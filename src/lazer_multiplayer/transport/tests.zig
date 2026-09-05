const std = @import("std");
const timespan_ticks_per_second = @import("../../lazer_multiplayer.zig").timespan_ticks_per_second;
const MessagePackReader = @import("../../lazer_multiplayer.zig").MessagePackReader;
const MessagePackWriter = @import("../../lazer_multiplayer.zig").MessagePackWriter;
const Room = @import("../rooms/model.zig").Room;
const Connection = @import("model.zig").Connection;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const defaultRoomUser = @import("../rooms/state.zig").defaultRoomUser;
const parseSettings = @import("../wire/parse.zig").parseSettings;
const parsePlaylistItem = @import("../wire/parse.zig").parsePlaylistItem;
const writeSettings = @import("../wire/messagepack.zig").writeSettings;
const writePlaylistItem = @import("../wire/messagepack.zig").writePlaylistItem;
const writeMatchState = @import("../wire/messagepack.zig").writeMatchState;
const eventRollOwned = @import("events.zig").eventRollOwned;

test "hostile multiplayer integers never trap narrow invocation or model fields" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    var connection: Connection = .{
        .allocator = std.testing.allocator,
        .user_id = 4,
        .user_country = .{ 'A', 'U' },
        .io = std.testing.io,
        .socket = null,
    };
    try connection.user_name.set("hostile");
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    const direct_targets = [_][]const u8{
        "TransferHost",
        "KickUser",
        "ChangeState",
        "InvitePlayer",
        "GetMatchmakingPoolsOfType",
        "MatchmakingJoinQueue",
    };
    for ([_]i64{ std.math.minInt(i64), std.math.maxInt(i64) }) |extreme| {
        for (direct_targets) |target| {
            encoded.clearRetainingCapacity();
            try (MessagePackWriter{ .writer = &encoded.writer }).integer(extreme);
            try HostileInvocationHarness.expectRejected(&manager, &connection, target, 1, encoded.written());
        }

        encoded.clearRetainingCapacity();
        var pack: MessagePackWriter = .{ .writer = &encoded.writer };
        try pack.integer(extreme);
        try pack.nil();
        try HostileInvocationHarness.expectRejected(&manager, &connection, "ChangeUserStyle", 2, encoded.written());
        encoded.clearRetainingCapacity();
        pack = .{ .writer = &encoded.writer };
        try pack.nil();
        try pack.integer(extreme);
        try HostileInvocationHarness.expectRejected(&manager, &connection, "ChangeUserStyle", 2, encoded.written());

        encoded.clearRetainingCapacity();
        pack = .{ .writer = &encoded.writer };
        try pack.array(1);
        try pack.integer(extreme);
        try HostileInvocationHarness.expectRejected(&manager, &connection, "MatchmakingJoinLobbyWithParams", 1, encoded.written());
        encoded.clearRetainingCapacity();
        pack = .{ .writer = &encoded.writer };
        try pack.array(2);
        try pack.integer(extreme);
        try pack.integer(1);
        try HostileInvocationHarness.expectRejected(&manager, &connection, "MatchmakingIssueDuel", 1, encoded.written());
        encoded.clearRetainingCapacity();
        pack = .{ .writer = &encoded.writer };
        try pack.array(2);
        try pack.integer(1);
        try pack.integer(extreme);
        try HostileInvocationHarness.expectRejected(&manager, &connection, "MatchmakingIssueDuel", 1, encoded.written());

        try HostileInvocationHarness.writeSettings(&encoded, extreme, 0, 2);
        try std.testing.expectError(error.InvalidMultiplayerArguments, parseSettings(encoded.written()));
        try HostileInvocationHarness.writeSettings(&encoded, 1, extreme, 2);
        try std.testing.expectError(error.InvalidMultiplayerArguments, parseSettings(encoded.written()));
        try HostileInvocationHarness.writeSettings(&encoded, 1, 0, extreme);
        try std.testing.expectError(error.InvalidMultiplayerArguments, parseSettings(encoded.written()));

        try HostileInvocationHarness.writePlaylistItem(&encoded, extreme, 75, 0, 0, 5);
        try std.testing.expectError(error.InvalidMultiplayerArguments, parsePlaylistItem(encoded.written()));
        try HostileInvocationHarness.writePlaylistItem(&encoded, 4, extreme, 0, 0, 5);
        try std.testing.expectError(error.InvalidMultiplayerArguments, parsePlaylistItem(encoded.written()));
        try HostileInvocationHarness.writePlaylistItem(&encoded, 4, 75, extreme, 0, 5);
        try std.testing.expectError(error.InvalidMultiplayerArguments, parsePlaylistItem(encoded.written()));
        try HostileInvocationHarness.writePlaylistItem(&encoded, 4, 75, 0, extreme, 5);
        try std.testing.expectError(error.InvalidMultiplayerArguments, parsePlaylistItem(encoded.written()));
    }

    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |non_finite| {
        try HostileInvocationHarness.writePlaylistItem(&encoded, 4, 75, 0, 0, non_finite);
        try std.testing.expectError(error.InvalidMultiplayerBeatmap, parsePlaylistItem(encoded.written()));
    }
}

test "typed match requests follow pinned countdown team slot roll and lock contracts" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const room = try std.testing.allocator.create(Room);
    room.* = .{
        .id = 1,
        .settings = .{},
        .host_id = 4,
        .host_country = .{ 'A', 'U' },
    };
    room.settings.match_type = 2;
    room.settings.max_participants = 4;
    try room.settings.name.set("typed requests");
    try room.host_name.set("raya");
    room.users[0] = try defaultRoomUser(4, "raya", .{ 'A', 'U' });
    room.users[0].?.team_id = 0;
    room.users[1] = try defaultRoomUser(7, "guest", .{ 'G', 'B' });
    room.users[1].?.team_id = 1;
    room.user_count = 2;
    manager.rooms[0] = room;

    var host: Connection = .{
        .allocator = std.testing.allocator,
        .user_id = 4,
        .user_country = .{ 'A', 'U' },
        .room_id = 1,
        .io = std.testing.io,
    };
    try host.user_name.set("raya");
    var guest: Connection = .{
        .allocator = std.testing.allocator,
        .user_id = 7,
        .user_country = .{ 'G', 'B' },
        .room_id = 1,
        .io = std.testing.io,
    };
    try guest.user_name.set("guest");

    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    const pack: MessagePackWriter = .{ .writer = &encoded.writer };

    // MatchUserRequest union key 0: ChangeTeamRequest { TeamID = 0 }.
    try pack.array(2);
    try pack.integer(0);
    try pack.array(1);
    try pack.integer(0);
    try manager.sendMatchRequest(&guest, null, encoded.written());
    try std.testing.expectEqual(@as(?i32, 0), room.users[1].?.team_id);

    // MatchUserRequest union key 1: StartMatchCountdownRequest { Duration = 5 seconds }.
    encoded.clearRetainingCapacity();
    try pack.array(2);
    try pack.integer(1);
    try pack.array(1);
    try pack.integer(5 * timespan_ticks_per_second);
    try manager.sendMatchRequest(&host, null, encoded.written());
    const countdown = room.match_start_countdown.?;
    try std.testing.expectEqual(@as(i32, 1), countdown.id);
    try std.testing.expectEqual(@as(i64, 2 * timespan_ticks_per_second), countdown.remainingTicks(countdown.deadline_ms - 2 * std.time.ms_per_s));

    // MatchUserRequest union key 2: StopCountdownRequest { ID = 1 }.
    encoded.clearRetainingCapacity();
    try pack.array(2);
    try pack.integer(2);
    try pack.array(1);
    try pack.integer(countdown.id);
    try manager.sendMatchRequest(&host, null, encoded.written());
    try std.testing.expect(room.match_start_countdown == null);

    // MatchUserRequest union key 5: SetLockStateRequest { Locked = true }.
    encoded.clearRetainingCapacity();
    try pack.array(2);
    try pack.integer(5);
    try pack.array(1);
    try pack.boolean(true);
    try manager.sendMatchRequest(&host, null, encoded.written());
    try std.testing.expect(room.locked);

    // MatchUserRequest union key 7: ChangeSlotRequest. Players cannot move while
    // locked, and occupied destinations are never swapped with the requester.
    encoded.clearRetainingCapacity();
    try pack.array(2);
    try pack.integer(7);
    try pack.array(1);
    try pack.integer(2);
    try std.testing.expectError(error.MultiplayerPermissionDenied, manager.sendMatchRequest(&guest, null, encoded.written()));
    try std.testing.expectEqual(@as(i32, 7), room.users[1].?.id);

    encoded.clearRetainingCapacity();
    try pack.array(2);
    try pack.integer(5);
    try pack.array(1);
    try pack.boolean(false);
    try manager.sendMatchRequest(&host, null, encoded.written());

    encoded.clearRetainingCapacity();
    try pack.array(2);
    try pack.integer(7);
    try pack.array(1);
    try pack.integer(2);
    try manager.sendMatchRequest(&guest, null, encoded.written());
    try std.testing.expect(room.users[1] == null);
    try std.testing.expectEqual(@as(i32, 7), room.users[2].?.id);

    encoded.clearRetainingCapacity();
    try pack.array(2);
    try pack.integer(7);
    try pack.array(1);
    try pack.integer(0);
    try std.testing.expectError(error.MultiplayerPermissionDenied, manager.sendMatchRequest(&guest, null, encoded.written()));
    try std.testing.expectEqual(@as(i32, 4), room.users[0].?.id);
    try std.testing.expectEqual(@as(i32, 7), room.users[2].?.id);

    // MatchUserRequest union key 6: RollRequest { Max = 20 }. The request is
    // accepted and the emitted event retains the pinned RollEvent union shape.
    encoded.clearRetainingCapacity();
    try pack.array(2);
    try pack.integer(6);
    try pack.array(1);
    try pack.integer(20);
    try manager.sendMatchRequest(&guest, null, encoded.written());

    const roll_frame = try eventRollOwned(std.testing.allocator, guest.user_id, 20, 7);
    defer std.testing.allocator.free(roll_frame);
    var frame_pos: usize = 0;
    var body_len: usize = 0;
    var shift: u6 = 0;
    while (true) {
        const byte_value = roll_frame[frame_pos];
        frame_pos += 1;
        body_len |= @as(usize, byte_value & 0x7f) << shift;
        if (byte_value & 0x80 == 0) break;
        shift += 7;
    }
    try std.testing.expectEqual(roll_frame.len - frame_pos, body_len);
    var event_reader: MessagePackReader = .{ .data = roll_frame[frame_pos..] };
    try std.testing.expectEqual(@as(usize, 6), try event_reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 1), try event_reader.integer());
    try std.testing.expectEqual(@as(usize, 0), try event_reader.mapLen());
    try event_reader.skip(0);
    try std.testing.expectEqualStrings("MatchEvent", try event_reader.string());
    try std.testing.expectEqual(@as(usize, 1), try event_reader.arrayLen());
    try std.testing.expectEqual(@as(usize, 2), try event_reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 4), try event_reader.integer());
    try std.testing.expectEqual(@as(usize, 3), try event_reader.arrayLen());
    try std.testing.expectEqual(@as(i64, guest.user_id), try event_reader.integer());
    try std.testing.expectEqual(@as(i64, 20), try event_reader.integer());
    try std.testing.expectEqual(@as(i64, 7), try event_reader.integer());
    try std.testing.expectEqual(@as(usize, 0), try event_reader.arrayLen());
    try std.testing.expectEqual(event_reader.data.len, event_reader.pos);

    // MessagePack-CSharp request objects have exactly one keyed field. Reject
    // extra fields instead of accepting a malformed union and ignoring data.
    encoded.clearRetainingCapacity();
    try pack.array(2);
    try pack.integer(6);
    try pack.array(2);
    try pack.integer(20);
    try pack.integer(21);
    try std.testing.expectError(error.InvalidMultiplayerArguments, manager.sendMatchRequest(&guest, null, encoded.written()));

    // The room-state response keeps the pinned TeamVersusRoomState union,
    // including lock state and the exact sparse slot array.
    encoded.clearRetainingCapacity();
    try writeMatchState(pack, room);
    var state_reader: MessagePackReader = .{ .data = encoded.written() };
    try std.testing.expectEqual(@as(usize, 2), try state_reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 0), try state_reader.integer());
    try std.testing.expectEqual(@as(usize, 3), try state_reader.arrayLen());
    try std.testing.expectEqual(@as(usize, 2), try state_reader.arrayLen());
    try state_reader.skip(0);
    try state_reader.skip(0);
    try std.testing.expect(!(try state_reader.boolean()));
    try std.testing.expectEqual(@as(usize, 4), try state_reader.arrayLen());
    try std.testing.expectEqual(@as(?i64, 4), try state_reader.nullableInteger());
    try std.testing.expectEqual(@as(?i64, null), try state_reader.nullableInteger());
    try std.testing.expectEqual(@as(?i64, 7), try state_reader.nullableInteger());
    try std.testing.expectEqual(@as(?i64, null), try state_reader.nullableInteger());
    try std.testing.expectEqual(state_reader.data.len, state_reader.pos);
}

pub const HostileInvocationHarness = struct {
    pub fn expectRejected(manager: *Manager, connection: *Connection, target: []const u8, argument_count: usize, encoded: []const u8) !void {
        var reader: MessagePackReader = .{ .data = encoded };
        try std.testing.expectError(error.InvalidMultiplayerArguments, manager.handleInvocation(connection, null, target, argument_count, &reader));
    }

    pub fn writeSettings(output: *std.Io.Writer.Allocating, match_type: i64, queue_mode: i64, max_participants: i64) !void {
        output.clearRetainingCapacity();
        const pack: MessagePackWriter = .{ .writer = &output.writer };
        try pack.array(8);
        try pack.string("hostile");
        try pack.integer(1);
        try pack.string("");
        try pack.integer(match_type);
        try pack.integer(queue_mode);
        try pack.nil();
        try pack.boolean(false);
        try pack.integer(max_participants);
    }

    pub fn writePlaylistItem(output: *std.Io.Writer.Allocating, owner_id: i64, beatmap_id: i64, ruleset_id: i64, order: i64, star_rating: f64) !void {
        output.clearRetainingCapacity();
        const pack: MessagePackWriter = .{ .writer = &output.writer };
        try pack.array(12);
        try pack.integer(1);
        try pack.integer(owner_id);
        try pack.integer(beatmap_id);
        try pack.string("");
        try pack.integer(ruleset_id);
        try pack.array(0);
        try pack.array(0);
        try pack.boolean(false);
        try pack.integer(order);
        try pack.nil();
        try pack.float64(star_rating);
        try pack.boolean(false);
    }
};
