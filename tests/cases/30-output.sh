#!/usr/bin/env bash
# chat mode is relayed verbatim, so the text above the delimiter must survive
# byte-for-byte.
. "$(dirname "$0")/../lib.sh"

with_subscription

export FAKE_CLAUDE_TEXT='# Title

Some *markdown* with `code` and a | pipe |.

```python
print("hi")
```'

out="$(handoff chat "explain" 2>/dev/null)"
answer="$(printf '%s' "$out" | sed -n '1,/^--- handoff metadata ---$/p' | sed '$d' | sed -e :a -e '/^\n*$/{$d;N;};/\n$/ba')"

assert_eq "$answer" "$FAKE_CLAUDE_TEXT" "the answer above the delimiter is byte-identical"
assert_contains "$out" "--- handoff metadata ---" "the delimiter is present"
assert_contains "$out" "session: 11111111-2222-3333-4444-555555555555" "the footer carries the session id"
assert_contains "$out" "cost_usd: 0.0123" "the footer carries the cost"
assert_contains "$out" "model: claude-opus-5" "the footer names the model actually used"

# Real runs report the auto-mode classifier's haiku usage alongside the main
# model, and the classifier often has more uncached tokens than the model that
# did the work. The footer must still name the main model.
export FAKE_CLAUDE_MODEL_USAGE='{"claude-haiku-4-5-20251001":{"inputTokens":521,"outputTokens":13},"claude-opus-5[1m]":{"inputTokens":2,"outputTokens":4}}'
out="$(handoff chat "explain" 2>/dev/null)"
assert_contains "$out" "model: claude-opus-5[1m]" "the auxiliary haiku model is not mistaken for the main one"

finish
