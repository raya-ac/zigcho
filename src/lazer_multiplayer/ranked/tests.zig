const std = @import("std");
const domain = @import("../../domain.zig");
const storage = @import("../../runtime_storage.zig");
const ranked_hand_size = @import("../../lazer_multiplayer.zig").ranked_hand_size;
const ranked_stage = @import("../../lazer_multiplayer.zig").ranked_stage;
const MessagePackReader = @import("../../lazer_multiplayer.zig").MessagePackReader;
const MessagePackWriter = @import("../../lazer_multiplayer.zig").MessagePackWriter;
const PlaylistItem = @import("../../lazer_multiplayer.zig").PlaylistItem;
const MatchmakingState = @import("../../lazer_multiplayer.zig").MatchmakingState;
const RankedCard = @import("../../lazer_multiplayer.zig").RankedCard;
const RankedPlayState = @import("../../lazer_multiplayer.zig").RankedPlayState;
const RankedStageCountdown = @import("../../lazer_multiplayer.zig").RankedStageCountdown;
const Room = @import("../rooms/model.zig").Room;
const PendingMatch = @import("../../lazer_multiplayer.zig").PendingMatch;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const defaultRoomUser = @import("../rooms/state.zig").defaultRoomUser;
const beatmap_availability_unknown = @import("../../lazer_multiplayer.zig").beatmap_availability_unknown;
const beatmap_availability_locally_available = @import("../../lazer_multiplayer.zig").beatmap_availability_locally_available;
const beatmapAvailabilityState = @import("../rooms/state.zig").beatmapAvailabilityState;
const nextPlaylistOrder = @import("../rooms/state.zig").nextPlaylistOrder;
const advanceRoomPlaylist = @import("../rooms/state.zig").advanceRoomPlaylist;
const parseRankedCardList = @import("state.zig").parseRankedCardList;
const rankedFinishRound = @import("state.zig").rankedFinishRound;
const recomputeMatchmakingPlacements = @import("state.zig").recomputeMatchmakingPlacements;
const writeMatchState = @import("../wire/messagepack.zig").writeMatchState;
const writeRoom = @import("../wire/messagepack.zig").writeRoom;
const eventMatchmakingDuelIssuedOwned = @import("../transport/events.zig").eventMatchmakingDuelIssuedOwned;
const eventLobbyStatusOwned = @import("../transport/events.zig").eventLobbyStatusOwned;
const eventRankedCountdownStartedOwned = @import("../transport/events.zig").eventRankedCountdownStartedOwned;

test "matchmaking lobby status leaves unavailable ratings empty" {
    const frame = try eventLobbyStatusOwned(std.testing.allocator, &.{ 4, 7 });
    defer std.testing.allocator.free(frame);
    var prefix_len: usize = 0;
    while (frame[prefix_len] & 0x80 != 0) prefix_len += 1;
    prefix_len += 1;
    var reader: MessagePackReader = .{ .data = frame[prefix_len..] };
    try std.testing.expectEqual(@as(usize, 6), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 1), try reader.integer());
    try std.testing.expectEqual(@as(usize, 0), try reader.mapLen());
    try reader.skip(0);
    try std.testing.expectEqualStrings("MatchmakingLobbyStatusChanged", try reader.string());
    try std.testing.expectEqual(@as(usize, 1), try reader.arrayLen());
    try std.testing.expectEqual(@as(usize, 4), try reader.arrayLen());
    try std.testing.expectEqual(@as(usize, 2), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 4), try reader.integer());
    try std.testing.expectEqual(@as(i64, 7), try reader.integer());
    try std.testing.expectEqual(@as(usize, 0), try reader.arrayLen());
    try std.testing.expectEqual(@as(?i64, null), try reader.nullableInteger());
    try std.testing.expectEqual(@as(usize, 0), try reader.arrayLen());
}

test "matchmaking duel event uses canonical guid and complete pool" {
    const duel_id = "00112233-4455-6677-8899-aabbccddeeff";
    const frame = try eventMatchmakingDuelIssuedOwned(std.testing.allocator, duel_id, 4, 102, 1, 1);
    defer std.testing.allocator.free(frame);
    var prefix_len: usize = 0;
    while (frame[prefix_len] & 0x80 != 0) prefix_len += 1;
    prefix_len += 1;
    var reader: MessagePackReader = .{ .data = frame[prefix_len..] };
    try std.testing.expectEqual(@as(usize, 6), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 1), try reader.integer());
    try std.testing.expectEqual(@as(usize, 0), try reader.mapLen());
    try reader.skip(0);
    try std.testing.expectEqualStrings("MatchmakingDuelIssued", try reader.string());
    try std.testing.expectEqual(@as(usize, 1), try reader.arrayLen());
    try std.testing.expectEqual(@as(usize, 3), try reader.arrayLen());
    try std.testing.expectEqualStrings(duel_id, try reader.string());
    try std.testing.expectEqual(@as(i64, 4), try reader.integer());
    try std.testing.expectEqual(@as(usize, 5), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 102), try reader.integer());
    try std.testing.expectEqual(@as(i64, 1), try reader.integer());
    try std.testing.expectEqual(@as(i64, 0), try reader.integer());
    try std.testing.expectEqualStrings("ranked play", try reader.string());
    try std.testing.expectEqual(@as(i64, 1), try reader.integer());
}

test "matchmaking placements use lower-equal ties and aggregate round points" {
    var state: MatchmakingState = .{};
    state.current_round = 2;
    state.user_count = 2;
    state.users[0] = .{ .id = 10 };
    state.users[1] = .{ .id = 20 };
    state.users[0].?.rounds[0] = .{ .round = 1, .total_score = 500, .passed = true };
    state.users[1].?.rounds[0] = .{ .round = 1, .total_score = 500, .passed = false };
    state.users[0].?.rounds[1] = .{ .round = 2, .total_score = 100, .passed = true };
    state.users[1].?.rounds[1] = .{ .round = 2, .total_score = 900, .passed = true };

    recomputeMatchmakingPlacements(&state);

    try std.testing.expectEqual(@as(u8, 2), state.users[0].?.rounds[0].?.placement);
    try std.testing.expectEqual(@as(u8, 2), state.users[1].?.rounds[0].?.placement);
    try std.testing.expectEqual(@as(i32, 27), state.users[1].?.points);
    try std.testing.expectEqual(@as(i32, 24), state.users[0].?.points);
    try std.testing.expectEqual(@as(?u8, 1), state.users[1].?.placement);
    try std.testing.expectEqual(@as(?u8, 2), state.users[0].?.placement);
}

test "ranked play state uses the official union and damage contract" {
    var ranked: RankedPlayState = .{};
    ranked.stage = ranked_stage.results;
    ranked.current_round = 1;
    ranked.active_user_id = 10;
    ranked.user_count = 2;
    ranked.users[0] = .{ .id = 10, .total_score = 900_000, .submitted = true };
    ranked.users[1] = .{ .id = 20, .total_score = 400_000, .submitted = true };
    rankedFinishRound(&ranked);
    try std.testing.expectEqual(@as(?i32, 10), ranked.round_winner_id);
    try std.testing.expectEqual(@as(i32, 1), ranked.users[0].?.rounds_won);
    try std.testing.expect(ranked.users[1].?.life < 1_000_000);
    try std.testing.expect(ranked.users[1].?.damage.?.damage >= 50_000);

    var room: Room = .{
        .id = 7,
        .settings = .{},
        .host_id = 3,
        .ranked_play = ranked,
    };
    try room.settings.name.set("ranked test");
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeMatchState(.{ .writer = &output.writer }, &room);
    var reader: MessagePackReader = .{ .data = output.written() };
    try std.testing.expectEqual(@as(usize, 2), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 2), try reader.integer());
    try std.testing.expectEqual(@as(usize, 7), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, ranked_stage.results), try reader.integer());
    try std.testing.expectEqual(@as(i64, 1), try reader.integer());
}

test "ordinary rooms expire the played map and choose the next playlist order" {
    var room: Room = .{ .id = 12, .settings = .{}, .host_id = 4 };
    room.settings.playlist_item_id = 10;
    room.users[0] = try defaultRoomUser(4, "host", .{ 'A', 'U' });
    room.users[0].?.voted_skip = true;
    room.user_count = 1;
    room.playlist[0] = .{ .id = 10, .owner_id = 4, .beatmap_id = 100, .order = 0 };
    room.playlist[2] = .{ .id = 30, .owner_id = 4, .beatmap_id = 300, .order = 2 };
    room.playlist_count = 2;

    try std.testing.expectEqual(@as(?u16, 3), nextPlaylistOrder(&room));
    room.playlist[2].?.order = std.math.maxInt(u16);
    try std.testing.expectEqual(@as(?u16, null), nextPlaylistOrder(&room));
    room.playlist[2].?.order = 2;
    const first = advanceRoomPlaylist(&room);
    try std.testing.expectEqual(@as(?i64, 30), first.next_item_id);
    try std.testing.expectEqual(@as(i64, 10), first.expired.?.id);
    try std.testing.expect(room.playlist[0].?.expired);
    try std.testing.expectEqual(@as(i64, 30), room.settings.playlist_item_id);
    try std.testing.expect(!room.users[0].?.voted_skip);

    const last = advanceRoomPlaylist(&room);
    try std.testing.expectEqual(@as(i64, 30), last.expired.?.id);
    try std.testing.expectEqual(@as(?i64, null), last.next_item_id);
    try std.testing.expect(room.playlist[2].?.expired);
}

test "ranked rooms load persistent ratings and settle a room once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/ranked-room.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(10,'ranked one','ranked_one',x'00',x'00'),(11,'ranked two','ranked_two',x'00',x'00');" ++
            "INSERT INTO lazer_ranked_ratings(user_id,ruleset_id,rating) VALUES(10,1,1700),(11,1,1400);" ++
            "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,mode,star_rating,osu_file) VALUES(75,750,'0123456789abcdef0123456789abcdef','fixture','ranked','taiko','mapper',3,1,4.5,x'00');",
    );

    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    try manager.setMatchmakingMaps(1, &.{.{ .id = 75, .md5 = "0123456789abcdef0123456789abcdef".*, .mode = 1, .stars = 4.5 }});
    const pending: PendingMatch = .{ .id = 1, .pool_id = 102, .users = .{ 10, 11 }, .created_at = 0 };
    const room = try manager.createMatchmakingRoomLocked(pending, "secret");
    defer std.testing.allocator.destroy(room);
    try std.testing.expectEqual(@as(i32, 1700), room.ranked_play.?.users[0].?.rating);
    try std.testing.expectEqual(@as(i32, 1400), room.ranked_play.?.users[1].?.rating);

    room.ranked_play.?.winning_user_id = 10;
    room.ranked_play.?.stage = ranked_stage.ended;
    try manager.persistRankedResult(room);
    try std.testing.expect(room.ranked_play.?.result_persisted);
    try std.testing.expectEqual(@as(i32, 1716), room.ranked_play.?.users[0].?.rating_after);
    try std.testing.expectEqual(@as(i32, 1384), room.ranked_play.?.users[1].?.rating_after);
    try manager.persistRankedResult(room);
    try std.testing.expectEqual(@as(i32, 1), (try store.lazerRankedRating(10, 1)).games_played);
    try std.testing.expectEqual(@as(i32, 1), (try store.lazerRankedRating(11, 1)).games_played);
}

test "ranked result database settlement never holds the multiplayer manager mutex" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/ranked-result-unlocked.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(10,'ranked one','ranked_one',x'00',x'00'),(11,'ranked two','ranked_two',x'00',x'00');" ++
            "INSERT INTO lazer_ranked_ratings(user_id,ruleset_id,rating) VALUES(10,1,1700),(11,1,1400);" ++
            "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,mode,star_rating,osu_file) VALUES(75,750,'0123456789abcdef0123456789abcdef','fixture','ranked','taiko','mapper',3,1,4.5,x'00');",
    );

    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    try manager.setMatchmakingMaps(1, &.{.{ .id = 75, .md5 = "0123456789abcdef0123456789abcdef".*, .mode = 1, .stars = 4.5 }});
    const pending: PendingMatch = .{ .id = 1, .pool_id = 102, .users = .{ 10, 11 }, .created_at = 0 };
    const room = try manager.createMatchmakingRoomLocked(pending, "secret");
    room.ranked_play.?.winning_user_id = 10;
    room.ranked_play.?.stage = ranked_stage.ended;
    manager.rooms[0] = room;

    const Settlement = struct {
        manager: *Manager,
        room_id: i64,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,

        fn run(context: *@This()) void {
            context.started.store(true, .release);
            context.manager.persistLiveRankedResult(context.room_id) catch |err| {
                context.failure = err;
            };
            context.done.store(true, .release);
        }
    };
    store.mutex.lockUncancelable(std.testing.io);
    var settlement: Settlement = .{ .manager = &manager, .room_id = room.id };
    const settlement_thread = try std.Thread.spawn(.{}, Settlement.run, .{&settlement});
    while (!settlement.started.load(.acquire)) std.Thread.yield() catch {};
    _ = std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    try std.testing.expect(!settlement.done.load(.acquire));

    // The storage operation is deliberately blocked above. An unrelated user
    // must still be able to enter and leave the manager immediately.
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const guest: domain.User = .{ .id = 20, .name = "unrelated", .safe_name = "unrelated", .country = .{ 'G', 'B' } };
    const unrelated = try manager.connect(guest, fake_socket);
    unrelated.socket = null;
    manager.disconnect(unrelated);

    store.mutex.unlock(std.testing.io);
    settlement_thread.join();
    try std.testing.expect(settlement.failure == null);
    try std.testing.expect(room.ranked_play.?.result_persisted);
    try std.testing.expectEqual(@as(i32, 1716), room.ranked_play.?.users[0].?.rating_after);
}

test "ranked pick countdown uses the pinned client union and timespan ticks" {
    const countdown: RankedStageCountdown = .{ .id = 17, .deadline_ms = 35_000, .stage = ranked_stage.card_play };
    const frame = try eventRankedCountdownStartedOwned(std.testing.allocator, countdown, 5_000);
    defer std.testing.allocator.free(frame);
    var prefix_len: usize = 0;
    while (frame[prefix_len] & 0x80 != 0) prefix_len += 1;
    prefix_len += 1;
    var reader: MessagePackReader = .{ .data = frame[prefix_len..] };
    try std.testing.expectEqual(@as(usize, 6), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 1), try reader.integer());
    try std.testing.expectEqual(@as(usize, 0), try reader.mapLen());
    try reader.skip(0);
    try std.testing.expectEqualStrings("MatchEvent", try reader.string());
    try std.testing.expectEqual(@as(usize, 1), try reader.arrayLen());
    try std.testing.expectEqual(@as(usize, 2), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 0), try reader.integer());
    try std.testing.expectEqual(@as(usize, 1), try reader.arrayLen());
    try std.testing.expectEqual(@as(usize, 2), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 4), try reader.integer());
    try std.testing.expectEqual(@as(usize, 3), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 17), try reader.integer());
    try std.testing.expectEqual(@as(i64, 300_000_000), try reader.integer());
    try std.testing.expectEqual(@as(i64, ranked_stage.card_play), try reader.integer());
    try std.testing.expectEqual(@as(usize, 0), try reader.arrayLen());

    var room: Room = .{ .id = 9, .settings = .{}, .host_id = 4, .ranked_play = .{} };
    try room.settings.name.set("rejoining pick");
    try room.settings.auto_start.set(&.{0xc0});
    room.ranked_play.?.pick_countdown = .{ .id = 18, .deadline_ms = 20_000, .stage = ranked_stage.card_play };
    var snapshot: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer snapshot.deinit();
    try writeRoom(.{ .writer = &snapshot.writer }, &room, 5_000);
    var snapshot_reader: MessagePackReader = .{ .data = snapshot.written() };
    try std.testing.expectEqual(@as(usize, 9), try snapshot_reader.arrayLen());
    for (0..7) |_| try snapshot_reader.skip(0);
    try std.testing.expectEqual(@as(usize, 1), try snapshot_reader.arrayLen());
    try std.testing.expectEqual(@as(usize, 2), try snapshot_reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 4), try snapshot_reader.integer());
    try std.testing.expectEqual(@as(usize, 3), try snapshot_reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 18), try snapshot_reader.integer());
    try std.testing.expectEqual(@as(i64, 150_000_000), try snapshot_reader.integer());
    try std.testing.expectEqual(@as(i64, ranked_stage.card_play), try snapshot_reader.integer());
}

test "expired ranked pick advances once with a deterministic card" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const room = try std.testing.allocator.create(Room);
    room.* = .{ .id = 9, .settings = .{}, .host_id = 4, .ranked_play = .{} };
    try room.settings.name.set("ranked timeout");
    try room.settings.auto_start.set(&.{0xc0});
    var item: PlaylistItem = .{ .id = 51, .owner_id = 4, .beatmap_id = 75 };
    try item.required_mods.set(&.{0x90});
    try item.allowed_mods.set(&.{0x90});
    try item.played_at.set(&.{0xc0});
    room.playlist[0] = item;
    room.playlist_count = 1;
    room.users[0] = try defaultRoomUser(4, "ranked timeout", .{ 'A', 'U' });
    room.user_count = 1;
    try room.users[0].?.availability.set(&.{ 0x92, beatmap_availability_locally_available, 0xc0 });
    const ranked = &room.ranked_play.?;
    ranked.stage = ranked_stage.card_play;
    ranked.current_round = 1;
    ranked.active_user_id = 4;
    ranked.user_count = 1;
    ranked.users[0] = .{ .id = 4 };
    var card: RankedCard = .{ .playlist_item_id = 51 };
    card.id.setText("00112233-4455-6677-8899-aabbccddeeff");
    ranked.users[0].?.hand[0] = card;
    ranked.users[0].?.hand_count = 1;
    ranked.pick_countdown = .{ .id = 3, .deadline_ms = 1_000, .stage = ranked_stage.card_play };
    manager.rooms[0] = room;

    try std.testing.expectEqual(@as(usize, 0), try manager.advanceExpiredRankedPicks(999));
    try std.testing.expectEqual(@as(usize, 1), try manager.advanceExpiredRankedPicks(1_000));
    try std.testing.expectEqual(@as(u8, ranked_stage.finish_card_play), room.ranked_play.?.stage);
    try std.testing.expectEqual(@as(i64, 51), room.settings.playlist_item_id);
    try std.testing.expectEqualStrings(card.id.slice(), room.ranked_play.?.played_card.?.id.slice());
    try std.testing.expect(room.ranked_play.?.pick_countdown == null);
    try std.testing.expectEqual(beatmap_availability_unknown, beatmapAvailabilityState(room.users[0].?.availability.slice()).?);
    try std.testing.expectEqual(@as(usize, 0), try manager.advanceExpiredRankedPicks(2_000));
}

test "ranked card selection clears stale beatmap availability" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer {
        manager.shutting_down = true;
        manager.deinit();
    }
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const user: domain.User = .{ .id = 4, .name = "ranked picker", .safe_name = "ranked_picker", .country = .{ 'A', 'U' } };
    const connection = try manager.connect(user, fake_socket);
    connection.socket = null;
    connection.room_id = 9;

    const room = try std.testing.allocator.create(Room);
    room.* = .{ .id = 9, .settings = .{}, .host_id = user.id, .ranked_play = .{} };
    try room.settings.name.set("ranked selection");
    try room.settings.auto_start.set(&.{0xc0});
    var item: PlaylistItem = .{ .id = 51, .owner_id = user.id, .beatmap_id = 75 };
    try item.required_mods.set(&.{0x90});
    try item.allowed_mods.set(&.{0x90});
    try item.played_at.set(&.{0xc0});
    room.playlist[0] = item;
    room.playlist_count = 1;
    room.users[0] = try defaultRoomUser(user.id, user.name, user.country);
    room.user_count = 1;
    try room.users[0].?.availability.set(&.{ 0x92, beatmap_availability_locally_available, 0xc0 });
    room.ranked_play.?.stage = ranked_stage.card_play;
    room.ranked_play.?.current_round = 1;
    room.ranked_play.?.active_user_id = user.id;
    room.ranked_play.?.users[0] = .{ .id = user.id };
    room.ranked_play.?.user_count = 1;
    var card: RankedCard = .{ .playlist_item_id = item.id };
    card.id.setText("00112233-4455-6677-8899-aabbccddeeff");
    room.ranked_play.?.users[0].?.hand[0] = card;
    room.ranked_play.?.users[0].?.hand_count = 1;
    manager.rooms[0] = room;

    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    const pack: MessagePackWriter = .{ .writer = &encoded.writer };
    try pack.array(1);
    try pack.string(card.id.slice());
    try manager.playRankedCard(connection, null, encoded.written());

    try std.testing.expectEqual(@as(u8, ranked_stage.finish_card_play), room.ranked_play.?.stage);
    try std.testing.expectEqual(@as(i64, item.id), room.settings.playlist_item_id);
    try std.testing.expectEqual(beatmap_availability_unknown, beatmapAvailabilityState(room.users[0].?.availability.slice()).?);
}

test "ranked card finish waits for every beatmap before ready starts gameplay" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer {
        manager.shutting_down = true;
        manager.deinit();
    }
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const first_user: domain.User = .{ .id = 4, .name = "ranked one", .safe_name = "ranked_one", .country = .{ 'A', 'U' } };
    const second_user: domain.User = .{ .id = 5, .name = "ranked two", .safe_name = "ranked_two", .country = .{ 'G', 'B' } };
    const first = try manager.connect(first_user, fake_socket);
    first.socket = null;
    first.room_id = 9;
    const second = try manager.connect(second_user, fake_socket);
    second.socket = null;
    second.room_id = 9;

    const room = try std.testing.allocator.create(Room);
    room.* = .{ .id = 9, .settings = .{}, .host_id = 3, .ranked_play = .{} };
    try room.settings.name.set("ranked warmup");
    room.users[0] = try defaultRoomUser(first_user.id, first_user.name, first_user.country);
    room.users[1] = try defaultRoomUser(second_user.id, second_user.name, second_user.country);
    room.user_count = 2;
    room.ranked_play.?.stage = ranked_stage.finish_card_play;
    room.ranked_play.?.current_round = 1;
    room.ranked_play.?.users[0] = .{ .id = first_user.id };
    room.ranked_play.?.users[1] = .{ .id = second_user.id };
    room.ranked_play.?.user_count = 2;
    manager.rooms[0] = room;

    const locally_available = [_]u8{ 0x92, beatmap_availability_locally_available, 0xc0 };
    try manager.changeAvailability(first, null, &locally_available);
    try std.testing.expectEqual(@as(u8, ranked_stage.finish_card_play), room.ranked_play.?.stage);
    try manager.changeAvailability(second, null, &locally_available);
    try std.testing.expectEqual(@as(u8, ranked_stage.gameplay_warmup), room.ranked_play.?.stage);

    try manager.changeState(first, null, 1);
    try std.testing.expectEqual(@as(u8, ranked_stage.gameplay_warmup), room.ranked_play.?.stage);
    try std.testing.expectEqual(@as(u8, 0), room.state);
    try manager.changeState(second, null, 1);
    try std.testing.expectEqual(@as(u8, ranked_stage.gameplay), room.ranked_play.?.stage);
    try std.testing.expectEqual(@as(u8, 1), room.state);
    try std.testing.expectEqual(@as(u8, 2), room.users[0].?.state);
    try std.testing.expectEqual(@as(u8, 2), room.users[1].?.state);
}

test "ranked card parser accepts canonical guids and rejects duplicates" {
    const first = "00112233-4455-6677-8899-aabbccddeeff";
    const second = "ffeeddcc-bbaa-9988-7766-554433221100";
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try pack.array(2);
    try pack.array(1);
    try pack.string(first);
    try pack.array(1);
    try pack.string(second);
    var cards: [ranked_hand_size][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try parseRankedCardList(output.written(), &cards));
    try std.testing.expectEqualStrings(first, cards[0]);

    output.clearRetainingCapacity();
    try pack.array(2);
    try pack.array(1);
    try pack.string(first);
    try pack.array(1);
    try pack.string(first);
    try std.testing.expectError(error.InvalidRankedPlayCard, parseRankedCardList(output.written(), &cards));
}
