const std = @import("std");
const domain = @import("../../../domain.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const jsonString = @import("../beatmaps/lazer_listing.zig").jsonString;

pub fn prepareSiteScores(self: *Store, sql: [:0]const u8, user_id: i32, score_mode: u8, namespace: []const u8) !*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, score_mode);
    _ = c.sqlite3_bind_text(stmt, 3, namespace.ptr, @intCast(namespace.len), null);
    return stmt.?;
}

pub fn writeSiteScores(writer: *std.Io.Writer, scores: *c.sqlite3_stmt, include_weight: bool) !void {
    try writer.writeByte('[');
    var first = true;
    var position: usize = 0;
    while (c.sqlite3_step(scores) == c.SQLITE_ROW) {
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("{{\"id\":{d},\"score\":{d},\"score_without_mods\":{d},\"legacy_score\":", .{ c.sqlite3_column_int64(scores, 0), c.sqlite3_column_int64(scores, 1), c.sqlite3_column_int64(scores, 20) });
        if (c.sqlite3_column_type(scores, 21) == c.SQLITE_NULL) try writer.writeAll("null") else try writer.print("{d}", .{c.sqlite3_column_int(scores, 21)});
        try writer.print(",\"pp\":{d},\"accuracy\":{d},\"max_combo\":{d},\"mods\":{d},\"mode\":{d},\"namespace\":", .{ c.sqlite3_column_double(scores, 2), c.sqlite3_column_double(scores, 3), c.sqlite3_column_int(scores, 4), c.sqlite3_column_int(scores, 5), c.sqlite3_column_int(scores, 6) });
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(scores, 7)));
        try writer.print(",\"passed\":{},\"submitted_at\":{d},\"set_id\":{d},\"map_id\":{d},\"artist\":", .{ c.sqlite3_column_int(scores, 8) != 0, c.sqlite3_column_int64(scores, 9), c.sqlite3_column_int(scores, 10), c.sqlite3_column_int(scores, 11) });
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(scores, 12)));
        try writer.writeAll(",\"title\":");
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(scores, 13)));
        try writer.writeAll(",\"version\":");
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(scores, 14)));
        try writer.print(",\"status\":{d},\"client\":", .{c.sqlite3_column_int(scores, 15)});
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(scores, 16)));
        try writer.writeAll(",\"mods_json\":");
        if (c.sqlite3_column_type(scores, 17) == c.SQLITE_NULL) {
            try writer.writeAll("null");
        } else {
            try writer.writeAll(std.mem.span(c.sqlite3_column_text(scores, 17)));
        }
        if (include_weight) {
            const percentage = 100.0 * std.math.pow(f64, 0.95, @floatFromInt(position));
            const weighted_pp = c.sqlite3_column_double(scores, 2) * percentage / 100.0;
            try writer.print(",\"weight\":{{\"percentage\":{d:.2},\"pp\":{d:.2}}}", .{ percentage, weighted_pp });
        }
        try writer.print(",\"has_replay\":{},\"star_rating\":{d}}}", .{ c.sqlite3_column_int(scores, 18) != 0, c.sqlite3_column_double(scores, 19) });
        position += 1;
    }
    try writer.writeByte(']');
}

pub fn siteBeatmapLeaderboard(self: *Store, allocator: std.mem.Allocator, map_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const score_mode = domain.siteScoreMode(stats_mode);
    const namespace = domain.siteNamespace(source, stats_mode);
    var map: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT mode FROM beatmaps WHERE id=?1", -1, &map, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(map);
    _ = c.sqlite3_bind_int(map, 1, map_id);
    if (c.sqlite3_step(map) != c.SQLITE_ROW or c.sqlite3_column_int(map, 0) != score_mode) return null;
    const sql =
        "WITH candidates(id,user_id,name,country,privileges,total_score,score_without_mods,legacy_score,pp,accuracy,max_combo,mods,mode,rank_namespace,submitted_at,client,mods_json,has_replay) AS (" ++
        "SELECT s.id,s.user_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,u.privileges,s.score,s.score,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.submitted_at,'stable',NULL,(length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)) FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 JOIN users u ON u.id=s.user_id WHERE b.id=?1 AND b.status>=3 AND s.mode=?2 AND s.rank_namespace=?4 AND s.passed=1 AND u.restricted=0 AND u.id!=3 AND (?3='all' OR ?3='stable' OR ?3='scorev2') AND NOT EXISTS(SELECT 1 FROM beatmap_rank_events veto_event WHERE veto_event.set_id=b.set_id AND veto_event.id=(SELECT max(latest_event.id) FROM beatmap_rank_events latest_event WHERE latest_event.set_id=b.set_id) AND veto_event.action='veto') UNION ALL " ++
        "SELECT s.id,s.user_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,u.privileges,s.total_score,s.total_score_without_mods,s.legacy_total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.submitted_at,'lazer',s.mods_json,(length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)) FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id JOIN users u ON u.id=s.user_id WHERE s.beatmap_id=?1 AND b.status>=3 AND s.ruleset_id=?2 AND s.rank_namespace=?4 AND s.passed=1 AND u.restricted=0 AND u.id!=3 AND (?3='all' OR ?3='lazer') AND NOT EXISTS(SELECT 1 FROM beatmap_rank_events veto_event WHERE veto_event.set_id=b.set_id AND veto_event.id=(SELECT max(latest_event.id) FROM beatmap_rank_events latest_event WHERE latest_event.set_id=b.set_id) AND veto_event.action='veto'))," ++
        "per_user AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY CASE WHEN ?3='all' OR ?5=1 THEN pp ELSE total_score END DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) user_place FROM candidates)," ++
        "board AS (SELECT *,row_number() OVER(ORDER BY CASE WHEN ?5=1 THEN pp ELSE total_score END DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) position FROM per_user WHERE user_place=1) " ++
        "SELECT position,id,user_id,name,country,privileges,total_score,score_without_mods,legacy_score,pp,accuracy,max_combo,mods,rank_namespace,submitted_at,client,mods_json,has_replay FROM board ORDER BY position LIMIT 100";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, map_id);
    _ = c.sqlite3_bind_int(stmt, 2, score_mode);
    const source_name = @tagName(source);
    _ = c.sqlite3_bind_text(stmt, 3, source_name.ptr, @intCast(source_name.len), null);
    _ = c.sqlite3_bind_text(stmt, 4, namespace.ptr, @intCast(namespace.len), null);
    _ = c.sqlite3_bind_int(stmt, 5, @intFromBool(std.mem.eql(u8, namespace, "relax") or std.mem.eql(u8, namespace, "autopilot")));
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"map_id\":{d},\"source\":\"{s}\",\"mode\":{d},\"namespace\":", .{ map_id, source_name, stats_mode });
    try jsonString(&output.writer, namespace);
    try output.writer.writeAll(",\"scores\":[");
    var first = true;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.print("{{\"rank\":{d},\"id\":{d},\"user_id\":{d},\"name\":", .{ c.sqlite3_column_int(stmt, 0), c.sqlite3_column_int64(stmt, 1), c.sqlite3_column_int(stmt, 2) });
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 3)));
        try output.writer.writeAll(",\"country\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 4)));
        try output.writer.print(",\"privileges\":{d},\"score\":{d},\"score_without_mods\":{d},\"legacy_score\":", .{ c.sqlite3_column_int64(stmt, 5), c.sqlite3_column_int64(stmt, 6), c.sqlite3_column_int64(stmt, 7) });
        if (c.sqlite3_column_type(stmt, 8) == c.SQLITE_NULL) try output.writer.writeAll("null") else try output.writer.print("{d}", .{c.sqlite3_column_int(stmt, 8)});
        try output.writer.print(",\"pp\":{d},\"accuracy\":{d},\"max_combo\":{d},\"mods\":{d},\"namespace\":", .{ c.sqlite3_column_double(stmt, 9), c.sqlite3_column_double(stmt, 10), c.sqlite3_column_int(stmt, 11), c.sqlite3_column_int(stmt, 12) });
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 13)));
        try output.writer.print(",\"submitted_at\":{d},\"client\":", .{c.sqlite3_column_int64(stmt, 14)});
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 15)));
        try output.writer.writeAll(",\"mods_json\":");
        if (c.sqlite3_column_type(stmt, 16) == c.SQLITE_NULL) try output.writer.writeAll("null") else try output.writer.writeAll(std.mem.span(c.sqlite3_column_text(stmt, 16)));
        try output.writer.print(",\"has_replay\":{}}}", .{c.sqlite3_column_int(stmt, 17) != 0});
    }
    try output.writer.writeAll("]}");
    var list = output.toArrayList();
    return @as(?[]u8, try list.toOwnedSlice(allocator));
}
