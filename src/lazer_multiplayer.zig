const std = @import("std");
const domain = @import("domain.zig");
const storage = @import("runtime_storage.zig");
const beatmap_sync = @import("beatmap_sync.zig");

pub const max_rooms = 64;
pub const Activity = enum { lobby, queue, multiplayer, playing };
pub const max_connections = 128;
pub const max_users = 16;
pub const max_playlist = 32;
pub const max_matchmaking_maps = 16;
pub const max_room_scores = 128;
pub const max_room_participants = 128;
pub const matchmaking_rounds = 3;
const ranked_player_count = 2;
const ranked_hand_size = 5;
const max_ranked_cards = max_playlist * ranked_player_count;
const max_hub_message = 60 * 1024;
const ranked_pick_seconds: i64 = 30;
const timespan_ticks_per_millisecond: i64 = 10_000;

const matchmaking_stage = struct {
    const waiting_for_clients_join: u8 = 0;
    const round_warmup: u8 = 1;
    const user_beatmap_select: u8 = 2;
    const server_beatmap_finalised: u8 = 3;
    const waiting_for_beatmap_download: u8 = 4;
    const gameplay_warmup: u8 = 5;
    const gameplay: u8 = 6;
    const results: u8 = 7;
    const ended: u8 = 8;
};

const ranked_stage = struct {
    const wait_for_join: u8 = 0;
    const round_warmup: u8 = 1;
    const card_discard: u8 = 2;
    const finish_card_discard: u8 = 3;
    const card_play: u8 = 4;
    const finish_card_play: u8 = 5;
    const gameplay_warmup: u8 = 6;
    const gameplay: u8 = 7;
    const results: u8 = 8;
    const ended: u8 = 9;
};

pub const RoomScorePath = struct {
    room_id: i64,
    playlist_item_id: i64,
    token_id: ?i64,
};

pub const RoomUserPath = struct { room_id: i64, user_id: i32 };
pub const RoomUserScorePath = struct { room_id: i64, playlist_item_id: i64, user_id: i32 };

pub const RoomListMode = enum { open, ended, participated, owned };
pub const RoomListStatus = enum { idle, playing };
pub const RoomListFilter = struct {
    requester_id: i32,
    mode: RoomListMode = .open,
    status: ?RoomListStatus = null,
    category: []const u8 = "",
};

pub fn roomListFilter(requester_id: i32, mode: []const u8, status: ?[]const u8, category: []const u8) !RoomListFilter {
    const parsed_mode = std.meta.stringToEnum(RoomListMode, mode) orelse return error.InvalidRoomListFilter;
    const parsed_status: ?RoomListStatus = if (status) |value| std.meta.stringToEnum(RoomListStatus, value) orelse return error.InvalidRoomListFilter else null;
    if (category.len != 0 and !std.mem.eql(u8, category, "normal") and !std.mem.eql(u8, category, "realtime") and !std.mem.eql(u8, category, "spotlight") and !std.mem.eql(u8, category, "featured_artist")) return error.InvalidRoomListFilter;
    return .{ .requester_id = requester_id, .mode = parsed_mode, .status = parsed_status, .category = category };
}

fn archiveIncludesUser(allocator: std.mem.Allocator, participant_ids_json: []const u8, user_id: i32) bool {
    const parsed = std.json.parseFromSlice([]i32, allocator, participant_ids_json, .{}) catch return false;
    defer parsed.deinit();
    return std.mem.indexOfScalar(i32, parsed.value, user_id) != null;
}

pub fn parseRoomUserPath(path: []const u8) ?RoomUserPath {
    const prefix = "/api/v2/rooms/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const marker = "/users/";
    const marker_at = std.mem.indexOf(u8, rest, marker) orelse return null;
    const room_id = std.fmt.parseInt(i64, rest[0..marker_at], 10) catch return null;
    const user_text = rest[marker_at + marker.len ..];
    if (std.mem.indexOfScalar(u8, user_text, '/') != null) return null;
    const user_id = std.fmt.parseInt(i32, user_text, 10) catch return null;
    if (room_id <= 0 or user_id <= 0) return null;
    return .{ .room_id = room_id, .user_id = user_id };
}

pub fn parseRoomLeaderboardPath(path: []const u8) ?i64 {
    const prefix = "/api/v2/rooms/";
    const suffix = "/leaderboard";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const id_text = path[prefix.len .. path.len - suffix.len];
    if (id_text.len == 0 or std.mem.indexOfScalar(u8, id_text, '/') != null) return null;
    const id = std.fmt.parseInt(i64, id_text, 10) catch return null;
    return if (id > 0) id else null;
}

pub fn parseRoomUserScorePath(path: []const u8) ?RoomUserScorePath {
    const prefix = "/api/v2/rooms/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    var parts = std.mem.splitScalar(u8, path[prefix.len..], '/');
    const room_text = parts.next() orelse return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "playlist")) return null;
    const playlist_text = parts.next() orelse return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "scores")) return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "users")) return null;
    const user_text = parts.next() orelse return null;
    if (parts.next() != null) return null;
    const room_id = std.fmt.parseInt(i64, room_text, 10) catch return null;
    const playlist_item_id = std.fmt.parseInt(i64, playlist_text, 10) catch return null;
    const user_id = std.fmt.parseInt(i32, user_text, 10) catch return null;
    if (room_id <= 0 or playlist_item_id <= 0 or user_id <= 0) return null;
    return .{ .room_id = room_id, .playlist_item_id = playlist_item_id, .user_id = user_id };
}

pub const RoomScoreContext = struct {
    beatmap_id: i32,
    ruleset_id: u8,
};

pub const RoomScoreResult = struct {
    score_id: i64,
    total_score: i64,
    accuracy: f64,
    max_combo: i32,
    passed: bool,
};

const RoomScoreRecord = struct {
    score_id: i64,
    user_id: i32,
    playlist_item_id: i64,
    total_score: i64,
    accuracy: f64,
    max_combo: i32,
    passed: bool,
};

fn FixedRaw(comptime capacity: usize) type {
    return struct {
        len: u16 = 0,
        bytes: [capacity]u8 = undefined,

        const Self = @This();

        fn set(self: *Self, value: []const u8) !void {
            if (value.len > self.bytes.len) return error.MultiplayerPayloadTooLarge;
            @memcpy(self.bytes[0..value.len], value);
            self.len = @intCast(value.len);
        }

        fn setText(self: *Self, value: []const u8) void {
            var len = @min(value.len, self.bytes.len);
            while (len != 0 and !std.unicode.utf8ValidateSlice(value[0..len])) len -= 1;
            @memcpy(self.bytes[0..len], value[0..len]);
            self.len = @intCast(len);
        }

        fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

const Raw64 = FixedRaw(64);
const Raw128 = FixedRaw(128);
const Raw2048 = FixedRaw(2048);
const Text64 = FixedRaw(64);
const Text128 = FixedRaw(128);
const Text256 = FixedRaw(256);

pub const MessagePackReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn byte(self: *MessagePackReader) !u8 {
        if (self.pos >= self.data.len) return error.TruncatedMessagePack;
        const value = self.data[self.pos];
        self.pos += 1;
        return value;
    }

    fn take(self: *MessagePackReader, len: usize) ![]const u8 {
        const end = std.math.add(usize, self.pos, len) catch return error.TruncatedMessagePack;
        if (end > self.data.len) return error.TruncatedMessagePack;
        const value = self.data[self.pos..end];
        self.pos = end;
        return value;
    }

    fn readUnsigned(self: *MessagePackReader, comptime T: type) !T {
        const bytes: *const [@sizeOf(T)]u8 = @ptrCast(try self.take(@sizeOf(T)));
        return std.mem.readInt(T, bytes, .big);
    }

    pub fn arrayLen(self: *MessagePackReader) !usize {
        const tag = try self.byte();
        if (tag >= 0x90 and tag <= 0x9f) return tag & 0x0f;
        return switch (tag) {
            0xdc => try self.readUnsigned(u16),
            0xdd => std.math.cast(usize, try self.readUnsigned(u32)) orelse error.MultiplayerPayloadTooLarge,
            else => error.ExpectedMessagePackArray,
        };
    }

    pub fn mapLen(self: *MessagePackReader) !usize {
        const tag = try self.byte();
        if (tag >= 0x80 and tag <= 0x8f) return tag & 0x0f;
        return switch (tag) {
            0xde => try self.readUnsigned(u16),
            0xdf => std.math.cast(usize, try self.readUnsigned(u32)) orelse error.MultiplayerPayloadTooLarge,
            else => error.ExpectedMessagePackMap,
        };
    }

    pub fn string(self: *MessagePackReader) ![]const u8 {
        const tag = try self.byte();
        const len: usize = if (tag >= 0xa0 and tag <= 0xbf)
            tag & 0x1f
        else switch (tag) {
            0xd9 => try self.byte(),
            0xda => try self.readUnsigned(u16),
            0xdb => std.math.cast(usize, try self.readUnsigned(u32)) orelse return error.MultiplayerPayloadTooLarge,
            else => return error.ExpectedMessagePackString,
        };
        return self.take(len);
    }

    pub fn integer(self: *MessagePackReader) !i64 {
        const tag = try self.byte();
        if (tag <= 0x7f) return tag;
        if (tag >= 0xe0) return @as(i8, @bitCast(tag));
        return switch (tag) {
            0xcc => try self.byte(),
            0xcd => try self.readUnsigned(u16),
            0xce => try self.readUnsigned(u32),
            0xcf => std.math.cast(i64, try self.readUnsigned(u64)) orelse error.MultiplayerIntegerOverflow,
            0xd0 => @as(i8, @bitCast(try self.byte())),
            0xd1 => @as(i16, @bitCast(try self.readUnsigned(u16))),
            0xd2 => @as(i32, @bitCast(try self.readUnsigned(u32))),
            0xd3 => @as(i64, @bitCast(try self.readUnsigned(u64))),
            else => error.ExpectedMessagePackInteger,
        };
    }

    pub fn boolean(self: *MessagePackReader) !bool {
        return switch (try self.byte()) {
            0xc2 => false,
            0xc3 => true,
            else => error.ExpectedMessagePackBoolean,
        };
    }

    pub fn nullableInteger(self: *MessagePackReader) !?i64 {
        if (self.pos >= self.data.len) return error.TruncatedMessagePack;
        if (self.data[self.pos] == 0xc0) {
            self.pos += 1;
            return null;
        }
        return try self.integer();
    }

    pub fn raw(self: *MessagePackReader) ![]const u8 {
        const start = self.pos;
        try self.skip(0);
        return self.data[start..self.pos];
    }

    pub fn skip(self: *MessagePackReader, depth: u8) !void {
        if (depth >= 16) return error.MessagePackNestingTooDeep;
        const tag = try self.byte();
        if (tag <= 0x7f or tag >= 0xe0 or tag == 0xc0 or tag == 0xc2 or tag == 0xc3) return;
        if (tag >= 0xa0 and tag <= 0xbf) {
            _ = try self.take(tag & 0x1f);
            return;
        }
        if (tag >= 0x90 and tag <= 0x9f) {
            for (0..tag & 0x0f) |_| try self.skip(depth + 1);
            return;
        }
        if (tag >= 0x80 and tag <= 0x8f) {
            for (0..(tag & 0x0f) * 2) |_| try self.skip(depth + 1);
            return;
        }
        const fixed: ?usize = switch (tag) {
            0xca, 0xce, 0xd2 => 4,
            0xcb, 0xcf, 0xd3 => 8,
            0xcc, 0xd0 => 1,
            0xcd, 0xd1 => 2,
            0xd4 => 2,
            0xd5 => 3,
            0xd6 => 5,
            0xd7 => 9,
            0xd8 => 17,
            else => null,
        };
        if (fixed) |len| {
            _ = try self.take(len);
            return;
        }
        const byte_len: ?usize = switch (tag) {
            0xc4, 0xd9 => try self.byte(),
            0xc5, 0xda => try self.readUnsigned(u16),
            0xc6, 0xdb => std.math.cast(usize, try self.readUnsigned(u32)) orelse return error.MultiplayerPayloadTooLarge,
            0xc7 => std.math.add(usize, try self.byte(), 1) catch return error.MultiplayerPayloadTooLarge,
            0xc8 => std.math.add(usize, try self.readUnsigned(u16), 1) catch return error.MultiplayerPayloadTooLarge,
            0xc9 => std.math.add(usize, std.math.cast(usize, try self.readUnsigned(u32)) orelse return error.MultiplayerPayloadTooLarge, 1) catch return error.MultiplayerPayloadTooLarge,
            else => null,
        };
        if (byte_len) |len| {
            _ = try self.take(len);
            return;
        }
        const collection_len: ?struct { len: usize, map: bool } = switch (tag) {
            0xdc => .{ .len = try self.readUnsigned(u16), .map = false },
            0xdd => .{ .len = std.math.cast(usize, try self.readUnsigned(u32)) orelse return error.MultiplayerPayloadTooLarge, .map = false },
            0xde => .{ .len = try self.readUnsigned(u16), .map = true },
            0xdf => .{ .len = std.math.cast(usize, try self.readUnsigned(u32)) orelse return error.MultiplayerPayloadTooLarge, .map = true },
            else => null,
        };
        if (collection_len) |collection| {
            const values = if (collection.map) std.math.mul(usize, collection.len, 2) catch return error.MultiplayerPayloadTooLarge else collection.len;
            for (0..values) |_| try self.skip(depth + 1);
            return;
        }
        return error.UnsupportedMessagePackValue;
    }
};

pub const MessagePackWriter = struct {
    writer: *std.Io.Writer,

    pub fn array(self: MessagePackWriter, len: usize) !void {
        if (len <= 15) return self.writer.writeByte(0x90 | @as(u8, @intCast(len)));
        if (len <= std.math.maxInt(u16)) {
            try self.writer.writeByte(0xdc);
            return self.writer.writeInt(u16, @intCast(len), .big);
        }
        try self.writer.writeByte(0xdd);
        try self.writer.writeInt(u32, @intCast(len), .big);
    }

    pub fn map(self: MessagePackWriter, len: usize) !void {
        if (len <= 15) return self.writer.writeByte(0x80 | @as(u8, @intCast(len)));
        if (len <= std.math.maxInt(u16)) {
            try self.writer.writeByte(0xde);
            return self.writer.writeInt(u16, @intCast(len), .big);
        }
        try self.writer.writeByte(0xdf);
        try self.writer.writeInt(u32, @intCast(len), .big);
    }

    pub fn string(self: MessagePackWriter, value: []const u8) !void {
        if (value.len <= 31) {
            try self.writer.writeByte(0xa0 | @as(u8, @intCast(value.len)));
        } else if (value.len <= std.math.maxInt(u8)) {
            try self.writer.writeByte(0xd9);
            try self.writer.writeByte(@intCast(value.len));
        } else if (value.len <= std.math.maxInt(u16)) {
            try self.writer.writeByte(0xda);
            try self.writer.writeInt(u16, @intCast(value.len), .big);
        } else {
            try self.writer.writeByte(0xdb);
            try self.writer.writeInt(u32, @intCast(value.len), .big);
        }
        try self.writer.writeAll(value);
    }

    pub fn integer(self: MessagePackWriter, value: i64) !void {
        if (value >= 0 and value <= 0x7f) return self.writer.writeByte(@intCast(value));
        if (value >= -32 and value < 0) return self.writer.writeByte(@bitCast(@as(i8, @intCast(value))));
        if (value >= std.math.minInt(i8) and value <= std.math.maxInt(i8)) {
            try self.writer.writeByte(0xd0);
            return self.writer.writeByte(@bitCast(@as(i8, @intCast(value))));
        }
        if (value >= std.math.minInt(i16) and value <= std.math.maxInt(i16)) {
            try self.writer.writeByte(0xd1);
            return self.writer.writeInt(i16, @intCast(value), .big);
        }
        if (value >= std.math.minInt(i32) and value <= std.math.maxInt(i32)) {
            try self.writer.writeByte(0xd2);
            return self.writer.writeInt(i32, @intCast(value), .big);
        }
        try self.writer.writeByte(0xd3);
        try self.writer.writeInt(i64, value, .big);
    }

    pub fn float64(self: MessagePackWriter, value: f64) !void {
        try self.writer.writeByte(0xcb);
        try self.writer.writeInt(u64, @bitCast(value), .big);
    }

    pub fn nil(self: MessagePackWriter) !void {
        try self.writer.writeByte(0xc0);
    }

    pub fn boolean(self: MessagePackWriter, value: bool) !void {
        try self.writer.writeByte(if (value) 0xc3 else 0xc2);
    }

    pub fn raw(self: MessagePackWriter, value: []const u8) !void {
        if (value.len == 0) return error.EmptyMessagePackValue;
        try self.writer.writeAll(value);
    }
};

const PlaylistItem = struct {
    id: i64 = 0,
    owner_id: i32 = 0,
    beatmap_id: i32 = 0,
    beatmapset_id: i32 = 0,
    checksum: Text64 = .{},
    ruleset_id: u8 = 0,
    artist: Text256 = .{},
    title: Text256 = .{},
    version: Text128 = .{},
    creator: Text128 = .{},
    status: i8 = 3,
    required_mods: Raw2048 = .{},
    allowed_mods: Raw2048 = .{},
    expired: bool = false,
    order: u16 = 0,
    played_at: Raw64 = .{},
    star_rating: f64 = 0,
    freestyle: bool = false,
};

const RoomUser = struct {
    id: i32,
    name: Text64 = .{},
    country: [2]u8 = .{ 'X', 'X' },
    state: u8 = 0,
    availability: Raw128 = .{},
    mods: Raw2048 = .{},
    ruleset_id: ?i32 = null,
    beatmap_id: ?i32 = null,
    voted_skip: bool = false,
    role: u8 = 0,
};

const RoomParticipant = struct {
    id: i32,
    name: Text64 = .{},
    country: [2]u8 = .{ 'X', 'X' },
};

const MatchmakingRound = struct {
    round: u8,
    placement: u8 = 0,
    total_score: i64 = 0,
    accuracy: f64 = 0,
    max_combo: i32 = 0,
    passed: bool = false,
};

const MatchmakingUser = struct {
    id: i32,
    placement: ?u8 = null,
    points: i32 = 0,
    rounds: [matchmaking_rounds]?MatchmakingRound = [_]?MatchmakingRound{null} ** matchmaking_rounds,
};

const MatchmakingState = struct {
    stage: u8 = 0,
    current_round: u8 = 0,
    candidate_items: [max_users]i64 = [_]i64{0} ** max_users,
    candidate_count: usize = 0,
    candidate_item: i64 = 0,
    gameplay_item: i64 = 0,
    users: [max_users]?MatchmakingUser = [_]?MatchmakingUser{null} ** max_users,
    user_count: usize = 0,
    picks: [max_users]?i64 = [_]?i64{null} ** max_users,

    fn userIndex(self: *const MatchmakingState, user_id: i32) ?usize {
        for (self.users, 0..) |entry, index| if (entry) |user| if (user.id == user_id) return index;
        return null;
    }
};

const RankedCard = struct {
    id: Text64 = .{},
    playlist_item_id: i64,
};

const RankedDamage = struct {
    damage: i32 = 0,
    raw_damage: i32 = 0,
    old_life: i32 = 1_000_000,
    new_life: i32 = 1_000_000,
    direct_damage: i32 = 0,
    multiplier: f64 = 1,
    bonus_damage: i32 = 0,
};

const RankedUser = struct {
    id: i32,
    rating: i32 = 1500,
    life: i32 = 1_000_000,
    hand: [ranked_hand_size]?RankedCard = [_]?RankedCard{null} ** ranked_hand_size,
    hand_count: usize = 0,
    rating_after: i32 = 1500,
    damage: ?RankedDamage = null,
    rounds_won: i32 = 0,
    damage_multiplier: f64 = 0.5,
    total_score: i64 = 0,
    submitted: bool = false,
    discarded: bool = false,

    fn cardIndex(self: *const RankedUser, card_id: []const u8) ?usize {
        for (self.hand, 0..) |entry, index| if (entry) |card| if (std.mem.eql(u8, card.id.slice(), card_id)) return index;
        return null;
    }
};

const RankedPlayState = struct {
    stage: u8 = ranked_stage.wait_for_join,
    current_round: u16 = 0,
    damage_multiplier: f64 = 0.5,
    users: [ranked_player_count]?RankedUser = [_]?RankedUser{null} ** ranked_player_count,
    user_count: usize = 0,
    active_user_id: ?i32 = null,
    star_rating: f64 = 0,
    winning_user_id: ?i32 = null,
    deck: [max_ranked_cards]?RankedCard = [_]?RankedCard{null} ** max_ranked_cards,
    deck_count: usize = 0,
    deck_cursor: usize = 0,
    played_card: ?RankedCard = null,
    gameplay_item: i64 = 0,
    round_winner_id: ?i32 = null,
    pick_countdown: ?RankedStageCountdown = null,

    fn userIndex(self: *const RankedPlayState, user_id: i32) ?usize {
        for (self.users, 0..) |entry, index| if (entry) |user| if (user.id == user_id) return index;
        return null;
    }
};

const RankedStageCountdown = struct {
    id: i32,
    deadline_ms: i64,
    stage: u8,

    fn remainingTicks(self: RankedStageCountdown, now_ms: i64) i64 {
        return @max(0, self.deadline_ms - now_ms) * timespan_ticks_per_millisecond;
    }
};

const Settings = struct {
    name: Text128 = .{},
    playlist_item_id: i64 = 0,
    password: Text64 = .{},
    match_type: u8 = 1,
    queue_mode: u8 = 0,
    auto_start: Raw64 = .{},
    auto_skip: bool = false,
    max_participants: ?u8 = null,
};

const Room = struct {
    id: i64,
    state: u8 = 0,
    settings: Settings,
    users: [max_users]?RoomUser = [_]?RoomUser{null} ** max_users,
    user_count: usize = 0,
    host_id: i32,
    host_name: Text64 = .{},
    host_country: [2]u8 = .{ 'X', 'X' },
    playlist: [max_playlist]?PlaylistItem = [_]?PlaylistItem{null} ** max_playlist,
    playlist_count: usize = 0,
    channel_id: i32 = 4,
    matchmaking: ?MatchmakingState = null,
    ranked_play: ?RankedPlayState = null,
    allowed_users: [max_users]i32 = [_]i32{0} ** max_users,
    allowed_user_count: usize = 0,
    scores: [max_room_scores]?RoomScoreRecord = [_]?RoomScoreRecord{null} ** max_room_scores,
    score_count: usize = 0,
    score_cursor: usize = 0,
    participants: [max_room_participants]?RoomParticipant = [_]?RoomParticipant{null} ** max_room_participants,
    participant_count: usize = 0,
    ended: bool = false,

    fn userIndex(self: *const Room, user_id: i32) ?usize {
        for (self.users, 0..) |entry, index| if (entry) |user| if (user.id == user_id) return index;
        return null;
    }

    fn itemIndex(self: *const Room, item_id: i64) ?usize {
        for (self.playlist, 0..) |entry, index| if (entry) |item| if (item.id == item_id) return index;
        return null;
    }

    fn participantIndex(self: *const Room, user_id: i32) ?usize {
        for (self.participants[0..self.participant_count], 0..) |entry, index| if (entry) |user| if (user.id == user_id) return index;
        return null;
    }

    fn rememberParticipant(self: *Room, user: RoomUser) void {
        if (self.participantIndex(user.id)) |index| {
            self.participants[index] = .{ .id = user.id, .name = user.name, .country = user.country };
            return;
        }
        if (self.participant_count == self.participants.len) {
            for (1..self.participant_count) |index| self.participants[index - 1] = self.participants[index];
            self.participant_count -= 1;
        }
        self.participants[self.participant_count] = .{ .id = user.id, .name = user.name, .country = user.country };
        self.participant_count += 1;
    }

    fn userAllowed(self: *const Room, user_id: i32) bool {
        if (self.allowed_user_count == 0) return true;
        return std.mem.indexOfScalar(i32, self.allowed_users[0..self.allowed_user_count], user_id) != null;
    }
};

fn roomCategory(room: *const Room) []const u8 {
    return if (room.settings.match_type == 0) "normal" else "realtime";
}

const PendingMatch = struct {
    id: u32,
    pool_id: i32,
    users: [2]i32,
    joined: [2]bool = .{ true, true },
    accepted: [2]bool = .{ false, false },
    is_duel: bool = false,
    duel_id: Text64 = .{},
    created_at: i64,

    fn userIndex(self: PendingMatch, user_id: i32) ?usize {
        if (self.users[0] == user_id) return 0;
        if (self.users[1] == user_id) return 1;
        return null;
    }
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    references: std.atomic.Value(usize) = .init(1),
    user_id: i32,
    user_name: Text64 = .{},
    user_country: [2]u8,
    room_id: ?i64 = null,
    lobby_pool_id: ?i32 = null,
    queue_pool_id: ?i32 = null,
    pending_match_id: ?u32 = null,
    io: std.Io,
    write_mutex: std.Io.Mutex = .init,
    socket: ?*std.http.Server.WebSocket = null,
    alive: bool = true,

    fn retain(self: *Connection) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }

    fn release(self: *Connection) void {
        if (self.references.fetchSub(1, .release) == 1) {
            _ = self.references.load(.acquire);
            self.allocator.destroy(self);
        }
    }

    fn send(self: *Connection, frame: []const u8) void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (!self.alive) return;
        const socket = self.socket orelse return;
        socket.writeMessage(frame, .binary) catch {
            self.alive = false;
        };
    }

    fn close(self: *Connection) void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        self.alive = false;
        self.socket = null;
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: ?*storage.Store = null,
    map_sync: ?*beatmap_sync.Sync = null,
    mutex: std.Io.Mutex = .init,
    rooms: [max_rooms]?*Room = [_]?*Room{null} ** max_rooms,
    connections: std.ArrayList(*Connection) = .empty,
    matchmaking_maps: [4][max_matchmaking_maps]?storage.Store.MatchmakingBeatmap = [_][max_matchmaking_maps]?storage.Store.MatchmakingBeatmap{[_]?storage.Store.MatchmakingBeatmap{null} ** max_matchmaking_maps} ** 4,
    matchmaking_map_counts: [4]usize = [_]usize{0} ** 4,
    pending_matches: [max_rooms]?PendingMatch = [_]?PendingMatch{null} ** max_rooms,
    next_room_id: i64 = 1,
    next_pending_match_id: u32 = 1,
    next_countdown_id: i32 = 1,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Manager {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn bindStore(self: *Manager, store: *storage.Store) !void {
        self.store = store;
        self.next_room_id = @max(self.next_room_id, try store.nextLazerMultiplayerRoomId());
    }

    pub fn bindBeatmapSync(self: *Manager, sync: *beatmap_sync.Sync) void {
        self.map_sync = sync;
    }

    fn hydratePlaylistItem(self: *Manager, item: *PlaylistItem) !void {
        const store = self.store orelse return;
        var info_optional = try store.beatmapInfoById(self.allocator, item.beatmap_id);
        if (info_optional == null) if (self.map_sync) |sync| {
            _ = sync.ensureByBeatmapId(store, item.beatmap_id, null) catch |err|
                std.log.warn("event=lazer_multiplayer_beatmap_hydration_failed beatmap_id={d} error={t}", .{ item.beatmap_id, err });
            info_optional = try store.beatmapInfoById(self.allocator, item.beatmap_id);
        };
        const info = info_optional orelse return;
        defer self.allocator.free(info.artist);
        defer self.allocator.free(info.title);
        defer self.allocator.free(info.version);
        defer self.allocator.free(info.creator);
        item.beatmapset_id = info.set_id;
        item.artist.setText(info.artist);
        item.title.setText(info.title);
        item.version.setText(info.version);
        item.creator.setText(info.creator);
        item.status = info.status;
        item.star_rating = info.star_rating;
    }

    fn hydrateRoom(self: *Manager, room: *Room) !void {
        for (&room.playlist) |*entry| if (entry.*) |*item| try self.hydratePlaylistItem(item);
    }

    pub fn refreshMatchmakingMaps(self: *Manager) !void {
        const store = self.store orelse return error.MatchmakingStoreUnavailable;
        var loaded: [4][]storage.Store.MatchmakingBeatmap = undefined;
        var loaded_count: usize = 0;
        defer for (loaded[0..loaded_count]) |maps| self.allocator.free(maps);
        for (0..4) |mode| {
            loaded[mode] = try store.matchmakingBeatmaps(self.allocator, @intCast(mode), max_matchmaking_maps);
            loaded_count += 1;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (0..4) |mode| {
            self.matchmaking_maps[mode] = [_]?storage.Store.MatchmakingBeatmap{null} ** max_matchmaking_maps;
            self.matchmaking_map_counts[mode] = loaded[mode].len;
            for (loaded[mode], 0..) |map, index| self.matchmaking_maps[mode][index] = map;
        }
    }

    pub fn setMatchmakingMaps(self: *Manager, mode: u8, maps: []const storage.Store.MatchmakingBeatmap) !void {
        if (mode > 3 or maps.len == 0 or maps.len > max_matchmaking_maps) return error.InvalidMatchmakingPool;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.matchmaking_maps[mode] = [_]?storage.Store.MatchmakingBeatmap{null} ** max_matchmaking_maps;
        self.matchmaking_map_counts[mode] = maps.len;
        for (maps, 0..) |map, index| {
            if (map.mode != mode or map.id <= 0) return error.InvalidMatchmakingBeatmap;
            self.matchmaking_maps[mode][index] = map;
        }
    }

    pub fn deinit(self: *Manager) void {
        for (&self.rooms) |*entry| if (entry.*) |room| self.allocator.destroy(room);
        for (self.connections.items) |connection| connection.release();
        self.connections.deinit(self.allocator);
    }

    fn nowMs(self: *const Manager) i64 {
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }

    fn startRankedPickCountdownLocked(self: *Manager, ranked: *RankedPlayState, now_ms: i64) RankedStageCountdown {
        const countdown: RankedStageCountdown = .{
            .id = self.next_countdown_id,
            .deadline_ms = now_ms + ranked_pick_seconds * std.time.ms_per_s,
            .stage = ranked_stage.card_play,
        };
        self.next_countdown_id = if (self.next_countdown_id == std.math.maxInt(i32)) 1 else self.next_countdown_id + 1;
        ranked.pick_countdown = countdown;
        return countdown;
    }

    fn archiveRoom(self: *Manager, room: *Room) void {
        defer self.allocator.destroy(room);
        room.ended = true;
        const store = self.store orelse {
            std.log.warn("event=lazer_multiplayer_room_archive_failed room_id={d} error=store_unavailable", .{room.id});
            return;
        };
        var room_output: std.Io.Writer.Allocating = .init(self.allocator);
        defer room_output.deinit();
        writeRoomJson(&room_output.writer, room) catch |err| {
            std.log.warn("event=lazer_multiplayer_room_archive_failed room_id={d} error={t}", .{ room.id, err });
            return;
        };
        var leaderboard_output: std.Io.Writer.Allocating = .init(self.allocator);
        defer leaderboard_output.deinit();
        writeRoomLeaderboardJson(&leaderboard_output.writer, room, 0) catch |err| {
            std.log.warn("event=lazer_multiplayer_room_archive_failed room_id={d} error={t}", .{ room.id, err });
            return;
        };
        var participants_output: std.Io.Writer.Allocating = .init(self.allocator);
        defer participants_output.deinit();
        participants_output.writer.writeByte('[') catch return;
        for (room.participants[0..room.participant_count], 0..) |entry, index| if (entry) |participant| {
            if (index != 0) participants_output.writer.writeByte(',') catch return;
            participants_output.writer.print("{d}", .{participant.id}) catch return;
        };
        participants_output.writer.writeByte(']') catch return;
        const owner_id = if (room.participant_count != 0) room.participants[0].?.id else room.host_id;
        store.saveLazerMultiplayerRoomArchive(room.id, owner_id, roomCategory(room), room_output.written(), leaderboard_output.written(), participants_output.written()) catch |err| {
            std.log.warn("event=lazer_multiplayer_room_archive_failed room_id={d} error={t}", .{ room.id, err });
            return;
        };
        std.log.info("event=lazer_multiplayer_room_archived room_id={d} participants={d} scores={d}", .{ room.id, room.participant_count, room.score_count });
    }

    fn roomByIdLocked(self: *Manager, room_id: i64) ?*Room {
        for (self.rooms) |entry| if (entry) |room| if (room.id == room_id) return room;
        return null;
    }

    fn roomSlotLocked(self: *Manager) ?usize {
        for (self.rooms, 0..) |entry, index| if (entry == null) return index;
        return null;
    }

    fn connectionByUserLocked(self: *Manager, user_id: i32) ?*Connection {
        var found: ?*Connection = null;
        for (self.connections.items) |connection| {
            if (connection.alive and connection.user_id == user_id) found = connection;
        }
        return found;
    }

    pub fn activity(self: *Manager, user_id: i32) ?Activity {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const connection = self.connectionByUserLocked(user_id) orelse return null;
        if (connection.room_id) |room_id| {
            const room = self.roomByIdLocked(room_id) orelse return .multiplayer;
            return if (room.state == 1 or room.state == 2) .playing else .multiplayer;
        }
        if (connection.queue_pool_id != null or connection.pending_match_id != null) return .queue;
        if (connection.lobby_pool_id != null) return .lobby;
        return null;
    }

    pub fn disconnectUser(self: *Manager, user_id: i32) bool {
        var targets: [max_connections]*Connection = undefined;
        var count: usize = 0;
        self.mutex.lockUncancelable(self.io);
        for (self.connections.items) |connection| {
            if (!connection.alive or connection.user_id != user_id or count == targets.len) continue;
            connection.retain();
            targets[count] = connection;
            count += 1;
        }
        self.mutex.unlock(self.io);
        for (targets[0..count]) |connection| {
            connection.close();
            connection.release();
        }
        return count != 0;
    }

    pub fn restCreateRoom(self: *Manager, allocator: std.mem.Allocator, user: domain.User, body: []const u8) ![]u8 {
        const room = try parseRestRoom(self.allocator, user, body);
        errdefer self.allocator.destroy(room);
        try self.hydrateRoom(room);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.rooms) |entry| if (entry) |existing| if (existing.userIndex(user.id) != null) return error.AlreadyInMultiplayerRoom;
        const slot = self.roomSlotLocked() orelse return error.MultiplayerRoomLimit;
        room.id = self.next_room_id;
        self.next_room_id += 1;
        room.channel_id = 4;
        if (self.connectionByUserLocked(user.id)) |connection| connection.room_id = room.id;
        self.rooms[slot] = room;
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try writeRoomJson(&output.writer, room);
        std.log.info("event=lazer_multiplayer_rest_room_created room_id={d} host_id={d}", .{ room.id, user.id });
        return output.toOwnedSlice();
    }

    pub fn restJoinRoom(self: *Manager, allocator: std.mem.Allocator, user: domain.User, room_id: i64, password: []const u8) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.rooms) |entry| if (entry) |existing| if (existing.id != room_id and existing.userIndex(user.id) != null) return error.AlreadyInMultiplayerRoom;
        const room = self.roomByIdLocked(room_id) orelse return error.MultiplayerRoomNotFound;
        if (!std.mem.eql(u8, room.settings.password.slice(), password)) return error.InvalidMultiplayerPassword;
        if (!room.userAllowed(user.id)) return error.MultiplayerPermissionDenied;
        if (room.userIndex(user.id) == null) {
            const limit: usize = room.settings.max_participants orelse max_users;
            if (room.user_count >= limit) return error.MultiplayerRoomFull;
            const slot = for (room.users, 0..) |entry, index| {
                if (entry == null) break index;
            } else return error.MultiplayerRoomFull;
            room.users[slot] = try defaultRoomUser(user.id, user.name, user.country);
            room.user_count += 1;
            room.rememberParticipant(room.users[slot].?);
        }
        if (self.connectionByUserLocked(user.id)) |connection| connection.room_id = room_id;
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try writeRoomJson(&output.writer, room);
        std.log.info("event=lazer_multiplayer_rest_room_joined room_id={d} user_id={d}", .{ room_id, user.id });
        return output.toOwnedSlice();
    }

    pub fn restPartRoom(self: *Manager, user_id: i32, room_id: i64) !void {
        self.mutex.lockUncancelable(self.io);
        const room = self.roomByIdLocked(room_id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerRoomNotFound;
        };
        const index = room.userIndex(user_id) orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        room.users[index] = null;
        room.user_count -= 1;
        if (self.connectionByUserLocked(user_id)) |connection| if (connection.room_id == room_id) {
            connection.room_id = null;
        };
        var ended_room: ?*Room = null;
        if (room.user_count == 0) {
            for (&self.rooms) |*entry| if (entry.* == room) {
                entry.* = null;
                break;
            };
            ended_room = room;
        } else if (room.host_id == user_id) {
            for (room.users) |entry| if (entry) |next| {
                room.host_id = next.id;
                room.host_name = next.name;
                room.host_country = next.country;
                break;
            };
        }
        self.mutex.unlock(self.io);
        if (ended_room) |ended| self.archiveRoom(ended);
        std.log.info("event=lazer_multiplayer_rest_room_left room_id={d} user_id={d}", .{ room_id, user_id });
    }

    pub fn restCloseRoom(self: *Manager, user_id: i32, room_id: i64) !void {
        self.mutex.lockUncancelable(self.io);
        const room = self.roomByIdLocked(room_id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerRoomNotFound;
        };
        if (room.host_id != user_id) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        for (self.connections.items) |connection| {
            if (connection.room_id == room_id) connection.room_id = null;
        }
        for (&self.rooms) |*entry| if (entry.* == room) {
            entry.* = null;
            break;
        };
        self.mutex.unlock(self.io);
        self.archiveRoom(room);
        std.log.info("event=lazer_multiplayer_rest_room_closed room_id={d} user_id={d}", .{ room_id, user_id });
    }

    fn pendingMatchByIdLocked(self: *Manager, match_id: u32) ?*PendingMatch {
        for (&self.pending_matches) |*entry| if (entry.*) |*pending| if (pending.id == match_id) return pending;
        return null;
    }

    fn pendingMatchSlotLocked(self: *Manager) ?usize {
        for (self.pending_matches, 0..) |entry, index| if (entry == null) return index;
        return null;
    }

    fn pendingDuelByIdLocked(self: *Manager, duel_id: []const u8) ?*PendingMatch {
        for (&self.pending_matches) |*entry| if (entry.*) |*pending| {
            if (pending.is_duel and std.mem.eql(u8, pending.duel_id.slice(), duel_id)) return pending;
        };
        return null;
    }

    fn clearPendingMatchLocked(self: *Manager, match_id: u32) void {
        for (&self.pending_matches) |*entry| if (entry.*) |pending| if (pending.id == match_id) {
            entry.* = null;
            return;
        };
    }

    fn poolMode(pool_id: i32) ?u8 {
        if (pool_id >= 1 and pool_id <= 4) return @intCast(pool_id - 1);
        if (pool_id >= 101 and pool_id <= 104) return @intCast(pool_id - 101);
        return null;
    }

    fn poolType(pool_id: i32) ?u8 {
        if (pool_id >= 1 and pool_id <= 4) return 0;
        if (pool_id >= 101 and pool_id <= 104) return 1;
        return null;
    }

    fn recipientsLocked(self: *Manager, room_id: i64, exclude: ?*Connection, output: *[max_connections]*Connection) usize {
        var count: usize = 0;
        for (self.connections.items) |connection| {
            if (!connection.alive or connection == exclude or connection.room_id != room_id) continue;
            if (count == output.len) break;
            connection.retain();
            output[count] = connection;
            count += 1;
        }
        return count;
    }

    fn sendRecipients(recipients: []const *Connection, frame: []const u8) void {
        for (recipients) |connection| connection.send(frame);
    }

    fn releaseRecipients(recipients: []const *Connection) void {
        for (recipients) |connection| connection.release();
    }

    fn connect(self: *Manager, user: domain.User, socket: *std.http.Server.WebSocket) !*Connection {
        if (user.name.len == 0 or user.name.len > 64) return error.InvalidMultiplayerUser;
        const connection = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(connection);
        connection.* = .{
            .allocator = self.allocator,
            .user_id = user.id,
            .user_country = user.country,
            .io = self.io,
            .socket = socket,
        };
        try connection.user_name.set(user.name);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.connections.items.len >= max_connections) return error.MultiplayerConnectionLimit;
        try self.connections.append(self.allocator, connection);
        std.log.info("event=lazer_multiplayer_connected user_id={d}", .{user.id});
        return connection;
    }

    fn removeConnectionLocked(self: *Manager, connection: *Connection) void {
        const index = std.mem.indexOfScalar(*Connection, self.connections.items, connection) orelse return;
        _ = self.connections.swapRemove(index);
    }

    fn leaveLocked(self: *Manager, connection: *Connection, recipients: *[max_connections]*Connection, left_user: *?RoomUser, new_host: *?i32, ranked_ended: *bool, ended_room: *?*Room) usize {
        const room_id = connection.room_id orelse return 0;
        const room = self.roomByIdLocked(room_id) orelse {
            connection.room_id = null;
            return 0;
        };
        const user_index = room.userIndex(connection.user_id) orelse {
            connection.room_id = null;
            return 0;
        };
        left_user.* = room.users[user_index];
        if (room.ranked_play) |*ranked| if (ranked.stage != ranked_stage.ended) {
            if (ranked.userIndex(connection.user_id)) |ranked_user_index| ranked.users[ranked_user_index].?.life = 0;
            ranked.winning_user_id = rankedWinner(ranked);
            for (&ranked.users) |*entry| if (entry.*) |*ranked_user| if (ranked.winning_user_id) |winner_id| {
                const rating_delta: i32 = if (ranked_user.id == winner_id) 16 else -16;
                ranked_user.rating_after = ranked_user.rating + rating_delta;
            };
            ranked.stage = ranked_stage.ended;
            ranked.pick_countdown = null;
            ranked_ended.* = true;
        };
        room.users[user_index] = null;
        room.user_count -= 1;
        connection.room_id = null;
        if (room.user_count == 0) {
            for (&self.rooms) |*entry| if (entry.* == room) {
                entry.* = null;
                break;
            };
            ended_room.* = room;
            return 0;
        }
        if (room.host_id == connection.user_id) {
            for (room.users) |entry| if (entry) |user| {
                room.host_id = user.id;
                room.host_name = user.name;
                room.host_country = user.country;
                new_host.* = user.id;
                break;
            };
        }
        return self.recipientsLocked(room_id, connection, recipients);
    }

    fn disconnect(self: *Manager, connection: *Connection) void {
        connection.close();
        var recipients: [max_connections]*Connection = undefined;
        var left_user: ?RoomUser = null;
        var new_host: ?i32 = null;
        var ranked_ended = false;
        var ended_room: ?*Room = null;
        var ranked_event: ?[]u8 = null;
        defer if (ranked_event) |event| self.allocator.free(event);
        var queue_peer: ?*Connection = null;
        var queue_peer_left = false;
        var queue_pool_id: ?i32 = connection.queue_pool_id;
        self.mutex.lockUncancelable(self.io);
        if (connection.pending_match_id) |match_id| {
            if (self.pendingMatchByIdLocked(match_id)) |pending| {
                const index = pending.userIndex(connection.user_id) orelse 0;
                const peer_index = 1 - index;
                queue_pool_id = pending.pool_id;
                if (pending.joined[peer_index]) {
                    const peer_id = pending.users[peer_index];
                    if (self.connectionByUserLocked(peer_id)) |peer| {
                        peer.pending_match_id = null;
                        peer.queue_pool_id = if (pending.is_duel) null else pending.pool_id;
                        peer.retain();
                        queue_peer = peer;
                        queue_peer_left = pending.is_duel;
                    }
                }
            }
            self.clearPendingMatchLocked(match_id);
        }
        connection.pending_match_id = null;
        connection.queue_pool_id = null;
        connection.lobby_pool_id = null;
        const room_id = connection.room_id;
        const count = self.leaveLocked(connection, &recipients, &left_user, &new_host, &ranked_ended, &ended_room);
        if (ranked_ended) if (room_id) |id| if (self.roomByIdLocked(id)) |room| {
            ranked_event = eventMatchStateOwned(self.allocator, room) catch null;
        };
        defer releaseRecipients(recipients[0..count]);
        defer if (queue_peer) |peer| peer.release();
        self.removeConnectionLocked(connection);
        self.mutex.unlock(self.io);
        if (ended_room) |ended| self.archiveRoom(ended);
        std.log.info("event=lazer_multiplayer_disconnected user_id={d}", .{connection.user_id});
        if (queue_peer) |peer| {
            const frame_result = if (queue_peer_left)
                eventNoArgsOwned(self.allocator, "MatchmakingQueueLeft")
            else
                eventQueueStatusOwned(self.allocator, 0);
            if (frame_result) |frame| {
                defer self.allocator.free(frame);
                peer.send(frame);
            } else |_| {}
        }
        if (queue_pool_id) |pool| self.publishLobbyStatus(pool) catch {};
        if (left_user) |user| {
            if (eventUserOwned(self.allocator, "UserLeft", user)) |frame| {
                defer self.allocator.free(frame);
                sendRecipients(recipients[0..count], frame);
            } else |_| {}
        }
        if (ranked_event) |event| sendRecipients(recipients[0..count], event);
        connection.release();
        if (new_host) |host_id| {
            if (eventIntegersOwned(self.allocator, "HostChanged", &.{host_id})) |frame| {
                defer self.allocator.free(frame);
                sendRecipients(recipients[0..count], frame);
            } else |_| {}
        }
    }

    pub fn roomsJson(self: *Manager, allocator: std.mem.Allocator, only_room_id: ?i64, filter: ?RoomListFilter) !?[]u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        self.mutex.lockUncancelable(self.io);
        if (only_room_id) |room_id| {
            if (self.roomByIdLocked(room_id)) |room| {
                writeRoomJson(&output.writer, room) catch |err| {
                    self.mutex.unlock(self.io);
                    return err;
                };
                self.mutex.unlock(self.io);
                return try output.toOwnedSlice();
            }
            self.mutex.unlock(self.io);
            const store = self.store orelse return null;
            var archive = (try store.lazerMultiplayerRoomArchive(allocator, room_id)) orelse return null;
            defer archive.deinit();
            try output.writer.writeAll(archive.room_json);
            return try output.toOwnedSlice();
        }
        output.writer.writeByte('[') catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        var written: usize = 0;
        for (self.rooms) |entry| if (entry) |room| {
            if (filter) |value| {
                if (value.mode == .ended) continue;
                if (value.mode == .owned and room.host_id != value.requester_id) continue;
                if (value.mode == .participated and room.participantIndex(value.requester_id) == null) continue;
                if (value.status) |wanted| if ((wanted == .idle) != (room.state == 0)) continue;
                if (value.category.len != 0 and !std.mem.eql(u8, value.category, roomCategory(room))) continue;
            }
            if (written != 0) output.writer.writeByte(',') catch |err| {
                self.mutex.unlock(self.io);
                return err;
            };
            writeRoomJson(&output.writer, room) catch |err| {
                self.mutex.unlock(self.io);
                return err;
            };
            written += 1;
        };
        self.mutex.unlock(self.io);
        const include_archives = filter == null or filter.?.mode == .ended or filter.?.mode == .participated or filter.?.mode == .owned;
        if (include_archives) if (self.store) |store| {
            const archives = try store.lazerMultiplayerRoomArchives(allocator, 100);
            defer {
                for (archives) |*archive| archive.deinit();
                allocator.free(archives);
            }
            for (archives) |archive| {
                if (filter) |value| {
                    if (value.status != null) continue;
                    if (value.category.len != 0 and !std.mem.eql(u8, value.category, archive.category)) continue;
                    if (value.mode == .owned and archive.owner_id != value.requester_id) continue;
                    if (value.mode == .participated and !archiveIncludesUser(allocator, archive.participant_ids_json, value.requester_id)) continue;
                }
                if (written != 0) try output.writer.writeByte(',');
                try output.writer.writeAll(archive.room_json);
                written += 1;
            }
        };
        try output.writer.writeByte(']');
        return try output.toOwnedSlice();
    }

    pub fn scoreContext(self: *Manager, user_id: i32, room_id: i64, playlist_item_id: i64) ?RoomScoreContext {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const room = self.roomByIdLocked(room_id) orelse return null;
        if (room.userIndex(user_id) == null) return null;
        const item_index = room.itemIndex(playlist_item_id) orelse return null;
        const item = room.playlist[item_index].?;
        return .{ .beatmap_id = item.beatmap_id, .ruleset_id = item.ruleset_id };
    }

    pub fn roomScoreIds(self: *Manager, allocator: std.mem.Allocator, user_id: i32, room_id: i64, playlist_item_id: i64) !?[]i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const room = self.roomByIdLocked(room_id) orelse return null;
        if (room.userIndex(user_id) == null or room.itemIndex(playlist_item_id) == null) return null;
        var ids: std.ArrayList(i64) = .empty;
        errdefer ids.deinit(allocator);
        for (room.scores) |entry| if (entry) |score| if (score.playlist_item_id == playlist_item_id) try ids.append(allocator, score.score_id);
        return @as(?[]i64, try ids.toOwnedSlice(allocator));
    }

    pub fn roomScoreIdForUser(self: *Manager, requester_id: i32, room_id: i64, playlist_item_id: i64, user_id: i32) ?i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const room = self.roomByIdLocked(room_id) orelse return null;
        if (room.userIndex(requester_id) == null or room.itemIndex(playlist_item_id) == null) return null;
        var best: ?RoomScoreRecord = null;
        for (room.scores) |entry| if (entry) |score| if (score.playlist_item_id == playlist_item_id and score.user_id == user_id) {
            if (best == null or score.total_score > best.?.total_score or (score.total_score == best.?.total_score and score.score_id < best.?.score_id)) best = score;
        };
        return if (best) |score| score.score_id else null;
    }

    pub fn roomContainsScore(self: *Manager, requester_id: i32, room_id: i64, playlist_item_id: i64, score_id: i64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const room = self.roomByIdLocked(room_id) orelse return false;
        if (room.userIndex(requester_id) == null or room.itemIndex(playlist_item_id) == null) return false;
        for (room.scores) |entry| if (entry) |score| if (score.playlist_item_id == playlist_item_id and score.score_id == score_id) return true;
        return false;
    }

    pub fn roomLeaderboardJson(self: *Manager, allocator: std.mem.Allocator, requester_id: i32, room_id: i64) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        if (self.roomByIdLocked(room_id)) |room| {
            var output: std.Io.Writer.Allocating = .init(allocator);
            errdefer output.deinit();
            writeRoomLeaderboardJson(&output.writer, room, requester_id) catch |err| {
                self.mutex.unlock(self.io);
                return err;
            };
            self.mutex.unlock(self.io);
            return @as(?[]u8, try output.toOwnedSlice());
        }
        self.mutex.unlock(self.io);
        const store = self.store orelse return null;
        var archive = (try store.lazerMultiplayerRoomArchive(allocator, room_id)) orelse return null;
        defer archive.deinit();
        return @as(?[]u8, try allocator.dupe(u8, archive.leaderboard_json));
    }

    pub fn serve(self: *Manager, user: domain.User, socket: *std.http.Server.WebSocket) !void {
        const handshake = try socket.readSmallMessage();
        if ((handshake.opcode != .text and handshake.opcode != .binary) or !validSignalRHandshake(self.allocator, handshake.data)) return error.InvalidSignalRHandshake;
        // SignalR's handshake body is JSON even when the selected hub protocol
        // uses binary transfer. Match the negotiated WebSocket transfer format
        // instead of assuming the JSON bytes arrived in a text frame.
        try socket.writeMessage("{}\x1e", handshake.opcode);
        const connection = try self.connect(user, socket);
        defer self.disconnect(connection);
        while (connection.alive) {
            const message = socket.readSmallMessage() catch return;
            switch (message.opcode) {
                .ping => {
                    connection.write_mutex.lockUncancelable(connection.io);
                    defer connection.write_mutex.unlock(connection.io);
                    if (connection.alive) try socket.writeMessage(message.data, .pong);
                },
                .binary => try self.handleFrames(connection, message.data),
                else => {},
            }
        }
    }

    fn handleFrames(self: *Manager, connection: *Connection, data: []const u8) !void {
        var position: usize = 0;
        while (position < data.len) {
            var length: usize = 0;
            var shift: u6 = 0;
            var prefix_bytes: u8 = 0;
            while (true) {
                if (position >= data.len or prefix_bytes == 5) return error.InvalidSignalRFrame;
                const byte_value = data[position];
                position += 1;
                prefix_bytes += 1;
                length |= @as(usize, byte_value & 0x7f) << shift;
                if (byte_value & 0x80 == 0) break;
                shift += 7;
            }
            if (length == 0 or length > max_hub_message or position + length > data.len) return error.InvalidSignalRFrame;
            try self.handleHubMessage(connection, data[position .. position + length]);
            position += length;
        }
    }

    fn handleHubMessage(self: *Manager, connection: *Connection, payload: []const u8) !void {
        var reader: MessagePackReader = .{ .data = payload };
        const count = try reader.arrayLen();
        if (count == 0) return error.InvalidSignalRMessage;
        const message_type = try reader.integer();
        if (message_type == 6) {
            const ping = try pingOwned(self.allocator);
            defer self.allocator.free(ping);
            connection.send(ping);
            return;
        }
        if (message_type == 7) return error.ConnectionClose;
        if (message_type != 1 or count < 5) return;
        const header_count = try reader.mapLen();
        for (0..header_count * 2) |_| try reader.skip(0);
        const invocation_id: ?[]const u8 = if (reader.pos < reader.data.len and reader.data[reader.pos] == 0xc0) id: {
            reader.pos += 1;
            break :id null;
        } else try reader.string();
        const target = try reader.string();
        const argument_count = try reader.arrayLen();
        self.handleInvocation(connection, invocation_id, target, argument_count, &reader) catch |err| {
            std.log.warn("event=lazer_multiplayer_invocation_failed user_id={d} target={s} error={t}", .{ connection.user_id, target, err });
            if (invocation_id) |id| {
                const frame = completionErrorOwned(self.allocator, id, "multiplayer request was not accepted") catch return;
                defer self.allocator.free(frame);
                connection.send(frame);
            }
        };
    }

    fn finishVoid(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
        const id = invocation_id orelse return;
        const frame = try completionVoidOwned(self.allocator, id);
        defer self.allocator.free(frame);
        connection.send(frame);
    }

    fn handleInvocation(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, target: []const u8, argument_count: usize, reader: *MessagePackReader) !void {
        if (std.mem.eql(u8, target, "CreateRoom")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            const room_value = try reader.raw();
            return self.createRoom(connection, invocation_id, room_value);
        }
        if (std.mem.eql(u8, target, "JoinRoom") or std.mem.eql(u8, target, "JoinRoomWithPassword")) {
            if (argument_count < 1 or argument_count > 2) return error.InvalidMultiplayerArguments;
            const room_id = try reader.integer();
            const password = if (argument_count == 2) try reader.string() else "";
            return self.joinRoom(connection, invocation_id, room_id, password);
        }
        if (std.mem.eql(u8, target, "LeaveRoom")) return self.leaveRoom(connection, invocation_id);
        if (std.mem.eql(u8, target, "TransferHost")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.transferHost(connection, invocation_id, @intCast(try reader.integer()));
        }
        if (std.mem.eql(u8, target, "KickUser")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.kickUser(connection, invocation_id, @intCast(try reader.integer()));
        }
        if (std.mem.eql(u8, target, "ChangeSettings")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.changeSettings(connection, invocation_id, try reader.raw());
        }
        if (std.mem.eql(u8, target, "ChangeState")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.changeState(connection, invocation_id, @intCast(try reader.integer()));
        }
        if (std.mem.eql(u8, target, "ChangeBeatmapAvailability")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.changeAvailability(connection, invocation_id, try reader.raw());
        }
        if (std.mem.eql(u8, target, "ChangeUserStyle")) {
            if (argument_count != 2) return error.InvalidMultiplayerArguments;
            const beatmap_id = try reader.nullableInteger();
            const ruleset_id = try reader.nullableInteger();
            return self.changeStyle(connection, invocation_id, if (beatmap_id) |value| @intCast(value) else null, if (ruleset_id) |value| @intCast(value) else null);
        }
        if (std.mem.eql(u8, target, "ChangeUserMods")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.changeMods(connection, invocation_id, try reader.raw());
        }
        if (std.mem.eql(u8, target, "StartMatch")) return self.startMatch(connection, invocation_id);
        if (std.mem.eql(u8, target, "AbortMatch")) return self.abortMatch(connection, invocation_id);
        if (std.mem.eql(u8, target, "AbortGameplay")) return self.abortGameplay(connection, invocation_id);
        if (std.mem.eql(u8, target, "AddPlaylistItem")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.addPlaylistItem(connection, invocation_id, try reader.raw());
        }
        if (std.mem.eql(u8, target, "EditPlaylistItem")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.editPlaylistItem(connection, invocation_id, try reader.raw());
        }
        if (std.mem.eql(u8, target, "RemovePlaylistItem")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.removePlaylistItem(connection, invocation_id, try reader.integer());
        }
        if (std.mem.eql(u8, target, "VoteToSkipIntro")) return self.voteSkip(connection, invocation_id);
        if (std.mem.eql(u8, target, "InvitePlayer")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.invitePlayer(connection, invocation_id, @intCast(try reader.integer()));
        }
        if (std.mem.eql(u8, target, "SendMatchRequest")) {
            for (0..argument_count) |_| try reader.skip(0);
            return self.finishVoid(connection, invocation_id);
        }
        if (std.mem.eql(u8, target, "GetMatchmakingPools") or std.mem.eql(u8, target, "GetMatchmakingPoolsOfType")) {
            if (argument_count > 1) return error.InvalidMultiplayerArguments;
            const pool_type: u8 = if (argument_count == 1) @intCast(try reader.integer()) else 0;
            return self.getMatchmakingPools(connection, invocation_id, pool_type);
        }
        if (std.mem.eql(u8, target, "MatchmakingJoinLobby")) {
            if (argument_count != 0) return error.InvalidMultiplayerArguments;
            return self.joinMatchmakingLobby(connection, invocation_id, 1);
        }
        if (std.mem.eql(u8, target, "MatchmakingJoinLobbyWithParams")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            const request = try reader.raw();
            var request_reader: MessagePackReader = .{ .data = request };
            if (try request_reader.arrayLen() < 1) return error.InvalidMultiplayerArguments;
            return self.joinMatchmakingLobby(connection, invocation_id, @intCast(try request_reader.integer()));
        }
        if (std.mem.eql(u8, target, "MatchmakingLeaveLobby")) {
            if (argument_count != 0) return error.InvalidMultiplayerArguments;
            return self.leaveMatchmakingLobby(connection, invocation_id);
        }
        if (std.mem.eql(u8, target, "MatchmakingJoinQueue")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.joinMatchmakingQueue(connection, invocation_id, @intCast(try reader.integer()));
        }
        if (std.mem.eql(u8, target, "MatchmakingLeaveQueue")) {
            if (argument_count != 0) return error.InvalidMultiplayerArguments;
            return self.leaveMatchmakingQueue(connection, invocation_id, true);
        }
        if (std.mem.eql(u8, target, "MatchmakingAcceptInvitation")) {
            if (argument_count != 0) return error.InvalidMultiplayerArguments;
            return self.acceptMatchmakingInvitation(connection, invocation_id);
        }
        if (std.mem.eql(u8, target, "MatchmakingIssueDuel")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            const request = try reader.raw();
            var request_reader: MessagePackReader = .{ .data = request };
            if (try request_reader.arrayLen() != 2) return error.InvalidMultiplayerArguments;
            return self.issueMatchmakingDuel(
                connection,
                invocation_id,
                @intCast(try request_reader.integer()),
                @intCast(try request_reader.integer()),
            );
        }
        if (std.mem.eql(u8, target, "MatchmakingAcceptDuel")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            const request = try reader.raw();
            var request_reader: MessagePackReader = .{ .data = request };
            if (try request_reader.arrayLen() != 1) return error.InvalidMultiplayerArguments;
            return self.acceptMatchmakingDuel(connection, invocation_id, try request_reader.string());
        }
        if (std.mem.eql(u8, target, "MatchmakingDeclineInvitation")) {
            if (argument_count != 0) return error.InvalidMultiplayerArguments;
            return self.declineMatchmakingInvitation(connection, invocation_id);
        }
        if (std.mem.eql(u8, target, "MatchmakingToggleSelection")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.toggleMatchmakingSelection(connection, invocation_id, try reader.integer());
        }
        if (std.mem.eql(u8, target, "DiscardCards")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.discardRankedCards(connection, invocation_id, try reader.raw());
        }
        if (std.mem.eql(u8, target, "PlayCard")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.playRankedCard(connection, invocation_id, try reader.raw());
        }
        for (0..argument_count) |_| try reader.skip(0);
        return error.UnsupportedMultiplayerMethod;
    }

    fn createRoom(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded_room: []const u8) !void {
        const id = invocation_id orelse return error.MissingInvocationId;
        if (connection.room_id != null) return error.AlreadyInMultiplayerRoom;
        const room = try parseRoom(self.allocator, encoded_room, connection);
        errdefer self.allocator.destroy(room);
        try self.hydrateRoom(room);
        var response: []u8 = undefined;
        self.mutex.lockUncancelable(self.io);
        const slot = self.roomSlotLocked() orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerRoomLimit;
        };
        room.id = self.next_room_id;
        self.next_room_id += 1;
        room.channel_id = 4;
        connection.room_id = room.id;
        self.rooms[slot] = room;
        response = completionRoomOwned(self.allocator, id, room, self.nowMs()) catch |err| {
            self.rooms[slot] = null;
            connection.room_id = null;
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        defer self.allocator.free(response);
        connection.send(response);
        std.log.info("event=lazer_multiplayer_room_created room_id={d} host_id={d}", .{ room.id, connection.user_id });
    }

    fn joinRoom(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, room_id: i64, password: []const u8) !void {
        const id = invocation_id orelse return error.MissingInvocationId;
        var recipients: [max_connections]*Connection = undefined;
        var joined: RoomUser = undefined;
        var response: []u8 = undefined;
        var match_state_events: [2]?[]u8 = [_]?[]u8{null} ** 2;
        var match_state_event_count: usize = 0;
        var advanced_match = false;
        var advanced_ranked = false;
        var joined_ranked_user: ?RankedUser = null;
        var joined_ranked_playlist: [ranked_hand_size]?PlaylistItem = [_]?PlaylistItem{null} ** ranked_hand_size;
        defer for (match_state_events) |event| if (event) |frame| self.allocator.free(frame);
        self.mutex.lockUncancelable(self.io);
        if (connection.room_id != null) {
            self.mutex.unlock(self.io);
            return error.AlreadyInMultiplayerRoom;
        }
        const room = self.roomByIdLocked(room_id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerRoomNotFound;
        };
        if (!std.mem.eql(u8, room.settings.password.slice(), password)) {
            self.mutex.unlock(self.io);
            return error.InvalidMultiplayerPassword;
        }
        if (!room.userAllowed(connection.user_id)) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        const limit: usize = room.settings.max_participants orelse max_users;
        if (room.user_count >= limit) {
            self.mutex.unlock(self.io);
            return error.MultiplayerRoomFull;
        }
        const user_slot = for (room.users, 0..) |entry, index| {
            if (entry == null) break index;
        } else {
            self.mutex.unlock(self.io);
            return error.MultiplayerRoomFull;
        };
        joined = try defaultRoomUser(connection.user_id, connection.user_name.slice(), connection.user_country);
        room.users[user_slot] = joined;
        room.user_count += 1;
        connection.room_id = room_id;
        if (room.matchmaking) |*matchmaking| {
            if (matchmaking.stage == matchmaking_stage.waiting_for_clients_join and room.user_count == room.allowed_user_count) {
                matchmaking.current_round = 1;
                matchmaking.stage = matchmaking_stage.user_beatmap_select;
                advanced_match = true;
                match_state_events[0] = eventMatchStateOwned(self.allocator, room) catch |err| {
                    matchmaking.current_round = 0;
                    matchmaking.stage = matchmaking_stage.waiting_for_clients_join;
                    room.users[user_slot] = null;
                    room.user_count -= 1;
                    connection.room_id = null;
                    self.mutex.unlock(self.io);
                    return err;
                };
                match_state_event_count = 1;
            }
        }
        if (room.ranked_play) |*ranked| {
            const ranked_user_index = ranked.userIndex(connection.user_id) orelse {
                room.users[user_slot] = null;
                room.user_count -= 1;
                connection.room_id = null;
                self.mutex.unlock(self.io);
                return error.MultiplayerPermissionDenied;
            };
            joined_ranked_user = ranked.users[ranked_user_index].?;
            for (joined_ranked_user.?.hand, 0..) |card_entry, index| if (card_entry) |card| {
                const item_index = room.itemIndex(card.playlist_item_id) orelse continue;
                joined_ranked_playlist[index] = room.playlist[item_index].?;
            };
            if (ranked.stage == ranked_stage.wait_for_join and room.user_count == room.allowed_user_count) {
                ranked.stage = ranked_stage.round_warmup;
                ranked.current_round = 1;
                match_state_events[0] = eventMatchStateOwned(self.allocator, room) catch |err| {
                    ranked.stage = ranked_stage.wait_for_join;
                    ranked.current_round = 0;
                    room.users[user_slot] = null;
                    room.user_count -= 1;
                    connection.room_id = null;
                    self.mutex.unlock(self.io);
                    return err;
                };
                ranked.stage = ranked_stage.card_discard;
                match_state_events[1] = eventMatchStateOwned(self.allocator, room) catch |err| {
                    ranked.stage = ranked_stage.wait_for_join;
                    ranked.current_round = 0;
                    room.users[user_slot] = null;
                    room.user_count -= 1;
                    connection.room_id = null;
                    self.mutex.unlock(self.io);
                    return err;
                };
                match_state_event_count = 2;
                advanced_ranked = true;
            }
        }
        const count = self.recipientsLocked(room_id, connection, &recipients);
        defer releaseRecipients(recipients[0..count]);
        response = completionRoomOwned(self.allocator, id, room, self.nowMs()) catch |err| {
            if (advanced_match) {
                room.matchmaking.?.current_round = 0;
                room.matchmaking.?.stage = matchmaking_stage.waiting_for_clients_join;
            }
            if (advanced_ranked) {
                room.ranked_play.?.current_round = 0;
                room.ranked_play.?.stage = ranked_stage.wait_for_join;
            }
            room.users[user_slot] = null;
            room.user_count -= 1;
            connection.room_id = null;
            self.mutex.unlock(self.io);
            return err;
        };
        room.rememberParticipant(joined);
        self.mutex.unlock(self.io);
        defer self.allocator.free(response);
        connection.send(response);
        const event = try eventUserOwned(self.allocator, "UserJoined", joined);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        if (joined_ranked_user) |ranked_user| for (ranked_user.hand, 0..) |card_entry, index| if (card_entry) |card| if (joined_ranked_playlist[index]) |item| {
            const reveal = try eventRankedCardRevealedOwned(self.allocator, card, item);
            defer self.allocator.free(reveal);
            connection.send(reveal);
        };
        for (match_state_events[0..match_state_event_count]) |state_event| sendRecipients(recipients[0..count], state_event.?);
        std.log.info("event=lazer_multiplayer_room_joined room_id={d} user_id={d}", .{ room_id, connection.user_id });
    }

    fn leaveRoom(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
        var recipients: [max_connections]*Connection = undefined;
        var left_user: ?RoomUser = null;
        var new_host: ?i32 = null;
        var ranked_ended = false;
        var ended_room: ?*Room = null;
        var ranked_event: ?[]u8 = null;
        defer if (ranked_event) |event| self.allocator.free(event);
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id;
        const count = self.leaveLocked(connection, &recipients, &left_user, &new_host, &ranked_ended, &ended_room);
        if (ranked_ended) if (room_id) |id| if (self.roomByIdLocked(id)) |room| {
            ranked_event = try eventMatchStateOwned(self.allocator, room);
        };
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        if (ended_room) |ended| self.archiveRoom(ended);
        if (left_user) |user| {
            const event = try eventUserOwned(self.allocator, "UserLeft", user);
            defer self.allocator.free(event);
            sendRecipients(recipients[0..count], event);
        }
        if (new_host) |host_id| {
            const event = try eventIntegersOwned(self.allocator, "HostChanged", &.{host_id});
            defer self.allocator.free(event);
            sendRecipients(recipients[0..count], event);
        }
        if (ranked_event) |event| sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn transferHost(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, target_user_id: i32) !void {
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        if (room.host_id != connection.user_id or room.userIndex(target_user_id) == null) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        room.host_id = target_user_id;
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const event = try eventIntegersOwned(self.allocator, "HostChanged", &.{target_user_id});
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn kickUser(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, target_user_id: i32) !void {
        if (target_user_id == connection.user_id) return error.MultiplayerPermissionDenied;
        var recipients: [max_connections]*Connection = undefined;
        var target_connection: ?*Connection = null;
        var kicked: RoomUser = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        if (room.host_id != connection.user_id) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        const index = room.userIndex(target_user_id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerUserNotFound;
        };
        kicked = room.users[index].?;
        room.users[index] = null;
        room.user_count -= 1;
        for (self.connections.items) |candidate| if (candidate.user_id == target_user_id and candidate.room_id == room_id) {
            candidate.room_id = null;
            candidate.retain();
            target_connection = candidate;
            break;
        };
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        defer if (target_connection) |target| target.release();
        self.mutex.unlock(self.io);
        const event = try eventUserOwned(self.allocator, "UserKicked", kicked);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        if (target_connection) |target| {
            target.send(event);
        }
        try self.finishVoid(connection, invocation_id);
    }

    fn changeSettings(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
        var settings = try parseSettings(encoded);
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        if (room.host_id != connection.user_id) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        if (settings.playlist_item_id == 0 or room.itemIndex(settings.playlist_item_id) == null) settings.playlist_item_id = room.settings.playlist_item_id;
        room.settings = settings;
        for (&room.users) |*entry| {
            if (entry.*) |*user| {
                if (user.state == 1) user.state = 0;
            }
        }
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        const event = eventSettingsOwned(self.allocator, "SettingsChanged", room.settings) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn changeState(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, new_state: u8) !void {
        if (new_state > 8 or new_state == 2 or new_state == 5 or new_state == 7) return error.InvalidMultiplayerState;
        var recipients: [max_connections]*Connection = undefined;
        var start_players: [max_connections]*Connection = undefined;
        var start_count: usize = 0;
        var load_players: [max_connections]*Connection = undefined;
        var load_count: usize = 0;
        var server_user_updates: [max_users]struct { id: i32, state: u8 } = undefined;
        var server_user_update_count: usize = 0;
        var match_snapshots: [3]Room = undefined;
        var match_snapshot_count: usize = 0;
        var match_events: [3]?[]u8 = [_]?[]u8{null} ** 3;
        defer for (match_events) |event| if (event) |frame| self.allocator.free(frame);
        var playlist_event: ?[]u8 = null;
        defer if (playlist_event) |event| self.allocator.free(event);
        var results_ready = false;
        var ranked_removed_card: ?RankedCard = null;
        var ranked_removed_user: ?i32 = null;
        var ranked_added_card: ?RankedCard = null;
        var ranked_added_item: ?PlaylistItem = null;
        var ranked_added_user: ?i32 = null;
        var ranked_countdown_event: ?[]u8 = null;
        defer if (ranked_countdown_event) |event| self.allocator.free(event);
        var changed_room_state: ?i32 = null;
        var emitted_user_state: u8 = new_state;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const room_before = room.*;
        const user_index = room.userIndex(connection.user_id).?;
        const previous_user_state = room.users[user_index].?.state;
        room.users[user_index].?.state = if (room.state == 2 and previous_user_state == 5 and (new_state == 3 or new_state == 4)) 5 else new_state;
        if (new_state == 6) room.users[user_index].?.state = 7;
        emitted_user_state = room.users[user_index].?.state;
        const quick_waiting = room.matchmaking != null and room.matchmaking.?.stage == matchmaking_stage.waiting_for_beatmap_download;
        const ranked_waiting = room.ranked_play != null and room.ranked_play.?.stage == ranked_stage.finish_card_play;
        if ((quick_waiting or ranked_waiting) and new_state == 1) {
            var all_ready = room.user_count != 0;
            for (room.users) |entry| if (entry) |user| if (user.state != 1) {
                all_ready = false;
            };
            if (all_ready) {
                if (quick_waiting) room.matchmaking.?.stage = matchmaking_stage.gameplay_warmup else room.ranked_play.?.stage = ranked_stage.gameplay_warmup;
                match_snapshots[match_snapshot_count] = room.*;
                match_snapshot_count += 1;
                if (quick_waiting) room.matchmaking.?.stage = matchmaking_stage.gameplay else room.ranked_play.?.stage = ranked_stage.gameplay;
                match_snapshots[match_snapshot_count] = room.*;
                match_snapshot_count += 1;
                room.state = 1;
                changed_room_state = 1;
                for (&room.users) |*entry| if (entry.*) |*user| {
                    if (user.state != 1) continue;
                    user.state = 2;
                    server_user_updates[server_user_update_count] = .{ .id = user.id, .state = 2 };
                    server_user_update_count += 1;
                };
                for (self.connections.items) |candidate| if (candidate.room_id == room_id) {
                    const candidate_index = room.userIndex(candidate.user_id) orelse continue;
                    if (room.users[candidate_index].?.state == 2 and load_count < load_players.len) {
                        candidate.retain();
                        load_players[load_count] = candidate;
                        load_count += 1;
                    }
                };
            }
        } else if (room.state == 1 and (new_state == 3 or new_state == 4)) {
            var waiting = false;
            var gameplay_users: usize = 0;
            for (room.users) |entry| if (entry) |user| {
                if (user.state == 2) waiting = true;
                if (user.state >= 2 and user.state <= 4) gameplay_users += 1;
            };
            if (!waiting and gameplay_users != 0) {
                room.state = 2;
                for (&room.users) |*entry| {
                    if (entry.*) |*user| {
                        if (user.state == 3 or user.state == 4) {
                            user.state = 5;
                            server_user_updates[server_user_update_count] = .{ .id = user.id, .state = 5 };
                            server_user_update_count += 1;
                        }
                    }
                }
                changed_room_state = 2;
                for (self.connections.items) |candidate| if (candidate.room_id == room_id) {
                    const candidate_index = room.userIndex(candidate.user_id) orelse continue;
                    if (room.users[candidate_index].?.state == 5 and start_count < start_players.len) {
                        candidate.retain();
                        start_players[start_count] = candidate;
                        start_count += 1;
                    }
                };
            }
        } else if (new_state == 6) {
            var playing = false;
            for (room.users) |entry| {
                if (entry) |user| {
                    if (user.state == 5 or user.state == 6) playing = true;
                }
            }
            if (!playing) {
                room.state = 0;
                results_ready = true;
                changed_room_state = 0;
                if (room.matchmaking) |*matchmaking| {
                    if (matchmaking.gameplay_item != 0) if (room.itemIndex(matchmaking.gameplay_item)) |item_index| {
                        room.playlist[item_index].?.expired = true;
                        playlist_event = eventPlaylistOwned(self.allocator, "PlaylistItemChanged", room.playlist[item_index].?) catch |err| {
                            room.* = room_before;
                            self.mutex.unlock(self.io);
                            return err;
                        };
                    };
                    matchmaking.stage = matchmaking_stage.results;
                    match_snapshots[match_snapshot_count] = room.*;
                    match_snapshot_count += 1;
                } else if (room.ranked_play) |*ranked| {
                    if (ranked.active_user_id) |active_user_id| if (ranked.played_card) |played_card| {
                        if (ranked.userIndex(active_user_id)) |active_index| {
                            ranked_removed_card = rankedRemoveCard(&ranked.users[active_index].?, played_card.id.slice());
                            ranked_removed_user = active_user_id;
                        }
                    };
                    rankedFinishRound(ranked);
                    ranked.stage = ranked_stage.results;
                    match_snapshots[match_snapshot_count] = room.*;
                    match_snapshot_count += 1;
                }
            }
        } else if (new_state == 0 and room.matchmaking != null and room.matchmaking.?.stage == matchmaking_stage.results) {
            var all_idle = room.user_count != 0;
            for (room.users) |entry| if (entry) |user| if (user.state != 0) {
                all_idle = false;
            };
            if (all_idle) {
                if (room.matchmaking.?.current_round >= matchmaking_rounds) {
                    room.matchmaking.?.stage = matchmaking_stage.ended;
                    match_snapshots[match_snapshot_count] = room.*;
                    match_snapshot_count += 1;
                } else {
                    room.matchmaking.?.current_round += 1;
                    room.matchmaking.?.candidate_items = [_]i64{0} ** max_users;
                    room.matchmaking.?.candidate_count = 0;
                    room.matchmaking.?.candidate_item = 0;
                    room.matchmaking.?.gameplay_item = 0;
                    room.matchmaking.?.picks = [_]?i64{null} ** max_users;
                    room.matchmaking.?.stage = matchmaking_stage.round_warmup;
                    match_snapshots[match_snapshot_count] = room.*;
                    match_snapshot_count += 1;
                    room.matchmaking.?.stage = matchmaking_stage.user_beatmap_select;
                    match_snapshots[match_snapshot_count] = room.*;
                    match_snapshot_count += 1;
                }
            }
        } else if (new_state == 0 and room.ranked_play != null and room.ranked_play.?.stage == ranked_stage.results) {
            var all_idle = room.user_count != 0;
            for (room.users) |entry| if (entry) |user| {
                if (user.state != 0) all_idle = false;
            };
            if (all_idle) {
                const ranked = &room.ranked_play.?;
                if (ranked.round_winner_id) |winner_id| if (ranked.userIndex(winner_id)) |winner_index| {
                    ranked.users[winner_index].?.damage_multiplier += 0.5;
                };
                for (&ranked.users) |*entry| if (entry.*) |*user| {
                    user.damage = null;
                    user.total_score = 0;
                    user.submitted = false;
                    user.discarded = true;
                };
                ranked.played_card = null;
                ranked.gameplay_item = 0;
                if (!rankedHasRoundsRemaining(ranked)) {
                    ranked.winning_user_id = rankedWinner(ranked);
                    for (&ranked.users) |*entry| if (entry.*) |*user| {
                        if (ranked.winning_user_id) |winner_id| {
                            const rating_delta: i32 = if (user.id == winner_id) 16 else -16;
                            user.rating_after = user.rating + rating_delta;
                        }
                    };
                    ranked.stage = ranked_stage.ended;
                    match_snapshots[match_snapshot_count] = room.*;
                    match_snapshot_count += 1;
                } else {
                    ranked.current_round += 1;
                    ranked.damage_multiplier += 0.5;
                    if (ranked.active_user_id) |active_user_id| {
                        for (ranked.users) |entry| if (entry) |user| if (user.id != active_user_id and user.life > 0) {
                            ranked.active_user_id = user.id;
                            break;
                        };
                    }
                    if (ranked.active_user_id) |active_user_id| if (ranked.userIndex(active_user_id)) |active_index| {
                        ranked_added_card = rankedDrawCard(ranked, active_index);
                        if (ranked_added_card) |card| {
                            ranked_added_user = active_user_id;
                            if (room.itemIndex(card.playlist_item_id)) |item_index| ranked_added_item = room.playlist[item_index].?;
                        }
                    };
                    ranked.stage = ranked_stage.round_warmup;
                    match_snapshots[match_snapshot_count] = room.*;
                    match_snapshot_count += 1;
                    ranked.stage = ranked_stage.card_play;
                    _ = self.startRankedPickCountdownLocked(ranked, self.nowMs());
                    match_snapshots[match_snapshot_count] = room.*;
                    match_snapshot_count += 1;
                }
            }
        }
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        defer releaseRecipients(start_players[0..start_count]);
        defer releaseRecipients(load_players[0..load_count]);
        for (match_snapshots[0..match_snapshot_count], 0..) |*snapshot, index| {
            match_events[index] = eventMatchStateOwned(self.allocator, snapshot) catch |err| {
                room.* = room_before;
                self.mutex.unlock(self.io);
                return err;
            };
        }
        if (room.ranked_play) |ranked| if (ranked.pick_countdown) |countdown| {
            if (room_before.ranked_play == null or room_before.ranked_play.?.pick_countdown == null or room_before.ranked_play.?.pick_countdown.?.id != countdown.id) {
                ranked_countdown_event = eventRankedCountdownStartedOwned(self.allocator, countdown, self.nowMs()) catch |err| {
                    room.* = room_before;
                    self.mutex.unlock(self.io);
                    return err;
                };
            }
        };
        self.mutex.unlock(self.io);
        const user_state_event = try eventIntegersOwned(self.allocator, "UserStateChanged", &.{ connection.user_id, emitted_user_state });
        defer self.allocator.free(user_state_event);
        sendRecipients(recipients[0..count], user_state_event);
        for (match_events[0..match_snapshot_count]) |state_event| sendRecipients(recipients[0..count], state_event.?);
        if (ranked_countdown_event) |event| sendRecipients(recipients[0..count], event);
        for (server_user_updates[0..server_user_update_count]) |update| {
            const event = try eventIntegersOwned(self.allocator, "UserStateChanged", &.{ update.id, update.state });
            defer self.allocator.free(event);
            sendRecipients(recipients[0..count], event);
        }
        if (changed_room_state) |state| {
            const event = try eventIntegersOwned(self.allocator, "RoomStateChanged", &.{state});
            defer self.allocator.free(event);
            sendRecipients(recipients[0..count], event);
        }
        if (load_count != 0) {
            const event = try eventNoArgsOwned(self.allocator, "LoadRequested");
            defer self.allocator.free(event);
            sendRecipients(load_players[0..load_count], event);
        }
        if (start_count != 0) {
            const event = try eventNoArgsOwned(self.allocator, "GameplayStarted");
            defer self.allocator.free(event);
            sendRecipients(start_players[0..start_count], event);
        }
        if (playlist_event) |event| sendRecipients(recipients[0..count], event);
        if (ranked_removed_card) |card| if (ranked_removed_user) |user_id| {
            const event = try eventRankedCardUserOwned(self.allocator, "RankedPlayCardRemoved", user_id, card);
            defer self.allocator.free(event);
            sendRecipients(recipients[0..count], event);
        };
        if (ranked_added_card) |card| if (ranked_added_user) |user_id| {
            const event = try eventRankedCardUserOwned(self.allocator, "RankedPlayCardAdded", user_id, card);
            defer self.allocator.free(event);
            sendRecipients(recipients[0..count], event);
            if (ranked_added_item) |item| for (recipients[0..count]) |recipient| if (recipient.user_id == user_id) {
                const reveal = try eventRankedCardRevealedOwned(self.allocator, card, item);
                defer self.allocator.free(reveal);
                recipient.send(reveal);
                break;
            };
        };
        if (results_ready) {
            const event = try eventNoArgsOwned(self.allocator, "ResultsReady");
            defer self.allocator.free(event);
            sendRecipients(recipients[0..count], event);
        }
        try self.finishVoid(connection, invocation_id);
    }

    fn changeAvailability(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const index = room.userIndex(connection.user_id).?;
        room.users[index].?.availability.set(encoded) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const event = try eventIntegerRawOwned(self.allocator, "UserBeatmapAvailabilityChanged", connection.user_id, encoded);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn changeStyle(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, beatmap_id: ?i32, ruleset_id: ?i32) !void {
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const index = room.userIndex(connection.user_id).?;
        room.users[index].?.beatmap_id = beatmap_id;
        room.users[index].?.ruleset_id = ruleset_id;
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const event = try eventStyleOwned(self.allocator, connection.user_id, beatmap_id, ruleset_id);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn changeMods(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const index = room.userIndex(connection.user_id).?;
        room.users[index].?.mods.set(encoded) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const event = try eventIntegerRawOwned(self.allocator, "UserModsChanged", connection.user_id, encoded);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn startMatch(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
        var recipients: [max_connections]*Connection = undefined;
        var loaders: [max_connections]*Connection = undefined;
        var loader_count: usize = 0;
        var state_events: [max_users]?[]u8 = [_]?[]u8{null} ** max_users;
        defer for (&state_events) |*entry| if (entry.*) |event| self.allocator.free(event);
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        if (room.host_id != connection.user_id or room.state != 0) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        var ready_count: usize = 0;
        for (&room.users, 0..) |*entry, index| if (entry.*) |*user| {
            if (user.state == 1) {
                user.state = 2;
                state_events[index] = eventIntegersOwned(self.allocator, "UserStateChanged", &.{ user.id, 2 }) catch |err| {
                    self.mutex.unlock(self.io);
                    return err;
                };
                ready_count += 1;
            }
        };
        if (ready_count == 0) {
            self.mutex.unlock(self.io);
            return error.NoReadyMultiplayerPlayers;
        }
        room.state = 1;
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        for (self.connections.items) |candidate| if (candidate.room_id == room_id) {
            const index = room.userIndex(candidate.user_id) orelse continue;
            if (room.users[index].?.state == 2 and loader_count < loaders.len) {
                candidate.retain();
                loaders[loader_count] = candidate;
                loader_count += 1;
            }
        };
        self.mutex.unlock(self.io);
        defer releaseRecipients(loaders[0..loader_count]);
        const room_event = try eventIntegersOwned(self.allocator, "RoomStateChanged", &.{1});
        defer self.allocator.free(room_event);
        sendRecipients(recipients[0..count], room_event);
        for (state_events) |entry| if (entry) |event| sendRecipients(recipients[0..count], event);
        const load = try eventNoArgsOwned(self.allocator, "LoadRequested");
        defer self.allocator.free(load);
        sendRecipients(loaders[0..loader_count], load);
        try self.finishVoid(connection, invocation_id);
    }

    fn abortMatch(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        if (room.host_id != connection.user_id) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        room.state = 0;
        for (&room.users) |*entry| {
            if (entry.*) |*user| {
                if (user.state >= 2 and user.state <= 7) user.state = 0;
            }
        }
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const room_event = try eventIntegersOwned(self.allocator, "RoomStateChanged", &.{0});
        defer self.allocator.free(room_event);
        sendRecipients(recipients[0..count], room_event);
        const abort_event = try eventIntegersOwned(self.allocator, "GameplayAborted", &.{1});
        defer self.allocator.free(abort_event);
        sendRecipients(recipients[0..count], abort_event);
        try self.finishVoid(connection, invocation_id);
    }

    fn abortGameplay(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
        try self.changeState(connection, null, 0);
        const event = try eventIntegersOwned(self.allocator, "GameplayAborted", &.{0});
        defer self.allocator.free(event);
        connection.send(event);
        try self.finishVoid(connection, invocation_id);
    }

    fn addPlaylistItem(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
        var item = try parsePlaylistItem(encoded);
        try self.hydratePlaylistItem(&item);
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        if (room.settings.queue_mode == 0 and room.host_id != connection.user_id) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        const slot = for (room.playlist, 0..) |entry, index| if (entry == null) break index else {} else {
            self.mutex.unlock(self.io);
            return error.MultiplayerPlaylistFull;
        };
        item.id = 1;
        for (room.playlist) |entry| {
            if (entry) |existing| item.id = @max(item.id, existing.id + 1);
        }
        item.owner_id = connection.user_id;
        item.order = @intCast(room.playlist_count);
        room.playlist[slot] = item;
        room.playlist_count += 1;
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        const event = eventPlaylistOwned(self.allocator, "PlaylistItemAdded", item) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn editPlaylistItem(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
        var item = try parsePlaylistItem(encoded);
        try self.hydratePlaylistItem(&item);
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const index = room.itemIndex(item.id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerPlaylistItemNotFound;
        };
        if (room.host_id != connection.user_id and room.playlist[index].?.owner_id != connection.user_id) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        room.playlist[index] = item;
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        const event = eventPlaylistOwned(self.allocator, "PlaylistItemChanged", item) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn removePlaylistItem(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, item_id: i64) !void {
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const index = room.itemIndex(item_id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerPlaylistItemNotFound;
        };
        if (room.playlist_count <= 1 or room.settings.playlist_item_id == item_id or (room.host_id != connection.user_id and room.playlist[index].?.owner_id != connection.user_id)) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        room.playlist[index] = null;
        room.playlist_count -= 1;
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const event = try eventIntegersOwned(self.allocator, "PlaylistItemRemoved", &.{item_id});
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn voteSkip(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
        var recipients: [max_connections]*Connection = undefined;
        var passed = false;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const index = room.userIndex(connection.user_id).?;
        room.users[index].?.voted_skip = true;
        var playing: usize = 0;
        var votes: usize = 0;
        for (room.users) |entry| if (entry) |user| {
            if (user.state == 5) playing += 1;
            if (user.state == 5 and user.voted_skip) votes += 1;
        };
        passed = playing != 0 and votes >= playing / 2 + 1;
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const vote = try eventIntegerBoolOwned(self.allocator, "UserVotedToSkipIntro", connection.user_id, true);
        defer self.allocator.free(vote);
        sendRecipients(recipients[0..count], vote);
        if (passed) {
            const event = try eventNoArgsOwned(self.allocator, "VoteToSkipIntroPassed");
            defer self.allocator.free(event);
            sendRecipients(recipients[0..count], event);
        }
        try self.finishVoid(connection, invocation_id);
    }

    fn invitePlayer(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, user_id: i32) !void {
        var target: ?*Connection = null;
        var room_id: i64 = 0;
        var password: [64]u8 = undefined;
        var password_len: usize = 0;
        self.mutex.lockUncancelable(self.io);
        room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const password_slice = room.settings.password.slice();
        @memcpy(password[0..password_slice.len], password_slice);
        password_len = password_slice.len;
        for (self.connections.items) |candidate| if (candidate.user_id == user_id and candidate.room_id == null and candidate.alive) {
            candidate.retain();
            target = candidate;
            break;
        };
        defer if (target) |recipient| recipient.release();
        self.mutex.unlock(self.io);
        if (target) |recipient| {
            const event = try eventInviteOwned(self.allocator, connection.user_id, room_id, password[0..password_len]);
            defer self.allocator.free(event);
            recipient.send(event);
        }
        try self.finishVoid(connection, invocation_id);
    }

    fn getMatchmakingPools(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, pool_type: u8) !void {
        const id = invocation_id orelse return error.MissingInvocationId;
        if (pool_type > 1) return error.InvalidMatchmakingPool;
        if (self.store != null) self.refreshMatchmakingMaps() catch |err| {
            std.log.warn("event=lazer_matchmaking_pool_refresh_failed error={t}", .{err});
        };
        var available: [4]bool = [_]bool{false} ** 4;
        self.mutex.lockUncancelable(self.io);
        for (0..4) |mode| available[mode] = self.matchmaking_map_counts[mode] != 0;
        self.mutex.unlock(self.io);
        const frame = try completionMatchmakingPoolsOwned(self.allocator, id, pool_type, available);
        defer self.allocator.free(frame);
        connection.send(frame);
    }

    fn joinMatchmakingLobby(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, pool_id: i32) !void {
        const id = invocation_id orelse return error.MissingInvocationId;
        const mode = poolMode(pool_id) orelse return error.InvalidMatchmakingPool;
        self.mutex.lockUncancelable(self.io);
        if (self.matchmaking_map_counts[mode] == 0) {
            self.mutex.unlock(self.io);
            return error.MatchmakingPoolUnavailable;
        }
        connection.lobby_pool_id = pool_id;
        self.mutex.unlock(self.io);
        const response = try completionEmptyObjectOwned(self.allocator, id);
        defer self.allocator.free(response);
        connection.send(response);
        try self.publishLobbyStatus(pool_id);
    }

    fn leaveMatchmakingLobby(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
        self.mutex.lockUncancelable(self.io);
        connection.lobby_pool_id = null;
        self.mutex.unlock(self.io);
        try self.finishVoid(connection, invocation_id);
    }

    fn publishLobbyStatus(self: *Manager, pool_id: i32) !void {
        var recipients: [max_connections]*Connection = undefined;
        var recipient_count: usize = 0;
        var users: [max_connections]i32 = undefined;
        var user_count: usize = 0;
        self.mutex.lockUncancelable(self.io);
        for (self.connections.items) |candidate| {
            if (!candidate.alive) continue;
            if (candidate.lobby_pool_id == pool_id and recipient_count < recipients.len) {
                candidate.retain();
                recipients[recipient_count] = candidate;
                recipient_count += 1;
            }
            if (candidate.queue_pool_id == pool_id and user_count < users.len and std.mem.indexOfScalar(i32, users[0..user_count], candidate.user_id) == null) {
                users[user_count] = candidate.user_id;
                user_count += 1;
            }
        }
        self.mutex.unlock(self.io);
        defer releaseRecipients(recipients[0..recipient_count]);
        const frame = try eventLobbyStatusOwned(self.allocator, users[0..user_count]);
        defer self.allocator.free(frame);
        sendRecipients(recipients[0..recipient_count], frame);
    }

    fn issueMatchmakingDuel(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, target_user_id: i32, pool_id: i32) !void {
        const id = invocation_id orelse return error.MissingInvocationId;
        const mode = poolMode(pool_id) orelse return error.InvalidMatchmakingPool;
        const pool_type = poolType(pool_id) orelse return error.InvalidMatchmakingPool;
        if (target_user_id == connection.user_id) return error.InvalidMatchmakingDuelTarget;
        if (connection.room_id != null) return error.AlreadyInMultiplayerRoom;

        // osu!'s duel flow replaces any ordinary queue the challenger was in.
        try self.leaveMatchmakingQueue(connection, null, false);

        var random: [16]u8 = undefined;
        try self.io.randomSecure(&random);
        random[6] = (random[6] & 0x0f) | 0x40;
        random[8] = (random[8] & 0x3f) | 0x80;
        const hex = std.fmt.bytesToHex(random, .lower);
        var duel_id: [36]u8 = undefined;
        @memcpy(duel_id[0..8], hex[0..8]);
        duel_id[8] = '-';
        @memcpy(duel_id[9..13], hex[8..12]);
        duel_id[13] = '-';
        @memcpy(duel_id[14..18], hex[12..16]);
        duel_id[18] = '-';
        @memcpy(duel_id[19..23], hex[16..20]);
        duel_id[23] = '-';
        @memcpy(duel_id[24..36], hex[20..32]);

        const joined = try eventNoArgsOwned(self.allocator, "MatchmakingQueueJoined");
        defer self.allocator.free(joined);
        const searching = try eventQueueStatusOwned(self.allocator, 0);
        defer self.allocator.free(searching);
        const issued = try eventMatchmakingDuelIssuedOwned(self.allocator, &duel_id, connection.user_id, pool_id, mode, pool_type);
        defer self.allocator.free(issued);
        const response = try completionEmptyObjectOwned(self.allocator, id);
        defer self.allocator.free(response);

        var target: ?*Connection = null;
        self.mutex.lockUncancelable(self.io);
        if (connection.room_id != null or connection.queue_pool_id != null or connection.pending_match_id != null) {
            self.mutex.unlock(self.io);
            return error.AlreadyInMatchmakingQueue;
        }
        if (self.matchmaking_map_counts[mode] == 0) {
            self.mutex.unlock(self.io);
            return error.MatchmakingPoolUnavailable;
        }
        const recipient = self.connectionByUserLocked(target_user_id) orelse {
            self.mutex.unlock(self.io);
            return error.MatchmakingPlayerUnavailable;
        };
        if (recipient.room_id != null) {
            self.mutex.unlock(self.io);
            return error.MatchmakingPlayerUnavailable;
        }
        const slot = self.pendingMatchSlotLocked() orelse {
            self.mutex.unlock(self.io);
            return error.MatchmakingGroupLimit;
        };
        const match_id = self.next_pending_match_id;
        self.next_pending_match_id +%= 1;
        if (self.next_pending_match_id == 0) self.next_pending_match_id = 1;
        var pending: PendingMatch = .{
            .id = match_id,
            .pool_id = pool_id,
            .users = .{ connection.user_id, recipient.user_id },
            .joined = .{ true, false },
            .is_duel = true,
            .created_at = std.Io.Clock.real.now(self.io).toSeconds(),
        };
        pending.duel_id.set(&duel_id) catch unreachable;
        self.pending_matches[slot] = pending;
        connection.queue_pool_id = pool_id;
        connection.pending_match_id = match_id;
        recipient.retain();
        target = recipient;
        self.mutex.unlock(self.io);
        defer if (target) |recipient_connection| recipient_connection.release();

        connection.send(joined);
        connection.send(searching);
        target.?.send(issued);
        connection.send(response);
        std.log.info("event=lazer_matchmaking_duel_issued challenger_id={d} target_id={d} pool_id={d}", .{ connection.user_id, target_user_id, pool_id });
        try self.publishLobbyStatus(pool_id);
    }

    fn acceptMatchmakingDuel(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, duel_id: []const u8) !void {
        const id = invocation_id orelse return error.MissingInvocationId;
        if (duel_id.len != 36 or connection.room_id != null) return error.InvalidMatchmakingDuel;

        // Validate before removing the target from another queue. The duel may
        // have expired or been cancelled while its notification was visible.
        self.mutex.lockUncancelable(self.io);
        const initial = self.pendingDuelByIdLocked(duel_id) orelse {
            self.mutex.unlock(self.io);
            const response = try completionEmptyObjectOwned(self.allocator, id);
            defer self.allocator.free(response);
            connection.send(response);
            return;
        };
        if (initial.users[1] != connection.user_id or initial.joined[1]) {
            self.mutex.unlock(self.io);
            return error.InvalidMatchmakingDuel;
        }
        const pool_id = initial.pool_id;
        const pool_type = poolType(pool_id) orelse {
            self.mutex.unlock(self.io);
            return error.InvalidMatchmakingPool;
        };
        self.mutex.unlock(self.io);

        // Accepting a duel follows official behavior and replaces any other
        // queue membership held by the target.
        try self.leaveMatchmakingQueue(connection, null, false);

        const joined = try eventNoArgsOwned(self.allocator, "MatchmakingQueueJoined");
        defer self.allocator.free(joined);
        const searching = try eventQueueStatusOwned(self.allocator, 0);
        defer self.allocator.free(searching);
        const invited_legacy = try eventNoArgsOwned(self.allocator, "MatchmakingRoomInvited");
        defer self.allocator.free(invited_legacy);
        const invited = try eventMatchmakingInvitationOwned(self.allocator, pool_type);
        defer self.allocator.free(invited);
        const found = try eventQueueStatusOwned(self.allocator, 1);
        defer self.allocator.free(found);
        const response = try completionEmptyObjectOwned(self.allocator, id);
        defer self.allocator.free(response);

        var challenger: ?*Connection = null;
        self.mutex.lockUncancelable(self.io);
        const pending = self.pendingDuelByIdLocked(duel_id) orelse {
            self.mutex.unlock(self.io);
            connection.send(response);
            return;
        };
        if (pending.users[1] != connection.user_id or pending.joined[1] or connection.room_id != null or connection.queue_pool_id != null or connection.pending_match_id != null) {
            self.mutex.unlock(self.io);
            return error.InvalidMatchmakingDuel;
        }
        const challenger_connection = self.connectionByUserLocked(pending.users[0]) orelse {
            self.mutex.unlock(self.io);
            connection.send(response);
            return;
        };
        if (challenger_connection.pending_match_id != pending.id or challenger_connection.queue_pool_id != pending.pool_id) {
            self.mutex.unlock(self.io);
            connection.send(response);
            return;
        }
        pending.joined[1] = true;
        connection.queue_pool_id = pending.pool_id;
        connection.pending_match_id = pending.id;
        challenger_connection.retain();
        challenger = challenger_connection;
        self.mutex.unlock(self.io);
        defer if (challenger) |challenger_connection_retained| challenger_connection_retained.release();

        connection.send(joined);
        connection.send(searching);
        challenger.?.send(invited_legacy);
        connection.send(invited_legacy);
        challenger.?.send(invited);
        connection.send(invited);
        challenger.?.send(found);
        connection.send(found);
        connection.send(response);
        std.log.info("event=lazer_matchmaking_duel_accepted challenger_id={d} target_id={d} pool_id={d}", .{ challenger.?.user_id, connection.user_id, pool_id });
        try self.publishLobbyStatus(pool_id);
    }

    fn joinMatchmakingQueue(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, pool_id: i32) !void {
        const mode = poolMode(pool_id) orelse return error.InvalidMatchmakingPool;
        const pool_type = poolType(pool_id) orelse return error.InvalidMatchmakingPool;
        const joined = try eventNoArgsOwned(self.allocator, "MatchmakingQueueJoined");
        defer self.allocator.free(joined);
        const searching = try eventQueueStatusOwned(self.allocator, 0);
        defer self.allocator.free(searching);
        const invited_legacy = try eventNoArgsOwned(self.allocator, "MatchmakingRoomInvited");
        defer self.allocator.free(invited_legacy);
        const invited = try eventMatchmakingInvitationOwned(self.allocator, pool_type);
        defer self.allocator.free(invited);
        const found = try eventQueueStatusOwned(self.allocator, 1);
        defer self.allocator.free(found);
        var peer: ?*Connection = null;
        self.mutex.lockUncancelable(self.io);
        if (connection.room_id != null or connection.queue_pool_id != null or connection.pending_match_id != null) {
            self.mutex.unlock(self.io);
            return error.AlreadyInMatchmakingQueue;
        }
        if (self.matchmaking_map_counts[mode] == 0) {
            self.mutex.unlock(self.io);
            return error.MatchmakingPoolUnavailable;
        }
        connection.queue_pool_id = pool_id;
        for (self.connections.items) |candidate| {
            if (candidate == connection or candidate.user_id == connection.user_id or !candidate.alive or candidate.room_id != null or candidate.queue_pool_id != pool_id or candidate.pending_match_id != null) continue;
            peer = candidate;
            break;
        }
        if (peer) |matched| {
            const slot = self.pendingMatchSlotLocked() orelse {
                self.mutex.unlock(self.io);
                return error.MatchmakingGroupLimit;
            };
            const match_id = self.next_pending_match_id;
            self.next_pending_match_id +%= 1;
            if (self.next_pending_match_id == 0) self.next_pending_match_id = 1;
            self.pending_matches[slot] = .{
                .id = match_id,
                .pool_id = pool_id,
                .users = .{ matched.user_id, connection.user_id },
                .created_at = std.Io.Clock.real.now(self.io).toSeconds(),
            };
            matched.pending_match_id = match_id;
            connection.pending_match_id = match_id;
            matched.retain();
        }
        self.mutex.unlock(self.io);
        defer if (peer) |matched| matched.release();
        connection.send(joined);
        connection.send(searching);
        if (peer) |matched| {
            matched.send(invited_legacy);
            connection.send(invited_legacy);
            matched.send(invited);
            connection.send(invited);
            matched.send(found);
            connection.send(found);
            std.log.info("event=lazer_matchmaking_group_formed pool_id={d} users={d},{d}", .{ pool_id, matched.user_id, connection.user_id });
        }
        try self.finishVoid(connection, invocation_id);
        try self.publishLobbyStatus(pool_id);
    }

    fn leaveMatchmakingQueue(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, notify: bool) !void {
        const left = try eventNoArgsOwned(self.allocator, "MatchmakingQueueLeft");
        defer self.allocator.free(left);
        const searching = try eventQueueStatusOwned(self.allocator, 0);
        defer self.allocator.free(searching);
        var peer: ?*Connection = null;
        var peer_left = false;
        var pool_id: ?i32 = null;
        var was_queued = false;
        self.mutex.lockUncancelable(self.io);
        pool_id = connection.queue_pool_id;
        was_queued = pool_id != null or connection.pending_match_id != null;
        if (connection.pending_match_id) |match_id| {
            if (self.pendingMatchByIdLocked(match_id)) |pending| {
                pool_id = pending.pool_id;
                const index = pending.userIndex(connection.user_id) orelse 0;
                const peer_index = 1 - index;
                if (pending.joined[peer_index]) {
                    const peer_id = pending.users[peer_index];
                    if (self.connectionByUserLocked(peer_id)) |matched| {
                        matched.pending_match_id = null;
                        matched.queue_pool_id = if (pending.is_duel) null else pending.pool_id;
                        matched.retain();
                        peer = matched;
                        peer_left = pending.is_duel;
                    }
                }
            }
            self.clearPendingMatchLocked(match_id);
        }
        connection.pending_match_id = null;
        connection.queue_pool_id = null;
        self.mutex.unlock(self.io);
        defer if (peer) |matched| matched.release();
        if (notify and was_queued) connection.send(left);
        if (peer) |matched| matched.send(if (peer_left) left else searching);
        try self.finishVoid(connection, invocation_id);
        if (pool_id) |pool| try self.publishLobbyStatus(pool);
    }

    fn declineMatchmakingInvitation(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
        if (connection.pending_match_id == null) return error.NoPendingMatchmakingInvitation;
        return self.leaveMatchmakingQueue(connection, invocation_id, true);
    }

    fn createMatchmakingRoomLocked(self: *Manager, pending: PendingMatch, password: []const u8) !*Room {
        const mode = poolMode(pending.pool_id) orelse return error.InvalidMatchmakingPool;
        const pool_type = poolType(pending.pool_id) orelse return error.InvalidMatchmakingPool;
        const map_count = self.matchmaking_map_counts[mode];
        if (map_count == 0) return error.MatchmakingPoolUnavailable;
        const room = try self.allocator.create(Room);
        errdefer self.allocator.destroy(room);
        room.* = .{
            .id = self.next_room_id,
            .settings = .{},
            .host_id = 3,
            .host_country = .{ 'I', 'S' },
            .allowed_user_count = pending.users.len,
            .matchmaking = if (pool_type == 0) .{} else null,
            .ranked_play = if (pool_type == 1) .{} else null,
        };
        self.next_room_id += 1;
        try room.host_name.set("kai");
        const mode_names = [_][]const u8{ "osu!", "osu!taiko", "osu!catch", "osu!mania" };
        var name_buf: [96]u8 = undefined;
        const room_name = try std.fmt.bufPrint(&name_buf, "zigcho {s} - {s}", .{ if (pool_type == 0) "quick play" else "ranked play", mode_names[mode] });
        try room.settings.name.set(room_name);
        try room.settings.password.set(password);
        room.settings.match_type = if (pool_type == 0) 3 else 4;
        room.settings.queue_mode = 0;
        room.settings.max_participants = pending.users.len;
        room.settings.auto_start.bytes[0] = 0;
        room.settings.auto_start.len = 1;
        room.allowed_users[0] = pending.users[0];
        room.allowed_users[1] = pending.users[1];
        for (pending.users, 0..) |user_id, index| if (pool_type == 0) {
            room.matchmaking.?.users[index] = .{ .id = user_id };
            room.matchmaking.?.user_count += 1;
        } else {
            room.ranked_play.?.users[index] = .{ .id = user_id };
            room.ranked_play.?.user_count += 1;
        };
        for (0..map_count) |index| {
            const map = self.matchmaking_maps[mode][index].?;
            var item: PlaylistItem = .{
                .id = @intCast(index + 1),
                .owner_id = 3,
                .beatmap_id = map.id,
                .ruleset_id = map.mode,
                .order = @intCast(index),
                .star_rating = map.stars,
            };
            try item.checksum.set(&map.md5);
            try self.hydratePlaylistItem(&item);
            item.required_mods.bytes[0] = 0x90;
            item.required_mods.len = 1;
            item.allowed_mods.bytes[0] = 0x90;
            item.allowed_mods.len = 1;
            item.played_at.bytes[0] = 0xc0;
            item.played_at.len = 1;
            room.playlist[index] = item;
            room.playlist_count += 1;
        }
        room.settings.playlist_item_id = room.playlist[0].?.id;
        if (room.ranked_play) |*ranked| {
            ranked.active_user_id = pending.users[0];
            var star_total: f64 = 0;
            for (0..map_count) |index| star_total += room.playlist[index].?.star_rating;
            ranked.star_rating = star_total / @as(f64, @floatFromInt(map_count));
            const card_count = @min(max_ranked_cards, @max(ranked_hand_size * ranked_player_count + ranked_player_count, map_count * 2));
            for (0..card_count) |index| {
                var card: RankedCard = .{ .playlist_item_id = room.playlist[index % map_count].?.id };
                var guid_buf: [64]u8 = undefined;
                const room_bits: u32 = @truncate(@as(u64, @intCast(room.id)));
                const guid = try std.fmt.bufPrint(&guid_buf, "{x:0>8}-0000-4000-8000-{x:0>12}", .{ room_bits, @as(u64, @intCast(index + 1)) });
                try card.id.set(guid);
                ranked.deck[index] = card;
                ranked.deck_count += 1;
            }
            for (0..ranked_player_count) |user_index| for (0..ranked_hand_size) |_| {
                _ = rankedDrawCard(ranked, user_index);
            };
        }
        return room;
    }

    fn acceptMatchmakingInvitation(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
        var random: [16]u8 = undefined;
        try self.io.randomSecure(&random);
        const password = std.fmt.bytesToHex(random, .lower);
        const joining = try eventQueueStatusOwned(self.allocator, 2);
        defer self.allocator.free(joining);
        var ready: [2]*Connection = undefined;
        var ready_count: usize = 0;
        var room_id: ?i64 = null;
        var pool_id: ?i32 = null;
        self.mutex.lockUncancelable(self.io);
        const match_id = connection.pending_match_id orelse {
            self.mutex.unlock(self.io);
            return error.NoPendingMatchmakingInvitation;
        };
        const pending = self.pendingMatchByIdLocked(match_id) orelse {
            connection.pending_match_id = null;
            self.mutex.unlock(self.io);
            return error.NoPendingMatchmakingInvitation;
        };
        const user_index = pending.userIndex(connection.user_id) orelse {
            self.mutex.unlock(self.io);
            return error.NoPendingMatchmakingInvitation;
        };
        pending.accepted[user_index] = true;
        pool_id = pending.pool_id;
        if (pending.accepted[0] and pending.accepted[1]) {
            var matched_connections: [2]*Connection = undefined;
            for (pending.users, 0..) |user_id, index| {
                matched_connections[index] = self.connectionByUserLocked(user_id) orelse {
                    pending.accepted[user_index] = false;
                    self.mutex.unlock(self.io);
                    return error.MatchmakingPlayerUnavailable;
                };
            }
            const room_slot = self.roomSlotLocked() orelse {
                pending.accepted[user_index] = false;
                self.mutex.unlock(self.io);
                return error.MultiplayerRoomLimit;
            };
            const room = self.createMatchmakingRoomLocked(pending.*, &password) catch |err| {
                pending.accepted[user_index] = false;
                self.mutex.unlock(self.io);
                return err;
            };
            self.rooms[room_slot] = room;
            room_id = room.id;
            for (matched_connections) |matched| {
                matched.pending_match_id = null;
                matched.queue_pool_id = null;
                matched.retain();
                ready[ready_count] = matched;
                ready_count += 1;
            }
            self.clearPendingMatchLocked(match_id);
        }
        self.mutex.unlock(self.io);
        defer releaseRecipients(ready[0..ready_count]);
        connection.send(joining);
        if (room_id) |created_room_id| {
            const event = try eventMatchmakingRoomReadyOwned(self.allocator, created_room_id, &password);
            defer self.allocator.free(event);
            sendRecipients(ready[0..ready_count], event);
            std.log.info("event=lazer_matchmaking_room_ready room_id={d} players={d}", .{ created_room_id, ready_count });
        }
        try self.finishVoid(connection, invocation_id);
        if (pool_id) |pool| try self.publishLobbyStatus(pool);
    }

    fn toggleMatchmakingSelection(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, playlist_item_id: i64) !void {
        var random_bytes: [8]u8 = undefined;
        try self.io.randomSecure(&random_bytes);
        const random_value = std.mem.readInt(u64, &random_bytes, .little);
        var recipients: [max_connections]*Connection = undefined;
        var previous: ?i64 = null;
        var advanced = false;
        var finalised_event: ?[]u8 = null;
        var settings_event: ?[]u8 = null;
        var download_event: ?[]u8 = null;
        defer if (finalised_event) |event| self.allocator.free(event);
        defer if (settings_event) |event| self.allocator.free(event);
        defer if (download_event) |event| self.allocator.free(event);
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        if (room.matchmaking == null or room.matchmaking.?.stage != matchmaking_stage.user_beatmap_select) {
            self.mutex.unlock(self.io);
            return error.InvalidMatchmakingStage;
        }
        if (playlist_item_id != -1) {
            const item_index = room.itemIndex(playlist_item_id) orelse {
                self.mutex.unlock(self.io);
                return error.MultiplayerPlaylistItemNotFound;
            };
            if (room.playlist[item_index].?.expired) {
                self.mutex.unlock(self.io);
                return error.MultiplayerPlaylistItemExpired;
            }
        }
        const match_user_index = room.matchmaking.?.userIndex(connection.user_id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        };
        previous = room.matchmaking.?.picks[match_user_index];
        if (previous == playlist_item_id) {
            self.mutex.unlock(self.io);
            return self.finishVoid(connection, invocation_id);
        }
        room.matchmaking.?.picks[match_user_index] = playlist_item_id;
        var all_picked = room.user_count != 0;
        for (room.users) |entry| if (entry) |user| {
            const index = room.matchmaking.?.userIndex(user.id) orelse continue;
            if (room.matchmaking.?.picks[index] == null) all_picked = false;
        };
        if (all_picked) {
            const previous_matchmaking = room.matchmaking.?;
            const previous_settings = room.settings;
            room.matchmaking.?.candidate_count = 0;
            for (room.matchmaking.?.picks) |pick_entry| if (pick_entry) |pick| {
                if (std.mem.indexOfScalar(i64, room.matchmaking.?.candidate_items[0..room.matchmaking.?.candidate_count], pick) == null) {
                    room.matchmaking.?.candidate_items[room.matchmaking.?.candidate_count] = pick;
                    room.matchmaking.?.candidate_count += 1;
                }
            };
            const candidate_index: usize = @intCast(random_value % room.matchmaking.?.candidate_count);
            room.matchmaking.?.candidate_item = room.matchmaking.?.candidate_items[candidate_index];
            room.matchmaking.?.gameplay_item = if (room.matchmaking.?.candidate_item == -1) random: {
                var active_items: [max_playlist]i64 = undefined;
                var active_count: usize = 0;
                for (room.playlist) |entry| if (entry) |item| if (!item.expired) {
                    active_items[active_count] = item.id;
                    active_count += 1;
                };
                if (active_count == 0) {
                    room.matchmaking = previous_matchmaking;
                    self.mutex.unlock(self.io);
                    return error.MatchmakingPoolUnavailable;
                }
                const active_index: usize = @intCast((random_value / room.matchmaking.?.candidate_count) % active_count);
                break :random active_items[active_index];
            } else room.matchmaking.?.candidate_item;
            room.matchmaking.?.stage = matchmaking_stage.server_beatmap_finalised;
            finalised_event = eventMatchStateOwned(self.allocator, room) catch |err| {
                room.matchmaking = previous_matchmaking;
                self.mutex.unlock(self.io);
                return err;
            };
            room.settings.playlist_item_id = room.matchmaking.?.gameplay_item;
            settings_event = eventSettingsOwned(self.allocator, "SettingsChanged", room.settings) catch |err| {
                room.matchmaking = previous_matchmaking;
                room.settings = previous_settings;
                self.mutex.unlock(self.io);
                return err;
            };
            room.matchmaking.?.stage = matchmaking_stage.waiting_for_beatmap_download;
            download_event = eventMatchStateOwned(self.allocator, room) catch |err| {
                room.matchmaking = previous_matchmaking;
                room.settings = previous_settings;
                self.mutex.unlock(self.io);
                return err;
            };
            advanced = true;
        }
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        if (previous) |old| {
            const event = try eventIntegersOwned(self.allocator, "MatchmakingItemDeselected", &.{ connection.user_id, old });
            defer self.allocator.free(event);
            sendRecipients(recipients[0..count], event);
        }
        const selected_event = try eventIntegersOwned(self.allocator, "MatchmakingItemSelected", &.{ connection.user_id, playlist_item_id });
        defer self.allocator.free(selected_event);
        sendRecipients(recipients[0..count], selected_event);
        if (advanced) {
            sendRecipients(recipients[0..count], finalised_event.?);
            sendRecipients(recipients[0..count], settings_event.?);
            sendRecipients(recipients[0..count], download_event.?);
        }
        try self.finishVoid(connection, invocation_id);
    }

    fn discardRankedCards(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
        var card_ids: [ranked_hand_size][]const u8 = undefined;
        const requested_count = try parseRankedCardList(encoded, &card_ids);
        var removed: [ranked_hand_size]?RankedCard = [_]?RankedCard{null} ** ranked_hand_size;
        var added: [ranked_hand_size]?RankedCard = [_]?RankedCard{null} ** ranked_hand_size;
        var added_items: [ranked_hand_size]?PlaylistItem = [_]?PlaylistItem{null} ** ranked_hand_size;
        var added_count: usize = 0;
        var snapshots: [3]Room = undefined;
        var snapshot_count: usize = 0;
        var recipients: [max_connections]*Connection = undefined;
        var countdown_started: ?RankedStageCountdown = null;
        var countdown_event: ?[]u8 = null;
        defer if (countdown_event) |event| self.allocator.free(event);
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const room_before = room.*;
        if (room.ranked_play == null) {
            self.mutex.unlock(self.io);
            return error.InvalidRankedPlayStage;
        }
        const ranked = &room.ranked_play.?;
        if (ranked.stage != ranked_stage.card_discard) {
            self.mutex.unlock(self.io);
            return error.InvalidRankedPlayStage;
        }
        const user_index = ranked.userIndex(connection.user_id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        };
        const user = &ranked.users[user_index].?;
        if (user.discarded) {
            self.mutex.unlock(self.io);
            return error.RankedPlayCardsAlreadyDiscarded;
        }
        for (card_ids[0..requested_count]) |card_id| if (user.cardIndex(card_id) == null) {
            self.mutex.unlock(self.io);
            return error.InvalidRankedPlayCard;
        };
        for (card_ids[0..requested_count], 0..) |card_id, index| removed[index] = rankedRemoveCard(user, card_id).?;
        for (0..requested_count) |_| if (rankedDrawCard(ranked, user_index)) |card| {
            added[added_count] = card;
            const item_index = room.itemIndex(card.playlist_item_id).?;
            added_items[added_count] = room.playlist[item_index].?;
            added_count += 1;
        };
        user.discarded = true;
        snapshots[snapshot_count] = room.*;
        snapshot_count += 1;
        var all_discarded = true;
        for (ranked.users) |entry| if (entry) |candidate| {
            if (!candidate.discarded) all_discarded = false;
        };
        if (all_discarded) {
            ranked.stage = ranked_stage.finish_card_discard;
            snapshots[snapshot_count] = room.*;
            snapshot_count += 1;
            ranked.stage = ranked_stage.card_play;
            countdown_started = self.startRankedPickCountdownLocked(ranked, self.nowMs());
            snapshots[snapshot_count] = room.*;
            snapshot_count += 1;
        }
        const recipient_count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..recipient_count]);
        if (countdown_started) |countdown| countdown_event = eventRankedCountdownStartedOwned(self.allocator, countdown, self.nowMs()) catch |err| {
            room.* = room_before;
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        for (removed[0..requested_count]) |entry| if (entry) |card| {
            const event = try eventRankedCardUserOwned(self.allocator, "RankedPlayCardRemoved", connection.user_id, card);
            defer self.allocator.free(event);
            sendRecipients(recipients[0..recipient_count], event);
        };
        for (added[0..added_count], 0..) |entry, index| if (entry) |card| {
            const added_event = try eventRankedCardUserOwned(self.allocator, "RankedPlayCardAdded", connection.user_id, card);
            defer self.allocator.free(added_event);
            sendRecipients(recipients[0..recipient_count], added_event);
            const reveal_event = try eventRankedCardRevealedOwned(self.allocator, card, added_items[index].?);
            defer self.allocator.free(reveal_event);
            connection.send(reveal_event);
        };
        for (snapshots[0..snapshot_count]) |*snapshot| {
            const state_event = try eventMatchStateOwned(self.allocator, snapshot);
            defer self.allocator.free(state_event);
            sendRecipients(recipients[0..recipient_count], state_event);
        }
        if (countdown_event) |event| sendRecipients(recipients[0..recipient_count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn playRankedCard(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
        const card_id = try parseRankedCardId(encoded);
        var recipients: [max_connections]*Connection = undefined;
        var card: RankedCard = undefined;
        var item: PlaylistItem = undefined;
        var settings: Settings = undefined;
        var snapshot: Room = undefined;
        var countdown_stopped_event: ?[]u8 = null;
        defer if (countdown_stopped_event) |event| self.allocator.free(event);
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const room_before = room.*;
        if (room.ranked_play == null) {
            self.mutex.unlock(self.io);
            return error.InvalidRankedPlayStage;
        }
        const ranked = &room.ranked_play.?;
        if (ranked.stage != ranked_stage.card_play or ranked.active_user_id != connection.user_id or ranked.played_card != null) {
            self.mutex.unlock(self.io);
            return error.InvalidRankedPlayStage;
        }
        const user_index = ranked.userIndex(connection.user_id).?;
        const hand_index = ranked.users[user_index].?.cardIndex(card_id) orelse {
            self.mutex.unlock(self.io);
            return error.InvalidRankedPlayCard;
        };
        card = ranked.users[user_index].?.hand[hand_index].?;
        const item_index = room.itemIndex(card.playlist_item_id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerPlaylistItemNotFound;
        };
        item = room.playlist[item_index].?;
        ranked.played_card = card;
        ranked.gameplay_item = card.playlist_item_id;
        room.settings.playlist_item_id = card.playlist_item_id;
        ranked.stage = ranked_stage.finish_card_play;
        const countdown_id = if (ranked.pick_countdown) |countdown| countdown.id else null;
        ranked.pick_countdown = null;
        settings = room.settings;
        snapshot = room.*;
        const recipient_count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..recipient_count]);
        if (countdown_id) |id| countdown_stopped_event = eventRankedCountdownStoppedOwned(self.allocator, id) catch |err| {
            room.* = room_before;
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        if (countdown_stopped_event) |event| sendRecipients(recipients[0..recipient_count], event);
        const reveal_event = try eventRankedCardRevealedOwned(self.allocator, card, item);
        defer self.allocator.free(reveal_event);
        sendRecipients(recipients[0..recipient_count], reveal_event);
        const played_event = try eventRankedCardPlayedOwned(self.allocator, card);
        defer self.allocator.free(played_event);
        sendRecipients(recipients[0..recipient_count], played_event);
        const settings_event = try eventSettingsOwned(self.allocator, "SettingsChanged", settings);
        defer self.allocator.free(settings_event);
        sendRecipients(recipients[0..recipient_count], settings_event);
        const state_event = try eventMatchStateOwned(self.allocator, &snapshot);
        defer self.allocator.free(state_event);
        sendRecipients(recipients[0..recipient_count], state_event);
        try self.finishVoid(connection, invocation_id);
    }

    pub fn advanceExpiredRankedPicks(self: *Manager, now_ms: i64) !usize {
        var advanced: usize = 0;
        while (true) {
            var recipients: [max_connections]*Connection = undefined;
            var recipient_count: usize = 0;
            var frames: [5]?[]u8 = [_]?[]u8{null} ** 5;
            defer for (frames) |frame| if (frame) |owned| self.allocator.free(owned);
            var room_id: i64 = 0;
            var active_user_id: i32 = 0;

            self.mutex.lockUncancelable(self.io);
            const room = expired: {
                for (self.rooms) |entry| if (entry) |candidate| {
                    if (candidate.ranked_play) |ranked| {
                        const countdown = ranked.pick_countdown orelse continue;
                        if (ranked.stage == ranked_stage.card_play and ranked.played_card == null and countdown.deadline_ms <= now_ms) break :expired candidate;
                    }
                };
                self.mutex.unlock(self.io);
                return advanced;
            };
            const room_before = room.*;
            const ranked = &room.ranked_play.?;
            const countdown = ranked.pick_countdown.?;
            var user_index = if (ranked.active_user_id) |id| ranked.userIndex(id) else null;
            if (user_index == null or ranked.users[user_index.?].?.hand_count == 0) {
                user_index = null;
                for (ranked.users, 0..) |entry, index| if (entry) |user| if (user.life > 0 and user.hand_count != 0) {
                    user_index = index;
                    ranked.active_user_id = user.id;
                    break;
                };
            }
            const selected_user_index = user_index orelse {
                ranked.pick_countdown = null;
                ranked.winning_user_id = rankedWinner(ranked);
                ranked.stage = ranked_stage.ended;
                room_id = room.id;
                recipient_count = self.recipientsLocked(room.id, null, &recipients);
                frames[0] = eventRankedCountdownStoppedOwned(self.allocator, countdown.id) catch |err| {
                    room.* = room_before;
                    self.mutex.unlock(self.io);
                    releaseRecipients(recipients[0..recipient_count]);
                    return err;
                };
                frames[1] = eventMatchStateOwned(self.allocator, room) catch |err| {
                    room.* = room_before;
                    self.mutex.unlock(self.io);
                    releaseRecipients(recipients[0..recipient_count]);
                    return err;
                };
                self.mutex.unlock(self.io);
                defer releaseRecipients(recipients[0..recipient_count]);
                sendRecipients(recipients[0..recipient_count], frames[0].?);
                sendRecipients(recipients[0..recipient_count], frames[1].?);
                std.log.warn("event=lazer_ranked_pick_ended room_id={d} error=no_playable_card", .{room_id});
                advanced += 1;
                continue;
            };
            const card = for (ranked.users[selected_user_index].?.hand) |entry| {
                if (entry) |value| break value;
            } else unreachable;
            const item_index = room.itemIndex(card.playlist_item_id) orelse {
                self.mutex.unlock(self.io);
                return error.MultiplayerPlaylistItemNotFound;
            };
            const item = room.playlist[item_index].?;
            active_user_id = ranked.users[selected_user_index].?.id;
            room_id = room.id;
            ranked.played_card = card;
            ranked.gameplay_item = card.playlist_item_id;
            ranked.pick_countdown = null;
            ranked.stage = ranked_stage.finish_card_play;
            room.settings.playlist_item_id = card.playlist_item_id;
            const settings = room.settings;
            const snapshot = room.*;
            recipient_count = self.recipientsLocked(room.id, null, &recipients);

            frames[0] = eventRankedCountdownStoppedOwned(self.allocator, countdown.id) catch |err| {
                room.* = room_before;
                self.mutex.unlock(self.io);
                releaseRecipients(recipients[0..recipient_count]);
                return err;
            };
            frames[1] = eventRankedCardRevealedOwned(self.allocator, card, item) catch |err| {
                room.* = room_before;
                self.mutex.unlock(self.io);
                releaseRecipients(recipients[0..recipient_count]);
                return err;
            };
            frames[2] = eventRankedCardPlayedOwned(self.allocator, card) catch |err| {
                room.* = room_before;
                self.mutex.unlock(self.io);
                releaseRecipients(recipients[0..recipient_count]);
                return err;
            };
            frames[3] = eventSettingsOwned(self.allocator, "SettingsChanged", settings) catch |err| {
                room.* = room_before;
                self.mutex.unlock(self.io);
                releaseRecipients(recipients[0..recipient_count]);
                return err;
            };
            frames[4] = eventMatchStateOwned(self.allocator, &snapshot) catch |err| {
                room.* = room_before;
                self.mutex.unlock(self.io);
                releaseRecipients(recipients[0..recipient_count]);
                return err;
            };
            self.mutex.unlock(self.io);
            defer releaseRecipients(recipients[0..recipient_count]);
            for (frames) |frame| sendRecipients(recipients[0..recipient_count], frame.?);
            std.log.info("event=lazer_ranked_pick_timed_out room_id={d} user_id={d} card_id={s}", .{ room_id, active_user_id, card.id.slice() });
            advanced += 1;
        }
    }

    pub fn recordRoomScore(self: *Manager, user_id: i32, room_id: i64, playlist_item_id: i64, score: RoomScoreResult) !void {
        var recipients: [max_connections]*Connection = undefined;
        var state_event: ?[]u8 = null;
        defer if (state_event) |event| self.allocator.free(event);
        self.mutex.lockUncancelable(self.io);
        const room = self.roomByIdLocked(room_id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerRoomNotFound;
        };
        if (room.userIndex(user_id) == null or room.itemIndex(playlist_item_id) == null) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        const record: RoomScoreRecord = .{
            .score_id = score.score_id,
            .user_id = user_id,
            .playlist_item_id = playlist_item_id,
            .total_score = score.total_score,
            .accuracy = score.accuracy,
            .max_combo = score.max_combo,
            .passed = score.passed,
        };
        if (room.score_count < room.scores.len) {
            room.scores[room.score_count] = record;
            room.score_count += 1;
        } else {
            room.scores[room.score_cursor] = record;
            room.score_cursor = (room.score_cursor + 1) % room.scores.len;
        }
        if (room.ranked_play) |*ranked| {
            if (ranked.gameplay_item != playlist_item_id or ranked.current_round == 0) {
                self.mutex.unlock(self.io);
                return;
            }
            const user_index = ranked.userIndex(user_id) orelse {
                self.mutex.unlock(self.io);
                return error.MultiplayerPermissionDenied;
            };
            ranked.users[user_index].?.total_score = score.total_score;
            ranked.users[user_index].?.submitted = true;
            const count = self.recipientsLocked(room_id, null, &recipients);
            defer releaseRecipients(recipients[0..count]);
            state_event = eventMatchStateOwned(self.allocator, room) catch |err| {
                self.mutex.unlock(self.io);
                return err;
            };
            self.mutex.unlock(self.io);
            sendRecipients(recipients[0..count], state_event.?);
            return;
        }
        if (room.matchmaking == null or room.matchmaking.?.gameplay_item != playlist_item_id or room.matchmaking.?.current_round == 0) {
            self.mutex.unlock(self.io);
            return;
        }
        const user_index = room.matchmaking.?.userIndex(user_id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        };
        const round_index = room.matchmaking.?.current_round - 1;
        room.matchmaking.?.users[user_index].?.rounds[round_index] = .{
            .round = room.matchmaking.?.current_round,
            .total_score = score.total_score,
            .accuracy = score.accuracy,
            .max_combo = score.max_combo,
            .passed = score.passed,
        };
        recomputeMatchmakingPlacements(&room.matchmaking.?);
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        state_event = eventMatchStateOwned(self.allocator, room) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        sendRecipients(recipients[0..count], state_event.?);
    }
};

fn defaultRoomUser(user_id: i32, name: []const u8, country: [2]u8) !RoomUser {
    var user: RoomUser = .{ .id = user_id };
    try user.name.set(name);
    user.country = country;
    user.availability.bytes[0] = 0x92;
    user.availability.bytes[1] = 0x00;
    user.availability.bytes[2] = 0xc0;
    user.availability.len = 3;
    user.mods.bytes[0] = 0x90;
    user.mods.len = 1;
    return user;
}

fn jsonString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (object.get(key) orelse return error.InvalidMultiplayerRoom) {
        .string => |value| value,
        else => error.InvalidMultiplayerRoom,
    };
}

fn jsonOptionalString(object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    return switch (object.get(key) orelse return null) {
        .null => null,
        .string => |value| value,
        else => error.InvalidMultiplayerRoom,
    };
}

fn beatmapStatusValue(value: std.json.Value) !i8 {
    return switch (value) {
        .integer => |status| std.math.cast(i8, status) orelse error.InvalidMultiplayerRoom,
        .string => |status| if (std.mem.eql(u8, status, "graveyard")) 0 else if (std.mem.eql(u8, status, "wip")) 1 else if (std.mem.eql(u8, status, "pending")) 2 else if (std.mem.eql(u8, status, "ranked")) 3 else if (std.mem.eql(u8, status, "approved")) 4 else if (std.mem.eql(u8, status, "qualified")) 5 else if (std.mem.eql(u8, status, "loved")) 6 else return error.InvalidMultiplayerRoom,
        else => error.InvalidMultiplayerRoom,
    };
}

fn jsonOptionalInteger(object: std.json.ObjectMap, key: []const u8) !?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .integer => |integer| integer,
        else => error.InvalidMultiplayerRoom,
    };
}

fn jsonOptionalBool(object: std.json.ObjectMap, key: []const u8, default: bool) !bool {
    const value = object.get(key) orelse return default;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidMultiplayerRoom,
    };
}

fn jsonNumber(value: std.json.Value) !f64 {
    const number: f64 = switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return error.InvalidMultiplayerRoom,
    };
    if (!std.math.isFinite(number)) return error.InvalidMultiplayerRoom;
    return number;
}

fn jsonValueMessagePack(pack: MessagePackWriter, value: std.json.Value, depth: u8) !void {
    if (depth >= 12) return error.InvalidMultiplayerRoom;
    switch (value) {
        .null => try pack.nil(),
        .bool => |boolean| try pack.boolean(boolean),
        .integer => |integer| try pack.integer(integer),
        .float => |float| try pack.float64(float),
        .number_string => return error.InvalidMultiplayerRoom,
        .string => |string| try pack.string(string),
        .array => |array| {
            if (array.items.len > 64) return error.InvalidMultiplayerRoom;
            try pack.array(array.items.len);
            for (array.items) |item| try jsonValueMessagePack(pack, item, depth + 1);
        },
        .object => |object| {
            if (object.count() > 32) return error.InvalidMultiplayerRoom;
            try pack.map(object.count());
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try pack.string(entry.key_ptr.*);
                try jsonValueMessagePack(pack, entry.value_ptr.*, depth + 1);
            }
        },
    }
}

fn setJsonMessagePack(comptime capacity: usize, destination: *FixedRaw(capacity), value: std.json.Value, allocator: std.mem.Allocator) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try jsonValueMessagePack(.{ .writer = &output.writer }, value, 0);
    try destination.set(output.written());
}

fn parseRestRoom(allocator: std.mem.Allocator, user: domain.User, body: []const u8) !*Room {
    if (body.len == 0 or body.len > 128 * 1024) return error.InvalidMultiplayerRoom;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidMultiplayerRoom;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidMultiplayerRoom,
    };
    const name = try jsonString(object, "name");
    if (name.len == 0 or name.len > 128 or !std.unicode.utf8ValidateSlice(name) or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidMultiplayerRoom;
    const password = if (object.get("password")) |value| switch (value) {
        .null => "",
        .string => |string| string,
        else => return error.InvalidMultiplayerRoom,
    } else "";
    if (password.len > 64 or !std.unicode.utf8ValidateSlice(password) or std.mem.indexOfScalar(u8, password, 0) != null) return error.InvalidMultiplayerRoom;
    const match_type_text = try jsonString(object, "type");
    const match_type: u8 = if (std.mem.eql(u8, match_type_text, "playlists"))
        0
    else if (std.mem.eql(u8, match_type_text, "head_to_head"))
        1
    else if (std.mem.eql(u8, match_type_text, "team_versus"))
        2
    else
        return error.InvalidMultiplayerRoom;
    const queue_mode_text = if (object.get("queue_mode")) |value| switch (value) {
        .string => |string| string,
        else => return error.InvalidMultiplayerRoom,
    } else "host_only";
    const queue_mode: u8 = if (std.mem.eql(u8, queue_mode_text, "host_only"))
        0
    else if (std.mem.eql(u8, queue_mode_text, "all_players"))
        1
    else if (std.mem.eql(u8, queue_mode_text, "all_players_round_robin"))
        2
    else
        return error.InvalidMultiplayerRoom;
    const max_participants_raw = try jsonOptionalInteger(object, "max_participants");
    const max_participants: ?u8 = if (max_participants_raw) |value| blk: {
        if (value < 1 or value > max_users) return error.InvalidMultiplayerRoom;
        break :blk @intCast(value);
    } else null;
    const auto_start_raw = try jsonOptionalInteger(object, "auto_start_duration");
    const auto_start: i64 = auto_start_raw orelse 0;
    if (auto_start < 0 or auto_start > std.math.maxInt(u16)) return error.InvalidMultiplayerRoom;
    const playlist_value = object.get("playlist") orelse return error.InvalidMultiplayerRoom;
    const playlist = switch (playlist_value) {
        .array => |value| value,
        else => return error.InvalidMultiplayerRoom,
    };
    if (playlist.items.len == 0 or playlist.items.len > max_playlist) return error.InvalidMultiplayerRoom;

    const room = try allocator.create(Room);
    errdefer allocator.destroy(room);
    room.* = .{ .id = 0, .settings = .{}, .host_id = user.id, .host_country = user.country };
    try room.settings.name.set(name);
    try room.settings.password.set(password);
    room.settings.match_type = match_type;
    room.settings.queue_mode = queue_mode;
    room.settings.auto_skip = try jsonOptionalBool(object, "auto_skip", false);
    room.settings.max_participants = max_participants;
    var auto_start_output: std.Io.Writer.Allocating = .init(allocator);
    defer auto_start_output.deinit();
    try (MessagePackWriter{ .writer = &auto_start_output.writer }).integer(auto_start);
    try room.settings.auto_start.set(auto_start_output.written());
    try room.host_name.set(user.name);
    room.users[0] = try defaultRoomUser(user.id, user.name, user.country);
    room.user_count = 1;
    room.rememberParticipant(room.users[0].?);

    for (playlist.items, 0..) |entry, index| {
        const item_object = switch (entry) {
            .object => |value| value,
            else => return error.InvalidMultiplayerRoom,
        };
        const beatmap_id_raw = try jsonOptionalInteger(item_object, "beatmap_id") orelse return error.InvalidMultiplayerRoom;
        const ruleset_id_raw = try jsonOptionalInteger(item_object, "ruleset_id") orelse return error.InvalidMultiplayerRoom;
        if (beatmap_id_raw <= 0 or beatmap_id_raw > std.math.maxInt(i32) or ruleset_id_raw < 0 or ruleset_id_raw > 3) return error.InvalidMultiplayerRoom;
        const item_id_raw = (try jsonOptionalInteger(item_object, "id")) orelse @as(i64, @intCast(index + 1));
        if (item_id_raw <= 0) return error.InvalidMultiplayerRoom;
        for (room.playlist[0..index]) |previous| if (previous) |item| if (item.id == item_id_raw) return error.InvalidMultiplayerRoom;
        const owner_id_raw = (try jsonOptionalInteger(item_object, "owner_id")) orelse user.id;
        if (owner_id_raw < 0 or owner_id_raw > std.math.maxInt(i32)) return error.InvalidMultiplayerRoom;
        const owner_id: i32 = if (owner_id_raw == 0) user.id else @intCast(owner_id_raw);
        const order_raw = (try jsonOptionalInteger(item_object, "playlist_order")) orelse @as(i64, @intCast(index));
        if (order_raw < 0 or order_raw > std.math.maxInt(u16)) return error.InvalidMultiplayerRoom;
        var item: PlaylistItem = .{
            .id = item_id_raw,
            .owner_id = owner_id,
            .beatmap_id = @intCast(beatmap_id_raw),
            .ruleset_id = @intCast(ruleset_id_raw),
            .order = @intCast(order_raw),
            .freestyle = try jsonOptionalBool(item_object, "freestyle", false),
        };
        item.required_mods.bytes[0] = 0x90;
        item.required_mods.len = 1;
        item.allowed_mods.bytes[0] = 0x90;
        item.allowed_mods.len = 1;
        item.played_at.bytes[0] = 0xc0;
        item.played_at.len = 1;
        if (item_object.get("required_mods")) |mods| try setJsonMessagePack(2048, &item.required_mods, mods, allocator);
        if (item_object.get("allowed_mods")) |mods| try setJsonMessagePack(2048, &item.allowed_mods, mods, allocator);
        if (item_object.get("beatmap")) |beatmap_value| switch (beatmap_value) {
            .object => |beatmap| {
                if (beatmap.get("checksum")) |checksum_value| switch (checksum_value) {
                    .null => {},
                    .string => |checksum| try item.checksum.set(checksum),
                    else => return error.InvalidMultiplayerRoom,
                };
                if (beatmap.get("difficulty_rating")) |rating| {
                    item.star_rating = try jsonNumber(rating);
                    if (item.star_rating < 0 or item.star_rating > 100) return error.InvalidMultiplayerRoom;
                }
                if (try jsonOptionalInteger(beatmap, "beatmapset_id")) |set_id| {
                    if (set_id <= 0 or set_id > std.math.maxInt(i32)) return error.InvalidMultiplayerRoom;
                    item.beatmapset_id = @intCast(set_id);
                }
                if (try jsonOptionalString(beatmap, "version")) |version| item.version.setText(version);
                if (beatmap.get("status")) |status| item.status = try beatmapStatusValue(status);
                if (beatmap.get("beatmapset")) |set_value| switch (set_value) {
                    .object => |set| {
                        if (try jsonOptionalString(set, "artist")) |artist| item.artist.setText(artist);
                        if (try jsonOptionalString(set, "title")) |title| item.title.setText(title);
                        if (try jsonOptionalString(set, "creator")) |creator| item.creator.setText(creator);
                    },
                    .null => {},
                    else => return error.InvalidMultiplayerRoom,
                };
            },
            .null => {},
            else => return error.InvalidMultiplayerRoom,
        };
        room.playlist[index] = item;
        room.playlist_count += 1;
    }
    room.settings.playlist_item_id = room.playlist[0].?.id;
    return room;
}

fn rankedDrawCard(state: *RankedPlayState, user_index: usize) ?RankedCard {
    if (user_index >= state.users.len or state.deck_cursor >= state.deck_count) return null;
    const user = &(state.users[user_index] orelse return null);
    const hand_slot = for (user.hand, 0..) |entry, index| if (entry == null) break index else {} else return null;
    const card = state.deck[state.deck_cursor] orelse return null;
    state.deck_cursor += 1;
    user.hand[hand_slot] = card;
    user.hand_count += 1;
    return card;
}

fn rankedRemoveCard(user: *RankedUser, card_id: []const u8) ?RankedCard {
    const index = user.cardIndex(card_id) orelse return null;
    const card = user.hand[index].?;
    user.hand[index] = null;
    user.hand_count -= 1;
    return card;
}

fn parseRankedCardId(encoded: []const u8) ![]const u8 {
    var reader: MessagePackReader = .{ .data = encoded };
    if (try reader.arrayLen() < 1) return error.InvalidRankedPlayCard;
    const id = try reader.string();
    if (id.len != 36 or id[8] != '-' or id[13] != '-' or id[18] != '-' or id[23] != '-') return error.InvalidRankedPlayCard;
    return id;
}

fn parseRankedCardList(encoded: []const u8, output: *[ranked_hand_size][]const u8) !usize {
    var reader: MessagePackReader = .{ .data = encoded };
    const count = try reader.arrayLen();
    if (count > output.len) return error.InvalidRankedPlayCard;
    for (0..count) |index| {
        const card = try reader.raw();
        output[index] = try parseRankedCardId(card);
        for (output[0..index]) |existing| if (std.mem.eql(u8, existing, output[index])) return error.InvalidRankedPlayCard;
    }
    return count;
}

fn rankedApplyDamage(user: *RankedUser, direct_damage: i64, multiplier: f64, bonus_damage: i32) RankedDamage {
    const direct: i32 = @intCast(std.math.clamp(direct_damage, 0, std.math.maxInt(i32)));
    const scaled = @ceil(@as(f64, @floatFromInt(direct)) * multiplier);
    const scaled_i64: i64 = @intFromFloat(@min(scaled, @as(f64, @floatFromInt(std.math.maxInt(i32)))));
    const total_i64 = std.math.add(i64, scaled_i64, bonus_damage) catch std.math.maxInt(i32);
    const total: i32 = @intCast(@min(total_i64, std.math.maxInt(i32)));
    const old_life = user.life;
    const minimum: i32 = if (old_life == 1_000_000) 1 else 0;
    user.life = @max(minimum, old_life -| total);
    return .{
        .damage = total,
        .raw_damage = @intCast(@min(@as(i64, direct) + bonus_damage, std.math.maxInt(i32))),
        .old_life = old_life,
        .new_life = user.life,
        .direct_damage = direct,
        .multiplier = multiplier,
        .bonus_damage = bonus_damage,
    };
}

fn rankedFinishRound(state: *RankedPlayState) void {
    state.round_winner_id = null;
    var winning_score: i64 = std.math.minInt(i64);
    var winner_index: ?usize = null;
    var tied = false;
    for (&state.users, 0..) |*entry, index| if (entry.*) |*user| {
        user.damage = rankedApplyDamage(user, 0, 1, 0);
        if (user.total_score > winning_score) {
            winning_score = user.total_score;
            winner_index = index;
            tied = false;
        } else if (user.total_score == winning_score) tied = true;
    };
    if (!tied) if (winner_index) |winner| {
        const winner_user = &state.users[winner].?;
        state.round_winner_id = winner_user.id;
        winner_user.rounds_won += 1;
        for (&state.users, 0..) |*entry, index| if (index != winner) if (entry.*) |*loser| {
            const difference = winning_score - loser.total_score;
            loser.damage = rankedApplyDamage(loser, difference, state.damage_multiplier + winner_user.damage_multiplier, 50_000);
        };
    };
}

fn rankedHasRoundsRemaining(state: *const RankedPlayState) bool {
    var alive: usize = 0;
    var cards = state.deck_count - state.deck_cursor;
    for (state.users) |entry| if (entry) |user| {
        if (user.life > 0) alive += 1;
        cards += user.hand_count;
    };
    return alive > 1 and cards > 0;
}

fn rankedWinner(state: *const RankedPlayState) ?i32 {
    var winner: ?i32 = null;
    var max_life: i32 = std.math.minInt(i32);
    var tied = false;
    for (state.users) |entry| if (entry) |user| {
        if (user.life > max_life) {
            max_life = user.life;
            winner = user.id;
            tied = false;
        } else if (user.life == max_life) tied = true;
    };
    return if (tied) null else winner;
}

fn recomputeMatchmakingPlacements(state: *MatchmakingState) void {
    const points = [_]i32{ 15, 12, 10, 8, 6, 4, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0 };
    for (&state.users) |*entry| if (entry.*) |*user| {
        user.points = 0;
        user.placement = null;
    };
    for (0..matchmaking_rounds) |round_index| {
        var order: [max_users]usize = undefined;
        var count: usize = 0;
        for (state.users, 0..) |entry, user_index| if (entry) |user| if (user.rounds[round_index] != null) {
            order[count] = user_index;
            count += 1;
        };
        for (0..count) |left| for (left + 1..count) |right| {
            const left_round = state.users[order[left]].?.rounds[round_index].?;
            const right_round = state.users[order[right]].?.rounds[round_index].?;
            if (right_round.total_score > left_round.total_score or (right_round.total_score == left_round.total_score and state.users[order[right]].?.id < state.users[order[left]].?.id)) {
                const swap = order[left];
                order[left] = order[right];
                order[right] = swap;
            }
        };
        var position: usize = 0;
        while (position < count) {
            var end = position + 1;
            const score = state.users[order[position]].?.rounds[round_index].?.total_score;
            while (end < count and state.users[order[end]].?.rounds[round_index].?.total_score == score) : (end += 1) {}
            const placement: u8 = @intCast(end);
            for (position..end) |cursor| {
                const user_index = order[cursor];
                state.users[user_index].?.rounds[round_index].?.placement = placement;
                state.users[user_index].?.points += points[end - 1];
            }
            position = end;
        }
    }
    var order: [max_users]usize = undefined;
    var count: usize = 0;
    for (state.users, 0..) |entry, index| if (entry != null) {
        order[count] = index;
        count += 1;
    };
    for (0..count) |left| for (left + 1..count) |right| {
        const a = state.users[order[left]].?;
        const b = state.users[order[right]].?;
        if (b.points > a.points or (b.points == a.points and b.id < a.id)) {
            const swap = order[left];
            order[left] = order[right];
            order[right] = swap;
        }
    };
    for (order[0..count], 0..) |user_index, placement| state.users[user_index].?.placement = @intCast(placement + 1);
}

fn parseSettings(encoded: []const u8) !Settings {
    var reader: MessagePackReader = .{ .data = encoded };
    if (try reader.arrayLen() < 8) return error.InvalidMultiplayerSettings;
    var settings: Settings = .{};
    const name = try reader.string();
    if (name.len == 0 or name.len > 100 or !std.unicode.utf8ValidateSlice(name)) return error.InvalidMultiplayerRoomName;
    try settings.name.set(name);
    settings.playlist_item_id = try reader.integer();
    const password = try reader.string();
    if (password.len > 50 or !std.unicode.utf8ValidateSlice(password)) return error.InvalidMultiplayerPassword;
    try settings.password.set(password);
    settings.match_type = @intCast(try reader.integer());
    if (settings.match_type != 1 and settings.match_type != 2) return error.UnsupportedMultiplayerMatchType;
    settings.queue_mode = @intCast(try reader.integer());
    if (settings.queue_mode > 2) return error.InvalidMultiplayerQueueMode;
    try settings.auto_start.set(try reader.raw());
    settings.auto_skip = try reader.boolean();
    settings.max_participants = if (try reader.nullableInteger()) |value| @intCast(value) else null;
    if (settings.max_participants) |limit| if (limit < 2 or limit > max_users) return error.InvalidMultiplayerParticipantLimit;
    return settings;
}

fn parsePlaylistItem(encoded: []const u8) !PlaylistItem {
    var reader: MessagePackReader = .{ .data = encoded };
    if (try reader.arrayLen() < 12) return error.InvalidMultiplayerPlaylistItem;
    var item: PlaylistItem = .{};
    item.id = try reader.integer();
    item.owner_id = @intCast(try reader.integer());
    item.beatmap_id = @intCast(try reader.integer());
    if (item.beatmap_id <= 0) return error.InvalidMultiplayerBeatmap;
    const checksum = try reader.string();
    if (checksum.len > 64) return error.InvalidMultiplayerBeatmap;
    try item.checksum.set(checksum);
    item.ruleset_id = @intCast(try reader.integer());
    if (item.ruleset_id > 3) return error.InvalidMultiplayerRuleset;
    try item.required_mods.set(try reader.raw());
    try item.allowed_mods.set(try reader.raw());
    item.expired = try reader.boolean();
    item.order = @intCast(try reader.integer());
    try item.played_at.set(try reader.raw());
    const star_raw = try reader.raw();
    var star_reader: MessagePackReader = .{ .data = star_raw };
    item.star_rating = switch (star_raw[0]) {
        0xca => value: {
            _ = try star_reader.byte();
            break :value @as(f64, @floatCast(@as(f32, @bitCast(try star_reader.readUnsigned(u32)))));
        },
        0xcb => value: {
            _ = try star_reader.byte();
            break :value @as(f64, @bitCast(try star_reader.readUnsigned(u64)));
        },
        else => @floatFromInt(try star_reader.integer()),
    };
    item.freestyle = try reader.boolean();
    return item;
}

fn parseRoom(allocator: std.mem.Allocator, encoded: []const u8, connection: *Connection) !*Room {
    var reader: MessagePackReader = .{ .data = encoded };
    if (try reader.arrayLen() < 9) return error.InvalidMultiplayerRoom;
    _ = try reader.integer();
    _ = try reader.integer();
    const settings_raw = try reader.raw();
    const settings = try parseSettings(settings_raw);
    try reader.skip(0);
    try reader.skip(0);
    try reader.skip(0);
    const playlist_len = try reader.arrayLen();
    if (playlist_len == 0 or playlist_len > max_playlist) return error.InvalidMultiplayerPlaylist;
    const room = try allocator.create(Room);
    errdefer allocator.destroy(room);
    room.* = .{
        .id = 0,
        .settings = settings,
        .host_id = connection.user_id,
        .host_country = connection.user_country,
    };
    try room.host_name.set(connection.user_name.slice());
    room.users[0] = try defaultRoomUser(connection.user_id, connection.user_name.slice(), connection.user_country);
    room.user_count = 1;
    room.rememberParticipant(room.users[0].?);
    for (0..playlist_len) |index| {
        const raw_item = try reader.raw();
        var item = try parsePlaylistItem(raw_item);
        if (item.id <= 0) item.id = @intCast(index + 1);
        if (item.owner_id <= 0) item.owner_id = connection.user_id;
        item.order = @intCast(index);
        room.playlist[index] = item;
        room.playlist_count += 1;
    }
    try reader.skip(0);
    _ = try reader.integer();
    if (room.itemIndex(room.settings.playlist_item_id) == null) room.settings.playlist_item_id = room.playlist[0].?.id;
    return room;
}

fn writeSettings(pack: MessagePackWriter, settings: Settings) !void {
    try pack.array(8);
    try pack.string(settings.name.slice());
    try pack.integer(settings.playlist_item_id);
    try pack.string(settings.password.slice());
    try pack.integer(settings.match_type);
    try pack.integer(settings.queue_mode);
    try pack.raw(settings.auto_start.slice());
    try pack.boolean(settings.auto_skip);
    if (settings.max_participants) |limit| try pack.integer(limit) else try pack.nil();
}

fn writeUser(pack: MessagePackWriter, user: RoomUser) !void {
    try pack.array(9);
    try pack.integer(user.id);
    try pack.integer(user.state);
    try pack.raw(user.availability.slice());
    try pack.raw(user.mods.slice());
    try pack.nil();
    if (user.ruleset_id) |ruleset_id| try pack.integer(ruleset_id) else try pack.nil();
    if (user.beatmap_id) |beatmap_id| try pack.integer(beatmap_id) else try pack.nil();
    try pack.boolean(user.voted_skip);
    try pack.integer(user.role);
}

fn writePlaylistItem(pack: MessagePackWriter, item: PlaylistItem) !void {
    try pack.array(12);
    try pack.integer(item.id);
    try pack.integer(item.owner_id);
    try pack.integer(item.beatmap_id);
    try pack.string(item.checksum.slice());
    try pack.integer(item.ruleset_id);
    try pack.raw(item.required_mods.slice());
    try pack.raw(item.allowed_mods.slice());
    try pack.boolean(item.expired);
    try pack.integer(item.order);
    try pack.raw(item.played_at.slice());
    try pack.float64(item.star_rating);
    try pack.boolean(item.freestyle);
}

fn writeRankedCard(pack: MessagePackWriter, card: RankedCard) !void {
    try pack.array(1);
    try pack.string(card.id.slice());
}

fn writeRankedDamage(pack: MessagePackWriter, damage: RankedDamage) !void {
    try pack.array(7);
    try pack.integer(damage.damage);
    try pack.integer(damage.raw_damage);
    try pack.integer(damage.old_life);
    try pack.integer(damage.new_life);
    try pack.integer(damage.direct_damage);
    try pack.float64(damage.multiplier);
    try pack.integer(damage.bonus_damage);
}

fn writeRankedUser(pack: MessagePackWriter, user: RankedUser) !void {
    try pack.array(7);
    try pack.integer(user.rating);
    try pack.integer(user.life);
    try pack.array(user.hand_count);
    for (user.hand) |entry| if (entry) |card| try writeRankedCard(pack, card);
    try pack.integer(user.rating_after);
    if (user.damage) |damage| try writeRankedDamage(pack, damage) else try pack.nil();
    try pack.integer(user.rounds_won);
    try pack.float64(user.damage_multiplier);
}

fn writeMatchState(pack: MessagePackWriter, room: *const Room) !void {
    if (room.ranked_play) |ranked| {
        try pack.array(2);
        try pack.integer(2);
        try pack.array(7);
        try pack.integer(ranked.stage);
        try pack.integer(ranked.current_round);
        try pack.float64(ranked.damage_multiplier);
        try pack.map(ranked.user_count);
        for (ranked.users) |entry| if (entry) |user| {
            try pack.integer(user.id);
            try writeRankedUser(pack, user);
        };
        if (ranked.active_user_id) |user_id| try pack.integer(user_id) else try pack.nil();
        try pack.float64(ranked.star_rating);
        if (ranked.winning_user_id) |user_id| try pack.integer(user_id) else try pack.nil();
        return;
    }
    if (room.matchmaking) |matchmaking| {
        try pack.array(2);
        try pack.integer(1);
        try pack.array(6);
        try pack.integer(matchmaking.stage);
        try pack.integer(matchmaking.current_round);
        try pack.array(matchmaking.candidate_count);
        for (matchmaking.candidate_items[0..matchmaking.candidate_count]) |item_id| try pack.integer(item_id);
        try pack.integer(matchmaking.candidate_item);
        try pack.array(1);
        try pack.map(matchmaking.user_count);
        for (matchmaking.users) |entry| if (entry) |user| {
            try pack.integer(user.id);
            try pack.array(5);
            try pack.integer(user.id);
            if (user.placement) |placement| try pack.integer(placement) else try pack.nil();
            try pack.integer(user.points);
            try pack.array(1);
            var round_count: usize = 0;
            for (user.rounds) |round| if (round != null) {
                round_count += 1;
            };
            try pack.map(round_count);
            for (user.rounds) |round_entry| if (round_entry) |round| {
                try pack.integer(round.round);
                try pack.array(6);
                try pack.integer(round.round);
                try pack.integer(round.placement);
                try pack.integer(round.total_score);
                try pack.float64(round.accuracy);
                try pack.integer(round.max_combo);
                try pack.map(0);
            };
            try pack.nil();
        };
        try pack.integer(matchmaking.gameplay_item);
        return;
    }
    try pack.array(2);
    try pack.integer(if (room.settings.match_type == 2) 0 else 3);
    try pack.array(3);
    if (room.settings.match_type == 2) {
        try pack.array(2);
        try pack.array(2);
        try pack.integer(0);
        try pack.string("Team Red");
        try pack.array(2);
        try pack.integer(1);
        try pack.string("Team Blue");
    } else try pack.nil();
    try pack.boolean(false);
    if (room.settings.max_participants) |limit| {
        try pack.array(limit);
        var written: usize = 0;
        for (room.users) |entry| if (entry) |user| {
            if (written == limit) break;
            try pack.integer(user.id);
            written += 1;
        };
        while (written < limit) : (written += 1) try pack.nil();
    } else try pack.nil();
}

fn writeRankedStageCountdown(pack: MessagePackWriter, countdown: RankedStageCountdown, now_ms: i64) !void {
    // MultiplayerCountdown union key 4 is RankedPlayStageCountdown. MessagePack-CSharp
    // represents TimeSpan as signed 100ns ticks.
    try pack.array(2);
    try pack.integer(4);
    try pack.array(3);
    try pack.integer(countdown.id);
    try pack.integer(countdown.remainingTicks(now_ms));
    try pack.integer(countdown.stage);
}

fn writeRoom(pack: MessagePackWriter, room: *const Room, now_ms: i64) !void {
    try pack.array(9);
    try pack.integer(room.id);
    try pack.integer(room.state);
    try writeSettings(pack, room.settings);
    try pack.array(room.user_count);
    for (room.users) |entry| if (entry) |user| try writeUser(pack, user);
    if (room.userIndex(room.host_id)) |host_index| {
        try writeUser(pack, room.users[host_index].?);
    } else {
        const host = try defaultRoomUser(room.host_id, room.host_name.slice(), room.host_country);
        try writeUser(pack, host);
    }
    try writeMatchState(pack, room);
    try pack.array(room.playlist_count);
    for (room.playlist) |entry| if (entry) |item| try writePlaylistItem(pack, item);
    if (room.ranked_play) |ranked| if (ranked.pick_countdown) |countdown| {
        try pack.array(1);
        try writeRankedStageCountdown(pack, countdown, now_ms);
    } else {
        try pack.array(0);
    } else {
        try pack.array(0);
    }
    try pack.integer(room.channel_id);
}

fn writeApiUserJson(writer: *std.Io.Writer, id: i32, name: []const u8, country: [2]u8) !void {
    try writer.print("{{\"id\":{d},\"username\":", .{id});
    try std.json.Stringify.value(name, .{}, writer);
    try writer.print(",\"avatar_url\":\"https://a.kai.ovh/{d}\",\"country_code\":", .{id});
    try std.json.Stringify.value(country[0..], .{}, writer);
    try writer.writeAll(",\"is_active\":true,\"is_supporter\":true}");
}

fn beatmapStatusName(status: i8) []const u8 {
    return switch (status) {
        1 => "wip",
        2 => "pending",
        3 => "ranked",
        4 => "approved",
        5 => "qualified",
        6 => "loved",
        else => "graveyard",
    };
}

fn matchmakingStageName(stage: u8) []const u8 {
    return switch (stage) {
        matchmaking_stage.waiting_for_clients_join => "waiting for players",
        matchmaking_stage.round_warmup => "round warmup",
        matchmaking_stage.user_beatmap_select => "choosing a beatmap",
        matchmaking_stage.server_beatmap_finalised => "beatmap selected",
        matchmaking_stage.waiting_for_beatmap_download => "waiting for downloads",
        matchmaking_stage.gameplay_warmup => "gameplay warmup",
        matchmaking_stage.gameplay => "playing",
        matchmaking_stage.results => "results",
        else => "finished",
    };
}

fn rankedStageName(stage: u8) []const u8 {
    return switch (stage) {
        ranked_stage.wait_for_join => "waiting for players",
        ranked_stage.round_warmup => "round warmup",
        ranked_stage.card_discard => "discarding cards",
        ranked_stage.finish_card_discard => "locking discards",
        ranked_stage.card_play => "playing cards",
        ranked_stage.finish_card_play => "locking cards",
        ranked_stage.gameplay_warmup => "gameplay warmup",
        ranked_stage.gameplay => "playing",
        ranked_stage.results => "results",
        else => "finished",
    };
}

fn writeRoomModeJson(writer: *std.Io.Writer, room: *const Room) !void {
    try writer.writeAll(",\"zigcho\":{");
    if (room.ranked_play) |ranked| {
        try writer.writeAll("\"kind\":\"ranked_play\",\"phase\":");
        try std.json.Stringify.value(rankedStageName(ranked.stage), .{}, writer);
        try writer.print(",\"round\":{d},\"star_rating\":{d},\"active_user_id\":", .{ ranked.current_round, ranked.star_rating });
        if (ranked.active_user_id) |id| try writer.print("{d}", .{id}) else try writer.writeAll("null");
        try writer.writeAll(",\"winner_id\":");
        if (ranked.winning_user_id) |id| try writer.print("{d}", .{id}) else try writer.writeAll("null");
        try writer.writeAll(",\"players\":[");
        var written: usize = 0;
        for (ranked.users) |entry| if (entry) |user| {
            if (written != 0) try writer.writeByte(',');
            try writer.print("{{\"user_id\":{d},\"rating\":{d},\"rating_after\":{d},\"life\":{d},\"rounds_won\":{d},\"total_score\":{d}}}", .{ user.id, user.rating, user.rating_after, user.life, user.rounds_won, user.total_score });
            written += 1;
        };
        try writer.writeByte(']');
    } else if (room.matchmaking) |matchmaking| {
        try writer.writeAll("\"kind\":\"quick_play\",\"phase\":");
        try std.json.Stringify.value(matchmakingStageName(matchmaking.stage), .{}, writer);
        try writer.print(",\"round\":{d},\"gameplay_item_id\":{d},\"players\":[", .{ matchmaking.current_round, matchmaking.gameplay_item });
        var written: usize = 0;
        for (matchmaking.users) |entry| if (entry) |user| {
            if (written != 0) try writer.writeByte(',');
            try writer.print("{{\"user_id\":{d},\"points\":{d},\"placement\":", .{ user.id, user.points });
            if (user.placement) |placement| try writer.print("{d}", .{placement}) else try writer.writeAll("null");
            try writer.writeByte('}');
            written += 1;
        };
        try writer.writeByte(']');
    } else {
        try writer.writeAll("\"kind\":\"room\",\"phase\":");
        try std.json.Stringify.value(if (room.state == 0) "waiting" else "playing", .{}, writer);
        try writer.writeAll(",\"round\":0,\"players\":[]");
    }
    try writer.writeByte('}');
}

fn writePlaylistItemJson(writer: *std.Io.Writer, item: PlaylistItem) !void {
    const mode: []const u8 = switch (item.ruleset_id) {
        0 => "osu",
        1 => "taiko",
        2 => "fruits",
        else => "mania",
    };
    const set_id = if (item.beatmapset_id > 0) item.beatmapset_id else item.beatmap_id;
    const artist = if (item.artist.len != 0) item.artist.slice() else "online beatmap";
    const title = if (item.title.len != 0) item.title.slice() else "unknown song";
    const version = if (item.version.len != 0) item.version.slice() else "online difficulty";
    const creator = if (item.creator.len != 0) item.creator.slice() else "unknown";
    const status = beatmapStatusName(item.status);
    try writer.print("{{\"id\":{d},\"owner_id\":{d},\"ruleset_id\":{d},\"expired\":{s},\"playlist_order\":{d},\"played_at\":null,\"allowed_mods\":[],\"required_mods\":[],\"beatmap_id\":{d},\"beatmap\":{{\"id\":{d},\"beatmapset_id\":{d},\"mode\":", .{ item.id, item.owner_id, item.ruleset_id, if (item.expired) "true" else "false", item.order, item.beatmap_id, item.beatmap_id, set_id });
    try std.json.Stringify.value(mode, .{}, writer);
    try writer.writeAll(",\"status\":");
    try std.json.Stringify.value(status, .{}, writer);
    try writer.writeAll(",\"version\":");
    try std.json.Stringify.value(version, .{}, writer);
    try writer.writeAll(",\"difficulty_rating\":");
    try writer.print("{d},\"checksum\":", .{item.star_rating});
    try std.json.Stringify.value(item.checksum.slice(), .{}, writer);
    try writer.print(",\"beatmapset\":{{\"id\":{d},\"status\":", .{set_id});
    try std.json.Stringify.value(status, .{}, writer);
    try writer.writeAll(",\"artist\":");
    try std.json.Stringify.value(artist, .{}, writer);
    try writer.writeAll(",\"artist_unicode\":");
    try std.json.Stringify.value(artist, .{}, writer);
    try writer.writeAll(",\"title\":");
    try std.json.Stringify.value(title, .{}, writer);
    try writer.writeAll(",\"title_unicode\":");
    try std.json.Stringify.value(title, .{}, writer);
    try writer.writeAll(",\"creator\":");
    try std.json.Stringify.value(creator, .{}, writer);
    try writer.print(",\"covers\":{{\"cover\":\"https://assets.kai.ovh/beatmaps/{d}/covers/cover.jpg\",\"cover@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/cover@2x.jpg\",\"card\":\"https://assets.kai.ovh/beatmaps/{d}/covers/card.jpg\",\"card@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/card@2x.jpg\",\"list\":\"https://assets.kai.ovh/beatmaps/{d}/covers/list.jpg\",\"list@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/list@2x.jpg\",\"slimcover\":\"https://assets.kai.ovh/beatmaps/{d}/covers/slimcover.jpg\",\"slimcover@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/slimcover@2x.jpg\"}},\"preview_url\":\"https://b.kai.ovh/preview/{d}.mp3\"}}}},\"freestyle\":{s}}}", .{ set_id, set_id, set_id, set_id, set_id, set_id, set_id, set_id, set_id, if (item.freestyle) "true" else "false" });
}

fn writeRoomJson(writer: *std.Io.Writer, room: *const Room) !void {
    try writer.print("{{\"id\":{d},\"name\":", .{room.id});
    try std.json.Stringify.value(room.settings.name.slice(), .{}, writer);
    try writer.print(",\"description\":null,\"has_password\":{s},\"host\":", .{if (room.settings.password.len != 0) "true" else "false"});
    try writeApiUserJson(writer, room.host_id, room.host_name.slice(), room.host_country);
    try writer.writeAll(",\"category\":");
    try std.json.Stringify.value(if (room.settings.match_type == 0) "normal" else "realtime", .{}, writer);
    try writer.writeAll(",\"duration\":null,\"starts_at\":null,\"ends_at\":null,\"max_participants\":");
    if (room.settings.max_participants) |limit| try writer.print("{d}", .{limit}) else try writer.writeAll("null");
    try writer.print(",\"participant_count\":{d},\"recent_participants\":[", .{if (room.ended) room.participant_count else room.user_count});
    var users_written: usize = 0;
    if (room.ended) {
        for (room.participants[0..room.participant_count]) |entry| if (entry) |user| {
            if (users_written != 0) try writer.writeByte(',');
            try writeApiUserJson(writer, user.id, user.name.slice(), user.country);
            users_written += 1;
        };
    } else {
        for (room.users) |entry| if (entry) |user| {
            if (users_written != 0) try writer.writeByte(',');
            try writeApiUserJson(writer, user.id, user.name.slice(), user.country);
            users_written += 1;
        };
    }
    const match_type: []const u8 = switch (room.settings.match_type) {
        0 => "playlists",
        2 => "team_versus",
        3 => "matchmaking",
        4 => "ranked_play",
        else => "head_to_head",
    };
    const queue_mode: []const u8 = switch (room.settings.queue_mode) {
        1 => "all_players",
        2 => "all_players_round_robin",
        else => "host_only",
    };
    try writer.writeAll("],\"max_attempts\":null,\"playlist\":[");
    var playlist_written: usize = 0;
    var active_playlist_items: usize = 0;
    for (room.playlist) |entry| if (entry) |item| {
        if (playlist_written != 0) try writer.writeByte(',');
        try writePlaylistItemJson(writer, item);
        playlist_written += 1;
        if (!item.expired) active_playlist_items += 1;
    };
    try writer.print("],\"playlist_item_stats\":{{\"count_active\":{d},\"count_total\":{d},\"ruleset_ids\":[]}},\"difficulty_range\":null,\"type\":", .{ active_playlist_items, room.playlist_count });
    try std.json.Stringify.value(match_type, .{}, writer);
    try writer.writeAll(",\"queue_mode\":");
    try std.json.Stringify.value(queue_mode, .{}, writer);
    try writer.print(",\"auto_skip\":{s},\"auto_start_duration\":0,\"current_user_score\":null,\"current_playlist_item\":", .{if (room.settings.auto_skip) "true" else "false"});
    const current = room.playlist[room.itemIndex(room.settings.playlist_item_id) orelse 0] orelse return error.MultiplayerPlaylistItemNotFound;
    try writePlaylistItemJson(writer, current);
    try writer.print(",\"channel_id\":{d},\"status\":\"{s}\",\"pinned\":false", .{ room.channel_id, if (room.ended) "ended" else if (room.state == 0) "idle" else "playing" });
    try writeRoomModeJson(writer, room);
    try writer.writeByte('}');
}

fn writeRoomLeaderboardJson(writer: *std.Io.Writer, room: *const Room, requester_id: i32) !void {
    const Aggregate = struct {
        user: RoomParticipant,
        attempts: i32 = 0,
        completed: i32 = 0,
        total_score: i64 = 0,
        accuracy_total: f64 = 0,
    };
    var aggregates: [max_room_participants]?Aggregate = [_]?Aggregate{null} ** max_room_participants;
    var aggregate_count: usize = 0;
    for (room.scores) |entry| if (entry) |score| {
        const participant_index = room.participantIndex(score.user_id) orelse continue;
        var aggregate_index: ?usize = null;
        for (aggregates[0..aggregate_count], 0..) |candidate, index| if (candidate.?.user.id == score.user_id) {
            aggregate_index = index;
            break;
        };
        if (aggregate_index == null) {
            if (aggregate_count == aggregates.len) continue;
            aggregate_index = aggregate_count;
            aggregates[aggregate_count] = .{ .user = room.participants[participant_index].? };
            aggregate_count += 1;
        }
        const aggregate = &aggregates[aggregate_index.?].?;
        aggregate.attempts += 1;
        aggregate.completed += @intFromBool(score.passed);
        aggregate.total_score += score.total_score;
        aggregate.accuracy_total += score.accuracy;
    };
    std.mem.sort(?Aggregate, aggregates[0..aggregate_count], {}, struct {
        fn lessThan(_: void, left: ?Aggregate, right: ?Aggregate) bool {
            if (left.?.total_score != right.?.total_score) return left.?.total_score > right.?.total_score;
            return left.?.user.id < right.?.user.id;
        }
    }.lessThan);
    try writer.writeAll("{\"leaderboard\":[");
    for (aggregates[0..aggregate_count], 0..) |entry, index| {
        const aggregate = entry.?;
        if (index != 0) try writer.writeByte(',');
        try writer.print("{{\"attempts\":{d},\"completed\":{d},\"accuracy\":{d},\"pp\":null,\"room_id\":{d},\"total_score\":{d},\"user_id\":{d},\"user\":", .{ aggregate.attempts, aggregate.completed, aggregate.accuracy_total / @as(f64, @floatFromInt(aggregate.attempts)), room.id, aggregate.total_score, aggregate.user.id });
        try writeApiUserJson(writer, aggregate.user.id, aggregate.user.name.slice(), aggregate.user.country);
        try writer.print(",\"position\":{d}}}", .{index + 1});
    }
    try writer.writeAll("],\"user_score\":");
    var own_index: ?usize = null;
    for (aggregates[0..aggregate_count], 0..) |entry, index| if (entry.?.user.id == requester_id) {
        own_index = index;
        break;
    };
    if (own_index) |index| {
        const aggregate = aggregates[index].?;
        try writer.print("{{\"attempts\":{d},\"completed\":{d},\"accuracy\":{d},\"pp\":null,\"room_id\":{d},\"total_score\":{d},\"user_id\":{d},\"user\":", .{ aggregate.attempts, aggregate.completed, aggregate.accuracy_total / @as(f64, @floatFromInt(aggregate.attempts)), room.id, aggregate.total_score, aggregate.user.id });
        try writeApiUserJson(writer, aggregate.user.id, aggregate.user.name.slice(), aggregate.user.country);
        try writer.print(",\"position\":{d}}}", .{index + 1});
    } else try writer.writeAll("null");
    try writer.writeByte('}');
}

pub fn frameOwned(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    if (body.len == 0 or body.len > max_hub_message) return error.MultiplayerPayloadTooLarge;
    var prefix: [5]u8 = undefined;
    var remaining = body.len;
    var prefix_len: usize = 0;
    while (true) {
        var byte_value: u8 = @intCast(remaining & 0x7f);
        remaining >>= 7;
        if (remaining != 0) byte_value |= 0x80;
        prefix[prefix_len] = byte_value;
        prefix_len += 1;
        if (remaining == 0) break;
    }
    const output = try allocator.alloc(u8, prefix_len + body.len);
    @memcpy(output[0..prefix_len], prefix[0..prefix_len]);
    @memcpy(output[prefix_len..], body);
    return output;
}

pub fn allocatingFrame(allocator: std.mem.Allocator, output: *std.Io.Writer.Allocating) ![]u8 {
    const body = output.written();
    return frameOwned(allocator, body);
}

pub fn completionVoidOwned(allocator: std.mem.Allocator, invocation_id: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try pack.array(4);
    try pack.integer(3);
    try pack.map(0);
    try pack.string(invocation_id);
    try pack.integer(2);
    return allocatingFrame(allocator, &output);
}

pub fn completionErrorOwned(allocator: std.mem.Allocator, invocation_id: []const u8, message: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try pack.array(5);
    try pack.integer(3);
    try pack.map(0);
    try pack.string(invocation_id);
    try pack.integer(1);
    try pack.string(message);
    return allocatingFrame(allocator, &output);
}

fn completionRoomOwned(allocator: std.mem.Allocator, invocation_id: []const u8, room: *const Room, now_ms: i64) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try pack.array(5);
    try pack.integer(3);
    try pack.map(0);
    try pack.string(invocation_id);
    try pack.integer(3);
    try writeRoom(pack, room, now_ms);
    return allocatingFrame(allocator, &output);
}

fn completionEmptyObjectOwned(allocator: std.mem.Allocator, invocation_id: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try pack.array(5);
    try pack.integer(3);
    try pack.map(0);
    try pack.string(invocation_id);
    try pack.integer(3);
    try pack.array(0);
    return allocatingFrame(allocator, &output);
}

fn completionMatchmakingPoolsOwned(allocator: std.mem.Allocator, invocation_id: []const u8, pool_type: u8, available: [4]bool) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try pack.array(5);
    try pack.integer(3);
    try pack.map(0);
    try pack.string(invocation_id);
    try pack.integer(3);
    var count: usize = 0;
    for (available) |enabled| if (enabled) {
        count += 1;
    };
    try pack.array(count);
    for (available, 0..) |enabled, mode| {
        if (!enabled) continue;
        try pack.array(5);
        const pool_offset: usize = if (pool_type == 1) 100 else 0;
        try pack.integer(@as(i64, @intCast(mode + 1 + pool_offset)));
        try pack.integer(@intCast(mode));
        try pack.integer(0);
        try pack.string(if (pool_type == 0) "quick play" else "ranked play");
        try pack.integer(pool_type);
    }
    return allocatingFrame(allocator, &output);
}

pub fn beginEvent(pack: MessagePackWriter, target: []const u8, argument_count: usize) !void {
    try pack.array(6);
    try pack.integer(1);
    try pack.map(0);
    try pack.nil();
    try pack.string(target);
    try pack.array(argument_count);
}

pub fn endEvent(pack: MessagePackWriter) !void {
    try pack.array(0);
}

fn eventNoArgsOwned(allocator: std.mem.Allocator, target: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, target, 0);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventQueueStatusOwned(allocator: std.mem.Allocator, status: u8) ![]u8 {
    if (status > 2) return error.InvalidMatchmakingQueueStatus;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchmakingQueueStatusChanged", 1);
    try pack.array(2);
    try pack.integer(status);
    try pack.array(0);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventMatchmakingInvitationOwned(allocator: std.mem.Allocator, pool_type: u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchmakingRoomInvitedWithParams", 1);
    try pack.array(1);
    try pack.integer(pool_type);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventMatchmakingDuelIssuedOwned(
    allocator: std.mem.Allocator,
    duel_id: []const u8,
    challenger_id: i32,
    pool_id: i32,
    mode: u8,
    pool_type: u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchmakingDuelIssued", 1);
    try pack.array(3);
    // MessagePack-CSharp's standard Guid formatter uses the canonical
    // lowercase 36-character string on the wire.
    try pack.string(duel_id);
    try pack.integer(challenger_id);
    try pack.array(5);
    try pack.integer(pool_id);
    try pack.integer(mode);
    try pack.integer(0);
    try pack.string(if (pool_type == 0) "quick play" else "ranked play");
    try pack.integer(pool_type);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventMatchmakingRoomReadyOwned(allocator: std.mem.Allocator, room_id: i64, password: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchmakingRoomReady", 2);
    try pack.integer(room_id);
    try pack.string(password);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventLobbyStatusOwned(allocator: std.mem.Allocator, users: []const i32) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchmakingLobbyStatusChanged", 1);
    try pack.array(4);
    try pack.array(users.len);
    for (users) |user_id| try pack.integer(user_id);
    // Ratings are not persistent yet. A made-up single bucket gives lazer a
    // zero-width graph range and causes its queue screen to calculate NaN.
    try pack.array(0);
    try pack.nil();
    try pack.array(0);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventMatchStateOwned(allocator: std.mem.Allocator, room: *const Room) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchRoomStateChanged", 1);
    try writeMatchState(pack, room);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventRankedCountdownStartedOwned(allocator: std.mem.Allocator, countdown: RankedStageCountdown, now_ms: i64) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchEvent", 1);
    // MatchServerEvent union key 0 is CountdownStartedEvent.
    try pack.array(2);
    try pack.integer(0);
    try pack.array(1);
    try writeRankedStageCountdown(pack, countdown, now_ms);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventRankedCountdownStoppedOwned(allocator: std.mem.Allocator, countdown_id: i32) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchEvent", 1);
    // MatchServerEvent union key 1 is CountdownStoppedEvent.
    try pack.array(2);
    try pack.integer(1);
    try pack.array(1);
    try pack.integer(countdown_id);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventIntegersOwned(allocator: std.mem.Allocator, target: []const u8, values: []const i64) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, target, values.len);
    for (values) |value| try pack.integer(value);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventUserOwned(allocator: std.mem.Allocator, target: []const u8, user: RoomUser) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, target, 1);
    try writeUser(pack, user);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventSettingsOwned(allocator: std.mem.Allocator, target: []const u8, settings: Settings) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, target, 1);
    try writeSettings(pack, settings);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventPlaylistOwned(allocator: std.mem.Allocator, target: []const u8, item: PlaylistItem) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, target, 1);
    try writePlaylistItem(pack, item);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventRankedCardUserOwned(allocator: std.mem.Allocator, target: []const u8, user_id: i32, card: RankedCard) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, target, 2);
    try pack.integer(user_id);
    try writeRankedCard(pack, card);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventRankedCardRevealedOwned(allocator: std.mem.Allocator, card: RankedCard, item: PlaylistItem) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "RankedPlayCardRevealed", 2);
    try writeRankedCard(pack, card);
    try writePlaylistItem(pack, item);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventRankedCardPlayedOwned(allocator: std.mem.Allocator, card: RankedCard) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "RankedPlayCardPlayed", 1);
    try writeRankedCard(pack, card);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventIntegerRawOwned(allocator: std.mem.Allocator, target: []const u8, user_id: i32, raw: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, target, 2);
    try pack.integer(user_id);
    try pack.raw(raw);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventIntegerBoolOwned(allocator: std.mem.Allocator, target: []const u8, user_id: i32, value: bool) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, target, 2);
    try pack.integer(user_id);
    try pack.boolean(value);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventStyleOwned(allocator: std.mem.Allocator, user_id: i32, beatmap_id: ?i32, ruleset_id: ?i32) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "UserStyleChanged", 3);
    try pack.integer(user_id);
    if (beatmap_id) |value| try pack.integer(value) else try pack.nil();
    if (ruleset_id) |value| try pack.integer(value) else try pack.nil();
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventInviteOwned(allocator: std.mem.Allocator, invited_by: i32, room_id: i64, password: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "Invited", 3);
    try pack.integer(invited_by);
    try pack.integer(room_id);
    try pack.string(password);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn pingOwned(allocator: std.mem.Allocator) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try pack.array(1);
    try pack.integer(6);
    return allocatingFrame(allocator, &output);
}

pub fn parseRoomPath(path: []const u8) ?i64 {
    const prefix = "/api/v2/rooms/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    if (rest.len == 0 or std.mem.indexOfScalar(u8, rest, '/') != null) return null;
    const id = std.fmt.parseInt(i64, rest, 10) catch return null;
    return if (id > 0) id else null;
}

pub fn parseRoomScorePath(path: []const u8) ?RoomScorePath {
    const prefix = "/api/v2/rooms/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    var parts = std.mem.splitScalar(u8, path[prefix.len..], '/');
    const room_text = parts.next() orelse return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "playlist")) return null;
    const playlist_text = parts.next() orelse return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "scores")) return null;
    const token_text = parts.next();
    if (parts.next() != null) return null;
    const room_id = std.fmt.parseInt(i64, room_text, 10) catch return null;
    const playlist_item_id = std.fmt.parseInt(i64, playlist_text, 10) catch return null;
    const token_id = if (token_text) |value| std.fmt.parseInt(i64, value, 10) catch return null else null;
    if (room_id <= 0 or playlist_item_id <= 0 or (token_id != null and token_id.? <= 0)) return null;
    return .{ .room_id = room_id, .playlist_item_id = playlist_item_id, .token_id = token_id };
}

pub fn negotiateJson(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var random: [24]u8 = undefined;
    try io.randomSecure(&random);
    var token: [32]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&token, &random);
    return std.fmt.allocPrint(allocator, "{{\"negotiateVersion\":1,\"connectionId\":\"{s}\",\"connectionToken\":\"{s}\",\"availableTransports\":[{{\"transport\":\"WebSockets\",\"transferFormats\":[\"Binary\"]}}]}}", .{ &token, &token });
}

pub fn validSignalRHandshake(allocator: std.mem.Allocator, data: []const u8) bool {
    if (data.len < 2 or data[data.len - 1] != 0x1e or std.mem.indexOfScalar(u8, data[0 .. data.len - 1], 0x1e) != null) return false;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data[0 .. data.len - 1], .{}) catch return false;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const protocol = object.get("protocol") orelse return false;
    const version = object.get("version") orelse return false;
    return switch (protocol) {
        .string => |value| std.mem.eql(u8, value, "messagepack"),
        else => false,
    } and switch (version) {
        .integer => |value| value == 1,
        else => false,
    };
}

test "bounded messagepack framing accepts a room snapshot and rejects nested bombs" {
    var body: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer body.deinit();
    const pack: MessagePackWriter = .{ .writer = &body.writer };
    try pack.array(3);
    try pack.integer(1);
    try pack.string("room");
    try pack.boolean(true);
    var reader: MessagePackReader = .{ .data = body.written() };
    try std.testing.expectEqual(@as(usize, 3), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 1), try reader.integer());
    try std.testing.expectEqualStrings("room", try reader.string());
    try std.testing.expect(try reader.boolean());

    const nested = [_]u8{0x91} ** 17 ++ [_]u8{0xc0};
    var nested_reader: MessagePackReader = .{ .data = &nested };
    try std.testing.expectError(error.MessagePackNestingTooDeep, nested_reader.skip(0));
}

test "lazer multiplayer room path only accepts exact positive ids" {
    try std.testing.expectEqual(@as(?i64, 42), parseRoomPath("/api/v2/rooms/42"));
    try std.testing.expectEqual(@as(?i64, null), parseRoomPath("/api/v2/rooms/42/scores"));
    try std.testing.expectEqual(@as(?i64, null), parseRoomPath("/api/v2/rooms/0"));
}

test "lazer multiplayer score path separates room playlist and token ids" {
    const create = parseRoomScorePath("/api/v2/rooms/5/playlist/8/scores").?;
    try std.testing.expectEqual(@as(i64, 5), create.room_id);
    try std.testing.expectEqual(@as(i64, 8), create.playlist_item_id);
    try std.testing.expectEqual(@as(?i64, null), create.token_id);
    const submit = parseRoomScorePath("/api/v2/rooms/5/playlist/8/scores/13").?;
    try std.testing.expectEqual(@as(?i64, 13), submit.token_id);
    try std.testing.expectEqual(@as(?RoomScorePath, null), parseRoomScorePath("/api/v2/rooms/5/playlist/users/scores"));
}

test "lazer multiplayer REST room paths cover leaderboard and user scores" {
    try std.testing.expectEqual(@as(?i64, 5), parseRoomLeaderboardPath("/api/v2/rooms/5/leaderboard"));
    try std.testing.expectEqual(@as(?i64, null), parseRoomLeaderboardPath("/api/v2/rooms/5/leaderboard/extra"));
    const user_score = parseRoomUserScorePath("/api/v2/rooms/5/playlist/8/scores/users/13").?;
    try std.testing.expectEqual(@as(i64, 5), user_score.room_id);
    try std.testing.expectEqual(@as(i64, 8), user_score.playlist_item_id);
    try std.testing.expectEqual(@as(i32, 13), user_score.user_id);
    try std.testing.expectEqual(@as(?RoomUserScorePath, null), parseRoomUserScorePath("/api/v2/rooms/5/playlist/8/scores/users/0"));
    try std.testing.expectEqual(RoomListMode.open, (try roomListFilter(4, "open", "idle", "realtime")).mode);
    try std.testing.expectEqual(RoomListStatus.idle, (try roomListFilter(4, "open", "idle", "realtime")).status.?);
    try std.testing.expectError(error.InvalidRoomListFilter, roomListFilter(4, "closed", null, "realtime"));
    try std.testing.expectError(error.InvalidRoomListFilter, roomListFilter(4, "open", null, "made_up"));
}

test "lazer playlist creation assigns zero owner ids to the authenticated user" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const host: domain.User = .{ .id = 4, .name = "raya", .safe_name = "raya", .country = .{ 'A', 'U' } };
    const client_body =
        \\{"id":null,"name":"raya's awesome playlist","description":null,"password":null,"host":null,"category":"normal","duration":30,"starts_at":null,"ends_at":null,"max_participants":null,"participant_count":0,"recent_participants":[],"max_attempts":null,"playlist":[{"owner_id":0,"ruleset_id":0,"expired":false,"playlist_order":null,"played_at":null,"allowed_mods":[],"required_mods":[],"beatmap_id":1000000003,"freestyle":false}],"playlist_item_stats":null,"difficulty_range":null,"type":"playlists","queue_mode":"host_only","auto_skip":false,"auto_start_duration":0,"current_user_score":null,"current_playlist_item":null,"channel_id":0,"status":"idle","pinned":false}
    ;
    const created = try manager.restCreateRoom(std.testing.allocator, host, client_body);
    defer std.testing.allocator.free(created);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, created, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("id").?.integer);
    try std.testing.expectEqualStrings("playlists", parsed.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("normal", parsed.value.object.get("category").?.string);
    try std.testing.expectEqual(@as(i64, host.id), parsed.value.object.get("playlist").?.array.items[0].object.get("owner_id").?.integer);
    try std.testing.expectEqual(@as(i64, host.id), parsed.value.object.get("current_playlist_item").?.object.get("owner_id").?.integer);
}

test "lazer multiplayer REST lifecycle owns room state and score boards" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const host: domain.User = .{ .id = 4, .name = "raya", .safe_name = "raya", .country = .{ 'A', 'U' } };
    const guest: domain.User = .{ .id = 7, .name = "guest", .safe_name = "guest", .country = .{ 'G', 'B' } };
    const room_body =
        \\{"name":"route test","password":"secret","type":"head_to_head","queue_mode":"host_only","max_participants":2,"auto_start_duration":5,"playlist":[{"id":8,"owner_id":4,"beatmap_id":75,"ruleset_id":0,"playlist_order":0,"required_mods":[{"acronym":"HD"}],"allowed_mods":[{"acronym":"DT","settings":{"speed_change":1.25}}],"beatmap":{"checksum":"0123456789abcdef0123456789abcdef","difficulty_rating":5.25,"beatmapset_id":750,"status":"loved","version":"night drive","beatmapset":{"artist":"fixture artist","title":"fixture song","creator":"fixture mapper"}}}]}
    ;
    const created = try manager.restCreateRoom(std.testing.allocator, host, room_body);
    defer std.testing.allocator.free(created);
    var parsed_created = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, created, .{});
    defer parsed_created.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed_created.value.object.get("id").?.integer);
    try std.testing.expectEqualStrings("head_to_head", parsed_created.value.object.get("type").?.string);
    try std.testing.expectEqual(@as(usize, 1), parsed_created.value.object.get("playlist").?.array.items.len);
    const created_beatmap = parsed_created.value.object.get("playlist").?.array.items[0].object.get("beatmap").?.object;
    try std.testing.expectEqual(@as(i64, 750), created_beatmap.get("beatmapset_id").?.integer);
    try std.testing.expectEqualStrings("night drive", created_beatmap.get("version").?.string);
    try std.testing.expectEqualStrings("loved", created_beatmap.get("status").?.string);
    const created_set = created_beatmap.get("beatmapset").?.object;
    try std.testing.expectEqualStrings("fixture artist", created_set.get("artist").?.string);
    try std.testing.expectEqualStrings("fixture song", created_set.get("title").?.string);
    try std.testing.expectEqualStrings("fixture mapper", created_set.get("creator").?.string);
    try std.testing.expectEqualStrings("https://assets.kai.ovh/beatmaps/750/covers/card@2x.jpg", created_set.get("covers").?.object.get("card@2x").?.string);
    try std.testing.expectError(error.InvalidMultiplayerPassword, manager.restJoinRoom(std.testing.allocator, guest, 1, "wrong"));

    const joined = try manager.restJoinRoom(std.testing.allocator, guest, 1, "secret");
    defer std.testing.allocator.free(joined);
    var parsed_joined = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, joined, .{});
    defer parsed_joined.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed_joined.value.object.get("recent_participants").?.array.items.len);
    const visible_rooms = (try manager.roomsJson(std.testing.allocator, null, try roomListFilter(host.id, "open", "idle", "realtime"))).?;
    defer std.testing.allocator.free(visible_rooms);
    var parsed_visible = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, visible_rooms, .{});
    defer parsed_visible.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_visible.value.array.items.len);
    const hidden_rooms = (try manager.roomsJson(std.testing.allocator, null, try roomListFilter(host.id, "open", "idle", "normal"))).?;
    defer std.testing.allocator.free(hidden_rooms);
    try std.testing.expectEqualStrings("[]", hidden_rooms);
    const guest_owned = (try manager.roomsJson(std.testing.allocator, null, try roomListFilter(guest.id, "owned", null, "realtime"))).?;
    defer std.testing.allocator.free(guest_owned);
    try std.testing.expectEqualStrings("[]", guest_owned);
    const context = manager.scoreContext(guest.id, 1, 8).?;
    try std.testing.expectEqual(@as(i32, 75), context.beatmap_id);
    try std.testing.expectEqual(@as(u8, 0), context.ruleset_id);

    try manager.recordRoomScore(host.id, 1, 8, .{ .score_id = 101, .total_score = 800_000, .accuracy = 0.98, .max_combo = 500, .passed = true });
    try manager.recordRoomScore(guest.id, 1, 8, .{ .score_id = 102, .total_score = 900_000, .accuracy = 0.99, .max_combo = 600, .passed = true });
    try manager.recordRoomScore(host.id, 1, 8, .{ .score_id = 103, .total_score = 850_000, .accuracy = 0.985, .max_combo = 550, .passed = true });
    try std.testing.expectEqual(@as(?i64, 103), manager.roomScoreIdForUser(host.id, 1, 8, host.id));
    try std.testing.expect(manager.roomContainsScore(guest.id, 1, 8, 102));
    const ids = (try manager.roomScoreIds(std.testing.allocator, host.id, 1, 8)).?;
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(i64, &.{ 101, 102, 103 }, ids);

    const leaderboard = (try manager.roomLeaderboardJson(std.testing.allocator, guest.id, 1)).?;
    defer std.testing.allocator.free(leaderboard);
    var parsed_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, leaderboard, .{});
    defer parsed_board.deinit();
    const rows = parsed_board.value.object.get("leaderboard").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(i64, 4), rows[0].object.get("user_id").?.integer);
    try std.testing.expectEqual(@as(i64, 1_650_000), rows[0].object.get("total_score").?.integer);
    try std.testing.expectEqual(@as(i64, 7), parsed_board.value.object.get("user_score").?.object.get("user_id").?.integer);

    try manager.restPartRoom(guest.id, 1);
    try std.testing.expect(manager.scoreContext(guest.id, 1, 8) == null);
    try std.testing.expectError(error.MultiplayerPermissionDenied, manager.restCloseRoom(guest.id, 1));
    try manager.restCloseRoom(host.id, 1);
    try std.testing.expect((try manager.roomsJson(std.testing.allocator, 1, null)) == null);
}

test "completed lazer rooms and score boards survive manager restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/multiplayer-history.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const host_id = try store.register("room host", "room-host@example.invalid", "00000000000000000000000000000000");
    const guest_id = try store.register("room guest", "room-guest@example.invalid", "00000000000000000000000000000000");
    const host: domain.User = .{ .id = host_id, .name = "room host", .safe_name = "room_host", .country = .{ 'A', 'U' } };
    const guest: domain.User = .{ .id = guest_id, .name = "room guest", .safe_name = "room_guest", .country = .{ 'G', 'B' } };
    const room_body = try std.fmt.allocPrint(std.testing.allocator, "{{\"name\":\"kept room\",\"type\":\"head_to_head\",\"queue_mode\":\"host_only\",\"playlist\":[{{\"id\":8,\"owner_id\":{d},\"beatmap_id\":75,\"ruleset_id\":0,\"beatmap\":{{\"checksum\":\"0123456789abcdef0123456789abcdef\",\"difficulty_rating\":5.25,\"beatmapset_id\":750,\"status\":\"ranked\",\"version\":\"history\",\"beatmapset\":{{\"artist\":\"fixture\",\"title\":\"kept\",\"creator\":\"mapper\"}}}}}}]}}", .{host_id});
    defer std.testing.allocator.free(room_body);

    {
        var manager = Manager.init(std.testing.allocator, std.testing.io);
        defer manager.deinit();
        try manager.bindStore(&store);
        const created = try manager.restCreateRoom(std.testing.allocator, host, room_body);
        std.testing.allocator.free(created);
        const joined = try manager.restJoinRoom(std.testing.allocator, guest, 1, "");
        std.testing.allocator.free(joined);
        try manager.recordRoomScore(host_id, 1, 8, .{ .score_id = 201, .total_score = 700_000, .accuracy = 0.97, .max_combo = 400, .passed = true });
        try manager.recordRoomScore(guest_id, 1, 8, .{ .score_id = 202, .total_score = 900_000, .accuracy = 0.99, .max_combo = 500, .passed = true });
        try manager.restPartRoom(guest_id, 1);
        try manager.restCloseRoom(host_id, 1);
    }

    var reopened = Manager.init(std.testing.allocator, std.testing.io);
    defer reopened.deinit();
    try reopened.bindStore(&store);
    const archived = (try reopened.roomsJson(std.testing.allocator, 1, null)).?;
    defer std.testing.allocator.free(archived);
    var parsed_room = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, archived, .{});
    defer parsed_room.deinit();
    try std.testing.expectEqualStrings("ended", parsed_room.value.object.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 2), parsed_room.value.object.get("recent_participants").?.array.items.len);
    const leaderboard = (try reopened.roomLeaderboardJson(std.testing.allocator, 0, 1)).?;
    defer std.testing.allocator.free(leaderboard);
    var parsed_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, leaderboard, .{});
    defer parsed_board.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed_board.value.object.get("leaderboard").?.array.items.len);
    try std.testing.expectEqual(@as(i64, guest_id), parsed_board.value.object.get("leaderboard").?.array.items[0].object.get("user_id").?.integer);
    const ended = (try reopened.roomsJson(std.testing.allocator, null, try roomListFilter(host_id, "ended", null, "realtime"))).?;
    defer std.testing.allocator.free(ended);
    var parsed_ended = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, ended, .{});
    defer parsed_ended.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_ended.value.array.items.len);

    const next = try reopened.restCreateRoom(std.testing.allocator, host, room_body);
    defer std.testing.allocator.free(next);
    var parsed_next = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, next, .{});
    defer parsed_next.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed_next.value.object.get("id").?.integer);
}

test "multiplayer room cards use stored beatmap metadata and cover ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/multiplayer-metadata.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,star_rating) VALUES(75,900,'0123456789abcdef0123456789abcdef','stored artist','stored song','stored diff','stored mapper',3,6.25)");
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    const host: domain.User = .{ .id = 4, .name = "raya", .safe_name = "raya", .country = .{ 'A', 'U' } };
    const room_body =
        \\{"name":"metadata","type":"head_to_head","queue_mode":"host_only","playlist":[{"id":1,"owner_id":4,"beatmap_id":75,"ruleset_id":0,"beatmap":{"checksum":"0123456789abcdef0123456789abcdef","difficulty_rating":1,"beatmapset_id":75,"status":"pending","version":"stale","beatmapset":{"artist":"stale","title":"stale","creator":"stale"}}}]}
    ;
    const created = try manager.restCreateRoom(std.testing.allocator, host, room_body);
    defer std.testing.allocator.free(created);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, created, .{});
    defer parsed.deinit();
    const beatmap = parsed.value.object.get("playlist").?.array.items[0].object.get("beatmap").?.object;
    try std.testing.expectEqual(@as(i64, 900), beatmap.get("beatmapset_id").?.integer);
    try std.testing.expectEqualStrings("stored diff", beatmap.get("version").?.string);
    try std.testing.expectEqualStrings("ranked", beatmap.get("status").?.string);
    try std.testing.expectApproxEqAbs(@as(f64, 6.25), beatmap.get("difficulty_rating").?.float, 0.0001);
    const set = beatmap.get("beatmapset").?.object;
    try std.testing.expectEqualStrings("stored artist", set.get("artist").?.string);
    try std.testing.expectEqualStrings("stored song", set.get("title").?.string);
    try std.testing.expectEqualStrings("stored mapper", set.get("creator").?.string);
    try std.testing.expectEqualStrings("https://assets.kai.ovh/beatmaps/900/covers/cover.jpg", set.get("covers").?.object.get("cover").?.string);

    var client_room: Room = .{ .id = 0, .settings = .{}, .host_id = host.id, .host_country = host.country };
    try client_room.settings.name.set("client snapshot");
    client_room.settings.playlist_item_id = 1;
    try client_room.settings.auto_start.set(&.{0xc0});
    try client_room.host_name.set(host.name);
    var client_item: PlaylistItem = .{ .id = 1, .owner_id = host.id, .beatmap_id = 75 };
    try client_item.required_mods.set(&.{0x90});
    try client_item.allowed_mods.set(&.{0x90});
    try client_item.played_at.set(&.{0xc0});
    client_room.playlist[0] = client_item;
    client_room.playlist_count = 1;
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try writeRoom(.{ .writer = &encoded.writer }, &client_room, 0);
    var connection: Connection = .{ .allocator = std.testing.allocator, .user_id = host.id, .user_country = host.country, .io = std.testing.io };
    try connection.user_name.set(host.name);
    const decoded = try parseRoom(std.testing.allocator, encoded.written(), &connection);
    defer std.testing.allocator.destroy(decoded);
    try manager.hydrateRoom(decoded);
    var client_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer client_json.deinit();
    try writeRoomJson(&client_json.writer, decoded);
    var parsed_client = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, client_json.written(), .{});
    defer parsed_client.deinit();
    const client_beatmap = parsed_client.value.object.get("playlist").?.array.items[0].object.get("beatmap").?.object;
    try std.testing.expectEqual(@as(i64, 900), client_beatmap.get("beatmapset_id").?.integer);
    try std.testing.expectEqualStrings("stored song", client_beatmap.get("beatmapset").?.object.get("title").?.string);
    try std.testing.expectEqualStrings("stored diff", client_beatmap.get("version").?.string);
}

test "signalr accepts messagepack handshake bytes independent of websocket opcode" {
    try std.testing.expect(validSignalRHandshake(std.testing.allocator, "{\"protocol\":\"messagepack\",\"version\":1}\x1e"));
    try std.testing.expect(validSignalRHandshake(std.testing.allocator, "{\"version\":1,\"protocol\":\"messagepack\"}\x1e"));
    try std.testing.expect(!validSignalRHandshake(std.testing.allocator, "{\"protocol\":\"json\",\"version\":1}\x1e"));
    try std.testing.expect(!validSignalRHandshake(std.testing.allocator, "{\"protocol\":\"messagepack\",\"version\":1}"));
}

test "matchmaking lobby status leaves unavailable ratings empty" {
    const frame = try eventLobbyStatusOwned(std.testing.allocator, &.{ 4, 7 });
    defer std.testing.allocator.free(frame);
    var prefix_len: usize = 0;
    while (frame[prefix_len] & 0x80 != 0) prefix_len += 1;
    prefix_len += 1;
    var reader: MessagePackReader = .{ .data = frame[prefix_len..] };
    try std.testing.expectEqual(@as(usize, 6), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 1), try reader.integer());
    try std.testing.expectEqual(@as(usize, 0), try reader.mapLen());
    try reader.skip(0);
    try std.testing.expectEqualStrings("MatchmakingLobbyStatusChanged", try reader.string());
    try std.testing.expectEqual(@as(usize, 1), try reader.arrayLen());
    try std.testing.expectEqual(@as(usize, 4), try reader.arrayLen());
    try std.testing.expectEqual(@as(usize, 2), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 4), try reader.integer());
    try std.testing.expectEqual(@as(i64, 7), try reader.integer());
    try std.testing.expectEqual(@as(usize, 0), try reader.arrayLen());
    try std.testing.expectEqual(@as(?i64, null), try reader.nullableInteger());
    try std.testing.expectEqual(@as(usize, 0), try reader.arrayLen());
}

test "matchmaking duel event uses canonical guid and complete pool" {
    const duel_id = "00112233-4455-6677-8899-aabbccddeeff";
    const frame = try eventMatchmakingDuelIssuedOwned(std.testing.allocator, duel_id, 4, 102, 1, 1);
    defer std.testing.allocator.free(frame);
    var prefix_len: usize = 0;
    while (frame[prefix_len] & 0x80 != 0) prefix_len += 1;
    prefix_len += 1;
    var reader: MessagePackReader = .{ .data = frame[prefix_len..] };
    try std.testing.expectEqual(@as(usize, 6), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 1), try reader.integer());
    try std.testing.expectEqual(@as(usize, 0), try reader.mapLen());
    try reader.skip(0);
    try std.testing.expectEqualStrings("MatchmakingDuelIssued", try reader.string());
    try std.testing.expectEqual(@as(usize, 1), try reader.arrayLen());
    try std.testing.expectEqual(@as(usize, 3), try reader.arrayLen());
    try std.testing.expectEqualStrings(duel_id, try reader.string());
    try std.testing.expectEqual(@as(i64, 4), try reader.integer());
    try std.testing.expectEqual(@as(usize, 5), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 102), try reader.integer());
    try std.testing.expectEqual(@as(i64, 1), try reader.integer());
    try std.testing.expectEqual(@as(i64, 0), try reader.integer());
    try std.testing.expectEqualStrings("ranked play", try reader.string());
    try std.testing.expectEqual(@as(i64, 1), try reader.integer());
}

test "matchmaking placements use lower-equal ties and aggregate round points" {
    var state: MatchmakingState = .{};
    state.current_round = 2;
    state.user_count = 2;
    state.users[0] = .{ .id = 10 };
    state.users[1] = .{ .id = 20 };
    state.users[0].?.rounds[0] = .{ .round = 1, .total_score = 500, .passed = true };
    state.users[1].?.rounds[0] = .{ .round = 1, .total_score = 500, .passed = false };
    state.users[0].?.rounds[1] = .{ .round = 2, .total_score = 100, .passed = true };
    state.users[1].?.rounds[1] = .{ .round = 2, .total_score = 900, .passed = true };

    recomputeMatchmakingPlacements(&state);

    try std.testing.expectEqual(@as(u8, 2), state.users[0].?.rounds[0].?.placement);
    try std.testing.expectEqual(@as(u8, 2), state.users[1].?.rounds[0].?.placement);
    try std.testing.expectEqual(@as(i32, 27), state.users[1].?.points);
    try std.testing.expectEqual(@as(i32, 24), state.users[0].?.points);
    try std.testing.expectEqual(@as(?u8, 1), state.users[1].?.placement);
    try std.testing.expectEqual(@as(?u8, 2), state.users[0].?.placement);
}

test "ranked play state uses the official union and damage contract" {
    var ranked: RankedPlayState = .{};
    ranked.stage = ranked_stage.results;
    ranked.current_round = 1;
    ranked.active_user_id = 10;
    ranked.user_count = 2;
    ranked.users[0] = .{ .id = 10, .total_score = 900_000, .submitted = true };
    ranked.users[1] = .{ .id = 20, .total_score = 400_000, .submitted = true };
    rankedFinishRound(&ranked);
    try std.testing.expectEqual(@as(?i32, 10), ranked.round_winner_id);
    try std.testing.expectEqual(@as(i32, 1), ranked.users[0].?.rounds_won);
    try std.testing.expect(ranked.users[1].?.life < 1_000_000);
    try std.testing.expect(ranked.users[1].?.damage.?.damage >= 50_000);

    var room: Room = .{
        .id = 7,
        .settings = .{},
        .host_id = 3,
        .ranked_play = ranked,
    };
    try room.settings.name.set("ranked test");
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeMatchState(.{ .writer = &output.writer }, &room);
    var reader: MessagePackReader = .{ .data = output.written() };
    try std.testing.expectEqual(@as(usize, 2), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 2), try reader.integer());
    try std.testing.expectEqual(@as(usize, 7), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, ranked_stage.results), try reader.integer());
    try std.testing.expectEqual(@as(i64, 1), try reader.integer());
}

test "ranked pick countdown uses the pinned client union and timespan ticks" {
    const countdown: RankedStageCountdown = .{ .id = 17, .deadline_ms = 35_000, .stage = ranked_stage.card_play };
    const frame = try eventRankedCountdownStartedOwned(std.testing.allocator, countdown, 5_000);
    defer std.testing.allocator.free(frame);
    var prefix_len: usize = 0;
    while (frame[prefix_len] & 0x80 != 0) prefix_len += 1;
    prefix_len += 1;
    var reader: MessagePackReader = .{ .data = frame[prefix_len..] };
    try std.testing.expectEqual(@as(usize, 6), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 1), try reader.integer());
    try std.testing.expectEqual(@as(usize, 0), try reader.mapLen());
    try reader.skip(0);
    try std.testing.expectEqualStrings("MatchEvent", try reader.string());
    try std.testing.expectEqual(@as(usize, 1), try reader.arrayLen());
    try std.testing.expectEqual(@as(usize, 2), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 0), try reader.integer());
    try std.testing.expectEqual(@as(usize, 1), try reader.arrayLen());
    try std.testing.expectEqual(@as(usize, 2), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 4), try reader.integer());
    try std.testing.expectEqual(@as(usize, 3), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 17), try reader.integer());
    try std.testing.expectEqual(@as(i64, 300_000_000), try reader.integer());
    try std.testing.expectEqual(@as(i64, ranked_stage.card_play), try reader.integer());
    try std.testing.expectEqual(@as(usize, 0), try reader.arrayLen());

    var room: Room = .{ .id = 9, .settings = .{}, .host_id = 4, .ranked_play = .{} };
    try room.settings.name.set("rejoining pick");
    try room.settings.auto_start.set(&.{0xc0});
    room.ranked_play.?.pick_countdown = .{ .id = 18, .deadline_ms = 20_000, .stage = ranked_stage.card_play };
    var snapshot: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer snapshot.deinit();
    try writeRoom(.{ .writer = &snapshot.writer }, &room, 5_000);
    var snapshot_reader: MessagePackReader = .{ .data = snapshot.written() };
    try std.testing.expectEqual(@as(usize, 9), try snapshot_reader.arrayLen());
    for (0..7) |_| try snapshot_reader.skip(0);
    try std.testing.expectEqual(@as(usize, 1), try snapshot_reader.arrayLen());
    try std.testing.expectEqual(@as(usize, 2), try snapshot_reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 4), try snapshot_reader.integer());
    try std.testing.expectEqual(@as(usize, 3), try snapshot_reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 18), try snapshot_reader.integer());
    try std.testing.expectEqual(@as(i64, 150_000_000), try snapshot_reader.integer());
    try std.testing.expectEqual(@as(i64, ranked_stage.card_play), try snapshot_reader.integer());
}

test "expired ranked pick advances once with a deterministic card" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const room = try std.testing.allocator.create(Room);
    room.* = .{ .id = 9, .settings = .{}, .host_id = 4, .ranked_play = .{} };
    try room.settings.name.set("ranked timeout");
    try room.settings.auto_start.set(&.{0xc0});
    var item: PlaylistItem = .{ .id = 51, .owner_id = 4, .beatmap_id = 75 };
    try item.required_mods.set(&.{0x90});
    try item.allowed_mods.set(&.{0x90});
    try item.played_at.set(&.{0xc0});
    room.playlist[0] = item;
    room.playlist_count = 1;
    const ranked = &room.ranked_play.?;
    ranked.stage = ranked_stage.card_play;
    ranked.current_round = 1;
    ranked.active_user_id = 4;
    ranked.user_count = 1;
    ranked.users[0] = .{ .id = 4 };
    var card: RankedCard = .{ .playlist_item_id = 51 };
    card.id.setText("00112233-4455-6677-8899-aabbccddeeff");
    ranked.users[0].?.hand[0] = card;
    ranked.users[0].?.hand_count = 1;
    ranked.pick_countdown = .{ .id = 3, .deadline_ms = 1_000, .stage = ranked_stage.card_play };
    manager.rooms[0] = room;

    try std.testing.expectEqual(@as(usize, 0), try manager.advanceExpiredRankedPicks(999));
    try std.testing.expectEqual(@as(usize, 1), try manager.advanceExpiredRankedPicks(1_000));
    try std.testing.expectEqual(@as(u8, ranked_stage.finish_card_play), room.ranked_play.?.stage);
    try std.testing.expectEqual(@as(i64, 51), room.settings.playlist_item_id);
    try std.testing.expectEqualStrings(card.id.slice(), room.ranked_play.?.played_card.?.id.slice());
    try std.testing.expect(room.ranked_play.?.pick_countdown == null);
    try std.testing.expectEqual(@as(usize, 0), try manager.advanceExpiredRankedPicks(2_000));
}

test "ranked card parser accepts canonical guids and rejects duplicates" {
    const first = "00112233-4455-6677-8899-aabbccddeeff";
    const second = "ffeeddcc-bbaa-9988-7766-554433221100";
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try pack.array(2);
    try pack.array(1);
    try pack.string(first);
    try pack.array(1);
    try pack.string(second);
    var cards: [ranked_hand_size][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try parseRankedCardList(output.written(), &cards));
    try std.testing.expectEqualStrings(first, cards[0]);

    output.clearRetainingCapacity();
    try pack.array(2);
    try pack.array(1);
    try pack.string(first);
    try pack.array(1);
    try pack.string(first);
    try std.testing.expectError(error.InvalidRankedPlayCard, parseRankedCardList(output.written(), &cards));
}
