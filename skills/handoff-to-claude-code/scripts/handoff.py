#!/usr/bin/env python3
# handoff.py - delegate a task or a question to Claude Code from another agent.
#
# See ../reference.md for the full flag table and troubleshooting notes.
#
# Stdlib only, Python 3.9+. Invoke as `python3 handoff.py ...` rather than
# relying on the exec bit, which does not reliably survive `npx skills add`.

import json
import os
import re
import signal
import subprocess
import sys
import time
import traceback

# The suite exercises a CJK prompt under LC_ALL=C, and a job's output file
# outlives whatever locale wrote it. Pin UTF-8 rather than inherit the locale's
# codec, which would raise on the first non-ASCII byte.
for _stream in (sys.stdin, sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError, OSError):
        pass

SCRIPT_PATH = os.path.abspath(__file__)
CLAUDE_BIN = os.environ.get("HANDOFF_CLAUDE_BIN") or "claude"
STATE_ROOT = os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state"),
    "handoff-to-claude-code",
)
METADATA_DELIMITER = "--- handoff metadata ---"
CHAT_TOOLS = "Read,Grep,Glob,Bash,WebSearch,WebFetch"
CLOUD_VARS = ("CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY")
API_KEY_VARS = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")

USAGE = """\
Usage:
  handoff.py chat  [options] <prompt|->   Ask Claude Code a question (no Edit/Write)
  handoff.py agent [options] <task|->     Have Claude Code do the work
  handoff.py status <job-id>              Report a background job
  handoff.py tail   <job-id> [-n N]       Show the tail of a background job's output
  handoff.py wait   <job-id> [--timeout S] Block until a background job finishes
  handoff.py kill   <job-id>              Stop a background job and all it spawned
  handoff.py sessions                     List recent threads for this directory
  handoff.py doctor                       Preflight self-check

status, tail, wait, kill, sessions and doctor all take --dir <path> to look at a
directory other than the cwd. Pass the same --dir you ran the job with.

Options for chat/agent:
  --session <id>     Continue a specific thread (id comes from a previous run)
  --continue         Continue the most recent thread in this directory
  --model <name>     Override the model (default: whatever the user configured)
  --dir <path>       Run in this directory (default: cwd). Threads are scoped to it.
  --background       Return a job id immediately instead of blocking
  --yolo             Use bypassPermissions instead of the default auto mode
  --no-auth-check    Do not strip ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN
  -- <args...>       Everything after -- is passed straight to `claude`

A prompt of `-` is read from stdin."""


def note(msg):
    sys.stderr.write("[handoff] %s\n" % msg)


def die(msg, code=1):
    sys.stderr.write("[handoff] ERROR: %s\n" % msg)
    sys.exit(code)


def usage():
    sys.stdout.write(USAGE + "\n")


# --- small file helpers ----------------------------------------------------


def write_file(job_dir, name, text):
    with open(os.path.join(job_dir, name), "w", encoding="utf-8") as fh:
        fh.write(text)


def read_file(job_dir, name, default=None):
    try:
        with open(os.path.join(job_dir, name), encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return default


def utcnow():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# --- state -----------------------------------------------------------------


def logical_cwd():
    # Mirror bash's $PWD, which keeps the symlinked path the caller used. The
    # project slug is derived from this, so switching to the resolved path would
    # silently relocate the state directory on hosts where /tmp is a symlink.
    pwd = os.environ.get("PWD")
    if pwd and os.path.isabs(pwd):
        try:
            if os.path.samefile(pwd, "."):
                return pwd
        except OSError:
            pass
    return os.getcwd()


def project_slug(path):
    return re.sub(r"[^A-Za-z0-9]", "-", path).lstrip("-")


def state_dir(path):
    return os.path.join(STATE_ROOT, project_slug(path))


# --- auth ------------------------------------------------------------------


def subscription_present():
    if os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"):
        return True
    config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    if os.path.isfile(os.path.join(config, ".credentials.json")):
        return True
    if sys.platform == "darwin":
        try:
            rc = subprocess.run(
                ["security", "find-generic-password", "-s", "Claude Code-credentials"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ).returncode
            return rc == 0
        except OSError:
            return False
    return False


def apply_auth_guard(no_auth_check):
    """Return the environment `claude` should run with, warning about billing."""
    env = dict(os.environ)
    for var in CLOUD_VARS:
        if env.get(var):
            note("%s is set; this run bills that cloud provider, not the Claude subscription." % var)

    if no_auth_check:
        return env

    has_key = any(env.get(v) for v in API_KEY_VARS)
    if subscription_present():
        if has_key:
            for var in API_KEY_VARS:
                env.pop(var, None)
            note("stripped ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN so this run bills the subscription")
    elif has_key:
        note("no subscription credentials found; falling back to the API key in the environment")
    return env


# --- error classification --------------------------------------------------

FAILURE_HINTS = (
    (
        ("Login expired", "run /login"),
        "the Claude Code login has expired. A human must run `claude` and /login. Do not retry.",
    ),
    (
        ("usage limit", "Usage limit", "rate_limit", "Rate limit"),
        "the subscription usage limit was hit. Retrying now will not help; wait for the reset.",
    ),
    (
        ("Credit balance is too low", "billing_error"),
        "billing is blocked on the account. Do not retry.",
    ),
    (
        ("oauth_org_not_allowed", "authentication_failed", "Invalid API key"),
        "authentication was rejected. Check `handoff.py doctor`. Do not retry.",
    ),
)


def classify_failure(text):
    """Return a hint for a recognised failure, or '' when unrecognised."""
    for needles, hint in FAILURE_HINTS:
        if any(needle in text for needle in needles):
            return hint
    return ""


# --- claude invocation -----------------------------------------------------


def build_claude_args(o):
    args = ["-p"]
    if o["model"]:
        args += ["--model", o["model"]]
    args += ["--permission-mode", "bypassPermissions" if o["yolo"] else "auto"]
    # chat can look around and run commands, but is not handed Edit/Write.
    if o["mode"] == "chat":
        args += ["--tools", CHAT_TOOLS]
    if o["session"]:
        args += ["--resume", o["session"]]
    elif o["continue"]:
        args.append("--continue")
    args += ["--output-format", "json"]
    args += o["passthru"]
    return args


def prompt_excerpt(prompt, limit):
    # Slicing a str counts characters, so this cannot split a multibyte
    # character the way `cut -c` on bytes could.
    return prompt.replace("\n", " ").replace("\t", " ")[:limit]


def record_session(sdir, sid, mode, prompt):
    if not sid:
        return
    os.makedirs(sdir, exist_ok=True)
    line = "%s\t%s\t%s\t%s\n" % (utcnow(), sid, mode, prompt_excerpt(prompt, 80))
    with open(os.path.join(sdir, "sessions.tsv"), "a", encoding="utf-8") as fh:
        fh.write(line)


def pick_model(usage):
    """The priciest entry in modelUsage.

    There is no top-level model field, and modelUsage also lists the auxiliary
    haiku model that auto mode uses for its safety classifier. Token counts
    cannot tell the two apart: the main model's input is mostly cache reads,
    which are billed separately from inputTokens, so the classifier routinely
    out-tokens it (521 vs 2 on a real run). Cost is not fooled by that - the
    model doing the work always dominates on price.
    """
    if not isinstance(usage, dict) or not usage:
        return ""
    return max(usage.items(), key=lambda kv: (kv[1] or {}).get("costUSD") or 0)[0]


def run_foreground(o):
    sdir = state_dir(o["workdir"])
    os.makedirs(sdir, exist_ok=True)
    env = apply_auth_guard(o["no_auth_check"])

    # `--` ends claude's own option parsing. Without it a prompt starting with `-`
    # (a markdown bullet, most often) is rejected as an unknown option by the CLI.
    argv = [CLAUDE_BIN] + build_claude_args(o) + ["--", o["prompt"]]

    start = time.time()
    try:
        proc = subprocess.run(
            argv, cwd=o["workdir"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
    except OSError as exc:
        die("could not run %s: %s" % (CLAUDE_BIN, exc))
    raw = proc.stdout.decode("utf-8", "replace")
    err = proc.stderr.decode("utf-8", "replace")
    elapsed = int(time.time() - start)

    if proc.returncode != 0:
        hint = classify_failure(raw + err)
        if hint:
            note("ERROR: " + hint)
        sys.stderr.write(err)
        note("claude exited with status %d" % proc.returncode)
        return proc.returncode

    try:
        data = json.loads(raw)
        if not isinstance(data, dict):
            raise ValueError("not an object")
    except ValueError:
        # --output-format json is always requested, so this means claude printed
        # something unexpected. Relay it rather than swallow it.
        data = {}
        note("could not parse claude's JSON output; relaying it verbatim")

    text = data.get("result") if data else raw
    text = text if text is not None else ""
    sid = data.get("session_id") or ""
    cost = data.get("total_cost_usd")
    model_used = data.get("model") or pick_model(data.get("modelUsage"))

    if data.get("is_error"):
        hint = classify_failure(raw)
        if hint:
            note("ERROR: " + hint)
        note("claude reported is_error=true")
        sys.stdout.write(text + "\n")
        return 1

    if not model_used:
        model_used = o["model"] or "(user default)"

    record_session(sdir, sid, o["mode"], o["prompt"])

    sys.stdout.write(text + "\n")
    sys.stdout.write("\n" + METADATA_DELIMITER + "\n")
    sys.stdout.write(
        "session: %s\nmodel: %s\ncost_usd: %s\nduration_s: %s\ndir: %s\n"
        % (sid or "unknown", model_used, "n/a" if cost is None else cost, elapsed, o["workdir"])
    )
    return 0


def run_background(o):
    sdir = state_dir(o["workdir"])
    job_id = "job-%s-%d" % (time.strftime("%Y%m%d-%H%M%S"), os.getpid())
    job_dir = os.path.join(sdir, "jobs", job_id)
    os.makedirs(job_dir, exist_ok=True)

    write_file(job_dir, "status", "running\n")
    write_file(job_dir, "started_at", utcnow() + "\n")
    write_file(job_dir, "cmd", "%s %s %s\n" % (o["mode"], o["workdir"], prompt_excerpt(o["prompt"], 200)))
    # Kept as plain-text provenance next to the machine-readable job.json.
    write_file(job_dir, "prompt.txt", o["prompt"])
    write_file(job_dir, "job.json", json.dumps(o))

    # The whole job description travels in job.json, so nothing has to survive a
    # trip back through argv - which is what used to break any prompt starting
    # with `-`. start_new_session makes the child a session leader, so its pid is
    # its process group id and `kill` can reap claude and everything it spawned.
    proc = subprocess.Popen(
        [sys.executable, SCRIPT_PATH, "__job", job_dir],
        cwd=o["workdir"],
        start_new_session=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    write_file(job_dir, "pgid", "%d\n" % proc.pid)

    # Carry --dir into the hint, or it will not find the job it just started.
    dir_hint = "" if o["workdir"] == logical_cwd() else " --dir %s" % o["workdir"]
    sys.stdout.write("job: %s\n" % job_id)
    # Spelled the way the docs say to invoke it, so the hint is copy-pasteable
    # even where the exec bit did not survive installation.
    sys.stdout.write("status_cmd: python3 %s status%s %s\n" % (SCRIPT_PATH, dir_hint, job_id))
    sys.stdout.write("output_file: %s\n" % os.path.join(job_dir, "output.txt"))
    return 0


def cmd_job(job_dir):
    """Internal: run a background job described by job.json. Not in usage()."""
    with open(os.path.join(job_dir, "job.json"), encoding="utf-8") as fh:
        o = json.load(fh)

    out_fh = open(os.path.join(job_dir, "output.txt"), "wb")
    err_fh = open(os.path.join(job_dir, "stderr.txt"), "wb")
    os.dup2(out_fh.fileno(), 1)
    os.dup2(err_fh.fileno(), 2)

    try:
        rc = run_foreground(o)
    except SystemExit as exc:
        rc = exc.code if isinstance(exc.code, int) else 1
    except Exception:
        traceback.print_exc()
        rc = 1

    sys.stdout.flush()
    sys.stderr.flush()
    write_file(job_dir, "exit_code", "%d\n" % rc)
    if os.path.exists(os.path.join(job_dir, "killed")):
        status = "killed"
    elif rc == 0:
        status = "done"
    else:
        status = "failed"
    write_file(job_dir, "status", status + "\n")
    return 0


# --- job commands ----------------------------------------------------------


def parse_query_opts(args):
    """Pull `--dir <path>` out of the arguments; everything else lands in rest.

    Threads and jobs are scoped to the directory they ran in, so a caller that
    used --dir has to be able to say so when querying them too.
    """
    query_dir = logical_cwd()
    rest = []
    i = 0
    while i < len(args):
        if args[i] == "--dir":
            value = args[i + 1] if i + 1 < len(args) else ""
            if not value:
                die("--dir needs a value")
            if not os.path.isdir(value):
                die("--dir is not a directory: %s" % value)
            query_dir = os.path.abspath(value)
            i += 2
        else:
            rest.append(args[i])
            i += 1
    return query_dir, rest


def find_job_dir(job_id, query_dir):
    direct = os.path.join(state_dir(query_dir), "jobs", job_id)
    if os.path.isdir(direct):
        return direct
    # The caller may have moved; fall back to a search across projects.
    for root, dirs, _files in os.walk(STATE_ROOT):
        if job_id in dirs:
            return os.path.join(root, job_id)
        if root[len(STATE_ROOT):].count(os.sep) >= 2:
            dirs[:] = []
    die("unknown job id: %s" % job_id)


def read_pgid(job_dir):
    raw = read_file(job_dir, "pgid", "")
    try:
        return int((raw or "").strip())
    except ValueError:
        return None


def job_alive(job_dir):
    """True while any process in the job's group is still around."""
    pgid = read_pgid(job_dir)
    if not pgid:
        return False
    try:
        os.killpg(pgid, 0)
        return True
    except OSError:
        return False


def cmd_kill(job_dir):
    name = os.path.basename(job_dir)
    pgid = read_pgid(job_dir)
    if not pgid:
        die("no process group recorded for %s" % name)
    if not job_alive(job_dir):
        note("job %s is not running" % name)
        return cmd_status(job_dir)

    # Marker first, so the child can tell a kill apart from an ordinary failure.
    write_file(job_dir, "killed", "")
    try:
        os.killpg(pgid, signal.SIGTERM)
    except OSError:
        pass
    waited = 0
    while job_alive(job_dir) and waited < 10:
        time.sleep(1)
        waited += 1
    if job_alive(job_dir):
        try:
            os.killpg(pgid, signal.SIGKILL)
        except OSError:
            pass
    write_file(job_dir, "status", "killed\n")
    sys.stdout.write("job: %s\nstatus: killed\n" % name)
    return 0


def cmd_status(job_dir):
    status = (read_file(job_dir, "status", "") or "").strip() or "unknown"
    # A job whose group is gone but which never recorded an exit code was killed
    # from outside; without this it reads as `running` forever.
    if (
        status == "running"
        and not job_alive(job_dir)
        and not os.path.exists(os.path.join(job_dir, "exit_code"))
    ):
        status = "died"
        write_file(job_dir, "status", "died\n")

    started = (read_file(job_dir, "started_at", "") or "").strip() or "unknown"
    sys.stdout.write("job: %s\n" % os.path.basename(job_dir))
    sys.stdout.write("status: %s\n" % status)
    sys.stdout.write("started_at: %s\n" % started)
    exit_code = read_file(job_dir, "exit_code")
    if exit_code is not None:
        sys.stdout.write("exit_code: %s\n" % exit_code.strip())
    sys.stdout.write("output_file: %s\n" % os.path.join(job_dir, "output.txt"))
    stderr_path = os.path.join(job_dir, "stderr.txt")
    if os.path.exists(stderr_path) and os.path.getsize(stderr_path) > 0:
        sys.stdout.write("stderr_file: %s\n" % stderr_path)
    return 0


def cmd_tail(job_dir, lines):
    body = read_file(job_dir, "output.txt")
    if body is None:
        die("no output yet for %s" % os.path.basename(job_dir))
    tail = body.splitlines()[-lines:] if lines else []
    for line in tail:
        sys.stdout.write(line + "\n")
    return 0


def cmd_wait(job_dir, timeout):
    waited = 0
    while True:
        status = (read_file(job_dir, "status", "") or "").strip() or "unknown"
        if status != "running":
            break
        # Don't spin forever on a job that was killed before it could report.
        if not job_alive(job_dir) and not os.path.exists(os.path.join(job_dir, "exit_code")):
            write_file(job_dir, "status", "died\n")
            note("job died without reporting an exit code")
            return 1
        if timeout > 0 and waited >= timeout:
            note("still running after %ds" % timeout)
            return 2
        time.sleep(2)
        waited += 2

    sys.stdout.write(read_file(job_dir, "output.txt", "") or "")
    err = read_file(job_dir, "stderr.txt", "") or ""
    if err:
        sys.stderr.write(err)
    raw = read_file(job_dir, "exit_code", "")
    try:
        return int((raw or "").strip())
    except ValueError:
        return 1


def cmd_sessions(query_dir):
    path = os.path.join(state_dir(query_dir), "sessions.tsv")
    if not os.path.isfile(path):
        sys.stdout.write("no recorded threads for %s\n" % query_dir)
        return 0
    with open(path, encoding="utf-8", errors="replace") as fh:
        rows = fh.read().splitlines()
    sys.stdout.write("started_at\tsession_id\tmode\tprompt\n")
    for row in rows[-20:]:
        sys.stdout.write(row + "\n")
    return 0


def which(binary):
    if os.path.sep in binary:
        return binary if os.path.isfile(binary) and os.access(binary, os.X_OK) else None
    for entry in (os.environ.get("PATH") or "").split(os.pathsep):
        candidate = os.path.join(entry, binary)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def cmd_doctor(query_dir):
    rc = 0
    found = which(CLAUDE_BIN)
    if found:
        version = ""
        try:
            out = subprocess.run(
                [found, "--version"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
            ).stdout.decode("utf-8", "replace")
            version = out.splitlines()[0] if out.splitlines() else ""
        except OSError:
            pass
        sys.stdout.write("claude: %s (%s)\n" % (found, version or "unknown version"))
    else:
        sys.stdout.write("claude: NOT FOUND on PATH\n")
        rc = 1

    if subscription_present():
        sys.stdout.write("auth: subscription credentials found\n")
        if any(os.environ.get(v) for v in API_KEY_VARS):
            sys.stdout.write(
                "auth: ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN present in the environment;"
                " it is stripped on every run (override with --no-auth-check)\n"
            )
    else:
        sys.stdout.write(
            "auth: NO subscription credentials found; runs will use the API key in the"
            " environment (billed per token)\n"
        )
        rc = 1

    for var in CLOUD_VARS:
        if os.environ.get(var):
            sys.stdout.write("auth: %s is set; runs bill that cloud provider\n" % var)

    sys.stdout.write(
        "python: %s (%d.%d.%d)\n"
        % (sys.executable, sys.version_info[0], sys.version_info[1], sys.version_info[2])
    )
    sys.stdout.write("state_dir: %s\n" % state_dir(query_dir))
    return rc


# --- argument parsing ------------------------------------------------------


def positive_int(value, what):
    if not value or not value.isdigit():
        die("%s, got: %s" % (what, value if value else "<empty>"))
    return int(value)


def cmd_run(mode, args):
    o = {
        "mode": mode,
        "model": "",
        "session": "",
        "continue": False,
        "yolo": False,
        "no_auth_check": False,
        "workdir": logical_cwd(),
        "passthru": [],
        "prompt": "",
    }
    background = False

    def value_at(i, flag):
        if i + 1 >= len(args) or not args[i + 1]:
            die("%s needs a value" % flag)
        return args[i + 1]

    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--session":
            o["session"] = value_at(i, "--session")
            i += 2
        elif arg == "--continue":
            o["continue"] = True
            i += 1
        elif arg == "--model":
            o["model"] = value_at(i, "--model")
            i += 2
        elif arg == "--dir":
            target = value_at(i, "--dir")
            if not os.path.isdir(target):
                die("--dir is not a directory: %s" % target)
            o["workdir"] = os.path.abspath(target)
            i += 2
        elif arg == "--background":
            background = True
            i += 1
        elif arg == "--yolo":
            o["yolo"] = True
            i += 1
        elif arg == "--no-auth-check":
            o["no_auth_check"] = True
            i += 1
        elif arg == "--":
            # Everything up to the last argument is for claude; the last one is
            # the prompt.
            i += 1
            while i < len(args) - 1:
                o["passthru"].append(args[i])
                i += 1
            break
        elif arg in ("-h", "--help"):
            usage()
            return 0
        elif arg == "-":
            break  # the prompt, read from stdin
        elif arg.startswith("-"):
            die("unknown option: %s (use -- to pass options through to claude)" % arg)
        else:
            break

    remaining = args[i:]
    if not remaining:
        die("missing prompt (pass a string, or - to read stdin)")
    prompt = remaining[0]
    if prompt == "-":
        # rstrip mirrors bash's $(cat), which drops trailing newlines.
        prompt = sys.stdin.read().rstrip("\n")
        if not prompt:
            die("empty prompt on stdin")
    o["prompt"] = prompt

    if o["session"] and o["continue"]:
        die("--session and --continue are mutually exclusive")

    if background:
        # Warn the caller directly; the child repeats this into its stderr file.
        apply_auth_guard(o["no_auth_check"])
        return run_background(o)
    return run_foreground(o)


def main(argv):
    if not argv:
        usage()
        return 1

    command, args = argv[0], argv[1:]

    if command in ("chat", "agent"):
        return cmd_run(command, args)

    if command == "__job":
        if not args:
            die("__job needs a job directory")
        return cmd_job(args[0])

    if command in ("status", "tail", "wait", "kill", "sessions", "doctor"):
        query_dir, rest = parse_query_opts(args)

        if command == "sessions":
            return cmd_sessions(query_dir)
        if command == "doctor":
            return cmd_doctor(query_dir)

        if not rest:
            die("%s needs a job id" % command)
        job_dir = find_job_dir(rest[0], query_dir)

        if command == "status":
            return cmd_status(job_dir)
        if command == "kill":
            return cmd_kill(job_dir)
        if command == "tail":
            lines = "50"
            if len(rest) > 1 and rest[1] == "-n":
                lines = rest[2] if len(rest) > 2 else "50"
            return cmd_tail(job_dir, positive_int(lines, "-n needs a whole number of lines"))
        if command == "wait":
            timeout = "0"
            if len(rest) > 1 and rest[1] == "--timeout":
                timeout = rest[2] if len(rest) > 2 else ""
                positive_int(timeout, "--timeout needs a whole number of seconds")
            return cmd_wait(job_dir, int(timeout))

    if command in ("-h", "--help", "help"):
        usage()
        return 0

    die("unknown command: %s (try --help)" % command)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(130)
