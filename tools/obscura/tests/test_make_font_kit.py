from __future__ import annotations

import subprocess
import sys
import tempfile
import unicodedata
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "make_font_kit.py"
sys.path.insert(0, str(SCRIPT.parent))
import make_font_kit  # noqa: E402


class MakeFontKitTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.src = Path(self._tmp.name) / "src"
        self.dest = Path(self._tmp.name) / "dest"
        self.src.mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def populate(self, names):
        for i, name in enumerate(names):
            (self.src / unicodedata.normalize("NFD", name)).write_bytes(b"font" * (i + 1))

    def run_kit(self):
        return subprocess.run([sys.executable, str(SCRIPT), str(self.dest), "--source", str(self.src)],
                              capture_output=True, text=True)

    def test_copies_every_font_as_a_regular_file(self):
        self.populate(make_font_kit.FONTS)
        result = self.run_kit()
        self.assertEqual(result.returncode, 0, result.stderr)
        copied = sorted(self.dest.iterdir())
        self.assertEqual(len(copied), len(make_font_kit.FONTS))
        for path in copied:
            self.assertTrue(path.is_file() and not path.is_symlink(), path)

    def test_missing_font_exits_1_after_copying_the_rest(self):
        self.populate(make_font_kit.FONTS[1:])
        result = self.run_kit()
        self.assertEqual(result.returncode, 1)
        self.assertIn(make_font_kit.FONTS[0], result.stderr)
        self.assertEqual(len(list(self.dest.iterdir())), len(make_font_kit.FONTS) - 1)

    def test_second_run_is_idempotent(self):
        self.populate(make_font_kit.FONTS)
        self.run_kit()
        result = self.run_kit()
        self.assertEqual(result.returncode, 0)
        self.assertIn("already present", result.stdout)


if __name__ == "__main__":
    unittest.main()
