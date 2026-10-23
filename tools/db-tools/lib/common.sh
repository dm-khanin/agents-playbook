#!/usr/bin/env bash
# common.sh — configuration, profiles, the audit line and output, shared by every db-tools wrapper.
# The sourcing script sets DBTOOLS_DIR and DB_KIND first, and PROFILE and UNMASK while it parses arguments.

# shellcheck source=log.sh
source "$DBTOOLS_DIR/lib/log.sh"
# shellcheck source=mask.sh
source "$DBTOOLS_DIR/lib/mask.sh"

: "${DBTOOLS_ENV_FILE:=${XDG_CONFIG_HOME:-$HOME/.config}/db-tools/.env}"

# Exit codes of every wrapper: 0 success, 1 refused by db-tools, 2 usage or configuration error,
# 3 the store returned an error or could not be reached.
# shellcheck disable=SC2034 # each wrapper uses the ones it needs
readonly EXIT_REFUSED=1 EXIT_USAGE=2 EXIT_FAILED=3

# The settings a profile can have. Only these are read from the config file, so a stray line there can
# never overwrite one of a wrapper's own variables.
readonly SETTING_KEY_RE='^[A-Za-z][A-Za-z0-9_]*_(PG_URI|MONGO_URI|ES_URL|ES_CLOUD_ID|ES_API_KEY|ES_CREDENTIAL|ES_AUTH|REDIS_URI)$'

usage_error() {
    echo "db-tools: $*" >&2
    exit "$EXIT_USAGE"
}

# take FLAG [VALUE...] — called with the remaining arguments before a flag's value is read.
take() {
    [ $# -ge 2 ] || usage_error "$1 needs a value"
}

# load_config — read NAME_SETTING=VALUE lines from $DBTOOLS_ENV_FILE into shell variables. A value is taken
# literally (no expansion, so & and $ in a password survive) and may be wrapped in one pair of quotes. A
# variable already set in the environment wins. Nothing is exported: each wrapper hands its client only the
# connection it uses, so a query that reads its own environment finds no other profile's secrets.
load_config() {
    [ -f "$DBTOOLS_ENV_FILE" ] || return 0
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        [[ "$key" =~ $SETTING_KEY_RE ]] || continue
        if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        [ -n "${!key+set}" ] && continue
        printf -v "$key" '%s' "$value"
    done < "$DBTOOLS_ENV_FILE"
}

# require_profile — every call names its target. There is no default connection.
require_profile() {
    [ -n "$PROFILE" ] || usage_error "--profile NAME is required: it selects the NAME_* settings, and there is no default"
    [[ "$PROFILE" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || usage_error "--profile must be a plain name (letters, digits, _), not '$PROFILE'"
}

# setting SUFFIX — the value of ${PROFILE}_SUFFIX, empty when it is not set.
setting() {
    local name="${PROFILE}_$1"
    printf '%s' "${!name:-}"
}

# require_setting SUFFIX — the value of ${PROFILE}_SUFFIX. Call it as `X=$(require_setting S) || exit 2`:
# the error is reported here, but the exit only ends the command substitution.
require_setting() {
    local value
    value=$(setting "$1")
    [ -n "$value" ] || usage_error "${PROFILE}_$1 is not set, neither in the environment nor in $DBTOOLS_ENV_FILE"
    printf '%s' "$value"
}

now_ms() {
    python3 -I -c 'import time; print(int(time.time() * 1000))'
}

# unmasked — true only when --unmask was given and the user allowed it in their own shell.
unmasked() {
    [ "$UNMASK" = 1 ] && [ "${DB_TOOLS_ALLOW_UNMASK:-0}" = 1 ]
}

# reveal TEXT — the text as the agent may see it: credentials in URLs always redacted, personal data masked
# unless unmasked.
reveal() {
    if unmasked; then
        printf '%s\n' "$1" | redact_secrets
    else
        printf '%s\n' "$1" | mask_pii
    fi
}

# emit OUT ERR — print a client's output and diagnostics through reveal; empty parts print nothing.
emit() {
    [ -n "$1" ] && reveal "$1"
    [ -n "$2" ] && reveal "$2" >&2
    return 0
}

# run_captured FUNCTION — run a client wrapped in a function (so secrets travel as per-command environment,
# never as arguments), keeping stdout and stderr apart. Sets CLIENT_OUT, CLIENT_ERR, CLIENT_STATUS, CLIENT_MS.
# shellcheck disable=SC2034 # CLIENT_* are this function's results, read by the calling script
run_captured() {
    local err_file start
    err_file=$(mktemp "${TMPDIR:-/tmp}/db-tools.XXXXXX") || usage_error "cannot create a temporary file"
    start=$(now_ms)
    CLIENT_OUT=$("$1" 2>"$err_file")
    CLIENT_STATUS=$?
    CLIENT_MS=$(( $(now_ms) - start ))
    CLIENT_ERR=$(cat "$err_file")
    rm -f "$err_file"
}

# first_error TEXT — the first line of a client's diagnostics, masked, for the audit line.
first_error() {
    printf '%s\n' "$1" | sed -n '/[^[:space:]]/{p;q;}' | mask_pii
}

# audit OUTCOME REASON EXTRA — append one audit line: the store, profile, outcome (ok, refused, failed),
# the reason when there is one, whether output was unmasked, and the wrapper's own fields (a JSON object).
audit() {
    local was_unmasked=false extra="${3:-}"
    unmasked && was_unmasked=true
    [ -n "$extra" ] || extra='{}'
    log_query "$(jq -cn --arg db "$DB_KIND" --arg profile "$PROFILE" --arg outcome "$1" --arg reason "$2" \
        --argjson unmasked "$was_unmasked" --argjson extra "$extra" \
        '{db: $db, profile: $profile, outcome: $outcome}
         + (if $reason == "" then {} else {reason: $reason} end)
         + {unmasked: $unmasked} + $extra')"
}

# refuse REASON [EXTRA] — record a refusal and stop before anything reaches the store.
refuse() {
    audit refused "$1" "${2:-}"
    echo "db-tools: refused: $1" >&2
    exit "$EXIT_REFUSED"
}

# json_strings ITEM... — the items as a JSON array of strings.
json_strings() {
    if [ $# -eq 0 ]; then
        echo '[]'
    else
        printf '%s\n' "$@" | jq -R . | jq -cs .
    fi
}

# read_query — the query from -q, or from stdin when -q was not given and stdin is not a terminal.
read_query() {
    if [ -z "$QUERY" ]; then
        [ -t 0 ] && usage_error "give the query with -q or on stdin"
        QUERY=$(cat)
    fi
    [[ "$QUERY" =~ [^[:space:]] ]] || usage_error "the query is empty"
}
