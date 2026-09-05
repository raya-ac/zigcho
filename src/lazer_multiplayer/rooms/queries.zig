const std = @import("std");
const lazer = @import("../../lazer.zig");
const storage = @import("../../runtime_storage.zig");
const Activity = @import("../../lazer_multiplayer.zig").Activity;
const RoomListFilter = @import("../../lazer_multiplayer.zig").RoomListFilter;
const archiveIncludesUser = @import("../archive/codec.zig").archiveIncludesUser;
const Room = @import("model.zig").Room;
const roomCategory = @import("../../lazer_multiplayer.zig").roomCategory;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const writeApiUserJson = @import("../wire/json.zig").writeApiUserJson;
const roomHasEnded = @import("../wire/json.zig").roomHasEnded;
const writeRoomJson = @import("../wire/json.zig").writeRoomJson;
const RuntimeCounts = @import("../../lazer_multiplayer.zig").Manager.RuntimeCounts;

pub fn roomByIdLocked(self: *Manager, room_id: i64) ?*Room {
    for (self.rooms) |entry| if (entry) |room| if (room.id == room_id) return room;
    return null;
}

pub fn archivedRoomForParticipant(self: *Manager, allocator: std.mem.Allocator, room_id: i64, user_id: i32) !?storage.Store.MultiplayerRoomArchive {
    const store = self.store orelse return null;
    var archive = (try store.lazerMultiplayerRoomArchive(allocator, room_id)) orelse return null;
    if (!archiveIncludesUser(allocator, archive.participant_ids_json, user_id)) {
        archive.deinit();
        return null;
    }
    return archive;
}

pub fn activity(self: *Manager, user_id: i32) ?Activity {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const connection = self.connectionByUserLocked(user_id) orelse return null;
    if (connection.room_id) |room_id| {
        const room = self.roomByIdLocked(room_id) orelse return .multiplayer;
        return if (room.state == 1 or room.state == 2) .playing else .multiplayer;
    }
    if (connection.queue_pool_id != null or connection.pending_match_id != null) return .queue;
    if (connection.lobby_pool_id != null) return .lobby;
    return null;
}

pub fn currentRoomId(self: *Manager, user_id: i32) ?i64 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.rooms) |entry| if (entry) |room| if (room.userIndex(user_id) != null) return room.id;
    return null;
}

pub fn runtimeCounts(self: *Manager) RuntimeCounts {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var counts: RuntimeCounts = .{ .connections = 0, .rooms = 0, .queued = 0, .pending_matches = 0 };
    for (self.connections.items) |connection| {
        if (!connection.alive.load(.acquire)) continue;
        counts.connections += 1;
        if (connection.queue_pool_id != null or connection.pending_match_id != null) counts.queued += 1;
    }
    for (self.rooms) |room| if (room != null) {
        counts.rooms += 1;
    };
    for (self.pending_matches) |pending| if (pending != null) {
        counts.pending_matches += 1;
    };
    return counts;
}

pub fn roomChannelAccess(self: *Manager, user_id: i32, channel_id: i64) ?i64 {
    const room_id = lazer.roomChannelRoom(channel_id) orelse return null;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const room = self.roomByIdLocked(room_id) orelse return null;
    if (room.channel_id != channel_id or room.userIndex(user_id) == null) return null;
    return room_id;
}

pub fn roomChannelUsersJson(self: *Manager, allocator: std.mem.Allocator, user_id: i32, channel_id: i64) !?[]u8 {
    const room_id = lazer.roomChannelRoom(channel_id) orelse return null;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const room = self.roomByIdLocked(room_id) orelse return null;
    if (room.channel_id != channel_id or room.userIndex(user_id) == null) return null;
    try output.writer.writeByte('[');
    var written: usize = 0;
    for (room.users) |entry| if (entry) |participant| {
        if (written != 0) try output.writer.writeByte(',');
        try writeApiUserJson(&output.writer, participant.id, participant.name.slice(), participant.country);
        written += 1;
    };
    try output.writer.writeByte(']');
    return try output.toOwnedSlice();
}

pub fn setUserCountryVisibility(self: *Manager, user_id: i32, country: [2]u8, visible: bool) void {
    const projected = if (visible) country else .{ 'X', 'X' };
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.connections.items) |connection| {
        if (connection.user_id == user_id) connection.user_country = projected;
    }
    for (self.rooms) |entry| if (entry) |room| {
        if (room.host_id == user_id) room.host_country = projected;
        for (&room.users) |*room_user| if (room_user.*) |*value| {
            if (value.id == user_id) value.country = projected;
        };
        for (room.participants[0..room.participant_count]) |*participant| if (participant.*) |*value| {
            if (value.id == user_id) value.country = projected;
        };
    };
}

pub fn roomsJson(self: *Manager, allocator: std.mem.Allocator, only_room_id: ?i64, filter: ?RoomListFilter, requester_id: i32) !?[]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
    self.mutex.lockUncancelable(self.io);
    if (only_room_id) |room_id| {
        if (self.roomByIdLocked(room_id)) |room| {
            writeRoomJson(&output.writer, room, requester_id, now_seconds, .none) catch |err| {
                self.mutex.unlock(self.io);
                return err;
            };
            self.mutex.unlock(self.io);
            return try output.toOwnedSlice();
        }
        self.mutex.unlock(self.io);
        const store = self.store orelse return null;
        var archive = (try store.lazerMultiplayerRoomArchive(allocator, room_id)) orelse return null;
        defer archive.deinit();
        try self.writeHydratedArchiveJson(&output.writer, archive.room_json);
        return try output.toOwnedSlice();
    }
    output.writer.writeByte('[') catch |err| {
        self.mutex.unlock(self.io);
        return err;
    };
    var written: usize = 0;
    for (self.rooms) |entry| if (entry) |room| {
        if (filter) |value| {
            const ended = roomHasEnded(room, now_seconds);
            if (value.mode == .ended and !ended) continue;
            if (value.mode != .ended and ended) continue;
            if (value.mode == .owned and room.host_id != value.requester_id) continue;
            if (value.mode == .participated and room.participantIndex(value.requester_id) == null) continue;
            if (value.status) |wanted| if ((wanted == .idle) != (ended or room.state == 0)) continue;
            if (value.kind == .playlists and room.settings.match_type != 0) continue;
            if (value.kind == .realtime and room.settings.match_type == 0) continue;
            if (value.category.len != 0 and !std.mem.eql(u8, value.category, roomCategory(room))) continue;
        }
        if (written != 0) output.writer.writeByte(',') catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        writeRoomJson(&output.writer, room, requester_id, now_seconds, .none) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        written += 1;
    };
    self.mutex.unlock(self.io);
    const include_archives = filter == null or filter.?.mode == .ended or filter.?.mode == .participated or filter.?.mode == .owned;
    if (include_archives) if (self.store) |store| {
        const archives = try store.lazerMultiplayerRoomArchives(allocator, 100);
        defer {
            for (archives) |*archive| archive.deinit();
            allocator.free(archives);
        }
        for (archives) |archive| {
            if (filter) |value| {
                if (value.kind == .playlists and !std.mem.eql(u8, archive.category, "normal")) continue;
                if (value.kind == .realtime and !std.mem.eql(u8, archive.category, "realtime")) continue;
                // Completed rooms are exposed to lazer as idle because the
                // pinned RoomStatus model only has idle and playing.
                if (value.status == .playing) continue;
                if (value.category.len != 0 and !std.mem.eql(u8, value.category, archive.category)) continue;
                if (value.mode == .owned and archive.owner_id != value.requester_id) continue;
                if (value.mode == .participated and !archiveIncludesUser(allocator, archive.participant_ids_json, value.requester_id)) continue;
            }
            if (written != 0) try output.writer.writeByte(',');
            try self.writeHydratedArchiveJson(&output.writer, archive.room_json);
            written += 1;
        }
    };
    try output.writer.writeByte(']');
    return try output.toOwnedSlice();
}
