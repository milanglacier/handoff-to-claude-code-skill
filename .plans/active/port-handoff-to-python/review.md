# Review — Port `handoff.sh` to Python

**Scope:** the Python rewrite in
`skills/handoff-to-claude-code/scripts/handoff.py`, reviewed against the previous shell
implementation, the offline test suite, and the intended Tau → Pi RPC → handoff execution path.

**Verification performed**

- `python3 tests/test_handoff.py` → 9 offline tests pass; the opt-in live test is skipped.
- `python3 -m py_compile skills/handoff-to-claude-code/scripts/handoff.py` → pass.
- `quick_validate.py skills/handoff-to-claude-code` → `Skill is valid!`.
- `git diff --check` → pass.

## Findings

### P2. Update `PWD` when changing the Claude child working directory

`subprocess.run(..., cwd=o["workdir"], env=env)` changed Claude's kernel-level working
directory but passed the caller's `PWD` through unchanged. With `--dir`, Claude, hooks, MCP
servers, or subprocesses that inspect `PWD` could therefore see the caller's project while
relative filesystem operations ran in the requested project.

This is especially relevant to the intended Tau/Pi integration:

| Boundary | Kernel cwd | Inherited `PWD` before this fix |
| --- | --- | --- |
| Tau server → Pi RPC | Tau session directory | Tau server launch directory |
| Pi → Bash tool | Pi session directory | Tau server launch directory |
| Bash → handoff | Pi session directory | Pi session directory, because Bash repairs it |
| handoff `--dir D` → Claude | `D` | Pi session directory |

Tau currently spawns Pi with `cwd: this.cwd` and an unchanged copy of `process.env`. Pi 0.82.0
also copies its environment when spawning Bash. Bash repairs an inconsistent `PWD` at startup,
which makes the default handoff path work, but this is incidental shell behavior rather than a
reliable process-spawn contract. It does not repair the second directory change made by
handoff's `--dir`.

Pi does not need to repeat `--dir` when Claude should work in Pi's existing session directory:
handoff's default is the actual current directory. When Pi intentionally delegates to a
different directory, however, the wrapper must explicitly synchronize `PWD`.

### P2. Normalize signal-based subprocess return codes

Python represents a subprocess terminated by signal `N` as return code `-N`. Returning that
value directly through `sys.exit()` wraps it modulo 256, so `SIGTERM` (`-15`) surfaced to a
foreground caller as 241 instead of the conventional 143. Background jobs also recorded the
non-shell-compatible negative value in `exit_code`.

Normalize negative subprocess return codes to `128 + N` before logging, returning, or recording
them.

## Fixes applied

### Child `PWD` now follows `--dir`

`run_foreground()` now sets:

```python
env["PWD"] = o["workdir"]
```

immediately before invoking Claude. Foreground and background jobs share `run_foreground()`, so
both paths now give Claude matching `cwd` and `PWD` values.

The directory-scoping test now inspects the fake Claude process environment for both foreground
and background `--dir` runs. Before the fix it reproduced the mismatch:

```text
expected: /tmp/.../other-project
actual:   /tmp/.../work
```

### Signal exits now use shell-compatible statuses

`normalize_returncode()` translates a negative Python return code with:

```python
128 - returncode
```

Thus `-15` becomes 143 and `-9` becomes 137. The normalized value is used consistently in the
error message, foreground process exit, background `exit_code`, `status`, and `wait`.

The fake Claude executable can now terminate itself by signal for offline coverage. The new
regression verifies that `SIGTERM` produces status 143 in both foreground and background modes;
before the fix the foreground assertion reproduced 241.

## Fix summary

Both P2 findings are resolved. Claude now observes a `PWD` consistent with the directory selected
by handoff, and signal-terminated Claude processes produce conventional `128 + signal` statuses
through every reporting path. No live Claude invocation was needed or performed.

---

# Second-round review

**Scope:** a second pass over the full Python port and migrated test suite, excluding the two
resolved first-round findings and the explicitly deferred pre-existing findings M3, M4, and L2.

**Verification performed**

- `python3 tests/test_handoff.py` → 9 offline tests pass; the opt-in live test is skipped.
- `python3 -m py_compile skills/handoff-to-claude-code/scripts/handoff.py` → pass.
- `git diff --check ff5fb89..HEAD` → pass.
- Reproduced the new finding with a read-only `sessions.tsv`: Claude completed successfully, but
  the wrapper exited 1 with a `PermissionError` traceback and emitted none of Claude's answer.

## New finding

### P2. Keep a successful result when the session ledger cannot be updated

`record_session()` opens `sessions.tsv` without handling `OSError`. If that ledger becomes
unwritable—for example because of permissions, a read-only state mount, or a full filesystem—the
exception occurs only after Claude has completed successfully, and it escapes before
`run_foreground()` writes the answer or metadata. The caller therefore loses the result of a
potentially long, quota-consuming run and receives a Python traceback instead. The previous shell
implementation did not make the best-effort ledger append fatal, so this is a port regression;
the append failure should be reported without discarding the successful Claude result.

## Second-round decision

The finding is confirmed, but accepted without a code change. It requires an otherwise usable
state namespace whose ledger append fails—for example because of file permissions, a read-only
mount, or a full filesystem. That failure can discard a successful result, but the combination is
too rare to justify expanding this port. The session ledger therefore remains a known
non-best-effort write.

---

# Third-round review

**Scope:** four additional reports against the Python port: background authentication with a
relative `CLAUDE_CONFIG_DIR`, process-group reuse in `kill`, logical symlink handling for relative
`--dir`, and strict `wait --timeout` behavior.

**Verification performed**

- Reproduced the background authentication issue: the launcher reported that it stripped
  `ANTHROPIC_API_KEY`, but the delegated child received the original key after resolving the
  relative credential directory from its new cwd.
- Modeled process-group reuse with a controlled unrelated process: a terminal `done` job record
  caused `kill` to send that process group `SIGTERM`.
- Reproduced the logical-path split: from a symlinked cwd, `doctor` used the symlink path while
  `doctor --dir .` used the physical target before the fix.
- Reproduced the timeout behavior: a 1.5-second job waited on with `--timeout 1` returned success
  after 2.038 seconds.
- After the selected fix, `python3 -m unittest discover -s tests -p 'test_handoff.py' -v` → 10
  offline tests pass; the opt-in live test is skipped.
- `python3 -m py_compile skills/handoff-to-claude-code/scripts/handoff.py` → pass.
- `git diff --check` → pass.

## Findings and decisions

### P1. Background `--dir` can reintroduce a stripped API key

The background launcher calls `apply_auth_guard()` but discards its returned environment, so
`Popen` inherits the original API key. If `CLAUDE_CONFIG_DIR` is relative and `--dir` changes the
cwd, the child may no longer find the subscription credential that the launcher found and can
pass the original key to Claude.

**Decision: acknowledge without fixing.** The report is correct and the behavior is a port
regression, but it requires the narrow combination of a background `--dir` run, a relative
credential directory, file-based subscription detection, and an exported API key. Normal
absolute credential directories are unaffected, so this is accepted as a rare configuration
edge case.

### P1. `kill` can signal an unrelated recycled process group

`cmd_kill()` probes and signals the recorded process-group ID without first consulting the job's
terminal status. Since job records persist, a sufficiently old PGID can be reused by an unrelated
same-user process group.

**Decision: acknowledge without fixing.** This behavior was inherited from the Bash wrapper and
requires an old terminal record, operating-system PGID reuse, and a later `kill` of that exact job
ID. A terminal-status guard would reduce the risk but would not cover stale records still marked
`running`, and it could prevent cleanup of legitimate descendants left in the group after a job
reports completion. The narrow destructive edge case remains an accepted risk.

### P2. Relative `--dir` loses the logical symlink path

`logical_cwd()` deliberately preserves the caller's `$PWD`, but `os.path.abspath()` resolved
relative `--dir` values from Python's physical `os.getcwd()`. Consequently, equivalent commands
such as `doctor` and `doctor --dir .` could use different session and job state namespaces when
the cwd was reached through a symlink.

**Decision: fix.** The correction is small, restores the previous Bash behavior, and keeps the
state-directory invariant already documented by `logical_cwd()`.

### P2. `--timeout` is not a strict deadline

`cmd_wait()` polls every two seconds, checks completion before timeout, and increments a synthetic
counter only after each sleep. A job can therefore finish after the requested deadline but before
the next poll and still return success; an odd-numbered whole-second timeout can also block until
the following two-second poll.

**Decision: acknowledge without fixing.** This polling behavior was inherited from the Bash
wrapper. The intended operational timeouts are normally tens or hundreds of seconds, where a
sub-two-second polling discrepancy is immaterial; strict one-to-five-second deadlines are not a
target use case.

## Fix applied

### Relative directory resolution now retains logical symlinks

The new `resolve_dir()` helper joins relative paths to `logical_cwd()` and applies lexical
normalization without resolving symlinks. Both the run parser and job-query parser use the same
helper and validate the resolved target.

The new regression test enters a real directory through a symlink and verifies that:

- `doctor` and `doctor --dir .` report the same state directory;
- `chat --dir .` reports and exports the logical symlink path; and
- the resulting session is visible through a default `sessions` query from that logical cwd.

## Third-round fix summary

All four reports were confirmed. The logical-symlink `--dir` regression is fixed and covered
offline. The relative-auth, recycled-PGID, and strict-timeout findings are documented as accepted
edge cases with no code change. The second-round session-ledger failure is likewise accepted
without a fix. The two first-round corrections for child `PWD` and signal exit statuses remain
covered and passing.
