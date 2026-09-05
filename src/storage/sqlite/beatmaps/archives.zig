const std = @import("std");
const object_keys = @import("../../../object_keys.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const BeatmapArchiveDownload = @import("../../contracts.zig").BeatmapArchiveDownload;
const BeatmapCacheStats = @import("../../contracts.zig").BeatmapCacheStats;
const BeatmapCachePrune = @import("../../contracts.zig").BeatmapCachePrune;

pub fn upsertBeatmapArchive(self: *Store, set_id: i32, sha256: []const u8, osz_file: []const u8) !void {
    if (!try self.beatmapSetExists(set_id)) return error.UnknownBeatmapSet;
    if (self.object_store.enabled() and object_keys.validSha256(sha256)) {
        const object_key = try object_keys.archive(self.allocator, set_id, sha256);
        defer self.allocator.free(object_key);
        self.object_store.put(self.allocator, self.io, object_key, "application/octet-stream", osz_file) catch |err|
            std.log.warn("event=beatmap_archive_object_write_failed set_id={d} error={t}", .{ set_id, err });
    }
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var exists_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM beatmaps WHERE set_id=?1 LIMIT 1", -1, &exists_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_int(exists_stmt, 1, set_id);
    const exists = c.sqlite3_step(exists_stmt) == c.SQLITE_ROW;
    _ = c.sqlite3_finalize(exists_stmt);
    if (!exists) return error.UnknownBeatmapSet;
    const sql = "INSERT INTO beatmap_archives(set_id,sha256,osz_file,object_bytes,last_accessed_at) VALUES(?1,?2,?3,?4,unixepoch()) ON CONFLICT(set_id) DO UPDATE SET sha256=excluded.sha256,osz_file=excluded.osz_file,object_bytes=excluded.object_bytes,imported_at=unixepoch(),last_accessed_at=unixepoch()";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, set_id);
    _ = c.sqlite3_bind_text(stmt, 2, sha256.ptr, @intCast(sha256.len), null);
    _ = c.sqlite3_bind_blob(stmt, 3, osz_file.ptr, @intCast(osz_file.len), null);
    _ = c.sqlite3_bind_int64(stmt, 4, @intCast(osz_file.len));
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn beatmapSetExists(self: *Store, set_id: i32) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM beatmaps WHERE set_id=?1 LIMIT 1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, set_id);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

pub fn beatmapSetIdsMissingArchives(self: *Store, allocator: std.mem.Allocator, limit: u16) ![]i32 {
    if (limit == 0) return allocator.alloc(i32, 0);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT b.set_id FROM beatmaps b LEFT JOIN beatmap_archives a ON a.set_id=b.set_id WHERE b.set_id>0 AND a.set_id IS NULL GROUP BY b.set_id ORDER BY max(b.last_update) DESC,b.set_id DESC LIMIT ?1";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, limit);
    var ids: std.ArrayList(i32) = .empty;
    errdefer ids.deinit(allocator);
    while (true) switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => try ids.append(allocator, c.sqlite3_column_int(stmt, 0)),
        c.SQLITE_DONE => break,
        else => return error.DatabaseQueryFailed,
    };
    return ids.toOwnedSlice(allocator);
}

pub fn beatmapArchiveIdsMissingSize(self: *Store, allocator: std.mem.Allocator, limit: u16) ![]i32 {
    if (limit == 0) return allocator.alloc(i32, 0);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT set_id FROM beatmap_archives WHERE object_bytes=0 ORDER BY set_id LIMIT ?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, limit);
    var ids: std.ArrayList(i32) = .empty;
    errdefer ids.deinit(allocator);
    while (true) switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => try ids.append(allocator, c.sqlite3_column_int(stmt, 0)),
        c.SQLITE_DONE => break,
        else => return error.DatabaseQueryFailed,
    };
    return ids.toOwnedSlice(allocator);
}

pub fn setBeatmapArchiveSize(self: *Store, set_id: i32, bytes: usize) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmap_archives SET object_bytes=?2 WHERE set_id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, set_id);
    _ = c.sqlite3_bind_int64(stmt, 2, @intCast(bytes));
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn beatmapMirrorPendingCount(self: *Store) !i64 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT count(*) FROM (SELECT b.set_id FROM beatmaps b LEFT JOIN beatmap_archives a ON a.set_id=b.set_id WHERE b.set_id>0 AND a.set_id IS NULL GROUP BY b.set_id)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return c.sqlite3_column_int64(stmt, 0);
}

pub fn beatmapArchive(self: *Store, allocator: std.mem.Allocator, set_id: i32) !?[]u8 {
    const stored = blk: {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT sha256,osz_file FROM beatmap_archives WHERE set_id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, set_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const sha256 = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)));
        errdefer allocator.free(sha256);
        const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 1));
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
        const data = try allocator.dupe(u8, ptr[0..len]);
        errdefer allocator.free(data);
        var touch: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmap_archives SET last_accessed_at=unixepoch() WHERE set_id=?1", -1, &touch, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(touch);
        _ = c.sqlite3_bind_int(touch, 1, set_id);
        if (c.sqlite3_step(touch) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        break :blk .{ .data = data, .sha256 = sha256 };
    };
    defer allocator.free(stored.sha256);
    if (self.object_store.enabled() and object_keys.validSha256(stored.sha256)) {
        const object_key = try object_keys.archive(allocator, set_id, stored.sha256);
        defer allocator.free(object_key);
        if (self.object_store.getWithLimit(allocator, self.io, object_key, "application/octet-stream", stored.data.len)) |data| {
            if (object_keys.matchesSha256(data, stored.sha256)) {
                allocator.free(stored.data);
                return data;
            }
            allocator.free(data);
            std.log.warn("event=beatmap_archive_object_invalid set_id={d}", .{set_id});
        } else |err| std.log.warn("event=beatmap_archive_object_read_failed set_id={d} error={t}", .{ set_id, err });
    }
    return stored.data;
}

pub fn beatmapArchiveDownload(self: *Store, allocator: std.mem.Allocator, set_id: i32) !?BeatmapArchiveDownload {
    const stored = blk: {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT sha256,osz_file,object_bytes FROM beatmap_archives WHERE set_id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, set_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const sha256 = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)));
        errdefer allocator.free(sha256);
        const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 1));
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
        const data = try allocator.dupe(u8, ptr[0..len]);
        errdefer allocator.free(data);
        const bytes: usize = @intCast(c.sqlite3_column_int64(stmt, 2));
        var touch: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmap_archives SET last_accessed_at=unixepoch() WHERE set_id=?1", -1, &touch, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(touch);
        _ = c.sqlite3_bind_int(touch, 1, set_id);
        if (c.sqlite3_step(touch) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        break :blk .{ .sha256 = sha256, .data = data, .bytes = bytes };
    };
    defer allocator.free(stored.sha256);
    if (stored.bytes == 0 or stored.bytes != stored.data.len or !object_keys.matchesSha256(stored.data, stored.sha256)) {
        allocator.free(stored.data);
        return error.InvalidStoredBeatmapArchive;
    }
    errdefer allocator.free(stored.data);
    const object_key = if (self.object_store.enabled() and object_keys.validSha256(stored.sha256))
        try object_keys.archive(allocator, set_id, stored.sha256)
    else
        null;
    return .{ .allocator = allocator, .object_key = object_key, .data = stored.data, .bytes = stored.bytes };
}

pub fn streamBeatmapArchive(self: *Store, download: BeatmapArchiveDownload, writer: *std.Io.Writer) !void {
    if (download.object_key) |object_key| {
        return self.object_store.streamGet(self.allocator, self.io, object_key, "application/octet-stream", writer);
    }
    try writer.writeAll(download.data orelse return error.BeatmapArchiveUnavailable);
}

pub fn hydrationRetryAllowed(self: *Store, md5: []const u8, now: i64) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT next_retry_at<=?2 FROM beatmap_hydration_failures WHERE md5=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, md5.ptr, @intCast(md5.len), null);
    _ = c.sqlite3_bind_int64(stmt, 2, now);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return true;
    return c.sqlite3_column_int(stmt, 0) != 0;
}

pub fn recordHydrationFailure(self: *Store, md5: []const u8, set_id: i32, reason: []const u8, now: i64) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = "INSERT INTO beatmap_hydration_failures(md5,set_id,attempts,next_retry_at,last_error,updated_at) VALUES(?1,?2,1,?4+30,?3,?4) ON CONFLICT(md5) DO UPDATE SET set_id=excluded.set_id,attempts=min(32,beatmap_hydration_failures.attempts+1),next_retry_at=excluded.updated_at+min(21600,30*(1 << min(beatmap_hydration_failures.attempts,10))),last_error=excluded.last_error,updated_at=excluded.updated_at";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, md5.ptr, @intCast(md5.len), null);
    _ = c.sqlite3_bind_int(stmt, 2, set_id);
    _ = c.sqlite3_bind_text(stmt, 3, reason.ptr, @intCast(reason.len), null);
    _ = c.sqlite3_bind_int64(stmt, 4, now);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    var trim: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "DELETE FROM beatmap_hydration_failures WHERE md5 IN (SELECT md5 FROM beatmap_hydration_failures ORDER BY updated_at DESC,md5 DESC LIMIT -1 OFFSET 10000)", -1, &trim, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(trim);
    if (c.sqlite3_step(trim) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn clearHydrationFailure(self: *Store, md5: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "DELETE FROM beatmap_hydration_failures WHERE md5=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, md5.ptr, @intCast(md5.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn beatmapCacheStats(self: *Store) !BeatmapCacheStats {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT count(*),coalesce(sum(object_bytes),0),(SELECT count(*) FROM beatmap_hydration_failures) FROM beatmap_archives", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return .{ .entries = c.sqlite3_column_int64(stmt, 0), .bytes = c.sqlite3_column_int64(stmt, 1), .hydration_failures = c.sqlite3_column_int64(stmt, 2) };
}

pub fn pruneBeatmapArchives(self: *Store, max_bytes: u64) !BeatmapCachePrune {
    if (self.object_store.enabled()) return .{ .entries = 0, .bytes = 0 };
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const before = try self.cacheSizeLocked();
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "DELETE FROM beatmap_archives WHERE set_id IN (SELECT set_id FROM (SELECT set_id,sum(length(osz_file)) OVER (ORDER BY last_accessed_at DESC,imported_at DESC,set_id DESC) AS running_bytes FROM beatmap_archives) WHERE running_bytes>?1)";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, @intCast(@min(max_bytes, @as(u64, std.math.maxInt(i64)))));
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    const after = try self.cacheSizeLocked();
    return .{ .entries = before.entries - after.entries, .bytes = before.bytes - after.bytes };
}

pub fn cacheSizeLocked(self: *Store) !BeatmapCachePrune {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT count(*),coalesce(sum(object_bytes),0) FROM beatmap_archives", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return .{ .entries = c.sqlite3_column_int64(stmt, 0), .bytes = c.sqlite3_column_int64(stmt, 1) };
}
