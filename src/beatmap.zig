const std = @import("std");

pub const Metadata = struct {
    id: i32 = 0,
    set_id: i32 = 0,
    mode: u8 = 0,
    artist: []const u8 = "",
    title: []const u8 = "",
    version: []const u8 = "",
    creator: []const u8 = "",
    source: []const u8 = "",
    tags: []const u8 = "",
    hp: f64 = 0,
    cs: f64 = 0,
    od: f64 = 0,
    ar: f64 = 0,
    bpm: f64 = 0,
    total_length: i32 = 0,
    object_count: u32 = 0,
};

fn value(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    if (line.len <= key.len or line[key.len] != ':') return null;
    return std.mem.trim(u8, line[key.len + 1 ..], " \t\r");
}

fn parseFloat(text: []const u8) !f64 {
    return std.fmt.parseFloat(f64, text);
}

pub fn parse(bytes: []const u8) !Metadata {
    if (!std.mem.startsWith(u8, bytes, "osu file format v")) return error.InvalidBeatmap;
    var result: Metadata = .{};
    var section: []const u8 = "";
    var first_beat_length: ?f64 = null;
    var last_object_time: i64 = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = line[1 .. line.len - 1];
            continue;
        }
        if (std.mem.eql(u8, section, "General")) {
            if (value(line, "Mode")) |v| result.mode = try std.fmt.parseInt(u8, v, 10);
        } else if (std.mem.eql(u8, section, "Metadata")) {
            if (value(line, "BeatmapID")) |v| result.id = try std.fmt.parseInt(i32, v, 10);
            if (value(line, "BeatmapSetID")) |v| result.set_id = try std.fmt.parseInt(i32, v, 10);
            if (value(line, "Artist")) |v| result.artist = v;
            if (value(line, "Title")) |v| result.title = v;
            if (value(line, "Version")) |v| result.version = v;
            if (value(line, "Creator")) |v| result.creator = v;
            if (value(line, "Source")) |v| result.source = v;
            if (value(line, "Tags")) |v| result.tags = v;
        } else if (std.mem.eql(u8, section, "Difficulty")) {
            if (value(line, "HPDrainRate")) |v| result.hp = try parseFloat(v);
            if (value(line, "CircleSize")) |v| result.cs = try parseFloat(v);
            if (value(line, "OverallDifficulty")) |v| result.od = try parseFloat(v);
            if (value(line, "ApproachRate")) |v| result.ar = try parseFloat(v);
        } else if (std.mem.eql(u8, section, "TimingPoints") and first_beat_length == null) {
            var fields = std.mem.splitScalar(u8, line, ',');
            _ = fields.next() orelse continue;
            const beat_length = try parseFloat(fields.next() orelse continue);
            if (beat_length > 0) first_beat_length = beat_length;
        } else if (std.mem.eql(u8, section, "HitObjects")) {
            var fields = std.mem.splitScalar(u8, line, ',');
            _ = fields.next() orelse continue;
            _ = fields.next() orelse continue;
            const object_time = try std.fmt.parseInt(i64, fields.next() orelse continue, 10);
            last_object_time = @max(last_object_time, object_time);
            result.object_count += 1;
        }
    }
    if (result.id <= 0 or result.set_id <= 0 or result.artist.len == 0 or result.title.len == 0 or result.version.len == 0 or result.creator.len == 0 or result.mode > 3 or result.object_count == 0) return error.InvalidBeatmap;
    result.bpm = if (first_beat_length) |length| 60_000.0 / length else 0;
    result.total_length = @intCast(@divTrunc(last_object_time, 1000));
    if (result.ar == 0) result.ar = result.od;
    return result;
}

pub fn md5(bytes: []const u8) [32]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(bytes, &digest, .{});
    var encoded: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&encoded, "{x}", .{digest}) catch unreachable;
    return encoded;
}
