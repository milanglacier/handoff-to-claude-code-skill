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

# The ledger truncates the prompt, and the skill is explicitly triggered by
# Chinese phrases, so truncation must not slice a character in half.
zh='让 claude code 帮我把这个解析器重构一下然后运行所有的测试确保没有任何问题最后再提交代码好吗谢谢你'
LC_ALL=C handoff chat "$zh" >/dev/null 2>&1
if command -v iconv >/dev/null 2>&1; then
    if iconv -f UTF-8 -t UTF-8 <"$ledger" >/dev/null 2>&1; then
        ok "the ledger is still valid UTF-8 after truncating a CJK prompt"
    else
        fail "truncation left invalid UTF-8 in the ledger"
    fi
else
    printf '    skip (no iconv to verify UTF-8 with)\n'
fi

finish
