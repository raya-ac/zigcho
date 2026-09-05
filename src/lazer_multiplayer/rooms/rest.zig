const std = @import("std");
const domain = @import("../../domain.zig");
const lazer = @import("../../lazer.zig");
const publicCountry = @import("state.zig").publicCountry;
const max_users = @import("../../lazer_multiplayer.zig").max_users;
const Room = @import("model.zig").Room;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const defaultRoomUser = @import("state.zig").defaultRoomUser;
const nextTeamId = @import("state.zig").nextTeamId;
const parseRestRoom = @import("../wire/rest.zig").parseRestRoom;
const roomHasEnded = @import("../wire/json.zig").roomHasEnded;
const writeRoomJson = @import("../wire/json.zig").writeRoomJson;

pub fn restCreateRoom(self: *Manager, allocator: std.mem.Allocator, user: domain.User, body: []const u8) ![]u8 {
    var mutation = try self.beginMutation();
    defer mutation.deinit();
    const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
    const room = try parseRestRoom(self.allocator, user, body, now_seconds, false);
    errdefer {
        room.deinit(self.allocator);
        self.allocator.destroy(room);
    }
    try self.hydrateRoom(room);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (!self.mutationAllowedLocked()) return self.blockedMutationErrorLocked();
    for (self.rooms) |entry| if (entry) |existing| if (existing.userIndex(user.id) != null) return error.AlreadyInMultiplayerRoom;
    const slot = self.roomSlotLocked() orelse return error.MultiplayerRoomLimit;
    room.id = self.next_room_id;
    room.channel_id = @intCast(lazer.roomChannelId(room.id) orelse return error.MultiplayerRoomLimit);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    writeRoomJson(&output.writer, room, user.id, now_seconds, .none) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    const response = try output.toOwnedSlice();
    self.next_room_id += 1;
    if (room.settings.match_type != 0) {
        if (self.connectionByUserLocked(user.id)) |connection| connection.room_id = room.id;
    }
    self.rooms[slot] = room;
    std.log.info("event=lazer_multiplayer_rest_room_created room_id={d} host_id={d}", .{ room.id, user.id });
    return response;
}

pub fn restJoinRoom(self: *Manager, allocator: std.mem.Allocator, user: domain.User, room_id: i64, password: []const u8) ![]u8 {
    var mutation = try self.beginMutation();
    defer mutation.deinit();
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (!self.mutationAllowedLocked()) return self.blockedMutationErrorLocked();
    var added_slot: ?usize = null;
    errdefer if (added_slot) |slot| {
        const room = self.roomByIdLocked(room_id) orelse unreachable;
        room.users[slot] = null;
        room.user_count -= 1;
    };
    for (self.rooms) |entry| if (entry) |existing| if (existing.id != room_id and existing.userIndex(user.id) != null) return error.AlreadyInMultiplayerRoom;
    const room = self.roomByIdLocked(room_id) orelse return error.MultiplayerRoomNotFound;
    if (roomHasEnded(room, std.Io.Clock.real.now(self.io).toSeconds())) return error.MultiplayerRoomNotFound;
    if (!std.mem.eql(u8, room.settings.password.slice(), password)) return error.InvalidMultiplayerPassword;
    if (!room.userAllowed(user.id)) return error.MultiplayerPermissionDenied;
    if (room.userIndex(user.id) == null) {
        const limit: usize = room.settings.max_participants orelse max_users;
        if (room.user_count >= limit) return error.MultiplayerRoomFull;
        const slot = for (room.users, 0..) |entry, index| {
            if (entry == null) break index;
        } else return error.MultiplayerRoomFull;
        var joined = try defaultRoomUser(user.id, user.name, publicCountry(user));
        if (room.settings.match_type == 2) joined.team_id = nextTeamId(room);
        room.users[slot] = joined;
        room.user_count += 1;
        added_slot = slot;
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    writeRoomJson(&output.writer, room, user.id, std.Io.Clock.real.now(self.io).toSeconds(), .none) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    const response = try output.toOwnedSlice();
    if (added_slot != null) room.rememberParticipant(room.users[added_slot.?].?);
    if (room.settings.match_type != 0) {
        if (self.connectionByUserLocked(user.id)) |connection| connection.room_id = room_id;
    }
    std.log.info("event=lazer_multiplayer_rest_room_joined room_id={d} user_id={d}", .{ room_id, user.id });
    return response;
}

pub fn restPartRoom(self: *Manager, user_id: i32, room_id: i64) !void {
    var mutation = try self.beginMutation();
    defer mutation.deinit();
    self.mutex.lockUncancelable(self.io);
    if (!self.mutationAllowedLocked()) {
        const err = self.blockedMutationErrorLocked();
        self.mutex.unlock(self.io);
        return err;
    }
    const room = self.roomByIdLocked(room_id) orelse {
        self.mutex.unlock(self.io);
        return error.MultiplayerRoomNotFound;
    };
    const index = room.userIndex(user_id) orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    room.users[index] = null;
    room.user_count -= 1;
    if (self.connectionByUserLocked(user_id)) |connection| if (connection.room_id == room_id) {
        connection.room_id = null;
    };
    var ended_room: ?*Room = null;
    if (room.user_count == 0 and room.settings.match_type != 0) {
        for (&self.rooms) |*entry| if (entry.* == room) {
            entry.* = null;
            break;
        };
        ended_room = room;
    } else if (room.host_id == user_id) {
        for (room.users) |entry| if (entry) |next| {
            room.host_id = next.id;
            room.host_name = next.name;
            room.host_country = next.country;
            break;
        };
    }
    self.mutex.unlock(self.io);
    if (ended_room) |ended| self.archiveRoom(ended);
    std.log.info("event=lazer_multiplayer_rest_room_left room_id={d} user_id={d}", .{ room_id, user_id });
}

pub fn restCloseRoom(self: *Manager, user_id: i32, room_id: i64) !void {
    var mutation = try self.beginMutation();
    defer mutation.deinit();
    self.mutex.lockUncancelable(self.io);
    if (!self.mutationAllowedLocked()) {
        const err = self.blockedMutationErrorLocked();
        self.mutex.unlock(self.io);
        return err;
    }
    const room = self.roomByIdLocked(room_id) orelse {
        self.mutex.unlock(self.io);
        return error.MultiplayerRoomNotFound;
    };
    if (room.host_id != user_id) {
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    }
    for (self.connections.items) |connection| {
        if (connection.room_id == room_id) connection.room_id = null;
    }
    for (&self.rooms) |*entry| if (entry.* == room) {
        entry.* = null;
        break;
    };
    self.mutex.unlock(self.io);
    self.archiveRoom(room);
    std.log.info("event=lazer_multiplayer_rest_room_closed room_id={d} user_id={d}", .{ room_id, user_id });
}
