const std = @import("std");
const domain = @import("../../../domain.zig");
const postgres = @import("../../../postgres.zig");
const storage_contracts = @import("../../contracts.zig");
const beatmap = @import("../../../beatmap.zig");
const lazer = @import("../../../lazer.zig");
const stable_mods = @import("../../../stable_mods.zig");
const user_json = @import("../../../user_json.zig");
const common = @import("../common.zig");
const pg_score_achievements = @import("../scores/achievements.zig");
const pg_score_maintenance = @import("../scores/maintenance.zig");

const ConsumedLazerScoreToken = storage_contracts.ConsumedLazerScoreToken;
const lazerStatus = storage_contracts.lazerStatus;

pub fn consumedLazerScoreToken(self: anytype, user_id: i32, beatmap_id: i32, token_id: i64) !?ConsumedLazerScoreToken {
    var buffers: [3][64]u8 = undefined;
    var cursor: usize = 0;
    const token = try common.param(&buffers, &cursor, token_id);
    const user = try common.param(&buffers, &cursor, user_id);
    const map = try common.param(&buffers, &cursor, beatmap_id);
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT t.score_id,s.total_score,s.accuracy,s.max_combo,s.passed FROM zigcho.lazer_score_tokens t JOIN zigcho.lazer_scores s ON s.id=t.score_id WHERE t.id=$1 AND t.user_id=$2 AND t.beatmap_id=$3 AND t.consumed_at IS NOT NULL", &.{ token, user, map });
    defer result.deinit();
    if (result.rows() == 0) return null;
    return .{
        .score_id = try result.int(i64, 0, 0),
        .total_score = try result.int(i64, 0, 1),
        .accuracy = try result.float(f64, 0, 2),
        .max_combo = try result.int(i32, 0, 3),
        .passed = try result.boolean(0, 4),
    };
}

pub fn lazerRankingsJson(self: anytype, allocator: std.mem.Allocator, ruleset_id: u8, kind: lazer.RankingKind, country_filter: ?[]const u8, page: u16) ![]u8 {
    if (page == 0) return error.InvalidPage;
    var mode_buf: [4]u8 = undefined;
    var offset_buf: [16]u8 = undefined;
    const mode = try std.fmt.bufPrint(&mode_buf, "{d}", .{ruleset_id});
    const offset = try std.fmt.bufPrint(&offset_buf, "{d}", .{(@as(u32, page) - 1) * 50});
    var lease = self.pool.acquire();
    defer lease.release();
    const country_sql =
        "WITH visible AS (SELECT CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,s.plays,s.ranked_score,s.pp FROM zigcho.stats s JOIN zigcho.users u ON u.id=s.user_id WHERE s.mode=$1 AND s.plays>0 AND u.id!=3 AND NOT u.restricted AND u.show_profile_stats) " ++
        "SELECT country,count(*),sum(plays),sum(ranked_score),sum(pp) FROM visible WHERE country!='XX' GROUP BY country ORDER BY sum(pp) DESC,country ASC LIMIT 50 OFFSET $2";
    const performance_sql =
        "WITH visible AS (SELECT u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,u.privileges,s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,least((SELECT count(*) FROM zigcho.score_replay_views v WHERE v.owner_id=u.id AND v.mode=s.mode AND v.rank_namespace='vanilla'),2147483647)::int replay_views," ++
        "row_number() OVER(ORDER BY s.pp DESC,u.id ASC) global_rank,row_number() OVER(PARTITION BY CASE WHEN u.show_country THEN u.country ELSE 'XX' END ORDER BY s.pp DESC,u.id ASC) country_rank " ++
        "FROM zigcho.stats s JOIN zigcho.users u ON u.id=s.user_id WHERE s.mode=$1 AND s.plays>0 AND u.id!=3 AND NOT u.restricted AND u.show_profile_stats) " ++
        "SELECT * FROM visible WHERE ($2='' OR country=$2) ORDER BY pp DESC,id ASC LIMIT 50 OFFSET $3";
    const score_sql =
        "WITH visible AS (SELECT u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,u.privileges,s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,least((SELECT count(*) FROM zigcho.score_replay_views v WHERE v.owner_id=u.id AND v.mode=s.mode AND v.rank_namespace='vanilla'),2147483647)::int replay_views," ++
        "row_number() OVER(ORDER BY s.total_score DESC,u.id ASC) global_rank,row_number() OVER(PARTITION BY CASE WHEN u.show_country THEN u.country ELSE 'XX' END ORDER BY s.total_score DESC,u.id ASC) country_rank " ++
        "FROM zigcho.stats s JOIN zigcho.users u ON u.id=s.user_id WHERE s.mode=$1 AND s.plays>0 AND u.id!=3 AND NOT u.restricted AND u.show_profile_stats) " ++
        "SELECT * FROM visible WHERE ($2='' OR country=$2) ORDER BY total_score DESC,id ASC LIMIT 50 OFFSET $3";
    var result = switch (kind) {
        .country => try postgres.queryParams(allocator, lease.conn, country_sql, &.{ mode, offset }),
        .performance => try postgres.queryParams(allocator, lease.conn, performance_sql, &.{ mode, country_filter orelse "", offset }),
        .score => try postgres.queryParams(allocator, lease.conn, score_sql, &.{ mode, country_filter orelse "", offset }),
    };
    defer result.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"ranking\":[");
    for (0..result.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        if (kind == .country) {
            try output.writer.writeAll("{\"code\":");
            try common.jsonString(&output.writer, result.value(row, 0));
            try output.writer.print(",\"active_users\":{d},\"play_count\":{d},\"ranked_score\":{d},\"performance\":{d}}}", .{ try result.int(i32, row, 1), try result.int(i64, row, 2), try result.int(i64, row, 3), try result.int(i64, row, 4) });
            continue;
        }
        const country_text = result.value(row, 2);
        const cc: [2]u8 = if (country_text.len == 2) .{ country_text[0], country_text[1] } else .{ 'X', 'X' };
        const user: domain.User = .{ .id = try result.int(i32, row, 0), .name = result.value(row, 1), .safe_name = "", .country = cc, .privileges = try result.int(u32, row, 3) };
        const stats: domain.Stats = .{ .mode = @enumFromInt(ruleset_id), .ranked_score = try result.int(i64, row, 4), .total_score = try result.int(i64, row, 5), .pp = try result.int(i32, row, 6), .plays = try result.int(i32, row, 7), .play_time = try result.int(i32, row, 8), .total_hits = try result.int(i64, row, 9), .accuracy = try result.float(f64, row, 10), .max_combo = try result.int(i32, row, 11), .replay_views = try result.int(i32, row, 12) };
        try user_json.writeRankingStatistics(&output.writer, user, stats, try result.int(i32, row, 13), try result.int(i32, row, 14));
    }
    try output.writer.writeAll("],\"cursor\":null}");
    return output.toOwnedSlice();
}

pub fn lazerUserScoreCounts(self: anytype, user_id: i32, ruleset_id: u8, source: domain.SiteScoreSource) !domain.UserScoreCounts {
    if (source == .scorev2) return error.InvalidScoreSource;
    var user_buf: [24]u8 = undefined;
    var ruleset_buf: [4]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const ruleset = try std.fmt.bufPrint(&ruleset_buf, "{d}", .{ruleset_id});
    const source_name = @tagName(source);
    var lease = self.pool.acquire();
    defer lease.release();
    const sql = if (source == .all)
        "WITH candidates AS (" ++
            "SELECT s.user_id,b.id beatmap_id,s.ruleset_id mode,s.total_score,s.pp,1 source_order,s.id source_id,s.submitted_at FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id JOIN zigcho.users u ON u.id=s.user_id WHERE $3='all' AND s.ruleset_id=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4) AND NOT u.restricted " ++
            "UNION ALL SELECT s.user_id,b.id,s.mode,s.score,s.pp,0,s.id,s.submitted_at FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 JOIN zigcho.users u ON u.id=s.user_id WHERE $3='all' AND s.mode=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4) AND NOT u.restricted)," ++
            "user_best AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id,mode ORDER BY pp DESC,source_order ASC,submitted_at DESC,source_id ASC) source_place FROM candidates)," ++
            "board AS (SELECT *,row_number() OVER(PARTITION BY beatmap_id,mode ORDER BY total_score DESC,source_order ASC,source_id ASC) board_place FROM user_best WHERE source_place=1) " ++
            "SELECT (SELECT count(*) FROM user_best WHERE user_id=$1 AND source_place=1),(SELECT count(*) FROM board WHERE user_id=$1 AND board_place=1)," ++
            "(SELECT count(*) FROM zigcho.lazer_scores WHERE user_id=$1 AND ruleset_id=$2)+(SELECT count(*) FROM zigcho.scores WHERE user_id=$1 AND mode=$2)," ++
            "(SELECT count(*) FROM zigcho.profile_score_pins WHERE user_id=$1 AND mode=$2)"
    else
        "SELECT " ++
            "(SELECT count(*) FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE $3!='stable' AND s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4))+(SELECT count(*) FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE $3!='lazer' AND s.user_id=$1 AND s.mode=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4))," ++
            "(SELECT count(*) FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE $3!='stable' AND s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4) AND NOT EXISTS(SELECT 1 FROM zigcho.lazer_scores o JOIN zigcho.users ou ON ou.id=o.user_id WHERE o.beatmap_id=s.beatmap_id AND o.ruleset_id=s.ruleset_id AND o.rank_namespace=s.rank_namespace AND o.passed AND o.best AND NOT ou.restricted AND (o.total_score>s.total_score OR (o.total_score=s.total_score AND o.id<s.id))))+(SELECT count(*) FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE $3!='lazer' AND s.user_id=$1 AND s.mode=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4) AND NOT EXISTS(SELECT 1 FROM zigcho.scores o JOIN zigcho.users ou ON ou.id=o.user_id WHERE o.map_md5=s.map_md5 AND o.mode=s.mode AND o.rank_namespace=s.rank_namespace AND o.passed AND o.best AND NOT ou.restricted AND (o.score>s.score OR (o.score=s.score AND o.id<s.id))))," ++
            "(SELECT count(*) FROM zigcho.lazer_scores WHERE $3!='stable' AND user_id=$1 AND ruleset_id=$2)+(SELECT count(*) FROM zigcho.scores WHERE $3!='lazer' AND user_id=$1 AND mode=$2)," ++
            "(SELECT count(*) FROM zigcho.profile_score_pins p WHERE p.user_id=$1 AND p.mode=$2 AND p.source=$3)";
    var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{ user, ruleset, source_name });
    defer result.deinit();
    return .{
        .best = try result.int(i32, 0, 0),
        .firsts = try result.int(i32, 0, 1),
        .recent = try result.int(i32, 0, 2),
        .pinned = try result.int(i32, 0, 3),
    };
}

pub fn lazerRecentActivityJson(self: anytype, allocator: std.mem.Allocator, user_id: i32, offset: u16, limit: u8) ![]u8 {
    if (limit == 0 or limit > 100) return error.InvalidScoreLimit;
    var user_buf: [24]u8 = undefined;
    var limit_buf: [8]u8 = undefined;
    var offset_buf: [16]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
    const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
    const sql =
        "WITH all_scores AS (" ++
        "SELECT s.id,'lazer'::text source,s.user_id,s.ruleset_id mode,s.pp,s.rank,0 mods,s.accuracy,0 n300,0 n100,0 n50,0 nmiss,s.submitted_at,b.id map_id,b.set_id,b.artist,b.title,b.version FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id JOIN zigcho.users u ON u.id=s.user_id WHERE s.passed AND NOT u.restricted " ++
        "UNION ALL SELECT s.id,'stable',s.user_id,s.mode,s.pp,''::text,s.mods,s.accuracy,s.n300,s.n100,s.n50,s.nmiss,s.submitted_at,b.id,b.set_id,b.artist,b.title,b.version FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 JOIN zigcho.users u ON u.id=s.user_id WHERE s.passed AND NOT u.restricted)," ++
        "best AS (SELECT user_id,map_id,mode,max(pp) pp FROM all_scores GROUP BY user_id,map_id,mode) " ++
        "SELECT a.id,a.source,a.mode,a.rank,a.mods,a.accuracy,a.n300,a.n100,a.n50,a.nmiss,to_char(to_timestamp(a.submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),a.map_id,a.set_id,a.artist,a.title,a.version,u.name,1+(SELECT count(*) FROM best b WHERE b.map_id=a.map_id AND b.mode=a.mode AND b.pp>a.pp) placement FROM all_scores a JOIN zigcho.users u ON u.id=a.user_id WHERE a.user_id=$1 ORDER BY a.submitted_at DESC,a.source ASC,a.id DESC LIMIT $2 OFFSET $3";
    var lease = self.pool.acquire();
    defer lease.release();
    var rows = try postgres.queryParams(allocator, lease.conn, sql, &.{ user, limit_text, offset_text });
    defer rows.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    for (0..rows.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        const stable = std.mem.eql(u8, rows.value(row, 1), "stable");
        const mode = try rows.int(u8, row, 2);
        const rank = if (stable) storage_contracts.stableGrade(mode, try rows.int(i32, row, 4), try rows.float(f64, row, 5), try rows.int(i32, row, 6), try rows.int(i32, row, 7), try rows.int(i32, row, 8), try rows.int(i32, row, 9)) else rows.value(row, 3);
        try output.writer.print("{{\"id\":{d},\"createdAt\":", .{@as(i64, @intCast(row + 1 + offset))});
        try common.jsonString(&output.writer, rows.value(row, 10));
        try output.writer.writeAll(",\"type\":\"rank\",\"scoreRank\":");
        try common.jsonString(&output.writer, rank);
        try output.writer.print(",\"rank\":{d},\"mode\":", .{try rows.int(i32, row, 17)});
        try common.jsonString(&output.writer, switch (mode) {
            0 => "osu",
            1 => "taiko",
            2 => "fruits",
            3 => "mania",
            else => "osu",
        });
        var title_buf: [768]u8 = undefined;
        const map_title = try std.fmt.bufPrint(&title_buf, "{s} - {s} [{s}]", .{ rows.value(row, 13), rows.value(row, 14), rows.value(row, 15) });
        try output.writer.writeAll(",\"beatmap\":{\"title\":");
        try common.jsonString(&output.writer, map_title);
        try output.writer.print(",\"url\":\"/b/{d}\"}},\"beatmapset\":{{\"title\":", .{try rows.int(i32, row, 11)});
        var set_title_buf: [512]u8 = undefined;
        const set_title = try std.fmt.bufPrint(&set_title_buf, "{s} - {s}", .{ rows.value(row, 13), rows.value(row, 14) });
        try common.jsonString(&output.writer, set_title);
        try output.writer.print(",\"url\":\"/beatmapsets/{d}\"}},\"user\":{{\"username\":", .{try rows.int(i32, row, 12)});
        try common.jsonString(&output.writer, rows.value(row, 16));
        try output.writer.print(",\"url\":\"/users/{d}\",\"previousUsername\":null}}}}", .{user_id});
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn lazerUserScoresJson(self: anytype, allocator: std.mem.Allocator, user_id: i32, ruleset_id: u8, kind: lazer.UserScoreKind, source: domain.SiteScoreSource, offset: u16, limit: u8) ![]u8 {
    if (limit == 0 or limit > 100) return error.InvalidScoreLimit;
    if (source == .scorev2) return error.InvalidScoreSource;
    var buffers: [4][24]u8 = undefined;
    const user = try std.fmt.bufPrint(&buffers[0], "{d}", .{user_id});
    const ruleset = try std.fmt.bufPrint(&buffers[1], "{d}", .{ruleset_id});
    const limit_text = try std.fmt.bufPrint(&buffers[2], "{d}", .{limit});
    const offset_text = try std.fmt.bufPrint(&buffers[3], "{d}", .{offset});
    const canonical_combined = source == .all and (kind == .best or kind == .firsts);
    const filters = if (canonical_combined) .{
        "AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4)",
        "AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4)",
        if (kind == .best) "pp DESC,submitted_epoch DESC,id DESC" else "submitted_epoch DESC,id DESC",
    } else switch (kind) {
        .best => .{
            "AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4)",
            "AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4)",
            "pp DESC,submitted_epoch DESC,id DESC",
        },
        .firsts => .{
            "AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4) AND NOT EXISTS(SELECT 1 FROM zigcho.lazer_scores o JOIN zigcho.users ou ON ou.id=o.user_id WHERE o.beatmap_id=s.beatmap_id AND o.ruleset_id=s.ruleset_id AND o.rank_namespace=s.rank_namespace AND o.passed AND o.best AND NOT ou.restricted AND (o.total_score>s.total_score OR (o.total_score=s.total_score AND o.id<s.id)))",
            "AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4) AND NOT EXISTS(SELECT 1 FROM zigcho.scores o JOIN zigcho.users ou ON ou.id=o.user_id WHERE o.map_md5=s.map_md5 AND o.mode=s.mode AND o.rank_namespace=s.rank_namespace AND o.passed AND o.best AND NOT ou.restricted AND (o.score>s.score OR (o.score=s.score AND o.id<s.id)))",
            "submitted_epoch DESC,id DESC",
        },
        .recent => .{ "", "", "submitted_epoch DESC,id DESC" },
        .pinned => .{
            "AND EXISTS(SELECT 1 FROM zigcho.profile_score_pins p WHERE p.user_id=s.user_id AND p.source='lazer' AND p.score_id=s.id)",
            "AND EXISTS(SELECT 1 FROM zigcho.profile_score_pins p WHERE p.user_id=s.user_id AND p.source='stable' AND p.score_id=s.id)",
            "pin_epoch DESC,source ASC,id DESC",
        },
    };
    const lazer_pin_epoch = if (kind == .pinned) "(SELECT p.pinned_at FROM zigcho.profile_score_pins p WHERE p.user_id=s.user_id AND p.source='lazer' AND p.score_id=s.id)" else "0";
    const stable_pin_epoch = if (kind == .pinned) "(SELECT p.pinned_at FROM zigcho.profile_score_pins p WHERE p.user_id=s.user_id AND p.source='stable' AND p.score_id=s.id)" else "0";
    const lazer_owner_filter = if (source == .all and kind == .firsts) "s.ruleset_id=$2 AND NOT u.restricted" else "s.user_id=$1 AND s.ruleset_id=$2";
    const stable_owner_filter = if (source == .all and kind == .firsts) "s.mode=$2 AND NOT u.restricted" else "s.user_id=$1 AND s.mode=$2";
    const select_rows = if (source == .all and kind == .best)
        "),selected AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id,ruleset_id ORDER BY pp DESC,CASE source WHEN 'stable' THEN 0 ELSE 1 END,submitted_epoch DESC,id ASC) source_place FROM combined) SELECT * FROM selected WHERE source_place=1"
    else if (source == .all and kind == .firsts)
        "),user_best AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id,ruleset_id ORDER BY pp DESC,CASE source WHEN 'stable' THEN 0 ELSE 1 END,submitted_epoch DESC,id ASC) user_place FROM combined),board AS (SELECT *,row_number() OVER(PARTITION BY beatmap_id,ruleset_id ORDER BY total_score DESC,CASE source WHEN 'stable' THEN 0 ELSE 1 END,id ASC) board_place FROM user_best WHERE user_place=1) SELECT * FROM board WHERE user_id=$1 AND board_place=1"
    else
        ") SELECT * FROM combined";
    const sql = try std.fmt.allocPrintSentinel(allocator,
        \\WITH combined AS (
        \\SELECT 'lazer'::text source,s.id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,s.beatmap_id,s.ruleset_id,s.total_score,s.total_score_without_mods total_without,s.legacy_total_score,s.pp,s.accuracy,s.max_combo,s.passed,s.rank,s.mods_json::text,s.statistics_json::text,s.maximum_statistics_json::text,s.pauses_json::text,to_char(to_timestamp(s.submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') ended_at,s.submitted_at submitted_epoch,b.status,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)) has_replay,0 stable_mods,0 n300,0 n100,0 n50,0 ngeki,0 nkatu,0 nmiss,false perfect,s.best preserve,{s}::bigint pin_epoch
        \\FROM zigcho.lazer_scores s JOIN zigcho.users u ON u.id=s.user_id JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE {s} {s} {s}
        \\UNION ALL
        \\SELECT 'stable'::text source,4000000000000000000+s.id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,b.id beatmap_id,s.mode ruleset_id,s.score total_score,s.score total_without,least(greatest(s.score,0),2147483647)::integer legacy_total_score,s.pp,s.accuracy,s.max_combo,s.passed,''::text rank,'[]'::text mods_json,'{{}}'::text statistics_json,'{{}}'::text maximum_statistics_json,'[]'::text pauses_json,to_char(to_timestamp(s.submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') ended_at,s.submitted_at submitted_epoch,b.status,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)) has_replay,s.mods stable_mods,s.n300,s.n100,s.n50,s.ngeki,s.nkatu,s.nmiss,s.perfect,s.best preserve,{s}::bigint pin_epoch
        \\FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE {s} {s} {s}
        \\{s} ORDER BY {s} LIMIT $3 OFFSET $4
    , .{ lazer_pin_epoch, lazer_owner_filter, filters[0], if (source == .stable) "AND false" else "", stable_pin_epoch, stable_owner_filter, filters[1], if (source == .lazer) "AND false" else "", select_rows, filters[2] }, 0);
    defer allocator.free(sql);
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(allocator, lease.conn, sql, &.{ user, ruleset, limit_text, offset_text });
    defer result.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    for (0..result.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        const stable = std.mem.eql(u8, result.value(row, 0), "stable");
        const status = try result.int(i32, row, 21);
        var mods: std.Io.Writer.Allocating = .init(allocator);
        defer mods.deinit();
        var statistics: std.Io.Writer.Allocating = .init(allocator);
        defer statistics.deinit();
        if (stable) {
            try stable_mods.writeLazerJson(&mods.writer, try result.int(i32, row, 32), true);
            try stable_mods.writeLazerStatistics(&statistics.writer, ruleset_id, try result.int(i32, row, 33), try result.int(i32, row, 34), try result.int(i32, row, 35), try result.int(i32, row, 36), try result.int(i32, row, 37), try result.int(i32, row, 38));
        }
        try lazer.writeLeaderboardScore(&output.writer, .{
            .id = try result.int(i64, row, 1),
            .legacy_score_id = if (stable) lazer.decodeStableScoreId(try result.int(i64, row, 1)) else null,
            .legacy_total_score = if (stable) lazer.stableLegacyTotalScore(try result.int(i64, row, 7)) else if (result.isNull(row, 9)) null else try result.int(i32, row, 9),
            .user_id = try result.int(i32, row, 2),
            .username = result.value(row, 3),
            .country = result.value(row, 4),
            .beatmap_id = try result.int(i32, row, 5),
            .ruleset_id = try result.int(i32, row, 6),
            .total_score = try result.int(i64, row, 7),
            .total_score_without_mods = try result.int(i64, row, 8),
            .pp = try result.float(f64, row, 10),
            .accuracy = try result.float(f64, row, 11),
            .max_combo = try result.int(i32, row, 12),
            .passed = try result.boolean(row, 13),
            .rank = if (stable) storage_contracts.stableGrade(ruleset_id, try result.int(i32, row, 32), try result.float(f64, row, 11), try result.int(i32, row, 33), try result.int(i32, row, 34), try result.int(i32, row, 35), try result.int(i32, row, 38)) else result.value(row, 14),
            .mods_json = if (stable) mods.written() else result.value(row, 15),
            .statistics_json = if (stable) statistics.written() else result.value(row, 16),
            .maximum_statistics_json = result.value(row, 17),
            .pauses_json = result.value(row, 18),
            .ended_at = result.value(row, 19),
            .ranked = status == 3 or status == 4,
            .preserve = try result.boolean(row, 40),
            .has_replay = try result.boolean(row, 31),
            .beatmap = .{
                .id = try result.int(i32, row, 5),
                .set_id = try result.int(i32, row, 22),
                .status = lazerStatus(status),
                .checksum = result.value(row, 23),
                .ruleset_id = try result.int(i32, row, 24),
                .star_rating = try result.float(f64, row, 25),
                .version = result.value(row, 26),
                .artist = result.value(row, 27),
                .title = result.value(row, 28),
                .creator = result.value(row, 29),
            },
        });
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn lazerLeaderboardJson(self: anytype, allocator: std.mem.Allocator, requester_id: i32, beatmap_id: i32, ruleset_id: u8, namespace: lazer.Namespace, exact_mods_json: []const u8, filter_mods: bool, classic: bool, requested_stable_mods: ?i32, scope: lazer.LeaderboardScope, limit: u8) ![]u8 {
    var buffers: [32][64]u8 = undefined;
    var cursor: usize = 0;
    const requester = try common.param(&buffers, &cursor, requester_id);
    const beatmap_text = try common.param(&buffers, &cursor, beatmap_id);
    const ruleset = try common.param(&buffers, &cursor, ruleset_id);
    const limit_text = try common.param(&buffers, &cursor, limit);
    const filter = if (filter_mods) "true" else "false";
    const classic_only = if (classic) "true" else "false";
    const stable_supported = if (requested_stable_mods != null) "true" else "false";
    const stable_bits = try common.param(&buffers, &cursor, requested_stable_mods orelse 0);
    const namespace_name = @tagName(namespace);
    var lease = self.pool.acquire();
    defer lease.release();
    const sql =
        "WITH candidates AS (" ++
        "SELECT 'lazer'::text source,s.id source_id,s.id public_id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,s.beatmap_id,s.ruleset_id,s.total_score,s.total_score_without_mods total_without,s.legacy_total_score,s.pp,s.accuracy,s.max_combo,s.passed,s.rank,s.mods_json::text,s.statistics_json::text,s.maximum_statistics_json::text,s.pauses_json::text,to_char(to_timestamp(s.submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') ended_at,b.status,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)) has_replay,0 stable_mods,0 n300,0 n100,0 n50,0 ngeki,0 nkatu,0 nmiss,false perfect,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,1 source_order,tm.team_id,t.name team_name,t.short_name team_short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0) team_flag_version " ++
        "FROM zigcho.lazer_scores s JOIN zigcho.users u ON u.id=s.user_id LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id JOIN zigcho.beatmaps b ON b.id=s.beatmap_id " ++
        "WHERE s.beatmap_id=$1 AND b.status>=3 AND s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed AND NOT u.restricted AND NOT $6::boolean AND NOT EXISTS(SELECT 1 FROM zigcho.beatmap_rank_events veto_event WHERE veto_event.set_id=b.set_id AND veto_event.id=(SELECT max(latest_event.id) FROM zigcho.beatmap_rank_events latest_event WHERE latest_event.set_id=b.set_id) AND veto_event.action='veto') " ++
        "AND ($11='global' OR ($11='country' AND u.country=(SELECT country FROM zigcho.users WHERE id=$10)) OR ($11='friend' AND (s.user_id=$10 OR EXISTS(SELECT 1 FROM zigcho.friends f JOIN zigcho.users friend_sender ON friend_sender.id=f.user_id JOIN zigcho.users friend_target ON friend_target.id=f.friend_id WHERE f.user_id=$10 AND f.friend_id=s.user_id AND friend_sender.id!=friend_target.id AND friend_target.id!=3 AND NOT friend_sender.restricted AND NOT friend_target.restricted))) OR ($11='team' AND tm.team_id IS NOT NULL AND tm.team_id=(SELECT team_id FROM zigcho.team_members WHERE user_id=$10))) " ++
        "AND (NOT $5::boolean OR (" ++
        "NOT EXISTS(SELECT upper(stored.value->>'acronym') FROM jsonb_array_elements(s.mods_json) stored WHERE $3!='custom' OR upper(stored.value->>'acronym') NOT IN('RX','AP') EXCEPT SELECT upper(value) FROM jsonb_array_elements_text($4::jsonb) WHERE $3!='custom' OR upper(value) NOT IN('RX','AP')) " ++
        "AND NOT EXISTS(SELECT upper(value) FROM jsonb_array_elements_text($4::jsonb) WHERE $3!='custom' OR upper(value) NOT IN('RX','AP') EXCEPT SELECT upper(stored.value->>'acronym') FROM jsonb_array_elements(s.mods_json) stored WHERE $3!='custom' OR upper(stored.value->>'acronym') NOT IN('RX','AP')))) " ++
        "UNION ALL " ++
        "SELECT 'stable'::text source,s.id source_id,4000000000000000000+s.id public_id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,b.id beatmap_id,s.mode ruleset_id,s.score total_score,s.score total_without,least(greatest(s.score,0),2147483647)::integer legacy_total_score,s.pp,s.accuracy,s.max_combo,s.passed,''::text rank,'[]'::text mods_json,'{}'::text statistics_json,'{}'::text maximum_statistics_json,'[]'::text pauses_json,to_char(to_timestamp(s.submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') ended_at,b.status,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)) has_replay,s.mods stable_mods,s.n300,s.n100,s.n50,s.ngeki,s.nkatu,s.nmiss,s.perfect,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,0 source_order,tm.team_id,t.name team_name,t.short_name team_short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0) team_flag_version " ++
        "FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id JOIN zigcho.beatmaps b ON b.md5=s.map_md5 " ++
        "WHERE b.id=$1 AND b.status>=3 AND s.mode=$2 AND s.rank_namespace=$3 AND s.passed AND NOT u.restricted AND $3!='custom' AND $7::boolean AND (NOT $5::boolean OR (s.mods & $12::integer)=$8) AND NOT EXISTS(SELECT 1 FROM zigcho.beatmap_rank_events veto_event WHERE veto_event.set_id=b.set_id AND veto_event.id=(SELECT max(latest_event.id) FROM zigcho.beatmap_rank_events latest_event WHERE latest_event.set_id=b.set_id) AND veto_event.action='veto') " ++
        "AND ($11='global' OR ($11='country' AND u.country=(SELECT country FROM zigcho.users WHERE id=$10)) OR ($11='friend' AND (s.user_id=$10 OR EXISTS(SELECT 1 FROM zigcho.friends f JOIN zigcho.users friend_sender ON friend_sender.id=f.user_id JOIN zigcho.users friend_target ON friend_target.id=f.friend_id WHERE f.user_id=$10 AND f.friend_id=s.user_id AND friend_sender.id!=friend_target.id AND friend_target.id!=3 AND NOT friend_sender.restricted AND NOT friend_target.restricted))) OR ($11='team' AND tm.team_id IS NOT NULL AND tm.team_id=(SELECT team_id FROM zigcho.team_members WHERE user_id=$10))))," ++
        "ordered AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY CASE WHEN rank_namespace IN('vanilla','relax','autopilot') THEN pp ELSE total_score::double precision END DESC,source_order,source_id) user_place FROM candidates)," ++
        "board AS (SELECT *,row_number() OVER(ORDER BY CASE WHEN rank_namespace IN('relax','autopilot') THEN pp ELSE total_score::double precision END DESC,source_order,source_id) position,count(*) OVER() score_count FROM ordered WHERE user_place=1) " ++
        "SELECT position,score_count,source,public_id,user_id,name,country,beatmap_id,ruleset_id,total_score,total_without,legacy_total_score,pp,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,ended_at,status,has_replay,stable_mods,n300,n100,n50,ngeki,nkatu,nmiss,perfect,set_id,md5,map_mode,star_rating,version,artist,title,creator,rank_namespace,team_id,team_name,team_short_name,team_flag_version " ++
        "FROM board WHERE position<=$9 OR user_id=$10 ORDER BY position";
    const gameplay_mask = try common.param(&buffers, &cursor, stable_mods.leaderboard_gameplay_mask);
    var result = try postgres.queryParams(allocator, lease.conn, sql, &.{ beatmap_text, ruleset, namespace_name, exact_mods_json, filter, classic_only, stable_supported, stable_bits, limit_text, requester, @tagName(scope), gameplay_mask });
    defer result.deinit();

    var scores: std.Io.Writer.Allocating = .init(allocator);
    defer scores.deinit();
    var user_score: ?[]u8 = null;
    defer if (user_score) |json| allocator.free(json);
    var score_count: i64 = 0;
    var written: usize = 0;
    for (0..result.rows()) |row| {
        const position = try result.int(i64, row, 0);
        score_count = try result.int(i64, row, 1);
        const stable = std.mem.eql(u8, result.value(row, 2), "stable");
        var mods: std.Io.Writer.Allocating = .init(allocator);
        defer mods.deinit();
        var statistics: std.Io.Writer.Allocating = .init(allocator);
        defer statistics.deinit();
        if (stable) {
            try stable_mods.writeLazerJson(&mods.writer, try result.int(i32, row, 24), true);
            try stable_mods.writeLazerStatistics(&statistics.writer, ruleset_id, try result.int(i32, row, 25), try result.int(i32, row, 26), try result.int(i32, row, 27), try result.int(i32, row, 28), try result.int(i32, row, 29), try result.int(i32, row, 30));
        }
        const score: lazer.LeaderboardScore = .{
            .id = try result.int(i64, row, 3),
            .legacy_score_id = if (stable) lazer.decodeStableScoreId(try result.int(i64, row, 3)) else null,
            .legacy_total_score = if (stable) lazer.stableLegacyTotalScore(try result.int(i64, row, 9)) else if (result.isNull(row, 11)) null else try result.int(i32, row, 11),
            .user_id = try result.int(i32, row, 4),
            .username = result.value(row, 5),
            .country = result.value(row, 6),
            .beatmap_id = try result.int(i32, row, 7),
            .ruleset_id = try result.int(i32, row, 8),
            .total_score = try result.int(i64, row, 9),
            .total_score_without_mods = try result.int(i64, row, 10),
            .pp = try result.float(f64, row, 12),
            .accuracy = try result.float(f64, row, 13),
            .max_combo = try result.int(i32, row, 14),
            .passed = try result.boolean(row, 15),
            .rank = if (stable) storage_contracts.stableGrade(ruleset_id, try result.int(i32, row, 24), try result.float(f64, row, 13), try result.int(i32, row, 25), try result.int(i32, row, 26), try result.int(i32, row, 27), try result.int(i32, row, 30)) else result.value(row, 16),
            .mods_json = if (stable) mods.written() else result.value(row, 17),
            .statistics_json = if (stable) statistics.written() else result.value(row, 18),
            .maximum_statistics_json = result.value(row, 19),
            .pauses_json = result.value(row, 20),
            .ended_at = result.value(row, 21),
            .ranked = (try result.int(i32, row, 22)) == 3 or (try result.int(i32, row, 22)) == 4,
            .has_replay = try result.boolean(row, 23),
            .team = if (result.isNull(row, 41)) null else try domain.TeamSummary.init(try result.int(i32, row, 41), result.value(row, 42), result.value(row, 43), try result.int(i64, row, 44)),
            .beatmap = .{
                .id = try result.int(i32, row, 7),
                .set_id = try result.int(i32, row, 32),
                .status = lazerStatus(try result.int(i32, row, 22)),
                .checksum = result.value(row, 33),
                .ruleset_id = try result.int(i32, row, 34),
                .star_rating = try result.float(f64, row, 35),
                .version = result.value(row, 36),
                .artist = result.value(row, 37),
                .title = result.value(row, 38),
                .creator = result.value(row, 39),
            },
        };
        if (position <= limit) {
            if (written != 0) try scores.writer.writeByte(',');
            try lazer.writeLeaderboardScore(&scores.writer, score);
            written += 1;
        }
        if (score.user_id == requester_id and (!stable or user_score == null)) {
            if (user_score) |json| allocator.free(json);
            var own: std.Io.Writer.Allocating = .init(allocator);
            errdefer own.deinit();
            try own.writer.print("{{\"position\":{d},\"score\":", .{position});
            try lazer.writeLeaderboardScore(&own.writer, score);
            try own.writer.writeByte('}');
            user_score = try own.toOwnedSlice();
        }
    }

    const score_rows_json = try scores.toOwnedSlice();
    defer allocator.free(score_rows_json);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"score_count\":{d},\"scores\":[", .{score_count});
    try output.writer.writeAll(score_rows_json);
    try output.writer.writeAll("],\"user_score\":");
    if (user_score) |json| try output.writer.writeAll(json) else try output.writer.writeAll("null");
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

pub fn lazerScoreJson(self: anytype, allocator: std.mem.Allocator, score_id: i64, beatmap_id: i32) !?[]u8 {
    var score_buf: [32]u8 = undefined;
    var map_buf: [24]u8 = undefined;
    const score_text = try std.fmt.bufPrint(&score_buf, "{d}", .{score_id});
    const map_text = try std.fmt.bufPrint(&map_buf, "{d}", .{beatmap_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,s.beatmap_id,s.ruleset_id,s.total_score,s.total_score_without_mods,s.legacy_total_score,s.pp,s.accuracy,s.max_combo,s.passed,s.rank,s.mods_json::text,s.statistics_json::text,s.maximum_statistics_json::text,s.pauses_json::text,to_char(to_timestamp(s.submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),b.status,(s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id))),b.set_id,b.md5,b.mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace FROM zigcho.lazer_scores s JOIN zigcho.users u ON u.id=s.user_id JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.id=$1 AND s.beatmap_id=$2 AND NOT u.restricted", &.{ score_text, map_text });
    defer result.deinit();
    if (result.rows() == 0) return null;
    const status = try result.int(i32, 0, 19);
    const score: lazer.LeaderboardScore = .{
        .id = try result.int(i64, 0, 0),
        .legacy_total_score = if (result.isNull(0, 8)) null else try result.int(i32, 0, 8),
        .user_id = try result.int(i32, 0, 1),
        .username = result.value(0, 2),
        .country = result.value(0, 3),
        .beatmap_id = try result.int(i32, 0, 4),
        .ruleset_id = try result.int(i32, 0, 5),
        .total_score = try result.int(i64, 0, 6),
        .total_score_without_mods = try result.int(i64, 0, 7),
        .pp = try result.float(f64, 0, 9),
        .accuracy = try result.float(f64, 0, 10),
        .max_combo = try result.int(i32, 0, 11),
        .passed = try result.boolean(0, 12),
        .rank = result.value(0, 13),
        .mods_json = result.value(0, 14),
        .statistics_json = result.value(0, 15),
        .maximum_statistics_json = result.value(0, 16),
        .pauses_json = result.value(0, 17),
        .ended_at = result.value(0, 18),
        .ranked = status == 3 or status == 4,
        .has_replay = try result.boolean(0, 20),
        .beatmap = .{
            .id = try result.int(i32, 0, 4),
            .set_id = try result.int(i32, 0, 21),
            .status = lazerStatus(status),
            .checksum = result.value(0, 22),
            .ruleset_id = try result.int(i32, 0, 23),
            .star_rating = try result.float(f64, 0, 24),
            .version = result.value(0, 25),
            .artist = result.value(0, 26),
            .title = result.value(0, 27),
            .creator = result.value(0, 28),
        },
    };
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try lazer.writeLeaderboardScore(&output.writer, score);
    return @as(?[]u8, try output.toOwnedSlice());
}

pub fn insertLazerScore(self: anytype, user_id: i32, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8) !i64 {
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    try pg_score_maintenance.history_updates.lockSubmission(self, lease.conn, lazer.statsMode(input) orelse 9);
    const score_id = try insertLazerScoreWithConnection(self, lease.conn, user_id, input, pp_value, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data);
    try postgres.exec(lease.conn, "COMMIT");
    return score_id;
}

pub fn insertLazerScoreWithConnection(self: anytype, conn: *postgres.c.PGconn, user_id: i32, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8) !i64 {
    var buffers: [32][64]u8 = undefined;
    var cursor: usize = 0;
    const user = try common.param(&buffers, &cursor, user_id);
    const beatmap_id = try common.param(&buffers, &cursor, input.beatmap_id);
    const ruleset_id = try common.param(&buffers, &cursor, input.ruleset_id);
    const total_score = try common.param(&buffers, &cursor, input.total_score);
    const total_score_without_mods = try common.param(&buffers, &cursor, input.total_score_without_mods);
    const legacy_total_score = try common.param(&buffers, &cursor, lazer.classicTotalScore(input));
    const accuracy = try common.param(&buffers, &cursor, input.accuracy);
    const max_combo = try common.param(&buffers, &cursor, input.max_combo);
    const pp_text = try common.param(&buffers, &cursor, pp_value);
    const star_rating = try common.param(&buffers, &cursor, input.achievement_stars);
    const replay_encoded: ?[]u8 = if (replay_data.len == 0) null else try postgres.encodeBytea(self.allocator, replay_data);
    defer if (replay_encoded) |encoded| self.allocator.free(encoded);
    const passed = if (input.passed) "true" else "false";
    const rank = input.rank orelse if (input.passed) "D" else "F";
    const namespace = @tagName(input.namespace);
    const medal_categories = try lazer.medalModCategories(self.allocator, mods_json);
    var scope_lock = try postgres.queryParams(self.allocator, conn, "SELECT pg_advisory_xact_lock(hashtextextended('zigcho:lazer-best:'||$1||':'||$2||':'||$3||':'||$4,0))", &.{ user, beatmap_id, ruleset_id, namespace });
    scope_lock.deinit();
    var result = try postgres.queryParams(self.allocator, conn, "INSERT INTO zigcho.lazer_scores(user_id,beatmap_id,ruleset_id,total_score,total_score_without_mods,legacy_total_score,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,rank_namespace,client_version,pp,best,replay,star_rating) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11::jsonb,$12::jsonb,$13::jsonb,$14::jsonb,$15,$16,$17,false,$18,$19) RETURNING id", &.{ user, beatmap_id, ruleset_id, total_score, total_score_without_mods, legacy_total_score, accuracy, max_combo, passed, rank, mods_json, statistics_json, maximum_statistics_json, pauses_json, namespace, input.client_version, pp_text, replay_encoded, star_rating });
    defer result.deinit();
    const score_id = try result.int(i64, 0, 0);
    if (input.passed) {
        var unset = try postgres.queryParams(self.allocator, conn, "UPDATE zigcho.lazer_scores SET best=false WHERE user_id=$1 AND beatmap_id=$2 AND ruleset_id=$3 AND rank_namespace=$4 AND best", &.{ user, beatmap_id, ruleset_id, namespace });
        unset.deinit();
        var promote = try postgres.queryParams(self.allocator, conn, "UPDATE zigcho.lazer_scores SET best=true WHERE id=(SELECT id FROM zigcho.lazer_scores WHERE user_id=$1 AND beatmap_id=$2 AND ruleset_id=$3 AND rank_namespace=$4 AND passed ORDER BY pp DESC,total_score DESC,id ASC LIMIT 1)", &.{ user, beatmap_id, ruleset_id, namespace });
        promote.deinit();
    }
    try updateLazerStatsWithConnection(self, conn, user_id, input);
    if (lazer.statsMode(input)) |stats_mode| {
        try pg_score_maintenance.recordStatsHistorySliceCurrentWithConnection(self, conn, .lazer, stats_mode, user_id);
        try pg_score_maintenance.recordStatsHistorySliceCurrentWithConnection(self, conn, .all, stats_mode, user_id);
    }
    var ranked_map = try postgres.queryParams(self.allocator, conn, "SELECT status IN(3,4) FROM zigcho.beatmaps WHERE id=$1", &.{beatmap_id});
    defer ranked_map.deinit();
    const ranked = ranked_map.rows() != 0 and try ranked_map.boolean(0, 0);
    try pg_score_achievements.awardAchievementsWithConnection(self, conn, user_id, "lazer", score_id, .{
        .eligible = input.passed and input.namespace == .vanilla and ranked,
        .mod_intro_eligible = input.passed and ranked,
        .conversion_mod = medal_categories.conversion,
        .fun_mod = medal_categories.fun,
        .mode = @intCast(input.ruleset_id),
        .mods = input.achievement_mods,
        .perfect = input.achievement_perfect,
        .max_combo = @intCast(input.max_combo),
        .stars = input.achievement_stars,
        .accuracy = input.accuracy,
        .pp = pp_value,
    });
    return score_id;
}

pub fn updateLazerStatsWithConnection(self: anytype, conn: *postgres.c.PGconn, user_id: i32, input: lazer.ScoreInput) !void {
    var buffers: [32][64]u8 = undefined;
    var cursor: usize = 0;
    const user = try common.param(&buffers, &cursor, user_id);
    const beatmap_id = try common.param(&buffers, &cursor, input.beatmap_id);

    var map = try postgres.queryParams(self.allocator, conn, "SELECT md5,status,greatest(total_length,0) FROM zigcho.beatmaps WHERE id=$1 FOR UPDATE", &.{beatmap_id});
    defer map.deinit();
    if (map.rows() == 0) return;
    const map_status = try map.int(i32, 0, 1);
    if (lazer.statsMode(input)) |stats_mode| {
        const stats_mode_text = try common.param(&buffers, &cursor, stats_mode);
        const legacy_score = try common.param(&buffers, &cursor, lazer.classicTotalScore(input));
        const max_combo = try common.param(&buffers, &cursor, input.max_combo);
        const hits = try common.param(&buffers, &cursor, lazer.totalHits(input));
        const play_time = try common.param(&buffers, &cursor, try map.int(i32, 0, 2));
        var update = try postgres.queryParams(self.allocator, conn, "UPDATE zigcho.stats SET total_score=total_score+$1,plays=plays+1,play_time=play_time+$2,total_hits=total_hits+$3,max_combo=CASE WHEN $4::boolean THEN greatest(max_combo,$5) ELSE max_combo END WHERE user_id=$6 AND mode=$7", &.{ legacy_score, play_time, hits, if (input.passed and map_status >= 3) "true" else "false", max_combo, user, stats_mode_text });
        update.deinit();
    }
    var map_update = try postgres.queryParams(self.allocator, conn, "UPDATE zigcho.beatmaps SET plays=plays+1,passes=passes+$1 WHERE id=$2", &.{ if (input.passed) "1" else "0", beatmap_id });
    map_update.deinit();
    if (lazer.statsMode(input)) |stats_mode| {
        if (input.passed and (map_status == 3 or map_status == 4)) try pg_score_maintenance.rebuildCombinedPerformanceWithConnection(self, conn, user_id, @intCast(input.ruleset_id), stats_mode, @tagName(input.namespace), false);
    }
}

pub fn isLazerRoomScoreToken(token_id: i64) bool {
    return storage_contracts.isLazerRoomScoreToken(token_id);
}

const lazer_room_score_token_tag: u64 = 0x7f_ff_ff_00_00_00_00_00;
const lazer_room_score_token_mask: u64 = 0x7f_ff_ff_00_00_00_00_00;
const lazer_room_score_token_payload_mask: u64 = 0x00_00_00_ff_ff_ff_ff_ff;

pub fn createLazerScoreToken(self: anytype, user_id: i32, beatmap_id: i32, beatmap_hash: []const u8, ruleset_id: i64, version_hash: []const u8) !i64 {
    return createLazerScoreTokenScoped(self, user_id, beatmap_id, beatmap_hash, ruleset_id, version_hash, false);
}

pub fn createLazerRoomScoreToken(self: anytype, user_id: i32, beatmap_id: i32, beatmap_hash: []const u8, ruleset_id: i64, version_hash: []const u8) !i64 {
    return createLazerScoreTokenScoped(self, user_id, beatmap_id, beatmap_hash, ruleset_id, version_hash, true);
}

pub fn discardUnusedLazerRoomScoreToken(self: anytype, user_id: i32, token_id: i64) !bool {
    if (!isLazerRoomScoreToken(token_id)) return false;
    var buffers: [2][32]u8 = undefined;
    var cursor: usize = 0;
    const token = try common.param(&buffers, &cursor, token_id);
    const user = try common.param(&buffers, &cursor, user_id);
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_score_tokens WHERE id=$1 AND user_id=$2 AND consumed_at IS NULL AND score_id IS NULL RETURNING 1", &.{ token, user });
    defer result.deinit();
    return result.rows() == 1;
}

pub fn createLazerScoreTokenScoped(self: anytype, user_id: i32, beatmap_id: i32, beatmap_hash: []const u8, ruleset_id: i64, version_hash: []const u8, room_scoped: bool) !i64 {
    var random_bytes: [8]u8 = undefined;
    try std.Io.randomSecure(self.io, &random_bytes);
    var raw = std.mem.readInt(u64, &random_bytes, .little) & std.math.maxInt(i64);
    if (room_scoped) {
        raw = lazer_room_score_token_tag | (raw & lazer_room_score_token_payload_mask);
    } else if ((raw & lazer_room_score_token_mask) == lazer_room_score_token_tag) {
        raw &= ~lazer_room_score_token_mask;
    }
    const token_id: i64 = @intCast(raw | 1);
    const now = std.Io.Clock.real.now(self.io).toSeconds();
    var buffers: [32][64]u8 = undefined;
    var cursor: usize = 0;
    const token = try common.param(&buffers, &cursor, token_id);
    const user = try common.param(&buffers, &cursor, user_id);
    const map_id = try common.param(&buffers, &cursor, beatmap_id);
    const ruleset = try common.param(&buffers, &cursor, ruleset_id);
    const expiry = try common.param(&buffers, &cursor, now + lazer.score_token_lifetime_seconds);
    const prune_before = try common.param(&buffers, &cursor, now - 86_400);
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT md5 FROM zigcho.beatmaps WHERE id=$1", &.{map_id});
    defer map.deinit();
    if (map.rows() == 0) return error.BeatmapNotFound;
    if (!std.ascii.eqlIgnoreCase(map.value(0, 0), beatmap_hash)) return error.BeatmapHashMismatch;
    var prune = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_score_tokens WHERE expires_at<$1 OR (consumed_at IS NOT NULL AND consumed_at<$1)", &.{prune_before});
    prune.deinit();
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_score_tokens(id,user_id,beatmap_id,beatmap_hash,ruleset_id,version_hash,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7)", &.{ token, user, map_id, beatmap_hash, ruleset, version_hash, expiry });
    result.deinit();
    try postgres.exec(lease.conn, "COMMIT");
    return token_id;
}

pub fn submitLazerScoreToken(self: anytype, user_id: i32, beatmap_id: i32, token_id: i64, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8) !i64 {
    return submitLazerScoreTokenScoped(self, user_id, beatmap_id, token_id, input, pp_value, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data, false);
}

pub fn submitLazerRoomScoreToken(self: anytype, user_id: i32, beatmap_id: i32, token_id: i64, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8) !i64 {
    return submitLazerScoreTokenScoped(self, user_id, beatmap_id, token_id, input, pp_value, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data, true);
}

pub fn submitLazerScoreTokenScoped(self: anytype, user_id: i32, beatmap_id: i32, token_id: i64, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8, room_scoped: bool) !i64 {
    if (isLazerRoomScoreToken(token_id) != room_scoped) return error.InvalidLazerScoreToken;
    const now = std.Io.Clock.real.now(self.io).toSeconds();
    var buffers: [32][64]u8 = undefined;
    var cursor: usize = 0;
    const token_text = try common.param(&buffers, &cursor, token_id);
    const user_text = try common.param(&buffers, &cursor, user_id);
    const map_text = try common.param(&buffers, &cursor, beatmap_id);
    const ruleset_text = try common.param(&buffers, &cursor, input.ruleset_id);
    const now_text = try common.param(&buffers, &cursor, now);
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    try pg_score_maintenance.history_updates.lockSubmission(self, lease.conn, lazer.statsMode(input) orelse 9);
    var token = try postgres.queryParams(self.allocator, lease.conn, "SELECT user_id,beatmap_id,ruleset_id,expires_at,consumed_at FROM zigcho.lazer_score_tokens WHERE id=$1 FOR UPDATE", &.{token_text});
    defer token.deinit();
    if (token.rows() == 0) return error.InvalidLazerScoreToken;
    if (try token.int(i32, 0, 0) != user_id) return error.ForeignLazerScoreToken;
    if (try token.int(i32, 0, 1) != beatmap_id or try token.int(i64, 0, 2) != input.ruleset_id) return error.LazerScoreTokenMismatch;
    if (try token.int(i64, 0, 3) <= now) return error.LazerScoreTokenExpired;
    if (!token.isNull(0, 4)) return error.LazerScoreTokenUsed;
    const score_id = try insertLazerScoreWithConnection(self, lease.conn, user_id, input, pp_value, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data);
    var score_buffer: [32]u8 = undefined;
    const score_text = try std.fmt.bufPrint(&score_buffer, "{d}", .{score_id});
    var consume = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.lazer_score_tokens SET consumed_at=$1,score_id=$2 WHERE id=$3 AND user_id=$4 AND beatmap_id=$5 AND ruleset_id=$6 AND consumed_at IS NULL RETURNING 1", &.{ now_text, score_text, token_text, user_text, map_text, ruleset_text });
    defer consume.deinit();
    if (consume.rows() != 1) return error.LazerScoreTokenUsed;
    try postgres.exec(lease.conn, "COMMIT");
    return score_id;
}

pub fn lazerScoreLeaderboardPlacement(self: anytype, score_id: i64) !?domain.ScorePlacement {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{score_id});
    const Context = struct { user_id: i32, beatmap_id: i32, ruleset_id: u8, namespace: lazer.Namespace, mods_json: []u8 };
    const context: Context = blk: {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.user_id,s.beatmap_id,s.ruleset_id,s.rank_namespace,s.mods_json::text,s.passed,b.status FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.id=$1", &.{id});
        defer result.deinit();
        if (result.rows() == 0 or !try result.boolean(0, 5) or try result.int(i32, 0, 6) < 3) return null;
        const score_namespace = std.meta.stringToEnum(lazer.Namespace, result.value(0, 3)) orelse return error.DatabaseQueryFailed;
        break :blk .{
            .user_id = try result.int(i32, 0, 0),
            .beatmap_id = try result.int(i32, 0, 1),
            .ruleset_id = try result.int(u8, 0, 2),
            .namespace = score_namespace,
            .mods_json = try self.allocator.dupe(u8, result.value(0, 4)),
        };
    };
    defer self.allocator.free(context.mods_json);
    const filter = try lazer.scoreModFilter(self.allocator, context.mods_json);
    defer filter.deinit(self.allocator);
    const board_json = try self.lazerLeaderboardJson(self.allocator, context.user_id, context.beatmap_id, context.ruleset_id, context.namespace, filter.exact_json, true, false, filter.stable_bits, .global, 100);
    defer self.allocator.free(board_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, board_json, .{});
    defer parsed.deinit();
    const own = parsed.value.object.get("user_score") orelse return null;
    const own_object = switch (own) {
        .object => |value| value,
        else => return null,
    };
    const position_value = switch (own_object.get("position") orelse return null) {
        .integer => |value| value,
        else => return null,
    };
    const score = own_object.get("score") orelse return null;
    const score_object = switch (score) {
        .object => |value| value,
        else => return null,
    };
    const listed_id = switch (score_object.get("id") orelse return null) {
        .integer => |value| value,
        else => return null,
    };
    return .{
        .submitted_is_best = listed_id == score_id,
        .rank = std.math.cast(i32, @max(position_value - 1, 0)) orelse return error.DatabaseQueryFailed,
    };
}
