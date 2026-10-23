#!/usr/bin/env bats
# refresh-schema.sh against a fake pg_dump and a fake mongosh.

load helpers

setup() {
    common_setup
    fake_client pg_dump
    answer pg_dump $'CREATE TABLE public.users (\n    id integer NOT NULL\n);\n'
    fake_client mongosh
    answer mongosh $'## users\n- count (estimated): 2\n- sample: {"_id":{"$oid":"507f1f77bcf86cd799439011"},"email":"alice@example.com"}\n'
}
teardown() { common_teardown; }

refresh() {
    run "$SCRIPTS/refresh-schema.sh" --profile P "$@"
}

@test "both stores are dumped into the profile's own directory, privately" {
    config 'P_PG_URI=postgresql://app:pw-c41a@example.com/shop' 'P_MONGO_URI=mongodb://app:pw-c41a@h/shop'
    refresh
    [ "$status" -eq 0 ]
    grep -q 'CREATE TABLE public.users' "$DBTOOLS_SCHEMA_DIR/P/postgres.sql"
    grep -q '## users' "$DBTOOLS_SCHEMA_DIR/P/mongo.md"
    [ "$(mode_of "$DBTOOLS_SCHEMA_DIR/P/postgres.sql")" = 600 ]
    [ "$(mode_of "$DBTOOLS_SCHEMA_DIR/P")" = 700 ]
}

@test "pg_dump dumps the schema only, with the password in its environment" {
    config 'P_PG_URI=postgresql://app:pw-c41a@example.com/shop'
    refresh
    recorded pg_dump '.argv == ["--schema-only", "--no-owner", "--no-acl", "--no-comments"]'
    recorded pg_dump '.env.PGPASSWORD == "pw-c41a" and .env.PGHOST == "example.com" and .env.PGAPPNAME == "db-tools"'
    not_called mongosh
}

@test "the mongo sample is masked and keeps its ObjectId; the dump runs under the guard" {
    config 'P_MONGO_URI=mongodb://app:pw-c41a@h/shop'
    refresh
    grep -q '"email":"al\*\*@example.com"' "$DBTOOLS_SCHEMA_DIR/P/mongo.md"
    grep -q '"\$oid":"507f1f77bcf86cd799439011"' "$DBTOOLS_SCHEMA_DIR/P/mongo.md"
    jq -e --arg g "$(cat "$TOOL_DIR/lib/mongo-guard.js")" '.argv | index($g) != null' "$DBTESTDIR/mongosh.json"
    recorded mongosh '[.argv[] | contains("pw-c41a")] | any | not'
    not_called pg_dump
}

@test "each dump is logged" {
    config 'P_PG_URI=postgresql://h/shop' 'P_MONGO_URI=mongodb://h/shop'
    refresh
    jq -se 'map(.db) == ["postgres", "mongo"] and all(.outcome == "ok" and .operation == "schema")' "$DBTOOLS_LOG_FILE"
}

@test "a failed dump exits 3 and leaves no file" {
    config 'P_PG_URI=postgresql://h/shop'
    answer pg_dump "" $'pg_dump: error: connection failed\n' 1
    refresh
    [ "$status" -eq 3 ]
    [ ! -e "$DBTOOLS_SCHEMA_DIR/P/postgres.sql" ]
    last_audit '.outcome == "failed" and .db == "postgres"'
}

@test "a profile with neither store, or no profile, is a usage error" {
    refresh
    [ "$status" -eq 2 ]
    run "$SCRIPTS/refresh-schema.sh"
    [ "$status" -eq 2 ]
    not_called pg_dump
    not_called mongosh
}
