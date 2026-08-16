const std = @import("std");
const domain = @import("domain.zig");
const storage = @import("runtime_storage.zig");

pub const max_rooms = 64;
pub const max_connections = 128;
pub const max_users = 16;
pub const max_playlist = 32;
pub const max_matchmaking_maps = 16;
pub const matchmaking_rounds = 3;
const max_hub_message = 60 * 1024;

const matchmaking_stage = struct {
    const waiting_for_clients_join: u8 = 0;
    const round_warmup: u8 = 1;
    const user_beatmap_select: u8 = 2;
    const server_beatmap_finalised: u8 = 3;
    const waiting_for_beatmap_download: u8 = 4;
    const gameplay_warmup: u8 = 5;
    const gameplay: u8 = 6;
    const results: u8 = 7;
    const ended: u8 = 8;
};

pub const RoomScorePath = struct {
    room_id: i64,
    playlist_item_id: i64,
    token_id: ?i64,
};

pub const RoomScoreContext = struct {
    beatmap_id: i32,
    ruleset_id: u8,
};

pub const RoomScoreResult = struct {
    total_score: i64,
    accuracy: f64,
    max_combo: i32,
    passed: bool,
};

fn FixedRaw(comptime capacity: usize) type {
    return struct {
        len: u16 = 0,
        bytes: [capacity]u8 = undefined,

        const Self = @This();

        fn set(self: *Self, value: []const u8) !void {
            if (value.len > self.bytes.len) return error.MultiplayerPayloadTooLarge;
            @memcpy(self.bytes[0..value.len], value);
            self.len = @intCast(value.len);
        }

        fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

const Raw64 = FixedRaw(64);
const Raw128 = FixedRaw(128);
const Raw2048 = FixedRaw(2048);
const Text64 = FixedRaw(64);
const Text128 = FixedRaw(128);

pub const MessagePackReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn byte(self: *MessagePackReader) !u8 {
        if (self.pos >= self.data.len) return error.TruncatedMessagePack;
        const value = self.data[self.pos];
        self.pos += 1;
        return value;
    }

    fn take(self: *MessagePackReader, len: usize) ![]const u8 {
        const end = std.math.add(usize, self.pos, len) catch return error.TruncatedMessagePack;
        if (end > self.data.len) return error.TruncatedMessagePack;
        const value = self.data[self.pos..end];
        self.pos = end;
        return value;
    }

    fn readUnsigned(self: *MessagePackReader, comptime T: type) !T {
        const bytes: *const [@sizeOf(T)]u8 = @ptrCast(try self.take(@sizeOf(T)));
        return std.mem.readInt(T, bytes, .big);
    }

    pub fn arrayLen(self: *MessagePackReader) !usize {
        const tag = try self.byte();
        if (tag >= 0x90 and tag <= 0x9f) return tag & 0x0f;
        return switch (tag) {
            0xdc => try self.readUnsigned(u16),
            0xdd => std.math.cast(usize, try self.readUnsigned(u32)) orelse error.MultiplayerPayloadTooLarge,
            else => error.ExpectedMessagePackArray,
        };
    }

    pub fn mapLen(self: *MessagePackReader) !usize {
        const tag = try self.byte();
        if (tag >= 0x80 and tag <= 0x8f) return tag & 0x0f;
        return switch (tag) {
            0xde => try self.readUnsigned(u16),
            0xdf => std.math.cast(usize, try self.readUnsigned(u32)) orelse error.MultiplayerPayloadTooLarge,
            else => error.ExpectedMessagePackMap,
        };
    }

    pub fn string(self: *MessagePackReader) ![]const u8 {
        const tag = try self.byte();
        const len: usize = if (tag >= 0xa0 and tag <= 0xbf)
            tag & 0x1f
        else switch (tag) {
            0xd9 => try self.byte(),
            0xda => try self.readUnsigned(u16),
            0xdb => std.math.cast(usize, try self.readUnsigned(u32)) orelse return error.MultiplayerPayloadTooLarge,
            else => return error.ExpectedMessagePackString,
        };
        return self.take(len);
    }

    pub fn integer(self: *MessagePackReader) !i64 {
        const tag = try self.byte();
        if (tag <= 0x7f) return tag;
        if (tag >= 0xe0) return @as(i8, @bitCast(tag));
        return switch (tag) {
            0xcc => try self.byte(),
            0xcd => try self.readUnsigned(u16),
            0xce => try self.readUnsigned(u32),
            0xcf => std.math.cast(i64, try self.readUnsigned(u64)) orelse error.MultiplayerIntegerOverflow,
            0xd0 => @as(i8, @bitCast(try self.byte())),
            0xd1 => @as(i16, @bitCast(try self.readUnsigned(u16))),
            0xd2 => @as(i32, @bitCast(try self.readUnsigned(u32))),
            0xd3 => @as(i64, @bitCast(try self.readUnsigned(u64))),
            else => error.ExpectedMessagePackInteger,
        };
    }

    pub fn boolean(self: *MessagePackReader) !bool {
        return switch (try self.byte()) {
            0xc2 => false,
            0xc3 => true,
            else => error.ExpectedMessagePackBoolean,
        };
    }

    pub fn nullableInteger(self: *MessagePackReader) !?i64 {
        if (self.pos >= self.data.len) return error.TruncatedMessagePack;
        if (self.data[self.pos] == 0xc0) {
            self.pos += 1;
            return null;
        }
        return try self.integer();
    }

    pub fn raw(self: *MessagePackReader) ![]const u8 {
        const start = self.pos;
        try self.skip(0);
        return self.data[start..self.pos];
    }

    pub fn skip(self: *MessagePackReader, depth: u8) !void {
        if (depth >= 16) return error.MessagePackNestingTooDeep;
        const tag = try self.byte();
        if (tag <= 0x7f or tag >= 0xe0 or tag == 0xc0 or tag == 0xc2 or tag == 0xc3) return;
        if (tag >= 0xa0 and tag <= 0xbf) {
            _ = try self.take(tag & 0x1f);
            return;
        }
        if (tag >= 0x90 and tag <= 0x9f) {
            for (0..tag & 0x0f) |_| try self.skip(depth + 1);
            return;
        }
        if (tag >= 0x80 and tag <= 0x8f) {
            for (0..(tag & 0x0f) * 2) |_| try self.skip(depth + 1);
            return;
        }
        const fixed: ?usize = switch (tag) {
            0xca, 0xce, 0xd2 => 4,
            0xcb, 0xcf, 0xd3 => 8,
            0xcc, 0xd0 => 1,
            0xcd, 0xd1 => 2,
            0xd4 => 2,
            0xd5 => 3,
            0xd6 => 5,
            0xd7 => 9,
            0xd8 => 17,
            else => null,
        };
        if (fixed) |len| {
            _ = try self.take(len);
            return;
        }
        const byte_len: ?usize = switch (tag) {
            0xc4, 0xd9 => try self.byte(),
            0xc5, 0xda => try self.readUnsigned(u16),
            0xc6, 0xdb => std.math.cast(usize, try self.readUnsigned(u32)) orelse return error.MultiplayerPayloadTooLarge,
            0xc7 => std.math.add(usize, try self.byte(), 1) catch return error.MultiplayerPayloadTooLarge,
            0xc8 => std.math.add(usize, try self.readUnsigned(u16), 1) catch return error.MultiplayerPayloadTooLarge,
            0xc9 => std.math.add(usize, std.math.cast(usize, try self.readUnsigned(u32)) orelse return error.MultiplayerPayloadTooLarge, 1) catch return error.MultiplayerPayloadTooLarge,
            else => null,
        };
        if (byte_len) |len| {
            _ = try self.take(len);
            return;
        }
        const collection_len: ?struct { len: usize, map: bool } = switch (tag) {
            0xdc => .{ .len = try self.readUnsigned(u16), .map = false },
            0xdd => .{ .len = std.math.cast(usize, try self.readUnsigned(u32)) orelse return error.MultiplayerPayloadTooLarge, .map = false },
            0xde => .{ .len = try self.readUnsigned(u16), .map = true },
            0xdf => .{ .len = std.math.cast(usize, try self.readUnsigned(u32)) orelse return error.MultiplayerPayloadTooLarge, .map = true },
            else => null,
        };
        if (collection_len) |collection| {
            const values = if (collection.map) std.math.mul(usize, collection.len, 2) catch return error.MultiplayerPayloadTooLarge else collection.len;
            for (0..values) |_| try self.skip(depth + 1);
            return;
        }
        return error.UnsupportedMessagePackValue;
    }
};

pub const MessagePackWriter = struct {
    writer: *std.Io.Writer,

    pub fn array(self: MessagePackWriter, len: usize) !void {
        if (len <= 15) return self.writer.writeByte(0x90 | @as(u8, @intCast(len)));
        if (len <= std.math.maxInt(u16)) {
            try self.writer.writeByte(0xdc);
            return self.writer.writeInt(u16, @intCast(len), .big);
        }
        try self.writer.writeByte(0xdd);
        try self.writer.writeInt(u32, @intCast(len), .big);
    }

    pub fn map(self: MessagePackWriter, len: usize) !void {
        if (len <= 15) return self.writer.writeByte(0x80 | @as(u8, @intCast(len)));
        if (len <= std.math.maxInt(u16)) {
            try self.writer.writeByte(0xde);
            return self.writer.writeInt(u16, @intCast(len), .big);
        }
        try self.writer.writeByte(0xdf);
        try self.writer.writeInt(u32, @intCast(len), .big);
    }

    pub fn string(self: MessagePackWriter, value: []const u8) !void {
        if (value.len <= 31) {
            try self.writer.writeByte(0xa0 | @as(u8, @intCast(value.len)));
        } else if (value.len <= std.math.maxInt(u8)) {
            try self.writer.writeByte(0xd9);
            try self.writer.writeByte(@intCast(value.len));
        } else if (value.len <= std.math.maxInt(u16)) {
            try self.writer.writeByte(0xda);
            try self.writer.writeInt(u16, @intCast(value.len), .big);
        } else {
            try self.writer.writeByte(0xdb);
            try self.writer.writeInt(u32, @intCast(value.len), .big);
        }
        try self.writer.writeAll(value);
    }

    pub fn integer(self: MessagePackWriter, value: i64) !void {
        if (value >= 0 and value <= 0x7f) return self.writer.writeByte(@intCast(value));
        if (value >= -32 and value < 0) return self.writer.writeByte(@bitCast(@as(i8, @intCast(value))));
        if (value >= std.math.minInt(i8) and value <= std.math.maxInt(i8)) {
            try self.writer.writeByte(0xd0);
            return self.writer.writeByte(@bitCast(@as(i8, @intCast(value))));
        }
        if (value >= std.math.minInt(i16) and value <= std.math.maxInt(i16)) {
            try self.writer.writeByte(0xd1);
            return self.writer.writeInt(i16, @intCast(value), .big);
        }
        if (value >= std.math.minInt(i32) and value <= std.math.maxInt(i32)) {
            try self.writer.writeByte(0xd2);
            return self.writer.writeInt(i32, @intCast(value), .big);
        }
        try self.writer.writeByte(0xd3);
        try self.writer.writeInt(i64, value, .big);
    }

    pub fn float64(self: MessagePackWriter, value: f64) !void {
        try self.writer.writeByte(0xcb);
        try self.writer.writeInt(u64, @bitCast(value), .big);
    }

    pub fn nil(self: MessagePackWriter) !void {
        try self.writer.writeByte(0xc0);
    }

    pub fn boolean(self: MessagePackWriter, value: bool) !void {
        try self.writer.writeByte(if (value) 0xc3 else 0xc2);
    }

    pub fn raw(self: MessagePackWriter, value: []const u8) !void {
        if (value.len == 0) return error.EmptyMessagePackValue;
        try self.writer.writeAll(value);
    }
};

const PlaylistItem = struct {
    id: i64 = 0,
    owner_id: i32 = 0,
    beatmap_id: i32 = 0,
    checksum: Text64 = .{},
    ruleset_id: u8 = 0,
    required_mods: Raw2048 = .{},
    allowed_mods: Raw2048 = .{},
    expired: bool = false,
    order: u16 = 0,
    played_at: Raw64 = .{},
    star_rating: f64 = 0,
    freestyle: bool = false,
};

const RoomUser = struct {
    id: i32,
    name: Text64 = .{},
    country: [2]u8 = .{ 'X', 'X' },
    state: u8 = 0,
    availability: Raw128 = .{},
    mods: Raw2048 = .{},
    ruleset_id: ?i32 = null,
    beatmap_id: ?i32 = null,
    voted_skip: bool = false,
    role: u8 = 0,
};

const MatchmakingRound = struct {
    round: u8,
    placement: u8 = 0,
    total_score: i64 = 0,
    accuracy: f64 = 0,
    max_combo: i32 = 0,
    passed: bool = false,
};

const MatchmakingUser = struct {
    id: i32,
    placement: ?u8 = null,
    points: i32 = 0,
    rounds: [matchmaking_rounds]?MatchmakingRound = [_]?MatchmakingRound{null} ** matchmaking_rounds,
};

const MatchmakingState = struct {
    stage: u8 = 0,
    current_round: u8 = 0,
    candidate_items: [max_users]i64 = [_]i64{0} ** max_users,
    candidate_count: usize = 0,
    candidate_item: i64 = 0,
    gameplay_item: i64 = 0,
    users: [max_users]?MatchmakingUser = [_]?MatchmakingUser{null} ** max_users,
    user_count: usize = 0,
    picks: [max_users]?i64 = [_]?i64{null} ** max_users,

    fn userIndex(self: *const MatchmakingState, user_id: i32) ?usize {
        for (self.users, 0..) |entry, index| if (entry) |user| if (user.id == user_id) return index;
        return null;
    }
};

const Settings = struct {
    name: Text128 = .{},
    playlist_item_id: i64 = 0,
    password: Text64 = .{},
    match_type: u8 = 1,
    queue_mode: u8 = 0,
    auto_start: Raw64 = .{},
    auto_skip: bool = false,
    max_participants: ?u8 = null,
};

const Room = struct {
    id: i64,
    state: u8 = 0,
    settings: Settings,
    users: [max_users]?RoomUser = [_]?RoomUser{null} ** max_users,
    user_count: usize = 0,
    host_id: i32,
    host_name: Text64 = .{},
    host_country: [2]u8 = .{ 'X', 'X' },
    playlist: [max_playlist]?PlaylistItem = [_]?PlaylistItem{null} ** max_playlist,
    playlist_count: usize = 0,
    channel_id: i32 = 4,
    matchmaking: ?MatchmakingState = null,
    allowed_users: [max_users]i32 = [_]i32{0} ** max_users,
    allowed_user_count: usize = 0,

    fn userIndex(self: *const Room, user_id: i32) ?usize {
        for (self.users, 0..) |entry, index| if (entry) |user| if (user.id == user_id) return index;
        return null;
    }

    fn itemIndex(self: *const Room, item_id: i64) ?usize {
        for (self.playlist, 0..) |entry, index| if (entry) |item| if (item.id == item_id) return index;
        return null;
    }

    fn userAllowed(self: *const Room, user_id: i32) bool {
        if (self.allowed_user_count == 0) return true;
        return std.mem.indexOfScalar(i32, self.allowed_users[0..self.allowed_user_count], user_id) != null;
    }
};

const PendingMatch = struct {
    id: u32,
    pool_id: i32,
    users: [2]i32,
    accepted: [2]bool = .{ false, false },
    created_at: i64,

    fn userIndex(self: PendingMatch, user_id: i32) ?usize {
        if (self.users[0] == user_id) return 0;
        if (self.users[1] == user_id) return 1;
        return null;
    }
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    references: std.atomic.Value(usize) = .init(1),
    user_id: i32,
    user_name: Text64 = .{},
    user_country: [2]u8,
    room_id: ?i64 = null,
    lobby_pool_id: ?i32 = null,
    queue_pool_id: ?i32 = null,
    pending_match_id: ?u32 = null,
    io: std.Io,
    write_mutex: std.Io.Mutex = .init,
    socket: ?*std.http.Server.WebSocket = null,
    alive: bool = true,

    fn retain(self: *Connection) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }

    fn release(self: *Connection) void {
        if (self.references.fetchSub(1, .release) == 1) {
            _ = self.references.load(.acquire);
            self.allocator.destroy(self);
        }
    }

    fn send(self: *Connection, frame: []const u8) void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (!self.alive) return;
        const socket = self.socket orelse return;
        socket.writeMessage(frame, .binary) catch {
            self.alive = false;
        };
    }

    fn close(self: *Connection) void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        self.alive = false;
        self.socket = null;
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: ?*storage.Store = null,
    mutex: std.Io.Mutex = .init,
    rooms: [max_rooms]?*Room = [_]?*Room{null} ** max_rooms,
    connections: std.ArrayList(*Connection) = .empty,
    matchmaking_maps: [4][max_matchmaking_maps]?storage.Store.MatchmakingBeatmap = [_][max_matchmaking_maps]?storage.Store.MatchmakingBeatmap{[_]?storage.Store.MatchmakingBeatmap{null} ** max_matchmaking_maps} ** 4,
    matchmaking_map_counts: [4]usize = [_]usize{0} ** 4,
    pending_matches: [max_rooms]?PendingMatch = [_]?PendingMatch{null} ** max_rooms,
    next_room_id: i64 = 1,
    next_pending_match_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Manager {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn bindStore(self: *Manager, store: *storage.Store) void {
        self.store = store;
    }

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

    pub fn deinit(self: *Manager) void {
        for (&self.rooms) |*entry| if (entry.*) |room| self.allocator.destroy(room);
        for (self.connections.items) |connection| connection.release();
        self.connections.deinit(self.allocator);
    }

    fn roomByIdLocked(self: *Manager, room_id: i64) ?*Room {
        for (self.rooms) |entry| if (entry) |room| if (room.id == room_id) return room;
        return null;
    }

    fn roomSlotLocked(self: *Manager) ?usize {
        for (self.rooms, 0..) |entry, index| if (entry == null) return index;
        return null;
    }

    fn connectionByUserLocked(self: *Manager, user_id: i32) ?*Connection {
        var found: ?*Connection = null;
        for (self.connections.items) |connection| {
            if (connection.alive and connection.user_id == user_id) found = connection;
        }
        return found;
    }

    fn pendingMatchByIdLocked(self: *Manager, match_id: u32) ?*PendingMatch {
        for (&self.pending_matches) |*entry| if (entry.*) |*pending| if (pending.id == match_id) return pending;
        return null;
    }

    fn pendingMatchSlotLocked(self: *Manager) ?usize {
        for (self.pending_matches, 0..) |entry, index| if (entry == null) return index;
        return null;
    }

    fn clearPendingMatchLocked(self: *Manager, match_id: u32) void {
        for (&self.pending_matches) |*entry| if (entry.*) |pending| if (pending.id == match_id) {
            entry.* = null;
            return;
        };
    }

    fn poolMode(pool_id: i32) ?u8 {
        if (pool_id < 1 or pool_id > 4) return null;
        return @intCast(pool_id - 1);
    }

    fn recipientsLocked(self: *Manager, room_id: i64, exclude: ?*Connection, output: *[max_connections]*Connection) usize {
        var count: usize = 0;
        for (self.connections.items) |connection| {
            if (!connection.alive or connection == exclude or connection.room_id != room_id) continue;
            if (count == output.len) break;
            connection.retain();
            output[count] = connection;
            count += 1;
        }
        return count;
    }

    fn sendRecipients(recipients: []const *Connection, frame: []const u8) void {
        for (recipients) |connection| connection.send(frame);
    }

    fn releaseRecipients(recipients: []const *Connection) void {
        for (recipients) |connection| connection.release();
    }

    fn connect(self: *Manager, user: domain.User, socket: *std.http.Server.WebSocket) !*Connection {
        if (user.name.len == 0 or user.name.len > 64) return error.InvalidMultiplayerUser;
        const connection = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(connection);
        connection.* = .{
            .allocator = self.allocator,
            .user_id = user.id,
            .user_country = user.country,
            .io = self.io,
            .socket = socket,
        };
        try connection.user_name.set(user.name);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.connections.items.len >= max_connections) return error.MultiplayerConnectionLimit;
        try self.connections.append(self.allocator, connection);
        return connection;
    }

    fn removeConnectionLocked(self: *Manager, connection: *Connection) void {
        const index = std.mem.indexOfScalar(*Connection, self.connections.items, connection) orelse return;
        _ = self.connections.swapRemove(index);
    }

    fn leaveLocked(self: *Manager, connection: *Connection, recipients: *[max_connections]*Connection, left_user: *?RoomUser, new_host: *?i32) usize {
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
        room.users[user_index] = null;
        room.user_count -= 1;
        connection.room_id = null;
        if (room.user_count == 0) {
            for (&self.rooms) |*entry| if (entry.* == room) {
                entry.* = null;
                break;
            };
            self.allocator.destroy(room);
            return 0;
        }
        if (room.host_id == connection.user_id) {
            for (room.users) |entry| if (entry) |user| {
                room.host_id = user.id;
                new_host.* = user.id;
                break;
            };
        }
        return self.recipientsLocked(room_id, connection, recipients);
    }

    fn disconnect(self: *Manager, connection: *Connection) void {
        connection.close();
        var recipients: [max_connections]*Connection = undefined;
        var left_user: ?RoomUser = null;
        var new_host: ?i32 = null;
        var queue_peer: ?*Connection = null;
        self.mutex.lockUncancelable(self.io);
        if (connection.pending_match_id) |match_id| {
            if (self.pendingMatchByIdLocked(match_id)) |pending| {
                const index = pending.userIndex(connection.user_id) orelse 0;
                const peer_id = pending.users[1 - index];
                if (self.connectionByUserLocked(peer_id)) |peer| {
                    peer.pending_match_id = null;
                    peer.queue_pool_id = pending.pool_id;
                    peer.retain();
                    queue_peer = peer;
                }
            }
            self.clearPendingMatchLocked(match_id);
        }
        connection.pending_match_id = null;
        connection.queue_pool_id = null;
        connection.lobby_pool_id = null;
        const count = self.leaveLocked(connection, &recipients, &left_user, &new_host);
        defer releaseRecipients(recipients[0..count]);
        defer if (queue_peer) |peer| peer.release();
        self.removeConnectionLocked(connection);
        self.mutex.unlock(self.io);
        if (queue_peer) |peer| {
            if (eventQueueStatusOwned(self.allocator, 0)) |frame| {
                defer self.allocator.free(frame);
                peer.send(frame);
            } else |_| {}
        }
        if (left_user) |user| {
            if (eventUserOwned(self.allocator, "UserLeft", user)) |frame| {
                defer self.allocator.free(frame);
                sendRecipients(recipients[0..count], frame);
            } else |_| {}
        }
        connection.release();
        if (new_host) |host_id| {
            if (eventIntegersOwned(self.allocator, "HostChanged", &.{host_id})) |frame| {
                defer self.allocator.free(frame);
                sendRecipients(recipients[0..count], frame);
            } else |_| {}
        }
    }

    pub fn roomsJson(self: *Manager, allocator: std.mem.Allocator, only_room_id: ?i64) !?[]u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (only_room_id) |room_id| {
            const room = self.roomByIdLocked(room_id) orelse return null;
            try writeRoomJson(&output.writer, room);
            return try output.toOwnedSlice();
        }
        try output.writer.writeByte('[');
        var written: usize = 0;
        for (self.rooms) |entry| if (entry) |room| {
            if (written != 0) try output.writer.writeByte(',');
            try writeRoomJson(&output.writer, room);
            written += 1;
        };
        try output.writer.writeByte(']');
        return try output.toOwnedSlice();
    }

    pub fn scoreContext(self: *Manager, user_id: i32, room_id: i64, playlist_item_id: i64) ?RoomScoreContext {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const room = self.roomByIdLocked(room_id) orelse return null;
        if (room.userIndex(user_id) == null) return null;
        const item_index = room.itemIndex(playlist_item_id) orelse return null;
        const item = room.playlist[item_index].?;
        return .{ .beatmap_id = item.beatmap_id, .ruleset_id = item.ruleset_id };
    }

    pub fn serve(self: *Manager, user: domain.User, socket: *std.http.Server.WebSocket) !void {
        const handshake = try socket.readSmallMessage();
        if ((handshake.opcode != .text and handshake.opcode != .binary) or !validSignalRHandshake(self.allocator, handshake.data)) return error.InvalidSignalRHandshake;
        // SignalR's handshake body is JSON even when the selected hub protocol
        // uses binary transfer. Match the negotiated WebSocket transfer format
        // instead of assuming the JSON bytes arrived in a text frame.
        try socket.writeMessage("{}\x1e", handshake.opcode);
        const connection = try self.connect(user, socket);
        defer self.disconnect(connection);
        while (connection.alive) {
            const message = socket.readSmallMessage() catch return;
            switch (message.opcode) {
                .ping => {
                    connection.write_mutex.lockUncancelable(connection.io);
                    defer connection.write_mutex.unlock(connection.io);
                    if (connection.alive) try socket.writeMessage(message.data, .pong);
                },
                .binary => try self.handleFrames(connection, message.data),
                else => {},
            }
        }
    }

    fn handleFrames(self: *Manager, connection: *Connection, data: []const u8) !void {
        var position: usize = 0;
        while (position < data.len) {
            var length: usize = 0;
            var shift: u6 = 0;
            var prefix_bytes: u8 = 0;
            while (true) {
                if (position >= data.len or prefix_bytes == 5) return error.InvalidSignalRFrame;
                const byte_value = data[position];
                position += 1;
                prefix_bytes += 1;
                length |= @as(usize, byte_value & 0x7f) << shift;
                if (byte_value & 0x80 == 0) break;
                shift += 7;
            }
            if (length == 0 or length > max_hub_message or position + length > data.len) return error.InvalidSignalRFrame;
            try self.handleHubMessage(connection, data[position .. position + length]);
            position += length;
        }
    }

    fn handleHubMessage(self: *Manager, connection: *Connection, payload: []const u8) !void {
        var reader: MessagePackReader = .{ .data = payload };
        const count = try reader.arrayLen();
        if (count == 0) return error.InvalidSignalRMessage;
        const message_type = try reader.integer();
        if (message_type == 6) {
            const ping = try pingOwned(self.allocator);
            defer self.allocator.free(ping);
            connection.send(ping);
            return;
        }
        if (message_type == 7) return error.ConnectionClose;
        if (message_type != 1 or count < 5) return;
        const header_count = try reader.mapLen();
        for (0..header_count * 2) |_| try reader.skip(0);
        const invocation_id: ?[]const u8 = if (reader.pos < reader.data.len and reader.data[reader.pos] == 0xc0) id: {
            reader.pos += 1;
            break :id null;
        } else try reader.string();
        const target = try reader.string();
        const argument_count = try reader.arrayLen();
        self.handleInvocation(connection, invocation_id, target, argument_count, &reader) catch |err| {
            std.log.warn("event=lazer_multiplayer_invocation_failed user_id={d} target={s} error={t}", .{ connection.user_id, target, err });
            if (invocation_id) |id| {
                const frame = completionErrorOwned(self.allocator, id, "multiplayer request was not accepted") catch return;
                defer self.allocator.free(frame);
                connection.send(frame);
            }
        };
    }

    fn finishVoid(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
        const id = invocation_id orelse return;
        const frame = try completionVoidOwned(self.allocator, id);
        defer self.allocator.free(frame);
        connection.send(frame);
    }

    fn handleInvocation(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, target: []const u8, argument_count: usize, reader: *MessagePackReader) !void {
        if (std.mem.eql(u8, target, "CreateRoom")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            const room_value = try reader.raw();
            return self.createRoom(connection, invocation_id, room_value);
        }
        if (std.mem.eql(u8, target, "JoinRoom") or std.mem.eql(u8, target, "JoinRoomWithPassword")) {
            if (argument_count < 1 or argument_count > 2) return error.InvalidMultiplayerArguments;
            const room_id = try reader.integer();
            const password = if (argument_count == 2) try reader.string() else "";
            return self.joinRoom(connection, invocation_id, room_id, password);
        }
        if (std.mem.eql(u8, target, "LeaveRoom")) return self.leaveRoom(connection, invocation_id);
        if (std.mem.eql(u8, target, "TransferHost")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.transferHost(connection, invocation_id, @intCast(try reader.integer()));
        }
        if (std.mem.eql(u8, target, "KickUser")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.kickUser(connection, invocation_id, @intCast(try reader.integer()));
        }
        if (std.mem.eql(u8, target, "ChangeSettings")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.changeSettings(connection, invocation_id, try reader.raw());
        }
        if (std.mem.eql(u8, target, "ChangeState")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.changeState(connection, invocation_id, @intCast(try reader.integer()));
        }
        if (std.mem.eql(u8, target, "ChangeBeatmapAvailability")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.changeAvailability(connection, invocation_id, try reader.raw());
        }
        if (std.mem.eql(u8, target, "ChangeUserStyle")) {
            if (argument_count != 2) return error.InvalidMultiplayerArguments;
            const beatmap_id = try reader.nullableInteger();
            const ruleset_id = try reader.nullableInteger();
            return self.changeStyle(connection, invocation_id, if (beatmap_id) |value| @intCast(value) else null, if (ruleset_id) |value| @intCast(value) else null);
        }
        if (std.mem.eql(u8, target, "ChangeUserMods")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.changeMods(connection, invocation_id, try reader.raw());
        }
        if (std.mem.eql(u8, target, "StartMatch")) return self.startMatch(connection, invocation_id);
        if (std.mem.eql(u8, target, "AbortMatch")) return self.abortMatch(connection, invocation_id);
        if (std.mem.eql(u8, target, "AbortGameplay")) return self.abortGameplay(connection, invocation_id);
        if (std.mem.eql(u8, target, "AddPlaylistItem")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.addPlaylistItem(connection, invocation_id, try reader.raw());
        }
        if (std.mem.eql(u8, target, "EditPlaylistItem")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.editPlaylistItem(connection, invocation_id, try reader.raw());
        }
        if (std.mem.eql(u8, target, "RemovePlaylistItem")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.removePlaylistItem(connection, invocation_id, try reader.integer());
        }
        if (std.mem.eql(u8, target, "VoteToSkipIntro")) return self.voteSkip(connection, invocation_id);
        if (std.mem.eql(u8, target, "InvitePlayer")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.invitePlayer(connection, invocation_id, @intCast(try reader.integer()));
        }
        if (std.mem.eql(u8, target, "SendMatchRequest")) {
            for (0..argument_count) |_| try reader.skip(0);
            return self.finishVoid(connection, invocation_id);
        }
        if (std.mem.eql(u8, target, "GetMatchmakingPools") or std.mem.eql(u8, target, "GetMatchmakingPoolsOfType")) {
            if (argument_count > 1) return error.InvalidMultiplayerArguments;
            const pool_type: u8 = if (argument_count == 1) @intCast(try reader.integer()) else 0;
            return self.getMatchmakingPools(connection, invocation_id, pool_type);
        }
        if (std.mem.eql(u8, target, "MatchmakingJoinLobby")) {
            if (argument_count != 0) return error.InvalidMultiplayerArguments;
            return self.joinMatchmakingLobby(connection, invocation_id, 1);
        }
        if (std.mem.eql(u8, target, "MatchmakingJoinLobbyWithParams")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            const request = try reader.raw();
            var request_reader: MessagePackReader = .{ .data = request };
            if (try request_reader.arrayLen() < 1) return error.InvalidMultiplayerArguments;
            return self.joinMatchmakingLobby(connection, invocation_id, @intCast(try request_reader.integer()));
        }
        if (std.mem.eql(u8, target, "MatchmakingLeaveLobby")) {
            if (argument_count != 0) return error.InvalidMultiplayerArguments;
            return self.leaveMatchmakingLobby(connection, invocation_id);
        }
        if (std.mem.eql(u8, target, "MatchmakingJoinQueue")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.joinMatchmakingQueue(connection, invocation_id, @intCast(try reader.integer()));
        }
        if (std.mem.eql(u8, target, "MatchmakingLeaveQueue")) {
            if (argument_count != 0) return error.InvalidMultiplayerArguments;
            return self.leaveMatchmakingQueue(connection, invocation_id, true);
        }
        if (std.mem.eql(u8, target, "MatchmakingAcceptInvitation")) {
            if (argument_count != 0) return error.InvalidMultiplayerArguments;
            return self.acceptMatchmakingInvitation(connection, invocation_id);
        }
        if (std.mem.eql(u8, target, "MatchmakingDeclineInvitation")) {
            if (argument_count != 0) return error.InvalidMultiplayerArguments;
            return self.declineMatchmakingInvitation(connection, invocation_id);
        }
        if (std.mem.eql(u8, target, "MatchmakingToggleSelection")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.toggleMatchmakingSelection(connection, invocation_id, try reader.integer());
        }
        for (0..argument_count) |_| try reader.skip(0);
        return error.UnsupportedMultiplayerMethod;
    }

    fn createRoom(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded_room: []const u8) !void {
        const id = invocation_id orelse return error.MissingInvocationId;
        if (connection.room_id != null) return error.AlreadyInMultiplayerRoom;
        const room = try parseRoom(self.allocator, encoded_room, connection);
        errdefer self.allocator.destroy(room);
        var response: []u8 = undefined;
        self.mutex.lockUncancelable(self.io);
        const slot = self.roomSlotLocked() orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerRoomLimit;
        };
        room.id = self.next_room_id;
        self.next_room_id += 1;
        room.channel_id = 4;
        connection.room_id = room.id;
        self.rooms[slot] = room;
        response = completionRoomOwned(self.allocator, id, room) catch |err| {
            self.rooms[slot] = null;
            connection.room_id = null;
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        defer self.allocator.free(response);
        connection.send(response);
        std.log.info("event=lazer_multiplayer_room_created room_id={d} host_id={d}", .{ room.id, connection.user_id });
    }

    fn joinRoom(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, room_id: i64, password: []const u8) !void {
        const id = invocation_id orelse return error.MissingInvocationId;
        var recipients: [max_connections]*Connection = undefined;
        var joined: RoomUser = undefined;
        var response: []u8 = undefined;
        var match_state_event: ?[]u8 = null;
        var advanced_match = false;
        defer if (match_state_event) |event| self.allocator.free(event);
        self.mutex.lockUncancelable(self.io);
        if (connection.room_id != null) {
            self.mutex.unlock(self.io);
            return error.AlreadyInMultiplayerRoom;
        }
        const room = self.roomByIdLocked(room_id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerRoomNotFound;
        };
        if (!std.mem.eql(u8, room.settings.password.slice(), password)) {
            self.mutex.unlock(self.io);
            return error.InvalidMultiplayerPassword;
        }
        if (!room.userAllowed(connection.user_id)) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        const limit: usize = room.settings.max_participants orelse max_users;
        if (room.user_count >= limit) {
            self.mutex.unlock(self.io);
            return error.MultiplayerRoomFull;
        }
        const user_slot = for (room.users, 0..) |entry, index| {
            if (entry == null) break index;
        } else {
            self.mutex.unlock(self.io);
            return error.MultiplayerRoomFull;
        };
        joined = try defaultRoomUser(connection.user_id, connection.user_name.slice(), connection.user_country);
        room.users[user_slot] = joined;
        room.user_count += 1;
        connection.room_id = room_id;
        if (room.matchmaking) |*matchmaking| {
            if (matchmaking.stage == matchmaking_stage.waiting_for_clients_join and room.user_count == room.allowed_user_count) {
                matchmaking.current_round = 1;
                matchmaking.stage = matchmaking_stage.user_beatmap_select;
                advanced_match = true;
                match_state_event = eventMatchStateOwned(self.allocator, room) catch |err| {
                    matchmaking.current_round = 0;
                    matchmaking.stage = matchmaking_stage.waiting_for_clients_join;
                    room.users[user_slot] = null;
                    room.user_count -= 1;
                    connection.room_id = null;
                    self.mutex.unlock(self.io);
                    return err;
                };
            }
        }
        const count = self.recipientsLocked(room_id, connection, &recipients);
        defer releaseRecipients(recipients[0..count]);
        response = completionRoomOwned(self.allocator, id, room) catch |err| {
            if (advanced_match) {
                room.matchmaking.?.current_round = 0;
                room.matchmaking.?.stage = matchmaking_stage.waiting_for_clients_join;
            }
            room.users[user_slot] = null;
            room.user_count -= 1;
            connection.room_id = null;
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        defer self.allocator.free(response);
        connection.send(response);
        const event = try eventUserOwned(self.allocator, "UserJoined", joined);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        if (match_state_event) |state_event| sendRecipients(recipients[0..count], state_event);
        std.log.info("event=lazer_multiplayer_room_joined room_id={d} user_id={d}", .{ room_id, connection.user_id });
    }

    fn leaveRoom(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
        var recipients: [max_connections]*Connection = undefined;
        var left_user: ?RoomUser = null;
        var new_host: ?i32 = null;
        self.mutex.lockUncancelable(self.io);
        const count = self.leaveLocked(connection, &recipients, &left_user, &new_host);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        if (left_user) |user| {
            const event = try eventUserOwned(self.allocator, "UserLeft", user);
            defer self.allocator.free(event);
            sendRecipients(recipients[0..count], event);
        }
        if (new_host) |host_id| {
            const event = try eventIntegersOwned(self.allocator, "HostChanged", &.{host_id});
            defer self.allocator.free(event);
            sendRecipients(recipients[0..count], event);
        }
        try self.finishVoid(connection, invocation_id);
    }

    fn transferHost(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, target_user_id: i32) !void {
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        if (room.host_id != connection.user_id or room.userIndex(target_user_id) == null) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        room.host_id = target_user_id;
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const event = try eventIntegersOwned(self.allocator, "HostChanged", &.{target_user_id});
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn kickUser(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, target_user_id: i32) !void {
        if (target_user_id == connection.user_id) return error.MultiplayerPermissionDenied;
        var recipients: [max_connections]*Connection = undefined;
        var target_connection: ?*Connection = null;
        var kicked: RoomUser = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        if (room.host_id != connection.user_id) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        const index = room.userIndex(target_user_id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerUserNotFound;
        };
        kicked = room.users[index].?;
        room.users[index] = null;
        room.user_count -= 1;
        for (self.connections.items) |candidate| if (candidate.user_id == target_user_id and candidate.room_id == room_id) {
            candidate.room_id = null;
            candidate.retain();
            target_connection = candidate;
            break;
        };
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        defer if (target_connection) |target| target.release();
        self.mutex.unlock(self.io);
        const event = try eventUserOwned(self.allocator, "UserKicked", kicked);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        if (target_connection) |target| {
            target.send(event);
        }
        try self.finishVoid(connection, invocation_id);
    }

    fn changeSettings(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
        var settings = try parseSettings(encoded);
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        if (room.host_id != connection.user_id) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        if (settings.playlist_item_id == 0 or room.itemIndex(settings.playlist_item_id) == null) settings.playlist_item_id = room.settings.playlist_item_id;
        room.settings = settings;
        for (&room.users) |*entry| {
            if (entry.*) |*user| {
                if (user.state == 1) user.state = 0;
            }
        }
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        const event = eventSettingsOwned(self.allocator, "SettingsChanged", room.settings) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn changeState(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, new_state: u8) !void {
        if (new_state > 8 or new_state == 2 or new_state == 5 or new_state == 7) return error.InvalidMultiplayerState;
        var recipients: [max_connections]*Connection = undefined;
        var start_players: [max_connections]*Connection = undefined;
        var start_count: usize = 0;
        var load_players: [max_connections]*Connection = undefined;
        var load_count: usize = 0;
        var server_user_updates: [max_users]struct { id: i32, state: u8 } = undefined;
        var server_user_update_count: usize = 0;
        var match_snapshots: [3]Room = undefined;
        var match_snapshot_count: usize = 0;
        var match_events: [3]?[]u8 = [_]?[]u8{null} ** 3;
        defer for (match_events) |event| if (event) |frame| self.allocator.free(frame);
        var playlist_event: ?[]u8 = null;
        defer if (playlist_event) |event| self.allocator.free(event);
        var results_ready = false;
        var changed_room_state: ?i32 = null;
        var emitted_user_state: u8 = new_state;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const room_before = room.*;
        const user_index = room.userIndex(connection.user_id).?;
        const previous_user_state = room.users[user_index].?.state;
        room.users[user_index].?.state = if (room.state == 2 and previous_user_state == 5 and (new_state == 3 or new_state == 4)) 5 else new_state;
        if (new_state == 6) room.users[user_index].?.state = 7;
        emitted_user_state = room.users[user_index].?.state;
        if (room.matchmaking != null and room.matchmaking.?.stage == matchmaking_stage.waiting_for_beatmap_download and new_state == 1) {
            var all_ready = room.user_count != 0;
            for (room.users) |entry| if (entry) |user| if (user.state != 1) {
                all_ready = false;
            };
            if (all_ready) {
                room.matchmaking.?.stage = matchmaking_stage.gameplay_warmup;
                match_snapshots[match_snapshot_count] = room.*;
                match_snapshot_count += 1;
                room.matchmaking.?.stage = matchmaking_stage.gameplay;
                match_snapshots[match_snapshot_count] = room.*;
                match_snapshot_count += 1;
                room.state = 1;
                changed_room_state = 1;
                for (&room.users) |*entry| if (entry.*) |*user| {
                    if (user.state != 1) continue;
                    user.state = 2;
                    server_user_updates[server_user_update_count] = .{ .id = user.id, .state = 2 };
                    server_user_update_count += 1;
                };
                for (self.connections.items) |candidate| if (candidate.room_id == room_id) {
                    const candidate_index = room.userIndex(candidate.user_id) orelse continue;
                    if (room.users[candidate_index].?.state == 2 and load_count < load_players.len) {
                        candidate.retain();
                        load_players[load_count] = candidate;
                        load_count += 1;
                    }
                };
            }
        } else if (room.state == 1 and (new_state == 3 or new_state == 4)) {
            var waiting = false;
            var gameplay_users: usize = 0;
            for (room.users) |entry| if (entry) |user| {
                if (user.state == 2) waiting = true;
                if (user.state >= 2 and user.state <= 4) gameplay_users += 1;
            };
            if (!waiting and gameplay_users != 0) {
                room.state = 2;
                for (&room.users) |*entry| {
                    if (entry.*) |*user| {
                        if (user.state == 3 or user.state == 4) {
                            user.state = 5;
                            server_user_updates[server_user_update_count] = .{ .id = user.id, .state = 5 };
                            server_user_update_count += 1;
                        }
                    }
                }
                changed_room_state = 2;
                for (self.connections.items) |candidate| if (candidate.room_id == room_id) {
                    const candidate_index = room.userIndex(candidate.user_id) orelse continue;
                    if (room.users[candidate_index].?.state == 5 and start_count < start_players.len) {
                        candidate.retain();
                        start_players[start_count] = candidate;
                        start_count += 1;
                    }
                };
            }
        } else if (new_state == 6) {
            var playing = false;
            for (room.users) |entry| {
                if (entry) |user| {
                    if (user.state == 5 or user.state == 6) playing = true;
                }
            }
            if (!playing) {
                room.state = 0;
                results_ready = true;
                changed_room_state = 0;
                if (room.matchmaking) |*matchmaking| {
                    if (matchmaking.gameplay_item != 0) if (room.itemIndex(matchmaking.gameplay_item)) |item_index| {
                        room.playlist[item_index].?.expired = true;
                        playlist_event = eventPlaylistOwned(self.allocator, "PlaylistItemChanged", room.playlist[item_index].?) catch |err| {
                            room.* = room_before;
                            self.mutex.unlock(self.io);
                            return err;
                        };
                    };
                    matchmaking.stage = matchmaking_stage.results;
                    match_snapshots[match_snapshot_count] = room.*;
                    match_snapshot_count += 1;
                }
            }
        } else if (new_state == 0 and room.matchmaking != null and room.matchmaking.?.stage == matchmaking_stage.results) {
            var all_idle = room.user_count != 0;
            for (room.users) |entry| if (entry) |user| if (user.state != 0) {
                all_idle = false;
            };
            if (all_idle) {
                if (room.matchmaking.?.current_round >= matchmaking_rounds) {
                    room.matchmaking.?.stage = matchmaking_stage.ended;
                    match_snapshots[match_snapshot_count] = room.*;
                    match_snapshot_count += 1;
                } else {
                    room.matchmaking.?.current_round += 1;
                    room.matchmaking.?.candidate_items = [_]i64{0} ** max_users;
                    room.matchmaking.?.candidate_count = 0;
                    room.matchmaking.?.candidate_item = 0;
                    room.matchmaking.?.gameplay_item = 0;
                    room.matchmaking.?.picks = [_]?i64{null} ** max_users;
                    room.matchmaking.?.stage = matchmaking_stage.round_warmup;
                    match_snapshots[match_snapshot_count] = room.*;
                    match_snapshot_count += 1;
                    room.matchmaking.?.stage = matchmaking_stage.user_beatmap_select;
                    match_snapshots[match_snapshot_count] = room.*;
                    match_snapshot_count += 1;
                }
            }
        }
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        defer releaseRecipients(start_players[0..start_count]);
        defer releaseRecipients(load_players[0..load_count]);
        for (match_snapshots[0..match_snapshot_count], 0..) |*snapshot, index| {
            match_events[index] = eventMatchStateOwned(self.allocator, snapshot) catch |err| {
                room.* = room_before;
                self.mutex.unlock(self.io);
                return err;
            };
        }
        self.mutex.unlock(self.io);
        const user_state_event = try eventIntegersOwned(self.allocator, "UserStateChanged", &.{ connection.user_id, emitted_user_state });
        defer self.allocator.free(user_state_event);
        sendRecipients(recipients[0..count], user_state_event);
        for (match_events[0..match_snapshot_count]) |state_event| sendRecipients(recipients[0..count], state_event.?);
        for (server_user_updates[0..server_user_update_count]) |update| {
            const event = try eventIntegersOwned(self.allocator, "UserStateChanged", &.{ update.id, update.state });
            defer self.allocator.free(event);
            sendRecipients(recipients[0..count], event);
        }
        if (changed_room_state) |state| {
            const event = try eventIntegersOwned(self.allocator, "RoomStateChanged", &.{state});
            defer self.allocator.free(event);
            sendRecipients(recipients[0..count], event);
        }
        if (load_count != 0) {
            const event = try eventNoArgsOwned(self.allocator, "LoadRequested");
            defer self.allocator.free(event);
            sendRecipients(load_players[0..load_count], event);
        }
        if (start_count != 0) {
            const event = try eventNoArgsOwned(self.allocator, "GameplayStarted");
            defer self.allocator.free(event);
            sendRecipients(start_players[0..start_count], event);
        }
        if (playlist_event) |event| sendRecipients(recipients[0..count], event);
        if (results_ready) {
            const event = try eventNoArgsOwned(self.allocator, "ResultsReady");
            defer self.allocator.free(event);
            sendRecipients(recipients[0..count], event);
        }
        try self.finishVoid(connection, invocation_id);
    }

    fn changeAvailability(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const index = room.userIndex(connection.user_id).?;
        room.users[index].?.availability.set(encoded) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const event = try eventIntegerRawOwned(self.allocator, "UserBeatmapAvailabilityChanged", connection.user_id, encoded);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn changeStyle(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, beatmap_id: ?i32, ruleset_id: ?i32) !void {
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const index = room.userIndex(connection.user_id).?;
        room.users[index].?.beatmap_id = beatmap_id;
        room.users[index].?.ruleset_id = ruleset_id;
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const event = try eventStyleOwned(self.allocator, connection.user_id, beatmap_id, ruleset_id);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn changeMods(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const index = room.userIndex(connection.user_id).?;
        room.users[index].?.mods.set(encoded) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const event = try eventIntegerRawOwned(self.allocator, "UserModsChanged", connection.user_id, encoded);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn startMatch(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
        var recipients: [max_connections]*Connection = undefined;
        var loaders: [max_connections]*Connection = undefined;
        var loader_count: usize = 0;
        var state_events: [max_users]?[]u8 = [_]?[]u8{null} ** max_users;
        defer for (&state_events) |*entry| if (entry.*) |event| self.allocator.free(event);
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        if (room.host_id != connection.user_id or room.state != 0) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        var ready_count: usize = 0;
        for (&room.users, 0..) |*entry, index| if (entry.*) |*user| {
            if (user.state == 1) {
                user.state = 2;
                state_events[index] = eventIntegersOwned(self.allocator, "UserStateChanged", &.{ user.id, 2 }) catch |err| {
                    self.mutex.unlock(self.io);
                    return err;
                };
                ready_count += 1;
            }
        };
        if (ready_count == 0) {
            self.mutex.unlock(self.io);
            return error.NoReadyMultiplayerPlayers;
        }
        room.state = 1;
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        for (self.connections.items) |candidate| if (candidate.room_id == room_id) {
            const index = room.userIndex(candidate.user_id) orelse continue;
            if (room.users[index].?.state == 2 and loader_count < loaders.len) {
                candidate.retain();
                loaders[loader_count] = candidate;
                loader_count += 1;
            }
        };
        self.mutex.unlock(self.io);
        defer releaseRecipients(loaders[0..loader_count]);
        const room_event = try eventIntegersOwned(self.allocator, "RoomStateChanged", &.{1});
        defer self.allocator.free(room_event);
        sendRecipients(recipients[0..count], room_event);
        for (state_events) |entry| if (entry) |event| sendRecipients(recipients[0..count], event);
        const load = try eventNoArgsOwned(self.allocator, "LoadRequested");
        defer self.allocator.free(load);
        sendRecipients(loaders[0..loader_count], load);
        try self.finishVoid(connection, invocation_id);
    }

    fn abortMatch(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        if (room.host_id != connection.user_id) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        room.state = 0;
        for (&room.users) |*entry| {
            if (entry.*) |*user| {
                if (user.state >= 2 and user.state <= 7) user.state = 0;
            }
        }
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const room_event = try eventIntegersOwned(self.allocator, "RoomStateChanged", &.{0});
        defer self.allocator.free(room_event);
        sendRecipients(recipients[0..count], room_event);
        const abort_event = try eventIntegersOwned(self.allocator, "GameplayAborted", &.{1});
        defer self.allocator.free(abort_event);
        sendRecipients(recipients[0..count], abort_event);
        try self.finishVoid(connection, invocation_id);
    }

    fn abortGameplay(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
        try self.changeState(connection, null, 0);
        const event = try eventIntegersOwned(self.allocator, "GameplayAborted", &.{0});
        defer self.allocator.free(event);
        connection.send(event);
        try self.finishVoid(connection, invocation_id);
    }

    fn addPlaylistItem(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
        var item = try parsePlaylistItem(encoded);
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
        item.order = @intCast(room.playlist_count);
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

    fn editPlaylistItem(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
        const item = try parsePlaylistItem(encoded);
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

    fn removePlaylistItem(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, item_id: i64) !void {
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

    fn voteSkip(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
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

    fn invitePlayer(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, user_id: i32) !void {
        var target: ?*Connection = null;
        var room_id: i64 = 0;
        var password: [64]u8 = undefined;
        var password_len: usize = 0;
        self.mutex.lockUncancelable(self.io);
        room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const password_slice = room.settings.password.slice();
        @memcpy(password[0..password_slice.len], password_slice);
        password_len = password_slice.len;
        for (self.connections.items) |candidate| if (candidate.user_id == user_id and candidate.room_id == null and candidate.alive) {
            candidate.retain();
            target = candidate;
            break;
        };
        defer if (target) |recipient| recipient.release();
        self.mutex.unlock(self.io);
        if (target) |recipient| {
            const event = try eventInviteOwned(self.allocator, connection.user_id, room_id, password[0..password_len]);
            defer self.allocator.free(event);
            recipient.send(event);
        }
        try self.finishVoid(connection, invocation_id);
    }

    fn getMatchmakingPools(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, pool_type: u8) !void {
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

    fn joinMatchmakingLobby(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, pool_id: i32) !void {
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

    fn leaveMatchmakingLobby(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
        self.mutex.lockUncancelable(self.io);
        connection.lobby_pool_id = null;
        self.mutex.unlock(self.io);
        try self.finishVoid(connection, invocation_id);
    }

    fn publishLobbyStatus(self: *Manager, pool_id: i32) !void {
        var recipients: [max_connections]*Connection = undefined;
        var recipient_count: usize = 0;
        var users: [max_connections]i32 = undefined;
        var user_count: usize = 0;
        self.mutex.lockUncancelable(self.io);
        for (self.connections.items) |candidate| {
            if (!candidate.alive) continue;
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

    fn joinMatchmakingQueue(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, pool_id: i32) !void {
        const mode = poolMode(pool_id) orelse return error.InvalidMatchmakingPool;
        const joined = try eventNoArgsOwned(self.allocator, "MatchmakingQueueJoined");
        defer self.allocator.free(joined);
        const searching = try eventQueueStatusOwned(self.allocator, 0);
        defer self.allocator.free(searching);
        const invited_legacy = try eventNoArgsOwned(self.allocator, "MatchmakingRoomInvited");
        defer self.allocator.free(invited_legacy);
        const invited = try eventMatchmakingInvitationOwned(self.allocator, 0);
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
            if (candidate == connection or candidate.user_id == connection.user_id or !candidate.alive or candidate.room_id != null or candidate.queue_pool_id != pool_id or candidate.pending_match_id != null) continue;
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

    fn leaveMatchmakingQueue(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, notify: bool) !void {
        const left = try eventNoArgsOwned(self.allocator, "MatchmakingQueueLeft");
        defer self.allocator.free(left);
        const searching = try eventQueueStatusOwned(self.allocator, 0);
        defer self.allocator.free(searching);
        var peer: ?*Connection = null;
        var pool_id: ?i32 = null;
        var was_queued = false;
        self.mutex.lockUncancelable(self.io);
        pool_id = connection.queue_pool_id;
        was_queued = pool_id != null or connection.pending_match_id != null;
        if (connection.pending_match_id) |match_id| {
            if (self.pendingMatchByIdLocked(match_id)) |pending| {
                pool_id = pending.pool_id;
                const index = pending.userIndex(connection.user_id) orelse 0;
                const peer_id = pending.users[1 - index];
                if (self.connectionByUserLocked(peer_id)) |matched| {
                    matched.pending_match_id = null;
                    matched.queue_pool_id = pending.pool_id;
                    matched.retain();
                    peer = matched;
                }
            }
            self.clearPendingMatchLocked(match_id);
        }
        connection.pending_match_id = null;
        connection.queue_pool_id = null;
        self.mutex.unlock(self.io);
        defer if (peer) |matched| matched.release();
        if (notify and was_queued) connection.send(left);
        if (peer) |matched| matched.send(searching);
        try self.finishVoid(connection, invocation_id);
        if (pool_id) |pool| try self.publishLobbyStatus(pool);
    }

    fn declineMatchmakingInvitation(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
        if (connection.pending_match_id == null) return error.NoPendingMatchmakingInvitation;
        return self.leaveMatchmakingQueue(connection, invocation_id, true);
    }

    fn createMatchmakingRoomLocked(self: *Manager, pending: PendingMatch, password: []const u8) !*Room {
        const mode = poolMode(pending.pool_id) orelse return error.InvalidMatchmakingPool;
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
            .matchmaking = .{},
        };
        self.next_room_id += 1;
        try room.host_name.set("kai");
        const mode_names = [_][]const u8{ "osu!", "osu!taiko", "osu!catch", "osu!mania" };
        var name_buf: [96]u8 = undefined;
        const room_name = try std.fmt.bufPrint(&name_buf, "zigcho quick play - {s}", .{mode_names[mode]});
        try room.settings.name.set(room_name);
        try room.settings.password.set(password);
        room.settings.match_type = 3;
        room.settings.queue_mode = 0;
        room.settings.max_participants = pending.users.len;
        room.settings.auto_start.bytes[0] = 0;
        room.settings.auto_start.len = 1;
        room.allowed_users[0] = pending.users[0];
        room.allowed_users[1] = pending.users[1];
        for (pending.users, 0..) |user_id, index| {
            room.matchmaking.?.users[index] = .{ .id = user_id };
            room.matchmaking.?.user_count += 1;
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
        return room;
    }

    fn acceptMatchmakingInvitation(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
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

    fn toggleMatchmakingSelection(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, playlist_item_id: i64) !void {
        var random_bytes: [8]u8 = undefined;
        try self.io.randomSecure(&random_bytes);
        const random_value = std.mem.readInt(u64, &random_bytes, .little);
        var recipients: [max_connections]*Connection = undefined;
        var previous: ?i64 = null;
        var advanced = false;
        var finalised_event: ?[]u8 = null;
        var settings_event: ?[]u8 = null;
        var download_event: ?[]u8 = null;
        defer if (finalised_event) |event| self.allocator.free(event);
        defer if (settings_event) |event| self.allocator.free(event);
        defer if (download_event) |event| self.allocator.free(event);
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        if (room.matchmaking == null or room.matchmaking.?.stage != matchmaking_stage.user_beatmap_select) {
            self.mutex.unlock(self.io);
            return error.InvalidMatchmakingStage;
        }
        if (playlist_item_id != -1) {
            const item_index = room.itemIndex(playlist_item_id) orelse {
                self.mutex.unlock(self.io);
                return error.MultiplayerPlaylistItemNotFound;
            };
            if (room.playlist[item_index].?.expired) {
                self.mutex.unlock(self.io);
                return error.MultiplayerPlaylistItemExpired;
            }
        }
        const match_user_index = room.matchmaking.?.userIndex(connection.user_id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        };
        previous = room.matchmaking.?.picks[match_user_index];
        if (previous == playlist_item_id) {
            self.mutex.unlock(self.io);
            return self.finishVoid(connection, invocation_id);
        }
        room.matchmaking.?.picks[match_user_index] = playlist_item_id;
        var all_picked = room.user_count != 0;
        for (room.users) |entry| if (entry) |user| {
            const index = room.matchmaking.?.userIndex(user.id) orelse continue;
            if (room.matchmaking.?.picks[index] == null) all_picked = false;
        };
        if (all_picked) {
            const previous_matchmaking = room.matchmaking.?;
            const previous_settings = room.settings;
            room.matchmaking.?.candidate_count = 0;
            for (room.matchmaking.?.picks) |pick_entry| if (pick_entry) |pick| {
                if (std.mem.indexOfScalar(i64, room.matchmaking.?.candidate_items[0..room.matchmaking.?.candidate_count], pick) == null) {
                    room.matchmaking.?.candidate_items[room.matchmaking.?.candidate_count] = pick;
                    room.matchmaking.?.candidate_count += 1;
                }
            };
            const candidate_index: usize = @intCast(random_value % room.matchmaking.?.candidate_count);
            room.matchmaking.?.candidate_item = room.matchmaking.?.candidate_items[candidate_index];
            room.matchmaking.?.gameplay_item = if (room.matchmaking.?.candidate_item == -1) random: {
                var active_items: [max_playlist]i64 = undefined;
                var active_count: usize = 0;
                for (room.playlist) |entry| if (entry) |item| if (!item.expired) {
                    active_items[active_count] = item.id;
                    active_count += 1;
                };
                if (active_count == 0) {
                    room.matchmaking = previous_matchmaking;
                    self.mutex.unlock(self.io);
                    return error.MatchmakingPoolUnavailable;
                }
                const active_index: usize = @intCast((random_value / room.matchmaking.?.candidate_count) % active_count);
                break :random active_items[active_index];
            } else room.matchmaking.?.candidate_item;
            room.matchmaking.?.stage = matchmaking_stage.server_beatmap_finalised;
            finalised_event = eventMatchStateOwned(self.allocator, room) catch |err| {
                room.matchmaking = previous_matchmaking;
                self.mutex.unlock(self.io);
                return err;
            };
            room.settings.playlist_item_id = room.matchmaking.?.gameplay_item;
            settings_event = eventSettingsOwned(self.allocator, "SettingsChanged", room.settings) catch |err| {
                room.matchmaking = previous_matchmaking;
                room.settings = previous_settings;
                self.mutex.unlock(self.io);
                return err;
            };
            room.matchmaking.?.stage = matchmaking_stage.waiting_for_beatmap_download;
            download_event = eventMatchStateOwned(self.allocator, room) catch |err| {
                room.matchmaking = previous_matchmaking;
                room.settings = previous_settings;
                self.mutex.unlock(self.io);
                return err;
            };
            advanced = true;
        }
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        if (previous) |old| {
            const event = try eventIntegersOwned(self.allocator, "MatchmakingItemDeselected", &.{ connection.user_id, old });
            defer self.allocator.free(event);
            sendRecipients(recipients[0..count], event);
        }
        const selected_event = try eventIntegersOwned(self.allocator, "MatchmakingItemSelected", &.{ connection.user_id, playlist_item_id });
        defer self.allocator.free(selected_event);
        sendRecipients(recipients[0..count], selected_event);
        if (advanced) {
            sendRecipients(recipients[0..count], finalised_event.?);
            sendRecipients(recipients[0..count], settings_event.?);
            sendRecipients(recipients[0..count], download_event.?);
        }
        try self.finishVoid(connection, invocation_id);
    }

    pub fn recordRoomScore(self: *Manager, user_id: i32, room_id: i64, playlist_item_id: i64, score: RoomScoreResult) !void {
        var recipients: [max_connections]*Connection = undefined;
        var state_event: ?[]u8 = null;
        defer if (state_event) |event| self.allocator.free(event);
        self.mutex.lockUncancelable(self.io);
        const room = self.roomByIdLocked(room_id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerRoomNotFound;
        };
        if (room.matchmaking == null or room.matchmaking.?.gameplay_item != playlist_item_id or room.matchmaking.?.current_round == 0) {
            self.mutex.unlock(self.io);
            return;
        }
        const user_index = room.matchmaking.?.userIndex(user_id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        };
        const round_index = room.matchmaking.?.current_round - 1;
        room.matchmaking.?.users[user_index].?.rounds[round_index] = .{
            .round = room.matchmaking.?.current_round,
            .total_score = score.total_score,
            .accuracy = score.accuracy,
            .max_combo = score.max_combo,
            .passed = score.passed,
        };
        recomputeMatchmakingPlacements(&room.matchmaking.?);
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        state_event = eventMatchStateOwned(self.allocator, room) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        sendRecipients(recipients[0..count], state_event.?);
    }
};

fn defaultRoomUser(user_id: i32, name: []const u8, country: [2]u8) !RoomUser {
    var user: RoomUser = .{ .id = user_id };
    try user.name.set(name);
    user.country = country;
    user.availability.bytes[0] = 0x92;
    user.availability.bytes[1] = 0x00;
    user.availability.bytes[2] = 0xc0;
    user.availability.len = 3;
    user.mods.bytes[0] = 0x90;
    user.mods.len = 1;
    return user;
}

fn recomputeMatchmakingPlacements(state: *MatchmakingState) void {
    const points = [_]i32{ 15, 12, 10, 8, 6, 4, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0 };
    for (&state.users) |*entry| if (entry.*) |*user| {
        user.points = 0;
        user.placement = null;
    };
    for (0..matchmaking_rounds) |round_index| {
        var order: [max_users]usize = undefined;
        var count: usize = 0;
        for (state.users, 0..) |entry, user_index| if (entry) |user| if (user.rounds[round_index] != null) {
            order[count] = user_index;
            count += 1;
        };
        for (0..count) |left| for (left + 1..count) |right| {
            const left_round = state.users[order[left]].?.rounds[round_index].?;
            const right_round = state.users[order[right]].?.rounds[round_index].?;
            if (right_round.total_score > left_round.total_score or (right_round.total_score == left_round.total_score and state.users[order[right]].?.id < state.users[order[left]].?.id)) {
                const swap = order[left];
                order[left] = order[right];
                order[right] = swap;
            }
        };
        var position: usize = 0;
        while (position < count) {
            var end = position + 1;
            const score = state.users[order[position]].?.rounds[round_index].?.total_score;
            while (end < count and state.users[order[end]].?.rounds[round_index].?.total_score == score) : (end += 1) {}
            const placement: u8 = @intCast(end);
            for (position..end) |cursor| {
                const user_index = order[cursor];
                state.users[user_index].?.rounds[round_index].?.placement = placement;
                state.users[user_index].?.points += points[end - 1];
            }
            position = end;
        }
    }
    var order: [max_users]usize = undefined;
    var count: usize = 0;
    for (state.users, 0..) |entry, index| if (entry != null) {
        order[count] = index;
        count += 1;
    };
    for (0..count) |left| for (left + 1..count) |right| {
        const a = state.users[order[left]].?;
        const b = state.users[order[right]].?;
        if (b.points > a.points or (b.points == a.points and b.id < a.id)) {
            const swap = order[left];
            order[left] = order[right];
            order[right] = swap;
        }
    };
    for (order[0..count], 0..) |user_index, placement| state.users[user_index].?.placement = @intCast(placement + 1);
}

fn parseSettings(encoded: []const u8) !Settings {
    var reader: MessagePackReader = .{ .data = encoded };
    if (try reader.arrayLen() < 8) return error.InvalidMultiplayerSettings;
    var settings: Settings = .{};
    const name = try reader.string();
    if (name.len == 0 or name.len > 100 or !std.unicode.utf8ValidateSlice(name)) return error.InvalidMultiplayerRoomName;
    try settings.name.set(name);
    settings.playlist_item_id = try reader.integer();
    const password = try reader.string();
    if (password.len > 50 or !std.unicode.utf8ValidateSlice(password)) return error.InvalidMultiplayerPassword;
    try settings.password.set(password);
    settings.match_type = @intCast(try reader.integer());
    if (settings.match_type != 1 and settings.match_type != 2) return error.UnsupportedMultiplayerMatchType;
    settings.queue_mode = @intCast(try reader.integer());
    if (settings.queue_mode > 2) return error.InvalidMultiplayerQueueMode;
    try settings.auto_start.set(try reader.raw());
    settings.auto_skip = try reader.boolean();
    settings.max_participants = if (try reader.nullableInteger()) |value| @intCast(value) else null;
    if (settings.max_participants) |limit| if (limit < 2 or limit > max_users) return error.InvalidMultiplayerParticipantLimit;
    return settings;
}

fn parsePlaylistItem(encoded: []const u8) !PlaylistItem {
    var reader: MessagePackReader = .{ .data = encoded };
    if (try reader.arrayLen() < 12) return error.InvalidMultiplayerPlaylistItem;
    var item: PlaylistItem = .{};
    item.id = try reader.integer();
    item.owner_id = @intCast(try reader.integer());
    item.beatmap_id = @intCast(try reader.integer());
    if (item.beatmap_id <= 0) return error.InvalidMultiplayerBeatmap;
    const checksum = try reader.string();
    if (checksum.len > 64) return error.InvalidMultiplayerBeatmap;
    try item.checksum.set(checksum);
    item.ruleset_id = @intCast(try reader.integer());
    if (item.ruleset_id > 3) return error.InvalidMultiplayerRuleset;
    try item.required_mods.set(try reader.raw());
    try item.allowed_mods.set(try reader.raw());
    item.expired = try reader.boolean();
    item.order = @intCast(try reader.integer());
    try item.played_at.set(try reader.raw());
    const star_raw = try reader.raw();
    var star_reader: MessagePackReader = .{ .data = star_raw };
    item.star_rating = switch (star_raw[0]) {
        0xca => value: {
            _ = try star_reader.byte();
            break :value @as(f64, @floatCast(@as(f32, @bitCast(try star_reader.readUnsigned(u32)))));
        },
        0xcb => value: {
            _ = try star_reader.byte();
            break :value @as(f64, @bitCast(try star_reader.readUnsigned(u64)));
        },
        else => @floatFromInt(try star_reader.integer()),
    };
    item.freestyle = try reader.boolean();
    return item;
}

fn parseRoom(allocator: std.mem.Allocator, encoded: []const u8, connection: *Connection) !*Room {
    var reader: MessagePackReader = .{ .data = encoded };
    if (try reader.arrayLen() < 9) return error.InvalidMultiplayerRoom;
    _ = try reader.integer();
    _ = try reader.integer();
    const settings_raw = try reader.raw();
    const settings = try parseSettings(settings_raw);
    try reader.skip(0);
    try reader.skip(0);
    try reader.skip(0);
    const playlist_len = try reader.arrayLen();
    if (playlist_len == 0 or playlist_len > max_playlist) return error.InvalidMultiplayerPlaylist;
    const room = try allocator.create(Room);
    errdefer allocator.destroy(room);
    room.* = .{
        .id = 0,
        .settings = settings,
        .host_id = connection.user_id,
        .host_country = connection.user_country,
    };
    try room.host_name.set(connection.user_name.slice());
    room.users[0] = try defaultRoomUser(connection.user_id, connection.user_name.slice(), connection.user_country);
    room.user_count = 1;
    for (0..playlist_len) |index| {
        const raw_item = try reader.raw();
        var item = try parsePlaylistItem(raw_item);
        if (item.id <= 0) item.id = @intCast(index + 1);
        if (item.owner_id <= 0) item.owner_id = connection.user_id;
        item.order = @intCast(index);
        room.playlist[index] = item;
        room.playlist_count += 1;
    }
    try reader.skip(0);
    _ = try reader.integer();
    if (room.itemIndex(room.settings.playlist_item_id) == null) room.settings.playlist_item_id = room.playlist[0].?.id;
    return room;
}

fn writeSettings(pack: MessagePackWriter, settings: Settings) !void {
    try pack.array(8);
    try pack.string(settings.name.slice());
    try pack.integer(settings.playlist_item_id);
    try pack.string(settings.password.slice());
    try pack.integer(settings.match_type);
    try pack.integer(settings.queue_mode);
    try pack.raw(settings.auto_start.slice());
    try pack.boolean(settings.auto_skip);
    if (settings.max_participants) |limit| try pack.integer(limit) else try pack.nil();
}

fn writeUser(pack: MessagePackWriter, user: RoomUser) !void {
    try pack.array(9);
    try pack.integer(user.id);
    try pack.integer(user.state);
    try pack.raw(user.availability.slice());
    try pack.raw(user.mods.slice());
    try pack.nil();
    if (user.ruleset_id) |ruleset_id| try pack.integer(ruleset_id) else try pack.nil();
    if (user.beatmap_id) |beatmap_id| try pack.integer(beatmap_id) else try pack.nil();
    try pack.boolean(user.voted_skip);
    try pack.integer(user.role);
}

fn writePlaylistItem(pack: MessagePackWriter, item: PlaylistItem) !void {
    try pack.array(12);
    try pack.integer(item.id);
    try pack.integer(item.owner_id);
    try pack.integer(item.beatmap_id);
    try pack.string(item.checksum.slice());
    try pack.integer(item.ruleset_id);
    try pack.raw(item.required_mods.slice());
    try pack.raw(item.allowed_mods.slice());
    try pack.boolean(item.expired);
    try pack.integer(item.order);
    try pack.raw(item.played_at.slice());
    try pack.float64(item.star_rating);
    try pack.boolean(item.freestyle);
}

fn writeMatchState(pack: MessagePackWriter, room: *const Room) !void {
    if (room.matchmaking) |matchmaking| {
        try pack.array(2);
        try pack.integer(1);
        try pack.array(6);
        try pack.integer(matchmaking.stage);
        try pack.integer(matchmaking.current_round);
        try pack.array(matchmaking.candidate_count);
        for (matchmaking.candidate_items[0..matchmaking.candidate_count]) |item_id| try pack.integer(item_id);
        try pack.integer(matchmaking.candidate_item);
        try pack.array(1);
        try pack.map(matchmaking.user_count);
        for (matchmaking.users) |entry| if (entry) |user| {
            try pack.integer(user.id);
            try pack.array(5);
            try pack.integer(user.id);
            if (user.placement) |placement| try pack.integer(placement) else try pack.nil();
            try pack.integer(user.points);
            try pack.array(1);
            var round_count: usize = 0;
            for (user.rounds) |round| if (round != null) {
                round_count += 1;
            };
            try pack.map(round_count);
            for (user.rounds) |round_entry| if (round_entry) |round| {
                try pack.integer(round.round);
                try pack.array(6);
                try pack.integer(round.round);
                try pack.integer(round.placement);
                try pack.integer(round.total_score);
                try pack.float64(round.accuracy);
                try pack.integer(round.max_combo);
                try pack.map(0);
            };
            try pack.nil();
        };
        try pack.integer(matchmaking.gameplay_item);
        return;
    }
    try pack.array(2);
    try pack.integer(if (room.settings.match_type == 2) 0 else 3);
    try pack.array(3);
    if (room.settings.match_type == 2) {
        try pack.array(2);
        try pack.array(2);
        try pack.integer(0);
        try pack.string("Team Red");
        try pack.array(2);
        try pack.integer(1);
        try pack.string("Team Blue");
    } else try pack.nil();
    try pack.boolean(false);
    if (room.settings.max_participants) |limit| {
        try pack.array(limit);
        var written: usize = 0;
        for (room.users) |entry| if (entry) |user| {
            if (written == limit) break;
            try pack.integer(user.id);
            written += 1;
        };
        while (written < limit) : (written += 1) try pack.nil();
    } else try pack.nil();
}

fn writeRoom(pack: MessagePackWriter, room: *const Room) !void {
    try pack.array(9);
    try pack.integer(room.id);
    try pack.integer(room.state);
    try writeSettings(pack, room.settings);
    try pack.array(room.user_count);
    for (room.users) |entry| if (entry) |user| try writeUser(pack, user);
    if (room.userIndex(room.host_id)) |host_index| {
        try writeUser(pack, room.users[host_index].?);
    } else {
        const host = try defaultRoomUser(room.host_id, room.host_name.slice(), room.host_country);
        try writeUser(pack, host);
    }
    try writeMatchState(pack, room);
    try pack.array(room.playlist_count);
    for (room.playlist) |entry| if (entry) |item| try writePlaylistItem(pack, item);
    try pack.array(0);
    try pack.integer(room.channel_id);
}

fn writeApiUserJson(writer: *std.Io.Writer, id: i32, name: []const u8, country: [2]u8) !void {
    try writer.print("{{\"id\":{d},\"username\":", .{id});
    try std.json.Stringify.value(name, .{}, writer);
    try writer.print(",\"avatar_url\":\"https://a.kai.ovh/{d}\",\"country_code\":", .{id});
    try std.json.Stringify.value(country[0..], .{}, writer);
    try writer.writeAll(",\"is_active\":true,\"is_supporter\":true}");
}

fn writePlaylistItemJson(writer: *std.Io.Writer, item: PlaylistItem) !void {
    const mode: []const u8 = switch (item.ruleset_id) {
        0 => "osu",
        1 => "taiko",
        2 => "fruits",
        else => "mania",
    };
    try writer.print("{{\"id\":{d},\"owner_id\":{d},\"ruleset_id\":{d},\"expired\":{s},\"playlist_order\":{d},\"played_at\":null,\"allowed_mods\":[],\"required_mods\":[],\"beatmap_id\":{d},\"beatmap\":{{\"id\":{d},\"beatmapset_id\":{d},\"mode\":", .{ item.id, item.owner_id, item.ruleset_id, if (item.expired) "true" else "false", item.order, item.beatmap_id, item.beatmap_id, item.beatmap_id });
    try std.json.Stringify.value(mode, .{}, writer);
    try writer.writeAll(",\"status\":\"ranked\",\"version\":\"online beatmap\",\"difficulty_rating\":");
    try writer.print("{d},\"checksum\":", .{item.star_rating});
    try std.json.Stringify.value(item.checksum.slice(), .{}, writer);
    try writer.print(",\"beatmapset\":{{\"id\":{d},\"artist\":\"online beatmap\",\"artist_unicode\":\"online beatmap\",\"title\":\"beatmap {d}\",\"title_unicode\":\"beatmap {d}\",\"creator\":\"unknown\",\"covers\":{{}}}}}},\"freestyle\":{s}}}", .{ item.beatmap_id, item.beatmap_id, item.beatmap_id, if (item.freestyle) "true" else "false" });
}

fn writeRoomJson(writer: *std.Io.Writer, room: *const Room) !void {
    try writer.print("{{\"id\":{d},\"name\":", .{room.id});
    try std.json.Stringify.value(room.settings.name.slice(), .{}, writer);
    try writer.print(",\"description\":null,\"has_password\":{s},\"host\":", .{if (room.settings.password.len != 0) "true" else "false"});
    try writeApiUserJson(writer, room.host_id, room.host_name.slice(), room.host_country);
    try writer.writeAll(",\"category\":\"normal\",\"duration\":null,\"starts_at\":null,\"ends_at\":null,\"max_participants\":");
    if (room.settings.max_participants) |limit| try writer.print("{d}", .{limit}) else try writer.writeAll("null");
    try writer.print(",\"participant_count\":{d},\"recent_participants\":[", .{room.user_count});
    var users_written: usize = 0;
    for (room.users) |entry| if (entry) |user| {
        if (users_written != 0) try writer.writeByte(',');
        try writeApiUserJson(writer, user.id, user.name.slice(), user.country);
        users_written += 1;
    };
    const match_type: []const u8 = switch (room.settings.match_type) {
        2 => "team_versus",
        3 => "matchmaking",
        4 => "ranked_play",
        else => "head_to_head",
    };
    const queue_mode: []const u8 = switch (room.settings.queue_mode) {
        1 => "all_players",
        2 => "all_players_round_robin",
        else => "host_only",
    };
    try writer.writeAll("],\"max_attempts\":null,\"playlist\":[");
    var playlist_written: usize = 0;
    var active_playlist_items: usize = 0;
    for (room.playlist) |entry| if (entry) |item| {
        if (playlist_written != 0) try writer.writeByte(',');
        try writePlaylistItemJson(writer, item);
        playlist_written += 1;
        if (!item.expired) active_playlist_items += 1;
    };
    try writer.print("],\"playlist_item_stats\":{{\"count_active\":{d},\"count_total\":{d},\"ruleset_ids\":[]}},\"difficulty_range\":null,\"type\":", .{ active_playlist_items, room.playlist_count });
    try std.json.Stringify.value(match_type, .{}, writer);
    try writer.writeAll(",\"queue_mode\":");
    try std.json.Stringify.value(queue_mode, .{}, writer);
    try writer.print(",\"auto_skip\":{s},\"auto_start_duration\":0,\"current_user_score\":null,\"current_playlist_item\":", .{if (room.settings.auto_skip) "true" else "false"});
    const current = room.playlist[room.itemIndex(room.settings.playlist_item_id) orelse 0] orelse return error.MultiplayerPlaylistItemNotFound;
    try writePlaylistItemJson(writer, current);
    try writer.print(",\"channel_id\":{d},\"status\":\"{s}\",\"pinned\":false}}", .{ room.channel_id, if (room.state == 0) "idle" else "playing" });
}

pub fn frameOwned(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    if (body.len == 0 or body.len > max_hub_message) return error.MultiplayerPayloadTooLarge;
    var prefix: [5]u8 = undefined;
    var remaining = body.len;
    var prefix_len: usize = 0;
    while (true) {
        var byte_value: u8 = @intCast(remaining & 0x7f);
        remaining >>= 7;
        if (remaining != 0) byte_value |= 0x80;
        prefix[prefix_len] = byte_value;
        prefix_len += 1;
        if (remaining == 0) break;
    }
    const output = try allocator.alloc(u8, prefix_len + body.len);
    @memcpy(output[0..prefix_len], prefix[0..prefix_len]);
    @memcpy(output[prefix_len..], body);
    return output;
}

pub fn allocatingFrame(allocator: std.mem.Allocator, output: *std.Io.Writer.Allocating) ![]u8 {
    const body = output.written();
    return frameOwned(allocator, body);
}

pub fn completionVoidOwned(allocator: std.mem.Allocator, invocation_id: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try pack.array(4);
    try pack.integer(3);
    try pack.map(0);
    try pack.string(invocation_id);
    try pack.integer(2);
    return allocatingFrame(allocator, &output);
}

pub fn completionErrorOwned(allocator: std.mem.Allocator, invocation_id: []const u8, message: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try pack.array(5);
    try pack.integer(3);
    try pack.map(0);
    try pack.string(invocation_id);
    try pack.integer(1);
    try pack.string(message);
    return allocatingFrame(allocator, &output);
}

fn completionRoomOwned(allocator: std.mem.Allocator, invocation_id: []const u8, room: *const Room) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try pack.array(5);
    try pack.integer(3);
    try pack.map(0);
    try pack.string(invocation_id);
    try pack.integer(3);
    try writeRoom(pack, room);
    return allocatingFrame(allocator, &output);
}

fn completionEmptyObjectOwned(allocator: std.mem.Allocator, invocation_id: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try pack.array(5);
    try pack.integer(3);
    try pack.map(0);
    try pack.string(invocation_id);
    try pack.integer(3);
    try pack.array(0);
    return allocatingFrame(allocator, &output);
}

fn completionMatchmakingPoolsOwned(allocator: std.mem.Allocator, invocation_id: []const u8, pool_type: u8, available: [4]bool) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try pack.array(5);
    try pack.integer(3);
    try pack.map(0);
    try pack.string(invocation_id);
    try pack.integer(3);
    var count: usize = 0;
    if (pool_type == 0) for (available) |enabled| if (enabled) {
        count += 1;
    };
    try pack.array(count);
    const names = [_][]const u8{ "quick play", "quick play", "quick play", "quick play" };
    for (available, 0..) |enabled, mode| {
        if (!enabled or pool_type != 0) continue;
        try pack.array(5);
        try pack.integer(@as(i64, @intCast(mode + 1)));
        try pack.integer(@intCast(mode));
        try pack.integer(0);
        try pack.string(names[mode]);
        try pack.integer(0);
    }
    return allocatingFrame(allocator, &output);
}

pub fn beginEvent(pack: MessagePackWriter, target: []const u8, argument_count: usize) !void {
    try pack.array(6);
    try pack.integer(1);
    try pack.map(0);
    try pack.nil();
    try pack.string(target);
    try pack.array(argument_count);
}

pub fn endEvent(pack: MessagePackWriter) !void {
    try pack.array(0);
}

fn eventNoArgsOwned(allocator: std.mem.Allocator, target: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, target, 0);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventQueueStatusOwned(allocator: std.mem.Allocator, status: u8) ![]u8 {
    if (status > 2) return error.InvalidMatchmakingQueueStatus;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchmakingQueueStatusChanged", 1);
    try pack.array(2);
    try pack.integer(status);
    try pack.array(0);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventMatchmakingInvitationOwned(allocator: std.mem.Allocator, pool_type: u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchmakingRoomInvitedWithParams", 1);
    try pack.array(1);
    try pack.integer(pool_type);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventMatchmakingRoomReadyOwned(allocator: std.mem.Allocator, room_id: i64, password: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchmakingRoomReady", 2);
    try pack.integer(room_id);
    try pack.string(password);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventLobbyStatusOwned(allocator: std.mem.Allocator, users: []const i32) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchmakingLobbyStatusChanged", 1);
    try pack.array(4);
    try pack.array(users.len);
    for (users) |user_id| try pack.integer(user_id);
    try pack.array(if (users.len == 0) 0 else 1);
    if (users.len != 0) {
        try pack.array(2);
        try pack.integer(1500);
        try pack.integer(@intCast(users.len));
    }
    try pack.integer(1500);
    try pack.array(0);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventMatchStateOwned(allocator: std.mem.Allocator, room: *const Room) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchRoomStateChanged", 1);
    try writeMatchState(pack, room);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventIntegersOwned(allocator: std.mem.Allocator, target: []const u8, values: []const i64) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, target, values.len);
    for (values) |value| try pack.integer(value);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventUserOwned(allocator: std.mem.Allocator, target: []const u8, user: RoomUser) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, target, 1);
    try writeUser(pack, user);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventSettingsOwned(allocator: std.mem.Allocator, target: []const u8, settings: Settings) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, target, 1);
    try writeSettings(pack, settings);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventPlaylistOwned(allocator: std.mem.Allocator, target: []const u8, item: PlaylistItem) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, target, 1);
    try writePlaylistItem(pack, item);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventIntegerRawOwned(allocator: std.mem.Allocator, target: []const u8, user_id: i32, raw: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, target, 2);
    try pack.integer(user_id);
    try pack.raw(raw);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventIntegerBoolOwned(allocator: std.mem.Allocator, target: []const u8, user_id: i32, value: bool) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, target, 2);
    try pack.integer(user_id);
    try pack.boolean(value);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventStyleOwned(allocator: std.mem.Allocator, user_id: i32, beatmap_id: ?i32, ruleset_id: ?i32) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "UserStyleChanged", 3);
    try pack.integer(user_id);
    if (beatmap_id) |value| try pack.integer(value) else try pack.nil();
    if (ruleset_id) |value| try pack.integer(value) else try pack.nil();
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventInviteOwned(allocator: std.mem.Allocator, invited_by: i32, room_id: i64, password: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "Invited", 3);
    try pack.integer(invited_by);
    try pack.integer(room_id);
    try pack.string(password);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn pingOwned(allocator: std.mem.Allocator) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try pack.array(1);
    try pack.integer(6);
    return allocatingFrame(allocator, &output);
}

pub fn parseRoomPath(path: []const u8) ?i64 {
    const prefix = "/api/v2/rooms/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    if (rest.len == 0 or std.mem.indexOfScalar(u8, rest, '/') != null) return null;
    const id = std.fmt.parseInt(i64, rest, 10) catch return null;
    return if (id > 0) id else null;
}

pub fn parseRoomScorePath(path: []const u8) ?RoomScorePath {
    const prefix = "/api/v2/rooms/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    var parts = std.mem.splitScalar(u8, path[prefix.len..], '/');
    const room_text = parts.next() orelse return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "playlist")) return null;
    const playlist_text = parts.next() orelse return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "scores")) return null;
    const token_text = parts.next();
    if (parts.next() != null) return null;
    const room_id = std.fmt.parseInt(i64, room_text, 10) catch return null;
    const playlist_item_id = std.fmt.parseInt(i64, playlist_text, 10) catch return null;
    const token_id = if (token_text) |value| std.fmt.parseInt(i64, value, 10) catch return null else null;
    if (room_id <= 0 or playlist_item_id <= 0 or (token_id != null and token_id.? <= 0)) return null;
    return .{ .room_id = room_id, .playlist_item_id = playlist_item_id, .token_id = token_id };
}

pub fn negotiateJson(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var random: [24]u8 = undefined;
    try io.randomSecure(&random);
    var token: [32]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&token, &random);
    return std.fmt.allocPrint(allocator, "{{\"negotiateVersion\":1,\"connectionId\":\"{s}\",\"connectionToken\":\"{s}\",\"availableTransports\":[{{\"transport\":\"WebSockets\",\"transferFormats\":[\"Binary\"]}}]}}", .{ &token, &token });
}

pub fn validSignalRHandshake(allocator: std.mem.Allocator, data: []const u8) bool {
    if (data.len < 2 or data[data.len - 1] != 0x1e or std.mem.indexOfScalar(u8, data[0 .. data.len - 1], 0x1e) != null) return false;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data[0 .. data.len - 1], .{}) catch return false;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const protocol = object.get("protocol") orelse return false;
    const version = object.get("version") orelse return false;
    return switch (protocol) {
        .string => |value| std.mem.eql(u8, value, "messagepack"),
        else => false,
    } and switch (version) {
        .integer => |value| value == 1,
        else => false,
    };
}

test "bounded messagepack framing accepts a room snapshot and rejects nested bombs" {
    var body: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer body.deinit();
    const pack: MessagePackWriter = .{ .writer = &body.writer };
    try pack.array(3);
    try pack.integer(1);
    try pack.string("room");
    try pack.boolean(true);
    var reader: MessagePackReader = .{ .data = body.written() };
    try std.testing.expectEqual(@as(usize, 3), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 1), try reader.integer());
    try std.testing.expectEqualStrings("room", try reader.string());
    try std.testing.expect(try reader.boolean());

    const nested = [_]u8{0x91} ** 17 ++ [_]u8{0xc0};
    var nested_reader: MessagePackReader = .{ .data = &nested };
    try std.testing.expectError(error.MessagePackNestingTooDeep, nested_reader.skip(0));
}

test "lazer multiplayer room path only accepts exact positive ids" {
    try std.testing.expectEqual(@as(?i64, 42), parseRoomPath("/api/v2/rooms/42"));
    try std.testing.expectEqual(@as(?i64, null), parseRoomPath("/api/v2/rooms/42/scores"));
    try std.testing.expectEqual(@as(?i64, null), parseRoomPath("/api/v2/rooms/0"));
}

test "lazer multiplayer score path separates room playlist and token ids" {
    const create = parseRoomScorePath("/api/v2/rooms/5/playlist/8/scores").?;
    try std.testing.expectEqual(@as(i64, 5), create.room_id);
    try std.testing.expectEqual(@as(i64, 8), create.playlist_item_id);
    try std.testing.expectEqual(@as(?i64, null), create.token_id);
    const submit = parseRoomScorePath("/api/v2/rooms/5/playlist/8/scores/13").?;
    try std.testing.expectEqual(@as(?i64, 13), submit.token_id);
    try std.testing.expectEqual(@as(?RoomScorePath, null), parseRoomScorePath("/api/v2/rooms/5/playlist/users/scores"));
}

test "signalr accepts messagepack handshake bytes independent of websocket opcode" {
    try std.testing.expect(validSignalRHandshake(std.testing.allocator, "{\"protocol\":\"messagepack\",\"version\":1}\x1e"));
    try std.testing.expect(validSignalRHandshake(std.testing.allocator, "{\"version\":1,\"protocol\":\"messagepack\"}\x1e"));
    try std.testing.expect(!validSignalRHandshake(std.testing.allocator, "{\"protocol\":\"json\",\"version\":1}\x1e"));
    try std.testing.expect(!validSignalRHandshake(std.testing.allocator, "{\"protocol\":\"messagepack\",\"version\":1}"));
}

test "matchmaking placements use lower-equal ties and aggregate round points" {
    var state: MatchmakingState = .{};
    state.current_round = 2;
    state.user_count = 2;
    state.users[0] = .{ .id = 10 };
    state.users[1] = .{ .id = 20 };
    state.users[0].?.rounds[0] = .{ .round = 1, .total_score = 500, .passed = true };
    state.users[1].?.rounds[0] = .{ .round = 1, .total_score = 500, .passed = false };
    state.users[0].?.rounds[1] = .{ .round = 2, .total_score = 100, .passed = true };
    state.users[1].?.rounds[1] = .{ .round = 2, .total_score = 900, .passed = true };

    recomputeMatchmakingPlacements(&state);

    try std.testing.expectEqual(@as(u8, 2), state.users[0].?.rounds[0].?.placement);
    try std.testing.expectEqual(@as(u8, 2), state.users[1].?.rounds[0].?.placement);
    try std.testing.expectEqual(@as(i32, 27), state.users[1].?.points);
    try std.testing.expectEqual(@as(i32, 24), state.users[0].?.points);
    try std.testing.expectEqual(@as(?u8, 1), state.users[1].?.placement);
    try std.testing.expectEqual(@as(?u8, 2), state.users[0].?.placement);
}
