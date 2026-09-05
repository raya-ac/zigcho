const std = @import("std");
const domain = @import("../../domain.zig");
const lazer = @import("../../lazer.zig");
const publicCountry = @import("../rooms/state.zig").publicCountry;
const max_users = @import("../../lazer_multiplayer.zig").max_users;
const max_playlist = @import("../../lazer_multiplayer.zig").max_playlist;
const max_room_scores = @import("../../lazer_multiplayer.zig").max_room_scores;
const max_room_participants = @import("../../lazer_multiplayer.zig").max_room_participants;
const timespan_ticks_per_second = @import("../../lazer_multiplayer.zig").timespan_ticks_per_second;
const jsonInteger = @import("../archive/codec.zig").jsonInteger;
const archivedScoreRecord = @import("../archive/codec.zig").archivedScoreRecord;
const archivedScoreTokenRecord = @import("../archive/codec.zig").archivedScoreTokenRecord;
const RoomScoreRecord = @import("../../lazer_multiplayer.zig").RoomScoreRecord;
const FixedRaw = @import("../../lazer_multiplayer.zig").FixedRaw;
const MessagePackWriter = @import("../../lazer_multiplayer.zig").MessagePackWriter;
const PlaylistItem = @import("../../lazer_multiplayer.zig").PlaylistItem;
const RoomUser = @import("../../lazer_multiplayer.zig").RoomUser;
const RoomParticipant = @import("../../lazer_multiplayer.zig").RoomParticipant;
const Room = @import("../rooms/model.zig").Room;
const defaultRoomUser = @import("../rooms/state.zig").defaultRoomUser;

pub fn jsonString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (object.get(key) orelse return error.InvalidMultiplayerRoom) {
        .string => |value| value,
        else => error.InvalidMultiplayerRoom,
    };
}

pub fn jsonOptionalString(object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    return switch (object.get(key) orelse return null) {
        .null => null,
        .string => |value| value,
        else => error.InvalidMultiplayerRoom,
    };
}

pub fn beatmapStatusValue(value: std.json.Value) !i8 {
    return switch (value) {
        .integer => |status| std.math.cast(i8, status) orelse error.InvalidMultiplayerRoom,
        .string => |status| if (std.mem.eql(u8, status, "graveyard")) 0 else if (std.mem.eql(u8, status, "wip")) 1 else if (std.mem.eql(u8, status, "pending")) 2 else if (std.mem.eql(u8, status, "ranked")) 3 else if (std.mem.eql(u8, status, "approved")) 4 else if (std.mem.eql(u8, status, "qualified")) 5 else if (std.mem.eql(u8, status, "loved")) 6 else return error.InvalidMultiplayerRoom,
        else => error.InvalidMultiplayerRoom,
    };
}

pub fn jsonOptionalInteger(object: std.json.ObjectMap, key: []const u8) !?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .integer => |integer| integer,
        else => error.InvalidMultiplayerRoom,
    };
}

pub fn jsonOptionalBool(object: std.json.ObjectMap, key: []const u8, default: bool) !bool {
    const value = object.get(key) orelse return default;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidMultiplayerRoom,
    };
}

pub fn jsonNumber(value: std.json.Value) !f64 {
    const number: f64 = switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return error.InvalidMultiplayerRoom,
    };
    if (!std.math.isFinite(number)) return error.InvalidMultiplayerRoom;
    return number;
}

pub fn jsonValueMessagePack(pack: MessagePackWriter, value: std.json.Value, depth: u8) !void {
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

pub fn setJsonMessagePack(comptime capacity: usize, destination: *FixedRaw(capacity), value: std.json.Value, allocator: std.mem.Allocator) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    jsonValueMessagePack(.{ .writer = &output.writer }, value, 0) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try destination.set(output.written());
}

pub fn roomUserFromJson(value: std.json.Value) !RoomUser {
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

pub fn restoreRoomCheckpoint(allocator: std.mem.Allocator, room_json: []const u8, now_seconds: i64) !?*Room {
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

pub fn parseRestRoom(allocator: std.mem.Allocator, user: domain.User, body: []const u8, now_seconds: i64, allow_checkpoint: bool) !*Room {
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
