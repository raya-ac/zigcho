const std = @import("std");
const domain = @import("domain.zig");
const postgres = @import("postgres.zig");
const sqlite_storage = @import("storage.zig");
const stable_score = @import("stable_score.zig");
const beatmap = @import("beatmap.zig");
const lazer = @import("lazer.zig");

pub const ClientHardware = sqlite_storage.ClientHardware;
pub const HardwareEnforcement = sqlite_storage.HardwareEnforcement;
pub const is_postgres = true;

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pool: postgres.Pool,

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

    pub const RegistrationConflicts = struct { username: bool, email: bool };
    pub const ServerCounts = struct { users: i64, plays: i64, passed: i64, maps: i64 };
    pub const BeatmapForScore = sqlite_storage.Store.BeatmapForScore;
    pub const BeatmapInfo = sqlite_storage.Store.BeatmapInfo;
    pub const BeatmapRating = sqlite_storage.Store.BeatmapRating;
    pub const PpSnapshot = sqlite_storage.Store.PpSnapshot;
    pub const directStatus = sqlite_storage.Store.directStatus;
    pub const stableStatus = sqlite_storage.Store.stableStatus;
    pub const lazerStatus = sqlite_storage.Store.lazerStatus;

    fn param(buffers: *[32][64]u8, cursor: *usize, value: anytype) ![]u8 {
        if (cursor.* == buffers.len) return error.ParameterBufferExhausted;
        const index = cursor.*;
        cursor.* += 1;
        return std.fmt.bufPrint(&buffers[index], "{d}", .{value});
    }

    pub fn open(allocator: std.mem.Allocator, io: std.Io, conninfo: []const u8) !Store {
        return .{ .allocator = allocator, .io = io, .pool = try postgres.Pool.init(allocator, io, conninfo, postgres.Pool.default_size) };
    }

    pub fn close(self: *Store) void {
        self.pool.deinit();
    }

    pub fn migrate(self: *Store) !void {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.query(lease.conn, "SELECT max(version) FROM zigcho.schema_migrations");
        defer result.deinit();
        if (result.rows() == 0 or result.isNull(0, 0) or try result.int(i32, 0, 0) != 12) return error.UnsupportedSchemaVersion;
    }

    fn userFromResult(allocator: std.mem.Allocator, result: postgres.Result, row: usize) !domain.User {
        const name = try allocator.dupe(u8, result.value(row, 1));
        errdefer allocator.free(name);
        const safe_name = try allocator.dupe(u8, result.value(row, 2));
        errdefer allocator.free(safe_name);
        const country = result.value(row, 3);
        if (country.len != 2) return error.InvalidCountry;
        return .{
            .id = try result.int(i32, row, 0),
            .name = name,
            .safe_name = safe_name,
            .country = .{ country[0], country[1] },
            .privileges = try result.int(u32, row, 4),
            .silence_end = try result.int(i64, row, 5),
            .restricted = try result.boolean(row, 6),
        };
    }

    pub fn register(self: *Store, name: []const u8, email: []const u8, password_md5: []const u8) !i32 {
        const safe = try domain.safeName(self.allocator, name);
        defer self.allocator.free(safe);
        var hash_buffer: [256]u8 = undefined;
        const hash = try std.crypto.pwhash.argon2.strHash(password_md5, .{ .allocator = self.allocator, .params = .owasp_2id }, &hash_buffer, self.io);
        const hash_bytea = try postgres.encodeBytea(self.allocator, hash);
        defer self.allocator.free(hash_bytea);
        const salt_bytea = try postgres.encodeBytea(self.allocator, "argon2id");
        defer self.allocator.free(salt_bytea);
        var random_byte: [1]u8 = undefined;
        try std.Io.randomSecure(self.io, &random_byte);
        var avatar_buf: [2]u8 = undefined;
        const avatar = try std.fmt.bufPrint(&avatar_buf, "{d}", .{1 + (random_byte[0] & 1)});

        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var result = postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.users(name,safe_name,email,password_hash,password_salt,avatar_key) VALUES($1,$2,$3,$4,$5,$6) RETURNING id", &.{ name, safe, email, hash_bytea, salt_bytea, avatar }) catch |err| switch (err) {
            error.UniqueViolation => return error.UserExists,
            else => return err,
        };
        defer result.deinit();
        const id = try result.int(i32, 0, 0);
        var id_buf: [24]u8 = undefined;
        const id_text = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
        var stats_result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.stats(user_id,mode) SELECT $1,mode FROM unnest(ARRAY[0,1,2,3,4,5,6,8]) AS mode", &.{id_text});
        stats_result.deinit();
        try postgres.exec(lease.conn, "COMMIT");
        return id;
    }

    fn restrictUser(allocator: std.mem.Allocator, conn: *postgres.c.PGconn, user_id: i32) !bool {
        if (user_id == 3) return false;
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var result = try postgres.queryParams(allocator, conn, "UPDATE zigcho.users SET restricted=true WHERE id=$1 AND id!=3 AND NOT restricted RETURNING 1", &.{id});
        defer result.deinit();
        return result.rows() != 0;
    }

    fn insertAudit(allocator: std.mem.Allocator, conn: *postgres.c.PGconn, actor_id: i32, action: []const u8, target_user_id: i32, detail: []const u8) !void {
        var actor_buf: [24]u8 = undefined;
        var target_buf: [24]u8 = undefined;
        const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
        const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{target_user_id});
        var result = try postgres.queryParams(allocator, conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) VALUES($1,$2,$3,$4)", &.{ actor, action, target, detail });
        result.deinit();
    }

    pub fn recordClientHardware(self: *Store, user_id: i32, hardware: ClientHardware) !HardwareEnforcement {
        var matched: std.ArrayList(i32) = .empty;
        errdefer matched.deinit(self.allocator);
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        const wine = if (hardware.running_under_wine) "true" else "false";

        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        try postgres.exec(lease.conn, "LOCK TABLE zigcho.client_hardware IN SHARE ROW EXCLUSIVE MODE");

        if (hardware.actionable) {
            var matches = try postgres.queryParams(self.allocator, lease.conn, "SELECT DISTINCT user_id FROM zigcho.client_hardware WHERE user_id!=$1 AND user_id!=3 AND adapters_md5=$2 AND uninstall_md5=$3 AND disk_signature_md5=$4 ORDER BY user_id", &.{ id, hardware.adapters_md5, hardware.uninstall_md5, hardware.disk_signature_md5 });
            defer matches.deinit();
            for (0..matches.rows()) |row| try matched.append(self.allocator, try matches.int(i32, row, 0));
        }

        var upsert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.client_hardware(user_id,osu_path_md5,adapters_md5,uninstall_md5,disk_signature_md5,client_version,running_under_wine) VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(user_id,osu_path_md5,adapters_md5,uninstall_md5,disk_signature_md5) DO UPDATE SET client_version=excluded.client_version,running_under_wine=excluded.running_under_wine,last_seen=extract(epoch FROM clock_timestamp())::bigint,occurrences=zigcho.client_hardware.occurrences+1", &.{ id, hardware.osu_path_md5, hardware.adapters_md5, hardware.uninstall_md5, hardware.disk_signature_md5, hardware.client_version, wine });
        upsert.deinit();

        if (matched.items.len != 0) {
            if (try restrictUser(self.allocator, lease.conn, user_id)) {
                var detail_buf: [128]u8 = undefined;
                const detail = try std.fmt.bufPrint(&detail_buf, "multiaccount_hwid_exact matched_user:{d}", .{matched.items[0]});
                try insertAudit(self.allocator, lease.conn, 3, "account.restrict", user_id, detail);
            }
            for (matched.items) |matched_user_id| {
                if (try restrictUser(self.allocator, lease.conn, matched_user_id)) {
                    var detail_buf: [128]u8 = undefined;
                    const detail = try std.fmt.bufPrint(&detail_buf, "multiaccount_hwid_exact matched_user:{d}", .{user_id});
                    try insertAudit(self.allocator, lease.conn, 3, "account.restrict", matched_user_id, detail);
                }
            }
        }

        const owned_matches = try matched.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_matches);
        try postgres.exec(lease.conn, "COMMIT");
        return .{ .allocator = self.allocator, .matched_user_ids = owned_matches };
    }

    pub fn restrictForClientFlag(self: *Store, user_id: i32, flags: u32) !bool {
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        const changed = try restrictUser(self.allocator, lease.conn, user_id);
        if (changed) {
            var detail_buf: [64]u8 = undefined;
            const detail = try std.fmt.bufPrint(&detail_buf, "stable_lastfm_hq flags:{d}", .{flags});
            try insertAudit(self.allocator, lease.conn, 3, "account.restrict", user_id, detail);
        }
        try postgres.exec(lease.conn, "COMMIT");
        return changed;
    }

    pub fn recordLastFmFlag(self: *Store, user_id: i32, flags: u32) !void {
        var lease = self.pool.acquire();
        defer lease.release();
        var detail_buf: [32]u8 = undefined;
        const detail = try std.fmt.bufPrint(&detail_buf, "flags:{d}", .{flags});
        try insertAudit(self.allocator, lease.conn, user_id, "stable.lastfm_flag", user_id, detail);
    }

    pub fn rateBeatmap(self: *Store, user_id: i32, map_md5: []const u8, rating: ?u8) !BeatmapRating {
        var user_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT status FROM zigcho.beatmaps WHERE md5=$1", &.{map_md5});
        defer map.deinit();
        if (map.rows() == 0) return .no_exist;
        if (try map.int(i32, 0, 0) < 3) return .not_ranked;
        if (rating) |value| {
            if (value < 1 or value > 10) return error.InvalidRating;
            var rating_buf: [4]u8 = undefined;
            const rating_text = try std.fmt.bufPrint(&rating_buf, "{d}", .{value});
            var insert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.ratings(user_id,map_md5,rating) VALUES($1,$2,$3) ON CONFLICT(user_id,map_md5) DO NOTHING", &.{ user, map_md5, rating_text });
            insert.deinit();
        } else {
            var existing = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.ratings WHERE user_id=$1 AND map_md5=$2", &.{ user, map_md5 });
            defer existing.deinit();
            if (existing.rows() == 0) return .can_rate;
        }
        var average = try postgres.queryParams(self.allocator, lease.conn, "SELECT avg(rating) FROM zigcho.ratings WHERE map_md5=$1", &.{map_md5});
        defer average.deinit();
        if (average.rows() == 0 or average.isNull(0, 0)) return error.DatabaseQueryFailed;
        return .{ .already_voted = try average.float(f64, 0, 0) };
    }

    fn upsertBeatmapInner(self: *Store, metadata: beatmap.Metadata, md5: []const u8, status: i8, stars: f64, max_combo: u32, osu_file: ?[]const u8, update_existing: bool) !void {
        var buffers: [32][64]u8 = undefined;
        var cursor: usize = 0;
        const map_id = try param(&buffers, &cursor, metadata.id);
        const set_id = try param(&buffers, &cursor, metadata.set_id);
        const status_text = try param(&buffers, &cursor, status);
        const total_length = try param(&buffers, &cursor, metadata.total_length);
        const combo = try param(&buffers, &cursor, max_combo);
        const mode = try param(&buffers, &cursor, metadata.mode);
        const bpm = try param(&buffers, &cursor, metadata.bpm);
        const cs = try param(&buffers, &cursor, metadata.cs);
        const ar = try param(&buffers, &cursor, metadata.ar);
        const od = try param(&buffers, &cursor, metadata.od);
        const hp = try param(&buffers, &cursor, metadata.hp);
        const star_rating = try param(&buffers, &cursor, stars);
        const circles = try param(&buffers, &cursor, metadata.count_circles);
        const sliders = try param(&buffers, &cursor, metadata.count_sliders);
        const spinners = try param(&buffers, &cursor, metadata.count_spinners);
        var encoded_file: ?[]u8 = null;
        if (osu_file) |bytes| encoded_file = try postgres.encodeBytea(self.allocator, bytes);
        defer if (encoded_file) |bytes| self.allocator.free(bytes);
        const file_param: ?[]const u8 = if (encoded_file) |bytes| bytes else null;
        const sql = if (update_existing)
            "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,last_update,total_length,max_combo,mode,bpm,cs,ar,od,hp,star_rating,source,tags,osu_file,count_circles,count_sliders,count_spinners) VALUES($1,$2,$3,$4,$5,$6,$7,$8,extract(epoch FROM clock_timestamp())::bigint,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23) ON CONFLICT(id) DO UPDATE SET set_id=excluded.set_id,md5=excluded.md5,artist=excluded.artist,title=excluded.title,version=excluded.version,creator=excluded.creator,status=excluded.status,last_update=excluded.last_update,total_length=excluded.total_length,max_combo=excluded.max_combo,mode=excluded.mode,bpm=excluded.bpm,cs=excluded.cs,ar=excluded.ar,od=excluded.od,hp=excluded.hp,star_rating=excluded.star_rating,source=excluded.source,tags=excluded.tags,osu_file=excluded.osu_file,count_circles=excluded.count_circles,count_sliders=excluded.count_sliders,count_spinners=excluded.count_spinners"
        else
            "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,last_update,total_length,max_combo,mode,bpm,cs,ar,od,hp,star_rating,source,tags,osu_file,count_circles,count_sliders,count_spinners) VALUES($1,$2,$3,$4,$5,$6,$7,$8,extract(epoch FROM clock_timestamp())::bigint,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23) ON CONFLICT(id) DO NOTHING";
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{ map_id, set_id, md5, metadata.artist, metadata.title, metadata.version, metadata.creator, status_text, total_length, combo, mode, bpm, cs, ar, od, hp, star_rating, metadata.source, metadata.tags, file_param, circles, sliders, spinners });
        result.deinit();
    }

    pub fn upsertBeatmap(self: *Store, metadata: beatmap.Metadata, md5: []const u8, status: i8, stars: f64, max_combo: u32, osu_file: []const u8) !void {
        return self.upsertBeatmapInner(metadata, md5, status, stars, max_combo, osu_file, true);
    }

    pub fn upsertBeatmapMeta(self: *Store, metadata: beatmap.Metadata, md5: []const u8, status: i8, stars: f64, max_combo: u32) !void {
        return self.upsertBeatmapInner(metadata, md5, status, stars, max_combo, null, false);
    }

    pub fn beatmapFile(self: *Store, allocator: std.mem.Allocator, md5: []const u8) !?[]u8 {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT osu_file FROM zigcho.beatmaps WHERE md5=$1 AND osu_file IS NOT NULL", &.{md5});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try postgres.decodeBytea(allocator, result.value(0, 0));
    }

    pub fn beatmapHasFile(self: *Store, md5: []const u8) !bool {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.beatmaps WHERE md5=$1 AND osu_file IS NOT NULL", &.{md5});
        defer result.deinit();
        return result.rows() != 0;
    }

    pub fn beatmapFileById(self: *Store, allocator: std.mem.Allocator, map_id: i32) !?[]u8 {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{map_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT osu_file FROM zigcho.beatmaps WHERE id=$1 AND osu_file IS NOT NULL", &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try postgres.decodeBytea(allocator, result.value(0, 0));
    }

    pub fn upsertBeatmapArchive(self: *Store, set_id: i32, sha256: []const u8, osz_file: []const u8) !void {
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        const encoded = try postgres.encodeBytea(self.allocator, osz_file);
        defer self.allocator.free(encoded);
        var lease = self.pool.acquire();
        defer lease.release();
        var exists = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.beatmaps WHERE set_id=$1 LIMIT 1", &.{set});
        defer exists.deinit();
        if (exists.rows() == 0) return error.UnknownBeatmapSet;
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_archives(set_id,sha256,osz_file) VALUES($1,$2,$3) ON CONFLICT(set_id) DO UPDATE SET sha256=excluded.sha256,osz_file=excluded.osz_file,imported_at=extract(epoch FROM clock_timestamp())::bigint", &.{ set, sha256, encoded });
        result.deinit();
    }

    pub fn beatmapArchive(self: *Store, allocator: std.mem.Allocator, set_id: i32) !?[]u8 {
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT osz_file FROM zigcho.beatmap_archives WHERE set_id=$1", &.{set});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try postgres.decodeBytea(allocator, result.value(0, 0));
    }

    fn writeDirectText(writer: *std.Io.Writer, value: []const u8) !void {
        for (value) |char| try writer.writeByte(switch (char) {
            '|' => 'I',
            '\r', '\n' => ' ',
            else => char,
        });
    }

    fn appendDirectSet(self: *Store, conn: *postgres.c.PGconn, writer: *std.Io.Writer, set_id: i32) !bool {
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        var set_result = try postgres.queryParams(self.allocator, conn, "SELECT artist,title,creator,status,coalesce(to_char(to_timestamp(last_update) AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI:SS'),'1970-01-01 00:00:00') FROM zigcho.beatmaps WHERE set_id=$1 ORDER BY star_rating LIMIT 1", &.{set});
        defer set_result.deinit();
        if (set_result.rows() == 0) return false;
        try writer.print("{d}.osz|", .{set_id});
        try writeDirectText(writer, set_result.value(0, 0));
        try writer.writeByte('|');
        try writeDirectText(writer, set_result.value(0, 1));
        try writer.writeByte('|');
        try writeDirectText(writer, set_result.value(0, 2));
        try writer.print("|{d}|10.0|{s}|{d}|0|0|0|0|0|", .{ directStatus(try set_result.int(i32, 0, 3)), set_result.value(0, 4), set_id });

        var maps = try postgres.queryParams(self.allocator, conn, "SELECT star_rating,version,cs,od,ar,hp,mode FROM zigcho.beatmaps WHERE set_id=$1 ORDER BY star_rating,id", &.{set});
        defer maps.deinit();
        for (0..maps.rows()) |row| {
            if (row != 0) try writer.writeByte(',');
            try writer.print("[{d:.2}⭐] ", .{try maps.float(f64, row, 0)});
            try writeDirectText(writer, maps.value(row, 1));
            try writer.print(" {{cs: {d} / od: {d} / ar: {d} / hp: {d}}}@{d}", .{ try maps.float(f64, row, 2), try maps.float(f64, row, 3), try maps.float(f64, row, 4), try maps.float(f64, row, 5), try maps.int(i32, row, 6) });
        }
        return true;
    }

    pub fn stableSearch(self: *Store, allocator: std.mem.Allocator, search_query: []const u8, mode: i8, direct_status: u8, page: u16) ![]u8 {
        var mode_buf: [4]u8 = undefined;
        var status_buf: [4]u8 = undefined;
        var offset_buf: [24]u8 = undefined;
        const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
        const status_text = try std.fmt.bufPrint(&status_buf, "{d}", .{direct_status});
        const offset = try std.fmt.bufPrint(&offset_buf, "{d}", .{@as(u32, page) * 100});
        var lease = self.pool.acquire();
        defer lease.release();
        var ids = try postgres.queryParams(self.allocator, lease.conn, "SELECT set_id FROM zigcho.beatmaps WHERE EXISTS(SELECT 1 FROM zigcho.beatmap_archives a WHERE a.set_id=zigcho.beatmaps.set_id) AND ($1::int=-1 OR mode=$1::int) AND ($2='' OR strpos(lower(artist||' '||title||' '||creator||' '||source||' '||tags),lower($2))>0) AND (($3::int=4 AND status IN(3,4,5,6)) OR ($3::int IN(0,7) AND status IN(3,4)) OR ($3::int IN(2,5) AND status=2) OR ($3::int=3 AND status=5) OR ($3::int=8 AND status=6)) GROUP BY set_id ORDER BY max(last_update) DESC,set_id DESC LIMIT 100 OFFSET $4", &.{ mode_text, search_query, status_text, offset });
        defer ids.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{d}", .{if (ids.rows() == 100) @as(usize, 101) else ids.rows()});
        for (0..ids.rows()) |row| {
            try output.writer.writeByte('\n');
            _ = try self.appendDirectSet(lease.conn, &output.writer, try ids.int(i32, row, 0));
        }
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    pub fn stableSearchSet(self: *Store, allocator: std.mem.Allocator, set_id: ?i32, map_id: ?i32, md5: ?[]const u8) ![]u8 {
        var set_buf: [24]u8 = undefined;
        var map_buf: [24]u8 = undefined;
        const set: ?[]const u8 = if (set_id) |value| try std.fmt.bufPrint(&set_buf, "{d}", .{value}) else null;
        const map: ?[]const u8 = if (map_id) |value| try std.fmt.bufPrint(&map_buf, "{d}", .{value}) else null;
        var lease = self.pool.acquire();
        defer lease.release();
        var found = try postgres.queryParams(self.allocator, lease.conn, "SELECT set_id FROM zigcho.beatmaps WHERE ($1::int IS NOT NULL AND set_id=$1::int) OR ($2::int IS NOT NULL AND id=$2::int) OR ($3::text IS NOT NULL AND md5=$3::text) LIMIT 1", &.{ set, map, md5 });
        defer found.deinit();
        if (found.rows() == 0) return allocator.dupe(u8, "");
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        _ = try self.appendDirectSet(lease.conn, &output.writer, try found.int(i32, 0, 0));
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    fn writeBoardRow(writer: *std.Io.Writer, result: postgres.Result, row: usize, rank: i32, uses_pp: bool) !void {
        const score_value: i64 = if (uses_pp) @intFromFloat(try result.float(f64, row, 2)) else try result.int(i64, row, 2);
        try writer.print("{d}|{s}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}", .{
            try result.int(i64, row, 0),
            result.value(row, 1),
            score_value,
            try result.int(i32, row, 3),
            try result.int(i32, row, 4),
            try result.int(i32, row, 5),
            try result.int(i32, row, 6),
            try result.int(i32, row, 7),
            try result.int(i32, row, 8),
            try result.int(i32, row, 9),
            @intFromBool(try result.boolean(row, 10)),
            try result.int(i32, row, 11),
            try result.int(i32, row, 12),
            rank,
            try result.int(i64, row, 13),
            @intFromBool(try result.boolean(row, 14)),
        });
    }

    pub fn stableLeaderboard(self: *Store, allocator: std.mem.Allocator, viewer: domain.User, map_md5: []const u8, mode: u8, board_type: u8, requested_mods: i32) ![]u8 {
        var mode_buf: [4]u8 = undefined;
        var board_buf: [4]u8 = undefined;
        var mods_buf: [16]u8 = undefined;
        var viewer_buf: [24]u8 = undefined;
        const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
        const board = try std.fmt.bufPrint(&board_buf, "{d}", .{board_type});
        const mods = try std.fmt.bufPrint(&mods_buf, "{d}", .{requested_mods});
        const viewer_id = try std.fmt.bufPrint(&viewer_buf, "{d}", .{viewer.id});
        const namespace = if (requested_mods & (1 << 13) != 0) "autopilot" else if (requested_mods & (1 << 7) != 0) "relax" else if (requested_mods & (1 << 27) != 0) "scorev2" else "vanilla";
        const uses_pp = std.mem.eql(u8, namespace, "relax") or std.mem.eql(u8, namespace, "autopilot");
        const filter = " FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id WHERE s.map_md5=$1 AND s.mode=$2 AND s.passed AND s.best AND s.rank_namespace=$3 AND ($4::int!=2 OR s.mods=$5) AND ($4::int!=3 OR s.user_id=$6 OR EXISTS(SELECT 1 FROM zigcho.friends f WHERE f.user_id=$6 AND f.friend_id=s.user_id)) AND ($4::int!=4 OR u.country=$7)";
        const params = &.{ map_md5, mode_text, namespace, board, mods, viewer_id, viewer.country[0..] };
        var lease = self.pool.acquire();
        defer lease.release();
        var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,set_id,status,artist,title,version FROM zigcho.beatmaps WHERE md5=$1", &.{map_md5});
        defer map.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        const writer = &output.writer;
        if (map.rows() == 0) {
            try writer.writeAll("-1|false");
            var missing = output.toArrayList();
            return missing.toOwnedSlice(allocator);
        }
        const map_id = try map.int(i32, 0, 0);
        const set_id = try map.int(i32, 0, 1);
        const status = try map.int(i32, 0, 2);
        const client_status = stableStatus(status);
        if (status < 3) {
            try writer.print("{d}|false", .{client_status});
            var unavailable = output.toArrayList();
            return unavailable.toOwnedSlice(allocator);
        }

        var count = try postgres.queryParams(self.allocator, lease.conn, "SELECT least(count(*),50)" ++ filter, params);
        defer count.deinit();
        const row_count = try count.int(i32, 0, 0);
        try writer.print("{d}|false|{d}|{d}|{d}|0|\n0\n{s} - {s} [{s}]\n0\n", .{ client_status, map_id, set_id, row_count, map.value(0, 3), map.value(0, 4), map.value(0, 5) });

        var personal = try postgres.queryParams(self.allocator, lease.conn, if (uses_pp)
            "SELECT s.id,s.pp" ++ filter ++ " AND s.user_id=$6 ORDER BY s.pp DESC,s.id ASC LIMIT 1"
        else
            "SELECT s.id,s.score" ++ filter ++ " AND s.user_id=$6 ORDER BY s.score DESC,s.id ASC LIMIT 1", params);
        defer personal.deinit();
        if (personal.rows() != 0) {
            const personal_id = try personal.int(i64, 0, 0);
            var metric_buf: [64]u8 = undefined;
            var score_id_buf: [24]u8 = undefined;
            const metric = if (uses_pp)
                try std.fmt.bufPrint(&metric_buf, "{d}", .{try personal.float(f64, 0, 1)})
            else
                try std.fmt.bufPrint(&metric_buf, "{d}", .{try personal.int(i64, 0, 1)});
            const personal_id_text = try std.fmt.bufPrint(&score_id_buf, "{d}", .{personal_id});
            const rank_params = &.{ map_md5, mode_text, namespace, board, mods, viewer_id, viewer.country[0..], metric, personal_id_text };
            var personal_rank = try postgres.queryParams(self.allocator, lease.conn, if (uses_pp)
                "SELECT count(*)+1" ++ filter ++ " AND (s.pp>$8 OR (s.pp=$8 AND s.id<$9))"
            else
                "SELECT count(*)+1" ++ filter ++ " AND (s.score>$8 OR (s.score=$8 AND s.id<$9))", rank_params);
            defer personal_rank.deinit();
            var personal_row = try postgres.queryParams(self.allocator, lease.conn, if (uses_pp)
                "SELECT s.id,u.name,s.pp,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,octet_length(s.replay)>0 FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id WHERE s.id=$1"
            else
                "SELECT s.id,u.name,s.score,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,octet_length(s.replay)>0 FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id WHERE s.id=$1", &.{personal_id_text});
            defer personal_row.deinit();
            if (personal_row.rows() == 0) return error.DatabaseQueryFailed;
            try writeBoardRow(writer, personal_row, 0, try personal_rank.int(i32, 0, 0), uses_pp);
        }
        try writer.writeByte('\n');
        var rows = try postgres.queryParams(self.allocator, lease.conn, if (uses_pp)
            "SELECT s.id,u.name,s.pp,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,octet_length(s.replay)>0" ++ filter ++ " ORDER BY s.pp DESC,s.id ASC LIMIT 50"
        else
            "SELECT s.id,u.name,s.score,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,octet_length(s.replay)>0" ++ filter ++ " ORDER BY s.score DESC,s.id ASC LIMIT 50", params);
        defer rows.deinit();
        for (0..rows.rows()) |row| {
            if (row != 0) try writer.writeByte('\n');
            try writeBoardRow(writer, rows, row, @intCast(row + 1), uses_pp);
        }
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    fn jsonString(writer: *std.Io.Writer, value: []const u8) !void {
        try std.json.Stringify.value(value, .{}, writer);
    }

    fn appendLazerMap(writer: *std.Io.Writer, result: postgres.Result, row: usize) !void {
        try writer.print("{{\"id\":{d},\"beatmapset_id\":{d},\"status\":", .{ try result.int(i32, row, 0), try result.int(i32, row, 1) });
        try jsonString(writer, lazerStatus(try result.int(i32, row, 2)));
        try writer.writeAll(",\"checksum\":");
        try jsonString(writer, result.value(row, 3));
        try writer.print(",\"user_id\":1,\"playcount\":{d},\"passcount\":{d},\"mode_int\":{d},\"difficulty_rating\":{d},\"drain\":{d},\"cs\":{d},\"ar\":{d},\"accuracy\":{d},\"total_length\":{d},\"hit_length\":{d},\"convert\":false,\"count_circles\":{d},\"count_sliders\":{d},\"count_spinners\":{d},\"version\":", .{ try result.int(i32, row, 4), try result.int(i32, row, 5), try result.int(i32, row, 6), try result.float(f64, row, 7), try result.float(f64, row, 8), try result.float(f64, row, 9), try result.float(f64, row, 10), try result.float(f64, row, 11), try result.int(i32, row, 12), try result.int(i32, row, 12), try result.int(i32, row, 17), try result.int(i32, row, 18), try result.int(i32, row, 19) });
        try jsonString(writer, result.value(row, 13));
        try writer.print(",\"max_combo\":{d},\"last_updated\":", .{try result.int(i32, row, 14)});
        try jsonString(writer, result.value(row, 15));
        try writer.print(",\"bpm\":{d},\"owners\":[]}}", .{try result.float(f64, row, 16)});
    }

    fn appendLazerSet(self: *Store, conn: *postgres.c.PGconn, writer: *std.Io.Writer, set_id: i32) !bool {
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        var set_result = try postgres.queryParams(self.allocator, conn, "SELECT set_id,min(artist),min(title),min(creator),min(status),max(bpm),min(source),min(tags),coalesce(to_char(to_timestamp(max(last_update)) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z'),NOT EXISTS(SELECT 1 FROM zigcho.beatmap_archives a WHERE a.set_id=$1),sum(plays) FROM zigcho.beatmaps WHERE set_id=$1 GROUP BY set_id", &.{set});
        defer set_result.deinit();
        if (set_result.rows() == 0) return false;
        try writer.print("{{\"id\":{d},\"status\":", .{set_id});
        try jsonString(writer, lazerStatus(try set_result.int(i32, 0, 4)));
        try writer.writeAll(",\"title\":");
        try jsonString(writer, set_result.value(0, 2));
        try writer.writeAll(",\"title_unicode\":");
        try jsonString(writer, set_result.value(0, 2));
        try writer.writeAll(",\"artist\":");
        try jsonString(writer, set_result.value(0, 1));
        try writer.writeAll(",\"artist_unicode\":");
        try jsonString(writer, set_result.value(0, 1));
        try writer.writeAll(",\"creator\":");
        try jsonString(writer, set_result.value(0, 3));
        try writer.print(",\"user_id\":1,\"covers\":{{\"cover\":\"\",\"cover@2x\":\"\",\"card\":\"\",\"card@2x\":\"\",\"list\":\"\",\"list@2x\":\"\"}},\"preview_url\":\"\",\"play_count\":{d},\"favourite_count\":0,\"bpm\":{d},\"nsfw\":false,\"spotlight\":false,\"video\":false,\"storyboard\":false,\"submitted_date\":", .{ try set_result.int(i64, 0, 10), try set_result.float(f64, 0, 5) });
        try jsonString(writer, set_result.value(0, 8));
        try writer.writeAll(",\"last_updated\":");
        try jsonString(writer, set_result.value(0, 8));
        try writer.print(",\"ranked_date\":null,\"ratings\":[],\"availability\":{{\"download_disabled\":{s},\"more_information\":\"\"}},\"genre\":{{\"id\":0,\"name\":\"Unspecified\"}},\"language\":{{\"id\":0,\"name\":\"Unspecified\"}},\"source\":", .{if (try set_result.boolean(0, 9)) "true" else "false"});
        try jsonString(writer, set_result.value(0, 6));
        try writer.writeAll(",\"tags\":");
        try jsonString(writer, set_result.value(0, 7));
        try writer.writeAll(",\"beatmaps\":[");
        var maps = try postgres.queryParams(self.allocator, conn, "SELECT id,set_id,status,md5,plays,passes,mode,star_rating,hp,cs,ar,od,total_length,version,max_combo,coalesce(to_char(to_timestamp(last_update) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z'),bpm,count_circles,count_sliders,count_spinners FROM zigcho.beatmaps WHERE set_id=$1 ORDER BY star_rating,id", &.{set});
        defer maps.deinit();
        for (0..maps.rows()) |row| {
            if (row != 0) try writer.writeByte(',');
            try appendLazerMap(writer, maps, row);
        }
        try writer.writeAll("]}");
        return true;
    }

    pub fn lazerBeatmapSet(self: *Store, allocator: std.mem.Allocator, set_id: i32) !?[]u8 {
        var lease = self.pool.acquire();
        defer lease.release();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        if (!try self.appendLazerSet(lease.conn, &output.writer, set_id)) {
            output.deinit();
            return null;
        }
        var list = output.toArrayList();
        return try list.toOwnedSlice(allocator);
    }

    pub fn lazerBeatmapSearch(self: *Store, allocator: std.mem.Allocator, search_query: []const u8, mode: i8, offset: u16) ![]u8 {
        var mode_buf: [4]u8 = undefined;
        var offset_buf: [24]u8 = undefined;
        const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
        const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
        var lease = self.pool.acquire();
        defer lease.release();
        var ids = try postgres.queryParams(self.allocator, lease.conn, "SELECT set_id FROM zigcho.beatmaps WHERE ($1::int=-1 OR mode=$1::int) AND ($2='' OR strpos(lower(artist||' '||title||' '||creator||' '||source||' '||tags),lower($2))>0) GROUP BY set_id ORDER BY max(last_update) DESC,set_id DESC LIMIT 50 OFFSET $3", &.{ mode_text, search_query, offset_text });
        defer ids.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"beatmapsets\":[");
        for (0..ids.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            _ = try self.appendLazerSet(lease.conn, &output.writer, try ids.int(i32, row, 0));
        }
        try output.writer.print("],\"total\":{d},\"cursor\":null}}", .{ids.rows()});
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    pub fn registrationConflicts(self: *Store, name: []const u8, email: []const u8) !RegistrationConflicts {
        const safe = try domain.safeName(self.allocator, name);
        defer self.allocator.free(safe);
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT EXISTS(SELECT 1 FROM zigcho.users WHERE safe_name=$1),EXISTS(SELECT 1 FROM zigcho.users WHERE email=$2)", &.{ safe, email });
        defer result.deinit();
        return .{ .username = try result.boolean(0, 0), .email = try result.boolean(0, 1) };
    }

    pub fn avatarForUser(self: *Store, user_id: i32) !?u8 {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT avatar_key FROM zigcho.users WHERE id=$1", &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        const key = try result.int(u8, 0, 0);
        if (key < 1 or key > 2) return error.InvalidAvatarKey;
        return key;
    }

    fn credentialForSafeName(self: *Store, allocator: std.mem.Allocator, safe: []const u8) !?Credential {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,name,safe_name,country,privileges,silence_end,restricted,password_hash,password_salt FROM zigcho.users WHERE safe_name=$1", &.{safe});
        defer result.deinit();
        if (result.rows() == 0) return null;
        const user = try userFromResult(allocator, result, 0);
        errdefer {
            allocator.free(user.name);
            allocator.free(user.safe_name);
        }
        const password_hash = try postgres.decodeBytea(allocator, result.value(0, 7));
        errdefer allocator.free(password_hash);
        const password_salt = try postgres.decodeBytea(allocator, result.value(0, 8));
        return .{ .allocator = allocator, .user = user, .password_hash = password_hash, .password_salt = password_salt };
    }

    pub fn authenticate(self: *Store, allocator: std.mem.Allocator, name: []const u8, password_md5: []const u8) !?domain.User {
        const safe = try domain.safeName(allocator, name);
        defer allocator.free(safe);
        var credential = (try self.credentialForSafeName(allocator, safe)) orelse return null;
        defer credential.deinit();
        var upgrade = false;
        if (credential.password_hash.len > 0 and credential.password_hash[0] == '$') {
            std.crypto.pwhash.argon2.strVerify(credential.password_hash, password_md5, .{ .allocator = allocator }, self.io) catch return null;
        } else {
            var actual: [32]u8 = undefined;
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hash.update(credential.password_salt);
            hash.update(password_md5);
            hash.final(&actual);
            if (credential.password_hash.len != 32 or !std.crypto.timing_safe.eql([32]u8, actual, credential.password_hash[0..32].*)) return null;
            upgrade = true;
        }
        const user_id = credential.user.?.id;
        if (upgrade) try self.upgradePassword(user_id, password_md5, credential.password_hash);
        return credential.takeUser();
    }

    fn upgradePassword(self: *Store, user_id: i32, password_md5: []const u8, previous_hash: []const u8) !void {
        var hash_buffer: [256]u8 = undefined;
        const hash = try std.crypto.pwhash.argon2.strHash(password_md5, .{ .allocator = self.allocator, .params = .owasp_2id }, &hash_buffer, self.io);
        const hash_bytea = try postgres.encodeBytea(self.allocator, hash);
        defer self.allocator.free(hash_bytea);
        const salt_bytea = try postgres.encodeBytea(self.allocator, "argon2id");
        defer self.allocator.free(salt_bytea);
        const previous_bytea = try postgres.encodeBytea(self.allocator, previous_hash);
        defer self.allocator.free(previous_bytea);
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET password_hash=$1,password_salt=$2 WHERE id=$3 AND password_hash=$4", &.{ hash_bytea, salt_bytea, id, previous_bytea });
        result.deinit();
    }

    pub fn userById(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?domain.User {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,name,safe_name,country,privileges,silence_end,restricted FROM zigcho.users WHERE id=$1", &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try userFromResult(allocator, result, 0);
    }

    pub fn updateCountry(self: *Store, user_id: i32, value: [2]u8) !void {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET country=$1,last_login=extract(epoch FROM clock_timestamp())::bigint WHERE id=$2", &.{ value[0..], id });
        result.deinit();
    }

    pub fn serverCounts(self: *Store) !ServerCounts {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.query(lease.conn, "SELECT (SELECT count(*) FROM zigcho.users WHERE id!=3),(SELECT count(*) FROM zigcho.scores)+(SELECT count(*) FROM zigcho.lazer_scores),(SELECT count(*) FROM zigcho.scores WHERE passed)+(SELECT count(*) FROM zigcho.lazer_scores WHERE passed),(SELECT count(*) FROM zigcho.beatmaps)");
        defer result.deinit();
        return .{ .users = try result.int(i64, 0, 0), .plays = try result.int(i64, 0, 1), .passed = try result.int(i64, 0, 2), .maps = try result.int(i64, 0, 3) };
    }

    pub fn insertLazerScore(self: *Store, user_id: i32, input: lazer.ScoreInput, raw_json: []const u8) !i64 {
        var buffers: [32][64]u8 = undefined;
        var cursor: usize = 0;
        const user = try param(&buffers, &cursor, user_id);
        const beatmap_id = try param(&buffers, &cursor, input.beatmap_id);
        const ruleset_id = try param(&buffers, &cursor, input.ruleset_id);
        const total_score = try param(&buffers, &cursor, input.total_score);
        const legacy_total_score: ?[]const u8 = if (input.legacy_total_score) |value| try param(&buffers, &cursor, value) else null;
        const accuracy = try param(&buffers, &cursor, input.accuracy);
        const max_combo = try param(&buffers, &cursor, input.max_combo);
        const passed = if (input.passed) "true" else "false";
        const namespace = @tagName(input.namespace);
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_scores(user_id,beatmap_id,ruleset_id,total_score,legacy_total_score,accuracy,max_combo,passed,mods_json,statistics_json,rank_namespace,client_version) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb,$10::jsonb,$11,$12) RETURNING id", &.{ user, beatmap_id, ruleset_id, total_score, legacy_total_score, accuracy, max_combo, passed, raw_json, raw_json, namespace, input.client_version });
        defer result.deinit();
        return result.int(i64, 0, 0);
    }

    pub fn statsForUser(self: *Store, user_id: i32, mode: u8) !?domain.Stats {
        var id_buf: [24]u8 = undefined;
        var mode_buf: [4]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,(SELECT count(1)+1 FROM zigcho.stats r JOIN zigcho.users u ON u.id=r.user_id WHERE r.mode=s.mode AND NOT u.restricted AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) FROM zigcho.stats s WHERE s.user_id=$1 AND s.mode=$2", &.{ id, mode_text });
        defer result.deinit();
        if (result.rows() == 0) return null;
        return .{ .mode = @enumFromInt(mode % 4), .ranked_score = try result.int(i64, 0, 0), .total_score = try result.int(i64, 0, 1), .pp = try result.int(i32, 0, 2), .plays = try result.int(i32, 0, 3), .play_time = try result.int(i32, 0, 4), .total_hits = try result.int(i64, 0, 5), .accuracy = try result.float(f64, 0, 6), .max_combo = try result.int(i32, 0, 7), .global_rank = try result.int(i32, 0, 8) };
    }

    pub fn beatmapForScore(self: *Store, md5: []const u8) !?BeatmapForScore {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,set_id,status,plays,passes FROM zigcho.beatmaps WHERE md5=$1", &.{md5});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return .{ .id = try result.int(i32, 0, 0), .set_id = try result.int(i32, 0, 1), .status = try result.int(i8, 0, 2), .plays = try result.int(i32, 0, 3), .passes = try result.int(i32, 0, 4) };
    }

    pub fn scoreRankOnMap(self: *Store, md5: []const u8, mode: u8, namespace: []const u8, score_value: i64, pp_value: f64) i32 {
        var mode_buf: [4]u8 = undefined;
        var metric_buf: [64]u8 = undefined;
        const mode_text = std.fmt.bufPrint(&mode_buf, "{d}", .{mode}) catch return 999;
        const vanilla = std.mem.eql(u8, namespace, "vanilla");
        const metric = if (vanilla)
            std.fmt.bufPrint(&metric_buf, "{d}", .{score_value}) catch return 999
        else
            std.fmt.bufPrint(&metric_buf, "{d}", .{pp_value}) catch return 999;
        var lease = self.pool.acquire();
        defer lease.release();
        var result = postgres.queryParams(self.allocator, lease.conn, if (vanilla)
            "SELECT count(*) FROM zigcho.scores WHERE map_md5=$1 AND mode=$2 AND rank_namespace=$3 AND passed AND score>$4"
        else
            "SELECT count(*) FROM zigcho.scores WHERE map_md5=$1 AND mode=$2 AND rank_namespace=$3 AND passed AND pp>$4", &.{ md5, mode_text, namespace, metric }) catch return 999;
        defer result.deinit();
        return result.int(i32, 0, 0) catch 999;
    }

    pub fn beatmapInfo(self: *Store, allocator: std.mem.Allocator, md5: []const u8) !?BeatmapInfo {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,set_id,max_combo,artist,title,version,star_rating FROM zigcho.beatmaps WHERE md5=$1", &.{md5});
        defer result.deinit();
        if (result.rows() == 0) return null;
        const artist = try allocator.dupe(u8, result.value(0, 3));
        errdefer allocator.free(artist);
        const title = try allocator.dupe(u8, result.value(0, 4));
        errdefer allocator.free(title);
        const version = try allocator.dupe(u8, result.value(0, 5));
        return .{ .id = try result.int(i32, 0, 0), .set_id = try result.int(i32, 0, 1), .max_combo = try result.int(i32, 0, 2), .artist = artist, .title = title, .version = version, .star_rating = try result.float(f64, 0, 6) };
    }

    pub fn insertStableScore(self: *Store, user_id: i32, score: stable_score.Submission, pp_value: f64, replay_data: []const u8, time_elapsed_ms: u32) !i64 {
        const stats_mode = stable_score.statsMode(score.mode, score.mods) orelse return error.UnsupportedModMode;
        const namespace = score.rankNamespace();
        const replay_encoded = try postgres.encodeBytea(self.allocator, replay_data);
        defer self.allocator.free(replay_encoded);

        var user_buf: [24]u8 = undefined;
        var mode_buf: [4]u8 = undefined;
        var stats_mode_buf: [4]u8 = undefined;
        var mods_buf: [16]u8 = undefined;
        var score_buf: [32]u8 = undefined;
        var pp_buf: [64]u8 = undefined;
        var accuracy_buf: [64]u8 = undefined;
        var combo_buf: [16]u8 = undefined;
        var n300_buf: [16]u8 = undefined;
        var n100_buf: [16]u8 = undefined;
        var n50_buf: [16]u8 = undefined;
        var nmiss_buf: [16]u8 = undefined;
        var ngeki_buf: [16]u8 = undefined;
        var nkatu_buf: [16]u8 = undefined;
        var elapsed_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const mode = try std.fmt.bufPrint(&mode_buf, "{d}", .{score.mode});
        const stats_mode_text = try std.fmt.bufPrint(&stats_mode_buf, "{d}", .{stats_mode});
        const mods = try std.fmt.bufPrint(&mods_buf, "{d}", .{score.mods});
        const score_text = try std.fmt.bufPrint(&score_buf, "{d}", .{score.total_score});
        const pp = try std.fmt.bufPrint(&pp_buf, "{d}", .{pp_value});
        const accuracy = try std.fmt.bufPrint(&accuracy_buf, "{d}", .{score.accuracy()});
        const combo = try std.fmt.bufPrint(&combo_buf, "{d}", .{score.max_combo});
        const n300 = try std.fmt.bufPrint(&n300_buf, "{d}", .{score.n300});
        const n100 = try std.fmt.bufPrint(&n100_buf, "{d}", .{score.n100});
        const n50 = try std.fmt.bufPrint(&n50_buf, "{d}", .{score.n50});
        const nmiss = try std.fmt.bufPrint(&nmiss_buf, "{d}", .{score.nmiss});
        const ngeki = try std.fmt.bufPrint(&ngeki_buf, "{d}", .{score.ngeki});
        const nkatu = try std.fmt.bufPrint(&nkatu_buf, "{d}", .{score.nkatu});
        const elapsed = try std.fmt.bufPrint(&elapsed_buf, "{d}", .{time_elapsed_ms});

        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var stats_lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.stats WHERE user_id=$1 AND mode=$2 FOR UPDATE", &.{ user, stats_mode_text });
        defer stats_lock.deinit();
        if (stats_lock.rows() == 0) return error.DatabaseQueryFailed;

        var previous_best_id: i64 = 0;
        var previous_best_score: i64 = 0;
        var previous_best_pp: f64 = 0;
        var previous = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,score,pp FROM zigcho.scores WHERE user_id=$1 AND map_md5=$2 AND mode=$3 AND rank_namespace=$4 AND best LIMIT 1", &.{ user, score.map_md5, mode, namespace });
        defer previous.deinit();
        if (previous.rows() != 0) {
            previous_best_id = try previous.int(i64, 0, 0);
            previous_best_score = try previous.int(i64, 0, 1);
            previous_best_pp = try previous.float(f64, 0, 2);
        }
        const uses_pp = !std.mem.eql(u8, namespace, "vanilla");
        const is_best = score.passed and if (uses_pp) pp_value > previous_best_pp else score.total_score > previous_best_score;
        const perfect = if (score.perfect) "true" else "false";
        const passed = if (score.passed) "true" else "false";
        const best = if (is_best) "true" else "false";
        var inserted = postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,checksum,rank_namespace,best,time_elapsed) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21) RETURNING id", &.{ user, score.map_md5, mode, mods, score_text, pp, accuracy, combo, n300, n100, n50, nmiss, ngeki, nkatu, perfect, passed, replay_encoded, score.online_checksum, namespace, best, elapsed }) catch |err| switch (err) {
            error.UniqueViolation => return error.DuplicateScore,
            else => return err,
        };
        defer inserted.deinit();
        const score_id = try inserted.int(i64, 0, 0);

        if (is_best and previous_best_id != 0) {
            var previous_buf: [24]u8 = undefined;
            const previous_id = try std.fmt.bufPrint(&previous_buf, "{d}", .{previous_best_id});
            var unset = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.scores SET best=false WHERE id=$1", &.{previous_id});
            unset.deinit();
        }
        var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT status FROM zigcho.beatmaps WHERE md5=$1 FOR UPDATE", &.{score.map_md5});
        defer map.deinit();
        if (map.rows() == 0) return error.DatabaseQueryFailed;
        const map_status = try map.int(i32, 0, 0);
        const leaderboard = map_status >= 3;
        const ranked = map_status == 3 or map_status == 4;
        const ranked_delta: i64 = if (is_best and ranked) score.total_score - previous_best_score else 0;
        const total_hits: i64 = @as(i64, score.n300) + score.n100 + score.n50 + if (score.mode == 1 or score.mode == 3) @as(i64, score.ngeki) + score.nkatu else 0;
        var ranked_buf: [32]u8 = undefined;
        var seconds_buf: [24]u8 = undefined;
        var hits_buf: [32]u8 = undefined;
        const ranked_text = try std.fmt.bufPrint(&ranked_buf, "{d}", .{ranked_delta});
        const seconds = try std.fmt.bufPrint(&seconds_buf, "{d}", .{time_elapsed_ms / 1000});
        const hits = try std.fmt.bufPrint(&hits_buf, "{d}", .{total_hits});
        var update_stats = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.stats SET total_score=total_score+$1,ranked_score=ranked_score+$2,plays=plays+1,play_time=play_time+$3,total_hits=total_hits+$4,max_combo=CASE WHEN $5::boolean THEN greatest(max_combo,$6) ELSE max_combo END WHERE user_id=$7 AND mode=$8", &.{ score_text, ranked_text, seconds, hits, if (score.passed and leaderboard) "true" else "false", combo, user, stats_mode_text });
        update_stats.deinit();
        var update_map = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmaps SET plays=plays+1,passes=passes+$1 WHERE md5=$2", &.{ if (score.passed) "1" else "0", score.map_md5 });
        update_map.deinit();

        if (is_best and ranked) {
            var weighted = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.pp,s.accuracy FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 AND s.mode=$2 AND s.passed AND s.best AND s.rank_namespace=$3 AND b.status IN (3,4) ORDER BY s.pp DESC,s.id ASC", &.{ user, mode, namespace });
            defer weighted.deinit();
            var total_pp: f64 = 0;
            var weighted_accuracy: f64 = 0;
            var weight: f64 = 1;
            for (0..weighted.rows()) |row| {
                total_pp += try weighted.float(f64, row, 0) * weight;
                weighted_accuracy += try weighted.float(f64, row, 1) * weight;
                weight *= 0.95;
            }
            const count: f64 = @floatFromInt(weighted.rows());
            const bonus_pp = 416.6667 * (1.0 - std.math.pow(f64, 0.9994, count));
            const bonus_accuracy = 1.0 / (20.0 * (1.0 - std.math.pow(f64, 0.95, count)));
            var player_pp_buf: [32]u8 = undefined;
            var player_acc_buf: [64]u8 = undefined;
            const player_pp = try std.fmt.bufPrint(&player_pp_buf, "{d}", .{@as(i64, @intFromFloat(@round(total_pp + bonus_pp)))});
            const player_accuracy = try std.fmt.bufPrint(&player_acc_buf, "{d}", .{weighted_accuracy * bonus_accuracy});
            var update_pp = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.stats SET pp=$1,accuracy=$2 WHERE user_id=$3 AND mode=$4", &.{ player_pp, player_accuracy, user, stats_mode_text });
            update_pp.deinit();
        }
        try postgres.exec(lease.conn, "COMMIT");
        return score_id;
    }

    pub fn replay(self: *Store, allocator: std.mem.Allocator, score_id: i64) !?[]u8 {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{score_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT replay FROM zigcho.scores WHERE id=$1 AND replay IS NOT NULL", &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try postgres.decodeBytea(allocator, result.value(0, 0));
    }

    pub fn ppSnapshot(self: *Store, score_id: i64) !?PpSnapshot {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{score_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.pp,t.pp FROM zigcho.scores s JOIN zigcho.stats t ON t.user_id=s.user_id AND t.mode=CASE WHEN (s.mods&8192)!=0 THEN s.mode+8 WHEN (s.mods&128)!=0 THEN s.mode+4 ELSE s.mode END WHERE s.id=$1", &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return .{ .score = try result.float(f64, 0, 0), .player = try result.int(i64, 0, 1) };
    }

    pub fn issueToken(self: *Store, user_id: i32, scopes: []const u8, lifetime_seconds: i64) ![64]u8 {
        var raw: [32]u8 = undefined;
        try std.Io.randomSecure(self.io, &raw);
        var token: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&token, "{x}", .{raw}) catch unreachable;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&token, &digest, .{});
        const digest_bytea = try postgres.encodeBytea(self.allocator, &digest);
        defer self.allocator.free(digest_bytea);
        var id_buf: [24]u8 = undefined;
        var expiry_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        const expiry = try std.fmt.bufPrint(&expiry_buf, "{d}", .{std.Io.Clock.real.now(self.io).toSeconds() + lifetime_seconds});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.oauth_tokens(token_hash,user_id,scopes,expires_at) VALUES($1,$2,$3,$4)", &.{ digest_bytea, id, scopes, expiry });
        result.deinit();
        return token;
    }

    pub fn authenticateToken(self: *Store, allocator: std.mem.Allocator, token: []const u8, required_scope: []const u8) !?domain.User {
        if (token.len != 64) return null;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
        const digest_bytea = try postgres.encodeBytea(self.allocator, &digest);
        defer self.allocator.free(digest_bytea);
        var now_buf: [32]u8 = undefined;
        const now = try std.fmt.bufPrint(&now_buf, "{d}", .{std.Io.Clock.real.now(self.io).toSeconds()});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,t.scopes FROM zigcho.oauth_tokens t JOIN zigcho.users u ON u.id=t.user_id WHERE t.token_hash=$1 AND t.revoked_at IS NULL AND t.expires_at>$2", &.{ digest_bytea, now });
        defer result.deinit();
        if (result.rows() == 0) return null;
        var allowed = required_scope.len == 0;
        var scopes = std.mem.splitScalar(u8, result.value(0, 7), ' ');
        while (scopes.next()) |scope| if (std.mem.eql(u8, scope, required_scope) or std.mem.eql(u8, scope, "*")) {
            allowed = true;
            break;
        };
        if (!allowed) return null;
        return try userFromResult(allocator, result, 0);
    }

    pub fn revokeToken(self: *Store, token: []const u8) !bool {
        if (token.len != 64) return false;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
        const digest_bytea = try postgres.encodeBytea(self.allocator, &digest);
        defer self.allocator.free(digest_bytea);
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE token_hash=$1 AND revoked_at IS NULL RETURNING 1", &.{digest_bytea});
        defer result.deinit();
        return result.rows() != 0;
    }
};

test "postgres account auth stats and token slice" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_STORE_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    const user_id = try store.register("ari", "ari@example.test", "00000000000000000000000000000000");
    try std.testing.expect((try store.registrationConflicts("ari", "ari@example.test")).username);
    try std.testing.expect((try store.avatarForUser(user_id)) != null);
    const user = (try store.authenticate(std.testing.allocator, "ari", "00000000000000000000000000000000")).?;
    defer {
        std.testing.allocator.free(user.name);
        std.testing.allocator.free(user.safe_name);
    }
    try std.testing.expectEqual(user_id, user.id);
    try store.updateCountry(user_id, .{ 'A', 'U' });
    const stats = (try store.statsForUser(user_id, 0)).?;
    try std.testing.expectEqual(@as(i32, 0), stats.pp);
    const token = try store.issueToken(user_id, "identify scores:write", 60);
    const token_user = (try store.authenticateToken(std.testing.allocator, &token, "identify")).?;
    std.testing.allocator.free(token_user.name);
    std.testing.allocator.free(token_user.safe_name);
    try std.testing.expect(try store.revokeToken(&token));
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &token, "identify")) == null);

    {
        var lease = store.pool.acquire();
        defer lease.release();
        var map_insert = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,max_combo) VALUES(1,1,$1,'artist','title','hard','mapper',3,10)", &.{"0123456789abcdef0123456789abcdef"});
        map_insert.deinit();
    }
    const score: stable_score.Submission = .{
        .map_md5 = "0123456789abcdef0123456789abcdef",
        .username = "ari",
        .online_checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .ngeki = 0,
        .nkatu = 0,
        .nmiss = 0,
        .total_score = 1_000_000,
        .max_combo = 10,
        .perfect = true,
        .grade = "X",
        .mods = 0,
        .passed = true,
        .mode = 0,
        .client_time = "260811000000",
        .client_flags = "0",
    };
    const score_id = try store.insertStableScore(user_id, score, 26.8, "replay", 12_000);
    const snapshot = (try store.ppSnapshot(score_id)).?;
    try std.testing.expectApproxEqAbs(@as(f64, 26.8), snapshot.score, 0.001);
    try std.testing.expectEqual(@as(i64, 27), snapshot.player);
    const replay = (try store.replay(std.testing.allocator, score_id)).?;
    defer std.testing.allocator.free(replay);
    try std.testing.expectEqualStrings("replay", replay);
    const after_pass = (try store.statsForUser(user_id, 0)).?;
    try std.testing.expectEqual(@as(i64, 1_000_000), after_pass.ranked_score);
    try std.testing.expectEqual(@as(i32, 27), after_pass.pp);
    try std.testing.expectEqual(@as(i32, 1), after_pass.plays);
    var failed = score;
    failed.online_checksum = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    failed.total_score = 200_000;
    failed.n300 = 4;
    failed.n100 = 3;
    failed.nmiss = 9;
    failed.max_combo = 99;
    failed.perfect = false;
    failed.grade = "F";
    failed.passed = false;
    _ = try store.insertStableScore(user_id, failed, 999, "", 45_123);
    const after_fail = (try store.statsForUser(user_id, 0)).?;
    try std.testing.expectEqual(after_pass.ranked_score, after_fail.ranked_score);
    try std.testing.expectEqual(after_pass.pp, after_fail.pp);
    try std.testing.expectEqual(@as(i64, 1_200_000), after_fail.total_score);
    try std.testing.expectEqual(@as(i32, 2), after_fail.plays);
    try std.testing.expectEqual(after_pass.max_combo, after_fail.max_combo);
    var relax = score;
    relax.online_checksum = "cccccccccccccccccccccccccccccccc";
    relax.total_score = 600_000;
    relax.mods = 128;
    _ = try store.insertStableScore(user_id, relax, 42.5, "relax replay", 15_000);
    const relax_stats = (try store.statsForUser(user_id, 4)).?;
    try std.testing.expectEqual(@as(i64, 600_000), relax_stats.ranked_score);
    try std.testing.expectEqual(@as(i32, 43), relax_stats.pp);
    const vanilla_board = try store.stableLeaderboard(std.testing.allocator, user, score.map_md5, 0, 0, 0);
    defer std.testing.allocator.free(vanilla_board);
    try std.testing.expect(std.mem.indexOf(u8, vanilla_board, "artist - title [hard]") != null);
    try std.testing.expect(std.mem.indexOf(u8, vanilla_board, "|ari|1000000|") != null);
    const relax_board = try store.stableLeaderboard(std.testing.allocator, user, score.map_md5, 0, 0, 128);
    defer std.testing.allocator.free(relax_board);
    try std.testing.expect(std.mem.indexOf(u8, relax_board, "|ari|42|") != null);

    const metadata: beatmap.Metadata = .{
        .id = 2,
        .set_id = 2,
        .artist = "artist two",
        .title = "title two",
        .version = "insane",
        .creator = "mapper",
        .source = "source",
        .tags = "some tags",
        .hp = 5,
        .cs = 4,
        .od = 8,
        .ar = 9,
        .bpm = 180,
        .total_length = 90,
        .count_circles = 10,
        .count_sliders = 20,
        .count_spinners = 1,
    };
    const second_md5 = "fedcba9876543210fedcba9876543210";
    try store.upsertBeatmapMeta(metadata, second_md5, 3, 5.25, 300);
    try std.testing.expect(!try store.beatmapHasFile(second_md5));
    try store.upsertBeatmap(metadata, second_md5, 3, 5.25, 300, "osu file bytes");
    try std.testing.expect(try store.beatmapHasFile(second_md5));
    const map_file = (try store.beatmapFileById(std.testing.allocator, 2)).?;
    defer std.testing.allocator.free(map_file);
    try std.testing.expectEqualStrings("osu file bytes", map_file);
    try store.upsertBeatmapArchive(2, "fixture-sha256", "osz archive bytes");
    const archive = (try store.beatmapArchive(std.testing.allocator, 2)).?;
    defer std.testing.allocator.free(archive);
    try std.testing.expectEqualStrings("osz archive bytes", archive);
    const direct = try store.stableSearch(std.testing.allocator, "title two", -1, 4, 0);
    defer std.testing.allocator.free(direct);
    try std.testing.expect(std.mem.indexOf(u8, direct, "2.osz|artist two|title two|mapper") != null);
    const direct_set = try store.stableSearchSet(std.testing.allocator, null, null, second_md5);
    defer std.testing.allocator.free(direct_set);
    try std.testing.expect(std.mem.startsWith(u8, direct_set, "2.osz|"));
    const lazer_set = (try store.lazerBeatmapSet(std.testing.allocator, 2)).?;
    defer std.testing.allocator.free(lazer_set);
    try std.testing.expect(std.mem.indexOf(u8, lazer_set, "\"title\":\"title two\"") != null);
    const lazer_search = try store.lazerBeatmapSearch(std.testing.allocator, "title two", 0, 0);
    defer std.testing.allocator.free(lazer_search);
    try std.testing.expect(std.mem.indexOf(u8, lazer_search, "\"beatmapsets\":[{") != null);
    const raw_lazer_score = "{\"beatmap_id\":2,\"ruleset_id\":0,\"total_score\":1234,\"accuracy\":0.98,\"max_combo\":25,\"passed\":true,\"mods\":[],\"statistics\":{},\"client_version\":\"2026.811.0\"}";
    const parsed_lazer = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw_lazer_score, .{});
    defer parsed_lazer.deinit();
    try std.testing.expect(try store.insertLazerScore(user_id, try lazer.parseScore(parsed_lazer.value), raw_lazer_score) > 0);
    try std.testing.expectEqual(Store.BeatmapRating.can_rate, try store.rateBeatmap(user_id, second_md5, null));
    const vote = try store.rateBeatmap(user_id, second_md5, 8);
    try std.testing.expectApproxEqAbs(@as(f64, 8), vote.already_voted, 0.001);

    const second_id = try store.register("raya", "raya@example.test", "11111111111111111111111111111111");
    const hardware: ClientHardware = .{
        .osu_path_md5 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .adapters_md5 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .uninstall_md5 = "cccccccccccccccccccccccccccccccc",
        .disk_signature_md5 = "dddddddddddddddddddddddddddddddd",
        .client_version = "b20260811",
        .running_under_wine = false,
        .actionable = true,
    };
    var first_hardware = try store.recordClientHardware(user_id, hardware);
    defer first_hardware.deinit();
    try std.testing.expect(!first_hardware.restricted());
    var second_hardware = try store.recordClientHardware(second_id, hardware);
    defer second_hardware.deinit();
    try std.testing.expect(second_hardware.restricted());
    try std.testing.expectEqual(user_id, second_hardware.matched_user_ids[0]);
    const restricted_first = (try store.userById(std.testing.allocator, user_id)).?;
    defer {
        std.testing.allocator.free(restricted_first.name);
        std.testing.allocator.free(restricted_first.safe_name);
    }
    try std.testing.expect(restricted_first.restricted);
    try std.testing.expect(!try store.restrictForClientFlag(user_id, 1 << 19));
    try store.recordLastFmFlag(user_id, 1 << 19);
}
