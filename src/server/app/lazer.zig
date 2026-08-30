const d = @import("../deps.zig");
const std = d.std;
const builtin = d.builtin;
const domain = d.domain;
const storage = d.storage;
const sqlite_storage = d.sqlite_storage;
const sessions_mod = d.sessions_mod;
const bancho = d.bancho;
const lazer = d.lazer;
const lazer_bot = d.lazer_bot;
const lazer_multiplayer = d.lazer_multiplayer;
const lazer_notifications = d.lazer_notifications;
const lazer_spectator = d.lazer_spectator;
const multipart = d.multipart;
const score_crypto = d.score_crypto;
const stable_score = d.stable_score;
const stable_mods = d.stable_mods;
const stable_response = d.stable_response;
const server_control = d.server_control;
const server_control_route = d.server_control_route;
const account_roles = d.account_roles;
const achievements = d.achievements;
const changelog = d.changelog;
const lazer_wiki = d.lazer_wiki;
const rate_limit = d.rate_limit;
const pp = d.pp;
const pp_admin = d.pp_admin;
const screenshot = d.screenshot;
const index_page = d.index_page;
const form_urlencoded = d.form_urlencoded;
const registration = d.registration;
const routing = d.routing;
const beatmap_sync = d.beatmap_sync;
const beatmap_media = d.beatmap_media;
const bss = d.bss;
const irc = d.irc;
const media_contract = d.media_contract;
const webhook = d.webhook;
const protocol = d.protocol;
const country = d.country;
const log = d.log;
const config_mod = d.config_mod;
const web_auth = d.web_auth;
const proxy = d.proxy;
const user_json = d.user_json;
const upstream_user = d.upstream_user;
const profile_avatar = d.profile_avatar;
const profile_banner = d.profile_banner;
const team_image = d.team_image;
const avatar_cache = d.avatar_cache;
const r2 = d.r2;
const object_keys = d.object_keys;
const anticheat_abi = d.anticheat_abi;
const anticheat_evidence = d.anticheat_evidence;
const anticheat_plugin = d.anticheat_plugin;
const anticheat_replay = d.anticheat_replay;
const player_routes = d.player_routes;
const http_boundary = d.http_boundary;
const stable_score_auth = d.stable_score_auth;
const stable_login = d.stable_login;
const default_avatar_1 = d.default_avatar_1;
const default_avatar_2 = d.default_avatar_2;
const lazer_access_lifetime_seconds = d.lazer_access_lifetime_seconds;
const lazer_refresh_lifetime_seconds = d.lazer_refresh_lifetime_seconds;

const support = @import("../support.zig");
const primitives = @import("../http/primitives.zig");
const respond = primitives.respond;
const header = primitives.header;
const freeUser = support.freeUser;
const rollbackFailedLazerLogin = support.rollbackFailedLazerLogin;
const randomMessageUuid = support.randomMessageUuid;
const parseWebsiteRoomPath = support.parseWebsiteRoomPath;
const parseTeamPath = support.parseTeamPath;
const parsePinPath = support.parsePinPath;
const ppNamespace = support.ppNamespace;
const lazerPpNamespace = support.lazerPpNamespace;
const staffPpComparisonJson = support.staffPpComparisonJson;
const lazerPerformance = support.lazerPerformance;
const intLines = support.intLines;
const validWebText = support.validWebText;
const validWebLine = support.validWebLine;
const validProfileWebsite = support.validProfileWebsite;
const stableClientPrivileges = support.stableClientPrivileges;
const scoreLog = support.scoreLog;
const announceScore = support.announceScore;
const announceLazerScore = support.announceLazerScore;

pub fn stableActionName(action: u8) []const u8 {
    return switch (action) {
        1 => "away",
        2 => "playing",
        3 => "editing a beatmap",
        4 => "modding a beatmap",
        5 => "in multiplayer",
        6 => "watching a replay",
        8 => "testing a beatmap",
        9 => "submitting a beatmap",
        10 => "paused",
        11 => "in the multiplayer lobby",
        12 => "in multiplayer",
        else => "idle",
    };
}

pub fn profilePresenceJson(self: anytype, user_id: i32, viewer_id: ?i32) ![]u8 {
    if (user_id == 3) {
        var bot_output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer bot_output.deinit();
        try lazer.writeSystemBotPresence(&bot_output.writer);
        return bot_output.toOwnedSlice();
    }
    const stable_presence = self.sessions.publicPresence(user_id);
    const cutoff = std.Io.Clock.real.now(self.store.io).toSeconds() - 120;
    const lazer_online = try self.store.lazerUserOnline(user_id, cutoff);
    const selected_client = domain.profilePresenceClient(stable_presence != null, lazer_online);
    const show_recent_scores = if (try self.store.lazerProfileSummary(user_id)) |summary| summary.show_recent_scores else false;
    const expose_detail = domain.profilePresenceDetailsVisible(viewer_id, user_id, show_recent_scores);
    var output: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer output.deinit();
    if (selected_client == .lazer) {
        var stored_activity = try self.store.lazerActivity(self.allocator, user_id, cutoff);
        defer if (stored_activity) |*activity| activity.deinit();
        const spectator_activity = self.lazer_spectator.activity(user_id);
        const multiplayer_activity = self.lazer_multiplayer.activity(user_id);
        const activity: []const u8 = if (spectator_activity) |current| switch (current) {
            .playing => "playing",
            .spectating => "spectating",
        } else if (multiplayer_activity) |current| switch (current) {
            .lobby => "in the multiplayer lobby",
            .queue => "in matchmaking",
            .multiplayer => "in multiplayer",
            .playing => "playing multiplayer",
        } else if (stored_activity) |stored| stored.status else "in lazer";
        try output.writer.writeAll("{\"online\":true,\"client\":\"lazer\",\"client_label\":\"lazer\",\"activity\":");
        try std.json.Stringify.value(activity, .{}, &output.writer);
        try output.writer.writeAll(",\"detail\":");
        try std.json.Stringify.value(if (expose_detail and stored_activity != null) stored_activity.?.detail else "", .{}, &output.writer);
        try output.writer.writeAll(",\"mode\":");
        if (expose_detail and stored_activity != null and stored_activity.?.ruleset_id != null) try output.writer.print("{d}", .{stored_activity.?.ruleset_id.?}) else try output.writer.writeAll("null");
        try output.writer.writeAll(",\"mods\":null,\"beatmap_id\":");
        if (expose_detail and stored_activity != null and stored_activity.?.beatmap_id != null) try output.writer.print("{d}", .{stored_activity.?.beatmap_id.?}) else try output.writer.writeAll("null");
        try output.writer.writeByte('}');
    } else if (selected_client == .stable) {
        const presence = stable_presence.?;
        try output.writer.writeAll("{\"online\":true,\"client\":\"stable\",\"client_label\":\"Stable\",\"activity\":");
        try std.json.Stringify.value(stableActionName(presence.action), .{}, &output.writer);
        try output.writer.writeAll(",\"detail\":");
        try std.json.Stringify.value(if (expose_detail) presence.info() else "", .{}, &output.writer);
        if (expose_detail) {
            try output.writer.print(",\"mode\":{d},\"mods\":{d},\"beatmap_id\":{d}}}", .{ presence.mode, presence.mods, presence.map_id });
        } else try output.writer.writeAll(",\"mode\":null,\"mods\":null,\"beatmap_id\":null}");
    } else {
        try output.writer.writeAll("{\"online\":false,\"client\":null,\"client_label\":\"offline\",\"activity\":\"offline\",\"detail\":\"\",\"mode\":null,\"mods\":null,\"beatmap_id\":null}");
    }
    return output.toOwnedSlice();
}

pub fn attachProfilePresence(self: anytype, profile: []const u8, user_id: i32, viewer_id: ?i32) ![]u8 {
    if (profile.len == 0 or profile[profile.len - 1] != '}') return error.InvalidProfileJson;
    const presence = try self.profilePresenceJson(user_id, viewer_id);
    defer self.allocator.free(presence);
    var output: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer output.deinit();
    try output.writer.writeAll(profile[0 .. profile.len - 1]);
    try output.writer.writeAll(",\"presence\":");
    try output.writer.writeAll(presence);
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

pub fn afterLazerScore(self: anytype, user: domain.User, score_id: i64, score: lazer.ScoreInput, pp_value: f64, mods_json: []const u8) ?domain.ScorePlacement {
    self.lazer_spectator.scoreProcessed(user.id, score_id);
    const placement = self.store.lazerScoreLeaderboardPlacement(score_id) catch |err| {
        std.log.warn("event=lazer_score_placement_failed score_id={d} error={t}", .{ score_id, err });
        return null;
    };
    std.log.info("event=lazer_score_submitted score_id={d} user_id={d} beatmap_id={d} namespace={s} passed={s} pp={d:.2} position={d}", .{ score_id, user.id, score.beatmap_id, @tagName(score.namespace), if (score.passed) "true" else "false", pp_value, if (placement) |current| current.rank + 1 else @as(i32, 0) });
    if (!score.passed or !webhook.shouldAnnounceScore(placement, pp_value)) return placement;
    const current = placement.?;
    const info_value = self.store.beatmapInfoById(self.allocator, @intCast(score.beatmap_id)) catch |err| {
        std.log.warn("event=lazer_score_announcement_map_failed score_id={d} error={t}", .{ score_id, err });
        return placement;
    };
    const info = info_value orelse return placement;
    defer self.allocator.free(info.artist);
    defer self.allocator.free(info.title);
    defer self.allocator.free(info.version);
    defer self.allocator.free(info.creator);
    const mods = lazer.modsDisplay(self.allocator, mods_json) catch |err| {
        std.log.warn("event=lazer_score_announcement_mods_failed score_id={d} error={t}", .{ score_id, err });
        return placement;
    };
    defer self.allocator.free(mods);
    announceLazerScore(self.allocator, &self.store, &self.sessions, user.name, score, mods, pp_value, current, info) catch |err|
        std.log.warn("event=lazer_score_ingame_announcement_failed score_id={d} error={t}", .{ score_id, err });
    self.score_webhook.postScore(.{
        .username = user.name,
        .user_id = user.id,
        .grade = score.rank orelse "F",
        .mods = 0,
        .mods_text = mods,
        .mode = @intCast(score.ruleset_id),
        .rank = current.rank + 1,
        .total_score = score.total_score,
        .max_combo = @intCast(score.max_combo),
        .beatmap_max_combo = info.max_combo,
        .accuracy = score.accuracy,
        .pp = pp_value,
        .stars = score.achievement_stars,
        .perfect = info.max_combo > 0 and score.max_combo >= info.max_combo,
        .artist = info.artist,
        .title = info.title,
        .version = info.version,
        .set_id = info.set_id,
    });
    return placement;
}

pub fn lazerScoreResponse(self: anytype, user_id: i32, score_id: i64, placement: ?domain.ScorePlacement) ![]u8 {
    const unlocks = try self.store.newAchievementsForScore("lazer", score_id);
    var output: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"id\":{d},\"position\":", .{score_id});
    if (placement) |current| try output.writer.print("{d}", .{current.rank + 1}) else try output.writer.writeAll("null");
    try output.writer.writeAll(",\"achievement_unlocks\":");
    try achievements.writeLazerUnlocks(&output.writer, unlocks, user_id);
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

pub fn lazerRoomScoreDetailJson(self: anytype, requester_id: i32, room_id: i64, playlist_item_id: i64, beatmap_id: i32, score_id: i64) !?[]u8 {
    const ranking = (try self.lazer_multiplayer.roomScoreRanking(self.allocator, requester_id, room_id, playlist_item_id, score_id)) orelse return null;
    const score_json = (try self.store.lazerScoreJson(self.allocator, score_id, beatmap_id)) orelse return null;
    defer self.allocator.free(score_json);

    const around_limit = lazer_multiplayer.room_score_around_limit;
    var higher_owned: [around_limit]?[]u8 = [_]?[]u8{null} ** around_limit;
    var lower_owned: [around_limit]?[]u8 = [_]?[]u8{null} ** around_limit;
    defer {
        for (higher_owned) |entry| if (entry) |json| self.allocator.free(json);
        for (lower_owned) |entry| if (entry) |json| self.allocator.free(json);
    }
    var higher: [around_limit][]const u8 = undefined;
    var lower: [around_limit][]const u8 = undefined;
    var higher_count: usize = 0;
    var lower_count: usize = 0;
    for (ranking.higher_ids[0..ranking.higher_count]) |around_id| {
        if (try self.store.lazerScoreJson(self.allocator, around_id, beatmap_id)) |json| {
            higher_owned[higher_count] = json;
            higher[higher_count] = json;
            higher_count += 1;
        }
    }
    for (ranking.lower_ids[0..ranking.lower_count]) |around_id| {
        if (try self.store.lazerScoreJson(self.allocator, around_id, beatmap_id)) |json| {
            lower_owned[lower_count] = json;
            lower[lower_count] = json;
            lower_count += 1;
        }
    }

    var output: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer output.deinit();
    try lazer_multiplayer.writeRoomScoreDetailJson(&output.writer, score_json, ranking.position, higher[0..higher_count], lower[0..lower_count]);
    return @as(?[]u8, try output.toOwnedSlice());
}

pub fn broadcastLazerChatToStable(self: anytype, user: domain.User, target: []const u8, message: []const u8) !void {
    if (lazer.channelId(target) == null) return;
    var packet = protocol.Writer.init(self.allocator);
    defer packet.deinit();
    try protocol.writeMessage(&packet, user.name, message, target, user.id);
    self.sessions.mutex.lockUncancelable(self.sessions.io);
    defer self.sessions.mutex.unlock(self.sessions.io);
    try self.sessions.broadcastChannel(target, packet.bytes(), null);
}

pub fn deliverDirectMessageToStable(self: anytype, sender: domain.User, target_id: i32, direct_message_id: i64, message: []const u8) !void {
    self.sessions.mutex.lockUncancelable(self.sessions.io);
    defer self.sessions.mutex.unlock(self.sessions.io);
    if (self.sessions.onlineByUser(target_id)) |target| {
        if (!target.is_bot) {
            var packet = protocol.Writer.init(self.allocator);
            defer packet.deinit();
            try protocol.writeMessage(&packet, sender.name, message, target.user.name, sender.id);
            try target.enqueueDirectMessage(self.allocator, direct_message_id, packet.bytes());
        }
    }
}

pub fn lazerUser(self: anytype, authorization: ?[]const u8, scope: []const u8) !?domain.User {
    const value = authorization orelse return null;
    if (!std.mem.startsWith(u8, value, "Bearer ")) return null;
    const presence_epoch = bancho.captureLazerPresenceEpoch(&self.sessions);
    var user = (try self.store.authenticateToken(self.allocator, value["Bearer ".len..], scope)) orelse return null;
    user.online = true;
    try bancho.publishLazerPresenceAtEpoch(self.allocator, &self.store, &self.sessions, user, presence_epoch);
    return user;
}

pub fn websiteViewerId(self: anytype, cookie_header: ?[]const u8) ?i32 {
    const token = web_auth.playerSessionToken(cookie_header) orelse return null;
    const user = (self.store.authenticateToken(self.allocator, token, web_auth.player_scope) catch |err| {
        std.log.warn("event=replay_viewer_auth_failed error={t}", .{err});
        return null;
    }) orelse return null;
    defer freeUser(self.allocator, user);
    return user.id;
}

pub fn recordReplayViewBestEffort(self: anytype, viewer_id: i32, source: storage.ReplaySource, score_id: i64) void {
    _ = self.store.recordReplayView(viewer_id, source, score_id) catch |err| {
        std.log.warn("event=replay_view_record_failed viewer_id={d} source={s} score_id={d} error={t}", .{ viewer_id, source.text(), score_id, err });
    };
}

pub fn lazerStats(self: anytype, user_id: i32) ![4]?domain.Stats {
    var stats: [4]?domain.Stats = .{ null, null, null, null };
    for (0..stats.len) |mode| stats[mode] = try self.store.statsForUser(user_id, @intCast(mode));
    return stats;
}

pub fn lazerPresenceJson(self: anytype, requester_id: i32) ![]u8 {
    const cutoff = std.Io.Clock.real.now(self.store.io).toSeconds() - 120;
    const oauth_ids = try self.store.recentOauthUserIds(self.allocator, cutoff);
    defer self.allocator.free(oauth_ids);
    const stable_ids = try self.sessions.onlineUserIds(self.allocator);
    defer self.allocator.free(stable_ids);

    var ids: std.ArrayList(i32) = .empty;
    defer ids.deinit(self.allocator);
    try ids.ensureTotalCapacity(self.allocator, oauth_ids.len + stable_ids.len + 2);
    for ([_]i32{ 3, requester_id }) |id| if (std.mem.indexOfScalar(i32, ids.items, id) == null) try ids.append(self.allocator, id);
    for (oauth_ids) |id| if (std.mem.indexOfScalar(i32, ids.items, id) == null) try ids.append(self.allocator, id);
    for (stable_ids) |id| if (std.mem.indexOfScalar(i32, ids.items, id) == null) try ids.append(self.allocator, id);

    var output: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    for (ids.items, 0..) |id, index| {
        if (index != 0) try output.writer.writeByte(',');
        const presence = try self.profilePresenceJson(id, requester_id);
        defer self.allocator.free(presence);
        if (presence.len < 2 or presence[0] != '{' or presence[presence.len - 1] != '}') return error.InvalidProfilePresence;
        try output.writer.print("{{\"user_id\":{d},", .{id});
        try output.writer.writeAll(presence[1..]);
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn recordLazerBotReply(self: anytype, user: domain.User, content: []const u8, is_action: bool) void {
    const reply_text = self.lazer_bot.replyOwned(&self.store, &self.sessions, user, content, is_action) catch |err| {
        std.log.warn("event=lazer_bot_command_failed user_id={d} error={t}", .{ user.id, err });
        return;
    };
    defer self.allocator.free(reply_text);
    const reply_uuid = randomMessageUuid(self.sessions.io) catch |err| {
        std.log.warn("event=lazer_bot_uuid_failed user_id={d} error={t}", .{ user.id, err });
        return;
    };
    const reply = self.store.recordLazerDirectMessage(self.allocator, 3, user.id, reply_text, false, &reply_uuid) catch |err| {
        std.log.warn("event=lazer_bot_reply_failed user_id={d} error={t}", .{ user.id, err });
        return;
    };
    self.allocator.free(reply.json);
    if (reply.inserted) {
        const kai = self.store.userById(self.allocator, 3) catch null;
        if (kai) |bot| {
            defer freeUser(self.allocator, bot);
            if (reply.direct_message_id) |message_id| self.deliverDirectMessageToStable(bot, user.id, message_id, reply_text) catch |err|
                std.log.warn("event=bot_dm_stable_delivery_failed user_id={d} error={t}", .{ user.id, err });
        }
    }
}

pub fn friendRelationsJson(self: anytype, user_id: i32) ![]u8 {
    const ids = try self.store.friendIds(self.allocator, user_id);
    defer self.allocator.free(ids);
    var output: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var written: usize = 0;
    for (ids) |id| {
        var target_user = (try self.store.userById(self.allocator, id)) orelse continue;
        defer freeUser(self.allocator, target_user);
        try self.markOnline(&target_user);
        if (written != 0) try output.writer.writeByte(',');
        written += 1;
        try output.writer.print("{{\"target_id\":{d},\"relation_type\":\"friend\",\"mutual\":{s},\"target\":", .{ id, if (try self.store.friendsAreMutual(user_id, id)) "true" else "false" });
        try user_json.writeCompact(&output.writer, target_user, target_user.show_country);
        try output.writer.writeByte('}');
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn blockRelationsJson(self: anytype, user_id: i32) ![]u8 {
    const ids = try self.store.blockIds(self.allocator, user_id);
    defer self.allocator.free(ids);
    var output: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var written: usize = 0;
    for (ids) |id| {
        var target_user = (try self.store.userById(self.allocator, id)) orelse continue;
        defer freeUser(self.allocator, target_user);
        try self.markOnline(&target_user);
        if (written != 0) try output.writer.writeByte(',');
        written += 1;
        try output.writer.print("{{\"target_id\":{d},\"relation_type\":\"block\",\"mutual\":false,\"target\":", .{id});
        try user_json.writeCompact(&output.writer, target_user, target_user.show_country);
        try output.writer.writeByte('}');
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn friendMutationJson(self: anytype, user_id: i32, target_value: domain.User) ![]u8 {
    var target = target_value;
    try self.markOnline(&target);
    var output: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"user_relation\":{{\"target_id\":{d},\"relation_type\":\"friend\",\"mutual\":{s},\"target\":", .{ target.id, if (try self.store.friendsAreMutual(user_id, target.id)) "true" else "false" });
    try user_json.writeCompact(&output.writer, target, target.show_country);
    try output.writer.writeAll("}}");
    return output.toOwnedSlice();
}

pub fn favouriteSetsJson(self: anytype, user_id: i32) ![]u8 {
    const ids = try self.store.favouriteSetIds(self.allocator, user_id);
    defer self.allocator.free(ids);
    var output: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"beatmapset_ids\":[");
    for (ids, 0..) |id, index| {
        if (index != 0) try output.writer.writeByte(',');
        try output.writer.print("{d}", .{id});
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}
