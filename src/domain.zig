const std = @import("std");

pub const Mode = enum(u8) { osu, taiko, @"catch", mania };
pub const SiteScoreSource = enum { all, stable, lazer, scorev2 };
pub const ProfileAccent = enum { pink, violet, blue, mint, gold, red };
pub const SiteProfileSettings = struct {
    bio: []const u8,
    title: []const u8,
    pronouns: []const u8,
    location: []const u8,
    website: []const u8,
    accent: ProfileAccent,
    preferred_mode: u8,
    profile_source: SiteScoreSource,
    avatar_key: u8,
    show_country: bool,
    show_profile_stats: bool,
    show_recent_scores: bool,
};

pub const TeamSettings = struct {
    name: []const u8,
    short_name: []const u8,
    url: []const u8,
    description: []const u8,
    is_open: bool,
    default_ruleset_id: u8,
};

pub const TeamJoinResult = enum { joined, applied };

pub fn validTeamSettings(settings: TeamSettings) bool {
    if (settings.name.len < 2 or settings.name.len > 40 or settings.short_name.len == 0 or settings.short_name.len > 4 or settings.url.len > 255 or settings.description.len > 2000 or settings.default_ruleset_id > 3) return false;
    if (!std.unicode.utf8ValidateSlice(settings.name) or !std.unicode.utf8ValidateSlice(settings.description)) return false;
    for (settings.name) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    for (settings.short_name) |byte| if (!std.ascii.isAlphanumeric(byte)) return false;
    if (settings.url.len != 0 and (!std.mem.startsWith(u8, settings.url, "https://") or std.mem.indexOfAny(u8, settings.url, "\r\n") != null)) return false;
    return true;
}

test "team settings keep public identity bounded" {
    try std.testing.expect(validTeamSettings(.{ .name = "kai team", .short_name = "KAI", .url = "https://kai.ovh", .description = "hello", .is_open = true, .default_ruleset_id = 0 }));
    try std.testing.expect(!validTeamSettings(.{ .name = "x", .short_name = "K!", .url = "http://kai.ovh", .description = "", .is_open = true, .default_ruleset_id = 0 }));
}

pub const TeamSummary = struct {
    id: i32,
    name_bytes: [40]u8 = [_]u8{0} ** 40,
    name_len: u8 = 0,
    short_name_bytes: [4]u8 = [_]u8{0} ** 4,
    short_name_len: u8 = 0,
    flag_version: i64 = 0,

    pub fn init(id: i32, team_name: []const u8, short_name: []const u8, flag_version: i64) !TeamSummary {
        if (id <= 0 or team_name.len == 0 or team_name.len > 40 or short_name.len == 0 or short_name.len > 4) return error.InvalidTeamSummary;
        var result: TeamSummary = .{ .id = id, .name_len = @intCast(team_name.len), .short_name_len = @intCast(short_name.len), .flag_version = @max(0, flag_version) };
        @memcpy(result.name_bytes[0..team_name.len], team_name);
        @memcpy(result.short_name_bytes[0..short_name.len], short_name);
        return result;
    }

    pub fn name(self: *const TeamSummary) []const u8 {
        return self.name_bytes[0..self.name_len];
    }

    pub fn shortName(self: *const TeamSummary) []const u8 {
        return self.short_name_bytes[0..self.short_name_len];
    }
};

pub const LazerActivity = struct {
    allocator: std.mem.Allocator,
    status: []u8,
    detail: []u8,
    beatmap_id: ?i32,
    ruleset_id: ?u8,

    pub fn deinit(self: *LazerActivity) void {
        self.allocator.free(self.status);
        self.allocator.free(self.detail);
        self.* = undefined;
    }
};

pub const ProfilePresenceClient = enum { offline, stable, lazer };

pub fn profilePresenceClient(stable_online: bool, lazer_online: bool) ProfilePresenceClient {
    if (lazer_online) return .lazer;
    if (stable_online) return .stable;
    return .offline;
}

pub fn profilePresenceDetailsVisible(viewer_id: ?i32, profile_user_id: i32, show_recent_scores: bool) bool {
    return show_recent_scores or (viewer_id != null and viewer_id.? == profile_user_id);
}

test "profile presence keeps the active client and owner privacy exact" {
    try std.testing.expectEqual(ProfilePresenceClient.lazer, profilePresenceClient(true, true));
    try std.testing.expectEqual(ProfilePresenceClient.stable, profilePresenceClient(true, false));
    try std.testing.expectEqual(ProfilePresenceClient.offline, profilePresenceClient(false, false));
    try std.testing.expect(profilePresenceDetailsVisible(4, 4, false));
    try std.testing.expect(!profilePresenceDetailsVisible(null, 4, false));
    try std.testing.expect(!profilePresenceDetailsVisible(5, 4, false));
    try std.testing.expect(profilePresenceDetailsVisible(null, 4, true));
}

pub fn validLazerActivity(status: []const u8, detail: []const u8, beatmap_id: ?i32, ruleset_id: ?u8) bool {
    if (status.len == 0 or status.len > 80 or detail.len > 200) return false;
    if (!std.unicode.utf8ValidateSlice(status) or !std.unicode.utf8ValidateSlice(detail)) return false;
    for (status) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    for (detail) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    if (beatmap_id) |id| if (id <= 0) return false;
    if (ruleset_id) |id| if (id > 3) return false;
    return true;
}

pub const LevelProgress = struct {
    current: u64,
    progress: u8,
};

fn levelScoreFormula(level: f64) f64 {
    return 5_000.0 / 3.0 * (4.0 * level * level * level - 3.0 * level * level - level) + 1.25 * std.math.pow(f64, 1.8, level - 60.0);
}

/// Converts total score to the level contract returned by osu!'s user API.
/// Levels through 100 use the client's rounded, cumulative score deltas; later
/// levels use the official linear continuation.
pub fn levelFromTotalScore(total_score: i64) LevelProgress {
    const score: u128 = @intCast(@max(0, total_score));
    const level_100_score: u128 = 26_931_190_827;
    const score_per_level_after_100: u128 = 99_999_999_999;

    if (score >= level_100_score) {
        const completed = (score - level_100_score) / score_per_level_after_100;
        const start = level_100_score + completed * score_per_level_after_100;
        return .{
            .current = 100 + @as(u64, @intCast(completed)),
            .progress = @intCast((score - start) * 100 / score_per_level_after_100),
        };
    }

    var current_level: u64 = 1;
    var current_score: u128 = 0;
    var previous_formula = levelScoreFormula(0);
    for (1..101) |raw_level| {
        const formula = levelScoreFormula(@floatFromInt(raw_level));
        const rounded_delta: u128 = @intFromFloat(@round(formula - previous_formula));
        const next_score = current_score + rounded_delta;
        previous_formula = formula;
        if (next_score > score) {
            return .{
                .current = current_level,
                .progress = if (next_score == current_score) 0 else @intCast((score - current_score) * 100 / (next_score - current_score)),
            };
        }
        current_level = @intCast(raw_level);
        current_score = next_score;
    }
    unreachable;
}

test "lazer activity is utf8 bounded and client safe" {
    try std.testing.expect(validLazerActivity("playing", "artist - title", 75, 0));
    try std.testing.expect(validLazerActivity("in lazer", "", null, null));
    try std.testing.expect(!validLazerActivity("", "", null, null));
    try std.testing.expect(!validLazerActivity("playing\nelsewhere", "", null, null));
    try std.testing.expect(!validLazerActivity("playing", "private\x00detail", null, null));
    try std.testing.expect(!validLazerActivity("playing", "", 0, null));
    try std.testing.expect(!validLazerActivity("playing", "", null, 4));
}

test "total score uses osu rounded level thresholds and post-100 continuation" {
    try std.testing.expectEqual(LevelProgress{ .current = 1, .progress = 0 }, levelFromTotalScore(-1));
    try std.testing.expectEqual(LevelProgress{ .current = 1, .progress = 0 }, levelFromTotalScore(0));
    try std.testing.expectEqual(LevelProgress{ .current = 1, .progress = 99 }, levelFromTotalScore(29_999));
    try std.testing.expectEqual(LevelProgress{ .current = 2, .progress = 0 }, levelFromTotalScore(30_000));
    try std.testing.expectEqual(LevelProgress{ .current = 83, .progress = 84 }, levelFromTotalScore(3_896_191_620));
    try std.testing.expectEqual(LevelProgress{ .current = 100, .progress = 0 }, levelFromTotalScore(26_931_190_827));
    try std.testing.expectEqual(LevelProgress{ .current = 102, .progress = 88 }, levelFromTotalScore(315_143_525_692));
    const maximum = levelFromTotalScore(std.math.maxInt(i64));
    try std.testing.expect(maximum.current > 100);
    try std.testing.expect(maximum.progress < 100);
}
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
pub const StablePersonalBest = struct {
    rank: i32, // One-based placement before the new submission.
    total_score: i64,
    max_combo: i32,
    accuracy: f64,
    pp: f64,
};
pub const StableScoreInsert = struct {
    id: i64,
    previous_best: ?StablePersonalBest = null,
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
    show_country: bool = true,
    privileges: u32 = 3,
    silence_end: i64 = 0,
    restricted: bool = false,
    online: bool = false,
    follower_count: i32 = 0,
    banner_version: i64 = 0,
    team: ?TeamSummary = null,
};

pub const RelationshipAddResult = enum { inserted, existing, ineligible };

pub const ProfileSummary = struct {
    created_at: i64 = 0,
    last_visit: i64 = 0,
    avatar_version: i64 = 0,
    preferred_mode: u8 = 0,
    show_country: bool = true,
    show_profile_stats: bool = true,
    show_recent_scores: bool = true,
    title_bytes: [40]u8 = [_]u8{0} ** 40,
    title_len: u8 = 0,
    location_bytes: [60]u8 = [_]u8{0} ** 60,
    location_len: u8 = 0,
    website_bytes: [200]u8 = [_]u8{0} ** 200,
    website_len: u8 = 0,
    favourite_count: i32 = 0,
    ranked_count: i32 = 0,
    loved_count: i32 = 0,
    pending_count: i32 = 0,
    graveyard_count: i32 = 0,
    nominated_count: i32 = 0,
    guest_count: i32 = 0,
    played_beatmap_count: i32 = 0,
    follower_count: i32 = 0,

    pub fn init(created_at: i64, last_visit: i64, avatar_version: i64, preferred_mode: u8, profile_title: []const u8, profile_location: []const u8, profile_website: []const u8) !ProfileSummary {
        if (preferred_mode > 3 or profile_title.len > 40 or profile_location.len > 60 or profile_website.len > 200) return error.InvalidProfileSummary;
        if (!std.unicode.utf8ValidateSlice(profile_title) or !std.unicode.utf8ValidateSlice(profile_location) or !std.unicode.utf8ValidateSlice(profile_website)) return error.InvalidProfileSummary;
        var result: ProfileSummary = .{
            .created_at = @max(0, created_at),
            .last_visit = @max(0, last_visit),
            .avatar_version = @max(0, avatar_version),
            .preferred_mode = preferred_mode,
            .title_len = @intCast(profile_title.len),
            .location_len = @intCast(profile_location.len),
            .website_len = @intCast(profile_website.len),
        };
        @memcpy(result.title_bytes[0..profile_title.len], profile_title);
        @memcpy(result.location_bytes[0..profile_location.len], profile_location);
        @memcpy(result.website_bytes[0..profile_website.len], profile_website);
        return result;
    }

    pub fn title(self: *const ProfileSummary) []const u8 {
        return self.title_bytes[0..self.title_len];
    }

    pub fn location(self: *const ProfileSummary) []const u8 {
        return self.location_bytes[0..self.location_len];
    }

    pub fn website(self: *const ProfileSummary) []const u8 {
        return self.website_bytes[0..self.website_len];
    }
};

pub const BatchUserVisibility = struct {
    avatar_version: i64 = 0,
    show_country: bool = true,
    show_profile_stats: bool = true,
    follower_count: i32 = 0,
};

test "profile summary owns bounded lazer metadata" {
    const summary = try ProfileSummary.init(1_700_000_000, 1_700_000_100, 42, 3, "mapper", "adelaide", "https://kai.ovh");
    try std.testing.expectEqual(@as(i64, 1_700_000_000), summary.created_at);
    try std.testing.expectEqual(@as(i64, 1_700_000_100), summary.last_visit);
    try std.testing.expectEqual(@as(i64, 42), summary.avatar_version);
    try std.testing.expectEqual(@as(u8, 3), summary.preferred_mode);
    try std.testing.expectEqualStrings("mapper", summary.title());
    try std.testing.expectEqualStrings("adelaide", summary.location());
    try std.testing.expectEqualStrings("https://kai.ovh", summary.website());
    try std.testing.expectError(error.InvalidProfileSummary, ProfileSummary.init(0, 0, 0, 4, "", "", ""));
    try std.testing.expectError(error.InvalidProfileSummary, ProfileSummary.init(0, 0, 0, 0, "x" ** 41, "", ""));
    try std.testing.expectError(error.InvalidProfileSummary, ProfileSummary.init(0, 0, 0, 0, "", "x" ** 61, ""));
    try std.testing.expectError(error.InvalidProfileSummary, ProfileSummary.init(0, 0, 0, 0, "", "", "x" ** 201));
}

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
    country_rank: i32 = 0,
    replay_views: i32 = 0,
    grade_ssh: i32 = 0,
    grade_ss: i32 = 0,
    grade_sh: i32 = 0,
    grade_s: i32 = 0,
    grade_a: i32 = 0,

    pub fn addGrade(self: *Stats, grade: []const u8) void {
        if (std.mem.eql(u8, grade, "XH") or std.mem.eql(u8, grade, "SSH"))
            self.grade_ssh += 1
        else if (std.mem.eql(u8, grade, "X") or std.mem.eql(u8, grade, "SS"))
            self.grade_ss += 1
        else if (std.mem.eql(u8, grade, "SH"))
            self.grade_sh += 1
        else if (std.mem.eql(u8, grade, "S"))
            self.grade_s += 1
        else if (std.mem.eql(u8, grade, "A"))
            self.grade_a += 1;
    }
};

pub const UserScoreCounts = struct {
    best: i32 = 0,
    firsts: i32 = 0,
    recent: i32 = 0,
    pinned: i32 = 0,
};

pub const StatsHistoryPoint = struct {
    day: i64 = 0,
    pp: i32 = 0,
    global_rank: i32 = 0,
};

pub const StatsHistory = struct {
    pub const max_points = 90;

    points: [max_points]StatsHistoryPoint = [_]StatsHistoryPoint{.{}} ** max_points,
    len: u8 = 0,

    pub fn slice(self: *const StatsHistory) []const StatsHistoryPoint {
        return self.points[0..self.len];
    }
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
    if (std.mem.eql(u8, value, "stable")) return .stable;
    if (std.mem.eql(u8, value, "lazer")) return .lazer;
    if (std.mem.eql(u8, value, "scorev2")) return .scorev2;
    return null;
}

pub fn parseProfileAccent(value: []const u8) ?ProfileAccent {
    inline for (std.meta.tags(ProfileAccent)) |accent| {
        if (std.mem.eql(u8, value, @tagName(accent))) return accent;
    }
    return null;
}

pub fn validSiteMode(source: SiteScoreSource, mode: u8) bool {
    return switch (source) {
        .all, .stable, .lazer => mode <= 6 or mode == 8,
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
