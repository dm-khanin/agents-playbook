#!/usr/bin/env bash
# pr-state.sh — one-shot state of a GitHub PR, for checking a report against the PR itself.
#
# Usage: pr-state.sh <owner/repo> <pr-number>
#
# Prints the head SHA, CI (rollup and each check), review threads (open ones with path and author),
# pending review requests, the latest reviews with the commit each one saw, and whether Copilot's latest
# review saw the head. Re-request Copilot with copilot-review.sh next to this script.
# Also counts the findings Copilot keeps in its review body ("previously missed", "suppressed"): a review
# can show zero threads and still carry one. pr-findings.sh lists them.
# The $names inside single-quoted GraphQL and jq text belong to those languages, not to the shell.
# shellcheck disable=SC2016
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $(basename "$0") <owner/repo> <pr-number>" >&2
  exit 2
fi

repo="$1"
num="$2"
case "$repo" in
  */*) owner="${repo%%/*}"; name="${repo#*/}" ;;
  *) echo "repository must be owner/repo, got: $repo" >&2; exit 2 ;;
esac
if [ -z "$owner" ] || [ -z "$name" ]; then
  echo "repository must be owner/repo, got: $repo" >&2
  exit 2
fi
case "$num" in
  '' | *[!0-9]*) echo "pr-number must be a number, got: $num" >&2; exit 2 ;;
esac

query='query($owner: String!, $name: String!, $num: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $num) {
      title url state isDraft mergeable baseRefName headRefName headRefOid
      commits(last: 1) { nodes { commit { committedDate statusCheckRollup { state
        contexts(first: 50) { nodes { __typename
          ... on CheckRun { name conclusion status }
          ... on StatusContext { context state } } } } } } }
      reviewRequests(first: 10) { nodes { requestedReviewer { __typename
        ... on User { login } ... on Bot { login } ... on Team { name } } } }
      reviewThreads(first: 100) { nodes { isResolved isOutdated comments(first: 1) { nodes { author { login } path } } } }
      reviews(last: 50) { nodes { author { login } state submittedAt body commit { oid } } }
    }
  }
}'

# One fetch, read twice: the summary below, then the latest Copilot body through the body parser.
json="$(gh api graphql -f query="$query" -F owner="$owner" -F name="$name" -F num="$num")"
jq -r '
  .data.repository.pullRequest as $p
  | $p.headRefOid as $head
  | ([$p.reviews.nodes[] | select(.author.login | test("copilot"; "i"))] | last) as $cop
  | "\($p.title)\n\($p.url)",
    "state: \($p.state)\(if $p.isDraft then " (draft)" else "" end), mergeable: \($p.mergeable)",
    "branch: \($p.baseRefName) <- \($p.headRefName)",
    "head: \($head[0:9]), committed \($p.commits.nodes[0].commit.committedDate)",
    "ci: \($p.commits.nodes[0].commit.statusCheckRollup.state // "none")",
    ($p.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]?
      | "  - \(.name // .context): \(.conclusion // .state // .status)"),
    "threads: \($p.reviewThreads.nodes | length) total, \([$p.reviewThreads.nodes[] | select(.isResolved | not)] | length) open",
    ($p.reviewThreads.nodes[] | select(.isResolved | not)
      | "  - open: \(.comments.nodes[0].path // "-") by \(.comments.nodes[0].author.login)\(if .isOutdated then " (outdated)" else "" end)"),
    "review requests pending: \([$p.reviewRequests.nodes[].requestedReviewer | .login // .name] | if length == 0 then "none" else join(", ") end)",
    "reviews, latest last:",
    ($p.reviews.nodes[-6:][] | "  - \(.author.login) \(.state) \(.submittedAt) on \(.commit.oid[0:9])"),
    (if $cop == null then "copilot: no review yet"
     else "copilot: latest review on \($cop.commit.oid[0:9]) at \($cop.submittedAt), "
       + (if $cop.commit.oid == $head then "saw the head" else "has NOT seen the head (re-request: copilot-review.sh)" end)
       + ((($cop.body | capture("(?<n>[0-9]+) open findings?")) // ($cop.body | capture("generated (?<n>[0-9]+) comments?"))
           | "; its overview: \(.n) finding(s)") // "")
     end)
' <<<"$json"

body="$(jq -r '[.data.repository.pullRequest.reviews.nodes[] | select(.author.login | test("copilot"; "i"))]
  | last | .body // empty' <<<"$json")"
if [ -n "$body" ]; then
  parser="$(cd "$(dirname "$0")" && pwd)/lib/copilot_body.py"
  count="$(printf '%s' "$body" | python3 -I "$parser" --format count)"
  effort="$(printf '%s' "$body" | python3 -I "$parser" --format effort)"
  line="copilot body findings: $count, effort ${effort:-unknown}"
  [ "$count" = "0" ] || line="$line — list them: pr-findings.sh $owner/$name $num"
  echo "$line"
fi
