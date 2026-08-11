const std = @import("std");
const domain = @import("domain.zig");
const stable_score = @import("stable_score.zig");
const beatmap = @import("beatmap.zig");
const lazer = @import("lazer.zig");
pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Store = struct {
    db: *c.sqlite3,
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    const Credential = struct {
        allocator: std.mem.Allocator,
        user: ?domain.User,
        password_hash: []u8,
        password_salt: []u8,

        fn deinit(self: *Credential) void {
            if (self.user) |user| {
                self.allocator.free(user.name);
                self.allocator.free(user.safe_name);
            }
            self.allocator.free(self.password_hash);
            self.allocator.free(self.password_salt);
            self.* = undefined;
        }

        fn takeUser(self: *Credential) domain.User {
            const user = self.user.?;
            self.user = null;
            return user;
        }
    };

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
            if (err != null) {
                std.log.err("sqlite exec failed: {s}", .{std.mem.span(err)});
                c.sqlite3_free(err);
            }
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
        if (version < 4) try self.exec(@embedFile("migration_004.sql"));
        if (version < 5) try self.exec(@embedFile("migration_005.sql"));
        if (version < 6) try self.exec(@embedFile("migration_006.sql"));
        if (version < 7) try self.exec(@embedFile("migration_007.sql"));
        if (version < 8) {
            try self.rebuildScoreStats();
            try self.exec(@embedFile("migration_008.sql"));
        }
        if (version < 9) try self.exec(@embedFile("migration_009.sql"));
        if (version < 10) {
            if (try self.hasAvatarColumn())
                try self.exec("PRAGMA user_version=10")
            else
                try self.exec(@embedFile("migration_010.sql"));
        }
    }

    fn hasAvatarColumn(self: *Store) !bool {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(users)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)), "avatar_key")) return true;
        }
        return false;
    }

    fn rebuildScoreStats(self: *Store) !void {
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        try self.exec(
            "UPDATE scores SET best=0;" ++
                "WITH ordered AS (" ++
                "SELECT id,row_number() OVER (PARTITION BY user_id,map_md5,mode,rank_namespace ORDER BY CASE WHEN rank_namespace='vanilla' THEN CAST(score AS REAL) ELSE pp END DESC,id ASC) AS place " ++
                "FROM scores WHERE passed=1" ++
                ") UPDATE scores SET best=1 WHERE id IN (SELECT id FROM ordered WHERE place=1);",
        );
        const internal_mode = "CASE WHEN (s.mods & 8192)!=0 THEN s.mode+8 WHEN (s.mods & 128)!=0 THEN s.mode+4 ELSE s.mode END";
        const rebuild_sql = "UPDATE stats SET " ++
            "total_score=coalesce((SELECT sum(s.score) FROM scores s WHERE s.user_id=stats.user_id AND " ++ internal_mode ++ "=stats.mode),0)," ++
            "plays=coalesce((SELECT count(*) FROM scores s WHERE s.user_id=stats.user_id AND " ++ internal_mode ++ "=stats.mode),0)," ++
            "play_time=coalesce((SELECT sum(s.time_elapsed/1000) FROM scores s WHERE s.user_id=stats.user_id AND " ++ internal_mode ++ "=stats.mode),0)," ++
            "total_hits=coalesce((SELECT sum(s.n300+s.n100+s.n50+CASE WHEN s.mode IN (1,3) THEN s.ngeki+s.nkatu ELSE 0 END) FROM scores s WHERE s.user_id=stats.user_id AND " ++ internal_mode ++ "=stats.mode),0)," ++
            "max_combo=coalesce((SELECT max(s.max_combo) FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=stats.user_id AND " ++ internal_mode ++ "=stats.mode AND s.passed=1 AND b.status>=3),0)," ++
            "ranked_score=coalesce((SELECT sum(s.score) FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=stats.user_id AND " ++ internal_mode ++ "=stats.mode AND s.passed=1 AND s.best=1 AND b.status IN (3,4)),0)," ++
            "pp=0,accuracy=0";
        try self.exec(rebuild_sql);

        const StatsKey = struct { user_id: i32, mode: u8 };
        var keys: std.ArrayList(StatsKey) = .empty;
        defer keys.deinit(self.allocator);
        var keys_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT user_id,mode FROM stats ORDER BY user_id,mode", -1, &keys_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        while (c.sqlite3_step(keys_stmt) == c.SQLITE_ROW) {
            try keys.append(self.allocator, .{ .user_id = c.sqlite3_column_int(keys_stmt, 0), .mode = @intCast(c.sqlite3_column_int(keys_stmt, 1)) });
        }
        _ = c.sqlite3_finalize(keys_stmt);

        for (keys.items) |key| {
            const namespace: []const u8 = switch (key.mode) {
                0...3 => "vanilla",
                4...6 => "relax",
                8 => "autopilot",
                else => continue,
            };
            const vanilla_mode: u8 = key.mode % 4;
            var scores_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT s.pp,s.accuracy FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=?1 AND s.mode=?2 AND s.passed=1 AND s.best=1 AND s.rank_namespace=?3 AND b.status IN (3,4) ORDER BY s.pp DESC,s.id ASC", -1, &scores_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            _ = c.sqlite3_bind_int(scores_stmt, 1, key.user_id);
            _ = c.sqlite3_bind_int(scores_stmt, 2, vanilla_mode);
            _ = c.sqlite3_bind_text(scores_stmt, 3, namespace.ptr, @intCast(namespace.len), null);
            var total_pp: f64 = 0;
            var weighted_accuracy: f64 = 0;
            var weight: f64 = 1;
            var score_count: u32 = 0;
            while (c.sqlite3_step(scores_stmt) == c.SQLITE_ROW) {
                total_pp += c.sqlite3_column_double(scores_stmt, 0) * weight;
                weighted_accuracy += c.sqlite3_column_double(scores_stmt, 1) * weight;
                weight *= 0.95;
                score_count += 1;
            }
            _ = c.sqlite3_finalize(scores_stmt);
            if (score_count == 0) continue;
            const bonus_pp = 416.6667 * (1.0 - std.math.pow(f64, 0.9994, @floatFromInt(score_count)));
            const bonus_accuracy = 1.0 / (20.0 * (1.0 - std.math.pow(f64, 0.95, @floatFromInt(score_count))));
            var update_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "UPDATE stats SET pp=?1,accuracy=?2 WHERE user_id=?3 AND mode=?4", -1, &update_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            _ = c.sqlite3_bind_int64(update_stmt, 1, @intFromFloat(@round(total_pp + bonus_pp)));
            _ = c.sqlite3_bind_double(update_stmt, 2, weighted_accuracy * bonus_accuracy);
            _ = c.sqlite3_bind_int(update_stmt, 3, key.user_id);
            _ = c.sqlite3_bind_int(update_stmt, 4, key.mode);
            if (c.sqlite3_step(update_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
            _ = c.sqlite3_finalize(update_stmt);
        }
        try self.exec("COMMIT");
    }

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

    fn credentialForSafeName(self: *Store, allocator: std.mem.Allocator, safe: []const u8) !?Credential {
        const sql = "SELECT id,name,safe_name,country,privileges,silence_end,restricted,password_hash,password_salt FROM users WHERE safe_name=?1";
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
        const expected: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 7));
        const expected_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 7));
        const expected_copy = try allocator.dupe(u8, expected[0..expected_len]);
        errdefer allocator.free(expected_copy);
        const salt: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 8));
        const salt_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 8));
        const salt_copy = try allocator.dupe(u8, salt[0..salt_len]);
        return .{
            .allocator = allocator,
            .user = .{ .id = c.sqlite3_column_int(stmt, 0), .name = uname, .safe_name = usafe, .country = .{ cc[0], cc[1] }, .privileges = @intCast(c.sqlite3_column_int64(stmt, 4)), .silence_end = c.sqlite3_column_int64(stmt, 5), .restricted = c.sqlite3_column_int(stmt, 6) != 0 },
            .password_hash = expected_copy,
            .password_salt = salt_copy,
        };
    }

    pub fn userById(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?domain.User {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "SELECT id,name,safe_name,country,privileges,silence_end,restricted FROM users WHERE id=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const name = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
        errdefer allocator.free(name);
        const safe = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)));
        const cc = std.mem.span(c.sqlite3_column_text(stmt, 3));
        return .{
            .id = c.sqlite3_column_int(stmt, 0),
            .name = name,
            .safe_name = safe,
            .country = .{ cc[0], cc[1] },
            .privileges = @intCast(c.sqlite3_column_int64(stmt, 4)),
            .silence_end = c.sqlite3_column_int64(stmt, 5),
            .restricted = c.sqlite3_column_int(stmt, 6) != 0,
        };
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

    pub const ServerCounts = struct {
        users: i64,
        plays: i64,
        passed: i64,
        maps: i64,
    };

    pub fn serverCounts(self: *Store) !ServerCounts {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT " ++
            "(SELECT count(*) FROM users WHERE id!=3)," ++
            "(SELECT count(*) FROM scores)+(SELECT count(*) FROM lazer_scores)," ++
            "(SELECT count(*) FROM scores WHERE passed=1)+(SELECT count(*) FROM lazer_scores WHERE passed=1)," ++
            "(SELECT count(*) FROM beatmaps)";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        return .{
            .users = c.sqlite3_column_int64(stmt, 0),
            .plays = c.sqlite3_column_int64(stmt, 1),
            .passed = c.sqlite3_column_int64(stmt, 2),
            .maps = c.sqlite3_column_int64(stmt, 3),
        };
    }

    fn upgradePassword(self: *Store, user_id: i32, password_md5: []const u8, previous_hash: []const u8) !void {
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

    pub fn statsForUser(self: *Store, user_id: i32, mode: u8) !?domain.Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "SELECT s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,(SELECT count(1)+1 FROM stats r JOIN users u ON u.id=r.user_id WHERE r.mode=s.mode AND u.restricted=0 AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) FROM stats s WHERE s.user_id=?1 AND s.mode=?2";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_int(stmt, 2, mode);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return .{
            .mode = @enumFromInt(mode % 4),
            .ranked_score = c.sqlite3_column_int64(stmt, 0),
            .total_score = c.sqlite3_column_int64(stmt, 1),
            .pp = c.sqlite3_column_int(stmt, 2),
            .plays = c.sqlite3_column_int(stmt, 3),
            .play_time = c.sqlite3_column_int(stmt, 4),
            .total_hits = c.sqlite3_column_int64(stmt, 5),
            .accuracy = c.sqlite3_column_double(stmt, 6),
            .max_combo = c.sqlite3_column_int(stmt, 7),
            .global_rank = c.sqlite3_column_int(stmt, 8),
        };
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

    pub fn insertLazerScore(self: *Store, user_id: i32, input: lazer.ScoreInput, raw_json: []const u8) !i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const namespace = @tagName(input.namespace);
        const sql = "INSERT INTO lazer_scores(user_id,beatmap_id,ruleset_id,total_score,legacy_total_score,accuracy,max_combo,passed,mods_json,statistics_json,rank_namespace,client_version) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_int64(stmt, 2, input.beatmap_id);
        _ = c.sqlite3_bind_int64(stmt, 3, input.ruleset_id);
        _ = c.sqlite3_bind_int64(stmt, 4, input.total_score);
        if (input.legacy_total_score) |n| _ = c.sqlite3_bind_int64(stmt, 5, n) else _ = c.sqlite3_bind_null(stmt, 5);
        _ = c.sqlite3_bind_double(stmt, 6, input.accuracy);
        _ = c.sqlite3_bind_int64(stmt, 7, input.max_combo);
        _ = c.sqlite3_bind_int(stmt, 8, @intFromBool(input.passed));
        _ = c.sqlite3_bind_text(stmt, 9, raw_json.ptr, @intCast(raw_json.len), null);
        _ = c.sqlite3_bind_text(stmt, 10, raw_json.ptr, @intCast(raw_json.len), null);
        _ = c.sqlite3_bind_text(stmt, 11, namespace.ptr, @intCast(namespace.len), null);
        if (input.client_version) |version| {
            _ = c.sqlite3_bind_text(stmt, 12, version.ptr, @intCast(version.len), null);
        } else _ = c.sqlite3_bind_null(stmt, 12);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        return c.sqlite3_last_insert_rowid(self.db);
    }

    pub const BeatmapForScore = struct { id: i32, set_id: i32, status: i8, plays: i32, passes: i32 };

    pub const BeatmapRating = union(enum) {
        no_exist,
        not_ranked,
        can_rate,
        already_voted: f64,
    };

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
        var target_buf: [24]u8 = undefined;
        var detail_buf: [32]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{user_id});
        const detail = try std.fmt.bufPrint(&detail_buf, "flags:{d}", .{flags});
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT INTO audit_log(actor_id,action,target,detail) VALUES(?1,'stable.lastfm_flag',?2,?3)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_text(stmt, 2, target.ptr, @intCast(target.len), null);
        _ = c.sqlite3_bind_text(stmt, 3, detail.ptr, @intCast(detail.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    pub fn upsertBeatmap(self: *Store, metadata: beatmap.Metadata, md5: []const u8, status: i8, stars: f64, max_combo: u32, osu_file: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,last_update,total_length,max_combo,mode,bpm,cs,ar,od,hp,star_rating,source,tags,osu_file,count_circles,count_sliders,count_spinners) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,unixepoch(),?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23) ON CONFLICT(id) DO UPDATE SET set_id=excluded.set_id,md5=excluded.md5,artist=excluded.artist,title=excluded.title,version=excluded.version,creator=excluded.creator,status=excluded.status,last_update=excluded.last_update,total_length=excluded.total_length,max_combo=excluded.max_combo,mode=excluded.mode,bpm=excluded.bpm,cs=excluded.cs,ar=excluded.ar,od=excluded.od,hp=excluded.hp,star_rating=excluded.star_rating,source=excluded.source,tags=excluded.tags,osu_file=excluded.osu_file,count_circles=excluded.count_circles,count_sliders=excluded.count_sliders,count_spinners=excluded.count_spinners";
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

    pub fn upsertBeatmapArchive(self: *Store, set_id: i32, sha256: []const u8, osz_file: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var exists_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM beatmaps WHERE set_id=?1 LIMIT 1", -1, &exists_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int(exists_stmt, 1, set_id);
        const exists = c.sqlite3_step(exists_stmt) == c.SQLITE_ROW;
        _ = c.sqlite3_finalize(exists_stmt);
        if (!exists) return error.UnknownBeatmapSet;
        const sql = "INSERT INTO beatmap_archives(set_id,sha256,osz_file) VALUES(?1,?2,?3) ON CONFLICT(set_id) DO UPDATE SET sha256=excluded.sha256,osz_file=excluded.osz_file,imported_at=unixepoch()";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, set_id);
        _ = c.sqlite3_bind_text(stmt, 2, sha256.ptr, @intCast(sha256.len), null);
        _ = c.sqlite3_bind_blob(stmt, 3, osz_file.ptr, @intCast(osz_file.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    pub fn beatmapArchive(self: *Store, allocator: std.mem.Allocator, set_id: i32) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT osz_file FROM beatmap_archives WHERE set_id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, set_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0));
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        return try allocator.dupe(u8, ptr[0..len]);
    }

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

    pub const BeatmapInfo = struct { id: i32, set_id: i32, max_combo: i32, artist: []const u8, title: []const u8, version: []const u8, star_rating: f64 };

    pub fn scoreRankOnMap(self: *Store, md5: []const u8, mode: u8, namespace: []const u8, score_val: i64, pp_val: f64) i32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const is_vanilla = std.mem.eql(u8, namespace, "vanilla");
        const sql = if (is_vanilla)
            "SELECT count(*) FROM scores WHERE map_md5=?1 AND mode=?2 AND rank_namespace=?3 AND passed=1 AND score>?4"
        else
            "SELECT count(*) FROM scores WHERE map_md5=?1 AND mode=?2 AND rank_namespace=?3 AND passed=1 AND pp>?4";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return 999;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, md5.ptr, @intCast(md5.len), null);
        _ = c.sqlite3_bind_int(stmt, 2, mode);
        _ = c.sqlite3_bind_text(stmt, 3, namespace.ptr, @intCast(namespace.len), null);
        if (is_vanilla)
            _ = c.sqlite3_bind_int64(stmt, 4, score_val)
        else
            _ = c.sqlite3_bind_double(stmt, 4, pp_val);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 999;
        return c.sqlite3_column_int(stmt, 0);
    }

    pub fn beatmapInfo(self: *Store, allocator: std.mem.Allocator, md5: []const u8) !?BeatmapInfo {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "SELECT id,set_id,max_combo,artist,title,version,star_rating FROM beatmaps WHERE md5=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, md5.ptr, @intCast(md5.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return .{
            .id = c.sqlite3_column_int(stmt, 0),
            .set_id = c.sqlite3_column_int(stmt, 1),
            .max_combo = c.sqlite3_column_int(stmt, 2),
            .artist = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3))),
            .title = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 4))),
            .version = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 5))),
            .star_rating = c.sqlite3_column_double(stmt, 6),
        };
    }

    pub fn insertStableScore(self: *Store, user_id: i32, score: stable_score.Submission, pp_value: f64, replay_data: []const u8, time_elapsed_ms: u32) !i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        const namespace = score.rankNamespace();
        var previous_best_id: i64 = 0;
        var previous_best_score: i64 = 0;
        var previous_best_pp: f64 = 0;
        const best_sql = "SELECT id,score,pp FROM scores WHERE user_id=?1 AND map_md5=?2 AND mode=?3 AND rank_namespace=?4 AND best=1 LIMIT 1";
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
        }
        _ = c.sqlite3_finalize(best_stmt);
        const uses_pp_metric = !std.mem.eql(u8, namespace, "vanilla");
        const is_best = score.passed and if (uses_pp_metric) pp_value > previous_best_pp else score.total_score > previous_best_score;
        const stats_mode = stable_score.statsMode(score.mode, score.mods) orelse return error.UnsupportedModMode;
        const sql = "INSERT INTO scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,checksum,rank_namespace,best,time_elapsed) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21)";
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
        const ranked_delta: i64 = if (is_best and awards_ranked_pp) score.total_score - previous_best_score else 0;
        const total_hits: i64 = @as(i64, score.n300) + score.n100 + score.n50 + if (score.mode == 1 or score.mode == 3) @as(i64, score.ngeki) + score.nkatu else 0;
        const update_stats = "UPDATE stats SET total_score=total_score+?1,ranked_score=ranked_score+?2,plays=plays+1,play_time=play_time+?3,total_hits=total_hits+?4,max_combo=CASE WHEN ?5=1 THEN max(max_combo,?6) ELSE max_combo END WHERE user_id=?7 AND mode=?8";
        var stats_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, update_stats, -1, &stats_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stats_stmt);
        _ = c.sqlite3_bind_int64(stats_stmt, 1, score.total_score);
        _ = c.sqlite3_bind_int64(stats_stmt, 2, ranked_delta);
        _ = c.sqlite3_bind_int64(stats_stmt, 3, time_elapsed_ms / 1000);
        _ = c.sqlite3_bind_int64(stats_stmt, 4, total_hits);
        _ = c.sqlite3_bind_int(stats_stmt, 5, @intFromBool(score.passed and has_leaderboard));
        _ = c.sqlite3_bind_int(stats_stmt, 6, score.max_combo);
        _ = c.sqlite3_bind_int(stats_stmt, 7, user_id);
        _ = c.sqlite3_bind_int(stats_stmt, 8, stats_mode);
        if (c.sqlite3_step(stats_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        const update_map = "UPDATE beatmaps SET plays=plays+1,passes=passes+?1 WHERE md5=?2";
        var map_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, update_map, -1, &map_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(map_stmt);
        _ = c.sqlite3_bind_int(map_stmt, 1, @intFromBool(score.passed));
        _ = c.sqlite3_bind_text(map_stmt, 2, score.map_md5.ptr, @intCast(score.map_md5.len), null);
        if (c.sqlite3_step(map_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        if (is_best and awards_ranked_pp) {
            const pp_sql = "SELECT s.pp,s.accuracy FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=?1 AND s.mode=?2 AND s.passed=1 AND s.best=1 AND s.rank_namespace=?3 AND b.status IN (3,4) ORDER BY s.pp DESC,s.id ASC";
            var pp_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, pp_sql, -1, &pp_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(pp_stmt);
            _ = c.sqlite3_bind_int(pp_stmt, 1, user_id);
            _ = c.sqlite3_bind_int(pp_stmt, 2, score.mode);
            _ = c.sqlite3_bind_text(pp_stmt, 3, namespace.ptr, @intCast(namespace.len), null);
            var total_pp: f64 = 0;
            var weighted_accuracy: f64 = 0;
            var weight: f64 = 1;
            var score_count: u32 = 0;
            while (c.sqlite3_step(pp_stmt) == c.SQLITE_ROW) {
                total_pp += c.sqlite3_column_double(pp_stmt, 0) * weight;
                weighted_accuracy += c.sqlite3_column_double(pp_stmt, 1) * weight;
                weight *= 0.95;
                score_count += 1;
            }
            const bonus_pp = 416.6667 * (1.0 - std.math.pow(f64, 0.9994, @floatFromInt(score_count)));
            const bonus_accuracy = 1.0 / (20.0 * (1.0 - std.math.pow(f64, 0.95, @floatFromInt(score_count))));
            const set_pp_sql = "UPDATE stats SET pp=?1,accuracy=?2 WHERE user_id=?3 AND mode=?4";
            var set_pp_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, set_pp_sql, -1, &set_pp_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(set_pp_stmt);
            _ = c.sqlite3_bind_int64(set_pp_stmt, 1, @intFromFloat(@round(total_pp + bonus_pp)));
            _ = c.sqlite3_bind_double(set_pp_stmt, 2, weighted_accuracy * bonus_accuracy);
            _ = c.sqlite3_bind_int(set_pp_stmt, 3, user_id);
            _ = c.sqlite3_bind_int(set_pp_stmt, 4, stats_mode);
            if (c.sqlite3_step(set_pp_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        }
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

    pub const PpSnapshot = struct { score: f64, player: i64 };

    pub fn ppSnapshot(self: *Store, score_id: i64) !?PpSnapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "SELECT s.pp,t.pp FROM scores s JOIN stats t ON t.user_id=s.user_id AND t.mode=s.mode WHERE s.id=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, score_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return .{ .score = c.sqlite3_column_double(stmt, 0), .player = c.sqlite3_column_int64(stmt, 1) };
    }

    fn writeDirectText(writer: *std.Io.Writer, value: []const u8) !void {
        for (value) |char| try writer.writeByte(switch (char) {
            '|' => 'I',
            '\r', '\n' => ' ',
            else => char,
        });
    }

    pub fn directStatus(db_status: i32) i32 {
        return switch (db_status) {
            2 => 2,
            3, 4 => 0,
            5 => 3,
            6 => 8,
            else => 2,
        };
    }

    pub fn stableStatus(db_status: i32) i32 {
        return switch (db_status) {
            1 => -1,
            2 => 0,
            3 => 2,
            4 => 3,
            5 => 4,
            6 => 5,
            else => 1,
        };
    }

    fn appendDirectSet(self: *Store, writer: *std.Io.Writer, set_id: i32) !bool {
        const set_sql = "SELECT artist,title,creator,status,coalesce(datetime(last_update,'unixepoch'),'1970-01-01 00:00:00') FROM beatmaps WHERE set_id=?1 ORDER BY star_rating LIMIT 1";
        var set_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, set_sql, -1, &set_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(set_stmt);
        _ = c.sqlite3_bind_int(set_stmt, 1, set_id);
        if (c.sqlite3_step(set_stmt) != c.SQLITE_ROW) return false;
        try writer.print("{d}.osz|", .{set_id});
        try writeDirectText(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 0)));
        try writer.writeByte('|');
        try writeDirectText(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 1)));
        try writer.writeByte('|');
        try writeDirectText(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 2)));
        try writer.print("|{d}|10.0|{s}|{d}|0|0|0|0|0|", .{ directStatus(c.sqlite3_column_int(set_stmt, 3)), std.mem.span(c.sqlite3_column_text(set_stmt, 4)), set_id });

        const maps_sql = "SELECT star_rating,version,cs,od,ar,hp,mode FROM beatmaps WHERE set_id=?1 ORDER BY star_rating,id";
        var maps_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, maps_sql, -1, &maps_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(maps_stmt);
        _ = c.sqlite3_bind_int(maps_stmt, 1, set_id);
        var first = true;
        while (c.sqlite3_step(maps_stmt) == c.SQLITE_ROW) {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("[{d:.2}⭐] ", .{c.sqlite3_column_double(maps_stmt, 0)});
            try writeDirectText(writer, std.mem.span(c.sqlite3_column_text(maps_stmt, 1)));
            try writer.print(" {{cs: {d} / od: {d} / ar: {d} / hp: {d}}}@{d}", .{ c.sqlite3_column_double(maps_stmt, 2), c.sqlite3_column_double(maps_stmt, 3), c.sqlite3_column_double(maps_stmt, 4), c.sqlite3_column_double(maps_stmt, 5), c.sqlite3_column_int(maps_stmt, 6) });
        }
        return true;
    }

    pub fn stableSearch(self: *Store, allocator: std.mem.Allocator, query: []const u8, mode: i8, direct_status: u8, page: u16) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        const sql = "SELECT set_id FROM beatmaps WHERE EXISTS(SELECT 1 FROM beatmap_archives a WHERE a.set_id=beatmaps.set_id) AND (?1=-1 OR mode=?1) AND (?2='' OR instr(lower(artist||' '||title||' '||creator||' '||source||' '||tags),lower(?2))>0) AND ((?3=4 AND status IN(3,4,5,6)) OR (?3 IN(0,7) AND status IN(3,4)) OR (?3 IN(2,5) AND status=2) OR (?3=3 AND status=5) OR (?3=8 AND status=6)) GROUP BY set_id ORDER BY max(last_update) DESC,set_id DESC LIMIT 100 OFFSET ?4";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, mode);
        _ = c.sqlite3_bind_text(stmt, 2, query.ptr, @intCast(query.len), null);
        _ = c.sqlite3_bind_int(stmt, 3, direct_status);
        _ = c.sqlite3_bind_int64(stmt, 4, @as(i64, page) * 100);
        var ids: [100]i32 = undefined;
        var count: usize = 0;
        while (count < ids.len and c.sqlite3_step(stmt) == c.SQLITE_ROW) : (count += 1) ids[count] = c.sqlite3_column_int(stmt, 0);
        try output.writer.print("{d}", .{if (count == 100) @as(usize, 101) else count});
        for (ids[0..count]) |set_id| {
            try output.writer.writeByte('\n');
            _ = try self.appendDirectSet(&output.writer, set_id);
        }
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    pub fn stableSearchSet(self: *Store, allocator: std.mem.Allocator, set_id: ?i32, map_id: ?i32, md5: ?[]const u8) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const find_sql = "SELECT set_id FROM beatmaps WHERE (?1 IS NOT NULL AND set_id=?1) OR (?2 IS NOT NULL AND id=?2) OR (?3 IS NOT NULL AND md5=?3) LIMIT 1";
        var find_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, find_sql, -1, &find_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(find_stmt);
        if (set_id) |value| _ = c.sqlite3_bind_int(find_stmt, 1, value) else _ = c.sqlite3_bind_null(find_stmt, 1);
        if (map_id) |value| _ = c.sqlite3_bind_int(find_stmt, 2, value) else _ = c.sqlite3_bind_null(find_stmt, 2);
        if (md5) |value| _ = c.sqlite3_bind_text(find_stmt, 3, value.ptr, @intCast(value.len), null) else _ = c.sqlite3_bind_null(find_stmt, 3);
        if (c.sqlite3_step(find_stmt) != c.SQLITE_ROW) return allocator.dupe(u8, "");
        const found_set_id = c.sqlite3_column_int(find_stmt, 0);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        _ = try self.appendDirectSet(&output.writer, found_set_id);
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    fn jsonString(writer: *std.Io.Writer, value: []const u8) !void {
        try std.json.Stringify.value(value, .{}, writer);
    }

    pub fn lazerStatus(db_status: i32) []const u8 {
        return switch (db_status) {
            3 => "ranked",
            4 => "approved",
            5 => "qualified",
            6 => "loved",
            else => "pending",
        };
    }

    fn appendLazerMap(writer: *std.Io.Writer, stmt: *c.sqlite3_stmt) !void {
        try writer.print("{{\"id\":{d},\"beatmapset_id\":{d},\"status\":", .{ c.sqlite3_column_int(stmt, 0), c.sqlite3_column_int(stmt, 1) });
        try jsonString(writer, lazerStatus(c.sqlite3_column_int(stmt, 2)));
        try writer.writeAll(",\"checksum\":");
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(stmt, 3)));
        try writer.print(",\"user_id\":1,\"playcount\":{d},\"passcount\":{d},\"mode_int\":{d},\"difficulty_rating\":{d},\"drain\":{d},\"cs\":{d},\"ar\":{d},\"accuracy\":{d},\"total_length\":{d},\"hit_length\":{d},\"convert\":false,\"count_circles\":{d},\"count_sliders\":{d},\"count_spinners\":{d},\"version\":", .{ c.sqlite3_column_int(stmt, 4), c.sqlite3_column_int(stmt, 5), c.sqlite3_column_int(stmt, 6), c.sqlite3_column_double(stmt, 7), c.sqlite3_column_double(stmt, 8), c.sqlite3_column_double(stmt, 9), c.sqlite3_column_double(stmt, 10), c.sqlite3_column_double(stmt, 11), c.sqlite3_column_int(stmt, 12), c.sqlite3_column_int(stmt, 12), c.sqlite3_column_int(stmt, 17), c.sqlite3_column_int(stmt, 18), c.sqlite3_column_int(stmt, 19) });
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(stmt, 13)));
        try writer.print(",\"max_combo\":{d},\"last_updated\":", .{c.sqlite3_column_int(stmt, 14)});
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(stmt, 15)));
        try writer.print(",\"bpm\":{d},\"owners\":[]}}", .{c.sqlite3_column_double(stmt, 16)});
    }

    fn appendLazerSet(self: *Store, writer: *std.Io.Writer, set_id: i32) !bool {
        const set_sql = "SELECT set_id,artist,title,creator,status,bpm,source,tags,coalesce(strftime('%Y-%m-%dT%H:%M:%SZ',last_update,'unixepoch'),'1970-01-01T00:00:00Z'),coalesce((SELECT 0 FROM beatmap_archives a WHERE a.set_id=beatmaps.set_id),1),sum(plays) FROM beatmaps WHERE set_id=?1 GROUP BY set_id";
        var set_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, set_sql, -1, &set_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(set_stmt);
        _ = c.sqlite3_bind_int(set_stmt, 1, set_id);
        if (c.sqlite3_step(set_stmt) != c.SQLITE_ROW) return false;
        try writer.print("{{\"id\":{d},\"status\":", .{set_id});
        try jsonString(writer, lazerStatus(c.sqlite3_column_int(set_stmt, 4)));
        try writer.writeAll(",\"title\":");
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 2)));
        try writer.writeAll(",\"title_unicode\":");
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 2)));
        try writer.writeAll(",\"artist\":");
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 1)));
        try writer.writeAll(",\"artist_unicode\":");
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 1)));
        try writer.writeAll(",\"creator\":");
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 3)));
        try writer.print(",\"user_id\":1,\"covers\":{{\"cover\":\"\",\"cover@2x\":\"\",\"card\":\"\",\"card@2x\":\"\",\"list\":\"\",\"list@2x\":\"\"}},\"preview_url\":\"\",\"play_count\":{d},\"favourite_count\":0,\"bpm\":{d},\"nsfw\":false,\"spotlight\":false,\"video\":false,\"storyboard\":false,\"submitted_date\":", .{ c.sqlite3_column_int(set_stmt, 10), c.sqlite3_column_double(set_stmt, 5) });
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 8)));
        try writer.writeAll(",\"last_updated\":");
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 8)));
        try writer.print(",\"ranked_date\":null,\"ratings\":[],\"availability\":{{\"download_disabled\":{s},\"more_information\":\"\"}},\"genre\":{{\"id\":0,\"name\":\"Unspecified\"}},\"language\":{{\"id\":0,\"name\":\"Unspecified\"}},\"source\":", .{if (c.sqlite3_column_int(set_stmt, 9) != 0) "true" else "false"});
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 6)));
        try writer.writeAll(",\"tags\":");
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 7)));
        try writer.writeAll(",\"beatmaps\":[");
        const maps_sql = "SELECT id,set_id,status,md5,plays,passes,mode,star_rating,hp,cs,ar,od,total_length,version,max_combo,coalesce(strftime('%Y-%m-%dT%H:%M:%SZ',last_update,'unixepoch'),'1970-01-01T00:00:00Z'),bpm,count_circles,count_sliders,count_spinners FROM beatmaps WHERE set_id=?1 ORDER BY star_rating,id";
        var maps_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, maps_sql, -1, &maps_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(maps_stmt);
        _ = c.sqlite3_bind_int(maps_stmt, 1, set_id);
        var first = true;
        while (c.sqlite3_step(maps_stmt) == c.SQLITE_ROW) {
            if (!first) try writer.writeByte(',');
            first = false;
            try appendLazerMap(writer, maps_stmt.?);
        }
        try writer.writeAll("]}");
        return true;
    }

    pub fn lazerBeatmapSet(self: *Store, allocator: std.mem.Allocator, set_id: i32) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        if (!try self.appendLazerSet(&output.writer, set_id)) {
            output.deinit();
            return null;
        }
        var list = output.toArrayList();
        return try list.toOwnedSlice(allocator);
    }

    pub fn lazerBeatmapSearch(self: *Store, allocator: std.mem.Allocator, query: []const u8, mode: i8, offset: u16) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const ids_sql = "SELECT set_id FROM beatmaps WHERE (?1=-1 OR mode=?1) AND (?2='' OR instr(lower(artist||' '||title||' '||creator||' '||source||' '||tags),lower(?2))>0) GROUP BY set_id ORDER BY max(last_update) DESC,set_id DESC LIMIT 50 OFFSET ?3";
        var ids_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, ids_sql, -1, &ids_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(ids_stmt);
        _ = c.sqlite3_bind_int(ids_stmt, 1, mode);
        _ = c.sqlite3_bind_text(ids_stmt, 2, query.ptr, @intCast(query.len), null);
        _ = c.sqlite3_bind_int64(ids_stmt, 3, offset);
        var ids: [50]i32 = undefined;
        var count: usize = 0;
        while (count < ids.len and c.sqlite3_step(ids_stmt) == c.SQLITE_ROW) : (count += 1) ids[count] = c.sqlite3_column_int(ids_stmt, 0);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"beatmapsets\":[");
        for (ids[0..count], 0..) |set_id, index| {
            if (index != 0) try output.writer.writeByte(',');
            _ = try self.appendLazerSet(&output.writer, set_id);
        }
        try output.writer.print("],\"total\":{d},\"cursor\":null}}", .{count});
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
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
        const namespace = if (requested_mods & (1 << 13) != 0) "autopilot" else if (requested_mods & (1 << 7) != 0) "relax" else if (requested_mods & (1 << 27) != 0) "scorev2" else "vanilla";
        const uses_pp = std.mem.eql(u8, namespace, "relax") or std.mem.eql(u8, namespace, "autopilot");
        const filter = " FROM scores s JOIN users u ON u.id=s.user_id WHERE s.map_md5=?1 AND s.mode=?2 AND s.passed=1 AND s.best=1 AND s.rank_namespace=?3 AND (?4!=2 OR s.mods=?5) AND (?4!=3 OR s.user_id=?6 OR EXISTS(SELECT 1 FROM friends f WHERE f.user_id=?6 AND f.friend_id=s.user_id)) AND (?4!=4 OR u.country=?7)";
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
                "SELECT s.id,u.name,s.pp,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,length(s.replay)>0 FROM scores s JOIN users u ON u.id=s.user_id WHERE s.id=?1"
            else
                "SELECT s.id,u.name,s.score,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,length(s.replay)>0 FROM scores s JOIN users u ON u.id=s.user_id WHERE s.id=?1";
            var row_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, row_sql, -1, &row_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            _ = c.sqlite3_bind_int64(row_stmt, 1, personal_id);
            if (c.sqlite3_step(row_stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
            try writeBoardRow(w, row_stmt.?, personal_rank, uses_pp);
            _ = c.sqlite3_finalize(row_stmt);
        }
        try w.writeByte('\n');
        const rows_sql = if (uses_pp)
            "SELECT s.id,u.name,s.pp,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,length(s.replay)>0" ++ filter ++ " ORDER BY s.pp DESC,s.id ASC LIMIT 50"
        else
            "SELECT s.id,u.name,s.score,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,length(s.replay)>0" ++ filter ++ " ORDER BY s.score DESC,s.id ASC LIMIT 50";
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
};

fn bindBoard(stmt: *c.sqlite3_stmt, map_md5: []const u8, mode: u8, namespace: []const u8, board_type: u8, mods: i32, viewer: *const domain.User) void {
    _ = c.sqlite3_bind_text(stmt, 1, map_md5.ptr, @intCast(map_md5.len), null);
    _ = c.sqlite3_bind_int(stmt, 2, mode);
    _ = c.sqlite3_bind_text(stmt, 3, namespace.ptr, @intCast(namespace.len), null);
    _ = c.sqlite3_bind_int(stmt, 4, board_type);
    _ = c.sqlite3_bind_int(stmt, 5, mods);
    _ = c.sqlite3_bind_int(stmt, 6, viewer.id);
    _ = c.sqlite3_bind_text(stmt, 7, viewer.country[0..].ptr, 2, null);
}

fn writeBoardRow(w: *std.Io.Writer, stmt: *c.sqlite3_stmt, rank: i32, is_pp: bool) !void {
    const score_val: i64 = if (is_pp) @intFromFloat(c.sqlite3_column_double(stmt, 2)) else c.sqlite3_column_int64(stmt, 2);
    try w.print("{d}|{s}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}", .{ c.sqlite3_column_int64(stmt, 0), std.mem.span(c.sqlite3_column_text(stmt, 1)), score_val, c.sqlite3_column_int(stmt, 3), c.sqlite3_column_int(stmt, 4), c.sqlite3_column_int(stmt, 5), c.sqlite3_column_int(stmt, 6), c.sqlite3_column_int(stmt, 7), c.sqlite3_column_int(stmt, 8), c.sqlite3_column_int(stmt, 9), c.sqlite3_column_int(stmt, 10), c.sqlite3_column_int(stmt, 11), c.sqlite3_column_int(stmt, 12), rank, c.sqlite3_column_int64(stmt, 13), c.sqlite3_column_int(stmt, 14) });
}
