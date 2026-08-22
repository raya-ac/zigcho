const std = @import("std");
const domain = @import("domain.zig");
const stable_mods = @import("stable_mods.zig");

pub const beatmap_tags_array_json =
    "[{\"id\":1,\"name\":\"aim\",\"description\":\"aim control and wide spacing\",\"ruleset_id\":0}," ++
    "{\"id\":2,\"name\":\"speed\",\"description\":\"fast tapping and bursts\",\"ruleset_id\":null}," ++
    "{\"id\":3,\"name\":\"streams\",\"description\":\"sustained streams\",\"ruleset_id\":0}," ++
    "{\"id\":4,\"name\":\"jumps\",\"description\":\"large aim jumps\",\"ruleset_id\":0}," ++
    "{\"id\":5,\"name\":\"technical\",\"description\":\"technical patterns and movement\",\"ruleset_id\":null}," ++
    "{\"id\":6,\"name\":\"reading\",\"description\":\"reading-heavy patterns\",\"ruleset_id\":null}," ++
    "{\"id\":7,\"name\":\"rhythm\",\"description\":\"rhythm complexity\",\"ruleset_id\":null}," ++
    "{\"id\":8,\"name\":\"stamina\",\"description\":\"sustained stamina\",\"ruleset_id\":null}," ++
    "{\"id\":9,\"name\":\"precision\",\"description\":\"small or precise patterns\",\"ruleset_id\":null}," ++
    "{\"id\":10,\"name\":\"finger-control\",\"description\":\"finger control patterns\",\"ruleset_id\":null}," ++
    "{\"id\":11,\"name\":\"sliders\",\"description\":\"slider-focused mapping\",\"ruleset_id\":0}," ++
    "{\"id\":12,\"name\":\"gimmick\",\"description\":\"unusual or gimmick patterns\",\"ruleset_id\":null}," ++
    "{\"id\":13,\"name\":\"marathon\",\"description\":\"long-form maps\",\"ruleset_id\":null}," ++
    "{\"id\":14,\"name\":\"alternating\",\"description\":\"alternating patterns\",\"ruleset_id\":null}," ++
    "{\"id\":15,\"name\":\"tournament\",\"description\":\"suited to tournament pools\",\"ruleset_id\":null}," ++
    "{\"id\":16,\"name\":\"beginner\",\"description\":\"friendly to newer players\",\"ruleset_id\":null}]";

pub fn validBeatmapTagId(id: i64) bool {
    return id >= 1 and id <= 16;
}

pub const stable_score_id_offset: i64 = 4_000_000_000_000_000_000;

pub const LeaderboardScope = enum {
    global,
    country,
    friend,
    team,

    pub fn parse(value: []const u8) ?LeaderboardScope {
        return std.meta.stringToEnum(LeaderboardScope, value);
    }
};

pub fn encodeStableScoreId(score_id: i64) ?i64 {
    if (score_id <= 0 or score_id > std.math.maxInt(i64) - stable_score_id_offset) return null;
    return stable_score_id_offset + score_id;
}

pub fn decodeStableScoreId(score_id: i64) ?i64 {
    if (score_id <= stable_score_id_offset) return null;
    return score_id - stable_score_id_offset;
}

pub const LeaderboardModFilter = struct {
    exact_json: []u8,
    selected: bool,
    classic: bool,
    stable_bits: ?i32,
    namespace: Namespace,

    pub fn deinit(self: LeaderboardModFilter, allocator: std.mem.Allocator) void {
        allocator.free(self.exact_json);
    }
};

pub fn leaderboardModFilter(allocator: std.mem.Allocator, target: []const u8) !LeaderboardModFilter {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var selected = false;
    var classic = false;
    var stable_supported = true;
    var stable_bits: i32 = 0;
    var relax = false;
    var autopilot = false;
    var custom = false;
    var first = true;
    if (std.mem.findScalar(u8, target, '?')) |query_start| {
        var parameters = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
        while (parameters.next()) |parameter| {
            const equals = std.mem.findScalar(u8, parameter, '=') orelse continue;
            const key = parameter[0..equals];
            if (!std.mem.eql(u8, key, "mods[]") and !std.ascii.eqlIgnoreCase(key, "mods%5B%5D")) continue;
            const acronym = parameter[equals + 1 ..];
            if (std.ascii.eqlIgnoreCase(acronym, "NM")) {
                selected = true;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(acronym, "CL")) {
                classic = true;
                continue;
            }
            if (!validAcronym(acronym)) return error.InvalidLeaderboardMod;
            if (std.ascii.eqlIgnoreCase(acronym, "RX")) {
                relax = true;
            } else if (std.ascii.eqlIgnoreCase(acronym, "AP")) {
                autopilot = true;
            } else if (!isOfficial(acronym)) {
                custom = true;
                selected = true;
            } else {
                selected = true;
            }
            if (stable_mods.parseCompact(acronym)) |bits| {
                stable_bits |= bits;
            } else {
                stable_supported = false;
            }
            if (!first) try output.writer.writeByte(',');
            first = false;
            try output.writer.writeByte('"');
            for (acronym) |character| try output.writer.writeByte(std.ascii.toUpper(character));
            try output.writer.writeByte('"');
        }
    }
    try output.writer.writeByte(']');
    return .{
        .exact_json = try output.toOwnedSlice(),
        .selected = selected,
        .classic = classic,
        .stable_bits = if (stable_supported) stable_mods.leaderboardGameplayBits(stable_bits) else null,
        .namespace = if (autopilot) .autopilot else if (relax) .relax else if (custom) .custom else .vanilla,
    };
}

pub fn scoreModFilter(allocator: std.mem.Allocator, mods_json: []const u8) !LeaderboardModFilter {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, mods_json, .{});
    defer parsed.deinit();
    const mods = switch (parsed.value) {
        .array => |value| value,
        else => return error.InvalidLeaderboardMod,
    };
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var stable_supported = true;
    var stable_bits: i32 = 0;
    var relax = false;
    var autopilot = false;
    var custom = false;
    var first = true;
    for (mods.items) |item| {
        const object = switch (item) {
            .object => |value| value,
            else => return error.InvalidLeaderboardMod,
        };
        const acronym = switch (object.get("acronym") orelse return error.InvalidLeaderboardMod) {
            .string => |value| value,
            else => return error.InvalidLeaderboardMod,
        };
        if (std.ascii.eqlIgnoreCase(acronym, "NM") or std.ascii.eqlIgnoreCase(acronym, "CL")) continue;
        if (!validAcronym(acronym)) return error.InvalidLeaderboardMod;
        if (std.ascii.eqlIgnoreCase(acronym, "RX")) {
            relax = true;
        } else if (std.ascii.eqlIgnoreCase(acronym, "AP")) {
            autopilot = true;
        } else if (!isOfficial(acronym)) {
            custom = true;
        }
        if (stable_mods.parseCompact(acronym)) |bits| {
            stable_bits |= bits;
        } else {
            stable_supported = false;
        }
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.writeByte('"');
        for (acronym) |character| try output.writer.writeByte(std.ascii.toUpper(character));
        try output.writer.writeByte('"');
    }
    try output.writer.writeByte(']');
    return .{
        .exact_json = try output.toOwnedSlice(),
        .selected = true,
        .classic = false,
        .stable_bits = if (stable_supported) stable_mods.leaderboardGameplayBits(stable_bits) else null,
        .namespace = if (autopilot) .autopilot else if (relax) .relax else if (custom) .custom else .vanilla,
    };
}

pub const Namespace = enum { vanilla, relax, autopilot, custom };

pub const max_combo: i64 = 10_000_000;
pub const max_total_score: i64 = 1_000_000_000_000;
pub const max_hit_count: i64 = 100_000_000;
pub const max_mods: usize = 32;
pub const max_pauses: usize = 4096;
pub const score_token_lifetime_seconds: i64 = 2 * 60 * 60;
pub const max_replay_bytes: usize = 8 * 1024 * 1024;
pub const max_score_body_bytes: usize = 12 * 1024 * 1024;

pub fn modNamespace(mods: ?*const std.json.Array) Namespace {
    const list = mods orelse return .vanilla;
    var custom = false;
    var relax = false;
    var autopilot = false;
    for (list.items) |item| {
        const object = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const acronym_value = object.get("acronym") orelse continue;
        const acronym = switch (acronym_value) {
            .string => |s| s,
            else => continue,
        };
        if (std.ascii.eqlIgnoreCase(acronym, "RX")) {
            relax = true;
        } else if (std.ascii.eqlIgnoreCase(acronym, "AP")) {
            autopilot = true;
        } else if (!isOfficial(acronym)) {
            custom = true;
        }
    }
    return if (custom) .custom else if (autopilot) .autopilot else if (relax) .relax else .vanilla;
}

pub fn statsMode(input: ScoreInput) ?u8 {
    return switch (input.namespace) {
        .vanilla => @intCast(input.ruleset_id),
        .relax => if (input.ruleset_id <= 2) @intCast(input.ruleset_id + 4) else null,
        .autopilot => if (input.ruleset_id == 0) 8 else null,
        .custom => null,
    };
}

pub fn totalHits(input: ScoreInput) i64 {
    const names = [_][]const u8{ "meh", "ok", "good", "great", "perfect" };
    var total: i64 = 0;
    for (names) |name| {
        if (input.statistics.get(name)) |value| total += value.integer;
    }
    return total;
}

pub const MedalModCategories = struct {
    conversion: bool = false,
    fun: bool = false,
};

pub fn medalModCategories(allocator: std.mem.Allocator, mods_json: []const u8) !MedalModCategories {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, mods_json, .{});
    defer parsed.deinit();
    const mods = switch (parsed.value) {
        .array => |array| array,
        else => return error.InvalidMods,
    };
    const conversion = [_][]const u8{ "TP", "DA", "CL", "RD", "MR", "AL", "SG", "SW", "CS", "DS", "IN", "HO", "1K", "2K", "3K", "4K", "5K", "6K", "7K", "8K", "9K", "10K" };
    const fun = [_][]const u8{ "TR", "WG", "SI", "GR", "DF", "WU", "WD", "BR", "AD", "MU", "NS", "MG", "RP", "AS", "FR", "BU", "SY", "DP", "BM", "FF", "MF" };
    var result: MedalModCategories = .{};
    for (mods.items) |item| {
        const object = switch (item) {
            .object => |value| value,
            else => continue,
        };
        const acronym = switch (object.get("acronym") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        for (conversion) |candidate| if (std.ascii.eqlIgnoreCase(acronym, candidate)) {
            result.conversion = true;
            break;
        };
        for (fun) |candidate| if (std.ascii.eqlIgnoreCase(acronym, candidate)) {
            result.fun = true;
            break;
        };
    }
    return result;
}

test "official lazer medal mod categories follow the pinned client" {
    const conversion = try medalModCategories(std.testing.allocator, "[{\"acronym\":\"DA\",\"settings\":{}}]");
    try std.testing.expect(conversion.conversion);
    try std.testing.expect(!conversion.fun);
    const fun = try medalModCategories(std.testing.allocator, "[{\"acronym\":\"WG\"},{\"acronym\":\"HD\"}]");
    try std.testing.expect(!fun.conversion);
    try std.testing.expect(fun.fun);
    const ordinary = try medalModCategories(std.testing.allocator, "[{\"acronym\":\"HD\"}]");
    try std.testing.expect(!ordinary.conversion and !ordinary.fun);
}

pub const PerformanceState = struct {
    mods: u32,
    max_combo: u32,
    large_tick_hits: u32,
    small_tick_hits: u32,
    slider_end_hits: u32,
    n_geki: u32,
    n_katu: u32,
    n300: u32,
    n100: u32,
    n50: u32,
    misses: u32,
    legacy_total_score: u32,
};

fn statistic(input: ScoreInput, name: []const u8) u32 {
    const value = input.statistics.get(name) orelse return 0;
    return @intCast(value.integer);
}

fn legacyModBit(acronym: []const u8) ?u32 {
    const names = [_][]const u8{ "NF", "EZ", "TD", "HD", "HR", "SD", "DT", "RX", "HT", "NC", "FL", "AT", "SO", "AP", "PF", "4K", "5K", "6K", "7K", "8K", "FI", "RD", "CN", "TP", "9K", "CO", "1K", "3K", "2K", "V2", "MR" };
    for (names, 0..) |name, index| if (std.mem.eql(u8, acronym, name)) {
        var bit = @as(u32, 1) << @intCast(index);
        if (std.mem.eql(u8, acronym, "NC")) bit |= @as(u32, 1) << 6;
        if (std.mem.eql(u8, acronym, "PF")) bit |= @as(u32, 1) << 5;
        return bit;
    };
    return null;
}

pub fn performanceState(input: ScoreInput) !?PerformanceState {
    if (input.namespace == .custom) return null;
    var mods: u32 = 0;
    if (input.mods) |list| for (list.items) |item| {
        const acronym = item.object.get("acronym").?.string;
        if (legacyModBit(acronym)) |bit| {
            mods |= bit;
        } else if (input.namespace == .relax or input.namespace == .autopilot) {
            // Akatsuki's RX/AP calculator only accepts the legacy mod surface.
            // Do not silently rank a new lazer mod after dropping its settings.
            return error.UnsupportedPerformanceMod;
        }
    };
    return .{
        .mods = mods,
        .max_combo = @intCast(input.max_combo),
        .large_tick_hits = statistic(input, "large_tick_hit"),
        .small_tick_hits = statistic(input, "small_tick_hit"),
        .slider_end_hits = statistic(input, "slider_tail_hit"),
        .n_geki = statistic(input, "perfect"),
        .n_katu = if (input.ruleset_id == 2) statistic(input, "small_tick_miss") else statistic(input, "good"),
        .n300 = statistic(input, "great"),
        .n100 = if (input.ruleset_id == 2) statistic(input, "large_tick_hit") else statistic(input, "ok"),
        .n50 = if (input.ruleset_id == 2) statistic(input, "small_tick_hit") else statistic(input, "meh"),
        .misses = statistic(input, "miss"),
        .legacy_total_score = @intCast(@min(input.legacy_total_score orelse input.total_score, std.math.maxInt(u32))),
    };
}

pub fn validAcronym(acronym: []const u8) bool {
    if (acronym.len < 2 or acronym.len > 8) return false;
    for (acronym) |c| if (!std.ascii.isUpper(c) and !std.ascii.isDigit(c)) return false;
    return true;
}

pub fn isOfficial(a: []const u8) bool {
    const names = [_][]const u8{ "NF", "EZ", "TD", "HD", "HR", "SD", "DT", "RX", "HT", "NC", "FL", "AT", "SO", "AP", "PF", "4K", "5K", "6K", "7K", "8K", "FI", "RD", "CN", "TP", "9K", "CO", "1K", "3K", "2K", "V2", "MR", "CL", "DA", "WU", "WD", "TC", "BR", "AD", "MU", "NS", "MG", "RP", "AS", "FR", "BU", "SY", "TR", "WG", "SI", "GR", "DF", "WU" };
    for (names) |name| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

test "leaderboard mod filters distinguish combined exact and classic boards" {
    try std.testing.expectEqual(LeaderboardScope.team, LeaderboardScope.parse("team").?);
    try std.testing.expect(LeaderboardScope.parse("local") == null);

    const combined = try leaderboardModFilter(std.testing.allocator, "/api/v2/beatmaps/1/scores?type=global");
    defer combined.deinit(std.testing.allocator);
    try std.testing.expect(!combined.selected);
    try std.testing.expect(!combined.classic);
    try std.testing.expectEqual(Namespace.vanilla, combined.namespace);
    try std.testing.expectEqualStrings("[]", combined.exact_json);
    try std.testing.expectEqual(@as(?i32, 0), combined.stable_bits);

    const no_mod = try leaderboardModFilter(std.testing.allocator, "/api/v2/beatmaps/1/scores?mods%5B%5D=NM");
    defer no_mod.deinit(std.testing.allocator);
    try std.testing.expect(no_mod.selected);
    try std.testing.expect(!no_mod.classic);
    try std.testing.expectEqualStrings("[]", no_mod.exact_json);
    try std.testing.expectEqual(@as(?i32, 0), no_mod.stable_bits);

    const classic_hr = try leaderboardModFilter(std.testing.allocator, "/api/v2/beatmaps/1/scores?mods[]=CL&mods[]=HR");
    defer classic_hr.deinit(std.testing.allocator);
    try std.testing.expect(classic_hr.selected);
    try std.testing.expect(classic_hr.classic);
    try std.testing.expectEqualStrings("[\"HR\"]", classic_hr.exact_json);
    try std.testing.expectEqual(@as(?i32, stable_mods.hard_rock), classic_hr.stable_bits);

    const lazer_only = try leaderboardModFilter(std.testing.allocator, "/api/v2/beatmaps/1/scores?mods[]=WG");
    defer lazer_only.deinit(std.testing.allocator);
    try std.testing.expect(lazer_only.selected);
    try std.testing.expectEqualStrings("[\"WG\"]", lazer_only.exact_json);
    try std.testing.expect(lazer_only.stable_bits == null);

    const submitted = try scoreModFilter(std.testing.allocator, "[{\"acronym\":\"HD\"},{\"acronym\":\"HR\"}]");
    defer submitted.deinit(std.testing.allocator);
    try std.testing.expect(submitted.selected);
    try std.testing.expectEqualStrings("[\"HD\",\"HR\"]", submitted.exact_json);
    try std.testing.expectEqual(@as(?i32, stable_mods.hidden | stable_mods.hard_rock), submitted.stable_bits);

    const relax = try leaderboardModFilter(std.testing.allocator, "/api/v2/beatmaps/1/scores?mods%5B%5D=HD&mods%5B%5D=RX");
    defer relax.deinit(std.testing.allocator);
    try std.testing.expect(relax.selected);
    try std.testing.expectEqual(Namespace.relax, relax.namespace);
    try std.testing.expectEqual(@as(?i32, stable_mods.hidden), relax.stable_bits);

    const relax_namespace = try leaderboardModFilter(std.testing.allocator, "/api/v2/beatmaps/1/scores?mods[]=CL&mods[]=RX");
    defer relax_namespace.deinit(std.testing.allocator);
    try std.testing.expect(!relax_namespace.selected);
    try std.testing.expect(relax_namespace.classic);
    try std.testing.expectEqual(Namespace.relax, relax_namespace.namespace);
    try std.testing.expectEqual(@as(?i32, 0), relax_namespace.stable_bits);

    const autopilot = try leaderboardModFilter(std.testing.allocator, "/api/v2/beatmaps/1/scores?mods[]=RX&mods[]=AP");
    defer autopilot.deinit(std.testing.allocator);
    try std.testing.expect(!autopilot.selected);
    try std.testing.expectEqual(Namespace.autopilot, autopilot.namespace);
    try std.testing.expectEqual(@as(?i32, 0), autopilot.stable_bits);

    const mixed_custom = try leaderboardModFilter(std.testing.allocator, "/api/v2/beatmaps/1/scores?mods[]=WG&mods[]=RX");
    defer mixed_custom.deinit(std.testing.allocator);
    try std.testing.expectEqual(Namespace.relax, mixed_custom.namespace);
}

test "stable score ids keep source identity for lazer replay downloads" {
    const encoded = encodeStableScoreId(223).?;
    try std.testing.expectEqual(stable_score_id_offset + 223, encoded);
    try std.testing.expectEqual(@as(?i64, 223), decodeStableScoreId(encoded));
    try std.testing.expect(decodeStableScoreId(223) == null);
}

pub const ScoreInput = struct {
    beatmap_id: i64,
    ruleset_id: i64,
    total_score: i64,
    legacy_total_score: ?i64 = null,
    accuracy: f64,
    max_combo: i64,
    passed: bool,
    mods: ?std.json.Array,
    statistics: std.json.ObjectMap,
    maximum_statistics: ?std.json.ObjectMap = null,
    pauses: ?std.json.Array = null,
    rank: ?[]const u8 = null,
    client_version: ?[]const u8 = null,
    namespace: Namespace,
    achievement_stars: f64 = 0,
    achievement_mods: u32 = 0,
    achievement_perfect: bool = false,
};

pub fn parseScore(value: std.json.Value) !ScoreInput {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidScore,
    };
    const beatmap_id = try boundedInteger(obj, "beatmap_id", 1, std.math.maxInt(i32));
    const ruleset_id = try boundedInteger(obj, "ruleset_id", 0, 3);
    const total_score = try boundedInteger(obj, "total_score", 0, max_total_score);
    const legacy_total_score = try optionalBoundedInteger(obj, "legacy_total_score", 0, max_total_score);
    const accuracy = try boundedNumber(obj, "accuracy", 0, 1);
    const combo = try boundedInteger(obj, "max_combo", 0, max_combo);
    const passed_value = obj.get("passed") orelse return error.InvalidScore;
    const passed = switch (passed_value) {
        .bool => |v| v,
        else => return error.InvalidScore,
    };
    const mods = try parseMods(obj, false);
    const statistics_value = obj.get("statistics") orelse return error.InvalidScore;
    const statistics = switch (statistics_value) {
        .object => |v| v,
        else => return error.InvalidScore,
    };
    try validateStatistics(statistics);
    const client_version: ?[]const u8 = if (obj.get("client_version")) |client_value| switch (client_value) {
        .string => |v| v,
        .null => null,
        else => return error.InvalidScore,
    } else null;
    const namespace = modNamespace(if (mods) |*list| list else null);
    if ((namespace == .relax and ruleset_id == 3) or (namespace == .autopilot and ruleset_id != 0)) return error.InvalidModMode;
    return .{
        .beatmap_id = beatmap_id,
        .ruleset_id = ruleset_id,
        .total_score = total_score,
        .legacy_total_score = legacy_total_score,
        .accuracy = accuracy,
        .max_combo = combo,
        .passed = passed,
        .mods = mods,
        .statistics = statistics,
        .client_version = client_version,
        .namespace = namespace,
    };
}

pub fn parseSoloScore(value: std.json.Value, beatmap_id: i32) !ScoreInput {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidScore,
    };
    const ruleset_id = try boundedInteger(obj, "ruleset_id", 0, 3);
    const total_score = try boundedInteger(obj, "total_score", 0, max_total_score);
    const total_score_without_mods = try boundedInteger(obj, "total_score_without_mods", 0, max_total_score);
    const accuracy = try boundedNumber(obj, "accuracy", 0, 1);
    const combo = try boundedInteger(obj, "max_combo", 0, max_combo);
    const passed_value = obj.get("passed") orelse return error.InvalidScore;
    const passed = switch (passed_value) {
        .bool => |v| v,
        else => return error.InvalidScore,
    };
    const rank_value = obj.get("rank") orelse return error.InvalidScore;
    const rank = switch (rank_value) {
        .string => |v| v,
        else => return error.InvalidScore,
    };
    if (!validRank(rank)) return error.InvalidScore;
    const mods = try parseMods(obj, true);
    const statistics_value = obj.get("statistics") orelse return error.InvalidScore;
    const statistics = switch (statistics_value) {
        .object => |v| v,
        else => return error.InvalidScore,
    };
    try validateStatistics(statistics);
    const maximum_value = obj.get("maximum_statistics") orelse return error.InvalidScore;
    const maximum_statistics = switch (maximum_value) {
        .object => |v| v,
        else => return error.InvalidScore,
    };
    try validateStatistics(maximum_statistics);
    const pauses_value = obj.get("pauses") orelse return error.InvalidScore;
    const pauses = switch (pauses_value) {
        .array => |v| v,
        else => return error.InvalidScore,
    };
    if (pauses.items.len > max_pauses) return error.InvalidScore;
    for (pauses.items) |pause| switch (pause) {
        .integer => |v| if (v < 0 or v > std.math.maxInt(i32)) return error.InvalidScore,
        else => return error.InvalidScore,
    };
    const namespace = modNamespace(if (mods) |*list| list else null);
    if ((namespace == .relax and ruleset_id == 3) or (namespace == .autopilot and ruleset_id != 0)) return error.InvalidModMode;
    return .{
        .beatmap_id = beatmap_id,
        .ruleset_id = ruleset_id,
        .total_score = total_score,
        .legacy_total_score = total_score_without_mods,
        .accuracy = accuracy,
        .max_combo = combo,
        .passed = passed,
        .mods = mods,
        .statistics = statistics,
        .maximum_statistics = maximum_statistics,
        .pauses = pauses,
        .rank = rank,
        .namespace = namespace,
    };
}

pub const SoloScorePath = struct {
    beatmap_id: i32,
    token_id: ?i64,
};

pub const UserPath = struct {
    lookup: []const u8,
    ruleset_id: u8,
};

pub const LeaderboardPath = struct {
    beatmap_id: i32,
};

pub const RankingKind = enum { performance, score, country };

pub const RankingPath = struct {
    ruleset_id: u8,
    kind: RankingKind,
};

pub const BeatmapSearchSource = enum { upstream, favourites, mine };

pub const BeatmapSearchCategory = struct {
    source: BeatmapSearchSource = .upstream,
    upstream_status: ?[]const u8 = null,
};

pub fn beatmapSearchCategory(value: []const u8) !BeatmapSearchCategory {
    if (std.mem.eql(u8, value, "any")) return .{};
    if (std.mem.eql(u8, value, "leaderboard")) return .{ .upstream_status = "1,2,3,4" };
    if (std.mem.eql(u8, value, "ranked")) return .{ .upstream_status = "1,2" };
    if (std.mem.eql(u8, value, "qualified")) return .{ .upstream_status = "3" };
    if (std.mem.eql(u8, value, "loved")) return .{ .upstream_status = "4" };
    if (std.mem.eql(u8, value, "pending")) return .{ .upstream_status = "-1,0" };
    if (std.mem.eql(u8, value, "wip")) return .{ .upstream_status = "-1" };
    if (std.mem.eql(u8, value, "graveyard")) return .{ .upstream_status = "-2" };
    if (std.mem.eql(u8, value, "favourites")) return .{ .source = .favourites };
    if (std.mem.eql(u8, value, "mine")) return .{ .source = .mine };
    return error.InvalidBeatmapSearchCategory;
}

pub fn beatmapSearchSort(value: []const u8) !?[]const u8 {
    const direct = [_]struct { lazer: []const u8, upstream: []const u8 }{
        .{ .lazer = "title_asc", .upstream = "title:asc" },
        .{ .lazer = "title_desc", .upstream = "title:desc" },
        .{ .lazer = "artist_asc", .upstream = "artist:asc" },
        .{ .lazer = "artist_desc", .upstream = "artist:desc" },
        .{ .lazer = "difficulty_asc", .upstream = "beatmaps.difficulty_rating:asc" },
        .{ .lazer = "difficulty_desc", .upstream = "beatmaps.difficulty_rating:desc" },
        .{ .lazer = "updated_asc", .upstream = "last_updated:asc" },
        .{ .lazer = "updated_desc", .upstream = "last_updated:desc" },
        .{ .lazer = "ranked_asc", .upstream = "ranked_date:asc" },
        .{ .lazer = "ranked_desc", .upstream = "ranked_date:desc" },
        .{ .lazer = "plays_asc", .upstream = "play_count:asc" },
        .{ .lazer = "plays_desc", .upstream = "play_count:desc" },
        .{ .lazer = "favourites_asc", .upstream = "favourite_count:asc" },
        .{ .lazer = "favourites_desc", .upstream = "favourite_count:desc" },
        .{ .lazer = "rating_asc", .upstream = "favourite_count:asc" },
        .{ .lazer = "rating_desc", .upstream = "favourite_count:desc" },
        .{ .lazer = "nominations_asc", .upstream = "ranked_date:asc" },
        .{ .lazer = "nominations_desc", .upstream = "ranked_date:desc" },
    };
    if (std.mem.eql(u8, value, "relevance_asc") or std.mem.eql(u8, value, "relevance_desc")) return null;
    for (direct) |entry| if (std.mem.eql(u8, value, entry.lazer)) return entry.upstream;
    return error.InvalidBeatmapSearchSort;
}

pub const ChannelUserPath = struct {
    channel_id: i64,
    user_id: i32,
};

pub const ChannelMessagesPath = struct {
    channel_id: i64,
};

pub const ChannelReadPath = struct {
    channel_id: i64,
    message_id: i64,
};

pub fn queryIds(allocator: std.mem.Allocator, target: []const u8, limit: usize) ![]i32 {
    if (limit == 0) return error.InvalidQueryLimit;
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return error.MissingIds;
    var ids: std.ArrayList(i32) = .empty;
    errdefer ids.deinit(allocator);
    var fields = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const key = field[0..equals];
        if (!std.mem.eql(u8, key, "ids[]") and !std.ascii.eqlIgnoreCase(key, "ids%5b%5d")) continue;
        if (ids.items.len == limit) return error.TooManyIds;
        const id = std.fmt.parseInt(i32, field[equals + 1 ..], 10) catch return error.InvalidId;
        if (id <= 0) return error.InvalidId;
        if (std.mem.indexOfScalar(i32, ids.items, id) == null) try ids.append(allocator, id);
    }
    if (ids.items.len == 0) return error.MissingIds;
    return ids.toOwnedSlice(allocator);
}

pub const ChatMessage = struct {
    id: i64,
    channel_id: i64,
    sender_id: i32,
    sender_name: []const u8,
    sender_country: []const u8,
    sender_privileges: u32,
    content: []const u8,
    is_action: bool,
    uuid: []const u8,
    timestamp: []const u8,
};

pub const LeaderboardScore = struct {
    id: i64,
    legacy_score_id: ?i64 = null,
    legacy_total_score: ?i64 = null,
    user_id: i32,
    username: []const u8,
    country: []const u8,
    beatmap_id: i32,
    ruleset_id: i32,
    total_score: i64,
    total_score_without_mods: i64,
    pp: f64,
    accuracy: f64,
    max_combo: i32,
    passed: bool,
    rank: []const u8,
    mods_json: []const u8,
    statistics_json: []const u8,
    maximum_statistics_json: []const u8,
    pauses_json: []const u8,
    ended_at: []const u8,
    ranked: bool,
    has_replay: bool = false,
    team: ?domain.TeamSummary = null,
    beatmap: ?BeatmapSummary = null,
};

pub const BeatmapSummary = struct {
    id: i32,
    set_id: i32,
    status: []const u8,
    checksum: []const u8,
    ruleset_id: i32,
    star_rating: f64,
    version: []const u8,
    artist: []const u8,
    title: []const u8,
    creator: []const u8,
};

pub const UserScoreKind = enum { best, firsts, recent, pinned };

pub const UserScoresPath = struct {
    user_id: i32,
    kind: UserScoreKind,
};

pub fn writeLeaderboardScore(writer: *std.Io.Writer, score: LeaderboardScore) !void {
    try writer.print("{{\"id\":{d},\"legacy_score_id\":", .{score.id});
    if (score.legacy_score_id) |value| try writer.print("{d}", .{value}) else try writer.writeAll("null");
    try writer.writeAll(",\"legacy_total_score\":");
    if (score.legacy_total_score) |value| try writer.print("{d}", .{value}) else try writer.writeAll("null");
    try writer.print(",\"user_id\":{d},\"beatmap_id\":{d},\"ruleset_id\":{d},\"passed\":{s},\"total_score\":{d},\"total_score_without_mods\":{d},\"pp\":{d},\"accuracy\":{d},\"max_combo\":{d},\"rank\":", .{
        score.user_id,
        score.beatmap_id,
        score.ruleset_id,
        if (score.passed) "true" else "false",
        score.total_score,
        score.total_score_without_mods,
        score.pp,
        score.accuracy,
        score.max_combo,
    });
    try std.json.Stringify.value(score.rank, .{}, writer);
    try writer.writeAll(",\"ended_at\":");
    try std.json.Stringify.value(score.ended_at, .{}, writer);
    try writer.writeAll(",\"mods\":");
    try writer.writeAll(score.mods_json);
    try writer.writeAll(",\"statistics\":");
    try writer.writeAll(score.statistics_json);
    try writer.writeAll(",\"maximum_statistics\":");
    try writer.writeAll(score.maximum_statistics_json);
    try writer.writeAll(",\"pauses\":");
    try writer.writeAll(score.pauses_json);
    try writer.print(",\"has_replay\":{s},\"ranked\":{s},\"preserve\":true,\"processed\":true,\"user\":{{\"id\":{d},\"username\":", .{ if (score.has_replay) "true" else "false", if (score.ranked) "true" else "false", score.user_id });
    try std.json.Stringify.value(score.username, .{}, writer);
    try writer.print(",\"avatar_url\":\"https://a.kai.ovh/{d}\",\"country_code\":", .{score.user_id});
    try std.json.Stringify.value(score.country, .{}, writer);
    try writer.writeAll(",\"team\":");
    if (score.team) |team| {
        try writer.print("{{\"id\":{d},\"name\":", .{team.id});
        try std.json.Stringify.value(team.name(), .{}, writer);
        try writer.writeAll(",\"short_name\":");
        try std.json.Stringify.value(team.shortName(), .{}, writer);
        try writer.writeAll(",\"flag_url\":");
        if (team.flag_version > 0) {
            var flag_buf: [160]u8 = undefined;
            const flag_url = try std.fmt.bufPrint(&flag_buf, "https://assets.kai.ovh/teams/{d}/flag?v={d}", .{ team.id, team.flag_version });
            try std.json.Stringify.value(flag_url, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeByte('}');
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"is_active\":true,\"is_online\":true}");
    if (score.beatmap) |beatmap| {
        try writer.print(",\"beatmap\":{{\"id\":{d},\"beatmapset_id\":{d},\"status\":", .{ beatmap.id, beatmap.set_id });
        try std.json.Stringify.value(beatmap.status, .{}, writer);
        try writer.writeAll(",\"checksum\":");
        try std.json.Stringify.value(beatmap.checksum, .{}, writer);
        try writer.print(",\"mode_int\":{d},\"difficulty_rating\":{d},\"version\":", .{ beatmap.ruleset_id, beatmap.star_rating });
        try std.json.Stringify.value(beatmap.version, .{}, writer);
        try writer.print(",\"beatmapset\":{{\"id\":{d},\"status\":", .{beatmap.set_id});
        try std.json.Stringify.value(beatmap.status, .{}, writer);
        try writer.writeAll(",\"artist\":");
        try std.json.Stringify.value(beatmap.artist, .{}, writer);
        try writer.writeAll(",\"artist_unicode\":");
        try std.json.Stringify.value(beatmap.artist, .{}, writer);
        try writer.writeAll(",\"title\":");
        try std.json.Stringify.value(beatmap.title, .{}, writer);
        try writer.writeAll(",\"title_unicode\":");
        try std.json.Stringify.value(beatmap.title, .{}, writer);
        try writer.writeAll(",\"creator\":");
        try std.json.Stringify.value(beatmap.creator, .{}, writer);
        try writer.writeAll("}}");
    }
    try writer.writeByte('}');
}

pub fn parseUserScoresPath(path: []const u8) ?UserScoresPath {
    const prefix = "/api/v2/users/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const marker = "/scores/";
    const marker_at = std.mem.indexOf(u8, rest, marker) orelse return null;
    if (marker_at == 0 or std.mem.indexOfScalar(u8, rest[marker_at + marker.len ..], '/') != null) return null;
    const user_id = std.fmt.parseInt(i32, rest[0..marker_at], 10) catch return null;
    if (user_id <= 0) return null;
    const kind = std.meta.stringToEnum(UserScoreKind, rest[marker_at + marker.len ..]) orelse return null;
    return .{ .user_id = user_id, .kind = kind };
}

pub fn parseUserRecentActivityPath(path: []const u8) ?i32 {
    const prefix = "/api/v2/users/";
    const suffix = "/recent_activity";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const id_text = path[prefix.len .. path.len - suffix.len];
    if (id_text.len == 0 or std.mem.indexOfScalar(u8, id_text, '/') != null) return null;
    const id = std.fmt.parseInt(i32, id_text, 10) catch return null;
    return if (id > 0) id else null;
}

pub fn parseCommentPath(path: []const u8) ?i64 {
    const prefix = "/api/v2/comments/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const id_text = path[prefix.len..];
    if (id_text.len == 0 or std.mem.indexOfScalar(u8, id_text, '/') != null) return null;
    const id = std.fmt.parseInt(i64, id_text, 10) catch return null;
    return if (id > 0) id else null;
}

pub fn parseCommentVotePath(path: []const u8) ?i64 {
    const prefix = "/api/v2/comments/";
    const suffix = "/vote";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const id_text = path[prefix.len .. path.len - suffix.len];
    if (id_text.len == 0 or std.mem.indexOfScalar(u8, id_text, '/') != null) return null;
    const id = std.fmt.parseInt(i64, id_text, 10) catch return null;
    return if (id > 0) id else null;
}

pub fn parseUserPath(path: []const u8) ?UserPath {
    const prefix = "/api/v2/users/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    if (rest.len == 0 or rest.len > 96) return null;
    const separator = std.mem.findScalar(u8, rest, '/') orelse return .{
        .lookup = rest,
        .ruleset_id = 0,
    };
    const lookup = rest[0..separator];
    const ruleset = rest[separator + 1 ..];
    if (lookup.len == 0 or lookup.len > 96 or std.mem.indexOfScalar(u8, ruleset, '/') != null) return null;
    return .{
        .lookup = lookup,
        .ruleset_id = if (ruleset.len == 0 or std.mem.eql(u8, ruleset, "osu"))
            0
        else if (std.mem.eql(u8, ruleset, "taiko"))
            1
        else if (std.mem.eql(u8, ruleset, "fruits"))
            2
        else if (std.mem.eql(u8, ruleset, "mania"))
            3
        else
            return null,
    };
}

pub fn parseSoloScorePath(path: []const u8) ?SoloScorePath {
    const prefix = "/api/v2/beatmaps/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const marker = "/solo/scores";
    const marker_at = std.mem.indexOf(u8, rest, marker) orelse return null;
    if (marker_at == 0) return null;
    const beatmap_id = std.fmt.parseInt(i32, rest[0..marker_at], 10) catch return null;
    if (beatmap_id <= 0) return null;
    const tail = rest[marker_at + marker.len ..];
    if (tail.len == 0) return .{ .beatmap_id = beatmap_id, .token_id = null };
    if (tail[0] != '/' or tail.len == 1 or std.mem.indexOfScalar(u8, tail[1..], '/') != null) return null;
    const token_id = std.fmt.parseInt(i64, tail[1..], 10) catch return null;
    if (token_id <= 0) return null;
    return .{ .beatmap_id = beatmap_id, .token_id = token_id };
}

pub fn parseScoreDownloadPath(path: []const u8) ?i64 {
    const prefix = "/api/v2/scores/";
    const suffix = "/download";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const id_text = path[prefix.len .. path.len - suffix.len];
    if (id_text.len == 0 or std.mem.indexOfScalar(u8, id_text, '/') != null) return null;
    const score_id = std.fmt.parseInt(i64, id_text, 10) catch return null;
    return if (score_id > 0) score_id else null;
}

pub fn parseLeaderboardPath(path: []const u8) ?LeaderboardPath {
    const prefix = "/api/v2/beatmaps/";
    const suffix = "/scores";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const id_text = path[prefix.len .. path.len - suffix.len];
    if (id_text.len == 0 or std.mem.indexOfScalar(u8, id_text, '/') != null) return null;
    const beatmap_id = std.fmt.parseInt(i32, id_text, 10) catch return null;
    if (beatmap_id <= 0) return null;
    return .{ .beatmap_id = beatmap_id };
}

pub fn parseRankingPath(path: []const u8) ?RankingPath {
    const prefix = "/api/v2/rankings/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const separator = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    if (separator == 0 or std.mem.indexOfScalar(u8, rest[separator + 1 ..], '/') != null) return null;
    const ruleset_id: u8 = if (std.mem.eql(u8, rest[0..separator], "osu"))
        0
    else if (std.mem.eql(u8, rest[0..separator], "taiko"))
        1
    else if (std.mem.eql(u8, rest[0..separator], "fruits"))
        2
    else if (std.mem.eql(u8, rest[0..separator], "mania"))
        3
    else
        return null;
    const kind = std.meta.stringToEnum(RankingKind, rest[separator + 1 ..]) orelse return null;
    return .{ .ruleset_id = ruleset_id, .kind = kind };
}

pub fn validChannelId(channel_id: i64) bool {
    return channel_id >= 1 and channel_id <= 4;
}

pub fn privateChannelId(other_user_id: i32) ?i64 {
    if (other_user_id <= 0) return null;
    return 1_000_000 + @as(i64, other_user_id);
}

pub fn privateChannelUser(channel_id: i64) ?i32 {
    if (channel_id <= 1_000_000 or channel_id > 1_000_000 + std.math.maxInt(i32)) return null;
    return @intCast(channel_id - 1_000_000);
}

pub fn directMessageTarget(buffer: []u8, first_user_id: i32, second_user_id: i32) ![]const u8 {
    if (first_user_id <= 0 or second_user_id <= 0 or first_user_id == second_user_id) return error.InvalidDirectMessage;
    const lower = @min(first_user_id, second_user_id);
    const upper = @max(first_user_id, second_user_id);
    return std.fmt.bufPrint(buffer, "@dm:{d}:{d}", .{ lower, upper });
}

pub fn directMessageOther(target: []const u8, viewer_id: i32) ?i32 {
    if (!std.mem.startsWith(u8, target, "@dm:")) return null;
    const pair = target["@dm:".len..];
    const separator = std.mem.indexOfScalar(u8, pair, ':') orelse return null;
    if (separator == 0 or std.mem.indexOfScalar(u8, pair[separator + 1 ..], ':') != null) return null;
    const first = std.fmt.parseInt(i32, pair[0..separator], 10) catch return null;
    const second = std.fmt.parseInt(i32, pair[separator + 1 ..], 10) catch return null;
    if (first <= 0 or second <= 0 or first >= second) return null;
    if (first == viewer_id) return second;
    if (second == viewer_id) return first;
    return null;
}

pub fn validAnyChannelId(channel_id: i64) bool {
    return validChannelId(channel_id) or privateChannelUser(channel_id) != null;
}

pub fn channelName(channel_id: i64) ?[]const u8 {
    return switch (channel_id) {
        1 => "#osu",
        2 => "#announce",
        3 => "#lobby",
        4 => "#lazer",
        else => null,
    };
}

pub fn channelId(name: []const u8) ?i64 {
    if (std.mem.eql(u8, name, "#osu")) return 1;
    if (std.mem.eql(u8, name, "#announce")) return 2;
    if (std.mem.eql(u8, name, "#lobby")) return 3;
    if (std.mem.eql(u8, name, "#lazer")) return 4;
    return null;
}

pub fn writeChatChannel(writer: *std.Io.Writer, channel_id: i64, last_message_id: ?i64, last_read_id: ?i64) !void {
    const name = channelName(channel_id) orelse return error.UnknownChannel;
    const description: []const u8 = switch (channel_id) {
        1 => "general chat",
        2 => "updates",
        3 => "multiplayer lobby",
        4 => "lazer chat",
        else => unreachable,
    };
    try writer.print("{{\"channel_id\":{d},\"name\":", .{channel_id});
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(description, .{}, writer);
    try writer.print(",\"type\":{d},\"last_message_id\":", .{if (channel_id == 2) @as(u8, 8) else 0});
    if (last_message_id) |id| try writer.print("{d}", .{id}) else try writer.writeAll("null");
    try writer.writeAll(",\"last_read_id\":");
    if (last_read_id) |id| try writer.print("{d}", .{id}) else try writer.writeAll("null");
    try writer.writeAll(",\"message_length_limit\":2000}");
}

pub fn writePrivateChatChannel(writer: *std.Io.Writer, channel_id: i64, name: []const u8, last_message_id: ?i64, last_read_id: ?i64) !void {
    if (privateChannelUser(channel_id) == null) return error.UnknownChannel;
    try writer.print("{{\"channel_id\":{d},\"name\":", .{channel_id});
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(",\"description\":\"private messages\",\"type\":5,\"last_message_id\":");
    if (last_message_id) |id| try writer.print("{d}", .{id}) else try writer.writeAll("null");
    try writer.writeAll(",\"last_read_id\":");
    if (last_read_id) |id| try writer.print("{d}", .{id}) else try writer.writeAll("null");
    try writer.writeAll(",\"message_length_limit\":2000}");
}

pub fn validMessageUuid(uuid: []const u8) bool {
    if (uuid.len != 36) return false;
    for (uuid, 0..) |char, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (char != '-') return false;
        } else if (!std.ascii.isHex(char)) return false;
    }
    return true;
}

pub fn writeChatMessage(writer: *std.Io.Writer, message: ChatMessage) !void {
    try writer.print("{{\"message_id\":{d},\"channel_id\":{d},\"is_action\":{s},\"timestamp\":", .{ message.id, message.channel_id, if (message.is_action) "true" else "false" });
    try std.json.Stringify.value(message.timestamp, .{}, writer);
    try writer.writeAll(",\"content\":");
    try std.json.Stringify.value(message.content, .{}, writer);
    try writer.print(",\"sender_id\":{d},\"sender\":{{\"id\":{d},\"username\":", .{ message.sender_id, message.sender_id });
    try std.json.Stringify.value(message.sender_name, .{}, writer);
    try writer.print(",\"avatar_url\":\"https://a.kai.ovh/{d}\",\"country_code\":", .{message.sender_id});
    try std.json.Stringify.value(message.sender_country, .{}, writer);
    try writer.writeAll(",\"profile_colour\":");
    try std.json.Stringify.value(@import("user_json.zig").roleColour(message.sender_privileges), .{}, writer);
    try writer.print(",\"is_active\":true,\"is_online\":true,\"is_supporter\":true,\"support_level\":{d},\"is_admin\":{s},\"is_gmt\":{s},\"is_bng\":{s},\"is_bot\":{s}}},\"uuid\":", .{
        @as(u8, if (message.sender_privileges & (@as(u32, 1) << 5) != 0) 2 else 1),
        if (message.sender_privileges & (@as(u32, 1) << 13) != 0) "true" else "false",
        if (message.sender_privileges & ((@as(u32, 1) << 12) | (@as(u32, 1) << 13) | (@as(u32, 1) << 14)) != 0) "true" else "false",
        if (message.sender_privileges & (@as(u32, 1) << 11) != 0) "true" else "false",
        if (message.sender_id == 3) "true" else "false",
    });
    try std.json.Stringify.value(message.uuid, .{}, writer);
    try writer.writeByte('}');
}

pub fn parseChannelUserPath(path: []const u8) ?ChannelUserPath {
    const prefix = "/api/v2/chat/channels/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const marker = "/users/";
    const marker_at = std.mem.indexOf(u8, rest, marker) orelse return null;
    if (marker_at == 0) return null;
    const user_text = rest[marker_at + marker.len ..];
    if (user_text.len == 0 or std.mem.indexOfScalar(u8, user_text, '/') != null) return null;
    const channel_id = std.fmt.parseInt(i64, rest[0..marker_at], 10) catch return null;
    const user_id = std.fmt.parseInt(i32, user_text, 10) catch return null;
    if (!validAnyChannelId(channel_id) or user_id <= 0) return null;
    return .{ .channel_id = channel_id, .user_id = user_id };
}

pub fn parseChannelMessagesPath(path: []const u8) ?ChannelMessagesPath {
    const prefix = "/api/v2/chat/channels/";
    const suffix = "/messages";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const id_text = path[prefix.len .. path.len - suffix.len];
    if (id_text.len == 0 or std.mem.indexOfScalar(u8, id_text, '/') != null) return null;
    const channel_id = std.fmt.parseInt(i64, id_text, 10) catch return null;
    if (!validAnyChannelId(channel_id)) return null;
    return .{ .channel_id = channel_id };
}

pub fn parseChannelPath(path: []const u8) ?i64 {
    const prefix = "/api/v2/chat/channels/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const id_text = path[prefix.len..];
    if (id_text.len == 0 or std.mem.indexOfScalar(u8, id_text, '/') != null) return null;
    const channel_id = std.fmt.parseInt(i64, id_text, 10) catch return null;
    return if (validAnyChannelId(channel_id)) channel_id else null;
}

pub fn parseChannelReadPath(path: []const u8) ?ChannelReadPath {
    const prefix = "/api/v2/chat/channels/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const marker = "/mark-as-read/";
    const marker_at = std.mem.indexOf(u8, rest, marker) orelse return null;
    if (marker_at == 0) return null;
    const message_text = rest[marker_at + marker.len ..];
    if (message_text.len == 0 or std.mem.indexOfScalar(u8, message_text, '/') != null) return null;
    const channel_id = std.fmt.parseInt(i64, rest[0..marker_at], 10) catch return null;
    const message_id = std.fmt.parseInt(i64, message_text, 10) catch return null;
    if (!validAnyChannelId(channel_id) or message_id <= 0) return null;
    return .{ .channel_id = channel_id, .message_id = message_id };
}

fn parsePositiveIdPath(path: []const u8, prefix: []const u8, suffix: []const u8) ?i32 {
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const id_text = path[prefix.len .. path.len - suffix.len];
    if (id_text.len == 0 or std.mem.indexOfScalar(u8, id_text, '/') != null) return null;
    const id = std.fmt.parseInt(i32, id_text, 10) catch return null;
    return if (id > 0) id else null;
}

pub fn parseFriendPath(path: []const u8) ?i32 {
    return parsePositiveIdPath(path, "/api/v2/friends/", "");
}

pub fn parseBlockPath(path: []const u8) ?i32 {
    return parsePositiveIdPath(path, "/api/v2/blocks/", "");
}

pub fn parseFavouritePath(path: []const u8) ?i32 {
    return parsePositiveIdPath(path, "/api/v2/beatmapsets/", "/favourites");
}

pub fn validHash(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

pub fn jsonField(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8, fallback: []const u8) ![]u8 {
    const value = object.get(key) orelse return allocator.dupe(u8, fallback);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(value, .{}, &output.writer);
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

pub fn decodeReplay(allocator: std.mem.Allocator, object: std.json.ObjectMap, ruleset_id: i64) ![]u8 {
    const value = object.get("replay") orelse return allocator.dupe(u8, "");
    if (value == .null) return allocator.dupe(u8, "");
    const encoded = switch (value) {
        .string => |text| text,
        else => return error.InvalidReplay,
    };
    if (encoded.len == 0) return allocator.dupe(u8, "");
    if (encoded.len > ((max_replay_bytes + 2) / 3) * 4) return error.InvalidReplay;
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidReplay;
    if (decoded_size < 32 or decoded_size > max_replay_bytes) return error.InvalidReplay;
    const replay = try allocator.alloc(u8, decoded_size);
    errdefer allocator.free(replay);
    std.base64.standard.Decoder.decode(replay, encoded) catch return error.InvalidReplay;
    if (replay[0] != @as(u8, @intCast(ruleset_id))) return error.InvalidReplay;
    const version = std.mem.readInt(i32, replay[1..5], .little);
    if (version < 20_100_101) return error.InvalidReplay;
    return replay;
}

pub fn modsDisplay(allocator: std.mem.Allocator, mods_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, mods_json, .{});
    defer parsed.deinit();
    const mods = switch (parsed.value) {
        .array => |list| list,
        else => return error.InvalidMod,
    };
    if (mods.items.len == 0) return allocator.dupe(u8, "NM");
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('+');
    for (mods.items) |item| {
        const object = switch (item) {
            .object => |value| value,
            else => return error.InvalidMod,
        };
        const acronym = switch (object.get("acronym") orelse return error.InvalidMod) {
            .string => |value| value,
            else => return error.InvalidMod,
        };
        if (!validAcronym(acronym)) return error.InvalidMod;
        try output.writer.writeAll(acronym);
        if (std.ascii.eqlIgnoreCase(acronym, "DT") or std.ascii.eqlIgnoreCase(acronym, "NC")) {
            if (object.get("settings")) |settings_value| switch (settings_value) {
                .object => |settings| if (settings.get("speed_change")) |rate_value| {
                    const rate = switch (rate_value) {
                        .float => |value| value,
                        .integer => |value| @as(f64, @floatFromInt(value)),
                        else => continue,
                    };
                    if (std.math.isFinite(rate)) try output.writer.print(" {d:.2}×", .{rate});
                },
                else => {},
            };
        }
    }
    return output.toOwnedSlice();
}

fn parseMods(object: std.json.ObjectMap, optional: bool) !?std.json.Array {
    const mods_value = object.get("mods") orelse if (optional) return null else return error.InvalidScore;
    const mods = switch (mods_value) {
        .array => |a| a,
        else => return error.InvalidScore,
    };
    if (mods.items.len > max_mods) return error.InvalidMod;
    for (mods.items) |m| {
        const mod = switch (m) {
            .object => |x| x,
            else => return error.InvalidScore,
        };
        const acronym_value = mod.get("acronym") orelse return error.InvalidScore;
        const acronym = switch (acronym_value) {
            .string => |x| x,
            else => return error.InvalidScore,
        };
        if (!validAcronym(acronym)) return error.InvalidMod;
        if (mod.get("settings")) |settings| if (settings != .object and settings != .null) return error.InvalidMod;
    }
    return mods;
}

fn validRank(rank: []const u8) bool {
    const ranks = [_][]const u8{ "F", "D", "C", "B", "A", "S", "SH", "X", "XH" };
    for (ranks) |candidate| if (std.mem.eql(u8, rank, candidate)) return true;
    return false;
}

fn validateStatistics(statistics: std.json.ObjectMap) !void {
    if (statistics.count() > 17) return error.InvalidScore;
    var iterator = statistics.iterator();
    while (iterator.next()) |entry| {
        if (!validStatistic(entry.key_ptr.*)) return error.InvalidScore;
        switch (entry.value_ptr.*) {
            .integer => |v| if (v < 0 or v > max_hit_count) return error.InvalidScore,
            else => return error.InvalidScore,
        }
    }
}

fn validStatistic(name: []const u8) bool {
    const names = [_][]const u8{ "miss", "meh", "ok", "good", "great", "perfect", "small_tick_miss", "small_tick_hit", "large_tick_miss", "large_tick_hit", "small_bonus", "large_bonus", "ignore_miss", "ignore_hit", "combo_break", "slider_tail_hit", "legacy_combo_increase" };
    for (names) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn boundedInteger(object: std.json.ObjectMap, key: []const u8, minimum: i64, maximum: i64) !i64 {
    const value = object.get(key) orelse return error.InvalidScore;
    const integer = switch (value) {
        .integer => |v| v,
        else => return error.InvalidScore,
    };
    if (integer < minimum or integer > maximum) return error.InvalidScore;
    return integer;
}

fn optionalBoundedInteger(object: std.json.ObjectMap, key: []const u8, minimum: i64, maximum: i64) !?i64 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    return try boundedInteger(object, key, minimum, maximum);
}

fn boundedNumber(object: std.json.ObjectMap, key: []const u8, minimum: f64, maximum: f64) !f64 {
    const value = object.get(key) orelse return error.InvalidScore;
    const number: f64 = switch (value) {
        .float => |v| v,
        .integer => |v| @floatFromInt(v),
        else => return error.InvalidScore,
    };
    if (!std.math.isFinite(number) or number < minimum or number > maximum) return error.InvalidScore;
    return number;
}
