const std = @import("std");
const abi = @import("anticheat_abi.zig");

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

pub const ReplayIssue = enum {
    missing,
    invalid_payload,
};

pub fn stableLogin(hardware_match_count: u32, running_under_wine: bool) ?Observation {
    if (hardware_match_count == 0) return null;
    const bounded_matches: u32 = @min(hardware_match_count, 10);
    return .{
        .reason = abi.Reason.exact_hardware_match,
        .risk_score = 225 + bounded_matches * @as(u32, 25),
        .evidence = abi.Evidence.exact_hardware_match | (if (running_under_wine) abi.Evidence.running_under_wine else 0),
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
