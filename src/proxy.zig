const std = @import("std");
const rate_limit = @import("rate_limit.zig");

pub fn trustsForwardedHeaders(peer_ip: ?[]const u8) bool {
    const text = peer_ip orelse return false;
    const address = std.Io.net.IpAddress.parse(text, 0) catch return false;
    return switch (address) {
        .ip4 => |ip| ip.bytes[0] == 127,
        .ip6 => |ip| std.mem.eql(u8, &ip.bytes, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }),
    };
}

pub fn clientKey(peer_ip: ?[]const u8, trusted: bool, cf_connecting_ip: ?[]const u8, forwarded_for: ?[]const u8, real_ip: ?[]const u8) []const u8 {
    if (trusted) return rate_limit.clientKey(cf_connecting_ip, forwarded_for, real_ip);
    return peer_ip orelse "direct";
}

pub fn clientIp(peer_ip: ?[]const u8, trusted: bool, cf_connecting_ip: ?[]const u8, forwarded_for: ?[]const u8, real_ip: ?[]const u8) ?[]const u8 {
    if (!trusted) return peer_ip;
    const selected = rate_limit.clientKey(cf_connecting_ip, forwarded_for, real_ip);
    return if (std.mem.eql(u8, selected, "proxy")) null else selected;
}

pub fn countryHeader(trusted: bool, value: ?[]const u8) ?[]const u8 {
    if (!trusted) return null;
    const country = value orelse return null;
    if (country.len != 2 or !std.ascii.isAlphabetic(country[0]) or !std.ascii.isAlphabetic(country[1])) return null;
    return country;
}

test "forwarded identity is only trusted from loopback peers" {
    try std.testing.expect(trustsForwardedHeaders("127.0.0.1"));
    try std.testing.expect(trustsForwardedHeaders("127.42.0.8"));
    try std.testing.expect(trustsForwardedHeaders("::1"));
    try std.testing.expect(!trustsForwardedHeaders("10.0.0.4"));
    try std.testing.expect(!trustsForwardedHeaders("203.0.113.10"));
    try std.testing.expect(!trustsForwardedHeaders(null));

    try std.testing.expectEqualStrings("203.0.113.7", clientKey("127.0.0.1", true, "203.0.113.7", null, null));
    try std.testing.expectEqualStrings("203.0.113.10", clientKey("203.0.113.10", false, "198.51.100.9", null, null));
    try std.testing.expectEqualStrings("203.0.113.10", clientIp("203.0.113.10", false, "198.51.100.9", null, null).?);
    try std.testing.expectEqualStrings("198.51.100.9", clientIp("127.0.0.1", true, null, "198.51.100.9, 127.0.0.1", null).?);
    try std.testing.expect(clientIp("127.0.0.1", true, "not-an-ip", null, null) == null);
    try std.testing.expectEqualStrings("AU", countryHeader(true, "AU").?);
    try std.testing.expect(countryHeader(false, "AU") == null);
    try std.testing.expect(countryHeader(true, "AUS") == null);
}
