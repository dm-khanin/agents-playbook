#!/usr/bin/env bash
# pr-findings.sh — findings Copilot's latest review keeps in its body, outside review threads.
#
# Usage: pr-findings.sh <owner/repo> <pr-number> [--full]
#   --full adds each finding's text.
#
# A review can read "No open issues" with zero threads and still carry a real finding under "N previously
# missed issue(s)" or "Suppressed comments (N)". This prints the review's commit, its effort level and every
# such finding with severity, file:line and title. Parsing lives in lib/copilot_body.py.
# The $names inside single-quoted GraphQL and jq text belong to those languages, not to the shell.
# shellcheck disable=SC2016
set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ] || { [ $# -eq 3 ] && [ "$3" != "--full" ]; }; then
  echo "usage: $(basename "$0") <owner/repo> <pr-number> [--full]" >&2
  exit 2
fi

repo="$1"
num="$2"
format="lines"
[ "${3:-}" = "--full" ] && format="full"
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

parser="$(cd "$(dirname "$0")" && pwd)/lib/copilot_body.py"
query='query($owner: String!, $name: String!, $num: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $num) {
      reviews(last: 50) { nodes { author { login } submittedAt commit { oid } body } }
    }
  }
}'

# Assign first: under set -e a failed gh inside a pipeline or here-string would go unnoticed.
json="$(gh api graphql -f query="$query" -f owner="$owner" -f name="$name" -F num="$num")"
latest='[.data.repository.pullRequest.reviews.nodes[] | select(.author.login == "copilot-pull-request-reviewer")] | last'
meta="$(jq -r "$latest | if . == null then \"\" else \"\(.commit.oid[0:9]) \(.submittedAt)\" end" <<<"$json")"
if [ -z "$meta" ]; then
  echo "copilot: no review yet on $owner/$name#$num"
  exit 0
fi
body="$(jq -r "$latest | .body" <<<"$json")"

count="$(printf '%s' "$body" | python3 -I "$parser" --format count)"
effort="$(printf '%s' "$body" | python3 -I "$parser" --format effort)"
echo "copilot review on ${meta% *} at ${meta#* }, effort ${effort:-unknown}: body findings $count"
printf '%s' "$body" | python3 -I "$parser" --format "$format"
