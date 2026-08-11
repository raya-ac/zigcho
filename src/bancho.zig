const std = @import("std");
const protocol = @import("protocol.zig");
const sessions_mod = @import("sessions.zig");
const storage = @import("storage.zig");
const domain = @import("domain.zig");
const stable_score = @import("stable_score.zig");
const country = @import("country.zig");
const commands = @import("commands.zig");
const log = @import("logutil.zig");
const multiplayer = @import("multiplayer.zig");

pub const LoginResult = struct {
    allocator: std.mem.Allocator,
    token: []u8,
    body: []u8,

    pub fn deinit(self: *LoginResult) void {
        self.allocator.free(self.token);
        self.allocator.free(self.body);
        self.* = undefined;
    }
};
pub const session_idle_seconds: i64 = 300;

const SnapshotUser = struct {
    id: i32,
    name: []u8,
    country: [2]u8,
    privileges: u32,
};

const SessionSnapshot = struct {
    allocator: std.mem.Allocator,
    user: SnapshotUser,
    utc_offset: i8,
    action: u8,
    mode: u8,
    mods: i32,
    map_id: i32,
    map_md5: [32]u8,
    info_text: [96]u8,
    info_len: usize,
    longitude: f32,
    latitude: f32,

    fn init(allocator: std.mem.Allocator, session: *const sessions_mod.Session) !SessionSnapshot {
        return .{
            .allocator = allocator,
            .user = .{
                .id = session.user.id,
                .name = try allocator.dupe(u8, session.user.name),
                .country = session.user.country,
                .privileges = session.user.privileges,
            },
            .utc_offset = session.utc_offset,
            .action = session.action,
            .mode = session.mode,
            .mods = session.mods,
            .map_id = session.map_id,
            .map_md5 = session.map_md5,
            .info_text = session.info_text,
            .info_len = session.info_len,
            .longitude = session.longitude,
            .latitude = session.latitude,
        };
    }

    fn deinit(self: *SessionSnapshot) void {
        self.allocator.free(self.user.name);
        self.* = undefined;
    }

    fn info(self: *const SessionSnapshot) []const u8 {
        return self.info_text[0..self.info_len];
    }
};

const LoginCapture = struct {
    allocator: std.mem.Allocator,
    token: []u8,
    user_id: i32,
    silence_end: i64,
    client_privileges: u8,
    osu_count: i32,
    announce_count: i32,
    sessions: std.ArrayList(SessionSnapshot) = .empty,

    fn deinit(self: *LoginCapture) void {
        for (self.sessions.items) |*snapshot| snapshot.deinit();
        self.sessions.deinit(self.allocator);
        self.allocator.free(self.token);
        self.* = undefined;
    }
};

pub fn clientPrivileges(server_privileges: u32, grant_direct: bool) u8 {
    const unrestricted: u32 = 1 << 0;
    const supporter: u32 = 1 << 4;
    const premium: u32 = 1 << 5;
    const moderator: u32 = 1 << 12;
    const administrator: u32 = 1 << 13;
    const developer: u32 = 1 << 14;
    var client: u8 = 0;
    if (server_privileges & unrestricted != 0) client |= 1 << 0;
    if (server_privileges & (supporter | premium) != 0 or grant_direct) client |= 1 << 2;
    if (server_privileges & moderator != 0) client |= 1 << 1;
    if (server_privileges & administrator != 0) client |= 1 << 4;
    if (server_privileges & developer != 0) client |= 1 << 3;
    return client;
}

fn presence(w: *protocol.Writer, s: anytype) !void {
    const start = try w.begin(.user_presence);
    try w.int(i32, s.user.id);
    try w.string(s.user.name);
    try w.byte(@intCast(@as(i16, s.utc_offset) + 24));
    try w.byte(country.numeric(&s.user.country));
    try w.byte(clientPrivileges(s.user.privileges, false) | (@as(u8, s.mode) << 5));
    try w.float(f32, s.longitude);
    try w.float(f32, s.latitude);
    try w.int(i32, 0);
    w.finish(start);
}

fn stats(w: *protocol.Writer, store: *storage.Store, s: anytype) !void {
    const stats_mode = stable_score.statsMode(s.mode, s.mods) orelse s.mode;
    const current = (try store.statsForUser(s.user.id, stats_mode)) orelse domain.Stats{};
    const start = try w.begin(.user_stats);
    try w.int(i32, s.user.id);
    try w.byte(s.action);
    try w.string(s.info());
    try w.string(&s.map_md5);
    try w.int(i32, s.mods);
    try w.byte(s.mode);
    try w.int(i32, s.map_id);
    try w.int(i64, if (current.pp > std.math.maxInt(u16)) current.pp else current.ranked_score);
    try w.float(f32, @floatCast(current.accuracy));
    try w.int(i32, current.plays);
    try w.int(i64, current.total_score);
    try w.int(i32, current.global_rank);
    try w.int(u16, if (current.pp > std.math.maxInt(u16)) 0 else @intCast(current.pp));
    w.finish(start);
}

fn loginFailure(allocator: std.mem.Allocator, token_text: []const u8, notification: []const u8) !LoginResult {
    var out = protocol.Writer.init(allocator);
    defer out.deinit();
    try out.packetInt(.user_id, -1);
    try out.packetString(.notification, notification);
    const token = try allocator.dupe(u8, token_text);
    errdefer allocator.free(token);
    return .{ .allocator = allocator, .token = token, .body = try allocator.dupe(u8, out.bytes()) };
}

fn captureLoginLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, user: domain.User, utc: i8, longitude: f32, latitude: f32) !LoginCapture {
    var user_owned = true;
    errdefer if (user_owned) {
        allocator.free(user.name);
        allocator.free(user.safe_name);
    };
    if (sessions.byUser(user.id)) |old| removeSessionLocked(allocator, sessions, old);
    const session = try sessions.create(user, utc, longitude, latitude);
    user_owned = false;
    errdefer sessions.remove(session);
    const token = try allocator.dupe(u8, &session.token);
    errdefer allocator.free(token);
    var capture: LoginCapture = .{
        .allocator = allocator,
        .token = token,
        .user_id = user.id,
        .silence_end = user.silence_end,
        .client_privileges = clientPrivileges(user.privileges, true),
        .osu_count = @intCast(sessions.channelCount("#osu")),
        .announce_count = @intCast(sessions.channelCount("#announce")),
    };
    errdefer {
        for (capture.sessions.items) |*snapshot| snapshot.deinit();
        capture.sessions.deinit(allocator);
    }
    for (sessions.items.items) |item| {
        const snapshot = try SessionSnapshot.init(allocator, item);
        errdefer {
            var owned = snapshot;
            owned.deinit();
        }
        try capture.sessions.append(allocator, snapshot);
    }
    return capture;
}

pub fn login(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, body: []const u8, login_country: ?[2]u8, longitude: f32, latitude: f32) !LoginResult {
    var lines = std.mem.splitScalar(u8, body, '\n');
    const name = std.mem.trim(u8, lines.next() orelse "", "\r");
    const password = std.mem.trim(u8, lines.next() orelse "", "\r");
    const details = std.mem.trim(u8, lines.next() orelse "", "\r");
    if (name.len < 2 or password.len != 32) {
        return loginFailure(allocator, "invalid-request", "Invalid login request.");
    }
    var user = (try store.authenticate(allocator, name, password)) orelse {
        return loginFailure(allocator, "no", "Incorrect credentials.");
    };
    var user_transferred = false;
    defer if (!user_transferred) {
        allocator.free(user.name);
        allocator.free(user.safe_name);
    };
    if (login_country) |value| {
        try store.updateCountry(user.id, value);
        user.country = value;
    }
    var utc: i8 = 0;
    var detail_it = std.mem.splitScalar(u8, details, '|');
    _ = detail_it.next();
    if (detail_it.next()) |offset| utc = std.fmt.parseInt(i8, offset, 10) catch 0;
    std.debug.print("{s}{s}╔══════════════════════════════════════════════════╗{s}\n", .{ log.magenta ++ log.bold, "", log.reset });
    std.debug.print("{s}{s}║  LOGIN — {s}{s}{s}{s}{s} ║{s}\n", .{ log.magenta ++ log.bold, "", log.green, name, log.reset, log.magenta ++ log.bold, "", log.reset });
    std.debug.print("{s}{s}╚══════════════════════════════════════════════════╝{s}\n", .{ log.magenta ++ log.bold, "", log.reset });
    std.debug.print("{s}  ► user_id  :{s} {d}\n", .{ log.dim, log.reset, user.id });
    const country_display: []const u8 = if (login_country) |c| &c else "??";
    std.debug.print("{s}  ► country  :{s} {s}\n", .{ log.dim, log.reset, country_display });
    std.debug.print("{s}  ► utc      :{s} {d}\n", .{ log.dim, log.reset, utc });
    sessions.mutex.lockUncancelable(sessions.io);
    pruneExpiredLocked(allocator, sessions);
    user_transferred = true;
    var capture = captureLoginLocked(allocator, sessions, user, utc, longitude, latitude) catch |err| {
        sessions.mutex.unlock(sessions.io);
        return err;
    };
    sessions.mutex.unlock(sessions.io);
    defer capture.deinit();
    var login_complete = false;
    defer if (!login_complete) {
        sessions.mutex.lockUncancelable(sessions.io);
        defer sessions.mutex.unlock(sessions.io);
        if (sessions.byToken(capture.token)) |failed_session| removeSessionLocked(allocator, sessions, failed_session);
    };

    var out = protocol.Writer.init(allocator);
    defer out.deinit();
    try out.packetInt(.protocol_version, 19);
    try out.packetInt(.user_id, capture.user_id);
    try out.packetInt(.privileges, capture.client_privileges);
    try out.packetInt(.silence_end, @intCast(@max(0, capture.silence_end - std.Io.Clock.real.now(sessions.io).toSeconds())));
    const own_index = for (capture.sessions.items, 0..) |*snapshot, index| {
        if (snapshot.user.id == capture.user_id) break index;
    } else return error.LoginSessionMissing;
    const own = &capture.sessions.items[own_index];
    try presence(&out, own);
    try stats(&out, store, own);
    try protocol.writeChannel(&out, "#osu", "general", capture.osu_count);
    try protocol.writeChannel(&out, "#announce", "updates", capture.announce_count);
    try out.packetEmpty(.channel_info_end);
    for (capture.sessions.items, 0..) |*other, index| if (index != own_index) {
        try presence(&out, other);
        try stats(&out, store, other);
    };
    var announce = protocol.Writer.init(allocator);
    defer announce.deinit();
    try presence(&announce, own);
    try stats(&announce, store, own);
    {
        sessions.mutex.lockUncancelable(sessions.io);
        defer sessions.mutex.unlock(sessions.io);
        if (sessions.byToken(capture.token)) |current| {
            if (current.user.id == capture.user_id) try sessions.broadcast(announce.bytes(), current);
        }
    }
    const result_token = try allocator.dupe(u8, capture.token);
    errdefer allocator.free(result_token);
    const result_body = try allocator.dupe(u8, out.bytes());
    login_complete = true;
    return .{ .allocator = allocator, .token = result_token, .body = result_body };
}

fn queuePacket(target: *sessions_mod.Session, allocator: std.mem.Allocator, bytes: []const u8) !void {
    try target.enqueue(allocator, bytes);
}

fn matchChannelName(buffer: *[32]u8, match_id: u16) ![]const u8 {
    return std.fmt.bufPrint(buffer, "#multi_{d}", .{match_id});
}

fn broadcastMatchStateLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, match: *const multiplayer.Match, include_lobby: bool) !void {
    var room_event = protocol.Writer.init(allocator);
    defer room_event.deinit();
    try multiplayer.writePacket(&room_event, .update_match, match, true);
    var lobby_event = protocol.Writer.init(allocator);
    defer lobby_event.deinit();
    if (include_lobby) try multiplayer.writePacket(&lobby_event, .update_match, match, false);
    for (sessions.items.items) |other| {
        if (other.is_bot) continue;
        if (other.match_id == match.id) {
            try other.enqueue(allocator, room_event.bytes());
        } else if (include_lobby and other.in_lobby) {
            try other.enqueue(allocator, lobby_event.bytes());
        }
    }
}

fn broadcastNewMatchLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, match: *const multiplayer.Match) !void {
    var event = protocol.Writer.init(allocator);
    defer event.deinit();
    try multiplayer.writePacket(&event, .new_match, match, false);
    for (sessions.items.items) |other| if (!other.is_bot and other.in_lobby) try other.enqueue(allocator, event.bytes());
}

fn broadcastDisposeMatchLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, match_id: u16) !void {
    var event = protocol.Writer.init(allocator);
    defer event.deinit();
    try event.packetInt(.dispose_match, match_id);
    for (sessions.items.items) |other| if (!other.is_bot and other.in_lobby) try other.enqueue(allocator, event.bytes());
}

fn containsUser(ids: []const i32, user_id: i32) bool {
    for (ids) |id| if (id == user_id) return true;
    return false;
}

fn broadcastMatchPacketLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, match_id: u16, bytes: []const u8, include_lobby: bool, immune: []const i32) !void {
    for (sessions.items.items) |other| {
        if (other.is_bot) continue;
        if (other.match_id == match_id) {
            if (!containsUser(immune, other.user.id)) try other.enqueue(allocator, bytes);
        } else if (include_lobby and other.in_lobby) {
            try other.enqueue(allocator, bytes);
        }
    }
}

fn leaveMatchLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, session: *sessions_mod.Session) void {
    const match_id = session.match_id orelse return;
    const match = sessions.matchById(match_id) orelse {
        session.match_id = null;
        return;
    };
    const slot = match.slotByUser(session.user.id) orelse {
        session.match_id = null;
        return;
    };
    const next_status: multiplayer.SlotStatus = if (slot.status == @intFromEnum(multiplayer.SlotStatus.locked)) .locked else .open;
    slot.reset(next_status);
    session.match_id = null;
    if (match.isEmpty()) {
        match.deinit();
        sessions.matches[match_id] = null;
        broadcastDisposeMatchLocked(allocator, sessions, match_id) catch {};
        return;
    }
    if (match.host_id == session.user.id) {
        match.host_id = match.firstUser().?;
        if (sessions.byUser(match.host_id)) |new_host| {
            var transfer = protocol.Writer.init(allocator);
            defer transfer.deinit();
            transfer.packetEmpty(.match_transfer_host) catch {};
            new_host.enqueue(allocator, transfer.bytes()) catch {};
        }
    }
    broadcastMatchStateLocked(allocator, sessions, match, true) catch {};
}

fn broadcastLogoutLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, session: *sessions_mod.Session) void {
    var event = protocol.Writer.init(allocator);
    defer event.deinit();
    const start = event.begin(.user_logout) catch return;
    event.int(i32, session.user.id) catch return;
    event.byte(0) catch return;
    event.finish(start);
    sessions.broadcast(event.bytes(), session) catch {};
}

fn removeSessionLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, session: *sessions_mod.Session) void {
    leaveMatchLocked(allocator, sessions, session);
    broadcastLogoutLocked(allocator, sessions, session);
    sessions.remove(session);
}

fn pruneExpiredLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions) void {
    const now = std.Io.Clock.real.now(sessions.io).toSeconds();
    var index: usize = 0;
    while (index < sessions.items.items.len) {
        const session = sessions.items.items[index];
        if (!session.is_bot and now - session.last_seen >= session_idle_seconds) {
            removeSessionLocked(allocator, sessions, session);
        } else {
            index += 1;
        }
    }
}

fn pollLocked(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, session: *sessions_mod.Session, body: []const u8, logged_out: *bool) ![]u8 {
    const now = std.Io.Clock.real.now(sessions.io).toSeconds();
    session.last_seen = now;
    var out = protocol.Writer.init(allocator);
    defer out.deinit();
    try out.raw(session.queue.items);
    session.queue.clearRetainingCapacity();
    var reader: protocol.Reader = .{ .data = body };
    while (try reader.next()) |packet| switch (packet.id) {
        .ping => {},
        .request_status => try stats(&out, store, session),
        .change_action => {
            var p: protocol.PayloadReader = .{ .data = packet.payload };
            session.action = try p.byte();
            const info = try p.string();
            const md5 = try p.string();
            session.mods = try p.int(i32);
            session.mode = try p.byte();
            session.map_id = try p.int(i32);
            session.info_len = @min(info.len, session.info_text.len);
            @memcpy(session.info_text[0..session.info_len], info[0..session.info_len]);
            @memset(&session.map_md5, 0);
            @memcpy(session.map_md5[0..@min(32, md5.len)], md5[0..@min(32, md5.len)]);
            var event = protocol.Writer.init(allocator);
            defer event.deinit();
            try stats(&event, store, session);
            try sessions.broadcast(event.bytes(), session);
            if (session.action == 1 and session.map_md5[0] != 0) {
                commands.handleNp(allocator, store, session) catch {};
            }
        },
        .send_public_message, .send_private_message => {
            var p: protocol.PayloadReader = .{ .data = packet.payload };
            _ = try p.string();
            const text = std.mem.trim(u8, try p.string(), " \t\r\n");
            const target_name = try p.string();
            _ = try p.int(i32);
            if (text.len == 0 or text.len > 2000) continue;
            if (packet.id == .send_private_message) {
                if (sessions.byName(target_name)) |target| {
                    if (target.is_bot) {
                        if (commands.handleCommand(allocator, store, session, text) == .handled) continue;
                        try protocol.writeMessage(&out, "kai", "commands: !np (pp for current map) | !with mods acc% misses (custom pp)", session.user.name, 3);
                        continue;
                    }
                }
            }
            var message = protocol.Writer.init(allocator);
            defer message.deinit();
            try protocol.writeMessage(&message, session.user.name, text, target_name, session.user.id);
            if (packet.id == .send_private_message) {
                if (sessions.byName(target_name)) |target| {
                    if (!target.is_bot) try queuePacket(target, allocator, message.bytes());
                }
            } else {
                if (!session.joined(target_name)) continue;
                try sessions.broadcastChannel(target_name, message.bytes(), session);
            }
        },
        .join_lobby => {
            session.in_lobby = true;
            for (&sessions.matches) |*entry| if (entry.*) |*match| try multiplayer.writePacket(&out, .new_match, match, false);
        },
        .part_lobby => session.in_lobby = false,
        .create_match => {
            const data = multiplayer.readMatch(packet.payload) catch continue;
            if (data.host_id != session.user.id or session.match_id != null or session.user.restricted or session.user.silence_end > now) {
                try out.packetEmpty(.match_join_fail);
                continue;
            }
            const match_id = sessions.freeMatchId() orelse {
                try out.packetEmpty(.match_join_fail);
                continue;
            };
            sessions.matches[match_id] = try multiplayer.Match.init(allocator, match_id, data, session.user.id);
            const match = sessions.matchById(match_id).?;
            session.match_id = match_id;
            session.in_lobby = false;
            try multiplayer.writePacket(&out, .match_join_success, match, true);
            var channel_buffer: [32]u8 = undefined;
            try out.packetString(.channel_join_success, try matchChannelName(&channel_buffer, match_id));
            try broadcastNewMatchLocked(allocator, sessions, match);
            try broadcastMatchStateLocked(allocator, sessions, match, true);
        },
        .join_match => {
            var payload: protocol.PayloadReader = .{ .data = packet.payload };
            const raw_match_id = try payload.int(i32);
            const password = try payload.string();
            if (payload.pos != packet.payload.len or raw_match_id < 0 or raw_match_id >= multiplayer.max_matches or session.match_id != null or session.user.restricted or session.user.silence_end > now) {
                try out.packetEmpty(.match_join_fail);
                continue;
            }
            const match_id: u16 = @intCast(raw_match_id);
            const match = sessions.matchById(match_id) orelse {
                try out.packetEmpty(.match_join_fail);
                continue;
            };
            if (!std.mem.eql(u8, password, match.password)) {
                try out.packetEmpty(.match_join_fail);
                continue;
            }
            const slot = match.freeSlot() orelse {
                try out.packetEmpty(.match_join_fail);
                continue;
            };
            slot.user_id = session.user.id;
            slot.status = @intFromEnum(multiplayer.SlotStatus.not_ready);
            slot.team = if (multiplayer.isTeamVersus(match.team_type)) @intFromEnum(multiplayer.Team.red) else @intFromEnum(multiplayer.Team.neutral);
            session.match_id = match_id;
            session.in_lobby = false;
            try multiplayer.writePacket(&out, .match_join_success, match, true);
            var channel_buffer: [32]u8 = undefined;
            try out.packetString(.channel_join_success, try matchChannelName(&channel_buffer, match_id));
            try broadcastMatchStateLocked(allocator, sessions, match, true);
        },
        .part_match => leaveMatchLocked(allocator, sessions, session),
        .change_slot => {
            const match_id = session.match_id orelse continue;
            const match = sessions.matchById(match_id) orelse continue;
            var payload: protocol.PayloadReader = .{ .data = packet.payload };
            const wanted = try payload.int(i32);
            if (payload.pos != packet.payload.len or wanted < 0 or wanted >= 16) continue;
            const current = match.slotByUser(session.user.id) orelse continue;
            const target = &match.slots[@intCast(wanted)];
            if (target.status != @intFromEnum(multiplayer.SlotStatus.open)) continue;
            target.* = current.*;
            current.reset(.open);
            try broadcastMatchStateLocked(allocator, sessions, match, true);
        },
        .match_ready => {
            const match = sessions.matchById(session.match_id orelse continue) orelse continue;
            const slot = match.slotByUser(session.user.id) orelse continue;
            slot.status = @intFromEnum(multiplayer.SlotStatus.ready);
            try broadcastMatchStateLocked(allocator, sessions, match, false);
        },
        .match_not_ready, .match_has_beatmap => {
            const match = sessions.matchById(session.match_id orelse continue) orelse continue;
            const slot = match.slotByUser(session.user.id) orelse continue;
            slot.status = @intFromEnum(multiplayer.SlotStatus.not_ready);
            try broadcastMatchStateLocked(allocator, sessions, match, false);
        },
        .match_no_beatmap => {
            const match = sessions.matchById(session.match_id orelse continue) orelse continue;
            const slot = match.slotByUser(session.user.id) orelse continue;
            slot.status = @intFromEnum(multiplayer.SlotStatus.no_map);
            try broadcastMatchStateLocked(allocator, sessions, match, false);
        },
        .match_start => {
            if (packet.payload.len != 0) continue;
            const match = sessions.matchById(session.match_id orelse continue) orelse continue;
            if (match.host_id != session.user.id or match.in_progress) continue;
            var no_map: [16]i32 = undefined;
            var no_map_count: usize = 0;
            for (&match.slots) |*slot| {
                slot.loaded = false;
                slot.skipped = false;
                if (slot.user_id) |user_id| {
                    if (slot.status == @intFromEnum(multiplayer.SlotStatus.no_map)) {
                        no_map[no_map_count] = user_id;
                        no_map_count += 1;
                    } else {
                        slot.status = @intFromEnum(multiplayer.SlotStatus.playing);
                    }
                }
            }
            match.in_progress = true;
            var event = protocol.Writer.init(allocator);
            defer event.deinit();
            try multiplayer.writePacket(&event, .match_start, match, true);
            try broadcastMatchPacketLocked(allocator, sessions, match.id, event.bytes(), false, no_map[0..no_map_count]);
            try broadcastMatchStateLocked(allocator, sessions, match, true);
        },
        .match_load_complete => {
            if (packet.payload.len != 0) continue;
            const match = sessions.matchById(session.match_id orelse continue) orelse continue;
            if (!match.in_progress) continue;
            const slot = match.slotByUser(session.user.id) orelse continue;
            if (slot.status != @intFromEnum(multiplayer.SlotStatus.playing)) continue;
            slot.loaded = true;
            var waiting = false;
            for (match.slots) |other_slot| if (other_slot.status == @intFromEnum(multiplayer.SlotStatus.playing) and !other_slot.loaded) {
                waiting = true;
                break;
            };
            if (!waiting) {
                var event = protocol.Writer.init(allocator);
                defer event.deinit();
                try event.packetEmpty(.match_all_players_loaded);
                try broadcastMatchPacketLocked(allocator, sessions, match.id, event.bytes(), false, &.{});
            }
        },
        .match_score_update => {
            const match = sessions.matchById(session.match_id orelse continue) orelse continue;
            if (!match.in_progress or !multiplayer.validScoreFrame(packet.payload)) continue;
            const slot_index = match.slotIndexByUser(session.user.id) orelse continue;
            if (match.slots[slot_index].status != @intFromEnum(multiplayer.SlotStatus.playing)) continue;
            var event = protocol.Writer.init(allocator);
            defer event.deinit();
            try multiplayer.writeScoreFramePacket(&event, packet.payload, @intCast(slot_index));
            try broadcastMatchPacketLocked(allocator, sessions, match.id, event.bytes(), false, &.{});
        },
        .match_failed => {
            if (packet.payload.len != 0) continue;
            const match = sessions.matchById(session.match_id orelse continue) orelse continue;
            if (!match.in_progress) continue;
            const slot_index = match.slotIndexByUser(session.user.id) orelse continue;
            if (match.slots[slot_index].status != @intFromEnum(multiplayer.SlotStatus.playing)) continue;
            var event = protocol.Writer.init(allocator);
            defer event.deinit();
            try event.packetInt(.match_player_failed, @intCast(slot_index));
            try broadcastMatchPacketLocked(allocator, sessions, match.id, event.bytes(), false, &.{});
        },
        .match_skip_request => {
            if (packet.payload.len != 0) continue;
            const match = sessions.matchById(session.match_id orelse continue) orelse continue;
            if (!match.in_progress) continue;
            const slot = match.slotByUser(session.user.id) orelse continue;
            if (slot.status != @intFromEnum(multiplayer.SlotStatus.playing) or slot.skipped) continue;
            slot.skipped = true;
            var skipped_event = protocol.Writer.init(allocator);
            defer skipped_event.deinit();
            try skipped_event.packetInt(.match_player_skipped, session.user.id);
            try broadcastMatchPacketLocked(allocator, sessions, match.id, skipped_event.bytes(), true, &.{});
            var waiting = false;
            for (match.slots) |other_slot| if (other_slot.status == @intFromEnum(multiplayer.SlotStatus.playing) and !other_slot.skipped) {
                waiting = true;
                break;
            };
            if (!waiting) {
                var skip_event = protocol.Writer.init(allocator);
                defer skip_event.deinit();
                try skip_event.packetEmpty(.match_skip);
                try broadcastMatchPacketLocked(allocator, sessions, match.id, skip_event.bytes(), false, &.{});
            }
        },
        .match_complete => {
            if (packet.payload.len != 0) continue;
            const match = sessions.matchById(session.match_id orelse continue) orelse continue;
            if (!match.in_progress) continue;
            const slot = match.slotByUser(session.user.id) orelse continue;
            if (slot.status != @intFromEnum(multiplayer.SlotStatus.playing)) continue;
            slot.status = @intFromEnum(multiplayer.SlotStatus.complete);
            var still_playing = false;
            for (match.slots) |other_slot| if (other_slot.status == @intFromEnum(multiplayer.SlotStatus.playing)) {
                still_playing = true;
                break;
            };
            if (still_playing) continue;
            var not_playing: [16]i32 = undefined;
            var not_playing_count: usize = 0;
            for (&match.slots) |*other_slot| {
                if (other_slot.user_id) |user_id| {
                    if (other_slot.status == @intFromEnum(multiplayer.SlotStatus.complete)) {
                        other_slot.status = @intFromEnum(multiplayer.SlotStatus.not_ready);
                    } else {
                        not_playing[not_playing_count] = user_id;
                        not_playing_count += 1;
                    }
                }
                other_slot.loaded = false;
                other_slot.skipped = false;
            }
            match.in_progress = false;
            var event = protocol.Writer.init(allocator);
            defer event.deinit();
            try event.packetEmpty(.match_complete);
            try broadcastMatchPacketLocked(allocator, sessions, match.id, event.bytes(), false, not_playing[0..not_playing_count]);
            try broadcastMatchStateLocked(allocator, sessions, match, true);
        },
        .match_lock => {
            const match = sessions.matchById(session.match_id orelse continue) orelse continue;
            if (match.host_id != session.user.id) continue;
            var payload: protocol.PayloadReader = .{ .data = packet.payload };
            const wanted = try payload.int(i32);
            if (payload.pos != packet.payload.len or wanted < 0 or wanted >= 16) continue;
            const slot = &match.slots[@intCast(wanted)];
            if (slot.user_id == session.user.id) continue;
            if (slot.status == @intFromEnum(multiplayer.SlotStatus.locked)) {
                slot.reset(.open);
            } else {
                if (slot.user_id) |target_id| if (sessions.byUser(target_id)) |target| {
                    target.match_id = null;
                    var kicked = protocol.Writer.init(allocator);
                    defer kicked.deinit();
                    try kicked.packetEmpty(.match_join_fail);
                    try target.enqueue(allocator, kicked.bytes());
                };
                slot.reset(.locked);
            }
            try broadcastMatchStateLocked(allocator, sessions, match, true);
        },
        .match_transfer_host => {
            const match = sessions.matchById(session.match_id orelse continue) orelse continue;
            if (match.host_id != session.user.id) continue;
            var payload: protocol.PayloadReader = .{ .data = packet.payload };
            const wanted = try payload.int(i32);
            if (payload.pos != packet.payload.len or wanted < 0 or wanted >= 16) continue;
            const target_id = match.slots[@intCast(wanted)].user_id orelse continue;
            const target = sessions.byUser(target_id) orelse continue;
            match.host_id = target_id;
            var transfer = protocol.Writer.init(allocator);
            defer transfer.deinit();
            try transfer.packetEmpty(.match_transfer_host);
            try target.enqueue(allocator, transfer.bytes());
            try broadcastMatchStateLocked(allocator, sessions, match, true);
        },
        .match_change_mods => {
            const match = sessions.matchById(session.match_id orelse continue) orelse continue;
            var payload: protocol.PayloadReader = .{ .data = packet.payload };
            const mods = try payload.int(i32);
            if (payload.pos != packet.payload.len or mods < 0) continue;
            if (match.freemods) {
                if (match.host_id == session.user.id) match.mods = mods & multiplayer.speed_changing_mods;
                const slot = match.slotByUser(session.user.id) orelse continue;
                slot.mods = mods & ~multiplayer.speed_changing_mods;
            } else {
                if (match.host_id != session.user.id) continue;
                match.mods = mods;
            }
            try broadcastMatchStateLocked(allocator, sessions, match, true);
        },
        .match_change_team => {
            const match = sessions.matchById(session.match_id orelse continue) orelse continue;
            if (!multiplayer.isTeamVersus(match.team_type)) continue;
            const slot = match.slotByUser(session.user.id) orelse continue;
            slot.team = if (slot.team == @intFromEnum(multiplayer.Team.blue)) @intFromEnum(multiplayer.Team.red) else @intFromEnum(multiplayer.Team.blue);
            try broadcastMatchStateLocked(allocator, sessions, match, false);
        },
        .match_change_settings => {
            const data = multiplayer.readMatch(packet.payload) catch continue;
            const match = sessions.matchById(session.match_id orelse continue) orelse continue;
            if (match.host_id != session.user.id or data.host_id != session.user.id) continue;
            if (data.freemods != match.freemods) {
                if (data.freemods) {
                    for (&match.slots) |*slot| if (slot.user_id != null) {
                        slot.mods = match.mods & ~multiplayer.speed_changing_mods;
                    };
                    match.mods &= multiplayer.speed_changing_mods;
                } else {
                    const host_slot = match.slotByUser(session.user.id).?;
                    match.mods = (match.mods & multiplayer.speed_changing_mods) | host_slot.mods;
                    for (&match.slots) |*slot| slot.mods = 0;
                }
                match.freemods = data.freemods;
            }
            if (match.team_type != data.team_type) {
                const team: u8 = if (multiplayer.isTeamVersus(data.team_type)) @intFromEnum(multiplayer.Team.red) else @intFromEnum(multiplayer.Team.neutral);
                for (&match.slots) |*slot| if (slot.user_id != null) {
                    slot.team = team;
                };
            }
            try match.updateSettings(data);
            if (data.map_id == -1) for (&match.slots) |*slot| if (slot.status == @intFromEnum(multiplayer.SlotStatus.ready)) {
                slot.status = @intFromEnum(multiplayer.SlotStatus.not_ready);
            };
            try broadcastMatchStateLocked(allocator, sessions, match, true);
        },
        .match_change_password => {
            const data = multiplayer.readMatch(packet.payload) catch continue;
            const match = sessions.matchById(session.match_id orelse continue) orelse continue;
            if (match.host_id != session.user.id or data.host_id != session.user.id) continue;
            try match.updatePassword(data.password);
            try broadcastMatchStateLocked(allocator, sessions, match, true);
        },
        .channel_join => {
            var p: protocol.PayloadReader = .{ .data = packet.payload };
            const name = try p.string();
            if (sessions.join(session, name)) try out.packetString(.channel_join_success, name);
        },
        .channel_part => {
            var p: protocol.PayloadReader = .{ .data = packet.payload };
            sessions.part(session, try p.string());
        },
        .user_stats_request => {
            var p: protocol.PayloadReader = .{ .data = packet.payload };
            const count = try p.int(u16);
            var i: usize = 0;
            while (i < count) : (i += 1) if (sessions.byUser(try p.int(i32))) |s| try stats(&out, store, s);
        },
        .user_presence_request => {
            var p: protocol.PayloadReader = .{ .data = packet.payload };
            const count = try p.int(u16);
            var i: usize = 0;
            while (i < count) : (i += 1) if (sessions.byUser(try p.int(i32))) |s| try presence(&out, s);
        },
        .start_spectating => {
            var p: protocol.PayloadReader = .{ .data = packet.payload };
            if (sessions.byUser(try p.int(i32))) |host| {
                var e = protocol.Writer.init(allocator);
                defer e.deinit();
                try e.packetInt(.spectator_joined, session.user.id);
                try queuePacket(host, allocator, e.bytes());
            }
        },
        .spectate_frames => {
            var e = protocol.Writer.init(allocator);
            defer e.deinit();
            const st = try e.begin(.spectate_frames);
            try e.raw(packet.payload);
            e.finish(st);
            try sessions.broadcast(e.bytes(), session);
        },
        .logout => {
            if (now - session.login_time >= 1) logged_out.* = true;
            return allocator.dupe(u8, out.bytes());
        },
        else => {},
    };
    return allocator.dupe(u8, out.bytes());
}

pub fn poll(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, session: *sessions_mod.Session, body: []const u8) ![]u8 {
    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    var logged_out = false;
    const result = try pollLocked(allocator, store, sessions, session, body, &logged_out);
    if (logged_out) removeSessionLocked(allocator, sessions, session);
    return result;
}

pub fn pollByToken(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, token: []const u8, body: []const u8) !?[]u8 {
    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    pruneExpiredLocked(allocator, sessions);
    const session = sessions.byToken(token) orelse return null;
    if (session.queue_overflowed) {
        removeSessionLocked(allocator, sessions, session);
        return null;
    }
    var logged_out = false;
    const result = try pollLocked(allocator, store, sessions, session, body, &logged_out);
    if (logged_out) removeSessionLocked(allocator, sessions, session);
    return result;
}

pub fn publishStats(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, user_id: i32, mode: u8, mods: i32) !void {
    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    const session = sessions.byUser(user_id) orelse return;
    session.mode = mode;
    session.mods = mods;
    var event = protocol.Writer.init(allocator);
    defer event.deinit();
    try stats(&event, store, session);
    try sessions.broadcast(event.bytes(), null);
}
