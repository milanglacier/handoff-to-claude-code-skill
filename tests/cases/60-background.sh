#!/usr/bin/env bash
# Background jobs are the fallback for harnesses without their own background
# shell, so the whole lifecycle needs to hold up.
. "$(dirname "$0")/../lib.sh"

with_subscription
export FAKE_CLAUDE_SLEEP=2

out="$(handoff agent --background "long task" 2>/dev/null)"
job="$(printf '%s' "$out" | awk '/^job: /{print $2}')"
assert_contains "$job" "job-" "a job id is returned immediately"

status="$(handoff status "$job" 2>/dev/null)"
assert_contains "$status" "status: running" "the job starts out running"

waited="$(handoff wait "$job" --timeout 30 2>/dev/null)"
rc=$?
assert_eq "$rc" "0" "wait exits 0 for a successful job"
assert_contains "$waited" "handoff metadata" "wait prints the job output"

status="$(handoff status "$job" 2>/dev/null)"
assert_contains "$status" "status: done" "the job ends up done"
assert_contains "$status" "exit_code: 0" "the exit code is recorded"

tailed="$(handoff tail "$job" -n 5 2>/dev/null)"
assert_contains "$tailed" "session:" "tail shows the end of the output"

# A failing run must be visible as failed, not silently done.
unset FAKE_CLAUDE_SLEEP
export FAKE_CLAUDE_EXIT=3
out="$(handoff agent --background "doomed" 2>/dev/null)"
job="$(printf '%s' "$out" | awk '/^job: /{print $2}')"
handoff wait "$job" --timeout 30 >/dev/null 2>&1
rc=$?
assert_eq "$rc" "3" "wait propagates the failing exit code"
assert_contains "$(handoff status "$job" 2>/dev/null)" "status: failed" "a failed job is marked failed"

finish
