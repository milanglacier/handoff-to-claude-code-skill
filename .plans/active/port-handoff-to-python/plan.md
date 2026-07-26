# Port `handoff.sh` to Python

## Context

`skills/handoff-to-claude-code/scripts/handoff.sh` is a 610-line bash wrapper that
delegates work to the `claude` CLI. It works and its 10-case suite is green — but the
entire most recent commit (`ff5fb89`) was spent fixing bugs that exist *only because it
is shell*:

| Bug fixed in `ff5fb89` | Root cause | In Python |
|---|---|---|
| Prompt starting with `-` died silently in background | argv reconstructed as a word-split string; `--` separator lost | pass a dict through a JSON file — no argv round-trip |
| `kill` orphaned `claude`, leaving it spending quota | `set -m` + `$!` records the shim's pid, not the group | `start_new_session=True`; `os.killpg` |
| `model:` footer named the wrong model | needs a cost-ranked max over a JSON map | `max(usage.items(), key=…)` |
| Ledger emitted invalid UTF-8 | `cut -c` counts *bytes*; needs `iconv -c` to repair | `s[:80]` — str is characters |

That is four distinct bugs, none of them logic errors. The script is past the point where
shell is buying anything.

Porting also deletes a whole dependency axis: `jq` is currently *optional*, which forces a
parallel degraded code path (`HAVE_JQ`, `PREGEN_SESSION`, `gen_uuid`'s three-way fallback,
plain-text output with no session id or cost) plus `HANDOFF_JQ_BIN` and a dedicated test
case. `import json` makes all of it disappear. The six `jq` subprocesses per run collapse
to one `json.loads`.

**Intended outcome:** identical observable behavior, one fewer external dependency, and the
argv/process-group bug classes structurally eliminated.

Note on size: the port is *not* shorter. 576 code lines against bash's 502 — explicit
`try/except OSError`, explicit encodings, and a hand-rolled `which()` (bash gets `command -v`
for free) all cost lines. The return is correctness and one fewer dependency, not brevity.

### Decisions taken

- **Script only.** The bash suite is the oracle proving behavior is preserved; porting it
  at the same time would destroy the ability to tell which side broke. Porting tests is a
  separate follow-up.
- **Behavior-identical.** Known review findings M3 (stderr discarded on success), M4
  (unbounded state dir, ambient umask), L2 (`project_slug` collisions) stay open for a
  later commit. Any red test means the port is wrong — never "behavior intentionally
  changed".
- **Python 3.9+**, invoked as `python3 <path>`. Explicit interpreter, not the shebang:
  `npx skills add` and plain `cp` can drop the exec bit.

---

## Files

| File | Change |
|---|---|
| `skills/handoff-to-claude-code/scripts/handoff.py` | **new** — the port |
| `skills/handoff-to-claude-code/scripts/handoff.sh` | **delete** (`git rm`; history keeps it) |
| `tests/lib.sh` | line 41 only: `bash "$HANDOFF"` → `python3 "$HANDOFF"` |
| `tests/cases/50-jq-fallback.sh` | **delete** — tests a path that no longer exists |
| `skills/handoff-to-claude-code/SKILL.md` | 8 invocation lines; `.sh` → `.py`, `bash` → `python3` |
| `skills/handoff-to-claude-code/reference.md` | invocations + drop `jq` rows (L14, 54, 133, 169) |
| `README.md` | L31 `doctor` line; L34 requirements sentence |

`tests/fake-claude` stays bash and stays byte-identical. `tests/run.sh` unchanged.

---

## Design

Single file, stdlib only. Keep the existing section layout (state → auth → error
classification → invocation → job commands → arg parsing) so the diff stays reviewable
against the original.

### Direct translations

| bash | Python |
|---|---|
| `project_slug` | `re.sub(r'[^A-Za-z0-9]', '-', p).lstrip('-')` |
| `prompt_excerpt` + `iconv` dance | `s.translate({10:' ',9:' '})[:n]` |
| `gen_uuid` (3-way fallback) | **deleted** — only existed for the no-jq path |
| `subscription_present` | same three probes: `CLAUDE_CODE_OAUTH_TOKEN`, `.credentials.json`, Darwin `security` |
| `apply_auth_guard` (`unset`, `${!var}`) | build an explicit `env` dict, `pop()` the keys |
| `classify_failure` glob `case` | list of `(substrings, hint)` pairs, `any(s in text …)` |
| `mktemp` + `trap RETURN` for stderr | `subprocess.run(capture_output=True)` |
| 6 × `jq` invocations | one `json.loads(raw)` |
| `.modelUsage \| max_by(.value.costUSD)` | `max(usage.items(), key=lambda kv: kv[1].get("costUSD", 0) or 0)` |
| `find "$STATE_ROOT" -maxdepth 3 -type d -name "$job"` | bounded `os.scandir` walk, first match |
| `tail -n N` | `f.read().splitlines()[-n:]` |

Argument parsing stays a hand-rolled loop over `sys.argv` — **not** `argparse`. Two
behaviors argparse will not reproduce (both covered by tests):

- The `--` branch consumes args *while more than one remains*, so the prompt is the last
  token: `handoff agent -- --add-dir /tmp "the prompt"`.
- Unknown `-*` before the prompt must `die` with "use -- to pass options through", while a
  bare `-` means read stdin.

### Claude argv — exact order (asserted by `assert_argv_pair`)

```
claude -p [--model M] --permission-mode {auto|bypassPermissions}
       [--tools Read,Grep,Glob,Bash,WebSearch,WebFetch]   # chat only
       [--resume S | --continue]
       --output-format json                                # now unconditional
       [PASSTHRU...] -- PROMPT
```

`--session-id` disappears with the no-jq path. `--` before the prompt is mandatory.

### Background jobs — the real win

Replace the re-invocation entirely. Today the parent rebuilds a child command line
(`FG_ARGV` + `--` + `PASSTHRU` + `-`) and hands it to a nested `bash -c` string under
`set -m`. That reconstruction is what broke in `ff5fb89`.

Instead:

1. Parent writes `job.json` into the job dir: mode, prompt, workdir, model, session,
   continue, yolo, no_auth_check, passthru.
2. Parent spawns `subprocess.Popen([sys.executable, __file__, "__job", job_dir],
   start_new_session=True, stdin=DEVNULL, stdout=DEVNULL, stderr=DEVNULL)`.
3. Child (`__job`, an internal subcommand, absent from `usage()`) loads `job.json`, opens
   `output.txt`/`stderr.txt` itself, and runs the ordinary foreground path.
4. Child writes `exit_code`, then `status` = `killed` if the marker exists, else
   `done`/`failed`.

`start_new_session=True` makes the child a session leader, so **pgid == child pid** — no
`set -m`, no `$!` ambiguity. There is no argv round-trip left to break, so a prompt of any
shape is safe by construction.

`FG_ARGV` is deleted outright.

Preserve exactly, or tests break:
- `job_id` = `job-%Y%m%d-%H%M%S-<pid>`.
- Job dir files: `status`, `started_at`, `cmd`, `prompt.txt`, `pgid`, `exit_code`,
  `output.txt`, `stderr.txt`, `killed`. (`prompt.txt` is now redundant with `job.json`
  but `45-dir`/`65-kill` locate job dirs by `find`, and it is cheap provenance — keep it.)
- `status_cmd:` appends ` --dir <path>` only when `WORKDIR != PWD` (`45-dir` asserts this).

### Job control

- alive: `os.killpg(pgid, 0)` in `try/except (ProcessLookupError, PermissionError)`.
- `kill`: write `killed` marker → `SIGTERM` the group → poll ≤10s → `SIGKILL` → write
  `status: killed`. Killing an already-dead job prints status and exits 0.
- `status`/`wait`: a job whose group is gone with no `exit_code` file flips to `died`
  (`wait` returns 1). `wait` polls every 2s; timeout returns 2.

### Exit codes and streams (unchanged)

`note()` → `[handoff] …` on stderr. `die()` → `[handoff] ERROR: …`, exit 1. `wait`
returns the job's code, 2 on timeout, 1 on died. `doctor` returns 1 if `claude` is missing
or no subscription. Metadata footer stays byte-identical:

```
--- handoff metadata ---
session: … model: … cost_usd: … duration_s: … dir: …
```
(one field per line, as today)

---

## Risks

**`65-kill.sh:20` is the one test that could legitimately need adjusting.** It asserts
`group_size >= 3` with the comment "shim, wrapper and claude all share the job's group".
Bash yields 4 processes (`bash -c` shim → `bash handoff.sh` → `fake-claude` → `sleep`);
the Python design yields 3 (`python3 handoff.py __job` → `fake-claude` → `sleep`), because
the separate shim is gone. It still passes, but with a margin of one process. If it comes
back as 2, the correct fix is to relax the assertion and update its comment — **not** to
add a pointless intermediate process. Flag this rather than quietly editing the test.

Also stale-but-harmless: `60-background.sh:38-40` comments that "the background path
re-invokes this script … through argv". That stops being true. Comment-only; leave it or
fix it in the follow-up.

**Python availability.** Universal on Linux; on macOS `/usr/bin/python3` is a stub that
prompts for Xcode CLT. In practice anyone running `claude` has it, but this is a genuinely
new dependency where bash was not. `doctor` should print the interpreter and version so a
broken environment is diagnosable.

---

## Verification

1. `bash tests/run.sh` — expect 9 cases green (10 minus the deleted jq case), no case
   edits beyond `lib.sh:41`. This is the acceptance gate.
2. `python3 -m py_compile skills/handoff-to-claude-code/scripts/handoff.py`.
3. Confirm the deleted-path claim: `PATH` without `jq` must now change nothing.
4. Manual prompt-shape check, the bug `ff5fb89` fixed:
   ```bash
   printf -- '- bullet one\n- bullet two\n' | python3 …/handoff.py agent --background -
   python3 …/handoff.py wait <job> --timeout 30
   ```
5. Kill path against a real hang: start with `FAKE_CLAUDE_SLEEP=300`, `kill`, then confirm
   `ps -eo pgid= | grep <pgid>` is empty.
6. `HANDOFF_LIVE=1 bash tests/run.sh` — opt-in, spends quota. Run once before committing,
   since the offline stub cannot reject a malformed option the way the real CLI does.
7. `python3 …/handoff.py doctor` in a clean shell.

## Follow-ups (not this change)

- Port the test suite to Python (`unittest`), including `fake-claude`.
- Review findings M3 / M4 / L2.
