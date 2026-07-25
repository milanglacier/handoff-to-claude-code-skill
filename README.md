# handoff-to-claude-code

A skill that lets any coding agent delegate work to Claude Code.

Third-party agents cannot spend a Claude subscription, but the `claude` CLI can. So run a cheap
model as the orchestrator and hand the expensive work to Claude Code: the orchestrator plans and
talks to the user, `claude -p` does the thinking and the editing, and the subscription pays for
it.

Two modes, because the deliverable differs:

- **agent** - Claude edits files and runs commands. The work on disk is the deliverable, so the
  orchestrator just summarizes what happened.
- **chat** - Claude's text is the deliverable, so the orchestrator relays it to the user verbatim.

Built for [pi](https://github.com/badlogic/pi-mono), but there is nothing pi-specific in it: it is
a `SKILL.md` and a bash script.

## Install

```bash
npx skills add milanglacier/handoff-to-claude-code-skill
```

Or copy `skills/handoff-to-claude-code/` into your agent's skills directory
(`~/.claude/skills/`, `~/.pi/agent/skills/`, `~/.agents/skills/`, …).

Then check the setup:

```bash
bash ~/.agents/skills/handoff-to-claude-code/scripts/handoff.sh doctor
```

Requirements: the `claude` CLI, logged in with a Claude subscription. `jq` is optional - without
it the wrapper pre-generates session ids and reads plain text instead of JSON.

## Usage

The agent drives this; you should not need to. But the wrapper is a normal CLI:

```bash
handoff.sh chat  "Why does this crash on startup?"
handoff.sh agent "Port the auth module to the new API and run the tests"
handoff.sh chat --session <id> "and what about the timeout path?"
handoff.sh agent --background "Migrate all call sites"
handoff.sh status <job-id>
```

See [`skills/handoff-to-claude-code/reference.md`](skills/handoff-to-claude-code/reference.md)
for every flag, the permission model, and troubleshooting.

## Why it is built this way

- **`claude -p`, not the Agent SDK.** The TypeScript and Python SDKs spawn this same binary with
  `--print --output-format stream-json`. Same mechanism, extra dependencies.
- **The API key is stripped by default.** Claude Code prefers `ANTHROPIC_API_KEY` over
  subscription credentials, and in `-p` mode it uses the key whenever it is present. A shell that
  exports one would quietly bill the API instead. `--no-auth-check` opts out.
- **`--permission-mode auto`, not `acceptEdits`.** In `-p` a permission prompt is a denial, and
  `acceptEdits` aborts the whole run when Claude tries a shell command it has no allow rule for.
- **Sessions are native.** `--resume <id>` continues a thread, so there is no need to replay
  transcripts back into the prompt. Session lookup is per-directory, so threads are pinned to the
  directory they started in.
- **`--bare` is never used.** It skips OAuth and keychain reads, which breaks subscription auth.

## Caveats

- Chat mode costs tokens twice: Claude writes the answer, and the orchestrator reads and rewrites
  it. That is deliberate - relaying verbatim through the orchestrator's main output stream renders
  as proper markdown, while tool output usually does not. With a cheap orchestrator the second
  pass is close to free.
- The skill triggers only when the user explicitly asks for it. It will not delegate on its own
  judgment, because that spends the subscription without being asked.
- Anthropic paused the plan to cut off SDK/CLI subscription access on 2026-06-15. If that changes,
  this stops working.

## Tests

```bash
bash tests/run.sh                 # offline, uses a fake claude binary, spends nothing
HANDOFF_LIVE=1 bash tests/run.sh  # also runs one real round-trip
```

## License

MIT
