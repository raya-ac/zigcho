const std = @import("std");

pub const Config = struct {
    allocator: std.mem.Allocator,
    osu_api_key: []u8,
    score_webhook: []u8,

    pub fn empty(allocator: std.mem.Allocator) !Config {
        const osu_api_key = try allocator.dupe(u8, "");
        errdefer allocator.free(osu_api_key);
        return .{
            .allocator = allocator,
            .osu_api_key = osu_api_key,
            .score_webhook = try allocator.dupe(u8, ""),
        };
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.osu_api_key);
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
        if (std.mem.eql(u8, key, "osu_api_key")) {
            try result.replace(&result.osu_api_key, value);
        } else if (std.mem.eql(u8, key, "score_webhook")) {
            try result.replace(&result.score_webhook, value);
        }
    }
    return result;
}

pub fn load(allocator: std.mem.Allocator, io: std.Io) !Config {
    var buffer: [4096]u8 = undefined;
    const bytes = std.Io.Dir.cwd().readFile(io, "config.ini", &buffer) catch return Config.empty(allocator);
    return parse(allocator, bytes);
}
