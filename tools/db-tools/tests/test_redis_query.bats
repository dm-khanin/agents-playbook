#!/usr/bin/env bats
# redis-query.sh against a fake node, and lib/redis-exec.js itself with the real node: the offline decoder
# and its own allowlist. Those need `npm ci` in the tool directory; without it they skip, unless
# DBTOOLS_REQUIRE_INTEGRATION=1, which CI sets, makes that a failure.

load helpers

setup() {
    REAL_NODE="$(command -v node)"
    common_setup
    mkdir -p "$DBTESTDIR/deps/ioredis" "$DBTESTDIR/deps/@msgpack/msgpack"
    export DBTOOLS_NODE_PATH="$DBTESTDIR/deps"
    config 'P_REDIS_URI=rediss://default:pw-2b7e@example.com:6380'
}
teardown() { common_teardown; }

with_fake_node() {
    fake_client node
    answer node $'{"op":"inspect","exists":1,"value":{"owner":"alice@example.com"}}\n'
}

redis() {
    run "$SCRIPTS/redis-query.sh" --profile P "$@"
}

spec() {
    jq -e ".argv[1] | fromjson | $1" "$DBTESTDIR/node.json" > /dev/null
}

need_real_deps() {
    if ! [ -d "$TOOL_DIR/node_modules/ioredis" ] || ! [ -d "$TOOL_DIR/node_modules/@msgpack/msgpack" ]; then
        [ "${DBTOOLS_REQUIRE_INTEGRATION:-0}" = 1 ] && { echo "run npm ci in $TOOL_DIR" >&2; return 1; }
        skip "npm ci has not been run in $TOOL_DIR"
    fi
}

@test "a key alone is an inspect, and the URI reaches node in its environment only" {
    with_fake_node
    redis -q 'session:42'
    [ "$status" -eq 0 ]
    recorded node '.argv[0] | endswith("lib/redis-exec.js")'
    spec '. == {op: "inspect", decode: true, key: "session:42"}'
    recorded node '.env.DBTOOLS_REDIS_URI == "rediss://default:pw-2b7e@example.com:6380"'
    recorded node '[.argv[] | contains("pw-2b7e")] | any | not'
    recorded node ".env.NODE_PATH == \"$DBTESTDIR/deps\""
}

@test "a read command with its arguments" {
    with_fake_node
    redis -q 'scores' --cmd zrange --arg 0 --arg -1
    spec '.op == "cmd" and .cmd == "zrange" and .args == ["0", "-1"] and .key == "scores"'
    redis --cmd DBSIZE
    spec '.op == "cmd" and .cmd == "DBSIZE" and (has("key") | not)'
}

@test "a scan carries its pattern and bounds" {
    with_fake_node
    redis --scan 'session:*' --count 50 --max-keys 0300
    spec '.op == "scan" and .scan == {pattern: "session:*", count: 50, maxKeys: 300}'
}

@test "--no-decode turns decoding off" {
    with_fake_node
    redis -q 'k' --no-decode
    spec '.decode == false'
}

@test "output is masked and the call is logged" {
    with_fake_node
    redis -q 'session:42'
    [[ "$output" =~ al\*\*@example\.com ]] || false
    [[ "$output" != *alice* ]] || false
    last_audit '.db == "redis" and .outcome == "ok" and .op == "inspect" and .key == "session:42"'
}

@test "a failure in node exits 3" {
    with_fake_node
    answer node "" $'connect ECONNREFUSED 127.0.0.1:6380\n' 1
    redis -q 'k'
    [ "$status" -eq 3 ]
    last_audit '.outcome == "failed" and (.reason | startswith("connect ECONNREFUSED"))'
}

@test "refusals: commands outside the allowlist, before node runs" {
    with_fake_node
    for c in SET DEL FLUSHALL CONFIG EVAL KEYS SCAN 'GET MGET'; do
        redis -q 'k' --cmd "$c"
        [ "$status" -eq 1 ] || { echo "not refused: $c"; false; }
    done
    last_audit '.outcome == "refused" and .reason == "command-not-a-read"'
    not_called node
}

@test "refusals: a key with a line break, and injected scan bounds" {
    with_fake_node
    redis -q $'k\r\nFLUSHALL'
    [ "$status" -eq 1 ]
    redis --scan 'k:*' --count '1,"x":1'
    [ "$status" -eq 1 ]
    redis --scan 'k:*' --max-keys 20000
    [ "$status" -eq 1 ]
    not_called node
}

@test "usage errors: nothing to do, no profile, no URI, no dependencies" {
    with_fake_node
    redis
    [ "$status" -eq 2 ]
    run "$SCRIPTS/redis-query.sh" -q k
    [ "$status" -eq 2 ]
    run "$SCRIPTS/redis-query.sh" --profile NOPE -q k
    [ "$status" -eq 2 ]
    DBTOOLS_NODE_PATH="$DBTESTDIR/empty" redis -q k
    [ "$status" -eq 2 ]
    [[ "$output" =~ "npm ci" ]] || false
    not_called node
}

@test "the two allowlists name the same commands" {
    bash_list=$(bash -c "source '$TOOL_DIR/lib/safety.sh'; printf '%s\n' \$REDIS_READ_COMMANDS" | sort | tr '\n' ' ')
    js_list=$(sed -n '/^const READ_COMMANDS = new Set(\[/,/^\]);/p' "$TOOL_DIR/lib/redis-exec.js" \
        | grep -oE "'[A-Z]+'" | tr -d "'" | sort | tr '\n' ' ')
    [ -n "$bash_list" ]
    [ "$bash_list" = "$js_list" ]
}

@test "redis-exec.js: MessagePack values decode, anything else prints as a string" {
    need_real_deps
    NODE_PATH="$TOOL_DIR/node_modules" "$REAL_NODE" -e '
        const { encode } = require("@msgpack/msgpack");
        require("fs").writeFileSync(process.argv[1], encode({ bv: [1, 2], name: "x" }));
    ' "$DBTESTDIR/packed.bin"
    printf 'plain text' > "$DBTESTDIR/plain.bin"
    run env NODE_PATH="$TOOL_DIR/node_modules" "$REAL_NODE" "$TOOL_DIR/lib/redis-exec.js" "{\"op\":\"decode-file\",\"file\":\"$DBTESTDIR/packed.bin\"}"
    [ "$status" -eq 0 ]
    jq -e '.encoding == "msgpack" and .value == {bv: [1, 2], name: "x"}' <<< "$output"
    run env NODE_PATH="$TOOL_DIR/node_modules" "$REAL_NODE" "$TOOL_DIR/lib/redis-exec.js" "{\"op\":\"decode-file\",\"file\":\"$DBTESTDIR/plain.bin\"}"
    jq -e '.encoding == "string" and .value == "plain text"' <<< "$output"
}

@test "redis-exec.js: it refuses a command outside its own allowlist" {
    need_real_deps
    for c in SET FLUSHALL KEYS; do
        run env NODE_PATH="$TOOL_DIR/node_modules" DBTOOLS_REDIS_URI=redis://127.0.0.1:1 \
            "$REAL_NODE" "$TOOL_DIR/lib/redis-exec.js" "{\"op\":\"cmd\",\"cmd\":\"$c\",\"key\":\"k\"}"
        [ "$status" -eq 1 ]
        [[ "$output" =~ "command '$c' is not a read command" ]] || false
    done
    run env NODE_PATH="$TOOL_DIR/node_modules" DBTOOLS_REDIS_URI=redis://127.0.0.1:1 \
        "$REAL_NODE" "$TOOL_DIR/lib/redis-exec.js" '{"op":"cmd","cmd":"MEMORY","args":["DOCTOR"]}'
    [[ "$output" =~ "MEMORY only allows USAGE" ]] || false
}
