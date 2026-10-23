#!/usr/bin/env bash
# log.sh — the audit log: one JSON line per call, accepted, refused or failed. Results are never logged.

: "${DBTOOLS_LOG_FILE:=${XDG_STATE_HOME:-$HOME/.local/state}/db-tools/queries.jsonl}"

# log_ready — make sure the log can be written before anything runs: a query that cannot be audited does
# not run. The directory is created private and the file is kept at mode 600.
log_ready() {
    (umask 077 && mkdir -p "$(dirname "$DBTOOLS_LOG_FILE")" && touch "$DBTOOLS_LOG_FILE") 2>/dev/null \
        && [ -w "$DBTOOLS_LOG_FILE" ] \
        && chmod 600 "$DBTOOLS_LOG_FILE"
}

# log_query JSON — append the object with a UTC timestamp first.
log_query() {
    jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{ts: $ts} + .' <<< "$1" >> "$DBTOOLS_LOG_FILE"
}
