"""Tests for the permission-rule linter, run as the SessionStart hook would run it."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "permission_lint.py"


class PermissionLintTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.home = self.tmp / "home"
        self.project = self.tmp / "project"
        (self.home / ".claude").mkdir(parents=True)
        (self.project / ".claude").mkdir(parents=True)
        self.user = self.home / ".claude" / "settings.json"
        self.shared = self.project / ".claude" / "settings.json"
        self.local = self.project / ".claude" / "settings.local.json"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def write(self, path: Path, content) -> None:
        path.write_text(content if isinstance(content, str) else json.dumps(content), encoding="utf-8")

    def lint(self, *files: Path) -> str:
        env = {"HOME": str(self.home), "CLAUDE_PROJECT_DIR": str(self.project), "PATH": os.environ["PATH"]}
        result = subprocess.run([sys.executable, str(SCRIPT), *map(str, files)], capture_output=True, text=True,
                                env=env, cwd=self.tmp, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        if not result.stdout.strip():
            return ""
        output = json.loads(result.stdout)
        self.assertEqual(list(output), ["systemMessage"])
        return output["systemMessage"]

    def test_clean_files_are_silent(self):
        self.write(self.user, {"permissions": {"allow": ["Bash(git status)", "Edit(src/**)"], "deny": ["Read(.env)"]}})
        self.assertEqual(self.lint(), "")

    def test_missing_files_are_silent(self):
        self.assertEqual(self.lint(), "")

    def test_invalid_json_is_reported(self):
        self.write(self.local, '{"permissions": {"allow": [}')
        message = self.lint()
        self.assertIn("settings.local.json", message)
        self.assertIn("invalid JSON", message)

    def test_path_rules_for_tools_that_are_never_consulted(self):
        self.write(self.shared, {"permissions": {"allow": ["Write(src/**)", "NotebookEdit(nb/**)",
                                                           "MultiEdit(lib/**)", "Glob(docs/**)"]}})
        message = self.lint()
        for rule, replacement in (("Write(src/**)", "Edit(src/**)"), ("NotebookEdit(nb/**)", "Edit(nb/**)"),
                                  ("MultiEdit(lib/**)", "Edit(lib/**)"), ("Glob(docs/**)", "Read(docs/**)")):
            self.assertIn(f"{rule} is never consulted; use {replacement}", message)

    def test_a_bare_tool_rule_is_valid(self):
        self.write(self.shared, {"permissions": {"allow": ["Write", "Glob"]}})
        self.assertEqual(self.lint(), "")

    def test_a_repeated_rule_is_reported(self):
        self.write(self.user, {"permissions": {"allow": ["Bash(ls)", "Bash(ls)"]}})
        self.assertIn("Bash(ls) appears 2 times in 'allow'", self.lint())

    def test_a_rule_in_allow_and_deny_is_reported(self):
        self.write(self.user, {"permissions": {"allow": ["Bash(rm *)"], "deny": ["Bash(rm *)"]}})
        self.assertIn("Bash(rm *) is in both allow and deny; deny wins", self.lint())

    def test_unexpected_shapes_are_silent(self):
        for content in ({"permissions": []}, {"permissions": {"allow": "Bash"}}, [], "null"):
            with self.subTest(content=content):
                self.write(self.user, content)
                self.assertEqual(self.lint(), "")

    def test_default_discovery_reads_user_and_project_files(self):
        for path in (self.user, self.shared, self.local):
            self.write(path, {"permissions": {"allow": ["Bash(ls)", "Bash(ls)"]}})
        message = self.lint()
        self.assertIn("~/.claude/settings.json", message)
        self.assertIn(str(self.shared), message)
        self.assertIn(str(self.local), message)

    def test_explicit_files_replace_discovery(self):
        other = self.tmp / "other.json"
        self.write(other, {"permissions": {"allow": ["Write(x)"]}})
        self.write(self.user, "{broken")
        message = self.lint(other)
        self.assertIn("Write(x)", message)
        self.assertNotIn("invalid JSON", message)

    def test_a_directory_in_place_of_a_file_is_silent(self):
        self.user.mkdir()
        self.assertEqual(self.lint(), "")

    def finding_file(self) -> Path:
        path = self.tmp / "with-finding.json"
        self.write(path, {"permissions": {"allow": ["Bash(ls)", "Bash(ls)"]}})
        return path

    def test_odd_shapes_do_not_hide_findings_in_other_files(self):
        odd = self.tmp / "odd.json"
        for content in ({"permissions": []}, {"permissions": {"allow": "Bash"}}, {"permissions": {"allow": [1]}},
                        [], "null"):
            with self.subTest(content=content):
                self.write(odd, content)
                self.assertIn("Bash(ls) appears 2 times", self.lint(odd, self.finding_file()))

    def test_an_undecodable_file_is_reported_without_hiding_other_findings(self):
        self.user.write_bytes(b'{"permissions": {"allow": ["Bash(caf\xe9)"]}}')
        self.write(self.shared, {"permissions": {"allow": ["Bash(ls)", "Bash(ls)"]}})
        message = self.lint()
        self.assertIn("not valid UTF-8", message)
        self.assertIn("Bash(ls) appears 2 times", message)

    def test_a_deeply_nested_file_is_reported(self):
        deep = self.tmp / "deep.json"
        self.write(deep, "[" * 100_000 + "]" * 100_000)
        message = self.lint(deep, self.finding_file())
        self.assertIn("could not be parsed", message)
        self.assertIn("Bash(ls) appears 2 times", message)

    def test_an_explicit_file_that_cannot_be_read_is_reported(self):
        directory = self.tmp / "a-directory"
        directory.mkdir()
        message = self.lint(self.tmp / "missing.json", directory, self.finding_file())
        self.assertEqual(message.count("cannot be read"), 2)
        self.assertIn("Bash(ls) appears 2 times", message)

    def test_a_project_directory_equal_to_home_is_read_once(self):
        self.write(self.user, {"permissions": {"allow": ["Bash(ls)", "Bash(ls)"]}})
        env_project = self.project
        self.project = self.home
        try:
            self.assertEqual(self.lint().count("~/.claude/settings.json"), 1)
        finally:
            self.project = env_project


    def test_a_rule_in_allow_and_ask_is_reported(self):
        self.write(self.user, {"permissions": {"allow": ["Bash(git push *)"], "ask": ["Bash(git push *)"]}})
        self.assertIn("Bash(git push *) is in both allow and ask; ask wins", self.lint())

    def test_a_rule_in_ask_and_deny_is_reported(self):
        self.write(self.user, {"permissions": {"ask": ["Bash(rm *)"], "deny": ["Bash(rm *)"]}})
        self.assertIn("Bash(rm *) is in both ask and deny; deny wins", self.lint())

    def test_hooks_json_runs_only_at_startup_and_never_blocks(self):
        config = json.loads((SCRIPT.parent / "hooks.json").read_text(encoding="utf-8"))
        entry = config["hooks"]["SessionStart"][0]
        self.assertEqual(entry["matcher"], "startup")
        self.assertTrue(entry["hooks"][0]["command"].endswith("|| true"))
        self.assertEqual(entry["hooks"][0]["timeout"], 10)

if __name__ == "__main__":
    unittest.main()
