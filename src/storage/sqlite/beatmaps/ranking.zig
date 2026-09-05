const std = @import("std");
const domain = @import("../../../domain.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;

pub fn beatmapRankContext(self: *Store, map_md5: []const u8) !?domain.BeatmapRankContext {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT b.id,b.set_id,b.status,(SELECT count(*) FROM beatmap_rank_requests r WHERE r.set_id=b.set_id AND r.active=1),(SELECT count(*) FROM beatmap_nominations n WHERE n.set_id=b.set_id AND n.active=1) FROM beatmaps b WHERE b.md5=?1";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, map_md5.ptr, @intCast(map_md5.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return .{
        .map_id = c.sqlite3_column_int(stmt, 0),
        .set_id = c.sqlite3_column_int(stmt, 1),
        .status = @intCast(c.sqlite3_column_int(stmt, 2)),
        .requests = @intCast(c.sqlite3_column_int(stmt, 3)),
        .nominations = @intCast(c.sqlite3_column_int(stmt, 4)),
    };
}

pub fn requestBeatmapRank(self: *Store, requester_id: i32, map_md5: []const u8) !domain.BeatmapRankContext {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var map_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT id,set_id,status FROM beatmaps WHERE md5=?1", -1, &map_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(map_stmt);
    _ = c.sqlite3_bind_text(map_stmt, 1, map_md5.ptr, @intCast(map_md5.len), null);
    if (c.sqlite3_step(map_stmt) != c.SQLITE_ROW) return error.BeatmapNotFound;
    const map_id = c.sqlite3_column_int(map_stmt, 0);
    const set_id = c.sqlite3_column_int(map_stmt, 1);
    const status: i8 = @intCast(c.sqlite3_column_int(map_stmt, 2));
    if (status != @intFromEnum(domain.RankedStatus.pending)) return error.BeatmapNotPending;

    var insert: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO beatmap_rank_requests(set_id,map_id,requester_id) VALUES(?1,?2,?3)", -1, &insert, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(insert);
    _ = c.sqlite3_bind_int(insert, 1, set_id);
    _ = c.sqlite3_bind_int(insert, 2, map_id);
    _ = c.sqlite3_bind_int(insert, 3, requester_id);
    if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    if (c.sqlite3_changes(self.db) == 0) return error.BeatmapAlreadyRequested;
    try self.insertBeatmapRankEventLocked(set_id, requester_id, "request", status, status, "player request");
    try self.exec("COMMIT");
    return .{ .map_id = map_id, .set_id = set_id, .status = status, .requests = try self.activeRankCountLocked("beatmap_rank_requests", set_id), .nominations = try self.activeRankCountLocked("beatmap_nominations", set_id) };
}

pub fn nominateBeatmapSet(self: *Store, actor_id: i32, map_md5: []const u8, reason: []const u8) !domain.BeatmapRankContext {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    const context = try self.rankContextLocked(map_md5);
    if (context.status != @intFromEnum(domain.RankedStatus.pending)) return error.BeatmapNotPending;
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "INSERT INTO beatmap_nominations(set_id,nominator_id,active) VALUES(?1,?2,1) ON CONFLICT(set_id,nominator_id) DO UPDATE SET active=1,updated_at=unixepoch() WHERE beatmap_nominations.active=0";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, context.set_id);
    _ = c.sqlite3_bind_int(stmt, 2, actor_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    if (c.sqlite3_changes(self.db) == 0) return error.BeatmapAlreadyNominated;
    try self.insertBeatmapRankEventLocked(context.set_id, actor_id, "nominate", context.status, context.status, reason);
    try self.exec("COMMIT");
    var result = context;
    result.nominations = try self.activeRankCountLocked("beatmap_nominations", context.set_id);
    return result;
}

pub fn applyBeatmapRankAction(self: *Store, actor_id: i32, map_md5: []const u8, action: domain.BeatmapRankAction, reason: []const u8) !domain.BeatmapRankContext {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var context = try self.rankContextLocked(map_md5);
    const current = context.status;
    var target: i8 = current;
    const action_name: []const u8 = switch (action) {
        .pending => "pending",
        .qualify => "qualify",
        .rank => "rank",
        .approve => "approve",
        .love => "love",
        .veto => "veto",
        .rollback => "rollback",
    };
    switch (action) {
        .pending, .veto => target = @intFromEnum(domain.RankedStatus.pending),
        .qualify => target = @intFromEnum(domain.RankedStatus.qualified),
        .rank => target = @intFromEnum(domain.RankedStatus.ranked),
        .approve => target = @intFromEnum(domain.RankedStatus.approved),
        .love => target = @intFromEnum(domain.RankedStatus.loved),
        .rollback => {
            var previous: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT from_status FROM beatmap_rank_events WHERE set_id=?1 AND from_status!=to_status ORDER BY id DESC LIMIT 1", -1, &previous, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(previous);
            _ = c.sqlite3_bind_int(previous, 1, context.set_id);
            if (c.sqlite3_step(previous) != c.SQLITE_ROW) return error.NothingToRollback;
            target = @intCast(c.sqlite3_column_int(previous, 0));
        },
    }
    var update: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmaps SET status=?1,status_frozen=1,last_update=unixepoch() WHERE set_id=?2", -1, &update, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(update);
    _ = c.sqlite3_bind_int(update, 1, target);
    _ = c.sqlite3_bind_int(update, 2, context.set_id);
    if (c.sqlite3_step(update) != c.SQLITE_DONE or c.sqlite3_changes(self.db) == 0) return error.BeatmapNotFound;
    if (action != .qualify) try self.clearBeatmapNominationsLocked(context.set_id);
    if (action == .rank or action == .approve or action == .love) try self.resolveBeatmapRequestsLocked(context.set_id);
    try self.rebuildScoreStats(false);
    try self.recordAllStatsHistoryCurrentLocked();
    try self.insertBeatmapRankEventLocked(context.set_id, actor_id, action_name, current, target, reason);
    try self.exec("COMMIT");
    context.status = target;
    context.requests = try self.activeRankCountLocked("beatmap_rank_requests", context.set_id);
    context.nominations = try self.activeRankCountLocked("beatmap_nominations", context.set_id);
    return context;
}

pub fn beatmapRankQueue(self: *Store, allocator: std.mem.Allocator) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT r.set_id,count(*),min(r.created_at),min(b.artist),min(b.title),(SELECT count(*) FROM beatmap_nominations n WHERE n.set_id=r.set_id AND n.active=1) FROM beatmap_rank_requests r JOIN beatmaps b ON b.set_id=r.set_id WHERE r.active=1 GROUP BY r.set_id ORDER BY min(r.created_at),r.set_id LIMIT 50";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (output.items.len != 0) try output.append(allocator, '\n');
        const line = try std.fmt.allocPrint(allocator, "set {d} | {d} request(s) | {d}/2 noms | {s} - {s}", .{ c.sqlite3_column_int(stmt, 0), c.sqlite3_column_int(stmt, 1), c.sqlite3_column_int(stmt, 5), std.mem.span(c.sqlite3_column_text(stmt, 3)), std.mem.span(c.sqlite3_column_text(stmt, 4)) });
        defer allocator.free(line);
        try output.appendSlice(allocator, line);
    }
    return output.toOwnedSlice(allocator);
}

pub fn rankContextLocked(self: *Store, map_md5: []const u8) !domain.BeatmapRankContext {
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT b.id,b.set_id,b.status,(SELECT count(*) FROM beatmap_rank_requests r WHERE r.set_id=b.set_id AND r.active=1),(SELECT count(*) FROM beatmap_nominations n WHERE n.set_id=b.set_id AND n.active=1) FROM beatmaps b WHERE b.md5=?1";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, map_md5.ptr, @intCast(map_md5.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.BeatmapNotFound;
    return .{ .map_id = c.sqlite3_column_int(stmt, 0), .set_id = c.sqlite3_column_int(stmt, 1), .status = @intCast(c.sqlite3_column_int(stmt, 2)), .requests = @intCast(c.sqlite3_column_int(stmt, 3)), .nominations = @intCast(c.sqlite3_column_int(stmt, 4)) };
}

pub fn activeRankCountLocked(self: *Store, comptime table: []const u8, set_id: i32) !u32 {
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT count(*) FROM " ++ table ++ " WHERE set_id=?1 AND active=1";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, set_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return @intCast(c.sqlite3_column_int(stmt, 0));
}

pub fn clearBeatmapNominationsLocked(self: *Store, set_id: i32) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmap_nominations SET active=0,updated_at=unixepoch() WHERE set_id=?1 AND active=1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, set_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn resolveBeatmapRequestsLocked(self: *Store, set_id: i32) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmap_rank_requests SET active=0,resolved_at=unixepoch() WHERE set_id=?1 AND active=1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, set_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn insertBeatmapRankEventLocked(self: *Store, set_id: i32, actor_id: i32, action: []const u8, from_status: i8, to_status: i8, reason: []const u8) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO beatmap_rank_events(set_id,actor_id,action,from_status,to_status,reason) VALUES(?1,?2,?3,?4,?5,?6)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, set_id);
    _ = c.sqlite3_bind_int(stmt, 2, actor_id);
    _ = c.sqlite3_bind_text(stmt, 3, action.ptr, @intCast(action.len), null);
    _ = c.sqlite3_bind_int(stmt, 4, from_status);
    _ = c.sqlite3_bind_int(stmt, 5, to_status);
    _ = c.sqlite3_bind_text(stmt, 6, reason.ptr, @intCast(reason.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    var target_buf: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "beatmapset:{d}", .{set_id});
    var audit: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO audit_log(actor_id,action,target,detail) VALUES(?1,?2,?3,?4)", -1, &audit, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(audit);
    _ = c.sqlite3_bind_int(audit, 1, actor_id);
    var audit_action_buf: [64]u8 = undefined;
    const audit_action = try std.fmt.bufPrint(&audit_action_buf, "beatmap.{s}", .{action});
    _ = c.sqlite3_bind_text(audit, 2, audit_action.ptr, @intCast(audit_action.len), null);
    _ = c.sqlite3_bind_text(audit, 3, target.ptr, @intCast(target.len), null);
    _ = c.sqlite3_bind_text(audit, 4, reason.ptr, @intCast(reason.len), null);
    if (c.sqlite3_step(audit) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}
