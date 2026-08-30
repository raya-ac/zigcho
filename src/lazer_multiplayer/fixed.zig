const std = @import("std");

pub fn FixedRaw(comptime capacity: usize) type {
    return struct {
        len: u16 = 0,
        bytes: [capacity]u8 = undefined,

        const Self = @This();

        pub fn set(self: *Self, value: []const u8) !void {
            if (value.len > self.bytes.len) return error.MultiplayerPayloadTooLarge;
            @memcpy(self.bytes[0..value.len], value);
            self.len = @intCast(value.len);
        }

        pub fn setText(self: *Self, value: []const u8) void {
            var len = @min(value.len, self.bytes.len);
            while (len != 0 and !std.unicode.utf8ValidateSlice(value[0..len])) len -= 1;
            @memcpy(self.bytes[0..len], value[0..len]);
            self.len = @intCast(len);
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub const Raw64 = FixedRaw(64);
pub const Raw128 = FixedRaw(128);
pub const Raw2048 = FixedRaw(2048);
pub const Text64 = FixedRaw(64);
pub const Text128 = FixedRaw(128);
pub const Text256 = FixedRaw(256);
