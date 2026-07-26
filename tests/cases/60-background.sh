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

# The background path re-invokes this script, so anything it cannot round-trip
# through argv breaks only in the background - and silently, since the caller
# already has its job id and a clean exit by then.
unset FAKE_CLAUDE_EXIT

out="$(handoff agent --background -- --add-dir /tmp "passthrough task" 2>/dev/null)"
job="$(printf '%s' "$out" | awk '/^job: /{print $2}')"
handoff wait "$job" --timeout 30 >/dev/null 2>&1
assert_eq "$?" "0" "--background survives a -- passthrough"
assert_argv_pair "--add-dir" "/tmp"
assert_argv_has "passthrough task"

# A markdown bullet is an entirely ordinary way to start a task description.
out="$(printf -- '- Refactor the parser\n- Run the tests\n' | handoff agent --background - 2>/dev/null)"
job="$(printf '%s' "$out" | awk '/^job: /{print $2}')"
handoff wait "$job" --timeout 30 >/dev/null 2>&1
assert_eq "$?" "0" "--background survives a prompt beginning with -"
assert_argv_has "- Refactor the parser
- Run the tests"

out="$(handoff wait "$job" --timeout abc 2>&1)"
assert_contains "$out" "whole number of seconds" "a non-numeric --timeout is rejected up front"

finish
