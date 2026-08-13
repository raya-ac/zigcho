#!/bin/sh
set -eu

server=${1:-./zig-out/bin/zigcho}
port=${ZIGCHO_SMOKE_PORT:-18094}
origin="http://127.0.0.1:$port"
work=$(mktemp -d "${TMPDIR:-/tmp}/zigcho-lazer-score.XXXXXX")
database="$work/zigcho.db"
response="$work/response"
server_log="$work/server.log"
server_pid=
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "lazer_solo_score_smoke_failed $*" >&2
  if [ -f "$response" ]; then sed -n '1,10p' "$response" >&2; fi
  exit 1
}

expect_status() {
  [ "$1" = "$2" ] || fail "$3 status=$1 expected=$2"
}

"$server" 127.0.0.1 "$port" "$database" >"$server_log" 2>&1 &
server_pid=$!
attempt=0
until curl --fail --silent "$origin/health" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 50 ] || ! kill -0 "$server_pid" >/dev/null 2>&1; then
    sed -n '1,80p' "$server_log" >&2
    fail server_not_ready
  fi
  sleep 0.1
done

for name in lazer-one lazer-two; do
  code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/users" \
    --data-urlencode "user[username]=$name" --data-urlencode "user[user_email]=$name@example.test" --data-urlencode 'user[password]=LazerPass123!')
  expect_status "$code" 201 "register_$name"
done

sqlite3 "$database" "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,max_combo,mode,osu_file) VALUES(75,75,'0123456789abcdef0123456789abcdef','artist','title','diff','mapper',3,10,0,readfile('$repo/src/testdata/synthetic-standard.osu'));"

oauth() {
  curl --silent --show-error --request POST "$origin/oauth/token" \
    --data-urlencode 'grant_type=password' --data-urlencode "username=$1" --data-urlencode 'password=LazerPass123!' | jq -er '.access_token'
}
token_one=$(oauth lazer-one)
token_two=$(oauth lazer-two)

auth_get() {
  code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "$origin$1" --header "Authorization: Bearer $token_one")
  expect_status "$code" 200 "$2"
}

auth_get /api/v2/me/ me
jq -e '.statistics_rulesets.osu.play_count == 0 and .avatar_url == "https://a.kai.ovh/4"' "$response" >/dev/null || fail invalid_me_contract
auth_get /api/v2/notifications notifications
jq -e '.has_more == false and .notifications == [] and (.notification_endpoint | startswith("wss://"))' "$response" >/dev/null || fail invalid_notifications_contract
auth_get /api/v2/friends friends
jq -e 'type == "array" and any(.[]; .target_id == 3 and .target.is_bot == true)' "$response" >/dev/null || fail invalid_friends_contract
auth_get /api/v2/blocks blocks
jq -e '. == []' "$response" >/dev/null || fail invalid_blocks_contract
auth_get /api/v2/me/beatmapset-favourites favourites
jq -e '.beatmapset_ids == []' "$response" >/dev/null || fail invalid_favourites_contract
auth_get '/api/v2/users/4/osu?key=id' profile_osu
jq -e '.id == 4 and .statistics.play_count == 0 and .country_code == "XX"' "$response" >/dev/null || fail invalid_profile_contract
auth_get '/api/v2/users/4/?key=id' profile_default_ruleset
jq -e '.id == 4 and .statistics.play_count == 0' "$response" >/dev/null || fail invalid_default_profile_contract
auth_get '/api/v2/users/lazer-one/mania?key=username' profile_mania
jq -e '.id == 4 and .statistics.play_count == 0' "$response" >/dev/null || fail invalid_username_profile_contract
auth_get '/api/v2/beatmaps/lookup?checksum=0123456789abcdef0123456789abcdef' beatmap_lookup
jq -e '.id == 75 and .status == "ranked" and .beatmapset.id == 75 and .beatmapset.status == "ranked"' "$response" >/dev/null || fail invalid_beatmap_lookup_contract
auth_get /api/v2/tags tags
jq -e '.tags == []' "$response" >/dev/null || fail invalid_tags_contract
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/chat/ack" \
  --header "Authorization: Bearer $token_one" --data-urlencode 'since=0')
expect_status "$code" 200 chat_ack
jq -e '.silences == []' "$response" >/dev/null || fail invalid_chat_ack_contract

create_score_token() {
  code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/beatmaps/75/solo/scores" \
    --header "Authorization: Bearer $1" --data-urlencode 'version_hash=11111111111111111111111111111111' \
    --data-urlencode 'beatmap_hash=0123456789abcdef0123456789abcdef' --data-urlencode 'ruleset_id=0')
  expect_status "$code" 201 create_score_token
  jq -er '.id | select(. > 0)' "$response"
}

score_body='{"rank":"A","total_score":987654,"total_score_without_mods":900000,"accuracy":0.985,"max_combo":321,"ruleset_id":0,"passed":true,"mods":[{"acronym":"RX"},{"acronym":"WIGGLE","settings":{"strength":1.25}}],"statistics":{"great":300,"miss":2},"maximum_statistics":{"great":302},"pauses":[1000,2000]}'
score_token=$(create_score_token "$token_one")

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request PUT "$origin/api/v2/beatmaps/75/solo/scores/$score_token" \
  --header "Authorization: Bearer $token_two" --header 'Content-Type: application/json' --data "$score_body")
expect_status "$code" 401 reject_foreign_user

wrong_ruleset=$(printf '%s' "$score_body" | sed 's/"ruleset_id":0/"ruleset_id":1/')
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request PUT "$origin/api/v2/beatmaps/75/solo/scores/$score_token" \
  --header "Authorization: Bearer $token_one" --header 'Content-Type: application/json' --data "$wrong_ruleset")
expect_status "$code" 422 reject_token_mismatch

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request PUT "$origin/api/v2/beatmaps/75/solo/scores/$score_token" \
  --header "Authorization: Bearer $token_one" --header 'Content-Type: application/json' --data "$score_body")
expect_status "$code" 200 submit_score
score_id=$(jq -er '.id | select(. > 0)' "$response")
jq -e '.position == null' "$response" >/dev/null || fail invalid_client_response

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request PUT "$origin/api/v2/beatmaps/75/solo/scores/$score_token" \
  --header "Authorization: Bearer $token_one" --header 'Content-Type: application/json' --data "$score_body")
expect_status "$code" 409 reject_token_reuse

[ "$(sqlite3 "$database" "SELECT mods_json FROM lazer_scores WHERE id=$score_id")" = '[{"acronym":"RX"},{"acronym":"WIGGLE","settings":{"strength":1.25}}]' ] || fail mods_not_stored_separately
[ "$(sqlite3 "$database" "SELECT statistics_json FROM lazer_scores WHERE id=$score_id")" = '{"great":300,"miss":2}' ] || fail statistics_not_stored_separately
[ "$(sqlite3 "$database" "SELECT rank_namespace FROM lazer_scores WHERE id=$score_id")" = custom ] || fail custom_namespace_missing
[ "$(sqlite3 "$database" 'PRAGMA user_version')" = 22 ] || fail schema_not_migrated

auth_get '/api/v2/beatmaps/75/scores?type=global&mode=osu&mods%5B%5D=WIGGLE&limit=50' custom_leaderboard
jq -e --argjson id "$score_id" '
  .score_count == 1 and
  (.scores | length) == 1 and
  .scores[0].id == $id and
  .scores[0].rank == "A" and
  .scores[0].mods[1].acronym == "WIGGLE" and
  .scores[0].maximum_statistics.great == 302 and
  .user_score.position == 1
' "$response" >/dev/null || fail invalid_custom_leaderboard_contract

vanilla_body='{"rank":"S","total_score":123456,"total_score_without_mods":123456,"accuracy":0.9,"max_combo":8,"ruleset_id":0,"passed":true,"mods":[],"statistics":{"great":9,"miss":1},"maximum_statistics":{"great":10},"pauses":[]}'
vanilla_token=$(create_score_token "$token_one")
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request PUT "$origin/api/v2/beatmaps/75/solo/scores/$vanilla_token" \
  --header "Authorization: Bearer $token_one" --header 'Content-Type: application/json' --data "$vanilla_body")
expect_status "$code" 200 submit_vanilla_score
vanilla_score_id=$(jq -er '.id | select(. > 0)' "$response")

auth_get '/api/v2/beatmaps/75/scores?type=global&mode=osu&limit=50' vanilla_leaderboard
jq -e --argjson id "$vanilla_score_id" '
  .score_count == 1 and
  .scores[0].id == $id and
  .scores[0].ranked == true and
  .scores[0].total_score == 123456 and
  .scores[0].pp > 0 and
  .user_score.score.id == $id
' "$response" >/dev/null || fail invalid_vanilla_leaderboard_contract

auth_get /api/v2/me/ me_after_vanilla_score
jq -e '
  .statistics_rulesets.osu.play_count == 1 and
  .statistics_rulesets.osu.total_score == 123456 and
  .statistics_rulesets.osu.ranked_score == 123456 and
  .statistics_rulesets.osu.total_hits == 9 and
  .statistics_rulesets.osu.maximum_combo == 8 and
  .statistics_rulesets.osu.pp > 0 and
  .statistics_rulesets.osu.hit_accuracy == 90 and
  .statistics_rulesets.taiko.play_count == 0 and
  .statistics_rulesets.taiko.total_score == 0
' "$response" >/dev/null || fail v2_score_overwrote_stats

expired_token=$(create_score_token "$token_one")
sqlite3 "$database" "UPDATE lazer_score_tokens SET expires_at=0 WHERE id=$expired_token"
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request PUT "$origin/api/v2/beatmaps/75/solo/scores/$expired_token" \
  --header "Authorization: Bearer $token_one" --header 'Content-Type: application/json' --data "$score_body")
expect_status "$code" 401 reject_expired_token

[ "$(sqlite3 "$database" 'SELECT count(*) FROM lazer_scores')" = 2 ] || fail rejected_submissions_were_stored
echo "lazer_solo_score_smoke_ok custom_score_id=$score_id vanilla_score_id=$vanilla_score_id"
