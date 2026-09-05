const std = @import("std");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const directListingStatus = @import("../../contracts.zig").directListingStatus;
const stableStatus = @import("../../contracts.zig").stableStatus;

pub fn writeDirectText(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |char| try writer.writeByte(switch (char) {
        '|' => 'I',
        '\r', '\n' => ' ',
        else => char,
    });
}

pub fn appendDirectSet(self: *Store, writer: *std.Io.Writer, set_id: i32) !bool {
    return appendDirectSetFields(self, writer, set_id, true);
}

fn appendDirectSetFields(self: *Store, writer: *std.Io.Writer, set_id: i32, include_difficulties: bool) !bool {
    const set_sql = "SELECT artist,title,creator,status,coalesce(datetime(last_update,'unixepoch'),'1970-01-01 00:00:00') FROM beatmaps WHERE set_id=?1 ORDER BY star_rating LIMIT 1";
    var set_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, set_sql, -1, &set_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(set_stmt);
    _ = c.sqlite3_bind_int(set_stmt, 1, set_id);
    if (c.sqlite3_step(set_stmt) != c.SQLITE_ROW) return false;
    try writer.print("{d}.osz|", .{set_id});
    try writeDirectText(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 0)));
    try writer.writeByte('|');
    try writeDirectText(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 1)));
    try writer.writeByte('|');
    try writeDirectText(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 2)));
    const status = c.sqlite3_column_int(set_stmt, 3);
    try writer.print("|{d}|10.0|{s}|{d}|0|0|0|0|0", .{ if (include_difficulties) directListingStatus(status) else stableStatus(status), std.mem.span(c.sqlite3_column_text(set_stmt, 4)), set_id });
    if (!include_difficulties) return true;
    try writer.writeByte('|');

    const maps_sql = "SELECT star_rating,version,cs,od,ar,hp,mode FROM beatmaps WHERE set_id=?1 ORDER BY star_rating,id";
    var maps_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, maps_sql, -1, &maps_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(maps_stmt);
    _ = c.sqlite3_bind_int(maps_stmt, 1, set_id);
    var first = true;
    while (c.sqlite3_step(maps_stmt) == c.SQLITE_ROW) {
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("[{d:.2}⭐] ", .{c.sqlite3_column_double(maps_stmt, 0)});
        try writeDirectText(writer, std.mem.span(c.sqlite3_column_text(maps_stmt, 1)));
        try writer.print(" {{cs: {d} / od: {d} / ar: {d} / hp: {d}}}@{d}", .{ c.sqlite3_column_double(maps_stmt, 2), c.sqlite3_column_double(maps_stmt, 3), c.sqlite3_column_double(maps_stmt, 4), c.sqlite3_column_double(maps_stmt, 5), c.sqlite3_column_int(maps_stmt, 6) });
    }
    return true;
}

pub fn stableSearch(self: *Store, allocator: std.mem.Allocator, query: []const u8, mode: i8, direct_status: u8, page: u16) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const sql = "SELECT set_id FROM beatmaps WHERE EXISTS(SELECT 1 FROM beatmap_archives a WHERE a.set_id=beatmaps.set_id) AND (?1=-1 OR mode=?1) AND (?2='' OR instr(lower(artist||' '||title||' '||creator||' '||source||' '||tags),lower(?2))>0) AND ((?3=4 AND status IN(3,4,5,6)) OR (?3 IN(0,7) AND status IN(3,4)) OR (?3 IN(2,5) AND status=2) OR (?3=3 AND status=5) OR (?3=8 AND status=6)) GROUP BY set_id ORDER BY max(last_update) DESC,set_id DESC LIMIT 100 OFFSET ?4";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, mode);
    _ = c.sqlite3_bind_text(stmt, 2, query.ptr, @intCast(query.len), null);
    _ = c.sqlite3_bind_int(stmt, 3, direct_status);
    _ = c.sqlite3_bind_int64(stmt, 4, @as(i64, page) * 100);
    var ids: [100]i32 = undefined;
    var count: usize = 0;
    while (count < ids.len and c.sqlite3_step(stmt) == c.SQLITE_ROW) : (count += 1) ids[count] = c.sqlite3_column_int(stmt, 0);
    try output.writer.print("{d}", .{if (count == 100) @as(usize, 101) else count});
    for (ids[0..count]) |set_id| {
        try output.writer.writeByte('\n');
        _ = try self.appendDirectSet(&output.writer, set_id);
    }
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

pub fn stableSearchSet(self: *Store, allocator: std.mem.Allocator, set_id: ?i32, map_id: ?i32, md5: ?[]const u8) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const find_sql = "SELECT set_id FROM beatmaps WHERE (?1 IS NOT NULL AND set_id=?1) OR (?2 IS NOT NULL AND id=?2) OR (?3 IS NOT NULL AND md5=?3) LIMIT 1";
    var find_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, find_sql, -1, &find_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(find_stmt);
    if (set_id) |value| _ = c.sqlite3_bind_int(find_stmt, 1, value) else _ = c.sqlite3_bind_null(find_stmt, 1);
    if (map_id) |value| _ = c.sqlite3_bind_int(find_stmt, 2, value) else _ = c.sqlite3_bind_null(find_stmt, 2);
    if (md5) |value| _ = c.sqlite3_bind_text(find_stmt, 3, value.ptr, @intCast(value.len), null) else _ = c.sqlite3_bind_null(find_stmt, 3);
    if (c.sqlite3_step(find_stmt) != c.SQLITE_ROW) return allocator.dupe(u8, "");
    const found_set_id = c.sqlite3_column_int(find_stmt, 0);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    _ = try appendDirectSetFields(self, &output.writer, found_set_id, false);
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}
