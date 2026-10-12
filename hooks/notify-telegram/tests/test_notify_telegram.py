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
        self.assertNotIn("updatedPermissions", out)

    def test_always_allow_returns_the_suggested_rules(self):
        out = self.decision(self.run_hook("always"))
        self.assertEqual(out["decision"]["behavior"], "allow")
        self.assertEqual(out["updatedPermissions"], REQUEST["permission_suggestions"])

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


if __name__ == "__main__":
    unittest.main()
