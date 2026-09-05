#!/usr/bin/env python3
"""Normalize or verify the bounded raw-GitHub changelog manifest."""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta
import hashlib
import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
UPDATES = ROOT / "updates"
MANIFEST = UPDATES / "changelog.json"
NAME = re.compile(r"^\d{4}-\d{2}-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*\.md$")
VERSION = re.compile(r"^\d+(?:\.\d+)+$")
TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})$")
COMMIT = re.compile(r"^(?:|[0-9a-f]{40})$")
MAX_BUILDS = 64
MAX_UPDATES = 256
MAX_MANIFEST_BYTES = 128 * 1024
MAX_UPDATE_BYTES = 128 * 1024
MAX_TOTAL_BYTES = 2 * 1024 * 1024
MAX_BUILD_ID = (2**63 - 1 - (MAX_UPDATES - 1)) // 100


def reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def exact_keys(value: dict[str, object], required: set[str], optional: set[str] = set()) -> None:
    missing = required - value.keys()
    extra = value.keys() - required - optional
    if missing or extra:
        raise ValueError(f"manifest keys are wrong: missing={sorted(missing)} extra={sorted(extra)}")


def valid_timestamp(value: object) -> bool:
    if not isinstance(value, str) or not TIMESTAMP.fullmatch(value):
        return False
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return False
    offset = parsed.utcoffset()
    return offset is not None and abs(offset) <= timedelta(hours=14)


def normalized_manifest() -> tuple[bytes, int]:
    raw = MANIFEST.read_bytes()
    if not raw or len(raw) > MAX_MANIFEST_BYTES:
        raise ValueError(f"manifest size must be 1..{MAX_MANIFEST_BYTES} bytes")
    data = json.loads(raw, object_pairs_hook=reject_duplicates)
    if not isinstance(data, dict):
        raise ValueError("manifest root must be an object")
    exact_keys(data, {"schema", "builds"})
    if data["schema"] != 1:
        raise ValueError("manifest schema must be 1")
    builds = data["builds"]
    if not isinstance(builds, list) or not 1 <= len(builds) <= MAX_BUILDS:
        raise ValueError(f"build count must be 1..{MAX_BUILDS}")

    seen_ids: set[int] = set()
    seen_versions: set[str] = set()
    seen_names: set[str] = set()
    previous_id: int | None = None
    total_bytes = 0
    update_count = 0
    for build in builds:
        if not isinstance(build, dict):
            raise ValueError("each build must be an object")
        exact_keys(build, {"id", "version", "created_at", "updates"}, {"display_version"})
        build_id = build["id"]
        version = build["version"]
        created_at = build["created_at"]
        if not isinstance(build_id, int) or isinstance(build_id, bool) or not 1 <= build_id <= MAX_BUILD_ID:
            raise ValueError("build id must be a positive integer")
        if previous_id is not None and build_id >= previous_id:
            raise ValueError("build ids must be strictly newest-to-oldest")
        previous_id = build_id
        if build_id in seen_ids:
            raise ValueError(f"duplicate build id: {build_id}")
        seen_ids.add(build_id)
        if not isinstance(version, str) or len(version) > 32 or not VERSION.fullmatch(version):
            raise ValueError(f"invalid build version: {version!r}")
        if version in seen_versions:
            raise ValueError(f"duplicate build version: {version}")
        seen_versions.add(version)
        if not valid_timestamp(created_at):
            raise ValueError(f"invalid build timestamp: {created_at!r}")
        if "display_version" in build and (
            not isinstance(build["display_version"], str)
            or not 1 <= len(build["display_version"].encode()) <= 64
        ):
            raise ValueError("display_version must be 1..64 UTF-8 bytes")
        updates = build["updates"]
        if not isinstance(updates, list) or not updates:
            raise ValueError(f"build {version} has no updates")
        for update in updates:
            if not isinstance(update, dict):
                raise ValueError("each update must be an object")
            exact_keys(update, {"name", "created_at", "commit", "sha256"})
            name = update["name"]
            update_at = update["created_at"]
            commit = update["commit"]
            if not isinstance(name, str) or len(name.encode()) > 96 or not NAME.fullmatch(name):
                raise ValueError(f"invalid update filename: {name!r}")
            if name in seen_names:
                raise ValueError(f"duplicate update filename: {name}")
            seen_names.add(name)
            if not valid_timestamp(update_at):
                raise ValueError(f"invalid update timestamp: {update_at!r}")
            if not isinstance(commit, str) or not COMMIT.fullmatch(commit):
                raise ValueError(f"invalid commit for {name}")
            path = UPDATES / name
            if path.parent != UPDATES or not path.is_file():
                raise ValueError(f"missing update Markdown: {name}")
            markdown = path.read_bytes()
            first_line = markdown.split(b"\n", 1)[0].strip(b"#* \t\r")
            if not markdown or len(markdown) > MAX_UPDATE_BYTES or b"\0" in markdown or not first_line:
                raise ValueError(f"invalid update Markdown: {name}")
            markdown.decode("utf-8")
            total_bytes += len(markdown)
            if total_bytes > MAX_TOTAL_BYTES:
                raise ValueError("total Markdown exceeds the runtime feed bound")
            update["sha256"] = hashlib.sha256(markdown).hexdigest()
            update_count += 1
            if update_count > MAX_UPDATES:
                raise ValueError(f"update count exceeds {MAX_UPDATES}")

    disk_names = {path.name for path in UPDATES.iterdir() if path.is_file() and NAME.fullmatch(path.name)}
    missing = sorted(disk_names - seen_names)
    unknown = sorted(seen_names - disk_names)
    if missing or unknown:
        raise ValueError(f"manifest/file mismatch: missing={missing} unknown={unknown}")
    normalized = (json.dumps(data, ensure_ascii=False, indent=2) + "\n").encode()
    if len(normalized) > MAX_MANIFEST_BYTES:
        raise ValueError("normalized manifest exceeds the runtime bound")
    return normalized, update_count


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="verify exact normalized content (default)")
    mode.add_argument("--write", action="store_true", help="rewrite hashes and formatting deterministically")
    args = parser.parse_args()
    try:
        normalized, update_count = normalized_manifest()
        if args.write:
            MANIFEST.write_bytes(normalized)
        elif MANIFEST.read_bytes() != normalized:
            raise ValueError("manifest is stale; run tools/changelog-manifest.py --write")
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        print(f"changelog manifest: {error}", file=sys.stderr)
        return 1
    print(f"changelog manifest ok: {update_count} updates")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
