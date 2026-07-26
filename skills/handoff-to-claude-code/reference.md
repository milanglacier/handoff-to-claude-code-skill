# handoff.py reference

## Commands

| Command | Purpose |
| --- | --- |
| `chat [options] <prompt\|->` | Ask a question. No Edit/Write tools. Output is meant to be relayed verbatim. |
| `agent [options] <task\|->` | Do the work. All tools available. |
| `status <job-id>` | Report a background job: status, exit code, output path. |
| `tail <job-id> [-n N]` | Last N lines (default 50) of a background job's output. |
| `wait <job-id> [--timeout S]` | Block until the job ends, print its output, exit with its code. Exits 2 on timeout. `S` must be a whole number of seconds. |
| `kill <job-id>` | Stop a background job: `SIGTERM` to its process group, `SIGKILL` after 10s. Reaps `claude` and anything it spawned. |
| `sessions` | Last 20 threads recorded for the current directory. |
| `doctor` | Check the CLI, authentication, the interpreter, and the state directory. |

`status`, `tail`, `wait`, `kill`, `sessions` and `doctor` also accept `--dir <path>`. Jobs and
threads are scoped to the directory they ran in, so a run started with `--dir` has to be queried
with the same `--dir`:

```bash
handoff.py agent --dir ../service --background "Migrate the call sites"
handoff.py status   --dir ../service <job-id>
handoff.py sessions --dir ../service
```

`status`, `tail`, `wait` and `kill` fall back to searching every project for the job id, so they
usually work without it. `sessions` and `doctor` have no such fallback - without `--dir` they
report on the current directory only.

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
- `--output-format json`, always, so the session id and cost can be read back.

`chat` additionally passes `--tools "Read,Grep,Glob,Bash,WebSearch,WebFetch"`. Bash is included
so Claude can investigate before answering; Edit and Write are withheld so a conversation does
not *casually* edit files.

**This is not a sandbox.** Bash is in the list, `--permission-mode auto` auto-approves tool
calls, and `printf 'x' > file` rewrites the tree perfectly well without Edit or Write. Withholding
them removes the obvious path, not every path. Two further limits worth knowing: `--tools`
restricts built-in tools only, so MCP tools are unaffected; and it cannot constrain what a shell
command does once Bash is granted.

So treat `chat` as "a run that should not need to change anything", not as a guarantee that it
cannot. If a prompt genuinely must not touch the tree, run it somewhere the tree is not - a
`--dir` pointing at a copy - rather than relying on the tool list.

`--bare` is never passed: it skips OAuth and keychain reads, which breaks subscription auth.

## The metadata footer

Every `chat` / `agent` run ends with a footer meant for the calling agent, not the user:

```
--- handoff metadata ---
session: 6b1c…   model: claude-opus-5[1m]   cost_usd: 0.12   duration_s: 41   dir: /path
```

**`model:` is the most expensive entry in `modelUsage`.** The result JSON has no top-level
`model` field, so the wrapper infers which model did the work, and cost is what it sorts on.

This matters because `--permission-mode auto` runs a safety classifier on a small haiku model,
so a second model shows up in `modelUsage` on every run whether or not you asked for it. Token
counts cannot tell the two apart, because the working model's context is nearly all cache reads
and those are counted separately from `inputTokens`. On a real one-line run:

| model | inputTokens + outputTokens | costUSD |
| --- | --- | --- |
| `claude-haiku-4-5-20251001` (classifier) | 534 | 0.00059 |
| `claude-opus-5[1m]` (did the work) | 6 | 0.03811 |

Sorting on tokens picks the classifier; sorting on cost picks the model that did the work.

Two consequences worth knowing:

- On a subscription run `costUSD` is a notional price - nothing is actually charged. It is used
  here only as a proxy for *which model did the heavy lifting*, which it reports faithfully.
  `cost_usd` in the footer is likewise indicative, not a bill.
- When `modelUsage` is empty or absent, `model:` falls back to whatever `--model` was passed, or
  the literal `(user default)`. It is never the string `null`.

An earlier version of this wrapper picked the busiest model by token count after discarding any
model whose name matched `haiku`. That misreported whenever haiku was itself the working model,
since the filter then discarded the real answer along with the classifier. Cost has no such
blind spot and needs no name matching.

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

The session id comes back in the result JSON, which the wrapper parses with the standard
library.

## State

Everything lives under `${XDG_STATE_HOME:-~/.local/state}/handoff-to-claude-code/<slug>/`, where
`<slug>` is the working directory with non-alphanumerics replaced by `-`:

```
sessions.tsv          started_at, session_id, mode, first 80 chars of the prompt
jobs/<job-id>/        cmd, pgid, prompt.txt, started_at, status,
                      exit_code, output.txt, stderr.txt
```

Nothing is written into the user's project.

`pgid` is a process *group*, not a pid: the job is forked under job control so the whole
tree - the wrapper, `claude`, and anything `claude` spawns - shares one group and can be
signalled together. `prompt.txt` holds the prompt, which is fed to the background run on
stdin rather than passed as an argument.

A job's `status` is one of:

| Status | Meaning |
| --- | --- |
| `running` | Still going. |
| `done` | Finished, exit code 0. |
| `failed` | Finished, non-zero exit code. |
| `killed` | Stopped by `handoff.py kill`. |
| `died` | The process group vanished without recording an exit code - killed from outside, or OOM. |

## Environment overrides

| Variable | Purpose |
| --- | --- |
| `HANDOFF_CLAUDE_BIN` | Path to the `claude` binary. Default: `claude` on `PATH`. |
| `XDG_STATE_HOME` | Where state is written. |
| `CLAUDE_CONFIG_DIR` | Where subscription credentials are looked for. |

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | Wrapper error (bad arguments, unusable prompt) or `claude` reported `is_error`. Also `wait` on a job that died without recording an exit code. |
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
`stderr.txt` in the job directory (path from `status`), then `handoff.py kill <job-id>`, which
signals the job's whole process group. Killing the recorded pid by hand is not enough: it would
leave `claude` running and still consuming quota.

**A job reports `died`** - its process group disappeared without recording an exit code. It was
killed from outside the wrapper, or the OOM killer took it. `output.txt` holds whatever was
produced before it went.
