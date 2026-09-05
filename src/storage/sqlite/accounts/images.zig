const std = @import("std");
const screenshot_contract = @import("../../../screenshot.zig");
const c = @import("../../../storage.zig").c;
const customImageFromSqlite = @import("../../../storage.zig").customImageFromSqlite;
const Store = @import("../../../storage.zig").Store;
const CustomAvatar = @import("../../contracts.zig").CustomAvatar;

pub fn avatarForUser(self: *Store, user_id: i32) !?u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT avatar_key FROM users WHERE id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const key = c.sqlite3_column_int(stmt, 0);
    if (key < 1 or key > 2) return error.InvalidAvatarKey;
    return @intCast(key);
}

pub fn customAvatarForUser(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?CustomAvatar {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT content_type,etag,object_key,updated_at FROM user_avatars WHERE user_id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const content_type = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)));
    errdefer allocator.free(content_type);
    const etag_value = std.mem.span(c.sqlite3_column_text(stmt, 1));
    if (etag_value.len != 64) return error.InvalidAvatarEtag;
    var etag: [64]u8 = undefined;
    @memcpy(&etag, etag_value);
    const object_key = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)));
    return .{ .allocator = allocator, .content_type = content_type, .etag = etag, .object_key = object_key, .updated_at = c.sqlite3_column_int64(stmt, 3) };
}

pub fn setCustomAvatar(self: *Store, user_id: i32, object_key: []const u8, content_type: []const u8, etag: [64]u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "INSERT INTO user_avatars(user_id,object_key,content_type,etag) VALUES(?1,?2,?3,?4) ON CONFLICT(user_id) DO UPDATE SET object_key=excluded.object_key,content_type=excluded.content_type,etag=excluded.etag,updated_at=max(unixepoch(),user_avatars.updated_at+1)";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_text(stmt, 2, object_key.ptr, @intCast(object_key.len), null);
    _ = c.sqlite3_bind_text(stmt, 3, content_type.ptr, @intCast(content_type.len), null);
    _ = c.sqlite3_bind_text(stmt, 4, &etag, etag.len, null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn deleteCustomAvatar(self: *Store, user_id: i32) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "DELETE FROM user_avatars WHERE user_id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return c.sqlite3_changes(self.db) != 0;
}

pub fn customBannerForUser(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?CustomAvatar {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT content_type,etag,object_key,updated_at,width,height FROM user_banners WHERE user_id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return try customImageFromSqlite(allocator, stmt.?);
}

pub fn setCustomBanner(self: *Store, user_id: i32, object_key: []const u8, content_type: []const u8, etag: [64]u8, width: u32, height: u32) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "INSERT INTO user_banners(user_id,object_key,content_type,etag,width,height) VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(user_id) DO UPDATE SET object_key=excluded.object_key,content_type=excluded.content_type,etag=excluded.etag,width=excluded.width,height=excluded.height,updated_at=max(unixepoch(),user_banners.updated_at+1)";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_text(stmt, 2, object_key.ptr, @intCast(object_key.len), null);
    _ = c.sqlite3_bind_text(stmt, 3, content_type.ptr, @intCast(content_type.len), null);
    _ = c.sqlite3_bind_text(stmt, 4, &etag, etag.len, null);
    _ = c.sqlite3_bind_int64(stmt, 5, width);
    _ = c.sqlite3_bind_int64(stmt, 6, height);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn deleteCustomBanner(self: *Store, user_id: i32) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "DELETE FROM user_banners WHERE user_id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return c.sqlite3_changes(self.db) != 0;
}

pub fn teamAsset(self: *Store, allocator: std.mem.Allocator, team_id: i32, kind: []const u8) !?CustomAvatar {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT content_type,etag,object_key,updated_at,width,height FROM team_assets WHERE team_id=?1 AND kind=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, team_id);
    _ = c.sqlite3_bind_text(stmt, 2, kind.ptr, @intCast(kind.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return try customImageFromSqlite(allocator, stmt.?);
}

pub fn setTeamAsset(self: *Store, team_id: i32, kind: []const u8, object_key: []const u8, content_type: []const u8, etag: [64]u8, width: u32, height: u32) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "INSERT INTO team_assets(team_id,kind,object_key,content_type,etag,width,height) VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(team_id,kind) DO UPDATE SET object_key=excluded.object_key,content_type=excluded.content_type,etag=excluded.etag,width=excluded.width,height=excluded.height,updated_at=max(unixepoch(),team_assets.updated_at+1)";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, team_id);
    _ = c.sqlite3_bind_text(stmt, 2, kind.ptr, @intCast(kind.len), null);
    _ = c.sqlite3_bind_text(stmt, 3, object_key.ptr, @intCast(object_key.len), null);
    _ = c.sqlite3_bind_text(stmt, 4, content_type.ptr, @intCast(content_type.len), null);
    _ = c.sqlite3_bind_text(stmt, 5, &etag, etag.len, null);
    _ = c.sqlite3_bind_int64(stmt, 6, width);
    _ = c.sqlite3_bind_int64(stmt, 7, height);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn deleteTeamAsset(self: *Store, team_id: i32, kind: []const u8) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "DELETE FROM team_assets WHERE team_id=?1 AND kind=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, team_id);
    _ = c.sqlite3_bind_text(stmt, 2, kind.ptr, @intCast(kind.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return c.sqlite3_changes(self.db) != 0;
}

pub fn putScreenshot(self: *Store, user_id: i32, token: []const u8, extension: []const u8, image: []const u8) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var quota: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT count(*),coalesce(sum(length(image)),0) FROM screenshots WHERE uploader_id=?1", -1, &quota, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(quota);
    _ = c.sqlite3_bind_int(quota, 1, user_id);
    if (c.sqlite3_step(quota) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    const file_count: usize = @intCast(c.sqlite3_column_int64(quota, 0));
    const byte_count: usize = @intCast(c.sqlite3_column_int64(quota, 1));
    if (!screenshot_contract.quotaAllows(file_count, byte_count, image.len)) return error.ScreenshotQuotaExceeded;
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO screenshots(token,extension,uploader_id,image) VALUES(?1,?2,?3,?4)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, token.ptr, @intCast(token.len), null);
    _ = c.sqlite3_bind_text(stmt, 2, extension.ptr, @intCast(extension.len), null);
    _ = c.sqlite3_bind_int(stmt, 3, user_id);
    _ = c.sqlite3_bind_blob(stmt, 4, image.ptr, @intCast(image.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return c.sqlite3_changes(self.db) == 1;
}

pub fn screenshot(self: *Store, allocator: std.mem.Allocator, token: []const u8, extension: []const u8) !?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT image FROM screenshots WHERE token=?1 AND extension=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, token.ptr, @intCast(token.len), null);
    _ = c.sqlite3_bind_text(stmt, 2, extension.ptr, @intCast(extension.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0));
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
    return @as(?[]u8, try allocator.dupe(u8, ptr[0..len]));
}
