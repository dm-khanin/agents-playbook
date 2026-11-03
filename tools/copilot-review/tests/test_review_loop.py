"""Tests for the review-loop scripts (pr-state, pr-findings, pr-thread-close, copilot-review-watch) and the
review-body parser they share, run against a fake gh placed first on PATH.

The fake gh answers by route: the first route whose key occurs in the joined arguments wins. A route holds a
list of responses served in order, the last one repeating. A response of {"__fail__": true} makes gh exit 1.
When the script passes --jq, the fake runs that filter through jq, so the filters are tested too.
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PARSER = ROOT / "lib" / "copilot_body.py"
BOT = "copilot-pull-request-reviewer"

FAKE_GH = r'''#!/usr/bin/env python3
import json, os, subprocess, sys

state = os.environ["FAKE_GH_STATE"]
args = sys.argv[1:]
with open(os.path.join(state, "calls.jsonl"), "a") as log:
    log.write(json.dumps(args) + "\n")
joined = " ".join(args)
with open(os.path.join(state, "routes.json")) as f:
    routes = json.load(f)
for index, (key, responses) in enumerate(routes):
    if key in joined:
        break
else:
    print(f"fake gh: no route for {joined[:120]}", file=sys.stderr)
    sys.exit(1)
counter = os.path.join(state, f"count-{index}")
n = int(open(counter).read()) if os.path.exists(counter) else 0
with open(counter, "w") as f:
    f.write(str(n + 1))
response = responses[min(n, len(responses) - 1)]
if isinstance(response, dict) and response.get("__fail__"):
    print("gh: simulated API failure", file=sys.stderr)
    sys.exit(1)
if "--jq" in args:
    jq_filter = args[args.index("--jq") + 1]
    out = subprocess.run(["jq", "-r", jq_filter], input=json.dumps(response),
                         capture_output=True, text=True, check=True)
    sys.stdout.write(out.stdout)
else:
    print(json.dumps(response))
'''

# date +%s advances 30 s per call, so a watcher with max_minutes=1 polls exactly once.
FAKE_DATE = r'''#!/bin/sh
f="$FAKE_GH_STATE/date-count"
n=$(cat "$f" 2>/dev/null || echo 0)
echo $((n + 1)) > "$f"
echo $((1000 + n * 30))
'''

NESTED_MISSED = """Copilot reviewed 3 files. No open issues.

<details>
<summary>1 previously missed issue</summary>
<details>
<summary><picture><img alt="medium severity" src="x.svg"></picture> Null check is missing</summary>

`src/​app/​main.ts:12`

The value can be undefined when the cache is cold.
</details>
</details>

Review effort: Balanced
"""

FLAT_SUPPRESSED = """<details>
<summary>Comments suppressed due to low confidence (1)</summary>

**lib/util.py:3-5**
* Consider a clearer name. The current one hides the unit.
</details>
"""

HEADING_SUPPRESSED = """### Suppressed comments (1)

**run.sh:7**
* Quote the variable.

---
Review effort: Lite
"""


def write_executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


def parse(body, fmt):
    result = subprocess.run(["python3", "-I", str(PARSER), "--format", fmt], input=body,
                            capture_output=True, text=True, check=True)
    return result.stdout


class CopilotBodyTest(unittest.TestCase):
    def test_nested_missed_finding_has_severity_location_and_title(self):
        [finding] = json.loads(parse(NESTED_MISSED, "json"))["findings"]
        self.assertEqual(finding["kind"], "missed")
        self.assertEqual(finding["severity"], "medium")
        self.assertEqual(finding["location"], "src/app/main.ts:12")  # zero-width spaces removed
        self.assertEqual(finding["title"], "Null check is missing")
        self.assertIn("cache is cold", finding["text"])

    def test_flat_details_and_heading_shapes_are_suppressed_findings(self):
        findings = json.loads(parse(FLAT_SUPPRESSED + HEADING_SUPPRESSED, "json"))["findings"]
        self.assertEqual([(f["kind"], f["location"]) for f in findings],
                         [("suppressed", "lib/util.py:3-5"), ("suppressed", "run.sh:7")])
        self.assertEqual(findings[0]["title"], "Consider a clearer name.")

    def test_count_splits_by_kind(self):
        body = NESTED_MISSED + FLAT_SUPPRESSED + HEADING_SUPPRESSED
        self.assertEqual(parse(body, "count").strip(), "3 (missed 1, suppressed 2)")

    def test_clean_body_counts_zero_and_reads_effort(self):
        body = "Copilot reviewed 2 files and generated no comments.\n\nReview effort: Lite\n"
        self.assertEqual(parse(body, "count").strip(), "0")
        self.assertEqual(parse(body, "effort").strip(), "Lite")
        self.assertEqual(parse("no effort line", "effort").strip(), "")

    def test_lines_and_full_formats(self):
        lines = parse(NESTED_MISSED, "lines")
        self.assertEqual(lines, "  - [missed medium] src/app/main.ts:12 — Null check is missing\n")
        self.assertIn("      The value can be undefined", parse(NESTED_MISSED, "full"))


class ScriptTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.state = root / "state"
        self.state.mkdir()
        self.bin = root / "bin"
        self.bin.mkdir()
        write_executable(self.bin / "gh", FAKE_GH)
        write_executable(self.bin / "sleep", "#!/bin/sh\nexit 0\n")
        self.env = {**os.environ, "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
                    "FAKE_GH_STATE": str(self.state)}

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, script, *args, routes=()):
        (self.state / "routes.json").write_text(json.dumps([list(r) for r in routes]))
        return subprocess.run([str(ROOT / script), *args], env=self.env, capture_output=True, text=True,
                              timeout=30)

    def calls(self):
        log = self.state / "calls.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []


class UsageTest(ScriptTestCase):
    def test_bad_arguments_exit_2_without_calling_gh(self):
        cases = {
            "pr-state.sh": ([], ["acme/widgets"], ["widgets", "42"], ["/widgets", "42"], ["acme/", "42"],
                            ["acme/widgets", "4x"]),
            "pr-findings.sh": (["widgets", "42"], ["acme/widgets", "42", "--fll"], ["acme/widgets", "x"]),
            "pr-thread-close.sh": (["widgets", "42", "7", "f"], ["acme/widgets", "42", "x7", "f"],
                                   ["acme/widgets", "42", "7", "/nonexistent/reply"]),
            "copilot-review-watch.sh": (["widgets", "42"], ["acme/", "42"], ["acme/widgets", "4x"],
                                        ["acme/widgets", "42", "fast"]),
        }
        for script, arg_lists in cases.items():
            for args in arg_lists:
                with self.subTest(script=script, args=args):
                    result = self.run_script(script, *args)
                    self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.calls(), [])


def pr_state_response(head="head2", copilot_on="head2", body="Review effort: Balanced", threads=()):
    reviews = [{"author": {"login": "alice"}, "state": "APPROVED", "submittedAt": "t1", "body": "",
                "commit": {"oid": head}}]
    if copilot_on:
        reviews.append({"author": {"login": BOT}, "state": "COMMENTED", "submittedAt": "t2", "body": body,
                        "commit": {"oid": copilot_on}})
    return {"data": {"repository": {"pullRequest": {
        "title": "Add widgets", "url": "https://github.com/acme/widgets/pull/42", "state": "OPEN",
        "isDraft": False, "mergeable": "MERGEABLE", "baseRefName": "main", "headRefName": "feat/w",
        "headRefOid": head,
        "commits": {"nodes": [{"commit": {"committedDate": "t0", "statusCheckRollup": {"state": "SUCCESS",
            "contexts": {"nodes": [{"__typename": "CheckRun", "name": "ci", "conclusion": "SUCCESS"}]}}}}]},
        "reviewRequests": {"nodes": []},
        "reviewThreads": {"nodes": [{"isResolved": resolved, "isOutdated": False,
                                     "comments": {"nodes": [{"author": {"login": "Copilot"}, "path": path}]}}
                                    for path, resolved in threads]},
        "reviews": {"nodes": reviews},
    }}}}


class PrStateTest(ScriptTestCase):
    def test_copilot_saw_the_head_with_no_body_findings(self):
        response = pr_state_response(threads=(("a.ts", True), ("b.ts", False)))
        result = self.run_script("pr-state.sh", "acme/widgets", "42", routes=[("graphql", [response])])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ci: SUCCESS", result.stdout)
        self.assertIn("threads: 2 total, 1 open", result.stdout)
        self.assertIn("  - open: b.ts by Copilot", result.stdout)
        self.assertIn("saw the head", result.stdout)
        self.assertIn("copilot body findings: 0, effort Balanced", result.stdout)
        self.assertNotIn("pr-findings.sh", result.stdout)

    def test_stale_copilot_review_and_body_findings_point_to_the_next_step(self):
        response = pr_state_response(head="head2", copilot_on="head1", body=NESTED_MISSED)
        result = self.run_script("pr-state.sh", "acme/widgets", "42", routes=[("graphql", [response])])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("has NOT seen the head", result.stdout)
        self.assertIn("copilot body findings: 1 (missed 1, suppressed 0)", result.stdout)
        self.assertIn("list them: pr-findings.sh acme/widgets 42", result.stdout)

    def test_no_copilot_review(self):
        result = self.run_script("pr-state.sh", "acme/widgets", "42",
                                 routes=[("graphql", [pr_state_response(copilot_on=None)])])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("copilot: no review yet", result.stdout)
        self.assertNotIn("body findings", result.stdout)

    def test_failed_query_fails_the_script(self):
        result = self.run_script("pr-state.sh", "acme/widgets", "42", routes=[("graphql", [{"__fail__": True}])])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("simulated API failure", result.stderr)


def reviews_response(*reviews):
    return {"data": {"repository": {"pullRequest": {"reviews": {"nodes": [
        {"author": {"login": login}, "submittedAt": "2026-10-20T11:00:00Z", "commit": {"oid": oid}, "body": body}
        for login, oid, body in reviews]}}}}}


class PrFindingsTest(ScriptTestCase):
    def test_lists_findings_of_the_latest_copilot_review_only(self):
        response = reviews_response((BOT, "old000000", "Review effort: Lite"), ("alice", "x", NESTED_MISSED),
                                    (BOT, "new111111", NESTED_MISSED + HEADING_SUPPRESSED))
        result = self.run_script("pr-findings.sh", "acme/widgets", "42", routes=[("graphql", [response])])
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[0], "copilot review on new111111 at 2026-10-20T11:00:00Z, effort Balanced: "
                                   "body findings 2 (missed 1, suppressed 1)")
        self.assertEqual(lines[1:], ["  - [missed medium] src/app/main.ts:12 — Null check is missing",
                                     "  - [suppressed] run.sh:7 — Quote the variable."])

    def test_full_adds_the_text(self):
        response = reviews_response((BOT, "new111111", NESTED_MISSED))
        result = self.run_script("pr-findings.sh", "acme/widgets", "42", "--full", routes=[("graphql", [response])])
        self.assertIn("      The value can be undefined", result.stdout)

    def test_no_copilot_review_yet(self):
        response = reviews_response(("alice", "x", ""))
        result = self.run_script("pr-findings.sh", "acme/widgets", "42", routes=[("graphql", [response])])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "copilot: no review yet on acme/widgets#42")


def threads_response(*threads):
    return {"data": {"repository": {"pullRequest": {"reviewThreads": {
        "pageInfo": {"hasNextPage": False, "endCursor": None},
        "nodes": [{"id": tid, "isResolved": False, "comments": {"nodes": [{"databaseId": c} for c in ids]}}
                  for tid, ids in threads]}}}}}


def resolved_response(value):
    return {"data": {"resolveReviewThread": {"thread": {"isResolved": value}}}}


class PrThreadCloseTest(ScriptTestCase):
    def setUp(self):
        super().setUp()
        self.reply = Path(self.tmp.name) / "reply.md"
        self.reply.write_text("Fixed in the next commit.\n")
        self.threads = threads_response(("T_other", [5]), ("T_target", [777, 778]))

    def close(self, *routes):
        return self.run_script("pr-thread-close.sh", "acme/widgets", "42", "777", str(self.reply), routes=routes)

    def writes(self):
        return [args for args in self.calls() if "replies" in " ".join(args) or "resolveReviewThread" in " ".join(args)]

    def test_replies_then_resolves_the_thread_holding_the_comment(self):
        result = self.close(("resolveReviewThread", [resolved_response(True)]),
                            ("comments/777/replies", [{"html_url": "https://github.com/acme/widgets/pull/42#r9"}]),
                            ("reviewThreads", [self.threads]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("replied: https://github.com/acme/widgets/pull/42#r9", result.stdout)
        self.assertIn("resolved: thread T_target", result.stdout)
        reply_call, resolve_call = self.writes()
        self.assertIn(f"body=@{self.reply}", reply_call)
        self.assertIn("id=T_target", resolve_call)

    def test_comment_not_in_any_thread_writes_nothing(self):
        result = self.close(("reviewThreads", [threads_response(("T_other", [5]))]))
        self.assertEqual(result.returncode, 1)
        self.assertIn("nothing written", result.stderr)
        self.assertEqual(self.writes(), [])

    def test_reply_without_url_is_not_resolved(self):
        result = self.close(("resolveReviewThread", [resolved_response(True)]),
                            ("comments/777/replies", [{}]), ("reviewThreads", [self.threads]))
        self.assertEqual(result.returncode, 1)
        self.assertIn("no html_url", result.stderr)
        self.assertFalse(any("resolveReviewThread" in " ".join(a) for a in self.calls()))

    def test_resolve_that_does_not_stick_says_the_thread_is_open(self):
        result = self.close(("resolveReviewThread", [resolved_response(False)]),
                            ("comments/777/replies", [{"html_url": "u"}]), ("reviewThreads", [self.threads]))
        self.assertEqual(result.returncode, 1)
        self.assertIn("isResolved=false — it is still open", result.stderr)

    def test_failed_thread_lookup_is_not_reported_as_not_found(self):
        result = self.close(("reviewThreads", [{"__fail__": True}]))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("is not in any review thread", result.stderr)
        self.assertEqual(self.writes(), [])


def review(review_id, login):
    return {"id": review_id, "user": {"login": login}}


class WatchTest(ScriptTestCase):
    def setUp(self):
        super().setUp()
        write_executable(self.bin / "date", FAKE_DATE)

    def watch(self, *routes):
        return self.run_script("copilot-review-watch.sh", "acme/widgets", "42", "30", "1", routes=routes)

    def test_new_review_signed_with_the_bot_login_fires(self):
        # The reviews endpoint signs as copilot-pull-request-reviewer[bot], not as the inline "Copilot".
        signed = f"{BOT}[bot]"
        result = self.watch(("reviews/9", [{"state": "COMMENTED", "body": "1 previously missed issue"}]),
                            ("reviews?per_page", [[review(5, signed)], [review(5, signed), review(9, signed)]]),
                            ("graphql", ["2"]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("new bot review on acme/widgets#42: review id 9, state COMMENTED", result.stdout)
        self.assertIn("body-flag 1", result.stdout)

    def test_first_ever_review_beats_an_empty_baseline(self):
        signed = f"{BOT}[bot]"
        result = self.watch(("reviews/3", [{"state": "COMMENTED", "body": ""}]),
                            ("reviews?per_page", [[], [review(3, signed)]]), ("graphql", ["0"]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("review id 3", result.stdout)

    def test_human_review_does_not_fire_and_the_watch_times_out(self):
        signed = f"{BOT}[bot]"
        result = self.watch(("reviews?per_page", [[review(5, signed)], [review(5, signed), review(99, "alice")]]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no new review on acme/widgets#42 after 1min (baseline id 5)", result.stdout)

    def test_unreadable_baseline_refuses_to_arm(self):
        result = self.watch(("reviews?per_page", [{"__fail__": True}]))
        self.assertEqual(result.returncode, 2)
        self.assertIn("not arming", result.stderr)


if __name__ == "__main__":
    unittest.main()
