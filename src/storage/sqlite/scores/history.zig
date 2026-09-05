const std = @import("std");
const domain = @import("../../../domain.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;

pub fn readStatsHistoryLocked(self: *Store, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !domain.StatsHistory {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT day,pp,global_rank FROM user_stats_history WHERE user_id=?1 AND source=?2 AND mode=?3 AND day BETWEEN ((unixepoch()/86400)-89)*86400 AND (unixepoch()/86400)*86400 ORDER BY day", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    const source_name = @tagName(source);
    _ = c.sqlite3_bind_text(stmt, 2, source_name.ptr, @intCast(source_name.len), null);
    _ = c.sqlite3_bind_int(stmt, 3, stats_mode);

    var history: domain.StatsHistory = .{};
    while (history.len < domain.StatsHistory.max_points and c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        history.points[history.len] = .{
            .day = c.sqlite3_column_int64(stmt, 0),
            .pp = c.sqlite3_column_int(stmt, 1),
            .global_rank = c.sqlite3_column_int(stmt, 2),
        };
        history.len += 1;
    }
    return history;
}

pub fn pruneStatsHistoryLocked(self: *Store) !void {
    try self.exec("DELETE FROM user_stats_history WHERE day<((unixepoch()/86400)-89)*86400");
}

pub fn recordStatsHistorySliceCurrentLocked(self: *Store, source: domain.SiteScoreSource, stats_mode: u8, user_id: i32) !void {
    const score_mode = domain.siteScoreMode(stats_mode);
    const namespace = domain.siteNamespace(source, stats_mode);
    const source_name = @tagName(source);
    // Rank is a property of the whole source/mode slice. Updating only the
    // submitting player can leave both sides of a rank swap at the same
    // position for the rest of the day.
    if (user_id != 0) return self.recordStatsHistorySliceCurrentLocked(source, stats_mode, 0);
    if (user_id == 0) {
        var clear: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM user_stats_history WHERE source=?1 AND mode=?2 AND day=(unixepoch()/86400)*86400", -1, &clear, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(clear);
        _ = c.sqlite3_bind_text(clear, 1, source_name.ptr, @intCast(source_name.len), null);
        _ = c.sqlite3_bind_int(clear, 2, stats_mode);
        if (c.sqlite3_step(clear) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }
    const sql: [:0]const u8 = switch (source) {
        .all => if (user_id == 0)
            "WITH players AS (SELECT s.user_id,s.pp FROM stats s JOIN users u ON u.id=s.user_id WHERE s.mode=?2 AND s.plays>0 AND u.id!=3 AND u.restricted=0),ordered AS (SELECT user_id,pp,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) " ++
                "INSERT INTO user_stats_history(user_id,source,mode,day,pp,global_rank) SELECT user_id,?1,?2,(unixepoch()/86400)*86400,pp,global_rank FROM ordered WHERE 1 " ++
                "ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp,global_rank=excluded.global_rank"
        else
            "WITH player AS (SELECT s.user_id,s.pp FROM stats s JOIN users u ON u.id=s.user_id WHERE s.user_id=?3 AND s.mode=?2 AND s.plays>0 AND u.id!=3 AND u.restricted=0),ranked AS (SELECT p.user_id,p.pp,1+(SELECT count(*) FROM user_stats_history h WHERE h.source=?1 AND h.mode=?2 AND h.day=(unixepoch()/86400)*86400 AND h.user_id!=p.user_id AND (h.pp>p.pp OR (h.pp=p.pp AND h.user_id<p.user_id))) global_rank FROM player p) " ++
                "INSERT INTO user_stats_history(user_id,source,mode,day,pp,global_rank) SELECT user_id,?1,?2,(unixepoch()/86400)*86400,pp,global_rank FROM ranked WHERE 1 " ++
                "ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp,global_rank=excluded.global_rank",
        .stable, .scorev2 => if (user_id == 0)
            "WITH source_scores AS (SELECT s.user_id,b.id beatmap_id,s.pp,s.passed,b.status FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.mode=?3 AND s.rank_namespace=?4)," ++
                "activity AS (SELECT DISTINCT user_id FROM source_scores)," ++
                "best AS (SELECT user_id,beatmap_id,max(pp) pp FROM source_scores WHERE passed=1 AND status IN(3,4) GROUP BY user_id,beatmap_id)," ++
                "weighted AS (SELECT user_id,pp,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC)-1 performance_index FROM best)," ++
                "performance AS (SELECT user_id,CAST(round(sum(pp*pow(0.95,performance_index))+416.6667*(1-pow(0.9994,count(*)))) AS INTEGER) pp FROM weighted GROUP BY user_id)," ++
                "players AS (SELECT a.user_id,coalesce(p.pp,0) pp FROM activity a JOIN users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND u.restricted=0)," ++
                "ordered AS (SELECT user_id,pp,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) " ++
                "INSERT INTO user_stats_history(user_id,source,mode,day,pp,global_rank) SELECT user_id,?1,?2,(unixepoch()/86400)*86400,pp,global_rank FROM ordered WHERE 1 " ++
                "ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp,global_rank=excluded.global_rank"
        else
            "WITH source_scores AS (SELECT s.user_id,b.id beatmap_id,s.pp,s.passed,b.status FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=?5 AND s.mode=?3 AND s.rank_namespace=?4)," ++
                "activity AS (SELECT DISTINCT user_id FROM source_scores)," ++
                "best AS (SELECT user_id,beatmap_id,max(pp) pp FROM source_scores WHERE passed=1 AND status IN(3,4) GROUP BY user_id,beatmap_id)," ++
                "weighted AS (SELECT user_id,pp,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC)-1 performance_index FROM best)," ++
                "performance AS (SELECT user_id,CAST(round(sum(pp*pow(0.95,performance_index))+416.6667*(1-pow(0.9994,count(*)))) AS INTEGER) pp FROM weighted GROUP BY user_id)," ++
                "player AS (SELECT a.user_id,coalesce(p.pp,0) pp FROM activity a JOIN users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND u.restricted=0)," ++
                "ranked AS (SELECT p.user_id,p.pp,1+(SELECT count(*) FROM user_stats_history h WHERE h.source=?1 AND h.mode=?2 AND h.day=(unixepoch()/86400)*86400 AND h.user_id!=p.user_id AND (h.pp>p.pp OR (h.pp=p.pp AND h.user_id<p.user_id))) global_rank FROM player p) " ++
                "INSERT INTO user_stats_history(user_id,source,mode,day,pp,global_rank) SELECT user_id,?1,?2,(unixepoch()/86400)*86400,pp,global_rank FROM ranked WHERE 1 " ++
                "ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp,global_rank=excluded.global_rank",
        .lazer => if (user_id == 0)
            "WITH source_scores AS (SELECT s.user_id,b.id beatmap_id,s.pp,s.passed,b.status FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.ruleset_id=?3 AND s.rank_namespace=?4)," ++
                "activity AS (SELECT DISTINCT user_id FROM source_scores)," ++
                "best AS (SELECT user_id,beatmap_id,max(pp) pp FROM source_scores WHERE passed=1 AND status IN(3,4) GROUP BY user_id,beatmap_id)," ++
                "weighted AS (SELECT user_id,pp,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC)-1 performance_index FROM best)," ++
                "performance AS (SELECT user_id,CAST(round(sum(pp*pow(0.95,performance_index))+416.6667*(1-pow(0.9994,count(*)))) AS INTEGER) pp FROM weighted GROUP BY user_id)," ++
                "players AS (SELECT a.user_id,coalesce(p.pp,0) pp FROM activity a JOIN users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND u.restricted=0)," ++
                "ordered AS (SELECT user_id,pp,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) " ++
                "INSERT INTO user_stats_history(user_id,source,mode,day,pp,global_rank) SELECT user_id,?1,?2,(unixepoch()/86400)*86400,pp,global_rank FROM ordered WHERE 1 " ++
                "ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp,global_rank=excluded.global_rank"
        else
            "WITH source_scores AS (SELECT s.user_id,b.id beatmap_id,s.pp,s.passed,b.status FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=?5 AND s.ruleset_id=?3 AND s.rank_namespace=?4)," ++
                "activity AS (SELECT DISTINCT user_id FROM source_scores)," ++
                "best AS (SELECT user_id,beatmap_id,max(pp) pp FROM source_scores WHERE passed=1 AND status IN(3,4) GROUP BY user_id,beatmap_id)," ++
                "weighted AS (SELECT user_id,pp,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC)-1 performance_index FROM best)," ++
                "performance AS (SELECT user_id,CAST(round(sum(pp*pow(0.95,performance_index))+416.6667*(1-pow(0.9994,count(*)))) AS INTEGER) pp FROM weighted GROUP BY user_id)," ++
                "player AS (SELECT a.user_id,coalesce(p.pp,0) pp FROM activity a JOIN users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND u.restricted=0)," ++
                "ranked AS (SELECT p.user_id,p.pp,1+(SELECT count(*) FROM user_stats_history h WHERE h.source=?1 AND h.mode=?2 AND h.day=(unixepoch()/86400)*86400 AND h.user_id!=p.user_id AND (h.pp>p.pp OR (h.pp=p.pp AND h.user_id<p.user_id))) global_rank FROM player p) " ++
                "INSERT INTO user_stats_history(user_id,source,mode,day,pp,global_rank) SELECT user_id,?1,?2,(unixepoch()/86400)*86400,pp,global_rank FROM ranked WHERE 1 " ++
                "ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp,global_rank=excluded.global_rank",
    };
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, source_name.ptr, @intCast(source_name.len), null);
    _ = c.sqlite3_bind_int(stmt, 2, stats_mode);
    if (source == .all) {
        _ = c.sqlite3_bind_int(stmt, 3, user_id);
    } else {
        _ = c.sqlite3_bind_int(stmt, 3, score_mode);
        _ = c.sqlite3_bind_text(stmt, 4, namespace.ptr, @intCast(namespace.len), null);
        _ = c.sqlite3_bind_int(stmt, 5, user_id);
    }
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn statsHistoryLocked(self: *Store, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !domain.StatsHistory {
    return self.readStatsHistoryLocked(user_id, source, stats_mode);
}

pub fn statsHistory(self: *Store, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !domain.StatsHistory {
    if (user_id <= 0 or !domain.validSiteMode(source, stats_mode)) return error.InvalidStatsHistory;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var user: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM users WHERE id=?1 AND id!=3 AND restricted=0", -1, &user, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(user);
    _ = c.sqlite3_bind_int(user, 1, user_id);
    if (c.sqlite3_step(user) != c.SQLITE_ROW) return error.InvalidStatsHistory;
    return self.statsHistoryLocked(user_id, source, stats_mode);
}

pub fn recordAllStatsHistoryCurrentLocked(self: *Store) !void {
    try self.pruneStatsHistoryLocked();
    const full_modes = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 8 };
    for ([_]domain.SiteScoreSource{ .all, .stable, .lazer }) |source| {
        for (full_modes) |stats_mode| try self.recordStatsHistorySliceCurrentLocked(source, stats_mode, 0);
    }
    for ([_]u8{ 0, 1, 2, 3 }) |stats_mode| try self.recordStatsHistorySliceCurrentLocked(.scorev2, stats_mode, 0);
}

pub fn recordBeatmapStatsHistoryCurrentLocked(self: *Store, map_id: i32, md5: []const u8) !void {
    var slices = [_][9]bool{[_]bool{false} ** 9} ** 4;
    var stmt: ?*c.sqlite3_stmt = null;
    const sql =
        "WITH keys(source,mode) AS (" ++
        "SELECT CASE rank_namespace WHEN 'scorev2' THEN 'scorev2' ELSE 'stable' END,CASE rank_namespace WHEN 'relax' THEN mode+4 WHEN 'autopilot' THEN 8 ELSE mode END FROM scores WHERE map_md5=?1 " ++
        "UNION SELECT 'lazer',CASE rank_namespace WHEN 'relax' THEN ruleset_id+4 WHEN 'autopilot' THEN 8 ELSE ruleset_id END FROM lazer_scores WHERE beatmap_id=?2)," ++
        "expanded(source,mode) AS (SELECT source,mode FROM keys UNION SELECT 'all',mode FROM keys WHERE source!='scorev2') " ++
        "SELECT DISTINCT source,mode FROM expanded";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_text(stmt, 1, md5.ptr, @intCast(md5.len), null);
    _ = c.sqlite3_bind_int(stmt, 2, map_id);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const source = domain.parseSiteScoreSource(std.mem.span(c.sqlite3_column_text(stmt, 0))) orelse continue;
        const stats_mode = c.sqlite3_column_int(stmt, 1);
        if (stats_mode < 0 or stats_mode > 8 or !domain.validSiteMode(source, @intCast(stats_mode))) continue;
        slices[@intFromEnum(source)][@intCast(stats_mode)] = true;
    }
    _ = c.sqlite3_finalize(stmt);
    try self.pruneStatsHistoryLocked();
    for (slices, 0..) |modes, source_index| {
        const source: domain.SiteScoreSource = @enumFromInt(source_index);
        for (modes, 0..) |present, stats_mode| if (present) try self.recordStatsHistorySliceCurrentLocked(source, @intCast(stats_mode), 0);
    }
}

pub fn refreshStatsHistory(self: *Store) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    try self.recordAllStatsHistoryCurrentLocked();
    try self.exec("COMMIT");
}
