const std = @import("std");

pub const Config = struct {
    allocator: std.mem.Allocator,
    score_webhook: []u8,
    beatmap_cache_max_bytes: u64,
    beatmap_media_cache_max_bytes: u64,

    pub fn empty(allocator: std.mem.Allocator) !Config {
        return .{
            .allocator = allocator,
            .score_webhook = try allocator.dupe(u8, ""),
            .beatmap_cache_max_bytes = 2 * 1024 * 1024 * 1024,
            .beatmap_media_cache_max_bytes = 512 * 1024 * 1024,
        };
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.score_webhook);
        self.* = undefined;
    }

    fn replace(self: *Config, target: *[]u8, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        self.allocator.free(target.*);
        target.* = owned;
    }
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Config {
    var result = try Config.empty(allocator);
    errdefer result.deinit();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const eq = std.mem.findScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "score_webhook")) {
            try result.replace(&result.score_webhook, value);
        } else if (std.mem.eql(u8, key, "beatmap_cache_max_bytes")) {
            const parsed = std.fmt.parseInt(u64, value, 10) catch continue;
            if (parsed >= 128 * 1024 * 1024 and parsed <= 128 * 1024 * 1024 * 1024)
                result.beatmap_cache_max_bytes = parsed;
        } else if (std.mem.eql(u8, key, "beatmap_media_cache_max_bytes")) {
            const parsed = std.fmt.parseInt(u64, value, 10) catch continue;
            if (parsed >= 32 * 1024 * 1024 and parsed <= 16 * 1024 * 1024 * 1024)
                result.beatmap_media_cache_max_bytes = parsed;
        }
    }
    return result;
}

pub fn load(allocator: std.mem.Allocator, io: std.Io) !Config {
    var buffer: [4096]u8 = undefined;
    const bytes = std.Io.Dir.cwd().readFile(io, "config.ini", &buffer) catch return Config.empty(allocator);
    return parse(allocator, bytes);
}
