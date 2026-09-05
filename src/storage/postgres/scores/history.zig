const std = @import("std");
const domain = @import("../../../domain.zig");
const postgres = @import("../../../postgres.zig");

// Acquire these before any score, token, map or stats row locks. Ordinary
// submissions share the maintenance barrier, then serialize only their mode.
// Global recalculation and visibility changes take the barrier exclusively.
// The two-int key space is separate from the existing one-bigint session keys.
pub fn lockSubmission(self: anytype, conn: *postgres.c.PGconn, mode: u8) !void {
    try postgres.exec(conn, "SELECT pg_advisory_xact_lock_shared(1514685256,0)");
    var buf: [8]u8 = undefined;
    const key = try std.fmt.bufPrint(&buf, "{d}", .{@as(u16, mode) + 1});
    var result = try postgres.queryParams(self.allocator, conn, "SELECT pg_advisory_xact_lock(1514685256,$1::integer)", &.{key});
    result.deinit();
}

pub fn lockMaintenance(conn: *postgres.c.PGconn) !void {
    try postgres.exec(conn, "SELECT pg_advisory_xact_lock(1514685256,0)");
}

pub fn hasCurrentSlice(self: anytype, conn: *postgres.c.PGconn, source: domain.SiteScoreSource, mode: u8) !bool {
    var buf: [8]u8 = undefined;
    const mode_text = try std.fmt.bufPrint(&buf, "{d}", .{mode});
    var rows = try postgres.queryParams(self.allocator, conn, "SELECT 1 FROM zigcho.user_stats_history WHERE source=$1 AND mode=$2 AND day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400 LIMIT 1", &.{ @tagName(source), mode_text });
    defer rows.deinit();
    return rows.rows() != 0;
}

/// The full daily slice already exists. Recompute this player's PP only, then
/// update ranks which actually changed. Other players keep their correct daily
/// ranks without deleting and rewriting their unchanged PP/history rows.
pub fn recordPlayer(self: anytype, conn: *postgres.c.PGconn, source: domain.SiteScoreSource, mode: u8, user_id: i32) !void {
    var buffers: [3][24]u8 = undefined;
    const mode_text = try std.fmt.bufPrint(&buffers[0], "{d}", .{mode});
    const user = try std.fmt.bufPrint(&buffers[1], "{d}", .{user_id});
    const ruleset = try std.fmt.bufPrint(&buffers[2], "{d}", .{domain.siteScoreMode(mode)});
    const source_scores = switch (source) {
        .stable, .scorev2 => "SELECT b.id beatmap_id,s.pp,s.passed,b.status FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$3 AND s.mode=$4 AND s.rank_namespace=$5",
        .lazer => "SELECT b.id beatmap_id,s.pp,s.passed,b.status FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$3 AND s.ruleset_id=$4 AND s.rank_namespace=$5",
        .all => "",
    };
    const source_prefix = "WITH source_scores AS ({s})," ++
        "best AS (SELECT beatmap_id,max(pp) pp FROM source_scores WHERE passed AND status IN(3,4) GROUP BY beatmap_id)," ++
        "weighted AS (SELECT pp,row_number() OVER(ORDER BY pp DESC,beatmap_id ASC)-1 performance_index FROM best)," ++
        "performance AS (SELECT coalesce(round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*))))::integer,0) pp FROM weighted)," ++
        "player AS (SELECT u.id user_id,p.pp FROM zigcho.users u CROSS JOIN performance p WHERE u.id=$3 AND u.id!=3 AND NOT u.restricted AND EXISTS(SELECT 1 FROM source_scores)) ";
    const combined_prefix = "WITH player AS (SELECT s.user_id,s.pp FROM zigcho.stats s JOIN zigcho.users u ON u.id=s.user_id WHERE s.user_id=$3 AND s.mode=$2 AND s.plays>0 AND u.id!=3 AND NOT u.restricted) ";
    const write = "INSERT INTO zigcho.user_stats_history AS h(user_id,source,mode,day,pp,global_rank) " ++
        "SELECT user_id,$1,$2,(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400,pp,0 FROM player " ++
        "ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp WHERE h.pp IS DISTINCT FROM excluded.pp RETURNING user_id";
    const sql = if (source == .all)
        try self.allocator.dupeZ(u8, combined_prefix ++ write)
    else
        try std.fmt.allocPrintSentinel(self.allocator, source_prefix ++ write, .{source_scores}, 0);
    defer self.allocator.free(sql);
    const params: []const ?[]const u8 = if (source == .all)
        &.{ @tagName(source), mode_text, user }
    else
        &.{ @tagName(source), mode_text, user, ruleset, domain.siteNamespace(source, mode) };
    var update = try postgres.queryParams(self.allocator, conn, sql, params);
    const changed = update.rows() != 0;
    update.deinit();

    // Removal from visibility is normally handled by the maintenance path;
    // retain the same exclusion if a restricted account reaches this writer.
    var hidden = try postgres.queryParams(self.allocator, conn, "DELETE FROM zigcho.user_stats_history h USING zigcho.users u WHERE h.user_id=$3 AND u.id=h.user_id AND (u.id=3 OR u.restricted) AND h.source=$1 AND h.mode=$2 AND h.day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400 RETURNING h.user_id", &.{ @tagName(source), mode_text, user });
    const removed = hidden.rows() != 0;
    hidden.deinit();
    if (!changed and !removed) return;
    var ranks = try postgres.queryParams(self.allocator, conn, "WITH ranked AS (SELECT user_id,row_number() OVER(ORDER BY pp DESC,user_id ASC) position FROM zigcho.user_stats_history WHERE source=$1 AND mode=$2 AND day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400) " ++
        "UPDATE zigcho.user_stats_history h SET global_rank=r.position FROM ranked r WHERE h.user_id=r.user_id AND h.source=$1 AND h.mode=$2 AND h.day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400 AND h.global_rank IS DISTINCT FROM r.position", &.{ @tagName(source), mode_text });
    ranks.deinit();
}
