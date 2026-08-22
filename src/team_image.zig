const profile_avatar = @import("profile_avatar.zig");

pub const flag_max_bytes: usize = 200_000;
pub const flag_max_width: u32 = 512;
pub const flag_max_height: u32 = 256;
pub const header_max_bytes: usize = 4_000_000;
pub const header_max_width: u32 = 2000;
pub const header_max_height: u32 = 500;

pub const Kind = enum { flag, header };

pub fn validate(kind: Kind, content_type: ?[]const u8, data: []const u8) !profile_avatar.Image {
    return switch (kind) {
        .flag => profile_avatar.validateWithLimits(content_type, data, flag_max_bytes, flag_max_width, flag_max_height),
        .header => profile_avatar.validateWithLimits(content_type, data, header_max_bytes, header_max_width, header_max_height),
    };
}
