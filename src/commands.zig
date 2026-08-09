const std = @import("std");
const pp = @import("pp.zig");
const storage = @import("storage.zig");
const beatmap = @import("beatmap.zig");
const sessions_mod = @import("sessions.zig");
const protocol = @import("protocol.zig");

pub const PpResult = struct {
    pp: f64,
    stars: f64,
    max_combo: u32,
    mods_str: []const u8,
};

pub const CommandResult = enum { handled, not_command };

pub fn handleCommand(allocator: std.mem.Allocator, store: *storage.Store, sender: *sessions_mod.Session, text: []const u8) CommandResult {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '!') return .not_command;
    const cmd = trimmed[1..];
    if (std.ascii.startsWithIgnoreCase(cmd, "np")) {
        handleNp(allocator, store, sender) catch {};
        return .handled;
    }
    if (std.ascii.startsWithIgnoreCase(cmd, "with ")) {
        handleWith(allocator, store, sender, cmd[5..]) catch {};
        return .handled;
    }
    return .not_command;
}

pub fn handleNp(allocator: std.mem.Allocator, store: *storage.Store, sender: *sessions_mod.Session) !void {
    const md5 = sender.map_md5;
    if (md5[0] == 0) {
        try sendPm(allocator, sender, "do /np first so i know what map you're on");
        return;
    }
    const map_file = (try store.beatmapFile(allocator, &md5)) orelse {
        try sendPm(allocator, sender, "i don't have that map yet, try again in a sec");
        return;
    };
    defer allocator.free(map_file);
    const meta = beatmap.parse(map_file) catch {
        try sendPm(allocator, sender, "couldn't parse the map file");
        return;
    };
    var mod_buf: [32]u8 = undefined;
    const mods_str = modString(&mod_buf, sender.mods);
    const result = pp.calculate(map_file, .{
        .mode = sender.mode,
        .lazer = 0,
        .mods = @intCast(sender.mods),
        .max_combo = meta.object_count,
        .n_geki = if (sender.mode == 3) meta.object_count else 0,
        .n_katu = 0,
        .n300 = meta.object_count,
        .n100 = 0,
        .n50 = 0,
        .misses = 0,
        .legacy_total_score = 1_000_000,
    }) catch {
        try sendPm(allocator, sender, "pp calc failed on this map");
        return;
    };
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} — {s} [{s}] | ★ {d:.2} | {s} | {d:.2}pp (100%, FC)", .{ meta.artist, meta.title, meta.version, result.stars, mods_str, result.pp }) catch return;
    try sendPm(allocator, sender, msg);
}

fn handleWith(allocator: std.mem.Allocator, store: *storage.Store, sender: *sessions_mod.Session, args: []const u8) !void {
    const md5 = sender.map_md5;
    if (md5[0] == 0) {
        try sendPm(allocator, sender, "do /np first so i know what map you're on");
        return;
    }
    const map_file = (try store.beatmapFile(allocator, &md5)) orelse {
        try sendPm(allocator, sender, "i don't have that map yet, try again in a sec");
        return;
    };
    defer allocator.free(map_file);
    const meta = beatmap.parse(map_file) catch {
        try sendPm(allocator, sender, "couldn't parse the map file");
        return;
    };

    var mods: i32 = sender.mods;
    var accuracy: f64 = 100.0;
    var misses: u32 = 0;
    var combo_pct: f64 = 100.0;

    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, args, " "), ' ');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        var lower_buf: [32]u8 = undefined;
        const lower_len = @min(part.len, lower_buf.len);
        for (part[0..lower_len], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        const lower = lower_buf[0..lower_len];
        if (std.mem.endsWith(u8, lower, "%") and lower.len > 1) {
            const val = std.fmt.parseFloat(f64, lower[0 .. lower.len - 1]) catch continue;
            if (val > 0 and val <= 100) {
                if (accuracy == 100.0 and misses == 0) accuracy = val else combo_pct = val;
            }
        } else if (std.mem.endsWith(u8, lower, "m") and lower.len > 1) {
            misses = std.fmt.parseInt(u32, lower[0 .. lower.len - 1], 10) catch continue;
        } else {
            const parsed = parseMods(lower) orelse continue;
            mods = parsed;
        }
    }

    var mod_buf: [32]u8 = undefined;
    const mods_str = modString(&mod_buf, mods);
    const total_objects = meta.object_count;
    const total_hits = if (misses > total_objects) total_objects else total_objects - misses;
    const acc = accuracy / 100.0;
    const n300_f: f64 = @max(0, @as(f64, @floatFromInt(total_hits)) * (3.0 * acc - 1.0) / 2.0);
    const n300: u32 = @intFromFloat(@min(@as(f64, @floatFromInt(total_hits)), std.math.round(n300_f)));
    const n100: u32 = total_hits -| n300;
    const max_combo_f: f64 = @as(f64, @floatFromInt(meta.object_count)) * combo_pct / 100.0;
    const max_combo: u32 = @intFromFloat(std.math.round(max_combo_f));

    const result = pp.calculate(map_file, .{
        .mode = sender.mode,
        .lazer = 0,
        .mods = @intCast(mods),
        .max_combo = max_combo,
        .n_geki = if (sender.mode == 3) total_hits else 0,
        .n_katu = 0,
        .n300 = n300,
        .n100 = n100,
        .n50 = 0,
        .misses = misses,
        .legacy_total_score = 1_000_000,
    }) catch {
        try sendPm(allocator, sender, "pp calc failed on this map");
        return;
    };
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} — {s} [{s}] | ★ {d:.2} | {s} | {d:.2}pp ({d:.1}%, {d}x combo, {d}m)", .{ meta.artist, meta.title, meta.version, result.stars, mods_str, result.pp, accuracy, max_combo, misses }) catch return;
    try sendPm(allocator, sender, msg);
}

fn parseMods(str: []const u8) ?i32 {
    var mods: i32 = 0;
    var i: usize = 0;
    while (i + 1 < str.len) : (i += 2) {
        const pair = str[i..][0..2];
        const bit: i32 = if (std.mem.eql(u8, pair, "nf")) 1 << 0 //
        else if (std.mem.eql(u8, pair, "ez")) 1 << 1 //
        else if (std.mem.eql(u8, pair, "hd")) 1 << 3 //
        else if (std.mem.eql(u8, pair, "hr")) 1 << 4 //
        else if (std.mem.eql(u8, pair, "sd")) 1 << 5 //
        else if (std.mem.eql(u8, pair, "dt")) 1 << 6 //
        else if (std.mem.eql(u8, pair, "rx")) 1 << 7 //
        else if (std.mem.eql(u8, pair, "ht")) 1 << 8 //
        else if (std.mem.eql(u8, pair, "nc")) 1 << 10 //
        else if (std.mem.eql(u8, pair, "fl")) 1 << 12 //
        else if (std.mem.eql(u8, pair, "ap")) 1 << 13 //
        else if (std.mem.eql(u8, pair, "so")) 1 << 14 //
        else if (std.mem.eql(u8, pair, "at")) 1 << 15 //
        else if (std.mem.eql(u8, pair, "cn")) 1 << 16 //
        else if (std.mem.eql(u8, pair, "tp")) 1 << 17 //
        else if (std.mem.eql(u8, pair, "fi")) 1 << 20 //
        else if (std.mem.eql(u8, pair, "rn")) 1 << 22 //
        else if (std.mem.eql(u8, pair, "cl")) 1 << 23 //
        else if (std.mem.eql(u8, pair, "v2")) 1 << 27 //
        else if (std.mem.eql(u8, pair, "mr")) 1 << 29 //
        else return null;
        mods |= bit;
    }
    return mods;
}

fn modString(buf: *[32]u8, mods: i32) []const u8 {
    if (mods == 0) return "NM";
    var pos: usize = 0;
    const mod_names = [_]struct { bit: i32, name: []const u8 }{
        .{ .bit = 1 << 0, .name = "NF" },
        .{ .bit = 1 << 1, .name = "EZ" },
        .{ .bit = 1 << 3, .name = "HD" },
        .{ .bit = 1 << 4, .name = "HR" },
        .{ .bit = 1 << 5, .name = "SD" },
        .{ .bit = 1 << 6, .name = "DT" },
        .{ .bit = 1 << 7, .name = "RX" },
        .{ .bit = 1 << 8, .name = "HT" },
        .{ .bit = 1 << 10, .name = "NC" },
        .{ .bit = 1 << 12, .name = "FL" },
        .{ .bit = 1 << 13, .name = "AP" },
        .{ .bit = 1 << 14, .name = "SO" },
        .{ .bit = 1 << 15, .name = "AT" },
        .{ .bit = 1 << 16, .name = "CN" },
        .{ .bit = 1 << 17, .name = "TP" },
        .{ .bit = 1 << 20, .name = "FI" },
        .{ .bit = 1 << 22, .name = "RN" },
        .{ .bit = 1 << 23, .name = "CL" },
        .{ .bit = 1 << 27, .name = "V2" },
        .{ .bit = 1 << 29, .name = "MR" },
    };
    for (mod_names) |m| {
        if (mods & m.bit != 0) {
            @memcpy(buf[pos..][0..2], m.name);
            pos += 2;
        }
    }
    if (pos == 0) return "NM";
    return buf[0..pos];
}

fn sendPm(allocator: std.mem.Allocator, sender: *sessions_mod.Session, text: []const u8) !void {
    var msg = protocol.Writer.init(allocator);
    defer msg.deinit();
    try protocol.writeMessage(&msg, "kai", text, sender.user.name, 3);
    try sender.queue.appendSlice(allocator, msg.bytes());
}
