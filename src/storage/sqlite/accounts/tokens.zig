const std = @import("std");
const domain = @import("../../../domain.zig");
const visible_follower_count_sql = @import("../../../storage.zig").visible_follower_count_sql;
const c = @import("../../../storage.zig").c;
const hasOauthScope = @import("../../../storage.zig").hasOauthScope;
const hasGameAccessScopes = @import("../../../storage.zig").hasGameAccessScopes;
const randomOauthToken = @import("../../../storage.zig").randomOauthToken;
const randomOauthClientId = @import("../../../storage.zig").randomOauthClientId;
const Store = @import("../../../storage.zig").Store;
const GameTokenPair = @import("../../contracts.zig").GameTokenPair;
const GameTokenRefresh = @import("../../contracts.zig").GameTokenRefresh;

pub fn upgradePassword(self: *Store, user_id: i32, password_md5: []const u8, previous_hash: []const u8) !void {
    var hash_buffer: [256]u8 = undefined;
    const hash = try std.crypto.pwhash.argon2.strHash(password_md5, .{ .allocator = self.allocator, .params = .owasp_2id }, &hash_buffer, self.io);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = "UPDATE users SET password_hash=?1,password_salt='argon2id' WHERE id=?2 AND password_hash=?3";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_blob(stmt, 1, hash.ptr, @intCast(hash.len), null);
    _ = c.sqlite3_bind_int(stmt, 2, user_id);
    _ = c.sqlite3_bind_blob(stmt, 3, previous_hash.ptr, @intCast(previous_hash.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn issueToken(self: *Store, user_id: i32, scopes: []const u8, lifetime_seconds: i64) ![64]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var raw: [32]u8 = undefined;
    try std.Io.randomSecure(self.io, &raw);
    var token: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&token, "{x}", .{raw}) catch unreachable;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&token, &digest, .{});
    const now = std.Io.Clock.real.now(self.io).toSeconds();
    const game_client = std.mem.indexOf(u8, scopes, "scores:write") != null;
    const sql = "INSERT INTO oauth_tokens(token_hash,user_id,scopes,expires_at,last_used_at) VALUES(?1,?2,?3,?4,?5)";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_blob(stmt, 1, &digest, digest.len, null);
    _ = c.sqlite3_bind_int(stmt, 2, user_id);
    _ = c.sqlite3_bind_text(stmt, 3, scopes.ptr, @intCast(scopes.len), null);
    _ = c.sqlite3_bind_int64(stmt, 4, now + lifetime_seconds);
    if (game_client) _ = c.sqlite3_bind_int64(stmt, 5, now) else _ = c.sqlite3_bind_null(stmt, 5);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return token;
}

pub fn insertGameTokenLocked(self: *Store, token: *const [64]u8, user_id: i32, scopes: []const u8, expires_at: i64, client_id: i32, last_used_at: ?i64) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "INSERT INTO oauth_tokens(token_hash,user_id,scopes,client_id,expires_at,last_used_at) VALUES(?1,?2,?3,?4,?5,?6)";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_blob(stmt, 1, &digest, digest.len, null);
    _ = c.sqlite3_bind_int(stmt, 2, user_id);
    _ = c.sqlite3_bind_text(stmt, 3, scopes.ptr, @intCast(scopes.len), null);
    _ = c.sqlite3_bind_int64(stmt, 4, client_id);
    _ = c.sqlite3_bind_int64(stmt, 5, expires_at);
    if (last_used_at) |value| _ = c.sqlite3_bind_int64(stmt, 6, value) else _ = c.sqlite3_bind_null(stmt, 6);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn issueGameTokenPair(self: *Store, user_id: i32, access_lifetime_seconds: i64, refresh_lifetime_seconds: i64, replace_existing: bool) !GameTokenPair {
    if (user_id <= 0 or access_lifetime_seconds <= 0 or refresh_lifetime_seconds <= 0) return error.InvalidOauthTokenPair;
    const access = try randomOauthToken(self.io);
    const refresh = try randomOauthToken(self.io);
    const client_id = try randomOauthClientId(self.io);
    const now = std.Io.Clock.real.now(self.io).toSeconds();
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    if (replace_existing) {
        var revoke: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE oauth_tokens SET revoked_at=unixepoch() WHERE user_id=?1 AND revoked_at IS NULL AND ((instr(' '||scopes||' ',' identify ')>0 AND instr(' '||scopes||' ',' scores:write ')>0) OR instr(' '||scopes||' ',' game:refresh ')>0)", -1, &revoke, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(revoke);
        _ = c.sqlite3_bind_int(revoke, 1, user_id);
        if (c.sqlite3_step(revoke) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        var clear: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM lazer_presence WHERE user_id=?1", -1, &clear, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(clear);
        _ = c.sqlite3_bind_int(clear, 1, user_id);
        if (c.sqlite3_step(clear) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }
    try self.insertGameTokenLocked(&access, user_id, "identify scores:write", now + access_lifetime_seconds, client_id, now);
    try self.insertGameTokenLocked(&refresh, user_id, "game:refresh", now + refresh_lifetime_seconds, client_id, null);
    try self.exec("COMMIT");
    return .{ .access = access, .refresh = refresh };
}

pub fn rotateGameTokenPair(self: *Store, allocator: std.mem.Allocator, refresh_token: []const u8, access_lifetime_seconds: i64, refresh_lifetime_seconds: i64) !?GameTokenRefresh {
    if (refresh_token.len != 64 or access_lifetime_seconds <= 0 or refresh_lifetime_seconds <= 0) return null;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(refresh_token, &digest, .{});
    const access = try randomOauthToken(self.io);
    const refresh = try randomOauthToken(self.io);
    const new_client_id = try randomOauthClientId(self.io);
    const now = std.Io.Clock.real.now(self.io).toSeconds();
    const user_id: i32 = rotate: {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        var consume: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE oauth_tokens SET revoked_at=unixepoch() WHERE token_hash=?1 AND scopes='game:refresh' AND revoked_at IS NULL AND expires_at>unixepoch() RETURNING user_id,client_id", -1, &consume, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer {
            if (consume) |stmt| _ = c.sqlite3_finalize(stmt);
        }
        _ = c.sqlite3_bind_blob(consume, 1, &digest, digest.len, null);
        if (c.sqlite3_step(consume) != c.SQLITE_ROW) {
            try self.exec("ROLLBACK");
            return null;
        }
        const id = c.sqlite3_column_int(consume, 0);
        const legacy = c.sqlite3_column_type(consume, 1) == c.SQLITE_NULL;
        const old_client_id = if (legacy) @as(i64, 0) else c.sqlite3_column_int64(consume, 1);
        _ = c.sqlite3_finalize(consume);
        consume = null;
        var revoke: ?*c.sqlite3_stmt = null;
        const revoke_sql = if (legacy)
            "UPDATE oauth_tokens SET revoked_at=unixepoch() WHERE user_id=?1 AND client_id IS NULL AND revoked_at IS NULL AND instr(' '||scopes||' ',' identify ')>0 AND instr(' '||scopes||' ',' scores:write ')>0"
        else
            "UPDATE oauth_tokens SET revoked_at=unixepoch() WHERE user_id=?1 AND client_id=?2 AND revoked_at IS NULL AND instr(' '||scopes||' ',' identify ')>0 AND instr(' '||scopes||' ',' scores:write ')>0";
        if (c.sqlite3_prepare_v2(self.db, revoke_sql, -1, &revoke, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(revoke);
        _ = c.sqlite3_bind_int(revoke, 1, id);
        if (!legacy) _ = c.sqlite3_bind_int64(revoke, 2, old_client_id);
        if (c.sqlite3_step(revoke) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        try self.insertGameTokenLocked(&access, id, "identify scores:write", now + access_lifetime_seconds, new_client_id, now);
        try self.insertGameTokenLocked(&refresh, id, "game:refresh", now + refresh_lifetime_seconds, new_client_id, null);
        try self.exec("COMMIT");
        break :rotate id;
    };
    const user = (try self.userById(allocator, user_id)) orelse return error.UserNotFound;
    return .{ .user = user, .tokens = .{ .access = access, .refresh = refresh } };
}

pub fn authenticateToken(self: *Store, allocator: std.mem.Allocator, token: []const u8, required_scope: []const u8) !?domain.User {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (token.len != 64) return null;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    const sql = "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,team.name,team.short_name,coalesce((SELECT updated_at FROM team_assets ta WHERE ta.team_id=team.id AND ta.kind='flag'),0),u.show_country," ++ visible_follower_count_sql ++ ",t.scopes FROM oauth_tokens t JOIN users u ON u.id=t.user_id LEFT JOIN team_members tm ON tm.user_id=u.id LEFT JOIN teams team ON team.id=tm.team_id WHERE t.token_hash=?1 AND t.revoked_at IS NULL AND t.expires_at>?2";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_blob(stmt, 1, &digest, digest.len, null);
    _ = c.sqlite3_bind_int64(stmt, 2, std.Io.Clock.real.now(self.io).toSeconds());
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const scopes = std.mem.span(c.sqlite3_column_text(stmt, 14));
    var allowed = required_scope.len == 0;
    var it = std.mem.splitScalar(u8, scopes, ' ');
    while (it.next()) |scope| {
        if (std.mem.eql(u8, scope, required_scope) or std.mem.eql(u8, scope, "*")) {
            allowed = true;
            break;
        }
    }
    if (!allowed) return null;
    const user_id = c.sqlite3_column_int(stmt, 0);
    const name = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
    errdefer allocator.free(name);
    const safe = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)));
    errdefer allocator.free(safe);
    const cc = std.mem.span(c.sqlite3_column_text(stmt, 3));
    const team: ?domain.TeamSummary = if (c.sqlite3_column_type(stmt, 8) == c.SQLITE_NULL) null else try domain.TeamSummary.init(c.sqlite3_column_int(stmt, 8), std.mem.span(c.sqlite3_column_text(stmt, 9)), std.mem.span(c.sqlite3_column_text(stmt, 10)), c.sqlite3_column_int64(stmt, 11));
    const user: domain.User = .{ .id = user_id, .name = name, .safe_name = safe, .country = .{ cc[0], cc[1] }, .show_country = c.sqlite3_column_int(stmt, 12) != 0, .privileges = @intCast(c.sqlite3_column_int64(stmt, 4)), .silence_end = c.sqlite3_column_int64(stmt, 5), .restricted = c.sqlite3_column_int(stmt, 6) != 0, .follower_count = c.sqlite3_column_int(stmt, 13), .banner_version = c.sqlite3_column_int64(stmt, 7), .team = team };
    _ = c.sqlite3_finalize(stmt);
    stmt = null;
    const now = std.Io.Clock.real.now(self.io).toSeconds();
    var touch: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE oauth_tokens SET last_used_at=?1 WHERE token_hash=?2 AND (last_used_at IS NULL OR last_used_at<?3)", -1, &touch, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(touch);
    _ = c.sqlite3_bind_int64(touch, 1, now);
    _ = c.sqlite3_bind_blob(touch, 2, &digest, digest.len, null);
    _ = c.sqlite3_bind_int64(touch, 3, now - 30);
    if (c.sqlite3_step(touch) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return user;
}

pub fn consumeGameRefreshToken(self: *Store, allocator: std.mem.Allocator, token: []const u8) !?domain.User {
    if (token.len != 64) return null;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    const user_id: i32 = consume: {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "UPDATE oauth_tokens SET revoked_at=unixepoch() WHERE token_hash=?1 AND scopes='game:refresh' AND revoked_at IS NULL AND expires_at>unixepoch() RETURNING user_id";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_blob(stmt, 1, &digest, digest.len, null);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        break :consume c.sqlite3_column_int(stmt, 0);
    };
    return self.userById(allocator, user_id);
}

pub fn revokeToken(self: *Store, token: []const u8) !bool {
    if (token.len != 64) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var current: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT user_id,scopes,client_id FROM oauth_tokens WHERE token_hash=?1 AND revoked_at IS NULL", -1, &current, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_blob(current, 1, &digest, digest.len, null);
    if (c.sqlite3_step(current) != c.SQLITE_ROW) {
        _ = c.sqlite3_finalize(current);
        try self.exec("ROLLBACK");
        return false;
    }
    const user_id = c.sqlite3_column_int(current, 0);
    const scopes = std.mem.span(c.sqlite3_column_text(current, 1));
    const game_session = hasGameAccessScopes(scopes) or hasOauthScope(scopes, "game:refresh");
    const legacy_game_session = game_session and c.sqlite3_column_type(current, 2) == c.SQLITE_NULL;
    const client_id = if (legacy_game_session or !game_session) @as(i64, 0) else c.sqlite3_column_int64(current, 2);
    _ = c.sqlite3_finalize(current);
    const sql = if (game_session)
        if (legacy_game_session)
            "UPDATE oauth_tokens SET revoked_at=unixepoch() WHERE user_id=?1 AND client_id IS NULL AND revoked_at IS NULL AND ((instr(' '||scopes||' ',' identify ')>0 AND instr(' '||scopes||' ',' scores:write ')>0) OR instr(' '||scopes||' ',' game:refresh ')>0)"
        else
            "UPDATE oauth_tokens SET revoked_at=unixepoch() WHERE user_id=?1 AND client_id=?2 AND revoked_at IS NULL AND ((instr(' '||scopes||' ',' identify ')>0 AND instr(' '||scopes||' ',' scores:write ')>0) OR instr(' '||scopes||' ',' game:refresh ')>0)"
    else
        "UPDATE oauth_tokens SET revoked_at=unixepoch() WHERE token_hash=?1 AND revoked_at IS NULL";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer if (stmt) |value| {
        _ = c.sqlite3_finalize(value);
    };
    if (game_session) {
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        if (!legacy_game_session) _ = c.sqlite3_bind_int64(stmt, 2, client_id);
    } else {
        _ = c.sqlite3_bind_blob(stmt, 1, &digest, digest.len, null);
    }
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    const revoked = c.sqlite3_changes(self.db) > 0;
    _ = c.sqlite3_finalize(stmt);
    stmt = null;
    if (game_session and revoked) {
        var clear: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM lazer_presence WHERE user_id=?1 AND NOT EXISTS(SELECT 1 FROM oauth_tokens WHERE user_id=?1 AND revoked_at IS NULL AND expires_at>unixepoch() AND instr(' '||scopes||' ',' identify ')>0 AND instr(' '||scopes||' ',' scores:write ')>0)", -1, &clear, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(clear);
        _ = c.sqlite3_bind_int(clear, 1, user_id);
        if (c.sqlite3_step(clear) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }
    try self.exec("COMMIT");
    return revoked;
}

pub fn revokeGameTokensForUser(self: *Store, user_id: i32) !usize {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "UPDATE oauth_tokens SET revoked_at=unixepoch() WHERE user_id=?1 AND revoked_at IS NULL AND expires_at>unixepoch() AND ((instr(' '||scopes||' ',' identify ')>0 AND instr(' '||scopes||' ',' scores:write ')>0) OR instr(' '||scopes||' ',' game:refresh ')>0)";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
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

pub fn revokeLazerAccessTokensForUser(self: *Store, user_id: i32) !usize {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "UPDATE oauth_tokens SET revoked_at=unixepoch() WHERE user_id=?1 AND revoked_at IS NULL AND instr(' '||scopes||' ',' identify ')>0 AND instr(' '||scopes||' ',' scores:write ')>0";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
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
