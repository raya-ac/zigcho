const std = @import("std");
const max_playlist = @import("../../lazer_multiplayer.zig").max_playlist;
const max_room_scores = @import("../../lazer_multiplayer.zig").max_room_scores;
const RoomScoreContext = @import("../../lazer_multiplayer.zig").RoomScoreContext;
const RoomScoreTokenRecord = @import("../../lazer_multiplayer.zig").RoomScoreTokenRecord;
const RoomScoreRecord = @import("../../lazer_multiplayer.zig").RoomScoreRecord;
const Room = @import("../rooms/model.zig").Room;

pub fn archiveIncludesUser(allocator: std.mem.Allocator, participant_ids_json: []const u8, user_id: i32) bool {
    return archiveIncludesUserFallible(allocator, participant_ids_json, user_id) catch false;
}

pub fn archiveIncludesUserFallible(allocator: std.mem.Allocator, participant_ids_json: []const u8, user_id: i32) !bool {
    const parsed = try std.json.parseFromSlice([]i32, allocator, participant_ids_json, .{});
    defer parsed.deinit();
    return std.mem.indexOfScalar(i32, parsed.value, user_id) != null;
}

pub fn jsonInteger(value: ?std.json.Value) ?i64 {
    return switch (value orelse return null) {
        .integer => |integer| integer,
        else => null,
    };
}

pub fn jsonFloat(value: ?std.json.Value) ?f64 {
    return switch (value orelse return null) {
        .float => |number| number,
        .integer => |integer| @floatFromInt(integer),
        else => null,
    };
}

pub fn archivedScoreRecord(value: std.json.Value) ?RoomScoreRecord {
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

pub fn archivedScoreTokenRecord(value: std.json.Value) ?RoomScoreTokenRecord {
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

pub fn archivedScoreContext(allocator: std.mem.Allocator, room_json: []const u8, playlist_item_id: i64) !?RoomScoreContext {
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

pub fn archivedScoreTokenBound(allocator: std.mem.Allocator, room_json: []const u8, token_id: i64, user_id: i32, playlist_item_id: i64) !bool {
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

pub fn archivedRoomRealtime(allocator: std.mem.Allocator, room_json: []const u8) !bool {
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

pub fn restoreArchivedPlaylist(root: *const std.json.ObjectMap, room: *Room) !void {
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

pub fn archivedLeaderboardHasRows(allocator: std.mem.Allocator, leaderboard_json: []const u8) !bool {
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

pub fn archivedScores(allocator: std.mem.Allocator, room_json: []const u8, playlist_item_id: i64, visitor: anytype) !void {
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
