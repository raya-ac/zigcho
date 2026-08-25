const std = @import("std");
const abi = @import("anticheat_abi.zig");
const stable_score = @import("stable_score.zig");
const stable_mods = @import("stable_mods.zig");

pub const module_name = "zigcho-host";
pub const rule_revision: u32 = 1;

pub const Observation = struct {
    action: u32 = abi.Action.audit,
    reason: u32,
    risk_score: u32,
    confidence_bps: u32 = 10_000,
    evidence: u64,
    replay_match_count: u32 = 0,
    decision_flags: u64 = abi.DecisionFlag.write_audit | abi.DecisionFlag.require_staff_review,
    rule_revision: u32 = rule_revision,
};

pub const Signal = struct {
    fallback: Observation,
    event: abi.EventV1,
};

pub const ReplayIssue = enum {
    missing,
    invalid_payload,
};

pub const StableScoreIssue = enum {
    checksum_mismatch,
    required_replay_missing,
};

fn namespaceForMods(mods: i32) u32 {
    if (mods & stable_mods.autopilot != 0) return abi.Namespace.autopilot;
    if (mods & stable_mods.relax != 0) return abi.Namespace.relax;
    if (mods & stable_mods.score_v2 != 0) return abi.Namespace.score_v2;
    return abi.Namespace.vanilla;
}

pub fn stableLogin(hardware_match_count: u32, running_under_wine: bool) ?Observation {
    if (hardware_match_count == 0) return null;
    const bounded_matches: u32 = @min(hardware_match_count, 10);
    return .{
        .reason = abi.Reason.exact_hardware_match,
        .risk_score = 225 + bounded_matches * @as(u32, 25),
        .evidence = abi.Evidence.exact_hardware_match | (if (running_under_wine) abi.Evidence.running_under_wine else 0),
    };
}

pub fn stableLoginSignal(hardware_match_count: u32, running_under_wine: bool) ?Signal {
    const fallback = stableLogin(hardware_match_count, running_under_wine) orelse return null;
    const bounded_matches = @min(hardware_match_count, 100_000);
    return .{
        .fallback = fallback,
        .event = .{
            .event_kind = abi.EventKind.login,
            .client_family = abi.ClientFamily.stable,
            .evidence = fallback.evidence,
            .hardware_match_count = bounded_matches,
        },
    };
}

pub fn stableLastFm(flags: u32) ?Observation {
    const hq_flags: u32 = (@as(u32, 1) << 17) | (@as(u32, 1) << 18);
    const registry_flag: u32 = @as(u32, 1) << 19;
    const high_confidence = flags & hq_flags != 0;
    const registry = flags & registry_flag != 0;
    if (!high_confidence and !registry) return null;
    return .{
        .reason = if (high_confidence) abi.Reason.high_confidence_client_flag else abi.Reason.registry_remnant,
        .risk_score = (if (high_confidence) @as(u32, 350) else 0) + (if (registry) @as(u32, 50) else 0),
        .evidence = (if (high_confidence) abi.Evidence.high_confidence_client_flag else 0) |
            (if (registry) abi.Evidence.registry_remnant else 0),
    };
}

pub fn stableLastFmSignal(flags: u32) ?Signal {
    const fallback = stableLastFm(flags) orelse return null;
    return .{
        .fallback = fallback,
        .event = .{
            .event_kind = abi.EventKind.heartbeat,
            .client_family = abi.ClientFamily.stable,
            .evidence = fallback.evidence,
        },
    };
}

pub fn stableReplay(issue: ReplayIssue, replay_match_count: u32) Observation {
    const bounded_matches: u32 = @min(replay_match_count, 100_000);
    return .{
        .reason = switch (issue) {
            .missing => abi.Reason.required_replay_missing,
            .invalid_payload => abi.Reason.invalid_replay_payload,
        },
        .risk_score = switch (issue) {
            .missing => 200,
            .invalid_payload => 250 + @min(bounded_matches, 5) * @as(u32, 25),
        },
        .evidence = (if (issue == .missing) abi.Evidence.required_replay_missing else 0) |
            (if (bounded_matches != 0) abi.Evidence.replay_hash_reused else 0),
        .replay_match_count = bounded_matches,
    };
}

pub fn stableScoreSignal(score: stable_score.Submission, issue: StableScoreIssue) Signal {
    const fallback: Observation = switch (issue) {
        .checksum_mismatch => .{
            .reason = abi.Reason.checksum_mismatch,
            .risk_score = 300,
            .evidence = abi.Evidence.checksum_mismatch,
        },
        .required_replay_missing => stableReplay(.missing, 0),
    };
    const accuracy_ppm: u32 = @intFromFloat(@round(@min(1.0, @max(0.0, score.accuracy())) * 1_000_000.0));
    const event_flags = (if (score.passed) abi.EventFlag.passed else 0) |
        (if (score.passed) abi.EventFlag.replay_required else 0);
    return .{
        .fallback = fallback,
        .event = .{
            .event_kind = abi.EventKind.score,
            .client_family = abi.ClientFamily.stable,
            .ruleset = score.mode,
            .namespace = namespaceForMods(score.mods),
            .event_flags = event_flags,
            .evidence = fallback.evidence,
            .score = @intCast(score.total_score),
            .accuracy_ppm = accuracy_ppm,
            .max_combo = @intCast(score.max_combo),
            .n300 = @intCast(score.n300),
            .n100 = @intCast(score.n100),
            .n50 = @intCast(score.n50),
            .nmiss = @intCast(score.nmiss),
            .ngeki = @intCast(score.ngeki),
            .nkatu = @intCast(score.nkatu),
        },
    };
}

test "host evidence remains review only" {
    try std.testing.expect(stableLogin(0, true) == null);
    const hardware = stableLogin(1, false).?;
    try std.testing.expectEqual(abi.Action.audit, hardware.action);
    try std.testing.expectEqual(abi.Reason.exact_hardware_match, hardware.reason);
    try std.testing.expectEqual(abi.Evidence.exact_hardware_match, hardware.evidence);
    try std.testing.expect(hardware.decision_flags & abi.DecisionFlag.disconnect_session == 0);
    try std.testing.expect(hardware.decision_flags & abi.DecisionFlag.hold_score == 0);

    const flags = stableLastFm((@as(u32, 1) << 17) | (@as(u32, 1) << 19)).?;
    try std.testing.expectEqual(abi.Action.audit, flags.action);
    try std.testing.expectEqual(abi.Reason.high_confidence_client_flag, flags.reason);
    try std.testing.expectEqual(abi.Evidence.high_confidence_client_flag | abi.Evidence.registry_remnant, flags.evidence);
    try std.testing.expect(flags.risk_score <= 1000);
}

test "normalized login and client signals contain no identifying material" {
    const login = stableLoginSignal(200_000, true).?;
    try std.testing.expectEqual(abi.EventKind.login, login.event.event_kind);
    try std.testing.expectEqual(abi.ClientFamily.stable, login.event.client_family);
    try std.testing.expectEqual(@as(u32, 100_000), login.event.hardware_match_count);
    try std.testing.expectEqual(abi.Evidence.exact_hardware_match | abi.Evidence.running_under_wine, login.event.evidence);
    try std.testing.expectEqual(@as(u64, 0), login.event.score);
    try std.testing.expectEqual(@as(u32, 0), login.event.namespace);

    const client = stableLastFmSignal((@as(u32, 1) << 17) | (@as(u32, 1) << 19)).?;
    try std.testing.expectEqual(abi.EventKind.heartbeat, client.event.event_kind);
    try std.testing.expectEqual(abi.Evidence.high_confidence_client_flag | abi.Evidence.registry_remnant, client.event.evidence);
    try std.testing.expectEqual(@as(u32, 0), client.event.hardware_match_count);
    try std.testing.expect(stableLoginSignal(0, true) == null);
    try std.testing.expect(stableLastFmSignal(0) == null);
}

test "missing and invalid replays produce bounded review evidence" {
    const missing = stableReplay(.missing, 0);
    const invalid = stableReplay(.invalid_payload, 2);
    try std.testing.expectEqual(abi.Action.audit, missing.action);
    try std.testing.expectEqual(abi.Reason.required_replay_missing, missing.reason);
    try std.testing.expectEqual(abi.Reason.invalid_replay_payload, invalid.reason);
    try std.testing.expectEqual(abi.Evidence.replay_hash_reused, invalid.evidence);
    try std.testing.expectEqual(@as(u32, 2), invalid.replay_match_count);
    try std.testing.expect(missing.risk_score <= 1000 and invalid.risk_score <= 1000);
    try std.testing.expect(missing.decision_flags & (abi.DecisionFlag.hold_score | abi.DecisionFlag.disconnect_session | abi.DecisionFlag.notify_player) == 0);
}

test "rejected scores cross the module boundary as normalized evidence only" {
    const score: stable_score.Submission = .{
        .map_md5 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .username = "player",
        .online_checksum = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .n300 = 80,
        .n100 = 10,
        .n50 = 2,
        .ngeki = 0,
        .nkatu = 0,
        .nmiss = 1,
        .total_score = 123_456,
        .max_combo = 90,
        .perfect = false,
        .grade = "A",
        .mods = 0,
        .passed = true,
        .mode = 0,
        .client_time = "260826000000",
        .client_flags = "",
    };
    const missing = stableScoreSignal(score, .required_replay_missing);
    try std.testing.expectEqual(abi.EventKind.score, missing.event.event_kind);
    try std.testing.expectEqual(abi.EventFlag.passed | abi.EventFlag.replay_required, missing.event.event_flags);
    try std.testing.expectEqual(abi.Evidence.required_replay_missing, missing.event.evidence);
    try std.testing.expectEqual(abi.Reason.required_replay_missing, missing.fallback.reason);
    try std.testing.expectEqual(@as(u32, 80), missing.event.n300);

    const checksum = stableScoreSignal(score, .checksum_mismatch);
    try std.testing.expectEqual(abi.Evidence.checksum_mismatch, checksum.event.evidence);
    try std.testing.expectEqual(abi.Reason.checksum_mismatch, checksum.fallback.reason);
    try std.testing.expect(checksum.fallback.decision_flags & (abi.DecisionFlag.hold_score | abi.DecisionFlag.disconnect_session | abi.DecisionFlag.notify_player) == 0);
}
