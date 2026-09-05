const std = @import("std");
const domain = @import("../../../domain.zig");
const lazer = @import("../../../lazer.zig");
const user_json = @import("../../../user_json.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const ServerCounts = @import("../../contracts.zig").ServerCounts;
const jsonString = @import("../beatmaps/lazer_listing.zig").jsonString;

pub fn serverCounts(self: *Store) !ServerCounts {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT " ++
        "(SELECT count(*) FROM users WHERE id!=3)," ++
        "(SELECT count(*) FROM scores)+(SELECT count(*) FROM lazer_scores)," ++
        "(SELECT count(*) FROM scores WHERE passed=1)+(SELECT count(*) FROM lazer_scores WHERE passed=1)," ++
        "(SELECT count(*) FROM beatmaps)";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return .{
        .users = c.sqlite3_column_int64(stmt, 0),
        .plays = c.sqlite3_column_int64(stmt, 1),
        .passed = c.sqlite3_column_int64(stmt, 2),
        .maps = c.sqlite3_column_int64(stmt, 3),
    };
}

pub fn customAvatarUserIds(self: *Store, allocator: std.mem.Allocator) ![]i32 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT user_id FROM user_avatars ORDER BY user_id", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    var ids: std.ArrayList(i32) = .empty;
    errdefer ids.deinit(allocator);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) try ids.append(allocator, c.sqlite3_column_int(stmt, 0));
    return ids.toOwnedSlice(allocator);
}

pub fn siteRankings(self: *Store, allocator: std.mem.Allocator, source: domain.SiteScoreSource, mode: u8, offset: u16) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const stable_sql =
        "WITH source_scores AS (" ++
        "SELECT s.user_id,s.id score_id,s.score total_score,s.pp,s.accuracy,s.max_combo,s.passed,b.status,b.id beatmap_id " ++
        "FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.mode=?1 AND s.rank_namespace=?2)," ++
        "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed=1 AND status IN(3,4))," ++
        "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
        "performance AS (SELECT user_id,round(sum(pp*pow(0.95,performance_index))+416.6667*(1-pow(0.9994,count(*)))) pp,sum(accuracy*pow(0.95,performance_index))/(20*(1-pow(0.95,count(*)))) accuracy FROM ranked GROUP BY user_id)," ++
        "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed=1 AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id) " ++
        "SELECT row_number() OVER(ORDER BY coalesce(p.pp,0) DESC,u.id ASC),u.id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,u.privileges,coalesce(p.pp,0),coalesce(p.accuracy,0),a.plays,a.ranked_score,a.total_score,a.max_combo FROM activity a JOIN users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND u.restricted=0 AND u.show_profile_stats=1 ORDER BY coalesce(p.pp,0) DESC,u.id ASC LIMIT 100 OFFSET ?3";
    const lazer_sql =
        "WITH source_scores AS (" ++
        "SELECT s.user_id,s.id score_id,coalesce(s.legacy_total_score,s.total_score) total_score,s.pp,s.accuracy,s.max_combo,s.passed,b.status,s.beatmap_id " ++
        "FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.ruleset_id=?1 AND s.rank_namespace=?2)," ++
        "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed=1 AND status IN(3,4))," ++
        "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
        "performance AS (SELECT user_id,round(sum(pp*pow(0.95,performance_index))+416.6667*(1-pow(0.9994,count(*)))) pp,sum(accuracy*pow(0.95,performance_index))/(20*(1-pow(0.95,count(*)))) accuracy FROM ranked GROUP BY user_id)," ++
        "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed=1 AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id) " ++
        "SELECT row_number() OVER(ORDER BY coalesce(p.pp,0) DESC,u.id ASC),u.id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,u.privileges,coalesce(p.pp,0),coalesce(p.accuracy,0),a.plays,a.ranked_score,a.total_score,a.max_combo FROM activity a JOIN users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND u.restricted=0 AND u.show_profile_stats=1 ORDER BY coalesce(p.pp,0) DESC,u.id ASC LIMIT 100 OFFSET ?3";
    const sql: [*:0]const u8 = switch (source) {
        .all => "SELECT row_number() OVER(ORDER BY s.pp DESC,u.id ASC),u.id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,u.privileges,s.pp,s.accuracy,s.plays,s.ranked_score,s.total_score,s.max_combo FROM stats s JOIN users u ON u.id=s.user_id WHERE s.mode=?1 AND u.id!=3 AND u.restricted=0 AND u.show_profile_stats=1 AND s.plays>0 ORDER BY s.pp DESC,u.id ASC LIMIT 100 OFFSET ?2",
        .stable, .scorev2 => stable_sql,
        .lazer => lazer_sql,
    };
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (source == .all) {
        _ = c.sqlite3_bind_int(stmt, 1, mode);
        _ = c.sqlite3_bind_int(stmt, 2, offset);
    } else {
        const namespace = domain.siteNamespace(source, mode);
        _ = c.sqlite3_bind_int(stmt, 1, domain.siteScoreMode(mode));
        _ = c.sqlite3_bind_text(stmt, 2, namespace.ptr, @intCast(namespace.len), null);
        _ = c.sqlite3_bind_int(stmt, 3, offset);
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"source\":\"{s}\",\"mode\":{d},\"offset\":{d},\"players\":[", .{ @tagName(source), mode, offset });
    var first = true;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.print("{{\"rank\":{d},\"id\":{d},\"name\":", .{ c.sqlite3_column_int(stmt, 0), c.sqlite3_column_int(stmt, 1) });
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 2)));
        try output.writer.writeAll(",\"country\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 3)));
        try output.writer.print(",\"privileges\":{d},\"pp\":{d},\"accuracy\":{d},\"plays\":{d},\"ranked_score\":{d},\"total_score\":{d},\"max_combo\":{d}}}", .{ c.sqlite3_column_int64(stmt, 4), c.sqlite3_column_int(stmt, 5), c.sqlite3_column_double(stmt, 6), c.sqlite3_column_int(stmt, 7), c.sqlite3_column_int64(stmt, 8), c.sqlite3_column_int64(stmt, 9), c.sqlite3_column_int(stmt, 10) });
    }
    try output.writer.writeAll("]}");
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

pub fn lazerRankingsJson(self: *Store, allocator: std.mem.Allocator, ruleset_id: u8, kind: lazer.RankingKind, country_filter: ?[]const u8, page: u16) ![]u8 {
    if (page == 0) return error.InvalidPage;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const offset: u32 = (@as(u32, page) - 1) * 50;
    var stmt: ?*c.sqlite3_stmt = null;
    const country_sql =
        "WITH visible AS (SELECT CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END country,s.plays,s.ranked_score,s.pp FROM stats s JOIN users u ON u.id=s.user_id WHERE s.mode=?1 AND s.plays>0 AND u.id!=3 AND u.restricted=0 AND u.show_profile_stats=1) " ++
        "SELECT country,count(*),sum(plays),sum(ranked_score),sum(pp) FROM visible WHERE country!='XX' GROUP BY country ORDER BY sum(pp) DESC,country ASC LIMIT 50 OFFSET ?2";
    const performance_sql =
        "WITH visible AS (SELECT u.id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END country,u.privileges,s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,(SELECT min(count(*),2147483647) FROM score_replay_views v WHERE v.owner_id=u.id AND v.mode=s.mode AND v.rank_namespace='vanilla') replay_views," ++
        "row_number() OVER(ORDER BY s.pp DESC,u.id ASC) global_rank,row_number() OVER(PARTITION BY CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END ORDER BY s.pp DESC,u.id ASC) country_rank " ++
        "FROM stats s JOIN users u ON u.id=s.user_id WHERE s.mode=?1 AND s.plays>0 AND u.id!=3 AND u.restricted=0 AND u.show_profile_stats=1) " ++
        "SELECT * FROM visible WHERE (?2='' OR country=?2) ORDER BY pp DESC,id ASC LIMIT 50 OFFSET ?3";
    const score_sql =
        "WITH visible AS (SELECT u.id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END country,u.privileges,s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,(SELECT min(count(*),2147483647) FROM score_replay_views v WHERE v.owner_id=u.id AND v.mode=s.mode AND v.rank_namespace='vanilla') replay_views," ++
        "row_number() OVER(ORDER BY s.total_score DESC,u.id ASC) global_rank,row_number() OVER(PARTITION BY CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END ORDER BY s.total_score DESC,u.id ASC) country_rank " ++
        "FROM stats s JOIN users u ON u.id=s.user_id WHERE s.mode=?1 AND s.plays>0 AND u.id!=3 AND u.restricted=0 AND u.show_profile_stats=1) " ++
        "SELECT * FROM visible WHERE (?2='' OR country=?2) ORDER BY total_score DESC,id ASC LIMIT 50 OFFSET ?3";
    const sql: [*:0]const u8 = switch (kind) {
        .country => country_sql,
        .performance => performance_sql,
        .score => score_sql,
    };
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, ruleset_id);
    if (kind == .country) {
        _ = c.sqlite3_bind_int64(stmt, 2, offset);
    } else {
        const filter = country_filter orelse "";
        _ = c.sqlite3_bind_text(stmt, 2, filter.ptr, @intCast(filter.len), null);
        _ = c.sqlite3_bind_int64(stmt, 3, offset);
    }

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"ranking\":[");
    var row: usize = 0;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) : (row += 1) {
        if (row != 0) try output.writer.writeByte(',');
        if (kind == .country) {
            try output.writer.writeAll("{\"code\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 0)));
            try output.writer.print(",\"active_users\":{d},\"play_count\":{d},\"ranked_score\":{d},\"performance\":{d}}}", .{ c.sqlite3_column_int(stmt, 1), c.sqlite3_column_int64(stmt, 2), c.sqlite3_column_int64(stmt, 3), c.sqlite3_column_int64(stmt, 4) });
            continue;
        }
        const country_text = std.mem.span(c.sqlite3_column_text(stmt, 2));
        const cc: [2]u8 = if (country_text.len == 2) .{ country_text[0], country_text[1] } else .{ 'X', 'X' };
        const user: domain.User = .{ .id = c.sqlite3_column_int(stmt, 0), .name = std.mem.span(c.sqlite3_column_text(stmt, 1)), .safe_name = "", .country = cc, .privileges = @intCast(c.sqlite3_column_int64(stmt, 3)) };
        const stats: domain.Stats = .{ .mode = @enumFromInt(ruleset_id), .ranked_score = c.sqlite3_column_int64(stmt, 4), .total_score = c.sqlite3_column_int64(stmt, 5), .pp = c.sqlite3_column_int(stmt, 6), .plays = c.sqlite3_column_int(stmt, 7), .play_time = c.sqlite3_column_int(stmt, 8), .total_hits = c.sqlite3_column_int64(stmt, 9), .accuracy = c.sqlite3_column_double(stmt, 10), .max_combo = c.sqlite3_column_int(stmt, 11), .replay_views = c.sqlite3_column_int(stmt, 12) };
        try user_json.writeRankingStatistics(&output.writer, user, stats, c.sqlite3_column_int(stmt, 13), c.sqlite3_column_int(stmt, 14));
    }
    try output.writer.writeAll("],\"cursor\":null}");
    return output.toOwnedSlice();
}
