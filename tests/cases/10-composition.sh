#!/usr/bin/env bash
# The command line handed to `claude` is the whole contract; check it directly.
. "$(dirname "$0")/../lib.sh"

with_subscription

handoff chat "hello" >/dev/null
assert_argv_has "-p"
assert_argv_pair "--permission-mode" "auto"
assert_argv_pair "--tools" "Read,Grep,Glob,Bash,WebSearch,WebFetch"
assert_argv_lacks "--bare"
assert_argv_has "hello"

handoff agent "do the thing" >/dev/null
assert_argv_pair "--permission-mode" "auto"
assert_argv_lacks "--tools"
assert_argv_has "do the thing"

handoff agent --yolo "risky" >/dev/null
assert_argv_pair "--permission-mode" "bypassPermissions"

handoff chat --model sonnet "hi" >/dev/null
assert_argv_pair "--model" "sonnet"

handoff agent -- --add-dir /tmp --effort high "task" >/dev/null
assert_argv_pair "--add-dir" "/tmp"
assert_argv_pair "--effort" "high"
assert_argv_has "task"

out="$(printf 'from stdin' | handoff chat - 2>/dev/null)"
assert_argv_has "from stdin"
assert_contains "$out" "handoff metadata" "stdin prompt still produces a metadata footer"

# The prompt must reach claude after a -- separator. The real CLI rejects a
# prompt starting with `-` as an unknown option otherwise; the stub does not
# parse options, so only the argv shape can catch this.
assert_argv_pair "--" "from stdin"

# Single-line, because the argv log is one argument per line and assert_argv_pair
# matches line-wise. 60-background.sh covers the multi-line case end to end.
printf -- '- a bullet of a task' | handoff agent - >/dev/null 2>&1
assert_argv_pair "--" "- a bullet of a task"

out="$(handoff chat --session abc --continue "x" 2>&1)"
assert_contains "$out" "mutually exclusive" "--session and --continue are rejected together"

out="$(handoff frobnicate 2>&1)"
assert_contains "$out" "unknown command" "unknown commands are rejected"

finish
