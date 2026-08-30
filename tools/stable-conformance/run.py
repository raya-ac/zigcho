#!/usr/bin/env python3
"""Validate or replay Zigcho Stable conformance transcripts."""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

from check import check_coverage
from coverage import check_transcript_coverage
from http_target import TargetClient
from runner import (
    ConfigError,
    RunOptions,
    discover_transcripts,
    load_config,
    redact_value,
    run_transcripts,
    validate_proof_metadata,
)
from strict_json import load_path
from transcript import TranscriptError


HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
DEFAULT_TRANSCRIPTS = HERE / "transcripts"
DEFAULT_MANIFEST = HERE / "manifest.json"
_PARTIAL_COVERAGE_CODES = {
    "missing_packet_transcript",
    "missing_policy_matrix",
    "missing_required_scenario",
    "missing_route_transcript",
}


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    inventory = subparsers.add_parser("inventory", help="check source packet and route inventory")
    inventory.add_argument("--root", type=Path, default=REPO_ROOT)
    inventory.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)

    validate = subparsers.add_parser("validate", help="validate transcripts and their surface coverage")
    validate.add_argument("--transcript", action="append", type=Path, default=[])
    validate.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    validate.add_argument(
        "--allow-partial-coverage",
        action="store_true",
        help="validate structure and observed claims without requiring every manifest item",
    )

    run = subparsers.add_parser("run", help="replay stateful transcripts against one or two targets")
    run.add_argument("--config", type=Path, required=True)
    run.add_argument("--transcript", action="append", type=Path, default=[])
    run.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    run.add_argument("--target", action="append", default=[])
    run.add_argument("--zigcho-origin")
    run.add_argument("--reference-origin")
    run.add_argument("--reference-root", type=Path)
    run.add_argument("--allow-mutating", action="store_true")
    run.add_argument("--require-all", action="store_true")
    run.add_argument("--continue-on-failure", action="store_true")
    run.add_argument("--report", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "inventory":
            report = check_coverage(args.root, args.manifest)
            return _emit(report, failed=report["status"] != "ok")

        transcript_paths = args.transcript or [DEFAULT_TRANSCRIPTS]
        transcripts = discover_transcripts(transcript_paths)
        if not args.transcript:
            transcripts = _order_manifest_scenarios(transcripts, args.manifest)
        coverage_report = check_transcript_coverage(transcripts, args.manifest)
        if args.command == "validate":
            if args.allow_partial_coverage:
                coverage_report = _selection_coverage(coverage_report)
            report = {
                "schema": 1,
                "status": coverage_report["status"],
                "transcripts": len(transcripts),
                "coverage": coverage_report,
            }
            return _emit(report, failed=report["status"] != "ok")

        if args.require_all and args.transcript:
            raise ConfigError("--require-all only accepts the complete default transcript corpus")
        if args.require_all and args.manifest.resolve() != DEFAULT_MANIFEST.resolve():
            raise ConfigError("--require-all only accepts the checked-in Stable conformance manifest")

        source_inventory = check_coverage(REPO_ROOT, args.manifest)
        if args.require_all and source_inventory["status"] != "ok":
            raise ConfigError("the live source inventory does not match the checked manifest")

        config, states = load_config(args.config)
        if args.target:
            unknown = sorted(set(args.target) - set(states))
            if unknown:
                raise ConfigError(f"unknown selected targets: {', '.join(unknown)}")
            states = {name: states[name] for name in args.target}
        _override_origin(states, "zigcho", args.zigcho_origin)
        _override_origin(states, "reference", args.reference_origin)
        if len(states) == 2 and len({state.client.origin for state in states.values()}) != 2:
            raise ConfigError("differential targets must use distinct origins")
        reference_path = HERE / "reference.json"
        reference_document = load_path(reference_path)
        reference = reference_document["reference"]
        configured_reference = config.get("metadata", {}).get("reference_commit")
        if configured_reference is not None and configured_reference != reference["commit"]:
            raise ConfigError("configuration reference_commit does not match the pinned contract")
        if args.require_all:
            validate_proof_metadata(
                config,
                states,
                pinned_reference_commit=reference["commit"],
            )
            source_attestation = _attest_sources(
                config,
                reference_root=args.reference_root,
                pinned_reference_commit=reference["commit"],
            )
        else:
            source_attestation = {
                "zigcho": {"attested": False, "note": "source checkout not required for a partial run"},
                "reference": {"attested": False, "note": "source checkout not required for a partial run"},
            }
        consistency_errors = [
            error
            for error in coverage_report["errors"]
            if error["code"] not in _PARTIAL_COVERAGE_CODES
        ]
        if consistency_errors:
            raise ConfigError("transcript coverage claims do not match their encoded requests")
        if not args.transcript and coverage_report["status"] != "ok":
            raise ConfigError("the default corpus does not cover every inventoried Stable surface")
        if args.transcript:
            coverage_report = _selection_coverage(coverage_report)
        report = run_transcripts(
            transcripts,
            states,
            options=RunOptions(
                allow_mutating=args.allow_mutating,
                require_all=args.require_all,
                continue_on_failure=args.continue_on_failure,
                source_attestations=frozenset(
                    contract["id"]
                    for contract in source_attestation.get("reference", {}).get("source_contracts", [])
                    if contract.get("attested") is True and isinstance(contract.get("id"), str)
                ),
            ),
        )
        report["metadata"] = redact_value(config.get("metadata", {}), states.values())
        report["reference_contract"] = {
            "repository": reference["repository"],
            "expected_commit": reference["commit"],
            "project_version": reference["project_version"],
            "sha256": hashlib.sha256(reference_path.read_bytes()).hexdigest(),
            "note": "the expected pin is validated from config; the running origin is not remotely attested",
        }
        metadata = config.get("metadata", {})
        report["origin_attestation"] = {
            name: {
                "attested": False,
                "expected_commit": metadata.get(f"{name}_commit"),
            }
            for name in states
        }
        report["coverage"] = coverage_report
        report["source_inventory"] = source_inventory
        report["source_attestation"] = source_attestation
        report["manifest_sha256"] = hashlib.sha256(args.manifest.read_bytes()).hexdigest()
        report["manifest_path"] = _manifest_label(args.manifest)
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        failed = report["summary"]["failed"] > 0 or (args.require_all and report["summary"]["skipped"] > 0)
        return _emit(report, failed=failed)
    except (ConfigError, OSError, TranscriptError, ValueError, json.JSONDecodeError) as exc:
        return _emit({"schema": 1, "status": "failed", "error": str(exc)}, failed=True)


def _override_origin(states, name: str, origin: str | None) -> None:  # noqa: ANN001
    if origin is None:
        return
    if name not in states:
        raise ConfigError(f"--{name}-origin requires a target named {name!r}")
    previous = states[name].client
    states[name].client = TargetClient(
        name=name,
        origin=origin,
        timeout_seconds=previous.timeout_seconds,
        max_response_bytes=previous.max_response_bytes,
    )


def _selection_coverage(report: dict) -> dict:
    errors = [error for error in report["errors"] if error["code"] not in _PARTIAL_COVERAGE_CODES]
    return {
        "schema": report["schema"],
        "scope": "selected transcripts",
        "status": "ok" if not errors else "failed",
        "packets": {
            "declared": report["packets"]["declared"],
            "observed": report["packets"]["observed"],
            "corpus_total": report["packets"]["expected"],
        },
        "routes": {
            "declared": report["routes"]["declared"],
            "observed": report["routes"]["observed"],
            "corpus_total": report["routes"]["expected"],
        },
        "policy_matrices": {
            "declared": report["policy_matrices"]["declared"],
            "exercised": report["policy_matrices"]["exercised"],
        },
        "errors": errors,
    }


def _order_manifest_scenarios(transcripts: list[dict], manifest_path: Path) -> list[dict]:
    manifest = load_path(manifest_path)
    required = manifest.get("required_scenarios", [])
    if not isinstance(required, list):
        raise ConfigError("manifest required_scenarios must be an array")
    order = {
        scenario.get("id"): index
        for index, scenario in enumerate(required)
        if isinstance(scenario, dict) and isinstance(scenario.get("id"), str)
    }
    return sorted(transcripts, key=lambda transcript: order.get(transcript.get("id"), len(order)))


def _attest_sources(
    config: dict,
    *,
    reference_root: Path | None,
    pinned_reference_commit: str,
) -> dict:
    if reference_root is None:
        raise ConfigError("a complete proof requires --reference-root at the pinned bancho.py checkout")
    metadata = config["metadata"]
    zigcho_commit = _clean_git_commit(REPO_ROOT, "zigcho")
    if zigcho_commit != metadata["zigcho_commit"]:
        raise ConfigError("zigcho_commit metadata does not match the clean checkout HEAD")
    reference_commit = _clean_git_commit(reference_root, "reference")
    if reference_commit != pinned_reference_commit:
        raise ConfigError("reference checkout HEAD does not match the pinned bancho.py commit")
    manifest = load_path(DEFAULT_MANIFEST)
    reference_restricted = _reference_restricted_packet_ids(reference_root)
    expected_restricted = sorted(manifest["restricted_dispatch"]["reference_allowed_packet_ids"])
    if reference_restricted != expected_restricted:
        raise ConfigError("pinned reference restricted packet registrations do not match the checked manifest")
    presence_request_all = _attest_reference_presence_request_all(reference_root)
    return {
        "zigcho": {"attested": True, "commit": zigcho_commit, "scope": "clean local source checkout"},
        "reference": {
            "attested": True,
            "commit": reference_commit,
            "restricted_packet_ids": reference_restricted,
            "source_contracts": [presence_request_all],
            "scope": "clean local source checkout",
        },
    }


def _clean_git_commit(root: Path, label: str) -> str:
    try:
        commit = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.strip()
        dirty = subprocess.run(
            ["git", "-C", str(root), "status", "--porcelain"],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout
    except (OSError, subprocess.SubprocessError) as exc:
        raise ConfigError(f"cannot attest the {label} source checkout") from exc
    if dirty:
        raise ConfigError(f"the {label} source checkout is not clean")
    return commit


def _manifest_label(path: Path) -> str:
    try:
        return path.resolve().relative_to(REPO_ROOT.resolve()).as_posix()
    except ValueError:
        return "<external-manifest>"


def _reference_restricted_packet_ids(root: Path) -> list[int]:
    packets_path = root / "app/packets.py"
    handlers_path = root / "app/api/domains/cho.py"
    try:
        packets_source = packets_path.read_text(encoding="utf-8")
        handlers_source = handlers_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ConfigError("cannot inspect pinned reference restricted packet registrations") from exc
    class_match = re.search(r"^class ClientPackets\(IntEnum\):\s*$", packets_source, re.MULTILINE)
    if class_match is None:
        raise ConfigError("cannot find pinned reference ClientPackets enum")
    body_start = class_match.end()
    next_top_level = re.search(r"^(?=\S)", packets_source[body_start:], re.MULTILINE)
    if next_top_level is None:
        raise ConfigError("cannot bound pinned reference ClientPackets enum")
    class_body = packets_source[body_start : body_start + next_top_level.start()]
    packet_ids = {
        name: int(value)
        for name, value in re.findall(r"^[ \t]+([A-Z][A-Z0-9_]*)\s*=\s*(-?[0-9]+)\b", class_body, re.MULTILINE)
    }
    restricted_names = re.findall(
        r"@register\(ClientPackets\.([A-Z][A-Z0-9_]*),\s*restricted=True\)",
        handlers_source,
    )
    try:
        return sorted(packet_ids[name] for name in restricted_names)
    except KeyError as exc:
        raise ConfigError(f"reference restricted handler names unknown packet {exc.args[0]!r}") from exc


def _attest_reference_presence_request_all(root: Path) -> dict[str, object]:
    attestation_id = "reference-presence-request-all-shadowed-set-routing"
    handler_path = root / "app/api/domains/cho.py"
    collections_path = root / "app/objects/collections.py"
    try:
        handler_tree = ast.parse(handler_path.read_text(encoding="utf-8"), filename=str(handler_path))
        collections_tree = ast.parse(
            collections_path.read_text(encoding="utf-8"),
            filename=str(collections_path),
        )
    except (OSError, SyntaxError) as exc:
        raise ConfigError("cannot inspect the pinned reference packet 98 routing contract") from exc

    handler_class = _ast_class(handler_tree, "UserPresenceRequestAll")
    handle = _ast_method(handler_class, "handle", async_only=True)
    expected_decorator = ast.parse(
        "@register(ClientPackets.USER_PRESENCE_REQUEST_ALL)\nclass Probe:\n    pass\n"
    ).body[0].decorator_list[0]
    if (
        len(handler_class.decorator_list) != 1
        or _ast_shape(handler_class.decorator_list[0]) != _ast_shape(expected_decorator)
        or [argument.arg for argument in handle.args.args] != ["self", "player"]
        or handle.args.vararg is not None
        or handle.args.kwarg is not None
        or handle.args.kwonlyargs
        or handle.args.defaults
        or handle.args.kw_defaults
    ):
        raise ConfigError("pinned reference packet 98 registration or handle signature changed")
    expected_handle = ast.parse(
        "async def handle(self, player):\n"
        "    buffer = bytearray()\n"
        "    for player in app.state.sessions.players.unrestricted:\n"
        "        buffer += app.packets.user_presence(player)\n"
        "    player.enqueue(bytes(buffer))\n"
    ).body[0]
    if _ast_shape(handle.body) != _ast_shape(expected_handle.body):
        raise ConfigError("pinned reference packet 98 no longer has the attested shadowed enqueue shape")

    players_class = _ast_class(collections_tree, "Players")
    unrestricted = _ast_method(players_class, "unrestricted", async_only=False)
    unrestricted_body = list(unrestricted.body)
    if (
        unrestricted_body
        and isinstance(unrestricted_body[0], ast.Expr)
        and isinstance(unrestricted_body[0].value, ast.Constant)
        and isinstance(unrestricted_body[0].value.value, str)
    ):
        unrestricted_body = unrestricted_body[1:]
    expected_property = ast.parse(
        "@property\n"
        "def unrestricted(self):\n"
        "    return {p for p in self if p.priv & Privileges.UNRESTRICTED}\n"
    ).body[0]
    if (
        [argument.arg for argument in unrestricted.args.args] != ["self"]
        or len(unrestricted.decorator_list) != 1
        or _ast_shape(unrestricted.decorator_list[0]) != _ast_shape(expected_property.decorator_list[0])
        or _ast_shape(unrestricted_body) != _ast_shape(expected_property.body)
    ):
        raise ConfigError("pinned reference unrestricted-player collection is no longer the attested set")

    return {
        "id": attestation_id,
        "attested": True,
        "handler": "app/api/domains/cho.py:UserPresenceRequestAll.handle",
        "membership": "app/objects/collections.py:Players.unrestricted",
        "contract": "set iteration shadows the requester and enqueues the bundle to the final iterated member",
    }


def _ast_class(tree: ast.AST, name: str) -> ast.ClassDef:
    matches = [node for node in ast.walk(tree) if isinstance(node, ast.ClassDef) and node.name == name]
    if len(matches) != 1:
        raise ConfigError(f"pinned reference source must contain exactly one {name} class")
    return matches[0]


def _ast_method(
    class_node: ast.ClassDef,
    name: str,
    *,
    async_only: bool,
) -> ast.FunctionDef | ast.AsyncFunctionDef:
    expected_type = ast.AsyncFunctionDef if async_only else ast.FunctionDef
    matches = [node for node in class_node.body if isinstance(node, expected_type) and node.name == name]
    if len(matches) != 1:
        raise ConfigError(f"pinned reference source must contain exactly one {class_node.name}.{name}")
    return matches[0]


def _ast_shape(value: ast.AST | list[ast.stmt]) -> str:
    if isinstance(value, list):
        return "[" + ",".join(ast.dump(node, include_attributes=False) for node in value) + "]"
    return ast.dump(value, include_attributes=False)


def _emit(report: dict, *, failed: bool) -> int:
    sys.stdout.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
