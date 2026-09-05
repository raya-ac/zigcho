const std = @import("std");
const lazer = @import("../../lazer.zig");
const max_rooms = @import("../../lazer_multiplayer.zig").max_rooms;
const max_connections = @import("../../lazer_multiplayer.zig").max_connections;
const max_users = @import("../../lazer_multiplayer.zig").max_users;
const ranked_hand_size = @import("../../lazer_multiplayer.zig").ranked_hand_size;
const matchmaking_stage = @import("../../lazer_multiplayer.zig").matchmaking_stage;
const ranked_stage = @import("../../lazer_multiplayer.zig").ranked_stage;
const eventIntegersOwned = @import("../../lazer_multiplayer.zig").eventIntegersOwned;
const PlaylistItem = @import("../../lazer_multiplayer.zig").PlaylistItem;
const RoomUser = @import("../../lazer_multiplayer.zig").RoomUser;
const RankedUser = @import("../../lazer_multiplayer.zig").RankedUser;
const Room = @import("model.zig").Room;
const Connection = @import("../transport/model.zig").Connection;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const defaultRoomUser = @import("state.zig").defaultRoomUser;
const nextTeamId = @import("state.zig").nextTeamId;
const parseRoom = @import("../wire/parse.zig").parseRoom;
const roomHasEnded = @import("../wire/json.zig").roomHasEnded;
const completionRoomOwned = @import("../transport/events.zig").completionRoomOwned;
const eventMatchStateOwned = @import("../transport/events.zig").eventMatchStateOwned;
const eventUserOwned = @import("../transport/events.zig").eventUserOwned;
const eventRankedCardRevealedOwned = @import("../transport/events.zig").eventRankedCardRevealedOwned;
const eventInviteOwned = @import("../transport/events.zig").eventInviteOwned;
const sendRecipients = @import("../transport/connections.zig").sendRecipients;
const releaseRecipients = @import("../transport/connections.zig").releaseRecipients;

pub fn roomSlotLocked(self: *Manager) ?usize {
    var owned: usize = 0;
    for (self.rooms) |entry| owned += @intFromBool(entry != null);
    for (self.pending_archives) |entry| owned += @intFromBool(entry != null);
    if (owned >= max_rooms) return null;
    for (self.rooms, 0..) |entry, index| if (entry == null) return index;
    return null;
}

pub fn createRoom(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded_room: []const u8) !void {
    const id = invocation_id orelse return error.MissingInvocationId;
    if (connection.room_id != null) return error.AlreadyInMultiplayerRoom;
    const room = try parseRoom(self.allocator, encoded_room, connection);
    errdefer self.allocator.destroy(room);
    try self.hydrateRoom(room);
    var response: []u8 = undefined;
    self.mutex.lockUncancelable(self.io);
    if (self.shutting_down) {
        self.mutex.unlock(self.io);
        return error.ServerShuttingDown;
    }
    if (!self.isEnabled()) {
        self.mutex.unlock(self.io);
        return error.MultiplayerDisabled;
    }
    if (!connection.alive.load(.acquire) or !connection.accepting_invocations.load(.acquire)) {
        self.mutex.unlock(self.io);
        return error.ConnectionClose;
    }
    const slot = self.roomSlotLocked() orelse {
        self.mutex.unlock(self.io);
        return error.MultiplayerRoomLimit;
    };
    room.id = self.next_room_id;
    self.next_room_id += 1;
    room.channel_id = @intCast(lazer.roomChannelId(room.id) orelse {
        self.mutex.unlock(self.io);
        return error.MultiplayerRoomLimit;
    });
    connection.room_id = room.id;
    self.rooms[slot] = room;
    response = completionRoomOwned(self.allocator, id, room, self.nowMs()) catch |err| {
        self.rooms[slot] = null;
        connection.room_id = null;
        self.mutex.unlock(self.io);
        return err;
    };
    self.mutex.unlock(self.io);
    defer self.allocator.free(response);
    connection.send(response);
    std.log.info("event=lazer_multiplayer_room_created room_id={d} host_id={d}", .{ room.id, connection.user_id });
}

pub fn joinRoom(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, room_id: i64, password: []const u8) !void {
    const id = invocation_id orelse return error.MissingInvocationId;
    var recipients: [max_connections]*Connection = undefined;
    var joined: RoomUser = undefined;
    var response: []u8 = undefined;
    var match_state_events: [2]?[]u8 = [_]?[]u8{null} ** 2;
    var match_state_event_count: usize = 0;
    var advanced_match = false;
    var advanced_ranked = false;
    var joined_ranked_user: ?RankedUser = null;
    var joined_ranked_playlist: [ranked_hand_size]?PlaylistItem = [_]?PlaylistItem{null} ** ranked_hand_size;
    defer for (match_state_events) |event| if (event) |frame| self.allocator.free(frame);
    self.mutex.lockUncancelable(self.io);
    if (connection.room_id) |current_room_id| {
        if (current_room_id != room_id) {
            self.mutex.unlock(self.io);
            return error.AlreadyInMultiplayerRoom;
        }
        const current_room = self.roomByIdLocked(room_id) orelse {
            connection.room_id = null;
            self.mutex.unlock(self.io);
            return error.MultiplayerRoomNotFound;
        };
        if (current_room.userIndex(connection.user_id) == null) {
            connection.room_id = null;
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        }
        response = completionRoomOwned(self.allocator, id, current_room, self.nowMs()) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        defer self.allocator.free(response);
        connection.send(response);
        std.log.info("event=lazer_multiplayer_room_rebound room_id={d} user_id={d}", .{ room_id, connection.user_id });
        return;
    }
    const room = self.roomByIdLocked(room_id) orelse {
        self.mutex.unlock(self.io);
        return error.MultiplayerRoomNotFound;
    };
    if (roomHasEnded(room, std.Io.Clock.real.now(self.io).toSeconds())) {
        self.mutex.unlock(self.io);
        return error.MultiplayerRoomNotFound;
    }
    if (!std.mem.eql(u8, room.settings.password.slice(), password)) {
        self.mutex.unlock(self.io);
        return error.InvalidMultiplayerPassword;
    }
    if (!room.userAllowed(connection.user_id)) {
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    }
    // A graceful restart restores the room's participant membership before
    // any websocket exists. When that user reconnects and explicitly joins
    // the room, bind the new connection to the restored membership rather
    // than appending the same user a second time.
    if (room.userIndex(connection.user_id) != null) {
        connection.room_id = room_id;
        response = completionRoomOwned(self.allocator, id, room, self.nowMs()) catch |err| {
            connection.room_id = null;
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        defer self.allocator.free(response);
        connection.send(response);
        std.log.info("event=lazer_multiplayer_room_membership_restored room_id={d} user_id={d}", .{ room_id, connection.user_id });
        return;
    }
    const limit: usize = room.settings.max_participants orelse max_users;
    if (room.user_count >= limit) {
        self.mutex.unlock(self.io);
        return error.MultiplayerRoomFull;
    }
    const user_slot = for (room.users, 0..) |entry, index| {
        if (entry == null) break index;
    } else {
        self.mutex.unlock(self.io);
        return error.MultiplayerRoomFull;
    };
    joined = try defaultRoomUser(connection.user_id, connection.user_name.slice(), connection.user_country);
    if (room.settings.match_type == 2) joined.team_id = nextTeamId(room);
    room.users[user_slot] = joined;
    room.user_count += 1;
    connection.room_id = room_id;
    if (room.matchmaking) |*matchmaking| {
        if (matchmaking.stage == matchmaking_stage.waiting_for_clients_join and room.user_count == room.allowed_user_count) {
            matchmaking.current_round = 1;
            matchmaking.stage = matchmaking_stage.user_beatmap_select;
            advanced_match = true;
            match_state_events[0] = eventMatchStateOwned(self.allocator, room) catch |err| {
                matchmaking.current_round = 0;
                matchmaking.stage = matchmaking_stage.waiting_for_clients_join;
                room.users[user_slot] = null;
                room.user_count -= 1;
                connection.room_id = null;
                self.mutex.unlock(self.io);
                return err;
            };
            match_state_event_count = 1;
        }
    }
    if (room.ranked_play) |*ranked| {
        const ranked_user_index = ranked.userIndex(connection.user_id) orelse {
            room.users[user_slot] = null;
            room.user_count -= 1;
            connection.room_id = null;
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        };
        joined_ranked_user = ranked.users[ranked_user_index].?;
        for (joined_ranked_user.?.hand, 0..) |card_entry, index| if (card_entry) |card| {
            const item_index = room.itemIndex(card.playlist_item_id) orelse continue;
            joined_ranked_playlist[index] = room.playlist[item_index].?;
        };
        if (ranked.stage == ranked_stage.wait_for_join and room.user_count == room.allowed_user_count) {
            ranked.stage = ranked_stage.round_warmup;
            ranked.current_round = 1;
            match_state_events[0] = eventMatchStateOwned(self.allocator, room) catch |err| {
                ranked.stage = ranked_stage.wait_for_join;
                ranked.current_round = 0;
                room.users[user_slot] = null;
                room.user_count -= 1;
                connection.room_id = null;
                self.mutex.unlock(self.io);
                return err;
            };
            ranked.stage = ranked_stage.card_discard;
            match_state_events[1] = eventMatchStateOwned(self.allocator, room) catch |err| {
                ranked.stage = ranked_stage.wait_for_join;
                ranked.current_round = 0;
                room.users[user_slot] = null;
                room.user_count -= 1;
                connection.room_id = null;
                self.mutex.unlock(self.io);
                return err;
            };
            match_state_event_count = 2;
            advanced_ranked = true;
        }
    }
    const count = self.recipientsLocked(room_id, connection, &recipients);
    defer releaseRecipients(recipients[0..count]);
    response = completionRoomOwned(self.allocator, id, room, self.nowMs()) catch |err| {
        if (advanced_match) {
            room.matchmaking.?.current_round = 0;
            room.matchmaking.?.stage = matchmaking_stage.waiting_for_clients_join;
        }
        if (advanced_ranked) {
            room.ranked_play.?.current_round = 0;
            room.ranked_play.?.stage = ranked_stage.wait_for_join;
        }
        room.users[user_slot] = null;
        room.user_count -= 1;
        connection.room_id = null;
        self.mutex.unlock(self.io);
        return err;
    };
    room.rememberParticipant(joined);
    self.mutex.unlock(self.io);
    defer self.allocator.free(response);
    connection.send(response);
    const event = try eventUserOwned(self.allocator, "UserJoined", joined);
    defer self.allocator.free(event);
    sendRecipients(recipients[0..count], event);
    if (joined_ranked_user) |ranked_user| for (ranked_user.hand, 0..) |card_entry, index| if (card_entry) |card| if (joined_ranked_playlist[index]) |item| {
        const reveal = try eventRankedCardRevealedOwned(self.allocator, card, item);
        defer self.allocator.free(reveal);
        connection.send(reveal);
    };
    for (match_state_events[0..match_state_event_count]) |state_event| sendRecipients(recipients[0..count], state_event.?);
    std.log.info("event=lazer_multiplayer_room_joined room_id={d} user_id={d}", .{ room_id, connection.user_id });
}

pub fn leaveRoom(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
    var recipients: [max_connections]*Connection = undefined;
    var left_user: ?RoomUser = null;
    var new_host: ?i32 = null;
    var ranked_ended = false;
    var ended_room: ?*Room = null;
    var ranked_event: ?[]u8 = null;
    defer if (ranked_event) |event| self.allocator.free(event);
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id;
    const count = self.leaveLocked(connection, &recipients, &left_user, &new_host, &ranked_ended, &ended_room);
    if (ranked_ended) if (room_id) |id| if (self.roomByIdLocked(id)) |room| {
        ranked_event = try eventMatchStateOwned(self.allocator, room);
    };
    defer releaseRecipients(recipients[0..count]);
    self.mutex.unlock(self.io);
    if (ranked_ended and ended_room == null) if (room_id) |id| {
        self.persistLiveRankedResult(id) catch |err| std.log.err("event=lazer_ranked_rating_persist_failed room_id={d} error={t}", .{ id, err });
        if (self.rankedStateEventForRoom(id) catch null) |updated| {
            if (ranked_event) |old| self.allocator.free(old);
            ranked_event = updated;
        }
    };
    if (ended_room) |ended| self.archiveRoom(ended);
    if (left_user) |user| {
        const event = try eventUserOwned(self.allocator, "UserLeft", user);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
    }
    if (new_host) |host_id| {
        const event = try eventIntegersOwned(self.allocator, "HostChanged", &.{host_id});
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
    }
    if (ranked_event) |event| sendRecipients(recipients[0..count], event);
    try self.finishVoid(connection, invocation_id);
}

pub fn transferHost(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, target_user_id: i32) !void {
    var recipients: [max_connections]*Connection = undefined;
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    if (room.host_id != connection.user_id or room.userIndex(target_user_id) == null) {
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    }
    room.host_id = target_user_id;
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    self.mutex.unlock(self.io);
    const event = try eventIntegersOwned(self.allocator, "HostChanged", &.{target_user_id});
    defer self.allocator.free(event);
    sendRecipients(recipients[0..count], event);
    try self.finishVoid(connection, invocation_id);
}

pub fn kickUser(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, target_user_id: i32) !void {
    if (target_user_id == connection.user_id) return error.MultiplayerPermissionDenied;
    var recipients: [max_connections]*Connection = undefined;
    var target_connection: ?*Connection = null;
    var kicked: RoomUser = undefined;
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    if (room.host_id != connection.user_id) {
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    }
    const index = room.userIndex(target_user_id) orelse {
        self.mutex.unlock(self.io);
        return error.MultiplayerUserNotFound;
    };
    kicked = room.users[index].?;
    room.users[index] = null;
    room.user_count -= 1;
    for (self.connections.items) |candidate| if (candidate.user_id == target_user_id and candidate.room_id == room_id) {
        candidate.room_id = null;
        candidate.retain();
        target_connection = candidate;
        break;
    };
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    defer if (target_connection) |target| target.release();
    self.mutex.unlock(self.io);
    const event = try eventUserOwned(self.allocator, "UserKicked", kicked);
    defer self.allocator.free(event);
    sendRecipients(recipients[0..count], event);
    if (target_connection) |target| {
        target.send(event);
    }
    try self.finishVoid(connection, invocation_id);
}

pub fn invitePlayer(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, user_id: i32) !void {
    var target: ?*Connection = null;
    var room_id: i64 = 0;
    var password: [64]u8 = undefined;
    var password_len: usize = 0;
    self.mutex.lockUncancelable(self.io);
    room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    const password_slice = room.settings.password.slice();
    @memcpy(password[0..password_slice.len], password_slice);
    password_len = password_slice.len;
    for (self.connections.items) |candidate| if (candidate.user_id == user_id and candidate.room_id == null and candidate.alive.load(.acquire)) {
        candidate.retain();
        target = candidate;
        break;
    };
    defer if (target) |recipient| recipient.release();
    self.mutex.unlock(self.io);
    if (target) |recipient| {
        const event = try eventInviteOwned(self.allocator, connection.user_id, room_id, password[0..password_len]);
        defer self.allocator.free(event);
        recipient.send(event);
    }
    try self.finishVoid(connection, invocation_id);
}
