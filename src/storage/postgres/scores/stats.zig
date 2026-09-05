const std = @import("std");
const database_sql = @import("database_sql");
const domain = @import("../../../domain.zig");
const postgres = @import("../../../postgres.zig");
const storage_contracts = @import("../../contracts.zig");
const lazer = @import("../../../lazer.zig");
const user_json = @import("../../../user_json.zig");
const achievements = @import("../../../achievements.zig");
const common = @import("../common.zig");
const pg_beatmap_catalog = @import("../beatmaps/catalog.zig");
const pg_score_achievements = @import("../scores/achievements.zig");
const pg_score_maintenance = @import("../scores/maintenance.zig");
const pg_social = @import("../social/store.zig");

const ReplaySource = storage_contracts.ReplaySource;
const BeatmapForScore = storage_contracts.BeatmapForScore;
const BeatmapInfo = storage_contracts.BeatmapInfo;
const PpSnapshot = storage_contracts.PpSnapshot;
const ServerCounts = common.ServerCounts;

pub fn setScorePinned(self: anytype, user_id: i32, map_md5: []const u8, mode: u8, mods_value: i32, namespace: []const u8, pinned: bool) !i64 {
    var user_buf: [24]u8 = undefined;
    var mode_buf: [4]u8 = undefined;
    var mods_buf: [16]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
    const mods = try std.fmt.bufPrint(&mods_buf, "{d}", .{mods_value});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var locked_user = try postgres.queryParams(self.allocator, lease.conn, "SELECT id FROM zigcho.users WHERE id=$1 FOR UPDATE", &.{user});
    defer locked_user.deinit();
    if (locked_user.rows() == 0) return error.UserNotFound;
    var score = try postgres.queryParams(self.allocator, lease.conn, "SELECT id FROM zigcho.scores WHERE user_id=$1 AND map_md5=$2 AND mode=$3 AND rank_namespace=$4 AND mods=$5 AND passed ORDER BY best DESC,pp DESC,score DESC,id DESC LIMIT 1", &.{ user, map_md5, mode_text, namespace, mods });
    defer score.deinit();
    if (score.rows() == 0) return error.NoPassedScore;
    const score_id = try score.int(i64, 0, 0);
    var score_buf: [24]u8 = undefined;
    const score_text = try std.fmt.bufPrint(&score_buf, "{d}", .{score_id});
    if (pinned) {
        var old = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.score_pins p USING zigcho.scores s WHERE p.user_id=$1 AND p.score_id=s.id AND s.user_id=$1 AND s.map_md5=$2 AND s.mode=$3 AND s.rank_namespace=$4 AND s.mods=$5 AND p.score_id<>$6", &.{ user, map_md5, mode_text, namespace, mods, score_text });
        old.deinit();
        var old_profile = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.profile_score_pins p USING zigcho.scores s WHERE p.user_id=$1 AND p.source='stable' AND p.score_id=s.id AND s.user_id=$1 AND s.map_md5=$2 AND s.mode=$3 AND s.rank_namespace=$4 AND s.mods=$5 AND p.score_id<>$6", &.{ user, map_md5, mode_text, namespace, mods, score_text });
        old_profile.deinit();
        var pins = try postgres.queryParams(self.allocator, lease.conn, "SELECT score_id FROM zigcho.profile_score_pins WHERE user_id=$1 AND mode=$2 AND rank_namespace=$3 FOR UPDATE", &.{ user, mode_text, namespace });
        defer pins.deinit();
        var already_pinned = false;
        for (0..pins.rows()) |row| if (try pins.int(i64, row, 0) == score_id) {
            already_pinned = true;
            break;
        };
        if (!already_pinned and pins.rows() >= 3) return error.TooManyPinnedScores;
        var update = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.score_pins(user_id,score_id) VALUES($1,$2) ON CONFLICT(user_id,score_id) DO UPDATE SET pinned_at=extract(epoch FROM clock_timestamp())::bigint", &.{ user, score_text });
        update.deinit();
    } else {
        var update = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.score_pins p USING zigcho.scores s WHERE p.user_id=$1 AND p.score_id=s.id AND s.user_id=$1 AND s.map_md5=$2 AND s.mode=$3 AND s.rank_namespace=$4 AND s.mods=$5", &.{ user, map_md5, mode_text, namespace, mods });
        update.deinit();
    }
    if (pinned) {
        var profile = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.profile_score_pins(user_id,source,score_id,mode,rank_namespace) VALUES($1,'stable',$2,$3,$4) ON CONFLICT(user_id,source,score_id) DO UPDATE SET pinned_at=extract(epoch FROM clock_timestamp())::bigint", &.{ user, score_text, mode_text, namespace });
        profile.deinit();
    } else {
        var profile = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.profile_score_pins p USING zigcho.scores s WHERE p.user_id=$1 AND p.source='stable' AND p.score_id=s.id AND s.user_id=$1 AND s.map_md5=$2 AND s.mode=$3 AND s.rank_namespace=$4 AND s.mods=$5", &.{ user, map_md5, mode_text, namespace, mods });
        profile.deinit();
    }
    try postgres.exec(lease.conn, "COMMIT");
    return score_id;
}

pub fn setScorePinnedById(self: anytype, user_id: i32, source: ReplaySource, score_id: i64, pinned: bool) !void {
    var buffers: [2][32]u8 = undefined;
    var cursor: usize = 0;
    const user = try common.param(&buffers, &cursor, user_id);
    const score_id_text = try common.param(&buffers, &cursor, score_id);
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var score = try postgres.queryParams(self.allocator, lease.conn, switch (source) {
        .stable => "SELECT mode,rank_namespace FROM zigcho.scores WHERE id=$1 AND user_id=$2 AND passed FOR UPDATE",
        .lazer => "SELECT ruleset_id,rank_namespace FROM zigcho.lazer_scores WHERE id=$1 AND user_id=$2 AND passed FOR UPDATE",
    }, &.{ score_id_text, user });
    defer score.deinit();
    if (score.rows() != 1) return error.NoPassedScore;
    if (pinned) {
        var pins = try postgres.queryParams(self.allocator, lease.conn, "SELECT score_id FROM zigcho.profile_score_pins WHERE user_id=$1 AND mode=$2 AND rank_namespace=$3 AND NOT(source=$4 AND score_id=$5) FOR UPDATE", &.{ user, score.value(0, 0), score.value(0, 1), source.text(), score_id_text });
        defer pins.deinit();
        if (pins.rows() >= 3) return error.TooManyPinnedScores;
        var update = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.profile_score_pins(user_id,source,score_id,mode,rank_namespace) VALUES($1,$2,$3,$4,$5) ON CONFLICT(user_id,source,score_id) DO UPDATE SET pinned_at=extract(epoch FROM clock_timestamp())::bigint", &.{ user, source.text(), score_id_text, score.value(0, 0), score.value(0, 1) });
        update.deinit();
        if (source == .stable) {
            var legacy = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.score_pins(user_id,score_id) VALUES($1,$2) ON CONFLICT(user_id,score_id) DO UPDATE SET pinned_at=extract(epoch FROM clock_timestamp())::bigint", &.{ user, score_id_text });
            legacy.deinit();
        }
    } else {
        var update = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.profile_score_pins WHERE user_id=$1 AND source=$2 AND score_id=$3", &.{ user, source.text(), score_id_text });
        update.deinit();
        if (source == .stable) {
            var legacy = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.score_pins WHERE user_id=$1 AND score_id=$2", &.{ user, score_id_text });
            legacy.deinit();
        }
    }
    try postgres.exec(lease.conn, "COMMIT");
}

pub fn serverCounts(self: anytype) !ServerCounts {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.query(lease.conn, "SELECT (SELECT count(*) FROM zigcho.users WHERE id!=3),(SELECT count(*) FROM zigcho.scores)+(SELECT count(*) FROM zigcho.lazer_scores),(SELECT count(*) FROM zigcho.scores WHERE passed)+(SELECT count(*) FROM zigcho.lazer_scores WHERE passed),(SELECT count(*) FROM zigcho.beatmaps)");
    defer result.deinit();
    return .{ .users = try result.int(i64, 0, 0), .plays = try result.int(i64, 0, 1), .passed = try result.int(i64, 0, 2), .maps = try result.int(i64, 0, 3) };
}

pub fn siteRankings(self: anytype, allocator: std.mem.Allocator, source: domain.SiteScoreSource, mode: u8, offset: u16) ![]u8 {
    var mode_buf: [4]u8 = undefined;
    var offset_buf: [8]u8 = undefined;
    const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
    const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
    var lease = self.pool.acquire();
    defer lease.release();
    const stable_sql =
        "WITH source_scores AS (" ++
        "SELECT s.user_id,s.id score_id,s.score total_score,s.pp,s.accuracy,s.max_combo,s.passed,b.status,b.id beatmap_id " ++
        "FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.mode=$1 AND s.rank_namespace=$2)," ++
        "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed AND status IN(3,4))," ++
        "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
        "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*)::double precision))) pp,sum(accuracy*power(0.95,performance_index))/(20*(1-power(0.95,count(*)::double precision))) accuracy FROM ranked GROUP BY user_id)," ++
        "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id) " ++
        "SELECT row_number() OVER(ORDER BY coalesce(p.pp,0) DESC,u.id ASC),u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,coalesce(p.pp,0),coalesce(p.accuracy,0),a.plays,a.ranked_score,a.total_score,a.max_combo FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted AND u.show_profile_stats ORDER BY coalesce(p.pp,0) DESC,u.id ASC LIMIT 100 OFFSET $3";
    const lazer_sql =
        "WITH source_scores AS (" ++
        "SELECT s.user_id,s.id score_id,coalesce(s.legacy_total_score,s.total_score) total_score,s.pp,s.accuracy,s.max_combo,s.passed,b.status,s.beatmap_id " ++
        "FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.ruleset_id=$1 AND s.rank_namespace=$2)," ++
        "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed AND status IN(3,4))," ++
        "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
        "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*)::double precision))) pp,sum(accuracy*power(0.95,performance_index))/(20*(1-power(0.95,count(*)::double precision))) accuracy FROM ranked GROUP BY user_id)," ++
        "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id) " ++
        "SELECT row_number() OVER(ORDER BY coalesce(p.pp,0) DESC,u.id ASC),u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,coalesce(p.pp,0),coalesce(p.accuracy,0),a.plays,a.ranked_score,a.total_score,a.max_combo FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted AND u.show_profile_stats ORDER BY coalesce(p.pp,0) DESC,u.id ASC LIMIT 100 OFFSET $3";
    var result = switch (source) {
        .all => try postgres.queryParams(allocator, lease.conn, "SELECT row_number() OVER(ORDER BY s.pp DESC,u.id ASC),u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,s.pp,s.accuracy,s.plays,s.ranked_score,s.total_score,s.max_combo FROM zigcho.stats s JOIN zigcho.users u ON u.id=s.user_id WHERE s.mode=$1 AND u.id!=3 AND NOT u.restricted AND u.show_profile_stats AND s.plays>0 ORDER BY s.pp DESC,u.id ASC LIMIT 100 OFFSET $2", &.{ mode_text, offset_text }),
        .stable, .lazer, .scorev2 => blk: {
            var score_mode_buf: [4]u8 = undefined;
            const score_mode_text = try std.fmt.bufPrint(&score_mode_buf, "{d}", .{domain.siteScoreMode(mode)});
            break :blk try postgres.queryParams(allocator, lease.conn, if (source == .lazer) lazer_sql else stable_sql, &.{ score_mode_text, domain.siteNamespace(source, mode), offset_text });
        },
    };
    defer result.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"source\":\"{s}\",\"mode\":{d},\"offset\":{d},\"players\":[", .{ @tagName(source), mode, offset });
    for (0..result.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        try output.writer.print("{{\"rank\":{d},\"id\":{d},\"name\":", .{ try result.int(i32, row, 0), try result.int(i32, row, 1) });
        try common.jsonString(&output.writer, result.value(row, 2));
        try output.writer.writeAll(",\"country\":");
        try common.jsonString(&output.writer, result.value(row, 3));
        try output.writer.print(",\"privileges\":{d},\"pp\":{d},\"accuracy\":{d},\"plays\":{d},\"ranked_score\":{d},\"total_score\":{d},\"max_combo\":{d}}}", .{ try result.int(u32, row, 4), try result.int(i32, row, 5), try result.float(f64, row, 6), try result.int(i32, row, 7), try result.int(i64, row, 8), try result.int(i64, row, 9), try result.int(i32, row, 10) });
    }
    try output.writer.writeAll("]}");
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

pub fn writeSiteScores(writer: *std.Io.Writer, scores: *postgres.Result, include_weight: bool) !void {
    try writer.writeByte('[');
    for (0..scores.rows()) |row| {
        if (row != 0) try writer.writeByte(',');
        try writer.print("{{\"id\":{d},\"score\":{d},\"score_without_mods\":{d},\"legacy_score\":", .{ try scores.int(i64, row, 0), try scores.int(i64, row, 1), try scores.int(i64, row, 20) });
        if (scores.isNull(row, 21)) try writer.writeAll("null") else try writer.print("{d}", .{try scores.int(i32, row, 21)});
        try writer.print(",\"pp\":{d},\"accuracy\":{d},\"max_combo\":{d},\"mods\":{d},\"mode\":{d},\"namespace\":", .{ try scores.float(f64, row, 2), try scores.float(f64, row, 3), try scores.int(i32, row, 4), try scores.int(i32, row, 5), try scores.int(u8, row, 6) });
        try common.jsonString(writer, scores.value(row, 7));
        try writer.print(",\"passed\":{},\"submitted_at\":{d},\"set_id\":{d},\"map_id\":{d},\"artist\":", .{ try scores.boolean(row, 8), try scores.int(i64, row, 9), try scores.int(i32, row, 10), try scores.int(i32, row, 11) });
        try common.jsonString(writer, scores.value(row, 12));
        try writer.writeAll(",\"title\":");
        try common.jsonString(writer, scores.value(row, 13));
        try writer.writeAll(",\"version\":");
        try common.jsonString(writer, scores.value(row, 14));
        try writer.print(",\"status\":{d},\"client\":", .{try scores.int(i8, row, 15)});
        try common.jsonString(writer, scores.value(row, 16));
        try writer.writeAll(",\"mods_json\":");
        if (scores.isNull(row, 17)) {
            try writer.writeAll("null");
        } else {
            try writer.writeAll(scores.value(row, 17));
        }
        if (include_weight) {
            const percentage = 100.0 * std.math.pow(f64, 0.95, @floatFromInt(row));
            const weighted_pp = try scores.float(f64, row, 2) * percentage / 100.0;
            try writer.print(",\"weight\":{{\"percentage\":{d:.2},\"pp\":{d:.2}}}", .{ percentage, weighted_pp });
        }
        try writer.print(",\"has_replay\":{},\"star_rating\":{d}}}", .{ try scores.boolean(row, 18), try scores.float(f64, row, 19) });
    }
    try writer.writeByte(']');
}

pub fn siteProfile(self: anytype, allocator: std.mem.Allocator, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !?[]u8 {
    return self.siteProfileForViewer(allocator, user_id, source, stats_mode, false);
}

pub fn siteProfileForViewer(self: anytype, allocator: std.mem.Allocator, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8, owner_view: bool) !?[]u8 {
    if (user_id <= 0 or !domain.validSiteMode(source, stats_mode)) return error.InvalidStatsHistory;
    var id_buf: [24]u8 = undefined;
    var score_mode_buf: [4]u8 = undefined;
    var stats_mode_buf: [4]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    const score_mode = domain.siteScoreMode(stats_mode);
    const score_mode_text = try std.fmt.bufPrint(&score_mode_buf, "{d}", .{score_mode});
    const stats_mode_text = try std.fmt.bufPrint(&stats_mode_buf, "{d}", .{stats_mode});
    const namespace = domain.siteNamespace(source, stats_mode);
    var lease = self.pool.acquire();
    defer lease.release();
    const user_sql = "SELECT u.id,u.name,CASE WHEN $2::boolean OR u.show_country THEN u.country ELSE 'XX' END,u.privileges,u.created_at,u.bio,u.preferred_mode,u.profile_source,coalesce((SELECT updated_at FROM zigcho.user_avatars a WHERE a.user_id=u.id),u.avatar_key),u.profile_title,u.profile_pronouns,u.profile_location,u.profile_website,u.profile_accent,u.show_profile_stats,u.show_recent_scores,coalesce((SELECT updated_at FROM zigcho.user_banners b WHERE b.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM zigcho.team_assets a WHERE a.team_id=t.id AND a.kind='flag'),0)," ++ common.visible_follower_count_sql ++ " FROM zigcho.users u LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id WHERE u.id=$1 AND u.id!=3 AND NOT u.restricted";
    var user = try postgres.queryParams(allocator, lease.conn, user_sql, &.{ id, if (owner_view) "true" else "false" });
    defer user.deinit();
    if (user.rows() == 0) return null;
    var stats = try postgres.queryParams(allocator, lease.conn, "SELECT s.mode,s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,CASE WHEN s.plays>0 THEN (SELECT count(*)+1 FROM zigcho.stats r JOIN zigcho.users ru ON ru.id=r.user_id WHERE r.mode=s.mode AND r.plays>0 AND ru.id!=3 AND NOT ru.restricted AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) ELSE 0 END FROM zigcho.stats s WHERE s.user_id=$1 ORDER BY s.mode", &.{id});
    defer stats.deinit();
    const stable_stats_sql =
        "WITH source_scores AS (SELECT s.user_id,s.id score_id,s.score total_score,s.pp,s.accuracy,s.max_combo,s.passed,s.time_elapsed/1000 play_time,b.status,b.id beatmap_id FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.mode=$2 AND s.rank_namespace=$3)," ++
        "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed AND status IN(3,4))," ++
        "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
        "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*)::double precision))) pp,sum(accuracy*power(0.95,performance_index))/(20*(1-power(0.95,count(*)::double precision))) accuracy FROM ranked GROUP BY user_id)," ++
        "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce(sum(play_time),0) play_time,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id)," ++
        "players AS (SELECT a.user_id,a.ranked_score,a.total_score,coalesce(p.pp,0) pp,a.plays,a.play_time,coalesce(p.accuracy,0) accuracy,a.max_combo FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted)," ++
        "ordered AS (SELECT *,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) SELECT ranked_score,total_score,pp,plays,play_time,accuracy,max_combo,global_rank FROM ordered WHERE user_id=$1";
    const lazer_stats_sql =
        "WITH source_scores AS (SELECT s.user_id,s.id score_id,coalesce(s.legacy_total_score,s.total_score) total_score,s.pp,s.accuracy,s.max_combo,s.passed,greatest(b.total_length,0) play_time,b.status,s.beatmap_id FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.ruleset_id=$2 AND s.rank_namespace=$3)," ++
        "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed AND status IN(3,4))," ++
        "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
        "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*)::double precision))) pp,sum(accuracy*power(0.95,performance_index))/(20*(1-power(0.95,count(*)::double precision))) accuracy FROM ranked GROUP BY user_id)," ++
        "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce(sum(play_time),0) play_time,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id)," ++
        "players AS (SELECT a.user_id,a.ranked_score,a.total_score,coalesce(p.pp,0) pp,a.plays,a.play_time,coalesce(p.accuracy,0) accuracy,a.max_combo FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted)," ++
        "ordered AS (SELECT *,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) SELECT ranked_score,total_score,pp,plays,play_time,accuracy,max_combo,global_rank FROM ordered WHERE user_id=$1";
    var selected_stats = switch (source) {
        .all => try postgres.queryParams(allocator, lease.conn, "SELECT s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.accuracy,s.max_combo,(SELECT count(*)+1 FROM zigcho.stats r JOIN zigcho.users ru ON ru.id=r.user_id WHERE r.mode=s.mode AND r.plays>0 AND ru.id!=3 AND NOT ru.restricted AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) FROM zigcho.stats s WHERE s.user_id=$1 AND s.mode=$2 AND s.plays>0", &.{ id, stats_mode_text }),
        .stable, .scorev2 => try postgres.queryParams(allocator, lease.conn, stable_stats_sql, &.{ id, score_mode_text, namespace }),
        .lazer => try postgres.queryParams(allocator, lease.conn, lazer_stats_sql, &.{ id, score_mode_text, namespace }),
    };
    defer selected_stats.deinit();
    const stable_columns = "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id map_id,b.artist,b.title,b.version,b.status,'stable',NULL::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.score score_without_mods,s.score legacy_score FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 ";
    const lazer_columns = "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id map_id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.total_score_without_mods score_without_mods,s.legacy_total_score legacy_score FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id ";
    const pinned_sql: [:0]const u8 = switch (source) {
        .all => "WITH pinned_scores(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score,pinned_at) AS (" ++
            "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.score,s.score,p.pinned_at FROM zigcho.profile_score_pins p JOIN zigcho.scores s ON p.source='stable' AND s.id=p.score_id JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE p.user_id=$1 AND p.mode=$2 AND p.rank_namespace=$3 AND s.passed UNION ALL " ++
            "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.total_score_without_mods,s.legacy_total_score,p.pinned_at FROM zigcho.profile_score_pins p JOIN zigcho.lazer_scores s ON p.source='lazer' AND s.id=p.score_id JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE p.user_id=$1 AND p.mode=$2 AND p.rank_namespace=$3 AND s.passed) SELECT id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score FROM pinned_scores ORDER BY pinned_at DESC,client,id DESC LIMIT 3",
        .stable, .scorev2 => stable_columns ++ "JOIN zigcho.profile_score_pins p ON p.source='stable' AND p.score_id=s.id AND p.user_id=s.user_id WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 AND s.passed ORDER BY p.pinned_at DESC,p.score_id DESC LIMIT 3",
        .lazer => lazer_columns ++ "JOIN zigcho.profile_score_pins p ON p.source='lazer' AND p.score_id=s.id AND p.user_id=s.user_id WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed ORDER BY p.pinned_at DESC,p.score_id DESC LIMIT 3",
    };
    const top_sql: [:0]const u8 = switch (source) {
        .all => "WITH candidates(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score,beatmap_key) AS (" ++
            "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.score,s.score,b.id FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4) UNION ALL " ++
            "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.total_score_without_mods,s.legacy_total_score,b.id FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4))," ++
            "per_map AS (SELECT *,row_number() OVER(PARTITION BY beatmap_key ORDER BY pp DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) map_place FROM candidates) " ++
            "SELECT id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score FROM per_map WHERE map_place=1 ORDER BY pp DESC,beatmap_key ASC,id ASC LIMIT 100",
        .stable, .scorev2 => "WITH candidates AS (" ++ stable_columns ++ "WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4)), ranked AS (SELECT *,row_number() OVER(PARTITION BY map_id ORDER BY pp DESC,id ASC) map_place FROM candidates) SELECT * FROM ranked WHERE map_place=1 ORDER BY pp DESC,map_id ASC,id ASC LIMIT 100",
        .lazer => "WITH candidates AS (" ++ lazer_columns ++ "WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4)), ranked AS (SELECT *,row_number() OVER(PARTITION BY map_id ORDER BY pp DESC,id ASC) map_place FROM candidates) SELECT * FROM ranked WHERE map_place=1 ORDER BY pp DESC,map_id ASC,id ASC LIMIT 100",
    };
    const recent_sql: [:0]const u8 = switch (source) {
        .all => "WITH recent_scores(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score) AS (" ++
            "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.score,s.score FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 UNION ALL " ++
            "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.total_score_without_mods,s.legacy_total_score FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3) " ++
            "SELECT * FROM recent_scores ORDER BY submitted_at DESC,client ASC,id DESC LIMIT 20",
        .lazer => lazer_columns ++ "WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3 ORDER BY s.id DESC LIMIT 20",
        .stable, .scorev2 => stable_columns ++ "WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 ORDER BY s.id DESC LIMIT 20",
    };
    const first_sql: [:0]const u8 = switch (source) {
        .all => database_sql.profile_firsts_all,
        .stable, .scorev2 => database_sql.profile_firsts_stable,
        .lazer => database_sql.profile_firsts_lazer,
    };
    var pinned = try postgres.queryParams(allocator, lease.conn, pinned_sql, &.{ id, score_mode_text, namespace });
    defer pinned.deinit();
    var top = try postgres.queryParams(allocator, lease.conn, top_sql, &.{ id, score_mode_text, namespace });
    defer top.deinit();
    var recent = try postgres.queryParams(allocator, lease.conn, recent_sql, &.{ id, score_mode_text, namespace });
    defer recent.deinit();
    var firsts = try postgres.queryParams(allocator, lease.conn, first_sql, &.{ id, score_mode_text, namespace });
    defer firsts.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"id\":{d},\"name\":", .{try user.int(i32, 0, 0)});
    try common.jsonString(&output.writer, user.value(0, 1));
    try output.writer.writeAll(",\"country\":");
    try common.jsonString(&output.writer, user.value(0, 2));
    try output.writer.print(",\"privileges\":{d},\"created_at\":{d},\"bio\":", .{ try user.int(u32, 0, 3), try user.int(i64, 0, 4) });
    try common.jsonString(&output.writer, user.value(0, 5));
    try output.writer.writeAll(",\"profile_source\":");
    try common.jsonString(&output.writer, user.value(0, 7));
    try output.writer.print(",\"preferred_mode\":{d},\"avatar_version\":{d},\"profile_title\":", .{ try user.int(u8, 0, 6), try user.int(i64, 0, 8) });
    try common.jsonString(&output.writer, user.value(0, 9));
    try output.writer.writeAll(",\"profile_pronouns\":");
    try common.jsonString(&output.writer, user.value(0, 10));
    try output.writer.writeAll(",\"profile_location\":");
    try common.jsonString(&output.writer, user.value(0, 11));
    try output.writer.writeAll(",\"profile_website\":");
    try common.jsonString(&output.writer, user.value(0, 12));
    try output.writer.writeAll(",\"profile_accent\":");
    try common.jsonString(&output.writer, user.value(0, 13));
    const banner_version = try user.int(i64, 0, 16);
    try output.writer.writeAll(",\"banner_url\":");
    if (banner_version > 0) try output.writer.print("\"https://assets.kai.ovh/banners/{d}/cover.jpg?v={d}\"", .{ user_id, banner_version }) else try output.writer.writeAll("null");
    try output.writer.writeAll(",\"team\":");
    if (user.isNull(0, 17)) {
        try output.writer.writeAll("null");
    } else {
        const team_id = try user.int(i32, 0, 17);
        try output.writer.print("{{\"id\":{d},\"name\":", .{team_id});
        try common.jsonString(&output.writer, user.value(0, 18));
        try output.writer.writeAll(",\"short_name\":");
        try common.jsonString(&output.writer, user.value(0, 19));
        const flag_version = try user.int(i64, 0, 20);
        try output.writer.writeAll(",\"flag_url\":");
        if (flag_version > 0) try output.writer.print("\"https://assets.kai.ovh/teams/{d}/flag?v={d}\"", .{ team_id, flag_version }) else try output.writer.writeAll("null");
        try output.writer.writeByte('}');
    }
    const show_profile_stats = owner_view or try user.boolean(0, 14);
    const show_recent_scores = owner_view or try user.boolean(0, 15);
    try output.writer.print(",\"follower_count\":{d},\"stats_public\":{},\"recent_scores_public\":{},\"selected_source\":\"{s}\",\"stats_source\":\"{s}\",\"selected_mode\":{d},\"selected_stats\":", .{ try user.int(i32, 0, 21), show_profile_stats, show_recent_scores, @tagName(source), if (source == .all) "combined" else @tagName(source), stats_mode });
    if (!show_profile_stats or selected_stats.rows() == 0) {
        try output.writer.writeAll("null");
    } else {
        const total_score = @max(@as(i64, 0), try selected_stats.int(i64, 0, 1));
        const level = domain.levelFromTotalScore(total_score);
        const global_rank = try selected_stats.int(i32, 0, 7);
        const selected_pp = try selected_stats.int(i32, 0, 2);
        const replay_views = try pg_social.replayViewCountWithConnection(self, lease.conn, user_id, source, stats_mode);
        const stats_history = try pg_score_maintenance.readStatsHistoryWithConnection(self, lease.conn, user_id, source, stats_mode);
        try output.writer.print("{{\"ranked_score\":{d},\"total_score\":{d},\"pp\":{d},\"plays\":{d},\"play_time\":{d},\"accuracy\":{d},\"max_combo\":{d},\"global_rank\":{d},\"level_current\":{d},\"level_progress\":{d},\"replay_views\":{d},", .{ try selected_stats.int(i64, 0, 0), total_score, selected_pp, try selected_stats.int(i32, 0, 3), try selected_stats.int(i32, 0, 4), try selected_stats.float(f64, 0, 5), try selected_stats.int(i32, 0, 6), global_rank, level.current, level.progress, replay_views });
        try user_json.writeSiteStatsHistory(&output.writer, stats_history);
        try output.writer.writeByte('}');
    }
    try output.writer.writeAll(",\"stats\":[");
    for (0..if (show_profile_stats) stats.rows() else 0) |row| {
        if (row != 0) try output.writer.writeByte(',');
        const raw_mode = try stats.int(u8, row, 0);
        try output.writer.print("{{\"mode\":{d},\"ranked_score\":{d},\"total_score\":{d},\"pp\":{d},\"plays\":{d},\"play_time\":{d},\"total_hits\":{d},\"accuracy\":{d},\"max_combo\":{d},\"global_rank\":{d},\"replay_views\":{d}}}", .{ raw_mode, try stats.int(i64, row, 1), try stats.int(i64, row, 2), try stats.int(i32, row, 3), try stats.int(i32, row, 4), try stats.int(i32, row, 5), try stats.int(i64, row, 6), try stats.float(f64, row, 7), try stats.int(i32, row, 8), try stats.int(i32, row, 9), try pg_social.replayViewCountWithConnection(self, lease.conn, user_id, .all, raw_mode) });
    }
    try output.writer.writeAll("],\"pinned_scores\":");
    if (show_profile_stats) try writeSiteScores(&output.writer, &pinned, false) else try output.writer.writeAll("[]");
    try output.writer.writeAll(",\"top_scores\":");
    if (show_profile_stats) try writeSiteScores(&output.writer, &top, true) else try output.writer.writeAll("[]");
    try output.writer.writeAll(",\"recent_scores\":");
    if (show_recent_scores) try writeSiteScores(&output.writer, &recent, false) else try output.writer.writeAll("[]");
    const first_count: i64 = if (!show_profile_stats or firsts.rows() == 0) 0 else try firsts.int(i64, 0, 22);
    try output.writer.print(",\"first_place_count\":{d},\"first_place_scores\":", .{first_count});
    if (show_profile_stats) try writeSiteScores(&output.writer, &firsts, false) else try output.writer.writeAll("[]");
    try output.writer.writeAll(",\"beatmapsets\":[");
    var mapped_sets = try postgres.queryParams(allocator, lease.conn, "SELECT set_id FROM zigcho.beatmap_submissions WHERE owner_id=$1 AND state='published' ORDER BY updated_at DESC,set_id DESC LIMIT 50", &.{id});
    defer mapped_sets.deinit();
    var mapped_written: usize = 0;
    for (0..mapped_sets.rows()) |row| {
        var mapped_set: std.Io.Writer.Allocating = .init(allocator);
        defer mapped_set.deinit();
        if (!try pg_beatmap_catalog.appendLazerSet(self, lease.conn, &mapped_set.writer, try mapped_sets.int(i32, row, 0), user_id)) continue;
        if (mapped_written != 0) try output.writer.writeByte(',');
        mapped_written += 1;
        try output.writer.writeAll(mapped_set.written());
    }
    try output.writer.writeByte(']');
    try output.writer.writeAll(",\"achievements\":");
    try pg_score_achievements.writeUserAchievementsWithConnection(self, allocator, lease.conn, &output.writer, user_id, true);
    try output.writer.writeByte('}');
    var list = output.toArrayList();
    return try list.toOwnedSlice(allocator);
}

pub fn siteBeatmapLeaderboard(self: anytype, allocator: std.mem.Allocator, map_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !?[]u8 {
    var map_buf: [24]u8 = undefined;
    var mode_buf: [4]u8 = undefined;
    const map_text = try std.fmt.bufPrint(&map_buf, "{d}", .{map_id});
    const score_mode = domain.siteScoreMode(stats_mode);
    const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{score_mode});
    const namespace = domain.siteNamespace(source, stats_mode);
    const source_name = @tagName(source);
    const uses_pp = std.mem.eql(u8, namespace, "relax") or std.mem.eql(u8, namespace, "autopilot");
    var lease = self.pool.acquire();
    defer lease.release();
    var map = try postgres.queryParams(allocator, lease.conn, "SELECT mode FROM zigcho.beatmaps WHERE id=$1", &.{map_text});
    defer map.deinit();
    if (map.rows() == 0 or try map.int(u8, 0, 0) != score_mode) return null;
    const sql =
        "WITH candidates(id,user_id,name,country,privileges,total_score,score_without_mods,legacy_score,pp,accuracy,max_combo,mods,mode,rank_namespace,submitted_at,client,mods_json,has_replay) AS (" ++
        "SELECT s.id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,s.score,s.score,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.submitted_at,'stable',NULL::text,(coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)) FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 JOIN zigcho.users u ON u.id=s.user_id WHERE b.id=$1 AND b.status>=3 AND s.mode=$2 AND s.rank_namespace=$4 AND s.passed AND NOT u.restricted AND u.id!=3 AND ($3='all' OR $3='stable' OR $3='scorev2') AND NOT EXISTS(SELECT 1 FROM zigcho.beatmap_rank_events veto_event WHERE veto_event.set_id=b.set_id AND veto_event.id=(SELECT max(latest_event.id) FROM zigcho.beatmap_rank_events latest_event WHERE latest_event.set_id=b.set_id) AND veto_event.action='veto') UNION ALL " ++
        "SELECT s.id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,s.total_score,s.total_score_without_mods,s.legacy_total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.submitted_at,'lazer',s.mods_json::text,(coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)) FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id JOIN zigcho.users u ON u.id=s.user_id WHERE s.beatmap_id=$1 AND b.status>=3 AND s.ruleset_id=$2 AND s.rank_namespace=$4 AND s.passed AND NOT u.restricted AND u.id!=3 AND ($3='all' OR $3='lazer') AND NOT EXISTS(SELECT 1 FROM zigcho.beatmap_rank_events veto_event WHERE veto_event.set_id=b.set_id AND veto_event.id=(SELECT max(latest_event.id) FROM zigcho.beatmap_rank_events latest_event WHERE latest_event.set_id=b.set_id) AND veto_event.action='veto'))," ++
        "per_user AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY CASE WHEN $3='all' OR $5::boolean THEN pp ELSE total_score::double precision END DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) user_place FROM candidates)," ++
        "board AS (SELECT *,row_number() OVER(ORDER BY CASE WHEN $5::boolean THEN pp ELSE total_score::double precision END DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) position FROM per_user WHERE user_place=1) " ++
        "SELECT position,id,user_id,name,country,privileges,total_score,score_without_mods,legacy_score,pp,accuracy,max_combo,mods,rank_namespace,submitted_at,client,mods_json,has_replay FROM board ORDER BY position LIMIT 100";
    var result = try postgres.queryParams(allocator, lease.conn, sql, &.{ map_text, mode_text, source_name, namespace, if (uses_pp) "true" else "false" });
    defer result.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"map_id\":{d},\"source\":\"{s}\",\"mode\":{d},\"namespace\":", .{ map_id, source_name, stats_mode });
    try common.jsonString(&output.writer, namespace);
    try output.writer.writeAll(",\"scores\":[");
    for (0..result.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        try output.writer.print("{{\"rank\":{d},\"id\":{d},\"user_id\":{d},\"name\":", .{ try result.int(i32, row, 0), try result.int(i64, row, 1), try result.int(i32, row, 2) });
        try common.jsonString(&output.writer, result.value(row, 3));
        try output.writer.writeAll(",\"country\":");
        try common.jsonString(&output.writer, result.value(row, 4));
        try output.writer.print(",\"privileges\":{d},\"score\":{d},\"score_without_mods\":{d},\"legacy_score\":", .{ try result.int(u32, row, 5), try result.int(i64, row, 6), try result.int(i64, row, 7) });
        if (result.isNull(row, 8)) try output.writer.writeAll("null") else try output.writer.print("{d}", .{try result.int(i32, row, 8)});
        try output.writer.print(",\"pp\":{d},\"accuracy\":{d},\"max_combo\":{d},\"mods\":{d},\"namespace\":", .{ try result.float(f64, row, 9), try result.float(f64, row, 10), try result.int(i32, row, 11), try result.int(i32, row, 12) });
        try common.jsonString(&output.writer, result.value(row, 13));
        try output.writer.print(",\"submitted_at\":{d},\"client\":", .{try result.int(i64, row, 14)});
        try common.jsonString(&output.writer, result.value(row, 15));
        try output.writer.writeAll(",\"mods_json\":");
        if (result.isNull(row, 16)) try output.writer.writeAll("null") else try output.writer.writeAll(result.value(row, 16));
        try output.writer.print(",\"has_replay\":{}}}", .{try result.boolean(row, 17)});
    }
    try output.writer.writeAll("]}");
    var list = output.toArrayList();
    return @as(?[]u8, try list.toOwnedSlice(allocator));
}

pub fn statsForUser(self: anytype, user_id: i32, mode: u8) !?domain.Stats {
    var id_buf: [24]u8 = undefined;
    var mode_buf: [4]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,CASE WHEN s.plays>0 THEN (SELECT count(1)+1 FROM zigcho.stats r JOIN zigcho.users u ON u.id=r.user_id WHERE r.mode=s.mode AND r.plays>0 AND u.id!=3 AND NOT u.restricted AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) ELSE 0 END,CASE WHEN s.plays>0 THEN (SELECT count(1)+1 FROM zigcho.stats r JOIN zigcho.users u ON u.id=r.user_id WHERE r.mode=s.mode AND r.plays>0 AND u.id!=3 AND NOT u.restricted AND u.country=me.country AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) ELSE 0 END FROM zigcho.stats s JOIN zigcho.users me ON me.id=s.user_id WHERE s.user_id=$1 AND s.mode=$2", &.{ id, mode_text });
    defer result.deinit();
    if (result.rows() == 0) return null;
    var stats: domain.Stats = .{ .mode = @enumFromInt(mode % 4), .ranked_score = try result.int(i64, 0, 0), .total_score = try result.int(i64, 0, 1), .pp = try result.int(i32, 0, 2), .plays = try result.int(i32, 0, 3), .play_time = try result.int(i32, 0, 4), .total_hits = try result.int(i64, 0, 5), .accuracy = try result.float(f64, 0, 6), .max_combo = try result.int(i32, 0, 7), .global_rank = try result.int(i32, 0, 8), .country_rank = try result.int(i32, 0, 9), .replay_views = try pg_social.replayViewCountWithConnection(self, lease.conn, user_id, .all, mode) };
    var stable = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.mods,s.accuracy,s.n300,s.n100,s.n50,s.nmiss FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4)", &.{ id, mode_text });
    defer stable.deinit();
    for (0..stable.rows()) |row| stats.addGrade(storage_contracts.stableGrade(mode, try stable.int(i32, row, 0), try stable.float(f64, row, 1), try stable.int(i32, row, 2), try stable.int(i32, row, 3), try stable.int(i32, row, 4), try stable.int(i32, row, 5)));
    var modern = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.rank FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4)", &.{ id, mode_text });
    defer modern.deinit();
    for (0..modern.rows()) |row| stats.addGrade(modern.value(row, 0));
    return stats;
}

pub fn statsRulesetsForUser(self: anytype, user_id: i32) ![4]?domain.Stats {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = [_]?domain.Stats{null} ** 4;
    var rows = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.mode,s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,CASE WHEN s.plays>0 THEN (SELECT count(1)+1 FROM zigcho.stats r JOIN zigcho.users u ON u.id=r.user_id WHERE r.mode=s.mode AND r.plays>0 AND u.id!=3 AND NOT u.restricted AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) ELSE 0 END,CASE WHEN s.plays>0 THEN (SELECT count(1)+1 FROM zigcho.stats r JOIN zigcho.users u ON u.id=r.user_id WHERE r.mode=s.mode AND r.plays>0 AND u.id!=3 AND NOT u.restricted AND u.country=me.country AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) ELSE 0 END FROM zigcho.stats s JOIN zigcho.users me ON me.id=s.user_id WHERE s.user_id=$1 AND s.mode BETWEEN 0 AND 3 ORDER BY s.mode", &.{id});
    defer rows.deinit();
    for (0..rows.rows()) |row| {
        const mode = try rows.int(u8, row, 0);
        result[mode] = .{
            .mode = @enumFromInt(mode),
            .ranked_score = try rows.int(i64, row, 1),
            .total_score = try rows.int(i64, row, 2),
            .pp = try rows.int(i32, row, 3),
            .plays = try rows.int(i32, row, 4),
            .play_time = try rows.int(i32, row, 5),
            .total_hits = try rows.int(i64, row, 6),
            .accuracy = try rows.float(f64, row, 7),
            .max_combo = try rows.int(i32, row, 8),
            .global_rank = try rows.int(i32, row, 9),
            .country_rank = try rows.int(i32, row, 10),
        };
    }
    var stable = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.mode,s.mods,s.accuracy,s.n300,s.n100,s.n50,s.nmiss FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 AND s.mode BETWEEN 0 AND 3 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4)", &.{id});
    defer stable.deinit();
    for (0..stable.rows()) |row| {
        const mode = try stable.int(u8, row, 0);
        if (result[mode]) |*stats| stats.addGrade(storage_contracts.stableGrade(mode, try stable.int(i32, row, 1), try stable.float(f64, row, 2), try stable.int(i32, row, 3), try stable.int(i32, row, 4), try stable.int(i32, row, 5), try stable.int(i32, row, 6)));
    }
    var modern = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.ruleset_id,s.rank FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$1 AND s.ruleset_id BETWEEN 0 AND 3 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4)", &.{id});
    defer modern.deinit();
    for (0..modern.rows()) |row| {
        const mode = try modern.int(u8, row, 0);
        if (result[mode]) |*stats| stats.addGrade(modern.value(row, 1));
    }
    for (0..result.len) |mode| if (result[mode]) |*stats| {
        stats.replay_views = try pg_social.replayViewCountWithConnection(self, lease.conn, user_id, .all, @intCast(mode));
    };
    return result;
}

pub fn sourceStatsForUser(self: anytype, user_id: i32, mode: u8, source: domain.SiteScoreSource) !?domain.Stats {
    if (source != .stable and source != .lazer) return error.InvalidScoreSource;
    var id_buf: [24]u8 = undefined;
    var mode_buf: [4]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
    const stable_sql =
        "WITH source_scores AS (SELECT s.user_id,s.id score_id,s.score total_score,s.pp,s.accuracy,s.max_combo,s.passed,s.time_elapsed/1000 play_time,b.status,b.id beatmap_id FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.mode=$2 AND s.rank_namespace='vanilla')," ++
        "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed AND status IN(3,4))," ++
        "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
        "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*)::double precision))) pp,sum(accuracy*power(0.95,performance_index))/(20*(1-power(0.95,count(*)::double precision))) accuracy FROM ranked GROUP BY user_id)," ++
        "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce(sum(play_time),0) play_time,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id)," ++
        "players AS (SELECT a.user_id,a.ranked_score,a.total_score,coalesce(p.pp,0) pp,a.plays,a.play_time,coalesce(p.accuracy,0) accuracy,a.max_combo FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted)," ++
        "ordered AS (SELECT *,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) SELECT ranked_score,total_score,pp,plays,play_time,accuracy,max_combo,global_rank FROM ordered WHERE user_id=$1";
    const lazer_sql =
        "WITH source_scores AS (SELECT s.user_id,s.id score_id,coalesce(s.legacy_total_score,s.total_score) total_score,s.pp,s.accuracy,s.max_combo,s.passed,greatest(b.total_length,0) play_time,b.status,s.beatmap_id FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.ruleset_id=$2 AND s.rank_namespace='vanilla')," ++
        "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed AND status IN(3,4))," ++
        "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
        "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*)::double precision))) pp,sum(accuracy*power(0.95,performance_index))/(20*(1-power(0.95,count(*)::double precision))) accuracy FROM ranked GROUP BY user_id)," ++
        "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce(sum(play_time),0) play_time,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id)," ++
        "players AS (SELECT a.user_id,a.ranked_score,a.total_score,coalesce(p.pp,0) pp,a.plays,a.play_time,coalesce(p.accuracy,0) accuracy,a.max_combo FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted)," ++
        "ordered AS (SELECT *,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) SELECT ranked_score,total_score,pp,plays,play_time,accuracy,max_combo,global_rank FROM ordered WHERE user_id=$1";
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, if (source == .stable) stable_sql else lazer_sql, &.{ id, mode_text });
    defer result.deinit();
    if (result.rows() == 0) return null;
    return .{
        .mode = @enumFromInt(mode % 4),
        .ranked_score = try result.int(i64, 0, 0),
        .total_score = try result.int(i64, 0, 1),
        .pp = try result.int(i32, 0, 2),
        .plays = try result.int(i32, 0, 3),
        .play_time = try result.int(i32, 0, 4),
        .accuracy = try result.float(f64, 0, 5),
        .max_combo = try result.int(i32, 0, 6),
        .global_rank = try result.int(i32, 0, 7),
        .replay_views = try pg_social.replayViewCountWithConnection(self, lease.conn, user_id, source, mode),
    };
}

pub fn beatmapForScore(self: anytype, md5: []const u8) !?BeatmapForScore {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,set_id,status,plays,passes,coalesce(last_update,0) FROM zigcho.beatmaps WHERE md5=$1", &.{md5});
    defer result.deinit();
    if (result.rows() == 0) return null;
    return .{ .id = try result.int(i32, 0, 0), .set_id = try result.int(i32, 0, 1), .status = try result.int(i8, 0, 2), .plays = try result.int(i32, 0, 3), .passes = try result.int(i32, 0, 4), .last_update = try result.int(i64, 0, 5) };
}

pub fn scoreLeaderboardPlacement(self: anytype, score_id: i64) !?domain.ScorePlacement {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{score_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.best,(SELECT count(*) FROM zigcho.scores o WHERE o.map_md5=pb.map_md5 AND o.mode=pb.mode AND o.rank_namespace=pb.rank_namespace AND o.passed AND o.best AND ((pb.rank_namespace IN('vanilla','scorev2') AND (o.score>pb.score OR (o.score=pb.score AND o.id<pb.id))) OR (pb.rank_namespace IN('relax','autopilot') AND (o.pp>pb.pp OR (o.pp=pb.pp AND o.id<pb.id))))) FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 JOIN zigcho.scores pb ON pb.user_id=s.user_id AND pb.map_md5=s.map_md5 AND pb.mode=s.mode AND pb.rank_namespace=s.rank_namespace AND pb.passed AND pb.best WHERE s.id=$1 AND s.passed AND b.status>=3", &.{id});
    defer result.deinit();
    if (result.rows() == 0) return null;
    return .{ .submitted_is_best = try result.boolean(0, 0), .rank = try result.int(i32, 0, 1) };
}

pub fn beatmapInfo(self: anytype, allocator: std.mem.Allocator, md5: []const u8) !?BeatmapInfo {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,set_id,max_combo,artist,title,version,creator,status,star_rating,greatest(total_length,0),greatest(CASE WHEN hit_length>0 THEN hit_length ELSE total_length END,0) FROM zigcho.beatmaps WHERE md5=$1", &.{md5});
    defer result.deinit();
    if (result.rows() == 0) return null;
    const artist = try allocator.dupe(u8, result.value(0, 3));
    errdefer allocator.free(artist);
    const title = try allocator.dupe(u8, result.value(0, 4));
    errdefer allocator.free(title);
    const version = try allocator.dupe(u8, result.value(0, 5));
    errdefer allocator.free(version);
    const creator = try allocator.dupe(u8, result.value(0, 6));
    return .{ .id = try result.int(i32, 0, 0), .set_id = try result.int(i32, 0, 1), .max_combo = try result.int(i32, 0, 2), .artist = artist, .title = title, .version = version, .creator = creator, .status = try result.int(i8, 0, 7), .star_rating = try result.float(f64, 0, 8), .total_length = try result.int(i32, 0, 9), .hit_length = try result.int(i32, 0, 10) };
}

pub fn beatmapInfoById(self: anytype, allocator: std.mem.Allocator, map_id: i32) !?BeatmapInfo {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{map_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,set_id,max_combo,artist,title,version,creator,status,star_rating,greatest(total_length,0),greatest(CASE WHEN hit_length>0 THEN hit_length ELSE total_length END,0) FROM zigcho.beatmaps WHERE id=$1", &.{id});
    defer result.deinit();
    if (result.rows() == 0) return null;
    const artist = try allocator.dupe(u8, result.value(0, 3));
    errdefer allocator.free(artist);
    const title = try allocator.dupe(u8, result.value(0, 4));
    errdefer allocator.free(title);
    const version = try allocator.dupe(u8, result.value(0, 5));
    errdefer allocator.free(version);
    const creator = try allocator.dupe(u8, result.value(0, 6));
    return .{ .id = try result.int(i32, 0, 0), .set_id = try result.int(i32, 0, 1), .max_combo = try result.int(i32, 0, 2), .artist = artist, .title = title, .version = version, .creator = creator, .status = try result.int(i8, 0, 7), .star_rating = try result.float(f64, 0, 8), .total_length = try result.int(i32, 0, 9), .hit_length = try result.int(i32, 0, 10) };
}

pub fn ppSnapshot(self: anytype, score_id: i64) !?PpSnapshot {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{score_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.pp,t.pp FROM zigcho.scores s JOIN zigcho.stats t ON t.user_id=s.user_id AND t.mode=CASE WHEN (s.mods&8192)!=0 THEN s.mode+8 WHEN (s.mods&128)!=0 THEN s.mode+4 ELSE s.mode END WHERE s.id=$1", &.{id});
    defer result.deinit();
    if (result.rows() == 0) return null;
    return .{ .score = try result.float(f64, 0, 0), .player = try result.int(i64, 0, 1) };
}
