#!/usr/bin/env bash
# Multi-turn relies on the session id round-tripping through the orchestrator.
. "$(dirname "$0")/../lib.sh"

with_subscription

out="$(handoff chat "first turn" 2>/dev/null)"
sid="$(printf '%s' "$out" | awk '/^session: /{print $2}')"
assert_eq "$sid" "11111111-2222-3333-4444-555555555555" "the first turn reports a session id"

handoff chat --session "$sid" "second turn" >/dev/null 2>&1
assert_argv_pair "--resume" "$sid"
assert_argv_lacks "--session-id"

handoff chat --continue "third turn" >/dev/null 2>&1
assert_argv_has "--continue"
assert_argv_lacks "--resume"

ledger="$XDG_STATE_HOME/handoff-to-claude-code/$(printf '%s' "$WORK" | sed -e 's/[^A-Za-z0-9]/-/g' -e 's/^-*//')/sessions.tsv"
assert_eq "$([ -f "$ledger" ] && echo yes)" "yes" "a session ledger is written under XDG_STATE_HOME"
assert_contains "$(cat "$ledger")" "first turn" "the ledger records the prompt"

listing="$(handoff sessions 2>/dev/null)"
assert_contains "$listing" "$sid" "sessions lists the thread"

finish
