const std = @import("std");

pub const Namespace = enum { vanilla, relax, custom };

pub fn modNamespace(mods: *const std.json.Array) Namespace {
    var custom = false;
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
        if (std.ascii.eqlIgnoreCase(acronym, "RX")) return .relax;
        if (!isOfficial(acronym)) custom = true;
    }
    return if (custom) .custom else .vanilla;
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
};

pub fn validateScore(value: std.json.Value) !Namespace {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidScore,
    };
    const beatmap = obj.get("beatmap_id") orelse return error.InvalidScore;
    if (beatmap != .integer or beatmap.integer <= 0) return error.InvalidScore;
    const score = obj.get("total_score") orelse return error.InvalidScore;
    if (score != .integer or score.integer < 0) return error.InvalidScore;
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
    return modNamespace(&mods);
}
