const std = @import("std");
const domain = @import("../domain.zig");
const storage = @import("../runtime_storage.zig");
const pending_match_timeout_seconds = @import("../lazer_multiplayer.zig").pending_match_timeout_seconds;
const MessagePackReader = @import("../lazer_multiplayer.zig").MessagePackReader;
const eventNoArgsOwned = @import("../lazer_multiplayer.zig").eventNoArgsOwned;
const PlaylistItem = @import("../lazer_multiplayer.zig").PlaylistItem;
const Room = @import("rooms/model.zig").Room;
const Connection = @import("transport/model.zig").Connection;
const Manager = @import("../lazer_multiplayer.zig").Manager;
const writeRoom = @import("wire/messagepack.zig").writeRoom;

test "reconnect shutdown and invitation expiry use pinned no-argument hub events" {
    for ([_][]const u8{ "DisconnectRequested", "ServerShuttingDown", "MatchmakingQueueLeft" }) |target| {
        const frame = try eventNoArgsOwned(std.testing.allocator, target);
        defer std.testing.allocator.free(frame);
        var prefix_len: usize = 0;
        while (frame[prefix_len] & 0x80 != 0) prefix_len += 1;
        prefix_len += 1;
        var reader: MessagePackReader = .{ .data = frame[prefix_len..] };
        try std.testing.expectEqual(@as(usize, 6), try reader.arrayLen());
        try std.testing.expectEqual(@as(i64, 1), try reader.integer());
        try std.testing.expectEqual(@as(usize, 0), try reader.mapLen());
        try reader.skip(0);
        try std.testing.expectEqualStrings(target, try reader.string());
        try std.testing.expectEqual(@as(usize, 0), try reader.arrayLen());
        try std.testing.expectEqual(@as(usize, 0), try reader.arrayLen());
        try std.testing.expectEqual(reader.data.len, reader.pos);
    }
}

test "multiplayer feature gate drains sessions at the invocation boundary and reopens" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const user: domain.User = .{ .id = 4, .name = "gate user", .safe_name = "gate_user", .country = .{ 'A', 'U' } };
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const connection = try manager.connect(user, fake_socket);
    connection.socket = null;
    const stale_user: domain.User = .{ .id = 7, .name = "stale gate", .safe_name = "stale_gate", .country = .{ 'G', 'B' } };
    const stale = try manager.connect(stale_user, fake_socket);
    stale.socket = null;
    stale.close();
    try std.testing.expectEqual(@as(usize, 2), manager.connections.items.len);
    try std.testing.expectEqual(@as(usize, 1), manager.runtimeCounts().connections);

    const Toggle = struct {
        manager: *Manager,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),

        fn run(context: *@This()) void {
            context.started.store(true, .release);
            context.manager.setEnabled(false);
            context.done.store(true, .release);
        }
    };
    connection.invocation_mutex.lockUncancelable(std.testing.io);
    var toggle: Toggle = .{ .manager = &manager };
    const thread = try std.Thread.spawn(.{}, Toggle.run, .{&toggle});
    while (manager.isEnabled()) std.Thread.yield() catch {};
    try std.testing.expect(toggle.started.load(.acquire));
    try std.testing.expect(!toggle.done.load(.acquire));
    connection.queue_pool_id = 101;
    connection.invocation_mutex.unlock(std.testing.io);
    thread.join();

    try std.testing.expect(!manager.isEnabled());
    try std.testing.expect(!connection.alive.load(.acquire));
    try std.testing.expect(!connection.accepting_invocations.load(.acquire));
    try std.testing.expectEqual(@as(?i32, null), connection.queue_pool_id);
    try std.testing.expectEqual(@as(usize, 0), manager.connections.items.len);
    try std.testing.expectError(error.MultiplayerDisabled, manager.connect(user, fake_socket));
    try std.testing.expectError(error.ConnectionClose, manager.handleHubMessage(connection, &.{}));

    manager.setEnabled(true);
    try std.testing.expect(manager.isEnabled());
    const reopened = try manager.connect(user, fake_socket);
    reopened.socket = null;
    try std.testing.expect(reopened.alive.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), manager.connections.items.len);
    // The direct fixture owns the same final handler reference that serve()
    // normally releases after its read wakes on the close frame.
    manager.disconnect(connection);
    manager.disconnect(stale);
    manager.disconnect(reopened);
}

test "disabled multiplayer rejects REST room creation and reopens idempotently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/multiplayer-disable.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("rest gate", "rest-gate@example.invalid", "00000000000000000000000000000000");
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    const user: domain.User = .{ .id = user_id, .name = "rest gate", .safe_name = "rest_gate", .country = .{ 'A', 'U' } };
    const room_body =
        \\{"name":"rest gate room","type":"playlists","duration":30,"playlist":[{"id":8,"owner_id":0,"beatmap_id":75,"ruleset_id":0}]}
    ;

    const Toggle = struct {
        manager: *Manager,
        enabled: bool,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        fn run(context: *@This()) void {
            context.started.store(true, .release);
            context.manager.setEnabled(context.enabled);
            context.done.store(true, .release);
        }
    };
    var admitted = try manager.beginMutation();
    var disable: Toggle = .{ .manager = &manager, .enabled = false };
    const disable_thread = try std.Thread.spawn(.{}, Toggle.run, .{&disable});
    while (manager.isEnabled()) std.Thread.yield() catch {};
    var enable: Toggle = .{ .manager = &manager, .enabled = true };
    const enable_thread = try std.Thread.spawn(.{}, Toggle.run, .{&enable});
    while (!enable.started.load(.acquire)) std.Thread.yield() catch {};
    _ = std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    try std.testing.expect(!disable.done.load(.acquire));
    try std.testing.expect(!enable.done.load(.acquire));
    admitted.deinit();
    disable_thread.join();
    enable_thread.join();
    try std.testing.expect(manager.isEnabled());

    manager.setEnabled(false);
    try std.testing.expectError(error.MultiplayerDisabled, manager.restCreateRoom(std.testing.allocator, user, room_body));
    for (manager.rooms) |entry| try std.testing.expect(entry == null);

    manager.setEnabled(true);
    manager.setEnabled(true);
    const created = try manager.restCreateRoom(std.testing.allocator, user, room_body);
    defer std.testing.allocator.free(created);
    try std.testing.expect(manager.rooms[0] != null);

    manager.setEnabled(false);
    for (manager.rooms) |entry| try std.testing.expect(entry == null);
    var archived = (try store.lazerMultiplayerRoomArchive(std.testing.allocator, 1)).?;
    const first_ended_at = archived.ended_at;
    archived.deinit();
    manager.setEnabled(false);
    var unchanged = (try store.lazerMultiplayerRoomArchive(std.testing.allocator, 1)).?;
    defer unchanged.deinit();
    try std.testing.expectEqual(first_ended_at, unchanged.ended_at);
    manager.setEnabled(true);
    const recreated = try manager.restCreateRoom(std.testing.allocator, user, room_body);
    defer std.testing.allocator.free(recreated);
    try std.testing.expect(manager.rooms[0] != null);
    try std.testing.expectEqual(@as(i64, 2), manager.rooms[0].?.id);
}

test "shutdown rejects delayed websocket creation and checkpoints each room once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/multiplayer-boundary.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const host_id = try store.register("checkpoint host", "checkpoint-host@example.invalid", "00000000000000000000000000000000");
    const late_user_id = try store.register("late websocket", "late-websocket@example.invalid", "00000000000000000000000000000000");

    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    try manager.bindStore(&store);
    const host: domain.User = .{ .id = host_id, .name = "checkpoint host", .safe_name = "checkpoint_host", .country = .{ 'A', 'U' } };
    const late_user: domain.User = .{ .id = late_user_id, .name = "late websocket", .safe_name = "late_websocket", .country = .{ 'G', 'B' } };
    const room_body =
        \\{"name":"checkpoint once","type":"playlists","duration":30,"playlist":[{"id":8,"owner_id":0,"beatmap_id":75,"ruleset_id":0}]}
    ;
    const created = try manager.restCreateRoom(std.testing.allocator, host, room_body);
    defer std.testing.allocator.free(created);

    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const connection = try manager.connect(late_user, fake_socket);
    connection.socket = null;
    var client_room: Room = .{ .id = 0, .settings = .{}, .host_id = late_user.id, .host_country = late_user.country };
    try client_room.settings.name.set("too late");
    client_room.settings.match_type = 1;
    client_room.settings.playlist_item_id = 9;
    try client_room.settings.auto_start.set(&.{0xc0});
    try client_room.host_name.set(late_user.name);
    var item: PlaylistItem = .{ .id = 9, .owner_id = late_user.id, .beatmap_id = 76 };
    try item.required_mods.set(&.{0x90});
    try item.allowed_mods.set(&.{0x90});
    try item.played_at.set(&.{0xc0});
    client_room.playlist[0] = item;
    client_room.playlist_count = 1;
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try writeRoom(.{ .writer = &encoded.writer }, &client_room, 0);

    const DelayedCreate = struct {
        manager: *Manager,
        connection: *Connection,
        encoded: []const u8,
        proceed: std.atomic.Value(bool) = .init(false),
        rejected: bool = false,
        unexpected_error: ?anyerror = null,

        fn run(context: *@This()) void {
            while (!context.proceed.load(.acquire)) std.Thread.yield() catch {};
            context.manager.createRoom(context.connection, "late", context.encoded) catch |err| {
                if (err == error.ServerShuttingDown) context.rejected = true else context.unexpected_error = err;
                return;
            };
        }
    };
    const Stop = struct {
        manager: *Manager,
        fn run(value: *@This()) void {
            value.manager.shutdown();
        }
    };
    var delayed: DelayedCreate = .{ .manager = &manager, .connection = connection, .encoded = encoded.written() };
    var stop: Stop = .{ .manager = &manager };
    const delayed_thread = try std.Thread.spawn(.{}, DelayedCreate.run, .{&delayed});
    const shutdown_thread = try std.Thread.spawn(.{}, Stop.run, .{&stop});
    while (manager.isEnabled()) std.Thread.yield() catch {};
    delayed.proceed.store(true, .release);
    delayed_thread.join();
    shutdown_thread.join();

    try std.testing.expect(delayed.rejected);
    try std.testing.expectEqual(@as(?anyerror, null), delayed.unexpected_error);
    for (manager.rooms) |entry| try std.testing.expect(entry == null);
    const checkpoints = try store.lazerMultiplayerRoomCheckpoints(std.testing.allocator);
    defer {
        for (checkpoints) |*checkpoint| checkpoint.deinit();
        std.testing.allocator.free(checkpoints);
    }
    try std.testing.expectEqual(@as(usize, 1), checkpoints.len);
    try std.testing.expectEqual(@as(i64, 1), checkpoints[0].room_id);
    manager.shutdown();
    const repeated = try store.lazerMultiplayerRoomCheckpoints(std.testing.allocator);
    defer {
        for (repeated) |*checkpoint| checkpoint.deinit();
        std.testing.allocator.free(repeated);
    }
    try std.testing.expectEqual(@as(usize, 1), repeated.len);
}

test "one websocket identity rebinds room and queue state without duplicate membership" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const host: domain.User = .{ .id = 4, .name = "raya", .safe_name = "raya", .country = .{ 'A', 'U' } };
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const old = try manager.connect(host, fake_socket);
    old.socket = null;
    const room_body =
        \\{"name":"reconnect","type":"head_to_head","playlist":[{"id":8,"owner_id":4,"beatmap_id":75,"ruleset_id":0}]}
    ;
    const created = try manager.restCreateRoom(std.testing.allocator, host, room_body);
    defer std.testing.allocator.free(created);
    try std.testing.expectEqual(@as(?i64, 1), old.room_id);

    const replacement = try manager.connect(host, fake_socket);
    replacement.socket = null;
    try std.testing.expect(!old.alive.load(.acquire));
    try std.testing.expectEqual(@as(?i64, null), old.room_id);
    try std.testing.expectEqual(@as(?i64, 1), replacement.room_id);
    try std.testing.expectEqual(@as(usize, 1), manager.connections.items.len);
    try std.testing.expect(manager.connections.items[0] == replacement);
    try manager.joinRoom(replacement, "1", 1, "");
    try std.testing.expectEqual(@as(usize, 1), manager.rooms[0].?.user_count);
    try std.testing.expectError(error.ConnectionClose, manager.handleHubMessage(old, &.{}));
    manager.disconnect(old);

    try manager.leaveRoom(replacement, null);
    replacement.lobby_pool_id = 100;
    replacement.queue_pool_id = 100;
    replacement.pending_match_id = 7;
    manager.pending_matches[0] = .{ .id = 7, .pool_id = 100, .users = .{ host.id, 7 }, .created_at = 0 };
    const queued_replacement = try manager.connect(host, fake_socket);
    queued_replacement.socket = null;
    try std.testing.expectEqual(@as(?i32, 100), queued_replacement.lobby_pool_id);
    try std.testing.expectEqual(@as(?i32, 100), queued_replacement.queue_pool_id);
    try std.testing.expectEqual(@as(?u32, 7), queued_replacement.pending_match_id);
    try std.testing.expectEqual(@as(usize, 1), manager.connections.items.len);
    manager.disconnect(replacement);
    try std.testing.expectEqual(@as(usize, 0), manager.expirePendingMatches(pending_match_timeout_seconds - 1));
    try std.testing.expectEqual(@as(usize, 1), manager.expirePendingMatches(pending_match_timeout_seconds));
    try std.testing.expectEqual(@as(?i32, null), queued_replacement.queue_pool_id);
    try std.testing.expectEqual(@as(?u32, null), queued_replacement.pending_match_id);
    try std.testing.expect(manager.pending_matches[0] == null);
}

test "cross client disconnect stops invocations and is idempotent" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const user: domain.User = .{ .id = 4, .name = "takeover", .safe_name = "takeover", .country = .{ 'A', 'U' } };
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const connection = try manager.connect(user, fake_socket);
    connection.socket = null;
    const created = try manager.restCreateRoom(std.testing.allocator, user,
        \\{"name":"takeover room","type":"head_to_head","playlist":[{"id":8,"owner_id":4,"beatmap_id":75,"ruleset_id":0}]}
    );
    defer std.testing.allocator.free(created);
    try std.testing.expectEqual(@as(?i64, 1), connection.room_id);

    const Takeover = struct {
        manager: *Manager,
        user_id: i32,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        disconnected: bool = false,

        fn run(context: *@This()) void {
            context.started.store(true, .release);
            context.disconnected = context.manager.disconnectUser(context.user_id);
            context.done.store(true, .release);
        }
    };
    connection.invocation_mutex.lockUncancelable(std.testing.io);
    var takeover: Takeover = .{ .manager = &manager, .user_id = user.id };
    const takeover_thread = try std.Thread.spawn(.{}, Takeover.run, .{&takeover});
    while (!takeover.started.load(.acquire)) std.Thread.yield() catch {};
    _ = std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    try std.testing.expect(!takeover.done.load(.acquire));
    // This is the final mutation committed by the already-running invocation.
    // The takeover must wait for it and synchronously clear it before return.
    connection.lobby_pool_id = 101;
    connection.queue_pool_id = 101;
    connection.invocation_mutex.unlock(std.testing.io);
    takeover_thread.join();

    try std.testing.expect(takeover.disconnected);
    try std.testing.expect(!connection.alive.load(.acquire));
    try std.testing.expect(!connection.accepting_invocations.load(.acquire));
    try std.testing.expectEqual(@as(?i64, null), connection.room_id);
    try std.testing.expectEqual(@as(?i32, null), connection.lobby_pool_id);
    try std.testing.expectEqual(@as(?i32, null), connection.queue_pool_id);
    try std.testing.expectEqual(@as(usize, 0), manager.connections.items.len);
    for (manager.rooms) |entry| try std.testing.expect(entry == null);
    try std.testing.expect(!manager.disconnectUser(user.id));
    try std.testing.expectError(error.ConnectionClose, manager.handleHubMessage(connection, &.{}));
    // The real websocket handler owns the final reference until its blocked
    // read observes the close frame. This direct-manager fixture releases it
    // explicitly after making the same deferred disconnect call.
    manager.disconnect(connection);
}

test "connection replacement waits only for the old identity invocation boundary" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const host: domain.User = .{ .id = 4, .name = "raya", .safe_name = "raya", .country = .{ 'A', 'U' } };
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const old = try manager.connect(host, fake_socket);
    old.socket = null;

    const Replacement = struct {
        manager: *Manager,
        user: domain.User,
        socket: *std.http.Server.WebSocket,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        result: ?*Connection = null,
        failure: ?anyerror = null,

        fn run(context: *@This()) void {
            context.started.store(true, .release);
            context.result = context.manager.connect(context.user, context.socket) catch |err| failed: {
                context.failure = err;
                break :failed null;
            };
            context.done.store(true, .release);
        }
    };

    old.invocation_mutex.lockUncancelable(std.testing.io);
    var replacement_context: Replacement = .{ .manager = &manager, .user = host, .socket = fake_socket };
    const replacement_thread = try std.Thread.spawn(.{}, Replacement.run, .{&replacement_context});
    while (!replacement_context.started.load(.acquire)) std.Thread.yield() catch {};
    _ = std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    const crossed_boundary = replacement_context.done.load(.acquire);
    const guest: domain.User = .{ .id = 7, .name = "other room", .safe_name = "other_room", .country = .{ 'G', 'B' } };
    const unrelated = try manager.connect(guest, fake_socket);
    unrelated.socket = null;
    try std.testing.expectEqual(@as(usize, 2), manager.connections.items.len);
    manager.disconnect(unrelated);
    // This assignment stands in for the final state committed by the old
    // invocation while the replacement is waiting at the gate.
    old.room_id = 77;
    old.invocation_mutex.unlock(std.testing.io);
    replacement_thread.join();

    try std.testing.expect(!crossed_boundary);
    try std.testing.expect(replacement_context.failure == null);
    const replacement = replacement_context.result.?;
    replacement.socket = null;
    try std.testing.expectEqual(@as(?i64, 77), replacement.room_id);
    try std.testing.expect(!old.alive.load(.acquire));
    manager.disconnect(old);
}
