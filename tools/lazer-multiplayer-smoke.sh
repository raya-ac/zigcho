#!/bin/sh
set -eu

server=${1:-./zig-out/bin/zigcho}
case "$server" in
  /*) ;;
  *) server="$(CDPATH='' cd -- "$(dirname "$server")" && pwd)/$(basename "$server")" ;;
esac
port=${ZIGCHO_MULTIPLAYER_SMOKE_PORT:-18096}
origin="http://127.0.0.1:$port"
work=$(mktemp -d "${TMPDIR:-/tmp}/zigcho-lazer-multiplayer.XXXXXX")
database="$work/zigcho.db"
response="$work/response"
server_log="$work/server.log"
server_pid=
repo=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "lazer_multiplayer_smoke_failed $*" >&2
  sed -n '1,120p' "$server_log" >&2
  exit 1
}

(cd "$work" && "$server" 127.0.0.1 "$port" "$database") >"$server_log" 2>&1 &
server_pid=$!
attempt=0
until curl --fail --silent "$origin/health" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 50 ] || ! kill -0 "$server_pid" >/dev/null 2>&1; then fail server_not_ready; fi
  sleep 0.1
done

for name in multiplayer-one multiplayer-two; do
  code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/users" \
    --data-urlencode "user[username]=$name" --data-urlencode "user[user_email]=$name@example.test" --data-urlencode 'user[password]=LazerPass123!')
  [ "$code" = 201 ] || fail "register_$name status=$code"
done

sqlite3 "$database" "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,max_combo,mode,osu_file) VALUES(75,75,'0123456789abcdef0123456789abcdef','artist','title','diff one','mapper',3,10,0,readfile('$repo/src/testdata/synthetic-standard.osu')),(76,75,'1123456789abcdef0123456789abcdef','artist','title','diff two','mapper',3,10,0,readfile('$repo/src/testdata/synthetic-standard.osu')),(77,75,'2123456789abcdef0123456789abcdef','artist','title','diff three','mapper',3,10,0,readfile('$repo/src/testdata/synthetic-standard.osu'));"

oauth() {
  curl --silent --show-error --request POST "$origin/oauth/token" \
    --data-urlencode 'grant_type=password' --data-urlencode "username=$1" --data-urlencode 'password=LazerPass123!' | jq -er '.access_token'
}
token_one=$(oauth multiplayer-one)
token_two=$(oauth multiplayer-two)

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/multiplayer/negotiate?negotiateVersion=1" --header "Authorization: Bearer $token_one")
[ "$code" = 200 ] || fail "negotiate status=$code"
jq -e '.negotiateVersion == 1 and .availableTransports[0].transport == "WebSockets" and .availableTransports[0].transferFormats == ["Binary"]' "$response" >/dev/null || fail negotiate_contract

python3 "$repo/tools/lazer-multiplayer-ws-smoke.py" 127.0.0.1 "$port" "$token_one" "$token_two" || fail websocket_flow

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "$origin/api/v2/rooms" --header "Authorization: Bearer $token_one")
[ "$code" = 200 ] || fail "room_list status=$code"
jq -e '. == []' "$response" >/dev/null || fail rooms_not_cleaned_up

grep -q 'event=lazer_multiplayer_room_created' "$server_log" || fail room_create_not_logged
grep -q 'event=lazer_multiplayer_room_joined' "$server_log" || fail room_join_not_logged
grep -q 'event=lazer_matchmaking_group_formed' "$server_log" || fail matchmaking_group_not_logged
grep -q 'event=lazer_matchmaking_duel_issued' "$server_log" || fail matchmaking_duel_issue_not_logged
grep -q 'event=lazer_matchmaking_duel_accepted' "$server_log" || fail matchmaking_duel_accept_not_logged
grep -q 'event=lazer_matchmaking_room_ready' "$server_log" || fail matchmaking_room_not_logged
echo lazer_multiplayer_smoke_ok
