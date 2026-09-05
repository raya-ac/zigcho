const std = @import("std");
const domain = @import("../../../domain.zig");
const lazer = @import("../../../lazer.zig");
const stable_mods = @import("../../../stable_mods.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const stableGrade = @import("../beatmaps/catalog.zig").stableGrade;
const jsonString = @import("../beatmaps/lazer_listing.zig").jsonString;
const lazerStatus = @import("../../contracts.zig").lazerStatus;

pub fn lazerUserScoreCounts(self: *Store, user_id: i32, ruleset_id: u8, source: domain.SiteScoreSource) !domain.UserScoreCounts {
    if (source == .scorev2) return error.InvalidScoreSource;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = if (source == .all)
        "WITH candidates AS (" ++
            "SELECT s.user_id,b.id beatmap_id,s.ruleset_id mode,s.total_score,s.pp,1 source_order,s.id source_id,s.submitted_at FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id JOIN users u ON u.id=s.user_id WHERE ?3='all' AND s.ruleset_id=?2 AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4) AND u.restricted=0 " ++
            "UNION ALL SELECT s.user_id,b.id,s.mode,s.score,s.pp,0,s.id,s.submitted_at FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 JOIN users u ON u.id=s.user_id WHERE ?3='all' AND s.mode=?2 AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4) AND u.restricted=0)," ++
            "user_best AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id,mode ORDER BY pp DESC,source_order ASC,submitted_at DESC,source_id ASC) source_place FROM candidates)," ++
            "board AS (SELECT *,row_number() OVER(PARTITION BY beatmap_id,mode ORDER BY total_score DESC,source_order ASC,source_id ASC) board_place FROM user_best WHERE source_place=1) " ++
            "SELECT (SELECT count(*) FROM user_best WHERE user_id=?1 AND source_place=1),(SELECT count(*) FROM board WHERE user_id=?1 AND board_place=1)," ++
            "(SELECT count(*) FROM lazer_scores WHERE user_id=?1 AND ruleset_id=?2)+(SELECT count(*) FROM scores WHERE user_id=?1 AND mode=?2)," ++
            "(SELECT count(*) FROM profile_score_pins WHERE user_id=?1 AND mode=?2)"
    else
        "SELECT " ++
            "(SELECT count(*) FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE ?3!='stable' AND s.user_id=?1 AND s.ruleset_id=?2 AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4))+(SELECT count(*) FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE ?3!='lazer' AND s.user_id=?1 AND s.mode=?2 AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4))," ++
            "(SELECT count(*) FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE ?3!='stable' AND s.user_id=?1 AND s.ruleset_id=?2 AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4) AND NOT EXISTS(SELECT 1 FROM lazer_scores o JOIN users ou ON ou.id=o.user_id WHERE o.beatmap_id=s.beatmap_id AND o.ruleset_id=s.ruleset_id AND o.rank_namespace=s.rank_namespace AND o.passed=1 AND o.best=1 AND ou.restricted=0 AND (o.total_score>s.total_score OR (o.total_score=s.total_score AND o.id<s.id))))+(SELECT count(*) FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE ?3!='lazer' AND s.user_id=?1 AND s.mode=?2 AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4) AND NOT EXISTS(SELECT 1 FROM scores o JOIN users ou ON ou.id=o.user_id WHERE o.map_md5=s.map_md5 AND o.mode=s.mode AND o.rank_namespace=s.rank_namespace AND o.passed=1 AND o.best=1 AND ou.restricted=0 AND (o.score>s.score OR (o.score=s.score AND o.id<s.id))))," ++
            "(SELECT count(*) FROM lazer_scores WHERE ?3!='stable' AND user_id=?1 AND ruleset_id=?2)+(SELECT count(*) FROM scores WHERE ?3!='lazer' AND user_id=?1 AND mode=?2)," ++
            "(SELECT count(*) FROM profile_score_pins p WHERE p.user_id=?1 AND p.mode=?2 AND p.source=?3)";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, ruleset_id);
    const source_name = @tagName(source);
    _ = c.sqlite3_bind_text(stmt, 3, source_name.ptr, @intCast(source_name.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return .{
        .best = c.sqlite3_column_int(stmt, 0),
        .firsts = c.sqlite3_column_int(stmt, 1),
        .recent = c.sqlite3_column_int(stmt, 2),
        .pinned = c.sqlite3_column_int(stmt, 3),
    };
}

pub fn lazerRecentActivityJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, offset: u16, limit: u8) ![]u8 {
    if (limit == 0 or limit > 100) return error.InvalidScoreLimit;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql =
        "WITH all_scores AS (" ++
        "SELECT s.id,'lazer' source,s.user_id,s.ruleset_id mode,s.pp,s.rank,0 mods,s.accuracy,0 n300,0 n100,0 n50,0 nmiss,s.submitted_at,b.id map_id,b.set_id,b.artist,b.title,b.version FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id JOIN users u ON u.id=s.user_id WHERE s.passed=1 AND u.restricted=0 " ++
        "UNION ALL SELECT s.id,'stable',s.user_id,s.mode,s.pp,'',s.mods,s.accuracy,s.n300,s.n100,s.n50,s.nmiss,s.submitted_at,b.id,b.set_id,b.artist,b.title,b.version FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 JOIN users u ON u.id=s.user_id WHERE s.passed=1 AND u.restricted=0)," ++
        "best AS (SELECT user_id,map_id,mode,max(pp) pp FROM all_scores GROUP BY user_id,map_id,mode) " ++
        "SELECT a.id,a.source,a.mode,a.rank,a.mods,a.accuracy,a.n300,a.n100,a.n50,a.nmiss,strftime('%Y-%m-%dT%H:%M:%SZ',a.submitted_at,'unixepoch'),a.map_id,a.set_id,a.artist,a.title,a.version,u.name,1+(SELECT count(*) FROM best b WHERE b.map_id=a.map_id AND b.mode=a.mode AND b.pp>a.pp) placement FROM all_scores a JOIN users u ON u.id=a.user_id WHERE a.user_id=?1 ORDER BY a.submitted_at DESC,a.source ASC,a.id DESC LIMIT ?2 OFFSET ?3";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, limit);
    _ = c.sqlite3_bind_int(stmt, 3, offset);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var index: usize = 0;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (index != 0) try output.writer.writeByte(',');
        const stable = std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)), "stable");
        const mode: u8 = @intCast(c.sqlite3_column_int(stmt, 2));
        const rank = if (stable) stableGrade(mode, c.sqlite3_column_int(stmt, 4), c.sqlite3_column_double(stmt, 5), c.sqlite3_column_int(stmt, 6), c.sqlite3_column_int(stmt, 7), c.sqlite3_column_int(stmt, 8), c.sqlite3_column_int(stmt, 9)) else std.mem.span(c.sqlite3_column_text(stmt, 3));
        try output.writer.print("{{\"id\":{d},\"createdAt\":", .{@as(i64, @intCast(index + 1 + offset))});
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 10)));
        try output.writer.writeAll(",\"type\":\"rank\",\"scoreRank\":");
        try jsonString(&output.writer, rank);
        try output.writer.print(",\"rank\":{d},\"mode\":", .{c.sqlite3_column_int(stmt, 17)});
        try jsonString(&output.writer, switch (mode) {
            0 => "osu",
            1 => "taiko",
            2 => "fruits",
            3 => "mania",
            else => "osu",
        });
        var title_buf: [768]u8 = undefined;
        const map_title = try std.fmt.bufPrint(&title_buf, "{s} - {s} [{s}]", .{ std.mem.span(c.sqlite3_column_text(stmt, 13)), std.mem.span(c.sqlite3_column_text(stmt, 14)), std.mem.span(c.sqlite3_column_text(stmt, 15)) });
        try output.writer.writeAll(",\"beatmap\":{\"title\":");
        try jsonString(&output.writer, map_title);
        try output.writer.print(",\"url\":\"/b/{d}\"}},\"beatmapset\":{{\"title\":", .{c.sqlite3_column_int(stmt, 11)});
        var set_title_buf: [512]u8 = undefined;
        const set_title = try std.fmt.bufPrint(&set_title_buf, "{s} - {s}", .{ std.mem.span(c.sqlite3_column_text(stmt, 13)), std.mem.span(c.sqlite3_column_text(stmt, 14)) });
        try jsonString(&output.writer, set_title);
        try output.writer.print(",\"url\":\"/beatmapsets/{d}\"}},\"user\":{{\"username\":", .{c.sqlite3_column_int(stmt, 12)});
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 16)));
        try output.writer.print(",\"url\":\"/users/{d}\",\"previousUsername\":null}}}}", .{user_id});
        index += 1;
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn lazerUserScoresJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, ruleset_id: u8, kind: lazer.UserScoreKind, source: domain.SiteScoreSource, offset: u16, limit: u8) ![]u8 {
    if (limit == 0 or limit > 100) return error.InvalidScoreLimit;
    if (source == .scorev2) return error.InvalidScoreSource;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const canonical_combined = source == .all and (kind == .best or kind == .firsts);
    const filters = if (canonical_combined) .{
        "AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4)",
        "AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4)",
        if (kind == .best) "pp DESC,submitted_epoch DESC,id DESC" else "submitted_epoch DESC,id DESC",
    } else switch (kind) {
        .best => .{
            "AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4)",
            "AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4)",
            "pp DESC,submitted_epoch DESC,id DESC",
        },
        .firsts => .{
            "AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4) AND NOT EXISTS(SELECT 1 FROM lazer_scores o JOIN users ou ON ou.id=o.user_id WHERE o.beatmap_id=s.beatmap_id AND o.ruleset_id=s.ruleset_id AND o.rank_namespace=s.rank_namespace AND o.passed=1 AND o.best=1 AND ou.restricted=0 AND (o.total_score>s.total_score OR (o.total_score=s.total_score AND o.id<s.id)))",
            "AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4) AND NOT EXISTS(SELECT 1 FROM scores o JOIN users ou ON ou.id=o.user_id WHERE o.map_md5=s.map_md5 AND o.mode=s.mode AND o.rank_namespace=s.rank_namespace AND o.passed=1 AND o.best=1 AND ou.restricted=0 AND (o.score>s.score OR (o.score=s.score AND o.id<s.id)))",
            "submitted_epoch DESC,id DESC",
        },
        .recent => .{ "", "", "submitted_epoch DESC,id DESC" },
        .pinned => .{
            "AND EXISTS(SELECT 1 FROM profile_score_pins p WHERE p.user_id=s.user_id AND p.source='lazer' AND p.score_id=s.id)",
            "AND EXISTS(SELECT 1 FROM profile_score_pins p WHERE p.user_id=s.user_id AND p.source='stable' AND p.score_id=s.id)",
            "pin_epoch DESC,source ASC,id DESC",
        },
    };
    const lazer_pin_epoch = if (kind == .pinned) "(SELECT p.pinned_at FROM profile_score_pins p WHERE p.user_id=s.user_id AND p.source='lazer' AND p.score_id=s.id)" else "0";
    const stable_pin_epoch = if (kind == .pinned) "(SELECT p.pinned_at FROM profile_score_pins p WHERE p.user_id=s.user_id AND p.source='stable' AND p.score_id=s.id)" else "0";
    const lazer_owner_filter = if (source == .all and kind == .firsts) "s.ruleset_id=?2 AND u.restricted=0" else "s.user_id=?1 AND s.ruleset_id=?2";
    const stable_owner_filter = if (source == .all and kind == .firsts) "s.mode=?2 AND u.restricted=0" else "s.user_id=?1 AND s.mode=?2";
    const select_rows = if (source == .all and kind == .best)
        "),selected AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id,ruleset_id ORDER BY pp DESC,CASE source WHEN 'stable' THEN 0 ELSE 1 END,submitted_epoch DESC,id ASC) source_place FROM combined) SELECT * FROM selected WHERE source_place=1"
    else if (source == .all and kind == .firsts)
        "),user_best AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id,ruleset_id ORDER BY pp DESC,CASE source WHEN 'stable' THEN 0 ELSE 1 END,submitted_epoch DESC,id ASC) user_place FROM combined),board AS (SELECT *,row_number() OVER(PARTITION BY beatmap_id,ruleset_id ORDER BY total_score DESC,CASE source WHEN 'stable' THEN 0 ELSE 1 END,id ASC) board_place FROM user_best WHERE user_place=1) SELECT * FROM board WHERE user_id=?1 AND board_place=1"
    else
        ") SELECT * FROM combined";
    const sql = try std.fmt.allocPrint(allocator,
        \\WITH combined AS (
        \\SELECT 'lazer' source,s.id,s.user_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END country,s.beatmap_id,s.ruleset_id,s.total_score,s.total_score_without_mods total_without,s.legacy_total_score,s.pp,s.accuracy,s.max_combo,s.passed,s.rank,s.mods_json,s.statistics_json,s.maximum_statistics_json,s.pauses_json,strftime('%Y-%m-%dT%H:%M:%SZ',s.submitted_at,'unixepoch') ended_at,s.submitted_at submitted_epoch,b.status,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,s.passed=1 AND (length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)) has_replay,0 stable_mods,0 n300,0 n100,0 n50,0 ngeki,0 nkatu,0 nmiss,0 perfect,s.best preserve,{s} pin_epoch
        \\FROM lazer_scores s JOIN users u ON u.id=s.user_id JOIN beatmaps b ON b.id=s.beatmap_id WHERE {s} {s} {s}
        \\UNION ALL
        \\SELECT 'stable' source,4000000000000000000+s.id,s.user_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END country,b.id beatmap_id,s.mode ruleset_id,s.score total_score,s.score total_without,min(max(s.score,0),2147483647) legacy_total_score,s.pp,s.accuracy,s.max_combo,s.passed,'' rank,'[]' mods_json,'{{}}' statistics_json,'{{}}' maximum_statistics_json,'[]' pauses_json,strftime('%Y-%m-%dT%H:%M:%SZ',s.submitted_at,'unixepoch') ended_at,s.submitted_at submitted_epoch,b.status,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,s.passed=1 AND (length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)) has_replay,s.mods stable_mods,s.n300,s.n100,s.n50,s.ngeki,s.nkatu,s.nmiss,s.perfect,s.best preserve,{s} pin_epoch
        \\FROM scores s JOIN users u ON u.id=s.user_id JOIN beatmaps b ON b.md5=s.map_md5 WHERE {s} {s} {s}
        \\{s} ORDER BY {s} LIMIT ?3 OFFSET ?4
    , .{ lazer_pin_epoch, lazer_owner_filter, filters[0], if (source == .stable) "AND 0" else "", stable_pin_epoch, stable_owner_filter, filters[1], if (source == .lazer) "AND 0" else "", select_rows, filters[2] });
    defer allocator.free(sql);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, ruleset_id);
    _ = c.sqlite3_bind_int(stmt, 3, limit);
    _ = c.sqlite3_bind_int(stmt, 4, offset);

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var written: usize = 0;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (written != 0) try output.writer.writeByte(',');
        written += 1;
        const stable = std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)), "stable");
        const status = c.sqlite3_column_int(stmt, 21);
        var mods: std.Io.Writer.Allocating = .init(allocator);
        defer mods.deinit();
        var statistics: std.Io.Writer.Allocating = .init(allocator);
        defer statistics.deinit();
        if (stable) {
            try stable_mods.writeLazerJson(&mods.writer, c.sqlite3_column_int(stmt, 32), true);
            try stable_mods.writeLazerStatistics(&statistics.writer, ruleset_id, c.sqlite3_column_int(stmt, 33), c.sqlite3_column_int(stmt, 34), c.sqlite3_column_int(stmt, 35), c.sqlite3_column_int(stmt, 36), c.sqlite3_column_int(stmt, 37), c.sqlite3_column_int(stmt, 38));
        }
        try lazer.writeLeaderboardScore(&output.writer, .{
            .id = c.sqlite3_column_int64(stmt, 1),
            .legacy_score_id = if (stable) lazer.decodeStableScoreId(c.sqlite3_column_int64(stmt, 1)) else null,
            .legacy_total_score = if (stable) lazer.stableLegacyTotalScore(c.sqlite3_column_int64(stmt, 7)) else if (c.sqlite3_column_type(stmt, 9) == c.SQLITE_NULL) null else c.sqlite3_column_int(stmt, 9),
            .user_id = c.sqlite3_column_int(stmt, 2),
            .username = std.mem.span(c.sqlite3_column_text(stmt, 3)),
            .country = std.mem.span(c.sqlite3_column_text(stmt, 4)),
            .beatmap_id = c.sqlite3_column_int(stmt, 5),
            .ruleset_id = c.sqlite3_column_int(stmt, 6),
            .total_score = c.sqlite3_column_int64(stmt, 7),
            .total_score_without_mods = c.sqlite3_column_int64(stmt, 8),
            .pp = c.sqlite3_column_double(stmt, 10),
            .accuracy = c.sqlite3_column_double(stmt, 11),
            .max_combo = c.sqlite3_column_int(stmt, 12),
            .passed = c.sqlite3_column_int(stmt, 13) != 0,
            .rank = if (stable) stableGrade(ruleset_id, c.sqlite3_column_int(stmt, 32), c.sqlite3_column_double(stmt, 11), c.sqlite3_column_int(stmt, 33), c.sqlite3_column_int(stmt, 34), c.sqlite3_column_int(stmt, 35), c.sqlite3_column_int(stmt, 38)) else std.mem.span(c.sqlite3_column_text(stmt, 14)),
            .mods_json = if (stable) mods.written() else std.mem.span(c.sqlite3_column_text(stmt, 15)),
            .statistics_json = if (stable) statistics.written() else std.mem.span(c.sqlite3_column_text(stmt, 16)),
            .maximum_statistics_json = std.mem.span(c.sqlite3_column_text(stmt, 17)),
            .pauses_json = std.mem.span(c.sqlite3_column_text(stmt, 18)),
            .ended_at = std.mem.span(c.sqlite3_column_text(stmt, 19)),
            .ranked = status == 3 or status == 4,
            .preserve = c.sqlite3_column_int(stmt, 40) != 0,
            .has_replay = c.sqlite3_column_int(stmt, 31) != 0,
            .beatmap = .{
                .id = c.sqlite3_column_int(stmt, 5),
                .set_id = c.sqlite3_column_int(stmt, 22),
                .status = lazerStatus(status),
                .checksum = std.mem.span(c.sqlite3_column_text(stmt, 23)),
                .ruleset_id = c.sqlite3_column_int(stmt, 24),
                .star_rating = c.sqlite3_column_double(stmt, 25),
                .version = std.mem.span(c.sqlite3_column_text(stmt, 26)),
                .artist = std.mem.span(c.sqlite3_column_text(stmt, 27)),
                .title = std.mem.span(c.sqlite3_column_text(stmt, 28)),
                .creator = std.mem.span(c.sqlite3_column_text(stmt, 29)),
            },
        });
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn lazerScoreJson(self: *Store, allocator: std.mem.Allocator, score_id: i64, beatmap_id: i32) !?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = "SELECT s.id,s.user_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,s.beatmap_id,s.ruleset_id,s.total_score,s.total_score_without_mods,s.legacy_total_score,s.pp,s.accuracy,s.max_combo,s.passed,s.rank,s.mods_json,s.statistics_json,s.maximum_statistics_json,s.pauses_json,strftime('%Y-%m-%dT%H:%M:%SZ',s.submitted_at,'unixepoch'),b.status,(s.passed=1 AND (length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id))),b.set_id,b.md5,b.mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace FROM lazer_scores s JOIN users u ON u.id=s.user_id JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.id=?1 AND s.beatmap_id=?2 AND u.restricted=0";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, score_id);
    _ = c.sqlite3_bind_int(stmt, 2, beatmap_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const status = c.sqlite3_column_int(stmt, 19);
    const score: lazer.LeaderboardScore = .{
        .id = c.sqlite3_column_int64(stmt, 0),
        .legacy_total_score = if (c.sqlite3_column_type(stmt, 8) == c.SQLITE_NULL) null else c.sqlite3_column_int(stmt, 8),
        .user_id = c.sqlite3_column_int(stmt, 1),
        .username = std.mem.span(c.sqlite3_column_text(stmt, 2)),
        .country = std.mem.span(c.sqlite3_column_text(stmt, 3)),
        .beatmap_id = c.sqlite3_column_int(stmt, 4),
        .ruleset_id = c.sqlite3_column_int(stmt, 5),
        .total_score = c.sqlite3_column_int64(stmt, 6),
        .total_score_without_mods = c.sqlite3_column_int64(stmt, 7),
        .pp = c.sqlite3_column_double(stmt, 9),
        .accuracy = c.sqlite3_column_double(stmt, 10),
        .max_combo = c.sqlite3_column_int(stmt, 11),
        .passed = c.sqlite3_column_int(stmt, 12) != 0,
        .rank = std.mem.span(c.sqlite3_column_text(stmt, 13)),
        .mods_json = std.mem.span(c.sqlite3_column_text(stmt, 14)),
        .statistics_json = std.mem.span(c.sqlite3_column_text(stmt, 15)),
        .maximum_statistics_json = std.mem.span(c.sqlite3_column_text(stmt, 16)),
        .pauses_json = std.mem.span(c.sqlite3_column_text(stmt, 17)),
        .ended_at = std.mem.span(c.sqlite3_column_text(stmt, 18)),
        .ranked = status == 3 or status == 4,
        .has_replay = c.sqlite3_column_int(stmt, 20) != 0,
        .beatmap = .{
            .id = c.sqlite3_column_int(stmt, 4),
            .set_id = c.sqlite3_column_int(stmt, 21),
            .status = lazerStatus(status),
            .checksum = std.mem.span(c.sqlite3_column_text(stmt, 22)),
            .ruleset_id = c.sqlite3_column_int(stmt, 23),
            .star_rating = c.sqlite3_column_double(stmt, 24),
            .version = std.mem.span(c.sqlite3_column_text(stmt, 25)),
            .artist = std.mem.span(c.sqlite3_column_text(stmt, 26)),
            .title = std.mem.span(c.sqlite3_column_text(stmt, 27)),
            .creator = std.mem.span(c.sqlite3_column_text(stmt, 28)),
        },
    };
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try lazer.writeLeaderboardScore(&output.writer, score);
    return @as(?[]u8, try output.toOwnedSlice());
}
