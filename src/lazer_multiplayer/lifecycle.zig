const std = @import("std");
const beatmap_sync = @import("../beatmap_sync.zig");
const max_rooms = @import("../lazer_multiplayer.zig").max_rooms;
const max_pending_archives = @import("../lazer_multiplayer.zig").max_pending_archives;
const max_connections = @import("../lazer_multiplayer.zig").max_connections;
const eventNoArgsOwned = @import("../lazer_multiplayer.zig").eventNoArgsOwned;
const Room = @import("rooms/model.zig").Room;
const PendingMatch = @import("../lazer_multiplayer.zig").PendingMatch;
const Connection = @import("transport/model.zig").Connection;
const Manager = @import("../lazer_multiplayer.zig").Manager;
const roomHasEnded = @import("wire/json.zig").roomHasEnded;

pub fn init(allocator: std.mem.Allocator, io: std.Io) Manager {
    return .{ .allocator = allocator, .io = io };
}

pub fn bindBeatmapSync(self: *Manager, sync: *beatmap_sync.Sync) void {
    self.map_sync = sync;
}

pub fn isEnabled(self: *const Manager) bool {
    return self.enabled.load(.acquire);
}

/// REST and maintenance mutations are not tied to a websocket invocation
/// mutex. Track them explicitly so disable and shutdown can stop accepting
/// new work, wait for already-accepted work, and only then drain/snapshot.
pub fn beginMutation(self: *Manager) !Mutation {
    self.lifecycle_mutex.lockUncancelable(self.io);
    defer self.lifecycle_mutex.unlock(self.io);
    if (self.terminal_shutdown) return error.ServerShuttingDown;
    if (!self.isEnabled()) return error.MultiplayerDisabled;
    self.active_mutations += 1;
    return .{ .manager = self };
}

pub fn waitForMutationsLocked(self: *Manager) void {
    while (self.active_mutations != 0) self.mutations_drained.waitUncancelable(self.io, &self.lifecycle_mutex);
}

pub fn mutationAllowedLocked(self: *const Manager) bool {
    return !self.quiescing and !self.shutting_down and self.isEnabled();
}

pub fn blockedMutationErrorLocked(self: *const Manager) MutationGateError {
    return if (self.shutting_down) error.ServerShuttingDown else error.MultiplayerDisabled;
}

/// Apply the live multiplayer gate as well as the HTTP gate. The transition
/// mutex remains held across the entire drain; Condition.wait deliberately
/// releases lifecycle_mutex, so that mutex alone cannot serialize a racing
/// re-enable or terminal shutdown.
pub fn setEnabled(self: *Manager, enabled: bool) void {
    self.transition_mutex.lockUncancelable(self.io);
    defer self.transition_mutex.unlock(self.io);
    self.lifecycle_mutex.lockUncancelable(self.io);
    if (self.terminal_shutdown or self.isEnabled() == enabled) {
        self.lifecycle_mutex.unlock(self.io);
        return;
    }
    if (!enabled) {
        // Publish quiescing and the closed admission gate while holding the
        // manager mutex, so deferred socket teardown cannot detach a room
        // into an untracked gap between those two state changes.
        self.mutex.lockUncancelable(self.io);
        self.quiescing = true;
        self.enabled.store(false, .release);
        self.mutex.unlock(self.io);
    } else self.enabled.store(true, .release);
    self.lifecycle_mutex.unlock(self.io);
    if (enabled) return;
    self.drain(.disable);
}

pub fn drain(self: *Manager, mode: DrainMode) void {
    var targets: [max_connections]*Connection = undefined;
    var count: usize = 0;
    self.mutex.lockUncancelable(self.io);
    for (self.connections.items) |connection| {
        if (count == targets.len) break;
        connection.accepting_invocations.store(false, .release);
        connection.retain();
        targets[count] = connection;
        count += 1;
    }
    self.mutex.unlock(self.io);

    self.lifecycle_mutex.lockUncancelable(self.io);
    self.waitForMutationsLocked();
    self.lifecycle_mutex.unlock(self.io);

    for (targets[0..count]) |connection| {
        connection.invocation_mutex.lockUncancelable(self.io);
        connection.invocation_mutex.unlock(self.io);
    }

    const event_name = if (mode == .shutdown) "ServerShuttingDown" else "DisconnectRequested";
    const disconnect_frame = eventNoArgsOwned(self.allocator, event_name) catch null;
    defer if (disconnect_frame) |frame| self.allocator.free(frame);
    for (targets[0..count]) |connection| {
        if (connection.alive.load(.acquire)) if (disconnect_frame) |frame| connection.send(frame);
        connection.close();
    }

    var rooms: [max_rooms + max_pending_archives]*Room = undefined;
    var room_count: usize = 0;
    self.archive_mutex.lockUncancelable(self.io);
    self.mutex.lockUncancelable(self.io);
    for (&self.rooms) |*entry| if (entry.*) |room| {
        entry.* = null;
        room.ended = mode == .disable or room.settings.match_type != 0 or roomHasEnded(room, std.Io.Clock.real.now(self.io).toSeconds());
        rooms[room_count] = room;
        room_count += 1;
    };
    for (&self.pending_archives) |*entry| if (entry.*) |room| {
        entry.* = null;
        if (std.mem.indexOfScalar(*Room, rooms[0..room_count], room) == null) {
            rooms[room_count] = room;
            room_count += 1;
        }
    };
    for (targets[0..count]) |connection| {
        connection.room_id = null;
        connection.lobby_pool_id = null;
        connection.queue_pool_id = null;
        connection.pending_match_id = null;
    }
    if (mode == .disable) self.connections.clearRetainingCapacity();
    self.pending_matches = [_]?PendingMatch{null} ** max_rooms;
    self.mutex.unlock(self.io);
    for (rooms[0..room_count]) |room| {
        if (mode == .shutdown and room.settings.match_type == 0 and !room.ended)
            self.checkpointPlaylistRoom(room)
        else
            self.archiveRoomUnderGate(room);
    }
    self.archive_mutex.unlock(self.io);
    for (targets[0..count]) |connection| connection.release();

    if (mode == .disable) {
        self.mutex.lockUncancelable(self.io);
        self.quiescing = false;
        self.mutex.unlock(self.io);
    }
}

pub fn deinit(self: *Manager) void {
    self.shutdown();
    for (&self.rooms) |*entry| if (entry.*) |room| {
        room.deinit(self.allocator);
        self.allocator.destroy(room);
    };
    for (&self.pending_archives) |*entry| if (entry.*) |room| {
        room.deinit(self.allocator);
        self.allocator.destroy(room);
    };
    for (self.connections.items) |connection| connection.release();
    self.connections.deinit(self.allocator);
}

/// Tell the pinned client that this is a planned interruption and archive
/// every active room before the process gives up its sockets. This is
/// idempotent so both the server shutdown path and deinit may call it.
pub fn shutdown(self: *Manager) void {
    self.transition_mutex.lockUncancelable(self.io);
    defer self.transition_mutex.unlock(self.io);
    self.lifecycle_mutex.lockUncancelable(self.io);
    if (self.terminal_shutdown) {
        self.lifecycle_mutex.unlock(self.io);
        return;
    }
    // Allocation-failure fixtures deliberately mark the manager as already
    // shutting down so deinit only frees its in-memory ownership and does
    // not introduce best-effort serializer allocations outside the tested
    // operation. Preserve that established cleanup contract.
    self.mutex.lockUncancelable(self.io);
    const externally_quiesced = self.shutting_down;
    self.mutex.unlock(self.io);
    if (externally_quiesced) {
        self.terminal_shutdown = true;
        self.enabled.store(false, .release);
        self.lifecycle_mutex.unlock(self.io);
        return;
    }
    self.terminal_shutdown = true;
    self.mutex.lockUncancelable(self.io);
    self.quiescing = true;
    self.shutting_down = true;
    self.enabled.store(false, .release);
    self.mutex.unlock(self.io);
    self.lifecycle_mutex.unlock(self.io);
    self.drain(.shutdown);
    std.log.info("event=lazer_multiplayer_shutdown", .{});
}

pub fn nowMs(self: *const Manager) i64 {
    return std.Io.Clock.awake.now(self.io).toMilliseconds();
}

pub const Mutation = struct {
    manager: *Manager,
    active: bool = true,

    pub fn deinit(self: *Mutation) void {
        if (!self.active) return;
        const manager = self.manager;
        manager.lifecycle_mutex.lockUncancelable(manager.io);
        std.debug.assert(manager.active_mutations != 0);
        manager.active_mutations -= 1;
        if (manager.active_mutations == 0) manager.mutations_drained.broadcast(manager.io);
        manager.lifecycle_mutex.unlock(manager.io);
        self.active = false;
    }
};

pub const MutationGateError = error{ MultiplayerDisabled, ServerShuttingDown };

pub const DrainMode = enum { disable, shutdown };
