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

fn writeUserCore(writer: *std.Io.Writer, user: domain.User, profile_summary: ?domain.ProfileSummary, country_visible: bool) !void {
    try writer.print("{{\"id\":{d},\"username\":", .{user.id});
    try std.json.Stringify.value(user.name, .{}, writer);
    try writer.writeAll(",\"avatar_url\":");
    var avatar_buf: [96]u8 = undefined;
    const avatar_url = if (profile_summary) |summary|
        if (summary.avatar_version > 0)
            try std.fmt.bufPrint(&avatar_buf, "https://a.kai.ovh/{d}?v={d}", .{ user.id, summary.avatar_version })
        else
            try std.fmt.bufPrint(&avatar_buf, "https://a.kai.ovh/{d}", .{user.id})
    else
        try std.fmt.bufPrint(&avatar_buf, "https://a.kai.ovh/{d}", .{user.id});
    try std.json.Stringify.value(avatar_url, .{}, writer);
    try writer.writeAll(",\"country_code\":");
    try std.json.Stringify.value(if (country_visible) user.country[0..] else "XX", .{}, writer);
    try writer.writeAll(",\"cover_url\":");
    if (user.banner_version > 0) {
        var cover_buf: [128]u8 = undefined;
        const cover_url = try std.fmt.bufPrint(&cover_buf, "https://assets.kai.ovh/banners/{d}/cover.jpg?v={d}", .{ user.id, user.banner_version });
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
        try writer.print("{{\"id\":{d},\"name\":", .{team.id});
        try std.json.Stringify.value(team.name(), .{}, writer);
        try writer.writeAll(",\"short_name\":");
        try std.json.Stringify.value(team.shortName(), .{}, writer);
        try writer.writeAll(",\"flag_url\":");
        if (team.flag_version > 0) {
            const flag_url = try std.fmt.bufPrint(&flag_buf, "https://assets.kai.ovh/teams/{d}/flag?v={d}", .{ team.id, team.flag_version });
            try std.json.Stringify.value(flag_url, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeByte('}');
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"profile_colour\":");
    try std.json.Stringify.value(roleColour(user.privileges), .{}, writer);
    try writer.print(",\"is_active\":{s},\"is_online\":{s},\"is_supporter\":{s},\"support_level\":{d},\"is_admin\":{s},\"is_gmt\":{s},\"is_qat\":false,\"is_bng\":{s},\"is_bot\":{s},\"pm_friends_only\":false,\"follower_count\":{d},\"mapping_follower_count\":0", .{
        if (user.restricted) "false" else "true",
        if (user.online or user.id == 3) "true" else "false",
        "true",
        @as(u8, if (user.privileges & (@as(u32, 1) << 5) != 0) 2 else 1),
        if (user.privileges & (@as(u32, 1) << 13) != 0) "true" else "false",
        if (user.privileges & ((@as(u32, 1) << 12) | (@as(u32, 1) << 13) | (@as(u32, 1) << 14)) != 0) "true" else "false",
        if (user.privileges & (@as(u32, 1) << 11) != 0) "true" else "false",
        if (user.id == 3) "true" else "false",
        if (profile_summary) |summary| summary.follower_count else @max(0, user.follower_count),
    });
}

fn writeStatistics(writer: *std.Io.Writer, maybe_stats: ?domain.Stats, restricted: bool) !void {
    const stats = if (restricted) domain.Stats{} else maybe_stats orelse domain.Stats{};
    const ranked = !restricted and maybe_stats != null and stats.plays > 0;
    const level = if (restricted) domain.LevelProgress{ .current = 0, .progress = 0 } else domain.levelFromTotalScore(stats.total_score);
    try writer.print("{{\"level\":{{\"current\":{d},\"progress\":{d}}},\"is_ranked\":", .{ level.current, level.progress });
    try writer.writeAll(if (ranked) "true" else "false");
    try writer.writeAll(",\"global_rank\":");
    if (ranked and stats.global_rank > 0) try writer.print("{d}", .{stats.global_rank}) else try writer.writeAll("null");
    try writer.writeAll(",\"country_rank\":");
    if (ranked and stats.country_rank > 0) try writer.print("{d}", .{stats.country_rank}) else try writer.writeAll("null");
    try writer.print(",\"pp\":{d},\"ranked_score\":{d},\"hit_accuracy\":{d:.6},\"play_count\":{d},\"play_time\":{d},\"total_score\":{d},\"total_hits\":{d},\"maximum_combo\":{d},\"replays_watched_by_others\":{d},\"grade_counts\":{{\"ssh\":{d},\"ss\":{d},\"sh\":{d},\"s\":{d},\"a\":{d}}}}}", .{
        stats.pp,
        stats.ranked_score,
        stats.accuracy * 100.0,
        stats.plays,
        stats.play_time,
        stats.total_score,
        stats.total_hits,
        stats.max_combo,
        stats.replay_views,
        stats.grade_ssh,
        stats.grade_ss,
        stats.grade_sh,
        stats.grade_s,
        stats.grade_a,
    });
}

pub fn writeRankingStatistics(writer: *std.Io.Writer, user: domain.User, stats: domain.Stats, global_rank: i32, country_rank: i32) !void {
    try writer.writeAll("{\"user\":");
    try writeUserCore(writer, user, null, true);
    try writer.writeAll("},\"level\":{\"current\":0,\"progress\":0},\"is_ranked\":true,\"global_rank\":");
    if (global_rank > 0) try writer.print("{d}", .{global_rank}) else try writer.writeAll("null");
    try writer.writeAll(",\"country_rank\":");
    if (country_rank > 0) try writer.print("{d}", .{country_rank}) else try writer.writeAll("null");
    try writer.print(",\"pp\":{d},\"ranked_score\":{d},\"hit_accuracy\":{d:.6},\"play_count\":{d},\"play_time\":{d},\"total_score\":{d},\"total_hits\":{d},\"maximum_combo\":{d},\"replays_watched_by_others\":{d},\"grade_counts\":{{\"ssh\":0,\"ss\":0,\"sh\":0,\"s\":0,\"a\":0}}}}", .{
        stats.pp,
        stats.ranked_score,
        stats.accuracy * 100.0,
        stats.plays,
        stats.play_time,
        stats.total_score,
        stats.total_hits,
        stats.max_combo,
        stats.replay_views,
    });
}

pub fn writeCompact(writer: *std.Io.Writer, user: domain.User, country_visible: bool) !void {
    try writeUserCore(writer, user, null, country_visible);
    try writer.writeByte('}');
}

fn batchProfileSummary(visibility: domain.BatchUserVisibility) domain.ProfileSummary {
    return .{
        .avatar_version = @max(0, visibility.avatar_version),
        .show_country = visibility.show_country,
        .show_profile_stats = visibility.show_profile_stats,
        .follower_count = @max(0, visibility.follower_count),
    };
}

fn batchStatsHidden(user: domain.User, visibility: domain.BatchUserVisibility, owner: bool) bool {
    return user.restricted or user.id == 3 or (!owner and !visibility.show_profile_stats);
}

pub fn writeBatchWithRulesets(writer: *std.Io.Writer, user: domain.User, stats: [4]?domain.Stats, visibility: domain.BatchUserVisibility, owner: bool) !void {
    const summary = batchProfileSummary(visibility);
    try writeUserCore(writer, user, summary, owner or visibility.show_country);
    try writer.writeAll(",\"statistics_rulesets\":{");
    const names = [_][]const u8{ "osu", "taiko", "fruits", "mania" };
    for (names, 0..) |name, index| {
        if (index != 0) try writer.writeByte(',');
        try std.json.Stringify.value(name, .{}, writer);
        try writer.writeByte(':');
        try writeStatistics(writer, stats[index], batchStatsHidden(user, visibility, owner));
    }
    try writer.writeByte('}');
    try writer.writeByte('}');
}

pub fn writeLookup(writer: *std.Io.Writer, user: domain.User, stats: ?domain.Stats, requested_ruleset: ?u8, visibility: domain.BatchUserVisibility, owner: bool) !void {
    const summary = batchProfileSummary(visibility);
    try writeUserCore(writer, user, summary, owner or visibility.show_country);
    try writer.writeAll(",\"global_rank\":");
    if (requested_ruleset) |ruleset_id| {
        try writer.writeAll("{\"rank\":");
        const visible_stats = !batchStatsHidden(user, visibility, owner);
        if (visible_stats and stats != null and stats.?.plays > 0 and stats.?.global_rank > 0)
            try writer.print("{d}", .{stats.?.global_rank})
        else
            try writer.writeAll("null");
        try writer.print(",\"ruleset_id\":{d}}}", .{ruleset_id});
    } else {
        try writer.writeAll("null");
    }
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

fn rulesetName(ruleset_id: u8) []const u8 {
    return switch (ruleset_id) {
        1 => "taiko",
        2 => "fruits",
        3 => "mania",
        else => "osu",
    };
}

fn writeProfileSummary(writer: *std.Io.Writer, summary: domain.ProfileSummary, ruleset_id: u8, show_play_history: bool) !void {
    const joined = isoTimestamp(summary.created_at);
    try writer.writeAll(",\"join_date\":");
    try std.json.Stringify.value(&joined, .{}, writer);
    try writer.writeAll(",\"last_visit\":");
    if (summary.last_visit > 0) {
        const last_visit = isoTimestamp(summary.last_visit);
        try std.json.Stringify.value(&last_visit, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"title\":");
    try std.json.Stringify.value(summary.title(), .{}, writer);
    try writer.writeAll(",\"location\":");
    try std.json.Stringify.value(summary.location(), .{}, writer);
    try writer.writeAll(",\"website\":");
    try std.json.Stringify.value(summary.website(), .{}, writer);
    try writer.writeAll(",\"playmode\":");
    try std.json.Stringify.value(rulesetName(ruleset_id), .{}, writer);
    try writer.print(",\"favourite_beatmapset_count\":{d},\"ranked_beatmapset_count\":{d},\"loved_beatmapset_count\":{d},\"pending_beatmapset_count\":{d},\"graveyard_beatmapset_count\":{d},\"nominated_beatmapset_count\":{d},\"guest_beatmapset_count\":{d},\"beatmap_playcounts_count\":{d},\"kudosu\":{{\"total\":0,\"available\":0}}", .{
        summary.favourite_count,
        summary.ranked_count,
        summary.loved_count,
        summary.pending_count,
        summary.graveyard_count,
        summary.nominated_count,
        summary.guest_count,
        if (show_play_history) summary.played_beatmap_count else 0,
    });
}

pub fn meOwnedWithProfile(allocator: std.mem.Allocator, user: domain.User, stats: [4]?domain.Stats, achievements_json: []const u8, summary: domain.ProfileSummary) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try writeUserCore(&output.writer, user, summary, true);
    try writeProfileSummary(&output.writer, summary, summary.preferred_mode, true);
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

pub fn meOwned(allocator: std.mem.Allocator, user: domain.User, stats: [4]?domain.Stats, achievements_json: []const u8, last_visit_epoch: i64) ![]u8 {
    const summary = try domain.ProfileSummary.init(0, last_visit_epoch, 0, 0, "", "", "");
    return meOwnedWithProfile(allocator, user, stats, achievements_json, summary);
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

fn scoreCountsForView(counts: domain.UserScoreCounts, show_stats: bool, show_recent: bool) domain.UserScoreCounts {
    return .{
        .best = if (show_stats) counts.best else 0,
        .firsts = if (show_stats) counts.firsts else 0,
        .recent = if (show_recent) counts.recent else 0,
        .pinned = if (show_stats) counts.pinned else 0,
    };
}

fn writeRankHistory(writer: *std.Io.Writer, ruleset_id: u8, history: domain.StatsHistory) !void {
    try writer.writeAll("{\"mode\":");
    try std.json.Stringify.value(rulesetName(ruleset_id), .{}, writer);
    try writer.writeAll(",\"data\":[");
    const raw = history.slice();
    if (raw.len != 0) {
        const wanted_points: usize = 89;
        const start = raw.len -| wanted_points;
        const points = raw[start..];
        const duplicate_single: usize = @intFromBool(points.len == 1);
        const padding = wanted_points - points.len - duplicate_single;
        for (0..padding) |index| {
            if (index != 0) try writer.writeByte(',');
            try writer.writeByte('0');
        }
        if (duplicate_single != 0) {
            if (padding != 0) try writer.writeByte(',');
            try writer.print("{d}", .{points[0].global_rank});
        }
        for (points, 0..) |point, index| {
            if (padding != 0 or duplicate_single != 0 or index != 0) try writer.writeByte(',');
            try writer.print("{d}", .{point.global_rank});
        }
    }
    try writer.writeAll("]}");
}

pub fn writeSiteStatsHistory(writer: *std.Io.Writer, history: domain.StatsHistory) !void {
    try writer.writeAll("\"rank_history\":[");
    for (history.slice(), 0..) |point, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{point.global_rank});
    }
    try writer.writeAll("],\"pp_history\":[");
    for (history.slice(), 0..) |point, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{point.pp});
    }
    try writer.writeAll("],\"history_days\":[");
    for (history.slice(), 0..) |point, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{point.day});
    }
    try writer.writeByte(']');
}

pub const ProfileView = struct {
    summary: domain.ProfileSummary = .{},
    requested_ruleset: u8 = 0,
    owner: bool = false,
    monthly_playcounts_json: []const u8 = "[]",
    replays_watched_counts_json: []const u8 = "[]",
    stats_history: domain.StatsHistory = .{},
};

pub fn profileOwnedWithView(allocator: std.mem.Allocator, user: domain.User, stats: ?domain.Stats, score_counts: domain.UserScoreCounts, sources: ProfileSources, achievements_json: []const u8, view: ProfileView) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const show_country = view.owner or view.summary.show_country;
    const show_stats = view.owner or view.summary.show_profile_stats;
    const show_recent = view.owner or view.summary.show_recent_scores;
    const show_historical = show_stats and show_recent;
    const visible_stats_history = if (show_stats and !user.restricted) view.stats_history else domain.StatsHistory{};
    try writeUserCore(&output.writer, user, view.summary, show_country);
    try writeProfileSummary(&output.writer, view.summary, view.requested_ruleset, show_historical);
    try output.writer.writeAll(",\"statistics\":");
    try writeStatistics(&output.writer, if (show_stats) stats else null, user.restricted or !show_stats);
    try output.writer.writeAll(",\"rank_history\":");
    try writeRankHistory(&output.writer, view.requested_ruleset, visible_stats_history);
    try output.writer.writeAll(",\"zigcho_statistics\":{\"stable\":");
    try writeStatistics(&output.writer, if (show_stats) sources.stable_stats else null, user.restricted or !show_stats);
    try output.writer.writeAll(",\"lazer\":");
    try writeStatistics(&output.writer, if (show_stats) sources.lazer_stats else null, user.restricted or !show_stats);
    try output.writer.writeAll("},\"zigcho_score_counts\":{\"stable\":");
    try writeScoreCounts(&output.writer, scoreCountsForView(sources.stable_counts, show_stats, show_recent));
    try output.writer.writeAll(",\"lazer\":");
    try writeScoreCounts(&output.writer, scoreCountsForView(sources.lazer_counts, show_stats, show_recent));
    try output.writer.writeByte('}');
    try output.writer.print(",\"scores_best_count\":{d},\"scores_first_count\":{d},\"scores_recent_count\":{d},\"scores_pinned_count\":{d},\"groups\":", .{
        if (show_stats) score_counts.best else 0,
        if (show_stats) score_counts.firsts else 0,
        if (show_recent) score_counts.recent else 0,
        if (show_stats) score_counts.pinned else 0,
    });
    try writeGroups(&output.writer, user.privileges);
    try output.writer.writeAll(",\"badges\":[],\"profile_order\":[");
    var order_written: usize = 0;
    if (show_recent) {
        try output.writer.writeAll("\"recent_activity\"");
        order_written += 1;
    }
    if (show_stats) {
        if (order_written != 0) try output.writer.writeByte(',');
        try output.writer.writeAll("\"top_ranks\"");
        order_written += 1;
    }
    if (show_historical) {
        if (order_written != 0) try output.writer.writeByte(',');
        try output.writer.writeAll("\"historical\"");
        order_written += 1;
    }
    for ([_][]const u8{ "beatmaps", "medals", "kudosu" }) |section| {
        if (order_written != 0) try output.writer.writeByte(',');
        try std.json.Stringify.value(section, .{}, &output.writer);
        order_written += 1;
    }
    try output.writer.writeAll("],\"user_achievements\":");
    try output.writer.writeAll(achievements_json);
    try output.writer.writeAll(",\"monthly_playcounts\":");
    if (show_historical) try output.writer.writeAll(view.monthly_playcounts_json) else try output.writer.writeAll("[]");
    try output.writer.writeAll(",\"replays_watched_counts\":");
    if (show_historical) try output.writer.writeAll(view.replays_watched_counts_json) else try output.writer.writeAll("[]");
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

pub fn profileOwned(allocator: std.mem.Allocator, user: domain.User, stats: ?domain.Stats, score_counts: domain.UserScoreCounts, sources: ProfileSources, achievements_json: []const u8) ![]u8 {
    const requested_ruleset: u8 = if (stats) |value| @intFromEnum(value.mode) else 0;
    return profileOwnedWithView(allocator, user, stats, score_counts, sources, achievements_json, .{ .requested_ruleset = requested_ruleset });
}

pub fn siteBotProfileOwned(allocator: std.mem.Allocator, user: domain.User) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"id\":{d},\"name\":", .{user.id});
    try std.json.Stringify.value(user.name, .{}, &output.writer);
    try output.writer.writeAll(",\"country\":\"XX\",\"privileges\":");
    try output.writer.print("{d}", .{user.privileges});
    try output.writer.writeAll(",\"created_at\":0,\"bio\":\"this is kai, the server bot.\",\"profile_source\":\"all\",\"preferred_mode\":0,\"avatar_version\":0,\"profile_title\":\"bot account\",\"profile_pronouns\":\"\",\"profile_location\":\"\",\"profile_website\":\"\",\"profile_accent\":\"bot\",\"banner_url\":null,\"team\":null,\"is_bot\":true,\"stats_public\":false,\"recent_scores_public\":false,\"selected_source\":\"all\",\"stats_source\":\"combined\",\"selected_mode\":0,\"selected_stats\":null,\"stats\":[],\"pinned_scores\":[],\"top_scores\":[],\"recent_scores\":[],\"first_place_count\":0,\"first_place_scores\":[],\"achievements\":[]}");
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

test "website bot profile contains identity without player data" {
    const json = try siteBotProfileOwned(std.testing.allocator, .{
        .id = 3,
        .name = "kai",
        .safe_name = "kai",
        .privileges = 24579,
    });
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 3), object.get("id").?.integer);
    try std.testing.expectEqualStrings("kai", object.get("name").?.string);
    try std.testing.expect(object.get("is_bot").?.bool);
    try std.testing.expect(!object.get("stats_public").?.bool);
    try std.testing.expectEqual(@as(usize, 0), object.get("stats").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), object.get("pinned_scores").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), object.get("top_scores").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), object.get("recent_scores").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), object.get("achievements").?.array.items.len);
}

test "lazer profile keeps a player with no scores unranked" {
    const profile = try profileOwnedWithView(std.testing.allocator, .{
        .id = 4,
        .name = "new player",
        .safe_name = "new_player",
    }, null, .{}, .{}, "[]", .{});
    defer std.testing.allocator.free(profile);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, profile, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("statistics").?.object.get("is_ranked").?.bool);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("rank_history").?.object.get("data").?.array.items.len);
}

test "batch and lookup user JSON keep pinned client stats contracts private" {
    const user: domain.User = .{
        .id = 4,
        .name = "raya",
        .safe_name = "raya",
        .country = .{ 'A', 'U' },
    };
    const visible: domain.BatchUserVisibility = .{ .avatar_version = 42 };
    const rulesets = [4]?domain.Stats{
        .{ .mode = .osu, .pp = 500, .plays = 10, .global_rank = 7, .country_rank = 2 },
        null,
        null,
        .{ .mode = .mania, .pp = 0, .plays = 0, .global_rank = 99, .country_rank = 9 },
    };
    var batch: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer batch.deinit();
    try writeBatchWithRulesets(&batch.writer, user, rulesets, visible, false);
    var parsed_batch = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, batch.written(), .{});
    defer parsed_batch.deinit();
    const batch_object = parsed_batch.value.object;
    try std.testing.expectEqualStrings("AU", batch_object.get("country_code").?.string);
    try std.testing.expectEqualStrings("https://a.kai.ovh/4?v=42", batch_object.get("avatar_url").?.string);
    const statistics_rulesets = batch_object.get("statistics_rulesets").?.object;
    try std.testing.expectEqual(@as(usize, 4), statistics_rulesets.count());
    try std.testing.expectEqual(@as(i64, 7), statistics_rulesets.get("osu").?.object.get("global_rank").?.integer);
    try std.testing.expect(statistics_rulesets.get("mania").?.object.get("global_rank").? == .null);
    try std.testing.expect(!statistics_rulesets.get("mania").?.object.get("is_ranked").?.bool);

    var lookup: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer lookup.deinit();
    try writeLookup(&lookup.writer, user, rulesets[0], 0, visible, false);
    var parsed_lookup = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lookup.written(), .{});
    defer parsed_lookup.deinit();
    try std.testing.expectEqual(@as(i64, 7), parsed_lookup.value.object.get("global_rank").?.object.get("rank").?.integer);
    try std.testing.expectEqual(@as(i64, 0), parsed_lookup.value.object.get("global_rank").?.object.get("ruleset_id").?.integer);
    try std.testing.expect(parsed_lookup.value.object.get("statistics_rulesets") == null);

    var lookup_without_ruleset: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer lookup_without_ruleset.deinit();
    try writeLookup(&lookup_without_ruleset.writer, user, null, null, visible, false);
    var parsed_lookup_without_ruleset = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lookup_without_ruleset.written(), .{});
    defer parsed_lookup_without_ruleset.deinit();
    try std.testing.expect(parsed_lookup_without_ruleset.value.object.get("global_rank").? == .null);

    const hidden: domain.BatchUserVisibility = .{ .avatar_version = 42, .show_country = false, .show_profile_stats = false };
    var hidden_batch: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer hidden_batch.deinit();
    try writeBatchWithRulesets(&hidden_batch.writer, user, rulesets, hidden, false);
    var parsed_hidden_batch = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, hidden_batch.written(), .{});
    defer parsed_hidden_batch.deinit();
    try std.testing.expectEqualStrings("XX", parsed_hidden_batch.value.object.get("country_code").?.string);
    try std.testing.expect(!parsed_hidden_batch.value.object.get("statistics_rulesets").?.object.get("osu").?.object.get("is_ranked").?.bool);
    try std.testing.expect(parsed_hidden_batch.value.object.get("statistics_rulesets").?.object.get("osu").?.object.get("global_rank").? == .null);

    var owner_lookup: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer owner_lookup.deinit();
    try writeLookup(&owner_lookup.writer, user, rulesets[0], 0, hidden, true);
    var parsed_owner_lookup = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, owner_lookup.written(), .{});
    defer parsed_owner_lookup.deinit();
    try std.testing.expectEqualStrings("AU", parsed_owner_lookup.value.object.get("country_code").?.string);
    try std.testing.expectEqual(@as(i64, 7), parsed_owner_lookup.value.object.get("global_rank").?.object.get("rank").?.integer);

    var restricted_batch: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer restricted_batch.deinit();
    var restricted = user;
    restricted.restricted = true;
    try writeBatchWithRulesets(&restricted_batch.writer, restricted, rulesets, visible, true);
    var parsed_restricted_batch = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, restricted_batch.written(), .{});
    defer parsed_restricted_batch.deinit();
    try std.testing.expect(!parsed_restricted_batch.value.object.get("is_active").?.bool);
    try std.testing.expect(!parsed_restricted_batch.value.object.get("statistics_rulesets").?.object.get("osu").?.object.get("is_ranked").?.bool);
    try std.testing.expect(parsed_restricted_batch.value.object.get("statistics_rulesets").?.object.get("osu").?.object.get("global_rank").? == .null);

    var bot_lookup: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bot_lookup.deinit();
    var bot = user;
    bot.id = 3;
    bot.name = "kai";
    try writeLookup(&bot_lookup.writer, bot, rulesets[0], 0, visible, false);
    var parsed_bot_lookup = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bot_lookup.written(), .{});
    defer parsed_bot_lookup.deinit();
    try std.testing.expect(parsed_bot_lookup.value.object.get("is_bot").?.bool);
    try std.testing.expect(parsed_bot_lookup.value.object.get("global_rank").?.object.get("rank").? == .null);

    var unranked_lookup: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer unranked_lookup.deinit();
    try writeLookup(&unranked_lookup.writer, user, rulesets[3], 3, visible, false);
    var parsed_unranked_lookup = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, unranked_lookup.written(), .{});
    defer parsed_unranked_lookup.deinit();
    try std.testing.expect(parsed_unranked_lookup.value.object.get("global_rank").?.object.get("rank").? == .null);
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
    var summary = try domain.ProfileSummary.init(1_700_000_000, 1_700_000_100, 42, 3, "mapper", "adelaide", "https://kai.ovh");
    summary.favourite_count = 2;
    summary.ranked_count = 3;
    summary.loved_count = 4;
    summary.pending_count = 5;
    summary.graveyard_count = 6;
    summary.nominated_count = 7;
    summary.played_beatmap_count = 8;
    var history: domain.StatsHistory = .{};
    history.len = 3;
    history.points[0] = .{ .day = 1_699_827_200, .pp = 300, .global_rank = 3 };
    history.points[1] = .{ .day = 1_699_913_600, .pp = 360, .global_rank = 2 };
    history.points[2] = .{ .day = 1_700_000_000, .pp = 424, .global_rank = 1 };
    const profile = try profileOwnedWithView(std.testing.allocator, user, stats, .{ .best = 2, .firsts = 1, .recent = 4 }, .{
        .stable_stats = .{ .pp = 300, .plays = 30 },
        .lazer_stats = .{ .pp = 124, .plays = 13 },
        .stable_counts = .{ .best = 1, .firsts = 1, .recent = 3, .pinned = 1 },
        .lazer_counts = .{ .best = 1, .recent = 1 },
    }, "[{\"achievement_id\":1,\"achieved_at\":42}]", .{ .summary = summary, .requested_ruleset = 3, .monthly_playcounts_json = "[{\"start_date\":\"2026-08-01T00:00:00Z\",\"count\":43}]", .replays_watched_counts_json = "[{\"start_date\":\"2026-08-01\",\"count\":7}]", .stats_history = history });
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
    try std.testing.expectEqualStrings("https://a.kai.ovh/4?v=42", object.get("avatar_url").?.string);
    try std.testing.expectEqualStrings("https://assets.kai.ovh/banners/4/cover.jpg?v=42", object.get("cover_url").?.string);
    try std.testing.expectEqualStrings("2023-11-14T22:13:20Z", object.get("join_date").?.string);
    try std.testing.expectEqualStrings("2023-11-14T22:15:00Z", object.get("last_visit").?.string);
    try std.testing.expectEqualStrings("mapper", object.get("title").?.string);
    try std.testing.expectEqualStrings("adelaide", object.get("location").?.string);
    try std.testing.expectEqualStrings("https://kai.ovh", object.get("website").?.string);
    try std.testing.expectEqualStrings("mania", object.get("playmode").?.string);
    try std.testing.expectEqual(@as(i64, 2), object.get("favourite_beatmapset_count").?.integer);
    try std.testing.expectEqual(@as(i64, 3), object.get("ranked_beatmapset_count").?.integer);
    try std.testing.expectEqual(@as(i64, 8), object.get("beatmap_playcounts_count").?.integer);
    try std.testing.expectEqual(@as(i64, 0), object.get("kudosu").?.object.get("total").?.integer);
    try std.testing.expectEqual(@as(i64, 7), object.get("team").?.object.get("id").?.integer);
    try std.testing.expectEqualStrings("KAI", object.get("team").?.object.get("short_name").?.string);
    try std.testing.expectEqual(@as(i64, 424), object.get("statistics").?.object.get("pp").?.integer);
    try std.testing.expectApproxEqAbs(@as(f64, 93.53), object.get("statistics").?.object.get("hit_accuracy").?.float, 0.0001);
    const rank_history = object.get("rank_history").?.object;
    try std.testing.expectEqualStrings("mania", rank_history.get("mode").?.string);
    try std.testing.expectEqual(@as(usize, 89), rank_history.get("data").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 3), rank_history.get("data").?.array.items[86].integer);
    try std.testing.expectEqual(@as(i64, 1), rank_history.get("data").?.array.items[88].integer);
    try std.testing.expectEqual(@as(i64, 300), object.get("zigcho_statistics").?.object.get("stable").?.object.get("pp").?.integer);
    try std.testing.expectEqual(@as(i64, 124), object.get("zigcho_statistics").?.object.get("lazer").?.object.get("pp").?.integer);
    try std.testing.expectEqual(@as(i64, 3), object.get("zigcho_score_counts").?.object.get("stable").?.object.get("recent").?.integer);
    try std.testing.expectEqual(@as(i64, 1), object.get("zigcho_score_counts").?.object.get("lazer").?.object.get("recent").?.integer);
    const profile_order = object.get("profile_order").?.array.items;
    try std.testing.expectEqual(@as(usize, 6), profile_order.len);
    try std.testing.expectEqualStrings("recent_activity", profile_order[0].string);
    try std.testing.expectEqualStrings("top_ranks", profile_order[1].string);
    try std.testing.expectEqualStrings("historical", profile_order[2].string);
    try std.testing.expectEqualStrings("beatmaps", profile_order[3].string);
    try std.testing.expectEqualStrings("medals", profile_order[4].string);
    try std.testing.expectEqualStrings("kudosu", profile_order[5].string);
    try std.testing.expectEqual(@as(i64, 43), object.get("monthly_playcounts").?.array.items[0].object.get("count").?.integer);
    const watched_counts = object.get("replays_watched_counts").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), watched_counts.len);
    try std.testing.expectEqualStrings("2026-08-01", watched_counts[0].object.get("start_date").?.string);
    try std.testing.expectEqual(@as(i64, 7), watched_counts[0].object.get("count").?.integer);

    summary.show_country = false;
    summary.show_profile_stats = false;
    summary.show_recent_scores = false;
    const private_profile = try profileOwnedWithView(std.testing.allocator, user, stats, .{ .best = 2, .firsts = 1, .recent = 4, .pinned = 1 }, .{
        .stable_stats = .{ .pp = 300, .plays = 30 },
        .lazer_stats = .{ .pp = 124, .plays = 13 },
        .stable_counts = .{ .best = 2, .firsts = 1, .recent = 3, .pinned = 1 },
        .lazer_counts = .{ .best = 4, .firsts = 2, .recent = 5, .pinned = 3 },
    }, "[]", .{ .summary = summary, .requested_ruleset = 0 });
    defer std.testing.allocator.free(private_profile);
    var parsed_private = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, private_profile, .{});
    defer parsed_private.deinit();
    const private_object = parsed_private.value.object;
    try std.testing.expectEqualStrings("XX", private_object.get("country_code").?.string);
    try std.testing.expect(!private_object.get("statistics").?.object.get("is_ranked").?.bool);
    try std.testing.expectEqual(@as(i64, 0), private_object.get("statistics").?.object.get("pp").?.integer);
    try std.testing.expectEqual(@as(usize, 0), private_object.get("rank_history").?.object.get("data").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 0), private_object.get("scores_best_count").?.integer);
    try std.testing.expectEqual(@as(i64, 0), private_object.get("scores_recent_count").?.integer);
    try std.testing.expectEqual(@as(i64, 0), private_object.get("zigcho_score_counts").?.object.get("stable").?.object.get("best").?.integer);
    try std.testing.expectEqual(@as(i64, 0), private_object.get("zigcho_score_counts").?.object.get("stable").?.object.get("recent").?.integer);
    try std.testing.expectEqual(@as(i64, 0), private_object.get("zigcho_score_counts").?.object.get("lazer").?.object.get("pinned").?.integer);
    try std.testing.expectEqual(@as(i64, 0), private_object.get("zigcho_score_counts").?.object.get("lazer").?.object.get("recent").?.integer);
    try std.testing.expectEqual(@as(usize, 0), private_object.get("monthly_playcounts").?.array.items.len);
    const private_order = private_object.get("profile_order").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), private_order.len);
    try std.testing.expectEqualStrings("beatmaps", private_order[0].string);
    try std.testing.expectEqualStrings("medals", private_order[1].string);
    try std.testing.expectEqualStrings("kudosu", private_order[2].string);

    summary.show_profile_stats = true;
    var stale_history = history;
    stale_history.points[stale_history.len - 1].pp = 400;
    stale_history.points[stale_history.len - 1].global_rank = 2;
    const stats_only_profile = try profileOwnedWithView(std.testing.allocator, user, stats, .{ .best = 2, .recent = 4 }, .{
        .stable_counts = .{ .best = 2, .recent = 3, .pinned = 1 },
        .lazer_counts = .{ .best = 4, .recent = 5, .pinned = 3 },
    }, "[]", .{ .summary = summary, .requested_ruleset = 0, .replays_watched_counts_json = "[{\"start_date\":\"2026-08-01\",\"count\":7}]", .stats_history = stale_history });
    defer std.testing.allocator.free(stats_only_profile);
    var parsed_stats_only = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stats_only_profile, .{});
    defer parsed_stats_only.deinit();
    const stats_only_counts = parsed_stats_only.value.object.get("zigcho_score_counts").?.object;
    try std.testing.expectEqual(@as(i64, 2), stats_only_counts.get("stable").?.object.get("best").?.integer);
    try std.testing.expectEqual(@as(i64, 1), stats_only_counts.get("stable").?.object.get("pinned").?.integer);
    try std.testing.expectEqual(@as(i64, 0), stats_only_counts.get("stable").?.object.get("recent").?.integer);
    try std.testing.expectEqual(@as(i64, 4), stats_only_counts.get("lazer").?.object.get("best").?.integer);
    try std.testing.expectEqual(@as(i64, 0), stats_only_counts.get("lazer").?.object.get("recent").?.integer);
    const stats_only_history = parsed_stats_only.value.object.get("rank_history").?.object.get("data").?.array.items;
    try std.testing.expectEqual(@as(usize, 89), stats_only_history.len);
    try std.testing.expectEqual(@as(i64, 3), stats_only_history[86].integer);
    try std.testing.expectEqual(@as(i64, 2), stats_only_history[stats_only_history.len - 1].integer);
    try std.testing.expectEqual(@as(i64, 0), parsed_stats_only.value.object.get("scores_recent_count").?.integer);
    try std.testing.expectEqual(@as(i64, 0), parsed_stats_only.value.object.get("beatmap_playcounts_count").?.integer);
    try std.testing.expectEqual(@as(usize, 0), parsed_stats_only.value.object.get("monthly_playcounts").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed_stats_only.value.object.get("replays_watched_counts").?.array.items.len);
    var stats_only_has_historical = false;
    var stats_only_has_recent = false;
    for (parsed_stats_only.value.object.get("profile_order").?.array.items) |section| {
        if (std.mem.eql(u8, section.string, "historical")) stats_only_has_historical = true;
        if (std.mem.eql(u8, section.string, "recent_activity")) stats_only_has_recent = true;
    }
    try std.testing.expect(!stats_only_has_historical);
    try std.testing.expect(!stats_only_has_recent);

    summary.show_profile_stats = false;
    summary.show_recent_scores = true;
    const recent_only_profile = try profileOwnedWithView(std.testing.allocator, user, stats, .{ .best = 2, .recent = 4 }, .{}, "[]", .{ .summary = summary, .requested_ruleset = 0, .monthly_playcounts_json = "[{\"start_date\":\"2026-08-01T00:00:00Z\",\"count\":43}]" });
    defer std.testing.allocator.free(recent_only_profile);
    var parsed_recent_only = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, recent_only_profile, .{});
    defer parsed_recent_only.deinit();
    try std.testing.expectEqual(@as(i64, 4), parsed_recent_only.value.object.get("scores_recent_count").?.integer);
    try std.testing.expectEqual(@as(i64, 0), parsed_recent_only.value.object.get("beatmap_playcounts_count").?.integer);
    try std.testing.expectEqual(@as(usize, 0), parsed_recent_only.value.object.get("monthly_playcounts").?.array.items.len);
    var recent_only_has_historical = false;
    for (parsed_recent_only.value.object.get("profile_order").?.array.items) |section| {
        if (std.mem.eql(u8, section.string, "historical")) recent_only_has_historical = true;
    }
    try std.testing.expect(!recent_only_has_historical);

    summary.show_profile_stats = true;
    const owner_profile = try profileOwnedWithView(std.testing.allocator, user, stats, .{ .best = 2, .recent = 4 }, .{
        .stable_counts = .{ .best = 2, .recent = 3 },
        .lazer_counts = .{ .best = 4, .recent = 5 },
    }, "[]", .{ .summary = summary, .requested_ruleset = 0, .owner = true });
    defer std.testing.allocator.free(owner_profile);
    var parsed_owner = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, owner_profile, .{});
    defer parsed_owner.deinit();
    try std.testing.expectEqualStrings("AU", parsed_owner.value.object.get("country_code").?.string);
    try std.testing.expectEqual(@as(i64, 424), parsed_owner.value.object.get("statistics").?.object.get("pp").?.integer);
    try std.testing.expectEqual(@as(i64, 3), parsed_owner.value.object.get("zigcho_score_counts").?.object.get("stable").?.object.get("recent").?.integer);
    try std.testing.expectEqual(@as(i64, 5), parsed_owner.value.object.get("zigcho_score_counts").?.object.get("lazer").?.object.get("recent").?.integer);
    try std.testing.expectEqual(@as(i64, 8), parsed_owner.value.object.get("beatmap_playcounts_count").?.integer);

    const me_json = try meOwnedWithProfile(std.testing.allocator, user, .{ stats, null, null, null }, "[]", summary);
    defer std.testing.allocator.free(me_json);
    var parsed_me = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, me_json, .{});
    defer parsed_me.deinit();
    try std.testing.expectEqualStrings("2023-11-14T22:13:20Z", parsed_me.value.object.get("join_date").?.string);
    try std.testing.expectEqualStrings("2023-11-14T22:15:00Z", parsed_me.value.object.get("last_visit").?.string);
    try std.testing.expectEqualStrings("mania", parsed_me.value.object.get("playmode").?.string);
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
