const std = @import("std");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const BeatmapSelection = @import("../../contracts.zig").BeatmapSelection;
const MatchmakingBeatmap = @import("../../contracts.zig").MatchmakingBeatmap;

pub fn matchmakingBeatmaps(self: *Store, allocator: std.mem.Allocator, mode: u8, limit: u8) ![]MatchmakingBeatmap {
    if (mode > 3 or limit == 0 or limit > 32) return error.InvalidMatchmakingPool;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT id,md5,mode,star_rating FROM beatmaps WHERE status IN(3,4) AND mode=?1 AND osu_file IS NOT NULL ORDER BY star_rating,id LIMIT ?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, mode);
    _ = c.sqlite3_bind_int(stmt, 2, limit);
    var maps: std.ArrayList(MatchmakingBeatmap) = .empty;
    errdefer maps.deinit(allocator);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const md5 = std.mem.span(c.sqlite3_column_text(stmt, 1));
        if (md5.len != 32) return error.InvalidBeatmap;
        var map: MatchmakingBeatmap = .{
            .id = c.sqlite3_column_int(stmt, 0),
            .md5 = undefined,
            .mode = @intCast(c.sqlite3_column_int(stmt, 2)),
            .stars = c.sqlite3_column_double(stmt, 3),
        };
        @memcpy(&map.md5, md5);
        try maps.append(allocator, map);
    }
    return maps.toOwnedSlice(allocator);
}

pub fn beatmapSelectionById(self: *Store, map_id: i32) !?BeatmapSelection {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT md5,set_id,status,mode FROM beatmaps WHERE id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, map_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const md5 = std.mem.span(c.sqlite3_column_text(stmt, 0));
    if (md5.len != 32) return error.InvalidBeatmap;
    var selection: BeatmapSelection = .{
        .md5 = undefined,
        .set_id = c.sqlite3_column_int(stmt, 1),
        .status = @intCast(c.sqlite3_column_int(stmt, 2)),
        .mode = @intCast(c.sqlite3_column_int(stmt, 3)),
    };
    @memcpy(&selection.md5, md5);
    return selection;
}
