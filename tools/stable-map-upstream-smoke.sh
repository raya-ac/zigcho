#!/bin/sh
set -eu

server=${1:-./zig-out/bin/zigcho}
port=${ZIGCHO_MAP_SMOKE_PORT:-18091}
origin="http://127.0.0.1:$port"
work=$(mktemp -d "${TMPDIR:-/tmp}/zigcho-stable-map.XXXXXX")
database="$work/zigcho.db"
response="$work/response"
archive="$work/1009839.osz"
server_log="$work/server.log"
server_pid=

case "$server" in
  /*) ;;
  *) server="$(cd "$(dirname "$server")" && pwd)/$(basename "$server")" ;;
esac

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "stable_map_upstream_smoke_failed $*" >&2
  if [ -f "$response" ]; then sed -n '1,12p' "$response" >&2; fi
  if [ -f "$server_log" ]; then tail -n 60 "$server_log" >&2; fi
  exit 1
}

(
  cd "$work"
  exec "$server" 127.0.0.1 "$port" "$database"
) >"$server_log" 2>&1 &
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
  --data-urlencode 'name=map tester' --data-urlencode 'email=map-tester@example.test' \
  --data-urlencode 'password_md5=00000000000000000000000000000000')
[ "$code" = 201 ] || fail "register status=$code"

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --get "$origin/web/osu-osz2-getscores.php" \
  --data-urlencode 'us=map tester' --data-urlencode 'ha=00000000000000000000000000000000' \
  --data-urlencode 'c=9c8d73e0d25509cb7bb2a62ca1a1934c' --data-urlencode 'i=1009839' \
  --data-urlencode 'm=0' --data-urlencode 'v=1' --data-urlencode 'mods=0')
[ "$code" = 200 ] || fail "first_leaderboard status=$code"
grep -q '^2|false|' "$response" || fail first_leaderboard_not_ranked
grep -q 'GALNERYUS - WINGS OF JUSTICE' "$response" || fail first_leaderboard_missing_metadata

attempt=0
while :; do
  ready=$(sqlite3 "$database" "SELECT count(*) FROM beatmaps WHERE id=2173528 AND set_id=1009839 AND md5='9c8d73e0d25509cb7bb2a62ca1a1934c' AND status=3 AND artist='GALNERYUS' AND title='WINGS OF JUSTICE' AND osu_file IS NOT NULL AND length(osu_file)>0;")
  archived=$(sqlite3 "$database" "SELECT count(*) FROM beatmap_archives WHERE set_id=1009839 AND length(sha256)=64 AND length(osz_file)>0;")
  if [ "$ready" = 1 ] && [ "$archived" = 1 ]; then break; fi
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 1200 ] || ! kill -0 "$server_pid" >/dev/null 2>&1; then
    fail "hydration_timeout map=$ready archive=$archived"
  fi
  sleep 0.1
done

failures=$(sqlite3 "$database" "SELECT count(*) FROM beatmap_hydration_failures;")
[ "$failures" = 0 ] || fail "hydration_failures=$failures"

code=$(curl --silent --show-error --output "$archive" --write-out '%{http_code}' "$origin/d/1009839")
[ "$code" = 200 ] || fail "archive_download status=$code"
[ "$(dd if="$archive" bs=2 count=1 2>/dev/null)" = PK ] || fail invalid_archive_signature

code=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' --get "$origin/web/osu-osz2-getscores.php" \
  --data-urlencode 'us=map tester' --data-urlencode 'ha=00000000000000000000000000000000' \
  --data-urlencode 'c=9c8d73e0d25509cb7bb2a62ca1a1934c' --data-urlencode 'i=1009839' \
  --data-urlencode 'm=0' --data-urlencode 'v=1' --data-urlencode 'mods=0')
[ "$code" = 200 ] || fail "hydrated_leaderboard status=$code"
grep -q '^2|false|2173528|1009839|' "$response" || fail hydrated_leaderboard_contract
grep -q 'GALNERYUS - WINGS OF JUSTICE' "$response" || fail hydrated_leaderboard_missing_metadata
grep -q '\[FLYING TOWARDS JUSTICE\]' "$response" || fail hydrated_leaderboard_missing_difficulty

echo "stable_map_upstream_smoke_ok map=2173528 set=1009839 status=ranked"
