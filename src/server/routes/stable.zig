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

const Context = @import("../http/context.zig").Context;
const Result = @import("result.zig").Result;
const primitives = @import("../http/primitives.zig");
const support = @import("../support.zig");
const lifecycle = @import("../lifecycle.zig");

const header = primitives.header;
const respond = primitives.respond;
const respondWithoutContinue = primitives.respondWithoutContinue;
const rejectStableScore = primitives.rejectStableScore;
const rejectStableScoreError = primitives.rejectStableScoreError;
const field = primitives.field;
const queryField = primitives.queryField;
const beatmapSearchOffset = primitives.beatmapSearchOffset;
const userPathWithSuffix = primitives.userPathWithSuffix;
const userBeatmapsetPath = primitives.userBeatmapsetPath;
const beatmapTagPath = primitives.beatmapTagPath;
const lazerRulesetId = primitives.lazerRulesetId;
const isAvatarHost = primitives.isAvatarHost;
const isAssetsHost = primitives.isAssetsHost;
const isBeatmapMirrorHost = primitives.isBeatmapMirrorHost;
const isBssHost = primitives.isBssHost;
const bssStorageFailure = primitives.bssStorageFailure;
const isLocalMetricsHost = primitives.isLocalMetricsHost;
const avatarUserId = primitives.avatarUserId;
const GeoResult = primitives.GeoResult;

const freeUser = support.freeUser;
const randomMessageUuid = support.randomMessageUuid;
const parseWebsiteRoomPath = support.parseWebsiteRoomPath;
const parseTeamPath = support.parseTeamPath;
const parsePinPath = support.parsePinPath;
const ppNamespace = support.ppNamespace;
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
const StaffPpPreviewRequest = support.StaffPpPreviewRequest;
const stableGameplayEvidence = @import("../app/anticheat.zig").stableGameplayEvidence;

fn dispatch(self: anytype, req: *std.http.Server.Request, ctx: *const Context) !void {
    const target = ctx.target;
    const raw_path = ctx.raw_path;
    const path = ctx.path;
    const osu_token_owned = ctx.osu_token_owned;
    const score_token_owned = ctx.score_token_owned;
    const content_type_owned = ctx.content_type_owned;
    const country_owned = ctx.country_owned;
    const host_owned = ctx.host_owned;
    const client_ip_owned = ctx.client_ip_owned;
    const body = ctx.body;
    if (std.mem.eql(u8, path, "/") and req.head.method == .POST) {
        if (osu_token_owned) |token| {
            const poll_user_id = bancho.pollUserIdForToken(&self.sessions, token) orelse {
                var restart = protocol.Writer.init(self.allocator);
                defer restart.deinit();
                try restart.packetString(.notification, "Server has restarted.");
                const rs = try restart.begin(.restart);
                try restart.int(i32, 0);
                restart.finish(rs);
                return respond(req, .ok, "application/octet-stream", restart.bytes(), &.{});
            };
            const maybe_bytes = poll: {
                const mutex = self.gameSessionMutex(poll_user_id);
                mutex.lockUncancelable(self.store.io);
                defer mutex.unlock(self.store.io);
                break :poll try bancho.pollByToken(self.allocator, &self.store, &self.sessions, token, body);
            };
            const bytes = maybe_bytes orelse {
                var restart = protocol.Writer.init(self.allocator);
                defer restart.deinit();
                try restart.packetString(.notification, "Server has restarted.");
                const rs = try restart.begin(.restart);
                try restart.int(i32, 0);
                restart.finish(rs);
                return respond(req, .ok, "application/octet-stream", restart.bytes(), &.{});
            };
            defer self.allocator.free(bytes);
            return respond(req, .ok, "application/octet-stream", bytes, &.{});
        }
        const geo = if (client_ip_owned) |ip| self.lookupGeo(ip) else GeoResult{ .lon = 0, .lat = 0 };
        var result = try self.stableLoginAndTakeover(body, if (country_owned) |value| country.normalized(value) else null, geo.lon, geo.lat);
        defer result.deinit();
        self.observeStableLogin(result);
        const token_headers = [_]std.http.Header{
            .{ .name = "cho-token", .value = result.token },
            .{ .name = "osu-token", .value = result.token },
        };
        return respond(req, .ok, "application/octet-stream", result.body, &token_headers);
    }
    if (std.mem.eql(u8, path, "/p/doyoureallywanttoaskpeppy") and req.head.method == .GET) {
        return respond(req, .ok, "text/plain", "This user's ID is usually peppy's (when on bancho), and is blocked from being messaged by the osu! client.", &.{});
    }
    if (std.mem.eql(u8, path, "/difficulty-rating") and req.head.method == .POST) {
        return respond(req, .temporary_redirect, "text/plain", "", &.{.{ .name = "location", .value = "https://osu.ppy.sh/difficulty-rating" }});
    }
    if (std.mem.eql(u8, path, "/web/osu-getbeatmapinfo.php") and req.head.method == .POST) {
        const encoded_name = queryField(target, "u") orelse return respond(req, .bad_request, "text/plain", "", &.{});
        const password = queryField(target, "h") orelse return respond(req, .unauthorized, "text/plain", "", &.{});
        const name_buf = try self.allocator.dupe(u8, encoded_name);
        defer self.allocator.free(name_buf);
        for (name_buf) |*char| if (char.* == '+') {
            char.* = ' ';
        };
        const name = std.Uri.percentDecodeInPlace(name_buf);
        const user = (try self.store.authenticate(self.allocator, name, password)) orelse return respond(req, .unauthorized, "text/plain", "", &.{});
        defer freeUser(self.allocator, user);
        if (!self.userOnline(user.id)) return respond(req, .unauthorized, "text/plain", "", &.{});
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch return respond(req, .bad_request, "text/plain", "", &.{});
        defer parsed.deinit();
        if (parsed.value != .object) return respond(req, .bad_request, "text/plain", "", &.{});
        const filenames_value = parsed.value.object.get("Filenames") orelse return respond(req, .bad_request, "text/plain", "", &.{});
        const ids_value = parsed.value.object.get("Ids") orelse return respond(req, .bad_request, "text/plain", "", &.{});
        if (filenames_value != .array or ids_value != .array or filenames_value.array.items.len + ids_value.array.items.len > 65_536) return respond(req, .bad_request, "text/plain", "", &.{});
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        var response_count: usize = 0;
        for (filenames_value.array.items, 0..) |item, index| {
            if (item != .string or item.string.len == 0 or item.string.len > 512 or std.mem.indexOfScalar(u8, item.string, 0) != null) return respond(req, .bad_request, "text/plain", "", &.{});
            const info = (try self.store.stableBeatmapInfoByFilename(user.id, item.string)) orelse continue;
            if (response_count != 0) try output.writer.writeByte('\n');
            response_count += 1;
            try output.writer.print("{d}|{d}|{d}|{s}|{d}|{s}|{s}|{s}|{s}", .{ index, info.id, info.set_id, &info.md5, info.status, info.grades[0], info.grades[1], info.grades[2], info.grades[3] });
        }
        for (ids_value.array.items, 0..) |item, offset| {
            if (item != .integer or item.integer <= 0 or item.integer > std.math.maxInt(i32)) return respond(req, .bad_request, "text/plain", "", &.{});
            const info = (try self.store.stableBeatmapInfoById(user.id, @intCast(item.integer))) orelse continue;
            if (response_count != 0) try output.writer.writeByte('\n');
            response_count += 1;
            try output.writer.print("{d}|{d}|{d}|{s}|{d}|{s}|{s}|{s}|{s}", .{ filenames_value.array.items.len + offset, info.id, info.set_id, &info.md5, info.status, info.grades[0], info.grades[1], info.grades[2], info.grades[3] });
        }
        return respond(req, .ok, "text/plain", output.written(), &.{});
    }
    if (std.mem.eql(u8, path, "/web/osu-comment.php") and req.head.method == .POST) {
        const encoded_name = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"u"})) orelse return respond(req, .bad_request, "text/plain", "", &.{});
        defer self.allocator.free(encoded_name);
        const password = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"p"})) orelse return respond(req, .unauthorized, "text/plain", "", &.{});
        defer self.allocator.free(password);
        const user = (try self.store.authenticate(self.allocator, encoded_name, password)) orelse return respond(req, .unauthorized, "text/plain", "", &.{});
        defer freeUser(self.allocator, user);
        if (!self.userOnline(user.id)) return respond(req, .unauthorized, "text/plain", "", &.{});
        const map_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"b"})) orelse return respond(req, .bad_request, "text/plain", "", &.{});
        defer self.allocator.free(map_text);
        const set_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"s"})) orelse return respond(req, .bad_request, "text/plain", "", &.{});
        defer self.allocator.free(set_text);
        const score_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"r"})) orelse return respond(req, .bad_request, "text/plain", "", &.{});
        defer self.allocator.free(score_text);
        const mode_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"m"})) orelse return respond(req, .bad_request, "text/plain", "", &.{});
        defer self.allocator.free(mode_text);
        const action = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"a"})) orelse return respond(req, .bad_request, "text/plain", "", &.{});
        defer self.allocator.free(action);
        const map_id = std.fmt.parseInt(i32, map_text, 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
        const set_id = std.fmt.parseInt(i32, set_text, 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
        const score_id = std.fmt.parseInt(i64, score_text, 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
        const mode = std.fmt.parseInt(u8, mode_text, 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
        if (map_id < 0 or set_id < 0 or score_id < 0 or mode > 3) return respond(req, .bad_request, "text/plain", "", &.{});
        if (std.mem.eql(u8, action, "get")) {
            const comments = try self.store.beatmapComments(self.allocator, score_id, set_id, map_id);
            defer self.allocator.free(comments);
            return respond(req, .ok, "text/plain", comments, &.{});
        }
        if (!std.mem.eql(u8, action, "post")) return respond(req, .bad_request, "text/plain", "", &.{});
        const target_type = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"target"})) orelse return respond(req, .bad_request, "text/plain", "", &.{});
        defer self.allocator.free(target_type);
        const time_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"starttime"})) orelse return respond(req, .bad_request, "text/plain", "", &.{});
        defer self.allocator.free(time_text);
        const comment_owned = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"comment"})) orelse return respond(req, .bad_request, "text/plain", "", &.{});
        defer self.allocator.free(comment_owned);
        const colour_owned = try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"f"});
        defer if (colour_owned) |value| self.allocator.free(value);
        if (!std.mem.eql(u8, target_type, "song") and !std.mem.eql(u8, target_type, "map") and !std.mem.eql(u8, target_type, "replay")) return respond(req, .bad_request, "text/plain", "", &.{});
        const start_time = std.fmt.parseFloat(f64, time_text) catch return respond(req, .bad_request, "text/plain", "", &.{});
        const comment = std.mem.trim(u8, comment_owned, " \t\r\n");
        if (!std.math.isFinite(start_time) or start_time < 0 or start_time > 1_000_000_000 or comment.len == 0 or comment.len > 80 or !std.unicode.utf8ValidateSlice(comment) or std.mem.indexOfAny(u8, comment, "\r\n\t") != null) return respond(req, .bad_request, "text/plain", "", &.{});
        var colour: ?[]const u8 = null;
        if (colour_owned) |value| {
            if (value.len != 6) return respond(req, .bad_request, "text/plain", "", &.{});
            for (value) |char| if (!std.ascii.isHex(char)) return respond(req, .bad_request, "text/plain", "", &.{});
            if (user.privileges & (1 << 4) != 0) colour = value;
        }
        const target_id: i64 = if (std.mem.eql(u8, target_type, "song")) set_id else if (std.mem.eql(u8, target_type, "map")) map_id else score_id;
        try self.store.addBeatmapComment(user.id, target_type, target_id, start_time, comment, colour);
        return respond(req, .ok, "text/plain", "", &.{});
    }
    if (std.mem.eql(u8, path, "/web/osu-markasread.php") and req.head.method == .GET) {
        const encoded_name = queryField(target, "u") orelse return respond(req, .bad_request, "text/plain", "", &.{});
        const password = queryField(target, "h") orelse return respond(req, .unauthorized, "text/plain", "", &.{});
        const encoded_channel = queryField(target, "channel") orelse return respond(req, .bad_request, "text/plain", "", &.{});
        const name_buf = try self.allocator.dupe(u8, encoded_name);
        defer self.allocator.free(name_buf);
        for (name_buf) |*char| if (char.* == '+') {
            char.* = ' ';
        };
        const name = std.Uri.percentDecodeInPlace(name_buf);
        const user = (try self.store.authenticate(self.allocator, name, password)) orelse return respond(req, .unauthorized, "text/plain", "", &.{});
        defer freeUser(self.allocator, user);
        if (!self.userOnline(user.id)) return respond(req, .unauthorized, "text/plain", "", &.{});
        const channel_buf = try self.allocator.dupe(u8, encoded_channel);
        defer self.allocator.free(channel_buf);
        for (channel_buf) |*char| if (char.* == '+') {
            char.* = ' ';
        };
        const channel = std.Uri.percentDecodeInPlace(channel_buf);
        if (channel.len > 32 or std.mem.indexOfScalar(u8, channel, 0) != null) return respond(req, .bad_request, "text/plain", "", &.{});
        if (channel.len != 0) if (try self.store.userByName(self.allocator, channel)) |other| {
            defer freeUser(self.allocator, other);
            try self.store.markDirectMessagesRead(user.id, other.id);
        };
        return respond(req, .ok, "text/plain", "", &.{});
    }
    if (req.head.method == .GET and std.mem.startsWith(u8, path, "/web/maps/") and path.len > "/web/maps/".len) {
        const location = try std.fmt.allocPrint(self.allocator, "https://osu.ppy.sh{s}", .{raw_path});
        defer self.allocator.free(location);
        return respond(req, .moved_permanently, "text/plain", "", &.{.{ .name = "location", .value = location }});
    }
    if (req.head.method == .GET and web_auth.protocolHost(host_owned) and (std.mem.startsWith(u8, path, "/beatmaps/") or std.mem.startsWith(u8, path, "/community/forums/topics/") or (std.mem.startsWith(u8, path, "/beatmapsets/") and std.mem.endsWith(u8, path, "/discussion")))) {
        const location = try std.fmt.allocPrint(self.allocator, "https://osu.ppy.sh{s}", .{raw_path});
        defer self.allocator.free(location);
        return respond(req, .moved_permanently, "text/plain", "", &.{.{ .name = "location", .value = location }});
    }
    if (std.mem.eql(u8, path, "/web/bancho_connect.php")) return respond(req, .ok, "text/plain", "", &.{});
    if (std.mem.eql(u8, path, "/web/check-updates.php")) return respond(req, .ok, "text/plain", "", &.{});
    if (std.mem.eql(u8, path, "/web/lastfm.php") and req.head.method == .GET) {
        const action = queryField(target, "action") orelse return respond(req, .bad_request, "text/plain", "", &.{});
        if (!std.mem.eql(u8, action, "np") and !std.mem.eql(u8, action, "scrobble")) return respond(req, .bad_request, "text/plain", "", &.{});
        const encoded_name = queryField(target, "us") orelse return respond(req, .bad_request, "text/plain", "", &.{});
        const password = queryField(target, "ha") orelse return respond(req, .unauthorized, "text/plain", "", &.{});
        const beatmap_or_flag = queryField(target, "b") orelse return respond(req, .bad_request, "text/plain", "", &.{});
        const name_buf = try self.allocator.dupe(u8, encoded_name);
        defer self.allocator.free(name_buf);
        for (name_buf) |*char| if (char.* == '+') {
            char.* = ' ';
        };
        const name = std.Uri.percentDecodeInPlace(name_buf);
        const user = (try self.store.authenticate(self.allocator, name, password)) orelse return respond(req, .unauthorized, "text/plain", "", &.{});
        defer self.allocator.free(user.name);
        defer self.allocator.free(user.safe_name);
        if (!self.userOnline(user.id)) return respond(req, .unauthorized, "text/plain", "", &.{});
        if (beatmap_or_flag.len == 0 or beatmap_or_flag[0] != 'a') return respond(req, .ok, "text/plain", "-3", &.{});
        const flags = std.fmt.parseInt(u32, beatmap_or_flag[1..], 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
        if (flags != 0) {
            try self.store.recordLastFmFlag(user.id, flags);
        }
        self.observeStableLastFmFlags(user.id, flags);
        std.log.info("lastfm: user_id={d} action={s} flags={d} b={s}", .{ user.id, action, flags, beatmap_or_flag });
        return respond(req, .ok, "text/plain", "", &.{});
    }
    if (std.mem.eql(u8, path, "/web/osu-rate.php") and req.head.method == .GET) {
        const encoded_name = queryField(target, "u") orelse return respond(req, .bad_request, "text/plain", "", &.{});
        const password = queryField(target, "p") orelse return respond(req, .unauthorized, "text/plain", "auth fail", &.{});
        const map_md5 = queryField(target, "c") orelse return respond(req, .bad_request, "text/plain", "", &.{});
        if (map_md5.len != 32) return respond(req, .bad_request, "text/plain", "", &.{});
        const rating: ?u8 = if (queryField(target, "v")) |value| std.fmt.parseInt(u8, value, 10) catch return respond(req, .bad_request, "text/plain", "", &.{}) else null;
        if (rating) |value| if (value < 1 or value > 10) return respond(req, .bad_request, "text/plain", "", &.{});
        const name_buf = try self.allocator.dupe(u8, encoded_name);
        defer self.allocator.free(name_buf);
        for (name_buf) |*char| if (char.* == '+') {
            char.* = ' ';
        };
        const name = std.Uri.percentDecodeInPlace(name_buf);
        const user = (try self.store.authenticate(self.allocator, name, password)) orelse return respond(req, .unauthorized, "text/plain", "auth fail", &.{});
        defer self.allocator.free(user.name);
        defer self.allocator.free(user.safe_name);
        if (!self.userOnline(user.id)) return respond(req, .unauthorized, "text/plain", "auth fail", &.{});
        return switch (try self.store.rateBeatmap(user.id, map_md5, rating)) {
            .no_exist => respond(req, .ok, "text/plain", "no exist", &.{}),
            .not_ranked => respond(req, .ok, "text/plain", "not ranked", &.{}),
            .can_rate => respond(req, .ok, "text/plain", "ok", &.{}),
            .already_voted => |average| voted: {
                var rating_buf: [64]u8 = undefined;
                const response = try std.fmt.bufPrint(&rating_buf, "alreadyvoted\n{d}", .{average});
                break :voted respond(req, .ok, "text/plain", response, &.{});
            },
        };
    }
    if (req.head.method == .GET and (std.mem.eql(u8, path, "/web/osu-getfriends.php") or std.mem.eql(u8, path, "/web/osu-getfavourites.php") or std.mem.eql(u8, path, "/web/osu-addfavourite.php"))) {
        const encoded_name = queryField(target, "u") orelse return respond(req, .bad_request, "text/plain", "", &.{});
        const password = queryField(target, "h") orelse return respond(req, .unauthorized, "text/plain", "", &.{});
        const name_buf = try self.allocator.dupe(u8, encoded_name);
        defer self.allocator.free(name_buf);
        for (name_buf) |*char| if (char.* == '+') {
            char.* = ' ';
        };
        const name = std.Uri.percentDecodeInPlace(name_buf);
        const user = (try self.store.authenticate(self.allocator, name, password)) orelse return respond(req, .unauthorized, "text/plain", "", &.{});
        defer freeUser(self.allocator, user);
        if (!self.userOnline(user.id)) return respond(req, .unauthorized, "text/plain", "", &.{});
        if (std.mem.eql(u8, path, "/web/osu-addfavourite.php")) {
            const set_id = std.fmt.parseInt(i32, queryField(target, "a") orelse return respond(req, .bad_request, "text/plain", "", &.{}), 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
            if (set_id <= 0) return respond(req, .bad_request, "text/plain", "", &.{});
            return respond(req, .ok, "text/plain", if (try self.store.addFavourite(user.id, set_id)) "Added favourite!" else "You've already favourited this beatmap!", &.{});
        }
        const ids = if (std.mem.eql(u8, path, "/web/osu-getfriends.php")) try self.store.friendIds(self.allocator, user.id) else try self.store.favouriteSetIds(self.allocator, user.id);
        defer self.allocator.free(ids);
        const response = try intLines(self.allocator, ids);
        defer self.allocator.free(response);
        return respond(req, .ok, "text/plain", response, &.{});
    }
    if ((std.mem.eql(u8, path, "/web/osu-search.php") or std.mem.eql(u8, path, "/web/osu-search-set.php")) and req.head.method == .GET) {
        const encoded_name = queryField(target, "u") orelse return respond(req, .bad_request, "text/plain", "", &.{});
        const password = queryField(target, "h") orelse return respond(req, .unauthorized, "text/plain", "", &.{});
        const name_buf = try self.allocator.dupe(u8, encoded_name);
        defer self.allocator.free(name_buf);
        for (name_buf) |*char| {
            if (char.* == '+') char.* = ' ';
        }
        const name = std.Uri.percentDecodeInPlace(name_buf);
        const user = (try self.store.authenticate(self.allocator, name, password)) orelse return respond(req, .unauthorized, "text/plain", "", &.{});
        defer self.allocator.free(user.name);
        defer self.allocator.free(user.safe_name);
        if (std.mem.eql(u8, path, "/web/osu-search.php")) {
            const direct_status = std.fmt.parseInt(u8, queryField(target, "r") orelse "4", 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
            const mode = std.fmt.parseInt(i8, queryField(target, "m") orelse "-1", 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
            const page = std.fmt.parseInt(u16, queryField(target, "p") orelse "0", 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
            if (direct_status > 8 or mode < -1 or mode > 3 or page > 1000) return respond(req, .bad_request, "text/plain", "", &.{});
            const encoded_query = queryField(target, "q") orelse "";
            const query_buf = try self.allocator.dupe(u8, encoded_query);
            defer self.allocator.free(query_buf);
            for (query_buf) |*char| {
                if (char.* == '+') char.* = ' ';
            }
            const decoded_query = std.Uri.percentDecodeInPlace(query_buf);
            const query = if (std.mem.eql(u8, decoded_query, "Newest") or std.mem.eql(u8, decoded_query, "Top Rated") or std.mem.eql(u8, decoded_query, "Most Played")) "" else decoded_query;
            const listing = try self.store.stableSearch(self.allocator, query, mode, direct_status, page);
            defer self.allocator.free(listing);
            return respond(req, .ok, "text/plain", listing, &.{});
        }
        const set_id: ?i32 = if (queryField(target, "s")) |value| std.fmt.parseInt(i32, value, 10) catch return respond(req, .bad_request, "text/plain", "", &.{}) else null;
        const map_id: ?i32 = if (queryField(target, "b")) |value| std.fmt.parseInt(i32, value, 10) catch return respond(req, .bad_request, "text/plain", "", &.{}) else null;
        const checksum = queryField(target, "c");
        if (set_id == null and map_id == null and checksum == null) return respond(req, .bad_request, "text/plain", "", &.{});
        if (checksum) |value| if (value.len != 32) return respond(req, .bad_request, "text/plain", "", &.{});
        const listing = try self.store.stableSearchSet(self.allocator, set_id, map_id, checksum);
        defer self.allocator.free(listing);
        return respond(req, .ok, "text/plain", listing, &.{});
    }
    if (std.mem.eql(u8, path, "/web/osu-osz2-getscores.php") and req.head.method == .GET) {
        const encoded_name = queryField(target, "us") orelse return respond(req, .bad_request, "text/plain", "", &.{});
        const password = queryField(target, "ha") orelse return respond(req, .unauthorized, "text/plain", "", &.{});
        const map_md5 = queryField(target, "c") orelse return respond(req, .bad_request, "text/plain", "", &.{});
        const set_id_text = queryField(target, "i") orelse "0";
        const mode_text = queryField(target, "m") orelse "0";
        const board_text = queryField(target, "v") orelse "1";
        const mods_text = queryField(target, "mods") orelse "0";
        const mode = std.fmt.parseInt(u8, mode_text, 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
        const board_type = std.fmt.parseInt(u8, board_text, 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
        const mods = std.fmt.parseInt(i32, mods_text, 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
        const set_id = std.fmt.parseInt(i32, set_id_text, 10) catch 0;
        if (mode > 3 or board_type > 4 or map_md5.len != 32) return respond(req, .bad_request, "text/plain", "", &.{});
        const name_buf = try self.allocator.dupe(u8, encoded_name);
        defer self.allocator.free(name_buf);
        for (name_buf) |*char| {
            if (char.* == '+') char.* = ' ';
        }
        const name = std.Uri.percentDecodeInPlace(name_buf);
        const user = (try self.store.authenticate(self.allocator, name, password)) orelse return respond(req, .unauthorized, "text/plain", "", &.{});
        defer self.allocator.free(user.name);
        defer self.allocator.free(user.safe_name);
        if (try beatmap_sync.needsHydration(&self.store, map_md5)) {
            std.debug.print("{s}  ┌─ LEADERBOARD ──────────────────────────────────{s}\n", .{ log.cyan, log.reset });
            std.debug.print("{s}  │ {s}►{s} user : {s}{s}{s}\n", .{ log.cyan, log.dim, log.reset, log.green, user.name, log.reset });
            std.debug.print("{s}  │ {s}►{s} map  : {s}{s}\n", .{ log.cyan, log.dim, log.reset, log.dim, map_md5 });
            std.debug.print("{s}  │ {s}►{s} hydrating...{s}\n", .{ log.cyan, log.dim, log.reset, log.dim });
            _ = self.map_sync.ensure(&self.store, map_md5, if (set_id > 0) set_id else null) catch |err| {
                std.debug.print("{s}  │ {s}✗ hydration failed: {t}{s}\n", .{ log.red, log.reset, err, log.reset });
            };
        }
        const listing = try self.store.stableLeaderboard(self.allocator, user, map_md5, mode, board_type, mods);
        defer self.allocator.free(listing);
        return respond(req, .ok, "text/plain", listing, &.{});
    }
    if (std.mem.eql(u8, path, "/web/osu-submit-modular-selector.php") and req.head.method == .POST) {
        const content_type = content_type_owned orelse return rejectStableScore(req, "missing_content_type", body.len);
        const boundary = multipart.boundaryFromContentType(content_type) catch |err| return rejectStableScoreError(req, "invalid_boundary", err, body.len);
        var form = multipart.parse(self.allocator, body, boundary) catch |err| return rejectStableScoreError(req, "invalid_multipart", err, body.len);
        defer form.deinit();
        const encrypted = form.nth("score", 0) orelse return rejectStableScore(req, "missing_encrypted_score", body.len);
        const replay = form.nth("score", 1) orelse return rejectStableScore(req, "missing_replay", body.len);
        if (encrypted.filename != null) return rejectStableScore(req, "encrypted_score_is_file", body.len);
        if (replay.filename == null) return rejectStableScore(req, "replay_is_not_file", body.len);
        const iv = (form.first("iv") orelse return rejectStableScore(req, "missing_iv", body.len)).data;
        const client_hash_encrypted = (form.first("s") orelse return rejectStableScore(req, "missing_client_hash", body.len)).data;
        const password = (form.first("pass") orelse {
            std.log.warn("stable score rejected: reason=missing_password body_bytes={d}", .{body.len});
            return respond(req, .unauthorized, "text/plain", "", &.{});
        }).data;
        const osu_version = (form.first("osuver") orelse return rejectStableScore(req, "missing_osu_version", body.len)).data;
        const updated_map_hash = (form.first("bmk") orelse return rejectStableScore(req, "missing_updated_map_hash", body.len)).data;
        const storyboard_hash = if (form.first("sbk")) |part| part.data else "";
        const score_time = std.fmt.parseInt(u32, (form.first("st") orelse return rejectStableScore(req, "missing_score_time", body.len)).data, 10) catch return rejectStableScore(req, "invalid_score_time", body.len);
        const fail_time = std.fmt.parseInt(u32, (form.first("ft") orelse return rejectStableScore(req, "missing_fail_time", body.len)).data, 10) catch return rejectStableScore(req, "invalid_fail_time", body.len);
        var decrypted = score_crypto.decrypt(self.allocator, encrypted.data, client_hash_encrypted, iv, osu_version) catch |err| return rejectStableScoreError(req, "decrypt_failed", err, body.len);
        defer decrypted.deinit();
        var score = stable_score.parse(decrypted.score_data) catch |err| {
            std.log.warn("stable score rejected: reason=score_parse_failed error={t} fields={d} plaintext_bytes={d} body_bytes={d}", .{ err, std.mem.count(u8, decrypted.score_data, ":") + 1, decrypted.score_data.len, body.len });
            return respond(req, .bad_request, "text/plain", "error: no", &.{});
        };
        if (!stable_score.replayLengthAccepted(false, replay.data.len)) return rejectStableScore(req, "replay_too_large", body.len);
        const passed_score_missing_replay = score.passed and replay.data.len == 0;
        if (!std.mem.eql(u8, score.map_md5, updated_map_hash)) {
            std.log.warn("stable score rejected: reason=beatmap_hash_mismatch body_bytes={d}", .{body.len});
            return respond(req, .bad_request, "text/plain", "error: beatmap", &.{});
        }
        const auth_username = if (score.username.len > 0 and score.username[score.username.len - 1] == ' ') score.username[0 .. score.username.len - 1] else score.username;
        const user = (try self.store.authenticate(self.allocator, auth_username, password)) orelse {
            std.log.warn("stable score rejected: reason=invalid_credentials body_bytes={d}", .{body.len});
            return respond(req, .ok, "text/plain", "error: no", &.{});
        };
        defer self.allocator.free(user.name);
        defer self.allocator.free(user.safe_name);
        if (!score.verifyChecksum(osu_version, decrypted.client_hash, storyboard_hash)) {
            self.observeStableSignal(user.id, .stable_score, anticheat_evidence.stableScoreSignal(score, .checksum_mismatch));
            return rejectStableScore(req, "checksum_mismatch", body.len);
        }
        if (passed_score_missing_replay) {
            self.observeStableSignal(user.id, .stable_score, anticheat_evidence.stableScoreSignal(score, .required_replay_missing));
            return rejectStableScore(req, "passed_score_missing_replay", body.len);
        }
        const submitted_binding = sessions_mod.StableClientBinding.init(osu_version, decrypted.client_hash) catch null;
        const score_auth = authorize: {
            const mutex = self.gameSessionMutex(user.id);
            mutex.lockUncancelable(self.store.io);
            defer mutex.unlock(self.store.io);
            break :authorize stable_score_auth.authorize(&self.store, &self.sessions, score_token_owned, user.id, submitted_binding, score.online_checksum, std.Io.Clock.real.now(self.store.io).toSeconds()) catch |err| {
                std.log.err("stable score retry requested: reason=grace_authorization_failed user_id={d} error={t}", .{ user.id, err });
                return respond(req, .ok, "text/plain", "error: no", &.{});
            };
        };
        switch (score_auth) {
            .exact => {},
            .grace => std.log.info("event=stable_score_grace_token_claimed user_id={d} checksum={s}", .{ user.id, score.online_checksum }),
            .missing => {
                std.log.warn("stable score rejected: reason=missing_session_token body_bytes={d}", .{body.len});
                return respond(req, .unauthorized, "text/plain", "", &.{});
            },
            .foreign => {
                std.log.warn("stable score rejected: reason=foreign_session_token user_id={d} body_bytes={d}", .{ user.id, body.len });
                return respond(req, .unauthorized, "text/plain", "", &.{});
            },
            .offline => {
                std.log.warn("stable score rejected: reason=inactive_session body_bytes={d}", .{body.len});
                return respond(req, .ok, "text/plain", "error: no", &.{});
            },
            .client_version_mismatch => {
                std.log.warn("stable score rejected: reason=client_version_mismatch user_id={d} body_bytes={d}", .{ user.id, body.len });
                return respond(req, .unauthorized, "text/plain", "", &.{});
            },
            .client_hardware_mismatch => {
                std.log.warn("stable score rejected: reason=client_hardware_mismatch user_id={d} body_bytes={d}", .{ user.id, body.len });
                return respond(req, .unauthorized, "text/plain", "", &.{});
            },
            .missing_login_client_binding => {
                std.log.err("stable score rejected: reason=missing_login_client_binding user_id={d} body_bytes={d}", .{ user.id, body.len });
                return respond(req, .unauthorized, "text/plain", "", &.{});
            },
            .invalid_client_binding => {
                std.log.warn("stable score rejected: reason=invalid_client_binding user_id={d} body_bytes={d}", .{ user.id, body.len });
                return respond(req, .unauthorized, "text/plain", "", &.{});
            },
            .unknown, .expired, .consumed, .revoked, .current_not_grace => {
                std.log.warn("stable score retry requested: reason={s} user_id={d} body_bytes={d}", .{ @tagName(score_auth), user.id, body.len });
                return respond(req, .ok, "text/plain", "error: no", &.{});
            },
        }
        const map_file = (try self.store.beatmapFile(self.allocator, score.map_md5)) orelse return respond(req, .ok, "text/plain", "error: beatmap", &.{});
        defer self.allocator.free(map_file);
        const performance = pp_admin.calculate(self.allocator, map_file, .{
            .source = .stable,
            .namespace = ppNamespace(score.rankNamespace()) orelse return respond(req, .ok, "text/plain", "error: no", &.{}),
            .input = .{
                .mode = score.mode,
                .lazer = 0,
                .mods = @intCast(score.mods),
                .max_combo = @intCast(score.max_combo),
                .n_geki = @intCast(score.ngeki),
                .n_katu = @intCast(score.nkatu),
                .n300 = @intCast(score.n300),
                .n100 = @intCast(score.n100),
                .n50 = @intCast(score.n50),
                .misses = @intCast(score.nmiss),
                .legacy_total_score = @intCast(@min(score.total_score, std.math.maxInt(u32))),
            },
        }) catch return respond(req, .ok, "text/plain", "error: beatmap", &.{});
        score.achievement_stars = performance.stars;
        const elapsed_ms = if (score.passed) score_time else fail_time;
        var replay_digest: [32]u8 = undefined;
        const has_replay_fingerprint = replay.data.len != 0;
        if (has_replay_fingerprint) std.crypto.hash.sha2.Sha256.hash(replay.data, &replay_digest, .{});
        const stats_mode = stable_score.statsMode(score.mode, score.mods) orelse return respond(req, .ok, "text/plain", "error: no", &.{});
        const before_stats = (try self.store.statsForUser(user.id, stats_mode)) orelse domain.Stats{};
        const score_id = self.store.insertStableScore(user.id, score, performance.pp, replay.data, elapsed_ms) catch |err| {
            std.log.warn("stable score insert failed: {t}", .{err});
            return respond(req, .ok, "text/plain", "error: no", &.{});
        };
        if (replay.data.len != 0) {
            _ = self.store.storeReplayObject(.stable, score_id, replay.data) catch |err| failed: {
                std.log.warn("event=replay_object_write_failed source=stable score_id={d} error={t}", .{ score_id, err });
                break :failed false;
            };
        }
        if (has_replay_fingerprint) self.store.recordReplayFingerprint(user.id, score_id, &replay_digest) catch |err| {
            std.log.warn("event=anticheat_replay_fingerprint_write_failed score_id={d} error={t}", .{ score_id, err });
        };
        const replay_match_count = if (has_replay_fingerprint) self.store.crossAccountReplayMatches(user.id, &replay_digest) catch |err| blk: {
            std.log.warn("event=anticheat_replay_match_lookup_failed user_id={d} error={t}", .{ user.id, err });
            break :blk 0;
        } else 0;
        switch (self.observeStableGameplay(user.id, score, replay.data, map_file, performance, elapsed_ms, replay_match_count)) {
            .none => {},
            .invalid_replay => self.persistHostAnticheatObservation(user.id, .stable_score, score_id, anticheat_evidence.stableReplay(.invalid_payload, replay_match_count)),
            .result => |observation| {
                self.store.recordReplayContentFingerprint(user.id, score_id, &observation.replay_content_digest) catch |err| {
                    std.log.warn("event=anticheat_replay_content_fingerprint_write_failed score_id={d} error={t}", .{ score_id, err });
                };
                const allow_sample = observation.result.decision.action == anticheat_abi.Action.allow and self.anticheat_allow_sample_modulus != 0 and @mod(score_id, @as(i64, self.anticheat_allow_sample_modulus)) == 0;
                if (observation.result.decision.action != anticheat_abi.Action.allow or allow_sample) self.persistAnticheatObservation(user.id, score_id, if (allow_sample) self.anticheat_allow_sample_modulus else 1, observation.evidence, replay_match_count, observation.result);
            },
        }
        const after_stats = (try self.store.statsForUser(user.id, stats_mode)) orelse domain.Stats{};
        const placement = try self.store.scoreLeaderboardPlacement(score_id);
        bancho.publishStats(self.allocator, &self.store, &self.sessions, user.id, score.mode, score.mods) catch {};
        scoreLog(user.name, score, performance.pp, placement);
        if (!score.passed) return respond(req, .ok, "text/plain", "error: no", &.{});
        const map_state = (try self.store.beatmapForScore(score.map_md5)) orelse return respond(req, .ok, "text/plain", "error: no", &.{});
        const placed = placement orelse return respond(req, .ok, "text/plain", "error: no", &.{});
        if (webhook.shouldAnnounceScore(placed, performance.pp)) {
            if (try self.store.beatmapInfo(self.allocator, score.map_md5)) |info| {
                defer self.allocator.free(info.artist);
                defer self.allocator.free(info.title);
                defer self.allocator.free(info.version);
                defer self.allocator.free(info.creator);
                announceScore(self.allocator, &self.sessions, user.name, score, performance.pp, placed, info) catch {};
                self.score_webhook.postScore(.{
                    .username = user.name,
                    .user_id = user.id,
                    .grade = score.grade,
                    .mods = score.mods,
                    .mode = score.mode,
                    .rank = placed.rank + 1,
                    .total_score = score.total_score,
                    .max_combo = score.max_combo,
                    .beatmap_max_combo = info.max_combo,
                    .accuracy = score.accuracy(),
                    .pp = performance.pp,
                    .stars = performance.stars,
                    .perfect = score.perfect,
                    .artist = info.artist,
                    .title = info.title,
                    .version = info.version,
                    .set_id = info.set_id,
                });
            }
        }
        const unlocked_achievements = try self.store.newAchievementsForScore("stable", score_id);
        const response_body = try stable_response.scoreSubmission(self.allocator, user.id, score_id, score, .{ .id = map_state.id, .set_id = map_state.set_id, .plays = map_state.plays, .passes = map_state.passes }, placed, before_stats, after_stats, performance.pp, unlocked_achievements);
        defer self.allocator.free(response_body);
        return respond(req, .ok, "text/plain", response_body, &.{});
    }
    if (std.mem.eql(u8, path, "/web/osu-screenshot.php") and req.head.method == .POST) {
        const content_type = content_type_owned orelse return respond(req, .bad_request, "text/plain", "Invalid file type", &.{});
        const boundary = multipart.boundaryFromContentType(content_type) catch return respond(req, .bad_request, "text/plain", "Invalid file type", &.{});
        var form = multipart.parse(self.allocator, body, boundary) catch return respond(req, .bad_request, "text/plain", "Invalid file type", &.{});
        defer form.deinit();
        const username_part = form.first("u") orelse return respond(req, .unauthorized, "text/plain", "", &.{});
        const password = (form.first("p") orelse return respond(req, .unauthorized, "text/plain", "", &.{})).data;
        const endpoint_version = std.fmt.parseInt(u8, (form.first("v") orelse return respond(req, .bad_request, "text/plain", "Invalid file type", &.{})).data, 10) catch return respond(req, .bad_request, "text/plain", "Invalid file type", &.{});
        const upload = form.first("ss") orelse return respond(req, .bad_request, "text/plain", "Invalid file type", &.{});
        if (upload.filename == null) return respond(req, .bad_request, "text/plain", "Invalid file type", &.{});
        const name_buf = try self.allocator.dupe(u8, username_part.data);
        defer self.allocator.free(name_buf);
        for (name_buf) |*char| if (char.* == '+') {
            char.* = ' ';
        };
        const name = std.Uri.percentDecodeInPlace(name_buf);
        const user = (try self.store.authenticate(self.allocator, name, password)) orelse return respond(req, .unauthorized, "text/plain", "", &.{});
        defer self.allocator.free(user.name);
        defer self.allocator.free(user.safe_name);
        if (!self.userOnline(user.id)) return respond(req, .unauthorized, "text/plain", "", &.{});
        const kind = screenshot.detect(upload.data) catch |err| return switch (err) {
            error.FileTooLarge => respond(req, .bad_request, "text/plain", "Screenshot file too large.", &.{}),
            else => respond(req, .bad_request, "text/plain", "Invalid file type", &.{}),
        };
        if (endpoint_version != 1) std.log.warn("stable screenshot used unexpected endpoint version: user_id={d} version={d}", .{ user.id, endpoint_version });
        var token_value: [8]u8 = undefined;
        var stored = false;
        for (0..8) |_| {
            token_value = try screenshot.generateToken(self.store.io);
            if (self.store.putScreenshot(user.id, &token_value, kind.extension(), upload.data) catch |err| switch (err) {
                error.ScreenshotQuotaExceeded => return respond(req, .bad_request, "text/plain", "Screenshot storage full.", &.{}),
                else => return err,
            }) {
                stored = true;
                break;
            }
        }
        if (!stored) return respond(req, .service_unavailable, "text/plain", "", &.{});
        var filename_buf: [13]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buf, "{s}.{s}", .{ &token_value, kind.extension() });
        std.log.info("event=stable_screenshot_uploaded user_id={d} filename={s} bytes={d}", .{ user.id, filename, upload.data.len });
        return respond(req, .ok, "text/plain", filename, &.{});
    }
    if (std.mem.eql(u8, path, "/web/osu-getreplay.php") and req.head.method == .GET) {
        const encoded_name = queryField(target, "u") orelse return respond(req, .bad_request, "text/plain", "", &.{});
        const password = queryField(target, "h") orelse return respond(req, .unauthorized, "text/plain", "", &.{});
        const score_id_text = queryField(target, "c") orelse return respond(req, .bad_request, "text/plain", "", &.{});
        const score_id = std.fmt.parseInt(i64, score_id_text, 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
        const name_buf = try self.allocator.dupe(u8, encoded_name);
        defer self.allocator.free(name_buf);
        for (name_buf) |*c| {
            if (c.* == '+') c.* = ' ';
        }
        const name = std.Uri.percentDecodeInPlace(name_buf);
        const user = (try self.store.authenticate(self.allocator, name, password)) orelse return respond(req, .unauthorized, "text/plain", "", &.{});
        defer self.allocator.free(user.name);
        defer self.allocator.free(user.safe_name);
        const replay = (try player_routes.stableReplay(self.allocator, &self.store, user.id, score_id)) orelse return respond(req, .not_found, "text/plain", "", &.{});
        defer self.allocator.free(replay);
        return respond(req, .ok, "application/octet-stream", replay, &.{});
    }
    return error.UnmatchedRouteStage;
}

pub fn handle(self: anytype, req: *std.http.Server.Request, ctx: *const Context) !Result {
    dispatch(self, req, ctx) catch |err| return switch (err) {
        error.UnmatchedRouteStage => .unmatched,
        else => err,
    };
    return .handled;
}
