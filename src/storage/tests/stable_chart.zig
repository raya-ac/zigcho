const std = @import("std");
const beatmap = @import("../../beatmap.zig");
const domain = @import("../../domain.zig");
const stable_score = @import("../../stable_score.zig");
const stable_response = @import("../../stable_response.zig");

pub fn verify(store: anytype) !void {
    const user = try store.register("chart owner", "chart-owner@example.invalid", "00000000000000000000000000000000");
    const rival = try store.register("chart rival", "chart-rival@example.invalid", "11111111111111111111111111111111");
    const map = @embedFile("../../testdata/synthetic-standard.osu");
    const metadata = try beatmap.parse(map);
    const hash = beatmap.md5(map);
    try store.upsertBeatmap(metadata, &hash, 3, 1.7931, 10, map);
    var checksum: [32]u8 = undefined;
    var serial: u32 = 0;
    // A different source/namespace must not supply the previous chart values.
    for ([_]i32{ 0, 128, 8192, 1 << 29 }) |mods| {
        var score: stable_score.Submission = .{
            .map_md5 = &hash,
            .username = "chart owner",
            .online_checksum = "",
            .n300 = 9,
            .n100 = 1,
            .n50 = 0,
            .ngeki = 0,
            .nkatu = 0,
            .nmiss = 0,
            .total_score = 1_000_000,
            .max_combo = 9,
            .perfect = false,
            .grade = "A",
            .mods = mods,
            .passed = true,
            .mode = 0,
            .client_time = "260905000000",
            .client_flags = "0",
        };
        const expected: domain.StablePersonalBest = .{
            .rank = if (mods == 128 or mods == 8192) 1 else 2,
            .total_score = score.total_score,
            .max_combo = score.max_combo,
            .accuracy = score.accuracy(),
            .pp = 40.125,
        };
        for (0..4) |step| {
            serial += 1;
            score.online_checksum = try std.fmt.bufPrint(&checksum, "{x:0>32}", .{serial});
            const pp: f64 = switch (step) {
                0 => 40.125,
                1 => 10,
                2 => 20,
                else => 60.25,
            };
            score.total_score = switch (step) {
                0 => 1_000_000,
                1 => 2_000_000,
                2 => 900_000,
                else => 2_100_000,
            };
            const inserted = try store.insertStableScoreWithChart(if (step == 1) rival else user, score, pp, "chart replay", 12_000);
            if (step < 2) {
                try std.testing.expectEqual(@as(?domain.StablePersonalBest, null), inserted.previous_best);
                continue;
            }
            try std.testing.expectEqualDeep(expected, inserted.previous_best.?);
            const placement = (try store.scoreLeaderboardPlacement(inserted.id)).?;
            try std.testing.expectEqual(step == 3, placement.submitted_is_best);
            const response = try stable_response.scoreSubmission(std.testing.allocator, user, inserted.id, score, .{
                .id = metadata.id,
                .set_id = metadata.set_id,
                .plays = 4,
                .passes = 4,
                .previous_best = inserted.previous_best,
            }, placement, .{}, .{}, pp, .{});
            defer std.testing.allocator.free(response);
            try std.testing.expect(std.mem.indexOf(u8, response, "|rankedScoreBefore:1000000|") != null);
            try std.testing.expect(std.mem.indexOf(u8, response, "|totalScoreBefore:1000000|") != null);
            try std.testing.expect(std.mem.indexOf(u8, response, "|maxComboBefore:9|") != null);
            try std.testing.expect(std.mem.indexOf(u8, response, "|accuracyBefore:93.33|") != null);
            try std.testing.expect(std.mem.indexOf(u8, response, "|ppBefore:40.125|") != null);
            const ranks = if (expected.rank == 1) "|rankBefore:1|rankAfter:1" else if (step == 2) "|rankBefore:2|rankAfter:2" else "|rankBefore:2|rankAfter:1";
            try std.testing.expect(std.mem.indexOf(u8, response, ranks) != null);
        }
    }
}
