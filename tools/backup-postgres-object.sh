#!/bin/sh
set -eu

backup_dir=${ZIGCHO_BACKUP_DIR:-/var/backups/zigcho}
database_url=${ZIGCHO_POSTGRES_URL:-dbname=zigcho}
admin_url=${ZIGCHO_POSTGRES_ADMIN_URL:-dbname=postgres}
expected_schema=${ZIGCHO_EXPECTED_SCHEMA:-}
current=/opt/zigcho/current
[ -x "$current/tools/backup-transfer.sh" ] || { echo "backup transport is missing" >&2; exit 1; }
command -v rclone >/dev/null || { echo "backup transport requires rclone" >&2; exit 1; }

if [ -z "$expected_schema" ]; then
  expected_schema=$(runuser --user postgres -- \
    psql --dbname="$database_url" --tuples-only --no-align \
    --command="SELECT max(version) FROM zigcho.schema_migrations")
fi
case "$expected_schema" in
  ''|*[!0-9]*) echo "could not resolve the live schema version" >&2; exit 1 ;;
esac

runuser --user postgres -- env \
  ZIGCHO_BACKUP_DIR="$backup_dir" \
  ZIGCHO_POSTGRES_URL="$database_url" \
  "$current/tools/backup-postgres.sh"

backup=$(find "$backup_dir" -maxdepth 1 -type f -name 'zigcho-*.dump' -print | sort | tail -n 1)
case "$backup" in
  "$backup_dir"/zigcho-*.dump) ;;
  *) echo "could not resolve backup for object upload" >&2; exit 1 ;;
esac

runuser --user postgres -- env \
  ZIGCHO_BACKUP_DIR="$backup_dir" \
  ZIGCHO_POSTGRES_ADMIN_URL="$admin_url" \
  ZIGCHO_EXPECTED_SCHEMA="$expected_schema" \
  "$current/tools/restore-postgres-drill.sh" "$backup"

name=$(basename "$backup")
"$current/tools/backup-transfer.sh" put "backups/postgres/$name" "$backup"
rm -f "$backup" "$backup.sha256"
echo "backup_object_ok key=backups/postgres/$name local_removed=true"
