const std = @import("std");
const domain = @import("domain.zig");
const stable_score = @import("stable_score.zig");
const achievements = @import("achievements.zig");

pub const BeatmapState = struct {
    id: i32,
    set_id: i32,
    plays: i32,
    passes: i32,
};

pub fn scoreSubmission(allocator: std.mem.Allocator, user_id: i32, score_id: i64, score: stable_score.Submission, map: BeatmapState, placement: domain.ScorePlacement, before: domain.Stats, after: domain.Stats, pp_value: f64, unlocks: achievements.Unlocks) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("beatmapId:{d}|beatmapSetId:{d}|beatmapPlaycount:{d}|beatmapPasscount:{d}|approvedDate:|\n|chartId:beatmap|chartUrl:https://kai.ovh/beatmapsets/{d}|chartName:Beatmap Ranking|rankBefore:|rankAfter:{d}|rankedScoreBefore:|rankedScoreAfter:{d}|totalScoreBefore:|totalScoreAfter:{d}|maxComboBefore:|maxComboAfter:{d}|accuracyBefore:|accuracyAfter:{d:.2}|ppBefore:|ppAfter:{d:.3}|onlineScoreId:{d}|\n|chartId:overall|chartUrl:https://kai.ovh/u/{d}|chartName:Overall Ranking|rankBefore:{d}|rankAfter:{d}|rankedScoreBefore:{d}|rankedScoreAfter:{d}|totalScoreBefore:{d}|totalScoreAfter:{d}|maxComboBefore:{d}|maxComboAfter:{d}|accuracyBefore:{d:.2}|accuracyAfter:{d:.2}|ppBefore:{d}|ppAfter:{d}|achievements-new:", .{ map.id, map.set_id, map.plays, map.passes, map.set_id, placement.rank + 1, score.total_score, score.total_score, score.max_combo, score.accuracy() * 100.0, pp_value, score_id, user_id, before.global_rank, after.global_rank, before.ranked_score, after.ranked_score, before.total_score, after.total_score, before.max_combo, after.max_combo, before.accuracy * 100.0, after.accuracy * 100.0, before.pp, after.pp });
    try achievements.writeStable(&output.writer, unlocks);
    return output.toOwnedSlice();
}
