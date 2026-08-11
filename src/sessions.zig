const std = @import("std");
const domain = @import("domain.zig");

pub const max_queue_bytes = 1024 * 1024;

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
    longitude: f32 = 0,
    latitude: f32 = 0,

    pub fn info(self: *const Session) []const u8 {
        return self.info_text[0..self.info_len];
    }
    pub fn joined(self: *const Session, name: []const u8) bool {
        if (std.mem.eql(u8, name, "#osu")) return self.joined_osu;
        if (std.mem.eql(u8, name, "#announce")) return self.joined_announce;
        return false;
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

    pub fn init(a: std.mem.Allocator, io: std.Io) Sessions {
        return .{ .allocator = a, .io = io };
    }
    pub fn deinit(self: *Sessions) void {
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
    pub fn remove(self: *Sessions, target: *Session) void {
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
        if (std.mem.eql(u8, name, "#osu")) session.joined_osu = true else if (std.mem.eql(u8, name, "#announce")) session.joined_announce = true else return false;
        return true;
    }
    pub fn part(self: *Sessions, session: *Session, name: []const u8) void {
        _ = self;
        if (std.mem.eql(u8, name, "#osu")) session.joined_osu = false else if (std.mem.eql(u8, name, "#announce")) session.joined_announce = false;
    }
    pub fn broadcastChannel(self: *Sessions, name: []const u8, bytes: []const u8, except: ?*Session) !void {
        for (self.items.items) |s| if (s != except and !s.is_bot and s.joined(name)) {
            try s.enqueue(self.allocator, bytes);
        };
    }
};
