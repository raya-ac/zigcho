const std = @import("std");
const beatmap = @import("beatmap.zig");
const abi = @import("anticheat_abi.zig");

const max_decompressed_bytes = 32 * 1024 * 1024;
const max_lzma_memory = 64 * 1024 * 1024;
const max_frames = 2_000_000;
const max_objects = 500_000;
const max_time_ms: i64 = 24 * 60 * 60 * 1000;
const min_time_ms: i64 = -60_000;
const max_coordinate: f32 = 131_072;
const mania_max_x: f32 = (1 << 20) - 1;
const replay_key_mask: u32 = 1 | 2 | 4 | 8 | 16;
const easy_mod: u64 = 1 << 1;
const hard_rock_mod: u64 = 1 << 4;
const minimum_cadence_intervals: u32 = 1_500;
const minimum_cadence_duration_ms: i64 = 30_000;
const maximum_cadence_interval_ms = 50;
const maximum_suspicious_cadence_ms = 13;
const suspicious_cadence_bps: u64 = 9_900;

pub const Prepared = struct {
    allocator: std.mem.Allocator,
    frames: []abi.ReplayFrameV1,
    objects: []abi.HitObjectV1,
    map_object_count: u32,
    hit_window_ms: u32,
    map_duration_ms: u32,
    // The current map parser applies Hard Rock, but not Stable's stacking
    // transform. Until stacking is implemented, object coordinates are not
    // reliable enough for cursor-family evidence.
    gameplay_coordinates_reliable: bool,

    pub fn deinit(self: *Prepared) void {
        self.allocator.free(self.frames);
        self.allocator.free(self.objects);
        self.* = undefined;
    }
};

const ParsedMap = struct {
    objects: []abi.HitObjectV1,
    map_object_count: u32,
    hit_window_ms: u32,
    map_duration_ms: u32,
};

pub fn prepare(allocator: std.mem.Allocator, replay: []const u8, map: []const u8, mods: u64) !Prepared {
    if (replay.len == 0 or replay.len > 16 * 1024 * 1024) return error.InvalidReplay;
    const decoded = try decompress(allocator, replay);
    defer allocator.free(decoded);
    const frames = try parseFrames(allocator, decoded);
    errdefer allocator.free(frames);
    const played_to = frames[frames.len - 1].time_ms;
    const parsed_map = try parseMap(allocator, map, mods, played_to);
    return .{
        .allocator = allocator,
        .frames = frames,
        .objects = parsed_map.objects,
        .map_object_count = parsed_map.map_object_count,
        .hit_window_ms = parsed_map.hit_window_ms,
        .map_duration_ms = parsed_map.map_duration_ms,
        .gameplay_coordinates_reliable = false,
    };
}

pub fn validatePayload(allocator: std.mem.Allocator, replay: []const u8, ruleset: u8) !void {
    if (ruleset > 3 or replay.len == 0 or replay.len > 16 * 1024 * 1024) return error.InvalidReplay;
    const decoded = try decompress(allocator, replay);
    defer allocator.free(decoded);
    const frames = try parseFramesWithLimit(allocator, decoded, if (ruleset == 3) mania_max_x else max_coordinate);
    allocator.free(frames);
}

fn decompress(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var input = std.Io.Reader.fixed(compressed);
    const decode_buffer = try allocator.alloc(u8, 4096);
    var decoder = std.compress.lzma.Decompress.initOptions(&input, allocator, decode_buffer, .{}, max_lzma_memory) catch |err| {
        allocator.free(decode_buffer);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidReplay,
        };
    };
    defer decoder.deinit();
    return decoder.reader.allocRemaining(allocator, .limited(max_decompressed_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed => {
            if (decoder.err) |decode_error| switch (decode_error) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
            return error.InvalidReplay;
        },
        else => return error.InvalidReplay,
    };
}

pub fn parseFrames(allocator: std.mem.Allocator, decoded: []const u8) ![]abi.ReplayFrameV1 {
    return parseFramesWithLimit(allocator, decoded, max_coordinate);
}

fn parseFramesWithLimit(allocator: std.mem.Allocator, decoded: []const u8, max_x: f32) ![]abi.ReplayFrameV1 {
    if (decoded.len == 0 or decoded.len > max_decompressed_bytes) return error.InvalidReplay;
    var frames: std.ArrayList(abi.ReplayFrameV1) = .empty;
    errdefer frames.deinit(allocator);
    var total_time: i64 = 0;
    var saw_sentinel = false;
    var records = std.mem.splitScalar(u8, decoded, ',');
    while (records.next()) |record| {
        if (record.len == 0) continue;
        if (saw_sentinel) return error.InvalidReplay;
        var fields = std.mem.splitScalar(u8, record, '|');
        const delta_text = fields.next() orelse return error.InvalidReplay;
        const x_text = fields.next() orelse return error.InvalidReplay;
        const y_text = fields.next() orelse return error.InvalidReplay;
        const keys_text = fields.next() orelse return error.InvalidReplay;
        if (fields.next() != null) return error.InvalidReplay;
        if (std.mem.eql(u8, delta_text, "-12345")) {
            _ = std.fmt.parseInt(i64, keys_text, 10) catch return error.InvalidReplay;
            if (!std.mem.eql(u8, x_text, "0") or !std.mem.eql(u8, y_text, "0")) return error.InvalidReplay;
            saw_sentinel = true;
            continue;
        }
        const delta = parseReplayDelta(delta_text) catch return error.InvalidReplay;
        total_time = std.math.add(i64, total_time, delta) catch return error.InvalidReplay;
        if (total_time < min_time_ms or total_time > max_time_ms) return error.InvalidReplay;
        const x = std.fmt.parseFloat(f32, x_text) catch return error.InvalidReplay;
        const y = std.fmt.parseFloat(f32, y_text) catch return error.InvalidReplay;
        const keys = std.fmt.parseInt(u32, keys_text, 10) catch return error.InvalidReplay;
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or x < -max_x or x > max_x or y < -max_coordinate or y > max_coordinate or keys & ~replay_key_mask != 0) return error.InvalidReplay;
        if (frames.items.len >= max_frames) return error.InvalidReplay;
        try frames.append(allocator, .{ .time_ms = total_time, .x = x, .y = y, .keys = keys });
    }
    if (frames.items.len < 2 or !saw_sentinel) return error.InvalidReplay;
    // Stable repairs one historical second-frame ordering quirk this way.
    if (frames.items[1].time_ms < frames.items[0].time_ms) {
        frames.items[1].time_ms = frames.items[0].time_ms;
        frames.items[0].time_ms = 0;
    }
    if (frames.items.len >= 3 and frames.items[0].time_ms > frames.items[2].time_ms) {
        frames.items[0].time_ms = frames.items[2].time_ms;
        frames.items[1].time_ms = frames.items[2].time_ms;
    }
    // Stable's decoder removes these historical prelude frames after applying
    // its early ordering repairs.
    if (frames.items.len >= 2 and isPreludeFrame(frames.items[1])) _ = frames.orderedRemove(1);
    if (frames.items.len >= 1 and isPreludeFrame(frames.items[0])) _ = frames.orderedRemove(0);

    // Historical repairs are deliberately narrow. Stable drops any remaining
    // backwards frames instead of rejecting the entire replay.
    var write_index: usize = 0;
    for (frames.items) |frame| {
        if (write_index != 0 and frame.time_ms < frames.items[write_index - 1].time_ms) continue;
        frames.items[write_index] = frame;
        write_index += 1;
    }
    frames.items.len = write_index;
    if (frames.items.len < 2) return error.InvalidReplay;
    return frames.toOwnedSlice(allocator);
}

fn parseReplayDelta(value: []const u8) !i64 {
    return std.fmt.parseInt(i64, value, 10) catch {
        const parsed = std.fmt.parseFloat(f32, value) catch return error.InvalidReplay;
        if (!std.math.isFinite(parsed)) return error.InvalidReplay;
        const rounded = roundToEven(@as(f64, parsed));
        const minimum: f64 = @floatFromInt(std.math.minInt(i64));
        const maximum_exclusive: f64 = @floatFromInt(std.math.maxInt(i64));
        if (rounded < minimum or rounded >= maximum_exclusive) return error.InvalidReplay;
        return @intFromFloat(rounded);
    };
}

fn roundToEven(value: f64) f64 {
    const lower = @floor(value);
    const fraction = value - lower;
    if (fraction < 0.5) return lower;
    if (fraction > 0.5) return lower + 1;
    return if (@mod(lower, 2.0) == 0) lower else lower + 1;
}

fn isPreludeFrame(frame: abi.ReplayFrameV1) bool {
    return frame.x == 256 and frame.y == -500;
}

pub const CadenceSummary = struct {
    interval_count: u32 = 0,
    ignored_short_intervals: u32 = 0,
    dominant_interval_ms: u32 = 0,
    dominant_intervals: u32 = 0,
    distinct_intervals: u32 = 0,
    duration_ms: u32 = 0,
    suspicious: bool = false,
};

pub fn frameCadence(frames: []const abi.ReplayFrameV1) CadenceSummary {
    if (frames.len < 2) return .{};
    var counts = [_]u32{0} ** (maximum_cadence_interval_ms + 1);
    var summary: CadenceSummary = .{};
    for (frames[1..], 1..) |frame, index| {
        const delta = frame.time_ms - frames[index - 1].time_ms;
        if (delta <= 2) {
            summary.ignored_short_intervals += 1;
            continue;
        }
        summary.interval_count += 1;
        if (delta > maximum_cadence_interval_ms) continue;
        counts[@intCast(delta)] += 1;
    }
    for (counts[3..], 3..) |count, interval| {
        if (count == 0) continue;
        summary.distinct_intervals += 1;
        if (count > summary.dominant_intervals) {
            summary.dominant_intervals = count;
            summary.dominant_interval_ms = @intCast(interval);
        }
    }
    const raw_duration = frames[frames.len - 1].time_ms - frames[0].time_ms;
    if (raw_duration > 0) summary.duration_ms = @intCast(@min(raw_duration, @as(i64, std.math.maxInt(u32))));
    const all_intervals = @as(u64, summary.interval_count) + summary.ignored_short_intervals;
    summary.suspicious = summary.interval_count >= minimum_cadence_intervals and
        raw_duration >= minimum_cadence_duration_ms and
        summary.dominant_interval_ms <= maximum_suspicious_cadence_ms and
        @as(u64, summary.dominant_intervals) * 10_000 >= all_intervals * suspicious_cadence_bps;
    return summary;
}

pub fn contentDigest(frames: []const abi.ReplayFrameV1) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zigcho-stable-replay-content-v1\x00");
    var count_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &count_bytes, frames.len, .little);
    hash.update(&count_bytes);
    for (frames) |frame| {
        var time_bytes: [8]u8 = undefined;
        var x_bytes: [4]u8 = undefined;
        var y_bytes: [4]u8 = undefined;
        var keys_bytes: [4]u8 = undefined;
        std.mem.writeInt(i64, &time_bytes, frame.time_ms, .little);
        std.mem.writeInt(u32, &x_bytes, @bitCast(if (frame.x == 0) @as(f32, 0) else frame.x), .little);
        std.mem.writeInt(u32, &y_bytes, @bitCast(if (frame.y == 0) @as(f32, 0) else frame.y), .little);
        const logical_keys: u32 = @intFromBool(frame.keys & (1 | 4) != 0) |
            (@as(u32, @intFromBool(frame.keys & (2 | 8) != 0)) << 1) |
            (@as(u32, @intFromBool(frame.keys & 16 != 0)) << 2);
        std.mem.writeInt(u32, &keys_bytes, logical_keys, .little);
        hash.update(&time_bytes);
        hash.update(&x_bytes);
        hash.update(&y_bytes);
        hash.update(&keys_bytes);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn parseMap(allocator: std.mem.Allocator, map: []const u8, mods: u64, played_to_ms: i64) !ParsedMap {
    if (map.len == 0 or map.len > 32 * 1024 * 1024) return error.InvalidBeatmap;
    const contents = beatmap.withoutUtf8Bom(map);
    if (!std.mem.startsWith(u8, contents, "osu file format v")) return error.InvalidBeatmap;
    const Section = enum { none, general, difficulty, hit_objects };
    var section: Section = .none;
    var overall_difficulty: f64 = 5;
    var mode: u8 = 0;
    var objects: std.ArrayList(abi.HitObjectV1) = .empty;
    errdefer objects.deinit(allocator);
    var map_object_count: u32 = 0;
    var last_object_time: i64 = -1;
    var map_duration_ms: u32 = 0;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            const name = line[1 .. line.len - 1];
            section = if (std.mem.eql(u8, name, "General")) .general else if (std.mem.eql(u8, name, "Difficulty")) .difficulty else if (std.mem.eql(u8, name, "HitObjects")) .hit_objects else .none;
            continue;
        }
        switch (section) {
            .general => if (valueFor(line, "Mode")) |value| {
                mode = std.fmt.parseInt(u8, value, 10) catch return error.InvalidBeatmap;
            },
            .difficulty => if (valueFor(line, "OverallDifficulty")) |value| {
                overall_difficulty = std.fmt.parseFloat(f64, value) catch return error.InvalidBeatmap;
                if (!std.math.isFinite(overall_difficulty) or overall_difficulty < 0 or overall_difficulty > 10) return error.InvalidBeatmap;
            },
            .hit_objects => {
                var fields = std.mem.splitScalar(u8, line, ',');
                const x = std.fmt.parseFloat(f32, fields.next() orelse return error.InvalidBeatmap) catch return error.InvalidBeatmap;
                var y = std.fmt.parseFloat(f32, fields.next() orelse return error.InvalidBeatmap) catch return error.InvalidBeatmap;
                const time = std.fmt.parseInt(i64, fields.next() orelse return error.InvalidBeatmap, 10) catch return error.InvalidBeatmap;
                const raw_kind = std.fmt.parseInt(u32, fields.next() orelse return error.InvalidBeatmap, 10) catch return error.InvalidBeatmap;
                if (!std.math.isFinite(x) or !std.math.isFinite(y) or x < 0 or x > 512 or y < 0 or y > 384 or time < 0 or time > max_time_ms or time < last_object_time) return error.InvalidBeatmap;
                last_object_time = time;
                map_duration_ms = @intCast(time);
                const kind = raw_kind & (abi.HitObjectKind.circle | abi.HitObjectKind.slider | abi.HitObjectKind.spinner);
                if (kind == 0) continue;
                if (kind != abi.HitObjectKind.circle and kind != abi.HitObjectKind.slider and kind != abi.HitObjectKind.spinner) return error.InvalidBeatmap;
                if (map_object_count >= max_objects) return error.InvalidBeatmap;
                map_object_count += 1;
                if (time > played_to_ms + 250) continue;
                if (mods & hard_rock_mod != 0) y = 384 - y;
                try objects.append(allocator, .{ .time_ms = time, .x = x, .y = y, .kind = kind });
            },
            .none => {},
        }
    }
    if (mode != 0 or objects.items.len == 0) return error.InvalidBeatmap;
    if (mods & easy_mod != 0) overall_difficulty *= 0.5;
    if (mods & hard_rock_mod != 0) overall_difficulty = @min(10, overall_difficulty * 1.4);
    const window: u32 = @intFromFloat(@round(200 - 10 * overall_difficulty));
    return .{ .objects = try objects.toOwnedSlice(allocator), .map_object_count = map_object_count, .hit_window_ms = window, .map_duration_ms = map_duration_ms };
}

fn valueFor(line: []const u8, key: []const u8) ?[]const u8 {
    const colon = std.mem.findScalar(u8, line, ':') orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " \t"), key)) return null;
    return std.mem.trim(u8, line[colon + 1 ..], " \t");
}

test "stable replay inputs reject unknown key state bits" {
    const smoke = try parseFrames(std.testing.allocator, "0|0|0|0,1|0|0|16,-12345|0|0|1,");
    defer std.testing.allocator.free(smoke);
    try std.testing.expectEqual(@as(u32, 16), smoke[1].keys);
    try std.testing.expectError(error.InvalidReplay, parseFrames(std.testing.allocator, "0|0|0|0,1|0|0|32,-12345|0|0|1,"));
}

test "stable replay input preserves the historical third frame repair" {
    const frames = try parseFrames(std.testing.allocator, "5|0|0|0,1|0|0|0,-2|0|0|0,-12345|0|0|1,");
    defer std.testing.allocator.free(frames);
    try std.testing.expectEqual(@as(i64, 4), frames[0].time_ms);
    try std.testing.expectEqual(@as(i64, 4), frames[1].time_ms);
    try std.testing.expectEqual(@as(i64, 4), frames[2].time_ms);
}

test "stable replay input rounds fractional historical deltas like the official decoder" {
    const frames = try parseFrames(std.testing.allocator, "0|0|0|0,16.5|1|1|0,17.5|2|2|0,-12345|0|0|1,");
    defer std.testing.allocator.free(frames);
    try std.testing.expectEqual(@as(i64, 16), frames[1].time_ms);
    try std.testing.expectEqual(@as(i64, 34), frames[2].time_ms);
}

test "stable replay input removes historical prelude frames" {
    const frames = try parseFrames(std.testing.allocator, "0|256|-500|0,1|256|-500|0,2|10|20|0,3|30|40|0,-12345|0|0|1,");
    defer std.testing.allocator.free(frames);
    try std.testing.expectEqual(@as(usize, 2), frames.len);
    try std.testing.expectEqual(@as(f32, 10), frames[0].x);
    try std.testing.expectEqual(@as(i64, 3), frames[0].time_ms);
}

test "stable replay input discards backwards frames left after historical repairs" {
    const frames = try parseFrames(std.testing.allocator, "0|0|0|0,10|1|1|0,-3|2|2|0,-20|3|3|0,30|4|4|0,-12345|0|0|1,");
    defer std.testing.allocator.free(frames);
    try std.testing.expectEqualSlices(i64, &.{ 0, 10, 17 }, &.{ frames[0].time_ms, frames[1].time_ms, frames[2].time_ms });
}

test "frame cadence tolerates sparse one and two millisecond noise" {
    var frames: [4_001]abi.ReplayFrameV1 = undefined;
    var time: i64 = 0;
    frames[0] = .{ .time_ms = time, .x = 0, .y = 0, .keys = 0 };
    for (frames[1..], 1..) |*frame, index| {
        time += if (@mod(index, 300) == 0) 2 else 10;
        frame.* = .{ .time_ms = time, .x = 0, .y = 0, .keys = 0 };
    }
    const cadence = frameCadence(&frames);
    try std.testing.expect(cadence.suspicious);
    try std.testing.expectEqual(@as(u32, 10), cadence.dominant_interval_ms);
    try std.testing.expectEqual(@as(u32, 13), cadence.ignored_short_intervals);
}

test "ordinary uniform sixteen millisecond cadence stays clean" {
    var frames: [2_001]abi.ReplayFrameV1 = undefined;
    for (&frames, 0..) |*frame, index| frame.* = .{ .time_ms = @intCast(index * 16), .x = 0, .y = 0, .keys = 0 };
    const cadence = frameCadence(&frames);
    try std.testing.expect(!cadence.suspicious);
    try std.testing.expectEqual(@as(u32, 16), cadence.dominant_interval_ms);
}

test "frame cadence rejects legitimate multimodal timing" {
    var frames: [2_001]abi.ReplayFrameV1 = undefined;
    var time: i64 = 0;
    frames[0] = .{ .time_ms = time, .x = 0, .y = 0, .keys = 0 };
    for (frames[1..], 1..) |*frame, index| {
        time += if (@mod(index, 2) == 0) 16 else 17;
        frame.* = .{ .time_ms = time, .x = 0, .y = 0, .keys = 0 };
    }
    const cadence = frameCadence(&frames);
    try std.testing.expect(!cadence.suspicious);
    try std.testing.expectEqual(@as(u32, 2), cadence.distinct_intervals);
}

test "one and two millisecond intervals cannot signal cadence alone" {
    var frames: [2_001]abi.ReplayFrameV1 = undefined;
    for (&frames, 0..) |*frame, index| frame.* = .{ .time_ms = @intCast(index * 2), .x = 0, .y = 0, .keys = 0 };
    const cadence = frameCadence(&frames);
    try std.testing.expect(!cadence.suspicious);
    try std.testing.expectEqual(@as(u32, 0), cadence.interval_count);
}

test "canonical replay content ignores encoding and physical key aliases" {
    const first = try parseFrames(std.testing.allocator, "0|0|0|0,16.5|1|2|1,17.5|3|4|0,-12345|0|0|1,");
    defer std.testing.allocator.free(first);
    const equivalent = try parseFrames(std.testing.allocator, "0|0|0|0,16|1|2|4,18|3|4|0,-12345|0|0|1,");
    defer std.testing.allocator.free(equivalent);
    const changed = try parseFrames(std.testing.allocator, "0|0|0|0,16|1|2|4,18|3|5|0,-12345|0|0|1,");
    defer std.testing.allocator.free(changed);
    try std.testing.expectEqualSlices(u8, &contentDigest(first), &contentDigest(equivalent));
    try std.testing.expect(!std.mem.eql(u8, &contentDigest(first), &contentDigest(changed)));
}

test "mania replay payload bounds allow its encoded key field" {
    const frames = try parseFramesWithLimit(std.testing.allocator, "0|1048575|0|0,1|0|0|0,-12345|0|0|1,", mania_max_x);
    defer std.testing.allocator.free(frames);
    try std.testing.expectEqual(@as(f32, 1_048_575), frames[0].x);
    try std.testing.expectError(error.InvalidReplay, parseFrames(std.testing.allocator, "0|1048575|0|0,1|0|0|0,-12345|0|0|1,"));
}

test "stable map evidence rejects ambiguous primary object kinds" {
    const map =
        "osu file format v14\n" ++
        "[General]\nMode:0\n" ++
        "[Difficulty]\nOverallDifficulty:5\n" ++
        "[HitObjects]\n256,192,1000,3,0,0:0:0:0:\n";
    try std.testing.expectError(error.InvalidBeatmap, parseMap(std.testing.allocator, map, 0, 2000));
}
