const std = @import("std");
const domain = @import("../../../domain.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;

pub fn friendIds(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]i32 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT relation.friend_id FROM friends relation JOIN users sender ON sender.id=relation.user_id JOIN users target ON target.id=relation.friend_id WHERE relation.user_id=?1 AND sender.restricted=0 AND target.restricted=0 ORDER BY relation.friend_id LIMIT 1000";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    var list: std.ArrayList(i32) = .empty;
    errdefer list.deinit(allocator);
    while (true) switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => try list.append(allocator, c.sqlite3_column_int(stmt, 0)),
        c.SQLITE_DONE => break,
        else => return error.DatabaseQueryFailed,
    };
    if (user_id != 3 and std.mem.indexOfScalar(i32, list.items, 3) == null) try list.append(allocator, 3);
    return try list.toOwnedSlice(allocator);
}

pub fn addFriend(self: *Store, user_id: i32, friend_id: i32) !domain.RelationshipAddResult {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql =
        "WITH eligible AS (SELECT sender.id user_id,target.id friend_id FROM users sender JOIN users target ON target.id=?2 " ++
        "WHERE sender.id=?1 AND sender.id!=target.id AND target.id!=3 AND sender.restricted=0 AND target.restricted=0) " ++
        "INSERT OR IGNORE INTO friends(user_id,friend_id) SELECT user_id,friend_id FROM eligible";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, friend_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    if (c.sqlite3_changes(self.db) != 0) return .inserted;
    var eligible: ?*c.sqlite3_stmt = null;
    const eligible_sql = "SELECT EXISTS(SELECT 1 FROM users sender JOIN users target ON target.id=?2 WHERE sender.id=?1 AND sender.id!=target.id AND target.id!=3 AND sender.restricted=0 AND target.restricted=0)";
    if (c.sqlite3_prepare_v2(self.db, eligible_sql, -1, &eligible, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(eligible);
    _ = c.sqlite3_bind_int(eligible, 1, user_id);
    _ = c.sqlite3_bind_int(eligible, 2, friend_id);
    if (c.sqlite3_step(eligible) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return if (c.sqlite3_column_int(eligible, 0) != 0) .existing else .ineligible;
}

pub fn removeFriend(self: *Store, user_id: i32, friend_id: i32) !bool {
    if (friend_id == 3) return false;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "DELETE FROM friends WHERE user_id=?1 AND friend_id=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, friend_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return c.sqlite3_changes(self.db) != 0;
}

pub fn friendsAreMutual(self: *Store, user_id: i32, friend_id: i32) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT EXISTS(SELECT 1 FROM friends relation JOIN users sender ON sender.id=relation.user_id JOIN users target ON target.id=relation.friend_id WHERE relation.user_id=?1 AND relation.friend_id=?2 AND sender.id!=target.id AND target.id!=3 AND sender.restricted=0 AND target.restricted=0)";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, friend_id);
    _ = c.sqlite3_bind_int(stmt, 2, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return c.sqlite3_column_int(stmt, 0) != 0;
}

pub fn blockIds(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]i32 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT blocked_id FROM user_blocks WHERE user_id=?1 ORDER BY blocked_id LIMIT 1000", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    var list: std.ArrayList(i32) = .empty;
    errdefer list.deinit(allocator);
    while (true) switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => try list.append(allocator, c.sqlite3_column_int(stmt, 0)),
        c.SQLITE_DONE => break,
        else => return error.DatabaseQueryFailed,
    };
    return list.toOwnedSlice(allocator);
}

pub fn addBlock(self: *Store, user_id: i32, blocked_id: i32) !bool {
    if (user_id == blocked_id or blocked_id == 3) return false;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO user_blocks(user_id,blocked_id) VALUES(?1,?2)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, blocked_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return c.sqlite3_changes(self.db) != 0;
}

pub fn removeBlock(self: *Store, user_id: i32, blocked_id: i32) !bool {
    if (blocked_id == 3) return false;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "DELETE FROM user_blocks WHERE user_id=?1 AND blocked_id=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, blocked_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return c.sqlite3_changes(self.db) != 0;
}

pub fn favouriteSetIds(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]i32 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT set_id FROM favourites WHERE user_id=?1 ORDER BY created_at,set_id LIMIT 10000", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    var list: std.ArrayList(i32) = .empty;
    errdefer list.deinit(allocator);
    while (true) switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => try list.append(allocator, c.sqlite3_column_int(stmt, 0)),
        c.SQLITE_DONE => break,
        else => return error.DatabaseQueryFailed,
    };
    return list.toOwnedSlice(allocator);
}

pub fn addFavourite(self: *Store, user_id: i32, set_id: i32) !bool {
    if (set_id <= 0) return error.InvalidBeatmapSet;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO favourites(user_id,set_id) VALUES(?1,?2)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, set_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return c.sqlite3_changes(self.db) != 0;
}

pub fn removeFavourite(self: *Store, user_id: i32, set_id: i32) !bool {
    if (set_id <= 0) return error.InvalidBeatmapSet;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "DELETE FROM favourites WHERE user_id=?1 AND set_id=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    _ = c.sqlite3_bind_int(stmt, 2, set_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return c.sqlite3_changes(self.db) != 0;
}
