const std = @import("std");
const c = @import("../../../storage.zig").c;
const ReplaySource = @import("../../contracts.zig").ReplaySource;
const Store = @import("../../../storage.zig").Store;

pub fn setScorePinned(self: *Store, user_id: i32, map_md5: []const u8, mode: u8, mods: i32, namespace: []const u8, pinned: bool) !i64 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};

    const score_id = block: {
        var score: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT id FROM scores WHERE user_id=?1 AND map_md5=?2 AND mode=?3 AND rank_namespace=?4 AND mods=?5 AND passed=1 ORDER BY best DESC,pp DESC,score DESC,id DESC LIMIT 1", -1, &score, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(score);
        _ = c.sqlite3_bind_int(score, 1, user_id);
        _ = c.sqlite3_bind_text(score, 2, map_md5.ptr, @intCast(map_md5.len), null);
        _ = c.sqlite3_bind_int(score, 3, mode);
        _ = c.sqlite3_bind_text(score, 4, namespace.ptr, @intCast(namespace.len), null);
        _ = c.sqlite3_bind_int(score, 5, mods);
        if (c.sqlite3_step(score) != c.SQLITE_ROW) return error.NoPassedScore;
        break :block c.sqlite3_column_int64(score, 0);
    };

    if (pinned) {
        var old: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM score_pins WHERE user_id=?1 AND score_id<>?2 AND score_id IN (SELECT id FROM scores WHERE user_id=?1 AND map_md5=?3 AND mode=?4 AND mods=?5 AND rank_namespace=?6)", -1, &old, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int(old, 1, user_id);
        _ = c.sqlite3_bind_int64(old, 2, score_id);
        _ = c.sqlite3_bind_text(old, 3, map_md5.ptr, @intCast(map_md5.len), null);
        _ = c.sqlite3_bind_int(old, 4, mode);
        _ = c.sqlite3_bind_int(old, 5, mods);
        _ = c.sqlite3_bind_text(old, 6, namespace.ptr, @intCast(namespace.len), null);
        if (c.sqlite3_step(old) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        _ = c.sqlite3_finalize(old);
        var old_profile: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM profile_score_pins WHERE user_id=?1 AND source='stable' AND score_id<>?2 AND score_id IN (SELECT id FROM scores WHERE user_id=?1 AND map_md5=?3 AND mode=?4 AND mods=?5 AND rank_namespace=?6)", -1, &old_profile, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int(old_profile, 1, user_id);
        _ = c.sqlite3_bind_int64(old_profile, 2, score_id);
        _ = c.sqlite3_bind_text(old_profile, 3, map_md5.ptr, @intCast(map_md5.len), null);
        _ = c.sqlite3_bind_int(old_profile, 4, mode);
        _ = c.sqlite3_bind_int(old_profile, 5, mods);
        _ = c.sqlite3_bind_text(old_profile, 6, namespace.ptr, @intCast(namespace.len), null);
        if (c.sqlite3_step(old_profile) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        _ = c.sqlite3_finalize(old_profile);

        var existing: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM profile_score_pins WHERE user_id=?1 AND source='stable' AND score_id=?2", -1, &existing, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int(existing, 1, user_id);
        _ = c.sqlite3_bind_int64(existing, 2, score_id);
        const already_pinned = c.sqlite3_step(existing) == c.SQLITE_ROW;
        _ = c.sqlite3_finalize(existing);
        if (!already_pinned) {
            var count: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT count(*) FROM profile_score_pins WHERE user_id=?1 AND mode=?2 AND rank_namespace=?3", -1, &count, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            _ = c.sqlite3_bind_int(count, 1, user_id);
            _ = c.sqlite3_bind_int(count, 2, mode);
            _ = c.sqlite3_bind_text(count, 3, namespace.ptr, @intCast(namespace.len), null);
            if (c.sqlite3_step(count) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
            const pin_count = c.sqlite3_column_int(count, 0);
            _ = c.sqlite3_finalize(count);
            if (pin_count >= 3) return error.TooManyPinnedScores;
            var insert: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "INSERT INTO score_pins(user_id,score_id) VALUES(?1,?2)", -1, &insert, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            _ = c.sqlite3_bind_int(insert, 1, user_id);
            _ = c.sqlite3_bind_int64(insert, 2, score_id);
            if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
            _ = c.sqlite3_finalize(insert);
        } else {
            var touch: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "UPDATE score_pins SET pinned_at=unixepoch() WHERE user_id=?1 AND score_id=?2", -1, &touch, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            _ = c.sqlite3_bind_int(touch, 1, user_id);
            _ = c.sqlite3_bind_int64(touch, 2, score_id);
            if (c.sqlite3_step(touch) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
            _ = c.sqlite3_finalize(touch);
        }
    } else {
        var remove: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM score_pins WHERE user_id=?1 AND score_id IN (SELECT id FROM scores WHERE user_id=?1 AND map_md5=?2 AND mode=?3 AND mods=?4 AND rank_namespace=?5)", -1, &remove, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int(remove, 1, user_id);
        _ = c.sqlite3_bind_text(remove, 2, map_md5.ptr, @intCast(map_md5.len), null);
        _ = c.sqlite3_bind_int(remove, 3, mode);
        _ = c.sqlite3_bind_int(remove, 4, mods);
        _ = c.sqlite3_bind_text(remove, 5, namespace.ptr, @intCast(namespace.len), null);
        if (c.sqlite3_step(remove) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        _ = c.sqlite3_finalize(remove);
    }
    var profile: ?*c.sqlite3_stmt = null;
    const profile_sql = if (pinned)
        "INSERT INTO profile_score_pins(user_id,source,score_id,mode,rank_namespace) VALUES(?1,'stable',?2,?3,?4) ON CONFLICT(user_id,source,score_id) DO UPDATE SET pinned_at=unixepoch()"
    else
        "DELETE FROM profile_score_pins WHERE user_id=?1 AND source='stable' AND score_id IN (SELECT id FROM scores WHERE user_id=?1 AND map_md5=?2 AND mode=?3 AND rank_namespace=?4 AND mods=?5)";
    if (c.sqlite3_prepare_v2(self.db, profile_sql, -1, &profile, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(profile);
    _ = c.sqlite3_bind_int(profile, 1, user_id);
    if (pinned) _ = c.sqlite3_bind_int64(profile, 2, score_id) else _ = c.sqlite3_bind_text(profile, 2, map_md5.ptr, @intCast(map_md5.len), null);
    _ = c.sqlite3_bind_int(profile, 3, mode);
    _ = c.sqlite3_bind_text(profile, 4, namespace.ptr, @intCast(namespace.len), null);
    if (!pinned) _ = c.sqlite3_bind_int(profile, 5, mods);
    if (c.sqlite3_step(profile) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    try self.exec("COMMIT");
    return score_id;
}

pub fn setScorePinnedById(self: *Store, user_id: i32, source: ReplaySource, score_id: i64, pinned: bool) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var score: ?*c.sqlite3_stmt = null;
    const score_sql = switch (source) {
        .stable => "SELECT mode,rank_namespace FROM scores WHERE id=?1 AND user_id=?2 AND passed=1",
        .lazer => "SELECT ruleset_id,rank_namespace FROM lazer_scores WHERE id=?1 AND user_id=?2 AND passed=1",
    };
    if (c.sqlite3_prepare_v2(self.db, score_sql, -1, &score, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(score);
    _ = c.sqlite3_bind_int64(score, 1, score_id);
    _ = c.sqlite3_bind_int(score, 2, user_id);
    if (c.sqlite3_step(score) != c.SQLITE_ROW) return error.NoPassedScore;
    if (pinned) {
        var count: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT count(*) FROM profile_score_pins WHERE user_id=?1 AND mode=?2 AND rank_namespace=?3 AND NOT(source=?4 AND score_id=?5)", -1, &count, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(count);
        _ = c.sqlite3_bind_int(count, 1, user_id);
        _ = c.sqlite3_bind_int(count, 2, c.sqlite3_column_int(score, 0));
        const namespace = std.mem.span(c.sqlite3_column_text(score, 1));
        _ = c.sqlite3_bind_text(count, 3, namespace.ptr, @intCast(namespace.len), null);
        _ = c.sqlite3_bind_text(count, 4, source.text().ptr, @intCast(source.text().len), null);
        _ = c.sqlite3_bind_int64(count, 5, score_id);
        if (c.sqlite3_step(count) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        if (c.sqlite3_column_int(count, 0) >= 3) return error.TooManyPinnedScores;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT INTO profile_score_pins(user_id,source,score_id,mode,rank_namespace) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(user_id,source,score_id) DO UPDATE SET pinned_at=unixepoch()", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_text(stmt, 2, source.text().ptr, @intCast(source.text().len), null);
        _ = c.sqlite3_bind_int64(stmt, 3, score_id);
        _ = c.sqlite3_bind_int(stmt, 4, c.sqlite3_column_int(score, 0));
        _ = c.sqlite3_bind_text(stmt, 5, namespace.ptr, @intCast(namespace.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        if (source == .stable) {
            var legacy: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "INSERT INTO score_pins(user_id,score_id) VALUES(?1,?2) ON CONFLICT(user_id,score_id) DO UPDATE SET pinned_at=unixepoch()", -1, &legacy, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(legacy);
            _ = c.sqlite3_bind_int(legacy, 1, user_id);
            _ = c.sqlite3_bind_int64(legacy, 2, score_id);
            if (c.sqlite3_step(legacy) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        }
    } else {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM profile_score_pins WHERE user_id=?1 AND source=?2 AND score_id=?3", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_text(stmt, 2, source.text().ptr, @intCast(source.text().len), null);
        _ = c.sqlite3_bind_int64(stmt, 3, score_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        if (source == .stable) {
            var legacy: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "DELETE FROM score_pins WHERE user_id=?1 AND score_id=?2", -1, &legacy, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(legacy);
            _ = c.sqlite3_bind_int(legacy, 1, user_id);
            _ = c.sqlite3_bind_int64(legacy, 2, score_id);
            if (c.sqlite3_step(legacy) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        }
    }
    try self.exec("COMMIT");
}
