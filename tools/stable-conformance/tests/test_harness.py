from __future__ import annotations

import json
import hashlib
import copy
import os
import struct
import sys
import tempfile
import time
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from http_target import HttpResponse, TargetClient, TransportError, prepare_request  # noqa: E402
from coverage import check_transcript_coverage  # noqa: E402
from run import (  # noqa: E402
    _attest_reference_presence_request_all,
    _order_manifest_scenarios,
    _selection_coverage,
)
from normalization import NormalizationError, apply_rules, first_difference  # noqa: E402
from runner import (  # noqa: E402
    ConfigError,
    RunOptions,
    TargetState,
    discover_transcripts,
    load_config,
    redact_value,
    run_transcripts,
    validate_proof_metadata,
)
from transcript import TranscriptError, encode_body, load_transcript, validate_transcript  # noqa: E402


class TranscriptTests(unittest.TestCase):
    def test_source_attested_uncompared_body_is_narrow_and_noncomparative(self) -> None:
        transcript = {
            "schema": 1,
            "id": "source-attested-body",
            "category": "policy-matrix",
            "mutates_state": False,
            "policy_assertions": [
                {
                    "observer_kind": "none",
                    "policy_id": "presence-request-all-reference-routing",
                    "trigger_step": "probe",
                    "steps": ["probe"],
                }
            ],
            "steps": [
                {
                    "id": "probe",
                    "request": {"method": "GET", "path": "/web/bancho_connect.php"},
                    "response": {"format": "bancho_packets"},
                    "policy_matrix": {
                        "id": "presence-request-all-reference-routing",
                        "source_attestation": "reference-presence-request-all-shadowed-set-routing",
                        "targets": {
                            "zigcho": {
                                "status": 200,
                                "required_packet_ids": [83],
                                "allowed_packet_ids": [83],
                                "allow_duplicate_packet_ids": [83],
                                "packet_field_counts": [
                                    {
                                        "packet_id": 83,
                                        "path": "payload.user_id",
                                        "variable": "peer_user_id",
                                        "count": 1,
                                    }
                                ],
                            },
                            "reference": {"status": 200, "body_policy": "uncompared"},
                        },
                    },
                }
            ],
        }
        validate_transcript(transcript)

        missing_attestation = copy.deepcopy(transcript)
        del missing_attestation["steps"][0]["policy_matrix"]["source_attestation"]
        with self.assertRaises(TranscriptError):
            validate_transcript(missing_attestation)

        false_comparison = copy.deepcopy(transcript)
        false_comparison["steps"][0]["policy_matrix"]["compare_target_with_step"] = {
            "reference": "probe"
        }
        with self.assertRaises(TranscriptError):
            validate_transcript(false_comparison)

        malformed = copy.deepcopy(transcript)
        malformed["category"] = "malformed-input"
        del malformed["steps"][0]["policy_matrix"]["source_attestation"]
        validate_transcript(malformed)

    def test_policy_selected_packet_ids_must_be_nonempty_unique_and_common(self) -> None:
        def transcript(selected: list[int]) -> dict:
            return {
                "schema": 1,
                "id": "selected-packet-contract",
                "category": "policy-matrix",
                "mutates_state": True,
                "policy_assertions": [
                    {
                        "observer_kind": "none",
                        "policy_id": "fixture-policy",
                        "trigger_step": "probe",
                        "steps": ["probe"],
                    }
                ],
                "steps": [
                    {
                        "id": "probe",
                        "request": {"method": "POST", "path": "/"},
                        "response": {"format": "bancho_packets"},
                        "policy_matrix": {
                            "id": "fixture-policy",
                            "compare_after_removing": {"zigcho": [8], "reference": []},
                            "compare_packet_ids": selected,
                            "targets": {
                                "zigcho": {"status": 200, "packet_ids": [8, 86, 92]},
                                "reference": {"status": 200, "packet_ids": [86, 92]},
                            },
                        },
                    }
                ],
            }

        validate_transcript(transcript([86, 92]))
        for selected in ([], [86, 86], [8]):
            with self.subTest(selected=selected), self.assertRaises(TranscriptError):
                validate_transcript(transcript(selected))

    def test_empty_transcript_selection_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(TranscriptError, "no conformance transcripts were selected"):
                discover_transcripts([directory])

    def test_evidence_objects_reject_unknown_keys(self) -> None:
        baseline = {
            "schema": 1,
            "id": "closed-schema",
            "category": "legacy-web",
            "mutates_state": False,
            "coverage": {"client_packets": [], "routes": ["ANY /web/bancho_connect.php"]},
            "steps": [
                {
                    "id": "read",
                    "request": {"method": "GET", "path": "/web/bancho_connect.php"},
                    "response": {"format": "binary", "compare": {"body": True}},
                }
            ],
        }
        variants = []
        top = copy.deepcopy(baseline)
        top["scheam"] = 1
        variants.append(top)
        step = copy.deepcopy(baseline)
        step["steps"][0]["assertoin"] = True
        variants.append(step)
        request = copy.deepcopy(baseline)
        request["steps"][0]["request"]["headerss"] = {}
        variants.append(request)
        compare = copy.deepcopy(baseline)
        compare["steps"][0]["response"]["compare"]["headerss"] = []
        variants.append(compare)
        coverage = copy.deepcopy(baseline)
        coverage["coverage"]["packet"] = []
        variants.append(coverage)
        body = copy.deepcopy(baseline)
        body["mutates_state"] = True
        body["steps"][0]["request"] = {
            "method": "POST",
            "path": "/",
            "body": {"encoding": "utf8", "value": "x", "vale": "x"},
        }
        variants.append(body)
        for transcript in variants:
            with self.assertRaises(TranscriptError):
                validate_transcript(transcript)

    def test_causal_response_group_cannot_cross_sessions(self) -> None:
        transcript = {
            "schema": 1,
            "id": "cross-session-group",
            "category": "stable-packets",
            "mutates_state": True,
            "requires": ["one.token", "one.user", "two.token", "two.user"],
            "session_bindings": [
                {"token": "one.token", "user_id": "one.user"},
                {"token": "two.token", "user_id": "two.user"},
            ],
            "coverage": {"client_packets": [4], "routes": []},
            "behavior_assertions": [
                {
                    "kind": "immediate-response",
                    "client_packets": [4],
                    "request_steps": ["action"],
                    "steps": ["action"],
                }
            ],
            "response_groups": [{"id": "bad-unit", "steps": ["action", "drain"]}],
            "steps": [
                {
                    "id": "action",
                    "request": {
                        "method": "POST",
                        "path": "/",
                        "headers": {"osu-token": "{{one.token}}"},
                        "body": {"encoding": "packet_stream", "packets": [{"id": 4}]},
                    },
                    "response": {"format": "bancho_packets", "expect_packet_ids": []},
                },
                {
                    "id": "drain",
                    "request": {
                        "method": "POST",
                        "path": "/",
                        "headers": {"osu-token": "{{two.token}}"},
                        "body": {"encoding": "packet_stream", "packets": []},
                    },
                    "response": {"format": "bancho_packets", "expect_packet_ids": []},
                },
            ],
        }
        with self.assertRaises(TranscriptError):
            validate_transcript(transcript)

    def test_transcript_json_rejects_duplicate_keys_and_nonstandard_numbers(self) -> None:
        for payload in (
            '{"schema":1,"schema":1}',
            '{"schema":1,"id":"bad","value":NaN}',
            '{"schema":1,"id":"bad","value":Infinity}',
            '{"schema":1,"id":"bad","value":1e999}',
            '{"schema":1,"id":"bad","value":-1e999}',
        ):
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "case.json"
                path.write_text(payload, encoding="utf-8")
                with self.assertRaises(TranscriptError):
                    load_transcript(path)

    def test_concat_packet_encoding_preserves_exact_stable_wire_shape(self) -> None:
        body = {
            "encoding": "packet_stream",
            "packets": [
                {
                    "id": 16,
                    "payload": {
                        "encoding": "concat",
                        "parts": [
                            {"encoding": "integer", "format": "i32le", "value": "{{user_id}}"},
                            {"encoding": "osu_string", "value": "ari"}
                        ]
                    }
                }
            ]
        }
        encoded = encode_body(body, {"user_id": 44})
        payload = struct.pack("<i", 44) + b"\x0b\x03ari"
        self.assertEqual(encoded, struct.pack("<HBI", 16, 0, len(payload)) + payload)

    def test_transcript_cannot_escape_the_target_origin(self) -> None:
        transcript = {
            "schema": 1,
            "id": "unsafe",
            "mutates_state": True,
            "steps": [{"id": "step", "request": {"method": "GET", "path": "https://evil.test/"}}],
        }
        with self.assertRaises(TranscriptError):
            validate_transcript(transcript)

    def test_whole_response_ignore_is_rejected(self) -> None:
        for path in ("body", "body.packets.*.payload", "body.packets.0"):
            transcript = {
                "schema": 1,
                "id": "broad-normalizer",
                "mutates_state": False,
                "normalizers": [{"kind": "ignore", "path": path}],
                "steps": [
                    {
                        "id": "step",
                        "request": {"method": "GET", "path": "/web/bancho_connect.php"},
                    }
                ],
            }
            with self.assertRaises(TranscriptError):
                validate_transcript(transcript)
        transcript = {
            "schema": 1,
            "id": "whole-text-replacement",
            "mutates_state": False,
            "normalizers": [{"kind": "replace_substring", "path": "body", "variable": "score_id"}],
            "steps": [
                {"id": "step", "request": {"method": "GET", "path": "/web/bancho_connect.php"}}
            ],
        }
        with self.assertRaises(TranscriptError):
            validate_transcript(transcript)

        transcript["normalizers"] = [
            {"kind": "replace_substring", "path": "body.user_id", "variable": "score_id"}
        ]
        with self.assertRaises(TranscriptError):
            validate_transcript(transcript)

    def test_poll_tokens_require_an_executable_session_binding(self) -> None:
        transcript = {
            "schema": 1,
            "id": "unbound-token",
            "mutates_state": True,
            "requires": ["token", "user_id"],
            "steps": [
                {
                    "id": "poll",
                    "request": {
                        "method": "POST",
                        "path": "/",
                        "headers": {"osu-token": "{{token}}"},
                        "body": {"encoding": "packet_stream", "packets": [{"id": 3}]},
                    },
                }
            ],
        }
        with self.assertRaises(TranscriptError):
            validate_transcript(transcript)
        transcript["session_bindings"] = [{"token": "token", "user_id": "user_id"}]
        transcript["category"] = "stable-packets"
        transcript["coverage"] = {"client_packets": [3], "routes": []}
        transcript["behavior_assertions"] = [
            {
                "kind": "immediate-response",
                "client_packets": [3],
                "request_steps": ["poll"],
                "steps": ["poll"],
            }
        ]
        validate_transcript(transcript)

    def test_request_headers_reject_case_insensitive_duplicates(self) -> None:
        transcript = {
            "schema": 1,
            "id": "duplicate-token-header",
            "category": "stable-packets",
            "mutates_state": True,
            "requires": ["token", "user_id"],
            "session_bindings": [{"token": "token", "user_id": "user_id"}],
            "coverage": {"client_packets": [4], "routes": []},
            "behavior_assertions": [
                {
                    "kind": "immediate-response",
                    "client_packets": [4],
                    "request_steps": ["ping"],
                    "steps": ["ping"],
                }
            ],
            "steps": [
                {
                    "id": "ping",
                    "request": {
                        "method": "POST",
                        "path": "/",
                        "headers": {
                            "osu-token": "{{token}}",
                            "Osu-Token": "unbound",
                        },
                        "body": {"encoding": "packet_stream", "packets": [{"id": 4}]},
                    },
                    "response": {"format": "bancho_packets", "expect_packet_ids": []},
                }
            ],
        }
        with self.assertRaises(TranscriptError):
            validate_transcript(transcript)

    def test_gameplay_semantics_cannot_be_normalized(self) -> None:
        for leaf in ("score", "pp", "mods", "beatmap_status", "rank_namespace", "passed", "replay_available"):
            transcript = {
                "schema": 1,
                "id": "protected-normalizer",
                "mutates_state": False,
                "normalizers": [
                    {"kind": "variable", "path": f"body.packet.payload.{leaf}", "variable": "score_id"}
                ],
                "steps": [
                    {
                        "id": "step",
                        "request": {"method": "GET", "path": "/web/bancho_connect.php"},
                    }
                ],
            }
            with self.assertRaises(TranscriptError):
                validate_transcript(transcript)

    def test_unmarked_poll_or_score_request_cannot_claim_read_only(self) -> None:
        for method, path in (("POST", "/"), ("POST", "/web/osu-submit-modular-selector.php")):
            transcript = {
                "schema": 1,
                "id": "unsafe-read-only",
                "mutates_state": False,
                "steps": [{"id": "step", "request": {"method": method, "path": path}}],
            }
            with self.assertRaises(TranscriptError):
                validate_transcript(transcript)


class NormalizationTests(unittest.TestCase):
    def test_generated_screenshot_names_compare_by_validated_extension(self) -> None:
        rules = [{"kind": "screenshot_filename", "path": "body"}]
        self.assertEqual(
            apply_rules({"body": "Ab1_-xyZ.png"}, rules, {}),
            {"body": "<generated-screenshot:png>"},
        )
        with self.assertRaises(NormalizationError):
            apply_rules({"body": "../../score.txt"}, rules, {})

    def test_variable_normalization_is_exact_and_missing_paths_fail(self) -> None:
        value = {"body": {"packets": [{"payload": {"user_id": 44}}]}}
        rules = [{"kind": "variable", "path": "body.packets.*.payload.user_id", "variable": "user_id"}]
        self.assertEqual(
            apply_rules(value, rules, {"user_id": 44})["body"]["packets"][0]["payload"]["user_id"],
            "<variable:user_id>",
        )
        with self.assertRaises(NormalizationError):
            apply_rules(value, rules, {"user_id": 45})
        with self.assertRaises(NormalizationError):
            apply_rules(value, rules, {"user_id": "44"})

    def test_first_difference_reports_the_exact_packet_field(self) -> None:
        left = {"body": {"packets": [{"payload": {"mods": 64}}]}}
        right = {"body": {"packets": [{"payload": {"mods": 0}}]}}
        difference = first_difference(left, right)
        self.assertEqual(difference.path, "$.body.packets[0].payload.mods")
        self.assertEqual(difference.reason, "value")


class CoverageProofTests(unittest.TestCase):
    def _check(self, transcript):  # noqa: ANN001
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "manifest.json"
            reference = root / "reference.json"
            manifest.write_text(
                json.dumps({"packets": [{"id": 4, "classification": "handled"}], "routes": []}),
                encoding="utf-8",
            )
            reference.write_text(json.dumps({"declared_policy_differences": []}), encoding="utf-8")
            return check_transcript_coverage([transcript], manifest, reference)

    def test_source_attested_packet_98_is_the_last_step_of_the_last_scenario(self) -> None:
        root = Path(__file__).resolve().parents[1]
        transcript = load_transcript(root / "transcripts/packet-session-presence-chat.json")
        manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(transcript["steps"][-1]["id"], "request-all-presences-isolated")
        self.assertEqual(manifest["required_scenarios"][-1]["id"], transcript["id"])

        with_later_poll = copy.deepcopy(transcript)
        with_later_poll["steps"][-2], with_later_poll["steps"][-1] = (
            with_later_poll["steps"][-1],
            with_later_poll["steps"][-2],
        )
        report = check_transcript_coverage(
            [with_later_poll],
            root / "manifest.json",
            root / "reference.json",
        )
        self.assertIn(
            "source_attested_policy_not_terminal_step",
            {error["code"] for error in report["errors"]},
        )

    def test_false_nonempty_flag_is_not_behavior_evidence(self) -> None:
        transcript = {
            "schema": 1,
            "id": "vacuous",
            "category": "stable-packets",
            "coverage": {"client_packets": [4], "routes": []},
            "behavior_assertions": [
                {
                    "kind": "immediate-response",
                    "client_packets": [4],
                    "request_steps": ["ping"],
                    "steps": ["ping"],
                }
            ],
            "steps": [
                {
                    "id": "ping",
                    "request": {
                        "method": "POST",
                        "path": "/",
                        "body": {"encoding": "packet_stream", "packets": [{"id": 4}]},
                    },
                    "response": {"format": "bancho_packets", "expect_nonempty": False},
                }
            ],
        }
        report = self._check(transcript)
        self.assertIn(
            "behavior_observer_without_runtime_predicate",
            {error["code"] for error in report["errors"]},
        )

    def test_observer_must_follow_the_request_it_proves(self) -> None:
        transcript = {
            "schema": 1,
            "id": "backwards",
            "category": "stable-packets",
            "coverage": {"client_packets": [4], "routes": []},
            "behavior_assertions": [
                {
                    "kind": "recipient-poll",
                    "client_packets": [4],
                    "request_steps": ["send"],
                    "steps": ["observe"],
                }
            ],
            "steps": [
                {
                    "id": "observe",
                    "request": {"method": "POST", "path": "/", "body": {"encoding": "packet_stream", "packets": []}},
                    "response": {"format": "bancho_packets", "expect_packet_ids": []},
                },
                {
                    "id": "send",
                    "request": {
                        "method": "POST",
                        "path": "/",
                        "body": {"encoding": "packet_stream", "packets": [{"id": 4}]},
                    },
                    "response": {"format": "bancho_packets", "expect_packet_ids": []},
                },
            ],
        }
        report = self._check(transcript)
        self.assertIn("observer_not_after_request", {error["code"] for error in report["errors"]})

    def test_one_step_cannot_certify_multiple_client_handlers(self) -> None:
        transcript = {
            "schema": 1,
            "id": "bundled",
            "category": "stable-packets",
            "coverage": {"client_packets": [4], "routes": []},
            "behavior_assertions": [
                {
                    "kind": "immediate-response",
                    "client_packets": [4],
                    "request_steps": ["send"],
                    "steps": ["send"],
                }
            ],
            "steps": [
                {
                    "id": "send",
                    "request": {
                        "method": "POST",
                        "path": "/",
                        "body": {"encoding": "packet_stream", "packets": [{"id": 4}, {"id": 4}]},
                    },
                    "response": {"format": "bancho_packets", "expect_packet_ids": []},
                }
            ],
        }
        report = self._check(transcript)
        self.assertIn(
            "multiple_client_packets_in_behavior_step",
            {error["code"] for error in report["errors"]},
        )

    def test_malformed_packet_does_not_satisfy_valid_handler_coverage(self) -> None:
        transcript = {
            "schema": 1,
            "id": "malformed-only",
            "category": "malformed-input",
            "coverage": {"client_packets": [4], "routes": []},
            "behavior_assertions": [
                {
                    "kind": "immediate-response",
                    "client_packets": [4],
                    "request_steps": ["malformed-ping"],
                    "steps": ["malformed-ping"],
                }
            ],
            "steps": [
                {
                    "id": "malformed-ping",
                    "request": {
                        "method": "POST",
                        "path": "/",
                        "body": {"encoding": "packet_stream", "packets": [{"id": 4}]},
                    },
                    "response": {"format": "bancho_packets", "expect_packet_ids": []},
                }
            ],
        }
        report = self._check(transcript)
        self.assertIn("missing_packet_transcript", {error["code"] for error in report["errors"]})
        self.assertEqual(report["packets"]["behavior_asserted"], 0)
        self.assertEqual(report["packets"]["malformed_asserted_occurrences"], 1)

    def test_policy_session_readback_must_be_an_empty_ping(self) -> None:
        transcript = {
            "schema": 1,
            "id": "unsafe-session-readback",
            "category": "policy-matrix",
            "coverage": {"client_packets": [4], "routes": []},
            "session_bindings": [{"token": "actor_token", "user_id": "actor_user_id"}],
            "policy_assertions": [
                {
                    "observer_kind": "session-readback",
                    "policy_id": "session-policy",
                    "trigger_step": "trigger",
                    "steps": ["trigger", "unsafe-observer"],
                }
            ],
            "behavior_assertions": [
                {
                    "kind": "immediate-response",
                    "client_packets": [4],
                    "request_steps": ["trigger"],
                    "steps": ["trigger"],
                }
            ],
            "steps": [
                {
                    "id": "trigger",
                    "request": {
                        "method": "POST",
                        "path": "/",
                        "headers": {"osu-token": "{{actor_token}}"},
                        "body": {"encoding": "packet_stream", "packets": [{"id": 4}]},
                    },
                    "response": {"format": "bancho_packets", "expect_packet_ids": []},
                    "policy_matrix": {
                        "id": "session-policy",
                        "targets": {
                            "zigcho": {"status": 200, "packet_ids": []},
                            "reference": {"status": 200, "packet_ids": []},
                        },
                    },
                },
                {
                    "id": "unsafe-observer",
                    "request": {
                        "method": "POST",
                        "path": "/",
                        "headers": {"osu-token": "{{actor_token}}"},
                        "body": {"encoding": "packet_stream", "packets": [{"id": 2}]},
                    },
                    "response": {"format": "bancho_packets", "expect_packet_ids": []},
                    "policy_matrix": {
                        "id": "session-policy",
                        "targets": {
                            "zigcho": {"status": 200, "packet_ids": []},
                            "reference": {"status": 200, "packet_ids": []},
                        },
                    },
                },
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "manifest.json"
            reference = root / "reference.json"
            manifest.write_text(
                json.dumps({"packets": [{"id": 4, "classification": "handled"}], "routes": []}),
                encoding="utf-8",
            )
            reference.write_text(
                json.dumps(
                    {
                        "declared_policy_differences": [
                            {"id": "session-policy", "packet_ids": [4]}
                        ]
                    }
                ),
                encoding="utf-8",
            )
            report = check_transcript_coverage([transcript], manifest, reference)
        self.assertIn("policy_observer_shape_invalid", {error["code"] for error in report["errors"]})

    def test_required_scenario_cannot_disappear_behind_surface_counts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "manifest.json"
            reference = root / "reference.json"
            manifest.write_text(
                json.dumps(
                    {
                        "packets": [],
                        "routes": [],
                        "required_scenarios": [
                            {
                                "id": "delayed-score",
                                "category": "policy-matrix",
                                "minimum_steps": 4,
                                "required_steps": ["submit"],
                                "contract_sha256": "0" * 64,
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            reference.write_text(json.dumps({"declared_policy_differences": []}), encoding="utf-8")
            report = check_transcript_coverage([], manifest, reference)
        self.assertIn("missing_required_scenario", {error["code"] for error in report["errors"]})

    def test_manifest_rejects_extra_duplicate_and_reordered_scenarios(self) -> None:
        def scenario(scenario_id: str) -> dict:
            return {
                "schema": 1,
                "id": scenario_id,
                "category": "legacy-web",
                "coverage": {"client_packets": [], "routes": []},
                "steps": [],
            }

        first = scenario("first")
        second = scenario("second")
        keys = (
            "behavior_assertions",
            "category",
            "coverage",
            "id",
            "mutates_state",
            "normalizers",
            "policy_assertions",
            "requires",
            "schema",
            "session_bindings",
            "steps",
        )

        def digest(item: dict) -> str:
            contract = {key: item[key] for key in keys if key in item}
            encoded = json.dumps(contract, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()
            return hashlib.sha256(encoded).hexdigest()

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "manifest.json"
            reference = root / "reference.json"
            manifest.write_text(
                json.dumps(
                    {
                        "packets": [],
                        "routes": [],
                        "required_scenarios": [
                            {
                                "id": "first",
                                "category": "legacy-web",
                                "minimum_steps": 0,
                                "required_steps": [],
                                "contract_sha256": digest(first),
                            },
                            {
                                "id": "second",
                                "category": "legacy-web",
                                "minimum_steps": 0,
                                "required_steps": [],
                                "contract_sha256": digest(second),
                            },
                        ],
                    }
                ),
                encoding="utf-8",
            )
            reference.write_text(json.dumps({"declared_policy_differences": []}), encoding="utf-8")

            reordered = check_transcript_coverage([second, first], manifest, reference)
            duplicated = check_transcript_coverage([first, second, dict(second)], manifest, reference)
            extra = check_transcript_coverage([first, second, scenario("unmanifested")], manifest, reference)
            ordered = _order_manifest_scenarios([second, first], manifest)

        self.assertIn("required_scenario_sequence_mismatch", {e["code"] for e in reordered["errors"]})
        self.assertIn("duplicate_scenario_id", {e["code"] for e in duplicated["errors"]})
        self.assertIn("unexpected_scenario", {e["code"] for e in extra["errors"]})
        self.assertEqual([item["id"] for item in ordered], ["first", "second"])

    def test_selected_transcript_does_not_inherit_full_corpus_absence_errors(self) -> None:
        report = {
            "schema": 1,
            "packets": {"declared": 0, "observed": 0, "expected": 46},
            "routes": {"declared": 3, "observed": 3, "expected": 17},
            "policy_matrices": {"declared": 6, "exercised": 0},
            "errors": [
                {"code": "missing_packet_transcript", "case": "manifest", "item": 4},
                {"code": "missing_required_scenario", "case": "manifest", "item": "other"},
                {"code": "required_scenario_contract_changed", "case": "selected", "item": "bad"},
            ],
        }
        selected = _selection_coverage(report)
        self.assertEqual(
            selected["errors"],
            [{"code": "required_scenario_contract_changed", "case": "selected", "item": "bad"}],
        )


class _FakeClient:
    def __init__(self, body: bytes):
        self.body = body

    def request(self, request_spec, variables):  # noqa: ANN001
        return HttpResponse(
            status=200,
            reason="OK",
            headers={"content-type": ["text/plain"]},
            body=self.body,
            elapsed_ms=1.0,
        )


class SourceAttestationTests(unittest.TestCase):
    def _write_reference(self, root: Path, *, handler_enqueue: str, collection_kind: str) -> None:
        handler = root / "app/api/domains/cho.py"
        collections = root / "app/objects/collections.py"
        handler.parent.mkdir(parents=True)
        collections.parent.mkdir(parents=True)
        handler.write_text(
            "@register(ClientPackets.USER_PRESENCE_REQUEST_ALL)\n"
            "class UserPresenceRequestAll(BasePacket):\n"
            "    async def handle(self, player):\n"
            "        buffer = bytearray()\n"
            "        for player in app.state.sessions.players.unrestricted:\n"
            "            buffer += app.packets.user_presence(player)\n"
            f"        {handler_enqueue}(bytes(buffer))\n",
            encoding="utf-8",
        )
        collections.write_text(
            "class Players:\n"
            "    @property\n"
            "    def unrestricted(self):\n"
            f"        return {collection_kind}\n",
            encoding="utf-8",
        )

    def test_packet_98_source_attestation_pins_shadowed_set_routing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_reference(
                root,
                handler_enqueue="player.enqueue",
                collection_kind="{p for p in self if p.priv & Privileges.UNRESTRICTED}",
            )
            report = _attest_reference_presence_request_all(root)
            self.assertTrue(report["attested"])
            self.assertEqual(
                report["id"],
                "reference-presence-request-all-shadowed-set-routing",
            )

    def test_packet_98_source_attestation_rejects_routing_or_collection_mutation(self) -> None:
        variants = (
            ("requester.enqueue", "{p for p in self if p.priv & Privileges.UNRESTRICTED}"),
            ("player.enqueue", "[p for p in self if p.priv & Privileges.UNRESTRICTED]"),
        )
        for handler_enqueue, collection_kind in variants:
            with self.subTest(handler_enqueue=handler_enqueue, collection_kind=collection_kind):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    self._write_reference(
                        root,
                        handler_enqueue=handler_enqueue,
                        collection_kind=collection_kind,
                    )
                    with self.assertRaises(ConfigError):
                        _attest_reference_presence_request_all(root)


class _SequenceClient:
    def __init__(self, bodies: list[bytes]):
        self.bodies = list(bodies)
        self.requests = 0

    def request(self, request_spec, variables):  # noqa: ANN001
        self.requests += 1
        if not self.bodies:
            raise AssertionError("unexpected request")
        return HttpResponse(
            status=200,
            reason="OK",
            headers={"content-type": ["text/plain"]},
            body=self.bodies.pop(0),
            elapsed_ms=1.0,
        )


class RunnerTests(unittest.TestCase):
    @staticmethod
    def _presence_waiver_transcript() -> dict:
        return {
            "schema": 1,
            "id": "presence-waiver",
            "category": "policy-matrix",
            "mutates_state": True,
            "requires": ["peer_user_id"],
            "steps": [
                {
                    "id": "probe",
                    "request": {
                        "method": "POST",
                        "path": "/",
                        "body": {
                            "encoding": "packet_stream",
                            "packets": [
                                {
                                    "id": 98,
                                    "payload": {
                                        "encoding": "integer",
                                        "format": "i32le",
                                        "value": 0,
                                    },
                                }
                            ],
                        },
                    },
                    "response": {"format": "bancho_packets", "compare": {"content_type": False}},
                    "policy_matrix": {
                        "id": "presence-request-all-reference-routing",
                        "source_attestation": "reference-presence-request-all-shadowed-set-routing",
                        "targets": {
                            "zigcho": {
                                "status": 200,
                                "required_packet_ids": [83],
                                "allowed_packet_ids": [83],
                                "allow_duplicate_packet_ids": [83],
                                "packet_field_counts": [
                                    {
                                        "packet_id": 83,
                                        "path": "payload.user_id",
                                        "variable": "peer_user_id",
                                        "count": 1,
                                    }
                                ],
                            },
                            "reference": {"status": 200, "body_policy": "uncompared"},
                        },
                    },
                }
            ],
        }

    @staticmethod
    def _presence_packet(user_id: int, username: str = "peer") -> bytes:
        encoded_name = username.encode("utf-8")
        payload = (
            struct.pack("<i", user_id)
            + b"\x0b"
            + bytes([len(encoded_name)])
            + encoded_name
            + struct.pack("<BBBffi", 24, 0, 1, 0.0, 0.0, 1)
        )
        return struct.pack("<HBI", 83, 0, len(payload)) + payload

    def test_source_attested_waiver_requires_complete_mode_and_attested_id(self) -> None:
        transcript = self._presence_waiver_transcript()
        for options in (
            RunOptions(allow_mutating=True),
            RunOptions(allow_mutating=True, require_all=True),
        ):
            with self.subTest(options=options):
                clients = {
                    "zigcho": _SequenceClient([self._presence_packet(7)]),
                    "reference": _SequenceClient([b""]),
                }
                states = {
                    name: TargetState(name, client, {"peer_user_id": 7}, allows_mutation=True)
                    for name, client in clients.items()
                }
                with self.assertRaises(ConfigError):
                    run_transcripts([transcript], states, options=options)
                self.assertTrue(all(client.requests == 0 for client in clients.values()))

    def test_source_attested_waiver_reports_proof_split_and_exact_requester_count(self) -> None:
        transcript = self._presence_waiver_transcript()
        attestation = frozenset({"reference-presence-request-all-shadowed-set-routing"})
        options = RunOptions(
            allow_mutating=True,
            require_all=True,
            source_attestations=attestation,
        )
        states = {
            "zigcho": TargetState(
                "zigcho",
                _SequenceClient([self._presence_packet(8, "other") + self._presence_packet(7)]),
                {"peer_user_id": 7},
                allows_mutation=True,
            ),
            "reference": TargetState(
                "reference",
                _SequenceClient([b""]),
                {"peer_user_id": 7},
                allows_mutation=True,
            ),
        }
        report = run_transcripts([transcript], states, options=options)
        step = report["cases"][0]["steps"][0]
        self.assertEqual(step["status"], "passed")
        self.assertEqual(step["comparison"], "source_attested_split_contract")
        self.assertFalse(step["live_differential_body"])
        self.assertEqual(step["reference_evidence_type"], "static_source")
        self.assertEqual(
            step["target_body_evidence"],
            {"zigcho": "executable_packet_contract", "reference": "uncompared"},
        )

        duplicate_states = {
            "zigcho": TargetState(
                "zigcho",
                _SequenceClient([self._presence_packet(7) + self._presence_packet(7)]),
                {"peer_user_id": 7},
                allows_mutation=True,
            ),
            "reference": TargetState(
                "reference",
                _SequenceClient([b""]),
                {"peer_user_id": 7},
                allows_mutation=True,
            ),
        }
        duplicate_report = run_transcripts([transcript], duplicate_states, options=options)
        self.assertEqual(duplicate_report["cases"][0]["status"], "failed")
        self.assertIn("exactly 1 time", duplicate_report["cases"][0]["steps"][0]["error"])

    def test_checked_login_bootstrap_policies_compare_the_common_remainder(self) -> None:
        root = Path(__file__).resolve().parents[1]
        fixtures = (
            ("session-login-reconnect.json", "login"),
            ("session-delayed-score.json", "login-before-queue"),
        )
        expected_selected = [5, 11, 71, 72, 75, 83, 92]
        expected_allowed = {
            "zigcho": [5, 11, 65, 71, 72, 75, 83, 89, 92],
            "reference": [5, 11, 24, 65, 71, 72, 75, 76, 83, 89, 92],
        }

        for filename, step_id in fixtures:
            with self.subTest(filename=filename):
                transcript = load_transcript(root / "transcripts" / filename)
                step = next(step for step in transcript["steps"] if step["id"] == step_id)
                matrix = step["policy_matrix"]
                self.assertEqual(matrix["id"], "stable-login-bootstrap")
                self.assertEqual(matrix["compare_packet_ids"], expected_selected)
                self.assertNotIn("compare_after_removing", matrix)
                for target_name, target in matrix["targets"].items():
                    self.assertEqual(target["allowed_packet_ids"], expected_allowed[target_name])
                    self.assertTrue(set(expected_selected).issubset(target["allowed_packet_ids"]))

    def test_selected_packet_comparison_ignores_cross_id_order_but_not_drift(self) -> None:
        def packet(packet_id: int, value: int) -> bytes:
            payload = struct.pack("<i", value)
            return struct.pack("<HBI", packet_id, 0, len(payload)) + payload

        cases = (
            (
                "reordered",
                packet(86, 7) + packet(92, 8),
                [86, 92],
                packet(92, 8) + packet(86, 7),
                [92, 86],
                "passed",
            ),
            (
                "payload-drift",
                packet(86, 7) + packet(92, 8),
                [86, 92],
                packet(92, 8) + packet(86, 9),
                [92, 86],
                "failed",
            ),
            (
                "extra-occurrence",
                packet(86, 7) + packet(92, 8) + packet(86, 7),
                [86, 92, 86],
                packet(92, 8) + packet(86, 7),
                [92, 86],
                "failed",
            ),
        )
        for label, zigcho_body, zigcho_ids, reference_body, reference_ids, expected_status in cases:
            with self.subTest(label=label):
                transcript = {
                    "schema": 1,
                    "id": f"selected-packet-{label}",
                    "category": "policy-matrix",
                    "mutates_state": True,
                    "steps": [
                        {
                            "id": "probe",
                            "request": {"method": "POST", "path": "/"},
                            "response": {"format": "bancho_packets", "compare": {"content_type": False}},
                            "policy_matrix": {
                                "id": "fixture-policy",
                                "compare_packet_ids": [86, 92],
                                "targets": {
                                    "zigcho": {"status": 200, "packet_ids": zigcho_ids},
                                    "reference": {"status": 200, "packet_ids": reference_ids},
                                },
                            },
                        }
                    ],
                }
                states = {
                    "zigcho": TargetState("zigcho", _FakeClient(zigcho_body), {}, allows_mutation=True),
                    "reference": TargetState("reference", _FakeClient(reference_body), {}, allows_mutation=True),
                }
                report = run_transcripts([transcript], states, options=RunOptions(allow_mutating=True))
                self.assertEqual(report["cases"][0]["status"], expected_status)
                if expected_status == "failed":
                    self.assertIn("selected packet 86", report["cases"][0]["steps"][0]["error"])

    def test_declared_policy_matrix_checks_exact_target_packet_ids(self) -> None:
        transcript = {
            "schema": 1,
            "id": "policy",
            "category": "policy-matrix",
            "mutates_state": True,
            "steps": [
                {
                    "id": "policy-step",
                    "request": {"method": "POST", "path": "/"},
                    "response": {"format": "bancho_packets", "compare": {"content_type": False}},
                    "policy_matrix": {
                        "id": "fixture-policy",
                        "targets": {
                            "zigcho": {"status": 200, "packet_ids": []},
                            "reference": {"status": 200, "packet_ids": [8]},
                        },
                    },
                }
            ],
        }
        states = {
            "zigcho": TargetState("zigcho", _FakeClient(b""), {}, allows_mutation=True),
            "reference": TargetState(
                "reference",
                _FakeClient(struct.pack("<HBI", 8, 0, 0)),
                {},
                allows_mutation=True,
            ),
        }
        report = run_transcripts([transcript], states, options=RunOptions(allow_mutating=True))
        self.assertEqual(report["cases"][0]["status"], "passed")
        self.assertEqual(report["cases"][0]["steps"][0]["comparison"], "declared_policy_matrix")

    def test_policy_packet_removal_cannot_hide_a_common_payload_difference(self) -> None:
        def packet(packet_id: int, payload: bytes = b"") -> bytes:
            return struct.pack("<HBI", packet_id, 0, len(payload)) + payload

        transcript = {
            "schema": 1,
            "id": "policy-common-difference",
            "category": "policy-matrix",
            "mutates_state": True,
            "steps": [
                {
                    "id": "probe",
                    "request": {"method": "POST", "path": "/"},
                    "response": {"format": "bancho_packets", "compare": {"content_type": False}},
                    "policy_matrix": {
                        "id": "fixture-policy",
                        "compare_after_removing": {"zigcho": [8], "reference": []},
                        "targets": {
                            "zigcho": {"status": 200, "packet_ids": [8, 86]},
                            "reference": {"status": 200, "packet_ids": [86]},
                        },
                    },
                }
            ],
        }
        states = {
            "zigcho": TargetState(
                "zigcho", _FakeClient(packet(8) + packet(86, struct.pack("<i", 7))), {}, allows_mutation=True
            ),
            "reference": TargetState(
                "reference", _FakeClient(packet(86, struct.pack("<i", 8))), {}, allows_mutation=True
            ),
        }
        report = run_transcripts([transcript], states, options=RunOptions(allow_mutating=True))
        self.assertEqual(report["cases"][0]["status"], "failed")
        self.assertIn("undeclared semantic difference", report["cases"][0]["steps"][0]["error"])

    def test_policy_packet_removal_recompares_the_semantic_remainder(self) -> None:
        def packet(packet_id: int, payload: bytes = b"") -> bytes:
            return struct.pack("<HBI", packet_id, 0, len(payload)) + payload

        transcript = {
            "schema": 1,
            "id": "policy-removal-success",
            "category": "policy-matrix",
            "mutates_state": True,
            "steps": [
                {
                    "id": "probe",
                    "request": {"method": "POST", "path": "/"},
                    "response": {"format": "bancho_packets", "compare": {"content_type": False}},
                    "policy_matrix": {
                        "id": "fixture-policy",
                        "compare_after_removing": {"zigcho": [8], "reference": []},
                        "targets": {
                            "zigcho": {"status": 200, "packet_ids": [8, 86]},
                            "reference": {"status": 200, "packet_ids": [86]},
                        },
                    },
                }
            ],
        }
        shared = packet(86, struct.pack("<i", 7))
        states = {
            "zigcho": TargetState("zigcho", _FakeClient(packet(8) + shared), {}, allows_mutation=True),
            "reference": TargetState("reference", _FakeClient(shared), {}, allows_mutation=True),
        }
        report = run_transcripts([transcript], states, options=RunOptions(allow_mutating=True))
        self.assertEqual(report["cases"][0]["status"], "passed")

    def test_policy_cross_target_route_compares_the_full_payload(self) -> None:
        def packet(packet_id: int, user_id: int) -> bytes:
            payload = struct.pack("<i", user_id)
            return struct.pack("<HBI", packet_id, 0, len(payload)) + payload

        transcript = {
            "schema": 1,
            "id": "cross-target-routing",
            "category": "policy-matrix",
            "mutates_state": True,
            "steps": [
                {
                    "id": "trigger",
                    "request": {"method": "POST", "path": "/"},
                    "response": {"format": "bancho_packets", "compare": {"content_type": False}},
                    "policy_matrix": {
                        "id": "routing-policy",
                        "compare_after_removing": {"zigcho": [5], "reference": []},
                        "targets": {
                            "zigcho": {"status": 200, "packet_ids": [5]},
                            "reference": {"status": 200, "packet_ids": []},
                        },
                    },
                },
                {
                    "id": "observer",
                    "request": {"method": "POST", "path": "/"},
                    "response": {"format": "bancho_packets", "compare": {"content_type": False}},
                    "policy_matrix": {
                        "id": "routing-policy",
                        "compare_after_removing": {"zigcho": [], "reference": [5]},
                        "compare_target_with_step_target": {
                            "reference": {"step": "trigger", "target": "zigcho"}
                        },
                        "targets": {
                            "zigcho": {"status": 200, "packet_ids": []},
                            "reference": {"status": 200, "packet_ids": [5]},
                        },
                    },
                },
            ],
        }
        states = {
            "zigcho": TargetState(
                "zigcho", _SequenceClient([packet(5, 7), b""]), {}, allows_mutation=True
            ),
            "reference": TargetState(
                "reference", _SequenceClient([b"", packet(5, 8)]), {}, allows_mutation=True
            ),
        }
        report = run_transcripts([transcript], states, options=RunOptions(allow_mutating=True))
        self.assertEqual(report["cases"][0]["status"], "failed")
        self.assertIn("routed payload", report["cases"][0]["steps"][1]["error"])

    def test_causal_response_group_compares_packets_across_poll_timing(self) -> None:
        def packet(user_id: int) -> bytes:
            payload = struct.pack("<i", user_id)
            return struct.pack("<HBI", 5, 0, len(payload)) + payload

        transcript = {
            "schema": 1,
            "id": "queue-timing",
            "category": "stable-packets",
            "mutates_state": False,
            "response_groups": [{"id": "action-unit", "steps": ["action", "drain"]}],
            "steps": [
                {
                    "id": "action",
                    "request": {"method": "GET", "path": "/web/bancho_connect.php"},
                    "response": {"format": "bancho_packets", "compare": {"content_type": False}},
                },
                {
                    "id": "drain",
                    "request": {"method": "GET", "path": "/web/bancho_connect.php"},
                    "response": {"format": "bancho_packets", "compare": {"content_type": False}},
                },
            ],
        }

        def run(reference_user_id: int) -> dict:
            states = {
                "zigcho": TargetState("zigcho", _SequenceClient([packet(7), b""]), {}),
                "reference": TargetState("reference", _SequenceClient([b"", packet(reference_user_id)]), {}),
            }
            return run_transcripts([transcript], states)

        passed = run(7)
        self.assertEqual(passed["cases"][0]["status"], "passed")
        self.assertEqual(passed["cases"][0]["steps"][-1]["comparison"], "semantic_packet_sequence")
        failed = run(8)
        self.assertEqual(failed["cases"][0]["status"], "failed")
        self.assertEqual(failed["cases"][0]["steps"][-1]["kind"], "causal_response_group")

    def test_transport_rejects_host_override_before_network_access(self) -> None:
        client = TargetClient(name="fixture", origin="http://127.0.0.1:1")
        with self.assertRaises(TranscriptError):
            client.request(
                {"method": "GET", "path": "/", "headers": {"Host": "other.test"}},
                {},
            )
        with self.assertRaises(TranscriptError):
            client.request({"method": "GET", "path": "/{{path}}"}, {"path": "x#other"})

    def test_request_rendering_is_single_pass(self) -> None:
        prepared = prepare_request(
            {
                "method": "POST",
                "path": "/",
                "headers": {"X-Value": "{{literal}}"},
                "query": {"value": "{{literal}}"},
                "body": {"encoding": "utf8", "value": "{{literal}}"},
            },
            {"literal": "{{other}}", "other": "must-not-expand"},
        )
        self.assertEqual(prepared.headers["X-Value"], "{{other}}")
        self.assertEqual(prepared.query, "value=%7B%7Bother%7D%7D")
        self.assertEqual(prepared.body, b"{{other}}")

    def test_dotted_capture_names_use_the_same_nested_path_at_runtime(self) -> None:
        payload = struct.pack("<i", 7)
        response = struct.pack("<HBI", 5, 0, len(payload)) + payload
        transcript = {
            "schema": 1,
            "id": "nested-capture",
            "category": "policy-matrix",
            "mutates_state": False,
            "steps": [
                {
                    "id": "capture",
                    "request": {"method": "GET", "path": "/web/bancho_connect.php"},
                    "response": {"format": "bancho_packets"},
                    "capture": [
                        {
                            "as": "auth.user_id",
                            "from": "path",
                            "path": "body.packets.0.payload.user_id",
                            "secret": False,
                            "type": "int",
                        }
                    ],
                }
            ],
        }
        state = TargetState("zigcho", _FakeClient(response), {})
        report = run_transcripts([transcript], {"zigcho": state})
        self.assertEqual(report["cases"][0]["status"], "passed")
        self.assertEqual(state.variables, {"auth": {"user_id": 7}})

    def test_transport_uses_one_wall_deadline_and_poisoned_clients_stop(self) -> None:
        class SlowTarget(TargetClient):
            def _request_blocking(self, request_spec, variables):  # noqa: ANN001
                time.sleep(0.15)
                return HttpResponse(200, "OK", {}, b"", 150)

        client = SlowTarget(name="slow", origin="http://127.0.0.1:1", timeout_seconds=0.02)
        started = time.monotonic()
        with self.assertRaises(TransportError):
            client.request({"method": "GET", "path": "/"}, {})
        self.assertLess(time.monotonic() - started, 0.1)
        with self.assertRaises(TransportError):
            client.request({"method": "GET", "path": "/"}, {})

    def test_dual_target_report_redacts_secrets_at_first_difference(self) -> None:
        transcript = {
            "schema": 1,
            "id": "difference",
            "category": "test",
            "steps": [
                {
                    "id": "request",
                    "request": {"method": "GET", "path": "/"},
                    "response": {"format": "text"},
                }
            ],
        }
        states = {
            "zigcho": TargetState("zigcho", _FakeClient(b"zig-secret"), {}, {"zig-secret"}),
            "reference": TargetState("reference", _FakeClient(b"ref-secret"), {}, {"ref-secret"}),
        }
        report = run_transcripts([transcript], states, options=RunOptions())
        difference = report["cases"][0]["steps"][0]["difference"]
        self.assertEqual(difference["left"], "<redacted:response-body>")
        self.assertEqual(difference["right"], "<redacted:response-body>")

    def test_session_preflight_rejects_two_matching_invalid_tokens(self) -> None:
        invalid = struct.pack("<HBI", 24, 0, 0) + struct.pack("<HBI", 86, 0, 4) + struct.pack("<i", 0)
        transcript = {
            "schema": 1,
            "id": "invalid-sessions",
            "category": "stable-packets",
            "mutates_state": True,
            "requires": ["token", "user_id"],
            "session_bindings": [{"token": "token", "user_id": "user_id"}],
            "steps": [
                {
                    "id": "poll",
                    "request": {
                        "method": "POST",
                        "path": "/",
                        "headers": {"osu-token": "{{token}}"},
                        "body": {"encoding": "packet_stream", "packets": [{"id": 4}]},
                    },
                    "response": {"format": "bancho_packets", "expect_packet_ids": []},
                }
            ],
        }
        states = {
            "zigcho": TargetState("zigcho", _FakeClient(invalid), {"token": "z", "user_id": 4}, {"z"}, True),
            "reference": TargetState("reference", _FakeClient(invalid), {"token": "r", "user_id": 4}, {"r"}, True),
        }
        report = run_transcripts([transcript], states, options=RunOptions(allow_mutating=True))
        self.assertEqual(report["cases"][0]["status"], "failed")
        self.assertEqual(report["cases"][0]["session_preflights"][0]["status"], "failed")

    def test_report_uses_an_ephemeral_keyed_body_digest(self) -> None:
        transcript = {
            "schema": 1,
            "id": "digest",
            "category": "test",
            "steps": [
                {
                    "id": "request",
                    "request": {"method": "GET", "path": "/"},
                    "response": {"format": "text"},
                }
            ],
        }
        state = TargetState("zigcho", _FakeClient(b"7"), {}, {"7"})
        report = run_transcripts([transcript], {"zigcho": state})
        target = report["cases"][0]["steps"][0]["targets"]["zigcho"]
        self.assertNotIn("body_sha256", target)
        self.assertNotEqual(target["body_hmac_sha256"], hashlib.sha256(b"7").hexdigest())

    def test_binary_body_difference_never_leaks_secret_bytes_or_raw_digest(self) -> None:
        transcript = {
            "schema": 1,
            "id": "binary-secret-difference",
            "category": "malformed-input",
            "steps": [
                {
                    "id": "request",
                    "request": {"method": "GET", "path": "/"},
                    "response": {"format": "bancho_packets"},
                }
            ],
        }
        states = {
            "zigcho": TargetState("zigcho", _FakeClient(b"7"), {}, {"7"}),
            "reference": TargetState("reference", _FakeClient(b"8"), {}, {"8"}),
        }
        report = run_transcripts([transcript], states)
        serialized = json.dumps(report, sort_keys=True)
        difference = report["cases"][0]["steps"][0]["difference"]
        self.assertEqual(difference["left"], "<redacted:response-body>")
        self.assertEqual(difference["right"], "<redacted:response-body>")
        self.assertNotIn(hashlib.sha256(b"7").hexdigest(), serialized)
        self.assertNotIn(hashlib.sha256(b"8").hexdigest(), serialized)
        self.assertNotIn('"remainder_hex": "37"', serialized)
        self.assertNotIn('"remainder_hex": "38"', serialized)

    def test_complete_run_validates_all_variables_before_first_request(self) -> None:
        first = {
            "schema": 1,
            "id": "first",
            "category": "test",
            "mutates_state": False,
            "steps": [{"id": "read", "request": {"method": "GET", "path": "/web/bancho_connect.php"}}],
        }
        later = {
            "schema": 1,
            "id": "later",
            "category": "test",
            "mutates_state": False,
            "requires": ["missing"],
            "steps": [{"id": "read", "request": {"method": "GET", "path": "/web/bancho_connect.php"}}],
        }
        clients = {name: _SequenceClient([b""]) for name in ("zigcho", "reference")}
        states = {name: TargetState(name, client, {}) for name, client in clients.items()}
        with self.assertRaises(ConfigError):
            run_transcripts([first, later], states, options=RunOptions(require_all=True))
        self.assertTrue(all(client.requests == 0 for client in clients.values()))

    def test_complete_run_preflights_assertion_variables_before_first_request(self) -> None:
        transcript = {
            "schema": 1,
            "id": "missing-assertion-variable",
            "category": "test",
            "mutates_state": False,
            "steps": [
                {
                    "id": "read",
                    "request": {"method": "GET", "path": "/web/bancho_connect.php"},
                    "response": {
                        "format": "bancho_packets",
                        "packet_fields": [
                            {
                                "packet_id": 5,
                                "path": "payload.user_id",
                                "variable": "missing_user_id",
                            }
                        ],
                    },
                }
            ],
        }
        clients = {name: _SequenceClient([b""]) for name in ("zigcho", "reference")}
        states = {name: TargetState(name, client, {}) for name, client in clients.items()}
        with self.assertRaises(ConfigError):
            run_transcripts([transcript], states, options=RunOptions(require_all=True))
        self.assertTrue(all(client.requests == 0 for client in clients.values()))

    def test_complete_run_dry_encodes_every_body_before_first_request(self) -> None:
        first = {
            "schema": 1,
            "id": "first-read",
            "category": "test",
            "mutates_state": False,
            "steps": [{"id": "read", "request": {"method": "GET", "path": "/web/bancho_connect.php"}}],
        }
        invalid = {
            "schema": 1,
            "id": "invalid-late-body",
            "category": "test",
            "mutates_state": False,
            "steps": [
                {
                    "id": "read",
                    "request": {
                        "method": "GET",
                        "path": "/web/bancho_connect.php",
                        "body": {"encoding": "base64", "value": "{{bad_body}}"},
                    },
                }
            ],
        }
        clients = {name: _SequenceClient([b""]) for name in ("zigcho", "reference")}
        states = {
            name: TargetState(name, client, {"bad_body": "%%%"})
            for name, client in clients.items()
        }
        with self.assertRaises(ConfigError):
            run_transcripts([first, invalid], states, options=RunOptions(require_all=True))
        self.assertTrue(all(client.requests == 0 for client in clients.values()))

    def test_opaque_compressed_packet_cannot_count_as_semantic_handler_evidence(self) -> None:
        transcript = {
            "schema": 1,
            "id": "opaque-ping",
            "category": "stable-packets",
            "mutates_state": True,
            "steps": [
                {
                    "id": "ping",
                    "request": {
                        "method": "POST",
                        "path": "/",
                        "body": {
                            "encoding": "packet_stream",
                            "packets": [
                                {"id": 4, "compression": 1, "payload": {"encoding": "hex", "value": "deadbeef"}}
                            ],
                        },
                    },
                    "response": {"format": "bancho_packets", "expect_packet_ids": []},
                }
            ],
        }
        client = _SequenceClient([b""])
        state = TargetState("zigcho", client, {}, allows_mutation=True)
        report = run_transcripts([transcript], {"zigcho": state}, options=RunOptions(allow_mutating=True))
        self.assertEqual(report["cases"][0]["status"], "failed")
        self.assertIn("decoder diagnostic", report["cases"][0]["steps"][0]["error"])
        self.assertEqual(client.requests, 0)

    def test_opaque_compressed_server_packet_cannot_count_as_response_evidence(self) -> None:
        compressed = struct.pack("<HBI", 8, 1, 4) + b"pong"
        transcript = {
            "schema": 1,
            "id": "opaque-server-packet",
            "category": "stable-packets",
            "mutates_state": False,
            "steps": [
                {
                    "id": "read",
                    "request": {"method": "GET", "path": "/web/bancho_connect.php"},
                    "response": {"format": "bancho_packets"},
                }
            ],
        }
        report = run_transcripts([transcript], {"zigcho": TargetState("zigcho", _FakeClient(compressed), {})})
        self.assertEqual(report["cases"][0]["status"], "failed")
        self.assertIn("decoder diagnostic", report["cases"][0]["steps"][0]["error"])

    def test_complete_run_rejects_fixture_roles_that_share_one_identity(self) -> None:
        transcript = {
            "schema": 1,
            "id": "duplicate-role",
            "category": "test",
            "mutates_state": False,
            "requires": ["one.token", "one.user", "two.token", "two.user"],
            "session_bindings": [
                {"token": "one.token", "user_id": "one.user"},
                {"token": "two.token", "user_id": "two.user"},
            ],
            "steps": [{"id": "read", "request": {"method": "GET", "path": "/web/bancho_connect.php"}}],
        }
        variables = {
            "one": {"token": "first", "user": 7},
            "two": {"token": "second", "user": 7},
        }
        states = {
            name: TargetState(name, _SequenceClient([b""]), variables)
            for name in ("zigcho", "reference")
        }
        with self.assertRaises(ConfigError):
            run_transcripts([transcript], states, options=RunOptions(require_all=True))

    def test_complete_run_keeps_login_created_roles_separate(self) -> None:
        transcript = {
            "schema": 1,
            "id": "login-role-alias",
            "category": "test",
            "mutates_state": False,
            "requires": ["online.token", "online.user", "login.user"],
            "session_bindings": [{"token": "online.token", "user_id": "online.user"}],
            "identity_roles": ["login.user"],
            "steps": [{"id": "read", "request": {"method": "GET", "path": "/web/bancho_connect.php"}}],
        }
        variables = {"online": {"token": "token", "user": 7}, "login": {"user": 7}}
        states = {
            name: TargetState(name, _SequenceClient([b""]), variables)
            for name in ("zigcho", "reference")
        }
        with self.assertRaises(ConfigError):
            run_transcripts([transcript], states, options=RunOptions(require_all=True))

    def test_score_submission_token_must_be_bound_to_a_fixture_session(self) -> None:
        transcript = {
            "schema": 1,
            "id": "unbound-score-token",
            "mutates_state": True,
            "steps": [
                {
                    "id": "submit",
                    "request": {
                        "method": "POST",
                        "path": "/web/osu-submit-modular-selector.php",
                        "headers": {"token": "literal-token"},
                    },
                }
            ],
        }
        with self.assertRaises(TranscriptError):
            validate_transcript(transcript)

    def test_score_success_contract_rejects_stables_200_error_body(self) -> None:
        transcript = {
            "schema": 1,
            "id": "score-result",
            "category": "test",
            "steps": [
                {
                    "id": "submit",
                    "request": {"method": "GET", "path": "/"},
                    "response": {
                        "format": "text",
                        "expect_status": 200,
                        "expect_text_contains": ["chartId:beatmap", "onlineScoreId:"],
                        "expect_text_not_contains": ["error: no"],
                    },
                }
            ],
        }
        state = TargetState("zigcho", _FakeClient(b"error: no"), {})
        report = run_transcripts([transcript], {"zigcho": state})
        self.assertEqual(report["cases"][0]["status"], "failed")

    def test_nonempty_contract_rejects_two_missing_replays(self) -> None:
        transcript = {
            "schema": 1,
            "id": "replay",
            "category": "test",
            "steps": [
                {
                    "id": "download",
                    "request": {"method": "GET", "path": "/"},
                    "response": {"format": "binary", "expect_status": 200, "expect_nonempty": True},
                }
            ],
        }
        states = {
            "zigcho": TargetState("zigcho", _FakeClient(b""), {}),
            "reference": TargetState("reference", _FakeClient(b""), {}),
        }
        report = run_transcripts([transcript], states)
        self.assertEqual(report["cases"][0]["status"], "failed")

    def test_complete_proof_requires_attributable_fixture_and_commits(self) -> None:
        pinned = "a" * 40
        states = {
            "zigcho": TargetState("zigcho", _FakeClient(b""), {}),
            "reference": TargetState("reference", _FakeClient(b""), {}),
        }
        good = {
            "metadata": {
                "fixture": "stable-proof-20260830",
                "fixture_reset_at": "2026-08-30T00:00:00Z",
                "fixture_snapshot_sha256": "c" * 64,
                "zigcho_commit": "b" * 40,
                "reference_commit": pinned,
            }
        }
        validate_proof_metadata(good, states, pinned_reference_commit=pinned)
        for key, value in (
            ("fixture", "replace-with-an-isolated-fixture-id"),
            ("zigcho_commit", "main"),
            ("reference_commit", "deadbeef"),
        ):
            broken = json.loads(json.dumps(good))
            broken["metadata"][key] = value
            with self.assertRaises(ConfigError):
                validate_proof_metadata(broken, states, pinned_reference_commit=pinned)

    def test_policy_id_cannot_claim_the_wrong_packet_scope(self) -> None:
        transcript = {
            "schema": 1,
            "id": "wrong-policy-scope",
            "category": "policy-matrix",
            "mutates_state": True,
            "coverage": {"client_packets": [78], "routes": []},
            "behavior_assertions": [
                {
                    "kind": "policy-matrix",
                    "policy_id": "fixture-policy",
                    "client_packets": [78],
                    "request_steps": ["part"],
                    "steps": ["part"],
                }
            ],
            "steps": [
                {
                    "id": "part",
                    "request": {
                        "method": "POST",
                        "path": "/",
                        "body": {"encoding": "packet_stream", "packets": [{"id": 78}]},
                    },
                    "response": {"format": "bancho_packets", "expect_packet_ids": []},
                    "policy_matrix": {
                        "id": "fixture-policy",
                        "targets": {
                            "zigcho": {"status": 200, "packet_ids": []},
                            "reference": {"status": 200, "packet_ids": []},
                        },
                    },
                }
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "manifest.json"
            reference = Path(directory) / "reference.json"
            manifest.write_text(
                json.dumps(
                    {
                        "packets": [{"id": 78, "classification": "handled"}],
                        "routes": [],
                    }
                ),
                encoding="utf-8",
            )
            reference.write_text(
                json.dumps(
                    {
                        "declared_policy_differences": [
                            {"id": "fixture-policy", "packet_ids": [63]}
                        ]
                    }
                ),
                encoding="utf-8",
            )
            report = check_transcript_coverage([transcript], manifest, reference)
        self.assertIn("policy_packet_set_mismatch", {error["code"] for error in report["errors"]})

    def test_config_resolves_credentials_from_environment_without_echoing_them(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "targets": {
                            "zigcho": {
                                "origin": "http://127.0.0.1:1",
                                "variables": {
                                    "password": {"env": "ZIGCHO_HARNESS_TEST_SECRET", "secret": True},
                                    "user_id": {"value": "44", "type": "int"},
                                },
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )
            previous = os.environ.get("ZIGCHO_HARNESS_TEST_SECRET")
            os.environ["ZIGCHO_HARNESS_TEST_SECRET"] = "not-printed"
            try:
                _, states = load_config(path)
            finally:
                if previous is None:
                    del os.environ["ZIGCHO_HARNESS_TEST_SECRET"]
                else:
                    os.environ["ZIGCHO_HARNESS_TEST_SECRET"] = previous
            self.assertEqual(states["zigcho"].variables["password"], "not-printed")
            self.assertEqual(states["zigcho"].variables["user_id"], 44)
            self.assertIn("not-printed", states["zigcho"].secret_values)
            states["zigcho"].secret_values.add("7")
            self.assertEqual(redact_value({"nested": [7, "?7!"]}, states.values()), {"nested": ["<redacted>", "?<redacted>!"]})

    def test_config_rejects_unknown_control_keys(self) -> None:
        baseline = {
            "schema": 1,
            "targets": {
                "zigcho": {
                    "origin": "http://127.0.0.1:1",
                    "limits": {"timeout_seconds": 1},
                    "variables": {"password": {"value": "hash", "secret": True}},
                }
            },
        }
        variants = []
        root = copy.deepcopy(baseline)
        root["target"] = {}
        variants.append(root)
        target = copy.deepcopy(baseline)
        target["targets"]["zigcho"]["orgin"] = "http://127.0.0.1:2"
        variants.append(target)
        limits = copy.deepcopy(baseline)
        limits["targets"]["zigcho"]["limits"]["timeouts_seconds"] = 2
        variants.append(limits)
        wrapper = copy.deepcopy(baseline)
        wrapper["targets"]["zigcho"]["variables"]["password"]["secert"] = True
        variants.append(wrapper)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            for config in variants:
                path.write_text(json.dumps(config), encoding="utf-8")
                with self.assertRaises(ConfigError):
                    load_config(path)


if __name__ == "__main__":
    unittest.main()
