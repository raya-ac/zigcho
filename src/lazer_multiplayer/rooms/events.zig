const std = @import("std");
const max_connections = @import("../../lazer_multiplayer.zig").max_connections;
const Connection = @import("../transport/model.zig").Connection;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const eventRollOwned = @import("../transport/events.zig").eventRollOwned;
const eventMatchmakingAvatarActionOwned = @import("../transport/events.zig").eventMatchmakingAvatarActionOwned;
const sendRecipients = @import("../transport/connections.zig").sendRecipients;
const releaseRecipients = @import("../transport/connections.zig").releaseRecipients;

pub fn roll(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, requested_max: ?i64) !void {
    const max = requested_max orelse 100;
    if (max < 2 or max > 1_000_000) return error.InvalidMultiplayerRoll;
    var random: [8]u8 = undefined;
    try self.io.randomSecure(&random);
    const result = @as(i64, @intCast(std.mem.readInt(u64, &random, .little) % @as(u64, @intCast(max)))) + 1;
    var recipients: [max_connections]*Connection = undefined;
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    if (self.roomByIdLocked(room_id).?.userIndex(connection.user_id) == null) {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    }
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    self.mutex.unlock(self.io);
    const event = try eventRollOwned(self.allocator, connection.user_id, max, result);
    defer self.allocator.free(event);
    sendRecipients(recipients[0..count], event);
    try self.finishVoid(connection, invocation_id);
}

pub fn matchmakingAvatarAction(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, action: i64) !void {
    if (action != 0) return error.InvalidMultiplayerAvatarAction;
    var recipients: [max_connections]*Connection = undefined;
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    if (room.matchmaking == null or room.userIndex(connection.user_id) == null) {
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    }
    const count = self.recipientsLocked(room_id, connection, &recipients);
    defer releaseRecipients(recipients[0..count]);
    self.mutex.unlock(self.io);
    const event = try eventMatchmakingAvatarActionOwned(self.allocator, connection.user_id, action);
    defer self.allocator.free(event);
    sendRecipients(recipients[0..count], event);
    try self.finishVoid(connection, invocation_id);
}
