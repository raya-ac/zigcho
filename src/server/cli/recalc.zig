const d = @import("../deps.zig");
const std = d.std;
const storage = d.storage;
const sqlite_storage = d.sqlite_storage;
const pp = d.pp;
const config_mod = d.config_mod;
const r2 = d.r2;
const object_keys = d.object_keys;

pub fn recalcAllScores(allocator: std.mem.Allocator, store: *sqlite_storage.Store) !void {
    const c = sqlite_storage.c;
    std.debug.print("recalculating all scores with zigcho pp {s}...\n", .{pp.engine_version});
    const scores_sql = "SELECT id,user_id,map_md5,mode,mods,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,score FROM scores WHERE passed=1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(store.db, scores_sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    var count: u32 = 0;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const id = c.sqlite3_column_int64(stmt, 0);
        const map_md5 = std.mem.span(c.sqlite3_column_text(stmt, 2));
        const mode: u8 = @intCast(c.sqlite3_column_int(stmt, 3));
        const mods = c.sqlite3_column_int(stmt, 4);
        const max_combo: u32 = @intCast(c.sqlite3_column_int(stmt, 5));
        const n300: u32 = @intCast(c.sqlite3_column_int(stmt, 6));
        const n100: u32 = @intCast(c.sqlite3_column_int(stmt, 7));
        const n50: u32 = @intCast(c.sqlite3_column_int(stmt, 8));
        const nmiss: u32 = @intCast(c.sqlite3_column_int(stmt, 9));
        const ngeki: u32 = @intCast(c.sqlite3_column_int(stmt, 10));
        const nkatu: u32 = @intCast(c.sqlite3_column_int(stmt, 11));
        const total_score: u32 = @intCast(c.sqlite3_column_int64(stmt, 12));
        const md5_copy = try allocator.dupe(u8, map_md5);
        defer allocator.free(md5_copy);
        const map_file = (try store.beatmapFile(allocator, md5_copy)) orelse {
            std.debug.print("  score {d}: no .osu file, skipping\n", .{id});
            continue;
        };
        defer allocator.free(map_file);
        const result = pp.calculate(map_file, .{
            .mode = mode,
            .lazer = 0,
            .mods = @intCast(mods),
            .max_combo = max_combo,
            .n_geki = ngeki,
            .n_katu = nkatu,
            .n300 = n300,
            .n100 = n100,
            .n50 = n50,
            .misses = nmiss,
            .legacy_total_score = total_score,
        }) catch {
            std.debug.print("  score {d}: pp calc failed, skipping\n", .{id});
            continue;
        };
        const update_sql = "UPDATE scores SET pp=?1 WHERE id=?2";
        var up: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(store.db, update_sql, -1, &up, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_double(up, 1, result.pp);
        _ = c.sqlite3_bind_int64(up, 2, id);
        if (c.sqlite3_step(up) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        _ = c.sqlite3_finalize(up);
        std.debug.print("  score {d}: pp={d:.2} stars={d:.2}\n", .{ id, result.pp, result.stars });
        count += 1;
    }
    std.debug.print("recalculated {d} scores. rebuilding stats...\n", .{count});
    try store.exec("BEGIN IMMEDIATE");
    try recalcStats(store);
    try store.exec("COMMIT");
    try store.refreshStatsHistory();
    std.debug.print("done.\n", .{});
}

pub fn recalcStats(store: *sqlite_storage.Store) !void {
    const c = sqlite_storage.c;
    const modes_sql = "SELECT DISTINCT user_id,mode FROM stats";
    var m_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(store.db, modes_sql, -1, &m_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(m_stmt);
    while (c.sqlite3_step(m_stmt) == c.SQLITE_ROW) {
        const uid = c.sqlite3_column_int(m_stmt, 0);
        const stats_mode = c.sqlite3_column_int(m_stmt, 1);
        const vanilla_mode: i32 = switch (stats_mode) {
            0, 1, 2, 3 => stats_mode,
            4, 5, 6 => stats_mode - 4,
            8 => 0,
            else => continue,
        };
        const namespace: ?[]const u8 = switch (stats_mode) {
            0, 1, 2, 3 => "vanilla",
            4, 5, 6 => "relax",
            8 => "autopilot",
            else => null,
        };
        if (namespace == null) continue;
        const ns = namespace.?;
        const pp_sql = "SELECT s.pp,s.accuracy FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=?1 AND s.mode=?2 AND s.passed=1 AND s.best=1 AND s.rank_namespace=?3 AND b.status IN (3,4) ORDER BY s.pp DESC,s.id ASC";
        var pp_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(store.db, pp_sql, -1, &pp_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(pp_stmt);
        _ = c.sqlite3_bind_int(pp_stmt, 1, uid);
        _ = c.sqlite3_bind_int(pp_stmt, 2, vanilla_mode);
        _ = c.sqlite3_bind_text(pp_stmt, 3, ns.ptr, @intCast(ns.len), null);
        var total_pp: f64 = 0;
        var weighted_accuracy: f64 = 0;
        var weight: f64 = 1;
        var score_count: u32 = 0;
        while (c.sqlite3_step(pp_stmt) == c.SQLITE_ROW) {
            total_pp += c.sqlite3_column_double(pp_stmt, 0) * weight;
            weighted_accuracy += c.sqlite3_column_double(pp_stmt, 1) * weight;
            weight *= 0.95;
            score_count += 1;
        }
        const bonus_pp = 416.6667 * (1.0 - std.math.pow(f64, 0.9994, @floatFromInt(score_count)));
        const bonus_accuracy = if (score_count > 0) 1.0 / (20.0 * (1.0 - std.math.pow(f64, 0.95, @floatFromInt(score_count)))) else 0;
        const set_sql = "UPDATE stats SET pp=?1,accuracy=?2 WHERE user_id=?3 AND mode=?4";
        var set_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(store.db, set_sql, -1, &set_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int64(set_stmt, 1, @intFromFloat(@round(total_pp + bonus_pp)));
        _ = c.sqlite3_bind_double(set_stmt, 2, weighted_accuracy * bonus_accuracy);
        _ = c.sqlite3_bind_int(set_stmt, 3, uid);
        _ = c.sqlite3_bind_int(set_stmt, 4, stats_mode);
        if (c.sqlite3_step(set_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        _ = c.sqlite3_finalize(set_stmt);
        std.debug.print("  user {d} mode {d} ({s}): pp={d}\n", .{ uid, stats_mode, ns, @round(total_pp + bonus_pp) });
    }
}
