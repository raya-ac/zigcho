const std = @import("std");
const postgres = @import("../../../postgres.zig");
const Store = @import("../../../postgres_store.zig").Store;
const stable = @import("../../../stable_score.zig");
const lazer = @import("../../../lazer.zig");

const snapshot_sql = "SELECT coalesce(json_agg(json_build_array(user_id,source,mode,day,pp,global_rank) ORDER BY source,user_id),'[]')::text FROM zigcho.user_stats_history WHERE mode=0 AND source IN('all','stable','lazer') AND day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400";

fn matchesFullRebuild(store: *Store) !void {
    var lease = store.pool.acquire();
    defer lease.release();
    var before = try postgres.query(lease.conn, snapshot_sql);
    defer before.deinit();
    try store.refreshStatsHistory();
    var after = try postgres.query(lease.conn, snapshot_sql);
    defer after.deinit();
    try std.testing.expectEqualStrings(before.value(0, 0), after.value(0, 0));
}

pub fn verify(conninfo: []const u8) !void {
    var store = try Store.open(std.testing.allocator, std.testing.io, conninfo);
    defer store.close();
    try store.migrate();
    const map_md5 = "97979797979797979797979797979791";
    try store.upsertBeatmapMeta(.{ .id = 990000010, .set_id = 990000010, .artist = "history", .title = "concurrent", .version = "one", .creator = "fixture" }, map_md5, 3, 1, 10);
    try store.upsertBeatmapMeta(.{ .id = 990000011, .set_id = 990000010, .artist = "history", .title = "concurrent", .version = "two", .creator = "fixture" }, "97979797979797979797979797979792", 3, 1, 10);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"beatmap_id\":990000011,\"ruleset_id\":0,\"total_score\":1000,\"accuracy\":1,\"max_combo\":10,\"passed\":true,\"rank\":\"X\",\"mods\":[],\"statistics\":{\"great\":10}}", .{});
    defer parsed.deinit();
    const input = try lazer.parseScore(parsed.value);
    const Submission = struct {
        store: *Store,
        user_id: i32,
        score: stable.Submission,
        lazer_input: lazer.ScoreInput,
        is_lazer: bool,
        pp: f64,
        failed: *std.atomic.Value(bool),

        fn run(context: *@This()) void {
            if (context.is_lazer) {
                _ = context.store.insertLazerScore(context.user_id, context.lazer_input, context.pp, "[]", "{\"great\":10}", "{}", "[]", "history replay") catch {
                    context.failed.store(true, .release);
                    return;
                };
            } else {
                _ = context.store.insertStableScore(context.user_id, context.score, context.pp, "history replay", 10_000) catch {
                    context.failed.store(true, .release);
                    return;
                };
            }
        }
    };
    var failed: std.atomic.Value(bool) = .init(false);
    var contexts: [6]Submission = undefined;
    var checksums: [6][32]u8 = undefined;
    for (&contexts, 0..) |*context, i| {
        var name_buf: [32]u8 = undefined;
        var email_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "history overlap {d}", .{i});
        const email = try std.fmt.bufPrint(&email_buf, "history-overlap-{d}@example.test", .{i});
        const id = try store.register(name, email, "97979797979797979797979797979797");
        const checksum = try std.fmt.bufPrint(&checksums[i], "{x:0>32}", .{1234000 + i});
        context.* = .{
            .store = &store,
            .user_id = id,
            .is_lazer = i % 2 == 1,
            .pp = @floatFromInt(20 + i * 10),
            .failed = &failed,
            .lazer_input = input,
            .score = .{ .map_md5 = map_md5, .username = "history overlap", .online_checksum = checksum, .n300 = 10, .n100 = 0, .n50 = 0, .ngeki = 0, .nkatu = 0, .nmiss = 0, .total_score = 1000, .max_combo = 10, .perfect = true, .grade = "X", .mods = 0, .passed = true, .mode = 0, .client_time = "260905000000", .client_flags = "0" },
        };
    }
    var barrier = store.pool.acquire();
    try postgres.exec(barrier.conn, "BEGIN; SELECT pg_advisory_xact_lock(1514685256,1)");
    var threads: [6]std.Thread = undefined;
    var started: usize = 0;
    var barrier_held = true;
    errdefer if (barrier_held) {
        postgres.exec(barrier.conn, "ROLLBACK") catch {};
        barrier.release();
        for (threads[0..started]) |thread| thread.join();
    };
    for (&contexts) |*context| {
        threads[started] = try std.Thread.spawn(.{}, Submission.run, .{context});
        started += 1;
    }
    var waiting = false;
    for (0..5000) |_| {
        var waiters = try postgres.query(barrier.conn, "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=1514685256 AND objid=1 AND NOT granted");
        defer waiters.deinit();
        const count = try waiters.int(i64, 0, 0);
        if (count >= 2) {
            waiting = true;
            break;
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try postgres.exec(barrier.conn, "COMMIT");
    barrier.release();
    barrier_held = false;
    for (threads) |thread| thread.join();
    return verifyResults(&store, &contexts, waiting, failed.load(.acquire));
}

fn verifyResults(store: *Store, contexts: anytype, waiting: bool, failed: bool) !void {
    try std.testing.expect(waiting);
    try std.testing.expect(!failed);
    try matchesFullRebuild(store);
    var lease = store.pool.acquire();
    defer lease.release();
    const versions_sql = "SELECT string_agg(xmin::text,',' ORDER BY user_id,source) FROM zigcho.user_stats_history WHERE mode=0 AND day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400";
    var versions = try postgres.query(lease.conn, versions_sql);
    defer versions.deinit();
    var lower = contexts[0].score;
    lower.online_checksum = "97979797979797979797979797979793";
    lower.passed = false;
    lower.grade = "F";
    lower.total_score = 900;
    _ = try store.insertStableScore(contexts[0].user_id, lower, 0, "failed replay", 1000);
    var unchanged = try postgres.query(lease.conn, versions_sql);
    defer unchanged.deinit();
    try std.testing.expectEqualStrings(versions.value(0, 0), unchanged.value(0, 0));
    lower.passed = true;
    lower.grade = "X";
    lower.total_score = 500;
    lower.online_checksum = "97979797979797979797979797979795";
    _ = try store.insertStableScore(contexts[0].user_id, lower, 1, "lower replay", 1000);
    var lower_unchanged = try postgres.query(lease.conn, versions_sql);
    defer lower_unchanged.deinit();
    try std.testing.expectEqualStrings(versions.value(0, 0), lower_unchanged.value(0, 0));
    lower.passed = false;
    lower.grade = "F";
    lower.total_score = 400;
    try postgres.exec(lease.conn, "INSERT INTO zigcho.user_stats_history SELECT user_id,source,mode,day-86400,pp,global_rank FROM zigcho.user_stats_history WHERE mode=0 AND day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400 ON CONFLICT DO NOTHING; DELETE FROM zigcho.user_stats_history WHERE mode=0 AND day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400 AND source IN('all','stable','lazer')");
    lower.online_checksum = "97979797979797979797979797979794";
    _ = try store.insertStableScore(contexts[0].user_id, lower, 0, "failed replay", 1000);
    _ = try store.insertLazerScore(contexts[1].user_id, contexts[1].lazer_input, contexts[1].pp, "[]", "{\"great\":10}", "{}", "[]", "next day replay");
    try matchesFullRebuild(store);
    try store.setRestricted(3, contexts[0].user_id, true, "history fixture");
    try matchesFullRebuild(store);
    try store.setRestricted(3, contexts[0].user_id, false, "history fixture");
    try matchesFullRebuild(store);
}
