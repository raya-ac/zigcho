const std = @import("std");
const abi = @import("anticheat_abi.zig");

const max_decompressed_bytes = 32 * 1024 * 1024;
const max_lzma_memory = 64 * 1024 * 1024;
const max_frames = 2_000_000;
const max_objects = 500_000;
const max_time_ms: i64 = 24 * 60 * 60 * 1000;
const min_time_ms: i64 = -60_000;
const max_coordinate: f32 = 131_072;
const easy_mod: u64 = 1 << 1;
const hard_rock_mod: u64 = 1 << 4;

pub const Prepared = struct {
    allocator: std.mem.Allocator,
    frames: []abi.ReplayFrameV1,
    objects: []abi.HitObjectV1,
    map_object_count: u32,
    hit_window_ms: u32,
    map_duration_ms: u32,

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
    };
}

fn decompress(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var input = std.Io.Reader.fixed(compressed);
    const decode_buffer = try allocator.alloc(u8, 4096);
    var decoder = std.compress.lzma.Decompress.initOptions(&input, allocator, decode_buffer, .{}, max_lzma_memory) catch |err| {
        allocator.free(decode_buffer);
        return err;
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
        const delta = std.fmt.parseInt(i64, delta_text, 10) catch return error.InvalidReplay;
        if (delta == -12345) {
            _ = std.fmt.parseInt(i64, keys_text, 10) catch return error.InvalidReplay;
            if (!std.mem.eql(u8, x_text, "0") or !std.mem.eql(u8, y_text, "0")) return error.InvalidReplay;
            saw_sentinel = true;
            continue;
        }
        total_time = std.math.add(i64, total_time, delta) catch return error.InvalidReplay;
        if (total_time < min_time_ms or total_time > max_time_ms) return error.InvalidReplay;
        const x = std.fmt.parseFloat(f32, x_text) catch return error.InvalidReplay;
        const y = std.fmt.parseFloat(f32, y_text) catch return error.InvalidReplay;
        const keys = std.fmt.parseInt(u32, keys_text, 10) catch return error.InvalidReplay;
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or x < -max_coordinate or x > max_coordinate or y < -max_coordinate or y > max_coordinate) return error.InvalidReplay;
        if (frames.items.len >= max_frames) return error.InvalidReplay;
        try frames.append(allocator, .{ .time_ms = total_time, .x = x, .y = y, .keys = keys });
    }
    if (frames.items.len < 2 or !saw_sentinel) return error.InvalidReplay;
    // Stable repairs one historical second-frame ordering quirk this way.
    if (frames.items[1].time_ms < frames.items[0].time_ms) {
        frames.items[1].time_ms = frames.items[0].time_ms;
        frames.items[0].time_ms = 0;
    }
    var previous_time = min_time_ms;
    for (frames.items) |frame| {
        if (frame.time_ms < previous_time) return error.InvalidReplay;
        previous_time = frame.time_ms;
    }
    return frames.toOwnedSlice(allocator);
}

fn parseMap(allocator: std.mem.Allocator, map: []const u8, mods: u64, played_to_ms: i64) !ParsedMap {
    if (map.len == 0 or map.len > 32 * 1024 * 1024 or !std.mem.startsWith(u8, map, "osu file format v")) return error.InvalidBeatmap;
    const Section = enum { none, general, difficulty, hit_objects };
    var section: Section = .none;
    var overall_difficulty: f64 = 5;
    var mode: u8 = 0;
    var objects: std.ArrayList(abi.HitObjectV1) = .empty;
    errdefer objects.deinit(allocator);
    var map_object_count: u32 = 0;
    var last_object_time: i64 = -1;
    var map_duration_ms: u32 = 0;

    var lines = std.mem.splitScalar(u8, map, '\n');
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
