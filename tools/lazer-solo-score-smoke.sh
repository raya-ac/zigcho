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

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/friends?target=5" \
  --header "Authorization: Bearer $token_one")
expect_status "$code" 200 add_friend
jq -e '.user_relation.target_id == 5 and .user_relation.relation_type == "friend" and .user_relation.target.id == 5' "$response" >/dev/null || fail invalid_add_friend_contract
auth_get /api/v2/friends friends_after_add
jq -e 'any(.[]; .target_id == 5 and .relation_type == "friend")' "$response" >/dev/null || fail friend_not_added
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request DELETE "$origin/api/v2/friends/5" \
  --header "Authorization: Bearer $token_one")
expect_status "$code" 204 delete_friend

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/blocks?target=5" \
  --header "Authorization: Bearer $token_one")
expect_status "$code" 204 add_block
auth_get /api/v2/blocks blocks_after_add
jq -e 'any(.[]; .target_id == 5 and .relation_type == "block")' "$response" >/dev/null || fail block_not_added
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request DELETE "$origin/api/v2/blocks/5" \
  --header "Authorization: Bearer $token_one")
expect_status "$code" 204 delete_block

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/beatmapsets/75/favourites" \
  --header "Authorization: Bearer $token_one" --data-urlencode 'action=favourite')
expect_status "$code" 204 add_favourite
auth_get /api/v2/me/beatmapset-favourites favourites_after_add
jq -e '.beatmapset_ids == [75]' "$response" >/dev/null || fail favourite_not_added
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/beatmapsets/75/favourites" \
  --header "Authorization: Bearer $token_one" --data-urlencode 'action=unfavourite')
expect_status "$code" 204 delete_favourite
auth_get '/api/v2/users/4/osu?key=id' profile_osu
jq -e '.id == 4 and .statistics.play_count == 0 and .country_code == "XX"' "$response" >/dev/null || fail invalid_profile_contract
auth_get '/api/v2/users/4/?key=id' profile_default_ruleset
jq -e '.id == 4 and .statistics.play_count == 0' "$response" >/dev/null || fail invalid_default_profile_contract
auth_get '/api/v2/users/lazer-one/mania?key=username' profile_mania
jq -e '.id == 4 and .statistics.play_count == 0' "$response" >/dev/null || fail invalid_username_profile_contract
auth_get '/api/v2/users/lookup/?ids[]=3&ids[]=4&ruleset_id=0' user_lookup_batch
jq -e '.cursor == null and (.users | length) == 2 and .users[0].id == 3 and .users[1].id == 4' "$response" >/dev/null || fail invalid_user_lookup_batch_contract
auth_get '/api/v2/beatmaps/lookup?checksum=0123456789abcdef0123456789abcdef' beatmap_lookup
jq -e '.id == 75 and .status == "ranked" and .beatmapset.id == 75 and .beatmapset.status == "ranked"' "$response" >/dev/null || fail invalid_beatmap_lookup_contract
auth_get '/api/v2/beatmaps/lookup?id=75&checksum=0123456789abcdef0123456789abcdef' beatmap_lookup_with_online_id
jq -e '.id == 75 and .beatmapset.id == 75' "$response" >/dev/null || fail invalid_beatmap_online_id_contract
auth_get '/api/v2/beatmaps/?ids[]=75' beatmap_lookup_batch
jq -e '.cursor == null and (.beatmaps | length) == 1 and .beatmaps[0].id == 75' "$response" >/dev/null || fail invalid_beatmap_batch_contract
auth_get /api/v2/tags tags
jq -e '.tags == []' "$response" >/dev/null || fail invalid_tags_contract
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/chat/ack" \
  --header "Authorization: Bearer $token_one" --data-urlencode 'since=0')
expect_status "$code" 200 chat_ack
jq -e '.silences == []' "$response" >/dev/null || fail invalid_chat_ack_contract

auth_get /api/v2/chat/channels chat_channels
jq -e '
  length == 4 and
  .[0].channel_id == 1 and .[0].name == "#osu" and .[0].type == 0 and
  .[1].channel_id == 2 and .[1].name == "#announce" and .[1].type == 8 and
  .[2].channel_id == 3 and .[2].name == "#lobby" and
  .[3].channel_id == 4 and .[3].name == "#lazer" and
  all(.[]; .message_length_limit == 2000)
' "$response" >/dev/null || fail invalid_chat_channel_list_contract
auth_get /api/v2/chat/channels/4 chat_channel
jq -e '.channel.channel_id == 4 and .channel.name == "#lazer" and .users == []' "$response" >/dev/null || fail invalid_chat_channel_contract

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request PUT "$origin/api/v2/chat/channels/4/users/4" \
  --header "Authorization: Bearer $token_one")
expect_status "$code" 200 chat_join

chat_uuid=01234567-89ab-cdef-0123-456789abcdef
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/chat/channels/4/messages" \
  --header "Authorization: Bearer $token_one" --data-urlencode 'message=hello from lazer smoke' \
  --data-urlencode 'is_action=false' --data-urlencode "uuid=$chat_uuid")
expect_status "$code" 201 chat_post
chat_message_id=$(jq -er '.message_id | select(. > 0)' "$response")
jq -e --arg uuid "$chat_uuid" '.channel_id == 4 and .content == "hello from lazer smoke" and .uuid == $uuid and .sender.id == 4' "$response" >/dev/null || fail invalid_chat_post_contract

auth_get /api/v2/chat/channels/4/messages chat_history
jq -e --arg uuid "$chat_uuid" 'length == 1 and .[0].uuid == $uuid and .[0].channel_id == 4' "$response" >/dev/null || fail invalid_chat_history_contract
auth_get "/api/v2/chat/messages?since=0" chat_poll
jq -e --arg uuid "$chat_uuid" 'any(.[]; .uuid == $uuid and .channel_id == 4)' "$response" >/dev/null || fail invalid_chat_poll_contract

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request PUT "$origin/api/v2/chat/channels/4/mark-as-read/$chat_message_id" \
  --header "Authorization: Bearer $token_one")
expect_status "$code" 200 chat_mark_read
auth_get /api/v2/chat/channels chat_channels_after_read
jq -e --argjson id "$chat_message_id" '.[3].last_message_id == $id and .[3].last_read_id == $id' "$response" >/dev/null || fail invalid_chat_read_state_contract

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request DELETE "$origin/api/v2/chat/channels/4/users/4" \
  --header "Authorization: Bearer $token_one")
expect_status "$code" 200 chat_leave

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
[ "$(sqlite3 "$database" 'PRAGMA user_version')" = 27 ] || fail schema_not_migrated

auth_get '/api/v2/beatmaps/75/scores?type=global&mode=osu&mods%5B%5D=WIGGLE&limit=50' custom_leaderboard
jq -e --argjson id "$score_id" '
  .score_count == 1 and
  (.scores | length) == 1 and
  .scores[0].id == $id and
  .scores[0].rank == "A" and
  .scores[0].ranked == false and
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

sqlite3 "$database" "UPDATE users SET country='AU' WHERE id=4"
auth_get '/api/v2/rankings/osu/performance?page=1' performance_rankings
jq -e '
  .cursor == null and
  (.ranking | length) == 1 and
  .ranking[0].user.id == 4 and
  .ranking[0].user.username == "lazer-one" and
  .ranking[0].global_rank == 1 and
  .ranking[0].country_rank == 1 and
  .ranking[0].pp > 0 and
  .ranking[0].play_count == 1 and
  .ranking[0].hit_accuracy == 90
' "$response" >/dev/null || fail invalid_performance_rankings_contract
auth_get '/api/v2/rankings/osu/score?page=1&country=au' score_rankings
jq -e '.cursor == null and (.ranking | length) == 1 and .ranking[0].user.country_code == "AU" and .ranking[0].total_score == 123456' "$response" >/dev/null || fail invalid_score_rankings_contract
auth_get '/api/v2/rankings/osu/country?page=1' country_rankings
jq -e '.cursor == null and (.ranking | length) == 1 and .ranking[0].code == "AU" and .ranking[0].active_users == 1 and .ranking[0].play_count == 1 and .ranking[0].performance > 0' "$response" >/dev/null || fail invalid_country_rankings_contract

auth_get '/api/v2/users/4/osu?key=id' profile_after_scores
jq -e '
  .scores_best_count == 1 and
  .scores_first_count == 1 and
  .scores_recent_count == 2 and
  .scores_pinned_count == 0
' "$response" >/dev/null || fail invalid_profile_score_counts

auth_get '/api/v2/users/4/scores/best?mode=osu&offset=0&limit=50' profile_best_scores
jq -e --argjson id "$vanilla_score_id" '
  length == 1 and
  .[0].id == $id and
  .[0].ranked == true and
  .[0].mods == [] and
  .[0].beatmap.id == 75 and
  .[0].beatmap.beatmapset.artist == "artist"
' "$response" >/dev/null || fail invalid_profile_best_scores

auth_get '/api/v2/users/4/scores/recent?mode=osu&offset=0&limit=50' profile_recent_scores
jq -e --argjson custom "$score_id" --argjson vanilla "$vanilla_score_id" '
  length == 2 and
  any(.[]; .id == $custom and .ranked == false and .mods[0].acronym == "RX" and .mods[1].acronym == "WIGGLE") and
  any(.[]; .id == $vanilla and .ranked == true and .mods == [])
' "$response" >/dev/null || fail invalid_profile_recent_scores

auth_get '/api/v2/users/4/scores/firsts?mode=osu&offset=0&limit=50' profile_first_scores
jq -e --argjson id "$vanilla_score_id" 'length == 1 and .[0].id == $id' "$response" >/dev/null || fail invalid_profile_first_scores
auth_get '/api/v2/users/4/scores/pinned?mode=osu&offset=0&limit=50' profile_pinned_scores
jq -e '. == []' "$response" >/dev/null || fail invalid_profile_pinned_scores

expired_token=$(create_score_token "$token_one")
sqlite3 "$database" "UPDATE lazer_score_tokens SET expires_at=0 WHERE id=$expired_token"
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request PUT "$origin/api/v2/beatmaps/75/solo/scores/$expired_token" \
  --header "Authorization: Bearer $token_one" --header 'Content-Type: application/json' --data "$score_body")
expect_status "$code" 401 reject_expired_token

[ "$(sqlite3 "$database" 'SELECT count(*) FROM lazer_scores')" = 2 ] || fail rejected_submissions_were_stored
echo "lazer_solo_score_smoke_ok custom_score_id=$score_id vanilla_score_id=$vanilla_score_id"
