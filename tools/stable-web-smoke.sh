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
  --data-urlencode 'name=staffer' --data-urlencode 'email=staffer@example.test' --data-urlencode 'password_md5=StablePass123!')
expect_status "$code" 201 register_staff
staff_id=$(jq -er '.id' "$response")

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/users" \
  --data-urlencode 'name=restricted player' --data-urlencode 'email=restricted@example.test' --data-urlencode 'password_md5=StablePass123!')
expect_status "$code" 201 register_player
player_id=$(jq -er '.id' "$response")

sqlite3 "$database" "UPDATE users SET privileges=privileges|(1<<11)|(1<<12)|(1<<13)|(1<<14) WHERE id=$staff_id; UPDATE users SET restricted=1 WHERE id=$player_id; INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,max_combo) VALUES(9001,9001,'90019001900190019001900190019001','smoke artist','smoke title','staff queue','mapper',2,10); INSERT INTO beatmap_rank_requests(set_id,map_id,requester_id) VALUES(9001,9001,$player_id);"

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v1/appeals" \
  --header 'Origin: https://evil.test' --data-urlencode 'username=restricted player' --data-urlencode 'password=StablePass123!' \
  --data-urlencode 'kind=restriction' --data-urlencode 'message=This restriction needs a manual review please.')
expect_status "$code" 403 appeal_wrong_origin

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v1/appeals" \
  --header "Origin: $origin" --data-urlencode 'username=restricted player' --data-urlencode 'password=StablePass123!' \
  --data-urlencode 'kind=restriction' --data-urlencode 'message=This restriction needs a manual review please.')
expect_status "$code" 201 appeal_create
appeal_id=$(jq -er '.id' "$response")

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --request POST "$origin/api/v1/appeals" \
  --header "Origin: $origin" --data-urlencode 'username=restricted player' --data-urlencode 'password=StablePass123!' \
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

encoded_player=$(printf '%s' 'restricted player' | jq -sRr @uri)
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
