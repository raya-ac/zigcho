const std = @import("std");

pub const Profile = struct {
    id: i32,
    username: []const u8,
    country: [2]u8,
    join_date: []const u8,
    mode: u8,
    pp: f64,
    global_rank: i32,
    country_rank: i32,
    ranked_score: i64,
    total_score: i64,
    play_count: i32,
    play_time: i64,
    level: f64,
    accuracy: f64,
    total_hits: i64,
    grade_ssh: i32,
    grade_ss: i32,
    grade_sh: i32,
    grade_s: i32,
    grade_a: i32,
};

pub const SetMetadata = struct {
    set_id: i32,
    favourites: i32,
    submitted_date: []const u8,
    last_updated: []const u8,
    ranked_date: ?[]const u8,
    has_video: bool,
    genre_id: i16,
    language_id: i16,
};

pub fn modeName(mode: u8) ?[]const u8 {
    return switch (mode) {
        0 => "osu",
        1 => "taiko",
        2 => "fruits",
        3 => "mania",
        else => null,
    };
}

pub fn genreName(id: i16) []const u8 {
    return switch (id) {
        1 => "Unspecified",
        2 => "Video Game",
        3 => "Anime",
        4 => "Rock",
        5 => "Pop",
        6 => "Other",
        7 => "Novelty",
        9 => "Hip Hop",
        10 => "Electronic",
        11 => "Metal",
        12 => "Classical",
        13 => "Folk",
        14 => "Jazz",
        else => "Any",
    };
}

pub fn languageName(id: i16) []const u8 {
    return switch (id) {
        1 => "Unspecified",
        2 => "English",
        3 => "Japanese",
        4 => "Chinese",
        5 => "Instrumental",
        6 => "Korean",
        7 => "French",
        8 => "German",
        9 => "Swedish",
        10 => "Spanish",
        11 => "Italian",
        12 => "Russian",
        13 => "Polish",
        14 => "Other",
        else => "Any",
    };
}

pub fn validate(profile: Profile) !void {
    if (profile.id <= 0 or profile.username.len == 0 or profile.username.len > 64 or !std.unicode.utf8ValidateSlice(profile.username) or std.mem.indexOfScalar(u8, profile.username, 0) != null) return error.InvalidUpstreamUser;
    if (modeName(profile.mode) == null or !std.ascii.isUpper(profile.country[0]) or !std.ascii.isUpper(profile.country[1])) return error.InvalidUpstreamUser;
    if (profile.join_date.len != 20 or profile.join_date[4] != '-' or profile.join_date[7] != '-' or profile.join_date[10] != 'T' or profile.join_date[13] != ':' or profile.join_date[16] != ':' or profile.join_date[19] != 'Z') return error.InvalidUpstreamUser;
    if (!std.math.isFinite(profile.pp) or profile.pp < 0 or profile.pp > 1_000_000 or !std.math.isFinite(profile.level) or profile.level < 0 or profile.level > 10_000 or !std.math.isFinite(profile.accuracy) or profile.accuracy < 0 or profile.accuracy > 100) return error.InvalidUpstreamUser;
    if (profile.global_rank < 0 or profile.country_rank < 0 or profile.ranked_score < 0 or profile.total_score < 0 or profile.play_count < 0 or profile.play_time < 0 or profile.total_hits < 0 or profile.grade_ssh < 0 or profile.grade_ss < 0 or profile.grade_sh < 0 or profile.grade_s < 0 or profile.grade_a < 0) return error.InvalidUpstreamUser;
}

fn writeStatistics(writer: *std.Io.Writer, profile: Profile) !void {
    const current_level: i32 = @intFromFloat(@floor(profile.level));
    const level_progress: i32 = @intFromFloat(@min(100, @round((profile.level - @floor(profile.level)) * 100.0)));
    try writer.print("{{\"level\":{{\"current\":{d},\"progress\":{d}}},\"is_ranked\":{s},\"global_rank\":", .{ current_level, level_progress, if (profile.global_rank > 0) "true" else "false" });
    if (profile.global_rank > 0) try writer.print("{d}", .{profile.global_rank}) else try writer.writeAll("null");
    try writer.writeAll(",\"country_rank\":");
    if (profile.country_rank > 0) try writer.print("{d}", .{profile.country_rank}) else try writer.writeAll("null");
    try writer.print(",\"pp\":{d},\"ranked_score\":{d},\"hit_accuracy\":{d},\"play_count\":{d},\"play_time\":{d},\"total_score\":{d},\"total_hits\":{d},\"maximum_combo\":0,\"replays_watched_by_others\":0,\"grade_counts\":{{\"ssh\":{d},\"ss\":{d},\"sh\":{d},\"s\":{d},\"a\":{d}}}}}", .{
        profile.pp,
        profile.ranked_score,
        profile.accuracy,
        profile.play_count,
        profile.play_time,
        profile.total_score,
        profile.total_hits,
        profile.grade_ssh,
        profile.grade_ss,
        profile.grade_sh,
        profile.grade_s,
        profile.grade_a,
    });
}

pub fn jsonOwned(allocator: std.mem.Allocator, profile: Profile) ![]u8 {
    try validate(profile);
    const mode = modeName(profile.mode).?;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"id\":{d},\"username\":", .{profile.id});
    try std.json.Stringify.value(profile.username, .{}, &output.writer);
    try output.writer.print(",\"avatar_url\":\"https://a.ppy.sh/{d}\",\"country_code\":\"{s}\",\"join_date\":", .{ profile.id, &profile.country });
    try std.json.Stringify.value(profile.join_date, .{}, &output.writer);
    try output.writer.writeAll(",\"profile_colour\":null,\"is_active\":true,\"is_bot\":false,\"is_deleted\":false,\"is_online\":false,\"is_supporter\":false,\"support_level\":0,\"pm_friends_only\":false,\"playmode\":");
    try std.json.Stringify.value(mode, .{}, &output.writer);
    try output.writer.writeAll(",\"statistics\":");
    try writeStatistics(&output.writer, profile);
    try output.writer.writeAll(",\"statistics_rulesets\":{");
    try std.json.Stringify.value(mode, .{}, &output.writer);
    try output.writer.writeAll(":");
    try writeStatistics(&output.writer, profile);
    try output.writer.writeAll("},\"groups\":[],\"badges\":[],\"profile_order\":[\"top_ranks\",\"medals\"],\"user_achievements\":[],\"monthly_playcounts\":[],\"replays_watched_counts\":[],\"rank_history\":{\"mode\":");
    try std.json.Stringify.value(mode, .{}, &output.writer);
    try output.writer.writeAll(",\"data\":[]}}");
    return output.toOwnedSlice();
}

test "upstream mapper json carries real identity avatar and statistics" {
    const json = try jsonOwned(std.testing.allocator, .{
        .id = 4_452_992,
        .username = "Sotarks",
        .country = .{ 'F', 'R' },
        .join_date = "2014-05-28T17:34:35Z",
        .mode = 0,
        .pp = 6440.47,
        .global_rank = 50_128,
        .country_rank = 1563,
        .ranked_score = 22_490_858_468,
        .total_score = 91_822_598_773,
        .play_count = 45_597,
        .play_time = 1_000,
        .level = 100.649,
        .accuracy = 99.301498,
        .total_hits = 10_002_288,
        .grade_ssh = 251,
        .grade_ss = 64,
        .grade_sh = 1502,
        .grade_s = 566,
        .grade_a = 780,
    });
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 4_452_992), parsed.value.object.get("id").?.integer);
    try std.testing.expectEqualStrings("https://a.ppy.sh/4452992", parsed.value.object.get("avatar_url").?.string);
    try std.testing.expectEqual(@as(i64, 50_128), parsed.value.object.get("statistics").?.object.get("global_rank").?.integer);
    try std.testing.expectEqual(@as(i64, 65), parsed.value.object.get("statistics").?.object.get("level").?.object.get("progress").?.integer);
}
