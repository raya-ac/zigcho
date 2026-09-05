const std = @import("std");
const jsonInteger = @import("codec.zig").jsonInteger;
const PlaylistItem = @import("../../lazer_multiplayer.zig").PlaylistItem;
const Room = @import("../rooms/model.zig").Room;
const Manager = @import("../../lazer_multiplayer.zig").Manager;

pub fn hydratePlaylistItem(self: *Manager, item: *PlaylistItem) !void {
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

pub fn hydrateRoom(self: *Manager, room: *Room) !void {
    for (&room.playlist) |*entry| if (entry.*) |*item| try self.hydratePlaylistItem(item);
}

pub fn hydrateArchivedPlaylistItem(self: *Manager, arena: std.mem.Allocator, value: *std.json.Value) !void {
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

pub fn userCountryVisible(self: *Manager, user_id: i32) !bool {
    const store = self.store orelse return false;
    const visibility = (try store.lazerBatchUserVisibility(user_id)) orelse return false;
    return visibility.show_country;
}

pub fn applyRoomCountryVisibility(self: *Manager, room: *Room) !void {
    for (&room.users) |*entry| if (entry.*) |*user| {
        if (!try self.userCountryVisible(user.id)) user.country = .{ 'X', 'X' };
        if (user.id == room.host_id) room.host_country = user.country;
    };
    for (room.participants[0..room.participant_count]) |*entry| if (entry.*) |*participant| {
        if (!try self.userCountryVisible(participant.id)) participant.country = .{ 'X', 'X' };
    };
}

pub fn sanitizeArchivedApiUser(self: *Manager, arena: std.mem.Allocator, value: *std.json.Value) !void {
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

pub fn normalizeArchivedPlaylistRulesets(arena: std.mem.Allocator, room: *std.json.ObjectMap) !void {
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

pub fn writeHydratedArchiveJson(self: *Manager, writer: *std.Io.Writer, room_json: []const u8) !void {
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

pub fn writeSanitizedArchiveLeaderboardJson(self: *Manager, writer: *std.Io.Writer, leaderboard_json: []const u8) !void {
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
