const max_connections = @import("../../lazer_multiplayer.zig").max_connections;
const eventNoArgsOwned = @import("../../lazer_multiplayer.zig").eventNoArgsOwned;
const eventIntegersOwned = @import("../../lazer_multiplayer.zig").eventIntegersOwned;
const eventIntegerBoolOwned = @import("../../lazer_multiplayer.zig").eventIntegerBoolOwned;
const Connection = @import("../transport/model.zig").Connection;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const nextPlaylistOrder = @import("state.zig").nextPlaylistOrder;
const parsePlaylistItem = @import("../wire/parse.zig").parsePlaylistItem;
const eventPlaylistOwned = @import("../transport/events.zig").eventPlaylistOwned;
const sendRecipients = @import("../transport/connections.zig").sendRecipients;
const releaseRecipients = @import("../transport/connections.zig").releaseRecipients;

pub fn addPlaylistItem(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
    var item = try parsePlaylistItem(encoded);
    try self.hydratePlaylistItem(&item);
    var recipients: [max_connections]*Connection = undefined;
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    if (room.settings.queue_mode == 0 and room.host_id != connection.user_id) {
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    }
    const slot = for (room.playlist, 0..) |entry, index| if (entry == null) break index else {} else {
        self.mutex.unlock(self.io);
        return error.MultiplayerPlaylistFull;
    };
    item.id = 1;
    for (room.playlist) |entry| {
        if (entry) |existing| item.id = @max(item.id, existing.id + 1);
    }
    item.owner_id = connection.user_id;
    item.order = nextPlaylistOrder(room) orelse {
        self.mutex.unlock(self.io);
        return error.MultiplayerPlaylistFull;
    };
    room.playlist[slot] = item;
    room.playlist_count += 1;
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    const event = eventPlaylistOwned(self.allocator, "PlaylistItemAdded", item) catch |err| {
        self.mutex.unlock(self.io);
        return err;
    };
    self.mutex.unlock(self.io);
    defer self.allocator.free(event);
    sendRecipients(recipients[0..count], event);
    try self.finishVoid(connection, invocation_id);
}

pub fn editPlaylistItem(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
    var item = try parsePlaylistItem(encoded);
    try self.hydratePlaylistItem(&item);
    var recipients: [max_connections]*Connection = undefined;
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    const index = room.itemIndex(item.id) orelse {
        self.mutex.unlock(self.io);
        return error.MultiplayerPlaylistItemNotFound;
    };
    if (room.host_id != connection.user_id and room.playlist[index].?.owner_id != connection.user_id) {
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    }
    room.playlist[index] = item;
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    const event = eventPlaylistOwned(self.allocator, "PlaylistItemChanged", item) catch |err| {
        self.mutex.unlock(self.io);
        return err;
    };
    self.mutex.unlock(self.io);
    defer self.allocator.free(event);
    sendRecipients(recipients[0..count], event);
    try self.finishVoid(connection, invocation_id);
}

pub fn removePlaylistItem(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, item_id: i64) !void {
    var recipients: [max_connections]*Connection = undefined;
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    const index = room.itemIndex(item_id) orelse {
        self.mutex.unlock(self.io);
        return error.MultiplayerPlaylistItemNotFound;
    };
    if (room.playlist_count <= 1 or room.settings.playlist_item_id == item_id or (room.host_id != connection.user_id and room.playlist[index].?.owner_id != connection.user_id)) {
        self.mutex.unlock(self.io);
        return error.MultiplayerPermissionDenied;
    }
    room.playlist[index] = null;
    room.playlist_count -= 1;
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    self.mutex.unlock(self.io);
    const event = try eventIntegersOwned(self.allocator, "PlaylistItemRemoved", &.{item_id});
    defer self.allocator.free(event);
    sendRecipients(recipients[0..count], event);
    try self.finishVoid(connection, invocation_id);
}

pub fn voteSkip(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
    var recipients: [max_connections]*Connection = undefined;
    var passed = false;
    self.mutex.lockUncancelable(self.io);
    const room_id = connection.room_id orelse {
        self.mutex.unlock(self.io);
        return error.NotInMultiplayerRoom;
    };
    const room = self.roomByIdLocked(room_id).?;
    const index = room.userIndex(connection.user_id).?;
    room.users[index].?.voted_skip = true;
    var playing: usize = 0;
    var votes: usize = 0;
    for (room.users) |entry| if (entry) |user| {
        if (user.state == 5) playing += 1;
        if (user.state == 5 and user.voted_skip) votes += 1;
    };
    passed = playing != 0 and votes >= playing / 2 + 1;
    const count = self.recipientsLocked(room_id, null, &recipients);
    defer releaseRecipients(recipients[0..count]);
    self.mutex.unlock(self.io);
    const vote = try eventIntegerBoolOwned(self.allocator, "UserVotedToSkipIntro", connection.user_id, true);
    defer self.allocator.free(vote);
    sendRecipients(recipients[0..count], vote);
    if (passed) {
        const event = try eventNoArgsOwned(self.allocator, "VoteToSkipIntroPassed");
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
    }
    try self.finishVoid(connection, invocation_id);
}
