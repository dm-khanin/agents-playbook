#!/usr/bin/env bats
# pg-query.sh against a real PostgreSQL: a throwaway cluster from initdb, on a free TCP port of 127.0.0.1,
# started once for this file and removed after it. The connection is a superuser, so every refusal here
# comes from the transaction pg-query.sh opens, not from missing privileges.
#
# Without initdb on PATH the file skips, unless DBTOOLS_REQUIRE_INTEGRATION=1, which CI sets, makes that a
# failure.

load helpers

setup_file() {
    if ! command -v initdb > /dev/null || ! command -v pg_ctl > /dev/null; then
        [ "${DBTOOLS_REQUIRE_INTEGRATION:-0}" = 1 ] && { echo "initdb and pg_ctl are required" >&2; return 1; }
        export PG_SERVER_SKIP=1
        return 0
    fi
    PG_CLUSTER="$(mktemp -d)"
    PG_PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
    export PG_CLUSTER PG_PORT
    initdb -D "$PG_CLUSTER/data" -A trust -U dbtools --no-instructions > "$PG_CLUSTER/initdb.log" 2>&1
    # No Unix socket: a temporary directory's path can exceed the 103-byte socket limit on macOS.
    pg_ctl -D "$PG_CLUSTER/data" -l "$PG_CLUSTER/server.log" -w \
        -o "-p $PG_PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" start > /dev/null
    psql -X -q -h 127.0.0.1 -p "$PG_PORT" -U dbtools -d postgres -v ON_ERROR_STOP=1 \
        -c "CREATE TABLE t (id int PRIMARY KEY, note text)" \
        -c "INSERT INTO t SELECT g, 'note ' || g FROM generate_series(1, 10) g" \
        -c "CREATE SEQUENCE s"
}

teardown_file() {
    [ -n "${PG_CLUSTER:-}" ] || return 0
    pg_ctl -D "$PG_CLUSTER/data" -m immediate stop > /dev/null 2>&1
    rm -rf "$PG_CLUSTER"
}

setup() {
    [ "${PG_SERVER_SKIP:-0}" = 1 ] && skip "initdb is not on PATH"
    common_setup
    config "IT_PG_URI=postgresql://dbtools@127.0.0.1:$PG_PORT/postgres"
}
teardown() { [ -n "${DBTESTDIR:-}" ] && common_teardown; }

pg() {
    run "$SCRIPTS/pg-query.sh" --profile IT "$@"
}

# sql STATEMENT — run directly, outside db-tools, to look at the state the wrapper left.
sql() {
    psql -X -q -At -h 127.0.0.1 -p "$PG_PORT" -U dbtools -d postgres -c "$1"
}

@test "server: a read returns rows, and ORDER BY survives the cap and the offset" {
    pg -q "SELECT id FROM t ORDER BY id DESC" --limit 3 --offset 2
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | sed -nE 's/^ +([0-9]+)$/\1/p' | tr '\n' ' ')" = "8 7 6 " ]
    [[ "$output" =~ "(3 rows)" ]] || false
}

@test "server: the transaction is read-only, with the timeout and the application name set" {
    pg -q "SELECT current_setting('transaction_read_only') AS ro, current_setting('statement_timeout') AS st, current_setting('application_name') AS app"
    [ "$status" -eq 0 ]
    [[ "$output" =~ on[[:space:]]+\|[[:space:]]+10min[[:space:]]+\|[[:space:]]+db-tools ]] || false
}

@test "server: writes that pass the client check are refused by the server" {
    for statement in \
        "WITH d AS (DELETE FROM t RETURNING 1) SELECT count(*) FROM d" \
        "SELECT 1 AS a INTO made_by_select_into" \
        "SELECT * FROM t FOR UPDATE" \
        "SELECT nextval('s')" \
        "SELECT set_config('transaction_read_only', 'off', true)"; do
        pg -q "$statement"
        [ "$status" -eq 3 ] || { echo "not refused: $statement"; false; }
        [[ "$output" =~ ERROR ]] || false
    done
    pg -q "EXPLAIN ANALYZE WITH d AS (DELETE FROM t RETURNING 1) SELECT 1"
    [ "$status" -eq 3 ]
    [ "$(sql "SELECT count(*) FROM t")" = 10 ]
    [ "$(sql "SELECT to_regclass('made_by_select_into') IS NULL")" = t ]
    [ "$(sql "SELECT last_value FROM s")" = 1 ]
}

@test "server: a large object does not outlive the call" {
    # Depending on the server version, lo_create is refused in a read-only transaction or runs and is rolled back.
    pg -q "SELECT lo_create(0)"
    [ "$status" -eq 0 ] || [ "$status" -eq 3 ]
    [ "$(sql "SELECT count(*) FROM pg_largeobject_metadata")" = 0 ]
}

@test "server: a session setting changed by the statement does not outlive the call" {
    pg -q "SELECT set_config('default_transaction_read_only', 'off', false)"
    [ "$status" -eq 0 ]
    pg -q "SELECT current_setting('transaction_read_only') AS ro"
    [[ "$output" =~ on ]] || false
}

@test "server: what the lexer calls one string, the server does too" {
    pg -q "SELECT ';' AS a, E'\\'; x' AS b, \$\$ ; \$\$ AS c, \$q\$ ' ; \$q\$ AS d, \"x;y\".id FROM t AS \"x;y\" WHERE id = 1 /* ; /* ; */ */"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "(1 row)" ]] || false
}

@test "server: EXPLAIN and SHOW run directly" {
    pg -q "EXPLAIN SELECT * FROM t"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Seq Scan on t" ]] || false
    pg -q "SHOW transaction_read_only"
    [[ "$output" =~ on ]] || false
}

@test "server: a statement error exits 3 with the server's message" {
    pg -q "SELECT no_such_column FROM t"
    [ "$status" -eq 3 ]
    [[ "$output" =~ 'column "no_such_column" does not exist' ]] || false
    last_audit '.outcome == "failed" and (.reason | contains("no_such_column"))'
}
