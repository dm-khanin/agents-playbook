#!/usr/bin/env bats
# mongo-explain.sh against a fake mongosh: the spec and the collection reach the fixed script as data.

load helpers

setup() {
    common_setup
    fake_client mongosh
    answer mongosh $'ACCEPTED  stage=UPDATE\n'
    config 'P_MONGO_URI=mongodb://app:pw-8b2f@example.com/shop'
    printf '%s' "$SPEC" > "$DBTESTDIR/spec.json"
}
teardown() { common_teardown; }

SPEC='{"q": {"_id": {"$oid": "507f1f77bcf86cd799439011"}}, "u": {"$set": {"items.$[i].qty": 1}}, "arrayFilters": [{"i.sku": "a"}]}'

explain() {
    run "$SCRIPTS/mongo-explain.sh" --profile P "$@" < "$DBTESTDIR/spec.json"
}

@test "the spec, the operation and the collection travel in the environment, not in the script" {
    explain --collection orders
    [ "$status" -eq 0 ]
    [[ "$output" =~ ACCEPTED ]] || false
    recorded mongosh '.env.DBTOOLS_EXPLAIN_OP == "update" and .env.DBTOOLS_EXPLAIN_COLLECTION == "orders"'
    recorded mongosh '.env.DBTOOLS_EXPLAIN_SPEC | fromjson | .u["$set"] == {"items.$[i].qty": 1}'
    recorded mongosh '[.argv[] | contains("orders") or contains("items.$[i]")] | any | not'
    recorded mongosh '.env.DBTOOLS_MONGO_URI | contains("pw-8b2f")'
    recorded mongosh '[.argv[] | contains("pw-8b2f")] | any | not'
}

@test "the script only ever explains, with the planner verbosity" {
    explain --collection orders
    recorded mongosh '.argv[-1] | contains("explain: command") and contains("verbosity: \"queryPlanner\"")'
}

@test "the spec can come from a file, and --op delete uses the deletes array" {
    printf '%s' '{"q": {"a": 1}, "limit": 0}' > "$DBTESTDIR/delete.json"
    run "$SCRIPTS/mongo-explain.sh" --profile P --collection orders --op delete --spec-file "$DBTESTDIR/delete.json"
    [ "$status" -eq 0 ]
    recorded mongosh '.env.DBTOOLS_EXPLAIN_OP == "delete"'
}

@test "a server rejection exits 3 and is logged as failed" {
    answer mongosh $'REJECTED  BadValue: No array filter found for identifier \x27i\x27\n' "" 1
    explain --collection orders
    [ "$status" -eq 3 ]
    [[ "$output" =~ "REJECTED  BadValue" ]] || false
    last_audit '.outcome == "failed" and .operation == "explain" and .collection == "orders" and (.reason | startswith("REJECTED"))'
}

@test "a collection name that could break out of the script is a usage error" {
    explain --collection 'c" } }); db.c.drop(); ({ x: "'
    [ "$status" -eq 2 ]
    [[ "$output" =~ "plain collection name" ]] || false
    not_called mongosh
}

@test "only update and delete can be explained" {
    explain --collection orders --op insert
    [ "$status" -eq 2 ]
    not_called mongosh
}

@test "a spec that is not one JSON object is a usage error" {
    run bash -c "printf '[1]' | '$SCRIPTS/mongo-explain.sh' --profile P --collection orders"
    [ "$status" -eq 2 ]
    not_called mongosh
}

@test "a profile is required" {
    run bash -c "printf '{}' | '$SCRIPTS/mongo-explain.sh' --collection orders"
    [ "$status" -eq 2 ]
    not_called mongosh
}
