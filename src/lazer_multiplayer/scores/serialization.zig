const std = @import("std");
const room_score_around_limit = @import("../../lazer_multiplayer.zig").room_score_around_limit;

pub fn writeRoomScorePage(writer: *std.Io.Writer, scores: []const []const u8, sort: []const u8) !void {
    try writer.writeAll("{\"scores\":[");
    for (scores, 0..) |score, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll(score);
    }
    try writer.print("],\"params\":{{\"limit\":{d},\"sort\":", .{room_score_around_limit});
    try std.json.Stringify.value(sort, .{}, writer);
    try writer.writeAll("},\"cursor\":null}");
}

/// Add the fields consumed by PlaylistItemResultsScreen to a stored lazer
/// score. `higher` is ordered nearest-first because the pinned client assigns
/// positions by walking away from the selected score.
pub fn writeRoomScoreDetailJson(writer: *std.Io.Writer, score_json: []const u8, position: usize, higher: []const []const u8, lower: []const []const u8) !void {
    if (score_json.len < 2 or score_json[0] != '{' or score_json[score_json.len - 1] != '}') return error.InvalidRoomScoreJson;
    try writer.writeAll(score_json[0 .. score_json.len - 1]);
    try writer.print(",\"position\":{d},\"scores_around\":{{\"higher\":", .{position});
    try writeRoomScorePage(writer, higher, "score_asc");
    try writer.writeAll(",\"lower\":");
    try writeRoomScorePage(writer, lower, "score_desc");
    try writer.writeAll("}}");
}
