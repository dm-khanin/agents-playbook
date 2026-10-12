from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "skill_lint.py"


def write_skill(root: Path, directory: str, frontmatter: str | None, body: str = "# Skill\n") -> Path:
    skill_dir = root / "skills" / directory
    skill_dir.mkdir(parents=True, exist_ok=True)
    text = body if frontmatter is None else f"---\n{frontmatter}\n---\n\n{body}"
    (skill_dir / "SKILL.md").write_text(text, encoding="utf-8")
    return skill_dir


def lint(root: Path) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(SCRIPT), "--root", str(root)], capture_output=True, text=True)


class SkillLintTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        (self.root / "skills").mkdir()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_valid_skill_passes(self):
        write_skill(self.root, "good-one", "name: good-one\ndescription: Does a thing.")
        result = lint(self.root)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_folded_description_is_read(self):
        write_skill(self.root, "folded", "name: folded\ndescription: >-\n  First line\n  second line.")
        self.assertEqual(lint(self.root).returncode, 0)

    def test_uppercase_or_underscore_name_fails(self):
        write_skill(self.root, "Bad_Name", "name: Bad_Name\ndescription: x")
        result = lint(self.root)
        self.assertEqual(result.returncode, 1)
        self.assertIn("skills/Bad_Name: name", result.stdout)

    def test_name_must_equal_directory(self):
        write_skill(self.root, "dir-name", "name: other-name\ndescription: x")
        self.assertIn("does not match directory", lint(self.root).stdout)

    def test_name_longer_than_64_fails(self):
        long_name = "a" * 65
        write_skill(self.root, long_name, f"name: {long_name}\ndescription: x")
        self.assertEqual(lint(self.root).returncode, 1)

    def test_missing_or_empty_description_fails(self):
        write_skill(self.root, "no-desc", "name: no-desc")
        write_skill(self.root, "empty-desc", "name: empty-desc\ndescription:")
        result = lint(self.root)
        self.assertIn("skills/no-desc: description", result.stdout)
        self.assertIn("skills/empty-desc: description", result.stdout)

    def test_description_over_1024_fails(self):
        write_skill(self.root, "long-desc", "name: long-desc\ndescription: " + "x" * 1025)
        self.assertEqual(lint(self.root).returncode, 1)

    def test_missing_frontmatter_fails(self):
        write_skill(self.root, "bare", None)
        self.assertIn("skills/bare: missing frontmatter", lint(self.root).stdout)

    def test_missing_skill_md_fails(self):
        (self.root / "skills" / "empty-dir").mkdir()
        self.assertIn("skills/empty-dir: missing SKILL.md", lint(self.root).stdout)

    def test_nested_skill_fails(self):
        outer = write_skill(self.root, "outer", "name: outer\ndescription: x")
        (outer / "inner").mkdir()
        (outer / "inner" / "SKILL.md").write_text("---\nname: inner\ndescription: x\n---\n", encoding="utf-8")
        self.assertIn("nested SKILL.md", lint(self.root).stdout)

    def test_file_at_skills_root_fails(self):
        (self.root / "skills" / "loose.md").write_text("x", encoding="utf-8")
        self.assertIn("skills/loose.md: skills must be directories", lint(self.root).stdout)

    def test_missing_skills_dir_exits_2(self):
        (self.root / "skills").rmdir()
        result = lint(self.root)
        self.assertEqual(result.returncode, 2)
        self.assertIn("skill-lint:", result.stderr)  # Python also exits 2 when the script is missing


if __name__ == "__main__":
    unittest.main()
