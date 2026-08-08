const std = @import("std");
const domain = @import("domain.zig");

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
    last_seen: i64,
    queue: std.ArrayList(u8) = .empty,

    pub fn info(self: *const Session) []const u8 {
        return self.info_text[0..self.info_len];
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
    pub fn create(self: *Sessions, user: domain.User, utc_offset: i8) !*Session {
        if (self.byUser(user.id)) |old| self.remove(old);
        const s = try self.allocator.create(Session);
        s.* = .{ .token = undefined, .user = user, .utc_offset = utc_offset, .last_seen = std.Io.Clock.real.now(self.io).toSeconds() };
        var random: [32]u8 = undefined;
        try std.Io.randomSecure(self.io, &random);
        _ = std.fmt.bufPrint(&s.token, "{x}", .{random}) catch unreachable;
        try self.items.append(self.allocator, s);
        return s;
    }
    pub fn byToken(self: *Sessions, token: []const u8) ?*Session {
        for (self.items.items) |s| if (std.mem.eql(u8, &s.token, token)) return s;
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
        for (self.items.items) |s| if (s != except) try s.queue.appendSlice(self.allocator, bytes);
    }
};
