const std = @import("std");
const storage = @import("../../runtime_storage.zig");
const max_connections = @import("../../lazer_multiplayer.zig").max_connections;
const max_matchmaking_maps = @import("../../lazer_multiplayer.zig").max_matchmaking_maps;
const completionEmptyObjectOwned = @import("../../lazer_multiplayer.zig").completionEmptyObjectOwned;
const Connection = @import("../transport/model.zig").Connection;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const completionMatchmakingPoolsOwned = @import("../transport/events.zig").completionMatchmakingPoolsOwned;
const eventLobbyStatusOwned = @import("../transport/events.zig").eventLobbyStatusOwned;
const poolMode = @import("queue.zig").poolMode;
const sendRecipients = @import("../transport/connections.zig").sendRecipients;
const releaseRecipients = @import("../transport/connections.zig").releaseRecipients;

pub fn refreshMatchmakingMaps(self: *Manager) !void {
    const store = self.store orelse return error.MatchmakingStoreUnavailable;
    var loaded: [4][]storage.Store.MatchmakingBeatmap = undefined;
    var loaded_count: usize = 0;
    defer for (loaded[0..loaded_count]) |maps| self.allocator.free(maps);
    for (0..4) |mode| {
        loaded[mode] = try store.matchmakingBeatmaps(self.allocator, @intCast(mode), max_matchmaking_maps);
        loaded_count += 1;
    }
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (0..4) |mode| {
        self.matchmaking_maps[mode] = [_]?storage.Store.MatchmakingBeatmap{null} ** max_matchmaking_maps;
        self.matchmaking_map_counts[mode] = loaded[mode].len;
        for (loaded[mode], 0..) |map, index| self.matchmaking_maps[mode][index] = map;
    }
}

pub fn setMatchmakingMaps(self: *Manager, mode: u8, maps: []const storage.Store.MatchmakingBeatmap) !void {
    if (mode > 3 or maps.len == 0 or maps.len > max_matchmaking_maps) return error.InvalidMatchmakingPool;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.matchmaking_maps[mode] = [_]?storage.Store.MatchmakingBeatmap{null} ** max_matchmaking_maps;
    self.matchmaking_map_counts[mode] = maps.len;
    for (maps, 0..) |map, index| {
        if (map.mode != mode or map.id <= 0) return error.InvalidMatchmakingBeatmap;
        self.matchmaking_maps[mode][index] = map;
    }
}

pub fn getMatchmakingPools(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, pool_type: u8) !void {
    const id = invocation_id orelse return error.MissingInvocationId;
    if (pool_type > 1) return error.InvalidMatchmakingPool;
    if (self.store != null) self.refreshMatchmakingMaps() catch |err| {
        std.log.warn("event=lazer_matchmaking_pool_refresh_failed error={t}", .{err});
    };
    var available: [4]bool = [_]bool{false} ** 4;
    self.mutex.lockUncancelable(self.io);
    for (0..4) |mode| available[mode] = self.matchmaking_map_counts[mode] != 0;
    self.mutex.unlock(self.io);
    const frame = try completionMatchmakingPoolsOwned(self.allocator, id, pool_type, available);
    defer self.allocator.free(frame);
    connection.send(frame);
}

pub fn joinMatchmakingLobby(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, pool_id: i32) !void {
    const id = invocation_id orelse return error.MissingInvocationId;
    const mode = poolMode(pool_id) orelse return error.InvalidMatchmakingPool;
    self.mutex.lockUncancelable(self.io);
    if (self.matchmaking_map_counts[mode] == 0) {
        self.mutex.unlock(self.io);
        return error.MatchmakingPoolUnavailable;
    }
    connection.lobby_pool_id = pool_id;
    self.mutex.unlock(self.io);
    const response = try completionEmptyObjectOwned(self.allocator, id);
    defer self.allocator.free(response);
    connection.send(response);
    try self.publishLobbyStatus(pool_id);
}

pub fn leaveMatchmakingLobby(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
    self.mutex.lockUncancelable(self.io);
    connection.lobby_pool_id = null;
    self.mutex.unlock(self.io);
    try self.finishVoid(connection, invocation_id);
}

pub fn publishLobbyStatus(self: *Manager, pool_id: i32) !void {
    var recipients: [max_connections]*Connection = undefined;
    var recipient_count: usize = 0;
    var users: [max_connections]i32 = undefined;
    var user_count: usize = 0;
    self.mutex.lockUncancelable(self.io);
    for (self.connections.items) |candidate| {
        if (!candidate.alive.load(.acquire)) continue;
        if (candidate.lobby_pool_id == pool_id and recipient_count < recipients.len) {
            candidate.retain();
            recipients[recipient_count] = candidate;
            recipient_count += 1;
        }
        if (candidate.queue_pool_id == pool_id and user_count < users.len and std.mem.indexOfScalar(i32, users[0..user_count], candidate.user_id) == null) {
            users[user_count] = candidate.user_id;
            user_count += 1;
        }
    }
    self.mutex.unlock(self.io);
    defer releaseRecipients(recipients[0..recipient_count]);
    const frame = try eventLobbyStatusOwned(self.allocator, users[0..user_count]);
    defer self.allocator.free(frame);
    sendRecipients(recipients[0..recipient_count], frame);
}
