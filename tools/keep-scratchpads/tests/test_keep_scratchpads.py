"""Tests for keep-scratchpads.sh against a temporary scratchpad root and projects directory."""

import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "keep-scratchpads.sh"
DAY = 86400


class KeepScratchpadsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.root = base / "tmp-root"
        self.projects = base / "projects"
        self.now = time.time()
        self.old = self.now - 10 * DAY

    def tearDown(self):
        self.tmp.cleanup()

    def scratch_file(self, project, session):
        path = self.root / project / session / "scratchpad" / "notes.md"
        path.parent.mkdir(parents=True)
        path.write_text("x")
        os.utime(path, (self.old, self.old))
        return path

    def transcript(self, project, session, age_days):
        path = self.projects / project / f"{session}.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("{}\n")
        stamp = self.now - age_days * DAY
        os.utime(path, (stamp, stamp))

    def run_script(self, **extra):
        env = {**os.environ, "KEEP_SCRATCHPADS_ROOT": str(self.root),
               "KEEP_SCRATCHPADS_PROJECTS": str(self.projects), **extra}
        return subprocess.run([str(SCRIPT)], env=env, capture_output=True, text=True, timeout=30)

    def refreshed(self, path):
        return path.stat().st_atime > self.old + DAY

    def test_only_recent_sessions_are_refreshed(self):
        recent = self.scratch_file("proj", "s-recent")
        stale = self.scratch_file("proj", "s-stale")
        orphan = self.scratch_file("proj", "s-orphan")
        self.transcript("proj", "s-recent", age_days=1)
        self.transcript("proj", "s-stale", age_days=40)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.refreshed(recent))
        self.assertFalse(self.refreshed(stale))
        self.assertFalse(self.refreshed(orphan))

    def test_modification_time_is_kept(self):
        recent = self.scratch_file("proj", "s1")
        self.transcript("proj", "s1", age_days=0)
        self.run_script()
        self.assertAlmostEqual(recent.stat().st_mtime, self.old, delta=1)

    def test_keep_days_narrows_the_window(self):
        path = self.scratch_file("proj", "s1")
        self.transcript("proj", "s1", age_days=5)
        self.run_script(KEEP_DAYS="3")
        self.assertFalse(self.refreshed(path))
        self.run_script(KEEP_DAYS="7")
        self.assertTrue(self.refreshed(path))

    def test_missing_root_is_a_quiet_success(self):
        result = self.run_script()
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_bad_keep_days_is_a_usage_error(self):
        result = self.run_script(KEEP_DAYS="month")
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
