const std = @import("std");
const domain = @import("../../domain.zig");
const lazer = @import("../../lazer.zig");
const storage = @import("../../runtime_storage.zig");
const roomListFilter = @import("../../lazer_multiplayer.zig").roomListFilter;
const Manager = @import("../../lazer_multiplayer.zig").Manager;

test "legacy archived playlists rebuild empty ruleset filters when hydrated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/legacy-archive-rulesets.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const owner_id = try store.register("legacy archive", "legacy-archive@example.invalid", "00000000000000000000000000000000");
    var participants_buf: [32]u8 = undefined;
    const participants = try std.fmt.bufPrint(&participants_buf, "[{d}]", .{owner_id});
    try store.saveLazerMultiplayerRoomArchive(
        77,
        owner_id,
        "normal",
        \\{"id":77,"type":"playlists","status":"ended","playlist":[{"id":8,"ruleset_id":3,"expired":true},{"id":9,"ruleset_id":1,"expired":true},{"id":10,"ruleset_id":3,"expired":true}],"playlist_item_stats":{"count_active":0,"count_total":3,"ruleset_ids":[]},"zigcho_score_tokens":[{"token_id":9001}]}
    ,
        "{\"leaderboard\":[],\"user_score\":null}",
        participants,
    );

    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    const hydrated = (try manager.roomsJson(std.testing.allocator, 77, null, owner_id)).?;
    defer std.testing.allocator.free(hydrated);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, hydrated, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("idle", parsed.value.object.get("status").?.string);
    try std.testing.expect(parsed.value.object.get("zigcho_score_tokens") == null);
    const stats = parsed.value.object.get("playlist_item_stats").?.object;
    try std.testing.expectEqual(@as(i64, 0), stats.get("count_active").?.integer);
    const rulesets = stats.get("ruleset_ids").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), rulesets.len);
    try std.testing.expectEqual(@as(i64, 1), rulesets[0].integer);
    try std.testing.expectEqual(@as(i64, 3), rulesets[1].integer);
}

test "room archive and checkpoint lists free every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/room-archive-allocation.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const owner_id = try store.register("archive allocator", "archive-allocator@example.invalid", "00000000000000000000000000000000");
    var participants_buf: [32]u8 = undefined;
    const participants = try std.fmt.bufPrint(&participants_buf, "[{d}]", .{owner_id});
    try store.saveLazerMultiplayerRoomArchive(1, owner_id, "realtime", "{}", "{\"leaderboard\":[],\"user_score\":null}", participants);
    try store.saveLazerMultiplayerRoomArchive(2, owner_id, "normal", "{\"zigcho_resumable\":true}", "{\"leaderboard\":[],\"user_score\":null}", participants);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, roomArchiveListAllocationRun, .{&store});
}

test "failed room archive stays owned and retries without losing scores or tokens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/archive-retry.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("archive retry", "archive-retry@example.invalid", "00000000000000000000000000000000");
    const user: domain.User = .{ .id = user_id, .name = "archive retry", .safe_name = "archive_retry", .country = .{ 'A', 'U' } };
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    const created = try manager.restCreateRoom(std.testing.allocator, user,
        \\{"name":"archive retry","type":"head_to_head","playlist":[{"id":8,"owner_id":0,"beatmap_id":75,"ruleset_id":0}]}
    );
    std.testing.allocator.free(created);
    try manager.recordRoomScore(user_id, 1, 8, .{ .score_id = 700, .total_score = 700_000, .accuracy = 0.97, .max_combo = 400, .passed = true });
    try manager.bindRoomScoreToken(user_id, 1, 8, 7001);

    try store.exec("ALTER TABLE lazer_multiplayer_room_history RENAME TO lazer_multiplayer_room_history_unavailable");
    try manager.restCloseRoom(user_id, 1);
    for (manager.rooms) |entry| try std.testing.expect(entry == null);
    const retained = manager.pending_archives[0].?;
    try std.testing.expect(retained.ended);
    try std.testing.expectEqual(@as(usize, 1), retained.scores.items.len);
    try std.testing.expectEqual(@as(i64, 700), retained.scores.items[0].score_id);
    try std.testing.expectEqual(@as(usize, 1), retained.score_tokens.items.len);

    // Reuse the freed live-room slot before the archive backend recovers. The
    // ended room remains independently owned by the retry queue.
    const replacement = try manager.restCreateRoom(std.testing.allocator, user,
        \\{"name":"slot reuse","type":"head_to_head","playlist":[{"id":9,"owner_id":0,"beatmap_id":76,"ruleset_id":0}]}
    );
    defer std.testing.allocator.free(replacement);
    try std.testing.expectEqual(@as(i64, 2), manager.rooms[0].?.id);
    try std.testing.expect(manager.pending_archives[0] == retained);

    try store.exec("ALTER TABLE lazer_multiplayer_room_history_unavailable RENAME TO lazer_multiplayer_room_history");
    try std.testing.expectEqual(@as(usize, 1), manager.archiveExpiredRooms(std.Io.Clock.real.now(std.testing.io).toSeconds()));
    try std.testing.expectEqual(@as(i64, 2), manager.rooms[0].?.id);
    for (manager.pending_archives) |entry| try std.testing.expect(entry == null);
    var archive = (try store.lazerMultiplayerRoomArchive(std.testing.allocator, 1)).?;
    defer archive.deinit();
    try std.testing.expect(std.mem.indexOf(u8, archive.room_json, "\"score_id\":700") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive.room_json, "\"token_id\":7001") != null);
}

test "archived grace score update frees every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/archived-score-allocation.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("archive scorer", "archive-scorer@example.invalid", "00000000000000000000000000000000");
    const room_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"id\":1,\"category\":\"realtime\",\"playlist\":[{{\"id\":8,\"beatmap_id\":75,\"ruleset_id\":0}}],\"recent_participants\":[{{\"id\":{d},\"username\":\"archive scorer\",\"country_code\":\"AU\"}}],\"zigcho_score_records\":[],\"zigcho_score_tokens\":[{{\"token_id\":5001,\"user_id\":{d},\"playlist_item_id\":8}}]}}",
        .{ user_id, user_id },
    );
    defer std.testing.allocator.free(room_json);
    const participant_ids_json = try std.fmt.allocPrint(std.testing.allocator, "[{d}]", .{user_id});
    defer std.testing.allocator.free(participant_ids_json);
    var context: ArchivedScoreAllocationContext = .{ .store = &store, .user_id = user_id, .room_json = room_json, .participant_ids_json = participant_ids_json };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, archivedScoreAllocationRun, .{&context});
}

test "late archived scores preserve playlist and realtime high score eligibility" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/archived-score-category.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("archive category", "archive-category@example.invalid", "00000000000000000000000000000000");
    const participant_ids_json = try std.fmt.allocPrint(std.testing.allocator, "[{d}]", .{user_id});
    defer std.testing.allocator.free(participant_ids_json);
    const normal_token: i64 = 0x7f_ff_ff_00_00_00_00_01;
    const realtime_token: i64 = 0x7f_ff_ff_00_00_00_00_03;
    for ([_]struct { room_id: i64, category: []const u8, token_id: i64 }{
        .{ .room_id = 1, .category = "normal", .token_id = normal_token },
        .{ .room_id = 2, .category = "realtime", .token_id = realtime_token },
    }) |fixture| {
        const room_json = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"id\":{d},\"category\":\"{s}\",\"playlist\":[{{\"id\":8,\"beatmap_id\":75,\"ruleset_id\":0}}],\"recent_participants\":[{{\"id\":{d},\"username\":\"archive category\",\"country_code\":\"AU\"}}],\"zigcho_score_records\":[],\"zigcho_score_tokens\":[{{\"token_id\":{d},\"user_id\":{d},\"playlist_item_id\":8}}]}}",
            .{ fixture.room_id, fixture.category, user_id, fixture.token_id, user_id },
        );
        defer std.testing.allocator.free(room_json);
        try store.saveLazerMultiplayerRoomArchive(fixture.room_id, user_id, fixture.category, room_json, "{\"leaderboard\":[],\"user_score\":null}", participant_ids_json);
    }

    var manager = Manager.init(std.testing.allocator, std.testing.io);
    manager.store = &store;
    defer {
        manager.shutting_down = true;
        manager.deinit();
    }
    const LateScore = struct {
        manager: *Manager,
        user_id: i32,
        token_id: i64,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,

        fn run(context: *@This()) void {
            context.started.store(true, .release);
            context.manager.recordRoomScore(context.user_id, 1, 8, .{ .token_id = context.token_id, .score_id = 101, .total_score = 500_000, .accuracy = 0.9, .max_combo = 100, .passed = false }) catch |err| {
                context.failure = err;
            };
            context.done.store(true, .release);
        }
    };
    const LiveProgress = struct {
        manager: *Manager,
        user: domain.User,
        socket: *std.http.Server.WebSocket,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,

        fn run(context: *@This()) void {
            context.started.store(true, .release);
            const connection = context.manager.connect(context.user, context.socket) catch |err| {
                context.failure = err;
                context.done.store(true, .release);
                return;
            };
            connection.socket = null;
            context.manager.disconnect(connection);
            context.done.store(true, .release);
        }
    };
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const unrelated_user: domain.User = .{ .id = user_id + 1, .name = "live progress", .safe_name = "live_progress", .country = .{ 'G', 'B' } };
    store.mutex.lockUncancelable(std.testing.io);
    var late_score: LateScore = .{ .manager = &manager, .user_id = user_id, .token_id = normal_token };
    var live_progress: LiveProgress = .{ .manager = &manager, .user = unrelated_user, .socket = fake_socket };
    const late_thread = try std.Thread.spawn(.{}, LateScore.run, .{&late_score});
    const live_thread = try std.Thread.spawn(.{}, LiveProgress.run, .{&live_progress});
    while (!late_score.started.load(.acquire) or !live_progress.started.load(.acquire)) std.Thread.yield() catch {};
    _ = std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake) catch {};
    const live_progressed_while_storage_blocked = live_progress.done.load(.acquire);
    const archive_waited_for_storage = !late_score.done.load(.acquire);
    store.mutex.unlock(std.testing.io);
    late_thread.join();
    live_thread.join();
    try std.testing.expect(live_progressed_while_storage_blocked);
    try std.testing.expect(archive_waited_for_storage);
    try std.testing.expect(late_score.failure == null);
    try std.testing.expect(live_progress.failure == null);

    try manager.recordRoomScore(user_id, 2, 8, .{ .token_id = realtime_token, .score_id = 102, .total_score = 500_000, .accuracy = 0.9, .max_combo = 100, .passed = false });

    const normal_ids = (try manager.roomScoreIds(std.testing.allocator, user_id, 1, 8)).?;
    defer std.testing.allocator.free(normal_ids);
    const realtime_ids = (try manager.roomScoreIds(std.testing.allocator, user_id, 2, 8)).?;
    defer std.testing.allocator.free(realtime_ids);
    try std.testing.expectEqual(@as(usize, 0), normal_ids.len);
    try std.testing.expectEqualSlices(i64, &.{102}, realtime_ids);
    // Both exact attempts remain addressable; only the playlist high-score
    // projection excludes its failed result.
    try std.testing.expect(manager.roomContainsScore(user_id, 1, 8, 101));
    try std.testing.expect(manager.roomContainsScore(user_id, 2, 8, 102));
}

test "late archived playlist scores rebuild existing rows and never erase a valid board" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/archived-playlist-leaderboard.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("archive playlist", "archive-playlist@example.invalid", "00000000000000000000000000000000");
    const participant_ids_json = try std.fmt.allocPrint(std.testing.allocator, "[{d}]", .{user_id});
    defer std.testing.allocator.free(participant_ids_json);
    const existing_board = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"leaderboard\":[{{\"attempts\":1,\"completed\":1,\"accuracy\":0.95,\"pp\":null,\"room_id\":1,\"total_score\":400000,\"user_id\":{d},\"user\":{{\"id\":{d},\"username\":\"archive playlist\",\"avatar_url\":\"https://a.kai.ovh/{d}\",\"country_code\":\"AU\",\"is_active\":true,\"is_supporter\":true}},\"position\":1}}],\"user_score\":null}}",
        .{ user_id, user_id, user_id },
    );
    defer std.testing.allocator.free(existing_board);
    const room_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"id\":1,\"category\":\"normal\",\"playlist\":[{{\"id\":8,\"owner_id\":{d},\"beatmap_id\":75,\"ruleset_id\":0,\"playlist_order\":0,\"expired\":true}}],\"recent_participants\":[{{\"id\":{d},\"username\":\"archive playlist\",\"country_code\":\"AU\"}}],\"zigcho_score_records\":[{{\"score_id\":201,\"user_id\":{d},\"playlist_item_id\":8,\"total_score\":400000,\"accuracy\":0.95,\"max_combo\":300,\"passed\":true}}],\"zigcho_score_tokens\":[{{\"token_id\":7001,\"user_id\":{d},\"playlist_item_id\":8}}]}}",
        .{ user_id, user_id, user_id, user_id },
    );
    defer std.testing.allocator.free(room_json);
    try store.saveLazerMultiplayerRoomArchive(1, user_id, "normal", room_json, existing_board, participant_ids_json);

    var manager = Manager.init(std.testing.allocator, std.testing.io);
    manager.store = &store;
    defer {
        manager.shutting_down = true;
        manager.deinit();
    }
    try manager.recordRoomScore(user_id, 1, 8, .{ .token_id = 7001, .score_id = 202, .total_score = 500_000, .accuracy = 0.99, .max_combo = 400, .passed = true });
    var rebuilt = (try store.lazerMultiplayerRoomArchive(std.testing.allocator, 1)).?;
    defer rebuilt.deinit();
    var parsed_rebuilt = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rebuilt.leaderboard_json, .{});
    defer parsed_rebuilt.deinit();
    const rebuilt_rows = parsed_rebuilt.value.object.get("leaderboard").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), rebuilt_rows.len);
    try std.testing.expectEqual(@as(i64, 2), rebuilt_rows[0].object.get("attempts").?.integer);
    try std.testing.expectEqual(@as(i64, 1), rebuilt_rows[0].object.get("completed").?.integer);
    try std.testing.expectEqual(@as(i64, 500_000), rebuilt_rows[0].object.get("total_score").?.integer);

    const legacy_board = "{\"leaderboard\":[{\"attempts\":1,\"completed\":1,\"total_score\":123,\"position\":1}],\"user_score\":null}";
    const legacy_room_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"id\":2,\"category\":\"normal\",\"playlist\":[{{\"id\":9,\"beatmap_id\":76,\"ruleset_id\":1,\"expired\":true}}],\"recent_participants\":[{{\"id\":{d},\"username\":\"archive playlist\",\"country_code\":\"AU\"}}],\"zigcho_score_records\":[],\"zigcho_score_tokens\":[{{\"token_id\":7003,\"user_id\":{d},\"playlist_item_id\":9}}]}}",
        .{ user_id, user_id },
    );
    defer std.testing.allocator.free(legacy_room_json);
    try store.saveLazerMultiplayerRoomArchive(2, user_id, "normal", legacy_room_json, legacy_board, participant_ids_json);
    try manager.recordRoomScore(user_id, 2, 9, .{ .token_id = 7003, .score_id = 203, .total_score = 50, .accuracy = 0.5, .max_combo = 10, .passed = false });
    var preserved = (try store.lazerMultiplayerRoomArchive(std.testing.allocator, 2)).?;
    defer preserved.deinit();
    try std.testing.expectEqualStrings(legacy_board, preserved.leaderboard_json);
}

test "consumed score token recovery attaches only its canonical room score" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/consumed-room-token.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const hash = "0123456789abcdef0123456789abcdef";
    try store.exec("INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,star_rating,total_length,hit_length) VALUES(75,750,'0123456789abcdef0123456789abcdef','fixture','retry','room','mapper',3,5.0,120,100)");
    const user_id = try store.register("retry scorer", "retry-scorer@example.invalid", "00000000000000000000000000000000");
    const input: lazer.ScoreInput = .{
        .beatmap_id = 75,
        .ruleset_id = 0,
        .total_score = 765_432,
        .total_score_without_mods = 765_432,
        .accuracy = 0.987,
        .max_combo = 432,
        .passed = true,
        .mods = null,
        .statistics = .empty,
        .namespace = .vanilla,
    };
    const solo_token_id = try store.createLazerScoreToken(user_id, 75, hash, 0, "00000000000000000000000000000000");
    try std.testing.expect(!storage.Store.isLazerRoomScoreToken(solo_token_id));
    try std.testing.expectError(error.InvalidLazerScoreToken, store.submitLazerRoomScoreToken(user_id, 75, solo_token_id, input, 123, "[]", "{}", "{}", "[]", &.{}));
    const token_id = try store.createLazerRoomScoreToken(user_id, 75, hash, 0, "11111111111111111111111111111111");
    try std.testing.expect(storage.Store.isLazerRoomScoreToken(token_id));
    // A room token that could not be bound because the room closed or the
    // manager ran out of memory is still unusable on the solo submission path.
    try std.testing.expectError(error.InvalidLazerScoreToken, store.submitLazerScoreToken(user_id, 75, token_id, input, 123, "[]", "{}", "{}", "[]", &.{}));
    const score_id = try store.submitLazerRoomScoreToken(user_id, 75, token_id, input, 123, "[]", "{}", "{}", "[]", &.{});
    try std.testing.expectError(error.LazerScoreTokenUsed, store.submitLazerRoomScoreToken(user_id, 75, token_id, input, 123, "[]", "{}", "{}", "[]", &.{}));
    const recovered = (try store.consumedLazerScoreToken(user_id, 75, token_id)).?;
    try std.testing.expectEqual(score_id, recovered.score_id);
    try std.testing.expectEqual(input.total_score, recovered.total_score);
    try std.testing.expectEqual(input.accuracy, recovered.accuracy);
    try std.testing.expectEqual(@as(i32, @intCast(input.max_combo)), recovered.max_combo);
    try std.testing.expectEqual(input.passed, recovered.passed);
    try std.testing.expect((try store.consumedLazerScoreToken(user_id + 1, 75, token_id)) == null);
    try std.testing.expect((try store.consumedLazerScoreToken(user_id, 76, token_id)) == null);

    const room_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"id\":1,\"category\":\"realtime\",\"playlist\":[{{\"id\":8,\"beatmap_id\":75,\"ruleset_id\":0}}],\"recent_participants\":[{{\"id\":{d},\"username\":\"retry scorer\",\"country_code\":\"AU\"}}],\"zigcho_score_records\":[],\"zigcho_score_tokens\":[{{\"token_id\":{d},\"user_id\":{d},\"playlist_item_id\":8}}]}}",
        .{ user_id, token_id, user_id },
    );
    defer std.testing.allocator.free(room_json);
    const participant_ids = try std.fmt.allocPrint(std.testing.allocator, "[{d}]", .{user_id});
    defer std.testing.allocator.free(participant_ids);
    try store.saveLazerMultiplayerRoomArchive(1, user_id, "realtime", room_json, "{\"leaderboard\":[],\"user_score\":null}", participant_ids);

    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    try std.testing.expect(manager.scoreSubmissionContext(user_id, 1, 8, token_id) != null);
    try std.testing.expect(manager.scoreSubmissionContext(user_id, 1, 9, token_id) == null);
    try std.testing.expect(manager.scoreSubmissionContext(user_id + 1, 1, 8, token_id) == null);
    try manager.recordRoomScore(user_id, 1, 8, .{
        .token_id = token_id,
        .score_id = recovered.score_id,
        .total_score = recovered.total_score,
        .accuracy = recovered.accuracy,
        .max_combo = recovered.max_combo,
        .passed = recovered.passed,
    });
    try std.testing.expect(manager.scoreSubmissionContext(user_id, 1, 8, token_id) != null);
    try manager.recordRoomScore(user_id, 1, 8, .{
        .token_id = token_id,
        .score_id = recovered.score_id,
        .total_score = recovered.total_score,
        .accuracy = recovered.accuracy,
        .max_combo = recovered.max_combo,
        .passed = recovered.passed,
    });
    var persisted = (try store.lazerMultiplayerRoomArchive(std.testing.allocator, 1)).?;
    defer persisted.deinit();
    var persisted_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, persisted.room_json, .{});
    defer persisted_json.deinit();
    const persisted_token = persisted_json.value.object.get("zigcho_score_tokens").?.array.items[0].object;
    try std.testing.expectEqual(score_id, persisted_token.get("score_id").?.integer);

    var restarted = Manager.init(std.testing.allocator, std.testing.io);
    defer restarted.deinit();
    try restarted.bindStore(&store);
    try std.testing.expect(restarted.roomContainsScore(user_id, 1, 8, score_id));
    try std.testing.expect(restarted.scoreSubmissionContext(user_id, 1, 8, token_id) != null);
    const ids = (try restarted.roomScoreIds(std.testing.allocator, user_id, 1, 8)).?;
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(i64, &.{score_id}, ids);
}

test "planned shutdown restores long lived playlist rooms without falsely ending them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/shutdown-room.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("shutdown host", "shutdown@example.invalid", "00000000000000000000000000000000");
    const guest_id = try store.register("shutdown guest", "shutdown-guest@example.invalid", "00000000000000000000000000000000");
    const host: domain.User = .{ .id = user_id, .name = "shutdown host", .safe_name = "shutdown_host", .country = .{ 'A', 'U' } };
    const guest: domain.User = .{ .id = guest_id, .name = "shutdown guest", .safe_name = "shutdown_guest", .country = .{ 'G', 'B' } };
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const connection = try manager.connect(host, fake_socket);
    connection.socket = null;
    const room_body =
        \\{"name":"durable shutdown","password":"secret","type":"playlists","duration":30,"max_attempts":1000,"playlist":[{"id":8,"owner_id":0,"beatmap_id":75,"ruleset_id":0}]}
    ;
    const created = try manager.restCreateRoom(std.testing.allocator, host, room_body);
    defer std.testing.allocator.free(created);
    var created_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, created, .{});
    defer created_json.deinit();
    const original_ends_at = created_json.value.object.get("ends_at").?.string;
    for (0..129) |index| try manager.recordRoomScore(user_id, 1, 8, .{
        .score_id = @intCast(501 + index),
        .total_score = @intCast(900_000 + index),
        .accuracy = 1,
        .max_combo = 500,
        .passed = true,
    });
    try manager.bindRoomScoreToken(user_id, 1, 8, 7001);
    try std.testing.expect(manager.scoreSubmissionContext(user_id, 1, 8, 7001) != null);
    manager.shutdown();
    try std.testing.expect(!connection.alive.load(.acquire));
    try std.testing.expect(manager.shutting_down);
    try std.testing.expect(manager.rooms[0] == null);
    try std.testing.expect((try store.lazerMultiplayerRoomArchive(std.testing.allocator, 1)) == null);
    const checkpoints = try store.lazerMultiplayerRoomCheckpoints(std.testing.allocator);
    defer {
        for (checkpoints) |*checkpoint| checkpoint.deinit();
        std.testing.allocator.free(checkpoints);
    }
    try std.testing.expectEqual(@as(usize, 1), checkpoints.len);
    try std.testing.expect(std.mem.indexOf(u8, checkpoints[0].room_json, "\"zigcho_password\":\"secret\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, checkpoints[0].room_json, "\"score_id\":501") != null);
    try std.testing.expect(std.mem.indexOf(u8, checkpoints[0].room_json, "\"score_id\":629") != null);
    try std.testing.expect(std.mem.indexOf(u8, checkpoints[0].room_json, "\"token_id\":7001") != null);
    manager.shutdown();
    try std.testing.expectError(error.ServerShuttingDown, manager.connect(host, fake_socket));

    var reopened = Manager.init(std.testing.allocator, std.testing.io);
    defer reopened.deinit();
    try reopened.bindStore(&store);
    try std.testing.expect(reopened.rooms[0] != null);
    const restored_json = (try reopened.roomsJson(std.testing.allocator, 1, null, user_id)).?;
    defer std.testing.allocator.free(restored_json);
    var restored = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, restored_json, .{});
    defer restored.deinit();
    try std.testing.expect(restored.value.object.get("zigcho_score_tokens") == null);
    try std.testing.expectEqualStrings("idle", restored.value.object.get("status").?.string);
    try std.testing.expectEqualStrings(original_ends_at, restored.value.object.get("ends_at").?.string);
    const attempt = restored.value.object.get("current_user_score").?.object.get("playlist_item_attempts").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 129), attempt.get("attempts").?.integer);
    const score_ids = (try reopened.roomScoreIds(std.testing.allocator, user_id, 1, 8)).?;
    defer std.testing.allocator.free(score_ids);
    try std.testing.expectEqualSlices(i64, &.{629}, score_ids);
    try std.testing.expect(reopened.roomContainsScore(user_id, 1, 8, 501));
    try std.testing.expect(reopened.roomContainsScore(user_id, 1, 8, 629));
    try std.testing.expect(reopened.scoreSubmissionContext(user_id, 1, 8, 7001) != null);
    const archived_older_detail = (try reopened.roomScoreRanking(std.testing.allocator, user_id, 1, 8, 501)).?;
    try std.testing.expectEqual(@as(usize, 2), archived_older_detail.position);
    try std.testing.expectEqual(@as(usize, 0), archived_older_detail.higher_count);
    try std.testing.expectEqual(@as(usize, 0), archived_older_detail.lower_count);
    const restored_room = reopened.rooms[0].?;
    try std.testing.expectEqual(@as(usize, 1), restored_room.user_count);
    try std.testing.expectEqual(@as(usize, 1), restored_room.participant_count);
    const fresh_connection = try reopened.connect(host, fake_socket);
    fresh_connection.socket = null;
    try std.testing.expectError(error.InvalidMultiplayerPassword, reopened.joinRoom(fresh_connection, "restart-wrong-password", 1, "wrong"));
    try std.testing.expectEqual(@as(?i64, null), fresh_connection.room_id);
    try reopened.joinRoom(fresh_connection, "restart-rebind", 1, "secret");
    try std.testing.expectEqual(@as(?i64, 1), fresh_connection.room_id);
    try std.testing.expectEqual(@as(usize, 1), restored_room.user_count);
    try std.testing.expectEqual(@as(usize, 1), restored_room.participant_count);
    try std.testing.expectError(error.InvalidMultiplayerPassword, reopened.restJoinRoom(std.testing.allocator, guest, 1, "wrong"));
    const guest_joined = try reopened.restJoinRoom(std.testing.allocator, guest, 1, "secret");
    std.testing.allocator.free(guest_joined);
    try reopened.restPartRoom(guest_id, 1);
    const remaining_checkpoints = try store.lazerMultiplayerRoomCheckpoints(std.testing.allocator);
    defer std.testing.allocator.free(remaining_checkpoints);
    try std.testing.expectEqual(@as(usize, 0), remaining_checkpoints.len);
    try reopened.restCloseRoom(user_id, 1);
    var archive = (try store.lazerMultiplayerRoomArchive(std.testing.allocator, 1)).?;
    defer archive.deinit();
    try std.testing.expect(std.mem.indexOf(u8, archive.room_json, "zigcho_password") == null);
    try std.testing.expect(std.mem.indexOf(u8, archive.room_json, "zigcho_resumable") == null);
    try std.testing.expect(std.mem.indexOf(u8, archive.room_json, "\"score_id\":501") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive.room_json, "\"score_id\":629") != null);
}

test "checkpoint hydration failure stays hidden and retries on a later restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/retry-room.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("retry host", "retry-host@example.invalid", "00000000000000000000000000000000");
    const host: domain.User = .{ .id = user_id, .name = "retry host", .safe_name = "retry_host", .country = .{ 'A', 'U' } };
    {
        var manager = Manager.init(std.testing.allocator, std.testing.io);
        defer manager.deinit();
        try manager.bindStore(&store);
        const room_body =
            \\{"name":"retry hydration","type":"playlists","duration":30,"playlist":[{"id":8,"owner_id":0,"beatmap_id":75,"ruleset_id":0}]}
        ;
        const created = try manager.restCreateRoom(std.testing.allocator, host, room_body);
        std.testing.allocator.free(created);
        manager.shutdown();
    }
    // Force only beatmap hydration to fail after the checkpoint itself can be
    // listed and parsed successfully.
    try store.exec("ALTER TABLE beatmaps RENAME TO beatmaps_unavailable;");
    var reopened = Manager.init(std.testing.allocator, std.testing.io);
    defer reopened.deinit();
    try reopened.bindStore(&store);
    for (reopened.rooms) |entry| try std.testing.expect(entry == null);
    try std.testing.expect((try store.lazerMultiplayerRoomArchive(std.testing.allocator, 1)) == null);
    const checkpoints = try store.lazerMultiplayerRoomCheckpoints(std.testing.allocator);
    defer {
        for (checkpoints) |*checkpoint| checkpoint.deinit();
        std.testing.allocator.free(checkpoints);
    }
    try std.testing.expectEqual(@as(usize, 1), checkpoints.len);
    try std.testing.expectEqual(@as(i64, 1), checkpoints[0].room_id);
}

test "completed lazer rooms and score boards survive manager restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/multiplayer-history.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,star_rating,total_length,hit_length) VALUES(75,750,'0123456789abcdef0123456789abcdef','fixture','kept','history','mapper',3,5.25,143,119)");
    const host_id = try store.register("room host", "room-host@example.invalid", "00000000000000000000000000000000");
    const guest_id = try store.register("room guest", "room-guest@example.invalid", "00000000000000000000000000000000");
    const host: domain.User = .{ .id = host_id, .name = "room host", .safe_name = "room_host", .country = .{ 'A', 'U' } };
    const guest: domain.User = .{ .id = guest_id, .name = "room guest", .safe_name = "room_guest", .country = .{ 'G', 'B' } };
    const room_body = try std.fmt.allocPrint(std.testing.allocator, "{{\"name\":\"kept room\",\"type\":\"head_to_head\",\"queue_mode\":\"host_only\",\"playlist\":[{{\"id\":8,\"owner_id\":{d},\"beatmap_id\":75,\"ruleset_id\":0,\"beatmap\":{{\"checksum\":\"0123456789abcdef0123456789abcdef\",\"difficulty_rating\":5.25,\"beatmapset_id\":750,\"status\":\"ranked\",\"version\":\"history\",\"beatmapset\":{{\"artist\":\"fixture\",\"title\":\"kept\",\"creator\":\"mapper\"}}}}}}]}}", .{host_id});
    defer std.testing.allocator.free(room_body);

    {
        var manager = Manager.init(std.testing.allocator, std.testing.io);
        defer manager.deinit();
        try manager.bindStore(&store);
        const created = try manager.restCreateRoom(std.testing.allocator, host, room_body);
        std.testing.allocator.free(created);
        const joined = try manager.restJoinRoom(std.testing.allocator, guest, 1, "");
        std.testing.allocator.free(joined);
        try manager.recordRoomScore(host_id, 1, 8, .{ .score_id = 201, .total_score = 700_000, .accuracy = 0.97, .max_combo = 400, .passed = true });
        try manager.recordRoomScore(guest_id, 1, 8, .{ .score_id = 202, .total_score = 900_000, .accuracy = 0.99, .max_combo = 500, .passed = true });
        try std.testing.expect(manager.scoreTokenContext(host_id, 1, 8) != null);
        try manager.bindRoomScoreToken(host_id, 1, 8, 555);
        try manager.bindRoomScoreToken(host_id, 1, 8, 557);
        try std.testing.expect(manager.scoreSubmissionContext(host_id, 1, 8, 555) != null);
        try std.testing.expect(manager.scoreSubmissionContext(host_id, 1, 8, 556) == null);
        try manager.restPartRoom(guest_id, 1);
        // Closing a room may archive it while its last live state was playing.
        // The persisted lazer model must still expose every ended room as idle.
        manager.rooms[0].?.state = 2;
        try manager.restCloseRoom(host_id, 1);
    }

    var reopened = Manager.init(std.testing.allocator, std.testing.io);
    defer reopened.deinit();
    try reopened.bindStore(&store);
    const archived = (try reopened.roomsJson(std.testing.allocator, 1, null, host_id)).?;
    defer std.testing.allocator.free(archived);
    var parsed_room = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, archived, .{});
    defer parsed_room.deinit();
    try std.testing.expectEqualStrings("idle", parsed_room.value.object.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 2), parsed_room.value.object.get("recent_participants").?.array.items.len);
    const archived_beatmap = parsed_room.value.object.get("playlist").?.array.items[0].object.get("beatmap").?.object;
    try std.testing.expectEqual(@as(i64, 143), archived_beatmap.get("total_length").?.integer);
    try std.testing.expectEqual(@as(i64, 119), archived_beatmap.get("hit_length").?.integer);
    const archived_current = parsed_room.value.object.get("current_playlist_item").?.object.get("beatmap").?.object;
    try std.testing.expectEqual(@as(i64, 143), archived_current.get("total_length").?.integer);
    try std.testing.expectEqual(@as(i64, 119), archived_current.get("hit_length").?.integer);
    try std.testing.expectEqual(@as(usize, 2), parsed_room.value.object.get("zigcho_score_records").?.array.items.len);
    const archived_context = reopened.scoreContext(host_id, 1, 8).?;
    try std.testing.expectEqual(@as(i32, 75), archived_context.beatmap_id);
    try std.testing.expectEqual(@as(u8, 0), archived_context.ruleset_id);
    // History remains readable, new token minting stops immediately, and a
    // pre-minted token may still complete during the official grace window.
    try std.testing.expect(reopened.scoreTokenContext(host_id, 1, 8) == null);
    try std.testing.expect(reopened.scoreSubmissionContext(host_id, 1, 8, 555) != null);
    try std.testing.expect(reopened.scoreSubmissionContext(host_id, 1, 8, 557) != null);
    try std.testing.expect(reopened.scoreSubmissionContext(host_id, 1, 8, 556) == null);
    try std.testing.expect(reopened.scoreSubmissionContext(guest_id, 1, 8, 555) == null);
    try std.testing.expect(reopened.scoreContext(host_id + 1000, 1, 8) == null);
    try reopened.recordRoomScore(host_id, 1, 8, .{ .token_id = 555, .score_id = 203, .total_score = 950_000, .accuracy = 0.995, .max_combo = 550, .passed = true });
    try std.testing.expect(reopened.roomContainsScore(host_id, 1, 8, 203));
    try std.testing.expect(reopened.scoreSubmissionContext(host_id, 1, 8, 555) != null);
    try reopened.recordRoomScore(host_id, 1, 8, .{ .token_id = 555, .score_id = 203, .total_score = 950_000, .accuracy = 0.995, .max_combo = 550, .passed = true });
    var restarted = Manager.init(std.testing.allocator, std.testing.io);
    defer restarted.deinit();
    try restarted.bindStore(&store);
    const restarted_score_ids = (try restarted.roomScoreIds(std.testing.allocator, host_id, 1, 8)).?;
    defer std.testing.allocator.free(restarted_score_ids);
    try std.testing.expectEqualSlices(i64, &.{ 203, 202 }, restarted_score_ids);
    try std.testing.expect(restarted.scoreSubmissionContext(host_id, 1, 8, 555) != null);
    try store.exec("UPDATE lazer_multiplayer_room_history SET ended_at=unixepoch()-301 WHERE room_id=1");
    try std.testing.expect(restarted.scoreSubmissionContext(host_id, 1, 8, 555) == null);
    try std.testing.expect(restarted.scoreSubmissionContext(host_id, 1, 8, 557) == null);
    try std.testing.expectError(error.MultiplayerRoomNotFound, restarted.recordRoomScore(host_id, 1, 8, .{ .token_id = 557, .score_id = 204, .total_score = 1_000_000, .accuracy = 1, .max_combo = 600, .passed = true }));
    const archived_score_ids = (try reopened.roomScoreIds(std.testing.allocator, guest_id, 1, 8)).?;
    defer std.testing.allocator.free(archived_score_ids);
    try std.testing.expectEqualSlices(i64, &.{ 203, 202 }, archived_score_ids);
    try std.testing.expectEqual(@as(?i64, 202), reopened.roomScoreIdForUser(host_id, 1, 8, guest_id));
    try std.testing.expect(reopened.roomContainsScore(guest_id, 1, 8, 201));
    try std.testing.expect(!reopened.roomContainsScore(host_id + 1000, 1, 8, 201));
    const leaderboard = (try reopened.roomLeaderboardJson(std.testing.allocator, 0, 1)).?;
    defer std.testing.allocator.free(leaderboard);
    var parsed_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, leaderboard, .{});
    defer parsed_board.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed_board.value.object.get("leaderboard").?.array.items.len);
    try std.testing.expectEqual(@as(i64, host_id), parsed_board.value.object.get("leaderboard").?.array.items[0].object.get("user_id").?.integer);
    try std.testing.expectEqual(@as(i64, 1_650_000), parsed_board.value.object.get("leaderboard").?.array.items[0].object.get("total_score").?.integer);
    const ended = (try reopened.roomsJson(std.testing.allocator, null, try roomListFilter(host_id, "ended", "idle", "realtime"), host_id)).?;
    defer std.testing.allocator.free(ended);
    var parsed_ended = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, ended, .{});
    defer parsed_ended.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_ended.value.array.items.len);
    const ended_playing = (try reopened.roomsJson(std.testing.allocator, null, try roomListFilter(host_id, "ended", "playing", "realtime"), host_id)).?;
    defer std.testing.allocator.free(ended_playing);
    try std.testing.expectEqualStrings("[]", ended_playing);
    const open = (try reopened.roomsJson(std.testing.allocator, null, .{ .requester_id = 0, .mode = .open }, 0)).?;
    defer std.testing.allocator.free(open);
    try std.testing.expectEqualStrings("[]", open);

    const next = try reopened.restCreateRoom(std.testing.allocator, host, room_body);
    defer std.testing.allocator.free(next);
    var parsed_next = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, next, .{});
    defer parsed_next.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed_next.value.object.get("id").?.integer);
}

pub fn roomArchiveListAllocationRun(allocator: std.mem.Allocator, store: *storage.Store) !void {
    const archives = try store.lazerMultiplayerRoomArchives(allocator, 64);
    defer {
        for (archives) |*archive| archive.deinit();
        allocator.free(archives);
    }
    try std.testing.expectEqual(@as(usize, 1), archives.len);
    const checkpoints = try store.lazerMultiplayerRoomCheckpoints(allocator);
    defer {
        for (checkpoints) |*checkpoint| checkpoint.deinit();
        allocator.free(checkpoints);
    }
    try std.testing.expectEqual(@as(usize, 1), checkpoints.len);
}

pub const ArchivedScoreAllocationContext = struct {
    store: *storage.Store,
    user_id: i32,
    room_json: []const u8,
    participant_ids_json: []const u8,
};

pub fn archivedScoreAllocationRun(allocator: std.mem.Allocator, context: *ArchivedScoreAllocationContext) !void {
    try context.store.saveLazerMultiplayerRoomArchive(1, context.user_id, "realtime", context.room_json, "{\"leaderboard\":[],\"user_score\":null}", context.participant_ids_json);
    var manager = Manager.init(allocator, std.testing.io);
    manager.store = context.store;
    defer {
        manager.shutting_down = true;
        manager.deinit();
    }
    try manager.recordRoomScore(context.user_id, 1, 8, .{ .token_id = 5001, .score_id = 9001, .total_score = 500_000, .accuracy = 0.98, .max_combo = 400, .passed = true });
    var archive = (try context.store.lazerMultiplayerRoomArchive(allocator, 1)).?;
    defer archive.deinit();
    try std.testing.expect(std.mem.indexOf(u8, archive.room_json, "\"score_id\":9001") != null);
}
