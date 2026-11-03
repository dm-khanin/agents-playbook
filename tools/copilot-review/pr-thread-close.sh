#!/usr/bin/env bash
# pr-thread-close.sh — reply in a PR review thread and resolve it, as one step that cannot half-happen silently.
#
# Usage: pr-thread-close.sh <owner/repo> <pr-number> <comment-databaseId> <reply-file>
#   The comment id is the numeric id of the thread's top-level review comment, as `gh api repos/<o>/<r>/pulls/<n>/comments` lists it. The reply text is read from a file.
#
# Order, each step checked before the next:
#   1. find the thread holding the comment (read-only; nothing is written if it is not found);
#   2. reply through REST, and require the reply's html_url;
#   3. resolve the thread through GraphQL, and require isResolved == true.
# A failure after step 2 says so explicitly: the reply exists but the thread is still open.
# The $names inside single-quoted GraphQL and jq text belong to those languages, not to the shell.
# shellcheck disable=SC2016
set -euo pipefail

if [ $# -ne 4 ]; then
  echo "usage: $(basename "$0") <owner/repo> <pr-number> <comment-databaseId> <reply-file>" >&2
  exit 2
fi

repo="$1"
num="$2"
comment="$3"
reply_file="$4"
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
case "$comment" in
  '' | *[!0-9]*) echo "comment id must be a number, got: $comment" >&2; exit 2 ;;
esac
if [ ! -s "$reply_file" ]; then
  echo "reply file is missing or empty: $reply_file" >&2
  exit 2
fi

threads_query='query($owner: String!, $name: String!, $num: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $num) {
      reviewThreads(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes { id isResolved comments(first: 100) { nodes { databaseId } } }
      }
    }
  }
}'

# Assign first: under set -e a failed gh inside a pipeline would go unnoticed and look like "not found".
threads="$(gh api graphql --paginate -f query="$threads_query" -f owner="$owner" -f name="$name" -F num="$num" \
  --jq ".data.repository.pullRequest.reviewThreads.nodes[]
        | select(any(.comments.nodes[]; .databaseId == $comment)) | \"\(.id) \(.isResolved)\"")"
if [ -z "$threads" ]; then
  echo "comment $comment is not in any review thread of $owner/$name#$num — nothing written" >&2
  exit 1
fi
thread="${threads%%$'\n'*}"
thread_id="${thread% *}"

if ! reply_url="$(gh api "repos/$owner/$name/pulls/$num/comments/$comment/replies" -F body=@"$reply_file" \
  --jq '.html_url // empty')"; then
  echo "reply failed — nothing written, thread $thread_id left as it was" >&2
  exit 1
fi
if [ -z "$reply_url" ]; then
  echo "reply returned no html_url — check the thread by hand, it was not resolved" >&2
  exit 1
fi
echo "replied: $reply_url"

if ! resolved="$(gh api graphql -f id="$thread_id" -f query='mutation($id: ID!) {
  resolveReviewThread(input: { threadId: $id }) { thread { isResolved } } }' \
  --jq '.data.resolveReviewThread.thread.isResolved')"; then
  echo "replied, but resolving thread $thread_id failed — it is still open" >&2
  exit 1
fi
if [ "$resolved" != "true" ]; then
  echo "replied, but thread $thread_id reports isResolved=$resolved — it is still open" >&2
  exit 1
fi
echo "resolved: thread $thread_id"
