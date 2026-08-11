const std = @import("std");

pub const max_hit_count: i32 = 10_000_000;
pub const max_combo: i32 = 10_000_000;
pub const max_total_score: i64 = 1_000_000_000_000;

pub const Submission = struct {
    map_md5: []const u8,
    username: []const u8,
    online_checksum: []const u8,
    n300: i32,
    n100: i32,
    n50: i32,
    ngeki: i32,
    nkatu: i32,
    nmiss: i32,
    total_score: i64,
    max_combo: i32,
    perfect: bool,
    grade: []const u8,
    mods: i32,
    passed: bool,
    mode: u8,
    client_time: []const u8,
    client_flags: []const u8,

    pub fn accuracy(self: Submission) f64 {
        const total: i64 = switch (self.mode) {
            0 => @as(i64, self.n300) + @as(i64, self.n100) + @as(i64, self.n50) + @as(i64, self.nmiss),
            1 => @as(i64, self.n300) + @as(i64, self.n100) + @as(i64, self.nmiss),
            2, 3 => @as(i64, self.n300) + @as(i64, self.n100) + @as(i64, self.n50) + @as(i64, self.ngeki) + @as(i64, self.nkatu) + @as(i64, self.nmiss),
            else => unreachable,
        };
        if (total == 0) return 0;
        const numerator: i64 = switch (self.mode) {
            0 => 300 * @as(i64, self.n300) + 100 * @as(i64, self.n100) + 50 * @as(i64, self.n50),
            1 => 300 * @as(i64, self.n300) + 150 * @as(i64, self.n100),
            2 => 300 * (@as(i64, self.n300) + @as(i64, self.n100) + @as(i64, self.n50)),
            3 => 300 * (@as(i64, self.n300) + @as(i64, self.ngeki)) + 200 * @as(i64, self.nkatu) + 100 * @as(i64, self.n100) + 50 * @as(i64, self.n50),
            else => unreachable,
        };
        return @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(300 * @as(i64, total)));
    }

    pub fn rankNamespace(self: Submission) []const u8 {
        const relax: i32 = 1 << 7;
        const autopilot: i32 = 1 << 13;
        const scorev2: i32 = 1 << 27;
        if (self.mods & autopilot != 0) return "autopilot";
        if (self.mods & relax != 0) return "relax";
        if (self.mods & scorev2 != 0) return "scorev2";
        return "vanilla";
    }

    pub fn verifyChecksum(self: Submission, osu_version: []const u8, client_hash: []const u8, storyboard_md5: []const u8) bool {
        var input_buffer: [2048]u8 = undefined;
        const perfect = if (self.perfect) "True" else "False";
        const passed = if (self.passed) "True" else "False";
        var name = self.username;
        while (name.len > 0 and name[name.len - 1] == ' ') name = name[0 .. name.len - 1];
        const input = std.fmt.bufPrint(
            &input_buffer,
            "chickenmcnuggets{d}o15{d}{d}smustard{d}{d}uu{s}{d}{s}{s}{d}{s}{d}Q{s}{d}{s}{s}{s}{s}",
            .{ @as(i64, self.n100) + @as(i64, self.n300), self.n50, self.ngeki, self.nkatu, self.nmiss, self.map_md5, self.max_combo, perfect, name, self.total_score, self.grade, self.mods, passed, self.mode, osu_version, self.client_time, client_hash, storyboard_md5 },
        ) catch return false;
        var digest: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(input, &digest, .{});
        var encoded: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&encoded, "{x}", .{digest}) catch return false;
        return self.online_checksum.len == encoded.len and std.crypto.timing_safe.eql([32]u8, encoded, self.online_checksum[0..32].*);
    }
};

pub const OwnedSubmission = struct {
    allocator: std.mem.Allocator,
    value: Submission,

    pub fn init(allocator: std.mem.Allocator, source: Submission) !OwnedSubmission {
        const map_md5 = try allocator.dupe(u8, source.map_md5);
        errdefer allocator.free(map_md5);
        const username = try allocator.dupe(u8, source.username);
        errdefer allocator.free(username);
        const online_checksum = try allocator.dupe(u8, source.online_checksum);
        errdefer allocator.free(online_checksum);
        const grade = try allocator.dupe(u8, source.grade);
        errdefer allocator.free(grade);
        const client_time = try allocator.dupe(u8, source.client_time);
        errdefer allocator.free(client_time);
        const client_flags = try allocator.dupe(u8, source.client_flags);
        errdefer allocator.free(client_flags);
        var value = source;
        value.map_md5 = map_md5;
        value.username = username;
        value.online_checksum = online_checksum;
        value.grade = grade;
        value.client_time = client_time;
        value.client_flags = client_flags;
        return .{ .allocator = allocator, .value = value };
    }

    pub fn deinit(self: *OwnedSubmission) void {
        self.allocator.free(self.value.map_md5);
        self.allocator.free(self.value.username);
        self.allocator.free(self.value.online_checksum);
        self.allocator.free(self.value.grade);
        self.allocator.free(self.value.client_time);
        self.allocator.free(self.value.client_flags);
        self.* = undefined;
    }
};

pub fn statsMode(vanilla_mode: u8, mods: i32) ?u8 {
    if (vanilla_mode > 3) return null;
    const relax: i32 = 1 << 7;
    const autopilot: i32 = 1 << 13;
    if (mods & autopilot != 0) return if (vanilla_mode == 0) 8 else null;
    if (mods & relax != 0) return if (vanilla_mode < 3) vanilla_mode + 4 else null;
    return vanilla_mode;
}

pub fn replayLengthAccepted(passed: bool, replay_len: usize) bool {
    const max_replay_size = 16 * 1024 * 1024;
    return replay_len <= max_replay_size and (!passed or replay_len != 0);
}

pub fn parse(data: []const u8) !Submission {
    var fields: [18][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, data, ':');
    for (&fields) |*field| field.* = it.next() orelse return error.InvalidFieldCount;
    while (it.next()) |_| {}
    if (!isMd5(fields[0]) or !isMd5(fields[2])) return error.InvalidChecksum;
    if (fields[1].len == 0 or fields[1].len > 32) return error.InvalidUsername;
    if (!validGrade(fields[12])) return error.InvalidGrade;
    if (fields[16].len != 12) return error.InvalidClientTime;
    for (fields[16]) |c| if (!std.ascii.isDigit(c)) return error.InvalidClientTime;
    const mode = try parseInteger(u8, fields[15]);
    if (mode > 3) return error.InvalidMode;
    return .{
        .map_md5 = fields[0],
        .username = fields[1],
        .online_checksum = fields[2],
        .n300 = try count(fields[3]),
        .n100 = try count(fields[4]),
        .n50 = try count(fields[5]),
        .ngeki = try count(fields[6]),
        .nkatu = try count(fields[7]),
        .nmiss = try count(fields[8]),
        .total_score = try boundedNonNegative(i64, fields[9], max_total_score),
        .max_combo = try boundedNonNegative(i32, fields[10], max_combo),
        .perfect = try parseBool(fields[11]),
        .grade = fields[12],
        .mods = try nonNegative(i32, fields[13]),
        .passed = try parseBool(fields[14]),
        .mode = mode,
        .client_time = fields[16],
        .client_flags = fields[17],
    };
}

fn count(value: []const u8) !i32 {
    return boundedNonNegative(i32, value, max_hit_count);
}
fn nonNegative(comptime T: type, value: []const u8) !T {
    const parsed = try parseInteger(T, value);
    if (parsed < 0) return error.NegativeValue;
    return parsed;
}
fn boundedNonNegative(comptime T: type, value: []const u8, maximum: T) !T {
    const parsed = try nonNegative(T, value);
    if (parsed > maximum) return error.ValueTooLarge;
    return parsed;
}
fn parseInteger(comptime T: type, value: []const u8) !T {
    return std.fmt.parseInt(T, value, 10) catch error.InvalidInteger;
}
fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "True")) return true;
    if (std.mem.eql(u8, value, "False")) return false;
    return error.InvalidBoolean;
}
fn isMd5(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    return true;
}
fn validGrade(value: []const u8) bool {
    const grades = [_][]const u8{ "XH", "SH", "X", "S", "A", "B", "C", "D", "F" };
    for (grades) |grade| if (std.mem.eql(u8, value, grade)) return true;
    return false;
}
