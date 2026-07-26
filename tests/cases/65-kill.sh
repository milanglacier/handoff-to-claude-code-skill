#!/usr/bin/env bash
# A stuck job has to be stoppable, and stopping it must reach `claude` itself -
# killing the wrapper shim alone leaves the model running and burning quota.
. "$(dirname "$0")/../lib.sh"

with_subscription

# Processes sharing a job's process group. Portable across Linux and BSD ps.
group_size() { ps -eo pgid=,pid= | awk -v g="$1" '$1 == g' | wc -l | tr -d ' '; }

export FAKE_CLAUDE_SLEEP=300
job="$(handoff agent --background "a job that hangs" 2>/dev/null | awk '/^job: /{print $2}')"
sleep 1

job_dir="$(find "$XDG_STATE_HOME" -type d -name "$job")"
pg="$(cat "$job_dir/pgid" 2>/dev/null)"

assert_eq "$(ps -o pgid= -p "$pg" 2>/dev/null | tr -d ' ')" "$pg" "the fork leads its own process group"
if [ "$(group_size "$pg")" -ge 3 ]; then
    ok "shim, wrapper and claude all share the job's group ($(group_size "$pg") processes)"
else
    fail "expected the whole tree in the job group, found $(group_size "$pg")"
fi

handoff kill "$job" >/dev/null 2>&1
assert_eq "$(group_size "$pg")" "0" "kill reaps the whole tree, not just the shim"
assert_contains "$(handoff status "$job" 2>/dev/null)" "status: killed" "a killed job reports killed, not failed"

# Killing an already-finished job is a no-op, not an error.
handoff kill "$job" >/dev/null 2>&1
assert_eq "$?" "0" "killing a dead job is harmless"

# A job killed from outside never writes an exit code. Neither status nor wait
# may report it as still running.
job2="$(handoff agent --background "another hang" 2>/dev/null | awk '/^job: /{print $2}')"
sleep 1
job_dir2="$(find "$XDG_STATE_HOME" -type d -name "$job2")"
kill -KILL -- "-$(cat "$job_dir2/pgid")" 2>/dev/null
sleep 1

handoff wait "$job2" --timeout 20 >/dev/null 2>&1
assert_eq "$?" "1" "wait returns instead of spinning forever on a hard-killed job"
assert_contains "$(handoff status "$job2" 2>/dev/null)" "status: died" "a hard-killed job reports died"

finish
