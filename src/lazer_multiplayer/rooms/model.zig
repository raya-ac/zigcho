const std = @import("std");
const max_users = @import("../../lazer_multiplayer.zig").max_users;
const max_playlist = @import("../../lazer_multiplayer.zig").max_playlist;
const max_room_participants = @import("../../lazer_multiplayer.zig").max_room_participants;
const RoomScoreTokenRecord = @import("../../lazer_multiplayer.zig").RoomScoreTokenRecord;
const RoomScoreRecord = @import("../../lazer_multiplayer.zig").RoomScoreRecord;
const Text64 = @import("../../lazer_multiplayer.zig").Text64;
const PlaylistItem = @import("../../lazer_multiplayer.zig").PlaylistItem;
const RoomUser = @import("../../lazer_multiplayer.zig").RoomUser;
const RoomParticipant = @import("../../lazer_multiplayer.zig").RoomParticipant;
const MatchmakingState = @import("../../lazer_multiplayer.zig").MatchmakingState;
const RankedPlayState = @import("../../lazer_multiplayer.zig").RankedPlayState;
const MatchStartCountdownState = @import("../../lazer_multiplayer.zig").MatchStartCountdownState;
const Settings = @import("../../lazer_multiplayer.zig").Settings;
const deinit = @import("../lifecycle.zig").deinit;

pub const Room = struct {
    id: i64,
    state: u8 = 0,
    settings: Settings,
    starts_at: i64 = 0,
    ends_at: i64 = 0,
    max_attempts: ?i32 = null,
    locked: bool = false,
    match_start_countdown: ?MatchStartCountdownState = null,
    users: [max_users]?RoomUser = [_]?RoomUser{null} ** max_users,
    user_count: usize = 0,
    host_id: i32,
    host_name: Text64 = .{},
    host_country: [2]u8 = .{ 'X', 'X' },
    playlist: [max_playlist]?PlaylistItem = [_]?PlaylistItem{null} ** max_playlist,
    playlist_count: usize = 0,
    channel_id: i32 = 0,
    matchmaking: ?MatchmakingState = null,
    ranked_play: ?RankedPlayState = null,
    allowed_users: [max_users]i32 = [_]i32{0} ** max_users,
    allowed_user_count: usize = 0,
    score_tokens: std.ArrayList(RoomScoreTokenRecord) = .empty,
    scores: std.ArrayList(RoomScoreRecord) = .empty,
    participants: [max_room_participants]?RoomParticipant = [_]?RoomParticipant{null} ** max_room_participants,
    participant_count: usize = 0,
    ended: bool = false,

    pub fn deinit(self: *Room, allocator: std.mem.Allocator) void {
        self.score_tokens.deinit(allocator);
        self.scores.deinit(allocator);
    }

    pub fn scoreTokenIndex(self: *const Room, token_id: i64, user_id: i32, playlist_item_id: i64) ?usize {
        for (self.score_tokens.items, 0..) |token, index| {
            if (token.token_id == token_id and token.user_id == user_id and token.playlist_item_id == playlist_item_id) return index;
        }
        return null;
    }

    pub fn userIndex(self: *const Room, user_id: i32) ?usize {
        for (self.users, 0..) |entry, index| if (entry) |user| if (user.id == user_id) return index;
        return null;
    }

    pub fn itemIndex(self: *const Room, item_id: i64) ?usize {
        for (self.playlist, 0..) |entry, index| if (entry) |item| if (item.id == item_id) return index;
        return null;
    }

    pub fn participantIndex(self: *const Room, user_id: i32) ?usize {
        for (self.participants[0..self.participant_count], 0..) |entry, index| if (entry) |user| if (user.id == user_id) return index;
        return null;
    }

    pub fn rememberParticipant(self: *Room, user: RoomUser) void {
        if (self.participantIndex(user.id)) |index| {
            self.participants[index] = .{ .id = user.id, .name = user.name, .country = user.country };
            return;
        }
        if (self.participant_count == self.participants.len) {
            for (1..self.participant_count) |index| self.participants[index - 1] = self.participants[index];
            self.participant_count -= 1;
        }
        self.participants[self.participant_count] = .{ .id = user.id, .name = user.name, .country = user.country };
        self.participant_count += 1;
    }

    pub fn userAllowed(self: *const Room, user_id: i32) bool {
        if (self.allowed_user_count == 0) return true;
        return std.mem.indexOfScalar(i32, self.allowed_users[0..self.allowed_user_count], user_id) != null;
    }
};
