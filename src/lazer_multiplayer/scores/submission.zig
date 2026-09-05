const std = @import("std");
const max_connections = @import("../../lazer_multiplayer.zig").max_connections;
const max_room_scores = @import("../../lazer_multiplayer.zig").max_room_scores;
const RoomScoreResult = @import("../../lazer_multiplayer.zig").RoomScoreResult;
const RoomScoreRecord = @import("../../lazer_multiplayer.zig").RoomScoreRecord;
const Connection = @import("../transport/model.zig").Connection;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const recomputeMatchmakingPlacements = @import("../ranked/state.zig").recomputeMatchmakingPlacements;
const roomHasEnded = @import("../wire/json.zig").roomHasEnded;
const eventMatchStateOwned = @import("../transport/events.zig").eventMatchStateOwned;
const sendRecipients = @import("../transport/connections.zig").sendRecipients;
const releaseRecipients = @import("../transport/connections.zig").releaseRecipients;

pub fn recordRoomScore(self: *Manager, user_id: i32, room_id: i64, playlist_item_id: i64, score: RoomScoreResult) !void {
    var mutation = try self.beginMutation();
    defer mutation.deinit();
    var recipients: [max_connections]*Connection = undefined;
    var state_event: ?[]u8 = null;
    defer if (state_event) |event| self.allocator.free(event);
    self.mutex.lockUncancelable(self.io);
    if (!self.mutationAllowedLocked()) {
        const err = self.blockedMutationErrorLocked();
        self.mutex.unlock(self.io);
        return err;
    }
    const room = self.roomByIdLocked(room_id) orelse {
        self.mutex.unlock(self.io);
        return self.recordArchivedRoomScore(user_id, room_id, playlist_item_id, score);
    };
    if (roomHasEnded(room, std.Io.Clock.real.now(self.io).toSeconds())) {
        self.mutex.unlock(self.io);
        return error.MultiplayerRoomNotFound;
    }
    if (room.userIndex(user_id) == null or room.itemIndex(playlist_item_id) == null) {
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    }
    const record: RoomScoreRecord = .{
        .score_id = score.score_id,
        .user_id = user_id,
        .playlist_item_id = playlist_item_id,
        .total_score = score.total_score,
        .accuracy = score.accuracy,
        .max_combo = score.max_combo,
        .passed = score.passed,
    };
    for (room.scores.items) |existing| if (existing.score_id == score.score_id) {
        if (existing.user_id != user_id or existing.playlist_item_id != playlist_item_id) {
            self.mutex.unlock(self.io);
            return error.InvalidMultiplayerRoomScore;
        }
        if (score.token_id) |token_id| if (room.scoreTokenIndex(token_id, user_id, playlist_item_id)) |index| {
            if (room.score_tokens.items[index].score_id != score.score_id) {
                self.mutex.unlock(self.io);
                return error.InvalidMultiplayerScoreToken;
            }
        } else {
            self.mutex.unlock(self.io);
            return error.InvalidMultiplayerScoreToken;
        };
        self.mutex.unlock(self.io);
        return;
    };
    const token_index: ?usize = if (score.token_id) |token_id|
        room.scoreTokenIndex(token_id, user_id, playlist_item_id) orelse {
            self.mutex.unlock(self.io);
            return error.InvalidMultiplayerScoreToken;
        }
    else
        null;
    if (token_index) |index| if (room.score_tokens.items[index].score_id != null) {
        self.mutex.unlock(self.io);
        return error.InvalidMultiplayerScoreToken;
    };
    if (room.scores.items.len >= max_room_scores) {
        self.mutex.unlock(self.io);
        return error.MultiplayerScoreLimit;
    }
    room.scores.append(self.allocator, record) catch |err| {
        self.mutex.unlock(self.io);
        return err;
    };
    if (room.ranked_play) |*ranked| {
        if (ranked.gameplay_item != playlist_item_id or ranked.current_round == 0) {
            if (token_index) |index| room.score_tokens.items[index].score_id = score.score_id;
            self.mutex.unlock(self.io);
            return;
        }
        const user_index = ranked.userIndex(user_id) orelse {
            room.scores.items.len -= 1;
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        };
        const user_before = ranked.users[user_index].?;
        ranked.users[user_index].?.total_score = score.total_score;
        ranked.users[user_index].?.submitted = true;
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        state_event = eventMatchStateOwned(self.allocator, room) catch |err| {
            ranked.users[user_index] = user_before;
            room.scores.items.len -= 1;
            self.mutex.unlock(self.io);
            return err;
        };
        if (token_index) |index| room.score_tokens.items[index].score_id = score.score_id;
        self.mutex.unlock(self.io);
        sendRecipients(recipients[0..count], state_event.?);
        return;
    }
    if (room.matchmaking == null or room.matchmaking.?.gameplay_item != playlist_item_id or room.matchmaking.?.current_round == 0) {
        if (token_index) |index| room.score_tokens.items[index].score_id = score.score_id;
        self.mutex.unlock(self.io);
        return;
    }
    const user_index = room.matchmaking.?.userIndex(user_id) orelse {
        room.scores.items.len -= 1;
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    };
    const matchmaking_before = room.matchmaking.?;
    const round_index = room.matchmaking.?.current_round - 1;
    room.matchmaking.?.users[user_index].?.rounds[round_index] = .{
        .round = room.matchmaking.?.current_round,
        .total_score = score.total_score,
        .accuracy = score.accuracy,
        .max_combo = score.max_combo,
        .passed = score.passed,
    };
    recomputeMatchmakingPlacements(&room.matchmaking.?);
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    state_event = eventMatchStateOwned(self.allocator, room) catch |err| {
        room.matchmaking = matchmaking_before;
        room.scores.items.len -= 1;
        self.mutex.unlock(self.io);
        return err;
    };
    if (token_index) |index| room.score_tokens.items[index].score_id = score.score_id;
    self.mutex.unlock(self.io);
    sendRecipients(recipients[0..count], state_event.?);
}
