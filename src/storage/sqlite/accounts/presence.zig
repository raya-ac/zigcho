const std = @import("std");
const domain = @import("../../../domain.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;

pub fn recentOauthUserIds(self: *Store, allocator: std.mem.Allocator, cutoff: i64) ![]i32 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT DISTINCT t.user_id FROM oauth_tokens t JOIN users u ON u.id=t.user_id WHERE t.last_used_at>=?1 AND t.revoked_at IS NULL AND t.expires_at>unixepoch() AND instr(' '||t.scopes||' ',' identify ')>0 AND instr(' '||t.scopes||' ',' scores:write ')>0 AND u.restricted=0 ORDER BY t.user_id";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, cutoff);
    var ids: std.ArrayList(i32) = .empty;
    errdefer ids.deinit(allocator);
    while (true) switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => try ids.append(allocator, c.sqlite3_column_int(stmt, 0)),
        c.SQLITE_DONE => break,
        else => return error.DatabaseQueryFailed,
    };
    return ids.toOwnedSlice(allocator);
}

pub fn lazerUserOnline(self: *Store, user_id: i32, cutoff: i64) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT 1 FROM oauth_tokens WHERE user_id=?1 AND last_used_at>=?2 AND revoked_at IS NULL AND expires_at>unixepoch() AND instr(' '||scopes||' ',' identify ')>0 AND instr(' '||scopes||' ',' scores:write ')>0 LIMIT 1";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int64(stmt, 2, cutoff);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

pub fn setLazerActivityForToken(self: *Store, token: []const u8, expected_user_id: i32, status: []const u8, detail: []const u8, beatmap_id: ?i32, ruleset_id: ?u8) !bool {
    if (token.len != 64 or expected_user_id <= 0) return false;
    if (!domain.validLazerActivity(status, detail, beatmap_id, ruleset_id)) return error.InvalidLazerActivity;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var owner: ?*c.sqlite3_stmt = null;
    const owner_sql = "SELECT 1 FROM oauth_tokens WHERE token_hash=?1 AND user_id=?2 AND revoked_at IS NULL AND expires_at>unixepoch() AND instr(' '||scopes||' ',' identify ')>0 AND instr(' '||scopes||' ',' scores:write ')>0";
    if (c.sqlite3_prepare_v2(self.db, owner_sql, -1, &owner, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_blob(owner, 1, &digest, digest.len, null);
    _ = c.sqlite3_bind_int(owner, 2, expected_user_id);
    const owns_session = c.sqlite3_step(owner) == c.SQLITE_ROW;
    _ = c.sqlite3_finalize(owner);
    if (!owns_session) return false;

    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var activity: ?*c.sqlite3_stmt = null;
    const activity_sql = "INSERT INTO lazer_presence(user_id,status,detail,beatmap_id,ruleset_id,updated_at) VALUES(?1,?2,?3,?4,?5,unixepoch()) ON CONFLICT(user_id) DO UPDATE SET status=excluded.status,detail=excluded.detail,beatmap_id=excluded.beatmap_id,ruleset_id=excluded.ruleset_id,updated_at=excluded.updated_at";
    if (c.sqlite3_prepare_v2(self.db, activity_sql, -1, &activity, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(activity);
    _ = c.sqlite3_bind_int(activity, 1, expected_user_id);
    _ = c.sqlite3_bind_text(activity, 2, status.ptr, @intCast(status.len), null);
    _ = c.sqlite3_bind_text(activity, 3, detail.ptr, @intCast(detail.len), null);
    if (beatmap_id) |id| _ = c.sqlite3_bind_int(activity, 4, id) else _ = c.sqlite3_bind_null(activity, 4);
    if (ruleset_id) |id| _ = c.sqlite3_bind_int(activity, 5, id) else _ = c.sqlite3_bind_null(activity, 5);
    if (c.sqlite3_step(activity) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    var touch: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE oauth_tokens SET last_used_at=unixepoch() WHERE token_hash=?1 AND user_id=?2 AND revoked_at IS NULL", -1, &touch, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(touch);
    _ = c.sqlite3_bind_blob(touch, 1, &digest, digest.len, null);
    _ = c.sqlite3_bind_int(touch, 2, expected_user_id);
    if (c.sqlite3_step(touch) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.DatabaseQueryFailed;
    try self.exec("COMMIT");
    return true;
}

pub fn clearLazerActivityForToken(self: *Store, token: []const u8, expected_user_id: i32) !bool {
    if (token.len != 64 or expected_user_id <= 0) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var owner: ?*c.sqlite3_stmt = null;
    const owner_sql = "SELECT 1 FROM oauth_tokens WHERE token_hash=?1 AND user_id=?2 AND revoked_at IS NULL AND expires_at>unixepoch() AND instr(' '||scopes||' ',' identify ')>0 AND instr(' '||scopes||' ',' scores:write ')>0";
    if (c.sqlite3_prepare_v2(self.db, owner_sql, -1, &owner, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_blob(owner, 1, &digest, digest.len, null);
    _ = c.sqlite3_bind_int(owner, 2, expected_user_id);
    const owns_session = c.sqlite3_step(owner) == c.SQLITE_ROW;
    _ = c.sqlite3_finalize(owner);
    if (!owns_session) return false;

    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var clear: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "DELETE FROM lazer_presence WHERE user_id=?1", -1, &clear, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(clear);
    _ = c.sqlite3_bind_int(clear, 1, expected_user_id);
    if (c.sqlite3_step(clear) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    var touch: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE oauth_tokens SET last_used_at=unixepoch() WHERE token_hash=?1 AND user_id=?2 AND revoked_at IS NULL", -1, &touch, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(touch);
    _ = c.sqlite3_bind_blob(touch, 1, &digest, digest.len, null);
    _ = c.sqlite3_bind_int(touch, 2, expected_user_id);
    if (c.sqlite3_step(touch) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.DatabaseQueryFailed;
    try self.exec("COMMIT");
    return true;
}

pub fn lazerActivity(self: *Store, allocator: std.mem.Allocator, user_id: i32, cutoff: i64) !?domain.LazerActivity {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT status,detail,beatmap_id,ruleset_id FROM lazer_presence WHERE user_id=?1 AND updated_at>=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int64(stmt, 2, cutoff);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const status = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)));
    errdefer allocator.free(status);
    const detail = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
    return .{
        .allocator = allocator,
        .status = status,
        .detail = detail,
        .beatmap_id = if (c.sqlite3_column_type(stmt, 2) == c.SQLITE_NULL) null else c.sqlite3_column_int(stmt, 2),
        .ruleset_id = if (c.sqlite3_column_type(stmt, 3) == c.SQLITE_NULL) null else @intCast(c.sqlite3_column_int(stmt, 3)),
    };
}
