const std = @import("std");
const lazer = @import("../../../lazer.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const DirectMessage = @import("../../contracts.zig").DirectMessage;

pub fn directMessageAllowedLocked(self: *Store, from_id: i32, to_id: i32) !bool {
    if (from_id <= 0 or to_id <= 0 or from_id == to_id) return false;
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT EXISTS(SELECT 1 FROM users sender JOIN users recipient ON recipient.id=?2 WHERE sender.id=?1 AND sender.restricted=0 AND recipient.restricted=0 AND NOT EXISTS(SELECT 1 FROM user_blocks b WHERE (b.user_id=?1 AND b.blocked_id=?2) OR (b.user_id=?2 AND b.blocked_id=?1)))";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, from_id);
    _ = c.sqlite3_bind_int(stmt, 2, to_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return c.sqlite3_column_int(stmt, 0) != 0;
}

pub fn directMessageAllowed(self: *Store, from_id: i32, to_id: i32) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.directMessageAllowedLocked(from_id, to_id);
}

pub fn storeDirectMessage(self: *Store, from_id: i32, to_id: i32, message: []const u8) !i64 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (!try self.directMessageAllowedLocked(from_id, to_id)) return error.DirectMessageBlocked;
    var target_buffer: [64]u8 = undefined;
    const target = try lazer.directMessageTarget(&target_buffer, from_id, to_id);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    const chat_message_id: i64 = chat: {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT INTO chat_messages(sender_id,target,message) VALUES(?1,?2,?3)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, from_id);
        _ = c.sqlite3_bind_text(stmt, 2, target.ptr, @intCast(target.len), null);
        _ = c.sqlite3_bind_text(stmt, 3, message.ptr, @intCast(message.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        break :chat c.sqlite3_last_insert_rowid(self.db);
    };
    var direct: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO direct_messages(from_id,to_id,message,chat_message_id) VALUES(?1,?2,?3,?4)", -1, &direct, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(direct);
    _ = c.sqlite3_bind_int(direct, 1, from_id);
    _ = c.sqlite3_bind_int(direct, 2, to_id);
    _ = c.sqlite3_bind_text(direct, 3, message.ptr, @intCast(message.len), null);
    _ = c.sqlite3_bind_int64(direct, 4, chat_message_id);
    if (c.sqlite3_step(direct) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    const direct_message_id = c.sqlite3_last_insert_rowid(self.db);
    try self.exec("COMMIT");
    return direct_message_id;
}

pub fn unreadDirectMessages(self: *Store, allocator: std.mem.Allocator, to_id: i32) ![]DirectMessage {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT d.id,d.from_id,u.name,d.message FROM direct_messages d JOIN users u ON u.id=d.from_id WHERE d.to_id=?1 AND d.read=0 ORDER BY d.created_at,d.id LIMIT 1000", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, to_id);
    var messages: std.ArrayList(DirectMessage) = .empty;
    errdefer {
        for (messages.items) |*message| message.deinit(allocator);
        messages.deinit(allocator);
    }
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const from_name = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)));
        errdefer allocator.free(from_name);
        const message = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3)));
        errdefer allocator.free(message);
        try messages.append(allocator, .{ .id = c.sqlite3_column_int64(stmt, 0), .from_id = c.sqlite3_column_int(stmt, 1), .from_name = from_name, .message = message });
    }
    return messages.toOwnedSlice(allocator);
}

pub fn markDirectMessagesRead(self: *Store, to_id: i32, from_id: i32) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE direct_messages SET read=1 WHERE to_id=?1 AND from_id=?2 AND read=0", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, to_id);
    _ = c.sqlite3_bind_int(stmt, 2, from_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn markDirectMessageRead(self: *Store, to_id: i32, message_id: i64) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE direct_messages SET read=1 WHERE id=?1 AND to_id=?2 AND read=0", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, message_id);
    _ = c.sqlite3_bind_int(stmt, 2, to_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return c.sqlite3_changes(self.db) != 0;
}

pub fn recordPublicMessage(self: *Store, sender_id: i32, target: []const u8, message: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO chat_messages(sender_id,target,message) VALUES(?1,?2,?3)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, sender_id);
    _ = c.sqlite3_bind_text(stmt, 2, target.ptr, @intCast(target.len), null);
    _ = c.sqlite3_bind_text(stmt, 3, message.ptr, @intCast(message.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn recordStaffAnnouncement(self: *Store, actor_id: i32, message: []const u8, reason: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var chat: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO chat_messages(sender_id,target,message) VALUES(3,'#announce',?1)", -1, &chat, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(chat);
    _ = c.sqlite3_bind_text(chat, 1, message.ptr, @intCast(message.len), null);
    if (c.sqlite3_step(chat) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    var audit: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO audit_log(actor_id,action,target,detail) VALUES(?1,'infra.announcement','server',?2)", -1, &audit, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(audit);
    _ = c.sqlite3_bind_int(audit, 1, actor_id);
    _ = c.sqlite3_bind_text(audit, 2, reason.ptr, @intCast(reason.len), null);
    if (c.sqlite3_step(audit) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    try self.exec("COMMIT");
}
