const std = @import("std");
const domain = @import("../../../domain.zig");
const postgres = @import("../../../postgres.zig");
const lazer = @import("../../../lazer.zig");
const performance_calculator = @import("../../../exact_pp.zig");
const pp_admin = @import("../../../pp_admin.zig");
const common = @import("../common.zig");
pub const history_updates = @import("history.zig");

pub fn backfillLazerClassicScoresWithConnection(self: anytype, conn: *postgres.c.PGconn) !void {
    try postgres.exec(conn, "BEGIN");
    errdefer postgres.exec(conn, "ROLLBACK") catch {};
    var rows = try postgres.query(conn, "SELECT id,ruleset_id,total_score,statistics_json::text,maximum_statistics_json::text FROM zigcho.lazer_scores WHERE legacy_total_score IS NULL ORDER BY id");
    defer rows.deinit();
    for (0..rows.rows()) |row| {
        const id = try rows.int(i64, row, 0);
        const ruleset_id = try rows.int(i64, row, 1);
        const total_score = try rows.int(i64, row, 2);
        const classic = lazer.classicTotalScoreFromJson(self.allocator, ruleset_id, total_score, rows.value(row, 3), rows.value(row, 4)) catch lazer.stableLegacyTotalScore(total_score);
        var id_buf: [32]u8 = undefined;
        var classic_buf: [32]u8 = undefined;
        const id_text = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
        const classic_text = try std.fmt.bufPrint(&classic_buf, "{d}", .{classic});
        var updated = try postgres.queryParams(self.allocator, conn, "UPDATE zigcho.lazer_scores SET legacy_total_score=$1 WHERE id=$2 AND legacy_total_score IS NULL", &.{ classic_text, id_text });
        updated.deinit();
    }
    try postgres.exec(conn, "COMMIT");
}

pub fn rebuildRankedStats(self: anytype, conn: *postgres.c.PGconn, pre_schema_43: bool) !void {
    var best = try postgres.query(
        conn,
        "UPDATE zigcho.lazer_scores SET best=false;" ++
            "WITH ordered AS (SELECT id,row_number() OVER(PARTITION BY user_id,beatmap_id,ruleset_id,rank_namespace ORDER BY pp DESC,total_score DESC,id ASC) place FROM zigcho.lazer_scores WHERE passed) " ++
            "UPDATE zigcho.lazer_scores scores SET best=true FROM ordered WHERE scores.id=ordered.id AND ordered.place=1",
    );
    best.deinit();
    const internal_mode = "CASE WHEN (s.mods&8192)!=0 THEN s.mode+8 WHEN (s.mods&128)!=0 THEN s.mode+4 ELSE s.mode END";
    const lazer_internal_mode = "CASE l.rank_namespace WHEN 'vanilla' THEN l.ruleset_id WHEN 'relax' THEN l.ruleset_id+4 WHEN 'autopilot' THEN 8 ELSE -1 END";
    const lazer_hits = "coalesce((l.statistics_json->>'meh')::bigint,0)+coalesce((l.statistics_json->>'ok')::bigint,0)+coalesce((l.statistics_json->>'good')::bigint,0)+coalesce((l.statistics_json->>'great')::bigint,0)+coalesce((l.statistics_json->>'perfect')::bigint,0)";
    const lazer_score = "coalesce(l.legacy_total_score,l.total_score)";
    const reset_sql = try std.fmt.allocPrintSentinel(self.allocator, "UPDATE zigcho.stats st SET " ++
        "total_score=coalesce((SELECT sum(s.score) FROM zigcho.scores s WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode),0)+coalesce((SELECT sum({s}) FROM zigcho.lazer_scores l WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode),0)," ++
        "plays=coalesce((SELECT count(*) FROM zigcho.scores s WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode),0)+coalesce((SELECT count(*) FROM zigcho.lazer_scores l WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode),0)," ++
        "play_time=coalesce((SELECT sum(s.time_elapsed/1000) FROM zigcho.scores s WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode),0)+coalesce((SELECT sum(greatest(b.total_length,0)) FROM zigcho.lazer_scores l JOIN zigcho.beatmaps b ON b.id=l.beatmap_id WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode),0)," ++
        "total_hits=coalesce((SELECT sum(s.n300+s.n100+s.n50+CASE WHEN s.mode IN(1,3) THEN s.ngeki+s.nkatu ELSE 0 END) FROM zigcho.scores s WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode),0)+coalesce((SELECT sum(" ++ lazer_hits ++ ") FROM zigcho.lazer_scores l WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode),0)," ++
        "ranked_score=0," ++
        "max_combo=greatest(coalesce((SELECT max(s.max_combo) FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode AND s.passed AND b.status>=3),0),coalesce((SELECT max(l.max_combo) FROM zigcho.lazer_scores l JOIN zigcho.beatmaps b ON b.id=l.beatmap_id WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode AND l.passed AND b.status>=3),0))," ++
        "pp=0,accuracy=0 WHERE st.user_id!=3 AND (EXISTS(SELECT 1 FROM zigcho.scores s WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode) OR EXISTS(SELECT 1 FROM zigcho.lazer_scores l WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode))", .{lazer_score}, 0);
    defer self.allocator.free(reset_sql);
    var reset = try postgres.query(conn, reset_sql);
    reset.deinit();
    var keys = try postgres.query(conn, "SELECT st.user_id,st.mode FROM zigcho.stats st WHERE st.user_id!=3 AND (EXISTS(SELECT 1 FROM zigcho.scores s WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode) OR EXISTS(SELECT 1 FROM zigcho.lazer_scores l WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode)) ORDER BY st.user_id,st.mode");
    defer keys.deinit();
    for (0..keys.rows()) |row| {
        const user_id = try keys.int(i32, row, 0);
        const stats_mode = try keys.int(u8, row, 1);
        const namespace: []const u8 = switch (stats_mode) {
            0...3 => "vanilla",
            4...6 => "relax",
            8 => "autopilot",
            else => continue,
        };
        try rebuildCombinedPerformanceWithConnection(self, conn, user_id, stats_mode % 4, stats_mode, namespace, pre_schema_43);
    }
}

pub fn recalculatePerformance(self: anytype, allocator: std.mem.Allocator) !u64 {
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    try history_updates.lockMaintenance(lease.conn);
    var scores = try postgres.query(lease.conn, "SELECT s.id,s.mode,s.mods,s.max_combo,s.n300,s.n100,s.n50,s.nmiss,s.ngeki,s.nkatu,s.score,s.rank_namespace,b.osu_file FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE b.osu_file IS NOT NULL ORDER BY s.id");
    defer scores.deinit();
    var count: u64 = 0;
    for (0..scores.rows()) |row| {
        const map_file = try postgres.decodeBytea(allocator, scores.value(row, 12));
        defer allocator.free(map_file);
        const namespace = std.meta.stringToEnum(pp_admin.Namespace, scores.value(row, 11)) orelse continue;
        const result = pp_admin.calculate(allocator, map_file, .{
            .source = .stable,
            .namespace = namespace,
            .input = .{
                .mode = try scores.int(u8, row, 1),
                .lazer = 0,
                .mods = try scores.int(u32, row, 2),
                .max_combo = try scores.int(u32, row, 3),
                .n_geki = try scores.int(u32, row, 8),
                .n_katu = try scores.int(u32, row, 9),
                .n300 = try scores.int(u32, row, 4),
                .n100 = try scores.int(u32, row, 5),
                .n50 = try scores.int(u32, row, 6),
                .misses = try scores.int(u32, row, 7),
                .legacy_total_score = try scores.int(u32, row, 10),
            },
        }) catch continue;
        var id_buf: [24]u8 = undefined;
        var pp_buf: [64]u8 = undefined;
        var star_buf: [64]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{try scores.int(i64, row, 0)});
        const performance = try std.fmt.bufPrint(&pp_buf, "{d}", .{result.pp});
        const stars = try std.fmt.bufPrint(&star_buf, "{d}", .{result.stars});
        var update = try postgres.queryParams(allocator, lease.conn, "UPDATE zigcho.scores SET pp=$1,star_rating=$2 WHERE id=$3", &.{ performance, stars, id });
        update.deinit();
        count += 1;
    }
    var lazer_scores = try postgres.query(lease.conn, "SELECT s.id,s.beatmap_id,s.ruleset_id,s.total_score,s.total_score_without_mods,s.legacy_total_score,s.accuracy,s.max_combo,s.passed,s.mods_json::text,s.statistics_json::text,s.rank_namespace,b.osu_file FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE b.osu_file IS NOT NULL ORDER BY s.id");
    defer lazer_scores.deinit();
    for (0..lazer_scores.rows()) |row| {
        const namespace = std.meta.stringToEnum(lazer.Namespace, lazer_scores.value(row, 11)) orelse continue;
        if (namespace == .custom) continue;
        var parsed_mods = std.json.parseFromSlice(std.json.Value, allocator, lazer_scores.value(row, 9), .{}) catch continue;
        defer parsed_mods.deinit();
        const mods = switch (parsed_mods.value) {
            .array => |value| value,
            else => continue,
        };
        var parsed_statistics = std.json.parseFromSlice(std.json.Value, allocator, lazer_scores.value(row, 10), .{}) catch continue;
        defer parsed_statistics.deinit();
        const statistics = switch (parsed_statistics.value) {
            .object => |value| value,
            else => continue,
        };
        const input: lazer.ScoreInput = .{
            .beatmap_id = try lazer_scores.int(i64, row, 1),
            .ruleset_id = try lazer_scores.int(i64, row, 2),
            .total_score = try lazer_scores.int(i64, row, 3),
            .total_score_without_mods = try lazer_scores.int(i64, row, 4),
            .legacy_total_score = if (lazer_scores.isNull(row, 5)) null else try lazer_scores.int(i32, row, 5),
            .accuracy = try lazer_scores.float(f64, row, 6),
            .max_combo = try lazer_scores.int(i64, row, 7),
            .passed = try lazer_scores.boolean(row, 8),
            .mods = mods,
            .statistics = statistics,
            .namespace = namespace,
        };
        const state = (lazer.performanceState(input) catch continue) orelse continue;
        const map_file = try postgres.decodeBytea(allocator, lazer_scores.value(row, 12));
        defer allocator.free(map_file);
        const performance_input: performance_calculator.Input = .{
            .mode = @intCast(input.ruleset_id),
            .lazer = 1,
            .mods = state.mods,
            .max_combo = state.max_combo,
            .large_tick_hits = state.large_tick_hits,
            .small_tick_hits = state.small_tick_hits,
            .slider_end_hits = state.slider_end_hits,
            .n_geki = state.n_geki,
            .n_katu = state.n_katu,
            .n300 = state.n300,
            .n100 = state.n100,
            .n50 = state.n50,
            .misses = state.misses,
            .legacy_total_score = state.legacy_total_score,
        };
        const policy_namespace = std.meta.stringToEnum(pp_admin.Namespace, lazer_scores.value(row, 11)) orelse continue;
        const result = pp_admin.calculate(allocator, map_file, .{
            .source = .lazer,
            .namespace = policy_namespace,
            .input = performance_input,
            .mods_json = lazer_scores.value(row, 9),
        }) catch continue;
        var id_buf: [24]u8 = undefined;
        var pp_buf: [64]u8 = undefined;
        var star_buf: [64]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{try lazer_scores.int(i64, row, 0)});
        const performance = try std.fmt.bufPrint(&pp_buf, "{d}", .{result.pp});
        const stars = try std.fmt.bufPrint(&star_buf, "{d}", .{result.stars});
        var update = try postgres.queryParams(allocator, lease.conn, "UPDATE zigcho.lazer_scores SET pp=$1,star_rating=$2 WHERE id=$3", &.{ performance, stars, id });
        update.deinit();
        count += 1;
    }
    var best = try postgres.query(
        lease.conn,
        "UPDATE zigcho.scores SET best=false;" ++
            "WITH ordered AS (SELECT id,row_number() OVER(PARTITION BY user_id,map_md5,mode,rank_namespace ORDER BY CASE WHEN rank_namespace IN('vanilla','scorev2') THEN score::double precision ELSE pp END DESC,id ASC) AS place FROM zigcho.scores WHERE passed) " ++
            "UPDATE zigcho.scores SET best=true WHERE id IN(SELECT id FROM ordered WHERE place=1)",
    );
    best.deinit();
    var lazer_best = try postgres.query(
        lease.conn,
        "UPDATE zigcho.lazer_scores SET best=false;" ++
            "WITH ordered AS (SELECT id,row_number() OVER(PARTITION BY user_id,beatmap_id,ruleset_id,rank_namespace ORDER BY pp DESC,total_score DESC,id ASC) AS place FROM zigcho.lazer_scores WHERE passed) " ++
            "UPDATE zigcho.lazer_scores SET best=true WHERE id IN(SELECT id FROM ordered WHERE place=1)",
    );
    lazer_best.deinit();
    try rebuildRankedStats(self, lease.conn, false);
    try recordAllStatsHistoryCurrentWithConnection(self, lease.conn);
    var detail_buf: [192]u8 = undefined;
    const detail = try std.fmt.bufPrint(&detail_buf, "recalculated {d} stable and lazer scores with {s}/{s}", .{ count, pp_admin.policy_version, pp_admin.upstream_engine_version });
    var audit = try postgres.queryParams(allocator, lease.conn, "INSERT INTO zigcho.audit_log(action,target,detail) VALUES('operations.pp_recalc','scores',$1)", &.{detail});
    audit.deinit();
    try postgres.exec(lease.conn, "COMMIT");
    return count;
}

pub fn readStatsHistoryWithConnection(self: anytype, conn: *postgres.c.PGconn, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !domain.StatsHistory {
    var buffers: [2][24]u8 = undefined;
    const user = try std.fmt.bufPrint(&buffers[0], "{d}", .{user_id});
    const mode = try std.fmt.bufPrint(&buffers[1], "{d}", .{stats_mode});
    var rows = try postgres.queryParams(
        self.allocator,
        conn,
        "SELECT day,pp,global_rank FROM zigcho.user_stats_history WHERE user_id=$1 AND source=$2 AND mode=$3 AND day BETWEEN ((extract(epoch FROM clock_timestamp())::bigint/86400)-89)*86400 AND (extract(epoch FROM clock_timestamp())::bigint/86400)*86400 ORDER BY day LIMIT 90",
        &.{ user, @tagName(source), mode },
    );
    defer rows.deinit();

    var history: domain.StatsHistory = .{};
    for (0..@min(rows.rows(), domain.StatsHistory.max_points)) |row| {
        history.points[row] = .{
            .day = try rows.int(i64, row, 0),
            .pp = try rows.int(i32, row, 1),
            .global_rank = try rows.int(i32, row, 2),
        };
        history.len += 1;
    }
    return history;
}

pub fn pruneStatsHistoryWithConnection(_: anytype, conn: *postgres.c.PGconn) !void {
    try postgres.exec(conn, "DELETE FROM zigcho.user_stats_history WHERE day<((extract(epoch FROM transaction_timestamp())::bigint/86400)-89)*86400");
}

pub fn recordStatsHistorySliceCurrentWithConnection(self: anytype, conn: *postgres.c.PGconn, source: domain.SiteScoreSource, stats_mode: u8, user_id: i32) !void {
    const score_mode = domain.siteScoreMode(stats_mode);
    const namespace = domain.siteNamespace(source, stats_mode);
    var history_mode_buf: [24]u8 = undefined;
    const history_mode = try std.fmt.bufPrint(&history_mode_buf, "{d}", .{stats_mode});
    if (user_id != 0) {
        // Preserve retention on every submission, but only touch this locked
        // slice. Unrelated modes cannot delete each other's history rows.
        var prune = try postgres.queryParams(self.allocator, conn, "DELETE FROM zigcho.user_stats_history WHERE source=$1 AND mode=$2 AND day<((extract(epoch FROM transaction_timestamp())::bigint/86400)-89)*86400", &.{ @tagName(source), history_mode });
        prune.deinit();
        if (try history_updates.hasCurrentSlice(self, conn, source, stats_mode))
            return history_updates.recordPlayer(self, conn, source, stats_mode, user_id);
        // First score of the day seeds the whole slice once, including inactive
        // players whose rank must move when today's active players pass them.
        return recordStatsHistorySliceCurrentWithConnection(self, conn, source, stats_mode, 0);
    }
    if (user_id == 0) {
        var clear = try postgres.queryParams(self.allocator, conn, "DELETE FROM zigcho.user_stats_history WHERE source=$1 AND mode=$2 AND day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400", &.{ @tagName(source), history_mode });
        defer clear.deinit();
    }
    const sql: [:0]const u8 = switch (source) {
        .all => if (user_id == 0)
            "WITH players AS (SELECT s.user_id,s.pp FROM zigcho.stats s JOIN zigcho.users u ON u.id=s.user_id WHERE s.mode=$2 AND s.plays>0 AND u.id!=3 AND NOT u.restricted),ordered AS (SELECT user_id,pp,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) " ++
                "INSERT INTO zigcho.user_stats_history(user_id,source,mode,day,pp,global_rank) SELECT user_id,$1,$2,(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400,pp,global_rank FROM ordered " ++
                "ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp,global_rank=excluded.global_rank"
        else
            "WITH player AS (SELECT s.user_id,s.pp FROM zigcho.stats s JOIN zigcho.users u ON u.id=s.user_id WHERE s.user_id=$3 AND s.mode=$2 AND s.plays>0 AND u.id!=3 AND NOT u.restricted),ranked AS (SELECT p.user_id,p.pp,1+(SELECT count(*) FROM zigcho.user_stats_history h WHERE h.source=$1 AND h.mode=$2 AND h.day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400 AND h.user_id!=p.user_id AND (h.pp>p.pp OR (h.pp=p.pp AND h.user_id<p.user_id))) global_rank FROM player p) " ++
                "INSERT INTO zigcho.user_stats_history(user_id,source,mode,day,pp,global_rank) SELECT user_id,$1,$2,(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400,pp,global_rank FROM ranked " ++
                "ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp,global_rank=excluded.global_rank",
        .stable, .scorev2 => if (user_id == 0)
            "WITH source_scores AS (SELECT s.user_id,b.id beatmap_id,s.pp,s.passed,b.status FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.mode=$3 AND s.rank_namespace=$4)," ++
                "activity AS (SELECT DISTINCT user_id FROM source_scores)," ++
                "best AS (SELECT user_id,beatmap_id,max(pp) pp FROM source_scores WHERE passed AND status IN(3,4) GROUP BY user_id,beatmap_id)," ++
                "weighted AS (SELECT user_id,pp,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC)-1 performance_index FROM best)," ++
                "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*))))::integer pp FROM weighted GROUP BY user_id)," ++
                "players AS (SELECT a.user_id,coalesce(p.pp,0) pp FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted)," ++
                "ordered AS (SELECT user_id,pp,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) " ++
                "INSERT INTO zigcho.user_stats_history(user_id,source,mode,day,pp,global_rank) SELECT user_id,$1,$2,(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400,pp,global_rank FROM ordered " ++
                "ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp,global_rank=excluded.global_rank"
        else
            "WITH source_scores AS (SELECT s.user_id,b.id beatmap_id,s.pp,s.passed,b.status FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$5 AND s.mode=$3 AND s.rank_namespace=$4)," ++
                "activity AS (SELECT DISTINCT user_id FROM source_scores)," ++
                "best AS (SELECT user_id,beatmap_id,max(pp) pp FROM source_scores WHERE passed AND status IN(3,4) GROUP BY user_id,beatmap_id)," ++
                "weighted AS (SELECT user_id,pp,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC)-1 performance_index FROM best)," ++
                "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*))))::integer pp FROM weighted GROUP BY user_id)," ++
                "player AS (SELECT a.user_id,coalesce(p.pp,0) pp FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted)," ++
                "ranked AS (SELECT p.user_id,p.pp,1+(SELECT count(*) FROM zigcho.user_stats_history h WHERE h.source=$1 AND h.mode=$2 AND h.day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400 AND h.user_id!=p.user_id AND (h.pp>p.pp OR (h.pp=p.pp AND h.user_id<p.user_id))) global_rank FROM player p) " ++
                "INSERT INTO zigcho.user_stats_history(user_id,source,mode,day,pp,global_rank) SELECT user_id,$1,$2,(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400,pp,global_rank FROM ranked " ++
                "ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp,global_rank=excluded.global_rank",
        .lazer => if (user_id == 0)
            "WITH source_scores AS (SELECT s.user_id,b.id beatmap_id,s.pp,s.passed,b.status FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.ruleset_id=$3 AND s.rank_namespace=$4)," ++
                "activity AS (SELECT DISTINCT user_id FROM source_scores)," ++
                "best AS (SELECT user_id,beatmap_id,max(pp) pp FROM source_scores WHERE passed AND status IN(3,4) GROUP BY user_id,beatmap_id)," ++
                "weighted AS (SELECT user_id,pp,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC)-1 performance_index FROM best)," ++
                "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*))))::integer pp FROM weighted GROUP BY user_id)," ++
                "players AS (SELECT a.user_id,coalesce(p.pp,0) pp FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted)," ++
                "ordered AS (SELECT user_id,pp,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) " ++
                "INSERT INTO zigcho.user_stats_history(user_id,source,mode,day,pp,global_rank) SELECT user_id,$1,$2,(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400,pp,global_rank FROM ordered " ++
                "ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp,global_rank=excluded.global_rank"
        else
            "WITH source_scores AS (SELECT s.user_id,b.id beatmap_id,s.pp,s.passed,b.status FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$5 AND s.ruleset_id=$3 AND s.rank_namespace=$4)," ++
                "activity AS (SELECT DISTINCT user_id FROM source_scores)," ++
                "best AS (SELECT user_id,beatmap_id,max(pp) pp FROM source_scores WHERE passed AND status IN(3,4) GROUP BY user_id,beatmap_id)," ++
                "weighted AS (SELECT user_id,pp,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC)-1 performance_index FROM best)," ++
                "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*))))::integer pp FROM weighted GROUP BY user_id)," ++
                "player AS (SELECT a.user_id,coalesce(p.pp,0) pp FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted)," ++
                "ranked AS (SELECT p.user_id,p.pp,1+(SELECT count(*) FROM zigcho.user_stats_history h WHERE h.source=$1 AND h.mode=$2 AND h.day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400 AND h.user_id!=p.user_id AND (h.pp>p.pp OR (h.pp=p.pp AND h.user_id<p.user_id))) global_rank FROM player p) " ++
                "INSERT INTO zigcho.user_stats_history(user_id,source,mode,day,pp,global_rank) SELECT user_id,$1,$2,(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400,pp,global_rank FROM ranked " ++
                "ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp,global_rank=excluded.global_rank",
    };
    var buffers: [3][24]u8 = undefined;
    const mode = try std.fmt.bufPrint(&buffers[1], "{d}", .{score_mode});
    const user = try std.fmt.bufPrint(&buffers[2], "{d}", .{user_id});
    const params: []const ?[]const u8 = if (source == .all)
        if (user_id == 0)
            &.{ @tagName(source), history_mode }
        else
            &.{ @tagName(source), history_mode, user }
    else if (user_id == 0)
        &.{ @tagName(source), history_mode, mode, namespace }
    else
        &.{ @tagName(source), history_mode, mode, namespace, user };
    var insert = try postgres.queryParams(self.allocator, conn, sql, params);
    defer insert.deinit();
}

pub fn statsHistoryUserVisibleWithConnection(self: anytype, conn: *postgres.c.PGconn, user_id: i32) !bool {
    var user_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    var visible = try postgres.queryParams(self.allocator, conn, "SELECT 1 FROM zigcho.users WHERE id=$1 AND id!=3 AND NOT restricted", &.{user});
    defer visible.deinit();
    return visible.rows() != 0;
}

pub fn statsHistory(self: anytype, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !domain.StatsHistory {
    if (user_id <= 0 or !domain.validSiteMode(source, stats_mode)) return error.InvalidStatsHistory;
    var lease = self.pool.acquire();
    defer lease.release();
    if (!try statsHistoryUserVisibleWithConnection(self, lease.conn, user_id)) return error.InvalidStatsHistory;
    return readStatsHistoryWithConnection(self, lease.conn, user_id, source, stats_mode);
}

pub fn recordAllStatsHistoryCurrentWithConnection(self: anytype, conn: *postgres.c.PGconn) !void {
    try pruneStatsHistoryWithConnection(self, conn);
    const full_modes = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 8 };
    for ([_]domain.SiteScoreSource{ .all, .stable, .lazer }) |source| {
        for (full_modes) |stats_mode| try recordStatsHistorySliceCurrentWithConnection(self, conn, source, stats_mode, 0);
    }
    for ([_]u8{ 0, 1, 2, 3 }) |stats_mode| try recordStatsHistorySliceCurrentWithConnection(self, conn, .scorev2, stats_mode, 0);
}

pub fn recordBeatmapStatsHistoryCurrentWithConnection(self: anytype, conn: *postgres.c.PGconn, map_id: i32, md5: []const u8) !void {
    var map_buf: [24]u8 = undefined;
    const map = try std.fmt.bufPrint(&map_buf, "{d}", .{map_id});
    var keys = try postgres.queryParams(
        self.allocator,
        conn,
        "WITH keys(source,mode) AS (" ++
            "SELECT CASE rank_namespace WHEN 'scorev2' THEN 'scorev2' ELSE 'stable' END,CASE rank_namespace WHEN 'relax' THEN mode+4 WHEN 'autopilot' THEN 8 ELSE mode END FROM zigcho.scores WHERE map_md5=$1 " ++
            "UNION SELECT 'lazer',CASE rank_namespace WHEN 'relax' THEN ruleset_id+4 WHEN 'autopilot' THEN 8 ELSE ruleset_id END FROM zigcho.lazer_scores WHERE beatmap_id=$2)," ++
            "expanded(source,mode) AS (SELECT source,mode FROM keys UNION SELECT 'all',mode FROM keys WHERE source!='scorev2') " ++
            "SELECT DISTINCT source,mode FROM expanded",
        &.{ md5, map },
    );
    defer keys.deinit();
    var slices = [_][9]bool{[_]bool{false} ** 9} ** 4;
    for (0..keys.rows()) |row| {
        const source = domain.parseSiteScoreSource(keys.value(row, 0)) orelse continue;
        const stats_mode = try keys.int(u8, row, 1);
        if (stats_mode > 8 or !domain.validSiteMode(source, stats_mode)) continue;
        slices[@intFromEnum(source)][stats_mode] = true;
    }
    try pruneStatsHistoryWithConnection(self, conn);
    for (slices, 0..) |modes, source_index| {
        const source: domain.SiteScoreSource = @enumFromInt(source_index);
        for (modes, 0..) |present, stats_mode| if (present) try recordStatsHistorySliceCurrentWithConnection(self, conn, source, @intCast(stats_mode), 0);
    }
}

pub fn refreshStatsHistory(self: anytype) !void {
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    try history_updates.lockMaintenance(lease.conn);
    try recordAllStatsHistoryCurrentWithConnection(self, lease.conn);
    try postgres.exec(lease.conn, "COMMIT");
}

pub fn rebuildCombinedPerformanceWithConnection(self: anytype, conn: *postgres.c.PGconn, user_id: i32, ruleset_id: u8, stats_mode: u8, namespace: []const u8, pre_schema_43: bool) !void {
    var buffers: [32][64]u8 = undefined;
    var cursor: usize = 0;
    const user = try common.param(&buffers, &cursor, user_id);
    const ruleset = try common.param(&buffers, &cursor, ruleset_id);
    const mode = try common.param(&buffers, &cursor, stats_mode);
    const sql = if (pre_schema_43)
        "WITH candidates AS (" ++
            "SELECT b.id beatmap_id,s.pp,s.accuracy,s.score legacy_score,0 source,s.id score_id FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4) " ++
            "UNION ALL SELECT s.beatmap_id,s.pp,s.accuracy,coalesce(s.legacy_total_score,s.total_score),1,s.id FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4))," ++
            "per_map AS (SELECT *,row_number() OVER(PARTITION BY beatmap_id ORDER BY pp DESC,source ASC,score_id ASC) map_place FROM candidates) " ++
            "SELECT pp,accuracy,legacy_score FROM per_map WHERE map_place=1 ORDER BY pp DESC,beatmap_id ASC"
    else
        "WITH candidates AS (" ++
            "SELECT b.id beatmap_id,s.pp,s.accuracy,s.score legacy_score,0 source,s.id score_id FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4) " ++
            "UNION ALL SELECT s.beatmap_id,s.pp,s.accuracy,coalesce(s.legacy_total_score,s.total_score),1,s.id FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4))," ++
            "per_map AS (SELECT *,row_number() OVER(PARTITION BY beatmap_id ORDER BY pp DESC,source ASC,score_id ASC) map_place FROM candidates) " ++
            "SELECT pp,accuracy,legacy_score FROM per_map WHERE map_place=1 ORDER BY pp DESC,beatmap_id ASC";
    var result = try postgres.queryParams(self.allocator, conn, sql, &.{ user, ruleset, namespace });
    defer result.deinit();
    var total_pp: f64 = 0;
    var weighted_accuracy: f64 = 0;
    var weight: f64 = 1;
    var ranked_score: i64 = 0;
    for (0..result.rows()) |row| {
        total_pp += try result.float(f64, row, 0) * weight;
        weighted_accuracy += try result.float(f64, row, 1) * weight;
        ranked_score += try result.int(i64, row, 2);
        weight *= 0.95;
    }
    const score_count: u32 = @intCast(result.rows());
    const bonus_pp = 416.6667 * (1.0 - std.math.pow(f64, 0.9994, @floatFromInt(score_count)));
    const accuracy = if (score_count == 0) 0 else weighted_accuracy / (20.0 * (1.0 - std.math.pow(f64, 0.95, @floatFromInt(score_count))));
    const total = try common.param(&buffers, &cursor, @as(i64, @intFromFloat(@round(total_pp + bonus_pp))));
    const accuracy_text = try common.param(&buffers, &cursor, accuracy);
    const ranked = try common.param(&buffers, &cursor, ranked_score);
    var update = try postgres.queryParams(self.allocator, conn, "UPDATE zigcho.stats SET pp=$1,accuracy=$2,ranked_score=$3 WHERE user_id=$4 AND mode=$5", &.{ total, accuracy_text, ranked, user, mode });
    update.deinit();
}
