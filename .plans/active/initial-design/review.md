# Review — `5781bae` feat: initial handoff-to-claude-code skill

**Scope:** the whole commit (1499 lines, 17 files). Reviewed against the real `claude` CLI on
this machine, plus the offline suite.

**Verification performed**
- `bash tests/run.sh` → all 8 cases pass (90-live skipped).
- `shellcheck -S warning` on `handoff.sh` → clean apart from one redundant pattern (see L4).
- Flags checked against the installed CLI: `--tools`, `--permission-mode auto`, `--session-id`,
  `--resume`, `--output-format` all exist and `auto` is a valid mode choice. The design notes in
  `README.md` and `reference.md` are accurate on this point.

## Overview

A `SKILL.md` plus a ~500-line bash wrapper letting a third-party orchestrator delegate to
`claude -p`, so the user's subscription pays instead of an API key. Two modes (`chat` relayed
verbatim, `agent` whose deliverable is on disk), background jobs, native `--resume` threading,
and an auth guard that strips `ANTHROPIC_API_KEY`.

The design is sound and unusually well-reasoned — testing the *argv contract* against a fake
binary is exactly the right shape for a wrapper like this, and the auth-precedence handling
(strip only when subscription evidence exists, never touch Bedrock/Vertex/Foundry) is careful
work. The problems below are concentrated in one place: the background path re-parses its own
prompt.

---

## High — background mode mangles its own argv

`run_background` reconstructs a command line and re-invokes the script
(`handoff.sh:462`, `FG_ARGV=("$MODE" "${FG_ARGV[@]}" "$PROMPT")`). That round-trip is lossy in
two ways. Both are reproduced, not theoretical.

### H1. `--background` drops the `--` passthrough separator

The `--` case at `handoff.sh:422-430` appends the passthrough args to `FG_ARGV` but never the
literal `--`. The child therefore sees them as its own options and dies at the `-*` guard
(`handoff.sh:438-440`):

```
$ handoff.sh agent --background -- --add-dir /tmp "task text"
job: job-...                       # returns success
$ handoff.sh status <job>
status: failed / exit_code: 1
stderr: [handoff] ERROR: unknown option: --add-dir (use -- to pass options through to claude)
```

Note the failure is asynchronous — the caller gets a job id and a clean exit, and only discovers
the breakage on `status`. An orchestrator that fires and forgets never finds out.

### H2. `--background` rejects any prompt whose first character is `-`

Same root cause: `$PROMPT` is re-parsed as argv, so a prompt starting with `-` hits the same
guard. This is not an exotic input — a markdown bullet list is a very natural task description,
and `SKILL.md:40-43` actively encourages multi-line heredoc prompts:

```
$ printf -- '- Refactor the parser\n- run tests\n' | handoff.sh agent --background -
stderr: [handoff] ERROR: unknown option: - Refactor the parser
- run tests (use -- to pass options through to claude)
```

The identical prompt succeeds in the foreground, so this is purely an artifact of the
reconstruction. `reference.md:28-29` documents the `-`-prefix caveat for the *parser* and says
stdin is the workaround — but stdin is exactly what H2 breaks.

### Suggested fix (covers both)

Stop passing the prompt as an argument at all; hand it to the child on stdin, which the parser
already supports via `-`. Roughly:

```bash
# in the `--` case: record only PASSTHRU, not into FG_ARGV
# in run_background, before forking:
printf '%s' "$PROMPT" >"$job_dir/prompt.txt"
FG_ARGV=("$MODE" "${FG_ARGV[@]}")
[ ${#PASSTHRU[@]} -gt 0 ] && FG_ARGV+=(-- "${PASSTHRU[@]}")
FG_ARGV+=(-)
# and in the nohup wrapper:
bash "$@" <"$job/prompt.txt" >"$job/output.txt" 2>"$job/stderr.txt"
```

This also closes a latent hazard: the forked child currently inherits the parent's stdin
undirected (`handoff.sh:243-249`), so a `-` prompt in background mode would block on a terminal.

---

## Medium

**M1. `chat` mode's isolation claim is stronger than what is enforced.**
`reference.md:42-43` says Edit and Write are withheld "so a conversation cannot rewrite the
tree." But `chat` grants `Bash` (`handoff.sh:132`) under `--permission-mode auto`, and
`echo x > file` rewrites the tree just fine. The guardrail is a speed bump against *accidental*
edits, not a boundary. Either soften the wording (recommended — Bash is genuinely useful for
investigation, and the commit message is honest that this is the tradeoff) or drop Bash from
`chat`. The current phrasing may lead a user to hand `chat` a prompt they would not hand `agent`.

**M2. The recorded pid is the wrapper's, not `claude`'s.**
`handoff.sh:250` stores `$!` of the `nohup bash` shim. `reference.md:119` tells the user to "kill
the pid in `pid`" when a job hangs — that kills the shim and orphans the actual `claude` process,
which keeps consuming quota. Either record the grandchild's pid, or use a process group and
document `kill -- -<pgid>`.

**M3. stderr from *successful* runs is silently discarded.**
`err_file` is only replayed on the failure path (`handoff.sh:183`). Deprecation notices, MCP
warnings, and partial-failure chatter from a run that still exits 0 vanish. Worth forwarding it,
or at least noting its presence in the metadata footer.

**M4. State grows without bound and is not permission-hardened.**
`sessions.tsv` and every `jobs/<id>/` tree (including full `output.txt`) accumulate forever under
`$XDG_STATE_HOME` with no pruning. Directories are created with the ambient umask
(`handoff.sh:158`, `handoff.sh:235`). Since prompts and complete model output land there, and
both routinely contain source code, consider `mkdir -m 700` on `STATE_ROOT` and a retention
sweep (e.g. drop job dirs older than N days on each run). `reference.md:84` says "Nothing is
written into the user's project," which is true and good — but the state directory deserves the
same care.

---

## Low

**L1. Job/session subcommands ignore `--dir`.** `cmd_sessions` (`handoff.sh:312`) looks only at
`$PWD`, so threads started with `--dir` are invisible to `sessions` — even though `SKILL.md:73-74`
tells the agent to use `--dir` and stay consistent. `find_job_dir` has a cross-project fallback;
`cmd_sessions` has none. Adding `--dir` to these subcommands would close the gap.

**L2. `project_slug` collisions.** `handoff.sh:47-49` maps every non-alphanumeric to `-`, so
`/a/b` and `/a-b` share a state directory and can cross-contaminate session ledgers. A short path
hash appended to the slug would remove the ambiguity.

**L3. `cut -c1-80` can split a multibyte character.** `handoff.sh:161`. Modern GNU coreutils in a
UTF-8 locale is character-aware, but under `LC_ALL=C` it truncates at byte 80 and writes invalid
UTF-8 into `sessions.tsv` (verified). Cosmetic — the ledger is display-only — but the skill
explicitly advertises Chinese trigger phrases, so mixed-script prompts are expected input.

**L4. Dead pattern in `classify_failure`.** `handoff.sh:104`: `*"run /login"*` already matches
everything `*"Please run /login"*` would (shellcheck SC2221/SC2222). Drop the third alternative.

**L5. `--timeout` is not validated.** `cmd_wait` (`handoff.sh:296`) runs `[ "$timeout" -gt 0 ]`
each iteration; a non-numeric value makes bash emit an error every 2s and — because `set -e` is
deliberately off — loop forever rather than failing fast.

**L6. Model attribution is a heuristic and says so, but has a blind spot.** The `modelUsage`
filter at `handoff.sh:196-203` excludes any key matching `haiku` to skip the auto-mode
classifier. If the user actually runs `--model haiku`, every entry is filtered, the fallback uses
`$all`, and the footer may name the classifier's haiku variant rather than the one that did the
work. Low impact (the footer is orchestrator-facing), and the inline comment explaining *why* the
filter exists is excellent — worth one more sentence about this case.

---

## Test coverage

Strong for a first commit: 7 offline cases plus an opt-in live round-trip, an isolated
`XDG_STATE_HOME`, a dependency-free fake binary, and `assert_argv_pair` doing exact adjacency
matching rather than substring matching. The auth case (`20-auth.sh`) tests the thing that
actually matters — what the child process sees in its environment.

Gaps, in priority order:

- **No background test exercises `--` or a `-`-leading prompt**, which is why H1 and H2 shipped.
  `10-composition.sh:24` covers passthrough in the foreground only; `60-background.sh` uses only
  plain prompts. A single case asserting the reconstructed child argv would have caught both.
- No `--dir` coverage anywhere, despite it being load-bearing for session scoping (L1).
- `30-output.sh` asserts the answer is byte-identical, but nothing asserts what happens when
  Claude's *own output* contains the `--- handoff metadata ---` delimiter. Since `chat` output is
  relayed verbatim to the user, a delimiter in the answer lets a footer be spoofed. Low risk,
  cheap to test.
- Test case files are mode `644` while `run.sh`/`fake-claude` are `755`; `run.sh` also `chmod +x`
  the fake binary at runtime even though git already records it executable. Harmless
  inconsistency worth tidying.

## Security notes

Nothing alarming. `--yolo` → `bypassPermissions` is clearly gated and documented as
user-requested only. The auth guard is the right default and fails open with a warning rather
than silently. Two things to keep in view: M1 (chat is not read-only) and M4 (state directory
permissions and retention). The skill description's "do not use it on your own judgment" framing
is the correct guard for something that spends the user's subscription.

## Verdict

Ship-worthy design; H1 and H2 should be fixed before this is relied on, since background mode is
the documented fallback for harnesses without their own background shell and both failures are
silent from the caller's perspective. One fix addresses both.

---

# Fixes applied

Everything above is the review as originally written and is left unedited, including the one
claim that turned out to be wrong — see H2 below.

**Scope:** H1, H2, M2, L3, L4, L5 fixed. Model detection changed and documented (L6). M1, M3, M4,
L1, L2 deliberately left alone.

**Result:** 9 offline cases pass (was 8), `handoff.sh` is shellcheck-clean, and the background
path is verified against the real CLI.

## H1 — `--background` dropped the `--` passthrough separator

`run_background` now rebuilds the separator it lost during parsing. The `--` branch no longer
copies passthrough args into `FG_ARGV`; they stay in `PASSTHRU` and are reassembled as
`-- "${PASSTHRU[@]}"` at fork time.

## H2 — prompts beginning with `-` — needed two fixes, not one

The review said this was "purely an artifact of the reconstruction" and that "the identical
prompt succeeds in the foreground." **That was wrong**, and only looked right because
`tests/fake-claude` logs its argv without parsing it. There were two independent defects:

1. *In the wrapper* (what the review found). Fixed by writing the prompt to `prompt.txt` and
   feeding it to the child on stdin as `-`, so it is never re-parsed as argv. This also removes
   a latent hang: the fork previously inherited stdin undirected.
2. *At the boundary to `claude`* (missed). The wrapper passed `"$PROMPT"` as a positional
   argument, and the real CLI rejects a leading `-` as an unknown option — in **foreground too**.
   A live run failed with:
   ```
   error: unknown option '- Count slowly from 1 to 40, writing each number to count.txt…'
   ```
   Fixed by invoking `claude "${CLAUDE_ARGS[@]}" -- "$PROMPT"`. Confirmed against the real CLI
   that `--` ends its option parsing.

The second defect was invisible to the whole offline suite by construction, because a stub that
does not parse options cannot reject one. `10-composition.sh` now asserts the argv *shape*
(`--` immediately precedes the prompt), which is the only thing a stub can check here.

## M2 — killing a job left `claude` running

Was worse than reported: the fork inherited the *parent's* process group, so there was no group
to signal without killing the caller.

- `set -m` before the fork puts the job in its own process group; `pgid` replaces `pid` in the
  job directory.
- New `handoff.sh kill <job-id>`: `SIGTERM` to the group, `SIGKILL` after 10s. A `killed` marker
  file lets the shim distinguish a kill from an ordinary failure.
- `status` and `wait` now detect a job whose group is gone that never recorded an exit code, and
  report `died` instead of `running` forever. This is the "stays running forever" symptom that
  `reference.md` previously documented without explanation.
- `</dev/null` on the fork is load-bearing, not tidying: a background process group that reads
  the terminal takes `SIGTTIN` and stops, which would look exactly like a hang.

Verified live: with a real `claude` in the group, `kill` reaped all four processes and the job
reported `killed`.

## L3, L4, L5

- **L3** — new `prompt_excerpt()` helper used by both truncation sites (80 chars for the ledger,
  200 for `cmd`). `cut -c` still does the cut, then `iconv -c` drops any partial UTF-8 sequence
  it leaves under `LC_ALL=C`. No hard dependency: without `iconv` the worst case is the old
  behaviour, one mangled character in a display-only field.
- **L4** — dead `*"Please run /login"*` alternative removed. `handoff.sh` is now shellcheck-clean
  at `-S warning`.
- **L5** — `--timeout` is validated as a whole number before `cmd_wait` runs, instead of erroring
  once every 2s inside the loop and never terminating.

## Model detection — semantics change (relates to L6)

**`model:` in the footer is now the most expensive entry in `modelUsage`, not the busiest
non-haiku entry by token count.** Nine lines of jq collapse to one:

```jq
.model // (.modelUsage // {} | to_entries | max_by(.value.costUSD // 0) | .key) // empty
```

Token counts cannot separate the working model from the `auto`-mode safety classifier, because
the working model's context is nearly all cache reads and those are billed apart from
`inputTokens`. Measured on a real one-line run:

| model | inputTokens + outputTokens | costUSD |
| --- | --- | --- |
| `claude-haiku-4-5-20251001` (classifier) | 534 | 0.00059 |
| `claude-opus-5[1m]` (did the work) | 6 | 0.03811 |

Cost points the right way by 65×; tokens point the wrong way by 89×. This also removes L6's
blind spot rather than merely tolerating it: the old name-based filter discarded the real answer
along with the classifier whenever haiku *was* the working model.

Documented in `reference.md` under a new **The metadata footer** section, including that
`costUSD` is notional on a subscription (nothing is charged — it is used only as a proxy for
which model did the heavy lifting), and that an empty `modelUsage` yields `(user default)`,
never the string `null`. `SKILL.md` now tells the orchestrator to take `model:` as given for its
attribution line rather than reasoning about token counts itself.

Not verified: whether `costUSD` is per-turn or cumulative under `--resume`. It applies equally to
the old token-based version, so it is not a regression.

## Test changes

New `65-kill.sh` (7 assertions: group leadership, whole-tree reaping, `killed` vs `died`,
`wait` not spinning on a hard-killed job). `60-background.sh` gains the two H1/H2 regressions and
the L5 check; `10-composition.sh` the `--` separator shape; `40-sessions.sh` a CJK truncation
check under `LC_ALL=C`; `30-output.sh` three model-detection cases including haiku-as-working-model
and empty `modelUsage`.

`tests/fake-claude` now emits `costUSD` and `cacheReadInputTokens`. The old fixture carried 2 of
the 10 fields the CLI actually returns, which is how the L6 gap stayed invisible — and the
`--`-separator defect shows the stub can still only catch what argv shape reveals. Worth keeping
in mind when adding cases: the offline suite tests the contract, not the CLI's acceptance of it.

## Not addressed (per instructions)

M1 (chat's Bash makes the "cannot rewrite the tree" claim overstated), M3 (stderr discarded on
success), M4 (unbounded, unhardened state directory), L1 (`--dir` ignored by job/session
subcommands), L2 (`project_slug` collisions). M1 and M4 are the two I would pick up next: M1 is
a docs-only change, and M4 is the one with a privacy dimension.

---

# Fixes applied — round 2

L1 and M1 (docs only). Everything above is left unedited. 10 offline cases pass (was 9),
`handoff.sh` still shellcheck-clean.

## L1 — job and session subcommands ignored `--dir`

`status`, `tail`, `wait`, `kill`, `sessions` and `doctor` now all accept `--dir <path>`, pulled
out by a shared `parse_query_opts()` that leaves the remaining arguments in `REST`. `find_job_dir`,
`cmd_sessions` and `cmd_doctor` resolve against `QUERY_DIR` instead of `$PWD`.

`doctor` was not in the original finding but belonged in the same change: it prints
`state_dir:`, and without `--dir` it would have reported a different directory than the one
`sessions` was reading from.

Two things fell out of doing this:

- **The `status_cmd` hint printed by `--background` was unusable for a `--dir` run.** It emitted
  `handoff.sh status <job-id>` with no `--dir`, so following it verbatim missed the job's own
  state directory and only worked by falling through to the cross-project search. It now carries
  `--dir` whenever the job ran somewhere other than the cwd.
- **`-n` is now validated** the same way `--timeout` was in L5. Both flags moved into `REST`, and
  leaving one checked and the other not would have been an odd seam.

Worth being explicit about what did *not* change: `status`, `tail`, `wait` and `kill` already had
a cross-project fallback that searches every project for the job id, so they mostly worked
without `--dir` before and still do. `sessions` and `doctor` have no such fallback — they were,
and remain, cwd-scoped unless told otherwise. That asymmetry is now documented rather than
implicit.

## M1 — `chat` is not a sandbox (documentation only)

No behaviour change; `chat` still passes `--tools "Read,Grep,Glob,Bash,WebSearch,WebFetch"`.

`reference.md` claimed Edit and Write are withheld "so a conversation cannot rewrite the tree."
That is not what withholding them achieves: Bash is in the list, `--permission-mode auto`
auto-approves tool calls, and `printf 'x' > file` rewrites the tree without either tool. The text
now says withholding them removes the obvious path rather than every path, states plainly that
this is not a sandbox, and points at the two real limits — `--tools` covers built-in tools only
(MCP is unaffected), and it cannot constrain what a shell command does once Bash is granted. It
closes with the honest alternative: if a prompt genuinely must not touch the tree, run it against
a copy via `--dir` rather than trusting the tool list.

`SKILL.md` gets one line under the mode table, since that is what the orchestrator actually
reads: `chat` is the right mode when nothing *should* change, not a guarantee that nothing *can*.

The factual statements elsewhere — the commands table's "No Edit/Write tools" and the usage
line's "(no Edit/Write)" — were left as they are. They describe what is passed, and they are
accurate.

## Test changes

New `45-dir.sh`, 11 assertions: a `--dir` thread is invisible to a bare `sessions` and visible to
`sessions --dir`; `doctor --dir` reports a different state directory; a backgrounded `--dir` job
is reachable by `status`/`wait`/`tail --dir`; the printed `status_cmd` carries `--dir`; the
cross-project fallback still covers a caller who forgot it; and `--dir`, `-n` and `--timeout`
all reject bad input.

## Still not addressed

M3 (stderr discarded on a successful run), M4 (unbounded, unhardened state directory), L2
(`project_slug` collisions). M4 remains the one with a privacy dimension — prompts and full model
output accumulate under `$XDG_STATE_HOME` with the ambient umask and no retention policy.
