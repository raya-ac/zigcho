const std = @import("std");

pub fn canonicalPath(path: []const u8) []const u8 {
    if (path.len > 1 and path[path.len - 1] == '/') return path[0 .. path.len - 1];
    return path;
}

pub fn websitePage(path: []const u8) bool {
    if (std.mem.eql(u8, path, "/") or
        std.mem.eql(u8, path, "/rankings") or
        std.mem.eql(u8, path, "/login") or
        std.mem.eql(u8, path, "/settings") or
        std.mem.eql(u8, path, "/appeal") or
        std.mem.eql(u8, path, "/staff") or
        std.mem.eql(u8, path, "/users")) return true;
    return playerPage(path, "/u/") or
        playerPage(path, "/users/") or
        numericPage(path, "/beatmapsets/");
}

pub fn websiteFallback(path: []const u8) bool {
    const reserved = [_][]const u8{
        "/api/", "/web/", "/oauth/", "/d/", "/avatars/", "/avatar/",
    };
    for (reserved) |prefix| {
        if (std.mem.eql(u8, path, prefix[0 .. prefix.len - 1]) or std.mem.startsWith(u8, path, prefix)) return false;
    }
    return !std.mem.eql(u8, path, "/health") and !std.mem.eql(u8, path, "/metrics");
}

fn playerPage(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    const identifier = path[prefix.len..];
    return identifier.len >= 1 and identifier.len <= 96 and std.mem.indexOfScalar(u8, identifier, '/') == null;
}

fn numericPage(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix) or path.len == prefix.len) return false;
    for (path[prefix.len..]) |char| if (!std.ascii.isDigit(char)) return false;
    return true;
}

test "website pages stay limited to real browser routes" {
    try std.testing.expect(websitePage("/"));
    try std.testing.expect(websitePage("/users"));
    try std.testing.expect(websitePage("/login"));
    try std.testing.expect(websitePage("/settings"));
    try std.testing.expect(websitePage("/users/4"));
    try std.testing.expect(websitePage("/u/4"));
    try std.testing.expect(websitePage("/users/raya"));
    try std.testing.expect(websitePage("/u/raya_ac"));
    try std.testing.expect(websitePage("/u/raya%20ac"));
    try std.testing.expect(websitePage("/beatmapsets/1"));
    try std.testing.expect(!websitePage("/web/osu-osz2-getscores.php"));
    try std.testing.expect(!websitePage("/api/v1/users/4"));
    try std.testing.expect(!websitePage("/u/name/extra"));
    try std.testing.expect(!websitePage("/u/"));
}

test "website fallback does not swallow service routes" {
    try std.testing.expect(websiteFallback("/does-not-exist"));
    try std.testing.expect(websiteFallback("/u"));
    try std.testing.expect(!websiteFallback("/api/v1/nope"));
    try std.testing.expect(!websiteFallback("/api"));
    try std.testing.expect(!websiteFallback("/web/nope"));
    try std.testing.expect(!websiteFallback("/health"));
}
