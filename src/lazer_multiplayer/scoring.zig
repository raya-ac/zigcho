const std = @import("std");

pub const RoomScoreContext = struct {
    beatmap_id: i32,
    ruleset_id: u8,
};

pub const RoomScoreResult = struct {
    token_id: ?i64 = null,
    score_id: i64,
    total_score: i64,
    accuracy: f64,
    max_combo: i32,
    passed: bool,
};

pub const RoomScoreRecord = struct {
    score_id: i64,
    user_id: i32,
    playlist_item_id: i64,
    total_score: i64,
    accuracy: f64,
    max_combo: i32,
    passed: bool,
};

pub const room_score_around_limit = 10;

pub const RoomScoreRanking = struct {
    position: usize,
    higher_ids: [room_score_around_limit]i64 = [_]i64{0} ** room_score_around_limit,
    higher_count: usize = 0,
    lower_ids: [room_score_around_limit]i64 = [_]i64{0} ** room_score_around_limit,
    lower_count: usize = 0,
};

pub fn scoreRanksBefore(left: RoomScoreRecord, right: RoomScoreRecord) bool {
    if (left.total_score != right.total_score) return left.total_score > right.total_score;
    return left.score_id < right.score_id;
}

pub fn sortRoomScores(scores: []RoomScoreRecord) void {
    std.mem.sort(RoomScoreRecord, scores, {}, struct {
        fn lessThan(_: void, left: RoomScoreRecord, right: RoomScoreRecord) bool {
            return scoreRanksBefore(left, right);
        }
    }.lessThan);
}

pub fn scoreEligibleForHighScore(score: RoomScoreRecord, realtime: bool) bool {
    // osu-web only promotes passing playlist scores, while realtime rooms also
    // retain failed results. A zero score never creates a high-score row.
    return score.total_score > 0 and (realtime or score.passed);
}

pub fn considerHighScore(allocator: std.mem.Allocator, high_scores: *std.ArrayList(RoomScoreRecord), score: RoomScoreRecord, realtime: bool) !void {
    if (!scoreEligibleForHighScore(score, realtime)) return;
    for (high_scores.items) |*existing| if (existing.user_id == score.user_id) {
        if (scoreRanksBefore(score, existing.*)) existing.* = score;
        return;
    };
    try high_scores.append(allocator, score);
}

pub fn rankingForScore(exact: RoomScoreRecord, high_scores: []const RoomScoreRecord) RoomScoreRanking {
    var ranking: RoomScoreRanking = .{ .position = 1 };
    for (high_scores) |score| ranking.position += @intFromBool(scoreRanksBefore(score, exact));

    // Official scoresAround excludes the exact score's user. Higher scores are
    // returned nearest-first in score_asc order; lower scores are nearest-first
    // in the normal score_desc order.
    var index = high_scores.len;
    while (index != 0 and ranking.higher_count < room_score_around_limit) {
        index -= 1;
        const score = high_scores[index];
        if (score.user_id == exact.user_id or !scoreRanksBefore(score, exact)) continue;
        ranking.higher_ids[ranking.higher_count] = score.score_id;
        ranking.higher_count += 1;
    }
    for (high_scores) |score| {
        if (ranking.lower_count == room_score_around_limit) break;
        if (score.user_id == exact.user_id or !scoreRanksBefore(exact, score)) continue;
        ranking.lower_ids[ranking.lower_count] = score.score_id;
        ranking.lower_count += 1;
    }
    return ranking;
}
