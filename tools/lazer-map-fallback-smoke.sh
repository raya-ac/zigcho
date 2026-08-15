#!/bin/sh
set -eu

server=${1:-./zig-out/bin/zigcho}
port=${ZIGCHO_SMOKE_PORT:-18098}
origin="http://127.0.0.1:$port"
work=$(mktemp -d "${TMPDIR:-/tmp}/zigcho-lazer-map-fallback.XXXXXX")
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
  echo "lazer_map_fallback_smoke_failed $*" >&2
  if [ -f "$response" ]; then sed -n '1,10p' "$response" >&2; fi
  if [ -f "$server_log" ]; then tail -n 60 "$server_log" >&2; fi
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
  --data-urlencode 'user[username]=fallback-score' --data-urlencode 'user[user_email]=fallback-score@example.test' --data-urlencode 'user[password]=LazerPass123!')
[ "$code" = 201 ] || fail "register status=$code"
token=$(curl --silent --show-error --request POST "$origin/oauth/token" \
  --data-urlencode 'grant_type=password' --data-urlencode 'username=fallback-score' --data-urlencode 'password=LazerPass123!' | jq -er '.access_token')

# This is the production regression: current mirrors do not carry the full set,
# but the canonical map payload is public and matches the client's checksum.
sqlite3 "$database" "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,mode) VALUES(5821049,2603021,'a01532dc9836195cc7ca0a35af5e70f6','Sewerslvt','Lexapro Delirium (Daycore)','Marathon','Len','5','0');"

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/beatmaps/5821049/solo/scores" \
  --header "Authorization: Bearer $token" --data-urlencode 'version_hash=11111111111111111111111111111111' \
  --data-urlencode 'beatmap_hash=a01532dc9836195cc7ca0a35af5e70f6' --data-urlencode 'ruleset_id=0')
[ "$code" = 201 ] || fail "score_token status=$code"
score_token=$(jq -er '.id | select(. > 0)' "$response")
[ "$(sqlite3 "$database" 'SELECT length(osu_file) FROM beatmaps WHERE id=5821049')" = 58540 ] || fail map_payload_not_stored
[ "$(sqlite3 "$database" 'SELECT md5 FROM beatmaps WHERE id=5821049')" = a01532dc9836195cc7ca0a35af5e70f6 ] || fail map_hash_changed

body='{"rank":"A","total_score":100000,"total_score_without_mods":100000,"accuracy":0.9,"max_combo":100,"ruleset_id":0,"passed":true,"mods":[],"statistics":{"great":100,"ok":10,"miss":1},"maximum_statistics":{"great":111},"pauses":[]}'
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request PUT "$origin/api/v2/beatmaps/5821049/solo/scores/$score_token" \
  --header "Authorization: Bearer $token" --header 'Content-Type: application/json' --data "$body")
[ "$code" = 200 ] || fail "score_submit status=$code"
jq -e '.id > 0' "$response" >/dev/null || fail invalid_score_response

grep -q 'stored verified map fallback map=5821049 set=2603021' "$server_log" || fail fallback_not_exercised
echo "lazer_map_fallback_smoke_ok beatmap_id=5821049 payload_bytes=58540"
