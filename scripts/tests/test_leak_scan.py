"""Tests for scripts/leak_scan.py. Fixture strings are assembled at runtime so this
file never contains a literal the scanner would flag."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "leak_scan.py"
HOME_PATH = "/" + "Users" + "/alice/project/notes.txt"
FOREIGN_EMAIL = "alice" + "@" + "corp.test"
ALLOWED_EMAIL = "someone" + "@" + "example.com"
PRIVATE_WORD = "zan" + "thor"


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout


def make_repo(root: Path) -> Path:
    repo = root / "repo"
    repo.mkdir()
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.name", "Test")
    git(repo, "config", "user.email", "test" + "@" + "example.com")
    return repo


def commit_file(repo: Path, name: str, content: str | bytes, message: str = "add") -> None:
    path = repo / name
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(content, bytes):
        path.write_bytes(content)
    else:
        path.write_text(content, encoding="utf-8")
    git(repo, "add", name)
    git(repo, "commit", "-q", "-m", message)


def scan(repo: Path, *args: str, patterns: str | None = None) -> subprocess.CompletedProcess:
    env = {k: v for k, v in os.environ.items() if k != "LEAKGUARD_PATTERNS"}
    if patterns is not None:
        env["LEAKGUARD_PATTERNS"] = patterns
    return subprocess.run([sys.executable, str(SCRIPT), *args, "--repo", str(repo)],
                          capture_output=True, text=True, env=env)


def assert_scan_error(test: unittest.TestCase, result: subprocess.CompletedProcess) -> None:
    """Exit 2 alone is not enough: Python also exits 2 when it cannot open the script."""
    test.assertEqual(result.returncode, 2, result.stdout + result.stderr)
    test.assertIn("leak-scan:", result.stderr)


class LeakScanTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.repo = make_repo(self.root)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_clean_tree_exits_0(self):
        commit_file(self.repo, "README.md", "Use ~/.config/tool or $HOME/.cache.\n")
        result = scan(self.repo, "--tree")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_home_path_is_flagged_with_location(self):
        commit_file(self.repo, "docs/a.md", "line one\nsee " + HOME_PATH + "\n")
        result = scan(self.repo, "--tree")
        self.assertEqual(result.returncode, 1)
        self.assertIn("docs/a.md:2: home-path", result.stdout)

    def test_placeholder_home_path_is_not_flagged(self):
        commit_file(self.repo, "a.md", "pattern /" + "Users/<name>/ is described here\n")
        self.assertEqual(scan(self.repo, "--tree").returncode, 0)

    def test_foreign_email_flagged_allowed_email_not(self):
        commit_file(self.repo, "a.md", "mail " + ALLOWED_EMAIL + "\n")
        self.assertEqual(scan(self.repo, "--tree").returncode, 0)
        commit_file(self.repo, "b.md", "mail " + FOREIGN_EMAIL + "\n")
        result = scan(self.repo, "--tree")
        self.assertEqual(result.returncode, 1)
        self.assertIn("b.md:1: email", result.stdout)
        self.assertNotIn("a.md", result.stdout)

    def test_private_ip_flagged_loopback_not(self):
        commit_file(self.repo, "a.md", "http://127.0.0.1:3000\n")
        self.assertEqual(scan(self.repo, "--tree").returncode, 0)
        commit_file(self.repo, "b.md", "host 192.168" + ".1.20\n")
        self.assertIn("b.md:1: private-ip", scan(self.repo, "--tree").stdout)

    def test_private_match_is_case_insensitive(self):
        commit_file(self.repo, "a.md", "Works at " + PRIVATE_WORD.upper() + " Ltd\n")
        result = scan(self.repo, "--tree", patterns=PRIVATE_WORD)
        self.assertEqual(result.returncode, 1)
        self.assertIn("a.md:1: private#1", result.stdout)

    def test_private_match_is_not_echoed(self):
        commit_file(self.repo, "a.md", "Works at " + PRIVATE_WORD + " Ltd\n")
        result = scan(self.repo, "--tree", patterns="# comment\n" + PRIVATE_WORD)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(PRIVATE_WORD, (result.stdout + result.stderr).lower())

    def test_private_patterns_from_local_file(self):
        (self.repo / ".leakguard.local").write_text("# mine\n" + PRIVATE_WORD + "\n", encoding="utf-8")
        commit_file(self.repo, "a.md", PRIVATE_WORD + "\n")
        self.assertIn("private#1", scan(self.repo, "--tree").stdout)

    def test_private_word_in_file_name_is_flagged_without_echo(self):
        commit_file(self.repo, "notes/" + PRIVATE_WORD + "-plan.md", "nothing here\n")
        result = scan(self.repo, "--tree", patterns=PRIVATE_WORD)
        self.assertEqual(result.returncode, 1)
        self.assertIn(":0: private#1", result.stdout)
        self.assertNotIn(PRIVATE_WORD, (result.stdout + result.stderr).lower())

    def test_public_excerpt_is_dropped_when_a_private_pattern_matches_the_line(self):
        commit_file(self.repo, "mail.md", "write to dev" + "@" + PRIVATE_WORD + ".io\n")
        result = scan(self.repo, "--tree", patterns=PRIVATE_WORD)
        self.assertEqual(result.returncode, 1)
        self.assertIn("mail.md:1: email", result.stdout)
        self.assertIn("mail.md:1: private#1", result.stdout)
        self.assertNotIn(PRIVATE_WORD, (result.stdout + result.stderr).lower())

    def test_private_path_in_history_is_not_echoed(self):
        commit_file(self.repo, PRIVATE_WORD + "/notes.md", "see " + HOME_PATH + "\n")
        result = scan(self.repo, "--history", patterns=PRIVATE_WORD)
        self.assertEqual(result.returncode, 1)
        self.assertIn("home-path", result.stdout)
        self.assertNotIn(PRIVATE_WORD, (result.stdout + result.stderr).lower())

    def test_reveal_prints_real_paths_and_excerpts_for_local_use(self):
        commit_file(self.repo, "notes/" + PRIVATE_WORD + "-plan.md", "mail dev" + "@" + PRIVATE_WORD + ".io\n")
        result = scan(self.repo, "--tree", "--reveal", patterns=PRIVATE_WORD)
        self.assertEqual(result.returncode, 1)
        self.assertIn("notes/" + PRIVATE_WORD + "-plan.md:1: email", result.stdout)

    def test_home_path_without_trailing_slash_is_flagged(self):
        commit_file(self.repo, "a.sh", "export HOME=" + "/home" + "/bob\ncd " + "/Users" + "/alice && ls\n")
        result = scan(self.repo, "--tree")
        self.assertEqual(result.returncode, 1)
        self.assertIn("a.sh:1: home-path", result.stdout)
        self.assertIn("a.sh:2: home-path", result.stdout)

    def test_windows_home_path_is_flagged(self):
        commit_file(self.repo, "a.md", "C:" + "\\" + "Users" + "\\" + "alice" + "\\" + "file.txt\n")
        self.assertIn("a.md:1: home-path", scan(self.repo, "--tree").stdout)

    def test_message_mode_scans_a_commit_message_file(self):
        commit_file(self.repo, "a.md", "clean\n")
        message = self.root / "MSG"
        message.write_text("fix: thing\n\nfor the " + PRIVATE_WORD + " team\n", encoding="utf-8")
        result = scan(self.repo, "--message", str(message), patterns=PRIVATE_WORD)
        self.assertEqual(result.returncode, 1)
        self.assertIn("<message>:3: private#1", result.stdout)

    def test_message_mode_ignores_comment_lines(self):
        commit_file(self.repo, "a.md", "clean\n")
        message = self.root / "MSG"
        message.write_text("fix: thing\n# On branch " + PRIVATE_WORD + "\n", encoding="utf-8")
        self.assertEqual(scan(self.repo, "--message", str(message), patterns=PRIVATE_WORD).returncode, 0)

    def test_require_private_without_patterns_exits_2(self):
        commit_file(self.repo, "a.md", "clean\n")
        assert_scan_error(self, scan(self.repo, "--tree", "--require-private"))

    def test_blank_private_patterns_count_as_missing(self):
        commit_file(self.repo, "a.md", "clean\n")
        assert_scan_error(self, scan(self.repo, "--tree", "--require-private", patterns="\n  \n"))

    def test_invalid_private_regex_exits_2_without_echo(self):
        commit_file(self.repo, "a.md", "clean\n")
        result = scan(self.repo, "--tree", patterns=PRIVATE_WORD + "(")
        assert_scan_error(self, result)
        self.assertNotIn(PRIVATE_WORD, result.stdout + result.stderr)

    def test_outside_git_repo_exits_2(self):
        plain = self.root / "plain"
        plain.mkdir()
        assert_scan_error(self, scan(plain, "--tree"))

    def test_binary_file_is_skipped(self):
        commit_file(self.repo, "img.bin", b"\x00\x01" + HOME_PATH.encode() + b"\xff\xfe")
        commit_file(self.repo, "a.md", "clean\n")
        result = scan(self.repo, "--tree")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_binary_file_name_is_still_scanned(self):
        commit_file(self.repo, PRIVATE_WORD + ".bin", b"\x00\x01\x02")
        result = scan(self.repo, "--tree", patterns=PRIVATE_WORD)
        self.assertEqual(result.returncode, 1)
        self.assertIn(":0: private#1", result.stdout)
        self.assertNotIn(PRIVATE_WORD, (result.stdout + result.stderr).lower())

    def test_staged_scans_index_not_worktree(self):
        commit_file(self.repo, "a.md", "clean\n")
        (self.repo / "a.md").write_text("clean v2\n", encoding="utf-8")
        git(self.repo, "add", "a.md")
        (self.repo / "a.md").write_text("dirty " + HOME_PATH + "\n", encoding="utf-8")
        self.assertEqual(scan(self.repo, "--staged").returncode, 0)
        git(self.repo, "add", "a.md")
        self.assertEqual(scan(self.repo, "--staged").returncode, 1)

    def test_history_finds_removed_content(self):
        commit_file(self.repo, "a.md", "oops " + HOME_PATH + "\n", "add leak")
        commit_file(self.repo, "a.md", "clean\n", "remove leak")
        self.assertEqual(scan(self.repo, "--tree").returncode, 0)
        result = scan(self.repo, "--history")
        self.assertEqual(result.returncode, 1)
        self.assertIn("home-path", result.stdout)

    def test_history_scans_commit_messages(self):
        commit_file(self.repo, "a.md", "clean\n", "ticket for " + PRIVATE_WORD)
        self.assertIn("private#1", scan(self.repo, "--history", patterns=PRIVATE_WORD).stdout)

    def test_history_on_shallow_clone_exits_2(self):
        commit_file(self.repo, "a.md", "one\n")
        commit_file(self.repo, "a.md", "two\n")
        clone = self.root / "clone"
        subprocess.run(["git", "clone", "-q", "--depth", "1", "file://" + str(self.repo), str(clone)],
                       check=True, capture_output=True)
        assert_scan_error(self, scan(clone, "--history"))

    def test_allowlist_suppresses_exact_path_and_id(self):
        commit_file(self.repo, "a.md", "see " + HOME_PATH + "\n")
        commit_file(self.repo, ".leakguard-allow", "# reason: documented example\na.md home-path\n")
        self.assertEqual(scan(self.repo, "--tree").returncode, 0)

    def test_allowlist_rejects_wildcards_and_private_ids(self):
        commit_file(self.repo, "a.md", "clean\n")
        commit_file(self.repo, ".leakguard-allow", "*.md home-path\n")
        assert_scan_error(self, scan(self.repo, "--tree"))
        commit_file(self.repo, ".leakguard-allow", "a.md private#1\n")
        assert_scan_error(self, scan(self.repo, "--tree"))


if __name__ == "__main__":
    unittest.main()
