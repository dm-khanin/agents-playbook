#!/usr/bin/env bash
# es-query.sh — send one read request to Elasticsearch for an agent: masked, audited.
#
# Only read APIs are reachable: _search (and its sub-APIs), _count, _msearch, _mapping, _field_caps and _cat.
# Every path segment must be a plain name and curl sends the path as given (--path-as-is), because curl
# would otherwise collapse "_search/../_doc/1" into a write API. The URL and the credentials reach curl
# through a config on a pipe, never on its command line. A request with a body is a POST, otherwise a GET.
set -uo pipefail

readonly USAGE='usage: es-query.sh --profile NAME [-i INDEX] [--endpoint PATH] [-q JSON] [--size N] [--unmask]
  -i INDEX         index, alias or pattern; a comma-separated list is fine
  --endpoint PATH  _search (default), _count, _msearch, _mapping, _field_caps, _search/..., _cat or _cat/...
  -q JSON          the request body
  --size N         hits to return, 0..10000
  The profile needs NAME_ES_URL (which may embed user:password) or NAME_ES_CLOUD_ID, and NAME_ES_API_KEY or
  NAME_ES_CREDENTIAL. A credential is tried as an API key, then as user:password, unless NAME_ES_AUTH is
  apikey or basic.'

DBTOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DBTOOLS_DIR DB_KIND=elastic
# shellcheck source=../lib/common.sh
source "$DBTOOLS_DIR/lib/common.sh"
# shellcheck source=../lib/safety.sh
source "$DBTOOLS_DIR/lib/safety.sh"

INDEX="" BODY="" ENDPOINT=_search SIZE="" PROFILE="" UNMASK=0
while [ $# -gt 0 ]; do
    case "$1" in
        -i | --index) take "$@"; INDEX="$2"; shift 2 ;;
        -q | --query) take "$@"; BODY="$2"; shift 2 ;;
        --endpoint) take "$@"; ENDPOINT="$2"; shift 2 ;;
        --size) take "$@"; SIZE="$2"; shift 2 ;;
        --profile) take "$@"; PROFILE="$2"; shift 2 ;;
        --unmask) UNMASK=1; shift ;;
        -h | --help) echo "$USAGE"; exit 0 ;;
        *) usage_error "unknown argument: $1"$'\n'"$USAGE" ;;
    esac
done

require_profile
log_ready || usage_error "cannot write the audit log $DBTOOLS_LOG_FILE"
load_config

MASKED_BODY=$(printf '%s' "$BODY" | mask_pii)
REQUEST=$(jq -cn --arg i "$INDEX" --arg e "$ENDPOINT" --arg b "$MASKED_BODY" '{index: $i, endpoint: $e, query: $b}')

REASON=$(es_endpoint_reject_reason "$ENDPOINT") || refuse "$REASON" "$REQUEST"
if [ -n "$INDEX" ]; then
    REASON=$(es_index_reject_reason "$INDEX") || refuse "$REASON" "$REQUEST"
fi
if [ -n "$SIZE" ]; then
    REASON=$(check_count --size "$SIZE" 0 10000) || refuse "$REASON" "$(jq -c --arg s "$SIZE" '. + {given: {size: $s}}' <<< "$REQUEST")"
    SIZE=$((10#$SIZE))
fi

# --- where to send it ---
BASE_URL=$(setting ES_URL)
CLOUD_ID=$(setting ES_CLOUD_ID)
if [ -z "$BASE_URL" ] && [ -n "$CLOUD_ID" ]; then
    # A cloud ID is "name:base64(host$es-uuid$kibana-uuid)".
    BASE_URL=$(printf '%s' "$CLOUD_ID" | python3 -I -c '
import base64, sys
encoded = sys.stdin.read().strip().split(":", 1)[-1]
host, uuid = (base64.b64decode(encoded + "=" * (-len(encoded) % 4)).decode().split("$") + [""])[:2]
print(f"https://{uuid}.{host}" if uuid else f"https://{host}")
' 2>/dev/null) || usage_error "${PROFILE}_ES_CLOUD_ID is not a valid cloud ID"
fi
[ -n "$BASE_URL" ] || usage_error "set ${PROFILE}_ES_URL or ${PROFILE}_ES_CLOUD_ID"

URL="${BASE_URL%/}${INDEX:+/$INDEX}/$ENDPOINT"
QUERY_STRING=()
[ -n "$SIZE" ] && QUERY_STRING+=("size=$SIZE")
case "$ENDPOINT" in _cat | _cat/*) QUERY_STRING+=("format=json") ;; esac
[ ${#QUERY_STRING[@]} -gt 0 ] && URL="$URL?$(IFS='&'; echo "${QUERY_STRING[*]}")"

# --- how to authenticate: a list of "scheme:value" attempts ---
ATTEMPTS=()
API_KEY=$(setting ES_API_KEY)
CREDENTIAL=$(setting ES_CREDENTIAL)
if [ -n "$API_KEY" ]; then
    ATTEMPTS=("apikey:$API_KEY")
elif [ -n "$CREDENTIAL" ]; then
    case "$(setting ES_AUTH)" in
        apikey) ATTEMPTS=("apikey:$CREDENTIAL") ;;
        basic) ATTEMPTS=("basic:$CREDENTIAL") ;;
        '') ATTEMPTS=("apikey:$CREDENTIAL" "basic:$CREDENTIAL") ;;
        *) usage_error "${PROFILE}_ES_AUTH must be apikey or basic" ;;
    esac
else
    usage_error "set ${PROFILE}_ES_API_KEY or ${PROFILE}_ES_CREDENTIAL"
fi

# A line break in a setting would start a new curl config line, that is, a new curl option.
case "$BASE_URL$API_KEY$CREDENTIAL" in
    *$'\n'* | *$'\r'*) usage_error "the ${PROFILE}_ES_* settings must not contain line breaks" ;;
esac

# curl_quote VALUE — the value as a double-quoted curl config string.
# shellcheck disable=SC2329 # used by curl_config
curl_quote() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

# curl_config SCHEME VALUE — the URL and the credentials as curl config lines.
# shellcheck disable=SC2329 # read by curl through run_curl
curl_config() {
    local value="$2"
    printf 'url = %s\n' "$(curl_quote "$URL")"
    case "$1" in
        # An API key header carries base64(id:key); a value that still has its colon is encoded here.
        apikey)
            [[ "$value" == *:* ]] && value=$(printf '%s' "$value" | base64 | tr -d '\n')
            printf 'header = %s\n' "$(curl_quote "Authorization: ApiKey $value")"
            ;;
        basic) printf 'user = %s\n' "$(curl_quote "$value")" ;;
    esac
}

if [ -n "$BODY" ]; then
    METHOD=POST
    case "$ENDPOINT" in _msearch) CONTENT_TYPE=application/x-ndjson ;; *) CONTENT_TYPE=application/json ;; esac
else
    METHOD=GET
fi

SCHEME="" VALUE=""
# shellcheck disable=SC2329 # run by run_captured
run_curl() {
    if [ "$METHOD" = POST ]; then
        curl -sS --path-as-is -X POST -K <(curl_config "$SCHEME" "$VALUE") -H "Content-Type: $CONTENT_TYPE" \
            --data-binary @- -w $'\n%{http_code}' <<< "$BODY"
    else
        curl -sS --path-as-is -X GET -K <(curl_config "$SCHEME" "$VALUE") -w $'\n%{http_code}'
    fi
}

for attempt in "${ATTEMPTS[@]}"; do
    SCHEME="${attempt%%:*}"
    VALUE="${attempt#*:}"
    run_captured run_curl
    HTTP_CODE="${CLIENT_OUT##*$'\n'}"
    case "$HTTP_CODE" in 401 | 403) continue ;; *) break ;; esac
done
RESPONSE="${CLIENT_OUT%$'\n'*}"
[ "$RESPONSE" = "$CLIENT_OUT" ] && RESPONSE=""
PRETTY=$(jq . <<< "$RESPONSE" 2>/dev/null) && RESPONSE="$PRETTY"

emit "$RESPONSE" "$CLIENT_ERR"
FIELDS=$(jq -c --arg m "$METHOD" --arg code "$HTTP_CODE" --arg auth "$SCHEME" --argjson ms "$CLIENT_MS" \
    '. + {method: $m, http_code: $code, auth: $auth, duration_ms: $ms}' <<< "$REQUEST")
case "$HTTP_CODE" in
    2??)
        audit ok "" "$FIELDS"
        exit 0
        ;;
esac
echo "db-tools: HTTP ${HTTP_CODE:-none} (auth $SCHEME)" >&2
audit failed "HTTP ${HTTP_CODE:-none}${CLIENT_ERR:+: $(first_error "$CLIENT_ERR")}" "$FIELDS"
exit "$EXIT_FAILED"
