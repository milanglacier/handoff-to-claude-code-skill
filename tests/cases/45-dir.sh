#!/usr/bin/env bash
# Threads and jobs are scoped to the directory they ran in, so every command that
# reads that state has to be able to point at the same directory.
. "$(dirname "$0")/../lib.sh"

with_subscription

OTHER="$TMPROOT/other-project"
mkdir -p "$OTHER"

sid_other="$(handoff chat --dir "$OTHER" "a thread over there" 2>/dev/null | awk '/^session: /{print $2}')"
assert_eq "$sid_other" "11111111-2222-3333-4444-555555555555" "a --dir run still reports its session"

# Without --dir, `sessions` must not claim the other directory's threads.
listing="$(handoff sessions 2>/dev/null)"
assert_contains "$listing" "no recorded threads" "sessions in the cwd does not see another dir's threads"

listing="$(handoff sessions --dir "$OTHER" 2>/dev/null)"
assert_contains "$listing" "a thread over there" "sessions --dir finds them"

# doctor reports the state directory it would actually use.
doc_here="$(handoff doctor 2>&1 | awk '/^state_dir: /{print $2}')"
doc_there="$(handoff doctor --dir "$OTHER" 2>&1 | awk '/^state_dir: /{print $2}')"
if [ "$doc_here" != "$doc_there" ]; then
    ok "doctor --dir reports the other project's state directory"
else
    fail "doctor ignored --dir (both reported $doc_here)"
fi

# Background jobs, queried both ways.
out="$(handoff agent --dir "$OTHER" --background "work over there" 2>/dev/null)"
job="$(printf '%s' "$out" | awk '/^job: /{print $2}')"
assert_contains "$out" "--dir $OTHER" "the printed status_cmd carries --dir so it still works"

handoff wait "$job" --dir "$OTHER" --timeout 30 >/dev/null 2>&1
assert_eq "$?" "0" "wait --dir finds the job"
assert_contains "$(handoff status --dir "$OTHER" "$job" 2>/dev/null)" "status: done" "status --dir finds the job"

# The cross-project fallback still covers a caller that forgot --dir.
assert_contains "$(handoff status "$job" 2>/dev/null)" "status: done" "status without --dir falls back to a search"

assert_contains "$(handoff tail --dir "$OTHER" "$job" -n 5 2>/dev/null)" "session:" "tail --dir finds the job"

# --dir still has to be a real directory, and -n/--timeout still validated.
out="$(handoff sessions --dir "$TMPROOT/nope" 2>&1)"
assert_contains "$out" "not a directory" "a bogus --dir is rejected"

out="$(handoff tail --dir "$OTHER" "$job" -n xyz 2>&1)"
assert_contains "$out" "whole number of lines" "a non-numeric -n is rejected"

finish
