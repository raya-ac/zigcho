const std = @import("std");
const telemetry = @import("../telemetry.zig");

pub const Kind = enum { stable_sessions, lazer_state };

pub fn Measured(comptime kind: Kind) type {
    return struct {
        const Self = @This();
        const wait_operation: telemetry.Operation = if (kind == .stable_sessions) .stable_sessions_wait else .lazer_state_wait;
        const hold_operation: telemetry.Operation = if (kind == .stable_sessions) .stable_sessions_hold else .lazer_state_hold;

        inner: std.Io.Mutex = .init,
        // Only the owning thread accesses this field while holding inner.
        acquired_at: u64 = 0,

        pub const init: Self = .{};

        pub fn lockUncancelable(self: *Self, io: std.Io) void {
            const timer = telemetry.Timer.start(wait_operation);
            self.inner.lockUncancelable(io);
            self.acquired_at = telemetry.clock.now();
            timer.finish();
        }

        pub fn lock(self: *Self, io: std.Io) std.Io.Cancelable!void {
            const timer = telemetry.Timer.start(wait_operation);
            defer timer.finish();
            try self.inner.lock(io);
            self.acquired_at = telemetry.clock.now();
        }

        pub fn tryLock(self: *Self) bool {
            const timer = telemetry.Timer.start(wait_operation);
            if (!self.inner.tryLock()) return false;
            self.acquired_at = telemetry.clock.now();
            timer.finish();
            return true;
        }

        pub fn unlock(self: *Self, io: std.Io) void {
            const elapsed = telemetry.clock.elapsed(self.acquired_at);
            self.acquired_at = 0;
            self.inner.unlock(io);
            if (elapsed) |duration| telemetry.observe(hold_operation, duration);
        }
    };
}
