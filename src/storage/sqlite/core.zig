const std = @import("std");
const r2 = @import("../../r2.zig");
const c = @import("../../storage.zig").c;
const Store = @import("../../storage.zig").Store;

pub fn open(allocator: std.mem.Allocator, io: std.Io, path: [:0]const u8) !Store {
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(path.ptr, &db) != c.SQLITE_OK) return error.DatabaseOpenFailed;
    return .{ .db = db.?, .allocator = allocator, .io = io };
}

pub fn bindObjectStorage(self: *Store, object_store: r2.Storage) void {
    self.object_store = object_store;
}

pub fn close(self: *Store) void {
    _ = c.sqlite3_close(self.db);
}

pub fn exec(self: *Store, sql: [:0]const u8) !void {
    var err: [*c]u8 = null;
    if (c.sqlite3_exec(self.db, sql.ptr, null, null, &err) != c.SQLITE_OK) {
        if (err != null) {
            std.log.err("sqlite exec failed: {s}", .{std.mem.span(err)});
            c.sqlite3_free(err);
        }
        return error.DatabaseQueryFailed;
    }
}
