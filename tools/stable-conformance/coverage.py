"""Cross-check transcript claims against encoded requests and the source manifest."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any, Iterable, Mapping

from strict_json import load_path


_STATE_READBACK_ROUTES = {
    73: {"GET /web/osu-getfriends.php"},
    74: {"GET /web/osu-getfriends.php"},
}


def check_transcript_coverage(
    transcripts: Iterable[Mapping[str, Any]],
    manifest_path: str | Path,
    reference_path: str | Path | None = None,
) -> dict[str, Any]:
    checked_manifest = Path(manifest_path)
    manifest = load_path(checked_manifest)
    checked_reference = Path(reference_path) if reference_path is not None else checked_manifest.with_name("reference.json")
    declared_policies: set[str] = set()
    declared_policy_packets: dict[str, set[int]] = {}
    declared_policy_attestations: dict[str, str | None] = {}
    if checked_reference.is_file():
        reference = load_path(checked_reference)
        policy_items = reference.get("declared_policy_differences", [])
        if not isinstance(policy_items, list):
            raise ValueError("reference declared_policy_differences must be an array")
        policy_ids = [item.get("id") for item in policy_items if isinstance(item, Mapping)]
        if len(policy_ids) != len(policy_items) or len(policy_ids) != len(set(policy_ids)):
            raise ValueError("reference policy ids must be unique objects")
        for item in policy_items:
            unknown_policy_keys = set(item) - {
                "id",
                "packet_ids",
                "reason",
                "reference",
                "scope",
                "source_attestation",
                "zigcho",
            }
            if unknown_policy_keys:
                raise ValueError(f"reference policy has unknown key {sorted(unknown_policy_keys)[0]!r}")
            if (
                not isinstance(item.get("id"), str)
                or re.fullmatch(r"[a-z0-9][a-z0-9._-]*", item["id"]) is None
                or not isinstance(item.get("packet_ids"), list)
                or not all(type(packet_id) is int and 0 <= packet_id <= 65535 for packet_id in item["packet_ids"])
                or len(item["packet_ids"]) != len(set(item["packet_ids"]))
            ):
                raise ValueError("reference policy ids and packet scopes must be explicit and valid")
            declared_policy_packets[item["id"]] = set(item.get("packet_ids", []))
            source_attestation = item.get("source_attestation")
            if source_attestation is not None and (
                not isinstance(source_attestation, str)
                or re.fullmatch(r"[a-z0-9][a-z0-9._-]*", source_attestation) is None
            ):
                raise ValueError("reference policy source attestations must be safe ids")
            declared_policy_attestations[item["id"]] = source_attestation
        declared_policies = set(declared_policy_packets)
    expected_packets = {
        packet["id"]
        for packet in manifest["packets"]
        if packet["classification"] == "handled"
    }
    expected_routes = {
        f"{method} {route['path']}"
        for route in manifest["routes"]
        for method in route["methods"]
    }
    route_methods = {route["path"]: set(route["methods"]) for route in manifest["routes"]}
    scenario_items = manifest.get("required_scenarios", [])
    if not isinstance(scenario_items, list) or not all(isinstance(scenario, Mapping) for scenario in scenario_items):
        raise ValueError("manifest required_scenarios must be an object array")
    scenario_ids = [scenario.get("id") for scenario in scenario_items]
    if not all(
        isinstance(scenario.get("id"), str)
        and isinstance(scenario.get("category"), str)
        and type(scenario.get("minimum_steps")) is int
        and isinstance(scenario.get("contract_sha256"), str)
        and len(scenario["contract_sha256"]) == 64
        and set(scenario["contract_sha256"]) <= set("0123456789abcdef")
        and isinstance(scenario.get("required_steps"), list)
        and all(isinstance(step_id, str) for step_id in scenario["required_steps"])
        for scenario in scenario_items
    ):
        raise ValueError("manifest required scenarios have an invalid contract shape")
    if len(scenario_ids) != len(set(scenario_ids)):
        raise ValueError("manifest required scenario ids must be unique")
    required_scenarios = {scenario["id"]: scenario for scenario in scenario_items}
    observed_scenarios: dict[str, tuple[Any, int, set[str], Mapping[str, Any]]] = {}
    observed_scenario_ids: list[str] = []
    declared_packets: set[int] = set()
    observed_packets: set[int] = set()
    asserted_packets: set[int] = set()
    valid_declared_packets: set[int] = set()
    valid_observed_packets: set[int] = set()
    valid_asserted_packets: set[int] = set()
    sent_occurrence_count = 0
    asserted_occurrence_count = 0
    malformed_sent_occurrence_count = 0
    malformed_asserted_occurrence_count = 0
    declared_routes: set[str] = set()
    observed_routes: set[str] = set()
    errors: list[dict[str, Any]] = []
    exercised_policies: set[str] = set()
    asserted_policy_packets: dict[str, set[int]] = {}

    for transcript in transcripts:
        case_id = transcript["id"]
        observed_scenario_ids.append(case_id)
        if case_id in observed_scenarios:
            errors.append(_error("duplicate_scenario_id", "transcripts", case_id))
        else:
            observed_scenarios[case_id] = (
                transcript.get("category"),
                len(transcript.get("steps", [])),
                {step["id"] for step in transcript.get("steps", [])},
                transcript,
            )
        coverage = transcript.get("coverage", {})
        case_packets = set(coverage.get("client_packets", []))
        case_routes = set(coverage.get("routes", []))
        actual_packets: set[int] = set()
        actual_occurrences: set[tuple[str, int]] = set()
        actual_routes: set[str] = set()
        step_by_id = {step["id"]: step for step in transcript["steps"]}
        step_index = {step["id"]: index for index, step in enumerate(transcript["steps"])}
        bound_roles = {
            binding["token"]: binding["user_id"]
            for binding in transcript.get("session_bindings", [])
        }
        case_policies = {
            step["policy_matrix"]["id"]
            for step in transcript["steps"]
            if "policy_matrix" in step
        }
        for policy_id in sorted(case_policies - declared_policies):
            errors.append(_error("unknown_policy_matrix", case_id, policy_id))
        exercised_policies.update(case_policies)
        for step_index_value, step in enumerate(transcript["steps"]):
            matrix = step.get("policy_matrix")
            if not isinstance(matrix, Mapping):
                continue
            policy_id = matrix["id"]
            expected_attestation = declared_policy_attestations.get(policy_id)
            actual_attestation = matrix.get("source_attestation")
            if actual_attestation != expected_attestation:
                errors.append(
                    _error(
                        "policy_source_attestation_mismatch",
                        case_id,
                        f"{step['id']}:expected={expected_attestation}:actual={actual_attestation}",
                    )
                )
            is_source_attested_waiver = isinstance(actual_attestation, str)
            if is_source_attested_waiver and step_index_value != len(transcript["steps"]) - 1:
                errors.append(_error("source_attested_policy_not_terminal_step", case_id, step["id"]))
            if is_source_attested_waiver and scenario_items and case_id != scenario_items[-1].get("id"):
                errors.append(_error("source_attested_policy_not_terminal_scenario", case_id, step["id"]))
        owned_matrix_steps: set[str] = set()
        for policy_assertion in transcript.get("policy_assertions", []):
            policy_id = policy_assertion["policy_id"]
            trigger_step = policy_assertion["trigger_step"]
            asserted_steps = policy_assertion["steps"]
            observer_kind = policy_assertion["observer_kind"]
            if policy_id not in declared_policies:
                errors.append(_error("unknown_policy_assertion", case_id, policy_id))
            trigger_packets = _packet_ids(step_by_id[trigger_step]["request"].get("body"))
            asserted_policy_packets.setdefault(policy_id, set()).update(trigger_packets)
            actor_token = _session_token_path(step_by_id[trigger_step]["request"])
            for step_id in asserted_steps:
                owned_matrix_steps.add(step_id)
                matrix_id = step_by_id[step_id].get("policy_matrix", {}).get("id")
                if matrix_id != policy_id:
                    errors.append(
                        _error(
                            "policy_assertion_matrix_mismatch",
                            case_id,
                            f"{step_id}:expected={policy_id}:actual={matrix_id}",
                        )
                    )
                if step_id != trigger_step:
                    observer_request = step_by_id[step_id]["request"]
                    valid_observer = (
                        _is_empty_poll(observer_request)
                        if observer_kind == "recipient-poll"
                        else _is_session_readback(observer_request)
                    )
                    if step_index[step_id] <= step_index[trigger_step] or not valid_observer:
                        errors.append(_error("policy_observer_shape_invalid", case_id, step_id))
                    if observer_kind == "recipient-poll" and not _roles_are_distinct(
                        actor_token,
                        _session_token_path(observer_request),
                        bound_roles,
                    ):
                        errors.append(_error("policy_observer_not_distinct", case_id, step_id))
        matrix_steps = {step["id"] for step in transcript["steps"] if "policy_matrix" in step}
        for step_id in sorted(matrix_steps - owned_matrix_steps):
            errors.append(_error("orphan_policy_matrix", case_id, step_id))
        for step_id in sorted(owned_matrix_steps - matrix_steps):
            errors.append(_error("policy_assertion_without_matrix", case_id, step_id))
        for step in transcript["steps"]:
            request = step["request"]
            step_packets = _packet_ids(request.get("body"))
            request_body = request.get("body")
            if (
                isinstance(request_body, Mapping)
                and request_body.get("encoding") == "packet_stream"
                and transcript.get("category") != "malformed-input"
                and step.get("response", {}).get("format") != "bancho_packets"
            ):
                errors.append(_error("packet_step_without_packet_response", case_id, step["id"]))
            if len(_packet_occurrences(request.get("body"))) > 1:
                errors.append(_error("multiple_client_packets_in_behavior_step", case_id, step["id"]))
            actual_packets.update(step_packets)
            actual_occurrences.update((step["id"], packet_id) for packet_id in step_packets)
            path = request["path"].split("?", 1)[0]
            covered_step = bool(step_packets) or path.startswith("/web/")
            comparison = step.get("response", {}).get("compare", {})
            if covered_step and comparison.get("body", True) is False:
                errors.append(_error("covered_response_body_not_compared", case_id, step["id"]))
            if covered_step and comparison.get("status", True) is False:
                errors.append(_error("covered_response_status_not_compared", case_id, step["id"]))
            if path.startswith("/web/"):
                methods = route_methods.get(path, set())
                canonical_method = "ANY" if "ANY" in methods else request["method"]
                actual_routes.add(f"{canonical_method} {path}")
        for packet_id in sorted(case_packets - actual_packets):
            errors.append(_error("unobserved_packet_claim", case_id, packet_id))
        for route in sorted(case_routes - actual_routes):
            errors.append(_error("unobserved_route_claim", case_id, route))
        undeclared_packets = actual_packets - case_packets
        for packet_id in sorted(undeclared_packets):
            errors.append(_error("undeclared_packet_request", case_id, packet_id))
        undeclared_routes = actual_routes - case_routes
        for route in sorted(undeclared_routes):
            errors.append(_error("undeclared_route_request", case_id, route))
        declared_packets.update(case_packets)
        observed_packets.update(actual_packets)
        if transcript.get("category") != "malformed-input":
            valid_declared_packets.update(case_packets)
            valid_observed_packets.update(actual_packets)
        case_asserted: set[int] = set()
        case_asserted_occurrences: set[tuple[str, int]] = set()
        for assertion in transcript.get("behavior_assertions", []):
            request_steps = assertion["request_steps"]
            observer_steps = assertion["steps"]
            if assertion["kind"] in {"immediate-response", "policy-matrix"}:
                if set(request_steps) != set(observer_steps):
                    errors.append(
                        _error(
                            "noncausal_immediate_observer",
                            case_id,
                            f"{assertion['kind']}:{','.join(request_steps)}->{','.join(observer_steps)}",
                        )
                    )
            else:
                for request_step in request_steps:
                    if not any(step_index[observer] > step_index[request_step] for observer in observer_steps):
                        errors.append(
                            _error(
                                "observer_not_after_request",
                                case_id,
                                f"{request_step}:{assertion['kind']}",
                            )
                        )
                    if assertion["kind"] == "recipient-poll":
                        actor_token = _session_token_path(step_by_id[request_step]["request"])
                        if not any(
                            step_index[observer] > step_index[request_step]
                            and _roles_are_distinct(
                                actor_token,
                                _session_token_path(step_by_id[observer]["request"]),
                                bound_roles,
                            )
                            for observer in observer_steps
                        ):
                            errors.append(
                                _error(
                                    "recipient_observer_not_distinct",
                                    case_id,
                                    request_step,
                                )
                            )
                for observer in observer_steps:
                    observer_request = step_by_id[observer]["request"]
                    if assertion["kind"] == "recipient-poll" and not _is_empty_poll(observer_request):
                        errors.append(_error("recipient_observer_is_not_empty_poll", case_id, observer))
                    if assertion["kind"] == "state-readback" and not _is_readback_request(observer_request):
                        errors.append(_error("state_observer_is_not_readback", case_id, observer))
                if assertion["kind"] == "state-readback":
                    for packet_id in assertion["client_packets"]:
                        allowed_routes = _STATE_READBACK_ROUTES.get(packet_id)
                        if allowed_routes is None:
                            errors.append(_error("packet_has_no_state_readback_contract", case_id, packet_id))
                            continue
                        for observer in observer_steps:
                            observer_request = step_by_id[observer]["request"]
                            route = f"{observer_request['method']} {observer_request['path'].split('?', 1)[0]}"
                            if route not in allowed_routes:
                                errors.append(
                                    _error(
                                        "state_readback_route_mismatch",
                                        case_id,
                                        f"{packet_id}:{observer}:{route}",
                                    )
                                )
            if assertion["kind"] == "policy-matrix":
                policy_id = assertion["policy_id"]
                for step_id in set(request_steps) | set(observer_steps):
                    actual_policy = step_by_id[step_id].get("policy_matrix", {}).get("id")
                    if actual_policy != policy_id:
                        errors.append(
                            _error(
                                "policy_observer_matrix_mismatch",
                                case_id,
                                f"{step_id}:expected={policy_id}:actual={actual_policy}",
                            )
                        )
            for step_id in assertion["steps"]:
                observer_step = step_by_id[step_id]
                response_spec = observer_step.get("response", {})
                observer_body = observer_step["request"].get("body")
                if (
                    transcript.get("category") != "malformed-input"
                    and isinstance(observer_body, Mapping)
                    and observer_body.get("encoding") == "packet_stream"
                    and response_spec.get("format") != "bancho_packets"
                ):
                    errors.append(_error("packet_observer_without_packet_response", case_id, step_id))
                comparison = response_spec.get("compare", {})
                if comparison.get("body", True) is False:
                    errors.append(_error("assertion_body_not_compared", case_id, step_id))
                if (
                    transcript.get("category") != "malformed-input"
                    and "policy_matrix" not in observer_step
                    and not _has_effective_runtime_predicate(response_spec)
                ):
                    errors.append(_error("behavior_observer_without_runtime_predicate", case_id, step_id))
            case_asserted.update(assertion["client_packets"])
            if assertion["kind"] == "policy-matrix":
                policy_id = assertion["policy_id"]
                if policy_id not in case_policies:
                    errors.append(_error("policy_assertion_without_case_matrix", case_id, policy_id))
            for request_step in assertion["request_steps"]:
                sent_by_step = _packet_ids(step_by_id[request_step]["request"].get("body"))
                for packet_id in assertion["client_packets"]:
                    if packet_id not in sent_by_step:
                        errors.append(
                            _error(
                                "assertion_request_step_did_not_send_packet",
                                case_id,
                                f"{request_step}:{packet_id}",
                            )
                        )
                    else:
                        case_asserted_occurrences.add((request_step, packet_id))
        for packet_id in sorted(case_packets - case_asserted):
            errors.append(_error("packet_behavior_not_asserted", case_id, packet_id))
        for packet_id in sorted(case_asserted - case_packets):
            errors.append(_error("assertion_for_unclaimed_packet", case_id, packet_id))
        for step_id, packet_id in sorted(actual_occurrences - case_asserted_occurrences):
            errors.append(_error("packet_occurrence_not_asserted", case_id, f"{step_id}:{packet_id}"))
        asserted_packets.update(case_asserted)
        if transcript.get("category") == "malformed-input":
            malformed_sent_occurrence_count += len(actual_occurrences)
            malformed_asserted_occurrence_count += len(case_asserted_occurrences)
        else:
            valid_asserted_packets.update(case_asserted)
            sent_occurrence_count += len(actual_occurrences)
            asserted_occurrence_count += len(case_asserted_occurrences)
        declared_routes.update(case_routes)
        observed_routes.update(actual_routes)

    for packet_id in sorted(expected_packets - valid_declared_packets):
        errors.append(_error("missing_packet_transcript", "manifest", packet_id))
    for route in sorted(expected_routes - declared_routes):
        errors.append(_error("missing_route_transcript", "manifest", route))
    for packet_id in sorted(declared_packets - expected_packets):
        errors.append(_error("unknown_packet_coverage", "transcripts", packet_id))
    for route in sorted(declared_routes - expected_routes):
        errors.append(_error("unknown_route_coverage", "transcripts", route))
    for policy_id in sorted(declared_policies - exercised_policies):
        errors.append(_error("missing_policy_matrix", "reference", policy_id))
    for policy_id in sorted(declared_policies):
        expected = declared_policy_packets[policy_id]
        actual = asserted_policy_packets.get(policy_id, set())
        if policy_id in exercised_policies and actual != expected:
            errors.append(
                _error(
                    "policy_packet_set_mismatch",
                    "reference",
                    f"{policy_id}:expected={sorted(expected)}:actual={sorted(actual)}",
                )
            )

    if required_scenarios:
        for scenario_id in sorted(set(observed_scenario_ids) - set(required_scenarios)):
            errors.append(_error("unexpected_scenario", "manifest", scenario_id))
        required_sequence = [scenario["id"] for scenario in scenario_items]
        if (
            len(observed_scenario_ids) == len(required_sequence)
            and set(observed_scenario_ids) == set(required_sequence)
            and observed_scenario_ids != required_sequence
        ):
            errors.append(
                _error(
                    "required_scenario_sequence_mismatch",
                    "manifest",
                    f"expected={required_sequence}:actual={observed_scenario_ids}",
                )
            )

    for scenario_id, expected in sorted(required_scenarios.items()):
        actual = observed_scenarios.get(scenario_id)
        if actual is None:
            errors.append(_error("missing_required_scenario", "manifest", scenario_id))
            continue
        category, step_count, actual_steps, scenario_transcript = actual
        if category != expected["category"]:
            errors.append(
                _error(
                    "required_scenario_category_mismatch",
                    scenario_id,
                    f"expected={expected['category']}:actual={category}",
                )
            )
        if step_count < expected["minimum_steps"]:
            errors.append(
                _error(
                    "required_scenario_too_small",
                    scenario_id,
                    f"expected>={expected['minimum_steps']}:actual={step_count}",
                )
            )
        missing_steps = sorted(set(expected.get("required_steps", [])) - actual_steps)
        for step_id in missing_steps:
            errors.append(_error("missing_required_scenario_step", scenario_id, step_id))
        actual_digest = _scenario_contract_sha256(scenario_transcript)
        if actual_digest != expected.get("contract_sha256"):
            errors.append(
                _error(
                    "required_scenario_contract_changed",
                    scenario_id,
                    f"expected={expected.get('contract_sha256')}:actual={actual_digest}",
                )
            )

    errors.sort(key=lambda item: (item["code"], item["case"], str(item["item"])))
    return {
        "schema": 1,
        "status": "ok" if not errors else "failed",
        "packets": {
            "expected": len(expected_packets),
            "declared": len(valid_declared_packets & expected_packets),
            "observed": len(valid_observed_packets & expected_packets),
            "behavior_asserted": len(valid_asserted_packets & expected_packets),
            "sent_occurrences": sent_occurrence_count,
            "asserted_occurrences": asserted_occurrence_count,
            "malformed_sent_occurrences": malformed_sent_occurrence_count,
            "malformed_asserted_occurrences": malformed_asserted_occurrence_count,
            "missing": sorted(expected_packets - valid_declared_packets),
        },
        "routes": {
            "expected": len(expected_routes),
            "declared": len(declared_routes & expected_routes),
            "observed": len(observed_routes & expected_routes),
            "missing": sorted(expected_routes - declared_routes),
        },
        "policy_matrices": {
            "declared": len(declared_policies),
            "exercised": len(exercised_policies & declared_policies),
            "missing": sorted(declared_policies - exercised_policies),
        },
        "required_scenarios": {
            "declared": len(required_scenarios),
            "present": len(set(required_scenarios) & set(observed_scenarios)),
            "missing": sorted(set(required_scenarios) - set(observed_scenarios)),
        },
        "errors": errors,
    }


def _packet_ids(body: Any) -> set[int]:
    return set(_packet_occurrences(body))


def _packet_occurrences(body: Any) -> list[int]:
    if not isinstance(body, dict) or body.get("encoding") != "packet_stream":
        return []
    packets = body.get("packets", [])
    return [packet["id"] for packet in packets if isinstance(packet, dict) and isinstance(packet.get("id"), int)]


def _has_effective_runtime_predicate(response: Mapping[str, Any]) -> bool:
    if "expect_packet_ids" in response or "expect_text_equals" in response:
        return True
    if response.get("expect_nonempty") is True:
        return True
    return any(
        isinstance(response.get(key), list) and bool(response[key])
        for key in (
            "expect_text_contains",
            "expect_text_lines_exclude_variables",
            "expect_text_lines_include_variables",
            "expect_text_not_contains",
            "packet_fields",
            "require_packet_ids",
        )
    )


def _is_empty_poll(request: Mapping[str, Any]) -> bool:
    body = request.get("body")
    headers = request.get("headers", {})
    return (
        request.get("method") == "POST"
        and request.get("path", "").split("?", 1)[0] == "/"
        and isinstance(headers, Mapping)
        and any(str(name).lower() == "osu-token" for name in headers)
        and isinstance(body, Mapping)
        and body.get("encoding") == "packet_stream"
        and body.get("packets") == []
    )


def _is_readback_request(request: Mapping[str, Any]) -> bool:
    path = request.get("path", "").split("?", 1)[0]
    return isinstance(path, str) and path.startswith("/web/") and request.get("method") in {"GET", "POST"}


def _is_session_readback(request: Mapping[str, Any]) -> bool:
    body = request.get("body")
    headers = request.get("headers", {})
    return (
        request.get("method") == "POST"
        and request.get("path", "").split("?", 1)[0] == "/"
        and isinstance(headers, Mapping)
        and any(str(name).lower() == "osu-token" for name in headers)
        and isinstance(body, Mapping)
        and body.get("encoding") == "packet_stream"
        and isinstance(body.get("packets"), list)
        and len(body["packets"]) == 1
        and body["packets"] == [{"id": 4}]
    )


def _session_token_path(request: Mapping[str, Any]) -> str | None:
    headers = request.get("headers", {})
    if not isinstance(headers, Mapping):
        return None
    value = next((value for name, value in headers.items() if str(name).lower() == "osu-token"), None)
    if not isinstance(value, str) or not value.startswith("{{") or not value.endswith("}}"):
        return None
    return value[2:-2]


def _roles_are_distinct(
    actor_token: str | None,
    observer_token: str | None,
    bound_roles: Mapping[str, str],
) -> bool:
    actor_role = bound_roles.get(actor_token or "")
    observer_role = bound_roles.get(observer_token or "")
    return actor_role is not None and observer_role is not None and actor_role != observer_role


def _scenario_contract_sha256(transcript: Mapping[str, Any]) -> str:
    contract = {key: value for key, value in transcript.items() if key != "_source"}
    encoded = json.dumps(contract, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _error(code: str, case: str, item: Any) -> dict[str, Any]:
    return {"code": code, "case": case, "item": item}
