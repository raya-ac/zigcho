const std = @import("std");
const domain = @import("domain.zig");
const lazer = @import("lazer.zig");
const storage = @import("runtime_storage.zig");
const beatmap_sync = @import("beatmap_sync.zig");
const multiplayer_fixed = @import("lazer_multiplayer/fixed.zig");
const multiplayer_model = @import("lazer_multiplayer/model.zig");

pub const max_rooms = 64;
const max_pending_archives = max_rooms * 2;

fn publicCountry(user: domain.User) [2]u8 {
    return if (user.show_country) user.country else .{ 'X', 'X' };
}
pub const Activity = enum { lobby, queue, multiplayer, playing };
pub const max_connections = 128;
pub const max_users = multiplayer_model.max_users;
pub const max_playlist = multiplayer_model.max_playlist;
pub const max_matchmaking_maps = multiplayer_model.max_matchmaking_maps;
// A playlist room may accept up to 1,000 attempts from each of its 16 users.
// Keep that whole supported contract available for the eventual archive rather
// than silently rotating older attempts out of the room history.
pub const max_room_scores = max_users * 1000;
pub const max_room_participants = 128;
pub const matchmaking_rounds = multiplayer_model.matchmaking_rounds;
const ranked_player_count = multiplayer_model.ranked_player_count;
const ranked_hand_size = multiplayer_model.ranked_hand_size;
const max_ranked_cards = multiplayer_model.max_ranked_cards;
const max_hub_message = 60 * 1024;
const ranked_pick_seconds: i64 = 30;
const pending_match_timeout_seconds: i64 = 30;
const multiplayer_score_grace_seconds: i64 = 5 * 60;
const timespan_ticks_per_millisecond = multiplayer_model.timespan_ticks_per_millisecond;
const timespan_ticks_per_second: i64 = std.time.ms_per_s * timespan_ticks_per_millisecond;

const matchmaking_stage = multiplayer_model.matchmaking_stage;
const ranked_stage = multiplayer_model.ranked_stage;

pub const RoomScorePath = struct {
    room_id: i64,
    playlist_item_id: i64,
    token_id: ?i64,
};

pub const RoomUserPath = struct { room_id: i64, user_id: i32 };
pub const RoomUserScorePath = struct { room_id: i64, playlist_item_id: i64, user_id: i32 };

pub const RoomListMode = enum { open, ended, participated, owned };
pub const RoomListStatus = enum { idle, playing };
pub const RoomListKind = enum { any, playlists, realtime };
pub const RoomListFilter = struct {
    requester_id: i32,
    mode: RoomListMode = .open,
    status: ?RoomListStatus = null,
    kind: RoomListKind = .any,
    category: []const u8 = "",
};

pub fn roomListFilter(requester_id: i32, mode: []const u8, status: ?[]const u8, category: []const u8) !RoomListFilter {
    const parsed_mode = std.meta.stringToEnum(RoomListMode, mode) orelse return error.InvalidRoomListFilter;
    const parsed_status: ?RoomListStatus = if (status) |value| std.meta.stringToEnum(RoomListStatus, value) orelse return error.InvalidRoomListFilter else null;
    if (category.len != 0 and !std.mem.eql(u8, category, "normal") and !std.mem.eql(u8, category, "realtime") and !std.mem.eql(u8, category, "spotlight") and !std.mem.eql(u8, category, "featured_artist")) return error.InvalidRoomListFilter;
    const kind: RoomListKind = if (std.mem.eql(u8, category, "realtime")) .realtime else .playlists;
    return .{ .requester_id = requester_id, .mode = parsed_mode, .status = parsed_status, .kind = kind, .category = if (kind == .realtime) "" else category };
}

fn archiveIncludesUser(allocator: std.mem.Allocator, participant_ids_json: []const u8, user_id: i32) bool {
    return archiveIncludesUserFallible(allocator, participant_ids_json, user_id) catch false;
}

fn archiveIncludesUserFallible(allocator: std.mem.Allocator, participant_ids_json: []const u8, user_id: i32) !bool {
    const parsed = try std.json.parseFromSlice([]i32, allocator, participant_ids_json, .{});
    defer parsed.deinit();
    return std.mem.indexOfScalar(i32, parsed.value, user_id) != null;
}

fn jsonInteger(value: ?std.json.Value) ?i64 {
    return switch (value orelse return null) {
        .integer => |integer| integer,
        else => null,
    };
}

fn jsonFloat(value: ?std.json.Value) ?f64 {
    return switch (value orelse return null) {
        .float => |number| number,
        .integer => |integer| @floatFromInt(integer),
        else => null,
    };
}

fn archivedScoreRecord(value: std.json.Value) ?RoomScoreRecord {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const score_id = jsonInteger(object.get("score_id")) orelse return null;
    const user_id = jsonInteger(object.get("user_id")) orelse return null;
    const playlist_item_id = jsonInteger(object.get("playlist_item_id")) orelse return null;
    const total_score = jsonInteger(object.get("total_score")) orelse return null;
    const max_combo = jsonInteger(object.get("max_combo")) orelse return null;
    const passed = switch (object.get("passed") orelse return null) {
        .bool => |flag| flag,
        else => return null,
    };
    if (score_id <= 0 or user_id <= 0 or user_id > std.math.maxInt(i32) or playlist_item_id <= 0 or max_combo < 0 or max_combo > std.math.maxInt(i32)) return null;
    return .{
        .score_id = score_id,
        .user_id = @intCast(user_id),
        .playlist_item_id = playlist_item_id,
        .total_score = total_score,
        .accuracy = jsonFloat(object.get("accuracy")) orelse return null,
        .max_combo = @intCast(max_combo),
        .passed = passed,
    };
}

fn archivedScoreTokenRecord(value: std.json.Value) ?RoomScoreTokenRecord {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const token_id = jsonInteger(object.get("token_id")) orelse return null;
    const user_id = jsonInteger(object.get("user_id")) orelse return null;
    const playlist_item_id = jsonInteger(object.get("playlist_item_id")) orelse return null;
    const score_id: ?i64 = if (object.get("score_id")) |score_value| switch (score_value) {
        .null => null,
        .integer => |id| if (id > 0) id else return null,
        else => return null,
    } else null;
    if (token_id <= 0 or user_id <= 0 or user_id > std.math.maxInt(i32) or playlist_item_id <= 0) return null;
    return .{ .token_id = token_id, .user_id = @intCast(user_id), .playlist_item_id = playlist_item_id, .score_id = score_id };
}

fn archivedScoreContext(allocator: std.mem.Allocator, room_json: []const u8, playlist_item_id: i64) !?RoomScoreContext {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, room_json, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const playlist = switch (root.get("playlist") orelse return null) {
        .array => |array| array,
        else => return null,
    };
    for (playlist.items) |value| {
        const item = switch (value) {
            .object => |object| object,
            else => continue,
        };
        if ((jsonInteger(item.get("id")) orelse continue) != playlist_item_id) continue;
        const beatmap_id = jsonInteger(item.get("beatmap_id")) orelse continue;
        const ruleset_id = jsonInteger(item.get("ruleset_id")) orelse continue;
        if (beatmap_id <= 0 or beatmap_id > std.math.maxInt(i32) or ruleset_id < 0 or ruleset_id > 3) return null;
        return .{ .beatmap_id = @intCast(beatmap_id), .ruleset_id = @intCast(ruleset_id) };
    }
    return null;
}

fn archivedScoreTokenBound(allocator: std.mem.Allocator, room_json: []const u8, token_id: i64, user_id: i32, playlist_item_id: i64) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, room_json, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidMultiplayerArchive,
    };
    const values = switch (root.get("zigcho_score_tokens") orelse return false) {
        .array => |array| array,
        else => return error.InvalidMultiplayerArchive,
    };
    if (values.items.len > max_room_scores) return error.InvalidMultiplayerArchive;
    var matched: ?bool = null;
    for (values.items) |value| {
        const token = archivedScoreTokenRecord(value) orelse return error.InvalidMultiplayerArchive;
        if (token.token_id != token_id) continue;
        if (matched != null) return error.InvalidMultiplayerArchive;
        matched = token.user_id == user_id and token.playlist_item_id == playlist_item_id;
    }
    return matched orelse false;
}

fn archivedRoomRealtime(allocator: std.mem.Allocator, room_json: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, room_json, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidMultiplayerArchive,
    };
    const category = switch (root.get("category") orelse return error.InvalidMultiplayerArchive) {
        .string => |value| value,
        else => return error.InvalidMultiplayerArchive,
    };
    if (std.mem.eql(u8, category, "realtime")) return true;
    if (std.mem.eql(u8, category, "normal")) return false;
    return error.InvalidMultiplayerArchive;
}

fn restoreArchivedPlaylist(root: *const std.json.ObjectMap, room: *Room) !void {
    const playlist = switch (root.get("playlist") orelse return error.InvalidMultiplayerArchive) {
        .array => |array| array,
        else => return error.InvalidMultiplayerArchive,
    };
    if (playlist.items.len == 0 or playlist.items.len > max_playlist) return error.InvalidMultiplayerArchive;
    for (playlist.items, 0..) |value, index| {
        const object = switch (value) {
            .object => |object| object,
            else => return error.InvalidMultiplayerArchive,
        };
        const id = jsonInteger(object.get("id")) orelse return error.InvalidMultiplayerArchive;
        const beatmap_id = jsonInteger(object.get("beatmap_id")) orelse return error.InvalidMultiplayerArchive;
        const ruleset_id = jsonInteger(object.get("ruleset_id")) orelse return error.InvalidMultiplayerArchive;
        const owner_id = jsonInteger(object.get("owner_id")) orelse 0;
        const order = jsonInteger(object.get("playlist_order")) orelse @as(i64, @intCast(index));
        const expired = if (object.get("expired")) |expired_value| switch (expired_value) {
            .bool => |expired| expired,
            else => return error.InvalidMultiplayerArchive,
        } else false;
        if (id <= 0 or beatmap_id <= 0 or beatmap_id > std.math.maxInt(i32) or ruleset_id < 0 or ruleset_id > 3 or owner_id < 0 or owner_id > std.math.maxInt(i32) or order < 0 or order > std.math.maxInt(u16)) return error.InvalidMultiplayerArchive;
        if (room.itemIndex(id) != null) return error.InvalidMultiplayerArchive;
        room.playlist[index] = .{
            .id = id,
            .owner_id = @intCast(owner_id),
            .beatmap_id = @intCast(beatmap_id),
            .ruleset_id = @intCast(ruleset_id),
            .expired = expired,
            .order = @intCast(order),
        };
        room.playlist_count += 1;
    }
    room.settings.playlist_item_id = room.playlist[0].?.id;
    if (root.get("current_playlist_item")) |current_value| switch (current_value) {
        .object => |current| if (jsonInteger(current.get("id"))) |current_id| {
            if (room.itemIndex(current_id) != null) room.settings.playlist_item_id = current_id;
        },
        .null => {},
        else => return error.InvalidMultiplayerArchive,
    };
}

fn archivedLeaderboardHasRows(allocator: std.mem.Allocator, leaderboard_json: []const u8) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, leaderboard_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidMultiplayerArchive,
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidMultiplayerArchive,
    };
    return switch (root.get("leaderboard") orelse return error.InvalidMultiplayerArchive) {
        .array => |rows| rows.items.len != 0,
        else => error.InvalidMultiplayerArchive,
    };
}

fn archivedScores(allocator: std.mem.Allocator, room_json: []const u8, playlist_item_id: i64, visitor: anytype) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, room_json, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return,
    };
    const records = switch (root.get("zigcho_score_records") orelse return) {
        .array => |array| array,
        else => return,
    };
    for (records.items) |value| {
        const score = archivedScoreRecord(value) orelse continue;
        if (score.playlist_item_id == playlist_item_id) try visitor.visit(score);
    }
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
    token_id: ?i64 = null,
    score_id: i64,
    total_score: i64,
    accuracy: f64,
    max_combo: i32,
    passed: bool,
};

const RoomScoreTokenRecord = struct {
    token_id: i64,
    user_id: i32,
    playlist_item_id: i64,
    score_id: ?i64 = null,
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

pub const room_score_around_limit = 10;

pub const RoomScoreRanking = struct {
    position: usize,
    higher_ids: [room_score_around_limit]i64 = [_]i64{0} ** room_score_around_limit,
    higher_count: usize = 0,
    lower_ids: [room_score_around_limit]i64 = [_]i64{0} ** room_score_around_limit,
    lower_count: usize = 0,
};

const RoomPersistence = enum { none, archive, checkpoint };

fn scoreRanksBefore(left: RoomScoreRecord, right: RoomScoreRecord) bool {
    if (left.total_score != right.total_score) return left.total_score > right.total_score;
    return left.score_id < right.score_id;
}

fn sortRoomScores(scores: []RoomScoreRecord) void {
    std.mem.sort(RoomScoreRecord, scores, {}, struct {
        fn lessThan(_: void, left: RoomScoreRecord, right: RoomScoreRecord) bool {
            return scoreRanksBefore(left, right);
        }
    }.lessThan);
}

fn scoreEligibleForHighScore(score: RoomScoreRecord, realtime: bool) bool {
    // osu-web only promotes passing playlist scores, while realtime rooms also
    // retain failed results. A zero score never creates a high-score row.
    return score.total_score > 0 and (realtime or score.passed);
}

fn considerHighScore(allocator: std.mem.Allocator, high_scores: *std.ArrayList(RoomScoreRecord), score: RoomScoreRecord, realtime: bool) !void {
    if (!scoreEligibleForHighScore(score, realtime)) return;
    for (high_scores.items) |*existing| if (existing.user_id == score.user_id) {
        if (scoreRanksBefore(score, existing.*)) existing.* = score;
        return;
    };
    try high_scores.append(allocator, score);
}

fn rankingForScore(exact: RoomScoreRecord, high_scores: []const RoomScoreRecord) RoomScoreRanking {
    var ranking: RoomScoreRanking = .{ .position = 1 };
    for (high_scores) |score| ranking.position += @intFromBool(scoreRanksBefore(score, exact));

    // Official scoresAround excludes the exact score's user. Higher scores are
    // returned nearest-first in score_asc order; lower scores are nearest-first
    // in the normal score_desc order.
    var index = high_scores.len;
    while (index != 0 and ranking.higher_count < room_score_around_limit) {
        index -= 1;
        const score = high_scores[index];
        if (score.user_id == exact.user_id or !scoreRanksBefore(score, exact)) continue;
        ranking.higher_ids[ranking.higher_count] = score.score_id;
        ranking.higher_count += 1;
    }
    for (high_scores) |score| {
        if (ranking.lower_count == room_score_around_limit) break;
        if (score.user_id == exact.user_id or !scoreRanksBefore(exact, score)) continue;
        ranking.lower_ids[ranking.lower_count] = score.score_id;
        ranking.lower_count += 1;
    }
    return ranking;
}

const FixedRaw = multiplayer_fixed.FixedRaw;
const Raw64 = multiplayer_fixed.Raw64;
const Raw128 = multiplayer_fixed.Raw128;
const Raw2048 = multiplayer_fixed.Raw2048;
const Text64 = multiplayer_fixed.Text64;
const Text128 = multiplayer_fixed.Text128;
const Text256 = multiplayer_fixed.Text256;

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

fn checkedInteger(comptime T: type, value: i64) !T {
    return std.math.cast(T, value) orelse error.InvalidMultiplayerArguments;
}

fn checkedReaderInteger(comptime T: type, reader: *MessagePackReader) !T {
    return checkedInteger(T, try reader.integer());
}

fn checkedNullableInteger(comptime T: type, value: ?i64) !?T {
    return if (value) |integer| try checkedInteger(T, integer) else null;
}

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

const PlaylistItem = multiplayer_model.PlaylistItem;
const RoomUser = multiplayer_model.RoomUser;
const RoomParticipant = multiplayer_model.RoomParticipant;
const MatchmakingRound = multiplayer_model.MatchmakingRound;
const MatchmakingUser = multiplayer_model.MatchmakingUser;
const MatchmakingState = multiplayer_model.MatchmakingState;
const RankedCard = multiplayer_model.RankedCard;
const RankedDamage = multiplayer_model.RankedDamage;
const RankedUser = multiplayer_model.RankedUser;
const RankedPlayState = multiplayer_model.RankedPlayState;
const RankedResultContext = multiplayer_model.RankedResultContext;
const RankedStageCountdown = multiplayer_model.RankedStageCountdown;
const MatchStartCountdownState = multiplayer_model.MatchStartCountdownState;
const PlaylistAdvance = multiplayer_model.PlaylistAdvance;
const Settings = multiplayer_model.Settings;

const Room = struct {
    id: i64,
    state: u8 = 0,
    settings: Settings,
    starts_at: i64 = 0,
    ends_at: i64 = 0,
    max_attempts: ?i32 = null,
    locked: bool = false,
    match_start_countdown: ?MatchStartCountdownState = null,
    users: [max_users]?RoomUser = [_]?RoomUser{null} ** max_users,
    user_count: usize = 0,
    host_id: i32,
    host_name: Text64 = .{},
    host_country: [2]u8 = .{ 'X', 'X' },
    playlist: [max_playlist]?PlaylistItem = [_]?PlaylistItem{null} ** max_playlist,
    playlist_count: usize = 0,
    channel_id: i32 = 0,
    matchmaking: ?MatchmakingState = null,
    ranked_play: ?RankedPlayState = null,
    allowed_users: [max_users]i32 = [_]i32{0} ** max_users,
    allowed_user_count: usize = 0,
    score_tokens: std.ArrayList(RoomScoreTokenRecord) = .empty,
    scores: std.ArrayList(RoomScoreRecord) = .empty,
    participants: [max_room_participants]?RoomParticipant = [_]?RoomParticipant{null} ** max_room_participants,
    participant_count: usize = 0,
    ended: bool = false,

    fn deinit(self: *Room, allocator: std.mem.Allocator) void {
        self.score_tokens.deinit(allocator);
        self.scores.deinit(allocator);
    }

    fn scoreTokenIndex(self: *const Room, token_id: i64, user_id: i32, playlist_item_id: i64) ?usize {
        for (self.score_tokens.items, 0..) |token, index| {
            if (token.token_id == token_id and token.user_id == user_id and token.playlist_item_id == playlist_item_id) return index;
        }
        return null;
    }

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

const PendingMatch = multiplayer_model.PendingMatch;

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
    invocation_mutex: std.Io.Mutex = .init,
    write_mutex: std.Io.Mutex = .init,
    socket: ?*std.http.Server.WebSocket = null,
    alive: std.atomic.Value(bool) = .init(true),
    accepting_invocations: std.atomic.Value(bool) = .init(true),

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
        if (!self.alive.load(.acquire)) return;
        const socket = self.socket orelse return;
        socket.writeMessage(frame, .binary) catch {
            self.accepting_invocations.store(false, .release);
            self.alive.store(false, .release);
        };
    }

    fn close(self: *Connection) void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        self.accepting_invocations.store(false, .release);
        if (self.alive.load(.acquire)) if (self.socket) |socket| socket.writeMessage("", .connection_close) catch {};
        self.alive.store(false, .release);
        self.socket = null;
    }
};

const DisconnectEffects = struct {
    recipients: [max_connections]*Connection = undefined,
    recipient_count: usize = 0,
    left_user: ?RoomUser = null,
    new_host: ?i32 = null,
    ranked_ended: bool = false,
    ranked_room_id: ?i64 = null,
    ended_room: ?*Room = null,
    ranked_event: ?[]u8 = null,
    queue_peer: ?*Connection = null,
    queue_peer_left: bool = false,
    queue_pool_id: ?i32 = null,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transition_mutex: std.Io.Mutex = .init,
    lifecycle_mutex: std.Io.Mutex = .init,
    mutations_drained: std.Io.Condition = .init,
    active_mutations: usize = 0,
    terminal_shutdown: bool = false,
    archive_mutex: std.Io.Mutex = .init,
    store: ?*storage.Store = null,
    map_sync: ?*beatmap_sync.Sync = null,
    mutex: std.Io.Mutex = .init,
    rooms: [max_rooms]?*Room = [_]?*Room{null} ** max_rooms,
    pending_archives: [max_pending_archives]?*Room = [_]?*Room{null} ** max_pending_archives,
    connections: std.ArrayList(*Connection) = .empty,
    matchmaking_maps: [4][max_matchmaking_maps]?storage.Store.MatchmakingBeatmap = [_][max_matchmaking_maps]?storage.Store.MatchmakingBeatmap{[_]?storage.Store.MatchmakingBeatmap{null} ** max_matchmaking_maps} ** 4,
    matchmaking_map_counts: [4]usize = [_]usize{0} ** 4,
    pending_matches: [max_rooms]?PendingMatch = [_]?PendingMatch{null} ** max_rooms,
    next_room_id: i64 = 1,
    next_pending_match_id: u32 = 1,
    next_countdown_id: i32 = 1,
    enabled: std.atomic.Value(bool) = .init(true),
    quiescing: bool = false,
    shutting_down: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Manager {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn bindStore(self: *Manager, store: *storage.Store) !void {
        self.store = store;
        self.next_room_id = @max(self.next_room_id, try store.nextLazerMultiplayerRoomId());
        const checkpoints = try store.lazerMultiplayerRoomCheckpoints(self.allocator);
        defer {
            for (checkpoints) |*checkpoint| checkpoint.deinit();
            self.allocator.free(checkpoints);
        }
        const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
        for (checkpoints) |checkpoint| {
            const restored = restoreRoomCheckpoint(self.allocator, checkpoint.room_json, now_seconds) catch |err| {
                std.log.err("event=lazer_multiplayer_room_restore_failed room_id={d} error={t}", .{ checkpoint.room_id, err });
                continue;
            };
            const room = restored orelse continue;
            if (room.id != checkpoint.room_id) {
                room.deinit(self.allocator);
                self.allocator.destroy(room);
                std.log.err("event=lazer_multiplayer_room_restore_failed room_id={d} error=id_mismatch", .{checkpoint.room_id});
                continue;
            }
            if (roomHasEnded(room, now_seconds)) {
                try self.applyRoomCountryVisibility(room);
                room.ended = true;
                self.archiveRoom(room);
                continue;
            }
            const slot = self.roomSlotLocked() orelse {
                room.deinit(self.allocator);
                self.allocator.destroy(room);
                return error.MultiplayerRoomLimit;
            };
            self.hydrateRoom(room) catch |err| {
                room.deinit(self.allocator);
                self.allocator.destroy(room);
                // Keep the hidden checkpoint intact. A transient database or
                // beatmap hydration failure must not prevent the server from
                // starting, and a later restart can retry the same snapshot.
                std.log.warn("event=lazer_multiplayer_room_restore_hydration_failed room_id={d} error={t}", .{ checkpoint.room_id, err });
                continue;
            };
            try self.applyRoomCountryVisibility(room);
            store.deleteLazerMultiplayerRoomCheckpoint(room.id) catch |err| {
                room.deinit(self.allocator);
                self.allocator.destroy(room);
                return err;
            };
            self.rooms[slot] = room;
            std.log.info("event=lazer_multiplayer_room_restored room_id={d} participants={d} scores={d}", .{ room.id, room.participant_count, room.scores.items.len });
        }
    }

    pub fn bindBeatmapSync(self: *Manager, sync: *beatmap_sync.Sync) void {
        self.map_sync = sync;
    }

    pub fn isEnabled(self: *const Manager) bool {
        return self.enabled.load(.acquire);
    }

    const Mutation = struct {
        manager: *Manager,
        active: bool = true,

        fn deinit(self: *Mutation) void {
            if (!self.active) return;
            const manager = self.manager;
            manager.lifecycle_mutex.lockUncancelable(manager.io);
            std.debug.assert(manager.active_mutations != 0);
            manager.active_mutations -= 1;
            if (manager.active_mutations == 0) manager.mutations_drained.broadcast(manager.io);
            manager.lifecycle_mutex.unlock(manager.io);
            self.active = false;
        }
    };

    /// REST and maintenance mutations are not tied to a websocket invocation
    /// mutex. Track them explicitly so disable and shutdown can stop accepting
    /// new work, wait for already-accepted work, and only then drain/snapshot.
    fn beginMutation(self: *Manager) !Mutation {
        self.lifecycle_mutex.lockUncancelable(self.io);
        defer self.lifecycle_mutex.unlock(self.io);
        if (self.terminal_shutdown) return error.ServerShuttingDown;
        if (!self.isEnabled()) return error.MultiplayerDisabled;
        self.active_mutations += 1;
        return .{ .manager = self };
    }

    fn waitForMutationsLocked(self: *Manager) void {
        while (self.active_mutations != 0) self.mutations_drained.waitUncancelable(self.io, &self.lifecycle_mutex);
    }

    fn mutationAllowedLocked(self: *const Manager) bool {
        return !self.quiescing and !self.shutting_down and self.isEnabled();
    }

    const MutationGateError = error{ MultiplayerDisabled, ServerShuttingDown };

    fn blockedMutationErrorLocked(self: *const Manager) MutationGateError {
        return if (self.shutting_down) error.ServerShuttingDown else error.MultiplayerDisabled;
    }

    const DrainMode = enum { disable, shutdown };

    /// Apply the live multiplayer gate as well as the HTTP gate. The transition
    /// mutex remains held across the entire drain; Condition.wait deliberately
    /// releases lifecycle_mutex, so that mutex alone cannot serialize a racing
    /// re-enable or terminal shutdown.
    pub fn setEnabled(self: *Manager, enabled: bool) void {
        self.transition_mutex.lockUncancelable(self.io);
        defer self.transition_mutex.unlock(self.io);
        self.lifecycle_mutex.lockUncancelable(self.io);
        if (self.terminal_shutdown or self.isEnabled() == enabled) {
            self.lifecycle_mutex.unlock(self.io);
            return;
        }
        if (!enabled) {
            // Publish quiescing and the closed admission gate while holding the
            // manager mutex, so deferred socket teardown cannot detach a room
            // into an untracked gap between those two state changes.
            self.mutex.lockUncancelable(self.io);
            self.quiescing = true;
            self.enabled.store(false, .release);
            self.mutex.unlock(self.io);
        } else self.enabled.store(true, .release);
        self.lifecycle_mutex.unlock(self.io);
        if (enabled) return;
        self.drain(.disable);
    }

    fn drain(self: *Manager, mode: DrainMode) void {
        var targets: [max_connections]*Connection = undefined;
        var count: usize = 0;
        self.mutex.lockUncancelable(self.io);
        for (self.connections.items) |connection| {
            if (count == targets.len) break;
            connection.accepting_invocations.store(false, .release);
            connection.retain();
            targets[count] = connection;
            count += 1;
        }
        self.mutex.unlock(self.io);

        self.lifecycle_mutex.lockUncancelable(self.io);
        self.waitForMutationsLocked();
        self.lifecycle_mutex.unlock(self.io);

        for (targets[0..count]) |connection| {
            connection.invocation_mutex.lockUncancelable(self.io);
            connection.invocation_mutex.unlock(self.io);
        }

        const event_name = if (mode == .shutdown) "ServerShuttingDown" else "DisconnectRequested";
        const disconnect_frame = eventNoArgsOwned(self.allocator, event_name) catch null;
        defer if (disconnect_frame) |frame| self.allocator.free(frame);
        for (targets[0..count]) |connection| {
            if (connection.alive.load(.acquire)) if (disconnect_frame) |frame| connection.send(frame);
            connection.close();
        }

        var rooms: [max_rooms + max_pending_archives]*Room = undefined;
        var room_count: usize = 0;
        self.archive_mutex.lockUncancelable(self.io);
        self.mutex.lockUncancelable(self.io);
        for (&self.rooms) |*entry| if (entry.*) |room| {
            entry.* = null;
            room.ended = mode == .disable or room.settings.match_type != 0 or roomHasEnded(room, std.Io.Clock.real.now(self.io).toSeconds());
            rooms[room_count] = room;
            room_count += 1;
        };
        for (&self.pending_archives) |*entry| if (entry.*) |room| {
            entry.* = null;
            if (std.mem.indexOfScalar(*Room, rooms[0..room_count], room) == null) {
                rooms[room_count] = room;
                room_count += 1;
            }
        };
        for (targets[0..count]) |connection| {
            connection.room_id = null;
            connection.lobby_pool_id = null;
            connection.queue_pool_id = null;
            connection.pending_match_id = null;
        }
        if (mode == .disable) self.connections.clearRetainingCapacity();
        self.pending_matches = [_]?PendingMatch{null} ** max_rooms;
        self.mutex.unlock(self.io);
        for (rooms[0..room_count]) |room| {
            if (mode == .shutdown and room.settings.match_type == 0 and !room.ended)
                self.checkpointPlaylistRoom(room)
            else
                self.archiveRoomUnderGate(room);
        }
        self.archive_mutex.unlock(self.io);
        for (targets[0..count]) |connection| connection.release();

        if (mode == .disable) {
            self.mutex.lockUncancelable(self.io);
            self.quiescing = false;
            self.mutex.unlock(self.io);
        }
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
        item.total_length = info.total_length;
        item.hit_length = info.hit_length;
    }

    fn hydrateRoom(self: *Manager, room: *Room) !void {
        for (&room.playlist) |*entry| if (entry.*) |*item| try self.hydratePlaylistItem(item);
    }

    fn hydrateArchivedPlaylistItem(self: *Manager, arena: std.mem.Allocator, value: *std.json.Value) !void {
        const store = self.store orelse return;
        const item = switch (value.*) {
            .object => |*object| object,
            else => return,
        };
        const beatmap_value = item.getPtr("beatmap") orelse return;
        const beatmap = switch (beatmap_value.*) {
            .object => |*object| object,
            else => return,
        };
        const id_value = beatmap.get("id") orelse item.get("beatmap_id") orelse return;
        const beatmap_id: i32 = switch (id_value) {
            .integer => |id| if (id > 0 and id <= std.math.maxInt(i32)) @intCast(id) else return,
            else => return,
        };
        const info = (try store.beatmapInfoById(self.allocator, beatmap_id)) orelse return;
        defer self.allocator.free(info.artist);
        defer self.allocator.free(info.title);
        defer self.allocator.free(info.version);
        defer self.allocator.free(info.creator);
        try beatmap.put(arena, "total_length", .{ .integer = info.total_length });
        try beatmap.put(arena, "hit_length", .{ .integer = info.hit_length });
    }

    fn userCountryVisible(self: *Manager, user_id: i32) !bool {
        const store = self.store orelse return false;
        const visibility = (try store.lazerBatchUserVisibility(user_id)) orelse return false;
        return visibility.show_country;
    }

    fn applyRoomCountryVisibility(self: *Manager, room: *Room) !void {
        for (&room.users) |*entry| if (entry.*) |*user| {
            if (!try self.userCountryVisible(user.id)) user.country = .{ 'X', 'X' };
            if (user.id == room.host_id) room.host_country = user.country;
        };
        for (room.participants[0..room.participant_count]) |*entry| if (entry.*) |*participant| {
            if (!try self.userCountryVisible(participant.id)) participant.country = .{ 'X', 'X' };
        };
    }

    fn sanitizeArchivedApiUser(self: *Manager, arena: std.mem.Allocator, value: *std.json.Value) !void {
        const object = switch (value.*) {
            .object => |*object| object,
            else => return,
        };
        const id_value = object.get("id") orelse return;
        const user_id: i32 = switch (id_value) {
            .integer => |id| if (id > 0 and id <= std.math.maxInt(i32)) @intCast(id) else return,
            else => return,
        };
        if (!try self.userCountryVisible(user_id)) try object.put(arena, "country_code", .{ .string = "XX" });
    }

    fn normalizeArchivedPlaylistRulesets(arena: std.mem.Allocator, room: *std.json.ObjectMap) !void {
        const room_type = switch (room.get("type") orelse return) {
            .string => |value| value,
            else => return,
        };
        if (!std.mem.eql(u8, room_type, "playlists")) return;

        const stats = switch ((room.getPtr("playlist_item_stats") orelse return).*) {
            .object => |*object| object,
            else => return,
        };
        if (jsonInteger(stats.get("count_active")) != 0) return;
        const playlist = switch (room.get("playlist") orelse return) {
            .array => |array| array,
            else => return,
        };

        var present = [_]bool{false} ** 4;
        for (playlist.items) |item_value| {
            const item = switch (item_value) {
                .object => |object| object,
                else => continue,
            };
            const ruleset_id = jsonInteger(item.get("ruleset_id")) orelse continue;
            if (ruleset_id >= 0 and ruleset_id < present.len) present[@intCast(ruleset_id)] = true;
        }

        var rulesets = std.json.Array.init(arena);
        for (present, 0..) |included, ruleset_id| {
            if (included) try rulesets.append(.{ .integer = @intCast(ruleset_id) });
        }
        try stats.put(arena, "ruleset_ids", .{ .array = rulesets });
    }

    fn writeHydratedArchiveJson(self: *Manager, writer: *std.Io.Writer, room_json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, room_json, .{});
        defer parsed.deinit();
        const room = switch (parsed.value) {
            .object => |*object| object,
            else => return error.InvalidMultiplayerArchive,
        };
        if (room.getPtr("host")) |host| try self.sanitizeArchivedApiUser(parsed.arena.allocator(), host);
        if (room.getPtr("recent_participants")) |participants_value| switch (participants_value.*) {
            .array => |*participants| for (participants.items) |*participant| try self.sanitizeArchivedApiUser(parsed.arena.allocator(), participant),
            else => {},
        };
        if (room.getPtr("playlist")) |playlist_value| switch (playlist_value.*) {
            .array => |*playlist| for (playlist.items) |*item| try self.hydrateArchivedPlaylistItem(parsed.arena.allocator(), item),
            else => {},
        };
        try normalizeArchivedPlaylistRulesets(parsed.arena.allocator(), room);
        if (room.getPtr("current_playlist_item")) |item| try self.hydrateArchivedPlaylistItem(parsed.arena.allocator(), item);
        if (room.getPtr("status")) |status| switch (status.*) {
            .string => |value| {
                if (std.mem.eql(u8, value, "ended")) status.* = .{ .string = "idle" };
            },
            else => {},
        };
        // Room-token bindings are persistence metadata, not part of the public
        // osu-web room model. Never disclose unused score token identifiers.
        _ = room.orderedRemove("zigcho_score_tokens");
        try std.json.Stringify.value(parsed.value, .{}, writer);
    }

    fn writeSanitizedArchiveLeaderboardJson(self: *Manager, writer: *std.Io.Writer, leaderboard_json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, leaderboard_json, .{});
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |*object| object,
            else => return error.InvalidMultiplayerArchive,
        };
        if (root.getPtr("leaderboard")) |leaderboard_value| switch (leaderboard_value.*) {
            .array => |*entries| for (entries.items) |*entry| switch (entry.*) {
                .object => |*object| if (object.getPtr("user")) |user| try self.sanitizeArchivedApiUser(parsed.arena.allocator(), user),
                else => {},
            },
            else => {},
        };
        if (root.getPtr("user_score")) |score| switch (score.*) {
            .object => |*object| if (object.getPtr("user")) |user| try self.sanitizeArchivedApiUser(parsed.arena.allocator(), user),
            else => {},
        };
        try std.json.Stringify.value(parsed.value, .{}, writer);
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
        self.shutdown();
        for (&self.rooms) |*entry| if (entry.*) |room| {
            room.deinit(self.allocator);
            self.allocator.destroy(room);
        };
        for (&self.pending_archives) |*entry| if (entry.*) |room| {
            room.deinit(self.allocator);
            self.allocator.destroy(room);
        };
        for (self.connections.items) |connection| connection.release();
        self.connections.deinit(self.allocator);
    }

    /// Tell the pinned client that this is a planned interruption and archive
    /// every active room before the process gives up its sockets. This is
    /// idempotent so both the server shutdown path and deinit may call it.
    pub fn shutdown(self: *Manager) void {
        self.transition_mutex.lockUncancelable(self.io);
        defer self.transition_mutex.unlock(self.io);
        self.lifecycle_mutex.lockUncancelable(self.io);
        if (self.terminal_shutdown) {
            self.lifecycle_mutex.unlock(self.io);
            return;
        }
        // Allocation-failure fixtures deliberately mark the manager as already
        // shutting down so deinit only frees its in-memory ownership and does
        // not introduce best-effort serializer allocations outside the tested
        // operation. Preserve that established cleanup contract.
        self.mutex.lockUncancelable(self.io);
        const externally_quiesced = self.shutting_down;
        self.mutex.unlock(self.io);
        if (externally_quiesced) {
            self.terminal_shutdown = true;
            self.enabled.store(false, .release);
            self.lifecycle_mutex.unlock(self.io);
            return;
        }
        self.terminal_shutdown = true;
        self.mutex.lockUncancelable(self.io);
        self.quiescing = true;
        self.shutting_down = true;
        self.enabled.store(false, .release);
        self.mutex.unlock(self.io);
        self.lifecycle_mutex.unlock(self.io);
        self.drain(.shutdown);
        std.log.info("event=lazer_multiplayer_shutdown", .{});
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

    fn rankedResultContext(room: *const Room) !?RankedResultContext {
        const ranked = room.ranked_play orelse return null;
        if (ranked.stage != ranked_stage.ended or ranked.result_persisted) return null;
        const winner_id = ranked.winning_user_id orelse return null;
        var loser_id: ?i32 = null;
        for (ranked.users) |entry| if (entry) |user| if (user.id != winner_id) {
            if (loser_id != null) return error.InvalidRankedPlayResult;
            loser_id = user.id;
        };
        const loser = loser_id orelse return error.InvalidRankedPlayResult;
        const ruleset_id = ruleset: {
            for (room.playlist) |entry| if (entry) |item| break :ruleset item.ruleset_id;
            return error.InvalidRankedPlayResult;
        };
        return .{ .room_id = room.id, .ruleset_id = ruleset_id, .winner_id = winner_id, .loser_id = loser };
    }

    fn applyRankedResult(room: *Room, context: RankedResultContext, result: storage.Store.LazerRankedResult) !void {
        const ranked = if (room.ranked_play) |*state| state else return error.InvalidRankedPlayResult;
        if (ranked.result_persisted) return;
        if (room.id != context.room_id or ranked.stage != ranked_stage.ended or ranked.winning_user_id != context.winner_id) return error.RankedPlayResultConflict;
        for (&ranked.users) |*entry| if (entry.*) |*user| {
            if (user.id == context.winner_id) {
                user.rating = result.winner_rating_before;
                user.rating_after = result.winner_rating_after;
            } else if (user.id == context.loser_id) {
                user.rating = result.loser_rating_before;
                user.rating_after = result.loser_rating_after;
            }
        };
        ranked.result_persisted = true;
    }

    /// Persist a result for a detached room. The caller owns the room pointer
    /// (normally through the archive gate), so no manager mutex is needed.
    fn persistRankedResult(self: *Manager, room: *Room) !void {
        const store = self.store orelse return;
        const context = (try rankedResultContext(room)) orelse return;
        const result = try store.applyLazerRankedResult(context.room_id, context.ruleset_id, context.winner_id, context.loser_id);
        try applyRankedResult(room, context, result);
        std.log.info("event=lazer_ranked_rating_persisted room_id={d} ruleset_id={d} winner_id={d} loser_id={d} applied={s}", .{ context.room_id, context.ruleset_id, context.winner_id, context.loser_id, if (result.applied) "true" else "false" });
    }

    /// Capture only immutable ids under the manager mutex, settle the database
    /// without blocking unrelated rooms, then re-lock briefly to publish the
    /// authoritative ratings if this room is still live. If it was detached in
    /// the meantime, the archive path applies the same idempotent DB result.
    fn persistLiveRankedResult(self: *Manager, room_id: i64) !void {
        const store = self.store orelse return;
        self.mutex.lockUncancelable(self.io);
        const room = self.roomByIdLocked(room_id) orelse {
            self.mutex.unlock(self.io);
            return;
        };
        const context = rankedResultContext(room) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        } orelse {
            self.mutex.unlock(self.io);
            return;
        };
        self.mutex.unlock(self.io);

        const result = try store.applyLazerRankedResult(context.room_id, context.ruleset_id, context.winner_id, context.loser_id);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const current = self.roomByIdLocked(room_id) orelse return;
        try applyRankedResult(current, context, result);
        std.log.info("event=lazer_ranked_rating_persisted room_id={d} ruleset_id={d} winner_id={d} loser_id={d} applied={s}", .{ context.room_id, context.ruleset_id, context.winner_id, context.loser_id, if (result.applied) "true" else "false" });
    }

    fn rankedStateEventForRoom(self: *Manager, room_id: i64) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const room = self.roomByIdLocked(room_id) orelse return null;
        return try eventMatchStateOwned(self.allocator, room);
    }

    fn saveRoomSnapshot(self: *Manager, room: *Room, persistence: RoomPersistence) !void {
        const store = self.store orelse return error.StoreUnavailable;
        var room_output: std.Io.Writer.Allocating = .init(self.allocator);
        defer room_output.deinit();
        try writeRoomJson(&room_output.writer, room, 0, std.Io.Clock.real.now(self.io).toSeconds(), persistence);
        var leaderboard_output: std.Io.Writer.Allocating = .init(self.allocator);
        defer leaderboard_output.deinit();
        try writeRoomLeaderboardJson(self.allocator, &leaderboard_output.writer, room, 0);
        var participants_output: std.Io.Writer.Allocating = .init(self.allocator);
        defer participants_output.deinit();
        try participants_output.writer.writeByte('[');
        for (room.participants[0..room.participant_count], 0..) |entry, index| if (entry) |participant| {
            if (index != 0) try participants_output.writer.writeByte(',');
            try participants_output.writer.print("{d}", .{participant.id});
        };
        try participants_output.writer.writeByte(']');
        const owner_id = if (room.participant_count != 0) room.participants[0].?.id else room.host_id;
        try store.saveLazerMultiplayerRoomArchive(room.id, owner_id, roomCategory(room), room_output.written(), leaderboard_output.written(), participants_output.written());
    }

    fn queuePendingArchive(self: *Manager, room: *Room) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.store == null or self.shutting_down) return false;
        for (self.pending_archives) |entry| if (entry) |pending| if (pending == room) return true;
        for (&self.pending_archives) |*entry| if (entry.* == null) {
            entry.* = room;
            return true;
        };
        std.log.err("event=lazer_multiplayer_archive_retry_capacity_exhausted room_id={d}", .{room.id});
        return false;
    }

    fn removePendingArchive(self: *Manager, room: *Room) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (&self.pending_archives) |*entry| if (entry.* == room) {
            entry.* = null;
            return;
        };
    }

    fn discardRoom(self: *Manager, room: *Room) void {
        room.deinit(self.allocator);
        self.allocator.destroy(room);
    }

    fn archiveRoomUnderGate(self: *Manager, room: *Room) void {
        const retained = self.queuePendingArchive(room);
        room.ended = true;
        self.persistRankedResult(room) catch |err| {
            std.log.err("event=lazer_ranked_rating_archive_retry_failed room_id={d} error={t}", .{ room.id, err });
            if (!retained) self.discardRoom(room);
            return;
        };
        self.saveRoomSnapshot(room, .archive) catch |err| {
            std.log.warn("event=lazer_multiplayer_room_archive_failed room_id={d} error={t}", .{ room.id, err });
            if (!retained) self.discardRoom(room);
            return;
        };
        std.log.info("event=lazer_multiplayer_room_archived room_id={d} participants={d} scores={d}", .{ room.id, room.participant_count, room.scores.items.len });
        if (retained) self.removePendingArchive(room);
        self.discardRoom(room);
    }

    fn archiveRoom(self: *Manager, room: *Room) void {
        self.archive_mutex.lockUncancelable(self.io);
        defer self.archive_mutex.unlock(self.io);
        self.archiveRoomUnderGate(room);
    }

    fn checkpointPlaylistRoom(self: *Manager, room: *Room) void {
        defer {
            room.deinit(self.allocator);
            self.allocator.destroy(room);
        }
        self.saveRoomSnapshot(room, .checkpoint) catch |err| {
            std.log.err("event=lazer_multiplayer_room_checkpoint_failed room_id={d} error={t}", .{ room.id, err });
            return;
        };
        std.log.info("event=lazer_multiplayer_room_checkpointed room_id={d} participants={d} scores={d}", .{ room.id, room.participant_count, room.scores.items.len });
    }

    fn roomByIdLocked(self: *Manager, room_id: i64) ?*Room {
        for (self.rooms) |entry| if (entry) |room| if (room.id == room_id) return room;
        return null;
    }

    fn archivedRoomForParticipant(self: *Manager, allocator: std.mem.Allocator, room_id: i64, user_id: i32) !?storage.Store.MultiplayerRoomArchive {
        const store = self.store orelse return null;
        var archive = (try store.lazerMultiplayerRoomArchive(allocator, room_id)) orelse return null;
        if (!archiveIncludesUser(allocator, archive.participant_ids_json, user_id)) {
            archive.deinit();
            return null;
        }
        return archive;
    }

    fn roomSlotLocked(self: *Manager) ?usize {
        var owned: usize = 0;
        for (self.rooms) |entry| owned += @intFromBool(entry != null);
        for (self.pending_archives) |entry| owned += @intFromBool(entry != null);
        if (owned >= max_rooms) return null;
        for (self.rooms, 0..) |entry, index| if (entry == null) return index;
        return null;
    }

    fn connectionByUserLocked(self: *Manager, user_id: i32) ?*Connection {
        var found: ?*Connection = null;
        for (self.connections.items) |connection| {
            if (connection.alive.load(.acquire) and connection.user_id == user_id) found = connection;
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

    pub fn currentRoomId(self: *Manager, user_id: i32) ?i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.rooms) |entry| if (entry) |room| if (room.userIndex(user_id) != null) return room.id;
        return null;
    }

    pub const RuntimeCounts = struct {
        connections: usize,
        rooms: usize,
        queued: usize,
        pending_matches: usize,
    };

    pub fn runtimeCounts(self: *Manager) RuntimeCounts {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var counts: RuntimeCounts = .{ .connections = 0, .rooms = 0, .queued = 0, .pending_matches = 0 };
        for (self.connections.items) |connection| {
            if (!connection.alive.load(.acquire)) continue;
            counts.connections += 1;
            if (connection.queue_pool_id != null or connection.pending_match_id != null) counts.queued += 1;
        }
        for (self.rooms) |room| if (room != null) {
            counts.rooms += 1;
        };
        for (self.pending_matches) |pending| if (pending != null) {
            counts.pending_matches += 1;
        };
        return counts;
    }

    pub fn roomChannelAccess(self: *Manager, user_id: i32, channel_id: i64) ?i64 {
        const room_id = lazer.roomChannelRoom(channel_id) orelse return null;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const room = self.roomByIdLocked(room_id) orelse return null;
        if (room.channel_id != channel_id or room.userIndex(user_id) == null) return null;
        return room_id;
    }

    pub fn roomChannelUsersJson(self: *Manager, allocator: std.mem.Allocator, user_id: i32, channel_id: i64) !?[]u8 {
        const room_id = lazer.roomChannelRoom(channel_id) orelse return null;
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const room = self.roomByIdLocked(room_id) orelse return null;
        if (room.channel_id != channel_id or room.userIndex(user_id) == null) return null;
        try output.writer.writeByte('[');
        var written: usize = 0;
        for (room.users) |entry| if (entry) |participant| {
            if (written != 0) try output.writer.writeByte(',');
            try writeApiUserJson(&output.writer, participant.id, participant.name.slice(), participant.country);
            written += 1;
        };
        try output.writer.writeByte(']');
        return try output.toOwnedSlice();
    }

    pub fn archiveExpiredRooms(self: *Manager, now_seconds: i64) usize {
        var mutation = self.beginMutation() catch return 0;
        defer mutation.deinit();
        self.archive_mutex.lockUncancelable(self.io);
        defer self.archive_mutex.unlock(self.io);
        var expired: [max_rooms + max_pending_archives]*Room = undefined;
        var expired_count: usize = 0;
        self.mutex.lockUncancelable(self.io);
        if (!self.mutationAllowedLocked()) {
            self.mutex.unlock(self.io);
            return 0;
        }
        for (&self.rooms) |*entry| if (entry.*) |room| {
            if (!room.ended and (room.ends_at <= 0 or now_seconds < room.ends_at)) continue;
            entry.* = null;
            room.ended = true;
            for (self.connections.items) |connection| {
                if (connection.room_id == room.id) connection.room_id = null;
            }
            expired[expired_count] = room;
            expired_count += 1;
        };
        for (self.pending_archives) |entry| if (entry) |room| {
            expired[expired_count] = room;
            expired_count += 1;
        };
        self.mutex.unlock(self.io);
        for (expired[0..expired_count]) |room| self.archiveRoomUnderGate(room);
        return expired_count;
    }

    pub fn expirePendingMatches(self: *Manager, now_seconds: i64) usize {
        var mutation = self.beginMutation() catch return 0;
        defer mutation.deinit();
        var targets: [max_connections]*Connection = undefined;
        var target_count: usize = 0;
        var pools: [max_rooms]i32 = undefined;
        var pool_count: usize = 0;
        var expired_count: usize = 0;
        self.mutex.lockUncancelable(self.io);
        if (!self.mutationAllowedLocked()) {
            self.mutex.unlock(self.io);
            return 0;
        }
        for (&self.pending_matches) |*entry| if (entry.*) |pending| {
            if (now_seconds < pending.created_at or now_seconds - pending.created_at < pending_match_timeout_seconds) continue;
            for (pending.users, 0..) |user_id, index| {
                if (!pending.joined[index]) continue;
                const connection = self.connectionByUserLocked(user_id) orelse continue;
                if (connection.pending_match_id != pending.id) continue;
                connection.pending_match_id = null;
                connection.queue_pool_id = null;
                connection.retain();
                targets[target_count] = connection;
                target_count += 1;
            }
            if (std.mem.indexOfScalar(i32, pools[0..pool_count], pending.pool_id) == null) {
                pools[pool_count] = pending.pool_id;
                pool_count += 1;
            }
            entry.* = null;
            expired_count += 1;
        };
        self.mutex.unlock(self.io);
        defer releaseRecipients(targets[0..target_count]);
        const left = eventNoArgsOwned(self.allocator, "MatchmakingQueueLeft") catch null;
        defer if (left) |frame| self.allocator.free(frame);
        if (left) |frame| sendRecipients(targets[0..target_count], frame);
        for (pools[0..pool_count]) |pool_id| self.publishLobbyStatus(pool_id) catch {};
        return expired_count;
    }

    pub fn disconnectUser(self: *Manager, user_id: i32) bool {
        var mutation_optional: ?Mutation = self.beginMutation() catch null;
        defer if (mutation_optional) |*mutation| mutation.deinit();
        var targets: [max_connections]*Connection = undefined;
        var count: usize = 0;
        self.mutex.lockUncancelable(self.io);
        for (self.connections.items) |connection| {
            if (!connection.alive.load(.acquire) or connection.user_id != user_id or count == targets.len) continue;
            connection.retain();
            targets[count] = connection;
            count += 1;
        }
        self.mutex.unlock(self.io);
        const disconnect_frame = eventNoArgsOwned(self.allocator, "DisconnectRequested") catch null;
        defer if (disconnect_frame) |frame| self.allocator.free(frame);
        var disconnected = false;
        for (targets[0..count]) |connection| {
            var effects: DisconnectEffects = .{};
            connection.invocation_mutex.lockUncancelable(self.io);
            self.mutex.lockUncancelable(self.io);
            const still_current = std.mem.indexOfScalar(*Connection, self.connections.items, connection) != null and
                connection.alive.load(.acquire) and connection.user_id == user_id;
            if (still_current) {
                // Wait for this identity's final invocation, close the gate,
                // and detach every room/queue/list membership before takeover
                // returns. A frame parsed concurrently will fail its second
                // accepting_invocations check when the gate is released.
                connection.accepting_invocations.store(false, .release);
                if (self.quiescing)
                    self.detachConnectionForDrainLocked(connection)
                else
                    self.detachConnectionLocked(connection, &effects);
                disconnected = true;
            }
            self.mutex.unlock(self.io);
            connection.invocation_mutex.unlock(self.io);
            if (still_current) {
                if (disconnect_frame) |frame| connection.send(frame);
                connection.close();
                self.finishDisconnect(&effects);
            }
            connection.release();
        }
        return disconnected;
    }

    pub fn setUserCountryVisibility(self: *Manager, user_id: i32, country: [2]u8, visible: bool) void {
        const projected = if (visible) country else .{ 'X', 'X' };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.connections.items) |connection| {
            if (connection.user_id == user_id) connection.user_country = projected;
        }
        for (self.rooms) |entry| if (entry) |room| {
            if (room.host_id == user_id) room.host_country = projected;
            for (&room.users) |*room_user| if (room_user.*) |*value| {
                if (value.id == user_id) value.country = projected;
            };
            for (room.participants[0..room.participant_count]) |*participant| if (participant.*) |*value| {
                if (value.id == user_id) value.country = projected;
            };
        };
    }

    pub fn restCreateRoom(self: *Manager, allocator: std.mem.Allocator, user: domain.User, body: []const u8) ![]u8 {
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
        const room = try parseRestRoom(self.allocator, user, body, now_seconds, false);
        errdefer {
            room.deinit(self.allocator);
            self.allocator.destroy(room);
        }
        try self.hydrateRoom(room);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.mutationAllowedLocked()) return self.blockedMutationErrorLocked();
        for (self.rooms) |entry| if (entry) |existing| if (existing.userIndex(user.id) != null) return error.AlreadyInMultiplayerRoom;
        const slot = self.roomSlotLocked() orelse return error.MultiplayerRoomLimit;
        room.id = self.next_room_id;
        room.channel_id = @intCast(lazer.roomChannelId(room.id) orelse return error.MultiplayerRoomLimit);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        writeRoomJson(&output.writer, room, user.id, now_seconds, .none) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
        const response = try output.toOwnedSlice();
        self.next_room_id += 1;
        if (room.settings.match_type != 0) {
            if (self.connectionByUserLocked(user.id)) |connection| connection.room_id = room.id;
        }
        self.rooms[slot] = room;
        std.log.info("event=lazer_multiplayer_rest_room_created room_id={d} host_id={d}", .{ room.id, user.id });
        return response;
    }

    pub fn restJoinRoom(self: *Manager, allocator: std.mem.Allocator, user: domain.User, room_id: i64, password: []const u8) ![]u8 {
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.mutationAllowedLocked()) return self.blockedMutationErrorLocked();
        var added_slot: ?usize = null;
        errdefer if (added_slot) |slot| {
            const room = self.roomByIdLocked(room_id) orelse unreachable;
            room.users[slot] = null;
            room.user_count -= 1;
        };
        for (self.rooms) |entry| if (entry) |existing| if (existing.id != room_id and existing.userIndex(user.id) != null) return error.AlreadyInMultiplayerRoom;
        const room = self.roomByIdLocked(room_id) orelse return error.MultiplayerRoomNotFound;
        if (roomHasEnded(room, std.Io.Clock.real.now(self.io).toSeconds())) return error.MultiplayerRoomNotFound;
        if (!std.mem.eql(u8, room.settings.password.slice(), password)) return error.InvalidMultiplayerPassword;
        if (!room.userAllowed(user.id)) return error.MultiplayerPermissionDenied;
        if (room.userIndex(user.id) == null) {
            const limit: usize = room.settings.max_participants orelse max_users;
            if (room.user_count >= limit) return error.MultiplayerRoomFull;
            const slot = for (room.users, 0..) |entry, index| {
                if (entry == null) break index;
            } else return error.MultiplayerRoomFull;
            var joined = try defaultRoomUser(user.id, user.name, publicCountry(user));
            if (room.settings.match_type == 2) joined.team_id = nextTeamId(room);
            room.users[slot] = joined;
            room.user_count += 1;
            added_slot = slot;
        }
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        writeRoomJson(&output.writer, room, user.id, std.Io.Clock.real.now(self.io).toSeconds(), .none) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
        const response = try output.toOwnedSlice();
        if (added_slot != null) room.rememberParticipant(room.users[added_slot.?].?);
        if (room.settings.match_type != 0) {
            if (self.connectionByUserLocked(user.id)) |connection| connection.room_id = room_id;
        }
        std.log.info("event=lazer_multiplayer_rest_room_joined room_id={d} user_id={d}", .{ room_id, user.id });
        return response;
    }

    pub fn restPartRoom(self: *Manager, user_id: i32, room_id: i64) !void {
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        self.mutex.lockUncancelable(self.io);
        if (!self.mutationAllowedLocked()) {
            const err = self.blockedMutationErrorLocked();
            self.mutex.unlock(self.io);
            return err;
        }
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
        if (room.user_count == 0 and room.settings.match_type != 0) {
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
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        self.mutex.lockUncancelable(self.io);
        if (!self.mutationAllowedLocked()) {
            const err = self.blockedMutationErrorLocked();
            self.mutex.unlock(self.io);
            return err;
        }
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
            if (!connection.alive.load(.acquire) or connection == exclude or connection.room_id != room_id) continue;
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
        if (!self.isEnabled()) {
            self.mutex.lockUncancelable(self.io);
            const terminal = self.shutting_down;
            self.mutex.unlock(self.io);
            return if (terminal) error.ServerShuttingDown else error.MultiplayerDisabled;
        }
        if (user.name.len == 0 or user.name.len > 64) return error.InvalidMultiplayerUser;
        const connection = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(connection);
        connection.* = .{
            .allocator = self.allocator,
            .user_id = user.id,
            .user_country = publicCountry(user),
            .io = self.io,
            .socket = socket,
        };
        try connection.user_name.set(user.name);
        while (true) {
            var replaced: ?*Connection = null;
            self.mutex.lockUncancelable(self.io);
            if (self.shutting_down or !self.isEnabled()) {
                self.mutex.unlock(self.io);
                return if (self.shutting_down) error.ServerShuttingDown else error.MultiplayerDisabled;
            }
            for (self.connections.items) |existing| {
                if (!existing.alive.load(.acquire) or existing.user_id != user.id) continue;
                existing.retain();
                replaced = existing;
                break;
            }
            if (replaced == null) {
                if (self.connections.items.len >= max_connections) {
                    self.mutex.unlock(self.io);
                    return error.MultiplayerConnectionLimit;
                }
                self.connections.append(self.allocator, connection) catch |err| {
                    self.mutex.unlock(self.io);
                    return err;
                };
                self.mutex.unlock(self.io);
                std.log.info("event=lazer_multiplayer_connected user_id={d}", .{user.id});
                return connection;
            }
            self.mutex.unlock(self.io);

            const existing = replaced.?;
            // Wait only for this identity's final invocation boundary. Other
            // users and rooms continue independently, and no socket write is
            // performed while this gate is held.
            existing.invocation_mutex.lockUncancelable(self.io);
            self.mutex.lockUncancelable(self.io);
            const index = std.mem.indexOfScalar(*Connection, self.connections.items, existing);
            if (self.shutting_down or self.quiescing or !self.isEnabled()) {
                const terminal = self.shutting_down;
                self.mutex.unlock(self.io);
                existing.invocation_mutex.unlock(self.io);
                existing.release();
                return if (terminal) error.ServerShuttingDown else error.MultiplayerDisabled;
            }
            if (index == null or !existing.alive.load(.acquire) or existing.user_id != user.id) {
                self.mutex.unlock(self.io);
                existing.invocation_mutex.unlock(self.io);
                existing.release();
                continue;
            }
            existing.accepting_invocations.store(false, .release);
            connection.room_id = existing.room_id;
            connection.lobby_pool_id = existing.lobby_pool_id;
            connection.queue_pool_id = existing.queue_pool_id;
            connection.pending_match_id = existing.pending_match_id;
            existing.room_id = null;
            existing.lobby_pool_id = null;
            existing.queue_pool_id = null;
            existing.pending_match_id = null;
            self.connections.items[index.?] = connection;
            self.mutex.unlock(self.io);
            existing.invocation_mutex.unlock(self.io);

            if (eventNoArgsOwned(self.allocator, "DisconnectRequested")) |frame| {
                defer self.allocator.free(frame);
                existing.send(frame);
            } else |_| {}
            existing.close();
            existing.release();
            std.log.info("event=lazer_multiplayer_connection_replaced user_id={d}", .{user.id});
            std.log.info("event=lazer_multiplayer_connected user_id={d}", .{user.id});
            return connection;
        }
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

    fn detachConnectionLocked(self: *Manager, connection: *Connection, effects: *DisconnectEffects) void {
        effects.queue_pool_id = connection.queue_pool_id;
        if (connection.pending_match_id) |match_id| {
            if (self.pendingMatchByIdLocked(match_id)) |pending| {
                const index = pending.userIndex(connection.user_id) orelse 0;
                const peer_index = 1 - index;
                effects.queue_pool_id = pending.pool_id;
                if (pending.joined[peer_index]) {
                    const peer_id = pending.users[peer_index];
                    if (self.connectionByUserLocked(peer_id)) |peer| {
                        peer.pending_match_id = null;
                        peer.queue_pool_id = if (pending.is_duel) null else pending.pool_id;
                        peer.retain();
                        effects.queue_peer = peer;
                        effects.queue_peer_left = pending.is_duel;
                    }
                }
            }
            self.clearPendingMatchLocked(match_id);
        }
        connection.pending_match_id = null;
        connection.queue_pool_id = null;
        connection.lobby_pool_id = null;
        const room_id = connection.room_id;
        effects.recipient_count = self.leaveLocked(connection, &effects.recipients, &effects.left_user, &effects.new_host, &effects.ranked_ended, &effects.ended_room);
        if (effects.ranked_ended) effects.ranked_room_id = room_id;
        if (effects.ranked_ended) if (room_id) |id| if (self.roomByIdLocked(id)) |room| {
            effects.ranked_event = eventMatchStateOwned(self.allocator, room) catch null;
        };
        self.removeConnectionLocked(connection);
    }

    /// The active lifecycle transition owns the final room snapshot. A socket
    /// read which wakes after that boundary may remove its connection object,
    /// but must not erase the participant or archive the room ahead of it.
    fn detachConnectionForDrainLocked(self: *Manager, connection: *Connection) void {
        connection.room_id = null;
        connection.lobby_pool_id = null;
        connection.queue_pool_id = null;
        connection.pending_match_id = null;
        self.removeConnectionLocked(connection);
    }

    fn finishDisconnect(self: *Manager, effects: *DisconnectEffects) void {
        defer releaseRecipients(effects.recipients[0..effects.recipient_count]);
        defer if (effects.queue_peer) |peer| peer.release();
        defer if (effects.ranked_event) |event| self.allocator.free(event);
        if (effects.ranked_ended and effects.ended_room == null) if (effects.ranked_room_id) |room_id| {
            self.persistLiveRankedResult(room_id) catch |err| std.log.err("event=lazer_ranked_rating_persist_failed room_id={d} error={t}", .{ room_id, err });
            if (self.rankedStateEventForRoom(room_id) catch null) |updated| {
                if (effects.ranked_event) |old| self.allocator.free(old);
                effects.ranked_event = updated;
            }
        };
        if (effects.ended_room) |ended| self.archiveRoom(ended);
        if (effects.queue_peer) |peer| {
            const frame_result = if (effects.queue_peer_left)
                eventNoArgsOwned(self.allocator, "MatchmakingQueueLeft")
            else
                eventQueueStatusOwned(self.allocator, 0);
            if (frame_result) |frame| {
                defer self.allocator.free(frame);
                peer.send(frame);
            } else |_| {}
        }
        if (effects.queue_pool_id) |pool| self.publishLobbyStatus(pool) catch {};
        if (effects.left_user) |user| {
            if (eventUserOwned(self.allocator, "UserLeft", user)) |frame| {
                defer self.allocator.free(frame);
                sendRecipients(effects.recipients[0..effects.recipient_count], frame);
            } else |_| {}
        }
        if (effects.ranked_event) |event| sendRecipients(effects.recipients[0..effects.recipient_count], event);
        if (effects.new_host) |host_id| {
            if (eventIntegersOwned(self.allocator, "HostChanged", &.{host_id})) |frame| {
                defer self.allocator.free(frame);
                sendRecipients(effects.recipients[0..effects.recipient_count], frame);
            } else |_| {}
        }
    }

    fn disconnect(self: *Manager, connection: *Connection) void {
        var mutation_optional: ?Mutation = self.beginMutation() catch null;
        defer if (mutation_optional) |*mutation| mutation.deinit();
        connection.close();
        var effects: DisconnectEffects = .{};
        self.mutex.lockUncancelable(self.io);
        const quiescing = self.quiescing;
        if (quiescing)
            self.detachConnectionForDrainLocked(connection)
        else
            self.detachConnectionLocked(connection, &effects);
        self.mutex.unlock(self.io);
        if (!quiescing) self.finishDisconnect(&effects);
        std.log.info("event=lazer_multiplayer_disconnected user_id={d}", .{connection.user_id});
        connection.release();
    }

    pub fn roomsJson(self: *Manager, allocator: std.mem.Allocator, only_room_id: ?i64, filter: ?RoomListFilter, requester_id: i32) !?[]u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
        self.mutex.lockUncancelable(self.io);
        if (only_room_id) |room_id| {
            if (self.roomByIdLocked(room_id)) |room| {
                writeRoomJson(&output.writer, room, requester_id, now_seconds, .none) catch |err| {
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
            try self.writeHydratedArchiveJson(&output.writer, archive.room_json);
            return try output.toOwnedSlice();
        }
        output.writer.writeByte('[') catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        var written: usize = 0;
        for (self.rooms) |entry| if (entry) |room| {
            if (filter) |value| {
                const ended = roomHasEnded(room, now_seconds);
                if (value.mode == .ended and !ended) continue;
                if (value.mode != .ended and ended) continue;
                if (value.mode == .owned and room.host_id != value.requester_id) continue;
                if (value.mode == .participated and room.participantIndex(value.requester_id) == null) continue;
                if (value.status) |wanted| if ((wanted == .idle) != (ended or room.state == 0)) continue;
                if (value.kind == .playlists and room.settings.match_type != 0) continue;
                if (value.kind == .realtime and room.settings.match_type == 0) continue;
                if (value.category.len != 0 and !std.mem.eql(u8, value.category, roomCategory(room))) continue;
            }
            if (written != 0) output.writer.writeByte(',') catch |err| {
                self.mutex.unlock(self.io);
                return err;
            };
            writeRoomJson(&output.writer, room, requester_id, now_seconds, .none) catch |err| {
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
                    if (value.kind == .playlists and !std.mem.eql(u8, archive.category, "normal")) continue;
                    if (value.kind == .realtime and !std.mem.eql(u8, archive.category, "realtime")) continue;
                    // Completed rooms are exposed to lazer as idle because the
                    // pinned RoomStatus model only has idle and playing.
                    if (value.status == .playing) continue;
                    if (value.category.len != 0 and !std.mem.eql(u8, value.category, archive.category)) continue;
                    if (value.mode == .owned and archive.owner_id != value.requester_id) continue;
                    if (value.mode == .participated and !archiveIncludesUser(allocator, archive.participant_ids_json, value.requester_id)) continue;
                }
                if (written != 0) try output.writer.writeByte(',');
                try self.writeHydratedArchiveJson(&output.writer, archive.room_json);
                written += 1;
            }
        };
        try output.writer.writeByte(']');
        return try output.toOwnedSlice();
    }

    pub fn scoreContext(self: *Manager, user_id: i32, room_id: i64, playlist_item_id: i64) ?RoomScoreContext {
        self.mutex.lockUncancelable(self.io);
        if (self.roomByIdLocked(room_id)) |room| {
            if (roomHasEnded(room, std.Io.Clock.real.now(self.io).toSeconds()) or room.userIndex(user_id) == null) {
                self.mutex.unlock(self.io);
                return null;
            }
            const item_index = room.itemIndex(playlist_item_id) orelse {
                self.mutex.unlock(self.io);
                return null;
            };
            const item = room.playlist[item_index].?;
            self.mutex.unlock(self.io);
            return .{ .beatmap_id = item.beatmap_id, .ruleset_id = item.ruleset_id };
        }
        self.mutex.unlock(self.io);
        var archive = (self.archivedRoomForParticipant(self.allocator, room_id, user_id) catch return null) orelse return null;
        defer archive.deinit();
        return archivedScoreContext(self.allocator, archive.room_json, playlist_item_id) catch null;
    }

    /// New score tokens may only be minted while the room is live.
    pub fn scoreTokenContext(self: *Manager, user_id: i32, room_id: i64, playlist_item_id: i64) ?RoomScoreContext {
        if (!self.isEnabled()) return null;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.mutationAllowedLocked()) return null;
        const room = self.roomByIdLocked(room_id) orelse return null;
        if (roomHasEnded(room, std.Io.Clock.real.now(self.io).toSeconds()) or room.userIndex(user_id) == null) return null;
        const item_index = room.itemIndex(playlist_item_id) orelse return null;
        const item = room.playlist[item_index].?;
        return .{ .beatmap_id = item.beatmap_id, .ruleset_id = item.ruleset_id };
    }

    /// Bind the opaque database token to the room and playlist item before it
    /// is returned to the client. This is deliberately kept in the room
    /// snapshot so an already-issued token can finish across a graceful
    /// restart or after the room is archived.
    pub fn bindRoomScoreToken(self: *Manager, user_id: i32, room_id: i64, playlist_item_id: i64, token_id: i64) !void {
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        if (token_id <= 0) return error.InvalidMultiplayerScoreToken;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.mutationAllowedLocked()) return self.blockedMutationErrorLocked();
        const room = self.roomByIdLocked(room_id) orelse return error.MultiplayerRoomNotFound;
        if (roomHasEnded(room, std.Io.Clock.real.now(self.io).toSeconds())) return error.MultiplayerRoomNotFound;
        if (room.userIndex(user_id) == null or room.itemIndex(playlist_item_id) == null) return error.MultiplayerPermissionDenied;
        for (room.score_tokens.items) |token| if (token.token_id == token_id) {
            if (token.user_id == user_id and token.playlist_item_id == playlist_item_id) return;
            return error.InvalidMultiplayerScoreToken;
        };
        if (room.score_tokens.items.len >= max_room_scores) return error.MultiplayerScoreTokenLimit;
        try room.score_tokens.append(self.allocator, .{ .token_id = token_id, .user_id = user_id, .playlist_item_id = playlist_item_id });
    }

    /// A token minted before the room ended may complete during osu-web's
    /// bounded five-minute grace period. The participant and playlist checks
    /// remain identical to archived score reads.
    pub fn scoreSubmissionContext(self: *Manager, user_id: i32, room_id: i64, playlist_item_id: i64, token_id: i64) ?RoomScoreContext {
        if (!self.isEnabled()) return null;
        const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
        _ = self.archiveExpiredRooms(now_seconds);
        self.mutex.lockUncancelable(self.io);
        if (!self.mutationAllowedLocked()) {
            self.mutex.unlock(self.io);
            return null;
        }
        if (self.roomByIdLocked(room_id)) |room| {
            if (!roomHasEnded(room, now_seconds) and room.userIndex(user_id) != null and room.scoreTokenIndex(token_id, user_id, playlist_item_id) != null) {
                const item = room.playlist[
                    room.itemIndex(playlist_item_id) orelse {
                        self.mutex.unlock(self.io);
                        return null;
                    }
                ].?;
                self.mutex.unlock(self.io);
                return .{ .beatmap_id = item.beatmap_id, .ruleset_id = item.ruleset_id };
            }
            self.mutex.unlock(self.io);
            return null;
        }
        self.mutex.unlock(self.io);
        var archive = (self.archivedRoomForParticipant(self.allocator, room_id, user_id) catch return null) orelse return null;
        defer archive.deinit();
        if (now_seconds > std.math.add(i64, archive.ended_at, multiplayer_score_grace_seconds) catch return null) return null;
        if (!(archivedScoreTokenBound(self.allocator, archive.room_json, token_id, user_id, playlist_item_id) catch return null)) return null;
        return archivedScoreContext(self.allocator, archive.room_json, playlist_item_id) catch null;
    }

    pub fn roomScoreIds(self: *Manager, allocator: std.mem.Allocator, user_id: i32, room_id: i64, playlist_item_id: i64) !?[]i64 {
        self.mutex.lockUncancelable(self.io);
        if (self.roomByIdLocked(room_id)) |room| {
            if (room.userIndex(user_id) == null or room.itemIndex(playlist_item_id) == null) {
                self.mutex.unlock(self.io);
                return null;
            }
            var ids: std.ArrayList(i64) = .empty;
            errdefer ids.deinit(allocator);
            var high_scores: std.ArrayList(RoomScoreRecord) = .empty;
            defer high_scores.deinit(allocator);
            const realtime = room.settings.match_type != 0;
            for (room.scores.items) |score| if (score.playlist_item_id == playlist_item_id) considerHighScore(allocator, &high_scores, score, realtime) catch |err| {
                self.mutex.unlock(self.io);
                return err;
            };
            self.mutex.unlock(self.io);
            sortRoomScores(high_scores.items);
            for (high_scores.items) |score| try ids.append(allocator, score.score_id);
            return @as(?[]i64, try ids.toOwnedSlice(allocator));
        }
        self.mutex.unlock(self.io);
        var archive = (try self.archivedRoomForParticipant(allocator, room_id, user_id)) orelse return null;
        defer archive.deinit();
        if ((try archivedScoreContext(allocator, archive.room_json, playlist_item_id)) == null) return null;
        const realtime = try archivedRoomRealtime(allocator, archive.room_json);
        var ids: std.ArrayList(i64) = .empty;
        errdefer ids.deinit(allocator);
        const HighScoreCollector = struct {
            allocator: std.mem.Allocator,
            realtime: bool,
            records: std.ArrayList(RoomScoreRecord) = .empty,

            fn visit(visitor: *@This(), score: RoomScoreRecord) !void {
                try considerHighScore(visitor.allocator, &visitor.records, score, visitor.realtime);
            }
        };
        var collector: HighScoreCollector = .{ .allocator = allocator, .realtime = realtime };
        defer collector.records.deinit(allocator);
        try archivedScores(allocator, archive.room_json, playlist_item_id, &collector);
        sortRoomScores(collector.records.items);
        for (collector.records.items) |score| try ids.append(allocator, score.score_id);
        return @as(?[]i64, try ids.toOwnedSlice(allocator));
    }

    pub fn roomScoreIdForUser(self: *Manager, requester_id: i32, room_id: i64, playlist_item_id: i64, user_id: i32) ?i64 {
        self.mutex.lockUncancelable(self.io);
        if (self.roomByIdLocked(room_id)) |room| {
            if (room.userIndex(requester_id) == null or room.itemIndex(playlist_item_id) == null) {
                self.mutex.unlock(self.io);
                return null;
            }
            var best: ?RoomScoreRecord = null;
            for (room.scores.items) |score| if (score.playlist_item_id == playlist_item_id and score.user_id == user_id) {
                if (!scoreEligibleForHighScore(score, room.settings.match_type != 0)) continue;
                if (best == null or score.total_score > best.?.total_score or (score.total_score == best.?.total_score and score.score_id < best.?.score_id)) best = score;
            };
            self.mutex.unlock(self.io);
            return if (best) |score| score.score_id else null;
        }
        self.mutex.unlock(self.io);
        var archive = (self.archivedRoomForParticipant(self.allocator, room_id, requester_id) catch return null) orelse return null;
        defer archive.deinit();
        if ((archivedScoreContext(self.allocator, archive.room_json, playlist_item_id) catch return null) == null) return null;
        const realtime = archivedRoomRealtime(self.allocator, archive.room_json) catch return null;
        const Finder = struct {
            user_id: i32,
            realtime: bool,
            best: ?RoomScoreRecord = null,

            fn visit(visitor: *@This(), score: RoomScoreRecord) !void {
                if (score.user_id != visitor.user_id or !scoreEligibleForHighScore(score, visitor.realtime)) return;
                if (visitor.best == null or score.total_score > visitor.best.?.total_score or (score.total_score == visitor.best.?.total_score and score.score_id < visitor.best.?.score_id)) visitor.best = score;
            }
        };
        var finder: Finder = .{ .user_id = user_id, .realtime = realtime };
        archivedScores(self.allocator, archive.room_json, playlist_item_id, &finder) catch return null;
        return if (finder.best) |score| score.score_id else null;
    }

    pub fn roomScoreRanking(self: *Manager, allocator: std.mem.Allocator, requester_id: i32, room_id: i64, playlist_item_id: i64, score_id: i64) !?RoomScoreRanking {
        self.mutex.lockUncancelable(self.io);
        if (self.roomByIdLocked(room_id)) |room| {
            if (room.userIndex(requester_id) == null or room.itemIndex(playlist_item_id) == null) {
                self.mutex.unlock(self.io);
                return null;
            }
            var exact: ?RoomScoreRecord = null;
            var high_scores: std.ArrayList(RoomScoreRecord) = .empty;
            defer high_scores.deinit(allocator);
            const realtime = room.settings.match_type != 0;
            for (room.scores.items) |score| if (score.playlist_item_id == playlist_item_id) {
                if (score.score_id == score_id) exact = score;
                considerHighScore(allocator, &high_scores, score, realtime) catch |err| {
                    self.mutex.unlock(self.io);
                    return err;
                };
            };
            self.mutex.unlock(self.io);
            const found = exact orelse return null;
            sortRoomScores(high_scores.items);
            return rankingForScore(found, high_scores.items);
        }
        self.mutex.unlock(self.io);
        var archive = (try self.archivedRoomForParticipant(allocator, room_id, requester_id)) orelse return null;
        defer archive.deinit();
        if ((try archivedScoreContext(allocator, archive.room_json, playlist_item_id)) == null) return null;
        const realtime = try archivedRoomRealtime(allocator, archive.room_json);
        const RankingCollector = struct {
            allocator: std.mem.Allocator,
            realtime: bool,
            score_id: i64,
            exact: ?RoomScoreRecord = null,
            high_scores: std.ArrayList(RoomScoreRecord) = .empty,

            fn visit(visitor: *@This(), score: RoomScoreRecord) !void {
                if (score.score_id == visitor.score_id) visitor.exact = score;
                try considerHighScore(visitor.allocator, &visitor.high_scores, score, visitor.realtime);
            }
        };
        var collector: RankingCollector = .{ .allocator = allocator, .realtime = realtime, .score_id = score_id };
        defer collector.high_scores.deinit(allocator);
        try archivedScores(allocator, archive.room_json, playlist_item_id, &collector);
        const found = collector.exact orelse return null;
        sortRoomScores(collector.high_scores.items);
        return rankingForScore(found, collector.high_scores.items);
    }

    pub fn roomContainsScore(self: *Manager, requester_id: i32, room_id: i64, playlist_item_id: i64, score_id: i64) bool {
        self.mutex.lockUncancelable(self.io);
        if (self.roomByIdLocked(room_id)) |room| {
            if (room.userIndex(requester_id) == null or room.itemIndex(playlist_item_id) == null) {
                self.mutex.unlock(self.io);
                return false;
            }
            for (room.scores.items) |score| if (score.playlist_item_id == playlist_item_id and score.score_id == score_id) {
                self.mutex.unlock(self.io);
                return true;
            };
            self.mutex.unlock(self.io);
            return false;
        }
        self.mutex.unlock(self.io);
        var archive = (self.archivedRoomForParticipant(self.allocator, room_id, requester_id) catch return false) orelse return false;
        defer archive.deinit();
        if ((archivedScoreContext(self.allocator, archive.room_json, playlist_item_id) catch return false) == null) return false;
        const Finder = struct {
            score_id: i64,
            found: bool = false,

            fn visit(visitor: *@This(), score: RoomScoreRecord) !void {
                if (score.score_id == visitor.score_id) visitor.found = true;
            }
        };
        var finder: Finder = .{ .score_id = score_id };
        archivedScores(self.allocator, archive.room_json, playlist_item_id, &finder) catch return false;
        return finder.found;
    }

    pub fn roomLeaderboardJson(self: *Manager, allocator: std.mem.Allocator, requester_id: i32, room_id: i64) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        if (self.roomByIdLocked(room_id)) |room| {
            var output: std.Io.Writer.Allocating = .init(allocator);
            errdefer output.deinit();
            writeRoomLeaderboardJson(allocator, &output.writer, room, requester_id) catch |err| {
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
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try self.writeSanitizedArchiveLeaderboardJson(&output.writer, archive.leaderboard_json);
        return @as(?[]u8, try output.toOwnedSlice());
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
        while (connection.alive.load(.acquire)) {
            const message = socket.readSmallMessage() catch return;
            switch (message.opcode) {
                .ping => {
                    connection.write_mutex.lockUncancelable(connection.io);
                    defer connection.write_mutex.unlock(connection.io);
                    if (connection.alive.load(.acquire)) try socket.writeMessage(message.data, .pong);
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
        if (!self.isEnabled() or !connection.alive.load(.acquire) or !connection.accepting_invocations.load(.acquire)) return error.ConnectionClose;
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
        connection.invocation_mutex.lockUncancelable(self.io);
        // The connection may have been replaced while this frame was parsed
        // and waiting for the invocation gate, or multiplayer may have crossed
        // its disable/shutdown boundary in the meantime.
        if (!self.isEnabled() or !connection.alive.load(.acquire) or !connection.accepting_invocations.load(.acquire)) {
            connection.invocation_mutex.unlock(self.io);
            return error.ConnectionClose;
        }
        const invocation_result = self.handleInvocation(connection, invocation_id, target, argument_count, &reader);
        connection.invocation_mutex.unlock(self.io);
        invocation_result catch |err| {
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
            return self.transferHost(connection, invocation_id, try checkedReaderInteger(i32, reader));
        }
        if (std.mem.eql(u8, target, "KickUser")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.kickUser(connection, invocation_id, try checkedReaderInteger(i32, reader));
        }
        if (std.mem.eql(u8, target, "ChangeSettings")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.changeSettings(connection, invocation_id, try reader.raw());
        }
        if (std.mem.eql(u8, target, "ChangeState")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.changeState(connection, invocation_id, try checkedReaderInteger(u8, reader));
        }
        if (std.mem.eql(u8, target, "ChangeBeatmapAvailability")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.changeAvailability(connection, invocation_id, try reader.raw());
        }
        if (std.mem.eql(u8, target, "ChangeUserStyle")) {
            if (argument_count != 2) return error.InvalidMultiplayerArguments;
            const beatmap_id = try reader.nullableInteger();
            const ruleset_id = try reader.nullableInteger();
            return self.changeStyle(connection, invocation_id, try checkedNullableInteger(i32, beatmap_id), try checkedNullableInteger(i32, ruleset_id));
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
            return self.invitePlayer(connection, invocation_id, try checkedReaderInteger(i32, reader));
        }
        if (std.mem.eql(u8, target, "SendMatchRequest")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.sendMatchRequest(connection, invocation_id, try reader.raw());
        }
        if (std.mem.eql(u8, target, "GetMatchmakingPools") or std.mem.eql(u8, target, "GetMatchmakingPoolsOfType")) {
            if (argument_count > 1) return error.InvalidMultiplayerArguments;
            const pool_type: u8 = if (argument_count == 1) try checkedReaderInteger(u8, reader) else 0;
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
            return self.joinMatchmakingLobby(connection, invocation_id, try checkedReaderInteger(i32, &request_reader));
        }
        if (std.mem.eql(u8, target, "MatchmakingLeaveLobby")) {
            if (argument_count != 0) return error.InvalidMultiplayerArguments;
            return self.leaveMatchmakingLobby(connection, invocation_id);
        }
        if (std.mem.eql(u8, target, "MatchmakingJoinQueue")) {
            if (argument_count != 1) return error.InvalidMultiplayerArguments;
            return self.joinMatchmakingQueue(connection, invocation_id, try checkedReaderInteger(i32, reader));
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
                try checkedReaderInteger(i32, &request_reader),
                try checkedReaderInteger(i32, &request_reader),
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
        if (self.shutting_down) {
            self.mutex.unlock(self.io);
            return error.ServerShuttingDown;
        }
        if (!self.isEnabled()) {
            self.mutex.unlock(self.io);
            return error.MultiplayerDisabled;
        }
        if (!connection.alive.load(.acquire) or !connection.accepting_invocations.load(.acquire)) {
            self.mutex.unlock(self.io);
            return error.ConnectionClose;
        }
        const slot = self.roomSlotLocked() orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerRoomLimit;
        };
        room.id = self.next_room_id;
        self.next_room_id += 1;
        room.channel_id = @intCast(lazer.roomChannelId(room.id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerRoomLimit;
        });
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
        if (connection.room_id) |current_room_id| {
            if (current_room_id != room_id) {
                self.mutex.unlock(self.io);
                return error.AlreadyInMultiplayerRoom;
            }
            const current_room = self.roomByIdLocked(room_id) orelse {
                connection.room_id = null;
                self.mutex.unlock(self.io);
                return error.MultiplayerRoomNotFound;
            };
            if (current_room.userIndex(connection.user_id) == null) {
                connection.room_id = null;
                self.mutex.unlock(self.io);
                return error.NotInMultiplayerRoom;
            }
            response = completionRoomOwned(self.allocator, id, current_room, self.nowMs()) catch |err| {
                self.mutex.unlock(self.io);
                return err;
            };
            self.mutex.unlock(self.io);
            defer self.allocator.free(response);
            connection.send(response);
            std.log.info("event=lazer_multiplayer_room_rebound room_id={d} user_id={d}", .{ room_id, connection.user_id });
            return;
        }
        const room = self.roomByIdLocked(room_id) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerRoomNotFound;
        };
        if (roomHasEnded(room, std.Io.Clock.real.now(self.io).toSeconds())) {
            self.mutex.unlock(self.io);
            return error.MultiplayerRoomNotFound;
        }
        if (!std.mem.eql(u8, room.settings.password.slice(), password)) {
            self.mutex.unlock(self.io);
            return error.InvalidMultiplayerPassword;
        }
        if (!room.userAllowed(connection.user_id)) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        // A graceful restart restores the room's participant membership before
        // any websocket exists. When that user reconnects and explicitly joins
        // the room, bind the new connection to the restored membership rather
        // than appending the same user a second time.
        if (room.userIndex(connection.user_id) != null) {
            connection.room_id = room_id;
            response = completionRoomOwned(self.allocator, id, room, self.nowMs()) catch |err| {
                connection.room_id = null;
                self.mutex.unlock(self.io);
                return err;
            };
            self.mutex.unlock(self.io);
            defer self.allocator.free(response);
            connection.send(response);
            std.log.info("event=lazer_multiplayer_room_membership_restored room_id={d} user_id={d}", .{ room_id, connection.user_id });
            return;
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
        if (room.settings.match_type == 2) joined.team_id = nextTeamId(room);
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
        if (ranked_ended and ended_room == null) if (room_id) |id| {
            self.persistLiveRankedResult(id) catch |err| std.log.err("event=lazer_ranked_rating_persist_failed room_id={d} error={t}", .{ id, err });
            if (self.rankedStateEventForRoom(id) catch null) |updated| {
                if (ranked_event) |old| self.allocator.free(old);
                ranked_event = updated;
            }
        };
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
        var reset_users: [max_users]i32 = undefined;
        var reset_user_count: usize = 0;
        var team_users: [max_users]struct { id: i32, team_id: i32 } = undefined;
        var team_user_count: usize = 0;
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
        if (settings.max_participants) |limit| if (limit < room.user_count) {
            self.mutex.unlock(self.io);
            return error.InvalidMultiplayerParticipantLimit;
        };
        const room_before = room.*;
        if (settings.playlist_item_id == 0 or room.itemIndex(settings.playlist_item_id) == null) settings.playlist_item_id = room.settings.playlist_item_id;
        room.settings = settings;
        for (&room.users) |*entry| {
            if (entry.*) |*user| {
                if (user.state == 1) {
                    user.state = 0;
                    reset_users[reset_user_count] = user.id;
                    reset_user_count += 1;
                }
                if (settings.match_type == 2) {
                    if (user.team_id == null) user.team_id = nextTeamId(room);
                    team_users[team_user_count] = .{ .id = user.id, .team_id = user.team_id.? };
                    team_user_count += 1;
                } else user.team_id = null;
            }
        }
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        const settings_event = eventSettingsOwned(self.allocator, "SettingsChanged", room.settings) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        errdefer self.allocator.free(settings_event);
        const room_state_event = eventMatchRoomStateOwned(self.allocator, room) catch |err| {
            room.* = room_before;
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        defer self.allocator.free(settings_event);
        defer self.allocator.free(room_state_event);
        sendRecipients(recipients[0..count], settings_event);
        sendRecipients(recipients[0..count], room_state_event);
        for (reset_users[0..reset_user_count]) |user_id| {
            const state_event = try eventIntegersOwned(self.allocator, "UserStateChanged", &.{ user_id, 0 });
            defer self.allocator.free(state_event);
            sendRecipients(recipients[0..count], state_event);
        }
        for (team_users[0..team_user_count]) |team| {
            const team_event = try eventTeamStateOwned(self.allocator, team.id, team.team_id);
            defer self.allocator.free(team_event);
            sendRecipients(recipients[0..count], team_event);
        }
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
        var playlist_settings_event: ?[]u8 = null;
        defer if (playlist_settings_event) |event| self.allocator.free(event);
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
        var ranked_result_room_id: ?i64 = null;
        var ranked_result_event_index: ?usize = null;
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
        const ranked_waiting = room.ranked_play != null and room.ranked_play.?.stage == ranked_stage.gameplay_warmup;
        if ((quick_waiting or ranked_waiting) and new_state == 1) {
            var all_ready = room.user_count != 0;
            for (room.users) |entry| if (entry) |user| if (user.state != 1) {
                all_ready = false;
            };
            if (all_ready) {
                if (quick_waiting) {
                    room.matchmaking.?.stage = matchmaking_stage.gameplay_warmup;
                    match_snapshots[match_snapshot_count] = room.*;
                    match_snapshot_count += 1;
                    room.matchmaking.?.stage = matchmaking_stage.gameplay;
                } else room.ranked_play.?.stage = ranked_stage.gameplay;
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
                } else {
                    const advanced = advanceRoomPlaylist(room);
                    if (advanced.expired) |item| {
                        playlist_event = eventPlaylistOwned(self.allocator, "PlaylistItemChanged", item) catch |err| {
                            room.* = room_before;
                            self.mutex.unlock(self.io);
                            return err;
                        };
                    }
                    if (advanced.next_item_id != null) {
                        playlist_settings_event = eventSettingsOwned(self.allocator, "SettingsChanged", room.settings) catch |err| {
                            room.* = room_before;
                            self.mutex.unlock(self.io);
                            return err;
                        };
                    }
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
                    ranked.stage = ranked_stage.ended;
                    ranked_result_room_id = room.id;
                    ranked_result_event_index = match_snapshot_count;
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
        if (ranked_result_room_id) |id| {
            self.persistLiveRankedResult(id) catch |err| std.log.err("event=lazer_ranked_rating_persist_failed room_id={d} error={t}", .{ id, err });
            if (self.rankedStateEventForRoom(id) catch null) |updated| if (ranked_result_event_index) |index| {
                if (match_events[index]) |old| self.allocator.free(old);
                match_events[index] = updated;
            };
        }
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
        if (playlist_settings_event) |event| sendRecipients(recipients[0..count], event);
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
        const availability_event = try eventIntegerRawOwned(self.allocator, "UserBeatmapAvailabilityChanged", connection.user_id, encoded);
        defer self.allocator.free(availability_event);
        var recipients: [max_connections]*Connection = undefined;
        var warmup_event: ?[]u8 = null;
        defer if (warmup_event) |event| self.allocator.free(event);
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const index = room.userIndex(connection.user_id).?;
        const previous_availability = room.users[index].?.availability;
        room.users[index].?.availability.set(encoded) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        if (room.ranked_play) |*ranked| if (ranked.stage == ranked_stage.finish_card_play and roomBeatmapsLocallyAvailable(room)) {
            ranked.stage = ranked_stage.gameplay_warmup;
            warmup_event = eventMatchStateOwned(self.allocator, room) catch |err| {
                ranked.stage = ranked_stage.finish_card_play;
                room.users[index].?.availability = previous_availability;
                self.mutex.unlock(self.io);
                return err;
            };
        };
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        sendRecipients(recipients[0..count], availability_event);
        if (warmup_event) |event| sendRecipients(recipients[0..count], event);
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

    fn sendMatchRequest(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, encoded: []const u8) !void {
        const ParsedRequest = union(enum) {
            change_team: i32,
            start_countdown: i64,
            stop_countdown: i32,
            avatar_action: i64,
            ranked_hand_replay: []const u8,
            set_lock: bool,
            roll: ?i64,
            change_slot: u8,
        };
        var reader: MessagePackReader = .{ .data = encoded };
        if (try reader.arrayLen() != 2) return error.InvalidMultiplayerArguments;
        const request_type = try reader.integer();
        const payload = try reader.raw();
        if (reader.pos != reader.data.len) return error.InvalidMultiplayerArguments;
        var payload_reader: MessagePackReader = .{ .data = payload };
        if (try payload_reader.arrayLen() != 1) return error.InvalidMultiplayerArguments;
        const request: ParsedRequest = switch (request_type) {
            0 => .{ .change_team = std.math.cast(i32, try payload_reader.integer()) orelse return error.InvalidMultiplayerArguments },
            1 => .{ .start_countdown = try payload_reader.integer() },
            2 => .{ .stop_countdown = std.math.cast(i32, try payload_reader.integer()) orelse return error.InvalidMultiplayerArguments },
            3 => .{ .avatar_action = try payload_reader.integer() },
            4 => .{ .ranked_hand_replay = try payload_reader.raw() },
            5 => .{ .set_lock = try payload_reader.boolean() },
            6 => .{ .roll = try payload_reader.nullableInteger() },
            7 => .{ .change_slot = std.math.cast(u8, try payload_reader.integer()) orelse return error.InvalidMultiplayerArguments },
            else => return error.UnsupportedMultiplayerMethod,
        };
        if (payload_reader.pos != payload_reader.data.len) return error.InvalidMultiplayerArguments;
        switch (request) {
            .change_team => |team_id| try self.changeTeam(connection, invocation_id, team_id),
            .start_countdown => |duration_ticks| try self.startMatchCountdown(connection, invocation_id, duration_ticks),
            .stop_countdown => |countdown_id| try self.stopMatchCountdown(connection, invocation_id, countdown_id),
            .avatar_action => |action| try self.matchmakingAvatarAction(connection, invocation_id, action),
            .ranked_hand_replay => |frames| try self.rankedHandReplay(connection, invocation_id, frames),
            .set_lock => |locked| try self.setRoomLock(connection, invocation_id, locked),
            .roll => |max| try self.roll(connection, invocation_id, max),
            .change_slot => |slot_id| try self.changeSlot(connection, invocation_id, slot_id),
        }
    }

    fn changeTeam(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, team_id: i32) !void {
        if (team_id < 0 or team_id > 1) return error.InvalidMultiplayerTeam;
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const user_index = room.userIndex(connection.user_id).?;
        const user = &room.users[user_index].?;
        if (room.settings.match_type != 2 or room.state != 0 or (room.locked and room.host_id != connection.user_id and user.role != 1)) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        user.team_id = team_id;
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const event = try eventTeamStateOwned(self.allocator, connection.user_id, team_id);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn startMatchCountdown(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, duration_ticks: i64) !void {
        if (duration_ticks < timespan_ticks_per_second or duration_ticks > 10 * 60 * timespan_ticks_per_second) return error.InvalidMultiplayerCountdown;
        const duration_ms = @divFloor(duration_ticks, timespan_ticks_per_millisecond);
        var recipients: [max_connections]*Connection = undefined;
        var countdown: MatchStartCountdownState = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const user_index = room.userIndex(connection.user_id).?;
        if ((room.host_id != connection.user_id and room.users[user_index].?.role != 1) or room.state != 0 or room.match_start_countdown != null) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        countdown = .{ .id = self.next_countdown_id, .deadline_ms = self.nowMs() + duration_ms };
        self.next_countdown_id = if (self.next_countdown_id == std.math.maxInt(i32)) 1 else self.next_countdown_id + 1;
        room.match_start_countdown = countdown;
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const event = try eventMatchStartCountdownOwned(self.allocator, countdown, self.nowMs());
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn stopMatchCountdown(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, countdown_id: i32) !void {
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const user_index = room.userIndex(connection.user_id).?;
        if ((room.host_id != connection.user_id and room.users[user_index].?.role != 1) or room.match_start_countdown == null or room.match_start_countdown.?.id != countdown_id) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        room.match_start_countdown = null;
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const event = try eventRankedCountdownStoppedOwned(self.allocator, countdown_id);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn setRoomLock(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, locked: bool) !void {
        var recipients: [max_connections]*Connection = undefined;
        var snapshot: Room = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const user_index = room.userIndex(connection.user_id).?;
        if (room.host_id != connection.user_id and room.users[user_index].?.role != 1) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        room.locked = locked;
        snapshot = room.*;
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const event = try eventMatchRoomStateOwned(self.allocator, &snapshot);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn changeSlot(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, slot_id: u8) !void {
        var recipients: [max_connections]*Connection = undefined;
        var snapshot: Room = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const user_index = room.userIndex(connection.user_id).?;
        const limit: usize = room.settings.max_participants orelse max_users;
        if (slot_id >= limit or room.users[slot_id] != null or room.state != 0 or (room.locked and room.host_id != connection.user_id and room.users[user_index].?.role != 1)) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        room.users[slot_id] = room.users[user_index];
        room.users[user_index] = null;
        snapshot = room.*;
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const event = try eventMatchRoomStateOwned(self.allocator, &snapshot);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn roll(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, requested_max: ?i64) !void {
        const max = requested_max orelse 100;
        if (max < 2 or max > 1_000_000) return error.InvalidMultiplayerRoll;
        var random: [8]u8 = undefined;
        try self.io.randomSecure(&random);
        const result = @as(i64, @intCast(std.mem.readInt(u64, &random, .little) % @as(u64, @intCast(max)))) + 1;
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        if (self.roomByIdLocked(room_id).?.userIndex(connection.user_id) == null) {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        }
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const event = try eventRollOwned(self.allocator, connection.user_id, max, result);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn matchmakingAvatarAction(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, action: i64) !void {
        if (action != 0) return error.InvalidMultiplayerAvatarAction;
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        if (room.matchmaking == null or room.userIndex(connection.user_id) == null) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        const count = self.recipientsLocked(room_id, connection, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const event = try eventMatchmakingAvatarActionOwned(self.allocator, connection.user_id, action);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn rankedHandReplay(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, frames: []const u8) !void {
        var frames_reader: MessagePackReader = .{ .data = frames };
        const frame_count = try frames_reader.arrayLen();
        if (frame_count > 256) return error.InvalidMultiplayerReplay;
        for (0..frame_count) |_| try frames_reader.skip(0);
        if (frames_reader.pos != frames_reader.data.len) return error.InvalidMultiplayerReplay;
        var recipients: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        if (room.ranked_play == null or room.userIndex(connection.user_id) == null) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        const count = self.recipientsLocked(room_id, connection, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const event = try eventRankedHandReplayOwned(self.allocator, connection.user_id, frames);
        defer self.allocator.free(event);
        sendRecipients(recipients[0..count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn startMatch(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
        var recipients: [max_connections]*Connection = undefined;
        var loaders: [max_connections]*Connection = undefined;
        var loader_count: usize = 0;
        var countdown_id: ?i32 = null;
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
        countdown_id = if (room.match_start_countdown) |countdown| countdown.id else null;
        room.match_start_countdown = null;
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
        if (countdown_id) |id| {
            const countdown_event = try eventRankedCountdownStoppedOwned(self.allocator, id);
            defer self.allocator.free(countdown_event);
            sendRecipients(recipients[0..count], countdown_event);
        }
        for (state_events) |entry| if (entry) |event| sendRecipients(recipients[0..count], event);
        const load = try eventNoArgsOwned(self.allocator, "LoadRequested");
        defer self.allocator.free(load);
        sendRecipients(loaders[0..loader_count], load);
        try self.finishVoid(connection, invocation_id);
    }

    fn abortMatch(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
        var recipients: [max_connections]*Connection = undefined;
        var changed_users: [max_users]i32 = undefined;
        var changed_user_count: usize = 0;
        var countdown_id: ?i32 = null;
        self.mutex.lockUncancelable(self.io);
        const room_id = connection.room_id orelse {
            self.mutex.unlock(self.io);
            return error.NotInMultiplayerRoom;
        };
        const room = self.roomByIdLocked(room_id).?;
        const requester_index = room.userIndex(connection.user_id).?;
        if (room.host_id != connection.user_id and room.users[requester_index].?.role != 1) {
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        }
        countdown_id = if (room.match_start_countdown) |countdown| countdown.id else null;
        room.match_start_countdown = null;
        room.state = 0;
        for (&room.users) |*entry| {
            if (entry.*) |*user| {
                if (user.state >= 2 and user.state <= 7) {
                    user.state = 0;
                    changed_users[changed_user_count] = user.id;
                    changed_user_count += 1;
                }
            }
        }
        const count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..count]);
        self.mutex.unlock(self.io);
        const room_event = try eventIntegersOwned(self.allocator, "RoomStateChanged", &.{0});
        defer self.allocator.free(room_event);
        sendRecipients(recipients[0..count], room_event);
        if (countdown_id) |id| {
            const countdown_event = try eventRankedCountdownStoppedOwned(self.allocator, id);
            defer self.allocator.free(countdown_event);
            sendRecipients(recipients[0..count], countdown_event);
        }
        for (changed_users[0..changed_user_count]) |user_id| {
            const state_event = try eventIntegersOwned(self.allocator, "UserStateChanged", &.{ user_id, 0 });
            defer self.allocator.free(state_event);
            sendRecipients(recipients[0..count], state_event);
        }
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
        item.order = nextPlaylistOrder(room) orelse {
            self.mutex.unlock(self.io);
            return error.MultiplayerPlaylistFull;
        };
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
        for (self.connections.items) |candidate| if (candidate.user_id == user_id and candidate.room_id == null and candidate.alive.load(.acquire)) {
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
            if (!candidate.alive.load(.acquire)) continue;
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
            if (candidate == connection or candidate.user_id == connection.user_id or !candidate.alive.load(.acquire) or candidate.room_id != null or candidate.queue_pool_id != pool_id or candidate.pending_match_id != null) continue;
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
        for (pending.users, 0..) |user_id, index| {
            if (pool_type == 0) {
                room.matchmaking.?.users[index] = .{ .id = user_id };
                room.matchmaking.?.user_count += 1;
            } else {
                const rating = if (self.store) |store| (try store.lazerRankedRating(user_id, mode)).rating else @as(i32, 1500);
                room.ranked_play.?.users[index] = .{ .id = user_id, .rating = rating, .rating_after = rating };
                room.ranked_play.?.user_count += 1;
            }
        }
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
        var state_event: ?[]u8 = null;
        defer if (state_event) |event| self.allocator.free(event);
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
        resetRoomBeatmapAvailability(room);
        ranked.stage = ranked_stage.finish_card_play;
        const countdown_id = if (ranked.pick_countdown) |countdown| countdown.id else null;
        ranked.pick_countdown = null;
        settings = room.settings;
        const recipient_count = self.recipientsLocked(room_id, null, &recipients);
        defer releaseRecipients(recipients[0..recipient_count]);
        if (countdown_id) |id| countdown_stopped_event = eventRankedCountdownStoppedOwned(self.allocator, id) catch |err| {
            room.* = room_before;
            self.mutex.unlock(self.io);
            return err;
        };
        state_event = eventMatchStateOwned(self.allocator, room) catch |err| {
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
        sendRecipients(recipients[0..recipient_count], state_event.?);
        try self.finishVoid(connection, invocation_id);
    }

    pub fn advanceExpiredMatchCountdowns(self: *Manager, now_ms: i64) !usize {
        var mutation = self.beginMutation() catch return 0;
        defer mutation.deinit();
        var advanced: usize = 0;
        while (true) {
            var recipients: [max_connections]*Connection = undefined;
            var host: ?*Connection = null;
            var countdown_id: i32 = 0;
            var room_id: i64 = 0;
            self.mutex.lockUncancelable(self.io);
            if (!self.mutationAllowedLocked()) {
                self.mutex.unlock(self.io);
                return advanced;
            }
            const room = expired: {
                for (self.rooms) |entry| if (entry) |candidate| {
                    const countdown = candidate.match_start_countdown orelse continue;
                    if (candidate.state == 0 and countdown.deadline_ms <= now_ms) break :expired candidate;
                };
                self.mutex.unlock(self.io);
                return advanced;
            };
            countdown_id = room.match_start_countdown.?.id;
            room_id = room.id;
            room.match_start_countdown = null;
            if (self.connectionByUserLocked(room.host_id)) |connection| if (connection.room_id == room.id) {
                connection.retain();
                host = connection;
            };
            const recipient_count = self.recipientsLocked(room.id, null, &recipients);
            defer releaseRecipients(recipients[0..recipient_count]);
            self.mutex.unlock(self.io);
            const stopped = try eventRankedCountdownStoppedOwned(self.allocator, countdown_id);
            defer self.allocator.free(stopped);
            sendRecipients(recipients[0..recipient_count], stopped);
            if (host) |connection| {
                defer connection.release();
                self.startMatch(connection, null) catch |err| if (err != error.NoReadyMultiplayerPlayers)
                    std.log.warn("event=lazer_multiplayer_countdown_start_failed room_id={d} error={t}", .{ room_id, err });
            }
            advanced += 1;
        }
    }

    pub fn advanceExpiredRankedPicks(self: *Manager, now_ms: i64) !usize {
        var mutation = self.beginMutation() catch return 0;
        defer mutation.deinit();
        var advanced: usize = 0;
        while (true) {
            var recipients: [max_connections]*Connection = undefined;
            var recipient_count: usize = 0;
            var frames: [5]?[]u8 = [_]?[]u8{null} ** 5;
            defer for (frames) |frame| if (frame) |owned| self.allocator.free(owned);
            var room_id: i64 = 0;
            var active_user_id: i32 = 0;

            self.mutex.lockUncancelable(self.io);
            if (!self.mutationAllowedLocked()) {
                self.mutex.unlock(self.io);
                return advanced;
            }
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
                self.persistLiveRankedResult(room_id) catch |err| std.log.err("event=lazer_ranked_rating_persist_failed room_id={d} error={t}", .{ room_id, err });
                if (self.rankedStateEventForRoom(room_id) catch null) |updated| {
                    if (frames[1]) |old| self.allocator.free(old);
                    frames[1] = updated;
                }
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
            resetRoomBeatmapAvailability(room);
            const settings = room.settings;
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
            frames[4] = eventMatchStateOwned(self.allocator, room) catch |err| {
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

    fn recordArchivedRoomScore(self: *Manager, user_id: i32, room_id: i64, playlist_item_id: i64, score: RoomScoreResult) !void {
        // Serialize with close/retry/checkpoint archive writers without
        // blocking live rooms, websocket connects, or matchmaking on the
        // manager-wide state mutex while storage and JSON work completes.
        self.archive_mutex.lockUncancelable(self.io);
        defer self.archive_mutex.unlock(self.io);
        self.mutex.lockUncancelable(self.io);
        if (!self.mutationAllowedLocked()) {
            const err = self.blockedMutationErrorLocked();
            self.mutex.unlock(self.io);
            return err;
        }
        self.mutex.unlock(self.io);
        const store = self.store orelse return error.StoreUnavailable;
        var archive = (try store.lazerMultiplayerRoomArchive(self.allocator, room_id)) orelse return error.MultiplayerRoomNotFound;
        defer archive.deinit();
        if (!try archiveIncludesUserFallible(self.allocator, archive.participant_ids_json, user_id)) return error.MultiplayerPermissionDenied;
        const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
        if (now_seconds > std.math.add(i64, archive.ended_at, multiplayer_score_grace_seconds) catch return error.MultiplayerRoomNotFound) return error.MultiplayerRoomNotFound;
        if ((try archivedScoreContext(self.allocator, archive.room_json, playlist_item_id)) == null) return error.MultiplayerPermissionDenied;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, archive.room_json, .{});
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |*object| object,
            else => return error.InvalidMultiplayerArchive,
        };
        const records = switch ((root.getPtr("zigcho_score_records") orelse return error.InvalidMultiplayerArchive).*) {
            .array => |*array| array,
            else => return error.InvalidMultiplayerArchive,
        };
        const token_id = score.token_id orelse return error.InvalidMultiplayerScoreToken;
        const tokens = switch ((root.getPtr("zigcho_score_tokens") orelse return error.InvalidMultiplayerScoreToken).*) {
            .array => |*array| array,
            else => return error.InvalidMultiplayerArchive,
        };
        if (tokens.items.len > max_room_scores) return error.InvalidMultiplayerArchive;
        var token_index: ?usize = null;
        for (tokens.items, 0..) |value, index| {
            const token = archivedScoreTokenRecord(value) orelse return error.InvalidMultiplayerArchive;
            if (token.token_id != token_id) continue;
            if (token_index != null) return error.InvalidMultiplayerArchive;
            if (token.user_id != user_id or token.playlist_item_id != playlist_item_id) return error.InvalidMultiplayerScoreToken;
            token_index = index;
        }
        const bound_token_index = token_index orelse return error.InvalidMultiplayerScoreToken;
        const bound_token = archivedScoreTokenRecord(tokens.items[bound_token_index]) orelse return error.InvalidMultiplayerArchive;
        for (records.items) |value| if (archivedScoreRecord(value)) |existing| {
            if (existing.score_id != score.score_id) continue;
            if (existing.user_id != user_id or existing.playlist_item_id != playlist_item_id or bound_token.score_id != score.score_id) return error.InvalidMultiplayerArchive;
            return;
        } else return error.InvalidMultiplayerArchive;
        if (bound_token.score_id != null) return error.InvalidMultiplayerScoreToken;
        if (records.items.len >= max_room_scores) return error.MultiplayerScoreLimit;

        const arena = parsed.arena.allocator();
        var score_object: std.json.ObjectMap = .empty;
        try score_object.put(arena, "score_id", .{ .integer = score.score_id });
        try score_object.put(arena, "user_id", .{ .integer = user_id });
        try score_object.put(arena, "playlist_item_id", .{ .integer = playlist_item_id });
        try score_object.put(arena, "total_score", .{ .integer = score.total_score });
        try score_object.put(arena, "accuracy", .{ .float = score.accuracy });
        try score_object.put(arena, "max_combo", .{ .integer = score.max_combo });
        try score_object.put(arena, "passed", .{ .bool = score.passed });
        try records.append(.{ .object = score_object });
        const token_object = switch (tokens.items[bound_token_index]) {
            .object => |*object| object,
            else => return error.InvalidMultiplayerArchive,
        };
        try token_object.put(arena, "score_id", .{ .integer = score.score_id });

        const realtime = switch (root.get("category") orelse return error.InvalidMultiplayerArchive) {
            .string => |category| if (std.mem.eql(u8, category, "realtime"))
                true
            else if (std.mem.eql(u8, category, "normal"))
                false
            else
                return error.InvalidMultiplayerArchive,
            else => return error.InvalidMultiplayerArchive,
        };
        const snapshot = try self.allocator.create(Room);
        defer self.allocator.destroy(snapshot);
        snapshot.* = .{ .id = room_id, .settings = .{}, .host_id = archive.owner_id };
        snapshot.settings.match_type = if (realtime) 1 else 0;
        snapshot.ended = true;
        defer snapshot.deinit(self.allocator);
        try restoreArchivedPlaylist(root, snapshot);
        const participants = switch (root.get("recent_participants") orelse return error.InvalidMultiplayerArchive) {
            .array => |array| array,
            else => return error.InvalidMultiplayerArchive,
        };
        if (participants.items.len > max_room_participants) return error.InvalidMultiplayerArchive;
        for (participants.items) |value| snapshot.rememberParticipant(try roomUserFromJson(value));
        if (snapshot.participantIndex(user_id) == null) return error.MultiplayerPermissionDenied;
        try snapshot.scores.ensureTotalCapacity(self.allocator, records.items.len);
        for (records.items) |value| snapshot.scores.appendAssumeCapacity(archivedScoreRecord(value) orelse return error.InvalidMultiplayerArchive);

        var room_output: std.Io.Writer.Allocating = .init(self.allocator);
        defer room_output.deinit();
        std.json.Stringify.value(parsed.value, .{}, &room_output.writer) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };
        var leaderboard_output: std.Io.Writer.Allocating = .init(self.allocator);
        defer leaderboard_output.deinit();
        writeRoomLeaderboardJson(self.allocator, &leaderboard_output.writer, snapshot, 0) catch |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
        };
        const rebuilt_has_rows = try archivedLeaderboardHasRows(self.allocator, leaderboard_output.written());
        const existing_has_rows = try archivedLeaderboardHasRows(self.allocator, archive.leaderboard_json);
        const leaderboard_json = if (!rebuilt_has_rows and existing_has_rows) archive.leaderboard_json else leaderboard_output.written();
        try store.updateLazerMultiplayerRoomArchive(room_id, room_output.written(), leaderboard_json);
    }

    pub fn recordRoomScore(self: *Manager, user_id: i32, room_id: i64, playlist_item_id: i64, score: RoomScoreResult) !void {
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        var recipients: [max_connections]*Connection = undefined;
        var state_event: ?[]u8 = null;
        defer if (state_event) |event| self.allocator.free(event);
        self.mutex.lockUncancelable(self.io);
        if (!self.mutationAllowedLocked()) {
            const err = self.blockedMutationErrorLocked();
            self.mutex.unlock(self.io);
            return err;
        }
        const room = self.roomByIdLocked(room_id) orelse {
            self.mutex.unlock(self.io);
            return self.recordArchivedRoomScore(user_id, room_id, playlist_item_id, score);
        };
        if (roomHasEnded(room, std.Io.Clock.real.now(self.io).toSeconds())) {
            self.mutex.unlock(self.io);
            return error.MultiplayerRoomNotFound;
        }
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
        for (room.scores.items) |existing| if (existing.score_id == score.score_id) {
            if (existing.user_id != user_id or existing.playlist_item_id != playlist_item_id) {
                self.mutex.unlock(self.io);
                return error.InvalidMultiplayerRoomScore;
            }
            if (score.token_id) |token_id| if (room.scoreTokenIndex(token_id, user_id, playlist_item_id)) |index| {
                if (room.score_tokens.items[index].score_id != score.score_id) {
                    self.mutex.unlock(self.io);
                    return error.InvalidMultiplayerScoreToken;
                }
            } else {
                self.mutex.unlock(self.io);
                return error.InvalidMultiplayerScoreToken;
            };
            self.mutex.unlock(self.io);
            return;
        };
        const token_index: ?usize = if (score.token_id) |token_id|
            room.scoreTokenIndex(token_id, user_id, playlist_item_id) orelse {
                self.mutex.unlock(self.io);
                return error.InvalidMultiplayerScoreToken;
            }
        else
            null;
        if (token_index) |index| if (room.score_tokens.items[index].score_id != null) {
            self.mutex.unlock(self.io);
            return error.InvalidMultiplayerScoreToken;
        };
        if (room.scores.items.len >= max_room_scores) {
            self.mutex.unlock(self.io);
            return error.MultiplayerScoreLimit;
        }
        room.scores.append(self.allocator, record) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        if (room.ranked_play) |*ranked| {
            if (ranked.gameplay_item != playlist_item_id or ranked.current_round == 0) {
                if (token_index) |index| room.score_tokens.items[index].score_id = score.score_id;
                self.mutex.unlock(self.io);
                return;
            }
            const user_index = ranked.userIndex(user_id) orelse {
                room.scores.items.len -= 1;
                self.mutex.unlock(self.io);
                return error.MultiplayerPermissionDenied;
            };
            const user_before = ranked.users[user_index].?;
            ranked.users[user_index].?.total_score = score.total_score;
            ranked.users[user_index].?.submitted = true;
            const count = self.recipientsLocked(room_id, null, &recipients);
            defer releaseRecipients(recipients[0..count]);
            state_event = eventMatchStateOwned(self.allocator, room) catch |err| {
                ranked.users[user_index] = user_before;
                room.scores.items.len -= 1;
                self.mutex.unlock(self.io);
                return err;
            };
            if (token_index) |index| room.score_tokens.items[index].score_id = score.score_id;
            self.mutex.unlock(self.io);
            sendRecipients(recipients[0..count], state_event.?);
            return;
        }
        if (room.matchmaking == null or room.matchmaking.?.gameplay_item != playlist_item_id or room.matchmaking.?.current_round == 0) {
            if (token_index) |index| room.score_tokens.items[index].score_id = score.score_id;
            self.mutex.unlock(self.io);
            return;
        }
        const user_index = room.matchmaking.?.userIndex(user_id) orelse {
            room.scores.items.len -= 1;
            self.mutex.unlock(self.io);
            return error.MultiplayerPermissionDenied;
        };
        const matchmaking_before = room.matchmaking.?;
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
            room.matchmaking = matchmaking_before;
            room.scores.items.len -= 1;
            self.mutex.unlock(self.io);
            return err;
        };
        if (token_index) |index| room.score_tokens.items[index].score_id = score.score_id;
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

const beatmap_availability_unknown: u8 = 0;
const beatmap_availability_locally_available: u8 = 4;

fn beatmapAvailabilityState(encoded: []const u8) ?u8 {
    var reader: MessagePackReader = .{ .data = encoded };
    if ((reader.arrayLen() catch return null) != 2) return null;
    const state = checkedReaderInteger(u8, &reader) catch return null;
    reader.skip(0) catch return null;
    if (reader.pos != reader.data.len or state > beatmap_availability_locally_available) return null;
    return state;
}

fn resetRoomBeatmapAvailability(room: *Room) void {
    for (&room.users) |*entry| if (entry.*) |*user| {
        user.availability.bytes[0] = 0x92;
        user.availability.bytes[1] = beatmap_availability_unknown;
        user.availability.bytes[2] = 0xc0;
        user.availability.len = 3;
    };
}

fn roomBeatmapsLocallyAvailable(room: *const Room) bool {
    if (room.user_count == 0) return false;
    var users_seen: usize = 0;
    for (room.users) |entry| if (entry) |user| {
        users_seen += 1;
        if (beatmapAvailabilityState(user.availability.slice()) != beatmap_availability_locally_available) return false;
    };
    return users_seen == room.user_count;
}

fn nextTeamId(room: *const Room) i32 {
    var red: usize = 0;
    var blue: usize = 0;
    for (room.users) |entry| if (entry) |user| {
        if (user.team_id == 0) red += 1 else if (user.team_id == 1) blue += 1;
    };
    return if (red <= blue) 0 else 1;
}

fn nextPlaylistOrder(room: *const Room) ?u16 {
    var highest: ?u16 = null;
    for (room.playlist) |entry| {
        if (entry) |item| highest = if (highest) |value| @max(value, item.order) else item.order;
    }
    return if (highest) |value| std.math.add(u16, value, 1) catch null else 0;
}

fn advanceRoomPlaylist(room: *Room) PlaylistAdvance {
    const current_index = room.itemIndex(room.settings.playlist_item_id) orelse return .{};
    var result: PlaylistAdvance = .{};
    if (!room.playlist[current_index].?.expired) {
        room.playlist[current_index].?.expired = true;
        result.expired = room.playlist[current_index].?;
    }

    var next: ?PlaylistItem = null;
    for (room.playlist) |entry| if (entry) |item| {
        if (item.expired) continue;
        if (next == null or item.order < next.?.order or (item.order == next.?.order and item.id < next.?.id)) next = item;
    };
    if (next) |item| {
        if (room.settings.playlist_item_id != item.id) {
            room.settings.playlist_item_id = item.id;
            result.next_item_id = item.id;
        }
    }
    for (&room.users) |*entry| {
        if (entry.*) |*user| user.voted_skip = false;
    }
    return result;
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
    jsonValueMessagePack(.{ .writer = &output.writer }, value, 0) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try destination.set(output.written());
}

fn roomUserFromJson(value: std.json.Value) !RoomUser {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidMultiplayerRoom,
    };
    const id_value = jsonInteger(object.get("id")) orelse return error.InvalidMultiplayerRoom;
    const name = try jsonString(object, "username");
    const country = try jsonString(object, "country_code");
    if (id_value <= 0 or id_value > std.math.maxInt(i32) or name.len == 0 or name.len > 64 or country.len != 2) return error.InvalidMultiplayerRoom;
    return defaultRoomUser(@intCast(id_value), name, .{ std.ascii.toUpper(country[0]), std.ascii.toUpper(country[1]) });
}

fn restoreRoomCheckpoint(allocator: std.mem.Allocator, room_json: []const u8, now_seconds: i64) !?*Room {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, room_json, .{}) catch return error.InvalidMultiplayerRoom;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidMultiplayerRoom,
    };
    if (!(try jsonOptionalBool(object, "zigcho_resumable", false))) return null;
    const host = switch (object.get("host") orelse return error.InvalidMultiplayerRoom) {
        .object => |host| host,
        else => return error.InvalidMultiplayerRoom,
    };
    const host_id = jsonInteger(host.get("id")) orelse return error.InvalidMultiplayerRoom;
    const host_name = try jsonString(host, "username");
    const country_code = try jsonString(host, "country_code");
    if (host_id <= 0 or host_id > std.math.maxInt(i32) or host_name.len == 0 or country_code.len != 2) return error.InvalidMultiplayerRoom;
    const user: domain.User = .{
        .id = @intCast(host_id),
        .name = host_name,
        .safe_name = host_name,
        .country = .{ std.ascii.toUpper(country_code[0]), std.ascii.toUpper(country_code[1]) },
    };
    return try parseRestRoom(allocator, user, room_json, now_seconds, true);
}

fn parseRestRoom(allocator: std.mem.Allocator, user: domain.User, body: []const u8, now_seconds: i64, allow_checkpoint: bool) !*Room {
    const max_body: usize = if (allow_checkpoint) 8 * 1024 * 1024 else 128 * 1024;
    if (body.len == 0 or body.len > max_body) return error.InvalidMultiplayerRoom;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidMultiplayerRoom,
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidMultiplayerRoom,
    };
    const name = try jsonString(object, "name");
    if (name.len == 0 or name.len > 128 or !std.unicode.utf8ValidateSlice(name) or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidMultiplayerRoom;
    const resumable = allow_checkpoint and try jsonOptionalBool(object, "zigcho_resumable", false);
    const password_field = if (resumable) "zigcho_password" else "password";
    const password = if (object.get(password_field)) |value| switch (value) {
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
    const duration_raw = if (resumable) @as(?i64, 1) else try jsonOptionalInteger(object, "duration");
    const duration_minutes: ?i64 = if (duration_raw) |value| blk: {
        if (value <= 0 or value > 31 * 3 * 24 * 60) return error.InvalidMultiplayerRoom;
        break :blk value;
    } else null;
    if (match_type == 0 and (duration_minutes == null or now_seconds < 0)) return error.InvalidMultiplayerRoom;
    if (resumable and match_type != 0) return error.InvalidMultiplayerRoom;
    const max_attempts_raw = try jsonOptionalInteger(object, "max_attempts");
    const max_attempts: ?i32 = if (max_attempts_raw) |value| blk: {
        if (value <= 0 or value > 1000) return error.InvalidMultiplayerRoom;
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

    const initial_ends_at = if (duration_minutes) |minutes|
        std.math.add(i64, now_seconds, std.math.mul(i64, minutes, 60) catch return error.InvalidMultiplayerRoom) catch return error.InvalidMultiplayerRoom
    else
        0;
    const room = try allocator.create(Room);
    errdefer {
        room.deinit(allocator);
        allocator.destroy(room);
    }
    room.* = .{
        .id = 0,
        .settings = .{},
        .starts_at = if (duration_minutes != null) now_seconds else 0,
        .ends_at = initial_ends_at,
        .max_attempts = max_attempts,
        .host_id = user.id,
        .host_country = publicCountry(user),
    };
    try room.settings.name.set(name);
    try room.settings.password.set(password);
    room.settings.match_type = match_type;
    room.settings.queue_mode = queue_mode;
    room.settings.auto_skip = try jsonOptionalBool(object, "auto_skip", false);
    room.settings.max_participants = max_participants;
    var auto_start_output: std.Io.Writer.Allocating = .init(allocator);
    defer auto_start_output.deinit();
    (MessagePackWriter{ .writer = &auto_start_output.writer }).integer(auto_start * timespan_ticks_per_second) catch return error.OutOfMemory;
    try room.settings.auto_start.set(auto_start_output.written());
    try room.host_name.set(user.name);
    room.users[0] = try defaultRoomUser(user.id, user.name, publicCountry(user));
    if (match_type == 2) room.users[0].?.team_id = 0;
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
        item.expired = try jsonOptionalBool(item_object, "expired", false);
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
                if (try jsonOptionalInteger(beatmap, "total_length")) |total_length| {
                    if (total_length < 0 or total_length > std.math.maxInt(i32)) return error.InvalidMultiplayerRoom;
                    item.total_length = @intCast(total_length);
                }
                if (try jsonOptionalInteger(beatmap, "hit_length")) |hit_length| {
                    if (hit_length < 0 or hit_length > std.math.maxInt(i32)) return error.InvalidMultiplayerRoom;
                    item.hit_length = @intCast(hit_length);
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
    if (resumable) {
        const room_id = (try jsonOptionalInteger(object, "id")) orelse return error.InvalidMultiplayerRoom;
        const starts_at = (try jsonOptionalInteger(object, "zigcho_starts_at")) orelse return error.InvalidMultiplayerRoom;
        const ends_at = (try jsonOptionalInteger(object, "zigcho_ends_at")) orelse return error.InvalidMultiplayerRoom;
        const current_item_id = (try jsonOptionalInteger(object, "zigcho_current_playlist_item_id")) orelse return error.InvalidMultiplayerRoom;
        if (room_id <= 0 or starts_at <= 0 or ends_at <= starts_at or room.itemIndex(current_item_id) == null) return error.InvalidMultiplayerRoom;
        room.id = room_id;
        room.starts_at = starts_at;
        room.ends_at = ends_at;
        room.settings.playlist_item_id = current_item_id;
        room.channel_id = @intCast(lazer.roomChannelId(room.id) orelse return error.InvalidMultiplayerRoom);

        room.users = [_]?RoomUser{null} ** max_users;
        room.user_count = 0;
        const active_users = switch (object.get("zigcho_active_users") orelse return error.InvalidMultiplayerRoom) {
            .array => |array| array,
            else => return error.InvalidMultiplayerRoom,
        };
        if (active_users.items.len > max_users) return error.InvalidMultiplayerRoom;
        for (active_users.items, 0..) |value, index| {
            const restored = try roomUserFromJson(value);
            if (room.userIndex(restored.id) != null) return error.InvalidMultiplayerRoom;
            room.users[index] = restored;
            room.user_count += 1;
        }

        room.participants = [_]?RoomParticipant{null} ** max_room_participants;
        room.participant_count = 0;
        const participants = switch (object.get("zigcho_participants") orelse return error.InvalidMultiplayerRoom) {
            .array => |array| array,
            else => return error.InvalidMultiplayerRoom,
        };
        if (participants.items.len > max_room_participants) return error.InvalidMultiplayerRoom;
        for (participants.items) |value| {
            const restored = try roomUserFromJson(value);
            room.rememberParticipant(restored);
        }

        if (object.get("zigcho_score_tokens")) |token_value| {
            const token_values = switch (token_value) {
                .array => |array| array,
                else => return error.InvalidMultiplayerRoom,
            };
            if (token_values.items.len > max_room_scores) return error.InvalidMultiplayerRoom;
            var token_ids = std.AutoHashMap(i64, void).init(allocator);
            defer token_ids.deinit();
            try room.score_tokens.ensureTotalCapacity(allocator, token_values.items.len);
            for (token_values.items) |value| {
                const token = archivedScoreTokenRecord(value) orelse return error.InvalidMultiplayerRoom;
                if (room.participantIndex(token.user_id) == null or room.itemIndex(token.playlist_item_id) == null) return error.InvalidMultiplayerRoom;
                if ((try token_ids.getOrPut(token.token_id)).found_existing) return error.InvalidMultiplayerRoom;
                room.score_tokens.appendAssumeCapacity(token);
            }
        }

        const score_values = switch (object.get("zigcho_score_records") orelse return error.InvalidMultiplayerRoom) {
            .array => |array| array,
            else => return error.InvalidMultiplayerRoom,
        };
        if (score_values.items.len > max_room_scores) return error.InvalidMultiplayerRoom;
        try room.scores.ensureTotalCapacity(allocator, score_values.items.len);
        for (score_values.items) |value| room.scores.appendAssumeCapacity(archivedScoreRecord(value) orelse return error.InvalidMultiplayerRoom);
        var restored_scores = std.AutoHashMap(i64, RoomScoreRecord).init(allocator);
        defer restored_scores.deinit();
        for (room.scores.items) |score| {
            if (restored_scores.contains(score.score_id)) return error.InvalidMultiplayerRoom;
            try restored_scores.put(score.score_id, score);
        }
        var consumed_score_ids = std.AutoHashMap(i64, void).init(allocator);
        defer consumed_score_ids.deinit();
        for (room.score_tokens.items) |token| if (token.score_id) |score_id| {
            if ((try consumed_score_ids.getOrPut(score_id)).found_existing) return error.InvalidMultiplayerRoom;
            const restored = restored_scores.get(score_id) orelse return error.InvalidMultiplayerRoom;
            if (restored.user_id != token.user_id or restored.playlist_item_id != token.playlist_item_id) return error.InvalidMultiplayerRoom;
        };
    }
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
    settings.match_type = try checkedReaderInteger(u8, &reader);
    if (settings.match_type != 1 and settings.match_type != 2) return error.UnsupportedMultiplayerMatchType;
    settings.queue_mode = try checkedReaderInteger(u8, &reader);
    if (settings.queue_mode > 2) return error.InvalidMultiplayerQueueMode;
    try settings.auto_start.set(try reader.raw());
    settings.auto_skip = try reader.boolean();
    settings.max_participants = try checkedNullableInteger(u8, try reader.nullableInteger());
    if (settings.max_participants) |limit| if (limit < 2 or limit > max_users) return error.InvalidMultiplayerParticipantLimit;
    return settings;
}

fn parsePlaylistItem(encoded: []const u8) !PlaylistItem {
    var reader: MessagePackReader = .{ .data = encoded };
    if (try reader.arrayLen() < 12) return error.InvalidMultiplayerPlaylistItem;
    var item: PlaylistItem = .{};
    item.id = try reader.integer();
    item.owner_id = try checkedReaderInteger(i32, &reader);
    item.beatmap_id = try checkedReaderInteger(i32, &reader);
    if (item.beatmap_id <= 0) return error.InvalidMultiplayerBeatmap;
    const checksum = try reader.string();
    if (checksum.len > 64) return error.InvalidMultiplayerBeatmap;
    try item.checksum.set(checksum);
    item.ruleset_id = try checkedReaderInteger(u8, &reader);
    if (item.ruleset_id > 3) return error.InvalidMultiplayerRuleset;
    try item.required_mods.set(try reader.raw());
    try item.allowed_mods.set(try reader.raw());
    item.expired = try reader.boolean();
    item.order = try checkedReaderInteger(u16, &reader);
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
    if (!std.math.isFinite(item.star_rating) or item.star_rating < 0 or item.star_rating > 100) return error.InvalidMultiplayerBeatmap;
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
    if (settings.match_type == 2) room.users[0].?.team_id = 0;
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
    if (user.team_id) |team_id| {
        // MatchUserState union key 0 is TeamVersusUserState.
        try pack.array(2);
        try pack.integer(0);
        try pack.array(1);
        try pack.integer(team_id);
    } else try pack.nil();
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
    try pack.boolean(room.locked);
    if (room.settings.max_participants) |limit| {
        try pack.array(limit);
        for (room.users[0..limit]) |entry| if (entry) |user| try pack.integer(user.id) else try pack.nil();
    } else try pack.nil();
}

fn writeMatchStartCountdown(pack: MessagePackWriter, countdown: MatchStartCountdownState, now_ms: i64) !void {
    // MultiplayerCountdown union key 0 is MatchStartCountdown.
    try pack.array(2);
    try pack.integer(0);
    try pack.array(2);
    try pack.integer(countdown.id);
    try pack.integer(countdown.remainingTicks(now_ms));
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
    } else if (room.match_start_countdown) |countdown| {
        try pack.array(1);
        try writeMatchStartCountdown(pack, countdown, now_ms);
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

fn writeMessagePackJsonValue(writer: *std.Io.Writer, reader: *MessagePackReader, depth: u8) !void {
    if (depth >= 16 or reader.pos >= reader.data.len) return error.InvalidMultiplayerJsonValue;
    const tag = reader.data[reader.pos];
    if (tag == 0xc0) {
        reader.pos += 1;
        return writer.writeAll("null");
    }
    if (tag == 0xc2 or tag == 0xc3) return writer.writeAll(if (try reader.boolean()) "true" else "false");
    if (tag <= 0x7f or tag >= 0xe0 or (tag >= 0xcc and tag <= 0xd3)) return writer.print("{d}", .{try reader.integer()});
    if (tag == 0xca) {
        _ = try reader.byte();
        const value: f32 = @bitCast(try reader.readUnsigned(u32));
        if (!std.math.isFinite(value)) return error.InvalidMultiplayerJsonValue;
        return writer.print("{d}", .{value});
    }
    if (tag == 0xcb) {
        _ = try reader.byte();
        const value: f64 = @bitCast(try reader.readUnsigned(u64));
        if (!std.math.isFinite(value)) return error.InvalidMultiplayerJsonValue;
        return writer.print("{d}", .{value});
    }
    if ((tag >= 0xa0 and tag <= 0xbf) or tag == 0xd9 or tag == 0xda or tag == 0xdb) {
        const value = try reader.string();
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidMultiplayerJsonValue;
        return std.json.Stringify.value(value, .{}, writer);
    }
    if ((tag >= 0x90 and tag <= 0x9f) or tag == 0xdc or tag == 0xdd) {
        const len = try reader.arrayLen();
        try writer.writeByte('[');
        for (0..len) |index| {
            if (index != 0) try writer.writeByte(',');
            try writeMessagePackJsonValue(writer, reader, depth + 1);
        }
        return writer.writeByte(']');
    }
    if ((tag >= 0x80 and tag <= 0x8f) or tag == 0xde or tag == 0xdf) {
        const len = try reader.mapLen();
        try writer.writeByte('{');
        for (0..len) |index| {
            if (index != 0) try writer.writeByte(',');
            const key = try reader.string();
            if (!std.unicode.utf8ValidateSlice(key)) return error.InvalidMultiplayerJsonValue;
            try std.json.Stringify.value(key, .{}, writer);
            try writer.writeByte(':');
            try writeMessagePackJsonValue(writer, reader, depth + 1);
        }
        return writer.writeByte('}');
    }
    return error.InvalidMultiplayerJsonValue;
}

fn writeMessagePackJson(writer: *std.Io.Writer, encoded: []const u8) !void {
    var reader: MessagePackReader = .{ .data = encoded };
    try writeMessagePackJsonValue(writer, &reader, 0);
    if (reader.pos != reader.data.len) return error.InvalidMultiplayerJsonValue;
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
    try writer.print("{{\"id\":{d},\"owner_id\":{d},\"ruleset_id\":{d},\"expired\":{s},\"playlist_order\":{d},\"played_at\":null,\"allowed_mods\":", .{ item.id, item.owner_id, item.ruleset_id, if (item.expired) "true" else "false", item.order });
    try writeMessagePackJson(writer, item.allowed_mods.slice());
    try writer.writeAll(",\"required_mods\":");
    try writeMessagePackJson(writer, item.required_mods.slice());
    try writer.print(",\"beatmap_id\":{d},\"beatmap\":{{\"id\":{d},\"beatmapset_id\":{d},\"mode\":", .{ item.beatmap_id, item.beatmap_id, set_id });
    try std.json.Stringify.value(mode, .{}, writer);
    try writer.writeAll(",\"status\":");
    try std.json.Stringify.value(status, .{}, writer);
    try writer.writeAll(",\"version\":");
    try std.json.Stringify.value(version, .{}, writer);
    try writer.writeAll(",\"difficulty_rating\":");
    try writer.print("{d},\"total_length\":{d},\"hit_length\":{d},\"checksum\":", .{ item.star_rating, item.total_length, item.hit_length });
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

fn writeIsoTimestamp(writer: *std.Io.Writer, unix_seconds: i64) !void {
    if (unix_seconds < 0) return error.InvalidMultiplayerTimestamp;
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(unix_seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    try writer.print("\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\"", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

fn autoStartSeconds(settings: Settings) i64 {
    var reader: MessagePackReader = .{ .data = settings.auto_start.slice() };
    const ticks = reader.integer() catch return 0;
    if (reader.pos != reader.data.len or ticks <= 0) return 0;
    return @divFloor(ticks, timespan_ticks_per_second);
}

fn roomHasEnded(room: *const Room, now_seconds: i64) bool {
    return room.ended or (room.ends_at > 0 and now_seconds >= room.ends_at);
}

fn writeCurrentUserScore(writer: *std.Io.Writer, room: *const Room, requester_id: i32) !void {
    if (requester_id <= 0 or room.userIndex(requester_id) == null) return writer.writeAll("null");
    try writer.writeAll("{\"playlist_item_attempts\":[");
    var written: usize = 0;
    for (room.playlist) |entry| if (entry) |item| {
        var attempts: usize = 0;
        var passed = false;
        for (room.scores.items) |score| if (score.user_id == requester_id and score.playlist_item_id == item.id) {
            attempts += 1;
            passed = passed or score.passed;
        };
        if (attempts == 0) continue;
        if (written != 0) try writer.writeByte(',');
        try writer.print("{{\"id\":{d},\"attempts\":{d},\"passed\":{s}}}", .{ item.id, attempts, if (passed) "true" else "false" });
        written += 1;
    };
    try writer.writeAll("]}");
}

fn writeRoomJson(writer: *std.Io.Writer, room: *const Room, requester_id: i32, now_seconds: i64, persistence: RoomPersistence) !void {
    try writer.print("{{\"id\":{d},\"name\":", .{room.id});
    try std.json.Stringify.value(room.settings.name.slice(), .{}, writer);
    try writer.print(",\"description\":null,\"has_password\":{s},\"host\":", .{if (room.settings.password.len != 0) "true" else "false"});
    try writeApiUserJson(writer, room.host_id, room.host_name.slice(), room.host_country);
    try writer.writeAll(",\"category\":");
    try std.json.Stringify.value(if (room.settings.match_type == 0) "normal" else "realtime", .{}, writer);
    try writer.writeAll(",\"duration\":null,\"starts_at\":");
    if (room.starts_at > 0) try writeIsoTimestamp(writer, room.starts_at) else try writer.writeAll("null");
    try writer.writeAll(",\"ends_at\":");
    if (room.ends_at > 0) try writeIsoTimestamp(writer, room.ends_at) else try writer.writeAll("null");
    try writer.writeAll(",\"max_participants\":");
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
    try writer.writeAll("],\"max_attempts\":");
    if (room.max_attempts) |limit| try writer.print("{d}", .{limit}) else try writer.writeAll("null");
    try writer.writeAll(",\"playlist\":[");
    var playlist_written: usize = 0;
    var active_playlist_items: usize = 0;
    var active_rulesets = [_]bool{false} ** 4;
    var all_rulesets = [_]bool{false} ** 4;
    for (room.playlist) |entry| if (entry) |item| {
        if (playlist_written != 0) try writer.writeByte(',');
        try writePlaylistItemJson(writer, item);
        playlist_written += 1;
        if (item.ruleset_id < all_rulesets.len) all_rulesets[item.ruleset_id] = true;
        if (!item.expired) {
            active_playlist_items += 1;
            if (item.ruleset_id < active_rulesets.len) active_rulesets[item.ruleset_id] = true;
        }
    };
    try writer.print("],\"playlist_item_stats\":{{\"count_active\":{d},\"count_total\":{d},\"ruleset_ids\":[", .{ active_playlist_items, room.playlist_count });
    const listed_rulesets = if (room.ended and room.settings.match_type == 0 and active_playlist_items == 0) all_rulesets else active_rulesets;
    var rulesets_written: usize = 0;
    for (listed_rulesets, 0..) |present, ruleset_id| {
        if (!present) continue;
        if (rulesets_written != 0) try writer.writeByte(',');
        try writer.print("{d}", .{ruleset_id});
        rulesets_written += 1;
    }
    try writer.writeAll("]},\"difficulty_range\":null,\"type\":");
    try std.json.Stringify.value(match_type, .{}, writer);
    try writer.writeAll(",\"queue_mode\":");
    try std.json.Stringify.value(queue_mode, .{}, writer);
    try writer.print(",\"auto_skip\":{s},\"auto_start_duration\":{d},\"current_user_score\":", .{ if (room.settings.auto_skip) "true" else "false", autoStartSeconds(room.settings) });
    try writeCurrentUserScore(writer, room, requester_id);
    try writer.writeAll(",\"current_playlist_item\":");
    const current = room.playlist[room.itemIndex(room.settings.playlist_item_id) orelse 0] orelse return error.MultiplayerPlaylistItemNotFound;
    try writePlaylistItemJson(writer, current);
    try writer.print(",\"channel_id\":{d},\"status\":\"{s}\",\"pinned\":false", .{ room.channel_id, if (roomHasEnded(room, now_seconds) or room.state == 0) "idle" else "playing" });
    if (persistence != .none) {
        try writer.writeAll(",\"zigcho_score_records\":[");
        var score_written: usize = 0;
        for (room.scores.items) |score| {
            if (score_written != 0) try writer.writeByte(',');
            try writer.print("{{\"score_id\":{d},\"user_id\":{d},\"playlist_item_id\":{d},\"total_score\":{d},\"accuracy\":{d},\"max_combo\":{d},\"passed\":{s}}}", .{ score.score_id, score.user_id, score.playlist_item_id, score.total_score, score.accuracy, score.max_combo, if (score.passed) "true" else "false" });
            score_written += 1;
        }
        try writer.writeAll("],\"zigcho_score_tokens\":[");
        for (room.score_tokens.items, 0..) |token, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.print("{{\"token_id\":{d},\"user_id\":{d},\"playlist_item_id\":{d},\"score_id\":", .{ token.token_id, token.user_id, token.playlist_item_id });
            if (token.score_id) |score_id| try writer.print("{d}", .{score_id}) else try writer.writeAll("null");
            try writer.writeByte('}');
        }
        try writer.writeByte(']');
    }
    if (persistence == .checkpoint) {
        try writer.writeAll(",\"zigcho_resumable\":true,\"zigcho_password\":");
        try std.json.Stringify.value(room.settings.password.slice(), .{}, writer);
        try writer.print(",\"zigcho_starts_at\":{d},\"zigcho_ends_at\":{d},\"zigcho_current_playlist_item_id\":{d},\"zigcho_active_users\":[", .{ room.starts_at, room.ends_at, room.settings.playlist_item_id });
        var active_written: usize = 0;
        for (room.users) |entry| if (entry) |user| {
            if (active_written != 0) try writer.writeByte(',');
            try writeApiUserJson(writer, user.id, user.name.slice(), user.country);
            active_written += 1;
        };
        try writer.writeAll("],\"zigcho_participants\":[");
        for (room.participants[0..room.participant_count], 0..) |entry, index| if (entry) |participant| {
            if (index != 0) try writer.writeByte(',');
            try writeApiUserJson(writer, participant.id, participant.name.slice(), participant.country);
        };
        try writer.writeByte(']');
    }
    try writeRoomModeJson(writer, room);
    try writer.writeByte('}');
}

fn writeRoomLeaderboardJson(allocator: std.mem.Allocator, writer: *std.Io.Writer, room: *const Room, requester_id: i32) !void {
    const Aggregate = struct {
        user: RoomParticipant,
        attempts: i32 = 0,
        completed: i32 = 0,
        total_score: i64 = 0,
        accuracy_total: f64 = 0,
    };
    var aggregates: [max_room_participants]?Aggregate = [_]?Aggregate{null} ** max_room_participants;
    var aggregate_count: usize = 0;
    const playlist_room = room.settings.match_type == 0;
    var playlist_high_scores: ?[]?RoomScoreRecord = null;
    defer if (playlist_high_scores) |scores| allocator.free(scores);
    if (playlist_room) {
        playlist_high_scores = try allocator.alloc(?RoomScoreRecord, max_room_participants * max_playlist);
        @memset(playlist_high_scores.?, null);
    }
    for (room.scores.items) |score| {
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
        if (playlist_room) {
            if (!scoreEligibleForHighScore(score, false)) continue;
            const item_index = room.itemIndex(score.playlist_item_id) orelse continue;
            const high_score = &playlist_high_scores.?[aggregate_index.? * max_playlist + item_index];
            if (high_score.* == null or scoreRanksBefore(score, high_score.*.?)) high_score.* = score;
        } else {
            aggregate.completed += @intFromBool(score.passed);
            aggregate.total_score += score.total_score;
            aggregate.accuracy_total += score.accuracy;
        }
    }
    if (playlist_room) {
        for (aggregates[0..aggregate_count], 0..) |*entry, aggregate_index| {
            const aggregate = &entry.*.?;
            for (playlist_high_scores.?[aggregate_index * max_playlist ..][0..max_playlist]) |high_score| if (high_score) |score| {
                aggregate.completed += 1;
                aggregate.total_score += score.total_score;
                aggregate.accuracy_total += score.accuracy;
            };
        }
        var ranked_count: usize = 0;
        for (aggregates[0..aggregate_count]) |entry| {
            if (entry.?.completed == 0) continue;
            aggregates[ranked_count] = entry;
            ranked_count += 1;
        }
        aggregate_count = ranked_count;
    }
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
        const accuracy_divisor = if (playlist_room) aggregate.completed else aggregate.attempts;
        try writer.print("{{\"attempts\":{d},\"completed\":{d},\"accuracy\":{d},\"pp\":null,\"room_id\":{d},\"total_score\":{d},\"user_id\":{d},\"user\":", .{ aggregate.attempts, aggregate.completed, aggregate.accuracy_total / @as(f64, @floatFromInt(accuracy_divisor)), room.id, aggregate.total_score, aggregate.user.id });
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
        const accuracy_divisor = if (playlist_room) aggregate.completed else aggregate.attempts;
        try writer.print("{{\"attempts\":{d},\"completed\":{d},\"accuracy\":{d},\"pp\":null,\"room_id\":{d},\"total_score\":{d},\"user_id\":{d},\"user\":", .{ aggregate.attempts, aggregate.completed, aggregate.accuracy_total / @as(f64, @floatFromInt(accuracy_divisor)), room.id, aggregate.total_score, aggregate.user.id });
        try writeApiUserJson(writer, aggregate.user.id, aggregate.user.name.slice(), aggregate.user.country);
        try writer.print(",\"position\":{d}}}", .{index + 1});
    } else try writer.writeAll("null");
    try writer.writeByte('}');
}

fn writeRoomScorePage(writer: *std.Io.Writer, scores: []const []const u8, sort: []const u8) !void {
    try writer.writeAll("{\"scores\":[");
    for (scores, 0..) |score, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll(score);
    }
    try writer.print("],\"params\":{{\"limit\":{d},\"sort\":", .{room_score_around_limit});
    try std.json.Stringify.value(sort, .{}, writer);
    try writer.writeAll("},\"cursor\":null}");
}

/// Add the fields consumed by PlaylistItemResultsScreen to a stored lazer
/// score. `higher` is ordered nearest-first because the pinned client assigns
/// positions by walking away from the selected score.
pub fn writeRoomScoreDetailJson(writer: *std.Io.Writer, score_json: []const u8, position: usize, higher: []const []const u8, lower: []const []const u8) !void {
    if (score_json.len < 2 or score_json[0] != '{' or score_json[score_json.len - 1] != '}') return error.InvalidRoomScoreJson;
    try writer.writeAll(score_json[0 .. score_json.len - 1]);
    try writer.print(",\"position\":{d},\"scores_around\":{{\"higher\":", .{position});
    try writeRoomScorePage(writer, higher, "score_asc");
    try writer.writeAll(",\"lower\":");
    try writeRoomScorePage(writer, lower, "score_desc");
    try writer.writeAll("}}");
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

fn eventMatchStartCountdownOwned(allocator: std.mem.Allocator, countdown: MatchStartCountdownState, now_ms: i64) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchEvent", 1);
    // MatchServerEvent union key 0 is CountdownStartedEvent.
    try pack.array(2);
    try pack.integer(0);
    try pack.array(1);
    try writeMatchStartCountdown(pack, countdown, now_ms);
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

fn eventMatchRoomStateOwned(allocator: std.mem.Allocator, room: *const Room) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchRoomStateChanged", 1);
    try writeMatchState(pack, room);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventTeamStateOwned(allocator: std.mem.Allocator, user_id: i32, team_id: i32) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchUserStateChanged", 2);
    try pack.integer(user_id);
    try pack.array(2);
    try pack.integer(0);
    try pack.array(1);
    try pack.integer(team_id);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventRollOwned(allocator: std.mem.Allocator, user_id: i32, max: i64, result: i64) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchEvent", 1);
    // MatchServerEvent union key 4 is RollEvent.
    try pack.array(2);
    try pack.integer(4);
    try pack.array(3);
    try pack.integer(user_id);
    try pack.integer(max);
    try pack.integer(result);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventMatchmakingAvatarActionOwned(allocator: std.mem.Allocator, user_id: i32, action: i64) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchEvent", 1);
    // MatchServerEvent union key 2 is MatchmakingAvatarActionEvent.
    try pack.array(2);
    try pack.integer(2);
    try pack.array(2);
    try pack.integer(user_id);
    try pack.integer(action);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventRankedHandReplayOwned(allocator: std.mem.Allocator, user_id: i32, frames: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchEvent", 1);
    // MatchServerEvent union key 3 is RankedPlayCardHandReplayEvent.
    try pack.array(2);
    try pack.integer(3);
    try pack.array(2);
    try pack.integer(user_id);
    try pack.raw(frames);
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
    try std.testing.expectEqual(RoomListKind.realtime, (try roomListFilter(4, "open", "idle", "realtime")).kind);
    try std.testing.expectEqual(RoomListKind.playlists, (try roomListFilter(4, "open", null, "")).kind);
    try std.testing.expectError(error.InvalidRoomListFilter, roomListFilter(4, "closed", null, "realtime"));
    try std.testing.expectError(error.InvalidRoomListFilter, roomListFilter(4, "open", null, "made_up"));
}

test "multiplayer never serializes a hidden local country" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/room-country-privacy.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("hidden host", "hidden-host@example.invalid", "00000000000000000000000000000000");
    try store.updateCountry(user_id, .{ 'A', 'U' });
    try store.updateSiteProfile(user_id, .{ .bio = "", .title = "", .pronouns = "", .location = "", .website = "", .accent = .pink, .preferred_mode = 0, .profile_source = .all, .avatar_key = 1, .show_country = false, .show_profile_stats = true, .show_recent_scores = true });
    const archived = try std.fmt.allocPrint(std.testing.allocator, "{{\"id\":99,\"host\":{{\"id\":{d},\"username\":\"hidden host\",\"country_code\":\"AU\"}},\"recent_participants\":[{{\"id\":{d},\"username\":\"hidden host\",\"country_code\":\"AU\"}}],\"playlist\":[]}}", .{ user_id, user_id });
    defer std.testing.allocator.free(archived);
    const archived_leaderboard = try std.fmt.allocPrint(std.testing.allocator, "{{\"leaderboard\":[{{\"user\":{{\"id\":{d},\"username\":\"hidden host\",\"country_code\":\"AU\"}}}}],\"user_score\":{{\"user\":{{\"id\":{d},\"username\":\"hidden host\",\"country_code\":\"AU\"}}}}}}", .{ user_id, user_id });
    defer std.testing.allocator.free(archived_leaderboard);
    try store.saveLazerMultiplayerRoomArchive(99, user_id, "realtime", archived, archived_leaderboard, "[]");

    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    const user = (try store.userById(std.testing.allocator, user_id)).?;
    defer std.testing.allocator.free(user.name);
    defer std.testing.allocator.free(user.safe_name);
    try std.testing.expect(!user.show_country);

    const archived_json = (try manager.roomsJson(std.testing.allocator, 99, null, 0)).?;
    defer std.testing.allocator.free(archived_json);
    try std.testing.expect(std.mem.indexOf(u8, archived_json, "\"country_code\":\"AU\"") == null);
    try std.testing.expect(std.mem.count(u8, archived_json, "\"country_code\":\"XX\"") == 2);
    const leaderboard_json = (try manager.roomLeaderboardJson(std.testing.allocator, user_id, 99)).?;
    defer std.testing.allocator.free(leaderboard_json);
    try std.testing.expect(std.mem.indexOf(u8, leaderboard_json, "\"country_code\":\"AU\"") == null);
    try std.testing.expect(std.mem.count(u8, leaderboard_json, "\"country_code\":\"XX\"") == 2);

    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const connection = try manager.connect(user, fake_socket);
    connection.socket = null;
    try std.testing.expectEqualSlices(u8, "XX", &connection.user_country);
    const created = try manager.restCreateRoom(std.testing.allocator, user,
        \\{"name":"private country","type":"head_to_head","playlist":[{"id":8,"owner_id":0,"beatmap_id":75,"ruleset_id":0}]}
    );
    defer std.testing.allocator.free(created);
    try std.testing.expect(std.mem.indexOf(u8, created, "\"country_code\":\"AU\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, created, "\"country_code\":\"XX\"") != null);
    try manager.restCloseRoom(user_id, 100);
    manager.disconnect(connection);
}

test "playlist score detail follows pinned position and scores around JSON" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const higher = [_][]const u8{
        "{\"id\":12,\"total_score\":900}",
        "{\"id\":11,\"total_score\":1000}",
    };
    const lower = [_][]const u8{"{\"id\":14,\"total_score\":700}"};
    try writeRoomScoreDetailJson(&output.writer, "{\"id\":13,\"total_score\":800}", 3, &higher, &lower);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 3), parsed.value.object.get("position").?.integer);
    const around = parsed.value.object.get("scores_around").?.object;
    const higher_page = around.get("higher").?.object;
    try std.testing.expectEqual(@as(i64, 12), higher_page.get("scores").?.array.items[0].object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, room_score_around_limit), higher_page.get("params").?.object.get("limit").?.integer);
    try std.testing.expectEqualStrings("score_asc", higher_page.get("params").?.object.get("sort").?.string);
    try std.testing.expect(std.meta.activeTag(higher_page.get("cursor").?) == .null);
    const lower_page = around.get("lower").?.object;
    try std.testing.expectEqual(@as(i64, 14), lower_page.get("scores").?.array.items[0].object.get("id").?.integer);
    try std.testing.expectEqualStrings("score_desc", lower_page.get("params").?.object.get("sort").?.string);
    try std.testing.expectError(error.InvalidRoomScoreJson, writeRoomScoreDetailJson(&output.writer, "[]", 1, &.{}, &.{}));
}

test "playlist score ordering is deterministic across score ties" {
    var scores = [_]RoomScoreRecord{
        .{ .score_id = 14, .user_id = 4, .playlist_item_id = 8, .total_score = 900, .accuracy = 1, .max_combo = 1, .passed = true },
        .{ .score_id = 11, .user_id = 7, .playlist_item_id = 8, .total_score = 1000, .accuracy = 1, .max_combo = 1, .passed = true },
        .{ .score_id = 12, .user_id = 9, .playlist_item_id = 8, .total_score = 900, .accuracy = 1, .max_combo = 1, .passed = true },
    };
    sortRoomScores(&scores);
    try std.testing.expectEqual(@as(i64, 11), scores[0].score_id);
    try std.testing.expectEqual(@as(i64, 12), scores[1].score_id);
    try std.testing.expectEqual(@as(i64, 14), scores[2].score_id);
}

test "playlist and realtime rooms promote the same failed score differently" {
    const failed: RoomScoreRecord = .{
        .score_id = 15,
        .user_id = 4,
        .playlist_item_id = 8,
        .total_score = 900,
        .accuracy = 0.75,
        .max_combo = 25,
        .passed = false,
    };
    const zero_pass: RoomScoreRecord = .{
        .score_id = 16,
        .user_id = 7,
        .playlist_item_id = 8,
        .total_score = 0,
        .accuracy = 1,
        .max_combo = 1,
        .passed = true,
    };
    var normal: std.ArrayList(RoomScoreRecord) = .empty;
    defer normal.deinit(std.testing.allocator);
    try considerHighScore(std.testing.allocator, &normal, failed, false);
    try considerHighScore(std.testing.allocator, &normal, zero_pass, false);
    try std.testing.expectEqual(@as(usize, 0), normal.items.len);

    var realtime: std.ArrayList(RoomScoreRecord) = .empty;
    defer realtime.deinit(std.testing.allocator);
    try considerHighScore(std.testing.allocator, &realtime, failed, true);
    try considerHighScore(std.testing.allocator, &realtime, zero_pass, true);
    try std.testing.expectEqual(@as(usize, 1), realtime.items.len);
    try std.testing.expectEqual(failed.score_id, realtime.items[0].score_id);
}

test "reconnect shutdown and invitation expiry use pinned no-argument hub events" {
    for ([_][]const u8{ "DisconnectRequested", "ServerShuttingDown", "MatchmakingQueueLeft" }) |target| {
        const frame = try eventNoArgsOwned(std.testing.allocator, target);
        defer std.testing.allocator.free(frame);
        var prefix_len: usize = 0;
        while (frame[prefix_len] & 0x80 != 0) prefix_len += 1;
        prefix_len += 1;
        var reader: MessagePackReader = .{ .data = frame[prefix_len..] };
        try std.testing.expectEqual(@as(usize, 6), try reader.arrayLen());
        try std.testing.expectEqual(@as(i64, 1), try reader.integer());
        try std.testing.expectEqual(@as(usize, 0), try reader.mapLen());
        try reader.skip(0);
        try std.testing.expectEqualStrings(target, try reader.string());
        try std.testing.expectEqual(@as(usize, 0), try reader.arrayLen());
        try std.testing.expectEqual(@as(usize, 0), try reader.arrayLen());
        try std.testing.expectEqual(reader.data.len, reader.pos);
    }
}

test "multiplayer feature gate drains sessions at the invocation boundary and reopens" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const user: domain.User = .{ .id = 4, .name = "gate user", .safe_name = "gate_user", .country = .{ 'A', 'U' } };
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const connection = try manager.connect(user, fake_socket);
    connection.socket = null;
    const stale_user: domain.User = .{ .id = 7, .name = "stale gate", .safe_name = "stale_gate", .country = .{ 'G', 'B' } };
    const stale = try manager.connect(stale_user, fake_socket);
    stale.socket = null;
    stale.close();
    try std.testing.expectEqual(@as(usize, 2), manager.connections.items.len);
    try std.testing.expectEqual(@as(usize, 1), manager.runtimeCounts().connections);

    const Toggle = struct {
        manager: *Manager,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),

        fn run(context: *@This()) void {
            context.started.store(true, .release);
            context.manager.setEnabled(false);
            context.done.store(true, .release);
        }
    };
    connection.invocation_mutex.lockUncancelable(std.testing.io);
    var toggle: Toggle = .{ .manager = &manager };
    const thread = try std.Thread.spawn(.{}, Toggle.run, .{&toggle});
    while (manager.isEnabled()) std.Thread.yield() catch {};
    try std.testing.expect(toggle.started.load(.acquire));
    try std.testing.expect(!toggle.done.load(.acquire));
    connection.queue_pool_id = 101;
    connection.invocation_mutex.unlock(std.testing.io);
    thread.join();

    try std.testing.expect(!manager.isEnabled());
    try std.testing.expect(!connection.alive.load(.acquire));
    try std.testing.expect(!connection.accepting_invocations.load(.acquire));
    try std.testing.expectEqual(@as(?i32, null), connection.queue_pool_id);
    try std.testing.expectEqual(@as(usize, 0), manager.connections.items.len);
    try std.testing.expectError(error.MultiplayerDisabled, manager.connect(user, fake_socket));
    try std.testing.expectError(error.ConnectionClose, manager.handleHubMessage(connection, &.{}));

    manager.setEnabled(true);
    try std.testing.expect(manager.isEnabled());
    const reopened = try manager.connect(user, fake_socket);
    reopened.socket = null;
    try std.testing.expect(reopened.alive.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), manager.connections.items.len);
    // The direct fixture owns the same final handler reference that serve()
    // normally releases after its read wakes on the close frame.
    manager.disconnect(connection);
    manager.disconnect(stale);
    manager.disconnect(reopened);
}

test "disabled multiplayer rejects REST room creation and reopens idempotently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/multiplayer-disable.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("rest gate", "rest-gate@example.invalid", "00000000000000000000000000000000");
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    const user: domain.User = .{ .id = user_id, .name = "rest gate", .safe_name = "rest_gate", .country = .{ 'A', 'U' } };
    const room_body =
        \\{"name":"rest gate room","type":"playlists","duration":30,"playlist":[{"id":8,"owner_id":0,"beatmap_id":75,"ruleset_id":0}]}
    ;

    const Toggle = struct {
        manager: *Manager,
        enabled: bool,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        fn run(context: *@This()) void {
            context.started.store(true, .release);
            context.manager.setEnabled(context.enabled);
            context.done.store(true, .release);
        }
    };
    var admitted = try manager.beginMutation();
    var disable: Toggle = .{ .manager = &manager, .enabled = false };
    const disable_thread = try std.Thread.spawn(.{}, Toggle.run, .{&disable});
    while (manager.isEnabled()) std.Thread.yield() catch {};
    var enable: Toggle = .{ .manager = &manager, .enabled = true };
    const enable_thread = try std.Thread.spawn(.{}, Toggle.run, .{&enable});
    while (!enable.started.load(.acquire)) std.Thread.yield() catch {};
    _ = std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    try std.testing.expect(!disable.done.load(.acquire));
    try std.testing.expect(!enable.done.load(.acquire));
    admitted.deinit();
    disable_thread.join();
    enable_thread.join();
    try std.testing.expect(manager.isEnabled());

    manager.setEnabled(false);
    try std.testing.expectError(error.MultiplayerDisabled, manager.restCreateRoom(std.testing.allocator, user, room_body));
    for (manager.rooms) |entry| try std.testing.expect(entry == null);

    manager.setEnabled(true);
    manager.setEnabled(true);
    const created = try manager.restCreateRoom(std.testing.allocator, user, room_body);
    defer std.testing.allocator.free(created);
    try std.testing.expect(manager.rooms[0] != null);

    manager.setEnabled(false);
    for (manager.rooms) |entry| try std.testing.expect(entry == null);
    var archived = (try store.lazerMultiplayerRoomArchive(std.testing.allocator, 1)).?;
    const first_ended_at = archived.ended_at;
    archived.deinit();
    manager.setEnabled(false);
    var unchanged = (try store.lazerMultiplayerRoomArchive(std.testing.allocator, 1)).?;
    defer unchanged.deinit();
    try std.testing.expectEqual(first_ended_at, unchanged.ended_at);
    manager.setEnabled(true);
    const recreated = try manager.restCreateRoom(std.testing.allocator, user, room_body);
    defer std.testing.allocator.free(recreated);
    try std.testing.expect(manager.rooms[0] != null);
    try std.testing.expectEqual(@as(i64, 2), manager.rooms[0].?.id);
}

test "shutdown rejects delayed websocket creation and checkpoints each room once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/multiplayer-boundary.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const host_id = try store.register("checkpoint host", "checkpoint-host@example.invalid", "00000000000000000000000000000000");
    const late_user_id = try store.register("late websocket", "late-websocket@example.invalid", "00000000000000000000000000000000");

    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    const host: domain.User = .{ .id = host_id, .name = "checkpoint host", .safe_name = "checkpoint_host", .country = .{ 'A', 'U' } };
    const late_user: domain.User = .{ .id = late_user_id, .name = "late websocket", .safe_name = "late_websocket", .country = .{ 'G', 'B' } };
    const room_body =
        \\{"name":"checkpoint once","type":"playlists","duration":30,"playlist":[{"id":8,"owner_id":0,"beatmap_id":75,"ruleset_id":0}]}
    ;
    const created = try manager.restCreateRoom(std.testing.allocator, host, room_body);
    defer std.testing.allocator.free(created);

    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const connection = try manager.connect(late_user, fake_socket);
    connection.socket = null;
    var client_room: Room = .{ .id = 0, .settings = .{}, .host_id = late_user.id, .host_country = late_user.country };
    try client_room.settings.name.set("too late");
    client_room.settings.match_type = 1;
    client_room.settings.playlist_item_id = 9;
    try client_room.settings.auto_start.set(&.{0xc0});
    try client_room.host_name.set(late_user.name);
    var item: PlaylistItem = .{ .id = 9, .owner_id = late_user.id, .beatmap_id = 76 };
    try item.required_mods.set(&.{0x90});
    try item.allowed_mods.set(&.{0x90});
    try item.played_at.set(&.{0xc0});
    client_room.playlist[0] = item;
    client_room.playlist_count = 1;
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try writeRoom(.{ .writer = &encoded.writer }, &client_room, 0);

    const DelayedCreate = struct {
        manager: *Manager,
        connection: *Connection,
        encoded: []const u8,
        proceed: std.atomic.Value(bool) = .init(false),
        rejected: bool = false,
        unexpected_error: ?anyerror = null,

        fn run(context: *@This()) void {
            while (!context.proceed.load(.acquire)) std.Thread.yield() catch {};
            context.manager.createRoom(context.connection, "late", context.encoded) catch |err| {
                if (err == error.ServerShuttingDown) context.rejected = true else context.unexpected_error = err;
                return;
            };
        }
    };
    const Stop = struct {
        manager: *Manager,
        fn run(value: *@This()) void {
            value.manager.shutdown();
        }
    };
    var delayed: DelayedCreate = .{ .manager = &manager, .connection = connection, .encoded = encoded.written() };
    var stop: Stop = .{ .manager = &manager };
    const delayed_thread = try std.Thread.spawn(.{}, DelayedCreate.run, .{&delayed});
    const shutdown_thread = try std.Thread.spawn(.{}, Stop.run, .{&stop});
    while (manager.isEnabled()) std.Thread.yield() catch {};
    delayed.proceed.store(true, .release);
    delayed_thread.join();
    shutdown_thread.join();

    try std.testing.expect(delayed.rejected);
    try std.testing.expectEqual(@as(?anyerror, null), delayed.unexpected_error);
    for (manager.rooms) |entry| try std.testing.expect(entry == null);
    const checkpoints = try store.lazerMultiplayerRoomCheckpoints(std.testing.allocator);
    defer {
        for (checkpoints) |*checkpoint| checkpoint.deinit();
        std.testing.allocator.free(checkpoints);
    }
    try std.testing.expectEqual(@as(usize, 1), checkpoints.len);
    try std.testing.expectEqual(@as(i64, 1), checkpoints[0].room_id);
    manager.shutdown();
    const repeated = try store.lazerMultiplayerRoomCheckpoints(std.testing.allocator);
    defer {
        for (repeated) |*checkpoint| checkpoint.deinit();
        std.testing.allocator.free(repeated);
    }
    try std.testing.expectEqual(@as(usize, 1), repeated.len);
}

test "one websocket identity rebinds room and queue state without duplicate membership" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const host: domain.User = .{ .id = 4, .name = "raya", .safe_name = "raya", .country = .{ 'A', 'U' } };
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const old = try manager.connect(host, fake_socket);
    old.socket = null;
    const room_body =
        \\{"name":"reconnect","type":"head_to_head","playlist":[{"id":8,"owner_id":4,"beatmap_id":75,"ruleset_id":0}]}
    ;
    const created = try manager.restCreateRoom(std.testing.allocator, host, room_body);
    defer std.testing.allocator.free(created);
    try std.testing.expectEqual(@as(?i64, 1), old.room_id);

    const replacement = try manager.connect(host, fake_socket);
    replacement.socket = null;
    try std.testing.expect(!old.alive.load(.acquire));
    try std.testing.expectEqual(@as(?i64, null), old.room_id);
    try std.testing.expectEqual(@as(?i64, 1), replacement.room_id);
    try std.testing.expectEqual(@as(usize, 1), manager.connections.items.len);
    try std.testing.expect(manager.connections.items[0] == replacement);
    try manager.joinRoom(replacement, "1", 1, "");
    try std.testing.expectEqual(@as(usize, 1), manager.rooms[0].?.user_count);
    try std.testing.expectError(error.ConnectionClose, manager.handleHubMessage(old, &.{}));
    manager.disconnect(old);

    try manager.leaveRoom(replacement, null);
    replacement.lobby_pool_id = 100;
    replacement.queue_pool_id = 100;
    replacement.pending_match_id = 7;
    manager.pending_matches[0] = .{ .id = 7, .pool_id = 100, .users = .{ host.id, 7 }, .created_at = 0 };
    const queued_replacement = try manager.connect(host, fake_socket);
    queued_replacement.socket = null;
    try std.testing.expectEqual(@as(?i32, 100), queued_replacement.lobby_pool_id);
    try std.testing.expectEqual(@as(?i32, 100), queued_replacement.queue_pool_id);
    try std.testing.expectEqual(@as(?u32, 7), queued_replacement.pending_match_id);
    try std.testing.expectEqual(@as(usize, 1), manager.connections.items.len);
    manager.disconnect(replacement);
    try std.testing.expectEqual(@as(usize, 0), manager.expirePendingMatches(pending_match_timeout_seconds - 1));
    try std.testing.expectEqual(@as(usize, 1), manager.expirePendingMatches(pending_match_timeout_seconds));
    try std.testing.expectEqual(@as(?i32, null), queued_replacement.queue_pool_id);
    try std.testing.expectEqual(@as(?u32, null), queued_replacement.pending_match_id);
    try std.testing.expect(manager.pending_matches[0] == null);
}

test "cross client disconnect stops invocations and is idempotent" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const user: domain.User = .{ .id = 4, .name = "takeover", .safe_name = "takeover", .country = .{ 'A', 'U' } };
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const connection = try manager.connect(user, fake_socket);
    connection.socket = null;
    const created = try manager.restCreateRoom(std.testing.allocator, user,
        \\{"name":"takeover room","type":"head_to_head","playlist":[{"id":8,"owner_id":4,"beatmap_id":75,"ruleset_id":0}]}
    );
    defer std.testing.allocator.free(created);
    try std.testing.expectEqual(@as(?i64, 1), connection.room_id);

    const Takeover = struct {
        manager: *Manager,
        user_id: i32,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        disconnected: bool = false,

        fn run(context: *@This()) void {
            context.started.store(true, .release);
            context.disconnected = context.manager.disconnectUser(context.user_id);
            context.done.store(true, .release);
        }
    };
    connection.invocation_mutex.lockUncancelable(std.testing.io);
    var takeover: Takeover = .{ .manager = &manager, .user_id = user.id };
    const takeover_thread = try std.Thread.spawn(.{}, Takeover.run, .{&takeover});
    while (!takeover.started.load(.acquire)) std.Thread.yield() catch {};
    _ = std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    try std.testing.expect(!takeover.done.load(.acquire));
    // This is the final mutation committed by the already-running invocation.
    // The takeover must wait for it and synchronously clear it before return.
    connection.lobby_pool_id = 101;
    connection.queue_pool_id = 101;
    connection.invocation_mutex.unlock(std.testing.io);
    takeover_thread.join();

    try std.testing.expect(takeover.disconnected);
    try std.testing.expect(!connection.alive.load(.acquire));
    try std.testing.expect(!connection.accepting_invocations.load(.acquire));
    try std.testing.expectEqual(@as(?i64, null), connection.room_id);
    try std.testing.expectEqual(@as(?i32, null), connection.lobby_pool_id);
    try std.testing.expectEqual(@as(?i32, null), connection.queue_pool_id);
    try std.testing.expectEqual(@as(usize, 0), manager.connections.items.len);
    for (manager.rooms) |entry| try std.testing.expect(entry == null);
    try std.testing.expect(!manager.disconnectUser(user.id));
    try std.testing.expectError(error.ConnectionClose, manager.handleHubMessage(connection, &.{}));
    // The real websocket handler owns the final reference until its blocked
    // read observes the close frame. This direct-manager fixture releases it
    // explicitly after making the same deferred disconnect call.
    manager.disconnect(connection);
}

test "connection replacement waits only for the old identity invocation boundary" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const host: domain.User = .{ .id = 4, .name = "raya", .safe_name = "raya", .country = .{ 'A', 'U' } };
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const old = try manager.connect(host, fake_socket);
    old.socket = null;

    const Replacement = struct {
        manager: *Manager,
        user: domain.User,
        socket: *std.http.Server.WebSocket,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        result: ?*Connection = null,
        failure: ?anyerror = null,

        fn run(context: *@This()) void {
            context.started.store(true, .release);
            context.result = context.manager.connect(context.user, context.socket) catch |err| failed: {
                context.failure = err;
                break :failed null;
            };
            context.done.store(true, .release);
        }
    };

    old.invocation_mutex.lockUncancelable(std.testing.io);
    var replacement_context: Replacement = .{ .manager = &manager, .user = host, .socket = fake_socket };
    const replacement_thread = try std.Thread.spawn(.{}, Replacement.run, .{&replacement_context});
    while (!replacement_context.started.load(.acquire)) std.Thread.yield() catch {};
    _ = std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    const crossed_boundary = replacement_context.done.load(.acquire);
    const guest: domain.User = .{ .id = 7, .name = "other room", .safe_name = "other_room", .country = .{ 'G', 'B' } };
    const unrelated = try manager.connect(guest, fake_socket);
    unrelated.socket = null;
    try std.testing.expectEqual(@as(usize, 2), manager.connections.items.len);
    manager.disconnect(unrelated);
    // This assignment stands in for the final state committed by the old
    // invocation while the replacement is waiting at the gate.
    old.room_id = 77;
    old.invocation_mutex.unlock(std.testing.io);
    replacement_thread.join();

    try std.testing.expect(!crossed_boundary);
    try std.testing.expect(replacement_context.failure == null);
    const replacement = replacement_context.result.?;
    replacement.socket = null;
    try std.testing.expectEqual(@as(?i64, 77), replacement.room_id);
    try std.testing.expect(!old.alive.load(.acquire));
    manager.disconnect(old);
}

const HostileInvocationHarness = struct {
    fn expectRejected(manager: *Manager, connection: *Connection, target: []const u8, argument_count: usize, encoded: []const u8) !void {
        var reader: MessagePackReader = .{ .data = encoded };
        try std.testing.expectError(error.InvalidMultiplayerArguments, manager.handleInvocation(connection, null, target, argument_count, &reader));
    }

    fn writeSettings(output: *std.Io.Writer.Allocating, match_type: i64, queue_mode: i64, max_participants: i64) !void {
        output.clearRetainingCapacity();
        const pack: MessagePackWriter = .{ .writer = &output.writer };
        try pack.array(8);
        try pack.string("hostile");
        try pack.integer(1);
        try pack.string("");
        try pack.integer(match_type);
        try pack.integer(queue_mode);
        try pack.nil();
        try pack.boolean(false);
        try pack.integer(max_participants);
    }

    fn writePlaylistItem(output: *std.Io.Writer.Allocating, owner_id: i64, beatmap_id: i64, ruleset_id: i64, order: i64, star_rating: f64) !void {
        output.clearRetainingCapacity();
        const pack: MessagePackWriter = .{ .writer = &output.writer };
        try pack.array(12);
        try pack.integer(1);
        try pack.integer(owner_id);
        try pack.integer(beatmap_id);
        try pack.string("");
        try pack.integer(ruleset_id);
        try pack.array(0);
        try pack.array(0);
        try pack.boolean(false);
        try pack.integer(order);
        try pack.nil();
        try pack.float64(star_rating);
        try pack.boolean(false);
    }
};

test "hostile multiplayer integers never trap narrow invocation or model fields" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    var connection: Connection = .{
        .allocator = std.testing.allocator,
        .user_id = 4,
        .user_country = .{ 'A', 'U' },
        .io = std.testing.io,
        .socket = null,
    };
    try connection.user_name.set("hostile");
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    const direct_targets = [_][]const u8{
        "TransferHost",
        "KickUser",
        "ChangeState",
        "InvitePlayer",
        "GetMatchmakingPoolsOfType",
        "MatchmakingJoinQueue",
    };
    for ([_]i64{ std.math.minInt(i64), std.math.maxInt(i64) }) |extreme| {
        for (direct_targets) |target| {
            encoded.clearRetainingCapacity();
            try (MessagePackWriter{ .writer = &encoded.writer }).integer(extreme);
            try HostileInvocationHarness.expectRejected(&manager, &connection, target, 1, encoded.written());
        }

        encoded.clearRetainingCapacity();
        var pack: MessagePackWriter = .{ .writer = &encoded.writer };
        try pack.integer(extreme);
        try pack.nil();
        try HostileInvocationHarness.expectRejected(&manager, &connection, "ChangeUserStyle", 2, encoded.written());
        encoded.clearRetainingCapacity();
        pack = .{ .writer = &encoded.writer };
        try pack.nil();
        try pack.integer(extreme);
        try HostileInvocationHarness.expectRejected(&manager, &connection, "ChangeUserStyle", 2, encoded.written());

        encoded.clearRetainingCapacity();
        pack = .{ .writer = &encoded.writer };
        try pack.array(1);
        try pack.integer(extreme);
        try HostileInvocationHarness.expectRejected(&manager, &connection, "MatchmakingJoinLobbyWithParams", 1, encoded.written());
        encoded.clearRetainingCapacity();
        pack = .{ .writer = &encoded.writer };
        try pack.array(2);
        try pack.integer(extreme);
        try pack.integer(1);
        try HostileInvocationHarness.expectRejected(&manager, &connection, "MatchmakingIssueDuel", 1, encoded.written());
        encoded.clearRetainingCapacity();
        pack = .{ .writer = &encoded.writer };
        try pack.array(2);
        try pack.integer(1);
        try pack.integer(extreme);
        try HostileInvocationHarness.expectRejected(&manager, &connection, "MatchmakingIssueDuel", 1, encoded.written());

        try HostileInvocationHarness.writeSettings(&encoded, extreme, 0, 2);
        try std.testing.expectError(error.InvalidMultiplayerArguments, parseSettings(encoded.written()));
        try HostileInvocationHarness.writeSettings(&encoded, 1, extreme, 2);
        try std.testing.expectError(error.InvalidMultiplayerArguments, parseSettings(encoded.written()));
        try HostileInvocationHarness.writeSettings(&encoded, 1, 0, extreme);
        try std.testing.expectError(error.InvalidMultiplayerArguments, parseSettings(encoded.written()));

        try HostileInvocationHarness.writePlaylistItem(&encoded, extreme, 75, 0, 0, 5);
        try std.testing.expectError(error.InvalidMultiplayerArguments, parsePlaylistItem(encoded.written()));
        try HostileInvocationHarness.writePlaylistItem(&encoded, 4, extreme, 0, 0, 5);
        try std.testing.expectError(error.InvalidMultiplayerArguments, parsePlaylistItem(encoded.written()));
        try HostileInvocationHarness.writePlaylistItem(&encoded, 4, 75, extreme, 0, 5);
        try std.testing.expectError(error.InvalidMultiplayerArguments, parsePlaylistItem(encoded.written()));
        try HostileInvocationHarness.writePlaylistItem(&encoded, 4, 75, 0, extreme, 5);
        try std.testing.expectError(error.InvalidMultiplayerArguments, parsePlaylistItem(encoded.written()));
    }

    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |non_finite| {
        try HostileInvocationHarness.writePlaylistItem(&encoded, 4, 75, 0, 0, non_finite);
        try std.testing.expectError(error.InvalidMultiplayerBeatmap, parsePlaylistItem(encoded.written()));
    }
}

test "typed match requests follow pinned countdown team slot roll and lock contracts" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const room = try std.testing.allocator.create(Room);
    room.* = .{
        .id = 1,
        .settings = .{},
        .host_id = 4,
        .host_country = .{ 'A', 'U' },
    };
    room.settings.match_type = 2;
    room.settings.max_participants = 4;
    try room.settings.name.set("typed requests");
    try room.host_name.set("raya");
    room.users[0] = try defaultRoomUser(4, "raya", .{ 'A', 'U' });
    room.users[0].?.team_id = 0;
    room.users[1] = try defaultRoomUser(7, "guest", .{ 'G', 'B' });
    room.users[1].?.team_id = 1;
    room.user_count = 2;
    manager.rooms[0] = room;

    var host: Connection = .{
        .allocator = std.testing.allocator,
        .user_id = 4,
        .user_country = .{ 'A', 'U' },
        .room_id = 1,
        .io = std.testing.io,
    };
    try host.user_name.set("raya");
    var guest: Connection = .{
        .allocator = std.testing.allocator,
        .user_id = 7,
        .user_country = .{ 'G', 'B' },
        .room_id = 1,
        .io = std.testing.io,
    };
    try guest.user_name.set("guest");

    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    const pack: MessagePackWriter = .{ .writer = &encoded.writer };

    // MatchUserRequest union key 0: ChangeTeamRequest { TeamID = 0 }.
    try pack.array(2);
    try pack.integer(0);
    try pack.array(1);
    try pack.integer(0);
    try manager.sendMatchRequest(&guest, null, encoded.written());
    try std.testing.expectEqual(@as(?i32, 0), room.users[1].?.team_id);

    // MatchUserRequest union key 1: StartMatchCountdownRequest { Duration = 5 seconds }.
    encoded.clearRetainingCapacity();
    try pack.array(2);
    try pack.integer(1);
    try pack.array(1);
    try pack.integer(5 * timespan_ticks_per_second);
    try manager.sendMatchRequest(&host, null, encoded.written());
    const countdown = room.match_start_countdown.?;
    try std.testing.expectEqual(@as(i32, 1), countdown.id);
    try std.testing.expectEqual(@as(i64, 2 * timespan_ticks_per_second), countdown.remainingTicks(countdown.deadline_ms - 2 * std.time.ms_per_s));

    // MatchUserRequest union key 2: StopCountdownRequest { ID = 1 }.
    encoded.clearRetainingCapacity();
    try pack.array(2);
    try pack.integer(2);
    try pack.array(1);
    try pack.integer(countdown.id);
    try manager.sendMatchRequest(&host, null, encoded.written());
    try std.testing.expect(room.match_start_countdown == null);

    // MatchUserRequest union key 5: SetLockStateRequest { Locked = true }.
    encoded.clearRetainingCapacity();
    try pack.array(2);
    try pack.integer(5);
    try pack.array(1);
    try pack.boolean(true);
    try manager.sendMatchRequest(&host, null, encoded.written());
    try std.testing.expect(room.locked);

    // MatchUserRequest union key 7: ChangeSlotRequest. Players cannot move while
    // locked, and occupied destinations are never swapped with the requester.
    encoded.clearRetainingCapacity();
    try pack.array(2);
    try pack.integer(7);
    try pack.array(1);
    try pack.integer(2);
    try std.testing.expectError(error.MultiplayerPermissionDenied, manager.sendMatchRequest(&guest, null, encoded.written()));
    try std.testing.expectEqual(@as(i32, 7), room.users[1].?.id);

    encoded.clearRetainingCapacity();
    try pack.array(2);
    try pack.integer(5);
    try pack.array(1);
    try pack.boolean(false);
    try manager.sendMatchRequest(&host, null, encoded.written());

    encoded.clearRetainingCapacity();
    try pack.array(2);
    try pack.integer(7);
    try pack.array(1);
    try pack.integer(2);
    try manager.sendMatchRequest(&guest, null, encoded.written());
    try std.testing.expect(room.users[1] == null);
    try std.testing.expectEqual(@as(i32, 7), room.users[2].?.id);

    encoded.clearRetainingCapacity();
    try pack.array(2);
    try pack.integer(7);
    try pack.array(1);
    try pack.integer(0);
    try std.testing.expectError(error.MultiplayerPermissionDenied, manager.sendMatchRequest(&guest, null, encoded.written()));
    try std.testing.expectEqual(@as(i32, 4), room.users[0].?.id);
    try std.testing.expectEqual(@as(i32, 7), room.users[2].?.id);

    // MatchUserRequest union key 6: RollRequest { Max = 20 }. The request is
    // accepted and the emitted event retains the pinned RollEvent union shape.
    encoded.clearRetainingCapacity();
    try pack.array(2);
    try pack.integer(6);
    try pack.array(1);
    try pack.integer(20);
    try manager.sendMatchRequest(&guest, null, encoded.written());

    const roll_frame = try eventRollOwned(std.testing.allocator, guest.user_id, 20, 7);
    defer std.testing.allocator.free(roll_frame);
    var frame_pos: usize = 0;
    var body_len: usize = 0;
    var shift: u6 = 0;
    while (true) {
        const byte_value = roll_frame[frame_pos];
        frame_pos += 1;
        body_len |= @as(usize, byte_value & 0x7f) << shift;
        if (byte_value & 0x80 == 0) break;
        shift += 7;
    }
    try std.testing.expectEqual(roll_frame.len - frame_pos, body_len);
    var event_reader: MessagePackReader = .{ .data = roll_frame[frame_pos..] };
    try std.testing.expectEqual(@as(usize, 6), try event_reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 1), try event_reader.integer());
    try std.testing.expectEqual(@as(usize, 0), try event_reader.mapLen());
    try event_reader.skip(0);
    try std.testing.expectEqualStrings("MatchEvent", try event_reader.string());
    try std.testing.expectEqual(@as(usize, 1), try event_reader.arrayLen());
    try std.testing.expectEqual(@as(usize, 2), try event_reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 4), try event_reader.integer());
    try std.testing.expectEqual(@as(usize, 3), try event_reader.arrayLen());
    try std.testing.expectEqual(@as(i64, guest.user_id), try event_reader.integer());
    try std.testing.expectEqual(@as(i64, 20), try event_reader.integer());
    try std.testing.expectEqual(@as(i64, 7), try event_reader.integer());
    try std.testing.expectEqual(@as(usize, 0), try event_reader.arrayLen());
    try std.testing.expectEqual(event_reader.data.len, event_reader.pos);

    // MessagePack-CSharp request objects have exactly one keyed field. Reject
    // extra fields instead of accepting a malformed union and ignoring data.
    encoded.clearRetainingCapacity();
    try pack.array(2);
    try pack.integer(6);
    try pack.array(2);
    try pack.integer(20);
    try pack.integer(21);
    try std.testing.expectError(error.InvalidMultiplayerArguments, manager.sendMatchRequest(&guest, null, encoded.written()));

    // The room-state response keeps the pinned TeamVersusRoomState union,
    // including lock state and the exact sparse slot array.
    encoded.clearRetainingCapacity();
    try writeMatchState(pack, room);
    var state_reader: MessagePackReader = .{ .data = encoded.written() };
    try std.testing.expectEqual(@as(usize, 2), try state_reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 0), try state_reader.integer());
    try std.testing.expectEqual(@as(usize, 3), try state_reader.arrayLen());
    try std.testing.expectEqual(@as(usize, 2), try state_reader.arrayLen());
    try state_reader.skip(0);
    try state_reader.skip(0);
    try std.testing.expect(!(try state_reader.boolean()));
    try std.testing.expectEqual(@as(usize, 4), try state_reader.arrayLen());
    try std.testing.expectEqual(@as(?i64, 4), try state_reader.nullableInteger());
    try std.testing.expectEqual(@as(?i64, null), try state_reader.nullableInteger());
    try std.testing.expectEqual(@as(?i64, 7), try state_reader.nullableInteger());
    try std.testing.expectEqual(@as(?i64, null), try state_reader.nullableInteger());
    try std.testing.expectEqual(state_reader.data.len, state_reader.pos);
}

fn restRoomAllocationRun(allocator: std.mem.Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io);
    // Avoid the deliberately best-effort shutdown serializer swallowing the
    // injected allocation failure after the operation under test has ended.
    defer {
        manager.shutting_down = true;
        manager.deinit();
    }
    const host: domain.User = .{ .id = 4, .name = "allocation host", .safe_name = "allocation_host", .country = .{ 'A', 'U' } };
    const guest: domain.User = .{ .id = 7, .name = "allocation guest", .safe_name = "allocation_guest", .country = .{ 'G', 'B' } };
    const room_body =
        \\{"name":"allocation room","type":"head_to_head","playlist":[{"id":8,"owner_id":4,"beatmap_id":75,"ruleset_id":0}]}
    ;
    const created = manager.restCreateRoom(allocator, host, room_body) catch |err| {
        for (manager.rooms) |entry| try std.testing.expect(entry == null);
        return err;
    };
    defer allocator.free(created);
    const room = manager.rooms[0].?;
    try std.testing.expectEqual(@as(usize, 1), room.user_count);

    const joined = manager.restJoinRoom(allocator, guest, room.id, "") catch |err| {
        try std.testing.expect(room.userIndex(guest.id) == null);
        try std.testing.expect(room.participantIndex(guest.id) == null);
        try std.testing.expectEqual(@as(usize, 1), room.user_count);
        return err;
    };
    defer allocator.free(joined);
    try std.testing.expect(room.userIndex(guest.id) != null);
    try std.testing.expect(room.participantIndex(guest.id) != null);
    try std.testing.expectEqual(@as(usize, 2), room.user_count);
    manager.bindRoomScoreToken(host.id, room.id, 8, 9001) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), room.score_tokens.items.len);
        return err;
    };
    try std.testing.expectEqual(@as(usize, 1), room.score_tokens.items.len);
    try std.testing.expect(manager.scoreSubmissionContext(host.id, room.id, 8, 9001) != null);
    try std.testing.expect(manager.scoreSubmissionContext(guest.id, room.id, 8, 9001) == null);
}

test "REST room create and join roll back every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, restRoomAllocationRun, .{});
}

test "lazer playlist creation assigns zero owner ids to the authenticated user" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const host: domain.User = .{ .id = 4, .name = "raya", .safe_name = "raya", .country = .{ 'A', 'U' } };
    const client_body =
        \\{"id":null,"name":"raya's awesome playlist","description":null,"password":null,"host":null,"category":"normal","duration":30,"starts_at":null,"ends_at":null,"max_participants":null,"participant_count":0,"recent_participants":[],"max_attempts":3,"playlist":[{"owner_id":0,"ruleset_id":0,"expired":false,"playlist_order":null,"played_at":null,"allowed_mods":[],"required_mods":[],"beatmap_id":1000000003,"freestyle":false}],"playlist_item_stats":null,"difficulty_range":null,"type":"playlists","queue_mode":"host_only","auto_skip":false,"auto_start_duration":0,"current_user_score":null,"current_playlist_item":null,"channel_id":0,"status":"idle","pinned":false}
    ;
    const created = try manager.restCreateRoom(std.testing.allocator, host, client_body);
    defer std.testing.allocator.free(created);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, created, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("id").?.integer);
    try std.testing.expectEqualStrings("playlists", parsed.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("normal", parsed.value.object.get("category").?.string);
    try std.testing.expect(std.meta.activeTag(parsed.value.object.get("starts_at").?) == .string);
    try std.testing.expect(std.meta.activeTag(parsed.value.object.get("ends_at").?) == .string);
    try std.testing.expect(!std.mem.eql(u8, parsed.value.object.get("starts_at").?.string, parsed.value.object.get("ends_at").?.string));
    try std.testing.expectEqual(@as(i64, 3), parsed.value.object.get("max_attempts").?.integer);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("current_user_score").?.object.get("playlist_item_attempts").?.array.items.len);
    try std.testing.expectEqual(@as(i64, host.id), parsed.value.object.get("playlist").?.array.items[0].object.get("owner_id").?.integer);
    try std.testing.expectEqual(@as(i64, host.id), parsed.value.object.get("current_playlist_item").?.object.get("owner_id").?.integer);
    const playlist_rulesets = parsed.value.object.get("playlist_item_stats").?.object.get("ruleset_ids").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), playlist_rulesets.len);
    try std.testing.expectEqual(@as(i64, 0), playlist_rulesets[0].integer);

    try manager.recordRoomScore(host.id, 1, 1, .{ .score_id = 9001, .total_score = 100, .accuracy = 0.5, .max_combo = 10, .passed = false });
    const failed_leaderboard = (try manager.roomLeaderboardJson(std.testing.allocator, host.id, 1)).?;
    defer std.testing.allocator.free(failed_leaderboard);
    var parsed_failed_leaderboard = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, failed_leaderboard, .{});
    defer parsed_failed_leaderboard.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed_failed_leaderboard.value.object.get("leaderboard").?.array.items.len);
    try std.testing.expect(std.meta.activeTag(parsed_failed_leaderboard.value.object.get("user_score").?) == .null);
    try manager.recordRoomScore(host.id, 1, 1, .{ .score_id = 9002, .total_score = 200, .accuracy = 1, .max_combo = 20, .passed = true });
    const refreshed = (try manager.roomsJson(std.testing.allocator, 1, null, host.id)).?;
    defer std.testing.allocator.free(refreshed);
    var parsed_refreshed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, refreshed, .{});
    defer parsed_refreshed.deinit();
    const attempt = parsed_refreshed.value.object.get("current_user_score").?.object.get("playlist_item_attempts").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 1), attempt.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 2), attempt.get("attempts").?.integer);
    try std.testing.expect(attempt.get("passed").?.bool);
    const playlist_high_scores = (try manager.roomScoreIds(std.testing.allocator, host.id, 1, 1)).?;
    defer std.testing.allocator.free(playlist_high_scores);
    try std.testing.expectEqualSlices(i64, &.{9002}, playlist_high_scores);
    try std.testing.expect(manager.roomContainsScore(host.id, 1, 1, 9001));
    const passing_leaderboard = (try manager.roomLeaderboardJson(std.testing.allocator, host.id, 1)).?;
    defer std.testing.allocator.free(passing_leaderboard);
    var parsed_passing_leaderboard = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, passing_leaderboard, .{});
    defer parsed_passing_leaderboard.deinit();
    const passing_rows = parsed_passing_leaderboard.value.object.get("leaderboard").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), passing_rows.len);
    try std.testing.expectEqual(@as(i64, 2), passing_rows[0].object.get("attempts").?.integer);
    try std.testing.expectEqual(@as(i64, 1), passing_rows[0].object.get("completed").?.integer);
    try std.testing.expectEqual(@as(i64, 200), passing_rows[0].object.get("total_score").?.integer);
    try std.testing.expectEqual(@as(f64, 1), jsonFloat(passing_rows[0].object.get("accuracy")).?);
    const default_playlist_listing = (try manager.roomsJson(std.testing.allocator, null, try roomListFilter(host.id, "open", null, ""), host.id)).?;
    defer std.testing.allocator.free(default_playlist_listing);
    var parsed_default_playlist_listing = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, default_playlist_listing, .{});
    defer parsed_default_playlist_listing.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_default_playlist_listing.value.array.items.len);

    try manager.restPartRoom(host.id, 1);
    const still_open = (try manager.roomsJson(std.testing.allocator, 1, null, host.id)).?;
    defer std.testing.allocator.free(still_open);
    var parsed_still_open = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, still_open, .{});
    defer parsed_still_open.deinit();
    try std.testing.expectEqualStrings("idle", parsed_still_open.value.object.get("status").?.string);
    try std.testing.expectEqual(@as(i64, 0), parsed_still_open.value.object.get("participant_count").?.integer);
    const rejoined = try manager.restJoinRoom(std.testing.allocator, host, 1, "");
    defer std.testing.allocator.free(rejoined);
    try manager.restCloseRoom(host.id, 1);
}

test "ended playlist rooms retain ruleset filters after every item expires" {
    var room: Room = .{ .id = 1, .settings = .{}, .host_id = 4, .ended = true };
    defer room.deinit(std.testing.allocator);
    try room.settings.name.set("ended rulesets");
    try room.host_name.set("raya");
    room.settings.match_type = 0;
    room.settings.playlist_item_id = 8;
    room.playlist[0] = .{ .id = 8, .owner_id = 4, .beatmap_id = 75, .ruleset_id = 1, .expired = true, .order = 0 };
    room.playlist[1] = .{ .id = 9, .owner_id = 4, .beatmap_id = 76, .ruleset_id = 3, .expired = true, .order = 1 };
    room.playlist_count = 2;
    for (&room.playlist) |*entry| if (entry.*) |*item| {
        item.required_mods.bytes[0] = 0x90;
        item.required_mods.len = 1;
        item.allowed_mods.bytes[0] = 0x90;
        item.allowed_mods.len = 1;
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeRoomJson(&output.writer, &room, 4, 0, .archive);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
    defer parsed.deinit();
    const stats = parsed.value.object.get("playlist_item_stats").?.object;
    try std.testing.expectEqual(@as(i64, 0), stats.get("count_active").?.integer);
    const rulesets = stats.get("ruleset_ids").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), rulesets.len);
    try std.testing.expectEqual(@as(i64, 1), rulesets[0].integer);
    try std.testing.expectEqual(@as(i64, 3), rulesets[1].integer);
}

test "legacy archived playlists rebuild empty ruleset filters when hydrated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/legacy-archive-rulesets.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const owner_id = try store.register("legacy archive", "legacy-archive@example.invalid", "00000000000000000000000000000000");
    var participants_buf: [32]u8 = undefined;
    const participants = try std.fmt.bufPrint(&participants_buf, "[{d}]", .{owner_id});
    try store.saveLazerMultiplayerRoomArchive(
        77,
        owner_id,
        "normal",
        \\{"id":77,"type":"playlists","status":"ended","playlist":[{"id":8,"ruleset_id":3,"expired":true},{"id":9,"ruleset_id":1,"expired":true},{"id":10,"ruleset_id":3,"expired":true}],"playlist_item_stats":{"count_active":0,"count_total":3,"ruleset_ids":[]},"zigcho_score_tokens":[{"token_id":9001}]}
    ,
        "{\"leaderboard\":[],\"user_score\":null}",
        participants,
    );

    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    const hydrated = (try manager.roomsJson(std.testing.allocator, 77, null, owner_id)).?;
    defer std.testing.allocator.free(hydrated);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, hydrated, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("idle", parsed.value.object.get("status").?.string);
    try std.testing.expect(parsed.value.object.get("zigcho_score_tokens") == null);
    const stats = parsed.value.object.get("playlist_item_stats").?.object;
    try std.testing.expectEqual(@as(i64, 0), stats.get("count_active").?.integer);
    const rulesets = stats.get("ruleset_ids").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), rulesets.len);
    try std.testing.expectEqual(@as(i64, 1), rulesets[0].integer);
    try std.testing.expectEqual(@as(i64, 3), rulesets[1].integer);
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
    const room_channel_id = parsed_created.value.object.get("channel_id").?.integer;
    try std.testing.expectEqual(@as(i64, 2_000_000_001), room_channel_id);
    try std.testing.expectEqual(@as(?i64, 1), manager.roomChannelAccess(host.id, room_channel_id));
    try std.testing.expectEqual(@as(?i64, null), manager.roomChannelAccess(guest.id, room_channel_id));
    try std.testing.expectEqualStrings("head_to_head", parsed_created.value.object.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 5), parsed_created.value.object.get("auto_start_duration").?.integer);
    try std.testing.expectEqual(@as(i64, 5), autoStartSeconds(manager.rooms[0].?.settings));
    try std.testing.expectEqual(@as(usize, 1), parsed_created.value.object.get("playlist").?.array.items.len);
    const realtime_rulesets = parsed_created.value.object.get("playlist_item_stats").?.object.get("ruleset_ids").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), realtime_rulesets.len);
    try std.testing.expectEqual(@as(i64, 0), realtime_rulesets[0].integer);
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
    try std.testing.expectEqual(@as(?i64, 1), manager.roomChannelAccess(guest.id, room_channel_id));
    const room_channel_users = (try manager.roomChannelUsersJson(std.testing.allocator, guest.id, room_channel_id)).?;
    defer std.testing.allocator.free(room_channel_users);
    var parsed_room_channel_users = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, room_channel_users, .{});
    defer parsed_room_channel_users.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed_room_channel_users.value.array.items.len);
    const visible_rooms = (try manager.roomsJson(std.testing.allocator, null, try roomListFilter(host.id, "open", "idle", "realtime"), host.id)).?;
    defer std.testing.allocator.free(visible_rooms);
    var parsed_visible = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, visible_rooms, .{});
    defer parsed_visible.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_visible.value.array.items.len);
    const hidden_rooms = (try manager.roomsJson(std.testing.allocator, null, try roomListFilter(host.id, "open", "idle", "normal"), host.id)).?;
    defer std.testing.allocator.free(hidden_rooms);
    try std.testing.expectEqualStrings("[]", hidden_rooms);
    const default_playlist_rooms = (try manager.roomsJson(std.testing.allocator, null, try roomListFilter(host.id, "open", null, ""), host.id)).?;
    defer std.testing.allocator.free(default_playlist_rooms);
    try std.testing.expectEqualStrings("[]", default_playlist_rooms);
    const guest_owned = (try manager.roomsJson(std.testing.allocator, null, try roomListFilter(guest.id, "owned", null, "realtime"), guest.id)).?;
    defer std.testing.allocator.free(guest_owned);
    try std.testing.expectEqualStrings("[]", guest_owned);
    const context = manager.scoreContext(guest.id, 1, 8).?;
    try std.testing.expectEqual(@as(i32, 75), context.beatmap_id);
    try std.testing.expectEqual(@as(u8, 0), context.ruleset_id);

    try manager.bindRoomScoreToken(host.id, 1, 8, 10101);
    try std.testing.expect(manager.scoreSubmissionContext(host.id, 1, 8, 10101) != null);
    try std.testing.expect(manager.scoreSubmissionContext(guest.id, 1, 8, 10101) == null);
    try std.testing.expectError(error.InvalidMultiplayerScoreToken, manager.recordRoomScore(host.id, 1, 8, .{ .token_id = 10102, .score_id = 100, .total_score = 1, .accuracy = 1, .max_combo = 1, .passed = true }));
    try std.testing.expectEqual(@as(usize, 0), manager.rooms[0].?.scores.items.len);
    try manager.recordRoomScore(host.id, 1, 8, .{ .token_id = 10101, .score_id = 101, .total_score = 800_000, .accuracy = 0.98, .max_combo = 500, .passed = true });
    try std.testing.expect(manager.scoreSubmissionContext(host.id, 1, 8, 10101) != null);
    try manager.recordRoomScore(host.id, 1, 8, .{ .token_id = 10101, .score_id = 101, .total_score = 800_000, .accuracy = 0.98, .max_combo = 500, .passed = true });
    try std.testing.expectError(error.InvalidMultiplayerScoreToken, manager.recordRoomScore(host.id, 1, 8, .{ .token_id = 10101, .score_id = 104, .total_score = 900_000, .accuracy = 1, .max_combo = 600, .passed = true }));
    try manager.recordRoomScore(guest.id, 1, 8, .{ .score_id = 102, .total_score = 900_000, .accuracy = 0.99, .max_combo = 600, .passed = true });
    try manager.recordRoomScore(host.id, 1, 8, .{ .score_id = 103, .total_score = 850_000, .accuracy = 0.985, .max_combo = 550, .passed = true });
    try std.testing.expectEqual(@as(?i64, 103), manager.roomScoreIdForUser(host.id, 1, 8, host.id));
    try std.testing.expect(manager.roomContainsScore(guest.id, 1, 8, 102));
    try std.testing.expect(manager.roomContainsScore(host.id, 1, 8, 101));
    const ids = (try manager.roomScoreIds(std.testing.allocator, host.id, 1, 8)).?;
    defer std.testing.allocator.free(ids);
    // The index and showUser paths expose one high score per user. The older
    // host attempt remains addressable through the exact score route.
    try std.testing.expectEqualSlices(i64, &.{ 102, 103 }, ids);
    const best_detail = (try manager.roomScoreRanking(std.testing.allocator, host.id, 1, 8, 103)).?;
    try std.testing.expectEqual(@as(usize, 2), best_detail.position);
    try std.testing.expectEqualSlices(i64, &.{102}, best_detail.higher_ids[0..best_detail.higher_count]);
    try std.testing.expectEqual(@as(usize, 0), best_detail.lower_count);
    const older_detail = (try manager.roomScoreRanking(std.testing.allocator, host.id, 1, 8, 101)).?;
    try std.testing.expectEqual(@as(usize, 3), older_detail.position);
    try std.testing.expectEqualSlices(i64, &.{102}, older_detail.higher_ids[0..older_detail.higher_count]);
    try std.testing.expectEqual(@as(usize, 0), older_detail.lower_count);

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
    try std.testing.expectEqual(@as(?i64, null), manager.roomChannelAccess(guest.id, room_channel_id));
    try std.testing.expect(manager.scoreContext(guest.id, 1, 8) == null);
    try std.testing.expectError(error.MultiplayerPermissionDenied, manager.restCloseRoom(guest.id, 1));
    try manager.restCloseRoom(host.id, 1);
    try std.testing.expect((try manager.roomsJson(std.testing.allocator, 1, null, host.id)) == null);
}

test "room score history keeps every supported finite attempt and never rotates" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const room = try std.testing.allocator.create(Room);
    room.* = .{ .id = 1, .settings = .{}, .host_id = 4 };
    room.users[0] = try defaultRoomUser(4, "raya", .{ 'A', 'U' });
    room.user_count = 1;
    room.rememberParticipant(room.users[0].?);
    room.playlist[0] = .{ .id = 8, .owner_id = 4, .beatmap_id = 75 };
    room.playlist[0].?.required_mods.bytes[0] = 0x90;
    room.playlist[0].?.required_mods.len = 1;
    room.playlist[0].?.allowed_mods.bytes[0] = 0x90;
    room.playlist[0].?.allowed_mods.len = 1;
    room.playlist_count = 1;
    room.settings.playlist_item_id = 8;
    try room.scores.ensureTotalCapacity(std.testing.allocator, max_room_scores);
    for (0..max_room_scores) |index| room.scores.appendAssumeCapacity(.{
        .score_id = @intCast(index + 1),
        .user_id = 4,
        .playlist_item_id = 8,
        .total_score = @intCast(index),
        .accuracy = 1,
        .max_combo = 1,
        .passed = true,
    });
    manager.rooms[0] = room;
    try std.testing.expectError(error.MultiplayerScoreLimit, manager.recordRoomScore(4, 1, 8, .{ .score_id = max_room_scores + 1, .total_score = 1, .accuracy = 1, .max_combo = 1, .passed = true }));
    try std.testing.expectEqual(@as(i64, 1), room.scores.items[0].score_id);
    try std.testing.expectEqual(@as(i64, max_room_scores), room.scores.items[max_room_scores - 1].score_id);
    var archive_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer archive_json.deinit();
    try writeRoomJson(&archive_json.writer, room, 4, 0, .archive);
    try std.testing.expect(archive_json.written().len <= 8 * 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, archive_json.written(), "\"score_id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive_json.written(), "\"score_id\":16000") != null);
}

fn roomArchiveListAllocationRun(allocator: std.mem.Allocator, store: *storage.Store) !void {
    const archives = try store.lazerMultiplayerRoomArchives(allocator, 64);
    defer {
        for (archives) |*archive| archive.deinit();
        allocator.free(archives);
    }
    try std.testing.expectEqual(@as(usize, 1), archives.len);
    const checkpoints = try store.lazerMultiplayerRoomCheckpoints(allocator);
    defer {
        for (checkpoints) |*checkpoint| checkpoint.deinit();
        allocator.free(checkpoints);
    }
    try std.testing.expectEqual(@as(usize, 1), checkpoints.len);
}

test "room archive and checkpoint lists free every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/room-archive-allocation.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const owner_id = try store.register("archive allocator", "archive-allocator@example.invalid", "00000000000000000000000000000000");
    var participants_buf: [32]u8 = undefined;
    const participants = try std.fmt.bufPrint(&participants_buf, "[{d}]", .{owner_id});
    try store.saveLazerMultiplayerRoomArchive(1, owner_id, "realtime", "{}", "{\"leaderboard\":[],\"user_score\":null}", participants);
    try store.saveLazerMultiplayerRoomArchive(2, owner_id, "normal", "{\"zigcho_resumable\":true}", "{\"leaderboard\":[],\"user_score\":null}", participants);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, roomArchiveListAllocationRun, .{&store});
}

test "failed room archive stays owned and retries without losing scores or tokens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/archive-retry.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("archive retry", "archive-retry@example.invalid", "00000000000000000000000000000000");
    const user: domain.User = .{ .id = user_id, .name = "archive retry", .safe_name = "archive_retry", .country = .{ 'A', 'U' } };
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    const created = try manager.restCreateRoom(std.testing.allocator, user,
        \\{"name":"archive retry","type":"head_to_head","playlist":[{"id":8,"owner_id":0,"beatmap_id":75,"ruleset_id":0}]}
    );
    std.testing.allocator.free(created);
    try manager.recordRoomScore(user_id, 1, 8, .{ .score_id = 700, .total_score = 700_000, .accuracy = 0.97, .max_combo = 400, .passed = true });
    try manager.bindRoomScoreToken(user_id, 1, 8, 7001);

    try store.exec("ALTER TABLE lazer_multiplayer_room_history RENAME TO lazer_multiplayer_room_history_unavailable");
    try manager.restCloseRoom(user_id, 1);
    for (manager.rooms) |entry| try std.testing.expect(entry == null);
    const retained = manager.pending_archives[0].?;
    try std.testing.expect(retained.ended);
    try std.testing.expectEqual(@as(usize, 1), retained.scores.items.len);
    try std.testing.expectEqual(@as(i64, 700), retained.scores.items[0].score_id);
    try std.testing.expectEqual(@as(usize, 1), retained.score_tokens.items.len);

    // Reuse the freed live-room slot before the archive backend recovers. The
    // ended room remains independently owned by the retry queue.
    const replacement = try manager.restCreateRoom(std.testing.allocator, user,
        \\{"name":"slot reuse","type":"head_to_head","playlist":[{"id":9,"owner_id":0,"beatmap_id":76,"ruleset_id":0}]}
    );
    defer std.testing.allocator.free(replacement);
    try std.testing.expectEqual(@as(i64, 2), manager.rooms[0].?.id);
    try std.testing.expect(manager.pending_archives[0] == retained);

    try store.exec("ALTER TABLE lazer_multiplayer_room_history_unavailable RENAME TO lazer_multiplayer_room_history");
    try std.testing.expectEqual(@as(usize, 1), manager.archiveExpiredRooms(std.Io.Clock.real.now(std.testing.io).toSeconds()));
    try std.testing.expectEqual(@as(i64, 2), manager.rooms[0].?.id);
    for (manager.pending_archives) |entry| try std.testing.expect(entry == null);
    var archive = (try store.lazerMultiplayerRoomArchive(std.testing.allocator, 1)).?;
    defer archive.deinit();
    try std.testing.expect(std.mem.indexOf(u8, archive.room_json, "\"score_id\":700") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive.room_json, "\"token_id\":7001") != null);
}

const ArchivedScoreAllocationContext = struct {
    store: *storage.Store,
    user_id: i32,
    room_json: []const u8,
    participant_ids_json: []const u8,
};

fn archivedScoreAllocationRun(allocator: std.mem.Allocator, context: *ArchivedScoreAllocationContext) !void {
    try context.store.saveLazerMultiplayerRoomArchive(1, context.user_id, "realtime", context.room_json, "{\"leaderboard\":[],\"user_score\":null}", context.participant_ids_json);
    var manager = Manager.init(allocator, std.testing.io);
    manager.store = context.store;
    defer {
        manager.shutting_down = true;
        manager.deinit();
    }
    try manager.recordRoomScore(context.user_id, 1, 8, .{ .token_id = 5001, .score_id = 9001, .total_score = 500_000, .accuracy = 0.98, .max_combo = 400, .passed = true });
    var archive = (try context.store.lazerMultiplayerRoomArchive(allocator, 1)).?;
    defer archive.deinit();
    try std.testing.expect(std.mem.indexOf(u8, archive.room_json, "\"score_id\":9001") != null);
}

test "archived grace score update frees every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/archived-score-allocation.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("archive scorer", "archive-scorer@example.invalid", "00000000000000000000000000000000");
    const room_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"id\":1,\"category\":\"realtime\",\"playlist\":[{{\"id\":8,\"beatmap_id\":75,\"ruleset_id\":0}}],\"recent_participants\":[{{\"id\":{d},\"username\":\"archive scorer\",\"country_code\":\"AU\"}}],\"zigcho_score_records\":[],\"zigcho_score_tokens\":[{{\"token_id\":5001,\"user_id\":{d},\"playlist_item_id\":8}}]}}",
        .{ user_id, user_id },
    );
    defer std.testing.allocator.free(room_json);
    const participant_ids_json = try std.fmt.allocPrint(std.testing.allocator, "[{d}]", .{user_id});
    defer std.testing.allocator.free(participant_ids_json);
    var context: ArchivedScoreAllocationContext = .{ .store = &store, .user_id = user_id, .room_json = room_json, .participant_ids_json = participant_ids_json };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, archivedScoreAllocationRun, .{&context});
}

test "late archived scores preserve playlist and realtime high score eligibility" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/archived-score-category.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("archive category", "archive-category@example.invalid", "00000000000000000000000000000000");
    const participant_ids_json = try std.fmt.allocPrint(std.testing.allocator, "[{d}]", .{user_id});
    defer std.testing.allocator.free(participant_ids_json);
    const normal_token: i64 = 0x7f_ff_ff_00_00_00_00_01;
    const realtime_token: i64 = 0x7f_ff_ff_00_00_00_00_03;
    for ([_]struct { room_id: i64, category: []const u8, token_id: i64 }{
        .{ .room_id = 1, .category = "normal", .token_id = normal_token },
        .{ .room_id = 2, .category = "realtime", .token_id = realtime_token },
    }) |fixture| {
        const room_json = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"id\":{d},\"category\":\"{s}\",\"playlist\":[{{\"id\":8,\"beatmap_id\":75,\"ruleset_id\":0}}],\"recent_participants\":[{{\"id\":{d},\"username\":\"archive category\",\"country_code\":\"AU\"}}],\"zigcho_score_records\":[],\"zigcho_score_tokens\":[{{\"token_id\":{d},\"user_id\":{d},\"playlist_item_id\":8}}]}}",
            .{ fixture.room_id, fixture.category, user_id, fixture.token_id, user_id },
        );
        defer std.testing.allocator.free(room_json);
        try store.saveLazerMultiplayerRoomArchive(fixture.room_id, user_id, fixture.category, room_json, "{\"leaderboard\":[],\"user_score\":null}", participant_ids_json);
    }

    var manager = Manager.init(std.testing.allocator, std.testing.io);
    manager.store = &store;
    defer {
        manager.shutting_down = true;
        manager.deinit();
    }
    const LateScore = struct {
        manager: *Manager,
        user_id: i32,
        token_id: i64,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,

        fn run(context: *@This()) void {
            context.started.store(true, .release);
            context.manager.recordRoomScore(context.user_id, 1, 8, .{ .token_id = context.token_id, .score_id = 101, .total_score = 500_000, .accuracy = 0.9, .max_combo = 100, .passed = false }) catch |err| {
                context.failure = err;
            };
            context.done.store(true, .release);
        }
    };
    const LiveProgress = struct {
        manager: *Manager,
        user: domain.User,
        socket: *std.http.Server.WebSocket,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,

        fn run(context: *@This()) void {
            context.started.store(true, .release);
            const connection = context.manager.connect(context.user, context.socket) catch |err| {
                context.failure = err;
                context.done.store(true, .release);
                return;
            };
            connection.socket = null;
            context.manager.disconnect(connection);
            context.done.store(true, .release);
        }
    };
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const unrelated_user: domain.User = .{ .id = user_id + 1, .name = "live progress", .safe_name = "live_progress", .country = .{ 'G', 'B' } };
    store.mutex.lockUncancelable(std.testing.io);
    var late_score: LateScore = .{ .manager = &manager, .user_id = user_id, .token_id = normal_token };
    var live_progress: LiveProgress = .{ .manager = &manager, .user = unrelated_user, .socket = fake_socket };
    const late_thread = try std.Thread.spawn(.{}, LateScore.run, .{&late_score});
    const live_thread = try std.Thread.spawn(.{}, LiveProgress.run, .{&live_progress});
    while (!late_score.started.load(.acquire) or !live_progress.started.load(.acquire)) std.Thread.yield() catch {};
    _ = std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake) catch {};
    const live_progressed_while_storage_blocked = live_progress.done.load(.acquire);
    const archive_waited_for_storage = !late_score.done.load(.acquire);
    store.mutex.unlock(std.testing.io);
    late_thread.join();
    live_thread.join();
    try std.testing.expect(live_progressed_while_storage_blocked);
    try std.testing.expect(archive_waited_for_storage);
    try std.testing.expect(late_score.failure == null);
    try std.testing.expect(live_progress.failure == null);

    try manager.recordRoomScore(user_id, 2, 8, .{ .token_id = realtime_token, .score_id = 102, .total_score = 500_000, .accuracy = 0.9, .max_combo = 100, .passed = false });

    const normal_ids = (try manager.roomScoreIds(std.testing.allocator, user_id, 1, 8)).?;
    defer std.testing.allocator.free(normal_ids);
    const realtime_ids = (try manager.roomScoreIds(std.testing.allocator, user_id, 2, 8)).?;
    defer std.testing.allocator.free(realtime_ids);
    try std.testing.expectEqual(@as(usize, 0), normal_ids.len);
    try std.testing.expectEqualSlices(i64, &.{102}, realtime_ids);
    // Both exact attempts remain addressable; only the playlist high-score
    // projection excludes its failed result.
    try std.testing.expect(manager.roomContainsScore(user_id, 1, 8, 101));
    try std.testing.expect(manager.roomContainsScore(user_id, 2, 8, 102));
}

test "late archived playlist scores rebuild existing rows and never erase a valid board" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/archived-playlist-leaderboard.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("archive playlist", "archive-playlist@example.invalid", "00000000000000000000000000000000");
    const participant_ids_json = try std.fmt.allocPrint(std.testing.allocator, "[{d}]", .{user_id});
    defer std.testing.allocator.free(participant_ids_json);
    const existing_board = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"leaderboard\":[{{\"attempts\":1,\"completed\":1,\"accuracy\":0.95,\"pp\":null,\"room_id\":1,\"total_score\":400000,\"user_id\":{d},\"user\":{{\"id\":{d},\"username\":\"archive playlist\",\"avatar_url\":\"https://a.kai.ovh/{d}\",\"country_code\":\"AU\",\"is_active\":true,\"is_supporter\":true}},\"position\":1}}],\"user_score\":null}}",
        .{ user_id, user_id, user_id },
    );
    defer std.testing.allocator.free(existing_board);
    const room_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"id\":1,\"category\":\"normal\",\"playlist\":[{{\"id\":8,\"owner_id\":{d},\"beatmap_id\":75,\"ruleset_id\":0,\"playlist_order\":0,\"expired\":true}}],\"recent_participants\":[{{\"id\":{d},\"username\":\"archive playlist\",\"country_code\":\"AU\"}}],\"zigcho_score_records\":[{{\"score_id\":201,\"user_id\":{d},\"playlist_item_id\":8,\"total_score\":400000,\"accuracy\":0.95,\"max_combo\":300,\"passed\":true}}],\"zigcho_score_tokens\":[{{\"token_id\":7001,\"user_id\":{d},\"playlist_item_id\":8}}]}}",
        .{ user_id, user_id, user_id, user_id },
    );
    defer std.testing.allocator.free(room_json);
    try store.saveLazerMultiplayerRoomArchive(1, user_id, "normal", room_json, existing_board, participant_ids_json);

    var manager = Manager.init(std.testing.allocator, std.testing.io);
    manager.store = &store;
    defer {
        manager.shutting_down = true;
        manager.deinit();
    }
    try manager.recordRoomScore(user_id, 1, 8, .{ .token_id = 7001, .score_id = 202, .total_score = 500_000, .accuracy = 0.99, .max_combo = 400, .passed = true });
    var rebuilt = (try store.lazerMultiplayerRoomArchive(std.testing.allocator, 1)).?;
    defer rebuilt.deinit();
    var parsed_rebuilt = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rebuilt.leaderboard_json, .{});
    defer parsed_rebuilt.deinit();
    const rebuilt_rows = parsed_rebuilt.value.object.get("leaderboard").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), rebuilt_rows.len);
    try std.testing.expectEqual(@as(i64, 2), rebuilt_rows[0].object.get("attempts").?.integer);
    try std.testing.expectEqual(@as(i64, 1), rebuilt_rows[0].object.get("completed").?.integer);
    try std.testing.expectEqual(@as(i64, 500_000), rebuilt_rows[0].object.get("total_score").?.integer);

    const legacy_board = "{\"leaderboard\":[{\"attempts\":1,\"completed\":1,\"total_score\":123,\"position\":1}],\"user_score\":null}";
    const legacy_room_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"id\":2,\"category\":\"normal\",\"playlist\":[{{\"id\":9,\"beatmap_id\":76,\"ruleset_id\":1,\"expired\":true}}],\"recent_participants\":[{{\"id\":{d},\"username\":\"archive playlist\",\"country_code\":\"AU\"}}],\"zigcho_score_records\":[],\"zigcho_score_tokens\":[{{\"token_id\":7003,\"user_id\":{d},\"playlist_item_id\":9}}]}}",
        .{ user_id, user_id },
    );
    defer std.testing.allocator.free(legacy_room_json);
    try store.saveLazerMultiplayerRoomArchive(2, user_id, "normal", legacy_room_json, legacy_board, participant_ids_json);
    try manager.recordRoomScore(user_id, 2, 9, .{ .token_id = 7003, .score_id = 203, .total_score = 50, .accuracy = 0.5, .max_combo = 10, .passed = false });
    var preserved = (try store.lazerMultiplayerRoomArchive(std.testing.allocator, 2)).?;
    defer preserved.deinit();
    try std.testing.expectEqualStrings(legacy_board, preserved.leaderboard_json);
}

test "consumed score token recovery attaches only its canonical room score" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/consumed-room-token.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const hash = "0123456789abcdef0123456789abcdef";
    try store.exec("INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,star_rating,total_length,hit_length) VALUES(75,750,'0123456789abcdef0123456789abcdef','fixture','retry','room','mapper',3,5.0,120,100)");
    const user_id = try store.register("retry scorer", "retry-scorer@example.invalid", "00000000000000000000000000000000");
    const input: lazer.ScoreInput = .{
        .beatmap_id = 75,
        .ruleset_id = 0,
        .total_score = 765_432,
        .total_score_without_mods = 765_432,
        .accuracy = 0.987,
        .max_combo = 432,
        .passed = true,
        .mods = null,
        .statistics = .empty,
        .namespace = .vanilla,
    };
    const solo_token_id = try store.createLazerScoreToken(user_id, 75, hash, 0, "00000000000000000000000000000000");
    try std.testing.expect(!storage.Store.isLazerRoomScoreToken(solo_token_id));
    try std.testing.expectError(error.InvalidLazerScoreToken, store.submitLazerRoomScoreToken(user_id, 75, solo_token_id, input, 123, "[]", "{}", "{}", "[]", &.{}));
    const token_id = try store.createLazerRoomScoreToken(user_id, 75, hash, 0, "11111111111111111111111111111111");
    try std.testing.expect(storage.Store.isLazerRoomScoreToken(token_id));
    // A room token that could not be bound because the room closed or the
    // manager ran out of memory is still unusable on the solo submission path.
    try std.testing.expectError(error.InvalidLazerScoreToken, store.submitLazerScoreToken(user_id, 75, token_id, input, 123, "[]", "{}", "{}", "[]", &.{}));
    const score_id = try store.submitLazerRoomScoreToken(user_id, 75, token_id, input, 123, "[]", "{}", "{}", "[]", &.{});
    try std.testing.expectError(error.LazerScoreTokenUsed, store.submitLazerRoomScoreToken(user_id, 75, token_id, input, 123, "[]", "{}", "{}", "[]", &.{}));
    const recovered = (try store.consumedLazerScoreToken(user_id, 75, token_id)).?;
    try std.testing.expectEqual(score_id, recovered.score_id);
    try std.testing.expectEqual(input.total_score, recovered.total_score);
    try std.testing.expectEqual(input.accuracy, recovered.accuracy);
    try std.testing.expectEqual(@as(i32, @intCast(input.max_combo)), recovered.max_combo);
    try std.testing.expectEqual(input.passed, recovered.passed);
    try std.testing.expect((try store.consumedLazerScoreToken(user_id + 1, 75, token_id)) == null);
    try std.testing.expect((try store.consumedLazerScoreToken(user_id, 76, token_id)) == null);

    const room_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"id\":1,\"category\":\"realtime\",\"playlist\":[{{\"id\":8,\"beatmap_id\":75,\"ruleset_id\":0}}],\"recent_participants\":[{{\"id\":{d},\"username\":\"retry scorer\",\"country_code\":\"AU\"}}],\"zigcho_score_records\":[],\"zigcho_score_tokens\":[{{\"token_id\":{d},\"user_id\":{d},\"playlist_item_id\":8}}]}}",
        .{ user_id, token_id, user_id },
    );
    defer std.testing.allocator.free(room_json);
    const participant_ids = try std.fmt.allocPrint(std.testing.allocator, "[{d}]", .{user_id});
    defer std.testing.allocator.free(participant_ids);
    try store.saveLazerMultiplayerRoomArchive(1, user_id, "realtime", room_json, "{\"leaderboard\":[],\"user_score\":null}", participant_ids);

    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    try std.testing.expect(manager.scoreSubmissionContext(user_id, 1, 8, token_id) != null);
    try std.testing.expect(manager.scoreSubmissionContext(user_id, 1, 9, token_id) == null);
    try std.testing.expect(manager.scoreSubmissionContext(user_id + 1, 1, 8, token_id) == null);
    try manager.recordRoomScore(user_id, 1, 8, .{
        .token_id = token_id,
        .score_id = recovered.score_id,
        .total_score = recovered.total_score,
        .accuracy = recovered.accuracy,
        .max_combo = recovered.max_combo,
        .passed = recovered.passed,
    });
    try std.testing.expect(manager.scoreSubmissionContext(user_id, 1, 8, token_id) != null);
    try manager.recordRoomScore(user_id, 1, 8, .{
        .token_id = token_id,
        .score_id = recovered.score_id,
        .total_score = recovered.total_score,
        .accuracy = recovered.accuracy,
        .max_combo = recovered.max_combo,
        .passed = recovered.passed,
    });
    var persisted = (try store.lazerMultiplayerRoomArchive(std.testing.allocator, 1)).?;
    defer persisted.deinit();
    var persisted_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, persisted.room_json, .{});
    defer persisted_json.deinit();
    const persisted_token = persisted_json.value.object.get("zigcho_score_tokens").?.array.items[0].object;
    try std.testing.expectEqual(score_id, persisted_token.get("score_id").?.integer);

    var restarted = Manager.init(std.testing.allocator, std.testing.io);
    defer restarted.deinit();
    try restarted.bindStore(&store);
    try std.testing.expect(restarted.roomContainsScore(user_id, 1, 8, score_id));
    try std.testing.expect(restarted.scoreSubmissionContext(user_id, 1, 8, token_id) != null);
    const ids = (try restarted.roomScoreIds(std.testing.allocator, user_id, 1, 8)).?;
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(i64, &.{score_id}, ids);
}

test "planned shutdown restores long lived playlist rooms without falsely ending them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/shutdown-room.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("shutdown host", "shutdown@example.invalid", "00000000000000000000000000000000");
    const guest_id = try store.register("shutdown guest", "shutdown-guest@example.invalid", "00000000000000000000000000000000");
    const host: domain.User = .{ .id = user_id, .name = "shutdown host", .safe_name = "shutdown_host", .country = .{ 'A', 'U' } };
    const guest: domain.User = .{ .id = guest_id, .name = "shutdown guest", .safe_name = "shutdown_guest", .country = .{ 'G', 'B' } };
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const connection = try manager.connect(host, fake_socket);
    connection.socket = null;
    const room_body =
        \\{"name":"durable shutdown","password":"secret","type":"playlists","duration":30,"max_attempts":1000,"playlist":[{"id":8,"owner_id":0,"beatmap_id":75,"ruleset_id":0}]}
    ;
    const created = try manager.restCreateRoom(std.testing.allocator, host, room_body);
    defer std.testing.allocator.free(created);
    var created_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, created, .{});
    defer created_json.deinit();
    const original_ends_at = created_json.value.object.get("ends_at").?.string;
    for (0..129) |index| try manager.recordRoomScore(user_id, 1, 8, .{
        .score_id = @intCast(501 + index),
        .total_score = @intCast(900_000 + index),
        .accuracy = 1,
        .max_combo = 500,
        .passed = true,
    });
    try manager.bindRoomScoreToken(user_id, 1, 8, 7001);
    try std.testing.expect(manager.scoreSubmissionContext(user_id, 1, 8, 7001) != null);
    manager.shutdown();
    try std.testing.expect(!connection.alive.load(.acquire));
    try std.testing.expect(manager.shutting_down);
    try std.testing.expect(manager.rooms[0] == null);
    try std.testing.expect((try store.lazerMultiplayerRoomArchive(std.testing.allocator, 1)) == null);
    const checkpoints = try store.lazerMultiplayerRoomCheckpoints(std.testing.allocator);
    defer {
        for (checkpoints) |*checkpoint| checkpoint.deinit();
        std.testing.allocator.free(checkpoints);
    }
    try std.testing.expectEqual(@as(usize, 1), checkpoints.len);
    try std.testing.expect(std.mem.indexOf(u8, checkpoints[0].room_json, "\"zigcho_password\":\"secret\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, checkpoints[0].room_json, "\"score_id\":501") != null);
    try std.testing.expect(std.mem.indexOf(u8, checkpoints[0].room_json, "\"score_id\":629") != null);
    try std.testing.expect(std.mem.indexOf(u8, checkpoints[0].room_json, "\"token_id\":7001") != null);
    manager.shutdown();
    try std.testing.expectError(error.ServerShuttingDown, manager.connect(host, fake_socket));

    var reopened = Manager.init(std.testing.allocator, std.testing.io);
    defer reopened.deinit();
    try reopened.bindStore(&store);
    try std.testing.expect(reopened.rooms[0] != null);
    const restored_json = (try reopened.roomsJson(std.testing.allocator, 1, null, user_id)).?;
    defer std.testing.allocator.free(restored_json);
    var restored = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, restored_json, .{});
    defer restored.deinit();
    try std.testing.expect(restored.value.object.get("zigcho_score_tokens") == null);
    try std.testing.expectEqualStrings("idle", restored.value.object.get("status").?.string);
    try std.testing.expectEqualStrings(original_ends_at, restored.value.object.get("ends_at").?.string);
    const attempt = restored.value.object.get("current_user_score").?.object.get("playlist_item_attempts").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 129), attempt.get("attempts").?.integer);
    const score_ids = (try reopened.roomScoreIds(std.testing.allocator, user_id, 1, 8)).?;
    defer std.testing.allocator.free(score_ids);
    try std.testing.expectEqualSlices(i64, &.{629}, score_ids);
    try std.testing.expect(reopened.roomContainsScore(user_id, 1, 8, 501));
    try std.testing.expect(reopened.roomContainsScore(user_id, 1, 8, 629));
    try std.testing.expect(reopened.scoreSubmissionContext(user_id, 1, 8, 7001) != null);
    const archived_older_detail = (try reopened.roomScoreRanking(std.testing.allocator, user_id, 1, 8, 501)).?;
    try std.testing.expectEqual(@as(usize, 2), archived_older_detail.position);
    try std.testing.expectEqual(@as(usize, 0), archived_older_detail.higher_count);
    try std.testing.expectEqual(@as(usize, 0), archived_older_detail.lower_count);
    const restored_room = reopened.rooms[0].?;
    try std.testing.expectEqual(@as(usize, 1), restored_room.user_count);
    try std.testing.expectEqual(@as(usize, 1), restored_room.participant_count);
    const fresh_connection = try reopened.connect(host, fake_socket);
    fresh_connection.socket = null;
    try std.testing.expectError(error.InvalidMultiplayerPassword, reopened.joinRoom(fresh_connection, "restart-wrong-password", 1, "wrong"));
    try std.testing.expectEqual(@as(?i64, null), fresh_connection.room_id);
    try reopened.joinRoom(fresh_connection, "restart-rebind", 1, "secret");
    try std.testing.expectEqual(@as(?i64, 1), fresh_connection.room_id);
    try std.testing.expectEqual(@as(usize, 1), restored_room.user_count);
    try std.testing.expectEqual(@as(usize, 1), restored_room.participant_count);
    try std.testing.expectError(error.InvalidMultiplayerPassword, reopened.restJoinRoom(std.testing.allocator, guest, 1, "wrong"));
    const guest_joined = try reopened.restJoinRoom(std.testing.allocator, guest, 1, "secret");
    std.testing.allocator.free(guest_joined);
    try reopened.restPartRoom(guest_id, 1);
    const remaining_checkpoints = try store.lazerMultiplayerRoomCheckpoints(std.testing.allocator);
    defer std.testing.allocator.free(remaining_checkpoints);
    try std.testing.expectEqual(@as(usize, 0), remaining_checkpoints.len);
    try reopened.restCloseRoom(user_id, 1);
    var archive = (try store.lazerMultiplayerRoomArchive(std.testing.allocator, 1)).?;
    defer archive.deinit();
    try std.testing.expect(std.mem.indexOf(u8, archive.room_json, "zigcho_password") == null);
    try std.testing.expect(std.mem.indexOf(u8, archive.room_json, "zigcho_resumable") == null);
    try std.testing.expect(std.mem.indexOf(u8, archive.room_json, "\"score_id\":501") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive.room_json, "\"score_id\":629") != null);
}

test "checkpoint hydration failure stays hidden and retries on a later restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/retry-room.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("retry host", "retry-host@example.invalid", "00000000000000000000000000000000");
    const host: domain.User = .{ .id = user_id, .name = "retry host", .safe_name = "retry_host", .country = .{ 'A', 'U' } };
    {
        var manager = Manager.init(std.testing.allocator, std.testing.io);
        defer manager.deinit();
        try manager.bindStore(&store);
        const room_body =
            \\{"name":"retry hydration","type":"playlists","duration":30,"playlist":[{"id":8,"owner_id":0,"beatmap_id":75,"ruleset_id":0}]}
        ;
        const created = try manager.restCreateRoom(std.testing.allocator, host, room_body);
        std.testing.allocator.free(created);
        manager.shutdown();
    }
    // Force only beatmap hydration to fail after the checkpoint itself can be
    // listed and parsed successfully.
    try store.exec("ALTER TABLE beatmaps RENAME TO beatmaps_unavailable;");
    var reopened = Manager.init(std.testing.allocator, std.testing.io);
    defer reopened.deinit();
    try reopened.bindStore(&store);
    for (reopened.rooms) |entry| try std.testing.expect(entry == null);
    try std.testing.expect((try store.lazerMultiplayerRoomArchive(std.testing.allocator, 1)) == null);
    const checkpoints = try store.lazerMultiplayerRoomCheckpoints(std.testing.allocator);
    defer {
        for (checkpoints) |*checkpoint| checkpoint.deinit();
        std.testing.allocator.free(checkpoints);
    }
    try std.testing.expectEqual(@as(usize, 1), checkpoints.len);
    try std.testing.expectEqual(@as(i64, 1), checkpoints[0].room_id);
}

test "completed lazer rooms and score boards survive manager restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/multiplayer-history.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,star_rating,total_length,hit_length) VALUES(75,750,'0123456789abcdef0123456789abcdef','fixture','kept','history','mapper',3,5.25,143,119)");
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
        try std.testing.expect(manager.scoreTokenContext(host_id, 1, 8) != null);
        try manager.bindRoomScoreToken(host_id, 1, 8, 555);
        try manager.bindRoomScoreToken(host_id, 1, 8, 557);
        try std.testing.expect(manager.scoreSubmissionContext(host_id, 1, 8, 555) != null);
        try std.testing.expect(manager.scoreSubmissionContext(host_id, 1, 8, 556) == null);
        try manager.restPartRoom(guest_id, 1);
        // Closing a room may archive it while its last live state was playing.
        // The persisted lazer model must still expose every ended room as idle.
        manager.rooms[0].?.state = 2;
        try manager.restCloseRoom(host_id, 1);
    }

    var reopened = Manager.init(std.testing.allocator, std.testing.io);
    defer reopened.deinit();
    try reopened.bindStore(&store);
    const archived = (try reopened.roomsJson(std.testing.allocator, 1, null, host_id)).?;
    defer std.testing.allocator.free(archived);
    var parsed_room = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, archived, .{});
    defer parsed_room.deinit();
    try std.testing.expectEqualStrings("idle", parsed_room.value.object.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 2), parsed_room.value.object.get("recent_participants").?.array.items.len);
    const archived_beatmap = parsed_room.value.object.get("playlist").?.array.items[0].object.get("beatmap").?.object;
    try std.testing.expectEqual(@as(i64, 143), archived_beatmap.get("total_length").?.integer);
    try std.testing.expectEqual(@as(i64, 119), archived_beatmap.get("hit_length").?.integer);
    const archived_current = parsed_room.value.object.get("current_playlist_item").?.object.get("beatmap").?.object;
    try std.testing.expectEqual(@as(i64, 143), archived_current.get("total_length").?.integer);
    try std.testing.expectEqual(@as(i64, 119), archived_current.get("hit_length").?.integer);
    try std.testing.expectEqual(@as(usize, 2), parsed_room.value.object.get("zigcho_score_records").?.array.items.len);
    const archived_context = reopened.scoreContext(host_id, 1, 8).?;
    try std.testing.expectEqual(@as(i32, 75), archived_context.beatmap_id);
    try std.testing.expectEqual(@as(u8, 0), archived_context.ruleset_id);
    // History remains readable, new token minting stops immediately, and a
    // pre-minted token may still complete during the official grace window.
    try std.testing.expect(reopened.scoreTokenContext(host_id, 1, 8) == null);
    try std.testing.expect(reopened.scoreSubmissionContext(host_id, 1, 8, 555) != null);
    try std.testing.expect(reopened.scoreSubmissionContext(host_id, 1, 8, 557) != null);
    try std.testing.expect(reopened.scoreSubmissionContext(host_id, 1, 8, 556) == null);
    try std.testing.expect(reopened.scoreSubmissionContext(guest_id, 1, 8, 555) == null);
    try std.testing.expect(reopened.scoreContext(host_id + 1000, 1, 8) == null);
    try reopened.recordRoomScore(host_id, 1, 8, .{ .token_id = 555, .score_id = 203, .total_score = 950_000, .accuracy = 0.995, .max_combo = 550, .passed = true });
    try std.testing.expect(reopened.roomContainsScore(host_id, 1, 8, 203));
    try std.testing.expect(reopened.scoreSubmissionContext(host_id, 1, 8, 555) != null);
    try reopened.recordRoomScore(host_id, 1, 8, .{ .token_id = 555, .score_id = 203, .total_score = 950_000, .accuracy = 0.995, .max_combo = 550, .passed = true });
    var restarted = Manager.init(std.testing.allocator, std.testing.io);
    defer restarted.deinit();
    try restarted.bindStore(&store);
    const restarted_score_ids = (try restarted.roomScoreIds(std.testing.allocator, host_id, 1, 8)).?;
    defer std.testing.allocator.free(restarted_score_ids);
    try std.testing.expectEqualSlices(i64, &.{ 203, 202 }, restarted_score_ids);
    try std.testing.expect(restarted.scoreSubmissionContext(host_id, 1, 8, 555) != null);
    try store.exec("UPDATE lazer_multiplayer_room_history SET ended_at=unixepoch()-301 WHERE room_id=1");
    try std.testing.expect(restarted.scoreSubmissionContext(host_id, 1, 8, 555) == null);
    try std.testing.expect(restarted.scoreSubmissionContext(host_id, 1, 8, 557) == null);
    try std.testing.expectError(error.MultiplayerRoomNotFound, restarted.recordRoomScore(host_id, 1, 8, .{ .token_id = 557, .score_id = 204, .total_score = 1_000_000, .accuracy = 1, .max_combo = 600, .passed = true }));
    const archived_score_ids = (try reopened.roomScoreIds(std.testing.allocator, guest_id, 1, 8)).?;
    defer std.testing.allocator.free(archived_score_ids);
    try std.testing.expectEqualSlices(i64, &.{ 203, 202 }, archived_score_ids);
    try std.testing.expectEqual(@as(?i64, 202), reopened.roomScoreIdForUser(host_id, 1, 8, guest_id));
    try std.testing.expect(reopened.roomContainsScore(guest_id, 1, 8, 201));
    try std.testing.expect(!reopened.roomContainsScore(host_id + 1000, 1, 8, 201));
    const leaderboard = (try reopened.roomLeaderboardJson(std.testing.allocator, 0, 1)).?;
    defer std.testing.allocator.free(leaderboard);
    var parsed_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, leaderboard, .{});
    defer parsed_board.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed_board.value.object.get("leaderboard").?.array.items.len);
    try std.testing.expectEqual(@as(i64, host_id), parsed_board.value.object.get("leaderboard").?.array.items[0].object.get("user_id").?.integer);
    try std.testing.expectEqual(@as(i64, 1_650_000), parsed_board.value.object.get("leaderboard").?.array.items[0].object.get("total_score").?.integer);
    const ended = (try reopened.roomsJson(std.testing.allocator, null, try roomListFilter(host_id, "ended", "idle", "realtime"), host_id)).?;
    defer std.testing.allocator.free(ended);
    var parsed_ended = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, ended, .{});
    defer parsed_ended.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_ended.value.array.items.len);
    const ended_playing = (try reopened.roomsJson(std.testing.allocator, null, try roomListFilter(host_id, "ended", "playing", "realtime"), host_id)).?;
    defer std.testing.allocator.free(ended_playing);
    try std.testing.expectEqualStrings("[]", ended_playing);
    const open = (try reopened.roomsJson(std.testing.allocator, null, .{ .requester_id = 0, .mode = .open }, 0)).?;
    defer std.testing.allocator.free(open);
    try std.testing.expectEqualStrings("[]", open);

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
    try store.exec("INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,star_rating,total_length,hit_length) VALUES(75,900,'0123456789abcdef0123456789abcdef','stored artist','stored song','stored diff','stored mapper',3,6.25,143,119)");
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
    try std.testing.expectEqual(@as(i64, 143), beatmap.get("total_length").?.integer);
    try std.testing.expectEqual(@as(i64, 119), beatmap.get("hit_length").?.integer);
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
    try writeRoomJson(&client_json.writer, decoded, 0, 0, .none);
    var parsed_client = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, client_json.written(), .{});
    defer parsed_client.deinit();
    const client_beatmap = parsed_client.value.object.get("playlist").?.array.items[0].object.get("beatmap").?.object;
    try std.testing.expectEqual(@as(i64, 900), client_beatmap.get("beatmapset_id").?.integer);
    try std.testing.expectEqualStrings("stored song", client_beatmap.get("beatmapset").?.object.get("title").?.string);
    try std.testing.expectEqualStrings("stored diff", client_beatmap.get("version").?.string);
    try std.testing.expectEqual(@as(i64, 143), client_beatmap.get("total_length").?.integer);
    try std.testing.expectEqual(@as(i64, 119), client_beatmap.get("hit_length").?.integer);
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

test "ordinary rooms expire the played map and choose the next playlist order" {
    var room: Room = .{ .id = 12, .settings = .{}, .host_id = 4 };
    room.settings.playlist_item_id = 10;
    room.users[0] = try defaultRoomUser(4, "host", .{ 'A', 'U' });
    room.users[0].?.voted_skip = true;
    room.user_count = 1;
    room.playlist[0] = .{ .id = 10, .owner_id = 4, .beatmap_id = 100, .order = 0 };
    room.playlist[2] = .{ .id = 30, .owner_id = 4, .beatmap_id = 300, .order = 2 };
    room.playlist_count = 2;

    try std.testing.expectEqual(@as(?u16, 3), nextPlaylistOrder(&room));
    room.playlist[2].?.order = std.math.maxInt(u16);
    try std.testing.expectEqual(@as(?u16, null), nextPlaylistOrder(&room));
    room.playlist[2].?.order = 2;
    const first = advanceRoomPlaylist(&room);
    try std.testing.expectEqual(@as(?i64, 30), first.next_item_id);
    try std.testing.expectEqual(@as(i64, 10), first.expired.?.id);
    try std.testing.expect(room.playlist[0].?.expired);
    try std.testing.expectEqual(@as(i64, 30), room.settings.playlist_item_id);
    try std.testing.expect(!room.users[0].?.voted_skip);

    const last = advanceRoomPlaylist(&room);
    try std.testing.expectEqual(@as(i64, 30), last.expired.?.id);
    try std.testing.expectEqual(@as(?i64, null), last.next_item_id);
    try std.testing.expect(room.playlist[2].?.expired);
}

test "ranked rooms load persistent ratings and settle a room once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/ranked-room.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(10,'ranked one','ranked_one',x'00',x'00'),(11,'ranked two','ranked_two',x'00',x'00');" ++
            "INSERT INTO lazer_ranked_ratings(user_id,ruleset_id,rating) VALUES(10,1,1700),(11,1,1400);" ++
            "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,mode,star_rating,osu_file) VALUES(75,750,'0123456789abcdef0123456789abcdef','fixture','ranked','taiko','mapper',3,1,4.5,x'00');",
    );

    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    try manager.setMatchmakingMaps(1, &.{.{ .id = 75, .md5 = "0123456789abcdef0123456789abcdef".*, .mode = 1, .stars = 4.5 }});
    const pending: PendingMatch = .{ .id = 1, .pool_id = 102, .users = .{ 10, 11 }, .created_at = 0 };
    const room = try manager.createMatchmakingRoomLocked(pending, "secret");
    defer std.testing.allocator.destroy(room);
    try std.testing.expectEqual(@as(i32, 1700), room.ranked_play.?.users[0].?.rating);
    try std.testing.expectEqual(@as(i32, 1400), room.ranked_play.?.users[1].?.rating);

    room.ranked_play.?.winning_user_id = 10;
    room.ranked_play.?.stage = ranked_stage.ended;
    try manager.persistRankedResult(room);
    try std.testing.expect(room.ranked_play.?.result_persisted);
    try std.testing.expectEqual(@as(i32, 1716), room.ranked_play.?.users[0].?.rating_after);
    try std.testing.expectEqual(@as(i32, 1384), room.ranked_play.?.users[1].?.rating_after);
    try manager.persistRankedResult(room);
    try std.testing.expectEqual(@as(i32, 1), (try store.lazerRankedRating(10, 1)).games_played);
    try std.testing.expectEqual(@as(i32, 1), (try store.lazerRankedRating(11, 1)).games_played);
}

test "ranked result database settlement never holds the multiplayer manager mutex" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/ranked-result-unlocked.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(10,'ranked one','ranked_one',x'00',x'00'),(11,'ranked two','ranked_two',x'00',x'00');" ++
            "INSERT INTO lazer_ranked_ratings(user_id,ruleset_id,rating) VALUES(10,1,1700),(11,1,1400);" ++
            "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,mode,star_rating,osu_file) VALUES(75,750,'0123456789abcdef0123456789abcdef','fixture','ranked','taiko','mapper',3,1,4.5,x'00');",
    );

    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    try manager.setMatchmakingMaps(1, &.{.{ .id = 75, .md5 = "0123456789abcdef0123456789abcdef".*, .mode = 1, .stars = 4.5 }});
    const pending: PendingMatch = .{ .id = 1, .pool_id = 102, .users = .{ 10, 11 }, .created_at = 0 };
    const room = try manager.createMatchmakingRoomLocked(pending, "secret");
    room.ranked_play.?.winning_user_id = 10;
    room.ranked_play.?.stage = ranked_stage.ended;
    manager.rooms[0] = room;

    const Settlement = struct {
        manager: *Manager,
        room_id: i64,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,

        fn run(context: *@This()) void {
            context.started.store(true, .release);
            context.manager.persistLiveRankedResult(context.room_id) catch |err| {
                context.failure = err;
            };
            context.done.store(true, .release);
        }
    };
    store.mutex.lockUncancelable(std.testing.io);
    var settlement: Settlement = .{ .manager = &manager, .room_id = room.id };
    const settlement_thread = try std.Thread.spawn(.{}, Settlement.run, .{&settlement});
    while (!settlement.started.load(.acquire)) std.Thread.yield() catch {};
    _ = std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    try std.testing.expect(!settlement.done.load(.acquire));

    // The storage operation is deliberately blocked above. An unrelated user
    // must still be able to enter and leave the manager immediately.
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const guest: domain.User = .{ .id = 20, .name = "unrelated", .safe_name = "unrelated", .country = .{ 'G', 'B' } };
    const unrelated = try manager.connect(guest, fake_socket);
    unrelated.socket = null;
    manager.disconnect(unrelated);

    store.mutex.unlock(std.testing.io);
    settlement_thread.join();
    try std.testing.expect(settlement.failure == null);
    try std.testing.expect(room.ranked_play.?.result_persisted);
    try std.testing.expectEqual(@as(i32, 1716), room.ranked_play.?.users[0].?.rating_after);
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
    room.users[0] = try defaultRoomUser(4, "ranked timeout", .{ 'A', 'U' });
    room.user_count = 1;
    try room.users[0].?.availability.set(&.{ 0x92, beatmap_availability_locally_available, 0xc0 });
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
    try std.testing.expectEqual(beatmap_availability_unknown, beatmapAvailabilityState(room.users[0].?.availability.slice()).?);
    try std.testing.expectEqual(@as(usize, 0), try manager.advanceExpiredRankedPicks(2_000));
}

test "ranked card selection clears stale beatmap availability" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer {
        manager.shutting_down = true;
        manager.deinit();
    }
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const user: domain.User = .{ .id = 4, .name = "ranked picker", .safe_name = "ranked_picker", .country = .{ 'A', 'U' } };
    const connection = try manager.connect(user, fake_socket);
    connection.socket = null;
    connection.room_id = 9;

    const room = try std.testing.allocator.create(Room);
    room.* = .{ .id = 9, .settings = .{}, .host_id = user.id, .ranked_play = .{} };
    try room.settings.name.set("ranked selection");
    try room.settings.auto_start.set(&.{0xc0});
    var item: PlaylistItem = .{ .id = 51, .owner_id = user.id, .beatmap_id = 75 };
    try item.required_mods.set(&.{0x90});
    try item.allowed_mods.set(&.{0x90});
    try item.played_at.set(&.{0xc0});
    room.playlist[0] = item;
    room.playlist_count = 1;
    room.users[0] = try defaultRoomUser(user.id, user.name, user.country);
    room.user_count = 1;
    try room.users[0].?.availability.set(&.{ 0x92, beatmap_availability_locally_available, 0xc0 });
    room.ranked_play.?.stage = ranked_stage.card_play;
    room.ranked_play.?.current_round = 1;
    room.ranked_play.?.active_user_id = user.id;
    room.ranked_play.?.users[0] = .{ .id = user.id };
    room.ranked_play.?.user_count = 1;
    var card: RankedCard = .{ .playlist_item_id = item.id };
    card.id.setText("00112233-4455-6677-8899-aabbccddeeff");
    room.ranked_play.?.users[0].?.hand[0] = card;
    room.ranked_play.?.users[0].?.hand_count = 1;
    manager.rooms[0] = room;

    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    const pack: MessagePackWriter = .{ .writer = &encoded.writer };
    try pack.array(1);
    try pack.string(card.id.slice());
    try manager.playRankedCard(connection, null, encoded.written());

    try std.testing.expectEqual(@as(u8, ranked_stage.finish_card_play), room.ranked_play.?.stage);
    try std.testing.expectEqual(@as(i64, item.id), room.settings.playlist_item_id);
    try std.testing.expectEqual(beatmap_availability_unknown, beatmapAvailabilityState(room.users[0].?.availability.slice()).?);
}

test "ranked card finish waits for every beatmap before ready starts gameplay" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer {
        manager.shutting_down = true;
        manager.deinit();
    }
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const first_user: domain.User = .{ .id = 4, .name = "ranked one", .safe_name = "ranked_one", .country = .{ 'A', 'U' } };
    const second_user: domain.User = .{ .id = 5, .name = "ranked two", .safe_name = "ranked_two", .country = .{ 'G', 'B' } };
    const first = try manager.connect(first_user, fake_socket);
    first.socket = null;
    first.room_id = 9;
    const second = try manager.connect(second_user, fake_socket);
    second.socket = null;
    second.room_id = 9;

    const room = try std.testing.allocator.create(Room);
    room.* = .{ .id = 9, .settings = .{}, .host_id = 3, .ranked_play = .{} };
    try room.settings.name.set("ranked warmup");
    room.users[0] = try defaultRoomUser(first_user.id, first_user.name, first_user.country);
    room.users[1] = try defaultRoomUser(second_user.id, second_user.name, second_user.country);
    room.user_count = 2;
    room.ranked_play.?.stage = ranked_stage.finish_card_play;
    room.ranked_play.?.current_round = 1;
    room.ranked_play.?.users[0] = .{ .id = first_user.id };
    room.ranked_play.?.users[1] = .{ .id = second_user.id };
    room.ranked_play.?.user_count = 2;
    manager.rooms[0] = room;

    const locally_available = [_]u8{ 0x92, beatmap_availability_locally_available, 0xc0 };
    try manager.changeAvailability(first, null, &locally_available);
    try std.testing.expectEqual(@as(u8, ranked_stage.finish_card_play), room.ranked_play.?.stage);
    try manager.changeAvailability(second, null, &locally_available);
    try std.testing.expectEqual(@as(u8, ranked_stage.gameplay_warmup), room.ranked_play.?.stage);

    try manager.changeState(first, null, 1);
    try std.testing.expectEqual(@as(u8, ranked_stage.gameplay_warmup), room.ranked_play.?.stage);
    try std.testing.expectEqual(@as(u8, 0), room.state);
    try manager.changeState(second, null, 1);
    try std.testing.expectEqual(@as(u8, ranked_stage.gameplay), room.ranked_play.?.stage);
    try std.testing.expectEqual(@as(u8, 1), room.state);
    try std.testing.expectEqual(@as(u8, 2), room.users[0].?.state);
    try std.testing.expectEqual(@as(u8, 2), room.users[1].?.state);
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
