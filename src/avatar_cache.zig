const std = @import("std");

pub const max_entries: usize = 64;
pub const max_bytes: usize = 32 * 1024 * 1024;

const Entry = struct {
    key: []u8,
    data: []u8,
    last_used: u64,
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,
    bytes: usize = 0,
    clock: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Cache {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Cache) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.data);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn get(self: *Cache, key: []const u8) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.key, key)) continue;
            self.touch(entry);
            return try self.allocator.dupe(u8, entry.data);
        }
        return null;
    }

    pub fn put(self: *Cache, key: []const u8, data: []const u8) !void {
        if (data.len == 0 or data.len > max_bytes) return;
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_data = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(owned_data);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.removeLocked(key);
        while (self.entries.items.len >= max_entries or self.bytes + data.len > max_bytes) self.evictOldest();
        self.clock +%= 1;
        try self.entries.append(self.allocator, .{ .key = owned_key, .data = owned_data, .last_used = self.clock });
        self.bytes += data.len;
    }

    pub fn remove(self: *Cache, key: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.removeLocked(key);
    }

    fn touch(self: *Cache, entry: *Entry) void {
        self.clock +%= 1;
        entry.last_used = self.clock;
    }

    fn removeLocked(self: *Cache, key: []const u8) void {
        for (self.entries.items, 0..) |entry, index| {
            if (!std.mem.eql(u8, entry.key, key)) continue;
            const removed = self.entries.swapRemove(index);
            self.bytes -= removed.data.len;
            self.allocator.free(removed.key);
            self.allocator.free(removed.data);
            return;
        }
    }

    fn evictOldest(self: *Cache) void {
        var oldest: usize = 0;
        for (self.entries.items[1..], 1..) |entry, index| {
            if (entry.last_used < self.entries.items[oldest].last_used) oldest = index;
        }
        const removed = self.entries.swapRemove(oldest);
        self.bytes -= removed.data.len;
        self.allocator.free(removed.key);
        self.allocator.free(removed.data);
    }
};

test "avatar cache owns hits invalidates updates and stays bounded" {
    var cache = Cache.init(std.testing.allocator, std.testing.io);
    defer cache.deinit();
    try cache.put("4/avatar.png", "first");
    const hit = (try cache.get("4/avatar.png")).?;
    defer std.testing.allocator.free(hit);
    try std.testing.expectEqualStrings("first", hit);
    try cache.put("4/avatar.png", "second");
    const updated = (try cache.get("4/avatar.png")).?;
    defer std.testing.allocator.free(updated);
    try std.testing.expectEqualStrings("second", updated);
    cache.remove("4/avatar.png");
    try std.testing.expect((try cache.get("4/avatar.png")) == null);

    for (0..max_entries + 1) |index| {
        var key_buffer: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "avatar-{d}", .{index});
        try cache.put(key, "x");
    }
    try std.testing.expectEqual(max_entries, cache.entries.items.len);
    try std.testing.expect((try cache.get("avatar-0")) == null);
}
