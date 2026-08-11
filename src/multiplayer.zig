const std = @import("std");
const protocol = @import("protocol.zig");

pub const max_matches = 64;
pub const max_name_len = 50;
pub const max_password_len = 32;
pub const max_map_name_len = 256;
pub const speed_changing_mods: i32 = (1 << 6) | (1 << 8) | (1 << 9);

pub const SlotStatus = enum(u8) {
    open = 1,
    locked = 2,
    not_ready = 4,
    ready = 8,
    no_map = 16,
    playing = 32,
    complete = 64,
    quit = 128,
};

pub const Team = enum(u8) { neutral = 0, blue = 1, red = 2 };

pub fn statusHasPlayer(status: u8) bool {
    return status & 0x7c != 0;
}

fn validSlotStatus(status: u8) bool {
    return switch (status) {
        @intFromEnum(SlotStatus.open),
        @intFromEnum(SlotStatus.locked),
        @intFromEnum(SlotStatus.not_ready),
        @intFromEnum(SlotStatus.ready),
        @intFromEnum(SlotStatus.no_map),
        @intFromEnum(SlotStatus.playing),
        @intFromEnum(SlotStatus.complete),
        @intFromEnum(SlotStatus.quit),
        => true,
        else => false,
    };
}

fn validMapMd5(value: []const u8) bool {
    if (value.len == 0) return true;
    if (value.len != 32) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

pub const Slot = struct {
    user_id: ?i32 = null,
    status: u8 = @intFromEnum(SlotStatus.open),
    team: u8 = @intFromEnum(Team.neutral),
    mods: i32 = 0,
    loaded: bool = false,
    skipped: bool = false,

    pub fn reset(self: *Slot, status: SlotStatus) void {
        self.* = .{ .status = @intFromEnum(status) };
    }
};

pub const MatchData = struct {
    id: i16,
    in_progress: bool,
    mods: i32,
    name: []const u8,
    password: []const u8,
    map_name: []const u8,
    map_id: i32,
    map_md5: []const u8,
    slot_statuses: [16]u8,
    slot_teams: [16]u8,
    slot_mods: [16]i32,
    host_id: i32,
    mode: u8,
    win_condition: u8,
    team_type: u8,
    freemods: bool,
    seed: i32,
};

pub const Match = struct {
    allocator: std.mem.Allocator,
    id: u16,
    in_progress: bool = false,
    mods: i32,
    name: []u8,
    password: []u8,
    map_name: []u8,
    map_id: i32,
    map_md5: []u8,
    slots: [16]Slot = [_]Slot{.{}} ** 16,
    referees: [16]?i32 = [_]?i32{null} ** 16,
    host_id: i32,
    mode: u8,
    win_condition: u8,
    team_type: u8,
    freemods: bool,
    seed: i32,

    pub fn init(allocator: std.mem.Allocator, id: u16, data: MatchData, host_id: i32) !Match {
        const name = try allocator.dupe(u8, data.name);
        errdefer allocator.free(name);
        const password = try allocator.dupe(u8, data.password);
        errdefer allocator.free(password);
        const map_name = try allocator.dupe(u8, data.map_name);
        errdefer allocator.free(map_name);
        const map_md5 = try allocator.dupe(u8, data.map_md5);
        errdefer allocator.free(map_md5);
        var result: Match = .{
            .allocator = allocator,
            .id = id,
            .mods = data.mods,
            .name = name,
            .password = password,
            .map_name = map_name,
            .map_id = data.map_id,
            .map_md5 = map_md5,
            .host_id = host_id,
            .mode = data.mode,
            .win_condition = data.win_condition,
            .team_type = data.team_type,
            .freemods = data.freemods,
            .seed = data.seed,
        };
        result.slots[0].user_id = host_id;
        result.slots[0].status = @intFromEnum(SlotStatus.not_ready);
        if (isTeamVersus(result.team_type)) result.slots[0].team = @intFromEnum(Team.red);
        return result;
    }

    pub fn deinit(self: *Match) void {
        self.allocator.free(self.name);
        self.allocator.free(self.password);
        self.allocator.free(self.map_name);
        self.allocator.free(self.map_md5);
        self.* = undefined;
    }

    pub fn slotByUser(self: *Match, user_id: i32) ?*Slot {
        for (&self.slots) |*slot| if (slot.user_id == user_id) return slot;
        return null;
    }

    pub fn slotIndexByUser(self: *const Match, user_id: i32) ?usize {
        for (self.slots, 0..) |slot, index| if (slot.user_id == user_id) return index;
        return null;
    }

    pub fn freeSlot(self: *Match) ?*Slot {
        for (&self.slots) |*slot| if (slot.status == @intFromEnum(SlotStatus.open)) return slot;
        return null;
    }

    pub fn isEmpty(self: *const Match) bool {
        for (self.slots) |slot| if (slot.user_id != null) return false;
        return true;
    }

    pub fn firstUser(self: *const Match) ?i32 {
        for (self.slots) |slot| if (slot.user_id) |user_id| return user_id;
        return null;
    }

    pub fn occupied(self: *const Match) usize {
        var count: usize = 0;
        for (self.slots) |slot| if (slot.user_id != null) {
            count += 1;
        };
        return count;
    }

    pub fn isReferee(self: *const Match, user_id: i32) bool {
        if (self.host_id == user_id) return true;
        for (self.referees) |referee| if (referee == user_id) return true;
        return false;
    }

    pub fn addReferee(self: *Match, user_id: i32) bool {
        if (self.isReferee(user_id) or self.slotByUser(user_id) == null) return false;
        for (&self.referees) |*referee| if (referee.* == null) {
            referee.* = user_id;
            return true;
        };
        return false;
    }

    pub fn removeReferee(self: *Match, user_id: i32) bool {
        if (self.host_id == user_id) return false;
        for (&self.referees) |*referee| if (referee.* == user_id) {
            referee.* = null;
            return true;
        };
        return false;
    }

    pub fn updateSettings(self: *Match, data: MatchData) !void {
        const name = try self.allocator.dupe(u8, data.name);
        errdefer self.allocator.free(name);
        const map_name = try self.allocator.dupe(u8, data.map_name);
        errdefer self.allocator.free(map_name);
        const map_md5 = try self.allocator.dupe(u8, data.map_md5);
        errdefer self.allocator.free(map_md5);
        self.allocator.free(self.name);
        self.allocator.free(self.map_name);
        self.allocator.free(self.map_md5);
        self.name = name;
        self.map_name = map_name;
        self.map_md5 = map_md5;
        self.map_id = data.map_id;
        self.mode = data.mode;
        self.win_condition = data.win_condition;
        self.team_type = data.team_type;
        self.seed = data.seed;
    }

    pub fn updatePassword(self: *Match, password_value: []const u8) !void {
        const password = try self.allocator.dupe(u8, password_value);
        self.allocator.free(self.password);
        self.password = password;
    }
};

pub fn readMatch(payload: []const u8) !MatchData {
    var reader: protocol.PayloadReader = .{ .data = payload };
    const id = try reader.int(i16);
    const in_progress_byte = try reader.byte();
    if (in_progress_byte > 1) return error.InvalidMatch;
    _ = try reader.byte();
    const mods = try reader.int(i32);
    const name = try reader.string();
    const password = try reader.string();
    const map_name = try reader.string();
    const map_id = try reader.int(i32);
    const map_md5 = try reader.string();
    if (mods < 0 or map_id < -1 or name.len == 0 or name.len > max_name_len or password.len > max_password_len or map_name.len > max_map_name_len or !validMapMd5(map_md5)) return error.InvalidMatch;
    var statuses: [16]u8 = undefined;
    for (&statuses) |*status| {
        status.* = try reader.byte();
        if (!validSlotStatus(status.*)) return error.InvalidMatch;
    }
    var teams: [16]u8 = undefined;
    for (&teams) |*team| {
        team.* = try reader.byte();
        if (team.* > @intFromEnum(Team.red)) return error.InvalidMatch;
    }
    for (statuses) |status| if (statusHasPlayer(status)) {
        if (try reader.int(i32) <= 0) return error.InvalidMatch;
    };
    const host_id = try reader.int(i32);
    const mode = try reader.byte();
    const win_condition = try reader.byte();
    const team_type = try reader.byte();
    const freemods_byte = try reader.byte();
    if (host_id <= 0 or mode > 3 or win_condition > 3 or team_type > 3 or freemods_byte > 1) return error.InvalidMatch;
    var slot_mods = [_]i32{0} ** 16;
    if (freemods_byte == 1) for (&slot_mods) |*slot_mods_value| {
        slot_mods_value.* = try reader.int(i32);
        if (slot_mods_value.* < 0) return error.InvalidMatch;
    };
    const seed = try reader.int(i32);
    if (reader.pos != payload.len) return error.InvalidMatch;
    return .{
        .id = id,
        .in_progress = in_progress_byte == 1,
        .mods = mods,
        .name = name,
        .password = password,
        .map_name = map_name,
        .map_id = map_id,
        .map_md5 = map_md5,
        .slot_statuses = statuses,
        .slot_teams = teams,
        .slot_mods = slot_mods,
        .host_id = host_id,
        .mode = mode,
        .win_condition = win_condition,
        .team_type = team_type,
        .freemods = freemods_byte == 1,
        .seed = seed,
    };
}

pub fn writePacket(writer: *protocol.Writer, packet: protocol.ServerPacket, match: *const Match, send_password: bool) !void {
    const start = try writer.begin(packet);
    try writeMatch(writer, match, send_password);
    writer.finish(start);
}

pub fn writeMatch(writer: *protocol.Writer, match: *const Match, send_password: bool) !void {
    try writer.int(u16, match.id);
    try writer.byte(@intFromBool(match.in_progress));
    try writer.byte(0);
    try writer.int(i32, match.mods);
    try writer.string(match.name);
    if (match.password.len == 0) {
        try writer.byte(0);
    } else if (send_password) {
        try writer.string(match.password);
    } else {
        try writer.raw(&.{ 0x0b, 0x00 });
    }
    try writer.string(match.map_name);
    try writer.int(i32, match.map_id);
    try writer.string(match.map_md5);
    for (match.slots) |slot| try writer.byte(slot.status);
    for (match.slots) |slot| try writer.byte(slot.team);
    for (match.slots) |slot| if (statusHasPlayer(slot.status)) {
        try writer.int(i32, slot.user_id orelse return error.InvalidMatchState);
    };
    try writer.int(i32, match.host_id);
    try writer.byte(match.mode);
    try writer.byte(match.win_condition);
    try writer.byte(match.team_type);
    try writer.byte(@intFromBool(match.freemods));
    if (match.freemods) for (match.slots) |slot| try writer.int(i32, slot.mods);
    try writer.int(i32, match.seed);
}

pub fn validScoreFrame(payload: []const u8) bool {
    if (payload.len != 29 and payload.len != 45) return false;
    if (payload[25] > 1 or payload[28] > 1) return false;
    return if (payload[28] == 1) payload.len == 45 else payload.len == 29;
}

pub fn writeScoreFramePacket(writer: *protocol.Writer, payload: []const u8, slot_id: u8) !void {
    if (!validScoreFrame(payload) or slot_id >= 16) return error.InvalidScoreFrame;
    const start = try writer.begin(.match_score_update);
    try writer.raw(payload);
    writer.list.items[start + 7 + 4] = slot_id;
    writer.finish(start);
}

pub fn isTeamVersus(team_type: u8) bool {
    return team_type == 2 or team_type == 3;
}
