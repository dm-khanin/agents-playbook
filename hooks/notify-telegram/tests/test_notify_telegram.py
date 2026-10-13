"""Tests for notify-telegram.sh against a fake Telegram API (tests/fake_curl.py on PATH as curl)."""
from __future__ import annotations

import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "notify-telegram.sh"
REQUEST = {
    "tool_name": "Bash",
    "tool_input": {"command": "ls -la"},
    "session_id": "session-1234",
    "cwd": "/tmp/project",
    "permission_suggestions": [{"type": "addRules", "rules": [{"toolName": "Bash"}]}],
}


class NotifyTelegramTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        fake = self.bin / "curl"
        shutil.copyfile(HERE / "fake_curl.py", fake)
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        self.state = self.tmp / "state"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_hook(self, scenario: str, token: str | None = "t") -> subprocess.CompletedProcess:
        env = {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "HOME": str(self.tmp),
            "TMPDIR": str(self.tmp),
            "TELEGRAM_CHAT_ID": "1",
            "TELEGRAM_HOOK_ENV_FILE": str(self.tmp / "missing.env"),
            "TELEGRAM_HOOK_TIMEOUT": "3",
            "FAKE_TG_STATE": str(self.state),
            "FAKE_TG_SCENARIO": scenario,
        }
        if token is not None:
            env["TELEGRAM_BOT_TOKEN"] = token
        return subprocess.run(["bash", str(SCRIPT)], input=json.dumps(REQUEST), capture_output=True,
                              text=True, env=env, timeout=30)

    def decision(self, result: subprocess.CompletedProcess) -> dict:
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)["hookSpecificOutput"]

    def calls(self) -> list[dict]:
        log = self.state / "calls.log"
        if not log.exists():
            return []
        return [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]

    def test_allow(self):
        out = self.decision(self.run_hook("allow"))
        self.assertEqual(out["decision"]["behavior"], "allow")
        self.assertNotIn("updatedPermissions", out["decision"])

    def test_always_allow_returns_the_suggested_rules(self):
        out = self.decision(self.run_hook("always"))
        self.assertEqual(out["decision"]["behavior"], "allow")
        # Claude Code reads the rules to persist from inside the allow decision.
        self.assertEqual(out["decision"]["updatedPermissions"], REQUEST["permission_suggestions"])
        self.assertNotIn("updatedPermissions", out)

    def test_deny(self):
        out = self.decision(self.run_hook("deny"))
        self.assertEqual(out["decision"]["behavior"], "deny")

    def test_timeout_falls_back_to_the_terminal_prompt(self):
        started = time.monotonic()
        result = self.run_hook("silent")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.strip(), "")
        self.assertLess(time.monotonic() - started, 15)
        methods = [c["method"] for c in self.calls()]
        self.assertIn("sendMessage", methods)
        self.assertEqual(methods[-1], "editMessageText", "the message is marked as timed out")

    def test_button_from_another_request_does_not_decide_this_one(self):
        result = self.run_hook("foreign")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.strip(), "")

    def test_missing_token_exits_without_calling_telegram(self):
        result = self.run_hook("allow", token=None)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls(), [])

    def test_message_names_the_tool_and_is_in_english(self):
        self.run_hook("deny")
        sent = [c for c in self.calls() if c["method"] == "sendMessage"]
        self.assertEqual(len(sent), 1)
        text = sent[0]["payload"]["text"]
        self.assertIn("ls -la", text)
        self.assertIsNone(re.search(r"[Ѐ-ӿ]", text), text)


    def test_a_press_on_another_message_or_in_another_chat_is_ignored(self):
        for scenario in ("other_chat", "other_message"):
            with self.subTest(scenario=scenario):
                result = self.run_hook(scenario)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout.strip(), "")

    def test_the_token_is_never_in_curl_arguments(self):
        token = "bot-token-for-tests"
        self.run_hook("allow", token=token)
        self.assertTrue(self.calls())
        for call in self.calls():
            self.assertFalse(any(token in arg for arg in call["argv"]), call["argv"])

    def test_pending_state_is_private_to_the_user(self):
        self.run_hook("allow")
        pending = self.tmp / f"notify-telegram-{os.getuid()}"
        self.assertTrue(pending.is_dir())
        self.assertEqual(stat.S_IMODE(pending.stat().st_mode), 0o700)

    def test_a_pending_path_that_is_a_symlink_is_refused(self):
        elsewhere = self.tmp / "elsewhere"
        elsewhere.mkdir()
        (self.tmp / f"notify-telegram-{os.getuid()}").symlink_to(elsewhere)
        result = self.run_hook("allow")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls(), [])

if __name__ == "__main__":
    unittest.main()
