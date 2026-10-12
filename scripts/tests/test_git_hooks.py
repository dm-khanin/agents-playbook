"""The opt-in git hooks, wired into a scratch clone: commit-msg and pre-push must stop a leak
before it leaves the machine, since CI only sees it once it is already public."""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PRIVATE_WORD = "zan" + "thor"


class GitHooksTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        tmp = Path(self._tmp.name)
        self.remote = tmp / "remote.git"
        self.repo = tmp / "repo"
        subprocess.run(["git", "init", "-q", "--bare", str(self.remote)], check=True)
        (self.repo / "scripts").mkdir(parents=True)
        shutil.copy(ROOT / "scripts" / "leak_scan.py", self.repo / "scripts")
        shutil.copytree(ROOT / ".githooks", self.repo / ".githooks")
        for args in (["init", "-q", "-b", "main"], ["config", "user.name", "T"],
                     ["config", "user.email", "t" + "@" + "example.com"],
                     ["config", "core.hooksPath", ".githooks"],
                     ["remote", "add", "origin", str(self.remote)]):
            self.git(*args)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def git(self, *args: str, patterns: str | None = PRIVATE_WORD) -> subprocess.CompletedProcess:
        env = {k: v for k, v in os.environ.items() if k != "LEAKGUARD_PATTERNS"}
        if patterns is not None:
            env["LEAKGUARD_PATTERNS"] = patterns
        return subprocess.run(["git", *args], cwd=self.repo, capture_output=True, text=True, env=env, timeout=60)

    def commit(self, name: str, content: str, message: str, *extra: str) -> subprocess.CompletedProcess:
        (self.repo / name).write_text(content, encoding="utf-8")
        self.git("add", name)
        return self.git("commit", "-q", "-m", message, *extra)

    def remote_has_main(self) -> bool:
        refs = subprocess.run(["git", "for-each-ref"], cwd=self.remote, capture_output=True, text=True).stdout
        return "refs/heads/main" in refs

    def test_commit_msg_refuses_a_private_word_in_the_message(self):
        result = self.commit("a.md", "clean\n", "docs: notes for the " + PRIVATE_WORD + " team")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(PRIVATE_WORD, (result.stdout + result.stderr).lower())
        self.assertNotEqual(self.git("rev-parse", "-q", "--verify", "HEAD").returncode, 0, "no commit was made")

    def test_clean_commit_and_push_go_through(self):
        self.assertEqual(self.commit("a.md", "clean\n", "docs: add notes").returncode, 0)
        result = self.git("push", "-q", "origin", "main")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.remote_has_main())

    def test_pre_push_refuses_history_that_bypassed_the_commit_hooks(self):
        self.commit("a.md", PRIVATE_WORD + "\n", "docs: add notes", "--no-verify")
        result = self.git("push", "-q", "origin", "main")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.remote_has_main())

    def test_pre_push_refuses_without_private_patterns(self):
        self.commit("a.md", "clean\n", "docs: add notes")
        result = self.git("push", "-q", "origin", "main", patterns=None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no private patterns", result.stderr)
        self.assertFalse(self.remote_has_main())


if __name__ == "__main__":
    unittest.main()
