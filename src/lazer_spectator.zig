const std = @import("std");
const domain = @import("domain.zig");
const signalr = @import("lazer_multiplayer.zig");
const storage = @import("runtime_storage.zig");

pub const max_connections = 128;
pub const max_subscriptions = 32;
pub const max_frames_per_bundle = 30;
pub const max_hub_message = 60 * 1024;
pub const max_frame_bundles_per_second = 20;
const max_state_value = 16 * 1024;

pub const Activity = enum { playing, spectating };

fn FixedRaw(comptime capacity: usize) type {
    return struct {
        len: u16 = 0,
        bytes: [capacity]u8 = undefined,

        const Self = @This();

        fn set(self: *Self, value: []const u8) !void {
            if (value.len > self.bytes.len) return error.SpectatorPayloadTooLarge;
            @memcpy(self.bytes[0..value.len], value);
            self.len = @intCast(value.len);
        }

        fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

const Text64 = FixedRaw(64);
const RawState = FixedRaw(max_state_value);

const ActivePlay = struct {
    score_token: ?i64,
    beatmap_id: i32,
    ruleset_id: u8,
    mods: RawState,
    maximum_statistics: RawState,
    processed_score_id: ?i64 = null,
};

const SpectatorUser = struct {
    id: i32,
    name: Text64,
};

const DisconnectEffects = struct {
    user_id: i32 = 0,
    watchers: [max_connections]*Connection = undefined,
    watcher_count: usize = 0,
    watched_hosts: [max_subscriptions]*Connection = undefined,
    host_count: usize = 0,
    active: ?ActivePlay = null,
};

const Connection = struct {
    allocator: std.mem.Allocator,
    references: std.atomic.Value(usize) = .init(1),
    user_id: i32,
    user_name: Text64 = .{},
    subscriptions: [max_subscriptions]i32 = [_]i32{0} ** max_subscriptions,
    subscription_count: usize = 0,
    active: ?ActivePlay = null,
    frame_window_second: i64 = 0,
    frame_bundle_count: u8 = 0,
    io: std.Io,
    write_mutex: std.Io.Mutex = .init,
    invocation_mutex: std.Io.Mutex = .init,
    socket: ?*std.http.Server.WebSocket = null,
    alive: std.atomic.Value(bool) = .init(true),
    accepting_invocations: std.atomic.Value(bool) = .init(true),

    fn retain(self: *Connection) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }

    fn release(self: *Connection) void {
        if (self.references.fetchSub(1, .release) == 1) {
            _ = self.references.load(.acquire);
            self.allocator.destroy(self);
        }
    }

    fn send(self: *Connection, frame: []const u8) void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (!self.alive.load(.acquire)) return;
        const socket = self.socket orelse return;
        socket.writeMessage(frame, .binary) catch {
            self.accepting_invocations.store(false, .release);
            self.alive.store(false, .release);
        };
    }

    fn close(self: *Connection) void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        self.accepting_invocations.store(false, .release);
        if (self.alive.load(.acquire)) if (self.socket) |socket| socket.writeMessage("", .connection_close) catch {};
        self.alive.store(false, .release);
        self.socket = null;
    }

    fn watches(self: *const Connection, user_id: i32) bool {
        return std.mem.indexOfScalar(i32, self.subscriptions[0..self.subscription_count], user_id) != null;
    }

    fn subscribe(self: *Connection, user_id: i32) !bool {
        if (self.watches(user_id)) return false;
        if (self.subscription_count == self.subscriptions.len) return error.SpectatorSubscriptionLimit;
        self.subscriptions[self.subscription_count] = user_id;
        self.subscription_count += 1;
        return true;
    }

    fn unsubscribe(self: *Connection, user_id: i32) bool {
        const index = std.mem.indexOfScalar(i32, self.subscriptions[0..self.subscription_count], user_id) orelse return false;
        self.subscription_count -= 1;
        self.subscriptions[index] = self.subscriptions[self.subscription_count];
        self.subscriptions[self.subscription_count] = 0;
        return true;
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: ?*storage.Store = null,
    mutex: std.Io.Mutex = .init,
    connections: std.ArrayList(*Connection) = .empty,
    enabled: std.atomic.Value(bool) = .init(true),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Manager {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn bindStore(self: *Manager, store: *storage.Store) void {
        self.store = store;
    }

    pub fn isEnabled(self: *const Manager) bool {
        return self.enabled.load(.acquire);
    }

    pub fn setEnabled(self: *Manager, enabled: bool) void {
        self.enabled.store(enabled, .release);
        if (enabled) return;
        var targets: [max_connections]*Connection = undefined;
        var count: usize = 0;
        self.mutex.lockUncancelable(self.io);
        for (self.connections.items) |connection| {
            if (count == targets.len) break;
            connection.retain();
            targets[count] = connection;
            count += 1;
        }
        self.mutex.unlock(self.io);
        for (targets[0..count]) |connection| {
            connection.invocation_mutex.lockUncancelable(self.io);
            self.mutex.lockUncancelable(self.io);
            const still_current = std.mem.indexOfScalar(*Connection, self.connections.items, connection) != null;
            if (still_current) {
                connection.accepting_invocations.store(false, .release);
                connection.active = null;
                connection.subscription_count = 0;
                self.removeConnectionLocked(connection);
            }
            self.mutex.unlock(self.io);
            connection.invocation_mutex.unlock(self.io);
            if (still_current) connection.close();
            connection.release();
        }
    }

    pub fn deinit(self: *Manager) void {
        for (self.connections.items) |connection| connection.release();
        self.connections.deinit(self.allocator);
    }

    fn connectionByUserLocked(self: *Manager, user_id: i32) ?*Connection {
        var found: ?*Connection = null;
        for (self.connections.items) |connection| {
            if (connection.alive.load(.acquire) and connection.user_id == user_id) found = connection;
        }
        return found;
    }

    fn latestConnectionByUserLocked(self: *Manager, user_id: i32) ?*Connection {
        var found: ?*Connection = null;
        for (self.connections.items) |connection| {
            if (connection.user_id == user_id) found = connection;
        }
        return found;
    }

    fn watchersLocked(self: *Manager, user_id: i32, output: *[max_connections]*Connection) usize {
        var count: usize = 0;
        for (self.connections.items) |connection| {
            if (!connection.alive.load(.acquire) or !connection.watches(user_id)) continue;
            if (count == output.len) break;
            connection.retain();
            output[count] = connection;
            count += 1;
        }
        return count;
    }

    pub fn activity(self: *Manager, user_id: i32) ?Activity {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const connection = self.connectionByUserLocked(user_id) orelse return null;
        if (connection.active != null) return .playing;
        if (connection.subscription_count != 0) return .spectating;
        return null;
    }

    pub fn connectionCount(self: *Manager) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.connections.items) |connection| if (connection.alive.load(.acquire)) {
            count += 1;
        };
        return count;
    }

    pub fn disconnectUser(self: *Manager, user_id: i32) bool {
        var targets: [max_connections]*Connection = undefined;
        var count: usize = 0;
        self.mutex.lockUncancelable(self.io);
        for (self.connections.items) |connection| {
            if (!connection.alive.load(.acquire) or connection.user_id != user_id or count == targets.len) continue;
            connection.retain();
            targets[count] = connection;
            count += 1;
        }
        self.mutex.unlock(self.io);
        var disconnected = false;
        for (targets[0..count]) |connection| {
            if (self.retireConnectionAtInvocationBoundary(connection, true)) disconnected = true;
            connection.release();
        }
        return disconnected;
    }

    fn connect(self: *Manager, user: domain.User, socket: *std.http.Server.WebSocket) !*Connection {
        if (!self.isEnabled()) return error.SpectatorDisabled;
        if (user.id <= 0 or user.name.len == 0 or user.name.len > 64) return error.InvalidSpectatorUser;
        const connection = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(connection);
        connection.* = .{ .allocator = self.allocator, .user_id = user.id, .io = self.io, .socket = socket };
        try connection.user_name.set(user.name);

        while (true) {
            var replaced: ?*Connection = null;
            self.mutex.lockUncancelable(self.io);
            if (!self.isEnabled()) {
                self.mutex.unlock(self.io);
                return error.SpectatorDisabled;
            }
            if (self.latestConnectionByUserLocked(user.id)) |old| {
                old.retain();
                replaced = old;
            } else {
                if (self.connections.items.len >= max_connections) {
                    self.mutex.unlock(self.io);
                    return error.SpectatorConnectionLimit;
                }
                self.connections.append(self.allocator, connection) catch |err| {
                    self.mutex.unlock(self.io);
                    return err;
                };
            }
            self.mutex.unlock(self.io);
            if (replaced) |old| {
                _ = self.retireConnectionAtInvocationBoundary(old, false);
                old.release();
                continue;
            }
            break;
        }
        return connection;
    }

    fn removeConnectionLocked(self: *Manager, connection: *Connection) void {
        const index = std.mem.indexOfScalar(*Connection, self.connections.items, connection) orelse return;
        _ = self.connections.swapRemove(index);
    }

    /// Stops a connection at the same boundary used to serialize hub
    /// invocations. Once this returns, the connection is no longer visible to
    /// the manager and no invocation which was already parsed can mutate its
    /// play or subscription state.
    fn retireConnectionAtInvocationBoundary(self: *Manager, connection: *Connection, notify: bool) bool {
        var effects: DisconnectEffects = .{};
        connection.invocation_mutex.lockUncancelable(self.io);
        self.mutex.lockUncancelable(self.io);
        const still_connected = std.mem.indexOfScalar(*Connection, self.connections.items, connection) != null;
        if (still_connected) {
            connection.accepting_invocations.store(false, .release);
            self.detachConnectionLocked(connection, &effects, notify);
        }
        self.mutex.unlock(self.io);
        connection.invocation_mutex.unlock(self.io);
        if (still_connected) {
            connection.close();
            self.finishDisconnect(&effects);
        }
        return still_connected;
    }

    fn detachConnectionLocked(self: *Manager, connection: *Connection, effects: *DisconnectEffects, notify: bool) void {
        if (notify) {
            effects.user_id = connection.user_id;
            if (self.latestConnectionByUserLocked(connection.user_id) == connection) {
                effects.active = connection.active;
                effects.watcher_count = self.watchersLocked(connection.user_id, &effects.watchers);
            }
            for (connection.subscriptions[0..connection.subscription_count]) |host_id| {
                if (self.connectionByUserLocked(host_id)) |host| {
                    host.retain();
                    effects.watched_hosts[effects.host_count] = host;
                    effects.host_count += 1;
                }
            }
        }
        connection.active = null;
        @memset(&connection.subscriptions, 0);
        connection.subscription_count = 0;
        connection.frame_window_second = 0;
        connection.frame_bundle_count = 0;
        self.removeConnectionLocked(connection);
    }

    fn finishDisconnect(self: *Manager, effects: *DisconnectEffects) void {
        defer releaseConnections(effects.watchers[0..effects.watcher_count]);
        defer releaseConnections(effects.watched_hosts[0..effects.host_count]);
        if (effects.active) |play| if (eventStateOwned(self.allocator, "UserFinishedPlaying", effects.user_id, play, 5)) |frame| {
            defer self.allocator.free(frame);
            sendConnections(effects.watchers[0..effects.watcher_count], frame);
        } else |_| {};
        if (effects.host_count != 0) if (eventIntegerOwned(self.allocator, "UserEndedWatching", effects.user_id)) |frame| {
            defer self.allocator.free(frame);
            sendConnections(effects.watched_hosts[0..effects.host_count], frame);
        } else |_| {};
    }

    fn disconnect(self: *Manager, connection: *Connection) void {
        connection.close();
        var watchers: [max_connections]*Connection = undefined;
        var watched_hosts: [max_subscriptions]*Connection = undefined;
        var watcher_count: usize = 0;
        var host_count: usize = 0;
        var active: ?ActivePlay = null;

        self.mutex.lockUncancelable(self.io);
        const is_current = self.latestConnectionByUserLocked(connection.user_id) == connection;
        if (is_current) {
            active = connection.active;
            watcher_count = self.watchersLocked(connection.user_id, &watchers);
        }
        for (connection.subscriptions[0..connection.subscription_count]) |host_id| {
            if (self.connectionByUserLocked(host_id)) |host| {
                host.retain();
                watched_hosts[host_count] = host;
                host_count += 1;
            }
        }
        connection.active = null;
        @memset(&connection.subscriptions, 0);
        connection.subscription_count = 0;
        connection.frame_window_second = 0;
        connection.frame_bundle_count = 0;
        self.removeConnectionLocked(connection);
        self.mutex.unlock(self.io);

        defer releaseConnections(watchers[0..watcher_count]);
        defer releaseConnections(watched_hosts[0..host_count]);
        if (active) |play| if (eventStateOwned(self.allocator, "UserFinishedPlaying", connection.user_id, play, 5)) |frame| {
            defer self.allocator.free(frame);
            sendConnections(watchers[0..watcher_count], frame);
        } else |_| {};
        if (eventIntegerOwned(self.allocator, "UserEndedWatching", connection.user_id)) |frame| {
            defer self.allocator.free(frame);
            sendConnections(watched_hosts[0..host_count], frame);
        } else |_| {}
        connection.release();
    }

    pub fn serve(self: *Manager, user: domain.User, socket: *std.http.Server.WebSocket) !void {
        const handshake = try socket.readSmallMessage();
        if ((handshake.opcode != .text and handshake.opcode != .binary) or !signalr.validSignalRHandshake(self.allocator, handshake.data)) return error.InvalidSignalRHandshake;
        try socket.writeMessage("{}\x1e", handshake.opcode);
        const connection = try self.connect(user, socket);
        defer self.disconnect(connection);
        while (connection.alive.load(.acquire)) {
            const message = socket.readSmallMessage() catch return;
            switch (message.opcode) {
                .ping => {
                    connection.write_mutex.lockUncancelable(connection.io);
                    defer connection.write_mutex.unlock(connection.io);
                    if (connection.alive.load(.acquire)) try socket.writeMessage(message.data, .pong);
                },
                .binary => try self.handleFrames(connection, message.data),
                else => {},
            }
        }
    }

    fn handleFrames(self: *Manager, connection: *Connection, data: []const u8) !void {
        var position: usize = 0;
        while (position < data.len) {
            var length: usize = 0;
            var shift: u6 = 0;
            var prefix_bytes: u8 = 0;
            while (true) {
                if (position >= data.len or prefix_bytes == 5) return error.InvalidSignalRFrame;
                const byte_value = data[position];
                position += 1;
                prefix_bytes += 1;
                length |= @as(usize, byte_value & 0x7f) << shift;
                if (byte_value & 0x80 == 0) break;
                shift += 7;
            }
            if (length == 0 or length > max_hub_message or position + length > data.len) return error.InvalidSignalRFrame;
            try self.handleHubMessage(connection, data[position .. position + length]);
            position += length;
        }
    }

    fn handleHubMessage(self: *Manager, connection: *Connection, payload: []const u8) !void {
        if (!self.isEnabled() or !connection.alive.load(.acquire) or !connection.accepting_invocations.load(.acquire)) return error.ConnectionClose;
        var reader: signalr.MessagePackReader = .{ .data = payload };
        const count = try reader.arrayLen();
        if (count == 0) return error.InvalidSignalRMessage;
        const message_type = try reader.integer();
        if (message_type == 6) {
            const ping = try signalr.pingOwned(self.allocator);
            defer self.allocator.free(ping);
            connection.send(ping);
            return;
        }
        if (message_type == 7) return error.ConnectionClose;
        if (message_type != 1 or count < 5) return;
        const header_count = try reader.mapLen();
        for (0..header_count * 2) |_| try reader.skip(0);
        const invocation_id: ?[]const u8 = if (reader.pos < reader.data.len and reader.data[reader.pos] == 0xc0) id: {
            reader.pos += 1;
            break :id null;
        } else try reader.string();
        const target = try reader.string();
        const argument_count = try reader.arrayLen();
        connection.invocation_mutex.lockUncancelable(self.io);
        if (!self.isEnabled() or !connection.alive.load(.acquire) or !connection.accepting_invocations.load(.acquire)) {
            connection.invocation_mutex.unlock(self.io);
            return error.ConnectionClose;
        }
        const invocation_result = self.handleInvocation(connection, invocation_id, target, argument_count, &reader);
        connection.invocation_mutex.unlock(self.io);
        invocation_result catch |err| {
            std.log.warn("event=lazer_spectator_invocation_failed user_id={d} target={s} error={t}", .{ connection.user_id, target, err });
            if (invocation_id) |id| {
                const frame = signalr.completionErrorOwned(self.allocator, id, "spectator request was not accepted") catch return;
                defer self.allocator.free(frame);
                connection.send(frame);
            } else return err;
        };
    }

    fn finishVoid(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
        const id = invocation_id orelse return;
        const frame = try signalr.completionVoidOwned(self.allocator, id);
        defer self.allocator.free(frame);
        connection.send(frame);
    }

    fn handleInvocation(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, target: []const u8, argument_count: usize, reader: *signalr.MessagePackReader) !void {
        if (!self.isEnabled()) return error.ConnectionClose;
        if (std.mem.eql(u8, target, "BeginPlaySessionV2")) {
            if (argument_count != 2) return error.InvalidSpectatorArguments;
            const arguments = try tokenPayloadArguments(reader);
            return self.beginPlay(connection, invocation_id, arguments.token, arguments.payload);
        }
        if (std.mem.eql(u8, target, "SendFrameDataV2")) {
            if (argument_count != 2) return error.InvalidSpectatorArguments;
            const arguments = try tokenPayloadArguments(reader);
            return self.sendFrames(connection, invocation_id, arguments.token, arguments.payload);
        }
        if (std.mem.eql(u8, target, "EndPlaySessionV2")) {
            if (argument_count != 2) return error.InvalidSpectatorArguments;
            const arguments = try tokenFinalStateArguments(reader);
            return self.endPlay(connection, invocation_id, arguments.token, arguments.final_state);
        }
        if (std.mem.eql(u8, target, "StartWatchingUser")) {
            if (argument_count != 1) return error.InvalidSpectatorArguments;
            return self.startWatching(connection, invocation_id, try castUserId(try reader.integer()));
        }
        if (std.mem.eql(u8, target, "EndWatchingUser")) {
            if (argument_count != 1) return error.InvalidSpectatorArguments;
            return self.endWatching(connection, invocation_id, try castUserId(try reader.integer()));
        }
        return error.UnsupportedSpectatorInvocation;
    }

    fn beginPlay(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, token: ?i64, raw_state: []const u8) !void {
        const play = try parseState(raw_state, token);
        const store = self.store orelse return error.SpectatorStoreUnavailable;
        if ((try store.beatmapSelectionById(play.beatmap_id)) == null) return error.SpectatorBeatmapNotFound;
        var watchers: [max_connections]*Connection = undefined;
        var watcher_count: usize = 0;
        self.mutex.lockUncancelable(self.io);
        if (self.connectionByUserLocked(connection.user_id) != connection or connection.active != null) {
            self.mutex.unlock(self.io);
            return error.SpectatorPlayAlreadyActive;
        }
        connection.active = play;
        watcher_count = self.watchersLocked(connection.user_id, &watchers);
        self.mutex.unlock(self.io);
        defer releaseConnections(watchers[0..watcher_count]);

        const began = try eventStateOwned(self.allocator, "UserBeganPlaying", connection.user_id, play, 1);
        defer self.allocator.free(began);
        sendConnections(watchers[0..watcher_count], began);
        if (watcher_count != 0) {
            var users: [max_connections]SpectatorUser = undefined;
            for (watchers[0..watcher_count], 0..) |watcher, index| users[index] = .{ .id = watcher.user_id, .name = watcher.user_name };
            const watching = try eventWatchersOwned(self.allocator, users[0..watcher_count]);
            defer self.allocator.free(watching);
            connection.send(watching);
        }
        try self.finishVoid(connection, invocation_id);
        std.log.info("event=lazer_spectator_play_started user_id={d} beatmap_id={d} ruleset_id={d} watchers={d}", .{ connection.user_id, play.beatmap_id, play.ruleset_id, watcher_count });
    }

    fn sendFrames(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, token: ?i64, bundle: []const u8) !void {
        try validateFrameBundle(bundle);
        var watchers: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const active = connection.active orelse {
            self.mutex.unlock(self.io);
            return error.SpectatorPlayNotActive;
        };
        if (self.connectionByUserLocked(connection.user_id) != connection or !tokensEqual(active.score_token, token)) {
            self.mutex.unlock(self.io);
            return error.SpectatorScoreTokenMismatch;
        }
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        if (connection.frame_window_second != now) {
            connection.frame_window_second = now;
            connection.frame_bundle_count = 0;
        }
        if (connection.frame_bundle_count >= max_frame_bundles_per_second) {
            self.mutex.unlock(self.io);
            return error.SpectatorFrameRateExceeded;
        }
        connection.frame_bundle_count += 1;
        const watcher_count = self.watchersLocked(connection.user_id, &watchers);
        self.mutex.unlock(self.io);
        defer releaseConnections(watchers[0..watcher_count]);
        const event = try eventRawOwned(self.allocator, "UserSentFrames", connection.user_id, bundle);
        defer self.allocator.free(event);
        sendConnections(watchers[0..watcher_count], event);
        try self.finishVoid(connection, invocation_id);
    }

    fn endPlay(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, token: ?i64, final_state: i64) !void {
        if (final_state < 3 or final_state > 5) return error.InvalidSpectatorFinalState;
        var watchers: [max_connections]*Connection = undefined;
        self.mutex.lockUncancelable(self.io);
        const active = connection.active orelse {
            self.mutex.unlock(self.io);
            return error.SpectatorPlayNotActive;
        };
        if (self.connectionByUserLocked(connection.user_id) != connection or !tokensEqual(active.score_token, token)) {
            self.mutex.unlock(self.io);
            return error.SpectatorScoreTokenMismatch;
        }
        connection.active = null;
        const watcher_count = self.watchersLocked(connection.user_id, &watchers);
        self.mutex.unlock(self.io);
        defer releaseConnections(watchers[0..watcher_count]);

        const finished = try eventStateOwned(self.allocator, "UserFinishedPlaying", connection.user_id, active, @intCast(final_state));
        defer self.allocator.free(finished);
        sendConnections(watchers[0..watcher_count], finished);
        try self.finishVoid(connection, invocation_id);
        if (active.processed_score_id) |score_id| {
            const processed = try eventScoreOwned(self.allocator, connection.user_id, score_id);
            defer self.allocator.free(processed);
            connection.send(processed);
            sendConnections(watchers[0..watcher_count], processed);
        }
        std.log.info("event=lazer_spectator_play_finished user_id={d} state={d} watchers={d}", .{ connection.user_id, final_state, watcher_count });
    }

    fn startWatching(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, user_id: i32) !void {
        const self_watch = user_id == connection.user_id;
        const store = self.store orelse return error.SpectatorStoreUnavailable;
        const target_user = (try store.userById(self.allocator, user_id)) orelse return error.SpectatorUserNotFound;
        defer self.allocator.free(target_user.name);
        defer self.allocator.free(target_user.safe_name);
        if (target_user.restricted) return error.SpectatorUserNotFound;
        var host: ?*Connection = null;
        var active: ?ActivePlay = null;
        self.mutex.lockUncancelable(self.io);
        if (self.connectionByUserLocked(connection.user_id) != connection) {
            self.mutex.unlock(self.io);
            return error.StaleSpectatorConnection;
        }
        const added = connection.subscribe(user_id) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        if (added) if (self.connectionByUserLocked(user_id)) |current| {
            current.retain();
            host = current;
            active = current.active;
        };
        self.mutex.unlock(self.io);
        defer if (host) |current| current.release();
        if (added) {
            if (active) |play| {
                const began = try eventStateOwned(self.allocator, "UserBeganPlaying", user_id, play, 1);
                defer self.allocator.free(began);
                connection.send(began);
            }
            if (host) |current| if (!self_watch) {
                const watcher = SpectatorUser{ .id = connection.user_id, .name = connection.user_name };
                const watching = try eventWatchersOwned(self.allocator, &.{watcher});
                defer self.allocator.free(watching);
                current.send(watching);
            };
        }
        try self.finishVoid(connection, invocation_id);
        if (added) std.log.info("event=lazer_spectator_watch_started user_id={d} target_id={d}", .{ connection.user_id, user_id });
    }

    fn endWatching(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, user_id: i32) !void {
        var host: ?*Connection = null;
        self.mutex.lockUncancelable(self.io);
        if (self.connectionByUserLocked(connection.user_id) != connection) {
            self.mutex.unlock(self.io);
            return error.StaleSpectatorConnection;
        }
        const removed = connection.unsubscribe(user_id);
        if (removed) if (self.connectionByUserLocked(user_id)) |current| {
            current.retain();
            host = current;
        };
        self.mutex.unlock(self.io);
        defer if (host) |current| current.release();
        if (host) |current| {
            const ended = try eventIntegerOwned(self.allocator, "UserEndedWatching", connection.user_id);
            defer self.allocator.free(ended);
            current.send(ended);
        }
        try self.finishVoid(connection, invocation_id);
        if (removed) std.log.info("event=lazer_spectator_watch_ended user_id={d} target_id={d}", .{ connection.user_id, user_id });
    }

    pub fn scoreProcessed(self: *Manager, user_id: i32, score_id: i64) void {
        if (user_id <= 0 or score_id <= 0) return;
        var recipients: [max_connections + 1]*Connection = undefined;
        var count: usize = 0;
        self.mutex.lockUncancelable(self.io);
        if (self.connectionByUserLocked(user_id)) |connection| {
            if (connection.active) |*active| {
                active.processed_score_id = score_id;
                self.mutex.unlock(self.io);
                return;
            }
            connection.retain();
            recipients[count] = connection;
            count += 1;
        }
        var watchers: [max_connections]*Connection = undefined;
        const watcher_count = self.watchersLocked(user_id, &watchers);
        for (watchers[0..watcher_count]) |watcher| {
            recipients[count] = watcher;
            count += 1;
        }
        self.mutex.unlock(self.io);
        defer releaseConnections(recipients[0..count]);
        const event = eventScoreOwned(self.allocator, user_id, score_id) catch return;
        defer self.allocator.free(event);
        sendConnections(recipients[0..count], event);
    }
};

const TokenPayloadArguments = struct {
    token: ?i64,
    payload: []const u8,
};

fn nextValueIsArray(reader: *const signalr.MessagePackReader) bool {
    if (reader.pos >= reader.data.len) return false;
    const tag = reader.data[reader.pos];
    return (tag >= 0x90 and tag <= 0x9f) or tag == 0xdc or tag == 0xdd;
}

fn tokenPayloadArguments(reader: *signalr.MessagePackReader) !TokenPayloadArguments {
    // Some shipped lazer builds used the pre-final V2 argument order. The payload is
    // unambiguously an array, so accepting both shapes does not loosen validation.
    if (nextValueIsArray(reader)) {
        const payload = try reader.raw();
        return .{ .token = try reader.nullableInteger(), .payload = payload };
    }
    return .{ .token = try reader.nullableInteger(), .payload = try reader.raw() };
}

const TokenFinalStateArguments = struct {
    token: ?i64,
    final_state: i64,
};

fn tokenFinalStateArguments(reader: *signalr.MessagePackReader) !TokenFinalStateArguments {
    const first = try reader.nullableInteger();
    const second = try reader.nullableInteger();
    if (second == null) {
        const final_state = first orelse return error.InvalidSpectatorArguments;
        if (final_state < 3 or final_state > 5) return error.InvalidSpectatorArguments;
        return .{ .token = null, .final_state = final_state };
    }
    if (first) |value| {
        if (value >= 3 and value <= 5 and (second.? < 3 or second.? > 5)) {
            return .{ .token = second, .final_state = value };
        }
    }
    return .{ .token = first, .final_state = second.? };
}

fn castUserId(value: i64) !i32 {
    const id = std.math.cast(i32, value) orelse return error.InvalidSpectatorUser;
    return if (id > 0) id else error.InvalidSpectatorUser;
}

fn tokensEqual(left: ?i64, right: ?i64) bool {
    if (left == null or right == null) return left == null and right == null;
    return left.? == right.?;
}

fn parseState(raw: []const u8, score_token: ?i64) !ActivePlay {
    if (raw.len == 0 or raw.len > max_state_value * 2) return error.SpectatorPayloadTooLarge;
    if (score_token) |token| if (token <= 0) return error.InvalidSpectatorScoreToken;
    var reader: signalr.MessagePackReader = .{ .data = raw };
    if (try reader.arrayLen() != 5) return error.InvalidSpectatorState;
    const beatmap_value = (try reader.nullableInteger()) orelse return error.InvalidSpectatorBeatmap;
    const ruleset_value = (try reader.nullableInteger()) orelse return error.InvalidSpectatorRuleset;
    const beatmap_id = std.math.cast(i32, beatmap_value) orelse return error.InvalidSpectatorBeatmap;
    const ruleset_id = std.math.cast(u8, ruleset_value) orelse return error.InvalidSpectatorRuleset;
    if (beatmap_id <= 0) return error.InvalidSpectatorBeatmap;
    if (ruleset_id > 3) return error.InvalidSpectatorRuleset;
    const mods = try reader.raw();
    try validateArray(mods, 64);
    if (try reader.integer() != 1) return error.InvalidSpectatorState;
    const maximum_statistics = try reader.raw();
    try validateMap(maximum_statistics, 64);
    if (reader.pos != raw.len or mods.len > max_state_value or maximum_statistics.len > max_state_value) return error.InvalidSpectatorState;
    var play: ActivePlay = .{ .score_token = score_token, .beatmap_id = beatmap_id, .ruleset_id = ruleset_id, .mods = .{}, .maximum_statistics = .{} };
    try play.mods.set(mods);
    try play.maximum_statistics.set(maximum_statistics);
    return play;
}

fn validateArray(raw: []const u8, maximum: usize) !void {
    var reader: signalr.MessagePackReader = .{ .data = raw };
    const count = try reader.arrayLen();
    if (count > maximum) return error.SpectatorPayloadTooLarge;
    for (0..count) |_| try reader.skip(0);
    if (reader.pos != raw.len) return error.InvalidSpectatorPayload;
}

fn validateMap(raw: []const u8, maximum: usize) !void {
    var reader: signalr.MessagePackReader = .{ .data = raw };
    const count = try reader.mapLen();
    if (count > maximum) return error.SpectatorPayloadTooLarge;
    for (0..count * 2) |_| try reader.skip(0);
    if (reader.pos != raw.len) return error.InvalidSpectatorPayload;
}

fn validateFrameBundle(raw: []const u8) !void {
    if (raw.len == 0 or raw.len > max_hub_message) return error.SpectatorPayloadTooLarge;
    var reader: signalr.MessagePackReader = .{ .data = raw };
    if (try reader.arrayLen() != 2) return error.InvalidSpectatorFrameBundle;
    const header = try reader.raw();
    var header_reader: signalr.MessagePackReader = .{ .data = header };
    if (try header_reader.arrayLen() != 10) return error.InvalidSpectatorFrameHeader;
    for (0..10) |_| try header_reader.skip(0);
    if (header_reader.pos != header.len) return error.InvalidSpectatorFrameHeader;
    const frames = try reader.raw();
    var frame_reader: signalr.MessagePackReader = .{ .data = frames };
    const count = try frame_reader.arrayLen();
    if (count > max_frames_per_bundle) return error.SpectatorFrameLimit;
    for (0..count) |_| {
        const frame = try frame_reader.raw();
        var value_reader: signalr.MessagePackReader = .{ .data = frame };
        if (try value_reader.arrayLen() != 4) return error.InvalidSpectatorReplayFrame;
        for (0..4) |_| try value_reader.skip(0);
        if (value_reader.pos != frame.len) return error.InvalidSpectatorReplayFrame;
    }
    if (frame_reader.pos != frames.len or reader.pos != raw.len) return error.InvalidSpectatorFrameBundle;
}

fn sendConnections(connections: []const *Connection, frame: []const u8) void {
    for (connections) |connection| connection.send(frame);
}

fn releaseConnections(connections: []const *Connection) void {
    for (connections) |connection| connection.release();
}

fn frameOwned(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    if (body.len == 0 or body.len > max_hub_message) return error.SpectatorPayloadTooLarge;
    var prefix: [5]u8 = undefined;
    var remaining = body.len;
    var prefix_len: usize = 0;
    while (true) {
        var byte_value: u8 = @intCast(remaining & 0x7f);
        remaining >>= 7;
        if (remaining != 0) byte_value |= 0x80;
        prefix[prefix_len] = byte_value;
        prefix_len += 1;
        if (remaining == 0) break;
    }
    const output = try allocator.alloc(u8, prefix_len + body.len);
    @memcpy(output[0..prefix_len], prefix[0..prefix_len]);
    @memcpy(output[prefix_len..], body);
    return output;
}

fn allocatingFrame(allocator: std.mem.Allocator, output: *std.Io.Writer.Allocating) ![]u8 {
    return frameOwned(allocator, output.written());
}

fn eventStateOwned(allocator: std.mem.Allocator, target: []const u8, user_id: i32, play: ActivePlay, state: u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: signalr.MessagePackWriter = .{ .writer = &output.writer };
    try signalr.beginEvent(pack, target, 2);
    try pack.integer(user_id);
    try pack.array(5);
    try pack.integer(play.beatmap_id);
    try pack.integer(play.ruleset_id);
    try pack.raw(play.mods.slice());
    try pack.integer(state);
    try pack.raw(play.maximum_statistics.slice());
    try signalr.endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventRawOwned(allocator: std.mem.Allocator, target: []const u8, user_id: i32, raw: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: signalr.MessagePackWriter = .{ .writer = &output.writer };
    try signalr.beginEvent(pack, target, 2);
    try pack.integer(user_id);
    try pack.raw(raw);
    try signalr.endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventIntegerOwned(allocator: std.mem.Allocator, target: []const u8, value: i64) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: signalr.MessagePackWriter = .{ .writer = &output.writer };
    try signalr.beginEvent(pack, target, 1);
    try pack.integer(value);
    try signalr.endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventScoreOwned(allocator: std.mem.Allocator, user_id: i32, score_id: i64) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: signalr.MessagePackWriter = .{ .writer = &output.writer };
    try signalr.beginEvent(pack, "UserScoreProcessed", 2);
    try pack.integer(user_id);
    try pack.integer(score_id);
    try signalr.endEvent(pack);
    return allocatingFrame(allocator, &output);
}

fn eventWatchersOwned(allocator: std.mem.Allocator, users: []const SpectatorUser) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: signalr.MessagePackWriter = .{ .writer = &output.writer };
    try signalr.beginEvent(pack, "UserStartedWatching", 1);
    try pack.array(users.len);
    for (users) |user| {
        try pack.array(2);
        try pack.integer(user.id);
        try pack.string(user.name.slice());
    }
    try signalr.endEvent(pack);
    return allocatingFrame(allocator, &output);
}

test "lazer spectator state requires an online map and a playing legacy ruleset" {
    const valid = [_]u8{ 0x95, 75, 0, 0x90, 1, 0x80 };
    const state = try parseState(&valid, 42);
    try std.testing.expectEqual(@as(i32, 75), state.beatmap_id);
    try std.testing.expectEqual(@as(u8, 0), state.ruleset_id);
    try std.testing.expectEqual(@as(?i64, 42), state.score_token);
    const offline = [_]u8{ 0x95, 0xc0, 0, 0x90, 1, 0x80 };
    try std.testing.expectError(error.InvalidSpectatorBeatmap, parseState(&offline, null));
    const idle = [_]u8{ 0x95, 75, 0, 0x90, 0, 0x80 };
    try std.testing.expectError(error.InvalidSpectatorState, parseState(&idle, null));
}

test "spectator feature gate drains sessions at the invocation boundary and reopens" {
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
    try std.testing.expectEqual(@as(usize, 1), manager.connectionCount());
    connection.subscriptions[0] = 7;
    connection.subscription_count = 1;

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
    connection.invocation_mutex.unlock(std.testing.io);
    thread.join();

    try std.testing.expect(!manager.isEnabled());
    try std.testing.expect(!connection.alive.load(.acquire));
    try std.testing.expect(!connection.accepting_invocations.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), connection.subscription_count);
    try std.testing.expectEqual(@as(usize, 0), manager.connectionCount());
    try std.testing.expectEqual(@as(usize, 0), manager.connections.items.len);
    try std.testing.expectError(error.SpectatorDisabled, manager.connect(user, fake_socket));
    try std.testing.expectError(error.ConnectionClose, manager.handleHubMessage(connection, &.{}));

    manager.setEnabled(true);
    try std.testing.expect(manager.isEnabled());
    const reopened = try manager.connect(user, fake_socket);
    reopened.socket = null;
    try std.testing.expect(reopened.alive.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), manager.connectionCount());
    manager.disconnect(connection);
    manager.disconnect(stale);
    manager.disconnect(reopened);
}

test "cross client spectator disconnect waits for the invocation boundary and clears session state" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const user: domain.User = .{ .id = 4, .name = "takeover", .safe_name = "takeover", .country = .{ 'A', 'U' } };
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const connection = try manager.connect(user, fake_socket);
    connection.socket = null;
    const state_raw = [_]u8{ 0x95, 75, 0, 0x90, 1, 0x80 };
    connection.active = try parseState(&state_raw, 42);
    connection.subscriptions[0] = 7;
    connection.subscription_count = 1;

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
    const thread = try std.Thread.spawn(.{}, Takeover.run, .{&takeover});
    while (!takeover.started.load(.acquire)) std.Thread.yield() catch {};
    while (connection.references.load(.acquire) == 1) std.Thread.yield() catch {};
    try std.testing.expect(!takeover.done.load(.acquire));
    // Model the last mutations made by an invocation which was already in
    // progress when the cross-client takeover began.
    connection.subscriptions[1] = 8;
    connection.subscription_count = 2;
    connection.active = try parseState(&state_raw, 84);
    connection.invocation_mutex.unlock(std.testing.io);
    thread.join();

    try std.testing.expect(takeover.disconnected);
    try std.testing.expect(!connection.alive.load(.acquire));
    try std.testing.expect(!connection.accepting_invocations.load(.acquire));
    try std.testing.expectEqual(@as(?ActivePlay, null), connection.active);
    try std.testing.expectEqual(@as(usize, 0), connection.subscription_count);
    try std.testing.expectEqualSlices(i32, &([_]i32{0} ** max_subscriptions), &connection.subscriptions);
    try std.testing.expectEqual(@as(usize, 0), manager.connections.items.len);
    try std.testing.expect(!manager.disconnectUser(user.id));
    try std.testing.expectError(error.ConnectionClose, manager.handleHubMessage(connection, &.{}));
    // A real websocket handler owns this final reference until its blocked
    // read observes the close frame.
    manager.disconnect(connection);
}

test "spectator replacement retires the old session before publishing the new one" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const user: domain.User = .{ .id = 4, .name = "replacement", .safe_name = "replacement", .country = .{ 'A', 'U' } };
    const fake_socket: *std.http.Server.WebSocket = @ptrFromInt(@alignOf(std.http.Server.WebSocket));
    const old = try manager.connect(user, fake_socket);
    old.socket = null;
    const state_raw = [_]u8{ 0x95, 75, 0, 0x90, 1, 0x80 };
    old.active = try parseState(&state_raw, 42);
    old.subscriptions[0] = 7;
    old.subscription_count = 1;

    const Replacement = struct {
        manager: *Manager,
        user: domain.User,
        socket: *std.http.Server.WebSocket,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        connection: ?*Connection = null,
        failure: ?anyerror = null,

        fn run(context: *@This()) void {
            context.started.store(true, .release);
            context.connection = context.manager.connect(context.user, context.socket) catch |err| {
                context.failure = err;
                context.done.store(true, .release);
                return;
            };
            context.done.store(true, .release);
        }
    };
    old.invocation_mutex.lockUncancelable(std.testing.io);
    var replacement: Replacement = .{ .manager = &manager, .user = user, .socket = fake_socket };
    const thread = try std.Thread.spawn(.{}, Replacement.run, .{&replacement});
    while (!replacement.started.load(.acquire)) std.Thread.yield() catch {};
    while (old.references.load(.acquire) == 1) std.Thread.yield() catch {};
    try std.testing.expect(!replacement.done.load(.acquire));
    old.subscriptions[1] = 8;
    old.subscription_count = 2;
    old.active = try parseState(&state_raw, 84);
    old.invocation_mutex.unlock(std.testing.io);
    thread.join();

    try std.testing.expect(replacement.failure == null);
    const current = replacement.connection.?;
    current.socket = null;
    try std.testing.expect(!old.alive.load(.acquire));
    try std.testing.expect(!old.accepting_invocations.load(.acquire));
    try std.testing.expectEqual(@as(?ActivePlay, null), old.active);
    try std.testing.expectEqual(@as(usize, 0), old.subscription_count);
    try std.testing.expectEqualSlices(i32, &([_]i32{0} ** max_subscriptions), &old.subscriptions);
    try std.testing.expectEqual(@as(usize, 1), manager.connections.items.len);
    try std.testing.expect(manager.connections.items[0] == current);
    try std.testing.expectError(error.ConnectionClose, manager.handleHubMessage(old, &.{}));
    // Deferred cleanup for the replaced socket must not rediscover the old
    // subscriptions and emit stale UserEndedWatching events.
    manager.disconnect(old);
    try std.testing.expectEqual(@as(usize, 1), manager.connections.items.len);
    try std.testing.expect(manager.connections.items[0] == current);
    manager.disconnect(current);
}

test "lazer spectator v2 accepts canonical and shipped payload-first argument order" {
    var canonical: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer canonical.deinit();
    const canonical_pack: signalr.MessagePackWriter = .{ .writer = &canonical.writer };
    try canonical_pack.integer(42);
    try canonical_pack.array(5);
    try canonical_pack.integer(75);
    try canonical_pack.integer(0);
    try canonical_pack.array(0);
    try canonical_pack.integer(1);
    try canonical_pack.map(0);
    var canonical_reader: signalr.MessagePackReader = .{ .data = canonical.written() };
    const canonical_arguments = try tokenPayloadArguments(&canonical_reader);
    try std.testing.expectEqual(@as(?i64, 42), canonical_arguments.token);
    try std.testing.expectEqual(@as(i32, 75), (try parseState(canonical_arguments.payload, canonical_arguments.token)).beatmap_id);
    try std.testing.expectEqual(canonical_reader.data.len, canonical_reader.pos);

    var payload_first: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer payload_first.deinit();
    const payload_first_pack: signalr.MessagePackWriter = .{ .writer = &payload_first.writer };
    try payload_first_pack.array(5);
    try payload_first_pack.integer(75);
    try payload_first_pack.integer(0);
    try payload_first_pack.array(0);
    try payload_first_pack.integer(1);
    try payload_first_pack.map(0);
    try payload_first_pack.integer(42);
    var payload_first_reader: signalr.MessagePackReader = .{ .data = payload_first.written() };
    const payload_first_arguments = try tokenPayloadArguments(&payload_first_reader);
    try std.testing.expectEqual(@as(?i64, 42), payload_first_arguments.token);
    try std.testing.expectEqual(@as(i32, 75), (try parseState(payload_first_arguments.payload, payload_first_arguments.token)).beatmap_id);
    try std.testing.expectEqual(payload_first_reader.data.len, payload_first_reader.pos);

    const canonical_end = [_]u8{ 42, 3 };
    var canonical_end_reader: signalr.MessagePackReader = .{ .data = &canonical_end };
    const canonical_end_arguments = try tokenFinalStateArguments(&canonical_end_reader);
    try std.testing.expectEqual(@as(?i64, 42), canonical_end_arguments.token);
    try std.testing.expectEqual(@as(i64, 3), canonical_end_arguments.final_state);

    const state_first_end = [_]u8{ 3, 42 };
    var state_first_end_reader: signalr.MessagePackReader = .{ .data = &state_first_end };
    const state_first_end_arguments = try tokenFinalStateArguments(&state_first_end_reader);
    try std.testing.expectEqual(@as(?i64, 42), state_first_end_arguments.token);
    try std.testing.expectEqual(@as(i64, 3), state_first_end_arguments.final_state);
}

test "lazer spectator frame bundles are exact and bounded" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const pack: signalr.MessagePackWriter = .{ .writer = &output.writer };
    try pack.array(2);
    try pack.array(10);
    for (0..10) |_| try pack.nil();
    try pack.array(1);
    try pack.array(4);
    try pack.float64(100);
    try pack.nil();
    try pack.nil();
    try pack.integer(0);
    try validateFrameBundle(output.written());

    var too_many: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer too_many.deinit();
    const many: signalr.MessagePackWriter = .{ .writer = &too_many.writer };
    try many.array(2);
    try many.array(10);
    for (0..10) |_| try many.nil();
    try many.array(max_frames_per_bundle + 1);
    for (0..max_frames_per_bundle + 1) |_| {
        try many.array(4);
        for (0..4) |_| try many.nil();
    }
    try std.testing.expectError(error.SpectatorFrameLimit, validateFrameBundle(too_many.written()));
}

test "lazer spectator events preserve the official state and watcher shapes" {
    const state_raw = [_]u8{ 0x95, 75, 0, 0x90, 1, 0x80 };
    const state = try parseState(&state_raw, null);
    const frame = try eventStateOwned(std.testing.allocator, "UserBeganPlaying", 4, state, 1);
    defer std.testing.allocator.free(frame);
    var prefix: usize = 0;
    while (frame[prefix] & 0x80 != 0) prefix += 1;
    prefix += 1;
    var reader: signalr.MessagePackReader = .{ .data = frame[prefix..] };
    try std.testing.expectEqual(@as(usize, 6), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 1), try reader.integer());
    try std.testing.expectEqual(@as(usize, 0), try reader.mapLen());
    _ = try reader.raw();
    try std.testing.expectEqualStrings("UserBeganPlaying", try reader.string());
    try std.testing.expectEqual(@as(usize, 2), try reader.arrayLen());
    try std.testing.expectEqual(@as(i64, 4), try reader.integer());
    try std.testing.expectEqual(@as(usize, 5), try reader.arrayLen());
}
