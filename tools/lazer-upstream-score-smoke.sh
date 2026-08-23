#!/bin/sh
set -eu

server=${1:-./zig-out/bin/zigcho}
port=${ZIGCHO_SMOKE_PORT:-18096}
origin="http://127.0.0.1:$port"
work=$(mktemp -d "${TMPDIR:-/tmp}/zigcho-lazer-upstream.XXXXXX")
database="$work/zigcho.db"
response="$work/response"
server_log="$work/server.log"
server_pid=

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "lazer_upstream_score_smoke_failed $*" >&2
  if [ -f "$response" ]; then sed -n '1,10p' "$response" >&2; fi
  if [ -f "$server_log" ]; then tail -n 40 "$server_log" >&2; fi
  exit 1
}

"$server" 127.0.0.1 "$port" "$database" >"$server_log" 2>&1 &
server_pid=$!
attempt=0
until curl --fail --silent "$origin/health" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 50 ] || ! kill -0 "$server_pid" >/dev/null 2>&1; then fail server_not_ready; fi
  sleep 0.1
done

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/users" \
  --data-urlencode 'user[username]=upstream-score' --data-urlencode 'user[user_email]=upstream-score@example.test' --data-urlencode 'user[password]=LazerPass123!')
[ "$code" = 201 ] || fail "register status=$code"
token=$(curl --silent --show-error --request POST "$origin/oauth/token" \
  --data-urlencode 'grant_type=password' --data-urlencode 'username=upstream-score' --data-urlencode 'password=LazerPass123!' | jq -er '.access_token')

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --get "$origin/api/v2/beatmapsets/search" \
  --header "Authorization: Bearer $token")
[ "$code" = 200 ] || fail "upstream_listing status=$code"
jq -e '(.beatmapsets | length) > 0 and all(.beatmapsets[]; .id > 0 and (.beatmaps | length) > 0 and (.video | type) == "boolean") and .total > 0' "$response" >/dev/null || fail invalid_upstream_listing_contract

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --get "$origin/api/v2/beatmapsets/search" \
  --header "Authorization: Bearer $token" --data-urlencode 'q=Thaehan Never Give Up' --data 'm=0' --data 'offset=0')
[ "$code" = 200 ] || fail "upstream_search status=$code"
jq -e '.beatmapsets[] | select(.id == 1048705) | .beatmaps | length == 6' "$response" >/dev/null || fail upstream_search_missing_full_set
[ "$(sqlite3 "$database" 'SELECT count(*) FROM beatmaps WHERE set_id=1048705')" = 6 ] || fail upstream_search_did_not_cache_all_metadata

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "$origin/api/v2/beatmapsets/1048705" --header "Authorization: Bearer $token")
[ "$code" = 200 ] || fail "set_lookup status=$code"
checksum=$(jq -er '.beatmaps[] | select(.id == 2191964) | .checksum' "$response")

code=$(curl --silent --show-error --max-time 9 --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/beatmaps/2191964/solo/scores" \
  --header "Authorization: Bearer $token" --data-urlencode 'version_hash=11111111111111111111111111111111' \
  --data-urlencode "beatmap_hash=$checksum" --data-urlencode 'ruleset_id=0')
[ "$code" = 201 ] || fail "score_token status=$code"
score_token=$(jq -er '.id | select(. > 0)' "$response")
[ "$(sqlite3 "$database" 'SELECT length(osu_file)>0 FROM beatmaps WHERE id=2191964')" = 1 ] || fail score_token_created_without_map_payload
attempt=0
while [ "$(sqlite3 "$database" 'SELECT count(*) FROM beatmaps WHERE set_id=1048705 AND length(osu_file)>0')" != 6 ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 300 ]; then fail archive_did_not_finish_in_background; fi
  sleep 0.1
done
[ "$(sqlite3 "$database" 'SELECT count(*) FROM beatmaps WHERE set_id=1048705 AND length(osu_file)>0')" = 6 ] || fail archive_did_not_store_every_difficulty

body='{"rank":"A","total_score":100000,"total_score_without_mods":100000,"accuracy":0.9,"max_combo":10,"ruleset_id":0,"passed":true,"mods":[],"statistics":{"great":9,"ok":1},"maximum_statistics":{"great":10},"pauses":[]}'
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request PUT "$origin/api/v2/beatmaps/2191964/solo/scores/$score_token" \
  --header "Authorization: Bearer $token" --header 'Content-Type: application/json' --data "$body")
[ "$code" = 200 ] || fail "score_submit status=$code"
jq -e '.id > 0 and .position == 1' "$response" >/dev/null || fail invalid_score_response

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --get "$origin/api/v2/beatmaps/lookup" \
  --header "Authorization: Bearer $token" --data 'id=5297696')
[ "$code" = 200 ] || fail "cold_lookup status=$code"
cold_checksum=$(jq -er '.checksum' "$response")
code=$(curl --silent --show-error --max-time 9 --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/beatmaps/5297696/solo/scores" \
  --header "Authorization: Bearer $token" --data-urlencode 'version_hash=22222222222222222222222222222222' \
  --data-urlencode "beatmap_hash=$cold_checksum" --data-urlencode 'ruleset_id=0')
[ "$code" = 201 ] || fail "cold_score_token status=$code"
[ "$(sqlite3 "$database" 'SELECT length(osu_file)>0 FROM beatmaps WHERE id=5297696')" = 1 ] || fail cold_score_token_created_without_map_payload

echo "lazer_upstream_score_smoke_ok beatmap_id=2191964 mapset_files=6 cold_race_beatmap_id=5297696"
