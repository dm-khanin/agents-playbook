#!/usr/bin/env bash
# mongo-explain.sh — have the server parse and plan an update or delete without running it.
#
# mongo-query.sh refuses every write, so it cannot tell whether an update would be accepted, for instance
# whether each arrayFilters identifier matches its filter, a mismatch that only the server reports. This
# script sends the spec inside an explain command with verbosity queryPlanner, which plans the write and
# never applies it. The spec and the collection travel in the environment and are used only inside that
# explain; the script text itself is fixed.
#
# Exit 0: the server accepted and planned the write. Exit 3: the server rejected it, with its reason.
set -uo pipefail

# shellcheck disable=SC2016 # usage text, nothing to expand
readonly USAGE='usage: mongo-explain.sh --profile NAME --collection NAME [--op update|delete] [--spec-file FILE]
  The spec is one element of the command'\''s updates (or deletes) array, as extended JSON, from --spec-file
  or stdin, e.g. {"q": {...}, "u": {"$set": {...}}, "arrayFilters": [...]}. NAME_MONGO_URI holds the
  connection.'

DBTOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DBTOOLS_DIR DB_KIND=mongo
# shellcheck source=../lib/common.sh
source "$DBTOOLS_DIR/lib/common.sh"
# shellcheck source=../lib/safety.sh
source "$DBTOOLS_DIR/lib/safety.sh"

COLLECTION="" SPEC_FILE="" OP=update PROFILE="" UNMASK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --collection) take "$@"; COLLECTION="$2"; shift 2 ;;
        --spec-file) take "$@"; SPEC_FILE="$2"; shift 2 ;;
        --op) take "$@"; OP="$2"; shift 2 ;;
        --profile) take "$@"; PROFILE="$2"; shift 2 ;;
        -h | --help) echo "$USAGE"; exit 0 ;;
        *) usage_error "unknown argument: $1"$'\n'"$USAGE" ;;
    esac
done

require_profile
[ -n "$COLLECTION" ] || usage_error "--collection is required"
[[ "$COLLECTION" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || usage_error "--collection must be a plain collection name (letters, digits, _ . -)"
case "$OP" in
    update | delete) ;;
    *) usage_error "--op must be update or delete, not '$OP'" ;;
esac
log_ready || usage_error "cannot write the audit log $DBTOOLS_LOG_FILE"
load_config

if [ -n "$SPEC_FILE" ]; then
    SPEC=$(cat "$SPEC_FILE") || usage_error "cannot read $SPEC_FILE"
else
    [ -t 0 ] && usage_error "give the spec with --spec-file or on stdin"
    SPEC=$(cat)
fi
jq -e 'type == "object"' >/dev/null 2>&1 <<< "$SPEC" || usage_error "the spec must be one JSON object"

URI=$(require_setting MONGO_URI) || exit "$EXIT_USAGE"
URI=$(mongo_with_read_preference "$URI")

# The write is only ever planned: explain with the queryPlanner verbosity does not run it, while
# executionStats and allPlansExecution would. Nothing but this line keeps it so; do not make it a parameter.
readonly EXPLAIN_SCRIPT='
const op = process.env.DBTOOLS_EXPLAIN_OP;
const command = {
  [op]: process.env.DBTOOLS_EXPLAIN_COLLECTION,
  [op === "update" ? "updates" : "deletes"]: [EJSON.parse(process.env.DBTOOLS_EXPLAIN_SPEC)],
};
let result;
try {
  result = db.runCommand({ explain: command, verbosity: "queryPlanner" });
} catch (error) {
  result = { ok: 0, codeName: error.codeName || error.code || "error", errmsg: error.message };
}
if (result.ok) {
  const plan = result.queryPlanner && result.queryPlanner.winningPlan;
  print("ACCEPTED  stage=" + (plan ? plan.stage : "n/a"));
} else {
  print("REJECTED  " + (result.codeName || "error") + ": " + result.errmsg);
  quit(1);
}'

# shellcheck disable=SC2317,SC2329 # run by run_captured
run_explain() {
    DBTOOLS_MONGO_URI="$URI" DBTOOLS_EXPLAIN_OP="$OP" DBTOOLS_EXPLAIN_COLLECTION="$COLLECTION" \
        DBTOOLS_EXPLAIN_SPEC="$SPEC" \
        mongosh --nodb --norc --quiet --eval "$(cat "$DBTOOLS_DIR/lib/mongo-connect.js")" --eval "$EXPLAIN_SCRIPT"
}
run_captured run_explain
emit "$CLIENT_OUT" "$CLIENT_ERR"

FIELDS=$(jq -cn --arg op "$OP" --arg collection "$COLLECTION" --arg spec "$(printf '%s' "$SPEC" | mask_pii)" \
    --argjson ms "$CLIENT_MS" '{operation: "explain", op: $op, collection: $collection, spec: $spec, duration_ms: $ms}')
if [ "$CLIENT_STATUS" -eq 0 ]; then
    audit ok "" "$FIELDS"
    exit 0
fi
audit failed "$(first_error "$CLIENT_OUT$CLIENT_ERR")" "$FIELDS"
exit "$EXIT_FAILED"
