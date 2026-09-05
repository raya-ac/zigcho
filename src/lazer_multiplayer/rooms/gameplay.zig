const std = @import("std");
const max_connections = @import("../../lazer_multiplayer.zig").max_connections;
const max_users = @import("../../lazer_multiplayer.zig").max_users;
const matchmaking_rounds = @import("../../lazer_multiplayer.zig").matchmaking_rounds;
const matchmaking_stage = @import("../../lazer_multiplayer.zig").matchmaking_stage;
const ranked_stage = @import("../../lazer_multiplayer.zig").ranked_stage;
const eventNoArgsOwned = @import("../../lazer_multiplayer.zig").eventNoArgsOwned;
const eventIntegersOwned = @import("../../lazer_multiplayer.zig").eventIntegersOwned;
const PlaylistItem = @import("../../lazer_multiplayer.zig").PlaylistItem;
const RankedCard = @import("../../lazer_multiplayer.zig").RankedCard;
const Room = @import("model.zig").Room;
const Connection = @import("../transport/model.zig").Connection;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const advanceRoomPlaylist = @import("state.zig").advanceRoomPlaylist;
const rankedDrawCard = @import("../ranked/state.zig").rankedDrawCard;
const rankedRemoveCard = @import("../ranked/state.zig").rankedRemoveCard;
const rankedFinishRound = @import("../ranked/state.zig").rankedFinishRound;
const rankedHasRoundsRemaining = @import("../ranked/state.zig").rankedHasRoundsRemaining;
const rankedWinner = @import("../ranked/state.zig").rankedWinner;
const eventMatchStateOwned = @import("../transport/events.zig").eventMatchStateOwned;
const eventRankedCountdownStartedOwned = @import("../transport/events.zig").eventRankedCountdownStartedOwned;
const eventRankedCountdownStoppedOwned = @import("../transport/events.zig").eventRankedCountdownStoppedOwned;
const eventSettingsOwned = @import("../transport/events.zig").eventSettingsOwned;
const eventPlaylistOwned = @import("../transport/events.zig").eventPlaylistOwned;
const eventRankedCardUserOwned = @import("../transport/events.zig").eventRankedCardUserOwned;
const eventRankedCardRevealedOwned = @import("../transport/events.zig").eventRankedCardRevealedOwned;
const sendRecipients = @import("../transport/connections.zig").sendRecipients;
const releaseRecipients = @import("../transport/connections.zig").releaseRecipients;

pub fn changeState(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, new_state: u8) !void {
    if (new_state > 8 or new_state == 2 or new_state == 5 or new_state == 7) return error.InvalidMultiplayerState;
    var recipients: [max_connections]*Connection = undefined;
    var start_players: [max_connections]*Connection = undefined;
    var start_count: usize = 0;
    var load_players: [max_connections]*Connection = undefined;
    var load_count: usize = 0;
    var server_user_updates: [max_users]struct { id: i32, state: u8 } = undefined;
    var server_user_update_count: usize = 0;
    var match_snapshots: [3]Room = undefined;
    var match_snapshot_count: usize = 0;
    var match_events: [3]?[]u8 = [_]?[]u8{null} ** 3;
    defer for (match_events) |event| if (event) |frame| self.allocator.free(frame);
    var playlist_event: ?[]u8 = null;
    defer if (playlist_event) |event| self.allocator.free(event);
    var playlist_settings_event: ?[]u8 = null;
    defer if (playlist_settings_event) |event| self.allocator.free(event);
    var results_ready = false;
    var ranked_removed_card: ?RankedCard = null;
    var ranked_removed_user: ?i32 = null;
    var ranked_added_card: ?RankedCard = null;
    var ranked_added_item: ?PlaylistItem = null;
    var ranked_added_user: ?i32 = null;
    var ranked_countdown_event: ?[]u8 = null;
    defer if (ranked_countdown_event) |event| self.allocator.free(event);
    var changed_room_state: ?i32 = null;
    var emitted_user_state: u8 = new_state;
    var ranked_result_room_id: ?i64 = null;
    var ranked_result_event_index: ?usize = null;
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    const room_before = room.*;
    const user_index = room.userIndex(connection.user_id).?;
    const previous_user_state = room.users[user_index].?.state;
    room.users[user_index].?.state = if (room.state == 2 and previous_user_state == 5 and (new_state == 3 or new_state == 4)) 5 else new_state;
    if (new_state == 6) room.users[user_index].?.state = 7;
    emitted_user_state = room.users[user_index].?.state;
    const quick_waiting = room.matchmaking != null and room.matchmaking.?.stage == matchmaking_stage.waiting_for_beatmap_download;
    const ranked_waiting = room.ranked_play != null and room.ranked_play.?.stage == ranked_stage.gameplay_warmup;
    if ((quick_waiting or ranked_waiting) and new_state == 1) {
        var all_ready = room.user_count != 0;
        for (room.users) |entry| if (entry) |user| if (user.state != 1) {
            all_ready = false;
        };
        if (all_ready) {
            if (quick_waiting) {
                room.matchmaking.?.stage = matchmaking_stage.gameplay_warmup;
                match_snapshots[match_snapshot_count] = room.*;
                match_snapshot_count += 1;
                room.matchmaking.?.stage = matchmaking_stage.gameplay;
            } else room.ranked_play.?.stage = ranked_stage.gameplay;
            match_snapshots[match_snapshot_count] = room.*;
            match_snapshot_count += 1;
            room.state = 1;
            changed_room_state = 1;
            for (&room.users) |*entry| if (entry.*) |*user| {
                if (user.state != 1) continue;
                user.state = 2;
                server_user_updates[server_user_update_count] = .{ .id = user.id, .state = 2 };
                server_user_update_count += 1;
            };
            for (self.connections.items) |candidate| if (candidate.room_id == room_id) {
                const candidate_index = room.userIndex(candidate.user_id) orelse continue;
                if (room.users[candidate_index].?.state == 2 and load_count < load_players.len) {
                    candidate.retain();
                    load_players[load_count] = candidate;
                    load_count += 1;
                }
            };
        }
    } else if (room.state == 1 and (new_state == 3 or new_state == 4)) {
        var waiting = false;
        var gameplay_users: usize = 0;
        for (room.users) |entry| if (entry) |user| {
            if (user.state == 2) waiting = true;
            if (user.state >= 2 and user.state <= 4) gameplay_users += 1;
        };
        if (!waiting and gameplay_users != 0) {
            room.state = 2;
            for (&room.users) |*entry| {
                if (entry.*) |*user| {
                    if (user.state == 3 or user.state == 4) {
                        user.state = 5;
                        server_user_updates[server_user_update_count] = .{ .id = user.id, .state = 5 };
                        server_user_update_count += 1;
                    }
                }
            }
            changed_room_state = 2;
            for (self.connections.items) |candidate| if (candidate.room_id == room_id) {
                const candidate_index = room.userIndex(candidate.user_id) orelse continue;
                if (room.users[candidate_index].?.state == 5 and start_count < start_players.len) {
                    candidate.retain();
                    start_players[start_count] = candidate;
                    start_count += 1;
                }
            };
        }
    } else if (new_state == 6) {
        var playing = false;
        for (room.users) |entry| {
            if (entry) |user| {
                if (user.state == 5 or user.state == 6) playing = true;
            }
        }
        if (!playing) {
            room.state = 0;
            results_ready = true;
            changed_room_state = 0;
            if (room.matchmaking) |*matchmaking| {
                if (matchmaking.gameplay_item != 0) if (room.itemIndex(matchmaking.gameplay_item)) |item_index| {
                    room.playlist[item_index].?.expired = true;
                    playlist_event = eventPlaylistOwned(self.allocator, "PlaylistItemChanged", room.playlist[item_index].?) catch |err| {
                        room.* = room_before;
                        self.mutex.unlock(self.io);
                        return err;
                    };
                };
                matchmaking.stage = matchmaking_stage.results;
                match_snapshots[match_snapshot_count] = room.*;
                match_snapshot_count += 1;
            } else if (room.ranked_play) |*ranked| {
                if (ranked.active_user_id) |active_user_id| if (ranked.played_card) |played_card| {
                    if (ranked.userIndex(active_user_id)) |active_index| {
                        ranked_removed_card = rankedRemoveCard(&ranked.users[active_index].?, played_card.id.slice());
                        ranked_removed_user = active_user_id;
                    }
                };
                rankedFinishRound(ranked);
                ranked.stage = ranked_stage.results;
                match_snapshots[match_snapshot_count] = room.*;
                match_snapshot_count += 1;
            } else {
                const advanced = advanceRoomPlaylist(room);
                if (advanced.expired) |item| {
                    playlist_event = eventPlaylistOwned(self.allocator, "PlaylistItemChanged", item) catch |err| {
                        room.* = room_before;
                        self.mutex.unlock(self.io);
                        return err;
                    };
                }
                if (advanced.next_item_id != null) {
                    playlist_settings_event = eventSettingsOwned(self.allocator, "SettingsChanged", room.settings) catch |err| {
                        room.* = room_before;
                        self.mutex.unlock(self.io);
                        return err;
                    };
                }
            }
        }
    } else if (new_state == 0 and room.matchmaking != null and room.matchmaking.?.stage == matchmaking_stage.results) {
        var all_idle = room.user_count != 0;
        for (room.users) |entry| if (entry) |user| if (user.state != 0) {
            all_idle = false;
        };
        if (all_idle) {
            if (room.matchmaking.?.current_round >= matchmaking_rounds) {
                room.matchmaking.?.stage = matchmaking_stage.ended;
                match_snapshots[match_snapshot_count] = room.*;
                match_snapshot_count += 1;
            } else {
                room.matchmaking.?.current_round += 1;
                room.matchmaking.?.candidate_items = [_]i64{0} ** max_users;
                room.matchmaking.?.candidate_count = 0;
                room.matchmaking.?.candidate_item = 0;
                room.matchmaking.?.gameplay_item = 0;
                room.matchmaking.?.picks = [_]?i64{null} ** max_users;
                room.matchmaking.?.stage = matchmaking_stage.round_warmup;
                match_snapshots[match_snapshot_count] = room.*;
                match_snapshot_count += 1;
                room.matchmaking.?.stage = matchmaking_stage.user_beatmap_select;
                match_snapshots[match_snapshot_count] = room.*;
                match_snapshot_count += 1;
            }
        }
    } else if (new_state == 0 and room.ranked_play != null and room.ranked_play.?.stage == ranked_stage.results) {
        var all_idle = room.user_count != 0;
        for (room.users) |entry| if (entry) |user| {
            if (user.state != 0) all_idle = false;
        };
        if (all_idle) {
            const ranked = &room.ranked_play.?;
            if (ranked.round_winner_id) |winner_id| if (ranked.userIndex(winner_id)) |winner_index| {
                ranked.users[winner_index].?.damage_multiplier += 0.5;
            };
            for (&ranked.users) |*entry| if (entry.*) |*user| {
                user.damage = null;
                user.total_score = 0;
                user.submitted = false;
                user.discarded = true;
            };
            ranked.played_card = null;
            ranked.gameplay_item = 0;
            if (!rankedHasRoundsRemaining(ranked)) {
                ranked.winning_user_id = rankedWinner(ranked);
                ranked.stage = ranked_stage.ended;
                ranked_result_room_id = room.id;
                ranked_result_event_index = match_snapshot_count;
                match_snapshots[match_snapshot_count] = room.*;
                match_snapshot_count += 1;
            } else {
                ranked.current_round += 1;
                ranked.damage_multiplier += 0.5;
                if (ranked.active_user_id) |active_user_id| {
                    for (ranked.users) |entry| if (entry) |user| if (user.id != active_user_id and user.life > 0) {
                        ranked.active_user_id = user.id;
                        break;
                    };
                }
                if (ranked.active_user_id) |active_user_id| if (ranked.userIndex(active_user_id)) |active_index| {
                    ranked_added_card = rankedDrawCard(ranked, active_index);
                    if (ranked_added_card) |card| {
                        ranked_added_user = active_user_id;
                        if (room.itemIndex(card.playlist_item_id)) |item_index| ranked_added_item = room.playlist[item_index].?;
                    }
                };
                ranked.stage = ranked_stage.round_warmup;
                match_snapshots[match_snapshot_count] = room.*;
                match_snapshot_count += 1;
                ranked.stage = ranked_stage.card_play;
                _ = self.startRankedPickCountdownLocked(ranked, self.nowMs());
                match_snapshots[match_snapshot_count] = room.*;
                match_snapshot_count += 1;
            }
        }
    }
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    defer releaseRecipients(start_players[0..start_count]);
    defer releaseRecipients(load_players[0..load_count]);
    for (match_snapshots[0..match_snapshot_count], 0..) |*snapshot, index| {
        match_events[index] = eventMatchStateOwned(self.allocator, snapshot) catch |err| {
            room.* = room_before;
            self.mutex.unlock(self.io);
            return err;
        };
    }
    if (room.ranked_play) |ranked| if (ranked.pick_countdown) |countdown| {
        if (room_before.ranked_play == null or room_before.ranked_play.?.pick_countdown == null or room_before.ranked_play.?.pick_countdown.?.id != countdown.id) {
            ranked_countdown_event = eventRankedCountdownStartedOwned(self.allocator, countdown, self.nowMs()) catch |err| {
                room.* = room_before;
                self.mutex.unlock(self.io);
                return err;
            };
        }
    };
    self.mutex.unlock(self.io);
    if (ranked_result_room_id) |id| {
        self.persistLiveRankedResult(id) catch |err| std.log.err("event=lazer_ranked_rating_persist_failed room_id={d} error={t}", .{ id, err });
        if (self.rankedStateEventForRoom(id) catch null) |updated| if (ranked_result_event_index) |index| {
            if (match_events[index]) |old| self.allocator.free(old);
            match_events[index] = updated;
        };
    }
    const user_state_event = try eventIntegersOwned(self.allocator, "UserStateChanged", &.{ connection.user_id, emitted_user_state });
    defer self.allocator.free(user_state_event);
    sendRecipients(recipients[0..count], user_state_event);
    for (match_events[0..match_snapshot_count]) |state_event| sendRecipients(recipients[0..count], state_event.?);
    if (ranked_countdown_event) |event| sendRecipients(recipients[0..count], event);
    for (server_user_updates[0..server_user_update_count]) |update| {
        const event = try eventIntegersOwned(self.allocator, "UserStateChanged", &.{ update.id, update.state });
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
    }
    if (changed_room_state) |state| {
        const event = try eventIntegersOwned(self.allocator, "RoomStateChanged", &.{state});
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
    }
    if (load_count != 0) {
        const event = try eventNoArgsOwned(self.allocator, "LoadRequested");
        defer self.allocator.free(event);
        sendRecipients(load_players[0..load_count], event);
    }
    if (start_count != 0) {
        const event = try eventNoArgsOwned(self.allocator, "GameplayStarted");
        defer self.allocator.free(event);
        sendRecipients(start_players[0..start_count], event);
    }
    if (playlist_event) |event| sendRecipients(recipients[0..count], event);
    if (playlist_settings_event) |event| sendRecipients(recipients[0..count], event);
    if (ranked_removed_card) |card| if (ranked_removed_user) |user_id| {
        const event = try eventRankedCardUserOwned(self.allocator, "RankedPlayCardRemoved", user_id, card);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
    };
    if (ranked_added_card) |card| if (ranked_added_user) |user_id| {
        const event = try eventRankedCardUserOwned(self.allocator, "RankedPlayCardAdded", user_id, card);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        if (ranked_added_item) |item| for (recipients[0..count]) |recipient| if (recipient.user_id == user_id) {
            const reveal = try eventRankedCardRevealedOwned(self.allocator, card, item);
            defer self.allocator.free(reveal);
            recipient.send(reveal);
            break;
        };
    };
    if (results_ready) {
        const event = try eventNoArgsOwned(self.allocator, "ResultsReady");
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
    }
    try self.finishVoid(connection, invocation_id);
}

pub fn startMatch(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
    var recipients: [max_connections]*Connection = undefined;
    var loaders: [max_connections]*Connection = undefined;
    var loader_count: usize = 0;
    var countdown_id: ?i32 = null;
    var state_events: [max_users]?[]u8 = [_]?[]u8{null} ** max_users;
    defer for (&state_events) |*entry| if (entry.*) |event| self.allocator.free(event);
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    if (room.host_id != connection.user_id or room.state != 0) {
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    }
    var ready_count: usize = 0;
    for (&room.users, 0..) |*entry, index| if (entry.*) |*user| {
        if (user.state == 1) {
            user.state = 2;
            state_events[index] = eventIntegersOwned(self.allocator, "UserStateChanged", &.{ user.id, 2 }) catch |err| {
                self.mutex.unlock(self.io);
                return err;
            };
            ready_count += 1;
        }
    };
    if (ready_count == 0) {
        self.mutex.unlock(self.io);
        return error.NoReadyMultiplayerPlayers;
    }
    countdown_id = if (room.match_start_countdown) |countdown| countdown.id else null;
    room.match_start_countdown = null;
    room.state = 1;
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    for (self.connections.items) |candidate| if (candidate.room_id == room_id) {
        const index = room.userIndex(candidate.user_id) orelse continue;
        if (room.users[index].?.state == 2 and loader_count < loaders.len) {
            candidate.retain();
            loaders[loader_count] = candidate;
            loader_count += 1;
        }
    };
    self.mutex.unlock(self.io);
    defer releaseRecipients(loaders[0..loader_count]);
    const room_event = try eventIntegersOwned(self.allocator, "RoomStateChanged", &.{1});
    defer self.allocator.free(room_event);
    sendRecipients(recipients[0..count], room_event);
    if (countdown_id) |id| {
        const countdown_event = try eventRankedCountdownStoppedOwned(self.allocator, id);
        defer self.allocator.free(countdown_event);
        sendRecipients(recipients[0..count], countdown_event);
    }
    for (state_events) |entry| if (entry) |event| sendRecipients(recipients[0..count], event);
    const load = try eventNoArgsOwned(self.allocator, "LoadRequested");
    defer self.allocator.free(load);
    sendRecipients(loaders[0..loader_count], load);
    try self.finishVoid(connection, invocation_id);
}

pub fn abortMatch(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
    var recipients: [max_connections]*Connection = undefined;
    var changed_users: [max_users]i32 = undefined;
    var changed_user_count: usize = 0;
    var countdown_id: ?i32 = null;
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    const requester_index = room.userIndex(connection.user_id).?;
    if (room.host_id != connection.user_id and room.users[requester_index].?.role != 1) {
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    }
    countdown_id = if (room.match_start_countdown) |countdown| countdown.id else null;
    room.match_start_countdown = null;
    room.state = 0;
    for (&room.users) |*entry| {
        if (entry.*) |*user| {
            if (user.state >= 2 and user.state <= 7) {
                user.state = 0;
                changed_users[changed_user_count] = user.id;
                changed_user_count += 1;
            }
        }
    }
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    self.mutex.unlock(self.io);
    const room_event = try eventIntegersOwned(self.allocator, "RoomStateChanged", &.{0});
    defer self.allocator.free(room_event);
    sendRecipients(recipients[0..count], room_event);
    if (countdown_id) |id| {
        const countdown_event = try eventRankedCountdownStoppedOwned(self.allocator, id);
        defer self.allocator.free(countdown_event);
        sendRecipients(recipients[0..count], countdown_event);
    }
    for (changed_users[0..changed_user_count]) |user_id| {
        const state_event = try eventIntegersOwned(self.allocator, "UserStateChanged", &.{ user_id, 0 });
        defer self.allocator.free(state_event);
        sendRecipients(recipients[0..count], state_event);
    }
    const abort_event = try eventIntegersOwned(self.allocator, "GameplayAborted", &.{1});
    defer self.allocator.free(abort_event);
    sendRecipients(recipients[0..count], abort_event);
    try self.finishVoid(connection, invocation_id);
}

pub fn abortGameplay(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
    try self.changeState(connection, null, 0);
    const event = try eventIntegersOwned(self.allocator, "GameplayAborted", &.{0});
    defer self.allocator.free(event);
    connection.send(event);
    try self.finishVoid(connection, invocation_id);
}
