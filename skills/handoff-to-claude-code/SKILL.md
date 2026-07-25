---
name: handoff-to-claude-code
description: Hand a task or a question to Claude Code (the `claude` CLI) and relay what it produces. Use ONLY when the user explicitly asks for it - "ask Claude Code", "hand this to claude", "let claude do it", "让 claude code 做". Covers both agentic work (Claude edits files and runs commands) and chat (Claude's answer is relayed to the user verbatim). Do not use it on your own judgment that a task looks hard, and do not use it if you are Claude Code yourself.
---

# Handoff to Claude Code

Delegates work to a local Claude Code session through `claude -p`. The user's Claude
subscription pays for it, so only run it when the user asked you to.

`SKILL_DIR` below is the directory holding this SKILL.md; the wrapper is
`$SKILL_DIR/scripts/handoff.sh`. Run `bash $SKILL_DIR/scripts/handoff.sh doctor` once on a new
machine to confirm the CLI is installed and logged in.

## Pick a mode

| | `chat` | `agent` |
| --- | --- | --- |
| The deliverable is | the text Claude writes | the work Claude does on disk |
| Claude may | read, search, run commands | everything, including edits |
| You should | relay the text **verbatim** | summarize what happened |

```bash
bash "$SKILL_DIR/scripts/handoff.sh" chat  "Why does this crash on startup?"
bash "$SKILL_DIR/scripts/handoff.sh" agent "Port the auth module to the new API and run the tests"
```

Both commands print Claude's output, then a footer:

```
--- handoff metadata ---
session: 6b1c…   model: claude-opus-5   cost_usd: 0.12   duration_s: 41   dir: /path
```

The footer is for you, not the user. Never show it to them.

For a long or multi-line prompt, pass `-` and pipe it in:

```bash
bash "$SKILL_DIR/scripts/handoff.sh" agent - <<'EOF'
Refactor the parser so that ...
EOF
```

## Relaying chat output

Everything **above** the `--- handoff metadata ---` line is Claude's answer. Reproduce it in your
final message verbatim - same words, same markdown, same order - preceded by exactly one
attribution line:

```
— via Claude Code (claude-opus-5) —
```

Do not summarize it, do not reformat it, do not merge it into your own prose, and do not append
your own commentary. The user asked for Claude's answer; your job is to carry it across intact.

## Relaying agent output

Here the deliverable is on disk, not in the text. Read the output and tell the user, in your own
words, what changed, what was verified, and what is still open. No verbatim relay needed.

## Follow-up turns

The wrapper prints a session id. Keep it, and pass it back for every follow-up so Claude keeps
its context:

```bash
bash "$SKILL_DIR/scripts/handoff.sh" chat --session 6b1c… "and what about the timeout path?"
```

Sessions are scoped to the directory the run happened in. Stay in the same directory (or pass the
same `--dir`) for every turn of a thread, or the session will not be found. `--continue` picks up
the most recent thread in the current directory when you no longer have the id.

## Long runs

An agentic task can run for many minutes and outlast your shell tool's timeout.

- If your harness has its own background-shell facility, use that - it gives the user better
  visibility. Just run the foreground command inside it.
- Otherwise add `--background`, which returns a job id immediately:

```bash
bash "$SKILL_DIR/scripts/handoff.sh" agent --background "Migrate all call sites"
bash "$SKILL_DIR/scripts/handoff.sh" status <job-id>
bash "$SKILL_DIR/scripts/handoff.sh" tail   <job-id> -n 40
bash "$SKILL_DIR/scripts/handoff.sh" wait   <job-id> --timeout 600
```

## Other options

- `--model <name>` - override the model. Without it Claude Code uses the user's configured
  default, which is usually what they want.
- `--yolo` - run with `bypassPermissions` instead of the default `auto` mode. Only when the user
  asks for it or an ordinary run was blocked by permissions.
- `--dir <path>` - run somewhere other than the current directory.
- `--no-auth-check` - by default the wrapper strips `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN`
  from the environment so the run bills the user's subscription rather than their API key. Pass
  this flag only if the user explicitly wants API-key or gateway billing.
- `-- <args>` - anything after `--` (and before the prompt) goes straight to `claude`.

## When something fails

The wrapper prints `[handoff] ERROR: …` for failures that are not worth retrying - an expired
login, an exhausted usage limit, a billing block. Report those to the user instead of retrying;
they need a human to fix them. Other failures surface Claude's own stderr and exit status.

See `reference.md` in this directory for the full flag table, the permission model, and
troubleshooting.
