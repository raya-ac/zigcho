const std = @import("std");

pub fn canonicalPath(path: []const u8) []const u8 {
    if (path.len > 1 and path[path.len - 1] == '/') return path[0 .. path.len - 1];
    return path;
}

pub fn websitePage(path: []const u8) bool {
    if (std.mem.eql(u8, path, "/") or
        std.mem.eql(u8, path, "/rankings") or
        std.mem.eql(u8, path, "/appeal") or
        std.mem.eql(u8, path, "/staff") or
        std.mem.eql(u8, path, "/users")) return true;
    return numericPage(path, "/u/") or
        numericPage(path, "/users/") or
        numericPage(path, "/beatmapsets/");
}

fn numericPage(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix) or path.len == prefix.len) return false;
    for (path[prefix.len..]) |char| if (!std.ascii.isDigit(char)) return false;
    return true;
}

test "website pages stay limited to real browser routes" {
    try std.testing.expect(websitePage("/"));
    try std.testing.expect(websitePage("/users"));
    try std.testing.expect(websitePage("/users/4"));
    try std.testing.expect(websitePage("/u/4"));
    try std.testing.expect(websitePage("/beatmapsets/1"));
    try std.testing.expect(!websitePage("/web/osu-osz2-getscores.php"));
    try std.testing.expect(!websitePage("/api/v1/users/4"));
    try std.testing.expect(!websitePage("/u/not-a-player"));
}
