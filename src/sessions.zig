const std = @import("std");
const domain = @import("domain.zig");
const multiplayer = @import("multiplayer.zig");

pub const max_queue_bytes = 1024 * 1024;
pub const max_stable_client_hash_bytes = 4096;

pub const ScoreTokenAuthorization = enum {
    exact,
    stale_online,
    foreign_live,
    offline,
    missing,
    client_version_mismatch,
    client_hardware_mismatch,
    missing_login_client_binding,
    invalid_client_binding,
};

/// Owned, immutable evidence shared by a real Stable login and score submit.
/// Stable login versions include the leading `b` and may include a stream,
/// while score submissions only send the eight-digit build date. The client
/// hash is the same five-field hardware value in both requests. We retain no
/// raw hardware identifiers on the session.
pub const StableClientBinding = struct {
    version_date: [8]u8,
    hardware_digest: [32]u8,

    pub fn init(osu_version: []const u8, client_hash: []const u8) !StableClientBinding {
        const version_date = try normalizedStableVersion(osu_version);
        const fields = try stableClientHashFields(client_hash);
        var digest: [32]u8 = undefined;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("zigcho-stable-client-binding-v1\x00");
        hashBindingField(&hash, fields.osu_path_md5);
        hashBindingField(&hash, fields.adapters);
        hashBindingField(&hash, fields.adapters_md5);
        hashBindingField(&hash, fields.uninstall_md5);
        hashBindingField(&hash, fields.disk_signature_md5);
        hash.final(&digest);
        return .{ .version_date = version_date, .hardware_digest = digest };
    }

    fn compare(self: StableClientBinding, submitted: StableClientBinding) ?ScoreTokenAuthorization {
        if (!std.crypto.timing_safe.eql([8]u8, self.version_date, submitted.version_date)) return .client_version_mismatch;
        if (!std.crypto.timing_safe.eql([32]u8, self.hardware_digest, submitted.hardware_digest)) return .client_hardware_mismatch;
        return null;
    }
};

const StableClientHashFields = struct {
    osu_path_md5: []const u8,
    adapters: []const u8,
    adapters_md5: []const u8,
    uninstall_md5: []const u8,
    disk_signature_md5: []const u8,
};

fn normalizedStableVersion(value: []const u8) ![8]u8 {
    const date = if (value.len == 8) value else if (value.len >= 9 and value[0] == 'b') value[1..9] else return error.InvalidStableClientVersion;
    for (date) |char| if (!std.ascii.isDigit(char)) return error.InvalidStableClientVersion;
    if (value.len != 8) {
        var remainder = value[9..];
        if (remainder.len >= 2 and remainder[0] == '.' and std.ascii.isDigit(remainder[1])) remainder = remainder[2..];
        if (remainder.len != 0 and
            !std.mem.eql(u8, remainder, "beta") and
            !std.mem.eql(u8, remainder, "cuttingedge") and
            !std.mem.eql(u8, remainder, "dev") and
            !std.mem.eql(u8, remainder, "tourney")) return error.InvalidStableClientVersion;
    }
    return date[0..8].*;
}

fn stableClientHashFields(value: []const u8) !StableClientHashFields {
    if (value.len < 2 or value.len > max_stable_client_hash_bytes or value[value.len - 1] != ':') return error.InvalidStableClientHash;
    var fields = std.mem.splitScalar(u8, value[0 .. value.len - 1], ':');
    const osu_path_md5 = fields.next() orelse return error.InvalidStableClientHash;
    const adapters = fields.next() orelse return error.InvalidStableClientHash;
    const adapters_md5 = fields.next() orelse return error.InvalidStableClientHash;
    const uninstall_md5 = fields.next() orelse return error.InvalidStableClientHash;
    const disk_signature_md5 = fields.next() orelse return error.InvalidStableClientHash;
    if (fields.next() != null or !validMd5(osu_path_md5) or !validMd5(adapters_md5) or !validMd5(uninstall_md5) or !validMd5(disk_signature_md5)) return error.InvalidStableClientHash;
    if (std.mem.eql(u8, adapters, "runningunderwine")) return .{
        .osu_path_md5 = osu_path_md5,
        .adapters = adapters,
        .adapters_md5 = adapters_md5,
        .uninstall_md5 = uninstall_md5,
        .disk_signature_md5 = disk_signature_md5,
    };
    if (adapters.len < 2 or adapters[adapters.len - 1] != '.') return error.InvalidStableClientHash;
    var adapter_parts = std.mem.splitScalar(u8, adapters[0 .. adapters.len - 1], '.');
    var any_adapter = false;
    while (adapter_parts.next()) |adapter| if (adapter.len != 0) {
        any_adapter = true;
        for (adapter) |char| if (char == 0 or char == ':') return error.InvalidStableClientHash;
    };
    if (!any_adapter) return error.InvalidStableClientHash;
    return .{
        .osu_path_md5 = osu_path_md5,
        .adapters = adapters,
        .adapters_md5 = adapters_md5,
        .uninstall_md5 = uninstall_md5,
        .disk_signature_md5 = disk_signature_md5,
    };
}

fn validMd5(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |char| if (!std.ascii.isHex(char)) return false;
    return true;
}

fn hashBindingField(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(value.len), .little);
    hash.update(&length);
    for (value) |char| {
        const normalized = [1]u8{std.ascii.toLower(char)};
        hash.update(&normalized);
    }
}

fn scoreBindingDecision(session: *const Session, submitted_binding: ?StableClientBinding) ?ScoreTokenAuthorization {
    const submitted = submitted_binding orelse return .invalid_client_binding;
    const login = session.stable_client_binding orelse return .missing_login_client_binding;
    return login.compare(submitted);
}

pub const PublicPresence = struct {
    action: u8,
    mode: u8,
    mods: i32,
    map_id: i32,
    info_text: [96]u8,
    info_len: usize,

    pub fn info(self: *const PublicPresence) []const u8 {
        return self.info_text[0..self.info_len];
    }
};

pub const Session = struct {
    token: [64]u8,
    generation: u64,
    stable_client_binding: ?StableClientBinding = null,
    user: domain.User,
    utc_offset: i8 = 0,
    action: u8 = 0,
    mode: u8 = 0,
    mods: i32 = 0,
    map_id: i32 = 0,
    map_md5: [32]u8 = [_]u8{0} ** 32,
    info_text: [96]u8 = [_]u8{0} ** 96,
    info_len: usize = 0,
    login_time: i64,
    last_seen: i64,
    friend_ids: std.ArrayList(i32) = .empty,
    block_non_friend_dms: bool = false,
    presence_filter: u8 = 0,
    away_message: [512]u8 = [_]u8{0} ** 512,
    away_message_len: usize = 0,
    queue: std.ArrayList(u8) = .empty,
    pending_dm_reads: std.ArrayList(i64) = .empty,
    queue_overflowed: bool = false,
    presence_suppressed: bool = false,
    is_bot: bool = false,
    joined_osu: bool = false,
    joined_announce: bool = false,
    in_lobby: bool = false,
    joined_lobby_channel: bool = false,
    match_id: ?u16 = null,
    tourney_matches: u64 = 0,
    spectating_user_id: ?i32 = null,
    longitude: f32 = 0,
    latitude: f32 = 0,

    pub fn info(self: *const Session) []const u8 {
        return self.info_text[0..self.info_len];
    }
    pub fn away(self: *const Session) []const u8 {
        return self.away_message[0..self.away_message_len];
    }
    pub fn isFriend(self: *const Session, user_id: i32) bool {
        return std.mem.indexOfScalar(i32, self.friend_ids.items, user_id) != null;
    }
    pub fn addFriend(self: *Session, allocator: std.mem.Allocator, user_id: i32) !void {
        if (self.isFriend(user_id)) return;
        try self.friend_ids.append(allocator, user_id);
    }
    pub fn removeFriend(self: *Session, user_id: i32) void {
        const index = std.mem.indexOfScalar(i32, self.friend_ids.items, user_id) orelse return;
        _ = self.friend_ids.orderedRemove(index);
    }
    pub fn joined(self: *const Session, name: []const u8) bool {
        if (std.mem.eql(u8, name, "#osu")) return self.joined_osu;
        if (std.mem.eql(u8, name, "#announce")) return self.joined_announce;
        if (std.mem.eql(u8, name, "#lobby")) return self.joined_lobby_channel;
        if (std.mem.eql(u8, name, "#multiplayer")) return self.match_id != null or self.tourney_matches != 0;
        return false;
    }
    pub fn tournamentJoined(self: *const Session, match_id: u16) bool {
        if (match_id >= multiplayer.max_matches) return false;
        return self.tourney_matches & (@as(u64, 1) << @intCast(match_id)) != 0;
    }
    pub fn joinTournament(self: *Session, match_id: u16) void {
        if (match_id < multiplayer.max_matches) self.tourney_matches |= @as(u64, 1) << @intCast(match_id);
    }
    pub fn partTournament(self: *Session, match_id: u16) void {
        if (match_id < multiplayer.max_matches) self.tourney_matches &= ~(@as(u64, 1) << @intCast(match_id));
    }
    pub fn visibleMatchId(self: *const Session) ?u16 {
        if (self.match_id) |match_id| return match_id;
        if (self.tourney_matches == 0 or self.tourney_matches & (self.tourney_matches - 1) != 0) return null;
        return @intCast(@ctz(self.tourney_matches));
    }
    pub fn enqueue(self: *Session, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (self.queue_overflowed) return;
        const next_len = std.math.add(usize, self.queue.items.len, bytes.len) catch max_queue_bytes + 1;
        if (next_len > max_queue_bytes) {
            self.queue.deinit(allocator);
            self.queue = .empty;
            self.pending_dm_reads.clearRetainingCapacity();
            self.queue_overflowed = true;
            return;
        }
        try self.queue.appendSlice(allocator, bytes);
    }
    pub fn enqueueDirectMessage(self: *Session, allocator: std.mem.Allocator, message_id: i64, bytes: []const u8) !void {
        if (self.queue_overflowed) return;
        const next_len = std.math.add(usize, self.queue.items.len, bytes.len) catch max_queue_bytes + 1;
        if (next_len > max_queue_bytes) {
            self.queue.deinit(allocator);
            self.queue = .empty;
            self.pending_dm_reads.clearRetainingCapacity();
            self.queue_overflowed = true;
            return;
        }
        try self.queue.ensureUnusedCapacity(allocator, bytes.len);
        try self.pending_dm_reads.ensureUnusedCapacity(allocator, 1);
        self.queue.appendSliceAssumeCapacity(bytes);
        self.pending_dm_reads.appendAssumeCapacity(message_id);
    }
};

pub const Sessions = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(*Session) = .empty,
    by_token: std.StringHashMap(*Session),
    by_user: std.AutoHashMap(i32, *Session),
    by_safe_name: std.StringHashMap(*Session),
    lazer_leases: std.AutoHashMap(i32, i64),
    lazer_presence_epoch: u64 = 0,
    next_session_generation: u64 = 1,
    matches: [multiplayer.max_matches]?multiplayer.Match = [_]?multiplayer.Match{null} ** multiplayer.max_matches,

    pub fn init(a: std.mem.Allocator, io: std.Io) Sessions {
        return .{
            .allocator = a,
            .io = io,
            .by_token = std.StringHashMap(*Session).init(a),
            .by_user = std.AutoHashMap(i32, *Session).init(a),
            .by_safe_name = std.StringHashMap(*Session).init(a),
            .lazer_leases = std.AutoHashMap(i32, i64).init(a),
        };
    }
    pub fn deinit(self: *Sessions) void {
        for (&self.matches) |*entry| if (entry.*) |*match| match.deinit();
        for (self.items.items) |s| {
            s.friend_ids.deinit(self.allocator);
            s.queue.deinit(self.allocator);
            s.pending_dm_reads.deinit(self.allocator);
            self.allocator.free(s.user.name);
            self.allocator.free(s.user.safe_name);
            self.allocator.destroy(s);
        }
        self.items.deinit(self.allocator);
        self.by_token.deinit();
        self.by_user.deinit();
        self.by_safe_name.deinit();
        self.lazer_leases.deinit();
    }
    fn takeSessionGeneration(self: *Sessions) u64 {
        const generation = self.next_session_generation;
        self.next_session_generation +%= 1;
        if (self.next_session_generation == 0) self.next_session_generation = 1;
        return generation;
    }
    fn createWithBinding(self: *Sessions, user: domain.User, utc_offset: i8, longitude: f32, latitude: f32, stable_client_binding: ?StableClientBinding) !*Session {
        const s = try self.allocator.create(Session);
        errdefer self.allocator.destroy(s);
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        s.* = .{ .token = undefined, .generation = self.takeSessionGeneration(), .stable_client_binding = stable_client_binding, .user = user, .utc_offset = utc_offset, .login_time = now, .last_seen = now, .longitude = longitude, .latitude = latitude };
        var random: [32]u8 = undefined;
        try std.Io.randomSecure(self.io, &random);
        _ = std.fmt.bufPrint(&s.token, "{x}", .{random}) catch unreachable;
        try self.items.ensureUnusedCapacity(self.allocator, 1);
        try self.by_token.ensureUnusedCapacity(1);
        try self.by_user.ensureUnusedCapacity(1);
        try self.by_safe_name.ensureUnusedCapacity(1);
        if (self.byUser(user.id)) |old| self.remove(old);
        self.items.appendAssumeCapacity(s);
        self.by_token.putAssumeCapacityNoClobber(&s.token, s);
        self.by_user.putAssumeCapacityNoClobber(user.id, s);
        self.by_safe_name.putAssumeCapacityNoClobber(user.safe_name, s);
        return s;
    }
    pub fn create(self: *Sessions, user: domain.User, utc_offset: i8, longitude: f32, latitude: f32) !*Session {
        return self.createWithBinding(user, utc_offset, longitude, latitude, null);
    }
    pub fn createBound(self: *Sessions, user: domain.User, utc_offset: i8, longitude: f32, latitude: f32, stable_client_binding: StableClientBinding) !*Session {
        return self.createWithBinding(user, utc_offset, longitude, latitude, stable_client_binding);
    }
    pub fn createWithSocial(self: *Sessions, user: domain.User, utc_offset: i8, longitude: f32, latitude: f32, friend_ids: []i32, block_non_friend_dms: bool, stable_client_binding: StableClientBinding) !*Session {
        errdefer self.allocator.free(friend_ids);
        const session = try self.createWithBinding(user, utc_offset, longitude, latitude, stable_client_binding);
        session.friend_ids = .fromOwnedSlice(friend_ids);
        session.block_non_friend_dms = block_non_friend_dms;
        return session;
    }
    pub fn createBot(self: *Sessions, user: domain.User) !*Session {
        const s = try self.allocator.create(Session);
        errdefer self.allocator.destroy(s);
        s.* = .{
            .token = [_]u8{0} ** 64,
            .generation = self.takeSessionGeneration(),
            .user = user,
            .login_time = std.math.maxInt(i64),
            .last_seen = std.math.maxInt(i64),
            .is_bot = true,
            .joined_osu = true,
            .joined_announce = true,
        };
        try self.items.ensureUnusedCapacity(self.allocator, 1);
        try self.by_user.ensureUnusedCapacity(1);
        try self.by_safe_name.ensureUnusedCapacity(1);
        if (self.byUser(user.id)) |old| self.remove(old);
        self.items.appendAssumeCapacity(s);
        self.by_user.putAssumeCapacityNoClobber(user.id, s);
        self.by_safe_name.putAssumeCapacityNoClobber(user.safe_name, s);
        return s;
    }
    pub fn byToken(self: *Sessions, token: []const u8) ?*Session {
        return self.by_token.get(token);
    }
    pub fn byUser(self: *Sessions, id: i32) ?*Session {
        return self.by_user.get(id);
    }
    pub fn onlineByUser(self: *Sessions, id: i32) ?*Session {
        const session = self.byUser(id) orelse return null;
        return if (session.presence_suppressed) null else session;
    }
    pub fn byName(self: *Sessions, name: []const u8) ?*Session {
        var safe_buffer: [96]u8 = undefined;
        if (name.len == 0 or name.len > safe_buffer.len) return null;
        for (name, 0..) |char, index| safe_buffer[index] = if (char == ' ') '_' else std.ascii.toLower(char);
        return self.by_safe_name.get(safe_buffer[0..name.len]);
    }
    pub fn onlineByName(self: *Sessions, name: []const u8) ?*Session {
        const session = self.byName(name) orelse return null;
        return if (session.presence_suppressed) null else session;
    }
    pub fn matchById(self: *Sessions, id: u16) ?*multiplayer.Match {
        if (id >= self.matches.len) return null;
        if (self.matches[id]) |*match| return match;
        return null;
    }
    pub fn freeMatchId(self: *const Sessions) ?u16 {
        for (self.matches, 0..) |entry, index| if (entry == null) return @intCast(index);
        return null;
    }
    pub fn authorizeScoreToken(self: *Sessions, token: ?[]const u8, user_id: i32, submitted_binding: ?StableClientBinding) ScoreTokenAuthorization {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const present_token = token orelse return .missing;
        if (self.byToken(present_token)) |session| {
            if (session.presence_suppressed) return .offline;
            if (session.user.id != user_id) return .foreign_live;
            return scoreBindingDecision(session, submitted_binding) orelse .exact;
        }
        const online = self.onlineByUser(user_id) orelse return .offline;
        return scoreBindingDecision(online, submitted_binding) orelse .stale_online;
    }
    pub fn remove(self: *Sessions, target: *Session) void {
        for (self.items.items) |session| {
            if (session.spectating_user_id == target.user.id) session.spectating_user_id = null;
        }
        target.spectating_user_id = null;
        if (target.match_id) |match_id| if (self.matchById(match_id)) |match| {
            _ = match.removeReferee(target.user.id);
            if (match.slotByUser(target.user.id)) |slot| slot.reset(.open);
            if (match.isEmpty()) {
                match.deinit();
                self.matches[match_id] = null;
            } else if (match.host_id == target.user.id) {
                match.host_id = match.firstUser().?;
            }
            target.match_id = null;
        };
        for (self.items.items, 0..) |s, i| if (s == target) {
            if (!s.is_bot) _ = self.by_token.remove(&s.token);
            _ = self.by_user.remove(s.user.id);
            _ = self.by_safe_name.remove(s.user.safe_name);
            _ = self.items.swapRemove(i);
            s.friend_ids.deinit(self.allocator);
            s.queue.deinit(self.allocator);
            s.pending_dm_reads.deinit(self.allocator);
            self.allocator.free(s.user.name);
            self.allocator.free(s.user.safe_name);
            self.allocator.destroy(s);
            return;
        };
    }
    pub fn broadcast(self: *Sessions, bytes: []const u8, except: ?*Session) !void {
        for (self.items.items) |s| if (s != except and !s.is_bot and !s.presence_suppressed) try s.enqueue(self.allocator, bytes);
    }
    pub fn humanCount(self: *const Sessions) usize {
        var count: usize = 0;
        for (self.items.items) |s| if (!s.is_bot and !s.presence_suppressed) {
            count += 1;
        };
        return count;
    }
    pub fn onlineUserIds(self: *Sessions, allocator: std.mem.Allocator) ![]i32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var ids: std.ArrayList(i32) = .empty;
        errdefer ids.deinit(allocator);
        try ids.ensureTotalCapacity(allocator, self.items.items.len);
        for (self.items.items) |session| if (!session.presence_suppressed) ids.appendAssumeCapacity(session.user.id);
        return ids.toOwnedSlice(allocator);
    }
    pub fn publicPresence(self: *Sessions, user_id: i32) ?PublicPresence {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const session = self.byUser(user_id) orelse return null;
        if (session.is_bot or session.user.restricted or session.presence_suppressed) return null;
        return .{
            .action = session.action,
            .mode = session.mode,
            .mods = session.mods,
            .map_id = session.map_id,
            .info_text = session.info_text,
            .info_len = session.info_len,
        };
    }
    pub fn channelCount(self: *const Sessions, name: []const u8) usize {
        var count: usize = 0;
        for (self.items.items) |s| if (!s.presence_suppressed and s.joined(name)) {
            count += 1;
        };
        return count;
    }
    pub fn join(self: *Sessions, session: *Session, name: []const u8) bool {
        _ = self;
        if (std.mem.eql(u8, name, "#osu")) {
            if (session.joined_osu) return false;
            session.joined_osu = true;
        } else if (std.mem.eql(u8, name, "#announce")) {
            if (session.joined_announce) return false;
            session.joined_announce = true;
        } else if (std.mem.eql(u8, name, "#lobby") and session.in_lobby) {
            if (session.joined_lobby_channel) return false;
            session.joined_lobby_channel = true;
        } else {
            return false;
        }
        return true;
    }
    pub fn part(self: *Sessions, session: *Session, name: []const u8) void {
        _ = self;
        if (std.mem.eql(u8, name, "#osu"))
            session.joined_osu = false
        else if (std.mem.eql(u8, name, "#announce"))
            session.joined_announce = false
        else if (std.mem.eql(u8, name, "#lobby"))
            session.joined_lobby_channel = false;
    }
    pub fn broadcastChannel(self: *Sessions, name: []const u8, bytes: []const u8, except: ?*Session) !void {
        for (self.items.items) |s| if (s != except and !s.is_bot and !s.presence_suppressed and s.joined(name)) {
            try s.enqueue(self.allocator, bytes);
        };
    }
};

test "session indices follow replacement and removal" {
    const allocator = std.testing.allocator;
    var sessions = Sessions.init(allocator, std.testing.io);
    defer sessions.deinit();

    const first = try sessions.create(.{
        .id = 10,
        .name = try allocator.dupe(u8, "Raya Player"),
        .safe_name = try allocator.dupe(u8, "raya_player"),
    }, 0, 0, 0);
    const stale_token = first.token;
    try std.testing.expect(sessions.byToken(&stale_token) == first);
    try std.testing.expect(sessions.byUser(10) == first);
    try std.testing.expect(sessions.byName("raya player") == first);
    try std.testing.expect(sessions.byName("RAYA_PLAYER") == first);
    first.presence_suppressed = true;
    try std.testing.expectEqual(@as(usize, 0), sessions.humanCount());

    const replacement = try sessions.create(.{
        .id = 10,
        .name = try allocator.dupe(u8, "Raya Player"),
        .safe_name = try allocator.dupe(u8, "raya_player"),
    }, 0, 0, 0);
    try std.testing.expect(sessions.byToken(&stale_token) == null);
    try std.testing.expect(sessions.byUser(10) == replacement);
    try std.testing.expect(sessions.byName("raya player") == replacement);
    try std.testing.expect(!replacement.presence_suppressed);
    try std.testing.expectEqual(@as(usize, 1), sessions.humanCount());

    const replacement_token = replacement.token;
    sessions.remove(replacement);
    try std.testing.expect(sessions.byToken(&replacement_token) == null);
    try std.testing.expect(sessions.byUser(10) == null);
    try std.testing.expect(sessions.byName("raya player") == null);
}

test "online user snapshot includes bot and human sessions" {
    const allocator = std.testing.allocator;
    var sessions = Sessions.init(allocator, std.testing.io);
    defer sessions.deinit();
    _ = try sessions.createBot(.{
        .id = 3,
        .name = try allocator.dupe(u8, "kai"),
        .safe_name = try allocator.dupe(u8, "kai"),
    });
    _ = try sessions.create(.{
        .id = 4,
        .name = try allocator.dupe(u8, "ari"),
        .safe_name = try allocator.dupe(u8, "ari"),
    }, 0, 0, 0);
    const ids = try sessions.onlineUserIds(allocator);
    defer allocator.free(ids);
    try std.testing.expectEqualSlices(i32, &.{ 3, 4 }, ids);
}

test "public presence copies Stable client activity without borrowing a session" {
    const allocator = std.testing.allocator;
    var sessions = Sessions.init(allocator, std.testing.io);
    defer sessions.deinit();
    const session = try sessions.create(.{
        .id = 4,
        .name = try allocator.dupe(u8, "ari"),
        .safe_name = try allocator.dupe(u8, "ari"),
    }, 0, 0, 0);
    session.action = 2;
    session.mode = 0;
    session.mods = 64;
    session.map_id = 75;
    @memcpy(session.info_text[0..7], "playing");
    session.info_len = 7;
    const presence = sessions.publicPresence(4).?;
    sessions.remove(session);
    try std.testing.expectEqual(@as(u8, 2), presence.action);
    try std.testing.expectEqual(@as(i32, 75), presence.map_id);
    try std.testing.expectEqualStrings("playing", presence.info());
}

test "superseded Stable sessions stay connected only long enough to receive their kick" {
    const allocator = std.testing.allocator;
    var sessions = Sessions.init(allocator, std.testing.io);
    defer sessions.deinit();
    const session = try sessions.create(.{
        .id = 4,
        .name = try allocator.dupe(u8, "ari"),
        .safe_name = try allocator.dupe(u8, "ari"),
    }, 0, 0, 0);
    session.action = 2;
    session.map_id = 75;
    session.joined_osu = true;
    const token = session.token;
    session.presence_suppressed = true;

    try std.testing.expect(sessions.byUser(4) == session);
    try std.testing.expect(sessions.onlineByUser(4) == null);
    try std.testing.expect(sessions.onlineByName("ari") == null);
    try std.testing.expect(sessions.publicPresence(4) == null);
    try std.testing.expectEqual(ScoreTokenAuthorization.offline, sessions.authorizeScoreToken(&token, 4, null));
    try std.testing.expectEqual(ScoreTokenAuthorization.offline, sessions.authorizeScoreToken("stale", 4, null));
    try std.testing.expectEqual(@as(usize, 0), sessions.channelCount("#osu"));
    try sessions.broadcast("presence", null);
    try sessions.broadcastChannel("#osu", "chat", null);
    try std.testing.expectEqual(@as(usize, 0), session.queue.items.len);
    const ids = try sessions.onlineUserIds(allocator);
    defer allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 0), ids.len);
}

test "direct-message queue owns exact unread rows and drops them with discarded bytes" {
    const allocator = std.testing.allocator;
    var sessions = Sessions.init(allocator, std.testing.io);
    defer sessions.deinit();
    const session = try sessions.create(.{
        .id = 4,
        .name = try allocator.dupe(u8, "ari"),
        .safe_name = try allocator.dupe(u8, "ari"),
    }, 0, 0, 0);
    try session.enqueueDirectMessage(allocator, 71, "message");
    try std.testing.expectEqualStrings("message", session.queue.items);
    try std.testing.expectEqualSlices(i64, &.{71}, session.pending_dm_reads.items);

    const fill = try allocator.alloc(u8, max_queue_bytes);
    defer allocator.free(fill);
    @memset(fill, 1);
    try session.enqueue(allocator, fill);
    try std.testing.expect(session.queue_overflowed);
    try std.testing.expectEqual(@as(usize, 0), session.pending_dm_reads.items.len);
}

test "Stable client bindings normalize only fields shared by login and score submit" {
    const login = try StableClientBinding.init(
        "b20260811.1cuttingedge",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:AA.BB.CC.:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC:DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD:",
    );
    const submit = try StableClientBinding.init(
        "20260811",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:aa.bb.cc.:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccc:dddddddddddddddddddddddddddddddd:",
    );
    try std.testing.expectEqual(login.version_date, submit.version_date);
    try std.testing.expectEqual(login.hardware_digest, submit.hardware_digest);

    const other_hardware = try StableClientBinding.init(
        "20260811",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:11.22.33.:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccc:dddddddddddddddddddddddddddddddd:",
    );
    try std.testing.expect(!std.crypto.timing_safe.eql([32]u8, login.hardware_digest, other_hardware.hardware_digest));
    try std.testing.expectError(error.InvalidStableClientVersion, StableClientBinding.init("b2026bad!", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1.2.3.:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccc:dddddddddddddddddddddddddddddddd:"));
    try std.testing.expectError(error.InvalidStableClientVersion, StableClientBinding.init("b20260811garbage", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1.2.3.:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccc:dddddddddddddddddddddddddddddddd:"));
    try std.testing.expectError(error.InvalidStableClientHash, StableClientBinding.init("20260811", "not-a-client-hash"));
}

test "score authorization binds exact and stale tokens to the live Stable client" {
    const allocator = std.testing.allocator;
    var sessions = Sessions.init(allocator, std.testing.io);
    defer sessions.deinit();
    const binding = try StableClientBinding.init(
        "b20260811",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1.2.3.:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccc:dddddddddddddddddddddddddddddddd:",
    );
    const wrong_version = try StableClientBinding.init(
        "20260812",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1.2.3.:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccc:dddddddddddddddddddddddddddddddd:",
    );
    const wrong_hardware = try StableClientBinding.init(
        "20260811",
        "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee:4.5.6.:ffffffffffffffffffffffffffffffff:11111111111111111111111111111111:22222222222222222222222222222222:",
    );
    const ari = try sessions.createBound(.{
        .id = 1,
        .name = try allocator.dupe(u8, "ari"),
        .safe_name = try allocator.dupe(u8, "ari"),
    }, 0, 0, 0, binding);
    const other = try sessions.createBound(.{
        .id = 2,
        .name = try allocator.dupe(u8, "other"),
        .safe_name = try allocator.dupe(u8, "other"),
    }, 0, 0, 0, wrong_hardware);
    const token = ari.token;
    const foreign_token = other.token;

    try std.testing.expectEqual(ScoreTokenAuthorization.exact, sessions.authorizeScoreToken(&token, 1, binding));
    try std.testing.expectEqual(ScoreTokenAuthorization.stale_online, sessions.authorizeScoreToken("queued-after-restart", 1, binding));
    try std.testing.expectEqual(ScoreTokenAuthorization.client_version_mismatch, sessions.authorizeScoreToken(&token, 1, wrong_version));
    try std.testing.expectEqual(ScoreTokenAuthorization.client_hardware_mismatch, sessions.authorizeScoreToken("queued-after-restart", 1, wrong_hardware));
    try std.testing.expectEqual(ScoreTokenAuthorization.invalid_client_binding, sessions.authorizeScoreToken(&token, 1, null));
    try std.testing.expectEqual(ScoreTokenAuthorization.foreign_live, sessions.authorizeScoreToken(&foreign_token, 1, binding));
    try std.testing.expectEqual(ScoreTokenAuthorization.missing, sessions.authorizeScoreToken(null, 1, null));

    ari.presence_suppressed = true;
    try std.testing.expectEqual(ScoreTokenAuthorization.offline, sessions.authorizeScoreToken(&token, 1, binding));
    try std.testing.expectEqual(ScoreTokenAuthorization.offline, sessions.authorizeScoreToken("queued-after-restart", 1, binding));
}
