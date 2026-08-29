#!/bin/sh
set -eu

mode=${1:-}
previous_input=${2:-}
backup_key=${3:-}
expected_schema=${4:-}
expected_sha256=${5:-}
release_root=/opt/zigcho/releases
hotfix_root=/opt/zigcho/hotfixes
current=/opt/zigcho/current
service=zigcho.service
health_url=http://127.0.0.1:27180/health
metrics_url=http://127.0.0.1:27180/metrics
backup_dir=/var/backups/zigcho
rollback_backup=
forward_backup=
forward_key=
forward_sha256=
service_stopped=no
rollback_complete=no

if [ "$(id -u)" -ne 0 ]; then
  echo "release rollback must run as root" >&2
  exit 1
fi
case "$mode" in
  check|apply) ;;
  *) echo "usage: $0 check|apply /opt/zigcho/releases/<commit> backups/postgres/zigcho-<stamp>.dump <schema> <sha256>" >&2; exit 1 ;;
esac
case "$previous_input" in
  "$release_root"/*|"$hotfix_root"/*) ;;
  *) echo "rollback release is outside the release roots" >&2; exit 1 ;;
esac
previous=$(readlink -f "$previous_input")
case "$previous" in
  "$release_root"/*|"$hotfix_root"/*) ;;
  *) echo "rollback release resolved outside the release roots" >&2; exit 1 ;;
esac
[ -x "$previous/zigcho" ] || { echo "rollback executable is missing" >&2; exit 1; }
current_release=$(readlink -f "$current")
case "$current_release" in
  "$release_root"/*|"$hotfix_root"/*) ;;
  *) echo "current release resolved outside the release roots" >&2; exit 1 ;;
esac
[ "$current_release" != "$previous" ] || { echo "rollback target is already active" >&2; exit 1; }
[ -x "$current_release/zigcho" ] || { echo "current executable is missing" >&2; exit 1; }
script_path=$(readlink -f "$0")
script_dir=$(dirname "$script_path")
tool_release=$(dirname "$script_dir")
case "$tool_release" in
  "$release_root"/*|"$hotfix_root"/*) ;;
  *) echo "rollback tool resolved outside the release roots" >&2; exit 1 ;;
esac
[ -x "$tool_release/zigcho" ] || { echo "rollback tool executable is missing" >&2; exit 1; }
[ -x "$tool_release/tools/backup-postgres.sh" ] || { echo "rollback backup tool is missing" >&2; exit 1; }
[ -x "$tool_release/tools/restore-postgres-drill.sh" ] || { echo "rollback restore drill is missing" >&2; exit 1; }

case "$backup_key" in
  backups/postgres/zigcho-*.dump) ;;
  *) echo "invalid rollback object key" >&2; exit 1 ;;
esac
backup_name=${backup_key#backups/postgres/}
printf '%s\n' "$backup_name" | grep -Eq '^zigcho-[0-9]{8}T[0-9]{6}Z\.dump$' || { echo "invalid rollback backup name" >&2; exit 1; }
case "$expected_schema" in
  ''|*[!0-9]*) echo "invalid rollback schema" >&2; exit 1 ;;
esac
printf '%s\n' "$expected_sha256" | grep -Eq '^[0-9a-f]{64}$' || { echo "invalid rollback digest" >&2; exit 1; }

if command -v flock >/dev/null 2>&1; then
  exec 9>/run/zigcho-release.lock
  flock -n 9 || { echo "another Zigcho release operation is running" >&2; exit 1; }
fi

install -d -m 0700 -o postgres -g postgres "$backup_dir"
rollback_backup="$backup_dir/zigcho-rollback-$(date -u +%Y%m%dT%H%M%SZ)-$$.dump"
case "$rollback_backup" in
  "$backup_dir"/zigcho-rollback-*.dump) ;;
  *) echo "could not resolve rollback staging path" >&2; exit 1 ;;
esac
[ ! -e "$rollback_backup" ] || { echo "rollback staging path already exists" >&2; exit 1; }

cleanup_files() {
  [ -z "$rollback_backup" ] || rm -f "$rollback_backup"
  [ -z "$forward_backup" ] || rm -f "$forward_backup" "$forward_backup.sha256"
}
trap cleanup_files EXIT HUP INT TERM

(cd /var/lib/zigcho && "$tool_release/zigcho" object-get "$backup_key" "$rollback_backup")
chown postgres:postgres "$rollback_backup"
chmod 600 "$rollback_backup"
actual_sha256=$(sha256sum "$rollback_backup" | cut -d ' ' -f1)
[ "$actual_sha256" = "$expected_sha256" ] || { echo "rollback object digest mismatch" >&2; exit 1; }
runuser --user postgres -- env \
  ZIGCHO_BACKUP_DIR="$backup_dir" \
  ZIGCHO_POSTGRES_ADMIN_URL="dbname=postgres host=/var/run/postgresql connect_timeout=5" \
  ZIGCHO_EXPECTED_SCHEMA="$expected_schema" \
  ZIGCHO_CHECK_BINARY="$previous/zigcho" \
  "$tool_release/tools/restore-postgres-drill.sh" "$rollback_backup"

if [ "$mode" = check ]; then
  echo "rollback_check_ok release=$previous schema=$expected_schema backup=$backup_key sha256=$expected_sha256"
  exit 0
fi

current_schema=$(runuser --user postgres -- psql --dbname=zigcho --tuples-only --no-align --command="SELECT max(version) FROM zigcho.schema_migrations")
case "$current_schema" in
  ''|*[!0-9]*) echo "invalid current schema version" >&2; exit 1 ;;
esac
forward_output=$(runuser --user postgres -- env \
  ZIGCHO_BACKUP_DIR="$backup_dir" \
  ZIGCHO_POSTGRES_URL="dbname=zigcho host=/var/run/postgresql connect_timeout=5" \
  "$tool_release/tools/backup-postgres.sh")
printf '%s\n' "$forward_output"
forward_backup=$(printf '%s\n' "$forward_output" | sed -n 's/^backup_ok path=\([^ ]*\) bytes=[0-9][0-9]*$/\1/p')
case "$forward_backup" in
  "$backup_dir"/zigcho-*.dump) ;;
  *) echo "could not resolve forward-recovery backup" >&2; exit 1 ;;
esac
[ -f "$forward_backup" ] || { echo "forward-recovery backup is missing" >&2; exit 1; }
runuser --user postgres -- env \
  ZIGCHO_BACKUP_DIR="$backup_dir" \
  ZIGCHO_POSTGRES_ADMIN_URL="dbname=postgres host=/var/run/postgresql connect_timeout=5" \
  ZIGCHO_EXPECTED_SCHEMA="$current_schema" \
  "$tool_release/tools/restore-postgres-drill.sh" "$forward_backup"
forward_key="backups/postgres/$(basename "$forward_backup")"
forward_sha256=$(sha256sum "$forward_backup" | cut -d ' ' -f1)
printf '%s\n' "$forward_sha256" | grep -Eq '^[0-9a-f]{64}$' || { echo "invalid forward-recovery digest" >&2; exit 1; }
(cd /var/lib/zigcho && "$tool_release/zigcho" object-put "$forward_key" "$forward_backup")

restore_current() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$rollback_complete" = no ] && [ "$service_stopped" = yes ]; then
    echo "rollback failed; restoring $current_release" >&2
    systemctl stop "$service" >/dev/null 2>&1 || true
    runuser --user postgres -- dropdb --if-exists --force zigcho
    runuser --user postgres -- createdb --owner=zigcho zigcho
    runuser --user postgres -- pg_restore \
      --exit-on-error \
      --no-owner \
      --no-privileges \
      --role=zigcho \
      --dbname=zigcho \
      "$forward_backup"
    ln -sfn "$current_release" "$current"
    systemctl start "$service"
    curl --fail --silent --show-error --retry 10 --retry-delay 1 --retry-connrefused "$health_url" >/dev/null
  fi
  cleanup_files
  exit "$status"
}
trap restore_current EXIT HUP INT TERM

systemctl stop "$service"
service_stopped=yes
runuser --user postgres -- dropdb --if-exists --force zigcho
runuser --user postgres -- createdb --owner=zigcho zigcho
runuser --user postgres -- pg_restore \
  --exit-on-error \
  --no-owner \
  --no-privileges \
  --role=zigcho \
  --dbname=zigcho \
  "$rollback_backup"
ln -sfn "$previous" "$current"
systemctl start "$service"
curl --fail --silent --show-error --retry 10 --retry-delay 1 --retry-connrefused "$health_url" >/dev/null
curl --fail --silent --show-error --retry 3 --retry-delay 1 --retry-connrefused "$metrics_url" | grep -q '^zigcho_up 1$'
rollback_complete=yes
trap - EXIT HUP INT TERM
cleanup_files
echo "release_rollback_active release=$previous schema=$expected_schema restored=$backup_key forward_release=$current_release forward_schema=$current_schema forward_backup=$forward_key forward_sha256=$forward_sha256 forward_tool=$tool_release/tools/rollback-release.sh"
