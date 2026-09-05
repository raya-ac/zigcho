const std = @import("std");
pub const clock = @import("telemetry/clock.zig");
pub const histogram = @import("telemetry/histogram.zig");
pub const work = @import("telemetry/work.zig");
pub const Mutex = @import("telemetry/mutex.zig").Measured;

// No raw routes, account IDs, query text, object keys or request values may be
// used as labels. Adding a metric requires adding a compile-time enum member.
pub const Operation = enum {
    stable_login,
    stable_poll,
    stable_score,
    stable_web,
    lazer_score,
    lazer_api,
    website_read,
    website_write,
    authentication,
    media,
    metrics,
    other,
    realtime_session,
    postgres_query,
    postgres_pool_acquire,
    postgres_pool_wait,
    stable_sessions_wait,
    stable_sessions_hold,
    lazer_state_wait,
    lazer_state_hold,
    pp_stable,
    pp_lazer,
    replay_analysis,
    replay_archive,
    object_upload,
    object_download,
};

var durations: [std.meta.fields(Operation).len]histogram.Histogram = @splat(.{});

pub fn observe(operation: Operation, nanoseconds: u64) void {
    durations[@intFromEnum(operation)].observe(nanoseconds);
}

pub const Timer = struct {
    operation: Operation,
    started: u64,

    pub fn start(operation: Operation) Timer {
        return .{ .operation = operation, .started = clock.now() };
    }

    pub fn finish(self: Timer) void {
        if (clock.elapsed(self.started)) |duration| observe(self.operation, duration);
    }
};

pub fn route(method: std.http.Method, path: []const u8, stable_client: bool, stable_token: bool) Operation {
    if (std.mem.eql(u8, path, "/metrics") or std.mem.eql(u8, path, "/metrics/runtime")) return .metrics;
    if (std.mem.eql(u8, path, "/multiplayer") or std.mem.eql(u8, path, "/spectator") or std.mem.eql(u8, path, "/notification-endpoint")) return .realtime_session;
    if (std.mem.eql(u8, path, "/") and method == .POST and stable_client) return if (stable_token) .stable_poll else .stable_login;
    if (std.mem.eql(u8, path, "/web/osu-submit-modular-selector.php")) return .stable_score;
    if (std.mem.startsWith(u8, path, "/web/")) return .stable_web;
    if (std.mem.startsWith(u8, path, "/oauth/") or std.mem.eql(u8, path, "/users") or std.mem.eql(u8, path, "/api/v1/session")) return .authentication;
    if (std.mem.startsWith(u8, path, "/api/v2/") and method != .GET and
        (std.mem.indexOf(u8, path, "/scores") != null)) return .lazer_score;
    if (std.mem.startsWith(u8, path, "/api/v2/")) return .lazer_api;
    if (std.mem.startsWith(u8, path, "/d/") or std.mem.startsWith(u8, path, "/assets/") or std.mem.endsWith(u8, path, "/download")) return .media;
    if (std.mem.startsWith(u8, path, "/api/v1/") or method == .GET or method == .HEAD) return if (method == .GET or method == .HEAD) .website_read else .website_write;
    return .other;
}

pub fn writePrometheus(writer: *std.Io.Writer) !void {
    try writer.writeAll("# HELP zigcho_duration_seconds Monotonic wall duration by bounded operation; realtime_session is connection lifetime, not request latency.\n# TYPE zigcho_duration_seconds histogram\n");
    inline for (std.meta.fields(Operation)) |field| {
        const snapshot = durations[field.value].snapshot();
        var cumulative: u64 = 0;
        for (snapshot.buckets, 0..) |count, index| {
            cumulative +|= count;
            try writer.print("zigcho_duration_seconds_bucket{{operation=\"{s}\",le=\"", .{field.name});
            if (index < histogram.bounds.len) try writer.print("{d}", .{@as(f64, @floatFromInt(histogram.bounds[index])) / 1_000_000}) else try writer.writeAll("+Inf");
            try writer.print("\"}} {d}\n", .{cumulative});
        }
        try writer.print("zigcho_duration_seconds_count{{operation=\"{s}\"}} {d}\nzigcho_duration_seconds_sum{{operation=\"{s}\"}} {d}\n", .{ field.name, snapshot.count(), field.name, @as(f64, @floatFromInt(snapshot.sum_us)) / 1_000_000 });
    }
    try writer.writeAll("# HELP zigcho_duration_quantile_seconds Process-lifetime bucket upper bound; use histogram deltas for a measurement window.\n# TYPE zigcho_duration_quantile_seconds gauge\n");
    inline for (std.meta.fields(Operation)) |field| {
        const snapshot = durations[field.value].snapshot();
        for ([_]u8{ 50, 95, 99 }) |percentile| {
            try writer.print("zigcho_duration_quantile_seconds{{operation=\"{s}\",quantile=\"{d}\"}} ", .{ field.name, @as(f64, @floatFromInt(percentile)) / 100 });
            if (snapshot.percentile(percentile)) |value| try writer.print("{d}\n", .{@as(f64, @floatFromInt(value)) / 1_000_000}) else try writer.writeAll("+Inf\n");
        }
    }
    try work.writePrometheus(writer);
}

test "route metrics collapse IDs and never use request values as labels" {
    try std.testing.expectEqual(Operation.stable_score, route(.POST, "/web/osu-submit-modular-selector.php", true, true));
    try std.testing.expectEqual(Operation.lazer_score, route(.PUT, "/api/v2/beatmaps/999/solo/scores/123", false, false));
    try std.testing.expectEqual(Operation.lazer_api, route(.GET, "/api/v2/beatmaps/999/scores", false, false));
    try std.testing.expectEqual(Operation.stable_poll, route(.POST, "/", true, true));
    try std.testing.expectEqual(Operation.stable_login, route(.POST, "/", true, false));
    _ = histogram;
}

test "runtime metrics export stays bounded and includes latency and queue series" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writePrometheus(&output.writer);
    try std.testing.expect(output.written().len < 128 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "zigcho_duration_seconds_bucket{operation=\"stable_score\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "zigcho_work_oldest_seconds{queue=\"postgres_pool\"") != null);
}
