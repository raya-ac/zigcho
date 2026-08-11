const std = @import("std");

pub const Namespace = enum { vanilla, relax, custom };

pub const max_combo: i64 = 10_000_000;
pub const max_total_score: i64 = 1_000_000_000_000;

pub fn modNamespace(mods: *const std.json.Array) Namespace {
    var custom = false;
    var relax = false;
    for (mods.items) |item| {
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
        } else if (!isOfficial(acronym)) {
            custom = true;
        }
    }
    return if (custom) .custom else if (relax) .relax else .vanilla;
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
    mods: std.json.Array,
    statistics: std.json.ObjectMap,
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
    const mods_value = obj.get("mods") orelse return error.InvalidScore;
    const mods = switch (mods_value) {
        .array => |a| a,
        else => return error.InvalidScore,
    };
    for (mods.items) |m| {
        const o = switch (m) {
            .object => |x| x,
            else => return error.InvalidScore,
        };
        const av = o.get("acronym") orelse return error.InvalidScore;
        const a = switch (av) {
            .string => |x| x,
            else => return error.InvalidScore,
        };
        if (!validAcronym(a)) return error.InvalidMod;
    }
    const statistics_value = obj.get("statistics") orelse return error.InvalidScore;
    const statistics = switch (statistics_value) {
        .object => |v| v,
        else => return error.InvalidScore,
    };
    const client_version: ?[]const u8 = if (obj.get("client_version")) |client_value| switch (client_value) {
        .string => |v| v,
        .null => null,
        else => return error.InvalidScore,
    } else null;
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
        .namespace = modNamespace(&mods),
    };
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
