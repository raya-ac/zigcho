const std = @import("std");
const server_control = @import("../../../server_control.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const jsonString = @import("../beatmaps/lazer_listing.zig").jsonString;

pub fn serverControlEnabled(self: *Store, feature: server_control.Feature) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT enabled FROM server_controls WHERE key=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    const key = feature.key();
    _ = c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), null);
    return switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => c.sqlite3_column_int(stmt, 0) != 0,
        c.SQLITE_DONE => true,
        else => error.DatabaseQueryFailed,
    };
}

pub fn staffServerControlsJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT c.enabled,c.reason,c.updated_at,coalesce(u.name,'system') FROM server_controls c LEFT JOIN users u ON u.id=c.updated_by WHERE c.key=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"schema\":45,\"controls\":[");
    for (server_control.definitions, 0..) |definition, index| {
        if (index != 0) try output.writer.writeByte(',');
        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);
        const key = definition.feature.key();
        _ = c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), null);
        const step = c.sqlite3_step(stmt);
        if (step != c.SQLITE_ROW and step != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        try output.writer.writeAll("{\"key\":");
        try jsonString(&output.writer, key);
        try output.writer.writeAll(",\"label\":");
        try jsonString(&output.writer, definition.label);
        try output.writer.writeAll(",\"group\":");
        try jsonString(&output.writer, definition.group);
        try output.writer.writeAll(",\"description\":");
        try jsonString(&output.writer, definition.description);
        if (step == c.SQLITE_ROW) {
            try output.writer.print(",\"enabled\":{},\"reason\":", .{c.sqlite3_column_int(stmt, 0) != 0});
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 1)));
            try output.writer.print(",\"updated_at\":{d},\"updated_by\":", .{c.sqlite3_column_int64(stmt, 2)});
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 3)));
        } else {
            try output.writer.writeAll(",\"enabled\":true,\"reason\":\"\",\"updated_at\":0,\"updated_by\":\"system\"");
        }
        try output.writer.writeByte('}');
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

pub fn setServerControl(self: *Store, actor_id: i32, feature: server_control.Feature, enabled: bool, reason: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var update: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO server_controls(key,enabled,reason,updated_by,updated_at) VALUES(?1,?2,?3,?4,unixepoch()) ON CONFLICT(key) DO UPDATE SET enabled=excluded.enabled,reason=excluded.reason,updated_by=excluded.updated_by,updated_at=excluded.updated_at", -1, &update, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(update);
    const key = feature.key();
    _ = c.sqlite3_bind_text(update, 1, key.ptr, @intCast(key.len), null);
    _ = c.sqlite3_bind_int(update, 2, if (enabled) 1 else 0);
    _ = c.sqlite3_bind_text(update, 3, reason.ptr, @intCast(reason.len), null);
    _ = c.sqlite3_bind_int(update, 4, actor_id);
    if (c.sqlite3_step(update) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    var target_buf: [80]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "feature:{s}", .{key});
    var detail_buf: [560]u8 = undefined;
    const detail = try std.fmt.bufPrint(&detail_buf, "state={s} reason={s}", .{ if (enabled) "enabled" else "disabled", reason });
    var audit: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO audit_log(actor_id,action,target,detail) VALUES(?1,'infra.feature',?2,?3)", -1, &audit, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(audit);
    _ = c.sqlite3_bind_int(audit, 1, actor_id);
    _ = c.sqlite3_bind_text(audit, 2, target.ptr, @intCast(target.len), null);
    _ = c.sqlite3_bind_text(audit, 3, detail.ptr, @intCast(detail.len), null);
    if (c.sqlite3_step(audit) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    try self.exec("COMMIT");
}
