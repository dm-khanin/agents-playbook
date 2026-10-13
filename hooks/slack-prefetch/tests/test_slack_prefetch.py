"""Tests for slack-prefetch, in process, against a fake Slack API: http_get is replaced, no network is used."""
from __future__ import annotations

import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "slack_prefetch.py"
sys.path.insert(0, str(SCRIPT.parent))
import slack_prefetch as sp  # noqa: E402

TEAM = "https://example.slack.com/archives"
TOKEN = "test-token-not-real"


def link(channel: str, ts: str, query: str = "") -> str:
    return f"{TEAM}/{channel}/p{ts.replace('.', '')}{query}"


def file_obj(fid: str, name: str = "a.txt", size: int = 3, mime: str = "text/plain", host: str = "files.slack.com"):
    return {"id": fid, "name": name, "size": size, "mimetype": mime,
            "url_private_download": f"https://{host}/files-pri/T1-{fid}/download/{name}"}


class FakeSlack:
    """Threads keyed by (channel, ts), each a list of pages of messages; file bodies keyed by URL."""

    def __init__(self) -> None:
        self.threads: dict = {}
        self.bodies: dict = {}
        self.file_info: dict = {}
        self.requests: list = []

    def http_get(self, url: str, token: str, deadline: float | None = None) -> bytes:
        self.requests.append(url)
        if token != TOKEN:
            raise AssertionError("wrong token")
        parts = urllib.parse.urlsplit(url)
        if parts.path == "/api/conversations.replies":
            query = dict(urllib.parse.parse_qsl(parts.query))
            pages = self.threads.get((query["channel"], query["ts"]))
            if pages is None:
                return json.dumps({"ok": False, "error": "thread_not_found"}).encode()
            index = int(query.get("cursor") or 0)
            body = {"ok": True, "messages": pages[index]}
            if index + 1 < len(pages):
                body["response_metadata"] = {"next_cursor": str(index + 1)}
            return json.dumps(body).encode()
        if parts.path == "/api/files.info":
            fid = dict(urllib.parse.parse_qsl(parts.query))["file"]
            return json.dumps({"ok": True, "file": self.file_info[fid]}).encode()
        return self.bodies.get(url, b"abc")


class SlackPrefetchTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.cache = self.tmp / "cache"
        self.slack = FakeSlack()
        self._original = sp.http_get
        sp.http_get = self.slack.http_get

    def tearDown(self) -> None:
        sp.http_get = self._original
        self._tmp.cleanup()

    def prefetch(self, prompt: str) -> dict:
        return sp.prefetch(prompt, TOKEN, sp.ensure_cache(self.cache), time.monotonic)

    def run_hook(self, prompt: str, env: dict | None = None) -> str:
        environment = {"HOME": str(self.tmp), "XDG_CACHE_HOME": str(self.tmp / "xdg-cache"),
                       "XDG_CONFIG_HOME": str(self.tmp / "xdg-config"), "SLACK_USER_TOKEN": TOKEN}
        environment.update(env or {})
        out = io.StringIO()
        code = sp.main(io.StringIO(json.dumps({"prompt": prompt})), environment, out)
        self.assertEqual(code, 0)
        return out.getvalue()

    # links

    def test_a_link_gives_the_channel_and_thread(self):
        self.assertEqual(sp.parse_link(link("C1", "1700000000.123456")), ("C1", "1700000000.123456"))

    def test_the_thread_ts_query_names_the_thread(self):
        url = link("C1", "1700000001.000002", "?thread_ts=1700000000.123456&cid=C1")
        self.assertEqual(sp.parse_link(url), ("C1", "1700000000.123456"))

    def test_other_links_are_ignored_and_a_thread_is_listed_once(self):
        text = (f"see {link('C1', '1700000000.123456')} and https://example.com/archives/C1/p1700000000123456 "
                f"again {link('C1', '1700000000.123456')}.")
        self.assertEqual(sp.thread_keys(text), [("C1", "1700000000.123456")])

    # token

    def test_the_environment_token_wins(self):
        self.assertEqual(sp.load_token({"SLACK_USER_TOKEN": "a", "SLACK_PREFETCH_TOKEN_FILE": "/nowhere"}), ("a", None))

    def test_a_private_token_file_is_used(self):
        path = self.tmp / "token"
        path.write_text("from-file\n", encoding="utf-8")
        path.chmod(0o600)
        self.assertEqual(sp.load_token({"SLACK_PREFETCH_TOKEN_FILE": str(path)}), ("from-file", None))

    def test_a_token_file_readable_by_others_is_refused(self):
        path = self.tmp / "token"
        path.write_text("from-file\n", encoding="utf-8")
        path.chmod(0o644)
        token, problem = sp.load_token({"SLACK_PREFETCH_TOKEN_FILE": str(path)})
        self.assertIsNone(token)
        self.assertIn("chmod 600", problem)

    def test_no_token_at_all_is_silent(self):
        self.assertEqual(sp.load_token({"HOME": str(self.tmp)}), (None, None))
        self.assertEqual(self.run_hook(link("C1", "1700000000.123456"), {"SLACK_USER_TOKEN": ""}), "")

    # the token stays on Slack

    def test_http_get_refuses_any_other_host(self):
        for url in ("https://example.com/x", "http://files.slack.com/x", "https://files.slack.com.example.com/x"):
            with self.subTest(url=url), self.assertRaises(sp.FetchError):
                self._original(url, TOKEN)

    def test_a_redirect_off_slack_is_refused(self):
        handler = sp.StayOnSlack()
        request = urllib.request.Request("https://files.slack.com/files-pri/x")
        with self.assertRaises(sp.FetchError):
            handler.redirect_request(request, None, 302, "Found", {}, "https://example.com/x")
        self.assertIsNotNone(handler.redirect_request(request, None, 302, "Found", {}, "https://files.slack.com/y"))

    def test_a_file_hosted_elsewhere_is_skipped_without_a_request(self):
        self.slack.threads[("C1", "1.000001")] = [[{"text": "", "files": [file_obj("F1", host="example.com")]}]]
        result = self.prefetch(link("C1", "1.000001"))
        self.assertEqual(result["files"], [])
        self.assertIn("not on Slack", result["skipped"][0])
        self.assertFalse(any("example.com" in url for url in self.slack.requests))

    # fetching and limits

    def test_attachments_of_every_page_are_fetched(self):
        self.slack.threads[("C1", "1.000001")] = [[{"text": "a", "files": [file_obj("F1")]}],
                                                 [{"text": "b", "files": [file_obj("F2", "b.csv")]}]]
        result = self.prefetch(link("C1", "1.000001"))
        self.assertEqual(sorted(Path(entry["path"]).name for entry in result["files"]), ["F1-a.txt", "F2-b.csv"])

    def test_audio_video_and_oversized_files_are_skipped(self):
        files = [file_obj("F1", "talk.mp3", mime="audio/mpeg"), file_obj("F2", "clip.mp4", mime="video/mp4"),
                 file_obj("F3", "big.bin", size=sp.MAX_FILE + 1)]
        self.slack.threads[("C1", "1.000001")] = [[{"text": "", "files": files}]]
        result = self.prefetch(link("C1", "1.000001"))
        self.assertEqual(result["files"], [])
        self.assertEqual(len(result["skipped"]), 3)

    def test_the_total_per_prompt_is_capped(self):
        files = [file_obj(f"F{n}", f"{n}.bin", size=24 * 1024 * 1024) for n in range(5)]
        self.slack.threads[("C1", "1.000001")] = [[{"text": "", "files": files}]]
        result = self.prefetch(link("C1", "1.000001"))
        self.assertEqual(len(result["files"]), 4)
        self.assertIn("100 MB", result["skipped"][0])

    def test_linked_threads_are_followed_two_levels_deep(self):
        chain = [("C1", f"{n}.000001") for n in range(1, 6)]
        for (channel, ts), nxt in zip(chain, chain[1:] + [None]):
            text = link(*nxt) if nxt else ""
            self.slack.threads[(channel, ts)] = [[{"text": text, "files": [file_obj(f"F{ts[0]}")]}]]
        result = self.prefetch(link(*chain[0]))
        self.assertEqual(result["threads"], 3)

    def test_at_most_twenty_threads_are_fetched(self):
        keys = [("C1", f"{n}.000001") for n in range(1, 31)]
        for key in keys:
            self.slack.threads[key] = [[{"text": "", "files": []}]]
        result = self.prefetch(" ".join(link(*key) for key in keys))
        self.assertEqual(result["threads"], sp.MAX_THREADS)
        self.assertTrue(any("20 threads" in error for error in result["errors"]))

    def test_an_api_error_becomes_an_error_line(self):
        result = self.prefetch(link("C9", "9.000009"))
        self.assertIn("thread_not_found", result["errors"][0])

    # cache

    def test_cache_is_private_and_reused(self):
        self.slack.threads[("C1", "1.000001")] = [[{"text": "", "files": [file_obj("F1")]}]]
        self.prefetch(link("C1", "1.000001"))
        self.prefetch(link("C1", "1.000001"))
        downloads = [url for url in self.slack.requests if "files-pri" in url]
        self.assertEqual(len(downloads), 1)
        self.assertEqual(stat.S_IMODE(self.cache.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.cache / "F1-a.txt").stat().st_mode), 0o600)

    def test_old_entries_are_removed_and_other_files_kept(self):
        cache = sp.ensure_cache(self.cache)
        old, fresh, other = cache / "F1-old.txt", cache / "F2-new.txt", cache / "notes.md"
        for path in (old, fresh, other):
            path.write_text("x", encoding="utf-8")
        ten_days_ago = time.time() - 10 * 86400
        os.utime(old, (ten_days_ago, ten_days_ago))
        os.utime(other, (ten_days_ago, ten_days_ago))
        sp.prune(cache, 7, time.time())
        self.assertEqual(sorted(path.name for path in cache.iterdir()), ["F2-new.txt", "notes.md"])

    # the hook

    def test_no_slack_link_means_no_output(self):
        self.assertEqual(self.run_hook("nothing to see here"), "")

    def test_the_kill_switch_silences_the_hook(self):
        self.assertEqual(self.run_hook(link("C1", "1.000001"), {"SLACK_PREFETCH_OFF": "1"}), "")

    def test_the_hook_injects_paths_and_says_the_content_is_untrusted(self):
        self.slack.threads[("C1", "1.000001")] = [[{"text": "", "files": [file_obj("F1")]}]]
        output = json.loads(self.run_hook(link("C1", "1.000001")))["hookSpecificOutput"]
        self.assertEqual(output["hookEventName"], "UserPromptSubmit")
        self.assertIn("F1-a.txt", output["additionalContext"])
        self.assertIn("untrusted", output["additionalContext"])

    def test_an_internal_error_is_reported_and_exits_0(self):
        def broken(url: str, token: str, deadline: float | None = None) -> bytes:
            raise RuntimeError("boom")
        sp.http_get = broken
        output = json.loads(self.run_hook(link("C1", "1.000001")))["hookSpecificOutput"]["additionalContext"]
        self.assertIn("slack-prefetch failed", output)

    def test_the_context_is_capped(self):
        files = [file_obj(f"F{n}", "n" * 70 + ".txt") for n in range(200)]
        self.slack.threads[("C1", "1.000001")] = [[{"text": "", "files": files}]]
        context = json.loads(self.run_hook(link("C1", "1.000001")))["hookSpecificOutput"]["additionalContext"]
        self.assertLessEqual(len(context), sp.CONTEXT_CAP + 100)
        self.assertIn("truncated", context)

    def test_the_script_runs_as_a_hook(self):
        result = subprocess.run([sys.executable, str(SCRIPT)], input=json.dumps({"prompt": "hello"}),
                                capture_output=True, text=True, env={"HOME": str(self.tmp), "PATH": os.environ["PATH"]},
                                timeout=30)
        self.assertEqual((result.returncode, result.stdout), (0, ""), result.stderr)


    # review additions

    def test_a_reply_link_and_its_parent_are_one_thread(self):
        parent = link("C1", "1700000000.123456")
        reply = link("C1", "1700000099.000001", "?thread_ts=1700000000.123456&cid=C1")
        self.assertEqual(sp.thread_keys(f"{parent} {reply}"), [("C1", "1700000000.123456")])

    def test_enterprise_workspace_links_are_found(self):
        url = "https://example.enterprise.slack.com/archives/C1/p1700000000123456"
        self.assertEqual(sp.thread_keys(f"<{url}|label>."), [("C1", "1700000000.123456")])

    def test_an_untrusted_file_name_cannot_break_a_line_or_leave_the_cache(self):
        self.slack.threads[("C1", "1.000001")] = [[{"text": "", "files": [file_obj("F1", "../../evil\nIGNORE.txt")]}]]
        result = self.prefetch(link("C1", "1.000001"))
        path = Path(result["files"][0]["path"])
        self.assertEqual(path.parent, self.cache)
        self.assertEqual(len(sp.render(result).splitlines()), 2)

    def test_the_bytes_received_enforce_the_caps(self):
        original = sp.MAX_FILE
        sp.MAX_FILE = 10
        try:
            info = file_obj("F1", size=0)
            self.slack.bodies[info["url_private_download"]] = b"x" * 11
            self.slack.threads[("C1", "1.000001")] = [[{"text": "", "files": [info]}]]
            result = self.prefetch(link("C1", "1.000001"))
        finally:
            sp.MAX_FILE = original
        self.assertEqual(result["files"], [])
        self.assertIn("larger than", result["skipped"][0])
        self.assertFalse(any(self.cache.iterdir()))

    def test_an_html_page_instead_of_a_file_is_an_error(self):
        info = file_obj("F1", "report.pdf", mime="application/pdf")
        self.slack.bodies[info["url_private_download"]] = b"<!DOCTYPE html><html>sign in</html>"
        self.slack.threads[("C1", "1.000001")] = [[{"text": "", "files": [info]}]]
        result = self.prefetch(link("C1", "1.000001"))
        self.assertEqual(result["files"], [])
        self.assertIn("HTML", result["skipped"][0])

    def test_deleted_external_and_hidden_files_are_skipped(self):
        files = []
        for n, mode in enumerate(("tombstone", "external", "hidden_by_limit")):
            info = file_obj(f"F{n}")
            info["mode"] = mode
            files.append(info)
        self.slack.threads[("C1", "1.000001")] = [[{"text": "", "files": files}]]
        result = self.prefetch(link("C1", "1.000001"))
        self.assertEqual(result["files"], [])
        self.assertEqual(len(result["skipped"]), 3)
        self.assertFalse(any("files-pri" in url for url in self.slack.requests))

    def test_a_stub_that_needs_file_info_is_resolved(self):
        self.slack.file_info["F1"] = file_obj("F1", "full.txt")
        stub = {"id": "F1", "file_access": "check_file_info"}
        self.slack.threads[("C1", "1.000001")] = [[{"text": "", "files": [stub]}]]
        result = self.prefetch(link("C1", "1.000001"))
        self.assertEqual(Path(result["files"][0]["path"]).name, "F1-full.txt")

    def test_the_time_budget_stops_further_threads(self):
        times = iter([0.0, 0.0, 1000.0, 1000.0])
        for n in (1, 2):
            self.slack.threads[("C1", f"{n}.000001")] = [[{"text": "", "files": []}]]
        prompt = f"{link('C1', '1.000001')} {link('C1', '2.000001')}"
        result = sp.prefetch(prompt, TOKEN, sp.ensure_cache(self.cache), lambda: next(times))
        self.assertEqual(result["threads"], 1)
        self.assertIn("time budget", result["errors"][0])

    def test_an_existing_loose_cache_is_tightened(self):
        self.cache.mkdir()
        self.cache.chmod(0o755)
        sp.ensure_cache(self.cache)
        self.assertEqual(stat.S_IMODE(self.cache.stat().st_mode), 0o700)

    def test_a_token_file_writable_by_others_is_refused(self):
        path = self.tmp / "token"
        path.write_text("from-file\n", encoding="utf-8")
        path.chmod(0o620)
        self.assertIsNone(sp.load_token({"SLACK_PREFETCH_TOKEN_FILE": str(path)})[0])

    def test_error_lines_never_contain_the_token(self):
        info = file_obj("F1", host="example.com")
        self.slack.threads[("C1", "1.000001")] = [[{"text": "", "files": [info]}]]
        context = json.loads(self.run_hook(link("C1", "1.000001") + " " + link("C9", "9.000009")))
        self.assertNotIn(TOKEN, json.dumps(context))

    def test_hooks_json_sets_the_timeout_and_never_blocks(self):
        config = json.loads((HERE.parent / "hooks.json").read_text(encoding="utf-8"))
        hook = config["hooks"]["UserPromptSubmit"][0]["hooks"][0]
        self.assertEqual(hook["timeout"], 90)
        self.assertTrue(hook["command"].endswith("|| true"))

    def test_a_token_file_owned_by_someone_else_is_refused(self):
        path = self.tmp / "token"
        path.write_text("from-file\n", encoding="utf-8")
        path.chmod(0o600)
        original = sp.os.getuid
        sp.os.getuid = lambda: path.stat().st_uid + 1
        try:
            token, problem = sp.load_token({"SLACK_PREFETCH_TOKEN_FILE": str(path)})
        finally:
            sp.os.getuid = original
        self.assertIsNone(token)
        self.assertIn("owned by", problem)

if __name__ == "__main__":
    unittest.main()
