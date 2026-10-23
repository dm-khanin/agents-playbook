#!/usr/bin/env bats
# pg-query.sh against a fake psql: what reaches psql, what the agent sees, what the log records.
# test_pg_server.bats runs the same wrapper against a real server.

load helpers

setup() {
    common_setup
    fake_client psql
    answer psql $' id | email\n----+-------\n  1 | alice@example.com\n(1 row)\n'
    config 'P_PG_URI=postgresql://app:pw-5e1d@example.com:6543/shop?sslmode=require'
}
teardown() { common_teardown; }

pg() {
    run "$SCRIPTS/pg-query.sh" --profile P "$@"
}

# psql_command N — the Nth -c command psql received, counting from 0.
psql_command() {
    jq -r --argjson n "$1" '[.argv as $a | range(0; $a | length) | select($a[.] == "-c") | $a[. + 1]][$n]' \
        "$DBTESTDIR/psql.json"
}

@test "a select runs in a read-only transaction that is rolled back, through a cursor" {
    pg -q "SELECT id, email FROM users"
    [ "$status" -eq 0 ]
    [ "$(psql_command 0)" = "BEGIN TRANSACTION READ ONLY" ]
    [ "$(psql_command 1)" = "SET LOCAL statement_timeout = '600s'" ]
    [ "$(psql_command 2)" = "SET LOCAL standard_conforming_strings = on" ]
    [ "$(psql_command 3)" = "DECLARE db_tools_cursor NO SCROLL CURSOR FOR SELECT id, email FROM users" ]
    [ "$(psql_command 4)" = "FETCH FORWARD 100 FROM db_tools_cursor" ]
    [ "$(psql_command 5)" = "ROLLBACK" ]
    [ "$(psql_command 6)" = "null" ]
}

@test "psql skips psqlrc, stops at the first error and prints no command tags" {
    pg -q "SELECT 1"
    recorded psql '.argv[0:5] == ["-X", "-q", "-v", "ON_ERROR_STOP=1", "-c"]'
}

@test "--limit and --offset become FETCH and MOVE, and the SQL itself is not rewritten" {
    pg -q "SELECT * FROM t ORDER BY id" --limit 5 --offset 0020
    [ "$status" -eq 0 ]
    [ "$(psql_command 3)" = "DECLARE db_tools_cursor NO SCROLL CURSOR FOR SELECT * FROM t ORDER BY id" ]
    [ "$(psql_command 4)" = "MOVE FORWARD 20 IN db_tools_cursor" ]
    [ "$(psql_command 5)" = "FETCH FORWARD 5 FROM db_tools_cursor" ]
}

@test "a LIMIT inside a subquery no longer switches the row cap off" {
    pg -q "SELECT *, (SELECT 1 LIMIT 1) AS x FROM big"
    [ "$(psql_command 4)" = "FETCH FORWARD 100 FROM db_tools_cursor" ]
}

@test "EXPLAIN and SHOW run directly, and --offset is ignored with a note" {
    pg -q "EXPLAIN SELECT * FROM t" --offset 5
    [ "$status" -eq 0 ]
    [ "$(psql_command 3)" = "EXPLAIN SELECT * FROM t" ]
    [ "$(psql_command 4)" = "ROLLBACK" ]
    [[ "$output" =~ "--offset does not apply" ]] || false
}

@test "a trailing semicolon and comment are dropped before the cursor" {
    pg -q $'SELECT 1; -- done\n'
    [ "$(psql_command 3)" = "DECLARE db_tools_cursor NO SCROLL CURSOR FOR SELECT 1" ]
}

@test "the statement can come on stdin" {
    run bash -c "echo 'SELECT 2' | '$SCRIPTS/pg-query.sh' --profile P"
    [ "$status" -eq 0 ]
    [ "$(psql_command 3)" = "DECLARE db_tools_cursor NO SCROLL CURSOR FOR SELECT 2" ]
}

@test "the connection reaches psql as libpq variables: no password in its arguments" {
    pg -q "SELECT 1"
    recorded psql '.env.PGHOST == "example.com" and .env.PGPORT == "6543" and .env.PGUSER == "app"
        and .env.PGPASSWORD == "pw-5e1d" and .env.PGDATABASE == "shop" and .env.PGSSLMODE == "require"
        and .env.PGAPPNAME == "db-tools" and .env.PGCONNECT_TIMEOUT == "10"'
    recorded psql '[.argv[] | contains("pw-5e1d")] | any | not'
}

@test "the password reaches psql only, not the tools the wrapper runs after it" {
    real_jq=$(PATH="${PATH#*:}" command -v jq)
    printf '#!/bin/sh\n[ -n "${PGPASSWORD+set}" ] && echo jq >> "%s/leak"\nexec "%s" "$@"\n' "$DBTESTDIR" "$real_jq" \
        > "$DBTESTDIR/bin/jq"
    chmod +x "$DBTESTDIR/bin/jq"
    pg -q "SELECT 1"
    [ "$status" -eq 0 ]
    recorded psql '.env.PGPASSWORD == "pw-5e1d"'
    [ ! -e "$DBTESTDIR/leak" ]
}

@test "PGOPTIONS and PGSERVICE from the caller's shell do not reach psql" {
    PGOPTIONS='-c default_transaction_read_only=off' PGSERVICE=elsewhere pg -q "SELECT 1"
    recorded psql '(.env | has("PGOPTIONS") or has("PGSERVICE")) | not'
}

@test "another profile's URI does not reach psql" {
    config 'Q_PG_URI=postgresql://other:pw-99ab@h/db'
    pg -q "SELECT 1"
    recorded psql '[.env[] | contains("pw-99ab")] | any | not'
}

@test "output is masked, and the row count is in the log" {
    pg -q "SELECT id, email FROM users"
    [[ "$output" =~ al\*\*@example\.com ]] || false
    [[ "$output" != *alice* ]] || false
    last_audit '.db == "postgres" and .profile == "P" and .outcome == "ok" and .rows == 1 and .mode == "cursor"
        and .limit == 100 and .offset == null and (.duration_ms | type) == "number" and .unmasked == false'
}

@test "the query in the log is masked too" {
    pg -q "SELECT * FROM users WHERE email = 'alice@example.com'"
    last_audit '.query == "SELECT * FROM users WHERE email = '"'"'al**@example.com'"'"'"'
}

@test "--unmask with DB_TOOLS_ALLOW_UNMASK=1 shows the data and says so in the log" {
    DB_TOOLS_ALLOW_UNMASK=1 pg -q "SELECT 1" --unmask
    [[ "$output" =~ alice@example\.com ]] || false
    last_audit '.unmasked == true'
}

@test "reaching --limit prints a note that the result may continue" {
    answer psql $' n\n---\n 1\n 2\n(2 rows)\n'
    pg -q "SELECT n FROM t" --limit 2
    [ "$status" -eq 0 ]
    [[ "$output" =~ "2 rows is the --limit" ]] || false
}

@test "a server error exits 3, is shown masked and is logged as failed" {
    answer psql "" $'ERROR:  permission denied for table users (owner alice@example.com)\n' 1
    pg -q "SELECT * FROM users"
    [ "$status" -eq 3 ]
    [[ "$output" =~ al\*\*@example\.com ]] || false
    last_audit '.outcome == "failed" and (.reason | startswith("ERROR:  permission denied")) and (.reason | contains("alice") | not)'
}

@test "no --profile: usage error, psql never runs, nothing is logged" {
    run "$SCRIPTS/pg-query.sh" -q "SELECT 1"
    [ "$status" -eq 2 ]
    not_called psql
    [ ! -s "$DBTOOLS_LOG_FILE" ]
}

@test "a profile without a PG URI is a configuration error" {
    run "$SCRIPTS/pg-query.sh" --profile NOPE -q "SELECT 1"
    [ "$status" -eq 2 ]
    [[ "$output" =~ "NOPE_PG_URI is not set" ]] || false
    not_called psql
}

@test "a URI that is not postgres is a configuration error" {
    config 'M_PG_URI=mysql://u@h/db'
    run "$SCRIPTS/pg-query.sh" --profile M -q "SELECT 1"
    [ "$status" -eq 2 ]
    not_called psql
}

@test "refusals: the reason, exit 1, logged with the arguments as given, psql never runs" {
    pg -q "DELETE FROM users"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "refused: not-a-read-statement" ]] || false
    last_audit '.outcome == "refused" and .reason == "not-a-read-statement" and .query == "DELETE FROM users"'
    pg -q "SELECT 1; DROP TABLE t"
    [[ "$output" =~ "refused: multi-statement" ]] || false
    pg -q "SELECT pg_catalog.pg_terminate_backend(1)"
    [[ "$output" =~ "refused: denied-function: pg_terminate_backend" ]] || false
    not_called psql
}

@test "refusals: an injected --offset or --limit never reaches psql" {
    pg -q "SELECT 1" --offset "0; DELETE FROM users"
    [ "$status" -eq 1 ]
    last_audit '.reason == "offset-not-a-count" and .given.offset == "0; DELETE FROM users"'
    pg -q "SELECT 1" --limit "1 UNION SELECT 2"
    [ "$status" -eq 1 ]
    pg -q "SELECT 1" --limit 10001
    [[ "$output" =~ "limit-out-of-range" ]] || false
    not_called psql
}

@test "unknown arguments and an empty query are usage errors" {
    pg -q "SELECT 1" --frobnicate
    [ "$status" -eq 2 ]
    pg -q "   "
    [ "$status" -eq 2 ]
    not_called psql
}
