const std = @import("std");
const domain = @import("domain.zig");
const pp = @import("exact_pp.zig");
const storage = @import("runtime_storage.zig");
const beatmap = @import("beatmap.zig");
const sessions_mod = @import("sessions.zig");
const protocol = @import("protocol.zig");
const stable_score = @import("stable_score.zig");
const stable_mods = @import("stable_mods.zig");
const account_roles = @import("account_roles.zig");

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
        var message: []const u8 = "player: /np !with <mods acc% misses> !pin !unpin !roll [max] !online !stats [name] !request !mapstate";
        if (has(sender, moderator)) message = "player: /np !with !pin !unpin !roll !online !stats !request !mapstate | mod: !user !silence !unsilence !kick !addnote !notes";
        if (isNominator(sender)) message = "player: /np !with !pin !unpin !roll !online !stats !request !mapstate | bn: !requests !nominate !mapstatus !veto !qualify !rank !approve !love";
        if (has(sender, administrator)) message = "player: /np !with !pin !unpin !roll !online !stats !request !mapstate | mod: !user !silence !unsilence !kick !addnote !notes | bn: !requests !nominate !mapstatus !veto !qualify !rank !approve !love | admin: !rollback !restrict !unrestrict !announce !alert !lock !unlock";
        if (has(sender, developer)) message = "player: /np !with !pin !unpin !roll !online !stats !request !mapstate | mod: !user !silence !unsilence !kick !addnote !notes | bn: !requests !nominate !mapstatus !veto !qualify !rank !approve !love | admin: !rollback !restrict !unrestrict !announce !alert !lock !unlock | dev: !addpriv !rmpriv";
        try reply(allocator, sessions, sender, reply_target, out, message);
        return .handled;
    }
    if (std.ascii.eqlIgnoreCase(cmd, "with")) {
        handleWith(allocator, store, sender, args) catch {};
        return .handled;
    }
    if (std.ascii.eqlIgnoreCase(cmd, "pin") or std.ascii.eqlIgnoreCase(cmd, "unpin"))
        return try pinCommand(allocator, store, sessions, sender, reply_target, out, std.ascii.eqlIgnoreCase(cmd, "pin"));
    if (std.ascii.eqlIgnoreCase(cmd, "request")) return try requestRankCommand(allocator, store, sessions, sender, args, reply_target, out);
    if (std.ascii.eqlIgnoreCase(cmd, "mapstate")) return try mapStateCommand(allocator, store, sessions, sender, args, reply_target, out);
    if (std.ascii.eqlIgnoreCase(cmd, "requests")) return try rankQueueCommand(allocator, store, sessions, sender, args, reply_target, out);
    if (std.ascii.eqlIgnoreCase(cmd, "nominate")) return try nominateCommand(allocator, store, sessions, sender, args, reply_target, out);
    if (std.ascii.eqlIgnoreCase(cmd, "mapstatus")) return try mapStatusCommand(allocator, store, sessions, sender, args, reply_target, out);
    if (std.ascii.eqlIgnoreCase(cmd, "pending") or std.ascii.eqlIgnoreCase(cmd, "veto") or std.ascii.eqlIgnoreCase(cmd, "qualify") or std.ascii.eqlIgnoreCase(cmd, "rank") or std.ascii.eqlIgnoreCase(cmd, "approve") or std.ascii.eqlIgnoreCase(cmd, "love") or std.ascii.eqlIgnoreCase(cmd, "rollback"))
        return try rankActionCommand(allocator, store, sessions, sender, cmd, args, reply_target, out);
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
        const message = try std.fmt.bufPrint(&buf, "{s} ({d}) | country {s} | priv {d} | restricted {any} | silence ends {d} | online {any}", .{ target.name, target.id, &target.country, target.privileges, target.restricted, target.silence_end, sessions.onlineByUser(target.id) != null });
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

fn isNominator(sender: *const sessions_mod.Session) bool {
    return sender.user.privileges & (nominator | administrator | developer) != 0;
}

fn currentMap(sender: *const sessions_mod.Session) ?[]const u8 {
    return if (sender.map_md5[0] == 0) null else &sender.map_md5;
}

fn rankStatusName(status: i8) []const u8 {
    return switch (status) {
        1 => "unsubmitted",
        2 => "pending",
        3 => "ranked",
        4 => "approved",
        5 => "qualified",
        6 => "loved",
        else => "unknown",
    };
}

fn replyRankError(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, sender: *sessions_mod.Session, target: []const u8, out: *protocol.Writer, err: anyerror) !CommandResult {
    const message: []const u8 = switch (err) {
        error.BeatmapNotFound => "i don't have that map yet, try again in a sec",
        error.BeatmapNotPending => "only pending maps can enter the ranking queue",
        error.BeatmapAlreadyRequested => "you already requested this set",
        error.BeatmapAlreadyNominated => "you already nominated this set",
        error.NotEnoughNominations => "this set needs two different nominations first",
        error.InvalidBeatmapTransition => "that status change is not valid from the set's current state",
        error.InconsistentBeatmapSet => "the set has mixed statuses; fix it manually before changing it",
        error.NothingToRollback => "there is no status change to roll back",
        else => return err,
    };
    try reply(allocator, sessions, sender, target, out, message);
    return .handled;
}

fn requestRankCommand(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, sender: *sessions_mod.Session, args: []const u8, target: []const u8, out: *protocol.Writer) !CommandResult {
    if (args.len != 0) {
        try reply(allocator, sessions, sender, target, out, "usage: !request after /np");
        return .handled;
    }
    const md5 = currentMap(sender) orelse {
        try reply(allocator, sessions, sender, target, out, "do /np first so i know what map you're on");
        return .handled;
    };
    const context = store.requestBeatmapRank(sender.user.id, md5) catch |err| return try replyRankError(allocator, sessions, sender, target, out, err);
    var buf: [160]u8 = undefined;
    const message = try std.fmt.bufPrint(&buf, "set {d} is in the queue now ({d} request{s})", .{ context.set_id, context.requests, if (context.requests == 1) "" else "s" });
    try reply(allocator, sessions, sender, target, out, message);
    return .handled;
}

fn mapStateCommand(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, sender: *sessions_mod.Session, args: []const u8, target: []const u8, out: *protocol.Writer) !CommandResult {
    if (args.len != 0) {
        try reply(allocator, sessions, sender, target, out, "usage: !mapstate after /np");
        return .handled;
    }
    const md5 = currentMap(sender) orelse {
        try reply(allocator, sessions, sender, target, out, "do /np first so i know what map you're on");
        return .handled;
    };
    const context = (try store.beatmapRankContext(md5)) orelse return try replyRankError(allocator, sessions, sender, target, out, error.BeatmapNotFound);
    var buf: [192]u8 = undefined;
    const message = try std.fmt.bufPrint(&buf, "set {d} | {s} | {d} request(s) | {d}/2 nominations", .{ context.set_id, rankStatusName(context.status), context.requests, context.nominations });
    try reply(allocator, sessions, sender, target, out, message);
    return .handled;
}

fn rankQueueCommand(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, sender: *sessions_mod.Session, args: []const u8, target: []const u8, out: *protocol.Writer) !CommandResult {
    if (!isNominator(sender)) return try denied(allocator, sessions, sender, target, out);
    if (args.len != 0) {
        try reply(allocator, sessions, sender, target, out, "usage: !requests");
        return .handled;
    }
    const queue = try store.beatmapRankQueue(allocator);
    defer allocator.free(queue);
    try reply(allocator, sessions, sender, target, out, if (queue.len == 0) "the ranking queue is empty" else queue);
    return .handled;
}

fn nominateCommand(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, sender: *sessions_mod.Session, args: []const u8, target: []const u8, out: *protocol.Writer) !CommandResult {
    if (!isNominator(sender)) return try denied(allocator, sessions, sender, target, out);
    if (args.len == 0) {
        try reply(allocator, sessions, sender, target, out, "usage: !nominate <reason> after /np");
        return .handled;
    }
    if (args.len > 512) {
        try reply(allocator, sessions, sender, target, out, "keep the review reason under 512 characters");
        return .handled;
    }
    const md5 = currentMap(sender) orelse {
        try reply(allocator, sessions, sender, target, out, "do /np first so i know what map you're on");
        return .handled;
    };
    const context = store.nominateBeatmapSet(sender.user.id, md5, args) catch |err| return try replyRankError(allocator, sessions, sender, target, out, err);
    var buf: [160]u8 = undefined;
    const message = try std.fmt.bufPrint(&buf, "set {d} has {d}/2 nominations", .{ context.set_id, context.nominations });
    try reply(allocator, sessions, sender, target, out, message);
    return .handled;
}

fn rankActionCommand(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, sender: *sessions_mod.Session, command: []const u8, args: []const u8, target: []const u8, out: *protocol.Writer) !CommandResult {
    const rollback = std.ascii.eqlIgnoreCase(command, "rollback");
    if (rollback) {
        if (!has(sender, administrator) and !has(sender, developer)) return try denied(allocator, sessions, sender, target, out);
    } else if (!isNominator(sender)) return try denied(allocator, sessions, sender, target, out);
    if (args.len == 0) {
        try reply(allocator, sessions, sender, target, out, "give a reason after the command");
        return .handled;
    }
    if (args.len > 512) {
        try reply(allocator, sessions, sender, target, out, "keep the review reason under 512 characters");
        return .handled;
    }
    const md5 = currentMap(sender) orelse {
        try reply(allocator, sessions, sender, target, out, "do /np first so i know what map you're on");
        return .handled;
    };
    const action: domain.BeatmapRankAction = if (std.ascii.eqlIgnoreCase(command, "pending")) .pending else if (std.ascii.eqlIgnoreCase(command, "qualify")) .qualify else if (std.ascii.eqlIgnoreCase(command, "rank")) .rank else if (std.ascii.eqlIgnoreCase(command, "approve")) .approve else if (std.ascii.eqlIgnoreCase(command, "love")) .love else if (std.ascii.eqlIgnoreCase(command, "veto")) .veto else .rollback;
    const context = store.applyBeatmapRankAction(sender.user.id, md5, action, args) catch |err| return try replyRankError(allocator, sessions, sender, target, out, err);
    var buf: [192]u8 = undefined;
    const message = try std.fmt.bufPrint(&buf, "set {d} is {s} now ({d} request(s), {d}/2 nominations)", .{ context.set_id, rankStatusName(context.status), context.requests, context.nominations });
    try reply(allocator, sessions, sender, target, out, message);
    return .handled;
}

fn mapStatusCommand(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, sender: *sessions_mod.Session, args: []const u8, target: []const u8, out: *protocol.Writer) !CommandResult {
    if (!isNominator(sender)) return try denied(allocator, sessions, sender, target, out);
    const separator = std.mem.indexOfScalar(u8, args, ' ') orelse {
        try reply(allocator, sessions, sender, target, out, "usage: !mapstatus <pending|ranked|approved|qualified|loved> <reason> after /np");
        return .handled;
    };
    const wanted = args[0..separator];
    const reason = std.mem.trim(u8, args[separator + 1 ..], " \t");
    if (reason.len == 0 or reason.len > 512) {
        try reply(allocator, sessions, sender, target, out, "give a reason under 512 characters");
        return .handled;
    }
    const action: domain.BeatmapRankAction = if (std.ascii.eqlIgnoreCase(wanted, "pending")) .pending else if (std.ascii.eqlIgnoreCase(wanted, "ranked")) .rank else if (std.ascii.eqlIgnoreCase(wanted, "approved")) .approve else if (std.ascii.eqlIgnoreCase(wanted, "qualified")) .qualify else if (std.ascii.eqlIgnoreCase(wanted, "loved")) .love else {
        try reply(allocator, sessions, sender, target, out, "status must be pending, ranked, approved, qualified, or loved");
        return .handled;
    };
    const md5 = currentMap(sender) orelse {
        try reply(allocator, sessions, sender, target, out, "do /np first so i know what map you're on");
        return .handled;
    };
    const context = store.applyBeatmapRankAction(sender.user.id, md5, action, reason) catch |err| return try replyRankError(allocator, sessions, sender, target, out, err);
    var buf: [192]u8 = undefined;
    const message = try std.fmt.bufPrint(&buf, "set {d} is {s} now ({d} request(s), {d}/2 nominations)", .{ context.set_id, rankStatusName(context.status), context.requests, context.nominations });
    try reply(allocator, sessions, sender, target, out, message);
    return .handled;
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

fn privilegeRole(args: []const u8) ?account_roles.Role {
    const value = std.mem.trim(u8, args, " \t");
    if (std.ascii.eqlIgnoreCase(value, "supporter")) return .supporter;
    if (std.ascii.eqlIgnoreCase(value, "premium")) return .premium;
    if (std.ascii.eqlIgnoreCase(value, "alumni")) return .alumni;
    if (std.ascii.eqlIgnoreCase(value, "tournament")) return .tournament;
    if (std.ascii.eqlIgnoreCase(value, "nominator") or std.ascii.eqlIgnoreCase(value, "bn")) return .nominator;
    if (std.ascii.eqlIgnoreCase(value, "mod") or std.ascii.eqlIgnoreCase(value, "gmt")) return .moderator;
    if (std.ascii.eqlIgnoreCase(value, "admin")) return .administrator;
    if (std.ascii.eqlIgnoreCase(value, "developer") or std.ascii.eqlIgnoreCase(value, "dev")) return .developer;
    return null;
}

fn privilegeCommand(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, sender: *sessions_mod.Session, args: []const u8, reply_target: []const u8, out: *protocol.Writer, add: bool) !CommandResult {
    const parsed = splitTargetReason(args) orelse {
        try reply(allocator, sessions, sender, reply_target, out, if (add) "usage: !addpriv <name> <one role>" else "usage: !rmpriv <name> <one role>");
        return .handled;
    };
    const role = privilegeRole(parsed.rest) orelse {
        try reply(allocator, sessions, sender, reply_target, out, "use one named role; base account access cannot be changed here");
        return .handled;
    };
    var target = (try store.userByName(allocator, parsed.name)) orelse {
        try reply(allocator, sessions, sender, reply_target, out, "player not found");
        return .handled;
    };
    defer freeUser(allocator, &target);
    if (!canManage(sender, target)) return try protected(allocator, sessions, sender, reply_target, out);
    const result = store.changeRole(sender.user.id, target.id, role, add, "in-game developer role command") catch |err| switch (err) {
        error.RoleStateUnchanged => {
            try reply(allocator, sessions, sender, reply_target, out, "player already has that role state");
            return .handled;
        },
        else => return err,
    };
    const privileges = result.privileges;
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
    const accuracies = [_]f64{ 90, 95, 98, 99, 100 };
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var mod_buf: [64]u8 = undefined;
    try writer.print("{s} — {s} [{s}] | {s}", .{ meta.artist, meta.title, meta.version, stable_mods.shortString(&mod_buf, sender.mods) });
    for (accuracies) |accuracy| {
        const total_hits = meta.object_count;
        const n300_f: f64 = @max(0, @as(f64, @floatFromInt(total_hits)) * (3.0 * (accuracy / 100.0) - 1.0) / 2.0);
        const n300: u32 = @intFromFloat(@min(@as(f64, @floatFromInt(total_hits)), std.math.round(n300_f)));
        const result = pp.calculate(map_file, .{
            .mode = sender.mode,
            .lazer = 0,
            .mods = @intCast(sender.mods),
            .max_combo = std.math.maxInt(u32),
            .n_geki = if (sender.mode == 3) total_hits else 0,
            .n_katu = 0,
            .n300 = n300,
            .n100 = total_hits -| n300,
            .n50 = 0,
            .misses = 0,
            .legacy_total_score = 1_000_000,
        }) catch {
            try sendPm(allocator, sender, "pp calc failed on this map");
            return;
        };
        try writer.print(" | {d:.0}%: {d:.2}pp", .{ accuracy, result.pp });
    }
    try sendPm(allocator, sender, buf[0..writer.end]);
}

pub const NowPlaying = struct { beatmap_id: i32, mode: ?u8 = null, mods: ?i32 = null };

pub fn parseNowPlaying(text: []const u8) ?NowPlaying {
    const prefix = "\x01ACTION is ";
    if (!std.mem.startsWith(u8, text, prefix) or text.len < prefix.len + 16 or text[text.len - 1] != 1) return null;
    const action = text[prefix.len..];
    const verbs = [_][]const u8{ "playing ", "editing ", "watching ", "listening to " };
    var rest: ?[]const u8 = null;
    for (verbs) |verb| if (std.mem.startsWith(u8, action, verb)) {
        rest = action[verb.len..];
        break;
    };
    const body = rest orelse return null;
    if (body.len == 0 or body[0] != '[') return null;
    const url_end = std.mem.indexOfScalar(u8, body, ' ') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, body, ']') orelse return null;
    if (close <= url_end) return null;
    var url = body[1..url_end];
    if (!(std.mem.startsWith(u8, url, "https://osu.ppy.sh/") or std.mem.startsWith(u8, url, "https://osu.kai.ovh/") or std.mem.startsWith(u8, url, "https://kai.ovh/"))) return null;
    if (!(std.mem.indexOf(u8, url, "/beatmapsets/") != null or std.mem.indexOf(u8, url, "/beatmaps/") != null or std.mem.indexOf(u8, url, "/b/") != null)) return null;
    if (std.mem.indexOfScalar(u8, url, '?')) |query| url = url[0..query];
    url = std.mem.trimEnd(u8, url, "/");
    var digit_start = url.len;
    while (digit_start > 0 and std.ascii.isDigit(url[digit_start - 1])) digit_start -= 1;
    if (digit_start == url.len) return null;
    const beatmap_id = std.fmt.parseInt(i32, url[digit_start..], 10) catch return null;
    if (beatmap_id <= 0) return null;

    var result: NowPlaying = .{ .beatmap_id = beatmap_id };
    if (std.mem.indexOf(u8, url, "#taiko/")) |_| result.mode = 1 else if (std.mem.indexOf(u8, url, "#fruits/")) |_| result.mode = 2 else if (std.mem.indexOf(u8, url, "#mania/")) |_| result.mode = 3 else if (std.mem.indexOf(u8, url, "#osu/")) |_| result.mode = 0;
    const tail = body[close + 1 .. body.len - 1];
    if (std.mem.indexOf(u8, tail, "<Taiko>")) |_| result.mode = 1 else if (std.mem.indexOf(u8, tail, "<CatchTheBeat>")) |_| result.mode = 2 else if (std.mem.indexOf(u8, tail, "<osu!mania>")) |_| result.mode = 3;
    result.mods = stable_mods.parseNowPlayingTail(tail);
    return result;
}

pub fn handleNowPlaying(allocator: std.mem.Allocator, store: *storage.Store, sender: *sessions_mod.Session, text: []const u8) !bool {
    const now_playing = parseNowPlaying(text) orelse return false;
    sender.map_id = now_playing.beatmap_id;
    @memset(&sender.map_md5, 0);
    const selection = (try store.beatmapSelectionById(now_playing.beatmap_id)) orelse {
        try sendPm(allocator, sender, "i don't have that map yet, open its leaderboard and /np it again in a sec");
        return true;
    };
    sender.map_md5 = selection.md5;
    sender.mode = now_playing.mode orelse sender.mode;
    sender.mods = now_playing.mods orelse 0;
    try handleNp(allocator, store, sender);
    return true;
}

fn namespaceForMods(mods: i32) []const u8 {
    return stable_mods.namespace(mods);
}

fn pinCommand(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, sender: *sessions_mod.Session, reply_target: []const u8, out: *protocol.Writer, pinned: bool) !CommandResult {
    if (sender.map_md5[0] == 0) {
        try reply(allocator, sessions, sender, reply_target, out, "do /np first so i know which play you mean");
        return .handled;
    }
    const score_id = store.setScorePinned(sender.user.id, &sender.map_md5, sender.mode, stable_mods.canonical(sender.mods), namespaceForMods(sender.mods), pinned) catch |err| {
        const message: []const u8 = switch (err) {
            error.NoPassedScore => "you don't have a passed play on that map in this mode",
            error.TooManyPinnedScores => "you already have three pinned plays; unpin one first",
            else => "i couldn't update that pin",
        };
        try reply(allocator, sessions, sender, reply_target, out, message);
        return .handled;
    };
    var buf: [96]u8 = undefined;
    const message = try std.fmt.bufPrint(&buf, "score #{d} {s}", .{ score_id, if (pinned) "pinned" else "unpinned" });
    try reply(allocator, sessions, sender, reply_target, out, message);
    return .handled;
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
            const parsed = stable_mods.parseCompact(lower) orelse continue;
            mods = parsed;
        }
    }

    mods = stable_mods.canonical(mods);
    sender.mods = mods;
    var mod_buf: [64]u8 = undefined;
    const mods_str = stable_mods.shortString(&mod_buf, mods);
    const total_objects = meta.object_count;
    const total_hits = if (misses > total_objects) total_objects else total_objects - misses;
    const acc = accuracy / 100.0;
    const n300_f: f64 = @max(0, @as(f64, @floatFromInt(total_hits)) * (3.0 * acc - 1.0) / 2.0);
    const n300: u32 = @intFromFloat(@min(@as(f64, @floatFromInt(total_hits)), std.math.round(n300_f)));
    const n100: u32 = total_hits -| n300;
    const full_combo = try pp.calculate(map_file, .{
        .mode = sender.mode,
        .lazer = 0,
        .mods = @intCast(mods),
        .max_combo = std.math.maxInt(u32),
        .n_geki = if (sender.mode == 3) total_hits else 0,
        .n_katu = 0,
        .n300 = if (sender.mode == 3) 0 else total_hits,
        .n100 = 0,
        .n50 = 0,
        .misses = 0,
        .legacy_total_score = 1_000_000,
    });
    const max_combo_f: f64 = @as(f64, @floatFromInt(full_combo.max_combo)) * combo_pct / 100.0;
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

fn sendPm(allocator: std.mem.Allocator, sender: *sessions_mod.Session, text: []const u8) !void {
    var msg = protocol.Writer.init(allocator);
    defer msg.deinit();
    try protocol.writeMessage(&msg, "kai", text, sender.user.name, 3);
    try sender.enqueue(allocator, msg.bytes());
}
