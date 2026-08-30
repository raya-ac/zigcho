const d = @import("deps.zig");
const std = d.std;
const builtin = d.builtin;

pub var shutdown_requested: std.atomic.Value(bool) = .init(false);
pub var shutdown_listener_fd: std.atomic.Value(i64) = .init(-1);
pub var restart_requested: std.atomic.Value(bool) = .init(false);

pub fn requestShutdown(_: if (builtin.os.tag == .windows) c_int else std.posix.SIG) callconv(.c) void {
    shutdown_requested.store(true, .release);
    if (comptime builtin.os.tag != .windows) {
        const fd = shutdown_listener_fd.load(.acquire);
        if (fd >= 0) _ = std.c.shutdown(@intCast(fd), std.c.SHUT.RDWR);
    }
}

pub fn requestRestart() void {
    restart_requested.store(true, .release);
    shutdown_requested.store(true, .release);
    if (comptime builtin.os.tag != .windows) {
        const fd = shutdown_listener_fd.load(.acquire);
        if (fd >= 0) _ = std.c.shutdown(@intCast(fd), std.c.SHUT.RDWR);
    }
}
