const std = @import("std");
const upstream_user = @import("../../../upstream_user.zig");
const c = @import("../../../storage.zig").c;
const UpstreamUserCache = @import("../../contracts.zig").UpstreamUserCache;
const BeatmapSetCreator = @import("../../contracts.zig").BeatmapSetCreator;
const Store = @import("../../../storage.zig").Store;

pub fn beatmapSetCreator(self: *Store, allocator: std.mem.Allocator, set_id: i32) !?BeatmapSetCreator {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT coalesce(max(owner.name),b.creator),min(b.mode),coalesce(max(owner.id),max(b.creator_id)),max(owner.id) IS NOT NULL FROM beatmaps b LEFT JOIN beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN users owner ON owner.id=submission.owner_id WHERE b.set_id=?1 GROUP BY b.creator ORDER BY count(*) DESC,b.creator LIMIT 1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, set_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const name = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)));
    return .{
        .allocator = allocator,
        .name = name,
        .mode = @intCast(c.sqlite3_column_int(stmt, 1)),
        .user_id = if (c.sqlite3_column_type(stmt, 2) == c.SQLITE_NULL) null else c.sqlite3_column_int(stmt, 2),
        .is_local = c.sqlite3_column_int(stmt, 3) != 0,
    };
}

pub fn upstreamUserCacheByName(self: *Store, name: []const u8, mode: u8, now: i64, max_age: i64) !?UpstreamUserCache {
    if (mode > 3 or now < 0 or max_age < 0) return error.InvalidUpstreamUser;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT u.id,coalesce(p.fetched_at>=?3-?4,0) FROM upstream_users u LEFT JOIN upstream_user_profiles p ON p.user_id=u.id AND p.mode=?2 WHERE lower(u.username)=lower(?1) ORDER BY u.fetched_at DESC,u.id LIMIT 1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), null);
    _ = c.sqlite3_bind_int(stmt, 2, mode);
    _ = c.sqlite3_bind_int64(stmt, 3, now);
    _ = c.sqlite3_bind_int64(stmt, 4, max_age);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return .{ .id = c.sqlite3_column_int(stmt, 0), .fresh = c.sqlite3_column_int(stmt, 1) != 0 };
}

pub fn upstreamUserCacheById(self: *Store, user_id: i32, mode: u8, now: i64, max_age: i64) !?UpstreamUserCache {
    if (user_id <= 0 or mode > 3 or now < 0 or max_age < 0) return error.InvalidUpstreamUser;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT u.id,coalesce(p.fetched_at>=?3-?4,0) FROM upstream_users u LEFT JOIN upstream_user_profiles p ON p.user_id=u.id AND p.mode=?2 WHERE u.id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, mode);
    _ = c.sqlite3_bind_int64(stmt, 3, now);
    _ = c.sqlite3_bind_int64(stmt, 4, max_age);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return .{ .id = c.sqlite3_column_int(stmt, 0), .fresh = c.sqlite3_column_int(stmt, 1) != 0 };
}

pub fn upsertUpstreamUserProfile(self: *Store, profile: upstream_user.Profile, profile_json: []const u8, fetched_at: i64) !void {
    try upstream_user.validate(profile);
    if (fetched_at < 0 or profile_json.len == 0 or profile_json.len > 128 * 1024 or !std.unicode.utf8ValidateSlice(profile_json)) return error.InvalidUpstreamUser;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var user_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO upstream_users(id,username,country,join_date,fetched_at) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(id) DO UPDATE SET username=excluded.username,country=excluded.country,join_date=excluded.join_date,fetched_at=excluded.fetched_at", -1, &user_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(user_stmt);
    _ = c.sqlite3_bind_int(user_stmt, 1, profile.id);
    _ = c.sqlite3_bind_text(user_stmt, 2, profile.username.ptr, @intCast(profile.username.len), null);
    _ = c.sqlite3_bind_text(user_stmt, 3, profile.country[0..].ptr, profile.country.len, null);
    _ = c.sqlite3_bind_text(user_stmt, 4, profile.join_date.ptr, @intCast(profile.join_date.len), null);
    _ = c.sqlite3_bind_int64(user_stmt, 5, fetched_at);
    if (c.sqlite3_step(user_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    var profile_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO upstream_user_profiles(user_id,mode,profile_json,fetched_at) VALUES(?1,?2,?3,?4) ON CONFLICT(user_id,mode) DO UPDATE SET profile_json=excluded.profile_json,fetched_at=excluded.fetched_at", -1, &profile_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(profile_stmt);
    _ = c.sqlite3_bind_int(profile_stmt, 1, profile.id);
    _ = c.sqlite3_bind_int(profile_stmt, 2, profile.mode);
    _ = c.sqlite3_bind_text(profile_stmt, 3, profile_json.ptr, @intCast(profile_json.len), null);
    _ = c.sqlite3_bind_int64(profile_stmt, 4, fetched_at);
    if (c.sqlite3_step(profile_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    try self.exec("COMMIT");
}

pub fn linkBeatmapSetCreator(self: *Store, set_id: i32, user_id: i32) !void {
    if (set_id <= 0 or user_id <= 0) return error.InvalidUpstreamUser;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmaps SET creator_id=?2 WHERE set_id=?1 AND EXISTS(SELECT 1 FROM upstream_users WHERE id=?2)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, set_id);
    _ = c.sqlite3_bind_int(stmt, 2, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn upstreamUserProfileJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, mode: u8) !?[]u8 {
    if (user_id <= 0 or mode > 3) return null;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT profile_json FROM upstream_user_profiles WHERE user_id=?1 ORDER BY mode=?2 DESC,mode=0 DESC,mode LIMIT 1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, mode);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return @as(?[]u8, try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))));
}

pub fn upsertBeatmapSetMetadata(self: *Store, metadata: upstream_user.SetMetadata, fetched_at: i64) !void {
    if (metadata.set_id <= 0 or metadata.favourites < 0 or metadata.genre_id < 0 or metadata.language_id < 0 or fetched_at < 0 or metadata.submitted_date.len != 20 or metadata.last_updated.len != 20 or (metadata.ranked_date != null and metadata.ranked_date.?.len != 20)) return error.InvalidBeatmapSetMetadata;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO beatmapset_metadata(set_id,favourites,submitted_date,last_updated,ranked_date,has_video,genre_id,language_id,fetched_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9) ON CONFLICT(set_id) DO UPDATE SET favourites=excluded.favourites,submitted_date=excluded.submitted_date,last_updated=excluded.last_updated,ranked_date=excluded.ranked_date,has_video=excluded.has_video,genre_id=excluded.genre_id,language_id=excluded.language_id,fetched_at=excluded.fetched_at", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, metadata.set_id);
    _ = c.sqlite3_bind_int(stmt, 2, metadata.favourites);
    _ = c.sqlite3_bind_text(stmt, 3, metadata.submitted_date.ptr, @intCast(metadata.submitted_date.len), null);
    _ = c.sqlite3_bind_text(stmt, 4, metadata.last_updated.ptr, @intCast(metadata.last_updated.len), null);
    if (metadata.ranked_date) |value| _ = c.sqlite3_bind_text(stmt, 5, value.ptr, @intCast(value.len), null) else _ = c.sqlite3_bind_null(stmt, 5);
    _ = c.sqlite3_bind_int(stmt, 6, @intFromBool(metadata.has_video));
    _ = c.sqlite3_bind_int(stmt, 7, metadata.genre_id);
    _ = c.sqlite3_bind_int(stmt, 8, metadata.language_id);
    _ = c.sqlite3_bind_int64(stmt, 9, fetched_at);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn updateBeatmapUpstreamStats(self: *Store, beatmap_id: i32, plays: i32, passes: i32, hit_length: i32) !void {
    if (beatmap_id <= 0 or plays < 0 or passes < 0 or passes > plays or hit_length < 0) return error.InvalidBeatmapSetMetadata;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmaps SET upstream_plays=?2,upstream_passes=?3,hit_length=?4 WHERE id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, beatmap_id);
    _ = c.sqlite3_bind_int(stmt, 2, plays);
    _ = c.sqlite3_bind_int(stmt, 3, passes);
    _ = c.sqlite3_bind_int(stmt, 4, hit_length);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}
