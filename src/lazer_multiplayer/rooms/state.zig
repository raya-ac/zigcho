const std = @import("std");
const domain = @import("../../domain.zig");
const MessagePackReader = @import("../../lazer_multiplayer.zig").MessagePackReader;
const checkedReaderInteger = @import("../../lazer_multiplayer.zig").checkedReaderInteger;
const PlaylistItem = @import("../../lazer_multiplayer.zig").PlaylistItem;
const RoomUser = @import("../../lazer_multiplayer.zig").RoomUser;
const PlaylistAdvance = @import("../../lazer_multiplayer.zig").PlaylistAdvance;
const Room = @import("model.zig").Room;
const beatmap_availability_unknown = @import("../../lazer_multiplayer.zig").beatmap_availability_unknown;
const beatmap_availability_locally_available = @import("../../lazer_multiplayer.zig").beatmap_availability_locally_available;

pub fn publicCountry(user: domain.User) [2]u8 {
    return if (user.show_country) user.country else .{ 'X', 'X' };
}

pub fn defaultRoomUser(user_id: i32, name: []const u8, country: [2]u8) !RoomUser {
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

pub fn beatmapAvailabilityState(encoded: []const u8) ?u8 {
    var reader: MessagePackReader = .{ .data = encoded };
    if ((reader.arrayLen() catch return null) != 2) return null;
    const state = checkedReaderInteger(u8, &reader) catch return null;
    reader.skip(0) catch return null;
    if (reader.pos != reader.data.len or state > beatmap_availability_locally_available) return null;
    return state;
}

pub fn resetRoomBeatmapAvailability(room: *Room) void {
    for (&room.users) |*entry| if (entry.*) |*user| {
        user.availability.bytes[0] = 0x92;
        user.availability.bytes[1] = beatmap_availability_unknown;
        user.availability.bytes[2] = 0xc0;
        user.availability.len = 3;
    };
}

pub fn roomBeatmapsLocallyAvailable(room: *const Room) bool {
    if (room.user_count == 0) return false;
    var users_seen: usize = 0;
    for (room.users) |entry| if (entry) |user| {
        users_seen += 1;
        if (beatmapAvailabilityState(user.availability.slice()) != beatmap_availability_locally_available) return false;
    };
    return users_seen == room.user_count;
}

pub fn nextTeamId(room: *const Room) i32 {
    var red: usize = 0;
    var blue: usize = 0;
    for (room.users) |entry| if (entry) |user| {
        if (user.team_id == 0) red += 1 else if (user.team_id == 1) blue += 1;
    };
    return if (red <= blue) 0 else 1;
}

pub fn nextPlaylistOrder(room: *const Room) ?u16 {
    var highest: ?u16 = null;
    for (room.playlist) |entry| {
        if (entry) |item| highest = if (highest) |value| @max(value, item.order) else item.order;
    }
    return if (highest) |value| std.math.add(u16, value, 1) catch null else 0;
}

pub fn advanceRoomPlaylist(room: *Room) PlaylistAdvance {
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
