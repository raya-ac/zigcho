const std = @import("std");
const domain = @import("../../../domain.zig");
const postgres = @import("../../../postgres.zig");
const Store = @import("../../../postgres_store.zig").Store;
const contracts = @import("../../contracts.zig");
const sql = @import("database_sql");

pub fn verify(conninfo: []const u8) !void {
    const allocator = std.testing.allocator;
    var store = try Store.open(allocator, std.testing.io, conninfo);
    defer store.close();
    try store.migrate();
    {
        var lease = store.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, sql.performance_fixture);
    }
    var requests: std.ArrayList(contracts.BanchoStatsRequest) = .empty;
    defer requests.deinit(allocator);
    for ([_]i32{ 3, 810001, 810002, 810003, 810004, 2147483647 }) |id| {
        for ([_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8 }) |mode| try requests.append(allocator, .{ .user_id = id, .mode = mode });
    }
    const batch = try store.banchoStatsBatch(allocator, requests.items);
    defer allocator.free(batch);
    for (requests.items, batch) |request, value| {
        const expected = contracts.BanchoStats.fromStats((try store.statsForUser(request.user_id, request.mode)) orelse domain.Stats{});
        try std.testing.expectEqualDeep(expected, value);
    }
    const empty = try store.banchoStatsBatch(allocator, &.{});
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    const repeated: [1030]contracts.BanchoStatsRequest = @splat(.{ .user_id = 810002, .mode = 4 });
    const chunks = try store.banchoStatsBatch(allocator, &repeated);
    defer allocator.free(chunks);
    const expected = contracts.BanchoStats.fromStats((try store.statsForUser(810002, 4)).?);
    for (chunks) |value| try std.testing.expectEqualDeep(expected, value);

    var lease = store.pool.acquire();
    defer lease.release();
    const queries = [_]struct { old: [:0]const u8, new: [:0]const u8 }{
        .{ .old = sql.profile_firsts_all_reference, .new = sql.profile_firsts_all },
        .{ .old = sql.profile_firsts_stable_reference, .new = sql.profile_firsts_stable },
        .{ .old = sql.profile_firsts_lazer_reference, .new = sql.profile_firsts_lazer },
    };
    for (queries, 0..) |query, source| {
        for ([_][]const u8{ "810001", "810002", "810003", "810004", "2147483647" }) |id| {
            for ([_][]const u8{ "vanilla", "relax", "autopilot", "scorev2" }) |namespace| {
                for ([_][]const u8{ "0", "3" }) |mode| {
                    var before = try postgres.queryParams(allocator, lease.conn, query.old, &.{ id, mode, namespace });
                    defer before.deinit();
                    var after = try postgres.queryParams(allocator, lease.conn, query.new, &.{ id, mode, namespace });
                    defer after.deinit();
                    try std.testing.expectEqual(before.rows(), after.rows());
                    try std.testing.expectEqual(before.columns(), after.columns());
                    for (0..before.rows()) |row| for (0..before.columns()) |column| {
                        try std.testing.expectEqual(before.isNull(row, column), after.isNull(row, column));
                        try std.testing.expectEqualStrings(before.value(row, column), after.value(row, column));
                    };
                    if (std.mem.eql(u8, id, "810001") and std.mem.eql(u8, mode, "0")) {
                        try std.testing.expectEqual(@as(usize, 20), after.rows());
                        try std.testing.expectEqual(@as(i64, if (source == 0) 32 else 48), try after.int(i64, 0, 22));
                    }
                }
            }
        }
    }
}
