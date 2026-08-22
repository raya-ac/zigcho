#!/bin/sh
set -eu

backup_dir=${ZIGCHO_BACKUP_DIR:-/var/backups/zigcho}
database_url=${ZIGCHO_POSTGRES_URL:-dbname=zigcho}
admin_url=${ZIGCHO_POSTGRES_ADMIN_URL:-dbname=postgres}
expected_schema=${ZIGCHO_EXPECTED_SCHEMA:-32}
current=/opt/zigcho/current

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
(cd /var/lib/zigcho && "$current/zigcho" object-put "backups/postgres/$name" "$backup")
rm -f "$backup" "$backup.sha256"
echo "backup_object_ok key=backups/postgres/$name local_removed=true"
