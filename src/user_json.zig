const std = @import("std");
const domain = @import("domain.zig");

pub fn registration(buffer: []u8, id: i32, name: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.print("{{\"id\":{d},\"name\":", .{id});
    try std.json.Stringify.value(name, .{}, &writer);
    try writer.writeByte('}');
    return buffer[0..writer.end];
}

pub fn me(buffer: []u8, id: i32, name: []const u8, country: [2]u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.print("{{\"id\":{d},\"username\":", .{id});
    try std.json.Stringify.value(name, .{}, &writer);
    try writer.print(",\"avatar_url\":\"https://a.kai.ovh/{d}\",\"country_code\":", .{id});
    try std.json.Stringify.value(&country, .{}, &writer);
    try writer.writeAll(",\"is_active\":true,\"is_online\":true,\"statistics_rulesets\":{}}");
    return buffer[0..writer.end];
}

pub fn roleColour(privileges: u32) []const u8 {
    if (privileges & (@as(u32, 1) << 14) != 0) return "#ef86ba";
    if (privileges & (@as(u32, 1) << 13) != 0) return "#ef8888";
    if (privileges & (@as(u32, 1) << 12) != 0) return "#daa0ee";
    if (privileges & (@as(u32, 1) << 11) != 0) return "#79c5ef";
    if (privileges & (@as(u32, 1) << 10) != 0) return "#e8bd69";
    if (privileges & (@as(u32, 1) << 7) != 0) return "#b9a2ef";
    if (privileges & (@as(u32, 1) << 5) != 0) return "#80d7c0";
    return "#ef9abe";
}

fn writeGroups(writer: *std.Io.Writer, privileges: u32) !void {
    const roles = [_]struct { bit: u32, id: u8, identifier: []const u8, name: []const u8, short: []const u8, colour: []const u8 }{
        .{ .bit = 1 << 14, .id = 8, .identifier = "dev", .name = "Developer", .short = "DEV", .colour = "#ef86ba" },
        .{ .bit = 1 << 13, .id = 7, .identifier = "admin", .name = "Administrator", .short = "ADMIN", .colour = "#ef8888" },
        .{ .bit = 1 << 12, .id = 6, .identifier = "gmt", .name = "Global Moderation Team", .short = "GMT", .colour = "#daa0ee" },
        .{ .bit = 1 << 11, .id = 5, .identifier = "bng", .name = "Beatmap Nominators", .short = "BN", .colour = "#79c5ef" },
        .{ .bit = 1 << 10, .id = 4, .identifier = "tournament", .name = "Tournament Staff", .short = "T", .colour = "#e8bd69" },
        .{ .bit = 1 << 7, .id = 3, .identifier = "alumni", .name = "Alumni", .short = "ALUMNI", .colour = "#b9a2ef" },
        .{ .bit = 1 << 5, .id = 2, .identifier = "premium", .name = "Premium Supporter", .short = "PREMIUM", .colour = "#80d7c0" },
        .{ .bit = 1 << 4, .id = 1, .identifier = "supporter", .name = "Supporter", .short = "SUPPORTER", .colour = "#ef9abe" },
    };
    try writer.writeByte('[');
    var first = true;
    for (roles) |role| {
        if (privileges & role.bit == 0) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("{{\"id\":{d},\"identifier\":", .{role.id});
        try std.json.Stringify.value(role.identifier, .{}, writer);
        try writer.writeAll(",\"name\":");
        try std.json.Stringify.value(role.name, .{}, writer);
        try writer.writeAll(",\"short_name\":");
        try std.json.Stringify.value(role.short, .{}, writer);
        try writer.writeAll(",\"colour\":");
        try std.json.Stringify.value(role.colour, .{}, writer);
        try writer.writeAll(",\"has_listing\":false,\"has_playmodes\":false,\"is_probationary\":false,\"playmodes\":null}");
    }
    try writer.writeByte(']');
}

fn writeUserCore(writer: *std.Io.Writer, user: domain.User) !void {
    try writer.print("{{\"id\":{d},\"username\":", .{user.id});
    try std.json.Stringify.value(user.name, .{}, writer);
    try writer.print(",\"avatar_url\":\"https://a.kai.ovh/{d}\",\"country_code\":", .{user.id});
    try std.json.Stringify.value(&user.country, .{}, writer);
    try writer.writeAll(",\"cover_url\":");
    if (user.banner_version > 0) {
        var cover_buf: [128]u8 = undefined;
        const cover_url = try std.fmt.bufPrint(&cover_buf, "https://assets.kai.ovh/banners/{d}?v={d}", .{ user.id, user.banner_version });
        try std.json.Stringify.value(cover_url, .{}, writer);
        try writer.writeAll(",\"cover\":{\"custom_url\":");
        try std.json.Stringify.value(cover_url, .{}, writer);
        try writer.writeAll(",\"url\":");
        try std.json.Stringify.value(cover_url, .{}, writer);
        try writer.writeAll(",\"id\":null}");
    } else {
        try writer.writeAll("\"\",\"cover\":{\"custom_url\":null,\"url\":\"\",\"id\":null}");
    }
    try writer.writeAll(",\"team\":");
    if (user.team) |team| {
        var flag_buf: [160]u8 = undefined;
        const flag_url = try std.fmt.bufPrint(&flag_buf, "https://assets.kai.ovh/teams/{d}/flag?v={d}", .{ team.id, team.flag_version });
        try writer.print("{{\"id\":{d},\"name\":", .{team.id});
        try std.json.Stringify.value(team.name(), .{}, writer);
        try writer.writeAll(",\"short_name\":");
        try std.json.Stringify.value(team.shortName(), .{}, writer);
        try writer.writeAll(",\"flag_url\":");
        try std.json.Stringify.value(flag_url, .{}, writer);
        try writer.writeByte('}');
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"profile_colour\":");
    try std.json.Stringify.value(roleColour(user.privileges), .{}, writer);
    try writer.print(",\"is_active\":{s},\"is_online\":{s},\"is_supporter\":{s},\"support_level\":{d},\"is_admin\":{s},\"is_gmt\":{s},\"is_qat\":false,\"is_bng\":{s},\"is_bot\":{s},\"pm_friends_only\":false", .{
        if (user.restricted) "false" else "true",
        if (user.online or user.id == 3) "true" else "false",
        "true",
        @as(u8, if (user.privileges & (@as(u32, 1) << 5) != 0) 2 else 1),
        if (user.privileges & (@as(u32, 1) << 13) != 0) "true" else "false",
        if (user.privileges & ((@as(u32, 1) << 12) | (@as(u32, 1) << 13) | (@as(u32, 1) << 14)) != 0) "true" else "false",
        if (user.privileges & (@as(u32, 1) << 11) != 0) "true" else "false",
        if (user.id == 3) "true" else "false",
    });
}

fn writeStatistics(writer: *std.Io.Writer, maybe_stats: ?domain.Stats, restricted: bool) !void {
    const stats = maybe_stats orelse domain.Stats{};
    const level: i64 = @min(100, @max(1, @divFloor(stats.total_score, 1_000_000) + 1));
    const progress: i64 = @divFloor(@mod(stats.total_score, 1_000_000) * 100, 1_000_000);
    try writer.print("{{\"level\":{{\"current\":{d},\"progress\":{d}}},\"is_ranked\":", .{ level, progress });
    try writer.writeAll(if (restricted) "false" else "true");
    try writer.writeAll(",\"global_rank\":");
    if (!restricted and stats.global_rank > 0) try writer.print("{d}", .{stats.global_rank}) else try writer.writeAll("null");
    try writer.writeAll(",\"country_rank\":");
    if (!restricted and stats.country_rank > 0) try writer.print("{d}", .{stats.country_rank}) else try writer.writeAll("null");
    try writer.print(",\"pp\":{d},\"ranked_score\":{d},\"hit_accuracy\":{d:.6},\"play_count\":{d},\"play_time\":{d},\"total_score\":{d},\"total_hits\":{d},\"maximum_combo\":{d},\"replays_watched_by_others\":0,\"grade_counts\":{{\"ssh\":{d},\"ss\":{d},\"sh\":{d},\"s\":{d},\"a\":{d}}}}}", .{
        stats.pp,
        stats.ranked_score,
        stats.accuracy * 100.0,
        stats.plays,
        stats.play_time,
        stats.total_score,
        stats.total_hits,
        stats.max_combo,
        stats.grade_ssh,
        stats.grade_ss,
        stats.grade_sh,
        stats.grade_s,
        stats.grade_a,
    });
}

pub fn writeRankingStatistics(writer: *std.Io.Writer, user: domain.User, stats: domain.Stats, global_rank: i32, country_rank: i32) !void {
    try writer.writeAll("{\"user\":");
    try writeUserCore(writer, user);
    try writer.writeAll("},\"level\":{\"current\":0,\"progress\":0},\"is_ranked\":true,\"global_rank\":");
    if (global_rank > 0) try writer.print("{d}", .{global_rank}) else try writer.writeAll("null");
    try writer.writeAll(",\"country_rank\":");
    if (country_rank > 0) try writer.print("{d}", .{country_rank}) else try writer.writeAll("null");
    try writer.print(",\"pp\":{d},\"ranked_score\":{d},\"hit_accuracy\":{d:.6},\"play_count\":{d},\"play_time\":{d},\"total_score\":{d},\"total_hits\":{d},\"maximum_combo\":{d},\"replays_watched_by_others\":0,\"grade_counts\":{{\"ssh\":0,\"ss\":0,\"sh\":0,\"s\":0,\"a\":0}}}}", .{
        stats.pp,
        stats.ranked_score,
        stats.accuracy * 100.0,
        stats.plays,
        stats.play_time,
        stats.total_score,
        stats.total_hits,
        stats.max_combo,
    });
}

pub fn writeCompact(writer: *std.Io.Writer, user: domain.User) !void {
    try writeUserCore(writer, user);
    try writer.writeByte('}');
}

fn isoTimestamp(unix_seconds: i64) [20]u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, unix_seconds)) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    var result: [20]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable;
    return result;
}

pub fn meOwned(allocator: std.mem.Allocator, user: domain.User, stats: [4]?domain.Stats, achievements_json: []const u8, last_visit_epoch: i64) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try writeUserCore(&output.writer, user);
    const last_visit = isoTimestamp(last_visit_epoch);
    try output.writer.writeAll(",\"last_visit\":");
    try std.json.Stringify.value(&last_visit, .{}, &output.writer);
    try output.writer.writeAll(",\"statistics_rulesets\":{");
    const names = [_][]const u8{ "osu", "taiko", "fruits", "mania" };
    for (names, 0..) |name, index| {
        if (index != 0) try output.writer.writeByte(',');
        try std.json.Stringify.value(name, .{}, &output.writer);
        try output.writer.writeByte(':');
        try writeStatistics(&output.writer, stats[index], user.restricted);
    }
    try output.writer.writeAll("},\"groups\":");
    try writeGroups(&output.writer, user.privileges);
    try output.writer.writeAll(",\"user_achievements\":");
    try output.writer.writeAll(achievements_json);
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

pub const ProfileSources = struct {
    stable_stats: ?domain.Stats = null,
    lazer_stats: ?domain.Stats = null,
    stable_counts: domain.UserScoreCounts = .{},
    lazer_counts: domain.UserScoreCounts = .{},
};

fn writeScoreCounts(writer: *std.Io.Writer, counts: domain.UserScoreCounts) !void {
    try writer.print("{{\"best\":{d},\"firsts\":{d},\"recent\":{d},\"pinned\":{d}}}", .{ counts.best, counts.firsts, counts.recent, counts.pinned });
}

fn writeRankHistory(writer: *std.Io.Writer, maybe_stats: ?domain.Stats, restricted: bool) !void {
    const stats = maybe_stats orelse domain.Stats{};
    const mode = switch (stats.mode) {
        .osu => "osu",
        .taiko => "taiko",
        .@"catch" => "fruits",
        .mania => "mania",
    };
    try writer.writeAll("{\"mode\":");
    try std.json.Stringify.value(mode, .{}, writer);
    try writer.writeAll(",\"data\":[");
    for (0..90) |index| {
        if (index != 0) try writer.writeByte(',');
        const rank = if (!restricted and stats.global_rank > 0 and index >= 88) stats.global_rank else 0;
        try writer.print("{d}", .{rank});
    }
    try writer.writeAll("]}");
}

pub fn profileOwned(allocator: std.mem.Allocator, user: domain.User, stats: ?domain.Stats, score_counts: domain.UserScoreCounts, sources: ProfileSources, achievements_json: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try writeUserCore(&output.writer, user);
    try output.writer.writeAll(",\"statistics\":");
    try writeStatistics(&output.writer, stats, user.restricted);
    try output.writer.writeAll(",\"rank_history\":");
    try writeRankHistory(&output.writer, stats, user.restricted);
    try output.writer.writeAll(",\"zigcho_statistics\":{\"stable\":");
    try writeStatistics(&output.writer, sources.stable_stats, user.restricted);
    try output.writer.writeAll(",\"lazer\":");
    try writeStatistics(&output.writer, sources.lazer_stats, user.restricted);
    try output.writer.writeAll("},\"zigcho_score_counts\":{\"stable\":");
    try writeScoreCounts(&output.writer, sources.stable_counts);
    try output.writer.writeAll(",\"lazer\":");
    try writeScoreCounts(&output.writer, sources.lazer_counts);
    try output.writer.writeByte('}');
    try output.writer.print(",\"scores_best_count\":{d},\"scores_first_count\":{d},\"scores_recent_count\":{d},\"scores_pinned_count\":{d},\"groups\":", .{ score_counts.best, score_counts.firsts, score_counts.recent, score_counts.pinned });
    try writeGroups(&output.writer, user.privileges);
    try output.writer.writeAll(",\"badges\":[],\"profile_order\":[\"recent_activity\",\"top_ranks\",\"medals\"],\"user_achievements\":");
    try output.writer.writeAll(achievements_json);
    try output.writer.writeAll(",\"monthly_playcounts\":[],\"replays_watched_counts\":[]}");
    return output.toOwnedSlice();
}

test "user JSON escapes imported names" {
    var buffer: [512]u8 = undefined;
    const registration_json = try registration(&buffer, 4, "raya\"},\"admin\":true");
    var parsed_registration = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, registration_json, .{});
    defer parsed_registration.deinit();
    try std.testing.expectEqualStrings("raya\"},\"admin\":true", parsed_registration.value.object.get("name").?.string);
    try std.testing.expect(parsed_registration.value.object.get("admin") == null);

    const me_json = try me(&buffer, 4, "line\nbreak", .{ 'A', 'U' });
    var parsed_me = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, me_json, .{});
    defer parsed_me.deinit();
    try std.testing.expectEqualStrings("line\nbreak", parsed_me.value.object.get("username").?.string);
    try std.testing.expectEqualStrings("AU", parsed_me.value.object.get("country_code").?.string);

    const imported_country_json = try me(&buffer, 4, "raya", .{ '"', '\\' });
    var parsed_country = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, imported_country_json, .{});
    defer parsed_country.deinit();
    try std.testing.expectEqualStrings("\"\\", parsed_country.value.object.get("country_code").?.string);
}

test "lazer profile JSON owns ruleset stats and role flags" {
    const user: domain.User = .{
        .id = 4,
        .name = "raya\"test",
        .safe_name = "raya_test",
        .country = .{ 'A', 'U' },
        .privileges = (@as(u32, 1) << 4) | (@as(u32, 1) << 11) | (@as(u32, 1) << 13),
        .banner_version = 42,
        .team = try domain.TeamSummary.init(7, "kai team", "KAI", 9),
    };
    const stats: domain.Stats = .{ .pp = 424, .ranked_score = 3_442_127, .total_score = 9_000_000, .plays = 43, .play_time = 100, .total_hits = 1234, .accuracy = 0.9353, .max_combo = 228, .global_rank = 1 };
    const profile = try profileOwned(std.testing.allocator, user, stats, .{ .best = 2, .firsts = 1, .recent = 4 }, .{
        .stable_stats = .{ .pp = 300, .plays = 30 },
        .lazer_stats = .{ .pp = 124, .plays = 13 },
        .stable_counts = .{ .best = 1, .firsts = 1, .recent = 3, .pinned = 1 },
        .lazer_counts = .{ .best = 1, .recent = 1 },
    }, "[{\"achievement_id\":1,\"achieved_at\":42}]");
    defer std.testing.allocator.free(profile);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, profile, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 2), object.get("scores_best_count").?.integer);
    try std.testing.expectEqualStrings("raya\"test", object.get("username").?.string);
    try std.testing.expect(object.get("is_supporter").?.bool);
    try std.testing.expectEqual(@as(i64, 1), object.get("support_level").?.integer);
    try std.testing.expect(object.get("is_bng").?.bool);
    try std.testing.expect(object.get("is_admin").?.bool);
    try std.testing.expectEqualStrings("https://assets.kai.ovh/banners/4?v=42", object.get("cover_url").?.string);
    try std.testing.expectEqual(@as(i64, 7), object.get("team").?.object.get("id").?.integer);
    try std.testing.expectEqualStrings("KAI", object.get("team").?.object.get("short_name").?.string);
    try std.testing.expectEqual(@as(i64, 424), object.get("statistics").?.object.get("pp").?.integer);
    try std.testing.expectApproxEqAbs(@as(f64, 93.53), object.get("statistics").?.object.get("hit_accuracy").?.float, 0.0001);
    const rank_history = object.get("rank_history").?.object;
    try std.testing.expectEqualStrings("osu", rank_history.get("mode").?.string);
    try std.testing.expectEqual(@as(usize, 90), rank_history.get("data").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 0), rank_history.get("data").?.array.items[87].integer);
    try std.testing.expectEqual(@as(i64, 1), rank_history.get("data").?.array.items[88].integer);
    try std.testing.expectEqual(@as(i64, 1), rank_history.get("data").?.array.items[89].integer);
    try std.testing.expectEqual(@as(i64, 300), object.get("zigcho_statistics").?.object.get("stable").?.object.get("pp").?.integer);
    try std.testing.expectEqual(@as(i64, 124), object.get("zigcho_statistics").?.object.get("lazer").?.object.get("pp").?.integer);
    try std.testing.expectEqual(@as(i64, 3), object.get("zigcho_score_counts").?.object.get("stable").?.object.get("recent").?.integer);
    try std.testing.expectEqual(@as(i64, 1), object.get("zigcho_score_counts").?.object.get("lazer").?.object.get("recent").?.integer);
    const profile_order = object.get("profile_order").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), profile_order.len);
    try std.testing.expectEqualStrings("recent_activity", profile_order[0].string);
    try std.testing.expectEqualStrings("top_ranks", profile_order[1].string);
    try std.testing.expectEqualStrings("medals", profile_order[2].string);

    const me_json = try meOwned(std.testing.allocator, user, .{ stats, null, null, null }, "[]", 0);
    defer std.testing.allocator.free(me_json);
    var parsed_me = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, me_json, .{});
    defer parsed_me.deinit();
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", parsed_me.value.object.get("last_visit").?.string);
    try std.testing.expectEqual(@as(i64, 43), parsed_me.value.object.get("statistics_rulesets").?.object.get("osu").?.object.get("play_count").?.integer);
    try std.testing.expectEqual(@as(i64, 0), parsed_me.value.object.get("statistics_rulesets").?.object.get("mania").?.object.get("play_count").?.integer);

    const regular_user: domain.User = .{
        .id = 5,
        .name = "regular",
        .safe_name = "regular",
        .privileges = 3,
    };
    const regular_json = try meOwned(std.testing.allocator, regular_user, .{ null, null, null, null }, "[]", 0);
    defer std.testing.allocator.free(regular_json);
    var parsed_regular = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, regular_json, .{});
    defer parsed_regular.deinit();
    try std.testing.expect(parsed_regular.value.object.get("is_supporter").?.bool);
    try std.testing.expectEqual(@as(i64, 1), parsed_regular.value.object.get("support_level").?.integer);

    const premium_user: domain.User = .{
        .id = 6,
        .name = "premium",
        .safe_name = "premium",
        .privileges = 3 | (@as(u32, 1) << 5),
    };
    const premium_json = try meOwned(std.testing.allocator, premium_user, .{ null, null, null, null }, "[]", 0);
    defer std.testing.allocator.free(premium_json);
    var parsed_premium = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, premium_json, .{});
    defer parsed_premium.deinit();
    try std.testing.expect(parsed_premium.value.object.get("is_supporter").?.bool);
    try std.testing.expectEqual(@as(i64, 2), parsed_premium.value.object.get("support_level").?.integer);
}
