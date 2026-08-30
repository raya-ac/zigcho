const d = @import("../deps.zig");
const std = d.std;
const domain = d.domain;
const storage = d.storage;
const irc = d.irc;
const lazer = d.lazer;
const App = @import("../app.zig").App;
const support = @import("../support.zig");
const freeUser = support.freeUser;
const randomMessageUuid = support.randomMessageUuid;

const max_irc_clients: u32 = 512;

const IrcConnection = struct {
    app: *App,
    stream: std.Io.net.Stream,
    io: std.Io,
    writer: std.Io.net.Stream.Writer = undefined,
    send_buffer: [4096]u8 = undefined,
    write_mutex: std.Io.Mutex = .init,
    alive: std.atomic.Value(bool) = .init(true),
    registered: std.atomic.Value(bool) = .init(false),
    joined: std.atomic.Value(u8) = .init(0),
    user: ?domain.User = null,
    nick: [32]u8 = undefined,
    nick_len: u8 = 0,
    password: [128]u8 = [_]u8{0} ** 128,
    password_len: u8 = 0,
    user_seen: bool = false,
    cap_pending: bool = false,
    authentication_attempts: u8 = 0,
    cursor: i64 = 0,
    connected_at: i64,
    last_ping_at: i64,

    fn init(self: *IrcConnection, app: *App, stream: std.Io.net.Stream, io: std.Io) void {
        const now = std.Io.Clock.real.now(io).toSeconds();
        self.* = .{
            .app = app,
            .stream = stream,
            .io = io,
            .connected_at = now,
            .last_ping_at = now,
        };
        self.writer = stream.writer(io, &self.send_buffer);
    }

    fn deinit(self: *IrcConnection) void {
        @memset(&self.password, 0);
        if (self.user) |user| freeUser(self.app.allocator, user);
        self.* = undefined;
    }

    fn currentNick(self: *const IrcConnection) []const u8 {
        if (self.user) |user| return user.safe_name;
        if (self.nick_len != 0) return self.nick[0..self.nick_len];
        return "*";
    }

    fn close(self: *IrcConnection) void {
        if (!self.alive.swap(false, .acq_rel)) return;
        self.stream.shutdown(self.io, .both) catch {};
    }

    fn sendRaw(self: *IrcConnection, bytes: []const u8) bool {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (!self.alive.load(.acquire)) return false;
        self.writer.interface.writeAll(bytes) catch {
            self.close();
            return false;
        };
        self.writer.interface.flush() catch {
            self.close();
            return false;
        };
        return true;
    }

    fn sendNumeric(self: *IrcConnection, comptime code: []const u8, comptime format: []const u8, args: anytype) void {
        var output: std.Io.Writer.Allocating = .init(self.app.allocator);
        defer output.deinit();
        output.writer.print(":" ++ irc.server_name ++ " " ++ code ++ " {s} ", .{self.currentNick()}) catch return self.close();
        output.writer.print(format, args) catch return self.close();
        output.writer.writeAll("\r\n") catch return self.close();
        _ = self.sendRaw(output.written());
    }

    fn sendServer(self: *IrcConnection, comptime format: []const u8, args: anytype) void {
        var output: std.Io.Writer.Allocating = .init(self.app.allocator);
        defer output.deinit();
        output.writer.print(":" ++ irc.server_name ++ " " ++ format ++ "\r\n", args) catch return self.close();
        _ = self.sendRaw(output.written());
    }

    fn sendLine(self: *IrcConnection, comptime format: []const u8, args: anytype) void {
        var output: std.Io.Writer.Allocating = .init(self.app.allocator);
        defer output.deinit();
        output.writer.print(format ++ "\r\n", args) catch return self.close();
        _ = self.sendRaw(output.written());
    }

    fn sendJoin(self: *IrcConnection, channel: []const u8) void {
        const mask = irc.channelMask(channel) orelse return;
        _ = self.joined.fetchOr(mask, .acq_rel);
        self.sendLine(":{s}!zigcho@kai.ovh JOIN {s}", .{ self.currentNick(), channel });
        const topic = if (std.mem.eql(u8, channel, "#announce")) "server and score updates" else if (std.mem.eql(u8, channel, "#lobby")) "multiplayer lobby" else if (std.mem.eql(u8, channel, "#lazer")) "lazer chat" else "general chat";
        self.sendNumeric("332", "{s} :{s}", .{ channel, topic });
        self.sendNames(channel);
    }

    fn sendNames(self: *IrcConnection, channel: []const u8) void {
        if (irc.channelMask(channel)) |mask| if (self.joined.load(.acquire) & mask == 0) return;
        self.sendNumeric("353", "= {s} :@kai {s}", .{ channel, self.currentNick() });
        self.sendNumeric("366", "{s} :End of /NAMES list", .{channel});
    }

    fn sendChat(self: *IrcConnection, sender: []const u8, target: []const u8, content: []const u8, action: bool) void {
        var remaining = content;
        while (remaining.len != 0) {
            var take = @min(remaining.len, 350);
            while (take > 0 and !std.unicode.utf8ValidateSlice(remaining[0..take])) take -= 1;
            if (take == 0) return;
            var output: std.Io.Writer.Allocating = .init(self.app.allocator);
            defer output.deinit();
            irc.writeMessage(&output.writer, sender, target, remaining[0..take], action) catch return self.close();
            if (!self.sendRaw(output.written())) return;
            remaining = remaining[take..];
        }
    }
};

fn ircJsonInteger(object: std.json.ObjectMap, name: []const u8) ?i64 {
    return switch (object.get(name) orelse return null) {
        .integer => |value| value,
        else => null,
    };
}

fn ircLatestCursor(connection: *IrcConnection) !i64 {
    const user = connection.user orelse return 0;
    const json = try connection.app.store.lazerAllMessagesJson(connection.app.allocator, user.id, 0, 100);
    defer connection.app.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, connection.app.allocator, json, .{});
    defer parsed.deinit();
    const items = switch (parsed.value) {
        .array => |array| array.items,
        else => return error.InvalidChatPayload,
    };
    var cursor: i64 = 0;
    for (items) |item| {
        const object = switch (item) {
            .object => |value| value,
            else => continue,
        };
        cursor = @max(cursor, ircJsonInteger(object, "message_id") orelse 0);
    }
    return cursor;
}

fn ircRegister(connection: *IrcConnection) void {
    if (connection.registered.load(.acquire) or connection.nick_len == 0 or connection.password_len == 0 or !connection.user_seen or connection.cap_pending) return;
    const password = connection.password[0..connection.password_len];
    if (password.len < 8) {
        connection.sendNumeric("464", ":Password incorrect", .{});
        connection.password_len = 0;
        @memset(&connection.password, 0);
        return;
    }
    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(password, &digest, .{});
    const password_md5 = std.fmt.bytesToHex(digest, .lower);
    @memset(&connection.password, 0);
    connection.password_len = 0;
    const user = connection.app.store.authenticate(connection.app.allocator, connection.nick[0..connection.nick_len], &password_md5) catch |err| {
        std.log.warn("event=irc_authentication_failed nick={s} error={t}", .{ connection.nick[0..connection.nick_len], err });
        connection.sendNumeric("464", ":Password incorrect", .{});
        return;
    } orelse {
        connection.authentication_attempts += 1;
        connection.sendNumeric("464", ":Password incorrect", .{});
        if (connection.authentication_attempts >= 3) connection.close();
        return;
    };
    connection.user = user;
    connection.cursor = ircLatestCursor(connection) catch |err| cursor: {
        std.log.warn("event=irc_cursor_prime_failed user_id={d} error={t}", .{ user.id, err });
        break :cursor 0;
    };
    connection.registered.store(true, .release);
    connection.sendNumeric("001", ":Welcome to kai IRC, {s}", .{user.safe_name});
    connection.sendNumeric("002", ":Your host is {s}", .{irc.server_name});
    connection.sendNumeric("003", ":This server is the shared Zigcho chat bridge", .{});
    connection.sendNumeric("004", "{s} zigcho o o", .{irc.server_name});
    connection.sendNumeric("005", "CHANTYPES=# CASEMAPPING=ascii NICKLEN=32 CHANNELLEN=32 TOPICLEN=300 :are supported by this server", .{});
    connection.sendNumeric("375", ":- {s} Message of the Day -", .{irc.server_name});
    connection.sendNumeric("372", ":Stable, lazer, web and IRC share this history.", .{});
    connection.sendNumeric("376", ":End of /MOTD command", .{});
    connection.sendJoin("#osu");
    connection.sendJoin("#announce");
    std.log.info("event=irc_authenticated user_id={d} nick={s}", .{ user.id, user.safe_name });
}

fn ircActionText(value: []const u8) struct { text: []const u8, action: bool } {
    if (value.len >= 9 and value[0] == 0x01 and value[value.len - 1] == 0x01 and std.mem.startsWith(u8, value[1..], "ACTION "))
        return .{ .text = value[8 .. value.len - 1], .action = true };
    return .{ .text = value, .action = false };
}

fn ircHandleMessage(connection: *IrcConnection, command: irc.Command) void {
    const user = connection.user orelse return;
    const target = command.parameter(0) orelse return connection.sendNumeric("411", ":No recipient given", .{});
    const raw = command.parameter(1) orelse return connection.sendNumeric("412", ":No text to send", .{});
    const action = ircActionText(raw);
    const message = std.mem.trim(u8, action.text, " \t\r\n");
    if (message.len == 0 or message.len > 2000 or std.mem.indexOfScalar(u8, message, 0) != null or !std.unicode.utf8ValidateSlice(message)) return connection.sendNumeric("412", ":Invalid message", .{});
    const now = std.Io.Clock.real.now(connection.io).toSeconds();
    if (user.restricted) return connection.sendNumeric("404", "{s} :Restricted accounts cannot chat", .{target});
    if (user.silence_end > now) return connection.sendNumeric("404", "{s} :You are silenced", .{target});

    if (target.len != 0 and target[0] == '#') {
        const channel = irc.canonicalChannel(target) orelse return connection.sendNumeric("403", "{s} :No such channel", .{target});
        const mask = irc.channelMask(channel).?;
        if (connection.joined.load(.acquire) & mask == 0) return connection.sendNumeric("442", "{s} :You're not on that channel", .{channel});
        const uuid = randomMessageUuid(connection.io) catch return connection.sendNumeric("400", ":Message unavailable", .{});
        const written = connection.app.store.recordLazerPublicMessage(connection.app.allocator, user.id, channel, message, action.action, &uuid) catch |err| return switch (err) {
            error.ChannelReadOnly => connection.sendNumeric("404", "{s} :Cannot send to channel", .{channel}),
            error.UnknownChannel => connection.sendNumeric("403", "{s} :No such channel", .{channel}),
            else => connection.sendNumeric("400", ":Message unavailable", .{}),
        };
        defer connection.app.allocator.free(written.json);
        if (written.inserted) connection.app.broadcastLazerChatToStable(user, channel, message) catch |err|
            std.log.warn("event=irc_chat_stable_broadcast_failed user_id={d} channel={s} error={t}", .{ user.id, channel, err });
        return;
    }

    const recipient_value = connection.app.store.userByName(connection.app.allocator, target) catch {
        connection.sendNumeric("400", ":Message unavailable", .{});
        return;
    };
    const recipient = recipient_value orelse {
        connection.sendNumeric("401", "{s} :No such nick", .{target});
        return;
    };
    defer freeUser(connection.app.allocator, recipient);
    if (recipient.id == user.id or recipient.restricted) return connection.sendNumeric("401", "{s} :No such nick", .{target});
    const uuid = randomMessageUuid(connection.io) catch return connection.sendNumeric("400", ":Message unavailable", .{});
    const written = connection.app.store.recordLazerDirectMessage(connection.app.allocator, user.id, recipient.id, message, action.action, &uuid) catch |err| return switch (err) {
        error.DirectMessageBlocked => connection.sendNumeric("404", "{s} :Direct messages are blocked", .{recipient.safe_name}),
        else => connection.sendNumeric("400", ":Message unavailable", .{}),
    };
    defer connection.app.allocator.free(written.json);
    if (written.inserted) {
        if (written.direct_message_id) |message_id| connection.app.deliverDirectMessageToStable(user, recipient.id, message_id, message) catch |err|
            std.log.warn("event=irc_dm_stable_delivery_failed user_id={d} target_id={d} error={t}", .{ user.id, recipient.id, err });
        if (recipient.id == 3) connection.app.recordLazerBotReply(user, message, action.action);
    }
}

fn ircHandleCommand(connection: *IrcConnection, command: irc.Command) bool {
    if (command.is("CAP")) {
        const subcommand = command.parameter(0) orelse "LS";
        if (std.ascii.eqlIgnoreCase(subcommand, "LS")) {
            connection.cap_pending = true;
            connection.sendServer("CAP * LS :", .{});
        } else if (std.ascii.eqlIgnoreCase(subcommand, "REQ")) {
            connection.sendServer("CAP * NAK :{s}", .{command.parameter(1) orelse ""});
        } else if (std.ascii.eqlIgnoreCase(subcommand, "END")) {
            connection.cap_pending = false;
            ircRegister(connection);
        }
        return true;
    }
    if (command.is("PASS")) {
        if (connection.registered.load(.acquire)) {
            connection.sendNumeric("462", ":You may not reregister", .{});
            return true;
        }
        const password = command.parameter(0) orelse {
            connection.sendNumeric("461", "PASS :Not enough parameters", .{});
            return true;
        };
        if (password.len > connection.password.len) {
            connection.sendNumeric("464", ":Password incorrect", .{});
            return true;
        }
        @memset(&connection.password, 0);
        @memcpy(connection.password[0..password.len], password);
        connection.password_len = @intCast(password.len);
        ircRegister(connection);
        return true;
    }
    if (command.is("NICK")) {
        if (connection.registered.load(.acquire)) {
            connection.sendNumeric("433", "{s} :Nickname changes are disabled; it is your account name", .{command.parameter(0) orelse "*"});
            return true;
        }
        const nick = command.parameter(0) orelse {
            connection.sendNumeric("431", ":No nickname given", .{});
            return true;
        };
        if (!irc.validNick(nick)) {
            connection.sendNumeric("432", "{s} :Erroneous nickname", .{nick});
            return true;
        }
        @memcpy(connection.nick[0..nick.len], nick);
        connection.nick_len = @intCast(nick.len);
        ircRegister(connection);
        return true;
    }
    if (command.is("USER")) {
        if (connection.registered.load(.acquire)) {
            connection.sendNumeric("462", ":You may not reregister", .{});
            return true;
        }
        if (command.parameter(0) == null) {
            connection.sendNumeric("461", "USER :Not enough parameters", .{});
            return true;
        }
        connection.user_seen = true;
        ircRegister(connection);
        return true;
    }
    if (command.is("PING")) {
        connection.sendServer("PONG {s} :{s}", .{ irc.server_name, command.parameter(0) orelse irc.server_name });
        return true;
    }
    if (command.is("PONG")) return true;
    if (command.is("QUIT")) {
        connection.sendServer("ERROR :Closing Link: {s}", .{connection.currentNick()});
        return false;
    }
    if (!connection.registered.load(.acquire)) {
        connection.sendNumeric("451", ":You have not registered", .{});
        return true;
    }
    if (command.is("JOIN")) {
        const names = command.parameter(0) orelse {
            connection.sendNumeric("461", "JOIN :Not enough parameters", .{});
            return true;
        };
        if (std.mem.eql(u8, names, "0")) {
            inline for (.{ "#osu", "#announce", "#lobby", "#lazer" }) |channel| if (connection.joined.load(.acquire) & irc.channelMask(channel).? != 0) {
                _ = connection.joined.fetchAnd(~irc.channelMask(channel).?, .acq_rel);
                connection.sendLine(":{s}!zigcho@kai.ovh PART {s}", .{ connection.currentNick(), channel });
            };
            return true;
        }
        var channels = std.mem.splitScalar(u8, names, ',');
        while (channels.next()) |requested| {
            const channel = irc.canonicalChannel(requested) orelse {
                connection.sendNumeric("403", "{s} :No such channel", .{requested});
                continue;
            };
            if (connection.joined.load(.acquire) & irc.channelMask(channel).? == 0) connection.sendJoin(channel);
        }
        return true;
    }
    if (command.is("PART")) {
        const requested = command.parameter(0) orelse {
            connection.sendNumeric("461", "PART :Not enough parameters", .{});
            return true;
        };
        const channel = irc.canonicalChannel(requested) orelse {
            connection.sendNumeric("403", "{s} :No such channel", .{requested});
            return true;
        };
        const mask = irc.channelMask(channel).?;
        if (connection.joined.load(.acquire) & mask == 0) {
            connection.sendNumeric("442", "{s} :You're not on that channel", .{channel});
            return true;
        }
        _ = connection.joined.fetchAnd(~mask, .acq_rel);
        connection.sendLine(":{s}!zigcho@kai.ovh PART {s}", .{ connection.currentNick(), channel });
        return true;
    }
    if (command.is("PRIVMSG") or command.is("NOTICE")) {
        ircHandleMessage(connection, command);
        return true;
    }
    if (command.is("NAMES")) {
        if (command.parameter(0)) |requested| {
            if (irc.canonicalChannel(requested)) |channel| connection.sendNames(channel) else connection.sendNumeric("403", "{s} :No such channel", .{requested});
        } else inline for (.{ "#osu", "#announce", "#lobby", "#lazer" }) |channel| connection.sendNames(channel);
        return true;
    }
    if (command.is("LIST")) {
        connection.sendNumeric("321", "Channel :Users Name", .{});
        inline for (.{ "#osu", "#announce", "#lobby", "#lazer" }) |channel| connection.sendNumeric("322", "{s} 2 :shared Zigcho chat", .{channel});
        connection.sendNumeric("323", ":End of /LIST", .{});
        return true;
    }
    if (command.is("WHO")) {
        const channel = command.parameter(0) orelse "#osu";
        connection.sendNumeric("352", "{s} zigcho kai.ovh {s} kai H@ :0 kai", .{ channel, irc.server_name });
        connection.sendNumeric("352", "{s} zigcho kai.ovh {s} {s} H :0 {s}", .{ channel, irc.server_name, connection.currentNick(), connection.currentNick() });
        connection.sendNumeric("315", "{s} :End of /WHO list", .{channel});
        return true;
    }
    if (command.is("WHOIS")) {
        const requested = command.parameter(0) orelse connection.currentNick();
        const found = connection.app.store.userByName(connection.app.allocator, requested) catch null;
        if (found) |user| {
            defer freeUser(connection.app.allocator, user);
            connection.sendNumeric("311", "{s} zigcho kai.ovh * :{s}", .{ user.safe_name, user.name });
            connection.sendNumeric("318", "{s} :End of /WHOIS list", .{user.safe_name});
        } else connection.sendNumeric("401", "{s} :No such nick", .{requested});
        return true;
    }
    if (command.is("TOPIC")) {
        const requested = command.parameter(0) orelse "#osu";
        if (irc.canonicalChannel(requested)) |channel| connection.sendNumeric("332", "{s} :shared Zigcho chat", .{channel}) else connection.sendNumeric("403", "{s} :No such channel", .{requested});
        return true;
    }
    if (command.is("MODE")) {
        const target = command.parameter(0) orelse connection.currentNick();
        if (target.len != 0 and target[0] == '#') connection.sendNumeric("324", "{s} +nt", .{target}) else connection.sendNumeric("221", "+i", .{});
        return true;
    }
    if (command.is("AWAY")) {
        if (command.parameter(0) != null) connection.sendNumeric("306", ":You have been marked as being away", .{}) else connection.sendNumeric("305", ":You are no longer marked as being away", .{});
        return true;
    }
    connection.sendNumeric("421", "{s} :Unknown command", .{command.verb});
    return true;
}

fn ircPollMessages(connection: *IrcConnection) std.Io.Cancelable!void {
    while (connection.alive.load(.acquire)) {
        const now = std.Io.Clock.real.now(connection.io).toSeconds();
        if (!connection.registered.load(.acquire)) {
            if (now - connection.connected_at >= 30) {
                connection.sendServer("ERROR :Registration timed out", .{});
                connection.close();
                return;
            }
            try std.Io.sleep(connection.io, .fromSeconds(1), .awake);
            continue;
        }
        if (now - connection.last_ping_at >= 90) {
            connection.sendServer("PING :{d}", .{now});
            connection.last_ping_at = now;
        }
        const user = connection.user orelse return;
        const json = connection.app.store.lazerAllMessagesJson(connection.app.allocator, user.id, connection.cursor, 100) catch |err| {
            std.log.warn("event=irc_chat_poll_failed user_id={d} error={t}", .{ user.id, err });
            try std.Io.sleep(connection.io, .fromSeconds(2), .awake);
            continue;
        };
        defer connection.app.allocator.free(json);
        var parsed = std.json.parseFromSlice(std.json.Value, connection.app.allocator, json, .{}) catch |err| {
            std.log.warn("event=irc_chat_payload_invalid user_id={d} error={t}", .{ user.id, err });
            try std.Io.sleep(connection.io, .fromSeconds(2), .awake);
            continue;
        };
        defer parsed.deinit();
        const items = switch (parsed.value) {
            .array => |array| array.items,
            else => {
                try std.Io.sleep(connection.io, .fromSeconds(2), .awake);
                continue;
            },
        };
        for (items) |item| {
            const object = switch (item) {
                .object => |value| value,
                else => continue,
            };
            const message_id = ircJsonInteger(object, "message_id") orelse continue;
            if (message_id <= connection.cursor) continue;
            connection.cursor = message_id;
            const sender_id: i32 = @intCast(ircJsonInteger(object, "sender_id") orelse continue);
            if (sender_id == user.id) continue;
            const channel_id = ircJsonInteger(object, "channel_id") orelse continue;
            const content = switch (object.get("content") orelse continue) {
                .string => |value| value,
                else => continue,
            };
            const action = switch (object.get("is_action") orelse continue) {
                .bool => |value| value,
                else => false,
            };
            const sender_object = switch (object.get("sender") orelse continue) {
                .object => |value| value,
                else => continue,
            };
            const sender_display = switch (sender_object.get("username") orelse continue) {
                .string => |value| value,
                else => continue,
            };
            const sender_nick = domain.safeName(connection.app.allocator, sender_display) catch continue;
            defer connection.app.allocator.free(sender_nick);
            if (irc.channelForId(channel_id)) |channel| {
                const mask = irc.channelMask(channel).?;
                if (connection.joined.load(.acquire) & mask != 0) connection.sendChat(sender_nick, channel, content, action);
            } else if (lazer.privateChannelUser(channel_id) != null) {
                connection.sendChat(sender_nick, user.safe_name, content, action);
                connection.app.store.markDirectMessagesRead(user.id, sender_id) catch |err|
                    std.log.warn("event=irc_dm_read_failed user_id={d} sender_id={d} error={t}", .{ user.id, sender_id, err });
            }
        }
        try std.Io.sleep(connection.io, .fromMilliseconds(500), .awake);
    }
}

fn serveIrcConnection(app: *App, stream_value: std.Io.net.Stream, io: std.Io) std.Io.Cancelable!void {
    const previous = app.irc_clients.fetchAdd(1, .acq_rel);
    defer _ = app.irc_clients.fetchSub(1, .acq_rel);
    var stream = stream_value;
    defer stream.close(io);
    if (previous >= max_irc_clients) {
        var send_buffer: [256]u8 = undefined;
        var writer = stream.writer(io, &send_buffer);
        writer.interface.writeAll(":irc.kai.ovh ERROR :Server is full\r\n") catch return;
        writer.interface.flush() catch return;
        return;
    }
    var connection: IrcConnection = undefined;
    connection.init(app, stream, io);
    defer connection.deinit();
    var poller: std.Io.Group = .init;
    defer poller.cancel(io);
    poller.concurrent(io, ircPollMessages, .{&connection}) catch {
        connection.sendServer("ERROR :Server is busy", .{});
        connection.close();
        return;
    };

    var receive_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &receive_buffer);
    while (connection.alive.load(.acquire)) {
        const line_value = reader.interface.takeDelimiter('\n') catch |err| {
            if (err == error.StreamTooLong) connection.sendServer("ERROR :Input line is too long", .{});
            break;
        };
        const line = line_value orelse break;
        const command = irc.parseCommand(line) catch |err| {
            if (err == error.LineTooLong) {
                connection.sendServer("ERROR :Input line is too long", .{});
                break;
            }
            connection.sendNumeric("417", ":Invalid input line", .{});
            continue;
        } orelse continue;
        if (!ircHandleCommand(&connection, command)) break;
    }
    connection.close();
}

pub fn serveIrcListener(app: *App, bind: []const u8, port: u16, io: std.Io) std.Io.Cancelable!void {
    const address = std.Io.net.IpAddress.parse(bind, port) catch |err| {
        std.log.err("event=irc_listener_address_invalid bind={s} port={d} error={t}", .{ bind, port, err });
        return;
    };
    var listener = address.listen(io, .{ .reuse_address = true }) catch |err| {
        std.log.err("event=irc_listener_start_failed bind={s} port={d} error={t}", .{ bind, port, err });
        return;
    };
    defer listener.deinit(io);
    var connections: std.Io.Group = .init;
    defer connections.cancel(io);
    std.log.info("event=irc_listener_started bind={s} port={d} tls=proxy_required", .{ bind, port });
    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                std.log.warn("event=irc_accept_failed error={t}", .{err});
                continue;
            },
        };
        connections.concurrent(io, serveIrcConnection, .{ app, stream, io }) catch |err| {
            std.log.warn("event=irc_connection_spawn_failed error={t}", .{err});
            var rejected = stream;
            rejected.close(io);
        };
    }
}
