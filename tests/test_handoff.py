#!/usr/bin/env python3
"""Behavioral tests for the handoff.py command-line interface."""

import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import unittest


TESTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parent
HANDOFF = REPO_ROOT / "skills" / "handoff-to-claude-code" / "scripts" / "handoff.py"
FAKE_CLAUDE = TESTS_DIR / "fake-claude"
METADATA_DELIMITER = "--- handoff metadata ---"
SESSION_ID = "11111111-2222-3333-4444-555555555555"
AUTH_VARS = (
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
)
FAKE_VARS = (
    "FAKE_CLAUDE_TEXT",
    "FAKE_CLAUDE_SESSION",
    "FAKE_CLAUDE_EXIT",
    "FAKE_CLAUDE_STDERR",
    "FAKE_CLAUDE_IS_ERROR",
    "FAKE_CLAUDE_MODEL_USAGE",
    "FAKE_CLAUDE_SLEEP",
    "FAKE_CLAUDE_SIGNAL",
)


class HandoffTestCase(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.work = self.root / "work"
        self.state = self.root / "state"
        self.config = self.root / "claude-config"
        self.argv_log = self.root / "argv.json"
        self.env_log = self.root / "env.json"
        self.work.mkdir()
        self.config.mkdir()
        self.job_groups = set()

        self.env = os.environ.copy()
        for name in AUTH_VARS + FAKE_VARS:
            self.env.pop(name, None)
        self.env.update(
            {
                "XDG_STATE_HOME": str(self.state),
                "CLAUDE_CONFIG_DIR": str(self.config),
                "HANDOFF_CLAUDE_BIN": str(FAKE_CLAUDE),
                "FAKE_CLAUDE_ARGV_LOG": str(self.argv_log),
                "FAKE_CLAUDE_ENV_LOG": str(self.env_log),
            }
        )

    def tearDown(self):
        for pgid in self.job_groups:
            try:
                os.killpg(pgid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.tempdir.cleanup()

    def with_subscription(self):
        (self.config / ".credentials.json").touch()

    def without_subscription(self):
        (self.config / ".credentials.json").unlink(missing_ok=True)

    def handoff(self, *args, input_text=None, cwd=None, env=None):
        run_env = self.env.copy()
        if env:
            run_env.update(env)
        run_cwd = Path(cwd or self.work)
        run_env["PWD"] = str(run_cwd)
        return subprocess.run(
            [sys.executable, str(HANDOFF), *args],
            cwd=run_cwd,
            env=run_env,
            input=input_text,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        )

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)

    def argv(self):
        return json.loads(self.argv_log.read_text(encoding="utf-8"))

    def child_env(self):
        return json.loads(self.env_log.read_text(encoding="utf-8"))

    def assert_argv_pair(self, flag, value):
        args = self.argv()
        self.assertTrue(
            any(pair == (flag, value) for pair in zip(args, args[1:])),
            "{} is not followed by {!r} in {!r}".format(flag, value, args),
        )

    @staticmethod
    def field(output, name):
        match = re.search(r"^{}: (.+)$".format(re.escape(name)), output, re.MULTILINE)
        return match.group(1) if match else ""

    @staticmethod
    def project_slug(path):
        return re.sub(r"[^A-Za-z0-9]", "-", str(path)).lstrip("-")

    def job_dir(self, job_id):
        matches = list(self.state.rglob(job_id))
        self.assertEqual(
            len(matches), 1, "expected one directory for {}".format(job_id)
        )
        return matches[0]

    def remember_job_group(self, job_id):
        pgid = int((self.job_dir(job_id) / "pgid").read_text(encoding="utf-8"))
        self.job_groups.add(pgid)
        return pgid

    @staticmethod
    def group_size(pgid):
        result = subprocess.run(
            ["ps", "-eo", "pgid=,pid="],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            check=True,
        )
        return sum(
            1
            for line in result.stdout.splitlines()
            if line.split() and int(line.split()[0]) == pgid
        )

    def test_command_composition_and_validation(self):
        self.with_subscription()

        result = self.handoff("chat", "hello")
        self.assert_success(result)
        self.assertIn("-p", self.argv())
        self.assert_argv_pair("--permission-mode", "auto")
        self.assert_argv_pair("--tools", "Read,Grep,Glob,Bash,WebSearch,WebFetch")
        self.assertNotIn("--bare", self.argv())
        self.assertIn("hello", self.argv())

        self.assert_success(self.handoff("agent", "do the thing"))
        self.assert_argv_pair("--permission-mode", "auto")
        self.assertNotIn("--tools", self.argv())
        self.assertIn("do the thing", self.argv())

        self.assert_success(self.handoff("agent", "--yolo", "risky"))
        self.assert_argv_pair("--permission-mode", "bypassPermissions")

        self.assert_success(self.handoff("chat", "--model", "sonnet", "hi"))
        self.assert_argv_pair("--model", "sonnet")

        self.assert_success(
            self.handoff(
                "agent",
                "--",
                "--add-dir",
                "/tmp",
                "--effort",
                "high",
                "task",
            )
        )
        self.assert_argv_pair("--add-dir", "/tmp")
        self.assert_argv_pair("--effort", "high")
        self.assertIn("task", self.argv())

        result = self.handoff("chat", "-", input_text="from stdin")
        self.assert_success(result)
        self.assertIn(METADATA_DELIMITER, result.stdout)
        self.assert_argv_pair("--", "from stdin")

        result = self.handoff("agent", "-", input_text="- a bullet of a task")
        self.assert_success(result)
        self.assert_argv_pair("--", "- a bullet of a task")

        result = self.handoff("chat", "--session", "abc", "--continue", "x")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mutually exclusive", result.stderr)

        result = self.handoff("frobnicate")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown command", result.stderr)

    def test_subscription_auth_guard(self):
        self.with_subscription()
        self.env["ANTHROPIC_API_KEY"] = "sk-ant-test-key"
        self.env["ANTHROPIC_AUTH_TOKEN"] = "bearer-test"

        result = self.handoff("chat", "hi")
        self.assert_success(result)
        self.assertIsNone(self.child_env()["ANTHROPIC_API_KEY"])
        self.assertIsNone(self.child_env()["ANTHROPIC_AUTH_TOKEN"])
        self.assertIn("stripped ANTHROPIC_API_KEY", result.stderr)

        self.assert_success(self.handoff("chat", "--no-auth-check", "hi"))
        self.assertEqual(self.child_env()["ANTHROPIC_API_KEY"], "sk-ant-test-key")

        self.without_subscription()
        result = self.handoff("chat", "hi")
        self.assert_success(result)
        self.assertEqual(self.child_env()["ANTHROPIC_API_KEY"], "sk-ant-test-key")
        self.assertIn("no subscription credentials found", result.stderr)

        self.with_subscription()
        result = self.handoff("chat", "hi", env={"CLAUDE_CODE_USE_BEDROCK": "1"})
        self.assert_success(result)
        self.assertIn("CLAUDE_CODE_USE_BEDROCK is set", result.stderr)

        self.without_subscription()
        result = self.handoff(
            "chat", "hi", env={"CLAUDE_CODE_OAUTH_TOKEN": "oauth-test"}
        )
        self.assert_success(result)
        self.assertIsNone(self.child_env()["ANTHROPIC_API_KEY"])

    def test_chat_output_and_model_attribution(self):
        self.with_subscription()
        answer = """# Title

Some *markdown* with `code` and a | pipe |.

```python
print("hi")
```"""
        self.env["FAKE_CLAUDE_TEXT"] = answer

        result = self.handoff("chat", "explain")
        self.assert_success(result)
        relayed = result.stdout.split("\n\n" + METADATA_DELIMITER, 1)[0]
        self.assertEqual(relayed, answer)
        self.assertIn(METADATA_DELIMITER, result.stdout)
        self.assertIn("session: " + SESSION_ID, result.stdout)
        self.assertIn("cost_usd: 0.0123", result.stdout)
        self.assertIn("model: claude-opus-5", result.stdout)

        self.env["FAKE_CLAUDE_MODEL_USAGE"] = json.dumps(
            {
                "claude-haiku-4-5-20251001": {
                    "inputTokens": 521,
                    "outputTokens": 13,
                    "cacheReadInputTokens": 0,
                    "costUSD": 0.000586,
                },
                "claude-opus-5[1m]": {
                    "inputTokens": 2,
                    "outputTokens": 4,
                    "cacheCreationInputTokens": 3800,
                    "costUSD": 0.03811,
                },
            }
        )
        result = self.handoff("chat", "explain")
        self.assert_success(result)
        self.assertIn("model: claude-opus-5[1m]", result.stdout)

        self.env["FAKE_CLAUDE_MODEL_USAGE"] = json.dumps(
            {
                "claude-haiku-4-5[1m]": {
                    "inputTokens": 2,
                    "outputTokens": 4,
                    "cacheReadInputTokens": 3800,
                    "costUSD": 0.021,
                },
                "claude-haiku-4-5-20251001": {
                    "inputTokens": 521,
                    "outputTokens": 13,
                    "costUSD": 0.000586,
                },
            }
        )
        result = self.handoff("chat", "explain")
        self.assert_success(result)
        self.assertIn("model: claude-haiku-4-5[1m]", result.stdout)

        self.env["FAKE_CLAUDE_MODEL_USAGE"] = "{}"
        result = self.handoff("chat", "explain")
        self.assert_success(result)
        self.assertNotIn("model: null", result.stdout)
        self.assertIn("model: (user default)", result.stdout)

    def test_sessions_and_utf8_ledger(self):
        self.with_subscription()

        result = self.handoff("chat", "first turn")
        self.assert_success(result)
        session_id = self.field(result.stdout, "session")
        self.assertEqual(session_id, SESSION_ID)

        self.assert_success(
            self.handoff("chat", "--session", session_id, "second turn")
        )
        self.assert_argv_pair("--resume", session_id)
        self.assertNotIn("--session-id", self.argv())

        self.assert_success(self.handoff("chat", "--continue", "third turn"))
        self.assertIn("--continue", self.argv())
        self.assertNotIn("--resume", self.argv())

        ledger = (
            self.state
            / "handoff-to-claude-code"
            / self.project_slug(self.work)
            / "sessions.tsv"
        )
        self.assertTrue(ledger.is_file())
        self.assertIn("first turn", ledger.read_text(encoding="utf-8"))

        result = self.handoff("sessions")
        self.assert_success(result)
        self.assertIn(session_id, result.stdout)

        prompt = (
            "让 claude code 帮我把这个解析器重构一下然后运行所有的测试"
            "确保没有任何问题最后再提交代码好吗谢谢你"
        )
        self.assert_success(self.handoff("chat", prompt, env={"LC_ALL": "C"}))
        ledger.read_text(encoding="utf-8", errors="strict")

    def test_directory_scoping(self):
        self.with_subscription()
        other = self.root / "other-project"
        other.mkdir()

        result = self.handoff("chat", "--dir", str(other), "a thread over there")
        self.assert_success(result)
        self.assertEqual(self.field(result.stdout, "session"), SESSION_ID)
        self.assertEqual(self.child_env()["PWD"], str(other))

        result = self.handoff("sessions")
        self.assert_success(result)
        self.assertIn("no recorded threads", result.stdout)

        result = self.handoff("sessions", "--dir", str(other))
        self.assert_success(result)
        self.assertIn("a thread over there", result.stdout)

        here = self.handoff("doctor")
        there = self.handoff("doctor", "--dir", str(other))
        self.assertNotEqual(
            self.field(here.stdout, "state_dir"),
            self.field(there.stdout, "state_dir"),
        )

        result = self.handoff(
            "agent",
            "--dir",
            str(other),
            "--background",
            "work over there",
        )
        self.assert_success(result)
        job_id = self.field(result.stdout, "job")
        self.remember_job_group(job_id)
        self.assertIn("--dir " + str(other), result.stdout)

        result = self.handoff("wait", job_id, "--dir", str(other), "--timeout", "30")
        self.assert_success(result)
        self.assertEqual(self.child_env()["PWD"], str(other))

        result = self.handoff("status", "--dir", str(other), job_id)
        self.assert_success(result)
        self.assertIn("status: done", result.stdout)

        result = self.handoff("status", job_id)
        self.assert_success(result)
        self.assertIn("status: done", result.stdout)

        result = self.handoff("tail", "--dir", str(other), job_id, "-n", "5")
        self.assert_success(result)
        self.assertIn("session:", result.stdout)

        result = self.handoff("sessions", "--dir", str(self.root / "nope"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a directory", result.stderr)

        result = self.handoff("tail", "--dir", str(other), job_id, "-n", "xyz")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("whole number of lines", result.stderr)

    def test_relative_directory_preserves_logical_symlink_path(self):
        self.with_subscription()
        real = self.root / "real" / "work"
        linked = self.root / "linked-work"
        real.mkdir(parents=True)
        linked.symlink_to(real, target_is_directory=True)

        default = self.handoff("doctor", cwd=linked)
        explicit = self.handoff("doctor", "--dir", ".", cwd=linked)
        self.assert_success(default)
        self.assert_success(explicit)
        self.assertEqual(
            self.field(default.stdout, "state_dir"),
            self.field(explicit.stdout, "state_dir"),
        )

        prompt = "thread through a logical symlink"
        result = self.handoff("chat", "--dir", ".", prompt, cwd=linked)
        self.assert_success(result)
        self.assertEqual(self.field(result.stdout, "dir"), str(linked))
        self.assertEqual(self.child_env()["PWD"], str(linked))

        result = self.handoff("sessions", cwd=linked)
        self.assert_success(result)
        self.assertIn(prompt, result.stdout)

    def test_background_job_lifecycle_and_argument_round_trip(self):
        self.with_subscription()
        self.env["FAKE_CLAUDE_SLEEP"] = "2"

        result = self.handoff("agent", "--background", "long task")
        self.assert_success(result)
        job_id = self.field(result.stdout, "job")
        self.assertIn("job-", job_id)
        self.remember_job_group(job_id)

        result = self.handoff("status", job_id)
        self.assert_success(result)
        self.assertIn("status: running", result.stdout)

        result = self.handoff("wait", job_id, "--timeout", "30")
        self.assert_success(result)
        self.assertIn(METADATA_DELIMITER, result.stdout)

        result = self.handoff("status", job_id)
        self.assert_success(result)
        self.assertIn("status: done", result.stdout)
        self.assertIn("exit_code: 0", result.stdout)

        result = self.handoff("tail", job_id, "-n", "5")
        self.assert_success(result)
        self.assertIn("session:", result.stdout)

        self.env.pop("FAKE_CLAUDE_SLEEP")
        self.env["FAKE_CLAUDE_EXIT"] = "3"
        result = self.handoff("agent", "--background", "doomed")
        self.assert_success(result)
        failed_job = self.field(result.stdout, "job")
        self.remember_job_group(failed_job)
        result = self.handoff("wait", failed_job, "--timeout", "30")
        self.assertEqual(result.returncode, 3)
        result = self.handoff("status", failed_job)
        self.assert_success(result)
        self.assertIn("status: failed", result.stdout)

        self.env.pop("FAKE_CLAUDE_EXIT")
        result = self.handoff(
            "agent",
            "--background",
            "--",
            "--add-dir",
            "/tmp",
            "passthrough task",
        )
        self.assert_success(result)
        passthrough_job = self.field(result.stdout, "job")
        self.remember_job_group(passthrough_job)
        self.assert_success(self.handoff("wait", passthrough_job, "--timeout", "30"))
        self.assert_argv_pair("--add-dir", "/tmp")
        self.assertIn("passthrough task", self.argv())

        prompt = "- Refactor the parser\n- Run the tests\n"
        result = self.handoff("agent", "--background", "-", input_text=prompt)
        self.assert_success(result)
        stdin_job = self.field(result.stdout, "job")
        self.remember_job_group(stdin_job)
        self.assert_success(self.handoff("wait", stdin_job, "--timeout", "30"))
        self.assertIn(prompt.rstrip("\n"), self.argv())

        result = self.handoff("wait", stdin_job, "--timeout", "abc")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("whole number of seconds", result.stderr)

    def test_kill_stops_the_entire_process_group(self):
        self.with_subscription()
        self.env["FAKE_CLAUDE_SLEEP"] = "300"

        result = self.handoff("agent", "--background", "a job that hangs")
        self.assert_success(result)
        job_id = self.field(result.stdout, "job")
        pgid = self.remember_job_group(job_id)
        time.sleep(1)

        result = subprocess.run(
            ["ps", "-o", "pgid=", "-p", str(pgid)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        )
        self.assertEqual(result.stdout.strip(), str(pgid))
        # The background wrapper and the Python fake Claude must both be in the
        # group. The old Bash fake added a third process solely to run `sleep`.
        self.assertGreaterEqual(self.group_size(pgid), 2)

        result = self.handoff("kill", job_id)
        self.assert_success(result)
        self.assertEqual(self.group_size(pgid), 0)
        self.job_groups.discard(pgid)

        result = self.handoff("status", job_id)
        self.assert_success(result)
        self.assertIn("status: killed", result.stdout)

        self.assert_success(self.handoff("kill", job_id))

        result = self.handoff("agent", "--background", "another hang")
        self.assert_success(result)
        hard_killed_job = self.field(result.stdout, "job")
        hard_killed_pgid = self.remember_job_group(hard_killed_job)
        time.sleep(1)
        os.killpg(hard_killed_pgid, signal.SIGKILL)
        time.sleep(1)

        result = self.handoff("wait", hard_killed_job, "--timeout", "20")
        self.assertEqual(result.returncode, 1)
        result = self.handoff("status", hard_killed_job)
        self.assert_success(result)
        self.assertIn("status: died", result.stdout)

    def test_signal_exit_codes_are_normalized(self):
        self.with_subscription()
        self.env["FAKE_CLAUDE_SIGNAL"] = str(signal.SIGTERM)

        result = self.handoff("chat", "terminate")
        self.assertEqual(result.returncode, 128 + signal.SIGTERM)
        self.assertIn(
            "claude exited with status {}".format(128 + signal.SIGTERM),
            result.stderr,
        )

        result = self.handoff("agent", "--background", "terminate in background")
        self.assert_success(result)
        job_id = self.field(result.stdout, "job")
        self.remember_job_group(job_id)

        result = self.handoff("wait", job_id, "--timeout", "30")
        self.assertEqual(result.returncode, 128 + signal.SIGTERM)

        result = self.handoff("status", job_id)
        self.assert_success(result)
        self.assertIn("status: failed", result.stdout)
        self.assertIn(
            "exit_code: {}".format(128 + signal.SIGTERM),
            result.stdout,
        )

    def test_non_retryable_and_unknown_errors(self):
        self.with_subscription()
        self.env["FAKE_CLAUDE_EXIT"] = "1"

        self.env["FAKE_CLAUDE_STDERR"] = "Login expired · Please run /login"
        result = self.handoff("chat", "hi")
        self.assertEqual(result.returncode, 1)
        self.assertIn("ERROR: the Claude Code login has expired", result.stderr)
        self.assertIn("Do not retry", result.stderr)

        self.env["FAKE_CLAUDE_STDERR"] = "Claude AI usage limit reached"
        result = self.handoff("agent", "hi")
        self.assertEqual(result.returncode, 1)
        self.assertIn("usage limit", result.stderr)

        self.env["FAKE_CLAUDE_STDERR"] = "something nobody has seen before"
        result = self.handoff("chat", "hi")
        self.assertEqual(result.returncode, 1)
        self.assertIn("claude exited with status 1", result.stderr)
        self.assertIn("something nobody has seen before", result.stderr)

        self.env.pop("FAKE_CLAUDE_EXIT")
        self.env.pop("FAKE_CLAUDE_STDERR")
        result = self.handoff("chat", "hi", env={"FAKE_CLAUDE_IS_ERROR": "1"})
        self.assertEqual(result.returncode, 1)


@unittest.skipUnless(
    os.environ.get("HANDOFF_LIVE") == "1",
    "set HANDOFF_LIVE=1 to run against the real Claude CLI",
)
class LiveHandoffTest(unittest.TestCase):
    def test_real_claude_round_trip(self):
        with tempfile.TemporaryDirectory() as tempdir:
            work = Path(tempdir) / "work"
            state = Path(tempdir) / "state"
            work.mkdir()
            (work / "note.txt").write_text(
                "The magic word is xyzzy.\n", encoding="utf-8"
            )
            env = os.environ.copy()
            env.pop("HANDOFF_CLAUDE_BIN", None)
            env["XDG_STATE_HOME"] = str(state)
            env["PWD"] = str(work)

            def handoff(*args):
                return subprocess.run(
                    [sys.executable, str(HANDOFF), *args],
                    cwd=work,
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    encoding="utf-8",
                )

            first = handoff("chat", "Read note.txt and reply with just the magic word.")
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertIn("xyzzy", first.stdout)
            session_id = HandoffTestCase.field(first.stdout, "session")
            self.assertRegex(session_id, r"^[0-9a-f]+(?:-[0-9a-f]+){4}$")

            follow = handoff(
                "chat",
                "--session",
                session_id,
                "What word did you just say? Reply with only that word.",
            )
            self.assertEqual(follow.returncode, 0, follow.stderr)
            self.assertIn("xyzzy", follow.stdout)

            agent = handoff("agent", "Create hello.txt containing exactly: hi")
            self.assertEqual(agent.returncode, 0, agent.stderr)
            self.assertTrue((work / "hello.txt").is_file())


if __name__ == "__main__":
    unittest.main(verbosity=2)
