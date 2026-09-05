const std = @import("std");
const achievements = @import("../../../achievements.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;

pub fn awardAchievementsLocked(self: *Store, user_id: i32, source: []const u8, score_id: i64, input: achievements.Input) !void {
    var enriched = input;
    if (input.eligible) {
        var stats: ?*c.sqlite3_stmt = null;
        const stats_sql = "SELECT s.plays,s.total_hits,CASE WHEN s.pp>0 THEN (SELECT count(*)+1 FROM stats r JOIN users u ON u.id=r.user_id WHERE r.mode=s.mode AND u.id!=3 AND u.restricted=0 AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) ELSE 0 END FROM stats s WHERE s.user_id=?1 AND s.mode=?2";
        if (c.sqlite3_prepare_v2(self.db, stats_sql, -1, &stats, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stats);
        _ = c.sqlite3_bind_int(stats, 1, user_id);
        _ = c.sqlite3_bind_int(stats, 2, input.mode);
        if (c.sqlite3_step(stats) == c.SQLITE_ROW) {
            enriched.plays = c.sqlite3_column_int64(stats, 0);
            enriched.total_hits = c.sqlite3_column_int64(stats, 1);
            enriched.global_rank = c.sqlite3_column_int64(stats, 2);
        }
    }
    const candidates = achievements.candidates(enriched);
    if (candidates.len == 0) return;
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "INSERT OR IGNORE INTO user_achievements(user_id,achievement_id,score_source,score_id) SELECT ?1,?2,?3,?4 WHERE EXISTS(SELECT 1 FROM users WHERE id=?1 AND restricted=0)";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    for (candidates.slice()) |achievement_id| {
        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_int(stmt, 2, achievement_id);
        _ = c.sqlite3_bind_text(stmt, 3, source.ptr, @intCast(source.len), null);
        _ = c.sqlite3_bind_int64(stmt, 4, score_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }
}

pub fn writeUserAchievementsLocked(self: *Store, writer: *std.Io.Writer, user_id: i32, include_metadata: bool) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT ua.achievement_id,strftime('%Y-%m-%dT%H:%M:%SZ',ua.achieved_at,'unixepoch'),(SELECT count(*) FROM user_achievements all_ua JOIN users all_users ON all_users.id=all_ua.user_id WHERE all_ua.achievement_id=ua.achievement_id AND all_users.restricted=0),(SELECT count(*) FROM users WHERE restricted=0) FROM user_achievements ua WHERE ua.user_id=?1 ORDER BY ua.achieved_at DESC,ua.achievement_id DESC";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    try writer.writeByte('[');
    var first = true;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const id: u16 = @intCast(c.sqlite3_column_int(stmt, 0));
        if (achievements.byId(id) == null) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try achievements.writeJson(writer, id, std.mem.span(c.sqlite3_column_text(stmt, 1)), c.sqlite3_column_int64(stmt, 2), c.sqlite3_column_int64(stmt, 3), include_metadata);
    }
    try writer.writeByte(']');
}

pub fn lazerUserAchievementsJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try self.writeUserAchievementsLocked(&output.writer, user_id, true);
    return output.toOwnedSlice();
}

pub fn newAchievementsForScore(self: *Store, source: []const u8, score_id: i64) !achievements.Unlocks {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT achievement_id FROM user_achievements WHERE score_source=?1 AND score_id=?2 ORDER BY achievement_id", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, source.ptr, @intCast(source.len), null);
    _ = c.sqlite3_bind_int64(stmt, 2, score_id);
    var result: achievements.Unlocks = .{};
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) result.append(@intCast(c.sqlite3_column_int(stmt, 0)));
    return result;
}
