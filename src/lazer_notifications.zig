const std = @import("std");

pub const max_message_bytes = 8 * 1024;

pub fn validClientMessage(allocator: std.mem.Allocator, data: []const u8) bool {
    if (data.len == 0 or data.len > max_message_bytes or !std.unicode.utf8ValidateSlice(data)) return false;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return false;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const event = switch (object.get("event") orelse return false) {
        .string => |value| value,
        else => return false,
    };
    return std.mem.eql(u8, event, "chat.start") or std.mem.eql(u8, event, "chat.end") or std.mem.eql(u8, event, "ping");
}

pub fn serve(allocator: std.mem.Allocator, user_id: i32, socket: *std.http.Server.WebSocket) !void {
    std.log.info("event=lazer_notifications_connected user_id={d}", .{user_id});
    defer std.log.info("event=lazer_notifications_disconnected user_id={d}", .{user_id});
    while (true) {
        const message = socket.readSmallMessage() catch return;
        switch (message.opcode) {
            .ping => try socket.writeMessage(message.data, .pong),
            .pong => {},
            .connection_close => return,
            .text => {
                if (!validClientMessage(allocator, message.data)) return error.InvalidNotificationMessage;
            },
            else => return error.InvalidNotificationMessage,
        }
    }
}

test "notification websocket only accepts the pinned client control messages" {
    try std.testing.expect(validClientMessage(std.testing.allocator, "{\"event\":\"chat.start\"}"));
    try std.testing.expect(validClientMessage(std.testing.allocator, "{\"event\":\"chat.end\",\"data\":null}"));
    try std.testing.expect(!validClientMessage(std.testing.allocator, "{\"event\":\"logout\"}"));
    try std.testing.expect(!validClientMessage(std.testing.allocator, "[]"));
}
