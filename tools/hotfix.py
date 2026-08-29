#!/usr/bin/env python3
"""Create, verify, and package small Zigcho production hotfixes."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
from typing import Any


FORMAT_VERSION = 1
SCHEMA_VERSION = 46
MAX_PATCH_BYTES = 512 * 1024
MAX_CHANGED_LINES = 600
MAX_SOURCE_FILES = 12
MAX_TEST_FILTERS = 3

ID_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9][a-z0-9-]{2,63}")
COMMIT_RE = re.compile(r"[0-9a-f]{40}")
HASH_RE = re.compile(r"[0-9a-f]{64}")
FILTER_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9 .,:_()!'/+\-]{0,95}")

ALLOWED_SUFFIXES = {".zig", ".html", ".css", ".js", ".json", ".svg"}
ALLOWED_SOURCE_FILES = {
    "src/beatmap.zig",
    "src/beatmap_media.zig",
    "src/changelog.zig",
    "src/changelog_feed.zig",
    "src/country.zig",
    "src/form_urlencoded.zig",
    "src/index.html",
    "src/lazer.zig",
    "src/lazer_route_manifest.zig",
    "src/lazer_wiki.zig",
    "src/logutil.zig",
    "src/main.zig",
    "src/media_contract.zig",
    "src/multipart.zig",
    "src/player_routes.zig",
    "src/protocol.zig",
    "src/proxy.zig",
    "src/routing.zig",
    "src/site_replay.zig",
    "src/stable_response.zig",
    "src/tests.zig",
    "src/user_json.zig",
    "src/webhook.zig",
}
ALLOWED_SOURCE_PREFIXES = ("src/assets/",)

MANIFEST_KEYS = {
    "format",
    "id",
    "base_commit",
    "schema_version",
    "patch_file",
    "patch_sha256",
    "summary",
    "test_filters",
}


class HotfixError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise HotfixError(message)


def git(root: Path, *args: str, text: bool = True) -> str | bytes:
    result = subprocess.run(
        ["git", *args],
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=text,
    )
    if result.returncode != 0:
        stderr = result.stderr.strip() if text else result.stderr.decode("utf-8", "replace").strip()
        fail(f"git {' '.join(args)} failed: {stderr}")
    return result.stdout


def repo_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        fail("run this inside the Zigcho checkout")
    return Path(result.stdout.strip()).resolve()


def resolve_commit(root: Path, value: str) -> str:
    resolved = str(git(root, "rev-parse", "--verify", f"{value}^{{commit}}")).strip()
    if not COMMIT_RE.fullmatch(resolved):
        fail(f"invalid commit: {value}")
    return resolved


def clean_path(value: str) -> str:
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or any(part in {"", ".", ".."} for part in path.parts):
        fail(f"unsafe repository path: {value}")
    return path.as_posix()


def allowed_source(path: str) -> bool:
    path = clean_path(path)
    if Path(path).suffix not in ALLOWED_SUFFIXES:
        return False
    return path in ALLOWED_SOURCE_FILES or path.startswith(ALLOWED_SOURCE_PREFIXES)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def changed_paths(root: Path, base: str, target: str | None = None) -> list[str]:
    args = ["diff", "--name-only", "--diff-filter=ACMRTUXB", base]
    if target is not None:
        args.append(target)
    args.append("--")
    output = str(git(root, *args))
    return [clean_path(line) for line in output.splitlines() if line]


def changed_status(root: Path, base: str, target: str) -> list[tuple[str, str]]:
    output = str(git(root, "diff", "--name-status", "--no-renames", base, target, "--"))
    rows: list[tuple[str, str]] = []
    for line in output.splitlines():
        status, separator, path = line.partition("\t")
        if not separator:
            fail(f"could not parse changed path: {line}")
        rows.append((status, clean_path(path)))
    return rows


def canonical_patch(root: Path, base: str, source_paths: list[str], target: str | None = None) -> bytes:
    args = [
        "diff",
        "--no-ext-diff",
        "--no-renames",
        "--full-index",
        "--binary",
        base,
    ]
    if target is not None:
        args.append(target)
    args.extend(["--", *source_paths])
    return bytes(git(root, *args, text=False))


def validate_patch(patch: bytes, source_paths: list[str]) -> None:
    if not patch or len(patch) > MAX_PATCH_BYTES:
        fail(f"patch must be between 1 and {MAX_PATCH_BYTES} bytes")
    text = patch.decode("utf-8", "strict")
    forbidden = (
        "GIT binary patch",
        "old mode ",
        "new mode ",
        "deleted file mode ",
        "new file mode 120000",
        "rename from ",
        "rename to ",
    )
    if any(marker in text for marker in forbidden):
        fail("hotfix patches must be plain text without mode, symlink, binary, delete, or rename changes")

    headers = []
    changed_lines = 0
    for line in text.splitlines():
        if line.startswith("diff --git a/"):
            match = re.fullmatch(r"diff --git a/(.+) b/(.+)", line)
            if match is None or match.group(1) != match.group(2):
                fail("patch contains a malformed or renamed path")
            headers.append(clean_path(match.group(1)))
        elif (line.startswith("+") and not line.startswith("+++")) or (
            line.startswith("-") and not line.startswith("---")
        ):
            changed_lines += 1

    if headers != source_paths:
        fail("patch headers do not exactly match the sorted source path list")
    if changed_lines > MAX_CHANGED_LINES:
        fail(f"hotfix changes {changed_lines} lines; full releases are required above {MAX_CHANGED_LINES}")


def validate_filter(value: Any) -> str:
    if not isinstance(value, str) or not FILTER_RE.fullmatch(value):
        fail(f"invalid test filter: {value!r}")
    return value


def validate_manifest_object(value: Any, expected_name: str | None = None) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != MANIFEST_KEYS:
        fail("hotfix manifest has missing or unknown fields")
    if value["format"] != FORMAT_VERSION:
        fail(f"unsupported hotfix format: {value['format']!r}")
    hotfix_id = value["id"]
    if not isinstance(hotfix_id, str) or not ID_RE.fullmatch(hotfix_id):
        fail("hotfix id must be a dated lowercase slug")
    if expected_name is not None and expected_name != f"{hotfix_id}.json":
        fail("hotfix manifest filename does not match its id")
    if not isinstance(value["base_commit"], str) or not COMMIT_RE.fullmatch(value["base_commit"]):
        fail("base_commit must be a full lowercase commit hash")
    if value["schema_version"] != SCHEMA_VERSION:
        fail(f"hotfixes must retain schema {SCHEMA_VERSION}")
    if value["patch_file"] != f"{hotfix_id}.patch":
        fail("patch_file must match the hotfix id")
    if not isinstance(value["patch_sha256"], str) or not HASH_RE.fullmatch(value["patch_sha256"]):
        fail("patch_sha256 must be a lowercase SHA-256 digest")
    summary = value["summary"]
    if not isinstance(summary, str) or not 8 <= len(summary) <= 180 or "\n" in summary or "\r" in summary:
        fail("summary must be one line between 8 and 180 characters")
    filters = value["test_filters"]
    if not isinstance(filters, list) or not 1 <= len(filters) <= MAX_TEST_FILTERS:
        fail(f"hotfixes require between 1 and {MAX_TEST_FILTERS} focused test filters")
    value["test_filters"] = [validate_filter(item) for item in filters]
    if len(set(value["test_filters"])) != len(value["test_filters"]):
        fail("test filters must be unique")
    return value


def manifest_from_bytes(data: bytes, expected_name: str | None = None) -> dict[str, Any]:
    try:
        value = json.loads(data.decode("utf-8", "strict"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid hotfix manifest JSON: {error}")
    return validate_manifest_object(value, expected_name)


def manifest_from_worktree(root: Path, path: str) -> dict[str, Any]:
    clean = clean_path(path)
    manifest_path = root / clean
    if manifest_path.is_symlink() or not manifest_path.is_file():
        fail(f"hotfix manifest is missing or is a symlink: {clean}")
    return manifest_from_bytes(manifest_path.read_bytes(), manifest_path.name)


def manifest_from_commit(root: Path, target: str, path: str) -> dict[str, Any]:
    clean = clean_path(path)
    data = bytes(git(root, "show", f"{target}:{clean}", text=False))
    return manifest_from_bytes(data, PurePosixPath(clean).name)


def test_names_from_commit(root: Path, target: str) -> list[str]:
    output = str(git(root, "grep", "-I", "-h", "test \"", target, "--", "src"))
    names: list[str] = []
    for line in output.splitlines():
        match = re.search(r'\btest\s+"([^"]+)"', line)
        if match:
            names.append(match.group(1))
    return names


def verify(root: Path, manifest_path: str, target_value: str) -> dict[str, Any]:
    target = resolve_commit(root, target_value)
    manifest_clean = clean_path(manifest_path)
    if not re.fullmatch(r"hotfixes/[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9][a-z0-9-]{2,63}\.json", manifest_clean):
        fail("manifest must be a dated JSON file directly under hotfixes/")
    manifest = manifest_from_commit(root, target, manifest_clean)
    base = resolve_commit(root, manifest["base_commit"])

    parent_line = str(git(root, "rev-list", "--parents", "-n", "1", target)).strip().split()
    if len(parent_line) != 2 or parent_line[1] != base:
        fail("a hotfix must be one non-merge commit directly on its declared base")

    patch_path = f"hotfixes/{manifest['patch_file']}"
    statuses = changed_status(root, base, target)
    if any(status not in {"A", "M"} for status, _ in statuses):
        fail("hotfix commits cannot delete, rename, copy, or change file types")
    paths = [path for _, path in statuses]
    metadata = {manifest_clean, patch_path}
    source_paths = sorted(path for path in paths if path not in metadata)
    if not source_paths or len(source_paths) > MAX_SOURCE_FILES:
        fail(f"hotfixes must change between 1 and {MAX_SOURCE_FILES} source files")
    unexpected = [path for path in source_paths if not allowed_source(path)]
    if unexpected:
        fail("full release required for: " + ", ".join(unexpected))
    if set(paths) != metadata | set(source_paths):
        fail("hotfix commit contains unexpected metadata paths")

    patch = bytes(git(root, "show", f"{target}:{patch_path}", text=False))
    expected = canonical_patch(root, base, source_paths, target)
    if patch != expected:
        fail("stored patch is not the exact canonical source diff")
    validate_patch(patch, source_paths)
    if sha256_bytes(patch) != manifest["patch_sha256"]:
        fail("stored patch SHA-256 does not match the manifest")

    names = test_names_from_commit(root, target)
    for test_filter in manifest["test_filters"]:
        if not any(test_filter in name for name in names):
            fail(f"test filter matches no committed Zig test: {test_filter}")

    return {
        "is_hotfix": True,
        "manifest": manifest_clean,
        "patch": patch_path,
        "base_commit": base,
        "target_commit": target,
        "source_paths": source_paths,
        "summary": manifest["summary"],
        "test_filters": manifest["test_filters"],
    }


def write_github_output(path: Path, values: dict[str, str]) -> None:
    with path.open("a", encoding="utf-8") as handle:
        for key, value in values.items():
            if "\n" in value or "\r" in value:
                fail(f"unsafe GitHub output value for {key}")
            handle.write(f"{key}={value}\n")


def command_create(args: argparse.Namespace) -> None:
    root = repo_root()
    if not ID_RE.fullmatch(args.id):
        fail("hotfix id must be a dated lowercase slug")
    base = resolve_commit(root, args.base)
    source_paths = sorted(changed_paths(root, base))
    if not source_paths or len(source_paths) > MAX_SOURCE_FILES:
        fail(f"hotfixes must change between 1 and {MAX_SOURCE_FILES} tracked source files")
    unexpected = [path for path in source_paths if not allowed_source(path)]
    if unexpected:
        fail("full release required for: " + ", ".join(unexpected))

    untracked = str(git(root, "ls-files", "--others", "--exclude-standard")).splitlines()
    allowed_output = {f"hotfixes/{args.id}.json", f"hotfixes/{args.id}.patch"}
    unrelated_untracked = [clean_path(path) for path in untracked if clean_path(path) not in allowed_output]
    if unrelated_untracked:
        fail("clean or stage unrelated untracked files first: " + ", ".join(unrelated_untracked))

    patch = canonical_patch(root, base, source_paths)
    validate_patch(patch, source_paths)
    filters = [validate_filter(value) for value in args.test_filter]
    if not 1 <= len(filters) <= MAX_TEST_FILTERS or len(set(filters)) != len(filters):
        fail(f"provide between 1 and {MAX_TEST_FILTERS} unique test filters")
    summary = args.summary.strip()
    if not 8 <= len(summary) <= 180 or "\n" in summary or "\r" in summary:
        fail("summary must be one line between 8 and 180 characters")

    output_dir = root / "hotfixes"
    output_dir.mkdir(exist_ok=True)
    patch_path = output_dir / f"{args.id}.patch"
    manifest_path = output_dir / f"{args.id}.json"
    patch_path.write_bytes(patch)
    manifest = {
        "format": FORMAT_VERSION,
        "id": args.id,
        "base_commit": base,
        "schema_version": SCHEMA_VERSION,
        "patch_file": patch_path.name,
        "patch_sha256": sha256_bytes(patch),
        "summary": summary,
        "test_filters": filters,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(manifest_path.relative_to(root))
    print(patch_path.relative_to(root))


def command_verify(args: argparse.Namespace) -> None:
    result = verify(repo_root(), args.manifest, args.target)
    print(json.dumps(result, sort_keys=True))


def command_classify(args: argparse.Namespace) -> None:
    root = repo_root()
    target = resolve_commit(root, args.target)
    parent_line = str(git(root, "rev-list", "--parents", "-n", "1", target)).strip().split()
    result: dict[str, Any] = {"is_hotfix": False, "manifest": ""}
    if len(parent_line) == 2:
        parent = parent_line[1]
        statuses = changed_status(root, parent, target)
        added_manifests = [
            path
            for status, path in statuses
            if status == "A" and re.fullmatch(r"hotfixes/.+\.json", path)
        ]
        patch_changes = [path for _, path in statuses if path.startswith("hotfixes/") and path.endswith(".patch")]
        if len(added_manifests) > 1:
            fail("one commit may contain only one hotfix manifest")
        if added_manifests:
            result = verify(root, added_manifests[0], target)
        elif patch_changes:
            fail("hotfix patch added without a matching manifest")

    if args.github_output:
        write_github_output(
            Path(args.github_output),
            {
                "is_hotfix": "true" if result["is_hotfix"] else "false",
                "manifest": str(result.get("manifest", "")),
            },
        )
    print(json.dumps(result, sort_keys=True))


def command_run_tests(args: argparse.Namespace) -> None:
    root = Path.cwd().resolve()
    if not (root / "build.zig").is_file() or not (root / "src").is_dir():
        fail("run focused hotfix tests from the Zigcho source root")
    manifest = manifest_from_worktree(root, args.manifest)
    for test_filter in manifest["test_filters"]:
        print(f"hotfix_test={test_filter}", flush=True)
        subprocess.run(
            ["zig", "build", "test", "-Dcpu=baseline", f"-Dtest-filter={test_filter}"],
            cwd=root,
            check=True,
        )


def command_bundle(args: argparse.Namespace) -> None:
    root = repo_root()
    result = verify(root, args.manifest, args.target)
    target = result["target_commit"]
    manifest = manifest_from_commit(root, target, result["manifest"])
    output = Path(args.output_dir).resolve()
    binary = Path(args.binary).resolve()
    pp_marker = Path(args.pp_engine_version).resolve()
    if binary.is_symlink() or not binary.is_file():
        fail("hotfix binary is missing or is a symlink")
    if pp_marker.is_symlink() or not pp_marker.is_file():
        fail("PP engine marker is missing or is a symlink")
    output.mkdir(parents=True, exist_ok=True)

    patch_source = root / result["patch"]
    manifest_source = root / result["manifest"]
    patch_target = output / "source.patch"
    json_target = output / "hotfix.json"
    shutil.copyfile(patch_source, patch_target)
    shutil.copyfile(manifest_source, json_target)

    binary_hash = sha256_file(binary)
    pp_hash = sha256_file(pp_marker)
    patch_hash = sha256_file(patch_target)
    if patch_hash != manifest["patch_sha256"]:
        fail("bundled patch digest changed")
    (output / "zigcho.sha256").write_text(f"{binary_hash}  zigcho\n", encoding="ascii")
    (output / "source.patch.sha256").write_text(f"{patch_hash}  source.patch\n", encoding="ascii")
    flat_manifest = {
        "format": str(FORMAT_VERSION),
        "id": manifest["id"],
        "base_commit": result["base_commit"],
        "target_commit": target,
        "schema_version": str(SCHEMA_VERSION),
        "patch_sha256": patch_hash,
        "binary_sha256": binary_hash,
        "pp_engine_sha256": pp_hash,
    }
    lines = [f"{key}={value}" for key, value in flat_manifest.items()]
    (output / "hotfix.manifest").write_text("\n".join(lines) + "\n", encoding="ascii")
    print(json.dumps(flat_manifest, sort_keys=True))


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    create = commands.add_parser("create", help="write a canonical patch and manifest from tracked changes")
    create.add_argument("--id", required=True)
    create.add_argument("--summary", required=True)
    create.add_argument("--base", default="HEAD")
    create.add_argument("--test-filter", action="append", required=True)
    create.set_defaults(handler=command_create)

    verify_parser = commands.add_parser("verify", help="verify a committed hotfix")
    verify_parser.add_argument("--manifest", required=True)
    verify_parser.add_argument("--target", default="HEAD")
    verify_parser.set_defaults(handler=command_verify)

    classify = commands.add_parser("classify", help="classify and verify the target commit")
    classify.add_argument("--target", default="HEAD")
    classify.add_argument("--github-output")
    classify.set_defaults(handler=command_classify)

    run_tests = commands.add_parser("run-tests", help="run only the manifest's focused tests")
    run_tests.add_argument("--manifest", required=True)
    run_tests.set_defaults(handler=command_run_tests)

    bundle = commands.add_parser("bundle", help="add verified patch metadata to a built hotfix artifact")
    bundle.add_argument("--manifest", required=True)
    bundle.add_argument("--target", default="HEAD")
    bundle.add_argument("--binary", required=True)
    bundle.add_argument("--pp-engine-version", required=True)
    bundle.add_argument("--output-dir", required=True)
    bundle.set_defaults(handler=command_bundle)
    return root


def main() -> int:
    try:
        args = parser().parse_args()
        args.handler(args)
        return 0
    except HotfixError as error:
        print(f"hotfix: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
