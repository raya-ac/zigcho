const std = @import("std");
const domain = @import("../../../domain.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const jsonString = @import("../beatmaps/lazer_listing.zig").jsonString;

pub fn teamsJson(self: *Store, allocator: std.mem.Allocator, requester_id: ?i32) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT t.id,t.name,t.short_name,t.description,t.is_open,t.default_ruleset_id,t.leader_id,t.created_at,t.updated_at,(SELECT count(*) FROM team_members m WHERE m.team_id=t.id),coalesce((SELECT updated_at FROM team_assets a WHERE a.team_id=t.id AND a.kind='flag'),0),EXISTS(SELECT 1 FROM team_members m WHERE m.team_id=t.id AND m.user_id=?1),EXISTS(SELECT 1 FROM team_applications a WHERE a.team_id=t.id AND a.user_id=?1) FROM teams t ORDER BY (SELECT count(*) FROM team_members m WHERE m.team_id=t.id) DESC,lower(t.name),t.id";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (requester_id) |id| _ = c.sqlite3_bind_int(stmt, 1, id) else _ = c.sqlite3_bind_null(stmt, 1);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var first = true;
    while (true) switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => {
            if (!first) try output.writer.writeByte(',');
            first = false;
            const id = c.sqlite3_column_int(stmt, 0);
            const flag_version = c.sqlite3_column_int64(stmt, 10);
            try output.writer.print("{{\"id\":{d},\"name\":", .{id});
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 1)));
            try output.writer.writeAll(",\"short_name\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 2)));
            try output.writer.writeAll(",\"description\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 3)));
            try output.writer.print(",\"is_open\":{},\"default_ruleset_id\":{d},\"leader_id\":{d},\"created_at\":{d},\"updated_at\":{d},\"member_count\":{d},\"flag_url\":", .{ c.sqlite3_column_int(stmt, 4) != 0, c.sqlite3_column_int(stmt, 5), c.sqlite3_column_int(stmt, 6), c.sqlite3_column_int64(stmt, 7), c.sqlite3_column_int64(stmt, 8), c.sqlite3_column_int(stmt, 9) });
            if (flag_version > 0) try output.writer.print("\"https://assets.kai.ovh/teams/{d}/flag?v={d}\"", .{ id, flag_version }) else try output.writer.writeAll("null");
            try output.writer.print(",\"member\":{},\"applied\":{}}}", .{ c.sqlite3_column_int(stmt, 11) != 0, c.sqlite3_column_int(stmt, 12) != 0 });
        },
        c.SQLITE_DONE => break,
        else => return error.DatabaseQueryFailed,
    };
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn teamJson(self: *Store, allocator: std.mem.Allocator, team_id: i32, requester_id: ?i32, staff: bool) !?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var team: ?*c.sqlite3_stmt = null;
    const sql = "SELECT t.id,t.name,t.short_name,t.url,t.description,t.is_open,t.default_ruleset_id,t.leader_id,t.created_at,t.updated_at,coalesce((SELECT updated_at FROM team_assets a WHERE a.team_id=t.id AND a.kind='flag'),0),coalesce((SELECT updated_at FROM team_assets a WHERE a.team_id=t.id AND a.kind='header'),0),EXISTS(SELECT 1 FROM team_members m WHERE m.team_id=t.id AND m.user_id=?2),EXISTS(SELECT 1 FROM team_applications a WHERE a.team_id=t.id AND a.user_id=?2) FROM teams t WHERE t.id=?1";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &team, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(team);
    _ = c.sqlite3_bind_int(team, 1, team_id);
    if (requester_id) |id| _ = c.sqlite3_bind_int(team, 2, id) else _ = c.sqlite3_bind_null(team, 2);
    if (c.sqlite3_step(team) != c.SQLITE_ROW) return null;
    const leader_id = c.sqlite3_column_int(team, 7);
    const can_manage = staff or (requester_id != null and requester_id.? == leader_id);
    var members: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT u.id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,u.privileges,m.joined_at FROM team_members m JOIN users u ON u.id=m.user_id WHERE m.team_id=?1 ORDER BY CASE WHEN u.id=(SELECT leader_id FROM teams WHERE id=?1) THEN 0 ELSE 1 END,m.joined_at,u.id", -1, &members, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(members);
    _ = c.sqlite3_bind_int(members, 1, team_id);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"id\":{d},\"name\":", .{team_id});
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(team, 1)));
    try output.writer.writeAll(",\"short_name\":");
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(team, 2)));
    try output.writer.writeAll(",\"url\":");
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(team, 3)));
    try output.writer.writeAll(",\"description\":");
    try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(team, 4)));
    const flag_version = c.sqlite3_column_int64(team, 10);
    const header_version = c.sqlite3_column_int64(team, 11);
    try output.writer.print(",\"is_open\":{},\"default_ruleset_id\":{d},\"leader_id\":{d},\"created_at\":{d},\"updated_at\":{d},\"flag_url\":", .{ c.sqlite3_column_int(team, 5) != 0, c.sqlite3_column_int(team, 6), leader_id, c.sqlite3_column_int64(team, 8), c.sqlite3_column_int64(team, 9) });
    if (flag_version > 0) try output.writer.print("\"https://assets.kai.ovh/teams/{d}/flag?v={d}\"", .{ team_id, flag_version }) else try output.writer.writeAll("null");
    try output.writer.writeAll(",\"header_url\":");
    if (header_version > 0) try output.writer.print("\"https://assets.kai.ovh/teams/{d}/header?v={d}\"", .{ team_id, header_version }) else try output.writer.writeAll("null");
    try output.writer.print(",\"member\":{},\"applied\":{},\"can_manage\":{},\"members\":[", .{ c.sqlite3_column_int(team, 12) != 0, c.sqlite3_column_int(team, 13) != 0, can_manage });
    first: {
        var first = true;
        while (true) switch (c.sqlite3_step(members)) {
            c.SQLITE_ROW => {
                if (!first) try output.writer.writeByte(',');
                first = false;
                try output.writer.print("{{\"id\":{d},\"name\":", .{c.sqlite3_column_int(members, 0)});
                try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(members, 1)));
                try output.writer.writeAll(",\"country\":");
                try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(members, 2)));
                try output.writer.print(",\"privileges\":{d},\"joined_at\":{d},\"leader\":{}}}", .{ c.sqlite3_column_int64(members, 3), c.sqlite3_column_int64(members, 4), c.sqlite3_column_int(members, 0) == leader_id });
            },
            c.SQLITE_DONE => break :first,
            else => return error.DatabaseQueryFailed,
        };
    }
    try output.writer.writeAll("],\"applications\":[");
    if (can_manage) {
        var applications: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT u.id,u.name,u.country,a.created_at FROM team_applications a JOIN users u ON u.id=a.user_id WHERE a.team_id=?1 ORDER BY a.created_at,u.id", -1, &applications, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(applications);
        _ = c.sqlite3_bind_int(applications, 1, team_id);
        var first = true;
        while (true) switch (c.sqlite3_step(applications)) {
            c.SQLITE_ROW => {
                if (!first) try output.writer.writeByte(',');
                first = false;
                try output.writer.print("{{\"id\":{d},\"name\":", .{c.sqlite3_column_int(applications, 0)});
                try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(applications, 1)));
                try output.writer.writeAll(",\"country\":");
                try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(applications, 2)));
                try output.writer.print(",\"created_at\":{d}}}", .{c.sqlite3_column_int64(applications, 3)});
            },
            c.SQLITE_DONE => break,
            else => return error.DatabaseQueryFailed,
        };
    }
    try output.writer.writeAll("]}");
    return @as(?[]u8, try output.toOwnedSlice());
}

pub fn createTeam(self: *Store, user_id: i32, settings: domain.TeamSettings) !i32 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var insert: ?*c.sqlite3_stmt = null;
    const sql = "INSERT INTO teams(name,short_name,url,description,is_open,default_ruleset_id,leader_id) SELECT ?1,?2,?3,?4,?5,?6,?7 WHERE NOT EXISTS(SELECT 1 FROM team_members WHERE user_id=?7)";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &insert, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(insert);
    _ = c.sqlite3_bind_text(insert, 1, settings.name.ptr, @intCast(settings.name.len), null);
    _ = c.sqlite3_bind_text(insert, 2, settings.short_name.ptr, @intCast(settings.short_name.len), null);
    _ = c.sqlite3_bind_text(insert, 3, settings.url.ptr, @intCast(settings.url.len), null);
    _ = c.sqlite3_bind_text(insert, 4, settings.description.ptr, @intCast(settings.description.len), null);
    _ = c.sqlite3_bind_int(insert, 5, @intFromBool(settings.is_open));
    _ = c.sqlite3_bind_int(insert, 6, settings.default_ruleset_id);
    _ = c.sqlite3_bind_int(insert, 7, user_id);
    if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.TeamExists;
    if (c.sqlite3_changes(self.db) != 1) return error.AlreadyInTeam;
    const team_id: i32 = @intCast(c.sqlite3_last_insert_rowid(self.db));
    var member: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO team_members(user_id,team_id) VALUES(?1,?2)", -1, &member, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(member);
    _ = c.sqlite3_bind_int(member, 1, user_id);
    _ = c.sqlite3_bind_int(member, 2, team_id);
    if (c.sqlite3_step(member) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    var clear: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "DELETE FROM team_applications WHERE user_id=?1", -1, &clear, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(clear);
    _ = c.sqlite3_bind_int(clear, 1, user_id);
    if (c.sqlite3_step(clear) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    try self.insertAuditLocked(user_id, "team.create", user_id, "team created");
    try self.exec("COMMIT");
    return team_id;
}

pub fn updateTeam(self: *Store, actor_id: i32, team_id: i32, settings: domain.TeamSettings, staff: bool) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE teams SET name=?1,short_name=?2,url=?3,description=?4,is_open=?5,default_ruleset_id=?6,updated_at=max(unixepoch(),updated_at+1) WHERE id=?7 AND (leader_id=?8 OR ?9=1)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, settings.name.ptr, @intCast(settings.name.len), null);
    _ = c.sqlite3_bind_text(stmt, 2, settings.short_name.ptr, @intCast(settings.short_name.len), null);
    _ = c.sqlite3_bind_text(stmt, 3, settings.url.ptr, @intCast(settings.url.len), null);
    _ = c.sqlite3_bind_text(stmt, 4, settings.description.ptr, @intCast(settings.description.len), null);
    _ = c.sqlite3_bind_int(stmt, 5, @intFromBool(settings.is_open));
    _ = c.sqlite3_bind_int(stmt, 6, settings.default_ruleset_id);
    _ = c.sqlite3_bind_int(stmt, 7, team_id);
    _ = c.sqlite3_bind_int(stmt, 8, actor_id);
    _ = c.sqlite3_bind_int(stmt, 9, @intFromBool(staff));
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.TeamExists;
    if (c.sqlite3_changes(self.db) != 1) return error.TeamPermissionDenied;
}

pub fn joinOrApplyTeam(self: *Store, user_id: i32, team_id: i32) !domain.TeamJoinResult {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var team: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT is_open FROM teams WHERE id=?1", -1, &team, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(team);
    _ = c.sqlite3_bind_int(team, 1, team_id);
    if (c.sqlite3_step(team) != c.SQLITE_ROW) return error.TeamNotFound;
    const team_open = c.sqlite3_column_int(team, 0) != 0;
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = if (team_open) "INSERT INTO team_members(user_id,team_id) VALUES(?1,?2)" else "INSERT INTO team_applications(user_id,team_id) VALUES(?1,?2)";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, team_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return if (team_open) error.AlreadyInTeam else error.AlreadyApplied;
    if (team_open) {
        var clear: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM team_applications WHERE user_id=?1", -1, &clear, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(clear);
        _ = c.sqlite3_bind_int(clear, 1, user_id);
        if (c.sqlite3_step(clear) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }
    try self.exec("COMMIT");
    return if (team_open) .joined else .applied;
}

pub fn leaveTeam(self: *Store, user_id: i32, team_id: i32) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "DELETE FROM team_members WHERE user_id=?1 AND team_id=?2 AND user_id!=(SELECT leader_id FROM teams WHERE id=?2)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, team_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    if (c.sqlite3_changes(self.db) != 1) return error.TeamLeaderCannotLeave;
}

pub fn teamMemberAction(self: *Store, actor_id: i32, team_id: i32, target_id: i32, action: []const u8, staff: bool) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var auth: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT leader_id FROM teams WHERE id=?1 AND (leader_id=?2 OR ?3=1)", -1, &auth, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(auth);
    _ = c.sqlite3_bind_int(auth, 1, team_id);
    _ = c.sqlite3_bind_int(auth, 2, actor_id);
    _ = c.sqlite3_bind_int(auth, 3, @intFromBool(staff));
    if (c.sqlite3_step(auth) != c.SQLITE_ROW) return error.TeamPermissionDenied;
    const leader_id = c.sqlite3_column_int(auth, 0);
    if (std.mem.eql(u8, action, "approve")) {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT INTO team_members(user_id,team_id) SELECT user_id,team_id FROM team_applications WHERE user_id=?1 AND team_id=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, target_id);
        _ = c.sqlite3_bind_int(stmt, 2, team_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.TeamApplicationNotFound;
        var clear: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM team_applications WHERE user_id=?1", -1, &clear, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(clear);
        _ = c.sqlite3_bind_int(clear, 1, target_id);
        if (c.sqlite3_step(clear) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    } else if (std.mem.eql(u8, action, "reject")) {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM team_applications WHERE user_id=?1 AND team_id=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, target_id);
        _ = c.sqlite3_bind_int(stmt, 2, team_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.TeamApplicationNotFound;
    } else if (std.mem.eql(u8, action, "remove")) {
        if (target_id == leader_id) return error.TeamLeaderCannotLeave;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM team_members WHERE user_id=?1 AND team_id=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, target_id);
        _ = c.sqlite3_bind_int(stmt, 2, team_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.TeamMemberNotFound;
    } else if (std.mem.eql(u8, action, "transfer")) {
        if (!staff and actor_id != leader_id) return error.TeamPermissionDenied;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE teams SET leader_id=?1,updated_at=max(unixepoch(),updated_at+1) WHERE id=?2 AND EXISTS(SELECT 1 FROM team_members WHERE team_id=?2 AND user_id=?1)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, target_id);
        _ = c.sqlite3_bind_int(stmt, 2, team_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.TeamMemberNotFound;
    } else return error.InvalidTeamAction;
    try self.exec("COMMIT");
}

pub fn disbandTeam(self: *Store, actor_id: i32, team_id: i32, staff: bool) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "DELETE FROM teams WHERE id=?1 AND (leader_id=?2 OR ?3=1)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, team_id);
    _ = c.sqlite3_bind_int(stmt, 2, actor_id);
    _ = c.sqlite3_bind_int(stmt, 3, @intFromBool(staff));
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.TeamPermissionDenied;
}

pub fn teamCanManage(self: *Store, actor_id: i32, team_id: i32, staff: bool) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM teams WHERE id=?1 AND (leader_id=?2 OR ?3=1)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, team_id);
    _ = c.sqlite3_bind_int(stmt, 2, actor_id);
    _ = c.sqlite3_bind_int(stmt, 3, @intFromBool(staff));
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}
