#!/bin/sh
set -eu

release=${1:-}
release_root=/opt/zigcho/releases
current=/opt/zigcho/current
service=zigcho.service
health_url=http://127.0.0.1:27180/health
metrics_url=http://127.0.0.1:27180/metrics
database_url=${ZIGCHO_POSTGRES_URL:-dbname=zigcho user=zigcho host=/var/run/postgresql connect_timeout=5}
backup_dir=/var/backups/zigcho

case "$release" in
  "$release_root"/*) ;;
  *) echo "usage: $0 /opt/zigcho/releases/<commit>" >&2; exit 1 ;;
esac
if [ ! -x "$release/zigcho" ] || [ ! -x "$release/tools/backup-postgres.sh" ] || [ ! -x "$release/tools/restore-postgres-drill.sh" ]; then
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
  "$release_root"/*) ;;
  *) echo "current release is not a valid rollback target: $previous" >&2; exit 1 ;;
esac

install -d -m 0700 -o postgres -g postgres "$backup_dir"
runuser --user postgres -- env \
  ZIGCHO_BACKUP_DIR="$backup_dir" \
  ZIGCHO_POSTGRES_URL="dbname=zigcho host=/var/run/postgresql connect_timeout=5" \
  "$candidate/tools/backup-postgres.sh"
runuser --user postgres -- env \
  ZIGCHO_BACKUP_DIR="$backup_dir" \
  ZIGCHO_POSTGRES_ADMIN_URL="dbname=postgres host=/var/run/postgresql connect_timeout=5" \
  "$candidate/tools/restore-postgres-drill.sh"
runuser --user zigcho -- env ZIGCHO_POSTGRES_URL="$database_url" "$candidate/zigcho" check
ln -sfn "$candidate" "$current"
if systemctl restart "$service" \
  && curl --fail --silent --show-error --retry 10 --retry-delay 1 --retry-connrefused "$health_url" >/dev/null \
  && curl --fail --silent --show-error --retry 3 --retry-delay 1 --retry-connrefused "$metrics_url" | grep -q '^zigcho_up 1$'; then
  echo "release_active candidate=$candidate rollback=$previous"
  exit 0
fi

echo "candidate failed health check; restoring $previous" >&2
ln -sfn "$previous" "$current"
systemctl restart "$service"
curl --fail --silent --show-error --retry 10 --retry-delay 1 --retry-connrefused "$health_url" >/dev/null
echo "release_rolled_back failed=$candidate active=$previous" >&2
exit 1
