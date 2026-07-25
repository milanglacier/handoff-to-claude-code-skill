# handoff.sh reference

## Commands

| Command | Purpose |
| --- | --- |
| `chat [options] <prompt\|->` | Ask a question. No Edit/Write tools. Output is meant to be relayed verbatim. |
| `agent [options] <task\|->` | Do the work. All tools available. |
| `status <job-id>` | Report a background job: status, exit code, output path. |
| `tail <job-id> [-n N]` | Last N lines (default 50) of a background job's output. |
| `wait <job-id> [--timeout S]` | Block until the job ends, print its output, exit with its code. Exits 2 on timeout. |
| `sessions` | Last 20 threads recorded for the current directory. |
| `doctor` | Check the CLI, authentication, jq, and the state directory. |

## Options for `chat` / `agent`

| Option | Effect |
| --- | --- |
| `--session <id>` | Resume a specific thread (`claude --resume`). |
| `--continue` | Resume the most recent thread in this directory (`claude --continue`). Mutually exclusive with `--session`. |
| `--model <name>` | `claude --model`. Omitted by default so the user's configured model wins. |
| `--dir <path>` | Directory to run in. Defaults to the cwd. Threads are scoped to it. |
| `--background` | Fork the run, print a job id, return immediately. |
| `--yolo` | `--permission-mode bypassPermissions` instead of `auto`. |
| `--no-auth-check` | Leave `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` in place. |
| `-- <args...>` | Passed straight to `claude`. Must come **before** the prompt: `agent -- --add-dir ../lib "task"`. |

A prompt of `-` is read from stdin. A prompt that begins with `-` must be passed on stdin,
since the parser would otherwise read it as an option.

## What gets sent to `claude`

Both modes:

- `-p` - non-interactive.
- `--permission-mode auto` (or `bypassPermissions` with `--yolo`). `auto` auto-approves tool
  calls with background safety checks. This matters: in `-p` a permission prompt is a denial, and
  `acceptEdits` *aborts the run* when Claude attempts a shell command with no allow rule.
- `--output-format json` when `jq` is available, so the session id and cost can be read back.

`chat` additionally passes `--tools "Read,Grep,Glob,Bash,WebSearch,WebFetch"`. Bash is included
so Claude can investigate before answering; Edit and Write are withheld so a conversation cannot
rewrite the tree. Note that `--tools` restricts built-in tools only - MCP tools are unaffected.

`--bare` is never passed: it skips OAuth and keychain reads, which breaks subscription auth.

## Authentication

Claude Code's credential precedence puts `ANTHROPIC_API_KEY` above subscription OAuth, and in
`-p` mode the key is used whenever it is present. A shell that exports an API key would therefore
silently bill the API instead of the subscription.

So, unless `--no-auth-check` is passed, the wrapper:

1. Looks for subscription evidence: `CLAUDE_CODE_OAUTH_TOKEN`, or
   `${CLAUDE_CONFIG_DIR:-~/.claude}/.credentials.json`, or the macOS keychain item
   `Claude Code-credentials`.
2. If found, unsets `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` for the child process and says
   so on stderr.
3. If not found, changes nothing and warns that the run will use whatever key is in the
   environment.

`CLAUDE_CODE_USE_BEDROCK` / `_VERTEX` / `_FOUNDRY` outrank everything else, so they are reported
but never unset.

## Sessions

`claude` scopes session lookup to the invocation directory and its git worktrees, so every turn
of a thread must run from the same directory.

With `jq`, the session id comes back in the result JSON. Without `jq`, the wrapper pre-generates
a UUID and passes `--session-id`, which achieves the same thing with plain-text output.

## State

Everything lives under `${XDG_STATE_HOME:-~/.local/state}/handoff-to-claude-code/<slug>/`, where
`<slug>` is the working directory with non-alphanumerics replaced by `-`:

```
sessions.tsv          started_at, session_id, mode, first 80 chars of the prompt
jobs/<job-id>/        cmd, pid, started_at, status, exit_code, output.txt, stderr.txt
```

Nothing is written into the user's project.

## Environment overrides

| Variable | Purpose |
| --- | --- |
| `HANDOFF_CLAUDE_BIN` | Path to the `claude` binary. Default: `claude` on `PATH`. |
| `HANDOFF_JQ_BIN` | Path to `jq`. Point it at a nonexistent path to force the no-jq code path. |
| `XDG_STATE_HOME` | Where state is written. |
| `CLAUDE_CONFIG_DIR` | Where subscription credentials are looked for. |

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | Wrapper error (bad arguments, unusable prompt) or `claude` reported `is_error`. |
| 2 | `wait` timed out while the job was still running. |
| other | Propagated from `claude`. |

## Troubleshooting

**`ERROR: the Claude Code login has expired`** - a human must run `claude` interactively and
`/login`. Nothing the agent does will fix it.

**`ERROR: the subscription usage limit was hit`** - wait for the reset. Retrying immediately just
burns time.

**`no subscription credentials found`** - either the user is not logged in, or
`CLAUDE_CONFIG_DIR` points somewhere unexpected. Run `doctor`.

**The run aborted partway with a permission complaint** - retry with `--yolo` after checking with
the user.

**A background job stays `running` forever** - `claude` may be waiting on something. Inspect
`stderr.txt` in the job directory (path from `status`) and kill the pid in `pid`.
