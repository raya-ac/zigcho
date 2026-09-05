const std = @import("std");
const max_connections = @import("../../lazer_multiplayer.zig").max_connections;
const max_playlist = @import("../../lazer_multiplayer.zig").max_playlist;
const ranked_hand_size = @import("../../lazer_multiplayer.zig").ranked_hand_size;
const matchmaking_stage = @import("../../lazer_multiplayer.zig").matchmaking_stage;
const ranked_stage = @import("../../lazer_multiplayer.zig").ranked_stage;
const MessagePackReader = @import("../../lazer_multiplayer.zig").MessagePackReader;
const eventIntegersOwned = @import("../../lazer_multiplayer.zig").eventIntegersOwned;
const PlaylistItem = @import("../../lazer_multiplayer.zig").PlaylistItem;
const RankedCard = @import("../../lazer_multiplayer.zig").RankedCard;
const RankedStageCountdown = @import("../../lazer_multiplayer.zig").RankedStageCountdown;
const Settings = @import("../../lazer_multiplayer.zig").Settings;
const Room = @import("../rooms/model.zig").Room;
const Connection = @import("../transport/model.zig").Connection;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const resetRoomBeatmapAvailability = @import("../rooms/state.zig").resetRoomBeatmapAvailability;
const rankedDrawCard = @import("state.zig").rankedDrawCard;
const rankedRemoveCard = @import("state.zig").rankedRemoveCard;
const parseRankedCardId = @import("state.zig").parseRankedCardId;
const parseRankedCardList = @import("state.zig").parseRankedCardList;
const eventMatchStateOwned = @import("../transport/events.zig").eventMatchStateOwned;
const eventRankedCountdownStartedOwned = @import("../transport/events.zig").eventRankedCountdownStartedOwned;
const eventRankedCountdownStoppedOwned = @import("../transport/events.zig").eventRankedCountdownStoppedOwned;
const eventRankedHandReplayOwned = @import("../transport/events.zig").eventRankedHandReplayOwned;
const eventSettingsOwned = @import("../transport/events.zig").eventSettingsOwned;
const eventRankedCardUserOwned = @import("../transport/events.zig").eventRankedCardUserOwned;
const eventRankedCardRevealedOwned = @import("../transport/events.zig").eventRankedCardRevealedOwned;
const eventRankedCardPlayedOwned = @import("../transport/events.zig").eventRankedCardPlayedOwned;
const sendRecipients = @import("../transport/connections.zig").sendRecipients;
const releaseRecipients = @import("../transport/connections.zig").releaseRecipients;

pub fn rankedHandReplay(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, frames: []const u8) !void {
    var frames_reader: MessagePackReader = .{ .data = frames };
    const frame_count = try frames_reader.arrayLen();
    if (frame_count > 256) return error.InvalidMultiplayerReplay;
    for (0..frame_count) |_| try frames_reader.skip(0);
    if (frames_reader.pos != frames_reader.data.len) return error.InvalidMultiplayerReplay;
    var recipients: [max_connections]*Connection = undefined;
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    if (room.ranked_play == null or room.userIndex(connection.user_id) == null) {
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    }
    const count = self.recipientsLocked(room_id, connection, &recipients);
    defer releaseRecipients(recipients[0..count]);
    self.mutex.unlock(self.io);
    const event = try eventRankedHandReplayOwned(self.allocator, connection.user_id, frames);
    defer self.allocator.free(event);
    sendRecipients(recipients[0..count], event);
    try self.finishVoid(connection, invocation_id);
}

pub fn toggleMatchmakingSelection(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, playlist_item_id: i64) !void {
    var random_bytes: [8]u8 = undefined;
    try self.io.randomSecure(&random_bytes);
    const random_value = std.mem.readInt(u64, &random_bytes, .little);
    var recipients: [max_connections]*Connection = undefined;
    var previous: ?i64 = null;
    var advanced = false;
    var finalised_event: ?[]u8 = null;
    var settings_event: ?[]u8 = null;
    var download_event: ?[]u8 = null;
    defer if (finalised_event) |event| self.allocator.free(event);
    defer if (settings_event) |event| self.allocator.free(event);
    defer if (download_event) |event| self.allocator.free(event);
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    if (room.matchmaking == null or room.matchmaking.?.stage != matchmaking_stage.user_beatmap_select) {
        self.mutex.unlock(self.io);
        return error.InvalidMatchmakingStage;
    }
    if (playlist_item_id != -1) {
        const item_index = room.itemIndex(playlist_item_id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerPlaylistItemNotFound;
        };
        if (room.playlist[item_index].?.expired) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPlaylistItemExpired;
        }
    }
    const match_user_index = room.matchmaking.?.userIndex(connection.user_id) orelse {
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    };
    previous = room.matchmaking.?.picks[match_user_index];
    if (previous == playlist_item_id) {
        self.mutex.unlock(self.io);
        return self.finishVoid(connection, invocation_id);
    }
    room.matchmaking.?.picks[match_user_index] = playlist_item_id;
    var all_picked = room.user_count != 0;
    for (room.users) |entry| if (entry) |user| {
        const index = room.matchmaking.?.userIndex(user.id) orelse continue;
        if (room.matchmaking.?.picks[index] == null) all_picked = false;
    };
    if (all_picked) {
        const previous_matchmaking = room.matchmaking.?;
        const previous_settings = room.settings;
        room.matchmaking.?.candidate_count = 0;
        for (room.matchmaking.?.picks) |pick_entry| if (pick_entry) |pick| {
            if (std.mem.indexOfScalar(i64, room.matchmaking.?.candidate_items[0..room.matchmaking.?.candidate_count], pick) == null) {
                room.matchmaking.?.candidate_items[room.matchmaking.?.candidate_count] = pick;
                room.matchmaking.?.candidate_count += 1;
            }
        };
        const candidate_index: usize = @intCast(random_value % room.matchmaking.?.candidate_count);
        room.matchmaking.?.candidate_item = room.matchmaking.?.candidate_items[candidate_index];
        room.matchmaking.?.gameplay_item = if (room.matchmaking.?.candidate_item == -1) random: {
            var active_items: [max_playlist]i64 = undefined;
            var active_count: usize = 0;
            for (room.playlist) |entry| if (entry) |item| if (!item.expired) {
                active_items[active_count] = item.id;
                active_count += 1;
            };
            if (active_count == 0) {
                room.matchmaking = previous_matchmaking;
                self.mutex.unlock(self.io);
                return error.MatchmakingPoolUnavailable;
            }
            const active_index: usize = @intCast((random_value / room.matchmaking.?.candidate_count) % active_count);
            break :random active_items[active_index];
        } else room.matchmaking.?.candidate_item;
        room.matchmaking.?.stage = matchmaking_stage.server_beatmap_finalised;
        finalised_event = eventMatchStateOwned(self.allocator, room) catch |err| {
            room.matchmaking = previous_matchmaking;
            self.mutex.unlock(self.io);
            return err;
        };
        room.settings.playlist_item_id = room.matchmaking.?.gameplay_item;
        settings_event = eventSettingsOwned(self.allocator, "SettingsChanged", room.settings) catch |err| {
            room.matchmaking = previous_matchmaking;
            room.settings = previous_settings;
            self.mutex.unlock(self.io);
            return err;
        };
        room.matchmaking.?.stage = matchmaking_stage.waiting_for_beatmap_download;
        download_event = eventMatchStateOwned(self.allocator, room) catch |err| {
            room.matchmaking = previous_matchmaking;
            room.settings = previous_settings;
            self.mutex.unlock(self.io);
            return err;
        };
        advanced = true;
    }
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    self.mutex.unlock(self.io);
    if (previous) |old| {
        const event = try eventIntegersOwned(self.allocator, "MatchmakingItemDeselected", &.{ connection.user_id, old });
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
    }
    const selected_event = try eventIntegersOwned(self.allocator, "MatchmakingItemSelected", &.{ connection.user_id, playlist_item_id });
    defer self.allocator.free(selected_event);
    sendRecipients(recipients[0..count], selected_event);
    if (advanced) {
        sendRecipients(recipients[0..count], finalised_event.?);
        sendRecipients(recipients[0..count], settings_event.?);
        sendRecipients(recipients[0..count], download_event.?);
    }
    try self.finishVoid(connection, invocation_id);
}

pub fn discardRankedCards(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
    var card_ids: [ranked_hand_size][]const u8 = undefined;
    const requested_count = try parseRankedCardList(encoded, &card_ids);
    var removed: [ranked_hand_size]?RankedCard = [_]?RankedCard{null} ** ranked_hand_size;
    var added: [ranked_hand_size]?RankedCard = [_]?RankedCard{null} ** ranked_hand_size;
    var added_items: [ranked_hand_size]?PlaylistItem = [_]?PlaylistItem{null} ** ranked_hand_size;
    var added_count: usize = 0;
    var snapshots: [3]Room = undefined;
    var snapshot_count: usize = 0;
    var recipients: [max_connections]*Connection = undefined;
    var countdown_started: ?RankedStageCountdown = null;
    var countdown_event: ?[]u8 = null;
    defer if (countdown_event) |event| self.allocator.free(event);
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    const room_before = room.*;
    if (room.ranked_play == null) {
        self.mutex.unlock(self.io);
        return error.InvalidRankedPlayStage;
    }
    const ranked = &room.ranked_play.?;
    if (ranked.stage != ranked_stage.card_discard) {
        self.mutex.unlock(self.io);
        return error.InvalidRankedPlayStage;
    }
    const user_index = ranked.userIndex(connection.user_id) orelse {
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    };
    const user = &ranked.users[user_index].?;
    if (user.discarded) {
        self.mutex.unlock(self.io);
        return error.RankedPlayCardsAlreadyDiscarded;
    }
    for (card_ids[0..requested_count]) |card_id| if (user.cardIndex(card_id) == null) {
        self.mutex.unlock(self.io);
        return error.InvalidRankedPlayCard;
    };
    for (card_ids[0..requested_count], 0..) |card_id, index| removed[index] = rankedRemoveCard(user, card_id).?;
    for (0..requested_count) |_| if (rankedDrawCard(ranked, user_index)) |card| {
        added[added_count] = card;
        const item_index = room.itemIndex(card.playlist_item_id).?;
        added_items[added_count] = room.playlist[item_index].?;
        added_count += 1;
    };
    user.discarded = true;
    snapshots[snapshot_count] = room.*;
    snapshot_count += 1;
    var all_discarded = true;
    for (ranked.users) |entry| if (entry) |candidate| {
        if (!candidate.discarded) all_discarded = false;
    };
    if (all_discarded) {
        ranked.stage = ranked_stage.finish_card_discard;
        snapshots[snapshot_count] = room.*;
        snapshot_count += 1;
        ranked.stage = ranked_stage.card_play;
        countdown_started = self.startRankedPickCountdownLocked(ranked, self.nowMs());
        snapshots[snapshot_count] = room.*;
        snapshot_count += 1;
    }
    const recipient_count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..recipient_count]);
    if (countdown_started) |countdown| countdown_event = eventRankedCountdownStartedOwned(self.allocator, countdown, self.nowMs()) catch |err| {
        room.* = room_before;
        self.mutex.unlock(self.io);
        return err;
    };
    self.mutex.unlock(self.io);
    for (removed[0..requested_count]) |entry| if (entry) |card| {
        const event = try eventRankedCardUserOwned(self.allocator, "RankedPlayCardRemoved", connection.user_id, card);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..recipient_count], event);
    };
    for (added[0..added_count], 0..) |entry, index| if (entry) |card| {
        const added_event = try eventRankedCardUserOwned(self.allocator, "RankedPlayCardAdded", connection.user_id, card);
        defer self.allocator.free(added_event);
        sendRecipients(recipients[0..recipient_count], added_event);
        const reveal_event = try eventRankedCardRevealedOwned(self.allocator, card, added_items[index].?);
        defer self.allocator.free(reveal_event);
        connection.send(reveal_event);
    };
    for (snapshots[0..snapshot_count]) |*snapshot| {
        const state_event = try eventMatchStateOwned(self.allocator, snapshot);
        defer self.allocator.free(state_event);
        sendRecipients(recipients[0..recipient_count], state_event);
    }
    if (countdown_event) |event| sendRecipients(recipients[0..recipient_count], event);
    try self.finishVoid(connection, invocation_id);
}

pub fn playRankedCard(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
    const card_id = try parseRankedCardId(encoded);
    var recipients: [max_connections]*Connection = undefined;
    var card: RankedCard = undefined;
    var item: PlaylistItem = undefined;
    var settings: Settings = undefined;
    var state_event: ?[]u8 = null;
    defer if (state_event) |event| self.allocator.free(event);
    var countdown_stopped_event: ?[]u8 = null;
    defer if (countdown_stopped_event) |event| self.allocator.free(event);
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    const room_before = room.*;
    if (room.ranked_play == null) {
        self.mutex.unlock(self.io);
        return error.InvalidRankedPlayStage;
    }
    const ranked = &room.ranked_play.?;
    if (ranked.stage != ranked_stage.card_play or ranked.active_user_id != connection.user_id or ranked.played_card != null) {
        self.mutex.unlock(self.io);
        return error.InvalidRankedPlayStage;
    }
    const user_index = ranked.userIndex(connection.user_id).?;
    const hand_index = ranked.users[user_index].?.cardIndex(card_id) orelse {
        self.mutex.unlock(self.io);
        return error.InvalidRankedPlayCard;
    };
    card = ranked.users[user_index].?.hand[hand_index].?;
    const item_index = room.itemIndex(card.playlist_item_id) orelse {
        self.mutex.unlock(self.io);
        return error.MultiplayerPlaylistItemNotFound;
    };
    item = room.playlist[item_index].?;
    ranked.played_card = card;
    ranked.gameplay_item = card.playlist_item_id;
    room.settings.playlist_item_id = card.playlist_item_id;
    resetRoomBeatmapAvailability(room);
    ranked.stage = ranked_stage.finish_card_play;
    const countdown_id = if (ranked.pick_countdown) |countdown| countdown.id else null;
    ranked.pick_countdown = null;
    settings = room.settings;
    const recipient_count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..recipient_count]);
    if (countdown_id) |id| countdown_stopped_event = eventRankedCountdownStoppedOwned(self.allocator, id) catch |err| {
        room.* = room_before;
        self.mutex.unlock(self.io);
        return err;
    };
    state_event = eventMatchStateOwned(self.allocator, room) catch |err| {
        room.* = room_before;
        self.mutex.unlock(self.io);
        return err;
    };
    self.mutex.unlock(self.io);
    if (countdown_stopped_event) |event| sendRecipients(recipients[0..recipient_count], event);
    const reveal_event = try eventRankedCardRevealedOwned(self.allocator, card, item);
    defer self.allocator.free(reveal_event);
    sendRecipients(recipients[0..recipient_count], reveal_event);
    const played_event = try eventRankedCardPlayedOwned(self.allocator, card);
    defer self.allocator.free(played_event);
    sendRecipients(recipients[0..recipient_count], played_event);
    const settings_event = try eventSettingsOwned(self.allocator, "SettingsChanged", settings);
    defer self.allocator.free(settings_event);
    sendRecipients(recipients[0..recipient_count], settings_event);
    sendRecipients(recipients[0..recipient_count], state_event.?);
    try self.finishVoid(connection, invocation_id);
}
