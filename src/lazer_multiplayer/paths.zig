const std = @import("std");

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
