#!/bin/sh
set -eu

backup_dir=${ZIGCHO_BACKUP_DIR:-/var/backups/zigcho}
admin_url=${ZIGCHO_POSTGRES_ADMIN_URL:-dbname=postgres}
expected_schema=${ZIGCHO_EXPECTED_SCHEMA:-16}
cd /

case "$backup_dir" in
  /var/backups/zigcho|/var/backups/zigcho/*) ;;
  *) echo "refusing unexpected backup directory: $backup_dir" >&2; exit 1 ;;
esac

backup=${1:-}
if [ -z "$backup" ]; then
  backup=$(find "$backup_dir" -maxdepth 1 -type f -name 'zigcho-*.dump' -print | sort | tail -n 1)
fi
case "$backup" in
  "$backup_dir"/zigcho-*.dump) ;;
  *) echo "refusing backup outside approved directory: $backup" >&2; exit 1 ;;
esac
if [ -z "$backup" ] || [ ! -f "$backup" ]; then
  echo "no backup found for restore drill" >&2
  exit 1
fi

if [ -f "$backup.sha256" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum --check --status "$backup.sha256"
  else
    shasum -a 256 --check "$backup.sha256" >/dev/null
  fi
fi
pg_restore --list "$backup" >/dev/null
drill_db="zigcho_restore_$(date -u +%Y%m%d%H%M%S)_$$"
case "$drill_db" in
  zigcho_restore_[0-9]*) ;;
  *) echo "invalid drill database name" >&2; exit 1 ;;
esac

cleanup() {
  dropdb --if-exists --force --maintenance-db="$admin_url" "$drill_db" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

createdb --maintenance-db="$admin_url" "$drill_db"
pg_restore --exit-on-error --no-owner --no-privileges --dbname="$drill_db" "$backup"

schema_version=$(psql --dbname="$drill_db" --tuples-only --no-align --command="SELECT max(version) FROM zigcho.schema_migrations")
invalid_indexes=$(psql --dbname="$drill_db" --tuples-only --no-align --command="SELECT count(*) FROM pg_index WHERE NOT indisvalid")
unvalidated_fks=$(psql --dbname="$drill_db" --tuples-only --no-align --command="SELECT count(*) FROM pg_constraint WHERE contype='f' AND NOT convalidated")
counts=$(psql --dbname="$drill_db" --tuples-only --no-align --field-separator=, --command="SELECT (SELECT count(*) FROM zigcho.users),(SELECT count(*) FROM zigcho.scores),(SELECT count(*) FROM zigcho.beatmaps),(SELECT count(*) FROM zigcho.audit_log)")

if [ "$schema_version" != "$expected_schema" ] || [ "$invalid_indexes" != "0" ] || [ "$unvalidated_fks" != "0" ]; then
  echo "restore_drill_failed schema=$schema_version invalid_indexes=$invalid_indexes unvalidated_fks=$unvalidated_fks" >&2
  exit 1
fi

echo "restore_drill_ok backup=$backup schema=$schema_version counts=$counts"
