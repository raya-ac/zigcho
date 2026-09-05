const std = @import("std");
const domain = @import("../../../domain.zig");
const user_json = @import("../../../user_json.zig");
const visible_follower_count_sql = @import("../../../storage.zig").visible_follower_count_sql;
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const writeSiteScores = @import("../scores/website.zig").writeSiteScores;
const jsonString = @import("../beatmaps/lazer_listing.zig").jsonString;

pub fn updateSiteProfile(self: *Store, user_id: i32, settings: domain.SiteProfileSettings) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE users SET bio=?1,profile_title=?2,profile_pronouns=?3,profile_location=?4,profile_website=?5,profile_accent=?6,preferred_mode=?7,profile_source=?8,avatar_key=?9,show_country=?10,show_profile_stats=?11,show_recent_scores=?12 WHERE id=?13 AND id!=3", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, settings.bio.ptr, @intCast(settings.bio.len), null);
    _ = c.sqlite3_bind_text(stmt, 2, settings.title.ptr, @intCast(settings.title.len), null);
    _ = c.sqlite3_bind_text(stmt, 3, settings.pronouns.ptr, @intCast(settings.pronouns.len), null);
    _ = c.sqlite3_bind_text(stmt, 4, settings.location.ptr, @intCast(settings.location.len), null);
    _ = c.sqlite3_bind_text(stmt, 5, settings.website.ptr, @intCast(settings.website.len), null);
    const accent = @tagName(settings.accent);
    _ = c.sqlite3_bind_text(stmt, 6, accent.ptr, @intCast(accent.len), null);
    _ = c.sqlite3_bind_int(stmt, 7, settings.preferred_mode);
    const source = @tagName(settings.profile_source);
    _ = c.sqlite3_bind_text(stmt, 8, source.ptr, @intCast(source.len), null);
    _ = c.sqlite3_bind_int(stmt, 9, settings.avatar_key);
    _ = c.sqlite3_bind_int(stmt, 10, @intFromBool(settings.show_country));
    _ = c.sqlite3_bind_int(stmt, 11, @intFromBool(settings.show_profile_stats));
    _ = c.sqlite3_bind_int(stmt, 12, @intFromBool(settings.show_recent_scores));
    _ = c.sqlite3_bind_int(stmt, 13, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.UserNotFound;
}

pub fn lazerProfileSummary(self: *Store, user_id: i32) !?domain.ProfileSummary {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql =
        "SELECT u.created_at,coalesce(u.last_login,0),coalesce((SELECT updated_at FROM user_avatars a WHERE a.user_id=u.id),u.avatar_key),u.preferred_mode,u.profile_title,u.profile_location,u.profile_website,u.show_country,u.show_profile_stats,u.show_recent_scores," ++
        "(SELECT count(*) FROM favourites f WHERE f.user_id=u.id)," ++
        "(SELECT count(*) FROM (SELECT submission.set_id FROM beatmap_submissions submission JOIN beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=u.id AND submission.state='published' GROUP BY submission.set_id HAVING min(b.status) IN(3,4)))," ++
        "(SELECT count(*) FROM (SELECT submission.set_id FROM beatmap_submissions submission JOIN beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=u.id AND submission.state='published' GROUP BY submission.set_id HAVING min(b.status)=6))," ++
        "(SELECT count(*) FROM (SELECT submission.set_id FROM beatmap_submissions submission JOIN beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=u.id AND submission.state='published' GROUP BY submission.set_id HAVING min(b.status)=2))," ++
        "(SELECT count(*) FROM (SELECT submission.set_id FROM beatmap_submissions submission JOIN beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=u.id AND submission.state='published' GROUP BY submission.set_id HAVING min(b.status)=1))," ++
        "(SELECT count(*) FROM (SELECT submission.set_id FROM beatmap_submissions submission JOIN beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=u.id AND submission.state='published' GROUP BY submission.set_id HAVING min(b.status)=5))," ++
        "(SELECT count(*) FROM (SELECT b.id FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=u.id UNION SELECT s.beatmap_id FROM lazer_scores s WHERE s.user_id=u.id))," ++
        visible_follower_count_sql ++ " " ++
        "FROM users u WHERE u.id=?1";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    var summary = try domain.ProfileSummary.init(
        c.sqlite3_column_int64(stmt, 0),
        c.sqlite3_column_int64(stmt, 1),
        c.sqlite3_column_int64(stmt, 2),
        @intCast(c.sqlite3_column_int(stmt, 3)),
        std.mem.span(c.sqlite3_column_text(stmt, 4)),
        std.mem.span(c.sqlite3_column_text(stmt, 5)),
        std.mem.span(c.sqlite3_column_text(stmt, 6)),
    );
    summary.show_country = c.sqlite3_column_int(stmt, 7) != 0;
    summary.show_profile_stats = c.sqlite3_column_int(stmt, 8) != 0;
    summary.show_recent_scores = c.sqlite3_column_int(stmt, 9) != 0;
    summary.favourite_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), c.sqlite3_column_int64(stmt, 10)));
    summary.ranked_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), c.sqlite3_column_int64(stmt, 11)));
    summary.loved_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), c.sqlite3_column_int64(stmt, 12)));
    summary.pending_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), c.sqlite3_column_int64(stmt, 13)));
    summary.graveyard_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), c.sqlite3_column_int64(stmt, 14)));
    summary.nominated_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), c.sqlite3_column_int64(stmt, 15)));
    summary.played_beatmap_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), c.sqlite3_column_int64(stmt, 16)));
    summary.follower_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), c.sqlite3_column_int64(stmt, 17)));
    return summary;
}

pub fn lazerBatchUserVisibility(self: *Store, user_id: i32) !?domain.BatchUserVisibility {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT coalesce((SELECT updated_at FROM user_avatars a WHERE a.user_id=u.id),u.avatar_key),u.show_country,u.show_profile_stats," ++ visible_follower_count_sql ++ " FROM users u WHERE u.id=?1";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return .{
        .avatar_version = c.sqlite3_column_int64(stmt, 0),
        .show_country = c.sqlite3_column_int(stmt, 1) != 0,
        .show_profile_stats = c.sqlite3_column_int(stmt, 2) != 0,
        .follower_count = c.sqlite3_column_int(stmt, 3),
    };
}

pub fn lazerMonthlyPlaycountsJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql =
        "WITH plays AS (SELECT submitted_at FROM scores WHERE user_id=?1 UNION ALL SELECT submitted_at FROM lazer_scores WHERE user_id=?1) " ++
        "SELECT strftime('%Y-%m-01T00:00:00Z',submitted_at,'unixepoch') month,count(*) FROM plays GROUP BY strftime('%Y-%m',submitted_at,'unixepoch') ORDER BY month";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var first = true;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.writeAll("{\"start_date\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 0)));
        try output.writer.print(",\"count\":{d}}}", .{c.sqlite3_column_int64(stmt, 1)});
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn lazerReplaysWatchedCountsJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, ruleset_id: u8) ![]u8 {
    if (ruleset_id > 3) return error.InvalidRulesetId;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql =
        "SELECT strftime('%Y-%m-01',viewed_at,'unixepoch') month,count(*) FROM score_replay_views " ++
        "WHERE owner_id=?1 AND mode=?2 AND rank_namespace='vanilla' " ++
        "GROUP BY strftime('%Y-%m',viewed_at,'unixepoch') ORDER BY month";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, ruleset_id);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var first = true;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.writeAll("{\"start_date\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 0)));
        try output.writer.print(",\"count\":{d}}}", .{c.sqlite3_column_int64(stmt, 1)});
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn siteAccountJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT u.id,u.name,u.email,u.country,u.privileges,u.bio,u.preferred_mode,u.profile_source,u.avatar_key,EXISTS(SELECT 1 FROM user_avatars a WHERE a.user_id=u.id),coalesce((SELECT updated_at FROM user_avatars a WHERE a.user_id=u.id),0),u.created_at,coalesce(u.last_login,0),u.profile_title,u.profile_pronouns,u.profile_location,u.profile_website,u.profile_accent,u.show_country,u.show_profile_stats,u.show_recent_scores,u.username_changes,EXISTS(SELECT 1 FROM user_banners b WHERE b.user_id=u.id),coalesce((SELECT updated_at FROM user_banners b WHERE b.user_id=u.id),0),tm.team_id,t.name,t.short_name,CASE WHEN t.leader_id=u.id THEN 1 ELSE 0 END FROM users u LEFT JOIN team_members tm ON tm.user_id=u.id LEFT JOIN teams t ON t.id=tm.team_id WHERE u.id=?1 AND u.id!=3";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"id\":{d},\"name\":", .{c.sqlite3_column_int(stmt, 0)});
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 1)));
    try output.writer.writeAll(",\"email\":");
    if (c.sqlite3_column_type(stmt, 2) == c.SQLITE_NULL) try output.writer.writeAll("null") else try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 2)));
    try output.writer.writeAll(",\"country\":");
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 3)));
    try output.writer.print(",\"privileges\":{d},\"bio\":", .{c.sqlite3_column_int64(stmt, 4)});
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 5)));
    try output.writer.writeAll(",\"profile_source\":");
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 7)));
    try output.writer.print(",\"preferred_mode\":{d},\"avatar_key\":{d},\"has_custom_avatar\":{},\"avatar_version\":{d},\"created_at\":{d},\"last_login\":{d},\"profile_title\":", .{ c.sqlite3_column_int(stmt, 6), c.sqlite3_column_int(stmt, 8), c.sqlite3_column_int(stmt, 9) != 0, c.sqlite3_column_int64(stmt, 10), c.sqlite3_column_int64(stmt, 11), c.sqlite3_column_int64(stmt, 12) });
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 13)));
    try output.writer.writeAll(",\"profile_pronouns\":");
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 14)));
    try output.writer.writeAll(",\"profile_location\":");
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 15)));
    try output.writer.writeAll(",\"profile_website\":");
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 16)));
    try output.writer.writeAll(",\"profile_accent\":");
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 17)));
    const changes = c.sqlite3_column_int(stmt, 21);
    try output.writer.print(",\"show_country\":{},\"show_profile_stats\":{},\"show_recent_scores\":{},\"username_changes\":{d},\"username_change_free\":{},\"username_change_allowed\":{},\"has_custom_banner\":{},\"banner_version\":{d},\"team\":", .{ c.sqlite3_column_int(stmt, 18) != 0, c.sqlite3_column_int(stmt, 19) != 0, c.sqlite3_column_int(stmt, 20) != 0, changes, changes == 0, changes == 0 or (c.sqlite3_column_int64(stmt, 4) & (1 << 5)) != 0, c.sqlite3_column_int(stmt, 22) != 0, c.sqlite3_column_int64(stmt, 23) });
    if (c.sqlite3_column_type(stmt, 24) == c.SQLITE_NULL) {
        try output.writer.writeAll("null");
    } else {
        try output.writer.print("{{\"id\":{d},\"name\":", .{c.sqlite3_column_int(stmt, 24)});
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 25)));
        try output.writer.writeAll(",\"short_name\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 26)));
        try output.writer.print(",\"leader\":{}}}", .{c.sqlite3_column_int(stmt, 27) != 0});
    }
    try output.writer.writeByte('}');
    var list = output.toArrayList();
    return @as(?[]u8, try list.toOwnedSlice(allocator));
}

pub fn siteNameHistoryJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql =
        "SELECT u.id,u.name,h.old_name,h.changed_at FROM users u " ++
        "LEFT JOIN (SELECT id,user_id,old_name,changed_at FROM user_name_changes WHERE user_id=?1 ORDER BY changed_at DESC,id DESC LIMIT 20) h ON h.user_id=u.id " ++
        "WHERE u.id=?1 AND u.id!=3 AND u.restricted=0 ORDER BY h.changed_at DESC,h.id DESC";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"id\":{d},\"name\":", .{c.sqlite3_column_int(stmt, 0)});
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 1)));
    try output.writer.writeAll(",\"history\":[");
    var first = true;
    while (true) {
        if (c.sqlite3_column_type(stmt, 2) != c.SQLITE_NULL) {
            if (!first) try output.writer.writeByte(',');
            first = false;
            try output.writer.writeAll("{\"name\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 2)));
            try output.writer.print(",\"changed_at\":{d}}}", .{c.sqlite3_column_int64(stmt, 3)});
        }
        switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => {},
            c.SQLITE_DONE => break,
            else => return error.DatabaseQueryFailed,
        }
    }
    try output.writer.writeAll("]}");
    var list = output.toArrayList();
    return @as(?[]u8, try list.toOwnedSlice(allocator));
}

pub fn updateCountry(self: *Store, user_id: i32, value: [2]u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE users SET country=?1,last_login=unixepoch() WHERE id=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, value[0..].ptr, 2, null);
    _ = c.sqlite3_bind_int(stmt, 2, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn siteProfile(self: *Store, allocator: std.mem.Allocator, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !?[]u8 {
    return self.siteProfileForViewer(allocator, user_id, source, stats_mode, false);
}

pub fn siteProfileForViewer(self: *Store, allocator: std.mem.Allocator, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8, owner_view: bool) !?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const score_mode = domain.siteScoreMode(stats_mode);
    const namespace = domain.siteNamespace(source, stats_mode);
    var user: ?*c.sqlite3_stmt = null;
    const user_sql = "SELECT u.id,u.name,CASE WHEN ?2=1 OR u.show_country=1 THEN u.country ELSE 'XX' END,u.privileges,u.created_at,u.bio,u.preferred_mode,u.profile_source,coalesce((SELECT updated_at FROM user_avatars a WHERE a.user_id=u.id),u.avatar_key),u.profile_title,u.profile_pronouns,u.profile_location,u.profile_website,u.profile_accent,u.show_profile_stats,u.show_recent_scores,coalesce((SELECT updated_at FROM user_banners b WHERE b.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM team_assets a WHERE a.team_id=t.id AND a.kind='flag'),0)," ++ visible_follower_count_sql ++ " FROM users u LEFT JOIN team_members tm ON tm.user_id=u.id LEFT JOIN teams t ON t.id=tm.team_id WHERE u.id=?1 AND u.id!=3 AND u.restricted=0";
    if (c.sqlite3_prepare_v2(self.db, user_sql, -1, &user, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(user);
    _ = c.sqlite3_bind_int(user, 1, user_id);
    _ = c.sqlite3_bind_int(user, 2, @intFromBool(owner_view));
    if (c.sqlite3_step(user) != c.SQLITE_ROW) return null;
    const show_profile_stats = owner_view or c.sqlite3_column_int(user, 14) != 0;
    const show_recent_scores = owner_view or c.sqlite3_column_int(user, 15) != 0;
    const stats_history = if (show_profile_stats) try self.statsHistoryLocked(user_id, source, stats_mode) else domain.StatsHistory{};
    var stats: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT s.mode,s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,CASE WHEN s.plays>0 THEN (SELECT count(*)+1 FROM stats r JOIN users ru ON ru.id=r.user_id WHERE r.mode=s.mode AND r.plays>0 AND ru.id!=3 AND ru.restricted=0 AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) ELSE 0 END FROM stats s WHERE s.user_id=?1 ORDER BY s.mode", -1, &stats, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stats);
    _ = c.sqlite3_bind_int(stats, 1, user_id);
    const stable_stats_sql =
        "WITH source_scores AS (SELECT s.user_id,s.id score_id,s.score total_score,s.pp,s.accuracy,s.max_combo,s.passed,s.time_elapsed/1000 play_time,b.status,b.id beatmap_id FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.mode=?2 AND s.rank_namespace=?3)," ++
        "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed=1 AND status IN(3,4))," ++
        "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
        "performance AS (SELECT user_id,round(sum(pp*pow(0.95,performance_index))+416.6667*(1-pow(0.9994,count(*)))) pp,sum(accuracy*pow(0.95,performance_index))/(20*(1-pow(0.95,count(*)))) accuracy FROM ranked GROUP BY user_id)," ++
        "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce(sum(play_time),0) play_time,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed=1 AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id)," ++
        "players AS (SELECT a.user_id,a.ranked_score,a.total_score,coalesce(p.pp,0) pp,a.plays,a.play_time,coalesce(p.accuracy,0) accuracy,a.max_combo FROM activity a JOIN users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND u.restricted=0)," ++
        "ordered AS (SELECT *,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) SELECT ranked_score,total_score,pp,plays,play_time,accuracy,max_combo,global_rank FROM ordered WHERE user_id=?1";
    const lazer_stats_sql =
        "WITH source_scores AS (SELECT s.user_id,s.id score_id,coalesce(s.legacy_total_score,s.total_score) total_score,s.pp,s.accuracy,s.max_combo,s.passed,max(b.total_length,0) play_time,b.status,s.beatmap_id FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.ruleset_id=?2 AND s.rank_namespace=?3)," ++
        "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed=1 AND status IN(3,4))," ++
        "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
        "performance AS (SELECT user_id,round(sum(pp*pow(0.95,performance_index))+416.6667*(1-pow(0.9994,count(*)))) pp,sum(accuracy*pow(0.95,performance_index))/(20*(1-pow(0.95,count(*)))) accuracy FROM ranked GROUP BY user_id)," ++
        "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce(sum(play_time),0) play_time,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed=1 AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id)," ++
        "players AS (SELECT a.user_id,a.ranked_score,a.total_score,coalesce(p.pp,0) pp,a.plays,a.play_time,coalesce(p.accuracy,0) accuracy,a.max_combo FROM activity a JOIN users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND u.restricted=0)," ++
        "ordered AS (SELECT *,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) SELECT ranked_score,total_score,pp,plays,play_time,accuracy,max_combo,global_rank FROM ordered WHERE user_id=?1";
    const combined_stats_sql = "SELECT s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.accuracy,s.max_combo,(SELECT count(*)+1 FROM stats r JOIN users ru ON ru.id=r.user_id WHERE r.mode=s.mode AND r.plays>0 AND ru.id!=3 AND ru.restricted=0 AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) FROM stats s WHERE s.user_id=?1 AND s.mode=?2 AND s.plays>0";
    const selected_stats_sql: [*:0]const u8 = switch (source) {
        .all => combined_stats_sql,
        .stable, .scorev2 => stable_stats_sql,
        .lazer => lazer_stats_sql,
    };
    var selected_stats: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, selected_stats_sql, -1, &selected_stats, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(selected_stats);
    _ = c.sqlite3_bind_int(selected_stats, 1, user_id);
    _ = c.sqlite3_bind_int(selected_stats, 2, if (source == .all) stats_mode else score_mode);
    if (source != .all) _ = c.sqlite3_bind_text(selected_stats, 3, namespace.ptr, @intCast(namespace.len), null);
    const stable_columns = "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id map_id,b.artist,b.title,b.version,b.status,'stable',NULL,s.passed=1 AND (length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.score score_without_mods,s.score legacy_score FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 ";
    const lazer_columns = "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id map_id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json,s.passed=1 AND (length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.total_score_without_mods score_without_mods,s.legacy_total_score legacy_score FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id ";
    const pinned_sql: [:0]const u8 = switch (source) {
        .all => "WITH pinned_scores(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score,pinned_at) AS (" ++
            "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL,s.passed=1 AND (length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.score,s.score,p.pinned_at FROM profile_score_pins p JOIN scores s ON p.source='stable' AND s.id=p.score_id JOIN beatmaps b ON b.md5=s.map_md5 WHERE p.user_id=?1 AND p.mode=?2 AND p.rank_namespace=?3 AND s.passed=1 UNION ALL " ++
            "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json,s.passed=1 AND (length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.total_score_without_mods,s.legacy_total_score,p.pinned_at FROM profile_score_pins p JOIN lazer_scores s ON p.source='lazer' AND s.id=p.score_id JOIN beatmaps b ON b.id=s.beatmap_id WHERE p.user_id=?1 AND p.mode=?2 AND p.rank_namespace=?3 AND s.passed=1) SELECT id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score FROM pinned_scores ORDER BY pinned_at DESC,client,id DESC LIMIT 3",
        .stable, .scorev2 => stable_columns ++ "JOIN profile_score_pins p ON p.source='stable' AND p.score_id=s.id AND p.user_id=s.user_id WHERE s.user_id=?1 AND s.mode=?2 AND s.rank_namespace=?3 AND s.passed=1 ORDER BY p.pinned_at DESC,p.score_id DESC LIMIT 3",
        .lazer => lazer_columns ++ "JOIN profile_score_pins p ON p.source='lazer' AND p.score_id=s.id AND p.user_id=s.user_id WHERE s.user_id=?1 AND s.ruleset_id=?2 AND s.rank_namespace=?3 AND s.passed=1 ORDER BY p.pinned_at DESC,p.score_id DESC LIMIT 3",
    };
    const top_sql: [:0]const u8 = switch (source) {
        .all => "WITH candidates(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score,beatmap_key) AS (" ++
            "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL,s.passed=1 AND (length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.score,s.score,b.id FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=?1 AND s.mode=?2 AND s.rank_namespace=?3 AND s.passed=1 AND b.status IN(3,4) UNION ALL " ++
            "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json,s.passed=1 AND (length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.total_score_without_mods,s.legacy_total_score,b.id FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=?1 AND s.ruleset_id=?2 AND s.rank_namespace=?3 AND s.passed=1 AND b.status IN(3,4))," ++
            "per_map AS (SELECT *,row_number() OVER(PARTITION BY beatmap_key ORDER BY pp DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) map_place FROM candidates) " ++
            "SELECT id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score FROM per_map WHERE map_place=1 ORDER BY pp DESC,beatmap_key ASC,id ASC LIMIT 100",
        .stable, .scorev2 => "WITH candidates AS (" ++ stable_columns ++ "WHERE s.user_id=?1 AND s.mode=?2 AND s.rank_namespace=?3 AND s.passed=1 AND b.status IN(3,4)), ranked AS (SELECT *,row_number() OVER(PARTITION BY map_id ORDER BY pp DESC,id ASC) map_place FROM candidates) SELECT * FROM ranked WHERE map_place=1 ORDER BY pp DESC,map_id ASC,id ASC LIMIT 100",
        .lazer => "WITH candidates AS (" ++ lazer_columns ++ "WHERE s.user_id=?1 AND s.ruleset_id=?2 AND s.rank_namespace=?3 AND s.passed=1 AND b.status IN(3,4)), ranked AS (SELECT *,row_number() OVER(PARTITION BY map_id ORDER BY pp DESC,id ASC) map_place FROM candidates) SELECT * FROM ranked WHERE map_place=1 ORDER BY pp DESC,map_id ASC,id ASC LIMIT 100",
    };
    const recent_sql: [:0]const u8 = switch (source) {
        .all => "WITH recent_scores(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score) AS (" ++
            "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL,s.passed=1 AND (length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.score,s.score FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=?1 AND s.mode=?2 AND s.rank_namespace=?3 UNION ALL " ++
            "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json,s.passed=1 AND (length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.total_score_without_mods,s.legacy_total_score FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=?1 AND s.ruleset_id=?2 AND s.rank_namespace=?3) " ++
            "SELECT * FROM recent_scores ORDER BY submitted_at DESC,client ASC,id DESC LIMIT 20",
        .lazer => lazer_columns ++ "WHERE s.user_id=?1 AND s.ruleset_id=?2 AND s.rank_namespace=?3 ORDER BY s.id DESC LIMIT 20",
        .stable, .scorev2 => stable_columns ++ "WHERE s.user_id=?1 AND s.mode=?2 AND s.rank_namespace=?3 ORDER BY s.id DESC LIMIT 20",
    };
    const first_sql: [:0]const u8 = switch (source) {
        .all => "WITH candidates(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score,beatmap_key,user_id) AS (" ++
            "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL,s.passed=1 AND (length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.score,s.score,b.id,s.user_id FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 JOIN users u ON u.id=s.user_id WHERE s.mode=?2 AND s.rank_namespace=?3 AND s.passed=1 AND s.best=1 AND b.status IN(3,4) AND u.restricted=0 UNION ALL " ++
            "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json,s.passed=1 AND (length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.total_score_without_mods,s.legacy_total_score,b.id,s.user_id FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id JOIN users u ON u.id=s.user_id WHERE s.ruleset_id=?2 AND s.rank_namespace=?3 AND s.passed=1 AND s.best=1 AND b.status IN(3,4) AND u.restricted=0)," ++
            "per_user AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_key ORDER BY pp DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) user_place FROM candidates),board AS (SELECT *,row_number() OVER(PARTITION BY beatmap_key ORDER BY score DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) map_place FROM per_user WHERE user_place=1),firsts AS (SELECT *,count(*) OVER() first_count FROM board WHERE map_place=1 AND user_id=?1) SELECT id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score,first_count FROM firsts ORDER BY submitted_at DESC,client,id DESC LIMIT 20",
        .stable, .scorev2 => "WITH candidates(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score,beatmap_key,user_id) AS (SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL,s.passed=1 AND (length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.score,s.score,b.id,s.user_id FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 JOIN users u ON u.id=s.user_id WHERE s.mode=?2 AND s.rank_namespace=?3 AND s.passed=1 AND s.best=1 AND b.status IN(3,4) AND u.restricted=0),per_user AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_key ORDER BY pp DESC,id ASC) user_place FROM candidates),board AS (SELECT *,row_number() OVER(PARTITION BY beatmap_key ORDER BY score DESC,id ASC) map_place FROM per_user WHERE user_place=1),firsts AS (SELECT *,count(*) OVER() first_count FROM board WHERE map_place=1 AND user_id=?1) SELECT id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score,first_count FROM firsts ORDER BY submitted_at DESC,id DESC LIMIT 20",
        .lazer => "WITH candidates(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score,beatmap_key,user_id) AS (SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json,s.passed=1 AND (length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.total_score_without_mods,s.legacy_total_score,b.id,s.user_id FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id JOIN users u ON u.id=s.user_id WHERE s.ruleset_id=?2 AND s.rank_namespace=?3 AND s.passed=1 AND s.best=1 AND b.status IN(3,4) AND u.restricted=0),per_user AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_key ORDER BY pp DESC,id ASC) user_place FROM candidates),board AS (SELECT *,row_number() OVER(PARTITION BY beatmap_key ORDER BY score DESC,id ASC) map_place FROM per_user WHERE user_place=1),firsts AS (SELECT *,count(*) OVER() first_count FROM board WHERE map_place=1 AND user_id=?1) SELECT id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score,first_count FROM firsts ORDER BY submitted_at DESC,id DESC LIMIT 20",
    };
    const pinned = try self.prepareSiteScores(pinned_sql, user_id, score_mode, namespace);
    defer _ = c.sqlite3_finalize(pinned);
    const top = try self.prepareSiteScores(top_sql, user_id, score_mode, namespace);
    defer _ = c.sqlite3_finalize(top);
    const recent = try self.prepareSiteScores(recent_sql, user_id, score_mode, namespace);
    defer _ = c.sqlite3_finalize(recent);
    const firsts = try self.prepareSiteScores(first_sql, user_id, score_mode, namespace);
    defer _ = c.sqlite3_finalize(firsts);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"id\":{d},\"name\":", .{c.sqlite3_column_int(user, 0)});
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 1)));
    try output.writer.writeAll(",\"country\":");
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 2)));
    try output.writer.print(",\"privileges\":{d},\"created_at\":{d},\"bio\":", .{ c.sqlite3_column_int64(user, 3), c.sqlite3_column_int64(user, 4) });
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 5)));
    try output.writer.writeAll(",\"profile_source\":");
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 7)));
    try output.writer.print(",\"preferred_mode\":{d},\"avatar_version\":{d},\"profile_title\":", .{ c.sqlite3_column_int(user, 6), c.sqlite3_column_int64(user, 8) });
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 9)));
    try output.writer.writeAll(",\"profile_pronouns\":");
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 10)));
    try output.writer.writeAll(",\"profile_location\":");
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 11)));
    try output.writer.writeAll(",\"profile_website\":");
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 12)));
    try output.writer.writeAll(",\"profile_accent\":");
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 13)));
    const banner_version = c.sqlite3_column_int64(user, 16);
    try output.writer.writeAll(",\"banner_url\":");
    if (banner_version > 0) try output.writer.print("\"https://assets.kai.ovh/banners/{d}/cover.jpg?v={d}\"", .{ user_id, banner_version }) else try output.writer.writeAll("null");
    try output.writer.writeAll(",\"team\":");
    if (c.sqlite3_column_type(user, 17) == c.SQLITE_NULL) {
        try output.writer.writeAll("null");
    } else {
        const team_id = c.sqlite3_column_int(user, 17);
        try output.writer.print("{{\"id\":{d},\"name\":", .{team_id});
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 18)));
        try output.writer.writeAll(",\"short_name\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 19)));
        const flag_version = c.sqlite3_column_int64(user, 20);
        try output.writer.writeAll(",\"flag_url\":");
        if (flag_version > 0) try output.writer.print("\"https://assets.kai.ovh/teams/{d}/flag?v={d}\"", .{ team_id, flag_version }) else try output.writer.writeAll("null");
        try output.writer.writeByte('}');
    }
    try output.writer.print(",\"follower_count\":{d},\"stats_public\":{},\"recent_scores_public\":{},\"selected_source\":\"{s}\",\"stats_source\":\"{s}\",\"selected_mode\":{d},\"selected_stats\":", .{ c.sqlite3_column_int(user, 21), show_profile_stats, show_recent_scores, @tagName(source), if (source == .all) "combined" else @tagName(source), stats_mode });
    if (show_profile_stats and c.sqlite3_step(selected_stats) == c.SQLITE_ROW) {
        const total_score = @max(@as(i64, 0), c.sqlite3_column_int64(selected_stats, 1));
        const level = domain.levelFromTotalScore(total_score);
        const current_pp = c.sqlite3_column_int(selected_stats, 2);
        const global_rank = c.sqlite3_column_int(selected_stats, 7);
        const replay_views = try self.replayViewCountLocked(user_id, source, stats_mode);
        try output.writer.print("{{\"ranked_score\":{d},\"total_score\":{d},\"pp\":{d},\"plays\":{d},\"play_time\":{d},\"accuracy\":{d},\"max_combo\":{d},\"global_rank\":{d},\"level_current\":{d},\"level_progress\":{d},\"replay_views\":{d},", .{ c.sqlite3_column_int64(selected_stats, 0), total_score, current_pp, c.sqlite3_column_int(selected_stats, 3), c.sqlite3_column_int(selected_stats, 4), c.sqlite3_column_double(selected_stats, 5), c.sqlite3_column_int(selected_stats, 6), global_rank, level.current, level.progress, replay_views });
        try user_json.writeSiteStatsHistory(&output.writer, stats_history);
        try output.writer.writeByte('}');
    } else {
        try output.writer.writeAll("null");
    }
    try output.writer.writeAll(",\"stats\":[");
    var first = true;
    while (show_profile_stats and c.sqlite3_step(stats) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        const raw_mode: u8 = @intCast(c.sqlite3_column_int(stats, 0));
        try output.writer.print("{{\"mode\":{d},\"ranked_score\":{d},\"total_score\":{d},\"pp\":{d},\"plays\":{d},\"play_time\":{d},\"total_hits\":{d},\"accuracy\":{d},\"max_combo\":{d},\"global_rank\":{d},\"replay_views\":{d}}}", .{ raw_mode, c.sqlite3_column_int64(stats, 1), c.sqlite3_column_int64(stats, 2), c.sqlite3_column_int(stats, 3), c.sqlite3_column_int(stats, 4), c.sqlite3_column_int(stats, 5), c.sqlite3_column_int64(stats, 6), c.sqlite3_column_double(stats, 7), c.sqlite3_column_int(stats, 8), c.sqlite3_column_int(stats, 9), try self.replayViewCountLocked(user_id, .all, raw_mode) });
    }
    try output.writer.writeAll("],\"pinned_scores\":");
    if (show_profile_stats) try writeSiteScores(&output.writer, pinned, false) else try output.writer.writeAll("[]");
    try output.writer.writeAll(",\"top_scores\":");
    if (show_profile_stats) try writeSiteScores(&output.writer, top, true) else try output.writer.writeAll("[]");
    try output.writer.writeAll(",\"recent_scores\":");
    if (show_recent_scores) try writeSiteScores(&output.writer, recent, false) else try output.writer.writeAll("[]");
    const first_step = if (show_profile_stats) c.sqlite3_step(firsts) else c.SQLITE_DONE;
    const first_count: i64 = if (first_step == c.SQLITE_ROW) c.sqlite3_column_int64(firsts, 22) else 0;
    if (first_step == c.SQLITE_ROW) _ = c.sqlite3_reset(firsts);
    try output.writer.print(",\"first_place_count\":{d},\"first_place_scores\":", .{first_count});
    if (show_profile_stats) try writeSiteScores(&output.writer, firsts, false) else try output.writer.writeAll("[]");
    try output.writer.writeAll(",\"beatmapsets\":[");
    var mapped_sets: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT set_id FROM beatmap_submissions WHERE owner_id=?1 AND state='published' ORDER BY updated_at DESC,set_id DESC LIMIT 50", -1, &mapped_sets, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(mapped_sets);
    _ = c.sqlite3_bind_int(mapped_sets, 1, user_id);
    var mapped_written: usize = 0;
    while (c.sqlite3_step(mapped_sets) == c.SQLITE_ROW) {
        var mapped_set: std.Io.Writer.Allocating = .init(allocator);
        defer mapped_set.deinit();
        if (!try self.appendLazerSet(&mapped_set.writer, c.sqlite3_column_int(mapped_sets, 0), user_id)) continue;
        if (mapped_written != 0) try output.writer.writeByte(',');
        mapped_written += 1;
        try output.writer.writeAll(mapped_set.written());
    }
    try output.writer.writeByte(']');
    try output.writer.writeAll(",\"achievements\":");
    try self.writeUserAchievementsLocked(&output.writer, user_id, true);
    try output.writer.writeByte('}');
    var list = output.toArrayList();
    return try list.toOwnedSlice(allocator);
}

pub fn lazerMostPlayedJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, requester_id: i32, offset: u16, limit: u8) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "WITH plays AS (SELECT b.id beatmap_id,count(*) plays FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=?1 GROUP BY b.id UNION ALL SELECT beatmap_id,count(*) FROM lazer_scores WHERE user_id=?1 GROUP BY beatmap_id), totals AS (SELECT beatmap_id,sum(plays) plays FROM plays GROUP BY beatmap_id) SELECT beatmap_id,plays FROM totals ORDER BY plays DESC,beatmap_id LIMIT ?2 OFFSET ?3";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, limit);
    _ = c.sqlite3_bind_int(stmt, 3, offset);
    var ids: [100]i32 = undefined;
    var counts: [100]i32 = undefined;
    var count: usize = 0;
    while (count < limit and c.sqlite3_step(stmt) == c.SQLITE_ROW) : (count += 1) {
        ids[count] = c.sqlite3_column_int(stmt, 0);
        counts[count] = c.sqlite3_column_int(stmt, 1);
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var written: usize = 0;
    for (ids[0..count], counts[0..count]) |beatmap_id, play_count| {
        var map: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT b.id,b.set_id,b.status,b.md5,b.plays,b.passes,b.mode,b.star_rating,b.hp,b.cs,b.ar,b.od,b.total_length,b.version,b.max_combo,coalesce(m.last_updated,coalesce(strftime('%Y-%m-%dT%H:%M:%SZ',b.last_update,'unixepoch'),'1970-01-01T00:00:00Z')),b.bpm,b.count_circles,b.count_sliders,b.count_spinners,coalesce(owner.id,b.creator_id,0),coalesce(owner.name,b.creator),CASE WHEN b.hit_length>0 THEN b.hit_length ELSE b.total_length END FROM beatmaps b LEFT JOIN beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN users owner ON owner.id=submission.owner_id WHERE b.id=?1", -1, &map, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(map);
        _ = c.sqlite3_bind_int(map, 1, beatmap_id);
        if (c.sqlite3_step(map) != c.SQLITE_ROW) continue;
        var set: std.Io.Writer.Allocating = .init(allocator);
        defer set.deinit();
        if (!try self.appendLazerSet(&set.writer, c.sqlite3_column_int(map, 1), requester_id)) continue;
        if (written != 0) try output.writer.writeByte(',');
        written += 1;
        try output.writer.print("{{\"beatmap_id\":{d},\"count\":{d},\"beatmap\":", .{ beatmap_id, play_count });
        try self.appendLazerMap(&output.writer, map.?, requester_id);
        try output.writer.writeAll(",\"beatmapset\":");
        try output.writer.writeAll(set.written());
        try output.writer.writeByte('}');
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}
