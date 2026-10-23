#!/usr/bin/env bash
# refresh-schema.sh — dump a profile's schema to local files an agent can read before it queries anything.
#
#   postgres.sql   pg_dump --schema-only: tables, columns, indexes, constraints, no data
#   mongo.md       per collection: estimated count, indexes and one sample document as relaxed EJSON (so an
#                  ObjectId shows as {"$oid": ...} and is not mistaken for a string), personal data masked
#
# Files go to $DBTOOLS_SCHEMA_DIR/<profile>/, by default ~/.local/share/db-tools/schema/<profile>/. Each store
# the profile has a URI for is dumped.
set -uo pipefail
umask 077

readonly USAGE='usage: refresh-schema.sh --profile NAME
  Dumps NAME_PG_URI to postgres.sql and NAME_MONGO_URI to mongo.md, whichever are set.'

DBTOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DBTOOLS_DIR
DB_KIND=schema
# shellcheck source=../lib/common.sh
source "$DBTOOLS_DIR/lib/common.sh"
# shellcheck source=../lib/safety.sh
source "$DBTOOLS_DIR/lib/safety.sh"
# shellcheck source=../lib/pg_uri.sh
source "$DBTOOLS_DIR/lib/pg_uri.sh"

PROFILE="" UNMASK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --profile) take "$@"; PROFILE="$2"; shift 2 ;;
        -h | --help) echo "$USAGE"; exit 0 ;;
        *) usage_error "unknown argument: $1"$'\n'"$USAGE" ;;
    esac
done

require_profile
log_ready || usage_error "cannot write the audit log $DBTOOLS_LOG_FILE"
load_config

PG_URI=$(setting PG_URI)
MONGO_URI=$(setting MONGO_URI)
[ -n "$PG_URI$MONGO_URI" ] || usage_error "neither ${PROFILE}_PG_URI nor ${PROFILE}_MONGO_URI is set"

OUT_DIR="${DBTOOLS_SCHEMA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/db-tools/schema}/$PROFILE"
mkdir -p "$OUT_DIR" || usage_error "cannot create $OUT_DIR"

STATUS=0

# dumped STORE FILE — report and audit a finished dump; failed STORE — the same for one that failed.
dumped() {
    DB_KIND="$1" audit ok "" "$(jq -cn --arg f "$2" --argjson ms "$CLIENT_MS" '{operation: "schema", file: $f, duration_ms: $ms}')"
    echo "wrote $2 ($(wc -l < "$2" | tr -d ' ') lines)"
}
failed() {
    emit "" "$CLIENT_ERR"
    DB_KIND="$1" audit failed "$(first_error "$CLIENT_ERR")" '{"operation": "schema"}'
    STATUS=$EXIT_FAILED
}

if [ -n "$PG_URI" ]; then
    (parse_pg_uri "$PG_URI") || usage_error "${PROFILE}_PG_URI is not a postgres:// or postgresql:// URI with a host"
    # shellcheck disable=SC2317,SC2329 # run by run_captured, in a subshell: the password reaches pg_dump only
    run_pg_dump() {
        parse_pg_uri "$PG_URI" || return "$EXIT_USAGE"
        PGAPPNAME=db-tools pg_dump --schema-only --no-owner --no-acl --no-comments
    }
    run_captured run_pg_dump
    if [ "$CLIENT_STATUS" -eq 0 ]; then
        printf '%s\n' "$CLIENT_OUT" > "$OUT_DIR/postgres.sql"
        dumped postgres "$OUT_DIR/postgres.sql"
    else
        failed postgres
    fi
fi

if [ -n "$MONGO_URI" ]; then
    # shellcheck disable=SC2016 # JavaScript for mongosh, not for the shell
    readonly MONGO_SCHEMA_SCRIPT='
const lines = [];
for (const name of db.getCollectionNames().filter((n) => !n.startsWith("system.")).sort()) {
  const collection = db.getCollection(name);
  const indexes = collection.getIndexes().map((i) => ({ name: i.name, key: i.key, unique: !!i.unique }));
  lines.push(`## ${name}`);
  lines.push(`- count (estimated): ${collection.estimatedDocumentCount()}`);
  lines.push(`- indexes: ${EJSON.stringify(indexes, { relaxed: true })}`);
  lines.push(`- sample: ${EJSON.stringify(collection.findOne(), { relaxed: true })}`);
  lines.push("");
}
print(lines.join("\n"));'
    URI=$(mongo_with_read_preference "$MONGO_URI")
    # shellcheck disable=SC2317,SC2329 # run by run_captured
    run_mongosh() {
        DBTOOLS_MONGO_URI="$URI" DBTOOLS_LIMIT=1 DBTOOLS_SKIP=0 DBTOOLS_MAX_TIME_MS=600000 \
            mongosh --nodb --norc --quiet \
            --eval "$(cat "$DBTOOLS_DIR/lib/mongo-connect.js")" \
            --eval "$(cat "$DBTOOLS_DIR/lib/mongo-guard.js")" \
            --eval "$MONGO_SCHEMA_SCRIPT"
    }
    run_captured run_mongosh
    if [ "$CLIENT_STATUS" -eq 0 ]; then
        printf '%s\n' "$CLIENT_OUT" | mask_pii > "$OUT_DIR/mongo.md"
        dumped mongo "$OUT_DIR/mongo.md"
    else
        failed mongo
    fi
fi

exit "$STATUS"
