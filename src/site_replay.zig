const std = @import("std");

pub const Header = struct {
    score_id: i64,
    username: []const u8,
    map_md5: []const u8,
    mode: u8,
    n300: i32,
    n100: i32,
    n50: i32,
    ngeki: i32,
    nkatu: i32,
    nmiss: i32,
    score: i64,
    max_combo: i32,
    perfect: bool,
    mods: i32,
    submitted_at: i64,
};

const windows_epoch_offset: i64 = 0x089f7ff5f7b58000;

fn writeInt(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try list.appendSlice(allocator, &bytes);
}

fn writeString(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    if (value.len == 0) {
        try list.append(allocator, 0);
        return;
    }
    try list.append(allocator, 0x0b);
    var length = value.len;
    while (true) {
        const part: u8 = @intCast(length & 0x7f);
        length >>= 7;
        try list.append(allocator, if (length == 0) part else part | 0x80);
        if (length == 0) break;
    }
    try list.appendSlice(allocator, value);
}

fn replayHash(header: Header) ![32]u8 {
    var input: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer input.deinit();
    try input.writer.print("{d}p{d}o{d}o{d}t{d}a{s}r{d}e{s}y{s}o{d}u{d}{d}True", .{
        @as(i64, header.n100) + header.n300,
        header.n50,
        header.ngeki,
        header.nkatu,
        header.nmiss,
        header.map_md5,
        header.max_combo,
        if (header.perfect) "True" else "False",
        header.username,
        header.score,
        0,
        header.mods,
    });
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(input.written(), &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Wrap the raw LZMA replay frames submitted by Stable in a complete .osr file.
pub fn build(allocator: std.mem.Allocator, header: Header, frames: []const u8) ![]u8 {
    if (frames.len == 0 or frames.len > std.math.maxInt(i32)) return error.InvalidReplay;
    const score = std.math.cast(i32, header.score) orelse return error.InvalidReplay;
    const combo = std.math.cast(i16, header.max_combo) orelse return error.InvalidReplay;
    const counts = [_]i32{ header.n300, header.n100, header.n50, header.ngeki, header.nkatu, header.nmiss };
    for (counts) |count| if (count < 0 or count > std.math.maxInt(i16)) return error.InvalidReplay;
    const timestamp = std.math.mul(i64, header.submitted_at, 10_000_000) catch return error.InvalidReplay;
    const ticks = std.math.add(i64, timestamp, windows_epoch_offset) catch return error.InvalidReplay;
    const hash = try replayHash(header);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, header.mode);
    try writeInt(&output, allocator, i32, 20200207);
    try writeString(&output, allocator, header.map_md5);
    try writeString(&output, allocator, header.username);
    try writeString(&output, allocator, &hash);
    try writeInt(&output, allocator, i16, @intCast(header.n300));
    try writeInt(&output, allocator, i16, @intCast(header.n100));
    try writeInt(&output, allocator, i16, @intCast(header.n50));
    try writeInt(&output, allocator, i16, @intCast(header.ngeki));
    try writeInt(&output, allocator, i16, @intCast(header.nkatu));
    try writeInt(&output, allocator, i16, @intCast(header.nmiss));
    try writeInt(&output, allocator, i32, score);
    try writeInt(&output, allocator, i16, combo);
    try output.append(allocator, @intFromBool(header.perfect));
    try writeInt(&output, allocator, i32, header.mods);
    try output.append(allocator, 0); // empty life graph
    try writeInt(&output, allocator, i64, ticks);
    try writeInt(&output, allocator, i32, @intCast(frames.len));
    try output.appendSlice(allocator, frames);
    try writeInt(&output, allocator, i64, header.score_id);
    return output.toOwnedSlice(allocator);
}

test "full replay contains stable header frames and online id" {
    const frames = "stable replay frames";
    const replay = try build(std.testing.allocator, .{
        .score_id = 42,
        .username = "ari",
        .map_md5 = "0123456789abcdef0123456789abcdef",
        .mode = 0,
        .n300 = 300,
        .n100 = 4,
        .n50 = 1,
        .ngeki = 2,
        .nkatu = 3,
        .nmiss = 5,
        .score = 987654,
        .max_combo = 321,
        .perfect = false,
        .mods = 8,
        .submitted_at = 1_700_000_000,
    }, frames);
    defer std.testing.allocator.free(replay);
    try std.testing.expectEqual(@as(u8, 0), replay[0]);
    try std.testing.expect(std.mem.indexOf(u8, replay, "ari") != null);
    try std.testing.expect(std.mem.indexOf(u8, replay, frames) != null);
    try std.testing.expectEqual(@as(i64, 42), std.mem.readInt(i64, replay[replay.len - 8 ..][0..8], .little));
}
