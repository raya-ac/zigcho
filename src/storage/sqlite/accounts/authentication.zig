const std = @import("std");
const domain = @import("../../../domain.zig");
const visible_follower_count_sql = @import("../../../storage.zig").visible_follower_count_sql;
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const RegistrationConflicts = @import("../../contracts.zig").RegistrationConflicts;

pub fn register(self: *Store, name: []const u8, email: []const u8, password_md5: []const u8) !i32 {
    const safe = try domain.safeName(self.allocator, name);
    defer self.allocator.free(safe);
    var hash_buffer: [256]u8 = undefined;
    const hash = try std.crypto.pwhash.argon2.strHash(password_md5, .{
        .allocator = self.allocator,
        .params = .owasp_2id,
    }, &hash_buffer, self.io);
    var random_byte: [1]u8 = undefined;
    try std.Io.randomSecure(self.io, &random_byte);
    const avatar_key: u8 = 1 + (random_byte[0] & 1);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = "INSERT INTO users(name,safe_name,email,password_hash,password_salt,avatar_key) VALUES(?1,?2,?3,?4,?5,?6)";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), null);
    _ = c.sqlite3_bind_text(stmt, 2, safe.ptr, @intCast(safe.len), null);
    _ = c.sqlite3_bind_text(stmt, 3, email.ptr, @intCast(email.len), null);
    _ = c.sqlite3_bind_blob(stmt, 4, hash.ptr, @intCast(hash.len), null);
    _ = c.sqlite3_bind_blob(stmt, 5, "argon2id".ptr, 8, null);
    _ = c.sqlite3_bind_int(stmt, 6, avatar_key);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.UserExists;
    const id: i32 = @intCast(c.sqlite3_last_insert_rowid(self.db));
    const stat_modes = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 8 };
    for (stat_modes) |mode| {
        var buf: [128]u8 = undefined;
        const q = std.fmt.bufPrintZ(&buf, "INSERT INTO stats(user_id,mode) VALUES({d},{d})", .{ id, mode }) catch return error.DatabaseQueryFailed;
        try self.exec(q);
    }
    return id;
}

pub fn registrationConflicts(self: *Store, name: []const u8, email: []const u8) !RegistrationConflicts {
    const safe = try domain.safeName(self.allocator, name);
    defer self.allocator.free(safe);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = "SELECT EXISTS(SELECT 1 FROM users WHERE safe_name=?1), EXISTS(SELECT 1 FROM users WHERE email=?2)";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, safe.ptr, @intCast(safe.len), null);
    _ = c.sqlite3_bind_text(stmt, 2, email.ptr, @intCast(email.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return .{ .username = c.sqlite3_column_int(stmt, 0) != 0, .email = c.sqlite3_column_int(stmt, 1) != 0 };
}

pub fn updateAccountEmail(self: *Store, user_id: i32, email: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE users SET email=?1 WHERE id=?2 AND id!=3 AND NOT EXISTS(SELECT 1 FROM users other WHERE other.email=?1 AND other.id!=?2)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, email.ptr, @intCast(email.len), null);
    _ = c.sqlite3_bind_int(stmt, 2, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    if (c.sqlite3_changes(self.db) != 1) {
        var exists: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT EXISTS(SELECT 1 FROM users WHERE id=?1 AND id!=3),EXISTS(SELECT 1 FROM users WHERE email=?2 AND id!=?1)", -1, &exists, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(exists);
        _ = c.sqlite3_bind_int(exists, 1, user_id);
        _ = c.sqlite3_bind_text(exists, 2, email.ptr, @intCast(email.len), null);
        if (c.sqlite3_step(exists) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        if (c.sqlite3_column_int(exists, 0) == 0) return error.UserNotFound;
        if (c.sqlite3_column_int(exists, 1) != 0) return error.EmailExists;
    }
    try self.insertAuditLocked(user_id, "account.email", user_id, "email changed");
    try self.exec("COMMIT");
}

pub fn updateAccountPassword(self: *Store, user_id: i32, password_md5: []const u8) !void {
    var hash_buffer: [256]u8 = undefined;
    const hash = try std.crypto.pwhash.argon2.strHash(password_md5, .{ .allocator = self.allocator, .params = .owasp_2id }, &hash_buffer, self.io);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE users SET password_hash=?1,password_salt='argon2id' WHERE id=?2 AND id!=3", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_blob(stmt, 1, hash.ptr, @intCast(hash.len), null);
    _ = c.sqlite3_bind_int(stmt, 2, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.UserNotFound;
    try self.insertAuditLocked(user_id, "account.password", user_id, "password changed");
    var revoke: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE oauth_tokens SET revoked_at=unixepoch() WHERE user_id=?1 AND revoked_at IS NULL", -1, &revoke, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(revoke);
    _ = c.sqlite3_bind_int(revoke, 1, user_id);
    if (c.sqlite3_step(revoke) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    var clear: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "DELETE FROM lazer_presence WHERE user_id=?1", -1, &clear, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(clear);
    _ = c.sqlite3_bind_int(clear, 1, user_id);
    if (c.sqlite3_step(clear) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    try self.exec("COMMIT");
}

pub fn updateAccountUsername(self: *Store, user_id: i32, new_name: []const u8) !void {
    const safe = try domain.safeName(self.allocator, new_name);
    defer self.allocator.free(safe);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var current: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT name,username_changes,privileges FROM users WHERE id=?1 AND id!=3", -1, &current, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(current);
    _ = c.sqlite3_bind_int(current, 1, user_id);
    if (c.sqlite3_step(current) != c.SQLITE_ROW) return error.UserNotFound;
    const old_name = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(current, 0)));
    defer self.allocator.free(old_name);
    const changes = c.sqlite3_column_int(current, 1);
    const privileges: u32 = @intCast(c.sqlite3_column_int64(current, 2));
    if (changes != 0 and privileges & (1 << 5) == 0) return error.PremiumRequired;
    var update: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE users SET name=?1,safe_name=?2,username_changes=username_changes+1,username_changed_at=unixepoch() WHERE id=?3 AND NOT EXISTS(SELECT 1 FROM users other WHERE other.safe_name=?2 AND other.id!=?3)", -1, &update, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(update);
    _ = c.sqlite3_bind_text(update, 1, new_name.ptr, @intCast(new_name.len), null);
    _ = c.sqlite3_bind_text(update, 2, safe.ptr, @intCast(safe.len), null);
    _ = c.sqlite3_bind_int(update, 3, user_id);
    if (c.sqlite3_step(update) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    if (c.sqlite3_changes(self.db) != 1) return error.UsernameExists;
    var history: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO user_name_changes(user_id,old_name,new_name) VALUES(?1,?2,?3)", -1, &history, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(history);
    _ = c.sqlite3_bind_int(history, 1, user_id);
    _ = c.sqlite3_bind_text(history, 2, old_name.ptr, @intCast(old_name.len), null);
    _ = c.sqlite3_bind_text(history, 3, new_name.ptr, @intCast(new_name.len), null);
    if (c.sqlite3_step(history) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    try self.insertAuditLocked(user_id, "account.username", user_id, "username changed");
    var revoke: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE oauth_tokens SET revoked_at=unixepoch() WHERE user_id=?1 AND revoked_at IS NULL", -1, &revoke, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(revoke);
    _ = c.sqlite3_bind_int(revoke, 1, user_id);
    if (c.sqlite3_step(revoke) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    var clear: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "DELETE FROM lazer_presence WHERE user_id=?1", -1, &clear, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(clear);
    _ = c.sqlite3_bind_int(clear, 1, user_id);
    if (c.sqlite3_step(clear) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    try self.exec("COMMIT");
}

pub fn revokeAllTokensForUser(self: *Store, user_id: i32) !usize {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE oauth_tokens SET revoked_at=unixepoch() WHERE user_id=?1 AND revoked_at IS NULL", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer if (stmt) |value| {
        _ = c.sqlite3_finalize(value);
    };
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    const revoked: usize = @intCast(c.sqlite3_changes(self.db));
    _ = c.sqlite3_finalize(stmt);
    stmt = null;
    var clear: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "DELETE FROM lazer_presence WHERE user_id=?1", -1, &clear, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(clear);
    _ = c.sqlite3_bind_int(clear, 1, user_id);
    if (c.sqlite3_step(clear) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    try self.exec("COMMIT");
    return revoked;
}

pub fn authenticate(self: *Store, allocator: std.mem.Allocator, name: []const u8, password_md5: []const u8) !?domain.User {
    const safe = try domain.safeName(allocator, name);
    defer allocator.free(safe);
    var credential = blk: {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        break :blk (try self.credentialForSafeName(allocator, safe)) orelse return null;
    };
    defer credential.deinit();
    var upgrade_password = false;
    if (credential.password_hash.len > 0 and credential.password_hash[0] == '$') {
        std.crypto.pwhash.argon2.strVerify(credential.password_hash, password_md5, .{ .allocator = allocator }, self.io) catch return null;
    } else {
        var actual: [32]u8 = undefined;
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(credential.password_salt);
        h.update(password_md5);
        h.final(&actual);
        if (credential.password_hash.len != 32 or !std.crypto.timing_safe.eql([32]u8, actual, credential.password_hash[0..32].*)) return null;
        upgrade_password = true;
    }
    const user_id = credential.user.?.id;
    if (upgrade_password) try self.upgradePassword(user_id, password_md5, credential.password_hash);
    return credential.takeUser();
}

pub fn credentialForSafeName(self: *Store, allocator: std.mem.Allocator, safe: []const u8) !?Credential {
    const sql = "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0),u.show_country," ++ visible_follower_count_sql ++ ",u.password_hash,u.password_salt FROM users u LEFT JOIN team_members tm ON tm.user_id=u.id LEFT JOIN teams t ON t.id=tm.team_id WHERE u.safe_name=?1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, safe.ptr, @intCast(safe.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const uname = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
    errdefer allocator.free(uname);
    const usafe = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)));
    errdefer allocator.free(usafe);
    const cc = std.mem.span(c.sqlite3_column_text(stmt, 3));
    if (cc.len != 2) return error.InvalidCountry;
    const expected: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 14));
    const expected_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 14));
    const expected_copy = try allocator.dupe(u8, expected[0..expected_len]);
    errdefer allocator.free(expected_copy);
    const salt: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 15));
    const salt_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 15));
    const salt_copy = try allocator.dupe(u8, salt[0..salt_len]);
    const team: ?domain.TeamSummary = if (c.sqlite3_column_type(stmt, 8) == c.SQLITE_NULL) null else try domain.TeamSummary.init(c.sqlite3_column_int(stmt, 8), std.mem.span(c.sqlite3_column_text(stmt, 9)), std.mem.span(c.sqlite3_column_text(stmt, 10)), c.sqlite3_column_int64(stmt, 11));
    return .{
        .allocator = allocator,
        .user = .{ .id = c.sqlite3_column_int(stmt, 0), .name = uname, .safe_name = usafe, .country = .{ cc[0], cc[1] }, .show_country = c.sqlite3_column_int(stmt, 12) != 0, .privileges = @intCast(c.sqlite3_column_int64(stmt, 4)), .silence_end = c.sqlite3_column_int64(stmt, 5), .restricted = c.sqlite3_column_int(stmt, 6) != 0, .follower_count = c.sqlite3_column_int(stmt, 13), .banner_version = c.sqlite3_column_int64(stmt, 7), .team = team },
        .password_hash = expected_copy,
        .password_salt = salt_copy,
    };
}

pub fn userById(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?domain.User {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0),u.show_country," ++ visible_follower_count_sql ++ " FROM users u LEFT JOIN team_members tm ON tm.user_id=u.id LEFT JOIN teams t ON t.id=tm.team_id WHERE u.id=?1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const name = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
    errdefer allocator.free(name);
    const safe = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)));
    const cc = std.mem.span(c.sqlite3_column_text(stmt, 3));
    const team: ?domain.TeamSummary = if (c.sqlite3_column_type(stmt, 8) == c.SQLITE_NULL) null else try domain.TeamSummary.init(c.sqlite3_column_int(stmt, 8), std.mem.span(c.sqlite3_column_text(stmt, 9)), std.mem.span(c.sqlite3_column_text(stmt, 10)), c.sqlite3_column_int64(stmt, 11));
    return .{
        .id = c.sqlite3_column_int(stmt, 0),
        .name = name,
        .safe_name = safe,
        .country = .{ cc[0], cc[1] },
        .show_country = c.sqlite3_column_int(stmt, 12) != 0,
        .privileges = @intCast(c.sqlite3_column_int64(stmt, 4)),
        .silence_end = c.sqlite3_column_int64(stmt, 5),
        .restricted = c.sqlite3_column_int(stmt, 6) != 0,
        .follower_count = c.sqlite3_column_int(stmt, 13),
        .banner_version = c.sqlite3_column_int64(stmt, 7),
        .team = team,
    };
}

pub fn userByName(self: *Store, allocator: std.mem.Allocator, name: []const u8) !?domain.User {
    const safe = try domain.safeName(allocator, name);
    defer allocator.free(safe);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0),u.show_country," ++ visible_follower_count_sql ++ " FROM users u LEFT JOIN team_members tm ON tm.user_id=u.id LEFT JOIN teams t ON t.id=tm.team_id WHERE u.safe_name=?1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, safe.ptr, @intCast(safe.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const user_name = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
    errdefer allocator.free(user_name);
    const safe_name = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)));
    const cc = std.mem.span(c.sqlite3_column_text(stmt, 3));
    if (cc.len != 2) return error.InvalidCountry;
    const team: ?domain.TeamSummary = if (c.sqlite3_column_type(stmt, 8) == c.SQLITE_NULL) null else try domain.TeamSummary.init(c.sqlite3_column_int(stmt, 8), std.mem.span(c.sqlite3_column_text(stmt, 9)), std.mem.span(c.sqlite3_column_text(stmt, 10)), c.sqlite3_column_int64(stmt, 11));
    return .{
        .id = c.sqlite3_column_int(stmt, 0),
        .name = user_name,
        .safe_name = safe_name,
        .country = .{ cc[0], cc[1] },
        .show_country = c.sqlite3_column_int(stmt, 12) != 0,
        .privileges = @intCast(c.sqlite3_column_int64(stmt, 4)),
        .silence_end = c.sqlite3_column_int64(stmt, 5),
        .restricted = c.sqlite3_column_int(stmt, 6) != 0,
        .follower_count = c.sqlite3_column_int(stmt, 13),
        .banner_version = c.sqlite3_column_int64(stmt, 7),
        .team = team,
    };
}

pub const Credential = struct {
    allocator: std.mem.Allocator,
    user: ?domain.User,
    password_hash: []u8,
    password_salt: []u8,

    pub fn deinit(self: *Credential) void {
        if (self.user) |user| {
            self.allocator.free(user.name);
            self.allocator.free(user.safe_name);
        }
        self.allocator.free(self.password_hash);
        self.allocator.free(self.password_salt);
        self.* = undefined;
    }

    pub fn takeUser(self: *Credential) domain.User {
        const user = self.user.?;
        self.user = null;
        return user;
    }
};
