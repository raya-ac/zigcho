const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const sessions_mod = @import("sessions.zig");
const storage = @import("runtime_storage.zig");
const domain = @import("domain.zig");
const stable_score = @import("stable_score.zig");
const country = @import("country.zig");
const commands = @import("commands.zig");
const log = @import("logutil.zig");
const multiplayer = @import("multiplayer.zig");
const stable_login = @import("stable_login.zig");
const storage_contracts = @import("storage/contracts.zig");

pub const LoginResult = struct {
    allocator: std.mem.Allocator,
    token: []u8,
    body: []u8,
    user_id: i32 = 0,
    hardware_match_count: u32 = 0,
    running_under_wine: bool = false,
    client_binding: ?sessions_mod.StableClientBinding = null,

    pub fn deinit(self: *LoginResult) void {
        self.allocator.free(self.token);
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

pub const StableLoginDetails = stable_login.Details;
pub const parseStableLoginDetails = stable_login.parse;
pub const session_idle_seconds: i64 = 300;
pub const lazer_presence_lease_seconds: i64 = 120;

const SnapshotUser = struct {
    id: i32,
    name: []u8,
    country: [2]u8,
    show_country: bool,
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
                .country = if (session.user.show_country) session.user.country else .{ 'X', 'X' },
                .show_country = session.user.show_country,
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

const StableStatsUser = struct { id: i32 };

/// A fixed-size copy of every session field needed to build a Stable stats
/// packet. It can cross the session-mutex boundary without retaining a Session
/// pointer or borrowing user-owned memory.
const StableStatsSnapshot = struct {
    user: StableStatsUser,
    generation: u64,
    action: u8,
    mode: u8,
    mods: i32,
    map_id: i32,
    map_md5: [32]u8,
    info_text: [96]u8,
    info_len: usize,

    fn init(session: *const sessions_mod.Session) StableStatsSnapshot {
        return .{
            .user = .{ .id = session.user.id },
            .generation = session.generation,
            .action = session.action,
            .mode = session.mode,
            .mods = session.mods,
            .map_id = session.map_id,
            .map_md5 = session.map_md5,
            .info_text = session.info_text,
            .info_len = session.info_len,
        };
    }

    fn info(self: *const StableStatsSnapshot) []const u8 {
        return self.info_text[0..self.info_len];
    }
};

fn applyStableAction(target: anytype, payload: []const u8) !void {
    var reader: protocol.PayloadReader = .{ .data = payload };
    target.action = try reader.byte();
    const info = try reader.string();
    const md5 = try reader.string();
    target.mods = try reader.int(i32);
    target.mode = try reader.byte();
    target.map_id = try reader.int(i32);
    target.info_len = @min(info.len, target.info_text.len);
    @memcpy(target.info_text[0..target.info_len], info[0..target.info_len]);
    @memset(&target.map_md5, 0);
    @memcpy(target.map_md5[0..@min(32, md5.len)], md5[0..@min(32, md5.len)]);
}

const StableStatsRequest = struct {
    packet_index: usize,
    snapshot: StableStatsSnapshot,
};

const CapturedDmTarget = struct {
    user_id: i32,
    generation: u64,
    name: [96]u8 = [_]u8{0} ** 96,
    name_len: usize = 0,
    block_non_friend_dms: bool,
    sender_is_friend: bool,
    away_message: [512]u8 = [_]u8{0} ** 512,
    away_message_len: usize = 0,

    fn init(target: *const sessions_mod.Session, sender_id: i32) CapturedDmTarget {
        var result: CapturedDmTarget = .{
            .user_id = target.user.id,
            .generation = target.generation,
            .block_non_friend_dms = target.block_non_friend_dms,
            .sender_is_friend = target.isFriend(sender_id),
        };
        result.name_len = @min(target.user.name.len, result.name.len);
        @memcpy(result.name[0..result.name_len], target.user.name[0..result.name_len]);
        if (target.action == 1) {
            result.away_message_len = @min(target.away().len, result.away_message.len);
            @memcpy(result.away_message[0..result.away_message_len], target.away()[0..result.away_message_len]);
        }
        return result;
    }

    fn nameText(self: *const CapturedDmTarget) []const u8 {
        return self.name[0..self.name_len];
    }

    fn away(self: *const CapturedDmTarget) []const u8 {
        return self.away_message[0..self.away_message_len];
    }
};

const StableDirectMessageRequest = struct {
    packet_index: usize,
    sender_id: i32,
    target_name: []u8,
    message: []u8,
    online_target: ?CapturedDmTarget,
};

const StableCommandRequest = struct {
    packet_index: usize,
    sender_id: i32,
    text: []u8,
    target: []u8,
    private_bot: bool,
    run_now_playing: bool,
    run_command: bool,
};

const StableDbRequest = union(enum) {
    friend_add: struct { packet_index: usize, user_id: i32, friend_id: i32 },
    friend_remove: struct { packet_index: usize, user_id: i32, friend_id: i32 },
    channel_write: struct { packet_index: usize, target: []u8, privileges: u32 },
    direct_message: StableDirectMessageRequest,
    command: StableCommandRequest,

    fn deinit(self: *StableDbRequest, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .channel_write => |request| allocator.free(request.target),
            .direct_message => |request| {
                allocator.free(request.target_name);
                allocator.free(request.message);
            },
            .command => |request| {
                allocator.free(request.text);
                allocator.free(request.target);
            },
            else => {},
        }
        self.* = undefined;
    }

    fn packetIndex(self: StableDbRequest) usize {
        return switch (self) {
            inline else => |request| request.packet_index,
        };
    }
};

const StablePollCapture = struct {
    allocator: std.mem.Allocator,
    owner_user_id: i32,
    owner_generation: u64,
    owner_restricted: bool,
    owner_name: [96]u8 = [_]u8{0} ** 96,
    owner_name_len: usize = 0,
    requests: std.ArrayList(StableStatsRequest) = .empty,
    db_requests: std.ArrayList(StableDbRequest) = .empty,
    command_world: ?sessions_mod.Sessions = null,

    fn deinit(self: *StablePollCapture) void {
        self.requests.deinit(self.allocator);
        for (self.db_requests.items) |*request| request.deinit(self.allocator);
        self.db_requests.deinit(self.allocator);
        if (self.command_world) |*world| world.deinit();
        self.* = undefined;
    }

    fn hasRequest(self: *const StablePollCapture, packet_index: usize, user_id: i32, generation: u64) bool {
        for (self.requests.items) |request| if (request.packet_index == packet_index and request.snapshot.user.id == user_id and request.snapshot.generation == generation) return true;
        return false;
    }

    fn append(self: *StablePollCapture, packet_index: usize, snapshot: StableStatsSnapshot) !void {
        if (self.hasRequest(packet_index, snapshot.user.id, snapshot.generation)) return;
        try self.requests.append(self.allocator, .{ .packet_index = packet_index, .snapshot = snapshot });
    }

    fn ownerName(self: *const StablePollCapture) []const u8 {
        return self.owner_name[0..self.owner_name_len];
    }

    fn appendCommand(self: *StablePollCapture, sessions: *sessions_mod.Sessions, packet_index: usize, text: []const u8, target: []const u8, private_bot: bool, run_now_playing: bool, run_command: bool) !void {
        if (self.command_world == null) self.command_world = try cloneCommandWorld(self.allocator, sessions);
        const owned_text = try self.allocator.dupe(u8, text);
        const owned_target = self.allocator.dupe(u8, target) catch |err| {
            self.allocator.free(owned_text);
            return err;
        };
        self.db_requests.append(self.allocator, .{ .command = .{
            .packet_index = packet_index,
            .sender_id = self.owner_user_id,
            .text = owned_text,
            .target = owned_target,
            .private_bot = private_bot,
            .run_now_playing = run_now_playing,
            .run_command = run_command,
        } }) catch |err| {
            self.allocator.free(owned_text);
            self.allocator.free(owned_target);
            return err;
        };
    }
};

fn cloneCommandWorld(allocator: std.mem.Allocator, source: *const sessions_mod.Sessions) !sessions_mod.Sessions {
    var clone = sessions_mod.Sessions.init(allocator, source.io);
    errdefer clone.deinit();
    for (source.items.items) |original| {
        var user = original.user;
        const owned_name = try allocator.dupe(u8, original.user.name);
        const owned_safe_name = allocator.dupe(u8, original.user.safe_name) catch |err| {
            allocator.free(owned_name);
            return err;
        };
        user.name = owned_name;
        user.safe_name = owned_safe_name;
        user.team = null;
        const replica = (if (original.is_bot) clone.createBot(user) else clone.create(user, original.utc_offset, original.longitude, original.latitude)) catch |err| {
            allocator.free(owned_name);
            allocator.free(owned_safe_name);
            return err;
        };
        replica.generation = original.generation;
        replica.action = original.action;
        replica.mode = original.mode;
        replica.mods = original.mods;
        replica.map_id = original.map_id;
        replica.map_md5 = original.map_md5;
        replica.info_text = original.info_text;
        replica.info_len = original.info_len;
        replica.block_non_friend_dms = original.block_non_friend_dms;
        replica.presence_filter = original.presence_filter;
        replica.away_message = original.away_message;
        replica.away_message_len = original.away_message_len;
        replica.presence_suppressed = original.presence_suppressed;
        replica.joined_osu = original.joined_osu;
        replica.joined_announce = original.joined_announce;
        replica.in_lobby = original.in_lobby;
        replica.joined_lobby_channel = original.joined_lobby_channel;
        replica.match_id = original.match_id;
        replica.tourney_matches = original.tourney_matches;
        replica.spectating_user_id = original.spectating_user_id;
        try replica.friend_ids.appendSlice(allocator, original.friend_ids.items);
    }
    return clone;
}

/// Capture the database-independent half of a Stable poll while the session
/// mutex is held. The returned plan owns only values and fixed-size snapshots.
fn captureStablePollLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, session: *sessions_mod.Session, body: []const u8) !StablePollCapture {
    var capture: StablePollCapture = .{ .allocator = allocator, .owner_user_id = session.user.id, .owner_generation = session.generation, .owner_restricted = session.user.restricted };
    errdefer capture.deinit();
    capture.owner_name_len = @min(session.user.name.len, capture.owner_name.len);
    @memcpy(capture.owner_name[0..capture.owner_name_len], session.user.name[0..capture.owner_name_len]);
    var own = StableStatsSnapshot.init(session);
    var packet_index: usize = 0;
    var packets: protocol.Reader = .{ .data = body };
    while (try packets.next()) |packet| : (packet_index += 1) {
        if (session.user.restricted and !protocol.restrictedClientPacketAllowed(packet.id)) continue;
        switch (packet.id) {
            .request_status => try capture.append(packet_index, own),
            .change_action => {
                try applyStableAction(&own, packet.payload);
                try capture.append(packet_index, own);
            },
            .user_stats_request => {
                var payload: protocol.PayloadReader = .{ .data = packet.payload };
                const count = try payload.int(u16);
                for (0..count) |_| {
                    const user_id = try payload.int(i32);
                    if (user_id == session.user.id) {
                        if (!session.user.restricted) try capture.append(packet_index, own);
                        continue;
                    }
                    const target = sessions.onlineByUser(user_id) orelse continue;
                    if (target.user.restricted) continue;
                    try capture.append(packet_index, StableStatsSnapshot.init(target));
                }
            },
            .friend_add => {
                const friend_id = packetUserId(packet.payload) orelse continue;
                if (friend_id == session.user.id or friend_id == 3 or session.isFriend(friend_id)) continue;
                try capture.db_requests.append(allocator, .{ .friend_add = .{ .packet_index = packet_index, .user_id = session.user.id, .friend_id = friend_id } });
            },
            .friend_remove => {
                const friend_id = packetUserId(packet.payload) orelse continue;
                if (friend_id == 3) continue;
                try capture.db_requests.append(allocator, .{ .friend_remove = .{ .packet_index = packet_index, .user_id = session.user.id, .friend_id = friend_id } });
            },
            .send_public_message => {
                var payload: protocol.PayloadReader = .{ .data = packet.payload };
                _ = try payload.string();
                const text = std.mem.trim(u8, try payload.string(), " \t\r\n");
                const target = try payload.string();
                _ = try payload.int(i32);
                if (text.len == 0 or text.len > 2000 or std.mem.indexOfScalar(u8, text, 0) != null) continue;
                const owned_target = try allocator.dupe(u8, target);
                capture.db_requests.append(allocator, .{ .channel_write = .{ .packet_index = packet_index, .target = owned_target, .privileges = session.user.privileges } }) catch |err| {
                    allocator.free(owned_target);
                    return err;
                };
                const run_now_playing = commands.parseNowPlaying(text) != null;
                const run_command = text[0] == '!' and !std.mem.eql(u8, target, multiplayer_channel) and !std.mem.eql(u8, target, "#spectator");
                if (run_now_playing or run_command) try capture.appendCommand(sessions, packet_index, text, target, false, run_now_playing, run_command);
            },
            .send_private_message => {
                var payload: protocol.PayloadReader = .{ .data = packet.payload };
                _ = try payload.string();
                const text = std.mem.trim(u8, try payload.string(), " \t\r\n");
                const target_name = try payload.string();
                _ = try payload.int(i32);
                if (text.len == 0 or text.len > 2000 or std.mem.indexOfScalar(u8, text, 0) != null) continue;
                const target = sessions.onlineByName(target_name);
                if (target) |online| if (online.is_bot) {
                    try capture.appendCommand(sessions, packet_index, text, session.user.name, true, true, true);
                    continue;
                };
                const online_target = if (target) |online| CapturedDmTarget.init(online, session.user.id) else null;
                const owned_target = try allocator.dupe(u8, target_name);
                const owned_message = allocator.dupe(u8, text) catch |err| {
                    allocator.free(owned_target);
                    return err;
                };
                capture.db_requests.append(allocator, .{ .direct_message = .{
                    .packet_index = packet_index,
                    .sender_id = session.user.id,
                    .target_name = owned_target,
                    .message = owned_message,
                    .online_target = online_target,
                } }) catch |err| {
                    allocator.free(owned_target);
                    allocator.free(owned_message);
                    return err;
                };
            },
            else => {},
        }
    }
    return capture;
}

const PreparedStableStatsItem = struct {
    packet_index: usize,
    snapshot: StableStatsSnapshot,
    bytes: []u8,

    fn stillCurrent(self: *const PreparedStableStatsItem, session: *const sessions_mod.Session) bool {
        const snapshot = &self.snapshot;
        return snapshot.user.id == session.user.id and
            snapshot.generation == session.generation and
            snapshot.action == session.action and
            snapshot.mode == session.mode and
            snapshot.mods == session.mods and
            snapshot.map_id == session.map_id and
            snapshot.info_len == session.info_len and
            std.mem.eql(u8, &snapshot.map_md5, &session.map_md5) and
            std.mem.eql(u8, snapshot.info(), session.info());
    }
};

const PreparedStableStats = struct {
    allocator: std.mem.Allocator,
    owner_generation: u64,
    items: std.ArrayList(PreparedStableStatsItem) = .empty,

    fn deinit(self: *PreparedStableStats) void {
        for (self.items.items) |item| self.allocator.free(item.bytes);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    fn find(self: *const PreparedStableStats, packet_index: usize, session: *const sessions_mod.Session) ?[]const u8 {
        for (self.items.items) |*item| if (item.packet_index == packet_index and item.stillCurrent(session)) return item.bytes;
        return null;
    }
};

const PreparedDirectMessageStatus = enum { missing, blocked, silenced, stored_online, stored_offline };

const PreparedDirectMessage = struct {
    packet_index: usize,
    status: PreparedDirectMessageStatus,
    target_id: i32 = 0,
    target_generation: u64 = 0,
    direct_message_id: i64 = 0,
    target_name: [96]u8 = [_]u8{0} ** 96,
    target_name_len: usize = 0,
    away_message: [512]u8 = [_]u8{0} ** 512,
    away_message_len: usize = 0,

    fn setName(self: *PreparedDirectMessage, value: []const u8) void {
        self.target_name_len = @min(value.len, self.target_name.len);
        @memcpy(self.target_name[0..self.target_name_len], value[0..self.target_name_len]);
    }

    fn setAway(self: *PreparedDirectMessage, value: []const u8) void {
        self.away_message_len = @min(value.len, self.away_message.len);
        @memcpy(self.away_message[0..self.away_message_len], value[0..self.away_message_len]);
    }

    fn name(self: *const PreparedDirectMessage) []const u8 {
        return self.target_name[0..self.target_name_len];
    }

    fn away(self: *const PreparedDirectMessage) []const u8 {
        return self.away_message[0..self.away_message_len];
    }
};

const PreparedUnreadDirectMessage = struct {
    id: i64,
    bytes: []u8,
};

const PreparedUnreadDirectMessages = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(PreparedUnreadDirectMessage) = .empty,

    fn deinit(self: *PreparedUnreadDirectMessages) void {
        for (self.items.items) |item| self.allocator.free(item.bytes);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }
};

fn prepareUnreadDirectMessages(allocator: std.mem.Allocator, store: *storage.Store, user_id: i32, target_name: []const u8) !PreparedUnreadDirectMessages {
    const unread = try store.unreadDirectMessages(allocator, user_id);
    defer {
        for (unread) |*message| message.deinit(allocator);
        allocator.free(unread);
    }
    var prepared: PreparedUnreadDirectMessages = .{ .allocator = allocator };
    errdefer prepared.deinit();
    var total_bytes: usize = 0;
    for (unread) |message| {
        var packet = protocol.Writer.init(allocator);
        defer packet.deinit();
        try protocol.writeMessage(&packet, message.from_name, message.message, target_name, message.from_id);
        const next_bytes = std.math.add(usize, total_bytes, packet.bytes().len) catch break;
        if (next_bytes > sessions_mod.max_queue_bytes) break;
        const owned = try allocator.dupe(u8, packet.bytes());
        prepared.items.append(allocator, .{ .id = message.id, .bytes = owned }) catch |err| {
            allocator.free(owned);
            return err;
        };
        total_bytes = next_bytes;
    }
    return prepared;
}

const CommandSessionState = struct {
    user_id: i32,
    generation: u64,
    privileges: u32,
    silence_end: i64,
    restricted: bool,
    mode: u8,
    mods: i32,
    map_id: i32,
    map_md5: [32]u8,

    fn init(session: *const sessions_mod.Session) CommandSessionState {
        return .{
            .user_id = session.user.id,
            .generation = session.generation,
            .privileges = session.user.privileges,
            .silence_end = session.user.silence_end,
            .restricted = session.user.restricted,
            .mode = session.mode,
            .mods = session.mods,
            .map_id = session.map_id,
            .map_md5 = session.map_md5,
        };
    }
};

const PreparedCommandMutation = struct {
    user_id: i32,
    generation: u64,
    mode: ?u8 = null,
    mods: ?i32 = null,
    map_id: ?i32 = null,
    map_md5: ?[32]u8 = null,
    queue: []u8,
};

const PreparedCommand = struct {
    allocator: std.mem.Allocator,
    packet_index: usize,
    consume: bool,
    output: []u8,
    mutations: std.ArrayList(PreparedCommandMutation) = .empty,

    fn deinit(self: *PreparedCommand) void {
        self.allocator.free(self.output);
        for (self.mutations.items) |mutation| self.allocator.free(mutation.queue);
        self.mutations.deinit(self.allocator);
        self.* = undefined;
    }
};

const StableDbResult = union(enum) {
    friend_add: struct { packet_index: usize, friend_id: i32, result: domain.RelationshipAddResult },
    friend_remove: struct { packet_index: usize, friend_id: i32, removed: bool },
    channel_write: struct { packet_index: usize, allowed: bool },
    direct_message: PreparedDirectMessage,
    command: PreparedCommand,

    fn deinit(self: *StableDbResult) void {
        switch (self.*) {
            .command => |*command| command.deinit(),
            else => {},
        }
        self.* = undefined;
    }

    fn packetIndex(self: StableDbResult) usize {
        return switch (self) {
            inline else => |result| result.packet_index,
        };
    }
};

const PreparedStableDatabase = struct {
    allocator: std.mem.Allocator,
    owner_generation: u64,
    results: std.ArrayList(StableDbResult) = .empty,

    fn deinit(self: *PreparedStableDatabase) void {
        for (self.results.items) |*result| result.deinit();
        self.results.deinit(self.allocator);
        self.* = undefined;
    }

    fn find(self: *const PreparedStableDatabase, packet_index: usize, tag: std.meta.Tag(StableDbResult)) ?*const StableDbResult {
        for (self.results.items) |*result| if (result.packetIndex() == packet_index and std.meta.activeTag(result.*) == tag) return result;
        return null;
    }
};

const PreparedOwnerAuth = struct {
    allocator: std.mem.Allocator,
    privileges: u32,
    silence_end: i64,
    restricted: bool,
    privileges_packet: []u8,
    silence_packet: []u8,
    restricted_packet: []u8,
    unrestricted_packet: []u8,

    fn deinit(self: *PreparedOwnerAuth) void {
        self.allocator.free(self.privileges_packet);
        self.allocator.free(self.silence_packet);
        self.allocator.free(self.restricted_packet);
        self.allocator.free(self.unrestricted_packet);
        self.* = undefined;
    }
};

const StableOwnerAuthSnapshot = struct {
    privileges: u32,
    silence_end: i64,
    restricted: bool,
};

fn prepareOwnerAuthFromSnapshot(allocator: std.mem.Allocator, io: std.Io, snapshot: StableOwnerAuthSnapshot) !PreparedOwnerAuth {
    var privileges = protocol.Writer.init(allocator);
    defer privileges.deinit();
    const visible_privileges = if (snapshot.restricted) snapshot.privileges & ~@as(u32, 1) else snapshot.privileges;
    try privileges.packetInt(.privileges, clientPrivileges(visible_privileges, true));
    const privileges_packet = try allocator.dupe(u8, privileges.bytes());
    errdefer allocator.free(privileges_packet);

    var silence = protocol.Writer.init(allocator);
    defer silence.deinit();
    const now = std.Io.Clock.real.now(io).toSeconds();
    try silence.packetInt(.silence_end, @intCast(@min(@as(i64, std.math.maxInt(i32)), @max(0, snapshot.silence_end - now))));
    const silence_packet = try allocator.dupe(u8, silence.bytes());
    errdefer allocator.free(silence_packet);

    var restricted = protocol.Writer.init(allocator);
    defer restricted.deinit();
    try restricted.packetEmpty(.account_restricted);
    try restricted.packetInt(.restart, 0);
    const restricted_packet = try allocator.dupe(u8, restricted.bytes());
    errdefer allocator.free(restricted_packet);

    var unrestricted = protocol.Writer.init(allocator);
    defer unrestricted.deinit();
    try unrestricted.packetInt(.restart, 0);
    return .{
        .allocator = allocator,
        .privileges = snapshot.privileges,
        .silence_end = snapshot.silence_end,
        .restricted = snapshot.restricted,
        .privileges_packet = privileges_packet,
        .silence_packet = silence_packet,
        .restricted_packet = restricted_packet,
        .unrestricted_packet = try allocator.dupe(u8, unrestricted.bytes()),
    };
}

fn ownerAuthSnapshot(user: domain.User) StableOwnerAuthSnapshot {
    return .{
        .privileges = user.privileges,
        .silence_end = user.silence_end,
        .restricted = user.restricted,
    };
}

fn prepareOwnerAuth(allocator: std.mem.Allocator, store: *storage.Store, user_id: i32) !PreparedOwnerAuth {
    const user = (try store.userById(allocator, user_id)) orelse return error.StablePollOwnerMissing;
    defer {
        allocator.free(user.name);
        allocator.free(user.safe_name);
    }
    return prepareOwnerAuthFromSnapshot(allocator, store.io, ownerAuthSnapshot(user));
}

fn prepareOwnerAuthForDirectTest(allocator: std.mem.Allocator, store: *storage.Store, user_id: i32, fallback: StableOwnerAuthSnapshot) !PreparedOwnerAuth {
    if (!builtin.is_test) return prepareOwnerAuth(allocator, store, user_id);
    if (try store.userById(allocator, user_id)) |user| {
        defer {
            allocator.free(user.name);
            allocator.free(user.safe_name);
        }
        return prepareOwnerAuthFromSnapshot(allocator, store.io, ownerAuthSnapshot(user));
    }
    return prepareOwnerAuthFromSnapshot(allocator, store.io, fallback);
}

const LazerPresenceSnapshot = struct {
    user: domain.User,
    utc_offset: i8 = 0,
    action: u8 = 0,
    mode: u8 = 0,
    mods: i32 = 0,
    map_id: i32 = 0,
    map_md5: [32]u8 = [_]u8{0} ** 32,
    info_text: [96]u8 = [_]u8{0} ** 96,
    info_len: usize = 0,
    longitude: f32 = 0,
    latitude: f32 = 0,

    fn init(user: domain.User) LazerPresenceSnapshot {
        var result: LazerPresenceSnapshot = .{ .user = user };
        if (!result.user.show_country) result.user.country = .{ 'X', 'X' };
        const text = "using lazer";
        @memcpy(result.info_text[0..text.len], text);
        result.info_len = text.len;
        return result;
    }

    fn info(self: *const LazerPresenceSnapshot) []const u8 {
        return self.info_text[0..self.info_len];
    }
};

fn capturedUser(capture: *const LoginCapture, user_id: i32) bool {
    for (capture.sessions.items) |snapshot| if (snapshot.user.id == user_id) return true;
    return false;
}

const PreparedLazerPresence = struct {
    allocator: std.mem.Allocator,
    user_id: i32,
    seen_at: i64,
    presence_bytes: ?[]u8 = null,
    stats_bytes: ?[]u8 = null,

    fn deinit(self: *PreparedLazerPresence) void {
        if (self.presence_bytes) |bytes| self.allocator.free(bytes);
        if (self.stats_bytes) |bytes| self.allocator.free(bytes);
        self.* = undefined;
    }
};

const PreparedLazerPresences = struct {
    allocator: std.mem.Allocator,
    epoch: u64,
    items: std.ArrayList(PreparedLazerPresence) = .empty,

    fn deinit(self: *PreparedLazerPresences) void {
        for (self.items.items) |*item| item.deinit();
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    fn find(self: *const PreparedLazerPresences, user_id: i32) ?*const PreparedLazerPresence {
        for (self.items.items) |*item| if (item.user_id == user_id) return item;
        return null;
    }
};

const presence_request_bit: u8 = 1 << 0;
const stats_request_bit: u8 = 1 << 1;

fn notePresenceRequest(requests: *std.AutoHashMap(i32, u8), user_id: i32, bits: u8) !void {
    if (user_id <= 0) return;
    const result = try requests.getOrPut(user_id);
    if (!result.found_existing) result.value_ptr.* = 0;
    result.value_ptr.* |= bits;
}

/// Prepare database-backed lazer presence packets before the global Stable
/// session mutex is acquired. `pollLocked` only re-checks current Stable
/// ownership and copies these owned bytes into the response.
fn prepareLazerPresences(allocator: std.mem.Allocator, store: *storage.Store, body: []const u8, epoch: u64, restricted: bool) !PreparedLazerPresences {
    var prepared: PreparedLazerPresences = .{ .allocator = allocator, .epoch = epoch };
    errdefer prepared.deinit();
    if (restricted) return prepared;
    var requests = std.AutoHashMap(i32, u8).init(allocator);
    defer requests.deinit();

    var reader: protocol.Reader = .{ .data = body };
    while (try reader.next()) |packet| switch (packet.id) {
        .user_stats_request, .user_presence_request => {
            var payload: protocol.PayloadReader = .{ .data = packet.payload };
            const count = try payload.int(u16);
            const bit = if (packet.id == .user_stats_request) stats_request_bit else presence_request_bit;
            for (0..count) |_| try notePresenceRequest(&requests, try payload.int(i32), bit);
            if (payload.pos != packet.payload.len) return error.InvalidPresenceRequest;
        },
        .user_presence_request_all => {
            if (packet.payload.len != @sizeOf(i32)) continue;
            const now = std.Io.Clock.real.now(store.io).toSeconds();
            const ids = try store.recentOauthUserIds(allocator, now - lazer_presence_lease_seconds);
            defer allocator.free(ids);
            for (ids) |user_id| try notePresenceRequest(&requests, user_id, presence_request_bit);
        },
        else => {},
    };

    const now = std.Io.Clock.real.now(store.io).toSeconds();
    const cutoff = now - lazer_presence_lease_seconds;
    var iterator = requests.iterator();
    while (iterator.next()) |entry| {
        const user_id = entry.key_ptr.*;
        if (!try store.lazerUserOnline(user_id, cutoff)) continue;
        const user = (try store.userById(allocator, user_id)) orelse continue;
        defer {
            allocator.free(user.name);
            allocator.free(user.safe_name);
        }
        if (user.restricted) continue;
        const snapshot = LazerPresenceSnapshot.init(user);
        var item: PreparedLazerPresence = .{ .allocator = allocator, .user_id = user_id, .seen_at = now };
        errdefer item.deinit();
        if (entry.value_ptr.* & presence_request_bit != 0) {
            var output = protocol.Writer.init(allocator);
            defer output.deinit();
            try presence(&output, &snapshot);
            item.presence_bytes = try allocator.dupe(u8, output.bytes());
        }
        if (entry.value_ptr.* & stats_request_bit != 0) {
            var output = protocol.Writer.init(allocator);
            defer output.deinit();
            try stats(&output, store, &snapshot);
            item.stats_bytes = try allocator.dupe(u8, output.bytes());
        }
        try prepared.items.append(allocator, item);
    }
    return prepared;
}

fn writePreparedLazerPresence(out: *protocol.Writer, sessions: *sessions_mod.Sessions, prepared: *const PreparedLazerPresences, user_id: i32, include_presence: bool, include_stats: bool) !bool {
    if (prepared.epoch != sessions.lazer_presence_epoch) return false;
    if (sessions.onlineByUser(user_id) != null) return false;
    const item = prepared.find(user_id) orelse return false;
    if (include_presence) if (item.presence_bytes) |bytes| try out.raw(bytes);
    if (include_stats) if (item.stats_bytes) |bytes| try out.raw(bytes);
    try sessions.lazer_leases.put(user_id, item.seen_at);
    return true;
}

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
    const visible_country: [2]u8 = if (s.user.show_country) s.user.country else .{ 'X', 'X' };
    try w.byte(country.numeric(&visible_country));
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
    return writeStats(w, s, storage_contracts.BanchoStats.fromStats(current));
}

fn writeStats(w: *protocol.Writer, s: anytype, current: storage_contracts.BanchoStats) !void {
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

/// Execute every stats read in an owned poll plan without holding the global
/// Stable session mutex. Applying these bytes later requires the same session
/// generation to still own the token.
fn prepareStableStats(allocator: std.mem.Allocator, store: *storage.Store, capture: *const StablePollCapture) !PreparedStableStats {
    var prepared: PreparedStableStats = .{ .allocator = allocator, .owner_generation = capture.owner_generation };
    errdefer prepared.deinit();
    try prepared.items.ensureTotalCapacity(allocator, capture.requests.items.len);
    for (capture.requests.items) |request| {
        var output = protocol.Writer.init(allocator);
        defer output.deinit();
        try stats(&output, store, &request.snapshot);
        const bytes = try allocator.dupe(u8, output.bytes());
        prepared.items.appendAssumeCapacity(.{
            .packet_index = request.packet_index,
            .snapshot = request.snapshot,
            .bytes = bytes,
        });
    }
    return prepared;
}

fn prepareDirectMessage(allocator: std.mem.Allocator, store: *storage.Store, request: StableDirectMessageRequest) !PreparedDirectMessage {
    var prepared: PreparedDirectMessage = .{ .packet_index = request.packet_index, .status = .missing };
    prepared.setName(request.target_name);
    const target = if (request.online_target) |online|
        try store.userById(allocator, online.user_id)
    else
        try store.userByName(allocator, request.target_name);
    const user = target orelse return prepared;
    defer {
        allocator.free(user.name);
        allocator.free(user.safe_name);
    }
    prepared.target_id = user.id;
    prepared.setName(user.name);
    if (user.restricted or user.silence_end > std.Io.Clock.real.now(store.io).toSeconds()) {
        prepared.status = .silenced;
        return prepared;
    }
    if (request.online_target) |online| {
        prepared.target_generation = online.generation;
        prepared.setAway(online.away());
        if (online.block_non_friend_dms and !online.sender_is_friend) {
            prepared.status = .blocked;
            return prepared;
        }
    }
    prepared.direct_message_id = store.storeDirectMessage(request.sender_id, user.id, request.message) catch |err| switch (err) {
        error.DirectMessageBlocked => {
            prepared.status = .blocked;
            return prepared;
        },
        else => return err,
    };
    prepared.status = if (request.online_target != null) .stored_online else .stored_offline;
    return prepared;
}

fn prepareCommand(allocator: std.mem.Allocator, store: *storage.Store, world: *sessions_mod.Sessions, request: StableCommandRequest) !PreparedCommand {
    // The command world was cloned while the session mutex was held, but staff
    // state may have changed in the database before this deferred command got
    // its turn. Refresh every online user's authority before taking the
    // before-image used to identify command-owned mutations.
    for (world.items.items) |session| {
        const current = (try store.userById(allocator, session.user.id)) orelse continue;
        defer {
            allocator.free(current.name);
            allocator.free(current.safe_name);
        }
        session.user.privileges = current.privileges;
        session.user.silence_end = current.silence_end;
        session.user.restricted = current.restricted;
    }
    var before: std.ArrayList(CommandSessionState) = .empty;
    defer before.deinit(allocator);
    try before.ensureTotalCapacity(allocator, world.items.items.len);
    for (world.items.items) |session| before.appendAssumeCapacity(CommandSessionState.init(session));

    const sender = world.byUser(request.sender_id) orelse return error.StableCommandSenderMissing;
    const current_user = (try store.userById(allocator, request.sender_id)) orelse return error.StableCommandSenderMissing;
    defer {
        allocator.free(current_user.name);
        allocator.free(current_user.safe_name);
    }
    // The cloned world is only an owned transport for session state. Staff
    // authority still comes from the database immediately before the command
    // runs, so a concurrent role removal, restriction, or silence cannot race
    // a captured command.
    sender.user.privileges = current_user.privileges;
    sender.user.restricted = current_user.restricted;
    sender.user.silence_end = current_user.silence_end;
    var output = protocol.Writer.init(allocator);
    defer output.deinit();
    var consume = false;
    const now = std.Io.Clock.real.now(store.io).toSeconds();
    if (sender.user.restricted) {
        try output.packetEmpty(.account_restricted);
        try output.packetInt(.restart, 0);
        consume = true;
    } else if (sender.user.silence_end > now) {
        try output.packetInt(.silence_end, @intCast(@min(@as(i64, std.math.maxInt(i32)), sender.user.silence_end - now)));
        consume = true;
    } else {
        if (request.run_now_playing) {
            const handled = try commands.handleNowPlaying(allocator, store, sender, request.text);
            if (request.private_bot and handled) consume = true;
        }
        if (!consume and request.run_command) {
            consume = try commands.handleCommand(allocator, store, world, sender, request.text, request.target, &output) == .handled;
        }
        if (request.private_bot and !consume) {
            try protocol.writeMessage(&output, "kai", "send /np here for pp, then use !with for a custom play", sender.user.name, 3);
            consume = true;
        }
    }

    var mutations: std.ArrayList(PreparedCommandMutation) = .empty;
    errdefer {
        for (mutations.items) |mutation| allocator.free(mutation.queue);
        mutations.deinit(allocator);
    }
    try mutations.ensureTotalCapacity(allocator, world.items.items.len);
    for (world.items.items) |session| {
        const previous = for (before.items) |state| {
            if (state.user_id == session.user.id) break state;
        } else continue;
        const auth_changed = previous.privileges != session.user.privileges or previous.silence_end != session.user.silence_end or previous.restricted != session.user.restricted;
        const mode = if (previous.mode != session.mode) session.mode else null;
        const mods = if (previous.mods != session.mods) session.mods else null;
        const map_id = if (previous.map_id != session.map_id) session.map_id else null;
        const map_md5 = if (!std.mem.eql(u8, &previous.map_md5, &session.map_md5)) session.map_md5 else null;
        // Authority is never copied out of the command clone. The affected
        // player's next poll reads the authoritative database row and emits
        // the correct privilege/silence/restriction packet. Dropping this
        // clone-owned queue for that player prevents an older command packet
        // from winning after a newer database transition.
        const queue_source: []const u8 = if (auth_changed) "" else session.queue.items;
        if (mode == null and mods == null and map_id == null and map_md5 == null and queue_source.len == 0) {
            session.queue.clearRetainingCapacity();
            session.pending_dm_reads.clearRetainingCapacity();
            continue;
        }
        const queue = try allocator.dupe(u8, queue_source);
        mutations.appendAssumeCapacity(.{
            .user_id = session.user.id,
            .generation = session.generation,
            .mode = mode,
            .mods = mods,
            .map_id = map_id,
            .map_md5 = map_md5,
            .queue = queue,
        });
        session.queue.clearRetainingCapacity();
        session.pending_dm_reads.clearRetainingCapacity();
    }
    const owned_output = try allocator.dupe(u8, output.bytes());
    return .{ .allocator = allocator, .packet_index = request.packet_index, .consume = consume, .output = owned_output, .mutations = mutations };
}

fn applyPreparedCommand(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, out: *protocol.Writer, command: *const PreparedCommand) !void {
    for (command.mutations.items) |mutation| {
        const current = sessions.onlineByUser(mutation.user_id) orelse continue;
        if (current.generation != mutation.generation) continue;
        if (mutation.mode) |value| current.mode = value;
        if (mutation.mods) |value| current.mods = value;
        if (mutation.map_id) |value| current.map_id = value;
        if (mutation.map_md5) |value| current.map_md5 = value;
        if (mutation.queue.len != 0) try current.enqueue(allocator, mutation.queue);
    }
    if (command.output.len != 0) try out.raw(command.output);
}

fn prepareStableDatabase(allocator: std.mem.Allocator, store: *storage.Store, capture: *StablePollCapture, owner_auth: *const PreparedOwnerAuth) !PreparedStableDatabase {
    var prepared: PreparedStableDatabase = .{ .allocator = allocator, .owner_generation = capture.owner_generation };
    errdefer prepared.deinit();
    if (owner_auth.restricted) return prepared;
    try prepared.results.ensureTotalCapacity(allocator, capture.db_requests.items.len);
    for (capture.db_requests.items) |request| switch (request) {
        .friend_add => |add| prepared.results.appendAssumeCapacity(.{ .friend_add = .{
            .packet_index = add.packet_index,
            .friend_id = add.friend_id,
            .result = try store.addFriend(add.user_id, add.friend_id),
        } }),
        .friend_remove => |remove| prepared.results.appendAssumeCapacity(.{ .friend_remove = .{
            .packet_index = remove.packet_index,
            .friend_id = remove.friend_id,
            .removed = try store.removeFriend(remove.user_id, remove.friend_id),
        } }),
        .channel_write => |channel| prepared.results.appendAssumeCapacity(.{ .channel_write = .{
            .packet_index = channel.packet_index,
            .allowed = try store.channelCanWrite(channel.target, channel.privileges),
        } }),
        .direct_message => |message| prepared.results.appendAssumeCapacity(.{ .direct_message = if (owner_auth.silence_end > std.Io.Clock.real.now(store.io).toSeconds()) .{ .packet_index = message.packet_index, .status = .missing } else try prepareDirectMessage(allocator, store, message) }),
        .command => |command| {
            const world = if (capture.command_world) |*value| value else return error.StableCommandWorldMissing;
            prepared.results.appendAssumeCapacity(.{ .command = try prepareCommand(allocator, store, world, command) });
        },
    };
    return prepared;
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

fn captureLoginLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, user: domain.User, utc: i8, longitude: f32, latitude: f32, friend_ids: []i32, block_non_friend_dms: bool, client_binding: sessions_mod.StableClientBinding) !LoginCapture {
    var user_owned = true;
    errdefer if (user_owned) {
        allocator.free(user.name);
        allocator.free(user.safe_name);
    };
    if (sessions.byUser(user.id)) |old| removeSessionLocked(allocator, sessions, old);
    const session = try sessions.createWithSocial(user, utc, longitude, latitude, friend_ids, block_non_friend_dms, client_binding);
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
        if (item.presence_suppressed) continue;
        const snapshot = try SessionSnapshot.init(allocator, item);
        errdefer {
            var owned = snapshot;
            owned.deinit();
        }
        try capture.sessions.append(allocator, snapshot);
    }
    return capture;
}

fn loginInternal(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, body: []const u8, login_country: ?[2]u8, longitude: f32, latitude: f32, expected_user_id: ?i32) !LoginResult {
    const request = stable_login.envelope(body);
    // Existing accounts may have a staff-approved one-character username.
    // Registration keeps the public two-character minimum; login only needs
    // a non-empty name which resolves to a real stored account.
    if (request.name.len == 0 or request.password.len != 32) {
        return loginFailure(allocator, "invalid-request", "Invalid login request.");
    }
    const parsed = parseStableLoginDetails(request.details) catch {
        return loginFailure(allocator, "invalid-request", "Please restart osu! and try again.");
    };
    var user = (try store.authenticate(allocator, request.name, request.password)) orelse {
        return loginFailure(allocator, "no", "Incorrect credentials.");
    };
    var user_transferred = false;
    defer if (!user_transferred) {
        allocator.free(user.name);
        allocator.free(user.safe_name);
    };
    if (expected_user_id) |expected| if (user.id != expected) {
        return loginFailure(allocator, "no", "Incorrect credentials.");
    };
    if (login_country) |value| {
        try store.updateCountry(user.id, value);
        user.country = value;
    }
    var hardware_evidence = try store.recordClientHardware(user.id, parsed.hardware);
    defer hardware_evidence.deinit();
    if (hardware_evidence.matched_user_ids.len != 0) std.log.warn("stable login exact hardware match observed: user_id={d} matches={any} mode=review", .{ user.id, hardware_evidence.matched_user_ids });
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
    std.debug.print("{s}{s}║  LOGIN — {s}{s}{s}{s}{s} ║{s}\n", .{ log.magenta ++ log.bold, "", log.green, request.name, log.reset, log.magenta ++ log.bold, "", log.reset });
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
    var capture = captureLoginLocked(allocator, sessions, user, parsed.utc_offset, longitude, latitude, session_friend_ids, parsed.pm_private, parsed.client_binding) catch |err| {
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
    const stat_requests = try allocator.alloc(storage_contracts.BanchoStatsRequest, capture.sessions.items.len);
    defer allocator.free(stat_requests);
    for (capture.sessions.items, stat_requests) |snapshot, *request| request.* = .{
        .user_id = snapshot.user.id,
        .mode = stable_score.statsMode(snapshot.mode, snapshot.mods) orelse snapshot.mode,
    };
    const login_stats = try store.banchoStatsBatch(allocator, stat_requests);
    defer allocator.free(login_stats);
    try presence(&out, own);
    try writeStats(&out, own, login_stats[own_index]);
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
        try writeStats(&out, other, login_stats[index]);
    };
    const lazer_presence_epoch = captureLazerPresenceEpoch(sessions);
    const lazer_now = std.Io.Clock.real.now(store.io).toSeconds();
    const lazer_cutoff = lazer_now - lazer_presence_lease_seconds;
    const lazer_ids = try store.recentOauthUserIds(allocator, lazer_cutoff);
    defer allocator.free(lazer_ids);
    for (lazer_ids) |user_id| {
        if (capturedUser(&capture, user_id)) continue;
        const lazer_user = (try store.userById(allocator, user_id)) orelse continue;
        defer {
            allocator.free(lazer_user.name);
            allocator.free(lazer_user.safe_name);
        }
        if (lazer_user.restricted or !try noteLazerPresenceAtEpoch(sessions, user_id, lazer_now, lazer_presence_epoch)) continue;
        const snapshot = LazerPresenceSnapshot.init(lazer_user);
        try presence(&out, &snapshot);
        try stats(&out, store, &snapshot);
    }
    if (capture.restricted) {
        try out.packetEmpty(.account_restricted);
        try protocol.writeMessage(&out, "kai", "Your account is restricted. If this was a mistake, contact staff so we can review it.", own.user.name, 3);
    }
    var announce = protocol.Writer.init(allocator);
    defer announce.deinit();
    if (!capture.restricted) {
        try presence(&announce, own);
        try writeStats(&announce, own, login_stats[own_index]);
        sessions.mutex.lockUncancelable(sessions.io);
        defer sessions.mutex.unlock(sessions.io);
        if (sessions.byToken(capture.token)) |current| {
            if (current.user.id == capture.user_id) {
                try current.pending_dm_reads.ensureUnusedCapacity(allocator, unread_messages.len);
                for (unread_messages) |message| current.pending_dm_reads.appendAssumeCapacity(message.id);
                try sessions.broadcast(announce.bytes(), current);
            }
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
        .hardware_match_count = @intCast(@min(hardware_evidence.matched_user_ids.len, std.math.maxInt(u32))),
        .running_under_wine = parsed.hardware.running_under_wine,
        .client_binding = parsed.client_binding,
    };
}

pub fn login(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, body: []const u8, login_country: ?[2]u8, longitude: f32, latitude: f32) !LoginResult {
    return loginInternal(allocator, store, sessions, body, login_country, longitude, latitude, null);
}

pub fn loginExpectedUser(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, body: []const u8, login_country: ?[2]u8, longitude: f32, latitude: f32, expected_user_id: i32) !LoginResult {
    return loginInternal(allocator, store, sessions, body, login_country, longitude, latitude, expected_user_id);
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
    const has_kick = blk: {
        kick.packetString(.channel_kick, "#spectator") catch break :blk false;
        break :blk true;
    };
    for (sessions.items.items) |other| if (other.spectating_user_id == host.user.id) {
        other.spectating_user_id = null;
        if (has_kick) other.enqueue(allocator, kick.bytes()) catch {};
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

fn broadcastUserLogoutLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, user_id: i32, except: ?*sessions_mod.Session) void {
    var event = protocol.Writer.init(allocator);
    defer event.deinit();
    const start = event.begin(.user_logout) catch return;
    event.int(i32, user_id) catch return;
    event.byte(0) catch return;
    event.finish(start);
    sessions.broadcast(event.bytes(), except) catch {};
}

fn broadcastLogoutLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, session: *sessions_mod.Session) void {
    if (session.presence_suppressed) return;
    broadcastUserLogoutLocked(allocator, sessions, session.user.id, session);
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

fn pruneLazerPresenceLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions) !void {
    const now = std.Io.Clock.real.now(sessions.io).toSeconds();
    var expired: std.ArrayList(i32) = .empty;
    defer expired.deinit(allocator);
    var iterator = sessions.lazer_leases.iterator();
    while (iterator.next()) |entry| {
        if (now - entry.value_ptr.* >= lazer_presence_lease_seconds) try expired.append(allocator, entry.key_ptr.*);
    }
    for (expired.items) |user_id| {
        if (!sessions.lazer_leases.remove(user_id)) continue;
        sessions.lazer_presence_epoch +%= 1;
        if (sessions.onlineByUser(user_id) != null) continue;
        broadcastUserLogoutLocked(allocator, sessions, user_id, null);
    }
}

pub fn captureLazerPresenceEpoch(sessions: *sessions_mod.Sessions) u64 {
    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    return sessions.lazer_presence_epoch;
}

const DeferredPublicMessage = struct {
    sender_id: i32,
    target: []u8,
    message: []u8,

    fn deinit(self: *DeferredPublicMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        allocator.free(self.message);
        self.* = undefined;
    }
};

fn deferPublicMessage(allocator: std.mem.Allocator, pending: *std.ArrayList(DeferredPublicMessage), sender_id: i32, target: []const u8, message: []const u8) !void {
    const owned_target = try allocator.dupe(u8, target);
    errdefer allocator.free(owned_target);
    const owned_message = try allocator.dupe(u8, message);
    errdefer allocator.free(owned_message);
    try pending.append(allocator, .{ .sender_id = sender_id, .target = owned_target, .message = owned_message });
}

fn applyOwnerAuthLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, session: *sessions_mod.Session, prepared: *const PreparedOwnerAuth) !void {
    const privileges_changed = session.user.privileges != prepared.privileges;
    const silence_changed = session.user.silence_end != prepared.silence_end;
    const restricted_changed = session.user.restricted != prepared.restricted;
    session.user.privileges = prepared.privileges;
    session.user.silence_end = prepared.silence_end;
    session.user.restricted = prepared.restricted;
    if (privileges_changed) try session.enqueue(allocator, prepared.privileges_packet);
    if (silence_changed) try session.enqueue(allocator, prepared.silence_packet);
    if (restricted_changed) {
        if (prepared.restricted) broadcastLogoutLocked(allocator, sessions, session);
        try session.enqueue(allocator, if (prepared.restricted) prepared.restricted_packet else prepared.unrestricted_packet);
    }
}

fn pollLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, session: *sessions_mod.Session, body: []const u8, prepared_stable: *const PreparedStableStats, prepared_database: *const PreparedStableDatabase, prepared_lazer: *const PreparedLazerPresences, prepared_unread: *const PreparedUnreadDirectMessages, logged_out: *bool, delivered_dm_ids: *std.ArrayList(i64), deferred_public_messages: *std.ArrayList(DeferredPublicMessage)) ![]u8 {
    if (prepared_stable.owner_generation != session.generation or prepared_database.owner_generation != session.generation) return error.StaleStablePollPlan;
    const now = std.Io.Clock.real.now(sessions.io).toSeconds();
    session.last_seen = now;
    var out = protocol.Writer.init(allocator);
    defer out.deinit();
    try out.raw(session.queue.items);
    try delivered_dm_ids.appendSlice(allocator, session.pending_dm_reads.items);
    session.queue.clearRetainingCapacity();
    session.pending_dm_reads.clearRetainingCapacity();
    for (prepared_unread.items.items) |message| {
        if (std.mem.indexOfScalar(i64, delivered_dm_ids.items, message.id) != null) continue;
        try out.raw(message.bytes);
        try delivered_dm_ids.append(allocator, message.id);
    }
    var reader: protocol.Reader = .{ .data = body };
    var packet_index: usize = 0;
    while (try reader.next()) |packet| : (packet_index += 1) switch (if (session.user.restricted and !protocol.restrictedClientPacketAllowed(packet.id)) @as(protocol.ClientPacket, @enumFromInt(std.math.maxInt(u16))) else packet.id) {
        .ping => {},
        .request_status => try out.raw(prepared_stable.find(packet_index, session) orelse return error.StalePreparedStableStats),
        .change_action => {
            try applyStableAction(session, packet.payload);
            const event = prepared_stable.find(packet_index, session) orelse return error.StalePreparedStableStats;
            try out.raw(event);
            if (!session.user.restricted) try sessions.broadcast(event, session);
        },
        .friend_add => {
            const result = prepared_database.find(packet_index, .friend_add) orelse continue;
            const add = switch (result.*) {
                .friend_add => |value| value,
                else => return error.InvalidStableDatabasePlan,
            };
            const friend_id = add.friend_id;
            if (session.isFriend(friend_id)) continue;
            try session.friend_ids.ensureUnusedCapacity(allocator, 1);
            switch (add.result) {
                .inserted, .existing => session.friend_ids.appendAssumeCapacity(friend_id),
                .ineligible => {},
            }
        },
        .friend_remove => {
            const result = prepared_database.find(packet_index, .friend_remove) orelse continue;
            const remove = switch (result.*) {
                .friend_remove => |value| value,
                else => return error.InvalidStableDatabasePlan,
            };
            if (remove.removed) session.removeFriend(remove.friend_id);
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
            if (packet.id == .send_public_message) {
                const result = prepared_database.find(packet_index, .channel_write) orelse return error.MissingStableDatabasePlan;
                const channel = switch (result.*) {
                    .channel_write => |value| value,
                    else => return error.InvalidStableDatabasePlan,
                };
                if (!channel.allowed) {
                    try out.packetString(.notification, "that channel is read-only right now");
                    continue;
                }
            }
            if (prepared_database.find(packet_index, .command)) |result| {
                const command = switch (result.*) {
                    .command => |*value| value,
                    else => return error.InvalidStableDatabasePlan,
                };
                try applyPreparedCommand(allocator, sessions, &out, command);
                if (command.consume) continue;
            }
            if (packet.id == .send_public_message and try handleMultiplayerCommandLocked(allocator, sessions, session, target_name, text)) continue;
            var message = protocol.Writer.init(allocator);
            defer message.deinit();
            try protocol.writeMessage(&message, session.user.name, text, target_name, session.user.id);
            if (packet.id == .send_private_message) {
                const result = prepared_database.find(packet_index, .direct_message) orelse continue;
                const dm = switch (result.*) {
                    .direct_message => |value| value,
                    else => return error.InvalidStableDatabasePlan,
                };
                switch (dm.status) {
                    .missing => {},
                    .blocked => try writeDmBlocked(&out, dm.name()),
                    .silenced => {
                        const start = try out.begin(.target_is_silenced);
                        try out.string("");
                        try out.string("");
                        try out.string(dm.name());
                        try out.int(i32, 0);
                        out.finish(start);
                    },
                    .stored_online => if (sessions.onlineByUser(dm.target_id)) |target| {
                        if (target.generation == dm.target_generation and !target.is_bot and !target.user.restricted and target.user.silence_end <= now) {
                            if (dm.away().len != 0) try protocol.writeMessage(&out, dm.name(), dm.away(), session.user.name, dm.target_id);
                            try target.enqueueDirectMessage(allocator, dm.direct_message_id, message.bytes());
                        }
                    },
                    .stored_offline => {
                        var notice_buf: [192]u8 = undefined;
                        const notice = try std.fmt.bufPrint(&notice_buf, "{s} is offline, but they'll get your message when they next log in.", .{dm.name()});
                        try out.packetString(.notification, notice);
                    },
                }
            } else {
                if (std.mem.eql(u8, target_name, "#spectator")) {
                    if (try broadcastSpectatorChatLocked(allocator, sessions, session, message.bytes())) {
                        const host_id = session.spectating_user_id orelse session.user.id;
                        var history_target_buf: [32]u8 = undefined;
                        const history_target = try std.fmt.bufPrint(&history_target_buf, "#spectator_{d}", .{host_id});
                        try deferPublicMessage(allocator, deferred_public_messages, session.user.id, history_target, text);
                    }
                    continue;
                }
                if (std.mem.eql(u8, target_name, multiplayer_channel)) {
                    const match_id = session.visibleMatchId() orelse continue;
                    try broadcastMatchChatLocked(allocator, sessions, match_id, message.bytes(), session);
                    var history_target_buf: [32]u8 = undefined;
                    const history_target = try std.fmt.bufPrint(&history_target_buf, "#multi_{d}", .{match_id});
                    try deferPublicMessage(allocator, deferred_public_messages, session.user.id, history_target, text);
                    continue;
                }
                if (!session.joined(target_name)) continue;
                try sessions.broadcastChannel(target_name, message.bytes(), session);
                try deferPublicMessage(allocator, deferred_public_messages, session.user.id, target_name, text);
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
            const target = sessions.onlineByUser(target_id) orelse continue;
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
            const target = sessions.onlineByUser(target_id) orelse continue;
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
            while (i < count) : (i += 1) {
                const user_id = try p.int(i32);
                if (sessions.onlineByUser(user_id)) |target| {
                    if (target.user.restricted or (session.user.restricted and target.user.id == session.user.id)) continue;
                    if (prepared_stable.find(packet_index, target)) |event| try out.raw(event);
                } else if (!session.user.restricted) {
                    _ = try writePreparedLazerPresence(&out, sessions, prepared_lazer, user_id, false, true);
                }
            }
        },
        .user_presence_request => {
            var p: protocol.PayloadReader = .{ .data = packet.payload };
            const count = try p.int(u16);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const user_id = try p.int(i32);
                if (sessions.onlineByUser(user_id)) |s|
                    try presence(&out, s)
                else
                    _ = try writePreparedLazerPresence(&out, sessions, prepared_lazer, user_id, true, false);
            }
        },
        .user_presence_request_all => {
            if (packet.payload.len != @sizeOf(i32)) continue;
            for (sessions.items.items) |target| if (!target.user.restricted and !target.presence_suppressed) try presence(&out, target);
            for (prepared_lazer.items.items) |item| _ = try writePreparedLazerPresence(&out, sessions, prepared_lazer, item.user_id, true, false);
        },
        .start_spectating => {
            const target_id = packetUserId(packet.payload) orelse continue;
            const host = sessions.onlineByUser(target_id) orelse continue;
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

fn markDeliveredDirectMessages(store: *storage.Store, user_id: i32, message_ids: []const i64) void {
    for (message_ids) |message_id| {
        _ = store.markDirectMessageRead(user_id, message_id) catch |err| {
            std.log.warn("event=stable_dm_read_failed user_id={d} message_id={d} error={t}", .{ user_id, message_id, err });
            continue;
        };
    }
}

fn storeDeferredPublicMessages(store: *storage.Store, messages: []const DeferredPublicMessage) void {
    for (messages) |message| store.recordPublicMessage(message.sender_id, message.target, message.message) catch |err| {
        std.log.warn("chat history write failed: {s}", .{@errorName(err)});
    };
}

fn drainSuppressedLocked(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, session: *sessions_mod.Session) ![]u8 {
    const result = try allocator.dupe(u8, session.queue.items);
    session.queue.clearRetainingCapacity();
    session.pending_dm_reads.clearRetainingCapacity();
    removeSessionLocked(allocator, sessions, session);
    return result;
}

pub fn poll(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, session: *sessions_mod.Session, body: []const u8) ![]u8 {
    sessions.mutex.lockUncancelable(sessions.io);
    const direct = if (sessions.byToken(&session.token)) |current| blk: {
        if (current != session or current.generation != session.generation) {
            sessions.mutex.unlock(sessions.io);
            return error.StaleStableSession;
        }
        break :blk .{
            .token = current.token,
            .owner_auth = ownerAuthSnapshot(current.user),
        };
    } else {
        sessions.mutex.unlock(sessions.io);
        return error.StaleStableSession;
    };
    sessions.mutex.unlock(sessions.io);
    const test_owner_auth: ?StableOwnerAuthSnapshot = if (builtin.is_test) direct.owner_auth else null;
    return (try pollByTokenWithOwnerAuthFallback(allocator, store, sessions, &direct.token, body, test_owner_auth)) orelse error.StaleStableSession;
}

/// Resolve the owner needed to acquire the app's per-user game-session lease.
/// `pollByToken` checks the token again after the lease is held, so a takeover
/// between this lookup and lock acquisition cannot execute any database work.
pub fn pollUserIdForToken(sessions: *sessions_mod.Sessions, token: []const u8) ?i32 {
    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    const session = sessions.byToken(token) orelse return null;
    return session.user.id;
}

pub fn pollByToken(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, token: []const u8, body: []const u8) !?[]u8 {
    return pollByTokenWithOwnerAuthFallback(allocator, store, sessions, token, body, null);
}

fn pollByTokenWithOwnerAuthFallback(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, token: []const u8, body: []const u8, test_owner_auth: ?StableOwnerAuthSnapshot) !?[]u8 {
    var delivered_dm_ids: std.ArrayList(i64) = .empty;
    defer delivered_dm_ids.deinit(allocator);
    var deferred_public_messages: std.ArrayList(DeferredPublicMessage) = .empty;
    defer {
        for (deferred_public_messages.items) |*message| message.deinit(allocator);
        deferred_public_messages.deinit(allocator);
    }
    // Do not let an unknown token trigger the database-backed presence
    // preparation pass. The token is checked again after preparation because
    // a concurrent reconnect may replace it in between.
    var stable_capture: StablePollCapture = undefined;
    var lazer_presence_epoch: u64 = 0;
    sessions.mutex.lockUncancelable(sessions.io);
    pruneExpiredLocked(allocator, sessions);
    {
        const initial_session = sessions.byToken(token) orelse {
            sessions.mutex.unlock(sessions.io);
            return null;
        };
        if (initial_session.queue_overflowed) {
            removeSessionLocked(allocator, sessions, initial_session);
            sessions.mutex.unlock(sessions.io);
            return null;
        }
        if (initial_session.presence_suppressed) {
            const result = drainSuppressedLocked(allocator, sessions, initial_session) catch |err| {
                sessions.mutex.unlock(sessions.io);
                return err;
            };
            sessions.mutex.unlock(sessions.io);
            return result;
        }
        initial_session.last_seen = std.Io.Clock.real.now(sessions.io).toSeconds();
        lazer_presence_epoch = sessions.lazer_presence_epoch;
        stable_capture = captureStablePollLocked(allocator, sessions, initial_session, body) catch |err| {
            sessions.mutex.unlock(sessions.io);
            return err;
        };
    }
    sessions.mutex.unlock(sessions.io);
    defer stable_capture.deinit();

    var prepared_owner_auth = if (test_owner_auth) |fallback|
        try prepareOwnerAuthForDirectTest(allocator, store, stable_capture.owner_user_id, fallback)
    else
        try prepareOwnerAuth(allocator, store, stable_capture.owner_user_id);
    defer prepared_owner_auth.deinit();
    var prepared_stable = try prepareStableStats(allocator, store, &stable_capture);
    defer prepared_stable.deinit();
    var prepared_database = try prepareStableDatabase(allocator, store, &stable_capture, &prepared_owner_auth);
    defer prepared_database.deinit();
    var prepared_lazer = try prepareLazerPresences(allocator, store, body, lazer_presence_epoch, prepared_owner_auth.restricted);
    defer prepared_lazer.deinit();
    var prepared_unread: PreparedUnreadDirectMessages = if (prepared_owner_auth.restricted)
        .{ .allocator = allocator }
    else
        try prepareUnreadDirectMessages(allocator, store, stable_capture.owner_user_id, stable_capture.ownerName());
    defer prepared_unread.deinit();
    sessions.mutex.lockUncancelable(sessions.io);
    pruneExpiredLocked(allocator, sessions);
    pruneLazerPresenceLocked(allocator, sessions) catch |err| {
        sessions.mutex.unlock(sessions.io);
        return err;
    };
    const session = sessions.byToken(token) orelse {
        sessions.mutex.unlock(sessions.io);
        return null;
    };
    if (session.generation != stable_capture.owner_generation) {
        sessions.mutex.unlock(sessions.io);
        return null;
    }
    if (session.queue_overflowed) {
        removeSessionLocked(allocator, sessions, session);
        sessions.mutex.unlock(sessions.io);
        return null;
    }
    if (session.presence_suppressed) {
        const result = drainSuppressedLocked(allocator, sessions, session) catch |err| {
            sessions.mutex.unlock(sessions.io);
            return err;
        };
        sessions.mutex.unlock(sessions.io);
        return result;
    }
    applyOwnerAuthLocked(allocator, sessions, session, &prepared_owner_auth) catch |err| {
        sessions.mutex.unlock(sessions.io);
        return err;
    };
    const user_id = session.user.id;
    var logged_out = false;
    const result = pollLocked(allocator, sessions, session, body, &prepared_stable, &prepared_database, &prepared_lazer, &prepared_unread, &logged_out, &delivered_dm_ids, &deferred_public_messages) catch |err| {
        sessions.mutex.unlock(sessions.io);
        return err;
    };
    if (logged_out) removeSessionLocked(allocator, sessions, session);
    sessions.mutex.unlock(sessions.io);
    if (logged_out) {
        if (comptime storage.is_postgres) _ = try store.revokeStableScoreSessionsForUser(user_id);
    }
    markDeliveredDirectMessages(store, user_id, delivered_dm_ids.items);
    storeDeferredPublicMessages(store, deferred_public_messages.items);
    return result;
}

pub const PreparedSuppression = struct {
    allocator: std.mem.Allocator,
    queue: std.ArrayList(u8),

    pub fn deinit(self: *PreparedSuppression) void {
        self.queue.deinit(self.allocator);
        self.* = undefined;
    }
};

pub fn prepareSuppression(allocator: std.mem.Allocator, message: []const u8) !PreparedSuppression {
    var packet = protocol.Writer.init(allocator);
    errdefer packet.deinit();
    try packet.packetString(.notification, message);
    try packet.packetInt(.restart, 0);
    if (packet.bytes().len > sessions_mod.max_queue_bytes) return error.SessionQueueOverflow;
    const queue = packet.list;
    packet.list = .empty;
    return .{ .allocator = allocator, .queue = queue };
}

/// Applies a preallocated kick without any fallible allocation after a durable
/// credential, restriction or token transition has committed.
pub fn suppressPrepared(sessions: *sessions_mod.Sessions, user_id: i32, prepared: *PreparedSuppression) bool {
    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    const session = sessions.onlineByUser(user_id) orelse return false;
    const allocator = prepared.allocator;
    closeLobbyLocked(allocator, sessions, session, null) catch {};
    leaveMatchLocked(allocator, sessions, session, null);
    detachSpectatorLocked(allocator, sessions, session) catch {};
    clearSpectatorsForHostLocked(allocator, sessions, session);
    session.queue.deinit(allocator);
    session.queue = prepared.queue;
    prepared.queue = .empty;
    session.pending_dm_reads.clearRetainingCapacity();
    session.queue_overflowed = false;
    broadcastLogoutLocked(allocator, sessions, session);
    session.presence_suppressed = true;
    return true;
}

pub fn suppressForTakeover(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, user_id: i32, message: []const u8) !bool {
    var prepared = try prepareSuppression(allocator, message);
    defer prepared.deinit();
    return suppressPrepared(sessions, user_id, &prepared);
}

/// Roll back only the Stable session created by a login result whose
/// post-login takeover failed. Token ownership prevents a delayed cleanup from
/// removing a newer reconnect for the same account.
pub fn rollbackLogin(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, user_id: i32, token: []const u8) bool {
    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    const session = sessions.byToken(token) orelse return false;
    if (session.user.id != user_id) return false;
    removeSessionLocked(allocator, sessions, session);
    return true;
}

pub fn setUserCountryVisibility(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, user_id: i32, country_code: [2]u8, visible: bool) void {
    var event = protocol.Writer.init(allocator);
    defer event.deinit();
    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    const session = sessions.byUser(user_id) orelse return;
    session.user.country = country_code;
    session.user.show_country = visible;
    if (session.presence_suppressed or session.user.restricted) return;
    presence(&event, session) catch return;
    sessions.broadcast(event.bytes(), null) catch {};
}

pub fn disconnectRestrictedUser(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, user_id: i32) void {
    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    const session = sessions.byUser(user_id) orelse return;
    if (!session.is_bot) removeSessionLocked(allocator, sessions, session);
}

pub fn publishStats(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, user_id: i32, mode: u8, mods: i32) !void {
    var snapshot: StableStatsSnapshot = undefined;
    sessions.mutex.lockUncancelable(sessions.io);
    {
        const session = sessions.onlineByUser(user_id) orelse {
            sessions.mutex.unlock(sessions.io);
            return;
        };
        session.mode = mode;
        session.mods = mods;
        snapshot = StableStatsSnapshot.init(session);
    }
    sessions.mutex.unlock(sessions.io);

    var event = protocol.Writer.init(allocator);
    defer event.deinit();
    try stats(&event, store, &snapshot);

    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    const current = sessions.onlineByUser(user_id) orelse return;
    if (current.generation != snapshot.generation or current.mode != snapshot.mode or current.mods != snapshot.mods) return;
    try sessions.broadcast(event.bytes(), null);
}

pub fn noteLazerPresence(sessions: *sessions_mod.Sessions, user_id: i32, seen_at: i64) !void {
    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    try sessions.lazer_leases.put(user_id, seen_at);
}

fn noteLazerPresenceAtEpoch(sessions: *sessions_mod.Sessions, user_id: i32, seen_at: i64, expected_epoch: u64) !bool {
    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    if (sessions.lazer_presence_epoch != expected_epoch or sessions.onlineByUser(user_id) != null) return false;
    try sessions.lazer_leases.put(user_id, seen_at);
    return true;
}

pub fn publishLazerPresenceAtEpoch(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, user: domain.User, expected_epoch: u64) !void {
    if (user.restricted) return;
    const now = std.Io.Clock.real.now(sessions.io).toSeconds();
    sessions.mutex.lockUncancelable(sessions.io);
    if (sessions.lazer_presence_epoch != expected_epoch) {
        sessions.mutex.unlock(sessions.io);
        return;
    }
    if (sessions.onlineByUser(user.id) != null) {
        sessions.mutex.unlock(sessions.io);
        return;
    }
    if (sessions.lazer_leases.getPtr(user.id)) |last_seen| {
        last_seen.* = now;
        sessions.mutex.unlock(sessions.io);
        return;
    }
    sessions.mutex.unlock(sessions.io);

    const snapshot = LazerPresenceSnapshot.init(user);
    var event = protocol.Writer.init(allocator);
    defer event.deinit();
    try presence(&event, &snapshot);
    try stats(&event, store, &snapshot);
    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    if (sessions.lazer_presence_epoch != expected_epoch) return;
    if (sessions.onlineByUser(user.id) != null) return;
    if (sessions.lazer_leases.getPtr(user.id)) |last_seen| {
        last_seen.* = now;
        return;
    }
    try sessions.lazer_leases.put(user.id, now);
    try sessions.broadcast(event.bytes(), null);
}

pub fn publishLazerPresence(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, user: domain.User) !void {
    return publishLazerPresenceAtEpoch(allocator, store, sessions, user, captureLazerPresenceEpoch(sessions));
}

pub fn publishLazerLogout(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, user_id: i32) !void {
    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    sessions.lazer_presence_epoch +%= 1;
    if (!sessions.lazer_leases.remove(user_id)) return;
    broadcastUserLogoutLocked(allocator, sessions, user_id, null);
}

pub fn forgetLazerPresence(sessions: *sessions_mod.Sessions, user_id: i32) void {
    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    sessions.lazer_presence_epoch +%= 1;
    _ = sessions.lazer_leases.remove(user_id);
}

pub fn publishAnnouncement(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, text: []const u8) !void {
    var message = protocol.Writer.init(allocator);
    defer message.deinit();
    try protocol.writeMessage(&message, "kai", text, "#announce", 3);
    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    try sessions.broadcastChannel("#announce", message.bytes(), null);
}

test "lazer logout invalidates presence prepared by an earlier Stable poll" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/lazer-presence-epoch.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    const tokens = try store.issueGameTokenPair(user_id, 60, 60, false);

    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const prepared_epoch = captureLazerPresenceEpoch(&sessions);
    var payload: [6]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], 1, .little);
    std.mem.writeInt(i32, payload[2..6], user_id, .little);
    var request: [13]u8 = undefined;
    std.mem.writeInt(u16, request[0..2], @intFromEnum(protocol.ClientPacket.user_presence_request), .little);
    request[2] = 0;
    std.mem.writeInt(u32, request[3..7], payload.len, .little);
    @memcpy(request[7..], &payload);
    var prepared = try prepareLazerPresences(std.testing.allocator, &store, &request, prepared_epoch, false);
    defer prepared.deinit();
    try std.testing.expect(prepared.find(user_id) != null);

    try noteLazerPresence(&sessions, user_id, std.Io.Clock.real.now(std.testing.io).toSeconds());
    try std.testing.expect(try store.revokeToken(&tokens.refresh));
    try publishLazerLogout(std.testing.allocator, &sessions, user_id);

    var out = protocol.Writer.init(std.testing.allocator);
    defer out.deinit();
    sessions.mutex.lockUncancelable(sessions.io);
    const wrote_presence = writePreparedLazerPresence(&out, &sessions, &prepared, user_id, true, false) catch |err| {
        sessions.mutex.unlock(sessions.io);
        return err;
    };
    const lease_recreated = sessions.lazer_leases.contains(user_id);
    sessions.mutex.unlock(sessions.io);
    try std.testing.expect(!wrote_presence);
    try std.testing.expectEqual(@as(usize, 0), out.bytes().len);
    try std.testing.expect(!lease_recreated);
}

test "lazer logout invalidates an earlier Stable login presence snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/lazer-login-presence-epoch.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    const tokens = try store.issueGameTokenPair(user_id, 60, 60, false);

    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const snapshot_epoch = captureLazerPresenceEpoch(&sessions);
    const now = std.Io.Clock.real.now(std.testing.io).toSeconds();
    const online_ids = try store.recentOauthUserIds(std.testing.allocator, now - lazer_presence_lease_seconds);
    defer std.testing.allocator.free(online_ids);
    try std.testing.expectEqualSlices(i32, &.{user_id}, online_ids);

    try std.testing.expect(try store.revokeToken(&tokens.refresh));
    try publishLazerLogout(std.testing.allocator, &sessions, user_id);
    try std.testing.expect(!try noteLazerPresenceAtEpoch(&sessions, user_id, now, snapshot_epoch));
    try std.testing.expect(!sessions.lazer_leases.contains(user_id));
}

test "lazer logout invalidates authenticate then publish presence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/lazer-auth-presence-epoch.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    const tokens = try store.issueGameTokenPair(user_id, 60, 60, false);

    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const auth_epoch = captureLazerPresenceEpoch(&sessions);
    const user = (try store.authenticateToken(std.testing.allocator, &tokens.access, "identify")).?;
    defer {
        std.testing.allocator.free(user.name);
        std.testing.allocator.free(user.safe_name);
    }

    try std.testing.expect(try store.revokeToken(&tokens.refresh));
    try publishLazerLogout(std.testing.allocator, &sessions, user_id);
    try publishLazerPresenceAtEpoch(std.testing.allocator, &store, &sessions, user, auth_epoch);
    try std.testing.expect(!sessions.lazer_leases.contains(user_id));
}

test "Stable login accepts an existing one character username" {
    if (storage.is_postgres) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/stable-one-character-login.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("r", "r@example.invalid", "00000000000000000000000000000000");
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const login_body = "r\n00000000000000000000000000000000\nb20260811|0|0|11111111111111111111111111111111:1.2.3.:22222222222222222222222222222222:33333333333333333333333333333333:44444444444444444444444444444444:|0";
    var result = try login(std.testing.allocator, &store, &sessions, login_body, .{ 'A', 'U' }, 0, 0);
    defer result.deinit();
    try std.testing.expectEqual(user_id, result.user_id);
    try std.testing.expect(sessions.byToken(result.token) != null);
}

test "expected Stable login owner mismatch never creates a ghost session" {
    if (storage.is_postgres) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/stable-expected-owner.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const expected_id = try store.register("first owner", "first-owner@example.invalid", "00000000000000000000000000000000");
    const actual_id = try store.register("second owner", "second-owner@example.invalid", "11111111111111111111111111111111");
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const login_body = "second owner\n11111111111111111111111111111111\nb20260811|0|0|55555555555555555555555555555555:1.2.3.:66666666666666666666666666666666:77777777777777777777777777777777:88888888888888888888888888888888:|0";
    var result = try loginExpectedUser(std.testing.allocator, &store, &sessions, login_body, .{ 'A', 'U' }, 0, 0, expected_id);
    defer result.deinit();
    try std.testing.expectEqual(@as(i32, 0), result.user_id);
    try std.testing.expect(sessions.byUser(actual_id) == null);
    try std.testing.expect(sessions.byUser(expected_id) == null);
}

test "suppression clears host spectator relationships when notifications cannot allocate" {
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const host = try sessions.create(.{ .id = 40, .name = try std.testing.allocator.dupe(u8, "host"), .safe_name = try std.testing.allocator.dupe(u8, "host") }, 0, 0, 0);
    const watcher = try sessions.create(.{ .id = 41, .name = try std.testing.allocator.dupe(u8, "watcher"), .safe_name = try std.testing.allocator.dupe(u8, "watcher") }, 0, 0, 0);
    watcher.spectating_user_id = host.user.id;
    var empty: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&empty);
    sessions.mutex.lockUncancelable(std.testing.io);
    clearSpectatorsForHostLocked(failing.allocator(), &sessions, host);
    sessions.mutex.unlock(std.testing.io);
    try std.testing.expect(watcher.spectating_user_id == null);
}

test "failed Stable takeover rolls back only its login-owned session" {
    if (storage.is_postgres) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/stable-takeover-rollback.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const observer_id = try store.register("observer", "observer@example.invalid", "00000000000000000000000000000000");
    const user_id = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");

    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const observer_user = (try store.userById(std.testing.allocator, observer_id)).?;
    const observer = try sessions.create(observer_user, 0, 0, 0);
    const login_body = "ari\n00000000000000000000000000000000\nb20260811|0|0|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1.2.3.:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccc:dddddddddddddddddddddddddddddddd:|0";
    var result = try login(std.testing.allocator, &store, &sessions, login_body, .{ 'A', 'U' }, 0, 0);
    defer result.deinit();
    try std.testing.expectEqual(user_id, result.user_id);
    observer.queue.clearRetainingCapacity();

    var oauth_table_renamed = false;
    defer if (oauth_table_renamed) store.exec("ALTER TABLE oauth_tokens_unavailable RENAME TO oauth_tokens") catch {};
    try store.exec("ALTER TABLE oauth_tokens RENAME TO oauth_tokens_unavailable");
    oauth_table_renamed = true;
    try std.testing.expectError(error.DatabaseQueryFailed, store.revokeGameTokensForUser(user_id));
    try std.testing.expect(rollbackLogin(std.testing.allocator, &sessions, result.user_id, result.token));
    try store.exec("ALTER TABLE oauth_tokens_unavailable RENAME TO oauth_tokens");
    oauth_table_renamed = false;

    try std.testing.expect(sessions.byToken(result.token) == null);
    try std.testing.expect(sessions.byUser(user_id) == null);
    var logout_reader: protocol.Reader = .{ .data = observer.queue.items };
    const logout = (try logout_reader.next()).?;
    try std.testing.expectEqual(@intFromEnum(protocol.ServerPacket.user_logout), @intFromEnum(logout.id));
    var logout_payload: protocol.PayloadReader = .{ .data = logout.payload };
    try std.testing.expectEqual(user_id, try logout_payload.int(i32));
    try std.testing.expect((try logout_reader.next()) == null);

    var reconnect = try login(std.testing.allocator, &store, &sessions, login_body, .{ 'A', 'U' }, 0, 0);
    defer reconnect.deinit();
    const reconnect_token = try std.testing.allocator.dupe(u8, reconnect.token);
    defer std.testing.allocator.free(reconnect_token);
    var replacement = try login(std.testing.allocator, &store, &sessions, login_body, .{ 'A', 'U' }, 0, 0);
    defer replacement.deinit();
    try std.testing.expect(!rollbackLogin(std.testing.allocator, &sessions, user_id, reconnect_token));
    try std.testing.expect(sessions.byToken(replacement.token) != null);
}

test "Stable login rollback removes the session even when logout allocation fails" {
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    _ = try sessions.create(.{ .id = 7, .name = try std.testing.allocator.dupe(u8, "observer"), .safe_name = try std.testing.allocator.dupe(u8, "observer") }, 0, 0, 0);
    const login_session = try sessions.create(.{ .id = 8, .name = try std.testing.allocator.dupe(u8, "login"), .safe_name = try std.testing.allocator.dupe(u8, "login") }, 0, 0, 0);
    const token = login_session.token;
    var empty: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&empty);
    try std.testing.expect(rollbackLogin(failing.allocator(), &sessions, login_session.user.id, &token));
    try std.testing.expect(sessions.byUser(8) == null);
    try std.testing.expect(sessions.byToken(&token) == null);
}

fn cloneCommandWorldAllocationRun(allocator: std.mem.Allocator) !void {
    var source = sessions_mod.Sessions.init(allocator, std.testing.io);
    defer source.deinit();
    const owned_name = try allocator.dupe(u8, "allocation owner");
    const owned_safe_name = allocator.dupe(u8, "allocation_owner") catch |err| {
        allocator.free(owned_name);
        return err;
    };
    const session = source.create(.{ .id = 90, .name = owned_name, .safe_name = owned_safe_name }, 0, 0, 0) catch |err| {
        allocator.free(owned_name);
        allocator.free(owned_safe_name);
        return err;
    };
    try session.friend_ids.appendSlice(allocator, &.{ 3, 91, 92, 93 });
    var clone = try cloneCommandWorld(allocator, &source);
    defer clone.deinit();
    try std.testing.expectEqualSlices(i32, session.friend_ids.items, clone.byUser(90).?.friend_ids.items);
}

test "command world ownership survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cloneCommandWorldAllocationRun, .{});
}

test "prepared Stable stats reject a newer action from the same session generation" {
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const target = try sessions.create(.{ .id = 91, .name = try std.testing.allocator.dupe(u8, "stats target"), .safe_name = try std.testing.allocator.dupe(u8, "stats_target") }, 0, 0, 0);
    const snapshot = StableStatsSnapshot.init(target);
    var prepared: PreparedStableStats = .{ .allocator = std.testing.allocator, .owner_generation = target.generation };
    defer prepared.deinit();
    try prepared.items.append(std.testing.allocator, .{ .packet_index = 0, .snapshot = snapshot, .bytes = try std.testing.allocator.dupe(u8, "stale") });
    target.action = 2;
    try std.testing.expect(prepared.find(0, target) == null);
}
