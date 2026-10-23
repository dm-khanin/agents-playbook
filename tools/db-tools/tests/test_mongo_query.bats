#!/usr/bin/env bats
# mongo-query.sh against a fake mongosh: what reaches it, what the agent sees, what the log records.
# tests/mongo_guard.test.mjs covers the runtime guard it loads.

load helpers

setup() {
    common_setup
    fake_client mongosh
    answer mongosh $'{"_id":{"$oid":"507f1f77bcf86cd799439011"},"email":"alice@example.com"}\n' \
        $'db-tools: 1 result(s)\n'
    config 'P_MONGO_URI=mongodb+srv://app:pw-3c9e@example.net/shop?retryWrites=true&readPreference=primary'
}
teardown() { common_teardown; }

mongo() {
    run "$SCRIPTS/mongo-query.sh" --profile P "$@"
}

# eval_arg N — the Nth --eval mongosh received, counting from 0.
eval_arg() {
    jq -r --argjson n "$1" '[.argv as $a | range(0; $a | length) | select($a[.] == "--eval") | $a[. + 1]][$n]' \
        "$DBTESTDIR/mongosh.json"
}

@test "mongosh starts without a connection or mongoshrc, then connects, guards and prints" {
    mongo -q 'db.users.find({})'
    [ "$status" -eq 0 ]
    recorded mongosh '.argv[0:3] == ["--nodb", "--norc", "--quiet"]'
    [ "$(eval_arg 0)" = "$(cat "$TOOL_DIR/lib/mongo-connect.js")" ]
    [ "$(eval_arg 1)" = "$(cat "$TOOL_DIR/lib/mongo-guard.js")" ]
    [ "$(eval_arg 2)" = $'__dbtoolsPrint((\ndb.users.find({})\n))' ]
}

@test "the connection string travels in the environment, with readPreference=secondaryPreferred" {
    mongo -q 'db.users.find({})'
    recorded mongosh '.env.DBTOOLS_MONGO_URI == "mongodb+srv://app:pw-3c9e@example.net/shop?retryWrites=true&readPreference=secondaryPreferred"'
    recorded mongosh '[.argv[] | contains("pw-3c9e")] | any | not'
}

@test "another profile's URI does not reach mongosh" {
    config 'Q_MONGO_URI=mongodb://other:pw-41d0@h/db'
    mongo -q 'db.users.find({})'
    recorded mongosh '[.env[] | contains("pw-41d0")] | any | not'
}

@test "--limit, --skip and the time limit reach the guard" {
    mongo -q 'db.users.find({})' --limit 007 --skip 20
    recorded mongosh '.env.DBTOOLS_LIMIT == "7" and .env.DBTOOLS_SKIP == "20" and .env.DBTOOLS_MAX_TIME_MS == "600000"'
}

@test "the defaults are --limit 100 and no skip" {
    mongo -q 'db.users.find({})'
    recorded mongosh '.env.DBTOOLS_LIMIT == "100" and .env.DBTOOLS_SKIP == "0"'
}

@test "a trailing semicolon is dropped, and the expression is not rewritten" {
    mongo -q 'db.users.find({a: 1}).sort({_id: -1});  '
    [ "$(eval_arg 2)" = $'__dbtoolsPrint((\ndb.users.find({a: 1}).sort({_id: -1})\n))' ]
}

@test "the expression can come on stdin" {
    run bash -c "echo 'db.users.countDocuments({})' | '$SCRIPTS/mongo-query.sh' --profile P"
    [ "$status" -eq 0 ]
    [ "$(eval_arg 2)" = $'__dbtoolsPrint((\ndb.users.countDocuments({})\n))' ]
}

@test "output is masked; the ObjectId stays; the result count is logged" {
    mongo -q 'db.users.find({})'
    [[ "$output" =~ al\*\*@example\.com ]] || false
    [[ "$output" =~ 507f1f77bcf86cd799439011 ]] || false
    [[ "$output" != *alice* ]] || false
    last_audit '.db == "mongo" and .outcome == "ok" and .results == 1 and .limit == 100 and .skip == null
        and .query == "db.users.find({})"'
}

@test "a server error exits 3 and is logged as failed" {
    answer mongosh "" $'MongoServerError: unknown top level operator: $bogus\n' 1
    mongo -q 'db.users.find({$bogus: 1})'
    [ "$status" -eq 3 ]
    last_audit '.outcome == "failed" and (.reason | startswith("MongoServerError"))'
}

@test "a write the guard stopped at runtime exits 1 and is logged as refused" {
    answer mongosh "" $'Error: db-tools: refused: the $out stage writes\n' 1
    mongo -q 'db.users.aggregate([{$match: {}}])'
    [ "$status" -eq 1 ]
    last_audit '.outcome == "refused" and .reason == "guard: the $out stage writes"'
}

@test "refusals: exit 1, the reason, logged with the arguments, mongosh never runs" {
    mongo -q 'db.users.deleteMany({})'
    [ "$status" -eq 1 ]
    [[ "$output" =~ "refused: write-method" ]] || false
    last_audit '.outcome == "refused" and .reason == "write-method" and .query == "db.users.deleteMany({})"'
    mongo -q "require('child_process').execSync('id')"
    [[ "$output" =~ "refused: shell-escape" ]] || false
    mongo -q 'db.users["deleteMany"]({})'
    [[ "$output" =~ "refused: computed-member" ]] || false
    not_called mongosh
}

@test "refusals: an injected --skip or --limit never reaches mongosh" {
    mongo -q 'db.users.find({})' --skip '0).drop('
    [ "$status" -eq 1 ]
    last_audit '.reason == "skip-not-a-count" and .given.skip == "0).drop("'
    mongo -q 'db.users.find({})' --limit 20000
    [[ "$output" =~ "limit-out-of-range" ]] || false
    not_called mongosh
}

@test "no --profile, or no MONGO_URI for it: usage error, mongosh never runs" {
    run "$SCRIPTS/mongo-query.sh" -q 'db.users.find({})'
    [ "$status" -eq 2 ]
    run "$SCRIPTS/mongo-query.sh" --profile NOPE -q 'db.users.find({})'
    [ "$status" -eq 2 ]
    [[ "$output" =~ "NOPE_MONGO_URI is not set" ]] || false
    not_called mongosh
}
