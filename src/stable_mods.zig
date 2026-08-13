const std = @import("std");

pub const no_fail: i32 = 1 << 0;
pub const easy: i32 = 1 << 1;
pub const touch_device: i32 = 1 << 2;
pub const hidden: i32 = 1 << 3;
pub const hard_rock: i32 = 1 << 4;
pub const sudden_death: i32 = 1 << 5;
pub const double_time: i32 = 1 << 6;
pub const relax: i32 = 1 << 7;
pub const half_time: i32 = 1 << 8;
pub const nightcore: i32 = 1 << 9;
pub const flashlight: i32 = 1 << 10;
pub const autoplay: i32 = 1 << 11;
pub const spun_out: i32 = 1 << 12;
pub const autopilot: i32 = 1 << 13;
pub const perfect: i32 = 1 << 14;
pub const key4: i32 = 1 << 15;
pub const key5: i32 = 1 << 16;
pub const key6: i32 = 1 << 17;
pub const key7: i32 = 1 << 18;
pub const key8: i32 = 1 << 19;
pub const fade_in: i32 = 1 << 20;
pub const random: i32 = 1 << 21;
pub const cinema: i32 = 1 << 22;
pub const target: i32 = 1 << 23;
pub const key9: i32 = 1 << 24;
pub const key_coop: i32 = 1 << 25;
pub const key1: i32 = 1 << 26;
pub const key3: i32 = 1 << 27;
pub const key2: i32 = 1 << 28;
pub const score_v2: i32 = 1 << 29;
pub const mirror: i32 = 1 << 30;

pub fn canonical(mods: i32) i32 {
    var result = mods;
    if (result & nightcore != 0) result |= double_time;
    if (result & perfect != 0) result |= sudden_death;
    return result;
}

pub fn namespace(mods: i32) []const u8 {
    if (mods & autopilot != 0) return "autopilot";
    if (mods & relax != 0) return "relax";
    if (mods & score_v2 != 0) return "scorev2";
    return "vanilla";
}

pub fn usesPpMetric(namespace_name: []const u8) bool {
    return std.mem.eql(u8, namespace_name, "relax") or std.mem.eql(u8, namespace_name, "autopilot");
}

pub fn updatesPlayerStats(namespace_name: []const u8) bool {
    return !std.mem.eql(u8, namespace_name, "scorev2");
}

pub fn parseCompact(value: []const u8) ?i32 {
    if (value.len == 0 or value.len % 2 != 0) return null;
    var mods: i32 = 0;
    var index: usize = 0;
    while (index < value.len) : (index += 2) {
        const pair = value[index..][0..2];
        mods |= compactBit(pair) orelse return null;
    }
    return canonical(mods);
}

pub fn parseNowPlayingTail(tail: []const u8) ?i32 {
    var mods: i32 = 0;
    var found = false;
    var tokens = std.mem.tokenizeScalar(u8, tail, ' ');
    while (tokens.next()) |token| {
        if (npBit(token)) |bit| {
            mods |= bit;
            found = true;
            continue;
        }
        if (token.len > 1 and (token[0] == '+' or token[0] == '-' or token[0] == '~' or token[0] == '|')) {
            var end = token.len;
            if (end > 1 and (token[end - 1] == '~' or token[end - 1] == '|')) end -= 1;
            if (parseCompact(token[1..end])) |compact| {
                mods |= compact;
                found = true;
            }
        }
    }
    return if (found) canonical(mods) else null;
}

pub fn shortString(buffer: []u8, mods_value: i32) []const u8 {
    if (mods_value == 0) return "NM";
    const mods = canonical(mods_value);
    var position: usize = 0;
    const names = [_]struct { bit: i32, name: []const u8 }{
        .{ .bit = no_fail, .name = "NF" },
        .{ .bit = easy, .name = "EZ" },
        .{ .bit = touch_device, .name = "TD" },
        .{ .bit = hidden, .name = "HD" },
        .{ .bit = hard_rock, .name = "HR" },
        .{ .bit = sudden_death, .name = "SD" },
        .{ .bit = double_time, .name = "DT" },
        .{ .bit = relax, .name = "RX" },
        .{ .bit = half_time, .name = "HT" },
        .{ .bit = nightcore, .name = "NC" },
        .{ .bit = flashlight, .name = "FL" },
        .{ .bit = autoplay, .name = "AT" },
        .{ .bit = spun_out, .name = "SO" },
        .{ .bit = autopilot, .name = "AP" },
        .{ .bit = perfect, .name = "PF" },
        .{ .bit = key4, .name = "4K" },
        .{ .bit = key5, .name = "5K" },
        .{ .bit = key6, .name = "6K" },
        .{ .bit = key7, .name = "7K" },
        .{ .bit = key8, .name = "8K" },
        .{ .bit = fade_in, .name = "FI" },
        .{ .bit = random, .name = "RD" },
        .{ .bit = cinema, .name = "CN" },
        .{ .bit = target, .name = "TP" },
        .{ .bit = key9, .name = "9K" },
        .{ .bit = key_coop, .name = "CO" },
        .{ .bit = key1, .name = "1K" },
        .{ .bit = key3, .name = "3K" },
        .{ .bit = key2, .name = "2K" },
        .{ .bit = score_v2, .name = "V2" },
        .{ .bit = mirror, .name = "MR" },
    };
    for (names) |entry| {
        if (entry.bit == double_time and mods & nightcore != 0) continue;
        if (entry.bit == sudden_death and mods & perfect != 0) continue;
        if (mods & entry.bit == 0 or position + entry.name.len > buffer.len) continue;
        @memcpy(buffer[position..][0..entry.name.len], entry.name);
        position += entry.name.len;
    }
    return if (position == 0) "NM" else buffer[0..position];
}

fn compactBit(pair: []const u8) ?i32 {
    if (std.ascii.eqlIgnoreCase(pair, "nf")) return no_fail;
    if (std.ascii.eqlIgnoreCase(pair, "ez")) return easy;
    if (std.ascii.eqlIgnoreCase(pair, "td")) return touch_device;
    if (std.ascii.eqlIgnoreCase(pair, "hd")) return hidden;
    if (std.ascii.eqlIgnoreCase(pair, "hr")) return hard_rock;
    if (std.ascii.eqlIgnoreCase(pair, "sd")) return sudden_death;
    if (std.ascii.eqlIgnoreCase(pair, "dt")) return double_time;
    if (std.ascii.eqlIgnoreCase(pair, "rx")) return relax;
    if (std.ascii.eqlIgnoreCase(pair, "ht")) return half_time;
    if (std.ascii.eqlIgnoreCase(pair, "nc")) return nightcore;
    if (std.ascii.eqlIgnoreCase(pair, "fl")) return flashlight;
    if (std.ascii.eqlIgnoreCase(pair, "at") or std.ascii.eqlIgnoreCase(pair, "au")) return autoplay;
    if (std.ascii.eqlIgnoreCase(pair, "so")) return spun_out;
    if (std.ascii.eqlIgnoreCase(pair, "ap")) return autopilot;
    if (std.ascii.eqlIgnoreCase(pair, "pf")) return perfect;
    if (std.ascii.eqlIgnoreCase(pair, "4k")) return key4;
    if (std.ascii.eqlIgnoreCase(pair, "5k")) return key5;
    if (std.ascii.eqlIgnoreCase(pair, "6k")) return key6;
    if (std.ascii.eqlIgnoreCase(pair, "7k")) return key7;
    if (std.ascii.eqlIgnoreCase(pair, "8k")) return key8;
    if (std.ascii.eqlIgnoreCase(pair, "fi")) return fade_in;
    if (std.ascii.eqlIgnoreCase(pair, "rd") or std.ascii.eqlIgnoreCase(pair, "rn")) return random;
    if (std.ascii.eqlIgnoreCase(pair, "cn")) return cinema;
    if (std.ascii.eqlIgnoreCase(pair, "tp")) return target;
    if (std.ascii.eqlIgnoreCase(pair, "9k")) return key9;
    if (std.ascii.eqlIgnoreCase(pair, "co")) return key_coop;
    if (std.ascii.eqlIgnoreCase(pair, "1k")) return key1;
    if (std.ascii.eqlIgnoreCase(pair, "3k")) return key3;
    if (std.ascii.eqlIgnoreCase(pair, "2k")) return key2;
    if (std.ascii.eqlIgnoreCase(pair, "v2")) return score_v2;
    if (std.ascii.eqlIgnoreCase(pair, "mr")) return mirror;
    return null;
}

fn npBit(token: []const u8) ?i32 {
    const values = [_]struct { text: []const u8, bit: i32 }{
        .{ .text = "-NoFail", .bit = no_fail },
        .{ .text = "-Easy", .bit = easy },
        .{ .text = "+Hidden", .bit = hidden },
        .{ .text = "+HardRock", .bit = hard_rock },
        .{ .text = "+SuddenDeath", .bit = sudden_death },
        .{ .text = "+DoubleTime", .bit = double_time },
        .{ .text = "~Relax~", .bit = relax },
        .{ .text = "-HalfTime", .bit = half_time },
        .{ .text = "+Nightcore", .bit = nightcore },
        .{ .text = "+Flashlight", .bit = flashlight },
        .{ .text = "|Autoplay|", .bit = autoplay },
        .{ .text = "-SpunOut", .bit = spun_out },
        .{ .text = "~Autopilot~", .bit = autopilot },
        .{ .text = "+Perfect", .bit = perfect },
        .{ .text = "|Cinema|", .bit = cinema },
        .{ .text = "~Target~", .bit = target },
        .{ .text = "|1K|", .bit = key1 },
        .{ .text = "|2K|", .bit = key2 },
        .{ .text = "|3K|", .bit = key3 },
        .{ .text = "|4K|", .bit = key4 },
        .{ .text = "|5K|", .bit = key5 },
        .{ .text = "|6K|", .bit = key6 },
        .{ .text = "|7K|", .bit = key7 },
        .{ .text = "|8K|", .bit = key8 },
        .{ .text = "|9K|", .bit = key9 },
        .{ .text = "|10K|", .bit = key5 | key_coop },
        .{ .text = "|12K|", .bit = key6 | key_coop },
        .{ .text = "|14K|", .bit = key7 | key_coop },
        .{ .text = "|16K|", .bit = key8 | key_coop },
        .{ .text = "|18K|", .bit = key9 | key_coop },
    };
    for (values) |entry| if (std.ascii.eqlIgnoreCase(token, entry.text)) return entry.bit;
    return null;
}

test "stable np words use the wire mod bits" {
    try std.testing.expectEqual(hidden | relax, parseNowPlayingTail(" +Hidden ~Relax~").?);
    try std.testing.expectEqual(double_time | nightcore, parseNowPlayingTail(" +Nightcore").?);
    try std.testing.expectEqual(key7 | key_coop, parseNowPlayingTail(" |14K|").?);
    try std.testing.expect(parseNowPlayingTail("") == null);
}

test "stable mod labels suppress implied bits" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("NC", shortString(&buffer, double_time | nightcore));
    try std.testing.expectEqualStrings("PF", shortString(&buffer, sudden_death | perfect));
    try std.testing.expectEqualStrings("HDRX", shortString(&buffer, hidden | relax));
}

test "stable scorev2 has a score board but no player stats slice" {
    const scorev2_namespace = namespace(score_v2);
    try std.testing.expectEqualStrings("scorev2", scorev2_namespace);
    try std.testing.expect(!usesPpMetric(scorev2_namespace));
    try std.testing.expect(!updatesPlayerStats(scorev2_namespace));
    try std.testing.expect(usesPpMetric(namespace(relax)));
    try std.testing.expect(updatesPlayerStats(namespace(relax)));
}
