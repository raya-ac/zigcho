const std = @import("std");

pub fn validIrcBind(value: []const u8) bool {
    return std.mem.eql(u8, value, "127.0.0.1") or std.mem.eql(u8, value, "::1") or std.ascii.eqlIgnoreCase(value, "localhost");
}

pub const Config = struct {
    allocator: std.mem.Allocator,
    osu_api_key: []u8,
    score_webhook: []u8,
    anticheat_module_path: []u8,
    anticheat_allow_sample_modulus: u32,
    avatar_r2_endpoint: []u8,
    avatar_r2_bucket: []u8,
    avatar_r2_access_key_id: []u8,
    avatar_r2_secret_access_key: []u8,
    object_storage_endpoint: []u8,
    object_storage_bucket: []u8,
    object_storage_region: []u8,
    object_storage_access_key_id: []u8,
    object_storage_secret_access_key: []u8,
    beatmap_cache_max_bytes: u64,
    beatmap_media_cache_max_bytes: u64,
    irc_bind: []u8,
    irc_port: u16,
    http_max_connections: u32,
    http_header_timeout_seconds: u16,
    http_request_timeout_seconds: u16,
    http_long_request_timeout_seconds: u16,

    pub fn empty(allocator: std.mem.Allocator) !Config {
        const osu_api_key = try allocator.dupe(u8, "");
        errdefer allocator.free(osu_api_key);
        const score_webhook = try allocator.dupe(u8, "");
        errdefer allocator.free(score_webhook);
        const anticheat_module_path = try allocator.dupe(u8, "");
        errdefer allocator.free(anticheat_module_path);
        const avatar_r2_endpoint = try allocator.dupe(u8, "https://23309d0f8407c82c3bd8406673bf3bec.r2.cloudflarestorage.com");
        errdefer allocator.free(avatar_r2_endpoint);
        const avatar_r2_bucket = try allocator.dupe(u8, "avatar");
        errdefer allocator.free(avatar_r2_bucket);
        const avatar_r2_access_key_id = try allocator.dupe(u8, "");
        errdefer allocator.free(avatar_r2_access_key_id);
        const avatar_r2_secret_access_key = try allocator.dupe(u8, "");
        errdefer allocator.free(avatar_r2_secret_access_key);
        const object_storage_endpoint = try allocator.dupe(u8, "");
        errdefer allocator.free(object_storage_endpoint);
        const object_storage_bucket = try allocator.dupe(u8, "");
        errdefer allocator.free(object_storage_bucket);
        const object_storage_region = try allocator.dupe(u8, "default");
        errdefer allocator.free(object_storage_region);
        const object_storage_access_key_id = try allocator.dupe(u8, "");
        errdefer allocator.free(object_storage_access_key_id);
        const object_storage_secret_access_key = try allocator.dupe(u8, "");
        errdefer allocator.free(object_storage_secret_access_key);
        const irc_bind = try allocator.dupe(u8, "127.0.0.1");
        errdefer allocator.free(irc_bind);
        return .{
            .allocator = allocator,
            .osu_api_key = osu_api_key,
            .score_webhook = score_webhook,
            .anticheat_module_path = anticheat_module_path,
            .anticheat_allow_sample_modulus = 100,
            .avatar_r2_endpoint = avatar_r2_endpoint,
            .avatar_r2_bucket = avatar_r2_bucket,
            .avatar_r2_access_key_id = avatar_r2_access_key_id,
            .avatar_r2_secret_access_key = avatar_r2_secret_access_key,
            .object_storage_endpoint = object_storage_endpoint,
            .object_storage_bucket = object_storage_bucket,
            .object_storage_region = object_storage_region,
            .object_storage_access_key_id = object_storage_access_key_id,
            .object_storage_secret_access_key = object_storage_secret_access_key,
            .beatmap_cache_max_bytes = 2 * 1024 * 1024 * 1024,
            .beatmap_media_cache_max_bytes = 512 * 1024 * 1024,
            .irc_bind = irc_bind,
            .irc_port = 0,
            .http_max_connections = 512,
            .http_header_timeout_seconds = 10,
            .http_request_timeout_seconds = 30,
            .http_long_request_timeout_seconds = 300,
        };
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.osu_api_key);
        self.allocator.free(self.score_webhook);
        self.allocator.free(self.anticheat_module_path);
        self.allocator.free(self.avatar_r2_endpoint);
        self.allocator.free(self.avatar_r2_bucket);
        self.allocator.free(self.avatar_r2_access_key_id);
        self.allocator.free(self.avatar_r2_secret_access_key);
        self.allocator.free(self.object_storage_endpoint);
        self.allocator.free(self.object_storage_bucket);
        self.allocator.free(self.object_storage_region);
        self.allocator.free(self.object_storage_access_key_id);
        self.allocator.free(self.object_storage_secret_access_key);
        self.allocator.free(self.irc_bind);
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
            if (value.len <= 256 and std.mem.indexOfScalar(u8, value, 0) == null)
                try result.replace(&result.osu_api_key, value);
        } else if (std.mem.eql(u8, key, "score_webhook")) {
            try result.replace(&result.score_webhook, value);
        } else if (std.mem.eql(u8, key, "anticheat_module_path")) {
            if (value.len <= 4096 and std.mem.indexOfScalar(u8, value, 0) == null)
                try result.replace(&result.anticheat_module_path, value);
        } else if (std.mem.eql(u8, key, "anticheat_allow_sample_modulus")) {
            const parsed = std.fmt.parseInt(u32, value, 10) catch continue;
            if (parsed == 0 or (parsed >= 10 and parsed <= 100_000)) result.anticheat_allow_sample_modulus = parsed;
        } else if (std.mem.eql(u8, key, "avatar_r2_endpoint")) {
            try result.replace(&result.avatar_r2_endpoint, value);
        } else if (std.mem.eql(u8, key, "avatar_r2_bucket")) {
            try result.replace(&result.avatar_r2_bucket, value);
        } else if (std.mem.eql(u8, key, "avatar_r2_access_key_id")) {
            try result.replace(&result.avatar_r2_access_key_id, value);
        } else if (std.mem.eql(u8, key, "avatar_r2_secret_access_key")) {
            try result.replace(&result.avatar_r2_secret_access_key, value);
        } else if (std.mem.eql(u8, key, "object_storage_endpoint")) {
            try result.replace(&result.object_storage_endpoint, value);
        } else if (std.mem.eql(u8, key, "object_storage_bucket")) {
            try result.replace(&result.object_storage_bucket, value);
        } else if (std.mem.eql(u8, key, "object_storage_region")) {
            try result.replace(&result.object_storage_region, value);
        } else if (std.mem.eql(u8, key, "object_storage_access_key_id")) {
            try result.replace(&result.object_storage_access_key_id, value);
        } else if (std.mem.eql(u8, key, "object_storage_secret_access_key")) {
            try result.replace(&result.object_storage_secret_access_key, value);
        } else if (std.mem.eql(u8, key, "beatmap_cache_max_bytes")) {
            const parsed = std.fmt.parseInt(u64, value, 10) catch continue;
            if (parsed >= 128 * 1024 * 1024 and parsed <= 128 * 1024 * 1024 * 1024)
                result.beatmap_cache_max_bytes = parsed;
        } else if (std.mem.eql(u8, key, "beatmap_media_cache_max_bytes")) {
            const parsed = std.fmt.parseInt(u64, value, 10) catch continue;
            if (parsed >= 32 * 1024 * 1024 and parsed <= 16 * 1024 * 1024 * 1024)
                result.beatmap_media_cache_max_bytes = parsed;
        } else if (std.mem.eql(u8, key, "irc_bind")) {
            if (validIrcBind(value)) try result.replace(&result.irc_bind, value);
        } else if (std.mem.eql(u8, key, "irc_port")) {
            result.irc_port = std.fmt.parseInt(u16, value, 10) catch continue;
        } else if (std.mem.eql(u8, key, "http_max_connections")) {
            const parsed = std.fmt.parseInt(u32, value, 10) catch continue;
            if (parsed >= 64 and parsed <= 4096) result.http_max_connections = parsed;
        } else if (std.mem.eql(u8, key, "http_header_timeout_seconds")) {
            const parsed = std.fmt.parseInt(u16, value, 10) catch continue;
            if (parsed >= 2 and parsed <= 60) result.http_header_timeout_seconds = parsed;
        } else if (std.mem.eql(u8, key, "http_request_timeout_seconds")) {
            const parsed = std.fmt.parseInt(u16, value, 10) catch continue;
            if (parsed >= 5 and parsed <= 300) result.http_request_timeout_seconds = parsed;
        } else if (std.mem.eql(u8, key, "http_long_request_timeout_seconds")) {
            const parsed = std.fmt.parseInt(u16, value, 10) catch continue;
            if (parsed >= 30 and parsed <= 1800) result.http_long_request_timeout_seconds = parsed;
        }
    }
    if (result.http_long_request_timeout_seconds < result.http_request_timeout_seconds) {
        result.http_long_request_timeout_seconds = result.http_request_timeout_seconds;
    }
    return result;
}

test "http limits keep bounded production defaults and reject unsafe config" {
    var defaults = try Config.empty(std.testing.allocator);
    defer defaults.deinit();
    try std.testing.expectEqual(@as(u32, 512), defaults.http_max_connections);
    try std.testing.expectEqual(@as(u16, 10), defaults.http_header_timeout_seconds);
    try std.testing.expectEqual(@as(u16, 30), defaults.http_request_timeout_seconds);
    try std.testing.expectEqual(@as(u16, 300), defaults.http_long_request_timeout_seconds);

    var configured = try parse(std.testing.allocator,
        \\http_max_connections=768
        \\http_header_timeout_seconds=12
        \\http_request_timeout_seconds=45
        \\http_long_request_timeout_seconds=420
    );
    defer configured.deinit();
    try std.testing.expectEqual(@as(u32, 768), configured.http_max_connections);
    try std.testing.expectEqual(@as(u16, 12), configured.http_header_timeout_seconds);
    try std.testing.expectEqual(@as(u16, 45), configured.http_request_timeout_seconds);
    try std.testing.expectEqual(@as(u16, 420), configured.http_long_request_timeout_seconds);

    var unsafe = try parse(std.testing.allocator,
        \\http_max_connections=0
        \\http_header_timeout_seconds=1
        \\http_request_timeout_seconds=1
        \\http_long_request_timeout_seconds=1
    );
    defer unsafe.deinit();
    try std.testing.expectEqual(@as(u32, 512), unsafe.http_max_connections);
    try std.testing.expectEqual(@as(u16, 10), unsafe.http_header_timeout_seconds);
    try std.testing.expectEqual(@as(u16, 30), unsafe.http_request_timeout_seconds);
    try std.testing.expectEqual(@as(u16, 300), unsafe.http_long_request_timeout_seconds);
}

pub fn load(allocator: std.mem.Allocator, io: std.Io) !Config {
    var buffer: [16 * 1024]u8 = undefined;
    const bytes = std.Io.Dir.cwd().readFile(io, "config.ini", &buffer) catch return Config.empty(allocator);
    return parse(allocator, bytes);
}
