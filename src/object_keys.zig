const std = @import("std");
const media_contract = @import("media_contract.zig");

pub fn validSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

pub fn matchesSha256(bytes: []const u8, expected: []const u8) bool {
    if (!validSha256(expected)) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return std.ascii.eqlIgnoreCase(&encoded, expected);
}

pub fn archive(allocator: std.mem.Allocator, set_id: i32, sha256: []const u8) ![]u8 {
    if (set_id <= 0 or !validSha256(sha256)) return error.InvalidObjectIdentity;
    return std.fmt.allocPrint(allocator, "beatmaps/archives/{d}/{s}.osz", .{ set_id, sha256 });
}

pub fn media(allocator: std.mem.Allocator, set_id: i32, kind: media_contract.Kind, content_type: media_contract.ContentType, sha256: []const u8) ![]u8 {
    if (set_id <= 0 or !validSha256(sha256) or !media_contract.compatible(kind, content_type)) return error.InvalidObjectIdentity;
    const extension: []const u8 = switch (content_type) {
        .jpeg => "jpg",
        .ogg => "ogg",
        .mp3 => "mp3",
    };
    return std.fmt.allocPrint(allocator, "beatmaps/media/{d}/{s}/{s}.{s}", .{ set_id, kind.dbName(), sha256, extension });
}

fn imageExtension(content_type: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, content_type, "image/png")) return "png";
    if (std.mem.eql(u8, content_type, "image/jpeg")) return "jpg";
    if (std.mem.eql(u8, content_type, "image/gif")) return "gif";
    return null;
}

pub fn banner(allocator: std.mem.Allocator, user_id: i32, content_type: []const u8, sha256: []const u8) ![]u8 {
    const extension = imageExtension(content_type) orelse return error.InvalidObjectIdentity;
    if (user_id <= 0 or !validSha256(sha256)) return error.InvalidObjectIdentity;
    return std.fmt.allocPrint(allocator, "banners/{d}/{s}.{s}", .{ user_id, sha256, extension });
}

pub fn teamAsset(allocator: std.mem.Allocator, team_id: i32, kind: []const u8, content_type: []const u8, sha256: []const u8) ![]u8 {
    const extension = imageExtension(content_type) orelse return error.InvalidObjectIdentity;
    if (team_id <= 0 or (!std.mem.eql(u8, kind, "flag") and !std.mem.eql(u8, kind, "header")) or !validSha256(sha256)) return error.InvalidObjectIdentity;
    return std.fmt.allocPrint(allocator, "teams/{d}/{s}/{s}.{s}", .{ team_id, kind, sha256, extension });
}

pub fn replay(allocator: std.mem.Allocator, source: []const u8, sha256: []const u8) ![]u8 {
    if ((!std.mem.eql(u8, source, "stable") and !std.mem.eql(u8, source, "lazer")) or !validSha256(sha256)) return error.InvalidObjectIdentity;
    return std.fmt.allocPrint(allocator, "replays/{s}/{s}.osr", .{ source, sha256 });
}

test "object keys are deterministic and content addressed" {
    const digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const archive_key = try archive(std.testing.allocator, 42, digest);
    defer std.testing.allocator.free(archive_key);
    try std.testing.expectEqualStrings("beatmaps/archives/42/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.osz", archive_key);
    const media_key = try media(std.testing.allocator, 42, .preview, .mp3, digest);
    defer std.testing.allocator.free(media_key);
    try std.testing.expectEqualStrings("beatmaps/media/42/preview/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.mp3", media_key);
    try std.testing.expectError(error.InvalidObjectIdentity, archive(std.testing.allocator, 42, "short"));
    const banner_key = try banner(std.testing.allocator, 4, "image/png", digest);
    defer std.testing.allocator.free(banner_key);
    try std.testing.expectEqualStrings("banners/4/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png", banner_key);
    const flag_key = try teamAsset(std.testing.allocator, 2, "flag", "image/jpeg", digest);
    defer std.testing.allocator.free(flag_key);
    try std.testing.expectEqualStrings("teams/2/flag/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.jpg", flag_key);
    const replay_key = try replay(std.testing.allocator, "stable", digest);
    defer std.testing.allocator.free(replay_key);
    try std.testing.expectEqualStrings("replays/stable/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.osr", replay_key);
}
