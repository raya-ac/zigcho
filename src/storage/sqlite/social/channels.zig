const std = @import("std");
const lazer = @import("../../../lazer.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const ChatCursor = @import("../../contracts.zig").ChatCursor;

pub fn lazerRoomChannelCursor(self: *Store, user_id: i32, room_id: i64) !ChatCursor {
    if (user_id <= 0) return error.InvalidUser;
    const channel_id = lazer.roomChannelId(room_id) orelse return error.UnknownChannel;
    var target_buffer: [64]u8 = undefined;
    const target = try lazer.roomChannelName(&target_buffer, room_id);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT (SELECT max(id) FROM chat_messages WHERE target=?1),(SELECT last_read_id FROM lazer_channel_reads WHERE user_id=?2 AND channel_id=?3)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, target.ptr, @intCast(target.len), null);
    _ = c.sqlite3_bind_int(stmt, 2, user_id);
    _ = c.sqlite3_bind_int64(stmt, 3, channel_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return .{
        .last_message_id = if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 0),
        .last_read_id = if (c.sqlite3_column_type(stmt, 1) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 1),
    };
}

pub fn markLazerRoomChannelRead(self: *Store, user_id: i32, room_id: i64, message_id: i64) !void {
    if (user_id <= 0 or message_id <= 0) return error.InvalidChatQuery;
    const channel_id = lazer.roomChannelId(room_id) orelse return error.UnknownChannel;
    var target_buffer: [64]u8 = undefined;
    const target = try lazer.roomChannelName(&target_buffer, room_id);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    var found: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM chat_messages WHERE id=?1 AND target=?2", -1, &found, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_int64(found, 1, message_id);
    _ = c.sqlite3_bind_text(found, 2, target.ptr, @intCast(target.len), null);
    const exists = c.sqlite3_step(found) == c.SQLITE_ROW;
    _ = c.sqlite3_finalize(found);
    if (!exists) return error.ChatMessageNotFound;

    var update: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO lazer_channel_reads(user_id,channel_id,last_read_id) VALUES(?1,?2,?3) ON CONFLICT(user_id,channel_id) DO UPDATE SET last_read_id=max(last_read_id,excluded.last_read_id),updated_at=unixepoch()", -1, &update, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(update);
    _ = c.sqlite3_bind_int(update, 1, user_id);
    _ = c.sqlite3_bind_int64(update, 2, channel_id);
    _ = c.sqlite3_bind_int64(update, 3, message_id);
    if (c.sqlite3_step(update) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn lazerChannelListJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]u8 {
    if (user_id <= 0) return error.InvalidUser;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT (SELECT max(id) FROM chat_messages WHERE target=?1),(SELECT last_read_id FROM lazer_channel_reads WHERE user_id=?2 AND channel_id=?3)";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var channel_id: i64 = 1;
    while (channel_id <= 4) : (channel_id += 1) {
        if (channel_id != 1) try output.writer.writeByte(',');
        const target = lazer.channelName(channel_id).?;
        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, target.ptr, @intCast(target.len), null);
        _ = c.sqlite3_bind_int(stmt, 2, user_id);
        _ = c.sqlite3_bind_int64(stmt, 3, channel_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        const last_message_id: ?i64 = if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 0);
        const last_read_id: ?i64 = if (c.sqlite3_column_type(stmt, 1) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 1);
        try lazer.writeChatChannel(&output.writer, channel_id, last_message_id, last_read_id);
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn lazerChannelCursor(self: *Store, user_id: i32, channel_id: i64) !ChatCursor {
    const target = lazer.channelName(channel_id) orelse return error.UnknownChannel;
    if (user_id <= 0) return error.InvalidUser;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT (SELECT max(id) FROM chat_messages WHERE target=?1),(SELECT last_read_id FROM lazer_channel_reads WHERE user_id=?2 AND channel_id=?3)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, target.ptr, @intCast(target.len), null);
    _ = c.sqlite3_bind_int(stmt, 2, user_id);
    _ = c.sqlite3_bind_int64(stmt, 3, channel_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return .{
        .last_message_id = if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 0),
        .last_read_id = if (c.sqlite3_column_type(stmt, 1) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 1),
    };
}

pub fn lazerDirectMessageCursor(self: *Store, viewer_id: i32, other_id: i32) !ChatCursor {
    if (viewer_id <= 0 or other_id <= 0 or viewer_id == other_id) return error.InvalidDirectMessage;
    var target_buffer: [64]u8 = undefined;
    const target = try lazer.directMessageTarget(&target_buffer, viewer_id, other_id);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT max(m.id),CASE WHEN (SELECT min(d.chat_message_id) FROM direct_messages d WHERE d.to_id=?2 AND d.from_id=?3 AND d.read=0 AND d.chat_message_id IS NOT NULL) IS NULL THEN max(m.id) ELSE (SELECT max(previous.id) FROM chat_messages previous WHERE previous.target=?1 AND previous.id<(SELECT min(d.chat_message_id) FROM direct_messages d WHERE d.to_id=?2 AND d.from_id=?3 AND d.read=0 AND d.chat_message_id IS NOT NULL)) END FROM chat_messages m WHERE m.target=?1";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, target.ptr, @intCast(target.len), null);
    _ = c.sqlite3_bind_int(stmt, 2, viewer_id);
    _ = c.sqlite3_bind_int(stmt, 3, other_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return .{
        .last_message_id = if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 0),
        .last_read_id = if (c.sqlite3_column_type(stmt, 1) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 1),
    };
}

pub fn markLazerChannelRead(self: *Store, user_id: i32, channel_id: i64, message_id: i64) !void {
    const target = lazer.channelName(channel_id) orelse return error.UnknownChannel;
    if (user_id <= 0 or message_id <= 0) return error.InvalidChatQuery;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "INSERT INTO lazer_channel_reads(user_id,channel_id,last_read_id) SELECT ?1,?2,?3 WHERE EXISTS(SELECT 1 FROM chat_messages WHERE id=?3 AND target=?4) ON CONFLICT(user_id,channel_id) DO UPDATE SET last_read_id=max(last_read_id,excluded.last_read_id),updated_at=unixepoch()";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int64(stmt, 2, channel_id);
    _ = c.sqlite3_bind_int64(stmt, 3, message_id);
    _ = c.sqlite3_bind_text(stmt, 4, target.ptr, @intCast(target.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    if (c.sqlite3_changes(self.db) == 0) return error.ChatMessageNotFound;
}

pub fn markLazerDirectMessageRead(self: *Store, viewer_id: i32, other_id: i32, message_id: i64) !void {
    if (viewer_id <= 0 or other_id <= 0 or viewer_id == other_id or message_id <= 0) return error.InvalidChatQuery;
    var target_buffer: [64]u8 = undefined;
    const target = try lazer.directMessageTarget(&target_buffer, viewer_id, other_id);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var message: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM chat_messages WHERE id=?1 AND target=?2", -1, &message, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_int64(message, 1, message_id);
    _ = c.sqlite3_bind_text(message, 2, target.ptr, @intCast(target.len), null);
    const found = c.sqlite3_step(message) == c.SQLITE_ROW;
    _ = c.sqlite3_finalize(message);
    if (!found) return error.ChatMessageNotFound;
    var update: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE direct_messages SET read=1 WHERE to_id=?1 AND from_id=?2 AND read=0 AND (chat_message_id IS NULL OR chat_message_id<=?3)", -1, &update, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(update);
    _ = c.sqlite3_bind_int(update, 1, viewer_id);
    _ = c.sqlite3_bind_int(update, 2, other_id);
    _ = c.sqlite3_bind_int64(update, 3, message_id);
    if (c.sqlite3_step(update) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    try self.exec("COMMIT");
}
