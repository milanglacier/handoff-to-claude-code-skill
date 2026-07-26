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
