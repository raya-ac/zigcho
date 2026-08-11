const std = @import("std");

pub const ClientPacket = enum(u16) {
    change_action = 0,
    send_public_message = 1,
    logout = 2,
    request_status = 3,
    ping = 4,
    start_spectating = 16,
    stop_spectating = 17,
    spectate_frames = 18,
    cant_spectate = 21,
    send_private_message = 25,
    part_lobby = 29,
    join_lobby = 30,
    create_match = 31,
    join_match = 32,
    part_match = 33,
    change_slot = 38,
    match_ready = 39,
    match_lock = 40,
    match_change_settings = 41,
    match_start = 44,
    match_score_update = 47,
    match_complete = 49,
    match_change_mods = 51,
    match_load_complete = 52,
    match_no_beatmap = 54,
    match_not_ready = 55,
    match_failed = 56,
    match_has_beatmap = 59,
    match_skip_request = 60,
    channel_join = 63,
    beatmap_info_request = 68,
    match_transfer_host = 70,
    friend_add = 73,
    friend_remove = 74,
    match_change_team = 77,
    channel_part = 78,
    receive_updates = 79,
    set_away_message = 82,
    irc_only = 84,
    user_stats_request = 85,
    match_invite = 87,
    match_change_password = 90,
    tournament_match_info = 93,
    user_presence_request = 97,
    user_presence_request_all = 98,
    toggle_block_non_friend_dms = 99,
    tournament_join_match_channel = 108,
    tournament_leave_match_channel = 109,
    _,
};

pub const ServerPacket = enum(u16) {
    user_id = 5,
    send_message = 7,
    pong = 8,
    user_stats = 11,
    user_logout = 12,
    spectator_joined = 13,
    spectator_left = 14,
    spectate_frames = 15,
    notification = 24,
    update_match = 26,
    new_match = 27,
    dispose_match = 28,
    toggle_block_non_friend_dms = 34,
    match_join_success = 36,
    match_join_fail = 37,
    fellow_spectator_joined = 42,
    fellow_spectator_left = 43,
    all_players_loaded = 45,
    match_start = 46,
    match_score_update = 48,
    match_transfer_host = 50,
    match_all_players_loaded = 53,
    match_player_failed = 57,
    match_complete = 58,
    match_skip = 61,
    channel_join_success = 64,
    channel_info = 65,
    channel_kick = 66,
    channel_auto_join = 67,
    beatmap_info_reply = 69,
    privileges = 71,
    friends_list = 72,
    protocol_version = 75,
    main_menu_icon = 76,
    match_player_skipped = 81,
    user_presence = 83,
    restart = 86,
    match_invite = 88,
    channel_info_end = 89,
    match_change_password = 91,
    silence_end = 92,
    user_silenced = 94,
    user_presence_single = 95,
    user_presence_bundle = 96,
    user_dm_blocked = 100,
    target_is_silenced = 101,
    version_update_forced = 102,
    switch_server = 103,
    account_restricted = 104,
    match_abort = 106,
    switch_tournament_server = 107,
};

pub const Packet = struct { id: ClientPacket, payload: []const u8 };

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn next(self: *Reader) !?Packet {
        if (self.pos == self.data.len) return null;
        if (self.data.len - self.pos < 7) return error.TruncatedPacket;
        const id = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        const length = std.mem.readInt(u32, self.data[self.pos + 3 ..][0..4], .little);
        const start = self.pos + 7;
        const end = std.math.add(usize, start, length) catch return error.PacketTooLarge;
        if (end > self.data.len) return error.TruncatedPacket;
        self.pos = end;
        return .{ .id = @enumFromInt(id), .payload = self.data[start..end] };
    }
};

pub const PayloadReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn int(self: *PayloadReader, comptime T: type) !T {
        const n = @sizeOf(T);
        if (self.pos + n > self.data.len) return error.TruncatedPayload;
        defer self.pos += n;
        return std.mem.readInt(T, self.data[self.pos..][0..n], .little);
    }

    pub fn byte(self: *PayloadReader) !u8 {
        return self.int(u8);
    }

    pub fn string(self: *PayloadReader) ![]const u8 {
        const marker = try self.byte();
        if (marker == 0) return "";
        if (marker != 0x0b) return error.InvalidStringMarker;
        const len = try self.uleb128();
        if (len > self.data.len - self.pos) return error.TruncatedPayload;
        defer self.pos += len;
        return self.data[self.pos..][0..len];
    }

    fn uleb128(self: *PayloadReader) !usize {
        var value: usize = 0;
        var shift: u6 = 0;
        while (shift < 63) : (shift += 7) {
            const b = try self.byte();
            value |= @as(usize, b & 0x7f) << shift;
            if (b & 0x80 == 0) return value;
        }
        return error.IntegerOverflow;
    }
};

pub const Writer = struct {
    list: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{ .list = .empty, .allocator = allocator };
    }
    pub fn deinit(self: *Writer) void {
        self.list.deinit(self.allocator);
    }
    pub fn bytes(self: *const Writer) []const u8 {
        return self.list.items;
    }

    pub fn begin(self: *Writer, id: ServerPacket) !usize {
        const start = self.list.items.len;
        try self.int(u16, @intFromEnum(id));
        try self.byte(0);
        try self.int(u32, 0);
        return start;
    }

    pub fn finish(self: *Writer, start: usize) void {
        const size: u32 = @intCast(self.list.items.len - start - 7);
        std.mem.writeInt(u32, self.list.items[start + 3 ..][0..4], size, .little);
    }

    pub fn packetInt(self: *Writer, id: ServerPacket, value: i32) !void {
        const start = try self.begin(id);
        try self.int(i32, value);
        self.finish(start);
    }
    pub fn packetEmpty(self: *Writer, id: ServerPacket) !void {
        const start = try self.begin(id);
        self.finish(start);
    }
    pub fn packetString(self: *Writer, id: ServerPacket, value: []const u8) !void {
        const start = try self.begin(id);
        try self.string(value);
        self.finish(start);
    }
    pub fn byte(self: *Writer, value: u8) !void {
        try self.list.append(self.allocator, value);
    }
    pub fn raw(self: *Writer, value: []const u8) !void {
        try self.list.appendSlice(self.allocator, value);
    }
    pub fn int(self: *Writer, comptime T: type, value: T) !void {
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, value, .little);
        try self.raw(&buf);
    }
    pub fn float(self: *Writer, comptime T: type, value: T) !void {
        try self.int(std.meta.Int(.unsigned, @bitSizeOf(T)), @bitCast(value));
    }
    pub fn string(self: *Writer, value: []const u8) !void {
        if (value.len == 0) return self.byte(0);
        try self.byte(0x0b);
        var n = value.len;
        while (true) {
            const b: u8 = @intCast(n & 0x7f);
            n >>= 7;
            try self.byte(if (n == 0) b else b | 0x80);
            if (n == 0) break;
        }
        try self.raw(value);
    }
};

pub fn writeMessage(w: *Writer, sender: []const u8, text: []const u8, target: []const u8, sender_id: i32) !void {
    return writeMessagePacket(w, .send_message, sender, text, target, sender_id);
}

pub fn writeMessagePacket(w: *Writer, packet: ServerPacket, sender: []const u8, text: []const u8, target: []const u8, sender_id: i32) !void {
    const start = try w.begin(packet);
    try w.string(sender);
    try w.string(text);
    try w.string(target);
    try w.int(i32, sender_id);
    w.finish(start);
}

pub fn writeChannel(w: *Writer, name: []const u8, topic: []const u8, count: i32) !void {
    const start = try w.begin(.channel_info);
    try w.string(name);
    try w.string(topic);
    try w.int(i32, count);
    w.finish(start);
}
