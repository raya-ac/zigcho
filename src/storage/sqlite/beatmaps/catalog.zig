const std = @import("std");
const beatmap = @import("../../../beatmap.zig");
const lazer = @import("../../../lazer.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const StableBeatmapInfo = @import("../../contracts.zig").StableBeatmapInfo;
const BeatmapForScore = @import("../../contracts.zig").BeatmapForScore;
const BeatmapRating = @import("../../contracts.zig").BeatmapRating;
const BeatmapInfo = @import("../../contracts.zig").BeatmapInfo;
const stableStatus = @import("../../contracts.zig").stableStatus;

pub const stableGrade = @import("../../contracts.zig").stableGrade;

pub fn stableBeatmapInfoLocked(self: *Store, user_id: i32, field: []const u8, by_id: bool) !?StableBeatmapInfo {
    const sql = if (by_id)
        "SELECT id,set_id,md5,status FROM beatmaps WHERE id=CAST(?1 AS INTEGER)"
    else
        "SELECT id,set_id,md5,status FROM beatmaps WHERE artist || ' - ' || title || ' (' || creator || ') [' || version || '].osu'=?1";
    var map_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &map_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(map_stmt);
    _ = c.sqlite3_bind_text(map_stmt, 1, field.ptr, @intCast(field.len), null);
    if (c.sqlite3_step(map_stmt) != c.SQLITE_ROW) return null;
    const md5_text = std.mem.span(c.sqlite3_column_text(map_stmt, 2));
    if (md5_text.len != 32) return error.InvalidBeatmapChecksum;
    var info: StableBeatmapInfo = .{
        .id = c.sqlite3_column_int(map_stmt, 0),
        .set_id = c.sqlite3_column_int(map_stmt, 1),
        .md5 = undefined,
        .status = switch (stableStatus(c.sqlite3_column_int(map_stmt, 3))) {
            0 => 0,
            2 => 1,
            3 => 2,
            4 => 3,
            5 => 4,
            else => 0,
        },
        .grades = .{ "N", "N", "N", "N" },
    };
    @memcpy(&info.md5, md5_text);
    var score_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT mode,mods,accuracy,n300,n100,n50,nmiss FROM scores WHERE user_id=?1 AND map_md5=?2 AND rank_namespace='vanilla' AND passed=1 AND best=1 AND mode BETWEEN 0 AND 3", -1, &score_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(score_stmt);
    _ = c.sqlite3_bind_int(score_stmt, 1, user_id);
    _ = c.sqlite3_bind_text(score_stmt, 2, info.md5[0..].ptr, info.md5.len, null);
    while (c.sqlite3_step(score_stmt) == c.SQLITE_ROW) {
        const mode: u8 = @intCast(c.sqlite3_column_int(score_stmt, 0));
        info.grades[mode] = stableGrade(mode, c.sqlite3_column_int(score_stmt, 1), c.sqlite3_column_double(score_stmt, 2), c.sqlite3_column_int(score_stmt, 3), c.sqlite3_column_int(score_stmt, 4), c.sqlite3_column_int(score_stmt, 5), c.sqlite3_column_int(score_stmt, 6));
    }
    return info;
}

pub fn stableBeatmapInfoByFilename(self: *Store, user_id: i32, filename: []const u8) !?StableBeatmapInfo {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.stableBeatmapInfoLocked(user_id, filename, false);
}

pub fn stableBeatmapInfoById(self: *Store, user_id: i32, map_id: i32) !?StableBeatmapInfo {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{map_id});
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.stableBeatmapInfoLocked(user_id, id, true);
}

pub fn rateBeatmap(self: *Store, user_id: i32, map_md5: []const u8, rating: ?u8) !BeatmapRating {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    var map_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT status FROM beatmaps WHERE md5=?1", -1, &map_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(map_stmt);
    _ = c.sqlite3_bind_text(map_stmt, 1, map_md5.ptr, @intCast(map_md5.len), null);
    if (c.sqlite3_step(map_stmt) != c.SQLITE_ROW) return .no_exist;
    if (c.sqlite3_column_int(map_stmt, 0) < 3) return .not_ranked;

    if (rating) |value| {
        if (value < 1 or value > 10) return error.InvalidRating;
        var insert_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT INTO ratings(user_id,map_md5,rating) VALUES(?1,?2,?3) ON CONFLICT(user_id,map_md5) DO NOTHING", -1, &insert_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(insert_stmt);
        _ = c.sqlite3_bind_int(insert_stmt, 1, user_id);
        _ = c.sqlite3_bind_text(insert_stmt, 2, map_md5.ptr, @intCast(map_md5.len), null);
        _ = c.sqlite3_bind_int(insert_stmt, 3, value);
        if (c.sqlite3_step(insert_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    } else {
        var existing_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM ratings WHERE user_id=?1 AND map_md5=?2", -1, &existing_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(existing_stmt);
        _ = c.sqlite3_bind_int(existing_stmt, 1, user_id);
        _ = c.sqlite3_bind_text(existing_stmt, 2, map_md5.ptr, @intCast(map_md5.len), null);
        if (c.sqlite3_step(existing_stmt) != c.SQLITE_ROW) return .can_rate;
    }

    var average_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT avg(rating) FROM ratings WHERE map_md5=?1", -1, &average_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(average_stmt);
    _ = c.sqlite3_bind_text(average_stmt, 1, map_md5.ptr, @intCast(map_md5.len), null);
    if (c.sqlite3_step(average_stmt) != c.SQLITE_ROW or c.sqlite3_column_type(average_stmt, 0) == c.SQLITE_NULL) return error.DatabaseQueryFailed;
    return .{ .already_voted = c.sqlite3_column_double(average_stmt, 0) };
}

pub fn recordLastFmFlag(self: *Store, user_id: i32, flags: u32) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    try self.exec("DELETE FROM audit_log WHERE id IN (SELECT id FROM audit_log WHERE action='stable.lastfm_flag' AND created_at<unixepoch()-15552000 ORDER BY created_at,id LIMIT 128)");
    var target_buf: [24]u8 = undefined;
    var detail_buf: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{user_id});
    const detail = try std.fmt.bufPrint(&detail_buf, "flags:{d}", .{flags});
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO audit_log(actor_id,action,target,detail) SELECT ?1,'stable.lastfm_flag',?2,?3 WHERE NOT EXISTS(SELECT 1 FROM audit_log WHERE actor_id=?1 AND action='stable.lastfm_flag' AND target=?2 AND detail=?3 AND created_at>=unixepoch()-86400)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_text(stmt, 2, target.ptr, @intCast(target.len), null);
    _ = c.sqlite3_bind_text(stmt, 3, detail.ptr, @intCast(detail.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    try self.exec("COMMIT");
}

pub fn upsertBeatmap(self: *Store, metadata: beatmap.Metadata, md5: []const u8, status: i8, stars: f64, max_combo: u32, osu_file: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var previous_status: ?i8 = null;
    var previous_frozen = false;
    var had_scores = false;
    var previous: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT b.status,b.status_frozen,EXISTS(SELECT 1 FROM scores s WHERE s.map_md5=b.md5) OR EXISTS(SELECT 1 FROM lazer_scores l WHERE l.beatmap_id=b.id) FROM beatmaps b WHERE b.id=?1", -1, &previous, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_int(previous, 1, metadata.id);
    if (c.sqlite3_step(previous) == c.SQLITE_ROW) {
        previous_status = @intCast(c.sqlite3_column_int(previous, 0));
        previous_frozen = c.sqlite3_column_int(previous, 1) != 0;
        had_scores = c.sqlite3_column_int(previous, 2) != 0;
    }
    _ = c.sqlite3_finalize(previous);
    const sql = "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,last_update,total_length,max_combo,mode,bpm,cs,ar,od,hp,star_rating,source,tags,osu_file,count_circles,count_sliders,count_spinners) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,unixepoch(),?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23) ON CONFLICT(id) DO UPDATE SET set_id=excluded.set_id,md5=excluded.md5,artist=excluded.artist,title=excluded.title,version=excluded.version,creator=excluded.creator,status=CASE WHEN beatmaps.status_frozen=1 THEN beatmaps.status ELSE excluded.status END,last_update=excluded.last_update,total_length=excluded.total_length,max_combo=excluded.max_combo,mode=excluded.mode,bpm=excluded.bpm,cs=excluded.cs,ar=excluded.ar,od=excluded.od,hp=excluded.hp,star_rating=excluded.star_rating,source=excluded.source,tags=excluded.tags,osu_file=excluded.osu_file,count_circles=excluded.count_circles,count_sliders=excluded.count_sliders,count_spinners=excluded.count_spinners";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, metadata.id);
    _ = c.sqlite3_bind_int(stmt, 2, metadata.set_id);
    _ = c.sqlite3_bind_text(stmt, 3, md5.ptr, @intCast(md5.len), null);
    _ = c.sqlite3_bind_text(stmt, 4, metadata.artist.ptr, @intCast(metadata.artist.len), null);
    _ = c.sqlite3_bind_text(stmt, 5, metadata.title.ptr, @intCast(metadata.title.len), null);
    _ = c.sqlite3_bind_text(stmt, 6, metadata.version.ptr, @intCast(metadata.version.len), null);
    _ = c.sqlite3_bind_text(stmt, 7, metadata.creator.ptr, @intCast(metadata.creator.len), null);
    _ = c.sqlite3_bind_int(stmt, 8, status);
    _ = c.sqlite3_bind_int(stmt, 9, metadata.total_length);
    _ = c.sqlite3_bind_int64(stmt, 10, max_combo);
    _ = c.sqlite3_bind_int(stmt, 11, metadata.mode);
    _ = c.sqlite3_bind_double(stmt, 12, metadata.bpm);
    _ = c.sqlite3_bind_double(stmt, 13, metadata.cs);
    _ = c.sqlite3_bind_double(stmt, 14, metadata.ar);
    _ = c.sqlite3_bind_double(stmt, 15, metadata.od);
    _ = c.sqlite3_bind_double(stmt, 16, metadata.hp);
    _ = c.sqlite3_bind_double(stmt, 17, stars);
    _ = c.sqlite3_bind_text(stmt, 18, metadata.source.ptr, @intCast(metadata.source.len), null);
    _ = c.sqlite3_bind_text(stmt, 19, metadata.tags.ptr, @intCast(metadata.tags.len), null);
    _ = c.sqlite3_bind_blob(stmt, 20, osu_file.ptr, @intCast(osu_file.len), null);
    _ = c.sqlite3_bind_int64(stmt, 21, metadata.count_circles);
    _ = c.sqlite3_bind_int64(stmt, 22, metadata.count_sliders);
    _ = c.sqlite3_bind_int64(stmt, 23, metadata.count_spinners);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    if (previous_status) |old_status| {
        const effective_status = if (previous_frozen) old_status else status;
        const leaderboard_changed = (old_status >= 3) != (effective_status >= 3);
        const ranked_changed = (old_status == 3 or old_status == 4) != (effective_status == 3 or effective_status == 4);
        if (had_scores and (leaderboard_changed or ranked_changed)) {
            try self.rebuildScoreStats(false);
            try self.recordBeatmapStatsHistoryCurrentLocked(metadata.id, md5);
        }
    }
    try self.exec("COMMIT");
}

pub fn upsertBeatmapMeta(self: *Store, map: beatmap.Metadata, md5: []const u8, status: i8, stars: f64, max_combo: u32) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,last_update,total_length,max_combo,mode,bpm,cs,ar,od,hp,star_rating,source,tags,osu_file,count_circles,count_sliders,count_spinners) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,unixepoch(),?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,NULL,?20,?21,?22) ON CONFLICT(id) DO NOTHING";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, map.id);
    _ = c.sqlite3_bind_int(stmt, 2, map.set_id);
    _ = c.sqlite3_bind_text(stmt, 3, md5.ptr, @intCast(md5.len), null);
    _ = c.sqlite3_bind_text(stmt, 4, map.artist.ptr, @intCast(map.artist.len), null);
    _ = c.sqlite3_bind_text(stmt, 5, map.title.ptr, @intCast(map.title.len), null);
    _ = c.sqlite3_bind_text(stmt, 6, map.version.ptr, @intCast(map.version.len), null);
    _ = c.sqlite3_bind_text(stmt, 7, map.creator.ptr, @intCast(map.creator.len), null);
    _ = c.sqlite3_bind_int(stmt, 8, status);
    _ = c.sqlite3_bind_int(stmt, 9, map.total_length);
    _ = c.sqlite3_bind_int64(stmt, 10, max_combo);
    _ = c.sqlite3_bind_int(stmt, 11, map.mode);
    _ = c.sqlite3_bind_double(stmt, 12, map.bpm);
    _ = c.sqlite3_bind_double(stmt, 13, map.cs);
    _ = c.sqlite3_bind_double(stmt, 14, map.ar);
    _ = c.sqlite3_bind_double(stmt, 15, map.od);
    _ = c.sqlite3_bind_double(stmt, 16, map.hp);
    _ = c.sqlite3_bind_double(stmt, 17, stars);
    _ = c.sqlite3_bind_text(stmt, 18, map.source.ptr, @intCast(map.source.len), null);
    _ = c.sqlite3_bind_text(stmt, 19, map.tags.ptr, @intCast(map.tags.len), null);
    _ = c.sqlite3_bind_int64(stmt, 20, map.count_circles);
    _ = c.sqlite3_bind_int64(stmt, 21, map.count_sliders);
    _ = c.sqlite3_bind_int64(stmt, 22, map.count_spinners);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn beatmapFile(self: *Store, allocator: std.mem.Allocator, md5: []const u8) !?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = "SELECT osu_file FROM beatmaps WHERE md5=?1 AND osu_file IS NOT NULL";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, md5.ptr, @intCast(md5.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0));
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
    return try allocator.dupe(u8, ptr[0..len]);
}

pub fn beatmapHasFile(self: *Store, md5: []const u8) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM beatmaps WHERE md5=?1 AND osu_file IS NOT NULL", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, md5.ptr, @intCast(md5.len), null);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

pub fn beatmapFileById(self: *Store, allocator: std.mem.Allocator, map_id: i32) !?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = "SELECT osu_file FROM beatmaps WHERE id=?1 AND osu_file IS NOT NULL";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, map_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0));
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
    return try allocator.dupe(u8, ptr[0..len]);
}

pub fn beatmapSetIdForMap(self: *Store, beatmap_id: i32) !?i32 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT set_id FROM beatmaps WHERE id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, beatmap_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return c.sqlite3_column_int(stmt, 0);
}

pub fn beatmapSetIdForChecksum(self: *Store, checksum: []const u8) !?i32 {
    if (!lazer.validHash(checksum)) return null;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT set_id FROM beatmaps WHERE md5=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, checksum.ptr, @intCast(checksum.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return c.sqlite3_column_int(stmt, 0);
}

pub fn beatmapForScore(self: *Store, md5: []const u8) !?BeatmapForScore {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = "SELECT id,set_id,status,plays,passes,coalesce(last_update,0) FROM beatmaps WHERE md5=?1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, md5.ptr, @intCast(md5.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return .{ .id = c.sqlite3_column_int(stmt, 0), .set_id = c.sqlite3_column_int(stmt, 1), .status = @intCast(c.sqlite3_column_int(stmt, 2)), .plays = c.sqlite3_column_int(stmt, 3), .passes = c.sqlite3_column_int(stmt, 4), .last_update = c.sqlite3_column_int64(stmt, 5) };
}

pub fn beatmapInfo(self: *Store, allocator: std.mem.Allocator, md5: []const u8) !?BeatmapInfo {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = "SELECT id,set_id,max_combo,artist,title,version,creator,status,star_rating,max(total_length,0),max(CASE WHEN hit_length>0 THEN hit_length ELSE total_length END,0) FROM beatmaps WHERE md5=?1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, md5.ptr, @intCast(md5.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const artist = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3)));
    errdefer allocator.free(artist);
    const title = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 4)));
    errdefer allocator.free(title);
    const version = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 5)));
    errdefer allocator.free(version);
    const creator = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 6)));
    return .{
        .id = c.sqlite3_column_int(stmt, 0),
        .set_id = c.sqlite3_column_int(stmt, 1),
        .max_combo = c.sqlite3_column_int(stmt, 2),
        .artist = artist,
        .title = title,
        .version = version,
        .creator = creator,
        .status = @intCast(c.sqlite3_column_int(stmt, 7)),
        .star_rating = c.sqlite3_column_double(stmt, 8),
        .total_length = c.sqlite3_column_int(stmt, 9),
        .hit_length = c.sqlite3_column_int(stmt, 10),
    };
}

pub fn beatmapInfoById(self: *Store, allocator: std.mem.Allocator, map_id: i32) !?BeatmapInfo {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = "SELECT id,set_id,max_combo,artist,title,version,creator,status,star_rating,max(total_length,0),max(CASE WHEN hit_length>0 THEN hit_length ELSE total_length END,0) FROM beatmaps WHERE id=?1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, map_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const artist = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3)));
    errdefer allocator.free(artist);
    const title = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 4)));
    errdefer allocator.free(title);
    const version = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 5)));
    errdefer allocator.free(version);
    const creator = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 6)));
    return .{ .id = c.sqlite3_column_int(stmt, 0), .set_id = c.sqlite3_column_int(stmt, 1), .max_combo = c.sqlite3_column_int(stmt, 2), .artist = artist, .title = title, .version = version, .creator = creator, .status = @intCast(c.sqlite3_column_int(stmt, 7)), .star_rating = c.sqlite3_column_double(stmt, 8), .total_length = c.sqlite3_column_int(stmt, 9), .hit_length = c.sqlite3_column_int(stmt, 10) };
}
