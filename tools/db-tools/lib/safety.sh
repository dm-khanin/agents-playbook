#!/usr/bin/env bash
# safety.sh — the checks a wrapper runs before a query reaches its client. Each *_reason function prints
# nothing and succeeds when the input passes, or prints the reason and fails. PostgreSQL is checked by
# lib/pgcheck.py instead, because splitting SQL safely needs a real lexer.

# --- Counts ---

# check_count FLAG VALUE MIN MAX — a limit, offset, skip, size or key count is a plain decimal integer
# within bounds. Wrappers pass these numbers to the client next to a query that was already checked, so
# any other text would run unchecked.
check_count() {
    local name="${1#--}" value="$2" min="$3" max="$4"
    case "$value" in
        '' | *[!0-9]* | ??????????*)
            echo "$name-not-a-count"
            return 1
            ;;
    esac
    value=$((10#$value))
    if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        echo "$name-out-of-range ($min..$max)"
        return 1
    fi
}

# --- MongoDB ---

# Write and administration methods of the mongosh shell API. lib/mongo-guard.js replaces the same names on
# the shell's prototypes at runtime; tests/test_mongo_guard.test.mjs keeps the two lists equal.
readonly MONGO_WRITE_METHODS='insert|insertOne|insertMany|update|updateOne|updateMany|replaceOne|remove|deleteOne|deleteMany|bulkWrite|findAndModify|findOneAndUpdate|findOneAndReplace|findOneAndDelete|drop|renameCollection|createIndex|createIndexes|ensureIndex|dropIndex|dropIndexes|hideIndex|unhideIndex|reIndex|convertToCapped|mapReduce|initializeOrderedBulkOp|initializeUnorderedBulkOp|createSearchIndex|createSearchIndexes|updateSearchIndex|dropSearchIndex|compactStructuredEncryptionData|configureQueryAnalyzer|getPlanCache|dropDatabase|createCollection|createView|runCommand|adminCommand|createUser|updateUser|changeUserPassword|dropUser|dropAllUsers|grantRolesToUser|revokeRolesFromUser|createRole|updateRole|dropRole|dropAllRoles|grantPrivilegesToRole|revokePrivilegesFromRole|grantRolesToRole|revokeRolesFromRole|shutdownServer|fsyncLock|fsyncUnlock|killOp|setProfilingLevel|setLogLevel|rotateCertificates|getClientEncryption|getKeyVault'

# Names that only the driver behind the shell has: the client, the generic command runners and writes the
# shell API calls something else. A read query never needs them.
readonly MONGO_DRIVER_NAMES='mongoClient|runCommandWithCheck|runCursorCommand|clientBulkWrite|initializeBulkOp|dropCollection'

readonly JS_START='(^|[^A-Za-z0-9_$])'
readonly JS_END='([^A-Za-z0-9_$]|$)'

# mongo_reject_reason EXPRESSION — a tripwire over the expression's text. JavaScript cannot be checked
# completely by patterns, so this layer names the common ways to write, to run server-side code or to leave
# the query; lib/mongo-guard.js catches what reaches a write method another way. Neither is a boundary: a
# database user with only the read role is.
#
# Two views of the text. Names that must not appear at all are looked for in the raw text, strings included,
# because a quoted key in a parameter pattern can still reach them (({"constructor": C}) => ...). The
# structure (calls, computed members, destructuring, a second statement, internal names) is checked on the
# code alone, from lib/jsblank.py, so that a ; a [ or an _ inside a string or a regular expression is data.
mongo_reject_reason() {
    local raw code
    # One line, so a pattern also sees a name and its parenthesis on different lines.
    raw=$(printf '%s' "$1" | tr '\n\r\t' '   ')
    code=$(printf '%s' "$1" | python3 -I "$DBTOOLS_DIR/lib/jsblank.py") || {
        echo "${code:-unterminated-literal}"
        return 1
    }
    code=$(printf '%s' "$code" | tr '\n\r\t' '   ' | sed -E 's/[[:space:];]+$//')

    # --- names, in the raw text ---
    # shellcheck disable=SC2016 # literal $ in the pattern
    if echo "$raw" | grep -qE '\$(where|function|accumulator)([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_$])mapReduce([^A-Za-z0-9_$]|$)'; then
        echo "server-side-js"
        return 1
    fi
    # shellcheck disable=SC2016 # literal $ in the pattern
    if echo "$raw" | grep -qE '\$(out|merge)([^A-Za-z0-9_]|$)'; then
        echo "aggregate-write-stage"
        return 1
    fi
    # Node modules and the process (shell commands, the environment), and the ways to a constructor or a
    # prototype, which lead to Function and from there anywhere.
    if echo "$raw" | grep -qE "${JS_START}(require|load|import)[[:space:]]*\\(|${JS_START}(process|mainModule|constructor|prototype|getPrototypeOf|setPrototypeOf|defineProperty|defineProperties)${JS_END}"; then
        echo "shell-escape"
        return 1
    fi
    # The driver behind the shell, its generic commands and the writes the shell API calls something else.
    if echo "$raw" | grep -qE "${JS_START}(${MONGO_DRIVER_NAMES})${JS_END}"; then
        echo "driver-handle"
        return 1
    fi

    # --- structure, in the code alone ---
    if [[ "$code" == *";"* ]]; then
        echo "multi-statement"
        return 1
    fi
    if echo "$code" | grep -qE "${JS_START}(eval|Function)[[:space:]]*[(\`]"; then
        echo "js-eval"
        return 1
    fi
    if echo "$code" | grep -qE "${JS_START}(this|global|globalThis|Object|Reflect|Proxy)${JS_END}"; then
        echo "shell-escape"
        return 1
    fi
    # A write method called, also with whitespace, a comment or optional chaining before the call, as a tagged
    # template, or through call, apply or bind.
    if echo "$code" | grep -qE "\\.[[:space:]]*($MONGO_WRITE_METHODS)[[:space:]]*(\\?\\.[[:space:]]*)?[(\`]|\\.[[:space:]]*($MONGO_WRITE_METHODS)[[:space:]]*\\.[[:space:]]*(call|apply|bind)${JS_END}"; then
        echo "write-method"
        return 1
    fi
    # A computed member or key can name anything: db.c["deleteMany"], x[k].call(...), ({[k]: v} = obj). Only a
    # numeric index (docs[0]) is allowed.
    if echo "$code" | grep -oE '[]A-Za-z0-9_$)][[:space:]]*(\?\.[[:space:]]*)?\[[^]]*\]?' | grep -qvE '\[[[:space:]]*[0-9]+[[:space:]]*\]$' \
        || echo "$code" | grep -qE '\{[[:space:]]*\[|,[[:space:]]*\[[^]]*\][[:space:]]*:'; then
        echo "computed-member"
        return 1
    fi
    # A name in the code that starts with an underscore is one of the shell's internals, such as
    # _serviceProvider, the driver handle; _id is a field. In a string it is data (video ids start with _),
    # and a string cannot become a member name: computed members are refused above, destructuring below.
    if echo "$code" | grep -oE "${JS_START}_[A-Za-z0-9_$]*" | grep -qvE '(^|[^A-Za-z0-9_$])_id$'; then
        echo "private-member"
        return 1
    fi
    # A destructuring assignment can pick any member by a quoted key: ({"_x": v} = obj).
    if echo "$code" | grep -qE '[]}][[:space:]]*=([^=>]|$)'; then
        echo "destructuring"
        return 1
    fi
    # Replica set, sharding and stream processing helpers administer the cluster.
    if echo "$code" | grep -qE '(^|[^A-Za-z0-9_$.])(rs|sh|sp)[[:space:]]*\.'; then
        echo "cluster-helper"
        return 1
    fi
    return 0
}

# mongo_with_read_preference URI — the URI with readPreference=secondaryPreferred, replacing any other.
# This keeps reads off the primary; it does not make the connection read-only.
mongo_with_read_preference() {
    local uri
    uri=$(echo "$1" | sed -E 's/([?&])readPreference=[^&]*&?/\1/g; s/[?&]$//')
    if [[ "$uri" == *"?"* ]]; then
        echo "$uri&readPreference=secondaryPreferred"
    else
        echo "$uri?readPreference=secondaryPreferred"
    fi
}

# --- Elasticsearch ---

# es_endpoint_reject_reason ENDPOINT — a read API whose every path segment is a plain name. curl collapses
# "." and ".." segments before it sends a request, so a prefix check alone would let "_search/../_doc/1"
# reach a write API; es-query.sh also passes --path-as-is, so the path checked here is the path sent.
es_endpoint_reject_reason() {
    local endpoint="$1" segment
    local -a segments
    case "$endpoint" in
        _search | _count | _msearch | _mapping | _field_caps | _search/* | _cat | _cat/*) ;;
        *)
            echo "endpoint-not-a-read-api"
            return 1
            ;;
    esac
    case "$endpoint" in
        */ | *//*)
            echo "endpoint-segment-not-allowed"
            return 1
            ;;
    esac
    IFS=/ read -r -a segments <<< "$endpoint"
    for segment in "${segments[@]}"; do
        case "$segment" in
            . | .. | *[!A-Za-z0-9_.*,-]*)
                echo "endpoint-segment-not-allowed"
                return 1
                ;;
        esac
    done
}

# es_index_reject_reason INDEX — comma-separated index names or patterns; "." and ".." would climb the path.
es_index_reject_reason() {
    if ! [[ "$1" =~ ^[A-Za-z0-9_.*,-]+$ ]]; then
        echo "index-name-not-allowed"
        return 1
    fi
    case ",$1," in
        *,.,* | *,..,*)
            echo "index-name-not-allowed"
            return 1
            ;;
    esac
}

# --- Redis ---

# Read commands that --cmd may run. lib/redis-exec.js keeps its own copy, READ_COMMANDS, and refuses again;
# tests/test_redis_query.bats keeps the two equal. MEMORY is pinned to its USAGE subcommand there. SCAN is not
# a --cmd: keys are listed by the paced --scan operation, and KEYS is never sent.
readonly REDIS_READ_COMMANDS='GET MGET TTL PTTL EXISTS TYPE STRLEN GETRANGE HGET HGETALL HKEYS HVALS HLEN HMGET SMEMBERS SCARD SISMEMBER LRANGE LLEN LINDEX ZRANGE ZCARD ZSCORE MEMORY DBSIZE'

redis_command_reject_reason() {
    local command
    command=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    if ! [[ "$command" =~ ^[A-Z]+$ ]]; then
        echo "command-not-a-read"
        return 1
    fi
    case " $REDIS_READ_COMMANDS " in
        *" $command "*) return 0 ;;
    esac
    echo "command-not-a-read"
    return 1
}
