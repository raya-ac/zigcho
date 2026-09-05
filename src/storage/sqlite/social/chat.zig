const std = @import("std");
const lazer = @import("../../../lazer.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const LazerChatWrite = @import("../../contracts.zig").LazerChatWrite;
const jsonString = @import("../beatmaps/lazer_listing.zig").jsonString;

pub fn recordLazerPublicMessage(self: *Store, allocator: std.mem.Allocator, sender_id: i32, target: []const u8, message: []const u8, is_action: bool, uuid: []const u8) !LazerChatWrite {
    const channel_id = lazer.channelId(target) orelse return error.UnknownChannel;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    var access: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT u.privileges,c.write_privileges,c.locked FROM users u JOIN chat_channels c ON c.name=?2 WHERE u.id=?1", -1, &access, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(access);
    _ = c.sqlite3_bind_int(access, 1, sender_id);
    _ = c.sqlite3_bind_text(access, 2, target.ptr, @intCast(target.len), null);
    if (c.sqlite3_step(access) != c.SQLITE_ROW) return error.UnknownChannel;
    const privileges: u32 = @intCast(c.sqlite3_column_int64(access, 0));
    const required: u32 = @intCast(c.sqlite3_column_int64(access, 1));
    if (c.sqlite3_column_int(access, 2) != 0 or privileges & required == 0) return error.ChannelReadOnly;

    var insert: ?*c.sqlite3_stmt = null;
    const insert_sql = "INSERT OR IGNORE INTO chat_messages(sender_id,target,message,is_action,client_uuid) VALUES(?1,?2,?3,?4,?5)";
    if (c.sqlite3_prepare_v2(self.db, insert_sql, -1, &insert, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(insert);
    _ = c.sqlite3_bind_int(insert, 1, sender_id);
    _ = c.sqlite3_bind_text(insert, 2, target.ptr, @intCast(target.len), null);
    _ = c.sqlite3_bind_text(insert, 3, message.ptr, @intCast(message.len), null);
    _ = c.sqlite3_bind_int(insert, 4, @intFromBool(is_action));
    _ = c.sqlite3_bind_text(insert, 5, uuid.ptr, @intCast(uuid.len), null);
    if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    const inserted = c.sqlite3_changes(self.db) != 0;

    var row: ?*c.sqlite3_stmt = null;
    const row_sql = "SELECT m.id,m.target,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,u.privileges FROM chat_messages m JOIN users u ON u.id=m.sender_id WHERE m.sender_id=?1 AND m.client_uuid=?2";
    if (c.sqlite3_prepare_v2(self.db, row_sql, -1, &row, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(row);
    _ = c.sqlite3_bind_int(row, 1, sender_id);
    _ = c.sqlite3_bind_text(row, 2, uuid.ptr, @intCast(uuid.len), null);
    if (c.sqlite3_step(row) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    if (!std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(row, 1)), target) or
        !std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(row, 2)), message) or
        (c.sqlite3_column_int(row, 3) != 0) != is_action) return error.ChatUuidConflict;

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try lazer.writeChatMessage(&output.writer, .{
        .id = c.sqlite3_column_int64(row, 0),
        .channel_id = channel_id,
        .sender_id = sender_id,
        .sender_name = std.mem.span(c.sqlite3_column_text(row, 6)),
        .sender_country = std.mem.span(c.sqlite3_column_text(row, 7)),
        .sender_privileges = @intCast(c.sqlite3_column_int64(row, 8)),
        .content = message,
        .is_action = is_action,
        .uuid = uuid,
        .timestamp = std.mem.span(c.sqlite3_column_text(row, 5)),
    });
    return .{ .json = try output.toOwnedSlice(), .inserted = inserted };
}

pub fn recordLazerRoomMessage(self: *Store, allocator: std.mem.Allocator, sender_id: i32, room_id: i64, message: []const u8, is_action: bool, uuid: []const u8) !LazerChatWrite {
    const channel_id = lazer.roomChannelId(room_id) orelse return error.UnknownChannel;
    var target_buffer: [64]u8 = undefined;
    const target = try lazer.roomChannelName(&target_buffer, room_id);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    var insert: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO chat_messages(sender_id,target,message,is_action,client_uuid) VALUES(?1,?2,?3,?4,?5)", -1, &insert, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(insert);
    _ = c.sqlite3_bind_int(insert, 1, sender_id);
    _ = c.sqlite3_bind_text(insert, 2, target.ptr, @intCast(target.len), null);
    _ = c.sqlite3_bind_text(insert, 3, message.ptr, @intCast(message.len), null);
    _ = c.sqlite3_bind_int(insert, 4, @intFromBool(is_action));
    _ = c.sqlite3_bind_text(insert, 5, uuid.ptr, @intCast(uuid.len), null);
    if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    const inserted = c.sqlite3_changes(self.db) != 0;

    var row: ?*c.sqlite3_stmt = null;
    const row_sql = "SELECT m.id,m.target,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,u.privileges FROM chat_messages m JOIN users u ON u.id=m.sender_id WHERE m.sender_id=?1 AND m.client_uuid=?2";
    if (c.sqlite3_prepare_v2(self.db, row_sql, -1, &row, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(row);
    _ = c.sqlite3_bind_int(row, 1, sender_id);
    _ = c.sqlite3_bind_text(row, 2, uuid.ptr, @intCast(uuid.len), null);
    if (c.sqlite3_step(row) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    if (!std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(row, 1)), target) or
        !std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(row, 2)), message) or
        (c.sqlite3_column_int(row, 3) != 0) != is_action) return error.ChatUuidConflict;

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try lazer.writeChatMessage(&output.writer, .{
        .id = c.sqlite3_column_int64(row, 0),
        .channel_id = channel_id,
        .sender_id = sender_id,
        .sender_name = std.mem.span(c.sqlite3_column_text(row, 6)),
        .sender_country = std.mem.span(c.sqlite3_column_text(row, 7)),
        .sender_privileges = @intCast(c.sqlite3_column_int64(row, 8)),
        .content = message,
        .is_action = is_action,
        .uuid = uuid,
        .timestamp = std.mem.span(c.sqlite3_column_text(row, 5)),
    });
    return .{ .json = try output.toOwnedSlice(), .inserted = inserted };
}

pub fn recordLazerDirectMessage(self: *Store, allocator: std.mem.Allocator, sender_id: i32, target_id: i32, message: []const u8, is_action: bool, uuid: []const u8) !LazerChatWrite {
    const channel_id = lazer.privateChannelId(target_id) orelse return error.InvalidDirectMessage;
    var target_buffer: [64]u8 = undefined;
    const target = try lazer.directMessageTarget(&target_buffer, sender_id, target_id);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (!try self.directMessageAllowedLocked(sender_id, target_id)) return error.DirectMessageBlocked;
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};

    var insert: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO chat_messages(sender_id,target,message,is_action,client_uuid) VALUES(?1,?2,?3,?4,?5)", -1, &insert, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_int(insert, 1, sender_id);
    _ = c.sqlite3_bind_text(insert, 2, target.ptr, @intCast(target.len), null);
    _ = c.sqlite3_bind_text(insert, 3, message.ptr, @intCast(message.len), null);
    _ = c.sqlite3_bind_int(insert, 4, @intFromBool(is_action));
    _ = c.sqlite3_bind_text(insert, 5, uuid.ptr, @intCast(uuid.len), null);
    if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    const inserted = c.sqlite3_changes(self.db) != 0;
    _ = c.sqlite3_finalize(insert);

    var row: ?*c.sqlite3_stmt = null;
    const row_sql = "SELECT m.id,m.target,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,u.privileges FROM chat_messages m JOIN users u ON u.id=m.sender_id WHERE m.sender_id=?1 AND m.client_uuid=?2";
    if (c.sqlite3_prepare_v2(self.db, row_sql, -1, &row, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(row);
    _ = c.sqlite3_bind_int(row, 1, sender_id);
    _ = c.sqlite3_bind_text(row, 2, uuid.ptr, @intCast(uuid.len), null);
    if (c.sqlite3_step(row) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    if (!std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(row, 1)), target) or
        !std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(row, 2)), message) or
        (c.sqlite3_column_int(row, 3) != 0) != is_action) return error.ChatUuidConflict;

    var direct_message_id: ?i64 = null;
    if (inserted) {
        var direct: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT INTO direct_messages(from_id,to_id,message,is_action,client_uuid,chat_message_id) VALUES(?1,?2,?3,?4,?5,?6)", -1, &direct, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(direct);
        _ = c.sqlite3_bind_int(direct, 1, sender_id);
        _ = c.sqlite3_bind_int(direct, 2, target_id);
        _ = c.sqlite3_bind_text(direct, 3, message.ptr, @intCast(message.len), null);
        _ = c.sqlite3_bind_int(direct, 4, @intFromBool(is_action));
        _ = c.sqlite3_bind_text(direct, 5, uuid.ptr, @intCast(uuid.len), null);
        _ = c.sqlite3_bind_int64(direct, 6, c.sqlite3_column_int64(row, 0));
        if (c.sqlite3_step(direct) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        direct_message_id = c.sqlite3_last_insert_rowid(self.db);
    }

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try lazer.writeChatMessage(&output.writer, .{
        .id = c.sqlite3_column_int64(row, 0),
        .channel_id = channel_id,
        .sender_id = sender_id,
        .sender_name = std.mem.span(c.sqlite3_column_text(row, 6)),
        .sender_country = std.mem.span(c.sqlite3_column_text(row, 7)),
        .sender_privileges = @intCast(c.sqlite3_column_int64(row, 8)),
        .content = message,
        .is_action = is_action,
        .uuid = uuid,
        .timestamp = std.mem.span(c.sqlite3_column_text(row, 5)),
    });
    try self.exec("COMMIT");
    return .{ .json = try output.toOwnedSlice(), .inserted = inserted, .direct_message_id = direct_message_id };
}

pub fn lazerDirectMessagesJson(self: *Store, allocator: std.mem.Allocator, viewer_id: i32, other_id: i32, since: i64, limit: u16) ![]u8 {
    if (since < 0 or limit == 0 or limit > 100) return error.InvalidChatQuery;
    const channel_id = lazer.privateChannelId(other_id) orelse return error.InvalidDirectMessage;
    var target_buffer: [64]u8 = undefined;
    const target = try lazer.directMessageTarget(&target_buffer, viewer_id, other_id);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = if (since == 0)
        "SELECT m.id,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM (SELECT * FROM chat_messages WHERE target=?1 ORDER BY id DESC LIMIT ?2) m JOIN users u ON u.id=m.sender_id WHERE u.restricted=0 ORDER BY m.id"
    else
        "SELECT m.id,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM chat_messages m JOIN users u ON u.id=m.sender_id WHERE m.target=?1 AND m.id>?2 AND u.restricted=0 ORDER BY m.id LIMIT ?3";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, target.ptr, @intCast(target.len), null);
    _ = c.sqlite3_bind_int64(stmt, 2, if (since == 0) limit else since);
    if (since != 0) _ = c.sqlite3_bind_int(stmt, 3, limit);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var first = true;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try lazer.writeChatMessage(&output.writer, .{
            .id = c.sqlite3_column_int64(stmt, 0),
            .channel_id = channel_id,
            .sender_id = c.sqlite3_column_int(stmt, 1),
            .sender_name = std.mem.span(c.sqlite3_column_text(stmt, 2)),
            .sender_country = std.mem.span(c.sqlite3_column_text(stmt, 3)),
            .sender_privileges = @intCast(c.sqlite3_column_int64(stmt, 8)),
            .content = std.mem.span(c.sqlite3_column_text(stmt, 4)),
            .is_action = c.sqlite3_column_int(stmt, 5) != 0,
            .uuid = std.mem.span(c.sqlite3_column_text(stmt, 6)),
            .timestamp = std.mem.span(c.sqlite3_column_text(stmt, 7)),
        });
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn directMessageThreadsJson(self: *Store, allocator: std.mem.Allocator, viewer_id: i32, limit: u8) ![]u8 {
    if (viewer_id <= 0 or limit == 0 or limit > 100) return error.InvalidChatQuery;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql =
        "WITH participants AS (SELECT CASE WHEN from_id=?1 THEN to_id ELSE from_id END other_id,max(id) last_id FROM direct_messages WHERE from_id=?1 OR to_id=?1 GROUP BY other_id) " ++
        "SELECT u.id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,u.privileges,d.message,d.is_action,strftime('%Y-%m-%dT%H:%M:%SZ',d.created_at,'unixepoch'),d.from_id,(SELECT count(*) FROM direct_messages unread WHERE unread.to_id=?1 AND unread.from_id=u.id AND unread.read=0) unread FROM participants p JOIN direct_messages d ON d.id=p.last_id JOIN users u ON u.id=p.other_id WHERE u.restricted=0 ORDER BY d.id DESC LIMIT ?2";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, viewer_id);
    _ = c.sqlite3_bind_int(stmt, 2, limit);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var first = true;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.print("{{\"id\":{d},\"name\":", .{c.sqlite3_column_int(stmt, 0)});
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 1)));
        try output.writer.writeAll(",\"country\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 2)));
        try output.writer.print(",\"privileges\":{d},\"last_message\":", .{c.sqlite3_column_int64(stmt, 3)});
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 4)));
        try output.writer.print(",\"is_action\":{},\"last_message_at\":", .{c.sqlite3_column_int(stmt, 5) != 0});
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 6)));
        try output.writer.print(",\"last_sender_id\":{d},\"unread\":{d}}}", .{ c.sqlite3_column_int(stmt, 7), c.sqlite3_column_int64(stmt, 8) });
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn lazerAllMessagesJson(self: *Store, allocator: std.mem.Allocator, viewer_id: i32, since: i64, limit: u16) ![]u8 {
    if (viewer_id <= 0 or since < 0 or limit == 0 or limit > 100) return error.InvalidChatQuery;
    var low_pattern_buffer: [64]u8 = undefined;
    var high_pattern_buffer: [64]u8 = undefined;
    const low_pattern = try std.fmt.bufPrint(&low_pattern_buffer, "@dm:{d}:%", .{viewer_id});
    const high_pattern = try std.fmt.bufPrint(&high_pattern_buffer, "@dm:%:{d}", .{viewer_id});
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const filter = "target IN('#osu','#announce','#lobby','#lazer') OR target LIKE ?1 OR target LIKE ?2";
    const unread_filter = "(m.target IN('#osu','#announce','#lobby','#lazer') AND m.id>coalesce((SELECT r.last_read_id FROM lazer_channel_reads r WHERE r.user_id=?3 AND r.channel_id=CASE m.target WHEN '#osu' THEN 1 WHEN '#announce' THEN 2 WHEN '#lobby' THEN 3 WHEN '#lazer' THEN 4 END),0)) OR ((m.target LIKE ?1 OR m.target LIKE ?2) AND EXISTS(SELECT 1 FROM direct_messages d WHERE d.chat_message_id=m.id AND d.to_id=?3 AND d.read=0))";
    const sql = if (since == 0)
        "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM (SELECT m.* FROM chat_messages m WHERE " ++ unread_filter ++ " ORDER BY m.id DESC LIMIT ?4) m JOIN users u ON u.id=m.sender_id WHERE u.restricted=0 ORDER BY m.id"
    else
        "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM chat_messages m JOIN users u ON u.id=m.sender_id WHERE (" ++ filter ++ ") AND m.id>?3 AND u.restricted=0 ORDER BY m.id LIMIT ?4";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, low_pattern.ptr, @intCast(low_pattern.len), null);
    _ = c.sqlite3_bind_text(stmt, 2, high_pattern.ptr, @intCast(high_pattern.len), null);
    _ = c.sqlite3_bind_int64(stmt, 3, if (since == 0) viewer_id else since);
    _ = c.sqlite3_bind_int(stmt, 4, limit);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var first = true;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const message_target = std.mem.span(c.sqlite3_column_text(stmt, 1));
        const message_channel_id = lazer.channelId(message_target) orelse private: {
            const other_id = lazer.directMessageOther(message_target, viewer_id) orelse continue;
            break :private lazer.privateChannelId(other_id).?;
        };
        if (!first) try output.writer.writeByte(',');
        first = false;
        try lazer.writeChatMessage(&output.writer, .{
            .id = c.sqlite3_column_int64(stmt, 0),
            .channel_id = message_channel_id,
            .sender_id = c.sqlite3_column_int(stmt, 2),
            .sender_name = std.mem.span(c.sqlite3_column_text(stmt, 3)),
            .sender_country = std.mem.span(c.sqlite3_column_text(stmt, 4)),
            .sender_privileges = @intCast(c.sqlite3_column_int64(stmt, 9)),
            .content = std.mem.span(c.sqlite3_column_text(stmt, 5)),
            .is_action = c.sqlite3_column_int(stmt, 6) != 0,
            .uuid = std.mem.span(c.sqlite3_column_text(stmt, 7)),
            .timestamp = std.mem.span(c.sqlite3_column_text(stmt, 8)),
        });
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn lazerAllMessagesForRoomJson(self: *Store, allocator: std.mem.Allocator, viewer_id: i32, room_id: i64, since: i64, limit: u16) ![]u8 {
    const room_channel_id = lazer.roomChannelId(room_id) orelse return error.UnknownChannel;
    if (viewer_id <= 0 or since < 0 or limit == 0 or limit > 100) return error.InvalidChatQuery;
    var low_pattern_buffer: [64]u8 = undefined;
    var high_pattern_buffer: [64]u8 = undefined;
    var room_target_buffer: [64]u8 = undefined;
    const low_pattern = try std.fmt.bufPrint(&low_pattern_buffer, "@dm:{d}:%", .{viewer_id});
    const high_pattern = try std.fmt.bufPrint(&high_pattern_buffer, "@dm:%:{d}", .{viewer_id});
    const room_target = try lazer.roomChannelName(&room_target_buffer, room_id);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const filter = "target IN('#osu','#announce','#lobby','#lazer') OR target LIKE ?1 OR target LIKE ?2 OR target=?5";
    const unread_filter = "(m.target IN('#osu','#announce','#lobby','#lazer') AND m.id>coalesce((SELECT r.last_read_id FROM lazer_channel_reads r WHERE r.user_id=?3 AND r.channel_id=CASE m.target WHEN '#osu' THEN 1 WHEN '#announce' THEN 2 WHEN '#lobby' THEN 3 WHEN '#lazer' THEN 4 END),0)) OR ((m.target LIKE ?1 OR m.target LIKE ?2) AND EXISTS(SELECT 1 FROM direct_messages d WHERE d.chat_message_id=m.id AND d.to_id=?3 AND d.read=0)) OR (m.target=?5 AND m.id>coalesce((SELECT r.last_read_id FROM lazer_channel_reads r WHERE r.user_id=?3 AND r.channel_id=?6),0))";
    const sql = if (since == 0)
        "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM (SELECT m.* FROM chat_messages m WHERE " ++ unread_filter ++ " ORDER BY m.id DESC LIMIT ?4) m JOIN users u ON u.id=m.sender_id WHERE u.restricted=0 ORDER BY m.id"
    else
        "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM chat_messages m JOIN users u ON u.id=m.sender_id WHERE (" ++ filter ++ ") AND m.id>?3 AND u.restricted=0 ORDER BY m.id LIMIT ?4";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, low_pattern.ptr, @intCast(low_pattern.len), null);
    _ = c.sqlite3_bind_text(stmt, 2, high_pattern.ptr, @intCast(high_pattern.len), null);
    _ = c.sqlite3_bind_int64(stmt, 3, if (since == 0) viewer_id else since);
    _ = c.sqlite3_bind_int(stmt, 4, limit);
    _ = c.sqlite3_bind_text(stmt, 5, room_target.ptr, @intCast(room_target.len), null);
    if (since == 0) _ = c.sqlite3_bind_int64(stmt, 6, room_channel_id);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var first = true;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const message_target = std.mem.span(c.sqlite3_column_text(stmt, 1));
        const message_channel_id = if (std.mem.eql(u8, message_target, room_target))
            room_channel_id
        else
            lazer.channelId(message_target) orelse private: {
                const other_id = lazer.directMessageOther(message_target, viewer_id) orelse continue;
                break :private lazer.privateChannelId(other_id).?;
            };
        if (!first) try output.writer.writeByte(',');
        first = false;
        try lazer.writeChatMessage(&output.writer, .{
            .id = c.sqlite3_column_int64(stmt, 0),
            .channel_id = message_channel_id,
            .sender_id = c.sqlite3_column_int(stmt, 2),
            .sender_name = std.mem.span(c.sqlite3_column_text(stmt, 3)),
            .sender_country = std.mem.span(c.sqlite3_column_text(stmt, 4)),
            .sender_privileges = @intCast(c.sqlite3_column_int64(stmt, 9)),
            .content = std.mem.span(c.sqlite3_column_text(stmt, 5)),
            .is_action = c.sqlite3_column_int(stmt, 6) != 0,
            .uuid = std.mem.span(c.sqlite3_column_text(stmt, 7)),
            .timestamp = std.mem.span(c.sqlite3_column_text(stmt, 8)),
        });
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn lazerChatMessagesJson(self: *Store, allocator: std.mem.Allocator, channel_id: ?i64, since: i64, limit: u16) ![]u8 {
    if (since < 0 or limit == 0 or limit > 100) return error.InvalidChatQuery;
    const target = if (channel_id) |id| lazer.channelName(id) orelse return error.UnknownChannel else null;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const sql = if (target != null and since == 0)
        "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM (SELECT * FROM chat_messages WHERE target=?1 ORDER BY id DESC LIMIT ?2) m JOIN users u ON u.id=m.sender_id WHERE u.restricted=0 ORDER BY m.id"
    else if (target != null)
        "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM chat_messages m JOIN users u ON u.id=m.sender_id WHERE m.target=?1 AND m.id>?2 AND u.restricted=0 ORDER BY m.id LIMIT ?3"
    else if (since == 0)
        "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM (SELECT * FROM chat_messages WHERE target IN('#osu','#announce','#lobby','#lazer') ORDER BY id DESC LIMIT ?1) m JOIN users u ON u.id=m.sender_id WHERE u.restricted=0 ORDER BY m.id"
    else
        "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM chat_messages m JOIN users u ON u.id=m.sender_id WHERE m.target IN('#osu','#announce','#lobby','#lazer') AND m.id>?1 AND u.restricted=0 ORDER BY m.id LIMIT ?2";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (target) |name| {
        _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), null);
        if (since == 0) {
            _ = c.sqlite3_bind_int(stmt, 2, limit);
        } else {
            _ = c.sqlite3_bind_int64(stmt, 2, since);
            _ = c.sqlite3_bind_int(stmt, 3, limit);
        }
    } else if (since == 0) {
        _ = c.sqlite3_bind_int(stmt, 1, limit);
    } else {
        _ = c.sqlite3_bind_int64(stmt, 1, since);
        _ = c.sqlite3_bind_int(stmt, 2, limit);
    }

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var first = true;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const message_channel_id = lazer.channelId(std.mem.span(c.sqlite3_column_text(stmt, 1))) orelse continue;
        if (!first) try output.writer.writeByte(',');
        first = false;
        try lazer.writeChatMessage(&output.writer, .{
            .id = c.sqlite3_column_int64(stmt, 0),
            .channel_id = message_channel_id,
            .sender_id = c.sqlite3_column_int(stmt, 2),
            .sender_name = std.mem.span(c.sqlite3_column_text(stmt, 3)),
            .sender_country = std.mem.span(c.sqlite3_column_text(stmt, 4)),
            .sender_privileges = @intCast(c.sqlite3_column_int64(stmt, 9)),
            .content = std.mem.span(c.sqlite3_column_text(stmt, 5)),
            .is_action = c.sqlite3_column_int(stmt, 6) != 0,
            .uuid = std.mem.span(c.sqlite3_column_text(stmt, 7)),
            .timestamp = std.mem.span(c.sqlite3_column_text(stmt, 8)),
        });
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn lazerRoomMessagesJson(self: *Store, allocator: std.mem.Allocator, room_id: i64, since: i64, limit: u16) ![]u8 {
    const channel_id = lazer.roomChannelId(room_id) orelse return error.UnknownChannel;
    if (since < 0 or limit == 0 or limit > 100) return error.InvalidChatQuery;
    var target_buffer: [64]u8 = undefined;
    const target = try lazer.roomChannelName(&target_buffer, room_id);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = if (since == 0)
        "SELECT m.id,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM (SELECT * FROM chat_messages WHERE target=?1 ORDER BY id DESC LIMIT ?2) m JOIN users u ON u.id=m.sender_id WHERE u.restricted=0 ORDER BY m.id"
    else
        "SELECT m.id,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM chat_messages m JOIN users u ON u.id=m.sender_id WHERE m.target=?1 AND m.id>?2 AND u.restricted=0 ORDER BY m.id LIMIT ?3";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, target.ptr, @intCast(target.len), null);
    if (since == 0) {
        _ = c.sqlite3_bind_int(stmt, 2, limit);
    } else {
        _ = c.sqlite3_bind_int64(stmt, 2, since);
        _ = c.sqlite3_bind_int(stmt, 3, limit);
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var first = true;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try lazer.writeChatMessage(&output.writer, .{
            .id = c.sqlite3_column_int64(stmt, 0),
            .channel_id = channel_id,
            .sender_id = c.sqlite3_column_int(stmt, 1),
            .sender_name = std.mem.span(c.sqlite3_column_text(stmt, 2)),
            .sender_country = std.mem.span(c.sqlite3_column_text(stmt, 3)),
            .sender_privileges = @intCast(c.sqlite3_column_int64(stmt, 8)),
            .content = std.mem.span(c.sqlite3_column_text(stmt, 4)),
            .is_action = c.sqlite3_column_int(stmt, 5) != 0,
            .uuid = std.mem.span(c.sqlite3_column_text(stmt, 6)),
            .timestamp = std.mem.span(c.sqlite3_column_text(stmt, 7)),
        });
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}
