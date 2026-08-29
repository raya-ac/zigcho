#!/bin/sh
set -eu

release=${1:-}
release_root=/opt/zigcho/releases
hotfix_root=/opt/zigcho/hotfixes
current=/opt/zigcho/current
service=zigcho.service
health_url=http://127.0.0.1:27180/health
metrics_url=http://127.0.0.1:27180/metrics
database_url=${ZIGCHO_POSTGRES_URL:-dbname=zigcho user=zigcho host=/var/run/postgresql connect_timeout=5}
backup_dir=/var/backups/zigcho
backup=
service_stopped=no
release_active=no

case "$release" in
  "$release_root"/*) ;;
  *) echo "usage: $0 /opt/zigcho/releases/<commit>" >&2; exit 1 ;;
esac
if [ ! -x "$release/zigcho" ] || [ ! -s "$release/pp-engine-version" ] || [ ! -x "$release/tools/backup-postgres.sh" ] || [ ! -x "$release/tools/restore-postgres-drill.sh" ]; then
  echo "candidate release is incomplete: $release" >&2
  exit 1
fi

candidate=$(readlink -f "$release")
case "$candidate" in
  "$release_root"/*) ;;
  *) echo "candidate resolved outside release root: $candidate" >&2; exit 1 ;;
esac

previous=$(readlink -f "$current")
case "$previous" in
  "$release_root"/*|"$hotfix_root"/*) ;;
  *) echo "current release is not a valid rollback target: $previous" >&2; exit 1 ;;
esac
candidate_pp=$(sed -n '1p' "$candidate/pp-engine-version")
previous_pp=legacy-akatsuki
if [ -s "$previous/pp-engine-version" ]; then
  previous_pp=$(sed -n '1p' "$previous/pp-engine-version")
fi
[ -n "$candidate_pp" ] || { echo "empty pp engine marker" >&2; exit 1; }
case "$candidate_pp:$previous_pp" in
  *[!A-Za-z0-9._:-]*) echo "invalid pp engine marker" >&2; exit 1 ;;
esac

if command -v flock >/dev/null 2>&1; then
  exec 9>/run/zigcho-release.lock
  flock -n 9 || { echo "another Zigcho activation is running" >&2; exit 1; }
fi

restore_previous() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$release_active" = "no" ] && [ "$service_stopped" = "yes" ]; then
    echo "candidate failed; restoring $previous" >&2
    systemctl stop "$service" >/dev/null 2>&1 || true
    ln -sfn "$previous" "$current"
    if [ -n "$backup" ] && [ -f "$backup" ]; then
      runuser --user postgres -- dropdb --if-exists --force zigcho
      runuser --user postgres -- createdb --owner=zigcho zigcho
      runuser --user postgres -- pg_restore \
        --exit-on-error \
        --no-owner \
        --no-privileges \
        --role=zigcho \
        --dbname=zigcho \
        "$backup"
    fi
    systemctl start "$service"
    curl --fail --silent --show-error --retry 10 --retry-delay 1 --retry-connrefused "$health_url" >/dev/null
    echo "release_rolled_back failed=$candidate active=$previous" >&2
  fi
  exit "$status"
}
trap restore_previous EXIT HUP INT TERM

install -d -m 0700 -o postgres -g postgres "$backup_dir"
current_schema=$(runuser --user postgres -- psql --dbname=zigcho --tuples-only --no-align --command="SELECT max(version) FROM zigcho.schema_migrations")
case "$current_schema" in
  ''|*[!0-9]*) echo "invalid current schema version: $current_schema" >&2; exit 1 ;;
esac

runuser --user postgres -- env \
  ZIGCHO_BACKUP_DIR="$backup_dir" \
  ZIGCHO_POSTGRES_URL="dbname=zigcho host=/var/run/postgresql connect_timeout=5" \
  "$candidate/tools/backup-postgres.sh"
backup=$(find "$backup_dir" -maxdepth 1 -type f -name 'zigcho-*.dump' -print | sort | tail -n 1)
case "$backup" in
  "$backup_dir"/zigcho-*.dump) ;;
  *) echo "could not resolve the release backup" >&2; exit 1 ;;
esac
runuser --user postgres -- env \
  ZIGCHO_BACKUP_DIR="$backup_dir" \
  ZIGCHO_POSTGRES_ADMIN_URL="dbname=postgres host=/var/run/postgresql connect_timeout=5" \
  ZIGCHO_EXPECTED_SCHEMA="$current_schema" \
  "$candidate/tools/restore-postgres-drill.sh" "$backup"
systemctl stop "$service"
service_stopped=yes
runuser --user zigcho -- env ZIGCHO_POSTGRES_URL="$database_url" "$candidate/zigcho" check
recalculated=no
if [ "$candidate_pp" != "$previous_pp" ] || [ "$current_schema" -lt 29 ]; then
  runuser --user zigcho -- env ZIGCHO_POSTGRES_URL="$database_url" "$candidate/zigcho" recalc
  recalculated=yes
fi
ln -sfn "$candidate" "$current"
if systemctl start "$service" \
  && curl --fail --silent --show-error --retry 10 --retry-delay 1 --retry-connrefused "$health_url" >/dev/null \
  && curl --fail --silent --show-error --retry 3 --retry-delay 1 --retry-connrefused "$metrics_url" | grep -q '^zigcho_up 1$' \
  && (cd /var/lib/zigcho && "$candidate/zigcho" object-put "backups/postgres/$(basename "$backup")" "$backup"); then
  release_active=yes
  trap - EXIT HUP INT TERM
  rm -f "$backup" "$backup.sha256"
  echo "release_active candidate=$candidate rollback=$previous pp_engine=$candidate_pp recalculated=$recalculated backup=object local_backup_removed=true"
  exit 0
fi
false
