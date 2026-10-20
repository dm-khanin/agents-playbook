#!/usr/bin/env bash
# copilot-review.sh — request a Copilot review on a PR without the GitHub UI, and prove the request registered.
#
# Usage: copilot-review.sh <owner/repo> <pr-number> [--force]
#
# Copilot already pending              -> nothing; a request is never doubled.
# Copilot's latest review saw the head -> nothing, unless --force.
# Copilot reviewed an older commit     -> rerequestReviews, what the UI's re-request button does.
# Copilot never reviewed this PR       -> requestReviewsByLogin with union, so other reviewers stay.
# Success means a new ReviewRequestedEvent for the bot. The review itself lands minutes later.
# Effort is not a request argument: Copilot uses the PR's level, shown as "Review effort: X" in each review.
#
# The $names inside single-quoted GraphQL and jq text belong to those languages, not to the shell.
# shellcheck disable=SC2016
set -euo pipefail

bot_id='BOT_kgDOCnlnWA'
bot_login='copilot-pull-request-reviewer'

usage() {
  echo "usage: $(basename "$0") <owner/repo> <pr-number> [--force]" >&2
  exit 2
}

if [ $# -lt 2 ] || [ $# -gt 3 ] || { [ $# -eq 3 ] && [ "$3" != "--force" ]; }; then
  usage
fi

repo="$1"
num="$2"
force="${3:-}"
case "$repo" in
  */*) owner="${repo%%/*}"; name="${repo#*/}" ;;
  *) echo "repository must be owner/repo, got: $repo" >&2; usage ;;
esac
if [ -z "$owner" ] || [ -z "$name" ]; then
  echo "repository must be owner/repo, got: $repo" >&2
  usage
fi
case "$num" in
  '' | *[!0-9]*) echo "pr-number must be a number, got: $num" >&2; exit 2 ;;
esac

# Fields are joined with | rather than tabs: read collapses runs of whitespace IFS, which would shift an
# empty field (no Copilot review yet) into the next variable.
query='query($owner: String!, $name: String!, $num: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $num) {
      id state isDraft headRefOid
      reviewRequests(first: 20) { nodes { requestedReviewer { ... on Bot { login } } } }
      reviews(last: 50) { nodes { author { login } commit { oid } } }
      timelineItems(last: 1, itemTypes: [REVIEW_REQUESTED_EVENT]) { nodes { ... on ReviewRequestedEvent {
        id createdAt actor { login } requestedReviewer { ... on Bot { login } } } } }
    }
  }
}'
fields='.data.repository.pullRequest as $p
  | ([$p.reviews.nodes[] | select(.author.login == "'"$bot_login"'")] | last) as $cop
  | ($p.timelineItems.nodes[0] // {}) as $ev
  | [$p.id, $p.state, ($p.isDraft | tostring), $p.headRefOid,
     ([$p.reviewRequests.nodes[].requestedReviewer.login // empty] | any(. == "'"$bot_login"'") | tostring),
     ($cop.commit.oid // ""), ($ev.id // ""), ($ev.requestedReviewer.login // ""), ($ev.createdAt // ""),
     ($ev.actor.login // "")]
  | join("|")'

pr_state() {
  gh api graphql -f query="$query" -f owner="$owner" -f name="$name" -F num="$num" --jq "$fields"
}

# Assign first: under set -e a failed gh inside a here-string would go unnoticed and leave every field empty.
line="$(pr_state)"
IFS='|' read -r pr_id state draft head pending cop_oid last_event _ _ _ <<<"$line"

if [ "$state" != "OPEN" ]; then
  echo "PR is $state — nothing to review" >&2
  exit 1
fi
if [ "$draft" = "true" ]; then
  echo "PR is a draft — mark it ready first (gh pr ready), then rerun" >&2
  exit 1
fi
if [ "$pending" = "true" ]; then
  echo "copilot: already pending — nothing to do (a request is never doubled)"
  exit 0
fi
if [ -n "$cop_oid" ] && [ "$cop_oid" = "$head" ] && [ "$force" != "--force" ]; then
  echo "copilot: latest review already saw the head ${head:0:9} — nothing to do (--force re-requests anyway)"
  exit 0
fi

if [ -n "$cop_oid" ]; then
  mode="re-requested"
  gh api graphql -f pr="$pr_id" -f bot="$bot_id" -f query='mutation($pr: ID!, $bot: ID!) {
    rerequestReviews(input: { pullRequestId: $pr, botIds: [$bot] }) { clientMutationId } }' >/dev/null
else
  mode="requested (first time)"
  gh api graphql -f pr="$pr_id" -f query='mutation($pr: ID!) {
    requestReviewsByLogin(input: { pullRequestId: $pr, botLogins: ["copilot-pull-request-reviewer[bot]"], union: true }) {
      clientMutationId } }' >/dev/null
fi

# The mutation's ok proves nothing on its own; the request counts only once its timeline event exists.
# Pending state is not part of the proof: Copilot may already have picked the request up.
for attempt in 1 2 3; do
  line="$(pr_state)"
  IFS='|' read -r _ _ _ _ _ _ event event_bot event_at event_actor <<<"$line"
  if [ -n "$event" ] && [ "$event" != "$last_event" ] && [ "$event_bot" = "$bot_login" ]; then
    echo "copilot: $mode on head ${head:0:9} — ReviewRequestedEvent at $event_at by $event_actor"
    echo "the review usually lands within ~10 min; it is signed by $bot_login"
    exit 0
  fi
  [ "$attempt" -lt 3 ] && sleep 2
done

echo "copilot: the mutation returned, but no new ReviewRequestedEvent for $bot_login appeared — not requested" >&2
exit 1
