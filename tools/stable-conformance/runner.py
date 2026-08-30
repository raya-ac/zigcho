"""Stateful, dual-target Stable transcript runner."""

from __future__ import annotations

import base64
import copy
import hashlib
import hmac
import json
import math
import os
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping

from http_target import HttpResponse, TargetClient, TransportError, prepare_request
from normalization import NormalizationError, apply_rules, first_difference
from strict_json import StrictJsonError, load_path, loads as strict_json_loads
from transcript import TranscriptError, encode_body, load_transcript


class ConfigError(ValueError):
    pass


_MISSING = object()
_COMMIT = re.compile(r"^[0-9a-f]{40}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_EVIDENCE_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{2,127}$")
_VALUE_PLACEHOLDER = re.compile(r"{{([a-zA-Z_][a-zA-Z0-9_.-]*)}}")
_PLACEHOLDER_FIXTURES = {
    "fixture",
    "replace-me",
    "replace-with-an-isolated-fixture-id",
    "unknown",
}


@dataclass
class TargetState:
    name: str
    client: TargetClient
    variables: dict[str, Any]
    secret_values: set[str] = field(default_factory=set)
    allows_mutation: bool = False


@dataclass
class RunOptions:
    allow_mutating: bool = False
    require_all: bool = False
    continue_on_failure: bool = False
    source_attestations: frozenset[str] = field(default_factory=frozenset)


def load_config(path: str | Path) -> tuple[dict[str, Any], dict[str, TargetState]]:
    source = Path(path)
    try:
        config = load_path(source)
    except (OSError, StrictJsonError) as exc:
        raise ConfigError(f"cannot load {source}: {exc}") from exc
    if not isinstance(config, dict) or config.get("schema") != 1:
        raise ConfigError("configuration schema must be 1")
    unknown_config = set(config) - {"metadata", "schema", "targets", "variables"}
    if unknown_config:
        raise ConfigError(f"unsupported configuration key {sorted(unknown_config)[0]!r}")
    metadata = config.get("metadata", {})
    if not isinstance(metadata, dict) or not all(
        isinstance(key, str) and isinstance(value, (str, int, float, bool))
        for key, value in metadata.items()
    ):
        raise ConfigError("configuration metadata must contain only scalar JSON values")
    unknown_metadata = set(metadata) - {
        "fixture",
        "fixture_reset_at",
        "fixture_snapshot_sha256",
        "zigcho_commit",
        "reference_commit",
    }
    if unknown_metadata:
        raise ConfigError(f"unsupported configuration metadata key {sorted(unknown_metadata)[0]!r}")
    shared, shared_secrets = _resolve_variables(config.get("variables", {}), "variables")
    raw_targets = config.get("targets")
    if not isinstance(raw_targets, dict) or not raw_targets:
        raise ConfigError("configuration targets must be a non-empty object")
    states: dict[str, TargetState] = {}
    for name, raw in raw_targets.items():
        if not isinstance(raw, dict):
            raise ConfigError(f"targets.{name} must be an object")
        unknown_target = set(raw) - {"allow_mutating", "limits", "origin", "variables"}
        if unknown_target:
            raise ConfigError(f"targets.{name} has unsupported key {sorted(unknown_target)[0]!r}")
        origin = raw.get("origin")
        if not isinstance(origin, str):
            raise ConfigError(f"targets.{name}.origin must be a string")
        specific, specific_secrets = _resolve_variables(raw.get("variables", {}), f"targets.{name}.variables")
        merged = _merge_variables(shared, specific)
        limits = raw.get("limits", {})
        if not isinstance(limits, dict):
            raise ConfigError(f"targets.{name}.limits must be an object")
        unknown_limits = set(limits) - {"max_response_bytes", "timeout_seconds"}
        if unknown_limits:
            raise ConfigError(f"targets.{name}.limits has unsupported key {sorted(unknown_limits)[0]!r}")
        timeout_seconds = limits.get("timeout_seconds", 10)
        max_response_bytes = limits.get("max_response_bytes", 16 * 1024 * 1024)
        if (
            isinstance(timeout_seconds, bool)
            or not isinstance(timeout_seconds, (int, float))
            or not math.isfinite(float(timeout_seconds))
            or timeout_seconds <= 0
        ):
            raise ConfigError(f"targets.{name}.limits.timeout_seconds must be a finite positive number")
        if type(max_response_bytes) is not int or max_response_bytes <= 0:
            raise ConfigError(f"targets.{name}.limits.max_response_bytes must be a positive integer")
        allows_mutation = raw.get("allow_mutating", False)
        if type(allows_mutation) is not bool:
            raise ConfigError(f"targets.{name}.allow_mutating must be a boolean")
        states[name] = TargetState(
            name=name,
            client=TargetClient(
                name=name,
                origin=origin,
                timeout_seconds=float(timeout_seconds),
                max_response_bytes=max_response_bytes,
            ),
            variables=merged,
            secret_values=set(shared_secrets) | set(specific_secrets),
            allows_mutation=allows_mutation,
        )
    return config, states


def validate_proof_metadata(
    config: Mapping[str, Any],
    states: Mapping[str, TargetState],
    *,
    pinned_reference_commit: str,
) -> None:
    if set(states) != {"zigcho", "reference"}:
        raise ConfigError("a complete proof requires both zigcho and reference targets")
    metadata = config.get("metadata", {})
    fixture = metadata.get("fixture") if isinstance(metadata, Mapping) else None
    if (
        not isinstance(fixture, str)
        or not _EVIDENCE_ID.fullmatch(fixture)
        or fixture in _PLACEHOLDER_FIXTURES
        or fixture.startswith("replace-")
    ):
        raise ConfigError("a complete proof requires a non-placeholder fixture evidence id")
    zigcho_commit = metadata.get("zigcho_commit")
    if not isinstance(zigcho_commit, str) or not _COMMIT.fullmatch(zigcho_commit):
        raise ConfigError("a complete proof requires an exact 40-hex zigcho_commit")
    reference_commit = metadata.get("reference_commit")
    if not isinstance(reference_commit, str) or not _COMMIT.fullmatch(reference_commit):
        raise ConfigError("a complete proof requires an exact 40-hex reference_commit")
    if reference_commit != pinned_reference_commit:
        raise ConfigError("configuration reference_commit does not match the pinned contract")
    fixture_snapshot = metadata.get("fixture_snapshot_sha256")
    if not isinstance(fixture_snapshot, str) or not _SHA256.fullmatch(fixture_snapshot):
        raise ConfigError("a complete proof requires the exact fixture snapshot SHA-256")
    reset_at = metadata.get("fixture_reset_at")
    if not isinstance(reset_at, str):
        raise ConfigError("a complete proof requires a timezone-aware fixture_reset_at")
    try:
        parsed_reset = datetime.fromisoformat(reset_at.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ConfigError("fixture_reset_at must be an ISO-8601 timestamp") from exc
    if parsed_reset.tzinfo is None:
        raise ConfigError("fixture_reset_at must include a timezone")


def run_transcripts(
    transcripts: Iterable[Mapping[str, Any]],
    states: Mapping[str, TargetState],
    *,
    options: RunOptions | None = None,
) -> dict[str, Any]:
    options = options or RunOptions()
    transcript_list = list(transcripts)
    target_names = list(states)
    if len(target_names) not in {1, 2}:
        raise ConfigError("a run must contain one smoke target or exactly two differential targets")
    if len(target_names) == 2 and set(target_names) != {"zigcho", "reference"}:
        raise ConfigError("differential targets must be named 'zigcho' and 'reference'")
    if options.require_all and set(target_names) != {"zigcho", "reference"}:
        raise ConfigError("a complete proof requires both zigcho and reference targets")
    source_attested_waivers = sorted(
        {
            step["policy_matrix"]["source_attestation"]
            for transcript in transcript_list
            for step in transcript.get("steps", [])
            if isinstance(step.get("policy_matrix"), Mapping)
            and isinstance(step["policy_matrix"].get("source_attestation"), str)
        }
    )
    if source_attested_waivers and not options.require_all:
        raise ConfigError(
            "source-attested response waivers are valid only in a complete --require-all proof"
        )
    missing_source_attestations = sorted(set(source_attested_waivers) - options.source_attestations)
    if missing_source_attestations:
        raise ConfigError(
            "complete proof did not attest required source contract(s): "
            + ", ".join(missing_source_attestations)
        )
    started = datetime.now(timezone.utc).isoformat()
    digest_key = os.urandom(32)
    fixture_preflights: list[dict[str, Any]] = []
    globally_preflighted = False
    if options.require_all:
        bindings = _validate_complete_run_requirements(transcript_list, states, options)
        fixture_preflights = _run_session_preflights(
            {"session_bindings": bindings},
            states,
            digest_key,
        )
        globally_preflighted = True
        if any(preflight["status"] != "passed" for preflight in fixture_preflights):
            return {
                "schema": 1,
                "mode": "differential" if len(target_names) == 2 else "smoke",
                "started_at": started,
                "targets": target_names,
                "fixture_preflights": fixture_preflights,
                "summary": {"passed": 0, "failed": 1, "skipped": 0, "total": 0, "required_skips": 0},
                "cases": [],
            }
    cases: list[dict[str, Any]] = []
    for transcript in transcript_list:
        case = _run_case(
            transcript,
            states,
            options,
            digest_key,
            globally_preflighted=globally_preflighted,
        )
        cases.append(case)
        if case["status"] == "failed" and not options.continue_on_failure:
            break
    summary = {
        "passed": sum(case["status"] == "passed" for case in cases),
        "failed": sum(case["status"] == "failed" for case in cases),
        "skipped": sum(case["status"] == "skipped" for case in cases),
        "total": len(cases),
    }
    summary["required_skips"] = summary["skipped"] if options.require_all else 0
    return {
        "schema": 1,
        "mode": "differential" if len(target_names) == 2 else "smoke",
        "started_at": started,
        "targets": target_names,
        "fixture_preflights": fixture_preflights,
        "summary": summary,
        "cases": cases,
    }


def _run_case(
    transcript: Mapping[str, Any],
    states: Mapping[str, TargetState],
    options: RunOptions,
    digest_key: bytes,
    *,
    globally_preflighted: bool,
) -> dict[str, Any]:
    case_id = transcript["id"]
    base = {
        "id": case_id,
        "category": transcript.get("category", "uncategorized"),
        "source": _source_label(transcript.get("_source")),
        "coverage": transcript.get("coverage", {}),
        "session_preflights": [],
        "steps": [],
    }
    if transcript.get("mutates_state", False) and not options.allow_mutating:
        return {**base, "status": "skipped", "reason": "mutating transcript requires --allow-mutating"}
    if transcript.get("mutates_state", False) and not all(state.allows_mutation for state in states.values()):
        return {
            **base,
            "status": "skipped",
            "reason": "every target config must set allow_mutating=true for a mutating transcript",
        }
    missing: dict[str, list[str]] = {}
    for target_name, state in states.items():
        absent = [name for name in transcript.get("requires", []) if not _has_path(state.variables, name)]
        if absent:
            missing[target_name] = absent
    if missing:
        return {**base, "status": "skipped", "reason": "missing fixture variables", "missing": missing}

    if not globally_preflighted:
        preflights = _run_session_preflights(transcript, states, digest_key)
        base["session_preflights"] = preflights
        if any(preflight["status"] != "passed" for preflight in preflights):
            return {**base, "status": "failed"}

    canonical_history: dict[str, dict[str, Any]] = {}
    response_group_by_step = {
        step_id: group
        for group in transcript.get("response_groups", [])
        for step_id in group["steps"]
    }
    for step in transcript["steps"]:
        group = response_group_by_step.get(step["id"])
        step_report = _run_step(
            transcript,
            step,
            states,
            digest_key,
            canonical_history,
            defer_differential_comparison=group is not None,
        )
        base["steps"].append(step_report)
        if step_report["status"] != "passed":
            return {**base, "status": "failed"}
        if group is not None and step["id"] == group["steps"][-1]:
            group_report = _check_response_group(group, canonical_history, states)
            base["steps"].append(group_report)
            if group_report["status"] != "passed":
                return {**base, "status": "failed"}
    return {**base, "status": "passed"}


def _run_step(
    transcript: Mapping[str, Any],
    step: Mapping[str, Any],
    states: Mapping[str, TargetState],
    digest_key: bytes,
    canonical_history: dict[str, dict[str, Any]],
    *,
    defer_differential_comparison: bool = False,
) -> dict[str, Any]:
    results: dict[str, Any] = {}
    canonical: dict[str, Any] = {}
    for target_name, state in states.items():
        try:
            _validate_client_packet_request(transcript, step, state.variables)
            response = state.client.request(step["request"], state.variables)
            value = canonical_response(response, step.get("response", {}))
            _validate_server_packet_response(transcript, step, value)
            _check_expectations(response, value, step.get("response", {}), state.variables)
            _apply_captures(response, value, step.get("capture", []), state)
            rules = list(transcript.get("normalizers", [])) + list(step.get("normalizers", []))
            canonical[target_name] = apply_rules(value, rules, state.variables)
            results[target_name] = {
                "status": response.status,
                "bytes": len(response.body),
                "elapsed_ms": round(response.elapsed_ms, 3),
                "body_hmac_sha256": _body_digest(response.body, digest_key),
            }
        except (ConfigError, NormalizationError, TranscriptError, TransportError, ValueError) as exc:
            return {
                "id": step["id"],
                "status": "failed",
                "targets": results,
                "error": _redact(str(exc), states.values()),
                "failed_target": target_name,
            }

    target_names = list(states)
    policy_matrix = step.get("policy_matrix")
    if policy_matrix is not None:
        try:
            _check_policy_matrix(policy_matrix, canonical, results, states, canonical_history)
        except (TranscriptError, ValueError) as exc:
            return {
                "id": step["id"],
                "status": "failed",
                "targets": results,
                "policy_id": policy_matrix["id"],
                "error": _redact(str(exc), states.values()),
            }
        report = {
            "id": step["id"],
            "status": "passed",
            "comparison": "declared_policy_matrix",
            "policy_id": policy_matrix["id"],
            "targets": results,
        }
        source_attestation = policy_matrix.get("source_attestation")
        if source_attestation is not None:
            report.update(
                {
                    "comparison": "source_attested_split_contract",
                    "live_differential_body": False,
                    "reference_evidence_type": "static_source",
                    "source_attestation": source_attestation,
                    "target_body_evidence": {
                        "zigcho": "executable_packet_contract",
                        "reference": "uncompared",
                    },
                }
            )
        canonical_history[step["id"]] = copy.deepcopy(canonical)
        return report
    if len(target_names) == 2 and not defer_differential_comparison:
        left_name, right_name = target_names
        difference = first_difference(canonical[left_name], canonical[right_name])
        if difference is not None:
            return {
                "id": step["id"],
                "status": "failed",
                "targets": results,
                "difference": _safe_difference(difference, states.values()),
            }
    canonical_history[step["id"]] = copy.deepcopy(canonical)
    report = {"id": step["id"], "status": "passed", "targets": results}
    if defer_differential_comparison:
        report["comparison"] = "deferred_to_causal_response_group"
    return report


def _check_response_group(
    group: Mapping[str, Any],
    canonical_history: Mapping[str, Mapping[str, Any]],
    states: Mapping[str, TargetState],
) -> dict[str, Any]:
    report: dict[str, Any] = {
        "id": f"response-group:{group['id']}",
        "kind": "causal_response_group",
        "steps": list(group["steps"]),
    }
    if len(states) != 2:
        return {**report, "status": "passed", "comparison": "single_target"}
    try:
        aggregated = {
            target_name: _aggregate_group_packets(group["steps"], target_name, canonical_history)
            for target_name in ("zigcho", "reference")
        }
    except (KeyError, TranscriptError, TypeError, ValueError) as exc:
        return {**report, "status": "failed", "error": _redact(str(exc), states.values())}
    difference = first_difference(aggregated["zigcho"], aggregated["reference"])
    if difference is not None:
        return {
            **report,
            "status": "failed",
            "difference": _safe_difference(difference, states.values()),
        }
    return {**report, "status": "passed", "comparison": "semantic_packet_sequence"}


def _aggregate_group_packets(
    step_ids: Iterable[str],
    target_name: str,
    canonical_history: Mapping[str, Mapping[str, Any]],
) -> dict[str, Any]:
    packets: list[Any] = []
    consumed = 0
    for step_id in step_ids:
        canonical = canonical_history[step_id][target_name]
        body = canonical.get("body")
        if not isinstance(body, Mapping) or body.get("complete") is not True:
            raise TranscriptError(f"response group step {step_id!r} is not a complete packet stream")
        step_packets = body.get("packets")
        if not isinstance(step_packets, list):
            raise TranscriptError(f"response group step {step_id!r} has no packet list")
        packets.extend(copy.deepcopy(step_packets))
        step_consumed = body.get("consumed", 0)
        if type(step_consumed) is not int:
            raise TranscriptError(f"response group step {step_id!r} has no consumed byte count")
        consumed += step_consumed
    return {"body": {"complete": True, "consumed": consumed, "diagnostics": [], "packets": packets}}


def _validate_client_packet_request(
    transcript: Mapping[str, Any],
    step: Mapping[str, Any],
    variables: Mapping[str, Any],
) -> None:
    body_spec = step["request"].get("body")
    if not isinstance(body_spec, Mapping) or body_spec.get("encoding") != "packet_stream":
        return
    if transcript.get("category") == "malformed-input":
        return
    from protocol import normalize_packet_stream

    encoded = encode_body(body_spec, variables)
    decoded = normalize_packet_stream(encoded or b"", direction="client")
    if decoded.get("complete") is not True:
        diagnostics = decoded.get("diagnostics", [])
        reason = diagnostics[0].get("error") if diagnostics and isinstance(diagnostics[0], Mapping) else "invalid_payload"
        raise TranscriptError(
            f"step {step['id']!r} does not encode a complete semantic client packet stream: {reason}"
        )
    diagnostics = decoded.get("diagnostics")
    if diagnostics:
        first = diagnostics[0]
        reason = first.get("error") if isinstance(first, Mapping) else "decoder_diagnostic"
        raise TranscriptError(
            f"step {step['id']!r} client packet stream has a decoder diagnostic: {reason}"
        )
    packets = decoded.get("packets")
    if not isinstance(packets, list):
        raise TranscriptError(f"step {step['id']!r} client packet stream has no decoded packet list")
    for packet in packets:
        if (
            not isinstance(packet, Mapping)
            or packet.get("compression") != 0
            or not isinstance(packet.get("payload"), Mapping)
            or str(packet.get("name", "")).startswith("unknown_")
        ):
            raise TranscriptError(
                f"step {step['id']!r} must use an uncompressed client packet with structured semantics"
            )


def _validate_server_packet_response(
    transcript: Mapping[str, Any],
    step: Mapping[str, Any],
    canonical: Mapping[str, Any],
) -> None:
    if transcript.get("category") == "malformed-input":
        return
    if step.get("response", {}).get("format") != "bancho_packets":
        return
    body = canonical.get("body")
    if not isinstance(body, Mapping) or body.get("complete") is not True:
        raise TranscriptError("response is not a complete Bancho packet stream")
    diagnostics = body.get("diagnostics")
    if diagnostics:
        first = diagnostics[0]
        reason = first.get("error") if isinstance(first, Mapping) else "decoder_diagnostic"
        raise TranscriptError(f"response Bancho packet stream has a decoder diagnostic: {reason}")
    packets = body.get("packets")
    if not isinstance(packets, list):
        raise TranscriptError("response Bancho packet stream has no decoded packet list")
    for packet in packets:
        if (
            not isinstance(packet, Mapping)
            or packet.get("compression") != 0
            or not isinstance(packet.get("payload"), Mapping)
            or str(packet.get("name", "")).startswith("unknown_")
        ):
            raise TranscriptError("response must contain uncompressed packets with structured semantics")


def _run_session_preflights(
    transcript: Mapping[str, Any],
    states: Mapping[str, TargetState],
    digest_key: bytes,
) -> list[dict[str, Any]]:
    reports: list[dict[str, Any]] = []
    for binding in transcript.get("session_bindings", []):
        targets: dict[str, Any] = {}
        canonical_by_target: dict[str, Any] = {}
        failed_target: str | None = None
        error: str | None = None
        for target_name, state in states.items():
            request = {
                "method": "POST",
                "path": "/",
                "headers": {
                    "User-Agent": "osu!",
                    "osu-token": "{{" + binding["token"] + "}}",
                },
                "body": {"encoding": "packet_stream", "packets": [{"id": 3}]},
            }
            spec = {
                "format": "bancho_packets",
                "expect_status": 200,
                "expect_packet_ids": [11],
                "packet_fields": [
                    {
                        "packet_id": 11,
                        "path": "payload.user_id",
                        "variable": binding["user_id"],
                    }
                ],
                "compare": {"status": True, "content_type": False, "body": True},
            }
            try:
                response = state.client.request(request, state.variables)
                canonical = canonical_response(response, spec)
                _check_expectations(response, canonical, spec, state.variables)
                canonical_by_target[target_name] = apply_rules(
                    canonical,
                    [
                        {
                            "kind": "variable",
                            "path": "body.packets.0.payload.user_id",
                            "variable": binding["user_id"],
                        }
                    ],
                    state.variables,
                )
                targets[target_name] = {
                    "status": response.status,
                    "bytes": len(response.body),
                    "elapsed_ms": round(response.elapsed_ms, 3),
                    "body_hmac_sha256": _body_digest(response.body, digest_key),
                }
            except (ConfigError, NormalizationError, TranscriptError, TransportError, ValueError) as exc:
                failed_target = target_name
                error = _redact(str(exc), states.values())
                break
        comparison_difference = None
        if failed_target is None and len(states) == 2:
            comparison_difference = first_difference(
                canonical_by_target["zigcho"],
                canonical_by_target["reference"],
            )
            if comparison_difference is not None:
                error = "session preflight responses differ"
        report = {
            "token_variable": binding["token"],
            "user_id_variable": binding["user_id"],
            "status": "failed" if failed_target is not None or comparison_difference is not None else "passed",
            "targets": targets,
        }
        if failed_target is not None:
            report["failed_target"] = failed_target
            report["error"] = error
        elif comparison_difference is not None:
            report["error"] = error
            report["difference"] = _safe_difference(comparison_difference, states.values())
        reports.append(report)
    return reports


def _validate_complete_run_requirements(
    transcripts: list[Mapping[str, Any]],
    states: Mapping[str, TargetState],
    options: RunOptions,
) -> list[dict[str, str]]:
    mutating = [transcript["id"] for transcript in transcripts if transcript.get("mutates_state", False)]
    if mutating and not options.allow_mutating:
        raise ConfigError("the complete corpus contains mutations and requires --allow-mutating")
    if mutating and not all(state.allows_mutation for state in states.values()):
        raise ConfigError("every target config must set allow_mutating=true before a complete run")

    missing: list[str] = []
    for transcript in transcripts:
        for target_name, state in states.items():
            for name in transcript.get("requires", []):
                if not _has_path(state.variables, name):
                    missing.append(f"{transcript['id']}:{target_name}:{name}")
    if missing:
        raise ConfigError("complete fixture is missing variables: " + ", ".join(sorted(missing)))

    _validate_complete_variable_plan(transcripts, states)
    if any(transcript["id"] == "account-policy" for transcript in transcripts):
        for target_name, state in states.items():
            restricted_channel = _get_path(state.variables, "stable_restricted_channel")
            if restricted_channel not in {"#announce", "#osu"}:
                raise ConfigError(f"{target_name} restricted channel must be #osu or #announce")

    bindings: list[dict[str, str]] = []
    seen_binding_paths: set[tuple[str, str]] = set()
    identity_roles: list[str] = []
    seen_identity_roles: set[str] = set()
    for transcript in transcripts:
        for binding in transcript.get("session_bindings", []):
            pair = (binding["token"], binding["user_id"])
            if pair not in seen_binding_paths:
                bindings.append(dict(binding))
                seen_binding_paths.add(pair)
            if binding["user_id"] not in seen_identity_roles:
                identity_roles.append(binding["user_id"])
                seen_identity_roles.add(binding["user_id"])
        for role_path in transcript.get("identity_roles", []):
            if role_path not in seen_identity_roles:
                identity_roles.append(role_path)
                seen_identity_roles.add(role_path)

    for target_name, state in states.items():
        seen_tokens: dict[str, str] = {}
        seen_users: dict[int, str] = {}
        for binding in bindings:
            token = _get_path(state.variables, binding["token"])
            if not isinstance(token, str) or not token:
                raise ConfigError(f"{target_name} session token {binding['token']!r} must be non-empty text")
            if token in seen_tokens and seen_tokens[token] != binding["token"]:
                raise ConfigError(f"{target_name} fixture reuses one session token across roles")
            seen_tokens[token] = binding["token"]
        for role_path in identity_roles:
            user_id = _get_path(state.variables, role_path)
            if type(user_id) is not int or user_id <= 0:
                raise ConfigError(f"{target_name} fixture user role {role_path!r} must be a positive integer")
            if user_id in seen_users and seen_users[user_id] != role_path:
                raise ConfigError(f"{target_name} fixture reuses one user across roles")
            seen_users[user_id] = role_path
    return bindings


def _validate_complete_variable_plan(
    transcripts: Iterable[Mapping[str, Any]],
    states: Mapping[str, TargetState],
) -> None:
    missing: list[str] = []
    shadowed: list[str] = []
    for transcript in transcripts:
        for target_name, state in states.items():
            captured: set[str] = set()
            planned_variables = copy.deepcopy(state.variables)
            for step in transcript["steps"]:
                before_capture = _placeholder_paths(step["request"]) | _response_variable_paths(
                    step.get("response", {})
                )
                for variable in before_capture:
                    if variable not in captured and not _has_path(state.variables, variable):
                        missing.append(f"{transcript['id']}:{step['id']}:{target_name}:{variable}")
                for capture in step.get("capture", []):
                    name = capture["as"]
                    if name in captured or _has_path(state.variables, name):
                        shadowed.append(f"{transcript['id']}:{step['id']}:{target_name}:{name}")
                    captured.add(name)
                after_capture = _normalizer_variable_paths(transcript.get("normalizers", []))
                after_capture.update(_normalizer_variable_paths(step.get("normalizers", [])))
                after_capture.update(_policy_variable_paths(step.get("policy_matrix")))
                for variable in after_capture:
                    if variable not in captured and not _has_path(state.variables, variable):
                        missing.append(f"{transcript['id']}:{step['id']}:{target_name}:{variable}")
                try:
                    prepare_request(step["request"], planned_variables)
                    _validate_client_packet_request(transcript, step, planned_variables)
                except (KeyError, TranscriptError, TypeError, ValueError) as exc:
                    raise ConfigError(
                        f"complete request plan cannot encode {transcript['id']}:{step['id']}:{target_name}: {exc}"
                    ) from exc
                for capture in step.get("capture", []):
                    _set_path(
                        planned_variables,
                        capture["as"],
                        1 if capture.get("type", "string") == "int" else "planned-capture",
                    )
    if missing:
        raise ConfigError("complete request plan has unresolved variables: " + ", ".join(sorted(missing)))
    if shadowed:
        raise ConfigError("complete request plan has shadowed capture names: " + ", ".join(sorted(shadowed)))


def _placeholder_paths(value: Any) -> set[str]:
    if isinstance(value, str):
        return set(_VALUE_PLACEHOLDER.findall(value))
    if isinstance(value, Mapping):
        return {name for child in value.values() for name in _placeholder_paths(child)}
    if isinstance(value, (list, tuple)):
        return {name for child in value for name in _placeholder_paths(child)}
    return set()


def _response_variable_paths(response: Any) -> set[str]:
    if not isinstance(response, Mapping):
        return set()
    output = {
        path
        for key in (
            "expect_text_lines_exclude_variables",
            "expect_text_lines_include_variables",
        )
        for path in response.get(key, [])
        if isinstance(path, str)
    }
    output.update(_field_variable_paths(response.get("packet_fields", [])))
    return output


def _normalizer_variable_paths(rules: Any) -> set[str]:
    if not isinstance(rules, list):
        return set()
    return {
        rule["variable"]
        for rule in rules
        if isinstance(rule, Mapping)
        and rule.get("kind") == "variable"
        and isinstance(rule.get("variable"), str)
    }


def _policy_variable_paths(matrix: Any) -> set[str]:
    if not isinstance(matrix, Mapping):
        return set()
    output: set[str] = set()
    targets = matrix.get("targets", {})
    if not isinstance(targets, Mapping):
        return output
    for expected in targets.values():
        if not isinstance(expected, Mapping):
            continue
        output.update(_field_variable_paths(expected.get("fields", [])))
        output.update(_field_variable_paths(expected.get("packet_field_counts", [])))
        output.update(_field_variable_paths(expected.get("packet_fields", [])))
    return output


def _field_variable_paths(fields: Any) -> set[str]:
    if not isinstance(fields, list):
        return set()
    return {
        field["variable"]
        for field in fields
        if isinstance(field, Mapping) and isinstance(field.get("variable"), str)
    }


def _safe_difference(difference: Any, states: Iterable[TargetState]) -> dict[str, Any]:
    safe = difference.as_dict()
    if safe["path"] == "$.body" or safe["path"].startswith(("$.body.", "$.body[")):
        safe["left"] = "<redacted:response-body>"
        safe["right"] = "<redacted:response-body>"
    else:
        state_list = tuple(states)
        safe["left"] = redact_value(safe["left"], state_list)
        safe["right"] = redact_value(safe["right"], state_list)
    return safe


def _source_label(source: Any) -> str:
    if not isinstance(source, str) or source == "<memory>":
        return "<memory>"
    return f"transcript:{Path(source).name}"


def _check_policy_matrix(
    matrix: Mapping[str, Any],
    canonical: Mapping[str, Any],
    results: Mapping[str, Any],
    states: Mapping[str, TargetState],
    canonical_history: Mapping[str, Mapping[str, Any]],
) -> None:
    if set(states) != {"zigcho", "reference"}:
        raise TranscriptError("a policy matrix requires both named differential targets")
    for target_name in ("zigcho", "reference"):
        expected = matrix["targets"][target_name]
        actual_status = results[target_name]["status"]
        expected_statuses = expected["status"] if isinstance(expected["status"], list) else [expected["status"]]
        if actual_status not in expected_statuses:
            raise TranscriptError(
                f"policy {matrix['id']!r} expected {target_name} status {expected_statuses}, got {actual_status}"
            )
        has_packet_contract = "packet_ids" in expected or "required_packet_ids" in expected
        if not has_packet_contract:
            if expected.get("body_policy") != "uncompared":
                raise TranscriptError(f"policy {matrix['id']!r} has no {target_name} body contract")
            continue
        body = canonical[target_name].get("body")
        if not isinstance(body, dict) or body.get("complete") is not True:
            raise TranscriptError(f"policy {matrix['id']!r} got an incomplete {target_name} packet stream")
        packets = body.get("packets")
        if not isinstance(packets, list):
            raise TranscriptError(f"policy {matrix['id']!r} has no {target_name} packet list")
        actual_ids = [packet.get("id") for packet in packets]
        if "packet_ids" in expected and actual_ids != expected["packet_ids"]:
            raise TranscriptError(
                f"policy {matrix['id']!r} expected {target_name} packet ids {expected['packet_ids']}, got {actual_ids}"
            )
        missing_ids = sorted(set(expected.get("required_packet_ids", [])) - set(actual_ids))
        forbidden_ids = sorted(set(expected.get("forbidden_packet_ids", [])) & set(actual_ids))
        if missing_ids or forbidden_ids:
            raise TranscriptError(
                f"policy {matrix['id']!r} {target_name} missing packet ids {missing_ids} or emitted forbidden ids {forbidden_ids}"
            )
        allowed_ids = expected.get("allowed_packet_ids")
        if allowed_ids is not None:
            unexpected_ids = sorted(set(actual_ids) - set(allowed_ids))
            if unexpected_ids:
                raise TranscriptError(
                    f"policy {matrix['id']!r} {target_name} emitted packets outside its allowlist {unexpected_ids}"
                )
        if "packet_ids" not in expected:
            duplicate_allowlist = set(expected.get("allow_duplicate_packet_ids", []))
            repeated = sorted(
                packet_id
                for packet_id in set(actual_ids)
                if actual_ids.count(packet_id) > 1 and packet_id not in duplicate_allowlist
            )
            if repeated:
                raise TranscriptError(
                    f"policy {matrix['id']!r} {target_name} repeated packet ids outside its duplicate allowlist {repeated}"
                )
            required_in_order = expected.get("required_packet_ids", [])
            if required_in_order and not _is_subsequence(required_in_order, actual_ids):
                raise TranscriptError(
                    f"policy {matrix['id']!r} {target_name} did not preserve required packet order {required_in_order}"
                )
        for field in expected.get("fields", []):
            actual = _get_path(canonical[target_name], field["path"])
            wanted = _get_path(states[target_name].variables, field["variable"])
            if type(actual) is not type(wanted) or actual != wanted:
                raise TranscriptError(
                    f"policy {matrix['id']!r} field {field['path']!r} did not equal variable {field['variable']!r}"
                )
        for field in expected.get("packet_fields", []):
            matches = [packet for packet in packets if packet.get("id") == field["packet_id"]]
            occurrence = field.get("occurrence", 0)
            if type(occurrence) is not int or occurrence < 0 or occurrence >= len(matches):
                raise TranscriptError(
                    f"policy {matrix['id']!r} has no {target_name} packet {field['packet_id']} occurrence {occurrence}"
                )
            actual = _get_path(matches[occurrence], field["path"])
            if "variable" in field:
                wanted = _get_path(states[target_name].variables, field["variable"])
                matched = type(actual) is type(wanted) and actual == wanted
            elif "value" in field:
                wanted = field["value"]
                matched = type(actual) is type(wanted) and actual == wanted
            else:
                predicate = field["predicate"]
                matched = type(actual) is int and (actual > 0 if predicate == "positive" else actual < 0)
            if not matched:
                raise TranscriptError(
                    f"policy {matrix['id']!r} packet {field['packet_id']} field {field['path']!r} did not match"
                )
        for field in expected.get("packet_field_counts", []):
            matching_packets = [
                packet
                for packet in packets
                if packet.get("id") == field["packet_id"]
                and _packet_field_matches(packet, field, states[target_name].variables)
            ]
            if len(matching_packets) != field["count"]:
                raise TranscriptError(
                    f"policy {matrix['id']!r} expected {target_name} packet {field['packet_id']} "
                    f"field {field['path']!r} to match exactly {field['count']} time(s), "
                    f"got {len(matching_packets)}"
                )
    for packet_id in matrix.get("compare_packet_ids", []):
        selected = {
            target_name: [
                packet
                for packet in canonical[target_name]["body"]["packets"]
                if packet.get("id") == packet_id
            ]
            for target_name in ("zigcho", "reference")
        }
        difference = first_difference(
            selected["zigcho"],
            selected["reference"],
            path=f"$.packets[id={packet_id}]",
        )
        if difference is not None:
            raise TranscriptError(
                f"policy {matrix['id']!r} selected packet {packet_id} has an undeclared semantic difference at {difference.path}"
            )
    removals = matrix.get("compare_after_removing")
    if removals is not None:
        stripped: dict[str, Any] = {}
        for target_name in ("zigcho", "reference"):
            value = copy.deepcopy(canonical[target_name])
            body = value.get("body")
            if not isinstance(body, dict) or not isinstance(body.get("packets"), list):
                raise TranscriptError(f"policy {matrix['id']!r} cannot compare a non-packet response")
            removed = set(removals[target_name])
            body["packets"] = [packet for packet in body["packets"] if packet.get("id") not in removed]
            body.pop("remainder", None)
            stripped[target_name] = value
        difference = first_difference(stripped["zigcho"], stripped["reference"])
        if difference is not None:
            raise TranscriptError(
                f"policy {matrix['id']!r} left an undeclared semantic difference at {difference.path}"
            )
    for target_name, prior_step in matrix.get("compare_target_with_step", {}).items():
        prior = canonical_history.get(prior_step)
        if prior is None or target_name not in prior:
            raise TranscriptError(
                f"policy {matrix['id']!r} cannot compare {target_name} with unavailable step {prior_step!r}"
            )
        difference = first_difference(canonical[target_name], prior[target_name])
        if difference is not None:
            raise TranscriptError(
                f"policy {matrix['id']!r} changed {target_name} from baseline step {prior_step!r} at {difference.path}"
            )
    for target_name, comparison in matrix.get("compare_target_with_step_target", {}).items():
        prior_step = comparison["step"]
        prior_target = comparison["target"]
        prior = canonical_history.get(prior_step)
        if prior is None or prior_target not in prior:
            raise TranscriptError(
                f"policy {matrix['id']!r} cannot compare {target_name} with unavailable {prior_target} step {prior_step!r}"
            )
        difference = first_difference(canonical[target_name], prior[prior_target])
        if difference is not None:
            raise TranscriptError(
                f"policy {matrix['id']!r} changed routed payload between {prior_target} step {prior_step!r} and {target_name} at {difference.path}"
            )


def _is_subsequence(required: list[int], actual: list[Any]) -> bool:
    position = 0
    for packet_id in actual:
        if position < len(required) and packet_id == required[position]:
            position += 1
    return position == len(required)


def _packet_field_matches(
    packet: Mapping[str, Any],
    field: Mapping[str, Any],
    variables: Mapping[str, Any],
) -> bool:
    try:
        actual = _get_path(packet, field["path"])
    except (KeyError, TranscriptError, TypeError, ValueError):
        return False
    if "variable" in field:
        wanted = _get_path(variables, field["variable"])
    else:
        wanted = field["value"]
    return type(actual) is type(wanted) and actual == wanted


def canonical_response(response: HttpResponse, spec: Mapping[str, Any]) -> dict[str, Any]:
    comparison = spec.get("compare", {})
    if not isinstance(comparison, dict):
        raise TranscriptError("response.compare must be an object")
    output: dict[str, Any] = {}
    if comparison.get("status", True):
        output["status"] = response.status
    if comparison.get("content_type", True):
        output["content_type"] = response.content_type
    header_names = comparison.get("headers", [])
    if not isinstance(header_names, list) or not all(isinstance(name, str) for name in header_names):
        raise TranscriptError("response.compare.headers must be an array of names")
    if header_names:
        output["headers"] = {name.lower(): response.headers.get(name.lower(), []) for name in header_names}
    if comparison.get("body", True):
        output["body"] = _decode_body(response.body, spec.get("format", "binary"))
    return output


def _decode_body(body: bytes, body_format: str) -> Any:
    if body_format == "binary":
        return {"encoding": "base64", "value": base64.b64encode(body).decode("ascii")}
    if body_format == "text":
        try:
            return body.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise TranscriptError(f"response is not valid UTF-8 at byte {exc.start}") from exc
    if body_format == "json":
        try:
            return strict_json_loads(body.decode("utf-8"))
        except (UnicodeDecodeError, StrictJsonError) as exc:
            raise TranscriptError(f"response is not valid JSON: {exc}") from exc
    if body_format == "bancho_packets":
        from protocol import normalize_packet_stream  # Imported late for focused unit tests.

        return normalize_packet_stream(body, direction="server")
    raise TranscriptError(f"unsupported response format {body_format!r}")


def _check_expectations(
    response: HttpResponse,
    canonical: Mapping[str, Any],
    response_spec: Mapping[str, Any],
    variables: Mapping[str, Any],
) -> None:
    expected_status = response_spec.get("expect_status")
    if expected_status is not None:
        allowed = expected_status if isinstance(expected_status, list) else [expected_status]
        actual = response.status
        if actual not in allowed:
            raise TranscriptError(f"expected HTTP status {allowed}, got {actual}")
    expected_type = response_spec.get("expect_content_type")
    if expected_type is not None and response.content_type != expected_type:
        raise TranscriptError(
            f"expected content type {expected_type!r}, got {response.content_type!r}"
        )
    if response_spec.get("expect_nonempty", False) and not response.body:
        raise TranscriptError("expected a non-empty response body")

    text_expectations = {
        "expect_text_equals",
        "expect_text_contains",
        "expect_text_lines_exclude_variables",
        "expect_text_lines_include_variables",
        "expect_text_not_contains",
    } & set(response_spec)
    if text_expectations:
        body = canonical.get("body")
        if not isinstance(body, str):
            raise TranscriptError("text expectations require a decoded text response body")
        if "expect_text_equals" in response_spec and body != response_spec["expect_text_equals"]:
            raise TranscriptError("response text did not equal the declared contract")
        missing = [needle for needle in response_spec.get("expect_text_contains", []) if needle not in body]
        forbidden = [needle for needle in response_spec.get("expect_text_not_contains", []) if needle in body]
        if missing or forbidden:
            raise TranscriptError(
                f"response text missing required markers {missing} or contained forbidden markers {forbidden}"
            )
        lines = set(body.splitlines())
        required_lines = {
            str(_get_path(variables, path))
            for path in response_spec.get("expect_text_lines_include_variables", [])
        }
        forbidden_lines = {
            str(_get_path(variables, path))
            for path in response_spec.get("expect_text_lines_exclude_variables", [])
        }
        if not required_lines.issubset(lines) or forbidden_lines & lines:
            raise TranscriptError("response text line membership did not match the declared variables")

    packet_expectations = {
        "expect_packet_ids",
        "require_packet_ids",
        "forbid_packet_ids",
        "packet_fields",
    } & set(response_spec)
    if packet_expectations:
        body = canonical.get("body")
        if not isinstance(body, Mapping) or body.get("complete") is not True:
            raise TranscriptError("packet expectations require a complete Bancho packet stream")
        packets = body.get("packets")
        if not isinstance(packets, list):
            raise TranscriptError("packet expectations require a decoded packet list")
        actual_ids = [packet.get("id") for packet in packets]
        if "expect_packet_ids" in response_spec and actual_ids != response_spec["expect_packet_ids"]:
            raise TranscriptError(
                f"expected packet ids {response_spec['expect_packet_ids']}, got {actual_ids}"
            )
        missing_ids = sorted(set(response_spec.get("require_packet_ids", [])) - set(actual_ids))
        forbidden_ids = sorted(set(response_spec.get("forbid_packet_ids", [])) & set(actual_ids))
        if missing_ids or forbidden_ids:
            raise TranscriptError(
                f"response missing packet ids {missing_ids} or emitted forbidden ids {forbidden_ids}"
            )
        _check_packet_fields(packets, response_spec.get("packet_fields", []), variables, context="response")


def _check_packet_fields(
    packets: list[Any],
    fields: Iterable[Mapping[str, Any]],
    variables: Mapping[str, Any],
    *,
    context: str,
) -> None:
    for field in fields:
        matches = [packet for packet in packets if isinstance(packet, Mapping) and packet.get("id") == field["packet_id"]]
        occurrence = field.get("occurrence", 0)
        if occurrence >= len(matches):
            raise TranscriptError(
                f"{context} has no packet {field['packet_id']} occurrence {occurrence}"
            )
        actual = _get_path(matches[occurrence], field["path"])
        if "variable" in field:
            wanted = _get_path(variables, field["variable"])
            matched = type(actual) is type(wanted) and actual == wanted
        elif "value" in field:
            wanted = field["value"]
            matched = type(actual) is type(wanted) and actual == wanted
        else:
            predicate = field["predicate"]
            matched = type(actual) is int and (actual > 0 if predicate == "positive" else actual < 0)
        if not matched:
            raise TranscriptError(
                f"{context} packet {field['packet_id']} field {field['path']!r} did not match"
            )


def _body_digest(body: bytes, key: bytes) -> str:
    return hmac.new(key, body, hashlib.sha256).hexdigest()


def _apply_captures(
    response: HttpResponse,
    canonical: Mapping[str, Any],
    captures: Iterable[Mapping[str, Any]],
    state: TargetState,
) -> None:
    for capture in captures:
        if capture["from"] == "header":
            value = response.header(capture["name"])
            if value is None:
                raise TranscriptError(f"capture header {capture['name']!r} is missing")
        elif capture["from"] == "path":
            value = _get_path(canonical, capture["path"])
        else:
            body = canonical.get("body")
            if not isinstance(body, str):
                raise TranscriptError("text_prefix capture requires a decoded text response")
            prefix = capture["prefix"]
            matches = [line[len(prefix) :] for line in body.splitlines() if line.startswith(prefix)]
            if len(matches) != 1 or not matches[0]:
                raise TranscriptError(f"capture prefix {prefix!r} did not match exactly one response line")
            value = matches[0]
        if capture.get("type", "string") == "int":
            try:
                value = int(value)
            except (TypeError, ValueError) as exc:
                raise TranscriptError(f"capture {capture['as']!r} is not an integer") from exc
        _set_path(state.variables, capture["as"], value)
        if capture.get("secret", True):
            _collect_secret(value, state.secret_values)


def _get_path(value: Any, path: str) -> Any:
    current = value
    for part in path.split("."):
        if isinstance(current, list):
            try:
                current = current[int(part)]
            except (ValueError, IndexError) as exc:
                raise TranscriptError(f"capture path {path!r} does not exist") from exc
        elif isinstance(current, Mapping) and part in current:
            current = current[part]
        else:
            raise TranscriptError(f"capture path {path!r} does not exist")
    return current


def _resolve_variables(value: Any, path: str) -> tuple[dict[str, Any], set[str]]:
    if not isinstance(value, dict):
        raise ConfigError(f"{path} must be an object")
    secrets: set[str] = set()

    def resolve(item: Any, item_path: str) -> Any:
        if isinstance(item, dict) and ("env" in item or "value" in item):
            unknown_wrapper = set(item) - {"env", "required", "secret", "type", "value"}
            if unknown_wrapper:
                raise ConfigError(f"{item_path} has unsupported key {sorted(unknown_wrapper)[0]!r}")
            if "env" in item and "value" in item:
                raise ConfigError(f"{item_path} cannot contain both env and value")
            if "secret" in item and type(item["secret"]) is not bool:
                raise ConfigError(f"{item_path}.secret must be a boolean")
            if "required" in item and type(item["required"]) is not bool:
                raise ConfigError(f"{item_path}.required must be a boolean")
            if "required" in item and "env" not in item:
                raise ConfigError(f"{item_path}.required is only valid for environment variables")
            if "env" in item:
                env_name = item["env"]
                if not isinstance(env_name, str) or not env_name:
                    raise ConfigError(f"{item_path}.env must be a non-empty string")
                if env_name not in os.environ:
                    if item.get("required", False):
                        raise ConfigError(f"{item_path}: environment variable {env_name!r} is missing")
                    return _MISSING
                resolved = os.environ[env_name]
            else:
                resolved = item["value"]
            value_type = item.get("type", "string" if "env" in item else "native")
            try:
                if value_type == "string":
                    resolved = str(resolved)
                elif value_type == "int":
                    resolved = int(resolved)
                elif value_type == "float":
                    resolved = float(resolved)
                    if not math.isfinite(resolved):
                        raise ConfigError(f"{item_path} must resolve to a finite float")
                elif value_type == "json":
                    resolved = strict_json_loads(resolved) if isinstance(resolved, str) else resolved
                elif value_type != "native":
                    raise ConfigError(f"{item_path}.type is unsupported")
            except (TypeError, ValueError, StrictJsonError) as exc:
                raise ConfigError(f"{item_path} cannot be converted to {value_type}") from exc
            if item.get("secret", False):
                _collect_secret(resolved, secrets)
            return resolved
        if isinstance(item, dict):
            output = {}
            for key, child in item.items():
                resolved_child = resolve(child, f"{item_path}.{key}")
                if resolved_child is not _MISSING:
                    output[key] = resolved_child
            return output
        if isinstance(item, list):
            output = [resolve(child, f"{item_path}[{index}]") for index, child in enumerate(item)]
            return [child for child in output if child is not _MISSING]
        return item

    resolved = {}
    for key, item in value.items():
        resolved_item = resolve(item, f"{path}.{key}")
        if resolved_item is not _MISSING:
            resolved[key] = resolved_item
    return resolved, secrets


def _merge_variables(shared: Mapping[str, Any], target: Mapping[str, Any]) -> dict[str, Any]:
    merged = dict(shared)
    for key, value in target.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = _merge_variables(merged[key], value)
        else:
            merged[key] = value
    return merged


def _has_path(value: Mapping[str, Any], path: str) -> bool:
    current: Any = value
    for part in path.split("."):
        if not isinstance(current, Mapping) or part not in current:
            return False
        current = current[part]
    return True


def _set_path(value: dict[str, Any], path: str, item: Any) -> None:
    parts = path.split(".")
    current = value
    for part in parts[:-1]:
        child = current.get(part)
        if child is None:
            child = {}
            current[part] = child
        if not isinstance(child, dict):
            raise ConfigError(f"capture path {path!r} collides with a scalar variable")
        current = child
    current[parts[-1]] = item


def _collect_secret(value: Any, output: set[str]) -> None:
    if isinstance(value, str) and value:
        output.add(value)
    elif isinstance(value, (int, float)) and not isinstance(value, bool):
        output.add(str(value))
    elif isinstance(value, Mapping):
        for item in value.values():
            _collect_secret(item, output)
    elif isinstance(value, (list, tuple, set)):
        for item in value:
            _collect_secret(item, output)


def _redact(text: str, states: Iterable[TargetState]) -> str:
    result = text
    secrets = {secret for state in states for secret in state.secret_values if secret}
    for secret in sorted(secrets, key=len, reverse=True):
        if len(secret) >= 3:
            result = result.replace(secret, "<redacted>")
        else:
            result = re.sub(
                rf"(?<![A-Za-z0-9]){re.escape(secret)}(?![A-Za-z0-9])",
                "<redacted>",
                result,
            )
    return result


def redact_value(value: Any, states: Iterable[TargetState]) -> Any:
    state_list = tuple(states)
    secrets = {secret for state in state_list for secret in state.secret_values if secret}
    if isinstance(value, (str, int, float)) and not isinstance(value, bool) and str(value) in secrets:
        return "<redacted>"
    if isinstance(value, str):
        return _redact(value, state_list)
    if isinstance(value, list):
        return [redact_value(item, state_list) for item in value]
    if isinstance(value, dict):
        return {key: redact_value(item, state_list) for key, item in value.items()}
    return value


def discover_transcripts(paths: Iterable[str | Path]) -> list[dict[str, Any]]:
    discovered: list[Path] = []
    for raw_path in paths:
        path = Path(raw_path)
        if path.is_dir():
            discovered.extend(sorted(path.glob("*.json")))
        else:
            discovered.append(path)
    transcripts = [load_transcript(path) for path in sorted(set(discovered))]
    if not transcripts:
        raise TranscriptError("no conformance transcripts were selected")
    ids: set[str] = set()
    for transcript in transcripts:
        if transcript["id"] in ids:
            raise TranscriptError(f"duplicate transcript id {transcript['id']!r}")
        ids.add(transcript["id"])
    return transcripts
