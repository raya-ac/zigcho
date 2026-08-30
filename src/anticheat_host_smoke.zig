const std = @import("std");
const abi = @import("anticheat_abi.zig");
const anticheat = @import("anticheat_plugin.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len != 2) {
        std.log.err("usage: anticheat-host-smoke <module>", .{});
        return error.InvalidArguments;
    }
    var host = try anticheat.Host.open(args[1]);
    defer host.close();
    if (host.ruleRevision() != abi.rule_revision) return error.UnexpectedRuleRevision;
    const decision = try host.evaluate(.{
        .event_kind = abi.EventKind.score,
        .client_family = abi.ClientFamily.stable,
        .ruleset = 0,
        .namespace = abi.Namespace.vanilla,
    });
    const login_decision = try host.evaluate(.{
        .event_kind = abi.EventKind.login,
        .client_family = abi.ClientFamily.stable,
        .evidence = abi.Evidence.exact_hardware_match,
        .hardware_match_count = 1,
    });
    const client_signal_decision = try host.evaluate(.{
        .event_kind = abi.EventKind.heartbeat,
        .client_family = abi.ClientFamily.stable,
        .evidence = abi.Evidence.high_confidence_client_flag | abi.Evidence.registry_remnant,
    });
    const missing_replay_decision = try host.evaluate(.{
        .event_kind = abi.EventKind.score,
        .client_family = abi.ClientFamily.stable,
        .ruleset = 0,
        .namespace = abi.Namespace.vanilla,
        .event_flags = abi.EventFlag.passed | abi.EventFlag.replay_required,
        .evidence = abi.Evidence.required_replay_missing,
        .n300 = 80,
        .n100 = 10,
        .n50 = 2,
        .nmiss = 1,
    });
    const checksum_decision = try host.evaluate(.{
        .event_kind = abi.EventKind.score,
        .client_family = abi.ClientFamily.stable,
        .ruleset = 0,
        .namespace = abi.Namespace.vanilla,
        .event_flags = abi.EventFlag.passed | abi.EventFlag.replay_required,
        .evidence = abi.Evidence.checksum_mismatch,
        .n300 = 80,
        .n100 = 10,
        .n50 = 2,
        .nmiss = 1,
    });
    const reused_content_decision = try host.evaluate(.{
        .event_kind = abi.EventKind.score,
        .client_family = abi.ClientFamily.stable,
        .ruleset = 0,
        .namespace = abi.Namespace.vanilla,
        .event_flags = abi.EventFlag.passed | abi.EventFlag.replay_required,
        .evidence = abi.Evidence.replay_content_reused,
        .n300 = 80,
        .n100 = 10,
        .n50 = 2,
        .nmiss = 1,
    });
    const cadence_decision = try host.evaluate(.{
        .event_kind = abi.EventKind.score,
        .client_family = abi.ClientFamily.stable,
        .ruleset = 0,
        .namespace = abi.Namespace.vanilla,
        .event_flags = abi.EventFlag.passed | abi.EventFlag.replay_required,
        .evidence = abi.Evidence.suspicious_frame_cadence,
        .n300 = 80,
        .n100 = 10,
        .n50 = 2,
        .nmiss = 1,
    });
    const shadow_flags = abi.DecisionFlag.write_audit | abi.DecisionFlag.require_staff_review;
    if (login_decision.action != abi.Action.audit or login_decision.reason != abi.Reason.exact_hardware_match or
        login_decision.flags & abi.DecisionFlag.disconnect_session != 0 or login_decision.rule_revision == 0) return error.UnexpectedLoginDecision;
    if (client_signal_decision.action != abi.Action.audit or client_signal_decision.reason != abi.Reason.high_confidence_client_flag or
        client_signal_decision.flags & abi.DecisionFlag.disconnect_session != 0 or client_signal_decision.rule_revision != login_decision.rule_revision) return error.UnexpectedClientSignalDecision;
    if (missing_replay_decision.action != abi.Action.challenge or missing_replay_decision.reason != abi.Reason.required_replay_missing or
        missing_replay_decision.flags & abi.DecisionFlag.hold_score == 0 or missing_replay_decision.rule_revision != login_decision.rule_revision) return error.UnexpectedMissingReplayDecision;
    if (checksum_decision.action != abi.Action.challenge or checksum_decision.reason != abi.Reason.checksum_mismatch or
        checksum_decision.flags & abi.DecisionFlag.hold_score == 0 or checksum_decision.rule_revision != login_decision.rule_revision) return error.UnexpectedChecksumDecision;
    if (reused_content_decision.action != abi.Action.audit or reused_content_decision.reason != abi.Reason.replay_content_reused or
        reused_content_decision.flags != shadow_flags or reused_content_decision.rule_revision != host.ruleRevision()) return error.UnexpectedReusedContentDecision;
    if (cadence_decision.action != abi.Action.audit or cadence_decision.reason != abi.Reason.suspicious_frame_cadence or
        cadence_decision.flags != shadow_flags or cadence_decision.rule_revision != host.ruleRevision()) return error.UnexpectedCadenceDecision;
    var frames: [240]abi.ReplayFrameV1 = undefined;
    var objects: [80]abi.HitObjectV1 = undefined;
    for (0..80) |index| {
        const time: i64 = 1000 + @as(i64, @intCast(index)) * 100;
        const x: f32 = @floatFromInt(64 + index % 8 * 48);
        const y: f32 = @floatFromInt(72 + index % 6 * 44);
        frames[index * 3] = .{ .time_ms = time - 1, .x = x, .y = y, .keys = 0 };
        frames[index * 3 + 1] = .{ .time_ms = time, .x = x, .y = y, .keys = 4 };
        frames[index * 3 + 2] = .{ .time_ms = time + 1, .x = x, .y = y, .keys = 0 };
        objects[index] = .{ .time_ms = time, .x = x, .y = y, .kind = abi.HitObjectKind.circle };
    }
    const gameplay = try host.evaluateGameplay(.{
        .base = .{
            .event_kind = abi.EventKind.score,
            .client_family = abi.ClientFamily.stable,
            .ruleset = 0,
            .namespace = abi.Namespace.vanilla,
            .event_flags = abi.EventFlag.passed | abi.EventFlag.replay_required,
            .n300 = objects.len,
            .map_objects = objects.len,
            .map_duration_ms = @intCast(objects[objects.len - 1].time_ms),
        },
        .passed_hits = objects.len,
        .hit_window_ms = 150,
        .frames = &frames,
        .frame_count = frames.len,
        .objects = &objects,
        .object_count = objects.len,
    });
    std.debug.print("module={s} abi={d} rule_revision={d} action={d} login_action={d} client_signal_action={d} missing_replay_action={d} missing_replay_reason={d} checksum_action={d} checksum_reason={d} reused_content_action={d} cadence_action={d} gameplay_action={d} gameplay_reason={d} objects={d} clicks={d} exact_bps={d} center_bps={d}\n", .{
        host.name(), abi.version, host.ruleRevision(), decision.action, login_decision.action, client_signal_decision.action, missing_replay_decision.action, missing_replay_decision.reason, checksum_decision.action, checksum_decision.reason, reused_content_decision.action, cadence_decision.action, gameplay.decision.action, gameplay.decision.reason, gameplay.objects_checked, gameplay.matched_clicks, gameplay.exact_timing_bps, gameplay.center_hits_bps,
    });
}
