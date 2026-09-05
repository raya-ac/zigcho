const std = @import("std");
const postgres = @import("../../../postgres.zig");
const storage_contracts = @import("../../contracts.zig");
const lazer = @import("../../../lazer.zig");
const screenshot_contract = @import("../../../screenshot.zig");
const site_replay = @import("../../../site_replay.zig");
const object_keys = @import("../../../object_keys.zig");
const common = @import("../common.zig");

const ReplaySource = storage_contracts.ReplaySource;

pub fn replayData(self: anytype, allocator: std.mem.Allocator, source: ReplaySource, score_id: i64, public_only: bool) !?[]u8 {
    var id_buf: [32]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{score_id});
    const stored = blk: {
        var lease = self.pool.acquire();
        defer lease.release();
        const sql = switch (source) {
            .stable => if (public_only)
                "SELECT s.replay,r.object_key,r.etag,r.object_bytes FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id LEFT JOIN zigcho.replay_objects r ON r.source='stable' AND r.score_id=s.id WHERE s.id=$1 AND s.passed AND u.id!=3 AND NOT u.restricted AND (coalesce(octet_length(s.replay),0)>0 OR r.object_key IS NOT NULL)"
            else
                "SELECT s.replay,r.object_key,r.etag,r.object_bytes FROM zigcho.scores s LEFT JOIN zigcho.replay_objects r ON r.source='stable' AND r.score_id=s.id WHERE s.id=$1 AND s.passed AND (coalesce(octet_length(s.replay),0)>0 OR r.object_key IS NOT NULL)",
            .lazer => "SELECT s.replay,r.object_key,r.etag,r.object_bytes FROM zigcho.lazer_scores s JOIN zigcho.users u ON u.id=s.user_id LEFT JOIN zigcho.replay_objects r ON r.source='lazer' AND r.score_id=s.id WHERE s.id=$1 AND s.passed AND u.id!=3 AND NOT u.restricted AND (coalesce(octet_length(s.replay),0)>0 OR r.object_key IS NOT NULL)",
        };
        var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{id});
        defer result.deinit();
        if (result.rows() == 0) break :blk null;
        const fallback = if (result.isNull(0, 0)) null else try postgres.decodeBytea(allocator, result.value(0, 0));
        errdefer if (fallback) |data| allocator.free(data);
        const object_key = if (result.isNull(0, 1)) null else try allocator.dupe(u8, result.value(0, 1));
        errdefer if (object_key) |key| allocator.free(key);
        var etag: [64]u8 = undefined;
        if (object_key != null) {
            const value = result.value(0, 2);
            if (value.len != etag.len) return error.InvalidReplayObject;
            @memcpy(&etag, value);
        }
        break :blk .{ .fallback = fallback, .object_key = object_key, .etag = etag, .object_bytes = if (result.isNull(0, 3)) 0 else try result.int(usize, 0, 3) };
    } orelse return null;
    defer if (stored.object_key) |key| allocator.free(key);
    if (stored.object_key) |key| if (self.object_store.enabled() and stored.object_bytes > 0 and stored.object_bytes <= common.max_replay_object_bytes) {
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

pub fn siteReplay(self: anytype, allocator: std.mem.Allocator, score_id: i64) !?[]u8 {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{score_id});
    const metadata: site_replay.Header = (blk: {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(allocator, lease.conn, "SELECT s.id,u.name,s.map_md5,s.mode,s.n300,s.n100,s.n50,s.ngeki,s.nkatu,s.nmiss,s.score,s.max_combo,s.perfect,s.mods,s.submitted_at FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id WHERE s.id=$1 AND s.passed AND u.id!=3 AND NOT u.restricted AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects r WHERE r.source='stable' AND r.score_id=s.id))", &.{id});
        defer result.deinit();
        if (result.rows() == 0) break :blk null;
        const username = try allocator.dupe(u8, result.value(0, 1));
        errdefer allocator.free(username);
        const map_md5 = try allocator.dupe(u8, result.value(0, 2));
        errdefer allocator.free(map_md5);
        break :blk site_replay.Header{
            .score_id = try result.int(i64, 0, 0),
            .username = username,
            .map_md5 = map_md5,
            .mode = try result.int(u8, 0, 3),
            .n300 = try result.int(i32, 0, 4),
            .n100 = try result.int(i32, 0, 5),
            .n50 = try result.int(i32, 0, 6),
            .ngeki = try result.int(i32, 0, 7),
            .nkatu = try result.int(i32, 0, 8),
            .nmiss = try result.int(i32, 0, 9),
            .score = try result.int(i64, 0, 10),
            .max_combo = try result.int(i32, 0, 11),
            .perfect = try result.boolean(0, 12),
            .mods = try result.int(i32, 0, 13),
            .submitted_at = try result.int(i64, 0, 14),
        };
    }) orelse return null;
    defer allocator.free(metadata.username);
    defer allocator.free(metadata.map_md5);
    const frames = (try replayData(self, allocator, .stable, score_id, true)) orelse return null;
    defer allocator.free(frames);
    return @as(?[]u8, try site_replay.build(allocator, metadata, frames));
}

pub fn lazerReplay(self: anytype, allocator: std.mem.Allocator, score_id: i64) !?[]u8 {
    return replayData(self, allocator, .lazer, score_id, true);
}

pub fn stableReplay(self: anytype, allocator: std.mem.Allocator, score_id: i64) !?[]u8 {
    return replayData(self, allocator, .stable, score_id, true);
}

pub fn putScreenshot(self: anytype, user_id: i32, token: []const u8, extension: []const u8, image: []const u8) !bool {
    var user_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const encoded = try postgres.encodeBytea(self.allocator, image);
    defer self.allocator.free(encoded);
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var locked_user = try postgres.queryParams(self.allocator, lease.conn, "SELECT id FROM zigcho.users WHERE id=$1 FOR UPDATE", &.{user});
    defer locked_user.deinit();
    if (locked_user.rows() == 0) return error.UserNotFound;
    var quota = try postgres.queryParams(self.allocator, lease.conn, "SELECT count(*),coalesce(sum(octet_length(image)),0) FROM zigcho.screenshots WHERE uploader_id=$1", &.{user});
    defer quota.deinit();
    const file_count = try quota.int(usize, 0, 0);
    const byte_count = try quota.int(usize, 0, 1);
    if (!screenshot_contract.quotaAllows(file_count, byte_count, image.len)) return error.ScreenshotQuotaExceeded;
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.screenshots(token,extension,uploader_id,image) VALUES($1,$2,$3,$4) ON CONFLICT(token) DO NOTHING RETURNING 1", &.{ token, extension, user, encoded });
    defer result.deinit();
    const inserted = result.rows() == 1;
    try postgres.exec(lease.conn, "COMMIT");
    return inserted;
}

pub fn screenshot(self: anytype, allocator: std.mem.Allocator, token: []const u8, extension: []const u8) !?[]u8 {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT image FROM zigcho.screenshots WHERE token=$1 AND extension=$2", &.{ token, extension });
    defer result.deinit();
    if (result.rows() == 0) return null;
    return try postgres.decodeBytea(allocator, result.value(0, 0));
}
