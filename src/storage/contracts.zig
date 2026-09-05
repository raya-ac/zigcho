const std = @import("std");
const domain = @import("../domain.zig");
const stable_score = @import("../stable_score.zig");
const lazer = @import("../lazer.zig");
const account_roles = @import("../account_roles.zig");

pub const BanchoStatsRequest = struct { user_id: i32, mode: u8 };

pub fn writeStableRating(writer: *std.Io.Writer, average: f64) !void {
    if (average == @trunc(average)) {
        try writer.print("{d:.1}", .{average});
    } else try writer.print("{d}", .{average});
}

/// Only fields serialized by the Stable user_stats packet, not profile extras.
pub const BanchoStats = struct {
    ranked_score: i64 = 0,
    total_score: i64 = 0,
    pp: i32 = 0,
    plays: i32 = 0,
    accuracy: f64 = 0,
    global_rank: i32 = 0,

    pub fn fromStats(value: domain.Stats) BanchoStats {
        return .{ .ranked_score = value.ranked_score, .total_score = value.total_score, .pp = value.pp, .plays = value.plays, .accuracy = value.accuracy, .global_rank = value.global_rank };
    }
};

pub const ConsumedLazerScoreToken = struct {
    score_id: i64,
    total_score: i64,
    accuracy: f64,
    max_combo: i32,
    passed: bool,
};

pub const LazerCommentable = enum {
    beatmapset,
    build,
    news_post,

    pub fn parse(value: []const u8) ?LazerCommentable {
        if (std.mem.eql(u8, value, "newspost")) return .news_post;
        return std.meta.stringToEnum(LazerCommentable, value);
    }

    pub fn text(self: LazerCommentable) []const u8 {
        return @tagName(self);
    }
};

pub const LazerCommentTarget = struct { commentable: LazerCommentable, id: i64 };

pub const LazerCommentSort = enum {
    new,
    old,
    top,

    pub fn parse(value: []const u8) ?LazerCommentSort {
        return std.meta.stringToEnum(LazerCommentSort, value);
    }
};

pub const ReplaySource = enum {
    stable,
    lazer,

    pub fn text(self: ReplaySource) []const u8 {
        return @tagName(self);
    }
};

pub const UpstreamUserCache = struct {
    id: i32,
    fresh: bool,
};

pub const BeatmapSetCreator = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    mode: u8,
    user_id: ?i32,
    is_local: bool,

    pub fn deinit(self: *BeatmapSetCreator) void {
        self.allocator.free(self.name);
        self.* = undefined;
    }
};

pub const ranked_play_default_rating: i32 = 1500;

pub const ranked_play_rating_delta: i32 = 16;

pub const RankedPlayRating = struct {
    rating: i32 = ranked_play_default_rating,
    games_played: i32 = 0,
    wins: i32 = 0,
    losses: i32 = 0,
};

pub const RankedPlayResult = struct {
    applied: bool,
    winner_rating_before: i32,
    winner_rating_after: i32,
    loser_rating_before: i32,
    loser_rating_after: i32,
};

pub fn validateRankedPlayResult(room_id: i64, ruleset_id: u8, winner_id: i32, loser_id: i32) !void {
    if (room_id <= 0 or ruleset_id > 3 or winner_id <= 0 or loser_id <= 0 or winner_id == loser_id) return error.InvalidRankedPlayResult;
}

pub const ClientHardware = struct {
    osu_path_md5: []const u8,
    adapters_md5: []const u8,
    uninstall_md5: []const u8,
    disk_signature_md5: []const u8,
    client_version: []const u8,
    running_under_wine: bool,
    actionable: bool,
};

pub const HardwareEvidence = struct {
    allocator: std.mem.Allocator,
    matched_user_ids: []i32,

    pub fn deinit(self: *HardwareEvidence) void {
        self.allocator.free(self.matched_user_ids);
        self.* = undefined;
    }
};

pub const AnticheatSource = enum {
    stable_login,
    stable_lastfm,
    stable_score,

    pub fn text(self: AnticheatSource) []const u8 {
        return switch (self) {
            .stable_login => "stable_login",
            .stable_lastfm => "stable_lastfm",
            .stable_score => "stable_score",
        };
    }
};

pub const anticheat_exclusion_min_seconds: i64 = 60 * 60;

pub const anticheat_exclusion_max_seconds: i64 = 30 * 24 * 60 * 60;

pub const AnticheatExclusionScope = enum {
    all,
    stable_login,
    stable_lastfm,
    stable_score,

    pub fn parse(value: []const u8) ?AnticheatExclusionScope {
        inline for (std.meta.fields(AnticheatExclusionScope)) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn text(self: AnticheatExclusionScope) []const u8 {
        return @tagName(self);
    }

    pub fn matches(self: AnticheatExclusionScope, source: AnticheatSource) bool {
        return self == .all or std.mem.eql(u8, self.text(), source.text());
    }
};

pub fn validateAnticheatExclusion(actor_id: i32, user_id: i32, duration_seconds: i64, reason: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, reason, " \t\r\n");
    if (actor_id <= 0 or user_id <= 0 or actor_id == 3 or user_id == 3 or actor_id == user_id) return error.InvalidAnticheatExclusion;
    if (duration_seconds < anticheat_exclusion_min_seconds or duration_seconds > anticheat_exclusion_max_seconds) return error.InvalidAnticheatExclusion;
    if (trimmed.len < 3 or trimmed.len > 500 or !std.unicode.utf8ValidateSlice(trimmed)) return error.InvalidAnticheatExclusion;
    return trimmed;
}

pub fn validateAnticheatExclusionRevocation(actor_id: i32, exclusion_id: i64, reason: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, reason, " \t\r\n");
    if (actor_id <= 0 or actor_id == 3 or exclusion_id <= 0) return error.InvalidAnticheatExclusion;
    if (trimmed.len < 3 or trimmed.len > 500 or !std.unicode.utf8ValidateSlice(trimmed)) return error.InvalidAnticheatExclusion;
    return trimmed;
}

pub fn canManageAnticheatExclusion(actor_id: i32, user_id: i32, actor_restricted: bool, actor_privileges: u32, user_privileges: u32) bool {
    const administrator = account_roles.Role.administrator.definition().bit;
    const developer = account_roles.Role.developer.definition().bit;
    if (actor_id <= 0 or user_id <= 0 or actor_id == user_id or user_id == 3 or actor_restricted) return false;
    if (actor_privileges & (administrator | developer) == 0) return false;
    return user_privileges & account_roles.staff_mask == 0 or actor_privileges & developer != 0;
}

pub const AnticheatReviewLabel = enum {
    clean,
    uncertain,
    cheat,
    dismissed,

    pub fn parse(value: []const u8) ?AnticheatReviewLabel {
        inline for (std.meta.fields(AnticheatReviewLabel)) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn text(self: AnticheatReviewLabel) []const u8 {
        return @tagName(self);
    }
};

pub const AnticheatObservation = struct {
    source: AnticheatSource,
    module: []const u8,
    score_id: ?i64 = null,
    action: u32,
    sample_weight: u32 = 1,
    reason: u32,
    risk_score: u32,
    confidence_bps: u32,
    evidence: u64 = 0,
    decision_flags: u64 = 0,
    rule_revision: u32 = 0,
    objects_checked: u32 = 0,
    matched_clicks: u32 = 0,
    mean_abs_timing_error_milli: u32 = 0,
    timing_stddev_milli: u32 = 0,
    exact_timing_bps: u32 = 0,
    center_hits_bps: u32 = 0,
    mean_center_distance_milli: u32 = 0,
    snap_events: u32 = 0,
    replay_match_count: u32 = 0,
    key_press_count: u32 = 0,
    key_hold_count: u32 = 0,
    mean_hold_duration_milli: u32 = 0,
    hold_duration_stddev_milli: u32 = 0,
    alternation_bps: u32 = 0,
    target_distance_stddev_milli: u32 = 0,
    velocity_spike_count: u32 = 0,
    movement_velocity_stddev_milli: u32 = 0,
};

pub fn validateAnticheatObservation(user_id: i32, observation: AnticheatObservation) !void {
    if (user_id <= 0 or observation.module.len == 0 or observation.module.len > 64 or !std.unicode.utf8ValidateSlice(observation.module)) return error.InvalidAnticheatObservation;
    if (observation.score_id) |score_id| if (score_id <= 0) return error.InvalidAnticheatObservation;
    if (observation.source != .stable_score and observation.score_id != null) return error.InvalidAnticheatObservation;
    if (observation.action > 3 or observation.sample_weight == 0 or observation.sample_weight > 100_000 or observation.risk_score > 1000 or observation.confidence_bps > 10_000 or observation.replay_match_count > 100_000) return error.InvalidAnticheatObservation;
    if (observation.evidence > std.math.maxInt(i64) or observation.decision_flags > std.math.maxInt(i64)) return error.InvalidAnticheatObservation;
    if (observation.matched_clicks > observation.objects_checked or observation.snap_events > observation.objects_checked or observation.exact_timing_bps > 10_000 or observation.center_hits_bps > 10_000 or observation.key_hold_count > observation.key_press_count or observation.alternation_bps > 10_000) return error.InvalidAnticheatObservation;
}

pub const CustomAvatar = struct {
    allocator: std.mem.Allocator,
    content_type: []u8,
    etag: [64]u8,
    object_key: []u8,
    updated_at: i64,
    width: u32 = 0,
    height: u32 = 0,

    pub fn deinit(self: *CustomAvatar) void {
        self.allocator.free(self.content_type);
        self.allocator.free(self.object_key);
        self.* = undefined;
    }
};

pub const LazerChatWrite = struct {
    json: []u8,
    inserted: bool,
    direct_message_id: ?i64 = null,
};

pub const GameTokenPair = struct {
    access: [64]u8,
    refresh: [64]u8,
};

pub const GameTokenRefresh = struct {
    user: domain.User,
    tokens: GameTokenPair,
};

pub const ChatCursor = struct {
    last_message_id: ?i64,
    last_read_id: ?i64,
};

pub const BeatmapArchiveDownload = struct {
    allocator: std.mem.Allocator,
    object_key: ?[]u8,
    data: ?[]u8,
    bytes: usize,

    pub fn deinit(self: *BeatmapArchiveDownload) void {
        if (self.object_key) |value| self.allocator.free(value);
        if (self.data) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

pub const MultiplayerRoomArchive = struct {
    allocator: std.mem.Allocator,
    room_id: i64,
    owner_id: i32,
    category: []u8,
    room_json: []u8,
    leaderboard_json: []u8,
    participant_ids_json: []u8,
    ended_at: i64,

    pub fn deinit(self: *MultiplayerRoomArchive) void {
        self.allocator.free(self.category);
        self.allocator.free(self.room_json);
        self.allocator.free(self.leaderboard_json);
        self.allocator.free(self.participant_ids_json);
        self.* = undefined;
    }
};

pub const LazerRankedRating = RankedPlayRating;

pub const LazerRankedResult = RankedPlayResult;

pub const RegistrationConflicts = struct { username: bool, email: bool };

pub const StableBeatmapInfo = struct {
    id: i32,
    set_id: i32,
    md5: [32]u8,
    status: i32,
    grades: [4][]const u8,
};

pub const DirectMessage = struct {
    id: i64,
    from_id: i32,
    from_name: []u8,
    message: []u8,

    pub fn deinit(self: *DirectMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.from_name);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const ServerCounts = struct {
    users: i64,
    plays: i64,
    passed: i64,
    maps: i64,
};

pub const BeatmapCacheStats = struct {
    entries: i64,
    bytes: i64,
    hydration_failures: i64,
};

pub const BeatmapCachePrune = struct {
    entries: i64,
    bytes: i64,
};

pub const BeatmapMediaCacheStats = struct {
    entries: i64,
    bytes: i64,
};

pub const ObjectMigrationStats = struct {
    archives: i64 = 0,
    media: i64 = 0,
    replays: i64 = 0,
    replay_bytes: i64 = 0,
    failed: i64 = 0,
};

pub const ObjectPurgeStats = struct {
    archives: i64 = 0,
    archive_bytes: i64 = 0,
    media: i64 = 0,
    media_bytes: i64 = 0,
};

pub const BeatmapForScore = struct { id: i32, set_id: i32, status: i8, plays: i32, passes: i32 };

pub const BeatmapRating = union(enum) {
    no_exist,
    not_ranked,
    can_rate,
    already_voted: f64,
};

pub const BeatmapSelection = struct {
    md5: [32]u8,
    set_id: i32,
    status: i8,
    mode: u8,
};

pub const MatchmakingBeatmap = struct {
    id: i32,
    md5: [32]u8,
    mode: u8,
    stars: f64,
};

pub const BeatmapInfo = struct { id: i32, set_id: i32, max_combo: i32, artist: []const u8, title: []const u8, version: []const u8, creator: []const u8, status: i8, star_rating: f64, total_length: i32, hit_length: i32 };

pub const PpSnapshot = struct { score: f64, player: i64 };

pub fn directStatus(db_status: i32) i32 {
    return switch (db_status) {
        2 => 2,
        3, 4 => 0,
        5 => 3,
        6 => 8,
        else => 2,
    };
}

/// Search result statuses use osu!api values, not the request's filter enum.
pub fn directListingStatus(db_status: i32) i32 {
    return switch (db_status) {
        3 => 1,
        4 => 2,
        5 => 3,
        6 => 4,
        else => 0,
    };
}

pub fn stableStatus(db_status: i32) i32 {
    return switch (db_status) {
        1 => -1,
        2 => 0,
        3 => 2,
        4 => 3,
        5 => 4,
        6 => 5,
        else => 1,
    };
}

pub fn lazerStatus(db_status: i32) []const u8 {
    return switch (db_status) {
        3 => "ranked",
        4 => "approved",
        5 => "qualified",
        6 => "loved",
        else => "pending",
    };
}

pub fn stableGrade(mode: u8, mods: i32, accuracy: f64, n300: i32, n100: i32, n50: i32, nmiss: i32) []const u8 {
    const hidden = mods & ((1 << 3) | (1 << 10)) != 0;
    const base: []const u8 = switch (mode) {
        0 => standard: {
            const total = n300 + n100 + n50 + nmiss;
            if (total <= 0) break :standard "N";
            const ratio_300 = @as(f64, @floatFromInt(n300)) / @as(f64, @floatFromInt(total));
            const ratio_50 = @as(f64, @floatFromInt(n50)) / @as(f64, @floatFromInt(total));
            if (n100 == 0 and n50 == 0 and nmiss == 0) break :standard "X";
            if (ratio_300 > 0.9 and ratio_50 <= 0.01 and nmiss == 0) break :standard "S";
            if ((ratio_300 > 0.8 and nmiss == 0) or ratio_300 > 0.9) break :standard "A";
            if ((ratio_300 > 0.7 and nmiss == 0) or ratio_300 > 0.8) break :standard "B";
            if (ratio_300 > 0.6) break :standard "C";
            break :standard "D";
        },
        1 => taiko: {
            const total = n300 + n100 + nmiss;
            if (total <= 0) break :taiko "N";
            const ratio_300 = @as(f64, @floatFromInt(n300)) / @as(f64, @floatFromInt(total));
            if (n100 == 0 and nmiss == 0) break :taiko "X";
            if (ratio_300 > 0.9 and nmiss == 0) break :taiko "S";
            if ((ratio_300 > 0.8 and nmiss == 0) or ratio_300 > 0.9) break :taiko "A";
            if ((ratio_300 > 0.7 and nmiss == 0) or ratio_300 > 0.8) break :taiko "B";
            if (ratio_300 > 0.6) break :taiko "C";
            break :taiko "D";
        },
        2 => if (accuracy >= 1.0) "X" else if (accuracy > 0.98) "S" else if (accuracy > 0.94) "A" else if (accuracy > 0.90) "B" else if (accuracy > 0.85) "C" else "D",
        3 => if (accuracy >= 1.0) "X" else if (accuracy > 0.95) "S" else if (accuracy > 0.9) "A" else if (accuracy > 0.8) "B" else if (accuracy > 0.7) "C" else "D",
        else => "N",
    };
    if (!hidden) return base;
    if (std.mem.eql(u8, base, "X")) return "XH";
    if (std.mem.eql(u8, base, "S")) return "SH";
    return base;
}

pub const lazer_room_score_token_tag: u64 = 0x7f_ff_ff_00_00_00_00_00;

pub const lazer_room_score_token_mask: u64 = 0x7f_ff_ff_00_00_00_00_00;

pub const lazer_room_score_token_payload_mask: u64 = 0x00_00_00_ff_ff_ff_ff_ff;

pub fn isLazerRoomScoreToken(token_id: i64) bool {
    if (token_id <= 0) return false;
    return (@as(u64, @intCast(token_id)) & lazer_room_score_token_mask) == lazer_room_score_token_tag;
}
