const std = @import("std");
const Gate = @import("../../http_boundary.zig").Gate;

pub const Result = struct { lon: f32 = 0, lat: f32 = 0 };
pub const max_concurrent = 4;
pub const timeout_ms = 1000;

pub fn lookup(self: anytype, ip: []const u8) Result {
    _ = std.Io.net.IpAddress.parse(ip, 0) catch return .{};
    return lookupBounded(self, ip, timeout_ms);
}

fn lookupBounded(self: anytype, ip: []const u8, deadline_ms: u32) Result {
    if (!self.geo_gate.tryAcquire()) return .{};
    defer self.geo_gate.release();
    const Completion = union(enum) { response: Result, deadline: std.Io.Cancelable!void };
    var buffer: [2]Completion = undefined;
    var selected: std.Io.Select(Completion) = .init(self.store.io, &buffer);
    defer selected.cancelDiscard();
    const Fetch = struct {
        fn run(app: @TypeOf(self), address: []const u8) Result {
            return fetch(app, address);
        }
    };
    selected.concurrent(.deadline, std.Io.sleep, .{ self.store.io, .fromMilliseconds(deadline_ms), .awake }) catch return .{};
    selected.concurrent(.response, Fetch.run, .{ self, ip }) catch return .{};
    const completed = selected.await() catch return .{};
    return switch (completed) {
        .response => |result| result,
        .deadline => blk: {
            self.geo_gate.recordTimeout();
            break :blk .{};
        },
    };
}

fn fetch(self: anytype, ip: []const u8) Result {
    const url = std.fmt.allocPrint(self.allocator, "http://ip-api.com/line/{s}?fields=status,lat,lon", .{ip}) catch return .{};
    defer self.allocator.free(url);
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const response = self.geo_client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer,
        .headers = .{ .user_agent = .{ .override = "zigcho/0.1" } },
    }) catch return .{};
    if (response.status != .ok) return .{};
    return parse(writer.buffered());
}

fn parse(bytes: []const u8) Result {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (!std.mem.eql(u8, std.mem.trim(u8, lines.next() orelse "", "\r "), "success")) return .{};
    const lat = std.fmt.parseFloat(f32, std.mem.trim(u8, lines.next() orelse return .{}, "\r ")) catch return .{};
    const lon = std.fmt.parseFloat(f32, std.mem.trim(u8, lines.next() orelse return .{}, "\r ")) catch return .{};
    if (!std.math.isFinite(lat) or !std.math.isFinite(lon) or @abs(lat) > 90 or @abs(lon) > 180) return .{};
    return .{ .lat = lat, .lon = lon };
}

test "geolocation bounds coordinates and ignores failed responses" {
    try std.testing.expectEqualDeep(Result{ .lat = -34.9, .lon = 138.6 }, parse("success\n-34.9\n138.6\n"));
    for ([_][]const u8{ "fail\n", "success\nNaN\n0", "success\n0\ninf", "success\n91\n0", "success\n0\n181", "success\n0" }) |body|
        try std.testing.expectEqualDeep(Result{}, parse(body));
}

test "geolocation cancels slow requests and rejects excess work without queuing" {
    const FakeClient = struct {
        io: std.Io,
        called: std.atomic.Value(u32) = .init(0),
        fn fetch(client: *@This(), _: std.http.Client.FetchOptions) !struct { status: std.http.Status } {
            _ = client.called.fetchAdd(1, .monotonic);
            try std.Io.sleep(client.io, .fromSeconds(10), .awake);
            return .{ .status = .service_unavailable };
        }
    };
    const Context = struct {
        allocator: std.mem.Allocator,
        store: struct { io: std.Io },
        geo_client: FakeClient,
        geo_gate: Gate,
    };
    var context: Context = .{
        .allocator = std.testing.allocator,
        .store = .{ .io = std.testing.io },
        .geo_client = FakeClient{ .io = std.testing.io },
        .geo_gate = Gate.init(max_concurrent),
    };
    const start = std.Io.Clock.awake.now(std.testing.io);
    try std.testing.expectEqualDeep(Result{}, lookupBounded(&context, "127.0.0.1", 20));
    try std.testing.expect(start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toMilliseconds() < 2000);
    try std.testing.expectEqual(@as(u32, 0), context.geo_gate.active.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), context.geo_gate.timed_out.load(.acquire));
    context.geo_gate.active.store(max_concurrent, .release);
    const called = context.geo_client.called.load(.acquire);
    try std.testing.expectEqualDeep(Result{}, lookup(&context, "127.0.0.1"));
    try std.testing.expectEqual(called, context.geo_client.called.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), context.geo_gate.rejected.load(.acquire));
    context.geo_gate.active.store(0, .release);
    try std.testing.expectEqualDeep(Result{}, lookup(&context, "127.0.0.1/other"));
    try std.testing.expectEqual(called, context.geo_client.called.load(.acquire));
}
