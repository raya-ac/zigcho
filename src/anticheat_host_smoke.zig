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
    std.debug.print("module={s} abi={d} action={d} login_action={d} gameplay_action={d} reason={d} objects={d} clicks={d} exact_bps={d} center_bps={d}\n", .{
        host.name(), abi.version, decision.action, login_decision.action, gameplay.decision.action, gameplay.decision.reason, gameplay.objects_checked, gameplay.matched_clicks, gameplay.exact_timing_bps, gameplay.center_hits_bps,
    });
}
