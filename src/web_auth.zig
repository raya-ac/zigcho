const std = @import("std");
const domain = @import("domain.zig");

pub const cookie_name = "__Host-kai-session";
pub const scope = "web:staff";
pub const lifetime_seconds: i64 = 8 * 60 * 60;

const nominator: u32 = 1 << 11;
const moderator: u32 = 1 << 12;
const administrator: u32 = 1 << 13;
const developer: u32 = 1 << 14;
const staff = nominator | moderator | administrator | developer;

pub fn allowed(user: domain.User) bool {
    return !user.restricted and user.privileges & staff != 0;
}

pub fn canRank(user: domain.User) bool {
    return allowed(user) and user.privileges & (nominator | administrator | developer) != 0;
}

pub fn canModerate(user: domain.User) bool {
    return allowed(user) and user.privileges & (moderator | administrator | developer) != 0;
}

pub fn canAdmin(user: domain.User) bool {
    return allowed(user) and user.privileges & (administrator | developer) != 0;
}

pub fn canDevelop(user: domain.User) bool {
    return allowed(user) and user.privileges & developer != 0;
}

pub fn canManage(actor: domain.User, target: domain.User) bool {
    if (target.id == 3 or target.id == actor.id) return false;
    return target.privileges & staff == 0 or canDevelop(actor);
}

pub fn passwordCredential(password: []const u8) ![32]u8 {
    if (password.len < 8 or password.len > 128) return error.InvalidCredential;
    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(password, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn sessionToken(cookie_header: ?[]const u8) ?[]const u8 {
    var cookies = std.mem.splitScalar(u8, cookie_header orelse return null, ';');
    while (cookies.next()) |raw| {
        const cookie = std.mem.trim(u8, raw, " \t");
        const separator = std.mem.findScalar(u8, cookie, '=') orelse continue;
        if (!std.mem.eql(u8, cookie[0..separator], cookie_name)) continue;
        const value = cookie[separator + 1 ..];
        if (value.len != 64) return null;
        for (value) |char| if (!std.ascii.isHex(char)) return null;
        return value;
    }
    return null;
}

pub fn csrfToken(token: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zigcho-web-csrf-v1\x00");
    hash.update(token);
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn csrfMatches(token: []const u8, submitted: ?[]const u8) bool {
    const value = submitted orelse return false;
    if (value.len != 64) return false;
    const expected = csrfToken(token);
    return std.crypto.timing_safe.eql([64]u8, expected, value[0..64].*);
}

fn hostWithoutPort(host: []const u8) []const u8 {
    if (host.len == 0) return host;
    if (host[0] == '[') {
        const closing = std.mem.findScalar(u8, host, ']') orelse return host;
        return host[0 .. closing + 1];
    }
    const colon = std.mem.findScalar(u8, host, ':') orelse return host;
    return host[0..colon];
}

pub fn websiteHost(host_header: ?[]const u8) bool {
    const host = hostWithoutPort(host_header orelse return false);
    return std.ascii.eqlIgnoreCase(host, "kai.ovh") or std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "[::1]");
}

pub fn protocolHost(host_header: ?[]const u8) bool {
    return std.ascii.eqlIgnoreCase(hostWithoutPort(host_header orelse return false), "osu.kai.ovh");
}

pub fn sameOrigin(origin_header: ?[]const u8, host_header: ?[]const u8) bool {
    const origin = origin_header orelse return false;
    const host = host_header orelse return false;
    if (!websiteHost(host)) return false;
    const scheme_end = std.mem.indexOf(u8, origin, "://") orelse return false;
    const scheme = origin[0..scheme_end];
    const origin_host = origin[scheme_end + 3 ..];
    if (origin_host.len == 0 or std.mem.findScalar(u8, origin_host, '/') != null) return false;
    if (!std.ascii.eqlIgnoreCase(origin_host, host)) return false;
    const bare_host = hostWithoutPort(host);
    if (std.ascii.eqlIgnoreCase(bare_host, "kai.ovh")) return std.ascii.eqlIgnoreCase(scheme, "https");
    return std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https");
}

pub fn sessionJson(allocator: std.mem.Allocator, user: domain.User, csrf: [64]u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"user\":{{\"id\":{d},\"name\":", .{user.id});
    try std.json.Stringify.value(user.name, .{}, &output.writer);
    try output.writer.print(",\"country\":\"{s}\",\"privileges\":{d}}},\"csrf\":\"{s}\"}}", .{ &user.country, user.privileges, &csrf });
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

test "staff authorization requires a live staff privilege" {
    var user: domain.User = .{ .id = 4, .name = "ari", .safe_name = "ari", .privileges = 3 | nominator };
    try std.testing.expect(allowed(user));
    user.privileges = 3;
    try std.testing.expect(!allowed(user));
    user.privileges = 3 | developer;
    user.restricted = true;
    try std.testing.expect(!allowed(user));
}

test "staff roles stay least privilege" {
    var user: domain.User = .{ .id = 4, .name = "ari", .safe_name = "ari", .privileges = 3 | nominator };
    try std.testing.expect(canRank(user));
    try std.testing.expect(!canModerate(user));
    try std.testing.expect(!canAdmin(user));
    user.privileges = 3 | moderator;
    try std.testing.expect(canModerate(user));
    try std.testing.expect(!canRank(user));
    user.privileges = 3 | administrator;
    try std.testing.expect(canRank(user) and canModerate(user) and canAdmin(user));
    try std.testing.expect(!canDevelop(user));
    const player: domain.User = .{ .id = 5, .name = "player", .safe_name = "player" };
    try std.testing.expect(canManage(user, player));
    try std.testing.expect(!canManage(user, user));
}

test "host cookie parsing is exact and rejects malformed tokens" {
    const token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expectEqualStrings(token, sessionToken("theme=dark; __Host-kai-session=" ++ token ++ "; other=1").?);
    try std.testing.expect(sessionToken("kai-session=" ++ token) == null);
    try std.testing.expect(sessionToken("__Host-kai-session=short") == null);
    try std.testing.expect(sessionToken("__Host-kai-session=zzzz456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef") == null);
}

test "csrf is bound to the session token" {
    const first = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const second = "1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const csrf = csrfToken(first);
    try std.testing.expect(csrfMatches(first, &csrf));
    try std.testing.expect(!csrfMatches(second, &csrf));
    try std.testing.expect(!csrfMatches(first, null));
    try std.testing.expect(!csrfMatches(first, "short"));
}

test "website passwords are always raw even when they look like stable md5" {
    const password = "00000000000000000000000000000000";
    const credential = try passwordCredential(password);
    try std.testing.expect(!std.mem.eql(u8, &credential, password));
    try std.testing.expectError(error.InvalidCredential, passwordCredential("short"));
}

test "staff origins stay on the website host" {
    try std.testing.expect(sameOrigin("https://kai.ovh", "kai.ovh"));
    try std.testing.expect(sameOrigin("http://127.0.0.1:8080", "127.0.0.1:8080"));
    try std.testing.expect(!sameOrigin("http://kai.ovh", "kai.ovh"));
    try std.testing.expect(!sameOrigin("https://kai.ovh.evil.test", "kai.ovh"));
    try std.testing.expect(!sameOrigin("https://kai.ovh/path", "kai.ovh"));
    try std.testing.expect(!sameOrigin("https://evil.test", "kai.ovh"));
    try std.testing.expect(!sameOrigin(null, "kai.ovh"));
    try std.testing.expect(!websiteHost("api.kai.ovh"));
    try std.testing.expect(protocolHost("osu.kai.ovh"));
    try std.testing.expect(protocolHost("OSU.KAI.OVH:443"));
    try std.testing.expect(!protocolHost("kai.ovh"));
}

test "staff session JSON escapes names" {
    const user: domain.User = .{ .id = 4, .name = "a\"ri", .safe_name = "a\"ri", .country = .{ 'A', 'U' }, .privileges = 8195 };
    const csrf = csrfToken("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    const json = try sessionJson(std.testing.allocator, user, csrf);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"a\\\"ri\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"country\":\"AU\"") != null);
}
