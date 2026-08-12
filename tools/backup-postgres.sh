#!/bin/sh
set -eu

backup_dir=${ZIGCHO_BACKUP_DIR:-/var/backups/zigcho}
database_url=${ZIGCHO_POSTGRES_URL:-dbname=zigcho}
retention_days=${ZIGCHO_BACKUP_RETENTION_DAYS:-14}
cd /

case "$backup_dir" in
  /var/backups/zigcho|/var/backups/zigcho/*) ;;
  *) echo "refusing unexpected backup directory: $backup_dir" >&2; exit 1 ;;
esac

mkdir -p "$backup_dir"
chmod 700 "$backup_dir"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$backup_dir/.backup.lock"
  flock 9
fi
stamp=$(date -u +%Y%m%dT%H%M%SZ)
temporary=$(mktemp "$backup_dir/.zigcho-$stamp.XXXXXX.dump")
final="$backup_dir/zigcho-$stamp.dump"

cleanup() {
  if [ -f "$temporary" ]; then
    rm -f "$temporary"
  fi
}
trap cleanup EXIT HUP INT TERM

pg_dump --dbname="$database_url" --format=custom --compress=6 --no-owner --no-privileges --file="$temporary"
pg_restore --list "$temporary" >/dev/null
chmod 600 "$temporary"
mv "$temporary" "$final"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$final" >"$final.sha256"
else
  shasum -a 256 "$final" >"$final.sha256"
fi
chmod 600 "$final.sha256"
trap - EXIT HUP INT TERM

find "$backup_dir" -type f \( -name 'zigcho-*.dump' -o -name 'zigcho-*.dump.sha256' \) -mtime "+$retention_days" -delete
echo "backup_ok path=$final bytes=$(wc -c <"$final" | tr -d ' ')"
