const std = @import("std");
const max_users = @import("../../lazer_multiplayer.zig").max_users;
const max_playlist = @import("../../lazer_multiplayer.zig").max_playlist;
const MessagePackReader = @import("../../lazer_multiplayer.zig").MessagePackReader;
const checkedReaderInteger = @import("../../lazer_multiplayer.zig").checkedReaderInteger;
const checkedNullableInteger = @import("../../lazer_multiplayer.zig").checkedNullableInteger;
const PlaylistItem = @import("../../lazer_multiplayer.zig").PlaylistItem;
const Settings = @import("../../lazer_multiplayer.zig").Settings;
const Room = @import("../rooms/model.zig").Room;
const Connection = @import("../transport/model.zig").Connection;
const defaultRoomUser = @import("../rooms/state.zig").defaultRoomUser;

pub fn parseSettings(encoded: []const u8) !Settings {
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

pub fn parsePlaylistItem(encoded: []const u8) !PlaylistItem {
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

pub fn parseRoom(allocator: std.mem.Allocator, encoded: []const u8, connection: *Connection) !*Room {
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
