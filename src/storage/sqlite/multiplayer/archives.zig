const std = @import("std");
const c = @import("../../../storage.zig").c;
const ranked_play_rating_delta = @import("../../contracts.zig").ranked_play_rating_delta;
const validateRankedPlayResult = @import("../../contracts.zig").validateRankedPlayResult;
const Store = @import("../../../storage.zig").Store;
const MultiplayerRoomArchive = @import("../../contracts.zig").MultiplayerRoomArchive;
const LazerRankedRating = @import("../../contracts.zig").LazerRankedRating;
const LazerRankedResult = @import("../../contracts.zig").LazerRankedResult;

pub fn multiplayerRoomArchiveFromStatement(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !MultiplayerRoomArchive {
    const category = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)));
    errdefer allocator.free(category);
    const room_json = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3)));
    errdefer allocator.free(room_json);
    const leaderboard_json = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 4)));
    errdefer allocator.free(leaderboard_json);
    const participant_ids_json = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 5)));
    return .{
        .allocator = allocator,
        .room_id = c.sqlite3_column_int64(stmt, 0),
        .owner_id = c.sqlite3_column_int(stmt, 1),
        .category = category,
        .room_json = room_json,
        .leaderboard_json = leaderboard_json,
        .participant_ids_json = participant_ids_json,
        .ended_at = c.sqlite3_column_int64(stmt, 6),
    };
}

pub fn nextLazerMultiplayerRoomId(self: *Store) !i64 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT max(coalesce((SELECT max(room_id) FROM lazer_multiplayer_room_history),0),coalesce((SELECT max(room_id) FROM lazer_ranked_matches),0))+1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return c.sqlite3_column_int64(stmt, 0);
}

pub fn saveLazerMultiplayerRoomArchive(self: *Store, room_id: i64, owner_id: i32, category: []const u8, room_json: []const u8, leaderboard_json: []const u8, participant_ids_json: []const u8) !void {
    if (room_id <= 0 or owner_id <= 0 or room_json.len == 0 or room_json.len > 8 * 1024 * 1024 or leaderboard_json.len == 0 or leaderboard_json.len > 512 * 1024 or participant_ids_json.len == 0 or participant_ids_json.len > 4096) return error.InvalidMultiplayerArchive;
    if (!std.mem.eql(u8, category, "normal") and !std.mem.eql(u8, category, "realtime") and !std.mem.eql(u8, category, "spotlight") and !std.mem.eql(u8, category, "featured_artist")) return error.InvalidMultiplayerArchive;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "INSERT INTO lazer_multiplayer_room_history(room_id,owner_id,category,room_json,leaderboard_json,participant_ids_json,ended_at) VALUES(?1,?2,?3,?4,?5,?6,unixepoch()) ON CONFLICT(room_id) DO UPDATE SET owner_id=excluded.owner_id,category=excluded.category,room_json=excluded.room_json,leaderboard_json=excluded.leaderboard_json,participant_ids_json=excluded.participant_ids_json,ended_at=excluded.ended_at";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, room_id);
    _ = c.sqlite3_bind_int(stmt, 2, owner_id);
    _ = c.sqlite3_bind_text(stmt, 3, category.ptr, @intCast(category.len), null);
    _ = c.sqlite3_bind_text(stmt, 4, room_json.ptr, @intCast(room_json.len), null);
    _ = c.sqlite3_bind_text(stmt, 5, leaderboard_json.ptr, @intCast(leaderboard_json.len), null);
    _ = c.sqlite3_bind_text(stmt, 6, participant_ids_json.ptr, @intCast(participant_ids_json.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn lazerMultiplayerRoomArchive(self: *Store, allocator: std.mem.Allocator, room_id: i64) !?MultiplayerRoomArchive {
    if (room_id <= 0) return null;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT room_id,owner_id,category,room_json,leaderboard_json,participant_ids_json,ended_at FROM lazer_multiplayer_room_history WHERE room_id=?1 AND instr(room_json,'\"zigcho_resumable\":true')=0", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, room_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return try multiplayerRoomArchiveFromStatement(allocator, stmt.?);
}

pub fn lazerMultiplayerRoomArchives(self: *Store, allocator: std.mem.Allocator, limit: u8) ![]MultiplayerRoomArchive {
    if (limit == 0) return allocator.alloc(MultiplayerRoomArchive, 0);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT room_id,owner_id,category,room_json,leaderboard_json,participant_ids_json,ended_at FROM lazer_multiplayer_room_history WHERE instr(room_json,'\"zigcho_resumable\":true')=0 ORDER BY ended_at DESC,room_id DESC LIMIT ?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, limit);
    var archives: std.ArrayList(MultiplayerRoomArchive) = .empty;
    errdefer {
        for (archives.items) |*archive| archive.deinit();
        archives.deinit(allocator);
    }
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        var archive = try multiplayerRoomArchiveFromStatement(allocator, stmt.?);
        archives.append(allocator, archive) catch |err| {
            archive.deinit();
            return err;
        };
    }
    return archives.toOwnedSlice(allocator);
}

pub fn lazerMultiplayerRoomCheckpoints(self: *Store, allocator: std.mem.Allocator) ![]MultiplayerRoomArchive {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT room_id,owner_id,category,room_json,leaderboard_json,participant_ids_json,ended_at FROM lazer_multiplayer_room_history WHERE instr(room_json,'\"zigcho_resumable\":true')>0 ORDER BY room_id LIMIT 64", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    var checkpoints: std.ArrayList(MultiplayerRoomArchive) = .empty;
    errdefer {
        for (checkpoints.items) |*checkpoint| checkpoint.deinit();
        checkpoints.deinit(allocator);
    }
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        var checkpoint = try multiplayerRoomArchiveFromStatement(allocator, stmt.?);
        checkpoints.append(allocator, checkpoint) catch |err| {
            checkpoint.deinit();
            return err;
        };
    }
    return checkpoints.toOwnedSlice(allocator);
}

pub fn deleteLazerMultiplayerRoomCheckpoint(self: *Store, room_id: i64) !void {
    if (room_id <= 0) return error.InvalidMultiplayerArchive;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "DELETE FROM lazer_multiplayer_room_history WHERE room_id=?1 AND instr(room_json,'\"zigcho_resumable\":true')>0", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, room_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn updateLazerMultiplayerRoomArchive(self: *Store, room_id: i64, room_json: []const u8, leaderboard_json: []const u8) !void {
    if (room_id <= 0 or room_json.len == 0 or room_json.len > 8 * 1024 * 1024 or leaderboard_json.len == 0 or leaderboard_json.len > 512 * 1024) return error.InvalidMultiplayerArchive;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "UPDATE lazer_multiplayer_room_history SET room_json=?2,leaderboard_json=?3 WHERE room_id=?1 AND instr(room_json,'\"zigcho_resumable\":true')=0";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, room_id);
    _ = c.sqlite3_bind_text(stmt, 2, room_json.ptr, @intCast(room_json.len), null);
    _ = c.sqlite3_bind_text(stmt, 3, leaderboard_json.ptr, @intCast(leaderboard_json.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    if (c.sqlite3_changes(self.db) != 1) return error.InvalidMultiplayerArchive;
}

pub fn lazerRankedRating(self: *Store, user_id: i32, ruleset_id: u8) !LazerRankedRating {
    if (user_id <= 0 or ruleset_id > 3) return error.InvalidRankedPlayUser;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT rating,games_played,wins,losses FROM lazer_ranked_ratings WHERE user_id=?1 AND ruleset_id=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, ruleset_id);
    const step = c.sqlite3_step(stmt);
    if (step == c.SQLITE_DONE) return .{};
    if (step != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return .{
        .rating = c.sqlite3_column_int(stmt, 0),
        .games_played = c.sqlite3_column_int(stmt, 1),
        .wins = c.sqlite3_column_int(stmt, 2),
        .losses = c.sqlite3_column_int(stmt, 3),
    };
}

pub fn applyLazerRankedResult(self: *Store, room_id: i64, ruleset_id: u8, winner_id: i32, loser_id: i32) !LazerRankedResult {
    try validateRankedPlayResult(room_id, ruleset_id, winner_id, loser_id);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    var committed = false;
    defer if (!committed) self.exec("ROLLBACK") catch {};

    var existing: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT ruleset_id,winner_id,loser_id,winner_rating_before,winner_rating_after,loser_rating_before,loser_rating_after FROM lazer_ranked_matches WHERE room_id=?1", -1, &existing, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_int64(existing, 1, room_id);
    const existing_step = c.sqlite3_step(existing);
    if (existing_step == c.SQLITE_ROW) {
        if (c.sqlite3_column_int(existing, 0) != ruleset_id or c.sqlite3_column_int(existing, 1) != winner_id or c.sqlite3_column_int(existing, 2) != loser_id) {
            _ = c.sqlite3_finalize(existing);
            return error.RankedPlayResultConflict;
        }
        const result: LazerRankedResult = .{
            .applied = false,
            .winner_rating_before = c.sqlite3_column_int(existing, 3),
            .winner_rating_after = c.sqlite3_column_int(existing, 4),
            .loser_rating_before = c.sqlite3_column_int(existing, 5),
            .loser_rating_after = c.sqlite3_column_int(existing, 6),
        };
        _ = c.sqlite3_finalize(existing);
        try self.exec("COMMIT");
        committed = true;
        return result;
    }
    if (existing_step != c.SQLITE_DONE) {
        _ = c.sqlite3_finalize(existing);
        return error.DatabaseQueryFailed;
    }
    _ = c.sqlite3_finalize(existing);

    var initialise: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO lazer_ranked_ratings(user_id,ruleset_id) VALUES(?1,?3),(?2,?3)", -1, &initialise, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_int(initialise, 1, winner_id);
    _ = c.sqlite3_bind_int(initialise, 2, loser_id);
    _ = c.sqlite3_bind_int(initialise, 3, ruleset_id);
    if (c.sqlite3_step(initialise) != c.SQLITE_DONE) {
        _ = c.sqlite3_finalize(initialise);
        return error.DatabaseQueryFailed;
    }
    _ = c.sqlite3_finalize(initialise);

    var ratings: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT user_id,rating FROM lazer_ranked_ratings WHERE ruleset_id=?3 AND user_id IN(?1,?2) ORDER BY user_id", -1, &ratings, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_int(ratings, 1, winner_id);
    _ = c.sqlite3_bind_int(ratings, 2, loser_id);
    _ = c.sqlite3_bind_int(ratings, 3, ruleset_id);
    var winner_before: ?i32 = null;
    var loser_before: ?i32 = null;
    while (c.sqlite3_step(ratings) == c.SQLITE_ROW) {
        const user_id = c.sqlite3_column_int(ratings, 0);
        if (user_id == winner_id) winner_before = c.sqlite3_column_int(ratings, 1);
        if (user_id == loser_id) loser_before = c.sqlite3_column_int(ratings, 1);
    }
    _ = c.sqlite3_finalize(ratings);
    const winner_rating_before = winner_before orelse return error.DatabaseQueryFailed;
    const loser_rating_before = loser_before orelse return error.DatabaseQueryFailed;
    const winner_rating_after = std.math.add(i32, winner_rating_before, ranked_play_rating_delta) catch return error.RankedPlayRatingOverflow;
    const loser_rating_after = std.math.sub(i32, loser_rating_before, ranked_play_rating_delta) catch return error.RankedPlayRatingOverflow;

    var update: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE lazer_ranked_ratings SET rating=CASE user_id WHEN ?1 THEN ?4 ELSE ?5 END,games_played=games_played+1,wins=wins+CASE WHEN user_id=?1 THEN 1 ELSE 0 END,losses=losses+CASE WHEN user_id=?2 THEN 1 ELSE 0 END,updated_at=unixepoch() WHERE ruleset_id=?3 AND user_id IN(?1,?2)", -1, &update, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_int(update, 1, winner_id);
    _ = c.sqlite3_bind_int(update, 2, loser_id);
    _ = c.sqlite3_bind_int(update, 3, ruleset_id);
    _ = c.sqlite3_bind_int(update, 4, winner_rating_after);
    _ = c.sqlite3_bind_int(update, 5, loser_rating_after);
    if (c.sqlite3_step(update) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 2) {
        _ = c.sqlite3_finalize(update);
        return error.DatabaseQueryFailed;
    }
    _ = c.sqlite3_finalize(update);

    var insert_match: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO lazer_ranked_matches(room_id,ruleset_id,winner_id,loser_id,winner_rating_before,winner_rating_after,loser_rating_before,loser_rating_after) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)", -1, &insert_match, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_int64(insert_match, 1, room_id);
    _ = c.sqlite3_bind_int(insert_match, 2, ruleset_id);
    _ = c.sqlite3_bind_int(insert_match, 3, winner_id);
    _ = c.sqlite3_bind_int(insert_match, 4, loser_id);
    _ = c.sqlite3_bind_int(insert_match, 5, winner_rating_before);
    _ = c.sqlite3_bind_int(insert_match, 6, winner_rating_after);
    _ = c.sqlite3_bind_int(insert_match, 7, loser_rating_before);
    _ = c.sqlite3_bind_int(insert_match, 8, loser_rating_after);
    if (c.sqlite3_step(insert_match) != c.SQLITE_DONE) {
        _ = c.sqlite3_finalize(insert_match);
        return error.DatabaseQueryFailed;
    }
    _ = c.sqlite3_finalize(insert_match);
    try self.exec("COMMIT");
    committed = true;
    return .{
        .applied = true,
        .winner_rating_before = winner_rating_before,
        .winner_rating_after = winner_rating_after,
        .loser_rating_before = loser_rating_before,
        .loser_rating_after = loser_rating_after,
    };
}
