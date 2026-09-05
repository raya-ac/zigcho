const std = @import("std");
const domain = @import("../../../domain.zig");
const stable_score = @import("../../../stable_score.zig");
const lazer = @import("../../../lazer.zig");
const stable_mods = @import("../../../stable_mods.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;

pub fn insertLazerScore(self: *Store, user_id: i32, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8) !i64 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    const score_id = try self.insertLazerScoreLocked(user_id, input, pp_value, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data);
    try self.exec("COMMIT");
    return score_id;
}

pub fn insertLazerScoreLocked(self: *Store, user_id: i32, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8) !i64 {
    const namespace = @tagName(input.namespace);
    const medal_categories = try lazer.medalModCategories(self.allocator, mods_json);
    const rank = input.rank orelse if (input.passed) "D" else "F";
    var previous_best_id: i64 = 0;
    var previous_pp: f64 = 0;
    var previous_score: i64 = 0;
    var previous: ?*c.sqlite3_stmt = null;
    const previous_sql = "SELECT id,pp,total_score FROM lazer_scores WHERE user_id=?1 AND beatmap_id=?2 AND ruleset_id=?3 AND rank_namespace=?4 AND best=1 LIMIT 1";
    if (c.sqlite3_prepare_v2(self.db, previous_sql, -1, &previous, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_int(previous, 1, user_id);
    _ = c.sqlite3_bind_int64(previous, 2, input.beatmap_id);
    _ = c.sqlite3_bind_int64(previous, 3, input.ruleset_id);
    _ = c.sqlite3_bind_text(previous, 4, namespace.ptr, @intCast(namespace.len), null);
    if (c.sqlite3_step(previous) == c.SQLITE_ROW) {
        previous_best_id = c.sqlite3_column_int64(previous, 0);
        previous_pp = c.sqlite3_column_double(previous, 1);
        previous_score = c.sqlite3_column_int64(previous, 2);
    }
    _ = c.sqlite3_finalize(previous);
    const is_best = input.passed and (previous_best_id == 0 or pp_value > previous_pp or (pp_value == previous_pp and input.total_score > previous_score));
    const sql = "INSERT INTO lazer_scores(user_id,beatmap_id,ruleset_id,total_score,total_score_without_mods,legacy_total_score,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,rank_namespace,client_version,pp,best,replay,star_rating) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20)";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int64(stmt, 2, input.beatmap_id);
    _ = c.sqlite3_bind_int64(stmt, 3, input.ruleset_id);
    _ = c.sqlite3_bind_int64(stmt, 4, input.total_score);
    _ = c.sqlite3_bind_int64(stmt, 5, input.total_score_without_mods);
    _ = c.sqlite3_bind_int(stmt, 6, lazer.classicTotalScore(input));
    _ = c.sqlite3_bind_double(stmt, 7, input.accuracy);
    _ = c.sqlite3_bind_int64(stmt, 8, input.max_combo);
    _ = c.sqlite3_bind_int(stmt, 9, @intFromBool(input.passed));
    _ = c.sqlite3_bind_text(stmt, 10, rank.ptr, @intCast(rank.len), null);
    _ = c.sqlite3_bind_text(stmt, 11, mods_json.ptr, @intCast(mods_json.len), null);
    _ = c.sqlite3_bind_text(stmt, 12, statistics_json.ptr, @intCast(statistics_json.len), null);
    _ = c.sqlite3_bind_text(stmt, 13, maximum_statistics_json.ptr, @intCast(maximum_statistics_json.len), null);
    _ = c.sqlite3_bind_text(stmt, 14, pauses_json.ptr, @intCast(pauses_json.len), null);
    _ = c.sqlite3_bind_text(stmt, 15, namespace.ptr, @intCast(namespace.len), null);
    if (input.client_version) |version| {
        _ = c.sqlite3_bind_text(stmt, 16, version.ptr, @intCast(version.len), null);
    } else _ = c.sqlite3_bind_null(stmt, 16);
    _ = c.sqlite3_bind_double(stmt, 17, pp_value);
    _ = c.sqlite3_bind_int(stmt, 18, @intFromBool(is_best));
    if (replay_data.len == 0)
        _ = c.sqlite3_bind_null(stmt, 19)
    else
        _ = c.sqlite3_bind_blob(stmt, 19, replay_data.ptr, @intCast(replay_data.len), null);
    _ = c.sqlite3_bind_double(stmt, 20, input.achievement_stars);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    const score_id = c.sqlite3_last_insert_rowid(self.db);
    if (is_best and previous_best_id != 0) {
        var unset: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE lazer_scores SET best=0 WHERE id=?1", -1, &unset, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(unset);
        _ = c.sqlite3_bind_int64(unset, 1, previous_best_id);
        if (c.sqlite3_step(unset) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }
    try self.updateLazerStatsLocked(user_id, input);
    if (lazer.statsMode(input)) |stats_mode| {
        try self.pruneStatsHistoryLocked();
        try self.recordStatsHistorySliceCurrentLocked(.lazer, stats_mode, user_id);
        try self.recordStatsHistorySliceCurrentLocked(.all, stats_mode, user_id);
    }
    var map: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT status FROM beatmaps WHERE id=?1", -1, &map, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(map);
    _ = c.sqlite3_bind_int64(map, 1, input.beatmap_id);
    const ranked = c.sqlite3_step(map) == c.SQLITE_ROW and (c.sqlite3_column_int(map, 0) == 3 or c.sqlite3_column_int(map, 0) == 4);
    try self.awardAchievementsLocked(user_id, "lazer", score_id, .{
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

pub fn updateLazerStatsLocked(self: *Store, user_id: i32, input: lazer.ScoreInput) !void {
    var map: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT md5,status,max(total_length,0) FROM beatmaps WHERE id=?1", -1, &map, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(map);
    _ = c.sqlite3_bind_int64(map, 1, input.beatmap_id);
    if (c.sqlite3_step(map) != c.SQLITE_ROW) return;
    const map_status = c.sqlite3_column_int(map, 1);
    const play_time = c.sqlite3_column_int64(map, 2);

    if (lazer.statsMode(input)) |stats_mode| {
        const legacy_score = lazer.classicTotalScore(input);
        const hits = lazer.totalHits(input);
        var update: ?*c.sqlite3_stmt = null;
        const update_sql = "UPDATE stats SET total_score=total_score+?1,ranked_score=ranked_score+?2,plays=plays+1,play_time=play_time+?3,total_hits=total_hits+?4,max_combo=CASE WHEN ?5=1 THEN max(max_combo,?6) ELSE max_combo END WHERE user_id=?7 AND mode=?8";
        if (c.sqlite3_prepare_v2(self.db, update_sql, -1, &update, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(update);
        _ = c.sqlite3_bind_int64(update, 1, legacy_score);
        _ = c.sqlite3_bind_int64(update, 2, 0);
        _ = c.sqlite3_bind_int64(update, 3, play_time);
        _ = c.sqlite3_bind_int64(update, 4, hits);
        _ = c.sqlite3_bind_int(update, 5, @intFromBool(input.passed and map_status >= 3));
        _ = c.sqlite3_bind_int64(update, 6, input.max_combo);
        _ = c.sqlite3_bind_int(update, 7, user_id);
        _ = c.sqlite3_bind_int(update, 8, stats_mode);
        if (c.sqlite3_step(update) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    var map_update: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmaps SET plays=plays+1,passes=passes+?1 WHERE id=?2", -1, &map_update, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(map_update);
    _ = c.sqlite3_bind_int(map_update, 1, @intFromBool(input.passed));
    _ = c.sqlite3_bind_int64(map_update, 2, input.beatmap_id);
    if (c.sqlite3_step(map_update) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    if (lazer.statsMode(input)) |stats_mode| {
        if (input.passed and (map_status == 3 or map_status == 4)) try self.rebuildCombinedPerformanceLocked(user_id, @intCast(input.ruleset_id), stats_mode, @tagName(input.namespace));
    }
}

pub fn rebuildCombinedPerformanceLocked(self: *Store, user_id: i32, ruleset_id: u8, stats_mode: u8, namespace: []const u8) !void {
    const sql =
        "WITH candidates AS (" ++
        "SELECT b.id beatmap_id,s.pp,s.accuracy,s.score legacy_score,0 source,s.id score_id FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=?1 AND s.mode=?2 AND s.rank_namespace=?3 AND s.passed=1 AND b.status IN(3,4) " ++
        "UNION ALL SELECT s.beatmap_id,s.pp,s.accuracy,coalesce(s.legacy_total_score,s.total_score),1,s.id FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=?1 AND s.ruleset_id=?2 AND s.rank_namespace=?3 AND s.passed=1 AND b.status IN(3,4))," ++
        "per_map AS (SELECT *,row_number() OVER(PARTITION BY beatmap_id ORDER BY pp DESC,source ASC,score_id ASC) map_place FROM candidates) " ++
        "SELECT pp,accuracy,legacy_score FROM per_map WHERE map_place=1 ORDER BY pp DESC,beatmap_id ASC";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, ruleset_id);
    _ = c.sqlite3_bind_text(stmt, 3, namespace.ptr, @intCast(namespace.len), null);
    var total_pp: f64 = 0;
    var weighted_accuracy: f64 = 0;
    var weight: f64 = 1;
    var score_count: u32 = 0;
    var ranked_score: i64 = 0;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        total_pp += c.sqlite3_column_double(stmt, 0) * weight;
        weighted_accuracy += c.sqlite3_column_double(stmt, 1) * weight;
        ranked_score += c.sqlite3_column_int64(stmt, 2);
        weight *= 0.95;
        score_count += 1;
    }
    const bonus_pp = 416.6667 * (1.0 - std.math.pow(f64, 0.9994, @floatFromInt(score_count)));
    const accuracy = if (score_count == 0) 0 else weighted_accuracy / (20.0 * (1.0 - std.math.pow(f64, 0.95, @floatFromInt(score_count))));
    var update: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE stats SET pp=?1,accuracy=?2,ranked_score=?3 WHERE user_id=?4 AND mode=?5", -1, &update, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(update);
    _ = c.sqlite3_bind_int64(update, 1, @intFromFloat(@round(total_pp + bonus_pp)));
    _ = c.sqlite3_bind_double(update, 2, accuracy);
    _ = c.sqlite3_bind_int64(update, 3, ranked_score);
    _ = c.sqlite3_bind_int(update, 4, user_id);
    _ = c.sqlite3_bind_int(update, 5, stats_mode);
    if (c.sqlite3_step(update) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn insertStableScore(self: *Store, user_id: i32, score: stable_score.Submission, pp_value: f64, replay_data: []const u8, time_elapsed_ms: u32) !i64 {
    return (try insertStableScoreWithChart(self, user_id, score, pp_value, replay_data, time_elapsed_ms)).id;
}

pub fn insertStableScoreWithChart(self: *Store, user_id: i32, score: stable_score.Submission, pp_value: f64, replay_data: []const u8, time_elapsed_ms: u32) !domain.StableScoreInsert {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    const namespace = score.rankNamespace();
    var previous_best_id: i64 = 0;
    var previous_best_score: i64 = 0;
    var previous_best_pp: f64 = 0;
    var previous_best: ?domain.StablePersonalBest = null;
    const best_sql = "SELECT pb.id,pb.score,pb.pp,pb.max_combo,pb.accuracy,1+(SELECT count(*) FROM scores o WHERE o.map_md5=pb.map_md5 AND o.mode=pb.mode AND o.rank_namespace=pb.rank_namespace AND o.passed=1 AND o.best=1 AND ((pb.rank_namespace IN('vanilla','scorev2') AND (o.score>pb.score OR (o.score=pb.score AND o.id<pb.id))) OR (pb.rank_namespace IN('relax','autopilot') AND (o.pp>pb.pp OR (o.pp=pb.pp AND o.id<pb.id))))) FROM scores pb WHERE pb.user_id=?1 AND pb.map_md5=?2 AND pb.mode=?3 AND pb.rank_namespace=?4 AND pb.best=1 LIMIT 1";
    var best_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, best_sql, -1, &best_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_int(best_stmt, 1, user_id);
    _ = c.sqlite3_bind_text(best_stmt, 2, score.map_md5.ptr, @intCast(score.map_md5.len), null);
    _ = c.sqlite3_bind_int(best_stmt, 3, score.mode);
    _ = c.sqlite3_bind_text(best_stmt, 4, namespace.ptr, @intCast(namespace.len), null);
    if (c.sqlite3_step(best_stmt) == c.SQLITE_ROW) {
        previous_best_id = c.sqlite3_column_int64(best_stmt, 0);
        previous_best_score = c.sqlite3_column_int64(best_stmt, 1);
        previous_best_pp = c.sqlite3_column_double(best_stmt, 2);
        previous_best = .{
            .total_score = previous_best_score,
            .pp = previous_best_pp,
            .max_combo = c.sqlite3_column_int(best_stmt, 3),
            .accuracy = c.sqlite3_column_double(best_stmt, 4),
            .rank = c.sqlite3_column_int(best_stmt, 5),
        };
    }
    _ = c.sqlite3_finalize(best_stmt);
    const uses_pp_metric = stable_mods.usesPpMetric(namespace);
    const updates_player_stats = stable_mods.updatesPlayerStats(namespace);
    const is_best = score.passed and if (uses_pp_metric) pp_value > previous_best_pp else score.total_score > previous_best_score;
    const stats_mode = stable_score.statsMode(score.mode, score.mods) orelse return error.UnsupportedModMode;
    const sql = "INSERT INTO scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,checksum,rank_namespace,best,time_elapsed,star_rating) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22)";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_text(stmt, 2, score.map_md5.ptr, @intCast(score.map_md5.len), null);
    _ = c.sqlite3_bind_int(stmt, 3, score.mode);
    _ = c.sqlite3_bind_int(stmt, 4, score.mods);
    _ = c.sqlite3_bind_int64(stmt, 5, score.total_score);
    _ = c.sqlite3_bind_double(stmt, 6, pp_value);
    _ = c.sqlite3_bind_double(stmt, 7, score.accuracy());
    _ = c.sqlite3_bind_int(stmt, 8, score.max_combo);
    _ = c.sqlite3_bind_int(stmt, 9, score.n300);
    _ = c.sqlite3_bind_int(stmt, 10, score.n100);
    _ = c.sqlite3_bind_int(stmt, 11, score.n50);
    _ = c.sqlite3_bind_int(stmt, 12, score.nmiss);
    _ = c.sqlite3_bind_int(stmt, 13, score.ngeki);
    _ = c.sqlite3_bind_int(stmt, 14, score.nkatu);
    _ = c.sqlite3_bind_int(stmt, 15, @intFromBool(score.perfect));
    _ = c.sqlite3_bind_int(stmt, 16, @intFromBool(score.passed));
    _ = c.sqlite3_bind_blob(stmt, 17, replay_data.ptr, @intCast(replay_data.len), null);
    _ = c.sqlite3_bind_text(stmt, 18, score.online_checksum.ptr, @intCast(score.online_checksum.len), null);
    _ = c.sqlite3_bind_text(stmt, 19, namespace.ptr, @intCast(namespace.len), null);
    _ = c.sqlite3_bind_int(stmt, 20, @intFromBool(is_best));
    _ = c.sqlite3_bind_int64(stmt, 21, time_elapsed_ms);
    _ = c.sqlite3_bind_double(stmt, 22, score.achievement_stars);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return if (c.sqlite3_extended_errcode(self.db) == c.SQLITE_CONSTRAINT_UNIQUE) error.DuplicateScore else error.DatabaseQueryFailed;
    const id = c.sqlite3_last_insert_rowid(self.db);
    if (is_best and previous_best_id != 0) {
        const unset = "UPDATE scores SET best=0 WHERE id=?1";
        var unset_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, unset, -1, &unset_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int64(unset_stmt, 1, previous_best_id);
        if (c.sqlite3_step(unset_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        _ = c.sqlite3_finalize(unset_stmt);
    }
    const status_sql = "SELECT status FROM beatmaps WHERE md5=?1";
    var status_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, status_sql, -1, &status_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(status_stmt);
    _ = c.sqlite3_bind_text(status_stmt, 1, score.map_md5.ptr, @intCast(score.map_md5.len), null);
    if (c.sqlite3_step(status_stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    const map_status = c.sqlite3_column_int(status_stmt, 0);
    const has_leaderboard = map_status >= 3;
    const awards_ranked_pp = map_status == 3 or map_status == 4;
    if (updates_player_stats) {
        const total_hits: i64 = @as(i64, score.n300) + score.n100 + score.n50 + if (score.mode == 1 or score.mode == 3) @as(i64, score.ngeki) + score.nkatu else 0;
        const update_stats = "UPDATE stats SET total_score=total_score+?1,ranked_score=ranked_score+?2,plays=plays+1,play_time=play_time+?3,total_hits=total_hits+?4,max_combo=CASE WHEN ?5=1 THEN max(max_combo,?6) ELSE max_combo END WHERE user_id=?7 AND mode=?8";
        var stats_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, update_stats, -1, &stats_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stats_stmt);
        _ = c.sqlite3_bind_int64(stats_stmt, 1, score.total_score);
        _ = c.sqlite3_bind_int64(stats_stmt, 2, 0);
        _ = c.sqlite3_bind_int64(stats_stmt, 3, time_elapsed_ms / 1000);
        _ = c.sqlite3_bind_int64(stats_stmt, 4, total_hits);
        _ = c.sqlite3_bind_int(stats_stmt, 5, @intFromBool(score.passed and has_leaderboard));
        _ = c.sqlite3_bind_int(stats_stmt, 6, score.max_combo);
        _ = c.sqlite3_bind_int(stats_stmt, 7, user_id);
        _ = c.sqlite3_bind_int(stats_stmt, 8, stats_mode);
        if (c.sqlite3_step(stats_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }
    const update_map = "UPDATE beatmaps SET plays=plays+1,passes=passes+?1 WHERE md5=?2";
    var map_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, update_map, -1, &map_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(map_stmt);
    _ = c.sqlite3_bind_int(map_stmt, 1, @intFromBool(score.passed));
    _ = c.sqlite3_bind_text(map_stmt, 2, score.map_md5.ptr, @intCast(score.map_md5.len), null);
    if (c.sqlite3_step(map_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    if (updates_player_stats and score.passed and awards_ranked_pp) {
        try self.rebuildCombinedPerformanceLocked(user_id, score.mode, stats_mode, namespace);
    }
    try self.pruneStatsHistoryLocked();
    try self.recordStatsHistorySliceCurrentLocked(if (std.mem.eql(u8, namespace, "scorev2")) .scorev2 else .stable, stats_mode, user_id);
    if (updates_player_stats) try self.recordStatsHistorySliceCurrentLocked(.all, stats_mode, user_id);
    try self.awardAchievementsLocked(user_id, "stable", id, .{
        .eligible = score.passed and std.mem.eql(u8, namespace, "vanilla") and awards_ranked_pp,
        .mode = score.mode,
        .mods = @intCast(score.mods),
        .perfect = score.perfect,
        .max_combo = @intCast(score.max_combo),
        .stars = score.achievement_stars,
        .accuracy = score.accuracy(),
        .pp = pp_value,
    });
    try self.exec("COMMIT");
    return .{ .id = id, .previous_best = previous_best };
}
