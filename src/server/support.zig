const d = @import("deps.zig");
const std = d.std;
const domain = d.domain;
const storage = d.storage;
const sessions_mod = d.sessions_mod;
const bancho = d.bancho;
const lazer = d.lazer;
const pp = d.pp;
const pp_admin = d.pp_admin;
const stable_score = d.stable_score;
const stable_mods = d.stable_mods;
const log = d.log;

pub fn healthResponse(buf: []u8, online: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "{{\"ok\":true,\"service\":\"zigcho\",\"online\":{d},\"protocol\":19,\"hotfixes\":true}}", .{online});
}

pub fn freeUser(allocator: std.mem.Allocator, user: domain.User) void {
    allocator.free(user.name);
    allocator.free(user.safe_name);
}

pub fn rollbackFailedLazerLogin(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, user_id: i32, tokens: storage.Store.GameTokenPair) void {
    _ = store.revokeToken(&tokens.access) catch |err| failed: {
        std.log.err("event=lazer_login_token_rollback_failed user_id={d} error={t}", .{ user_id, err });
        break :failed false;
    };
    bancho.publishLazerLogout(allocator, sessions, user_id) catch |err|
        std.log.err("event=lazer_login_presence_rollback_failed user_id={d} error={t}", .{ user_id, err });
}

pub fn randomMessageUuid(io: std.Io) ![36]u8 {
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

pub const TeamPath = struct { id: i32, action: []const u8 = "" };
pub const PinPath = struct { source: storage.ReplaySource, id: i64 };

pub fn parseWebsiteRoomPath(path: []const u8) ?i64 {
    const prefix = "/api/v1/multiplayer/rooms/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const id_text = path[prefix.len..];
    if (id_text.len == 0 or std.mem.indexOfScalar(u8, id_text, '/') != null) return null;
    const id = std.fmt.parseInt(i64, id_text, 10) catch return null;
    return if (id > 0) id else null;
}

pub fn parseTeamPath(path: []const u8, prefix: []const u8) ?TeamPath {
    if (!std.mem.startsWith(u8, path, prefix) or path.len <= prefix.len) return null;
    const tail = path[prefix.len..];
    const slash = std.mem.findScalar(u8, tail, '/');
    const id_text = if (slash) |index| tail[0..index] else tail;
    const id = std.fmt.parseInt(i32, id_text, 10) catch return null;
    if (id <= 0) return null;
    const action = if (slash) |index| tail[index + 1 ..] else "";
    if (std.mem.indexOfScalar(u8, action, '/') != null) return null;
    return .{ .id = id, .action = action };
}

pub fn parsePinPath(path: []const u8) ?PinPath {
    const prefix = "/api/v1/account/pins/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    var parts = std.mem.splitScalar(u8, path[prefix.len..], '/');
    const source_text = parts.next() orelse return null;
    const id_text = parts.next() orelse return null;
    if (parts.next() != null) return null;
    const source: storage.ReplaySource = if (std.mem.eql(u8, source_text, "stable")) .stable else if (std.mem.eql(u8, source_text, "lazer")) .lazer else return null;
    const id = std.fmt.parseInt(i64, id_text, 10) catch return null;
    if (id <= 0) return null;
    return .{ .source = source, .id = id };
}

pub const LazerPerformance = struct { pp: f64 = 0, stars: f64 = 0, max_combo: u32 = 0, mods: u32 = 0 };

pub const StaffPpPreviewRequest = struct {
    beatmap_id: i32,
    source: pp_admin.Source,
    namespace: pp_admin.Namespace,
    mode: u8,
    mods: u32,
    max_combo: u32,
    large_tick_hits: u32 = 0,
    small_tick_hits: u32 = 0,
    slider_end_hits: u32 = 0,
    n_geki: u32 = 0,
    n_katu: u32 = 0,
    n300: u32,
    n100: u32,
    n50: u32,
    misses: u32,
    legacy_total_score: u32,
    mods_json: []const u8 = "[]",
};

pub fn ppNamespace(value: []const u8) ?pp_admin.Namespace {
    return std.meta.stringToEnum(pp_admin.Namespace, value);
}

pub fn lazerPpNamespace(value: lazer.Namespace) ?pp_admin.Namespace {
    return switch (value) {
        .vanilla => .vanilla,
        .relax => .relax,
        .autopilot => .autopilot,
        .custom => null,
    };
}

pub fn staffPpComparisonJson(allocator: std.mem.Allocator, result: pp_admin.Comparison) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print(
        "{{\"policy\":\"{s}\",\"engine\":\"{s}\",\"source\":\"{s}\",\"namespace\":\"{s}\",\"submitted_mods\":{d},\"candidate_mods\":{d},\"rate\":{{\"mod\":\"{s}\",\"multiplier\":{d}}},\"current\":{{\"pp\":{d},\"stars\":{d},\"max_combo\":{d}}},\"candidate\":{{\"pp\":{d},\"stars\":{d},\"max_combo\":{d}}},\"delta\":{{\"pp\":{d},\"stars\":{d},\"max_combo\":{d},\"pp_percent\":",
        .{ result.policy, result.upstream_engine, @tagName(result.source), @tagName(result.namespace), result.submitted_mods, result.candidate_mods, @tagName(result.rate.mod), result.rate.multiplier, result.current.pp, result.current.stars, result.current.max_combo, result.candidate.pp, result.candidate.stars, result.candidate.max_combo, result.delta.pp, result.delta.stars, result.delta.max_combo },
    );
    if (result.delta.pp_percent) |value| try output.writer.print("{d}", .{value}) else try output.writer.writeAll("null");
    try output.writer.print("}},\"changed\":{}}}", .{result.changed});
    return output.toOwnedSlice();
}

pub fn lazerPerformance(allocator: std.mem.Allocator, store: *storage.Store, input: lazer.ScoreInput, mods_json: []const u8) !LazerPerformance {
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
    const performance = if (lazerPpNamespace(input.namespace)) |namespace|
        try pp_admin.calculate(allocator, map_file, .{
            .source = .lazer,
            .namespace = namespace,
            .input = performance_input,
            .mods_json = mods_json,
        })
    else if (input.namespace == .vanilla)
        try pp.calculateLazer(map_file, mods_json, performance_input)
    else
        try pp.calculate(map_file, performance_input);
    return .{ .pp = performance.pp, .stars = performance.stars, .max_combo = performance.max_combo, .mods = state.mods };
}

pub fn intLines(allocator: std.mem.Allocator, values: []const i32) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (values, 0..) |value, index| {
        if (index != 0) try output.writer.writeByte('\n');
        try output.writer.print("{d}", .{value});
    }
    return output.toOwnedSlice();
}

pub fn validWebText(value: []const u8, minimum: usize, maximum: usize) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return trimmed.len >= minimum and trimmed.len <= maximum and std.unicode.utf8ValidateSlice(trimmed);
}

pub fn validWebLine(value: []const u8, maximum: usize) bool {
    return validWebText(value, 0, maximum) and std.mem.indexOfAny(u8, value, "\r\n") == null;
}

pub fn validProfileWebsite(value: []const u8) bool {
    if (value.len == 0) return true;
    if (value.len > 200 or !std.mem.startsWith(u8, value, "https://") or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (std.ascii.isWhitespace(byte) or byte < 0x20 or byte == 0x7f or byte == '"' or byte == '\'' or byte == '<' or byte == '>') return false;
    return value.len > "https://".len;
}

pub fn stableClientPrivileges(server: u32) u8 {
    var client: u8 = 1 << 2;
    if (server & 1 != 0) client |= 1 << 0;
    if (server & ((1 << 4) | (1 << 5)) != 0) client |= 1 << 2;
    if (server & (1 << 12) != 0) client |= 1 << 1;
    if (server & (1 << 13) != 0) client |= 1 << 4;
    if (server & (1 << 14) != 0) client |= 1 << 3;
    return client;
}

pub fn scoreLog(user_name: []const u8, score: stable_score.Submission, pp_value: f64, placement: ?domain.ScorePlacement) void {
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

pub fn announceScore(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, user_name: []const u8, score: stable_score.Submission, pp_value: f64, placement: domain.ScorePlacement, info: storage.Store.BeatmapInfo) !void {
    var text_buf: [768]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buf, "{s} set #{d} on {s} - {s} [{s}] with {d:.2}pp ({d:.2}%)", .{ user_name, placement.rank + 1, info.artist, info.title, info.version, pp_value, score.accuracy() * 100.0 });
    try bancho.publishAnnouncement(allocator, sessions, text);
}

pub fn announceLazerScore(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, user_name: []const u8, score: lazer.ScoreInput, mods: []const u8, pp_value: f64, placement: domain.ScorePlacement, info: storage.Store.BeatmapInfo) !void {
    var text_buf: [896]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buf, "{s} set #{d} on {s} - {s} [{s}] with {d:.2}pp ({d:.2}%) [{s}] {s}", .{ user_name, placement.rank + 1, info.artist, info.title, info.version, pp_value, score.accuracy * 100.0, @tagName(score.namespace), mods });
    try store.recordPublicMessage(3, "#announce", text);
    try bancho.publishAnnouncement(allocator, sessions, text);
}
