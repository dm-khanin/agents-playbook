"""Tests for tools/leak-guard/install.sh: install into scratch repositories and exercise the installed hooks.

The scratch directory's name contains a space, so every path in the installer and the hooks must be quoted.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

INSTALL = Path(__file__).resolve().parents[1] / "install.sh"
PRIVATE_WORD = "zan" + "thor"


def git(repo: Path, *args: str, check: bool = True, env: dict | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=check, env=env)


class InstallTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name) / "with space"
        self.root.mkdir()
        self.repo = self.root / "repo"
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.repo)], check=True)
        git(self.repo, "config", "user.name", "T")
        git(self.repo, "config", "user.email", "t" + "@" + "example.com")
        self.env = {key: value for key, value in os.environ.items() if key != "LEAKGUARD_PATTERNS"}

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def install(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["sh", str(INSTALL), *args], capture_output=True, text=True)

    def enable(self) -> None:
        result = self.install(str(self.repo))
        self.assertEqual(result.returncode, 0, result.stderr)
        git(self.repo, "config", "core.hooksPath", ".leak-guard/hooks")

    def commit(self, name: str, content: str, message: str = "add") -> subprocess.CompletedProcess:
        (self.repo / name).write_text(content, encoding="utf-8")
        git(self.repo, "add", name)
        return git(self.repo, "commit", "-q", "-m", message, check=False, env=self.env)

    def test_install_creates_the_files_and_ignores_the_private_list(self):
        result = self.install(str(self.repo))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.repo / ".leak-guard" / "leak_scan.py").is_file())
        for hook in ("pre-commit", "commit-msg", "pre-push"):
            self.assertTrue(os.access(self.repo / ".leak-guard" / "hooks" / hook, os.X_OK), hook)
        self.assertTrue((self.repo / ".leakguard-allow").is_file())
        self.assertEqual((self.repo / ".gitignore").read_text(encoding="utf-8").splitlines().count(".leakguard.local"), 1)
        self.assertIn("core.hooksPath .leak-guard/hooks", result.stdout)

    def test_install_is_idempotent_and_keeps_an_existing_allowlist(self):
        (self.repo / ".leakguard-allow").write_text("docs/a.md email\n", encoding="utf-8")
        (self.repo / ".gitignore").write_text("node_modules/", encoding="utf-8")
        self.install(str(self.repo))
        self.install(str(self.repo))
        self.assertEqual((self.repo / ".leakguard-allow").read_text(encoding="utf-8"), "docs/a.md email\n")
        self.assertEqual((self.repo / ".gitignore").read_text(encoding="utf-8"), "node_modules/\n.leakguard.local\n")

    def test_installed_pre_commit_refuses_a_private_word(self):
        self.enable()
        (self.repo / ".leakguard.local").write_text(PRIVATE_WORD + "\n", encoding="utf-8")
        result = self.commit("notes.md", "about " + PRIVATE_WORD + "\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("private#1", result.stdout + result.stderr)
        self.assertNotIn(PRIVATE_WORD, (result.stdout + result.stderr).lower())

    def test_installed_commit_msg_refuses_a_private_word_in_the_message(self):
        self.enable()
        (self.repo / ".leakguard.local").write_text(PRIVATE_WORD + "\n", encoding="utf-8")
        result = self.commit("notes.md", "clean\n", message="fix for " + PRIVATE_WORD)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("private#1", result.stdout + result.stderr)

    def test_a_clean_commit_passes(self):
        self.enable()
        (self.repo / ".leakguard.local").write_text(PRIVATE_WORD + "\n", encoding="utf-8")
        self.assertEqual(self.commit("notes.md", "clean\n").returncode, 0)

    def test_installed_pre_push_requires_private_patterns(self):
        self.enable()
        remote = self.root / "remote.git"
        subprocess.run(["git", "init", "-q", "--bare", str(remote)], check=True)
        git(self.repo, "remote", "add", "origin", str(remote))
        self.assertEqual(self.commit("notes.md", "clean\n").returncode, 0)
        refused = git(self.repo, "push", "-q", "origin", "main", check=False, env=self.env)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("leak-scan:", refused.stdout + refused.stderr)
        (self.repo / ".leakguard.local").write_text(PRIVATE_WORD + "\n", encoding="utf-8")
        self.assertEqual(git(self.repo, "push", "-q", "origin", "main", check=False, env=self.env).returncode, 0)

    def test_hooks_are_executable_even_when_the_copy_of_the_tool_lost_its_modes(self):
        tool = self.root / "tool copy"
        shutil.copytree(INSTALL.parent, tool, ignore=shutil.ignore_patterns("tests"))
        for hook in (tool / "githooks").iterdir():
            hook.chmod(0o644)
        result = subprocess.run(["sh", str(tool / "install.sh"), str(self.repo)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for hook in ("pre-commit", "commit-msg", "pre-push"):
            self.assertTrue(os.access(self.repo / ".leak-guard" / "hooks" / hook, os.X_OK), hook)

    def test_usage_errors_exit_2(self):
        self.assertEqual(self.install().returncode, 2)
        plain = self.root / "plain"
        plain.mkdir()
        result = self.install(str(plain))
        self.assertEqual(result.returncode, 2)
        self.assertIn("not a git work tree", result.stderr)


    def test_install_leaves_git_configuration_alone(self):
        self.install(str(self.repo))
        self.assertEqual(git(self.repo, "config", "--get", "core.hooksPath", check=False).stdout, "")

    def test_an_equivalent_ignore_rule_is_respected(self):
        (self.repo / ".gitignore").write_text("*.local\n", encoding="utf-8")
        self.install(str(self.repo))
        self.assertEqual((self.repo / ".gitignore").read_text(encoding="utf-8"), "*.local\n")

    def test_a_tracked_private_list_is_reported(self):
        (self.repo / ".leakguard.local").write_text("x\n", encoding="utf-8")
        git(self.repo, "add", "-f", ".leakguard.local")
        git(self.repo, "commit", "-q", "-m", "oops")
        result = self.install(str(self.repo))
        self.assertIn(".leakguard.local is tracked", result.stderr)

    def test_the_ci_job_requires_private_patterns_on_tree_and_history(self):
        text = (INSTALL.parent / "ci" / "leak-scan.yml").read_text(encoding="utf-8")
        for needle in ("fetch-depth: 0", "--tree --require-private", "--history --require-private",
                       "secrets.LEAKGUARD_PATTERNS"):
            self.assertIn(needle, text)

if __name__ == "__main__":
    unittest.main()
