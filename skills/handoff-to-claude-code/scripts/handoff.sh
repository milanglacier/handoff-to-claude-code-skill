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
  handoff.sh sessions                     List recent threads for this directory
  handoff.sh doctor                       Preflight self-check

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
    *"Login expired"* | *"run /login"* | *"Please run /login"*)
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

record_session() {
    # $1 state dir, $2 session id, $3 mode, $4 prompt
    local dir="$1" sid="$2" mode="$3" prompt="$4"
    [ -n "$sid" ] || return 0
    mkdir -p "$dir"
    printf '%s\t%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sid" "$mode" \
        "$(printf '%s' "$prompt" | tr '\n\t' '  ' | cut -c1-80)" \
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
    raw="$(cd "$WORKDIR" && "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}" "$PROMPT" 2>"$err_file")"
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
        # haiku model that auto mode uses for its safety classifier - which often
        # out-tokens the main model, whose input is mostly cached. So drop haiku
        # entries first, and only then take the busiest.
        model_used="$(printf '%s' "$raw" | "$JQ_BIN" -r '
            .model
            // (.modelUsage // {} | to_entries as $all
                | ($all | map(select(.key | test("haiku"; "i") | not))) as $main
                | (if ($main | length) > 0 then $main else $all end)
                | max_by((.value.inputTokens // 0) + (.value.outputTokens // 0))
                | .key)
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
    printf '%s %s %s\n' "$MODE" "$WORKDIR" "$(printf '%s' "$PROMPT" | tr '\n' ' ' | cut -c1-200)" >"$job_dir/cmd"

    (
        HANDOFF_JOB_DIR="$job_dir" \
            nohup bash -c '
                job="$HANDOFF_JOB_DIR"
                bash "$@" >"$job/output.txt" 2>"$job/stderr.txt"
                ec=$?
                printf "%s\n" "$ec" >"$job/exit_code"
                if [ "$ec" -eq 0 ]; then printf "done\n" >"$job/status"; else printf "failed\n" >"$job/status"; fi
            ' _ "$SCRIPT_PATH" "${FG_ARGV[@]}" >/dev/null 2>&1 &
        printf '%s\n' "$!" >"$job_dir/pid"
    )

    printf 'job: %s\n' "$job_id"
    printf 'status_cmd: %s status %s\n' "$SCRIPT_PATH" "$job_id"
    printf 'output_file: %s\n' "$job_dir/output.txt"
}

# --- job commands ----------------------------------------------------------

find_job_dir() {
    local job_id="$1" dir
    dir="$(state_dir "$PWD")/jobs/$job_id"
    if [ -d "$dir" ]; then
        printf '%s' "$dir"
        return 0
    fi
    # The caller may have moved; fall back to a search across projects.
    dir="$(find "$STATE_ROOT" -maxdepth 3 -type d -name "$job_id" 2>/dev/null | head -1)"
    [ -n "$dir" ] || die "unknown job id: $job_id"
    printf '%s' "$dir"
}

cmd_status() {
    local job_dir="$1" status
    status="$(cat "$job_dir/status" 2>/dev/null || printf 'unknown')"
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
    file="$(state_dir "$PWD")/sessions.tsv"
    [ -f "$file" ] || {
        printf 'no recorded threads for %s\n' "$PWD"
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

    printf 'state_dir: %s\n' "$(state_dir "$PWD")"
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
                FG_ARGV+=("$1")
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
        FG_ARGV=("$MODE" "${FG_ARGV[@]}" "$PROMPT")
        run_background
    else
        run_foreground
    fi
    exit $?
    ;;
status)
    [ $# -ge 1 ] || die "status needs a job id"
    cmd_status "$(find_job_dir "$1")"
    ;;
tail)
    [ $# -ge 1 ] || die "tail needs a job id"
    job="$1"
    shift
    lines=50
    [ "${1:-}" = "-n" ] && lines="${2:-50}"
    cmd_tail "$(find_job_dir "$job")" "$lines"
    ;;
wait)
    [ $# -ge 1 ] || die "wait needs a job id"
    job="$1"
    shift
    timeout=0
    [ "${1:-}" = "--timeout" ] && timeout="${2:-0}"
    cmd_wait "$(find_job_dir "$job")" "$timeout"
    ;;
sessions)
    cmd_sessions
    ;;
doctor)
    cmd_doctor
    ;;
-h | --help | help)
    usage
    ;;
*)
    die "unknown command: $command (try --help)"
    ;;
esac
