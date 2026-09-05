const std = @import("std");
const domain = @import("../../../domain.zig");
const site_replay = @import("../../../site_replay.zig");
const object_keys = @import("../../../object_keys.zig");
const c = @import("../../../storage.zig").c;
const ReplaySource = @import("../../contracts.zig").ReplaySource;
const max_replay_object_bytes = @import("../../../storage.zig").max_replay_object_bytes;
const Store = @import("../../../storage.zig").Store;

pub fn replayViewCountLocked(self: *Store, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !i32 {
    if (!domain.validSiteMode(source, stats_mode)) return error.InvalidScoreSource;
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT count(*) FROM score_replay_views WHERE owner_id=?1 AND mode=?2 AND rank_namespace=?3 AND (?4='all' OR (?4='scorev2' AND source='stable') OR source=?4)";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, stats_mode);
    const namespace = domain.siteNamespace(source, stats_mode);
    _ = c.sqlite3_bind_text(stmt, 3, namespace.ptr, @intCast(namespace.len), null);
    const source_name = @tagName(source);
    _ = c.sqlite3_bind_text(stmt, 4, source_name.ptr, @intCast(source_name.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return c.sqlite3_column_int(stmt, 0);
}

pub fn replayViewCount(self: *Store, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !i32 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.replayViewCountLocked(user_id, source, stats_mode);
}

pub fn recordReplayView(self: *Store, viewer_id: i32, source: ReplaySource, score_id: i64) !bool {
    if (viewer_id <= 0 or score_id <= 0) return false;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const stable_sql =
        "INSERT INTO score_replay_views(source,score_id,viewer_id,owner_id,mode,rank_namespace) " ++
        "SELECT 'stable',s.id,?1,s.user_id,CASE WHEN (s.mods&8192)!=0 THEN s.mode+8 WHEN (s.mods&128)!=0 THEN s.mode+4 ELSE s.mode END,s.rank_namespace FROM scores s " ++
        "WHERE s.id=?2 AND s.user_id!=?1 AND s.passed=1 AND s.rank_namespace IN('vanilla','relax','autopilot','scorev2') " ++
        "ON CONFLICT(source,score_id,viewer_id) DO UPDATE SET viewed_at=unixepoch()";
    const lazer_sql =
        "INSERT INTO score_replay_views(source,score_id,viewer_id,owner_id,mode,rank_namespace) " ++
        "SELECT 'lazer',s.id,?1,s.user_id,CASE s.rank_namespace WHEN 'vanilla' THEN s.ruleset_id WHEN 'relax' THEN s.ruleset_id+4 WHEN 'autopilot' THEN 8 ELSE -1 END,s.rank_namespace FROM lazer_scores s " ++
        "WHERE s.id=?2 AND s.user_id!=?1 AND s.passed=1 AND s.rank_namespace IN('vanilla','relax','autopilot') " ++
        "ON CONFLICT(source,score_id,viewer_id) DO UPDATE SET viewed_at=unixepoch()";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, if (source == .stable) stable_sql else lazer_sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, viewer_id);
    _ = c.sqlite3_bind_int64(stmt, 2, score_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return c.sqlite3_changes(self.db) != 0;
}

pub fn replayData(self: *Store, allocator: std.mem.Allocator, source: ReplaySource, score_id: i64, public_only: bool) !?[]u8 {
    const stored = blk: {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = switch (source) {
            .stable => if (public_only)
                "SELECT s.replay,r.object_key,r.etag,r.object_bytes FROM scores s JOIN users u ON u.id=s.user_id LEFT JOIN replay_objects r ON r.source='stable' AND r.score_id=s.id WHERE s.id=?1 AND s.passed=1 AND u.id!=3 AND u.restricted=0 AND (length(s.replay)>0 OR r.object_key IS NOT NULL)"
            else
                "SELECT s.replay,r.object_key,r.etag,r.object_bytes FROM scores s LEFT JOIN replay_objects r ON r.source='stable' AND r.score_id=s.id WHERE s.id=?1 AND s.passed=1 AND (length(s.replay)>0 OR r.object_key IS NOT NULL)",
            .lazer => "SELECT s.replay,r.object_key,r.etag,r.object_bytes FROM lazer_scores s JOIN users u ON u.id=s.user_id LEFT JOIN replay_objects r ON r.source='lazer' AND r.score_id=s.id WHERE s.id=?1 AND s.passed=1 AND u.id!=3 AND u.restricted=0 AND (length(s.replay)>0 OR r.object_key IS NOT NULL)",
        };
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, score_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) break :blk null;
        const fallback: ?[]u8 = if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) null else value: {
            const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0));
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            break :value try allocator.dupe(u8, ptr[0..len]);
        };
        errdefer if (fallback) |data| allocator.free(data);
        const object_key = if (c.sqlite3_column_type(stmt, 1) == c.SQLITE_NULL) null else try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
        errdefer if (object_key) |key| allocator.free(key);
        var etag: [64]u8 = undefined;
        if (object_key != null) {
            const value = std.mem.span(c.sqlite3_column_text(stmt, 2));
            if (value.len != etag.len) return error.InvalidReplayObject;
            @memcpy(&etag, value);
        }
        break :blk .{ .fallback = fallback, .object_key = object_key, .etag = etag, .object_bytes = @as(usize, @intCast(@max(0, c.sqlite3_column_int64(stmt, 3)))) };
    } orelse return null;
    defer if (stored.object_key) |key| allocator.free(key);
    if (stored.object_key) |key| if (self.object_store.enabled() and stored.object_bytes > 0 and stored.object_bytes <= max_replay_object_bytes) {
        if (self.object_store.getWithLimit(allocator, self.io, key, "application/octet-stream", stored.object_bytes)) |data| {
            if (data.len == stored.object_bytes and object_keys.matchesSha256(data, &stored.etag)) {
                if (stored.fallback) |fallback| allocator.free(fallback);
                return data;
            }
            allocator.free(data);
            std.log.warn("event=replay_object_invalid source={s} score_id={d}", .{ source.text(), score_id });
        } else |err| std.log.warn("event=replay_object_read_failed source={s} score_id={d} error={t}", .{ source.text(), score_id, err });
    };
    return stored.fallback;
}

pub fn siteReplay(self: *Store, allocator: std.mem.Allocator, score_id: i64) !?[]u8 {
    const metadata: site_replay.Header = (blk: {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT s.id,u.name,s.map_md5,s.mode,s.n300,s.n100,s.n50,s.ngeki,s.nkatu,s.nmiss,s.score,s.max_combo,s.perfect,s.mods,s.submitted_at FROM scores s JOIN users u ON u.id=s.user_id WHERE s.id=?1 AND s.passed=1 AND u.id!=3 AND u.restricted=0 AND (length(s.replay)>0 OR EXISTS(SELECT 1 FROM replay_objects r WHERE r.source='stable' AND r.score_id=s.id))";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, score_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) break :blk null;
        const username = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
        errdefer allocator.free(username);
        const map_md5 = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)));
        errdefer allocator.free(map_md5);
        break :blk site_replay.Header{
            .score_id = c.sqlite3_column_int64(stmt, 0),
            .username = username,
            .map_md5 = map_md5,
            .mode = @as(u8, @intCast(c.sqlite3_column_int(stmt, 3))),
            .n300 = c.sqlite3_column_int(stmt, 4),
            .n100 = c.sqlite3_column_int(stmt, 5),
            .n50 = c.sqlite3_column_int(stmt, 6),
            .ngeki = c.sqlite3_column_int(stmt, 7),
            .nkatu = c.sqlite3_column_int(stmt, 8),
            .nmiss = c.sqlite3_column_int(stmt, 9),
            .score = c.sqlite3_column_int64(stmt, 10),
            .max_combo = c.sqlite3_column_int(stmt, 11),
            .perfect = c.sqlite3_column_int(stmt, 12) != 0,
            .mods = c.sqlite3_column_int(stmt, 13),
            .submitted_at = c.sqlite3_column_int64(stmt, 14),
        };
    }) orelse return null;
    defer allocator.free(metadata.username);
    defer allocator.free(metadata.map_md5);
    const frames = (try self.replayData(allocator, .stable, score_id, true)) orelse return null;
    defer allocator.free(frames);
    return @as(?[]u8, try site_replay.build(allocator, metadata, frames));
}

pub fn lazerReplay(self: *Store, allocator: std.mem.Allocator, score_id: i64) !?[]u8 {
    return self.replayData(allocator, .lazer, score_id, true);
}

pub fn stableReplay(self: *Store, allocator: std.mem.Allocator, score_id: i64) !?[]u8 {
    return self.replayData(allocator, .stable, score_id, true);
}
