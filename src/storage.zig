const std = @import("std");
const domain = @import("domain.zig");
const stable_score = @import("stable_score.zig");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Store = struct {
    db: *c.sqlite3,
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: [:0]const u8) !Store {
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path.ptr, &db) != c.SQLITE_OK) return error.DatabaseOpenFailed;
        return .{ .db = db.?, .allocator = allocator, .io = io };
    }
    pub fn close(self: *Store) void {
        _ = c.sqlite3_close(self.db);
    }
    pub fn exec(self: *Store, sql: [:0]const u8) !void {
        var err: [*c]u8 = null;
        if (c.sqlite3_exec(self.db, sql.ptr, null, null, &err) != c.SQLITE_OK) {
            if (err != null) c.sqlite3_free(err);
            return error.DatabaseQueryFailed;
        }
    }
    pub fn migrate(self: *Store) !void {
        try self.exec(@embedFile("schema.sql"));
        var version: i32 = 0;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "PRAGMA user_version", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) version = c.sqlite3_column_int(stmt, 0);
        _ = c.sqlite3_finalize(stmt);
        if (version < 2) try self.exec(@embedFile("migration_002.sql"));
        if (version < 3) try self.exec(@embedFile("migration_003.sql"));
    }

    pub fn register(self: *Store, name: []const u8, email: []const u8, password_md5: []const u8) !i32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const safe = try domain.safeName(self.allocator, name);
        defer self.allocator.free(safe);
        var hash_buffer: [256]u8 = undefined;
        const hash = try std.crypto.pwhash.argon2.strHash(password_md5, .{
            .allocator = self.allocator,
            .params = .owasp_2id,
        }, &hash_buffer, self.io);
        const sql = "INSERT INTO users(name,safe_name,email,password_hash,password_salt) VALUES(?1,?2,?3,?4,?5)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), null);
        _ = c.sqlite3_bind_text(stmt, 2, safe.ptr, @intCast(safe.len), null);
        _ = c.sqlite3_bind_text(stmt, 3, email.ptr, @intCast(email.len), null);
        _ = c.sqlite3_bind_blob(stmt, 4, hash.ptr, @intCast(hash.len), null);
        _ = c.sqlite3_bind_blob(stmt, 5, "argon2id".ptr, 8, null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.UserExists;
        const id: i32 = @intCast(c.sqlite3_last_insert_rowid(self.db));
        var mode: u8 = 0;
        while (mode < 4) : (mode += 1) {
            var buf: [128]u8 = undefined;
            const q = std.fmt.bufPrintZ(&buf, "INSERT INTO stats(user_id,mode) VALUES({d},{d})", .{ id, mode }) catch return error.DatabaseQueryFailed;
            try self.exec(q);
        }
        return id;
    }

    pub fn authenticate(self: *Store, allocator: std.mem.Allocator, name: []const u8, password_md5: []const u8) !?domain.User {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const safe = try domain.safeName(allocator, name);
        defer allocator.free(safe);
        const sql = "SELECT id,name,safe_name,country,privileges,silence_end,restricted,password_hash,password_salt FROM users WHERE safe_name=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, safe.ptr, @intCast(safe.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const expected: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 7));
        const expected_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 7));
        var upgrade_password = false;
        if (expected_len > 0 and expected[0] == '$') {
            std.crypto.pwhash.argon2.strVerify(expected[0..expected_len], password_md5, .{ .allocator = allocator }, self.io) catch return null;
        } else {
            // One-time compatibility path for databases created before Argon2id storage.
            const salt: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 8));
            const salt_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 8));
            var actual: [32]u8 = undefined;
            var h = std.crypto.hash.sha2.Sha256.init(.{});
            h.update(salt[0..salt_len]);
            h.update(password_md5);
            h.final(&actual);
            if (expected_len != 32 or !std.crypto.timing_safe.eql([32]u8, actual, expected[0..32].*)) return null;
            upgrade_password = true;
        }
        const uname = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
        const usafe = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)));
        const cc = std.mem.span(c.sqlite3_column_text(stmt, 3));
        const user: domain.User = .{ .id = c.sqlite3_column_int(stmt, 0), .name = uname, .safe_name = usafe, .country = .{ cc[0], cc[1] }, .privileges = @intCast(c.sqlite3_column_int64(stmt, 4)), .silence_end = c.sqlite3_column_int64(stmt, 5), .restricted = c.sqlite3_column_int(stmt, 6) != 0 };
        if (upgrade_password) try self.upgradePassword(user.id, password_md5);
        return user;
    }

    fn upgradePassword(self: *Store, user_id: i32, password_md5: []const u8) !void {
        var hash_buffer: [256]u8 = undefined;
        const hash = try std.crypto.pwhash.argon2.strHash(password_md5, .{ .allocator = self.allocator, .params = .owasp_2id }, &hash_buffer, self.io);
        const sql = "UPDATE users SET password_hash=?1,password_salt='argon2id' WHERE id=?2";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_blob(stmt, 1, hash.ptr, @intCast(hash.len), null);
        _ = c.sqlite3_bind_int(stmt, 2, user_id);
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
        const sql = "INSERT INTO oauth_tokens(token_hash,user_id,scopes,expires_at) VALUES(?1,?2,?3,?4)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_blob(stmt, 1, &digest, digest.len, null);
        _ = c.sqlite3_bind_int(stmt, 2, user_id);
        _ = c.sqlite3_bind_text(stmt, 3, scopes.ptr, @intCast(scopes.len), null);
        _ = c.sqlite3_bind_int64(stmt, 4, now + lifetime_seconds);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        return token;
    }

    pub fn authenticateToken(self: *Store, allocator: std.mem.Allocator, token: []const u8, required_scope: []const u8) !?domain.User {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (token.len != 64) return null;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
        const sql = "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,t.scopes FROM oauth_tokens t JOIN users u ON u.id=t.user_id WHERE t.token_hash=?1 AND t.revoked_at IS NULL AND t.expires_at>?2";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_blob(stmt, 1, &digest, digest.len, null);
        _ = c.sqlite3_bind_int64(stmt, 2, std.Io.Clock.real.now(self.io).toSeconds());
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const scopes = std.mem.span(c.sqlite3_column_text(stmt, 7));
        var allowed = required_scope.len == 0;
        var it = std.mem.splitScalar(u8, scopes, ' ');
        while (it.next()) |scope| {
            if (std.mem.eql(u8, scope, required_scope) or std.mem.eql(u8, scope, "*")) {
                allowed = true;
                break;
            }
        }
        if (!allowed) return null;
        const name = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
        errdefer allocator.free(name);
        const safe = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)));
        const cc = std.mem.span(c.sqlite3_column_text(stmt, 3));
        return .{ .id = c.sqlite3_column_int(stmt, 0), .name = name, .safe_name = safe, .country = .{ cc[0], cc[1] }, .privileges = @intCast(c.sqlite3_column_int64(stmt, 4)), .silence_end = c.sqlite3_column_int64(stmt, 5), .restricted = c.sqlite3_column_int(stmt, 6) != 0 };
    }

    pub fn revokeToken(self: *Store, token: []const u8) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (token.len != 64) return false;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
        const sql = "UPDATE oauth_tokens SET revoked_at=unixepoch() WHERE token_hash=?1 AND revoked_at IS NULL";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_blob(stmt, 1, &digest, digest.len, null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        return c.sqlite3_changes(self.db) > 0;
    }

    pub fn insertLazerScore(self: *Store, user_id: i32, value: std.json.Value, raw_json: []const u8, namespace: []const u8) !i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const o = value.object;
        const beatmap = o.get("beatmap_id").?.integer;
        const ruleset = if (o.get("ruleset_id")) |v| v.integer else 0;
        const total = o.get("total_score").?.integer;
        const legacy: ?i64 = if (o.get("legacy_total_score")) |v| switch (v) {
            .integer => |n| n,
            else => null,
        } else null;
        const acc: f64 = if (o.get("accuracy")) |v| switch (v) {
            .float => |n| n,
            .integer => |n| @floatFromInt(n),
            else => 0,
        } else 0;
        const combo: i64 = if (o.get("max_combo")) |v| v.integer else 0;
        const passed: bool = if (o.get("passed")) |v| v.bool else false;
        const sql = "INSERT INTO lazer_scores(user_id,beatmap_id,ruleset_id,total_score,legacy_total_score,accuracy,max_combo,passed,mods_json,statistics_json,rank_namespace,client_version) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_int64(stmt, 2, beatmap);
        _ = c.sqlite3_bind_int64(stmt, 3, ruleset);
        _ = c.sqlite3_bind_int64(stmt, 4, total);
        if (legacy) |n| _ = c.sqlite3_bind_int64(stmt, 5, n) else _ = c.sqlite3_bind_null(stmt, 5);
        _ = c.sqlite3_bind_double(stmt, 6, acc);
        _ = c.sqlite3_bind_int64(stmt, 7, combo);
        _ = c.sqlite3_bind_int(stmt, 8, @intFromBool(passed));
        _ = c.sqlite3_bind_text(stmt, 9, raw_json.ptr, @intCast(raw_json.len), null);
        _ = c.sqlite3_bind_text(stmt, 10, raw_json.ptr, @intCast(raw_json.len), null);
        _ = c.sqlite3_bind_text(stmt, 11, namespace.ptr, @intCast(namespace.len), null);
        if (o.get("client_version")) |v| switch (v) {
            .string => |s| {
                _ = c.sqlite3_bind_text(stmt, 12, s.ptr, @intCast(s.len), null);
            },
            else => {
                _ = c.sqlite3_bind_null(stmt, 12);
            },
        } else _ = c.sqlite3_bind_null(stmt, 12);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        return c.sqlite3_last_insert_rowid(self.db);
    }

    pub const BeatmapForScore = struct { id: i32, set_id: i32, status: i8, plays: i32, passes: i32 };

    pub fn beatmapForScore(self: *Store, md5: []const u8) !?BeatmapForScore {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "SELECT id,set_id,status,plays,passes FROM beatmaps WHERE md5=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, md5.ptr, @intCast(md5.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return .{ .id = c.sqlite3_column_int(stmt, 0), .set_id = c.sqlite3_column_int(stmt, 1), .status = @intCast(c.sqlite3_column_int(stmt, 2)), .plays = c.sqlite3_column_int(stmt, 3), .passes = c.sqlite3_column_int(stmt, 4) };
    }

    pub fn insertStableScore(self: *Store, user_id: i32, score: stable_score.Submission, replay_data: []const u8) !i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        const sql = "INSERT INTO scores(user_id,map_md5,mode,mods,score,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,checksum) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_text(stmt, 2, score.map_md5.ptr, @intCast(score.map_md5.len), null);
        _ = c.sqlite3_bind_int(stmt, 3, score.mode);
        _ = c.sqlite3_bind_int(stmt, 4, score.mods);
        _ = c.sqlite3_bind_int64(stmt, 5, score.total_score);
        _ = c.sqlite3_bind_double(stmt, 6, score.accuracy());
        _ = c.sqlite3_bind_int(stmt, 7, score.max_combo);
        _ = c.sqlite3_bind_int(stmt, 8, score.n300);
        _ = c.sqlite3_bind_int(stmt, 9, score.n100);
        _ = c.sqlite3_bind_int(stmt, 10, score.n50);
        _ = c.sqlite3_bind_int(stmt, 11, score.nmiss);
        _ = c.sqlite3_bind_int(stmt, 12, score.ngeki);
        _ = c.sqlite3_bind_int(stmt, 13, score.nkatu);
        _ = c.sqlite3_bind_int(stmt, 14, @intFromBool(score.perfect));
        _ = c.sqlite3_bind_int(stmt, 15, @intFromBool(score.passed));
        _ = c.sqlite3_bind_blob(stmt, 16, replay_data.ptr, @intCast(replay_data.len), null);
        _ = c.sqlite3_bind_text(stmt, 17, score.online_checksum.ptr, @intCast(score.online_checksum.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return if (c.sqlite3_extended_errcode(self.db) == c.SQLITE_CONSTRAINT_UNIQUE) error.DuplicateScore else error.DatabaseQueryFailed;
        const id = c.sqlite3_last_insert_rowid(self.db);
        const update_stats = "UPDATE stats SET total_score=total_score+?1,plays=plays+1,accuracy=((accuracy*plays)+?2)/(plays+1),max_combo=max(max_combo,?3) WHERE user_id=?4 AND mode=?5";
        var stats_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, update_stats, -1, &stats_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stats_stmt);
        _ = c.sqlite3_bind_int64(stats_stmt, 1, score.total_score);
        _ = c.sqlite3_bind_double(stats_stmt, 2, score.accuracy());
        _ = c.sqlite3_bind_int(stats_stmt, 3, score.max_combo);
        _ = c.sqlite3_bind_int(stats_stmt, 4, user_id);
        _ = c.sqlite3_bind_int(stats_stmt, 5, score.mode);
        if (c.sqlite3_step(stats_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        const update_map = "UPDATE beatmaps SET plays=plays+1,passes=passes+?1 WHERE md5=?2";
        var map_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, update_map, -1, &map_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(map_stmt);
        _ = c.sqlite3_bind_int(map_stmt, 1, @intFromBool(score.passed));
        _ = c.sqlite3_bind_text(map_stmt, 2, score.map_md5.ptr, @intCast(score.map_md5.len), null);
        if (c.sqlite3_step(map_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        try self.exec("COMMIT");
        return id;
    }

    pub fn replay(self: *Store, allocator: std.mem.Allocator, score_id: i64) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "SELECT replay FROM scores WHERE id=?1 AND replay IS NOT NULL";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, score_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0));
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        return @as(?[]u8, try allocator.dupe(u8, ptr[0..len]));
    }
};
