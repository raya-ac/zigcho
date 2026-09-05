const std = @import("std");
const builtin = @import("builtin");

// Metrics must not depend on wall-clock corrections or request-owned Io state.
// A failed clock read drops the observation rather than inventing a duration.
pub fn now() u64 {
    if (builtin.os.tag == .windows) {
        var counter: i64 = 0;
        var frequency: i64 = 0;
        if (std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter) == 0 or
            std.os.windows.ntdll.RtlQueryPerformanceFrequency(&frequency) == 0 or
            counter < 0 or frequency <= 0) return 0;
        return @intCast(@as(u128, @intCast(counter)) * std.time.ns_per_s / @as(u64, @intCast(frequency)));
    }
    var value: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &value) != 0 or value.sec < 0 or value.nsec < 0) return 0;
    return @as(u64, @intCast(value.sec)) *| std.time.ns_per_s +| @as(u64, @intCast(value.nsec));
}

pub fn elapsed(started: u64) ?u64 {
    const finished = now();
    if (started == 0 or finished < started) return null;
    return finished - started;
}
