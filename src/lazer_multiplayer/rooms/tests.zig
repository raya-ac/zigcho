const std = @import("std");
const domain = @import("../../domain.zig");
const storage = @import("../../runtime_storage.zig");
const max_room_scores = @import("../../lazer_multiplayer.zig").max_room_scores;
const roomListFilter = @import("../../lazer_multiplayer.zig").roomListFilter;
const jsonFloat = @import("../archive/codec.zig").jsonFloat;
const PlaylistItem = @import("../../lazer_multiplayer.zig").PlaylistItem;
const Room = @import("model.zig").Room;
const Connection = @import("../transport/model.zig").Connection;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const defaultRoomUser = @import("state.zig").defaultRoomUser;
const parseRoom = @import("../wire/parse.zig").parseRoom;
const writeRoom = @import("../wire/messagepack.zig").writeRoom;
const autoStartSeconds = @import("../wire/json.zig").autoStartSeconds;
const writeRoomJson = @import("../wire/json.zig").writeRoomJson;

test "REST room create and join roll back every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, restRoomAllocationRun, .{});
}

test "lazer playlist creation assigns zero owner ids to the authenticated user" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const host: domain.User = .{ .id = 4, .name = "raya", .safe_name = "raya", .country = .{ 'A', 'U' } };
    const client_body =
        \\{"id":null,"name":"raya's awesome playlist","description":null,"password":null,"host":null,"category":"normal","duration":30,"starts_at":null,"ends_at":null,"max_participants":null,"participant_count":0,"recent_participants":[],"max_attempts":3,"playlist":[{"owner_id":0,"ruleset_id":0,"expired":false,"playlist_order":null,"played_at":null,"allowed_mods":[],"required_mods":[],"beatmap_id":1000000003,"freestyle":false}],"playlist_item_stats":null,"difficulty_range":null,"type":"playlists","queue_mode":"host_only","auto_skip":false,"auto_start_duration":0,"current_user_score":null,"current_playlist_item":null,"channel_id":0,"status":"idle","pinned":false}
    ;
    const created = try manager.restCreateRoom(std.testing.allocator, host, client_body);
    defer std.testing.allocator.free(created);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, created, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("id").?.integer);
    try std.testing.expectEqualStrings("playlists", parsed.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("normal", parsed.value.object.get("category").?.string);
    try std.testing.expect(std.meta.activeTag(parsed.value.object.get("starts_at").?) == .string);
    try std.testing.expect(std.meta.activeTag(parsed.value.object.get("ends_at").?) == .string);
    try std.testing.expect(!std.mem.eql(u8, parsed.value.object.get("starts_at").?.string, parsed.value.object.get("ends_at").?.string));
    try std.testing.expectEqual(@as(i64, 3), parsed.value.object.get("max_attempts").?.integer);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("current_user_score").?.object.get("playlist_item_attempts").?.array.items.len);
    try std.testing.expectEqual(@as(i64, host.id), parsed.value.object.get("playlist").?.array.items[0].object.get("owner_id").?.integer);
    try std.testing.expectEqual(@as(i64, host.id), parsed.value.object.get("current_playlist_item").?.object.get("owner_id").?.integer);
    const playlist_rulesets = parsed.value.object.get("playlist_item_stats").?.object.get("ruleset_ids").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), playlist_rulesets.len);
    try std.testing.expectEqual(@as(i64, 0), playlist_rulesets[0].integer);

    try manager.recordRoomScore(host.id, 1, 1, .{ .score_id = 9001, .total_score = 100, .accuracy = 0.5, .max_combo = 10, .passed = false });
    const failed_leaderboard = (try manager.roomLeaderboardJson(std.testing.allocator, host.id, 1)).?;
    defer std.testing.allocator.free(failed_leaderboard);
    var parsed_failed_leaderboard = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, failed_leaderboard, .{});
    defer parsed_failed_leaderboard.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed_failed_leaderboard.value.object.get("leaderboard").?.array.items.len);
    try std.testing.expect(std.meta.activeTag(parsed_failed_leaderboard.value.object.get("user_score").?) == .null);
    try manager.recordRoomScore(host.id, 1, 1, .{ .score_id = 9002, .total_score = 200, .accuracy = 1, .max_combo = 20, .passed = true });
    const refreshed = (try manager.roomsJson(std.testing.allocator, 1, null, host.id)).?;
    defer std.testing.allocator.free(refreshed);
    var parsed_refreshed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, refreshed, .{});
    defer parsed_refreshed.deinit();
    const attempt = parsed_refreshed.value.object.get("current_user_score").?.object.get("playlist_item_attempts").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 1), attempt.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 2), attempt.get("attempts").?.integer);
    try std.testing.expect(attempt.get("passed").?.bool);
    const playlist_high_scores = (try manager.roomScoreIds(std.testing.allocator, host.id, 1, 1)).?;
    defer std.testing.allocator.free(playlist_high_scores);
    try std.testing.expectEqualSlices(i64, &.{9002}, playlist_high_scores);
    try std.testing.expect(manager.roomContainsScore(host.id, 1, 1, 9001));
    const passing_leaderboard = (try manager.roomLeaderboardJson(std.testing.allocator, host.id, 1)).?;
    defer std.testing.allocator.free(passing_leaderboard);
    var parsed_passing_leaderboard = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, passing_leaderboard, .{});
    defer parsed_passing_leaderboard.deinit();
    const passing_rows = parsed_passing_leaderboard.value.object.get("leaderboard").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), passing_rows.len);
    try std.testing.expectEqual(@as(i64, 2), passing_rows[0].object.get("attempts").?.integer);
    try std.testing.expectEqual(@as(i64, 1), passing_rows[0].object.get("completed").?.integer);
    try std.testing.expectEqual(@as(i64, 200), passing_rows[0].object.get("total_score").?.integer);
    try std.testing.expectEqual(@as(f64, 1), jsonFloat(passing_rows[0].object.get("accuracy")).?);
    const default_playlist_listing = (try manager.roomsJson(std.testing.allocator, null, try roomListFilter(host.id, "open", null, ""), host.id)).?;
    defer std.testing.allocator.free(default_playlist_listing);
    var parsed_default_playlist_listing = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, default_playlist_listing, .{});
    defer parsed_default_playlist_listing.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_default_playlist_listing.value.array.items.len);

    try manager.restPartRoom(host.id, 1);
    const still_open = (try manager.roomsJson(std.testing.allocator, 1, null, host.id)).?;
    defer std.testing.allocator.free(still_open);
    var parsed_still_open = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, still_open, .{});
    defer parsed_still_open.deinit();
    try std.testing.expectEqualStrings("idle", parsed_still_open.value.object.get("status").?.string);
    try std.testing.expectEqual(@as(i64, 0), parsed_still_open.value.object.get("participant_count").?.integer);
    const rejoined = try manager.restJoinRoom(std.testing.allocator, host, 1, "");
    defer std.testing.allocator.free(rejoined);
    try manager.restCloseRoom(host.id, 1);
}

test "ended playlist rooms retain ruleset filters after every item expires" {
    var room: Room = .{ .id = 1, .settings = .{}, .host_id = 4, .ended = true };
    defer room.deinit(std.testing.allocator);
    try room.settings.name.set("ended rulesets");
    try room.host_name.set("raya");
    room.settings.match_type = 0;
    room.settings.playlist_item_id = 8;
    room.playlist[0] = .{ .id = 8, .owner_id = 4, .beatmap_id = 75, .ruleset_id = 1, .expired = true, .order = 0 };
    room.playlist[1] = .{ .id = 9, .owner_id = 4, .beatmap_id = 76, .ruleset_id = 3, .expired = true, .order = 1 };
    room.playlist_count = 2;
    for (&room.playlist) |*entry| if (entry.*) |*item| {
        item.required_mods.bytes[0] = 0x90;
        item.required_mods.len = 1;
        item.allowed_mods.bytes[0] = 0x90;
        item.allowed_mods.len = 1;
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeRoomJson(&output.writer, &room, 4, 0, .archive);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
    defer parsed.deinit();
    const stats = parsed.value.object.get("playlist_item_stats").?.object;
    try std.testing.expectEqual(@as(i64, 0), stats.get("count_active").?.integer);
    const rulesets = stats.get("ruleset_ids").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), rulesets.len);
    try std.testing.expectEqual(@as(i64, 1), rulesets[0].integer);
    try std.testing.expectEqual(@as(i64, 3), rulesets[1].integer);
}

test "lazer multiplayer REST lifecycle owns room state and score boards" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const host: domain.User = .{ .id = 4, .name = "raya", .safe_name = "raya", .country = .{ 'A', 'U' } };
    const guest: domain.User = .{ .id = 7, .name = "guest", .safe_name = "guest", .country = .{ 'G', 'B' } };
    const room_body =
        \\{"name":"route test","password":"secret","type":"head_to_head","queue_mode":"host_only","max_participants":2,"auto_start_duration":5,"playlist":[{"id":8,"owner_id":4,"beatmap_id":75,"ruleset_id":0,"playlist_order":0,"required_mods":[{"acronym":"HD"}],"allowed_mods":[{"acronym":"DT","settings":{"speed_change":1.25}}],"beatmap":{"checksum":"0123456789abcdef0123456789abcdef","difficulty_rating":5.25,"beatmapset_id":750,"status":"loved","version":"night drive","beatmapset":{"artist":"fixture artist","title":"fixture song","creator":"fixture mapper"}}}]}
    ;
    const created = try manager.restCreateRoom(std.testing.allocator, host, room_body);
    defer std.testing.allocator.free(created);
    var parsed_created = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, created, .{});
    defer parsed_created.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed_created.value.object.get("id").?.integer);
    const room_channel_id = parsed_created.value.object.get("channel_id").?.integer;
    try std.testing.expectEqual(@as(i64, 2_000_000_001), room_channel_id);
    try std.testing.expectEqual(@as(?i64, 1), manager.roomChannelAccess(host.id, room_channel_id));
    try std.testing.expectEqual(@as(?i64, null), manager.roomChannelAccess(guest.id, room_channel_id));
    try std.testing.expectEqualStrings("head_to_head", parsed_created.value.object.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 5), parsed_created.value.object.get("auto_start_duration").?.integer);
    try std.testing.expectEqual(@as(i64, 5), autoStartSeconds(manager.rooms[0].?.settings));
    try std.testing.expectEqual(@as(usize, 1), parsed_created.value.object.get("playlist").?.array.items.len);
    const realtime_rulesets = parsed_created.value.object.get("playlist_item_stats").?.object.get("ruleset_ids").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), realtime_rulesets.len);
    try std.testing.expectEqual(@as(i64, 0), realtime_rulesets[0].integer);
    const created_beatmap = parsed_created.value.object.get("playlist").?.array.items[0].object.get("beatmap").?.object;
    try std.testing.expectEqual(@as(i64, 750), created_beatmap.get("beatmapset_id").?.integer);
    try std.testing.expectEqualStrings("night drive", created_beatmap.get("version").?.string);
    try std.testing.expectEqualStrings("loved", created_beatmap.get("status").?.string);
    const created_set = created_beatmap.get("beatmapset").?.object;
    try std.testing.expectEqualStrings("fixture artist", created_set.get("artist").?.string);
    try std.testing.expectEqualStrings("fixture song", created_set.get("title").?.string);
    try std.testing.expectEqualStrings("fixture mapper", created_set.get("creator").?.string);
    try std.testing.expectEqualStrings("https://assets.kai.ovh/beatmaps/750/covers/card@2x.jpg", created_set.get("covers").?.object.get("card@2x").?.string);
    try std.testing.expectError(error.InvalidMultiplayerPassword, manager.restJoinRoom(std.testing.allocator, guest, 1, "wrong"));

    const joined = try manager.restJoinRoom(std.testing.allocator, guest, 1, "secret");
    defer std.testing.allocator.free(joined);
    var parsed_joined = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, joined, .{});
    defer parsed_joined.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed_joined.value.object.get("recent_participants").?.array.items.len);
    try std.testing.expectEqual(@as(?i64, 1), manager.roomChannelAccess(guest.id, room_channel_id));
    const room_channel_users = (try manager.roomChannelUsersJson(std.testing.allocator, guest.id, room_channel_id)).?;
    defer std.testing.allocator.free(room_channel_users);
    var parsed_room_channel_users = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, room_channel_users, .{});
    defer parsed_room_channel_users.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed_room_channel_users.value.array.items.len);
    const visible_rooms = (try manager.roomsJson(std.testing.allocator, null, try roomListFilter(host.id, "open", "idle", "realtime"), host.id)).?;
    defer std.testing.allocator.free(visible_rooms);
    var parsed_visible = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, visible_rooms, .{});
    defer parsed_visible.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_visible.value.array.items.len);
    const hidden_rooms = (try manager.roomsJson(std.testing.allocator, null, try roomListFilter(host.id, "open", "idle", "normal"), host.id)).?;
    defer std.testing.allocator.free(hidden_rooms);
    try std.testing.expectEqualStrings("[]", hidden_rooms);
    const default_playlist_rooms = (try manager.roomsJson(std.testing.allocator, null, try roomListFilter(host.id, "open", null, ""), host.id)).?;
    defer std.testing.allocator.free(default_playlist_rooms);
    try std.testing.expectEqualStrings("[]", default_playlist_rooms);
    const guest_owned = (try manager.roomsJson(std.testing.allocator, null, try roomListFilter(guest.id, "owned", null, "realtime"), guest.id)).?;
    defer std.testing.allocator.free(guest_owned);
    try std.testing.expectEqualStrings("[]", guest_owned);
    const context = manager.scoreContext(guest.id, 1, 8).?;
    try std.testing.expectEqual(@as(i32, 75), context.beatmap_id);
    try std.testing.expectEqual(@as(u8, 0), context.ruleset_id);

    try manager.bindRoomScoreToken(host.id, 1, 8, 10101);
    try std.testing.expect(manager.scoreSubmissionContext(host.id, 1, 8, 10101) != null);
    try std.testing.expect(manager.scoreSubmissionContext(guest.id, 1, 8, 10101) == null);
    try std.testing.expectError(error.InvalidMultiplayerScoreToken, manager.recordRoomScore(host.id, 1, 8, .{ .token_id = 10102, .score_id = 100, .total_score = 1, .accuracy = 1, .max_combo = 1, .passed = true }));
    try std.testing.expectEqual(@as(usize, 0), manager.rooms[0].?.scores.items.len);
    try manager.recordRoomScore(host.id, 1, 8, .{ .token_id = 10101, .score_id = 101, .total_score = 800_000, .accuracy = 0.98, .max_combo = 500, .passed = true });
    try std.testing.expect(manager.scoreSubmissionContext(host.id, 1, 8, 10101) != null);
    try manager.recordRoomScore(host.id, 1, 8, .{ .token_id = 10101, .score_id = 101, .total_score = 800_000, .accuracy = 0.98, .max_combo = 500, .passed = true });
    try std.testing.expectError(error.InvalidMultiplayerScoreToken, manager.recordRoomScore(host.id, 1, 8, .{ .token_id = 10101, .score_id = 104, .total_score = 900_000, .accuracy = 1, .max_combo = 600, .passed = true }));
    try manager.recordRoomScore(guest.id, 1, 8, .{ .score_id = 102, .total_score = 900_000, .accuracy = 0.99, .max_combo = 600, .passed = true });
    try manager.recordRoomScore(host.id, 1, 8, .{ .score_id = 103, .total_score = 850_000, .accuracy = 0.985, .max_combo = 550, .passed = true });
    try std.testing.expectEqual(@as(?i64, 103), manager.roomScoreIdForUser(host.id, 1, 8, host.id));
    try std.testing.expect(manager.roomContainsScore(guest.id, 1, 8, 102));
    try std.testing.expect(manager.roomContainsScore(host.id, 1, 8, 101));
    const ids = (try manager.roomScoreIds(std.testing.allocator, host.id, 1, 8)).?;
    defer std.testing.allocator.free(ids);
    // The index and showUser paths expose one high score per user. The older
    // host attempt remains addressable through the exact score route.
    try std.testing.expectEqualSlices(i64, &.{ 102, 103 }, ids);
    const best_detail = (try manager.roomScoreRanking(std.testing.allocator, host.id, 1, 8, 103)).?;
    try std.testing.expectEqual(@as(usize, 2), best_detail.position);
    try std.testing.expectEqualSlices(i64, &.{102}, best_detail.higher_ids[0..best_detail.higher_count]);
    try std.testing.expectEqual(@as(usize, 0), best_detail.lower_count);
    const older_detail = (try manager.roomScoreRanking(std.testing.allocator, host.id, 1, 8, 101)).?;
    try std.testing.expectEqual(@as(usize, 3), older_detail.position);
    try std.testing.expectEqualSlices(i64, &.{102}, older_detail.higher_ids[0..older_detail.higher_count]);
    try std.testing.expectEqual(@as(usize, 0), older_detail.lower_count);

    const leaderboard = (try manager.roomLeaderboardJson(std.testing.allocator, guest.id, 1)).?;
    defer std.testing.allocator.free(leaderboard);
    var parsed_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, leaderboard, .{});
    defer parsed_board.deinit();
    const rows = parsed_board.value.object.get("leaderboard").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(i64, 4), rows[0].object.get("user_id").?.integer);
    try std.testing.expectEqual(@as(i64, 1_650_000), rows[0].object.get("total_score").?.integer);
    try std.testing.expectEqual(@as(i64, 7), parsed_board.value.object.get("user_score").?.object.get("user_id").?.integer);

    try manager.restPartRoom(guest.id, 1);
    try std.testing.expectEqual(@as(?i64, null), manager.roomChannelAccess(guest.id, room_channel_id));
    try std.testing.expect(manager.scoreContext(guest.id, 1, 8) == null);
    try std.testing.expectError(error.MultiplayerPermissionDenied, manager.restCloseRoom(guest.id, 1));
    try manager.restCloseRoom(host.id, 1);
    try std.testing.expect((try manager.roomsJson(std.testing.allocator, 1, null, host.id)) == null);
}

test "room score history keeps every supported finite attempt and never rotates" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const room = try std.testing.allocator.create(Room);
    room.* = .{ .id = 1, .settings = .{}, .host_id = 4 };
    room.users[0] = try defaultRoomUser(4, "raya", .{ 'A', 'U' });
    room.user_count = 1;
    room.rememberParticipant(room.users[0].?);
    room.playlist[0] = .{ .id = 8, .owner_id = 4, .beatmap_id = 75 };
    room.playlist[0].?.required_mods.bytes[0] = 0x90;
    room.playlist[0].?.required_mods.len = 1;
    room.playlist[0].?.allowed_mods.bytes[0] = 0x90;
    room.playlist[0].?.allowed_mods.len = 1;
    room.playlist_count = 1;
    room.settings.playlist_item_id = 8;
    try room.scores.ensureTotalCapacity(std.testing.allocator, max_room_scores);
    for (0..max_room_scores) |index| room.scores.appendAssumeCapacity(.{
        .score_id = @intCast(index + 1),
        .user_id = 4,
        .playlist_item_id = 8,
        .total_score = @intCast(index),
        .accuracy = 1,
        .max_combo = 1,
        .passed = true,
    });
    manager.rooms[0] = room;
    try std.testing.expectError(error.MultiplayerScoreLimit, manager.recordRoomScore(4, 1, 8, .{ .score_id = max_room_scores + 1, .total_score = 1, .accuracy = 1, .max_combo = 1, .passed = true }));
    try std.testing.expectEqual(@as(i64, 1), room.scores.items[0].score_id);
    try std.testing.expectEqual(@as(i64, max_room_scores), room.scores.items[max_room_scores - 1].score_id);
    var archive_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer archive_json.deinit();
    try writeRoomJson(&archive_json.writer, room, 4, 0, .archive);
    try std.testing.expect(archive_json.written().len <= 8 * 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, archive_json.written(), "\"score_id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive_json.written(), "\"score_id\":16000") != null);
}

test "multiplayer room cards use stored beatmap metadata and cover ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/multiplayer-metadata.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,star_rating,total_length,hit_length) VALUES(75,900,'0123456789abcdef0123456789abcdef','stored artist','stored song','stored diff','stored mapper',3,6.25,143,119)");
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    const host: domain.User = .{ .id = 4, .name = "raya", .safe_name = "raya", .country = .{ 'A', 'U' } };
    const room_body =
        \\{"name":"metadata","type":"head_to_head","queue_mode":"host_only","playlist":[{"id":1,"owner_id":4,"beatmap_id":75,"ruleset_id":0,"beatmap":{"checksum":"0123456789abcdef0123456789abcdef","difficulty_rating":1,"beatmapset_id":75,"status":"pending","version":"stale","beatmapset":{"artist":"stale","title":"stale","creator":"stale"}}}]}
    ;
    const created = try manager.restCreateRoom(std.testing.allocator, host, room_body);
    defer std.testing.allocator.free(created);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, created, .{});
    defer parsed.deinit();
    const beatmap = parsed.value.object.get("playlist").?.array.items[0].object.get("beatmap").?.object;
    try std.testing.expectEqual(@as(i64, 900), beatmap.get("beatmapset_id").?.integer);
    try std.testing.expectEqualStrings("stored diff", beatmap.get("version").?.string);
    try std.testing.expectEqualStrings("ranked", beatmap.get("status").?.string);
    try std.testing.expectApproxEqAbs(@as(f64, 6.25), beatmap.get("difficulty_rating").?.float, 0.0001);
    try std.testing.expectEqual(@as(i64, 143), beatmap.get("total_length").?.integer);
    try std.testing.expectEqual(@as(i64, 119), beatmap.get("hit_length").?.integer);
    const set = beatmap.get("beatmapset").?.object;
    try std.testing.expectEqualStrings("stored artist", set.get("artist").?.string);
    try std.testing.expectEqualStrings("stored song", set.get("title").?.string);
    try std.testing.expectEqualStrings("stored mapper", set.get("creator").?.string);
    try std.testing.expectEqualStrings("https://assets.kai.ovh/beatmaps/900/covers/cover.jpg", set.get("covers").?.object.get("cover").?.string);

    var client_room: Room = .{ .id = 0, .settings = .{}, .host_id = host.id, .host_country = host.country };
    try client_room.settings.name.set("client snapshot");
    client_room.settings.playlist_item_id = 1;
    try client_room.settings.auto_start.set(&.{0xc0});
    try client_room.host_name.set(host.name);
    var client_item: PlaylistItem = .{ .id = 1, .owner_id = host.id, .beatmap_id = 75 };
    try client_item.required_mods.set(&.{0x90});
    try client_item.allowed_mods.set(&.{0x90});
    try client_item.played_at.set(&.{0xc0});
    client_room.playlist[0] = client_item;
    client_room.playlist_count = 1;
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try writeRoom(.{ .writer = &encoded.writer }, &client_room, 0);
    var connection: Connection = .{ .allocator = std.testing.allocator, .user_id = host.id, .user_country = host.country, .io = std.testing.io };
    try connection.user_name.set(host.name);
    const decoded = try parseRoom(std.testing.allocator, encoded.written(), &connection);
    defer std.testing.allocator.destroy(decoded);
    try manager.hydrateRoom(decoded);
    var client_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer client_json.deinit();
    try writeRoomJson(&client_json.writer, decoded, 0, 0, .none);
    var parsed_client = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, client_json.written(), .{});
    defer parsed_client.deinit();
    const client_beatmap = parsed_client.value.object.get("playlist").?.array.items[0].object.get("beatmap").?.object;
    try std.testing.expectEqual(@as(i64, 900), client_beatmap.get("beatmapset_id").?.integer);
    try std.testing.expectEqualStrings("stored song", client_beatmap.get("beatmapset").?.object.get("title").?.string);
    try std.testing.expectEqualStrings("stored diff", client_beatmap.get("version").?.string);
    try std.testing.expectEqual(@as(i64, 143), client_beatmap.get("total_length").?.integer);
    try std.testing.expectEqual(@as(i64, 119), client_beatmap.get("hit_length").?.integer);
}

pub fn restRoomAllocationRun(allocator: std.mem.Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io);
    // Avoid the deliberately best-effort shutdown serializer swallowing the
    // injected allocation failure after the operation under test has ended.
    defer {
        manager.shutting_down = true;
        manager.deinit();
    }
    const host: domain.User = .{ .id = 4, .name = "allocation host", .safe_name = "allocation_host", .country = .{ 'A', 'U' } };
    const guest: domain.User = .{ .id = 7, .name = "allocation guest", .safe_name = "allocation_guest", .country = .{ 'G', 'B' } };
    const room_body =
        \\{"name":"allocation room","type":"head_to_head","playlist":[{"id":8,"owner_id":4,"beatmap_id":75,"ruleset_id":0}]}
    ;
    const created = manager.restCreateRoom(allocator, host, room_body) catch |err| {
        for (manager.rooms) |entry| try std.testing.expect(entry == null);
        return err;
    };
    defer allocator.free(created);
    const room = manager.rooms[0].?;
    try std.testing.expectEqual(@as(usize, 1), room.user_count);

    const joined = manager.restJoinRoom(allocator, guest, room.id, "") catch |err| {
        try std.testing.expect(room.userIndex(guest.id) == null);
        try std.testing.expect(room.participantIndex(guest.id) == null);
        try std.testing.expectEqual(@as(usize, 1), room.user_count);
        return err;
    };
    defer allocator.free(joined);
    try std.testing.expect(room.userIndex(guest.id) != null);
    try std.testing.expect(room.participantIndex(guest.id) != null);
    try std.testing.expectEqual(@as(usize, 2), room.user_count);
    manager.bindRoomScoreToken(host.id, room.id, 8, 9001) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), room.score_tokens.items.len);
        return err;
    };
    try std.testing.expectEqual(@as(usize, 1), room.score_tokens.items.len);
    try std.testing.expect(manager.scoreSubmissionContext(host.id, room.id, 8, 9001) != null);
    try std.testing.expect(manager.scoreSubmissionContext(guest.id, room.id, 8, 9001) == null);
}
