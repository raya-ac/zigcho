const std = @import("std");
const max_connections = @import("../../lazer_multiplayer.zig").max_connections;
const max_users = @import("../../lazer_multiplayer.zig").max_users;
const timespan_ticks_per_millisecond = @import("../../lazer_multiplayer.zig").timespan_ticks_per_millisecond;
const timespan_ticks_per_second = @import("../../lazer_multiplayer.zig").timespan_ticks_per_second;
const ranked_stage = @import("../../lazer_multiplayer.zig").ranked_stage;
const MessagePackReader = @import("../../lazer_multiplayer.zig").MessagePackReader;
const eventIntegersOwned = @import("../../lazer_multiplayer.zig").eventIntegersOwned;
const eventIntegerRawOwned = @import("../../lazer_multiplayer.zig").eventIntegerRawOwned;
const MatchStartCountdownState = @import("../../lazer_multiplayer.zig").MatchStartCountdownState;
const Room = @import("model.zig").Room;
const Connection = @import("../transport/model.zig").Connection;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const roomBeatmapsLocallyAvailable = @import("state.zig").roomBeatmapsLocallyAvailable;
const nextTeamId = @import("state.zig").nextTeamId;
const parseSettings = @import("../wire/parse.zig").parseSettings;
const eventMatchStateOwned = @import("../transport/events.zig").eventMatchStateOwned;
const eventMatchStartCountdownOwned = @import("../transport/events.zig").eventMatchStartCountdownOwned;
const eventRankedCountdownStoppedOwned = @import("../transport/events.zig").eventRankedCountdownStoppedOwned;
const eventMatchRoomStateOwned = @import("../transport/events.zig").eventMatchRoomStateOwned;
const eventTeamStateOwned = @import("../transport/events.zig").eventTeamStateOwned;
const eventSettingsOwned = @import("../transport/events.zig").eventSettingsOwned;
const eventStyleOwned = @import("../transport/events.zig").eventStyleOwned;
const sendRecipients = @import("../transport/connections.zig").sendRecipients;
const releaseRecipients = @import("../transport/connections.zig").releaseRecipients;
const roll = @import("events.zig").roll;

pub fn changeSettings(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
    var settings = try parseSettings(encoded);
    var recipients: [max_connections]*Connection = undefined;
    var reset_users: [max_users]i32 = undefined;
    var reset_user_count: usize = 0;
    var team_users: [max_users]struct { id: i32, team_id: i32 } = undefined;
    var team_user_count: usize = 0;
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
    if (settings.max_participants) |limit| if (limit < room.user_count) {
        self.mutex.unlock(self.io);
        return error.InvalidMultiplayerParticipantLimit;
    };
    const room_before = room.*;
    if (settings.playlist_item_id == 0 or room.itemIndex(settings.playlist_item_id) == null) settings.playlist_item_id = room.settings.playlist_item_id;
    room.settings = settings;
    for (&room.users) |*entry| {
        if (entry.*) |*user| {
            if (user.state == 1) {
                user.state = 0;
                reset_users[reset_user_count] = user.id;
                reset_user_count += 1;
            }
            if (settings.match_type == 2) {
                if (user.team_id == null) user.team_id = nextTeamId(room);
                team_users[team_user_count] = .{ .id = user.id, .team_id = user.team_id.? };
                team_user_count += 1;
            } else user.team_id = null;
        }
    }
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    const settings_event = eventSettingsOwned(self.allocator, "SettingsChanged", room.settings) catch |err| {
        self.mutex.unlock(self.io);
        return err;
    };
    errdefer self.allocator.free(settings_event);
    const room_state_event = eventMatchRoomStateOwned(self.allocator, room) catch |err| {
        room.* = room_before;
        self.mutex.unlock(self.io);
        return err;
    };
    self.mutex.unlock(self.io);
    defer self.allocator.free(settings_event);
    defer self.allocator.free(room_state_event);
    sendRecipients(recipients[0..count], settings_event);
    sendRecipients(recipients[0..count], room_state_event);
    for (reset_users[0..reset_user_count]) |user_id| {
        const state_event = try eventIntegersOwned(self.allocator, "UserStateChanged", &.{ user_id, 0 });
        defer self.allocator.free(state_event);
        sendRecipients(recipients[0..count], state_event);
    }
    for (team_users[0..team_user_count]) |team| {
        const team_event = try eventTeamStateOwned(self.allocator, team.id, team.team_id);
        defer self.allocator.free(team_event);
        sendRecipients(recipients[0..count], team_event);
    }
    try self.finishVoid(connection, invocation_id);
}

pub fn changeAvailability(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
    const availability_event = try eventIntegerRawOwned(self.allocator, "UserBeatmapAvailabilityChanged", connection.user_id, encoded);
    defer self.allocator.free(availability_event);
    var recipients: [max_connections]*Connection = undefined;
    var warmup_event: ?[]u8 = null;
    defer if (warmup_event) |event| self.allocator.free(event);
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    const index = room.userIndex(connection.user_id).?;
    const previous_availability = room.users[index].?.availability;
    room.users[index].?.availability.set(encoded) catch |err| {
        self.mutex.unlock(self.io);
        return err;
    };
    if (room.ranked_play) |*ranked| if (ranked.stage == ranked_stage.finish_card_play and roomBeatmapsLocallyAvailable(room)) {
        ranked.stage = ranked_stage.gameplay_warmup;
        warmup_event = eventMatchStateOwned(self.allocator, room) catch |err| {
            ranked.stage = ranked_stage.finish_card_play;
            room.users[index].?.availability = previous_availability;
            self.mutex.unlock(self.io);
            return err;
        };
    };
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    self.mutex.unlock(self.io);
    sendRecipients(recipients[0..count], availability_event);
    if (warmup_event) |event| sendRecipients(recipients[0..count], event);
    try self.finishVoid(connection, invocation_id);
}

pub fn changeStyle(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, beatmap_id: ?i32, ruleset_id: ?i32) !void {
    var recipients: [max_connections]*Connection = undefined;
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    const index = room.userIndex(connection.user_id).?;
    room.users[index].?.beatmap_id = beatmap_id;
    room.users[index].?.ruleset_id = ruleset_id;
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    self.mutex.unlock(self.io);
    const event = try eventStyleOwned(self.allocator, connection.user_id, beatmap_id, ruleset_id);
    defer self.allocator.free(event);
    sendRecipients(recipients[0..count], event);
    try self.finishVoid(connection, invocation_id);
}

pub fn changeMods(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
    var recipients: [max_connections]*Connection = undefined;
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    const index = room.userIndex(connection.user_id).?;
    room.users[index].?.mods.set(encoded) catch |err| {
        self.mutex.unlock(self.io);
        return err;
    };
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    self.mutex.unlock(self.io);
    const event = try eventIntegerRawOwned(self.allocator, "UserModsChanged", connection.user_id, encoded);
    defer self.allocator.free(event);
    sendRecipients(recipients[0..count], event);
    try self.finishVoid(connection, invocation_id);
}

pub fn sendMatchRequest(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
    const ParsedRequest = union(enum) {
        change_team: i32,
        start_countdown: i64,
        stop_countdown: i32,
        avatar_action: i64,
        ranked_hand_replay: []const u8,
        set_lock: bool,
        roll: ?i64,
        change_slot: u8,
    };
    var reader: MessagePackReader = .{ .data = encoded };
    if (try reader.arrayLen() != 2) return error.InvalidMultiplayerArguments;
    const request_type = try reader.integer();
    const payload = try reader.raw();
    if (reader.pos != reader.data.len) return error.InvalidMultiplayerArguments;
    var payload_reader: MessagePackReader = .{ .data = payload };
    if (try payload_reader.arrayLen() != 1) return error.InvalidMultiplayerArguments;
    const request: ParsedRequest = switch (request_type) {
        0 => .{ .change_team = std.math.cast(i32, try payload_reader.integer()) orelse return error.InvalidMultiplayerArguments },
        1 => .{ .start_countdown = try payload_reader.integer() },
        2 => .{ .stop_countdown = std.math.cast(i32, try payload_reader.integer()) orelse return error.InvalidMultiplayerArguments },
        3 => .{ .avatar_action = try payload_reader.integer() },
        4 => .{ .ranked_hand_replay = try payload_reader.raw() },
        5 => .{ .set_lock = try payload_reader.boolean() },
        6 => .{ .roll = try payload_reader.nullableInteger() },
        7 => .{ .change_slot = std.math.cast(u8, try payload_reader.integer()) orelse return error.InvalidMultiplayerArguments },
        else => return error.UnsupportedMultiplayerMethod,
    };
    if (payload_reader.pos != payload_reader.data.len) return error.InvalidMultiplayerArguments;
    switch (request) {
        .change_team => |team_id| try self.changeTeam(connection, invocation_id, team_id),
        .start_countdown => |duration_ticks| try self.startMatchCountdown(connection, invocation_id, duration_ticks),
        .stop_countdown => |countdown_id| try self.stopMatchCountdown(connection, invocation_id, countdown_id),
        .avatar_action => |action| try self.matchmakingAvatarAction(connection, invocation_id, action),
        .ranked_hand_replay => |frames| try self.rankedHandReplay(connection, invocation_id, frames),
        .set_lock => |locked| try self.setRoomLock(connection, invocation_id, locked),
        .roll => |max| try self.roll(connection, invocation_id, max),
        .change_slot => |slot_id| try self.changeSlot(connection, invocation_id, slot_id),
    }
}

pub fn changeTeam(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, team_id: i32) !void {
    if (team_id < 0 or team_id > 1) return error.InvalidMultiplayerTeam;
    var recipients: [max_connections]*Connection = undefined;
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    const user_index = room.userIndex(connection.user_id).?;
    const user = &room.users[user_index].?;
    if (room.settings.match_type != 2 or room.state != 0 or (room.locked and room.host_id != connection.user_id and user.role != 1)) {
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    }
    user.team_id = team_id;
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    self.mutex.unlock(self.io);
    const event = try eventTeamStateOwned(self.allocator, connection.user_id, team_id);
    defer self.allocator.free(event);
    sendRecipients(recipients[0..count], event);
    try self.finishVoid(connection, invocation_id);
}

pub fn startMatchCountdown(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, duration_ticks: i64) !void {
    if (duration_ticks < timespan_ticks_per_second or duration_ticks > 10 * 60 * timespan_ticks_per_second) return error.InvalidMultiplayerCountdown;
    const duration_ms = @divFloor(duration_ticks, timespan_ticks_per_millisecond);
    var recipients: [max_connections]*Connection = undefined;
    var countdown: MatchStartCountdownState = undefined;
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    const user_index = room.userIndex(connection.user_id).?;
    if ((room.host_id != connection.user_id and room.users[user_index].?.role != 1) or room.state != 0 or room.match_start_countdown != null) {
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    }
    countdown = .{ .id = self.next_countdown_id, .deadline_ms = self.nowMs() + duration_ms };
    self.next_countdown_id = if (self.next_countdown_id == std.math.maxInt(i32)) 1 else self.next_countdown_id + 1;
    room.match_start_countdown = countdown;
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    self.mutex.unlock(self.io);
    const event = try eventMatchStartCountdownOwned(self.allocator, countdown, self.nowMs());
    defer self.allocator.free(event);
    sendRecipients(recipients[0..count], event);
    try self.finishVoid(connection, invocation_id);
}

pub fn stopMatchCountdown(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, countdown_id: i32) !void {
    var recipients: [max_connections]*Connection = undefined;
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    const user_index = room.userIndex(connection.user_id).?;
    if ((room.host_id != connection.user_id and room.users[user_index].?.role != 1) or room.match_start_countdown == null or room.match_start_countdown.?.id != countdown_id) {
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    }
    room.match_start_countdown = null;
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    self.mutex.unlock(self.io);
    const event = try eventRankedCountdownStoppedOwned(self.allocator, countdown_id);
    defer self.allocator.free(event);
    sendRecipients(recipients[0..count], event);
    try self.finishVoid(connection, invocation_id);
}

pub fn setRoomLock(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, locked: bool) !void {
    var recipients: [max_connections]*Connection = undefined;
    var snapshot: Room = undefined;
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    const user_index = room.userIndex(connection.user_id).?;
    if (room.host_id != connection.user_id and room.users[user_index].?.role != 1) {
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    }
    room.locked = locked;
    snapshot = room.*;
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    self.mutex.unlock(self.io);
    const event = try eventMatchRoomStateOwned(self.allocator, &snapshot);
    defer self.allocator.free(event);
    sendRecipients(recipients[0..count], event);
    try self.finishVoid(connection, invocation_id);
}

pub fn changeSlot(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, slot_id: u8) !void {
    var recipients: [max_connections]*Connection = undefined;
    var snapshot: Room = undefined;
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    const user_index = room.userIndex(connection.user_id).?;
    const limit: usize = room.settings.max_participants orelse max_users;
    if (slot_id >= limit or room.users[slot_id] != null or room.state != 0 or (room.locked and room.host_id != connection.user_id and room.users[user_index].?.role != 1)) {
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    }
    room.users[slot_id] = room.users[user_index];
    room.users[user_index] = null;
    snapshot = room.*;
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    self.mutex.unlock(self.io);
    const event = try eventMatchRoomStateOwned(self.allocator, &snapshot);
    defer self.allocator.free(event);
    sendRecipients(recipients[0..count], event);
    try self.finishVoid(connection, invocation_id);
}
