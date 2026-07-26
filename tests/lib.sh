#!/usr/bin/env bash
# Shared helpers for the offline test cases. Every case sources this file,
# gets an isolated state directory, and talks to tests/fake-claude instead of
# the real CLI, so nothing here spends subscription quota.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HANDOFF="$REPO_ROOT/skills/handoff-to-claude-code/scripts/handoff.py"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

WORK="$TMPROOT/work"
mkdir -p "$WORK"

export XDG_STATE_HOME="$TMPROOT/state"
export CLAUDE_CONFIG_DIR="$TMPROOT/claude-config"
export HANDOFF_CLAUDE_BIN="$TESTS_DIR/fake-claude"
export FAKE_CLAUDE_ARGV_LOG="$TMPROOT/argv.log"
export FAKE_CLAUDE_ENV_LOG="$TMPROOT/env.log"
mkdir -p "$CLAUDE_CONFIG_DIR"

# Start from a known-clean auth environment regardless of the developer's shell.
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY

FAILURES=0

ok() { printf '    ok  %s\n' "$*"; }
fail() {
    printf '    FAIL %s\n' "$*" >&2
    FAILURES=$((FAILURES + 1))
}

with_subscription() { : >"$CLAUDE_CONFIG_DIR/.credentials.json"; }
without_subscription() { rm -f "$CLAUDE_CONFIG_DIR/.credentials.json"; }

# handoff <args...> - run the wrapper in the temp work dir.
handoff() { (cd "$WORK" && python3 "$HANDOFF" "$@"); }

assert_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else
        fail "$3
      expected: $2
      actual:   $1"
    fi
}

assert_contains() {
    case "$1" in
    *"$2"*) ok "$3" ;;
    *) fail "$3 (missing '$2' in: $(printf '%s' "$1" | head -3))" ;;
    esac
}

assert_not_contains() {
    case "$1" in
    *"$2"*) fail "$3 (unexpectedly found '$2')" ;;
    *) ok "$3" ;;
    esac
}

# The argv log holds one argument per line, so exact-line matching avoids
# false positives from substrings.
assert_argv_has() {
    if grep -Fxq -- "$1" "$FAKE_CLAUDE_ARGV_LOG"; then ok "argv has $1"; else
        fail "argv missing $1
      argv: $(tr '\n' ' ' <"$FAKE_CLAUDE_ARGV_LOG")"
    fi
}

assert_argv_lacks() {
    if grep -Fxq -- "$1" "$FAKE_CLAUDE_ARGV_LOG"; then
        fail "argv unexpectedly has $1"
    else ok "argv lacks $1"; fi
}

# assert_argv_pair FLAG VALUE - VALUE must be the argument right after FLAG.
assert_argv_pair() {
    if awk -v a="$1" -v b="$2" 'prev==a && $0==b {found=1} {prev=$0} END {exit !found}' \
        "$FAKE_CLAUDE_ARGV_LOG"; then
        ok "argv has $1 $2"
    else
        fail "argv missing pair '$1 $2'
      argv: $(tr '\n' ' ' <"$FAKE_CLAUDE_ARGV_LOG")"
    fi
}

finish() { exit "$FAILURES"; }
