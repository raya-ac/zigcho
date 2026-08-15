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

fn writeUserCore(writer: *std.Io.Writer, user: domain.User) !void {
    try writer.print("{{\"id\":{d},\"username\":", .{user.id});
    try std.json.Stringify.value(user.name, .{}, writer);
    try writer.print(",\"avatar_url\":\"https://a.kai.ovh/{d}\",\"country_code\":", .{user.id});
    try std.json.Stringify.value(&user.country, .{}, writer);
    try writer.print(",\"is_active\":{s},\"is_online\":true,\"is_supporter\":{s},\"support_level\":{d},\"is_admin\":{s},\"is_gmt\":{s},\"is_qat\":false,\"is_bng\":{s},\"is_bot\":{s},\"pm_friends_only\":false", .{
        if (user.restricted) "false" else "true",
        "true",
        @as(u8, if (user.privileges & (@as(u32, 1) << 5) != 0) 2 else 1),
        if (user.privileges & (@as(u32, 1) << 13) != 0) "true" else "false",
        if (user.privileges & (@as(u32, 1) << 12) != 0) "true" else "false",
        if (user.privileges & (@as(u32, 1) << 11) != 0) "true" else "false",
        if (user.id == 3) "true" else "false",
    });
}

fn writeStatistics(writer: *std.Io.Writer, maybe_stats: ?domain.Stats, restricted: bool) !void {
    const stats = maybe_stats orelse domain.Stats{};
    try writer.writeAll("{\"level\":{\"current\":0,\"progress\":0},\"is_ranked\":");
    try writer.writeAll(if (restricted) "false" else "true");
    try writer.writeAll(",\"global_rank\":");
    if (!restricted and stats.global_rank > 0) try writer.print("{d}", .{stats.global_rank}) else try writer.writeAll("null");
    try writer.print(",\"country_rank\":null,\"pp\":{d},\"ranked_score\":{d},\"hit_accuracy\":{d:.6},\"play_count\":{d},\"play_time\":{d},\"total_score\":{d},\"total_hits\":{d},\"maximum_combo\":{d},\"replays_watched_by_others\":0,\"grade_counts\":{{\"ssh\":0,\"ss\":0,\"sh\":0,\"s\":0,\"a\":0}}}}", .{
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

pub fn meOwned(allocator: std.mem.Allocator, user: domain.User, stats: [4]?domain.Stats) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try writeUserCore(&output.writer, user);
    try output.writer.writeAll(",\"statistics_rulesets\":{");
    const names = [_][]const u8{ "osu", "taiko", "fruits", "mania" };
    for (names, 0..) |name, index| {
        if (index != 0) try output.writer.writeByte(',');
        try std.json.Stringify.value(name, .{}, &output.writer);
        try output.writer.writeByte(':');
        try writeStatistics(&output.writer, stats[index], user.restricted);
    }
    try output.writer.writeAll("},\"groups\":[]}");
    return output.toOwnedSlice();
}

pub fn profileOwned(allocator: std.mem.Allocator, user: domain.User, stats: ?domain.Stats, score_counts: domain.UserScoreCounts) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try writeUserCore(&output.writer, user);
    try output.writer.writeAll(",\"statistics\":");
    try writeStatistics(&output.writer, stats, user.restricted);
    try output.writer.print(",\"scores_best_count\":{d},\"scores_first_count\":{d},\"scores_recent_count\":{d},\"scores_pinned_count\":{d},\"groups\":[],\"badges\":[],\"user_achievements\":[],\"monthly_playcounts\":[],\"replays_watched_counts\":[]}}", .{ score_counts.best, score_counts.firsts, score_counts.recent, score_counts.pinned });
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
    };
    const stats: domain.Stats = .{ .pp = 424, .ranked_score = 3_442_127, .total_score = 9_000_000, .plays = 43, .play_time = 100, .total_hits = 1234, .accuracy = 0.9353, .max_combo = 228, .global_rank = 1 };
    const profile = try profileOwned(std.testing.allocator, user, stats, .{ .best = 2, .firsts = 1, .recent = 4 });
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
    try std.testing.expectEqual(@as(i64, 424), object.get("statistics").?.object.get("pp").?.integer);
    try std.testing.expectApproxEqAbs(@as(f64, 93.53), object.get("statistics").?.object.get("hit_accuracy").?.float, 0.0001);

    const me_json = try meOwned(std.testing.allocator, user, .{ stats, null, null, null });
    defer std.testing.allocator.free(me_json);
    var parsed_me = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, me_json, .{});
    defer parsed_me.deinit();
    try std.testing.expectEqual(@as(i64, 43), parsed_me.value.object.get("statistics_rulesets").?.object.get("osu").?.object.get("play_count").?.integer);
    try std.testing.expectEqual(@as(i64, 0), parsed_me.value.object.get("statistics_rulesets").?.object.get("mania").?.object.get("play_count").?.integer);

    const regular_user: domain.User = .{
        .id = 5,
        .name = "regular",
        .safe_name = "regular",
        .privileges = 3,
    };
    const regular_json = try meOwned(std.testing.allocator, regular_user, .{ null, null, null, null });
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
    const premium_json = try meOwned(std.testing.allocator, premium_user, .{ null, null, null, null });
    defer std.testing.allocator.free(premium_json);
    var parsed_premium = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, premium_json, .{});
    defer parsed_premium.deinit();
    try std.testing.expect(parsed_premium.value.object.get("is_supporter").?.bool);
    try std.testing.expectEqual(@as(i64, 2), parsed_premium.value.object.get("support_level").?.integer);
}
