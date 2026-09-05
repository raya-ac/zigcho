const std = @import("std");
const max_connections = @import("../../lazer_multiplayer.zig").max_connections;
const Text64 = @import("../../lazer_multiplayer.zig").Text64;
const RoomUser = @import("../../lazer_multiplayer.zig").RoomUser;
const Room = @import("../rooms/model.zig").Room;

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
    invocation_mutex: std.Io.Mutex = .init,
    write_mutex: std.Io.Mutex = .init,
    socket: ?*std.http.Server.WebSocket = null,
    alive: std.atomic.Value(bool) = .init(true),
    accepting_invocations: std.atomic.Value(bool) = .init(true),

    pub fn retain(self: *Connection) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *Connection) void {
        if (self.references.fetchSub(1, .release) == 1) {
            _ = self.references.load(.acquire);
            self.allocator.destroy(self);
        }
    }

    pub fn send(self: *Connection, frame: []const u8) void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (!self.alive.load(.acquire)) return;
        const socket = self.socket orelse return;
        socket.writeMessage(frame, .binary) catch {
            self.accepting_invocations.store(false, .release);
            self.alive.store(false, .release);
        };
    }

    pub fn close(self: *Connection) void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        self.accepting_invocations.store(false, .release);
        if (self.alive.load(.acquire)) if (self.socket) |socket| socket.writeMessage("", .connection_close) catch {};
        self.alive.store(false, .release);
        self.socket = null;
    }
};

pub const DisconnectEffects = struct {
    recipients: [max_connections]*Connection = undefined,
    recipient_count: usize = 0,
    left_user: ?RoomUser = null,
    new_host: ?i32 = null,
    ranked_ended: bool = false,
    ranked_room_id: ?i64 = null,
    ended_room: ?*Room = null,
    ranked_event: ?[]u8 = null,
    queue_peer: ?*Connection = null,
    queue_peer_left: bool = false,
    queue_pool_id: ?i32 = null,
};
