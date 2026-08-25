#!/bin/sh
set -eu

server=${1:-./zig-out/bin/zigcho}
case "$server" in
  /*) ;;
  *) server="$(CDPATH='' cd -- "$(dirname "$server")" && pwd)/$(basename "$server")" ;;
esac
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

(cd "$work" && "$server" 127.0.0.1 "$port" "$database") >"$server_log" 2>&1 &
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

sqlite3 "$database" "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,max_combo,mode,total_length,star_rating,osu_file) VALUES(75,75,'0123456789abcdef0123456789abcdef','artist','title','diff','mapper',3,10,0,90,1.7931,readfile('$repo/src/testdata/synthetic-standard.osu')); INSERT INTO user_banners(user_id,object_key,content_type,etag,width,height,updated_at) VALUES(4,'banners/4/profile.jpg','image/jpeg','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',400,400,4242);"

oauth() {
  curl --silent --show-error --request POST "$origin/oauth/token" \
    --data-urlencode 'grant_type=password' --data-urlencode "username=$1" --data-urlencode 'password=LazerPass123!'
}
oauth_one=$(oauth lazer-one)
oauth_two=$(oauth lazer-two)
token_one=$(printf '%s' "$oauth_one" | jq -er '.access_token | select(length == 64)')
refresh_one=$(printf '%s' "$oauth_one" | jq -er '.refresh_token | select(length == 64)')
token_two=$(printf '%s' "$oauth_two" | jq -er '.access_token | select(length == 64)')
printf '%s' "$oauth_two" | jq -e '.refresh_token | length == 64' >/dev/null || fail missing_second_refresh_token
refreshed=$(curl --silent --show-error --request POST "$origin/oauth/token" \
  --data-urlencode 'grant_type=refresh_token' --data-urlencode "refresh_token=$refresh_one" \
  --data-urlencode 'client_id=5' --data-urlencode 'client_secret=zigcho-lazer')
token_one=$(printf '%s' "$refreshed" | jq -er '.access_token | select(length == 64)')
printf '%s' "$refreshed" | jq -e --arg old "$refresh_one" '.expires_in == 3600 and (.refresh_token | length == 64) and .refresh_token != $old' >/dev/null || fail invalid_refresh_contract
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/oauth/token" \
  --data-urlencode 'grant_type=refresh_token' --data-urlencode "refresh_token=$refresh_one")
expect_status "$code" 401 reused_refresh_token

auth_get() {
  code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "$origin$1" --header "Authorization: Bearer $token_one")
  expect_status "$code" 200 "$2"
}

auth_get /api/v2/me/ me
jq -e '.statistics_rulesets.osu.play_count == 0 and (.avatar_url | startswith("https://a.kai.ovh/4")) and .cover_url == "https://assets.kai.ovh/banners/4/cover.jpg?v=4242" and .cover.url == .cover_url and .is_supporter == true and .support_level == 1' "$response" >/dev/null || fail invalid_me_contract
auth_get /api/v2/me/osu me_ruleset
jq -e '.id == 4 and .statistics_rulesets.osu.play_count == 0' "$response" >/dev/null || fail invalid_me_ruleset_contract
for route in session/verify session/verify/reissue session/verify/mail-fallback; do
  code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/$route" --header "Authorization: Bearer $token_one")
  expect_status "$code" 200 "$route"
  jq -e '. == {}' "$response" >/dev/null || fail "invalid_$route"
done
auth_get /api/v2/seasonal-backgrounds seasonal_backgrounds
jq -e '.backgrounds == []' "$response" >/dev/null || fail invalid_seasonal_backgrounds
auth_get '/api/v2/search?mode=user&query=lazer' user_search
jq -e '.total == 2 and (.user.data | length) == 2' "$response" >/dev/null || fail invalid_user_search_contract
auth_get /api/v2/news news
jq -e '.news_posts[0].id == 3800 and .news_posts[0].slug == "2026-08-26-controls-results-and-local-maps" and .cursor == null and .news_sidebar.current_year == 2026' "$response" >/dev/null || fail invalid_news_contract
auth_get /api/v2/spotlights spotlights
jq -e '.spotlights == []' "$response" >/dev/null || fail invalid_spotlights_contract
auth_get /api/v2/rankings/kudosu kudosu_rankings
jq -e '.ranking == []' "$response" >/dev/null || fail invalid_kudosu_rankings_contract
auth_get '/api/v2/rankings/osu/charts?spotlight=1' spotlight_rankings
jq -e '.ranking == [] and .spotlight.id == 1 and .spotlight.name == "zigcho!lazer" and .beatmapsets == []' "$response" >/dev/null || fail invalid_spotlight_rankings_contract
auth_get /api/v2/wiki/en/Main_page wiki
jq -e '.layout == "wiki" and .locale == "en" and .path == "Main_page" and (.markdown | contains("](/wiki/Multiplayer)"))' "$response" >/dev/null || fail invalid_wiki_contract
auth_get /api/v2/changelog changelog
jq -e '(.streams | length) > 0 and (.builds | length) > 0 and .builds[0].id == 38 and .builds[0].changelog_entries[0].id == 3800 and .streams[0].display_name == "zigcho!lazer"' "$response" >/dev/null || fail invalid_changelog_contract
auth_get /api/v2/changelog/lazer/2026.809.0 changelog_oldest
jq -e '(.changelog_entries | length) == 18 and .versions.next.version == "2026.810.0" and .versions.previous == null' "$response" >/dev/null || fail invalid_changelog_navigation
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
auth_get '/api/v2/users/4/beatmapsets/favourite?limit=50&offset=0' profile_favourite_maps
jq -e 'length == 1 and .[0].id == 75' "$response" >/dev/null || fail invalid_profile_favourite_maps_contract
auth_get '/api/v2/beatmapsets/search?s=favourites&sort=ranked_desc' favourite_search
jq -e '(.beatmapsets | length) == 1 and .beatmapsets[0].id == 75 and .cursor == null' "$response" >/dev/null || fail invalid_favourite_search_contract
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/beatmapsets/75/favourites" \
  --header "Authorization: Bearer $token_one" --data-urlencode 'action=unfavourite')
expect_status "$code" 204 delete_favourite
auth_get '/api/v2/users/4/osu?key=id' profile_osu
jq -e '.id == 4 and .statistics.play_count == 0 and .country_code == "XX" and .cover_url == "https://assets.kai.ovh/banners/4/cover.jpg?v=4242" and .cover.custom_url == .cover_url' "$response" >/dev/null || fail invalid_profile_contract
auth_get '/api/v2/users/4/?key=id' profile_default_ruleset
jq -e '.id == 4 and .statistics.play_count == 0' "$response" >/dev/null || fail invalid_default_profile_contract
auth_get '/api/v2/users/lazer-one/mania?key=username' profile_mania
jq -e '.id == 4 and .statistics.play_count == 0' "$response" >/dev/null || fail invalid_username_profile_contract
auth_get '/api/v2/users/4/kudosu?limit=50&offset=0' profile_kudosu
jq -e '. == []' "$response" >/dev/null || fail invalid_profile_kudosu_contract
auth_get '/api/v2/users/4/recent_activity?limit=50&offset=0' profile_activity
jq -e '. == []' "$response" >/dev/null || fail invalid_profile_activity_contract
auth_get '/api/v2/users/4/beatmapsets/most_played?limit=50&offset=0' profile_most_played
jq -e '. == []' "$response" >/dev/null || fail invalid_profile_most_played_contract
auth_get '/api/v2/users/4/beatmapsets/ranked?limit=50&offset=0' profile_ranked_maps
jq -e '. == []' "$response" >/dev/null || fail invalid_profile_ranked_maps_contract
auth_get '/api/v2/users/lookup/?ids[]=3&ids[]=4&ruleset_id=0' user_lookup_batch
jq -e '.cursor == null and (.users | length) == 2 and .users[0].id == 3 and .users[1].id == 4' "$response" >/dev/null || fail invalid_user_lookup_batch_contract
auth_get '/api/v2/beatmaps/lookup?checksum=0123456789abcdef0123456789abcdef' beatmap_lookup
jq -e '.id == 75 and .status == "ranked" and .beatmapset.id == 75 and .beatmapset.status == "ranked"' "$response" >/dev/null || fail invalid_beatmap_lookup_contract
auth_get '/api/v2/beatmaps/lookup?id=75&checksum=0123456789abcdef0123456789abcdef' beatmap_lookup_with_online_id
jq -e '.id == 75 and .beatmapset.id == 75' "$response" >/dev/null || fail invalid_beatmap_online_id_contract
auth_get '/api/v2/beatmaps/?ids[]=75' beatmap_lookup_batch
jq -e '.cursor == null and (.beatmaps | length) == 1 and .beatmaps[0].id == 75' "$response" >/dev/null || fail invalid_beatmap_batch_contract
auth_get /api/v2/tags tags
jq -e '(.tags | length) == 16 and .tags[0].id == 1 and .tags[0].name == "aim"' "$response" >/dev/null || fail invalid_tags_contract
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request PUT "$origin/api/v2/beatmaps/75/tags/1" --header "Authorization: Bearer $token_one")
expect_status "$code" 204 add_beatmap_tag
auth_get '/api/v2/beatmaps/lookup?id=75' tagged_beatmap
jq -e '.current_user_tag_ids == [1] and .top_tag_ids == [{"tag_id":1,"count":1}]' "$response" >/dev/null || fail invalid_beatmap_tag_state
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request DELETE "$origin/api/v2/beatmaps/75/tags/1" --header "Authorization: Bearer $token_one")
expect_status "$code" 204 remove_beatmap_tag
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
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/chat/channels" \
  --header "Authorization: Bearer $token_one" --data-urlencode 'type=PM' --data-urlencode 'target_id=5')
expect_status "$code" 200 create_private_channel
jq -e '.channel_id == 1000005 and .recent_messages == []' "$response" >/dev/null || fail invalid_private_channel_contract
auth_get /api/v2/chat/channels/4 chat_channel
jq -e '.channel.channel_id == 4 and .channel.name == "#lazer" and (.users | length) == 2 and .users[0].id == 4 and .users[1].id == 3 and .users[1].is_bot == true and .users[1].is_online == true' "$response" >/dev/null || fail invalid_chat_channel_contract

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
auth_get "/api/v2/chat/updates?since=0&channel=4" chat_updates
jq -e --arg uuid "$chat_uuid" '(.presence | length) == 4 and any(.messages[]; .uuid == $uuid and .channel_id == 4)' "$response" >/dev/null || fail invalid_chat_updates_contract

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/reports" \
  --header "Authorization: Bearer $token_one" --data-urlencode 'reportable_type=message' --data-urlencode "reportable_id=$chat_message_id" \
  --data-urlencode 'reason=Spam' --data-urlencode 'comments=route smoke message report')
expect_status "$code" 201 report_message

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request PUT "$origin/api/v2/chat/channels/4/mark-as-read/$chat_message_id" \
  --header "Authorization: Bearer $token_one")
expect_status "$code" 200 chat_mark_read
auth_get /api/v2/chat/channels chat_channels_after_read
jq -e --argjson id "$chat_message_id" '.[3].last_message_id == $id and .[3].last_read_id == $id' "$response" >/dev/null || fail invalid_chat_read_state_contract

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request DELETE "$origin/api/v2/chat/channels/4/users/4" \
  --header "Authorization: Bearer $token_one")
expect_status "$code" 200 chat_leave

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/comments" \
  --header "Authorization: Bearer $token_one" --data-urlencode 'comment[commentable_type]=beatmapset' \
  --data-urlencode 'comment[commentable_id]=75' --data-urlencode 'comment[message]=route smoke comment')
expect_status "$code" 201 create_comment
comment_id=$(jq -er '.comments[0].id | select(. > 0)' "$response")
auth_get '/api/v2/comments?commentable_type=beatmapset&commentable_id=75&sort=new&page=1' comments
jq -e --argjson id "$comment_id" 'any(.comments[]; .id == $id and .message == "route smoke comment")' "$response" >/dev/null || fail invalid_comments_contract
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/comments/$comment_id/vote" --header "Authorization: Bearer $token_two")
expect_status "$code" 200 vote_comment
jq -e --argjson id "$comment_id" 'any(.comments[]; .id == $id and .votes_count == 1) and any(.user_votes[]; . == $id)' "$response" >/dev/null || fail invalid_comment_vote_contract
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/reports" \
  --header "Authorization: Bearer $token_two" --data-urlencode 'reportable_type=comment' --data-urlencode "reportable_id=$comment_id" \
  --data-urlencode 'reason=Spam' --data-urlencode 'comments=route smoke comment report')
expect_status "$code" 201 report_comment
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v2/reports" \
  --header "Authorization: Bearer $token_one" --data-urlencode 'reportable_type=user' --data-urlencode 'reportable_id=5' \
  --data-urlencode 'reason=Other' --data-urlencode 'comments=route smoke user report')
expect_status "$code" 201 report_user
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request DELETE "$origin/api/v2/comments/$comment_id" --header "Authorization: Bearer $token_one")
expect_status "$code" 200 delete_comment
jq -e --argjson id "$comment_id" 'any(.comments[]; .id == $id and .deleted_at != null)' "$response" >/dev/null || fail invalid_comment_delete_contract

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
jq -e '.position == 1' "$response" >/dev/null || fail invalid_client_response

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request PUT "$origin/api/v2/beatmaps/75/solo/scores/$score_token" \
  --header "Authorization: Bearer $token_one" --header 'Content-Type: application/json' --data "$score_body")
expect_status "$code" 409 reject_token_reuse

[ "$(sqlite3 "$database" "SELECT mods_json FROM lazer_scores WHERE id=$score_id")" = '[{"acronym":"RX"},{"acronym":"WIGGLE","settings":{"strength":1.25}}]' ] || fail mods_not_stored_separately
[ "$(sqlite3 "$database" "SELECT statistics_json FROM lazer_scores WHERE id=$score_id")" = '{"great":300,"miss":2}' ] || fail statistics_not_stored_separately
[ "$(sqlite3 "$database" "SELECT rank_namespace FROM lazer_scores WHERE id=$score_id")" = custom ] || fail custom_namespace_missing
[ "$(sqlite3 "$database" "SELECT total_score_without_mods FROM lazer_scores WHERE id=$score_id")" = 900000 ] || fail score_without_mods_not_stored
[ "$(sqlite3 "$database" "SELECT legacy_total_score FROM lazer_scores WHERE id=$score_id")" = 3032606 ] || fail classic_score_not_stored
[ "$(sqlite3 "$database" 'PRAGMA user_version')" = 45 ] || fail schema_not_migrated

auth_get '/api/v2/beatmaps/75/scores?type=global&mode=osu&mods%5B%5D=WIGGLE&limit=50' custom_leaderboard
jq -e --argjson id "$score_id" '
  .score_count == 1 and
  (.scores | length) == 1 and
  .scores[0].id == $id and
  .scores[0].rank == "A" and
  .scores[0].ranked == true and
  .scores[0].mods[1].acronym == "WIGGLE" and
  .scores[0].maximum_statistics.great == 302 and
  .user_score.position == 1
' "$response" >/dev/null || fail invalid_custom_leaderboard_contract

replay_base64='ANAnNQEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
vanilla_body='{"rank":"S","total_score":123456,"total_score_without_mods":123456,"accuracy":0.9,"max_combo":8,"ruleset_id":0,"passed":true,"mods":[{"acronym":"HR"}],"statistics":{"great":9,"miss":1},"maximum_statistics":{"great":10},"pauses":[],"replay":"ANAnNQEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}'
vanilla_token=$(create_score_token "$token_one")
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request PUT "$origin/api/v2/beatmaps/75/solo/scores/$vanilla_token" \
  --header "Authorization: Bearer $token_one" --header 'Content-Type: application/json' --data "$vanilla_body")
expect_status "$code" 200 submit_vanilla_score
vanilla_score_id=$(jq -er '.id | select(. > 0)' "$response")
jq -e '.position == 1' "$response" >/dev/null || fail vanilla_position_missing
[ "$(sqlite3 "$database" "SELECT abs(star_rating-1.7931)>0.0001 FROM lazer_scores WHERE id=$vanilla_score_id")" = 1 ] || fail modded_star_rating_missing

auth_get '/api/v2/beatmaps/75/scores?type=global&mode=osu&limit=50' vanilla_leaderboard
jq -e --argjson id "$vanilla_score_id" '
  .score_count == 1 and
  .scores[0].id == $id and
  .scores[0].ranked == true and
  .scores[0].mods[0].acronym == "HR" and
  .scores[0].total_score == 123456 and
  .scores[0].pp > 0 and
  .scores[0].has_replay == true and
  .user_score.score.id == $id
' "$response" >/dev/null || fail invalid_vanilla_leaderboard_contract
auth_get '/api/v2/beatmaps/75/scores?type=friend&mode=osu&limit=50' friend_leaderboard
jq -e '.score_count == 1 and .scores[0].user_id == 4 and .user_score.position == 1' "$response" >/dev/null || fail invalid_friend_leaderboard_contract
auth_get '/api/v2/beatmaps/75/scores?type=country&mode=osu&limit=50' country_leaderboard
jq -e '.score_count == 1 and .scores[0].user_id == 4 and .user_score.position == 1' "$response" >/dev/null || fail invalid_country_leaderboard_contract
auth_get '/api/v2/beatmaps/75/scores?type=team&mode=osu&limit=50' team_leaderboard_without_team
jq -e '.score_count == 0 and .scores == [] and .user_score == null' "$response" >/dev/null || fail invalid_empty_team_leaderboard_contract
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "$origin/api/v2/beatmaps/75/scores?type=local&mode=osu&limit=50" --header "Authorization: Bearer $token_one")
expect_status "$code" 400 reject_local_leaderboard_scope

auth_get "/api/v2/scores/$vanilla_score_id/download" authenticated_lazer_replay
[ "$(base64 < "$response" | tr -d '\r\n')" = "$replay_base64" ] || fail authenticated_lazer_replay_mismatch
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "$origin/replays/lazer/$vanilla_score_id")
expect_status "$code" 200 public_lazer_replay
[ "$(base64 < "$response" | tr -d '\r\n')" = "$replay_base64" ] || fail public_lazer_replay_mismatch

rx_body='{"rank":"A","total_score":223456,"total_score_without_mods":223456,"accuracy":0.92,"max_combo":9,"ruleset_id":0,"passed":true,"mods":[{"acronym":"RX"}],"statistics":{"great":9,"miss":1},"maximum_statistics":{"great":10},"pauses":[]}'
rx_token=$(create_score_token "$token_one")
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request PUT "$origin/api/v2/beatmaps/75/solo/scores/$rx_token" \
  --header "Authorization: Bearer $token_one" --header 'Content-Type: application/json' --data "$rx_body")
expect_status "$code" 200 submit_relax_score
rx_score_id=$(jq -er '.id | select(. > 0)' "$response")
auth_get '/api/v2/beatmaps/75/scores?type=global&mode=osu&mods%5B%5D=RX&limit=50' relax_leaderboard
jq -e --argjson id "$rx_score_id" '.score_count == 1 and .scores[0].id == $id and .scores[0].mods[0].acronym == "RX" and .scores[0].ranked == true and .user_score.position == 1' "$response" >/dev/null || fail invalid_relax_leaderboard_contract

ap_body='{"rank":"A","total_score":323456,"total_score_without_mods":323456,"accuracy":0.93,"max_combo":9,"ruleset_id":0,"passed":true,"mods":[{"acronym":"AP"}],"statistics":{"great":9,"miss":1},"maximum_statistics":{"great":10},"pauses":[]}'
ap_token=$(create_score_token "$token_one")
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request PUT "$origin/api/v2/beatmaps/75/solo/scores/$ap_token" \
  --header "Authorization: Bearer $token_one" --header 'Content-Type: application/json' --data "$ap_body")
expect_status "$code" 200 submit_autopilot_score
ap_score_id=$(jq -er '.id | select(. > 0)' "$response")
auth_get '/api/v2/beatmaps/75/scores?type=global&mode=osu&mods%5B%5D=AP&limit=50' autopilot_leaderboard
jq -e --argjson id "$ap_score_id" '.score_count == 1 and .scores[0].id == $id and .scores[0].mods[0].acronym == "AP" and .scores[0].ranked == true and .user_score.position == 1' "$response" >/dev/null || fail invalid_autopilot_leaderboard_contract
auth_get /api/v2/chat/channels/2/messages score_announcements
jq -e '
  length == 4 and
  all(.[]; .sender_id == 3 and .channel_id == 2 and (.content | contains("set #1 on artist - title [diff]"))) and
  any(.[]; .content | contains("[vanilla] +HR")) and
  any(.[]; .content | contains("[relax] +RX")) and
  any(.[]; .content | contains("[autopilot] +AP"))
' "$response" >/dev/null || fail invalid_score_announcement_contract

auth_get /api/v2/me/ me_after_vanilla_score
jq -e '
  .statistics_rulesets.osu.play_count == 1 and
  .statistics_rulesets.osu.play_time == 90 and
  .statistics_rulesets.osu.total_score == 12748 and
  .statistics_rulesets.osu.ranked_score == 12748 and
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
jq -e '.cursor == null and (.ranking | length) == 1 and .ranking[0].user.country_code == "AU" and .ranking[0].total_score == 12748' "$response" >/dev/null || fail invalid_score_rankings_contract
auth_get '/api/v2/rankings/osu/country?page=1' country_rankings
jq -e '.cursor == null and (.ranking | length) == 1 and .ranking[0].code == "AU" and .ranking[0].active_users == 1 and .ranking[0].play_count == 1 and .ranking[0].performance > 0' "$response" >/dev/null || fail invalid_country_rankings_contract

auth_get '/api/v2/users/4/osu?key=id' profile_after_scores
jq -e '
  .scores_best_count == 1 and
  .scores_first_count == 1 and
  .scores_recent_count == 4 and
  .scores_pinned_count == 0
' "$response" >/dev/null || fail invalid_profile_score_counts

auth_get '/api/v2/users/4/scores/best?mode=osu&offset=0&limit=50' profile_best_scores
jq -e --argjson id "$vanilla_score_id" '
  length == 1 and
  .[0].id == $id and
  .[0].ranked == true and
  .[0].mods[0].acronym == "HR" and
  .[0].beatmap.id == 75 and
  .[0].beatmap.beatmapset.artist == "artist"
' "$response" >/dev/null || fail invalid_profile_best_scores

auth_get '/api/v2/users/4/scores/recent?mode=osu&offset=0&limit=50' profile_recent_scores
jq -e --argjson custom "$score_id" --argjson vanilla "$vanilla_score_id" --argjson relax "$rx_score_id" --argjson autopilot "$ap_score_id" '
  length == 4 and
  any(.[]; .id == $custom and .ranked == true and .mods[0].acronym == "RX" and .mods[1].acronym == "WIGGLE") and
  any(.[]; .id == $relax and .ranked == true and .mods[0].acronym == "RX") and
  any(.[]; .id == $autopilot and .ranked == true and .mods[0].acronym == "AP") and
  any(.[]; .id == $vanilla and .ranked == true and .mods[0].acronym == "HR")
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

[ "$(sqlite3 "$database" 'SELECT count(*) FROM lazer_scores')" = 4 ] || fail rejected_submissions_were_stored
echo "lazer_solo_score_smoke_ok custom_score_id=$score_id vanilla_score_id=$vanilla_score_id relax_score_id=$rx_score_id autopilot_score_id=$ap_score_id"
