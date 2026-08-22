const profile_avatar = @import("profile_avatar.zig");

pub const max_bytes: usize = 4_000_000;
pub const max_width: u32 = 2000;
pub const max_height: u32 = 500;

pub fn validate(content_type: ?[]const u8, data: []const u8) !profile_avatar.Image {
    return profile_avatar.validateWithLimits(content_type, data, max_bytes, max_width, max_height);
}

test "profile banners follow the lazer cover limits" {
    const png = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 7, 0xd0, 0, 0, 1, 0xf4 };
    const image = try validate("image/png", &png);
    try @import("std").testing.expectEqual(@as(u32, 2000), image.width);
    try @import("std").testing.expectEqual(@as(u32, 500), image.height);

    var too_wide = png;
    too_wide[19] = 0xd1;
    try @import("std").testing.expectError(error.InvalidAvatarDimensions, validate("image/png", &too_wide));
}
