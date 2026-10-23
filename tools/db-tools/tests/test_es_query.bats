#!/usr/bin/env bats
# es-query.sh against a fake curl, which records its arguments and the config it read from -K.

load helpers

setup() {
    common_setup
    fake_client curl
    answer curl $'{"hits":{"hits":[{"_source":{"email":"alice@example.com"}}]}}\n200'
    config 'P_ES_URL=https://search.example.com:9243' 'P_ES_API_KEY=key-id:key-secret-6a1f'
}
teardown() { common_teardown; }

es() {
    run "$SCRIPTS/es-query.sh" --profile P "$@"
}

@test "a search is a POST with the body on stdin, and the path is sent as checked" {
    es -i products -q '{"query":{"match_all":{}}}' --size 5
    [ "$status" -eq 0 ]
    recorded curl '.argv | index("--path-as-is") != null and (.[index("-X") + 1] == "POST")'
    recorded curl '.stdin == "{\"query\":{\"match_all\":{}}}\n"'
    recorded curl '.config | contains("url = \"https://search.example.com:9243/products/_search?size=5\"")'
    recorded curl '.argv | index("Content-Type: application/json") != null'
}

@test "the URL and the API key reach curl in its config, never in its arguments" {
    es -i products
    expected_key=$(printf '%s' 'key-id:key-secret-6a1f' | base64 | tr -d '\n')
    jq -e --arg k "$expected_key" '.config | contains("Authorization: ApiKey " + $k)' "$DBTESTDIR/curl.json"
    recorded curl '[.argv[] | contains("key-secret-6a1f") or contains("search.example.com")] | any | not'
}

@test "a credential in the URL stays out of the arguments too" {
    : > "$DBTOOLS_ENV_FILE"
    config 'P_ES_URL=https://reader:pw-0d4c@example.com' 'P_ES_CREDENTIAL=reader:pw-0d4c' 'P_ES_AUTH=basic'
    es --endpoint _cat/indices
    [ "$status" -eq 0 ]
    recorded curl '.config | contains("user = \"reader:pw-0d4c\"") and contains("url = \"https://reader:pw-0d4c@example.com/_cat/indices?format=json\"")'
    recorded curl '[.argv[] | contains("pw-0d4c")] | any | not'
}

@test "a request without a body is a GET" {
    es --endpoint _mapping -i products
    recorded curl '.argv[.argv | index("-X") + 1] == "GET" and (has("stdin") | not)'
}

@test "_msearch is sent as NDJSON" {
    es --endpoint _msearch -q $'{}\n{"query":{"match_all":{}}}'
    recorded curl '.argv | index("Content-Type: application/x-ndjson") != null'
}

@test "a cloud ID gives the endpoint" {
    : > "$DBTOOLS_ENV_FILE"
    cloud_id="deploy:$(printf '%s' 'eu-west-1.aws.example.io$abc123$def456' | base64 | tr -d '\n')"
    config "P_ES_CLOUD_ID=$cloud_id" 'P_ES_API_KEY=k'
    es --endpoint _count -i products
    recorded curl '.config | contains("url = \"https://abc123.eu-west-1.aws.example.io/products/_count\"")'
}

@test "a credential is tried as an API key first, then as user:password on 401 or 403" {
    : > "$DBTOOLS_ENV_FILE"
    config 'P_ES_URL=https://search.example.com' 'P_ES_CREDENTIAL=reader:pw-77aa'
    answer curl $'{"error":"unauthorized"}\n401'
    es --endpoint _count
    [ "$status" -eq 3 ]
    calls curl 'length == 2'
    calls curl '.[0].config | contains("Authorization: ApiKey ")'
    calls curl '.[1].config | contains("user = \"reader:pw-77aa\"")'
    last_audit '.auth == "basic" and .http_code == "401"'
}

@test "output is masked, the status is in the log" {
    es -i products
    [[ "$output" =~ al\*\*@example\.com ]] || false
    [[ "$output" != *alice* ]] || false
    last_audit '.db == "elastic" and .outcome == "ok" and .http_code == "200" and .auth == "apikey" and .index == "products"
        and .endpoint == "_search" and .method == "GET"'
}

@test "an HTTP error exits 3, shows the body and is logged as failed" {
    answer curl $'{"error":{"type":"index_not_found_exception"}}\n404'
    es -i nope --endpoint _count
    [ "$status" -eq 3 ]
    [[ "$output" =~ index_not_found_exception ]] || false
    last_audit '.outcome == "failed" and .reason == "HTTP 404"'
}

@test "refusals: write APIs and paths that climb, before curl runs" {
    for e in _doc _bulk _delete_by_query '_search/../_doc/1' '_cat/../products/_delete_by_query' '_search/%2e%2e'; do
        es -i products --endpoint "$e" -q '{}'
        [ "$status" -eq 1 ] || { echo "not refused: $e"; false; }
    done
    last_audit '.outcome == "refused" and .reason == "endpoint-segment-not-allowed" and .endpoint == "_search/%2e%2e"'
    not_called curl
}

@test "refusals: an index that climbs and an injected --size" {
    es -i '..' --endpoint _count
    [ "$status" -eq 1 ]
    es -i products --size '1&q=x'
    [ "$status" -eq 1 ]
    last_audit '.reason == "size-not-a-count" and .given.size == "1&q=x"'
    not_called curl
}

@test "configuration errors: no endpoint, no credential, a line break, a bad auth mode" {
    : > "$DBTOOLS_ENV_FILE"
    config 'P_ES_API_KEY=k'
    es --endpoint _count
    [ "$status" -eq 2 ]
    : > "$DBTOOLS_ENV_FILE"
    config 'P_ES_URL=https://search.example.com'
    es --endpoint _count
    [ "$status" -eq 2 ]
    : > "$DBTOOLS_ENV_FILE"
    config 'P_ES_URL=https://search.example.com' 'P_ES_CREDENTIAL=a:b' 'P_ES_AUTH=token'
    es --endpoint _count
    [ "$status" -eq 2 ]
    P_ES_API_KEY=$'k\noutput = /tmp/owned' es --endpoint _count
    [ "$status" -eq 2 ]
    [[ "$output" =~ "line breaks" ]] || false
    not_called curl
}
