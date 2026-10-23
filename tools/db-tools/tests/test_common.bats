#!/usr/bin/env bats
# Configuration, profiles and output rules shared by every wrapper (lib/common.sh, lib/log.sh).

load helpers

setup() { common_setup; }
teardown() { common_teardown; }

# in_common SCRIPT — run SCRIPT in bash with lib/common.sh loaded, as a wrapper would have it.
in_common() {
    run bash -c "DBTOOLS_DIR='$TOOL_DIR' DB_KIND=test PROFILE=\${PROFILE:-} UNMASK=\${UNMASK:-0}; source '$TOOL_DIR/lib/common.sh'; $1"
}

@test "config: values are taken literally, so & and \$ in a password survive" {
    config 'P_PG_URI=postgres://u:a&b$c@h/db'
    in_common 'load_config; printf %s "$P_PG_URI"'
    [ "$status" -eq 0 ]
    [ "$output" = 'postgres://u:a&b$c@h/db' ]
}

@test "config: one pair of surrounding quotes is removed" {
    config 'P_PG_URI="postgres://h/db?a=1&b=2"' "Q_PG_URI='postgres://h/q'"
    in_common 'load_config; printf "%s|%s" "$P_PG_URI" "$Q_PG_URI"'
    [ "$output" = 'postgres://h/db?a=1&b=2|postgres://h/q' ]
}

@test "config: the environment wins over the file" {
    config 'P_PG_URI=postgres://from-file/db'
    P_PG_URI=postgres://from-env/db in_common 'load_config; printf %s "$P_PG_URI"'
    [ "$output" = 'postgres://from-env/db' ]
}

@test "config: values are not exported, so a client sees no other profile's secret" {
    config 'OTHER_PG_URI=postgres://u:pw-7f3a91@h/db'
    in_common 'load_config; [ -n "$OTHER_PG_URI" ] && env'
    [ "$status" -eq 0 ]
    [[ "$output" != *pw-7f3a91* ]] || false
}

@test "config: only profile settings are read, so a line cannot overwrite a wrapper variable" {
    config 'LIMIT=7' 'PATH=/nowhere' 'P_UNKNOWN_SETTING=x' 'P_REDIS_URI=redis://h'
    in_common 'LIMIT=100; load_config; printf "%s|%s|%s|%s" "$LIMIT" "${PATH%%:*}" "${P_UNKNOWN_SETTING:-unset}" "$P_REDIS_URI"'
    [ "$output" = "100|$DBTESTDIR/bin|unset|redis://h" ]
}

@test "config: comments, blank lines and a missing file are fine" {
    config '# a comment' '' '  P_MONGO_URI=mongodb://h/db'
    in_common 'load_config; printf %s "$P_MONGO_URI"'
    [ "$output" = 'mongodb://h/db' ]
    rm "$DBTOOLS_ENV_FILE"
    in_common 'load_config; echo ok'
    [ "$output" = ok ]
}

@test "profile: it is required, and there is no default" {
    in_common 'require_profile'
    [ "$status" -eq 2 ]
    [[ "$output" =~ "--profile NAME is required" ]] || false
}

@test "profile: it must be a plain name" {
    for name in 'a-b' '1abc' 'x[$(id)]' 'a b' '_x'; do
        PROFILE="$name" in_common 'require_profile'
        [ "$status" -eq 2 ]
        [[ "$output" =~ "plain name" ]] || false
    done
}

@test "profile: settings resolve under its name, and a missing one is a configuration error" {
    config 'DEV_PG_URI=postgres://dev/db'
    PROFILE=DEV in_common 'load_config; require_setting PG_URI'
    [ "$status" -eq 0 ]
    [ "$output" = 'postgres://dev/db' ]
    PROFILE=DEV in_common 'load_config; require_setting MONGO_URI'
    [ "$status" -eq 2 ]
    [[ "$output" =~ "DEV_MONGO_URI is not set" ]] || false
}

@test "a flag without its value is a usage error" {
    run "$SCRIPTS/pg-query.sh" --profile
    [ "$status" -eq 2 ]
    [[ "$output" =~ "--profile needs a value" ]] || false
}

@test "output: personal data is masked by default" {
    in_common 'reveal "mail alice@example.com"'
    [ "$output" = "mail al**@example.com" ]
}

@test "output: --unmask alone does not unmask" {
    UNMASK=1 in_common 'reveal "mail alice@example.com"'
    [ "$output" = "mail al**@example.com" ]
}

@test "output: --unmask with DB_TOOLS_ALLOW_UNMASK=1 unmasks, but a URL password stays redacted" {
    DB_TOOLS_ALLOW_UNMASK=1 UNMASK=1 in_common 'reveal "alice@example.com postgres://u:hunter2@h/db"'
    [ "$output" = "alice@example.com postgres://u:***@h/db" ]
}

@test "audit: the log is created private, before anything runs" {
    in_common 'log_ready'
    [ "$status" -eq 0 ]
    [ "$(mode_of "$DBTOOLS_LOG_FILE")" = 600 ]
    [ "$(mode_of "$(dirname "$DBTOOLS_LOG_FILE")")" = 700 ]
}

@test "audit: a looser existing log is tightened to 600" {
    mkdir -p "$(dirname "$DBTOOLS_LOG_FILE")"
    : > "$DBTOOLS_LOG_FILE"
    chmod 644 "$DBTOOLS_LOG_FILE"
    in_common 'log_ready'
    [ "$(mode_of "$DBTOOLS_LOG_FILE")" = 600 ]
}

@test "audit: a wrapper does not run when the log cannot be written" {
    fake_client psql
    config 'P_PG_URI=postgresql://h/db'
    DBTOOLS_LOG_FILE=/dev/null/queries.jsonl run "$SCRIPTS/pg-query.sh" --profile P -q "SELECT 1"
    [ "$status" -eq 2 ]
    [[ "$output" =~ "cannot write the audit log" ]] || false
    not_called psql
}

@test "audit: one line per call, a timestamp first, appended" {
    in_common 'log_ready && audit ok "" "{\"rows\": 1}" && audit refused "why" ""'
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$DBTOOLS_LOG_FILE")" -eq 2 ]
    head -n 1 "$DBTOOLS_LOG_FILE" | jq -e 'keys_unsorted[0] == "ts" and .outcome == "ok" and .rows == 1 and (has("reason") | not)'
    last_audit '.outcome == "refused" and .reason == "why" and .db == "test"'
}
