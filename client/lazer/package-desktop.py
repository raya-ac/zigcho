#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import struct
import tempfile
import zipfile


VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
FIXED_TIME = (2026, 1, 1, 0, 0, 0)
RUNTIMES = {"macos-arm64", "linux-x64"}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def write_bytes(archive: zipfile.ZipFile, name: str, data: bytes, mode: int = 0o100644) -> None:
    info = zipfile.ZipInfo(name, FIXED_TIME)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = mode << 16
    archive.writestr(info, data)


def write_file(archive: zipfile.ZipFile, name: str, path: Path, executable: bool = False) -> None:
    mode = 0o100755 if executable else 0o100644
    info = zipfile.ZipInfo(name, FIXED_TIME)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = mode << 16
    with path.open("rb") as source, archive.open(info, "w") as target:
        shutil.copyfileobj(source, target, length=1024 * 1024)


def verify_executable(path: Path, runtime: str) -> None:
    data = path.read_bytes()[:64]
    if runtime == "linux-x64":
        if len(data) < 20 or data[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", data, 18)[0] != 0x3E:
            raise SystemExit(f"not an x86-64 ELF executable: {path}")
        return
    if len(data) < 8 or data[:4] != b"\xcf\xfa\xed\xfe" or struct.unpack_from("<I", data, 4)[0] != 0x0100000C:
        raise SystemExit(f"not an arm64 Mach-O executable: {path}")


def verify_markers(files: list[Path]) -> None:
    required = ("https://api.kai.ovh", "zigcho-lazer", "zigcho!lazer", "OSU_EXTERNAL_UPDATE_PROVIDER")
    found = {marker: False for marker in required}
    for path in files:
        data = path.read_bytes()
        for marker in required:
            if marker.encode() in data or marker.encode("utf-16le") in data:
                found[marker] = True
    missing = [marker for marker, present in found.items() if not present]
    if missing:
        raise SystemExit(f"production markers missing: {', '.join(missing)}")


def verify_archive(path: Path, runtime: str) -> None:
    external = path.with_suffix(path.suffix + ".sha256")
    expected_hash, expected_name = external.read_text(encoding="ascii").strip().split(None, 1)
    if expected_name.strip() != path.name or digest(path) != expected_hash:
        raise SystemExit("desktop archive checksum does not match")

    with zipfile.ZipFile(path) as package:
        if package.testzip() is not None:
            raise SystemExit("desktop archive is corrupt")
        names = package.namelist()
        roots = {PurePosixPath(name).parts[0] for name in names}
        if len(roots) != 1:
            raise SystemExit("desktop package must have one top-level directory")
        root = roots.pop()
        required = {
            f"{root}/app/osu!",
            f"{root}/VERSION.txt",
            f"{root}/README.txt",
            f"{root}/SHA256SUMS",
            f"{root}/licenses/zigcho-MIT.txt",
            f"{root}/licenses/osu-MIT.txt",
        }
        if not required.issubset(names):
            raise SystemExit("desktop package is missing required files")
        manifest = {}
        for line in package.read(f"{root}/SHA256SUMS").decode("ascii").splitlines():
            value, name = line.split("  ", 1)
            manifest[name] = value
        expected_names = {
            name.removeprefix(f"{root}/")
            for name in names
            if name != f"{root}/SHA256SUMS" and not name.endswith("/")
        }
        if set(manifest) != expected_names:
            raise SystemExit("desktop manifest does not cover the package exactly")
        for name, value in manifest.items():
            if hashlib.sha256(package.read(f"{root}/{name}")).hexdigest() != value:
                raise SystemExit(f"desktop manifest mismatch: {name}")
        version = package.read(f"{root}/VERSION.txt").decode("utf-8")
        if f"runtime={runtime}\n" not in version or "client_lane=production\n" not in version:
            raise SystemExit("desktop runtime metadata is incomplete")


def main() -> None:
    parser = argparse.ArgumentParser(description="package a self-contained zigcho!lazer desktop build")
    parser.add_argument("--publish-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--runtime", choices=sorted(RUNTIMES), required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--zigcho-revision", required=True)
    parser.add_argument("--osu-revision", required=True)
    parser.add_argument("--zigcho-license", type=Path, required=True)
    parser.add_argument("--osu-license", type=Path, required=True)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    if not VERSION_RE.fullmatch(args.version):
        raise SystemExit(f"invalid client version: {args.version}")
    executable = args.publish_dir / "osu!"
    if not executable.is_file():
        raise SystemExit(f"desktop executable missing: {executable}")
    verify_executable(executable, args.runtime)
    for licence in (args.zigcho_license, args.osu_license):
        if not licence.is_file():
            raise SystemExit(f"licence missing: {licence}")

    published = sorted(path for path in args.publish_dir.rglob("*") if path.is_file())
    if any(path.suffix.lower() == ".pdb" for path in published):
        raise SystemExit("debug symbols are not allowed in the desktop package")
    verify_markers(published)

    root = f"zigcho-lazer-{args.version}-{args.runtime}"
    args.output_dir.mkdir(parents=True, exist_ok=True)
    destination = args.output_dir / f"{root}.zip"
    checksum_path = destination.with_suffix(destination.suffix + ".sha256")
    if not args.force and (destination.exists() or checksum_path.exists()):
        raise SystemExit(f"release already exists: {destination}")

    version_text = (
        f"client_version={args.version}\n"
        f"zigcho_revision={args.zigcho_revision}\n"
        f"osu_revision={args.osu_revision}\n"
        f"runtime={args.runtime}\n"
        "self_contained=true\n"
        "client_lane=production\n"
    ).encode()
    readme_text = (
        f"zigcho!lazer for {args.runtime}\n\n"
        "keep the app folder together and run osu!. this build keeps its data and IPC\n"
        "separate from official osu! and connects to kai.ovh. it has no updater or installer.\n"
        "check the matching .sha256 file before opening it.\n"
    ).encode()

    manifest_entries = []
    for path in published:
        relative = path.relative_to(args.publish_dir).as_posix()
        manifest_entries.append((digest(path), f"app/{relative}"))
    manifest_entries.extend(
        [
            (hashlib.sha256(version_text).hexdigest(), "VERSION.txt"),
            (hashlib.sha256(readme_text).hexdigest(), "README.txt"),
            (digest(args.zigcho_license), "licenses/zigcho-MIT.txt"),
            (digest(args.osu_license), "licenses/osu-MIT.txt"),
        ]
    )
    manifest = "".join(f"{value}  {name}\n" for value, name in sorted(manifest_entries, key=lambda item: item[1])).encode()

    handle, temp_name = tempfile.mkstemp(prefix=f".{root}.", suffix=".zip", dir=args.output_dir)
    os.close(handle)
    temp_path = Path(temp_name)
    try:
        with zipfile.ZipFile(temp_path, "w", allowZip64=True) as archive:
            write_bytes(archive, f"{root}/VERSION.txt", version_text)
            write_bytes(archive, f"{root}/README.txt", readme_text)
            write_file(archive, f"{root}/licenses/zigcho-MIT.txt", args.zigcho_license)
            write_file(archive, f"{root}/licenses/osu-MIT.txt", args.osu_license)
            for path in published:
                relative = path.relative_to(args.publish_dir).as_posix()
                write_file(archive, f"{root}/app/{relative}", path, executable=path == executable)
            write_bytes(archive, f"{root}/SHA256SUMS", manifest)
        if args.force:
            destination.unlink(missing_ok=True)
            checksum_path.unlink(missing_ok=True)
        temp_path.replace(destination)
        checksum_path.write_text(f"{digest(destination)}  {destination.name}\n", encoding="ascii", newline="\n")
    finally:
        temp_path.unlink(missing_ok=True)

    verify_archive(destination, args.runtime)
    print(destination)
    print(checksum_path)


if __name__ == "__main__":
    main()
