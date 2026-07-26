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
# model, and the classifier has far more *uncached* tokens than the model that
# did the work - these are the numbers from an actual run. Cost is the only
# field that separates them, so the footer must be picking on cost.
export FAKE_CLAUDE_MODEL_USAGE='{"claude-haiku-4-5-20251001":{"inputTokens":521,"outputTokens":13,"cacheReadInputTokens":0,"costUSD":0.000586},"claude-opus-5[1m]":{"inputTokens":2,"outputTokens":4,"cacheCreationInputTokens":3800,"costUSD":0.03811}}'
out="$(handoff chat "explain" 2>/dev/null)"
assert_contains "$out" "model: claude-opus-5[1m]" "the auxiliary haiku model is not mistaken for the main one"

# The old token-based heuristic filtered on the name "haiku", so it misreported
# whenever haiku was itself the working model. Cost has no such blind spot.
export FAKE_CLAUDE_MODEL_USAGE='{"claude-haiku-4-5[1m]":{"inputTokens":2,"outputTokens":4,"cacheReadInputTokens":3800,"costUSD":0.021},"claude-haiku-4-5-20251001":{"inputTokens":521,"outputTokens":13,"costUSD":0.000586}}'
out="$(handoff chat "explain" 2>/dev/null)"
assert_contains "$out" "model: claude-haiku-4-5[1m]" "haiku as the working model is reported, not the classifier"

# No cost data at all must not produce a literal "null" in the footer.
export FAKE_CLAUDE_MODEL_USAGE='{}'
out="$(handoff chat "explain" 2>/dev/null)"
assert_not_contains "$out" "model: null" "an empty modelUsage does not leak a null"
assert_contains "$out" "model: (user default)" "an empty modelUsage falls back to the configured model"
unset FAKE_CLAUDE_MODEL_USAGE

finish
