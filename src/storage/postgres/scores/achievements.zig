const std = @import("std");
const postgres = @import("../../../postgres.zig");
const achievements = @import("../../../achievements.zig");

pub fn awardAchievementsWithConnection(self: anytype, conn: *postgres.c.PGconn, user_id: i32, source: []const u8, score_id: i64, input: achievements.Input) !void {
    var user_buf: [24]u8 = undefined;
    var mode_buf: [4]u8 = undefined;
    var score_buf: [32]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const mode = try std.fmt.bufPrint(&mode_buf, "{d}", .{input.mode});
    const score = try std.fmt.bufPrint(&score_buf, "{d}", .{score_id});
    var enriched = input;
    if (input.eligible) {
        var stats = try postgres.queryParams(self.allocator, conn, "SELECT s.plays,s.total_hits,CASE WHEN s.pp>0 THEN (SELECT count(*)+1 FROM zigcho.stats r JOIN zigcho.users u ON u.id=r.user_id WHERE r.mode=s.mode AND u.id!=3 AND NOT u.restricted AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) ELSE 0 END FROM zigcho.stats s WHERE s.user_id=$1 AND s.mode=$2", &.{ user, mode });
        defer stats.deinit();
        if (stats.rows() != 0) {
            enriched.plays = try stats.int(i64, 0, 0);
            enriched.total_hits = try stats.int(i64, 0, 1);
            enriched.global_rank = try stats.int(i64, 0, 2);
        }
    }
    const candidates = achievements.candidates(enriched);
    if (candidates.len == 0) return;
    for (candidates.slice()) |achievement_id| {
        var achievement_buf: [8]u8 = undefined;
        const achievement = try std.fmt.bufPrint(&achievement_buf, "{d}", .{achievement_id});
        var inserted = try postgres.queryParams(self.allocator, conn, "INSERT INTO zigcho.user_achievements(user_id,achievement_id,score_source,score_id) SELECT $1,$2,$3,$4 WHERE EXISTS(SELECT 1 FROM zigcho.users WHERE id=$1 AND NOT restricted) ON CONFLICT DO NOTHING", &.{ user, achievement, source, score });
        inserted.deinit();
    }
}

pub fn writeUserAchievementsWithConnection(_: anytype, allocator: std.mem.Allocator, conn: *postgres.c.PGconn, writer: *std.Io.Writer, user_id: i32, include_metadata: bool) !void {
    var user_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    var result = try postgres.queryParams(allocator, conn, "SELECT ua.achievement_id,to_char(to_timestamp(ua.achieved_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),(SELECT count(*) FROM zigcho.user_achievements all_ua JOIN zigcho.users all_users ON all_users.id=all_ua.user_id WHERE all_ua.achievement_id=ua.achievement_id AND NOT all_users.restricted),(SELECT count(*) FROM zigcho.users WHERE NOT restricted) FROM zigcho.user_achievements ua WHERE ua.user_id=$1 ORDER BY ua.achieved_at DESC,ua.achievement_id DESC", &.{user});
    defer result.deinit();
    try writer.writeByte('[');
    var first = true;
    for (0..result.rows()) |row| {
        const id = try result.int(u16, row, 0);
        if (achievements.byId(id) == null) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try achievements.writeJson(writer, id, result.value(row, 1), try result.int(i64, row, 2), try result.int(i64, row, 3), include_metadata);
    }
    try writer.writeByte(']');
}

pub fn lazerUserAchievementsJson(self: anytype, allocator: std.mem.Allocator, user_id: i32) ![]u8 {
    var lease = self.pool.acquire();
    defer lease.release();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try writeUserAchievementsWithConnection(self, allocator, lease.conn, &output.writer, user_id, true);
    return output.toOwnedSlice();
}

pub fn newAchievementsForScore(self: anytype, source: []const u8, score_id: i64) !achievements.Unlocks {
    var score_buf: [32]u8 = undefined;
    const score = try std.fmt.bufPrint(&score_buf, "{d}", .{score_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var rows = try postgres.queryParams(self.allocator, lease.conn, "SELECT achievement_id FROM zigcho.user_achievements WHERE score_source=$1 AND score_id=$2 ORDER BY achievement_id", &.{ source, score });
    defer rows.deinit();
    var result: achievements.Unlocks = .{};
    for (0..rows.rows()) |row| result.append(try rows.int(u16, row, 0));
    return result;
}
