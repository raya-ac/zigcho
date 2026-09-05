const std = @import("std");

// Microseconds; the final bucket is +Inf. Labels and storage never grow with
// traffic. Quantiles are bucket upper bounds, not exact sampled percentiles.
pub const bounds = [_]u64{ 100, 250, 500, 1000, 2500, 5000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000, 2_500_000, 5_000_000, 10_000_000, 30_000_000, 60_000_000, 120_000_000, 300_000_000 };

pub const Snapshot = struct {
    buckets: [bounds.len + 1]u64,
    sum_us: u64,

    pub fn count(self: Snapshot) u64 {
        var total: u64 = 0;
        for (self.buckets) |value| total +|= value;
        return total;
    }

    pub fn percentile(self: Snapshot, percentage: u8) ?u64 {
        const total = self.count();
        if (total == 0) return 0;
        const target = (@as(u128, total) * percentage + 99) / 100;
        var cumulative: u64 = 0;
        for (self.buckets, 0..) |value, index| {
            cumulative +|= value;
            if (cumulative >= target) return if (index < bounds.len) bounds[index] else null;
        }
        return null;
    }
};

pub const Histogram = struct {
    buckets: [bounds.len + 1]std.atomic.Value(u64) = @splat(.init(0)),
    sum_us: std.atomic.Value(u64) = .init(0),

    pub fn observe(self: *Histogram, nanoseconds: u64) void {
        const microseconds = nanoseconds / 1000 + @intFromBool(nanoseconds % 1000 != 0);
        var index: usize = 0;
        while (index < bounds.len and microseconds > bounds[index]) : (index += 1) {}
        _ = self.buckets[index].fetchAdd(1, .monotonic);
        _ = self.sum_us.fetchAdd(microseconds, .monotonic);
    }

    pub fn snapshot(self: *const Histogram) Snapshot {
        var result: Snapshot = .{ .buckets = undefined, .sum_us = self.sum_us.load(.monotonic) };
        for (&result.buckets, &self.buckets) |*value, *bucket| value.* = bucket.load(.monotonic);
        return result;
    }
};

test "latency histogram keeps overflow and quantile upper bounds honest" {
    var histogram: Histogram = .{};
    histogram.observe(100_000);
    histogram.observe(250_000);
    histogram.observe(300_000_000_001);
    const snapshot = histogram.snapshot();
    try std.testing.expectEqual(@as(u64, 3), snapshot.count());
    try std.testing.expectEqual(@as(?u64, 250), snapshot.percentile(50));
    try std.testing.expectEqual(@as(?u64, null), snapshot.percentile(99));
    try std.testing.expectEqual(@as(u64, 300_000_351), snapshot.sum_us);
}
