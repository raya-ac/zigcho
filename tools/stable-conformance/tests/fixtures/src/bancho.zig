fn pollLocked() void {
    while (try reader.next()) |packet| switch (packet.id) {
        .ping => {},
        .logout => {},
        else => {},
    };
}
