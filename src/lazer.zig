const std = @import("std");

pub const Namespace = enum { vanilla, relax, autopilot, custom };

pub const max_combo: i64 = 10_000_000;
pub const max_total_score: i64 = 1_000_000_000_000;
pub const max_hit_count: i64 = 100_000_000;
pub const max_mods: usize = 32;
pub const max_pauses: usize = 4096;
pub const score_token_lifetime_seconds: i64 = 2 * 60 * 60;

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

pub const LeaderboardScore = struct {
    id: i64,
    user_id: i32,
    username: []const u8,
    country: []const u8,
    beatmap_id: i32,
    ruleset_id: i32,
    total_score: i64,
    total_score_without_mods: i64,
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
};

pub fn writeLeaderboardScore(writer: *std.Io.Writer, score: LeaderboardScore) !void {
    try writer.print("{{\"id\":{d},\"user_id\":{d},\"beatmap_id\":{d},\"ruleset_id\":{d},\"passed\":{s},\"total_score\":{d},\"total_score_without_mods\":{d},\"accuracy\":{d},\"max_combo\":{d},\"rank\":", .{
        score.id,
        score.user_id,
        score.beatmap_id,
        score.ruleset_id,
        if (score.passed) "true" else "false",
        score.total_score,
        score.total_score_without_mods,
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
    try writer.print(",\"has_replay\":false,\"ranked\":{s},\"preserve\":true,\"processed\":true,\"user\":{{\"id\":{d},\"username\":", .{ if (score.ranked) "true" else "false", score.user_id });
    try std.json.Stringify.value(score.username, .{}, writer);
    try writer.print(",\"avatar_url\":\"https://a.kai.ovh/{d}\",\"country_code\":", .{score.user_id});
    try std.json.Stringify.value(score.country, .{}, writer);
    try writer.writeAll(",\"is_active\":true,\"is_online\":false}}");
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
