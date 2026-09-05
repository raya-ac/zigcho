const std = @import("std");
const domain = @import("domain.zig");
const stable_score = @import("stable_score.zig");
const achievements = @import("achievements.zig");

pub const BeatmapState = struct {
    id: i32,
    set_id: i32,
    plays: i32,
    passes: i32,
    last_update: i64 = 0,
    previous_best: ?domain.StablePersonalBest = null,
};

fn writeInteger(writer: *std.Io.Writer, value: i64) !void {
    if (value != 0) try writer.print("{d}", .{value});
}

fn writeDecimal(writer: *std.Io.Writer, value: f64, comptime precision: usize) !void {
    comptime std.debug.assert(precision > 0 and precision <= 3);
    if (!std.math.isFinite(value)) return error.InvalidScoreChartValue;
    var buffer: [384]u8 = undefined;
    const bits: u64 = @bitCast(@abs(value));
    const exponent: u16 = @intCast((bits >> 52) & 0x7ff);
    const formatted = if (exponent >= 1075)
        // These f64 values are already integral, so there is no rounding tie.
        try std.fmt.bufPrint(&buffer, "{d:." ++ std.fmt.comptimePrint("{d}", .{precision}) ++ "}", .{value})
    else blk: {
        // Round the exact binary rational, ties to even, like Python round().
        // Multiplying an f64 by 100 first loses cases such as 2.675 -> 2.67.
        const shift: u16 = if (exponent == 0) 1074 else 1075 - exponent;
        if (shift >= 128) return;
        const mantissa = (bits & 0x000fffffffffffff) | (if (exponent == 0) @as(u64, 0) else @as(u64, 1) << 52);
        const factor = comptime std.math.pow(u128, 10, precision);
        const numerator = @as(u128, mantissa) * factor;
        const denominator = @as(u128, 1) << @as(u7, @intCast(shift));
        const integral = numerator / denominator;
        const remainder = numerator % denominator;
        const half = denominator / 2;
        const rounded = integral + @intFromBool(remainder > half or (remainder == half and integral % 2 != 0));
        // chart_entry emits an empty field for zero, including rounded zero.
        if (rounded == 0) return;
        break :blk try std.fmt.bufPrint(&buffer, "{s}{d}.{d:0>" ++ std.fmt.comptimePrint("{d}", .{precision}) ++ "}", .{
            if (value < 0) "-" else "", rounded / factor, rounded % factor,
        });
    };
    // Integral floats retain one decimal place (100.0, not 100).
    const decimal = std.mem.indexOfScalar(u8, formatted, '.') orelse return writer.writeAll(formatted);
    var end = formatted.len;
    while (end > decimal + 2 and formatted[end - 1] == '0') end -= 1;
    try writer.writeAll(formatted[0..end]);
}

fn integerEntry(writer: *std.Io.Writer, name: []const u8, before: ?i64, after: i64) !void {
    try writer.print("|{s}Before:", .{name});
    if (before) |value| try writeInteger(writer, value);
    try writer.print("|{s}After:", .{name});
    try writeInteger(writer, after);
}

fn decimalEntry(writer: *std.Io.Writer, name: []const u8, before: ?f64, after: f64, comptime precision: usize) !void {
    try writer.print("|{s}Before:", .{name});
    if (before) |value| try writeDecimal(writer, value, precision);
    try writer.print("|{s}After:", .{name});
    try writeDecimal(writer, after, precision);
}

fn writeMapDate(writer: *std.Io.Writer, timestamp: i64) !void {
    // Unknown/imported dates stay empty; do not invent an approval date.
    if (timestamp <= 0 or timestamp > 253402300799) return;
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,                 month_day.month.numeric(),        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(), day_seconds.getMinutesIntoHour(), day_seconds.getSecondsIntoMinute(),
    });
}

pub fn scoreSubmission(allocator: std.mem.Allocator, user_id: i32, score_id: i64, score: stable_score.Submission, map: BeatmapState, placement: domain.ScorePlacement, before: domain.Stats, after: domain.Stats, pp_value: f64, unlocks: achievements.Unlocks) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    try writer.print("beatmapId:{d}|beatmapSetId:{d}|beatmapPlaycount:{d}|beatmapPasscount:{d}|approvedDate:", .{ map.id, map.set_id, map.plays, map.passes });
    try writeMapDate(writer, map.last_update);
    try writer.print("|\n|chartId:beatmap|chartUrl:https://kai.ovh/beatmapsets/{d}|chartName:Beatmap Ranking", .{map.set_id});
    const previous = map.previous_best;
    try integerEntry(writer, "rank", if (previous) |pb| pb.rank else null, placement.rank + 1);
    try integerEntry(writer, "rankedScore", if (previous) |pb| pb.total_score else null, score.total_score);
    try integerEntry(writer, "totalScore", if (previous) |pb| pb.total_score else null, score.total_score);
    try integerEntry(writer, "maxCombo", if (previous) |pb| pb.max_combo else null, score.max_combo);
    try decimalEntry(writer, "accuracy", if (previous) |pb| pb.accuracy * 100.0 else null, score.accuracy() * 100.0, 2);
    try decimalEntry(writer, "pp", if (previous) |pb| pb.pp else null, pp_value, 3);
    try writer.print("|onlineScoreId:{d}|\n|chartId:overall|chartUrl:https://kai.ovh/u/{d}|chartName:Overall Ranking", .{ score_id, user_id });
    try integerEntry(writer, "rank", before.global_rank, after.global_rank);
    try integerEntry(writer, "rankedScore", before.ranked_score, after.ranked_score);
    try integerEntry(writer, "totalScore", before.total_score, after.total_score);
    try integerEntry(writer, "maxCombo", before.max_combo, after.max_combo);
    try decimalEntry(writer, "accuracy", before.accuracy * 100.0, after.accuracy * 100.0, 2);
    try integerEntry(writer, "pp", before.pp, after.pp);
    try writer.writeAll("|achievements-new:");
    try achievements.writeStable(writer, unlocks);
    return output.toOwnedSlice();
}

test "stable score response matches the legacy chart shape without changing pp" {
    const score: stable_score.Submission = .{
        .map_md5 = "0123456789abcdef0123456789abcdef",
        .username = "ari",
        .online_checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .ngeki = 0,
        .nkatu = 0,
        .nmiss = 0,
        .total_score = 900000,
        .max_combo = 10,
        .perfect = true,
        .grade = "X",
        .mods = 0,
        .passed = true,
        .mode = 0,
        .client_time = "260905000000",
        .client_flags = "0",
    };
    const response = try scoreSubmission(std.testing.allocator, 4, 99, score, .{ .id = 10, .set_id = 20, .plays = 8, .passes = 6, .last_update = 1788566400 }, .{ .rank = 3, .submitted_is_best = true }, .{}, .{ .global_rank = 7, .pp = 126, .ranked_score = 900000, .total_score = 900000, .max_combo = 10, .accuracy = 1 }, 126.064, .{});
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings(
        "beatmapId:10|beatmapSetId:20|beatmapPlaycount:8|beatmapPasscount:6|approvedDate:2026-09-05 00:00:00|\n" ++
            "|chartId:beatmap|chartUrl:https://kai.ovh/beatmapsets/20|chartName:Beatmap Ranking|rankBefore:|rankAfter:4" ++
            "|rankedScoreBefore:|rankedScoreAfter:900000|totalScoreBefore:|totalScoreAfter:900000|maxComboBefore:|maxComboAfter:10" ++
            "|accuracyBefore:|accuracyAfter:100.0|ppBefore:|ppAfter:126.064|onlineScoreId:99|\n" ++
            "|chartId:overall|chartUrl:https://kai.ovh/u/4|chartName:Overall Ranking|rankBefore:|rankAfter:7" ++
            "|rankedScoreBefore:|rankedScoreAfter:900000|totalScoreBefore:|totalScoreAfter:900000|maxComboBefore:|maxComboAfter:10" ++
            "|accuracyBefore:|accuracyAfter:100.0|ppBefore:|ppAfter:126|achievements-new:",
        response,
    );
}

test "stable chart decimals retain float shape and round before zero elision" {
    for ([_]struct { value: f64, expected: []const u8 }{
        .{ .value = 100, .expected = "100.0" },
        .{ .value = 96.125, .expected = "96.12" },
        .{ .value = 2.675, .expected = "2.67" },
        .{ .value = 0.005, .expected = "0.01" },
        .{ .value = 42.25, .expected = "42.25" },
        .{ .value = 0.0001, .expected = "" },
        .{ .value = -0.0, .expected = "" },
    }) |fixture| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try writeDecimal(&output.writer, fixture.value, 2);
        try std.testing.expectEqualStrings(fixture.expected, output.written());
    }
}
