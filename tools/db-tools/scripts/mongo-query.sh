#!/usr/bin/env bash
# mongo-query.sh — run one mongosh expression for an agent: capped, timed out, masked, audited.
#
# Two layers stand between the expression and a write. lib/safety.sh refuses an expression whose text names
# a write method, server-side JavaScript or a way out of the query (modules, the process, prototypes). Then
# mongosh evaluates lib/mongo-guard.js before the expression, which replaces every write method on the shell's
# prototypes with one that throws, whatever path reaches it. Neither is a boundary: give the profile a user
# with only the read role. Reads go to a secondary when there is one.
#
# The result prints as one EJSON line per document, so ObjectId and date types stay visible, and at most
# --limit lines; a summary line goes to stderr.
set -uo pipefail

readonly USAGE='usage: mongo-query.sh --profile NAME [-q EXPRESSION] [--limit N] [--skip N] [--unmask]
  The expression comes from -q or stdin, e.g. db.orders.find({status: "open"}). NAME_MONGO_URI holds the
  connection.
  --limit N   documents to print, 1..10000 (default 100); find() also gets it as its limit
  --skip N    documents find() skips first
  --unmask    show personal data unmasked; needs DB_TOOLS_ALLOW_UNMASK=1 in your shell'

DBTOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DBTOOLS_DIR DB_KIND=mongo
# shellcheck source=../lib/common.sh
source "$DBTOOLS_DIR/lib/common.sh"
# shellcheck source=../lib/safety.sh
source "$DBTOOLS_DIR/lib/safety.sh"

readonly MAX_TIME_MS=600000

QUERY="" LIMIT=100 SKIP="" PROFILE="" UNMASK=0
while [ $# -gt 0 ]; do
    case "$1" in
        -q) take "$@"; QUERY="$2"; shift 2 ;;
        --limit) take "$@"; LIMIT="$2"; shift 2 ;;
        --skip) take "$@"; SKIP="$2"; shift 2 ;;
        --profile) take "$@"; PROFILE="$2"; shift 2 ;;
        --unmask) UNMASK=1; shift ;;
        -h | --help) echo "$USAGE"; exit 0 ;;
        *) usage_error "unknown argument: $1"$'\n'"$USAGE" ;;
    esac
done

require_profile
log_ready || usage_error "cannot write the audit log $DBTOOLS_LOG_FILE"
load_config
read_query

MASKED_QUERY=$(printf '%s' "$QUERY" | mask_pii)
GIVEN=$(jq -cn --arg q "$MASKED_QUERY" --arg limit "$LIMIT" --arg skip "$SKIP" \
    '{query: $q, given: ({limit: $limit} + (if $skip == "" then {} else {skip: $skip} end))}')

REASON=$(check_count --limit "$LIMIT" 1 10000) || refuse "$REASON" "$GIVEN"
LIMIT=$((10#$LIMIT))
if [ -n "$SKIP" ]; then
    REASON=$(check_count --skip "$SKIP" 0 999999999) || refuse "$REASON" "$GIVEN"
    SKIP=$((10#$SKIP))
fi
REASON=$(mongo_reject_reason "$QUERY") || refuse "$REASON" "$GIVEN"

URI=$(require_setting MONGO_URI) || exit "$EXIT_USAGE"
URI=$(mongo_with_read_preference "$URI")

# The expression is printed through __dbtoolsPrint, so it must be one expression; a trailing ; is dropped.
EXPRESSION=$(printf '%s' "$QUERY" | sed -E 's/[[:space:];]+$//')

# shellcheck disable=SC2317,SC2329 # run by run_captured
run_mongosh() {
    DBTOOLS_MONGO_URI="$URI" DBTOOLS_LIMIT="$LIMIT" DBTOOLS_SKIP="${SKIP:-0}" DBTOOLS_MAX_TIME_MS="$MAX_TIME_MS" \
        mongosh --nodb --norc --quiet \
        --eval "$(cat "$DBTOOLS_DIR/lib/mongo-connect.js")" \
        --eval "$(cat "$DBTOOLS_DIR/lib/mongo-guard.js")" \
        --eval "__dbtoolsPrint((
$EXPRESSION
))"
}
run_captured run_mongosh

RESULTS=$(printf '%s\n' "$CLIENT_ERR" | sed -nE 's/^db-tools: ([0-9]+) result\(s\).*/\1/p' | tail -n 1)
emit "$CLIENT_OUT" "$CLIENT_ERR"

FIELDS=$(jq -cn --arg q "$MASKED_QUERY" --argjson limit "$LIMIT" --arg skip "${SKIP:-}" --arg results "${RESULTS:-}" \
    --argjson ms "$CLIENT_MS" \
    '{query: $q, limit: $limit, skip: (if $skip == "" then null else ($skip | tonumber) end),
      results: (if $results == "" then null else ($results | tonumber) end), duration_ms: $ms}')
if [ "$CLIENT_STATUS" -eq 0 ]; then
    audit ok "" "$FIELDS"
    exit 0
fi
# mongo-guard.js throws "db-tools: refused: ..." when the expression reached a write at runtime.
GUARD_REASON=$(printf '%s\n' "$CLIENT_ERR" | sed -nE 's/.*db-tools: refused: (.*)$/\1/p' | head -n 1)
if [ -n "$GUARD_REASON" ]; then
    audit refused "guard: $GUARD_REASON" "$FIELDS"
    exit "$EXIT_REFUSED"
fi
audit failed "$(first_error "$CLIENT_ERR")" "$FIELDS"
exit "$EXIT_FAILED"
