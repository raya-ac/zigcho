const std = @import("std");
const domain = @import("../../domain.zig");
const publicCountry = @import("../rooms/state.zig").publicCountry;
const max_connections = @import("../../lazer_multiplayer.zig").max_connections;
const ranked_stage = @import("../../lazer_multiplayer.zig").ranked_stage;
const eventNoArgsOwned = @import("../../lazer_multiplayer.zig").eventNoArgsOwned;
const eventIntegersOwned = @import("../../lazer_multiplayer.zig").eventIntegersOwned;
const RoomUser = @import("../../lazer_multiplayer.zig").RoomUser;
const Room = @import("../rooms/model.zig").Room;
const Connection = @import("model.zig").Connection;
const DisconnectEffects = @import("model.zig").DisconnectEffects;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const rankedWinner = @import("../ranked/state.zig").rankedWinner;
const eventQueueStatusOwned = @import("events.zig").eventQueueStatusOwned;
const eventMatchStateOwned = @import("events.zig").eventMatchStateOwned;
const eventUserOwned = @import("events.zig").eventUserOwned;
const Mutation = @import("../lifecycle.zig").Mutation;

pub fn connectionByUserLocked(self: *Manager, user_id: i32) ?*Connection {
    var found: ?*Connection = null;
    for (self.connections.items) |connection| {
        if (connection.alive.load(.acquire) and connection.user_id == user_id) found = connection;
    }
    return found;
}

pub fn disconnectUser(self: *Manager, user_id: i32) bool {
    var mutation_optional: ?Mutation = self.beginMutation() catch null;
    defer if (mutation_optional) |*mutation| mutation.deinit();
    var targets: [max_connections]*Connection = undefined;
    var count: usize = 0;
    self.mutex.lockUncancelable(self.io);
    for (self.connections.items) |connection| {
        if (!connection.alive.load(.acquire) or connection.user_id != user_id or count == targets.len) continue;
        connection.retain();
        targets[count] = connection;
        count += 1;
    }
    self.mutex.unlock(self.io);
    const disconnect_frame = eventNoArgsOwned(self.allocator, "DisconnectRequested") catch null;
    defer if (disconnect_frame) |frame| self.allocator.free(frame);
    var disconnected = false;
    for (targets[0..count]) |connection| {
        var effects: DisconnectEffects = .{};
        connection.invocation_mutex.lockUncancelable(self.io);
        self.mutex.lockUncancelable(self.io);
        const still_current = std.mem.indexOfScalar(*Connection, self.connections.items, connection) != null and
            connection.alive.load(.acquire) and connection.user_id == user_id;
        if (still_current) {
            // Wait for this identity's final invocation, close the gate,
            // and detach every room/queue/list membership before takeover
            // returns. A frame parsed concurrently will fail its second
            // accepting_invocations check when the gate is released.
            connection.accepting_invocations.store(false, .release);
            if (self.quiescing)
                self.detachConnectionForDrainLocked(connection)
            else
                self.detachConnectionLocked(connection, &effects);
            disconnected = true;
        }
        self.mutex.unlock(self.io);
        connection.invocation_mutex.unlock(self.io);
        if (still_current) {
            if (disconnect_frame) |frame| connection.send(frame);
            connection.close();
            self.finishDisconnect(&effects);
        }
        connection.release();
    }
    return disconnected;
}

pub fn recipientsLocked(self: *Manager, room_id: i64, exclude: ?*Connection, output: *[max_connections]*Connection) usize {
    var count: usize = 0;
    for (self.connections.items) |connection| {
        if (!connection.alive.load(.acquire) or connection == exclude or connection.room_id != room_id) continue;
        if (count == output.len) break;
        connection.retain();
        output[count] = connection;
        count += 1;
    }
    return count;
}

pub fn sendRecipients(recipients: []const *Connection, frame: []const u8) void {
    for (recipients) |connection| connection.send(frame);
}

pub fn releaseRecipients(recipients: []const *Connection) void {
    for (recipients) |connection| connection.release();
}

pub fn connect(self: *Manager, user: domain.User, socket: *std.http.Server.WebSocket) !*Connection {
    if (!self.isEnabled()) {
        self.mutex.lockUncancelable(self.io);
        const terminal = self.shutting_down;
        self.mutex.unlock(self.io);
        return if (terminal) error.ServerShuttingDown else error.MultiplayerDisabled;
    }
    if (user.name.len == 0 or user.name.len > 64) return error.InvalidMultiplayerUser;
    const connection = try self.allocator.create(Connection);
    errdefer self.allocator.destroy(connection);
    connection.* = .{
        .allocator = self.allocator,
        .user_id = user.id,
        .user_country = publicCountry(user),
        .io = self.io,
        .socket = socket,
    };
    try connection.user_name.set(user.name);
    while (true) {
        var replaced: ?*Connection = null;
        self.mutex.lockUncancelable(self.io);
        if (self.shutting_down or !self.isEnabled()) {
            self.mutex.unlock(self.io);
            return if (self.shutting_down) error.ServerShuttingDown else error.MultiplayerDisabled;
        }
        for (self.connections.items) |existing| {
            if (!existing.alive.load(.acquire) or existing.user_id != user.id) continue;
            existing.retain();
            replaced = existing;
            break;
        }
        if (replaced == null) {
            if (self.connections.items.len >= max_connections) {
                self.mutex.unlock(self.io);
                return error.MultiplayerConnectionLimit;
            }
            self.connections.append(self.allocator, connection) catch |err| {
                self.mutex.unlock(self.io);
                return err;
            };
            self.mutex.unlock(self.io);
            std.log.info("event=lazer_multiplayer_connected user_id={d}", .{user.id});
            return connection;
        }
        self.mutex.unlock(self.io);

        const existing = replaced.?;
        // Wait only for this identity's final invocation boundary. Other
        // users and rooms continue independently, and no socket write is
        // performed while this gate is held.
        existing.invocation_mutex.lockUncancelable(self.io);
        self.mutex.lockUncancelable(self.io);
        const index = std.mem.indexOfScalar(*Connection, self.connections.items, existing);
        if (self.shutting_down or self.quiescing or !self.isEnabled()) {
            const terminal = self.shutting_down;
            self.mutex.unlock(self.io);
            existing.invocation_mutex.unlock(self.io);
            existing.release();
            return if (terminal) error.ServerShuttingDown else error.MultiplayerDisabled;
        }
        if (index == null or !existing.alive.load(.acquire) or existing.user_id != user.id) {
            self.mutex.unlock(self.io);
            existing.invocation_mutex.unlock(self.io);
            existing.release();
            continue;
        }
        existing.accepting_invocations.store(false, .release);
        connection.room_id = existing.room_id;
        connection.lobby_pool_id = existing.lobby_pool_id;
        connection.queue_pool_id = existing.queue_pool_id;
        connection.pending_match_id = existing.pending_match_id;
        existing.room_id = null;
        existing.lobby_pool_id = null;
        existing.queue_pool_id = null;
        existing.pending_match_id = null;
        self.connections.items[index.?] = connection;
        self.mutex.unlock(self.io);
        existing.invocation_mutex.unlock(self.io);

        if (eventNoArgsOwned(self.allocator, "DisconnectRequested")) |frame| {
            defer self.allocator.free(frame);
            existing.send(frame);
        } else |_| {}
        existing.close();
        existing.release();
        std.log.info("event=lazer_multiplayer_connection_replaced user_id={d}", .{user.id});
        std.log.info("event=lazer_multiplayer_connected user_id={d}", .{user.id});
        return connection;
    }
}

pub fn removeConnectionLocked(self: *Manager, connection: *Connection) void {
    const index = std.mem.indexOfScalar(*Connection, self.connections.items, connection) orelse return;
    _ = self.connections.swapRemove(index);
}

pub fn leaveLocked(self: *Manager, connection: *Connection, recipients: *[max_connections]*Connection, left_user: *?RoomUser, new_host: *?i32, ranked_ended: *bool, ended_room: *?*Room) usize {
    const room_id = connection.room_id orelse return 0;
    const room = self.roomByIdLocked(room_id) orelse {
        connection.room_id = null;
        return 0;
    };
    const user_index = room.userIndex(connection.user_id) orelse {
        connection.room_id = null;
        return 0;
    };
    left_user.* = room.users[user_index];
    if (room.ranked_play) |*ranked| if (ranked.stage != ranked_stage.ended) {
        if (ranked.userIndex(connection.user_id)) |ranked_user_index| ranked.users[ranked_user_index].?.life = 0;
        ranked.winning_user_id = rankedWinner(ranked);
        ranked.stage = ranked_stage.ended;
        ranked.pick_countdown = null;
        ranked_ended.* = true;
    };
    room.users[user_index] = null;
    room.user_count -= 1;
    connection.room_id = null;
    if (room.user_count == 0) {
        for (&self.rooms) |*entry| if (entry.* == room) {
            entry.* = null;
            break;
        };
        ended_room.* = room;
        return 0;
    }
    if (room.host_id == connection.user_id) {
        for (room.users) |entry| if (entry) |user| {
            room.host_id = user.id;
            room.host_name = user.name;
            room.host_country = user.country;
            new_host.* = user.id;
            break;
        };
    }
    return self.recipientsLocked(room_id, connection, recipients);
}

pub fn detachConnectionLocked(self: *Manager, connection: *Connection, effects: *DisconnectEffects) void {
    effects.queue_pool_id = connection.queue_pool_id;
    if (connection.pending_match_id) |match_id| {
        if (self.pendingMatchByIdLocked(match_id)) |pending| {
            const index = pending.userIndex(connection.user_id) orelse 0;
            const peer_index = 1 - index;
            effects.queue_pool_id = pending.pool_id;
            if (pending.joined[peer_index]) {
                const peer_id = pending.users[peer_index];
                if (self.connectionByUserLocked(peer_id)) |peer| {
                    peer.pending_match_id = null;
                    peer.queue_pool_id = if (pending.is_duel) null else pending.pool_id;
                    peer.retain();
                    effects.queue_peer = peer;
                    effects.queue_peer_left = pending.is_duel;
                }
            }
        }
        self.clearPendingMatchLocked(match_id);
    }
    connection.pending_match_id = null;
    connection.queue_pool_id = null;
    connection.lobby_pool_id = null;
    const room_id = connection.room_id;
    effects.recipient_count = self.leaveLocked(connection, &effects.recipients, &effects.left_user, &effects.new_host, &effects.ranked_ended, &effects.ended_room);
    if (effects.ranked_ended) effects.ranked_room_id = room_id;
    if (effects.ranked_ended) if (room_id) |id| if (self.roomByIdLocked(id)) |room| {
        effects.ranked_event = eventMatchStateOwned(self.allocator, room) catch null;
    };
    self.removeConnectionLocked(connection);
}

/// The active lifecycle transition owns the final room snapshot. A socket
/// read which wakes after that boundary may remove its connection object,
/// but must not erase the participant or archive the room ahead of it.
pub fn detachConnectionForDrainLocked(self: *Manager, connection: *Connection) void {
    connection.room_id = null;
    connection.lobby_pool_id = null;
    connection.queue_pool_id = null;
    connection.pending_match_id = null;
    self.removeConnectionLocked(connection);
}

pub fn finishDisconnect(self: *Manager, effects: *DisconnectEffects) void {
    defer releaseRecipients(effects.recipients[0..effects.recipient_count]);
    defer if (effects.queue_peer) |peer| peer.release();
    defer if (effects.ranked_event) |event| self.allocator.free(event);
    if (effects.ranked_ended and effects.ended_room == null) if (effects.ranked_room_id) |room_id| {
        self.persistLiveRankedResult(room_id) catch |err| std.log.err("event=lazer_ranked_rating_persist_failed room_id={d} error={t}", .{ room_id, err });
        if (self.rankedStateEventForRoom(room_id) catch null) |updated| {
            if (effects.ranked_event) |old| self.allocator.free(old);
            effects.ranked_event = updated;
        }
    };
    if (effects.ended_room) |ended| self.archiveRoom(ended);
    if (effects.queue_peer) |peer| {
        const frame_result = if (effects.queue_peer_left)
            eventNoArgsOwned(self.allocator, "MatchmakingQueueLeft")
        else
            eventQueueStatusOwned(self.allocator, 0);
        if (frame_result) |frame| {
            defer self.allocator.free(frame);
            peer.send(frame);
        } else |_| {}
    }
    if (effects.queue_pool_id) |pool| self.publishLobbyStatus(pool) catch {};
    if (effects.left_user) |user| {
        if (eventUserOwned(self.allocator, "UserLeft", user)) |frame| {
            defer self.allocator.free(frame);
            sendRecipients(effects.recipients[0..effects.recipient_count], frame);
        } else |_| {}
    }
    if (effects.ranked_event) |event| sendRecipients(effects.recipients[0..effects.recipient_count], event);
    if (effects.new_host) |host_id| {
        if (eventIntegersOwned(self.allocator, "HostChanged", &.{host_id})) |frame| {
            defer self.allocator.free(frame);
            sendRecipients(effects.recipients[0..effects.recipient_count], frame);
        } else |_| {}
    }
}

pub fn disconnect(self: *Manager, connection: *Connection) void {
    var mutation_optional: ?Mutation = self.beginMutation() catch null;
    defer if (mutation_optional) |*mutation| mutation.deinit();
    connection.close();
    var effects: DisconnectEffects = .{};
    self.mutex.lockUncancelable(self.io);
    const quiescing = self.quiescing;
    if (quiescing)
        self.detachConnectionForDrainLocked(connection)
    else
        self.detachConnectionLocked(connection, &effects);
    self.mutex.unlock(self.io);
    if (!quiescing) self.finishDisconnect(&effects);
    std.log.info("event=lazer_multiplayer_disconnected user_id={d}", .{connection.user_id});
    connection.release();
}
