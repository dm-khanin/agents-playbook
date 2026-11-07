#!/usr/bin/env bash
# Heroku helpers for the roll-out-a-library-release skill. Source this file in the same shell call that uses a
# helper; each agent shell call starts a new shell, so functions do not carry over:
#   . ~/.claude/skills/roll-out-a-library-release/scripts/heroku-lib.sh
#
# Why a separate file: Claude Code replaces a dollar sign followed by a digit anywhere in SKILL.md with an
# invocation argument, so a helper written there loads with its positional parameters already replaced.
#
# Valid in bash 3.2 (the macOS default) and in zsh: no bash-4 syntax, no `local path` or `local status`,
# which are special in zsh. Python programs are single-quoted and read their inputs from the environment, so a
# quote inside one can never end the shell string early.
#
# Tunables: ROLLOUT_TIMEOUT (seconds, default 180) and ROLLOUT_POLL (seconds between polls, default 5).

# usage: heroku_deploy_branch <app> <branch>
# Starts the GitHub branch deploy that the dashboard's "Deploy Branch" button starts, by POSTing
# {"branch":"<branch>"} with your CLI token to HEROKU_BRANCH_DEPLOY_URL, in which {app_id} is replaced by the
# app's id. Take that URL from the request the button sends (the browser's network tab). Prints the response and
# returns 1 on any non-2xx answer: curl -sS exits 0 on 401 and 5xx, so an expired token would otherwise look like
# a started deploy. Returns 2 when HEROKU_BRANCH_DEPLOY_URL is not set.
heroku_deploy_branch() {
  local app="$1" branch="$2"
  local token app_id endpoint resp code body
  case "${HEROKU_BRANCH_DEPLOY_URL:-}" in
    https://*'{app_id}'*) ;;
    *) echo "heroku_deploy_branch: set HEROKU_BRANCH_DEPLOY_URL to the button's endpoint, with {app_id} in it" >&2
       return 2 ;;
  esac
  token=$(heroku auth:token) || { echo "$app: heroku auth:token failed" >&2; return 1; }
  app_id=$(heroku apps:info -a "$app" --json \
    | python3 -c 'import sys, json; print(json.load(sys.stdin)["app"]["id"])') \
    || { echo "$app: cannot read the app id" >&2; return 1; }
  endpoint=$(printf '%s' "$HEROKU_BRANCH_DEPLOY_URL" | sed "s/{app_id}/$app_id/")
  resp=$(curl -sS -w '\n%{http_code}' -X POST "$endpoint" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d "{\"branch\":\"$branch\"}")
  code=$(printf '%s' "$resp" | tail -n1)
  body=$(printf '%s' "$resp" | sed '$d')
  case "$code" in
    2??) printf '%s\n' "$body" ;;
    *) echo "$app: branch deploy failed: HTTP ${code:-none}: $body" >&2; return 1 ;;
  esac
}

# usage: wait_dyno_up <app> <since>
#   <since>: the UTC second taken before the scale-up, exactly `date -u +%Y-%m-%dT%H:%M:%S`.
# After a web scale-up from 0, waits for Heroku's own `State changed from starting to up` line for a web dyno,
# stamped at or after <since>. `heroku ps` alone is not enough: it can show `up` seconds before the process
# starts. Only web.N lines count, so a one-off (run.N) or release dyno starting at the same time cannot satisfy
# the wait. The time filter is a string comparison, which is chronological because `heroku logs` stamps in UTC.
# Returns 0 when the line is seen, 1 at the deadline, 2 on a malformed or future <since>. It never exits the
# shell, so a caller's formation restore after it always runs.
wait_dyno_up() {
  local app="$1" since="$2"
  local timeout="${ROLLOUT_TIMEOUT:-180}" poll="${ROLLOUT_POLL:-5}"
  case "$since" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
    *)
      echo "wait_dyno_up: <since> must be \`date -u +%Y-%m-%dT%H:%M:%S\` taken before the scale, got '$since'" >&2
      return 2 ;;
  esac
  if [[ "$since" > "$(date -u +%Y-%m-%dT%H:%M:%S)" ]]; then
    echo "wait_dyno_up: <since> $since is in the future; take it with date -u (UTC), not local time" >&2
    return 2
  fi
  local deadline=$(( $(date +%s) + timeout ))
  local line
  while :; do
    line=$(heroku logs -a "$app" -n 300 2>/dev/null \
      | awk -v t0="$since" '$1 >= t0' \
      | grep -m1 -E 'heroku\[web\.[0-9]+\].*State changed from starting to up')
    if [[ -n "$line" ]]; then
      echo "$app: web dyno up: $line"
      return 0
    fi
    (( $(date +%s) < deadline )) || break
    sleep "$poll"
  done
  echo "$app: no web dyno logged 'State changed from starting to up' since $since within ${timeout}s" >&2
  heroku ps -a "$app" 2>&1 | head -10 >&2
  return 1
}

# usage: deploy_health_check <app> <url> <deployed-sha>
# Finds the release whose description carries <deployed-sha> and every release built from the same slug, waits
# until every web dyno is up on one of them, then retries <url> until it answers 1xx-4xx.
# Slug, not "release >= target": a config change makes a new release on the same slug, which must pass, while
# someone else's newer deploy has a different slug and must not. Every dyno, not any: during a preboot cutover
# old dynos are still listed and can still answer.
deploy_health_check() {
  local app="$1" url="$2" deployed_sha="$3"
  if [[ -z "$deployed_sha" ]]; then
    echo "deploy_health_check: pass the deployed commit sha" >&2
    return 2
  fi
  local timeout="${ROLLOUT_TIMEOUT:-180}" poll="${ROLLOUT_POLL:-5}"
  local deadline=$(( $(date +%s) + timeout ))

  local found target ok_versions
  found=$(heroku releases -a "$app" -n 25 --json 2>/dev/null | ROLLOUT_SHA="$deployed_sha" python3 -c '
import json, os, sys
sha = os.environ["ROLLOUT_SHA"][:7]
try:
    rels = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
hit = next((r for r in rels if sha in (r.get("description") or "")), None)
if hit is None:
    sys.exit(0)
slug = (hit.get("slug") or {}).get("id")
if slug:
    same = [str(r["version"]) for r in rels if (r.get("slug") or {}).get("id") == slug]
else:
    same = [str(hit["version"])]
print(hit["version"], ",".join(same))
')
  target=${found%% *}
  ok_versions=${found#* }
  if [[ -z "$found" ]]; then
    echo "$app: no release carries $deployed_sha; the deploy never landed here" >&2
    heroku releases -a "$app" -n 5 2>&1 | head -8 >&2
    return 1
  fi
  echo "$app: release v$target carries $deployed_sha (same slug in v$ok_versions); waiting for web dynos"

  local dynos_ready=0
  while :; do
    if heroku ps -a "$app" --json 2>/dev/null | ROLLOUT_OK_VERSIONS="$ok_versions" python3 -c '
import json, os, sys
ok = {int(v) for v in os.environ["ROLLOUT_OK_VERSIONS"].split(",") if v}
try:
    dynos = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
webs = [d for d in dynos if d.get("type") == "web"]
ready = bool(webs) and all(
    d.get("state") == "up" and (d.get("release") or {}).get("version") in ok
    for d in webs
)
sys.exit(0 if ready else 1)
'; then
      dynos_ready=1
      break
    fi
    (( $(date +%s) < deadline )) || break
    sleep "$poll"
  done
  if (( dynos_ready == 0 )); then
    echo "$app: web dynos did not all reach 'up' on the slug of v$target within ${timeout}s" >&2
    heroku ps -a "$app" 2>&1 | head -10 >&2
    return 1
  fi

  local code=""
  while :; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null)
    case "$code" in
      1??|2??|3??|4??) echo "$app: alive on v$target (HTTP $code)"; return 0 ;;
    esac
    (( $(date +%s) < deadline )) || break
    sleep "$poll"
  done
  echo "$app: dynos are up on v$target but $url never answered 1xx-4xx within ${timeout}s (last: '${code:-none}')" >&2
  return 1
}
