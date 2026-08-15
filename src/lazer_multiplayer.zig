const std = @import("std");
const domain = @import("domain.zig");

pub const max_rooms = 64;
pub const max_connections = 128;
pub const max_users = 16;
pub const max_playlist = 32;
const max_hub_message = 60 * 1024;

pub const RoomScorePath = struct {
    room_id: i64,
    playlist_item_id: i64,
    token_id: ?i64,
};

pub const RoomScoreContext = struct {
    beatmap_id: i32,
    ruleset_id: u8,
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

const MessagePackReader = struct {
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

    fn arrayLen(self: *MessagePackReader) !usize {
        const tag = try self.byte();
        if (tag >= 0x90 and tag <= 0x9f) return tag & 0x0f;
        return switch (tag) {
            0xdc => try self.readUnsigned(u16),
            0xdd => std.math.cast(usize, try self.readUnsigned(u32)) orelse error.MultiplayerPayloadTooLarge,
            else => error.ExpectedMessagePackArray,
        };
    }

    fn mapLen(self: *MessagePackReader) !usize {
        const tag = try self.byte();
        if (tag >= 0x80 and tag <= 0x8f) return tag & 0x0f;
        return switch (tag) {
            0xde => try self.readUnsigned(u16),
            0xdf => std.math.cast(usize, try self.readUnsigned(u32)) orelse error.MultiplayerPayloadTooLarge,
            else => error.ExpectedMessagePackMap,
        };
    }

    fn string(self: *MessagePackReader) ![]const u8 {
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

    fn integer(self: *MessagePackReader) !i64 {
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

    fn boolean(self: *MessagePackReader) !bool {
        return switch (try self.byte()) {
            0xc2 => false,
            0xc3 => true,
            else => error.ExpectedMessagePackBoolean,
        };
    }

    fn nullableInteger(self: *MessagePackReader) !?i64 {
        if (self.pos >= self.data.len) return error.TruncatedMessagePack;
        if (self.data[self.pos] == 0xc0) {
            self.pos += 1;
            return null;
        }
        return try self.integer();
    }

    fn raw(self: *MessagePackReader) ![]const u8 {
        const start = self.pos;
        try self.skip(0);
        return self.data[start..self.pos];
    }

    fn skip(self: *MessagePackReader, depth: u8) !void {
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

const MessagePackWriter = struct {
    writer: *std.Io.Writer,

    fn array(self: MessagePackWriter, len: usize) !void {
        if (len <= 15) return self.writer.writeByte(0x90 | @as(u8, @intCast(len)));
        if (len <= std.math.maxInt(u16)) {
            try self.writer.writeByte(0xdc);
            return self.writer.writeInt(u16, @intCast(len), .big);
        }
        try self.writer.writeByte(0xdd);
        try self.writer.writeInt(u32, @intCast(len), .big);
    }

    fn map(self: MessagePackWriter, len: usize) !void {
        if (len <= 15) return self.writer.writeByte(0x80 | @as(u8, @intCast(len)));
        if (len <= std.math.maxInt(u16)) {
            try self.writer.writeByte(0xde);
            return self.writer.writeInt(u16, @intCast(len), .big);
        }
        try self.writer.writeByte(0xdf);
        try self.writer.writeInt(u32, @intCast(len), .big);
    }

    fn string(self: MessagePackWriter, value: []const u8) !void {
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

    fn integer(self: MessagePackWriter, value: i64) !void {
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

    fn float64(self: MessagePackWriter, value: f64) !void {
        try self.writer.writeByte(0xcb);
        try self.writer.writeInt(u64, @bitCast(value), .big);
    }

    fn nil(self: MessagePackWriter) !void {
        try self.writer.writeByte(0xc0);
    }

    fn boolean(self: MessagePackWriter, value: bool) !void {
        try self.writer.writeByte(if (value) 0xc3 else 0xc2);
    }

    fn raw(self: MessagePackWriter, value: []const u8) !void {
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
    state: u8 = 0,
    availability: Raw128 = .{},
    mods: Raw2048 = .{},
    ruleset_id: ?i32 = null,
    beatmap_id: ?i32 = null,
    voted_skip: bool = false,
    role: u8 = 0,
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

    fn userIndex(self: *const Room, user_id: i32) ?usize {
        for (self.users, 0..) |entry, index| if (entry) |user| if (user.id == user_id) return index;
        return null;
    }

    fn itemIndex(self: *const Room, item_id: i64) ?usize {
        for (self.playlist, 0..) |entry, index| if (entry) |item| if (item.id == item_id) return index;
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
    mutex: std.Io.Mutex = .init,
    rooms: [max_rooms]?*Room = [_]?*Room{null} ** max_rooms,
    connections: std.ArrayList(*Connection) = .empty,
    next_room_id: i64 = 1,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Manager {
        return .{ .allocator = allocator, .io = io };
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
        self.mutex.lockUncancelable(self.io);
        const count = self.leaveLocked(connection, &recipients, &left_user, &new_host);
        defer releaseRecipients(recipients[0..count]);
        self.removeConnectionLocked(connection);
        self.mutex.unlock(self.io);
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
        joined = defaultRoomUser(connection.user_id);
        room.users[user_slot] = joined;
        room.user_count += 1;
        connection.room_id = room_id;
        const count = self.recipientsLocked(room_id, connection, &recipients);
        defer releaseRecipients(recipients[0..count]);
        response = completionRoomOwned(self.allocator, id, room) catch |err| {
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
        var started_user_ids: [max_users]i32 = undefined;
        var started_user_count: usize = 0;
        var results_ready = false;
        var changed_room_state: ?i32 = null;
        var emitted_user_state: u8 = new_state;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const user_index = room.userIndex(connection.user_id).?;
        room.users[user_index].?.state = new_state;
        if (new_state == 6) room.users[user_index].?.state = 7;
        emitted_user_state = room.users[user_index].?.state;
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        if (new_state == 3 or new_state == 4) {
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
                            started_user_ids[started_user_count] = user.id;
                            started_user_count += 1;
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
            }
        }
        self.mutex.unlock(self.io);
        defer releaseRecipients(start_players[0..start_count]);
        const user_state_event = try eventIntegersOwned(self.allocator, "UserStateChanged", &.{ connection.user_id, emitted_user_state });
        defer self.allocator.free(user_state_event);
        sendRecipients(recipients[0..count], user_state_event);
        for (started_user_ids[0..started_user_count]) |user_id| {
            const event = try eventIntegersOwned(self.allocator, "UserStateChanged", &.{ user_id, 5 });
            defer self.allocator.free(event);
            sendRecipients(recipients[0..count], event);
        }
        if (changed_room_state) |state| {
            const event = try eventIntegersOwned(self.allocator, "RoomStateChanged", &.{state});
            defer self.allocator.free(event);
            sendRecipients(recipients[0..count], event);
        }
        if (start_count != 0) {
            const event = try eventNoArgsOwned(self.allocator, "GameplayStarted");
            defer self.allocator.free(event);
            sendRecipients(start_players[0..start_count], event);
        }
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
};

fn defaultRoomUser(user_id: i32) RoomUser {
    var user: RoomUser = .{ .id = user_id };
    user.availability.bytes[0] = 0x92;
    user.availability.bytes[1] = 0x00;
    user.availability.bytes[2] = 0xc0;
    user.availability.len = 3;
    user.mods.bytes[0] = 0x90;
    user.mods.len = 1;
    return user;
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
    room.users[0] = defaultRoomUser(connection.user_id);
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
    const host_index = room.userIndex(room.host_id) orelse return error.MultiplayerHostMissing;
    try writeUser(pack, room.users[host_index].?);
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
        const name = if (user.id == room.host_id) room.host_name.slice() else "player";
        const country = if (user.id == room.host_id) room.host_country else [2]u8{ 'X', 'X' };
        try writeApiUserJson(writer, user.id, name, country);
        users_written += 1;
    };
    const match_type: []const u8 = if (room.settings.match_type == 2) "team_versus" else "head_to_head";
    const queue_mode: []const u8 = switch (room.settings.queue_mode) {
        1 => "all_players",
        2 => "all_players_round_robin",
        else => "host_only",
    };
    try writer.writeAll("],\"max_attempts\":null,\"playlist\":[");
    var playlist_written: usize = 0;
    for (room.playlist) |entry| if (entry) |item| {
        if (playlist_written != 0) try writer.writeByte(',');
        try writePlaylistItemJson(writer, item);
        playlist_written += 1;
    };
    try writer.print("],\"playlist_item_stats\":{{\"count_active\":{d},\"count_total\":{d},\"ruleset_ids\":[]}},\"difficulty_range\":null,\"type\":", .{ room.playlist_count, room.playlist_count });
    try std.json.Stringify.value(match_type, .{}, writer);
    try writer.writeAll(",\"queue_mode\":");
    try std.json.Stringify.value(queue_mode, .{}, writer);
    try writer.print(",\"auto_skip\":{s},\"auto_start_duration\":0,\"current_user_score\":null,\"current_playlist_item\":", .{if (room.settings.auto_skip) "true" else "false"});
    const current = room.playlist[room.itemIndex(room.settings.playlist_item_id) orelse 0] orelse return error.MultiplayerPlaylistItemNotFound;
    try writePlaylistItemJson(writer, current);
    try writer.print(",\"channel_id\":{d},\"status\":\"{s}\",\"pinned\":false}}", .{ room.channel_id, if (room.state == 0) "idle" else "playing" });
}

fn frameOwned(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
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

fn allocatingFrame(allocator: std.mem.Allocator, output: *std.Io.Writer.Allocating) ![]u8 {
    const body = output.written();
    return frameOwned(allocator, body);
}

fn completionVoidOwned(allocator: std.mem.Allocator, invocation_id: []const u8) ![]u8 {
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

fn completionErrorOwned(allocator: std.mem.Allocator, invocation_id: []const u8, message: []const u8) ![]u8 {
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

fn beginEvent(pack: MessagePackWriter, target: []const u8, argument_count: usize) !void {
    try pack.array(6);
    try pack.integer(1);
    try pack.map(0);
    try pack.nil();
    try pack.string(target);
    try pack.array(argument_count);
}

fn endEvent(pack: MessagePackWriter) !void {
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

fn pingOwned(allocator: std.mem.Allocator) ![]u8 {
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

fn validSignalRHandshake(allocator: std.mem.Allocator, data: []const u8) bool {
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
