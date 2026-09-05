const std = @import("std");
const postgres = @import("../../../postgres.zig");
const storage_contracts = @import("../../contracts.zig");
const lazer = @import("../../../lazer.zig");
const media_contract = @import("../../../media_contract.zig");
const object_keys = @import("../../../object_keys.zig");
const database_sql = @import("database_sql");
const common = @import("../common.zig");

const ReplaySource = storage_contracts.ReplaySource;
const BeatmapArchiveDownload = storage_contracts.BeatmapArchiveDownload;
const ObjectMigrationStats = storage_contracts.ObjectMigrationStats;
const ObjectPurgeStats = storage_contracts.ObjectPurgeStats;
const BeatmapCacheStats = common.BeatmapCacheStats;
const BeatmapCachePrune = common.BeatmapCachePrune;
const BeatmapMediaCacheStats = common.BeatmapMediaCacheStats;

pub fn upsertBeatmapArchive(self: anytype, set_id: i32, sha256: []const u8, osz_file: []const u8) !void {
    var set_buf: [24]u8 = undefined;
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    if (!try self.beatmapSetExists(set_id)) return error.UnknownBeatmapSet;
    const object_written = upload: {
        if (!self.object_store.enabled() or !object_keys.validSha256(sha256)) break :upload false;
        const object_key = try object_keys.archive(self.allocator, set_id, sha256);
        defer self.allocator.free(object_key);
        self.object_store.put(self.allocator, self.io, object_key, "application/octet-stream", osz_file) catch |err| {
            std.log.warn("event=beatmap_archive_object_write_failed set_id={d} error={t}", .{ set_id, err });
            break :upload false;
        };
        break :upload true;
    };
    var lease = self.pool.acquire();
    defer lease.release();
    var exists = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.beatmaps WHERE set_id=$1 LIMIT 1", &.{set});
    defer exists.deinit();
    if (exists.rows() == 0) return error.UnknownBeatmapSet;
    if (self.external_only and object_written) {
        var size_buf: [32]u8 = undefined;
        const size = try std.fmt.bufPrint(&size_buf, "{d}", .{osz_file.len});
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_archives(set_id,sha256,osz_file,object_bytes,last_accessed_at) VALUES($1,$2,NULL,$3,extract(epoch FROM clock_timestamp())::bigint) ON CONFLICT(set_id) DO UPDATE SET sha256=excluded.sha256,osz_file=NULL,object_bytes=excluded.object_bytes,imported_at=extract(epoch FROM clock_timestamp())::bigint,last_accessed_at=extract(epoch FROM clock_timestamp())::bigint", &.{ set, sha256, size });
        result.deinit();
    } else {
        const encoded = try postgres.encodeBytea(self.allocator, osz_file);
        defer self.allocator.free(encoded);
        var size_buf: [32]u8 = undefined;
        const size = try std.fmt.bufPrint(&size_buf, "{d}", .{osz_file.len});
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_archives(set_id,sha256,osz_file,object_bytes,last_accessed_at) VALUES($1,$2,$3,$4,extract(epoch FROM clock_timestamp())::bigint) ON CONFLICT(set_id) DO UPDATE SET sha256=excluded.sha256,osz_file=excluded.osz_file,object_bytes=excluded.object_bytes,imported_at=extract(epoch FROM clock_timestamp())::bigint,last_accessed_at=extract(epoch FROM clock_timestamp())::bigint", &.{ set, sha256, encoded, size });
        result.deinit();
    }
}

pub fn beatmapSetIdsMissingArchives(self: anytype, allocator: std.mem.Allocator, limit: u16) ![]i32 {
    if (limit == 0) return allocator.alloc(i32, 0);
    var limit_buf: [12]u8 = undefined;
    const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT b.set_id FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmap_archives a ON a.set_id=b.set_id WHERE b.set_id>0 AND a.set_id IS NULL GROUP BY b.set_id ORDER BY max(b.last_update) DESC,b.set_id DESC LIMIT $1", &.{limit_text});
    defer result.deinit();
    const ids = try allocator.alloc(i32, result.rows());
    errdefer allocator.free(ids);
    for (ids, 0..) |*id, row| id.* = try result.int(i32, row, 0);
    return ids;
}

pub fn beatmapArchiveIdsMissingSize(self: anytype, allocator: std.mem.Allocator, limit: u16) ![]i32 {
    if (limit == 0) return allocator.alloc(i32, 0);
    var limit_buf: [12]u8 = undefined;
    const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT set_id FROM zigcho.beatmap_archives WHERE object_bytes=0 ORDER BY set_id LIMIT $1", &.{limit_text});
    defer result.deinit();
    const ids = try allocator.alloc(i32, result.rows());
    errdefer allocator.free(ids);
    for (ids, 0..) |*id, row| id.* = try result.int(i32, row, 0);
    return ids;
}

pub fn setBeatmapArchiveSize(self: anytype, set_id: i32, bytes: usize) !void {
    var set_buf: [24]u8 = undefined;
    var bytes_buf: [32]u8 = undefined;
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    const size = try std.fmt.bufPrint(&bytes_buf, "{d}", .{bytes});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_archives SET object_bytes=$2 WHERE set_id=$1", &.{ set, size });
    result.deinit();
}

pub fn beatmapMirrorPendingCount(self: anytype) !i64 {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.query(lease.conn, "SELECT count(*) FROM (SELECT b.set_id FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmap_archives a ON a.set_id=b.set_id WHERE b.set_id>0 AND a.set_id IS NULL GROUP BY b.set_id) pending");
    defer result.deinit();
    return try result.int(i64, 0, 0);
}

pub fn putBeatmapMedia(self: anytype, set_id: i32, kind: media_contract.Kind, content_type: media_contract.ContentType, data: []const u8) !void {
    if (!media_contract.compatible(kind, content_type) or media_contract.detect(kind, data) != content_type) return error.InvalidBeatmapMedia;
    if (!try self.beatmapSetExists(set_id)) return error.UnknownBeatmapSet;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    var encoded_digest: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&encoded_digest, "{x}", .{digest}) catch unreachable;
    const object_written = upload: {
        if (!self.object_store.enabled()) break :upload false;
        const object_key = try object_keys.media(self.allocator, set_id, kind, content_type, &encoded_digest);
        defer self.allocator.free(object_key);
        self.object_store.put(self.allocator, self.io, object_key, content_type.value(), data) catch |err| {
            std.log.warn("event=beatmap_media_object_write_failed set_id={d} kind={s} error={t}", .{ set_id, kind.dbName(), err });
            break :upload false;
        };
        break :upload true;
    };
    var set_buf: [24]u8 = undefined;
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var exists = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.beatmaps WHERE set_id=$1 LIMIT 1", &.{set});
    defer exists.deinit();
    if (exists.rows() == 0) return error.UnknownBeatmapSet;
    if (self.external_only and object_written) {
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_media(set_id,kind,content_type,sha256,data,last_accessed_at) VALUES($1,$2,$3,$4,NULL,extract(epoch FROM clock_timestamp())::bigint) ON CONFLICT(set_id,kind) DO UPDATE SET content_type=excluded.content_type,sha256=excluded.sha256,data=NULL,fetched_at=extract(epoch FROM clock_timestamp())::bigint,last_accessed_at=extract(epoch FROM clock_timestamp())::bigint", &.{ set, kind.dbName(), content_type.value(), &encoded_digest });
        result.deinit();
    } else {
        const encoded_data = try postgres.encodeBytea(self.allocator, data);
        defer self.allocator.free(encoded_data);
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_media(set_id,kind,content_type,sha256,data,last_accessed_at) VALUES($1,$2,$3,$4,$5,extract(epoch FROM clock_timestamp())::bigint) ON CONFLICT(set_id,kind) DO UPDATE SET content_type=excluded.content_type,sha256=excluded.sha256,data=excluded.data,fetched_at=extract(epoch FROM clock_timestamp())::bigint,last_accessed_at=extract(epoch FROM clock_timestamp())::bigint", &.{ set, kind.dbName(), content_type.value(), &encoded_digest, encoded_data });
        result.deinit();
    }
}

pub fn beatmapMedia(self: anytype, allocator: std.mem.Allocator, set_id: i32, kind: media_contract.Kind) !?media_contract.Asset {
    var set_buf: [24]u8 = undefined;
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    const stored = blk: {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_media SET last_accessed_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 AND kind=$2 RETURNING content_type,sha256,data", &.{ set, kind.dbName() });
        defer result.deinit();
        if (result.rows() == 0) return null;
        const content_type = media_contract.ContentType.parse(result.value(0, 0)) orelse return error.InvalidStoredBeatmapMedia;
        const sha256 = try allocator.dupe(u8, result.value(0, 1));
        errdefer allocator.free(sha256);
        const data: ?[]u8 = if (result.isNull(0, 2)) null else try postgres.decodeBytea(allocator, result.value(0, 2));
        errdefer if (data) |owned| allocator.free(owned);
        if (!media_contract.compatible(kind, content_type) or !object_keys.validSha256(sha256)) return error.InvalidStoredBeatmapMedia;
        break :blk .{ .data = data, .content_type = content_type, .sha256 = sha256 };
    };
    defer allocator.free(stored.sha256);
    if (self.object_store.enabled()) {
        const object_key = try object_keys.media(allocator, set_id, kind, stored.content_type, stored.sha256);
        defer allocator.free(object_key);
        const limit = if (stored.data) |fallback| fallback.len else kind.maxBytes();
        if (self.object_store.getWithLimit(allocator, self.io, object_key, stored.content_type.value(), limit)) |data| {
            if (object_keys.matchesSha256(data, stored.sha256) and media_contract.detect(kind, data) == stored.content_type) {
                if (stored.data) |fallback| allocator.free(fallback);
                return .{ .data = data, .content_type = stored.content_type };
            }
            allocator.free(data);
            std.log.warn("event=beatmap_media_object_invalid set_id={d} kind={s}", .{ set_id, kind.dbName() });
        } else |err| std.log.warn("event=beatmap_media_object_read_failed set_id={d} kind={s} error={t}", .{ set_id, kind.dbName(), err });
    }
    const fallback = stored.data orelse return null;
    if (media_contract.detect(kind, fallback) != stored.content_type or !object_keys.matchesSha256(fallback, stored.sha256)) {
        allocator.free(fallback);
        return error.InvalidStoredBeatmapMedia;
    }
    return .{ .data = fallback, .content_type = stored.content_type };
}

pub fn beatmapMediaCacheStats(self: anytype) !BeatmapMediaCacheStats {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.query(lease.conn, "SELECT count(*),coalesce(sum(octet_length(data)),0) FROM zigcho.beatmap_media");
    defer result.deinit();
    return .{ .entries = try result.int(i64, 0, 0), .bytes = try result.int(i64, 0, 1) };
}

pub fn pruneBeatmapMedia(self: anytype, max_bytes: u64) !BeatmapCachePrune {
    if (self.object_store.enabled()) return .{ .entries = 0, .bytes = 0 };
    var max_buf: [32]u8 = undefined;
    const max_text = try std.fmt.bufPrint(&max_buf, "{d}", .{@min(max_bytes, @as(u64, std.math.maxInt(i64)))});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "WITH ranked AS (SELECT set_id,kind,octet_length(data) AS bytes,sum(octet_length(data)) OVER(ORDER BY last_accessed_at DESC,fetched_at DESC,set_id DESC,kind DESC) AS running_bytes FROM zigcho.beatmap_media),deleted AS (DELETE FROM zigcho.beatmap_media m USING ranked r WHERE m.set_id=r.set_id AND m.kind=r.kind AND r.running_bytes>$1::bigint RETURNING octet_length(m.data) AS bytes) SELECT count(*),coalesce(sum(bytes),0) FROM deleted", &.{max_text});
    defer result.deinit();
    return .{ .entries = try result.int(i64, 0, 0), .bytes = try result.int(i64, 0, 1) };
}

pub fn beatmapArchive(self: anytype, allocator: std.mem.Allocator, set_id: i32) !?[]u8 {
    var set_buf: [24]u8 = undefined;
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    const stored = blk: {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_archives SET last_accessed_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 RETURNING sha256,osz_file", &.{set});
        defer result.deinit();
        if (result.rows() == 0) return null;
        const sha256 = try allocator.dupe(u8, result.value(0, 0));
        errdefer allocator.free(sha256);
        const data: ?[]u8 = if (result.isNull(0, 1)) null else try postgres.decodeBytea(allocator, result.value(0, 1));
        errdefer if (data) |owned| allocator.free(owned);
        break :blk .{ .data = data, .sha256 = sha256 };
    };
    defer allocator.free(stored.sha256);
    if (self.object_store.enabled() and object_keys.validSha256(stored.sha256)) {
        const object_key = try object_keys.archive(allocator, set_id, stored.sha256);
        defer allocator.free(object_key);
        const limit = if (stored.data) |fallback| fallback.len else common.archive_object_limit;
        if (self.object_store.getWithLimit(allocator, self.io, object_key, "application/octet-stream", limit)) |data| {
            if (object_keys.matchesSha256(data, stored.sha256)) {
                if (stored.data) |fallback| allocator.free(fallback);
                return data;
            }
            allocator.free(data);
            std.log.warn("event=beatmap_archive_object_invalid set_id={d}", .{set_id});
        } else |err| std.log.warn("event=beatmap_archive_object_read_failed set_id={d} error={t}", .{ set_id, err });
    }
    const fallback = stored.data orelse return null;
    if (!object_keys.matchesSha256(fallback, stored.sha256)) {
        allocator.free(fallback);
        return error.InvalidStoredBeatmapArchive;
    }
    return fallback;
}

pub fn beatmapArchiveDownload(self: anytype, allocator: std.mem.Allocator, set_id: i32) !?BeatmapArchiveDownload {
    var set_buf: [24]u8 = undefined;
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    const stored = blk: {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_archives SET last_accessed_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 RETURNING sha256,osz_file,object_bytes", &.{set});
        defer result.deinit();
        if (result.rows() == 0) return null;
        const sha256 = try allocator.dupe(u8, result.value(0, 0));
        errdefer allocator.free(sha256);
        const data: ?[]u8 = if (result.isNull(0, 1)) null else try postgres.decodeBytea(allocator, result.value(0, 1));
        errdefer if (data) |value| allocator.free(value);
        const bytes_i64 = try result.int(i64, 0, 2);
        if (bytes_i64 <= 0 or bytes_i64 > common.archive_object_limit) return error.InvalidStoredBeatmapArchive;
        break :blk .{ .sha256 = sha256, .data = data, .bytes = @as(usize, @intCast(bytes_i64)) };
    };
    defer allocator.free(stored.sha256);
    if (stored.data) |data| {
        if (data.len != stored.bytes or !object_keys.matchesSha256(data, stored.sha256)) {
            allocator.free(data);
            return error.InvalidStoredBeatmapArchive;
        }
    }
    errdefer if (stored.data) |data| allocator.free(data);
    const object_key = if (self.object_store.enabled() and object_keys.validSha256(stored.sha256))
        try object_keys.archive(allocator, set_id, stored.sha256)
    else
        null;
    if (object_key == null and stored.data == null) return null;
    return .{ .allocator = allocator, .object_key = object_key, .data = stored.data, .bytes = stored.bytes };
}

pub fn streamBeatmapArchive(self: anytype, download: BeatmapArchiveDownload, writer: *std.Io.Writer) !void {
    if (download.object_key) |object_key| {
        return self.object_store.streamGet(self.allocator, self.io, object_key, "application/octet-stream", writer);
    }
    try writer.writeAll(download.data orelse return error.BeatmapArchiveUnavailable);
}

pub fn hydrationRetryAllowed(self: anytype, md5: []const u8, now: i64) !bool {
    var now_buf: [32]u8 = undefined;
    const now_text = try std.fmt.bufPrint(&now_buf, "{d}", .{now});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT next_retry_at<=$2 FROM zigcho.beatmap_hydration_failures WHERE md5=$1", &.{ md5, now_text });
    defer result.deinit();
    if (result.rows() == 0) return true;
    return try result.boolean(0, 0);
}

pub fn recordHydrationFailure(self: anytype, md5: []const u8, set_id: i32, reason: []const u8, now: i64) !void {
    var set_buf: [24]u8 = undefined;
    var now_buf: [32]u8 = undefined;
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    const now_text = try std.fmt.bufPrint(&now_buf, "{d}", .{now});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_hydration_failures(md5,set_id,attempts,next_retry_at,last_error,updated_at) VALUES($1,$2,1,$4::bigint+30,$3,$4) ON CONFLICT(md5) DO UPDATE SET set_id=excluded.set_id,attempts=least(32,zigcho.beatmap_hydration_failures.attempts+1),next_retry_at=excluded.updated_at+least(21600,(30*power(2,least(zigcho.beatmap_hydration_failures.attempts,10)))::bigint),last_error=excluded.last_error,updated_at=excluded.updated_at", &.{ md5, set, reason, now_text });
    result.deinit();
    var trim = try postgres.query(lease.conn, "DELETE FROM zigcho.beatmap_hydration_failures WHERE md5 IN(SELECT md5 FROM zigcho.beatmap_hydration_failures ORDER BY updated_at DESC,md5 DESC OFFSET 10000)");
    trim.deinit();
}

pub fn clearHydrationFailure(self: anytype, md5: []const u8) !void {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.beatmap_hydration_failures WHERE md5=$1", &.{md5});
    result.deinit();
}

pub fn beatmapCacheStats(self: anytype) !BeatmapCacheStats {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.query(lease.conn, "SELECT count(*),coalesce(sum(object_bytes),0),(SELECT count(*) FROM zigcho.beatmap_hydration_failures) FROM zigcho.beatmap_archives");
    defer result.deinit();
    return .{ .entries = try result.int(i64, 0, 0), .bytes = try result.int(i64, 0, 1), .hydration_failures = try result.int(i64, 0, 2) };
}

pub fn pruneBeatmapArchives(self: anytype, max_bytes: u64) !BeatmapCachePrune {
    if (self.object_store.enabled()) return .{ .entries = 0, .bytes = 0 };
    var max_buf: [32]u8 = undefined;
    const max_text = try std.fmt.bufPrint(&max_buf, "{d}", .{@min(max_bytes, @as(u64, std.math.maxInt(i64)))});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "WITH ranked AS (SELECT set_id,octet_length(osz_file) AS bytes,sum(octet_length(osz_file)) OVER(ORDER BY last_accessed_at DESC,imported_at DESC,set_id DESC) AS running_bytes FROM zigcho.beatmap_archives),deleted AS (DELETE FROM zigcho.beatmap_archives WHERE set_id IN(SELECT set_id FROM ranked WHERE running_bytes>$1::bigint) RETURNING octet_length(osz_file) AS bytes) SELECT count(*),coalesce(sum(bytes),0) FROM deleted", &.{max_text});
    defer result.deinit();
    return .{ .entries = try result.int(i64, 0, 0), .bytes = try result.int(i64, 0, 1) };
}

pub fn putVerifiedObject(self: anytype, object_key: []const u8, content_type: []const u8, bytes: []const u8, sha256: []const u8) !void {
    try self.object_store.put(self.allocator, self.io, object_key, content_type, bytes);
    const downloaded = try self.object_store.getWithLimit(self.allocator, self.io, object_key, content_type, bytes.len);
    defer self.allocator.free(downloaded);
    if (downloaded.len != bytes.len or !object_keys.matchesSha256(downloaded, sha256)) return error.ObjectVerificationFailed;
}

pub fn storeReplayObject(self: anytype, source: ReplaySource, score_id: i64, data: []const u8) !bool {
    if (!self.object_store.enabled()) return false;
    const timer = @import("../../../telemetry.zig").Timer.start(.replay_archive);
    defer timer.finish();
    if (score_id <= 0 or data.len == 0 or data.len > common.max_replay_object_bytes) return error.InvalidReplayObject;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const etag = std.fmt.bytesToHex(digest, .lower);
    const object_key = try object_keys.replay(self.allocator, source.text(), &etag);
    defer self.allocator.free(object_key);
    try putVerifiedObject(self, object_key, "application/octet-stream", data, &etag);
    var id_buf: [32]u8 = undefined;
    var bytes_buf: [32]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{score_id});
    const bytes = try std.fmt.bufPrint(&bytes_buf, "{d}", .{data.len});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.replay_objects(source,score_id,object_key,etag,object_bytes) VALUES($1,$2,$3,$4,$5) ON CONFLICT(source,score_id) DO UPDATE SET object_key=excluded.object_key,etag=excluded.etag,object_bytes=excluded.object_bytes,stored_at=greatest(extract(epoch FROM clock_timestamp())::bigint,zigcho.replay_objects.stored_at+1)", &.{ source.text(), id, object_key, &etag, bytes });
    result.deinit();
    return true;
}

pub fn migrateBeatmapObjects(self: anytype) !ObjectMigrationStats {
    if (!self.object_store.enabled()) return error.ObjectStorageNotConfigured;
    var stats: ObjectMigrationStats = .{};
    var offset: i64 = 0;
    while (true) : (offset += 1) {
        var offset_buf: [32]u8 = undefined;
        const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
        const item = blk: {
            var lease = self.pool.acquire();
            defer lease.release();
            var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT set_id,sha256,osz_file FROM zigcho.beatmap_archives ORDER BY set_id LIMIT 1 OFFSET $1::bigint", &.{offset_text});
            defer result.deinit();
            if (result.rows() == 0) break :blk null;
            const sha256 = try self.allocator.dupe(u8, result.value(0, 1));
            errdefer self.allocator.free(sha256);
            const data = try postgres.decodeBytea(self.allocator, result.value(0, 2));
            break :blk .{ .set_id = try result.int(i32, 0, 0), .sha256 = sha256, .data = data };
        } orelse break;
        defer self.allocator.free(item.sha256);
        defer self.allocator.free(item.data);
        const object_key = object_keys.archive(self.allocator, item.set_id, item.sha256) catch |err| {
            stats.failed += 1;
            std.log.warn("event=beatmap_archive_object_migration_failed set_id={d} error={t}", .{ item.set_id, err });
            continue;
        };
        defer self.allocator.free(object_key);
        putVerifiedObject(self, object_key, "application/octet-stream", item.data, item.sha256) catch |err| {
            stats.failed += 1;
            std.log.warn("event=beatmap_archive_object_migration_failed set_id={d} error={t}", .{ item.set_id, err });
            continue;
        };
        stats.archives += 1;
    }

    offset = 0;
    while (true) : (offset += 1) {
        var offset_buf: [32]u8 = undefined;
        const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
        const item = blk: {
            var lease = self.pool.acquire();
            defer lease.release();
            var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT set_id,kind,content_type,sha256,data FROM zigcho.beatmap_media ORDER BY set_id,kind LIMIT 1 OFFSET $1::bigint", &.{offset_text});
            defer result.deinit();
            if (result.rows() == 0) break :blk null;
            const kind = media_contract.Kind.parseDb(result.value(0, 1)) orelse return error.InvalidStoredBeatmapMedia;
            const content_type = media_contract.ContentType.parse(result.value(0, 2)) orelse return error.InvalidStoredBeatmapMedia;
            const sha256 = try self.allocator.dupe(u8, result.value(0, 3));
            errdefer self.allocator.free(sha256);
            const data = try postgres.decodeBytea(self.allocator, result.value(0, 4));
            break :blk .{ .set_id = try result.int(i32, 0, 0), .kind = kind, .content_type = content_type, .sha256 = sha256, .data = data };
        } orelse break;
        defer self.allocator.free(item.sha256);
        defer self.allocator.free(item.data);
        const object_key = object_keys.media(self.allocator, item.set_id, item.kind, item.content_type, item.sha256) catch |err| {
            stats.failed += 1;
            std.log.warn("event=beatmap_media_object_migration_failed set_id={d} kind={s} error={t}", .{ item.set_id, item.kind.dbName(), err });
            continue;
        };
        defer self.allocator.free(object_key);
        putVerifiedObject(self, object_key, item.content_type.value(), item.data, item.sha256) catch |err| {
            stats.failed += 1;
            std.log.warn("event=beatmap_media_object_migration_failed set_id={d} kind={s} error={t}", .{ item.set_id, item.kind.dbName(), err });
            continue;
        };
        stats.media += 1;
    }

    offset = 0;
    while (true) : (offset += 1) {
        var offset_buf: [32]u8 = undefined;
        const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
        const item = blk: {
            var lease = self.pool.acquire();
            defer lease.release();
            var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT source,score_id,replay FROM (SELECT 'stable'::text source,id score_id,replay FROM zigcho.scores WHERE replay IS NOT NULL AND octet_length(replay)>0 UNION ALL SELECT 'lazer'::text source,id score_id,replay FROM zigcho.lazer_scores WHERE replay IS NOT NULL AND octet_length(replay)>0) rows ORDER BY source,score_id LIMIT 1 OFFSET $1::bigint", &.{offset_text});
            defer result.deinit();
            if (result.rows() == 0) break :blk null;
            const source: ReplaySource = if (std.mem.eql(u8, result.value(0, 0), "stable")) .stable else .lazer;
            break :blk .{ .source = source, .score_id = try result.int(i64, 0, 1), .data = try postgres.decodeBytea(self.allocator, result.value(0, 2)) };
        } orelse break;
        defer self.allocator.free(item.data);
        if (self.storeReplayObject(item.source, item.score_id, item.data)) |stored| {
            if (stored) {
                stats.replays += 1;
                stats.replay_bytes += @intCast(item.data.len);
            }
        } else |err| {
            stats.failed += 1;
            std.log.warn("event=replay_object_migration_failed source={s} score_id={d} error={t}", .{ item.source.text(), item.score_id, err });
        }
    }
    return stats;
}

pub fn purgeBeatmapObjectBackups(self: anytype) !ObjectPurgeStats {
    if (!self.object_store.enabled()) return error.ObjectStorageNotConfigured;
    const version = blk: {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.query(lease.conn, "SELECT max(version) FROM zigcho.schema_migrations");
        defer result.deinit();
        break :blk try result.int(i32, 0, 0);
    };
    if (version >= 30) return .{};
    if (version != 29) return error.UnsupportedSchemaVersion;
    const verification = try self.migrateBeatmapObjects();
    if (verification.failed != 0) return error.ObjectMigrationIncomplete;
    var lease = self.pool.acquire();
    defer lease.release();
    var before = try postgres.query(lease.conn, "SELECT count(osz_file),coalesce(sum(octet_length(osz_file)),0),(SELECT count(data) FROM zigcho.beatmap_media),(SELECT coalesce(sum(octet_length(data)),0) FROM zigcho.beatmap_media) FROM zigcho.beatmap_archives");
    defer before.deinit();
    const stats: ObjectPurgeStats = .{
        .archives = try before.int(i64, 0, 0),
        .archive_bytes = try before.int(i64, 0, 1),
        .media = try before.int(i64, 0, 2),
        .media_bytes = try before.int(i64, 0, 3),
    };
    try postgres.exec(lease.conn, database_sql.postgresMigration(30));
    self.external_only = true;
    return stats;
}
