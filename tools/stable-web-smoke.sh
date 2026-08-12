#!/bin/sh
set -eu

server=${1:-./zig-out/bin/zigcho}
port=${ZIGCHO_SMOKE_PORT:-18090}
origin="http://127.0.0.1:$port"
work=$(mktemp -d "${TMPDIR:-/tmp}/zigcho-stable-web.XXXXXX")
database="$work/zigcho.db"
response="$work/response"
headers="$work/headers"
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
  echo "stable_web_smoke_failed $*" >&2
  if [ -f "$response" ]; then sed -n '1,10p' "$response" >&2; fi
  exit 1
}

expect_status() {
  actual=$1
  expected=$2
  label=$3
  [ "$actual" = "$expected" ] || fail "$label status=$actual expected=$expected"
}

"$server" 127.0.0.1 "$port" "$database" >"$server_log" 2>&1 &
server_pid=$!
attempt=0
until curl --fail --silent "$origin/health" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 50 ] || ! kill -0 "$server_pid" >/dev/null 2>&1; then
    sed -n '1,80p' "$server_log" >&2
    fail "server_not_ready"
  fi
  sleep 0.1
done

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/users" \
  --data-urlencode 'name=bad"name' --data-urlencode 'email=bad-name@example.test' --data-urlencode 'password_md5=StablePass123!')
expect_status "$code" 400 reject_unsafe_shared_name

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/users" \
  --data-urlencode 'name=staffer' --data-urlencode 'email=staffer@example.test' --data-urlencode 'password_md5=StablePass123!')
expect_status "$code" 201 register_staff
staff_id=$(jq -er '.id' "$response")

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/users" \
  --data-urlencode 'name=restricted' --data-urlencode 'email=restricted@example.test' --data-urlencode 'password_md5=StablePass123!')
expect_status "$code" 201 register_player
player_id=$(jq -er '.id' "$response")

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/users" \
  --data-urlencode 'name=social player' --data-urlencode 'email=social-player@example.test' --data-urlencode 'password_md5=00000000000000000000000000000000')
expect_status "$code" 201 register_social_player
social_player_id=$(jq -er '.id' "$response")

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/users" \
  --data-urlencode 'name=social friend' --data-urlencode 'email=social-friend@example.test' --data-urlencode 'password_md5=11111111111111111111111111111111')
expect_status "$code" 201 register_social_friend
social_friend_id=$(jq -er '.id' "$response")

sqlite3 "$database" "UPDATE users SET privileges=privileges|(1<<11)|(1<<12)|(1<<13)|(1<<14) WHERE id=$staff_id; UPDATE users SET restricted=1 WHERE id=$player_id; UPDATE users SET privileges=privileges|(1<<4) WHERE id=$social_player_id; INSERT INTO friends(user_id,friend_id) VALUES($social_player_id,$social_friend_id); INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,max_combo) VALUES(9001,9001,'90019001900190019001900190019001','smoke artist','smoke title','staff queue','mapper',2,10),(9002,9002,'90029002900290029002900290029002','ranked artist','ranked title','ranked diff','ranked mapper',3,10); INSERT INTO beatmap_rank_requests(set_id,map_id,requester_id) VALUES(9001,9001,$player_id); INSERT INTO scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,checksum,rank_namespace,best,time_elapsed) VALUES($social_player_id,'90029002900290029002900290029002',0,8,1000000,20,1,10,10,0,0,0,0,0,1,1,'smoke-score-checksum','vanilla',1,12000); INSERT INTO direct_messages(from_id,to_id,message) VALUES($social_friend_id,$social_player_id,'offline smoke hello'); INSERT INTO beatmap_archives(set_id,sha256,osz_file) VALUES(9002,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',x'6f737a20736d6f6b65');"
score_id=$(sqlite3 "$database" "SELECT id FROM scores WHERE checksum='smoke-score-checksum'")

stable_login_body="social player
00000000000000000000000000000000
b20260811|0|0|11111111111111111111111111111111:1.2.3.:22222222222222222222222222222222:33333333333333333333333333333333:44444444444444444444444444444444:|1"
code=$(curl --silent --show-error --dump-header "$headers" --output "$response" --write-out '%{http_code}' --request POST "$origin/" \
  --header 'User-Agent: osu!' --header 'CF-IPCountry: AU' --data-binary "$stable_login_body")
expect_status "$code" 200 stable_social_login
grep -qi '^osu-token: [0-9a-f]\{64\}' "$headers" || fail missing_stable_token
grep -aFq 'offline smoke hello' "$response" || fail missing_offline_mail_on_login
[ "$(sqlite3 "$database" "SELECT country FROM users WHERE id=$social_player_id")" = AU ] || fail trusted_proxy_country_not_saved

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --get "$origin/web/osu-getfriends.php" \
  --data-urlencode 'u=social player' --data-urlencode 'h=00000000000000000000000000000000')
expect_status "$code" 200 stable_get_friends
grep -qx '3' "$response" || fail missing_kai_friend
grep -qx "$social_friend_id" "$response" || fail missing_social_friend

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --get "$origin/web/osu-getfavourites.php" \
  --data-urlencode 'u=social player' --data-urlencode 'h=00000000000000000000000000000000')
expect_status "$code" 200 stable_get_empty_favourites
[ ! -s "$response" ] || fail expected_empty_favourites

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --get "$origin/web/osu-addfavourite.php" \
  --data-urlencode 'u=social player' --data-urlencode 'h=00000000000000000000000000000000' --data-urlencode 'a=9001')
expect_status "$code" 200 stable_add_favourite
grep -qx 'Added favourite!' "$response" || fail invalid_add_favourite_response

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --get "$origin/web/osu-addfavourite.php" \
  --data-urlencode 'u=social player' --data-urlencode 'h=00000000000000000000000000000000' --data-urlencode 'a=9001')
expect_status "$code" 200 stable_add_duplicate_favourite
grep -qx "You've already favourited this beatmap!" "$response" || fail invalid_duplicate_favourite_response

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --get "$origin/web/osu-getfavourites.php" \
  --data-urlencode 'u=social player' --data-urlencode 'h=00000000000000000000000000000000')
expect_status "$code" 200 stable_get_favourites
grep -qx '9001' "$response" || fail missing_favourite

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST \
  "$origin/web/osu-getbeatmapinfo.php?u=social%20player&h=00000000000000000000000000000000" \
  --data '{"Filenames":["ranked artist - ranked title (ranked mapper) [ranked diff].osu"],"Ids":[]}')
expect_status "$code" 200 stable_get_beatmap_info
grep -qx '0|9002|9002|90029002900290029002900290029002|1|XH|N|N|N' "$response" || fail invalid_stable_beatmap_info

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/web/osu-comment.php" \
  --data-urlencode 'u=social player' --data-urlencode 'p=00000000000000000000000000000000' --data-urlencode 'b=9002' \
  --data-urlencode 's=9002' --data-urlencode "r=$score_id" --data-urlencode 'm=0' --data-urlencode 'a=post' \
  --data-urlencode 'target=song' --data-urlencode 'starttime=nan' --data-urlencode 'comment=must not be stored')
expect_status "$code" 400 stable_comment_reject_non_finite_time

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/web/osu-comment.php" \
  --data-urlencode 'u=social player' --data-urlencode 'p=00000000000000000000000000000000' --data-urlencode 'b=9002' \
  --data-urlencode 's=9002' --data-urlencode "r=$score_id" --data-urlencode 'm=0' --data-urlencode 'a=post' \
  --data-urlencode 'target=song' --data-urlencode 'f=ff66aa' --data-urlencode 'starttime=12.5' --data-urlencode 'comment=stable smoke comment')
expect_status "$code" 200 stable_comment_post

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/web/osu-comment.php" \
  --data-urlencode 'u=social player' --data-urlencode 'p=00000000000000000000000000000000' --data-urlencode 'b=9002' \
  --data-urlencode 's=9002' --data-urlencode "r=$score_id" --data-urlencode 'm=0' --data-urlencode 'a=get')
expect_status "$code" 200 stable_comment_get
grep -qx '12.5.song.supporter|ff66aa.stable smoke comment' "$response" || fail invalid_stable_comment_response

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --get "$origin/web/osu-markasread.php" \
  --data-urlencode 'u=social player' --data-urlencode 'h=00000000000000000000000000000000' --data-urlencode 'channel=social friend')
expect_status "$code" 200 stable_mark_mail_read
[ "$(sqlite3 "$database" "SELECT read FROM direct_messages WHERE to_id=$social_player_id AND from_id=$social_friend_id")" = 1 ] || fail mail_not_marked_read

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "$origin/p/doyoureallywanttoaskpeppy")
expect_status "$code" 200 stable_peppy_dm_guard
grep -Fq 'blocked from being messaged' "$response" || fail invalid_peppy_dm_guard

code=$(curl --silent --show-error --dump-header "$headers" --output "$response" --write-out '%{http_code}' --request POST "$origin/difficulty-rating" --data '')
expect_status "$code" 307 stable_difficulty_redirect
grep -qi '^location: https://osu.ppy.sh/difficulty-rating' "$headers" || fail invalid_difficulty_redirect

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --get "$origin/web/bancho_connect.php" --data-urlencode 'v=b20260811')
expect_status "$code" 200 stable_bancho_connect
[ ! -s "$response" ] || fail bancho_connect_must_be_empty

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --get "$origin/web/check-updates.php" --data-urlencode 'action=check' --data-urlencode 'stream=stable')
expect_status "$code" 200 stable_check_updates
[ ! -s "$response" ] || fail check_updates_must_be_empty

code=$(curl --silent --show-error --dump-header "$headers" --output "$response" --write-out '%{http_code}' "$origin/web/maps/example.osu")
expect_status "$code" 301 stable_updated_map_redirect
grep -qi '^location: https://osu.ppy.sh/web/maps/example.osu' "$headers" || fail invalid_updated_map_redirect

code=$(curl --silent --show-error --dump-header "$headers" --output "$response" --write-out '%{http_code}' "$origin/beatmaps/9002" --header 'Host: osu.kai.ovh')
expect_status "$code" 301 stable_beatmap_link_redirect
grep -qi '^location: https://osu.ppy.sh/beatmaps/9002' "$headers" || fail invalid_beatmap_link_redirect

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "$origin/d/9002n")
expect_status "$code" 200 stable_no_video_archive
grep -qx 'osz smoke' "$response" || fail invalid_no_video_archive

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v1/appeals" \
  --header 'Origin: https://evil.test' --data-urlencode 'username=restricted' --data-urlencode 'password=StablePass123!' \
  --data-urlencode 'kind=restriction' --data-urlencode 'message=This restriction needs a manual review please.')
expect_status "$code" 403 appeal_wrong_origin

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v1/appeals" \
  --header "Origin: $origin" --data-urlencode 'username=restricted' --data-urlencode 'password=StablePass123!' \
  --data-urlencode 'kind=restriction' --data-urlencode 'message=This restriction needs a manual review please.')
expect_status "$code" 201 appeal_create
appeal_id=$(jq -er '.id' "$response")

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v1/appeals" \
  --header "Origin: $origin" --data-urlencode 'username=restricted' --data-urlencode 'password=StablePass123!' \
  --data-urlencode 'kind=restriction' --data-urlencode 'message=This duplicate appeal should be refused safely.')
expect_status "$code" 409 appeal_duplicate

code=$(curl --silent --show-error --dump-header "$headers" --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v1/staff/session" \
  --header "Origin: $origin" --data-urlencode 'username=staffer' --data-urlencode 'password=StablePass123!')
expect_status "$code" 200 staff_login
csrf=$(jq -er '.csrf' "$response")
cookie=$(sed -n 's/^set-cookie: \(__Host-kai-session=[^;]*\).*/\1/ip' "$headers" | head -n 1)
[ -n "$cookie" ] || fail missing_staff_cookie

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "$origin/api/v1/staff/overview" --header "Cookie: $cookie")
expect_status "$code" 200 staff_overview
jq -e '.open_appeals == 1 and .ranking_sets == 1 and .restricted_users == 1' "$response" >/dev/null || fail invalid_overview

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "$origin/api/v1/staff/ranking" --header "Cookie: $cookie")
expect_status "$code" 200 staff_ranking
jq -e '.queue | length == 1' "$response" >/dev/null || fail invalid_ranking_queue

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v1/staff/ranking" \
  --header "Cookie: $cookie" --header "Origin: $origin" --header 'X-CSRF-Token: wrong' \
  --data-urlencode 'set_id=9001' --data-urlencode 'action=nominate' --data-urlencode 'reason=smoke nomination')
expect_status "$code" 403 ranking_wrong_csrf

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v1/staff/ranking" \
  --header "Cookie: $cookie" --header "Origin: $origin" --header "X-CSRF-Token: $csrf" \
  --data-urlencode 'set_id=9001' --data-urlencode 'action=nominate' --data-urlencode 'reason=smoke nomination')
expect_status "$code" 200 ranking_nominate

for rank_action in love approve pending qualify rank; do
  code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v1/staff/ranking" \
    --header "Cookie: $cookie" --header "Origin: $origin" --header "X-CSRF-Token: $csrf" \
    --data-urlencode 'set_id=9001' --data-urlencode "action=$rank_action" --data-urlencode "reason=smoke direct $rank_action status")
  expect_status "$code" 200 "ranking_direct_$rank_action"
done

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "$origin/api/v1/staff/ranking" --header "Cookie: $cookie")
expect_status "$code" 200 staff_ranking_after_direct_statuses
jq -e '[.history[] | select(.set_id == 9001) | .action] | index("love") != null and index("approve") != null and index("pending") != null and index("qualify") != null and index("rank") != null' "$response" >/dev/null || fail missing_direct_ranking_history

encoded_player=$(printf '%s' 'restricted' | jq -sRr @uri)
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "$origin/api/v1/staff/moderation?user=$encoded_player" --header "Cookie: $cookie")
expect_status "$code" 200 moderation_lookup
jq -e ".user.id == $player_id and .user.restricted == true" "$response" >/dev/null || fail invalid_moderation_lookup

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v1/staff/moderation" \
  --header "Cookie: $cookie" --header "Origin: $origin" --header "X-CSRF-Token: $csrf" \
  --data-urlencode "user_id=$player_id" --data-urlencode 'action=note' --data-urlencode 'reason=reviewed by the local stable smoke')
expect_status "$code" 200 moderation_note

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "$origin/api/v1/staff/appeals" --header "Cookie: $cookie")
expect_status "$code" 200 staff_appeals
jq -e ".appeals[] | select(.id == $appeal_id and .status == \"open\")" "$response" >/dev/null || fail missing_open_appeal

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v1/staff/appeals" \
  --header "Cookie: $cookie" --header "Origin: $origin" --header "X-CSRF-Token: $csrf" \
  --data-urlencode "appeal_id=$appeal_id" --data-urlencode 'decision=accepted' --data-urlencode 'resolution=accepted for a manual account review')
expect_status "$code" 200 appeal_accept

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v1/staff/channels" \
  --header "Cookie: $cookie" --header "Origin: $origin" --header "X-CSRF-Token: $csrf" \
  --data-urlencode 'channel=#osu' --data-urlencode 'action=lock' --data-urlencode 'reason=local stable smoke')
expect_status "$code" 200 channel_lock

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v1/staff/channels" \
  --header "Cookie: $cookie" --header "Origin: $origin" --header "X-CSRF-Token: $csrf" \
  --data-urlencode 'channel=#osu' --data-urlencode 'action=unlock' --data-urlencode 'reason=local stable smoke complete')
expect_status "$code" 200 channel_unlock

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "$origin/api/v1/staff/audit" --header "Cookie: $cookie")
expect_status "$code" 200 staff_audit
jq -e '.events | length >= 5' "$response" >/dev/null || fail missing_audit_events

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "$origin/metrics")
expect_status "$code" 200 local_metrics
grep -q '^zigcho_up 1$' "$response" || fail invalid_metrics
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "$origin/metrics" --header 'Host: kai.ovh')
expect_status "$code" 404 public_metrics
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "$origin/api/v1/staff/overview" --header 'Host: api.kai.ovh' --header "Cookie: $cookie")
expect_status "$code" 404 api_staff_boundary

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request DELETE "$origin/api/v1/staff/session" \
  --header "Cookie: $cookie" --header "Origin: $origin" --header "X-CSRF-Token: $csrf")
expect_status "$code" 204 staff_logout
code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' "$origin/api/v1/staff/overview" --header "Cookie: $cookie")
expect_status "$code" 401 revoked_session

echo "stable_web_smoke_ok staff=$staff_id player=$player_id appeal=$appeal_id"
