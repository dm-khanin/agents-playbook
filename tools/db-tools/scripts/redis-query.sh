#!/usr/bin/env bash
# redis-query.sh — read from Redis (or a Redis-compatible store) for an agent: masked, audited.
#
# Three operations, all reads:
#   inspect  -q KEY                  EXISTS, TTL, type, length and the value, MessagePack-decoded when it is
#   command  [-q KEY] --cmd VERB     one command from the read allowlist, extra arguments via --arg
#   scan     --scan PATTERN          SCAN, paced and capped; KEYS is never sent
# The allowlist is checked here and again in lib/redis-exec.js. The connection URI reaches node through the
# environment only.
set -uo pipefail

readonly USAGE='usage: redis-query.sh --profile NAME (-q KEY [--cmd VERB [--arg A]...] | --cmd VERB | --scan PATTERN)
  --cmd VERB       a read command: GET MGET TTL PTTL EXISTS TYPE STRLEN GETRANGE HGET HGETALL HKEYS HVALS HLEN
                   HMGET SMEMBERS SCARD SISMEMBER LRANGE LLEN LINDEX ZRANGE ZCARD ZSCORE MEMORY (USAGE) DBSIZE
  --scan PATTERN   list matching keys; --count N per round trip (1..10000, default 200),
                   --max-keys N in total (1..10000, default 1000)
  --no-decode      print values as strings instead of decoding MessagePack
  NAME_REDIS_URI holds the connection (redis:// or rediss://).'

DBTOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DBTOOLS_DIR DB_KIND=redis
# shellcheck source=../lib/common.sh
source "$DBTOOLS_DIR/lib/common.sh"
# shellcheck source=../lib/safety.sh
source "$DBTOOLS_DIR/lib/safety.sh"

KEY="" CMD="" SCAN_PATTERN="" COUNT=200 MAX_KEYS=1000 DECODE=true PROFILE="" UNMASK=0
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -q | --key) take "$@"; KEY="$2"; shift 2 ;;
        -c | --cmd) take "$@"; CMD="$2"; shift 2 ;;
        --arg) take "$@"; ARGS+=("$2"); shift 2 ;;
        --scan) take "$@"; SCAN_PATTERN="$2"; shift 2 ;;
        --count) take "$@"; COUNT="$2"; shift 2 ;;
        --max-keys) take "$@"; MAX_KEYS="$2"; shift 2 ;;
        --no-decode) DECODE=false; shift ;;
        --profile) take "$@"; PROFILE="$2"; shift 2 ;;
        --unmask) UNMASK=1; shift ;;
        -h | --help) echo "$USAGE"; exit 0 ;;
        *) usage_error "unknown argument: $1"$'\n'"$USAGE" ;;
    esac
done

require_profile
log_ready || usage_error "cannot write the audit log $DBTOOLS_LOG_FILE"
load_config

if [ -n "$SCAN_PATTERN" ]; then
    OP=scan
elif [ -n "$CMD" ]; then
    OP=cmd
elif [ -n "$KEY" ]; then
    OP=inspect
else
    usage_error "nothing to do: give -q KEY, --cmd VERB or --scan PATTERN"$'\n'"$USAGE"
fi

MASKED_TARGET=$(printf '%s' "${KEY:-$SCAN_PATTERN}" | mask_pii)
REQUEST=$(jq -cn --arg op "$OP" --arg key "$MASKED_TARGET" --arg cmd "$CMD" '{op: $op, key: $key, cmd: $cmd}')

case "$KEY$SCAN_PATTERN" in
    *$'\n'* | *$'\r'*) refuse "key-contains-a-line-break" "$REQUEST" ;;
esac
if [ "$OP" = cmd ]; then
    REASON=$(redis_command_reject_reason "$CMD") || refuse "$REASON" "$REQUEST"
fi
if [ "$OP" = scan ]; then
    REASON=$(check_count --count "$COUNT" 1 10000) || refuse "$REASON" "$REQUEST"
    REASON=$(check_count --max-keys "$MAX_KEYS" 1 10000) || refuse "$REASON" "$REQUEST"
    COUNT=$((10#$COUNT)) MAX_KEYS=$((10#$MAX_KEYS))
fi

URI=$(require_setting REDIS_URI) || exit "$EXIT_USAGE"

# ioredis and @msgpack/msgpack: `npm ci` in this directory, or DBTOOLS_NODE_PATH for a node_modules elsewhere.
NODE_MODULES="${DBTOOLS_NODE_PATH:-$DBTOOLS_DIR/node_modules}"
if ! [ -d "$NODE_MODULES/ioredis" ] || ! [ -d "$NODE_MODULES/@msgpack/msgpack" ]; then
    usage_error "ioredis and @msgpack/msgpack are missing from $NODE_MODULES: run npm ci in $DBTOOLS_DIR"
fi

if [ ${#ARGS[@]} -gt 0 ]; then ARGS_JSON=$(json_strings "${ARGS[@]}"); else ARGS_JSON='[]'; fi
SPEC=$(jq -cn --arg op "$OP" --arg key "$KEY" --arg cmd "$CMD" --argjson args "$ARGS_JSON" \
    --argjson decode "$DECODE" --arg pattern "$SCAN_PATTERN" --argjson count "$COUNT" --argjson maxKeys "$MAX_KEYS" \
    '{op: $op, decode: $decode}
     + (if $key != "" then {key: $key} else {} end)
     + (if $op == "cmd" then {cmd: $cmd, args: $args} else {} end)
     + (if $op == "scan" then {scan: {pattern: $pattern, count: $count, maxKeys: $maxKeys}} else {} end)')

# shellcheck disable=SC2317,SC2329 # run by run_captured
run_node() {
    DBTOOLS_REDIS_URI="$URI" NODE_PATH="$NODE_MODULES" node "$DBTOOLS_DIR/lib/redis-exec.js" "$SPEC"
}
run_captured run_node
emit "$CLIENT_OUT" "$CLIENT_ERR"

FIELDS=$(jq -c --argjson ms "$CLIENT_MS" '. + {duration_ms: $ms}' <<< "$REQUEST")
if [ "$CLIENT_STATUS" -eq 0 ]; then
    audit ok "" "$FIELDS"
    exit 0
fi
audit failed "$(first_error "$CLIENT_ERR")" "$FIELDS"
exit "$EXIT_FAILED"
