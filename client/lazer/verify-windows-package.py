#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path, PurePosixPath
import struct
import zipfile


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_sha256(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description="verify a zigcho lazer Windows package")
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()

    external = args.archive.with_suffix(args.archive.suffix + ".sha256")
    expected_archive_hash, expected_name = external.read_text(encoding="ascii").strip().split(None, 1)
    if expected_name.strip() != args.archive.name:
        raise SystemExit("external checksum names the wrong archive")
    if file_sha256(args.archive) != expected_archive_hash:
        raise SystemExit("external archive checksum does not match")

    with zipfile.ZipFile(args.archive) as package:
        names = package.namelist()
        roots = {PurePosixPath(name).parts[0] for name in names}
        if len(roots) != 1:
            raise SystemExit("package must have exactly one top-level directory")
        root = roots.pop()
        required = {
            f"{root}/app/osu!.exe",
            f"{root}/VERSION.txt",
            f"{root}/README-WINDOWS.txt",
            f"{root}/SHA256SUMS",
            f"{root}/licenses/zigcho-MIT.txt",
            f"{root}/licenses/osu-MIT.txt",
        }
        missing = sorted(required.difference(names))
        if missing:
            raise SystemExit(f"package entries missing: {', '.join(missing)}")
        if any(name.lower().endswith(".pdb") for name in names):
            raise SystemExit("package contains debug symbols")

        executable = package.read(f"{root}/app/osu!.exe")
        if executable[:2] != b"MZ":
            raise SystemExit("osu!.exe has no DOS header")
        pe_offset = struct.unpack_from("<I", executable, 0x3C)[0]
        if executable[pe_offset : pe_offset + 4] != b"PE\0\0":
            raise SystemExit("osu!.exe has no PE header")
        machine = struct.unpack_from("<H", executable, pe_offset + 4)[0]
        if machine != 0x8664:
            raise SystemExit(f"osu!.exe is not x86-64 PE (machine 0x{machine:04x})")

        manifest: dict[str, str] = {}
        for line in package.read(f"{root}/SHA256SUMS").decode("ascii").splitlines():
            value, name = line.split("  ", 1)
            manifest[name] = value
        expected_manifest_names = {
            name.removeprefix(f"{root}/")
            for name in names
            if name != f"{root}/SHA256SUMS" and not name.endswith("/")
        }
        if set(manifest) != expected_manifest_names:
            raise SystemExit("internal manifest does not cover the package exactly")
        for name, value in manifest.items():
            package_name = f"{root}/{name}"
            if package_name not in names:
                raise SystemExit(f"manifest entry missing from package: {name}")
            if sha256(package.read(package_name)) != value:
                raise SystemExit(f"manifest checksum mismatch: {name}")

        required_markers = ("https://api.kai.ovh", "zigcho-lazer", "OSU_EXTERNAL_UPDATE_PROVIDER")
        markers_found = {marker: False for marker in required_markers}
        for name in names:
            if name.endswith("/"):
                continue
            data = package.read(name)
            for marker in required_markers:
                if marker.encode() in data or marker.encode("utf-16le") in data:
                    markers_found[marker] = True
        missing_markers = [marker for marker, found in markers_found.items() if not found]
        if missing_markers:
            raise SystemExit(f"required production markers missing: {', '.join(missing_markers)}")

        version = package.read(f"{root}/VERSION.txt").decode("utf-8")
        if any(
            marker not in version
            for marker in ("runtime=win-x64\n", "self_contained=true\n", "client_lane=production\n")
        ):
            raise SystemExit("Windows runtime metadata is incomplete")

    print(f"verified {args.archive.name}: x86-64 PE, checksums, production endpoints, isolated storage")


if __name__ == "__main__":
    main()
