#!/usr/bin/env bash
# copilot-review-watch.sh — exit when Copilot posts its NEXT review on a PR, with one actionable line.
#
# Usage: copilot-review-watch.sh <owner/repo> <pr-number> [poll_seconds] [max_minutes]
#   poll_seconds  default 45 (keep it at 30 or more for the GitHub API rate limit)
#   max_minutes   default 30; then it prints a timeout line and exits 0, so re-run it to keep watching
#
# Copilot signs with a different login per API surface: inline review comments say "Copilot", while the
# reviews endpoint and GraphQL say "copilot-pull-request-reviewer[bot]". A watcher that filters reviews by
# the inline login never fires. This one matches case-insensitively on "copilot", and refuses to arm when
# the baseline query fails, because a baseline that cannot be read can never be beaten either.
# It also reports a body-flag count: Copilot keeps some findings in the review body, not in threads, so
# "0 open threads" is not "0 findings" (pr-findings.sh lists them).
#
# Run it in the background and wait for it to exit: one completion, one line.
set -uo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $(basename "$0") <owner/repo> <pr-number> [poll_seconds] [max_minutes]" >&2
  exit 2
fi

repo="$1"; pr="$2"; poll="${3:-45}"; max_min="${4:-30}"
case "$repo" in
  ?*/?*) ;;
  *) echo "repository must be owner/repo, got: $repo" >&2; exit 2 ;;
esac
case "$pr" in '' | *[!0-9]*) echo "pr-number must be a number, got: $pr" >&2; exit 2 ;; esac
case "$poll$max_min" in *[!0-9]*) echo "poll_seconds and max_minutes must be numbers" >&2; exit 2 ;; esac

reviews_api="repos/$repo/pulls/$pr/reviews?per_page=100"
max_review_id() {
  gh api "$reviews_api" --jq '[.[] | select(.user.login | test("copilot";"i")) | .id] | max // 0' 2>/dev/null
}

base="$(max_review_id)"
if [ -z "$base" ]; then
  echo "could not read reviews for $repo#$pr (gh auth / repo / pr wrong?) — not arming" >&2
  exit 2
fi
# base may legitimately be 0 (no prior Copilot review); that is fine — any first review beats it.

deadline=$(( $(date +%s) + max_min * 60 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  cur="$(max_review_id)"
  if [ -n "$cur" ] && [ "$cur" -gt "$base" ]; then
    state="$(gh api "repos/$repo/pulls/$pr/reviews/$cur" --jq .state 2>/dev/null || echo '?')"
    open="$(gh api graphql -f query="{ repository(owner:\"${repo%%/*}\",name:\"${repo#*/}\"){ pullRequest(number:$pr){ reviewThreads(first:100){ nodes { isResolved } } } } }" \
      --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false)] | length' 2>/dev/null || echo '?')"
    body="$(gh api "repos/$repo/pulls/$pr/reviews/$cur" --jq '.body' 2>/dev/null | grep -ciE 'previously missed|needs a closer look|open issues' || true)"
    echo "new bot review on $repo#$pr: review id $cur, state $state, $open open thread(s), body-flag $body — inspect with pr-state.sh / pr-findings.sh"
    exit 0
  fi
  sleep "$poll"
done
echo "copilot-review-watch: no new review on $repo#$pr after ${max_min}min (baseline id $base) — re-run to keep watching"
exit 0
