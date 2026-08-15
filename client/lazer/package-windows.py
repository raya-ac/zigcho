#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import tempfile
import zipfile


VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
FIXED_TIME = (2026, 1, 1, 0, 0, 0)


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def write_bytes(archive: zipfile.ZipFile, name: str, data: bytes) -> None:
    info = zipfile.ZipInfo(name, FIXED_TIME)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o100644 << 16
    archive.writestr(info, data)


def write_file(archive: zipfile.ZipFile, name: str, path: Path) -> None:
    info = zipfile.ZipInfo(name, FIXED_TIME)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o100644 << 16
    with path.open("rb") as source, archive.open(info, "w") as target:
        shutil.copyfileobj(source, target, length=1024 * 1024)


def main() -> None:
    parser = argparse.ArgumentParser(description="package a self-contained zigcho lazer Windows build")
    parser.add_argument("--publish-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--zigcho-revision", required=True)
    parser.add_argument("--osu-revision", required=True)
    parser.add_argument("--zigcho-license", type=Path, required=True)
    parser.add_argument("--osu-license", type=Path, required=True)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    if not VERSION_RE.fullmatch(args.version):
        raise SystemExit(f"invalid client version: {args.version}")
    executable = args.publish_dir / "osu!.exe"
    if not executable.is_file():
        raise SystemExit(f"Windows executable missing: {executable}")
    if executable.read_bytes()[:2] != b"MZ":
        raise SystemExit(f"not a Windows executable: {executable}")
    for licence in (args.zigcho_license, args.osu_license):
        if not licence.is_file():
            raise SystemExit(f"licence missing: {licence}")

    root = f"zigcho-lazer-{args.version}-windows-x64"
    args.output_dir.mkdir(parents=True, exist_ok=True)
    destination = args.output_dir / f"{root}.zip"
    checksum_path = destination.with_suffix(destination.suffix + ".sha256")
    if not args.force and (destination.exists() or checksum_path.exists()):
        raise SystemExit(f"release already exists: {destination}")

    published = sorted(path for path in args.publish_dir.rglob("*") if path.is_file())
    if any(path.suffix.lower() == ".pdb" for path in published):
        raise SystemExit("debug symbols are not allowed in the Windows package")

    version_text = (
        f"client_version={args.version}\n"
        f"zigcho_revision={args.zigcho_revision}\n"
        f"osu_revision={args.osu_revision}\n"
        "runtime=win-x64\n"
        "self_contained=true\n"
        "client_lane=production\n"
        "discord_room_party_id=clamped\n"
    ).encode()
    readme_text = (
        "zigcho!lazer for Windows x64\r\n"
        "\r\n"
        "Open osu!.exe to start. This build keeps its data in the zigcho-lazer folder,\r\n"
        "uses its own IPC pipe, and cannot replace or update an official osu! install.\r\n"
        "It connects to api.kai.ovh and kai.ovh. Public chat uses the REST\r\n"
        "fallback. normal head-to-head multiplayer rooms are live; matchmaking and\r\n"
        "spectator streaming are still outside this alpha.\r\n"
        "\r\n"
        "This alpha is not code-signed yet, so Windows SmartScreen may warn.\r\n"
        "Check the .zip.sha256 file before opening it.\r\n"
    ).encode()

    manifest_entries: list[tuple[str, str]] = []
    for path in published:
        relative = path.relative_to(args.publish_dir).as_posix()
        manifest_entries.append((digest(path), f"app/{relative}"))
    manifest_entries.extend(
        [
            (hashlib.sha256(version_text).hexdigest(), "VERSION.txt"),
            (hashlib.sha256(readme_text).hexdigest(), "README-WINDOWS.txt"),
            (digest(args.zigcho_license), "licenses/zigcho-MIT.txt"),
            (digest(args.osu_license), "licenses/osu-MIT.txt"),
        ]
    )
    manifest = "".join(f"{value}  {name}\n" for value, name in sorted(manifest_entries, key=lambda item: item[1])).encode()

    temp_handle, temp_name = tempfile.mkstemp(prefix=f".{root}.", suffix=".zip", dir=args.output_dir)
    os.close(temp_handle)
    temp_path = Path(temp_name)
    try:
        with zipfile.ZipFile(temp_path, "w", allowZip64=True) as archive:
            write_bytes(archive, f"{root}/VERSION.txt", version_text)
            write_bytes(archive, f"{root}/README-WINDOWS.txt", readme_text)
            write_file(archive, f"{root}/licenses/zigcho-MIT.txt", args.zigcho_license)
            write_file(archive, f"{root}/licenses/osu-MIT.txt", args.osu_license)
            for path in published:
                relative = path.relative_to(args.publish_dir).as_posix()
                write_file(archive, f"{root}/app/{relative}", path)
            write_bytes(archive, f"{root}/SHA256SUMS", manifest)

        if args.force:
            destination.unlink(missing_ok=True)
            checksum_path.unlink(missing_ok=True)
        temp_path.replace(destination)
        checksum_path.write_text(f"{digest(destination)}  {destination.name}\n", encoding="ascii", newline="\n")
    finally:
        temp_path.unlink(missing_ok=True)

    print(destination)
    print(checksum_path)


if __name__ == "__main__":
    main()
