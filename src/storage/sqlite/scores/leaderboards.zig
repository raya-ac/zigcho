const std = @import("std");
const domain = @import("../../../domain.zig");
const lazer = @import("../../../lazer.zig");
const stable_mods = @import("../../../stable_mods.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const bindBoard = @import("../../../storage.zig").bindBoard;
const writeBoardRow = @import("../../../storage.zig").writeBoardRow;
const stableGrade = @import("../beatmaps/catalog.zig").stableGrade;
const stableStatus = @import("../../contracts.zig").stableStatus;
const lazerStatus = @import("../../contracts.zig").lazerStatus;

pub fn stableClassicLeaderboardJsonLocked(self: *Store, allocator: std.mem.Allocator, requester_id: i32, beatmap_id: i32, ruleset_id: u8, limit: u8) ![]u8 {
    const sql =
        "WITH ordered AS (" ++
        "SELECT s.*,b.status,b.set_id,b.id beatmap_id,b.star_rating,b.version,b.artist,b.title,b.creator,tm.team_id,t.name team_name,t.short_name team_short_name,coalesce((SELECT updated_at FROM team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0) team_flag_version,row_number() OVER(PARTITION BY s.user_id ORDER BY s.score DESC,s.id ASC) AS user_place " ++
        "FROM scores s JOIN users u ON u.id=s.user_id LEFT JOIN team_members tm ON tm.user_id=u.id LEFT JOIN teams t ON t.id=tm.team_id JOIN beatmaps b ON b.md5=s.map_md5 " ++
        "WHERE b.id=?1 AND b.status>=3 AND s.mode=?2 AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND u.restricted=0)," ++
        "board AS (SELECT *,row_number() OVER(ORDER BY score DESC,id ASC) AS position,count(*) OVER() AS score_count FROM ordered WHERE user_place=1) " ++
        "SELECT position,score_count,id,user_id,(SELECT name FROM users WHERE id=board.user_id),(SELECT country FROM users WHERE id=board.user_id),beatmap_id,mode,score,pp,accuracy,max_combo,n300,n100,n50,ngeki,nkatu,nmiss,perfect,mods,strftime('%Y-%m-%dT%H:%M:%SZ',submitted_at,'unixepoch'),status,set_id,map_md5,star_rating,version,artist,title,creator,team_id,team_name,team_short_name,team_flag_version,(length(replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='stable' AND ro.score_id=board.id)) " ++
        "FROM board WHERE position<=?3 OR user_id=?4 ORDER BY position";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, beatmap_id);
    _ = c.sqlite3_bind_int(stmt, 2, ruleset_id);
    _ = c.sqlite3_bind_int(stmt, 3, limit);
    _ = c.sqlite3_bind_int(stmt, 4, requester_id);

    var scores: std.Io.Writer.Allocating = .init(allocator);
    defer scores.deinit();
    var user_score: ?[]u8 = null;
    defer if (user_score) |json| allocator.free(json);
    var score_count: i64 = 0;
    var written: usize = 0;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const position = c.sqlite3_column_int64(stmt, 0);
        score_count = c.sqlite3_column_int64(stmt, 1);
        var mods: std.Io.Writer.Allocating = .init(allocator);
        defer mods.deinit();
        try stable_mods.writeLazerJson(&mods.writer, c.sqlite3_column_int(stmt, 19), true);
        var statistics: std.Io.Writer.Allocating = .init(allocator);
        defer statistics.deinit();
        try stable_mods.writeLazerStatistics(&statistics.writer, ruleset_id, c.sqlite3_column_int(stmt, 12), c.sqlite3_column_int(stmt, 13), c.sqlite3_column_int(stmt, 14), c.sqlite3_column_int(stmt, 15), c.sqlite3_column_int(stmt, 16), c.sqlite3_column_int(stmt, 17));
        const score: lazer.LeaderboardScore = .{
            .id = c.sqlite3_column_int64(stmt, 2),
            .legacy_score_id = c.sqlite3_column_int64(stmt, 2),
            .legacy_total_score = lazer.stableLegacyTotalScore(c.sqlite3_column_int64(stmt, 8)),
            .user_id = c.sqlite3_column_int(stmt, 3),
            .username = std.mem.span(c.sqlite3_column_text(stmt, 4)),
            .country = std.mem.span(c.sqlite3_column_text(stmt, 5)),
            .beatmap_id = c.sqlite3_column_int(stmt, 6),
            .ruleset_id = c.sqlite3_column_int(stmt, 7),
            .total_score = c.sqlite3_column_int64(stmt, 8),
            .total_score_without_mods = c.sqlite3_column_int64(stmt, 8),
            .pp = c.sqlite3_column_double(stmt, 9),
            .accuracy = c.sqlite3_column_double(stmt, 10),
            .max_combo = c.sqlite3_column_int(stmt, 11),
            .passed = true,
            .rank = stableGrade(ruleset_id, c.sqlite3_column_int(stmt, 19), c.sqlite3_column_double(stmt, 10), c.sqlite3_column_int(stmt, 12), c.sqlite3_column_int(stmt, 13), c.sqlite3_column_int(stmt, 14), c.sqlite3_column_int(stmt, 17)),
            .mods_json = mods.written(),
            .statistics_json = statistics.written(),
            .maximum_statistics_json = "{}",
            .pauses_json = "[]",
            .ended_at = std.mem.span(c.sqlite3_column_text(stmt, 20)),
            .ranked = c.sqlite3_column_int(stmt, 21) == 3 or c.sqlite3_column_int(stmt, 21) == 4,
            .has_replay = c.sqlite3_column_int(stmt, 33) != 0,
            .team = if (c.sqlite3_column_type(stmt, 29) == c.SQLITE_NULL) null else try domain.TeamSummary.init(c.sqlite3_column_int(stmt, 29), std.mem.span(c.sqlite3_column_text(stmt, 30)), std.mem.span(c.sqlite3_column_text(stmt, 31)), c.sqlite3_column_int64(stmt, 32)),
            .beatmap = .{
                .id = c.sqlite3_column_int(stmt, 6),
                .set_id = c.sqlite3_column_int(stmt, 22),
                .status = lazerStatus(c.sqlite3_column_int(stmt, 21)),
                .checksum = std.mem.span(c.sqlite3_column_text(stmt, 23)),
                .ruleset_id = ruleset_id,
                .star_rating = c.sqlite3_column_double(stmt, 24),
                .version = std.mem.span(c.sqlite3_column_text(stmt, 25)),
                .artist = std.mem.span(c.sqlite3_column_text(stmt, 26)),
                .title = std.mem.span(c.sqlite3_column_text(stmt, 27)),
                .creator = std.mem.span(c.sqlite3_column_text(stmt, 28)),
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

pub fn lazerLeaderboardJson(self: *Store, allocator: std.mem.Allocator, requester_id: i32, beatmap_id: i32, ruleset_id: u8, namespace: lazer.Namespace, exact_mods_json: []const u8, filter_mods: bool, classic: bool, requested_stable_mods: ?i32, scope: lazer.LeaderboardScope, limit: u8) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql =
        "WITH candidates AS (" ++
        "SELECT 'lazer' source,s.id source_id,s.id public_id,s.user_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END country,s.beatmap_id,s.ruleset_id,s.total_score,s.total_score_without_mods total_without,s.legacy_total_score,s.pp,s.accuracy,s.max_combo,s.passed,s.rank,s.mods_json,s.statistics_json,s.maximum_statistics_json,s.pauses_json,strftime('%Y-%m-%dT%H:%M:%SZ',s.submitted_at,'unixepoch') ended_at,b.status,s.passed=1 AND (length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)) has_replay,0 stable_mods,0 n300,0 n100,0 n50,0 ngeki,0 nkatu,0 nmiss,0 perfect,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,1 source_order,tm.team_id,t.name team_name,t.short_name team_short_name,coalesce((SELECT updated_at FROM team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0) team_flag_version " ++
        "FROM lazer_scores s JOIN users u ON u.id=s.user_id LEFT JOIN team_members tm ON tm.user_id=u.id LEFT JOIN teams t ON t.id=tm.team_id JOIN beatmaps b ON b.id=s.beatmap_id " ++
        "WHERE s.beatmap_id=?1 AND b.status>=3 AND s.ruleset_id=?2 AND s.rank_namespace=?3 AND s.passed=1 AND u.restricted=0 AND ?6=0 AND NOT EXISTS(SELECT 1 FROM beatmap_rank_events veto_event WHERE veto_event.set_id=b.set_id AND veto_event.id=(SELECT max(latest_event.id) FROM beatmap_rank_events latest_event WHERE latest_event.set_id=b.set_id) AND veto_event.action='veto') " ++
        "AND (?11='global' OR (?11='country' AND u.country=(SELECT country FROM users WHERE id=?10)) OR (?11='friend' AND (s.user_id=?10 OR EXISTS(SELECT 1 FROM friends f JOIN users friend_sender ON friend_sender.id=f.user_id JOIN users friend_target ON friend_target.id=f.friend_id WHERE f.user_id=?10 AND f.friend_id=s.user_id AND friend_sender.id!=friend_target.id AND friend_target.id!=3 AND friend_sender.restricted=0 AND friend_target.restricted=0))) OR (?11='team' AND tm.team_id IS NOT NULL AND tm.team_id=(SELECT team_id FROM team_members WHERE user_id=?10))) " ++
        "AND (?5=0 OR (" ++
        "NOT EXISTS(SELECT upper(json_extract(stored.value,'$.acronym')) FROM json_each(s.mods_json) stored WHERE ?3!='custom' OR upper(json_extract(stored.value,'$.acronym')) NOT IN('RX','AP') EXCEPT SELECT upper(value) FROM json_each(?4) WHERE ?3!='custom' OR upper(value) NOT IN('RX','AP')) " ++
        "AND NOT EXISTS(SELECT upper(value) FROM json_each(?4) WHERE ?3!='custom' OR upper(value) NOT IN('RX','AP') EXCEPT SELECT upper(json_extract(stored.value,'$.acronym')) FROM json_each(s.mods_json) stored WHERE ?3!='custom' OR upper(json_extract(stored.value,'$.acronym')) NOT IN('RX','AP')))) " ++
        "UNION ALL " ++
        "SELECT 'stable' source,s.id source_id,4000000000000000000+s.id public_id,s.user_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END country,b.id beatmap_id,s.mode ruleset_id,s.score total_score,s.score total_without,min(max(s.score,0),2147483647) legacy_total_score,s.pp,s.accuracy,s.max_combo,s.passed,'' rank,'[]' mods_json,'{}' statistics_json,'{}' maximum_statistics_json,'[]' pauses_json,strftime('%Y-%m-%dT%H:%M:%SZ',s.submitted_at,'unixepoch') ended_at,b.status,s.passed=1 AND (length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)) has_replay,s.mods stable_mods,s.n300,s.n100,s.n50,s.ngeki,s.nkatu,s.nmiss,s.perfect,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,0 source_order,tm.team_id,t.name team_name,t.short_name team_short_name,coalesce((SELECT updated_at FROM team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0) team_flag_version " ++
        "FROM scores s JOIN users u ON u.id=s.user_id LEFT JOIN team_members tm ON tm.user_id=u.id LEFT JOIN teams t ON t.id=tm.team_id JOIN beatmaps b ON b.md5=s.map_md5 " ++
        "WHERE b.id=?1 AND b.status>=3 AND s.mode=?2 AND s.rank_namespace=?3 AND s.passed=1 AND u.restricted=0 AND ?3!='custom' AND ?7=1 AND (?5=0 OR (s.mods & ?12)=?8) AND NOT EXISTS(SELECT 1 FROM beatmap_rank_events veto_event WHERE veto_event.set_id=b.set_id AND veto_event.id=(SELECT max(latest_event.id) FROM beatmap_rank_events latest_event WHERE latest_event.set_id=b.set_id) AND veto_event.action='veto') " ++
        "AND (?11='global' OR (?11='country' AND u.country=(SELECT country FROM users WHERE id=?10)) OR (?11='friend' AND (s.user_id=?10 OR EXISTS(SELECT 1 FROM friends f JOIN users friend_sender ON friend_sender.id=f.user_id JOIN users friend_target ON friend_target.id=f.friend_id WHERE f.user_id=?10 AND f.friend_id=s.user_id AND friend_sender.id!=friend_target.id AND friend_target.id!=3 AND friend_sender.restricted=0 AND friend_target.restricted=0))) OR (?11='team' AND tm.team_id IS NOT NULL AND tm.team_id=(SELECT team_id FROM team_members WHERE user_id=?10))))," ++
        "ordered AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY CASE WHEN rank_namespace IN('vanilla','relax','autopilot') THEN pp ELSE total_score END DESC,source_order,source_id) user_place FROM candidates)," ++
        "board AS (SELECT *,row_number() OVER(ORDER BY CASE WHEN rank_namespace IN('relax','autopilot') THEN pp ELSE total_score END DESC,source_order,source_id) position,count(*) OVER() score_count FROM ordered WHERE user_place=1) " ++
        "SELECT position,score_count,source,public_id,user_id,name,country,beatmap_id,ruleset_id,total_score,total_without,legacy_total_score,pp,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,ended_at,status,has_replay,stable_mods,n300,n100,n50,ngeki,nkatu,nmiss,perfect,set_id,md5,map_mode,star_rating,version,artist,title,creator,rank_namespace,team_id,team_name,team_short_name,team_flag_version " ++
        "FROM board WHERE position<=?9 OR user_id=?10 ORDER BY position";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, beatmap_id);
    _ = c.sqlite3_bind_int(stmt, 2, ruleset_id);
    const namespace_name = @tagName(namespace);
    _ = c.sqlite3_bind_text(stmt, 3, namespace_name.ptr, @intCast(namespace_name.len), null);
    _ = c.sqlite3_bind_text(stmt, 4, exact_mods_json.ptr, @intCast(exact_mods_json.len), null);
    _ = c.sqlite3_bind_int(stmt, 5, @intFromBool(filter_mods));
    _ = c.sqlite3_bind_int(stmt, 6, @intFromBool(classic));
    _ = c.sqlite3_bind_int(stmt, 7, @intFromBool(requested_stable_mods != null));
    _ = c.sqlite3_bind_int(stmt, 8, requested_stable_mods orelse 0);
    _ = c.sqlite3_bind_int(stmt, 9, limit);
    _ = c.sqlite3_bind_int(stmt, 10, requester_id);
    const scope_name = @tagName(scope);
    _ = c.sqlite3_bind_text(stmt, 11, scope_name.ptr, @intCast(scope_name.len), null);
    _ = c.sqlite3_bind_int(stmt, 12, stable_mods.leaderboard_gameplay_mask);

    var scores: std.Io.Writer.Allocating = .init(allocator);
    defer scores.deinit();
    var user_score: ?[]u8 = null;
    defer if (user_score) |json| allocator.free(json);
    var score_count: i64 = 0;
    var written: usize = 0;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const position = c.sqlite3_column_int64(stmt, 0);
        score_count = c.sqlite3_column_int64(stmt, 1);
        const stable = std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)), "stable");
        var mods: std.Io.Writer.Allocating = .init(allocator);
        defer mods.deinit();
        var statistics: std.Io.Writer.Allocating = .init(allocator);
        defer statistics.deinit();
        if (stable) {
            try stable_mods.writeLazerJson(&mods.writer, c.sqlite3_column_int(stmt, 24), true);
            try stable_mods.writeLazerStatistics(&statistics.writer, ruleset_id, c.sqlite3_column_int(stmt, 25), c.sqlite3_column_int(stmt, 26), c.sqlite3_column_int(stmt, 27), c.sqlite3_column_int(stmt, 28), c.sqlite3_column_int(stmt, 29), c.sqlite3_column_int(stmt, 30));
        }
        const score: lazer.LeaderboardScore = .{
            .id = c.sqlite3_column_int64(stmt, 3),
            .legacy_score_id = if (stable) lazer.decodeStableScoreId(c.sqlite3_column_int64(stmt, 3)) else null,
            .legacy_total_score = if (stable) lazer.stableLegacyTotalScore(c.sqlite3_column_int64(stmt, 9)) else if (c.sqlite3_column_type(stmt, 11) == c.SQLITE_NULL) null else c.sqlite3_column_int(stmt, 11),
            .user_id = c.sqlite3_column_int(stmt, 4),
            .username = std.mem.span(c.sqlite3_column_text(stmt, 5)),
            .country = std.mem.span(c.sqlite3_column_text(stmt, 6)),
            .beatmap_id = c.sqlite3_column_int(stmt, 7),
            .ruleset_id = c.sqlite3_column_int(stmt, 8),
            .total_score = c.sqlite3_column_int64(stmt, 9),
            .total_score_without_mods = c.sqlite3_column_int64(stmt, 10),
            .pp = c.sqlite3_column_double(stmt, 12),
            .accuracy = c.sqlite3_column_double(stmt, 13),
            .max_combo = c.sqlite3_column_int(stmt, 14),
            .passed = c.sqlite3_column_int(stmt, 15) != 0,
            .rank = if (stable) stableGrade(ruleset_id, c.sqlite3_column_int(stmt, 24), c.sqlite3_column_double(stmt, 13), c.sqlite3_column_int(stmt, 25), c.sqlite3_column_int(stmt, 26), c.sqlite3_column_int(stmt, 27), c.sqlite3_column_int(stmt, 30)) else std.mem.span(c.sqlite3_column_text(stmt, 16)),
            .mods_json = if (stable) mods.written() else std.mem.span(c.sqlite3_column_text(stmt, 17)),
            .statistics_json = if (stable) statistics.written() else std.mem.span(c.sqlite3_column_text(stmt, 18)),
            .maximum_statistics_json = std.mem.span(c.sqlite3_column_text(stmt, 19)),
            .pauses_json = std.mem.span(c.sqlite3_column_text(stmt, 20)),
            .ended_at = std.mem.span(c.sqlite3_column_text(stmt, 21)),
            .ranked = c.sqlite3_column_int(stmt, 22) == 3 or c.sqlite3_column_int(stmt, 22) == 4,
            .has_replay = c.sqlite3_column_int(stmt, 23) != 0,
            .team = if (c.sqlite3_column_type(stmt, 41) == c.SQLITE_NULL) null else try domain.TeamSummary.init(c.sqlite3_column_int(stmt, 41), std.mem.span(c.sqlite3_column_text(stmt, 42)), std.mem.span(c.sqlite3_column_text(stmt, 43)), c.sqlite3_column_int64(stmt, 44)),
            .beatmap = .{
                .id = c.sqlite3_column_int(stmt, 7),
                .set_id = c.sqlite3_column_int(stmt, 32),
                .status = lazerStatus(c.sqlite3_column_int(stmt, 22)),
                .checksum = std.mem.span(c.sqlite3_column_text(stmt, 33)),
                .ruleset_id = c.sqlite3_column_int(stmt, 34),
                .star_rating = c.sqlite3_column_double(stmt, 35),
                .version = std.mem.span(c.sqlite3_column_text(stmt, 36)),
                .artist = std.mem.span(c.sqlite3_column_text(stmt, 37)),
                .title = std.mem.span(c.sqlite3_column_text(stmt, 38)),
                .creator = std.mem.span(c.sqlite3_column_text(stmt, 39)),
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

pub fn scoreLeaderboardPlacement(self: *Store, score_id: i64) !?domain.ScorePlacement {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = "SELECT s.best,(SELECT count(*) FROM scores o WHERE o.map_md5=pb.map_md5 AND o.mode=pb.mode AND o.rank_namespace=pb.rank_namespace AND o.passed=1 AND o.best=1 AND ((pb.rank_namespace IN('vanilla','scorev2') AND (o.score>pb.score OR (o.score=pb.score AND o.id<pb.id))) OR (pb.rank_namespace IN('relax','autopilot') AND (o.pp>pb.pp OR (o.pp=pb.pp AND o.id<pb.id))))) FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 JOIN scores pb ON pb.user_id=s.user_id AND pb.map_md5=s.map_md5 AND pb.mode=s.mode AND pb.rank_namespace=s.rank_namespace AND pb.passed=1 AND pb.best=1 WHERE s.id=?1 AND s.passed=1 AND b.status>=3";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, score_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return .{ .submitted_is_best = c.sqlite3_column_int(stmt, 0) != 0, .rank = c.sqlite3_column_int(stmt, 1) };
}

pub fn lazerScoreLeaderboardPlacement(self: *Store, score_id: i64) !?domain.ScorePlacement {
    const Context = struct { user_id: i32, beatmap_id: i32, ruleset_id: u8, namespace: lazer.Namespace, mods_json: []u8 };
    const context: Context = blk: {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT s.user_id,s.beatmap_id,s.ruleset_id,s.rank_namespace,s.mods_json,s.passed,b.status FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, score_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW or c.sqlite3_column_int(stmt, 5) == 0 or c.sqlite3_column_int(stmt, 6) < 3) return null;
        const namespace_name = std.mem.span(c.sqlite3_column_text(stmt, 3));
        const score_namespace = std.meta.stringToEnum(lazer.Namespace, namespace_name) orelse return error.DatabaseQueryFailed;
        break :blk .{
            .user_id = c.sqlite3_column_int(stmt, 0),
            .beatmap_id = c.sqlite3_column_int(stmt, 1),
            .ruleset_id = @intCast(c.sqlite3_column_int(stmt, 2)),
            .namespace = score_namespace,
            .mods_json = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 4))),
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
    const position = own_object.get("position") orelse return null;
    const position_value = switch (position) {
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

pub fn stableLeaderboard(self: *Store, allocator: std.mem.Allocator, viewer: domain.User, map_md5: []const u8, mode: u8, board_type: u8, requested_mods: i32) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const w = &output.writer;
    const map_sql = "SELECT id,set_id,status,artist,title,version FROM beatmaps WHERE md5=?1";
    var map_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, map_sql, -1, &map_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(map_stmt);
    _ = c.sqlite3_bind_text(map_stmt, 1, map_md5.ptr, @intCast(map_md5.len), null);
    if (c.sqlite3_step(map_stmt) != c.SQLITE_ROW) {
        try w.writeAll("-1|false");
        var missing = output.toArrayList();
        return missing.toOwnedSlice(allocator);
    }
    const map_id = c.sqlite3_column_int(map_stmt, 0);
    const set_id = c.sqlite3_column_int(map_stmt, 1);
    const status = c.sqlite3_column_int(map_stmt, 2);
    const client_status = stableStatus(status);
    const artist = std.mem.span(c.sqlite3_column_text(map_stmt, 3));
    const title = std.mem.span(c.sqlite3_column_text(map_stmt, 4));
    const version = std.mem.span(c.sqlite3_column_text(map_stmt, 5));
    if (status < 3) {
        try w.print("{d}|false", .{client_status});
        var unavailable = output.toArrayList();
        return unavailable.toOwnedSlice(allocator);
    }
    const namespace = stable_mods.namespace(requested_mods);
    const uses_pp = std.mem.eql(u8, namespace, "relax") or std.mem.eql(u8, namespace, "autopilot");
    const filter = " FROM scores s JOIN users u ON u.id=s.user_id WHERE s.map_md5=?1 AND s.mode=?2 AND s.passed=1 AND s.best=1 AND s.rank_namespace=?3 AND (?4!=2 OR s.mods=?5) AND (?4!=3 OR s.user_id=?6 OR EXISTS(SELECT 1 FROM friends f JOIN users friend_sender ON friend_sender.id=f.user_id JOIN users friend_target ON friend_target.id=f.friend_id WHERE f.user_id=?6 AND f.friend_id=s.user_id AND friend_sender.id!=friend_target.id AND friend_target.id!=3 AND friend_sender.restricted=0 AND friend_target.restricted=0)) AND (?4!=4 OR u.country=?7)";
    const count_sql = "SELECT min(count(*),50)" ++ filter;
    var count_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, count_sql, -1, &count_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(count_stmt);
    bindBoard(count_stmt.?, map_md5, mode, namespace, board_type, requested_mods, &viewer);
    if (c.sqlite3_step(count_stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    const row_count = c.sqlite3_column_int(count_stmt, 0);
    try w.print("{d}|false|{d}|{d}|{d}|0|\n0\n{s} - {s} [{s}]\n0\n", .{ client_status, map_id, set_id, row_count, artist, title, version });

    const personal_id_sql = if (uses_pp) "SELECT s.id,s.pp" ++ filter ++ " AND s.user_id=?6 ORDER BY s.pp DESC,s.id ASC LIMIT 1" else "SELECT s.id,s.score" ++ filter ++ " AND s.user_id=?6 ORDER BY s.score DESC,s.id ASC LIMIT 1";
    var personal_id_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, personal_id_sql, -1, &personal_id_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    bindBoard(personal_id_stmt.?, map_md5, mode, namespace, board_type, requested_mods, &viewer);
    var personal_id: i64 = 0;
    var personal_score: i64 = 0;
    if (c.sqlite3_step(personal_id_stmt) == c.SQLITE_ROW) {
        personal_id = c.sqlite3_column_int64(personal_id_stmt, 0);
        personal_score = if (uses_pp) @bitCast(c.sqlite3_column_double(personal_id_stmt, 1)) else c.sqlite3_column_int64(personal_id_stmt, 1);
    }
    _ = c.sqlite3_finalize(personal_id_stmt);
    if (personal_id != 0) {
        const rank_sql = if (uses_pp) "SELECT count(*)+1" ++ filter ++ " AND (s.pp>?8 OR (s.pp=?8 AND s.id<?9))" else "SELECT count(*)+1" ++ filter ++ " AND (s.score>?8 OR (s.score=?8 AND s.id<?9))";
        var rank_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, rank_sql, -1, &rank_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        bindBoard(rank_stmt.?, map_md5, mode, namespace, board_type, requested_mods, &viewer);
        _ = c.sqlite3_bind_double(rank_stmt, 8, @bitCast(personal_score));
        _ = c.sqlite3_bind_int64(rank_stmt, 9, personal_id);
        if (c.sqlite3_step(rank_stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        const personal_rank = c.sqlite3_column_int(rank_stmt, 0);
        _ = c.sqlite3_finalize(rank_stmt);
        const row_sql = if (uses_pp)
            "SELECT s.id,u.name,s.pp,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,(length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)) FROM scores s JOIN users u ON u.id=s.user_id WHERE s.id=?1"
        else
            "SELECT s.id,u.name,s.score,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,(length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)) FROM scores s JOIN users u ON u.id=s.user_id WHERE s.id=?1";
        var row_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, row_sql, -1, &row_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int64(row_stmt, 1, personal_id);
        if (c.sqlite3_step(row_stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        try writeBoardRow(w, row_stmt.?, personal_rank, uses_pp);
        _ = c.sqlite3_finalize(row_stmt);
    }
    try w.writeByte('\n');
    const rows_sql = if (uses_pp)
        "SELECT s.id,u.name,s.pp,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,(length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id))" ++ filter ++ " ORDER BY s.pp DESC,s.id ASC LIMIT 50"
    else
        "SELECT s.id,u.name,s.score,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,(length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id))" ++ filter ++ " ORDER BY s.score DESC,s.id ASC LIMIT 50";
    var rows_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, rows_sql, -1, &rows_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(rows_stmt);
    bindBoard(rows_stmt.?, map_md5, mode, namespace, board_type, requested_mods, &viewer);
    var rank: i32 = 1;
    while (c.sqlite3_step(rows_stmt) == c.SQLITE_ROW) {
        if (rank > 1) try w.writeByte('\n');
        try writeBoardRow(w, rows_stmt.?, rank, uses_pp);
        rank += 1;
    }
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}
