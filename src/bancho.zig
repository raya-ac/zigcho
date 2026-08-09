const std = @import("std");
const protocol = @import("protocol.zig");
const sessions_mod = @import("sessions.zig");
const storage = @import("storage.zig");
const domain = @import("domain.zig");

pub const LoginResult = struct { token: []const u8, body: []u8 };

fn presence(w: *protocol.Writer, s: *const sessions_mod.Session) !void {
    const start = try w.begin(.user_presence);
    try w.int(i32, s.user.id);
    try w.string(s.user.name);
    try w.byte(@intCast(@as(i16, s.utc_offset) + 24));
    try w.byte(0);
    try w.byte(@intCast(1 | (@as(u8, s.mode) << 5)));
    try w.float(f32, 0);
    try w.float(f32, 0);
    try w.int(i32, 0);
    w.finish(start);
}

fn stats(w: *protocol.Writer, store: *storage.Store, s: *const sessions_mod.Session) !void {
    const current = (try store.statsForUser(s.user.id, s.mode)) orelse domain.Stats{};
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

pub fn login(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, body: []const u8) !LoginResult {
    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    var lines = std.mem.splitScalar(u8, body, '\n');
    const name = std.mem.trim(u8, lines.next() orelse "", "\r");
    const password = std.mem.trim(u8, lines.next() orelse "", "\r");
    const details = std.mem.trim(u8, lines.next() orelse "", "\r");
    var out = protocol.Writer.init(allocator);
    errdefer out.deinit();
    if (name.len < 2 or password.len != 32) {
        try out.packetInt(.user_id, -1);
        try out.packetString(.notification, "Invalid login request.");
        return .{ .token = "invalid-request", .body = try allocator.dupe(u8, out.bytes()) };
    }
    const user = (try store.authenticate(allocator, name, password)) orelse {
        try out.packetInt(.user_id, -1);
        try out.packetString(.notification, "Incorrect credentials.");
        return .{ .token = "no", .body = try allocator.dupe(u8, out.bytes()) };
    };
    var utc: i8 = 0;
    var detail_it = std.mem.splitScalar(u8, details, '|');
    _ = detail_it.next();
    if (detail_it.next()) |offset| utc = std.fmt.parseInt(i8, offset, 10) catch 0;
    const session = try sessions.create(user, utc);
    try out.packetInt(.protocol_version, 19);
    try out.packetInt(.user_id, user.id);
    try out.packetInt(.privileges, @intCast(user.privileges));
    try out.packetInt(.silence_end, @intCast(@max(0, user.silence_end - std.Io.Clock.real.now(sessions.io).toSeconds())));
    try presence(&out, session);
    try stats(&out, store, session);
    try protocol.writeChannel(&out, "#osu", "General discussion", 1);
    try protocol.writeChannel(&out, "#announce", "Server announcements", 1);
    try out.packetEmpty(.channel_info_end);
    for (sessions.items.items) |other| if (other != session) {
        try presence(&out, other);
        try stats(&out, store, other);
    };
    var announce = protocol.Writer.init(allocator);
    defer announce.deinit();
    try presence(&announce, session);
    try stats(&announce, store, session);
    try sessions.broadcast(announce.bytes(), session);
    const result = try allocator.dupe(u8, out.bytes());
    out.deinit();
    return .{ .token = &session.token, .body = result };
}

fn queuePacket(target: *sessions_mod.Session, allocator: std.mem.Allocator, bytes: []const u8) !void {
    try target.queue.appendSlice(allocator, bytes);
}

pub fn poll(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, session: *sessions_mod.Session, body: []const u8) ![]u8 {
    sessions.mutex.lockUncancelable(sessions.io);
    defer sessions.mutex.unlock(sessions.io);
    session.last_seen = std.Io.Clock.real.now(sessions.io).toSeconds();
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
        },
        .send_public_message, .send_private_message => {
            var p: protocol.PayloadReader = .{ .data = packet.payload };
            _ = try p.string();
            const text = try p.string();
            const target_name = try p.string();
            _ = try p.int(i32);
            if (text.len > 2000) continue;
            var message = protocol.Writer.init(allocator);
            defer message.deinit();
            try protocol.writeMessage(&message, session.user.name, text, target_name, session.user.id);
            if (packet.id == .send_private_message) {
                if (sessions.byName(target_name)) |target| try queuePacket(target, allocator, message.bytes());
            } else try sessions.broadcast(message.bytes(), session);
        },
        .channel_join => {
            var p: protocol.PayloadReader = .{ .data = packet.payload };
            try out.packetString(.channel_join_success, try p.string());
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
        .logout => return allocator.dupe(u8, out.bytes()),
        else => {},
    };
    return allocator.dupe(u8, out.bytes());
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
