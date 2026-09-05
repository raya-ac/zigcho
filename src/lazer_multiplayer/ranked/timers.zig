const std = @import("std");
const max_connections = @import("../../lazer_multiplayer.zig").max_connections;
const ranked_stage = @import("../../lazer_multiplayer.zig").ranked_stage;
const Connection = @import("../transport/model.zig").Connection;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const resetRoomBeatmapAvailability = @import("../rooms/state.zig").resetRoomBeatmapAvailability;
const rankedWinner = @import("state.zig").rankedWinner;
const eventMatchStateOwned = @import("../transport/events.zig").eventMatchStateOwned;
const eventRankedCountdownStoppedOwned = @import("../transport/events.zig").eventRankedCountdownStoppedOwned;
const eventSettingsOwned = @import("../transport/events.zig").eventSettingsOwned;
const eventRankedCardRevealedOwned = @import("../transport/events.zig").eventRankedCardRevealedOwned;
const eventRankedCardPlayedOwned = @import("../transport/events.zig").eventRankedCardPlayedOwned;
const sendRecipients = @import("../transport/connections.zig").sendRecipients;
const releaseRecipients = @import("../transport/connections.zig").releaseRecipients;

pub fn advanceExpiredMatchCountdowns(self: *Manager, now_ms: i64) !usize {
    var mutation = self.beginMutation() catch return 0;
    defer mutation.deinit();
    var advanced: usize = 0;
    while (true) {
        var recipients: [max_connections]*Connection = undefined;
        var host: ?*Connection = null;
        var countdown_id: i32 = 0;
        var room_id: i64 = 0;
        self.mutex.lockUncancelable(self.io);
        if (!self.mutationAllowedLocked()) {
            self.mutex.unlock(self.io);
            return advanced;
        }
        const room = expired: {
            for (self.rooms) |entry| if (entry) |candidate| {
                const countdown = candidate.match_start_countdown orelse continue;
                if (candidate.state == 0 and countdown.deadline_ms <= now_ms) break :expired candidate;
            };
            self.mutex.unlock(self.io);
            return advanced;
        };
        countdown_id = room.match_start_countdown.?.id;
        room_id = room.id;
        room.match_start_countdown = null;
        if (self.connectionByUserLocked(room.host_id)) |connection| if (connection.room_id == room.id) {
            connection.retain();
            host = connection;
        };
        const recipient_count = self.recipientsLocked(room.id, null, &recipients);
        defer releaseRecipients(recipients[0..recipient_count]);
        self.mutex.unlock(self.io);
        const stopped = try eventRankedCountdownStoppedOwned(self.allocator, countdown_id);
        defer self.allocator.free(stopped);
        sendRecipients(recipients[0..recipient_count], stopped);
        if (host) |connection| {
            defer connection.release();
            self.startMatch(connection, null) catch |err| if (err != error.NoReadyMultiplayerPlayers)
                std.log.warn("event=lazer_multiplayer_countdown_start_failed room_id={d} error={t}", .{ room_id, err });
        }
        advanced += 1;
    }
}

pub fn advanceExpiredRankedPicks(self: *Manager, now_ms: i64) !usize {
    var mutation = self.beginMutation() catch return 0;
    defer mutation.deinit();
    var advanced: usize = 0;
    while (true) {
        var recipients: [max_connections]*Connection = undefined;
        var recipient_count: usize = 0;
        var frames: [5]?[]u8 = [_]?[]u8{null} ** 5;
        defer for (frames) |frame| if (frame) |owned| self.allocator.free(owned);
        var room_id: i64 = 0;
        var active_user_id: i32 = 0;

        self.mutex.lockUncancelable(self.io);
        if (!self.mutationAllowedLocked()) {
            self.mutex.unlock(self.io);
            return advanced;
        }
        const room = expired: {
            for (self.rooms) |entry| if (entry) |candidate| {
                if (candidate.ranked_play) |ranked| {
                    const countdown = ranked.pick_countdown orelse continue;
                    if (ranked.stage == ranked_stage.card_play and ranked.played_card == null and countdown.deadline_ms <= now_ms) break :expired candidate;
                }
            };
            self.mutex.unlock(self.io);
            return advanced;
        };
        const room_before = room.*;
        const ranked = &room.ranked_play.?;
        const countdown = ranked.pick_countdown.?;
        var user_index = if (ranked.active_user_id) |id| ranked.userIndex(id) else null;
        if (user_index == null or ranked.users[user_index.?].?.hand_count == 0) {
            user_index = null;
            for (ranked.users, 0..) |entry, index| if (entry) |user| if (user.life > 0 and user.hand_count != 0) {
                user_index = index;
                ranked.active_user_id = user.id;
                break;
            };
        }
        const selected_user_index = user_index orelse {
            ranked.pick_countdown = null;
            ranked.winning_user_id = rankedWinner(ranked);
            ranked.stage = ranked_stage.ended;
            room_id = room.id;
            recipient_count = self.recipientsLocked(room.id, null, &recipients);
            frames[0] = eventRankedCountdownStoppedOwned(self.allocator, countdown.id) catch |err| {
                room.* = room_before;
                self.mutex.unlock(self.io);
                releaseRecipients(recipients[0..recipient_count]);
                return err;
            };
            frames[1] = eventMatchStateOwned(self.allocator, room) catch |err| {
                room.* = room_before;
                self.mutex.unlock(self.io);
                releaseRecipients(recipients[0..recipient_count]);
                return err;
            };
            self.mutex.unlock(self.io);
            defer releaseRecipients(recipients[0..recipient_count]);
            self.persistLiveRankedResult(room_id) catch |err| std.log.err("event=lazer_ranked_rating_persist_failed room_id={d} error={t}", .{ room_id, err });
            if (self.rankedStateEventForRoom(room_id) catch null) |updated| {
                if (frames[1]) |old| self.allocator.free(old);
                frames[1] = updated;
            }
            sendRecipients(recipients[0..recipient_count], frames[0].?);
            sendRecipients(recipients[0..recipient_count], frames[1].?);
            std.log.warn("event=lazer_ranked_pick_ended room_id={d} error=no_playable_card", .{room_id});
            advanced += 1;
            continue;
        };
        const card = for (ranked.users[selected_user_index].?.hand) |entry| {
            if (entry) |value| break value;
        } else unreachable;
        const item_index = room.itemIndex(card.playlist_item_id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerPlaylistItemNotFound;
        };
        const item = room.playlist[item_index].?;
        active_user_id = ranked.users[selected_user_index].?.id;
        room_id = room.id;
        ranked.played_card = card;
        ranked.gameplay_item = card.playlist_item_id;
        ranked.pick_countdown = null;
        ranked.stage = ranked_stage.finish_card_play;
        room.settings.playlist_item_id = card.playlist_item_id;
        resetRoomBeatmapAvailability(room);
        const settings = room.settings;
        recipient_count = self.recipientsLocked(room.id, null, &recipients);

        frames[0] = eventRankedCountdownStoppedOwned(self.allocator, countdown.id) catch |err| {
            room.* = room_before;
            self.mutex.unlock(self.io);
            releaseRecipients(recipients[0..recipient_count]);
            return err;
        };
        frames[1] = eventRankedCardRevealedOwned(self.allocator, card, item) catch |err| {
            room.* = room_before;
            self.mutex.unlock(self.io);
            releaseRecipients(recipients[0..recipient_count]);
            return err;
        };
        frames[2] = eventRankedCardPlayedOwned(self.allocator, card) catch |err| {
            room.* = room_before;
            self.mutex.unlock(self.io);
            releaseRecipients(recipients[0..recipient_count]);
            return err;
        };
        frames[3] = eventSettingsOwned(self.allocator, "SettingsChanged", settings) catch |err| {
            room.* = room_before;
            self.mutex.unlock(self.io);
            releaseRecipients(recipients[0..recipient_count]);
            return err;
        };
        frames[4] = eventMatchStateOwned(self.allocator, room) catch |err| {
            room.* = room_before;
            self.mutex.unlock(self.io);
            releaseRecipients(recipients[0..recipient_count]);
            return err;
        };
        self.mutex.unlock(self.io);
        defer releaseRecipients(recipients[0..recipient_count]);
        for (frames) |frame| sendRecipients(recipients[0..recipient_count], frame.?);
        std.log.info("event=lazer_ranked_pick_timed_out room_id={d} user_id={d} card_id={s}", .{ room_id, active_user_id, card.id.slice() });
        advanced += 1;
    }
}
