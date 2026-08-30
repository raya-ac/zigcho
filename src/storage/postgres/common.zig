const std = @import("std");
const domain = @import("../../domain.zig");
const postgres = @import("../../postgres.zig");

pub const RegistrationConflicts = struct { username: bool, email: bool };
pub const ServerCounts = struct { users: i64, plays: i64, passed: i64, maps: i64 };
pub const BeatmapCacheStats = struct { entries: i64, bytes: i64, hydration_failures: i64 };
pub const BeatmapCachePrune = struct { entries: i64, bytes: i64 };
pub const BeatmapMediaCacheStats = struct { entries: i64, bytes: i64 };
pub const schema_version: u16 = 47;
pub const archive_object_limit: usize = 128 * 1024 * 1024;
pub const max_replay_object_bytes: usize = 32 * 1024 * 1024;
pub const visible_follower_count_sql = "CASE WHEN NOT u.restricted AND u.id!=3 THEN (SELECT count(*) FROM zigcho.friends relation JOIN zigcho.users follower ON follower.id=relation.user_id WHERE relation.friend_id=u.id AND relation.user_id!=u.id AND NOT follower.restricted) ELSE 0 END";

pub fn param(buffers: anytype, cursor: *usize, value: anytype) ![]u8 {
    if (cursor.* == buffers.len) return error.ParameterBufferExhausted;
    const index = cursor.*;
    cursor.* += 1;
    return std.fmt.bufPrint(&buffers[index], "{d}", .{value});
}

pub fn userFromResult(allocator: std.mem.Allocator, result: postgres.Result, row: usize) !domain.User {
    const name = try allocator.dupe(u8, result.value(row, 1));
    errdefer allocator.free(name);
    const safe_name = try allocator.dupe(u8, result.value(row, 2));
    errdefer allocator.free(safe_name);
    const country = result.value(row, 3);
    if (country.len != 2) return error.InvalidCountry;
    const team: ?domain.TeamSummary = if (result.isNull(row, 8)) null else try domain.TeamSummary.init(try result.int(i32, row, 8), result.value(row, 9), result.value(row, 10), try result.int(i64, row, 11));
    return .{
        .id = try result.int(i32, row, 0),
        .name = name,
        .safe_name = safe_name,
        .country = .{ country[0], country[1] },
        .show_country = try result.boolean(row, 12),
        .privileges = try result.int(u32, row, 4),
        .silence_end = try result.int(i64, row, 5),
        .restricted = try result.boolean(row, 6),
        .follower_count = try result.int(i32, row, 13),
        .banner_version = try result.int(i64, row, 7),
        .team = team,
    };
}

pub fn insertAudit(allocator: std.mem.Allocator, conn: *postgres.c.PGconn, actor_id: i32, action: []const u8, target_user_id: i32, detail: []const u8) !void {
    var actor_buf: [24]u8 = undefined;
    var target_buf: [24]u8 = undefined;
    const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
    const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{target_user_id});
    var result = try postgres.queryParams(allocator, conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) VALUES($1,$2,$3,$4)", &.{ actor, action, target, detail });
    result.deinit();
}

pub fn jsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}
