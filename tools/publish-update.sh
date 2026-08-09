#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: DISCORD_RELEASE_WEBHOOK=... tools/publish-update.sh updates/file.md" >&2
    exit 2
fi

if [ -z "${DISCORD_RELEASE_WEBHOOK:-}" ]; then
    echo "DISCORD_RELEASE_WEBHOOK is required" >&2
    exit 2
fi

python3 - "$1" <<'PY' | curl --fail --silent --show-error \
    -H 'Content-Type: application/json' \
    --data-binary @- \
    "$DISCORD_RELEASE_WEBHOOK"
import json
import pathlib
import sys

message = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip()
if not message:
    raise SystemExit("update is empty")
if len(message) > 2000:
    raise SystemExit(f"update is {len(message)} characters; Discord allows 2000")
print(json.dumps({"content": message}, ensure_ascii=False))
PY
