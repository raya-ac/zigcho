#!/bin/sh
# Backup transport only. Game uploads continue to use the server's object API.
set +x
set -eu

mode=${1:-}
key=${2:-}
file=${3:-}
config=${ZIGCHO_BACKUP_CONFIG:-/var/lib/zigcho/config.ini}
temporary=
temporary_dir=
cleanup() {
  if [ -n "$temporary_dir" ]; then
    # This directory was created by this invocation and contains only its
    # credentials, response headers and temporary backup parts.
    find "$temporary_dir" -mindepth 1 -maxdepth 1 -type f -delete
    rmdir "$temporary_dir"
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

[ "$#" = 3 ] || { echo 'usage: backup-transfer.sh put|get backups/postgres/<name>.dump /absolute/file' >&2; exit 1; }
case "$mode" in put|get) ;; *) echo 'invalid backup operation' >&2; exit 1;; esac
printf '%s\n' "$key" | grep -Eq '^backups/postgres/zigcho-[0-9]{8}T[0-9]{6}Z\.dump$' || { echo 'invalid backup key' >&2; exit 1; }
case "$file" in /*) ;; *) echo 'backup file must be absolute' >&2; exit 1;; esac
command -v rclone >/dev/null || { echo 'backup transfer requires rclone 1.60 or later' >&2; exit 1; }
command -v curl >/dev/null || { echo 'backup transfer requires curl with AWS SigV4 support' >&2; exit 1; }
command -v timeout >/dev/null || { echo 'backup transfer requires timeout' >&2; exit 1; }
[ -r "$config" ] || { echo 'backup configuration is unreadable' >&2; exit 1; }

# Read literal values, never source/eval configuration or put credentials in argv.
setting() {
  awk -v wanted="$1" '
    /^[[:space:]]*[#;]/ {next}
    {at=index($0,"="); if(!at) next; key=substr($0,1,at-1); gsub(/^[[:space:]]+|[[:space:]]+$/,"",key);
     if(key==wanted) {value=substr($0,at+1); gsub(/^[[:space:]]+|[[:space:]]+$/,"",value); found=1}}
    END {if(found) print value; else exit 1}' "$config"
}
RCLONE_CONFIG_ZIGCHOBACKUP_TYPE=s3
RCLONE_CONFIG_ZIGCHOBACKUP_PROVIDER=Other
RCLONE_CONFIG_ZIGCHOBACKUP_ENDPOINT=$(setting object_storage_endpoint)
RCLONE_CONFIG_ZIGCHOBACKUP_ACCESS_KEY_ID=$(setting object_storage_access_key_id)
RCLONE_CONFIG_ZIGCHOBACKUP_SECRET_ACCESS_KEY=$(setting object_storage_secret_access_key)
RCLONE_CONFIG_ZIGCHOBACKUP_REGION=$(setting object_storage_region || printf auto)
bucket=$(setting object_storage_bucket)
[ -n "$bucket" ] && [ -n "$RCLONE_CONFIG_ZIGCHOBACKUP_ACCESS_KEY_ID" ] && [ -n "$RCLONE_CONFIG_ZIGCHOBACKUP_SECRET_ACCESS_KEY" ] || { echo 'backup storage is not configured' >&2; exit 1; }
case "$bucket" in *[!A-Za-z0-9._-]*) echo 'invalid backup bucket' >&2; exit 1;; esac
case "$RCLONE_CONFIG_ZIGCHOBACKUP_ENDPOINT" in https://*) ;; *) echo 'backup storage requires HTTPS' >&2; exit 1;; esac
export RCLONE_CONFIG_ZIGCHOBACKUP_TYPE RCLONE_CONFIG_ZIGCHOBACKUP_PROVIDER RCLONE_CONFIG_ZIGCHOBACKUP_ENDPOINT RCLONE_CONFIG_ZIGCHOBACKUP_ACCESS_KEY_ID RCLONE_CONFIG_ZIGCHOBACKUP_SECRET_ACCESS_KEY RCLONE_CONFIG_ZIGCHOBACKUP_REGION
remote="zigchobackup:$bucket/$key"

transfer() {
  stage=$1
  shift
  echo "backup_transfer_started stage=$stage"
  # Bounded multipart upload. Do not leak provider errors,
  # signed URLs or credentials into release logs.
  if timeout --kill-after=10s 330s rclone --config /dev/null "$@" \
      --s3-no-check-bucket --bind 0.0.0.0 --buffer-size 256k --transfers 1 --timeout 45s --contimeout 10s \
      --retries 2 --low-level-retries 2 --max-duration 5m --log-level ERROR >/dev/null 2>&1; then
    echo "backup_transfer_finished stage=$stage"
  else
    status=$?
    echo "backup_transfer_failed stage=$stage exit=$status" >&2
    exit "$status"
  fi
}

if [ "$mode" = put ]; then
  [ -f "$file" ] && [ ! -L "$file" ] || { echo 'backup source must be a regular file' >&2; exit 1; }
  bytes=$(wc -c <"$file" | tr -d ' ')
  [ "$bytes" -gt 0 ] && [ "$bytes" -le 2147483648 ] || { echo 'backup size outside supported bounds' >&2; exit 1; }
  expected=$(sha256sum "$file" | cut -d ' ' -f1)
  transfer upload copyto "$file" "$remote" --immutable --s3-upload-cutoff 8M --s3-chunk-size 8M --s3-upload-concurrency 4
else
  [ ! -e "$file" ] && [ ! -L "$file" ] || { echo 'backup destination already exists' >&2; exit 1; }
fi

# A real full-byte readback, never just HEAD, an ETag or the ends of the dump.
temporary_dir=$(mktemp -d "$(dirname "$file")/.zigcho-transfer.XXXXXX")
temporary="$temporary_dir/download.dump"
umask 077
base="$temporary_dir/request.conf"
curl_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}
curl_setting() {
  escaped=$(curl_escape "$2")
  printf '%s = "%s"\n' "$1" "$escaped" >>"$base"
}
curl_setting url "${RCLONE_CONFIG_ZIGCHOBACKUP_ENDPOINT%/}/$bucket/$key"
curl_setting aws-sigv4 "aws:amz:$RCLONE_CONFIG_ZIGCHOBACKUP_REGION:s3"
curl_setting user "$RCLONE_CONFIG_ZIGCHOBACKUP_ACCESS_KEY_ID:$RCLONE_CONFIG_ZIGCHOBACKUP_SECRET_ACCESS_KEY"
curl_setting header 'Accept-Encoding: identity'
printf 'http1.1\nipv4\nsilent\nshow-error\nfail\nconnect-timeout = 10\nmax-time = 45\nretry = 2\nretry-all-errors\nretry-delay = 1\n' >>"$base"

echo 'backup_transfer_started stage=download'
status=$(timeout --kill-after=10s 150s curl --config "$base" --head --dump-header "$temporary_dir/headers" --output /dev/null --write-out '%{http_code}' 2>/dev/null) || { echo 'backup metadata request failed' >&2; exit 1; }
[ "$status" = 200 ] || { echo 'backup metadata status rejected' >&2; exit 1; }
length=$(awk '/^HTTP\// {count=0;value=""} tolower($1)=="content-length:" {gsub(/\r/,"",$2);value=$2;count++} END {if(count==1)print value}' "$temporary_dir/headers")
etag=$(awk '/^HTTP\// {count=0;value=""} tolower($1)=="etag:" {sub(/^[^:]*:[[:space:]]*/,"");sub(/\r$/,"");value=$0;count++} END {if(count==1)print value}' "$temporary_dir/headers")
case "$length" in ''|*[!0-9]*) echo 'invalid backup length' >&2; exit 1;; esac
[ "$length" -gt 0 ] && [ "$length" -le 2147483648 ] || { echo 'backup length outside supported bounds' >&2; exit 1; }
printf '%s\n' "$etag" | grep -Eq '^"[A-Za-z0-9-]{1,128}"$' || { echo 'invalid backup ETag' >&2; exit 1; }
curl_setting header "If-Match: $etag"
chunk=262144
parts=$(((length + chunk - 1) / chunk))
requests="$temporary_dir/ranges.conf"
index=0
while [ "$index" -lt "$parts" ]; do
  start=$((index * chunk))
  end=$((start + chunk - 1))
  [ "$end" -lt "$length" ] || end=$((length - 1))
  [ "$index" = 0 ] || printf 'next\n'
  cat "$base"
  printf 'range = "%s-%s"\nmax-filesize = %s\noutput = "%s"\nwrite-out = "%%{http_code}\\n"\n' "$start" "$end" "$((end - start + 1))" "$(curl_escape "$temporary_dir/part-$index")"
  index=$((index + 1))
done >"$requests"
# Small requests bound slow tails. One curl process, at most 64 active
# requests, and a 330-second overall cap; no unbounded process fan-out.
if timeout --kill-after=10s 330s curl --config "$requests" --parallel --parallel-immediate --parallel-max 64 --fail-early >"$temporary_dir/statuses" 2>/dev/null; then
  :
else
  status=$?
  echo "backup_transfer_failed stage=ranges exit=$status" >&2
  exit "$status"
fi
[ "$(wc -l <"$temporary_dir/statuses" | tr -d ' ')" = "$parts" ] && ! grep -qv '^206$' "$temporary_dir/statuses" || { echo 'backup range status rejected' >&2; exit 1; }
: >"$temporary"
index=0
while [ "$index" -lt "$parts" ]; do
  expected_length=$chunk
  remaining=$((length - index * chunk))
  [ "$remaining" -ge "$chunk" ] || expected_length=$remaining
  part="$temporary_dir/part-$index"
  [ "$(wc -c <"$part" | tr -d ' ')" = "$expected_length" ] || { echo 'backup range length rejected' >&2; exit 1; }
  cat "$part" >>"$temporary"
  rm -f "$part"
  index=$((index + 1))
done
echo 'backup_transfer_finished stage=download'
downloaded=$(wc -c <"$temporary" | tr -d ' ')
[ "$downloaded" -gt 0 ] && [ "$downloaded" -le 2147483648 ] || { echo 'downloaded backup size outside supported bounds' >&2; exit 1; }
actual=$(sha256sum "$temporary" | cut -d ' ' -f1)
if [ "$mode" = put ]; then
  [ "$downloaded" = "$bytes" ] && [ "$actual" = "$expected" ] || { echo 'backup byte verification failed; local source retained' >&2; exit 1; }
  echo "backup_transfer_verified bytes=$bytes sha256=$actual"
else
  # Atomic no-clobber publication. Existing recovery files are never overwritten.
  ln "$temporary" "$file"
  echo "backup_transfer_downloaded bytes=$downloaded sha256=$actual"
fi
