#!/usr/bin/env bash
# Without jq there is no way to read the session id back, so the wrapper has to
# pin one up front and fall back to plain-text output.
. "$(dirname "$0")/../lib.sh"

with_subscription
export HANDOFF_JQ_BIN="$TMPROOT/no-such-jq"

out="$(handoff chat "hello" 2>/dev/null)"

assert_argv_lacks "--output-format"
assert_argv_has "--session-id"

sid="$(printf '%s' "$out" | awk '/^session: /{print $2}')"
case "$sid" in
[0-9a-f]*-*-*-*-*) ok "a UUID was pre-generated: $sid" ;;
*) fail "expected a pre-generated UUID, got: $sid" ;;
esac
assert_argv_pair "--session-id" "$sid"
assert_contains "$out" "Some **markdown** text." "the plain-text answer is passed through"

doctor="$(handoff doctor 2>&1)"
assert_contains "$doctor" "jq: not installed" "doctor reports the missing jq"

finish
