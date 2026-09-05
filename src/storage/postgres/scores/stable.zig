const std = @import("std");
const domain = @import("../../../domain.zig");
const postgres = @import("../../../postgres.zig");
const storage_contracts = @import("../../contracts.zig");
const stable_score = @import("../../../stable_score.zig");
const beatmap = @import("../../../beatmap.zig");
const lazer = @import("../../../lazer.zig");
const stable_mods = @import("../../../stable_mods.zig");
const common = @import("../common.zig");
const pg_score_achievements = @import("../scores/achievements.zig");
const pg_score_maintenance = @import("../scores/maintenance.zig");

const lazerStatus = storage_contracts.lazerStatus;

pub fn stableClassicLeaderboardJson(self: anytype, allocator: std.mem.Allocator, requester_id: i32, beatmap_id: i32, ruleset_id: u8, limit: u8) ![]u8 {
    var buffers: [32][64]u8 = undefined;
    var cursor: usize = 0;
    const requester = try common.param(&buffers, &cursor, requester_id);
    const beatmap_text = try common.param(&buffers, &cursor, beatmap_id);
    const ruleset = try common.param(&buffers, &cursor, ruleset_id);
    const limit_text = try common.param(&buffers, &cursor, limit);
    var lease = self.pool.acquire();
    defer lease.release();
    const sql =
        "WITH ordered AS (" ++
        "SELECT s.*,b.status,b.set_id,b.id beatmap_id,b.star_rating AS beatmap_star_rating,b.version,b.artist,b.title,b.creator,tm.team_id,t.name team_name,t.short_name team_short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0) team_flag_version,row_number() OVER(PARTITION BY s.user_id ORDER BY s.score DESC,s.id ASC) AS user_place " ++
        "FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id JOIN zigcho.beatmaps b ON b.md5=s.map_md5 " ++
        "WHERE b.id=$1 AND b.status>=3 AND s.mode=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND NOT u.restricted)," ++
        "board AS (SELECT *,row_number() OVER(ORDER BY score DESC,id ASC) AS position,count(*) OVER() AS score_count FROM ordered WHERE user_place=1) " ++
        "SELECT position,score_count,id,user_id,(SELECT name FROM zigcho.users WHERE id=board.user_id),(SELECT country FROM zigcho.users WHERE id=board.user_id),beatmap_id,mode,score,pp,accuracy,max_combo,n300,n100,n50,ngeki,nkatu,nmiss,perfect,mods,to_char(to_timestamp(submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),status,set_id,map_md5,beatmap_star_rating,version,artist,title,creator,team_id,team_name,team_short_name,team_flag_version,(coalesce(octet_length(replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=board.id)) " ++
        "FROM board WHERE position<=$3 OR user_id=$4 ORDER BY position";
    var result = try postgres.queryParams(allocator, lease.conn, sql, &.{ beatmap_text, ruleset, limit_text, requester });
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
        var mods: std.Io.Writer.Allocating = .init(allocator);
        defer mods.deinit();
        const mod_bits = try result.int(i32, row, 19);
        try stable_mods.writeLazerJson(&mods.writer, mod_bits, true);
        var statistics: std.Io.Writer.Allocating = .init(allocator);
        defer statistics.deinit();
        const n300 = try result.int(i32, row, 12);
        const n100 = try result.int(i32, row, 13);
        const n50 = try result.int(i32, row, 14);
        const ngeki = try result.int(i32, row, 15);
        const nkatu = try result.int(i32, row, 16);
        const nmiss = try result.int(i32, row, 17);
        try stable_mods.writeLazerStatistics(&statistics.writer, ruleset_id, n300, n100, n50, ngeki, nkatu, nmiss);
        const status = try result.int(i32, row, 21);
        const score: lazer.LeaderboardScore = .{
            .id = try result.int(i64, row, 2),
            .legacy_score_id = try result.int(i64, row, 2),
            .legacy_total_score = lazer.stableLegacyTotalScore(try result.int(i64, row, 8)),
            .user_id = try result.int(i32, row, 3),
            .username = result.value(row, 4),
            .country = result.value(row, 5),
            .beatmap_id = try result.int(i32, row, 6),
            .ruleset_id = try result.int(i32, row, 7),
            .total_score = try result.int(i64, row, 8),
            .total_score_without_mods = try result.int(i64, row, 8),
            .pp = try result.float(f64, row, 9),
            .accuracy = try result.float(f64, row, 10),
            .max_combo = try result.int(i32, row, 11),
            .passed = true,
            .rank = storage_contracts.stableGrade(ruleset_id, mod_bits, try result.float(f64, row, 10), n300, n100, n50, nmiss),
            .mods_json = mods.written(),
            .statistics_json = statistics.written(),
            .maximum_statistics_json = "{}",
            .pauses_json = "[]",
            .ended_at = result.value(row, 20),
            .ranked = status == 3 or status == 4,
            .has_replay = try result.boolean(row, 33),
            .team = if (result.isNull(row, 29)) null else try domain.TeamSummary.init(try result.int(i32, row, 29), result.value(row, 30), result.value(row, 31), try result.int(i64, row, 32)),
            .beatmap = .{
                .id = try result.int(i32, row, 6),
                .set_id = try result.int(i32, row, 22),
                .status = lazerStatus(status),
                .checksum = result.value(row, 23),
                .ruleset_id = ruleset_id,
                .star_rating = try result.float(f64, row, 24),
                .version = result.value(row, 25),
                .artist = result.value(row, 26),
                .title = result.value(row, 27),
                .creator = result.value(row, 28),
            },
        };
        if (position <= limit) {
            if (written != 0) try scores.writer.writeByte(',');
            try lazer.writeLeaderboardScore(&scores.writer, score);
            written += 1;
        }
        if (score.user_id == requester_id) {
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

pub fn insertStableScore(self: anytype, user_id: i32, score: stable_score.Submission, pp_value: f64, replay_data: []const u8, time_elapsed_ms: u32) !i64 {
    const stats_mode = stable_score.statsMode(score.mode, score.mods) orelse return error.UnsupportedModMode;
    const namespace = score.rankNamespace();
    const uses_pp = stable_mods.usesPpMetric(namespace);
    const updates_player_stats = stable_mods.updatesPlayerStats(namespace);
    const replay_encoded = try postgres.encodeBytea(self.allocator, replay_data);
    defer self.allocator.free(replay_encoded);

    var user_buf: [24]u8 = undefined;
    var mode_buf: [4]u8 = undefined;
    var stats_mode_buf: [4]u8 = undefined;
    var mods_buf: [16]u8 = undefined;
    var score_buf: [32]u8 = undefined;
    var pp_buf: [64]u8 = undefined;
    var accuracy_buf: [64]u8 = undefined;
    var combo_buf: [16]u8 = undefined;
    var n300_buf: [16]u8 = undefined;
    var n100_buf: [16]u8 = undefined;
    var n50_buf: [16]u8 = undefined;
    var nmiss_buf: [16]u8 = undefined;
    var ngeki_buf: [16]u8 = undefined;
    var nkatu_buf: [16]u8 = undefined;
    var elapsed_buf: [24]u8 = undefined;
    var star_buf: [64]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const mode = try std.fmt.bufPrint(&mode_buf, "{d}", .{score.mode});
    const stats_mode_text = try std.fmt.bufPrint(&stats_mode_buf, "{d}", .{stats_mode});
    const mods = try std.fmt.bufPrint(&mods_buf, "{d}", .{score.mods});
    const score_text = try std.fmt.bufPrint(&score_buf, "{d}", .{score.total_score});
    const pp = try std.fmt.bufPrint(&pp_buf, "{d}", .{pp_value});
    const accuracy = try std.fmt.bufPrint(&accuracy_buf, "{d}", .{score.accuracy()});
    const combo = try std.fmt.bufPrint(&combo_buf, "{d}", .{score.max_combo});
    const n300 = try std.fmt.bufPrint(&n300_buf, "{d}", .{score.n300});
    const n100 = try std.fmt.bufPrint(&n100_buf, "{d}", .{score.n100});
    const n50 = try std.fmt.bufPrint(&n50_buf, "{d}", .{score.n50});
    const nmiss = try std.fmt.bufPrint(&nmiss_buf, "{d}", .{score.nmiss});
    const ngeki = try std.fmt.bufPrint(&ngeki_buf, "{d}", .{score.ngeki});
    const nkatu = try std.fmt.bufPrint(&nkatu_buf, "{d}", .{score.nkatu});
    const elapsed = try std.fmt.bufPrint(&elapsed_buf, "{d}", .{time_elapsed_ms});
    const star_rating = try std.fmt.bufPrint(&star_buf, "{d}", .{score.achievement_stars});

    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var scope_lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT pg_advisory_xact_lock(hashtextextended('zigcho:stable-best:'||$1||':'||$2||':'||$3||':'||$4,0))", &.{ user, score.map_md5, mode, namespace });
    scope_lock.deinit();
    // Stable and lazer both lock the beatmap before the user's stats row.
    // Keeping this order identical prevents a cross-client submission from
    // forming a map -> stats / stats -> map deadlock cycle.
    var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT status FROM zigcho.beatmaps WHERE md5=$1 FOR UPDATE", &.{score.map_md5});
    defer map.deinit();
    if (map.rows() == 0) return error.DatabaseQueryFailed;
    const map_status = try map.int(i32, 0, 0);
    if (updates_player_stats) {
        var stats_lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.stats WHERE user_id=$1 AND mode=$2 FOR UPDATE", &.{ user, stats_mode_text });
        defer stats_lock.deinit();
        if (stats_lock.rows() == 0) return error.DatabaseQueryFailed;
    }

    const perfect = if (score.perfect) "true" else "false";
    const passed = if (score.passed) "true" else "false";
    var inserted = postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,checksum,rank_namespace,best,time_elapsed,star_rating) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,false,$20,$21) RETURNING id", &.{ user, score.map_md5, mode, mods, score_text, pp, accuracy, combo, n300, n100, n50, nmiss, ngeki, nkatu, perfect, passed, replay_encoded, score.online_checksum, namespace, elapsed, star_rating }) catch |err| switch (err) {
        error.UniqueViolation => return error.DuplicateScore,
        else => return err,
    };
    defer inserted.deinit();
    const score_id = try inserted.int(i64, 0, 0);

    if (score.passed) {
        var unset = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.scores SET best=false WHERE user_id=$1 AND map_md5=$2 AND mode=$3 AND rank_namespace=$4 AND best", &.{ user, score.map_md5, mode, namespace });
        unset.deinit();
        const promote_sql = if (uses_pp)
            "UPDATE zigcho.scores SET best=true WHERE id=(SELECT id FROM zigcho.scores WHERE user_id=$1 AND map_md5=$2 AND mode=$3 AND rank_namespace=$4 AND passed ORDER BY pp DESC,id ASC LIMIT 1)"
        else
            "UPDATE zigcho.scores SET best=true WHERE id=(SELECT id FROM zigcho.scores WHERE user_id=$1 AND map_md5=$2 AND mode=$3 AND rank_namespace=$4 AND passed ORDER BY score DESC,id ASC LIMIT 1)";
        var promote = try postgres.queryParams(self.allocator, lease.conn, promote_sql, &.{ user, score.map_md5, mode, namespace });
        promote.deinit();
    }
    const leaderboard = map_status >= 3;
    const ranked = map_status == 3 or map_status == 4;
    if (updates_player_stats) {
        const total_hits: i64 = @as(i64, score.n300) + score.n100 + score.n50 + if (score.mode == 1 or score.mode == 3) @as(i64, score.ngeki) + score.nkatu else 0;
        var ranked_buf: [32]u8 = undefined;
        var seconds_buf: [24]u8 = undefined;
        var hits_buf: [32]u8 = undefined;
        const ranked_text = try std.fmt.bufPrint(&ranked_buf, "{d}", .{@as(i64, 0)});
        const seconds = try std.fmt.bufPrint(&seconds_buf, "{d}", .{time_elapsed_ms / 1000});
        const hits = try std.fmt.bufPrint(&hits_buf, "{d}", .{total_hits});
        var update_stats = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.stats SET total_score=total_score+$1,ranked_score=ranked_score+$2,plays=plays+1,play_time=play_time+$3,total_hits=total_hits+$4,max_combo=CASE WHEN $5::boolean THEN greatest(max_combo,$6) ELSE max_combo END WHERE user_id=$7 AND mode=$8", &.{ score_text, ranked_text, seconds, hits, if (score.passed and leaderboard) "true" else "false", combo, user, stats_mode_text });
        update_stats.deinit();
    }
    var update_map = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmaps SET plays=plays+1,passes=passes+$1 WHERE md5=$2", &.{ if (score.passed) "1" else "0", score.map_md5 });
    update_map.deinit();

    if (updates_player_stats and score.passed and ranked) {
        try pg_score_maintenance.rebuildCombinedPerformanceWithConnection(self, lease.conn, user_id, score.mode, stats_mode, namespace, false);
    }
    try pg_score_maintenance.pruneStatsHistoryWithConnection(self, lease.conn);
    try pg_score_maintenance.recordStatsHistorySliceCurrentWithConnection(self, lease.conn, if (std.mem.eql(u8, namespace, "scorev2")) .scorev2 else .stable, stats_mode, user_id);
    if (updates_player_stats) try pg_score_maintenance.recordStatsHistorySliceCurrentWithConnection(self, lease.conn, .all, stats_mode, user_id);
    try pg_score_achievements.awardAchievementsWithConnection(self, lease.conn, user_id, "stable", score_id, .{
        .eligible = score.passed and std.mem.eql(u8, namespace, "vanilla") and ranked,
        .mode = score.mode,
        .mods = @intCast(score.mods),
        .perfect = score.perfect,
        .max_combo = @intCast(score.max_combo),
        .stars = score.achievement_stars,
        .accuracy = score.accuracy(),
        .pp = pp_value,
    });
    try postgres.exec(lease.conn, "COMMIT");
    return score_id;
}
