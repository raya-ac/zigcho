const std = @import("std");

pub const max_bytes: usize = 2 * 1024 * 1024;
pub const max_dimension: u32 = 4096;

pub const Image = struct {
    content_type: []const u8,
    width: u32,
    height: u32,
};

fn be16(bytes: []const u8, index: usize) u16 {
    return (@as(u16, bytes[index]) << 8) | bytes[index + 1];
}

fn le16(bytes: []const u8, index: usize) u16 {
    return @as(u16, bytes[index]) | (@as(u16, bytes[index + 1]) << 8);
}

fn be32(bytes: []const u8, index: usize) u32 {
    return (@as(u32, bytes[index]) << 24) | (@as(u32, bytes[index + 1]) << 16) | (@as(u32, bytes[index + 2]) << 8) | bytes[index + 3];
}

fn jpegDimensions(data: []const u8) ?struct { width: u32, height: u32 } {
    if (data.len < 4 or data[0] != 0xff or data[1] != 0xd8) return null;
    var cursor: usize = 2;
    while (cursor + 1 < data.len) {
        while (cursor < data.len and data[cursor] != 0xff) cursor += 1;
        while (cursor < data.len and data[cursor] == 0xff) cursor += 1;
        if (cursor >= data.len) return null;
        const marker = data[cursor];
        cursor += 1;
        if (marker == 0xd9 or marker == 0xda) return null;
        if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) continue;
        if (cursor + 2 > data.len) return null;
        const segment_len: usize = be16(data, cursor);
        if (segment_len < 2 or cursor + segment_len > data.len) return null;
        const is_sof = marker == 0xc0 or marker == 0xc1 or marker == 0xc2 or marker == 0xc3 or marker == 0xc5 or marker == 0xc6 or marker == 0xc7 or marker == 0xc9 or marker == 0xca or marker == 0xcb or marker == 0xcd or marker == 0xce or marker == 0xcf;
        if (is_sof) {
            if (segment_len < 7) return null;
            return .{ .width = be16(data, cursor + 5), .height = be16(data, cursor + 3) };
        }
        cursor += segment_len;
    }
    return null;
}

pub fn validateWithLimits(content_type: ?[]const u8, data: []const u8, byte_limit: usize, width_limit: u32, height_limit: u32) !Image {
    if (data.len == 0 or data.len > byte_limit) return error.InvalidAvatarSize;
    const expected = content_type orelse return error.InvalidAvatarContentType;
    var image: Image = undefined;
    if (data.len >= 24 and std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) {
        image = .{ .content_type = "image/png", .width = be32(data, 16), .height = be32(data, 20) };
    } else if (data.len >= 10 and (std.mem.eql(u8, data[0..6], "GIF87a") or std.mem.eql(u8, data[0..6], "GIF89a"))) {
        image = .{ .content_type = "image/gif", .width = le16(data, 6), .height = le16(data, 8) };
    } else if (jpegDimensions(data)) |dimensions| {
        image = .{ .content_type = "image/jpeg", .width = dimensions.width, .height = dimensions.height };
    } else {
        return error.InvalidAvatarImage;
    }
    if (!std.ascii.eqlIgnoreCase(expected, image.content_type)) return error.InvalidAvatarContentType;
    if (image.width == 0 or image.height == 0 or image.width > width_limit or image.height > height_limit) return error.InvalidAvatarDimensions;
    return image;
}

pub fn validate(content_type: ?[]const u8, data: []const u8) !Image {
    return validateWithLimits(content_type, data, max_bytes, max_dimension, max_dimension);
}

test "avatar validation uses image bytes and bounded dimensions" {
    const png = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 1, 0, 0, 0, 1, 0 };
    const parsed = try validate("image/png", &png);
    try std.testing.expectEqual(@as(u32, 256), parsed.width);
    try std.testing.expectEqual(@as(u32, 256), parsed.height);
    try std.testing.expectError(error.InvalidAvatarContentType, validate("image/jpeg", &png));

    const gif = "GIF89a\x20\x00\x40\x00";
    const parsed_gif = try validate("image/gif", gif);
    try std.testing.expectEqual(@as(u32, 32), parsed_gif.width);
    try std.testing.expectEqual(@as(u32, 64), parsed_gif.height);
    try std.testing.expectError(error.InvalidAvatarImage, validate("image/png", "not an image"));
}

test "jpeg avatar dimensions are read from the first frame" {
    const jpeg = [_]u8{ 0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, 0, 64, 0, 32, 1, 1, 0x11, 0, 0xff, 0xd9 };
    const parsed = try validate("image/jpeg", &jpeg);
    try std.testing.expectEqual(@as(u32, 32), parsed.width);
    try std.testing.expectEqual(@as(u32, 64), parsed.height);
}
