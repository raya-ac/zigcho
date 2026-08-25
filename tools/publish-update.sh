#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: DISCORD_RELEASE_WEBHOOK=... tools/publish-update.sh updates/file.md" >&2
    exit 2
fi

update=$1
if [ ! -f "$update" ] || [ ! -s "$update" ]; then
    echo "update is missing or empty: $update" >&2
    exit 2
fi
if [ "$(wc -c < "$update")" -gt 100000 ]; then
    echo "update is too large for the release webhook" >&2
    exit 2
fi
if [ -z "${DISCORD_RELEASE_WEBHOOK:-}" ] && [ "${DISCORD_DRY_RUN:-0}" != 1 ]; then
    echo "DISCORD_RELEASE_WEBHOOK is required" >&2
    exit 2
fi

payload=$(python3 - "$update" <<'PY'
import datetime
import json
import os
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
message = path.read_text(encoding="utf-8").strip()
if not message:
    raise SystemExit("update is empty")

lines = message.splitlines()
title = "zigcho release 1"
if lines and lines[0].startswith("# "):
    title = lines.pop(0)[2:].strip()

intro_lines = []
sections = []
section_name = None
section_lines = []
for line in lines:
    if line.startswith("## "):
        if section_name is not None:
            sections.append((section_name, "\n".join(section_lines).strip()))
        section_name = line[3:].strip()
        section_lines = []
    elif section_name is None:
        intro_lines.append(line)
    else:
        section_lines.append(line)
if section_name is not None:
    sections.append((section_name, "\n".join(section_lines).strip()))

def compact(value):
    return re.sub(r"\n{3,}", "\n\n", value.strip())

def clipped(value, limit):
    value = compact(value)
    if len(value) <= limit:
        return value
    cut = value.rfind(" ", 0, limit - 1)
    if cut < limit // 2:
        cut = limit - 1
    return value[:cut].rstrip() + "…"

intro = clipped("\n".join(intro_lines), 850)
if not intro:
    intro = "the first proper zigcho release. the full changelog is attached below."
else:
    intro += "\n\n*the full changelog is attached below.*"

commit = os.environ.get("ZIGCHO_RELEASE_COMMIT", "").strip()
short_commit = commit[:8] if commit else "pending"
repository = os.environ.get("ZIGCHO_RELEASE_REPOSITORY", "raya-ac/zigcho").strip()
release_url = os.environ.get("ZIGCHO_RELEASE_URL", "").strip()
client_version = os.environ.get("ZIGCHO_CLIENT_VERSION", "0.1.0-alpha.15").strip()
builds = os.environ.get("ZIGCHO_RELEASE_BUILDS", "Windows · macOS · Linux · Android · unsigned iOS").strip()
schema = os.environ.get("ZIGCHO_SCHEMA", "45").strip()
state = os.environ.get("ZIGCHO_RELEASE_STATE", "live").strip()

commit_value = f"`{short_commit}`"
if commit and repository:
    commit_value = f"[`{short_commit}`](https://github.com/{repository}/commit/{commit})"
release_facts = (
    f"**server:** {state}\n"
    f"**commit:** {commit_value}\n"
    f"**database:** schema {schema}\n"
    f"**lazer package:** {client_version}\n"
    f"**builds:** {builds}"
)

fields = [{"name": "release", "value": release_facts, "inline": False}]
remaining = 4700 - len(intro) - len(release_facts)
for name, body in sections:
    if not body or len(fields) >= 7 or remaining < 180:
        continue
    limit = min(650, remaining)
    value = clipped(body, limit)
    fields.append({"name": clipped(name, 256), "value": value, "inline": False})
    remaining -= len(name) + len(value)

embed = {
    "title": clipped(title, 256),
    "description": intro,
    "color": 15745175,
    "fields": fields,
    "thumbnail": {"url": "https://a.kai.ovh/3"},
    "footer": {"text": f"release 1 · {client_version} · {short_commit}"},
    "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
if release_url:
    embed["url"] = release_url

payload = {
    "username": "kai",
    "avatar_url": "https://a.kai.ovh/3",
    "embeds": [embed],
    "allowed_mentions": {"parse": []},
}
print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
PY
)

if [ "${DISCORD_DRY_RUN:-0}" = 1 ]; then
    printf '%s\n' "$payload"
    exit 0
fi

curl --fail --silent --show-error \
    --form-string "payload_json=$payload" \
    --form "files[0]=@$update;type=text/markdown;filename=zigcho-release-1.md" \
    "$DISCORD_RELEASE_WEBHOOK"
