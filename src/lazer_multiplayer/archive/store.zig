const std = @import("std");
const storage = @import("../../runtime_storage.zig");
const max_rooms = @import("../../lazer_multiplayer.zig").max_rooms;
const max_pending_archives = @import("../../lazer_multiplayer.zig").max_pending_archives;
const RoomPersistence = @import("../../lazer_multiplayer.zig").RoomPersistence;
const Room = @import("../rooms/model.zig").Room;
const roomCategory = @import("../../lazer_multiplayer.zig").roomCategory;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const restoreRoomCheckpoint = @import("../wire/rest.zig").restoreRoomCheckpoint;
const roomHasEnded = @import("../wire/json.zig").roomHasEnded;
const writeRoomJson = @import("../wire/json.zig").writeRoomJson;
const writeRoomLeaderboardJson = @import("../wire/json.zig").writeRoomLeaderboardJson;

pub fn bindStore(self: *Manager, store: *storage.Store) !void {
    self.store = store;
    self.next_room_id = @max(self.next_room_id, try store.nextLazerMultiplayerRoomId());
    const checkpoints = try store.lazerMultiplayerRoomCheckpoints(self.allocator);
    defer {
        for (checkpoints) |*checkpoint| checkpoint.deinit();
        self.allocator.free(checkpoints);
    }
    const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
    for (checkpoints) |checkpoint| {
        const restored = restoreRoomCheckpoint(self.allocator, checkpoint.room_json, now_seconds) catch |err| {
            std.log.err("event=lazer_multiplayer_room_restore_failed room_id={d} error={t}", .{ checkpoint.room_id, err });
            continue;
        };
        const room = restored orelse continue;
        if (room.id != checkpoint.room_id) {
            room.deinit(self.allocator);
            self.allocator.destroy(room);
            std.log.err("event=lazer_multiplayer_room_restore_failed room_id={d} error=id_mismatch", .{checkpoint.room_id});
            continue;
        }
        if (roomHasEnded(room, now_seconds)) {
            try self.applyRoomCountryVisibility(room);
            room.ended = true;
            self.archiveRoom(room);
            continue;
        }
        const slot = self.roomSlotLocked() orelse {
            room.deinit(self.allocator);
            self.allocator.destroy(room);
            return error.MultiplayerRoomLimit;
        };
        self.hydrateRoom(room) catch |err| {
            room.deinit(self.allocator);
            self.allocator.destroy(room);
            // Keep the hidden checkpoint intact. A transient database or
            // beatmap hydration failure must not prevent the server from
            // starting, and a later restart can retry the same snapshot.
            std.log.warn("event=lazer_multiplayer_room_restore_hydration_failed room_id={d} error={t}", .{ checkpoint.room_id, err });
            continue;
        };
        try self.applyRoomCountryVisibility(room);
        store.deleteLazerMultiplayerRoomCheckpoint(room.id) catch |err| {
            room.deinit(self.allocator);
            self.allocator.destroy(room);
            return err;
        };
        self.rooms[slot] = room;
        std.log.info("event=lazer_multiplayer_room_restored room_id={d} participants={d} scores={d}", .{ room.id, room.participant_count, room.scores.items.len });
    }
}

pub fn saveRoomSnapshot(self: *Manager, room: *Room, persistence: RoomPersistence) !void {
    const store = self.store orelse return error.StoreUnavailable;
    var room_output: std.Io.Writer.Allocating = .init(self.allocator);
    defer room_output.deinit();
    try writeRoomJson(&room_output.writer, room, 0, std.Io.Clock.real.now(self.io).toSeconds(), persistence);
    var leaderboard_output: std.Io.Writer.Allocating = .init(self.allocator);
    defer leaderboard_output.deinit();
    try writeRoomLeaderboardJson(self.allocator, &leaderboard_output.writer, room, 0);
    var participants_output: std.Io.Writer.Allocating = .init(self.allocator);
    defer participants_output.deinit();
    try participants_output.writer.writeByte('[');
    for (room.participants[0..room.participant_count], 0..) |entry, index| if (entry) |participant| {
        if (index != 0) try participants_output.writer.writeByte(',');
        try participants_output.writer.print("{d}", .{participant.id});
    };
    try participants_output.writer.writeByte(']');
    const owner_id = if (room.participant_count != 0) room.participants[0].?.id else room.host_id;
    try store.saveLazerMultiplayerRoomArchive(room.id, owner_id, roomCategory(room), room_output.written(), leaderboard_output.written(), participants_output.written());
}

pub fn queuePendingArchive(self: *Manager, room: *Room) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.store == null or self.shutting_down) return false;
    for (self.pending_archives) |entry| if (entry) |pending| if (pending == room) return true;
    for (&self.pending_archives) |*entry| if (entry.* == null) {
        entry.* = room;
        return true;
    };
    std.log.err("event=lazer_multiplayer_archive_retry_capacity_exhausted room_id={d}", .{room.id});
    return false;
}

pub fn removePendingArchive(self: *Manager, room: *Room) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (&self.pending_archives) |*entry| if (entry.* == room) {
        entry.* = null;
        return;
    };
}

pub fn discardRoom(self: *Manager, room: *Room) void {
    room.deinit(self.allocator);
    self.allocator.destroy(room);
}

pub fn archiveRoomUnderGate(self: *Manager, room: *Room) void {
    const retained = self.queuePendingArchive(room);
    room.ended = true;
    self.persistRankedResult(room) catch |err| {
        std.log.err("event=lazer_ranked_rating_archive_retry_failed room_id={d} error={t}", .{ room.id, err });
        if (!retained) self.discardRoom(room);
        return;
    };
    self.saveRoomSnapshot(room, .archive) catch |err| {
        std.log.warn("event=lazer_multiplayer_room_archive_failed room_id={d} error={t}", .{ room.id, err });
        if (!retained) self.discardRoom(room);
        return;
    };
    std.log.info("event=lazer_multiplayer_room_archived room_id={d} participants={d} scores={d}", .{ room.id, room.participant_count, room.scores.items.len });
    if (retained) self.removePendingArchive(room);
    self.discardRoom(room);
}

pub fn archiveRoom(self: *Manager, room: *Room) void {
    self.archive_mutex.lockUncancelable(self.io);
    defer self.archive_mutex.unlock(self.io);
    self.archiveRoomUnderGate(room);
}

pub fn checkpointPlaylistRoom(self: *Manager, room: *Room) void {
    defer {
        room.deinit(self.allocator);
        self.allocator.destroy(room);
    }
    self.saveRoomSnapshot(room, .checkpoint) catch |err| {
        std.log.err("event=lazer_multiplayer_room_checkpoint_failed room_id={d} error={t}", .{ room.id, err });
        return;
    };
    std.log.info("event=lazer_multiplayer_room_checkpointed room_id={d} participants={d} scores={d}", .{ room.id, room.participant_count, room.scores.items.len });
}

pub fn archiveExpiredRooms(self: *Manager, now_seconds: i64) usize {
    var mutation = self.beginMutation() catch return 0;
    defer mutation.deinit();
    self.archive_mutex.lockUncancelable(self.io);
    defer self.archive_mutex.unlock(self.io);
    var expired: [max_rooms + max_pending_archives]*Room = undefined;
    var expired_count: usize = 0;
    self.mutex.lockUncancelable(self.io);
    if (!self.mutationAllowedLocked()) {
        self.mutex.unlock(self.io);
        return 0;
    }
    for (&self.rooms) |*entry| if (entry.*) |room| {
        if (!room.ended and (room.ends_at <= 0 or now_seconds < room.ends_at)) continue;
        entry.* = null;
        room.ended = true;
        for (self.connections.items) |connection| {
            if (connection.room_id == room.id) connection.room_id = null;
        }
        expired[expired_count] = room;
        expired_count += 1;
    };
    for (self.pending_archives) |entry| if (entry) |room| {
        expired[expired_count] = room;
        expired_count += 1;
    };
    self.mutex.unlock(self.io);
    for (expired[0..expired_count]) |room| self.archiveRoomUnderGate(room);
    return expired_count;
}
