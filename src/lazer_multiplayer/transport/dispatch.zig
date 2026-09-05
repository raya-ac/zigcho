const std = @import("std");
const domain = @import("../../domain.zig");
const signalr = @import("../../lazer_multiplayer/signalr.zig");
const MessagePackReader = @import("../../lazer_multiplayer.zig").MessagePackReader;
const completionVoidOwned = @import("../../lazer_multiplayer.zig").completionVoidOwned;
const completionErrorOwned = @import("../../lazer_multiplayer.zig").completionErrorOwned;
const pingOwned = @import("../../lazer_multiplayer.zig").pingOwned;
const validSignalRHandshake = @import("../../lazer_multiplayer.zig").validSignalRHandshake;
const checkedReaderInteger = @import("../../lazer_multiplayer.zig").checkedReaderInteger;
const checkedNullableInteger = @import("../../lazer_multiplayer.zig").checkedNullableInteger;
const Connection = @import("model.zig").Connection;
const Manager = @import("../../lazer_multiplayer.zig").Manager;

pub fn serve(self: *Manager, user: domain.User, socket: *std.http.Server.WebSocket) !void {
    const handshake = try socket.readSmallMessage();
    if ((handshake.opcode != .text and handshake.opcode != .binary) or !validSignalRHandshake(self.allocator, handshake.data)) return error.InvalidSignalRHandshake;
    // SignalR's handshake body is JSON even when the selected hub protocol
    // uses binary transfer. Match the negotiated WebSocket transfer format
    // instead of assuming the JSON bytes arrived in a text frame.
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

pub fn handleFrames(self: *Manager, connection: *Connection, data: []const u8) !void {
    var frames: signalr.FrameReader = .{ .data = data };
    while (try frames.next()) |payload| try self.handleHubMessage(connection, payload);
}

pub fn handleHubMessage(self: *Manager, connection: *Connection, payload: []const u8) !void {
    if (!self.isEnabled() or !connection.alive.load(.acquire) or !connection.accepting_invocations.load(.acquire)) return error.ConnectionClose;
    var reader: MessagePackReader = .{ .data = payload };
    const count = try reader.arrayLen();
    if (count == 0) return error.InvalidSignalRMessage;
    const message_type = try reader.integer();
    if (message_type == 6) {
        const ping = try pingOwned(self.allocator);
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
    // The connection may have been replaced while this frame was parsed
    // and waiting for the invocation gate, or multiplayer may have crossed
    // its disable/shutdown boundary in the meantime.
    if (!self.isEnabled() or !connection.alive.load(.acquire) or !connection.accepting_invocations.load(.acquire)) {
        connection.invocation_mutex.unlock(self.io);
        return error.ConnectionClose;
    }
    const invocation_result = self.handleInvocation(connection, invocation_id, target, argument_count, &reader);
    connection.invocation_mutex.unlock(self.io);
    invocation_result catch |err| {
        std.log.warn("event=lazer_multiplayer_invocation_failed user_id={d} target={s} error={t}", .{ connection.user_id, target, err });
        if (invocation_id) |id| {
            const frame = completionErrorOwned(self.allocator, id, "multiplayer request was not accepted") catch return;
            defer self.allocator.free(frame);
            connection.send(frame);
        }
    };
}

pub fn finishVoid(self: *Manager, connection: *Connection, invocation_id: ?[]const u8) !void {
    const id = invocation_id orelse return;
    const frame = try completionVoidOwned(self.allocator, id);
    defer self.allocator.free(frame);
    connection.send(frame);
}

pub fn handleInvocation(self: *Manager, connection: *Connection, invocation_id: ?[]const u8, target: []const u8, argument_count: usize, reader: *MessagePackReader) !void {
    if (std.mem.eql(u8, target, "CreateRoom")) {
        if (argument_count != 1) return error.InvalidMultiplayerArguments;
        const room_value = try reader.raw();
        return self.createRoom(connection, invocation_id, room_value);
    }
    if (std.mem.eql(u8, target, "JoinRoom") or std.mem.eql(u8, target, "JoinRoomWithPassword")) {
        if (argument_count < 1 or argument_count > 2) return error.InvalidMultiplayerArguments;
        const room_id = try reader.integer();
        const password = if (argument_count == 2) try reader.string() else "";
        return self.joinRoom(connection, invocation_id, room_id, password);
    }
    if (std.mem.eql(u8, target, "LeaveRoom")) return self.leaveRoom(connection, invocation_id);
    if (std.mem.eql(u8, target, "TransferHost")) {
        if (argument_count != 1) return error.InvalidMultiplayerArguments;
        return self.transferHost(connection, invocation_id, try checkedReaderInteger(i32, reader));
    }
    if (std.mem.eql(u8, target, "KickUser")) {
        if (argument_count != 1) return error.InvalidMultiplayerArguments;
        return self.kickUser(connection, invocation_id, try checkedReaderInteger(i32, reader));
    }
    if (std.mem.eql(u8, target, "ChangeSettings")) {
        if (argument_count != 1) return error.InvalidMultiplayerArguments;
        return self.changeSettings(connection, invocation_id, try reader.raw());
    }
    if (std.mem.eql(u8, target, "ChangeState")) {
        if (argument_count != 1) return error.InvalidMultiplayerArguments;
        return self.changeState(connection, invocation_id, try checkedReaderInteger(u8, reader));
    }
    if (std.mem.eql(u8, target, "ChangeBeatmapAvailability")) {
        if (argument_count != 1) return error.InvalidMultiplayerArguments;
        return self.changeAvailability(connection, invocation_id, try reader.raw());
    }
    if (std.mem.eql(u8, target, "ChangeUserStyle")) {
        if (argument_count != 2) return error.InvalidMultiplayerArguments;
        const beatmap_id = try reader.nullableInteger();
        const ruleset_id = try reader.nullableInteger();
        return self.changeStyle(connection, invocation_id, try checkedNullableInteger(i32, beatmap_id), try checkedNullableInteger(i32, ruleset_id));
    }
    if (std.mem.eql(u8, target, "ChangeUserMods")) {
        if (argument_count != 1) return error.InvalidMultiplayerArguments;
        return self.changeMods(connection, invocation_id, try reader.raw());
    }
    if (std.mem.eql(u8, target, "StartMatch")) return self.startMatch(connection, invocation_id);
    if (std.mem.eql(u8, target, "AbortMatch")) return self.abortMatch(connection, invocation_id);
    if (std.mem.eql(u8, target, "AbortGameplay")) return self.abortGameplay(connection, invocation_id);
    if (std.mem.eql(u8, target, "AddPlaylistItem")) {
        if (argument_count != 1) return error.InvalidMultiplayerArguments;
        return self.addPlaylistItem(connection, invocation_id, try reader.raw());
    }
    if (std.mem.eql(u8, target, "EditPlaylistItem")) {
        if (argument_count != 1) return error.InvalidMultiplayerArguments;
        return self.editPlaylistItem(connection, invocation_id, try reader.raw());
    }
    if (std.mem.eql(u8, target, "RemovePlaylistItem")) {
        if (argument_count != 1) return error.InvalidMultiplayerArguments;
        return self.removePlaylistItem(connection, invocation_id, try reader.integer());
    }
    if (std.mem.eql(u8, target, "VoteToSkipIntro")) return self.voteSkip(connection, invocation_id);
    if (std.mem.eql(u8, target, "InvitePlayer")) {
        if (argument_count != 1) return error.InvalidMultiplayerArguments;
        return self.invitePlayer(connection, invocation_id, try checkedReaderInteger(i32, reader));
    }
    if (std.mem.eql(u8, target, "SendMatchRequest")) {
        if (argument_count != 1) return error.InvalidMultiplayerArguments;
        return self.sendMatchRequest(connection, invocation_id, try reader.raw());
    }
    if (std.mem.eql(u8, target, "GetMatchmakingPools") or std.mem.eql(u8, target, "GetMatchmakingPoolsOfType")) {
        if (argument_count > 1) return error.InvalidMultiplayerArguments;
        const pool_type: u8 = if (argument_count == 1) try checkedReaderInteger(u8, reader) else 0;
        return self.getMatchmakingPools(connection, invocation_id, pool_type);
    }
    if (std.mem.eql(u8, target, "MatchmakingJoinLobby")) {
        if (argument_count != 0) return error.InvalidMultiplayerArguments;
        return self.joinMatchmakingLobby(connection, invocation_id, 1);
    }
    if (std.mem.eql(u8, target, "MatchmakingJoinLobbyWithParams")) {
        if (argument_count != 1) return error.InvalidMultiplayerArguments;
        const request = try reader.raw();
        var request_reader: MessagePackReader = .{ .data = request };
        if (try request_reader.arrayLen() < 1) return error.InvalidMultiplayerArguments;
        return self.joinMatchmakingLobby(connection, invocation_id, try checkedReaderInteger(i32, &request_reader));
    }
    if (std.mem.eql(u8, target, "MatchmakingLeaveLobby")) {
        if (argument_count != 0) return error.InvalidMultiplayerArguments;
        return self.leaveMatchmakingLobby(connection, invocation_id);
    }
    if (std.mem.eql(u8, target, "MatchmakingJoinQueue")) {
        if (argument_count != 1) return error.InvalidMultiplayerArguments;
        return self.joinMatchmakingQueue(connection, invocation_id, try checkedReaderInteger(i32, reader));
    }
    if (std.mem.eql(u8, target, "MatchmakingLeaveQueue")) {
        if (argument_count != 0) return error.InvalidMultiplayerArguments;
        return self.leaveMatchmakingQueue(connection, invocation_id, true);
    }
    if (std.mem.eql(u8, target, "MatchmakingAcceptInvitation")) {
        if (argument_count != 0) return error.InvalidMultiplayerArguments;
        return self.acceptMatchmakingInvitation(connection, invocation_id);
    }
    if (std.mem.eql(u8, target, "MatchmakingIssueDuel")) {
        if (argument_count != 1) return error.InvalidMultiplayerArguments;
        const request = try reader.raw();
        var request_reader: MessagePackReader = .{ .data = request };
        if (try request_reader.arrayLen() != 2) return error.InvalidMultiplayerArguments;
        return self.issueMatchmakingDuel(
            connection,
            invocation_id,
            try checkedReaderInteger(i32, &request_reader),
            try checkedReaderInteger(i32, &request_reader),
        );
    }
    if (std.mem.eql(u8, target, "MatchmakingAcceptDuel")) {
        if (argument_count != 1) return error.InvalidMultiplayerArguments;
        const request = try reader.raw();
        var request_reader: MessagePackReader = .{ .data = request };
        if (try request_reader.arrayLen() != 1) return error.InvalidMultiplayerArguments;
        return self.acceptMatchmakingDuel(connection, invocation_id, try request_reader.string());
    }
    if (std.mem.eql(u8, target, "MatchmakingDeclineInvitation")) {
        if (argument_count != 0) return error.InvalidMultiplayerArguments;
        return self.declineMatchmakingInvitation(connection, invocation_id);
    }
    if (std.mem.eql(u8, target, "MatchmakingToggleSelection")) {
        if (argument_count != 1) return error.InvalidMultiplayerArguments;
        return self.toggleMatchmakingSelection(connection, invocation_id, try reader.integer());
    }
    if (std.mem.eql(u8, target, "DiscardCards")) {
        if (argument_count != 1) return error.InvalidMultiplayerArguments;
        return self.discardRankedCards(connection, invocation_id, try reader.raw());
    }
    if (std.mem.eql(u8, target, "PlayCard")) {
        if (argument_count != 1) return error.InvalidMultiplayerArguments;
        return self.playRankedCard(connection, invocation_id, try reader.raw());
    }
    for (0..argument_count) |_| try reader.skip(0);
    return error.UnsupportedMultiplayerMethod;
}
