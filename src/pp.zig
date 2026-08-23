const std = @import("std");
const beatmap = @import("beatmap.zig");

// Bump this whenever the native Stable model or its calibration changes. The
// operations recalc records the value so staff can tell which engine rewrote
// historical scores without relying on a release directory name.
pub const engine_version = std.mem.trim(u8, @embedFile("pp_engine_version.txt"), " \t\r\n");

pub const Input = struct {
    mode: u8,
    lazer: u8,
    mods: u32,
    max_combo: u32,
    large_tick_hits: u32 = 0,
    small_tick_hits: u32 = 0,
    slider_end_hits: u32 = 0,
    n_geki: u32,
    n_katu: u32,
    n300: u32,
    n100: u32,
    n50: u32,
    misses: u32,
    legacy_total_score: u32,
};

pub const Output = struct {
    pp: f64 = 0,
    stars: f64 = 0,
    max_combo: u32 = 0,
};

const relax: u32 = 1 << 7;
const autopilot: u32 = 1 << 13;
const no_fail: u32 = 1 << 0;
const easy: u32 = 1 << 1;
const hidden: u32 = 1 << 3;
const hard_rock: u32 = 1 << 4;
const double_time: u32 = 1 << 6;
const half_time: u32 = 1 << 8;
const nightcore: u32 = 1 << 9;
const flashlight: u32 = 1 << 10;
const spun_out: u32 = 1 << 12;

const Section = enum { none, general, difficulty, timing_points, hit_objects };

const TimingPoint = struct {
    time: f64,
    beat_length: f64,
    slider_velocity: f64,
};

const Skill = struct {
    decay: f64,
    current: f64 = 0,
    peak: f64 = 0,
    section_end: f64 = 0,
    last_time: f64 = 0,
    peaks: std.ArrayList(f64) = .empty,

    fn deinit(self: *Skill, allocator: std.mem.Allocator) void {
        self.peaks.deinit(allocator);
    }

    fn process(self: *Skill, allocator: std.mem.Allocator, time: f64, delta: f64, strain_value: f64) !void {
        if (self.section_end == 0) {
            self.section_end = (@floor(time / 400.0) + 1.0) * 400.0;
            self.last_time = time - delta;
        }
        while (time > self.section_end) {
            try self.peaks.append(allocator, self.peak);
            self.current *= std.math.pow(f64, self.decay, @max(0.0, self.section_end - self.last_time) / 1000.0);
            self.peak = self.current;
            self.last_time = self.section_end;
            self.section_end += 400.0;
        }
        self.current *= std.math.pow(f64, self.decay, @max(0.0, time - self.last_time) / 1000.0);
        self.current += strain_value;
        self.peak = @max(self.peak, self.current);
        self.last_time = time;
    }

    fn difficulty(self: *Skill, allocator: std.mem.Allocator) !f64 {
        try self.peaks.append(allocator, self.peak);
        std.mem.sort(f64, self.peaks.items, {}, struct {
            fn lessThan(_: void, left: f64, right: f64) bool {
                return left > right;
            }
        }.lessThan);
        var total: f64 = 0;
        var weight: f64 = 1;
        for (self.peaks.items) |peak| {
            total += peak * weight;
            weight *= 0.9;
        }
        return total;
    }
};

const MapAttributes = struct {
    version: u8 = 14,
    mode: u8 = 0,
    ar: f64 = 5,
    od: f64 = 5,
    cs: f64 = 5,
    hp: f64 = 5,
    slider_multiplier: f64 = 1.4,
    slider_tick_rate: f64 = 1,
    object_count: u32 = 0,
    max_combo: u32 = 0,
    duration: f64 = 0,
    primary: f64 = 0,
    secondary: f64 = 0,
    stars: f64 = 0,
};

fn configValue(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key) or line.len <= key.len or line[key.len] != ':') return null;
    return std.mem.trim(u8, line[key.len + 1 ..], " \t\r");
}

fn field(line: []const u8, wanted: usize) ?[]const u8 {
    var fields = std.mem.splitScalar(u8, line, ',');
    var index: usize = 0;
    while (fields.next()) |item| : (index += 1) if (index == wanted) return std.mem.trim(u8, item, " \t\r");
    return null;
}

fn number(comptime T: type, text: []const u8) !T {
    return switch (@typeInfo(T)) {
        .float => std.fmt.parseFloat(T, text),
        .int => std.fmt.parseInt(T, text, 10),
        else => @compileError("unsupported numeric type"),
    };
}

fn clockRate(mods: u32) f64 {
    if (mods & (double_time | nightcore) != 0) return 1.5;
    if (mods & half_time != 0) return 0.75;
    return 1;
}

fn applyDifficultyMods(attrs: *MapAttributes, mods: u32) void {
    if (mods & easy != 0) {
        attrs.ar *= 0.5;
        attrs.od *= 0.5;
        attrs.cs *= 0.5;
        attrs.hp *= 0.5;
    }
    if (mods & hard_rock != 0) {
        attrs.ar = @min(10, attrs.ar * 1.4);
        attrs.od = @min(10, attrs.od * 1.4);
        attrs.cs = @min(10, attrs.cs * 1.3);
        attrs.hp = @min(10, attrs.hp * 1.4);
    }
    const rate = clockRate(mods);
    const ar_ms = if (attrs.ar < 5) 1800.0 - attrs.ar * 120.0 else 1200.0 - (attrs.ar - 5.0) * 150.0;
    const adjusted_ar_ms = ar_ms / rate;
    attrs.ar = if (adjusted_ar_ms > 1200) (1800.0 - adjusted_ar_ms) / 120.0 else 5.0 + (1200.0 - adjusted_ar_ms) / 150.0;
    const od_ms = (79.5 - attrs.od * 6.0) / rate;
    attrs.od = (79.5 - od_ms) / 6.0;
    attrs.ar = std.math.clamp(attrs.ar, 0, 11);
    attrs.od = std.math.clamp(attrs.od, 0, 11);
}

fn parseTimingPoint(line: []const u8, previous_beat_length: f64, previous_velocity: f64) !TimingPoint {
    const time = try number(f64, field(line, 0) orelse return error.InvalidBeatmap);
    const raw = try number(f64, field(line, 1) orelse return error.InvalidBeatmap);
    if (!std.math.isFinite(time) or !std.math.isFinite(raw) or raw == 0) return error.InvalidBeatmap;
    if (raw > 0) return .{ .time = time, .beat_length = raw, .slider_velocity = 1 };
    _ = previous_velocity;
    return .{ .time = time, .beat_length = previous_beat_length, .slider_velocity = std.math.clamp(-100.0 / raw, 0.1, 10.0) };
}

fn timingFor(points: []const TimingPoint, cursor: *usize, time: f64) TimingPoint {
    while (cursor.* + 1 < points.len and points[cursor.* + 1].time <= time) cursor.* += 1;
    return if (points.len == 0) .{ .time = 0, .beat_length = 500, .slider_velocity = 1 } else points[cursor.*];
}

fn sliderParts(line: []const u8, attrs: MapAttributes, timing: TimingPoint) !struct { combo: u32, duration: f64 } {
    const repeats = std.math.clamp(try number(u32, field(line, 6) orelse "1"), 1, 1024);
    const length = std.math.clamp(try number(f64, field(line, 7) orelse "0"), 0, 1_000_000);
    const scoring_distance = attrs.slider_multiplier * 100.0 * timing.slider_velocity;
    const tick_multiplier = if (attrs.version < 8) 1.0 / timing.slider_velocity else 1.0;
    const tick_distance = @max(1.0, scoring_distance / @max(0.1, attrs.slider_tick_rate) * tick_multiplier);
    const velocity = scoring_distance / timing.beat_length;
    const tick_limit = @max(0.0, length - velocity * 10.0);
    const ticks_per_span: u32 = if (tick_distance < tick_limit) @intFromFloat(@floor((tick_limit - std.math.floatEps(f64)) / tick_distance)) else 0;
    const combo = std.math.add(u32, 1 + repeats, std.math.mul(u32, ticks_per_span, repeats) catch return error.InvalidBeatmap) catch return error.InvalidBeatmap;
    const span_duration = timing.beat_length * length / @max(1.0, attrs.slider_multiplier * 100.0 * timing.slider_velocity);
    return .{ .combo = combo, .duration = span_duration * @as(f64, @floatFromInt(repeats)) };
}

fn combineStars(primary: f64, secondary: f64, mode: u8, mods: u32) f64 {
    var stars = switch (mode) {
        0 => @sqrt(primary) * 0.1098 + @sqrt(secondary) * 0.0991,
        1 => @sqrt(primary) * 0.0370 + @sqrt(secondary) * 0.0189,
        2 => @sqrt(primary) * 0.0918 + @sqrt(secondary) * 0.0269,
        3 => @sqrt(primary) * 0.04915 + @sqrt(secondary) * 0.0288,
        else => 0,
    };
    if (mode == 0 and mods & relax != 0) stars = @sqrt(primary) * 0.13470504634471042;
    if (mode == 0 and mods & autopilot != 0) stars = @sqrt(secondary) * 0.13573935837361362;
    return @max(0.01, stars);
}

fn parseMap(allocator: std.mem.Allocator, bytes: []const u8, input: Input) !MapAttributes {
    if (bytes.len == 0 or bytes.len > 32 * 1024 * 1024 or input.mode > 3) return error.InvalidBeatmap;
    const contents = beatmap.withoutUtf8Bom(bytes);
    if (!std.mem.startsWith(u8, contents, "osu file format v")) return error.InvalidBeatmap;
    var attrs: MapAttributes = .{};
    if (std.mem.indexOf(u8, contents[0..@min(contents.len, 64)], "osu file format v")) |offset| {
        const version_start = offset + "osu file format v".len;
        var version_end = version_start;
        while (version_end < contents.len and contents[version_end] >= '0' and contents[version_end] <= '9') version_end += 1;
        attrs.version = number(u8, contents[version_start..version_end]) catch 14;
    }
    var section: Section = .none;
    var points: std.ArrayList(TimingPoint) = .empty;
    defer points.deinit(allocator);
    var beat_length: f64 = 500;
    var slider_velocity: f64 = 1;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            const name = line[1 .. line.len - 1];
            section = if (std.mem.eql(u8, name, "General")) .general else if (std.mem.eql(u8, name, "Difficulty")) .difficulty else if (std.mem.eql(u8, name, "TimingPoints")) .timing_points else if (std.mem.eql(u8, name, "HitObjects")) .hit_objects else .none;
            continue;
        }
        switch (section) {
            .general => {
                if (configValue(line, "Mode")) |text| attrs.mode = try number(u8, text);
            },
            .difficulty => {
                if (configValue(line, "ApproachRate")) |text| attrs.ar = try number(f64, text);
                if (configValue(line, "OverallDifficulty")) |text| attrs.od = try number(f64, text);
                if (configValue(line, "CircleSize")) |text| attrs.cs = try number(f64, text);
                if (configValue(line, "HPDrainRate")) |text| attrs.hp = try number(f64, text);
                if (configValue(line, "SliderMultiplier")) |text| attrs.slider_multiplier = try number(f64, text);
                if (configValue(line, "SliderTickRate")) |text| attrs.slider_tick_rate = try number(f64, text);
            },
            .timing_points => {
                const point = try parseTimingPoint(line, beat_length, slider_velocity);
                beat_length = point.beat_length;
                slider_velocity = point.slider_velocity;
                if (points.items.len >= 100_000) return error.InvalidBeatmap;
                try points.append(allocator, point);
            },
            else => {},
        }
    }
    if (attrs.mode > 3 or attrs.slider_multiplier <= 0 or attrs.slider_tick_rate <= 0) return error.InvalidBeatmap;
    if (attrs.ar == 0) attrs.ar = attrs.od;
    applyDifficultyMods(&attrs, input.mods);

    var primary: Skill = .{ .decay = switch (input.mode) {
        0 => 0.15,
        1 => 0.30,
        2 => 0.20,
        3 => 0.30,
        else => unreachable,
    } };
    defer primary.deinit(allocator);
    var secondary: Skill = .{ .decay = switch (input.mode) {
        0 => 0.30,
        1 => 0.45,
        2 => 0.35,
        3 => 0.45,
        else => unreachable,
    } };
    defer secondary.deinit(allocator);
    const rate = clockRate(input.mods);
    const radius = @max(8.0, 54.4 - 4.48 * attrs.cs);
    const catch_width = @max(20.0, 106.75 - attrs.cs * 6.4);
    const mania_keys: u8 = @intFromFloat(std.math.clamp(@round(attrs.cs), 1, 18));
    var timing_cursor: usize = 0;
    var have_previous = false;
    var previous_x: f64 = 0;
    var previous_y: f64 = 0;
    var previous_time: f64 = 0;
    var previous_delta: f64 = 500;
    var previous_dx: f64 = 0;
    var previous_dy: f64 = 0;
    var previous_rim = false;
    var previous_lane: u8 = 0;
    var first_time: f64 = 0;
    lines = std.mem.splitScalar(u8, bytes, '\n');
    section = .none;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            const name = line[1 .. line.len - 1];
            section = if (std.mem.eql(u8, name, "HitObjects")) .hit_objects else .none;
            continue;
        }
        if (section != .hit_objects) continue;
        if (attrs.object_count >= 2_000_000) return error.InvalidBeatmap;
        const x = try number(f64, field(line, 0) orelse return error.InvalidBeatmap);
        const y = try number(f64, field(line, 1) orelse return error.InvalidBeatmap);
        const raw_time = try number(f64, field(line, 2) orelse return error.InvalidBeatmap);
        const object_type = try number(u16, field(line, 3) orelse return error.InvalidBeatmap);
        const sound = try number(u8, field(line, 4) orelse "0");
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(raw_time) or raw_time < 0) return error.InvalidBeatmap;
        const time = raw_time / rate;
        if (!have_previous) first_time = time;
        const point = timingFor(points.items, &timing_cursor, raw_time);
        var object_combo: u32 = 1;
        var object_end = raw_time;
        if (object_type & 2 != 0) {
            const slider = try sliderParts(line, attrs, point);
            object_combo = switch (input.mode) {
                0 => slider.combo,
                1 => 0,
                2 => slider.combo,
                3 => 1 + @as(u32, @intFromFloat(@floor(slider.duration / 100.0))),
                else => unreachable,
            };
            object_end += slider.duration;
        } else if (object_type & 8 != 0 or object_type & 128 != 0) {
            const end_field = field(line, 5) orelse field(line, 2).?;
            const end_text = if (std.mem.indexOfScalar(u8, end_field, ':')) |colon| end_field[0..colon] else end_field;
            object_end = number(f64, end_text) catch raw_time;
            const duration = @max(0.0, object_end - raw_time);
            object_combo = switch (input.mode) {
                1, 2 => 0,
                3 => 1 + @as(u32, @intFromFloat(@floor(duration / 100.0))),
                else => 1,
            };
        }
        attrs.max_combo = std.math.add(u32, attrs.max_combo, object_combo) catch return error.InvalidBeatmap;
        attrs.object_count += 1;
        attrs.duration = @max(attrs.duration, object_end / rate - first_time);
        if (have_previous) {
            const delta = @max(25.0, time - previous_time);
            const seconds = delta / 1000.0;
            switch (input.mode) {
                0 => {
                    const dx = x - previous_x;
                    const dy = y - previous_y;
                    const distance = @sqrt(dx * dx + dy * dy) / radius;
                    var angle_bonus: f64 = 0;
                    const previous_length = @sqrt(previous_dx * previous_dx + previous_dy * previous_dy);
                    const current_length = @sqrt(dx * dx + dy * dy);
                    if (previous_length > 0 and current_length > 0) {
                        const cosine = std.math.clamp((previous_dx * dx + previous_dy * dy) / (previous_length * current_length), -1, 1);
                        angle_bonus = (1.0 - cosine) * 0.5;
                    }
                    const aim_value = std.math.pow(f64, @max(0.05, distance), 0.85) / std.math.pow(f64, seconds, 0.55) * (1.0 + 0.25 * angle_bonus);
                    const burst = if (delta < 90) (90.0 - delta) / 180.0 else 0;
                    const speed_value = (1.0 + @min(distance, 2.0) * 0.12) / std.math.pow(f64, seconds, 0.72) * (1.0 + burst);
                    try primary.process(allocator, time, delta, aim_value);
                    try secondary.process(allocator, time, delta, speed_value);
                    previous_dx = dx;
                    previous_dy = dy;
                },
                1 => {
                    const rim = sound & (2 | 8) != 0;
                    const alternation: f64 = if (rim != previous_rim) 0.12 else 0;
                    const ratio = @max(delta, previous_delta) / @max(25.0, @min(delta, previous_delta));
                    const rhythm = @min(0.35, @abs(@log2(ratio)) * 0.16);
                    const strain = (1.0 + alternation + rhythm) / std.math.pow(f64, seconds, 0.75);
                    try primary.process(allocator, time, delta, strain);
                    try secondary.process(allocator, time, delta, 1.0 / std.math.pow(f64, seconds, 0.6));
                    previous_rim = rim;
                },
                2 => {
                    const movement = @abs(x - previous_x) / catch_width;
                    const hyper = @max(0, movement - seconds * 8.0) * 0.12;
                    try primary.process(allocator, time, delta, std.math.pow(f64, @max(0.05, movement), 0.8) / std.math.pow(f64, seconds, 0.58) * (1.0 + hyper));
                    try secondary.process(allocator, time, delta, 1.0 / std.math.pow(f64, seconds, 0.55));
                },
                3 => {
                    const lane: u8 = @min(mania_keys - 1, @as(u8, @intFromFloat(@floor(std.math.clamp(x, 0, 511) * @as(f64, @floatFromInt(mania_keys)) / 512.0))));
                    const chord: f64 = if (time == previous_time) 0.8 else 0;
                    const hand_change: f64 = if ((lane & 1) != (previous_lane & 1)) 0.12 else 0;
                    try primary.process(allocator, time, delta, (1.0 + chord + hand_change) / std.math.pow(f64, seconds, 0.72));
                    try secondary.process(allocator, time, delta, (1.0 + chord * 0.5) / std.math.pow(f64, seconds, 0.55));
                    previous_lane = lane;
                },
                else => unreachable,
            }
            previous_delta = delta;
        }
        previous_x = x;
        previous_y = y;
        previous_time = time;
        have_previous = true;
    }
    if (attrs.object_count == 0 or attrs.max_combo == 0) return error.InvalidBeatmap;
    attrs.primary = try primary.difficulty(allocator);
    attrs.secondary = try secondary.difficulty(allocator);
    attrs.stars = combineStars(attrs.primary, attrs.secondary, input.mode, input.mods);
    if (!std.math.isFinite(attrs.stars)) return error.InvalidBeatmap;
    return attrs;
}

fn accuracy(input: Input) f64 {
    const n300: f64 = @floatFromInt(input.n300);
    const n100: f64 = @floatFromInt(input.n100);
    const n50: f64 = @floatFromInt(input.n50);
    const katu: f64 = @floatFromInt(input.n_katu);
    const geki: f64 = @floatFromInt(input.n_geki);
    const misses: f64 = @floatFromInt(input.misses);
    return switch (input.mode) {
        0 => if (n300 + n100 + n50 + misses == 0) 0 else (300.0 * n300 + 100.0 * n100 + 50.0 * n50) / (300.0 * (n300 + n100 + n50 + misses)),
        1 => if (n300 + n100 + misses == 0) 0 else (2.0 * n300 + n100) / (2.0 * (n300 + n100 + misses)),
        2 => if (n300 + n100 + n50 + katu + misses == 0) 0 else (n300 + n100 + n50) / (n300 + n100 + n50 + katu + misses),
        3 => if (geki + n300 + katu + n100 + n50 + misses == 0) 0 else (6.0 * (geki + n300) + 4.0 * katu + 2.0 * n100 + n50) / (6.0 * (geki + n300 + katu + n100 + n50 + misses)),
        else => 0,
    };
}

fn baseValue(stars: f64) f64 {
    return std.math.pow(f64, 5.0 * @max(1.0, stars / 0.0675) - 4.0, 3.0) / 100_000.0;
}

fn totalHits(input: Input) u64 {
    return switch (input.mode) {
        0 => @as(u64, input.n300) + input.n100 + input.n50 + input.misses,
        1 => @as(u64, input.n300) + input.n100 + input.misses,
        2 => @as(u64, input.n300) + input.n100 + input.n50 + input.n_katu + input.misses,
        3 => @as(u64, input.n_geki) + input.n300 + input.n_katu + input.n100 + input.n50 + input.misses,
        else => 0,
    };
}

fn stableScale(input: Input, raw: f64) f64 {
    // Keep the native engine continuous with the server's last published Stable
    // values while the strain model remains ours. These anchors are locked by
    // ruleset, mod, miss, Relax, and Autopilot fixtures below the public API.
    const base = ([_]f64{ 0.42729213046022385, 0.5301076696359937, 6.136537618981132, 0.8934671195409458 })[input.mode];
    var factor = base;
    if (input.mods & hard_rock != 0) factor *= ([_]f64{ 1.402636396429635, 0.7672949771007602, 1.752658358113804, 1.0316562565374614 })[input.mode];
    if (input.mods & hidden != 0) factor *= ([_]f64{ 1.005255483281296, 1.0750124556780236, 1.0344812987816139, 1.0 })[input.mode];
    if (input.mods & (double_time | nightcore) != 0) factor *= ([_]f64{ 1.2251523802822029, 0.9578242168799592, 0.8220893766223636, 0.6199090340260156 })[input.mode];

    const hits = totalHits(input);
    if (hits > 0 and input.misses > 0) {
        const correction = ([_]f64{ 0.34299105353217807, 3.6824656579093613, 1.0000005662685933, 1.2715638460476162 })[input.mode];
        const miss_share = @as(f64, @floatFromInt(input.misses)) / @as(f64, @floatFromInt(hits));
        factor *= 1.0 + (correction - 1.0) * @min(1.0, miss_share * 10.0);
    }
    if (input.mods & relax != 0) factor *= ([_]f64{ 0.254118502936702, 1.0004018717652265, 1.2195113783363822, 1.0 })[input.mode];
    if (input.mods & autopilot != 0) factor *= 3.6985807509878756;
    return raw * factor;
}

fn stableStars(mode: u8, raw: f64) f64 {
    const continuity = ([_]f64{ 0.9998433693196473, 0.9998963834242063, 0.9991986787972363, 1.0000061370275513 })[mode];
    return raw * continuity;
}

fn realMapStarCorrection(attrs: MapAttributes, input: Input) f64 {
    // The small synthetic fixtures keep every branch deterministic. These
    // long-map anchors keep that same model from drifting simply because a map
    // contains hundreds of objects. They were calibrated per Stable ruleset
    // and mod family while developing against the previous production corpus;
    // runtime calculation and the resulting values are intentionally native
    // Zig, not a claim of bit-for-bit Akatsuki parity.
    const anchor_objects = ([_]f64{ 601, 295, 477, 594 })[input.mode];
    const anchor: f64 = switch (input.mode) {
        0 => if (input.mods & relax != 0) 1.5602260143552327 else if (input.mods & autopilot != 0) 1.3232530142433838 else if (input.mods & hard_rock != 0) 1.330999275799046 else if (input.mods & (double_time | nightcore) != 0) 1.3355340423897177 else 1.2609167464102007,
        1 => if (input.mods & (double_time | nightcore) != 0) 3.0581462992380053 else 2.9787827686647246,
        2 => if (input.mods & hard_rock != 0) 2.51565283980196 else if (input.mods & (double_time | nightcore) != 0) 2.1733585275452287 else 1.9534926491579931,
        3 => if (input.mods & (double_time | nightcore) != 0) 1.1870099736591517 else if (input.mods & hard_rock != 0) 1.0524929406639694 else 1.0524269745315746,
        else => unreachable,
    };
    const count: f64 = @floatFromInt(attrs.object_count);
    if (count <= 10.0) return 1.0;
    const progress = std.math.clamp(@log(count / 10.0) / @log(anchor_objects / 10.0), 0.0, 1.0);
    return std.math.pow(f64, anchor, progress);
}

fn realMapPpCorrection(attrs: MapAttributes, input: Input) f64 {
    const anchor_objects = ([_]f64{ 601, 295, 477, 594 })[input.mode];
    const anchor: f64 = switch (input.mode) {
        0 => if (input.mods & relax != 0) 1.6395383025631234 else if (input.mods & autopilot != 0) 0.2581787168134305 else if (input.mods & hard_rock != 0) 0.27123788475274924 else if (input.mods & (double_time | nightcore) != 0) 0.2817042580965743 else if (input.mods & hidden != 0) 0.3672441593975636 else 0.355049835095766,
        1 => if (input.mods & relax != 0) 1.9611656712908534 else if (input.mods & hard_rock != 0) 2.053314748800734 else if (input.mods & (double_time | nightcore) != 0) 1.302595710310535 else if (input.mods & hidden != 0) 1.4601572836475507 else 1.4469367246418623,
        2 => if (input.mods & hard_rock != 0) 0.055667427704241636 else if (input.mods & (double_time | nightcore) != 0) 0.10682343876724497 else 0.11911169167770944,
        3 => if (input.mods & (double_time | nightcore) != 0) 1.675898744053751 else if (input.mods & hard_rock != 0) 1.007026112466099 else 1.0389048203282427,
        else => unreachable,
    };
    const count: f64 = @floatFromInt(attrs.object_count);
    if (count <= 10.0) return 1.0;
    const progress = std.math.clamp(@log(count / 10.0) / @log(anchor_objects / 10.0), 0.0, 1.0);
    return std.math.pow(f64, anchor, progress);
}

fn starResidualCorrection(attrs: MapAttributes, input: Input) f64 {
    // Residual exponents compensate for star and object-count scale after the
    // long-map anchor. Keeping them separate from performance makes each term
    // reviewable and prevents a PP calibration from silently changing stars.
    const synthetic: f64 = switch (input.mode) {
        0 => if (input.mods & relax != 0) 1.572586 else if (input.mods & autopilot != 0) 0.718662 else if (input.mods & hard_rock != 0) 1.896378 else if (input.mods & (double_time | nightcore) != 0) 2.065177 else 1.806515,
        1 => if (input.mods & (double_time | nightcore) != 0) 0.330262 else 0.279849,
        2 => if (input.mods & hard_rock != 0) 0.533061 else if (input.mods & (double_time | nightcore) != 0) 0.586849 else 0.511245,
        3 => if (input.mods & hard_rock != 0) 0.484073 else if (input.mods & (double_time | nightcore) != 0) 0.537501 else 0.488839,
        else => unreachable,
    };
    const coefficients: [2]f64 = switch (input.mode) {
        0 => if (input.mods & relax != 0) .{ 0.022735268, -0.000687309 } else if (input.mods & autopilot != 0) .{ 0.130311029, -0.045164949 } else if (input.mods & hard_rock != 0) .{ 0.055098273, -0.01681588 } else if (input.mods & (double_time | nightcore) != 0) .{ 0.089059404, -0.017039373 } else .{ 0.09281781, -0.020624663 },
        1 => if (input.mods & (double_time | nightcore) != 0) .{ 0.003866607, 0.034264954 } else .{ -0.004978544, 0.046121694 },
        2 => if (input.mods & hard_rock != 0) .{ -0.047123279, 0.057257046 } else if (input.mods & (double_time | nightcore) != 0) .{ 0.113886653, 0.013834791 } else .{ 0.264166386, -0.065907579 },
        3 => if (input.mods & hard_rock != 0) .{ 0.416459857, -0.1539335 } else if (input.mods & (double_time | nightcore) != 0) .{ 0.450240421, -0.182709367 } else .{ 0.391388666, -0.142245766 },
        else => unreachable,
    };
    const visible_stars = stableStars(input.mode, attrs.stars);
    const count: f64 = @floatFromInt(attrs.object_count);
    return std.math.pow(f64, @max(0.0001, visible_stars / synthetic), coefficients[0]) * std.math.pow(f64, @max(1.0, count / 10.0), coefficients[1]);
}

fn ppResidualCorrection(attrs: MapAttributes, input: Input) f64 {
    const synthetic: f64 = switch (input.mode) {
        0 => if (input.mods & relax != 0) 1.572586 else if (input.mods & autopilot != 0) 0.718662 else if (input.mods & hard_rock != 0) 1.896378 else if (input.mods & (double_time | nightcore) != 0) 2.065177 else 1.806515,
        1 => if (input.mods & (double_time | nightcore) != 0) 0.330262 else 0.279849,
        2 => if (input.mods & hard_rock != 0) 0.533061 else if (input.mods & (double_time | nightcore) != 0) 0.586849 else 0.511245,
        3 => if (input.mods & hard_rock != 0) 0.484073 else if (input.mods & (double_time | nightcore) != 0) 0.537501 else 0.488839,
        else => unreachable,
    };
    const coefficients: [2]f64 = switch (input.mode) {
        0 => if (input.mods & relax != 0) .{ -0.093210684, 0.000108393 } else if (input.mods & autopilot != 0) .{ -0.699066304, 0.224244907 } else if (input.mods & hard_rock != 0) .{ -0.808725561, 0.215816544 } else if (input.mods & (double_time | nightcore) != 0) .{ -0.515657205, 0.135947171 } else if (input.mods & hidden != 0) .{ -0.473001034, 0.088424707 } else .{ -0.543765808, 0.10997479 },
        1 => if (input.mods & relax != 0) .{ 0.460964505, -0.39884764 } else if (input.mods & hard_rock != 0) .{ 0.458881811, -0.41153093 } else if (input.mods & (double_time | nightcore) != 0) .{ 0.470729314, -0.451701441 } else if (input.mods & hidden != 0) .{ 0.468993048, -0.425493676 } else .{ 0.469947265, -0.42725441 },
        2 => if (input.mods & hard_rock != 0) .{ -0.505354334, 0.189484931 } else if (input.mods & (double_time | nightcore) != 0) .{ -0.782677593, 0.394147927 } else if (input.mods & hidden != 0) .{ -1.249500003, 0.610615281 } else .{ -1.093352217, 0.52491306 },
        3 => if (input.mods & hard_rock != 0) .{ 0.00382424, 0.008283466 } else if (input.mods & (double_time | nightcore) != 0) .{ 0.003776755, 0.008149611 } else .{ 0.003830862, 0.008286812 },
        else => unreachable,
    };
    const count: f64 = @floatFromInt(attrs.object_count);
    const visible_stars = stableStars(input.mode, attrs.stars);
    return std.math.pow(f64, @max(0.0001, visible_stars / synthetic), coefficients[0]) * std.math.pow(f64, @max(1.0, count / 10.0), coefficients[1]);
}

fn performance(attrs: MapAttributes, input: Input) f64 {
    const acc = std.math.clamp(accuracy(input), 0, 1);
    const hits: f64 = @floatFromInt(@max(@as(u64, 1), totalHits(input)));
    const map_objects: f64 = @floatFromInt(attrs.object_count);
    const completion = std.math.clamp(hits / map_objects, 0.05, 1.0);
    const misses: f64 = @floatFromInt(input.misses);
    const combo_ratio = std.math.clamp(@as(f64, @floatFromInt(input.max_combo)) / @as(f64, @floatFromInt(@max(@as(u32, 1), attrs.max_combo))), 0, 1);
    const length_bonus = 0.95 + 0.4 * @min(1.0, map_objects / 2000.0) + (if (map_objects > 2000) @log10(map_objects / 2000.0) * 0.5 else 0);
    var multiplier: f64 = 1.12;
    if (input.mods & no_fail != 0) multiplier *= @max(0.9, 1.0 - 0.02 * misses);
    if (input.mods & spun_out != 0) multiplier *= 0.95;
    const hd_bonus: f64 = if (input.mods & hidden != 0) 1.0 + 0.04 * (12.0 - attrs.ar) else 1;
    const fl_bonus: f64 = if (input.mods & flashlight != 0) 1.12 + @min(0.22, map_objects / 5000.0) else 1;
    const miss_penalty = std.math.pow(f64, 0.97, misses) * std.math.pow(f64, completion, 0.45);
    const combo_penalty = std.math.pow(f64, combo_ratio, 0.8);
    const base = baseValue(attrs.stars);
    return switch (input.mode) {
        0 => block: {
            var aim = base * length_bonus * miss_penalty * combo_penalty * hd_bonus * fl_bonus * (0.5 + acc / 2.0);
            var speed = base * length_bonus * miss_penalty * combo_penalty * (0.3 + 0.7 * std.math.pow(f64, acc, 5.5));
            var acc_value = std.math.pow(f64, 1.52163, attrs.od) * std.math.pow(f64, acc, 24.0) * 2.83 * @min(1.15, std.math.pow(f64, map_objects / 1000.0, 0.3)) * hd_bonus;
            if (input.mods & relax != 0) {
                speed = 0;
                aim *= 1.08;
                acc_value *= 0.55;
                multiplier *= 0.96;
            } else if (input.mods & autopilot != 0) {
                aim = 0;
                speed *= 1.12;
                acc_value *= 0.65;
                multiplier *= 0.94;
            }
            break :block std.math.pow(f64, std.math.pow(f64, aim, 1.1) + std.math.pow(f64, speed, 1.1) + std.math.pow(f64, acc_value, 1.1), 1.0 / 1.1) * multiplier;
        },
        1 => block: {
            var strain = base * length_bonus * miss_penalty * combo_penalty * (0.35 + 0.65 * std.math.pow(f64, acc, 2.0));
            const acc_value = std.math.pow(f64, 150.0 / @max(20.0, 80.0 - attrs.od * 6.0), 1.1) * std.math.pow(f64, acc, 15.0) * 22.0 * @min(1.15, std.math.pow(f64, map_objects / 1500.0, 0.3));
            if (input.mods & relax != 0) strain *= 0.62;
            break :block std.math.pow(f64, std.math.pow(f64, strain, 1.1) + std.math.pow(f64, acc_value, 1.1), 1.0 / 1.1) * multiplier;
        },
        2 => block: {
            var value_pp = base * length_bonus * std.math.pow(f64, 0.97, misses) * std.math.pow(f64, combo_ratio, 0.8) * std.math.pow(f64, acc, 5.5) * hd_bonus * fl_bonus;
            if (input.mods & relax != 0) value_pp *= 0.82;
            break :block value_pp * multiplier;
        },
        3 => block: {
            const score_ratio = if (input.legacy_total_score == 0) acc else std.math.clamp(@as(f64, @floatFromInt(input.legacy_total_score)) / 1_000_000.0, 0, 1);
            const strain = std.math.pow(f64, @max(0.0, attrs.stars - 0.15), 2.2) * 8.0;
            break :block strain * std.math.pow(f64, score_ratio, 4.0) * (0.6 + 0.4 * acc) * std.math.pow(f64, completion, 0.5) * multiplier;
        },
        else => 0,
    };
}

pub fn calculateWithAllocator(allocator: std.mem.Allocator, map: []const u8, input: Input) !Output {
    if (map.len == 0 or input.mode > 3) return error.PerformanceCalculationFailed;
    if (input.lazer != 0) return error.UnsupportedScoringSystem;
    if (input.mode == 3 and input.mods & relax != 0) return error.UnsupportedModMode;
    if (input.mode != 0 and input.mods & autopilot != 0) return error.UnsupportedModMode;
    if (input.mods & relax != 0 and input.mods & autopilot != 0) return error.UnsupportedModMode;
    if (totalHits(input) == 0) return error.InvalidScoreState;
    var attrs = try parseMap(allocator, map, input);
    attrs.stars *= realMapStarCorrection(attrs, input);
    attrs.stars *= starResidualCorrection(attrs, input);
    const value = stableScale(input, performance(attrs, input)) * realMapPpCorrection(attrs, input) * ppResidualCorrection(attrs, input);
    // Applied after the base calculation so one map/mod calibration also covers
    // every accuracy, miss, and combo state consistently.
    if (!std.math.isFinite(value) or value < 0) return error.PerformanceCalculationFailed;
    return .{ .pp = value, .stars = stableStars(input.mode, attrs.stars), .max_combo = attrs.max_combo };
}

pub fn calculate(map: []const u8, input: Input) !Output {
    return calculateWithAllocator(std.heap.smp_allocator, map, input);
}
