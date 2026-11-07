#!/usr/bin/env bats
# scripts/heroku-lib.sh against stand-ins for heroku and curl placed first on PATH.
#
# Every assertion that is not a test's last command ends in `|| false`: bash 3.2 does not fail a test on a false
# [[ ]] in the middle.

LIB="$BATS_TEST_DIRNAME/../scripts/heroku-lib.sh"

setup() {
    T="$(mktemp -d)"
    export T
    mkdir -p "$T/bin"
    export PATH="$T/bin:$PATH"
    export ROLLOUT_TIMEOUT=1 ROLLOUT_POLL=0
    export HEROKU_BRANCH_DEPLOY_URL='https://deploy.example.test/apps/{app_id}/branch'

    # heroku stand-in: answers from files in $T, records every call.
    cat > "$T/bin/heroku" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$T/heroku.calls"
case "$1" in
  auth:token) echo tok-123 ;;
  apps:info) echo '{"app":{"id":"app-id-1"}}' ;;
  releases) if [[ " $* " == *" --json "* ]]; then cat "$T/releases.json"; else echo "v1 text"; fi ;;
  ps) if [[ " $* " == *" --json "* ]]; then cat "$T/ps.json"; else echo "ps text"; fi ;;
  logs) cat "$T/logs.txt" 2>/dev/null ;;
esac
EOF
    # curl stand-in: records its arguments; prints the next line of $T/curl.codes (the last one repeats) as
    # the status, after $T/curl.body when a -w format with a newline asks for a body.
    cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T/curl.calls"
n=$(cat "$T/curl.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$T/curl.n"
total=$(wc -l < "$T/curl.codes")
[ "$n" -le "$total" ] || n=$total
code=$(sed -n "${n}p" "$T/curl.codes")
case "$*" in
  *'\n%{http_code}'*) cat "$T/curl.body" 2>/dev/null; printf '\n%s' "$code" ;;
  *) printf '%s' "$code" ;;
esac
EOF
    chmod +x "$T/bin/heroku" "$T/bin/curl"
}

teardown() { rm -rf "$T"; }

codes() { printf '%s\n' "$@" > "$T/curl.codes"; }

# Three releases: v10 deploys abc1234 on slug S1, v11 is a config change on S1, v12 is someone else's deploy
# on slug S2.
releases_with_foreign_deploy() {
    cat > "$T/releases.json" <<'EOF'
[{"version":12,"description":"Deploy fff9999","slug":{"id":"S2"}},
 {"version":11,"description":"Set FOO config vars","slug":{"id":"S1"}},
 {"version":10,"description":"Deploy abc1234","slug":{"id":"S1"}}]
EOF
}

ps_json() { printf '%s\n' "$1" > "$T/ps.json"; }

# --- heroku_deploy_branch ---------------------------------------------------------------------------

@test "deploy_branch: a 2xx answer prints the body and posts the branch to the app's push endpoint" {
    codes 201
    echo '{"build":{"id":"b1","status":"pending"}}' > "$T/curl.body"
    run bash -c ". '$LIB'; heroku_deploy_branch my-app main"
    [ "$status" -eq 0 ] || false
    [[ "$output" == *'"status":"pending"'* ]] || false
    grep -q 'https://deploy.example.test/apps/app-id-1/branch' "$T/curl.calls" || false
    grep -q '"branch":"main"' "$T/curl.calls" || false
    grep -q 'Bearer tok-123' "$T/curl.calls"
}

@test "deploy_branch: a 401 answer fails and names the status, although curl itself exits 0" {
    codes 401
    echo '{"id":"unauthorized"}' > "$T/curl.body"
    run bash -c ". '$LIB'; heroku_deploy_branch my-app main"
    [ "$status" -eq 1 ] || false
    [[ "$output" == *"HTTP 401"* ]]
}

@test "deploy_branch: without an endpoint nothing is called" {
    run bash -c "unset HEROKU_BRANCH_DEPLOY_URL; . '$LIB'; heroku_deploy_branch my-app main"
    [ "$status" -eq 2 ] || false
    [ ! -e "$T/heroku.calls" ] || false
    [ ! -e "$T/curl.calls" ]
}

@test "deploy_branch: a 500 answer fails" {
    codes 500
    run bash -c ". '$LIB'; heroku_deploy_branch my-app main"
    [ "$status" -eq 1 ]
}

# --- deploy_health_check --------------------------------------------------------------------------------

@test "health: an empty sha is refused before any call" {
    run bash -c ". '$LIB'; deploy_health_check my-app https://x.test/ ''"
    [ "$status" -eq 2 ] || false
    [ ! -e "$T/heroku.calls" ]
}

@test "health: no release carries the sha, so the deploy never landed" {
    releases_with_foreign_deploy
    run bash -c ". '$LIB'; deploy_health_check my-app https://x.test/ 0000000"
    [ "$status" -eq 1 ] || false
    [[ "$output" == *"never landed"* ]]
}

@test "health: dynos on a config release of the same slug pass, and a 404 counts as alive" {
    releases_with_foreign_deploy
    ps_json '[{"type":"web","state":"up","release":{"version":11}},{"type":"worker","state":"crashed","release":{"version":9}}]'
    codes 404
    run bash -c ". '$LIB'; deploy_health_check my-app https://x.test/ abc1234def"
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"alive on v10 (HTTP 404)"* ]]
}

@test "health: dynos on someone else's newer deploy fail, although its release number is higher" {
    releases_with_foreign_deploy
    ps_json '[{"type":"web","state":"up","release":{"version":12}}]'
    codes 200
    run bash -c ". '$LIB'; deploy_health_check my-app https://x.test/ abc1234"
    [ "$status" -eq 1 ] || false
    [[ "$output" == *"did not all reach 'up'"* ]]
}

@test "health: one old dyno still listed during preboot keeps the gate closed" {
    releases_with_foreign_deploy
    ps_json '[{"type":"web","state":"up","release":{"version":10}},{"type":"web","state":"up","release":{"version":9}}]'
    codes 200
    run bash -c ". '$LIB'; deploy_health_check my-app https://x.test/ abc1234"
    [ "$status" -eq 1 ]
}

@test "health: a web dyno of our slug that is still starting does not pass" {
    releases_with_foreign_deploy
    ps_json '[{"type":"web","state":"starting","release":{"version":10}}]'
    codes 200
    run bash -c ". '$LIB'; deploy_health_check my-app https://x.test/ abc1234"
    [ "$status" -eq 1 ]
}

@test "health: no web dynos at all does not pass" {
    releases_with_foreign_deploy
    ps_json '[]'
    codes 200
    run bash -c ". '$LIB'; deploy_health_check my-app https://x.test/ abc1234"
    [ "$status" -eq 1 ]
}

@test "health: the URL is retried until the process listens" {
    releases_with_foreign_deploy
    ps_json '[{"type":"web","state":"up","release":{"version":10}}]'
    codes 000 000 200
    run bash -c ". '$LIB'; ROLLOUT_TIMEOUT=30 deploy_health_check my-app https://x.test/ abc1234"
    [ "$status" -eq 0 ] || false
    [ "$(wc -l < "$T/curl.calls")" -eq 3 ]
}

@test "health: a 5xx until the deadline fails and reports the last code" {
    releases_with_foreign_deploy
    ps_json '[{"type":"web","state":"up","release":{"version":10}}]'
    codes 503
    run bash -c ". '$LIB'; deploy_health_check my-app https://x.test/ abc1234"
    [ "$status" -eq 1 ] || false
    [[ "$output" == *"last: '503'"* ]]
}

@test "health: a sha containing quotes is data, not code" {
    releases_with_foreign_deploy
    run bash -c ". '$LIB'; deploy_health_check my-app https://x.test/ \"ab'\\\"c\""
    [ "$status" -eq 1 ] || false
    [[ "$output" == *"never landed"* ]]
}

# --- wait_dyno_up -----------------------------------------------------------------------------------------

@test "wait: a malformed time is refused" {
    run bash -c ". '$LIB'; wait_dyno_up my-app '12:00'"
    [ "$status" -eq 2 ]
}

@test "wait: a time in the future is refused" {
    run bash -c ". '$LIB'; wait_dyno_up my-app 2999-01-01T00:00:00"
    [ "$status" -eq 2 ]
}

@test "wait: only a web dyno's up line at or after the start time counts" {
    cat > "$T/logs.txt" <<'EOF'
2026-01-01T09:59:59.000000+00:00 heroku[web.1]: State changed from starting to up
2026-01-01T10:00:01.000000+00:00 heroku[run.1234]: State changed from starting to up
2026-01-01T10:00:02.000000+00:00 heroku[web.1]: State changed from starting to up
EOF
    run bash -c ". '$LIB'; wait_dyno_up my-app 2026-01-01T10:00:00"
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"10:00:02"* ]]
}

@test "wait: an older web line and a one-off dyno's line are not enough" {
    cat > "$T/logs.txt" <<'EOF'
2026-01-01T09:59:59.000000+00:00 heroku[web.1]: State changed from starting to up
2026-01-01T10:00:01.000000+00:00 heroku[run.1234]: State changed from starting to up
EOF
    run bash -c ". '$LIB'; wait_dyno_up my-app 2026-01-01T10:00:00"
    [ "$status" -eq 1 ]
}
