#!/bin/sh
set -eu

server=${1:-./zig-out/bin/zigcho}
case "$server" in
  /*) ;;
  *) server="$(CDPATH='' cd -- "$(dirname "$server")" && pwd)/$(basename "$server")" ;;
esac
port=${ZIGCHO_SPECTATOR_SMOKE_PORT:-18097}
origin="http://127.0.0.1:$port"
work=$(mktemp -d "${TMPDIR:-/tmp}/zigcho-lazer-spectator.XXXXXX")
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
  echo "lazer_spectator_smoke_failed $*" >&2
  sed -n '1,160p' "$server_log" >&2
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

for name in spectator-one spectator-two; do
  code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/users" \
    --data-urlencode "user[username]=$name" --data-urlencode "user[user_email]=$name@example.test" --data-urlencode 'user[password]=LazerPass123!')
  [ "$code" = 201 ] || fail "register_$name status=$code"
done

sqlite3 "$database" "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,max_combo,mode,osu_file) VALUES(75,75,'0123456789abcdef0123456789abcdef','artist','title','diff','mapper',3,10,0,readfile('$repo/src/testdata/synthetic-standard.osu'));"

oauth() {
  curl --silent --show-error --request POST "$origin/oauth/token" \
    --data-urlencode 'grant_type=password' --data-urlencode "username=$1" --data-urlencode 'password=LazerPass123!' | jq -er '.access_token'
}
token_one=$(oauth spectator-one)
token_two=$(oauth spectator-two)

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/spectator/negotiate?negotiateVersion=1" --header "Authorization: Bearer $token_one")
[ "$code" = 200 ] || fail "negotiate status=$code"
jq -e '.negotiateVersion == 1 and .availableTransports[0].transport == "WebSockets" and .availableTransports[0].transferFormats == ["Binary"]' "$response" >/dev/null || fail negotiate_contract

python3 "$repo/tools/lazer-spectator-ws-smoke.py" 127.0.0.1 "$port" "$token_one" "$token_two" || fail websocket_flow

grep -q 'event=lazer_spectator_play_started' "$server_log" || fail play_start_not_logged
grep -q 'event=lazer_spectator_play_finished' "$server_log" || fail play_finish_not_logged
grep -q 'event=lazer_spectator_watch_started' "$server_log" || fail watch_start_not_logged
grep -q 'event=lazer_spectator_watch_ended' "$server_log" || fail watch_end_not_logged
echo lazer_spectator_smoke_ok
