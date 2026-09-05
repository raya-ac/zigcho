const std = @import("std");
const max_room_scores = @import("../../lazer_multiplayer.zig").max_room_scores;
const multiplayer_score_grace_seconds = @import("../../lazer_multiplayer.zig").multiplayer_score_grace_seconds;
const archivedScoreContext = @import("../archive/codec.zig").archivedScoreContext;
const archivedScoreTokenBound = @import("../archive/codec.zig").archivedScoreTokenBound;
const archivedRoomRealtime = @import("../archive/codec.zig").archivedRoomRealtime;
const archivedScores = @import("../archive/codec.zig").archivedScores;
const RoomScoreContext = @import("../../lazer_multiplayer.zig").RoomScoreContext;
const RoomScoreRecord = @import("../../lazer_multiplayer.zig").RoomScoreRecord;
const RoomScoreRanking = @import("../../lazer_multiplayer.zig").RoomScoreRanking;
const sortRoomScores = @import("../../lazer_multiplayer.zig").sortRoomScores;
const scoreEligibleForHighScore = @import("../../lazer_multiplayer.zig").scoreEligibleForHighScore;
const considerHighScore = @import("../../lazer_multiplayer.zig").considerHighScore;
const rankingForScore = @import("../../lazer_multiplayer.zig").rankingForScore;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const roomHasEnded = @import("../wire/json.zig").roomHasEnded;
const writeRoomLeaderboardJson = @import("../wire/json.zig").writeRoomLeaderboardJson;

pub fn scoreContext(self: *Manager, user_id: i32, room_id: i64, playlist_item_id: i64) ?RoomScoreContext {
    self.mutex.lockUncancelable(self.io);
    if (self.roomByIdLocked(room_id)) |room| {
        if (roomHasEnded(room, std.Io.Clock.real.now(self.io).toSeconds()) or room.userIndex(user_id) == null) {
            self.mutex.unlock(self.io);
            return null;
        }
        const item_index = room.itemIndex(playlist_item_id) orelse {
            self.mutex.unlock(self.io);
            return null;
        };
        const item = room.playlist[item_index].?;
        self.mutex.unlock(self.io);
        return .{ .beatmap_id = item.beatmap_id, .ruleset_id = item.ruleset_id };
    }
    self.mutex.unlock(self.io);
    var archive = (self.archivedRoomForParticipant(self.allocator, room_id, user_id) catch return null) orelse return null;
    defer archive.deinit();
    return archivedScoreContext(self.allocator, archive.room_json, playlist_item_id) catch null;
}

/// New score tokens may only be minted while the room is live.
pub fn scoreTokenContext(self: *Manager, user_id: i32, room_id: i64, playlist_item_id: i64) ?RoomScoreContext {
    if (!self.isEnabled()) return null;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (!self.mutationAllowedLocked()) return null;
    const room = self.roomByIdLocked(room_id) orelse return null;
    if (roomHasEnded(room, std.Io.Clock.real.now(self.io).toSeconds()) or room.userIndex(user_id) == null) return null;
    const item_index = room.itemIndex(playlist_item_id) orelse return null;
    const item = room.playlist[item_index].?;
    return .{ .beatmap_id = item.beatmap_id, .ruleset_id = item.ruleset_id };
}

/// Bind the opaque database token to the room and playlist item before it
/// is returned to the client. This is deliberately kept in the room
/// snapshot so an already-issued token can finish across a graceful
/// restart or after the room is archived.
pub fn bindRoomScoreToken(self: *Manager, user_id: i32, room_id: i64, playlist_item_id: i64, token_id: i64) !void {
    var mutation = try self.beginMutation();
    defer mutation.deinit();
    if (token_id <= 0) return error.InvalidMultiplayerScoreToken;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (!self.mutationAllowedLocked()) return self.blockedMutationErrorLocked();
    const room = self.roomByIdLocked(room_id) orelse return error.MultiplayerRoomNotFound;
    if (roomHasEnded(room, std.Io.Clock.real.now(self.io).toSeconds())) return error.MultiplayerRoomNotFound;
    if (room.userIndex(user_id) == null or room.itemIndex(playlist_item_id) == null) return error.MultiplayerPermissionDenied;
    for (room.score_tokens.items) |token| if (token.token_id == token_id) {
        if (token.user_id == user_id and token.playlist_item_id == playlist_item_id) return;
        return error.InvalidMultiplayerScoreToken;
    };
    if (room.score_tokens.items.len >= max_room_scores) return error.MultiplayerScoreTokenLimit;
    try room.score_tokens.append(self.allocator, .{ .token_id = token_id, .user_id = user_id, .playlist_item_id = playlist_item_id });
}

/// A token minted before the room ended may complete during osu-web's
/// bounded five-minute grace period. The participant and playlist checks
/// remain identical to archived score reads.
pub fn scoreSubmissionContext(self: *Manager, user_id: i32, room_id: i64, playlist_item_id: i64, token_id: i64) ?RoomScoreContext {
    if (!self.isEnabled()) return null;
    const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
    _ = self.archiveExpiredRooms(now_seconds);
    self.mutex.lockUncancelable(self.io);
    if (!self.mutationAllowedLocked()) {
        self.mutex.unlock(self.io);
        return null;
    }
    if (self.roomByIdLocked(room_id)) |room| {
        if (!roomHasEnded(room, now_seconds) and room.userIndex(user_id) != null and room.scoreTokenIndex(token_id, user_id, playlist_item_id) != null) {
            const item = room.playlist[
                room.itemIndex(playlist_item_id) orelse {
                    self.mutex.unlock(self.io);
                    return null;
                }
            ].?;
            self.mutex.unlock(self.io);
            return .{ .beatmap_id = item.beatmap_id, .ruleset_id = item.ruleset_id };
        }
        self.mutex.unlock(self.io);
        return null;
    }
    self.mutex.unlock(self.io);
    var archive = (self.archivedRoomForParticipant(self.allocator, room_id, user_id) catch return null) orelse return null;
    defer archive.deinit();
    if (now_seconds > std.math.add(i64, archive.ended_at, multiplayer_score_grace_seconds) catch return null) return null;
    if (!(archivedScoreTokenBound(self.allocator, archive.room_json, token_id, user_id, playlist_item_id) catch return null)) return null;
    return archivedScoreContext(self.allocator, archive.room_json, playlist_item_id) catch null;
}

pub fn roomScoreIds(self: *Manager, allocator: std.mem.Allocator, user_id: i32, room_id: i64, playlist_item_id: i64) !?[]i64 {
    self.mutex.lockUncancelable(self.io);
    if (self.roomByIdLocked(room_id)) |room| {
        if (room.userIndex(user_id) == null or room.itemIndex(playlist_item_id) == null) {
            self.mutex.unlock(self.io);
            return null;
        }
        var ids: std.ArrayList(i64) = .empty;
        errdefer ids.deinit(allocator);
        var high_scores: std.ArrayList(RoomScoreRecord) = .empty;
        defer high_scores.deinit(allocator);
        const realtime = room.settings.match_type != 0;
        for (room.scores.items) |score| if (score.playlist_item_id == playlist_item_id) considerHighScore(allocator, &high_scores, score, realtime) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        sortRoomScores(high_scores.items);
        for (high_scores.items) |score| try ids.append(allocator, score.score_id);
        return @as(?[]i64, try ids.toOwnedSlice(allocator));
    }
    self.mutex.unlock(self.io);
    var archive = (try self.archivedRoomForParticipant(allocator, room_id, user_id)) orelse return null;
    defer archive.deinit();
    if ((try archivedScoreContext(allocator, archive.room_json, playlist_item_id)) == null) return null;
    const realtime = try archivedRoomRealtime(allocator, archive.room_json);
    var ids: std.ArrayList(i64) = .empty;
    errdefer ids.deinit(allocator);
    const HighScoreCollector = struct {
        allocator: std.mem.Allocator,
        realtime: bool,
        records: std.ArrayList(RoomScoreRecord) = .empty,

        pub fn visit(visitor: *@This(), score: RoomScoreRecord) !void {
            try considerHighScore(visitor.allocator, &visitor.records, score, visitor.realtime);
        }
    };
    var collector: HighScoreCollector = .{ .allocator = allocator, .realtime = realtime };
    defer collector.records.deinit(allocator);
    try archivedScores(allocator, archive.room_json, playlist_item_id, &collector);
    sortRoomScores(collector.records.items);
    for (collector.records.items) |score| try ids.append(allocator, score.score_id);
    return @as(?[]i64, try ids.toOwnedSlice(allocator));
}

pub fn roomScoreIdForUser(self: *Manager, requester_id: i32, room_id: i64, playlist_item_id: i64, user_id: i32) ?i64 {
    self.mutex.lockUncancelable(self.io);
    if (self.roomByIdLocked(room_id)) |room| {
        if (room.userIndex(requester_id) == null or room.itemIndex(playlist_item_id) == null) {
            self.mutex.unlock(self.io);
            return null;
        }
        var best: ?RoomScoreRecord = null;
        for (room.scores.items) |score| if (score.playlist_item_id == playlist_item_id and score.user_id == user_id) {
            if (!scoreEligibleForHighScore(score, room.settings.match_type != 0)) continue;
            if (best == null or score.total_score > best.?.total_score or (score.total_score == best.?.total_score and score.score_id < best.?.score_id)) best = score;
        };
        self.mutex.unlock(self.io);
        return if (best) |score| score.score_id else null;
    }
    self.mutex.unlock(self.io);
    var archive = (self.archivedRoomForParticipant(self.allocator, room_id, requester_id) catch return null) orelse return null;
    defer archive.deinit();
    if ((archivedScoreContext(self.allocator, archive.room_json, playlist_item_id) catch return null) == null) return null;
    const realtime = archivedRoomRealtime(self.allocator, archive.room_json) catch return null;
    const Finder = struct {
        user_id: i32,
        realtime: bool,
        best: ?RoomScoreRecord = null,

        pub fn visit(visitor: *@This(), score: RoomScoreRecord) !void {
            if (score.user_id != visitor.user_id or !scoreEligibleForHighScore(score, visitor.realtime)) return;
            if (visitor.best == null or score.total_score > visitor.best.?.total_score or (score.total_score == visitor.best.?.total_score and score.score_id < visitor.best.?.score_id)) visitor.best = score;
        }
    };
    var finder: Finder = .{ .user_id = user_id, .realtime = realtime };
    archivedScores(self.allocator, archive.room_json, playlist_item_id, &finder) catch return null;
    return if (finder.best) |score| score.score_id else null;
}

pub fn roomScoreRanking(self: *Manager, allocator: std.mem.Allocator, requester_id: i32, room_id: i64, playlist_item_id: i64, score_id: i64) !?RoomScoreRanking {
    self.mutex.lockUncancelable(self.io);
    if (self.roomByIdLocked(room_id)) |room| {
        if (room.userIndex(requester_id) == null or room.itemIndex(playlist_item_id) == null) {
            self.mutex.unlock(self.io);
            return null;
        }
        var exact: ?RoomScoreRecord = null;
        var high_scores: std.ArrayList(RoomScoreRecord) = .empty;
        defer high_scores.deinit(allocator);
        const realtime = room.settings.match_type != 0;
        for (room.scores.items) |score| if (score.playlist_item_id == playlist_item_id) {
            if (score.score_id == score_id) exact = score;
            considerHighScore(allocator, &high_scores, score, realtime) catch |err| {
                self.mutex.unlock(self.io);
                return err;
            };
        };
        self.mutex.unlock(self.io);
        const found = exact orelse return null;
        sortRoomScores(high_scores.items);
        return rankingForScore(found, high_scores.items);
    }
    self.mutex.unlock(self.io);
    var archive = (try self.archivedRoomForParticipant(allocator, room_id, requester_id)) orelse return null;
    defer archive.deinit();
    if ((try archivedScoreContext(allocator, archive.room_json, playlist_item_id)) == null) return null;
    const realtime = try archivedRoomRealtime(allocator, archive.room_json);
    const RankingCollector = struct {
        allocator: std.mem.Allocator,
        realtime: bool,
        score_id: i64,
        exact: ?RoomScoreRecord = null,
        high_scores: std.ArrayList(RoomScoreRecord) = .empty,

        pub fn visit(visitor: *@This(), score: RoomScoreRecord) !void {
            if (score.score_id == visitor.score_id) visitor.exact = score;
            try considerHighScore(visitor.allocator, &visitor.high_scores, score, visitor.realtime);
        }
    };
    var collector: RankingCollector = .{ .allocator = allocator, .realtime = realtime, .score_id = score_id };
    defer collector.high_scores.deinit(allocator);
    try archivedScores(allocator, archive.room_json, playlist_item_id, &collector);
    const found = collector.exact orelse return null;
    sortRoomScores(collector.high_scores.items);
    return rankingForScore(found, collector.high_scores.items);
}

pub fn roomContainsScore(self: *Manager, requester_id: i32, room_id: i64, playlist_item_id: i64, score_id: i64) bool {
    self.mutex.lockUncancelable(self.io);
    if (self.roomByIdLocked(room_id)) |room| {
        if (room.userIndex(requester_id) == null or room.itemIndex(playlist_item_id) == null) {
            self.mutex.unlock(self.io);
            return false;
        }
        for (room.scores.items) |score| if (score.playlist_item_id == playlist_item_id and score.score_id == score_id) {
            self.mutex.unlock(self.io);
            return true;
        };
        self.mutex.unlock(self.io);
        return false;
    }
    self.mutex.unlock(self.io);
    var archive = (self.archivedRoomForParticipant(self.allocator, room_id, requester_id) catch return false) orelse return false;
    defer archive.deinit();
    if ((archivedScoreContext(self.allocator, archive.room_json, playlist_item_id) catch return false) == null) return false;
    const Finder = struct {
        score_id: i64,
        found: bool = false,

        pub fn visit(visitor: *@This(), score: RoomScoreRecord) !void {
            if (score.score_id == visitor.score_id) visitor.found = true;
        }
    };
    var finder: Finder = .{ .score_id = score_id };
    archivedScores(self.allocator, archive.room_json, playlist_item_id, &finder) catch return false;
    return finder.found;
}

pub fn roomLeaderboardJson(self: *Manager, allocator: std.mem.Allocator, requester_id: i32, room_id: i64) !?[]u8 {
    self.mutex.lockUncancelable(self.io);
    if (self.roomByIdLocked(room_id)) |room| {
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        writeRoomLeaderboardJson(allocator, &output.writer, room, requester_id) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        return @as(?[]u8, try output.toOwnedSlice());
    }
    self.mutex.unlock(self.io);
    const store = self.store orelse return null;
    var archive = (try store.lazerMultiplayerRoomArchive(allocator, room_id)) orelse return null;
    defer archive.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try self.writeSanitizedArchiveLeaderboardJson(&output.writer, archive.leaderboard_json);
    return @as(?[]u8, try output.toOwnedSlice());
}
