const std = @import("std");
const domain = @import("../../../domain.zig");
const account_roles = @import("../../../account_roles.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const jsonString = @import("../beatmaps/lazer_listing.zig").jsonString;

pub fn staffOverviewJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT (SELECT count(*) FROM moderation_appeals WHERE status='open'),(SELECT count(DISTINCT set_id) FROM beatmap_rank_requests WHERE active=1),(SELECT count(*) FROM users WHERE restricted=1),(SELECT count(*) FROM users WHERE silence_end>unixepoch()),(SELECT count(*) FROM audit_log WHERE created_at>=unixepoch()-86400),(SELECT count(*) FROM client_hardware),(SELECT count(*) FROM anticheat_observations WHERE review_label='pending' AND review_exclusion_id IS NULL),(SELECT count(*) FROM lazer_reports WHERE status='open')";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return std.fmt.allocPrint(allocator, "{{\"open_appeals\":{d},\"ranking_sets\":{d},\"restricted_users\":{d},\"silenced_users\":{d},\"audit_24h\":{d},\"hardware_records\":{d},\"anticheat_pending\":{d},\"open_reports\":{d}}}", .{ c.sqlite3_column_int64(stmt, 0), c.sqlite3_column_int64(stmt, 1), c.sqlite3_column_int64(stmt, 2), c.sqlite3_column_int64(stmt, 3), c.sqlite3_column_int64(stmt, 4), c.sqlite3_column_int64(stmt, 5), c.sqlite3_column_int64(stmt, 6), c.sqlite3_column_int64(stmt, 7) });
}

pub fn staffUserSearchJson(self: *Store, allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    const safe = try domain.safeName(allocator, query);
    defer allocator.free(safe);
    const numeric_id = std.fmt.parseInt(i32, query, 10) catch 0;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT u.id,u.name,u.country,u.privileges,u.restricted,u.silence_end,coalesce(u.last_login,0),coalesce(t.short_name,'') FROM users u LEFT JOIN team_members tm ON tm.user_id=u.id LEFT JOIN teams t ON t.id=tm.team_id WHERE u.id=?1 OR instr(lower(u.name),lower(?2))>0 OR instr(u.safe_name,?3)>0 ORDER BY CASE WHEN u.id=?1 THEN 0 WHEN u.safe_name=?3 THEN 1 WHEN lower(u.name)=lower(?2) THEN 2 WHEN instr(u.safe_name,?3)=1 THEN 3 ELSE 4 END,u.restricted,u.id LIMIT 20";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, numeric_id);
    _ = c.sqlite3_bind_text(stmt, 2, query.ptr, @intCast(query.len), null);
    _ = c.sqlite3_bind_text(stmt, 3, safe.ptr, @intCast(safe.len), null);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var first = true;
    while (true) switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => {
            if (!first) try output.writer.writeByte(',');
            first = false;
            try output.writer.print("{{\"id\":{d},\"name\":", .{c.sqlite3_column_int(stmt, 0)});
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 1)));
            try output.writer.writeAll(",\"country\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 2)));
            try output.writer.print(",\"privileges\":{d},\"restricted\":{},\"silence_end\":{d},\"last_login\":{d},\"team\":", .{ c.sqlite3_column_int64(stmt, 3), c.sqlite3_column_int(stmt, 4) != 0, c.sqlite3_column_int64(stmt, 5), c.sqlite3_column_int64(stmt, 6) });
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 7)));
            try output.writer.writeByte('}');
        },
        c.SQLITE_DONE => break,
        else => return error.DatabaseQueryFailed,
    };
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn staffRolesJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var user: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT id,name,country,privileges,restricted,created_at,coalesce(last_login,0) FROM users WHERE id=?1 AND id!=3", -1, &user, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(user);
    _ = c.sqlite3_bind_int(user, 1, user_id);
    if (c.sqlite3_step(user) != c.SQLITE_ROW) return null;
    const privileges: u32 = @intCast(c.sqlite3_column_int64(user, 3));
    var audit: ?*c.sqlite3_stmt = null;
    var target_buf: [24]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{user_id});
    if (c.sqlite3_prepare_v2(self.db, "SELECT a.id,coalesce(actor.name,'system'),coalesce(a.detail,''),a.created_at FROM audit_log a LEFT JOIN users actor ON actor.id=a.actor_id WHERE a.target=?1 AND a.action='account.role' ORDER BY a.id DESC LIMIT 100", -1, &audit, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(audit);
    _ = c.sqlite3_bind_text(audit, 1, target.ptr, @intCast(target.len), null);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"user\":{{\"id\":{d},\"name\":", .{c.sqlite3_column_int(user, 0)});
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 1)));
    try output.writer.writeAll(",\"country\":");
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 2)));
    try output.writer.print(",\"privileges\":{d},\"restricted\":{},\"created_at\":{d},\"last_login\":{d}}},\"roles\":", .{ privileges, c.sqlite3_column_int(user, 4) != 0, c.sqlite3_column_int64(user, 5), c.sqlite3_column_int64(user, 6) });
    try account_roles.writeCatalogJson(&output.writer, privileges);
    try output.writer.writeAll(",\"audit\":[");
    var first = true;
    while (c.sqlite3_step(audit) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.print("{{\"id\":{d},\"actor\":", .{c.sqlite3_column_int64(audit, 0)});
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(audit, 1)));
        try output.writer.writeAll(",\"detail\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(audit, 2)));
        try output.writer.print(",\"created_at\":{d}}}", .{c.sqlite3_column_int64(audit, 3)});
    }
    try output.writer.writeAll("]}");
    const owned = try output.toOwnedSlice();
    return owned;
}

pub fn lazerUserSearchIds(self: *Store, allocator: std.mem.Allocator, query: []const u8, limit: u8) ![]i32 {
    const safe = try domain.safeName(allocator, query);
    defer allocator.free(safe);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT id FROM users WHERE restricted=0 AND id!=3 AND (instr(lower(name),lower(?1))>0 OR instr(safe_name,?2)>0) ORDER BY CASE WHEN safe_name=?2 THEN 0 WHEN lower(name)=lower(?1) THEN 1 WHEN instr(safe_name,?2)=1 THEN 2 ELSE 3 END,id LIMIT ?3", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, query.ptr, @intCast(query.len), null);
    _ = c.sqlite3_bind_text(stmt, 2, safe.ptr, @intCast(safe.len), null);
    _ = c.sqlite3_bind_int(stmt, 3, limit);
    var result: std.ArrayList(i32) = .empty;
    errdefer result.deinit(allocator);
    while (true) switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => try result.append(allocator, c.sqlite3_column_int(stmt, 0)),
        c.SQLITE_DONE => break,
        else => return error.DatabaseQueryFailed,
    };
    return result.toOwnedSlice(allocator);
}

pub fn staffRankingJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var queue: ?*c.sqlite3_stmt = null;
    const queue_sql = "SELECT r.set_id,min(b.status),count(*),(SELECT count(*) FROM beatmap_nominations n WHERE n.set_id=r.set_id AND n.active=1),min(b.artist),min(b.title),min(b.creator),min(b.md5),min(r.created_at) FROM beatmap_rank_requests r JOIN beatmaps b ON b.set_id=r.set_id WHERE r.active=1 GROUP BY r.set_id ORDER BY min(r.created_at),r.set_id LIMIT 100";
    if (c.sqlite3_prepare_v2(self.db, queue_sql, -1, &queue, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(queue);
    var history: ?*c.sqlite3_stmt = null;
    const history_sql = "SELECT e.id,e.set_id,e.action,e.from_status,e.to_status,e.reason,e.created_at,u.name FROM beatmap_rank_events e JOIN users u ON u.id=e.actor_id ORDER BY e.id DESC LIMIT 100";
    if (c.sqlite3_prepare_v2(self.db, history_sql, -1, &history, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(history);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"queue\":[");
    var first = true;
    while (c.sqlite3_step(queue) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.print("{{\"set_id\":{d},\"status\":{d},\"requests\":{d},\"nominations\":{d},\"artist\":", .{ c.sqlite3_column_int(queue, 0), c.sqlite3_column_int(queue, 1), c.sqlite3_column_int(queue, 2), c.sqlite3_column_int(queue, 3) });
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(queue, 4)));
        try output.writer.writeAll(",\"title\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(queue, 5)));
        try output.writer.writeAll(",\"creator\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(queue, 6)));
        try output.writer.writeAll(",\"map_md5\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(queue, 7)));
        try output.writer.print(",\"created_at\":{d}}}", .{c.sqlite3_column_int64(queue, 8)});
    }
    try output.writer.writeAll("],\"history\":[");
    first = true;
    while (c.sqlite3_step(history) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.print("{{\"id\":{d},\"set_id\":{d},\"action\":", .{ c.sqlite3_column_int64(history, 0), c.sqlite3_column_int(history, 1) });
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(history, 2)));
        try output.writer.print(",\"from_status\":{d},\"to_status\":{d},\"reason\":", .{ c.sqlite3_column_int(history, 3), c.sqlite3_column_int(history, 4) });
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(history, 5)));
        try output.writer.print(",\"created_at\":{d},\"actor\":", .{c.sqlite3_column_int64(history, 6)});
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(history, 7)));
        try output.writer.writeByte('}');
    }
    try output.writer.writeAll("]}");
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

pub fn staffAppealsJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT a.id,a.user_id,u.name,u.country,a.kind,a.message,a.status,coalesce(r.name,''),coalesce(a.resolution,''),a.created_at,coalesce(a.resolved_at,0) FROM moderation_appeals a JOIN users u ON u.id=a.user_id LEFT JOIN users r ON r.id=a.reviewer_id ORDER BY CASE a.status WHEN 'open' THEN 0 ELSE 1 END,a.created_at,a.id LIMIT 200";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"appeals\":[");
    var first = true;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.print("{{\"id\":{d},\"user_id\":{d},\"user\":", .{ c.sqlite3_column_int64(stmt, 0), c.sqlite3_column_int(stmt, 1) });
        for (2..9) |column| {
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, @intCast(column))));
            const names = [_][]const u8{ "country", "kind", "message", "status", "reviewer", "resolution" };
            if (column < 8) try output.writer.print(",\"{s}\":", .{names[column - 2]});
        }
        try output.writer.print(",\"created_at\":{d},\"resolved_at\":{d}}}", .{ c.sqlite3_column_int64(stmt, 9), c.sqlite3_column_int64(stmt, 10) });
    }
    try output.writer.writeAll("]}");
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

pub fn staffUserJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var user: ?*c.sqlite3_stmt = null;
    const user_sql = "SELECT id,name,country,privileges,silence_end,restricted,created_at,coalesce(last_login,0),(SELECT count(DISTINCT h2.user_id) FROM client_hardware h1 JOIN client_hardware h2 ON h2.user_id!=h1.user_id AND h2.adapters_md5=h1.adapters_md5 AND h2.uninstall_md5=h1.uninstall_md5 AND h2.disk_signature_md5=h1.disk_signature_md5 WHERE h1.user_id=u.id) FROM users u WHERE id=?1 AND id!=3";
    if (c.sqlite3_prepare_v2(self.db, user_sql, -1, &user, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(user);
    _ = c.sqlite3_bind_int(user, 1, user_id);
    if (c.sqlite3_step(user) != c.SQLITE_ROW) return null;
    var hardware: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT substr(adapters_md5,-8),substr(uninstall_md5,-8),substr(disk_signature_md5,-8),client_version,running_under_wine,first_seen,last_seen,occurrences FROM client_hardware WHERE user_id=?1 ORDER BY last_seen DESC LIMIT 50", -1, &hardware, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(hardware);
    _ = c.sqlite3_bind_int(hardware, 1, user_id);
    var audit: ?*c.sqlite3_stmt = null;
    var target_buf: [24]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{user_id});
    if (c.sqlite3_prepare_v2(self.db, "SELECT a.id,coalesce(actor.name,'system'),a.action,coalesce(a.detail,''),a.created_at FROM audit_log a LEFT JOIN users actor ON actor.id=a.actor_id WHERE a.target=?1 ORDER BY a.id DESC LIMIT 100", -1, &audit, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(audit);
    _ = c.sqlite3_bind_text(audit, 1, target.ptr, @intCast(target.len), null);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"user\":{{\"id\":{d},\"name\":", .{c.sqlite3_column_int(user, 0)});
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 1)));
    try output.writer.writeAll(",\"country\":");
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 2)));
    try output.writer.print(",\"privileges\":{d},\"silence_end\":{d},\"restricted\":{},\"created_at\":{d},\"last_login\":{d},\"exact_hardware_matches\":{d}}},\"hardware\":[", .{ c.sqlite3_column_int64(user, 3), c.sqlite3_column_int64(user, 4), c.sqlite3_column_int(user, 5) != 0, c.sqlite3_column_int64(user, 6), c.sqlite3_column_int64(user, 7), c.sqlite3_column_int64(user, 8) });
    var first = true;
    while (c.sqlite3_step(hardware) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.writeAll("{\"adapter\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(hardware, 0)));
        try output.writer.writeAll(",\"uninstall\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(hardware, 1)));
        try output.writer.writeAll(",\"disk\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(hardware, 2)));
        try output.writer.writeAll(",\"client\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(hardware, 3)));
        try output.writer.print(",\"wine\":{},\"first_seen\":{d},\"last_seen\":{d},\"occurrences\":{d}}}", .{ c.sqlite3_column_int(hardware, 4) != 0, c.sqlite3_column_int64(hardware, 5), c.sqlite3_column_int64(hardware, 6), c.sqlite3_column_int(hardware, 7) });
    }
    try output.writer.writeAll("],\"audit\":[");
    first = true;
    while (c.sqlite3_step(audit) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.print("{{\"id\":{d},\"actor\":", .{c.sqlite3_column_int64(audit, 0)});
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(audit, 1)));
        try output.writer.writeAll(",\"action\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(audit, 2)));
        try output.writer.writeAll(",\"detail\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(audit, 3)));
        try output.writer.print(",\"created_at\":{d}}}", .{c.sqlite3_column_int64(audit, 4)});
    }
    try output.writer.writeAll("]}");
    var list = output.toArrayList();
    return try list.toOwnedSlice(allocator);
}

pub fn staffAuditJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT a.id,coalesce(u.name,'system'),a.action,coalesce(a.target,''),coalesce(a.detail,''),a.created_at FROM audit_log a LEFT JOIN users u ON u.id=a.actor_id ORDER BY a.id DESC LIMIT 250", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"events\":[");
    var first = true;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.print("{{\"id\":{d},\"actor\":", .{c.sqlite3_column_int64(stmt, 0)});
        for (1..5) |column| {
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, @intCast(column))));
            const names = [_][]const u8{ "action", "target", "detail" };
            if (column < 4) try output.writer.print(",\"{s}\":", .{names[column - 1]});
        }
        try output.writer.print(",\"created_at\":{d}}}", .{c.sqlite3_column_int64(stmt, 5)});
    }
    try output.writer.writeAll("]}");
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

pub fn staffChannelsJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT name,topic,write_privileges,locked,updated_at FROM chat_channels ORDER BY name", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"channels\":[");
    var first = true;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.writeAll("{\"name\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 0)));
        try output.writer.writeAll(",\"topic\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 1)));
        try output.writer.print(",\"write_privileges\":{d},\"locked\":{},\"updated_at\":{d}}}", .{ c.sqlite3_column_int64(stmt, 2), c.sqlite3_column_int(stmt, 3) != 0, c.sqlite3_column_int64(stmt, 4) });
    }
    try output.writer.writeAll("]}");
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}
