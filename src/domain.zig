const std = @import("std");

pub const Mode = enum(u8) { osu, taiko, @"catch", mania };
pub const RankedStatus = enum(i8) { unknown = 0, unsubmitted = 1, pending = 2, ranked = 3, approved = 4, qualified = 5, loved = 6 };
pub const Privileges = packed struct(u32) {
    unrestricted: bool = true,
    verified: bool = true,
    supporter: bool = false,
    moderator: bool = false,
    admin: bool = false,
    developer: bool = false,
    tournament: bool = false,
    alumni: bool = false,
    _padding: u24 = 0,
};

pub const User = struct {
    id: i32,
    name: []const u8,
    safe_name: []const u8,
    country: [2]u8 = .{ 'X', 'X' },
    privileges: u32 = 3,
    silence_end: i64 = 0,
    restricted: bool = false,
};

pub const Stats = struct {
    mode: Mode = .osu,
    ranked_score: i64 = 0,
    total_score: i64 = 0,
    pp: i32 = 0,
    plays: i32 = 0,
    play_time: i32 = 0,
    accuracy: f64 = 0,
    max_combo: i32 = 0,
    global_rank: i32 = 0,
};

pub const Score = struct {
    user_id: i32,
    map_md5: []const u8,
    mode: Mode,
    mods: i32,
    score: i64,
    pp: f64 = 0,
    accuracy: f64,
    max_combo: i32,
    n300: i32,
    n100: i32,
    n50: i32,
    nmiss: i32,
    ngeki: i32,
    nkatu: i32,
    perfect: bool,
    passed: bool,
};

pub fn safeName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| out[i] = if (c == ' ') '_' else std.ascii.toLower(c);
    return out;
}

pub fn accuracy(s: Score) f64 {
    const total = s.n300 + s.n100 + s.n50 + s.nmiss;
    if (total == 0) return 0;
    return 100.0 * @as(f64, @floatFromInt(300 * s.n300 + 100 * s.n100 + 50 * s.n50)) / @as(f64, @floatFromInt(300 * total));
}
