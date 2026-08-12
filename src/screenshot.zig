const std = @import("std");

pub const max_bytes: usize = 4 * 1024 * 1024;
pub const max_user_bytes: usize = 256 * 1024 * 1024;
pub const max_user_files: usize = 1_000;

pub fn quotaAllows(file_count: usize, byte_count: usize, new_bytes: usize) bool {
    return file_count < max_user_files and new_bytes <= max_user_bytes -| byte_count;
}

pub const Kind = enum {
    jpeg,
    png,

    pub fn extension(self: Kind) []const u8 {
        return switch (self) {
            .jpeg => "jpeg",
            .png => "png",
        };
    }

    pub fn contentType(self: Kind) []const u8 {
        return switch (self) {
            .jpeg => "image/jpeg",
            .png => "image/png",
        };
    }
};

pub fn detect(bytes: []const u8) !Kind {
    if (bytes.len > max_bytes) return error.FileTooLarge;
    if (bytes.len >= 11 and
        std.mem.eql(u8, bytes[0..4], &.{ 0xff, 0xd8, 0xff, 0xe0 }) and
        std.mem.eql(u8, bytes[6..11], "JFIF\x00")) return .jpeg;
    if (bytes.len >= 16 and
        std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n") and
        std.mem.eql(u8, bytes[bytes.len - 8 ..], "IEND\xaeB`\x82")) return .png;
    return error.InvalidFileType;
}

pub fn tokenValid(token: []const u8) bool {
    if (token.len != 8) return false;
    for (token) |char| if (!(std.ascii.isAlphanumeric(char) or char == '-' or char == '_')) return false;
    return true;
}

pub fn kindForExtension(extension: []const u8) ?Kind {
    if (std.mem.eql(u8, extension, "jpg") or std.mem.eql(u8, extension, "jpeg")) return .jpeg;
    if (std.mem.eql(u8, extension, "png")) return .png;
    return null;
}

pub const Path = struct { token: []const u8, kind: Kind };

pub fn parsePath(path: []const u8) ?Path {
    if (!std.mem.startsWith(u8, path, "/ss/")) return null;
    const file = path[4..];
    const dot = std.mem.lastIndexOfScalar(u8, file, '.') orelse return null;
    const name = file[0..dot];
    if (!tokenValid(name)) return null;
    return .{ .token = name, .kind = kindForExtension(file[dot + 1 ..]) orelse return null };
}

pub fn generateToken(io: std.Io) ![8]u8 {
    var random: [6]u8 = undefined;
    try std.Io.randomSecure(io, &random);
    var output: [8]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&output, &random);
    return output;
}

test "stable screenshot signatures and names are strict" {
    const png = "\x89PNG\r\n\x1a\nbodyIEND\xaeB`\x82";
    const jpeg = "\xff\xd8\xff\xe0\x00\x10JFIF\x00body";
    try std.testing.expectEqual(Kind.png, try detect(png));
    try std.testing.expectEqual(Kind.jpeg, try detect(jpeg));
    try std.testing.expectError(error.InvalidFileType, detect("not an image"));
    try std.testing.expect(tokenValid("Ab1_-xyZ"));
    try std.testing.expect(!tokenValid("../../etc"));
    try std.testing.expectEqual(Kind.jpeg, kindForExtension("jpg").?);
    try std.testing.expect(kindForExtension("gif") == null);
    const path = parsePath("/ss/Ab1_-xyZ.png").?;
    try std.testing.expectEqualStrings("Ab1_-xyZ", path.token);
    try std.testing.expectEqual(Kind.png, path.kind);
    try std.testing.expect(parsePath("/ss/../../etc") == null);
    try std.testing.expect(quotaAllows(999, max_user_bytes - 1, 1));
    try std.testing.expect(!quotaAllows(1_000, 0, 1));
    try std.testing.expect(!quotaAllows(1, max_user_bytes, 1));
}
