const std = @import("std");
const media_contract = @import("../../../media_contract.zig");
const object_keys = @import("../../../object_keys.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const BeatmapCachePrune = @import("../../contracts.zig").BeatmapCachePrune;
const BeatmapMediaCacheStats = @import("../../contracts.zig").BeatmapMediaCacheStats;

pub fn putBeatmapMedia(self: *Store, set_id: i32, kind: media_contract.Kind, content_type: media_contract.ContentType, data: []const u8) !void {
    if (!media_contract.compatible(kind, content_type) or media_contract.detect(kind, data) != content_type) return error.InvalidBeatmapMedia;
    if (!try self.beatmapSetExists(set_id)) return error.UnknownBeatmapSet;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    var encoded_digest: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&encoded_digest, "{x}", .{digest}) catch unreachable;

    if (self.object_store.enabled()) {
        const object_key = try object_keys.media(self.allocator, set_id, kind, content_type, &encoded_digest);
        defer self.allocator.free(object_key);
        self.object_store.put(self.allocator, self.io, object_key, content_type.value(), data) catch |err|
            std.log.warn("event=beatmap_media_object_write_failed set_id={d} kind={s} error={t}", .{ set_id, kind.dbName(), err });
    }

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var exists: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM beatmaps WHERE set_id=?1 LIMIT 1", -1, &exists, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_int(exists, 1, set_id);
    const known_set = c.sqlite3_step(exists) == c.SQLITE_ROW;
    _ = c.sqlite3_finalize(exists);
    if (!known_set) return error.UnknownBeatmapSet;

    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "INSERT INTO beatmap_media(set_id,kind,content_type,sha256,data,last_accessed_at) VALUES(?1,?2,?3,?4,?5,unixepoch()) ON CONFLICT(set_id,kind) DO UPDATE SET content_type=excluded.content_type,sha256=excluded.sha256,data=excluded.data,fetched_at=unixepoch(),last_accessed_at=unixepoch()";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, set_id);
    _ = c.sqlite3_bind_text(stmt, 2, kind.dbName().ptr, @intCast(kind.dbName().len), null);
    _ = c.sqlite3_bind_text(stmt, 3, content_type.value().ptr, @intCast(content_type.value().len), null);
    _ = c.sqlite3_bind_text(stmt, 4, &encoded_digest, encoded_digest.len, null);
    _ = c.sqlite3_bind_blob(stmt, 5, data.ptr, @intCast(data.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn beatmapMedia(self: *Store, allocator: std.mem.Allocator, set_id: i32, kind: media_contract.Kind) !?media_contract.Asset {
    const stored = blk: {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT content_type,sha256,data FROM beatmap_media WHERE set_id=?1 AND kind=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, set_id);
        _ = c.sqlite3_bind_text(stmt, 2, kind.dbName().ptr, @intCast(kind.dbName().len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const content_type = media_contract.ContentType.parse(std.mem.span(c.sqlite3_column_text(stmt, 0))) orelse return error.InvalidStoredBeatmapMedia;
        const sha256 = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
        errdefer allocator.free(sha256);
        const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 2));
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 2));
        const data = try allocator.dupe(u8, ptr[0..len]);
        errdefer allocator.free(data);
        if (!media_contract.compatible(kind, content_type) or !object_keys.validSha256(sha256)) return error.InvalidStoredBeatmapMedia;
        var touch: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmap_media SET last_accessed_at=unixepoch() WHERE set_id=?1 AND kind=?2", -1, &touch, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(touch);
        _ = c.sqlite3_bind_int(touch, 1, set_id);
        _ = c.sqlite3_bind_text(touch, 2, kind.dbName().ptr, @intCast(kind.dbName().len), null);
        if (c.sqlite3_step(touch) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        break :blk .{ .data = data, .content_type = content_type, .sha256 = sha256 };
    };
    defer allocator.free(stored.sha256);
    if (self.object_store.enabled()) {
        const object_key = try object_keys.media(allocator, set_id, kind, stored.content_type, stored.sha256);
        defer allocator.free(object_key);
        if (self.object_store.getWithLimit(allocator, self.io, object_key, stored.content_type.value(), stored.data.len)) |data| {
            if (object_keys.matchesSha256(data, stored.sha256) and media_contract.detect(kind, data) == stored.content_type) {
                allocator.free(stored.data);
                return .{ .data = data, .content_type = stored.content_type };
            }
            allocator.free(data);
            std.log.warn("event=beatmap_media_object_invalid set_id={d} kind={s}", .{ set_id, kind.dbName() });
        } else |err| std.log.warn("event=beatmap_media_object_read_failed set_id={d} kind={s} error={t}", .{ set_id, kind.dbName(), err });
    }
    if (media_contract.detect(kind, stored.data) != stored.content_type or !object_keys.matchesSha256(stored.data, stored.sha256)) {
        allocator.free(stored.data);
        return error.InvalidStoredBeatmapMedia;
    }
    return .{ .data = stored.data, .content_type = stored.content_type };
}

pub fn beatmapMediaCacheStats(self: *Store) !BeatmapMediaCacheStats {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.mediaCacheSizeLocked();
}

pub fn pruneBeatmapMedia(self: *Store, max_bytes: u64) !BeatmapCachePrune {
    if (self.object_store.enabled()) return .{ .entries = 0, .bytes = 0 };
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const before = try self.mediaCacheSizeLocked();
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "DELETE FROM beatmap_media WHERE (set_id,kind) IN (SELECT set_id,kind FROM (SELECT set_id,kind,sum(length(data)) OVER (ORDER BY last_accessed_at DESC,fetched_at DESC,set_id DESC,kind DESC) AS running_bytes FROM beatmap_media) WHERE running_bytes>?1)";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, @intCast(@min(max_bytes, @as(u64, std.math.maxInt(i64)))));
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    const after = try self.mediaCacheSizeLocked();
    return .{ .entries = before.entries - after.entries, .bytes = before.bytes - after.bytes };
}

pub fn mediaCacheSizeLocked(self: *Store) !BeatmapMediaCacheStats {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT count(*),coalesce(sum(length(data)),0) FROM beatmap_media", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return .{ .entries = c.sqlite3_column_int64(stmt, 0), .bytes = c.sqlite3_column_int64(stmt, 1) };
}
