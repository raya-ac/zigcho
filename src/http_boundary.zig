const std = @import("std");
const routing = @import("routing.zig");

pub const Gate = struct {
    limit: u32,
    active: std.atomic.Value(u32) = .init(0),
    rejected: std.atomic.Value(u64) = .init(0),
    timed_out: std.atomic.Value(u64) = .init(0),

    pub fn init(limit: u32) Gate {
        std.debug.assert(limit > 0);
        return .{ .limit = limit };
    }

    pub fn tryAcquire(self: *Gate) bool {
        const previous = self.active.fetchAdd(1, .acq_rel);
        if (previous < self.limit) return true;
        const active_before_release = self.active.fetchSub(1, .acq_rel);
        std.debug.assert(active_before_release > 0);
        _ = self.rejected.fetchAdd(1, .acq_rel);
        return false;
    }

    pub fn release(self: *Gate) void {
        const previous = self.active.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
    }

    pub fn recordTimeout(self: *Gate) void {
        _ = self.timed_out.fetchAdd(1, .acq_rel);
    }
};

pub fn requestDeadlineSeconds(method: std.http.Method, target: []const u8, normal_seconds: u16, long_seconds: u16) ?u16 {
    const query = std.mem.findScalar(u8, target, '?') orelse target.len;
    const path = routing.canonicalPath(target[0..query]);
    if (std.mem.eql(u8, path, "/multiplayer") or
        std.mem.eql(u8, path, "/spectator") or
        std.mem.eql(u8, path, "/notification-endpoint")) return null;
    if (method == .PUT or method == .PATCH or
        std.mem.startsWith(u8, path, "/d/") or
        std.mem.endsWith(u8, path, "/download") or
        std.mem.eql(u8, path, "/web/osu-submit-modular-selector.php") or
        std.mem.eql(u8, path, "/web/osu-screenshot.php") or
        std.mem.eql(u8, path, "/api/v2/scores") or
        std.mem.endsWith(u8, path, "/solo/scores") or
        (std.mem.indexOf(u8, path, "/playlist/") != null and std.mem.endsWith(u8, path, "/scores")) or
        std.mem.eql(u8, path, "/api/v1/account/avatar") or
        std.mem.eql(u8, path, "/api/v1/account/banner") or
        std.mem.endsWith(u8, path, "/flag") or
        std.mem.endsWith(u8, path, "/header")) return long_seconds;
    return normal_seconds;
}
