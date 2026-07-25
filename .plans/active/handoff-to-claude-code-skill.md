# handoff-to-claude-code — a skill that lets any agent delegate to Claude Code

## Context

Anthropic's subscription plan does not permit third-party agents to consume it, but
the `claude` CLI (`claude -p`) and the Agent SDK still do (the June 15 2026 change was
paused). That makes a useful split possible: run a cheap third-party harness
(pi with `deepseek-v4-flash`) as the orchestrator, and hand the expensive work to
Claude Code, which bills against the subscription.

This project packages that pattern as a portable skill: a `SKILL.md` plus a bash
wrapper, published as a standalone git repo installable with `npx skills`. Primary
target is pi-coding-agent, but nothing in it is pi-specific.

### Facts established during research (these drove the design)

- **`claude -p` beats the Agent SDK here.** The TS/Python SDKs spawn this same `claude`
  binary with `--print --output-format stream-json`. Identical from a
  "will it stay whitelisted" standpoint, so take the one with zero extra dependencies.
- **`ANTHROPIC_API_KEY` silently hijacks billing.** Docs: "In non-interactive mode (`-p`),
  the key is always used when present." The login shell here exports a real 108-char key
  from `creds/api-keys.sh`, which pi inherits — so an unguarded `claude -p` would bill the
  API, defeating the entire premise. The wrapper must strip it.
- **`--bare` must never be used** — it skips OAuth/keychain reads, so subscription auth
  breaks.
- **Multi-turn is native**; no tee-file replay needed:
  `sid=$(claude -p ... --output-format json | jq -r .session_id)` then
  `claude -p "..." --resume "$sid"`. Session lookup is scoped to the invocation directory,
  so every turn of a thread must run from the same `--dir`.
- **`acceptEdits` aborts the run** when Claude attempts a shell command that has no allow
  rule. `--permission-mode auto` auto-approves with background safety checks and covers
  Bash *and* MCP in one flag — chosen as the agentic default.
- **`mcp__*` is invalid in allow rules** (skipped with a warning; allow globs must be
  anchored as `mcp__<server>__*`). Another reason to use `auto` rather than enumerate.
- `--tools` restricts built-in tools only and does not affect MCP tools.

## Decisions (agreed with the user)

| Topic | Decision |
| --- | --- |
| Transport | `claude -p`, never the SDK, never `--bare` |
| Delivery | one repo at `~/Desktop/handoff-to-claude-code-skill`, canonical `skills/<name>/SKILL.md` layout, installable via `npx skills` |
| Script | a single bash wrapper for everything; `jq` optional with a graceful fallback |
| Modes | `chat` (no Edit/Write, but Bash allowed) and `agent` (unrestricted, auto permission mode) |
| chat output | orchestrator reproduces Claude's text **verbatim**, prefixed with one attribution line. Accepting the double-billing is deliberate: the main output stream renders markdown properly, tool output does not |
| Output shaping | none — no `--append-system-prompt` in either mode |
| Permissions | agentic default `--permission-mode auto`; `--yolo` → `bypassPermissions`, no extra ceremony |
| Model | inherit user config by default, `--model` overrides |
| Sessions | explicit `--session <id>`, with `--continue` as a convenience |
| Long tasks | agent decides; prefer the harness's own background-shell tool, fall back to the wrapper's `--background` |
| State | `${XDG_STATE_HOME:-~/.local/state}/handoff-to-claude-code/<project-slug>/` |
| Auth | detect subscription → strip `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN`; no subscription → touch nothing; `--no-auth-check` opts out |
| Triggering | only on an explicit user request — never autonomous delegation |

## Repo layout

```
~/Desktop/handoff-to-claude-code-skill/
├── README.md                                   # background, npx skills install, limits
├── LICENSE                                     # MIT
├── skills/
│   └── handoff-to-claude-code/
│       ├── SKILL.md
│       ├── reference.md                        # full flag table, permission matrix, troubleshooting
│       └── scripts/handoff.sh                  # the wrapper
└── tests/
    ├── run.sh                                  # plain-bash runner, no deps
    ├── fake-claude                             # stub binary shimmed onto PATH
    └── cases/*.sh
```

`skills/<name>/SKILL.md` is the layout the `npx skills` CLI walks by default, so
`npx skills add milanglacier/handoff-to-claude-code-skill` finds it, and the repo can grow a
second skill later without restructuring. `reference.md` and `scripts/` live inside the skill
directory because installers copy that directory and nothing above it.

## `scripts/handoff.sh` — interface

```
handoff.sh chat  [opts] <prompt|->     # answer for a human; read-only tools
handoff.sh agent [opts] <task|->       # do the work; auto permission mode
handoff.sh status <job-id>
handoff.sh tail   <job-id> [-n N]
handoff.sh wait   <job-id> [--timeout S]
handoff.sh sessions                    # recent threads for this project
handoff.sh doctor                      # preflight self-check
```

Shared options: `--session <id>`, `--continue`, `--model <m>`, `--dir <path>`,
`--background`, `--yolo`, and `--` to pass any remaining args straight to `claude`
(e.g. `-- --add-dir ../lib`). A prompt of `-` is read from stdin, so callers can use a
heredoc instead of fighting shell quoting.

### Behaviour

1. **Auth guard (runs first, every invocation).** Subscription is present if
   `CLAUDE_CODE_OAUTH_TOKEN` is set, or `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json`
   exists, or (macOS) the `Claude Code-credentials` keychain item exists. If so, `unset
   ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN` and note it on stderr. If not, change nothing.
   Warn on stderr if `CLAUDE_CODE_USE_BEDROCK|VERTEX|FOUNDRY` is set (those outrank
   everything and mean the run is not on the subscription).
   `--no-auth-check` skips this step entirely — the environment is passed through as-is, which is
   the escape hatch for anyone who deliberately wants API-key billing or a gateway/proxy setup.
   Documented in both `SKILL.md` and `reference.md`, with `SKILL.md` stating that the orchestrator
   uses it only when the user asks for it.
2. **Mode flags.** Both modes use `--permission-mode auto` (or `bypassPermissions` with
   `--yolo`) so nothing aborts on an unapproved command — in `-p` a prompt is a denial.
   - `chat`: `--tools "Read,Grep,Glob,Bash,WebSearch,WebFetch"`. Bash is allowed so Claude can
     actually investigate before answering; Edit/Write are withheld so a "conversation" cannot
     rewrite the tree.
   - `agent`: tools unrestricted.
3. **Session handling.** With `jq`: `--output-format json`, print `.result`, read
   `.session_id`/`.total_cost_usd`/`.is_error`. Without `jq`: pre-generate a UUID
   (`uuidgen` → `/proc/sys/kernel/random/uuid` → python fallback), pass `--session-id`, and use
   `--output-format text`. Either way append a row to `sessions.tsv` in the state dir.
4. **Output framing.** Claude's text is printed first and untouched, then a footer:

   ```
   --- handoff metadata ---
   session: <id>   model: <m>   cost: <usd>   duration: <s>   job: <id>
   ```

   The footer is what makes the session id discoverable; `SKILL.md` is responsible for telling
   the agent that everything above the delimiter is Claude's answer and the footer is for the
   agent's eyes only.
5. **Background.** `--background` forks a `nohup`'d run into
   `<state>/jobs/<job-id>/` (`cmd`, `pid`, `status`, `exit_code`, `output.txt`, `stderr.txt`,
   `meta.json`) and returns the job id immediately; `status`/`tail`/`wait` read that directory.
6. **Error surfacing.** Map non-zero exits and known stderr signatures (login expired, usage
   limit, org not allowed) to an explicit `[handoff] ERROR: …` line that tells the orchestrator
   whether retrying is pointless. Propagate `claude`'s exit code otherwise.

## `SKILL.md` — content contract

- Frontmatter `description` fires **only on an explicit user request** ("ask Claude Code",
  "hand this to claude", "让 claude code 做") — never on the model's own judgment that a task
  is hard.
- Two modes, stated as an output-handling protocol, not just a flag difference:
  - **chat** — the deliverable is the text. Reproduce everything above
    `--- handoff metadata ---` *verbatim* in the final answer, preceded by exactly one
    attribution line, e.g. `— via Claude Code (opus) —`. Do not summarize, reformat, or merge it
    with your own prose. Never show the metadata footer to the user.
  - **agent** — the deliverable is the work on disk. Read the output and summarize it for the
    user; verbatim relay is unnecessary.
- Multi-turn: the wrapper prints a session id, keep it in context, pass it back with
  `--session <id>`, and always use the same `--dir`.
- Foreground vs background: prefer the harness's native background-shell tool if it has one
  (pi does); use `--background` only as a fallback. Warn that long agentic runs exceed a
  default bash-tool timeout.
- Auth: the wrapper strips `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN` by default so the run bills
  the subscription; `--no-auth-check` disables that, and the orchestrator passes it only when the
  user explicitly asks to bill an API key / gateway instead.
- Guardrail: if you *are* Claude Code, do not use this skill (no recursion).
- Pointer to `reference.md` for flags and troubleshooting, and to `handoff.sh doctor` for setup.

## Tests

`tests/run.sh` is a dependency-free bash runner (no bats). It puts `tests/fake-claude` first on
`PATH`: a stub that appends its full argv to `$FAKE_CLAUDE_ARGV_LOG`, then emits either canned
`--output-format json` or plain text, and can be told to exit non-zero or print a known failure
signature. Every case runs against a temp `XDG_STATE_HOME`, so nothing touches real state and no
test spends subscription quota.

Cases:

1. **Command composition** — `chat` sends `--tools "Read,Grep,Glob,Bash,WebSearch,WebFetch"` and
   no Edit/Write; `agent` sends no `--tools`; both send `--permission-mode auto`; `--yolo` swaps
   in `bypassPermissions`; `--model` and post-`--` passthrough args land verbatim; `--bare` is
   never emitted.
2. **Auth guard** — with a stub credentials file present and `ANTHROPIC_API_KEY` exported, the
   child process sees no key; with no subscription evidence, the key survives untouched;
   `--no-auth-check` leaves the key in place even when subscription evidence exists; a
   `CLAUDE_CODE_USE_BEDROCK` value produces the warning.
3. **Output framing** — stdout reproduces the stub's answer byte-for-byte above the delimiter,
   including markdown and trailing whitespace, and the footer carries the session id.
4. **Sessions** — first call records a row in `sessions.tsv`; `--session <id>` emits `--resume
   <id>`; `--continue` emits `--continue`; the two are mutually exclusive.
5. **jq fallback** — with `jq` hidden from `PATH`, the wrapper pre-generates a UUID, passes
   `--session-id`, and still reports a usable session id.
6. **Background lifecycle** — `--background` returns a job id immediately, the job directory has
   the expected files, and `status`/`tail`/`wait` report running → done with the right exit code;
   a failing stub yields `failed` and a non-zero `wait`.
7. **Error mapping** — stub exits with a usage-limit / expired-login signature; the wrapper emits
   the matching `ERROR:` line and a non-zero exit.
8. **Live smoke test**, skipped unless `HANDOFF_LIVE=1` — one real `chat` call plus one
   `--session` follow-up, asserting the follow-up sees turn one. This is the only case that
   spends quota.

## Verification

1. `bash tests/run.sh` — all offline cases green; then `HANDOFF_LIVE=1 bash tests/run.sh`.
2. `bash skills/handoff-to-claude-code/scripts/handoff.sh doctor` — reports `claude` on PATH and version, auth mode
   (subscription vs API key), whether `ANTHROPIC_API_KEY` was detected and stripped, `jq`
   presence, and the resolved state dir.
2. Chat, single turn: `handoff.sh chat "In one sentence, what is this repo?"` in a scratch git
   repo. Confirm stdout is pure prose and the metadata line goes to stderr.
3. Multi-turn: capture the session id, then `handoff.sh chat --session <id> "and who wrote it?"`
   from the same directory; confirm the follow-up shows awareness of turn one.
4. Agentic, foreground: in a scratch dir, `handoff.sh agent "create hello.py that prints hi and
   run it"` — confirms `--permission-mode auto` actually lets Bash and file writes through
   without an abort (this is the flag most likely to need adjustment).
5. Background: same task with `--background`; then `status`, `tail`, `wait`.
6. Billing guard: run once with `ANTHROPIC_API_KEY` exported in the shell and confirm doctor
   reports it stripped; run once with a fake `CLAUDE_CODE_USE_BEDROCK=1` and confirm the warning.
7. Install path: `npx skills add <local path or GitHub repo>` into a scratch config dir, then
   drive one chat turn end-to-end from `pi -p` to prove the SKILL.md is discoverable and the
   script path resolves after installation.

## Optional follow-up (not part of this change)

Add a `handoff-to-claude-code` entry to `bin/download-agent-skills` in the dotfiles repo once
the GitHub repo exists, so it installs alongside the other skills into
`~/.agents/skills` / `~/.pi/agent/skills`.
