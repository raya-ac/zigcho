const std = @import("std");
const max_room_scores = @import("../../lazer_multiplayer.zig").max_room_scores;
const max_room_participants = @import("../../lazer_multiplayer.zig").max_room_participants;
const multiplayer_score_grace_seconds = @import("../../lazer_multiplayer.zig").multiplayer_score_grace_seconds;
const archiveIncludesUserFallible = @import("codec.zig").archiveIncludesUserFallible;
const archivedScoreRecord = @import("codec.zig").archivedScoreRecord;
const archivedScoreTokenRecord = @import("codec.zig").archivedScoreTokenRecord;
const archivedScoreContext = @import("codec.zig").archivedScoreContext;
const restoreArchivedPlaylist = @import("codec.zig").restoreArchivedPlaylist;
const archivedLeaderboardHasRows = @import("codec.zig").archivedLeaderboardHasRows;
const RoomScoreResult = @import("../../lazer_multiplayer.zig").RoomScoreResult;
const Room = @import("../rooms/model.zig").Room;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const roomUserFromJson = @import("../wire/rest.zig").roomUserFromJson;
const writeRoomLeaderboardJson = @import("../wire/json.zig").writeRoomLeaderboardJson;

pub fn recordArchivedRoomScore(self: *Manager, user_id: i32, room_id: i64, playlist_item_id: i64, score: RoomScoreResult) !void {
    // Serialize with close/retry/checkpoint archive writers without
    // blocking live rooms, websocket connects, or matchmaking on the
    // manager-wide state mutex while storage and JSON work completes.
    self.archive_mutex.lockUncancelable(self.io);
    defer self.archive_mutex.unlock(self.io);
    self.mutex.lockUncancelable(self.io);
    if (!self.mutationAllowedLocked()) {
        const err = self.blockedMutationErrorLocked();
        self.mutex.unlock(self.io);
        return err;
    }
    self.mutex.unlock(self.io);
    const store = self.store orelse return error.StoreUnavailable;
    var archive = (try store.lazerMultiplayerRoomArchive(self.allocator, room_id)) orelse return error.MultiplayerRoomNotFound;
    defer archive.deinit();
    if (!try archiveIncludesUserFallible(self.allocator, archive.participant_ids_json, user_id)) return error.MultiplayerPermissionDenied;
    const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
    if (now_seconds > std.math.add(i64, archive.ended_at, multiplayer_score_grace_seconds) catch return error.MultiplayerRoomNotFound) return error.MultiplayerRoomNotFound;
    if ((try archivedScoreContext(self.allocator, archive.room_json, playlist_item_id)) == null) return error.MultiplayerPermissionDenied;

    var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, archive.room_json, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |*object| object,
        else => return error.InvalidMultiplayerArchive,
    };
    const records = switch ((root.getPtr("zigcho_score_records") orelse return error.InvalidMultiplayerArchive).*) {
        .array => |*array| array,
        else => return error.InvalidMultiplayerArchive,
    };
    const token_id = score.token_id orelse return error.InvalidMultiplayerScoreToken;
    const tokens = switch ((root.getPtr("zigcho_score_tokens") orelse return error.InvalidMultiplayerScoreToken).*) {
        .array => |*array| array,
        else => return error.InvalidMultiplayerArchive,
    };
    if (tokens.items.len > max_room_scores) return error.InvalidMultiplayerArchive;
    var token_index: ?usize = null;
    for (tokens.items, 0..) |value, index| {
        const token = archivedScoreTokenRecord(value) orelse return error.InvalidMultiplayerArchive;
        if (token.token_id != token_id) continue;
        if (token_index != null) return error.InvalidMultiplayerArchive;
        if (token.user_id != user_id or token.playlist_item_id != playlist_item_id) return error.InvalidMultiplayerScoreToken;
        token_index = index;
    }
    const bound_token_index = token_index orelse return error.InvalidMultiplayerScoreToken;
    const bound_token = archivedScoreTokenRecord(tokens.items[bound_token_index]) orelse return error.InvalidMultiplayerArchive;
    for (records.items) |value| if (archivedScoreRecord(value)) |existing| {
        if (existing.score_id != score.score_id) continue;
        if (existing.user_id != user_id or existing.playlist_item_id != playlist_item_id or bound_token.score_id != score.score_id) return error.InvalidMultiplayerArchive;
        return;
    } else return error.InvalidMultiplayerArchive;
    if (bound_token.score_id != null) return error.InvalidMultiplayerScoreToken;
    if (records.items.len >= max_room_scores) return error.MultiplayerScoreLimit;

    const arena = parsed.arena.allocator();
    var score_object: std.json.ObjectMap = .empty;
    try score_object.put(arena, "score_id", .{ .integer = score.score_id });
    try score_object.put(arena, "user_id", .{ .integer = user_id });
    try score_object.put(arena, "playlist_item_id", .{ .integer = playlist_item_id });
    try score_object.put(arena, "total_score", .{ .integer = score.total_score });
    try score_object.put(arena, "accuracy", .{ .float = score.accuracy });
    try score_object.put(arena, "max_combo", .{ .integer = score.max_combo });
    try score_object.put(arena, "passed", .{ .bool = score.passed });
    try records.append(.{ .object = score_object });
    const token_object = switch (tokens.items[bound_token_index]) {
        .object => |*object| object,
        else => return error.InvalidMultiplayerArchive,
    };
    try token_object.put(arena, "score_id", .{ .integer = score.score_id });

    const realtime = switch (root.get("category") orelse return error.InvalidMultiplayerArchive) {
        .string => |category| if (std.mem.eql(u8, category, "realtime"))
            true
        else if (std.mem.eql(u8, category, "normal"))
            false
        else
            return error.InvalidMultiplayerArchive,
        else => return error.InvalidMultiplayerArchive,
    };
    const snapshot = try self.allocator.create(Room);
    defer self.allocator.destroy(snapshot);
    snapshot.* = .{ .id = room_id, .settings = .{}, .host_id = archive.owner_id };
    snapshot.settings.match_type = if (realtime) 1 else 0;
    snapshot.ended = true;
    defer snapshot.deinit(self.allocator);
    try restoreArchivedPlaylist(root, snapshot);
    const participants = switch (root.get("recent_participants") orelse return error.InvalidMultiplayerArchive) {
        .array => |array| array,
        else => return error.InvalidMultiplayerArchive,
    };
    if (participants.items.len > max_room_participants) return error.InvalidMultiplayerArchive;
    for (participants.items) |value| snapshot.rememberParticipant(try roomUserFromJson(value));
    if (snapshot.participantIndex(user_id) == null) return error.MultiplayerPermissionDenied;
    try snapshot.scores.ensureTotalCapacity(self.allocator, records.items.len);
    for (records.items) |value| snapshot.scores.appendAssumeCapacity(archivedScoreRecord(value) orelse return error.InvalidMultiplayerArchive);

    var room_output: std.Io.Writer.Allocating = .init(self.allocator);
    defer room_output.deinit();
    std.json.Stringify.value(parsed.value, .{}, &room_output.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    var leaderboard_output: std.Io.Writer.Allocating = .init(self.allocator);
    defer leaderboard_output.deinit();
    writeRoomLeaderboardJson(self.allocator, &leaderboard_output.writer, snapshot, 0) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    const rebuilt_has_rows = try archivedLeaderboardHasRows(self.allocator, leaderboard_output.written());
    const existing_has_rows = try archivedLeaderboardHasRows(self.allocator, archive.leaderboard_json);
    const leaderboard_json = if (!rebuilt_has_rows and existing_has_rows) archive.leaderboard_json else leaderboard_output.written();
    try store.updateLazerMultiplayerRoomArchive(room_id, room_output.written(), leaderboard_json);
}
