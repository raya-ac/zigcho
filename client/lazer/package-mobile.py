#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import tempfile
import zipfile


VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
FIXED_TIME = (2026, 1, 1, 0, 0, 0)
BUNDLE_ID = "ovh.kai.zigcholazer"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def write_checksum(path: Path) -> Path:
    checksum = path.with_suffix(path.suffix + ".sha256")
    checksum.write_text(f"{digest(path)}  {path.name}\n", encoding="ascii", newline="\n")
    return checksum


def write_metadata(path: Path, platform: str, version: str, zigcho: str, osu: str) -> Path:
    metadata = path.with_suffix(path.suffix + ".metadata.txt")
    metadata.write_text(
        f"client_version={version}\n"
        f"zigcho_revision={zigcho}\n"
        f"osu_revision={osu}\n"
        f"runtime={platform}\n"
        "client_lane=production\n"
        "distribution_signed=false\n",
        encoding="utf-8",
        newline="\n",
    )
    return metadata


def contains_bundle_id(data: bytes) -> bool:
    return BUNDLE_ID.encode() in data or BUNDLE_ID.encode("utf-16le") in data


def verify_android(path: Path) -> None:
    with zipfile.ZipFile(path) as package:
        if package.testzip() is not None:
            raise SystemExit("Android package is corrupt")
        names = package.namelist()
        if "AndroidManifest.xml" not in names or not any(Path(name).name.startswith("classes") and name.endswith(".dex") for name in names):
            raise SystemExit("Android package is missing its manifest or dex code")
        arm64 = [name for name in names if name.startswith("lib/arm64-v8a/") and name.endswith(".so")]
        if not arm64:
            raise SystemExit("Android package has no arm64 native runtime")
        if not contains_bundle_id(package.read("AndroidManifest.xml")):
            raise SystemExit("Android package has the wrong application id")


def macho_has_arm64(path: Path) -> bool:
    data = path.read_bytes()[:4096]
    if len(data) < 8:
        return False
    if data[:4] == b"\xcf\xfa\xed\xfe":
        return struct.unpack_from("<I", data, 4)[0] == 0x0100000C
    if data[:4] == b"\xca\xfe\xba\xbe":
        count = struct.unpack_from(">I", data, 4)[0]
        return any(struct.unpack_from(">I", data, 8 + index * 20)[0] == 0x0100000C for index in range(count))
    if data[:4] == b"\xca\xfe\xba\xbf":
        count = struct.unpack_from(">I", data, 4)[0]
        return any(struct.unpack_from(">I", data, 8 + index * 32)[0] == 0x0100000C for index in range(count))
    return False


def verify_ios_app(app: Path) -> None:
    info_path = app / "Info.plist"
    if not info_path.is_file():
        raise SystemExit("iOS app has no Info.plist")
    with info_path.open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise SystemExit("iOS app has the wrong bundle id")
    if info.get("CFBundleDisplayName") != "zigcho!lazer" and info.get("CFBundleName") != "zigcho!lazer":
        raise SystemExit("iOS app has the wrong display name")
    executable = app / str(info.get("CFBundleExecutable", ""))
    if not executable.is_file() or not macho_has_arm64(executable):
        raise SystemExit("iOS app has no arm64 Mach-O executable")


def write_tree(archive: zipfile.ZipFile, source: Path, root: str) -> None:
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source).as_posix()
        name = f"{root}/{relative}"
        stat = path.lstat()
        is_link = path.is_symlink()
        is_directory = path.is_dir() and not is_link
        info = zipfile.ZipInfo(name + ("/" if is_directory else ""), FIXED_TIME)
        info.create_system = 3
        info.external_attr = stat.st_mode << 16
        if is_link:
            info.compress_type = zipfile.ZIP_STORED
            archive.writestr(info, os.readlink(path).encode())
        elif is_directory:
            archive.writestr(info, b"")
        elif path.is_file():
            info.compress_type = zipfile.ZIP_DEFLATED
            with path.open("rb") as input_file, archive.open(info, "w") as output_file:
                shutil.copyfileobj(input_file, output_file, length=1024 * 1024)


def verify_ipa(path: Path) -> None:
    with zipfile.ZipFile(path) as package:
        if package.testzip() is not None:
            raise SystemExit("iOS package is corrupt")
        info_names = [name for name in package.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(info_names) != 1:
            raise SystemExit("iOS package must contain exactly one app")
        info = plistlib.loads(package.read(info_names[0]))
        if info.get("CFBundleIdentifier") != BUNDLE_ID:
            raise SystemExit("iOS package has the wrong bundle id")
        executable_name = str(info.get("CFBundleExecutable", ""))
        executable_path = info_names[0].removesuffix("Info.plist") + executable_name
        if executable_path not in package.namelist():
            raise SystemExit("iOS package is missing its executable")
        handle, temp_name = tempfile.mkstemp(prefix="zigcho-ios-executable.")
        os.close(handle)
        temp = Path(temp_name)
        try:
            temp.write_bytes(package.read(executable_path))
            if not macho_has_arm64(temp):
                raise SystemExit("iOS package executable is not arm64")
        finally:
            temp.unlink(missing_ok=True)


def package_android(source: Path, destination: Path) -> None:
    if not source.is_file():
        raise SystemExit(f"Android package missing: {source}")
    verify_android(source)
    shutil.copyfile(source, destination)
    verify_android(destination)


def package_ios(source: Path, destination: Path) -> None:
    if not source.is_dir() or source.suffix != ".app":
        raise SystemExit(f"iOS app missing: {source}")
    verify_ios_app(source)
    handle, temp_name = tempfile.mkstemp(prefix=f".{destination.stem}.", suffix=".ipa", dir=destination.parent)
    os.close(handle)
    temp = Path(temp_name)
    try:
        with zipfile.ZipFile(temp, "w", allowZip64=True) as archive:
            write_tree(archive, source, f"Payload/{source.name}")
        temp.replace(destination)
    finally:
        temp.unlink(missing_ok=True)
    verify_ipa(destination)


def main() -> None:
    parser = argparse.ArgumentParser(description="package a zigcho!lazer mobile build")
    parser.add_argument("platform", choices=("android-arm64", "ios-arm64"))
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--zigcho-revision", required=True)
    parser.add_argument("--osu-revision", required=True)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    if not VERSION_RE.fullmatch(args.version):
        raise SystemExit(f"invalid client version: {args.version}")
    suffix = ".apk" if args.platform == "android-arm64" else ".ipa"
    args.output_dir.mkdir(parents=True, exist_ok=True)
    destination = args.output_dir / f"zigcho-lazer-{args.version}-{args.platform}{suffix}"
    sidecars = [destination.with_suffix(destination.suffix + suffix) for suffix in (".sha256", ".metadata.txt")]
    if not args.force and (destination.exists() or any(path.exists() for path in sidecars)):
        raise SystemExit(f"release already exists: {destination}")
    if args.force:
        destination.unlink(missing_ok=True)
        for path in sidecars:
            path.unlink(missing_ok=True)

    if args.platform == "android-arm64":
        package_android(args.input, destination)
    else:
        package_ios(args.input, destination)
    checksum = write_checksum(destination)
    metadata = write_metadata(destination, args.platform, args.version, args.zigcho_revision, args.osu_revision)
    print(destination)
    print(checksum)
    print(metadata)


if __name__ == "__main__":
    main()
