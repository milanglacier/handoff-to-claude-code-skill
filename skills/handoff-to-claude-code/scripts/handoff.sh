#!/usr/bin/env bash
# handoff.sh - delegate a task or a question to Claude Code from another agent.
#
# See ../reference.md for the full flag table and troubleshooting notes.

set -uo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
CLAUDE_BIN="${HANDOFF_CLAUDE_BIN:-claude}"
JQ_BIN="${HANDOFF_JQ_BIN:-jq}"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/handoff-to-claude-code"
METADATA_DELIMITER="--- handoff metadata ---"

note() { printf '[handoff] %s\n' "$*" >&2; }
die() {
    printf '[handoff] ERROR: %s\n' "$*" >&2
    exit "${2:-1}"
}

usage() {
    cat <<'EOF'
Usage:
  handoff.sh chat  [options] <prompt|->   Ask Claude Code a question (no Edit/Write)
  handoff.sh agent [options] <task|->     Have Claude Code do the work
  handoff.sh status <job-id>              Report a background job
  handoff.sh tail   <job-id> [-n N]       Show the tail of a background job's output
  handoff.sh wait   <job-id> [--timeout S] Block until a background job finishes
  handoff.sh kill   <job-id>              Stop a background job and all it spawned
  handoff.sh sessions                     List recent threads for this directory
  handoff.sh doctor                       Preflight self-check

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

A prompt of `-` is read from stdin.
EOF
}

# --- state -----------------------------------------------------------------

project_slug() {
    printf '%s' "$1" | sed -e 's/[^A-Za-z0-9]/-/g' -e 's/^-*//'
}

state_dir() {
    printf '%s/%s' "$STATE_ROOT" "$(project_slug "$1")"
}

gen_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr 'A-Z' 'a-z'
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import uuid; print(uuid.uuid4())'
    else
        die "cannot generate a UUID: install uuidgen, or jq so session ids come from Claude"
    fi
}

# --- auth ------------------------------------------------------------------

subscription_present() {
    [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && return 0
    [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ] && return 0
    if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
        security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1 && return 0
    fi
    return 1
}

apply_auth_guard() {
    for var in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY; do
        if [ -n "${!var:-}" ]; then
            note "$var is set; this run bills that cloud provider, not the Claude subscription."
        fi
    done

    if [ "$NO_AUTH_CHECK" = 1 ]; then
        return 0
    fi

    if subscription_present; then
        if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
            unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
            note "stripped ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN so this run bills the subscription"
        fi
    elif [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
        note "no subscription credentials found; falling back to the API key in the environment"
    fi
}

# --- error classification --------------------------------------------------

classify_failure() {
    # $1: combined stdout+stderr text. Prints a hint, or nothing when unrecognised.
    case "$1" in
    *"Login expired"* | *"run /login"*)
        printf 'the Claude Code login has expired. A human must run `claude` and /login. Do not retry.' ;;
    *"usage limit"* | *"Usage limit"* | *"rate_limit"* | *"Rate limit"*)
        printf 'the subscription usage limit was hit. Retrying now will not help; wait for the reset.' ;;
    *"Credit balance is too low"* | *"billing_error"*)
        printf 'billing is blocked on the account. Do not retry.' ;;
    *"oauth_org_not_allowed"* | *"authentication_failed"* | *"Invalid API key"*)
        printf 'authentication was rejected. Check `handoff.sh doctor`. Do not retry.' ;;
    *) printf '' ;;
    esac
}

# --- claude invocation -----------------------------------------------------

build_claude_args() {
    # Populates CLAUDE_ARGS. Requires MODE, MODEL, SESSION, CONTINUE, YOLO, HAVE_JQ.
    CLAUDE_ARGS=(-p)

    [ -n "$MODEL" ] && CLAUDE_ARGS+=(--model "$MODEL")

    if [ "$YOLO" = 1 ]; then
        CLAUDE_ARGS+=(--permission-mode bypassPermissions)
    else
        CLAUDE_ARGS+=(--permission-mode auto)
    fi

    # chat can look around and run commands, but cannot rewrite the tree.
    if [ "$MODE" = chat ]; then
        CLAUDE_ARGS+=(--tools "Read,Grep,Glob,Bash,WebSearch,WebFetch")
    fi

    if [ -n "$SESSION" ]; then
        CLAUDE_ARGS+=(--resume "$SESSION")
    elif [ "$CONTINUE" = 1 ]; then
        CLAUDE_ARGS+=(--continue)
    elif [ "$HAVE_JQ" = 0 ]; then
        # No jq means no way to read the session id back out, so pin it up front.
        PREGEN_SESSION="$(gen_uuid)" || exit 1
        CLAUDE_ARGS+=(--session-id "$PREGEN_SESSION")
    fi

    if [ "$HAVE_JQ" = 1 ]; then
        CLAUDE_ARGS+=(--output-format json)
    fi

    if [ ${#PASSTHRU[@]} -gt 0 ]; then
        CLAUDE_ARGS+=("${PASSTHRU[@]}")
    fi
}

prompt_excerpt() {
    # $1 prompt, $2 max length. `cut -c` counts bytes under LC_ALL=C, so it can
    # split a multibyte character and leave invalid UTF-8 in the ledger. iconv -c
    # drops whatever partial sequence that leaves; without iconv the worst case is
    # one mangled character in a display-only field.
    local out
    out="$(printf '%s' "$1" | tr '\n\t' '  ' | cut -c"1-$2")"
    if command -v iconv >/dev/null 2>&1; then
        out="$(printf '%s' "$out" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)"
    fi
    printf '%s' "$out"
}

record_session() {
    # $1 state dir, $2 session id, $3 mode, $4 prompt
    local dir="$1" sid="$2" mode="$3" prompt="$4"
    [ -n "$sid" ] || return 0
    mkdir -p "$dir"
    printf '%s\t%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sid" "$mode" \
        "$(prompt_excerpt "$prompt" 80)" \
        >>"$dir/sessions.tsv"
}

run_foreground() {
    local sdir err_file start elapsed rc raw text sid cost model_used hint combined
    sdir="$(state_dir "$WORKDIR")"
    mkdir -p "$sdir"
    err_file="$(mktemp)"
    trap 'rm -f "$err_file"' RETURN

    build_claude_args

    start="$(date +%s)"
    # `--` ends claude's own option parsing. Without it a prompt starting with `-`
    # (a markdown bullet, most often) is rejected as an unknown option by the CLI.
    raw="$(cd "$WORKDIR" && "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}" -- "$PROMPT" 2>"$err_file")"
    rc=$?
    elapsed=$(($(date +%s) - start))

    combined="$raw$(cat "$err_file")"
    if [ "$rc" -ne 0 ]; then
        hint="$(classify_failure "$combined")"
        [ -n "$hint" ] && note "ERROR: $hint"
        cat "$err_file" >&2
        note "claude exited with status $rc"
        return "$rc"
    fi

    if [ "$HAVE_JQ" = 1 ]; then
        text="$(printf '%s' "$raw" | "$JQ_BIN" -r '.result // empty')"
        sid="$(printf '%s' "$raw" | "$JQ_BIN" -r '.session_id // empty')"
        cost="$(printf '%s' "$raw" | "$JQ_BIN" -r '.total_cost_usd // empty')"
        # There is no top-level model field, and modelUsage also lists the auxiliary
        # haiku model that auto mode uses for its safety classifier. Token counts
        # cannot tell the two apart: the main model's input is mostly cache reads,
        # which are billed separately from inputTokens, so the classifier routinely
        # out-tokens it (521 vs 2 on a real run). Cost is not fooled by that - the
        # model doing the work always dominates on price - so take the priciest.
        model_used="$(printf '%s' "$raw" | "$JQ_BIN" -r '
            .model
            // (.modelUsage // {} | to_entries | max_by(.value.costUSD // 0) | .key)
            // empty')"
        if [ "$(printf '%s' "$raw" | "$JQ_BIN" -r '.is_error // false')" = true ]; then
            hint="$(classify_failure "$raw")"
            [ -n "$hint" ] && note "ERROR: $hint"
            note "claude reported is_error=true"
            printf '%s\n' "$text"
            return 1
        fi
    else
        text="$raw"
        sid="${SESSION:-$PREGEN_SESSION}"
        cost=""
        model_used=""
    fi

    [ -n "$model_used" ] || model_used="${MODEL:-(user default)}"
    [ -n "$cost" ] || cost="n/a"

    record_session "$sdir" "$sid" "$MODE" "$PROMPT"

    printf '%s\n' "$text"
    printf '\n%s\n' "$METADATA_DELIMITER"
    printf 'session: %s\nmodel: %s\ncost_usd: %s\nduration_s: %s\ndir: %s\n' \
        "${sid:-unknown}" "$model_used" "$cost" "$elapsed" "$WORKDIR"
    return 0
}

run_background() {
    local sdir job_id job_dir
    sdir="$(state_dir "$WORKDIR")"
    job_id="job-$(date +%Y%m%d-%H%M%S)-$$"
    job_dir="$sdir/jobs/$job_id"
    mkdir -p "$job_dir"

    printf '%s\n' "running" >"$job_dir/status"
    printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$job_dir/started_at"
    printf '%s %s %s\n' "$MODE" "$WORKDIR" "$(prompt_excerpt "$PROMPT" 200)" >"$job_dir/cmd"

    # The prompt goes to the child on stdin, never as an argument: re-parsing it as
    # argv breaks any prompt whose first character is `-` (a markdown bullet, say).
    # The -- separator has to be rebuilt here too, since PASSTHRU was flattened out
    # of it during parsing.
    printf '%s' "$PROMPT" >"$job_dir/prompt.txt"
    local child_argv=("$MODE" "${FG_ARGV[@]}")
    [ ${#PASSTHRU[@]} -gt 0 ] && child_argv+=(-- "${PASSTHRU[@]}")
    child_argv+=(-)

    (
        # Job control puts the fork in its own process group, so `kill -- -<pgid>`
        # reaps claude and everything it spawned rather than just this shim.
        set -m
        HANDOFF_JOB_DIR="$job_dir" \
            nohup bash -c '
                job="$HANDOFF_JOB_DIR"
                bash "$@" <"$job/prompt.txt" >"$job/output.txt" 2>"$job/stderr.txt"
                ec=$?
                printf "%s\n" "$ec" >"$job/exit_code"
                if [ -f "$job/killed" ]; then printf "killed\n" >"$job/status"
                elif [ "$ec" -eq 0 ]; then printf "done\n" >"$job/status"
                else printf "failed\n" >"$job/status"; fi
            ' _ "$SCRIPT_PATH" "${child_argv[@]}" </dev/null >/dev/null 2>&1 &
        printf '%s\n' "$!" >"$job_dir/pgid"
    )

    # Carry --dir into the hint, or it will not find the job it just started.
    local dir_hint=""
    [ "$WORKDIR" = "$PWD" ] || dir_hint=" --dir $WORKDIR"
    printf 'job: %s\n' "$job_id"
    printf 'status_cmd: %s status%s %s\n' "$SCRIPT_PATH" "$dir_hint" "$job_id"
    printf 'output_file: %s\n' "$job_dir/output.txt"
}

# --- job commands ----------------------------------------------------------

parse_query_opts() {
    # Pulls `--dir <path>` out of the arguments; everything else lands in REST.
    # Threads and jobs are scoped to the directory they ran in, so a caller that
    # used --dir has to be able to say so when querying them too.
    REST=()
    while [ $# -gt 0 ]; do
        case "$1" in
        --dir)
            [ -n "${2:-}" ] || die "--dir needs a value"
            [ -d "$2" ] || die "--dir is not a directory: $2"
            QUERY_DIR="$(cd "$2" && pwd)"
            shift 2
            ;;
        *)
            REST+=("$1")
            shift
            ;;
        esac
    done
}

find_job_dir() {
    local job_id="$1" dir
    dir="$(state_dir "$QUERY_DIR")/jobs/$job_id"
    if [ -d "$dir" ]; then
        printf '%s' "$dir"
        return 0
    fi
    # The caller may have moved; fall back to a search across projects.
    dir="$(find "$STATE_ROOT" -maxdepth 3 -type d -name "$job_id" 2>/dev/null | head -1)"
    [ -n "$dir" ] || die "unknown job id: $job_id"
    printf '%s' "$dir"
}

job_alive() {
    # $1 job dir. True while any process in the job's group is still around.
    local pg
    pg="$(cat "$1/pgid" 2>/dev/null)" || return 1
    [ -n "$pg" ] && kill -0 -- "-$pg" 2>/dev/null
}

cmd_kill() {
    local job_dir="$1" pg waited=0
    pg="$(cat "$job_dir/pgid" 2>/dev/null)"
    [ -n "$pg" ] || die "no process group recorded for $(basename "$job_dir")"
    if ! job_alive "$job_dir"; then
        note "job $(basename "$job_dir") is not running"
        cmd_status "$job_dir"
        return 0
    fi
    # Marker first, so the shim can tell a kill apart from an ordinary failure.
    : >"$job_dir/killed"
    kill -TERM -- "-$pg" 2>/dev/null
    while job_alive "$job_dir" && [ "$waited" -lt 10 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    job_alive "$job_dir" && kill -KILL -- "-$pg" 2>/dev/null
    printf 'killed\n' >"$job_dir/status"
    printf 'job: %s\nstatus: killed\n' "$(basename "$job_dir")"
}

cmd_status() {
    local job_dir="$1" status
    status="$(cat "$job_dir/status" 2>/dev/null || printf 'unknown')"
    # A job whose group is gone but which never recorded an exit code was killed
    # from outside; without this it reads as `running` forever.
    if [ "$status" = running ] && ! job_alive "$job_dir" && [ ! -f "$job_dir/exit_code" ]; then
        status=died
        printf '%s\n' "$status" >"$job_dir/status"
    fi
    printf 'job: %s\n' "$(basename "$job_dir")"
    printf 'status: %s\n' "$status"
    printf 'started_at: %s\n' "$(cat "$job_dir/started_at" 2>/dev/null || printf 'unknown')"
    [ -f "$job_dir/exit_code" ] && printf 'exit_code: %s\n' "$(cat "$job_dir/exit_code")"
    printf 'output_file: %s\n' "$job_dir/output.txt"
    [ -s "$job_dir/stderr.txt" ] && printf 'stderr_file: %s\n' "$job_dir/stderr.txt"
    return 0
}

cmd_tail() {
    local job_dir="$1" lines="$2"
    [ -f "$job_dir/output.txt" ] || die "no output yet for $(basename "$job_dir")"
    tail -n "$lines" "$job_dir/output.txt"
}

cmd_wait() {
    local job_dir="$1" timeout="$2" waited=0 status
    while :; do
        status="$(cat "$job_dir/status" 2>/dev/null || printf 'unknown')"
        [ "$status" != running ] && break
        # Don't spin forever on a job that was killed before it could report.
        if ! job_alive "$job_dir" && [ ! -f "$job_dir/exit_code" ]; then
            printf 'died\n' >"$job_dir/status"
            note "job died without reporting an exit code"
            return 1
        fi
        if [ "$timeout" -gt 0 ] && [ "$waited" -ge "$timeout" ]; then
            note "still running after ${timeout}s"
            return 2
        fi
        sleep 2
        waited=$((waited + 2))
    done
    cat "$job_dir/output.txt" 2>/dev/null
    if [ -s "$job_dir/stderr.txt" ]; then
        cat "$job_dir/stderr.txt" >&2
    fi
    return "$(cat "$job_dir/exit_code" 2>/dev/null || printf 1)"
}

cmd_sessions() {
    local file
    file="$(state_dir "$QUERY_DIR")/sessions.tsv"
    [ -f "$file" ] || {
        printf 'no recorded threads for %s\n' "$QUERY_DIR"
        return 0
    }
    printf 'started_at\tsession_id\tmode\tprompt\n'
    tail -n 20 "$file"
}

cmd_doctor() {
    local rc=0 version
    if command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
        version="$("$CLAUDE_BIN" --version 2>/dev/null | head -1)"
        printf 'claude: %s (%s)\n' "$(command -v "$CLAUDE_BIN")" "${version:-unknown version}"
    else
        printf 'claude: NOT FOUND on PATH\n'
        rc=1
    fi

    if subscription_present; then
        printf 'auth: subscription credentials found\n'
        if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
            printf 'auth: ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN present in the environment; it is stripped on every run (override with --no-auth-check)\n'
        fi
    else
        printf 'auth: NO subscription credentials found; runs will use the API key in the environment (billed per token)\n'
        rc=1
    fi

    for var in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY; do
        [ -n "${!var:-}" ] && printf 'auth: %s is set; runs bill that cloud provider\n' "$var"
    done

    if command -v "$JQ_BIN" >/dev/null 2>&1; then
        printf 'jq: %s\n' "$(command -v "$JQ_BIN")"
    else
        printf 'jq: not installed (falling back to pre-generated session ids and plain-text output)\n'
    fi

    printf 'state_dir: %s\n' "$(state_dir "$QUERY_DIR")"
    return "$rc"
}

# --- argument parsing ------------------------------------------------------

MODE=""
MODEL=""
SESSION=""
CONTINUE=0
YOLO=0
NO_AUTH_CHECK=0
BACKGROUND=0
WORKDIR="$PWD"
QUERY_DIR="$PWD"
REST=()
PROMPT=""
PREGEN_SESSION=""
PASSTHRU=()
FG_ARGV=()
CLAUDE_ARGS=()

[ $# -gt 0 ] || {
    usage
    exit 1
}

command="$1"
shift

case "$command" in
chat | agent)
    MODE="$command"
    while [ $# -gt 0 ]; do
        case "$1" in
        --session)
            SESSION="${2:-}"
            [ -n "$SESSION" ] || die "--session needs a value"
            FG_ARGV+=("$1" "$2")
            shift 2
            ;;
        --continue)
            CONTINUE=1
            FG_ARGV+=("$1")
            shift
            ;;
        --model)
            MODEL="${2:-}"
            [ -n "$MODEL" ] || die "--model needs a value"
            FG_ARGV+=("$1" "$2")
            shift 2
            ;;
        --dir)
            WORKDIR="${2:-}"
            [ -d "$WORKDIR" ] || die "--dir is not a directory: ${2:-}"
            WORKDIR="$(cd "$WORKDIR" && pwd)"
            FG_ARGV+=("$1" "$WORKDIR")
            shift 2
            ;;
        --background)
            BACKGROUND=1
            shift
            ;;
        --yolo)
            YOLO=1
            FG_ARGV+=("$1")
            shift
            ;;
        --no-auth-check)
            NO_AUTH_CHECK=1
            FG_ARGV+=("$1")
            shift
            ;;
        --)
            shift
            while [ $# -gt 1 ]; do
                PASSTHRU+=("$1")
                shift
            done
            break
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -)
            break # the prompt, read from stdin
            ;;
        -*)
            die "unknown option: $1 (use -- to pass options through to claude)"
            ;;
        *)
            break
            ;;
        esac
    done

    [ $# -gt 0 ] || die "missing prompt (pass a string, or - to read stdin)"
    PROMPT="$1"
    if [ "$PROMPT" = "-" ]; then
        PROMPT="$(cat)"
        [ -n "$PROMPT" ] || die "empty prompt on stdin"
    fi

    [ -n "$SESSION" ] && [ "$CONTINUE" = 1 ] && die "--session and --continue are mutually exclusive"

    HAVE_JQ=0
    command -v "$JQ_BIN" >/dev/null 2>&1 && HAVE_JQ=1

    apply_auth_guard

    if [ "$BACKGROUND" = 1 ]; then
        run_background
    else
        run_foreground
    fi
    exit $?
    ;;
status)
    parse_query_opts "$@"
    [ ${#REST[@]} -ge 1 ] || die "status needs a job id"
    cmd_status "$(find_job_dir "${REST[0]}")"
    ;;
tail)
    parse_query_opts "$@"
    [ ${#REST[@]} -ge 1 ] || die "tail needs a job id"
    lines=50
    [ "${REST[1]:-}" = "-n" ] && lines="${REST[2]:-50}"
    case "$lines" in
    '' | *[!0-9]*) die "-n needs a whole number of lines, got: ${lines:-<empty>}" ;;
    esac
    cmd_tail "$(find_job_dir "${REST[0]}")" "$lines"
    ;;
wait)
    parse_query_opts "$@"
    [ ${#REST[@]} -ge 1 ] || die "wait needs a job id"
    timeout=0
    if [ "${REST[1]:-}" = "--timeout" ]; then
        timeout="${REST[2]:-}"
        case "$timeout" in
        '' | *[!0-9]*) die "--timeout needs a whole number of seconds, got: ${timeout:-<empty>}" ;;
        esac
    fi
    cmd_wait "$(find_job_dir "${REST[0]}")" "$timeout"
    ;;
kill)
    parse_query_opts "$@"
    [ ${#REST[@]} -ge 1 ] || die "kill needs a job id"
    cmd_kill "$(find_job_dir "${REST[0]}")"
    ;;
sessions)
    parse_query_opts "$@"
    cmd_sessions
    ;;
doctor)
    parse_query_opts "$@"
    cmd_doctor
    ;;
-h | --help | help)
    usage
    ;;
*)
    die "unknown command: $command (try --help)"
    ;;
esac
