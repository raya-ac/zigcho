const std = @import("std");
const domain = @import("domain.zig");
const multiplayer = @import("multiplayer.zig");

pub const max_queue_bytes = 1024 * 1024;
pub const ScoreTokenAuthorization = enum { exact, stale_online, foreign_live, offline, missing };

pub const Session = struct {
    token: [64]u8,
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
    queue: std.ArrayList(u8) = .empty,
    queue_overflowed: bool = false,
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
            self.queue_overflowed = true;
            return;
        }
        try self.queue.appendSlice(allocator, bytes);
    }
};

pub const Sessions = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(*Session) = .empty,
    matches: [multiplayer.max_matches]?multiplayer.Match = [_]?multiplayer.Match{null} ** multiplayer.max_matches,

    pub fn init(a: std.mem.Allocator, io: std.Io) Sessions {
        return .{ .allocator = a, .io = io };
    }
    pub fn deinit(self: *Sessions) void {
        for (&self.matches) |*entry| if (entry.*) |*match| match.deinit();
        for (self.items.items) |s| {
            s.queue.deinit(self.allocator);
            self.allocator.free(s.user.name);
            self.allocator.free(s.user.safe_name);
            self.allocator.destroy(s);
        }
        self.items.deinit(self.allocator);
    }
    pub fn create(self: *Sessions, user: domain.User, utc_offset: i8, longitude: f32, latitude: f32) !*Session {
        if (self.byUser(user.id)) |old| self.remove(old);
        const s = try self.allocator.create(Session);
        errdefer self.allocator.destroy(s);
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        s.* = .{ .token = undefined, .user = user, .utc_offset = utc_offset, .login_time = now, .last_seen = now, .longitude = longitude, .latitude = latitude };
        var random: [32]u8 = undefined;
        try std.Io.randomSecure(self.io, &random);
        _ = std.fmt.bufPrint(&s.token, "{x}", .{random}) catch unreachable;
        try self.items.append(self.allocator, s);
        return s;
    }
    pub fn createBot(self: *Sessions, user: domain.User) !*Session {
        if (self.byUser(user.id)) |old| self.remove(old);
        const s = try self.allocator.create(Session);
        errdefer self.allocator.destroy(s);
        s.* = .{
            .token = [_]u8{0} ** 64,
            .user = user,
            .login_time = std.math.maxInt(i64),
            .last_seen = std.math.maxInt(i64),
            .is_bot = true,
            .joined_osu = true,
            .joined_announce = true,
        };
        try self.items.append(self.allocator, s);
        return s;
    }
    pub fn byToken(self: *Sessions, token: []const u8) ?*Session {
        for (self.items.items) |s| if (!s.is_bot and std.mem.eql(u8, &s.token, token)) return s;
        return null;
    }
    pub fn byUser(self: *Sessions, id: i32) ?*Session {
        for (self.items.items) |s| if (s.user.id == id) return s;
        return null;
    }
    pub fn byName(self: *Sessions, name: []const u8) ?*Session {
        for (self.items.items) |s| if (std.ascii.eqlIgnoreCase(s.user.name, name)) return s;
        return null;
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
    pub fn authorizeScoreToken(self: *Sessions, token: ?[]const u8, user_id: i32) ScoreTokenAuthorization {
        const present_token = token orelse return .missing;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.byToken(present_token)) |session| {
            return if (session.user.id == user_id) .exact else .foreign_live;
        }
        return if (self.byUser(user_id) != null) .stale_online else .offline;
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
            _ = self.items.swapRemove(i);
            s.queue.deinit(self.allocator);
            self.allocator.free(s.user.name);
            self.allocator.free(s.user.safe_name);
            self.allocator.destroy(s);
            return;
        };
    }
    pub fn broadcast(self: *Sessions, bytes: []const u8, except: ?*Session) !void {
        for (self.items.items) |s| if (s != except and !s.is_bot) try s.enqueue(self.allocator, bytes);
    }
    pub fn humanCount(self: *const Sessions) usize {
        var count: usize = 0;
        for (self.items.items) |s| if (!s.is_bot) {
            count += 1;
        };
        return count;
    }
    pub fn channelCount(self: *const Sessions, name: []const u8) usize {
        var count: usize = 0;
        for (self.items.items) |s| if (s.joined(name)) {
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
        for (self.items.items) |s| if (s != except and !s.is_bot and s.joined(name)) {
            try s.enqueue(self.allocator, bytes);
        };
    }
};
