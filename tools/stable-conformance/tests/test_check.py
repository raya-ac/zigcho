from __future__ import annotations

import importlib.util
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path


TOOL_ROOT = Path(__file__).resolve().parents[1]
FIXTURE_ROOT = Path(__file__).resolve().parent / "fixtures"
sys.path.insert(0, str(TOOL_ROOT))
SPEC = importlib.util.spec_from_file_location("stable_conformance_check", TOOL_ROOT / "check.py")
assert SPEC is not None and SPEC.loader is not None
CHECK = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CHECK
SPEC.loader.exec_module(CHECK)


class StableConformanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "repo"
        shutil.copytree(FIXTURE_ROOT, self.root)
        self.manifest = self.root / "manifest.json"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def check(self) -> dict:
        return CHECK.check_coverage(self.root, self.manifest)

    def error_codes(self) -> set[str]:
        return {error["code"] for error in self.check()["errors"]}

    def test_complete_fixture_is_deterministic_and_gap_free(self) -> None:
        first = self.check()
        second = self.check()
        self.assertEqual(json.dumps(first, sort_keys=True), json.dumps(second, sort_keys=True))
        built = CHECK.build_manifest(self.root, reference_root=self.root / "unused", manifest_path=self.manifest)
        self.assertEqual("ok", built["status"])
        self.assertEqual(3, len(built["packets"]))
        self.assertEqual(2, len(built["routes"]))
        self.assertEqual("ok", first["status"])
        self.assertEqual(3, first["bancho_client_packets"]["declared"])
        self.assertEqual(2, first["bancho_client_packets"]["explicitly_handled"])
        self.assertEqual(1, first["bancho_client_packets"]["ignored_compatibility"])
        self.assertEqual(2, first["legacy_web_routes"]["registered"])

    def test_unclassified_packet_addition_fails(self) -> None:
        protocol = self.root / "src/protocol.zig"
        protocol.write_text(protocol.read_text().replace("    _,", "    new_packet = 111,\n    _,"))
        self.assertIn("unclassified_source_packet", self.error_codes())

    def test_packet_id_collision_fails(self) -> None:
        protocol = self.root / "src/protocol.zig"
        protocol.write_text(protocol.read_text().replace("logout = 2", "logout = 4"))
        codes = self.error_codes()
        self.assertIn("duplicate_source_packet_id", codes)
        self.assertIn("packet_id_changed", codes)

    def test_missing_explicit_handler_fails(self) -> None:
        bancho = self.root / "src/bancho.zig"
        bancho.write_text(bancho.read_text().replace("        .logout => {},\n", ""))
        self.assertIn("missing_packet_handler", self.error_codes())

    def test_unclassified_route_addition_fails(self) -> None:
        stable = self.root / "src/server/routes/stable.zig"
        stable.write_text(stable.read_text().replace(
            "    if (std.mem.eql(u8, path, \"/web/bancho_connect.php\")) return;",
            "    if (std.mem.eql(u8, path, \"/web/new-route.php\")) return;\n"
            "    if (std.mem.eql(u8, path, \"/web/bancho_connect.php\")) return;",
        ))
        self.assertIn("unclassified_source_route", self.error_codes())

    def test_duplicate_top_level_route_registration_fails(self) -> None:
        stable = self.root / "src/server/routes/stable.zig"
        stable.write_text(stable.read_text().replace(
            "    if (std.mem.eql(u8, path, \"/web/bancho_connect.php\")) return;",
            "    if (std.mem.eql(u8, path, \"/web/bancho_connect.php\")) return;\n"
            "    if (std.mem.eql(u8, path, \"/web/bancho_connect.php\")) return;",
        ))
        self.assertIn("duplicate_source_route", self.error_codes())

    def test_route_method_change_fails(self) -> None:
        stable = self.root / "src/server/routes/stable.zig"
        stable.write_text(stable.read_text().replace("req.head.method == .POST", "req.head.method == .GET"))
        self.assertIn("route_methods_changed", self.error_codes())

    def test_restricted_allowlist_parser_reads_only_switch_labels(self) -> None:
        source = """
        pub fn restrictedClientPacketAllowed(packet: ClientPacket) bool {
            return switch (packet) {
                .ping, .request_status => true,
                else => false,
            };
        }
        """
        self.assertEqual(
            CHECK.parse_restricted_allowlist(source),
            ["ping", "request_status"],
        )
        bypassed = source.replace("return switch", "return true or switch")
        with self.assertRaises(CHECK.InspectionError):
            CHECK.parse_restricted_allowlist(bypassed)

    def test_restricted_dispatch_guard_must_wrap_the_packet_switch(self) -> None:
        guarded = """
        fn pollLocked() void {
            while (try reader.next()) |packet| switch (if (session.user.restricted and !protocol.restrictedClientPacketAllowed(packet.id)) @as(protocol.ClientPacket, @enumFromInt(std.math.maxInt(u16))) else packet.id) {
                .ping => {},
                else => {},
            };
        }
        """
        bypassed = guarded.replace(
            "if (session.user.restricted and !protocol.restrictedClientPacketAllowed(packet.id)) @as(protocol.ClientPacket, @enumFromInt(std.math.maxInt(u16))) else packet.id",
            "packet.id",
        )
        dead_guard = bypassed.replace(
            "            };\n",
            "            };\n"
            "            if (false) switch (if (session.user.restricted and !protocol.restrictedClientPacketAllowed(packet.id)) @as(protocol.ClientPacket, @enumFromInt(std.math.maxInt(u16))) else packet.id) { .ping => {} };\n",
        )
        ineffective = guarded.replace(
            "@as(protocol.ClientPacket, @enumFromInt(std.math.maxInt(u16))) else packet.id",
            "packet.id else packet.id",
        )
        self.assertTrue(CHECK.has_restricted_dispatch_guard(guarded))
        self.assertFalse(CHECK.has_restricted_dispatch_guard(bypassed))
        self.assertFalse(CHECK.has_restricted_dispatch_guard(dead_guard))
        self.assertFalse(CHECK.has_restricted_dispatch_guard(ineffective))
        effectful_else = guarded.replace("else => {},", "else => mutate(),")
        self.assertFalse(CHECK.has_restricted_dispatch_guard(effectful_else))

    def test_restricted_pre_dispatch_guards_are_bound_to_the_real_traversals(self) -> None:
        capture = """
        fn captureStablePollLocked() void {
            while (try packets.next()) |packet| : (packet_index += 1) {
                if (session.user.restricted and !protocol.restrictedClientPacketAllowed(packet.id)) continue;
                switch (packet.id) { else => {} }
            }
        }
        """
        presence = """
        fn prepareLazerPresences() void {
            var prepared = Prepared{};
            if (restricted) return prepared;
            var reader: protocol.Reader = .{ .data = body };
            while (try reader.next()) |packet| switch (packet.id) { else => {} };
        }
        """
        self.assertTrue(CHECK.has_restricted_capture_guard(capture))
        self.assertFalse(CHECK.has_restricted_capture_guard(capture.replace("continue;", "mutate();")))
        self.assertTrue(CHECK.has_restricted_presence_preparation_guard(presence))
        self.assertFalse(
            CHECK.has_restricted_presence_preparation_guard(
                presence.replace("if (restricted) return prepared;", "if (false) return prepared;")
            )
        )


if __name__ == "__main__":
    unittest.main()
