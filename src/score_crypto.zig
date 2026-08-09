const std = @import("std");
const rijndael = @import("rijndael.zig");

pub const Decrypted = struct {
    allocator: std.mem.Allocator,
    score_data: []u8,
    client_hash: []u8,

    pub fn deinit(self: *Decrypted) void {
        self.allocator.free(self.score_data);
        self.allocator.free(self.client_hash);
    }
};

pub fn decrypt(
    allocator: std.mem.Allocator,
    score_base64: []const u8,
    client_hash_base64: []const u8,
    iv_base64: []const u8,
    osu_version: []const u8,
) !Decrypted {
    if (osu_version.len != 8) return error.InvalidOsuVersion;
    for (osu_version) |c| if (!std.ascii.isDigit(c)) return error.InvalidOsuVersion;
    var key: [32]u8 = undefined;
    @memcpy(key[0..24], "osu!-scoreburgr---------");
    @memcpy(key[24..], osu_version);
    var iv: [32]u8 = undefined;
    try decodeExact(&iv, iv_base64);

    const encrypted_score = try decodeAlloc(allocator, score_base64, 64 * 1024);
    defer allocator.free(encrypted_score);
    const encrypted_hash = try decodeAlloc(allocator, client_hash_base64, 4096);
    defer allocator.free(encrypted_hash);
    const score = try rijndael.decryptCbcPkcs7(allocator, key, iv, encrypted_score);
    errdefer allocator.free(score);
    const client_hash = try rijndael.decryptCbcPkcs7(allocator, key, iv, encrypted_hash);
    errdefer allocator.free(client_hash);
    if (!std.unicode.utf8ValidateSlice(score) or !std.unicode.utf8ValidateSlice(client_hash)) return error.InvalidText;
    return .{ .allocator = allocator, .score_data = score, .client_hash = client_hash };
}

fn decodeAlloc(allocator: std.mem.Allocator, encoded: []const u8, limit: usize) ![]u8 {
    const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    if (size == 0 or size > limit) return error.DecodedValueTooLarge;
    const decoded = try allocator.alloc(u8, size);
    errdefer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    return decoded;
}

fn decodeExact(output: []u8, encoded: []const u8) !void {
    if (try std.base64.standard.Decoder.calcSizeForSlice(encoded) != output.len) return error.InvalidDecodedLength;
    try std.base64.standard.Decoder.decode(output, encoded);
}
