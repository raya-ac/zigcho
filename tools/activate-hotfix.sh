#!/bin/sh
set -eu

candidate_input=${1:-}
hotfix_root=/opt/zigcho/hotfixes
release_root=/opt/zigcho/releases
current=/opt/zigcho/current
service=zigcho.service
health_url=http://127.0.0.1:27180/health
metrics_url=http://127.0.0.1:27180/metrics
database_url=${ZIGCHO_POSTGRES_URL:-dbname=zigcho user=zigcho host=/var/run/postgresql connect_timeout=5}
backup_dir=/var/backups/zigcho
backup=
service_stopped=no
hotfix_active=no

if [ "$(id -u)" -ne 0 ]; then
  echo "hotfix activation must run as root" >&2
  exit 1
fi
case "$candidate_input" in
  "$hotfix_root"/*) ;;
  *) echo "usage: $0 /opt/zigcho/hotfixes/<commit>" >&2; exit 1 ;;
esac
candidate=$(readlink -f "$candidate_input")
case "$candidate" in
  "$hotfix_root"/*) ;;
  *) echo "candidate resolved outside the hotfix root: $candidate" >&2; exit 1 ;;
esac

for file in zigcho zigcho.sha256 pp-engine-version source.patch source.patch.sha256 hotfix.json hotfix.manifest tools/backup-postgres.sh tools/restore-postgres-drill.sh; do
  if [ ! -f "$candidate/$file" ] || [ -L "$candidate/$file" ] || [ ! -s "$candidate/$file" ]; then
    echo "hotfix candidate is missing a regular file: $file" >&2
    exit 1
  fi
done
if [ ! -x "$candidate/zigcho" ] || [ ! -x "$candidate/tools/backup-postgres.sh" ] || [ ! -x "$candidate/tools/restore-postgres-drill.sh" ]; then
  echo "hotfix candidate executables are not ready" >&2
  exit 1
fi

manifest_value() {
  key=$1
  count=$(grep -c "^$key=" "$candidate/hotfix.manifest" || true)
  [ "$count" = 1 ] || { echo "invalid hotfix manifest key: $key" >&2; return 1; }
  sed -n "s/^$key=//p" "$candidate/hotfix.manifest"
}

if [ "$(awk 'END { print NR }' "$candidate/hotfix.manifest")" != 8 ] \
  || grep -Ev '^(format|id|base_commit|target_commit|schema_version|patch_sha256|binary_sha256|pp_engine_sha256)=.*$' "$candidate/hotfix.manifest" | grep -q .; then
  echo "hotfix manifest contains unknown or duplicate data" >&2
  exit 1
fi

valid_hex() {
  value=$1
  length=$2
  [ "${#value}" -eq "$length" ] && printf '%s\n' "$value" | grep -Eq '^[0-9a-f]+$'
}

format=$(manifest_value format)
hotfix_id=$(manifest_value id)
base_commit=$(manifest_value base_commit)
target_commit=$(manifest_value target_commit)
expected_schema=$(manifest_value schema_version)
patch_sha=$(manifest_value patch_sha256)
binary_sha=$(manifest_value binary_sha256)
pp_sha=$(manifest_value pp_engine_sha256)

[ "$format" = 1 ] || { echo "unsupported hotfix manifest format: $format" >&2; exit 1; }
printf '%s\n' "$hotfix_id" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9][a-z0-9-]{2,63}$' || { echo "invalid hotfix id" >&2; exit 1; }
for value in "$base_commit" "$target_commit"; do
  valid_hex "$value" 40 || { echo "invalid hotfix commit hash" >&2; exit 1; }
done
for value in "$patch_sha" "$binary_sha" "$pp_sha"; do
  valid_hex "$value" 64 || { echo "invalid hotfix digest" >&2; exit 1; }
done
case "$expected_schema" in
  ''|*[!0-9]*) echo "invalid expected schema" >&2; exit 1 ;;
esac
[ "$(basename "$candidate")" = "$target_commit" ] || { echo "candidate directory does not match target commit" >&2; exit 1; }

(cd "$candidate" && sha256sum --check --status zigcho.sha256 && sha256sum --check --status source.patch.sha256)
[ "$(sha256sum "$candidate/zigcho" | cut -d ' ' -f1)" = "$binary_sha" ] || { echo "hotfix binary digest mismatch" >&2; exit 1; }
[ "$(sha256sum "$candidate/source.patch" | cut -d ' ' -f1)" = "$patch_sha" ] || { echo "hotfix patch digest mismatch" >&2; exit 1; }
[ "$(sha256sum "$candidate/pp-engine-version" | cut -d ' ' -f1)" = "$pp_sha" ] || { echo "hotfix PP marker digest mismatch" >&2; exit 1; }

previous=$(readlink -f "$current")
case "$previous" in
  "$release_root"/*|"$hotfix_root"/*) ;;
  *) echo "current release is not a valid rollback target: $previous" >&2; exit 1 ;;
esac
previous_name=$(basename "$previous")
if [ "${#previous_name}" -lt 7 ] || [ "${#previous_name}" -gt 40 ] || ! printf '%s\n' "$previous_name" | grep -Eq '^[0-9a-f]+$'; then
  echo "active release has no usable commit marker" >&2
  exit 1
fi
case "$base_commit" in
  "$previous_name"*) ;;
  *) echo "hotfix base is not the active commit" >&2; exit 1 ;;
esac
[ -s "$previous/pp-engine-version" ] || { echo "active PP marker is missing" >&2; exit 1; }
[ "$(sha256sum "$previous/pp-engine-version" | cut -d ' ' -f1)" = "$pp_sha" ] || { echo "hotfix changes the PP engine" >&2; exit 1; }

if command -v flock >/dev/null 2>&1; then
  exec 9>/run/zigcho-release.lock
  flock -n 9 || { echo "another Zigcho activation is running" >&2; exit 1; }
fi

restore_previous() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$hotfix_active" = no ] && [ "$service_stopped" = yes ]; then
    echo "hotfix failed; restoring $previous" >&2
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
    echo "hotfix_rolled_back failed=$candidate active=$previous" >&2
  fi
  exit "$status"
}
trap restore_previous EXIT HUP INT TERM

current_schema=$(runuser --user postgres -- psql --dbname=zigcho --tuples-only --no-align --command="SELECT max(version) FROM zigcho.schema_migrations")
[ "$current_schema" = "$expected_schema" ] || { echo "hotfix schema mismatch: live=$current_schema expected=$expected_schema" >&2; exit 1; }

install -d -m 0700 -o postgres -g postgres "$backup_dir"
runuser --user postgres -- env \
  ZIGCHO_BACKUP_DIR="$backup_dir" \
  ZIGCHO_POSTGRES_URL="dbname=zigcho host=/var/run/postgresql connect_timeout=5" \
  "$candidate/tools/backup-postgres.sh"
backup=$(find "$backup_dir" -maxdepth 1 -type f -name 'zigcho-*.dump' -print | sort | tail -n 1)
case "$backup" in
  "$backup_dir"/zigcho-*.dump) ;;
  *) echo "could not resolve the hotfix backup" >&2; exit 1 ;;
esac
runuser --user postgres -- env \
  ZIGCHO_BACKUP_DIR="$backup_dir" \
  ZIGCHO_POSTGRES_ADMIN_URL="dbname=postgres host=/var/run/postgresql connect_timeout=5" \
  ZIGCHO_EXPECTED_SCHEMA="$current_schema" \
  "$candidate/tools/restore-postgres-drill.sh" "$backup"

runuser --user zigcho -- env ZIGCHO_POSTGRES_URL="$database_url" "$candidate/zigcho" check
post_check_schema=$(runuser --user postgres -- psql --dbname=zigcho --tuples-only --no-align --command="SELECT max(version) FROM zigcho.schema_migrations")
[ "$post_check_schema" = "$current_schema" ] || { echo "hotfix candidate changed the live schema" >&2; exit 1; }

systemctl stop "$service"
service_stopped=yes
ln -sfn "$candidate" "$current"
if systemctl start "$service" \
  && curl --fail --silent --show-error --retry 10 --retry-delay 1 --retry-connrefused "$health_url" >/dev/null \
  && curl --fail --silent --show-error --retry 3 --retry-delay 1 --retry-connrefused "$metrics_url" | grep -q '^zigcho_up 1$' \
  && (cd /var/lib/zigcho && "$candidate/zigcho" object-put "backups/postgres/$(basename "$backup")" "$backup"); then
  hotfix_active=yes
  trap - EXIT HUP INT TERM
  rm -f "$backup" "$backup.sha256"
  echo "hotfix_active candidate=$candidate rollback=$previous base=$base_commit target=$target_commit backup=object local_backup_removed=true"
  exit 0
fi
false
