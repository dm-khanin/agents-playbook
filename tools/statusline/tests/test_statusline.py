"""Tests for statusline.sh: feed Claude Code's status JSON on stdin, read the printed line."""
from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "statusline.sh"


def git(cwd: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


class StatuslineTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self._tmp.name) / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "feature-x")
        git(self.repo, "config", "user.name", "Test")
        git(self.repo, "config", "user.email", "test" + "@" + "example.com")
        (self.repo / "a.txt").write_text("a\n", encoding="utf-8")
        git(self.repo, "add", "a.txt")
        git(self.repo, "commit", "-q", "-m", "init")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def status(self, payload: dict, cwd: Path | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(["bash", str(SCRIPT)], input=json.dumps(payload), capture_output=True, text=True,
                              cwd=cwd or self._tmp.name, timeout=30)

    def payload(self, **extra) -> dict:
        base = {"model": {"display_name": "Model Q"}, "workspace": {"current_dir": str(self.repo)},
                "cost": {"total_duration_ms": 65000}}
        base.update(extra)
        return base

    def test_dirty_repo_shows_model_branch_and_marker(self):
        (self.repo / "untracked.txt").write_text("x\n", encoding="utf-8")
        result = self.status(self.payload())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Model Q", result.stdout)
        self.assertIn("feature-x*", result.stdout)
        self.assertIn("1:05", result.stdout)

    def test_clean_repo_has_no_dirty_marker(self):
        result = self.status(self.payload())
        self.assertIn("feature-x", result.stdout)
        self.assertNotIn("feature-x*", result.stdout)

    def test_context_usage_bar(self):
        usage = {"context_window_size": 200000, "used_percentage": 40,
                 "current_usage": {"input_tokens": 50000, "cache_read_input_tokens": 30000}}
        result = self.status(self.payload(context_window=usage))
        self.assertIn("80k/200k", result.stdout)
        self.assertIn("40%", result.stdout)

    def test_empty_payload_still_prints_a_line(self):
        result = self.status({})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("?", result.stdout)
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
