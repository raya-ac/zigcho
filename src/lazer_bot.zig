const std = @import("std");
const commands = @import("commands.zig");
const domain = @import("domain.zig");
const protocol = @import("protocol.zig");
const sessions_mod = @import("sessions.zig");
const storage = @import("runtime_storage.zig");

const State = struct {
    mode: u8 = 0,
    mods: i32 = 0,
    map_id: i32 = 0,
    map_md5: [32]u8 = [_]u8{0} ** 32,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    states: std.AutoHashMap(i32, State),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Manager {
        return .{ .allocator = allocator, .io = io, .states = std.AutoHashMap(i32, State).init(allocator) };
    }

    pub fn deinit(self: *Manager) void {
        self.states.deinit();
    }

    pub fn replyOwned(
        self: *Manager,
        store: *storage.Store,
        sessions: *sessions_mod.Sessions,
        user: domain.User,
        text: []const u8,
        is_action: bool,
    ) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const entry = try self.states.getOrPut(user.id);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        var sender: sessions_mod.Session = .{
            .token = [_]u8{0} ** 64,
            .user = user,
            .mode = entry.value_ptr.mode,
            .mods = entry.value_ptr.mods,
            .map_id = entry.value_ptr.map_id,
            .map_md5 = entry.value_ptr.map_md5,
            .login_time = std.Io.Clock.real.now(self.io).toSeconds(),
            .last_seen = std.Io.Clock.real.now(self.io).toSeconds(),
        };
        defer sender.friend_ids.deinit(self.allocator);
        defer sender.queue.deinit(self.allocator);

        var command_output = protocol.Writer.init(self.allocator);
        defer command_output.deinit();
        var handled = false;
        if (is_action) {
            const action = try std.fmt.allocPrint(self.allocator, "\x01ACTION {s}\x01", .{text});
            defer self.allocator.free(action);
            handled = try commands.handleNowPlaying(self.allocator, store, &sender, action);
        }
        if (!handled) {
            handled = (try commands.handleCommand(self.allocator, store, sessions, &sender, text, user.name, &command_output)) == .handled;
        }

        entry.value_ptr.* = .{
            .mode = sender.mode,
            .mods = sender.mods,
            .map_id = sender.map_id,
            .map_md5 = sender.map_md5,
        };

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        try appendReplyTexts(&output.writer, command_output.bytes());
        try appendReplyTexts(&output.writer, sender.queue.items);
        if (output.written().len == 0) {
            try output.writer.writeAll(if (handled)
                "done"
            else
                "try !help, or use /np and then !with for a pp calc");
        }
        return output.toOwnedSlice();
    }
};

fn appendReplyTexts(output: *std.Io.Writer, packets: []const u8) !void {
    var reader: protocol.Reader = .{ .data = packets };
    while (try reader.next()) |packet| {
        if (@intFromEnum(packet.id) != @intFromEnum(protocol.ServerPacket.send_message)) continue;
        var payload: protocol.PayloadReader = .{ .data = packet.payload };
        _ = try payload.string();
        const text = try payload.string();
        _ = try payload.string();
        _ = try payload.int(i32);
        if (output.end != 0) try output.writeByte('\n');
        try output.writeAll(text);
    }
}

test "lazer bot extracts kai replies from stable packets" {
    var packets = protocol.Writer.init(std.testing.allocator);
    defer packets.deinit();
    try protocol.writeMessage(&packets, "kai", "first reply", "ari", 3);
    try protocol.writeMessage(&packets, "kai", "second reply", "ari", 3);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try appendReplyTexts(&output.writer, packets.bytes());
    try std.testing.expectEqualStrings("first reply\nsecond reply", output.written());
}
