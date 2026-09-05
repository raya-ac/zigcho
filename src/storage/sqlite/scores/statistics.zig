const std = @import("std");
const domain = @import("../../../domain.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const stableGrade = @import("../beatmaps/catalog.zig").stableGrade;
const PpSnapshot = @import("../../contracts.zig").PpSnapshot;

pub fn banchoStatsBatch(self: *Store, allocator: std.mem.Allocator, requests: []const @import("../../contracts.zig").BanchoStatsRequest) ![]@import("../../contracts.zig").BanchoStats {
    const Stats = @import("../../contracts.zig").BanchoStats;
    const result = try allocator.alloc(Stats, requests.len);
    errdefer allocator.free(result);
    for (requests, result) |request, *value| value.* = Stats.fromStats((try self.statsForUser(request.user_id, request.mode)) orelse domain.Stats{});
    return result;
}

pub fn statsForUser(self: *Store, user_id: i32, mode: u8) !?domain.Stats {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = "SELECT s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,CASE WHEN s.plays>0 THEN (SELECT count(1)+1 FROM stats r JOIN users u ON u.id=r.user_id WHERE r.mode=s.mode AND r.plays>0 AND u.id!=3 AND u.restricted=0 AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) ELSE 0 END,CASE WHEN s.plays>0 THEN (SELECT count(1)+1 FROM stats r JOIN users u ON u.id=r.user_id WHERE r.mode=s.mode AND r.plays>0 AND u.id!=3 AND u.restricted=0 AND u.country=me.country AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) ELSE 0 END FROM stats s JOIN users me ON me.id=s.user_id WHERE s.user_id=?1 AND s.mode=?2";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, mode);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    var stats: domain.Stats = .{
        .mode = @enumFromInt(mode % 4),
        .ranked_score = c.sqlite3_column_int64(stmt, 0),
        .total_score = c.sqlite3_column_int64(stmt, 1),
        .pp = c.sqlite3_column_int(stmt, 2),
        .plays = c.sqlite3_column_int(stmt, 3),
        .play_time = c.sqlite3_column_int(stmt, 4),
        .total_hits = c.sqlite3_column_int64(stmt, 5),
        .accuracy = c.sqlite3_column_double(stmt, 6),
        .max_combo = c.sqlite3_column_int(stmt, 7),
        .global_rank = c.sqlite3_column_int(stmt, 8),
        .country_rank = c.sqlite3_column_int(stmt, 9),
        .replay_views = try self.replayViewCountLocked(user_id, .all, mode),
    };
    var stable: ?*c.sqlite3_stmt = null;
    const stable_sql = "SELECT s.mods,s.accuracy,s.n300,s.n100,s.n50,s.nmiss FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=?1 AND s.mode=?2 AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4)";
    if (c.sqlite3_prepare_v2(self.db, stable_sql, -1, &stable, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stable);
    _ = c.sqlite3_bind_int(stable, 1, user_id);
    _ = c.sqlite3_bind_int(stable, 2, mode);
    while (c.sqlite3_step(stable) == c.SQLITE_ROW) stats.addGrade(stableGrade(mode, c.sqlite3_column_int(stable, 0), c.sqlite3_column_double(stable, 1), c.sqlite3_column_int(stable, 2), c.sqlite3_column_int(stable, 3), c.sqlite3_column_int(stable, 4), c.sqlite3_column_int(stable, 5)));
    var modern: ?*c.sqlite3_stmt = null;
    const modern_sql = "SELECT s.rank FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=?1 AND s.ruleset_id=?2 AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4)";
    if (c.sqlite3_prepare_v2(self.db, modern_sql, -1, &modern, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(modern);
    _ = c.sqlite3_bind_int(modern, 1, user_id);
    _ = c.sqlite3_bind_int(modern, 2, mode);
    while (c.sqlite3_step(modern) == c.SQLITE_ROW) stats.addGrade(std.mem.span(c.sqlite3_column_text(modern, 0)));
    return stats;
}

pub fn statsRulesetsForUser(self: *Store, user_id: i32) ![4]?domain.Stats {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var result = [_]?domain.Stats{null} ** 4;
    const sql = "SELECT s.mode,s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,CASE WHEN s.plays>0 THEN (SELECT count(1)+1 FROM stats r JOIN users u ON u.id=r.user_id WHERE r.mode=s.mode AND r.plays>0 AND u.id!=3 AND u.restricted=0 AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) ELSE 0 END,CASE WHEN s.plays>0 THEN (SELECT count(1)+1 FROM stats r JOIN users u ON u.id=r.user_id WHERE r.mode=s.mode AND r.plays>0 AND u.id!=3 AND u.restricted=0 AND u.country=me.country AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) ELSE 0 END FROM stats s JOIN users me ON me.id=s.user_id WHERE s.user_id=?1 AND s.mode BETWEEN 0 AND 3 ORDER BY s.mode";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const mode: u8 = @intCast(c.sqlite3_column_int(stmt, 0));
        result[mode] = .{
            .mode = @enumFromInt(mode),
            .ranked_score = c.sqlite3_column_int64(stmt, 1),
            .total_score = c.sqlite3_column_int64(stmt, 2),
            .pp = c.sqlite3_column_int(stmt, 3),
            .plays = c.sqlite3_column_int(stmt, 4),
            .play_time = c.sqlite3_column_int(stmt, 5),
            .total_hits = c.sqlite3_column_int64(stmt, 6),
            .accuracy = c.sqlite3_column_double(stmt, 7),
            .max_combo = c.sqlite3_column_int(stmt, 8),
            .global_rank = c.sqlite3_column_int(stmt, 9),
            .country_rank = c.sqlite3_column_int(stmt, 10),
        };
    }
    var stable: ?*c.sqlite3_stmt = null;
    const stable_sql = "SELECT s.mode,s.mods,s.accuracy,s.n300,s.n100,s.n50,s.nmiss FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=?1 AND s.mode BETWEEN 0 AND 3 AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4)";
    if (c.sqlite3_prepare_v2(self.db, stable_sql, -1, &stable, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stable);
    _ = c.sqlite3_bind_int(stable, 1, user_id);
    while (c.sqlite3_step(stable) == c.SQLITE_ROW) {
        const mode: u8 = @intCast(c.sqlite3_column_int(stable, 0));
        if (result[mode]) |*stats| stats.addGrade(stableGrade(mode, c.sqlite3_column_int(stable, 1), c.sqlite3_column_double(stable, 2), c.sqlite3_column_int(stable, 3), c.sqlite3_column_int(stable, 4), c.sqlite3_column_int(stable, 5), c.sqlite3_column_int(stable, 6)));
    }
    var modern: ?*c.sqlite3_stmt = null;
    const modern_sql = "SELECT s.ruleset_id,s.rank FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=?1 AND s.ruleset_id BETWEEN 0 AND 3 AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4)";
    if (c.sqlite3_prepare_v2(self.db, modern_sql, -1, &modern, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(modern);
    _ = c.sqlite3_bind_int(modern, 1, user_id);
    while (c.sqlite3_step(modern) == c.SQLITE_ROW) {
        const mode: u8 = @intCast(c.sqlite3_column_int(modern, 0));
        if (result[mode]) |*stats| stats.addGrade(std.mem.span(c.sqlite3_column_text(modern, 1)));
    }
    for (0..result.len) |mode| if (result[mode]) |*stats| {
        stats.replay_views = try self.replayViewCountLocked(user_id, .all, @intCast(mode));
    };
    return result;
}

pub fn sourceStatsForUser(self: *Store, user_id: i32, mode: u8, source: domain.SiteScoreSource) !?domain.Stats {
    if (source != .stable and source != .lazer) return error.InvalidScoreSource;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const stable_sql =
        "WITH source_scores AS (SELECT s.user_id,s.id score_id,s.score total_score,s.pp,s.accuracy,s.max_combo,s.passed,s.time_elapsed/1000 play_time,b.status,b.id beatmap_id FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.mode=?2 AND s.rank_namespace='vanilla')," ++
        "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed=1 AND status IN(3,4))," ++
        "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
        "performance AS (SELECT user_id,round(sum(pp*pow(0.95,performance_index))+416.6667*(1-pow(0.9994,count(*)))) pp,sum(accuracy*pow(0.95,performance_index))/(20*(1-pow(0.95,count(*)))) accuracy FROM ranked GROUP BY user_id)," ++
        "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce(sum(play_time),0) play_time,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed=1 AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id)," ++
        "players AS (SELECT a.user_id,a.ranked_score,a.total_score,coalesce(p.pp,0) pp,a.plays,a.play_time,coalesce(p.accuracy,0) accuracy,a.max_combo FROM activity a JOIN users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND u.restricted=0)," ++
        "ordered AS (SELECT *,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) SELECT ranked_score,total_score,pp,plays,play_time,accuracy,max_combo,global_rank FROM ordered WHERE user_id=?1";
    const lazer_sql =
        "WITH source_scores AS (SELECT s.user_id,s.id score_id,coalesce(s.legacy_total_score,s.total_score) total_score,s.pp,s.accuracy,s.max_combo,s.passed,max(b.total_length,0) play_time,b.status,s.beatmap_id FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.ruleset_id=?2 AND s.rank_namespace='vanilla')," ++
        "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed=1 AND status IN(3,4))," ++
        "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
        "performance AS (SELECT user_id,round(sum(pp*pow(0.95,performance_index))+416.6667*(1-pow(0.9994,count(*)))) pp,sum(accuracy*pow(0.95,performance_index))/(20*(1-pow(0.95,count(*)))) accuracy FROM ranked GROUP BY user_id)," ++
        "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce(sum(play_time),0) play_time,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed=1 AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id)," ++
        "players AS (SELECT a.user_id,a.ranked_score,a.total_score,coalesce(p.pp,0) pp,a.plays,a.play_time,coalesce(p.accuracy,0) accuracy,a.max_combo FROM activity a JOIN users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND u.restricted=0)," ++
        "ordered AS (SELECT *,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) SELECT ranked_score,total_score,pp,plays,play_time,accuracy,max_combo,global_rank FROM ordered WHERE user_id=?1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, if (source == .stable) stable_sql else lazer_sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, mode);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return .{
        .mode = @enumFromInt(mode % 4),
        .ranked_score = c.sqlite3_column_int64(stmt, 0),
        .total_score = c.sqlite3_column_int64(stmt, 1),
        .pp = c.sqlite3_column_int(stmt, 2),
        .plays = c.sqlite3_column_int(stmt, 3),
        .play_time = c.sqlite3_column_int(stmt, 4),
        .accuracy = c.sqlite3_column_double(stmt, 5),
        .max_combo = c.sqlite3_column_int(stmt, 6),
        .global_rank = c.sqlite3_column_int(stmt, 7),
        .replay_views = try self.replayViewCountLocked(user_id, source, mode),
    };
}

pub fn ppSnapshot(self: *Store, score_id: i64) !?PpSnapshot {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = "SELECT s.pp,t.pp FROM scores s JOIN stats t ON t.user_id=s.user_id AND t.mode=s.mode WHERE s.id=?1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, score_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return .{ .score = c.sqlite3_column_double(stmt, 0), .player = c.sqlite3_column_int64(stmt, 1) };
}
