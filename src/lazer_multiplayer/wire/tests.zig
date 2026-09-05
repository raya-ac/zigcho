const std = @import("std");
const storage = @import("../../runtime_storage.zig");
const RoomScorePath = @import("../../lazer_multiplayer.zig").RoomScorePath;
const RoomUserScorePath = @import("../../lazer_multiplayer.zig").RoomUserScorePath;
const RoomListMode = @import("../../lazer_multiplayer.zig").RoomListMode;
const RoomListStatus = @import("../../lazer_multiplayer.zig").RoomListStatus;
const RoomListKind = @import("../../lazer_multiplayer.zig").RoomListKind;
const roomListFilter = @import("../../lazer_multiplayer.zig").roomListFilter;
const parseRoomLeaderboardPath = @import("../../lazer_multiplayer.zig").parseRoomLeaderboardPath;
const parseRoomUserScorePath = @import("../../lazer_multiplayer.zig").parseRoomUserScorePath;
const RoomScoreRecord = @import("../../lazer_multiplayer.zig").RoomScoreRecord;
const room_score_around_limit = @import("../../lazer_multiplayer.zig").room_score_around_limit;
const sortRoomScores = @import("../../lazer_multiplayer.zig").sortRoomScores;
const considerHighScore = @import("../../lazer_multiplayer.zig").considerHighScore;
const MessagePackReader = @import("../../lazer_multiplayer.zig").MessagePackReader;
const MessagePackWriter = @import("../../lazer_multiplayer.zig").MessagePackWriter;
const validSignalRHandshake = @import("../../lazer_multiplayer.zig").validSignalRHandshake;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const writeRoomScoreDetailJson = @import("../scores/serialization.zig").writeRoomScoreDetailJson;
const parseRoomPath = @import("../../lazer_multiplayer.zig").parseRoomPath;
const parseRoomScorePath = @import("../../lazer_multiplayer.zig").parseRoomScorePath;

test "bounded messagepack framing accepts a room snapshot and rejects nested bombs" {
    var body: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer body.deinit();
    const pack: MessagePackWriter = .{ .writer = &body.writer };
    try pack.array(3);
    try pack.integer(1);
    try pack.string("room");
    try pack.boolean(true);
    var reader: MessagePackReader = .{ .data = body.written() };
    try std.testing.expectEqual(@as(usize, 3), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 1), try reader.integer());
    try std.testing.expectEqualStrings("room", try reader.string());
    try std.testing.expect(try reader.boolean());

    const nested = [_]u8{0x91} ** 17 ++ [_]u8{0xc0};
    var nested_reader: MessagePackReader = .{ .data = &nested };
    try std.testing.expectError(error.MessagePackNestingTooDeep, nested_reader.skip(0));
}

test "lazer multiplayer room path only accepts exact positive ids" {
    try std.testing.expectEqual(@as(?i64, 42), parseRoomPath("/api/v2/rooms/42"));
    try std.testing.expectEqual(@as(?i64, null), parseRoomPath("/api/v2/rooms/42/scores"));
    try std.testing.expectEqual(@as(?i64, null), parseRoomPath("/api/v2/rooms/0"));
}

test "lazer multiplayer score path separates room playlist and token ids" {
    const create = parseRoomScorePath("/api/v2/rooms/5/playlist/8/scores").?;
    try std.testing.expectEqual(@as(i64, 5), create.room_id);
    try std.testing.expectEqual(@as(i64, 8), create.playlist_item_id);
    try std.testing.expectEqual(@as(?i64, null), create.token_id);
    const submit = parseRoomScorePath("/api/v2/rooms/5/playlist/8/scores/13").?;
    try std.testing.expectEqual(@as(?i64, 13), submit.token_id);
    try std.testing.expectEqual(@as(?RoomScorePath, null), parseRoomScorePath("/api/v2/rooms/5/playlist/users/scores"));
}

test "lazer multiplayer REST room paths cover leaderboard and user scores" {
    try std.testing.expectEqual(@as(?i64, 5), parseRoomLeaderboardPath("/api/v2/rooms/5/leaderboard"));
    try std.testing.expectEqual(@as(?i64, null), parseRoomLeaderboardPath("/api/v2/rooms/5/leaderboard/extra"));
    const user_score = parseRoomUserScorePath("/api/v2/rooms/5/playlist/8/scores/users/13").?;
    try std.testing.expectEqual(@as(i64, 5), user_score.room_id);
    try std.testing.expectEqual(@as(i64, 8), user_score.playlist_item_id);
    try std.testing.expectEqual(@as(i32, 13), user_score.user_id);
    try std.testing.expectEqual(@as(?RoomUserScorePath, null), parseRoomUserScorePath("/api/v2/rooms/5/playlist/8/scores/users/0"));
    try std.testing.expectEqual(RoomListMode.open, (try roomListFilter(4, "open", "idle", "realtime")).mode);
    try std.testing.expectEqual(RoomListStatus.idle, (try roomListFilter(4, "open", "idle", "realtime")).status.?);
    try std.testing.expectEqual(RoomListKind.realtime, (try roomListFilter(4, "open", "idle", "realtime")).kind);
    try std.testing.expectEqual(RoomListKind.playlists, (try roomListFilter(4, "open", null, "")).kind);
    try std.testing.expectError(error.InvalidRoomListFilter, roomListFilter(4, "closed", null, "realtime"));
    try std.testing.expectError(error.InvalidRoomListFilter, roomListFilter(4, "open", null, "made_up"));
}

test "multiplayer never serializes a hidden local country" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/room-country-privacy.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("hidden host", "hidden-host@example.invalid", "00000000000000000000000000000000");
    try store.updateCountry(user_id, .{ 'A', 'U' });
    try store.updateSiteProfile(user_id, .{ .bio = "", .title = "", .pronouns = "", .location = "", .website = "", .accent = .pink, .preferred_mode = 0, .profile_source = .all, .avatar_key = 1, .show_country = false, .show_profile_stats = true, .show_recent_scores = true });
    const archived = try std.fmt.allocPrint(std.testing.allocator, "{{\"id\":99,\"host\":{{\"id\":{d},\"username\":\"hidden host\",\"country_code\":\"AU\"}},\"recent_participants\":[{{\"id\":{d},\"username\":\"hidden host\",\"country_code\":\"AU\"}}],\"playlist\":[]}}", .{ user_id, user_id });
    defer std.testing.allocator.free(archived);
    const archived_leaderboard = try std.fmt.allocPrint(std.testing.allocator, "{{\"leaderboard\":[{{\"user\":{{\"id\":{d},\"username\":\"hidden host\",\"country_code\":\"AU\"}}}}],\"user_score\":{{\"user\":{{\"id\":{d},\"username\":\"hidden host\",\"country_code\":\"AU\"}}}}}}", .{ user_id, user_id });
    defer std.testing.allocator.free(archived_leaderboard);
    try store.saveLazerMultiplayerRoomArchive(99, user_id, "realtime", archived, archived_leaderboard, "[]");

    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    const user = (try store.userById(std.testing.allocator, user_id)).?;
    defer std.testing.allocator.free(user.name);
    defer std.testing.allocator.free(user.safe_name);
    try std.testing.expect(!user.show_country);

    const archived_json = (try manager.roomsJson(std.testing.allocator, 99, null, 0)).?;
    defer std.testing.allocator.free(archived_json);
    try std.testing.expect(std.mem.indexOf(u8, archived_json, "\"country_code\":\"AU\"") == null);
    try std.testing.expect(std.mem.count(u8, archived_json, "\"country_code\":\"XX\"") == 2);
    const leaderboard_json = (try manager.roomLeaderboardJson(std.testing.allocator, user_id, 99)).?;
    defer std.testing.allocator.free(leaderboard_json);
    try std.testing.expect(std.mem.indexOf(u8, leaderboard_json, "\"country_code\":\"AU\"") == null);
    try std.testing.expect(std.mem.count(u8, leaderboard_json, "\"country_code\":\"XX\"") == 2);

    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const connection = try manager.connect(user, fake_socket);
    connection.socket = null;
    try std.testing.expectEqualSlices(u8, "XX", &connection.user_country);
    const created = try manager.restCreateRoom(std.testing.allocator, user,
        \\{"name":"private country","type":"head_to_head","playlist":[{"id":8,"owner_id":0,"beatmap_id":75,"ruleset_id":0}]}
    );
    defer std.testing.allocator.free(created);
    try std.testing.expect(std.mem.indexOf(u8, created, "\"country_code\":\"AU\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, created, "\"country_code\":\"XX\"") != null);
    try manager.restCloseRoom(user_id, 100);
    manager.disconnect(connection);
}

test "playlist score detail follows pinned position and scores around JSON" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const higher = [_][]const u8{
        "{\"id\":12,\"total_score\":900}",
        "{\"id\":11,\"total_score\":1000}",
    };
    const lower = [_][]const u8{"{\"id\":14,\"total_score\":700}"};
    try writeRoomScoreDetailJson(&output.writer, "{\"id\":13,\"total_score\":800}", 3, &higher, &lower);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 3), parsed.value.object.get("position").?.integer);
    const around = parsed.value.object.get("scores_around").?.object;
    const higher_page = around.get("higher").?.object;
    try std.testing.expectEqual(@as(i64, 12), higher_page.get("scores").?.array.items[0].object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, room_score_around_limit), higher_page.get("params").?.object.get("limit").?.integer);
    try std.testing.expectEqualStrings("score_asc", higher_page.get("params").?.object.get("sort").?.string);
    try std.testing.expect(std.meta.activeTag(higher_page.get("cursor").?) == .null);
    const lower_page = around.get("lower").?.object;
    try std.testing.expectEqual(@as(i64, 14), lower_page.get("scores").?.array.items[0].object.get("id").?.integer);
    try std.testing.expectEqualStrings("score_desc", lower_page.get("params").?.object.get("sort").?.string);
    try std.testing.expectError(error.InvalidRoomScoreJson, writeRoomScoreDetailJson(&output.writer, "[]", 1, &.{}, &.{}));
}

test "playlist score ordering is deterministic across score ties" {
    var scores = [_]RoomScoreRecord{
        .{ .score_id = 14, .user_id = 4, .playlist_item_id = 8, .total_score = 900, .accuracy = 1, .max_combo = 1, .passed = true },
        .{ .score_id = 11, .user_id = 7, .playlist_item_id = 8, .total_score = 1000, .accuracy = 1, .max_combo = 1, .passed = true },
        .{ .score_id = 12, .user_id = 9, .playlist_item_id = 8, .total_score = 900, .accuracy = 1, .max_combo = 1, .passed = true },
    };
    sortRoomScores(&scores);
    try std.testing.expectEqual(@as(i64, 11), scores[0].score_id);
    try std.testing.expectEqual(@as(i64, 12), scores[1].score_id);
    try std.testing.expectEqual(@as(i64, 14), scores[2].score_id);
}

test "playlist and realtime rooms promote the same failed score differently" {
    const failed: RoomScoreRecord = .{
        .score_id = 15,
        .user_id = 4,
        .playlist_item_id = 8,
        .total_score = 900,
        .accuracy = 0.75,
        .max_combo = 25,
        .passed = false,
    };
    const zero_pass: RoomScoreRecord = .{
        .score_id = 16,
        .user_id = 7,
        .playlist_item_id = 8,
        .total_score = 0,
        .accuracy = 1,
        .max_combo = 1,
        .passed = true,
    };
    var normal: std.ArrayList(RoomScoreRecord) = .empty;
    defer normal.deinit(std.testing.allocator);
    try considerHighScore(std.testing.allocator, &normal, failed, false);
    try considerHighScore(std.testing.allocator, &normal, zero_pass, false);
    try std.testing.expectEqual(@as(usize, 0), normal.items.len);

    var realtime: std.ArrayList(RoomScoreRecord) = .empty;
    defer realtime.deinit(std.testing.allocator);
    try considerHighScore(std.testing.allocator, &realtime, failed, true);
    try considerHighScore(std.testing.allocator, &realtime, zero_pass, true);
    try std.testing.expectEqual(@as(usize, 1), realtime.items.len);
    try std.testing.expectEqual(failed.score_id, realtime.items[0].score_id);
}

test "signalr accepts messagepack handshake bytes independent of websocket opcode" {
    try std.testing.expect(validSignalRHandshake(std.testing.allocator, "{\"protocol\":\"messagepack\",\"version\":1}\x1e"));
    try std.testing.expect(validSignalRHandshake(std.testing.allocator, "{\"version\":1,\"protocol\":\"messagepack\"}\x1e"));
    try std.testing.expect(!validSignalRHandshake(std.testing.allocator, "{\"protocol\":\"json\",\"version\":1}\x1e"));
    try std.testing.expect(!validSignalRHandshake(std.testing.allocator, "{\"protocol\":\"messagepack\",\"version\":1}"));
}
