fn dispatch(self: anytype, req: anytype, path: []const u8) !void {
    if (std.mem.eql(u8, path, "/web/bancho_connect.php")) return;
    if (req.head.method == .POST and std.mem.eql(u8, path, "/web/osu-submit-modular-selector.php")) {
        if (std.mem.eql(u8, path, "/web/osu-submit-modular-selector.php")) return;
    }
}
