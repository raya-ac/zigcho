const std = @import("std");
const abi = @import("anticheat_abi.zig");

const AbiVersionFn = *const fn () callconv(.c) u32;
const SizeFn = *const fn () callconv(.c) u32;
const NameFn = *const fn () callconv(.c) [*:0]const u8;
const EvaluateFn = *const fn (?*const abi.EventV1, ?*abi.DecisionV1) callconv(.c) u32;
const EvaluateGameplayFn = *const fn (?*const abi.GameplayEventV1, ?*abi.GameplayResultV1) callconv(.c) u32;

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
        const module_name = std.mem.span(name_fn());
        if (module_name.len == 0 or module_name.len > 64 or !std.unicode.utf8ValidateSlice(module_name)) return error.InvalidModuleName;
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
        var decision: abi.DecisionV1 = .{};
        if (self.evaluate_fn(&event, &decision) != abi.Status.ok) return error.ModuleRejectedEvent;
        try validateDecision(decision);
        return decision;
    }

    pub fn evaluateGameplay(self: Host, event: abi.GameplayEventV1) !abi.GameplayResultV1 {
        var result: abi.GameplayResultV1 = .{};
        if (self.evaluate_gameplay_fn(&event, &result) != abi.Status.ok) return error.ModuleRejectedEvent;
        if (result.abi_version != abi.version or result.struct_size != @sizeOf(abi.GameplayResultV1)) return error.InvalidDecision;
        try validateDecision(result.decision);
        if (result.objects_checked > event.object_count or result.matched_clicks > result.objects_checked or
            result.exact_timing_bps > 10_000 or result.center_hits_bps > 10_000 or result.snap_events > result.objects_checked) return error.InvalidDecision;
        return result;
    }
};

fn validateDecision(decision: abi.DecisionV1) !void {
    if (decision.abi_version != abi.version or decision.struct_size != @sizeOf(abi.DecisionV1) or
        decision.action > abi.Action.restrict or decision.risk_score > 1000 or decision.confidence_bps > 10_000) return error.InvalidDecision;
}
