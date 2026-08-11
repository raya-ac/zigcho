const std = @import("std");
const pp = @import("pp.zig");
const storage = @import("runtime_storage.zig");
const beatmap = @import("beatmap.zig");
const sessions_mod = @import("sessions.zig");
const protocol = @import("protocol.zig");
const stable_score = @import("stable_score.zig");

pub const PpResult = struct {
    pp: f64,
    stars: f64,
    max_combo: u32,
    mods_str: []const u8,
};

pub const CommandResult = enum { handled, not_command };

const unrestricted: u32 = 1 << 0;
const supporter: u32 = 1 << 4;
const premium: u32 = 1 << 5;
const tournament: u32 = 1 << 10;
const nominator: u32 = 1 << 11;
const moderator: u32 = 1 << 12;
const administrator: u32 = 1 << 13;
const developer: u32 = 1 << 14;
const staff = moderator | administrator | developer;

pub fn handleCommand(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, sender: *sessions_mod.Session, text: []const u8, reply_target: []const u8, out: *protocol.Writer) !CommandResult {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '!') return .not_command;
    const body = trimmed[1..];
    const separator = std.mem.indexOfScalar(u8, body, ' ') orelse body.len;
    const cmd = body[0..separator];
    const args = if (separator == body.len) "" else std.mem.trim(u8, body[separator + 1 ..], " \t");

    if (std.ascii.eqlIgnoreCase(cmd, "help") or std.ascii.eqlIgnoreCase(cmd, "h")) {
        var message: []const u8 = "player: !help !roll [max] !online !stats [name] !np !with <mods acc% misses>";
        if (has(sender, moderator)) message = "player: !help !roll !online !stats !np !with | mod: !user !silence !unsilence !kick !addnote !notes";
        if (has(sender, administrator)) message = "player: !help !roll !online !stats !np !with | mod: !user !silence !unsilence !kick !addnote !notes | admin: !restrict !unrestrict !announce !alert !lock !unlock";
        if (has(sender, developer)) message = "player: !help !roll !online !stats !np !with | mod: !user !silence !unsilence !kick !addnote !notes | admin: !restrict !unrestrict !announce !alert !lock !unlock | dev: !addpriv !rmpriv";
        try reply(allocator, sessions, sender, reply_target, out, message);
        return .handled;
    }
    if (std.ascii.eqlIgnoreCase(cmd, "np")) {
        handleNp(allocator, store, sender) catch {};
        return .handled;
    }
    if (std.ascii.eqlIgnoreCase(cmd, "with")) {
        handleWith(allocator, store, sender, args) catch {};
        return .handled;
    }
    if (std.ascii.eqlIgnoreCase(cmd, "roll")) {
        const maximum = if (args.len == 0) 100 else std.fmt.parseInt(u16, args, 10) catch 100;
        if (maximum == 0) {
            try reply(allocator, sessions, sender, reply_target, out, "roll what?");
            return .handled;
        }
        var random: [2]u8 = undefined;
        try std.Io.randomSecure(sessions.io, &random);
        const rolled = std.mem.readInt(u16, &random, .little) % maximum;
        var buf: [128]u8 = undefined;
        const message = try std.fmt.bufPrint(&buf, "{s} rolls {d} points!", .{ sender.user.name, rolled });
        try reply(allocator, sessions, sender, reply_target, out, message);
        return .handled;
    }
    if (std.ascii.eqlIgnoreCase(cmd, "online")) {
        var buf: [96]u8 = undefined;
        const message = try std.fmt.bufPrint(&buf, "{d} player{s} online right now", .{ sessions.humanCount(), if (sessions.humanCount() == 1) "" else "s" });
        try reply(allocator, sessions, sender, reply_target, out, message);
        return .handled;
    }
    if (std.ascii.eqlIgnoreCase(cmd, "stats")) {
        var user = if (args.len == 0)
            (try store.userById(allocator, sender.user.id)) orelse return .handled
        else
            (try store.userByName(allocator, args)) orelse {
                try reply(allocator, sessions, sender, reply_target, out, "player not found");
                return .handled;
            };
        defer freeUser(allocator, &user);
        const stats_mode = stable_score.statsMode(sender.mode, sender.mods) orelse sender.mode;
        const player_stats = (try store.statsForUser(user.id, stats_mode)) orelse {
            try reply(allocator, sessions, sender, reply_target, out, "stats not found");
            return .handled;
        };
        var buf: [256]u8 = undefined;
        const message = try std.fmt.bufPrint(&buf, "{s} | #{d} | {d}pp | {d} plays | {d:.2}% | {d}x", .{ user.name, player_stats.global_rank, player_stats.pp, player_stats.plays, player_stats.accuracy, player_stats.max_combo });
        try reply(allocator, sessions, sender, reply_target, out, message);
        return .handled;
    }
    if (std.ascii.eqlIgnoreCase(cmd, "user")) {
        if (!has(sender, moderator)) return try denied(allocator, sessions, sender, reply_target, out);
        const name = if (args.len == 0) sender.user.name else args;
        var target = (try store.userByName(allocator, name)) orelse {
            try reply(allocator, sessions, sender, reply_target, out, "player not found");
            return .handled;
        };
        defer freeUser(allocator, &target);
        var buf: [320]u8 = undefined;
        const message = try std.fmt.bufPrint(&buf, "{s} ({d}) | country {s} | priv {d} | restricted {any} | silence ends {d} | online {any}", .{ target.name, target.id, &target.country, target.privileges, target.restricted, target.silence_end, sessions.byUser(target.id) != null });
        try reply(allocator, sessions, sender, reply_target, out, message);
        return .handled;
    }
    if (std.ascii.eqlIgnoreCase(cmd, "silence")) return try silenceCommand(allocator, store, sessions, sender, args, reply_target, out, false);
    if (std.ascii.eqlIgnoreCase(cmd, "unsilence")) return try silenceCommand(allocator, store, sessions, sender, args, reply_target, out, true);
    if (std.ascii.eqlIgnoreCase(cmd, "restrict")) return try restrictionCommand(allocator, store, sessions, sender, args, reply_target, out, true);
    if (std.ascii.eqlIgnoreCase(cmd, "unrestrict")) return try restrictionCommand(allocator, store, sessions, sender, args, reply_target, out, false);
    if (std.ascii.eqlIgnoreCase(cmd, "kick")) return try kickCommand(allocator, store, sessions, sender, args, reply_target, out);
    if (std.ascii.eqlIgnoreCase(cmd, "announce") or std.ascii.eqlIgnoreCase(cmd, "alert")) {
        if (!has(sender, administrator)) return try denied(allocator, sessions, sender, reply_target, out);
        if (args.len == 0) {
            try reply(allocator, sessions, sender, reply_target, out, "usage: !announce <message>");
            return .handled;
        }
        try store.recordAudit(sender.user.id, if (std.ascii.eqlIgnoreCase(cmd, "alert")) "server.alert" else "channel.announce", if (std.ascii.eqlIgnoreCase(cmd, "alert")) "server" else "#announce", args);
        var packet = protocol.Writer.init(allocator);
        defer packet.deinit();
        if (std.ascii.eqlIgnoreCase(cmd, "alert"))
            try packet.packetString(.notification, args)
        else
            try protocol.writeMessage(&packet, "kai", args, "#announce", 3);
        if (std.ascii.eqlIgnoreCase(cmd, "alert"))
            try sessions.broadcast(packet.bytes(), null)
        else
            try sessions.broadcastChannel("#announce", packet.bytes(), null);
        try reply(allocator, sessions, sender, reply_target, out, "sent");
        return .handled;
    }
    if (std.ascii.eqlIgnoreCase(cmd, "lock") or std.ascii.eqlIgnoreCase(cmd, "unlock")) {
        if (!has(sender, administrator)) return try denied(allocator, sessions, sender, reply_target, out);
        const parsed = splitTargetReason(args) orelse {
            try reply(allocator, sessions, sender, reply_target, out, if (std.ascii.eqlIgnoreCase(cmd, "lock")) "usage: !lock <#channel> <reason>" else "usage: !unlock <#channel> <reason>");
            return .handled;
        };
        const locked = std.ascii.eqlIgnoreCase(cmd, "lock");
        store.setChannelLocked(sender.user.id, parsed.name, locked, parsed.rest) catch |err| switch (err) {
            error.InvalidChannel => {
                try reply(allocator, sessions, sender, reply_target, out, "unknown channel");
                return .handled;
            },
            else => return err,
        };
        try reply(allocator, sessions, sender, reply_target, out, if (locked) "channel locked" else "channel unlocked");
        return .handled;
    }
    if (std.ascii.eqlIgnoreCase(cmd, "addnote")) {
        if (!has(sender, moderator)) return try denied(allocator, sessions, sender, reply_target, out);
        var parts = std.mem.splitScalar(u8, args, ' ');
        const name = parts.next() orelse "";
        const note = std.mem.trim(u8, args[@min(args.len, name.len)..], " ");
        if (name.len == 0 or note.len == 0) {
            try reply(allocator, sessions, sender, reply_target, out, "usage: !addnote <name> <note>");
            return .handled;
        }
        var target = (try store.userByName(allocator, name)) orelse {
            try reply(allocator, sessions, sender, reply_target, out, "player not found");
            return .handled;
        };
        defer freeUser(allocator, &target);
        if (!canManage(sender, target)) return try protected(allocator, sessions, sender, reply_target, out);
        try store.addModerationNote(sender.user.id, target.id, note);
        try reply(allocator, sessions, sender, reply_target, out, "note added");
        return .handled;
    }
    if (std.ascii.eqlIgnoreCase(cmd, "notes")) {
        if (!has(sender, moderator)) return try denied(allocator, sessions, sender, reply_target, out);
        if (args.len == 0) {
            try reply(allocator, sessions, sender, reply_target, out, "usage: !notes <name>");
            return .handled;
        }
        var target = (try store.userByName(allocator, args)) orelse {
            try reply(allocator, sessions, sender, reply_target, out, "player not found");
            return .handled;
        };
        defer freeUser(allocator, &target);
        if (!canManage(sender, target)) return try protected(allocator, sessions, sender, reply_target, out);
        const notes = try store.moderationNotes(allocator, target.id, 10);
        defer allocator.free(notes);
        try reply(allocator, sessions, sender, reply_target, out, if (notes.len == 0) "no moderation history" else notes);
        return .handled;
    }
    if (std.ascii.eqlIgnoreCase(cmd, "addpriv") or std.ascii.eqlIgnoreCase(cmd, "rmpriv")) {
        if (!has(sender, developer)) return try denied(allocator, sessions, sender, reply_target, out);
        return try privilegeCommand(allocator, store, sessions, sender, args, reply_target, out, std.ascii.eqlIgnoreCase(cmd, "addpriv"));
    }
    return .not_command;
}

fn has(sender: *const sessions_mod.Session, bits: u32) bool {
    return sender.user.privileges & bits == bits;
}

fn stableClientPrivileges(server: u32) u8 {
    var client: u8 = 1 << 2;
    if (server & unrestricted != 0) client |= 1 << 0;
    if (server & (supporter | premium) != 0) client |= 1 << 2;
    if (server & moderator != 0) client |= 1 << 1;
    if (server & administrator != 0) client |= 1 << 4;
    if (server & developer != 0) client |= 1 << 3;
    return client;
}

fn freeUser(allocator: std.mem.Allocator, user: *const @import("domain.zig").User) void {
    allocator.free(user.name);
    allocator.free(user.safe_name);
}

fn reply(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, sender: *sessions_mod.Session, target: []const u8, out: *protocol.Writer, text: []const u8) !void {
    var message = protocol.Writer.init(allocator);
    defer message.deinit();
    try protocol.writeMessage(&message, "kai", text, target, 3);
    try out.raw(message.bytes());
    if (target.len != 0 and target[0] == '#') try sessions.broadcastChannel(target, message.bytes(), sender);
}

fn denied(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, sender: *sessions_mod.Session, target: []const u8, out: *protocol.Writer) !CommandResult {
    try reply(allocator, sessions, sender, target, out, "you do not have permission for that");
    return .handled;
}

fn protected(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, sender: *sessions_mod.Session, target: []const u8, out: *protocol.Writer) !CommandResult {
    try reply(allocator, sessions, sender, target, out, "only developers can manage staff members");
    return .handled;
}

fn canManage(sender: *const sessions_mod.Session, target: @import("domain.zig").User) bool {
    if (target.id == 3 or target.id == sender.user.id) return false;
    return target.privileges & staff == 0 or has(sender, developer);
}

fn splitTargetReason(args: []const u8) ?struct { name: []const u8, rest: []const u8 } {
    const first = std.mem.indexOfScalar(u8, args, ' ') orelse return null;
    const name = std.mem.trim(u8, args[0..first], " ");
    const rest = std.mem.trim(u8, args[first + 1 ..], " ");
    if (name.len == 0 or rest.len == 0) return null;
    return .{ .name = name, .rest = rest };
}

fn parseDuration(value: []const u8) ?i64 {
    if (value.len < 2) return null;
    const amount = std.fmt.parseInt(i64, value[0 .. value.len - 1], 10) catch return null;
    if (amount <= 0) return null;
    const multiplier: i64 = switch (std.ascii.toLower(value[value.len - 1])) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        'w' => 604800,
        else => return null,
    };
    const seconds = std.math.mul(i64, amount, multiplier) catch return null;
    if (seconds > 365 * 86400) return null;
    return seconds;
}

fn silenceCommand(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, sender: *sessions_mod.Session, args: []const u8, reply_target: []const u8, out: *protocol.Writer, undo: bool) !CommandResult {
    if (!has(sender, moderator)) return try denied(allocator, sessions, sender, reply_target, out);
    const first = splitTargetReason(args) orelse {
        try reply(allocator, sessions, sender, reply_target, out, if (undo) "usage: !unsilence <name> <reason>" else "usage: !silence <name> <duration> <reason>");
        return .handled;
    };
    var reason = first.rest;
    var seconds: i64 = 0;
    if (!undo) {
        const duration_end = std.mem.indexOfScalar(u8, first.rest, ' ') orelse {
            try reply(allocator, sessions, sender, reply_target, out, "usage: !silence <name> <duration> <reason>");
            return .handled;
        };
        seconds = parseDuration(first.rest[0..duration_end]) orelse {
            try reply(allocator, sessions, sender, reply_target, out, "invalid duration; use 30m, 2h, 7d, or 1w");
            return .handled;
        };
        reason = std.mem.trim(u8, first.rest[duration_end + 1 ..], " ");
        if (reason.len == 0) return .handled;
    }
    var target = (try store.userByName(allocator, first.name)) orelse {
        try reply(allocator, sessions, sender, reply_target, out, "player not found");
        return .handled;
    };
    defer freeUser(allocator, &target);
    if (!canManage(sender, target)) return try protected(allocator, sessions, sender, reply_target, out);
    const now = std.Io.Clock.real.now(sessions.io).toSeconds();
    const silence_end = if (undo) now else now + seconds;
    try store.setSilence(sender.user.id, target.id, silence_end, if (undo) "account.unsilence" else "account.silence", reason);
    if (sessions.byUser(target.id)) |online| {
        online.user.silence_end = silence_end;
        var packet = protocol.Writer.init(allocator);
        defer packet.deinit();
        try packet.packetInt(.silence_end, @intCast(if (undo) 0 else seconds));
        try online.enqueue(allocator, packet.bytes());
        if (!undo) {
            packet.list.clearRetainingCapacity();
            try packet.packetInt(.user_silenced, target.id);
            try sessions.broadcast(packet.bytes(), null);
        }
    }
    var buf: [128]u8 = undefined;
    const message = try std.fmt.bufPrint(&buf, "{s} was {s}", .{ target.name, if (undo) "unsilenced" else "silenced" });
    try reply(allocator, sessions, sender, reply_target, out, message);
    return .handled;
}

fn restrictionCommand(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, sender: *sessions_mod.Session, args: []const u8, reply_target: []const u8, out: *protocol.Writer, restrict: bool) !CommandResult {
    if (!has(sender, administrator)) return try denied(allocator, sessions, sender, reply_target, out);
    const parsed = splitTargetReason(args) orelse {
        try reply(allocator, sessions, sender, reply_target, out, if (restrict) "usage: !restrict <name> <reason>" else "usage: !unrestrict <name> <reason>");
        return .handled;
    };
    var target = (try store.userByName(allocator, parsed.name)) orelse {
        try reply(allocator, sessions, sender, reply_target, out, "player not found");
        return .handled;
    };
    defer freeUser(allocator, &target);
    if (!canManage(sender, target)) return try protected(allocator, sessions, sender, reply_target, out);
    if (target.restricted == restrict) {
        try reply(allocator, sessions, sender, reply_target, out, if (restrict) "player is already restricted" else "player is not restricted");
        return .handled;
    }
    try store.setRestricted(sender.user.id, target.id, restrict, parsed.rest);
    if (sessions.byUser(target.id)) |online| {
        online.user.restricted = restrict;
        var packet = protocol.Writer.init(allocator);
        defer packet.deinit();
        if (restrict) {
            try packet.packetEmpty(.account_restricted);
            var visibility = protocol.Writer.init(allocator);
            defer visibility.deinit();
            const start = try visibility.begin(.user_logout);
            try visibility.int(i32, target.id);
            try visibility.byte(0);
            visibility.finish(start);
            try sessions.broadcast(visibility.bytes(), online);
        }
        try packet.packetInt(.restart, 0);
        try online.enqueue(allocator, packet.bytes());
    }
    var buf: [128]u8 = undefined;
    const message = try std.fmt.bufPrint(&buf, "{s} was {s}", .{ target.name, if (restrict) "restricted" else "unrestricted" });
    try reply(allocator, sessions, sender, reply_target, out, message);
    return .handled;
}

fn kickCommand(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, sender: *sessions_mod.Session, args: []const u8, reply_target: []const u8, out: *protocol.Writer) !CommandResult {
    if (!has(sender, moderator)) return try denied(allocator, sessions, sender, reply_target, out);
    const parsed = splitTargetReason(args) orelse {
        try reply(allocator, sessions, sender, reply_target, out, "usage: !kick <name> <reason>");
        return .handled;
    };
    var target = (try store.userByName(allocator, parsed.name)) orelse {
        try reply(allocator, sessions, sender, reply_target, out, "player not found");
        return .handled;
    };
    defer freeUser(allocator, &target);
    if (!canManage(sender, target)) return try protected(allocator, sessions, sender, reply_target, out);
    const online = sessions.byUser(target.id) orelse {
        try reply(allocator, sessions, sender, reply_target, out, "player is not online");
        return .handled;
    };
    try store.recordModerationAction(sender.user.id, target.id, "account.kick", parsed.rest);
    var packet = protocol.Writer.init(allocator);
    defer packet.deinit();
    try packet.packetString(.notification, parsed.rest);
    try packet.packetInt(.restart, 0);
    try online.enqueue(allocator, packet.bytes());
    try reply(allocator, sessions, sender, reply_target, out, "player kicked");
    return .handled;
}

fn privilegeBits(args: []const u8) ?u32 {
    var bits: u32 = 0;
    var values = std.mem.splitScalar(u8, args, ' ');
    while (values.next()) |value| {
        if (value.len == 0) continue;
        bits |= if (std.ascii.eqlIgnoreCase(value, "normal")) unrestricted else if (std.ascii.eqlIgnoreCase(value, "supporter")) supporter else if (std.ascii.eqlIgnoreCase(value, "premium")) premium else if (std.ascii.eqlIgnoreCase(value, "tournament")) tournament else if (std.ascii.eqlIgnoreCase(value, "nominator")) nominator else if (std.ascii.eqlIgnoreCase(value, "mod")) moderator else if (std.ascii.eqlIgnoreCase(value, "admin")) administrator else if (std.ascii.eqlIgnoreCase(value, "developer")) developer else return null;
    }
    return if (bits == 0) null else bits;
}

fn privilegeCommand(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, sender: *sessions_mod.Session, args: []const u8, reply_target: []const u8, out: *protocol.Writer, add: bool) !CommandResult {
    const parsed = splitTargetReason(args) orelse {
        try reply(allocator, sessions, sender, reply_target, out, if (add) "usage: !addpriv <name> <roles>" else "usage: !rmpriv <name> <roles>");
        return .handled;
    };
    const bits = privilegeBits(parsed.rest) orelse {
        try reply(allocator, sessions, sender, reply_target, out, "unknown role");
        return .handled;
    };
    var target = (try store.userByName(allocator, parsed.name)) orelse {
        try reply(allocator, sessions, sender, reply_target, out, "player not found");
        return .handled;
    };
    defer freeUser(allocator, &target);
    if (!canManage(sender, target)) return try protected(allocator, sessions, sender, reply_target, out);
    const privileges = try store.changePrivileges(sender.user.id, target.id, bits, add);
    if (sessions.byUser(target.id)) |online| {
        online.user.privileges = privileges;
        var packet = protocol.Writer.init(allocator);
        defer packet.deinit();
        try packet.packetInt(.privileges, stableClientPrivileges(privileges));
        try online.enqueue(allocator, packet.bytes());
    }
    try reply(allocator, sessions, sender, reply_target, out, "privileges updated");
    return .handled;
}

pub fn handleNp(allocator: std.mem.Allocator, store: *storage.Store, sender: *sessions_mod.Session) !void {
    const md5 = sender.map_md5;
    if (md5[0] == 0) {
        try sendPm(allocator, sender, "do /np first so i know what map you're on");
        return;
    }
    const map_file = (try store.beatmapFile(allocator, &md5)) orelse {
        try sendPm(allocator, sender, "i don't have that map yet, try again in a sec");
        return;
    };
    defer allocator.free(map_file);
    const meta = beatmap.parse(map_file) catch {
        try sendPm(allocator, sender, "couldn't parse the map file");
        return;
    };
    var mod_buf: [32]u8 = undefined;
    const mods_str = modString(&mod_buf, sender.mods);
    const result = pp.calculate(map_file, .{
        .mode = sender.mode,
        .lazer = 0,
        .mods = @intCast(sender.mods),
        .max_combo = meta.object_count,
        .n_geki = if (sender.mode == 3) meta.object_count else 0,
        .n_katu = 0,
        .n300 = meta.object_count,
        .n100 = 0,
        .n50 = 0,
        .misses = 0,
        .legacy_total_score = 1_000_000,
    }) catch {
        try sendPm(allocator, sender, "pp calc failed on this map");
        return;
    };
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} — {s} [{s}] | ★ {d:.2} | {s} | {d:.2}pp (100%, FC)", .{ meta.artist, meta.title, meta.version, result.stars, mods_str, result.pp }) catch return;
    try sendPm(allocator, sender, msg);
}

fn handleWith(allocator: std.mem.Allocator, store: *storage.Store, sender: *sessions_mod.Session, args: []const u8) !void {
    const md5 = sender.map_md5;
    if (md5[0] == 0) {
        try sendPm(allocator, sender, "do /np first so i know what map you're on");
        return;
    }
    const map_file = (try store.beatmapFile(allocator, &md5)) orelse {
        try sendPm(allocator, sender, "i don't have that map yet, try again in a sec");
        return;
    };
    defer allocator.free(map_file);
    const meta = beatmap.parse(map_file) catch {
        try sendPm(allocator, sender, "couldn't parse the map file");
        return;
    };

    var mods: i32 = sender.mods;
    var accuracy: f64 = 100.0;
    var misses: u32 = 0;
    var combo_pct: f64 = 100.0;

    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, args, " "), ' ');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        var lower_buf: [32]u8 = undefined;
        const lower_len = @min(part.len, lower_buf.len);
        for (part[0..lower_len], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        const lower = lower_buf[0..lower_len];
        if (std.mem.endsWith(u8, lower, "%") and lower.len > 1) {
            const val = std.fmt.parseFloat(f64, lower[0 .. lower.len - 1]) catch continue;
            if (val > 0 and val <= 100) {
                if (accuracy == 100.0 and misses == 0) accuracy = val else combo_pct = val;
            }
        } else if (std.mem.endsWith(u8, lower, "m") and lower.len > 1) {
            misses = std.fmt.parseInt(u32, lower[0 .. lower.len - 1], 10) catch continue;
        } else {
            const parsed = parseMods(lower) orelse continue;
            mods = parsed;
        }
    }

    var mod_buf: [32]u8 = undefined;
    const mods_str = modString(&mod_buf, mods);
    const total_objects = meta.object_count;
    const total_hits = if (misses > total_objects) total_objects else total_objects - misses;
    const acc = accuracy / 100.0;
    const n300_f: f64 = @max(0, @as(f64, @floatFromInt(total_hits)) * (3.0 * acc - 1.0) / 2.0);
    const n300: u32 = @intFromFloat(@min(@as(f64, @floatFromInt(total_hits)), std.math.round(n300_f)));
    const n100: u32 = total_hits -| n300;
    const max_combo_f: f64 = @as(f64, @floatFromInt(meta.object_count)) * combo_pct / 100.0;
    const max_combo: u32 = @intFromFloat(std.math.round(max_combo_f));

    const result = pp.calculate(map_file, .{
        .mode = sender.mode,
        .lazer = 0,
        .mods = @intCast(mods),
        .max_combo = max_combo,
        .n_geki = if (sender.mode == 3) total_hits else 0,
        .n_katu = 0,
        .n300 = n300,
        .n100 = n100,
        .n50 = 0,
        .misses = misses,
        .legacy_total_score = 1_000_000,
    }) catch {
        try sendPm(allocator, sender, "pp calc failed on this map");
        return;
    };
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} — {s} [{s}] | ★ {d:.2} | {s} | {d:.2}pp ({d:.1}%, {d}x combo, {d}m)", .{ meta.artist, meta.title, meta.version, result.stars, mods_str, result.pp, accuracy, max_combo, misses }) catch return;
    try sendPm(allocator, sender, msg);
}

fn parseMods(str: []const u8) ?i32 {
    var mods: i32 = 0;
    var i: usize = 0;
    while (i + 1 < str.len) : (i += 2) {
        const pair = str[i..][0..2];
        const bit: i32 = if (std.mem.eql(u8, pair, "nf")) 1 << 0 //
        else if (std.mem.eql(u8, pair, "ez")) 1 << 1 //
        else if (std.mem.eql(u8, pair, "hd")) 1 << 3 //
        else if (std.mem.eql(u8, pair, "hr")) 1 << 4 //
        else if (std.mem.eql(u8, pair, "sd")) 1 << 5 //
        else if (std.mem.eql(u8, pair, "dt")) 1 << 6 //
        else if (std.mem.eql(u8, pair, "rx")) 1 << 7 //
        else if (std.mem.eql(u8, pair, "ht")) 1 << 8 //
        else if (std.mem.eql(u8, pair, "nc")) 1 << 10 //
        else if (std.mem.eql(u8, pair, "fl")) 1 << 12 //
        else if (std.mem.eql(u8, pair, "ap")) 1 << 13 //
        else if (std.mem.eql(u8, pair, "so")) 1 << 14 //
        else if (std.mem.eql(u8, pair, "at")) 1 << 15 //
        else if (std.mem.eql(u8, pair, "cn")) 1 << 16 //
        else if (std.mem.eql(u8, pair, "tp")) 1 << 17 //
        else if (std.mem.eql(u8, pair, "fi")) 1 << 20 //
        else if (std.mem.eql(u8, pair, "rn")) 1 << 22 //
        else if (std.mem.eql(u8, pair, "cl")) 1 << 23 //
        else if (std.mem.eql(u8, pair, "v2")) 1 << 27 //
        else if (std.mem.eql(u8, pair, "mr")) 1 << 29 //
        else return null;
        mods |= bit;
    }
    return mods;
}

fn modString(buf: *[32]u8, mods: i32) []const u8 {
    if (mods == 0) return "NM";
    var pos: usize = 0;
    const mod_names = [_]struct { bit: i32, name: []const u8 }{
        .{ .bit = 1 << 0, .name = "NF" },
        .{ .bit = 1 << 1, .name = "EZ" },
        .{ .bit = 1 << 3, .name = "HD" },
        .{ .bit = 1 << 4, .name = "HR" },
        .{ .bit = 1 << 5, .name = "SD" },
        .{ .bit = 1 << 6, .name = "DT" },
        .{ .bit = 1 << 7, .name = "RX" },
        .{ .bit = 1 << 8, .name = "HT" },
        .{ .bit = 1 << 10, .name = "NC" },
        .{ .bit = 1 << 12, .name = "FL" },
        .{ .bit = 1 << 13, .name = "AP" },
        .{ .bit = 1 << 14, .name = "SO" },
        .{ .bit = 1 << 15, .name = "AT" },
        .{ .bit = 1 << 16, .name = "CN" },
        .{ .bit = 1 << 17, .name = "TP" },
        .{ .bit = 1 << 20, .name = "FI" },
        .{ .bit = 1 << 22, .name = "RN" },
        .{ .bit = 1 << 23, .name = "CL" },
        .{ .bit = 1 << 27, .name = "V2" },
        .{ .bit = 1 << 29, .name = "MR" },
    };
    for (mod_names) |m| {
        if (mods & m.bit != 0) {
            @memcpy(buf[pos..][0..2], m.name);
            pos += 2;
        }
    }
    if (pos == 0) return "NM";
    return buf[0..pos];
}

fn sendPm(allocator: std.mem.Allocator, sender: *sessions_mod.Session, text: []const u8) !void {
    var msg = protocol.Writer.init(allocator);
    defer msg.deinit();
    try protocol.writeMessage(&msg, "kai", text, sender.user.name, 3);
    try sender.enqueue(allocator, msg.bytes());
}
