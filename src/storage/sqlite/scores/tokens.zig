const std = @import("std");
const lazer = @import("../../../lazer.zig");
const ConsumedLazerScoreToken = @import("../../contracts.zig").ConsumedLazerScoreToken;
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const lazer_room_score_token_tag = @import("../../../storage.zig").Store.lazer_room_score_token_tag;
const lazer_room_score_token_mask = @import("../../../storage.zig").Store.lazer_room_score_token_mask;
const lazer_room_score_token_payload_mask = @import("../../../storage.zig").Store.lazer_room_score_token_payload_mask;

pub fn isLazerRoomScoreToken(token_id: i64) bool {
    if (token_id <= 0) return false;
    return (@as(u64, @intCast(token_id)) & lazer_room_score_token_mask) == lazer_room_score_token_tag;
}

pub fn createLazerScoreToken(self: *Store, user_id: i32, beatmap_id: i32, beatmap_hash: []const u8, ruleset_id: i64, version_hash: []const u8) !i64 {
    return self.createLazerScoreTokenScoped(user_id, beatmap_id, beatmap_hash, ruleset_id, version_hash, false);
}

pub fn createLazerRoomScoreToken(self: *Store, user_id: i32, beatmap_id: i32, beatmap_hash: []const u8, ruleset_id: i64, version_hash: []const u8) !i64 {
    return self.createLazerScoreTokenScoped(user_id, beatmap_id, beatmap_hash, ruleset_id, version_hash, true);
}

pub fn discardUnusedLazerRoomScoreToken(self: *Store, user_id: i32, token_id: i64) !bool {
    if (!isLazerRoomScoreToken(token_id)) return false;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "DELETE FROM lazer_score_tokens WHERE id=?1 AND user_id=?2 AND consumed_at IS NULL AND score_id IS NULL", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, token_id);
    _ = c.sqlite3_bind_int(stmt, 2, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return c.sqlite3_changes(self.db) == 1;
}

pub fn createLazerScoreTokenScoped(self: *Store, user_id: i32, beatmap_id: i32, beatmap_hash: []const u8, ruleset_id: i64, version_hash: []const u8, room_scoped: bool) !i64 {
    var random_bytes: [8]u8 = undefined;
    try std.Io.randomSecure(self.io, &random_bytes);
    var raw = std.mem.readInt(u64, &random_bytes, .little) & std.math.maxInt(i64);
    if (room_scoped) {
        raw = lazer_room_score_token_tag | (raw & lazer_room_score_token_payload_mask);
    } else if ((raw & lazer_room_score_token_mask) == lazer_room_score_token_tag) {
        // Tokens minted before room scoring existed occupied the full
        // positive i64 range. Keep the reserved room prefix tiny so an
        // already-issued legacy token has only a 1-in-2^23 collision, and
        // never mint a new solo token inside that namespace.
        raw &= ~lazer_room_score_token_mask;
    }
    const token_id: i64 = @intCast(raw | 1);
    const now = std.Io.Clock.real.now(self.io).toSeconds();
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};

    {
        var map: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT md5 FROM beatmaps WHERE id=?1", -1, &map, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(map);
        _ = c.sqlite3_bind_int(map, 1, beatmap_id);
        if (c.sqlite3_step(map) != c.SQLITE_ROW) return error.BeatmapNotFound;
        if (!std.ascii.eqlIgnoreCase(std.mem.span(c.sqlite3_column_text(map, 0)), beatmap_hash)) return error.BeatmapHashMismatch;
    }

    var prune: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "DELETE FROM lazer_score_tokens WHERE expires_at<?1 OR (consumed_at IS NOT NULL AND consumed_at<?2)", -1, &prune, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_int64(prune, 1, now - 86_400);
    _ = c.sqlite3_bind_int64(prune, 2, now - 86_400);
    if (c.sqlite3_step(prune) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    _ = c.sqlite3_finalize(prune);

    {
        var insert: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT INTO lazer_score_tokens(id,user_id,beatmap_id,beatmap_hash,ruleset_id,version_hash,expires_at) VALUES(?1,?2,?3,?4,?5,?6,?7)", -1, &insert, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(insert);
        _ = c.sqlite3_bind_int64(insert, 1, token_id);
        _ = c.sqlite3_bind_int(insert, 2, user_id);
        _ = c.sqlite3_bind_int(insert, 3, beatmap_id);
        _ = c.sqlite3_bind_text(insert, 4, beatmap_hash.ptr, @intCast(beatmap_hash.len), null);
        _ = c.sqlite3_bind_int64(insert, 5, ruleset_id);
        _ = c.sqlite3_bind_text(insert, 6, version_hash.ptr, @intCast(version_hash.len), null);
        _ = c.sqlite3_bind_int64(insert, 7, now + lazer.score_token_lifetime_seconds);
        if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }
    try self.exec("COMMIT");
    return token_id;
}

pub fn submitLazerScoreToken(self: *Store, user_id: i32, beatmap_id: i32, token_id: i64, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8) !i64 {
    return self.submitLazerScoreTokenScoped(user_id, beatmap_id, token_id, input, pp_value, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data, false);
}

pub fn submitLazerRoomScoreToken(self: *Store, user_id: i32, beatmap_id: i32, token_id: i64, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8) !i64 {
    return self.submitLazerScoreTokenScoped(user_id, beatmap_id, token_id, input, pp_value, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data, true);
}

pub fn submitLazerScoreTokenScoped(self: *Store, user_id: i32, beatmap_id: i32, token_id: i64, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8, room_scoped: bool) !i64 {
    if (isLazerRoomScoreToken(token_id) != room_scoped) return error.InvalidLazerScoreToken;
    const now = std.Io.Clock.real.now(self.io).toSeconds();
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};

    {
        var token: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT user_id,beatmap_id,ruleset_id,expires_at,consumed_at FROM lazer_score_tokens WHERE id=?1", -1, &token, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(token);
        _ = c.sqlite3_bind_int64(token, 1, token_id);
        if (c.sqlite3_step(token) != c.SQLITE_ROW) return error.InvalidLazerScoreToken;
        if (c.sqlite3_column_int(token, 0) != user_id) return error.ForeignLazerScoreToken;
        if (c.sqlite3_column_int(token, 1) != beatmap_id or c.sqlite3_column_int64(token, 2) != input.ruleset_id) return error.LazerScoreTokenMismatch;
        if (c.sqlite3_column_int64(token, 3) <= now) return error.LazerScoreTokenExpired;
        if (c.sqlite3_column_type(token, 4) != c.SQLITE_NULL) return error.LazerScoreTokenUsed;
    }

    const score_id = try self.insertLazerScoreLocked(user_id, input, pp_value, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data);
    {
        var consume: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE lazer_score_tokens SET consumed_at=?1,score_id=?2 WHERE id=?3 AND consumed_at IS NULL", -1, &consume, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(consume);
        _ = c.sqlite3_bind_int64(consume, 1, now);
        _ = c.sqlite3_bind_int64(consume, 2, score_id);
        _ = c.sqlite3_bind_int64(consume, 3, token_id);
        if (c.sqlite3_step(consume) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.LazerScoreTokenUsed;
    }
    try self.exec("COMMIT");
    return score_id;
}

/// Recover the canonical score produced by a token whose database commit
/// succeeded but whose room/archive attachment failed afterward. The
/// caller can safely retry only that exact score; client-supplied retry
/// fields are never trusted for the repair.
pub fn consumedLazerScoreToken(self: *Store, user_id: i32, beatmap_id: i32, token_id: i64) !?ConsumedLazerScoreToken {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT t.score_id,s.total_score,s.accuracy,s.max_combo,s.passed FROM lazer_score_tokens t JOIN lazer_scores s ON s.id=t.score_id WHERE t.id=?1 AND t.user_id=?2 AND t.beatmap_id=?3 AND t.consumed_at IS NOT NULL", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, token_id);
    _ = c.sqlite3_bind_int(stmt, 2, user_id);
    _ = c.sqlite3_bind_int(stmt, 3, beatmap_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return .{
        .score_id = c.sqlite3_column_int64(stmt, 0),
        .total_score = c.sqlite3_column_int64(stmt, 1),
        .accuracy = c.sqlite3_column_double(stmt, 2),
        .max_combo = c.sqlite3_column_int(stmt, 3),
        .passed = c.sqlite3_column_int(stmt, 4) != 0,
    };
}
