const std = @import("std");
const protocol = @import("protocol.zig");
const sessions_mod = @import("sessions.zig");
const storage = @import("runtime_storage.zig");
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
    user_id: i32 = 0,
    hardware_match_count: u32 = 0,
    running_under_wine: bool = false,

    pub fn deinit(self: *LoginResult) void {
        self.allocator.free(self.token);
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

pub const StableLoginDetails = struct {
    osu_version: []const u8,
    utc_offset: i8,
    display_city: bool,
    pm_private: bool,
    hardware: storage.ClientHardware,
};

fn isMd5(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |char| if (!std.ascii.isHex(char)) return false;
    return true;
}

fn isValidClientVersion(value: []const u8) bool {
    if (value.len < 9 or value[0] != 'b') return false;
    for (value[1..9]) |char| if (!std.ascii.isDigit(char)) return false;
    var remainder = value[9..];
    if (remainder.len >= 2 and remainder[0] == '.' and std.ascii.isDigit(remainder[1])) remainder = remainder[2..];
    return remainder.len == 0 or
        std.mem.eql(u8, remainder, "beta") or
        std.mem.eql(u8, remainder, "cuttingedge") or
        std.mem.eql(u8, remainder, "dev") or
        std.mem.eql(u8, remainder, "tourney");
}

fn commonHardwareHash(value: []const u8) bool {
    return std.mem.eql(u8, value, "00000000000000000000000000000000") or
        std.ascii.eqlIgnoreCase(value, "d41d8cd98f00b204e9800998ecf8427e") or
        std.ascii.eqlIgnoreCase(value, "cfcd208495d565ef66e7dff9f98764da");
}

pub fn parseStableLoginDetails(details: []const u8) !StableLoginDetails {
    var fields = std.mem.splitScalar(u8, details, '|');
    const osu_version = fields.next() orelse return error.InvalidLoginDetails;
    const utc_text = fields.next() orelse return error.InvalidLoginDetails;
    const display_city = fields.next() orelse return error.InvalidLoginDetails;
    const client_hashes = fields.next() orelse return error.InvalidLoginDetails;
    const pm_private = fields.next() orelse return error.InvalidLoginDetails;
    if (fields.next() != null or !isValidClientVersion(osu_version)) return error.InvalidLoginDetails;
    const utc_offset = std.fmt.parseInt(i8, utc_text, 10) catch return error.InvalidLoginDetails;
    if (utc_offset < -24 or utc_offset > 24) return error.InvalidLoginDetails;
    if ((!std.mem.eql(u8, display_city, "0") and !std.mem.eql(u8, display_city, "1")) or
        (!std.mem.eql(u8, pm_private, "0") and !std.mem.eql(u8, pm_private, "1"))) return error.InvalidLoginDetails;
    if (client_hashes.len < 2 or client_hashes[client_hashes.len - 1] != ':') return error.InvalidLoginDetails;

    var hashes = std.mem.splitScalar(u8, client_hashes[0 .. client_hashes.len - 1], ':');
    const osu_path_md5 = hashes.next() orelse return error.InvalidLoginDetails;
    const adapters_str = hashes.next() orelse return error.InvalidLoginDetails;
    const adapters_md5 = hashes.next() orelse return error.InvalidLoginDetails;
    const uninstall_md5 = hashes.next() orelse return error.InvalidLoginDetails;
    const disk_signature_md5 = hashes.next() orelse return error.InvalidLoginDetails;
    if (hashes.next() != null or !isMd5(osu_path_md5) or !isMd5(adapters_md5) or !isMd5(uninstall_md5) or !isMd5(disk_signature_md5)) return error.InvalidLoginDetails;

    const running_under_wine = std.mem.eql(u8, adapters_str, "runningunderwine");
    if (!running_under_wine) {
        if (adapters_str.len < 2 or adapters_str[adapters_str.len - 1] != '.') return error.InvalidLoginDetails;
        var adapters = std.mem.splitScalar(u8, adapters_str[0 .. adapters_str.len - 1], '.');
        var any_adapter = false;
        while (adapters.next()) |adapter| if (adapter.len != 0) {
            any_adapter = true;
        };
        if (!any_adapter) return error.InvalidLoginDetails;
    }

    return .{
        .osu_version = osu_version,
        .utc_offset = utc_offset,
        .display_city = std.mem.eql(u8, display_city, "1"),
        .pm_private = std.mem.eql(u8, pm_private, "1"),
        .hardware = .{
            .osu_path_md5 = osu_path_md5,
            .adapters_md5 = adapters_md5,
            .uninstall_md5 = uninstall_md5,
            .disk_signature_md5 = disk_signature_md5,
            .client_version = osu_version,
            .running_under_wine = running_under_wine,
            .actionable = !commonHardwareHash(adapters_md5) and !commonHardwareHash(uninstall_md5) and !commonHardwareHash(disk_signature_md5),
        },
    };
}
pub const session_idle_seconds: i64 = 300;

const SnapshotUser = struct {
    id: i32,
    name: []u8,
    country: [2]u8,
    privileges: u32,
    restricted: bool,
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
                .restricted = session.user.restricted,
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
    restricted: bool,
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
    const visible_privileges = if (s.user.restricted) s.user.privileges & ~@as(u32, 1) else s.user.privileges;
    try w.byte(clientPrivileges(visible_privileges, false) | (@as(u8, s.mode) << 5));
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

fn captureLoginLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, user: domain.User, utc: i8, longitude: f32, latitude: f32, friend_ids: []i32, block_non_friend_dms: bool, matched_user_ids: []const i32) !LoginCapture {
    var user_owned = true;
    errdefer if (user_owned) {
        allocator.free(user.name);
        allocator.free(user.safe_name);
    };
    for (matched_user_ids) |matched_user_id| if (sessions.byUser(matched_user_id)) |matched| removeSessionLocked(allocator, sessions, matched);
    if (sessions.byUser(user.id)) |old| removeSessionLocked(allocator, sessions, old);
    const session = try sessions.createWithSocial(user, utc, longitude, latitude, friend_ids, block_non_friend_dms);
    user_owned = false;
    errdefer sessions.remove(session);
    const token = try allocator.dupe(u8, &session.token);
    errdefer allocator.free(token);
    var capture: LoginCapture = .{
        .allocator = allocator,
        .token = token,
        .user_id = user.id,
        .silence_end = user.silence_end,
        .client_privileges = clientPrivileges(if (user.restricted) user.privileges & ~@as(u32, 1) else user.privileges, true),
        .osu_count = @intCast(sessions.channelCount("#osu")),
        .announce_count = @intCast(sessions.channelCount("#announce")),
        .restricted = user.restricted,
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
    const parsed = parseStableLoginDetails(details) catch {
        return loginFailure(allocator, "invalid-request", "Please restart osu! and try again.");
    };
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
    var enforcement = try store.recordClientHardware(user.id, parsed.hardware);
    defer enforcement.deinit();
    if (enforcement.restricted()) {
        user.restricted = true;
        std.log.warn("stable login restricted exact hardware match: user_id={d} matches={any}", .{ user.id, enforcement.matched_user_ids });
    }
    const response_friend_ids = try store.friendIds(allocator, user.id);
    defer allocator.free(response_friend_ids);
    const session_friend_ids = try allocator.dupe(i32, response_friend_ids);
    var friends_transferred = false;
    defer if (!friends_transferred) allocator.free(session_friend_ids);
    const unread_messages = try store.unreadDirectMessages(allocator, user.id);
    defer {
        for (unread_messages) |*message| message.deinit(allocator);
        allocator.free(unread_messages);
    }
    std.debug.print("{s}{s}╔══════════════════════════════════════════════════╗{s}\n", .{ log.magenta ++ log.bold, "", log.reset });
    std.debug.print("{s}{s}║  LOGIN — {s}{s}{s}{s}{s} ║{s}\n", .{ log.magenta ++ log.bold, "", log.green, name, log.reset, log.magenta ++ log.bold, "", log.reset });
    std.debug.print("{s}{s}╚══════════════════════════════════════════════════╝{s}\n", .{ log.magenta ++ log.bold, "", log.reset });
    std.debug.print("{s}  ► user_id  :{s} {d}\n", .{ log.dim, log.reset, user.id });
    const country_display: []const u8 = if (login_country) |c| &c else "??";
    std.debug.print("{s}  ► country  :{s} {s}\n", .{ log.dim, log.reset, country_display });
    std.debug.print("{s}  ► utc      :{s} {d}\n", .{ log.dim, log.reset, parsed.utc_offset });
    std.debug.print("{s}  ► client   :{s} {s} ({s})\n", .{ log.dim, log.reset, parsed.osu_version, if (parsed.hardware.running_under_wine) "wine" else "win32" });
    sessions.mutex.lockUncancelable(sessions.io);
    pruneExpiredLocked(allocator, sessions);
    user_transferred = true;
    friends_transferred = true;
    var capture = captureLoginLocked(allocator, sessions, user, parsed.utc_offset, longitude, latitude, session_friend_ids, parsed.pm_private, enforcement.matched_user_ids) catch |err| {
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
    try out.packetIntList(.friends_list, response_friend_ids);
    var unread_senders = std.AutoHashMap(i32, void).init(allocator);
    defer unread_senders.deinit();
    for (unread_messages) |message| {
        const sender = try unread_senders.getOrPut(message.from_id);
        if (!sender.found_existing) try protocol.writeMessage(&out, message.from_name, "Unread messages", own.user.name, message.from_id);
        try protocol.writeMessage(&out, message.from_name, message.message, own.user.name, message.from_id);
    }
    for (capture.sessions.items, 0..) |*other, index| if (index != own_index and !other.user.restricted) {
        try presence(&out, other);
        try stats(&out, store, other);
    };
    if (capture.restricted) {
        try out.packetEmpty(.account_restricted);
        try protocol.writeMessage(&out, "kai", "Your account is restricted. If this was a mistake, contact staff so we can review it.", own.user.name, 3);
    }
    var announce = protocol.Writer.init(allocator);
    defer announce.deinit();
    if (!capture.restricted) {
        try presence(&announce, own);
        try stats(&announce, store, own);
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
    return .{
        .allocator = allocator,
        .token = result_token,
        .body = result_body,
        .user_id = capture.user_id,
        .hardware_match_count = @intCast(@min(enforcement.matched_user_ids.len, std.math.maxInt(u32))),
        .running_under_wine = parsed.hardware.running_under_wine,
    };
}

fn queuePacket(target: *sessions_mod.Session, allocator: std.mem.Allocator, bytes: []const u8) !void {
    try target.enqueue(allocator, bytes);
}

const lobby_channel = "#lobby";
const multiplayer_channel = "#multiplayer";

fn writeDmBlocked(out: *protocol.Writer, target_name: []const u8) !void {
    const start = try out.begin(.user_dm_blocked);
    try out.string("");
    try out.string("");
    try out.string(target_name);
    try out.int(i32, 0);
    out.finish(start);
}

fn packetMatchId(payload: []const u8) ?u16 {
    if (payload.len != @sizeOf(i32)) return null;
    const raw = std.mem.readInt(i32, payload[0..4], .little);
    if (raw < 0 or raw >= multiplayer.max_matches) return null;
    return @intCast(raw);
}

fn packetUserId(payload: []const u8) ?i32 {
    if (payload.len != @sizeOf(i32)) return null;
    const user_id = std.mem.readInt(i32, payload[0..4], .little);
    return if (user_id > 0) user_id else null;
}

fn canUseTournament(session: *const sessions_mod.Session) bool {
    const supporter_or_premium: u32 = (1 << 4) | (1 << 5);
    return !session.user.restricted and session.user.privileges & supporter_or_premium != 0;
}

fn matchChannelCountLocked(sessions: *const sessions_mod.Sessions, match_id: u16) i32 {
    var count: usize = 0;
    for (sessions.items.items) |other| if (other.match_id == match_id or other.tournamentJoined(match_id)) {
        count += 1;
    };
    return @intCast(count);
}

fn queueLobbyChannelInfoLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, except: ?*sessions_mod.Session) !void {
    var info = protocol.Writer.init(allocator);
    defer info.deinit();
    try protocol.writeChannel(&info, lobby_channel, "multiplayer lobby", @intCast(sessions.channelCount(lobby_channel)));
    try sessions.broadcastChannel(lobby_channel, info.bytes(), except);
}

fn queueMatchChannelInfoLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, match_id: u16, except: ?*sessions_mod.Session) !void {
    var info = protocol.Writer.init(allocator);
    defer info.deinit();
    try protocol.writeChannel(&info, multiplayer_channel, "multiplayer", matchChannelCountLocked(sessions, match_id));
    for (sessions.items.items) |other| {
        if (other != except and !other.is_bot and (other.match_id == match_id or other.tournamentJoined(match_id))) {
            try other.enqueue(allocator, info.bytes());
        }
    }
}

fn closeLobbyLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, session: *sessions_mod.Session, response: ?*protocol.Writer) !void {
    const was_joined = session.joined_lobby_channel;
    session.in_lobby = false;
    session.joined_lobby_channel = false;
    if (!was_joined) return;
    if (response) |out| try out.packetString(.channel_kick, lobby_channel);
    try queueLobbyChannelInfoLocked(allocator, sessions, session);
}

fn broadcastMatchChatLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, match_id: u16, bytes: []const u8, except: ?*sessions_mod.Session) !void {
    for (sessions.items.items) |other| {
        if (other != except and !other.is_bot and (other.match_id == match_id or other.tournamentJoined(match_id))) {
            try other.enqueue(allocator, bytes);
        }
    }
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
        if (other.match_id == match.id or other.tournamentJoined(match.id)) {
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
    var channel_kick = protocol.Writer.init(allocator);
    defer channel_kick.deinit();
    try channel_kick.packetString(.channel_kick, multiplayer_channel);
    for (sessions.items.items) |other| {
        if (other.tournamentJoined(match_id)) try other.enqueue(allocator, channel_kick.bytes());
        other.partTournament(match_id);
        if (!other.is_bot and other.in_lobby) try other.enqueue(allocator, event.bytes());
    }
}

fn containsUser(ids: []const i32, user_id: i32) bool {
    for (ids) |id| if (id == user_id) return true;
    return false;
}

fn spectatorCountLocked(sessions: *const sessions_mod.Sessions, host_id: i32) usize {
    var count: usize = 0;
    for (sessions.items.items) |other| if (other.spectating_user_id == host_id) {
        count += 1;
    };
    return count;
}

fn queueSpectatorChannelInfoLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, host_id: i32) !void {
    const count = spectatorCountLocked(sessions, host_id);
    if (count == 0) return;
    var info = protocol.Writer.init(allocator);
    defer info.deinit();
    try protocol.writeChannel(&info, "#spectator", "spectator", @intCast(count + 1));
    for (sessions.items.items) |other| {
        if (other.user.id == host_id or other.spectating_user_id == host_id) try other.enqueue(allocator, info.bytes());
    }
}

fn detachSpectatorLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, spectator: *sessions_mod.Session) !void {
    const host_id = spectator.spectating_user_id orelse return;
    const host = sessions.byUser(host_id);
    spectator.spectating_user_id = null;

    var kick = protocol.Writer.init(allocator);
    defer kick.deinit();
    try kick.packetString(.channel_kick, "#spectator");
    try spectator.enqueue(allocator, kick.bytes());

    const remaining = spectatorCountLocked(sessions, host_id);
    if (host) |current_host| {
        if (remaining == 0) {
            try current_host.enqueue(allocator, kick.bytes());
        } else {
            try queueSpectatorChannelInfoLocked(allocator, sessions, host_id);
        }
        var left = protocol.Writer.init(allocator);
        defer left.deinit();
        try left.packetInt(.spectator_left, spectator.user.id);
        try current_host.enqueue(allocator, left.bytes());
    }

    if (remaining > 0) {
        var fellow_left = protocol.Writer.init(allocator);
        defer fellow_left.deinit();
        try fellow_left.packetInt(.fellow_spectator_left, spectator.user.id);
        for (sessions.items.items) |other| if (other.spectating_user_id == host_id) {
            try other.enqueue(allocator, fellow_left.bytes());
        };
    }
}

fn attachSpectatorLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, spectator: *sessions_mod.Session, host: *sessions_mod.Session) !void {
    if (spectator == host or spectator.is_bot or host.is_bot) return;
    if (spectator.spectating_user_id == host.user.id) {
        var joined_again = protocol.Writer.init(allocator);
        defer joined_again.deinit();
        try joined_again.packetInt(.spectator_joined, spectator.user.id);
        try host.enqueue(allocator, joined_again.bytes());
        var fellow_again = protocol.Writer.init(allocator);
        defer fellow_again.deinit();
        try fellow_again.packetInt(.fellow_spectator_joined, spectator.user.id);
        for (sessions.items.items) |other| if (other != spectator and other.spectating_user_id == host.user.id) {
            try other.enqueue(allocator, fellow_again.bytes());
        };
        return;
    }
    if (spectator.spectating_user_id != null) try detachSpectatorLocked(allocator, sessions, spectator);

    const first = spectatorCountLocked(sessions, host.user.id) == 0;
    var channel_join = protocol.Writer.init(allocator);
    defer channel_join.deinit();
    try channel_join.packetString(.channel_join_success, "#spectator");
    if (first) {
        try host.enqueue(allocator, channel_join.bytes());
        var host_only_info = protocol.Writer.init(allocator);
        defer host_only_info.deinit();
        try protocol.writeChannel(&host_only_info, "#spectator", "spectator", 1);
        try host.enqueue(allocator, host_only_info.bytes());
    }
    try spectator.enqueue(allocator, channel_join.bytes());

    var new_spectator_events = protocol.Writer.init(allocator);
    defer new_spectator_events.deinit();
    var fellow_joined = protocol.Writer.init(allocator);
    defer fellow_joined.deinit();
    try fellow_joined.packetInt(.fellow_spectator_joined, spectator.user.id);
    for (sessions.items.items) |other| if (other.spectating_user_id == host.user.id) {
        try new_spectator_events.packetInt(.fellow_spectator_joined, other.user.id);
    };
    spectator.spectating_user_id = host.user.id;
    errdefer spectator.spectating_user_id = null;
    try queueSpectatorChannelInfoLocked(allocator, sessions, host.user.id);
    for (sessions.items.items) |other| if (other != spectator and other.spectating_user_id == host.user.id) {
        try other.enqueue(allocator, fellow_joined.bytes());
    };
    try spectator.enqueue(allocator, new_spectator_events.bytes());
    var joined = protocol.Writer.init(allocator);
    defer joined.deinit();
    try joined.packetInt(.spectator_joined, spectator.user.id);
    try host.enqueue(allocator, joined.bytes());
}

fn clearSpectatorsForHostLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, host: *sessions_mod.Session) void {
    var kick = protocol.Writer.init(allocator);
    defer kick.deinit();
    kick.packetString(.channel_kick, "#spectator") catch return;
    for (sessions.items.items) |other| if (other.spectating_user_id == host.user.id) {
        other.spectating_user_id = null;
        other.enqueue(allocator, kick.bytes()) catch {};
    };
}

fn broadcastSpectatorChatLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, sender: *sessions_mod.Session, bytes: []const u8) !bool {
    const host_id = sender.spectating_user_id orelse if (spectatorCountLocked(sessions, sender.user.id) > 0) sender.user.id else return false;
    for (sessions.items.items) |other| {
        if (other == sender or other.is_bot) continue;
        if (other.user.id == host_id or other.spectating_user_id == host_id) try other.enqueue(allocator, bytes);
    }
    return true;
}

fn broadcastMatchPacketLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, match_id: u16, bytes: []const u8, include_lobby: bool, immune: []const i32) !void {
    for (sessions.items.items) |other| {
        if (other.is_bot) continue;
        if (other.match_id == match_id or other.tournamentJoined(match_id)) {
            if (!containsUser(immune, other.user.id)) try other.enqueue(allocator, bytes);
        } else if (include_lobby and other.in_lobby) {
            try other.enqueue(allocator, bytes);
        }
    }
}

fn sendMatchBotLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, match_id: u16, text: []const u8) !void {
    var message = protocol.Writer.init(allocator);
    defer message.deinit();
    try protocol.writeMessage(&message, "kai", text, multiplayer_channel, 3);
    try broadcastMatchChatLocked(allocator, sessions, match_id, message.bytes(), null);
}

fn handleMultiplayerCommandLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, session: *sessions_mod.Session, target_name: []const u8, text: []const u8) !bool {
    if (text.len < 3 or !std.ascii.eqlIgnoreCase(text[0..3], "!mp") or (text.len > 3 and text[3] != ' ')) return false;
    const match_id = session.match_id orelse return true;
    if (!std.mem.eql(u8, target_name, multiplayer_channel)) return true;
    const match = sessions.matchById(match_id) orelse return true;

    var tokens = std.mem.tokenizeScalar(u8, std.mem.trim(u8, text[3..], " \t"), ' ');
    const command = tokens.next() orelse "help";
    const is_known = std.ascii.eqlIgnoreCase(command, "help") or
        std.ascii.eqlIgnoreCase(command, "h") or
        std.ascii.eqlIgnoreCase(command, "abort") or
        std.ascii.eqlIgnoreCase(command, "a") or
        std.ascii.eqlIgnoreCase(command, "addref") or
        std.ascii.eqlIgnoreCase(command, "rmref") or
        std.ascii.eqlIgnoreCase(command, "listref");
    if (!is_known) return false;
    const tournament_manager: u32 = 1 << 10;
    if (!match.isReferee(session.user.id) and session.user.privileges & tournament_manager == 0) return true;

    if (std.ascii.eqlIgnoreCase(command, "help") or std.ascii.eqlIgnoreCase(command, "h")) {
        try sendMatchBotLocked(allocator, sessions, match_id, "commands: !mp abort | !mp addref <name> | !mp rmref <name> | !mp listref");
        return true;
    }
    if (std.ascii.eqlIgnoreCase(command, "abort") or std.ascii.eqlIgnoreCase(command, "a")) {
        if (tokens.next() != null) {
            try sendMatchBotLocked(allocator, sessions, match_id, "Invalid syntax: !mp abort");
            return true;
        }
        if (!match.in_progress) {
            try sendMatchBotLocked(allocator, sessions, match_id, "Abort what?");
            return true;
        }
        for (&match.slots) |*slot| {
            if (slot.status == @intFromEnum(multiplayer.SlotStatus.playing)) slot.status = @intFromEnum(multiplayer.SlotStatus.not_ready);
            slot.loaded = false;
            slot.skipped = false;
        }
        match.in_progress = false;
        var abort_event = protocol.Writer.init(allocator);
        defer abort_event.deinit();
        try abort_event.packetEmpty(.match_abort);
        try broadcastMatchPacketLocked(allocator, sessions, match_id, abort_event.bytes(), false, &.{});
        try broadcastMatchStateLocked(allocator, sessions, match, true);
        try sendMatchBotLocked(allocator, sessions, match_id, "Match aborted.");
        return true;
    }

    const target_name_arg = tokens.next();
    if (std.ascii.eqlIgnoreCase(command, "listref")) {
        if (target_name_arg != null) {
            try sendMatchBotLocked(allocator, sessions, match_id, "Invalid syntax: !mp listref");
            return true;
        }
        var refs: std.ArrayList(u8) = .empty;
        defer refs.deinit(allocator);
        if (sessions.byUser(match.host_id)) |host| try refs.appendSlice(allocator, host.user.name);
        for (match.referees) |referee_id| if (referee_id) |user_id| if (user_id != match.host_id) if (sessions.byUser(user_id)) |referee| {
            if (refs.items.len > 0) try refs.appendSlice(allocator, ", ");
            try refs.appendSlice(allocator, referee.user.name);
        };
        try refs.append(allocator, '.');
        try sendMatchBotLocked(allocator, sessions, match_id, refs.items);
        return true;
    }

    if (target_name_arg == null or tokens.next() != null) {
        const syntax = if (std.ascii.eqlIgnoreCase(command, "addref")) "Invalid syntax: !mp addref <name>" else "Invalid syntax: !mp rmref <name>";
        try sendMatchBotLocked(allocator, sessions, match_id, syntax);
        return true;
    }
    const target = sessions.byName(target_name_arg.?) orelse {
        try sendMatchBotLocked(allocator, sessions, match_id, "Could not find a user by that name.");
        return true;
    };
    if (std.ascii.eqlIgnoreCase(command, "addref")) {
        if (match.slotByUser(target.user.id) == null) {
            try sendMatchBotLocked(allocator, sessions, match_id, "User must be in the current match!");
        } else if (!match.addReferee(target.user.id)) {
            var response_buffer: [128]u8 = undefined;
            try sendMatchBotLocked(allocator, sessions, match_id, try std.fmt.bufPrint(&response_buffer, "{s} is already a match referee!", .{target.user.name}));
        } else {
            var response_buffer: [128]u8 = undefined;
            try sendMatchBotLocked(allocator, sessions, match_id, try std.fmt.bufPrint(&response_buffer, "{s} added to match referees.", .{target.user.name}));
        }
        return true;
    }
    if (target.user.id == match.host_id) {
        try sendMatchBotLocked(allocator, sessions, match_id, "The host is always a referee!");
    } else if (!match.removeReferee(target.user.id)) {
        var response_buffer: [128]u8 = undefined;
        try sendMatchBotLocked(allocator, sessions, match_id, try std.fmt.bufPrint(&response_buffer, "{s} is not a match referee!", .{target.user.name}));
    } else {
        var response_buffer: [128]u8 = undefined;
        try sendMatchBotLocked(allocator, sessions, match_id, try std.fmt.bufPrint(&response_buffer, "{s} removed from match referees.", .{target.user.name}));
    }
    return true;
}

fn leaveMatchLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, session: *sessions_mod.Session, response: ?*protocol.Writer) void {
    const match_id = session.match_id orelse return;
    if (response) |out| out.packetString(.channel_kick, multiplayer_channel) catch {};
    const match = sessions.matchById(match_id) orelse {
        session.match_id = null;
        return;
    };
    const slot = match.slotByUser(session.user.id) orelse {
        session.match_id = null;
        return;
    };
    const next_status: multiplayer.SlotStatus = if (slot.status == @intFromEnum(multiplayer.SlotStatus.locked)) .locked else .open;
    _ = match.removeReferee(session.user.id);
    slot.reset(next_status);
    session.match_id = null;
    queueMatchChannelInfoLocked(allocator, sessions, match_id, session) catch {};
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
    closeLobbyLocked(allocator, sessions, session, null) catch {};
    leaveMatchLocked(allocator, sessions, session, null);
    detachSpectatorLocked(allocator, sessions, session) catch {};
    clearSpectatorsForHostLocked(allocator, sessions, session);
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
            try out.raw(event.bytes());
            try sessions.broadcast(event.bytes(), session);
        },
        .friend_add => {
            const friend_id = packetUserId(packet.payload) orelse continue;
            if (friend_id == session.user.id or friend_id == 3 or session.isFriend(friend_id)) continue;
            if (sessions.byUser(friend_id) == null) {
                const found = (try store.userById(allocator, friend_id)) orelse continue;
                allocator.free(found.name);
                allocator.free(found.safe_name);
            }
            try session.friend_ids.ensureUnusedCapacity(allocator, 1);
            _ = try store.addFriend(session.user.id, friend_id);
            session.friend_ids.appendAssumeCapacity(friend_id);
        },
        .friend_remove => {
            const friend_id = packetUserId(packet.payload) orelse continue;
            if (friend_id == 3) continue;
            _ = try store.removeFriend(session.user.id, friend_id);
            session.removeFriend(friend_id);
        },
        .receive_updates => {
            if (packet.payload.len != @sizeOf(i32)) continue;
            const value = std.mem.readInt(i32, packet.payload[0..4], .little);
            if (value >= 0 and value <= 2) session.presence_filter = @intCast(value);
        },
        .set_away_message => {
            var p: protocol.PayloadReader = .{ .data = packet.payload };
            _ = try p.string();
            const message = try p.string();
            _ = try p.string();
            _ = try p.int(i32);
            if (message.len > session.away_message.len or std.mem.indexOfScalar(u8, message, 0) != null or !std.unicode.utf8ValidateSlice(message)) continue;
            session.away_message_len = message.len;
            @memcpy(session.away_message[0..message.len], message);
        },
        .toggle_block_non_friend_dms => {
            if (packet.payload.len != @sizeOf(i32)) continue;
            const value = std.mem.readInt(i32, packet.payload[0..4], .little);
            if (value == 0 or value == 1) session.block_non_friend_dms = value == 1;
        },
        .send_public_message, .send_private_message => {
            var p: protocol.PayloadReader = .{ .data = packet.payload };
            _ = try p.string();
            const text = std.mem.trim(u8, try p.string(), " \t\r\n");
            const target_name = try p.string();
            _ = try p.int(i32);
            if (text.len == 0 or text.len > 2000 or std.mem.indexOfScalar(u8, text, 0) != null) continue;
            if (session.user.restricted) continue;
            if (session.user.silence_end > now) {
                try out.packetInt(.silence_end, @intCast(@min(@as(i64, std.math.maxInt(i32)), session.user.silence_end - now)));
                continue;
            }
            if (packet.id == .send_public_message and !try store.channelCanWrite(target_name, session.user.privileges)) {
                try out.packetString(.notification, "that channel is read-only right now");
                continue;
            }
            if (packet.id == .send_private_message) {
                if (sessions.byName(target_name)) |target| {
                    if (target.is_bot) {
                        if (try commands.handleNowPlaying(allocator, store, session, text)) continue;
                        if (try commands.handleCommand(allocator, store, sessions, session, text, session.user.name, &out) == .handled) continue;
                        try protocol.writeMessage(&out, "kai", "send /np here for pp, then use !with for a custom play", session.user.name, 3);
                        continue;
                    }
                }
            }
            _ = if (packet.id == .send_public_message) try commands.handleNowPlaying(allocator, store, session, text) else false;
            if (packet.id == .send_public_message and try handleMultiplayerCommandLocked(allocator, sessions, session, target_name, text)) continue;
            if (packet.id == .send_public_message and text[0] == '!' and !std.mem.eql(u8, target_name, multiplayer_channel) and !std.mem.eql(u8, target_name, "#spectator")) {
                if (try commands.handleCommand(allocator, store, sessions, session, text, target_name, &out) == .handled) continue;
            }
            var message = protocol.Writer.init(allocator);
            defer message.deinit();
            try protocol.writeMessage(&message, session.user.name, text, target_name, session.user.id);
            if (packet.id == .send_private_message) {
                if (sessions.byName(target_name)) |target| {
                    if (!target.is_bot) {
                        if (target.block_non_friend_dms and !target.isFriend(session.user.id)) {
                            try writeDmBlocked(&out, target.user.name);
                            continue;
                        }
                        if (target.user.silence_end > now or target.user.restricted) {
                            var blocked = protocol.Writer.init(allocator);
                            defer blocked.deinit();
                            const start = try blocked.begin(.target_is_silenced);
                            try blocked.string("");
                            try blocked.string("");
                            try blocked.string(target.user.name);
                            try blocked.int(i32, 0);
                            blocked.finish(start);
                            try out.raw(blocked.bytes());
                            continue;
                        }
                        if (!try store.directMessageAllowed(session.user.id, target.user.id)) {
                            try writeDmBlocked(&out, target.user.name);
                            continue;
                        }
                        if (target.action == 1 and target.away().len != 0) {
                            try protocol.writeMessage(&out, target.user.name, target.away(), session.user.name, target.user.id);
                        }
                        store.storeDirectMessage(session.user.id, target.user.id, text) catch |err| switch (err) {
                            error.DirectMessageBlocked => {
                                try writeDmBlocked(&out, target.user.name);
                                continue;
                            },
                            else => return err,
                        };
                        try queuePacket(target, allocator, message.bytes());
                        store.markDirectMessagesRead(target.user.id, session.user.id) catch |err| std.log.warn("direct message read state failed: {s}", .{@errorName(err)});
                    }
                } else if (try store.userByName(allocator, target_name)) |target_user| {
                    defer {
                        allocator.free(target_user.name);
                        allocator.free(target_user.safe_name);
                    }
                    if (target_user.silence_end > now or target_user.restricted) {
                        const start = try out.begin(.target_is_silenced);
                        try out.string("");
                        try out.string("");
                        try out.string(target_user.name);
                        try out.int(i32, 0);
                        out.finish(start);
                        continue;
                    }
                    if (!try store.directMessageAllowed(session.user.id, target_user.id)) {
                        try writeDmBlocked(&out, target_user.name);
                        continue;
                    }
                    store.storeDirectMessage(session.user.id, target_user.id, text) catch |err| switch (err) {
                        error.DirectMessageBlocked => {
                            try writeDmBlocked(&out, target_user.name);
                            continue;
                        },
                        else => return err,
                    };
                    var notice_buf: [192]u8 = undefined;
                    const notice = try std.fmt.bufPrint(&notice_buf, "{s} is offline, but they'll get your message when they next log in.", .{target_user.name});
                    try out.packetString(.notification, notice);
                }
            } else {
                if (std.mem.eql(u8, target_name, "#spectator")) {
                    if (try broadcastSpectatorChatLocked(allocator, sessions, session, message.bytes())) {
                        const host_id = session.spectating_user_id orelse session.user.id;
                        var history_target_buf: [32]u8 = undefined;
                        const history_target = try std.fmt.bufPrint(&history_target_buf, "#spectator_{d}", .{host_id});
                        store.recordPublicMessage(session.user.id, history_target, text) catch |err| std.log.warn("chat history write failed: {s}", .{@errorName(err)});
                    }
                    continue;
                }
                if (std.mem.eql(u8, target_name, multiplayer_channel)) {
                    const match_id = session.visibleMatchId() orelse continue;
                    try broadcastMatchChatLocked(allocator, sessions, match_id, message.bytes(), session);
                    var history_target_buf: [32]u8 = undefined;
                    const history_target = try std.fmt.bufPrint(&history_target_buf, "#multi_{d}", .{match_id});
                    store.recordPublicMessage(session.user.id, history_target, text) catch |err| std.log.warn("chat history write failed: {s}", .{@errorName(err)});
                    continue;
                }
                if (!session.joined(target_name)) continue;
                try sessions.broadcastChannel(target_name, message.bytes(), session);
                store.recordPublicMessage(session.user.id, target_name, text) catch |err| std.log.warn("chat history write failed: {s}", .{@errorName(err)});
            }
        },
        .join_lobby => {
            if (session.match_id != null) continue;
            const newly_joined = !session.joined_lobby_channel;
            session.in_lobby = true;
            session.joined_lobby_channel = true;
            if (newly_joined) try out.packetString(.channel_join_success, lobby_channel);
            try protocol.writeChannel(&out, lobby_channel, "multiplayer lobby", @intCast(sessions.channelCount(lobby_channel)));
            if (newly_joined) try queueLobbyChannelInfoLocked(allocator, sessions, session);
            for (&sessions.matches) |*entry| if (entry.*) |*match| try multiplayer.writePacket(&out, .new_match, match, false);
        },
        .part_lobby => try closeLobbyLocked(allocator, sessions, session, &out),
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
            try out.packetString(.channel_join_success, multiplayer_channel);
            try protocol.writeChannel(&out, multiplayer_channel, "multiplayer", matchChannelCountLocked(sessions, match_id));
            try closeLobbyLocked(allocator, sessions, session, &out);
            try multiplayer.writePacket(&out, .match_join_success, match, true);
            try queueMatchChannelInfoLocked(allocator, sessions, match_id, session);
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
            if (session.tournamentJoined(match_id)) {
                try out.packetEmpty(.match_join_fail);
                continue;
            }
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
            try out.packetString(.channel_join_success, multiplayer_channel);
            try protocol.writeChannel(&out, multiplayer_channel, "multiplayer", matchChannelCountLocked(sessions, match_id));
            try closeLobbyLocked(allocator, sessions, session, &out);
            try multiplayer.writePacket(&out, .match_join_success, match, true);
            try queueMatchChannelInfoLocked(allocator, sessions, match_id, session);
            try broadcastMatchStateLocked(allocator, sessions, match, true);
        },
        .part_match => leaveMatchLocked(allocator, sessions, session, &out),
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
                    _ = match.removeReferee(target_id);
                    target.match_id = null;
                    var kicked = protocol.Writer.init(allocator);
                    defer kicked.deinit();
                    try kicked.packetEmpty(.match_join_fail);
                    try kicked.packetString(.channel_kick, multiplayer_channel);
                    try target.enqueue(allocator, kicked.bytes());
                    try queueMatchChannelInfoLocked(allocator, sessions, match.id, target);
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
        .match_invite => {
            const target_id = packetUserId(packet.payload) orelse continue;
            const match = sessions.matchById(session.match_id orelse continue) orelse continue;
            const target = sessions.byUser(target_id) orelse continue;
            if (target.is_bot) {
                try protocol.writeMessage(&out, "kai", "I'm too busy!", session.user.name, 3);
                continue;
            }
            const text = try std.fmt.allocPrint(allocator, "Come join my game: [osump://{d}/{s} {s}].", .{ match.id, match.password, match.name });
            defer allocator.free(text);
            var invite = protocol.Writer.init(allocator);
            defer invite.deinit();
            try protocol.writeMessagePacket(&invite, .match_invite, session.user.name, text, target.user.name, session.user.id);
            try target.enqueue(allocator, invite.bytes());
        },
        .tournament_match_info => {
            const match_id = packetMatchId(packet.payload) orelse continue;
            if (!canUseTournament(session)) continue;
            const match = sessions.matchById(match_id) orelse continue;
            try multiplayer.writePacket(&out, .update_match, match, false);
        },
        .tournament_join_match_channel => {
            const match_id = packetMatchId(packet.payload) orelse continue;
            if (!canUseTournament(session) or session.tournamentJoined(match_id)) continue;
            const match = sessions.matchById(match_id) orelse continue;
            if (match.slotByUser(session.user.id) != null) continue;
            session.joinTournament(match_id);
            try out.packetString(.channel_join_success, multiplayer_channel);
            try protocol.writeChannel(&out, multiplayer_channel, "multiplayer", matchChannelCountLocked(sessions, match_id));
            try queueMatchChannelInfoLocked(allocator, sessions, match_id, session);
        },
        .tournament_leave_match_channel => {
            const match_id = packetMatchId(packet.payload) orelse continue;
            if (!canUseTournament(session) or !session.tournamentJoined(match_id)) continue;
            session.partTournament(match_id);
            try out.packetString(.channel_kick, multiplayer_channel);
            if (sessions.matchById(match_id) != null) {
                try queueMatchChannelInfoLocked(allocator, sessions, match_id, session);
            }
        },
        .channel_join => {
            var p: protocol.PayloadReader = .{ .data = packet.payload };
            const name = try p.string();
            if (sessions.join(session, name)) {
                try out.packetString(.channel_join_success, name);
                if (std.mem.eql(u8, name, lobby_channel)) {
                    try protocol.writeChannel(&out, lobby_channel, "multiplayer lobby", @intCast(sessions.channelCount(lobby_channel)));
                    try queueLobbyChannelInfoLocked(allocator, sessions, session);
                }
            }
        },
        .channel_part => {
            var p: protocol.PayloadReader = .{ .data = packet.payload };
            const name = try p.string();
            sessions.part(session, name);
            if (std.mem.eql(u8, name, lobby_channel)) {
                session.in_lobby = false;
                try queueLobbyChannelInfoLocked(allocator, sessions, session);
            }
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
        .user_presence_request_all => {
            if (packet.payload.len != @sizeOf(i32)) continue;
            for (sessions.items.items) |target| if (!target.user.restricted) try presence(&out, target);
        },
        .start_spectating => {
            const target_id = packetUserId(packet.payload) orelse continue;
            const host = sessions.byUser(target_id) orelse continue;
            try attachSpectatorLocked(allocator, sessions, session, host);
        },
        .stop_spectating => {
            if (packet.payload.len != 0) continue;
            try detachSpectatorLocked(allocator, sessions, session);
        },
        .spectate_frames => {
            if (packet.payload.len == 0) continue;
            var e = protocol.Writer.init(allocator);
            defer e.deinit();
            const st = try e.begin(.spectate_frames);
            try e.raw(packet.payload);
            e.finish(st);
            for (sessions.items.items) |other| if (other.spectating_user_id == session.user.id) {
                try other.enqueue(allocator, e.bytes());
            };
        },
        .cant_spectate => {
            if (packet.payload.len != 0) continue;
            const host_id = session.spectating_user_id orelse continue;
            var event = protocol.Writer.init(allocator);
            defer event.deinit();
            try event.packetInt(.spectator_cant_spectate, session.user.id);
            for (sessions.items.items) |other| {
                if (other.user.id == host_id or other.spectating_user_id == host_id) try other.enqueue(allocator, event.bytes());
            }
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

pub fn disconnectRestrictedUser(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, user_id: i32) void {
    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    const session = sessions.byUser(user_id) orelse return;
    if (!session.is_bot) removeSessionLocked(allocator, sessions, session);
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

pub fn publishAnnouncement(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, text: []const u8) !void {
    var message = protocol.Writer.init(allocator);
    defer message.deinit();
    try protocol.writeMessage(&message, "kai", text, "#announce", 3);
    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    try sessions.broadcastChannel("#announce", message.bytes(), null);
}
