"""Tests for copilot-review.sh, run against a fake gh and a no-op sleep placed first on PATH.

The fake gh answers state queries with canned GraphQL responses, in order, and runs the script's own --jq
filter through jq, so the filter is exercised as well as the shell logic. Mutations are only recorded.
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "copilot-review.sh"
BOT = "copilot-pull-request-reviewer"
BOT_ID = "BOT_kgDOCnlnWA"

FAKE_GH = r'''#!/usr/bin/env python3
import json, os, subprocess, sys

state = os.environ["FAKE_GH_STATE"]
args = sys.argv[1:]
with open(os.path.join(state, "calls.jsonl"), "a") as log:
    log.write(json.dumps(args) + "\n")
query = next(a.split("=", 1)[1] for a in args if a.startswith("query="))
if "mutation" in query:
    print("{}")
    sys.exit(0)
if os.path.exists(os.path.join(state, "fail_query")):
    print("gh: simulated API failure", file=sys.stderr)
    sys.exit(1)
with open(os.path.join(state, "responses.json")) as f:
    responses = json.load(f)
counter = os.path.join(state, "count")
n = int(open(counter).read()) if os.path.exists(counter) else 0
with open(counter, "w") as f:
    f.write(str(n + 1))
response = responses[min(n, len(responses) - 1)]
jq_filter = args[args.index("--jq") + 1]
out = subprocess.run(["jq", "-r", jq_filter], input=json.dumps(response),
                     capture_output=True, text=True, check=True)
sys.stdout.write(out.stdout)
'''


def pr(state="OPEN", draft=False, head="head2", pending=(), reviews=(), event=None):
    """One GraphQL state response.

    pending: "bot" for a pending Copilot request, "user" for a pending human one (a User node selected only
    through "... on Bot" comes back as an empty object). reviews: (author, commit) pairs, oldest first.
    event: (event id, requested reviewer login or None) for the latest ReviewRequestedEvent.
    """
    requested = [{"requestedReviewer": {"login": BOT} if who == "bot" else {}} for who in pending]
    review_nodes = [{"author": {"login": author}, "commit": {"oid": oid}} for author, oid in reviews]
    events = []
    if event:
        event_id, reviewer = event
        events = [{"id": event_id, "createdAt": "2026-10-20T11:31:44Z", "actor": {"login": "someone"},
                   "requestedReviewer": {"login": reviewer} if reviewer else {}}]
    return {"data": {"repository": {"pullRequest": {
        "id": "PR_node", "state": state, "isDraft": draft, "headRefOid": head,
        "reviewRequests": {"nodes": requested},
        "reviews": {"nodes": review_nodes},
        "timelineItems": {"nodes": events},
    }}}}


def write_executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


class CopilotReviewTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.state = root / "state"
        self.state.mkdir()
        bin_dir = root / "bin"
        bin_dir.mkdir()
        write_executable(bin_dir / "gh", FAKE_GH)
        write_executable(bin_dir / "sleep", "#!/bin/sh\nexit 0\n")
        self.env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
                    "FAKE_GH_STATE": str(self.state)}

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *args, responses=()):
        (self.state / "responses.json").write_text(json.dumps(list(responses)))
        return subprocess.run([str(SCRIPT), *args], env=self.env, capture_output=True, text=True, timeout=30)

    def calls(self):
        log = self.state / "calls.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def queries(self):
        return [next(a.split("=", 1)[1] for a in args if a.startswith("query=")) for args in self.calls()]

    def mutations(self):
        return [(query, args) for query, args in zip(self.queries(), self.calls()) if "mutation" in query]

    def state_query_count(self):
        return sum(1 for query in self.queries() if "mutation" not in query)

    def test_usage_errors_exit_2_without_calling_gh(self):
        for args in ([], ["acme/widgets"], ["acme/widgets", "42", "--frce"], ["acme/widgets", "4x"],
                     ["widgets", "42"], ["/widgets", "42"], ["acme/", "42"]):
            with self.subTest(args=args):
                result = self.run_script(*args)
                self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.calls(), [])

    def test_closed_pull_request_is_refused(self):
        result = self.run_script("acme/widgets", "42", responses=[pr(state="MERGED")])
        self.assertEqual(result.returncode, 1)
        self.assertIn("PR is MERGED", result.stderr)
        self.assertEqual(self.mutations(), [])

    def test_draft_is_refused(self):
        result = self.run_script("acme/widgets", "42", responses=[pr(draft=True)])
        self.assertEqual(result.returncode, 1)
        self.assertIn("draft", result.stderr)
        self.assertEqual(self.mutations(), [])

    def test_pending_copilot_is_never_doubled_even_with_force(self):
        before = pr(pending=("bot",), reviews=((BOT, "head1"),))
        for extra in ([], ["--force"]):
            with self.subTest(extra=extra):
                result = self.run_script("acme/widgets", "42", *extra, responses=[before])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("already pending", result.stdout)
        self.assertEqual(self.mutations(), [])

    def test_review_that_saw_the_head_is_a_noop(self):
        before = pr(head="head2", reviews=((BOT, "head1"), (BOT, "head2")))
        result = self.run_script("acme/widgets", "42", responses=[before])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already saw the head head2", result.stdout)
        self.assertEqual(self.mutations(), [])

    def test_force_rerequests_a_review_that_saw_the_head(self):
        before = pr(head="head2", reviews=((BOT, "head2"),), event=("E1", BOT))
        after = pr(head="head2", pending=("bot",), reviews=((BOT, "head2"),), event=("E2", BOT))
        result = self.run_script("acme/widgets", "42", "--force", responses=[before, after])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("re-requested on head head2", result.stdout)
        [(query, args)] = self.mutations()
        self.assertIn("rerequestReviews", query)
        self.assertIn("pr=PR_node", args)
        self.assertIn(f"bot={BOT_ID}", args)

    def test_review_of_an_older_commit_is_rerequested_and_human_reviews_are_ignored(self):
        # A human approved the head; only Copilot's own latest review decides whether it saw the head.
        reviews = ((BOT, "head1"), ("alice", "head2"))
        before = pr(head="head2", reviews=reviews, event=("E1", BOT))
        after = pr(head="head2", pending=("bot",), reviews=reviews, event=("E2", BOT))
        result = self.run_script("acme/widgets", "42", responses=[before, after])
        self.assertEqual(result.returncode, 0, result.stderr)
        [(query, _)] = self.mutations()
        self.assertIn("rerequestReviews", query)

    def test_pending_human_reviewer_does_not_count_as_copilot(self):
        before = pr(pending=("user",), reviews=((BOT, "head1"),), event=("E1", None))
        after = pr(pending=("user", "bot"), reviews=((BOT, "head1"),), event=("E2", BOT))
        result = self.run_script("acme/widgets", "42", responses=[before, after])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.mutations()), 1)

    def test_first_request_adds_copilot_by_login_without_replacing_reviewers(self):
        before = pr(pending=("user",))
        after = pr(pending=("user", "bot"), event=("E1", BOT))
        result = self.run_script("acme/widgets", "42", responses=[before, after])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("requested (first time)", result.stdout)
        [(query, args)] = self.mutations()
        self.assertIn("requestReviewsByLogin", query)
        self.assertIn('"copilot-pull-request-reviewer[bot]"', query)
        self.assertIn("union: true", query)
        self.assertIn("pr=PR_node", args)

    def test_waits_for_the_event_across_polls(self):
        before = pr(reviews=((BOT, "head1"),), event=("E1", BOT))
        not_yet = pr(reviews=((BOT, "head1"),), event=("E1", BOT))
        landed = pr(pending=("bot",), reviews=((BOT, "head1"),), event=("E2", BOT))
        result = self.run_script("acme/widgets", "42", responses=[before, not_yet, landed])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state_query_count(), 3)

    def test_mutation_without_a_new_event_fails(self):
        before = pr(reviews=((BOT, "head1"),), event=("E1", BOT))
        result = self.run_script("acme/widgets", "42", responses=[before])
        self.assertEqual(result.returncode, 1)
        self.assertIn("not requested", result.stderr)
        self.assertEqual(self.state_query_count(), 4)

    def test_new_event_counts_even_if_copilot_already_picked_the_request_up(self):
        before = pr(reviews=((BOT, "head1"),), event=("E1", BOT))
        after = pr(reviews=((BOT, "head1"),), event=("E2", BOT))
        result = self.run_script("acme/widgets", "42", responses=[before, after])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ReviewRequestedEvent at", result.stdout)

    def test_new_event_for_another_reviewer_does_not_count(self):
        before = pr(reviews=((BOT, "head1"),), event=("E1", BOT))
        after = pr(pending=("bot",), reviews=((BOT, "head1"),), event=("E2", None))
        result = self.run_script("acme/widgets", "42", responses=[before, after])
        self.assertEqual(result.returncode, 1)
        self.assertIn("not requested", result.stderr)

    def test_failed_state_query_stops_before_any_mutation(self):
        (self.state / "fail_query").touch()
        result = self.run_script("acme/widgets", "42", responses=[pr()])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("simulated API failure", result.stderr)
        self.assertEqual(self.mutations(), [])


if __name__ == "__main__":
    unittest.main()
