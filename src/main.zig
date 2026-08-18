const std = @import("std");
const builtin = @import("builtin");
const domain = @import("domain.zig");
const storage = @import("runtime_storage.zig");
const sqlite_storage = @import("storage.zig");
const sessions_mod = @import("sessions.zig");
const bancho = @import("bancho.zig");
const lazer = @import("lazer.zig");
const lazer_bot = @import("lazer_bot.zig");
const lazer_multiplayer = @import("lazer_multiplayer.zig");
const lazer_spectator = @import("lazer_spectator.zig");
const multipart = @import("multipart.zig");
const score_crypto = @import("score_crypto.zig");
const stable_score = @import("stable_score.zig");
const stable_mods = @import("stable_mods.zig");
const stable_response = @import("stable_response.zig");
const achievements = @import("achievements.zig");
const rate_limit = @import("rate_limit.zig");
const pp = @import("exact_pp.zig");
const screenshot = @import("screenshot.zig");
const status_page = @embedFile("status.html");
const form_urlencoded = @import("form_urlencoded.zig");
const registration = @import("registration.zig");
const routing = @import("routing.zig");
const beatmap_sync = @import("beatmap_sync.zig");
const beatmap_media = @import("beatmap_media.zig");
const media_contract = @import("media_contract.zig");
const webhook = @import("webhook.zig");
const protocol = @import("protocol.zig");
const country = @import("country.zig");
const log = @import("logutil.zig");
const config_mod = @import("config.zig");
const web_auth = @import("web_auth.zig");
const proxy = @import("proxy.zig");
const user_json = @import("user_json.zig");
const profile_avatar = @import("profile_avatar.zig");
const avatar_cache = @import("avatar_cache.zig");
const r2 = @import("r2.zig");
const object_keys = @import("object_keys.zig");
const anticheat_abi = @import("anticheat_abi.zig");
const anticheat_plugin = @import("anticheat_plugin.zig");
const anticheat_replay = @import("anticheat_replay.zig");
const default_avatar_1 = @embedFile("assets/avatars/default-1.gif");
const default_avatar_2 = @embedFile("assets/avatars/default-2.jpg");

fn freeUser(allocator: std.mem.Allocator, user: domain.User) void {
    allocator.free(user.name);
    allocator.free(user.safe_name);
}

fn randomMessageUuid(io: std.Io) ![36]u8 {
    var raw: [16]u8 = undefined;
    try std.Io.randomSecure(io, &raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    var uuid: [36]u8 = undefined;
    @memcpy(uuid[0..8], hex[0..8]);
    uuid[8] = '-';
    @memcpy(uuid[9..13], hex[8..12]);
    uuid[13] = '-';
    @memcpy(uuid[14..18], hex[12..16]);
    uuid[18] = '-';
    @memcpy(uuid[19..23], hex[16..20]);
    uuid[23] = '-';
    @memcpy(uuid[24..36], hex[20..32]);
    return uuid;
}

const LazerPerformance = struct { pp: f64 = 0, stars: f64 = 0, max_combo: u32 = 0, mods: u32 = 0 };

fn lazerPerformance(allocator: std.mem.Allocator, store: *storage.Store, input: lazer.ScoreInput, mods_json: []const u8) !LazerPerformance {
    const state = (try lazer.performanceState(input)) orelse return .{};
    const map_file = (try store.beatmapFileById(allocator, @intCast(input.beatmap_id))) orelse return error.BeatmapPayloadMissing;
    defer allocator.free(map_file);
    const performance_input: pp.Input = .{
        .mode = @intCast(input.ruleset_id),
        .lazer = 1,
        .mods = state.mods,
        .max_combo = state.max_combo,
        .large_tick_hits = state.large_tick_hits,
        .small_tick_hits = state.small_tick_hits,
        .slider_end_hits = state.slider_end_hits,
        .n_geki = state.n_geki,
        .n_katu = state.n_katu,
        .n300 = state.n300,
        .n100 = state.n100,
        .n50 = state.n50,
        .misses = state.misses,
        .legacy_total_score = state.legacy_total_score,
    };
    const performance = if (input.namespace == .vanilla)
        try pp.calculateLazer(map_file, mods_json, performance_input)
    else
        try pp.calculate(map_file, performance_input);
    return .{ .pp = performance.pp, .stars = performance.stars, .max_combo = performance.max_combo, .mods = state.mods };
}

fn intLines(allocator: std.mem.Allocator, values: []const i32) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (values, 0..) |value, index| {
        if (index != 0) try output.writer.writeByte('\n');
        try output.writer.print("{d}", .{value});
    }
    return output.toOwnedSlice();
}

fn validWebText(value: []const u8, minimum: usize, maximum: usize) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return trimmed.len >= minimum and trimmed.len <= maximum and std.unicode.utf8ValidateSlice(trimmed);
}

fn validWebLine(value: []const u8, maximum: usize) bool {
    return validWebText(value, 0, maximum) and std.mem.indexOfAny(u8, value, "\r\n") == null;
}

fn validProfileWebsite(value: []const u8) bool {
    if (value.len == 0) return true;
    if (value.len > 200 or !std.mem.startsWith(u8, value, "https://") or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (std.ascii.isWhitespace(byte) or byte < 0x20 or byte == 0x7f or byte == '"' or byte == '\'' or byte == '<' or byte == '>') return false;
    return value.len > "https://".len;
}

fn stableClientPrivileges(server: u32) u8 {
    var client: u8 = 1 << 2;
    if (server & 1 != 0) client |= 1 << 0;
    if (server & ((1 << 4) | (1 << 5)) != 0) client |= 1 << 2;
    if (server & (1 << 12) != 0) client |= 1 << 1;
    if (server & (1 << 13) != 0) client |= 1 << 4;
    if (server & (1 << 14) != 0) client |= 1 << 3;
    return client;
}

fn scoreLog(user_name: []const u8, score: stable_score.Submission, pp_value: f64, placement: ?domain.ScorePlacement) void {
    const grade_color = if (std.mem.eql(u8, score.grade, "XH") or std.mem.eql(u8, score.grade, "X")) log.yellow else if (std.mem.eql(u8, score.grade, "SH") or std.mem.eql(u8, score.grade, "S")) log.cyan else if (std.mem.eql(u8, score.grade, "A")) log.green else if (std.mem.eql(u8, score.grade, "B")) log.blue else log.red;
    std.debug.print("{s}  ┌─ SCORE {s} ────────────────────────────{s}\n", .{ if (score.passed) log.green else log.red, if (score.passed) "SUBMIT" else "FAIL", log.reset });
    std.debug.print("{s}  │ {s}►{s} user    : {s}{s}{s}\n", .{ if (score.passed) log.green else log.red, log.dim, log.reset, log.bold, user_name, log.reset });
    std.debug.print("{s}  │ {s}►{s} grade   : {s}{s}{s}{s}\n", .{ if (score.passed) log.green else log.red, log.dim, log.reset, grade_color, score.grade, log.bold, log.reset });
    std.debug.print("{s}  │ {s}►{s} pp      : {s}{d:.2}{s}\n", .{ if (score.passed) log.green else log.red, log.dim, log.reset, log.bold, pp_value, log.reset });
    if (placement) |p|
        std.debug.print("{s}  │ {s}►{s} map rank: #{d}\n", .{ if (score.passed) log.green else log.red, log.dim, log.reset, p.rank + 1 })
    else
        std.debug.print("{s}  │ {s}►{s} map rank: not on the board\n", .{ if (score.passed) log.green else log.red, log.dim, log.reset });
    std.debug.print("{s}  │ {s}►{s} combo   : {d}x\n", .{ if (score.passed) log.green else log.red, log.dim, log.reset, score.max_combo });
    std.debug.print("{s}  │ {s}►{s} acc     : {d:.2}%\n", .{ if (score.passed) log.green else log.red, log.dim, log.reset, score.accuracy() * 100.0 });
    std.debug.print("{s}  │ {s}►{s} score   : {d}\n", .{ if (score.passed) log.green else log.red, log.dim, log.reset, score.total_score });
    std.debug.print("{s}  │ {s}►{s} 300/100/50/miss : {d}/{d}/{d}/{d}\n", .{ if (score.passed) log.green else log.red, log.dim, log.reset, score.n300, score.n100, score.n50, score.nmiss });
    std.debug.print("{s}  └──────────────────────────────────────────────{s}\n", .{ if (score.passed) log.green else log.red, log.reset });
}

fn announceScore(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, user_name: []const u8, score: stable_score.Submission, pp_value: f64, placement: domain.ScorePlacement, info: storage.Store.BeatmapInfo) !void {
    var text_buf: [768]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buf, "{s} set #{d} on {s} - {s} [{s}] with {d:.2}pp ({d:.2}%)", .{ user_name, placement.rank + 1, info.artist, info.title, info.version, pp_value, score.accuracy() * 100.0 });
    try bancho.publishAnnouncement(allocator, sessions, text);
}

fn announceLazerScore(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, user_name: []const u8, score: lazer.ScoreInput, mods: []const u8, pp_value: f64, placement: domain.ScorePlacement, info: storage.Store.BeatmapInfo) !void {
    var text_buf: [896]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buf, "{s} set #{d} on {s} - {s} [{s}] with {d:.2}pp ({d:.2}%) [{s}] {s}", .{ user_name, placement.rank + 1, info.artist, info.title, info.version, pp_value, score.accuracy * 100.0, @tagName(score.namespace), mods });
    try store.recordPublicMessage(3, "#announce", text);
    try bancho.publishAnnouncement(allocator, sessions, text);
}

const App = struct {
    allocator: std.mem.Allocator,
    store: storage.Store,
    sessions: sessions_mod.Sessions,
    lazer_bot: lazer_bot.Manager,
    lazer_multiplayer: lazer_multiplayer.Manager,
    lazer_spectator: lazer_spectator.Manager,
    limiter: rate_limit.Limiter,
    map_sync: beatmap_sync.Sync,
    media_sync: beatmap_media.Sync,
    score_webhook: webhook.Webhook,
    anticheat: ?anticheat_plugin.Host,
    anticheat_allow_sample_modulus: u32,
    avatar_store: r2.Storage,
    avatar_cache: avatar_cache.Cache,
    geo_client: std.http.Client,
    started_at: i64,

    fn anticheatNamespace(mods: i32) u32 {
        if (mods & stable_mods.autopilot != 0) return anticheat_abi.Namespace.autopilot;
        if (mods & stable_mods.relax != 0) return anticheat_abi.Namespace.relax;
        if (mods & stable_mods.score_v2 != 0) return anticheat_abi.Namespace.score_v2;
        return anticheat_abi.Namespace.vanilla;
    }

    fn stableScoreEvidence(score: stable_score.Submission) u64 {
        const flags = stable_score.clientFlags(score.client_flags);
        var evidence: u64 = 0;
        if (flags & (1 << 1) != 0) evidence |= anticheat_abi.Evidence.rate_anomaly;
        if (flags & ((1 << 4) | (1 << 5)) != 0) evidence |= anticheat_abi.Evidence.checksum_mismatch;
        if (flags & ((1 << 8) | (1 << 9) | (1 << 11) | (1 << 12) | (1 << 13)) != 0) evidence |= anticheat_abi.Evidence.high_confidence_client_flag;
        return evidence;
    }

    fn stableGameplayEvidence(score: stable_score.Submission, replay_match_count: u32) u64 {
        return stableScoreEvidence(score) | (if (replay_match_count != 0) anticheat_abi.Evidence.replay_hash_reused else 0);
    }

    fn observeStableEvidence(self: *App, user_id: i32, source: storage.AnticheatSource, event: anticheat_abi.EventV1) void {
        const host = if (self.anticheat) |*loaded| loaded else return;
        const decision = host.evaluate(event) catch |err| {
            std.log.warn("event=anticheat_module_evaluation_failed module={s} source={s} user_id={d} error={t}", .{ host.name(), source.text(), user_id, err });
            return;
        };
        if (decision.action == anticheat_abi.Action.allow) return;
        _ = self.store.recordAnticheatObservation(user_id, .{
            .source = source,
            .module = host.name(),
            .action = decision.action,
            .reason = decision.reason,
            .risk_score = decision.risk_score,
            .confidence_bps = decision.confidence_bps,
            .evidence = event.evidence,
            .decision_flags = decision.flags,
            .rule_revision = decision.rule_revision,
        }) catch |err| {
            std.log.warn("event=anticheat_observation_write_failed source={s} user_id={d} error={t}", .{ source.text(), user_id, err });
        };
    }

    fn observeStableLogin(self: *App, result: bancho.LoginResult) void {
        if (result.user_id <= 0) return;
        var evidence: u64 = 0;
        if (result.hardware_match_count != 0) evidence |= anticheat_abi.Evidence.exact_hardware_match;
        if (result.running_under_wine) evidence |= anticheat_abi.Evidence.running_under_wine;
        self.observeStableEvidence(result.user_id, .stable_login, .{
            .event_kind = anticheat_abi.EventKind.login,
            .client_family = anticheat_abi.ClientFamily.stable,
            .evidence = evidence,
            .hardware_match_count = result.hardware_match_count,
        });
    }

    fn observeStableLastFmFlags(self: *App, user_id: i32, flags: u32) void {
        const hq_flags: u32 = (@as(u32, 1) << 17) | (@as(u32, 1) << 18);
        var evidence: u64 = 0;
        if (flags & hq_flags != 0) evidence |= anticheat_abi.Evidence.high_confidence_client_flag;
        if (flags & (@as(u32, 1) << 19) != 0) evidence |= anticheat_abi.Evidence.registry_remnant;
        if (evidence == 0) return;
        self.observeStableEvidence(user_id, .stable_lastfm, .{
            .event_kind = anticheat_abi.EventKind.heartbeat,
            .client_family = anticheat_abi.ClientFamily.stable,
            .evidence = evidence,
        });
    }

    fn observeStableGameplay(self: *App, user_id: i32, score: stable_score.Submission, replay: []const u8, map: []const u8, performance: pp.Output, elapsed_ms: u32, replay_match_count: u32) ?anticheat_abi.GameplayResultV1 {
        const host = if (self.anticheat) |*loaded| loaded else return null;
        if (score.mode != 0 or replay.len == 0) return null;
        var prepared = anticheat_replay.prepare(self.allocator, replay, map, @intCast(score.mods)) catch |err| {
            std.log.warn("event=anticheat_replay_parse_failed user_id={d} error={t}", .{ user_id, err });
            return null;
        };
        defer prepared.deinit();
        const passed_hits_i64 = @as(i64, score.n300) + @as(i64, score.n100) + @as(i64, score.n50);
        const accuracy_ppm: u32 = @intFromFloat(@round(@min(1.0, @max(0.0, score.accuracy())) * 1_000_000.0));
        const pp_milli: u64 = @intFromFloat(@round(@min(performance.pp * 1000.0, @as(f64, @floatFromInt(std.math.maxInt(u64))))));
        const event_flags = (if (score.passed) anticheat_abi.EventFlag.passed else 0) |
            (if (score.passed) anticheat_abi.EventFlag.replay_required else 0);
        const event: anticheat_abi.GameplayEventV1 = .{
            .base = .{
                .event_kind = anticheat_abi.EventKind.score,
                .client_family = anticheat_abi.ClientFamily.stable,
                .ruleset = score.mode,
                .namespace = anticheatNamespace(score.mods),
                .event_flags = event_flags,
                .evidence = stableGameplayEvidence(score, replay_match_count),
                .score = @intCast(score.total_score),
                .pp_milli = pp_milli,
                .accuracy_ppm = accuracy_ppm,
                .max_combo = @intCast(score.max_combo),
                .map_max_combo = performance.max_combo,
                .n300 = @intCast(score.n300),
                .n100 = @intCast(score.n100),
                .n50 = @intCast(score.n50),
                .nmiss = @intCast(score.nmiss),
                .ngeki = @intCast(score.ngeki),
                .nkatu = @intCast(score.nkatu),
                .map_objects = prepared.map_object_count,
                .elapsed_ms = elapsed_ms,
                .map_duration_ms = prepared.map_duration_ms,
                .replay_match_count = replay_match_count,
            },
            .mods = @intCast(score.mods),
            .passed_hits = @intCast(@min(passed_hits_i64, @as(i64, std.math.maxInt(u32)))),
            .hit_window_ms = prepared.hit_window_ms,
            .frames = prepared.frames.ptr,
            .frame_count = @intCast(prepared.frames.len),
            .objects = prepared.objects.ptr,
            .object_count = @intCast(prepared.objects.len),
        };
        const result = host.evaluateGameplay(event) catch |err| {
            std.log.warn("event=anticheat_module_evaluation_failed module={s} error={t}", .{ host.name(), err });
            return null;
        };
        if (result.decision.action != anticheat_abi.Action.allow) std.log.warn("event=anticheat_observation module={s} action={d} reason={d} risk={d} confidence_bps={d} objects={d} clicks={d}", .{
            host.name(), result.decision.action, result.decision.reason, result.decision.risk_score, result.decision.confidence_bps, result.objects_checked, result.matched_clicks,
        });
        return result;
    }

    fn persistAnticheatObservation(self: *App, user_id: i32, score_id: i64, sample_weight: u32, evidence: u64, replay_match_count: u32, result: anticheat_abi.GameplayResultV1) void {
        const host = if (self.anticheat) |*loaded| loaded else return;
        _ = self.store.recordAnticheatObservation(user_id, .{
            .source = .stable_score,
            .module = host.name(),
            .score_id = score_id,
            .action = result.decision.action,
            .sample_weight = sample_weight,
            .reason = result.decision.reason,
            .risk_score = result.decision.risk_score,
            .confidence_bps = result.decision.confidence_bps,
            .evidence = evidence,
            .decision_flags = result.decision.flags,
            .rule_revision = result.decision.rule_revision,
            .objects_checked = result.objects_checked,
            .matched_clicks = result.matched_clicks,
            .mean_abs_timing_error_milli = result.mean_abs_timing_error_milli,
            .timing_stddev_milli = result.timing_stddev_milli,
            .exact_timing_bps = result.exact_timing_bps,
            .center_hits_bps = result.center_hits_bps,
            .mean_center_distance_milli = result.mean_center_distance_milli,
            .snap_events = result.snap_events,
            .replay_match_count = replay_match_count,
            .key_press_count = result.key_press_count,
            .key_hold_count = result.key_hold_count,
            .mean_hold_duration_milli = result.mean_hold_duration_milli,
            .hold_duration_stddev_milli = result.hold_duration_stddev_milli,
            .alternation_bps = result.alternation_bps,
            .target_distance_stddev_milli = result.target_distance_stddev_milli,
            .velocity_spike_count = result.velocity_spike_count,
            .movement_velocity_stddev_milli = result.movement_velocity_stddev_milli,
        }) catch |err| {
            std.log.warn("event=anticheat_observation_write_failed score_id={d} error={t}", .{ score_id, err });
        };
    }

    fn header(req: *const std.http.Server.Request, wanted: []const u8) ?[]const u8 {
        var it = req.iterateHeaders();
        while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, wanted)) return h.value;
        return null;
    }

    fn respond(req: *std.http.Server.Request, status: std.http.Status, content_type: []const u8, body: []const u8, headers: []const std.http.Header) !void {
        var all: [8]std.http.Header = undefined;
        all[0] = .{ .name = "content-type", .value = content_type };
        if (headers.len > all.len - 1) return error.TooManyHeaders;
        @memcpy(all[1..][0..headers.len], headers);
        try req.respond(body, .{ .status = status, .extra_headers = all[0 .. headers.len + 1], .keep_alive = false });
    }

    const GeoResult = struct { lon: f32, lat: f32 };

    fn lookupGeo(self: *App, ip: []const u8) GeoResult {
        const url = std.fmt.allocPrint(self.allocator, "http://ip-api.com/line/{s}?fields=status,lat,lon", .{ip}) catch return .{ .lon = 0, .lat = 0 };
        defer self.allocator.free(url);
        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const result = self.geo_client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &writer,
            .headers = .{
                .user_agent = .{ .override = "zigcho/0.1" },
            },
        }) catch return .{ .lon = 0, .lat = 0 };
        if (result.status != .ok) return .{ .lon = 0, .lat = 0 };
        const body_str = buf[0..writer.end];
        var lines = std.mem.splitScalar(u8, body_str, '\n');
        const status = std.mem.trim(u8, lines.next() orelse "", "\r ");
        if (!std.mem.eql(u8, status, "success")) return .{ .lon = 0, .lat = 0 };
        const lat_str = std.mem.trim(u8, lines.next() orelse "0", "\r ");
        const lon_str = std.mem.trim(u8, lines.next() orelse "0", "\r ");
        const lat = std.fmt.parseFloat(f32, lat_str) catch 0;
        const lon = std.fmt.parseFloat(f32, lon_str) catch 0;
        std.debug.print("{s}  ┌─ GEOLOCATION ──────────────────────────────────{s}\n", .{ log.blue, log.reset });
        std.debug.print("{s}  │ {s}►{s} ip  : {s}{s}\n", .{ log.blue, log.dim, log.reset, ip, log.reset });
        std.debug.print("{s}  │ {s}✓{s} lat : {d:.4}  lon : {d:.4}{s}\n", .{ log.blue, log.green, log.reset, lat, lon, log.reset });
        std.debug.print("{s}  └──────────────────────────────────────────────{s}\n", .{ log.blue, log.reset });
        return .{ .lon = lon, .lat = lat };
    }

    fn rejectStableScore(req: *std.http.Server.Request, reason: []const u8, body_len: usize) !void {
        std.log.warn("stable score rejected: reason={s} body_bytes={d}", .{ reason, body_len });
        return respond(req, .bad_request, "text/plain", "error: no", &.{});
    }

    fn rejectStableScoreError(req: *std.http.Server.Request, reason: []const u8, err: anyerror, body_len: usize) !void {
        std.log.warn("stable score rejected: reason={s} error={t} body_bytes={d}", .{ reason, err, body_len });
        return respond(req, .bad_request, "text/plain", "error: no", &.{});
    }

    fn field(body: []const u8, key: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, body, '&');
        while (it.next()) |part| {
            const eq = std.mem.findScalar(u8, part, '=') orelse continue;
            if (std.mem.eql(u8, part[0..eq], key)) return part[eq + 1 ..];
        }
        return null;
    }

    fn queryField(target: []const u8, key: []const u8) ?[]const u8 {
        const query_start = std.mem.findScalar(u8, target, '?') orelse return null;
        return field(target[query_start + 1 ..], key);
    }

    fn lazerRulesetId(name: []const u8) ?u8 {
        if (std.mem.eql(u8, name, "osu")) return 0;
        if (std.mem.eql(u8, name, "taiko")) return 1;
        if (std.mem.eql(u8, name, "fruits")) return 2;
        if (std.mem.eql(u8, name, "mania")) return 3;
        return null;
    }

    fn lazerLeaderboardNamespace(target: []const u8) lazer.Namespace {
        const query_start = std.mem.findScalar(u8, target, '?') orelse return .vanilla;
        var relax = false;
        var autopilot = false;
        var custom = false;
        var parameters = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
        while (parameters.next()) |parameter| {
            const equals = std.mem.findScalar(u8, parameter, '=') orelse continue;
            const key = parameter[0..equals];
            if (!std.mem.eql(u8, key, "mods[]") and !std.ascii.eqlIgnoreCase(key, "mods%5B%5D")) continue;
            const acronym = parameter[equals + 1 ..];
            if (std.ascii.eqlIgnoreCase(acronym, "RX")) {
                relax = true;
            } else if (std.ascii.eqlIgnoreCase(acronym, "AP")) {
                autopilot = true;
            } else if (!std.ascii.eqlIgnoreCase(acronym, "NM") and lazer.validAcronym(acronym) and !lazer.isOfficial(acronym)) {
                custom = true;
            }
        }
        return if (custom) .custom else if (autopilot) .autopilot else if (relax) .relax else .vanilla;
    }

    fn isAvatarHost(value: ?[]const u8) bool {
        const host = value orelse return false;
        const end = std.mem.findScalar(u8, host, ':') orelse host.len;
        return std.ascii.eqlIgnoreCase(host[0..end], "a.kai.ovh");
    }

    fn isLocalMetricsHost(value: ?[]const u8) bool {
        const raw = value orelse return false;
        const host = if (raw.len > 0 and raw[0] == '[') raw else if (std.mem.findScalar(u8, raw, ':')) |colon| raw[0..colon] else raw;
        return std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "127.0.0.1") or std.mem.startsWith(u8, host, "[::1]");
    }

    fn avatarUserId(path: []const u8) ?i32 {
        const value = if (std.mem.startsWith(u8, path, "/avatars/"))
            path["/avatars/".len..]
        else if (std.mem.startsWith(u8, path, "/avatar/"))
            path["/avatar/".len..]
        else if (path.len > 1)
            path[1..]
        else
            return null;
        if (value.len == 0) return null;
        return std.fmt.parseInt(i32, value, 10) catch null;
    }

    fn userOnline(self: *App, user_id: i32) bool {
        self.sessions.mutex.lockUncancelable(self.sessions.io);
        defer self.sessions.mutex.unlock(self.sessions.io);
        return self.sessions.byUser(user_id) != null;
    }

    fn afterLazerScore(self: *App, user: domain.User, score_id: i64, score: lazer.ScoreInput, pp_value: f64, mods_json: []const u8) ?domain.ScorePlacement {
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

    fn lazerScoreResponse(self: *App, user_id: i32, score_id: i64, placement: ?domain.ScorePlacement) ![]u8 {
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

    fn broadcastLazerChatToStable(self: *App, user: domain.User, target: []const u8, message: []const u8) !void {
        if (lazer.channelId(target) == null) return;
        var packet = protocol.Writer.init(self.allocator);
        defer packet.deinit();
        try protocol.writeMessage(&packet, user.name, message, target, user.id);
        self.sessions.mutex.lockUncancelable(self.sessions.io);
        defer self.sessions.mutex.unlock(self.sessions.io);
        try self.sessions.broadcastChannel(target, packet.bytes(), null);
    }

    fn lazerUser(self: *App, authorization: ?[]const u8, scope: []const u8) !?domain.User {
        const value = authorization orelse return null;
        if (!std.mem.startsWith(u8, value, "Bearer ")) return null;
        return self.store.authenticateToken(self.allocator, value["Bearer ".len..], scope);
    }

    fn lazerStats(self: *App, user_id: i32) ![4]?domain.Stats {
        var stats: [4]?domain.Stats = .{ null, null, null, null };
        for (0..stats.len) |mode| stats[mode] = try self.store.statsForUser(user_id, @intCast(mode));
        return stats;
    }

    fn lazerPresenceJson(self: *App, requester_id: i32) ![]u8 {
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
            try output.writer.print("{{\"user_id\":{d}}}", .{id});
        }
        try output.writer.writeByte(']');
        return output.toOwnedSlice();
    }

    fn recordLazerBotReply(self: *App, user: domain.User, content: []const u8, is_action: bool) void {
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
    }

    fn friendRelationsJson(self: *App, user_id: i32) ![]u8 {
        const ids = try self.store.friendIds(self.allocator, user_id);
        defer self.allocator.free(ids);
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        try output.writer.writeByte('[');
        var written: usize = 0;
        for (ids) |id| {
            const target_user = (try self.store.userById(self.allocator, id)) orelse continue;
            defer freeUser(self.allocator, target_user);
            if (written != 0) try output.writer.writeByte(',');
            written += 1;
            try output.writer.print("{{\"target_id\":{d},\"relation_type\":\"friend\",\"mutual\":{s},\"target\":", .{ id, if (try self.store.friendsAreMutual(user_id, id)) "true" else "false" });
            try user_json.writeCompact(&output.writer, target_user);
            try output.writer.writeByte('}');
        }
        try output.writer.writeByte(']');
        return output.toOwnedSlice();
    }

    fn blockRelationsJson(self: *App, user_id: i32) ![]u8 {
        const ids = try self.store.blockIds(self.allocator, user_id);
        defer self.allocator.free(ids);
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        try output.writer.writeByte('[');
        var written: usize = 0;
        for (ids) |id| {
            const target_user = (try self.store.userById(self.allocator, id)) orelse continue;
            defer freeUser(self.allocator, target_user);
            if (written != 0) try output.writer.writeByte(',');
            written += 1;
            try output.writer.print("{{\"target_id\":{d},\"relation_type\":\"block\",\"mutual\":false,\"target\":", .{id});
            try user_json.writeCompact(&output.writer, target_user);
            try output.writer.writeByte('}');
        }
        try output.writer.writeByte(']');
        return output.toOwnedSlice();
    }

    fn friendMutationJson(self: *App, user_id: i32, target: domain.User) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        try output.writer.print("{{\"user_relation\":{{\"target_id\":{d},\"relation_type\":\"friend\",\"mutual\":{s},\"target\":", .{ target.id, if (try self.store.friendsAreMutual(user_id, target.id)) "true" else "false" });
        try user_json.writeCompact(&output.writer, target);
        try output.writer.writeAll("}}");
        return output.toOwnedSlice();
    }

    fn favouriteSetsJson(self: *App, user_id: i32) ![]u8 {
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

    fn requestRule(req: *const std.http.Server.Request, path: []const u8) ?rate_limit.Rule {
        if (req.head.method == .POST and std.mem.eql(u8, path, "/users")) return rate_limit.registration;
        if (req.head.method == .POST and (std.mem.eql(u8, path, "/oauth/token") or std.mem.eql(u8, path, "/oauth/revoke"))) return rate_limit.token;
        if (req.head.method == .POST and std.mem.eql(u8, path, "/api/v1/staff/session")) return rate_limit.web_session;
        if (req.head.method == .POST and std.mem.eql(u8, path, "/api/v1/session")) return rate_limit.web_session;
        if ((req.head.method == .POST and std.mem.eql(u8, path, "/api/v1/account")) or ((req.head.method == .PUT or req.head.method == .DELETE) and std.mem.eql(u8, path, "/api/v1/account/avatar"))) return rate_limit.web_action;
        if (req.head.method == .POST and std.mem.startsWith(u8, path, "/api/v1/staff/")) return rate_limit.web_action;
        if (req.head.method == .POST and std.mem.eql(u8, path, "/api/v1/appeals")) return rate_limit.appeal;
        if (req.head.method == .POST and std.mem.eql(u8, path, "/api/v2/scores")) return rate_limit.score;
        if ((req.head.method == .POST or req.head.method == .PUT) and lazer.parseSoloScorePath(path) != null) return rate_limit.score;
        if ((req.head.method == .POST or req.head.method == .PUT) and lazer_multiplayer.parseRoomScorePath(path) != null) return rate_limit.score;
        if (std.mem.eql(u8, path, "/multiplayer") or std.mem.eql(u8, path, "/multiplayer/negotiate") or std.mem.eql(u8, path, "/spectator") or std.mem.eql(u8, path, "/spectator/negotiate") or std.mem.eql(u8, path, "/api/v2/rooms") or lazer_multiplayer.parseRoomPath(path) != null) return rate_limit.authenticated;
        if (req.head.method == .POST and std.mem.eql(u8, path, "/web/osu-submit-modular-selector.php")) return rate_limit.score;
        if (req.head.method == .POST and std.mem.eql(u8, path, "/web/osu-screenshot.php")) return rate_limit.media_upload;
        if (req.head.method == .GET and (std.mem.eql(u8, path, "/web/osu-getfriends.php") or std.mem.eql(u8, path, "/web/osu-getfavourites.php") or std.mem.eql(u8, path, "/web/osu-addfavourite.php"))) return rate_limit.authenticated;
        if (req.head.method == .GET and routing.lazerBeatmapMetadata(path)) return rate_limit.beatmap_metadata;
        if (req.head.method == .GET and (std.mem.startsWith(u8, path, "/d/") or std.mem.startsWith(u8, path, "/ss/") or std.mem.startsWith(u8, path, "/replays/") or std.mem.startsWith(u8, path, "/beatmaps/") or std.mem.startsWith(u8, path, "/preview/") or std.mem.startsWith(u8, path, "/thumb/") or lazer.parseScoreDownloadPath(path) != null or (std.mem.startsWith(u8, path, "/api/v2/beatmapsets/") and std.mem.endsWith(u8, path, "/download")))) return rate_limit.download;
        if (req.head.method == .POST and std.mem.eql(u8, path, "/")) {
            return if (header(req, "osu-token") == null) rate_limit.login else rate_limit.authenticated;
        }
        if (std.mem.eql(u8, path, "/api/v2/me") or std.mem.eql(u8, path, "/api/v2/notifications") or std.mem.startsWith(u8, path, "/api/v2/friends") or std.mem.startsWith(u8, path, "/api/v2/blocks") or std.mem.eql(u8, path, "/api/v2/me/beatmapset-favourites") or lazer.parseFavouritePath(path) != null or std.mem.startsWith(u8, path, "/api/v2/chat/") or std.mem.eql(u8, path, "/api/v2/users") or std.mem.startsWith(u8, path, "/api/v2/users/") or std.mem.eql(u8, path, "/web/osu-osz2-getscores.php") or std.mem.eql(u8, path, "/web/osu-getreplay.php") or std.mem.eql(u8, path, "/web/osu-search.php") or std.mem.eql(u8, path, "/web/osu-search-set.php") or std.mem.eql(u8, path, "/web/osu-rate.php") or std.mem.eql(u8, path, "/web/lastfm.php") or std.mem.eql(u8, path, "/web/osu-getbeatmapinfo.php") or std.mem.eql(u8, path, "/web/osu-comment.php") or std.mem.eql(u8, path, "/web/osu-markasread.php")) return rate_limit.authenticated;
        return null;
    }

    fn bodyLimit(path: []const u8) usize {
        if (std.mem.eql(u8, path, "/api/v1/account/avatar")) return profile_avatar.max_bytes;
        if (std.mem.eql(u8, path, "/users") or std.mem.eql(u8, path, "/oauth/token") or std.mem.eql(u8, path, "/oauth/revoke") or std.mem.eql(u8, path, "/api/v1/session") or std.mem.eql(u8, path, "/api/v1/account") or std.mem.eql(u8, path, "/api/v1/staff/session") or std.mem.eql(u8, path, "/api/v1/appeals") or std.mem.startsWith(u8, path, "/api/v1/staff/")) return 8 * 1024;
        if (std.mem.eql(u8, path, "/api/v2/scores")) return 1024 * 1024;
        if (lazer.parseSoloScorePath(path) != null) return lazer.max_score_body_bytes;
        if (lazer_multiplayer.parseRoomScorePath(path) != null) return lazer.max_score_body_bytes;
        if (std.mem.eql(u8, path, "/web/osu-submit-modular-selector.php")) return 20 * 1024 * 1024;
        if (std.mem.eql(u8, path, "/web/osu-getbeatmapinfo.php")) return 32 * 1024 * 1024;
        if (std.mem.eql(u8, path, "/web/osu-screenshot.php")) return screenshot.max_bytes + 256 * 1024;
        if (std.mem.eql(u8, path, "/")) return 1024 * 1024;
        return 64 * 1024;
    }

    fn serve(self: *App, req: *std.http.Server.Request, peer_ip: ?[]const u8) !void {
        const target = try self.allocator.dupe(u8, req.head.target);
        defer self.allocator.free(target);
        const raw_path = if (std.mem.findScalar(u8, target, '?')) |q| target[0..q] else target;
        const path = routing.canonicalPath(raw_path);
        const trusted_proxy = proxy.trustsForwardedHeaders(peer_ip);
        if (requestRule(req, path)) |rule| {
            const client = proxy.clientKey(peer_ip, trusted_proxy, header(req, "cf-connecting-ip"), header(req, "x-forwarded-for"), header(req, "x-real-ip"));
            const decision = self.limiter.check(client, rule) catch return respond(req, .service_unavailable, "application/json", "{\"error\":\"rate limiter unavailable\"}", &.{});
            if (!decision.allowed) {
                var retry_buf: [16]u8 = undefined;
                var limit_buf: [16]u8 = undefined;
                const retry = try std.fmt.bufPrint(&retry_buf, "{d}", .{decision.retry_after});
                const limit = try std.fmt.bufPrint(&limit_buf, "{d}", .{decision.limit});
                const headers = [_]std.http.Header{
                    .{ .name = "retry-after", .value = retry },
                    .{ .name = "x-ratelimit-limit", .value = limit },
                    .{ .name = "x-ratelimit-remaining", .value = "0" },
                };
                return respond(req, .too_many_requests, "application/json", "{\"error\":\"rate limit exceeded\"}", &headers);
            }
        }
        const auth_owned: ?[]u8 = if (header(req, "authorization")) |v| try self.allocator.dupe(u8, v) else null;
        defer if (auth_owned) |v| self.allocator.free(v);
        const osu_token_owned: ?[]u8 = if (header(req, "osu-token")) |v| try self.allocator.dupe(u8, v) else null;
        defer if (osu_token_owned) |v| self.allocator.free(v);
        const score_token_owned: ?[]u8 = if (header(req, "token")) |v| try self.allocator.dupe(u8, v) else null;
        defer if (score_token_owned) |v| self.allocator.free(v);
        const content_type_owned: ?[]u8 = if (req.head.content_type) |v| try self.allocator.dupe(u8, v) else null;
        defer if (content_type_owned) |v| self.allocator.free(v);
        const country_owned: ?[]u8 = if (proxy.countryHeader(trusted_proxy, header(req, "cf-ipcountry"))) |v| try self.allocator.dupe(u8, v) else null;
        defer if (country_owned) |v| self.allocator.free(v);
        const host_owned: ?[]u8 = if (header(req, "host")) |v| try self.allocator.dupe(u8, v) else null;
        defer if (host_owned) |v| self.allocator.free(v);
        const cookie_owned: ?[]u8 = if (header(req, "cookie")) |v| try self.allocator.dupe(u8, v) else null;
        defer if (cookie_owned) |v| self.allocator.free(v);
        const csrf_owned: ?[]u8 = if (header(req, "x-csrf-token")) |v| try self.allocator.dupe(u8, v) else null;
        defer if (csrf_owned) |v| self.allocator.free(v);
        const origin_owned: ?[]u8 = if (header(req, "origin")) |v| try self.allocator.dupe(u8, v) else null;
        defer if (origin_owned) |v| self.allocator.free(v);
        const client_ip_owned: ?[]u8 = if (proxy.clientIp(peer_ip, trusted_proxy, header(req, "cf-connecting-ip"), header(req, "x-forwarded-for"), header(req, "x-real-ip"))) |v| try self.allocator.dupe(u8, v) else null;
        defer if (client_ip_owned) |v| self.allocator.free(v);
        if ((req.head.method == .GET or req.head.method == .HEAD) and web_auth.protocolHost(host_owned) and routing.websitePage(path)) {
            const location = try std.fmt.allocPrint(self.allocator, "https://kai.ovh{s}", .{target});
            defer self.allocator.free(location);
            return respond(req, .permanent_redirect, "text/plain", "", &.{.{ .name = "location", .value = location }});
        }
        if (std.mem.eql(u8, path, "/multiplayer/negotiate")) {
            if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"authentication required\"}", &.{});
            defer freeUser(self.allocator, user);
            if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"account restricted\"}", &.{});
            const json = try lazer_multiplayer.negotiateJson(self.allocator, self.store.io);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &.{.{ .name = "cache-control", .value = "no-store" }});
        }
        if (std.mem.eql(u8, path, "/multiplayer")) {
            if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"authentication required\"}", &.{});
            defer freeUser(self.allocator, user);
            if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"account restricted\"}", &.{});
            const key = switch (req.upgradeRequested()) {
                .websocket => |maybe_key| maybe_key orelse return respond(req, .bad_request, "application/json", "{\"error\":\"websocket key required\"}", &.{}),
                else => return respond(req, .bad_request, "application/json", "{\"error\":\"websocket upgrade required\"}", &.{}),
            };
            var socket = try req.respondWebSocket(.{ .key = key });
            try socket.flush();
            self.lazer_multiplayer.serve(user, &socket) catch |err| {
                std.log.info("event=lazer_multiplayer_connection_closed user_id={d} error={t}", .{ user.id, err });
            };
            return;
        }
        if (std.mem.eql(u8, path, "/spectator/negotiate")) {
            if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"authentication required\"}", &.{});
            defer freeUser(self.allocator, user);
            if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"account restricted\"}", &.{});
            const json = try lazer_multiplayer.negotiateJson(self.allocator, self.store.io);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &.{.{ .name = "cache-control", .value = "no-store" }});
        }
        if (std.mem.eql(u8, path, "/spectator")) {
            if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"authentication required\"}", &.{});
            defer freeUser(self.allocator, user);
            if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"account restricted\"}", &.{});
            const key = switch (req.upgradeRequested()) {
                .websocket => |maybe_key| maybe_key orelse return respond(req, .bad_request, "application/json", "{\"error\":\"websocket key required\"}", &.{}),
                else => return respond(req, .bad_request, "application/json", "{\"error\":\"websocket upgrade required\"}", &.{}),
            };
            var socket = try req.respondWebSocket(.{ .key = key });
            try socket.flush();
            self.lazer_spectator.serve(user, &socket) catch |err| {
                std.log.info("event=lazer_spectator_connection_closed user_id={d} error={t}", .{ user.id, err });
            };
            return;
        }
        if (std.mem.eql(u8, path, "/api/v2/rooms") or lazer_multiplayer.parseRoomPath(path) != null) {
            if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"authentication required\"}", &.{});
            defer freeUser(self.allocator, user);
            if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"account restricted\"}", &.{});
            const room_id = lazer_multiplayer.parseRoomPath(path);
            const json = (try self.lazer_multiplayer.roomsJson(self.allocator, room_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"room not found\"}", &.{});
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &.{.{ .name = "cache-control", .value = "no-store" }});
        }
        const body_is_framed = req.head.content_length != null or req.head.transfer_encoding != .none;
        const body: []u8 = if (req.head.method.requestHasBody() and body_is_framed) b: {
            const r = req.readerExpectContinue(&.{}) catch return error.BadBody;
            break :b r.allocRemaining(self.allocator, .limited(bodyLimit(path))) catch |err| switch (err) {
                error.StreamTooLong => return respond(req, .payload_too_large, "application/json", "{\"error\":\"request body too large\"}", &.{}),
                else => return err,
            };
        } else &.{};
        defer if (body.len > 0) self.allocator.free(body);

        if (std.mem.eql(u8, path, "/health")) {
            self.sessions.mutex.lockUncancelable(self.sessions.io);
            defer self.sessions.mutex.unlock(self.sessions.io);
            var buf: [256]u8 = undefined;
            const json = try std.fmt.bufPrint(&buf, "{{\"ok\":true,\"service\":\"zigcho\",\"online\":{d},\"protocol\":19}}", .{self.sessions.humanCount()});
            return respond(req, .ok, "application/json", json, &.{});
        }
        if (std.mem.eql(u8, path, "/metrics")) {
            if (req.head.method != .GET or !isLocalMetricsHost(host_owned)) return respond(req, .not_found, "text/plain", "not found\n", &.{});
            self.sessions.mutex.lockUncancelable(self.sessions.io);
            const online = self.sessions.humanCount();
            self.sessions.mutex.unlock(self.sessions.io);
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
                    "# TYPE zigcho_beatmap_media_fetch_attempts counter\nzigcho_beatmap_media_fetch_attempts {d}\n" ++
                    "# TYPE zigcho_beatmap_media_fetch_successes counter\nzigcho_beatmap_media_fetch_successes {d}\n" ++
                    "# TYPE zigcho_beatmap_media_fetch_failures counter\nzigcho_beatmap_media_fetch_failures {d}\n" ++
                    "# TYPE zigcho_beatmap_media_cache_pruned_entries counter\nzigcho_beatmap_media_cache_pruned_entries {d}\n" ++
                    "# TYPE zigcho_beatmap_media_cache_pruned_bytes counter\nzigcho_beatmap_media_cache_pruned_bytes {d}\n" ++
                    "# TYPE zigcho_uptime_seconds counter\nzigcho_uptime_seconds {d}\n",
                .{ online, counts.users, counts.plays, counts.passed, counts.maps, cache.entries, cache.bytes, media_cache.entries, media_cache.bytes, cache.hydration_failures, hydration.attempts, hydration.successes, hydration.failures, hydration.backoff_skips, hydration.capacity_skips, hydration.pruned_entries, hydration.pruned_bytes, media.attempts, media.successes, media.failures, media.pruned_entries, media.pruned_bytes, uptime },
            );
            return respond(req, .ok, "text/plain; version=0.0.4; charset=utf-8", output.written(), &.{.{ .name = "cache-control", .value = "no-store" }});
        }
        if (std.mem.eql(u8, path, "/api/v1/status")) {
            self.sessions.mutex.lockUncancelable(self.sessions.io);
            const online = self.sessions.humanCount();
            self.sessions.mutex.unlock(self.sessions.io);
            const counts = try self.store.serverCounts();
            var buf: [384]u8 = undefined;
            const json = try std.fmt.bufPrint(&buf, "{{\"ok\":true,\"service\":\"zigcho\",\"stage\":\"stable\",\"online\":{d},\"users\":{d},\"plays\":{d},\"passed\":{d},\"maps\":{d},\"protocol\":19}}", .{ online, counts.users, counts.plays, counts.passed, counts.maps });
            return respond(req, .ok, "application/json", json, &.{});
        }
        if (std.mem.eql(u8, path, "/api/v1/appeals")) {
            const no_store = [_]std.http.Header{
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "pragma", .value = "no-cache" },
            };
            if (!web_auth.websiteHost(host_owned)) return respond(req, .not_found, "application/json", "{\"error\":\"not found\"}", &no_store);
            if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &no_store);
            if (!web_auth.sameOrigin(origin_owned, host_owned)) return respond(req, .forbidden, "application/json", "{\"error\":\"invalid origin\"}", &no_store);
            const name = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"username"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"username required\"}", &no_store);
            defer self.allocator.free(name);
            const password = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"password"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"password required\"}", &no_store);
            defer self.allocator.free(password);
            const kind = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"kind"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"appeal kind required\"}", &no_store);
            defer self.allocator.free(kind);
            const message = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"message"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"appeal message required\"}", &no_store);
            defer self.allocator.free(message);
            if ((!std.mem.eql(u8, kind, "restriction") and !std.mem.eql(u8, kind, "hwid")) or !validWebText(message, 20, 2000)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid appeal\"}", &no_store);
            const password_md5 = web_auth.passwordCredential(password) catch return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid credentials\"}", &no_store);
            const user = (try self.store.authenticate(self.allocator, name, &password_md5)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid credentials\"}", &no_store);
            defer freeUser(self.allocator, user);
            if (!user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"this account is not restricted\"}", &no_store);
            const appeal_id = self.store.createModerationAppeal(user.id, kind, std.mem.trim(u8, message, " \t\r\n")) catch |err| return respond(req, if (err == error.AppealAlreadyOpen) .conflict else .internal_server_error, "application/json", if (err == error.AppealAlreadyOpen) "{\"error\":\"an appeal of this type is already open\"}" else "{\"error\":\"appeal could not be saved\"}", &no_store);
            std.log.info("event=appeal_submitted appeal_id={d} user_id={d} kind={s}", .{ appeal_id, user.id, kind });
            var response_buf: [64]u8 = undefined;
            const response_json = try std.fmt.bufPrint(&response_buf, "{{\"ok\":true,\"id\":{d}}}", .{appeal_id});
            return respond(req, .created, "application/json", response_json, &no_store);
        }
        if (std.mem.eql(u8, path, "/api/v1/session")) {
            const no_store = [_]std.http.Header{
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "pragma", .value = "no-cache" },
            };
            if (!web_auth.websiteHost(host_owned)) return respond(req, .not_found, "application/json", "{\"error\":\"not found\"}", &no_store);
            if (req.head.method == .POST) {
                if (!web_auth.sameOrigin(origin_owned, host_owned)) return respond(req, .forbidden, "application/json", "{\"error\":\"invalid origin\"}", &no_store);
                const name = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"username"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"username required\"}", &no_store);
                defer self.allocator.free(name);
                const password = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"password"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"password required\"}", &no_store);
                defer self.allocator.free(password);
                const password_md5 = web_auth.passwordCredential(password) catch return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid credentials\"}", &no_store);
                const user = (try self.store.authenticate(self.allocator, name, &password_md5)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid credentials\"}", &no_store);
                defer freeUser(self.allocator, user);
                if (user.id == 3) return respond(req, .forbidden, "application/json", "{\"error\":\"account login unavailable\"}", &no_store);
                const token = try self.store.issueToken(user.id, web_auth.player_scope, web_auth.player_lifetime_seconds);
                const csrf = web_auth.csrfToken(&token);
                const json = try web_auth.sessionJson(self.allocator, user, csrf);
                defer self.allocator.free(json);
                var cookie_buf: [256]u8 = undefined;
                const cookie = try std.fmt.bufPrint(&cookie_buf, "{s}={s}; Path=/; Max-Age={d}; Secure; HttpOnly; SameSite=Strict", .{ web_auth.player_cookie_name, &token, web_auth.player_lifetime_seconds });
                std.log.info("event=website_session_created user_id={d}", .{user.id});
                return respond(req, .ok, "application/json", json, &.{
                    .{ .name = "set-cookie", .value = cookie },
                    .{ .name = "cache-control", .value = "no-store" },
                    .{ .name = "pragma", .value = "no-cache" },
                });
            }
            const token = web_auth.playerSessionToken(cookie_owned) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
            if (req.head.method == .GET) {
                const user = (try self.store.authenticateToken(self.allocator, token, web_auth.player_scope)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
                defer freeUser(self.allocator, user);
                const csrf = web_auth.csrfToken(token);
                const json = try web_auth.sessionJson(self.allocator, user, csrf);
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &no_store);
            }
            if (req.head.method == .DELETE) {
                if (!web_auth.sameOrigin(origin_owned, host_owned) or !web_auth.csrfMatches(token, csrf_owned)) return respond(req, .forbidden, "application/json", "{\"error\":\"invalid request\"}", &no_store);
                _ = try self.store.revokeToken(token);
                return respond(req, .no_content, "application/json", "", &.{
                    .{ .name = "set-cookie", .value = "__Host-kai-account=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict" },
                    .{ .name = "cache-control", .value = "no-store" },
                    .{ .name = "pragma", .value = "no-cache" },
                });
            }
            return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &no_store);
        }
        if (std.mem.eql(u8, path, "/api/v1/account") or std.mem.eql(u8, path, "/api/v1/account/avatar")) {
            const no_store = [_]std.http.Header{
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "pragma", .value = "no-cache" },
            };
            if (!web_auth.websiteHost(host_owned)) return respond(req, .not_found, "application/json", "{\"error\":\"not found\"}", &no_store);
            const token = web_auth.playerSessionToken(cookie_owned) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
            const user = (try self.store.authenticateToken(self.allocator, token, web_auth.player_scope)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
            defer freeUser(self.allocator, user);
            if (std.mem.eql(u8, path, "/api/v1/account")) {
                if (req.head.method == .GET) {
                    const json = (try self.store.siteAccountJson(self.allocator, user.id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"account not found\"}", &no_store);
                    defer self.allocator.free(json);
                    return respond(req, .ok, "application/json", json, &no_store);
                }
                if (req.head.method == .POST) {
                    if (!web_auth.sameOrigin(origin_owned, host_owned) or !web_auth.csrfMatches(token, csrf_owned)) return respond(req, .forbidden, "application/json", "{\"error\":\"invalid request\"}", &no_store);
                    const bio_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"bio"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"bio required\"}", &no_store);
                    defer self.allocator.free(bio_value);
                    const title_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"profile_title"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"profile title required\"}", &no_store);
                    defer self.allocator.free(title_value);
                    const pronouns_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"profile_pronouns"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"pronouns required\"}", &no_store);
                    defer self.allocator.free(pronouns_value);
                    const location_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"profile_location"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"location required\"}", &no_store);
                    defer self.allocator.free(location_value);
                    const website_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"profile_website"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"website required\"}", &no_store);
                    defer self.allocator.free(website_value);
                    const accent_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"profile_accent"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"accent required\"}", &no_store);
                    defer self.allocator.free(accent_value);
                    const mode_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"preferred_mode"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"main mode required\"}", &no_store);
                    defer self.allocator.free(mode_value);
                    const source_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"profile_source"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"score view required\"}", &no_store);
                    defer self.allocator.free(source_value);
                    const avatar_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"avatar_key"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"default avatar required\"}", &no_store);
                    defer self.allocator.free(avatar_value);
                    const show_country_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"show_country"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"country privacy required\"}", &no_store);
                    defer self.allocator.free(show_country_value);
                    const show_stats_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"show_profile_stats"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"stats privacy required\"}", &no_store);
                    defer self.allocator.free(show_stats_value);
                    const show_recent_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"show_recent_scores"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"recent plays privacy required\"}", &no_store);
                    defer self.allocator.free(show_recent_value);
                    const bio = std.mem.trim(u8, bio_value, " \t\r\n");
                    const profile_title = std.mem.trim(u8, title_value, " \t\r\n");
                    const profile_pronouns = std.mem.trim(u8, pronouns_value, " \t\r\n");
                    const profile_location = std.mem.trim(u8, location_value, " \t\r\n");
                    const profile_website = std.mem.trim(u8, website_value, " \t\r\n");
                    const profile_accent = domain.parseProfileAccent(accent_value) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid profile accent\"}", &no_store);
                    const preferred_mode = std.fmt.parseInt(u8, mode_value, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid main mode\"}", &no_store);
                    const profile_source = domain.parseSiteScoreSource(source_value) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid score view\"}", &no_store);
                    const avatar_key = std.fmt.parseInt(u8, avatar_value, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid default avatar\"}", &no_store);
                    const show_country = std.mem.eql(u8, show_country_value, "1");
                    const show_profile_stats = std.mem.eql(u8, show_stats_value, "1");
                    const show_recent_scores = std.mem.eql(u8, show_recent_value, "1");
                    if ((!show_country and !std.mem.eql(u8, show_country_value, "0")) or (!show_profile_stats and !std.mem.eql(u8, show_stats_value, "0")) or (!show_recent_scores and !std.mem.eql(u8, show_recent_value, "0")) or !validWebText(bio, 0, 500) or !validWebLine(profile_title, 40) or !validWebLine(profile_pronouns, 32) or !validWebLine(profile_location, 60) or !validProfileWebsite(profile_website) or preferred_mode > 3 or (avatar_key != 1 and avatar_key != 2)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid profile settings\"}", &no_store);
                    try self.store.updateSiteProfile(user.id, .{ .bio = bio, .title = profile_title, .pronouns = profile_pronouns, .location = profile_location, .website = profile_website, .accent = profile_accent, .preferred_mode = preferred_mode, .profile_source = profile_source, .avatar_key = avatar_key, .show_country = show_country, .show_profile_stats = show_profile_stats, .show_recent_scores = show_recent_scores });
                    const json = (try self.store.siteAccountJson(self.allocator, user.id)).?;
                    defer self.allocator.free(json);
                    std.log.info("event=website_profile_updated user_id={d}", .{user.id});
                    return respond(req, .ok, "application/json", json, &no_store);
                }
                return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &no_store);
            }
            if ((req.head.method != .PUT and req.head.method != .DELETE) or !web_auth.sameOrigin(origin_owned, host_owned) or !web_auth.csrfMatches(token, csrf_owned)) return respond(req, if (req.head.method == .PUT or req.head.method == .DELETE) .forbidden else .method_not_allowed, "application/json", if (req.head.method == .PUT or req.head.method == .DELETE) "{\"error\":\"invalid request\"}" else "{\"error\":\"method not allowed\"}", &no_store);
            if (req.head.method == .PUT) {
                const image = profile_avatar.validate(content_type_owned, body) catch return respond(req, .bad_request, "application/json", "{\"error\":\"use a valid png, jpeg, or gif up to 2 mb and 4096 px\"}", &no_store);
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
                const etag = std.fmt.bytesToHex(digest, .lower);
                const extension = if (std.mem.eql(u8, image.content_type, "image/png")) "png" else if (std.mem.eql(u8, image.content_type, "image/gif")) "gif" else "jpg";
                var object_key_buf: [128]u8 = undefined;
                const object_key = try std.fmt.bufPrint(&object_key_buf, "{d}/{s}.{s}", .{ user.id, &etag, extension });
                const previous = try self.store.customAvatarForUser(self.allocator, user.id);
                defer if (previous) |avatar_value| {
                    var avatar = avatar_value;
                    avatar.deinit();
                };
                self.avatar_store.put(self.allocator, self.store.io, object_key, image.content_type, body) catch |err| {
                    std.log.warn("event=website_avatar_upload_failed user_id={d} error={t}", .{ user.id, err });
                    return respond(req, .bad_gateway, "application/json", "{\"error\":\"avatar storage is not available\"}", &no_store);
                };
                self.store.setCustomAvatar(user.id, object_key, image.content_type, etag) catch |err| {
                    const replaces_existing_object = if (previous) |avatar| std.mem.eql(u8, avatar.object_key, object_key) else false;
                    if (!replaces_existing_object) self.avatar_store.delete(self.allocator, self.store.io, object_key) catch {};
                    return err;
                };
                self.avatar_cache.put(object_key, body) catch |err| std.log.warn("event=website_avatar_cache_write_failed user_id={d} error={t}", .{ user.id, err });
                if (previous) |avatar| if (!std.mem.eql(u8, avatar.object_key, object_key)) {
                    self.avatar_cache.remove(avatar.object_key);
                    self.avatar_store.delete(self.allocator, self.store.io, avatar.object_key) catch |err| std.log.warn("event=website_avatar_old_object_delete_failed user_id={d} error={t}", .{ user.id, err });
                };
                std.log.info("event=website_avatar_updated user_id={d} bytes={d} type={s}", .{ user.id, body.len, image.content_type });
                return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
            }
            const previous = try self.store.customAvatarForUser(self.allocator, user.id);
            defer if (previous) |avatar_value| {
                var avatar = avatar_value;
                avatar.deinit();
            };
            _ = try self.store.deleteCustomAvatar(user.id);
            if (previous) |avatar| {
                self.avatar_cache.remove(avatar.object_key);
                self.avatar_store.delete(self.allocator, self.store.io, avatar.object_key) catch |err| std.log.warn("event=website_avatar_object_delete_failed user_id={d} error={t}", .{ user.id, err });
            }
            std.log.info("event=website_avatar_reset user_id={d}", .{user.id});
            return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
        }
        if (std.mem.eql(u8, path, "/api/v1/staff/session")) {
            const no_store = [_]std.http.Header{
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "pragma", .value = "no-cache" },
            };
            if (!web_auth.websiteHost(host_owned)) return respond(req, .not_found, "application/json", "{\"error\":\"not found\"}", &no_store);
            if (req.head.method == .POST) {
                if (!web_auth.sameOrigin(origin_owned, host_owned)) return respond(req, .forbidden, "application/json", "{\"error\":\"invalid origin\"}", &no_store);
                const name = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"username"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"username required\"}", &no_store);
                defer self.allocator.free(name);
                const password = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"password"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"password required\"}", &no_store);
                defer self.allocator.free(password);
                const password_md5 = web_auth.passwordCredential(password) catch return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid credentials\"}", &no_store);
                const user = (try self.store.authenticate(self.allocator, name, &password_md5)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid credentials\"}", &no_store);
                defer self.allocator.free(user.name);
                defer self.allocator.free(user.safe_name);
                if (!web_auth.allowed(user)) return respond(req, .forbidden, "application/json", "{\"error\":\"staff access required\"}", &no_store);
                const token = try self.store.issueToken(user.id, web_auth.scope, web_auth.lifetime_seconds);
                std.log.info("event=staff_session_created user_id={d}", .{user.id});
                const csrf = web_auth.csrfToken(&token);
                const json = try web_auth.sessionJson(self.allocator, user, csrf);
                defer self.allocator.free(json);
                var cookie_buf: [256]u8 = undefined;
                const cookie = try std.fmt.bufPrint(&cookie_buf, "{s}={s}; Path=/; Max-Age={d}; Secure; HttpOnly; SameSite=Strict", .{ web_auth.cookie_name, &token, web_auth.lifetime_seconds });
                const headers = [_]std.http.Header{
                    .{ .name = "set-cookie", .value = cookie },
                    .{ .name = "cache-control", .value = "no-store" },
                    .{ .name = "pragma", .value = "no-cache" },
                };
                return respond(req, .ok, "application/json", json, &headers);
            }
            const token = web_auth.sessionToken(cookie_owned) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
            if (req.head.method == .GET) {
                const user = (try self.store.authenticateToken(self.allocator, token, web_auth.scope)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
                defer self.allocator.free(user.name);
                defer self.allocator.free(user.safe_name);
                if (!web_auth.allowed(user)) {
                    _ = try self.store.revokeToken(token);
                    return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
                }
                const csrf = web_auth.csrfToken(token);
                const json = try web_auth.sessionJson(self.allocator, user, csrf);
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &no_store);
            }
            if (req.head.method == .DELETE) {
                if (!web_auth.sameOrigin(origin_owned, host_owned) or !web_auth.csrfMatches(token, csrf_owned)) return respond(req, .forbidden, "application/json", "{\"error\":\"invalid request\"}", &no_store);
                _ = try self.store.revokeToken(token);
                const headers = [_]std.http.Header{
                    .{ .name = "set-cookie", .value = "__Host-kai-session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict" },
                    .{ .name = "cache-control", .value = "no-store" },
                    .{ .name = "pragma", .value = "no-cache" },
                };
                return respond(req, .no_content, "application/json", "", &headers);
            }
            return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &no_store);
        }
        if (std.mem.startsWith(u8, path, "/api/v1/staff/")) {
            const no_store = [_]std.http.Header{
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "pragma", .value = "no-cache" },
            };
            if (!web_auth.websiteHost(host_owned)) return respond(req, .not_found, "application/json", "{\"error\":\"not found\"}", &no_store);
            const staff_token = web_auth.sessionToken(cookie_owned) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
            const staff_user = (try self.store.authenticateToken(self.allocator, staff_token, web_auth.scope)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
            defer freeUser(self.allocator, staff_user);
            if (!web_auth.allowed(staff_user)) {
                _ = try self.store.revokeToken(staff_token);
                return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
            }
            if (req.head.method == .POST and (!web_auth.sameOrigin(origin_owned, host_owned) or !web_auth.csrfMatches(staff_token, csrf_owned))) return respond(req, .forbidden, "application/json", "{\"error\":\"invalid request\"}", &no_store);

            if (std.mem.eql(u8, path, "/api/v1/staff/overview") and req.head.method == .GET) {
                const json = try self.store.staffOverviewJson(self.allocator);
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &no_store);
            }
            if (std.mem.eql(u8, path, "/api/v1/staff/ranking")) {
                if (!web_auth.canRank(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"ranking access required\"}", &no_store);
                if (req.head.method == .GET) {
                    const json = try self.store.staffRankingJson(self.allocator);
                    defer self.allocator.free(json);
                    return respond(req, .ok, "application/json", json, &no_store);
                }
                if (req.head.method == .POST) {
                    const set_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"set_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"set required\"}", &no_store);
                    defer self.allocator.free(set_text);
                    const action = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"action"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"action required\"}", &no_store);
                    defer self.allocator.free(action);
                    const reason = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"reason"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"reason required\"}", &no_store);
                    defer self.allocator.free(reason);
                    const set_id = std.fmt.parseInt(i32, set_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid set\"}", &no_store);
                    if (set_id <= 0 or !validWebText(reason, 3, 1000)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid ranking action\"}", &no_store);
                    const md5 = (try self.store.beatmapMd5ForSet(set_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap set not found\"}", &no_store);
                    const trimmed_reason = std.mem.trim(u8, reason, " \t\r\n");
                    if (std.mem.eql(u8, action, "nominate")) {
                        _ = self.store.nominateBeatmapSet(staff_user.id, &md5, trimmed_reason) catch return respond(req, .conflict, "application/json", "{\"error\":\"nomination was not accepted\"}", &no_store);
                    } else {
                        const rank_action: domain.BeatmapRankAction = if (std.mem.eql(u8, action, "pending")) .pending else if (std.mem.eql(u8, action, "qualify")) .qualify else if (std.mem.eql(u8, action, "rank")) .rank else if (std.mem.eql(u8, action, "approve")) .approve else if (std.mem.eql(u8, action, "love")) .love else if (std.mem.eql(u8, action, "veto")) .veto else if (std.mem.eql(u8, action, "rollback") and web_auth.canAdmin(staff_user)) .rollback else return respond(req, .bad_request, "application/json", "{\"error\":\"invalid ranking action\"}", &no_store);
                        _ = self.store.applyBeatmapRankAction(staff_user.id, &md5, rank_action, trimmed_reason) catch return respond(req, .conflict, "application/json", "{\"error\":\"ranking transition was not accepted\"}", &no_store);
                    }
                    std.log.info("event=staff_ranking_action actor_id={d} set_id={d} action={s}", .{ staff_user.id, set_id, action });
                    return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
                }
            }
            if (std.mem.eql(u8, path, "/api/v1/staff/moderation")) {
                if (!web_auth.canModerate(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"moderation access required\"}", &no_store);
                if (req.head.method == .GET) {
                    const user_text = queryField(target, "user") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"player required\"}", &no_store);
                    var target_id = std.fmt.parseInt(i32, user_text, 10) catch 0;
                    if (target_id <= 0) {
                        const encoded = try self.allocator.dupe(u8, user_text);
                        defer self.allocator.free(encoded);
                        for (encoded) |*char| if (char.* == '+') {
                            char.* = ' ';
                        };
                        const decoded = std.Uri.percentDecodeInPlace(encoded);
                        const found = (try self.store.userByName(self.allocator, decoded)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &no_store);
                        defer freeUser(self.allocator, found);
                        target_id = found.id;
                    }
                    const json = (try self.store.staffUserJson(self.allocator, target_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &no_store);
                    defer self.allocator.free(json);
                    return respond(req, .ok, "application/json", json, &no_store);
                }
                if (req.head.method == .POST) {
                    const user_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"user_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"player required\"}", &no_store);
                    defer self.allocator.free(user_text);
                    const action = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"action"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"action required\"}", &no_store);
                    defer self.allocator.free(action);
                    const reason = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"reason"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"reason required\"}", &no_store);
                    defer self.allocator.free(reason);
                    const target_id = std.fmt.parseInt(i32, user_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid player\"}", &no_store);
                    if (!validWebText(reason, 3, 1000)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid reason\"}", &no_store);
                    const target_user = (try self.store.userById(self.allocator, target_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &no_store);
                    defer freeUser(self.allocator, target_user);
                    if (!web_auth.canManage(staff_user, target_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"protected player\"}", &no_store);
                    const trimmed_reason = std.mem.trim(u8, reason, " \t\r\n");
                    if (std.mem.eql(u8, action, "note")) {
                        try self.store.addModerationNote(staff_user.id, target_id, trimmed_reason);
                    } else if (std.mem.eql(u8, action, "silence") or std.mem.eql(u8, action, "unsilence")) {
                        var seconds: i64 = 0;
                        if (std.mem.eql(u8, action, "silence")) {
                            const duration = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"duration"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"duration required\"}", &no_store);
                            defer self.allocator.free(duration);
                            seconds = std.fmt.parseInt(i64, duration, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid duration\"}", &no_store);
                            if (seconds < 60 or seconds > 365 * 86400) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid duration\"}", &no_store);
                        }
                        const silence_end = if (seconds == 0) @as(i64, 0) else std.Io.Clock.real.now(self.store.io).toSeconds() + seconds;
                        try self.store.setSilence(staff_user.id, target_id, silence_end, if (seconds == 0) "account.unsilence" else "account.silence", trimmed_reason);
                        self.sessions.mutex.lockUncancelable(self.sessions.io);
                        defer self.sessions.mutex.unlock(self.sessions.io);
                        if (self.sessions.byUser(target_id)) |online| {
                            online.user.silence_end = silence_end;
                            var packet = protocol.Writer.init(self.allocator);
                            defer packet.deinit();
                            try packet.packetInt(.silence_end, @intCast(@min(seconds, std.math.maxInt(i32))));
                            try online.enqueue(self.allocator, packet.bytes());
                            if (seconds > 0) {
                                packet.list.clearRetainingCapacity();
                                try packet.packetInt(.user_silenced, target_id);
                                try self.sessions.broadcast(packet.bytes(), null);
                            }
                        }
                    } else if (std.mem.eql(u8, action, "restrict") or std.mem.eql(u8, action, "unrestrict")) {
                        if (!web_auth.canAdmin(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"admin access required\"}", &no_store);
                        const restricted = std.mem.eql(u8, action, "restrict");
                        if (target_user.restricted == restricted) return respond(req, .conflict, "application/json", "{\"error\":\"player already has that state\"}", &no_store);
                        try self.store.setRestricted(staff_user.id, target_id, restricted, trimmed_reason);
                        self.sessions.mutex.lockUncancelable(self.sessions.io);
                        defer self.sessions.mutex.unlock(self.sessions.io);
                        if (self.sessions.byUser(target_id)) |online| {
                            online.user.restricted = restricted;
                            var packet = protocol.Writer.init(self.allocator);
                            defer packet.deinit();
                            if (restricted) {
                                try packet.packetEmpty(.account_restricted);
                                var visibility = protocol.Writer.init(self.allocator);
                                defer visibility.deinit();
                                const start = try visibility.begin(.user_logout);
                                try visibility.int(i32, target_id);
                                try visibility.byte(0);
                                visibility.finish(start);
                                try self.sessions.broadcast(visibility.bytes(), online);
                            }
                            try packet.packetInt(.restart, 0);
                            try online.enqueue(self.allocator, packet.bytes());
                        }
                    } else if (std.mem.eql(u8, action, "add_privilege") or std.mem.eql(u8, action, "remove_privilege")) {
                        if (!web_auth.canDevelop(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"developer access required\"}", &no_store);
                        const bits_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"bits"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"privilege bits required\"}", &no_store);
                        defer self.allocator.free(bits_text);
                        const bits = std.fmt.parseInt(u32, bits_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid privilege bits\"}", &no_store);
                        const allowed_bits: u32 = 1 | 2 | (1 << 4) | (1 << 5) | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 13) | (1 << 14);
                        if (bits == 0 or bits & ~allowed_bits != 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid privilege bits\"}", &no_store);
                        const privileges = try self.store.changePrivileges(staff_user.id, target_id, bits, std.mem.eql(u8, action, "add_privilege"));
                        self.sessions.mutex.lockUncancelable(self.sessions.io);
                        defer self.sessions.mutex.unlock(self.sessions.io);
                        if (self.sessions.byUser(target_id)) |online| {
                            online.user.privileges = privileges;
                            var packet = protocol.Writer.init(self.allocator);
                            defer packet.deinit();
                            try packet.packetInt(.privileges, stableClientPrivileges(privileges));
                            try online.enqueue(self.allocator, packet.bytes());
                        }
                    } else return respond(req, .bad_request, "application/json", "{\"error\":\"invalid moderation action\"}", &no_store);
                    std.log.info("event=staff_moderation_action actor_id={d} target_id={d} action={s}", .{ staff_user.id, target_id, action });
                    return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
                }
            }
            if (std.mem.eql(u8, path, "/api/v1/staff/appeals")) {
                if (!web_auth.canModerate(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"moderation access required\"}", &no_store);
                if (req.head.method == .GET) {
                    const json = try self.store.staffAppealsJson(self.allocator);
                    defer self.allocator.free(json);
                    return respond(req, .ok, "application/json", json, &no_store);
                }
                if (req.head.method == .POST) {
                    const id_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"appeal_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"appeal required\"}", &no_store);
                    defer self.allocator.free(id_text);
                    const decision = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"decision"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"decision required\"}", &no_store);
                    defer self.allocator.free(decision);
                    const resolution = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"resolution"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"resolution required\"}", &no_store);
                    defer self.allocator.free(resolution);
                    const appeal_id = std.fmt.parseInt(i64, id_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid appeal\"}", &no_store);
                    if ((!std.mem.eql(u8, decision, "accepted") and !std.mem.eql(u8, decision, "denied")) or !validWebText(resolution, 3, 2000)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid decision\"}", &no_store);
                    self.store.resolveModerationAppeal(staff_user.id, appeal_id, decision, std.mem.trim(u8, resolution, " \t\r\n")) catch return respond(req, .conflict, "application/json", "{\"error\":\"appeal is not open\"}", &no_store);
                    std.log.info("event=staff_appeal_decision actor_id={d} appeal_id={d} decision={s}", .{ staff_user.id, appeal_id, decision });
                    return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
                }
            }
            if (std.mem.eql(u8, path, "/api/v1/staff/anticheat")) {
                if (!web_auth.canModerate(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"moderation access required\"}", &no_store);
                if (req.head.method == .GET) {
                    const json = try self.store.staffAnticheatJson(self.allocator);
                    defer self.allocator.free(json);
                    return respond(req, .ok, "application/json", json, &no_store);
                }
                if (req.head.method == .POST) {
                    const id_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"observation_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"observation required\"}", &no_store);
                    defer self.allocator.free(id_text);
                    const label_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"label"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"label required\"}", &no_store);
                    defer self.allocator.free(label_text);
                    const note = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"note"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"review note required\"}", &no_store);
                    defer self.allocator.free(note);
                    const observation_id = std.fmt.parseInt(i64, id_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid observation\"}", &no_store);
                    const label = storage.AnticheatReviewLabel.parse(label_text) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid review label\"}", &no_store);
                    if (!validWebText(note, 3, 1000)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid review note\"}", &no_store);
                    self.store.reviewAnticheatObservation(staff_user.id, observation_id, label, note) catch |err| switch (err) {
                        error.AnticheatObservationNotFound => return respond(req, .not_found, "application/json", "{\"error\":\"observation not found\"}", &no_store),
                        else => return err,
                    };
                    std.log.info("event=staff_anticheat_review actor_id={d} observation_id={d} label={s}", .{ staff_user.id, observation_id, label.text() });
                    return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
                }
            }
            if (std.mem.eql(u8, path, "/api/v1/staff/audit") and req.head.method == .GET) {
                if (!web_auth.canModerate(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"moderation access required\"}", &no_store);
                const json = try self.store.staffAuditJson(self.allocator);
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &no_store);
            }
            if (std.mem.eql(u8, path, "/api/v1/staff/channels")) {
                if (!web_auth.canAdmin(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"admin access required\"}", &no_store);
                if (req.head.method == .GET) {
                    const json = try self.store.staffChannelsJson(self.allocator);
                    defer self.allocator.free(json);
                    return respond(req, .ok, "application/json", json, &no_store);
                }
                if (req.head.method == .POST) {
                    const channel = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"channel"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"channel required\"}", &no_store);
                    defer self.allocator.free(channel);
                    const action = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"action"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"action required\"}", &no_store);
                    defer self.allocator.free(action);
                    const reason = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"reason"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"reason required\"}", &no_store);
                    defer self.allocator.free(reason);
                    if ((!std.mem.eql(u8, action, "lock") and !std.mem.eql(u8, action, "unlock")) or !validWebText(reason, 3, 1000)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid channel action\"}", &no_store);
                    self.store.setChannelLocked(staff_user.id, channel, std.mem.eql(u8, action, "lock"), std.mem.trim(u8, reason, " \t\r\n")) catch return respond(req, .bad_request, "application/json", "{\"error\":\"unknown channel\"}", &no_store);
                    std.log.info("event=staff_channel_action actor_id={d} channel={s} action={s}", .{ staff_user.id, channel, action });
                    return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
                }
            }
            const known_staff_path = std.mem.eql(u8, path, "/api/v1/staff/overview") or
                std.mem.eql(u8, path, "/api/v1/staff/ranking") or
                std.mem.eql(u8, path, "/api/v1/staff/moderation") or
                std.mem.eql(u8, path, "/api/v1/staff/appeals") or
                std.mem.eql(u8, path, "/api/v1/staff/anticheat") or
                std.mem.eql(u8, path, "/api/v1/staff/audit") or
                std.mem.eql(u8, path, "/api/v1/staff/channels");
            return respond(req, if (known_staff_path) .method_not_allowed else .not_found, "application/json", if (known_staff_path) "{\"error\":\"method not allowed\"}" else "{\"error\":\"not found\"}", &no_store);
        }
        if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v1/rankings")) {
            const source = domain.parseSiteScoreSource(queryField(target, "source") orelse "all") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid source\"}", &.{});
            const mode = std.fmt.parseInt(u8, queryField(target, "mode") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid mode\"}", &.{});
            const offset = std.fmt.parseInt(u16, queryField(target, "offset") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid offset\"}", &.{});
            if (!domain.validSiteMode(source, mode) or offset > 10_000) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid rankings\"}", &.{});
            const listing = try self.store.siteRankings(self.allocator, source, mode, offset);
            defer self.allocator.free(listing);
            return respond(req, .ok, "application/json", listing, &.{});
        }
        if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v1/users/")) {
            const encoded_identifier = path["/api/v1/users/".len..];
            if (encoded_identifier.len == 0 or encoded_identifier.len > 96 or std.mem.indexOfScalar(u8, encoded_identifier, '/') != null) return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &.{});
            const identifier_buffer = try self.allocator.dupe(u8, encoded_identifier);
            defer self.allocator.free(identifier_buffer);
            const identifier = std.Uri.percentDecodeInPlace(identifier_buffer);
            if (identifier.len < 1 or identifier.len > 32 or std.mem.indexOfScalar(u8, identifier, '/') != null) return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &.{});
            const user_id = std.fmt.parseInt(i32, identifier, 10) catch resolve: {
                const found = (try self.store.userByName(self.allocator, identifier)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &.{});
                defer self.allocator.free(found.name);
                defer self.allocator.free(found.safe_name);
                break :resolve found.id;
            };
            if (user_id <= 0) return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &.{});
            const source = domain.parseSiteScoreSource(queryField(target, "source") orelse "all") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid source\"}", &.{});
            const mode = std.fmt.parseInt(u8, queryField(target, "mode") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid mode\"}", &.{});
            if (!domain.validSiteMode(source, mode)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid mode\"}", &.{});
            const profile = (try self.store.siteProfile(self.allocator, user_id, source, mode)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &.{});
            defer self.allocator.free(profile);
            return respond(req, .ok, "application/json", profile, &.{});
        }
        if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v1/beatmapsets/")) {
            const set_id = std.fmt.parseInt(i32, path["/api/v1/beatmapsets/".len..], 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap set\"}", &.{});
            if (set_id <= 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap set\"}", &.{});
            const set = (try self.store.lazerBeatmapSet(self.allocator, set_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap set not found\"}", &.{});
            defer self.allocator.free(set);
            return respond(req, .ok, "application/json", set, &.{});
        }
        if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v1/beatmaps/") and std.mem.endsWith(u8, path, "/leaderboard")) {
            const id_text = path["/api/v1/beatmaps/".len .. path.len - "/leaderboard".len];
            if (id_text.len == 0 or std.mem.indexOfScalar(u8, id_text, '/') != null) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap\"}", &.{});
            const map_id = std.fmt.parseInt(i32, id_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap\"}", &.{});
            const source = domain.parseSiteScoreSource(queryField(target, "source") orelse "all") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid source\"}", &.{});
            const mode = std.fmt.parseInt(u8, queryField(target, "mode") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid mode\"}", &.{});
            if (map_id <= 0 or !domain.validSiteMode(source, mode)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid leaderboard\"}", &.{});
            const board = (try self.store.siteBeatmapLeaderboard(self.allocator, map_id, source, mode)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap not found for that ruleset\"}", &.{});
            defer self.allocator.free(board);
            return respond(req, .ok, "application/json", board, &.{});
        }
        if (req.head.method == .GET) if (lazer.parseScoreDownloadPath(path)) |score_id| {
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            const stable_score_id = lazer.decodeStableScoreId(score_id);
            const replay = if (stable_score_id) |stable_id|
                try self.store.siteReplay(self.allocator, stable_id)
            else
                try self.store.lazerReplay(self.allocator, score_id);
            const data = replay orelse return respond(req, .not_found, "application/json", "{\"error\":\"replay not found\"}", &.{});
            defer self.allocator.free(data);
            var disposition_buf: [96]u8 = undefined;
            const disposition = try std.fmt.bufPrint(&disposition_buf, "attachment; filename=\"kai-{s}-score-{d}.osr\"", .{ if (stable_score_id != null) "stable" else "lazer", stable_score_id orelse score_id });
            return respond(req, .ok, "application/x-osu-replay", data, &.{
                .{ .name = "content-disposition", .value = disposition },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
            });
        };
        if (req.head.method == .GET and std.mem.startsWith(u8, path, "/replays/stable/")) {
            const id_text = path["/replays/stable/".len..];
            if (id_text.len == 0 or std.mem.indexOfScalar(u8, id_text, '/') != null) return respond(req, .not_found, "application/json", "{\"error\":\"replay not found\"}", &.{});
            const score_id = std.fmt.parseInt(i64, id_text, 10) catch return respond(req, .not_found, "application/json", "{\"error\":\"replay not found\"}", &.{});
            const replay = (try self.store.siteReplay(self.allocator, score_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"replay not found\"}", &.{});
            defer self.allocator.free(replay);
            var disposition_buf: [96]u8 = undefined;
            const disposition = try std.fmt.bufPrint(&disposition_buf, "attachment; filename=\"kai-score-{d}.osr\"", .{score_id});
            return respond(req, .ok, "application/octet-stream", replay, &.{
                .{ .name = "content-disposition", .value = disposition },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
            });
        }
        if (req.head.method == .GET and std.mem.startsWith(u8, path, "/replays/lazer/")) {
            const id_text = path["/replays/lazer/".len..];
            if (id_text.len == 0 or std.mem.indexOfScalar(u8, id_text, '/') != null) return respond(req, .not_found, "application/json", "{\"error\":\"replay not found\"}", &.{});
            const score_id = std.fmt.parseInt(i64, id_text, 10) catch return respond(req, .not_found, "application/json", "{\"error\":\"replay not found\"}", &.{});
            const replay = (try self.store.lazerReplay(self.allocator, score_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"replay not found\"}", &.{});
            defer self.allocator.free(replay);
            var disposition_buf: [96]u8 = undefined;
            const disposition = try std.fmt.bufPrint(&disposition_buf, "attachment; filename=\"kai-lazer-score-{d}.osr\"", .{score_id});
            return respond(req, .ok, "application/x-osu-replay", replay, &.{
                .{ .name = "content-disposition", .value = disposition },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
            });
        }
        if (req.head.method == .GET and std.mem.startsWith(u8, path, "/ss/")) {
            const requested = screenshot.parsePath(path) orelse return respond(req, .not_found, "application/json", "{\"status\":\"Screenshot not found.\"}", &.{});
            const image = (try self.store.screenshot(self.allocator, requested.token, requested.kind.extension())) orelse return respond(req, .not_found, "application/json", "{\"status\":\"Screenshot not found.\"}", &.{});
            defer self.allocator.free(image);
            return respond(req, .ok, requested.kind.contentType(), image, &.{
                .{ .name = "cache-control", .value = "public, max-age=31536000, immutable" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
            });
        }
        if (req.head.method == .GET) {
            if (media_contract.parsePath(path)) |media_request| {
                var asset = (self.media_sync.get(&self.store, media_request) catch |err| {
                    std.log.warn("beatmap media fetch failed set_id={d} kind={s}: {t}", .{ media_request.set_id, media_request.kind.dbName(), err });
                    return respond(req, .bad_gateway, "application/json", "{\"error\":\"beatmap media upstream unavailable\"}", &.{.{ .name = "cache-control", .value = "no-store" }});
                }) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap media unavailable\"}", &.{.{ .name = "cache-control", .value = "public, max-age=300" }});
                defer asset.deinit(self.allocator);
                return respond(req, .ok, asset.content_type.value(), asset.data, &.{
                    .{ .name = "cache-control", .value = "public, max-age=86400" },
                    .{ .name = "x-content-type-options", .value = "nosniff" },
                });
            }
        }
        if (req.head.method == .GET and (isAvatarHost(host_owned) or std.mem.startsWith(u8, path, "/avatars/") or std.mem.startsWith(u8, path, "/avatar/"))) {
            if (avatarUserId(path)) |user_id| {
                if (try self.store.customAvatarForUser(self.allocator, user_id)) |avatar_value| {
                    var avatar = avatar_value;
                    defer avatar.deinit();
                    var data = self.avatar_cache.get(avatar.object_key) catch |err| cache_error: {
                        std.log.warn("event=website_avatar_cache_read_failed user_id={d} error={t}", .{ user_id, err });
                        break :cache_error null;
                    };
                    if (data == null) {
                        const fetched = self.avatar_store.get(self.allocator, self.store.io, avatar.object_key, avatar.content_type) catch |err| {
                            std.log.warn("event=website_avatar_download_failed user_id={d} error={t}", .{ user_id, err });
                            return respond(req, .bad_gateway, "application/json", "{\"error\":\"avatar storage is not available\"}", &.{.{ .name = "cache-control", .value = "no-store" }});
                        };
                        self.avatar_cache.put(avatar.object_key, fetched) catch |err| std.log.warn("event=website_avatar_cache_write_failed user_id={d} error={t}", .{ user_id, err });
                        data = fetched;
                    }
                    const avatar_data = data.?;
                    defer self.allocator.free(avatar_data);
                    var etag_buf: [66]u8 = undefined;
                    const etag = try std.fmt.bufPrint(&etag_buf, "\"{s}\"", .{&avatar.etag});
                    const custom_headers = [_]std.http.Header{
                        .{ .name = "cache-control", .value = "public, max-age=300" },
                        .{ .name = "etag", .value = etag },
                        .{ .name = "x-content-type-options", .value = "nosniff" },
                    };
                    if (header(req, "if-none-match")) |current| if (std.mem.eql(u8, current, etag)) return respond(req, .not_modified, avatar.content_type, "", &custom_headers);
                    return respond(req, .ok, avatar.content_type, avatar_data, &custom_headers);
                }
                const key = (try self.store.avatarForUser(user_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"avatar not found\"}", &.{});
                const cache_headers = [_]std.http.Header{
                    .{ .name = "cache-control", .value = "public, max-age=3600" },
                    .{ .name = "etag", .value = if (key == 1) "\"default-avatar-1\"" else "\"default-avatar-2\"" },
                    .{ .name = "x-content-type-options", .value = "nosniff" },
                };
                return if (key == 1)
                    respond(req, .ok, "image/gif", default_avatar_1, &cache_headers)
                else
                    respond(req, .ok, "image/jpeg", default_avatar_2, &cache_headers);
            }
        }
        if (req.head.method == .GET and std.mem.startsWith(u8, path, "/d/")) {
            const raw_set_id = path[3..];
            const set_id_text = if (std.mem.endsWith(u8, raw_set_id, "n")) raw_set_id[0 .. raw_set_id.len - 1] else raw_set_id;
            const set_id = std.fmt.parseInt(i32, set_id_text, 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
            const archive = (try self.store.beatmapArchive(self.allocator, set_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap archive unavailable\"}", &.{});
            defer self.allocator.free(archive);
            var disposition_buf: [96]u8 = undefined;
            const disposition = try std.fmt.bufPrint(&disposition_buf, "attachment; filename=\"{d}.osz\"", .{set_id});
            const headers = [_]std.http.Header{.{ .name = "content-disposition", .value = disposition }};
            return respond(req, .ok, "application/x-osu-beatmap-archive", archive, &headers);
        }
        if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v2/beatmapsets/") and std.mem.endsWith(u8, path, "/download")) {
            const id_text = path["/api/v2/beatmapsets/".len .. path.len - "/download".len];
            const set_id = std.fmt.parseInt(i32, id_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap set\"}", &.{});
            const auth = auth_owned orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            if (!std.mem.startsWith(u8, auth, "Bearer ")) return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            const user = (try self.store.authenticateToken(self.allocator, auth[7..], "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            const archive = (try self.store.beatmapArchive(self.allocator, set_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap archive unavailable\"}", &.{});
            defer self.allocator.free(archive);
            var disposition_buf: [96]u8 = undefined;
            const disposition = try std.fmt.bufPrint(&disposition_buf, "attachment; filename=\"{d}.osz\"", .{set_id});
            const headers = [_]std.http.Header{.{ .name = "content-disposition", .value = disposition }};
            return respond(req, .ok, "application/x-osu-beatmap-archive", archive, &headers);
        }
        if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v2/beatmaps/") and std.mem.endsWith(u8, path, "/file")) {
            const id_text = path["/api/v2/beatmaps/".len .. path.len - "/file".len];
            const map_id = std.fmt.parseInt(i32, id_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap\"}", &.{});
            const auth = auth_owned orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            if (!std.mem.startsWith(u8, auth, "Bearer ")) return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            const user = (try self.store.authenticateToken(self.allocator, auth[7..], "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            const map_file = (try self.store.beatmapFileById(self.allocator, map_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap file unavailable\"}", &.{});
            defer self.allocator.free(map_file);
            var disposition_buf: [96]u8 = undefined;
            const disposition = try std.fmt.bufPrint(&disposition_buf, "attachment; filename=\"{d}.osu\"", .{map_id});
            const headers = [_]std.http.Header{.{ .name = "content-disposition", .value = disposition }};
            return respond(req, .ok, "application/x-osu-beatmap", map_file, &headers);
        }
        if (std.mem.eql(u8, path, "/users") and req.head.method == .POST) {
            const check = try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"check"});
            defer if (check) |value| self.allocator.free(value);
            const stable_registration = check != null;
            const name = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{ "name", "user[username]" })) orelse return respond(req, .bad_request, if (stable_registration) "text/plain" else "application/json", if (stable_registration) "Missing required params" else "{\"error\":\"name required\"}", &.{});
            defer self.allocator.free(name);
            const email = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{ "email", "user[user_email]" })) orelse if (stable_registration) return respond(req, .bad_request, "text/plain", "Missing required params", &.{}) else try self.allocator.dupe(u8, "");
            defer self.allocator.free(email);
            const password = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{ "password_md5", "user[password]" })) orelse return respond(req, .bad_request, if (stable_registration) "text/plain" else "application/json", if (stable_registration) "Missing required params" else "{\"error\":\"password required\"}", &.{});
            defer self.allocator.free(password);
            if (check) |check_value| {
                const result = registration.stableRequest(&self.store, name, email, password, check_value) catch |err| return respond(req, if (err == error.InvalidCheck) .bad_request else .internal_server_error, "text/plain", if (err == error.InvalidCheck) "Invalid check value" else "registration failed", &.{});
                switch (result) {
                    .ok => return respond(req, .ok, "text/plain", "ok", &.{}),
                    .validation_failed => |validation| {
                        var error_buffer: [768]u8 = undefined;
                        const error_json = try registration.writeStableErrors(&error_buffer, validation);
                        return respond(req, .bad_request, "application/json", error_json, &.{});
                    },
                }
            }
            const password_md5 = form_urlencoded.credentialMd5(password) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid fields\"}", &.{});
            if (!registration.validUsername(name) or !registration.validEmail(email) or !registration.validCredential(password)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid fields\"}", &.{});
            const id = self.store.register(name, email, &password_md5) catch |err| return respond(req, if (err == error.UserExists) .conflict else .internal_server_error, "application/json", "{\"error\":\"registration failed\"}", &.{});
            var out: [256]u8 = undefined;
            const json = try user_json.registration(&out, id, name);
            return respond(req, .created, "application/json", json, &.{});
        }
        if (std.mem.eql(u8, path, "/oauth/token") and req.head.method == .POST) {
            const grant = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"grant_type"})) orelse try self.allocator.dupe(u8, "password");
            defer self.allocator.free(grant);
            if (!std.mem.eql(u8, grant, "password")) return respond(req, .bad_request, "application/json", "{\"error\":\"unsupported_grant_type\"}", &.{});
            const name = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"username"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_request\"}", &.{});
            defer self.allocator.free(name);
            const password = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{ "password_md5", "password" })) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_request\"}", &.{});
            defer self.allocator.free(password);
            const password_md5 = form_urlencoded.credentialMd5(password) catch return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid_grant\"}", &.{});
            const user = (try self.store.authenticate(self.allocator, name, &password_md5)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid_grant\"}", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            const token = try self.store.issueToken(user.id, "identify scores:write", 3600);
            var out: [256]u8 = undefined;
            const json = try std.fmt.bufPrint(&out, "{{\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\"identify scores:write\",\"access_token\":\"{s}\"}}", .{token});
            const token_headers = [_]std.http.Header{
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "pragma", .value = "no-cache" },
            };
            return respond(req, .ok, "application/json", json, &token_headers);
        }
        if (std.mem.eql(u8, path, "/oauth/revoke") and req.head.method == .POST) {
            const token = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"token"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_request\"}", &.{});
            defer self.allocator.free(token);
            _ = try self.store.revokeToken(token);
            return respond(req, .ok, "application/json", "{}", &.{});
        }
        if (std.mem.eql(u8, path, "/api/v2/mods")) return respond(req, .ok, "application/json", "{\"mods\":[{\"acronym\":\"RX\",\"name\":\"Relax\",\"description\":\"server accepted; separate relax leaderboard\",\"ranked\":true,\"score_multiplier\":0.0,\"settings\":{}},{\"acronym\":\"AP\",\"name\":\"Autopilot\",\"description\":\"server accepted; separate autopilot leaderboard\",\"ranked\":true,\"score_multiplier\":0.0,\"settings\":{}},{\"acronym\":\"CL\",\"name\":\"Classic\",\"description\":\"Stable score leaderboard\",\"ranked\":true,\"score_multiplier\":1.0,\"settings\":{}}],\"custom_mod_contract\":{\"acronym\":\"2-8 uppercase ASCII characters\",\"settings\":\"arbitrary JSON object\",\"leaderboard\":\"custom namespace\",\"ranked\":true}}", &.{});
        if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/seasonal-backgrounds")) return respond(req, .ok, "application/json", "{\"backgrounds\":[]}", &.{});
        if (req.head.method == .GET and std.mem.eql(u8, path, "/web/osu-getseasonal.php")) return respond(req, .ok, "application/json", "[]", &.{});
        if (req.head.method == .GET and std.mem.eql(u8, path, "/menu-content.json")) return respond(req, .ok, "application/json", "{\"images\":[]}", &.{});
        if (std.mem.eql(u8, path, "/api/v2/notifications")) {
            if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            return respond(req, .ok, "application/json", "{\"has_more\":false,\"notifications\":[],\"notification_endpoint\":\"wss://api.kai.ovh/notification-endpoint\"}", &.{});
        }
        if (std.mem.eql(u8, path, "/api/v2/friends")) {
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            if (req.head.method == .GET) {
                const json = try self.friendRelationsJson(user.id);
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &.{});
            }
            if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const target_id = std.fmt.parseInt(i32, queryField(target, "target") orelse "", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid target\"}", &.{});
            const target_user = (try self.store.userById(self.allocator, target_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
            defer freeUser(self.allocator, target_user);
            if (target_user.restricted or target_user.id == user.id or target_user.id == 3) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"user cannot be followed\"}", &.{});
            _ = try self.store.addFriend(user.id, target_user.id);
            const json = try self.friendMutationJson(user.id, target_user);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &.{});
        }
        if (lazer.parseFriendPath(path)) |target_id| {
            if (req.head.method != .DELETE) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            if (target_id == 3) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"kai stays available\"}", &.{});
            _ = try self.store.removeFriend(user.id, target_id);
            return respond(req, .no_content, "application/json", "", &.{});
        }
        if (std.mem.eql(u8, path, "/api/v2/blocks")) {
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            if (req.head.method == .GET) {
                const json = try self.blockRelationsJson(user.id);
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &.{});
            }
            if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const target_id = std.fmt.parseInt(i32, queryField(target, "target") orelse "", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid target\"}", &.{});
            const target_user = (try self.store.userById(self.allocator, target_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
            defer freeUser(self.allocator, target_user);
            if (target_user.id == user.id or target_user.id == 3) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"user cannot be blocked\"}", &.{});
            _ = try self.store.addBlock(user.id, target_user.id);
            return respond(req, .no_content, "application/json", "", &.{});
        }
        if (lazer.parseBlockPath(path)) |target_id| {
            if (req.head.method != .DELETE) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            _ = try self.store.removeBlock(user.id, target_id);
            return respond(req, .no_content, "application/json", "", &.{});
        }
        if (std.mem.eql(u8, path, "/api/v2/me/beatmapset-favourites")) {
            if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            const json = try self.favouriteSetsJson(user.id);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &.{});
        }
        if (lazer.parseFavouritePath(path)) |set_id| {
            if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            const action = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"action"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"action required\"}", &.{});
            defer self.allocator.free(action);
            if (std.mem.eql(u8, action, "favourite"))
                _ = try self.store.addFavourite(user.id, set_id)
            else if (std.mem.eql(u8, action, "unfavourite"))
                _ = try self.store.removeFavourite(user.id, set_id)
            else
                return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid action\"}", &.{});
            return respond(req, .no_content, "application/json", "", &.{});
        }
        if (std.mem.eql(u8, path, "/api/v2/chat/channels")) {
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            if (req.head.method == .GET) {
                const channels = try self.store.lazerChannelListJson(self.allocator, user.id);
                defer self.allocator.free(channels);
                return respond(req, .ok, "application/json", channels, &.{});
            }
            if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const kind = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"type"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"type required\"}", &.{});
            defer self.allocator.free(kind);
            if (!std.ascii.eqlIgnoreCase(kind, "PM") and !std.mem.eql(u8, kind, "5")) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"unsupported channel type\"}", &.{});
            const target_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"target_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"target required\"}", &.{});
            defer self.allocator.free(target_text);
            const target_id = std.fmt.parseInt(i32, target_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid target\"}", &.{});
            if (target_id == user.id) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"cannot message yourself\"}", &.{});
            const target_user = (try self.store.userById(self.allocator, target_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
            defer freeUser(self.allocator, target_user);
            if (target_user.restricted) return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
            const messages = try self.store.lazerDirectMessagesJson(self.allocator, user.id, target_id, 0, 50);
            defer self.allocator.free(messages);
            var output: std.Io.Writer.Allocating = .init(self.allocator);
            defer output.deinit();
            try output.writer.print("{{\"channel_id\":{d},\"recent_messages\":", .{lazer.privateChannelId(target_id).?});
            try output.writer.writeAll(messages);
            try output.writer.writeByte('}');
            return respond(req, .ok, "application/json", output.written(), &.{});
        }
        if (std.mem.eql(u8, path, "/api/v2/chat/new")) {
            if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"restricted\"}", &.{});
            const now = std.Io.Clock.real.now(self.sessions.io).toSeconds();
            if (user.silence_end > now) return respond(req, .forbidden, "application/json", "{\"error\":\"silenced\"}", &.{});
            const target_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"target_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"target required\"}", &.{});
            defer self.allocator.free(target_text);
            const target_id = std.fmt.parseInt(i32, target_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid target\"}", &.{});
            if (target_id == user.id) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"cannot message yourself\"}", &.{});
            const target_user = (try self.store.userById(self.allocator, target_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
            defer freeUser(self.allocator, target_user);
            if (target_user.restricted) return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
            const content = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"message"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"message required\"}", &.{});
            defer self.allocator.free(content);
            const uuid = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"uuid"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"uuid required\"}", &.{});
            defer self.allocator.free(uuid);
            const action_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"is_action"})) orelse try self.allocator.dupe(u8, "false");
            defer self.allocator.free(action_text);
            const is_action = if (std.mem.eql(u8, action_text, "true")) true else if (std.mem.eql(u8, action_text, "false")) false else return respond(req, .bad_request, "application/json", "{\"error\":\"invalid action\"}", &.{});
            if (content.len == 0 or content.len > 2000 or !std.unicode.utf8ValidateSlice(content) or std.mem.indexOfScalar(u8, content, 0) != null) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid message\"}", &.{});
            if (!lazer.validMessageUuid(uuid)) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid uuid\"}", &.{});
            const written = self.store.recordLazerDirectMessage(self.allocator, user.id, target_id, content, is_action, uuid) catch |err| return switch (err) {
                error.ChatUuidConflict => respond(req, .conflict, "application/json", "{\"error\":\"message uuid conflict\"}", &.{}),
                error.InvalidDirectMessage => respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid target\"}", &.{}),
                else => respond(req, .internal_server_error, "application/json", "{\"error\":\"message unavailable\"}", &.{}),
            };
            defer self.allocator.free(written.json);
            if (written.inserted and target_id == 3) self.recordLazerBotReply(user, content, is_action);
            var output: std.Io.Writer.Allocating = .init(self.allocator);
            defer output.deinit();
            try output.writer.print("{{\"new_channel_id\":{d},\"message\":", .{lazer.privateChannelId(target_id).?});
            try output.writer.writeAll(written.json);
            try output.writer.writeByte('}');
            return respond(req, .created, "application/json", output.written(), &.{});
        }
        if (std.mem.eql(u8, path, "/api/v2/presence")) {
            if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            const presence = try self.lazerPresenceJson(user.id);
            defer self.allocator.free(presence);
            return respond(req, .ok, "application/json", presence, &.{.{ .name = "cache-control", .value = "no-store" }});
        }
        if (lazer.parseChannelUserPath(path)) |channel_path| {
            if (req.head.method != .PUT and req.head.method != .DELETE) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            if (channel_path.user_id != user.id) return respond(req, .forbidden, "application/json", "{\"error\":\"channel user mismatch\"}", &.{});
            if (lazer.privateChannelUser(channel_path.channel_id)) |other_id| {
                const other = (try self.store.userById(self.allocator, other_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
                defer freeUser(self.allocator, other);
                if (other.restricted or other.id == user.id) return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
            }
            return respond(req, .ok, "application/json", "{}", &.{});
        }
        if (req.head.method == .GET) if (lazer.parseChannelPath(path)) |channel_id| {
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            if (lazer.privateChannelUser(channel_id)) |other_id| {
                if (other_id == user.id) return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
                const other = (try self.store.userById(self.allocator, other_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
                defer freeUser(self.allocator, other);
                if (other.restricted) return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
                var output: std.Io.Writer.Allocating = .init(self.allocator);
                defer output.deinit();
                try output.writer.writeAll("{\"channel\":");
                try lazer.writePrivateChatChannel(&output.writer, channel_id, other.name, null, null);
                try output.writer.writeAll(",\"users\":[");
                try user_json.writeCompact(&output.writer, user);
                try output.writer.writeByte(',');
                try user_json.writeCompact(&output.writer, other);
                try output.writer.writeAll("]}");
                return respond(req, .ok, "application/json", output.written(), &.{});
            }
            const kai = (try self.store.userById(self.allocator, 3)) orelse return respond(req, .service_unavailable, "application/json", "{\"error\":\"channel presence unavailable\"}", &.{});
            defer freeUser(self.allocator, kai);
            var output: std.Io.Writer.Allocating = .init(self.allocator);
            defer output.deinit();
            try output.writer.writeAll("{\"channel\":");
            try lazer.writeChatChannel(&output.writer, channel_id, null, null);
            try output.writer.writeAll(",\"users\":[");
            try user_json.writeCompact(&output.writer, user);
            try output.writer.writeByte(',');
            try user_json.writeCompact(&output.writer, kai);
            try output.writer.writeAll("]}");
            return respond(req, .ok, "application/json", output.written(), &.{});
        };
        if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/chat/messages")) {
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            const since = std.fmt.parseInt(i64, queryField(target, "since") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid since\"}", &.{});
            if (since < 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid since\"}", &.{});
            const messages = try self.store.lazerAllMessagesJson(self.allocator, user.id, since, 100);
            defer self.allocator.free(messages);
            return respond(req, .ok, "application/json", messages, &.{});
        }
        if (lazer.parseChannelReadPath(path)) |channel_path| {
            if (req.head.method != .PUT) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            if (lazer.privateChannelUser(channel_path.channel_id)) |other_id|
                self.store.markDirectMessagesRead(user.id, other_id) catch return respond(req, .internal_server_error, "application/json", "{\"error\":\"read state unavailable\"}", &.{})
            else
                self.store.markLazerChannelRead(user.id, channel_path.channel_id, channel_path.message_id) catch |err| return switch (err) {
                    error.ChatMessageNotFound => respond(req, .not_found, "application/json", "{\"error\":\"chat message not found\"}", &.{}),
                    else => respond(req, .internal_server_error, "application/json", "{\"error\":\"read state unavailable\"}", &.{}),
                };
            return respond(req, .ok, "application/json", "{}", &.{});
        }
        if (lazer.parseChannelMessagesPath(path)) |channel_path| {
            if (req.head.method != .GET and req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            const private_target_id = lazer.privateChannelUser(channel_path.channel_id);
            if (private_target_id) |target_id| {
                if (target_id == user.id) return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
                const target_user = (try self.store.userById(self.allocator, target_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
                defer freeUser(self.allocator, target_user);
                if (target_user.restricted) return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
            }
            if (req.head.method == .GET) {
                const messages = if (private_target_id) |target_id|
                    try self.store.lazerDirectMessagesJson(self.allocator, user.id, target_id, 0, 50)
                else
                    try self.store.lazerChatMessagesJson(self.allocator, channel_path.channel_id, 0, 50);
                defer self.allocator.free(messages);
                return respond(req, .ok, "application/json", messages, &.{});
            }
            if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"restricted\"}", &.{});
            const now = std.Io.Clock.real.now(self.sessions.io).toSeconds();
            if (user.silence_end > now) return respond(req, .forbidden, "application/json", "{\"error\":\"silenced\"}", &.{});
            const content = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"message"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"message required\"}", &.{});
            defer self.allocator.free(content);
            const uuid = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"uuid"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"uuid required\"}", &.{});
            defer self.allocator.free(uuid);
            const action_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"is_action"})) orelse try self.allocator.dupe(u8, "false");
            defer self.allocator.free(action_text);
            const is_action = if (std.mem.eql(u8, action_text, "true")) true else if (std.mem.eql(u8, action_text, "false")) false else return respond(req, .bad_request, "application/json", "{\"error\":\"invalid action\"}", &.{});
            if (content.len == 0 or content.len > 2000 or !std.unicode.utf8ValidateSlice(content) or std.mem.indexOfScalar(u8, content, 0) != null) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid message\"}", &.{});
            if (!lazer.validMessageUuid(uuid)) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid uuid\"}", &.{});
            const written = (if (private_target_id) |target_id|
                self.store.recordLazerDirectMessage(self.allocator, user.id, target_id, content, is_action, uuid)
            else
                self.store.recordLazerPublicMessage(self.allocator, user.id, lazer.channelName(channel_path.channel_id).?, content, is_action, uuid)) catch |err| return switch (err) {
                error.ChannelReadOnly => respond(req, .forbidden, "application/json", "{\"error\":\"channel is read-only\"}", &.{}),
                error.ChatUuidConflict => respond(req, .conflict, "application/json", "{\"error\":\"message uuid conflict\"}", &.{}),
                error.UnknownChannel => respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{}),
                else => respond(req, .internal_server_error, "application/json", "{\"error\":\"message unavailable\"}", &.{}),
            };
            defer self.allocator.free(written.json);
            if (written.inserted and private_target_id == null) {
                const channel_name = lazer.channelName(channel_path.channel_id).?;
                self.broadcastLazerChatToStable(user, channel_name, content) catch |err|
                    std.log.warn("event=lazer_chat_stable_broadcast_failed channel={s} error={t}", .{ channel_name, err });
            }
            if (written.inserted and private_target_id == 3) self.recordLazerBotReply(user, content, is_action);
            return respond(req, .created, "application/json", written.json, &.{});
        }
        if (std.mem.eql(u8, path, "/api/v2/chat/ack")) {
            if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            return respond(req, .ok, "application/json", "{\"silences\":[]}", &.{});
        }
        if (std.mem.eql(u8, path, "/api/v2/tags")) {
            if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            return respond(req, .ok, "application/json", "{\"tags\":[]}", &.{});
        }
        if (req.head.method == .GET and (std.mem.eql(u8, path, "/api/v2/users") or std.mem.eql(u8, path, "/api/v2/users/lookup"))) {
            const requester = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, requester);
            const ids = lazer.queryIds(self.allocator, target, 50) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid user ids\"}", &.{});
            defer self.allocator.free(ids);
            var output: std.Io.Writer.Allocating = .init(self.allocator);
            defer output.deinit();
            try output.writer.writeAll("{\"users\":[");
            var written: usize = 0;
            for (ids) |id| {
                const found = (try self.store.userById(self.allocator, id)) orelse continue;
                defer freeUser(self.allocator, found);
                if (found.restricted and found.id != requester.id) continue;
                if (written != 0) try output.writer.writeByte(',');
                written += 1;
                try user_json.writeCompact(&output.writer, found);
            }
            try output.writer.writeAll("],\"cursor\":null}");
            return respond(req, .ok, "application/json", output.written(), &.{});
        }
        if (req.head.method == .GET) if (lazer.parseUserScoresPath(path)) |score_path| {
            const requester = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, requester);
            const profile_user = (try self.store.userById(self.allocator, score_path.user_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
            defer freeUser(self.allocator, profile_user);
            if (profile_user.restricted and profile_user.id != requester.id) return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
            const ruleset_id = lazerRulesetId(queryField(target, "mode") orelse "osu") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid mode\"}", &.{});
            const offset = std.fmt.parseInt(u16, queryField(target, "offset") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid offset\"}", &.{});
            const limit = std.fmt.parseInt(u8, queryField(target, "limit") orelse "50", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid limit\"}", &.{});
            if (limit == 0 or limit > 100 or offset > 10_000) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid pagination\"}", &.{});
            const score_source = domain.parseSiteScoreSource(queryField(target, "source") orelse "all") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid score source\"}", &.{});
            if (score_source == .scorev2) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid score source\"}", &.{});
            const json = try self.store.lazerUserScoresJson(self.allocator, profile_user.id, ruleset_id, score_path.kind, score_source, offset, limit);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &.{});
        };
        if (req.head.method == .GET) if (lazer.parseUserPath(path)) |user_path| {
            const requester = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, requester);
            const key = queryField(target, "key") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"lookup key required\"}", &.{});
            const lookup_buffer = try self.allocator.dupe(u8, user_path.lookup);
            defer self.allocator.free(lookup_buffer);
            const lookup = std.Uri.percentDecodeInPlace(lookup_buffer);
            const profile_user = if (std.mem.eql(u8, key, "id")) by_id: {
                const id = std.fmt.parseInt(i32, lookup, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid user id\"}", &.{});
                if (id <= 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid user id\"}", &.{});
                break :by_id try self.store.userById(self.allocator, id);
            } else if (std.mem.eql(u8, key, "username"))
                try self.store.userByName(self.allocator, lookup)
            else
                return respond(req, .bad_request, "application/json", "{\"error\":\"invalid lookup key\"}", &.{});
            const found = profile_user orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
            defer freeUser(self.allocator, found);
            if (found.restricted and found.id != requester.id) return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
            const stats = try self.store.statsForUser(found.id, user_path.ruleset_id);
            const stable_stats = try self.store.sourceStatsForUser(found.id, user_path.ruleset_id, .stable);
            const lazer_stats = try self.store.sourceStatsForUser(found.id, user_path.ruleset_id, .lazer);
            const score_counts = try self.store.lazerUserScoreCounts(found.id, user_path.ruleset_id, .all);
            const stable_counts = try self.store.lazerUserScoreCounts(found.id, user_path.ruleset_id, .stable);
            const lazer_counts = try self.store.lazerUserScoreCounts(found.id, user_path.ruleset_id, .lazer);
            const achievements_json = try self.store.lazerUserAchievementsJson(self.allocator, found.id);
            defer self.allocator.free(achievements_json);
            const json = try user_json.profileOwned(self.allocator, found, stats, score_counts, .{
                .stable_stats = stable_stats,
                .lazer_stats = lazer_stats,
                .stable_counts = stable_counts,
                .lazer_counts = lazer_counts,
            }, achievements_json);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &.{});
        };
        if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/beatmaps")) {
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            const ids = lazer.queryIds(self.allocator, target, 50) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap ids\"}", &.{});
            defer self.allocator.free(ids);
            var output: std.Io.Writer.Allocating = .init(self.allocator);
            defer output.deinit();
            try output.writer.writeAll("{\"beatmaps\":[");
            var written: usize = 0;
            for (ids) |id| {
                var found = try self.store.lazerBeatmapLookup(self.allocator, id, null);
                if (found == null) {
                    _ = self.map_sync.ensureByBeatmapId(&self.store, id, null) catch |err|
                        std.log.warn("event=lazer_beatmap_batch_hydration_failed beatmap_id={d} error={t}", .{ id, err });
                    found = try self.store.lazerBeatmapLookup(self.allocator, id, null);
                }
                const beatmap = found orelse continue;
                defer self.allocator.free(beatmap);
                if (written != 0) try output.writer.writeByte(',');
                written += 1;
                try output.writer.writeAll(beatmap);
            }
            try output.writer.writeAll("],\"cursor\":null}");
            return respond(req, .ok, "application/json", output.written(), &.{});
        }
        if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/beatmaps/lookup")) {
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            const checksum = queryField(target, "checksum");
            if (checksum) |value| if (!lazer.validHash(value)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid checksum\"}", &.{});
            const beatmap_id: ?i32 = if (queryField(target, "id")) |value| std.fmt.parseInt(i32, value, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap id\"}", &.{}) else null;
            if (beatmap_id) |value| if (value <= 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap id\"}", &.{});
            if (checksum == null and beatmap_id == null) return respond(req, .bad_request, "application/json", "{\"error\":\"beatmap lookup required\"}", &.{});
            if (queryField(target, "filename")) |filename| if (filename.len > 1024) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid filename\"}", &.{});
            var found = try self.store.lazerBeatmapLookup(self.allocator, beatmap_id, checksum);
            if (found == null) if (beatmap_id) |id| {
                _ = self.map_sync.ensureByBeatmapId(&self.store, id, checksum) catch |err|
                    std.log.warn("event=lazer_beatmap_lookup_hydration_failed beatmap_id={d} error={t}", .{ id, err });
                found = try self.store.lazerBeatmapLookup(self.allocator, id, null);
            };
            const response = found orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap not found\"}", &.{});
            defer self.allocator.free(response);
            return respond(req, .ok, "application/json", response, &.{});
        }
        if (req.head.method == .GET) if (lazer.parseRankingPath(path)) |ranking_path| {
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            const page = std.fmt.parseInt(u16, queryField(target, "page") orelse "1", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid page\"}", &.{});
            if (page == 0 or page > 200) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid page\"}", &.{});
            var country_buffer: [2]u8 = undefined;
            var country_filter: ?[]const u8 = null;
            if (queryField(target, "country")) |value| {
                if (ranking_path.kind == .country or value.len != 2 or !std.ascii.isAlphabetic(value[0]) or !std.ascii.isAlphabetic(value[1])) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid country\"}", &.{});
                country_buffer = .{ std.ascii.toUpper(value[0]), std.ascii.toUpper(value[1]) };
                country_filter = &country_buffer;
            }
            const json = try self.store.lazerRankingsJson(self.allocator, ranking_path.ruleset_id, ranking_path.kind, country_filter, page);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &.{});
        };
        if (req.head.method == .GET) if (lazer.parseLeaderboardPath(path)) |leaderboard_path| {
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            const ruleset_id = lazerRulesetId(queryField(target, "mode") orelse "osu") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid mode\"}", &.{});
            const raw_limit = std.fmt.parseInt(u16, queryField(target, "limit") orelse "50", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid limit\"}", &.{});
            if (raw_limit == 0 or raw_limit > 100) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid limit\"}", &.{});
            const scope = queryField(target, "type") orelse "global";
            if (!std.mem.eql(u8, scope, "global") and !std.mem.eql(u8, scope, "country") and !std.mem.eql(u8, scope, "friend")) return respond(req, .bad_request, "application/json", "{\"error\":\"unsupported leaderboard scope\"}", &.{});
            const mod_filter = lazer.leaderboardModFilter(self.allocator, target) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid leaderboard mods\"}", &.{});
            defer mod_filter.deinit(self.allocator);
            const json = try self.store.lazerLeaderboardJson(self.allocator, user.id, leaderboard_path.beatmap_id, ruleset_id, lazerLeaderboardNamespace(target), mod_filter.exact_json, mod_filter.selected, mod_filter.classic, mod_filter.stable_bits, @intCast(raw_limit));
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &.{});
        };
        if (lazer.parseSoloScorePath(path)) |solo_path| {
            const auth = auth_owned orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            if (!std.mem.startsWith(u8, auth, "Bearer ")) return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            const user = (try self.store.authenticateToken(self.allocator, auth[7..], "scores:write")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"restricted\"}", &.{});

            if (solo_path.token_id == null and req.head.method == .POST) {
                const version_hash = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"version_hash"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"version_hash required\"}", &.{});
                defer self.allocator.free(version_hash);
                const beatmap_hash = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"beatmap_hash"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"beatmap_hash required\"}", &.{});
                defer self.allocator.free(beatmap_hash);
                const ruleset_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"ruleset_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"ruleset_id required\"}", &.{});
                defer self.allocator.free(ruleset_text);
                if (!lazer.validHash(version_hash) or !lazer.validHash(beatmap_hash)) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid score token hashes\"}", &.{});
                const ruleset_id = std.fmt.parseInt(i64, ruleset_text, 10) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid ruleset_id\"}", &.{});
                if (ruleset_id < 0 or ruleset_id > 3) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid ruleset_id\"}", &.{});
                const pp_ready = self.map_sync.ensureFileByBeatmapId(&self.store, solo_path.beatmap_id, beatmap_hash) catch |err| {
                    if (err == error.BeatmapHashMismatch) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"beatmap hash mismatch\"}", &.{});
                    std.log.warn("event=lazer_score_token_hydration_failed beatmap_id={d} error={t}", .{ solo_path.beatmap_id, err });
                    return respond(req, .service_unavailable, "application/json", "{\"error\":\"beatmap payload unavailable\"}", &.{});
                };
                if (!pp_ready) return respond(req, .service_unavailable, "application/json", "{\"error\":\"beatmap payload unavailable\"}", &.{});
                const token_id = self.store.createLazerScoreToken(user.id, solo_path.beatmap_id, beatmap_hash, ruleset_id, version_hash) catch |err| return switch (err) {
                    error.BeatmapNotFound => respond(req, .not_found, "application/json", "{\"error\":\"beatmap not found\"}", &.{}),
                    error.BeatmapHashMismatch => respond(req, .unprocessable_entity, "application/json", "{\"error\":\"beatmap hash mismatch\"}", &.{}),
                    else => respond(req, .internal_server_error, "application/json", "{\"error\":\"score token unavailable\"}", &.{}),
                };
                var out: [96]u8 = undefined;
                const json = try std.fmt.bufPrint(&out, "{{\"id\":{d}}}", .{token_id});
                return respond(req, .created, "application/json", json, &.{});
            }
            if (solo_path.token_id) |token_id| {
                if (req.head.method != .PUT) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
                const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_json\"}", &.{});
                defer parsed.deinit();
                var score = lazer.parseSoloScore(parsed.value, solo_path.beatmap_id) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid_score_or_mod\"}", &.{});
                const replay_data = lazer.decodeReplay(self.allocator, parsed.value.object, score.ruleset_id) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid_replay\"}", &.{});
                defer self.allocator.free(replay_data);
                const mods_json = try lazer.jsonField(self.allocator, parsed.value.object, "mods", "[]");
                defer self.allocator.free(mods_json);
                const statistics_json = try lazer.jsonField(self.allocator, parsed.value.object, "statistics", "{}");
                defer self.allocator.free(statistics_json);
                const maximum_statistics_json = try lazer.jsonField(self.allocator, parsed.value.object, "maximum_statistics", "{}");
                defer self.allocator.free(maximum_statistics_json);
                const pauses_json = try lazer.jsonField(self.allocator, parsed.value.object, "pauses", "[]");
                defer self.allocator.free(pauses_json);
                const pp_ready = self.map_sync.ensureFileByBeatmapId(&self.store, solo_path.beatmap_id, null) catch |err| {
                    std.log.warn("event=lazer_score_submit_hydration_failed beatmap_id={d} token_id={d} error={t}", .{ solo_path.beatmap_id, token_id, err });
                    return respond(req, .service_unavailable, "application/json", "{\"error\":\"beatmap payload unavailable\"}", &.{});
                };
                if (!pp_ready) return respond(req, .service_unavailable, "application/json", "{\"error\":\"beatmap payload unavailable\"}", &.{});
                const performance = lazerPerformance(self.allocator, &self.store, score, mods_json) catch |err| {
                    std.log.warn("event=lazer_score_performance_failed beatmap_id={d} token_id={d} error={t}", .{ solo_path.beatmap_id, token_id, err });
                    return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"performance calculation failed\"}", &.{});
                };
                score.achievement_stars = performance.stars;
                score.achievement_mods = performance.mods;
                score.achievement_perfect = performance.max_combo > 0 and score.max_combo >= performance.max_combo;
                const score_id = self.store.submitLazerScoreToken(user.id, solo_path.beatmap_id, token_id, score, performance.pp, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data) catch |err| return switch (err) {
                    error.InvalidLazerScoreToken, error.ForeignLazerScoreToken, error.LazerScoreTokenExpired => respond(req, .unauthorized, "application/json", "{\"error\":\"invalid or expired score token\"}", &.{}),
                    error.LazerScoreTokenUsed => respond(req, .conflict, "application/json", "{\"error\":\"score token already used\"}", &.{}),
                    error.LazerScoreTokenMismatch => respond(req, .unprocessable_entity, "application/json", "{\"error\":\"score token does not match submission\"}", &.{}),
                    else => respond(req, .internal_server_error, "application/json", "{\"error\":\"score submission failed\"}", &.{}),
                };
                const placement = self.afterLazerScore(user, score_id, score, performance.pp, mods_json);
                const json = try self.lazerScoreResponse(user.id, score_id, placement);
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &.{});
            }
            return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        }
        if (lazer_multiplayer.parseRoomScorePath(path)) |room_score_path| {
            const auth = auth_owned orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            if (!std.mem.startsWith(u8, auth, "Bearer ")) return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            const required_scope: []const u8 = if (req.head.method == .GET) "identify" else "scores:write";
            const user = (try self.store.authenticateToken(self.allocator, auth[7..], required_scope)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"restricted\"}", &.{});
            const score_context = self.lazer_multiplayer.scoreContext(user.id, room_score_path.room_id, room_score_path.playlist_item_id) orelse return respond(req, .not_found, "application/json", "{\"error\":\"room or playlist item not found\"}", &.{});

            if (room_score_path.token_id == null and req.head.method == .GET) {
                const board_json = try self.store.lazerLeaderboardJson(self.allocator, user.id, score_context.beatmap_id, score_context.ruleset_id, .vanilla, "[]", false, false, 0, 100);
                defer self.allocator.free(board_json);
                const parsed_board = std.json.parseFromSlice(std.json.Value, self.allocator, board_json, .{}) catch return respond(req, .internal_server_error, "application/json", "{\"error\":\"room scores unavailable\"}", &.{});
                defer parsed_board.deinit();
                const board = switch (parsed_board.value) {
                    .object => |object| object,
                    else => return respond(req, .internal_server_error, "application/json", "{\"error\":\"room scores unavailable\"}", &.{}),
                };
                const scores = board.get("scores") orelse return respond(req, .internal_server_error, "application/json", "{\"error\":\"room scores unavailable\"}", &.{});
                const score_count: i64 = if (board.get("score_count")) |value| switch (value) {
                    .integer => |integer| integer,
                    else => 0,
                } else 0;
                var output: std.Io.Writer.Allocating = .init(self.allocator);
                defer output.deinit();
                try output.writer.writeAll("{\"scores\":");
                try std.json.Stringify.value(scores, .{}, &output.writer);
                try output.writer.print(",\"total\":{d},\"user_score\":", .{score_count});
                if (board.get("user_score")) |own| switch (own) {
                    .object => |object| if (object.get("score")) |score| try std.json.Stringify.value(score, .{}, &output.writer) else try output.writer.writeAll("null"),
                    else => try output.writer.writeAll("null"),
                } else try output.writer.writeAll("null");
                try output.writer.writeAll(",\"params\":{},\"cursor_string\":null}");
                return respond(req, .ok, "application/json", output.written(), &.{.{ .name = "cache-control", .value = "no-store" }});
            }

            if (room_score_path.token_id == null and req.head.method == .POST) {
                const version_hash = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"version_hash"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"version_hash required\"}", &.{});
                defer self.allocator.free(version_hash);
                const beatmap_hash = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"beatmap_hash"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"beatmap_hash required\"}", &.{});
                defer self.allocator.free(beatmap_hash);
                const beatmap_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"beatmap_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"beatmap_id required\"}", &.{});
                defer self.allocator.free(beatmap_text);
                const ruleset_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"ruleset_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"ruleset_id required\"}", &.{});
                defer self.allocator.free(ruleset_text);
                const beatmap_id = std.fmt.parseInt(i32, beatmap_text, 10) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid beatmap_id\"}", &.{});
                const ruleset_id = std.fmt.parseInt(u8, ruleset_text, 10) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid ruleset_id\"}", &.{});
                if (beatmap_id != score_context.beatmap_id or ruleset_id != score_context.ruleset_id or !lazer.validHash(version_hash) or !lazer.validHash(beatmap_hash)) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"score token does not match room\"}", &.{});
                const pp_ready = self.map_sync.ensureFileByBeatmapId(&self.store, beatmap_id, beatmap_hash) catch |err| {
                    std.log.warn("event=lazer_room_score_token_hydration_failed room_id={d} beatmap_id={d} error={t}", .{ room_score_path.room_id, beatmap_id, err });
                    return respond(req, .service_unavailable, "application/json", "{\"error\":\"beatmap payload unavailable\"}", &.{});
                };
                if (!pp_ready) return respond(req, .service_unavailable, "application/json", "{\"error\":\"beatmap payload unavailable\"}", &.{});
                const token_id = self.store.createLazerScoreToken(user.id, beatmap_id, beatmap_hash, ruleset_id, version_hash) catch return respond(req, .internal_server_error, "application/json", "{\"error\":\"score token unavailable\"}", &.{});
                var out: [96]u8 = undefined;
                const json = try std.fmt.bufPrint(&out, "{{\"id\":{d}}}", .{token_id});
                return respond(req, .created, "application/json", json, &.{});
            }

            if (room_score_path.token_id) |token_id| {
                if (req.head.method != .PUT) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
                const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_json\"}", &.{});
                defer parsed.deinit();
                var score = lazer.parseSoloScore(parsed.value, score_context.beatmap_id) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid_score_or_mod\"}", &.{});
                const replay_data = lazer.decodeReplay(self.allocator, parsed.value.object, score.ruleset_id) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid_replay\"}", &.{});
                defer self.allocator.free(replay_data);
                const mods_json = try lazer.jsonField(self.allocator, parsed.value.object, "mods", "[]");
                defer self.allocator.free(mods_json);
                const statistics_json = try lazer.jsonField(self.allocator, parsed.value.object, "statistics", "{}");
                defer self.allocator.free(statistics_json);
                const maximum_statistics_json = try lazer.jsonField(self.allocator, parsed.value.object, "maximum_statistics", "{}");
                defer self.allocator.free(maximum_statistics_json);
                const pauses_json = try lazer.jsonField(self.allocator, parsed.value.object, "pauses", "[]");
                defer self.allocator.free(pauses_json);
                const performance = lazerPerformance(self.allocator, &self.store, score, mods_json) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"performance calculation failed\"}", &.{});
                score.achievement_stars = performance.stars;
                score.achievement_mods = performance.mods;
                score.achievement_perfect = performance.max_combo > 0 and score.max_combo >= performance.max_combo;
                const score_id = self.store.submitLazerScoreToken(user.id, score_context.beatmap_id, token_id, score, performance.pp, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data) catch |err| return switch (err) {
                    error.InvalidLazerScoreToken, error.ForeignLazerScoreToken, error.LazerScoreTokenExpired => respond(req, .unauthorized, "application/json", "{\"error\":\"invalid or expired score token\"}", &.{}),
                    error.LazerScoreTokenUsed => respond(req, .conflict, "application/json", "{\"error\":\"score token already used\"}", &.{}),
                    error.LazerScoreTokenMismatch => respond(req, .unprocessable_entity, "application/json", "{\"error\":\"score token does not match submission\"}", &.{}),
                    else => respond(req, .internal_server_error, "application/json", "{\"error\":\"score submission failed\"}", &.{}),
                };
                const placement = self.afterLazerScore(user, score_id, score, performance.pp, mods_json);
                self.lazer_multiplayer.recordRoomScore(user.id, room_score_path.room_id, room_score_path.playlist_item_id, .{
                    .total_score = score.legacy_total_score orelse score.total_score,
                    .accuracy = score.accuracy,
                    .max_combo = @intCast(score.max_combo),
                    .passed = score.passed,
                }) catch |err| std.log.warn("event=lazer_matchmaking_score_state_failed room_id={d} playlist_item_id={d} user_id={d} score_id={d} error={t}", .{ room_score_path.room_id, room_score_path.playlist_item_id, user.id, score_id, err });
                const json = try self.lazerScoreResponse(user.id, score_id, placement);
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &.{});
            }
            return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        }
        if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/beatmapsets/search")) {
            const auth = auth_owned orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            if (!std.mem.startsWith(u8, auth, "Bearer ")) return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            const user = (try self.store.authenticateToken(self.allocator, auth[7..], "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            const mode = std.fmt.parseInt(i8, queryField(target, "m") orelse "-1", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid mode\"}", &.{});
            const offset = std.fmt.parseInt(u16, queryField(target, "offset") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid offset\"}", &.{});
            if (mode < -1 or mode > 3 or offset > 10_000) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid search\"}", &.{});
            const encoded_query = queryField(target, "q") orelse "";
            const query_buf = try self.allocator.dupe(u8, encoded_query);
            defer self.allocator.free(query_buf);
            for (query_buf) |*char| {
                if (char.* == '+') char.* = ' ';
            }
            const query = std.Uri.percentDecodeInPlace(query_buf);
            const upstream_ids: ?[]i32 = self.map_sync.searchSets(&self.store, query, mode, offset) catch |err| failed: {
                std.log.warn("event=lazer_beatmap_search_upstream_failed mode={d} offset={d} error={t}", .{ mode, offset, err });
                break :failed null;
            };
            defer if (upstream_ids) |ids| self.allocator.free(ids);
            const listing = if (upstream_ids) |ids|
                try self.store.lazerBeatmapSets(self.allocator, ids)
            else
                try self.store.lazerBeatmapSearch(self.allocator, query, mode, offset);
            defer self.allocator.free(listing);
            return respond(req, .ok, "application/json", listing, &.{});
        }
        if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/beatmapsets/lookup")) {
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            const map_text = queryField(target, "beatmap_id") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"beatmap id required\"}", &.{});
            const map_id = std.fmt.parseInt(i32, map_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap id\"}", &.{});
            if (map_id <= 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap id\"}", &.{});
            var set_id = try self.store.beatmapSetIdForMap(map_id);
            if (set_id == null) {
                _ = self.map_sync.ensureByBeatmapId(&self.store, map_id, null) catch |err|
                    std.log.warn("event=lazer_beatmap_set_lookup_hydration_failed beatmap_id={d} error={t}", .{ map_id, err });
                set_id = try self.store.beatmapSetIdForMap(map_id);
            }
            const resolved_set_id = set_id orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap set not found\"}", &.{});
            const listing = (try self.store.lazerBeatmapSet(self.allocator, resolved_set_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap set not found\"}", &.{});
            defer self.allocator.free(listing);
            return respond(req, .ok, "application/json", listing, &.{});
        }
        if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v2/beatmapsets/") and !std.mem.endsWith(u8, path, "/download")) {
            const set_id = std.fmt.parseInt(i32, path["/api/v2/beatmapsets/".len..], 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap set\"}", &.{});
            if (set_id <= 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap set\"}", &.{});
            const auth = auth_owned orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            if (!std.mem.startsWith(u8, auth, "Bearer ")) return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            const user = (try self.store.authenticateToken(self.allocator, auth[7..], "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            var listing = try self.store.lazerBeatmapSet(self.allocator, set_id);
            if (listing == null) {
                _ = self.map_sync.ensureBySetId(&self.store, set_id) catch |err|
                    std.log.warn("event=lazer_beatmap_set_hydration_failed set_id={d} error={t}", .{ set_id, err });
                listing = try self.store.lazerBeatmapSet(self.allocator, set_id);
            }
            const response = listing orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap set not found\"}", &.{});
            defer self.allocator.free(response);
            return respond(req, .ok, "application/json", response, &.{});
        }
        if (std.mem.eql(u8, path, "/api/v2/me")) {
            const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, user);
            const stats = try self.lazerStats(user.id);
            const achievements_json = try self.store.lazerUserAchievementsJson(self.allocator, user.id);
            defer self.allocator.free(achievements_json);
            const json = try user_json.meOwned(self.allocator, user, stats, achievements_json, std.Io.Clock.real.now(self.sessions.io).toSeconds());
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &.{});
        }
        if (std.mem.eql(u8, path, "/api/v2/scores") and req.head.method == .POST) {
            const auth = auth_owned orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            if (!std.mem.startsWith(u8, auth, "Bearer ")) return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            const user = (try self.store.authenticateToken(self.allocator, auth[7..], "scores:write")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_json\"}", &.{});
            defer parsed.deinit();
            var score = lazer.parseScore(parsed.value) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid_score_or_mod\"}", &.{});
            const mods_json = try lazer.jsonField(self.allocator, parsed.value.object, "mods", "[]");
            defer self.allocator.free(mods_json);
            const statistics_json = try lazer.jsonField(self.allocator, parsed.value.object, "statistics", "{}");
            defer self.allocator.free(statistics_json);
            const maximum_statistics_json = try lazer.jsonField(self.allocator, parsed.value.object, "maximum_statistics", "{}");
            defer self.allocator.free(maximum_statistics_json);
            const pauses_json = try lazer.jsonField(self.allocator, parsed.value.object, "pauses", "[]");
            defer self.allocator.free(pauses_json);
            const ns_name = @tagName(score.namespace);
            const pp_ready = self.map_sync.ensureFileByBeatmapId(&self.store, @intCast(score.beatmap_id), null) catch |err| {
                std.log.warn("event=lazer_legacy_score_hydration_failed beatmap_id={d} error={t}", .{ score.beatmap_id, err });
                return respond(req, .service_unavailable, "application/json", "{\"error\":\"beatmap payload unavailable\"}", &.{});
            };
            if (!pp_ready) return respond(req, .service_unavailable, "application/json", "{\"error\":\"beatmap payload unavailable\"}", &.{});
            const performance = lazerPerformance(self.allocator, &self.store, score, mods_json) catch |err| {
                std.log.warn("event=lazer_legacy_score_performance_failed beatmap_id={d} error={t}", .{ score.beatmap_id, err });
                return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"performance calculation failed\"}", &.{});
            };
            score.achievement_stars = performance.stars;
            score.achievement_mods = performance.mods;
            score.achievement_perfect = performance.max_combo > 0 and score.max_combo >= performance.max_combo;
            const id = try self.store.insertLazerScore(user.id, score, performance.pp, mods_json, statistics_json, maximum_statistics_json, pauses_json, &.{});
            self.lazer_spectator.scoreProcessed(user.id, id);
            var out: [192]u8 = undefined;
            const json = try std.fmt.bufPrint(&out, "{{\"id\":{d},\"user_id\":{d},\"rank_namespace\":\"{s}\",\"ranked\":true}}", .{ id, user.id, ns_name });
            return respond(req, .created, "application/json", json, &.{});
        }
        if (std.mem.eql(u8, path, "/") and req.head.method == .POST) {
            if (osu_token_owned) |token| {
                const bytes = (try bancho.pollByToken(self.allocator, &self.store, &self.sessions, token, body)) orelse {
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
            var result = try bancho.login(self.allocator, &self.store, &self.sessions, body, if (country_owned) |value| country.normalized(value) else null, geo.lon, geo.lat);
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
            const hq_flags: u32 = (@as(u32, 1) << 17) | (@as(u32, 1) << 18);
            if (flags & hq_flags != 0) {
                _ = try self.store.restrictForClientFlag(user.id, flags);
                bancho.disconnectRestrictedUser(self.allocator, &self.sessions, user.id);
            }
            const hq_or_registry: u32 = hq_flags | (@as(u32, 1) << 19);
            return respond(req, .ok, "text/plain", if (flags & hq_or_registry != 0) "-3" else "", &.{});
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
            if (!stable_score.replayLengthAccepted(score.passed, replay.data.len)) {
                return rejectStableScore(req, if (replay.data.len == 0) "passed_score_missing_replay" else "replay_too_large", body.len);
            }
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
            switch (self.sessions.authorizeScoreToken(score_token_owned, user.id)) {
                .exact, .stale_online => {},
                .missing => {
                    std.log.warn("stable score rejected: reason=missing_session_token body_bytes={d}", .{body.len});
                    return respond(req, .unauthorized, "text/plain", "", &.{});
                },
                .foreign_live => {
                    std.log.warn("stable score rejected: reason=foreign_session_token user_id={d} body_bytes={d}", .{ user.id, body.len });
                    return respond(req, .unauthorized, "text/plain", "", &.{});
                },
                .offline => {
                    std.log.warn("stable score rejected: reason=inactive_session body_bytes={d}", .{body.len});
                    return respond(req, .ok, "text/plain", "error: no", &.{});
                },
            }
            if (!score.verifyChecksum(osu_version, decrypted.client_hash, storyboard_hash)) return rejectStableScore(req, "checksum_mismatch", body.len);
            const map_file = (try self.store.beatmapFile(self.allocator, score.map_md5)) orelse return respond(req, .ok, "text/plain", "error: beatmap", &.{});
            defer self.allocator.free(map_file);
            const performance = pp.calculate(map_file, .{
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
            if (has_replay_fingerprint) self.store.recordReplayFingerprint(user.id, score_id, &replay_digest) catch |err| {
                std.log.warn("event=anticheat_replay_fingerprint_write_failed score_id={d} error={t}", .{ score_id, err });
            };
            const replay_match_count = if (has_replay_fingerprint) self.store.crossAccountReplayMatches(user.id, &replay_digest) catch |err| blk: {
                std.log.warn("event=anticheat_replay_match_lookup_failed user_id={d} error={t}", .{ user.id, err });
                break :blk 0;
            } else 0;
            const anticheat_observation = self.observeStableGameplay(user.id, score, replay.data, map_file, performance, elapsed_ms, replay_match_count);
            if (anticheat_observation) |observation| {
                const allow_sample = observation.decision.action == anticheat_abi.Action.allow and self.anticheat_allow_sample_modulus != 0 and @mod(score_id, @as(i64, self.anticheat_allow_sample_modulus)) == 0;
                if (observation.decision.action != anticheat_abi.Action.allow or allow_sample) self.persistAnticheatObservation(user.id, score_id, if (allow_sample) self.anticheat_allow_sample_modulus else 1, stableGameplayEvidence(score, replay_match_count), replay_match_count, observation);
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
            const replay = (try self.store.replay(self.allocator, score_id)) orelse return respond(req, .not_found, "text/plain", "", &.{});
            defer self.allocator.free(replay);
            return respond(req, .ok, "application/octet-stream", replay, &.{});
        }
        const known_website_page = routing.websitePage(path);
        if (req.head.method == .GET and (known_website_page or (web_auth.websiteHost(host_owned) and routing.websiteFallback(path)))) {
            if ((std.mem.eql(u8, path, "/staff") or std.mem.eql(u8, path, "/appeal")) and !web_auth.websiteHost(host_owned)) return respond(req, .not_found, "application/json", "{\"error\":\"not found\"}", &.{});
            const headers = [_]std.http.Header{
                .{ .name = "cache-control", .value = "no-cache" },
                .{ .name = "content-security-policy", .value = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' https://a.kai.ovh https://assets.ppy.sh; media-src 'self'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
            };
            return respond(req, if (known_website_page) .ok else .not_found, "text/html; charset=utf-8", status_page, &headers);
        }
        return respond(req, .not_found, "application/json", "{\"error\":\"not found\"}", &.{});
    }
};

const PosixAddress = extern union {
    any: std.posix.sockaddr,
    in: std.posix.sockaddr.in,
    in6: std.posix.sockaddr.in6,
};

fn peerIp(stream: std.Io.net.Stream, buffer: []u8) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) return null;
    var address: PosixAddress = undefined;
    var address_len: std.posix.socklen_t = @sizeOf(PosixAddress);
    std.posix.getpeername(stream.socket.handle, &address.any, &address_len) catch return null;
    return switch (address.any.family) {
        std.posix.AF.INET => blk: {
            const bytes: [4]u8 = @bitCast(address.in.addr);
            break :blk std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] }) catch null;
        },
        std.posix.AF.INET6 => blk: {
            const bytes = address.in6.addr;
            if (std.mem.eql(u8, bytes[0..12], &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
                break :blk std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{ bytes[12], bytes[13], bytes[14], bytes[15] }) catch null;
            }
            break :blk std.fmt.bufPrint(buffer, "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{
                std.mem.readInt(u16, bytes[0..2], .big),
                std.mem.readInt(u16, bytes[2..4], .big),
                std.mem.readInt(u16, bytes[4..6], .big),
                std.mem.readInt(u16, bytes[6..8], .big),
                std.mem.readInt(u16, bytes[8..10], .big),
                std.mem.readInt(u16, bytes[10..12], .big),
                std.mem.readInt(u16, bytes[12..14], .big),
                std.mem.readInt(u16, bytes[14..16], .big),
            }) catch null;
        },
        else => null,
    };
}

fn serveConnection(app: *App, stream_value: std.Io.net.Stream, io: std.Io) void {
    var stream = stream_value;
    defer stream.close(io);
    var peer_buffer: [64]u8 = undefined;
    const peer_ip = peerIp(stream, &peer_buffer);
    var recv: [64 * 1024]u8 = undefined;
    var send: [64 * 1024]u8 = undefined;
    var cr = stream.reader(io, &recv);
    var cw = stream.writer(io, &send);
    var server: std.http.Server = .init(&cr.interface, &cw.interface);
    var req = server.receiveHead() catch return;
    app.serve(&req, peer_ip) catch |err| std.log.err("request failed: {t}", .{err});
}

fn recalcAllScores(allocator: std.mem.Allocator, store: *sqlite_storage.Store) !void {
    const c = sqlite_storage.c;
    std.debug.print("recalculating all scores with zigcho pp {s}...\n", .{pp.engine_version});
    const scores_sql = "SELECT id,user_id,map_md5,mode,mods,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,score FROM scores WHERE passed=1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(store.db, scores_sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    var count: u32 = 0;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const id = c.sqlite3_column_int64(stmt, 0);
        const map_md5 = std.mem.span(c.sqlite3_column_text(stmt, 2));
        const mode: u8 = @intCast(c.sqlite3_column_int(stmt, 3));
        const mods = c.sqlite3_column_int(stmt, 4);
        const max_combo: u32 = @intCast(c.sqlite3_column_int(stmt, 5));
        const n300: u32 = @intCast(c.sqlite3_column_int(stmt, 6));
        const n100: u32 = @intCast(c.sqlite3_column_int(stmt, 7));
        const n50: u32 = @intCast(c.sqlite3_column_int(stmt, 8));
        const nmiss: u32 = @intCast(c.sqlite3_column_int(stmt, 9));
        const ngeki: u32 = @intCast(c.sqlite3_column_int(stmt, 10));
        const nkatu: u32 = @intCast(c.sqlite3_column_int(stmt, 11));
        const total_score: u32 = @intCast(c.sqlite3_column_int64(stmt, 12));
        const md5_copy = try allocator.dupe(u8, map_md5);
        defer allocator.free(md5_copy);
        const map_file = (try store.beatmapFile(allocator, md5_copy)) orelse {
            std.debug.print("  score {d}: no .osu file, skipping\n", .{id});
            continue;
        };
        defer allocator.free(map_file);
        const result = pp.calculate(map_file, .{
            .mode = mode,
            .lazer = 0,
            .mods = @intCast(mods),
            .max_combo = max_combo,
            .n_geki = ngeki,
            .n_katu = nkatu,
            .n300 = n300,
            .n100 = n100,
            .n50 = n50,
            .misses = nmiss,
            .legacy_total_score = total_score,
        }) catch {
            std.debug.print("  score {d}: pp calc failed, skipping\n", .{id});
            continue;
        };
        const update_sql = "UPDATE scores SET pp=?1 WHERE id=?2";
        var up: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(store.db, update_sql, -1, &up, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_double(up, 1, result.pp);
        _ = c.sqlite3_bind_int64(up, 2, id);
        if (c.sqlite3_step(up) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        _ = c.sqlite3_finalize(up);
        std.debug.print("  score {d}: pp={d:.2} stars={d:.2}\n", .{ id, result.pp, result.stars });
        count += 1;
    }
    std.debug.print("recalculated {d} scores. rebuilding stats...\n", .{count});
    try store.exec("BEGIN IMMEDIATE");
    try recalcStats(store);
    try store.exec("COMMIT");
    std.debug.print("done.\n", .{});
}

fn recalcStats(store: *sqlite_storage.Store) !void {
    const c = sqlite_storage.c;
    const modes_sql = "SELECT DISTINCT user_id,mode FROM stats";
    var m_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(store.db, modes_sql, -1, &m_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(m_stmt);
    while (c.sqlite3_step(m_stmt) == c.SQLITE_ROW) {
        const uid = c.sqlite3_column_int(m_stmt, 0);
        const stats_mode = c.sqlite3_column_int(m_stmt, 1);
        const vanilla_mode: i32 = switch (stats_mode) {
            0, 1, 2, 3 => stats_mode,
            4, 5, 6 => stats_mode - 4,
            8 => 0,
            else => continue,
        };
        const namespace: ?[]const u8 = switch (stats_mode) {
            0, 1, 2, 3 => "vanilla",
            4, 5, 6 => "relax",
            8 => "autopilot",
            else => null,
        };
        if (namespace == null) continue;
        const ns = namespace.?;
        const pp_sql = "SELECT s.pp,s.accuracy FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=?1 AND s.mode=?2 AND s.passed=1 AND s.best=1 AND s.rank_namespace=?3 AND b.status IN (3,4) ORDER BY s.pp DESC,s.id ASC";
        var pp_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(store.db, pp_sql, -1, &pp_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(pp_stmt);
        _ = c.sqlite3_bind_int(pp_stmt, 1, uid);
        _ = c.sqlite3_bind_int(pp_stmt, 2, vanilla_mode);
        _ = c.sqlite3_bind_text(pp_stmt, 3, ns.ptr, @intCast(ns.len), null);
        var total_pp: f64 = 0;
        var weighted_accuracy: f64 = 0;
        var weight: f64 = 1;
        var score_count: u32 = 0;
        while (c.sqlite3_step(pp_stmt) == c.SQLITE_ROW) {
            total_pp += c.sqlite3_column_double(pp_stmt, 0) * weight;
            weighted_accuracy += c.sqlite3_column_double(pp_stmt, 1) * weight;
            weight *= 0.95;
            score_count += 1;
        }
        const bonus_pp = 416.6667 * (1.0 - std.math.pow(f64, 0.9994, @floatFromInt(score_count)));
        const bonus_accuracy = if (score_count > 0) 1.0 / (20.0 * (1.0 - std.math.pow(f64, 0.95, @floatFromInt(score_count)))) else 0;
        const set_sql = "UPDATE stats SET pp=?1,accuracy=?2 WHERE user_id=?3 AND mode=?4";
        var set_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(store.db, set_sql, -1, &set_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int64(set_stmt, 1, @intFromFloat(@round(total_pp + bonus_pp)));
        _ = c.sqlite3_bind_double(set_stmt, 2, weighted_accuracy * bonus_accuracy);
        _ = c.sqlite3_bind_int(set_stmt, 3, uid);
        _ = c.sqlite3_bind_int(set_stmt, 4, stats_mode);
        if (c.sqlite3_step(set_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        _ = c.sqlite3_finalize(set_stmt);
        std.debug.print("  user {d} mode {d} ({s}): pp={d}\n", .{ uid, stats_mode, ns, @round(total_pp + bonus_pp) });
    }
}

fn configuredObjectStore(config: config_mod.Config) r2.Storage {
    return .{
        .endpoint = config.object_storage_endpoint,
        .bucket = config.object_storage_bucket,
        .access_key_id = config.object_storage_access_key_id,
        .secret_access_key = config.object_storage_secret_access_key,
        .region = config.object_storage_region,
    };
}

fn configuredLegacyAvatarStore(config: config_mod.Config) r2.Storage {
    return .{
        .endpoint = config.avatar_r2_endpoint,
        .bucket = config.avatar_r2_bucket,
        .access_key_id = config.avatar_r2_access_key_id,
        .secret_access_key = config.avatar_r2_secret_access_key,
    };
}

const AvatarObjectMigrationStats = struct { migrated: i64 = 0, failed: i64 = 0 };

fn migrateAvatarObjects(allocator: std.mem.Allocator, store: *storage.Store, source: r2.Storage, target: r2.Storage) !AvatarObjectMigrationStats {
    const user_ids = try store.customAvatarUserIds(allocator);
    defer allocator.free(user_ids);
    var stats: AvatarObjectMigrationStats = .{};
    for (user_ids) |user_id| {
        var avatar = (try store.customAvatarForUser(allocator, user_id)) orelse continue;
        defer avatar.deinit();
        var target_valid = false;
        if (target.getWithLimit(allocator, store.io, avatar.object_key, avatar.content_type, profile_avatar.max_bytes)) |data| {
            defer allocator.free(data);
            if (profile_avatar.validate(avatar.content_type, data)) |_| {
                target_valid = object_keys.matchesSha256(data, &avatar.etag);
            } else |_| {}
        } else |_| {}
        if (target_valid) {
            stats.migrated += 1;
            continue;
        }
        if (!source.enabled()) {
            stats.failed += 1;
            std.log.warn("event=avatar_object_migration_failed user_id={d} error=source_not_configured", .{user_id});
            continue;
        }
        const data = source.getWithLimit(allocator, store.io, avatar.object_key, avatar.content_type, profile_avatar.max_bytes) catch |err| {
            stats.failed += 1;
            std.log.warn("event=avatar_object_migration_failed user_id={d} error={t}", .{ user_id, err });
            continue;
        };
        defer allocator.free(data);
        _ = profile_avatar.validate(avatar.content_type, data) catch |err| {
            stats.failed += 1;
            std.log.warn("event=avatar_object_migration_failed user_id={d} error={t}", .{ user_id, err });
            continue;
        };
        if (!object_keys.matchesSha256(data, &avatar.etag)) {
            stats.failed += 1;
            std.log.warn("event=avatar_object_migration_failed user_id={d} error=etag_mismatch", .{user_id});
            continue;
        }
        target.put(allocator, store.io, avatar.object_key, avatar.content_type, data) catch |err| {
            stats.failed += 1;
            std.log.warn("event=avatar_object_migration_failed user_id={d} error={t}", .{ user_id, err });
            continue;
        };
        const verified = target.getWithLimit(allocator, store.io, avatar.object_key, avatar.content_type, profile_avatar.max_bytes) catch |err| {
            stats.failed += 1;
            std.log.warn("event=avatar_object_migration_failed user_id={d} error={t}", .{ user_id, err });
            continue;
        };
        defer allocator.free(verified);
        if (!object_keys.matchesSha256(verified, &avatar.etag)) {
            stats.failed += 1;
            std.log.warn("event=avatar_object_migration_failed user_id={d} error=verification_failed", .{user_id});
            continue;
        }
        stats.migrated += 1;
    }
    return stats;
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len > 1 and std.mem.eql(u8, args[1], "check")) {
        if (args.len > 2) return error.UnexpectedCheckArgument;
        const database: [:0]const u8 = if (storage.is_postgres)
            std.mem.span(std.c.getenv("ZIGCHO_POSTGRES_URL") orelse return error.MissingPostgresUrl)
        else
            "zigcho.db";
        var store = try storage.Store.open(allocator, init.io, database);
        defer store.close();
        try store.migrate();
        const kai = (try store.userById(allocator, 3)) orelse return error.SystemBotMissing;
        defer {
            allocator.free(kai.name);
            allocator.free(kai.safe_name);
        }
        if (!std.mem.eql(u8, kai.safe_name, "kai")) return error.InvalidSystemBot;
        const counts = try store.serverCounts();
        std.log.info("event=preflight_ok storage={s} accounts={d} plays={d} passed={d} beatmaps={d}", .{
            if (storage.is_postgres) "postgres" else "sqlite",
            counts.users,
            counts.plays,
            counts.passed,
            counts.maps,
        });
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "object-migrate")) {
        if (storage.is_postgres and args.len > 2) return error.PostgresUrlMustUseEnvironment;
        const database: [:0]const u8 = if (storage.is_postgres)
            std.mem.span(std.c.getenv("ZIGCHO_POSTGRES_URL") orelse return error.MissingPostgresUrl)
        else if (args.len > 2)
            try allocator.dupeZ(u8, args[2])
        else
            "zigcho.db";
        defer if (!storage.is_postgres and args.len > 2) allocator.free(database);
        var store = try storage.Store.open(allocator, init.io, database);
        defer store.close();
        try store.migrate();
        var config = try config_mod.load(allocator, init.io);
        defer config.deinit();
        const object_store = configuredObjectStore(config);
        if (!object_store.enabled()) return error.ObjectStorageNotConfigured;
        store.bindObjectStorage(object_store);
        const maps = try store.migrateBeatmapObjects();
        const avatars = try migrateAvatarObjects(allocator, &store, configuredLegacyAvatarStore(config), object_store);
        std.log.info("event=object_migration_complete archives={d} media={d} avatars={d} failed={d}", .{ maps.archives, maps.media, avatars.migrated, maps.failed + avatars.failed });
        if (maps.failed + avatars.failed != 0) return error.ObjectMigrationIncomplete;
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "object-purge")) {
        if (!storage.is_postgres) return error.ObjectPurgeRequiresPostgres;
        if (args.len > 2) return error.PostgresUrlMustUseEnvironment;
        const database = std.mem.span(std.c.getenv("ZIGCHO_POSTGRES_URL") orelse return error.MissingPostgresUrl);
        var store = try storage.Store.open(allocator, init.io, database);
        defer store.close();
        try store.migrate();
        var config = try config_mod.load(allocator, init.io);
        defer config.deinit();
        const object_store = configuredObjectStore(config);
        if (!object_store.enabled()) return error.ObjectStorageNotConfigured;
        store.bindObjectStorage(object_store);
        const avatars = try migrateAvatarObjects(allocator, &store, configuredLegacyAvatarStore(config), object_store);
        if (avatars.failed != 0) return error.ObjectMigrationIncomplete;
        const purged = try store.purgeBeatmapObjectBackups();
        std.log.info("event=object_purge_complete archives={d} archive_bytes={d} media={d} media_bytes={d} avatars={d}", .{ purged.archives, purged.archive_bytes, purged.media, purged.media_bytes, avatars.migrated });
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "recalc")) {
        if (storage.is_postgres) {
            if (args.len > 2) return error.PostgresUrlMustUseEnvironment;
            const conninfo = std.mem.span(std.c.getenv("ZIGCHO_POSTGRES_URL") orelse return error.MissingPostgresUrl);
            var store = try storage.Store.open(allocator, init.io, conninfo);
            defer store.close();
            try store.migrate();
            const count = try store.recalculatePerformance(allocator);
            std.log.info("event=postgres_pp_recalc_complete scores={d}", .{count});
        } else {
            const db_path: [:0]const u8 = if (args.len > 2) try allocator.dupeZ(u8, args[2]) else "zigcho.db";
            defer if (args.len > 2) allocator.free(db_path);
            var store = try sqlite_storage.Store.open(allocator, init.io, db_path);
            defer store.close();
            try store.migrate();
            try recalcAllScores(allocator, &store);
        }
        return;
    }
    const bind = if (args.len > 1) args[1] else "127.0.0.1";
    const port = if (args.len > 2) try std.fmt.parseInt(u16, args[2], 10) else 8080;
    const default_database: [:0]const u8 = if (storage.is_postgres)
        std.mem.span(std.c.getenv("ZIGCHO_POSTGRES_URL") orelse return error.MissingPostgresUrl)
    else
        "zigcho.db";
    const db_path: [:0]const u8 = if (args.len > 3) try allocator.dupeZ(u8, args[3]) else default_database;
    defer if (args.len > 3) allocator.free(db_path);
    var store = try storage.Store.open(allocator, init.io, db_path);
    defer store.close();
    try store.migrate();
    var config = try config_mod.load(allocator, init.io);
    defer config.deinit();
    const object_store = configuredObjectStore(config);
    store.bindObjectStorage(object_store);
    const anticheat: ?anticheat_plugin.Host = if (config.anticheat_module_path.len == 0)
        null
    else
        anticheat_plugin.Host.open(config.anticheat_module_path) catch |err| blk: {
            std.log.warn("event=anticheat_module_load_failed path={s} error={t}", .{ config.anticheat_module_path, err });
            break :blk null;
        };
    var app: App = .{
        .allocator = allocator,
        .store = store,
        .sessions = sessions_mod.Sessions.init(allocator, init.io),
        .lazer_bot = lazer_bot.Manager.init(allocator, init.io),
        .lazer_multiplayer = lazer_multiplayer.Manager.init(allocator, init.io),
        .lazer_spectator = lazer_spectator.Manager.init(allocator, init.io),
        .limiter = rate_limit.Limiter.init(allocator, init.io),
        .map_sync = beatmap_sync.Sync.init(allocator, init.io, config.beatmap_cache_max_bytes),
        .media_sync = beatmap_media.Sync.init(allocator, init.io, config.beatmap_media_cache_max_bytes),
        .score_webhook = webhook.Webhook.init(allocator, init.io, config.score_webhook),
        .anticheat = anticheat,
        .anticheat_allow_sample_modulus = config.anticheat_allow_sample_modulus,
        .avatar_store = if (object_store.enabled()) object_store else configuredLegacyAvatarStore(config),
        .avatar_cache = avatar_cache.Cache.init(allocator, init.io),
        .geo_client = .{ .allocator = allocator, .io = init.io },
        .started_at = std.Io.Clock.real.now(init.io).toSeconds(),
    };
    var kai = (try app.store.userById(allocator, 3)) orelse return error.SystemBotMissing;
    app.lazer_multiplayer.bindStore(&app.store);
    app.lazer_multiplayer.refreshMatchmakingMaps() catch |err| std.log.warn("event=lazer_matchmaking_pool_startup_failed error={t}", .{err});
    app.lazer_spectator.bindStore(&app.store);
    kai.country = .{ 'I', 'S' };
    const kai_session = try app.sessions.createBot(kai);
    kai_session.longitude = -21.9426; // reykjavik
    kai_session.latitude = 64.1466;
    if (app.anticheat) |*loaded| std.log.info("event=anticheat_module_loaded module={s} abi={d} mode=observe", .{ loaded.name(), anticheat_abi.version });
    defer if (app.anticheat) |*loaded| loaded.close();
    defer app.score_webhook.deinit();
    defer app.avatar_cache.deinit();
    defer app.map_sync.deinit();
    defer app.geo_client.deinit();
    defer app.limiter.deinit();
    defer app.lazer_spectator.deinit();
    defer app.lazer_multiplayer.deinit();
    defer app.lazer_bot.deinit();
    defer app.sessions.deinit();
    const address = try std.Io.net.IpAddress.parse(bind, port);
    var listener = try address.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);
    var connections: std.Io.Group = .init;
    defer connections.cancel(init.io);
    std.log.info("event=server_started bind={s} port={d} storage={s}", .{ bind, port, if (storage.is_postgres) "postgres" else "sqlite" });
    while (true) {
        const stream = listener.accept(init.io) catch |err| {
            std.log.err("accept: {t}", .{err});
            continue;
        };
        connections.concurrent(init.io, serveConnection, .{ &app, stream, init.io }) catch |err| {
            std.log.err("spawn connection: {t}", .{err});
            var rejected = stream;
            rejected.close(init.io);
        };
    }
}
