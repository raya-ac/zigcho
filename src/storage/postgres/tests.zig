const std = @import("std");
const domain = @import("../../domain.zig");
const postgres = @import("../../postgres.zig");
const stable_score = @import("../../stable_score.zig");
const beatmap = @import("../../beatmap.zig");
const lazer = @import("../../lazer.zig");
const stable_mods = @import("../../stable_mods.zig");
const media_contract = @import("../../media_contract.zig");
const site_replay = @import("../../site_replay.zig");
const user_json = @import("../../user_json.zig");
const bss = @import("../../bss.zig");
const server_control = @import("../../server_control.zig");
const anticheat_evidence = @import("../../anticheat_evidence.zig");
const stable_client = @import("../../stable_client.zig");
const database_sql = @import("database_sql");
const postgres_store = @import("../../postgres_store.zig");

const Store = postgres_store.Store;
const ClientHardware = postgres_store.ClientHardware;
const AnticheatObservation = postgres_store.AnticheatObservation;
const StableScoreGraceResult = postgres_store.StableScoreGraceResult;
const schema_version = postgres_store.schema_version;

test "postgres score submissions refresh both sides of a daily rank swap" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_HISTORY_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    const first_id = try store.register("history first", "history-first@example.test", "00000000000000000000000000000000");
    const second_id = try store.register("history second", "history-second@example.test", "11111111111111111111111111111111");
    const map_md5 = "99999999999999999999999999999991";
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var map = try postgres.query(lease.conn, "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,max_combo) VALUES(990000001,990000001,'99999999999999999999999999999991','history','rank swap','test','zigcho',3,10)");
        map.deinit();
    }

    const base: stable_score.Submission = .{
        .map_md5 = map_md5,
        .username = "history first",
        .online_checksum = "99999999999999999999999999999992",
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .ngeki = 0,
        .nkatu = 0,
        .nmiss = 0,
        .total_score = 1_000_000,
        .max_combo = 10,
        .perfect = true,
        .grade = "X",
        .mods = 0,
        .passed = true,
        .mode = 0,
        .client_time = "260825000000",
        .client_flags = "0",
    };
    _ = try store.insertStableScore(first_id, base, 40, "first replay", 12_000);
    var second_low = base;
    second_low.username = "history second";
    second_low.online_checksum = "99999999999999999999999999999993";
    second_low.total_score = 900_000;
    _ = try store.insertStableScore(second_id, second_low, 20, "second low replay", 12_000);
    try std.testing.expectEqual(@as(i32, 1), (try store.statsHistory(first_id, .all, 0)).points[0].global_rank);
    try std.testing.expectEqual(@as(i32, 2), (try store.statsHistory(second_id, .all, 0)).points[0].global_rank);

    var second_high = second_low;
    second_high.online_checksum = "99999999999999999999999999999994";
    second_high.total_score = 1_100_000;
    _ = try store.insertStableScore(second_id, second_high, 80, "second high replay", 12_000);
    const first_history = try store.statsHistory(first_id, .all, 0);
    const second_history = try store.statsHistory(second_id, .all, 0);
    try std.testing.expectEqual(@as(u8, 1), first_history.len);
    try std.testing.expectEqual(@as(u8, 1), second_history.len);
    try std.testing.expectEqual(@as(i32, 2), first_history.points[0].global_rank);
    try std.testing.expectEqual(@as(i32, 1), second_history.points[0].global_rank);
    {
        var buffers: [2][24]u8 = undefined;
        const first = try std.fmt.bufPrint(&buffers[0], "{d}", .{first_id});
        const second = try std.fmt.bufPrint(&buffers[1], "{d}", .{second_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var ranks = try postgres.queryParams(std.testing.allocator, lease.conn, "SELECT count(*),count(DISTINCT global_rank) FROM zigcho.user_stats_history WHERE source='all' AND mode=0 AND day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400 AND user_id IN($1,$2)", &.{ first, second });
        defer ranks.deinit();
        try std.testing.expectEqual(@as(i64, 2), try ranks.int(i64, 0, 0));
        try std.testing.expectEqual(@as(i64, 2), try ranks.int(i64, 0, 1));
    }
}

test "postgres concurrent first score submissions keep one best row per scope" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_STORE_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    {
        var lease = store.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "DELETE FROM zigcho.lazer_scores WHERE user_id IN(SELECT id FROM zigcho.users WHERE safe_name='best_race_pg'); DELETE FROM zigcho.scores WHERE user_id IN(SELECT id FROM zigcho.users WHERE safe_name='best_race_pg'); DELETE FROM zigcho.users WHERE safe_name='best_race_pg'; DELETE FROM zigcho.beatmaps WHERE id=2000000460");
    }
    const user_id = try store.register("best race pg", "best-race-pg@example.test", "46464646464646464646464646464646");
    const map_md5 = "46464646464646464646464646464640";
    try store.upsertBeatmapMeta(.{
        .id = 2_000_000_460,
        .set_id = 2_000_000_460,
        .artist = "concurrency",
        .title = "one winner",
        .version = "barrier",
        .creator = "zigcho",
        .total_length = 60,
    }, map_md5, 2, 4, 100);

    const Waiters = struct {
        fn two(conn: *postgres.c.PGconn) bool {
            for (0..100_000) |_| {
                var result = postgres.query(conn, "SELECT count(*) FROM pg_locks held JOIN pg_locks waiting ON waiting.locktype=held.locktype AND waiting.database IS NOT DISTINCT FROM held.database AND waiting.classid IS NOT DISTINCT FROM held.classid AND waiting.objid IS NOT DISTINCT FROM held.objid AND waiting.objsubid IS NOT DISTINCT FROM held.objsubid WHERE held.pid=pg_backend_pid() AND held.locktype='advisory' AND held.granted AND NOT waiting.granted") catch return false;
                const count = result.int(i64, 0, 0) catch {
                    result.deinit();
                    return false;
                };
                result.deinit();
                if (count >= 2) return true;
                std.Thread.yield() catch {};
            }
            return false;
        }
    };
    const StableSubmit = struct {
        store: *Store,
        user_id: i32,
        score: stable_score.Submission,
        pp: f64,
        started: *std.atomic.Value(bool),
        failed: *std.atomic.Value(bool),

        fn run(context: *@This()) void {
            context.started.store(true, .release);
            _ = context.store.insertStableScore(context.user_id, context.score, context.pp, "race replay", 10_000) catch {
                context.failed.store(true, .release);
                return;
            };
        }
    };
    const base: stable_score.Submission = .{
        .map_md5 = map_md5,
        .username = "best race pg",
        .online_checksum = "46464646464646464646464646464641",
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .ngeki = 0,
        .nkatu = 0,
        .nmiss = 0,
        .total_score = 500,
        .max_combo = 10,
        .perfect = true,
        .grade = "X",
        .mods = 1 << 29,
        .passed = true,
        .mode = 0,
        .client_time = "260829000000",
        .client_flags = "0",
    };
    var higher = base;
    higher.online_checksum = "46464646464646464646464646464642";
    higher.total_score = 600;
    var stable_first_started: std.atomic.Value(bool) = .init(false);
    var stable_second_started: std.atomic.Value(bool) = .init(false);
    var stable_failed: std.atomic.Value(bool) = .init(false);
    var stable_first: StableSubmit = .{ .store = &store, .user_id = user_id, .score = base, .pp = 900, .started = &stable_first_started, .failed = &stable_failed };
    var stable_second: StableSubmit = .{ .store = &store, .user_id = user_id, .score = higher, .pp = 100, .started = &stable_second_started, .failed = &stable_failed };
    var stable_barrier = store.pool.acquire();
    try postgres.exec(stable_barrier.conn, "BEGIN");
    var user_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    var stable_lock = try postgres.queryParams(std.testing.allocator, stable_barrier.conn, "SELECT pg_advisory_xact_lock(hashtextextended('zigcho:stable-best:'||$1||':'||$2||':0:scorev2',0))", &.{ user, map_md5 });
    stable_lock.deinit();
    const stable_thread_one = std.Thread.spawn(.{}, StableSubmit.run, .{&stable_first}) catch |err| {
        try postgres.exec(stable_barrier.conn, "ROLLBACK");
        stable_barrier.release();
        return err;
    };
    const stable_thread_two = std.Thread.spawn(.{}, StableSubmit.run, .{&stable_second}) catch |err| {
        try postgres.exec(stable_barrier.conn, "ROLLBACK");
        stable_barrier.release();
        stable_thread_one.join();
        return err;
    };
    while (!stable_first_started.load(.acquire) or !stable_second_started.load(.acquire)) std.Thread.yield() catch {};
    const stable_waited = Waiters.two(stable_barrier.conn);
    try postgres.exec(stable_barrier.conn, "COMMIT");
    stable_barrier.release();
    stable_thread_one.join();
    stable_thread_two.join();
    try std.testing.expect(stable_waited);
    try std.testing.expect(!stable_failed.load(.acquire));
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var winner = try postgres.queryParams(std.testing.allocator, lease.conn, "SELECT count(*),count(*) FILTER(WHERE best),max(score) FILTER(WHERE best) FROM zigcho.scores WHERE user_id=$1 AND map_md5=$2 AND mode=0 AND rank_namespace='scorev2'", &.{ user, map_md5 });
        defer winner.deinit();
        try std.testing.expectEqual(@as(i64, 2), try winner.int(i64, 0, 0));
        try std.testing.expectEqual(@as(i64, 1), try winner.int(i64, 0, 1));
        try std.testing.expectEqual(@as(i64, 600), try winner.int(i64, 0, 2));
    }

    const raw_lazer = "{\"beatmap_id\":2000000460,\"ruleset_id\":0,\"total_score\":500,\"total_score_without_mods\":500,\"accuracy\":1,\"max_combo\":10,\"passed\":true,\"rank\":\"X\",\"mods\":[],\"statistics\":{\"great\":10}}";
    var parsed_lazer = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw_lazer, .{});
    defer parsed_lazer.deinit();
    const lazer_first_input = try lazer.parseScore(parsed_lazer.value);
    var lazer_second_input = lazer_first_input;
    lazer_second_input.total_score = 600;
    lazer_second_input.total_score_without_mods = 600;
    const LazerSubmit = struct {
        store: *Store,
        user_id: i32,
        input: lazer.ScoreInput,
        started: *std.atomic.Value(bool),
        failed: *std.atomic.Value(bool),

        fn run(context: *@This()) void {
            context.started.store(true, .release);
            _ = context.store.insertLazerScore(context.user_id, context.input, 200, "[]", "{\"great\":10}", "{}", "[]", &.{}) catch {
                context.failed.store(true, .release);
                return;
            };
        }
    };
    var lazer_first_started: std.atomic.Value(bool) = .init(false);
    var lazer_second_started: std.atomic.Value(bool) = .init(false);
    var lazer_failed: std.atomic.Value(bool) = .init(false);
    var lazer_first: LazerSubmit = .{ .store = &store, .user_id = user_id, .input = lazer_first_input, .started = &lazer_first_started, .failed = &lazer_failed };
    var lazer_second: LazerSubmit = .{ .store = &store, .user_id = user_id, .input = lazer_second_input, .started = &lazer_second_started, .failed = &lazer_failed };
    var lazer_barrier = store.pool.acquire();
    try postgres.exec(lazer_barrier.conn, "BEGIN");
    var lazer_lock = try postgres.queryParams(std.testing.allocator, lazer_barrier.conn, "SELECT pg_advisory_xact_lock(hashtextextended('zigcho:lazer-best:'||$1||':2000000460:0:vanilla',0))", &.{user});
    lazer_lock.deinit();
    const lazer_thread_one = std.Thread.spawn(.{}, LazerSubmit.run, .{&lazer_first}) catch |err| {
        try postgres.exec(lazer_barrier.conn, "ROLLBACK");
        lazer_barrier.release();
        return err;
    };
    const lazer_thread_two = std.Thread.spawn(.{}, LazerSubmit.run, .{&lazer_second}) catch |err| {
        try postgres.exec(lazer_barrier.conn, "ROLLBACK");
        lazer_barrier.release();
        lazer_thread_one.join();
        return err;
    };
    while (!lazer_first_started.load(.acquire) or !lazer_second_started.load(.acquire)) std.Thread.yield() catch {};
    const lazer_waited = Waiters.two(lazer_barrier.conn);
    try postgres.exec(lazer_barrier.conn, "COMMIT");
    lazer_barrier.release();
    lazer_thread_one.join();
    lazer_thread_two.join();
    try std.testing.expect(lazer_waited);
    try std.testing.expect(!lazer_failed.load(.acquire));
    var lease = store.pool.acquire();
    defer lease.release();
    var winner = try postgres.queryParams(std.testing.allocator, lease.conn, "SELECT count(*),count(*) FILTER(WHERE best),max(total_score) FILTER(WHERE best) FROM zigcho.lazer_scores WHERE user_id=$1 AND beatmap_id=2000000460 AND ruleset_id=0 AND rank_namespace='vanilla'", &.{user});
    defer winner.deinit();
    try std.testing.expectEqual(@as(i64, 2), try winner.int(i64, 0, 0));
    try std.testing.expectEqual(@as(i64, 1), try winner.int(i64, 0, 1));
    try std.testing.expectEqual(@as(i64, 600), try winner.int(i64, 0, 2));
    try postgres.exec(lease.conn, "DELETE FROM zigcho.lazer_scores WHERE user_id IN(SELECT id FROM zigcho.users WHERE safe_name='best_race_pg'); DELETE FROM zigcho.scores WHERE user_id IN(SELECT id FROM zigcho.users WHERE safe_name='best_race_pg'); DELETE FROM zigcho.users WHERE safe_name='best_race_pg'; DELETE FROM zigcho.beatmaps WHERE id=2000000460");
}

test "postgres runtime migrates through stable score grace schema forty eight" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_MIGRATE_URL") orelse return error.SkipZigTest;
    {
        var old_store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
        defer old_store.close();
        try old_store.migrate();
        var previous = old_store.pool.acquire();
        defer previous.release();
        try postgres.exec(previous.conn, "DROP TABLE zigcho.stable_score_sessions; DROP TABLE zigcho.server_controls; DROP TABLE IF EXISTS zigcho.score_replay_views; DROP TABLE zigcho.user_stats_history; DROP TABLE zigcho.lazer_ranked_matches; DROP TABLE zigcho.lazer_ranked_ratings; DROP TABLE zigcho.lazer_multiplayer_room_history; DROP TABLE zigcho.beatmapset_metadata; DROP TABLE zigcho.upstream_user_profiles; ALTER TABLE zigcho.beatmaps DROP COLUMN creator_id,DROP COLUMN upstream_plays,DROP COLUMN upstream_passes,DROP COLUMN hit_length; DROP TABLE zigcho.upstream_users; DROP TABLE zigcho.beatmap_submission_maps; DROP TABLE zigcho.beatmap_submissions; DROP TABLE zigcho.bss_counters; DROP TABLE zigcho.profile_score_pins; DROP TABLE zigcho.beatmap_tag_votes; DROP TABLE zigcho.lazer_reports; DROP TABLE zigcho.replay_objects; DROP TABLE zigcho.lazer_presence; DROP TABLE zigcho.team_assets; DROP TABLE zigcho.team_applications; DROP TABLE zigcho.team_members; DROP TABLE zigcho.teams; DROP TABLE zigcho.user_banners; DROP TABLE zigcho.user_name_changes; ALTER TABLE zigcho.users DROP COLUMN username_changes,DROP COLUMN username_changed_at; DROP TABLE zigcho.lazer_comment_reports; DROP TABLE zigcho.lazer_comment_votes; DROP TABLE zigcho.lazer_comments");
        try postgres.exec(previous.conn, "DROP INDEX zigcho.scores_one_best_per_scope; DROP INDEX zigcho.lazer_scores_one_best_per_scope; DROP TABLE zigcho.maintenance_markers; ALTER TABLE zigcho.scores DROP COLUMN star_rating; ALTER TABLE zigcho.lazer_scores DROP CONSTRAINT lazer_scores_legacy_total_score_range; ALTER TABLE zigcho.lazer_scores DROP COLUMN star_rating,DROP COLUMN total_score_without_mods; ALTER TABLE zigcho.lazer_scores ALTER COLUMN legacy_total_score TYPE bigint USING legacy_total_score::bigint; ALTER TABLE zigcho.beatmap_archives DROP COLUMN object_bytes; DROP TABLE zigcho.user_achievements; ALTER TABLE zigcho.direct_messages DROP COLUMN chat_message_id; DROP INDEX zigcho.direct_messages_sender_uuid; ALTER TABLE zigcho.direct_messages DROP COLUMN is_action,DROP COLUMN client_uuid; DROP TABLE zigcho.user_blocks; DROP TABLE zigcho.lazer_channel_reads; DROP INDEX zigcho.chat_messages_sender_uuid; ALTER TABLE zigcho.chat_messages DROP COLUMN is_action,DROP COLUMN client_uuid; DROP TABLE zigcho.anticheat_replay_fingerprints; DROP TABLE zigcho.anticheat_observations; DROP TABLE zigcho.anticheat_review_exclusions; DROP TABLE zigcho.user_avatars; ALTER TABLE zigcho.users DROP COLUMN bio,DROP COLUMN preferred_mode,DROP COLUMN profile_source,DROP COLUMN profile_title,DROP COLUMN profile_pronouns,DROP COLUMN profile_location,DROP COLUMN profile_website,DROP COLUMN profile_accent,DROP COLUMN show_country,DROP COLUMN show_profile_stats,DROP COLUMN show_recent_scores; DROP INDEX zigcho.lazer_scores_user_best; DROP TABLE zigcho.lazer_score_tokens; ALTER TABLE zigcho.lazer_scores DROP COLUMN rank,DROP COLUMN maximum_statistics_json,DROP COLUMN pauses_json,DROP COLUMN pp,DROP COLUMN best; TRUNCATE zigcho.schema_migrations; INSERT INTO zigcho.schema_migrations(version) VALUES(20)");
        try postgres.exec(previous.conn, "ALTER TABLE zigcho.beatmap_archives ALTER COLUMN osz_file SET NOT NULL; ALTER TABLE zigcho.beatmap_media ALTER COLUMN data SET NOT NULL");
        try postgres.exec(previous.conn, "DELETE FROM zigcho.lazer_scores WHERE id=2147483000; DELETE FROM zigcho.beatmaps WHERE id=2147483000; DELETE FROM zigcho.users WHERE id=2147483000; INSERT INTO zigcho.users(id,name,safe_name,password_hash,password_salt) VALUES(2147483000,'schema43 migration','schema43_migration',decode('00','hex'),decode('00','hex')); INSERT INTO zigcho.stats(user_id,mode,ranked_score,total_score,pp,plays,play_time,total_hits,accuracy,max_combo) VALUES(2147483000,0,999999,999999,999999,999,999,999,0.01,999); INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status) VALUES(2147483000,2147483000,'fffffffffffffffffffffffffffffff0','artist','title','diff','mapper',3); INSERT INTO zigcho.lazer_scores(id,user_id,beatmap_id,ruleset_id,total_score,legacy_total_score,accuracy,max_combo,passed,mods_json,statistics_json,rank_namespace) VALUES(2147483000,2147483000,2147483000,0,987654,900000,0.98,321,true,'[]'::jsonb,'{}'::jsonb,'vanilla')");
    }
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    try std.testing.expect(!store.external_only);
    var lease = store.pool.acquire();
    defer lease.release();
    var result = try postgres.query(lease.conn, "SELECT max(version),(to_regclass('zigcho.chat_messages') IS NOT NULL)::int,(to_regclass('zigcho.chat_channels') IS NOT NULL)::int,(to_regclass('zigcho.beatmap_rank_requests') IS NOT NULL)::int,(to_regclass('zigcho.beatmap_rank_events') IS NOT NULL)::int,(to_regclass('zigcho.moderation_appeals') IS NOT NULL)::int,(to_regclass('zigcho.score_pins') IS NOT NULL)::int,(to_regclass('zigcho.beatmap_hydration_failures') IS NOT NULL)::int,(to_regclass('zigcho.screenshots') IS NOT NULL)::int,(to_regclass('zigcho.beatmap_media') IS NOT NULL)::int,(to_regclass('zigcho.beatmap_comments') IS NOT NULL)::int,(to_regclass('zigcho.direct_messages') IS NOT NULL)::int,(to_regclass('zigcho.lazer_score_tokens') IS NOT NULL)::int,(to_regclass('zigcho.user_avatars') IS NOT NULL)::int,(to_regclass('zigcho.anticheat_observations') IS NOT NULL)::int,(to_regclass('zigcho.anticheat_replay_fingerprints') IS NOT NULL)::int,(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='users' AND column_name IN('bio','preferred_mode','profile_source')),(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='lazer_scores' AND column_name IN('pp','best')),(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='users' AND column_name IN('profile_title','profile_pronouns','profile_location','profile_website','profile_accent','show_country','show_profile_stats','show_recent_scores')),(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='chat_messages' AND column_name IN('is_action','client_uuid')),(to_regclass('zigcho.lazer_channel_reads') IS NOT NULL)::int,(to_regclass('zigcho.user_blocks') IS NOT NULL)::int,(to_regclass('zigcho.user_achievements') IS NOT NULL)::int,(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='direct_messages' AND column_name IN('is_action','client_uuid')),(to_regclass('zigcho.direct_messages_sender_uuid') IS NOT NULL)::int,(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name IN('scores','lazer_scores') AND column_name='star_rating'),(SELECT count(*) FROM information_schema.tables WHERE table_schema='zigcho' AND table_name IN('lazer_comments','user_name_changes','user_banners','teams','team_members','team_applications','team_assets','lazer_presence','replay_objects','lazer_reports','beatmap_tag_votes','profile_score_pins')),(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='users' AND column_name IN('username_changes','username_changed_at')),(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='direct_messages' AND column_name='chat_message_id'),(to_regclass('zigcho.direct_messages_chat_message') IS NOT NULL)::int,(SELECT count(*) FROM pg_constraint WHERE connamespace='zigcho'::regnamespace AND conname='direct_messages_chat_message_id_fkey' AND convalidated) FROM zigcho.schema_migrations");
    defer result.deinit();
    try std.testing.expectEqual(@as(i32, schema_version), try result.int(i32, 0, 0));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 1));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 2));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 3));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 4));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 5));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 6));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 7));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 8));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 9));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 10));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 11));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 12));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 13));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 14));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 15));
    try std.testing.expectEqual(@as(i32, 3), try result.int(i32, 0, 16));
    try std.testing.expectEqual(@as(i32, 2), try result.int(i32, 0, 17));
    try std.testing.expectEqual(@as(i32, 8), try result.int(i32, 0, 18));
    try std.testing.expectEqual(@as(i32, 2), try result.int(i32, 0, 19));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 20));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 21));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 22));
    try std.testing.expectEqual(@as(i32, 2), try result.int(i32, 0, 23));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 24));
    try std.testing.expectEqual(@as(i32, 2), try result.int(i32, 0, 25));
    try std.testing.expectEqual(@as(i32, 12), try result.int(i32, 0, 26));
    try std.testing.expectEqual(@as(i32, 2), try result.int(i32, 0, 27));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 28));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 29));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 30));
    var anticheat_exclusion_schema = try postgres.query(lease.conn, "SELECT (to_regclass('zigcho.anticheat_review_exclusions') IS NOT NULL)::int,(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='anticheat_observations' AND column_name='review_exclusion_id'),(to_regclass('zigcho.anticheat_observations_review_queue') IS NOT NULL)::int,(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='anticheat_replay_fingerprints' AND column_name='replay_content_sha256'),(to_regclass('zigcho.anticheat_replay_fingerprints_content') IS NOT NULL)::int");
    defer anticheat_exclusion_schema.deinit();
    try std.testing.expectEqual(@as(i32, 1), try anticheat_exclusion_schema.int(i32, 0, 0));
    try std.testing.expectEqual(@as(i64, 1), try anticheat_exclusion_schema.int(i64, 0, 1));
    try std.testing.expectEqual(@as(i32, 1), try anticheat_exclusion_schema.int(i32, 0, 2));
    try std.testing.expectEqual(@as(i64, 1), try anticheat_exclusion_schema.int(i64, 0, 3));
    try std.testing.expectEqual(@as(i32, 1), try anticheat_exclusion_schema.int(i32, 0, 4));
    var stable_score_session_schema = try postgres.query(lease.conn, "SELECT (to_regclass('zigcho.stable_score_sessions') IS NOT NULL)::int,(SELECT count(*) FROM pg_indexes WHERE schemaname='zigcho' AND indexname IN('stable_score_sessions_one_current','stable_score_sessions_user_grace'))");
    defer stable_score_session_schema.deinit();
    try std.testing.expectEqual(@as(i32, 1), try stable_score_session_schema.int(i32, 0, 0));
    try std.testing.expectEqual(@as(i64, 2), try stable_score_session_schema.int(i64, 0, 1));
    var ranked_schema = try postgres.query(lease.conn, "SELECT (to_regclass('zigcho.lazer_ranked_ratings') IS NOT NULL)::int,(to_regclass('zigcho.lazer_ranked_matches') IS NOT NULL)::int");
    defer ranked_schema.deinit();
    try std.testing.expectEqual(@as(i32, 1), try ranked_schema.int(i32, 0, 0));
    try std.testing.expectEqual(@as(i32, 1), try ranked_schema.int(i32, 0, 1));
    var room_cursor_schema = try postgres.query(lease.conn, "SELECT (SELECT (data_type='bigint')::int FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='lazer_channel_reads' AND column_name='channel_id'),(SELECT count(*) FROM pg_constraint WHERE connamespace='zigcho'::regnamespace AND conrelid='zigcho.lazer_channel_reads'::regclass AND conname='lazer_channel_reads_channel_id_check' AND convalidated)");
    defer room_cursor_schema.deinit();
    try std.testing.expectEqual(@as(i32, 1), try room_cursor_schema.int(i32, 0, 0));
    try std.testing.expectEqual(@as(i32, 1), try room_cursor_schema.int(i32, 0, 1));
    var history_schema = try postgres.query(lease.conn, "SELECT (to_regclass('zigcho.user_stats_history') IS NOT NULL)::int,(to_regclass('zigcho.user_stats_history_lookup') IS NOT NULL)::int,(to_regclass('zigcho.user_stats_history_retention') IS NOT NULL)::int,(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='user_stats_history' AND column_name IN('user_id','source','mode','day','pp','global_rank'))");
    defer history_schema.deinit();
    try std.testing.expectEqual(@as(i32, 1), try history_schema.int(i32, 0, 0));
    try std.testing.expectEqual(@as(i32, 1), try history_schema.int(i32, 0, 1));
    try std.testing.expectEqual(@as(i32, 1), try history_schema.int(i32, 0, 2));
    try std.testing.expectEqual(@as(i32, 6), try history_schema.int(i32, 0, 3));
    var replay_views_schema = try postgres.query(lease.conn, "SELECT (to_regclass('zigcho.score_replay_views') IS NOT NULL)::int,(to_regclass('zigcho.score_replay_views_owner') IS NOT NULL)::int,(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='score_replay_views' AND column_name IN('source','score_id','viewer_id','owner_id','mode','rank_namespace','viewed_at'))");
    defer replay_views_schema.deinit();
    try std.testing.expectEqual(@as(i32, 1), try replay_views_schema.int(i32, 0, 0));
    try std.testing.expectEqual(@as(i32, 1), try replay_views_schema.int(i32, 0, 1));
    try std.testing.expectEqual(@as(i32, 7), try replay_views_schema.int(i32, 0, 2));
    var friends_schema = try postgres.query(lease.conn, "SELECT (to_regclass('zigcho.friends_inbound') IS NOT NULL)::int");
    defer friends_schema.deinit();
    try std.testing.expectEqual(@as(i32, 1), try friends_schema.int(i32, 0, 0));
    var score_schema = try postgres.query(lease.conn, "SELECT total_score,total_score_without_mods,(legacy_total_score IS NULL)::int,(SELECT (data_type='bigint')::int FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='lazer_scores' AND column_name='total_score_without_mods'),(SELECT (data_type='integer')::int FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='lazer_scores' AND column_name='legacy_total_score') FROM zigcho.lazer_scores WHERE id=2147483000");
    defer score_schema.deinit();
    try std.testing.expectEqual(@as(i64, 987654), try score_schema.int(i64, 0, 0));
    try std.testing.expectEqual(@as(i64, 900000), try score_schema.int(i64, 0, 1));
    try std.testing.expectEqual(@as(i32, 0), try score_schema.int(i32, 0, 2));
    try std.testing.expectEqual(@as(i32, 1), try score_schema.int(i32, 0, 3));
    try std.testing.expectEqual(@as(i32, 1), try score_schema.int(i32, 0, 4));
    var control_schema = try postgres.query(lease.conn, "SELECT count(*),count(DISTINCT key),bool_and(enabled)::int FROM zigcho.server_controls");
    defer control_schema.deinit();
    try std.testing.expectEqual(@as(i64, server_control.definitions.len), try control_schema.int(i64, 0, 0));
    try std.testing.expectEqual(@as(i64, server_control.definitions.len), try control_schema.int(i64, 0, 1));
    try std.testing.expectEqual(@as(i32, 1), try control_schema.int(i32, 0, 2));
    var bss_schema = try postgres.query(lease.conn, "SELECT (to_regclass('zigcho.beatmap_submissions') IS NOT NULL)::int,(to_regclass('zigcho.beatmap_submission_maps') IS NOT NULL)::int,(to_regclass('zigcho.bss_counters') IS NOT NULL)::int,(SELECT count(*) FROM zigcho.bss_counters),(SELECT min(next_id) FROM zigcho.bss_counters),(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='beatmap_submissions' AND column_name='replacement_set_id'),(to_regclass('zigcho.beatmap_submissions_replacement') IS NOT NULL)::int");
    defer bss_schema.deinit();
    try std.testing.expectEqual(@as(i32, 1), try bss_schema.int(i32, 0, 0));
    try std.testing.expectEqual(@as(i32, 1), try bss_schema.int(i32, 0, 1));
    try std.testing.expectEqual(@as(i32, 1), try bss_schema.int(i32, 0, 2));
    try std.testing.expectEqual(@as(i32, 2), try bss_schema.int(i32, 0, 3));
    try std.testing.expect((try bss_schema.int(i64, 0, 4)) >= @as(i64, bss.private_id_floor));
    try std.testing.expectEqual(@as(i32, 1), try bss_schema.int(i32, 0, 5));
    try std.testing.expectEqual(@as(i32, 1), try bss_schema.int(i32, 0, 6));
    var best_score_schema = try postgres.query(lease.conn, "SELECT (to_regclass('zigcho.scores_one_best_per_scope') IS NOT NULL)::int,(to_regclass('zigcho.lazer_scores_one_best_per_scope') IS NOT NULL)::int,(to_regclass('zigcho.maintenance_markers') IS NOT NULL)::int,(SELECT count(*) FROM zigcho.maintenance_markers)");
    defer best_score_schema.deinit();
    try std.testing.expectEqual(@as(i32, 1), try best_score_schema.int(i32, 0, 0));
    try std.testing.expectEqual(@as(i32, 1), try best_score_schema.int(i32, 0, 1));
    try std.testing.expectEqual(@as(i32, 1), try best_score_schema.int(i32, 0, 2));
    try std.testing.expectEqual(@as(i64, 0), try best_score_schema.int(i64, 0, 3));
    var rebuilt_stats = try postgres.query(lease.conn, "SELECT st.total_score,st.pp,st.plays,st.play_time,st.total_hits,st.accuracy,st.max_combo,h.pp,h.global_rank,coalesce(s.legacy_total_score,s.total_score) FROM zigcho.stats st JOIN zigcho.user_stats_history h ON h.user_id=st.user_id AND h.source='all' AND h.mode=st.mode AND h.day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400 JOIN zigcho.lazer_scores s ON s.user_id=st.user_id AND s.ruleset_id=st.mode WHERE st.user_id=2147483000 AND st.mode=0");
    defer rebuilt_stats.deinit();
    try std.testing.expectEqual(@as(usize, 1), rebuilt_stats.rows());
    try std.testing.expectEqual(try rebuilt_stats.int(i64, 0, 9), try rebuilt_stats.int(i64, 0, 0));
    try std.testing.expectEqual(@as(i32, 1), try rebuilt_stats.int(i32, 0, 2));
    try std.testing.expectEqual(@as(i64, 0), try rebuilt_stats.int(i64, 0, 3));
    try std.testing.expectEqual(@as(i64, 0), try rebuilt_stats.int(i64, 0, 4));
    try std.testing.expectApproxEqAbs(@as(f64, 0.98), try rebuilt_stats.float(f64, 0, 5), 0.000001);
    try std.testing.expectEqual(@as(i32, 321), try rebuilt_stats.int(i32, 0, 6));
    try std.testing.expectEqual(try rebuilt_stats.int(i32, 0, 1), try rebuilt_stats.int(i32, 0, 7));
    try std.testing.expectEqual(@as(i32, 1), try rebuilt_stats.int(i32, 0, 8));
    try std.testing.expect((try rebuilt_stats.int(i64, 0, 0)) != 999999);
    try std.testing.expect((try rebuilt_stats.int(i32, 0, 1)) != 999999);
    const kai = (try store.userById(std.testing.allocator, 3)).?;
    defer {
        std.testing.allocator.free(kai.name);
        std.testing.allocator.free(kai.safe_name);
    }
    try std.testing.expectEqualStrings("kai", kai.safe_name);
    try std.testing.expect(kai.privileges & (1 << 13) != 0);
    try std.testing.expect(kai.privileges & (1 << 14) != 0);
    var reopened = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer reopened.close();
    try reopened.migrate();
    var reopened_lease = reopened.pool.acquire();
    defer reopened_lease.release();
    var reopened_state = try postgres.query(reopened_lease.conn, "SELECT (SELECT count(*) FROM zigcho.maintenance_markers),(SELECT st.pp FROM zigcho.stats st WHERE st.user_id=2147483000 AND st.mode=0),(SELECT h.pp FROM zigcho.user_stats_history h WHERE h.user_id=2147483000 AND h.source='all' AND h.mode=0 AND h.day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400)");
    defer reopened_state.deinit();
    try std.testing.expectEqual(@as(i64, 0), try reopened_state.int(i64, 0, 0));
    try std.testing.expectEqual(try reopened_state.int(i32, 0, 1), try reopened_state.int(i32, 0, 2));
}

test "postgres best score migration repairs duplicate winners deterministically" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_MIGRATE_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    {
        var lease = store.pool.acquire();
        defer lease.release();
        try postgres.exec(
            lease.conn,
            "BEGIN;" ++
                "DROP INDEX zigcho.scores_one_best_per_scope;" ++
                "DROP INDEX zigcho.lazer_scores_one_best_per_scope;" ++
                "DELETE FROM zigcho.lazer_scores WHERE user_id=2147482998;" ++
                "DELETE FROM zigcho.scores WHERE user_id=2147482998;" ++
                "DELETE FROM zigcho.stats WHERE user_id=2147482998;" ++
                "DELETE FROM zigcho.users WHERE id=2147482998;" ++
                "DELETE FROM zigcho.beatmaps WHERE id=2147482998;" ++
                "INSERT INTO zigcho.users(id,name,safe_name,password_hash,password_salt) VALUES(2147482998,'best migration','best_migration',decode('00','hex'),decode('00','hex'));" ++
                "INSERT INTO zigcho.stats(user_id,mode,ranked_score,total_score,pp,plays,play_time,total_hits,accuracy,max_combo) VALUES(2147482998,0,999999,999999,999999,999,999,999,0.01,999);" ++
                "INSERT INTO zigcho.user_stats_history(user_id,source,mode,day,pp,global_rank) VALUES(2147482998,'all',0,(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400,999999,999) ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp,global_rank=excluded.global_rank;" ++
                "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status) VALUES(2147482998,2147482998,'46464646464646464646464646464646','migration','best repair','test','zigcho',3);" ++
                "INSERT INTO zigcho.scores(id,user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,rank_namespace,best) VALUES" ++
                "(2147482901,2147482998,'46464646464646464646464646464646',0,0,500,900,1,1,1,0,0,0,0,0,true,true,'vanilla',true)," ++
                "(2147482902,2147482998,'46464646464646464646464646464646',0,8,700,100,1,1,1,0,0,0,0,0,true,true,'vanilla',true)," ++
                "(2147482903,2147482998,'46464646464646464646464646464646',0,16,999,999,0,1,0,0,0,1,0,0,false,false,'vanilla',true)," ++
                "(2147482904,2147482998,'46464646464646464646464646464646',0,128,900,100,1,1,1,0,0,0,0,0,true,true,'relax',true)," ++
                "(2147482905,2147482998,'46464646464646464646464646464646',0,136,100,200,1,1,1,0,0,0,0,0,true,true,'relax',true)," ++
                "(2147482906,2147482998,'46464646464646464646464646464646',0,536870912,300,1000,1,1,1,0,0,0,0,0,true,true,'scorev2',true)," ++
                "(2147482907,2147482998,'46464646464646464646464646464646',0,536870920,400,1,1,1,1,0,0,0,0,0,true,true,'scorev2',true)," ++
                "(2147482908,2147482998,'46464646464646464646464646464646',0,8192,900,100,1,1,1,0,0,0,0,0,true,true,'autopilot',true)," ++
                "(2147482909,2147482998,'46464646464646464646464646464646',0,8200,100,200,1,1,1,0,0,0,0,0,true,true,'autopilot',true)," ++
                "(2147482910,2147482998,'46464646464646464646464646464646',0,64,700,500,1,1,1,0,0,0,0,0,true,true,'vanilla',true);" ++
                "INSERT INTO zigcho.lazer_scores(id,user_id,beatmap_id,ruleset_id,total_score,total_score_without_mods,accuracy,max_combo,passed,rank,mods_json,statistics_json,rank_namespace,pp,best) VALUES" ++
                "(2147482910,2147482998,2147482998,0,600,600,1,1,true,'A','[]'::jsonb,'{}'::jsonb,'vanilla',200,true)," ++
                "(2147482911,2147482998,2147482998,0,500,500,1,1,true,'A','[]'::jsonb,'{}'::jsonb,'vanilla',200,true)," ++
                "(2147482912,2147482998,2147482998,0,600,600,1,1,true,'A','[]'::jsonb,'{}'::jsonb,'vanilla',200,true)," ++
                "(2147482913,2147482998,2147482998,0,999,999,0,1,false,'F','[]'::jsonb,'{}'::jsonb,'vanilla',900,true);" ++
                "DROP TABLE zigcho.stable_score_sessions;" ++
                "DELETE FROM zigcho.maintenance_markers WHERE key='schema46_ranked_stats_rebuild';" ++
                "DELETE FROM zigcho.schema_migrations WHERE version=47;" ++
                "DELETE FROM zigcho.schema_migrations WHERE version=46;" ++
                "COMMIT",
        );
    }

    // Simulate the process dying after the structural migration committed but
    // before the derived-stat repair ran. The marker must survive that gap.
    {
        var lease = store.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, database_sql.postgresMigration(46));
        var pending = try postgres.query(lease.conn, "SELECT (SELECT count(*) FROM zigcho.maintenance_markers WHERE key='schema46_ranked_stats_rebuild'),(SELECT pp FROM zigcho.stats WHERE user_id=2147482998 AND mode=0)");
        defer pending.deinit();
        try std.testing.expectEqual(@as(i64, 1), try pending.int(i64, 0, 0));
        try std.testing.expectEqual(@as(i32, 999999), try pending.int(i32, 0, 1));
    }
    try store.migrate();
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var repaired = try postgres.query(lease.conn, "SELECT (SELECT max(version) FROM zigcho.schema_migrations),(SELECT count(*) FROM zigcho.scores WHERE user_id=2147482998 AND best),(SELECT id FROM zigcho.scores WHERE user_id=2147482998 AND rank_namespace='vanilla' AND best),(SELECT id FROM zigcho.scores WHERE user_id=2147482998 AND rank_namespace='relax' AND best),(SELECT id FROM zigcho.scores WHERE user_id=2147482998 AND rank_namespace='scorev2' AND best),(SELECT id FROM zigcho.scores WHERE user_id=2147482998 AND rank_namespace='autopilot' AND best),(SELECT count(*) FROM zigcho.lazer_scores WHERE user_id=2147482998 AND best),(SELECT id FROM zigcho.lazer_scores WHERE user_id=2147482998 AND best),(SELECT count(*) FROM pg_index WHERE indexrelid='zigcho.scores_one_best_per_scope'::regclass AND indisunique AND indpred IS NOT NULL),(SELECT count(*) FROM pg_index WHERE indexrelid='zigcho.lazer_scores_one_best_per_scope'::regclass AND indisunique AND indpred IS NOT NULL),(SELECT count(*) FROM zigcho.maintenance_markers WHERE key='schema46_ranked_stats_rebuild'),(SELECT pp FROM zigcho.stats WHERE user_id=2147482998 AND mode=0),(SELECT plays FROM zigcho.stats WHERE user_id=2147482998 AND mode=0),(SELECT pp FROM zigcho.user_stats_history WHERE user_id=2147482998 AND source='all' AND mode=0 AND day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400),(SELECT global_rank FROM zigcho.user_stats_history WHERE user_id=2147482998 AND source='all' AND mode=0 AND day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400)");
        defer repaired.deinit();
        try std.testing.expectEqual(@as(i32, schema_version), try repaired.int(i32, 0, 0));
        try std.testing.expectEqual(@as(i64, 4), try repaired.int(i64, 0, 1));
        try std.testing.expectEqual(@as(i64, 2147482902), try repaired.int(i64, 0, 2));
        try std.testing.expectEqual(@as(i64, 2147482905), try repaired.int(i64, 0, 3));
        try std.testing.expectEqual(@as(i64, 2147482907), try repaired.int(i64, 0, 4));
        try std.testing.expectEqual(@as(i64, 2147482909), try repaired.int(i64, 0, 5));
        try std.testing.expectEqual(@as(i64, 1), try repaired.int(i64, 0, 6));
        try std.testing.expectEqual(@as(i64, 2147482910), try repaired.int(i64, 0, 7));
        try std.testing.expectEqual(@as(i64, 1), try repaired.int(i64, 0, 8));
        try std.testing.expectEqual(@as(i64, 1), try repaired.int(i64, 0, 9));
        try std.testing.expectEqual(@as(i64, 0), try repaired.int(i64, 0, 10));
        const rebuilt_pp = try repaired.int(i32, 0, 11);
        try std.testing.expect(rebuilt_pp > 0 and rebuilt_pp != 999999);
        try std.testing.expect((try repaired.int(i32, 0, 12)) != 999);
        try std.testing.expectEqual(rebuilt_pp, try repaired.int(i32, 0, 13));
        try std.testing.expectEqual(@as(i32, 1), try repaired.int(i32, 0, 14));
    }

    var reopened = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer reopened.close();
    try reopened.migrate();
    var lease = reopened.pool.acquire();
    defer lease.release();
    var after_restart = try postgres.query(lease.conn, "SELECT (SELECT count(*) FROM zigcho.scores WHERE user_id=2147482998 AND best),(SELECT count(*) FROM zigcho.lazer_scores WHERE user_id=2147482998 AND best),(SELECT count(*) FROM zigcho.maintenance_markers WHERE key='schema46_ranked_stats_rebuild'),(SELECT pp FROM zigcho.stats WHERE user_id=2147482998 AND mode=0),(SELECT pp FROM zigcho.user_stats_history WHERE user_id=2147482998 AND source='all' AND mode=0 AND day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400)");
    defer after_restart.deinit();
    try std.testing.expectEqual(@as(i64, 4), try after_restart.int(i64, 0, 0));
    try std.testing.expectEqual(@as(i64, 1), try after_restart.int(i64, 0, 1));
    try std.testing.expectEqual(@as(i64, 0), try after_restart.int(i64, 0, 2));
    try std.testing.expectEqual(try after_restart.int(i32, 0, 3), try after_restart.int(i32, 0, 4));
}

test "postgres room chat acknowledgements stay monotonic across reconnect" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_ROOM_CHAT_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    errdefer store.close();
    try store.migrate();
    {
        var lease = store.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "DELETE FROM zigcho.users WHERE safe_name='room_cursor_pg'");
    }
    const user_id = try store.register("room cursor pg", "room-cursor-pg@example.test", "00000000000000000000000000000000");

    const first = try store.recordLazerRoomMessage(std.testing.allocator, user_id, 41, "postgres room first", false, "41000000-0000-0000-0000-000000000001");
    defer std.testing.allocator.free(first.json);
    const second = try store.recordLazerRoomMessage(std.testing.allocator, user_id, 41, "postgres room second", false, "41000000-0000-0000-0000-000000000002");
    defer std.testing.allocator.free(second.json);
    const foreign = try store.recordLazerRoomMessage(std.testing.allocator, user_id, 42, "postgres other room", false, "41000000-0000-0000-0000-000000000003");
    defer std.testing.allocator.free(foreign.json);
    const public = try store.recordLazerPublicMessage(std.testing.allocator, user_id, "#lazer", "postgres public unread", false, "41000000-0000-0000-0000-000000000004");
    defer std.testing.allocator.free(public.json);

    const parsed_first = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, first.json, .{});
    defer parsed_first.deinit();
    const first_id = parsed_first.value.object.get("message_id").?.integer;
    const parsed_second = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, second.json, .{});
    defer parsed_second.deinit();
    const second_id = parsed_second.value.object.get("message_id").?.integer;
    const parsed_foreign = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, foreign.json, .{});
    defer parsed_foreign.deinit();
    const foreign_id = parsed_foreign.value.object.get("message_id").?.integer;

    try std.testing.expectEqual(@as(?i64, null), (try store.lazerRoomChannelCursor(user_id, 41)).last_read_id);
    try store.markLazerRoomChannelRead(user_id, 41, first_id);
    try store.markLazerRoomChannelRead(user_id, 41, first_id);
    try store.markLazerRoomChannelRead(user_id, 41, second_id);
    try store.markLazerRoomChannelRead(user_id, 41, first_id);
    try std.testing.expectEqual(second_id, (try store.lazerRoomChannelCursor(user_id, 41)).last_read_id.?);
    try std.testing.expectError(error.ChatMessageNotFound, store.markLazerRoomChannelRead(user_id, 41, foreign_id));

    store.close();
    var reopened = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer reopened.close();
    try reopened.migrate();
    try std.testing.expectEqual(second_id, (try reopened.lazerRoomChannelCursor(user_id, 41)).last_read_id.?);
    const reconnect_feed = try reopened.lazerAllMessagesForRoomJson(std.testing.allocator, user_id, 41, 0, 100);
    defer std.testing.allocator.free(reconnect_feed);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_feed, "postgres room first") == null);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_feed, "postgres room second") == null);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_feed, "postgres other room") == null);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_feed, "postgres public unread") != null);

    const third = try reopened.recordLazerRoomMessage(std.testing.allocator, user_id, 41, "postgres room third", false, "41000000-0000-0000-0000-000000000005");
    defer std.testing.allocator.free(third.json);
    const after_reconnect = try reopened.lazerAllMessagesForRoomJson(std.testing.allocator, user_id, 41, 0, 100);
    defer std.testing.allocator.free(after_reconnect);
    try std.testing.expect(std.mem.indexOf(u8, after_reconnect, "postgres room first") == null);
    try std.testing.expect(std.mem.indexOf(u8, after_reconnect, "postgres room second") == null);
    try std.testing.expect(std.mem.indexOf(u8, after_reconnect, "postgres room third") != null);
}

test "postgres ranked result updates two users atomically and deduplicates its room" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_RANKED_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    {
        var lease = store.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "DELETE FROM zigcho.lazer_ranked_matches WHERE room_id=9000000039; DELETE FROM zigcho.users WHERE safe_name IN('ranked_pg_one','ranked_pg_two')");
    }
    const winner_id = try store.register("ranked pg one", "ranked-pg-one@example.test", "00000000000000000000000000000000");
    const loser_id = try store.register("ranked pg two", "ranked-pg-two@example.test", "11111111111111111111111111111111");
    try std.testing.expectEqual(@as(i32, 1500), (try store.lazerRankedRating(winner_id, 2)).rating);

    const first = try store.applyLazerRankedResult(9_000_000_039, 2, winner_id, loser_id);
    try std.testing.expect(first.applied);
    try std.testing.expectEqual(@as(i32, 1516), first.winner_rating_after);
    try std.testing.expectEqual(@as(i32, 1484), first.loser_rating_after);
    const repeat = try store.applyLazerRankedResult(9_000_000_039, 2, winner_id, loser_id);
    try std.testing.expect(!repeat.applied);
    try std.testing.expectEqual(@as(i32, 1), (try store.lazerRankedRating(winner_id, 2)).games_played);
    try std.testing.expectEqual(@as(i32, 1), (try store.lazerRankedRating(loser_id, 2)).games_played);
}

test "postgres BSS publishes an owned pending package into the BN queue" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_BSS_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    store.external_only = false;
    const owner_id = try store.register("bss pg owner", "bss-pg-owner@example.test", "00000000000000000000000000000000");
    const other_id = try store.register("bss pg other", "bss-pg-other@example.test", "11111111111111111111111111111111");
    try store.updateCountry(owner_id, .{ 'A', 'U' });
    try store.updateSiteProfile(owner_id, .{ .bio = "", .title = "", .pronouns = "", .location = "", .website = "", .accent = .pink, .preferred_mode = 0, .profile_source = .all, .avatar_key = 1, .show_country = false, .show_profile_stats = true, .show_recent_scores = true });
    {
        var owner_buf: [24]u8 = undefined;
        const owner = try std.fmt.bufPrint(&owner_buf, "{d}", .{owner_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var legacy = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.beatmap_submissions(set_id,owner_id,target,state,last_error) VALUES(100000000,$1,'WIP','failed','InvalidBssBeatmaps')", &.{owner});
        legacy.deinit();
        var legacy_maps = try postgres.query(lease.conn, "INSERT INTO zigcho.beatmap_submission_maps(set_id,beatmap_id,position) VALUES(100000000,100000000,0),(100000000,100000001,1)");
        legacy_maps.deinit();
    }
    var legacy_retry = try bss.parseReserveInput(std.testing.allocator, "{\"beatmapset_id\":100000000,\"beatmaps_to_create\":0,\"beatmaps_to_keep\":[100000000,100000001],\"target\":\"Pending\",\"notify_on_discussion_replies\":true}");
    defer legacy_retry.deinit();
    var legacy_reissued = try store.reserveBssSubmission(std.testing.allocator, owner_id, legacy_retry);
    defer legacy_reissued.deinit();
    try std.testing.expect(legacy_reissued.set_id >= bss.private_id_floor);
    for (legacy_reissued.beatmap_ids) |id| try std.testing.expect(id >= bss.private_id_floor);
    var legacy_repeat = try store.reserveBssSubmission(std.testing.allocator, owner_id, legacy_retry);
    defer legacy_repeat.deinit();
    try std.testing.expectEqual(legacy_reissued.set_id, legacy_repeat.set_id);
    try std.testing.expectEqualSlices(i32, legacy_reissued.beatmap_ids, legacy_repeat.beatmap_ids);
    var create = try bss.parseReserveInput(std.testing.allocator, "{\"beatmapset_id\":null,\"beatmaps_to_create\":1,\"beatmaps_to_keep\":[],\"target\":\"Pending\",\"notify_on_discussion_replies\":true}");
    defer create.deinit();
    var reservation = try store.reserveBssSubmission(std.testing.allocator, owner_id, create);
    defer reservation.deinit();
    try std.testing.expect(reservation.set_id >= bss.private_id_floor);
    try std.testing.expect(reservation.beatmap_ids[0] >= bss.private_id_floor);
    const foreign_ids = store.bssReservedMapIds(std.testing.allocator, other_id, reservation.set_id);
    try std.testing.expectError(error.BssNotOwner, foreign_ids);

    const map_id_text = try std.fmt.allocPrint(std.testing.allocator, "BeatmapID:{d}", .{reservation.beatmap_ids[0]});
    defer std.testing.allocator.free(map_id_text);
    const set_id_text = try std.fmt.allocPrint(std.testing.allocator, "BeatmapSetID:{d}", .{reservation.set_id});
    defer std.testing.allocator.free(set_id_text);
    const with_map_id = try std.mem.replaceOwned(u8, std.testing.allocator, @embedFile("../../testdata/synthetic-standard.osu"), "BeatmapID:900000001", map_id_text);
    defer std.testing.allocator.free(with_map_id);
    const map = try std.mem.replaceOwned(u8, std.testing.allocator, with_map_id, "BeatmapSetID:900000000", set_id_text);
    defer std.testing.allocator.free(map);
    var archive_source: bss.Archive = .{ .allocator = std.testing.allocator };
    defer archive_source.deinit();
    try archive_source.entries.append(std.testing.allocator, .{
        .allocator = std.testing.allocator,
        .name = try std.testing.allocator.dupe(u8, "Zigcho [Postgres].osu"),
        .data = try std.testing.allocator.dupe(u8, map),
    });
    const archive = try bss.buildArchive(std.testing.allocator, &archive_source);
    defer std.testing.allocator.free(archive);
    var package = try bss.preparePackage(std.testing.allocator, archive, reservation.set_id, reservation.beatmap_ids);
    defer package.deinit();
    const digest = bss.archiveSha256(archive);
    try store.publishBssSubmission(owner_id, reservation.set_id, &package, archive, &digest);
    const cover_bytes = "\x89PNG\r\n\x1a\npostgres BSS cover";
    const preview_bytes = "RIFFxxxxWAVEpostgres BSS preview";
    try store.putBeatmapMedia(reservation.set_id, .cover, .png, cover_bytes);
    try store.putBeatmapMedia(reservation.set_id, .preview, .wav, preview_bytes);
    var stored_cover = (try store.beatmapMedia(std.testing.allocator, reservation.set_id, .cover)).?;
    defer stored_cover.deinit(std.testing.allocator);
    try std.testing.expectEqual(media_contract.ContentType.png, stored_cover.content_type);
    try std.testing.expectEqualSlices(u8, cover_bytes, stored_cover.data);
    var stored_preview = (try store.beatmapMedia(std.testing.allocator, reservation.set_id, .preview)).?;
    defer stored_preview.deinit(std.testing.allocator);
    try std.testing.expectEqual(media_contract.ContentType.wav, stored_preview.content_type);
    try std.testing.expectEqualSlices(u8, preview_bytes, stored_preview.data);
    const info = (try store.beatmapInfoById(std.testing.allocator, reservation.beatmap_ids[0])).?;
    defer std.testing.allocator.free(info.artist);
    defer std.testing.allocator.free(info.title);
    defer std.testing.allocator.free(info.version);
    defer std.testing.allocator.free(info.creator);
    try std.testing.expectEqual(@as(i8, 2), info.status);
    {
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{reservation.set_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var upstream = try postgres.query(lease.conn, "INSERT INTO zigcho.upstream_users(id,username,country,join_date) VALUES(35712887,'Raya_old_6','AU','2020-01-01T00:00:00Z') ON CONFLICT(id) DO UPDATE SET username=excluded.username");
        upstream.deinit();
        var collision = try postgres.queryParams(std.testing.allocator, lease.conn, "UPDATE zigcho.beatmaps SET creator_id=35712887 WHERE set_id=$1", &.{set});
        collision.deinit();
    }
    var local_creator = (try store.beatmapSetCreator(std.testing.allocator, reservation.set_id)).?;
    defer local_creator.deinit();
    try std.testing.expect(local_creator.is_local);
    try std.testing.expectEqual(owner_id, local_creator.user_id.?);
    try std.testing.expectEqualStrings("bss pg owner", local_creator.name);
    const lookup = (try store.lazerBeatmapLookup(std.testing.allocator, reservation.beatmap_ids[0], null, owner_id)).?;
    defer std.testing.allocator.free(lookup);
    var parsed_lookup = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lookup, .{});
    defer parsed_lookup.deinit();
    try std.testing.expectEqual(@as(i64, owner_id), parsed_lookup.value.object.get("user_id").?.integer);
    try std.testing.expectEqualStrings("bss pg owner", parsed_lookup.value.object.get("owners").?.array.items[0].object.get("username").?.string);
    const lookup_set = parsed_lookup.value.object.get("beatmapset").?.object;
    try std.testing.expectEqual(@as(i64, owner_id), lookup_set.get("user_id").?.integer);
    try std.testing.expectEqualStrings("bss pg owner", lookup_set.get("creator").?.string);
    try std.testing.expectEqualStrings("bss pg owner", lookup_set.get("user").?.object.get("username").?.string);
    try std.testing.expectEqualStrings("XX", lookup_set.get("user").?.object.get("country_code").?.string);
    const pending_sets = try store.lazerUserBeatmapSetsJson(std.testing.allocator, owner_id, "pending", 0, 50, owner_id);
    defer std.testing.allocator.free(pending_sets);
    var parsed_pending_sets = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, pending_sets, .{});
    defer parsed_pending_sets.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_pending_sets.value.array.items.len);
    const owned_search = try store.lazerOwnedBeatmapSearch(std.testing.allocator, owner_id, "", -1, 0, owner_id);
    defer std.testing.allocator.free(owned_search);
    var parsed_owned_search = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, owned_search, .{});
    defer parsed_owned_search.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_owned_search.value.object.get("beatmapsets").?.array.items.len);
    try std.testing.expectEqual(@as(i64, reservation.set_id), parsed_owned_search.value.object.get("beatmapsets").?.array.items[0].object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 1), parsed_owned_search.value.object.get("total").?.integer);
    try std.testing.expect(parsed_owned_search.value.object.get("cursor").? == .null);
    const score_body = try std.fmt.allocPrint(std.testing.allocator, "{{\"beatmap_id\":{d},\"ruleset_id\":0,\"total_score\":987654,\"legacy_total_score\":900000,\"accuracy\":0.985,\"max_combo\":321,\"passed\":true,\"mods\":[],\"statistics\":{{}},\"client_version\":\"2026.823.0\"}}", .{reservation.beatmap_ids[0]});
    defer std.testing.allocator.free(score_body);
    var parsed_score = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, score_body, .{});
    defer parsed_score.deinit();
    _ = try store.insertLazerScore(owner_id, try lazer.parseScore(parsed_score.value), 100, "[]", "{}", "{}", "[]", &.{});
    const pending_board = try store.lazerLeaderboardJson(std.testing.allocator, owner_id, reservation.beatmap_ids[0], 0, .vanilla, "[]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(pending_board);
    try std.testing.expect(std.mem.indexOf(u8, pending_board, "\"score_count\":0") != null);
    const site_profile = (try store.siteProfile(std.testing.allocator, owner_id, .all, 0)).?;
    defer std.testing.allocator.free(site_profile);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"beatmapsets\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"creator\":\"bss pg owner\"") != null);
    const ranking = try store.staffRankingJson(std.testing.allocator);
    defer std.testing.allocator.free(ranking);
    const marker = try std.fmt.allocPrint(std.testing.allocator, "\"set_id\":{d}", .{reservation.set_id});
    defer std.testing.allocator.free(marker);
    try std.testing.expect(std.mem.indexOf(u8, ranking, marker) != null);
}

test "postgres account auth stats and token slice" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_STORE_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    const user_id = try store.register("ari", "ari@example.test", "00000000000000000000000000000000");
    try std.testing.expect(try store.serverControlEnabled(.spectator));
    try store.setServerControl(user_id, .spectator, false, "postgres control fixture");
    try std.testing.expect(!try store.serverControlEnabled(.spectator));
    const controls_json = try store.staffServerControlsJson(std.testing.allocator);
    defer std.testing.allocator.free(controls_json);
    try std.testing.expect(std.mem.indexOf(u8, controls_json, "\"key\":\"spectator\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, controls_json, "postgres control fixture") != null);
    try store.setServerControl(user_id, .spectator, true, "postgres control restored");
    const team_id = try store.createTeam(user_id, .{ .name = "uwu team", .short_name = "uwu", .url = "", .description = "postgres leaderboard flag", .is_open = true, .default_ruleset_id = 0 });
    var team_etag: [64]u8 = undefined;
    @memset(&team_etag, 'b');
    try store.setTeamAsset(team_id, "flag", "teams/1/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.png", "image/png", team_etag, 64, 32);
    const observation_id = try store.recordAnticheatObservation(user_id, .{
        .source = .stable_login,
        .module = "private",
        .action = 1,
        .reason = 42,
        .risk_score = 150,
        .confidence_bps = 5000,
        .evidence = 1,
    });
    try store.reviewAnticheatObservation(user_id, observation_id, .clean, "verified test fixture");
    {
        var audit_lease = store.pool.acquire();
        defer audit_lease.release();
        var target_buf: [32]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{user_id});
        var audit = try postgres.queryParams(std.testing.allocator, audit_lease.conn, "SELECT count(*) FROM zigcho.audit_log WHERE action IN('anticheat.observe','anticheat.review') AND target=$1", &.{target});
        defer audit.deinit();
        try std.testing.expectEqual(@as(i64, 2), try audit.int(i64, 0, 0));
    }
    const anticheat_json = try store.staffAnticheatJson(std.testing.allocator);
    defer std.testing.allocator.free(anticheat_json);
    try std.testing.expect(std.mem.indexOf(u8, anticheat_json, "\"review_label\":\"clean\"") != null);
    try std.testing.expect((try store.registrationConflicts("ari", "ari@example.test")).username);
    try std.testing.expect((try store.avatarForUser(user_id)) != null);
    const user = (try store.authenticate(std.testing.allocator, "ari", "00000000000000000000000000000000")).?;
    defer {
        std.testing.allocator.free(user.name);
        std.testing.allocator.free(user.safe_name);
    }
    try std.testing.expectEqual(user_id, user.id);
    try store.updateSiteProfile(user_id, .{ .bio = "postgres profile", .title = "mapper", .pronouns = "they/them", .location = "adelaide", .website = "https://kai.ovh", .accent = .mint, .preferred_mode = 2, .profile_source = .lazer, .avatar_key = 2, .show_country = true, .show_profile_stats = true, .show_recent_scores = true });
    const site_account = (try store.siteAccountJson(std.testing.allocator, user_id)).?;
    defer std.testing.allocator.free(site_account);
    try std.testing.expect(std.mem.indexOf(u8, site_account, "\"bio\":\"postgres profile\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_account, "\"profile_source\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_account, "\"preferred_mode\":2") != null);
    const default_profile_summary = (try store.lazerProfileSummary(user_id)).?;
    try std.testing.expect(default_profile_summary.created_at > 0);
    try std.testing.expectEqual(@as(i64, 2), default_profile_summary.avatar_version);
    try std.testing.expectEqual(@as(u8, 2), default_profile_summary.preferred_mode);
    const batch_visibility = (try store.lazerBatchUserVisibility(user_id)).?;
    try std.testing.expect(batch_visibility.show_country);
    try std.testing.expect(batch_visibility.show_profile_stats);
    const batch_rulesets = try store.statsRulesetsForUser(user_id);
    try std.testing.expectEqual(@as(i32, 0), batch_rulesets[0].?.plays);
    try std.testing.expectEqualStrings("mapper", default_profile_summary.title());
    try std.testing.expectEqualStrings("adelaide", default_profile_summary.location());
    try std.testing.expectEqualStrings("https://kai.ovh", default_profile_summary.website());
    try std.testing.expect(default_profile_summary.show_country);
    try std.testing.expect(default_profile_summary.show_profile_stats);
    try std.testing.expect(default_profile_summary.show_recent_scores);
    var avatar_etag: [64]u8 = undefined;
    @memset(&avatar_etag, 'a');
    try store.setCustomAvatar(user_id, "4/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png", "image/png", avatar_etag);
    var custom_avatar = (try store.customAvatarForUser(std.testing.allocator, user_id)).?;
    try std.testing.expectEqualStrings("image/png", custom_avatar.content_type);
    try std.testing.expectEqualStrings("4/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png", custom_avatar.object_key);
    const custom_avatar_version = custom_avatar.updated_at;
    custom_avatar.deinit();
    const custom_profile_summary = (try store.lazerProfileSummary(user_id)).?;
    try std.testing.expectEqual(custom_avatar_version, custom_profile_summary.avatar_version);
    try std.testing.expect(try store.deleteCustomAvatar(user_id));
    try std.testing.expect((try store.customAvatarForUser(std.testing.allocator, user_id)) == null);
    const reset_profile_summary = (try store.lazerProfileSummary(user_id)).?;
    try std.testing.expectEqual(@as(i64, 2), reset_profile_summary.avatar_version);
    const screenshot_png = "\x89PNG\r\n\x1a\nbodyIEND\xaeB`\x82";
    try std.testing.expect(try store.putScreenshot(user_id, "Ab1_-xyZ", "png", screenshot_png));
    try std.testing.expect(!try store.putScreenshot(user_id, "Ab1_-xyZ", "png", "collision"));
    const stored_screenshot = (try store.screenshot(std.testing.allocator, "Ab1_-xyZ", "png")).?;
    defer std.testing.allocator.free(stored_screenshot);
    try std.testing.expectEqualSlices(u8, screenshot_png, stored_screenshot);
    try store.updateCountry(user_id, .{ 'A', 'U' });
    const stats = (try store.statsForUser(user_id, 0)).?;
    try std.testing.expectEqual(@as(i32, 0), stats.pp);
    const token = try store.issueToken(user_id, "identify scores:write", 60);
    const refresh_token = try store.issueToken(user_id, "game:refresh", 60);
    const token_user = (try store.authenticateToken(std.testing.allocator, &token, "identify")).?;
    std.testing.allocator.free(token_user.name);
    std.testing.allocator.free(token_user.safe_name);
    try std.testing.expect(try store.setLazerActivityForToken(&token, user_id, "playing", "postgres fixture", 1, 0));
    var activity = (try store.lazerActivity(std.testing.allocator, user_id, 0)).?;
    try std.testing.expectEqualStrings("postgres fixture", activity.detail);
    activity.deinit();
    try std.testing.expect(try store.revokeToken(&token));
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &token, "identify")) == null);
    try std.testing.expect((try store.consumeGameRefreshToken(std.testing.allocator, &refresh_token)) == null);
    try std.testing.expect((try store.lazerActivity(std.testing.allocator, user_id, 0)) == null);
    const refresh = try store.issueToken(user_id, "game:refresh", 60);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &refresh, "identify")) == null);
    const refreshed_user = (try store.consumeGameRefreshToken(std.testing.allocator, &refresh)).?;
    std.testing.allocator.free(refreshed_user.name);
    std.testing.allocator.free(refreshed_user.safe_name);
    try std.testing.expect((try store.consumeGameRefreshToken(std.testing.allocator, &refresh)) == null);
    const old_pair = try store.issueGameTokenPair(user_id, 60, 60, false);
    const current_pair = try store.issueGameTokenPair(user_id, 60, 60, false);
    try std.testing.expect(try store.revokeToken(&old_pair.access));
    try std.testing.expect((try store.consumeGameRefreshToken(std.testing.allocator, &old_pair.refresh)) == null);
    const current_pair_user = (try store.authenticateToken(std.testing.allocator, &current_pair.access, "identify")).?;
    std.testing.allocator.free(current_pair_user.name);
    std.testing.allocator.free(current_pair_user.safe_name);
    const rotated_pair = (try store.rotateGameTokenPair(std.testing.allocator, &current_pair.refresh, 60, 60)).?;
    std.testing.allocator.free(rotated_pair.user.name);
    std.testing.allocator.free(rotated_pair.user.safe_name);
    const rotated_pair_user = (try store.authenticateToken(std.testing.allocator, &rotated_pair.tokens.access, "identify")).?;
    std.testing.allocator.free(rotated_pair_user.name);
    std.testing.allocator.free(rotated_pair_user.safe_name);

    {
        var lease = store.pool.acquire();
        defer lease.release();
        var map_insert = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,max_combo) VALUES(1,1,$1,'artist','title','hard','mapper',3,10)", &.{"0123456789abcdef0123456789abcdef"});
        map_insert.deinit();
    }
    const score: stable_score.Submission = .{
        .map_md5 = "0123456789abcdef0123456789abcdef",
        .username = "ari",
        .online_checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .ngeki = 0,
        .nkatu = 0,
        .nmiss = 0,
        .total_score = 1_000_000,
        .max_combo = 10,
        .perfect = true,
        .grade = "X",
        .mods = 0,
        .passed = true,
        .mode = 0,
        .client_time = "260811000000",
        .client_flags = "0",
    };
    const score_id = try store.insertStableScore(user_id, score, 26.8, "replay", 12_000);
    const first_placement = (try store.scoreLeaderboardPlacement(score_id)).?;
    try std.testing.expect(first_placement.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 0), first_placement.rank);
    const snapshot = (try store.ppSnapshot(score_id)).?;
    try std.testing.expectApproxEqAbs(@as(f64, 26.8), snapshot.score, 0.001);
    try std.testing.expectEqual(@as(i64, 27), snapshot.player);
    const replay = (try store.stableReplay(std.testing.allocator, score_id)).?;
    defer std.testing.allocator.free(replay);
    try std.testing.expectEqualStrings("replay", replay);
    const website_replay = (try store.siteReplay(std.testing.allocator, score_id)).?;
    defer std.testing.allocator.free(website_replay);
    try std.testing.expect(std.mem.indexOf(u8, website_replay, "replay") != null);
    try std.testing.expectEqual(score_id, std.mem.readInt(i64, website_replay[website_replay.len - 8 ..][0..8], .little));
    const website_board = (try store.siteBeatmapLeaderboard(std.testing.allocator, 1, .all, 0)).?;
    defer std.testing.allocator.free(website_board);
    try std.testing.expect(std.mem.indexOf(u8, website_board, "\"rank\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, website_board, "\"has_replay\":true") != null);
    const stable_website_board = (try store.siteBeatmapLeaderboard(std.testing.allocator, 1, .stable, 0)).?;
    defer std.testing.allocator.free(stable_website_board);
    try std.testing.expect(std.mem.indexOf(u8, stable_website_board, "\"source\":\"stable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stable_website_board, "\"client\":\"stable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stable_website_board, "\"client\":\"lazer\"") == null);
    {
        var parsed_stable_website_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stable_website_board, .{});
        defer parsed_stable_website_board.deinit();
        const stable_website_score = parsed_stable_website_board.value.object.get("scores").?.array.items[0].object;
        try std.testing.expectEqual(@as(i64, 1_000_000), stable_website_score.get("score_without_mods").?.integer);
        try std.testing.expectEqual(@as(i64, 1_000_000), stable_website_score.get("legacy_score").?.integer);
    }
    const classic_lazer_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 1, 0, .vanilla, "[]", true, true, 0, .global, 50);
    defer std.testing.allocator.free(classic_lazer_board);
    try std.testing.expect(std.mem.indexOf(u8, classic_lazer_board, "\"score_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, classic_lazer_board, "\"username\":\"ari\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, classic_lazer_board, "\"total_score\":1000000") != null);
    var parsed_classic_lazer_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, classic_lazer_board, .{});
    defer parsed_classic_lazer_board.deinit();
    const classic_team = parsed_classic_lazer_board.value.object.get("scores").?.array.items[0].object.get("user").?.object.get("team").?.object;
    try std.testing.expectEqual(@as(i64, team_id), classic_team.get("id").?.integer);
    try std.testing.expectEqualStrings("uwu", classic_team.get("short_name").?.string);
    try std.testing.expect(std.mem.startsWith(u8, classic_team.get("flag_url").?.string, "https://assets.kai.ovh/teams/"));

    const outsider_id = try store.register("outside", "outside@example.test", "11111111111111111111111111111111");
    try store.updateCountry(outsider_id, .{ 'N', 'Z' });
    try std.testing.expectEqual(domain.RelationshipAddResult.inserted, try store.addFriend(user_id, outsider_id));
    var outsider_score = score;
    outsider_score.username = "outside";
    outsider_score.online_checksum = "cccccccccccccccccccccccccccccccc";
    outsider_score.total_score = 2_000_000;
    _ = try store.insertStableScore(outsider_id, outsider_score, 40, "outside replay", 20_000);

    const global_scope = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 1, 0, .vanilla, "[]", true, true, 0, .global, 50);
    defer std.testing.allocator.free(global_scope);
    try std.testing.expect(std.mem.indexOf(u8, global_scope, "\"score_count\":2") != null);
    const friend_scope = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 1, 0, .vanilla, "[]", true, true, 0, .friend, 50);
    defer std.testing.allocator.free(friend_scope);
    try std.testing.expect(std.mem.indexOf(u8, friend_scope, "\"score_count\":2") != null);
    const country_scope = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 1, 0, .vanilla, "[]", true, true, 0, .country, 50);
    defer std.testing.allocator.free(country_scope);
    try std.testing.expect(std.mem.indexOf(u8, country_scope, "\"score_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, country_scope, "\"username\":\"outside\"") == null);
    const team_scope = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 1, 0, .vanilla, "[]", true, true, 0, .team, 50);
    defer std.testing.allocator.free(team_scope);
    try std.testing.expect(std.mem.indexOf(u8, team_scope, "\"score_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, team_scope, "\"username\":\"ari\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, team_scope, "\"username\":\"outside\"") == null);
    var relax_hidden = score;
    relax_hidden.online_checksum = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    relax_hidden.total_score = 700_000;
    relax_hidden.mods = stable_mods.relax | stable_mods.hidden;
    const relax_hidden_id = try store.insertStableScore(user_id, relax_hidden, 33, "relax hidden replay", 12_000);
    const relax_namespace_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 1, 0, .relax, "[\"RX\"]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(relax_namespace_board);
    try std.testing.expect(std.mem.indexOf(u8, relax_namespace_board, "\"score_count\":1") != null);
    var relax_public_id_buf: [64]u8 = undefined;
    const relax_public_id = try std.fmt.bufPrint(&relax_public_id_buf, "\"id\":{d}", .{lazer.encodeStableScoreId(relax_hidden_id).?});
    try std.testing.expect(std.mem.indexOf(u8, relax_namespace_board, relax_public_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, relax_namespace_board, "\"acronym\":\"HD\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, relax_namespace_board, "\"acronym\":\"RX\"") != null);
    const relax_hidden_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 1, 0, .relax, "[\"HD\",\"RX\"]", true, false, stable_mods.hidden, .global, 50);
    defer std.testing.allocator.free(relax_hidden_board);
    try std.testing.expect(std.mem.indexOf(u8, relax_hidden_board, relax_public_id) != null);
    const after_pass = (try store.statsForUser(user_id, 0)).?;
    try std.testing.expectEqual(@as(i64, 1_000_000), after_pass.ranked_score);
    try std.testing.expectEqual(@as(i32, 27), after_pass.pp);
    try std.testing.expectEqual(@as(i32, 1), after_pass.plays);
    var failed = score;
    failed.online_checksum = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    failed.total_score = 200_000;
    failed.n300 = 4;
    failed.n100 = 3;
    failed.nmiss = 9;
    failed.max_combo = 99;
    failed.perfect = false;
    failed.grade = "F";
    failed.passed = false;
    const failed_id = try store.insertStableScore(user_id, failed, 999, "", 45_123);
    try std.testing.expect((try store.scoreLeaderboardPlacement(failed_id)) == null);
    const after_fail = (try store.statsForUser(user_id, 0)).?;
    try std.testing.expectEqual(after_pass.ranked_score, after_fail.ranked_score);
    try std.testing.expectEqual(after_pass.pp, after_fail.pp);
    try std.testing.expectEqual(@as(i64, 1_200_000), after_fail.total_score);
    try std.testing.expectEqual(@as(i32, 2), after_fail.plays);
    try std.testing.expectEqual(after_pass.max_combo, after_fail.max_combo);
    var worse = score;
    worse.online_checksum = "dddddddddddddddddddddddddddddddd";
    worse.total_score = 900_000;
    const worse_id = try store.insertStableScore(user_id, worse, 20, "worse replay", 12_000);
    const worse_placement = (try store.scoreLeaderboardPlacement(worse_id)).?;
    try std.testing.expect(!worse_placement.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 1), worse_placement.rank);
    try std.testing.expectEqual(score_id, try store.setScorePinned(user_id, score.map_md5, 0, 0, "vanilla", true));
    var hidden = score;
    hidden.online_checksum = "55555555555555555555555555555555";
    hidden.total_score = 800_000;
    hidden.mods = stable_mods.hidden;
    const hidden_id = try store.insertStableScore(user_id, hidden, 18, "hidden replay", 12_000);
    try std.testing.expectEqual(hidden_id, try store.setScorePinned(user_id, score.map_md5, 0, stable_mods.hidden, "vanilla", true));
    try std.testing.expectError(error.NoPassedScore, store.setScorePinned(user_id, score.map_md5, 0, stable_mods.hard_rock, "vanilla", true));
    {
        var user_id_buf: [24]u8 = undefined;
        const user_id_text = try std.fmt.bufPrint(&user_id_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var pinned = try postgres.queryParams(std.testing.allocator, lease.conn, "SELECT count(*) FROM zigcho.score_pins WHERE user_id=$1", &.{user_id_text});
        defer pinned.deinit();
        try std.testing.expectEqual(@as(i64, 2), try pinned.int(i64, 0, 0));
    }
    const site_rankings = try store.siteRankings(std.testing.allocator, .all, 0, 0);
    defer std.testing.allocator.free(site_rankings);
    try std.testing.expect(std.mem.indexOf(u8, site_rankings, "\"rank\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_rankings, "\"name\":\"ari\"") != null);
    const lazer_performance_rankings = try store.lazerRankingsJson(std.testing.allocator, 0, .performance, null, 1);
    defer std.testing.allocator.free(lazer_performance_rankings);
    try std.testing.expect(std.mem.indexOf(u8, lazer_performance_rankings, "\"ranking\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_performance_rankings, "\"username\":\"ari\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_performance_rankings, "\"global_rank\":1") != null);
    const lazer_country_rankings = try store.lazerRankingsJson(std.testing.allocator, 0, .country, null, 1);
    defer std.testing.allocator.free(lazer_country_rankings);
    try std.testing.expect(std.mem.indexOf(u8, lazer_country_rankings, "\"code\":\"AU\"") != null);
    const filtered_lazer_rankings = try store.lazerRankingsJson(std.testing.allocator, 0, .score, "AU", 1);
    defer std.testing.allocator.free(filtered_lazer_rankings);
    try std.testing.expect(std.mem.indexOf(u8, filtered_lazer_rankings, "\"country_code\":\"AU\"") != null);
    const site_profile = (try store.siteProfile(std.testing.allocator, user_id, .all, 0)).?;
    defer std.testing.allocator.free(site_profile);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"country\":\"AU\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"global_rank\":1") != null);
    {
        var parsed_profile = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, site_profile, .{});
        defer parsed_profile.deinit();
        const selected = parsed_profile.value.object.get("selected_stats").?.object;
        const ranks = selected.get("rank_history").?.array.items;
        const pp_values = selected.get("pp_history").?.array.items;
        const days = selected.get("history_days").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), ranks.len);
        try std.testing.expectEqual(ranks.len, pp_values.len);
        try std.testing.expectEqual(ranks.len, days.len);
        try std.testing.expectEqual(selected.get("global_rank").?.integer, ranks[ranks.len - 1].integer);
        try std.testing.expectEqual(selected.get("pp").?.integer, pp_values[pp_values.len - 1].integer);
    }
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var user_id_buf: [24]u8 = undefined;
        const user_id_text = try std.fmt.bufPrint(&user_id_buf, "{d}", .{user_id});
        var inserted_history = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.user_stats_history(user_id,source,mode,day,pp,global_rank) VALUES($1,'all',0,((extract(epoch FROM clock_timestamp())::bigint/86400)-90)*86400,6,10),($1,'all',0,((extract(epoch FROM clock_timestamp())::bigint/86400)-89)*86400,7,9)", &.{user_id_text});
        defer inserted_history.deinit();
    }
    var history_score = score;
    history_score.online_checksum = "44444444444444444444444444444444";
    history_score.total_score = 700_000;
    _ = try store.insertStableScore(user_id, history_score, 10, "history replay", 12_000);
    const observed_history = try store.statsHistory(user_id, .all, 0);
    try std.testing.expectEqual(@as(usize, 2), observed_history.len);
    try std.testing.expectEqual(@as(i32, 7), observed_history.points[0].pp);
    try std.testing.expectEqual(@as(i32, 9), observed_history.points[0].global_rank);
    try std.testing.expectEqual(@as(i32, 27), observed_history.points[1].pp);
    try std.testing.expectEqual(@as(i32, 2), observed_history.points[1].global_rank);
    try std.testing.expectEqual(observed_history, try store.statsHistory(user_id, .all, 0));
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var pruned = try postgres.query(lease.conn, "SELECT count(*) FROM zigcho.user_stats_history WHERE day<((extract(epoch FROM clock_timestamp())::bigint/86400)-89)*86400");
        defer pruned.deinit();
        try std.testing.expectEqual(@as(i64, 0), try pruned.int(i64, 0, 0));
    }
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"artist\":\"artist\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"passed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"pinned_scores\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"top_scores\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"weight\":{\"percentage\":100.00,\"pp\":26.80}") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"recent_scores\":[{") != null);
    {
        var user_id_buf: [24]u8 = undefined;
        const user_id_text = try std.fmt.bufPrint(&user_id_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var map_insert = try postgres.query(lease.conn, "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,max_combo) VALUES(3,3,'33333333333333333333333333333333','first artist','first title','first diff','mapper',3,10)");
        map_insert.deinit();
        var first_insert = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,rank_namespace,best) VALUES($1,'33333333333333333333333333333333',0,0,1234,1,1,10,10,0,0,0,0,0,true,true,'first-replay'::bytea,'vanilla',true)", &.{user_id_text});
        first_insert.deinit();
    }
    try store.updateSiteProfile(user_id, .{ .bio = "postgres profile", .title = "mapper", .pronouns = "they/them", .location = "adelaide", .website = "https://kai.ovh", .accent = .mint, .preferred_mode = 2, .profile_source = .lazer, .avatar_key = 2, .show_country = false, .show_profile_stats = false, .show_recent_scores = false });
    try std.testing.expect(try store.recordReplayView(3, .stable, score_id));
    for ([_]domain.SiteScoreSource{ .all, .stable }) |private_source| {
        const private_site_rankings = try store.siteRankings(std.testing.allocator, private_source, 0, 0);
        defer std.testing.allocator.free(private_site_rankings);
        var parsed_private_site = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, private_site_rankings, .{});
        defer parsed_private_site.deinit();
        const private_site_players = parsed_private_site.value.object.get("players").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), private_site_players.len);
        try std.testing.expectEqual(@as(i64, outsider_id), private_site_players[0].object.get("id").?.integer);
        try std.testing.expectEqual(@as(i64, 1), private_site_players[0].object.get("rank").?.integer);
    }
    for ([_]lazer.RankingKind{ .performance, .score }) |private_kind| {
        const private_lazer_rankings = try store.lazerRankingsJson(std.testing.allocator, 0, private_kind, null, 1);
        defer std.testing.allocator.free(private_lazer_rankings);
        var parsed_private_lazer = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, private_lazer_rankings, .{});
        defer parsed_private_lazer.deinit();
        const private_lazer_rows = parsed_private_lazer.value.object.get("ranking").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), private_lazer_rows.len);
        try std.testing.expectEqual(@as(i64, outsider_id), private_lazer_rows[0].object.get("user").?.object.get("id").?.integer);
        try std.testing.expectEqual(@as(i64, 1), private_lazer_rows[0].object.get("global_rank").?.integer);
        try std.testing.expectEqual(@as(i64, 0), private_lazer_rows[0].object.get("replays_watched_by_others").?.integer);
    }
    try store.updateSiteProfile(user_id, .{ .bio = "postgres profile", .title = "mapper", .pronouns = "they/them", .location = "adelaide", .website = "https://kai.ovh", .accent = .mint, .preferred_mode = 2, .profile_source = .lazer, .avatar_key = 2, .show_country = true, .show_profile_stats = false, .show_recent_scores = false });
    const private_countries_json = try store.lazerRankingsJson(std.testing.allocator, 0, .country, null, 1);
    defer std.testing.allocator.free(private_countries_json);
    var private_countries = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, private_countries_json, .{});
    defer private_countries.deinit();
    const private_country_rows = private_countries.value.object.get("ranking").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), private_country_rows.len);
    try std.testing.expectEqualStrings("NZ", private_country_rows[0].object.get("code").?.string);
    try std.testing.expectEqual(@as(i64, 1), private_country_rows[0].object.get("active_users").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, private_countries_json, "\"code\":\"AU\"") == null);
    {
        var score_buf: [24]u8 = undefined;
        const score_text = try std.fmt.bufPrint(&score_buf, "{d}", .{score_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var remove_privacy_view = try postgres.queryParams(std.testing.allocator, lease.conn, "DELETE FROM zigcho.score_replay_views WHERE viewer_id=3 AND source='stable' AND score_id=$1", &.{score_text});
        remove_privacy_view.deinit();
    }
    try store.updateSiteProfile(user_id, .{ .bio = "postgres profile", .title = "mapper", .pronouns = "they/them", .location = "adelaide", .website = "https://kai.ovh", .accent = .mint, .preferred_mode = 2, .profile_source = .lazer, .avatar_key = 2, .show_country = false, .show_profile_stats = false, .show_recent_scores = false });
    const hidden_lookup = (try store.userById(std.testing.allocator, user_id)).?;
    defer std.testing.allocator.free(hidden_lookup.name);
    defer std.testing.allocator.free(hidden_lookup.safe_name);
    try std.testing.expect(!hidden_lookup.show_country);
    const hidden_auth = (try store.authenticate(std.testing.allocator, "ari", "00000000000000000000000000000000")).?;
    defer std.testing.allocator.free(hidden_auth.name);
    defer std.testing.allocator.free(hidden_auth.safe_name);
    try std.testing.expect(!hidden_auth.show_country);
    const hidden_token = try store.issueToken(user_id, "web:account", 60);
    const hidden_token_user = (try store.authenticateToken(std.testing.allocator, &hidden_token, "web:account")).?;
    defer std.testing.allocator.free(hidden_token_user.name);
    defer std.testing.allocator.free(hidden_token_user.safe_name);
    try std.testing.expect(!hidden_token_user.show_country);
    const hidden_public_profile = (try store.siteProfile(std.testing.allocator, user_id, .all, 0)).?;
    defer std.testing.allocator.free(hidden_public_profile);
    try std.testing.expect(std.mem.indexOf(u8, hidden_public_profile, "\"country\":\"XX\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_public_profile, "\"selected_stats\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_public_profile, "\"pinned_scores\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_public_profile, "\"top_scores\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_public_profile, "\"recent_scores\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_public_profile, "\"first_place_count\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_public_profile, "\"first_place_scores\":[]") != null);
    const hidden_owner_profile = (try store.siteProfileForViewer(std.testing.allocator, user_id, .all, 0, true)).?;
    defer std.testing.allocator.free(hidden_owner_profile);
    try std.testing.expect(std.mem.indexOf(u8, hidden_owner_profile, "\"country\":\"AU\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_owner_profile, "\"selected_stats\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_owner_profile, "\"pinned_scores\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_owner_profile, "\"top_scores\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_owner_profile, "\"recent_scores\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_owner_profile, "\"first_place_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_owner_profile, "\"first_place_scores\":[{") != null);
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var first_delete = try postgres.query(lease.conn, "DELETE FROM zigcho.scores WHERE map_md5='33333333333333333333333333333333'");
        first_delete.deinit();
        var map_delete = try postgres.query(lease.conn, "DELETE FROM zigcho.beatmaps WHERE id=3");
        map_delete.deinit();
    }
    try store.updateSiteProfile(user_id, .{ .bio = "postgres profile", .title = "mapper", .pronouns = "they/them", .location = "adelaide", .website = "https://kai.ovh", .accent = .mint, .preferred_mode = 2, .profile_source = .lazer, .avatar_key = 2, .show_country = true, .show_profile_stats = true, .show_recent_scores = true });
    var relax = score;
    relax.online_checksum = "ffffffffffffffffffffffffffffffff";
    relax.total_score = 600_000;
    relax.mods = 128;
    _ = try store.insertStableScore(user_id, relax, 42.5, "relax replay", 15_000);
    const relax_profile = (try store.siteProfile(std.testing.allocator, user_id, .all, 4)).?;
    defer std.testing.allocator.free(relax_profile);
    try std.testing.expect(std.mem.indexOf(u8, relax_profile, "\"selected_mode\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, relax_profile, "\"namespace\":\"relax\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, relax_profile, "\"namespace\":\"vanilla\"") == null);
    {
        var parsed_relax_profile = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, relax_profile, .{});
        defer parsed_relax_profile.deinit();
        const selected = parsed_relax_profile.value.object.get("selected_stats").?.object;
        const pp_values = selected.get("pp_history").?.array.items;
        try std.testing.expectEqual(@as(i64, 43), selected.get("pp").?.integer);
        try std.testing.expectEqual(@as(usize, 1), pp_values.len);
        try std.testing.expectEqual(@as(i64, 43), pp_values[pp_values.len - 1].integer);
    }
    const relax_stats = (try store.statsForUser(user_id, 4)).?;
    try std.testing.expectEqual(@as(i64, 600_000), relax_stats.ranked_score);
    try std.testing.expectEqual(@as(i32, 43), relax_stats.pp);
    const vanilla_board = try store.stableLeaderboard(std.testing.allocator, user, score.map_md5, 0, 0, 0);
    defer std.testing.allocator.free(vanilla_board);
    try std.testing.expect(std.mem.indexOf(u8, vanilla_board, "artist - title [hard]") != null);
    try std.testing.expect(std.mem.indexOf(u8, vanilla_board, "|ari|1000000|") != null);
    const relax_board = try store.stableLeaderboard(std.testing.allocator, user, score.map_md5, 0, 0, 128);
    defer std.testing.allocator.free(relax_board);
    try std.testing.expect(std.mem.indexOf(u8, relax_board, "|ari|42|") != null);

    const metadata: beatmap.Metadata = .{
        .id = 2,
        .set_id = 2,
        .artist = "artist two",
        .title = "title two",
        .version = "insane",
        .creator = "mapper",
        .source = "source",
        .tags = "some tags",
        .hp = 5,
        .cs = 4,
        .od = 8,
        .ar = 9,
        .bpm = 180,
        .total_length = 90,
        .count_circles = 10,
        .count_sliders = 20,
        .count_spinners = 1,
    };
    const second_md5 = "fedcba9876543210fedcba9876543210";
    try store.upsertBeatmapMeta(metadata, second_md5, 3, 5.25, 300);
    try std.testing.expect(!try store.beatmapHasFile(second_md5));
    try store.upsertBeatmap(metadata, second_md5, 3, 5.25, 300, "osu file bytes");
    try std.testing.expect(try store.beatmapHasFile(second_md5));
    const map_file = (try store.beatmapFileById(std.testing.allocator, 2)).?;
    defer std.testing.allocator.free(map_file);
    try std.testing.expectEqualStrings("osu file bytes", map_file);
    const archive_bytes = "osz archive bytes";
    var archive_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive_bytes, &archive_digest, .{});
    const archive_sha256 = std.fmt.bytesToHex(archive_digest, .lower);
    try store.upsertBeatmapArchive(2, &archive_sha256, archive_bytes);
    const archive = (try store.beatmapArchive(std.testing.allocator, 2)).?;
    defer std.testing.allocator.free(archive);
    try std.testing.expectEqualStrings(archive_bytes, archive);
    const cover = "\xff\xd8\xffcover\xff\xd9";
    try store.putBeatmapMedia(2, .cover, .jpeg, cover);
    var stored_cover = (try store.beatmapMedia(std.testing.allocator, 2, .cover)).?;
    defer stored_cover.deinit(std.testing.allocator);
    try std.testing.expectEqual(.jpeg, stored_cover.content_type);
    try std.testing.expectEqualStrings(cover, stored_cover.data);
    const media_stats = try store.beatmapMediaCacheStats();
    try std.testing.expectEqual(@as(i64, 1), media_stats.entries);
    try std.testing.expectEqual(@as(i64, cover.len), media_stats.bytes);
    try store.upsertBeatmapSetMetadata(.{
        .set_id = 2,
        .favourites = 39,
        .submitted_date = "2026-08-20T00:00:00Z",
        .last_updated = "2026-08-22T05:45:08Z",
        .ranked_date = "2026-08-22T05:45:08Z",
        .has_video = false,
        .genre_id = 4,
        .language_id = 2,
    }, 1_787_456_000);
    try store.updateBeatmapUpstreamStats(2, 123, 45, 80);
    try std.testing.expect(try store.addFavourite(user_id, 2));
    try store.recordHydrationFailure("cccccccccccccccccccccccccccccccc", 2, "UpstreamUnavailable", 100);
    try std.testing.expect(!try store.hydrationRetryAllowed("cccccccccccccccccccccccccccccccc", 129));
    try std.testing.expect(try store.hydrationRetryAllowed("cccccccccccccccccccccccccccccccc", 130));
    try std.testing.expectEqual(@as(i64, 1), (try store.beatmapCacheStats()).hydration_failures);
    try store.clearHydrationFailure("cccccccccccccccccccccccccccccccc");
    const direct = try store.stableSearch(std.testing.allocator, "title two", -1, 4, 0);
    defer std.testing.allocator.free(direct);
    try std.testing.expect(std.mem.indexOf(u8, direct, "2.osz|artist two|title two|mapper") != null);
    const direct_set = try store.stableSearchSet(std.testing.allocator, null, null, second_md5);
    defer std.testing.allocator.free(direct_set);
    try std.testing.expect(std.mem.startsWith(u8, direct_set, "2.osz|"));
    const lazer_set = (try store.lazerBeatmapSet(std.testing.allocator, 2, null)).?;
    defer std.testing.allocator.free(lazer_set);
    try std.testing.expect(std.mem.indexOf(u8, lazer_set, "\"title\":\"title two\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_set, "https://assets.kai.ovh/beatmaps/2/covers/cover.jpg") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_set, "https://b.kai.ovh/preview/2.mp3") != null);
    {
        var parsed_local_set = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lazer_set, .{});
        defer parsed_local_set.deinit();
        try std.testing.expectEqual(@as(i64, 0), parsed_local_set.value.object.get("play_count").?.integer);
        try std.testing.expectEqual(@as(i64, 1), parsed_local_set.value.object.get("favourite_count").?.integer);
        const local_map = parsed_local_set.value.object.get("beatmaps").?.array.items[0].object;
        try std.testing.expectEqual(@as(i64, 0), local_map.get("playcount").?.integer);
        try std.testing.expectEqual(@as(i64, 0), local_map.get("passcount").?.integer);
    }
    const lookup_by_id = (try store.lazerBeatmapLookup(std.testing.allocator, 2, null, null)).?;
    defer std.testing.allocator.free(lookup_by_id);
    const parsed_lookup_by_id = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lookup_by_id, .{});
    defer parsed_lookup_by_id.deinit();
    try std.testing.expectEqual(@as(i64, 0), parsed_lookup_by_id.value.object.get("playcount").?.integer);
    try std.testing.expectEqual(@as(i64, 0), parsed_lookup_by_id.value.object.get("passcount").?.integer);
    const lookup_by_checksum = (try store.lazerBeatmapLookup(std.testing.allocator, null, second_md5, null)).?;
    defer std.testing.allocator.free(lookup_by_checksum);
    const parsed_lookup_by_checksum = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lookup_by_checksum, .{});
    defer parsed_lookup_by_checksum.deinit();
    try std.testing.expectEqual(@as(i64, 0), parsed_lookup_by_checksum.value.object.get("playcount").?.integer);
    try std.testing.expectEqual(@as(i64, 0), parsed_lookup_by_checksum.value.object.get("passcount").?.integer);
    try std.testing.expect(try store.setLazerBeatmapTag(user_id, 2, 1, true));
    const tag_state = (try store.lazerBeatmapTagStateJson(std.testing.allocator, user_id, 2)).?;
    defer std.testing.allocator.free(tag_state);
    try std.testing.expect(std.mem.indexOf(u8, tag_state, "\"current_user_tag_ids\":[1]") != null);
    try std.testing.expect(try store.setLazerBeatmapTag(user_id, 2, 1, false));
    try std.testing.expect(try store.addLazerReport(user_id, "user", user_id, "Other", "postgres route report"));
    const report_queue = try store.staffLazerReportsJson(std.testing.allocator);
    defer std.testing.allocator.free(report_queue);
    const parsed_queue = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report_queue, .{});
    defer parsed_queue.deinit();
    const report_id = parsed_queue.value.object.get("reports").?.array.items[0].object.get("id").?.integer;
    try std.testing.expect(try store.resolveLazerReport(user_id, report_id, "resolved"));
    try std.testing.expect(!try store.resolveLazerReport(user_id, report_id, "dismissed"));
    try std.testing.expect(!try store.lazerMessageExists(999999));
    const lazer_search = try store.lazerBeatmapSearch(std.testing.allocator, "title two", 0, 0, null);
    defer std.testing.allocator.free(lazer_search);
    try std.testing.expect(std.mem.indexOf(u8, lazer_search, "\"beatmapsets\":[{") != null);
    const ordered_lazer_sets = try store.lazerBeatmapSets(std.testing.allocator, &.{2}, 0, null);
    defer std.testing.allocator.free(ordered_lazer_sets);
    try std.testing.expect(std.mem.indexOf(u8, ordered_lazer_sets, "\"beatmapsets\":[{\"id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, ordered_lazer_sets, "\"user\":null") == null);
    const raw_lazer_score = "{\"beatmap_id\":2,\"ruleset_id\":0,\"total_score\":1234,\"legacy_total_score\":900,\"accuracy\":0.98,\"max_combo\":25,\"passed\":true,\"mods\":[],\"statistics\":{},\"client_version\":\"2026.811.0\"}";
    const parsed_lazer = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw_lazer_score, .{});
    defer parsed_lazer.deinit();
    const mods_json = try lazer.jsonField(std.testing.allocator, parsed_lazer.value.object, "mods", "[]");
    defer std.testing.allocator.free(mods_json);
    const statistics_json = try lazer.jsonField(std.testing.allocator, parsed_lazer.value.object, "statistics", "{}");
    defer std.testing.allocator.free(statistics_json);
    const lazer_input = try lazer.parseScore(parsed_lazer.value);
    const lazer_token = try store.createLazerScoreToken(user_id, 2, second_md5, 0, "11111111111111111111111111111111");
    var lazer_replay: [32]u8 = @splat(0);
    lazer_replay[0] = 0;
    std.mem.writeInt(i32, lazer_replay[1..5], 20_260_816, .little);
    const lazer_score_id = try store.submitLazerScoreToken(user_id, 2, lazer_token, lazer_input, 0, mods_json, statistics_json, "{}", "[]", &lazer_replay);
    try std.testing.expect(lazer_score_id > 0);
    try std.testing.expectError(error.LazerScoreTokenUsed, store.submitLazerScoreToken(user_id, 2, lazer_token, lazer_input, 0, mods_json, statistics_json, "{}", "[]", &.{}));
    const consumed_lazer = (try store.consumedLazerScoreToken(user_id, 2, lazer_token)).?;
    try std.testing.expectEqual(lazer_score_id, consumed_lazer.score_id);
    try std.testing.expectEqual(lazer_input.total_score, consumed_lazer.total_score);
    try std.testing.expectEqual(lazer_input.accuracy, consumed_lazer.accuracy);
    try std.testing.expectEqual(@as(i32, @intCast(lazer_input.max_combo)), consumed_lazer.max_combo);
    try std.testing.expectEqual(lazer_input.passed, consumed_lazer.passed);
    try std.testing.expect((try store.consumedLazerScoreToken(user_id + 1, 2, lazer_token)) == null);
    const combined_stats = (try store.statsForUser(user_id, 0)).?;
    // The server derives Classic score from the submitted native score and
    // judgements; it never trusts the client-provided legacy_total_score.
    try std.testing.expectEqual(@as(i64, 3_600_123), combined_stats.total_score);
    try std.testing.expectEqual(@as(i64, 1_000_123), combined_stats.ranked_score);
    try std.testing.expectEqual(@as(i32, 6), combined_stats.plays);
    try std.testing.expectEqual(@as(i32, 25), combined_stats.max_combo);
    const most_played_json = try store.lazerMostPlayedJson(std.testing.allocator, user_id, user_id, 0, 50);
    defer std.testing.allocator.free(most_played_json);
    var parsed_most_played = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, most_played_json, .{});
    defer parsed_most_played.deinit();
    var found_local_map = false;
    for (parsed_most_played.value.array.items) |row_value| {
        const row = row_value.object;
        if (row.get("beatmap_id").?.integer != 2) continue;
        found_local_map = true;
        const nested_map = row.get("beatmap").?.object;
        try std.testing.expectEqual(@as(i64, 1), nested_map.get("playcount").?.integer);
        try std.testing.expectEqual(@as(i64, 1), nested_map.get("passcount").?.integer);
        const nested_set = row.get("beatmapset").?.object;
        try std.testing.expectEqual(@as(i64, 1), nested_set.get("play_count").?.integer);
        try std.testing.expectEqual(@as(i64, 1), nested_set.get("favourite_count").?.integer);
    }
    try std.testing.expect(found_local_map);
    const stored_lazer_replay = (try store.lazerReplay(std.testing.allocator, lazer_score_id)).?;
    defer std.testing.allocator.free(stored_lazer_replay);
    try std.testing.expectEqualSlices(u8, &lazer_replay, stored_lazer_replay);
    const lazer_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 2, 0, .vanilla, "[]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(lazer_board);
    try std.testing.expect(std.mem.indexOf(u8, lazer_board, "\"has_replay\":true") != null);
    {
        var parsed_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lazer_board, .{});
        defer parsed_board.deinit();
        const board_score = parsed_board.value.object.get("scores").?.array.items[0].object;
        try std.testing.expectEqual(@as(i64, 1234), board_score.get("total_score").?.integer);
        try std.testing.expectEqual(@as(i64, 123), board_score.get("legacy_total_score").?.integer);
    }
    const lazer_score_detail = (try store.lazerScoreJson(std.testing.allocator, lazer_score_id, 2)).?;
    defer std.testing.allocator.free(lazer_score_detail);
    {
        var parsed_detail = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lazer_score_detail, .{});
        defer parsed_detail.deinit();
        try std.testing.expectEqual(@as(i64, 1234), parsed_detail.value.object.get("total_score").?.integer);
        try std.testing.expectEqual(@as(i64, 123), parsed_detail.value.object.get("legacy_total_score").?.integer);
    }
    {
        var score_id_buf: [24]u8 = undefined;
        const score_id_text = try std.fmt.bufPrint(&score_id_buf, "{d}", .{lazer_score_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var clear_replay = try postgres.queryParams(std.testing.allocator, lease.conn, "UPDATE zigcho.lazer_scores SET replay=NULL WHERE id=$1", &.{score_id_text});
        clear_replay.deinit();
    }
    const old_lazer_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 2, 0, .vanilla, "[]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(old_lazer_board);
    try std.testing.expect(std.mem.indexOf(u8, old_lazer_board, "\"has_replay\":false") != null);
    const missing_lazer_detail_json = (try store.lazerScoreJson(std.testing.allocator, lazer_score_id, 2)).?;
    defer std.testing.allocator.free(missing_lazer_detail_json);
    var missing_lazer_detail = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, missing_lazer_detail_json, .{});
    defer missing_lazer_detail.deinit();
    try std.testing.expect(!missing_lazer_detail.value.object.get("has_replay").?.bool);
    {
        var stable_id_buf: [24]u8 = undefined;
        var lazer_id_buf: [24]u8 = undefined;
        const stable_id_text = try std.fmt.bufPrint(&stable_id_buf, "{d}", .{score_id});
        const lazer_id_text = try std.fmt.bufPrint(&lazer_id_buf, "{d}", .{lazer_score_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var clear_stable = try postgres.queryParams(std.testing.allocator, lease.conn, "UPDATE zigcho.scores SET replay=NULL WHERE id=$1", &.{stable_id_text});
        clear_stable.deinit();
        var replay_objects = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.replay_objects(source,score_id,object_key,etag,object_bytes) VALUES('stable',$1::bigint,'replays/stable/postgres-'||$1::text,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',6),('lazer',$2::bigint,'replays/lazer/postgres-'||$2::text,'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',32) ON CONFLICT(source,score_id) DO UPDATE SET object_key=excluded.object_key,etag=excluded.etag,object_bytes=excluded.object_bytes", &.{ stable_id_text, lazer_id_text });
        replay_objects.deinit();
    }
    const object_lazer_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 2, 0, .vanilla, "[]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(object_lazer_board);
    try std.testing.expect(std.mem.indexOf(u8, object_lazer_board, "\"has_replay\":true") != null);
    const object_lazer_detail_json = (try store.lazerScoreJson(std.testing.allocator, lazer_score_id, 2)).?;
    defer std.testing.allocator.free(object_lazer_detail_json);
    var object_lazer_detail = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, object_lazer_detail_json, .{});
    defer object_lazer_detail.deinit();
    try std.testing.expect(object_lazer_detail.value.object.get("has_replay").?.bool);
    const object_stable_board_json = (try store.siteBeatmapLeaderboard(std.testing.allocator, 1, .stable, 0)).?;
    defer std.testing.allocator.free(object_stable_board_json);
    var object_stable_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, object_stable_board_json, .{});
    defer object_stable_board.deinit();
    try std.testing.expect(object_stable_board.value.object.get("scores").?.array.items[0].object.get("has_replay").?.bool);
    const object_stable_scores_json = try store.lazerUserScoresJson(std.testing.allocator, user_id, 0, .recent, .stable, 0, 50);
    defer std.testing.allocator.free(object_stable_scores_json);
    var object_stable_scores = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, object_stable_scores_json, .{});
    defer object_stable_scores.deinit();
    try std.testing.expect(object_stable_scores.value.array.items[0].object.get("has_replay").?.bool);
    const object_stable_profile_json = (try store.siteProfile(std.testing.allocator, user_id, .stable, 0)).?;
    defer std.testing.allocator.free(object_stable_profile_json);
    var object_stable_profile = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, object_stable_profile_json, .{});
    defer object_stable_profile.deinit();
    try std.testing.expect(object_stable_profile.value.object.get("recent_scores").?.array.items[0].object.get("has_replay").?.bool);
    const lazer_placement = (try store.lazerScoreLeaderboardPlacement(lazer_score_id)).?;
    try std.testing.expect(lazer_placement.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 0), lazer_placement.rank);
    const lazer_rankings = try store.siteRankings(std.testing.allocator, .lazer, 0, 0);
    defer std.testing.allocator.free(lazer_rankings);
    try std.testing.expect(std.mem.indexOf(u8, lazer_rankings, "\"source\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_rankings, "\"name\":\"ari\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_rankings, "\"total_score\":123") != null);
    const stable_rankings = try store.siteRankings(std.testing.allocator, .stable, 0, 0);
    defer std.testing.allocator.free(stable_rankings);
    try std.testing.expect(std.mem.indexOf(u8, stable_rankings, "\"source\":\"stable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stable_rankings, "\"name\":\"ari\"") != null);
    const lazer_profile = (try store.siteProfile(std.testing.allocator, user_id, .lazer, 0)).?;
    defer std.testing.allocator.free(lazer_profile);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"selected_source\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"stats_source\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"selected_stats\":{\"ranked_score\":123,\"total_score\":123,\"pp\":0,\"plays\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"client\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"mods_json\":[]") != null);
    {
        var parsed_profile = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lazer_profile, .{});
        defer parsed_profile.deinit();
        const profile_score = parsed_profile.value.object.get("recent_scores").?.array.items[0].object;
        try std.testing.expectEqual(@as(i64, 1234), profile_score.get("score").?.integer);
        try std.testing.expectEqual(@as(i64, 900), profile_score.get("score_without_mods").?.integer);
        try std.testing.expectEqual(@as(i64, 123), profile_score.get("legacy_score").?.integer);
        const first_place_score = parsed_profile.value.object.get("first_place_scores").?.array.items[0].object;
        try std.testing.expectEqual(@as(i64, 900), first_place_score.get("score_without_mods").?.integer);
        try std.testing.expectEqual(@as(i64, 123), first_place_score.get("legacy_score").?.integer);
    }
    const lazer_website_board = (try store.siteBeatmapLeaderboard(std.testing.allocator, 2, .lazer, 0)).?;
    defer std.testing.allocator.free(lazer_website_board);
    try std.testing.expect(std.mem.indexOf(u8, lazer_website_board, "\"source\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_website_board, "\"client\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_website_board, "\"client\":\"stable\"") == null);
    {
        var parsed_lazer_website_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lazer_website_board, .{});
        defer parsed_lazer_website_board.deinit();
        const lazer_website_score = parsed_lazer_website_board.value.object.get("scores").?.array.items[0].object;
        try std.testing.expectEqual(@as(i64, 1234), lazer_website_score.get("score").?.integer);
        try std.testing.expectEqual(@as(i64, 900), lazer_website_score.get("score_without_mods").?.integer);
        try std.testing.expectEqual(@as(i64, 123), lazer_website_score.get("legacy_score").?.integer);
    }
    {
        var user_buf: [24]u8 = undefined;
        const user_text = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var inserted = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,rank_namespace,best) VALUES($1,$2,0,0,1100,120,0.97,30,97,3,0,0,0,0,false,true,'replay'::bytea,'vanilla',true)", &.{ user_text, second_md5 });
        inserted.deinit();
    }
    const mixed_client_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 2, 0, .vanilla, "[]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(mixed_client_board);
    var parsed_mixed_client_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, mixed_client_board, .{});
    defer parsed_mixed_client_board.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed_mixed_client_board.value.object.get("score_count").?.integer);
    const mixed_scores = parsed_mixed_client_board.value.object.get("scores").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), mixed_scores.len);
    try std.testing.expect(mixed_scores[0].object.get("id").?.integer >= lazer.stable_score_id_offset);
    try std.testing.expect(std.mem.indexOf(u8, mixed_client_board, "\"pp\":120") != null);
    try std.testing.expectEqual(@as(i64, team_id), mixed_scores[0].object.get("user").?.object.get("team").?.object.get("id").?.integer);
    try std.testing.expect(parsed_mixed_client_board.value.object.get("user_score").?.object.get("score").?.object.get("id").?.integer >= lazer.stable_score_id_offset);
    const combined_site_board = (try store.siteBeatmapLeaderboard(std.testing.allocator, 2, .all, 0)).?;
    defer std.testing.allocator.free(combined_site_board);
    var parsed_combined_site_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, combined_site_board, .{});
    defer parsed_combined_site_board.deinit();
    const combined_site_score = parsed_combined_site_board.value.object.get("scores").?.array.items[0].object;
    try std.testing.expectEqualStrings("stable", combined_site_score.get("client").?.string);
    try std.testing.expectEqual(@as(i64, 1100), combined_site_score.get("score").?.integer);
    try std.testing.expectEqual(@as(i64, 120), combined_site_score.get("pp").?.integer);
    {
        var user_buf: [24]u8 = undefined;
        const user_text = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var removed = try postgres.queryParams(std.testing.allocator, lease.conn, "DELETE FROM zigcho.scores WHERE user_id=$1 AND map_md5=$2 AND score=1100", &.{ user_text, second_md5 });
        removed.deinit();
    }
    {
        var user_buf: [24]u8 = undefined;
        const user_text = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var inserted = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,rank_namespace,best) VALUES($1,$2,0,0,3000000000,500,0.99,300,300,0,0,0,0,0,true,true,'high-score-replay'::bytea,'vanilla',true)", &.{ user_text, second_md5 });
        inserted.deinit();
    }
    const high_recent_json = try store.lazerUserScoresJson(std.testing.allocator, user_id, 0, .recent, .stable, 0, 50);
    defer std.testing.allocator.free(high_recent_json);
    var high_recent = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, high_recent_json, .{});
    defer high_recent.deinit();
    const high_recent_score = high_recent.value.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 3_000_000_000), high_recent_score.get("total_score").?.integer);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i32)), high_recent_score.get("legacy_total_score").?.integer);
    const high_board_json = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 2, 0, .vanilla, "[]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(high_board_json);
    var high_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, high_board_json, .{});
    defer high_board.deinit();
    const high_board_score = high_board.value.object.get("scores").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 3_000_000_000), high_board_score.get("total_score").?.integer);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i32)), high_board_score.get("legacy_total_score").?.integer);
    {
        var user_buf: [24]u8 = undefined;
        const user_text = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var removed = try postgres.queryParams(std.testing.allocator, lease.conn, "DELETE FROM zigcho.scores WHERE user_id=$1 AND map_md5=$2 AND score=3000000000", &.{ user_text, second_md5 });
        removed.deinit();
    }
    var stable_relax_id: i64 = 0;
    var stable_autopilot_id: i64 = 0;
    {
        var user_buf: [24]u8 = undefined;
        const user_text = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var inserted = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,rank_namespace,best) VALUES($1,$2,0,128,600,180,0.96,60,96,4,0,0,0,0,false,true,'relax-replay'::bytea,'relax',true),($1,$2,0,8192,620,190,0.97,62,97,3,0,0,0,0,false,true,'autopilot-replay'::bytea,'autopilot',true) RETURNING id", &.{ user_text, second_md5 });
        defer inserted.deinit();
        stable_relax_id = try inserted.int(i64, 0, 0);
        stable_autopilot_id = try inserted.int(i64, 1, 0);
    }
    const stable_relax_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 2, 0, .relax, "[\"RX\"]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(stable_relax_board);
    var parsed_stable_relax = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stable_relax_board, .{});
    defer parsed_stable_relax.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed_stable_relax.value.object.get("score_count").?.integer);
    const relax_board_score = parsed_stable_relax.value.object.get("scores").?.array.items[0].object;
    try std.testing.expect(relax_board_score.get("id").?.integer >= lazer.stable_score_id_offset);
    try std.testing.expectEqual(stable_relax_id, relax_board_score.get("legacy_score_id").?.integer);
    try std.testing.expectEqual(@as(i64, 600), relax_board_score.get("legacy_total_score").?.integer);
    try std.testing.expect(relax_board_score.get("ranked").?.bool);
    try std.testing.expect(relax_board_score.get("has_replay").?.bool);
    try std.testing.expectEqualStrings("RX", relax_board_score.get("mods").?.array.items[1].object.get("acronym").?.string);
    const stable_relax_replay = (try store.siteReplay(std.testing.allocator, stable_relax_id)).?;
    defer std.testing.allocator.free(stable_relax_replay);
    try std.testing.expect(std.mem.indexOf(u8, stable_relax_replay, "relax-replay") != null);

    const stable_autopilot_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 2, 0, .autopilot, "[\"AP\"]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(stable_autopilot_board);
    var parsed_stable_autopilot = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stable_autopilot_board, .{});
    defer parsed_stable_autopilot.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed_stable_autopilot.value.object.get("score_count").?.integer);
    const autopilot_board_score = parsed_stable_autopilot.value.object.get("scores").?.array.items[0].object;
    try std.testing.expect(autopilot_board_score.get("id").?.integer >= lazer.stable_score_id_offset);
    try std.testing.expectEqual(stable_autopilot_id, autopilot_board_score.get("legacy_score_id").?.integer);
    try std.testing.expectEqual(@as(i64, 620), autopilot_board_score.get("legacy_total_score").?.integer);
    try std.testing.expect(autopilot_board_score.get("ranked").?.bool);
    try std.testing.expect(autopilot_board_score.get("has_replay").?.bool);
    try std.testing.expectEqualStrings("AP", autopilot_board_score.get("mods").?.array.items[1].object.get("acronym").?.string);
    const stable_autopilot_replay = (try store.siteReplay(std.testing.allocator, stable_autopilot_id)).?;
    defer std.testing.allocator.free(stable_autopilot_replay);
    try std.testing.expect(std.mem.indexOf(u8, stable_autopilot_replay, "autopilot-replay") != null);
    var hard_rock_id: i64 = 0;
    {
        var user_buf: [24]u8 = undefined;
        const user_text = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var inserted = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.lazer_scores(user_id,beatmap_id,ruleset_id,total_score,total_score_without_mods,legacy_total_score,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,rank_namespace,pp,best) VALUES($1,2,0,500,500,NULL,0.95,50,true,'A','[{\"acronym\":\"HR\"}]'::jsonb,'{}'::jsonb,'{}'::jsonb,'[]'::jsonb,'vanilla',150,false) RETURNING id", &.{user_text});
        defer inserted.deinit();
        hard_rock_id = try inserted.int(i64, 0, 0);
    }
    const hard_rock_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 2, 0, .vanilla, "[\"HR\"]", true, false, stable_mods.hard_rock, .global, 50);
    defer std.testing.allocator.free(hard_rock_board);
    try std.testing.expect(std.mem.indexOf(u8, hard_rock_board, "\"total_score\":1234") == null);
    try std.testing.expect(std.mem.indexOf(u8, hard_rock_board, "\"total_score\":500") != null);
    const hard_rock_placement = (try store.lazerScoreLeaderboardPlacement(hard_rock_id)).?;
    try std.testing.expect(hard_rock_placement.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 0), hard_rock_placement.rank);
    const native_profile_json = (try store.siteProfile(std.testing.allocator, user_id, .lazer, 0)).?;
    defer std.testing.allocator.free(native_profile_json);
    var native_profile = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, native_profile_json, .{});
    defer native_profile.deinit();
    const native_recent = native_profile.value.object.get("recent_scores").?.array.items[0].object;
    try std.testing.expectEqual(hard_rock_id, native_recent.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 500), native_recent.get("score_without_mods").?.integer);
    try std.testing.expect(std.meta.activeTag(native_recent.get("legacy_score").?) == .null);
    var custom_id: i64 = 0;
    {
        var user_buf: [24]u8 = undefined;
        const user_text = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var inserted = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.lazer_scores(user_id,beatmap_id,ruleset_id,total_score,total_score_without_mods,legacy_total_score,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,rank_namespace,pp,best) VALUES($1,2,0,600,600,NULL,0.95,60,true,'A','[{\"acronym\":\"RX\"},{\"acronym\":\"WIGGLE\"}]'::jsonb,'{}'::jsonb,'{}'::jsonb,'[]'::jsonb,'custom',60,true),($1,2,0,800,800,NULL,0.98,80,true,'A','[{\"acronym\":\"WIGGLE\"},{\"acronym\":\"HR\"}]'::jsonb,'{}'::jsonb,'{}'::jsonb,'[]'::jsonb,'custom',80,false) RETURNING id", &.{user_text});
        defer inserted.deinit();
        custom_id = try inserted.int(i64, 0, 0);
    }
    const custom_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 2, 0, .custom, "[\"WIGGLE\"]", true, false, null, .global, 50);
    defer std.testing.allocator.free(custom_board);
    try std.testing.expect(std.mem.indexOf(u8, custom_board, "\"total_score\":600") != null);
    try std.testing.expect(std.mem.indexOf(u8, custom_board, "\"total_score\":800") == null);
    const custom_placement = (try store.lazerScoreLeaderboardPlacement(custom_id)).?;
    try std.testing.expect(custom_placement.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 0), custom_placement.rank);
    try std.testing.expectEqual(Store.BeatmapRating.can_rate, try store.rateBeatmap(user_id, second_md5, null));
    const vote = try store.rateBeatmap(user_id, second_md5, 8);
    try std.testing.expectApproxEqAbs(@as(f64, 8), vote.already_voted, 0.001);

    const second_id = try store.register("raya", "raya@example.test", "11111111111111111111111111111111");
    const by_name = (try store.userByName(std.testing.allocator, "raya")).?;
    defer {
        std.testing.allocator.free(by_name.name);
        std.testing.allocator.free(by_name.safe_name);
    }
    try std.testing.expectEqual(second_id, by_name.id);
    const stable_info = (try store.stableBeatmapInfoByFilename(user_id, "artist - title (mapper) [hard].osu")).?;
    try std.testing.expectEqual(@as(i32, 1), stable_info.id);
    try std.testing.expectEqualStrings("X", stable_info.grades[0]);
    try store.addBeatmapComment(user_id, "map", 1, 12.5, "postgres map comment", null);
    const comments = try store.beatmapComments(std.testing.allocator, score_id, 1, 1);
    defer std.testing.allocator.free(comments);
    try std.testing.expect(std.mem.indexOf(u8, comments, "12.5\tmap\t\tpostgres map comment") != null);
    const stored_direct_id = try store.storeDirectMessage(second_id, user_id, "postgres offline hello");
    const initial_dm_feed = try store.lazerAllMessagesJson(std.testing.allocator, user_id, 0, 100);
    defer std.testing.allocator.free(initial_dm_feed);
    const parsed_dm_feed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, initial_dm_feed, .{});
    defer parsed_dm_feed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_dm_feed.value.array.items.len);
    const dm_message_id = parsed_dm_feed.value.array.items[0].object.get("message_id").?.integer;
    const unread = try store.unreadDirectMessages(std.testing.allocator, user_id);
    defer {
        for (unread) |*message| message.deinit(std.testing.allocator);
        std.testing.allocator.free(unread);
    }
    try std.testing.expectEqual(@as(usize, 1), unread.len);
    try std.testing.expectEqualStrings("raya", unread[0].from_name);
    try std.testing.expectEqual(stored_direct_id, unread[0].id);
    try std.testing.expect(try store.markDirectMessageRead(user_id, stored_direct_id));
    try std.testing.expect(!try store.markDirectMessageRead(user_id, stored_direct_id));
    try store.markLazerDirectMessageRead(user_id, second_id, dm_message_id);
    const cleared_dm_feed = try store.lazerAllMessagesJson(std.testing.allocator, user_id, 0, 100);
    defer std.testing.allocator.free(cleared_dm_feed);
    try std.testing.expectEqualStrings("[]", cleared_dm_feed);
    const dm_threads = try store.directMessageThreadsJson(std.testing.allocator, user_id, 50);
    defer std.testing.allocator.free(dm_threads);
    try std.testing.expect(std.mem.indexOf(u8, dm_threads, "\"name\":\"raya\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dm_threads, "\"last_message\":\"postgres offline hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dm_threads, "\"unread\":0") != null);
    const initial_friends = try store.friendIds(std.testing.allocator, user_id);
    defer std.testing.allocator.free(initial_friends);
    try std.testing.expect(std.mem.indexOfScalar(i32, initial_friends, 3) != null);
    try std.testing.expectEqual(domain.RelationshipAddResult.inserted, try store.addFriend(user_id, second_id));
    try std.testing.expectEqual(domain.RelationshipAddResult.existing, try store.addFriend(user_id, second_id));
    try std.testing.expectEqual(@as(i32, 1), (try store.lazerProfileSummary(second_id)).?.follower_count);
    try std.testing.expectEqual(@as(i32, 1), (try store.lazerBatchUserVisibility(second_id)).?.follower_count);
    const followed_user = (try store.userById(std.testing.allocator, second_id)).?;
    defer std.testing.allocator.free(followed_user.name);
    defer std.testing.allocator.free(followed_user.safe_name);
    try std.testing.expectEqual(@as(i32, 1), followed_user.follower_count);
    var compact_user: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer compact_user.deinit();
    try user_json.writeCompact(&compact_user.writer, followed_user, followed_user.show_country);
    var parsed_compact_user = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, compact_user.written(), .{});
    defer parsed_compact_user.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed_compact_user.value.object.get("follower_count").?.integer);
    const friends = try store.friendIds(std.testing.allocator, user_id);
    defer std.testing.allocator.free(friends);
    try std.testing.expect(std.mem.indexOfScalar(i32, friends, 3) != null);
    try std.testing.expect(std.mem.indexOfScalar(i32, friends, second_id) != null);
    const reverse_friends = try store.friendIds(std.testing.allocator, second_id);
    defer std.testing.allocator.free(reverse_friends);
    try std.testing.expect(std.mem.indexOfScalar(i32, reverse_friends, user_id) == null);
    var relationship_buffers: [2][24]u8 = undefined;
    const relationship_user = try std.fmt.bufPrint(&relationship_buffers[0], "{d}", .{user_id});
    const relationship_target = try std.fmt.bufPrint(&relationship_buffers[1], "{d}", .{second_id});
    {
        var relationship_lease = store.pool.acquire();
        defer relationship_lease.release();
        var restrict_sender = try postgres.queryParams(std.testing.allocator, relationship_lease.conn, "UPDATE zigcho.users SET restricted=true WHERE id=$1 RETURNING id,restricted::int", &.{relationship_user});
        try std.testing.expectEqual(@as(usize, 1), restrict_sender.rows());
        try std.testing.expectEqual(user_id, try restrict_sender.int(i32, 0, 0));
        try std.testing.expectEqual(@as(i32, 1), try restrict_sender.int(i32, 0, 1));
        restrict_sender.deinit();
    }
    try std.testing.expectEqual(@as(i32, 0), (try store.lazerProfileSummary(second_id)).?.follower_count);
    const restricted_sender_friends = try store.friendIds(std.testing.allocator, user_id);
    defer std.testing.allocator.free(restricted_sender_friends);
    try std.testing.expectEqualSlices(i32, &.{3}, restricted_sender_friends);
    try std.testing.expectEqual(domain.RelationshipAddResult.ineligible, try store.addFriend(user_id, second_id));
    {
        var relationship_lease = store.pool.acquire();
        defer relationship_lease.release();
        var unrestrict_sender = try postgres.queryParams(std.testing.allocator, relationship_lease.conn, "UPDATE zigcho.users SET restricted=false WHERE id=$1 RETURNING id,restricted::int", &.{relationship_user});
        try std.testing.expectEqual(@as(usize, 1), unrestrict_sender.rows());
        try std.testing.expectEqual(user_id, try unrestrict_sender.int(i32, 0, 0));
        try std.testing.expectEqual(@as(i32, 0), try unrestrict_sender.int(i32, 0, 1));
        unrestrict_sender.deinit();
        var restrict_target = try postgres.queryParams(std.testing.allocator, relationship_lease.conn, "UPDATE zigcho.users SET restricted=true WHERE id=$1 RETURNING id,restricted::int", &.{relationship_target});
        try std.testing.expectEqual(@as(usize, 1), restrict_target.rows());
        try std.testing.expectEqual(second_id, try restrict_target.int(i32, 0, 0));
        try std.testing.expectEqual(@as(i32, 1), try restrict_target.int(i32, 0, 1));
        restrict_target.deinit();
        var restricted_state = try postgres.queryParams(std.testing.allocator, relationship_lease.conn, "SELECT restricted::int FROM zigcho.users WHERE id=$1", &.{relationship_target});
        defer restricted_state.deinit();
        try std.testing.expectEqual(@as(i32, 1), try restricted_state.int(i32, 0, 0));
        try std.testing.expect(postgres.c.PQtransactionStatus(relationship_lease.conn) == postgres.c.PQTRANS_IDLE);
    }
    const restricted_target_friends = try store.friendIds(std.testing.allocator, user_id);
    defer std.testing.allocator.free(restricted_target_friends);
    try std.testing.expectEqual(@as(usize, 2), restricted_target_friends.len);
    try std.testing.expect(std.mem.indexOfScalar(i32, restricted_target_friends, outsider_id) != null);
    try std.testing.expect(std.mem.indexOfScalar(i32, restricted_target_friends, second_id) == null);
    try std.testing.expect(std.mem.indexOfScalar(i32, restricted_target_friends, 3) != null);
    try std.testing.expectEqual(domain.RelationshipAddResult.ineligible, try store.addFriend(user_id, second_id));
    {
        var relationship_lease = store.pool.acquire();
        defer relationship_lease.release();
        var unrestrict = try postgres.queryParams(std.testing.allocator, relationship_lease.conn, "UPDATE zigcho.users SET restricted=false WHERE id IN($1,$2)", &.{ relationship_user, relationship_target });
        unrestrict.deinit();
    }
    try std.testing.expectEqual(@as(i32, 1), (try store.lazerProfileSummary(second_id)).?.follower_count);
    try std.testing.expectEqual(domain.RelationshipAddResult.ineligible, try store.addFriend(user_id, user_id));
    try std.testing.expectEqual(domain.RelationshipAddResult.ineligible, try store.addFriend(user_id, 3));
    try std.testing.expectEqual(domain.RelationshipAddResult.ineligible, try store.addFriend(user_id, 2_000_000_000));
    try std.testing.expect(try store.removeFriend(user_id, second_id));
    try std.testing.expect(!try store.removeFriend(user_id, second_id));
    try std.testing.expectEqual(@as(i32, 0), (try store.lazerProfileSummary(second_id)).?.follower_count);
    try std.testing.expect(try store.recordReplayView(second_id, .stable, score_id));
    try std.testing.expect(try store.recordReplayView(second_id, .lazer, lazer_score_id));
    try std.testing.expectEqual(@as(i32, 2), try store.replayViewCount(user_id, .all, 0));
    try std.testing.expectEqual(@as(i32, 1), try store.replayViewCount(user_id, .stable, 0));
    try std.testing.expectEqual(@as(i32, 1), try store.replayViewCount(user_id, .lazer, 0));
    try std.testing.expectEqual(@as(i32, 2), (try store.statsForUser(user_id, 0)).?.replay_views);
    {
        var replay_history_lease = store.pool.acquire();
        defer replay_history_lease.release();
        var set_replay_months = try postgres.queryParams(
            std.testing.allocator,
            replay_history_lease.conn,
            "UPDATE zigcho.score_replay_views SET viewed_at=CASE source WHEN 'stable' THEN extract(epoch FROM timestamptz '2026-07-15 00:00:00+00')::bigint ELSE extract(epoch FROM timestamptz '2026-08-15 00:00:00+00')::bigint END WHERE owner_id=$1 RETURNING source",
            &.{relationship_user},
        );
        defer set_replay_months.deinit();
        try std.testing.expectEqual(@as(usize, 2), set_replay_months.rows());
    }
    const replay_watch_history = try store.lazerReplaysWatchedCountsJson(std.testing.allocator, user_id, 0);
    defer std.testing.allocator.free(replay_watch_history);
    var parsed_replay_watch_history = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, replay_watch_history, .{});
    defer parsed_replay_watch_history.deinit();
    const replay_watch_months = parsed_replay_watch_history.value.array.items;
    try std.testing.expectEqual(@as(usize, 2), replay_watch_months.len);
    try std.testing.expectEqualStrings("2026-07-01", replay_watch_months[0].object.get("start_date").?.string);
    try std.testing.expectEqual(@as(i64, 1), replay_watch_months[0].object.get("count").?.integer);
    try std.testing.expectEqualStrings("2026-08-01", replay_watch_months[1].object.get("start_date").?.string);
    try std.testing.expectEqual(@as(i64, 1), replay_watch_months[1].object.get("count").?.integer);
    const empty_replay_watch_history = try store.lazerReplaysWatchedCountsJson(std.testing.allocator, user_id, 1);
    defer std.testing.allocator.free(empty_replay_watch_history);
    try std.testing.expectEqualStrings("[]", empty_replay_watch_history);
    try std.testing.expectError(error.InvalidRulesetId, store.lazerReplaysWatchedCountsJson(std.testing.allocator, user_id, 4));
    const replay_rankings = try store.lazerRankingsJson(std.testing.allocator, 0, .performance, null, 1);
    defer std.testing.allocator.free(replay_rankings);
    try std.testing.expect(std.mem.indexOf(u8, replay_rankings, "\"replays_watched_by_others\":2") != null);
    try std.testing.expect(try store.recordReplayView(second_id, .stable, score_id));
    try std.testing.expect(!try store.recordReplayView(user_id, .stable, score_id));
    try std.testing.expectEqual(@as(i32, 2), try store.replayViewCount(user_id, .all, 0));
    try std.testing.expect(try store.addBlock(user_id, second_id));
    try std.testing.expect(!try store.directMessageAllowed(user_id, second_id));
    try std.testing.expectError(error.DirectMessageBlocked, store.storeDirectMessage(second_id, user_id, "blocked postgres dm"));
    try std.testing.expect(try store.removeBlock(user_id, second_id));
    try std.testing.expect(try store.addFavourite(user_id, 900000000));
    try std.testing.expect(!try store.addFavourite(user_id, 900000000));
    const favourites = try store.favouriteSetIds(std.testing.allocator, user_id);
    defer std.testing.allocator.free(favourites);
    try std.testing.expect(std.mem.indexOfScalar(i32, favourites, 900000000) != null);
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var pending_map = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,max_combo) VALUES(3,3,$1,'queue artist','queue title','hard','mapper',2,10)", &.{"33333333333333333333333333333333"});
        pending_map.deinit();
    }
    const requested = try store.requestBeatmapRank(user_id, "33333333333333333333333333333333");
    try std.testing.expectEqual(@as(u32, 1), requested.requests);
    _ = try store.nominateBeatmapSet(user_id, "33333333333333333333333333333333", "first postgres review");
    const nominated = try store.nominateBeatmapSet(second_id, "33333333333333333333333333333333", "second postgres review");
    try std.testing.expectEqual(@as(u32, 2), nominated.nominations);
    const qualified = try store.applyBeatmapRankAction(user_id, "33333333333333333333333333333333", .qualify, "postgres qualification");
    try std.testing.expectEqual(@as(i8, 5), qualified.status);
    const ranked = try store.applyBeatmapRankAction(second_id, "33333333333333333333333333333333", .rank, "postgres ranking");
    try std.testing.expectEqual(@as(i8, 3), ranked.status);
    const loved = try store.applyBeatmapRankAction(user_id, "33333333333333333333333333333333", .love, "postgres direct loved status");
    try std.testing.expectEqual(@as(i8, 6), loved.status);
    const approved = try store.applyBeatmapRankAction(second_id, "33333333333333333333333333333333", .approve, "postgres direct approved status");
    try std.testing.expectEqual(@as(i8, 4), approved.status);
    const pending = try store.applyBeatmapRankAction(user_id, "33333333333333333333333333333333", .pending, "postgres direct pending status");
    try std.testing.expectEqual(@as(i8, 2), pending.status);
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var mixed_map = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,max_combo) VALUES(4,3,$1,'queue artist','queue title','insane','mapper',4,20)", &.{"44444444444444444444444444444444"});
        mixed_map.deinit();
    }
    const mixed_loved = try store.applyBeatmapRankAction(second_id, "33333333333333333333333333333333", .love, "postgres repair mixed set as loved");
    try std.testing.expectEqual(@as(i8, 6), mixed_loved.status);
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var statuses = try postgres.query(lease.conn, "SELECT min(status),max(status),count(*) FROM zigcho.beatmaps WHERE set_id=3");
        defer statuses.deinit();
        try std.testing.expectEqual(@as(i32, 6), try statuses.int(i32, 0, 0));
        try std.testing.expectEqual(@as(i32, 6), try statuses.int(i32, 0, 1));
        try std.testing.expectEqual(@as(i64, 2), try statuses.int(i64, 0, 2));
    }
    const rank_queue = try store.beatmapRankQueue(std.testing.allocator);
    defer std.testing.allocator.free(rank_queue);
    try std.testing.expect(std.mem.indexOf(u8, rank_queue, "set 3") == null);
    try store.recordPublicMessage(user_id, "#osu", "postgres chat history");
    try store.recordAudit(user_id, "server.alert", "server", "postgres audit");
    try std.testing.expect(try store.channelCanWrite("#osu", 3));
    try std.testing.expect(!try store.channelCanWrite("#announce", 3));
    try store.setChannelLocked(user_id, "#osu", true, "fixture lock");
    try std.testing.expect(!try store.channelCanWrite("#osu", 3));
    try store.setChannelLocked(user_id, "#osu", false, "fixture unlock");
    try store.setSilence(user_id, second_id, 123456789, "account.silence", "fixture silence");
    try store.addModerationNote(user_id, second_id, "fixture note");
    const notes = try store.moderationNotes(std.testing.allocator, second_id, 10);
    defer std.testing.allocator.free(notes);
    try std.testing.expect(std.mem.indexOf(u8, notes, "fixture note") != null);
    const supporter_privileges = try store.changePrivileges(user_id, second_id, 1 << 4, true);
    try std.testing.expect(supporter_privileges & (1 << 4) != 0);
    try store.setRestricted(user_id, second_id, true, "fixture restrict");
    try store.setRestricted(user_id, second_id, false, "fixture unrestrict");
    const hardware: ClientHardware = .{
        .osu_path_md5 = "acacacacacacacacacacacacacacacac",
        .adapters_md5 = "bdbdbdbdbdbdbdbdbdbdbdbdbdbdbdbd",
        .uninstall_md5 = "cececececececececececececececece",
        .disk_signature_md5 = "dfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdf",
        .client_version = "b20260811",
        .running_under_wine = false,
        .actionable = true,
    };
    var first_hardware = try store.recordClientHardware(user_id, hardware);
    defer first_hardware.deinit();
    try std.testing.expectEqual(@as(usize, 0), first_hardware.matched_user_ids.len);
    var second_hardware = try store.recordClientHardware(second_id, hardware);
    defer second_hardware.deinit();
    try std.testing.expectEqual(user_id, second_hardware.matched_user_ids[0]);
    const observed_first = (try store.userById(std.testing.allocator, user_id)).?;
    defer {
        std.testing.allocator.free(observed_first.name);
        std.testing.allocator.free(observed_first.safe_name);
    }
    const observed_second = (try store.userById(std.testing.allocator, second_id)).?;
    defer {
        std.testing.allocator.free(observed_second.name);
        std.testing.allocator.free(observed_second.safe_name);
    }
    try std.testing.expect(!observed_first.restricted);
    try std.testing.expect(!observed_second.restricted);
    {
        var first_target_buf: [32]u8 = undefined;
        var second_target_buf: [32]u8 = undefined;
        const first_target = try std.fmt.bufPrint(&first_target_buf, "user:{d}", .{user_id});
        const second_target = try std.fmt.bufPrint(&second_target_buf, "user:{d}", .{second_id});
        var hardware_lease = store.pool.acquire();
        defer hardware_lease.release();
        var hardware_audit = try postgres.queryParams(std.testing.allocator, hardware_lease.conn, "SELECT count(*) FROM zigcho.audit_log WHERE action='anticheat.hardware_match' AND target IN($1,$2)", &.{ first_target, second_target });
        defer hardware_audit.deinit();
        try std.testing.expectEqual(@as(i64, 2), try hardware_audit.int(i64, 0, 0));
    }
    try store.recordLastFmFlag(user_id, 1 << 19);

    const recalc_file = @embedFile("../../testdata/synthetic-standard.osu");
    const recalc_metadata = try beatmap.parse(recalc_file);
    const recalc_hash = beatmap.md5(recalc_file);
    try store.upsertBeatmap(recalc_metadata, &recalc_hash, 3, 1.7931, 10, recalc_file);
    {
        const encoded_recalc_file = try postgres.encodeBytea(std.testing.allocator, recalc_file);
        defer std.testing.allocator.free(encoded_recalc_file);
        var lazer_id_buf: [24]u8 = undefined;
        const lazer_id = try std.fmt.bufPrint(&lazer_id_buf, "{d}", .{lazer_score_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var attach_recalc_file = try postgres.queryParams(std.testing.allocator, lease.conn, "UPDATE zigcho.beatmaps SET osu_file=$1 WHERE id=2", &.{encoded_recalc_file});
        attach_recalc_file.deinit();
        var make_lazer_recalculable = try postgres.queryParams(std.testing.allocator, lease.conn, "UPDATE zigcho.lazer_scores SET pp=1,star_rating=0,max_combo=4,total_score_without_mods=1000000,statistics_json='{\"great\":4}'::jsonb WHERE id=$1", &.{lazer_id});
        make_lazer_recalculable.deinit();
    }
    var recalc_score = score;
    recalc_score.map_md5 = &recalc_hash;
    recalc_score.online_checksum = "66666666666666666666666666666666";
    recalc_score.total_score = 777_777;
    const recalc_score_id = try store.insertStableScore(user_id, recalc_score, 1, "recalc replay", 12_000);
    try std.testing.expectEqual(@as(u64, 4), try store.recalculatePerformance(std.testing.allocator));
    {
        var lazer_id_buf: [24]u8 = undefined;
        const lazer_id = try std.fmt.bufPrint(&lazer_id_buf, "{d}", .{lazer_score_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var recalculated_lazer = try postgres.queryParams(std.testing.allocator, lease.conn, "SELECT pp,star_rating FROM zigcho.lazer_scores WHERE id=$1", &.{lazer_id});
        defer recalculated_lazer.deinit();
        try std.testing.expect((try recalculated_lazer.float(f64, 0, 0)) > 1);
        try std.testing.expect((try recalculated_lazer.float(f64, 0, 1)) > 0);
    }
    const before_scorev2 = (try store.statsForUser(user_id, 0)).?;
    var scorev2 = recalc_score;
    scorev2.online_checksum = "77777777777777777777777777777777";
    scorev2.total_score = 2_000_000;
    scorev2.max_combo = 999;
    scorev2.mods = stable_mods.score_v2;
    const scorev2_id = try store.insertStableScore(user_id, scorev2, 1, "scorev2 replay", 30_000);
    try std.testing.expectEqualDeep(before_scorev2, (try store.statsForUser(user_id, 0)).?);
    const scorev2_placement = (try store.scoreLeaderboardPlacement(scorev2_id)).?;
    try std.testing.expect(scorev2_placement.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 0), scorev2_placement.rank);
    try store.setRestricted(second_id, user_id, false, "fixture source view");
    const scorev2_rankings = try store.siteRankings(std.testing.allocator, .scorev2, 0, 0);
    defer std.testing.allocator.free(scorev2_rankings);
    try std.testing.expect(std.mem.indexOf(u8, scorev2_rankings, "\"source\":\"scorev2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scorev2_rankings, "\"name\":\"ari\"") != null);
    const scorev2_profile = (try store.siteProfile(std.testing.allocator, user_id, .scorev2, 0)).?;
    defer std.testing.allocator.free(scorev2_profile);
    try std.testing.expect(std.mem.indexOf(u8, scorev2_profile, "\"selected_source\":\"scorev2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scorev2_profile, "\"namespace\":\"scorev2\"") != null);
    {
        var user_id_buf: [24]u8 = undefined;
        const user_id_text = try std.fmt.bufPrint(&user_id_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var corrupt = try postgres.queryParams(std.testing.allocator, lease.conn, "UPDATE zigcho.stats SET ranked_score=1,total_score=2,pp=3,plays=4,play_time=5,total_hits=6,accuracy=0.7,max_combo=8 WHERE user_id=$1 AND mode=0", &.{user_id_text});
        corrupt.deinit();
    }
    try std.testing.expectEqual(@as(u64, 5), try store.recalculatePerformance(std.testing.allocator));
    try std.testing.expectEqualDeep(before_scorev2, (try store.statsForUser(user_id, 0)).?);
    const recalculated = (try store.ppSnapshot(recalc_score_id)).?;
    try std.testing.expect(recalculated.score > 1);
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var recalc_audit = try postgres.query(lease.conn, "SELECT count(*) FROM zigcho.audit_log WHERE action='operations.pp_recalc' AND target='scores'");
        defer recalc_audit.deinit();
        try std.testing.expectEqual(@as(i64, 2), try recalc_audit.int(i64, 0, 0));
    }
    var failed_stable = score;
    failed_stable.passed = false;
    failed_stable.grade = "F";
    failed_stable.online_checksum = "abababababababababababababababab";
    failed_stable.total_score = 111_111;
    const failed_stable_id = try store.insertStableScore(user_id, failed_stable, 0, "failed", 12_000);
    try std.testing.expect((try store.stableReplay(std.testing.allocator, failed_stable_id)) == null);
    var failed_lazer = lazer_input;
    failed_lazer.passed = false;
    failed_lazer.rank = "F";
    failed_lazer.total_score = 4_321;
    failed_lazer.legacy_total_score = 3_210;
    const failed_lazer_token = try store.createLazerScoreToken(user_id, 2, second_md5, 0, "44444444444444444444444444444444");
    const failed_lazer_id = try store.submitLazerScoreToken(user_id, 2, failed_lazer_token, failed_lazer, 0, mods_json, statistics_json, "{}", "[]", "failed");
    try std.testing.expect((try store.lazerReplay(std.testing.allocator, failed_lazer_id)) == null);
    {
        var stable_buf: [24]u8 = undefined;
        var lazer_buf: [24]u8 = undefined;
        const stable_text = try std.fmt.bufPrint(&stable_buf, "{d}", .{failed_stable_id});
        const lazer_text = try std.fmt.bufPrint(&lazer_buf, "{d}", .{failed_lazer_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var stored_failed = try postgres.queryParams(std.testing.allocator, lease.conn, "SELECT (SELECT octet_length(replay) FROM zigcho.scores WHERE id=$1),(SELECT octet_length(replay) FROM zigcho.lazer_scores WHERE id=$2)", &.{ stable_text, lazer_text });
        defer stored_failed.deinit();
        try std.testing.expectEqual(@as(i32, 6), try stored_failed.int(i32, 0, 0));
        try std.testing.expectEqual(@as(i32, 6), try stored_failed.int(i32, 0, 1));
    }
    const pruned = try store.pruneBeatmapArchives(1);
    try std.testing.expectEqual(@as(i64, 1), pruned.entries);
    try std.testing.expectEqual(@as(i64, 17), pruned.bytes);
}

test "postgres custom lazer plays update local map counters without touching player stats" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_STORE_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    const user_id = try store.register("pg custom counter", "pg-custom-counter@example.test", "22222222222222222222222222222222");
    const map_md5 = "90909090909090909090909090909090";
    try store.upsertBeatmapMeta(.{
        .id = 2_000_000_101,
        .set_id = 2_000_000_100,
        .artist = "postgres counter artist",
        .title = "postgres counter title",
        .version = "postgres counter difficulty",
        .creator = "postgres counter mapper",
        .total_length = 120,
    }, map_md5, 3, 4.5, 500);

    const raw = "{\"beatmap_id\":2000000101,\"ruleset_id\":0,\"total_score\":123456,\"accuracy\":0.8,\"max_combo\":40,\"passed\":false,\"rank\":\"F\",\"mods\":[{\"acronym\":\"WIGGLE\"}],\"statistics\":{\"great\":4,\"miss\":1}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const mods_json = try lazer.jsonField(std.testing.allocator, parsed.value.object, "mods", "[]");
    defer std.testing.allocator.free(mods_json);
    const statistics_json = try lazer.jsonField(std.testing.allocator, parsed.value.object, "statistics", "{}");
    defer std.testing.allocator.free(statistics_json);
    const failed_input = try lazer.parseScore(parsed.value);
    try std.testing.expectEqual(lazer.Namespace.custom, failed_input.namespace);
    try std.testing.expect(lazer.statsMode(failed_input) == null);
    const stats_before = (try store.statsForUser(user_id, 0)).?;

    _ = try store.insertLazerScore(user_id, failed_input, 0, mods_json, statistics_json, "{}", "[]", &.{});
    const after_fail = (try store.beatmapForScore(map_md5)).?;
    try std.testing.expectEqual(@as(i32, 1), after_fail.plays);
    try std.testing.expectEqual(@as(i32, 0), after_fail.passes);

    var passed_input = failed_input;
    passed_input.passed = true;
    passed_input.rank = "A";
    passed_input.total_score = 654_321;
    _ = try store.insertLazerScore(user_id, passed_input, 999, mods_json, statistics_json, "{}", "[]", &.{});
    const after_pass = (try store.beatmapForScore(map_md5)).?;
    try std.testing.expectEqual(@as(i32, 2), after_pass.plays);
    try std.testing.expectEqual(@as(i32, 1), after_pass.passes);
    try std.testing.expectEqualDeep(stats_before, (try store.statsForUser(user_id, 0)).?);

    const set_json = (try store.lazerBeatmapSet(std.testing.allocator, 2_000_000_100, null)).?;
    defer std.testing.allocator.free(set_json);
    var set = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, set_json, .{});
    defer set.deinit();
    try std.testing.expectEqual(@as(i64, 2), set.value.object.get("play_count").?.integer);
    const map = set.value.object.get("beatmaps").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 2), map.get("playcount").?.integer);
    try std.testing.expectEqual(@as(i64, 1), map.get("passcount").?.integer);
}

test "postgres unbound room score tokens can be discarded" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_STORE_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    const user_id = try store.register("pg room token owner", "pg-room-token-owner@example.test", "44444444444444444444444444444444");
    const map_md5 = "91919191919191919191919191919191";
    try store.upsertBeatmapMeta(.{ .id = 2_000_000_111, .set_id = 2_000_000_110, .artist = "pg token artist", .title = "pg token title", .version = "pg token difficulty", .creator = "pg token mapper" }, map_md5, 3, 4, 100);
    const room_token = try store.createLazerRoomScoreToken(user_id, 2_000_000_111, map_md5, 0, "55555555555555555555555555555555");
    try std.testing.expect(Store.isLazerRoomScoreToken(room_token));
    try std.testing.expect(try store.discardUnusedLazerRoomScoreToken(user_id, room_token));
    try std.testing.expect(!try store.discardUnusedLazerRoomScoreToken(user_id, room_token));
}

test "postgres staff announcements persist chat and audit atomically" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_STORE_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    const actor_id = try store.register("pg announce admin", "pg-announce-admin@example.test", "33333333333333333333333333333333");
    try store.recordStaffAnnouncement(actor_id, "postgres server is back", "postgres maintenance finished");
    var actor_buf: [24]u8 = undefined;
    const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var committed = try postgres.queryParams(std.testing.allocator, lease.conn, "SELECT (SELECT count(*) FROM zigcho.chat_messages WHERE sender_id=3 AND target='#announce' AND message='postgres server is back'),(SELECT count(*) FROM zigcho.audit_log WHERE actor_id=$1 AND action='infra.announcement' AND target='server' AND detail='postgres maintenance finished')", &.{actor});
        defer committed.deinit();
        try std.testing.expectEqual(@as(i64, 1), try committed.int(i64, 0, 0));
        try std.testing.expectEqual(@as(i64, 1), try committed.int(i64, 0, 1));
    }
}

test "postgres credential and restriction commits revoke matching token families" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_STORE_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    const stable_binding = try stable_client.Binding.init("b20260811", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1.2.3.:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccc:dddddddddddddddddddddddddddddddd:");
    const stable_now = std.Io.Clock.real.now(std.testing.io).toSeconds();

    const password_id = try store.register("pg password target", "pg-password-target@example.test", "00000000000000000000000000000000");
    const password_game = try store.issueGameTokenPair(password_id, 60, 60, false);
    const password_web = try store.issueToken(password_id, "web:account", 60);
    const password_stable = [_]u8{'4'} ** 64;
    try store.rotateStableScoreSession(password_id, &password_stable, stable_binding, stable_now, 300);
    try store.updateAccountPassword(password_id, "11111111111111111111111111111111");
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &password_game.access, "identify")) == null);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &password_game.refresh, "")) == null);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &password_web, "web:account")) == null);
    try std.testing.expectEqual(StableScoreGraceResult.revoked, try store.consumeStableScoreGrace(&password_stable, password_id, stable_binding, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", stable_now + 1));

    const username_id = try store.register("pg username target", "pg-username-target@example.test", "00000000000000000000000000000000");
    const username_game = try store.issueGameTokenPair(username_id, 60, 60, false);
    const username_web = try store.issueToken(username_id, "web:account", 60);
    const username_stable = [_]u8{'5'} ** 64;
    try store.rotateStableScoreSession(username_id, &username_stable, stable_binding, stable_now, 300);
    try store.updateAccountUsername(username_id, "pg renamed target");
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &username_game.access, "identify")) == null);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &username_game.refresh, "")) == null);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &username_web, "web:account")) == null);
    try std.testing.expectEqual(StableScoreGraceResult.revoked, try store.consumeStableScoreGrace(&username_stable, username_id, stable_binding, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", stable_now + 1));

    const restricted_id = try store.register("pg restricted target", "pg-restricted-target@example.test", "00000000000000000000000000000000");
    const restricted_game = try store.issueGameTokenPair(restricted_id, 60, 60, false);
    const restricted_web = try store.issueToken(restricted_id, "web:account", 60);
    const restricted_stable = [_]u8{'6'} ** 64;
    try store.rotateStableScoreSession(restricted_id, &restricted_stable, stable_binding, stable_now, 300);
    try store.setRestricted(password_id, restricted_id, true, "postgres token transition fixture");
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &restricted_game.access, "identify")) == null);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &restricted_game.refresh, "")) == null);
    const appeal_session = (try store.authenticateToken(std.testing.allocator, &restricted_web, "web:account")).?;
    defer {
        std.testing.allocator.free(appeal_session.name);
        std.testing.allocator.free(appeal_session.safe_name);
    }
    try std.testing.expectEqual(StableScoreGraceResult.revoked, try store.consumeStableScoreGrace(&restricted_stable, restricted_id, stable_binding, "cccccccccccccccccccccccccccccccc", stable_now + 1));
}

test "postgres stable score grace is client bound expiring and one time" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_STORE_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    {
        var lease = store.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "DELETE FROM zigcho.users WHERE safe_name IN('pg_stable_grace','pg_stable_foreign')");
    }
    const user_id = try store.register("pg stable grace", "pg-stable-grace@example.test", "00000000000000000000000000000000");
    const foreign_id = try store.register("pg stable foreign", "pg-stable-foreign@example.test", "00000000000000000000000000000000");
    const client_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1.2.3.:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccc:dddddddddddddddddddddddddddddddd:";
    const binding = try stable_client.Binding.init("b20260811", client_hash);
    const wrong_version = try stable_client.Binding.init("b20260812", client_hash);
    const wrong_hardware = try stable_client.Binding.init("b20260811", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1.2.3.:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee:cccccccccccccccccccccccccccccccc:dddddddddddddddddddddddddddddddd:");
    const token_one = [_]u8{'1'} ** 64;
    const token_two = [_]u8{'2'} ** 64;
    const token_three = [_]u8{'3'} ** 64;
    const unknown = [_]u8{'9'} ** 64;
    const checksum_one = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const checksum_two = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    try store.rotateStableScoreSession(user_id, &token_one, binding, 1_000, 300);
    try std.testing.expectEqual(StableScoreGraceResult.current_not_grace, try store.consumeStableScoreGrace(&token_one, user_id, binding, checksum_one, 1_001));
    try std.testing.expectEqual(StableScoreGraceResult.foreign, try store.consumeStableScoreGrace(&token_one, foreign_id, binding, checksum_one, 1_001));
    try std.testing.expectEqual(StableScoreGraceResult.unknown, try store.consumeStableScoreGrace(&unknown, user_id, binding, checksum_one, 1_001));

    try store.rotateStableScoreSession(user_id, &token_two, binding, 1_010, 300);
    try std.testing.expectEqual(StableScoreGraceResult.version_mismatch, try store.consumeStableScoreGrace(&token_one, user_id, wrong_version, checksum_one, 1_011));
    try std.testing.expectEqual(StableScoreGraceResult.hardware_mismatch, try store.consumeStableScoreGrace(&token_one, user_id, wrong_hardware, checksum_one, 1_011));
    const Claim = struct {
        store: *Store,
        token: *const [64]u8,
        user_id: i32,
        binding: stable_client.Binding,
        checksum: []const u8,
        result: ?StableScoreGraceResult = null,
        failed: bool = false,

        fn run(context: *@This()) void {
            context.result = context.store.consumeStableScoreGrace(context.token, context.user_id, context.binding, context.checksum, 1_012) catch {
                context.failed = true;
                return;
            };
        }
    };
    var first_claim: Claim = .{ .store = &store, .token = &token_one, .user_id = user_id, .binding = binding, .checksum = checksum_one };
    var second_claim: Claim = .{ .store = &store, .token = &token_one, .user_id = user_id, .binding = binding, .checksum = checksum_two };
    const first_thread = try std.Thread.spawn(.{}, Claim.run, .{&first_claim});
    const second_thread = try std.Thread.spawn(.{}, Claim.run, .{&second_claim});
    first_thread.join();
    second_thread.join();
    try std.testing.expect(!first_claim.failed and !second_claim.failed);
    const first_result = first_claim.result.?;
    const second_result = second_claim.result.?;
    try std.testing.expect((first_result == .accepted and second_result == .consumed) or (first_result == .consumed and second_result == .accepted));
    const claimed_checksum = if (first_result == .accepted) checksum_one else checksum_two;
    try std.testing.expectEqual(StableScoreGraceResult.accepted, try store.consumeStableScoreGrace(&token_one, user_id, binding, claimed_checksum, 1_013));

    try store.rotateStableScoreSession(user_id, &token_three, binding, 1_020, 300);
    try std.testing.expectEqual(StableScoreGraceResult.expired, try store.consumeStableScoreGrace(&token_two, user_id, binding, checksum_two, 1_321));
    const game_tokens = try store.issueGameTokenPair(user_id, 300, 300, false);
    try std.testing.expectEqual(@as(usize, 5), try store.revokeAllGameCredentialsForUser(user_id));
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &game_tokens.access, "identify")) == null);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &game_tokens.refresh, "")) == null);
    try std.testing.expectEqual(StableScoreGraceResult.revoked, try store.consumeStableScoreGrace(&token_three, user_id, binding, checksum_two, 1_322));

    var lease = store.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "DELETE FROM zigcho.users WHERE safe_name IN('pg_stable_grace','pg_stable_foreign')");
}

test "postgres developer role changes preserve unrelated bits and revoke final staff sessions" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_STORE_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    const actor_id = try store.register("pg role developer", "pg-role-developer@example.test", "44444444444444444444444444444444");
    const target_id = try store.register("pg role target", "pg-role-target@example.test", "55555555555555555555555555555555");
    var actor_buf: [24]u8 = undefined;
    var target_buf: [24]u8 = undefined;
    const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
    const target = try std.fmt.bufPrint(&target_buf, "{d}", .{target_id});
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var roles = try postgres.queryParams(std.testing.allocator, lease.conn, "UPDATE zigcho.users SET privileges=CASE id WHEN $1 THEN 16387 ELSE 4115 END WHERE id IN($1,$2) RETURNING id", &.{ actor, target });
        defer roles.deinit();
        try std.testing.expectEqual(@as(usize, 2), roles.rows());
    }
    const staff_token = try store.issueToken(target_id, "web:staff", 3600);
    const premium = try store.changeRole(actor_id, target_id, .premium, true, "postgres permanent premium grant");
    try std.testing.expectEqual(@as(u32, 4147), premium.privileges);
    try std.testing.expect(!premium.staff_sessions_revoked);
    try std.testing.expectError(error.InvalidRoleChange, store.changePrivileges(actor_id, target_id, 3, false));
    try std.testing.expectError(error.InvalidRoleChange, store.changePrivileges(actor_id, target_id, (1 << 4) | (1 << 5), false));
    const admin = try store.changeRole(actor_id, target_id, .administrator, true, "postgres move onto admin access");
    try std.testing.expectEqual(@as(u32, 12_339), admin.privileges);
    const downgraded = try store.changeRole(actor_id, target_id, .moderator, false, "postgres moderation role replaced");
    try std.testing.expectEqual(@as(u32, 8_243), downgraded.privileges);
    try std.testing.expect(!downgraded.staff_sessions_revoked);
    const refreshed = (try store.authenticateToken(std.testing.allocator, &staff_token, "web:staff")).?;
    defer {
        std.testing.allocator.free(refreshed.name);
        std.testing.allocator.free(refreshed.safe_name);
    }
    try std.testing.expect(refreshed.privileges & (1 << 13) != 0);
    try std.testing.expect(refreshed.privileges & (1 << 12) == 0);
    const removed = try store.changeRole(actor_id, target_id, .administrator, false, "postgres admin access ended");
    try std.testing.expectEqual(@as(u32, 51), removed.privileges);
    try std.testing.expect(removed.staff_sessions_revoked);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &staff_token, "web:staff")) == null);
    const roles_json = (try store.staffRolesJson(std.testing.allocator, target_id)).?;
    defer std.testing.allocator.free(roles_json);
    try std.testing.expect(std.mem.indexOf(u8, roles_json, "\"key\":\"premium\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, roles_json, "permanent premium grant") != null);
}

test "postgres anticheat review exclusions preserve evidence and audit history" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_STORE_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    const actor_id = try store.register("pg exclusion admin", "pg-exclusion-admin@example.test", "22222222222222222222222222222222");
    const player_id = try store.register("pg excluded player", "pg-excluded-player@example.test", "33333333333333333333333333333333");
    try std.testing.expectError(error.InvalidAnticheatExclusion, store.createAnticheatExclusion(actor_id, actor_id, .all, 3600, "self exclusion"));
    try std.testing.expectError(error.InvalidAnticheatExclusion, store.createAnticheatExclusion(actor_id, player_id, .all, 3599, "too short"));
    try std.testing.expectError(error.AnticheatExclusionForbidden, store.createAnticheatExclusion(actor_id, player_id, .stable_score, 3600, "ordinary player cannot suppress review"));
    {
        var actor_buf: [24]u8 = undefined;
        const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var grant = try postgres.queryParams(std.testing.allocator, lease.conn, "UPDATE zigcho.users SET privileges=privileges|(1<<13) WHERE id=$1", &.{actor});
        grant.deinit();
    }

    const exclusion_id = try store.createAnticheatExclusion(actor_id, player_id, .stable_score, postgres_store.anticheat_exclusion_max_seconds, "postgres score calibration account");
    try std.testing.expectEqual(player_id, (try store.anticheatExclusionTarget(exclusion_id)).?);
    try std.testing.expectError(error.AnticheatExclusionOverlap, store.createAnticheatExclusion(actor_id, player_id, .all, 86400, "overlap"));
    const suppressed_id = try store.recordAnticheatObservation(player_id, .{
        .source = .stable_score,
        .module = "pg-exclusion-test",
        .action = 1,
        .reason = 7101,
        .risk_score = 450,
        .confidence_bps = 7200,
        .evidence = 8,
    });
    _ = try store.recordAnticheatObservation(player_id, .{
        .source = .stable_login,
        .module = "pg-exclusion-test",
        .action = 1,
        .reason = 7102,
        .risk_score = 350,
        .confidence_bps = 6800,
        .evidence = 1,
    });
    try store.revokeAnticheatExclusion(actor_id, exclusion_id, "postgres calibration complete");
    const after_revoke_id = try store.recordAnticheatObservation(player_id, .{
        .source = .stable_score,
        .module = "pg-exclusion-test",
        .action = 1,
        .reason = 7101,
        .risk_score = 450,
        .confidence_bps = 7200,
        .evidence = 8,
    });
    try std.testing.expect(after_revoke_id != suppressed_id);

    const expired_id = try store.createAnticheatExclusion(actor_id, player_id, .stable_login, 3600, "postgres login calibration");
    var buffers: [3][32]u8 = undefined;
    const player = try std.fmt.bufPrint(&buffers[0], "{d}", .{player_id});
    const expired = try std.fmt.bufPrint(&buffers[1], "{d}", .{expired_id});
    const suppressed = try std.fmt.bufPrint(&buffers[2], "{d}", .{suppressed_id});
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var update = try postgres.queryParams(std.testing.allocator, lease.conn, "UPDATE zigcho.anticheat_review_exclusions SET created_at=1,expires_at=3601 WHERE id=$1", &.{expired});
        update.deinit();
    }
    _ = try store.recordAnticheatObservation(player_id, .{
        .source = .stable_login,
        .module = "pg-exclusion-test",
        .action = 1,
        .reason = 7103,
        .risk_score = 375,
        .confidence_bps = 6900,
        .evidence = 1,
    });

    {
        var lease = store.pool.acquire();
        defer lease.release();
        var state = try postgres.queryParams(std.testing.allocator, lease.conn, "SELECT count(*) FILTER(WHERE review_label='pending' AND review_exclusion_id IS NULL),count(*) FILTER(WHERE review_label='pending' AND review_exclusion_id IS NOT NULL),(SELECT review_exclusion_id FROM zigcho.anticheat_observations WHERE id=$2::bigint),(SELECT count(*) FROM zigcho.audit_log WHERE action IN('anticheat.review_exclusion.create','anticheat.review_exclusion.revoke') AND target='user:'||$1::text) FROM zigcho.anticheat_observations WHERE user_id=$1::integer", &.{ player, suppressed });
        defer state.deinit();
        try std.testing.expectEqual(@as(i64, 3), try state.int(i64, 0, 0));
        try std.testing.expectEqual(@as(i64, 1), try state.int(i64, 0, 1));
        try std.testing.expectEqual(exclusion_id, try state.int(i64, 0, 2));
        try std.testing.expectEqual(@as(i64, 3), try state.int(i64, 0, 3));
    }
    const json = try store.staffAnticheatJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "postgres score calibration account") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"review_suppressed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "postgres calibration complete") != null);
}

test "postgres anticheat hardware and flags stay review only" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_STORE_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    const first_id = try store.register("pg ac first", "pg-ac-first@example.test", "00000000000000000000000000000000");
    const second_id = try store.register("pg ac second", "pg-ac-second@example.test", "11111111111111111111111111111111");
    const hardware: ClientHardware = .{
        .osu_path_md5 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .adapters_md5 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .uninstall_md5 = "cccccccccccccccccccccccccccccccc",
        .disk_signature_md5 = "dddddddddddddddddddddddddddddddd",
        .client_version = "b20260826",
        .running_under_wine = false,
        .actionable = true,
    };
    var first = try store.recordClientHardware(first_id, hardware);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 0), first.matched_user_ids.len);
    var second = try store.recordClientHardware(second_id, hardware);
    defer second.deinit();
    try std.testing.expectEqualSlices(i32, &.{first_id}, second.matched_user_ids);
    var second_again = try store.recordClientHardware(second_id, hardware);
    defer second_again.deinit();
    try std.testing.expectEqualSlices(i32, &.{first_id}, second_again.matched_user_ids);

    const hq_flags: u32 = (@as(u32, 1) << 17) | (@as(u32, 1) << 18);
    try store.recordLastFmFlag(second_id, hq_flags);
    try store.recordLastFmFlag(second_id, hq_flags);
    const observation = anticheat_evidence.stableLastFm(hq_flags).?;
    const observation_id = try store.recordAnticheatObservation(second_id, .{
        .source = .stable_lastfm,
        .module = anticheat_evidence.module_name,
        .action = observation.action,
        .reason = observation.reason,
        .risk_score = observation.risk_score,
        .confidence_bps = observation.confidence_bps,
        .evidence = observation.evidence,
        .decision_flags = observation.decision_flags,
        .rule_revision = observation.rule_revision,
    });
    try std.testing.expectEqual(observation_id, try store.recordAnticheatObservation(second_id, .{
        .source = .stable_lastfm,
        .module = anticheat_evidence.module_name,
        .action = observation.action,
        .reason = observation.reason,
        .risk_score = observation.risk_score,
        .confidence_bps = observation.confidence_bps,
        .evidence = observation.evidence,
        .decision_flags = observation.decision_flags,
        .rule_revision = observation.rule_revision,
    }));
    const distinct_observation_id = try store.recordAnticheatObservation(second_id, .{
        .source = .stable_lastfm,
        .module = anticheat_evidence.module_name,
        .action = observation.action,
        .reason = observation.reason,
        .risk_score = observation.risk_score,
        .confidence_bps = observation.confidence_bps,
        .evidence = observation.evidence,
        .decision_flags = observation.decision_flags,
        .rule_revision = observation.rule_revision,
        .movement_velocity_stddev_milli = 1,
    });
    try std.testing.expect(distinct_observation_id != observation_id);

    var score_id: i64 = 0;
    {
        var user_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{second_id});
        var score_lease = store.pool.acquire();
        defer score_lease.release();
        var score = try postgres.queryParams(std.testing.allocator, score_lease.conn, "INSERT INTO zigcho.scores(user_id,map_md5,mode,mods,score,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed) VALUES($1,'abababababababababababababababab',0,0,123456,0.98,100,100,0,0,0,0,0,true,true) RETURNING id", &.{user});
        defer score.deinit();
        score_id = try score.int(i64, 0, 0);
    }
    const score_observation_id = try store.recordAnticheatObservation(second_id, .{
        .source = .stable_score,
        .module = anticheat_evidence.module_name,
        .score_id = score_id,
        .action = 1,
        .reason = 1001,
        .risk_score = 300,
        .confidence_bps = 8000,
        .evidence = 8,
    });
    const rejected_score_observation = try store.recordAnticheatObservation(second_id, .{
        .source = .stable_score,
        .module = anticheat_evidence.module_name,
        .action = 1,
        .reason = 2006,
        .risk_score = 200,
        .confidence_bps = 10_000,
        .evidence = 16,
    });
    try std.testing.expectEqual(rejected_score_observation, try store.recordAnticheatObservation(second_id, .{
        .source = .stable_score,
        .module = anticheat_evidence.module_name,
        .action = 1,
        .reason = 2006,
        .risk_score = 200,
        .confidence_bps = 10_000,
        .evidence = 16,
    }));
    try store.reviewAnticheatObservation(first_id, score_observation_id, .uncertain, "retain postgres score evidence");
    {
        var score_buf: [24]u8 = undefined;
        var observation_buf: [24]u8 = undefined;
        const score = try std.fmt.bufPrint(&score_buf, "{d}", .{score_id});
        const score_observation = try std.fmt.bufPrint(&observation_buf, "{d}", .{score_observation_id});
        var retention_lease = store.pool.acquire();
        defer retention_lease.release();
        var aged = try postgres.queryParams(std.testing.allocator, retention_lease.conn, "UPDATE zigcho.anticheat_observations SET created_at=1,reviewed_at=1 WHERE id=$1", &.{score_observation});
        aged.deinit();
        var deleted_score = try postgres.queryParams(std.testing.allocator, retention_lease.conn, "DELETE FROM zigcho.scores WHERE id=$1", &.{score});
        deleted_score.deinit();
    }
    _ = try store.recordAnticheatObservation(second_id, .{
        .source = .stable_lastfm,
        .module = anticheat_evidence.module_name,
        .action = observation.action,
        .reason = observation.reason + 1,
        .risk_score = observation.risk_score,
        .confidence_bps = observation.confidence_bps,
        .evidence = observation.evidence,
        .decision_flags = observation.decision_flags,
        .rule_revision = observation.rule_revision,
    });
    const first_user = (try store.userById(std.testing.allocator, first_id)).?;
    defer {
        std.testing.allocator.free(first_user.name);
        std.testing.allocator.free(first_user.safe_name);
    }
    const second_user = (try store.userById(std.testing.allocator, second_id)).?;
    defer {
        std.testing.allocator.free(second_user.name);
        std.testing.allocator.free(second_user.safe_name);
    }
    try std.testing.expect(!first_user.restricted);
    try std.testing.expect(!second_user.restricted);
    const review = try store.staffAnticheatJson(std.testing.allocator);
    defer std.testing.allocator.free(review);
    try std.testing.expect(std.mem.indexOf(u8, review, "\"module\":\"zigcho-host\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, review, "\"source\":\"stable_lastfm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, review, "\"display\":\"required replay missing (2006)\"") != null);
    var first_target_buf: [32]u8 = undefined;
    var second_target_buf: [32]u8 = undefined;
    const first_target = try std.fmt.bufPrint(&first_target_buf, "user:{d}", .{first_id});
    const second_target = try std.fmt.bufPrint(&second_target_buf, "user:{d}", .{second_id});
    var lease = store.pool.acquire();
    defer lease.release();
    var score_observation_buf: [24]u8 = undefined;
    const score_observation = try std.fmt.bufPrint(&score_observation_buf, "{d}", .{score_observation_id});
    var audit = try postgres.queryParams(std.testing.allocator, lease.conn, "SELECT (SELECT count(*) FROM zigcho.audit_log WHERE action='anticheat.hardware_match' AND target IN($1,$2)),(SELECT count(*) FROM zigcho.audit_log WHERE action='stable.lastfm_flag' AND target=$2),(SELECT count(*) FROM zigcho.anticheat_observations WHERE id=$3 AND source='stable_score')", &.{ first_target, second_target, score_observation });
    defer audit.deinit();
    try std.testing.expectEqual(@as(i64, 2), try audit.int(i64, 0, 0));
    try std.testing.expectEqual(@as(i64, 1), try audit.int(i64, 0, 1));
    try std.testing.expectEqual(@as(i64, 1), try audit.int(i64, 0, 2));
}
