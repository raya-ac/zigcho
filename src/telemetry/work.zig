const std = @import("std");
const clock = @import("clock.zig");

pub const Kind = enum { postgres_pool, media_slots, beatmap_hydration };
// The HTTP admission limit is at most 4096. This bounds observation storage;
// exhausting it drops a metric sample, never changes admission of real work.
pub const capacity = 4096;

const Queue = struct {
    slots: [capacity]std.atomic.Value(u64) = @splat(.init(0)),
    cursor: std.atomic.Value(usize) = .init(0),
    untracked: std.atomic.Value(u64) = .init(0),
    rejected: std.atomic.Value(u64) = .init(0),
};

var queues: [std.meta.fields(Kind).len]Queue = @splat(.{});

pub const Ticket = struct {
    kind: Kind,
    slot: ?usize,

    pub fn leave(self: Ticket) void {
        if (self.slot) |index| queues[@intFromEnum(self.kind)].slots[index].store(0, .release);
    }
};

pub fn enter(kind: Kind) Ticket {
    const queue = &queues[@intFromEnum(kind)];
    const started = clock.now();
    if (started == 0) return .{ .kind = kind, .slot = null };
    const first = queue.cursor.fetchAdd(1, .monotonic) % capacity;
    for (0..capacity) |offset| {
        const slot = (first + offset) % capacity;
        if (queue.slots[slot].cmpxchgStrong(0, started, .acq_rel, .monotonic) == null) return .{ .kind = kind, .slot = slot };
    }
    _ = queue.untracked.fetchAdd(1, .monotonic);
    return .{ .kind = kind, .slot = null };
}

pub fn reject(kind: Kind) void {
    _ = queues[@intFromEnum(kind)].rejected.fetchAdd(1, .monotonic);
}

pub fn writePrometheus(writer: *std.Io.Writer) !void {
    try writer.writeAll("# HELP zigcho_work_pending Pending pool/media acquisitions or in-flight beatmap hydrations; not durable jobs.\n# TYPE zigcho_work_pending gauge\n# TYPE zigcho_work_oldest_seconds gauge\n# TYPE zigcho_work_rejected_total counter\n# TYPE zigcho_work_untracked_total counter\n");
    inline for (std.meta.fields(Kind)) |field| {
        const queue = &queues[field.value];
        var count: u64 = 0;
        var oldest: u64 = std.math.maxInt(u64);
        for (&queue.slots) |*slot| {
            const started = slot.load(.acquire);
            if (started == 0) continue;
            count += 1;
            oldest = @min(oldest, started);
        }
        const age = if (count == 0) 0 else clock.elapsed(oldest) orelse 0;
        try writer.print("zigcho_work_pending{{queue=\"{s}\"}} {d}\nzigcho_work_oldest_seconds{{queue=\"{s}\"}} {d}\nzigcho_work_rejected_total{{queue=\"{s}\"}} {d}\nzigcho_work_untracked_total{{queue=\"{s}\"}} {d}\n", .{ field.name, count, field.name, @as(f64, @floatFromInt(age)) / std.time.ns_per_s, field.name, queue.rejected.load(.monotonic), field.name, queue.untracked.load(.monotonic) });
    }
}
