#!/usr/bin/env bash
# pg-query.sh — run one read statement against PostgreSQL for an agent: capped, timed out, masked, audited.
#
# The statement runs inside BEGIN READ ONLY ... ROLLBACK, so the server refuses writes and undoes the few
# effects that read-only mode allows. Before that, lib/pgcheck.py confirms the text is exactly one SELECT,
# WITH, VALUES, TABLE, EXPLAIN or SHOW, lexed the way the server lexes it, calling none of the functions
# whose effects a rollback cannot undo. Row-returning statements are read through a cursor, so --limit caps
# the result without rewriting the SQL.
set -uo pipefail

readonly USAGE='usage: pg-query.sh --profile NAME [-q SQL] [--limit N] [--offset N] [--unmask]
  The statement comes from -q or stdin. NAME_PG_URI holds the connection.
  --limit N    rows to return, 1..10000 (default 100)
  --offset N   rows to skip first
  --unmask     show personal data unmasked; needs DB_TOOLS_ALLOW_UNMASK=1 in your shell'

DBTOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DBTOOLS_DIR DB_KIND=postgres
# shellcheck source=../lib/common.sh
source "$DBTOOLS_DIR/lib/common.sh"
# shellcheck source=../lib/safety.sh
source "$DBTOOLS_DIR/lib/safety.sh"
# shellcheck source=../lib/pg_uri.sh
source "$DBTOOLS_DIR/lib/pg_uri.sh"

readonly STATEMENT_TIMEOUT=600s CURSOR=db_tools_cursor

QUERY="" LIMIT=100 OFFSET="" PROFILE="" UNMASK=0
while [ $# -gt 0 ]; do
    case "$1" in
        -q) take "$@"; QUERY="$2"; shift 2 ;;
        --limit) take "$@"; LIMIT="$2"; shift 2 ;;
        --offset) take "$@"; OFFSET="$2"; shift 2 ;;
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
# A refusal records the arguments as given, so an injection attempt stays visible in the log.
GIVEN=$(jq -cn --arg q "$MASKED_QUERY" --arg limit "$LIMIT" --arg offset "$OFFSET" \
    '{query: $q, given: ({limit: $limit} + (if $offset == "" then {} else {offset: $offset} end))}')

REASON=$(check_count --limit "$LIMIT" 1 10000) || refuse "$REASON" "$GIVEN"
if [ -n "$OFFSET" ]; then
    REASON=$(check_count --offset "$OFFSET" 0 999999999) || refuse "$REASON" "$GIVEN"
    OFFSET=$((10#$OFFSET))
fi
LIMIT=$((10#$LIMIT))

CHECKED=$(printf '%s' "$QUERY" | python3 -I "$DBTOOLS_DIR/lib/pgcheck.py") || refuse "$CHECKED" "$GIVEN"
MODE=${CHECKED%%$'\n'*}
STATEMENT=${CHECKED#*$'\n'}

URI=$(require_setting PG_URI) || exit "$EXIT_USAGE"
(parse_pg_uri "$URI") || usage_error "${PROFILE}_PG_URI is not a postgres:// or postgresql:// URI with a host"

# Each -c is its own message to the server, in one session; ON_ERROR_STOP ends the session at the first
# error, which rolls the transaction back. standard_conforming_strings is the setting pgcheck.py lexes with.
PSQL_ARGS=(-X -q -v ON_ERROR_STOP=1
    -c 'BEGIN TRANSACTION READ ONLY'
    -c "SET LOCAL statement_timeout = '$STATEMENT_TIMEOUT'"
    -c 'SET LOCAL standard_conforming_strings = on')
if [ "$MODE" = cursor ]; then
    PSQL_ARGS+=(-c "DECLARE $CURSOR NO SCROLL CURSOR FOR $STATEMENT")
    [ -n "$OFFSET" ] && PSQL_ARGS+=(-c "MOVE FORWARD $OFFSET IN $CURSOR")
    PSQL_ARGS+=(-c "FETCH FORWARD $LIMIT FROM $CURSOR")
else
    [ -n "$OFFSET" ] && echo "db-tools: --offset does not apply to EXPLAIN or SHOW; ignored" >&2
    PSQL_ARGS+=(-c "$STATEMENT")
fi
PSQL_ARGS+=(-c 'ROLLBACK')

# shellcheck disable=SC2329 # run by run_captured
run_psql() {
    # run_captured runs this in a subshell, so the libpq variables, the password among them, reach psql and
    # nothing else this script runs.
    parse_pg_uri "$URI" || return "$EXIT_USAGE"
    PGAPPNAME=db-tools psql "${PSQL_ARGS[@]}"
}
run_captured run_psql

ROWS=$(printf '%s\n' "$CLIENT_OUT" | sed -nE 's/^\(([0-9]+) rows?\)$/\1/p' | tail -n 1)
emit "$CLIENT_OUT" "$CLIENT_ERR"
if [ "$CLIENT_STATUS" -eq 0 ] && [ "$MODE" = cursor ] && [ "${ROWS:-0}" -eq "$LIMIT" ]; then
    echo "db-tools: $ROWS rows is the --limit; the result may continue (raise --limit, or page with --offset)" >&2
fi

FIELDS=$(jq -cn --arg q "$MASKED_QUERY" --arg mode "$MODE" --argjson limit "$LIMIT" --arg offset "$OFFSET" \
    --arg rows "${ROWS:-}" --argjson ms "$CLIENT_MS" \
    '{query: $q, mode: $mode, limit: (if $mode == "cursor" then $limit else null end),
      offset: (if $offset == "" then null else ($offset | tonumber) end),
      rows: (if $rows == "" then null else ($rows | tonumber) end), duration_ms: $ms}')
if [ "$CLIENT_STATUS" -eq 0 ]; then
    audit ok "" "$FIELDS"
    exit 0
fi
audit failed "$(first_error "$CLIENT_ERR")" "$FIELDS"
exit "$EXIT_FAILED"
