#!/usr/bin/env bash
# The only case that talks to the real CLI and spends subscription quota.
# Skipped unless HANDOFF_LIVE=1.
. "$(dirname "$0")/../lib.sh"

if [ "${HANDOFF_LIVE:-0}" != 1 ]; then
    printf '    skip (set HANDOFF_LIVE=1 to run against the real claude CLI)\n'
    exit 0
fi

# Talk to the real binary and the real credentials.
unset HANDOFF_CLAUDE_BIN CLAUDE_CONFIG_DIR FAKE_CLAUDE_ARGV_LOG FAKE_CLAUDE_ENV_LOG

printf 'The magic word is xyzzy.\n' >"$WORK/note.txt"

out="$(handoff chat "Read note.txt and reply with just the magic word." 2>/dev/null)"
assert_contains "$out" "xyzzy" "claude read the file and answered"

sid="$(printf '%s' "$out" | awk '/^session: /{print $2}')"
case "$sid" in
[0-9a-f]*-*-*-*-*) ok "got a real session id: $sid" ;;
*) fail "no usable session id in the footer" ;;
esac

follow="$(handoff chat --session "$sid" "What word did you just say? Reply with only that word." 2>/dev/null)"
assert_contains "$follow" "xyzzy" "the follow-up turn remembered the first turn"

out="$(handoff agent "Create hello.txt containing exactly: hi" 2>/dev/null)"
assert_eq "$([ -f "$WORK/hello.txt" ] && echo yes)" "yes" "agent mode could write a file without an abort"

finish
