#!/usr/bin/env bats
# The checks in lib/safety.sh: counts, the MongoDB tripwire, Elasticsearch paths and the Redis allowlist.

load helpers

setup() {
    DBTOOLS_DIR="$TOOL_DIR"
    source "$TOOL_DIR/lib/safety.sh"
}

refused_with() {
    [ "$status" -ne 0 ] && [ "$output" = "$1" ]
}

# --- counts ---

@test "count: plain integers within bounds pass" {
    for v in 0 1 100 10000 007; do
        run check_count --limit "$v" 0 10000
        [ "$status" -eq 0 ]
    done
}

@test "count: anything but digits is refused with the flag's name" {
    for v in "" "-1" "1.5" "1e3" "0x10" " 5" "1 OFFSET 0" "0; DELETE FROM users" "0).drop(" "1234567890"; do
        run check_count --offset "$v" 0 999999999
        refused_with offset-not-a-count
    done
}

@test "count: out of range is refused" {
    run check_count --limit 10001 1 10000
    refused_with "limit-out-of-range (1..10000)"
    run check_count --limit 0 1 10000
    refused_with "limit-out-of-range (1..10000)"
}

@test "count: leading zeros are decimal, not octal" {
    run check_count --limit 0010001 1 10000
    refused_with "limit-out-of-range (1..10000)"
    run check_count --limit 09 1 10000
    [ "$status" -eq 0 ]
}

# --- MongoDB: what passes ---

@test "mongo: ordinary reads pass" {
    for q in \
        'db.users.find({})' \
        'db.users.find({email: /gmail[.]com$/}).sort({_id: -1}).limit(5)' \
        'db.c.find({_id: {$in: [1, 2]}, processed_at: {$gt: 0}}).map(d => d._id)' \
        'db.c.aggregate([{$match: {a: 1}}, {$group: {_id: "$b", n: {$sum: 1}}}])' \
        'db.c.countDocuments({status: "open"})' \
        'db.c.distinct("type")' \
        'db.getCollectionNames()' \
        'db.c.getIndexes()' \
        'db.c.find({}).explain("executionStats")' \
        'db.c.find({note: "see https://example.com/a"})' \
        'db.c.find({});' \
        $'db.c.aggregate([\n  {$match: {}},\n  {$count: "n"}\n])'; do
        run mongo_reject_reason "$q"
        [ "$status" -eq 0 ] || { echo "refused: $q -> $output"; false; }
    done
}

@test "mongo: a write method's name inside a longer name is not a write" {
    run mongo_reject_reason 'db.c.find({}).explain().queryPlanner.droppedStages'
    [ "$status" -eq 0 ]
    run mongo_reject_reason 'db.updates_log.find({})'
    [ "$status" -eq 0 ]
}

# --- MongoDB: writes ---

@test "mongo: write methods are refused" {
    for m in insertOne insertMany updateOne updateMany replaceOne deleteOne deleteMany remove bulkWrite \
        findOneAndUpdate findOneAndDelete findAndModify drop renameCollection createIndex dropIndexes \
        initializeOrderedBulkOp dropDatabase createCollection createView createUser; do
        run mongo_reject_reason "db.c.$m({})"
        refused_with write-method
    done
}

@test "mongo: write methods with whitespace, a line break or optional chaining before the call" {
    run mongo_reject_reason 'db.c.deleteMany ({})'
    refused_with write-method
    run mongo_reject_reason $'db.c.insertOne\t({a: 1})'
    refused_with write-method
    run mongo_reject_reason $'db.c\n  .deleteMany\n  ({})'
    refused_with write-method
    run mongo_reject_reason 'db.c.deleteMany?.({})'
    refused_with write-method
}

@test "mongo: write methods through call, apply or bind" {
    for via in call apply bind; do
        run mongo_reject_reason "db.c.deleteMany.$via(db.c, {})"
        refused_with write-method
    done
}

@test "mongo: arbitrary commands are refused" {
    run mongo_reject_reason 'db.runCommand({ping: 1})'
    refused_with write-method
    run mongo_reject_reason 'db.adminCommand({listDatabases: 1})'
    refused_with write-method
}

@test "mongo: \$out and \$merge stages are refused" {
    run mongo_reject_reason 'db.c.aggregate([{$match: {}}, {$out: "copy"}])'
    refused_with aggregate-write-stage
    run mongo_reject_reason 'db.c.aggregate([{$merge: {into: "copy"}}])'
    refused_with aggregate-write-stage
}

@test "mongo: a computed member or key is refused; a numeric index is not" {
    for q in 'db.c["deleteMany"]({})' 'db.getCollection("c")["drop"]()' 'db.c[name].call(db.c, {})' \
        'db.c["find"]({})' '({[k]: v} = db.getMongo())' '({a: 1, [k]: v} = db.getMongo())' \
        'db.c.find({}).map(d => `${db.c["x"]}`)' '({}/db.c["delete" + "Many"]({})/1)'; do
        run mongo_reject_reason "$q"
        refused_with computed-member
    done
    run mongo_reject_reason 'db.c.find({}).toArray()[0][ 1 ]'
    [ "$status" -eq 0 ]
}

# --- MongoDB: server-side JavaScript and ways out of the query ---

@test "mongo: server-side JavaScript is refused" {
    run mongo_reject_reason 'db.c.find({$where: "this.a == 1"})'
    refused_with server-side-js
    run mongo_reject_reason 'db.c.find({$expr: {$function: {body: "1", args: [], lang: "js"}}})'
    refused_with server-side-js
    run mongo_reject_reason 'db.c.aggregate([{$group: {_id: 1, x: {$accumulator: {}}}}])'
    refused_with server-side-js
    run mongo_reject_reason 'db.c.mapReduce(m, r)'
    refused_with server-side-js
}

@test "mongo: eval and the Function constructor are refused" {
    run mongo_reject_reason 'eval("1")'
    refused_with js-eval
    run mongo_reject_reason 'new Function ("return 1")()'
    refused_with js-eval
    run mongo_reject_reason 'db.c.find({}).explain()'
    [ "$status" -eq 0 ]
}

@test "mongo: modules and the process are refused" {
    run mongo_reject_reason "require('child_process').execSync('id').toString()"
    refused_with shell-escape
    run mongo_reject_reason "this.require('fs')"
    refused_with shell-escape
    run mongo_reject_reason 'print(process.env)'
    refused_with shell-escape
    run mongo_reject_reason 'load("x.js")'
    refused_with shell-escape
    run mongo_reject_reason 'import("fs")'
    refused_with shell-escape
    run mongo_reject_reason $'require\n  ("child_process")'
    refused_with shell-escape
}

@test "mongo: reflection and prototypes are refused" {
    for q in 'globalThis.x' 'Reflect.get(db, "c")' 'new Proxy({}, {})' '[].map.constructor("x")()' \
        'Object.getPrototypeOf(db.c)' 'Object.defineProperty(o, "a", {})'; do
        run mongo_reject_reason "$q"
        refused_with shell-escape
    done
}

@test "mongo: the shell's private members are refused, _id is a field" {
    run mongo_reject_reason 'db.getMongo()._serviceProvider'
    refused_with private-member
    run mongo_reject_reason 'db._mongo'
    refused_with private-member
    run mongo_reject_reason 'db.c.__proto__'
    refused_with private-member
    run mongo_reject_reason 'db.c.find({}).map(d => d._id)'
    [ "$status" -eq 0 ]
}

@test "mongo: cluster helpers are refused" {
    for q in 'rs.stepDown()' 'sh.enableSharding("x")' 'sp.listStreamProcessors()'; do
        run mongo_reject_reason "$q"
        refused_with cluster-helper
    done
}

@test "mongo: a second statement is refused, and a comment does not split a call from its name" {
    run mongo_reject_reason 'db.c.find({}); db.c.find({})'
    refused_with multi-statement
    run mongo_reject_reason 'db.c.deleteMany/**/({})'
    refused_with write-method
    run mongo_reject_reason $'db.c.deleteMany // why\n({})'
    refused_with write-method
}

@test "mongo: a tagged template is a call" {
    run mongo_reject_reason 'db.c.deleteMany`x`'
    refused_with write-method
}

@test "mongo: the driver handle is refused however it is spelled" {
    run mongo_reject_reason 'db.getMongo()["_serviceProvider"].dropCollection("db", "coll")'
    refused_with driver-handle
    run mongo_reject_reason 'db.getMongo()["_serviceProvider"]'
    refused_with computed-member
    run mongo_reject_reason 'db.getMongo()._serviceProvider'
    refused_with private-member
    run mongo_reject_reason '({"_serviceProvider": sp} = db.getMongo())'
    refused_with destructuring
    run mongo_reject_reason '([a, b] = x)'
    refused_with destructuring
    run mongo_reject_reason '({"mongoClient": mc} = x)'
    refused_with driver-handle
    for name in runCommandWithCheck runCursorCommand clientBulkWrite initializeBulkOp dropCollection; do
        run mongo_reject_reason "x.$name(1)"
        refused_with driver-handle
    done
}

@test "mongo: a quoted key cannot reach a constructor, and the global object is not reachable" {
    run mongo_reject_reason '({"constructor": C} = [].map)'
    refused_with shell-escape
    for q in 'this.x' 'global.process' 'globalThis.x' 'Object.values(db.getMongo())[2]'; do
        run mongo_reject_reason "$q"
        refused_with shell-escape
    done
}

@test "mongo: inside strings and regular expressions, ; [ and keywords are text" {
    for q in 'db.c.find({email: /gmail[.]com$/i})' 'db.c.find({name: {$regex: "a[b]"}, note: "x;y"})' \
        'db.c.find({status: "processing", scope: "global", kind: "this"})' \
        'db.system.profile.find({"command.find": "x"})' 'db.c.find({}).map(d => `${d.items[0]}`)'; do
        run mongo_reject_reason "$q"
        [ "$status" -eq 0 ] || { echo "refused: $q -> $output"; false; }
    done
}

@test "mongo: a string that starts with an underscore is data, and comparisons are not assignments" {
    run mongo_reject_reason 'db.videos.find({id: {$in: ["_x7Gq1abcde", "-k2m9zzzzzz"]}}, {_id: 0, id: 1})'
    [ "$status" -eq 0 ]
    run mongo_reject_reason 'db.c.find({}).toArray().filter(d => d.items[0] === 1 && d.n >= 2).map(d => ({a: d.a}))'
    [ "$status" -eq 0 ]
}

@test "mongo: an unterminated literal is refused" {
    run mongo_reject_reason 'db.c.find({x: "open})'
    refused_with unterminated-string
    run mongo_reject_reason 'db.c.find({x: /open})'
    refused_with unterminated-regex
}

@test "mongo: the read preference becomes secondaryPreferred" {
    run mongo_with_read_preference 'mongodb://h/db'
    [ "$output" = 'mongodb://h/db?readPreference=secondaryPreferred' ]
    run mongo_with_read_preference 'mongodb+srv://u:p@h/db?retryWrites=true&readPreference=primary&w=majority'
    [ "$output" = 'mongodb+srv://u:p@h/db?retryWrites=true&w=majority&readPreference=secondaryPreferred' ]
}

# --- Elasticsearch ---

@test "es: read APIs pass, with path parameters" {
    for e in _search _count _msearch _mapping _field_caps _search/template _cat _cat/indices 'cat/x' ; do
        run es_endpoint_reject_reason "$e"
        if [ "$e" = cat/x ]; then refused_with endpoint-not-a-read-api; else [ "$status" -eq 0 ]; fi
    done
    run es_endpoint_reject_reason '_cat/indices/products*,logs-2026.10'
    [ "$status" -eq 0 ]
}

@test "es: write APIs are refused" {
    for e in _doc _bulk _delete_by_query _update_by_query _reindex _settings _aliases _security/user; do
        run es_endpoint_reject_reason "$e"
        refused_with endpoint-not-a-read-api
    done
}

@test "es: dot segments, encoded characters and empty segments are refused" {
    for e in '_search/../_doc/1' '_cat/../products/_delete_by_query' '_search/./x' '_search/%2e%2e/_bulk' \
        '_cat//indices' '_search/' '_search/a?b' '_search/a b'; do
        run es_endpoint_reject_reason "$e"
        refused_with endpoint-segment-not-allowed
    done
}

@test "es: index names" {
    run es_index_reject_reason '.kibana,products-2026.10,logs-*'
    [ "$status" -eq 0 ]
    for i in '..' 'products,..' '.' 'a/b' 'a?b' 'a b'; do
        run es_index_reject_reason "$i"
        refused_with index-name-not-allowed
    done
}

# --- Redis ---

@test "redis: read commands pass in any case" {
    for c in GET get TTL MGET HGETALL ZRANGE MEMORY DBSIZE; do
        run redis_command_reject_reason "$c"
        [ "$status" -eq 0 ]
    done
}

@test "redis: everything else is refused, including SCAN, KEYS and two words" {
    for c in SET DEL GETDEL GETEX EXPIRE RENAME FLUSHALL FLUSHDB CONFIG SHUTDOWN EVAL FUNCTION SORT \
        RESTORE MIGRATE SWAPDB ACL KEYS SCAN OBJECT 'HGET HGETALL' '' 'GET;DEL'; do
        run redis_command_reject_reason "$c"
        refused_with command-not-a-read
    done
}
