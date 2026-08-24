#!/bin/sh
set -eu

server=${1:-./zig-out/bin/zigcho}
case "$server" in
  /*) ;;
  *) server="$(CDPATH='' cd -- "$(dirname "$server")" && pwd)/$(basename "$server")" ;;
esac
port=${ZIGCHO_SMOKE_PORT:-18096}
origin="http://127.0.0.1:$port"
work=$(mktemp -d "${TMPDIR:-/tmp}/zigcho-lazer-bot.XXXXXX")
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
  echo "lazer_bot_smoke_failed $*" >&2
  if [ -f "$response" ]; then sed -n '1,20p' "$response" >&2; fi
  if [ -f "$server_log" ]; then sed -n '1,100p' "$server_log" >&2; fi
  exit 1
}

expect_status() {
  [ "$1" = "$2" ] || fail "$3 status=$1 expected=$2"
}

(cd "$work" && "$server" 127.0.0.1 "$port" "$database") >"$server_log" 2>&1 &
server_pid=$!
attempt=0
until curl --fail --silent "$origin/health" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 50 ] || ! kill -0 "$server_pid" >/dev/null 2>&1; then
    fail server_not_ready
  fi
  sleep 0.1
done

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/users" \
  --data-urlencode 'user[username]=lazer-bot-user' --data-urlencode 'user[user_email]=lazer-bot-user@example.test' \
  --data-urlencode 'user[password]=LazerPass123!')
expect_status "$code" 201 register

sqlite3 "$database" "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,max_combo,mode,osu_file) VALUES(75,75,'0123456789abcdef0123456789abcdef','artist','title','diff','mapper',3,10,0,readfile('$repo/src/testdata/synthetic-standard.osu')); INSERT INTO scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,checksum,rank_namespace,best) VALUES(4,'0123456789abcdef0123456789abcdef',0,0,1200,300,1,100,100,0,0,0,0,0,1,1,'stable-profile-smoke','vanilla',1); INSERT INTO lazer_scores(user_id,beatmap_id,ruleset_id,total_score,total_score_without_mods,legacy_total_score,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,rank_namespace,client_version,pp,best) VALUES(4,75,0,1500,900,NULL,0.95,90,1,'A','[]','{\"great\":95,\"miss\":5}','{\"great\":100}','[]','vanilla','2026.816.0',350,1); UPDATE stats SET ranked_score=1200,total_score=2100,pp=350,plays=2,accuracy=0.95,max_combo=100 WHERE user_id=4 AND mode=0;"

token=$(curl --silent --show-error --request POST "$origin/oauth/token" \
  --data-urlencode 'grant_type=password' --data-urlencode 'username=lazer-bot-user' \
  --data-urlencode 'password=LazerPass123!' | jq -er '.access_token')

auth_get() {
  code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "$origin$1" \
    --header "Authorization: Bearer $token")
  expect_status "$code" 200 "$2"
}

auth_get /api/v2/me/ me
jq -e '.id == 4 and .is_online == true and (.last_visit | type == "string" and endswith("Z"))' "$response" >/dev/null || fail invalid_online_presence

auth_get '/api/v2/users/4/osu?key=id' profile
jq -e '
  .id == 4 and
  .statistics.pp == 350 and .statistics.play_count == 2 and
  .zigcho_statistics.stable.pp == 300 and .zigcho_statistics.stable.play_count == 1 and
  .zigcho_statistics.lazer.pp == 350 and .zigcho_statistics.lazer.play_count == 1 and
  .zigcho_score_counts.stable.recent == 1 and .zigcho_score_counts.lazer.recent == 1 and
  .profile_order == ["recent_activity", "top_ranks", "medals"]
' "$response" >/dev/null || fail invalid_combined_profile_contract

auth_get '/api/v2/users/4/scores/recent?mode=osu&source=stable' stable_plays
jq -e 'length == 1 and .[0].id >= 4000000000000000000 and .[0].user.id == 4' "$response" >/dev/null || fail invalid_stable_play_tab

auth_get '/api/v2/users/4/scores/recent?mode=osu&source=lazer' lazer_plays
jq -e 'length == 1 and .[0].id < 4000000000000000000 and .[0].user.id == 4' "$response" >/dev/null || fail invalid_lazer_play_tab

help_uuid=11111111-1111-4111-8111-111111111111
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/chat/new" \
  --header "Authorization: Bearer $token" --data-urlencode 'target_id=3' --data-urlencode 'message=!help' \
  --data-urlencode 'is_action=false' --data-urlencode "uuid=$help_uuid")
expect_status "$code" 201 bot_help
jq -e --arg uuid "$help_uuid" '.new_channel_id == 1000003 and .message.sender_id == 4 and .message.uuid == $uuid' "$response" >/dev/null || fail invalid_help_write

auth_get /api/v2/chat/channels/1000003/messages help_history
jq -e '
  length == 2 and
  .[0].sender_id == 4 and .[0].content == "!help" and
  .[1].sender_id == 3 and .[1].sender.is_bot == true and
  (. [1].content | startswith("player: /np !with"))
' "$response" >/dev/null || fail bot_help_reply_missing

np_uuid=22222222-2222-4222-8222-222222222222
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/chat/channels/1000003/messages" \
  --header "Authorization: Bearer $token" \
  --data-urlencode 'message=is playing [https://kai.ovh/b/75 artist - title [diff]] <osu!standard> +HD' \
  --data-urlencode 'is_action=true' --data-urlencode "uuid=$np_uuid")
expect_status "$code" 201 bot_np

auth_get /api/v2/chat/channels/1000003/messages np_history
jq -e '
  length == 4 and
  .[2].sender_id == 4 and .[2].is_action == true and
  .[3].sender_id == 3 and (. [3].content | contains("pp"))
' "$response" >/dev/null || fail bot_np_reply_missing

grep -q 'event=lazer_bot_.*failed' "$server_log" && fail bot_command_logged_failure
echo lazer_bot_smoke_ok
