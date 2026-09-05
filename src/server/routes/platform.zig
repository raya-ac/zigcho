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
const healthResponse = support.healthResponse;
const featureUnavailable = @import("../app/control.zig").featureUnavailable;

fn dispatch(self: anytype, req: *std.http.Server.Request, ctx: *const Context) !void {
    const target = ctx.target;
    const path = ctx.path;
    const auth_owned = ctx.auth_owned;
    const content_type_owned = ctx.content_type_owned;
    const host_owned = ctx.host_owned;
    const bss_path = ctx.bss_path;
    const bss_user = ctx.bss_user;
    const body = ctx.body;
    if (bss_path) |route| switch (route) {
        .collection => {
            const content_type = content_type_owned orelse return respond(req, .unsupported_media_type, "application/json", "{\"error\":\"application/json required\"}", &.{});
            if (!std.ascii.startsWithIgnoreCase(content_type, "application/json")) return respond(req, .unsupported_media_type, "application/json", "{\"error\":\"application/json required\"}", &.{});
            var input = bss.parseReserveInput(self.allocator, body) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid beatmap reservation\"}", &.{});
            defer input.deinit();
            var reservation = self.store.reserveBssSubmission(self.allocator, bss_user.?.id, input) catch |err| return switch (err) {
                error.BssSubmissionNotFound => respond(req, .not_found, "application/json", "{\"error\":\"beatmap set not found\"}", &.{}),
                error.BssNotOwner, error.BssBeatmapNotOwned => respond(req, .forbidden, "application/json", "{\"error\":\"this beatmap set belongs to another mapper\"}", &.{}),
                error.InvalidBssReservation => respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid beatmap reservation\"}", &.{}),
                error.BssIdentifierExhausted => respond(req, .service_unavailable, "application/json", "{\"error\":\"beatmap identifiers unavailable\"}", &.{}),
                else => return err,
            };
            defer reservation.deinit();
            var old_bytes: ?[]u8 = null;
            defer if (old_bytes) |value| self.allocator.free(value);
            var old_archive: ?bss.Archive = null;
            defer if (old_archive) |*value| value.deinit();
            if (input.set_id != null) {
                old_bytes = self.store.beatmapArchive(self.allocator, reservation.set_id) catch |err| blk: {
                    std.log.warn("event=bss_manifest_load_failed set_id={d} error={t}", .{ reservation.set_id, err });
                    break :blk null;
                };
                if (old_bytes) |value| old_archive = bss.parseArchive(self.allocator, value) catch |err| blk: {
                    std.log.warn("event=bss_manifest_parse_failed set_id={d} error={t}", .{ reservation.set_id, err });
                    break :blk null;
                };
            }
            const json = try bss.reservationJson(self.allocator, reservation, if (old_archive) |*value| value else null);
            defer self.allocator.free(json);
            std.log.info("event=bss_reserved user_id={d} set_id={d} maps={d} revision={d} target={s}", .{ bss_user.?.id, reservation.set_id, reservation.beatmap_ids.len, reservation.revision, input.target.database() });
            return respond(req, .ok, "application/json", json, &.{.{ .name = "cache-control", .value = "no-store" }});
        },
        .set => |set_id| {
            const expected_ids = self.store.bssReservedMapIds(self.allocator, bss_user.?.id, set_id) catch |err| return switch (err) {
                error.BssSubmissionNotFound => respond(req, .not_found, "application/json", "{\"error\":\"beatmap set not found\"}", &.{}),
                error.BssNotOwner => respond(req, .forbidden, "application/json", "{\"error\":\"this beatmap set belongs to another mapper\"}", &.{}),
                else => return err,
            };
            defer self.allocator.free(expected_ids);
            const content_type = content_type_owned orelse return respond(req, .unsupported_media_type, "application/json", "{\"error\":\"multipart/form-data required\"}", &.{});
            const boundary = multipart.boundaryFromContentType(content_type) catch return respond(req, .unsupported_media_type, "application/json", "{\"error\":\"multipart/form-data required\"}", &.{});
            var form = multipart.parse(self.allocator, body, boundary) catch |err| {
                self.store.failBssSubmission(bss_user.?.id, set_id, @errorName(err)) catch {};
                return respond(req, .bad_request, "application/json", "{\"error\":\"invalid upload form\"}", &.{});
            };
            defer form.deinit();
            var rebuilt: ?[]u8 = null;
            defer if (rebuilt) |value| self.allocator.free(value);
            var current: ?[]u8 = null;
            defer if (current) |value| self.allocator.free(value);
            const archive = if (req.head.method == .PUT) blk: {
                const part = form.first("beatmapArchive") orelse {
                    self.store.failBssSubmission(bss_user.?.id, set_id, "missing beatmapArchive") catch {};
                    return respond(req, .bad_request, "application/json", "{\"error\":\"beatmapArchive required\"}", &.{});
                };
                if (part.filename == null) return respond(req, .bad_request, "application/json", "{\"error\":\"beatmapArchive filename required\"}", &.{});
                break :blk part.data;
            } else blk: {
                current = (try self.store.beatmapArchive(self.allocator, set_id)) orelse return respond(req, .conflict, "application/json", "{\"error\":\"full package upload required\"}", &.{});
                rebuilt = bss.applyPatch(self.allocator, current.?, &form) catch |err| {
                    self.store.failBssSubmission(bss_user.?.id, set_id, @errorName(err)) catch {};
                    return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid beatmap package patch\"}", &.{});
                };
                break :blk rebuilt.?;
            };
            var package = bss.preparePackage(self.allocator, archive, set_id, expected_ids) catch |err| {
                self.store.failBssSubmission(bss_user.?.id, set_id, @errorName(err)) catch {};
                std.log.warn("event=bss_package_rejected user_id={d} set_id={d} error={t}", .{ bss_user.?.id, set_id, err });
                return respond(req, .unprocessable_entity, "application/json", bss.packageErrorJson(err), &.{});
            };
            defer package.deinit();
            const package_media = package.media();
            const digest = bss.archiveSha256(archive);
            self.store.publishBssSubmission(bss_user.?.id, set_id, &package, archive, &digest) catch |err| {
                if (bssStorageFailure(err)) return respond(req, .service_unavailable, "application/json", "{\"error\":\"beatmap storage unavailable\"}", &.{.{ .name = "retry-after", .value = "30" }});
                return switch (err) {
                    error.BssSubmissionNotFound => respond(req, .not_found, "application/json", "{\"error\":\"beatmap set not found\"}", &.{}),
                    error.BssNotOwner => respond(req, .forbidden, "application/json", "{\"error\":\"this beatmap set belongs to another mapper\"}", &.{}),
                    error.BssRevisionMismatch => respond(req, .conflict, "application/json", "{\"error\":\"beatmap set changed; submit it again\"}", &.{}),
                    else => return err,
                };
            };
            self.storeBssMedia(set_id, package_media) catch |err| {
                self.store.failBssSubmission(bss_user.?.id, set_id, @errorName(err)) catch {};
                std.log.warn("event=bss_media_store_failed user_id={d} set_id={d} error={t}", .{ bss_user.?.id, set_id, err });
                return respond(req, .service_unavailable, "application/json", "{\"error\":\"beatmap media storage unavailable\"}", &.{.{ .name = "retry-after", .value = "30" }});
            };
            std.log.info("event=bss_published user_id={d} set_id={d} maps={d} bytes={d} cover={s} preview={s} sha256={s}", .{ bss_user.?.id, set_id, package.maps.len, archive.len, if (package_media.cover != null) "uploaded" else "default", if (package_media.preview != null) "true" else "false", &digest });
            return respond(req, .no_content, "application/json", "", &.{.{ .name = "cache-control", .value = "no-store" }});
        },
    };

    if (std.mem.eql(u8, path, "/api/v2/rooms") and req.head.method == .POST) {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"authentication required\"}", &.{});
        defer freeUser(self.allocator, user);
        if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"account restricted\"}", &.{});
        const json = self.lazer_multiplayer.restCreateRoom(self.allocator, user, body) catch |err| return switch (err) {
            error.InvalidMultiplayerRoom, error.MultiplayerPayloadTooLarge => respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid room\"}", &.{}),
            error.AlreadyInMultiplayerRoom => respond(req, .conflict, "application/json", "{\"error\":\"already in a room\"}", &.{}),
            error.MultiplayerRoomLimit => respond(req, .service_unavailable, "application/json", "{\"error\":\"room limit reached\"}", &.{}),
            error.MultiplayerDisabled, error.ServerShuttingDown => featureUnavailable(req, .lazer_multiplayer),
            else => return err,
        };
        defer self.allocator.free(json);
        return respond(req, .created, "application/json", json, &.{.{ .name = "cache-control", .value = "no-store" }});
    }
    if (lazer_multiplayer.parseRoomUserPath(path)) |room_user_path| {
        if (req.head.method != .PUT and req.head.method != .DELETE) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"authentication required\"}", &.{});
        defer freeUser(self.allocator, user);
        if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"account restricted\"}", &.{});
        if (room_user_path.user_id != user.id) return respond(req, .forbidden, "application/json", "{\"error\":\"room user mismatch\"}", &.{});
        if (req.head.method == .DELETE) {
            self.lazer_multiplayer.restPartRoom(user.id, room_user_path.room_id) catch |err| return switch (err) {
                error.MultiplayerRoomNotFound, error.NotInMultiplayerRoom => respond(req, .not_found, "application/json", "{\"error\":\"room not found\"}", &.{}),
                error.MultiplayerDisabled, error.ServerShuttingDown => featureUnavailable(req, .lazer_multiplayer),
            };
            return respond(req, .no_content, "application/json", "", &.{.{ .name = "cache-control", .value = "no-store" }});
        }
        const encoded_password = queryField(target, "password") orelse "";
        const password_buf = try self.allocator.dupe(u8, encoded_password);
        defer self.allocator.free(password_buf);
        for (password_buf) |*char| {
            if (char.* == '+') char.* = ' ';
        }
        const password = std.Uri.percentDecodeInPlace(password_buf);
        const json = self.lazer_multiplayer.restJoinRoom(self.allocator, user, room_user_path.room_id, password) catch |err| return switch (err) {
            error.MultiplayerRoomNotFound => respond(req, .not_found, "application/json", "{\"error\":\"room not found\"}", &.{}),
            error.InvalidMultiplayerPassword => respond(req, .forbidden, "application/json", "{\"error\":\"invalid password\"}", &.{}),
            error.MultiplayerPermissionDenied => respond(req, .forbidden, "application/json", "{\"error\":\"room access denied\"}", &.{}),
            error.AlreadyInMultiplayerRoom => respond(req, .conflict, "application/json", "{\"error\":\"already in a room\"}", &.{}),
            error.MultiplayerRoomFull => respond(req, .conflict, "application/json", "{\"error\":\"room is full\"}", &.{}),
            error.MultiplayerDisabled, error.ServerShuttingDown => featureUnavailable(req, .lazer_multiplayer),
            else => return err,
        };
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{.{ .name = "cache-control", .value = "no-store" }});
    }
    if (lazer_multiplayer.parseRoomPath(path)) |room_id| {
        if (req.head.method == .DELETE) {
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"authentication required\"}", &.{});
            defer freeUser(self.allocator, user);
            self.lazer_multiplayer.restCloseRoom(user.id, room_id) catch |err| return switch (err) {
                error.MultiplayerRoomNotFound => respond(req, .not_found, "application/json", "{\"error\":\"room not found\"}", &.{}),
                error.MultiplayerPermissionDenied => respond(req, .forbidden, "application/json", "{\"error\":\"only the host can close this room\"}", &.{}),
                error.MultiplayerDisabled, error.ServerShuttingDown => featureUnavailable(req, .lazer_multiplayer),
            };
            return respond(req, .no_content, "application/json", "", &.{.{ .name = "cache-control", .value = "no-store" }});
        }
        return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
    }

    if (std.mem.eql(u8, path, "/health")) {
        var buf: [256]u8 = undefined;
        const json = try healthResponse(&buf, try self.combinedOnlineCount());
        return respond(req, .ok, "application/json", json, &.{});
    }
    if (std.mem.eql(u8, path, "/metrics/runtime")) {
        if (req.head.method != .GET or !isLocalMetricsHost(host_owned)) return respond(req, .not_found, "text/plain", "not found\n", &.{});
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        try @import("../../telemetry.zig").writePrometheus(&output.writer);
        try output.writer.print("# TYPE zigcho_http_connections gauge\nzigcho_http_connections {d}\n# TYPE zigcho_http_connection_limit gauge\nzigcho_http_connection_limit {d}\n# TYPE zigcho_http_rejected counter\nzigcho_http_rejected {d}\n# TYPE zigcho_http_timeouts counter\nzigcho_http_timeouts {d}\n", .{ self.http_gate.active.load(.acquire), self.http_gate.limit, self.http_gate.rejected.load(.acquire), self.http_gate.timed_out.load(.acquire) });
        return respond(req, .ok, "text/plain; version=0.0.4; charset=utf-8", output.written(), &.{.{ .name = "cache-control", .value = "no-store" }});
    }
    if (std.mem.eql(u8, path, "/metrics")) {
        if (req.head.method != .GET or !isLocalMetricsHost(host_owned)) return respond(req, .not_found, "text/plain", "not found\n", &.{});
        const online = try self.combinedOnlineCount();
        const counts = try self.store.serverCounts();
        const cache = try self.store.beatmapCacheStats();
        const media_cache = try self.store.beatmapMediaCacheStats();
        const hydration = self.map_sync.metrics();
        const media = self.media_sync.metrics();
        const uptime = @max(@as(i64, 0), std.Io.Clock.real.now(self.store.io).toSeconds() - self.started_at);
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        try output.writer.print(
            "# HELP zigcho_up Whether the server can answer requests.\n" ++
                "# TYPE zigcho_up gauge\nzigcho_up 1\n" ++
                "# TYPE zigcho_online_users gauge\nzigcho_online_users {d}\n" ++
                "# TYPE zigcho_http_connections gauge\nzigcho_http_connections {d}\n" ++
                "# TYPE zigcho_http_connection_limit gauge\nzigcho_http_connection_limit {d}\n" ++
                "# TYPE zigcho_http_rejected counter\nzigcho_http_rejected {d}\n" ++
                "# TYPE zigcho_http_timeouts counter\nzigcho_http_timeouts {d}\n" ++
                "# TYPE zigcho_accounts gauge\nzigcho_accounts {d}\n" ++
                "# TYPE zigcho_plays gauge\nzigcho_plays {d}\n" ++
                "# TYPE zigcho_passed_plays gauge\nzigcho_passed_plays {d}\n" ++
                "# TYPE zigcho_beatmaps gauge\nzigcho_beatmaps {d}\n" ++
                "# TYPE zigcho_beatmap_cache_entries gauge\nzigcho_beatmap_cache_entries {d}\n" ++
                "# TYPE zigcho_beatmap_cache_bytes gauge\nzigcho_beatmap_cache_bytes {d}\n" ++
                "# TYPE zigcho_beatmap_media_cache_entries gauge\nzigcho_beatmap_media_cache_entries {d}\n" ++
                "# TYPE zigcho_beatmap_media_cache_bytes gauge\nzigcho_beatmap_media_cache_bytes {d}\n" ++
                "# TYPE zigcho_beatmap_hydration_blocked gauge\nzigcho_beatmap_hydration_blocked {d}\n" ++
                "# TYPE zigcho_beatmap_hydration_attempts counter\nzigcho_beatmap_hydration_attempts {d}\n" ++
                "# TYPE zigcho_beatmap_hydration_successes counter\nzigcho_beatmap_hydration_successes {d}\n" ++
                "# TYPE zigcho_beatmap_hydration_failures counter\nzigcho_beatmap_hydration_failures {d}\n" ++
                "# TYPE zigcho_beatmap_hydration_backoff_skips counter\nzigcho_beatmap_hydration_backoff_skips {d}\n" ++
                "# TYPE zigcho_beatmap_hydration_capacity_skips counter\nzigcho_beatmap_hydration_capacity_skips {d}\n" ++
                "# TYPE zigcho_beatmap_cache_pruned_entries counter\nzigcho_beatmap_cache_pruned_entries {d}\n" ++
                "# TYPE zigcho_beatmap_cache_pruned_bytes counter\nzigcho_beatmap_cache_pruned_bytes {d}\n" ++
                "# TYPE zigcho_beatmap_mirror_hits counter\nzigcho_beatmap_mirror_hits {d}\n" ++
                "# TYPE zigcho_beatmap_mirror_misses counter\nzigcho_beatmap_mirror_misses {d}\n" ++
                "# TYPE zigcho_beatmap_mirror_fills counter\nzigcho_beatmap_mirror_fills {d}\n" ++
                "# TYPE zigcho_beatmap_mirror_failures counter\nzigcho_beatmap_mirror_failures {d}\n" ++
                "# TYPE zigcho_beatmap_mirror_bytes_served counter\nzigcho_beatmap_mirror_bytes_served {d}\n" ++
                "# TYPE zigcho_beatmap_media_fetch_attempts counter\nzigcho_beatmap_media_fetch_attempts {d}\n" ++
                "# TYPE zigcho_beatmap_media_fetch_successes counter\nzigcho_beatmap_media_fetch_successes {d}\n" ++
                "# TYPE zigcho_beatmap_media_fetch_failures counter\nzigcho_beatmap_media_fetch_failures {d}\n" ++
                "# TYPE zigcho_beatmap_media_cache_pruned_entries counter\nzigcho_beatmap_media_cache_pruned_entries {d}\n" ++
                "# TYPE zigcho_beatmap_media_cache_pruned_bytes counter\nzigcho_beatmap_media_cache_pruned_bytes {d}\n" ++
                "# TYPE zigcho_uptime_seconds counter\nzigcho_uptime_seconds {d}\n",
            .{ online, self.http_gate.active.load(.acquire), self.http_gate.limit, self.http_gate.rejected.load(.acquire), self.http_gate.timed_out.load(.acquire), counts.users, counts.plays, counts.passed, counts.maps, cache.entries, cache.bytes, media_cache.entries, media_cache.bytes, cache.hydration_failures, hydration.attempts, hydration.successes, hydration.failures, hydration.backoff_skips, hydration.capacity_skips, hydration.pruned_entries, hydration.pruned_bytes, hydration.mirror_hits, hydration.mirror_misses, hydration.mirror_fills, hydration.mirror_failures, hydration.mirror_bytes_served, media.attempts, media.successes, media.failures, media.pruned_entries, media.pruned_bytes, uptime },
        );
        try @import("../../telemetry.zig").writePrometheus(&output.writer);
        return respond(req, .ok, "text/plain; version=0.0.4; charset=utf-8", output.written(), &.{.{ .name = "cache-control", .value = "no-store" }});
    }
    if (std.mem.eql(u8, path, "/api/v1/status")) {
        const online = try self.combinedOnlineCount();
        const counts = try self.store.serverCounts();
        var buf: [384]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf, "{{\"ok\":true,\"service\":\"zigcho\",\"stage\":\"stable\",\"online\":{d},\"users\":{d},\"plays\":{d},\"passed\":{d},\"maps\":{d},\"protocol\":19}}", .{ online, counts.users, counts.plays, counts.passed, counts.maps });
        return respond(req, .ok, "application/json", json, &.{});
    }
    if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/changelog")) {
        const json = try self.changelog_feed.indexJson(self.allocator);
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{.{ .name = "cache-control", .value = "public, max-age=60, stale-if-error=86400" }});
    }
    if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v2/changelog/")) {
        var parts = std.mem.splitScalar(u8, path["/api/v2/changelog/".len..], '/');
        const stream = parts.next() orelse return respond(req, .not_found, "application/json", "{\"error\":\"build not found\"}", &.{});
        const version = parts.next() orelse return respond(req, .not_found, "application/json", "{\"error\":\"build not found\"}", &.{});
        if (parts.next() != null) return respond(req, .not_found, "application/json", "{\"error\":\"build not found\"}", &.{});
        const json = (try self.changelog_feed.buildJson(self.allocator, stream, version)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"build not found\"}", &.{});
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{.{ .name = "cache-control", .value = "public, max-age=60, stale-if-error=86400" }});
    }
    if ((req.head.method == .GET or req.head.method == .HEAD) and web_auth.websiteHost(host_owned) and std.mem.startsWith(u8, path, "/home/news/")) {
        const slug_value = path["/home/news/".len..];
        if (slug_value.len == 0 or std.mem.indexOfScalar(u8, slug_value, '/') != null or !self.changelog_feed.newsSlugKnown(slug_value)) return respond(req, .not_found, "application/json", "{\"error\":\"news post not found\"}", &.{});
        return respond(req, .temporary_redirect, "text/plain", "", &.{.{ .name = "location", .value = "/changelog" }});
    }
    if (std.mem.eql(u8, path, "/api/v1/mirror/status")) {
        if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const cache = try self.store.beatmapCacheStats();
        const pending = try self.store.beatmapMirrorPendingCount();
        const metrics = self.map_sync.metrics();
        const capacity: u64 = 1_500_000_000_000;
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        try output.writer.print("{{\"ok\":true,\"service\":\"beatmap mirror\",\"stored_sets\":{d},\"stored_bytes\":{d},\"capacity_bytes\":{d},\"known_sets_waiting\":{d},\"hits\":{d},\"misses\":{d},\"fills\":{d},\"failures\":{d},\"bytes_served\":{d}}}", .{ cache.entries, cache.bytes, capacity, pending, metrics.mirror_hits, metrics.mirror_misses, metrics.mirror_fills, metrics.mirror_failures, metrics.mirror_bytes_served });
        return respond(req, .ok, "application/json", output.written(), &.{.{ .name = "cache-control", .value = "no-store" }});
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
