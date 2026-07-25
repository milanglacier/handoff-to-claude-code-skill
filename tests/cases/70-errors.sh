#!/usr/bin/env bash
# A cheap orchestrator will happily retry forever; failures that cannot be
# retried must say so.
. "$(dirname "$0")/../lib.sh"

with_subscription

export FAKE_CLAUDE_EXIT=1
export FAKE_CLAUDE_STDERR="Login expired · Please run /login"
err="$(handoff chat "hi" 2>&1 >/dev/null)"
rc=$?
assert_contains "$err" "ERROR: the Claude Code login has expired" "expired logins are named"
assert_contains "$err" "Do not retry" "the orchestrator is told not to retry"

export FAKE_CLAUDE_STDERR="Claude AI usage limit reached"
err="$(handoff agent "hi" 2>&1 >/dev/null)"
assert_contains "$err" "usage limit" "usage limits are named"

export FAKE_CLAUDE_STDERR="something nobody has seen before"
err="$(handoff chat "hi" 2>&1 >/dev/null)"
assert_contains "$err" "claude exited with status 1" "unknown failures still surface the exit status"
assert_contains "$err" "something nobody has seen before" "claude's own stderr is passed through"

handoff chat "hi" >/dev/null 2>&1
assert_eq "$?" "1" "a failing run exits non-zero"

unset FAKE_CLAUDE_EXIT FAKE_CLAUDE_STDERR
export FAKE_CLAUDE_IS_ERROR=1
handoff chat "hi" >/dev/null 2>&1
assert_eq "$?" "1" "is_error=true in the JSON result is treated as a failure"

finish
