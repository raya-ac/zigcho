const std = @import("std");
const completionEmptyObjectOwned = @import("../../lazer_multiplayer.zig").completionEmptyObjectOwned;
const eventNoArgsOwned = @import("../../lazer_multiplayer.zig").eventNoArgsOwned;
const PendingMatch = @import("../../lazer_multiplayer.zig").PendingMatch;
const Connection = @import("../transport/model.zig").Connection;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const eventQueueStatusOwned = @import("../transport/events.zig").eventQueueStatusOwned;
const eventMatchmakingInvitationOwned = @import("../transport/events.zig").eventMatchmakingInvitationOwned;
const eventMatchmakingDuelIssuedOwned = @import("../transport/events.zig").eventMatchmakingDuelIssuedOwned;
const poolMode = @import("queue.zig").poolMode;
const poolType = @import("queue.zig").poolType;

pub fn issueMatchmakingDuel(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, target_user_id: i32, pool_id: i32) !void {
    const id = invocation_id orelse return error.MissingInvocationId;
    const mode = poolMode(pool_id) orelse return error.InvalidMatchmakingPool;
    const pool_type = poolType(pool_id) orelse return error.InvalidMatchmakingPool;
    if (target_user_id == connection.user_id) return error.InvalidMatchmakingDuelTarget;
    if (connection.room_id != null) return error.AlreadyInMultiplayerRoom;

    // osu!'s duel flow replaces any ordinary queue the challenger was in.
    try self.leaveMatchmakingQueue(connection, null, false);

    var random: [16]u8 = undefined;
    try self.io.randomSecure(&random);
    random[6] = (random[6] & 0x0f) | 0x40;
    random[8] = (random[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(random, .lower);
    var duel_id: [36]u8 = undefined;
    @memcpy(duel_id[0..8], hex[0..8]);
    duel_id[8] = '-';
    @memcpy(duel_id[9..13], hex[8..12]);
    duel_id[13] = '-';
    @memcpy(duel_id[14..18], hex[12..16]);
    duel_id[18] = '-';
    @memcpy(duel_id[19..23], hex[16..20]);
    duel_id[23] = '-';
    @memcpy(duel_id[24..36], hex[20..32]);

    const joined = try eventNoArgsOwned(self.allocator, "MatchmakingQueueJoined");
    defer self.allocator.free(joined);
    const searching = try eventQueueStatusOwned(self.allocator, 0);
    defer self.allocator.free(searching);
    const issued = try eventMatchmakingDuelIssuedOwned(self.allocator, &duel_id, connection.user_id, pool_id, mode, pool_type);
    defer self.allocator.free(issued);
    const response = try completionEmptyObjectOwned(self.allocator, id);
    defer self.allocator.free(response);

    var target: ?*Connection = null;
    self.mutex.lockUncancelable(self.io);
    if (connection.room_id != null or connection.queue_pool_id != null or connection.pending_match_id != null) {
        self.mutex.unlock(self.io);
        return error.AlreadyInMatchmakingQueue;
    }
    if (self.matchmaking_map_counts[mode] == 0) {
        self.mutex.unlock(self.io);
        return error.MatchmakingPoolUnavailable;
    }
    const recipient = self.connectionByUserLocked(target_user_id) orelse {
        self.mutex.unlock(self.io);
        return error.MatchmakingPlayerUnavailable;
    };
    if (recipient.room_id != null) {
        self.mutex.unlock(self.io);
        return error.MatchmakingPlayerUnavailable;
    }
    const slot = self.pendingMatchSlotLocked() orelse {
        self.mutex.unlock(self.io);
        return error.MatchmakingGroupLimit;
    };
    const match_id = self.next_pending_match_id;
    self.next_pending_match_id +%= 1;
    if (self.next_pending_match_id == 0) self.next_pending_match_id = 1;
    var pending: PendingMatch = .{
        .id = match_id,
        .pool_id = pool_id,
        .users = .{ connection.user_id, recipient.user_id },
        .joined = .{ true, false },
        .is_duel = true,
        .created_at = std.Io.Clock.real.now(self.io).toSeconds(),
    };
    pending.duel_id.set(&duel_id) catch unreachable;
    self.pending_matches[slot] = pending;
    connection.queue_pool_id = pool_id;
    connection.pending_match_id = match_id;
    recipient.retain();
    target = recipient;
    self.mutex.unlock(self.io);
    defer if (target) |recipient_connection| recipient_connection.release();

    connection.send(joined);
    connection.send(searching);
    target.?.send(issued);
    connection.send(response);
    std.log.info("event=lazer_matchmaking_duel_issued challenger_id={d} target_id={d} pool_id={d}", .{ connection.user_id, target_user_id, pool_id });
    try self.publishLobbyStatus(pool_id);
}

pub fn acceptMatchmakingDuel(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, duel_id: []const u8) !void {
    const id = invocation_id orelse return error.MissingInvocationId;
    if (duel_id.len != 36 or connection.room_id != null) return error.InvalidMatchmakingDuel;

    // Validate before removing the target from another queue. The duel may
    // have expired or been cancelled while its notification was visible.
    self.mutex.lockUncancelable(self.io);
    const initial = self.pendingDuelByIdLocked(duel_id) orelse {
        self.mutex.unlock(self.io);
        const response = try completionEmptyObjectOwned(self.allocator, id);
        defer self.allocator.free(response);
        connection.send(response);
        return;
    };
    if (initial.users[1] != connection.user_id or initial.joined[1]) {
        self.mutex.unlock(self.io);
        return error.InvalidMatchmakingDuel;
    }
    const pool_id = initial.pool_id;
    const pool_type = poolType(pool_id) orelse {
        self.mutex.unlock(self.io);
        return error.InvalidMatchmakingPool;
    };
    self.mutex.unlock(self.io);

    // Accepting a duel follows official behavior and replaces any other
    // queue membership held by the target.
    try self.leaveMatchmakingQueue(connection, null, false);

    const joined = try eventNoArgsOwned(self.allocator, "MatchmakingQueueJoined");
    defer self.allocator.free(joined);
    const searching = try eventQueueStatusOwned(self.allocator, 0);
    defer self.allocator.free(searching);
    const invited_legacy = try eventNoArgsOwned(self.allocator, "MatchmakingRoomInvited");
    defer self.allocator.free(invited_legacy);
    const invited = try eventMatchmakingInvitationOwned(self.allocator, pool_type);
    defer self.allocator.free(invited);
    const found = try eventQueueStatusOwned(self.allocator, 1);
    defer self.allocator.free(found);
    const response = try completionEmptyObjectOwned(self.allocator, id);
    defer self.allocator.free(response);

    var challenger: ?*Connection = null;
    self.mutex.lockUncancelable(self.io);
    const pending = self.pendingDuelByIdLocked(duel_id) orelse {
        self.mutex.unlock(self.io);
        connection.send(response);
        return;
    };
    if (pending.users[1] != connection.user_id or pending.joined[1] or connection.room_id != null or connection.queue_pool_id != null or connection.pending_match_id != null) {
        self.mutex.unlock(self.io);
        return error.InvalidMatchmakingDuel;
    }
    const challenger_connection = self.connectionByUserLocked(pending.users[0]) orelse {
        self.mutex.unlock(self.io);
        connection.send(response);
        return;
    };
    if (challenger_connection.pending_match_id != pending.id or challenger_connection.queue_pool_id != pending.pool_id) {
        self.mutex.unlock(self.io);
        connection.send(response);
        return;
    }
    pending.joined[1] = true;
    connection.queue_pool_id = pending.pool_id;
    connection.pending_match_id = pending.id;
    challenger_connection.retain();
    challenger = challenger_connection;
    self.mutex.unlock(self.io);
    defer if (challenger) |challenger_connection_retained| challenger_connection_retained.release();

    connection.send(joined);
    connection.send(searching);
    challenger.?.send(invited_legacy);
    connection.send(invited_legacy);
    challenger.?.send(invited);
    connection.send(invited);
    challenger.?.send(found);
    connection.send(found);
    connection.send(response);
    std.log.info("event=lazer_matchmaking_duel_accepted challenger_id={d} target_id={d} pool_id={d}", .{ challenger.?.user_id, connection.user_id, pool_id });
    try self.publishLobbyStatus(pool_id);
}
