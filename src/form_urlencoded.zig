const std = @import("std");
const multipart = @import("multipart.zig");

pub fn requestField(allocator: std.mem.Allocator, body: []const u8, content_type: ?[]const u8, keys: []const []const u8) !?[]u8 {
    if (content_type) |value| {
        if (std.ascii.startsWithIgnoreCase(value, "multipart/form-data")) {
            const boundary = try multipart.boundaryFromContentType(value);
            var form = try multipart.parse(allocator, body, boundary);
            defer form.deinit();
            for (keys) |key| if (form.first(key)) |part| {
                if (part.filename != null) return error.InvalidFormField;
                return try allocator.dupe(u8, part.data);
            };
            return null;
        }
    }
    return field(allocator, body, keys);
}

pub fn field(allocator: std.mem.Allocator, body: []const u8, keys: []const []const u8) !?[]u8 {
    var parts = std.mem.splitScalar(u8, body, '&');
    while (parts.next()) |part| {
        const separator = std.mem.findScalar(u8, part, '=') orelse continue;
        const encoded_key = part[0..separator];
        const key_buffer = try allocator.dupe(u8, encoded_key);
        defer allocator.free(key_buffer);
        replacePlus(key_buffer);
        const decoded_key = std.Uri.percentDecodeInPlace(key_buffer);

        var matches = false;
        for (keys) |key| {
            if (std.mem.eql(u8, decoded_key, key)) {
                matches = true;
                break;
            }
        }
        if (!matches) continue;

        const value_buffer = try allocator.dupe(u8, part[separator + 1 ..]);
        replacePlus(value_buffer);
        const decoded_value = std.Uri.percentDecodeInPlace(value_buffer);
        if (decoded_value.len == value_buffer.len) return value_buffer;
        const owned = try allocator.dupe(u8, decoded_value);
        allocator.free(value_buffer);
        return owned;
    }
    return null;
}

pub fn credentialMd5(input: []const u8) ![32]u8 {
    if (input.len == 32 and isHex(input)) {
        var normalized: [32]u8 = undefined;
        for (input, 0..) |char, index| {
            normalized[index] = std.ascii.toLower(char);
        }
        return normalized;
    }
    if (input.len < 8 or input.len > 128) return error.InvalidCredential;
    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(input, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn isHex(input: []const u8) bool {
    for (input) |char| if (!std.ascii.isHex(char)) return false;
    return true;
}

fn replacePlus(buffer: []u8) void {
    for (buffer) |*char| if (char.* == '+') {
        char.* = ' ';
    };
}
