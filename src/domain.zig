const std = @import("std");

pub const Mode = enum(u8) { osu, taiko, @"catch", mania };
pub const SiteScoreSource = enum { all, lazer, scorev2 };
pub const RankedStatus = enum(i8) { unknown = 0, unsubmitted = 1, pending = 2, ranked = 3, approved = 4, qualified = 5, loved = 6 };
pub const BeatmapRankAction = enum { pending, qualify, rank, approve, love, veto, rollback };
pub const BeatmapRankContext = struct {
    map_id: i32,
    set_id: i32,
    status: i8,
    requests: u32,
    nominations: u32,
};
pub const ScorePlacement = struct {
    rank: i32,
    submitted_is_best: bool,
};
pub const Privileges = packed struct(u32) {
    unrestricted: bool = true,
    verified: bool = true,
    whitelisted: bool = false,
    _reserved_3: bool = false,
    supporter: bool = false,
    premium: bool = false,
    _reserved_6: bool = false,
    alumni: bool = false,
    _reserved_8_9: u2 = 0,
    tournament: bool = false,
    nominator: bool = false,
    moderator: bool = false,
    admin: bool = false,
    developer: bool = false,
    _padding: u17 = 0,
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
    total_hits: i64 = 0,
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

pub fn parseSiteScoreSource(value: []const u8) ?SiteScoreSource {
    if (std.mem.eql(u8, value, "all")) return .all;
    if (std.mem.eql(u8, value, "lazer")) return .lazer;
    if (std.mem.eql(u8, value, "scorev2")) return .scorev2;
    return null;
}

pub fn validSiteMode(source: SiteScoreSource, mode: u8) bool {
    return switch (source) {
        .all, .lazer => mode <= 6 or mode == 8,
        .scorev2 => mode <= 3,
    };
}

pub fn siteScoreMode(mode: u8) u8 {
    return if (mode <= 3) mode else if (mode <= 6) mode - 4 else 0;
}

pub fn siteNamespace(source: SiteScoreSource, mode: u8) []const u8 {
    if (source == .scorev2) return "scorev2";
    return if (mode <= 3) "vanilla" else if (mode <= 6) "relax" else "autopilot";
}

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
