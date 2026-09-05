const std = @import("std");
const account_roles = @import("../../../account_roles.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;

pub fn channelCanWrite(self: *Store, name: []const u8, privileges: u32) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT CASE WHEN locked!=0 THEN (?2 & 8192)=8192 ELSE (?2 & write_privileges)=write_privileges END FROM chat_channels WHERE name=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), null);
    _ = c.sqlite3_bind_int64(stmt, 2, privileges);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return true;
    return c.sqlite3_column_int(stmt, 0) != 0;
}

pub fn setChannelLocked(self: *Store, actor_id: i32, name: []const u8, locked: bool, reason: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE chat_channels SET locked=?1,updated_by=?2,updated_at=unixepoch() WHERE name=?3", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, @intFromBool(locked));
    _ = c.sqlite3_bind_int(stmt, 2, actor_id);
    _ = c.sqlite3_bind_text(stmt, 3, name.ptr, @intCast(name.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE or c.sqlite3_changes(self.db) == 0) return error.InvalidChannel;
    var audit_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO audit_log(actor_id,action,target,detail) VALUES(?1,?2,?3,?4)", -1, &audit_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(audit_stmt);
    _ = c.sqlite3_bind_int(audit_stmt, 1, actor_id);
    const action = if (locked) "channel.lock" else "channel.unlock";
    _ = c.sqlite3_bind_text(audit_stmt, 2, action.ptr, @intCast(action.len), null);
    _ = c.sqlite3_bind_text(audit_stmt, 3, name.ptr, @intCast(name.len), null);
    _ = c.sqlite3_bind_text(audit_stmt, 4, reason.ptr, @intCast(reason.len), null);
    if (c.sqlite3_step(audit_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    try self.exec("COMMIT");
}

pub fn setSilence(self: *Store, actor_id: i32, target_id: i32, silence_end: i64, action: []const u8, reason: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE users SET silence_end=?1 WHERE id=?2 AND id!=3", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, silence_end);
    _ = c.sqlite3_bind_int(stmt, 2, target_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE or c.sqlite3_changes(self.db) == 0) return error.InvalidModerationTarget;
    try self.insertAuditLocked(actor_id, action, target_id, reason);
    try self.exec("COMMIT");
}

pub fn setRestricted(self: *Store, actor_id: i32, target_id: i32, restricted: bool, reason: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE users SET restricted=?1 WHERE id=?2 AND id!=3", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, @intFromBool(restricted));
    _ = c.sqlite3_bind_int(stmt, 2, target_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE or c.sqlite3_changes(self.db) == 0) return error.InvalidModerationTarget;
    try self.insertAuditLocked(actor_id, if (restricted) "account.restrict" else "account.unrestrict", target_id, reason);
    if (restricted) {
        var revoke: ?*c.sqlite3_stmt = null;
        const revoke_sql = "UPDATE oauth_tokens SET revoked_at=unixepoch() WHERE user_id=?1 AND revoked_at IS NULL AND expires_at>unixepoch() AND ((instr(' '||scopes||' ',' identify ')>0 AND instr(' '||scopes||' ',' scores:write ')>0) OR instr(' '||scopes||' ',' game:refresh ')>0)";
        if (c.sqlite3_prepare_v2(self.db, revoke_sql, -1, &revoke, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(revoke);
        _ = c.sqlite3_bind_int(revoke, 1, target_id);
        if (c.sqlite3_step(revoke) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        var clear: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM lazer_presence WHERE user_id=?1", -1, &clear, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(clear);
        _ = c.sqlite3_bind_int(clear, 1, target_id);
        if (c.sqlite3_step(clear) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }
    try self.recordAllStatsHistoryCurrentLocked();
    try self.exec("COMMIT");
}

pub fn changePrivileges(self: *Store, actor_id: i32, target_id: i32, bits: u32, add: bool) !u32 {
    const role = account_roles.Role.fromBit(bits) orelse return error.InvalidRoleChange;
    return (try self.changeRole(actor_id, target_id, role, add, "legacy typed role command")).privileges;
}

pub fn changeRole(self: *Store, actor_id: i32, target_id: i32, role: account_roles.Role, grant: bool, reason: []const u8) !account_roles.ChangeResult {
    if (actor_id <= 0 or target_id <= 0 or !account_roles.validReason(reason)) return error.InvalidRoleChange;
    const definition = role.definition();
    const trimmed_reason = std.mem.trim(u8, reason, " \t\r\n");
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = if (grant)
        "UPDATE users SET privileges=privileges | ?1 WHERE id=?2 AND id!=3 AND (privileges & ?1)=0 RETURNING privileges"
    else
        "UPDATE users SET privileges=privileges & ~?1 WHERE id=?2 AND id!=3 AND (privileges & ?1)!=0 RETURNING privileges";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, definition.bit);
    _ = c.sqlite3_bind_int(stmt, 2, target_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.RoleStateUnchanged;
    const privileges: u32 = @intCast(c.sqlite3_column_int64(stmt, 0));
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    var staff_sessions_revoked = false;
    if (!account_roles.isStaff(privileges)) {
        var revoke: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE oauth_tokens SET revoked_at=unixepoch() WHERE user_id=?1 AND scopes='web:staff' AND revoked_at IS NULL AND expires_at>unixepoch()", -1, &revoke, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(revoke);
        _ = c.sqlite3_bind_int(revoke, 1, target_id);
        if (c.sqlite3_step(revoke) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        staff_sessions_revoked = c.sqlite3_changes(self.db) != 0;
    }
    const detail = try std.fmt.allocPrint(self.allocator, "{s} role:{s} bit:{d} permanent:{} reason:{s}", .{ if (grant) "grant" else "revoke", @tagName(role), definition.bit, definition.permanent, trimmed_reason });
    defer self.allocator.free(detail);
    try self.insertAuditLocked(actor_id, "account.role", target_id, detail);
    try self.exec("COMMIT");
    return .{ .privileges = privileges, .staff_sessions_revoked = staff_sessions_revoked };
}

pub fn addModerationNote(self: *Store, actor_id: i32, target_id: i32, note: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.insertAuditLocked(actor_id, "account.note", target_id, note);
}

pub fn recordModerationAction(self: *Store, actor_id: i32, target_id: i32, action: []const u8, detail: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.insertAuditLocked(actor_id, action, target_id, detail);
}

pub fn recordAudit(self: *Store, actor_id: i32, action: []const u8, target: []const u8, detail: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO audit_log(actor_id,action,target,detail) VALUES(?1,?2,?3,?4)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, actor_id);
    _ = c.sqlite3_bind_text(stmt, 2, action.ptr, @intCast(action.len), null);
    _ = c.sqlite3_bind_text(stmt, 3, target.ptr, @intCast(target.len), null);
    _ = c.sqlite3_bind_text(stmt, 4, detail.ptr, @intCast(detail.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn moderationNotes(self: *Store, allocator: std.mem.Allocator, target_id: i32, limit: u8) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var target_buf: [24]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{target_id});
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT created_at,action,coalesce(actor_id,0),coalesce(detail,'') FROM audit_log WHERE target=?1 ORDER BY id DESC LIMIT ?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, target.ptr, @intCast(target.len), null);
    _ = c.sqlite3_bind_int(stmt, 2, limit);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (output.items.len != 0) try output.append(allocator, '\n');
        const line = try std.fmt.allocPrint(allocator, "{d} | {s} | by {d} | {s}", .{
            c.sqlite3_column_int64(stmt, 0),
            std.mem.span(c.sqlite3_column_text(stmt, 1)),
            c.sqlite3_column_int(stmt, 2),
            std.mem.span(c.sqlite3_column_text(stmt, 3)),
        });
        defer allocator.free(line);
        try output.appendSlice(allocator, line);
    }
    return output.toOwnedSlice(allocator);
}

pub fn createModerationAppeal(self: *Store, user_id: i32, kind: []const u8, message: []const u8) !i64 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO moderation_appeals(user_id,kind,message) VALUES(?1,?2,?3) RETURNING id", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_text(stmt, 2, kind.ptr, @intCast(kind.len), null);
    _ = c.sqlite3_bind_text(stmt, 3, message.ptr, @intCast(message.len), null);
    return switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => c.sqlite3_column_int64(stmt, 0),
        c.SQLITE_CONSTRAINT => error.AppealAlreadyOpen,
        else => error.DatabaseQueryFailed,
    };
}

pub fn resolveModerationAppeal(self: *Store, actor_id: i32, appeal_id: i64, status: []const u8, resolution: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    const target_id = block: {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE moderation_appeals SET status=?1,reviewer_id=?2,resolution=?3,resolved_at=unixepoch() WHERE id=?4 AND status='open' RETURNING user_id", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, status.ptr, @intCast(status.len), null);
        _ = c.sqlite3_bind_int(stmt, 2, actor_id);
        _ = c.sqlite3_bind_text(stmt, 3, resolution.ptr, @intCast(resolution.len), null);
        _ = c.sqlite3_bind_int64(stmt, 4, appeal_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.AppealNotOpen;
        break :block c.sqlite3_column_int(stmt, 0);
    };
    try self.insertAuditLocked(actor_id, if (std.mem.eql(u8, status, "accepted")) "appeal.accept" else "appeal.deny", target_id, resolution);
    try self.exec("COMMIT");
}

pub fn beatmapMd5ForSet(self: *Store, set_id: i32) !?[32]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT md5 FROM beatmaps WHERE set_id=?1 ORDER BY id LIMIT 1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, set_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const value = std.mem.span(c.sqlite3_column_text(stmt, 0));
    if (value.len != 32) return error.InvalidBeatmapHash;
    var out: [32]u8 = undefined;
    @memcpy(&out, value);
    return out;
}
