#!/usr/bin/env bash
# The whole point of the skill is that the run bills the subscription, so the
# child process must not see an API key.
. "$(dirname "$0")/../lib.sh"

child_env() { grep "^$1=" "$FAKE_CLAUDE_ENV_LOG" | cut -d= -f2-; }

with_subscription
export ANTHROPIC_API_KEY="sk-ant-test-key"
export ANTHROPIC_AUTH_TOKEN="bearer-test"

err="$(handoff chat "hi" 2>&1 >/dev/null)"
assert_eq "$(child_env ANTHROPIC_API_KEY)" "<unset>" "API key stripped when a subscription exists"
assert_eq "$(child_env ANTHROPIC_AUTH_TOKEN)" "<unset>" "auth token stripped when a subscription exists"
assert_contains "$err" "stripped ANTHROPIC_API_KEY" "the strip is reported on stderr"

handoff chat --no-auth-check "hi" >/dev/null 2>&1
assert_eq "$(child_env ANTHROPIC_API_KEY)" "sk-ant-test-key" "--no-auth-check leaves the key alone"

without_subscription
err="$(handoff chat "hi" 2>&1 >/dev/null)"
assert_eq "$(child_env ANTHROPIC_API_KEY)" "sk-ant-test-key" "no subscription means the environment is untouched"
assert_contains "$err" "no subscription credentials found" "the fallback to API billing is announced"

with_subscription
export CLAUDE_CODE_USE_BEDROCK=1
err="$(handoff chat "hi" 2>&1 >/dev/null)"
assert_contains "$err" "CLAUDE_CODE_USE_BEDROCK is set" "cloud-provider vars are flagged"
unset CLAUDE_CODE_USE_BEDROCK

# An OAuth token is also subscription evidence, even with no credentials file.
without_subscription
export CLAUDE_CODE_OAUTH_TOKEN="oauth-test"
handoff chat "hi" >/dev/null 2>&1
assert_eq "$(child_env ANTHROPIC_API_KEY)" "<unset>" "CLAUDE_CODE_OAUTH_TOKEN counts as a subscription"

finish
