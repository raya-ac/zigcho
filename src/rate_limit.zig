const std = @import("std");

pub const Rule = struct {
    name: []const u8,
    limit: u32,
    window_seconds: i64,
};

pub const registration: Rule = .{ .name = "registration", .limit = 5, .window_seconds = 3600 };
pub const token: Rule = .{ .name = "token", .limit = 20, .window_seconds = 60 };
pub const web_session: Rule = .{ .name = "web_session", .limit = 10, .window_seconds = 15 * 60 };
pub const web_action: Rule = .{ .name = "web_action", .limit = 120, .window_seconds = 60 };
pub const appeal: Rule = .{ .name = "appeal", .limit = 5, .window_seconds = 60 * 60 };
pub const login: Rule = .{ .name = "login", .limit = 30, .window_seconds = 60 };
pub const score: Rule = .{ .name = "score", .limit = 120, .window_seconds = 60 };
pub const authenticated: Rule = .{ .name = "authenticated", .limit = 600, .window_seconds = 60 };
pub const download: Rule = .{ .name = "download", .limit = 60, .window_seconds = 60 };

pub const Decision = struct {
    allowed: bool,
    remaining: u32,
    retry_after: u32,
    limit: u32,
};

const Entry = struct {
    count: u32,
    reset_at: i64,
};

pub const Limiter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    entries: std.StringHashMap(Entry),
    max_entries: usize = 16_384,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Limiter {
        return .{ .allocator = allocator, .io = io, .entries = std.StringHashMap(Entry).init(allocator) };
    }

    pub fn deinit(self: *Limiter) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.entries.deinit();
    }

    pub fn check(self: *Limiter, client: []const u8, rule: Rule) !Decision {
        return self.checkAt(client, rule, std.Io.Clock.awake.now(self.io).toSeconds());
    }

    pub fn checkAt(self: *Limiter, client: []const u8, rule: Rule, now: i64) !Decision {
        var key_buf: [96]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ rule.name, client });

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.entries.getPtr(key)) |entry| {
            if (now >= entry.reset_at) {
                entry.* = .{ .count = 1, .reset_at = now + rule.window_seconds };
                return allowedDecision(rule, entry.*);
            }
            if (entry.count >= rule.limit) return deniedDecision(rule, entry.*, now);
            entry.count += 1;
            return allowedDecision(rule, entry.*);
        }

        if (self.entries.count() >= self.max_entries) {
            var expired: ?[]const u8 = null;
            var it = self.entries.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.reset_at <= now) {
                    expired = entry.key_ptr.*;
                    break;
                }
            }
            if (expired) |old_key| {
                _ = self.entries.remove(old_key);
                self.allocator.free(old_key);
            } else return error.RateLimitCapacity;
        }

        const owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned);
        const entry: Entry = .{ .count = 1, .reset_at = now + rule.window_seconds };
        try self.entries.put(owned, entry);
        return allowedDecision(rule, entry);
    }
};

fn allowedDecision(rule: Rule, entry: Entry) Decision {
    return .{
        .allowed = true,
        .remaining = rule.limit - entry.count,
        .retry_after = 0,
        .limit = rule.limit,
    };
}

fn deniedDecision(rule: Rule, entry: Entry, now: i64) Decision {
    const seconds = @max(@as(i64, 1), entry.reset_at - now);
    return .{
        .allowed = false,
        .remaining = 0,
        .retry_after = @intCast(@min(seconds, std.math.maxInt(u32))),
        .limit = rule.limit,
    };
}

fn validClientKey(value: []const u8) ?[]const u8 {
    const first = if (std.mem.findScalar(u8, value, ',')) |comma| value[0..comma] else value;
    const trimmed = std.mem.trim(u8, first, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 64) return null;
    _ = std.Io.net.IpAddress.parse(trimmed, 0) catch return null;
    return trimmed;
}

pub fn clientKey(cf_connecting_ip: ?[]const u8, forwarded_for: ?[]const u8, real_ip: ?[]const u8) []const u8 {
    if (cf_connecting_ip) |value| if (validClientKey(value)) |key| return key;
    if (forwarded_for) |value| if (validClientKey(value)) |key| return key;
    if (real_ip) |value| if (validClientKey(value)) |key| return key;
    return "proxy";
}
