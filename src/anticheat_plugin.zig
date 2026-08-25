const std = @import("std");
const abi = @import("anticheat_abi.zig");

const AbiVersionFn = *const fn () callconv(.c) u32;
const SizeFn = *const fn () callconv(.c) u32;
const NameFn = *const fn () callconv(.c) ?[*:0]const u8;
const EvaluateFn = *const fn (?*const abi.EventV1, ?*abi.DecisionV1) callconv(.c) u32;
const EvaluateGameplayFn = *const fn (?*const abi.GameplayEventV1, ?*abi.GameplayResultV1) callconv(.c) u32;

const max_match_count: u32 = 100_000;
const max_frames: u32 = 2_000_000;
const max_objects: u32 = 500_000;
const min_time_ms: i64 = -60_000;
const max_time_ms: i64 = 24 * 60 * 60 * 1000;
const max_coordinate: f32 = 131_072;
const replay_key_mask: u32 = 1 | 2 | 4 | 8 | 16;

fn allZero(values: anytype) bool {
    for (values) |value| if (value != 0) return false;
    return true;
}

fn validEventKind(value: u32) bool {
    return value == abi.EventKind.login or value == abi.EventKind.score or value == abi.EventKind.heartbeat;
}

fn validClientFamily(value: u32) bool {
    return value == abi.ClientFamily.stable or value == abi.ClientFamily.lazer;
}

fn validNamespace(value: u32) bool {
    return value >= abi.Namespace.vanilla and value <= abi.Namespace.custom;
}

fn validateEvent(event: abi.EventV1) !void {
    if (event.abi_version != abi.version or event.struct_size != @sizeOf(abi.EventV1) or
        !validEventKind(event.event_kind) or !validClientFamily(event.client_family) or event.ruleset > 3 or
        event.event_flags & ~abi.EventFlag.known_mask != 0 or event.evidence & ~abi.Evidence.known_mask != 0 or
        event.recent_risk_score > 1000 or event.hardware_match_count > max_match_count or event.replay_match_count > max_match_count or
        event.reserved32 != 0 or !allZero(event.reserved)) return error.InvalidEvent;
    if (event.event_kind == abi.EventKind.score) {
        if (!validNamespace(event.namespace)) return error.InvalidEvent;
    } else if (event.namespace != 0 and !validNamespace(event.namespace)) return error.InvalidEvent;
    if (event.event_flags & abi.EventFlag.replay_required != 0 and event.event_flags & abi.EventFlag.passed == 0) return error.InvalidEvent;
    const hardware_evidence = event.evidence & abi.Evidence.exact_hardware_match != 0;
    if (hardware_evidence != (event.hardware_match_count != 0)) return error.InvalidEvent;
    const replay_evidence = event.evidence & abi.Evidence.replay_hash_reused != 0;
    if (replay_evidence != (event.replay_match_count != 0)) return error.InvalidEvent;
    if (event.event_kind != abi.EventKind.score and (event.event_flags != 0 or event.replay_match_count != 0)) return error.InvalidEvent;
}

fn validObjectKind(kind: u32) bool {
    return kind == abi.HitObjectKind.circle or kind == abi.HitObjectKind.slider or kind == abi.HitObjectKind.spinner;
}

fn validateGameplayEvent(event: abi.GameplayEventV1) !void {
    if (event.abi_version != abi.version or event.struct_size != @sizeOf(abi.GameplayEventV1) or !allZero(event.reserved)) return error.InvalidEvent;
    try validateEvent(event.base);
    if (event.base.event_kind != abi.EventKind.score or event.base.ruleset != 0 or event.frame_count < 2 or event.frame_count > max_frames or
        event.object_count == 0 or event.object_count > max_objects or event.base.map_objects == 0 or
        (event.frame_count != 0 and event.frames == null) or (event.object_count != 0 and event.objects == null) or
        event.object_count > event.base.map_objects) return error.InvalidEvent;
    const judged_hits = @as(u64, event.base.n300) + event.base.n100 + event.base.n50;
    if (judged_hits > std.math.maxInt(u32) or event.passed_hits != judged_hits) return error.InvalidEvent;
    if (event.object_count != 0 and (event.hit_window_ms < 20 or event.hit_window_ms > 200)) return error.InvalidEvent;

    if (event.frames) |pointer| {
        const frames = pointer[0..@as(usize, @intCast(event.frame_count))];
        var previous_time = min_time_ms;
        for (frames) |frame| {
            if (frame.reserved != 0 or frame.time_ms < previous_time or frame.time_ms > max_time_ms or
                !std.math.isFinite(frame.x) or !std.math.isFinite(frame.y) or frame.x < -max_coordinate or frame.x > max_coordinate or
                frame.y < -max_coordinate or frame.y > max_coordinate or frame.keys & ~replay_key_mask != 0) return error.InvalidEvent;
            previous_time = frame.time_ms;
        }
    }
    if (event.objects) |pointer| {
        const objects = pointer[0..@as(usize, @intCast(event.object_count))];
        var previous_time: i64 = 0;
        for (objects) |object| {
            if (object.reserved != 0 or object.time_ms < previous_time or object.time_ms > max_time_ms or
                !std.math.isFinite(object.x) or !std.math.isFinite(object.y) or object.x < 0 or object.x > 512 or object.y < 0 or object.y > 384 or
                !validObjectKind(object.kind)) return error.InvalidEvent;
            previous_time = object.time_ms;
        }
        if (objects.len != 0 and event.base.map_duration_ms != 0 and objects[objects.len - 1].time_ms > event.base.map_duration_ms) return error.InvalidEvent;
    }
}

fn validateGameplayResult(event: abi.GameplayEventV1, result: abi.GameplayResultV1) !void {
    if (result.abi_version != abi.version or result.struct_size != @sizeOf(abi.GameplayResultV1) or !allZero(result.reserved)) return error.InvalidDecision;
    try validateDecision(result.decision);
    var expected_objects: u32 = 0;
    if (event.objects) |pointer| for (pointer[0..@as(usize, @intCast(event.object_count))]) |object| {
        if (object.kind == abi.HitObjectKind.circle or object.kind == abi.HitObjectKind.slider) expected_objects += 1;
    };
    const max_key_presses = @as(u64, if (event.frame_count == 0) 0 else event.frame_count - 1) * 2;
    if (result.objects_checked != expected_objects or result.matched_clicks > result.objects_checked or
        result.exact_timing_bps > 10_000 or result.center_hits_bps > 10_000 or result.snap_events > result.objects_checked or
        result.key_hold_count > result.key_press_count or result.key_press_count > max_key_presses or result.alternation_bps > 10_000 or
        result.velocity_spike_count > (if (event.frame_count == 0) 0 else event.frame_count - 1)) return error.InvalidDecision;
    if (result.matched_clicks == 0 and (result.mean_abs_timing_error_milli != 0 or result.timing_stddev_milli != 0 or result.exact_timing_bps != 0)) return error.InvalidDecision;
    if (result.objects_checked == 0 and (result.center_hits_bps != 0 or result.mean_center_distance_milli != 0 or result.snap_events != 0 or result.target_distance_stddev_milli != 0)) return error.InvalidDecision;
    if (result.key_press_count == 0 and (result.key_hold_count != 0 or result.mean_hold_duration_milli != 0 or result.hold_duration_stddev_milli != 0 or result.alternation_bps != 0)) return error.InvalidDecision;
}

pub const Host = struct {
    library: std.DynLib,
    module_name: []const u8,
    evaluate_fn: EvaluateFn,
    evaluate_gameplay_fn: EvaluateGameplayFn,

    pub fn open(path: []const u8) !Host {
        if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidModulePath;
        var library = try std.DynLib.open(path);
        errdefer library.close();
        const abi_version = library.lookup(AbiVersionFn, "zigcho_anticheat_abi_version") orelse return error.MissingAbiVersion;
        const event_size = library.lookup(SizeFn, "zigcho_anticheat_event_size_v1") orelse return error.MissingEventSize;
        const decision_size = library.lookup(SizeFn, "zigcho_anticheat_decision_size_v1") orelse return error.MissingDecisionSize;
        const gameplay_event_size = library.lookup(SizeFn, "zigcho_anticheat_gameplay_event_size_v1") orelse return error.MissingGameplayEventSize;
        const gameplay_result_size = library.lookup(SizeFn, "zigcho_anticheat_gameplay_result_size_v1") orelse return error.MissingGameplayResultSize;
        const name_fn = library.lookup(NameFn, "zigcho_anticheat_name") orelse return error.MissingName;
        const evaluate_fn = library.lookup(EvaluateFn, "zigcho_anticheat_evaluate_v1") orelse return error.MissingEvaluator;
        const evaluate_gameplay_fn = library.lookup(EvaluateGameplayFn, "zigcho_anticheat_evaluate_gameplay_v1") orelse return error.MissingGameplayEvaluator;

        if (abi_version() != abi.version) return error.UnsupportedAbi;
        if (event_size() != @sizeOf(abi.EventV1) or decision_size() != @sizeOf(abi.DecisionV1) or
            gameplay_event_size() != @sizeOf(abi.GameplayEventV1) or gameplay_result_size() != @sizeOf(abi.GameplayResultV1)) return error.LayoutMismatch;
        const module_name_pointer = name_fn() orelse return error.InvalidModuleName;
        const bounded_name = module_name_pointer[0..65];
        const module_name_end = std.mem.indexOfScalar(u8, bounded_name, 0) orelse return error.InvalidModuleName;
        const module_name = bounded_name[0..module_name_end];
        if (module_name.len == 0 or !std.unicode.utf8ValidateSlice(module_name)) return error.InvalidModuleName;
        return .{
            .library = library,
            .module_name = module_name,
            .evaluate_fn = evaluate_fn,
            .evaluate_gameplay_fn = evaluate_gameplay_fn,
        };
    }

    pub fn close(self: *Host) void {
        self.library.close();
        self.* = undefined;
    }

    pub fn name(self: Host) []const u8 {
        return self.module_name;
    }

    pub fn evaluate(self: Host, event: abi.EventV1) !abi.DecisionV1 {
        try validateEvent(event);
        var decision: abi.DecisionV1 = .{};
        if (self.evaluate_fn(&event, &decision) != abi.Status.ok) return error.ModuleRejectedEvent;
        try validateDecision(decision);
        return decision;
    }

    pub fn evaluateGameplay(self: Host, event: abi.GameplayEventV1) !abi.GameplayResultV1 {
        try validateGameplayEvent(event);
        var result: abi.GameplayResultV1 = .{};
        if (self.evaluate_gameplay_fn(&event, &result) != abi.Status.ok) return error.ModuleRejectedEvent;
        try validateGameplayResult(event, result);
        return result;
    }
};

fn validateDecision(decision: abi.DecisionV1) !void {
    if (decision.abi_version != abi.version or decision.struct_size != @sizeOf(abi.DecisionV1) or
        decision.action > abi.Action.restrict or decision.risk_score > 1000 or decision.confidence_bps > 10_000 or
        decision.flags & ~abi.DecisionFlag.known_mask != 0 or decision.reserved32 != 0 or !allZero(decision.reserved)) return error.InvalidDecision;
}

test "anticheat host rejects contradictory or unbounded evidence" {
    try validateEvent(.{ .event_kind = abi.EventKind.login, .client_family = abi.ClientFamily.stable });
    try validateEvent(.{ .event_kind = abi.EventKind.score, .client_family = abi.ClientFamily.lazer, .namespace = abi.Namespace.custom });
    try std.testing.expectError(error.InvalidEvent, validateEvent(.{ .event_kind = abi.EventKind.login, .client_family = abi.ClientFamily.stable, .evidence = abi.Evidence.exact_hardware_match }));
    try std.testing.expectError(error.InvalidEvent, validateEvent(.{ .event_kind = abi.EventKind.score, .client_family = abi.ClientFamily.stable, .namespace = abi.Namespace.vanilla, .replay_match_count = 1 }));
    try std.testing.expectError(error.InvalidEvent, validateEvent(.{ .event_kind = abi.EventKind.score, .client_family = abi.ClientFamily.stable, .namespace = abi.Namespace.vanilla, .event_flags = 1 << 63 }));
    try std.testing.expectError(error.InvalidDecision, validateDecision(.{ .flags = 1 << 63 }));
}

test "anticheat host verifies replay input and module metric consistency" {
    const frames = [_]abi.ReplayFrameV1{
        .{ .time_ms = 0, .x = 128, .y = 96, .keys = 0 },
        .{ .time_ms = 1000, .x = 256, .y = 192, .keys = 4 },
    };
    const objects = [_]abi.HitObjectV1{
        .{ .time_ms = 1000, .x = 256, .y = 192, .kind = abi.HitObjectKind.circle },
        .{ .time_ms = 1500, .x = 256, .y = 192, .kind = abi.HitObjectKind.spinner },
    };
    const event: abi.GameplayEventV1 = .{
        .base = .{
            .event_kind = abi.EventKind.score,
            .client_family = abi.ClientFamily.stable,
            .namespace = abi.Namespace.vanilla,
            .n300 = 1,
            .map_objects = 2,
            .map_duration_ms = 1500,
        },
        .passed_hits = 1,
        .hit_window_ms = 150,
        .frames = &frames,
        .frame_count = frames.len,
        .objects = &objects,
        .object_count = objects.len,
    };
    try validateGameplayEvent(event);
    try validateGameplayResult(event, .{ .objects_checked = 1, .matched_clicks = 1, .key_press_count = 1 });
    try std.testing.expectError(error.InvalidDecision, validateGameplayResult(event, .{ .objects_checked = 2 }));
    var corrupt = event;
    var bad_frames = frames;
    bad_frames[1].keys = 1 << 31;
    corrupt.frames = &bad_frames;
    try std.testing.expectError(error.InvalidEvent, validateGameplayEvent(corrupt));
}
