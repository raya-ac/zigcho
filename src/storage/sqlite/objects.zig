const std = @import("std");
const media_contract = @import("../../media_contract.zig");
const object_keys = @import("../../object_keys.zig");
const c = @import("../../storage.zig").c;
const ReplaySource = @import("../contracts.zig").ReplaySource;
const max_replay_object_bytes = @import("../../storage.zig").max_replay_object_bytes;
const Store = @import("../../storage.zig").Store;
const ObjectMigrationStats = @import("../contracts.zig").ObjectMigrationStats;
const ObjectPurgeStats = @import("../contracts.zig").ObjectPurgeStats;

pub fn putVerifiedObject(self: *Store, object_key: []const u8, content_type: []const u8, bytes: []const u8, sha256: []const u8) !void {
    try self.object_store.put(self.allocator, self.io, object_key, content_type, bytes);
    const downloaded = try self.object_store.getWithLimit(self.allocator, self.io, object_key, content_type, bytes.len);
    defer self.allocator.free(downloaded);
    if (downloaded.len != bytes.len or !object_keys.matchesSha256(downloaded, sha256)) return error.ObjectVerificationFailed;
}

pub fn storeReplayObject(self: *Store, source: ReplaySource, score_id: i64, data: []const u8) !bool {
    if (!self.object_store.enabled()) return false;
    const timer = @import("../../telemetry.zig").Timer.start(.replay_archive);
    defer timer.finish();
    if (score_id <= 0 or data.len == 0 or data.len > max_replay_object_bytes) return error.InvalidReplayObject;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const etag = std.fmt.bytesToHex(digest, .lower);
    const object_key = try object_keys.replay(self.allocator, source.text(), &etag);
    defer self.allocator.free(object_key);
    try self.putVerifiedObject(object_key, "application/octet-stream", data, &etag);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "INSERT INTO replay_objects(source,score_id,object_key,etag,object_bytes) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(source,score_id) DO UPDATE SET object_key=excluded.object_key,etag=excluded.etag,object_bytes=excluded.object_bytes,stored_at=max(unixepoch(),replay_objects.stored_at+1)";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, source.text().ptr, @intCast(source.text().len), null);
    _ = c.sqlite3_bind_int64(stmt, 2, score_id);
    _ = c.sqlite3_bind_text(stmt, 3, object_key.ptr, @intCast(object_key.len), null);
    _ = c.sqlite3_bind_text(stmt, 4, etag[0..].ptr, etag.len, null);
    _ = c.sqlite3_bind_int64(stmt, 5, @intCast(data.len));
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return true;
}

pub fn migrateBeatmapObjects(self: *Store) !ObjectMigrationStats {
    if (!self.object_store.enabled()) return error.ObjectStorageNotConfigured;
    var stats: ObjectMigrationStats = .{};
    var offset: i64 = 0;
    while (true) : (offset += 1) {
        const item = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT set_id,sha256,osz_file FROM beatmap_archives ORDER BY set_id LIMIT 1 OFFSET ?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(stmt);
            _ = c.sqlite3_bind_int64(stmt, 1, offset);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) break :blk null;
            const sha256 = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
            errdefer self.allocator.free(sha256);
            const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 2));
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 2));
            const data = try self.allocator.dupe(u8, ptr[0..len]);
            break :blk .{ .set_id = c.sqlite3_column_int(stmt, 0), .sha256 = sha256, .data = data };
        } orelse break;
        defer self.allocator.free(item.sha256);
        defer self.allocator.free(item.data);
        const object_key = object_keys.archive(self.allocator, item.set_id, item.sha256) catch |err| {
            stats.failed += 1;
            std.log.warn("event=beatmap_archive_object_migration_failed set_id={d} error={t}", .{ item.set_id, err });
            continue;
        };
        defer self.allocator.free(object_key);
        self.putVerifiedObject(object_key, "application/octet-stream", item.data, item.sha256) catch |err| {
            stats.failed += 1;
            std.log.warn("event=beatmap_archive_object_migration_failed set_id={d} error={t}", .{ item.set_id, err });
            continue;
        };
        stats.archives += 1;
    }

    offset = 0;
    while (true) : (offset += 1) {
        const item = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT set_id,kind,content_type,sha256,data FROM beatmap_media ORDER BY set_id,kind LIMIT 1 OFFSET ?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(stmt);
            _ = c.sqlite3_bind_int64(stmt, 1, offset);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) break :blk null;
            const kind = media_contract.Kind.parseDb(std.mem.span(c.sqlite3_column_text(stmt, 1))) orelse return error.InvalidStoredBeatmapMedia;
            const content_type = media_contract.ContentType.parse(std.mem.span(c.sqlite3_column_text(stmt, 2))) orelse return error.InvalidStoredBeatmapMedia;
            const sha256 = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3)));
            errdefer self.allocator.free(sha256);
            const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 4));
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 4));
            const data = try self.allocator.dupe(u8, ptr[0..len]);
            break :blk .{ .set_id = c.sqlite3_column_int(stmt, 0), .kind = kind, .content_type = content_type, .sha256 = sha256, .data = data };
        } orelse break;
        defer self.allocator.free(item.sha256);
        defer self.allocator.free(item.data);
        const object_key = object_keys.media(self.allocator, item.set_id, item.kind, item.content_type, item.sha256) catch |err| {
            stats.failed += 1;
            std.log.warn("event=beatmap_media_object_migration_failed set_id={d} kind={s} error={t}", .{ item.set_id, item.kind.dbName(), err });
            continue;
        };
        defer self.allocator.free(object_key);
        self.putVerifiedObject(object_key, item.content_type.value(), item.data, item.sha256) catch |err| {
            stats.failed += 1;
            std.log.warn("event=beatmap_media_object_migration_failed set_id={d} kind={s} error={t}", .{ item.set_id, item.kind.dbName(), err });
            continue;
        };
        stats.media += 1;
    }

    offset = 0;
    while (true) : (offset += 1) {
        const item = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var stmt: ?*c.sqlite3_stmt = null;
            const sql = "SELECT source,score_id,replay FROM (SELECT 'stable' source,id score_id,replay FROM scores WHERE replay IS NOT NULL AND length(replay)>0 UNION ALL SELECT 'lazer' source,id score_id,replay FROM lazer_scores WHERE replay IS NOT NULL AND length(replay)>0) ORDER BY source,score_id LIMIT 1 OFFSET ?1";
            if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(stmt);
            _ = c.sqlite3_bind_int64(stmt, 1, offset);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) break :blk null;
            const source: ReplaySource = if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)), "stable")) .stable else .lazer;
            const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 2));
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 2));
            break :blk .{ .source = source, .score_id = c.sqlite3_column_int64(stmt, 1), .data = try self.allocator.dupe(u8, ptr[0..len]) };
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

pub fn purgeBeatmapObjectBackups(self: *Store) !ObjectPurgeStats {
    _ = self;
    return error.ObjectPurgeRequiresPostgres;
}
