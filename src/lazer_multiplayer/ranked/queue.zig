const std = @import("std");
const max_rooms = @import("../../lazer_multiplayer.zig").max_rooms;
const max_connections = @import("../../lazer_multiplayer.zig").max_connections;
const ranked_player_count = @import("../../lazer_multiplayer.zig").ranked_player_count;
const ranked_hand_size = @import("../../lazer_multiplayer.zig").ranked_hand_size;
const max_ranked_cards = @import("../../lazer_multiplayer.zig").max_ranked_cards;
const pending_match_timeout_seconds = @import("../../lazer_multiplayer.zig").pending_match_timeout_seconds;
const eventNoArgsOwned = @import("../../lazer_multiplayer.zig").eventNoArgsOwned;
const PlaylistItem = @import("../../lazer_multiplayer.zig").PlaylistItem;
const RankedCard = @import("../../lazer_multiplayer.zig").RankedCard;
const Room = @import("../rooms/model.zig").Room;
const PendingMatch = @import("../../lazer_multiplayer.zig").PendingMatch;
const Connection = @import("../transport/model.zig").Connection;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const rankedDrawCard = @import("state.zig").rankedDrawCard;
const eventQueueStatusOwned = @import("../transport/events.zig").eventQueueStatusOwned;
const eventMatchmakingInvitationOwned = @import("../transport/events.zig").eventMatchmakingInvitationOwned;
const eventMatchmakingRoomReadyOwned = @import("../transport/events.zig").eventMatchmakingRoomReadyOwned;
const sendRecipients = @import("../transport/connections.zig").sendRecipients;
const releaseRecipients = @import("../transport/connections.zig").releaseRecipients;

pub fn expirePendingMatches(self: *Manager, now_seconds: i64) usize {
    var mutation = self.beginMutation() catch return 0;
    defer mutation.deinit();
    var targets: [max_connections]*Connection = undefined;
    var target_count: usize = 0;
    var pools: [max_rooms]i32 = undefined;
    var pool_count: usize = 0;
    var expired_count: usize = 0;
    self.mutex.lockUncancelable(self.io);
    if (!self.mutationAllowedLocked()) {
        self.mutex.unlock(self.io);
        return 0;
    }
    for (&self.pending_matches) |*entry| if (entry.*) |pending| {
        if (now_seconds < pending.created_at or now_seconds - pending.created_at < pending_match_timeout_seconds) continue;
        for (pending.users, 0..) |user_id, index| {
            if (!pending.joined[index]) continue;
            const connection = self.connectionByUserLocked(user_id) orelse continue;
            if (connection.pending_match_id != pending.id) continue;
            connection.pending_match_id = null;
            connection.queue_pool_id = null;
            connection.retain();
            targets[target_count] = connection;
            target_count += 1;
        }
        if (std.mem.indexOfScalar(i32, pools[0..pool_count], pending.pool_id) == null) {
            pools[pool_count] = pending.pool_id;
            pool_count += 1;
        }
        entry.* = null;
        expired_count += 1;
    };
    self.mutex.unlock(self.io);
    defer releaseRecipients(targets[0..target_count]);
    const left = eventNoArgsOwned(self.allocator, "MatchmakingQueueLeft") catch null;
    defer if (left) |frame| self.allocator.free(frame);
    if (left) |frame| sendRecipients(targets[0..target_count], frame);
    for (pools[0..pool_count]) |pool_id| self.publishLobbyStatus(pool_id) catch {};
    return expired_count;
}

pub fn pendingMatchByIdLocked(self: *Manager, match_id: u32) ?*PendingMatch {
    for (&self.pending_matches) |*entry| if (entry.*) |*pending| if (pending.id == match_id) return pending;
    return null;
}

pub fn pendingMatchSlotLocked(self: *Manager) ?usize {
    for (self.pending_matches, 0..) |entry, index| if (entry == null) return index;
    return null;
}

pub fn pendingDuelByIdLocked(self: *Manager, duel_id: []const u8) ?*PendingMatch {
    for (&self.pending_matches) |*entry| if (entry.*) |*pending| {
        if (pending.is_duel and std.mem.eql(u8, pending.duel_id.slice(), duel_id)) return pending;
    };
    return null;
}

pub fn clearPendingMatchLocked(self: *Manager, match_id: u32) void {
    for (&self.pending_matches) |*entry| if (entry.*) |pending| if (pending.id == match_id) {
        entry.* = null;
        return;
    };
}

pub fn poolMode(pool_id: i32) ?u8 {
    if (pool_id >= 1 and pool_id <= 4) return @intCast(pool_id - 1);
    if (pool_id >= 101 and pool_id <= 104) return @intCast(pool_id - 101);
    return null;
}

pub fn poolType(pool_id: i32) ?u8 {
    if (pool_id >= 1 and pool_id <= 4) return 0;
    if (pool_id >= 101 and pool_id <= 104) return 1;
    return null;
}

pub fn joinMatchmakingQueue(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, pool_id: i32) !void {
    const mode = poolMode(pool_id) orelse return error.InvalidMatchmakingPool;
    const pool_type = poolType(pool_id) orelse return error.InvalidMatchmakingPool;
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
    var peer: ?*Connection = null;
    self.mutex.lockUncancelable(self.io);
    if (connection.room_id != null or connection.queue_pool_id != null or connection.pending_match_id != null) {
        self.mutex.unlock(self.io);
        return error.AlreadyInMatchmakingQueue;
    }
    if (self.matchmaking_map_counts[mode] == 0) {
        self.mutex.unlock(self.io);
        return error.MatchmakingPoolUnavailable;
    }
    connection.queue_pool_id = pool_id;
    for (self.connections.items) |candidate| {
        if (candidate == connection or candidate.user_id == connection.user_id or !candidate.alive.load(.acquire) or candidate.room_id != null or candidate.queue_pool_id != pool_id or candidate.pending_match_id != null) continue;
        peer = candidate;
        break;
    }
    if (peer) |matched| {
        const slot = self.pendingMatchSlotLocked() orelse {
            self.mutex.unlock(self.io);
            return error.MatchmakingGroupLimit;
        };
        const match_id = self.next_pending_match_id;
        self.next_pending_match_id +%= 1;
        if (self.next_pending_match_id == 0) self.next_pending_match_id = 1;
        self.pending_matches[slot] = .{
            .id = match_id,
            .pool_id = pool_id,
            .users = .{ matched.user_id, connection.user_id },
            .created_at = std.Io.Clock.real.now(self.io).toSeconds(),
        };
        matched.pending_match_id = match_id;
        connection.pending_match_id = match_id;
        matched.retain();
    }
    self.mutex.unlock(self.io);
    defer if (peer) |matched| matched.release();
    connection.send(joined);
    connection.send(searching);
    if (peer) |matched| {
        matched.send(invited_legacy);
        connection.send(invited_legacy);
        matched.send(invited);
        connection.send(invited);
        matched.send(found);
        connection.send(found);
        std.log.info("event=lazer_matchmaking_group_formed pool_id={d} users={d},{d}", .{ pool_id, matched.user_id, connection.user_id });
    }
    try self.finishVoid(connection, invocation_id);
    try self.publishLobbyStatus(pool_id);
}

pub fn leaveMatchmakingQueue(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, notify: bool) !void {
    const left = try eventNoArgsOwned(self.allocator, "MatchmakingQueueLeft");
    defer self.allocator.free(left);
    const searching = try eventQueueStatusOwned(self.allocator, 0);
    defer self.allocator.free(searching);
    var peer: ?*Connection = null;
    var peer_left = false;
    var pool_id: ?i32 = null;
    var was_queued = false;
    self.mutex.lockUncancelable(self.io);
    pool_id = connection.queue_pool_id;
    was_queued = pool_id != null or connection.pending_match_id != null;
    if (connection.pending_match_id) |match_id| {
        if (self.pendingMatchByIdLocked(match_id)) |pending| {
            pool_id = pending.pool_id;
            const index = pending.userIndex(connection.user_id) orelse 0;
            const peer_index = 1 - index;
            if (pending.joined[peer_index]) {
                const peer_id = pending.users[peer_index];
                if (self.connectionByUserLocked(peer_id)) |matched| {
                    matched.pending_match_id = null;
                    matched.queue_pool_id = if (pending.is_duel) null else pending.pool_id;
                    matched.retain();
                    peer = matched;
                    peer_left = pending.is_duel;
                }
            }
        }
        self.clearPendingMatchLocked(match_id);
    }
    connection.pending_match_id = null;
    connection.queue_pool_id = null;
    self.mutex.unlock(self.io);
    defer if (peer) |matched| matched.release();
    if (notify and was_queued) connection.send(left);
    if (peer) |matched| matched.send(if (peer_left) left else searching);
    try self.finishVoid(connection, invocation_id);
    if (pool_id) |pool| try self.publishLobbyStatus(pool);
}

pub fn declineMatchmakingInvitation(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
    if (connection.pending_match_id == null) return error.NoPendingMatchmakingInvitation;
    return self.leaveMatchmakingQueue(connection, invocation_id, true);
}

pub fn createMatchmakingRoomLocked(self: *Manager, pending: PendingMatch, password: []const u8) !*Room {
    const mode = poolMode(pending.pool_id) orelse return error.InvalidMatchmakingPool;
    const pool_type = poolType(pending.pool_id) orelse return error.InvalidMatchmakingPool;
    const map_count = self.matchmaking_map_counts[mode];
    if (map_count == 0) return error.MatchmakingPoolUnavailable;
    const room = try self.allocator.create(Room);
    errdefer self.allocator.destroy(room);
    room.* = .{
        .id = self.next_room_id,
        .settings = .{},
        .host_id = 3,
        .host_country = .{ 'I', 'S' },
        .allowed_user_count = pending.users.len,
        .matchmaking = if (pool_type == 0) .{} else null,
        .ranked_play = if (pool_type == 1) .{} else null,
    };
    self.next_room_id += 1;
    try room.host_name.set("kai");
    const mode_names = [_][]const u8{ "osu!", "osu!taiko", "osu!catch", "osu!mania" };
    var name_buf: [96]u8 = undefined;
    const room_name = try std.fmt.bufPrint(&name_buf, "zigcho {s} - {s}", .{ if (pool_type == 0) "quick play" else "ranked play", mode_names[mode] });
    try room.settings.name.set(room_name);
    try room.settings.password.set(password);
    room.settings.match_type = if (pool_type == 0) 3 else 4;
    room.settings.queue_mode = 0;
    room.settings.max_participants = pending.users.len;
    room.settings.auto_start.bytes[0] = 0;
    room.settings.auto_start.len = 1;
    room.allowed_users[0] = pending.users[0];
    room.allowed_users[1] = pending.users[1];
    for (pending.users, 0..) |user_id, index| {
        if (pool_type == 0) {
            room.matchmaking.?.users[index] = .{ .id = user_id };
            room.matchmaking.?.user_count += 1;
        } else {
            const rating = if (self.store) |store| (try store.lazerRankedRating(user_id, mode)).rating else @as(i32, 1500);
            room.ranked_play.?.users[index] = .{ .id = user_id, .rating = rating, .rating_after = rating };
            room.ranked_play.?.user_count += 1;
        }
    }
    for (0..map_count) |index| {
        const map = self.matchmaking_maps[mode][index].?;
        var item: PlaylistItem = .{
            .id = @intCast(index + 1),
            .owner_id = 3,
            .beatmap_id = map.id,
            .ruleset_id = map.mode,
            .order = @intCast(index),
            .star_rating = map.stars,
        };
        try item.checksum.set(&map.md5);
        try self.hydratePlaylistItem(&item);
        item.required_mods.bytes[0] = 0x90;
        item.required_mods.len = 1;
        item.allowed_mods.bytes[0] = 0x90;
        item.allowed_mods.len = 1;
        item.played_at.bytes[0] = 0xc0;
        item.played_at.len = 1;
        room.playlist[index] = item;
        room.playlist_count += 1;
    }
    room.settings.playlist_item_id = room.playlist[0].?.id;
    if (room.ranked_play) |*ranked| {
        ranked.active_user_id = pending.users[0];
        var star_total: f64 = 0;
        for (0..map_count) |index| star_total += room.playlist[index].?.star_rating;
        ranked.star_rating = star_total / @as(f64, @floatFromInt(map_count));
        const card_count = @min(max_ranked_cards, @max(ranked_hand_size * ranked_player_count + ranked_player_count, map_count * 2));
        for (0..card_count) |index| {
            var card: RankedCard = .{ .playlist_item_id = room.playlist[index % map_count].?.id };
            var guid_buf: [64]u8 = undefined;
            const room_bits: u32 = @truncate(@as(u64, @intCast(room.id)));
            const guid = try std.fmt.bufPrint(&guid_buf, "{x:0>8}-0000-4000-8000-{x:0>12}", .{ room_bits, @as(u64, @intCast(index + 1)) });
            try card.id.set(guid);
            ranked.deck[index] = card;
            ranked.deck_count += 1;
        }
        for (0..ranked_player_count) |user_index| for (0..ranked_hand_size) |_| {
            _ = rankedDrawCard(ranked, user_index);
        };
    }
    return room;
}

pub fn acceptMatchmakingInvitation(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
    var random: [16]u8 = undefined;
    try self.io.randomSecure(&random);
    const password = std.fmt.bytesToHex(random, .lower);
    const joining = try eventQueueStatusOwned(self.allocator, 2);
    defer self.allocator.free(joining);
    var ready: [2]*Connection = undefined;
    var ready_count: usize = 0;
    var room_id: ?i64 = null;
    var pool_id: ?i32 = null;
    self.mutex.lockUncancelable(self.io);
    const match_id = connection.pending_match_id orelse {
        self.mutex.unlock(self.io);
        return error.NoPendingMatchmakingInvitation;
    };
    const pending = self.pendingMatchByIdLocked(match_id) orelse {
        connection.pending_match_id = null;
        self.mutex.unlock(self.io);
        return error.NoPendingMatchmakingInvitation;
    };
    const user_index = pending.userIndex(connection.user_id) orelse {
        self.mutex.unlock(self.io);
        return error.NoPendingMatchmakingInvitation;
    };
    pending.accepted[user_index] = true;
    pool_id = pending.pool_id;
    if (pending.accepted[0] and pending.accepted[1]) {
        var matched_connections: [2]*Connection = undefined;
        for (pending.users, 0..) |user_id, index| {
            matched_connections[index] = self.connectionByUserLocked(user_id) orelse {
                pending.accepted[user_index] = false;
                self.mutex.unlock(self.io);
                return error.MatchmakingPlayerUnavailable;
            };
        }
        const room_slot = self.roomSlotLocked() orelse {
            pending.accepted[user_index] = false;
            self.mutex.unlock(self.io);
            return error.MultiplayerRoomLimit;
        };
        const room = self.createMatchmakingRoomLocked(pending.*, &password) catch |err| {
            pending.accepted[user_index] = false;
            self.mutex.unlock(self.io);
            return err;
        };
        self.rooms[room_slot] = room;
        room_id = room.id;
        for (matched_connections) |matched| {
            matched.pending_match_id = null;
            matched.queue_pool_id = null;
            matched.retain();
            ready[ready_count] = matched;
            ready_count += 1;
        }
        self.clearPendingMatchLocked(match_id);
    }
    self.mutex.unlock(self.io);
    defer releaseRecipients(ready[0..ready_count]);
    connection.send(joining);
    if (room_id) |created_room_id| {
        const event = try eventMatchmakingRoomReadyOwned(self.allocator, created_room_id, &password);
        defer self.allocator.free(event);
        sendRecipients(ready[0..ready_count], event);
        std.log.info("event=lazer_matchmaking_room_ready room_id={d} players={d}", .{ created_room_id, ready_count });
    }
    try self.finishVoid(connection, invocation_id);
    if (pool_id) |pool| try self.publishLobbyStatus(pool);
}
