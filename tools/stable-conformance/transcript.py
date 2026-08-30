"""Transcript loading and deterministic Stable request encoding.

The conformance harness deliberately keeps fixtures as data.  Nothing in a
transcript can run a command, read a file, or make a request outside the two
origins supplied by the operator.
"""

from __future__ import annotations

import base64
import json
import re
import struct
import urllib.parse
from pathlib import Path
from typing import Any, Mapping

from strict_json import StrictJsonError, load_path


SCHEMA_VERSION = 1
_ID = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
_PLACEHOLDER = re.compile(r"{{([a-zA-Z_][a-zA-Z0-9_.-]*)}}")
_FORMATS = {"bancho_packets", "binary", "json", "text"}
_CATEGORIES = {"legacy-web", "malformed-input", "policy-matrix", "stable-packets"}
_SOURCE_ATTESTATIONS = {"reference-presence-request-all-shadowed-set-routing"}
_RESPONSE_KEYS = {
    "compare",
    "expect_content_type",
    "expect_nonempty",
    "expect_packet_ids",
    "expect_status",
    "expect_text_contains",
    "expect_text_equals",
    "expect_text_lines_exclude_variables",
    "expect_text_lines_include_variables",
    "expect_text_not_contains",
    "forbid_packet_ids",
    "format",
    "packet_fields",
    "require_packet_ids",
}
_ENCODINGS = {
    "base64",
    "concat",
    "form",
    "hex",
    "integer",
    "json",
    "packet_stream",
    "osu_string",
    "utf8",
}
_INTEGER_FORMATS = {
    "i8": "<b",
    "u8": "<B",
    "i16le": "<h",
    "u16le": "<H",
    "i32le": "<i",
    "u32le": "<I",
    "i64le": "<q",
    "u64le": "<Q",
}
_READ_ONLY_REQUESTS = {
    ("GET", "/web/bancho_connect.php"),
    ("GET", "/web/check-updates.php"),
    ("GET", "/web/osu-getseasonal.php"),
}
_IGNORABLE_LEAVES = {
    "created_at",
    "last_seen_at",
    "nonce",
    "request_id",
    "server_time",
    "timestamp",
    "token",
    "updated_at",
}
_VARIABLE_LEAVES = {
    "beatmap_id",
    "beatmap_set_id",
    "channel",
    "channel_id",
    "match_id",
    "request_id",
    "score_id",
    "sender",
    "sender_id",
    "target",
    "target_id",
    "timestamp",
    "token",
    "user_id",
    "username",
}
_PROTECTED_SEMANTIC_LEAVES = {
    "accuracy",
    "beatmap_status",
    "clock_rate",
    "leaderboard_namespace",
    "legacy_score",
    "max_combo",
    "mods",
    "pass_state",
    "passed",
    "performance",
    "pp",
    "rank_namespace",
    "ranked_score",
    "replay_availability",
    "replay_available",
    "score",
    "score_value",
    "total_score",
}
_TOP_LEVEL_KEYS = {
    "baseline_evidence",
    "behavior_assertions",
    "blockers",
    "category",
    "contract_sources",
    "coverage",
    "description",
    "fixture_contract",
    "id",
    "identity_roles",
    "known_reference_limitations",
    "mutates_state",
    "normalizers",
    "policy_assertions",
    "registered_no_output",
    "response_groups",
    "requires",
    "safety",
    "schema",
    "session_bindings",
    "steps",
}
_STEP_KEYS = {"capture", "id", "normalizers", "policy_matrix", "request", "response"}
_REQUEST_KEYS = {"body", "headers", "method", "path", "query"}
_COMPARE_KEYS = {"body", "content_type", "headers", "status"}
_BODY_KEYS = {
    "base64": {"encoding", "value"},
    "concat": {"encoding", "parts"},
    "form": {"encoding", "fields"},
    "hex": {"encoding", "value"},
    "integer": {"encoding", "format", "value"},
    "json": {"encoding", "value"},
    "osu_string": {"encoding", "value"},
    "packet_stream": {"encoding", "packets"},
    "utf8": {"encoding", "value"},
}


class TranscriptError(ValueError):
    """Raised when a transcript is unsafe, ambiguous, or malformed."""


def load_transcript(path: str | Path) -> dict[str, Any]:
    source = Path(path)
    try:
        value = load_path(source)
    except (OSError, StrictJsonError) as exc:
        raise TranscriptError(f"cannot load {source}: {exc}") from exc
    validate_transcript(value, source=str(source))
    value["_source"] = str(source)
    return value


def validate_transcript(value: Any, *, source: str = "<transcript>") -> None:
    if not isinstance(value, dict):
        raise TranscriptError(f"{source}: root must be an object")
    _reject_unknown(value, _TOP_LEVEL_KEYS, where=source)
    if value.get("schema") != SCHEMA_VERSION:
        raise TranscriptError(f"{source}: schema must be {SCHEMA_VERSION}")
    case_id = value.get("id")
    if not isinstance(case_id, str) or not _ID.fullmatch(case_id):
        raise TranscriptError(f"{source}: id must match {_ID.pattern}")
    if type(value.get("mutates_state")) is not bool:
        raise TranscriptError(f"{source}: mutates_state must be an explicit boolean")
    category = value.get("category")
    if category is not None and category not in _CATEGORIES:
        raise TranscriptError(f"{source}: category must be one of {sorted(_CATEGORIES)}")
    steps = value.get("steps")
    if not isinstance(steps, list) or not steps:
        raise TranscriptError(f"{source}: steps must be a non-empty array")

    seen: set[str] = set()
    requires = value.get("requires", [])
    if not isinstance(requires, list) or not all(
        isinstance(name, str) and all(_ID.fullmatch(part) for part in name.split("."))
        for name in requires
    ):
        raise TranscriptError(f"{source}: requires must contain safe variable paths")
    if len(requires) != len(set(requires)):
        raise TranscriptError(f"{source}: requires contains duplicates")
    session_bindings = value.get("session_bindings", [])
    _validate_session_bindings(session_bindings, requires=requires, where=f"{source}: session_bindings")
    identity_roles = value.get("identity_roles", [])
    if not isinstance(identity_roles, list) or not all(
        isinstance(path, str)
        and all(_ID.fullmatch(part) for part in path.split("."))
        and path in requires
        for path in identity_roles
    ):
        raise TranscriptError(f"{source}: identity_roles must contain unique required variable paths")
    if len(identity_roles) != len(set(identity_roles)):
        raise TranscriptError(f"{source}: identity_roles contains duplicates")
    for index, step in enumerate(steps):
        where = f"{source}: steps[{index}]"
        if not isinstance(step, dict):
            raise TranscriptError(f"{where} must be an object")
        _reject_unknown(step, _STEP_KEYS, where=where)
        step_id = step.get("id")
        if not isinstance(step_id, str) or not _ID.fullmatch(step_id):
            raise TranscriptError(f"{where}.id must match {_ID.pattern}")
        if step_id in seen:
            raise TranscriptError(f"{where}.id duplicates {step_id!r}")
        seen.add(step_id)
        request = step.get("request")
        if not isinstance(request, dict):
            raise TranscriptError(f"{where}.request must be an object")
        _reject_unknown(request, _REQUEST_KEYS, where=f"{where}.request")
        method = request.get("method")
        path = request.get("path")
        if not isinstance(method, str) or not method or method != method.upper():
            raise TranscriptError(f"{where}.request.method must be uppercase")
        if not isinstance(path, str) or not path.startswith("/") or path.startswith("//"):
            raise TranscriptError(f"{where}.request.path must be an origin-relative path")
        if "://" in path or "#" in path:
            raise TranscriptError(f"{where}.request.path cannot contain an origin or fragment")
        if not value["mutates_state"] and (method, path.split("?", 1)[0]) not in _READ_ONLY_REQUESTS:
            raise TranscriptError(f"{where}.request is not in the read-only allowlist")
        response = step.get("response", {})
        if not isinstance(response, dict):
            raise TranscriptError(f"{where}.response must be an object")
        unknown_response_keys = set(response) - _RESPONSE_KEYS
        if unknown_response_keys:
            raise TranscriptError(
                f"{where}.response has unsupported key {sorted(unknown_response_keys)[0]!r}"
            )
        body_format = response.get("format", "binary")
        if body_format not in _FORMATS:
            raise TranscriptError(f"{where}.response.format must be one of {sorted(_FORMATS)}")
        compare = response.get("compare", {})
        if not isinstance(compare, dict):
            raise TranscriptError(f"{where}.response.compare must be an object")
        _reject_unknown(compare, _COMPARE_KEYS, where=f"{where}.response.compare")
        for flag in ("body", "content_type", "status"):
            if flag in compare and type(compare[flag]) is not bool:
                raise TranscriptError(f"{where}.response.compare.{flag} must be a boolean")
        if "headers" in compare and (
            not isinstance(compare["headers"], list)
            or not all(isinstance(name, str) and name for name in compare["headers"])
        ):
            raise TranscriptError(f"{where}.response.compare.headers must contain names")
        expected_status = response.get("expect_status")
        expected_values = expected_status if isinstance(expected_status, list) else [expected_status]
        if expected_status is not None and (
            not expected_values
            or not all(type(status) is int and 100 <= status <= 599 for status in expected_values)
        ):
            raise TranscriptError(f"{where}.response.expect_status must contain HTTP statuses")
        if "expect_nonempty" in response and type(response["expect_nonempty"]) is not bool:
            raise TranscriptError(f"{where}.response.expect_nonempty must be a boolean")
        for key in ("expect_text_contains", "expect_text_not_contains"):
            values = response.get(key, [])
            if not isinstance(values, list) or not all(isinstance(item, str) and item for item in values):
                raise TranscriptError(f"{where}.response.{key} must contain non-empty strings")
        if "expect_text_equals" in response and not isinstance(response["expect_text_equals"], str):
            raise TranscriptError(f"{where}.response.expect_text_equals must be a string")
        if {
            "expect_text_contains",
            "expect_text_equals",
            "expect_text_lines_exclude_variables",
            "expect_text_lines_include_variables",
            "expect_text_not_contains",
        } & set(response) and body_format != "text":
            raise TranscriptError(f"{where}.response text expectations require text format")
        for key in ("expect_text_lines_include_variables", "expect_text_lines_exclude_variables"):
            values = response.get(key, [])
            if not isinstance(values, list) or not all(
                isinstance(path, str) and all(_ID.fullmatch(part) for part in path.split("."))
                for path in values
            ):
                raise TranscriptError(f"{where}.response.{key} must contain safe variable paths")
        packet_expectation_keys = {
            "expect_packet_ids",
            "forbid_packet_ids",
            "packet_fields",
            "require_packet_ids",
        }
        if packet_expectation_keys & set(response) and body_format != "bancho_packets":
            raise TranscriptError(f"{where}.response packet expectations require bancho_packets format")
        for key in ("expect_packet_ids", "require_packet_ids", "forbid_packet_ids"):
            values = response.get(key, [])
            if not isinstance(values, list) or not all(type(packet_id) is int and 0 <= packet_id <= 65535 for packet_id in values):
                raise TranscriptError(f"{where}.response.{key} must contain u16 integers")
        _validate_packet_fields(response.get("packet_fields", []), where=f"{where}.response.packet_fields")
        headers = request.get("headers", {})
        if not isinstance(headers, dict) or not all(
            isinstance(name, str) and name and isinstance(header_value, (str, int, float, bool))
            for name, header_value in headers.items()
        ):
            raise TranscriptError(f"{where}.request.headers must be a scalar object")
        folded_header_names = [name.lower() for name in headers]
        if len(folded_header_names) != len(set(folded_header_names)):
            raise TranscriptError(f"{where}.request.headers contains case-insensitive duplicates")
        query = request.get("query")
        if query is not None and not isinstance(query, (dict, list)):
            raise TranscriptError(f"{where}.request.query must be an object or array of pairs")
        _validate_body(request.get("body"), where=f"{where}.request.body")
        _validate_rules(step.get("normalizers", []), where=f"{where}.normalizers")
        _validate_captures(step.get("capture", []), where=f"{where}.capture")
        _validate_policy_matrix(step.get("policy_matrix"), category=value.get("category"), where=f"{where}.policy_matrix")

    positions = {step["id"]: index for index, step in enumerate(steps)}
    response_groups = value.get("response_groups", [])
    if not isinstance(response_groups, list):
        raise TranscriptError(f"{source}: response_groups must be an array")
    response_group_ids: set[str] = set()
    grouped_steps: set[str] = set()
    for index, group in enumerate(response_groups):
        where = f"{source}: response_groups[{index}]"
        if not isinstance(group, dict) or set(group) != {"id", "steps"}:
            raise TranscriptError(f"{where} must contain exactly id and steps")
        group_id = group["id"]
        group_steps = group["steps"]
        if not isinstance(group_id, str) or not _ID.fullmatch(group_id) or group_id in response_group_ids:
            raise TranscriptError(f"{where}.id must be a unique safe id")
        if not isinstance(group_steps, list) or len(group_steps) != 2 or not all(
            isinstance(step_id, str) and step_id in positions for step_id in group_steps
        ):
            raise TranscriptError(f"{where}.steps must contain exactly one action and its drain")
        if len(group_steps) != len(set(group_steps)) or grouped_steps & set(group_steps):
            raise TranscriptError(f"{where}.steps must be unique across response groups")
        group_positions = [positions[step_id] for step_id in group_steps]
        if group_positions != list(range(group_positions[0], group_positions[0] + len(group_positions))):
            raise TranscriptError(f"{where}.steps must be consecutive and in execution order")
        for step_id in group_steps:
            step = steps[positions[step_id]]
            if step.get("response", {}).get("format") != "bancho_packets" or "policy_matrix" in step:
                raise TranscriptError(f"{where}.steps must be non-policy Bancho packet responses")
        action_request = steps[positions[group_steps[0]]]["request"]
        drain_request = steps[positions[group_steps[1]]]["request"]
        action_packets = action_request.get("body", {}).get("packets")
        drain_packets = drain_request.get("body", {}).get("packets")
        action_token = _exact_header_placeholder(action_request, "osu-token")
        drain_token = _exact_header_placeholder(drain_request, "osu-token")
        if (
            action_request.get("method") != "POST"
            or action_request.get("path", "").split("?", 1)[0] != "/"
            or drain_request.get("method") != "POST"
            or drain_request.get("path", "").split("?", 1)[0] != "/"
            or not isinstance(action_packets, list)
            or len(action_packets) != 1
            or drain_packets != []
            or action_token is None
            or action_token != drain_token
        ):
            raise TranscriptError(
                f"{where}.steps must be one packet followed by an empty poll on the same bound session"
            )
        response_group_ids.add(group_id)
        grouped_steps.update(group_steps)
    for index, step in enumerate(steps):
        matrix = step.get("policy_matrix")
        if not isinstance(matrix, dict):
            continue
        for target, prior_step in matrix.get("compare_target_with_step", {}).items():
            if prior_step not in positions or positions[prior_step] >= index:
                raise TranscriptError(
                    f"{source}: steps[{index}].policy_matrix.compare_target_with_step.{target} must reference an earlier step"
                )
        for target, comparison in matrix.get("compare_target_with_step_target", {}).items():
            prior_step = comparison["step"]
            if prior_step not in positions or positions[prior_step] >= index:
                raise TranscriptError(
                    f"{source}: steps[{index}].policy_matrix.compare_target_with_step_target.{target}.step must reference an earlier step"
                )
    policy_assertions = value.get("policy_assertions", [])
    if not isinstance(policy_assertions, list):
        raise TranscriptError(f"{source}: policy_assertions must be an array")
    owned_matrix_steps: set[str] = set()
    for index, assertion in enumerate(policy_assertions):
        where = f"{source}: policy_assertions[{index}]"
        if not isinstance(assertion, dict) or set(assertion) != {"observer_kind", "policy_id", "steps", "trigger_step"}:
            raise TranscriptError(f"{where} must contain exactly observer_kind, policy_id, trigger_step and steps")
        policy_id = assertion["policy_id"]
        trigger_step = assertion["trigger_step"]
        asserted_steps = assertion["steps"]
        observer_kind = assertion["observer_kind"]
        if observer_kind not in {"none", "recipient-poll", "session-readback"}:
            raise TranscriptError(f"{where}.observer_kind is invalid")
        if not isinstance(policy_id, str) or not _ID.fullmatch(policy_id):
            raise TranscriptError(f"{where}.policy_id must be safe")
        if not isinstance(trigger_step, str) or trigger_step not in positions:
            raise TranscriptError(f"{where}.trigger_step must reference a transcript step")
        if not isinstance(asserted_steps, list) or not asserted_steps or not all(
            isinstance(step_id, str) and step_id in positions for step_id in asserted_steps
        ):
            raise TranscriptError(f"{where}.steps must reference transcript steps")
        if len(asserted_steps) != len(set(asserted_steps)) or trigger_step not in asserted_steps:
            raise TranscriptError(f"{where}.steps must be unique and include trigger_step")
        if (len(asserted_steps) == 1) != (observer_kind == "none"):
            raise TranscriptError(f"{where}.observer_kind must describe whether later matrix observers exist")
        for step_id in asserted_steps:
            if positions[step_id] < positions[trigger_step]:
                raise TranscriptError(f"{where}.steps cannot precede trigger_step")
            matrix = steps[positions[step_id]].get("policy_matrix")
            if not isinstance(matrix, dict) or matrix.get("id") != policy_id:
                raise TranscriptError(f"{where}.steps must carry the same declared policy matrix")
            if step_id in owned_matrix_steps:
                raise TranscriptError(f"{where}.steps reuses matrix step {step_id!r}")
            owned_matrix_steps.add(step_id)
    matrix_steps = {step["id"] for step in steps if "policy_matrix" in step}
    if owned_matrix_steps != matrix_steps:
        missing = sorted(matrix_steps - owned_matrix_steps)
        raise TranscriptError(f"{source}: policy matrix steps need causal policy_assertions: {missing}")

    coverage = value.get("coverage", {})
    if not isinstance(coverage, dict):
        raise TranscriptError(f"{source}: coverage must be an object")
    _reject_unknown(coverage, {"client_packets", "routes"}, where=f"{source}: coverage")
    for key in ("client_packets", "routes"):
        if key in coverage and not isinstance(coverage[key], list):
            raise TranscriptError(f"{source}: coverage.{key} must be an array")
    packet_claims = coverage.get("client_packets", [])
    if not all(type(packet_id) is int and 0 <= packet_id <= 65535 for packet_id in packet_claims):
        raise TranscriptError(f"{source}: coverage.client_packets must contain u16 integers")
    if len(packet_claims) != len(set(packet_claims)):
        raise TranscriptError(f"{source}: coverage.client_packets contains duplicates")
    if packet_claims and category not in {"malformed-input", "policy-matrix", "stable-packets"}:
        raise TranscriptError(f"{source}: packet coverage requires an explicit packet category")
    route_claims = coverage.get("routes", [])
    if not all(
        isinstance(route, str) and re.fullmatch(r"(?:ANY|GET|POST) /web/[A-Za-z0-9._~!$&()*+,;=:@%/-]+\.php", route)
        for route in route_claims
    ):
        raise TranscriptError(f"{source}: coverage.routes contains an invalid method/path")
    if len(route_claims) != len(set(route_claims)):
        raise TranscriptError(f"{source}: coverage.routes contains duplicates")
    assertion_groups = value.get("behavior_assertions", [])
    if not isinstance(assertion_groups, list):
        raise TranscriptError(f"{source}: behavior_assertions must be an array")
    step_ids = {step["id"] for step in steps}
    for index, assertion in enumerate(assertion_groups):
        where = f"{source}: behavior_assertions[{index}]"
        if not isinstance(assertion, dict):
            raise TranscriptError(f"{where} must be an object")
        _reject_unknown(
            assertion,
            {"client_packets", "kind", "policy_id", "request_steps", "steps"},
            where=where,
        )
        if assertion.get("kind") not in {
            "immediate-response",
            "policy-matrix",
            "recipient-poll",
            "state-readback",
        }:
            raise TranscriptError(f"{where}.kind is invalid")
        packets = assertion.get("client_packets")
        observers = assertion.get("steps")
        request_steps = assertion.get("request_steps")
        if not isinstance(packets, list) or not packets or not all(
            type(packet_id) is int and packet_id in packet_claims for packet_id in packets
        ):
            raise TranscriptError(f"{where}.client_packets must reference claimed packets")
        if len(packets) != len(set(packets)):
            raise TranscriptError(f"{where}.client_packets contains duplicates")
        if not isinstance(observers, list) or not observers or not all(
            isinstance(step_id, str) and step_id in step_ids for step_id in observers
        ):
            raise TranscriptError(f"{where}.steps must reference transcript steps")
        if len(observers) != len(set(observers)):
            raise TranscriptError(f"{where}.steps contains duplicates")
        if not isinstance(request_steps, list) or not request_steps or not all(
            isinstance(step_id, str) and step_id in step_ids for step_id in request_steps
        ):
            raise TranscriptError(f"{where}.request_steps must reference packet-sending steps")
        if len(request_steps) != len(set(request_steps)):
            raise TranscriptError(f"{where}.request_steps contains duplicates")
        policy_id = assertion.get("policy_id")
        if assertion["kind"] == "policy-matrix":
            if not isinstance(policy_id, str) or not _ID.fullmatch(policy_id):
                raise TranscriptError(f"{where}.policy_id must identify the declared policy")
        elif policy_id is not None:
            raise TranscriptError(f"{where}.policy_id is only valid for policy-matrix assertions")
    bound_tokens = {binding["token"] for binding in session_bindings}
    capture_names = [
        capture["as"]
        for step in steps
        for capture in step.get("capture", [])
    ]
    if len(capture_names) != len(set(capture_names)):
        raise TranscriptError(f"{source}: capture names must be unique")
    protected_binding_paths = {
        path
        for binding in session_bindings
        for path in (binding["token"], binding["user_id"])
    }
    collisions = sorted(set(capture_names) & (set(requires) | protected_binding_paths))
    if collisions:
        raise TranscriptError(f"{source}: captures cannot shadow fixture or session paths: {collisions}")
    captured_tokens = {
        capture["as"]
        for step in steps
        for capture in step.get("capture", [])
        if capture.get("from") == "header" and capture.get("name", "").lower() == "cho-token"
    }
    available_captures: set[str] = set()
    for step in steps:
        early = sorted((_placeholder_names(step["request"]) & set(capture_names)) - available_captures)
        if early:
            raise TranscriptError(f"{source}: step {step['id']!r} uses captures before creation: {early}")
        headers = step["request"].get("headers", {})
        request_body = step["request"].get("body")
        is_packet_poll = (
            step["request"]["method"] == "POST"
            and step["request"]["path"].split("?", 1)[0] == "/"
            and isinstance(request_body, dict)
            and request_body.get("encoding") == "packet_stream"
        )
        has_osu_token = any(name.lower() == "osu-token" for name in headers)
        if is_packet_poll and not has_osu_token:
            raise TranscriptError(f"{source}: step {step['id']!r} packet poll requires a bound osu-token")
        protected_headers = {"osu-token"}
        if step["request"]["path"].split("?", 1)[0] == "/web/osu-submit-modular-selector.php":
            protected_headers.add("token")
        for header_name in protected_headers:
            token_value = next(
                (header_value for name, header_value in headers.items() if name.lower() == header_name),
                None,
            )
            if token_value is None:
                continue
            match = _PLACEHOLDER.fullmatch(token_value) if isinstance(token_value, str) else None
            if match is None or match.group(1) not in bound_tokens | captured_tokens:
                raise TranscriptError(
                    f"{source}: step {step['id']!r} must use a captured token or declared session binding"
                )
        available_captures.update(capture["as"] for capture in step.get("capture", []))
    _validate_rules(value.get("normalizers", []), where=f"{source}: normalizers")


def _validate_body(body: Any, *, where: str, allow_packet_stream: bool = True) -> None:
    if body is None:
        return
    if not isinstance(body, dict):
        raise TranscriptError(f"{where} must be an object")
    encoding = body.get("encoding")
    if encoding not in _ENCODINGS:
        raise TranscriptError(f"{where}.encoding must be one of {sorted(_ENCODINGS)}")
    _reject_unknown(body, _BODY_KEYS[encoding], where=where)
    if encoding == "packet_stream":
        if not allow_packet_stream:
            raise TranscriptError(f"{where}: packet_stream cannot be nested")
        packets = body.get("packets")
        if not isinstance(packets, list):
            raise TranscriptError(f"{where}.packets must be an array")
        for index, packet in enumerate(packets):
            packet_where = f"{where}.packets[{index}]"
            if not isinstance(packet, dict) or type(packet.get("id")) is not int:
                raise TranscriptError(f"{packet_where}.id must be an integer")
            _reject_unknown(packet, {"compression", "id", "payload"}, where=packet_where)
            packet_id = packet["id"]
            if packet_id < 0 or packet_id > 65535:
                raise TranscriptError(f"{packet_where}.id must fit u16")
            compression = packet.get("compression", 0)
            if not isinstance(compression, int) or compression < 0 or compression > 255:
                raise TranscriptError(f"{packet_where}.compression must fit u8")
            _validate_body(packet.get("payload"), where=f"{packet_where}.payload", allow_packet_stream=False)
    elif encoding == "concat":
        parts = body.get("parts")
        if not isinstance(parts, list):
            raise TranscriptError(f"{where}.parts must be an array")
        for index, part in enumerate(parts):
            _validate_body(part, where=f"{where}.parts[{index}]", allow_packet_stream=False)
    elif encoding == "integer" and body.get("format") not in _INTEGER_FORMATS:
        raise TranscriptError(f"{where}.format must be one of {sorted(_INTEGER_FORMATS)}")
    elif encoding == "integer":
        value = body.get("value")
        if type(value) is not int and not (isinstance(value, str) and _PLACEHOLDER.fullmatch(value)):
            raise TranscriptError(f"{where}.value must be an integer or exact placeholder")
    elif encoding in {"hex", "base64"}:
        value = body.get("value", "")
        if not isinstance(value, str):
            raise TranscriptError(f"{where}.value must be a string")
        if not _PLACEHOLDER.search(value):
            try:
                bytes.fromhex(value) if encoding == "hex" else base64.b64decode(value, validate=True)
            except (TypeError, ValueError) as exc:
                raise TranscriptError(f"{where}.value is invalid {encoding}") from exc


def _placeholder_names(value: Any) -> set[str]:
    if isinstance(value, str):
        return set(_PLACEHOLDER.findall(value))
    if isinstance(value, dict):
        return {name for child in value.values() for name in _placeholder_names(child)}
    if isinstance(value, list):
        return {name for child in value for name in _placeholder_names(child)}
    return set()


def _exact_header_placeholder(request: Mapping[str, Any], wanted: str) -> str | None:
    headers = request.get("headers", {})
    if not isinstance(headers, Mapping):
        return None
    value = next(
        (header for name, header in headers.items() if isinstance(name, str) and name.lower() == wanted),
        None,
    )
    if not isinstance(value, str):
        return None
    match = _PLACEHOLDER.fullmatch(value)
    return match.group(1) if match is not None else None


def _validate_rules(rules: Any, *, where: str) -> None:
    if not isinstance(rules, list):
        raise TranscriptError(f"{where} must be an array")
    valid = {"ignore", "screenshot_filename", "variable"}
    for index, rule in enumerate(rules):
        item = f"{where}[{index}]"
        if not isinstance(rule, dict):
            raise TranscriptError(f"{item} must be an object")
        if rule.get("kind") not in valid:
            raise TranscriptError(f"{item}.kind must be one of {sorted(valid)}")
        allowed_keys = {"kind", "path", "variable"} if rule["kind"] == "variable" else {"kind", "path"}
        _reject_unknown(rule, allowed_keys, where=item)
        if not isinstance(rule.get("path"), str) or not rule["path"]:
            raise TranscriptError(f"{item}.path must be a non-empty string")
        parts = rule["path"].split(".")
        leaf = parts[-1]
        if leaf in _PROTECTED_SEMANTIC_LEAVES:
            raise TranscriptError(f"{item}.path targets protected gameplay semantics")
        if rule["kind"] == "ignore" and (len(parts) < 2 or leaf not in _IGNORABLE_LEAVES):
            raise TranscriptError(f"{item}.path must end at an allowlisted nondeterministic leaf")
        if rule["kind"] == "variable" and (len(parts) < 2 or leaf not in _VARIABLE_LEAVES):
            raise TranscriptError(f"{item}.path must end at an allowlisted identity field")
        if rule["kind"] == "screenshot_filename" and rule["path"] != "body":
            raise TranscriptError(f"{item}.path must be the exact text body")
        if rule["kind"] == "variable" and not isinstance(rule.get("variable"), str):
            raise TranscriptError(f"{item}.variable must be a string")


def _reject_unknown(value: Mapping[str, Any], allowed: set[str], *, where: str) -> None:
    unknown = set(value) - allowed
    if unknown:
        raise TranscriptError(f"{where} has unsupported key {sorted(unknown)[0]!r}")


def _validate_session_bindings(bindings: Any, *, requires: list[str], where: str) -> None:
    if not isinstance(bindings, list):
        raise TranscriptError(f"{where} must be an array")
    seen: set[tuple[str, str]] = set()
    for index, binding in enumerate(bindings):
        item = f"{where}[{index}]"
        if not isinstance(binding, dict) or set(binding) != {"token", "user_id"}:
            raise TranscriptError(f"{item} must contain exactly token and user_id")
        token = binding["token"]
        user_id = binding["user_id"]
        if not all(
            isinstance(path, str) and all(_ID.fullmatch(part) for part in path.split("."))
            for path in (token, user_id)
        ):
            raise TranscriptError(f"{item} must contain safe variable paths")
        if token not in requires or user_id not in requires:
            raise TranscriptError(f"{item} variables must also appear in requires")
        pair = (token, user_id)
        if pair in seen:
            raise TranscriptError(f"{item} duplicates an earlier binding")
        seen.add(pair)


def _validate_captures(captures: Any, *, where: str) -> None:
    if not isinstance(captures, list):
        raise TranscriptError(f"{where} must be an array")
    for index, capture in enumerate(captures):
        item = f"{where}[{index}]"
        if not isinstance(capture, dict):
            raise TranscriptError(f"{item} must be an object")
        unknown_keys = set(capture) - {"as", "from", "name", "path", "prefix", "secret", "type"}
        if unknown_keys:
            raise TranscriptError(f"{item} has unsupported key {sorted(unknown_keys)[0]!r}")
        if capture.get("from") not in {"header", "path", "text_prefix"}:
            raise TranscriptError(f"{item}.from must be header, path or text_prefix")
        if not isinstance(capture.get("as"), str) or not _ID.fullmatch(capture["as"]):
            raise TranscriptError(f"{item}.as must be a safe variable name")
        source_key = {"header": "name", "path": "path", "text_prefix": "prefix"}[capture["from"]]
        if not isinstance(capture.get(source_key), str) or not capture[source_key]:
            raise TranscriptError(f"{item}.{source_key} must be a non-empty string")
        capture_type = capture.get("type", "string")
        if capture_type not in {"int", "string"}:
            raise TranscriptError(f"{item}.type must be int or string")
        if "secret" in capture and type(capture["secret"]) is not bool:
            raise TranscriptError(f"{item}.secret must be a boolean")


def _validate_policy_matrix(matrix: Any, *, category: Any, where: str) -> None:
    if matrix is None:
        return
    if not isinstance(matrix, dict):
        raise TranscriptError(f"{where} must be an object")
    unknown_matrix_keys = set(matrix) - {
        "compare_after_removing",
        "compare_packet_ids",
        "compare_target_with_step",
        "compare_target_with_step_target",
        "id",
        "source_attestation",
        "targets",
    }
    if unknown_matrix_keys:
        raise TranscriptError(f"{where} has unsupported key {sorted(unknown_matrix_keys)[0]!r}")
    if not isinstance(matrix.get("id"), str) or not _ID.fullmatch(matrix["id"]):
        raise TranscriptError(f"{where}.id must be safe")
    removals = matrix.get("compare_after_removing")
    if removals is not None:
        if not isinstance(removals, dict) or set(removals) != {"zigcho", "reference"}:
            raise TranscriptError(f"{where}.compare_after_removing must contain zigcho and reference")
        for target, packet_ids in removals.items():
            if not isinstance(packet_ids, list) or not all(type(packet_id) is int for packet_id in packet_ids):
                raise TranscriptError(f"{where}.compare_after_removing.{target} must be an integer array")
            if len(packet_ids) != len(set(packet_ids)):
                raise TranscriptError(f"{where}.compare_after_removing.{target} contains duplicates")
    compare_packet_ids = matrix.get("compare_packet_ids")
    if compare_packet_ids is not None:
        if not isinstance(compare_packet_ids, list) or not compare_packet_ids:
            raise TranscriptError(f"{where}.compare_packet_ids must be a non-empty integer array")
        if not all(type(packet_id) is int for packet_id in compare_packet_ids):
            raise TranscriptError(f"{where}.compare_packet_ids must be a non-empty integer array")
        if len(compare_packet_ids) != len(set(compare_packet_ids)):
            raise TranscriptError(f"{where}.compare_packet_ids contains duplicates")
    baseline_comparisons = matrix.get("compare_target_with_step", {})
    if not isinstance(baseline_comparisons, dict) or not set(baseline_comparisons).issubset({"zigcho", "reference"}):
        raise TranscriptError(f"{where}.compare_target_with_step must map named targets to earlier step ids")
    if not all(isinstance(step_id, str) and _ID.fullmatch(step_id) for step_id in baseline_comparisons.values()):
        raise TranscriptError(f"{where}.compare_target_with_step must contain safe step ids")
    cross_target_comparisons = matrix.get("compare_target_with_step_target", {})
    if not isinstance(cross_target_comparisons, dict) or not set(cross_target_comparisons).issubset(
        {"zigcho", "reference"}
    ):
        raise TranscriptError(
            f"{where}.compare_target_with_step_target must map named targets to prior target/step objects"
        )
    for target, comparison in cross_target_comparisons.items():
        if not isinstance(comparison, dict) or set(comparison) != {"step", "target"}:
            raise TranscriptError(
                f"{where}.compare_target_with_step_target.{target} must contain exactly step and target"
            )
        if comparison["target"] not in {"zigcho", "reference"}:
            raise TranscriptError(
                f"{where}.compare_target_with_step_target.{target}.target must name a target"
            )
        if not isinstance(comparison["step"], str) or not _ID.fullmatch(comparison["step"]):
            raise TranscriptError(
                f"{where}.compare_target_with_step_target.{target}.step must be a safe step id"
            )
    targets = matrix.get("targets")
    if not isinstance(targets, dict) or set(targets) != {"zigcho", "reference"}:
        raise TranscriptError(f"{where}.targets must contain exactly zigcho and reference")
    for target, expected in targets.items():
        target_where = f"{where}.targets.{target}"
        if not isinstance(expected, dict):
            raise TranscriptError(f"{target_where} must be an object")
        statuses = expected.get("status")
        status_values = statuses if isinstance(statuses, list) else [statuses]
        if not status_values or not all(type(status) is int and 100 <= status <= 599 for status in status_values):
            raise TranscriptError(f"{target_where}.status must contain HTTP statuses")
        unknown_target_keys = set(expected) - {
            "allowed_packet_ids",
            "allow_duplicate_packet_ids",
            "body_policy",
            "fields",
            "forbidden_packet_ids",
            "packet_field_counts",
            "packet_fields",
            "packet_ids",
            "required_packet_ids",
            "status",
        }
        if unknown_target_keys:
            raise TranscriptError(f"{target_where} has unsupported key {sorted(unknown_target_keys)[0]!r}")
        packet_ids = expected.get("packet_ids")
        required_ids = expected.get("required_packet_ids")
        body_policy = expected.get("body_policy")
        if packet_ids is None and required_ids is None:
            if body_policy != "uncompared":
                raise TranscriptError(
                    f"{target_where} must declare a packet contract or explicit uncompared body policy"
                )
        elif body_policy is not None:
            raise TranscriptError(f"{target_where}.body_policy cannot weaken a packet contract")
        for key in ("allowed_packet_ids", "allow_duplicate_packet_ids", "packet_ids", "required_packet_ids", "forbidden_packet_ids"):
            values = expected.get(key, [])
            if not isinstance(values, list) or not all(type(packet_id) is int for packet_id in values):
                raise TranscriptError(f"{target_where}.{key} must be an integer array")
            if key != "packet_ids" and len(values) != len(set(values)):
                raise TranscriptError(f"{target_where}.{key} contains duplicates")
        allowed_ids = expected.get("allowed_packet_ids")
        if required_ids is not None and allowed_ids is None:
            raise TranscriptError(
                f"{target_where}.allowed_packet_ids is required when using required_packet_ids"
            )
        if allowed_ids is not None and not set(required_ids or []).issubset(allowed_ids):
            raise TranscriptError(f"{target_where}.allowed_packet_ids must include every required packet")
        duplicate_ids = expected.get("allow_duplicate_packet_ids", [])
        if not set(duplicate_ids).issubset(set(allowed_ids or expected.get("packet_ids", []))):
            raise TranscriptError(f"{target_where}.allow_duplicate_packet_ids must be allowed by the packet contract")
        fields = expected.get("fields", [])
        if not isinstance(fields, list):
            raise TranscriptError(f"{target_where}.fields must be an array")
        for index, field in enumerate(fields):
            if not isinstance(field, dict) or not isinstance(field.get("path"), str) or not field["path"]:
                raise TranscriptError(f"{target_where}.fields[{index}].path must be a string")
            if not isinstance(field.get("variable"), str) or not field["variable"]:
                raise TranscriptError(f"{target_where}.fields[{index}].variable must be a string")
        packet_field_counts = expected.get("packet_field_counts", [])
        _validate_packet_field_counts(
            packet_field_counts,
            where=f"{target_where}.packet_field_counts",
        )
        possible_target_ids = set(packet_ids or allowed_ids or [])
        if any(field["packet_id"] not in possible_target_ids for field in packet_field_counts):
            raise TranscriptError(
                f"{target_where}.packet_field_counts may inspect only packets allowed by its target contract"
            )
        _validate_packet_fields(expected.get("packet_fields", []), where=f"{target_where}.packet_fields")
    uncompared_targets = {
        target
        for target, expected in targets.items()
        if expected.get("body_policy") == "uncompared"
    }
    source_attestation = matrix.get("source_attestation")
    if uncompared_targets and category != "malformed-input":
        if uncompared_targets != {"reference"}:
            raise TranscriptError(
                f"{where} may waive only the nondeterministic pinned reference body"
            )
        if source_attestation not in _SOURCE_ATTESTATIONS:
            raise TranscriptError(
                f"{where}.source_attestation must name the narrow checked source contract for an uncompared body"
            )
        comparison_keys = {
            "compare_after_removing",
            "compare_packet_ids",
            "compare_target_with_step",
            "compare_target_with_step_target",
        }
        if comparison_keys & set(matrix):
            raise TranscriptError(
                f"{where} cannot compare a target whose body is explicitly uncompared"
            )
    elif source_attestation is not None:
        raise TranscriptError(f"{where}.source_attestation requires an explicitly uncompared target body")
    possible_ids = {
        target: set(expected.get("packet_ids", expected.get("allowed_packet_ids", [])))
        for target, expected in targets.items()
    }
    if compare_packet_ids is not None:
        selected = set(compare_packet_ids)
        common = possible_ids["zigcho"] & possible_ids["reference"]
        if not selected.issubset(common):
            raise TranscriptError(f"{where}.compare_packet_ids may select only packet ids allowed by both targets")
        if removals is not None and selected & (set(removals["zigcho"]) | set(removals["reference"])):
            raise TranscriptError(f"{where}.compare_packet_ids must be disjoint from packet removals")
    if removals is not None:
        for target, other in (("zigcho", "reference"), ("reference", "zigcho")):
            removed = set(removals[target])
            if not removed.issubset(possible_ids[target]):
                raise TranscriptError(f"{where}.compare_after_removing.{target} removes packets outside its target contract")
            if removed & possible_ids[other]:
                raise TranscriptError(f"{where}.compare_after_removing.{target} may remove only target-exclusive packet ids")


def _validate_packet_fields(fields: Any, *, where: str) -> None:
    if not isinstance(fields, list):
        raise TranscriptError(f"{where} must be an array")
    for index, field in enumerate(fields):
        field_where = f"{where}[{index}]"
        if not isinstance(field, dict) or type(field.get("packet_id")) is not int:
            raise TranscriptError(f"{field_where}.packet_id must be an integer")
        if not isinstance(field.get("path"), str) or not field["path"]:
            raise TranscriptError(f"{field_where}.path must be a string")
        if "occurrence" in field and (type(field["occurrence"]) is not int or field["occurrence"] < 0):
            raise TranscriptError(f"{field_where}.occurrence must be a non-negative integer")
        selectors = {key for key in ("value", "variable", "predicate") if key in field}
        if len(selectors) != 1 or ("predicate" in field and field["predicate"] not in {"negative", "positive"}):
            raise TranscriptError(f"{field_where} must have one valid value, variable or predicate")


def _validate_packet_field_counts(fields: Any, *, where: str) -> None:
    if not isinstance(fields, list):
        raise TranscriptError(f"{where} must be an array")
    for index, field in enumerate(fields):
        field_where = f"{where}[{index}]"
        if not isinstance(field, dict) or set(field) - {"count", "packet_id", "path", "value", "variable"}:
            raise TranscriptError(f"{field_where} has unsupported fields")
        if type(field.get("packet_id")) is not int:
            raise TranscriptError(f"{field_where}.packet_id must be an integer")
        if not isinstance(field.get("path"), str) or not field["path"]:
            raise TranscriptError(f"{field_where}.path must be a string")
        if type(field.get("count")) is not int or field["count"] < 1:
            raise TranscriptError(f"{field_where}.count must be a positive integer")
        selectors = {key for key in ("value", "variable") if key in field}
        if len(selectors) != 1:
            raise TranscriptError(f"{field_where} must have exactly one value or variable selector")
        if "variable" in field and (
            not isinstance(field["variable"], str)
            or not all(_ID.fullmatch(part) for part in field["variable"].split("."))
        ):
            raise TranscriptError(f"{field_where}.variable must be a safe variable path")


def render_value(value: Any, variables: Mapping[str, Any]) -> Any:
    """Render placeholders without evaluating code or accessing the environment."""

    if isinstance(value, str):
        match = _PLACEHOLDER.fullmatch(value)
        if match:
            return _lookup_variable(match.group(1), variables)

        def replace(item: re.Match[str]) -> str:
            return str(_lookup_variable(item.group(1), variables))

        return _PLACEHOLDER.sub(replace, value)
    if isinstance(value, list):
        return [render_value(item, variables) for item in value]
    if isinstance(value, dict):
        return {key: render_value(item, variables) for key, item in value.items()}
    return value


def _lookup_variable(name: str, variables: Mapping[str, Any]) -> Any:
    current: Any = variables
    for part in name.split("."):
        if not isinstance(current, Mapping) or part not in current:
            raise TranscriptError(f"missing transcript variable {name!r}")
        current = current[part]
    return current


def encode_body(spec: Any, variables: Mapping[str, Any]) -> bytes | None:
    if spec is None:
        return None
    rendered = render_value(spec, variables)
    encoding = rendered["encoding"]
    if encoding == "utf8":
        value = rendered.get("value", "")
        if not isinstance(value, str):
            raise TranscriptError("utf8 body value must be a string")
        return value.encode("utf-8")
    if encoding == "hex":
        try:
            return bytes.fromhex(rendered.get("value", ""))
        except (TypeError, ValueError) as exc:
            raise TranscriptError(f"invalid hexadecimal body: {exc}") from exc
    if encoding == "base64":
        try:
            return base64.b64decode(rendered.get("value", ""), validate=True)
        except (TypeError, ValueError) as exc:
            raise TranscriptError(f"invalid base64 body: {exc}") from exc
    if encoding == "json":
        return json.dumps(
            rendered.get("value"),
            ensure_ascii=False,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    if encoding == "form":
        fields = rendered.get("fields", {})
        if not isinstance(fields, (dict, list)):
            raise TranscriptError("form fields must be an object or an array of pairs")
        return urllib.parse.urlencode(fields, doseq=True).encode("ascii")
    if encoding == "osu_string":
        value = rendered.get("value", "")
        if not isinstance(value, str):
            raise TranscriptError("osu_string body value must be a string")
        raw = value.encode("utf-8")
        return b"\x00" if not raw else b"\x0b" + _uleb128(len(raw)) + raw
    if encoding == "integer":
        value = rendered.get("value")
        if not isinstance(value, int):
            raise TranscriptError("integer body value must be an integer")
        try:
            return struct.pack(_INTEGER_FORMATS[rendered["format"]], value)
        except struct.error as exc:
            raise TranscriptError(f"integer body value is out of range: {exc}") from exc
    if encoding == "concat":
        return b"".join(encode_body(part, variables) or b"" for part in rendered["parts"])
    if encoding == "packet_stream":
        output = bytearray()
        for packet in rendered["packets"]:
            payload = encode_body(packet.get("payload"), variables) or b""
            output.extend(struct.pack("<HBI", packet["id"], packet.get("compression", 0), len(payload)))
            output.extend(payload)
        return bytes(output)
    raise TranscriptError(f"unsupported body encoding {encoding!r}")


def encode_query(query: Any, variables: Mapping[str, Any]) -> str:
    if query is None:
        return ""
    rendered = render_value(query, variables)
    if not isinstance(rendered, (dict, list)):
        raise TranscriptError("query must be an object or an array of pairs")
    return urllib.parse.urlencode(rendered, doseq=True)


def _uleb128(value: int) -> bytes:
    if value < 0:
        raise TranscriptError("ULEB128 values cannot be negative")
    output = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            output.append(byte | 0x80)
        else:
            output.append(byte)
            return bytes(output)
