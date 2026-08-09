const std = @import("std");
const domain = @import("domain.zig");
const stable_score = @import("stable_score.zig");
const beatmap = @import("beatmap.zig");
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
        if (version < 4) try self.exec(@embedFile("migration_004.sql"));
        if (version < 5) try self.exec(@embedFile("migration_005.sql"));
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
        const beatmap_id = o.get("beatmap_id").?.integer;
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
        _ = c.sqlite3_bind_int64(stmt, 2, beatmap_id);
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

    pub fn upsertBeatmap(self: *Store, metadata: beatmap.Metadata, md5: []const u8, status: i8, stars: f64, max_combo: u32, osu_file: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,last_update,total_length,max_combo,mode,bpm,cs,ar,od,hp,star_rating,source,tags,osu_file) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,unixepoch(),?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20) ON CONFLICT(id) DO UPDATE SET set_id=excluded.set_id,md5=excluded.md5,artist=excluded.artist,title=excluded.title,version=excluded.version,creator=excluded.creator,status=excluded.status,last_update=excluded.last_update,total_length=excluded.total_length,max_combo=excluded.max_combo,mode=excluded.mode,bpm=excluded.bpm,cs=excluded.cs,ar=excluded.ar,od=excluded.od,hp=excluded.hp,star_rating=excluded.star_rating,source=excluded.source,tags=excluded.tags,osu_file=excluded.osu_file";
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

    pub fn insertStableScore(self: *Store, user_id: i32, score: stable_score.Submission, pp_value: f64, replay_data: []const u8) !i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        const namespace = score.rankNamespace();
        var previous_best_id: i64 = 0;
        var previous_best_score: i64 = 0;
        const best_sql = "SELECT id,score FROM scores WHERE user_id=?1 AND map_md5=?2 AND mode=?3 AND rank_namespace=?4 AND best=1 LIMIT 1";
        var best_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, best_sql, -1, &best_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int(best_stmt, 1, user_id);
        _ = c.sqlite3_bind_text(best_stmt, 2, score.map_md5.ptr, @intCast(score.map_md5.len), null);
        _ = c.sqlite3_bind_int(best_stmt, 3, score.mode);
        _ = c.sqlite3_bind_text(best_stmt, 4, namespace.ptr, @intCast(namespace.len), null);
        if (c.sqlite3_step(best_stmt) == c.SQLITE_ROW) {
            previous_best_id = c.sqlite3_column_int64(best_stmt, 0);
            previous_best_score = c.sqlite3_column_int64(best_stmt, 1);
        }
        _ = c.sqlite3_finalize(best_stmt);
        const is_best = score.passed and score.total_score > previous_best_score;
        const sql = "INSERT INTO scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,checksum,rank_namespace,best) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20)";
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
        var ranked_delta: i64 = 0;
        if (is_best and std.mem.eql(u8, namespace, "vanilla")) {
            const status_sql = "SELECT status FROM beatmaps WHERE md5=?1";
            var status_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, status_sql, -1, &status_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            _ = c.sqlite3_bind_text(status_stmt, 1, score.map_md5.ptr, @intCast(score.map_md5.len), null);
            if (c.sqlite3_step(status_stmt) == c.SQLITE_ROW) {
                const status = c.sqlite3_column_int(status_stmt, 0);
                if (status == 3 or status == 4) ranked_delta = score.total_score - previous_best_score;
            }
            _ = c.sqlite3_finalize(status_stmt);
        }
        const update_stats = "UPDATE stats SET total_score=total_score+?1,ranked_score=ranked_score+?6,plays=plays+1,accuracy=((accuracy*plays)+?2)/(plays+1),max_combo=max(max_combo,?3) WHERE user_id=?4 AND mode=?5";
        var stats_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, update_stats, -1, &stats_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stats_stmt);
        _ = c.sqlite3_bind_int64(stats_stmt, 1, score.total_score);
        _ = c.sqlite3_bind_double(stats_stmt, 2, score.accuracy());
        _ = c.sqlite3_bind_int(stats_stmt, 3, score.max_combo);
        _ = c.sqlite3_bind_int(stats_stmt, 4, user_id);
        _ = c.sqlite3_bind_int(stats_stmt, 5, score.mode);
        _ = c.sqlite3_bind_int64(stats_stmt, 6, ranked_delta);
        if (c.sqlite3_step(stats_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        const update_map = "UPDATE beatmaps SET plays=plays+1,passes=passes+?1 WHERE md5=?2";
        var map_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, update_map, -1, &map_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(map_stmt);
        _ = c.sqlite3_bind_int(map_stmt, 1, @intFromBool(score.passed));
        _ = c.sqlite3_bind_text(map_stmt, 2, score.map_md5.ptr, @intCast(score.map_md5.len), null);
        if (c.sqlite3_step(map_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        if (std.mem.eql(u8, namespace, "vanilla")) {
            const pp_sql = "SELECT max(s.pp) FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=?1 AND s.mode=?2 AND s.passed=1 AND s.rank_namespace='vanilla' AND b.status IN (3,4) GROUP BY s.map_md5 ORDER BY max(s.pp) DESC";
            var pp_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, pp_sql, -1, &pp_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(pp_stmt);
            _ = c.sqlite3_bind_int(pp_stmt, 1, user_id);
            _ = c.sqlite3_bind_int(pp_stmt, 2, score.mode);
            var total_pp: f64 = 0;
            var weight: f64 = 1;
            while (c.sqlite3_step(pp_stmt) == c.SQLITE_ROW) {
                total_pp += c.sqlite3_column_double(pp_stmt, 0) * weight;
                weight *= 0.95;
            }
            const set_pp_sql = "UPDATE stats SET pp=?1 WHERE user_id=?2 AND mode=?3";
            var set_pp_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, set_pp_sql, -1, &set_pp_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(set_pp_stmt);
            _ = c.sqlite3_bind_int64(set_pp_stmt, 1, @intFromFloat(@round(total_pp)));
            _ = c.sqlite3_bind_int(set_pp_stmt, 2, user_id);
            _ = c.sqlite3_bind_int(set_pp_stmt, 3, score.mode);
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
        const artist = std.mem.span(c.sqlite3_column_text(map_stmt, 3));
        const title = std.mem.span(c.sqlite3_column_text(map_stmt, 4));
        const version = std.mem.span(c.sqlite3_column_text(map_stmt, 5));
        if (status < 3) {
            try w.print("{d}|false", .{status});
            var unavailable = output.toArrayList();
            return unavailable.toOwnedSlice(allocator);
        }
        const namespace = if (requested_mods & ((1 << 7) | (1 << 13)) != 0) "relax" else "vanilla";
        const filter = " FROM scores s JOIN users u ON u.id=s.user_id WHERE s.map_md5=?1 AND s.mode=?2 AND s.passed=1 AND s.best=1 AND s.rank_namespace=?3 AND (?4!=2 OR s.mods=?5) AND (?4!=3 OR s.user_id=?6 OR EXISTS(SELECT 1 FROM friends f WHERE f.user_id=?6 AND f.friend_id=s.user_id)) AND (?4!=4 OR u.country=?7)";
        const count_sql = "SELECT min(count(*),50)" ++ filter;
        var count_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, count_sql, -1, &count_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(count_stmt);
        bindBoard(count_stmt.?, map_md5, mode, namespace, board_type, requested_mods, viewer);
        if (c.sqlite3_step(count_stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        const row_count = c.sqlite3_column_int(count_stmt, 0);
        try w.print("{d}|false|{d}|{d}|{d}|0|\n0\n{s} - {s} [{s}]\n0\n", .{ status, map_id, set_id, row_count, artist, title, version });

        const personal_id_sql = "SELECT s.id,s.score" ++ filter ++ " AND s.user_id=?6 ORDER BY s.score DESC,s.id ASC LIMIT 1";
        var personal_id_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, personal_id_sql, -1, &personal_id_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        bindBoard(personal_id_stmt.?, map_md5, mode, namespace, board_type, requested_mods, viewer);
        var personal_id: i64 = 0;
        var personal_score: i64 = 0;
        if (c.sqlite3_step(personal_id_stmt) == c.SQLITE_ROW) {
            personal_id = c.sqlite3_column_int64(personal_id_stmt, 0);
            personal_score = c.sqlite3_column_int64(personal_id_stmt, 1);
        }
        _ = c.sqlite3_finalize(personal_id_stmt);
        if (personal_id != 0) {
            const rank_sql = "SELECT count(*)+1" ++ filter ++ " AND (s.score>?8 OR (s.score=?8 AND s.id<?9))";
            var rank_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, rank_sql, -1, &rank_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            bindBoard(rank_stmt.?, map_md5, mode, namespace, board_type, requested_mods, viewer);
            _ = c.sqlite3_bind_int64(rank_stmt, 8, personal_score);
            _ = c.sqlite3_bind_int64(rank_stmt, 9, personal_id);
            if (c.sqlite3_step(rank_stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
            const personal_rank = c.sqlite3_column_int(rank_stmt, 0);
            _ = c.sqlite3_finalize(rank_stmt);
            const row_sql = "SELECT s.id,u.name,s.score,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,datetime(s.submitted_at,'unixepoch'),length(s.replay)>0 FROM scores s JOIN users u ON u.id=s.user_id WHERE s.id=?1";
            var row_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, row_sql, -1, &row_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            _ = c.sqlite3_bind_int64(row_stmt, 1, personal_id);
            if (c.sqlite3_step(row_stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
            try writeBoardRow(w, row_stmt.?, personal_rank);
            _ = c.sqlite3_finalize(row_stmt);
        }
        try w.writeByte('\n');
        const rows_sql = "SELECT s.id,u.name,s.score,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,datetime(s.submitted_at,'unixepoch'),length(s.replay)>0" ++ filter ++ " ORDER BY s.score DESC,s.id ASC LIMIT 50";
        var rows_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, rows_sql, -1, &rows_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(rows_stmt);
        bindBoard(rows_stmt.?, map_md5, mode, namespace, board_type, requested_mods, viewer);
        var rank: i32 = 1;
        while (c.sqlite3_step(rows_stmt) == c.SQLITE_ROW) {
            if (rank > 1) try w.writeByte('\n');
            try writeBoardRow(w, rows_stmt.?, rank);
            rank += 1;
        }
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }
};

fn bindBoard(stmt: *c.sqlite3_stmt, map_md5: []const u8, mode: u8, namespace: []const u8, board_type: u8, mods: i32, viewer: domain.User) void {
    _ = c.sqlite3_bind_text(stmt, 1, map_md5.ptr, @intCast(map_md5.len), null);
    _ = c.sqlite3_bind_int(stmt, 2, mode);
    _ = c.sqlite3_bind_text(stmt, 3, namespace.ptr, @intCast(namespace.len), null);
    _ = c.sqlite3_bind_int(stmt, 4, board_type);
    _ = c.sqlite3_bind_int(stmt, 5, mods);
    _ = c.sqlite3_bind_int(stmt, 6, viewer.id);
    _ = c.sqlite3_bind_text(stmt, 7, &viewer.country, 2, null);
}

fn writeBoardRow(w: *std.Io.Writer, stmt: *c.sqlite3_stmt, rank: i32) !void {
    try w.print("{d}|{s}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{s}|{d}", .{ c.sqlite3_column_int64(stmt, 0), std.mem.span(c.sqlite3_column_text(stmt, 1)), c.sqlite3_column_int64(stmt, 2), c.sqlite3_column_int(stmt, 3), c.sqlite3_column_int(stmt, 4), c.sqlite3_column_int(stmt, 5), c.sqlite3_column_int(stmt, 6), c.sqlite3_column_int(stmt, 7), c.sqlite3_column_int(stmt, 8), c.sqlite3_column_int(stmt, 9), c.sqlite3_column_int(stmt, 10), c.sqlite3_column_int(stmt, 11), c.sqlite3_column_int(stmt, 12), rank, std.mem.span(c.sqlite3_column_text(stmt, 13)), c.sqlite3_column_int(stmt, 14) });
}
