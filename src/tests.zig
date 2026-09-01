const std = @import("std");
const bancho = @import("bancho.zig");
const protocol = @import("protocol.zig");
const domain = @import("domain.zig");
const lazer = @import("lazer.zig");
const lazer_bot = @import("lazer_bot.zig");
const lazer_multiplayer = @import("lazer_multiplayer.zig");
const lazer_notifications = @import("lazer_notifications.zig");
const lazer_spectator = @import("lazer_spectator.zig");
const rijndael = @import("rijndael.zig");
const multipart = @import("multipart.zig");
const score_crypto = @import("score_crypto.zig");
const stable_score = @import("stable_score.zig");
const stable_mods = @import("stable_mods.zig");
const stable_response = @import("stable_response.zig");
const rate_limit = @import("rate_limit.zig");
const pp = @import("exact_pp.zig");
const pp_admin = @import("pp_admin.zig");
const native_pp = @import("pp.zig");
const beatmap = @import("beatmap.zig");
const storage = @import("runtime_storage.zig");
const form_urlencoded = @import("form_urlencoded.zig");
const routing = @import("routing.zig");
const beatmap_sync = @import("beatmap_sync.zig");
const bss = @import("bss.zig");
const upstream_user = @import("upstream_user.zig");
const sessions_mod = @import("sessions.zig");
const country = @import("country.zig");
const config_mod = @import("config.zig");
const irc = @import("irc.zig");
const multiplayer = @import("multiplayer.zig");
const registration = @import("registration.zig");
const postgres = @import("postgres.zig");
const migrate_postgres = @import("migrate_postgres.zig");
const postgres_store = @import("postgres_store.zig");
const postgres_store_tests = @import("storage/postgres/tests.zig");
const webhook = @import("webhook.zig");
const web_auth = @import("web_auth.zig");
const screenshot = @import("screenshot.zig");
const media_contract = @import("media_contract.zig");
const beatmap_media = @import("beatmap_media.zig");
const proxy = @import("proxy.zig");
const user_json = @import("user_json.zig");
const profile_avatar = @import("profile_avatar.zig");
const avatar_cache = @import("avatar_cache.zig");
const r2 = @import("r2.zig");
const site_replay = @import("site_replay.zig");
const server_control = @import("server_control.zig");
const account_roles = @import("account_roles.zig");
const server_control_route = @import("server_control_route.zig");
const anticheat_abi = @import("anticheat_abi.zig");
const anticheat_evidence = @import("anticheat_evidence.zig");
const anticheat_plugin = @import("anticheat_plugin.zig");
const anticheat_replay = @import("anticheat_replay.zig");
const anticheat_review = @import("anticheat_review.zig");
const server_anticheat = @import("server/app/anticheat.zig");
const achievements = @import("achievements.zig");
const changelog = @import("changelog");
const lazer_route_manifest = @import("lazer_route_manifest.zig");
const lazer_wiki = @import("lazer_wiki.zig");
const player_routes = @import("player_routes.zig");
const index_page = @embedFile("index.html");
const server_website_source = @embedFile("server/routes/website.zig");
const server_lazer_source = @embedFile("server/app/lazer.zig");
const server_sessions_source = @embedFile("server/app/sessions.zig");
const server_router_source = @embedFile("server/http/router.zig");
const server_platform_source = @embedFile("server/routes/platform.zig");
const server_primitives_source = @embedFile("server/http/primitives.zig");
const server_fallback_source = @embedFile("server/routes/fallback.zig");

const sqlite_anticheat_exclusion_downgrade =
    "DROP INDEX anticheat_observations_review_queue;" ++
    "ALTER TABLE anticheat_observations DROP COLUMN review_exclusion_id;" ++
    "DROP TABLE anticheat_review_exclusions;" ++
    "DROP INDEX anticheat_replay_fingerprints_content;" ++
    "ALTER TABLE anticheat_replay_fingerprints DROP COLUMN replay_content_sha256;";

comptime {
    _ = postgres;
    _ = server_control_route;
    _ = migrate_postgres;
    _ = postgres_store;
    _ = postgres_store_tests;
    _ = web_auth;
    _ = screenshot;
    _ = media_contract;
    _ = beatmap_media;
    _ = proxy;
    _ = user_json;
    _ = lazer_bot;
    _ = profile_avatar;
    _ = avatar_cache;
    _ = r2;
    _ = site_replay;
    _ = anticheat_abi;
    _ = anticheat_evidence;
    _ = anticheat_plugin;
    _ = anticheat_replay;
    _ = anticheat_review;
    _ = achievements;
    _ = pp_admin;
    _ = changelog;
    _ = lazer_route_manifest;
    _ = lazer_wiki;
    _ = lazer_spectator;
    _ = lazer_notifications;
    _ = irc;
}

const stable_login_details = "b20260811|0|0|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1.2.3.:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccc:dddddddddddddddddddddddddddddddd:|0";
const ari_stable_login = "ari\n00000000000000000000000000000000\n" ++ stable_login_details;

fn clientMessagePacket(allocator: std.mem.Allocator, id: protocol.ClientPacket, sender: []const u8, message: []const u8, target: []const u8, sender_id: i32) ![]u8 {
    var w = protocol.Writer.init(allocator);
    defer w.deinit();
    try w.int(u16, @intFromEnum(id));
    try w.byte(0);
    try w.int(u32, 0);
    try w.string(sender);
    try w.string(message);
    try w.string(target);
    try w.int(i32, sender_id);
    std.mem.writeInt(u32, w.list.items[3..][0..4], @intCast(w.list.items.len - 7), .little);
    return allocator.dupe(u8, w.bytes());
}

fn clientEmptyPacket(allocator: std.mem.Allocator, id: protocol.ClientPacket) ![]u8 {
    var w = protocol.Writer.init(allocator);
    defer w.deinit();
    try w.int(u16, @intFromEnum(id));
    try w.byte(0);
    try w.int(u32, 0);
    return allocator.dupe(u8, w.bytes());
}

fn clientPayloadPacket(allocator: std.mem.Allocator, id: protocol.ClientPacket, payload: []const u8) ![]u8 {
    var w = protocol.Writer.init(allocator);
    defer w.deinit();
    try w.int(u16, @intFromEnum(id));
    try w.byte(0);
    try w.int(u32, @intCast(payload.len));
    try w.raw(payload);
    return allocator.dupe(u8, w.bytes());
}

fn clientIntPacket(allocator: std.mem.Allocator, id: protocol.ClientPacket, value: i32) ![]u8 {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(i32, &payload, value, .little);
    return clientPayloadPacket(allocator, id, &payload);
}

fn clientActionPacket(allocator: std.mem.Allocator, action: u8) ![]u8 {
    return clientActionModsPacket(allocator, action, 0, 0);
}

fn clientActionModsPacket(allocator: std.mem.Allocator, action: u8, mods: i32, mode: u8) ![]u8 {
    var payload = protocol.Writer.init(allocator);
    defer payload.deinit();
    try payload.byte(action);
    try payload.string("");
    try payload.string("");
    try payload.int(i32, mods);
    try payload.byte(mode);
    try payload.int(i32, 0);
    return clientPayloadPacket(allocator, .change_action, payload.bytes());
}

fn multiplayerFixtureData(host_id: i32, password: []const u8) multiplayer.MatchData {
    return .{
        .id = 0,
        .in_progress = false,
        .mods = 0,
        .name = "zigcho stable room",
        .password = password,
        .map_name = "Zigcho - Fixture [Tests]",
        .map_id = 900000001,
        .map_md5 = "0123456789abcdef0123456789abcdef",
        .slot_statuses = [_]u8{@intFromEnum(multiplayer.SlotStatus.open)} ** 16,
        .slot_teams = [_]u8{@intFromEnum(multiplayer.Team.neutral)} ** 16,
        .slot_mods = [_]i32{0} ** 16,
        .host_id = host_id,
        .mode = 0,
        .win_condition = 0,
        .team_type = 0,
        .freemods = false,
        .seed = 0,
    };
}

fn clientMatchPacket(allocator: std.mem.Allocator, id: protocol.ClientPacket, host_id: i32, password: []const u8) ![]u8 {
    return clientMatchDataPacket(allocator, id, multiplayerFixtureData(host_id, password));
}

fn clientMatchDataPacket(allocator: std.mem.Allocator, id: protocol.ClientPacket, data: multiplayer.MatchData) ![]u8 {
    var match = try multiplayer.Match.init(allocator, 0, data, data.host_id);
    defer match.deinit();
    var payload = protocol.Writer.init(allocator);
    defer payload.deinit();
    try multiplayer.writeMatch(&payload, &match, true);
    return clientPayloadPacket(allocator, id, payload.bytes());
}

fn clientJoinMatchPacket(allocator: std.mem.Allocator, match_id: i32, password: []const u8) ![]u8 {
    var payload = protocol.Writer.init(allocator);
    defer payload.deinit();
    try payload.int(i32, match_id);
    try payload.string(password);
    return clientPayloadPacket(allocator, .join_match, payload.bytes());
}

fn testSessionUser(allocator: std.mem.Allocator, id: i32, name: []const u8) !domain.User {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    return .{
        .id = id,
        .name = owned_name,
        .safe_name = try allocator.dupe(u8, name),
    };
}

fn drainSession(allocator: std.mem.Allocator, store: *storage.Store, sessions: *sessions_mod.Sessions, session: *sessions_mod.Session) !void {
    const result = try bancho.poll(allocator, store, sessions, session, "");
    allocator.free(result);
}

fn expectPacketIds(data: []const u8, expected: []const protocol.ServerPacket) !void {
    var reader: protocol.Reader = .{ .data = data };
    for (expected) |wanted| {
        const actual = (try reader.next()) orelse return error.MissingPacket;
        try std.testing.expectEqual(wanted, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum(actual.id))));
    }
    try std.testing.expect((try reader.next()) == null);
}

fn expectStringPacket(data: []const u8, wanted: protocol.ServerPacket, value: []const u8) !void {
    var reader: protocol.Reader = .{ .data = data };
    while (try reader.next()) |packet| {
        if (@intFromEnum(packet.id) != @intFromEnum(wanted)) continue;
        var payload: protocol.PayloadReader = .{ .data = packet.payload };
        try std.testing.expectEqualStrings(value, try payload.string());
        return;
    }
    return error.MissingPacket;
}

fn expectPacket(data: []const u8, wanted: protocol.ServerPacket) !void {
    var reader: protocol.Reader = .{ .data = data };
    while (try reader.next()) |packet| {
        if (@intFromEnum(packet.id) == @intFromEnum(wanted)) return;
    }
    return error.MissingPacket;
}

fn expectIntListContains(data: []const u8, wanted: protocol.ServerPacket, values: []const i32) !void {
    var reader: protocol.Reader = .{ .data = data };
    while (try reader.next()) |packet| {
        if (@intFromEnum(packet.id) != @intFromEnum(wanted)) continue;
        var payload: protocol.PayloadReader = .{ .data = packet.payload };
        const count = try payload.int(u16);
        var found = [_]bool{false} ** 16;
        try std.testing.expect(values.len <= found.len);
        for (0..count) |_| {
            const actual = try payload.int(i32);
            for (values, 0..) |value, index| if (actual == value) {
                found[index] = true;
            };
        }
        for (found[0..values.len]) |present| try std.testing.expect(present);
        return;
    }
    return error.MissingPacket;
}

fn expectPresenceUsers(data: []const u8, included: []const i32, excluded: []const i32) !void {
    var found = [_]bool{false} ** 16;
    try std.testing.expect(included.len <= found.len);
    var reader: protocol.Reader = .{ .data = data };
    while (try reader.next()) |packet| {
        if (@intFromEnum(packet.id) != @intFromEnum(protocol.ServerPacket.user_presence)) continue;
        var payload: protocol.PayloadReader = .{ .data = packet.payload };
        const actual = try payload.int(i32);
        for (included, 0..) |user_id, index| if (actual == user_id) {
            found[index] = true;
        };
        for (excluded) |user_id| try std.testing.expect(actual != user_id);
    }
    for (found[0..included.len]) |present| try std.testing.expect(present);
}

fn expectStatsPacket(data: []const u8, user_id: i32, expected_mods: i32, expected_mode: u8, expected_pp: u16) !void {
    var reader: protocol.Reader = .{ .data = data };
    while (try reader.next()) |packet| {
        if (@intFromEnum(packet.id) != @intFromEnum(protocol.ServerPacket.user_stats)) continue;
        var payload: protocol.PayloadReader = .{ .data = packet.payload };
        if (try payload.int(i32) != user_id) continue;
        _ = try payload.byte();
        _ = try payload.string();
        _ = try payload.string();
        try std.testing.expectEqual(expected_mods, try payload.int(i32));
        try std.testing.expectEqual(expected_mode, try payload.byte());
        _ = try payload.int(i32);
        _ = try payload.int(i64);
        _ = try payload.int(u32);
        _ = try payload.int(i32);
        _ = try payload.int(i64);
        _ = try payload.int(i32);
        try std.testing.expectEqual(expected_pp, try payload.int(u16));
        return;
    }
    return error.MissingPacket;
}

fn expectMessageText(data: []const u8, expected: []const u8) !void {
    var reader: protocol.Reader = .{ .data = data };
    while (try reader.next()) |packet| {
        if (@intFromEnum(packet.id) != @intFromEnum(protocol.ServerPacket.send_message)) continue;
        var payload: protocol.PayloadReader = .{ .data = packet.payload };
        _ = try payload.string();
        try std.testing.expectEqualStrings(expected, try payload.string());
        return;
    }
    return error.MissingPacket;
}

fn expectMessageContains(data: []const u8, expected: []const u8) !void {
    var reader: protocol.Reader = .{ .data = data };
    while (try reader.next()) |packet| {
        if (@intFromEnum(packet.id) != @intFromEnum(protocol.ServerPacket.send_message)) continue;
        var payload: protocol.PayloadReader = .{ .data = packet.payload };
        _ = try payload.string();
        const message = try payload.string();
        if (std.mem.indexOf(u8, message, expected) != null) return;
    }
    return error.MissingPacket;
}

const LoginAllocationContext = struct {
    store: *storage.Store,
    body: []const u8,
};

fn multiplayerAllocationRun(allocator: std.mem.Allocator, _: void) !void {
    var match = try multiplayer.Match.init(allocator, 1, multiplayerFixtureData(10, "secret"), 10);
    defer match.deinit();
    var settings = multiplayerFixtureData(10, "secret");
    settings.name = "updated stable room";
    settings.map_name = "updated map";
    try match.updateSettings(settings);
    try match.updatePassword("updated-secret");
    var writer = protocol.Writer.init(allocator);
    defer writer.deinit();
    match.in_progress = true;
    match.slots[0].status = @intFromEnum(multiplayer.SlotStatus.playing);
    try multiplayer.writePacket(&writer, .match_start, &match, true);
    var score_frame = [_]u8{0} ** 29;
    score_frame[25] = 1;
    try multiplayer.writeScoreFramePacket(&writer, &score_frame, 0);
}

const SpectatorAllocationContext = struct { store: *storage.Store };

fn spectatorAllocationRun(allocator: std.mem.Allocator, context: *SpectatorAllocationContext) !void {
    var sessions = sessions_mod.Sessions.init(allocator, std.testing.io);
    defer sessions.deinit();
    const host_user = try testSessionUser(allocator, 70, "allocation_host");
    var host_owned = true;
    errdefer if (host_owned) {
        allocator.free(host_user.name);
        allocator.free(host_user.safe_name);
    };
    _ = try sessions.create(host_user, 0, 0, 0);
    host_owned = false;
    const spectator_user = try testSessionUser(allocator, 71, "allocation_spectator");
    var spectator_owned = true;
    errdefer if (spectator_owned) {
        allocator.free(spectator_user.name);
        allocator.free(spectator_user.safe_name);
    };
    const spectator = try sessions.create(spectator_user, 0, 0, 0);
    spectator_owned = false;
    const start = try clientIntPacket(allocator, .start_spectating, 70);
    defer allocator.free(start);
    const result = try bancho.poll(allocator, context.store, &sessions, spectator, start);
    defer allocator.free(result);
}

fn loginAllocationRun(allocator: std.mem.Allocator, context: *LoginAllocationContext) !void {
    var sessions = sessions_mod.Sessions.init(allocator, std.testing.io);
    defer sessions.deinit();
    var result = try bancho.login(allocator, context.store, &sessions, context.body, null, 0, 0);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 64), result.token.len);
}

fn ppAllocationRun(allocator: std.mem.Allocator, _: void) !void {
    const result = try native_pp.calculateWithAllocator(allocator, @embedFile("testdata/synthetic-standard.osu"), .{
        .mode = 0,
        .lazer = 0,
        .mods = 0,
        .max_combo = 10,
        .n_geki = 0,
        .n_katu = 0,
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .misses = 0,
        .legacy_total_score = 1_000_000,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 26.895763), result.pp, 0.0001);
}

const AuthStressContext = struct {
    store: *storage.Store,
    failed: *std.atomic.Value(bool),
};

fn authStress(context: *AuthStressContext) void {
    for (0..4) |_| {
        const user = context.store.authenticate(std.heap.smp_allocator, "ari", "00000000000000000000000000000000") catch {
            context.failed.store(true, .release);
            return;
        } orelse {
            context.failed.store(true, .release);
            return;
        };
        std.heap.smp_allocator.free(user.name);
        std.heap.smp_allocator.free(user.safe_name);
        if ((context.store.authenticate(std.heap.smp_allocator, "ari", "11111111111111111111111111111111") catch {
            context.failed.store(true, .release);
            return;
        }) != null) {
            context.failed.store(true, .release);
            return;
        }
    }
}

fn countStress(context: *AuthStressContext) void {
    for (0..100) |_| _ = context.store.serverCounts() catch {
        context.failed.store(true, .release);
        return;
    };
}

fn storedZip(allocator: std.mem.Allocator, filename: []const u8, contents: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    const crc = std.hash.Crc32.hash(contents);
    try writer.writeAll(&std.zip.local_file_header_sig);
    try writer.writeInt(u16, 20, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u32, crc, .little);
    try writer.writeInt(u32, @intCast(contents.len), .little);
    try writer.writeInt(u32, @intCast(contents.len), .little);
    try writer.writeInt(u16, @intCast(filename.len), .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeAll(filename);
    try writer.writeAll(contents);
    const central_offset: u32 = @intCast(output.written().len);
    try writer.writeAll(&std.zip.central_file_header_sig);
    try writer.writeInt(u16, 20, .little);
    try writer.writeInt(u16, 20, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u32, crc, .little);
    try writer.writeInt(u32, @intCast(contents.len), .little);
    try writer.writeInt(u32, @intCast(contents.len), .little);
    try writer.writeInt(u16, @intCast(filename.len), .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u32, 0, .little);
    try writer.writeInt(u32, 0, .little);
    try writer.writeAll(filename);
    const central_size: u32 = @intCast(output.written().len - central_offset);
    try writer.writeAll(&std.zip.end_record_sig);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 1, .little);
    try writer.writeInt(u16, 1, .little);
    try writer.writeInt(u32, central_size, .little);
    try writer.writeInt(u32, central_offset, .little);
    try writer.writeInt(u16, 0, .little);
    return output.toOwnedSlice();
}

const StoredZipEntry = struct {
    filename: []const u8,
    contents: []const u8,
};

fn storedZipFiles(allocator: std.mem.Allocator, entries: []const StoredZipEntry) ![]u8 {
    if (entries.len == 0 or entries.len > std.math.maxInt(u16)) return error.InvalidFixture;
    const local_offsets = try allocator.alloc(u32, entries.len);
    defer allocator.free(local_offsets);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    for (entries, 0..) |entry, index| {
        local_offsets[index] = @intCast(output.written().len);
        const crc = std.hash.Crc32.hash(entry.contents);
        try writer.writeAll(&std.zip.local_file_header_sig);
        try writer.writeInt(u16, 20, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u32, crc, .little);
        try writer.writeInt(u32, @intCast(entry.contents.len), .little);
        try writer.writeInt(u32, @intCast(entry.contents.len), .little);
        try writer.writeInt(u16, @intCast(entry.filename.len), .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeAll(entry.filename);
        try writer.writeAll(entry.contents);
    }
    const central_offset: u32 = @intCast(output.written().len);
    for (entries, local_offsets) |entry, local_offset| {
        const crc = std.hash.Crc32.hash(entry.contents);
        try writer.writeAll(&std.zip.central_file_header_sig);
        try writer.writeInt(u16, 20, .little);
        try writer.writeInt(u16, 20, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u32, crc, .little);
        try writer.writeInt(u32, @intCast(entry.contents.len), .little);
        try writer.writeInt(u32, @intCast(entry.contents.len), .little);
        try writer.writeInt(u16, @intCast(entry.filename.len), .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u32, 0, .little);
        try writer.writeInt(u32, local_offset, .little);
        try writer.writeAll(entry.filename);
    }
    const central_size: u32 = @intCast(output.written().len - central_offset);
    try writer.writeAll(&std.zip.end_record_sig);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, @intCast(entries.len), .little);
    try writer.writeInt(u16, @intCast(entries.len), .little);
    try writer.writeInt(u32, central_size, .little);
    try writer.writeInt(u32, central_offset, .little);
    try writer.writeInt(u16, 0, .little);
    return output.toOwnedSlice();
}

test "config values stay owned after the source buffer changes" {
    const source = try std.testing.allocator.dupe(
        u8,
        "osu_api_key=first-key\n" ++
            "score_webhook=https://discord.invalid/first\n" ++
            "anticheat_module_path=/opt/zigcho/private/anticheat.so\n" ++
            "anticheat_allow_sample_modulus=250\n" ++
            "beatmap_cache_max_bytes=536870912\n" ++
            "beatmap_media_cache_max_bytes=268435456\n" ++
            "irc_bind=::1\n" ++
            "irc_port=16667\n" ++
            "avatar_r2_endpoint=https://example.r2.cloudflarestorage.com\n" ++
            "avatar_r2_bucket=avatars\n" ++
            "avatar_r2_access_key_id=test-access\n" ++
            "avatar_r2_secret_access_key=test-secret\n" ++
            "object_storage_endpoint=https://sin1.contabostorage.com\n" ++
            "object_storage_bucket=data\n" ++
            "object_storage_region=default\n" ++
            "object_storage_access_key_id=object-access\n" ++
            "object_storage_secret_access_key=object-secret\n" ++
            "osu_api_key=final-key\n",
    );
    var config = try config_mod.parse(std.testing.allocator, source);
    defer config.deinit();

    @memset(source, 'x');
    std.testing.allocator.free(source);

    try std.testing.expectEqualStrings("final-key", config.osu_api_key);
    try std.testing.expectEqualStrings("https://discord.invalid/first", config.score_webhook);
    try std.testing.expectEqualStrings("/opt/zigcho/private/anticheat.so", config.anticheat_module_path);
    try std.testing.expectEqual(@as(u32, 250), config.anticheat_allow_sample_modulus);
    try std.testing.expectEqual(@as(u64, 536870912), config.beatmap_cache_max_bytes);
    try std.testing.expectEqual(@as(u64, 268435456), config.beatmap_media_cache_max_bytes);
    try std.testing.expectEqualStrings("::1", config.irc_bind);
    try std.testing.expectEqual(@as(u16, 16667), config.irc_port);
    try std.testing.expect(config_mod.validIrcBind(config.irc_bind));
    try std.testing.expect(!config_mod.validIrcBind("0.0.0.0"));
    try std.testing.expectEqualStrings("https://example.r2.cloudflarestorage.com", config.avatar_r2_endpoint);
    try std.testing.expectEqualStrings("avatars", config.avatar_r2_bucket);
    try std.testing.expectEqualStrings("test-access", config.avatar_r2_access_key_id);
    try std.testing.expectEqualStrings("test-secret", config.avatar_r2_secret_access_key);
    try std.testing.expectEqualStrings("https://sin1.contabostorage.com", config.object_storage_endpoint);
    try std.testing.expectEqualStrings("data", config.object_storage_bucket);
    try std.testing.expectEqualStrings("default", config.object_storage_region);
    try std.testing.expectEqualStrings("object-access", config.object_storage_access_key_id);
    try std.testing.expectEqualStrings("object-secret", config.object_storage_secret_access_key);
}

const stable_replay_fixture =
    "\x5d\x00\x00\x80\x00\xff\xff\xff\xff\xff\xff\xff\xff\x00\x18\x1f" ++
    "\x02\xc3\x47\xeb\xd6\xc5\x14\x32\x97\xb8\xe4\xb0\xd8\x28\x49\x7a" ++
    "\xdb\x23\x77\xba\x2d\x49\xd7\x64\x79\x3b\x7a\x7e\x1f\x98\x91\x3b" ++
    "\xaf\x1e\x18\xf7\x7f\xff\x11\xd4\x40\x00";

const anticheat_map_fixture =
    "osu file format v14\n" ++
    "\n[General]\n" ++
    "Mode:0\n" ++
    "\n[Difficulty]\n" ++
    "OverallDifficulty:5\n" ++
    "\n[HitObjects]\n" ++
    "128,100,1000,1,0,0:0:0:0:\n" ++
    "256,200,2000,1,0,0:0:0:0:\n";

test "stable anticheat replay decoding stays bounded and preserves input frames" {
    var prepared = try anticheat_replay.prepare(std.testing.allocator, stable_replay_fixture, anticheat_map_fixture, stable_mods.hard_rock);
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 3), prepared.frames.len);
    try std.testing.expectEqual(@as(i64, 0), prepared.frames[0].time_ms);
    try std.testing.expectEqual(@as(i64, 1000), prepared.frames[1].time_ms);
    try std.testing.expectEqual(@as(i64, 1001), prepared.frames[2].time_ms);
    try std.testing.expectEqual(@as(u32, 4), prepared.frames[1].keys);
    try std.testing.expectEqual(@as(usize, 1), prepared.objects.len);
    try std.testing.expectEqual(@as(u32, 2), prepared.map_object_count);
    try std.testing.expectEqual(@as(f32, 284), prepared.objects[0].y);
    try std.testing.expectEqual(@as(u32, 130), prepared.hit_window_ms);
    try std.testing.expectEqual(@as(u32, 2000), prepared.map_duration_ms);
}

test "stable anticheat replay parser rejects malformed or unbounded frames" {
    const historical = try anticheat_replay.parseFrames(std.testing.allocator, "0|0|0|0,-1|0|0|0,-12345|0|0|1,");
    defer std.testing.allocator.free(historical);
    try std.testing.expectEqual(@as(i64, 0), historical[0].time_ms);
    try std.testing.expectEqual(@as(i64, 0), historical[1].time_ms);
    const repaired = try anticheat_replay.parseFrames(std.testing.allocator, "0|0|0|0,1|0|0|0,-1|0|0|0,-12345|0|0|1,");
    defer std.testing.allocator.free(repaired);
    try std.testing.expectEqual(@as(usize, 2), repaired.len);
    try std.testing.expectEqual(@as(i64, 1), repaired[1].time_ms);
    try std.testing.expectError(error.InvalidReplay, anticheat_replay.parseFrames(std.testing.allocator, "0|nan|0|0,1|0|0|0,-12345|0|0|1,"));
    try std.testing.expectError(error.InvalidReplay, anticheat_replay.parseFrames(std.testing.allocator, "0|0|0|0,86400001|0|0|0,-12345|0|0|1,"));
    try std.testing.expectError(error.InvalidReplay, anticheat_replay.parseFrames(std.testing.allocator, "0|0|0|0,1|0|0|0"));
}

test "stable score client flags keep bancho compatible space encoding" {
    try std.testing.expectEqual(@as(u32, 0), stable_score.clientFlags("b20260814"));
    try std.testing.expectEqual(@as(u32, 2), stable_score.clientFlags("b20260814  "));
    try std.testing.expectEqual(@as(u32, 0), stable_score.clientFlags("b20260814    "));
    try std.testing.expectEqual(@as(u32, 8), stable_score.clientFlags("b20260814        "));
}

test "failed stable plays cannot emit behavioral shadow evidence" {
    try std.testing.expectEqual(@as(u64, 0), server_anticheat.stableReplayShadowEvidence(false, true, 3));
    try std.testing.expectEqual(
        anticheat_abi.Evidence.suspicious_frame_cadence | anticheat_abi.Evidence.replay_content_reused,
        server_anticheat.stableReplayShadowEvidence(true, true, 3),
    );
}

test "raw unstacked cursor output cannot become review evidence" {
    var result: anticheat_abi.GameplayResultV1 = .{
        .decision = .{ .action = anticheat_abi.Action.challenge, .reason = anticheat_abi.Reason.aim_center_lock, .risk_score = 900, .confidence_bps = 9900, .rule_revision = anticheat_abi.rule_revision },
        .matched_clicks = 80,
        .timing_stddev_milli = 2_000,
        .center_hits_bps = 9_900,
        .mean_center_distance_milli = 100,
        .snap_events = 40,
        .target_distance_stddev_milli = 50,
        .movement_velocity_stddev_milli = 3_000,
    };
    server_anticheat.gateUnreliableCursorEvidence(&result);
    try std.testing.expectEqual(anticheat_abi.Action.allow, result.decision.action);
    try std.testing.expectEqual(anticheat_abi.rule_revision, result.decision.rule_revision);
    try std.testing.expectEqual(@as(u32, 0), result.center_hits_bps);
    try std.testing.expectEqual(@as(u32, 0), result.mean_center_distance_milli);
    try std.testing.expectEqual(@as(u32, 0), result.snap_events);
    try std.testing.expectEqual(@as(u32, 0), result.target_distance_stddev_milli);
    try std.testing.expectEqual(@as(u32, 80), result.matched_clicks);
    try std.testing.expectEqual(@as(u32, 3_000), result.movement_velocity_stddev_milli);
}

fn anticheatReplayAllocationRun(allocator: std.mem.Allocator) !void {
    var prepared = try anticheat_replay.prepare(allocator, stable_replay_fixture, anticheat_map_fixture, 0);
    defer prepared.deinit();
}

test "stable anticheat replay preparation frees every allocation failure path" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, anticheatReplayAllocationRun, .{});
}

test "anticheat observations stay structured reviewable and non enforcing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/anticheat-audit.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const player_id = try store.register("ac player", "ac-player@example.invalid", "00000000000000000000000000000000");
    const reviewer_id = try store.register("ac reviewer", "ac-reviewer@example.invalid", "11111111111111111111111111111111");
    var score_sql_buf: [1024]u8 = undefined;
    const score_sql = try std.fmt.bufPrintZ(&score_sql_buf, "INSERT INTO scores(id,user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,checksum,rank_namespace,best,time_elapsed) VALUES(42,{d},'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',0,0,123456,100,0.98,500,300,20,1,0,0,0,1,1,x'00','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','vanilla',1,60000)", .{player_id});
    try store.exec(score_sql);
    const clean_sample_sql = try std.fmt.bufPrintZ(&score_sql_buf, "INSERT INTO scores(id,user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,checksum,rank_namespace,best,time_elapsed) VALUES(43,{d},'cccccccccccccccccccccccccccccccc',0,0,654321,125,0.99,600,320,10,0,0,0,0,1,1,x'00','dddddddddddddddddddddddddddddddd','vanilla',1,70000)", .{player_id});
    try store.exec(clean_sample_sql);
    const copied_score_sql = try std.fmt.bufPrintZ(&score_sql_buf, "INSERT INTO scores(id,user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,checksum,rank_namespace,best,time_elapsed) VALUES(44,{d},'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',0,0,777777,130,0.99,620,325,8,0,0,0,0,1,1,x'00','ffffffffffffffffffffffffffffffff','vanilla',1,71000)", .{reviewer_id});
    try store.exec(copied_score_sql);
    const failed_copy_sql = try std.fmt.bufPrintZ(&score_sql_buf, "INSERT INTO scores(id,user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,checksum,rank_namespace,best,time_elapsed) VALUES(45,{d},'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',0,0,1000,0,0.50,10,1,0,0,1,0,0,0,0,x'00','eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee','vanilla',0,1000)", .{reviewer_id});
    try store.exec(failed_copy_sql);
    const same_map_copy_sql = try std.fmt.bufPrintZ(&score_sql_buf, "INSERT INTO scores(id,user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,checksum,rank_namespace,best,time_elapsed) VALUES(46,{d},'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',0,16,888888,140,0.99,630,330,7,0,0,0,0,1,1,x'00','cccccccccccccccccccccccccccccccc','vanilla',1,72000)", .{reviewer_id});
    try store.exec(same_map_copy_sql);
    const observation_id = try store.recordAnticheatObservation(player_id, .{
        .source = .stable_score,
        .module = "private-test",
        .score_id = 42,
        .action = 2,
        .reason = 4101,
        .risk_score = 670,
        .confidence_bps = 9200,
        .decision_flags = 1,
        .rule_revision = 7,
        .objects_checked = 80,
        .matched_clicks = 80,
        .mean_abs_timing_error_milli = 100,
        .timing_stddev_milli = 25,
        .exact_timing_bps = 9000,
        .center_hits_bps = 8750,
        .mean_center_distance_milli = 1200,
        .snap_events = 12,
        .replay_match_count = 1,
        .key_press_count = 80,
        .key_hold_count = 79,
        .mean_hold_duration_milli = 30_000,
        .hold_duration_stddev_milli = 500,
        .alternation_bps = 9_900,
        .target_distance_stddev_milli = 400,
        .velocity_spike_count = 12,
        .movement_velocity_stddev_milli = 2_500,
    });
    const clean_sample_id = try store.recordAnticheatObservation(player_id, .{
        .source = .stable_score,
        .module = "private-test",
        .score_id = 43,
        .action = 0,
        .sample_weight = 100,
        .reason = 0,
        .risk_score = 0,
        .confidence_bps = 0,
        .rule_revision = 7,
        .objects_checked = 80,
        .matched_clicks = 77,
        .mean_abs_timing_error_milli = 8_000,
        .timing_stddev_milli = 12_000,
        .exact_timing_bps = 1_250,
        .center_hits_bps = 2_500,
        .mean_center_distance_milli = 8_000,
    });
    try std.testing.expectError(error.InvalidAnticheatObservation, store.recordAnticheatObservation(player_id, .{ .source = .stable_login, .module = "private-test", .score_id = 42, .action = 1, .reason = 1, .risk_score = 1, .confidence_bps = 1 }));

    var stmt: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(storage.c.SQLITE_OK, storage.c.sqlite3_prepare_v2(store.db, "SELECT score_id,source,module,action,sample_weight,reason,risk_score,confidence_bps,review_label FROM anticheat_observations WHERE id=?1", -1, &stmt, null));
    defer _ = storage.c.sqlite3_finalize(stmt);
    _ = storage.c.sqlite3_bind_int64(stmt, 1, observation_id);
    try std.testing.expectEqual(storage.c.SQLITE_ROW, storage.c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(i64, 42), storage.c.sqlite3_column_int64(stmt, 0));
    try std.testing.expectEqualStrings("stable_score", std.mem.span(storage.c.sqlite3_column_text(stmt, 1)));
    try std.testing.expectEqualStrings("private-test", std.mem.span(storage.c.sqlite3_column_text(stmt, 2)));
    try std.testing.expectEqual(@as(c_int, 2), storage.c.sqlite3_column_int(stmt, 3));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(stmt, 4));
    try std.testing.expectEqual(@as(c_int, 4101), storage.c.sqlite3_column_int(stmt, 5));
    try std.testing.expectEqual(@as(c_int, 670), storage.c.sqlite3_column_int(stmt, 6));
    try std.testing.expectEqual(@as(c_int, 9200), storage.c.sqlite3_column_int(stmt, 7));
    try std.testing.expectEqualStrings("pending", std.mem.span(storage.c.sqlite3_column_text(stmt, 8)));

    const pending = try store.staffAnticheatJson(std.testing.allocator);
    defer std.testing.allocator.free(pending);
    const pending_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, pending, .{});
    defer pending_parsed.deinit();
    try std.testing.expect(pending_parsed.value.object.get("policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"pending\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"score_id\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"score_id\":43") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"sample_weight\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"exact_timing_bps\":9000") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"replay_match_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"alternation_bps\":9900") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"velocity_spike_count\":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"mode\":\"observe_only\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"display\":\"challenge (2)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"display\":\"aim centre lock (4101)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"display\":\"670 / 1000 · high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"display\":\"2500 px/s\"") != null);

    var replay_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("identical compressed replay", &replay_digest, .{});
    try store.recordReplayFingerprint(player_id, 42, &replay_digest);
    try std.testing.expectEqual(@as(u32, 0), try store.crossAccountReplayMatches(player_id, &replay_digest));
    try std.testing.expectEqual(@as(u32, 0), try store.crossAccountReplayMatches(reviewer_id, &replay_digest));
    try store.recordReplayFingerprint(reviewer_id, 44, &replay_digest);
    try std.testing.expectEqual(@as(u32, 0), try store.crossAccountReplayMatches(player_id, &replay_digest));
    try std.testing.expectEqual(@as(u32, 0), try store.crossAccountReplayMatches(reviewer_id, &replay_digest));
    try store.recordReplayFingerprint(reviewer_id, 45, &replay_digest);
    try std.testing.expectEqual(@as(u32, 0), try store.crossAccountReplayMatches(player_id, &replay_digest));
    try std.testing.expectEqual(@as(u32, 0), try store.crossAccountReplayMatches(reviewer_id, &replay_digest));
    try store.recordReplayFingerprint(reviewer_id, 46, &replay_digest);
    try std.testing.expectEqual(@as(u32, 1), try store.crossAccountReplayMatches(player_id, &replay_digest));
    try std.testing.expectEqual(@as(u32, 1), try store.crossAccountReplayMatches(reviewer_id, &replay_digest));

    var content_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("canonical replay frames v1", &content_digest, .{});
    try store.recordReplayContentFingerprint(player_id, 42, &content_digest);
    try std.testing.expectEqual(@as(u32, 0), try store.crossAccountReplayContentMatches(player_id, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0, &content_digest));
    try std.testing.expectEqual(@as(u32, 1), try store.crossAccountReplayContentMatches(reviewer_id, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0, &content_digest));
    try std.testing.expectEqual(@as(u32, 0), try store.crossAccountReplayContentMatches(reviewer_id, "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", 0, &content_digest));
    try std.testing.expectEqual(@as(u32, 0), try store.crossAccountReplayContentMatches(reviewer_id, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 1, &content_digest));
    try store.recordReplayContentFingerprint(reviewer_id, 45, &content_digest);
    try std.testing.expectEqual(@as(u32, 0), try store.crossAccountReplayContentMatches(player_id, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0, &content_digest));
    try store.recordReplayContentFingerprint(reviewer_id, 46, &content_digest);
    try std.testing.expectEqual(@as(u32, 1), try store.crossAccountReplayContentMatches(player_id, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0, &content_digest));

    const replay_issue = anticheat_evidence.stableReplay(.missing, 0);
    const replay_review_id = try store.recordAnticheatObservation(reviewer_id, .{
        .source = .stable_score,
        .module = anticheat_evidence.module_name,
        .score_id = 46,
        .action = replay_issue.action,
        .reason = replay_issue.reason,
        .risk_score = replay_issue.risk_score,
        .confidence_bps = replay_issue.confidence_bps,
        .evidence = replay_issue.evidence,
        .decision_flags = replay_issue.decision_flags,
        .rule_revision = replay_issue.rule_revision,
    });
    const replay_review = try store.staffAnticheatJson(std.testing.allocator);
    defer std.testing.allocator.free(replay_review);
    try std.testing.expect(std.mem.indexOf(u8, replay_review, "\"module\":\"zigcho-host\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, replay_review, "\"reason\":2006") != null);

    try std.testing.expectError(error.InvalidAnticheatReview, store.reviewAnticheatObservation(reviewer_id, observation_id, .clean, "x"));
    try std.testing.expectError(error.AnticheatObservationNotFound, store.reviewAnticheatObservation(reviewer_id, 9999, .dismissed, "not this finding"));
    try store.reviewAnticheatObservation(reviewer_id, observation_id, .clean, "verified clean replay fixture");
    try store.reviewAnticheatObservation(reviewer_id, clean_sample_id, .clean, "verified ordinary sampled play");
    try store.reviewAnticheatObservation(reviewer_id, replay_review_id, .dismissed, "missing replay retained for review");
    const reviewed = try store.staffAnticheatJson(std.testing.allocator);
    defer std.testing.allocator.free(reviewed);
    try std.testing.expect(std.mem.indexOf(u8, reviewed, "\"pending\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, reviewed, "\"review_label\":\"clean\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reviewed, "\"reviewer\":\"ac reviewer\"") != null);
    const player = (try store.userById(std.testing.allocator, player_id)).?;
    defer std.testing.allocator.free(player.name);
    defer std.testing.allocator.free(player.safe_name);
    try std.testing.expect(!player.restricted);
}

test "anticheat review exclusions suppress the queue without suppressing evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/anticheat-exclusions.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const actor_id = try store.register("exclusion admin", "exclusion-admin@example.invalid", "00000000000000000000000000000000");
    const player_id = try store.register("excluded player", "excluded-player@example.invalid", "11111111111111111111111111111111");

    try std.testing.expectError(error.InvalidAnticheatExclusion, store.createAnticheatExclusion(actor_id, actor_id, .all, 3600, "self exclusion"));
    try std.testing.expectError(error.InvalidAnticheatExclusion, store.createAnticheatExclusion(actor_id, 3, .all, 3600, "bot exclusion"));
    try std.testing.expectError(error.InvalidAnticheatExclusion, store.createAnticheatExclusion(actor_id, player_id, .all, 3599, "too short"));
    try std.testing.expectError(error.InvalidAnticheatExclusion, store.createAnticheatExclusion(actor_id, player_id, .all, storage.anticheat_exclusion_max_seconds + 1, "too long"));
    try std.testing.expectEqual(storage.AnticheatExclusionScope.stable_score, storage.AnticheatExclusionScope.parse("stable_score").?);
    try std.testing.expect(storage.AnticheatExclusionScope.all.matches(.stable_login));
    try std.testing.expectError(error.AnticheatExclusionForbidden, store.createAnticheatExclusion(actor_id, player_id, .stable_score, 3600, "ordinary player cannot suppress review"));
    var grant_buf: [128]u8 = undefined;
    const grant = try std.fmt.bufPrintZ(&grant_buf, "UPDATE users SET privileges=privileges|(1<<13) WHERE id={d}", .{actor_id});
    try store.exec(grant);

    const score_exclusion_id = try store.createAnticheatExclusion(actor_id, player_id, .stable_score, storage.anticheat_exclusion_max_seconds, "trusted score calibration account");
    try std.testing.expectEqual(player_id, (try store.anticheatExclusionTarget(score_exclusion_id)).?);
    try std.testing.expectError(error.AnticheatExclusionOverlap, store.createAnticheatExclusion(actor_id, player_id, .all, 86400, "overlapping all signal exclusion"));

    const score_observation_id = try store.recordAnticheatObservation(player_id, .{
        .source = .stable_score,
        .module = "exclusion-test",
        .action = 1,
        .reason = 7001,
        .risk_score = 400,
        .confidence_bps = 7000,
        .evidence = 8,
    });
    _ = try store.recordAnticheatObservation(player_id, .{
        .source = .stable_login,
        .module = "exclusion-test",
        .action = 1,
        .reason = 7002,
        .risk_score = 300,
        .confidence_bps = 6500,
        .evidence = 1,
    });
    const initial = try store.staffAnticheatJson(std.testing.allocator);
    defer std.testing.allocator.free(initial);
    try std.testing.expect(std.mem.indexOf(u8, initial, "\"pending\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, initial, "\"suppressed_pending\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, initial, "\"review_suppressed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, initial, "trusted score calibration account") != null);

    try store.revokeAnticheatExclusion(actor_id, score_exclusion_id, "calibration window complete");
    try std.testing.expectError(error.AnticheatExclusionNotActive, store.revokeAnticheatExclusion(actor_id, score_exclusion_id, "already revoked"));
    const after_revoke_id = try store.recordAnticheatObservation(player_id, .{
        .source = .stable_score,
        .module = "exclusion-test",
        .action = 1,
        .reason = 7001,
        .risk_score = 400,
        .confidence_bps = 7000,
        .evidence = 8,
    });
    try std.testing.expect(after_revoke_id != score_observation_id);

    const login_exclusion_id = try store.createAnticheatExclusion(actor_id, player_id, .stable_login, 3600, "temporary login calibration");
    var expiry_sql_buf: [256]u8 = undefined;
    const expiry_sql = try std.fmt.bufPrintZ(&expiry_sql_buf, "UPDATE anticheat_review_exclusions SET created_at=1,expires_at=3601 WHERE id={d}", .{login_exclusion_id});
    try store.exec(expiry_sql);
    _ = try store.recordAnticheatObservation(player_id, .{
        .source = .stable_login,
        .module = "exclusion-test",
        .action = 1,
        .reason = 7003,
        .risk_score = 325,
        .confidence_bps = 6600,
        .evidence = 1,
    });
    const final = try store.staffAnticheatJson(std.testing.allocator);
    defer std.testing.allocator.free(final);
    try std.testing.expect(std.mem.indexOf(u8, final, "\"pending\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, final, "\"suppressed_pending\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, final, "\"active\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, final, "calibration window complete") != null);

    var audit: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(storage.c.SQLITE_OK, storage.c.sqlite3_prepare_v2(store.db, "SELECT (SELECT review_exclusion_id FROM anticheat_observations WHERE id=?1),(SELECT count(*) FROM audit_log WHERE action IN('anticheat.review_exclusion.create','anticheat.review_exclusion.revoke') AND target=?2)", -1, &audit, null));
    defer _ = storage.c.sqlite3_finalize(audit);
    _ = storage.c.sqlite3_bind_int64(audit, 1, score_observation_id);
    var target_buf: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{player_id});
    _ = storage.c.sqlite3_bind_text(audit, 2, target.ptr, @intCast(target.len), null);
    try std.testing.expectEqual(storage.c.SQLITE_ROW, storage.c.sqlite3_step(audit));
    try std.testing.expectEqual(score_exclusion_id, storage.c.sqlite3_column_int64(audit, 0));
    try std.testing.expectEqual(@as(c_int, 3), storage.c.sqlite3_column_int(audit, 1));

    var backlog_buf: [1024]u8 = undefined;
    const backlog = try std.fmt.bufPrintZ(
        &backlog_buf,
        "WITH RECURSIVE seq(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM seq WHERE value<251) INSERT INTO anticheat_observations(user_id,source,module,action,sample_weight,reason,risk_score,confidence_bps,rule_revision) SELECT {d},'stable_lastfm','backlog-test',1,1,8000+value,100,5000,1 FROM seq",
        .{player_id},
    );
    try store.exec(backlog);
    const bounded = try store.staffAnticheatJson(std.testing.allocator);
    defer std.testing.allocator.free(bounded);
    var suppressed_id_buf: [64]u8 = undefined;
    const suppressed_id = try std.fmt.bufPrint(&suppressed_id_buf, "\"id\":{d}", .{score_observation_id});
    try std.testing.expect(std.mem.indexOf(u8, bounded, suppressed_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, bounded, "\"review_suppressed\":true") != null);
}

test "staff anticheat renders canonical backend meanings as observe only proposals" {
    try std.testing.expect(std.mem.indexOf(u8, index_page, "staffAnticheatDecoded") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "proposed ${esc(action.display)}") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "${esc(reason.description)}") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "rule confidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "anticheatMetricFacts(m.metrics)") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "sampled allow decision") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "clean sample") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "clean means reviewed benign") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "uncertain means insufficient evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "cheat means verified cheating") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "dismissed means invalid or duplicate evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "action ${o.action} · reason ${o.reason}") == null);
}

test "rejected stable score evidence stays reviewable without a score row" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/anticheat-rejected-score.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("rejected score", "rejected-score@example.invalid", "00000000000000000000000000000000");
    const missing = anticheat_evidence.stableReplay(.missing, 0);
    const observation_id = try store.recordAnticheatObservation(user_id, .{
        .source = .stable_score,
        .module = anticheat_evidence.module_name,
        .action = missing.action,
        .reason = missing.reason,
        .risk_score = missing.risk_score,
        .confidence_bps = missing.confidence_bps,
        .evidence = missing.evidence,
        .decision_flags = missing.decision_flags,
        .rule_revision = missing.rule_revision,
    });
    try std.testing.expectEqual(observation_id, try store.recordAnticheatObservation(user_id, .{
        .source = .stable_score,
        .module = anticheat_evidence.module_name,
        .action = missing.action,
        .reason = missing.reason,
        .risk_score = missing.risk_score,
        .confidence_bps = missing.confidence_bps,
        .evidence = missing.evidence,
        .decision_flags = missing.decision_flags,
        .rule_revision = missing.rule_revision,
    }));
    const json = try store.staffAnticheatJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"score_id\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"display\":\"required replay missing (2006)\"") != null);
    const user = (try store.userById(std.testing.allocator, user_id)).?;
    defer std.testing.allocator.free(user.name);
    defer std.testing.allocator.free(user.safe_name);
    try std.testing.expect(!user.restricted);
}

test "anticheat null signals coalesce without deleting score evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/anticheat-retention.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES" ++
            "(60,'signal','signal',x'00',x'00'),(61,'reviewer','reviewer',x'00',x'00');" ++
            "INSERT INTO scores(id,user_id,map_md5,mode,mods,score,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed) " ++
            "VALUES(600,60,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',0,0,123456,0.98,100,100,0,0,0,0,0,1,1)",
    );

    const base: storage.AnticheatObservation = .{
        .source = .stable_login,
        .module = "retention-test",
        .action = 1,
        .reason = 100,
        .risk_score = 250,
        .confidence_bps = 7000,
        .evidence = 4,
        .objects_checked = 1,
    };
    const first_id = try store.recordAnticheatObservation(60, base);
    try std.testing.expectEqual(first_id, try store.recordAnticheatObservation(60, base));
    var changed = base;
    changed.movement_velocity_stddev_milli = 1;
    const changed_id = try store.recordAnticheatObservation(60, changed);
    try std.testing.expect(changed_id != first_id);

    const score_id = try store.recordAnticheatObservation(60, .{
        .source = .stable_score,
        .module = "retention-test",
        .score_id = 600,
        .action = 1,
        .reason = 101,
        .risk_score = 300,
        .confidence_bps = 8000,
        .evidence = 8,
    });
    try store.reviewAnticheatObservation(61, score_id, .uncertain, "retain score-linked evidence");

    try store.recordLastFmFlag(60, 123);
    try store.recordLastFmFlag(60, 123);
    var audit: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(storage.c.SQLITE_OK, storage.c.sqlite3_prepare_v2(store.db, "SELECT count(*) FROM audit_log WHERE action='stable.lastfm_flag' AND target='user:60' AND detail='flags:123'", -1, &audit, null));
    try std.testing.expectEqual(storage.c.SQLITE_ROW, storage.c.sqlite3_step(audit));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(audit, 0));
    _ = storage.c.sqlite3_finalize(audit);

    try store.exec(
        "UPDATE anticheat_observations SET created_at=1 WHERE id IN (SELECT id FROM anticheat_observations WHERE source='stable_login' ORDER BY id LIMIT 1);" ++
            "UPDATE anticheat_observations SET created_at=1,reviewed_at=1 WHERE source='stable_score';" ++
            "UPDATE audit_log SET created_at=1 WHERE action='anticheat.observe';" ++
            "WITH RECURSIVE old(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM old WHERE n<130) " ++
            "INSERT INTO audit_log(actor_id,action,target,detail,created_at) SELECT 60,'stable.lastfm_flag','user:60','old:'||n,1 FROM old;" ++
            "DELETE FROM scores WHERE id=600",
    );
    try store.recordLastFmFlag(60, 124);
    audit = null;
    try std.testing.expectEqual(storage.c.SQLITE_OK, storage.c.sqlite3_prepare_v2(store.db, "SELECT count(*) FROM audit_log WHERE action='stable.lastfm_flag' AND created_at=1", -1, &audit, null));
    try std.testing.expectEqual(storage.c.SQLITE_ROW, storage.c.sqlite3_step(audit));
    try std.testing.expectEqual(@as(c_int, 2), storage.c.sqlite3_column_int(audit, 0));
    _ = storage.c.sqlite3_finalize(audit);

    var newest = base;
    newest.reason = 102;
    _ = try store.recordAnticheatObservation(60, newest);
    var retained: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(storage.c.SQLITE_OK, storage.c.sqlite3_prepare_v2(store.db, "SELECT (SELECT count(*) FROM anticheat_observations WHERE id=?1 AND source='stable_score'),(SELECT count(*) FROM anticheat_observations WHERE id=?2),(SELECT count(*) FROM audit_log WHERE action='anticheat.observe' AND detail LIKE '% score_id=600 %'),(SELECT count(*) FROM audit_log WHERE action='anticheat.observe' AND detail LIKE '% score_id=0 %' AND created_at=1),(SELECT count(*) FROM audit_log WHERE action='stable.lastfm_flag' AND created_at=1)", -1, &retained, null));
    defer _ = storage.c.sqlite3_finalize(retained);
    _ = storage.c.sqlite3_bind_int64(retained, 1, score_id);
    _ = storage.c.sqlite3_bind_int64(retained, 2, first_id);
    try std.testing.expectEqual(storage.c.SQLITE_ROW, storage.c.sqlite3_step(retained));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(retained, 0));
    try std.testing.expectEqual(@as(c_int, 0), storage.c.sqlite3_column_int(retained, 1));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(retained, 2));
    try std.testing.expectEqual(@as(c_int, 0), storage.c.sqlite3_column_int(retained, 3));
    try std.testing.expectEqual(@as(c_int, 0), storage.c.sqlite3_column_int(retained, 4));
}

test "beatmap hydration backoff and archive pruning stay bounded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/beatmap-cache.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status) VALUES" ++
            "(1,10,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','a','a','a','a',3)," ++
            "(2,20,'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','b','b','b','b',3)",
    );
    try store.upsertBeatmapArchive(10, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "old!");
    try store.upsertBeatmapArchive(20, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "newest");
    try store.exec("UPDATE beatmap_archives SET last_accessed_at=CASE set_id WHEN 10 THEN 1 ELSE 2 END");

    try store.recordHydrationFailure("cccccccccccccccccccccccccccccccc", 30, "UpstreamUnavailable", 100);
    try std.testing.expect(!try store.hydrationRetryAllowed("cccccccccccccccccccccccccccccccc", 129));
    try std.testing.expect(try store.hydrationRetryAllowed("cccccccccccccccccccccccccccccccc", 130));
    try store.recordHydrationFailure("cccccccccccccccccccccccccccccccc", 30, "UpstreamUnavailable", 130);
    try std.testing.expect(!try store.hydrationRetryAllowed("cccccccccccccccccccccccccccccccc", 189));
    try std.testing.expect(try store.hydrationRetryAllowed("cccccccccccccccccccccccccccccccc", 190));

    const pruned = try store.pruneBeatmapArchives(6);
    try std.testing.expectEqual(@as(i64, 1), pruned.entries);
    try std.testing.expectEqual(@as(i64, 4), pruned.bytes);
    try std.testing.expect((try store.beatmapArchive(std.testing.allocator, 10)) == null);
    const retained = (try store.beatmapArchive(std.testing.allocator, 20)).?;
    defer std.testing.allocator.free(retained);
    try std.testing.expectEqualStrings("newest", retained);
    const stats = try store.beatmapCacheStats();
    try std.testing.expectEqual(@as(i64, 1), stats.entries);
    try std.testing.expectEqual(@as(i64, 6), stats.bytes);
    try std.testing.expectEqual(@as(i64, 1), stats.hydration_failures);
    try store.clearHydrationFailure("cccccccccccccccccccccccccccccccc");
    try std.testing.expectEqual(@as(i64, 0), (try store.beatmapCacheStats()).hydration_failures);
}

test "beatmap mirror serves verified cache hits and tracks stored bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/beatmap-mirror.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status) VALUES(1,900000000,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','a','a','a','a',3),(2,900000001,'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','b','b','b','b',3)");
    const archive = "verified mirror archive";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
    const sha256 = std.fmt.bytesToHex(digest, .lower);
    try store.upsertBeatmapArchive(900000000, &sha256, archive);

    var sync = beatmap_sync.Sync.init(std.testing.allocator, std.testing.io, 1024 * 1024);
    defer sync.deinit();
    const mirrored = try sync.mirrorArchive(&store, 900000000);
    defer std.testing.allocator.free(mirrored.data);
    try std.testing.expect(mirrored.cache_hit);
    try std.testing.expectEqualStrings(archive, mirrored.data);
    var download = (try store.beatmapArchiveDownload(std.testing.allocator, 900000000)).?;
    defer download.deinit();
    try std.testing.expectEqual(archive.len, download.bytes);
    var streamed: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer streamed.deinit();
    try store.streamBeatmapArchive(download, &streamed.writer);
    try std.testing.expectEqualStrings(archive, streamed.written());
    const metrics = sync.metrics();
    try std.testing.expectEqual(@as(u64, 1), metrics.mirror_hits);
    try std.testing.expectEqual(@as(u64, archive.len), metrics.mirror_bytes_served);
    const prefetched = try sync.prefetchMirrorArchive(&store, 900000000);
    defer std.testing.allocator.free(prefetched.data);
    try std.testing.expect(prefetched.cache_hit);
    try std.testing.expectEqual(@as(u64, 1), sync.metrics().mirror_hits);
    try std.testing.expectEqual(@as(u64, archive.len), sync.metrics().mirror_bytes_served);
    const cache = try store.beatmapCacheStats();
    try std.testing.expectEqual(@as(i64, 1), cache.entries);
    try std.testing.expectEqual(@as(i64, archive.len), cache.bytes);
    try std.testing.expectEqual(@as(i64, 1), try store.beatmapMirrorPendingCount());
    const missing = try store.beatmapSetIdsMissingArchives(std.testing.allocator, 10);
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqualSlices(i32, &.{900000001}, missing);
}

test "legacy credentials authenticate and upgrade outside the read lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/legacy-auth.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO users(id,name,safe_name,country,password_hash,password_salt) VALUES(1,'ari','ari','AU',x'2fdcd03d9eaa34f2a47cac2001e876ea0fa3cd26f2bbbd5ca4d64a34739d5aee',x'73616c74')");

    const user = (try store.authenticate(std.testing.allocator, "ari", "00000000000000000000000000000000")).?;
    defer std.testing.allocator.free(user.name);
    defer std.testing.allocator.free(user.safe_name);
    try std.testing.expectEqualStrings("ari", user.name);

    var stmt: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "SELECT password_hash,password_salt FROM users WHERE id=1", -1, &stmt, null));
    defer _ = storage.c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(stmt));
    const hash = std.mem.span(storage.c.sqlite3_column_text(stmt, 0));
    const salt = std.mem.span(storage.c.sqlite3_column_text(stmt, 1));
    try std.testing.expect(std.mem.startsWith(u8, hash, "$argon2id$"));
    try std.testing.expectEqualStrings("argon2id", salt);
}

test "authentication and database reads make progress concurrently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/auth-concurrency.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const ari_id = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    const lazer_tokens = try store.issueGameTokenPair(ari_id, 60, 60, false);
    var failed: std.atomic.Value(bool) = .init(false);
    var context: AuthStressContext = .{ .store = &store, .failed = &failed };
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const online = try sessions.create((try store.userById(std.testing.allocator, ari_id)).?, 0, 0, 0);
    const online_token = online.token;
    var presence_payload: [@sizeOf(u16) + @sizeOf(i32)]u8 = undefined;
    std.mem.writeInt(u16, presence_payload[0..2], 1, .little);
    std.mem.writeInt(i32, presence_payload[2..6], ari_id, .little);
    const presence_request = try clientPayloadPacket(std.testing.allocator, .user_stats_request, &presence_payload);
    defer std.testing.allocator.free(presence_request);
    const auth_thread = try std.Thread.spawn(.{}, authStress, .{&context});
    const count_thread = try std.Thread.spawn(.{}, countStress, .{&context});
    for (0..100) |_| {
        const poll = (try bancho.pollByToken(std.testing.allocator, &store, &sessions, &online_token, presence_request)).?;
        std.testing.allocator.free(poll);
    }
    auth_thread.join();
    count_thread.join();
    try std.testing.expect(!failed.load(.acquire));
    const still_current = (try store.authenticateToken(std.testing.allocator, &lazer_tokens.access, "identify")).?;
    defer std.testing.allocator.free(still_current.name);
    defer std.testing.allocator.free(still_current.safe_name);
}

test "oauth authentication owns a bounded online presence lease" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/oauth-presence.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    const web_token = try store.issueToken(user_id, "web:account", 60);
    const now = std.Io.Clock.real.now(std.testing.io).toSeconds();

    const before = try store.recentOauthUserIds(std.testing.allocator, now - 10);
    defer std.testing.allocator.free(before);
    try std.testing.expectEqual(@as(usize, 0), before.len);

    const token = try store.issueToken(user_id, "identify scores:write", 60);
    const user = (try store.authenticateToken(std.testing.allocator, &token, "identify")).?;
    defer std.testing.allocator.free(user.name);
    defer std.testing.allocator.free(user.safe_name);
    const online = try store.recentOauthUserIds(std.testing.allocator, now - 10);
    defer std.testing.allocator.free(online);
    try std.testing.expectEqualSlices(i32, &.{user_id}, online);

    try store.exec("UPDATE oauth_tokens SET last_used_at=1 WHERE scopes='identify scores:write'");
    try std.testing.expect(!try store.lazerUserOnline(user_id, now - 120));
    const expired = try store.recentOauthUserIds(std.testing.allocator, now - 120);
    defer std.testing.allocator.free(expired);
    try std.testing.expectEqual(@as(usize, 0), expired.len);
    const renewed = (try store.authenticateToken(std.testing.allocator, &token, "identify")).?;
    defer std.testing.allocator.free(renewed.name);
    defer std.testing.allocator.free(renewed.safe_name);
    try std.testing.expect(try store.lazerUserOnline(user_id, now - 120));

    try std.testing.expectEqual(@as(usize, 1), try store.revokeGameTokensForUser(user_id));
    const revoked = try store.recentOauthUserIds(std.testing.allocator, now - 10);
    defer std.testing.allocator.free(revoked);
    try std.testing.expectEqual(@as(usize, 0), revoked.len);
    const website_user = (try store.authenticateToken(std.testing.allocator, &web_token, "web:account")).?;
    defer std.testing.allocator.free(website_user.name);
    defer std.testing.allocator.free(website_user.safe_name);
}

test "lazer activity is owned by the live game token and expires cleanly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/lazer-activity.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    const other_id = try store.register("uwu", "uwu@example.invalid", "11111111111111111111111111111111");
    const first = try store.issueToken(user_id, "identify scores:write", 60);
    const web = try store.issueToken(user_id, "web:account", 60);

    try std.testing.expect(!try store.setLazerActivityForToken(&first, other_id, "playing", "wrong owner", 75, 0));
    try std.testing.expect(!try store.setLazerActivityForToken(&web, user_id, "playing", "wrong scope", 75, 0));
    try std.testing.expectError(error.InvalidLazerActivity, store.setLazerActivityForToken(&first, user_id, "playing\nelsewhere", "", null, null));
    try std.testing.expect(try store.setLazerActivityForToken(&first, user_id, "playing", "artist - title", 75, 0));
    const now = std.Io.Clock.real.now(std.testing.io).toSeconds();
    var activity = (try store.lazerActivity(std.testing.allocator, user_id, now - 120)).?;
    try std.testing.expectEqualStrings("playing", activity.status);
    try std.testing.expectEqualStrings("artist - title", activity.detail);
    try std.testing.expectEqual(@as(?i32, 75), activity.beatmap_id);
    try std.testing.expectEqual(@as(?u8, 0), activity.ruleset_id);
    activity.deinit();

    try store.exec("UPDATE lazer_presence SET updated_at=1");
    try std.testing.expect((try store.lazerActivity(std.testing.allocator, user_id, now - 120)) == null);
    try std.testing.expect(try store.setLazerActivityForToken(&first, user_id, "editing", "local map", null, 0));
    try std.testing.expectEqual(@as(usize, 1), try store.revokeLazerAccessTokensForUser(user_id));
    try std.testing.expect((try store.lazerActivity(std.testing.allocator, user_id, 0)) == null);
    try std.testing.expect(!try store.setLazerActivityForToken(&first, user_id, "playing", "stale write", 75, 0));

    const second = try store.issueToken(user_id, "identify scores:write", 60);
    try std.testing.expect(try store.setLazerActivityForToken(&second, user_id, "playing", "new session", 76, 1));
    try std.testing.expect(!try store.revokeToken(&first));
    var current = (try store.lazerActivity(std.testing.allocator, user_id, 0)).?;
    try std.testing.expectEqualStrings("new session", current.detail);
    current.deinit();
    try std.testing.expect(try store.clearLazerActivityForToken(&second, user_id));
    try std.testing.expect((try store.lazerActivity(std.testing.allocator, user_id, 0)) == null);
    try std.testing.expect(try store.setLazerActivityForToken(&second, user_id, "playing", "logout", 76, 1));
    try std.testing.expect(try store.revokeToken(&second));
    try std.testing.expect((try store.lazerActivity(std.testing.allocator, user_id, 0)) == null);
}

test "lazer refresh tokens rotate once and cannot be bearer tokens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/oauth-refresh.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    const refresh = try store.issueToken(user_id, "game:refresh", 60);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &refresh, "identify")) == null);
    const refreshed = (try store.consumeGameRefreshToken(std.testing.allocator, &refresh)).?;
    defer std.testing.allocator.free(refreshed.name);
    defer std.testing.allocator.free(refreshed.safe_name);
    try std.testing.expectEqual(user_id, refreshed.id);
    try std.testing.expect((try store.consumeGameRefreshToken(std.testing.allocator, &refresh)) == null);

    const access = try store.issueToken(user_id, "identify scores:write", 60);
    const next_refresh = try store.issueToken(user_id, "game:refresh", 60);
    try std.testing.expectEqual(@as(usize, 2), try store.revokeGameTokensForUser(user_id));
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &access, "identify")) == null);
    try std.testing.expect((try store.consumeGameRefreshToken(std.testing.allocator, &next_refresh)) == null);
}

test "explicit lazer logout revokes the access and refresh token family" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/oauth-family-revoke.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    const tokens = try store.issueGameTokenPair(user_id, 60, 60, false);
    const online = (try store.authenticateToken(std.testing.allocator, &tokens.access, "identify")).?;
    defer std.testing.allocator.free(online.name);
    defer std.testing.allocator.free(online.safe_name);
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const observer_id = try store.register("observer", "observer@example.invalid", "00000000000000000000000000000000");
    const observer = try sessions.create((try store.userById(std.testing.allocator, observer_id)).?, 0, 0, 0);
    const observer_token = observer.token;
    try bancho.noteLazerPresence(&sessions, user_id, std.Io.Clock.real.now(std.testing.io).toSeconds());

    const refresh_owner = (try store.authenticateToken(std.testing.allocator, &tokens.refresh, "")).?;
    defer std.testing.allocator.free(refresh_owner.name);
    defer std.testing.allocator.free(refresh_owner.safe_name);
    try std.testing.expectEqual(user_id, refresh_owner.id);
    try std.testing.expect(try store.revokeToken(&tokens.refresh));
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &tokens.access, "identify")) == null);
    try std.testing.expect((try store.consumeGameRefreshToken(std.testing.allocator, &tokens.refresh)) == null);
    try std.testing.expect(!try store.lazerUserOnline(user_id, 0));
    try bancho.publishLazerLogout(std.testing.allocator, &sessions, refresh_owner.id);
    const logout = (try bancho.pollByToken(std.testing.allocator, &store, &sessions, &observer_token, "")).?;
    defer std.testing.allocator.free(logout);
    var reader: protocol.Reader = .{ .data = logout };
    const packet = (try reader.next()).?;
    try std.testing.expectEqual(@intFromEnum(protocol.ServerPacket.user_logout), @intFromEnum(packet.id));
    var payload: protocol.PayloadReader = .{ .data = packet.payload };
    try std.testing.expectEqual(user_id, try payload.int(i32));
    try std.testing.expect((try reader.next()) == null);
}

test "delayed logout revokes only its game-token pair" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/oauth-pair-race.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    const old = try store.issueGameTokenPair(user_id, 60, 60, false);
    const current = try store.issueGameTokenPair(user_id, 60, 60, false);
    try std.testing.expect(try store.setLazerActivityForToken(&current.access, user_id, "playing", "new session", 75, 0));

    try std.testing.expect(try store.revokeToken(&old.access));
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &old.access, "identify")) == null);
    try std.testing.expect((try store.consumeGameRefreshToken(std.testing.allocator, &old.refresh)) == null);
    const current_user = (try store.authenticateToken(std.testing.allocator, &current.access, "identify")).?;
    defer std.testing.allocator.free(current_user.name);
    defer std.testing.allocator.free(current_user.safe_name);
    var activity = (try store.lazerActivity(std.testing.allocator, user_id, 0)).?;
    defer activity.deinit();
    try std.testing.expectEqualStrings("new session", activity.detail);
    const refreshed = (try store.consumeGameRefreshToken(std.testing.allocator, &current.refresh)).?;
    defer std.testing.allocator.free(refreshed.name);
    defer std.testing.allocator.free(refreshed.safe_name);
}

test "password replacement makes an older refresh harmless" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/oauth-refresh-race.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    const old = try store.issueGameTokenPair(user_id, 60, 60, false);
    const current = try store.issueGameTokenPair(user_id, 60, 60, true);
    try std.testing.expect((try store.rotateGameTokenPair(std.testing.allocator, &old.refresh, 60, 60)) == null);
    const current_user = (try store.authenticateToken(std.testing.allocator, &current.access, "identify")).?;
    defer std.testing.allocator.free(current_user.name);
    defer std.testing.allocator.free(current_user.safe_name);
    const refreshed = (try store.consumeGameRefreshToken(std.testing.allocator, &current.refresh)).?;
    defer std.testing.allocator.free(refreshed.name);
    defer std.testing.allocator.free(refreshed.safe_name);
}

test "refresh rotation replaces only the consumed game-token pair" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/oauth-pair-rotation.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    const old = try store.issueGameTokenPair(user_id, 60, 60, false);
    const unrelated = try store.issueGameTokenPair(user_id, 60, 60, false);
    const rotated = (try store.rotateGameTokenPair(std.testing.allocator, &old.refresh, 60, 60)).?;
    defer {
        std.testing.allocator.free(rotated.user.name);
        std.testing.allocator.free(rotated.user.safe_name);
    }
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &old.access, "identify")) == null);
    const rotated_user = (try store.authenticateToken(std.testing.allocator, &rotated.tokens.access, "identify")).?;
    defer std.testing.allocator.free(rotated_user.name);
    defer std.testing.allocator.free(rotated_user.safe_name);
    const unrelated_user = (try store.authenticateToken(std.testing.allocator, &unrelated.access, "identify")).?;
    defer std.testing.allocator.free(unrelated_user.name);
    defer std.testing.allocator.free(unrelated_user.safe_name);
    const unrelated_refresh = (try store.consumeGameRefreshToken(std.testing.allocator, &unrelated.refresh)).?;
    defer std.testing.allocator.free(unrelated_refresh.name);
    defer std.testing.allocator.free(unrelated_refresh.safe_name);
}

test "game-token pair insertion rolls back when the refresh row fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/oauth-pair-rollback.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    try store.exec("CREATE TRIGGER reject_refresh BEFORE INSERT ON oauth_tokens WHEN NEW.scopes='game:refresh' BEGIN SELECT RAISE(ABORT,'reject refresh'); END");
    try std.testing.expectError(error.DatabaseQueryFailed, store.issueGameTokenPair(user_id, 60, 60, false));
    var stmt: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(storage.c.SQLITE_OK, storage.c.sqlite3_prepare_v2(store.db, "SELECT count(*) FROM oauth_tokens WHERE user_id=?1", -1, &stmt, null));
    defer _ = storage.c.sqlite3_finalize(stmt);
    _ = storage.c.sqlite3_bind_int(stmt, 1, user_id);
    try std.testing.expectEqual(storage.c.SQLITE_ROW, storage.c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(c_int, 0), storage.c.sqlite3_column_int(stmt, 0));
}

test "Stable login can take over an account with a live lazer game lease" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/cross-client-login.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    _ = try store.issueToken(user_id, "identify scores:write", 3600);
    _ = try store.issueToken(user_id, "game:refresh", 3600);
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    var accepted = try bancho.login(std.testing.allocator, &store, &sessions, ari_stable_login, .{ 'A', 'U' }, 0, 0);
    defer accepted.deinit();
    try std.testing.expectEqual(user_id, accepted.user_id);
    try std.testing.expect(sessions.byUser(user_id) != null);
    try std.testing.expectEqual(@as(usize, 2), try store.revokeGameTokensForUser(user_id));
    const now = std.Io.Clock.real.now(std.testing.io).toSeconds();
    try std.testing.expect(!(try store.lazerUserOnline(user_id, now - 120)));
}

test "login result owns its token after the session is replaced" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/owned-login.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    var result = try bancho.login(std.testing.allocator, &store, &sessions, ari_stable_login, .{ 'A', 'U' }, 138.6, -34.9);
    defer result.deinit();
    try std.testing.expectEqual(user_id, result.user_id);
    try std.testing.expectEqual(@as(u32, 0), result.hardware_match_count);
    try std.testing.expect(!result.running_under_wine);
    const original_token = try std.testing.allocator.dupe(u8, result.token);
    defer std.testing.allocator.free(original_token);

    sessions.mutex.lockUncancelable(sessions.io);
    const replacement_user = (try store.userById(std.testing.allocator, user_id)).?;
    const replacement = sessions.create(replacement_user, 0, 0, 0) catch |err| {
        sessions.mutex.unlock(sessions.io);
        return err;
    };
    sessions.mutex.unlock(sessions.io);

    try std.testing.expectEqualStrings(original_token, result.token);
    try std.testing.expect(!std.mem.eql(u8, result.token, &replacement.token));
    try std.testing.expect(result.body.len > 7);
}

test "login ownership cleans every induced allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/login-allocation.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const ari_id = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    const sender_id = try store.register("mail sender", "sender@example.invalid", "11111111111111111111111111111111");
    _ = try store.storeDirectMessage(sender_id, ari_id, "allocation owned mail");
    var context: LoginAllocationContext = .{ .store = &store, .body = ari_stable_login };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, loginAllocationRun, .{&context});
}

test "a token superseded before its per-user poll lease cannot mutate storage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/stale-poll-mutation.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const owner_id = try store.register("poll owner", "poll-owner@example.invalid", "00000000000000000000000000000000");
    const friend_id = try store.register("poll friend", "poll-friend@example.invalid", "11111111111111111111111111111111");
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const original = try sessions.create((try store.userById(std.testing.allocator, owner_id)).?, 0, 0, 0);
    const old_token = original.token;
    try std.testing.expectEqual(owner_id, bancho.pollUserIdForToken(&sessions, &old_token).?);

    _ = try sessions.create((try store.userById(std.testing.allocator, owner_id)).?, 0, 0, 0);
    const friend_add = try clientIntPacket(std.testing.allocator, .friend_add, friend_id);
    defer std.testing.allocator.free(friend_add);
    try std.testing.expect((try bancho.pollByToken(std.testing.allocator, &store, &sessions, &old_token, friend_add)) == null);
    const friends = try store.friendIds(std.testing.allocator, owner_id);
    defer std.testing.allocator.free(friends);
    try std.testing.expect(std.mem.indexOfScalar(i32, friends, friend_id) == null);
}

test "stable login details require the complete client hardware contract" {
    const parsed = try bancho.parseStableLoginDetails(stable_login_details);
    try std.testing.expectEqualStrings("b20260811", parsed.osu_version);
    try std.testing.expectEqual(@as(i8, 0), parsed.utc_offset);
    try std.testing.expect(!parsed.display_city);
    try std.testing.expect(!parsed.pm_private);
    try std.testing.expect(!parsed.hardware.running_under_wine);
    try std.testing.expect(parsed.hardware.actionable);
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", parsed.hardware.osu_path_md5);

    const wine = try bancho.parseStableLoginDetails("b20260811cuttingedge|-5|1|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:runningunderwine:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccc:dddddddddddddddddddddddddddddddd:|1");
    try std.testing.expect(wine.hardware.running_under_wine);
    try std.testing.expect(wine.display_city);
    try std.testing.expect(wine.pm_private);
    try std.testing.expectEqual(@as(i8, -5), wine.utc_offset);

    const common_disk = try bancho.parseStableLoginDetails("b20260811|0|0|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1.2.3.:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccc:cfcd208495d565ef66e7dff9f98764da:|0");
    try std.testing.expect(!common_disk.hardware.actionable);
    try std.testing.expectError(error.InvalidLoginDetails, bancho.parseStableLoginDetails("b20260811|0"));
    try std.testing.expectError(error.InvalidLoginDetails, bancho.parseStableLoginDetails("20260811|0|0|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1.2.3.:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccc:dddddddddddddddddddddddddddddddd:|0"));
    try std.testing.expectError(error.InvalidLoginDetails, bancho.parseStableLoginDetails("b20260811|0|0|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1.2.3:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccc:dddddddddddddddddddddddddddddddd:|0"));
    try std.testing.expectError(error.InvalidLoginDetails, bancho.parseStableLoginDetails("b20260811|0|0|short:1.2.3.:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccc:dddddddddddddddddddddddddddddddd:|0"));
}

test "exact stable hardware matches remain review evidence without restriction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/hardware.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES" ++
            "(40,'first','first',x'00',x'00'),(41,'second','second',x'00',x'00')," ++
            "(42,'common-one','common_one',x'00',x'00'),(43,'common-two','common_two',x'00',x'00')",
    );
    const exact: storage.ClientHardware = .{
        .osu_path_md5 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .adapters_md5 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .uninstall_md5 = "cccccccccccccccccccccccccccccccc",
        .disk_signature_md5 = "dddddddddddddddddddddddddddddddd",
        .client_version = "b20260811",
        .running_under_wine = false,
        .actionable = true,
    };
    var first = try store.recordClientHardware(40, exact);
    first.deinit();
    var first_again = try store.recordClientHardware(40, exact);
    first_again.deinit();

    const partial: storage.ClientHardware = .{
        .osu_path_md5 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        .adapters_md5 = exact.adapters_md5,
        .uninstall_md5 = "ffffffffffffffffffffffffffffffff",
        .disk_signature_md5 = "11111111111111111111111111111111",
        .client_version = exact.client_version,
        .running_under_wine = false,
        .actionable = true,
    };
    var partial_result = try store.recordClientHardware(41, partial);
    defer partial_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), partial_result.matched_user_ids.len);
    var second_exact = try store.recordClientHardware(41, exact);
    defer second_exact.deinit();
    try std.testing.expectEqualSlices(i32, &.{40}, second_exact.matched_user_ids);
    var second_exact_again = try store.recordClientHardware(41, exact);
    defer second_exact_again.deinit();
    try std.testing.expectEqualSlices(i32, &.{40}, second_exact_again.matched_user_ids);

    const first_user = (try store.userById(std.testing.allocator, 40)).?;
    defer std.testing.allocator.free(first_user.name);
    defer std.testing.allocator.free(first_user.safe_name);
    const second_user = (try store.userById(std.testing.allocator, 41)).?;
    defer std.testing.allocator.free(second_user.name);
    defer std.testing.allocator.free(second_user.safe_name);
    try std.testing.expect(!first_user.restricted);
    try std.testing.expect(!second_user.restricted);

    var audit_stmt: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(storage.c.SQLITE_OK, storage.c.sqlite3_prepare_v2(store.db, "SELECT count(*) FROM audit_log WHERE action='anticheat.hardware_match' AND target='user:41' AND detail LIKE 'mode=observe exact_hardware_match%'", -1, &audit_stmt, null));
    defer _ = storage.c.sqlite3_finalize(audit_stmt);
    try std.testing.expectEqual(storage.c.SQLITE_ROW, storage.c.sqlite3_step(audit_stmt));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(audit_stmt, 0));

    var stmt: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(storage.c.SQLITE_OK, storage.c.sqlite3_prepare_v2(store.db, "SELECT occurrences FROM client_hardware WHERE user_id=40 AND adapters_md5='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'", -1, &stmt, null));
    defer _ = storage.c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(storage.c.SQLITE_ROW, storage.c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(c_int, 2), storage.c.sqlite3_column_int(stmt, 0));

    const common: storage.ClientHardware = .{
        .osu_path_md5 = exact.osu_path_md5,
        .adapters_md5 = exact.adapters_md5,
        .uninstall_md5 = exact.uninstall_md5,
        .disk_signature_md5 = "cfcd208495d565ef66e7dff9f98764da",
        .client_version = exact.client_version,
        .running_under_wine = false,
        .actionable = false,
    };
    var common_one = try store.recordClientHardware(42, common);
    common_one.deinit();
    var common_two = try store.recordClientHardware(43, common);
    defer common_two.deinit();
    try std.testing.expectEqual(@as(usize, 0), common_two.matched_user_ids.len);
}

test "an exact hardware login keeps both accounts online and unrestricted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/hardware-login.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const first_id = try store.register("first", "first@example.invalid", "00000000000000000000000000000000");
    const second_id = try store.register("second", "second@example.invalid", "00000000000000000000000000000000");
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const first_body = "first\n00000000000000000000000000000000\n" ++ stable_login_details;
    var first_login = try bancho.login(std.testing.allocator, &store, &sessions, first_body, .{ 'A', 'U' }, 0, 0);
    defer first_login.deinit();
    try std.testing.expectEqual(first_id, first_login.user_id);
    try std.testing.expectEqual(@as(u32, 0), first_login.hardware_match_count);
    try std.testing.expect(!first_login.running_under_wine);
    try std.testing.expect(sessions.byUser(first_id) != null);

    const second_body = "second\n00000000000000000000000000000000\n" ++ stable_login_details;
    var second_login = try bancho.login(std.testing.allocator, &store, &sessions, second_body, .{ 'A', 'U' }, 0, 0);
    defer second_login.deinit();
    try std.testing.expectEqual(second_id, second_login.user_id);
    try std.testing.expectEqual(@as(u32, 1), second_login.hardware_match_count);
    try std.testing.expect(!second_login.running_under_wine);
    try std.testing.expect(sessions.byUser(first_id) != null);
    try std.testing.expect(!sessions.byUser(first_id).?.user.restricted);
    try std.testing.expect(!sessions.byUser(second_id).?.user.restricted);
    var response_reader: protocol.Reader = .{ .data = second_login.body };
    while (try response_reader.next()) |packet| try std.testing.expect(@intFromEnum(packet.id) != @intFromEnum(protocol.ServerPacket.account_restricted));

    const first_user = (try store.userById(std.testing.allocator, first_id)).?;
    defer std.testing.allocator.free(first_user.name);
    defer std.testing.allocator.free(first_user.safe_name);
    const second_user = (try store.userById(std.testing.allocator, second_id)).?;
    defer std.testing.allocator.free(second_user.name);
    defer std.testing.allocator.free(second_user.safe_name);
    try std.testing.expect(!first_user.restricted);
    try std.testing.expect(!second_user.restricted);
}

test "high confidence stable client flags stay review only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/client-flags.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(50,'hq','hq',x'00',x'00'),(51,'registry','registry',x'00',x'00')");
    try store.recordLastFmFlag(51, @as(u32, 1) << 19);
    const registry_user = (try store.userById(std.testing.allocator, 51)).?;
    defer std.testing.allocator.free(registry_user.name);
    defer std.testing.allocator.free(registry_user.safe_name);
    try std.testing.expect(!registry_user.restricted);

    const hq_flags = (@as(u32, 1) << 17) | (@as(u32, 1) << 18);
    try store.recordLastFmFlag(50, hq_flags);
    const observation = anticheat_evidence.stableLastFm(hq_flags).?;
    _ = try store.recordAnticheatObservation(50, .{
        .source = .stable_lastfm,
        .module = anticheat_evidence.module_name,
        .action = observation.action,
        .reason = observation.reason,
        .risk_score = observation.risk_score,
        .confidence_bps = observation.confidence_bps,
        .evidence = observation.evidence,
        .decision_flags = observation.decision_flags,
        .rule_revision = observation.rule_revision,
    });
    const hq_user = (try store.userById(std.testing.allocator, 50)).?;
    defer std.testing.allocator.free(hq_user.name);
    defer std.testing.allocator.free(hq_user.safe_name);
    try std.testing.expect(!hq_user.restricted);

    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    _ = try sessions.create(try testSessionUser(std.testing.allocator, 50, "hq"), 0, 0, 0);
    try std.testing.expect(sessions.byUser(50) != null);
    const review = try store.staffAnticheatJson(std.testing.allocator);
    defer std.testing.allocator.free(review);
    try std.testing.expect(std.mem.indexOf(u8, review, "\"module\":\"zigcho-host\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, review, "\"source\":\"stable_lastfm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, review, "\"review_label\":\"pending\"") != null);
    var audit_stmt: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(storage.c.SQLITE_OK, storage.c.sqlite3_prepare_v2(store.db, "SELECT count(*) FROM audit_log WHERE action='stable.lastfm_flag' AND target='user:50' AND detail=?1", -1, &audit_stmt, null));
    defer _ = storage.c.sqlite3_finalize(audit_stmt);
    var detail_buf: [32]u8 = undefined;
    const detail = try std.fmt.bufPrint(&detail_buf, "flags:{d}", .{hq_flags});
    _ = storage.c.sqlite3_bind_text(audit_stmt, 1, detail.ptr, @intCast(detail.len), null);
    try std.testing.expectEqual(storage.c.SQLITE_ROW, storage.c.sqlite3_step(audit_stmt));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(audit_stmt, 0));
    try std.testing.expect(sessions.byUser(50) != null);
}

test "owned stable submissions do not borrow decrypted request memory" {
    var source = [_]u8{'x'} ** 160;
    const parsed: stable_score.Submission = .{
        .map_md5 = source[0..32],
        .username = source[32..36],
        .online_checksum = source[36..68],
        .n300 = 300,
        .n100 = 10,
        .n50 = 1,
        .ngeki = 0,
        .nkatu = 0,
        .nmiss = 2,
        .total_score = 123456,
        .max_combo = 321,
        .perfect = false,
        .grade = source[68..69],
        .mods = 0,
        .passed = true,
        .mode = 0,
        .client_time = source[69..81],
        .client_flags = source[81..82],
    };
    var owned = try stable_score.OwnedSubmission.init(std.testing.allocator, parsed);
    defer owned.deinit();

    @memset(&source, 'z');

    try std.testing.expectEqualStrings("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", owned.value.map_md5);
    try std.testing.expectEqualStrings("xxxx", owned.value.username);
    try std.testing.expectEqualStrings("x", owned.value.grade);
    try std.testing.expectEqual(@as(i64, 123456), owned.value.total_score);
}

test "downloaded anime defaults keep their real image formats" {
    const gif = @embedFile("assets/avatars/default-1.gif");
    const jpeg = @embedFile("assets/avatars/default-2.jpg");
    try std.testing.expect(std.mem.startsWith(u8, gif, "GIF89a"));
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xd8, 0xff }, jpeg[0..3]);
}

test "accounts keep one assigned default avatar" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/avatars.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const kai_avatar = (try store.avatarForUser(3)).?;
    try std.testing.expect(kai_avatar == 1 or kai_avatar == 2);
    try std.testing.expectEqual(kai_avatar, (try store.avatarForUser(3)).?);
    const user_id = try store.register("avatar test", "avatar-test@example.invalid", "00000000000000000000000000000000");
    const user_avatar = (try store.avatarForUser(user_id)).?;
    try std.testing.expect(user_avatar == 1 or user_avatar == 2);
    try std.testing.expectEqual(user_avatar, (try store.avatarForUser(user_id)).?);
    try std.testing.expect((try store.avatarForUser(999_999)) == null);
}

test "public name history follows account renames without exposing restricted users" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/name-history.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();

    const user_id = try store.register("old name", "name-history@example.invalid", "00000000000000000000000000000000");
    try store.updateAccountUsername(user_id, "new name");
    const history_json = (try store.siteNameHistoryJson(std.testing.allocator, user_id)).?;
    defer std.testing.allocator.free(history_json);
    var history = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, history_json, .{});
    defer history.deinit();
    try std.testing.expectEqual(@as(i64, user_id), history.value.object.get("id").?.integer);
    try std.testing.expectEqualStrings("new name", history.value.object.get("name").?.string);
    const entries = history.value.object.get("history").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("old name", entries[0].object.get("name").?.string);
    try std.testing.expect(entries[0].object.get("changed_at").?.integer > 0);

    try store.setRestricted(3, user_id, true, "name history privacy fixture");
    try std.testing.expect((try store.siteNameHistoryJson(std.testing.allocator, user_id)) == null);
    try std.testing.expect((try store.siteNameHistoryJson(std.testing.allocator, 3)) == null);
}

test "credential and restriction commits revoke the matching token family atomically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/account-token-transition.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();

    const password_id = try store.register("password target", "password-target@example.invalid", "00000000000000000000000000000000");
    const password_game = try store.issueGameTokenPair(password_id, 60, 60, false);
    const password_web = try store.issueToken(password_id, web_auth.player_scope, 60);
    try store.updateAccountPassword(password_id, "11111111111111111111111111111111");
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &password_game.access, "identify")) == null);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &password_game.refresh, "")) == null);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &password_web, web_auth.player_scope)) == null);

    const username_id = try store.register("username target", "username-target@example.invalid", "00000000000000000000000000000000");
    const username_game = try store.issueGameTokenPair(username_id, 60, 60, false);
    const username_web = try store.issueToken(username_id, web_auth.player_scope, 60);
    try store.updateAccountUsername(username_id, "renamed target");
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &username_game.access, "identify")) == null);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &username_game.refresh, "")) == null);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &username_web, web_auth.player_scope)) == null);

    const restricted_id = try store.register("restricted target", "restricted-target@example.invalid", "00000000000000000000000000000000");
    const restricted_game = try store.issueGameTokenPair(restricted_id, 60, 60, false);
    const restricted_web = try store.issueToken(restricted_id, web_auth.player_scope, 60);
    try store.setRestricted(3, restricted_id, true, "token transition fixture");
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &restricted_game.access, "identify")) == null);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &restricted_game.refresh, "")) == null);
    const appeal_session = (try store.authenticateToken(std.testing.allocator, &restricted_web, web_auth.player_scope)).?;
    defer {
        std.testing.allocator.free(appeal_session.name);
        std.testing.allocator.free(appeal_session.safe_name);
    }
}

test "website name history is an explicit profile-only dropdown" {
    try std.testing.expect(std.mem.indexOf(u8, server_website_source, "/api/v1/users/") != null);
    try std.testing.expect(std.mem.indexOf(u8, server_website_source, "/name-history") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "profile-name-history") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "name-history-tooltip") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "data-name-history") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "bindProfileNameHistory(identifier)") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "show previous usernames") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".profile-name-cluster{width:100%}.profile-name-history{position:static}.profile-name-history-menu{left:0;right:0;width:auto}") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "document.querySelector('.profile-view')!==view") != null);
}

test "developer server controls persist fixed gates and audit every change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/server-controls.db", .{tmp.sub_path});
    var actor_id: i32 = 0;
    {
        var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
        defer store.close();
        try store.migrate();
        actor_id = try store.register("infra dev", "infra-dev@example.invalid", "00000000000000000000000000000000");
        try std.testing.expect(try store.serverControlEnabled(.stable_scores));
        try store.setServerControl(actor_id, .stable_scores, false, "score maintenance window");
        try std.testing.expect(!try store.serverControlEnabled(.stable_scores));
        const json = try store.staffServerControlsJson(std.testing.allocator);
        defer std.testing.allocator.free(json);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, 45), parsed.value.object.get("schema").?.integer);
        const controls = parsed.value.object.get("controls").?.array.items;
        try std.testing.expectEqual(server_control.definitions.len, controls.len);
        var found = false;
        for (controls) |control| {
            if (!std.mem.eql(u8, control.object.get("key").?.string, "stable_scores")) continue;
            found = true;
            try std.testing.expect(!control.object.get("enabled").?.bool);
            try std.testing.expectEqualStrings("score maintenance window", control.object.get("reason").?.string);
            try std.testing.expectEqualStrings("infra dev", control.object.get("updated_by").?.string);
        }
        try std.testing.expect(found);
    }
    {
        var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
        defer store.close();
        try store.migrate();
        try std.testing.expect(!try store.serverControlEnabled(.stable_scores));
        try store.setServerControl(actor_id, .stable_scores, true, "maintenance finished");
        try std.testing.expect(try store.serverControlEnabled(.stable_scores));
        const audit = try store.staffAuditJson(std.testing.allocator);
        defer std.testing.allocator.free(audit);
        try std.testing.expect(std.mem.indexOf(u8, audit, "infra.feature") != null);
        try std.testing.expect(std.mem.indexOf(u8, audit, "feature:stable_scores") != null);
    }
}

test "developer operations plane stays bounded and recoverable" {
    try std.testing.expect(std.mem.indexOf(u8, server_website_source, "/api/v1/staff/infrastructure") != null);
    try std.testing.expect(std.mem.indexOf(u8, server_website_source, "developer access required") != null);
    try std.testing.expect(std.mem.indexOf(u8, server_website_source, "restart zigcho") != null);
    try std.testing.expect(std.mem.indexOf(u8, server_website_source, "infra.restart") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "no shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "deploy and rollback stay outside the browser") != null);
}

test "website profile settings and private avatar metadata stay account scoped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/site-account.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("site user", "site-user@example.invalid", "00000000000000000000000000000000");
    try store.updateCountry(user_id, .{ 'A', 'U' });
    const map_contents = @embedFile("testdata/synthetic-standard.osu");
    const map_metadata = try beatmap.parse(map_contents);
    const map_hash = beatmap.md5(map_contents);
    try store.upsertBeatmap(map_metadata, &map_hash, 3, 1.7931, 10, map_contents);
    const score: stable_score.Submission = .{
        .map_md5 = &map_hash,
        .username = "site user",
        .online_checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .ngeki = 0,
        .nkatu = 0,
        .nmiss = 0,
        .total_score = 1_000_000,
        .max_combo = 10,
        .perfect = true,
        .grade = "X",
        .mods = 0,
        .passed = true,
        .mode = 0,
        .client_time = "260824000000",
        .client_flags = "0",
    };
    _ = try store.insertStableScore(user_id, score, 26.8, "site replay", 12_000);
    _ = try store.setScorePinned(user_id, &map_hash, 0, 0, "vanilla", true);

    try store.updateSiteProfile(user_id, .{
        .bio = "hello <kai> & friends",
        .title = "tiny mapper",
        .pronouns = "she/her",
        .location = "somewhere quiet",
        .website = "https://kai.ovh",
        .accent = .violet,
        .preferred_mode = 3,
        .profile_source = .scorev2,
        .avatar_key = 2,
        .show_country = false,
        .show_profile_stats = false,
        .show_recent_scores = false,
    });
    const before_avatar = (try store.siteAccountJson(std.testing.allocator, user_id)).?;
    defer std.testing.allocator.free(before_avatar);
    var account = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, before_avatar, .{});
    defer account.deinit();
    try std.testing.expectEqualStrings("hello <kai> & friends", account.value.object.get("bio").?.string);
    try std.testing.expectEqualStrings("scorev2", account.value.object.get("profile_source").?.string);
    try std.testing.expectEqual(@as(i64, 3), account.value.object.get("preferred_mode").?.integer);
    try std.testing.expectEqual(@as(i64, 2), account.value.object.get("avatar_key").?.integer);
    try std.testing.expectEqualStrings("tiny mapper", account.value.object.get("profile_title").?.string);
    try std.testing.expectEqualStrings("violet", account.value.object.get("profile_accent").?.string);
    try std.testing.expect(!account.value.object.get("show_country").?.bool);
    try std.testing.expect(!account.value.object.get("has_custom_avatar").?.bool);
    const default_summary = (try store.lazerProfileSummary(user_id)).?;
    try std.testing.expect(default_summary.created_at > 0);
    try std.testing.expect(default_summary.last_visit > 0);
    try std.testing.expectEqual(@as(i64, 2), default_summary.avatar_version);
    try std.testing.expectEqual(@as(u8, 3), default_summary.preferred_mode);
    try std.testing.expectEqualStrings("tiny mapper", default_summary.title());
    try std.testing.expectEqualStrings("somewhere quiet", default_summary.location());
    try std.testing.expectEqualStrings("https://kai.ovh", default_summary.website());
    try std.testing.expect(!default_summary.show_country);
    try std.testing.expect(!default_summary.show_profile_stats);
    try std.testing.expect(!default_summary.show_recent_scores);
    const owner_token = try store.issueToken(user_id, web_auth.player_scope, 60);
    const owner = (try store.authenticateToken(std.testing.allocator, &owner_token, web_auth.player_scope)).?;
    defer std.testing.allocator.free(owner.name);
    defer std.testing.allocator.free(owner.safe_name);
    try std.testing.expect(!owner.show_country);
    try std.testing.expect(domain.profilePresenceDetailsVisible(owner.id, user_id, default_summary.show_recent_scores));
    try std.testing.expect(!domain.profilePresenceDetailsVisible(null, user_id, default_summary.show_recent_scores));
    try std.testing.expect(!domain.profilePresenceDetailsVisible(user_id + 1, user_id, default_summary.show_recent_scores));

    const etag: [64]u8 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".*;
    try store.setCustomAvatar(user_id, "4/0123456789abcdef.png", "image/png", etag);
    var avatar = (try store.customAvatarForUser(std.testing.allocator, user_id)).?;
    defer avatar.deinit();
    try std.testing.expectEqualStrings("4/0123456789abcdef.png", avatar.object_key);
    try std.testing.expectEqualStrings("image/png", avatar.content_type);
    try std.testing.expectEqualStrings(&etag, &avatar.etag);
    try std.testing.expect(avatar.updated_at > 0);
    const custom_summary = (try store.lazerProfileSummary(user_id)).?;
    try std.testing.expectEqual(avatar.updated_at, custom_summary.avatar_version);

    const public_profile = (try store.siteProfile(std.testing.allocator, user_id, .scorev2, 3)).?;
    defer std.testing.allocator.free(public_profile);
    try std.testing.expect(std.mem.indexOf(u8, public_profile, "\"bio\":\"hello <kai> & friends\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, public_profile, "\"profile_source\":\"scorev2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, public_profile, "\"preferred_mode\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, public_profile, "\"country\":\"XX\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, public_profile, "\"profile_title\":\"tiny mapper\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, public_profile, "\"selected_stats\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, public_profile, "\"recent_scores\":[]") != null);
    const public_scored_profile = (try store.siteProfile(std.testing.allocator, user_id, .all, 0)).?;
    defer std.testing.allocator.free(public_scored_profile);
    try std.testing.expect(std.mem.indexOf(u8, public_scored_profile, "\"stats\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, public_scored_profile, "\"pinned_scores\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, public_scored_profile, "\"top_scores\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, public_scored_profile, "\"first_place_count\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, public_scored_profile, "\"first_place_scores\":[]") != null);

    const owner_profile = (try store.siteProfileForViewer(std.testing.allocator, user_id, .all, 0, true)).?;
    defer std.testing.allocator.free(owner_profile);
    try std.testing.expect(std.mem.indexOf(u8, owner_profile, "\"country\":\"AU\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, owner_profile, "\"stats_public\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, owner_profile, "\"recent_scores_public\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, owner_profile, "\"selected_stats\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, owner_profile, "\"pinned_scores\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, owner_profile, "\"top_scores\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, owner_profile, "\"recent_scores\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, owner_profile, "\"first_place_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, owner_profile, "\"first_place_scores\":[{") != null);

    const lookup_user = (try store.userById(std.testing.allocator, user_id)).?;
    defer std.testing.allocator.free(lookup_user.name);
    defer std.testing.allocator.free(lookup_user.safe_name);
    try std.testing.expect(!lookup_user.show_country);
    var compact: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer compact.deinit();
    try user_json.writeCompact(&compact.writer, lookup_user, lookup_user.show_country);
    try std.testing.expect(std.mem.indexOf(u8, compact.written(), "\"country_code\":\"XX\"") != null);
    try std.testing.expect(try store.deleteCustomAvatar(user_id));
    try std.testing.expect((try store.customAvatarForUser(std.testing.allocator, user_id)) == null);
    const reset_summary = (try store.lazerProfileSummary(user_id)).?;
    try std.testing.expectEqual(@as(i64, 2), reset_summary.avatar_version);
}

test "private profile stats never enter website or lazer rankings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/private-rankings.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();

    const public_id = try store.register("public stats", "public-stats@example.invalid", "00000000000000000000000000000000");
    const private_id = try store.register("private stats", "private-stats@example.invalid", "11111111111111111111111111111111");
    const viewer_id = try store.register("ranking viewer", "ranking-viewer@example.invalid", "22222222222222222222222222222222");
    try store.updateCountry(public_id, .{ 'A', 'U' });
    try store.updateCountry(private_id, .{ 'A', 'U' });
    const public_settings: domain.SiteProfileSettings = .{ .bio = "", .title = "", .pronouns = "", .location = "", .website = "", .accent = .pink, .preferred_mode = 0, .profile_source = .all, .avatar_key = 1, .show_country = true, .show_profile_stats = true, .show_recent_scores = true };
    var private_settings = public_settings;
    private_settings.show_profile_stats = false;
    try store.updateSiteProfile(public_id, public_settings);
    try store.updateSiteProfile(private_id, private_settings);

    const map_contents = @embedFile("testdata/synthetic-standard.osu");
    const map_metadata = try beatmap.parse(map_contents);
    const map_hash = beatmap.md5(map_contents);
    try store.upsertBeatmap(map_metadata, &map_hash, 3, 1.7931, 10, map_contents);
    var public_score: stable_score.Submission = .{
        .map_md5 = &map_hash,
        .username = "public stats",
        .online_checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .ngeki = 0,
        .nkatu = 0,
        .nmiss = 0,
        .total_score = 100_000,
        .max_combo = 10,
        .perfect = true,
        .grade = "X",
        .mods = 0,
        .passed = true,
        .mode = 0,
        .client_time = "260825000000",
        .client_flags = "0",
    };
    const public_score_id = try store.insertStableScore(public_id, public_score, 50, "public replay", 10_000);
    var private_score = public_score;
    private_score.username = "private stats";
    private_score.online_checksum = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    private_score.total_score = 900_000;
    const private_score_id = try store.insertStableScore(private_id, private_score, 500, "private replay", 10_000);

    public_score.online_checksum = "cccccccccccccccccccccccccccccccc";
    public_score.total_score = 110_000;
    public_score.mods = stable_mods.score_v2;
    _ = try store.insertStableScore(public_id, public_score, 60, "public scorev2 replay", 10_000);
    private_score.online_checksum = "dddddddddddddddddddddddddddddddd";
    private_score.total_score = 910_000;
    private_score.mods = stable_mods.score_v2;
    _ = try store.insertStableScore(private_id, private_score, 600, "private scorev2 replay", 10_000);

    var lazer_fixture_buf: [2048]u8 = undefined;
    const lazer_fixture = try std.fmt.bufPrintZ(
        &lazer_fixture_buf,
        "INSERT INTO lazer_scores(user_id,beatmap_id,ruleset_id,total_score,total_score_without_mods,legacy_total_score,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,rank_namespace,pp,best) VALUES({d},{d},0,120000,120000,NULL,0.95,12,1,'A','[]','{{}}','{{}}','[]','vanilla',70,1),({d},{d},0,920000,920000,NULL,0.99,92,1,'S','[]','{{}}','{{}}','[]','vanilla',700,1)",
        .{ public_id, map_metadata.id, private_id, map_metadata.id },
    );
    try store.exec(lazer_fixture);
    try std.testing.expect(try store.recordReplayView(viewer_id, .stable, public_score_id));
    try std.testing.expect(try store.recordReplayView(viewer_id, .stable, private_score_id));

    for ([_]domain.SiteScoreSource{ .all, .stable, .lazer, .scorev2 }) |source| {
        const rankings = try store.siteRankings(std.testing.allocator, source, 0, 0);
        defer std.testing.allocator.free(rankings);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rankings, .{});
        defer parsed.deinit();
        const players = parsed.value.object.get("players").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), players.len);
        try std.testing.expectEqual(@as(i64, public_id), players[0].object.get("id").?.integer);
        try std.testing.expectEqual(@as(i64, 1), players[0].object.get("rank").?.integer);
    }

    for ([_]lazer.RankingKind{ .performance, .score }) |kind| {
        const rankings = try store.lazerRankingsJson(std.testing.allocator, 0, kind, null, 1);
        defer std.testing.allocator.free(rankings);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rankings, .{});
        defer parsed.deinit();
        const rows = parsed.value.object.get("ranking").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), rows.len);
        try std.testing.expectEqual(@as(i64, public_id), rows[0].object.get("user").?.object.get("id").?.integer);
        try std.testing.expectEqual(@as(i64, 1), rows[0].object.get("global_rank").?.integer);
        try std.testing.expectEqual(@as(i64, 1), rows[0].object.get("replays_watched_by_others").?.integer);
    }

    const countries_json = try store.lazerRankingsJson(std.testing.allocator, 0, .country, null, 1);
    defer std.testing.allocator.free(countries_json);
    var countries = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, countries_json, .{});
    defer countries.deinit();
    const country_rows = countries.value.object.get("ranking").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), country_rows.len);
    try std.testing.expectEqualStrings("AU", country_rows[0].object.get("code").?.string);
    try std.testing.expectEqual(@as(i64, 1), country_rows[0].object.get("active_users").?.integer);
    try std.testing.expectEqual(@as(i64, 1), country_rows[0].object.get("play_count").?.integer);
    try std.testing.expectEqual(@as(i64, 100_000), country_rows[0].object.get("ranked_score").?.integer);
    try std.testing.expectEqual(@as(i64, 50), country_rows[0].object.get("performance").?.integer);
}

test "website profile plays keep an accessible score details dialog" {
    try std.testing.expect(std.mem.indexOf(u8, index_page, "const emptyImage='data:image/gif") != null);
    try std.testing.expect(std.mem.indexOf(u8, server_fallback_source, "img-src 'self' data: https://a.kai.ovh") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".accent-bot #pinned-plays") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".accent-bot #recent-plays") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "profile-head-tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "profile-facts") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "aria-label','score filters") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "combined or client-specific") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "grid-template-columns:repeat(20,minmax(0,1fr))") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "grid-template-columns:repeat(4,minmax(0,1fr))") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".profile-stats .stat:nth-child(n){grid-column:auto") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "<dialog class=\"score-dialog\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "aria-labelledby=\"score-dialog-title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "data-score-detail") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "bindScoreDetails()") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "scoreDialogTrigger") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "data-play-collapse") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "data-pin-draggable") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "top.after(first)") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "drop a passed play here to pin it") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "touch or keyboard: open details") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "setAttribute('aria-expanded'") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "accountRequest(`/api/v1/account/pins/${match[1]}/${match[2]}`") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "download replay ↓") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "https://assets.ppy.sh/old-flags/") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "String.fromCodePoint") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "s.client==='lazer'?'native score':'stable score'") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "score without mods") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "w/o mods") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "https://assets.ppy.sh/medals/web/") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "class=\"achievement-icon\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "achievement-recent") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "achievement-group-title") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "a.icon_url") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "custom-achievement-icon") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "class=\"rank-history-chart\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "tracking starts now") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "if(points.length<2)return `<section class=\"rank-history\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "chartPoints=points.length===1") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "data-history-metric=\"rank\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "data-history-metric=\"pp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "bindProfileHistory(stats)") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "if(!points.length)return ''") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "speed_change") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "toFixed(2)+'×'") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "if(mapped)recent.after(mapped)") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "achievementAnchor=mapped||recent") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "achievementAnchor.insertAdjacentHTML('afterend'") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "online · '+esc(presence.client_label)") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "beatmaps.kai.ovh") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "stored sets") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "'irc.kai.ovh':['shared IRC','TLS IRC access to the same Stable, lazer and website chat history.','6697/tls','reserved']") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "['irc.kai.ovh','shared IRC']") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "<option value=\"kick\">kick from game</option>") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "<option value=\"revoke_sessions\">revoke every session</option>") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "['reports','reports']") != null);
}

test "website home leads with playable clients instead of a service directory" {
    try std.testing.expect(std.mem.indexOf(u8, index_page, "kai is the front door") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "const publicServices=") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "<h2>services</h2>") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "play osu! on kai.") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "Stable + zigcho!lazer") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "class=\"home-actions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "class=\"home-client stable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "class=\"home-client lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "https://github.com/zigcho/zigcho/releases") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "href=\"https://osu.kai.ovh/\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "href=\"/api/v1/status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "aria-label=\"live server facts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "get('/api/v1/rankings?source=all&mode=0')") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "playerRows(r.players,5,'all',0)") != null);
}

test "website routes keep shared language without sharing one layout" {
    try std.testing.expect(std.mem.indexOf(u8, index_page, "function structurePageView()") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "pageLayoutObserver.observe(app,{childList:true})") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "className='page-mode-bar'") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "auth.classList.add('auth-sheet')") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "tabs.classList.add('workspace-tabs')") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".page-view.error-page") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".page-view .changelog-build") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "function changelogMarkdown(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "changelogMarkdown(entry.message)") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "<p>${esc(entry.message)}</p>") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".changelog-copy h3") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".page-view .chat-layout") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".page-view .team-page-header") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".page-view .map-head") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".page-view .service-row{grid-template-columns:minmax(0,1fr) auto") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".page-view .stats .stat:last-child:nth-child(odd)") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "'/rankings':'rankings','/appeal':'appeal','/staff':'staff'") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "view.classList.add(type+'-view')") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "type=siteSession?'chat-workspace':'chat-gate'") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "type=staffSession?'staff-workspace':'staff-login'") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "className='chat-gate-rail'") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "className='changelog-feed'") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".home-view{display:grid;grid-template-columns:minmax(0,1fr) 250px}") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".rankings-view>.page-mode-bar{position:sticky") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".multiplayer-index-view>#multiplayer-groups{grid-column:1/-1;display:grid") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".changelog-view{display:grid;grid-template-columns:220px minmax(0,1fr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".login-view{display:grid;grid-template-columns:minmax(0,.85fr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".appeal-view{display:grid;grid-template-columns:280px minmax(0,1fr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".staff-login-view>.auth-sheet{grid-template-columns:minmax(0,1fr) minmax(0,1fr) auto") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".settings-view{display:grid;grid-template-columns:250px minmax(0,1fr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, ".staff-workspace-view{display:grid;grid-template-columns:180px minmax(0,1fr)") != null);
}

test "team JSON does not publish dead asset URLs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/team-assets.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("team owner", "team-owner@example.invalid", "00000000000000000000000000000000");
    const team_id = try store.createTeam(user_id, .{ .name = "quiet team", .short_name = "qt", .url = "", .description = "", .is_open = true, .default_ruleset_id = 0 });

    const missing_json = (try store.teamJson(std.testing.allocator, team_id, user_id, false)).?;
    defer std.testing.allocator.free(missing_json);
    var missing = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, missing_json, .{});
    defer missing.deinit();
    try std.testing.expect(missing.value.object.get("flag_url").? == .null);
    try std.testing.expect(missing.value.object.get("header_url").? == .null);

    const etag = [_]u8{'a'} ** 64;
    try store.setTeamAsset(team_id, "flag", "teams/1/flag.png", "image/png", etag, 64, 32);
    const stored_json = (try store.teamJson(std.testing.allocator, team_id, user_id, false)).?;
    defer std.testing.allocator.free(stored_json);
    var stored = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stored_json, .{});
    defer stored.deinit();
    try std.testing.expect(std.mem.startsWith(u8, stored.value.object.get("flag_url").?.string, "https://assets.kai.ovh/teams/"));
    try std.testing.expect(stored.value.object.get("header_url").? == .null);
}

test "lazer leaderboard teams do not publish a version zero flag" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try lazer.writeLeaderboardScore(&output.writer, .{
        .id = 1,
        .user_id = 4,
        .username = "raya",
        .country = "AU",
        .beatmap_id = 75,
        .ruleset_id = 0,
        .total_score = 1_000_000,
        .total_score_without_mods = 1_000_000,
        .pp = 100,
        .accuracy = 1,
        .max_combo = 100,
        .passed = true,
        .rank = "S",
        .mods_json = "[]",
        .statistics_json = "{}",
        .maximum_statistics_json = "{}",
        .pauses_json = "[]",
        .ended_at = "2026-08-23T00:00:00Z",
        .ranked = true,
        .team = try domain.TeamSummary.init(1, "uwu", "uwu", 0),
    });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("user").?.object.get("team").?.object.get("flag_url").? == .null);
}

test "website multiplayer exposes normal quick and ranked room views" {
    try std.testing.expect(std.mem.indexOf(u8, index_page, "data-nav=\"multiplayer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "async function multiplayerRooms()") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "async function multiplayerRoom(id)") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "'/api/v1/multiplayer/rooms'") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "multiplayerGroup('ranked play'") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "multiplayerGroup('quick play'") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "multiplayerGroup('multiplayer rooms'") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "state.kind==='ranked_play'") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "state.kind==='quick_play'") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "href=\"/multiplayer\" data-nav=\"multiplayer\"") != null);
}

test "website profile presence keeps optional owner auth and cross-client takeover wired" {
    try std.testing.expect(std.mem.indexOf(u8, server_website_source, "const token = web_auth.playerSessionToken(cookie_owned)") != null);
    try std.testing.expect(std.mem.indexOf(u8, server_website_source, "attachProfilePresence(profile, user_id, viewer_id)") != null);
    try std.testing.expect(std.mem.indexOf(u8, server_sessions_source, "bancho.suppressForTakeover") != null);
    try std.testing.expect(std.mem.indexOf(u8, server_lazer_source, "domain.profilePresenceClient(stable_presence != null, lazer_online)") != null);
}

test "lazer BSS reserves owned ids publishes pending and returns WIP through one atomic store path" {
    try std.testing.expectEqual(@as(u32, 1 << 5), bss.premium_privilege);
    try std.testing.expect(std.mem.indexOf(u8, server_router_source, "user.privileges & bss.premium_privilege == 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, server_router_source, "{\\\"error\\\":\\\"premium required\\\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "premium mapper uploads, package validation and BN review handoff") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "mappedBeatmapRows") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "id=\"mapped-beatmaps\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "data-map-preview=\"/preview/${set.id}.mp3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "recent.after(mapped)") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "bindMappedSetPreviews()") != null);
    try std.testing.expect(std.mem.indexOf(u8, server_primitives_source, "storeBssMedia") != null);
    try std.testing.expect(std.mem.indexOf(u8, server_platform_source, "package.media()") != null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/bss.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const owner_id = try store.register("bss owner", "bss-owner@example.invalid", "00000000000000000000000000000000");
    const other_id = try store.register("bss other", "bss-other@example.invalid", "00000000000000000000000000000000");
    try store.updateCountry(owner_id, .{ 'A', 'U' });
    try store.updateSiteProfile(owner_id, .{ .bio = "", .title = "", .pronouns = "", .location = "", .website = "", .accent = .pink, .preferred_mode = 0, .profile_source = .all, .avatar_key = 1, .show_country = false, .show_profile_stats = true, .show_recent_scores = true });

    var create = try bss.parseReserveInput(std.testing.allocator, "{\"beatmapset_id\":null,\"beatmaps_to_create\":1,\"beatmaps_to_keep\":[],\"target\":\"Pending\",\"notify_on_discussion_replies\":true}");
    defer create.deinit();
    var reservation = try store.reserveBssSubmission(std.testing.allocator, owner_id, create);
    defer reservation.deinit();
    try std.testing.expect(reservation.set_id >= bss.private_id_floor);
    try std.testing.expectEqual(@as(usize, 1), reservation.beatmap_ids.len);
    try std.testing.expect(reservation.beatmap_ids[0] >= bss.private_id_floor);

    const foreign_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"beatmapset_id\":{d},\"beatmaps_to_create\":0,\"beatmaps_to_keep\":[{d}],\"target\":\"WIP\",\"notify_on_discussion_replies\":false}}", .{ reservation.set_id, reservation.beatmap_ids[0] });
    defer std.testing.allocator.free(foreign_json);
    var foreign_update = try bss.parseReserveInput(std.testing.allocator, foreign_json);
    defer foreign_update.deinit();
    try std.testing.expectError(error.BssNotOwner, store.reserveBssSubmission(std.testing.allocator, other_id, foreign_update));

    const map_id_text = try std.fmt.allocPrint(std.testing.allocator, "BeatmapID:{d}", .{reservation.beatmap_ids[0]});
    defer std.testing.allocator.free(map_id_text);
    const set_id_text = try std.fmt.allocPrint(std.testing.allocator, "BeatmapSetID:{d}", .{reservation.set_id});
    defer std.testing.allocator.free(set_id_text);
    const with_map_id = try std.mem.replaceOwned(u8, std.testing.allocator, @embedFile("testdata/synthetic-standard.osu"), "BeatmapID:900000001", map_id_text);
    defer std.testing.allocator.free(with_map_id);
    const map = try std.mem.replaceOwned(u8, std.testing.allocator, with_map_id, "BeatmapSetID:900000000", set_id_text);
    defer std.testing.allocator.free(map);
    const exported_map = try std.mem.concat(std.testing.allocator, u8, &.{ "\xef\xbb\xbf", map });
    defer std.testing.allocator.free(exported_map);
    const archive = try storedZip(std.testing.allocator, "Zigcho [Tests].osu", exported_map);
    defer std.testing.allocator.free(archive);
    var package = try bss.preparePackage(std.testing.allocator, archive, reservation.set_id, reservation.beatmap_ids);
    defer package.deinit();
    const digest = bss.archiveSha256(archive);
    try store.publishBssSubmission(owner_id, reservation.set_id, &package, archive, &digest);

    const stored_map = (try store.beatmapInfoById(std.testing.allocator, reservation.beatmap_ids[0])).?;
    defer std.testing.allocator.free(stored_map.artist);
    defer std.testing.allocator.free(stored_map.title);
    defer std.testing.allocator.free(stored_map.version);
    defer std.testing.allocator.free(stored_map.creator);
    try std.testing.expectEqual(@as(i8, 2), stored_map.status);
    var collision_sql_buf: [512]u8 = undefined;
    const collision_sql = try std.fmt.bufPrintZ(&collision_sql_buf, "INSERT INTO upstream_users(id,username,country,join_date) VALUES(35712887,'Raya_old_6','AU','2020-01-01T00:00:00Z'); UPDATE beatmaps SET creator_id=35712887 WHERE set_id={d};", .{reservation.set_id});
    try store.exec(collision_sql);
    var local_creator = (try store.beatmapSetCreator(std.testing.allocator, reservation.set_id)).?;
    defer local_creator.deinit();
    try std.testing.expect(local_creator.is_local);
    try std.testing.expectEqual(owner_id, local_creator.user_id.?);
    try std.testing.expectEqualStrings("bss owner", local_creator.name);

    const lookup = (try store.lazerBeatmapLookup(std.testing.allocator, reservation.beatmap_ids[0], null, owner_id)).?;
    defer std.testing.allocator.free(lookup);
    var parsed_lookup = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lookup, .{});
    defer parsed_lookup.deinit();
    try std.testing.expectEqual(@as(i64, owner_id), parsed_lookup.value.object.get("user_id").?.integer);
    try std.testing.expectEqualStrings("bss owner", parsed_lookup.value.object.get("owners").?.array.items[0].object.get("username").?.string);
    const lookup_set = parsed_lookup.value.object.get("beatmapset").?.object;
    try std.testing.expectEqual(@as(i64, owner_id), lookup_set.get("user_id").?.integer);
    try std.testing.expectEqualStrings("bss owner", lookup_set.get("creator").?.string);
    try std.testing.expectEqualStrings("bss owner", lookup_set.get("user").?.object.get("username").?.string);
    try std.testing.expectEqualStrings("XX", lookup_set.get("user").?.object.get("country_code").?.string);

    const pending_sets = try store.lazerUserBeatmapSetsJson(std.testing.allocator, owner_id, "pending", 0, 50, owner_id);
    defer std.testing.allocator.free(pending_sets);
    var parsed_pending_sets = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, pending_sets, .{});
    defer parsed_pending_sets.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_pending_sets.value.array.items.len);
    try std.testing.expectEqual(@as(i64, reservation.set_id), parsed_pending_sets.value.array.items[0].object.get("id").?.integer);

    const owned_search = try store.lazerOwnedBeatmapSearch(std.testing.allocator, owner_id, "", -1, 0, owner_id);
    defer std.testing.allocator.free(owned_search);
    var parsed_owned_search = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, owned_search, .{});
    defer parsed_owned_search.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_owned_search.value.object.get("beatmapsets").?.array.items.len);
    try std.testing.expectEqual(@as(i64, reservation.set_id), parsed_owned_search.value.object.get("beatmapsets").?.array.items[0].object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 1), parsed_owned_search.value.object.get("total").?.integer);
    try std.testing.expect(parsed_owned_search.value.object.get("cursor").? == .null);

    const wrong_mode_search = try store.lazerOwnedBeatmapSearch(std.testing.allocator, owner_id, "", 3, 0, owner_id);
    defer std.testing.allocator.free(wrong_mode_search);
    var parsed_wrong_mode_search = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, wrong_mode_search, .{});
    defer parsed_wrong_mode_search.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed_wrong_mode_search.value.object.get("beatmapsets").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 0), parsed_wrong_mode_search.value.object.get("total").?.integer);

    const score_body = try std.fmt.allocPrint(std.testing.allocator, "{{\"beatmap_id\":{d},\"ruleset_id\":0,\"total_score\":987654,\"legacy_total_score\":900000,\"accuracy\":0.985,\"max_combo\":321,\"passed\":true,\"mods\":[],\"statistics\":{{}},\"client_version\":\"2026.823.0\"}}", .{reservation.beatmap_ids[0]});
    defer std.testing.allocator.free(score_body);
    var parsed_score = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, score_body, .{});
    defer parsed_score.deinit();
    _ = try store.insertLazerScore(owner_id, try lazer.parseScore(parsed_score.value), 100, "[]", "{}", "{}", "[]", &.{});
    const pending_board = try store.lazerLeaderboardJson(std.testing.allocator, owner_id, reservation.beatmap_ids[0], 0, .vanilla, "[]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(pending_board);
    var parsed_pending_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, pending_board, .{});
    defer parsed_pending_board.deinit();
    try std.testing.expectEqual(@as(i64, 0), parsed_pending_board.value.object.get("score_count").?.integer);
    try std.testing.expect(parsed_pending_board.value.object.get("user_score").? == .null);

    const site_profile = (try store.siteProfile(std.testing.allocator, owner_id, .all, 0)).?;
    defer std.testing.allocator.free(site_profile);
    var parsed_site_profile = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, site_profile, .{});
    defer parsed_site_profile.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_site_profile.value.object.get("beatmapsets").?.array.items.len);
    try std.testing.expectEqualStrings("bss owner", parsed_site_profile.value.object.get("beatmapsets").?.array.items[0].object.get("creator").?.string);
    const ranking = try store.staffRankingJson(std.testing.allocator);
    defer std.testing.allocator.free(ranking);
    const set_marker = try std.fmt.allocPrint(std.testing.allocator, "\"set_id\":{d}", .{reservation.set_id});
    defer std.testing.allocator.free(set_marker);
    try std.testing.expect(std.mem.indexOf(u8, ranking, set_marker) != null);

    var current_archive = try bss.parseArchive(std.testing.allocator, archive);
    defer current_archive.deinit();
    const reservation_json = try bss.reservationJson(std.testing.allocator, reservation, &current_archive);
    defer std.testing.allocator.free(reservation_json);
    try std.testing.expect(std.mem.indexOf(u8, reservation_json, "Zigcho [Tests].osu") != null);

    const update_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"beatmapset_id\":{d},\"beatmaps_to_create\":0,\"beatmaps_to_keep\":[{d}],\"target\":\"WIP\",\"notify_on_discussion_replies\":false}}", .{ reservation.set_id, reservation.beatmap_ids[0] });
    defer std.testing.allocator.free(update_json);
    var update = try bss.parseReserveInput(std.testing.allocator, update_json);
    defer update.deinit();
    var next = try store.reserveBssSubmission(std.testing.allocator, owner_id, update);
    defer next.deinit();
    try std.testing.expectEqual(@as(u32, 2), next.revision);
    const changed_map = try std.mem.replaceOwned(u8, std.testing.allocator, map, "Version:Tests", "Version:Tests 2");
    defer std.testing.allocator.free(changed_map);
    const patch_body = try std.fmt.allocPrint(std.testing.allocator, "--zigcho-bss\r\nContent-Disposition: form-data; name=\"filesChanged\"; filename=\"Zigcho [Tests].osu\"\r\nContent-Type: application/octet-stream\r\n\r\n{s}\r\n--zigcho-bss--\r\n", .{changed_map});
    defer std.testing.allocator.free(patch_body);
    var form = try multipart.parse(std.testing.allocator, patch_body, "zigcho-bss");
    defer form.deinit();
    const patched = try bss.applyPatch(std.testing.allocator, archive, &form);
    defer std.testing.allocator.free(patched);
    var next_package = try bss.preparePackage(std.testing.allocator, patched, next.set_id, next.beatmap_ids);
    defer next_package.deinit();
    const next_digest = bss.archiveSha256(patched);
    try store.publishBssSubmission(owner_id, next.set_id, &next_package, patched, &next_digest);
    const updated_map = (try store.beatmapInfoById(std.testing.allocator, next.beatmap_ids[0])).?;
    defer std.testing.allocator.free(updated_map.artist);
    defer std.testing.allocator.free(updated_map.title);
    defer std.testing.allocator.free(updated_map.version);
    defer std.testing.allocator.free(updated_map.creator);
    try std.testing.expectEqualStrings("Tests 2", updated_map.version);
    try std.testing.expectEqual(@as(i8, 1), updated_map.status);

    const traversal = try storedZip(std.testing.allocator, "../outside.osu", map);
    defer std.testing.allocator.free(traversal);
    try std.testing.expectError(error.InvalidBssFilename, bss.parseArchive(std.testing.allocator, traversal));
}

test "failed legacy BSS reservations are atomically reissued above one billion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/bss-legacy-reissue.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const owner_id = try store.register("bss legacy owner", "bss-legacy-owner@example.test", "00000000000000000000000000000000");
    var fixture_sql_buf: [1024]u8 = undefined;
    const fixture_sql = try std.fmt.bufPrintZ(
        &fixture_sql_buf,
        "INSERT INTO beatmap_submissions(set_id,owner_id,target,state,last_error) VALUES(100000000,{d},'WIP','failed','InvalidBssBeatmaps');" ++
            "INSERT INTO beatmap_submission_maps(set_id,beatmap_id,position) VALUES(100000000,100000000,0),(100000000,100000001,1);",
        .{owner_id},
    );
    try store.exec(fixture_sql);

    var retry = try bss.parseReserveInput(std.testing.allocator, "{\"beatmapset_id\":100000000,\"beatmaps_to_create\":0,\"beatmaps_to_keep\":[100000000,100000001],\"target\":\"Pending\",\"notify_on_discussion_replies\":true}");
    defer retry.deinit();
    var reservation = try store.reserveBssSubmission(std.testing.allocator, owner_id, retry);
    defer reservation.deinit();
    try std.testing.expect(reservation.set_id >= bss.private_id_floor);
    try std.testing.expectEqual(@as(u32, 1), reservation.revision);
    try std.testing.expectEqual(@as(usize, 2), reservation.beatmap_ids.len);
    for (reservation.beatmap_ids) |id| try std.testing.expect(id >= bss.private_id_floor);

    var legacy_alias: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "SELECT replacement_set_id FROM beatmap_submissions WHERE set_id=100000000", -1, &legacy_alias, null));
    defer _ = storage.c.sqlite3_finalize(legacy_alias);
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(legacy_alias));
    try std.testing.expectEqual(@as(i64, reservation.set_id), storage.c.sqlite3_column_int64(legacy_alias, 0));

    var retried = try store.reserveBssSubmission(std.testing.allocator, owner_id, retry);
    defer retried.deinit();
    try std.testing.expectEqual(reservation.set_id, retried.set_id);
    try std.testing.expectEqual(@as(u32, 2), retried.revision);
    try std.testing.expectEqualSlices(i32, reservation.beatmap_ids, retried.beatmap_ids);
}

test "stable screenshots survive storage with exact type isolation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/screenshots.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("screenshot test", "screenshot-test@example.invalid", "00000000000000000000000000000000");
    const png = "\x89PNG\r\n\x1a\nbodyIEND\xaeB`\x82";
    try std.testing.expect(try store.putScreenshot(user_id, "Ab1_-xyZ", "png", png));
    try std.testing.expect(!try store.putScreenshot(user_id, "Ab1_-xyZ", "png", "collision"));
    const stored = (try store.screenshot(std.testing.allocator, "Ab1_-xyZ", "png")).?;
    defer std.testing.allocator.free(stored);
    try std.testing.expectEqualSlices(u8, png, stored);
    try std.testing.expect((try store.screenshot(std.testing.allocator, "Ab1_-xyZ", "jpeg")) == null);
}

test "beatmap covers and previews survive the bounded media cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/beatmap-media.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const map = @embedFile("testdata/synthetic-standard.osu");
    const metadata = try beatmap.parse(map);
    const hash = beatmap.md5(map);
    try store.upsertBeatmap(metadata, &hash, 3, 1.7931, 10, map);
    const png = "\x89PNG\r\n\x1a\ncover bytes";
    const wav = "RIFFxxxxWAVEpreview bytes";
    var source: bss.Archive = .{ .allocator = std.testing.allocator };
    defer source.deinit();
    for ([_][]const u8{ "Zigcho [Tests].osu", "background.png", "synthetic.mp3" }, [_][]const u8{ map, png, wav }) |name, data| {
        try source.entries.append(std.testing.allocator, .{
            .allocator = std.testing.allocator,
            .name = try std.testing.allocator.dupe(u8, name),
            .data = try std.testing.allocator.dupe(u8, data),
        });
    }
    const archive = try bss.buildArchive(std.testing.allocator, &source);
    defer std.testing.allocator.free(archive);
    const digest = bss.archiveSha256(archive);
    try store.upsertBeatmapArchive(metadata.set_id, &digest, archive);
    var sync = beatmap_media.Sync.init(std.testing.allocator, std.testing.io, 64 * 1024 * 1024);
    var list_cover = (try sync.get(&store, .{ .set_id = metadata.set_id, .kind = .list })).?;
    defer list_cover.deinit(std.testing.allocator);
    try std.testing.expectEqual(media_contract.ContentType.png, list_cover.content_type);
    try std.testing.expectEqualSlices(u8, png, list_cover.data);
    var preview = (try sync.get(&store, .{ .set_id = metadata.set_id, .kind = .preview })).?;
    defer preview.deinit(std.testing.allocator);
    try std.testing.expectEqual(media_contract.ContentType.wav, preview.content_type);
    try std.testing.expectEqualSlices(u8, wav, preview.data);
    try std.testing.expectError(error.InvalidBeatmapMedia, store.putBeatmapMedia(metadata.set_id, .cover, .wav, wav));
    try std.testing.expectError(error.UnknownBeatmapSet, store.putBeatmapMedia(metadata.set_id + 1, .cover, .png, png));
    const before = try store.beatmapMediaCacheStats();
    try std.testing.expectEqual(@as(i64, 2), before.entries);
    try std.testing.expectEqual(@as(i64, png.len + wav.len), before.bytes);
    const pruned = try store.pruneBeatmapMedia(0);
    try std.testing.expectEqual(@as(i64, 2), pruned.entries);
    try std.testing.expectEqual(@as(i64, 0), (try store.beatmapMediaCacheStats()).entries);
}

test "object storage keeps the database rollback copy out of cache pruning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/object-rollback.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status) VALUES(1,10,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','a','a','a','a',3)");
    try store.upsertBeatmapArchive(10, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "archive");
    try store.putBeatmapMedia(10, .cover, .jpeg, "\xff\xd8\xffcover\xff\xd9");
    store.bindObjectStorage(.{
        .endpoint = "https://sin1.contabostorage.com",
        .bucket = "data",
        .region = "default",
        .access_key_id = "fixture-access",
        .secret_access_key = "fixture-secret",
    });
    const archives = try store.pruneBeatmapArchives(0);
    const media = try store.pruneBeatmapMedia(0);
    try std.testing.expectEqual(@as(i64, 0), archives.entries);
    try std.testing.expectEqual(@as(i64, 0), archives.bytes);
    try std.testing.expectEqual(@as(i64, 0), media.entries);
    try std.testing.expectEqual(@as(i64, 0), media.bytes);
    try std.testing.expectEqual(@as(i64, 1), (try store.beatmapCacheStats()).entries);
    try std.testing.expectEqual(@as(i64, 1), (try store.beatmapMediaCacheStats()).entries);
}

test "Akatsuki ranks map into local leaderboard states" {
    try std.testing.expectEqual(@as(i8, 3), beatmap_sync.localStatus(1));
    try std.testing.expectEqual(@as(i8, 4), beatmap_sync.localStatus(2));
    try std.testing.expectEqual(@as(i8, 5), beatmap_sync.localStatus(3));
    try std.testing.expectEqual(@as(i8, 6), beatmap_sync.localStatus(4));
    try std.testing.expectEqual(@as(i8, 2), beatmap_sync.localStatus(-2));
}

test "beatmap statuses use each client protocol's values" {
    try std.testing.expectEqual(@as(i32, 0), storage.Store.stableStatus(2));
    try std.testing.expectEqual(@as(i32, 2), storage.Store.stableStatus(3));
    try std.testing.expectEqual(@as(i32, 3), storage.Store.stableStatus(4));
    try std.testing.expectEqual(@as(i32, 4), storage.Store.stableStatus(5));
    try std.testing.expectEqual(@as(i32, 5), storage.Store.stableStatus(6));
    try std.testing.expectEqual(@as(i32, 2), storage.Store.directStatus(2));
    try std.testing.expectEqual(@as(i32, 0), storage.Store.directStatus(3));
    try std.testing.expectEqual(@as(i32, 3), storage.Store.directStatus(5));
    try std.testing.expectEqual(@as(i32, 8), storage.Store.directStatus(6));
    try std.testing.expectEqualStrings("ranked", storage.Store.lazerStatus(3));
    try std.testing.expectEqualStrings("approved", storage.Store.lazerStatus(4));
    try std.testing.expectEqualStrings("qualified", storage.Store.lazerStatus(5));
    try std.testing.expectEqualStrings("loved", storage.Store.lazerStatus(6));
}

test "stable beatmap grades keep each ruleset's exact boundaries" {
    try std.testing.expectEqualStrings("S", storage.Store.stableGrade(0, 0, 0, 91, 8, 1, 0));
    try std.testing.expectEqualStrings("A", storage.Store.stableGrade(0, 0, 0, 90, 9, 1, 0));
    try std.testing.expectEqualStrings("S", storage.Store.stableGrade(1, 0, 0.95, 91, 9, 0, 0));
    try std.testing.expectEqualStrings("A", storage.Store.stableGrade(1, 0, 0.95, 90, 10, 0, 0));
    try std.testing.expectEqualStrings("A", storage.Store.stableGrade(1, 0, 0.90, 91, 8, 0, 1));
    try std.testing.expectEqualStrings("S", storage.Store.stableGrade(2, 0, 0.9801, 0, 0, 0, 0));
    try std.testing.expectEqualStrings("A", storage.Store.stableGrade(2, 0, 0.98, 0, 0, 0, 0));
    try std.testing.expectEqualStrings("B", storage.Store.stableGrade(2, 0, 0.94, 0, 0, 0, 0));
    try std.testing.expectEqualStrings("C", storage.Store.stableGrade(2, 0, 0.90, 0, 0, 0, 0));
    try std.testing.expectEqualStrings("D", storage.Store.stableGrade(2, 0, 0.85, 0, 0, 0, 0));
    try std.testing.expectEqualStrings("S", storage.Store.stableGrade(3, 0, 0.9501, 0, 0, 0, 0));
    try std.testing.expectEqualStrings("SH", storage.Store.stableGrade(3, 1 << 3, 0.9501, 0, 0, 0, 0));
}

test "stable beatmap info comments and direct mail keep the real client contract" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/stable-web-contract.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const player_id = try store.register("stable player", "stable-player@example.invalid", "00000000000000000000000000000000");
    const supporter_id = try store.register("map supporter", "map-supporter@example.invalid", "11111111111111111111111111111111");
    try store.exec("UPDATE users SET privileges=privileges|(1<<4) WHERE safe_name='map_supporter'");
    const map = @embedFile("testdata/synthetic-standard.osu");
    const metadata = try beatmap.parse(map);
    const hash = beatmap.md5(map);
    try store.upsertBeatmap(metadata, &hash, 6, 1.7931, 10, map);
    const score: stable_score.Submission = .{
        .map_md5 = &hash,
        .username = "stable player",
        .online_checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .ngeki = 0,
        .nkatu = 0,
        .nmiss = 0,
        .total_score = 1_000_000,
        .max_combo = 10,
        .perfect = true,
        .grade = "XH",
        .mods = 1 << 3,
        .passed = true,
        .mode = 0,
        .client_time = "260811000000",
        .client_flags = "0",
    };
    _ = try store.insertStableScore(player_id, score, 26.8, "replay", 12_000);
    const filename = try std.fmt.allocPrint(std.testing.allocator, "{s} - {s} ({s}) [{s}].osu", .{ metadata.artist, metadata.title, metadata.creator, metadata.version });
    defer std.testing.allocator.free(filename);
    const by_filename = (try store.stableBeatmapInfoByFilename(player_id, filename)).?;
    try std.testing.expectEqual(metadata.id, by_filename.id);
    try std.testing.expectEqual(@as(i32, 4), by_filename.status);
    try std.testing.expectEqualStrings("XH", by_filename.grades[0]);
    try std.testing.expectEqualStrings("N", by_filename.grades[1]);
    const by_id = (try store.stableBeatmapInfoById(player_id, metadata.id)).?;
    try std.testing.expectEqualSlices(u8, &hash, &by_id.md5);

    try store.addBeatmapComment(supporter_id, "song", metadata.set_id, 12.5, "whole set comment", "ff66aa");
    try store.addBeatmapComment(player_id, "map", metadata.id, 20, "map comment", null);
    const comments = try store.beatmapComments(std.testing.allocator, 0, metadata.set_id, metadata.id);
    defer std.testing.allocator.free(comments);
    try std.testing.expect(std.mem.indexOf(u8, comments, "12.5\tsong\tsupporter|ff66aa\twhole set comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, comments, "20\tmap\t\tmap comment") != null);

    _ = try store.storeDirectMessage(supporter_id, player_id, "offline hello");
    const unread = try store.unreadDirectMessages(std.testing.allocator, player_id);
    defer {
        for (unread) |*message| message.deinit(std.testing.allocator);
        std.testing.allocator.free(unread);
    }
    try std.testing.expectEqual(@as(usize, 1), unread.len);
    try std.testing.expectEqualStrings("map supporter", unread[0].from_name);
    try std.testing.expectEqualStrings("offline hello", unread[0].message);
    try store.markDirectMessagesRead(player_id, supporter_id);
    const read = try store.unreadDirectMessages(std.testing.allocator, player_id);
    defer std.testing.allocator.free(read);
    try std.testing.expectEqual(@as(usize, 0), read.len);
}

test "lazer comments support listing replies votes deletion and reports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/lazer-comments.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const author_id = try store.register("comment author", "comment-author@example.invalid", "00000000000000000000000000000000");
    const voter_id = try store.register("comment voter", "comment-voter@example.invalid", "11111111111111111111111111111111");
    const target: storage.LazerCommentTarget = .{ .commentable = .beatmapset, .id = 900000000 };
    const parent_id = try store.addLazerComment(author_id, target, null, "first comment");
    const reply_id = try store.addLazerComment(voter_id, target, parent_id, "reply comment");
    try std.testing.expect(try store.setLazerCommentVote(voter_id, parent_id, true));
    const root_json = try store.lazerCommentsJson(std.testing.allocator, voter_id, target, .top, 1, 0, 0);
    defer std.testing.allocator.free(root_json);
    var root = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, root_json, .{});
    defer root.deinit();
    const comment = root.value.object.get("comments").?.array.items[0].object;
    try std.testing.expectEqual(parent_id, comment.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 1), comment.get("replies_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), comment.get("votes_count").?.integer);
    try std.testing.expectEqual(parent_id, root.value.object.get("user_votes").?.array.items[0].integer);
    const replies_json = try store.lazerCommentsJson(std.testing.allocator, author_id, target, .old, 1, parent_id, 0);
    defer std.testing.allocator.free(replies_json);
    var replies = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, replies_json, .{});
    defer replies.deinit();
    try std.testing.expectEqual(reply_id, replies.value.object.get("comments").?.array.items[0].object.get("id").?.integer);
    try std.testing.expect(try store.reportLazerComment(voter_id, parent_id, "Spam", "test report"));
    try std.testing.expect(!try store.reportLazerComment(voter_id, parent_id, "Spam", "duplicate"));
    try std.testing.expect(try store.deleteLazerComment(author_id, parent_id, false));
    const deleted_json = try store.lazerCommentsJson(std.testing.allocator, author_id, target, .new, 1, 0, parent_id);
    defer std.testing.allocator.free(deleted_json);
    var deleted = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, deleted_json, .{});
    defer deleted.deinit();
    try std.testing.expect(deleted.value.object.get("comments").?.array.items[0].object.get("deleted_at").? != .null);
}

test "stable login keeps replayed private mail unread until the client polls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/stable-offline-mail.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const recipient = try store.register("mail target", "mail-target@example.invalid", "00000000000000000000000000000000");
    const sender = try store.register("mail sender", "mail-sender@example.invalid", "11111111111111111111111111111111");
    _ = try store.storeDirectMessage(sender, recipient, "saved while you were away");
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    var result = try bancho.login(std.testing.allocator, &store, &sessions, "mail target\n00000000000000000000000000000000\n" ++ stable_login_details, .{ 'A', 'U' }, 0, 0);
    defer result.deinit();
    try expectMessageText(result.body, "Unread messages");
    try expectMessageContains(result.body, "saved while you were away");
    const unread = try store.unreadDirectMessages(std.testing.allocator, recipient);
    defer {
        for (unread) |*message| message.deinit(std.testing.allocator);
        std.testing.allocator.free(unread);
    }
    try std.testing.expectEqual(@as(usize, 1), unread.len);
    const poll = (try bancho.pollByToken(std.testing.allocator, &store, &sessions, result.token, "")).?;
    defer std.testing.allocator.free(poll);
    const read = try store.unreadDirectMessages(std.testing.allocator, recipient);
    defer std.testing.allocator.free(read);
    try std.testing.expectEqual(@as(usize, 0), read.len);
}

test "stable score response reports the committed one based leaderboard rank" {
    const score: stable_score.Submission = .{
        .map_md5 = "0123456789abcdef0123456789abcdef",
        .username = "ari",
        .online_checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .ngeki = 0,
        .nkatu = 0,
        .nmiss = 0,
        .total_score = 900_000,
        .max_combo = 10,
        .perfect = true,
        .grade = "X",
        .mods = 0,
        .passed = true,
        .mode = 0,
        .client_time = "260811000000",
        .client_flags = "0",
    };
    const response = try stable_response.scoreSubmission(std.testing.allocator, 4, 99, score, .{ .id = 10, .set_id = 20, .plays = 8, .passes = 6 }, .{ .rank = 3, .submitted_is_best = true }, .{ .global_rank = 8, .pp = 100 }, .{ .global_rank = 7, .pp = 120 }, 42.25, .{});
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "chartId:beatmap") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "rankAfter:4") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "onlineScoreId:99") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "chartId:overall") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "rankBefore:8|rankAfter:7") != null);
}

test "beatmap ranking records nominations and lets BNs set every stable status" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/ranking.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const requester = try store.register("requester", "requester@example.invalid", "00000000000000000000000000000000");
    const first_bn = try store.register("first bn", "first-bn@example.invalid", "11111111111111111111111111111111");
    const second_bn = try store.register("second bn", "second-bn@example.invalid", "22222222222222222222222222222222");
    const map = @embedFile("testdata/synthetic-standard.osu");
    const metadata = try beatmap.parse(map);
    const hash = beatmap.md5(map);
    try store.upsertBeatmap(metadata, &hash, 2, 1.7931, 10, map);
    const pending_score: stable_score.Submission = .{
        .map_md5 = &hash,
        .username = "requester",
        .online_checksum = "dddddddddddddddddddddddddddddddd",
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .ngeki = 0,
        .nkatu = 0,
        .nmiss = 0,
        .total_score = 1_000_000,
        .max_combo = 10,
        .perfect = true,
        .grade = "X",
        .mods = 0,
        .passed = true,
        .mode = 0,
        .client_time = "260811000000",
        .client_flags = "0",
    };
    const pending_score_id = try store.insertStableScore(requester, pending_score, 26.8, "pending replay", 12_000);
    try std.testing.expect((try store.scoreLeaderboardPlacement(pending_score_id)) == null);
    try std.testing.expectEqual(@as(i32, 0), (try store.statsForUser(requester, 0)).?.pp);

    const requested = try store.requestBeatmapRank(requester, &hash);
    try std.testing.expectEqual(@as(u32, 1), requested.requests);
    try std.testing.expectError(error.BeatmapAlreadyRequested, store.requestBeatmapRank(requester, &hash));
    const queue = try store.beatmapRankQueue(std.testing.allocator);
    defer std.testing.allocator.free(queue);
    try std.testing.expect(std.mem.indexOf(u8, queue, "1 request(s) | 0/2 noms") != null);

    const first = try store.nominateBeatmapSet(first_bn, &hash, "clean first review");
    try std.testing.expectEqual(@as(u32, 1), first.nominations);
    try std.testing.expectError(error.BeatmapAlreadyNominated, store.nominateBeatmapSet(first_bn, &hash, "duplicate"));
    const second = try store.nominateBeatmapSet(second_bn, &hash, "clean second review");
    try std.testing.expectEqual(@as(u32, 2), second.nominations);

    const qualified = try store.applyBeatmapRankAction(first_bn, &hash, .qualify, "two clean reviews");
    try std.testing.expectEqual(@as(i8, 5), qualified.status);
    const viewer = (try store.userById(std.testing.allocator, requester)).?;
    defer {
        std.testing.allocator.free(viewer.name);
        std.testing.allocator.free(viewer.safe_name);
    }
    const qualified_board = try store.stableLeaderboard(std.testing.allocator, viewer, &hash, 0, 0, 0);
    defer std.testing.allocator.free(qualified_board);
    try std.testing.expect(std.mem.startsWith(u8, qualified_board, "4|false|"));

    const ranked = try store.applyBeatmapRankAction(second_bn, &hash, .rank, "ranking window complete");
    try std.testing.expectEqual(@as(i8, 3), ranked.status);
    try std.testing.expectEqual(@as(u32, 0), ranked.requests);
    try std.testing.expectEqual(@as(u32, 0), ranked.nominations);
    const ranked_stats = (try store.statsForUser(requester, 0)).?;
    try std.testing.expectEqual(@as(i64, 1_000_000), ranked_stats.ranked_score);
    try std.testing.expectEqual(@as(i32, 27), ranked_stats.pp);
    const placed = (try store.scoreLeaderboardPlacement(pending_score_id)).?;
    try std.testing.expect(placed.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 0), placed.rank);
    try std.testing.expect(webhook.shouldAnnounceScore(placed, 26.8));

    const loved = try store.applyBeatmapRankAction(first_bn, &hash, .love, "this set belongs in loved");
    try std.testing.expectEqual(@as(i8, 6), loved.status);
    const approved = try store.applyBeatmapRankAction(second_bn, &hash, .approve, "move the loved set to approved");
    try std.testing.expectEqual(@as(i8, 4), approved.status);
    const direct_pending = try store.applyBeatmapRankAction(first_bn, &hash, .pending, "send approved back to pending");
    try std.testing.expectEqual(@as(i8, 2), direct_pending.status);
    const direct_ranked = try store.applyBeatmapRankAction(second_bn, &hash, .rank, "rank directly from pending");
    try std.testing.expectEqual(@as(i8, 3), direct_ranked.status);
    var worse_score = pending_score;
    worse_score.online_checksum = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    worse_score.total_score = 900_000;
    const worse_score_id = try store.insertStableScore(requester, worse_score, 20.0, "worse replay", 12_000);
    const worse_placement = (try store.scoreLeaderboardPlacement(worse_score_id)).?;
    try std.testing.expect(!worse_placement.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 0), worse_placement.rank);
    try std.testing.expect(!webhook.shouldAnnounceScore(worse_placement, 999.0));
    try std.testing.expect(!webhook.shouldAnnounceScore(.{ .rank = 50, .submitted_is_best = true }, 999.0));
    var failed_score = pending_score;
    failed_score.online_checksum = "ffffffffffffffffffffffffffffffff";
    failed_score.total_score = 100_000;
    failed_score.passed = false;
    failed_score.perfect = false;
    failed_score.grade = "F";
    _ = try store.insertStableScore(requester, failed_score, 0, "", 8_000);
    try std.testing.expectEqual(pending_score_id, try store.setScorePinned(requester, &hash, 0, 0, "vanilla", true));
    const site_rankings = try store.siteRankings(std.testing.allocator, .all, 0, 0);
    defer std.testing.allocator.free(site_rankings);
    try std.testing.expect(std.mem.indexOf(u8, site_rankings, "\"rank\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_rankings, "\"source\":\"all\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_rankings, "\"name\":\"requester\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_rankings, "\"pp\":27") != null);
    var history_update_buf: [128]u8 = undefined;
    const history_update = try std.fmt.bufPrintZ(&history_update_buf, "UPDATE scores SET submitted_at=unixepoch()-172800 WHERE id={d}", .{pending_score_id});
    try store.exec(history_update);
    const observed_history = try store.statsHistory(requester, .all, 0);
    try std.testing.expectEqual(@as(u8, 1), observed_history.len);
    try std.testing.expectEqual(@as(i32, 27), observed_history.points[0].pp);
    try std.testing.expectEqual(@as(i32, 1), observed_history.points[0].global_rank);
    try std.testing.expectEqual(observed_history, try store.statsHistory(requester, .all, 0));
    const empty_lazer_history = try store.statsHistory(requester, .lazer, 0);
    try std.testing.expectEqual(@as(u8, 0), empty_lazer_history.len);
    const full_modes = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 8 };
    const scorev2_modes = [_]u8{ 0, 1, 2, 3 };
    for ([_]domain.SiteScoreSource{ .all, .stable, .lazer, .scorev2 }) |history_source| {
        const history_modes: []const u8 = if (history_source == .scorev2) &scorev2_modes else &full_modes;
        for (history_modes) |history_mode| {
            const matrix_history = try store.statsHistory(requester, history_source, history_mode);
            const expected_len: u8 = if ((history_source == .all or history_source == .stable) and history_mode == 0) 1 else 0;
            try std.testing.expectEqual(expected_len, matrix_history.len);
        }
    }
    try store.exec("UPDATE scores SET pp=999 WHERE id=(SELECT min(id) FROM scores)");
    try std.testing.expectEqual(observed_history, try store.statsHistory(requester, .all, 0));
    try std.testing.expectEqual(@as(i32, 27), (try store.statsHistory(requester, .stable, 0)).points[0].pp);
    try store.exec("UPDATE scores SET pp=27 WHERE id=(SELECT min(id) FROM scores)");
    var retained_buf: [512]u8 = undefined;
    const retained_sql = try std.fmt.bufPrintZ(&retained_buf, "INSERT INTO user_stats_history(user_id,source,mode,day,pp,global_rank) VALUES({d},'all',0,((unixepoch()/86400)-90)*86400,1,9),({d},'all',0,((unixepoch()/86400)-89)*86400,2,8)", .{ requester, requester });
    try store.exec(retained_sql);
    var history_score = pending_score;
    history_score.online_checksum = "44444444444444444444444444444444";
    history_score.total_score = 700_000;
    _ = try store.insertStableScore(requester, history_score, 10, "history replay", 12_000);
    const retained_history = try store.statsHistory(requester, .all, 0);
    try std.testing.expectEqual(@as(u8, 2), retained_history.len);
    try std.testing.expectEqual(@as(i32, 2), retained_history.points[0].pp);
    try std.testing.expectEqual(@as(i32, 27), retained_history.points[1].pp);
    var pruned: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "SELECT count(*) FROM user_stats_history WHERE day<((unixepoch()/86400)-89)*86400", -1, &pruned, null));
    defer _ = storage.c.sqlite3_finalize(pruned);
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(pruned));
    try std.testing.expectEqual(@as(c_int, 0), storage.c.sqlite3_column_int(pruned, 0));
    const site_profile = (try store.siteProfile(std.testing.allocator, requester, .all, 0)).?;
    defer std.testing.allocator.free(site_profile);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"country\":\"XX\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"global_rank\":1") != null);
    {
        var parsed_profile = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, site_profile, .{});
        defer parsed_profile.deinit();
        const selected = parsed_profile.value.object.get("selected_stats").?.object;
        const ranks = selected.get("rank_history").?.array.items;
        const pp_values = selected.get("pp_history").?.array.items;
        const days = selected.get("history_days").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), ranks.len);
        try std.testing.expectEqual(ranks.len, pp_values.len);
        try std.testing.expectEqual(ranks.len, days.len);
        try std.testing.expectEqual(@as(i64, 1), ranks[ranks.len - 1].integer);
        try std.testing.expectEqual(@as(i64, 27), pp_values[pp_values.len - 1].integer);
    }
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "Zigcho Fixture") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"selected_mode\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"selected_source\":\"all\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"namespace\":\"vanilla\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"client\":\"stable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"passed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"pinned_scores\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"top_scores\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"recent_scores\":[{") != null);
    inline for (.{ .{ 4, 404 }, .{ 5, 505 }, .{ 6, 606 }, .{ 8, 808 } }) |fixture| {
        var relaxed_stats_buf: [192]u8 = undefined;
        const relaxed_stats = try std.fmt.bufPrintZ(&relaxed_stats_buf, "UPDATE stats SET pp={d},plays=2,total_score={d} WHERE user_id={d} AND mode={d}", .{ fixture[1], fixture[1] * 1000, requester, fixture[0] });
        try store.exec(relaxed_stats);
        const namespace_profile = (try store.siteProfile(std.testing.allocator, requester, .all, fixture[0])).?;
        defer std.testing.allocator.free(namespace_profile);
        var pp_needle_buf: [48]u8 = undefined;
        const pp_needle = try std.fmt.bufPrint(&pp_needle_buf, "\"pp\":{d}", .{fixture[1]});
        try std.testing.expect(std.mem.indexOf(u8, namespace_profile, pp_needle) != null);
    }
    const recent_activity = try store.lazerRecentActivityJson(std.testing.allocator, requester, 0, 50);
    defer std.testing.allocator.free(recent_activity);
    var parsed_activity = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, recent_activity, .{});
    defer parsed_activity.deinit();
    try std.testing.expect(parsed_activity.value.array.items.len >= 2);
    const activity = parsed_activity.value.array.items[0].object;
    try std.testing.expectEqualStrings("rank", activity.get("type").?.string);
    try std.testing.expectEqualStrings("osu", activity.get("mode").?.string);
    try std.testing.expectEqualStrings("requester", activity.get("user").?.object.get("username").?.string);
    try std.testing.expect(std.mem.startsWith(u8, activity.get("beatmap").?.object.get("url").?.string, "/b/"));
    const empty_autopilot_profile = (try store.siteProfile(std.testing.allocator, requester, .all, 8)).?;
    defer std.testing.allocator.free(empty_autopilot_profile);
    try std.testing.expect(std.mem.indexOf(u8, empty_autopilot_profile, "\"selected_mode\":8") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_autopilot_profile, "\"pinned_scores\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_autopilot_profile, "\"top_scores\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_autopilot_profile, "\"recent_scores\":[]") != null);
    try std.testing.expect((try store.siteProfile(std.testing.allocator, 999_999, .all, 0)) == null);
    const ranked_board = try store.stableLeaderboard(std.testing.allocator, viewer, &hash, 0, 0, 0);
    defer std.testing.allocator.free(ranked_board);
    try std.testing.expect(std.mem.startsWith(u8, ranked_board, "2|false|"));
    try store.upsertBeatmap(metadata, &hash, 2, 1.7931, 10, map);
    try std.testing.expectEqual(@as(i8, 3), (try store.beatmapRankContext(&hash)).?.status);

    const rolled_back = try store.applyBeatmapRankAction(first_bn, &hash, .rollback, "bad ranking metadata");
    try std.testing.expectEqual(@as(i8, 2), rolled_back.status);
    try std.testing.expectEqual(@as(i32, 0), (try store.statsForUser(requester, 0)).?.pp);
    const vetoed = try store.applyBeatmapRankAction(first_bn, &hash, .veto, "send it back through review");
    try std.testing.expectEqual(@as(i8, 2), vetoed.status);
    const pending_board = try store.stableLeaderboard(std.testing.allocator, viewer, &hash, 0, 0, 0);
    defer std.testing.allocator.free(pending_board);
    try std.testing.expectEqualStrings("0|false", pending_board);
    const vetoed_site_board = (try store.siteBeatmapLeaderboard(std.testing.allocator, metadata.id, .all, 0)).?;
    defer std.testing.allocator.free(vetoed_site_board);
    try std.testing.expect(std.mem.indexOf(u8, vetoed_site_board, "\"scores\":[]") != null);
    const vetoed_lazer_board = try store.lazerLeaderboardJson(std.testing.allocator, requester, metadata.id, 0, .vanilla, "[]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(vetoed_lazer_board);
    try std.testing.expect(std.mem.indexOf(u8, vetoed_lazer_board, "\"score_count\":0") != null);

    const reopened = try store.applyBeatmapRankAction(second_bn, &hash, .rank, "review finished after veto");
    try std.testing.expectEqual(@as(i8, 3), reopened.status);
    const reopened_site_board = (try store.siteBeatmapLeaderboard(std.testing.allocator, metadata.id, .all, 0)).?;
    defer std.testing.allocator.free(reopened_site_board);
    try std.testing.expect(std.mem.indexOf(u8, reopened_site_board, "\"scores\":[]") == null);
}

test "score submissions refresh both sides of a daily rank swap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/history-rank-swap.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const first_id = try store.register("history first", "history-first@example.invalid", "00000000000000000000000000000000");
    const second_id = try store.register("history second", "history-second@example.invalid", "11111111111111111111111111111111");
    const map_md5 = "99999999999999999999999999999991";
    try store.exec("INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,max_combo) VALUES(990000001,990000001,'99999999999999999999999999999991','history','rank swap','test','zigcho',3,10)");

    const base: stable_score.Submission = .{
        .map_md5 = map_md5,
        .username = "history first",
        .online_checksum = "99999999999999999999999999999992",
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .ngeki = 0,
        .nkatu = 0,
        .nmiss = 0,
        .total_score = 1_000_000,
        .max_combo = 10,
        .perfect = true,
        .grade = "X",
        .mods = 0,
        .passed = true,
        .mode = 0,
        .client_time = "260825000000",
        .client_flags = "0",
    };
    _ = try store.insertStableScore(first_id, base, 40, "first replay", 12_000);
    var second_low = base;
    second_low.username = "history second";
    second_low.online_checksum = "99999999999999999999999999999993";
    second_low.total_score = 900_000;
    _ = try store.insertStableScore(second_id, second_low, 20, "second low replay", 12_000);
    try std.testing.expectEqual(@as(i32, 1), (try store.statsHistory(first_id, .all, 0)).points[0].global_rank);
    try std.testing.expectEqual(@as(i32, 2), (try store.statsHistory(second_id, .all, 0)).points[0].global_rank);

    var second_high = second_low;
    second_high.online_checksum = "99999999999999999999999999999994";
    second_high.total_score = 1_100_000;
    _ = try store.insertStableScore(second_id, second_high, 80, "second high replay", 12_000);
    const first_history = try store.statsHistory(first_id, .all, 0);
    const second_history = try store.statsHistory(second_id, .all, 0);
    try std.testing.expectEqual(@as(u8, 1), first_history.len);
    try std.testing.expectEqual(@as(u8, 1), second_history.len);
    try std.testing.expectEqual(@as(i32, 2), first_history.points[0].global_rank);
    try std.testing.expectEqual(@as(i32, 1), second_history.points[0].global_rank);

    var ranks: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "SELECT count(*),count(DISTINCT global_rank) FROM user_stats_history WHERE source='all' AND mode=0 AND day=(unixepoch()/86400)*86400 AND user_id IN(?1,?2)", -1, &ranks, null));
    defer _ = storage.c.sqlite3_finalize(ranks);
    _ = storage.c.sqlite3_bind_int(ranks, 1, first_id);
    _ = storage.c.sqlite3_bind_int(ranks, 2, second_id);
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(ranks));
    try std.testing.expectEqual(@as(c_int, 2), storage.c.sqlite3_column_int(ranks, 0));
    try std.testing.expectEqual(@as(c_int, 2), storage.c.sqlite3_column_int(ranks, 1));
}

test "profile pins replace the selected map and keep three per stable score slice" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/profile-pins.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("pin player", "pin-player@example.invalid", "00000000000000000000000000000000");
    const map = @embedFile("testdata/synthetic-standard.osu");
    const base_metadata = try beatmap.parse(map);
    const hashes = [_][]const u8{
        "11111111111111111111111111111111",
        "22222222222222222222222222222222",
        "33333333333333333333333333333333",
        "44444444444444444444444444444444",
    };
    const checksums = [_][]const u8{
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "cccccccccccccccccccccccccccccccc",
        "dddddddddddddddddddddddddddddddd",
    };
    var score_ids: [4]i64 = undefined;
    for (hashes, checksums, 0..) |hash, checksum, index| {
        var metadata = base_metadata;
        metadata.id = 910_000_001 + @as(i32, @intCast(index));
        metadata.set_id = 910_000_000 + @as(i32, @intCast(index));
        try store.upsertBeatmap(metadata, hash, 3, 1.8, 10, map);
        const score: stable_score.Submission = .{
            .map_md5 = hash,
            .username = "pin player",
            .online_checksum = checksum,
            .n300 = 10,
            .n100 = 0,
            .n50 = 0,
            .ngeki = 0,
            .nkatu = 0,
            .nmiss = 0,
            .total_score = 1_000_000 + @as(i64, @intCast(index)),
            .max_combo = 10,
            .perfect = true,
            .grade = "X",
            .mods = 0,
            .passed = true,
            .mode = 0,
            .client_time = "260812000000",
            .client_flags = "0",
        };
        score_ids[index] = try store.insertStableScore(user_id, score, 10.0 + @as(f64, @floatFromInt(index)), "replay", 1_000);
    }

    for (hashes[0..3], score_ids[0..3]) |hash, score_id|
        try std.testing.expectEqual(score_id, try store.setScorePinned(user_id, hash, 0, 0, "vanilla", true));
    try std.testing.expectError(error.TooManyPinnedScores, store.setScorePinned(user_id, hashes[3], 0, 0, "vanilla", true));

    const replacement: stable_score.Submission = .{
        .map_md5 = hashes[0],
        .username = "pin player",
        .online_checksum = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .ngeki = 0,
        .nkatu = 0,
        .nmiss = 0,
        .total_score = 2_000_000,
        .max_combo = 10,
        .perfect = true,
        .grade = "X",
        .mods = 0,
        .passed = true,
        .mode = 0,
        .client_time = "260812000001",
        .client_flags = "0",
    };
    const replacement_id = try store.insertStableScore(user_id, replacement, 99.0, "better replay", 1_000);
    try std.testing.expectEqual(replacement_id, try store.setScorePinned(user_id, hashes[0], 0, 0, "vanilla", true));
    try std.testing.expectEqual(score_ids[1], try store.setScorePinned(user_id, hashes[1], 0, 0, "vanilla", false));
    try std.testing.expectEqual(score_ids[3], try store.setScorePinned(user_id, hashes[3], 0, 0, "vanilla", true));

    const profile = (try store.siteProfile(std.testing.allocator, user_id, .all, 0)).?;
    defer std.testing.allocator.free(profile);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, profile, .{});
    defer parsed.deinit();
    const pinned = parsed.value.object.get("pinned_scores").?.array.items;
    const top = parsed.value.object.get("top_scores").?.array.items;
    const recent = parsed.value.object.get("recent_scores").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), pinned.len);
    try std.testing.expectEqual(@as(usize, 4), top.len);
    try std.testing.expectEqual(@as(usize, 5), recent.len);
    try std.testing.expectEqual(replacement_id, top[0].object.get("id").?.integer);
    try std.testing.expectEqual(replacement_id, recent[0].object.get("id").?.integer);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), top[0].object.get("weight").?.object.get("percentage").?.float, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), top[0].object.get("weight").?.object.get("pp").?.float, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 95.0), top[1].object.get("weight").?.object.get("percentage").?.float, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 90.25), top[2].object.get("weight").?.object.get("percentage").?.float, 0.001);
    try std.testing.expect(pinned[0].object.get("weight") == null);
    try std.testing.expect(recent[0].object.get("weight") == null);
    for (pinned) |item| try std.testing.expect(item.object.get("id").?.integer != score_ids[0]);
}

test "profile pins select and retain exact mod scores on the same map" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/profile-exact-mod-pins.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("mod pin player", "mod-pin-player@example.invalid", "00000000000000000000000000000000");
    const map = @embedFile("testdata/synthetic-standard.osu");
    const metadata = try beatmap.parse(map);
    const hash = beatmap.md5(map);
    try store.upsertBeatmap(metadata, &hash, 3, 1.8, 10, map);

    var hidden_score: stable_score.Submission = .{
        .map_md5 = &hash,
        .username = "mod pin player",
        .online_checksum = "abababababababababababababababab",
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .ngeki = 0,
        .nkatu = 0,
        .nmiss = 0,
        .total_score = 1_000_000,
        .max_combo = 10,
        .perfect = true,
        .grade = "X",
        .mods = 1 << 3,
        .passed = true,
        .mode = 0,
        .client_time = "260812000010",
        .client_flags = "0",
    };
    const hidden_id = try store.insertStableScore(user_id, hidden_score, 20.0, "hidden replay", 1_000);
    hidden_score.online_checksum = "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd";
    hidden_score.total_score = 900_000;
    hidden_score.mods = 1 << 4;
    const hard_rock_id = try store.insertStableScore(user_id, hidden_score, 18.0, "hard rock replay", 1_000);

    try std.testing.expectEqual(hidden_id, try store.setScorePinned(user_id, &hash, 0, 1 << 3, "vanilla", true));
    try std.testing.expectEqual(hard_rock_id, try store.setScorePinned(user_id, &hash, 0, 1 << 4, "vanilla", true));
    try std.testing.expectError(error.NoPassedScore, store.setScorePinned(user_id, &hash, 0, 1 << 6, "vanilla", true));

    const profile = (try store.siteProfile(std.testing.allocator, user_id, .all, 0)).?;
    defer std.testing.allocator.free(profile);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, profile, .{});
    defer parsed.deinit();
    const pinned = parsed.value.object.get("pinned_scores").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), pinned.len);
    var saw_hidden = false;
    var saw_hard_rock = false;
    for (pinned) |item| {
        const id = item.object.get("id").?.integer;
        if (id == hidden_id) saw_hidden = true;
        if (id == hard_rock_id) saw_hard_rock = true;
    }
    try std.testing.expect(saw_hidden and saw_hard_rock);

    try std.testing.expectEqual(hidden_id, try store.setScorePinned(user_id, &hash, 0, 1 << 3, "vanilla", false));
    const after_unpin = (try store.siteProfile(std.testing.allocator, user_id, .all, 0)).?;
    defer std.testing.allocator.free(after_unpin);
    const after = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, after_unpin, .{});
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 1), after.value.object.get("pinned_scores").?.array.items.len);
    try std.testing.expectEqual(hard_rock_id, after.value.object.get("pinned_scores").?.array.items[0].object.get("id").?.integer);
}

test "staff web data keeps appeals and moderation actions auditable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/staff-web.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const player = try store.register("player", "player-staff@example.invalid", "00000000000000000000000000000000");
    const moderator = try store.register("moderator", "moderator-staff@example.invalid", "11111111111111111111111111111111");
    try store.exec("UPDATE users SET restricted=1 WHERE id=4; UPDATE users SET privileges=4099 WHERE id=5;");
    const appeal_id = try store.createModerationAppeal(player, "hwid", "this exact hardware match belongs to a shared pc, please review it");
    try std.testing.expectError(error.AppealAlreadyOpen, store.createModerationAppeal(player, "hwid", "a duplicate appeal that must not create another queue row"));
    try std.testing.expect(try store.addLazerReport(player, "user", moderator, "spam", "sent from the lazer report sheet"));
    try std.testing.expect(!try store.addLazerReport(player, "user", moderator, "spam", "duplicate"));

    const overview = try store.staffOverviewJson(std.testing.allocator);
    defer std.testing.allocator.free(overview);
    try std.testing.expect(std.mem.indexOf(u8, overview, "\"open_appeals\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, overview, "\"open_reports\":1") != null);
    const reports = try store.staffLazerReportsJson(std.testing.allocator);
    defer std.testing.allocator.free(reports);
    const parsed_reports = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, reports, .{});
    defer parsed_reports.deinit();
    const report = parsed_reports.value.object.get("reports").?.array.items[0].object;
    const report_id = report.get("id").?.integer;
    try std.testing.expectEqualStrings("moderator", report.get("target").?.string);
    try std.testing.expectEqualStrings("open", report.get("status").?.string);
    try std.testing.expect(try store.resolveLazerReport(moderator, report_id, "resolved"));
    try std.testing.expect(!try store.resolveLazerReport(moderator, report_id, "dismissed"));
    const reviewed_reports = try store.staffLazerReportsJson(std.testing.allocator);
    defer std.testing.allocator.free(reviewed_reports);
    try std.testing.expect(std.mem.indexOf(u8, reviewed_reports, "\"status\":\"resolved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reviewed_reports, "\"resolver\":\"moderator\"") != null);
    const appeals = try store.staffAppealsJson(std.testing.allocator);
    defer std.testing.allocator.free(appeals);
    try std.testing.expect(std.mem.indexOf(u8, appeals, "\"kind\":\"hwid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, appeals, "shared pc") != null);

    try store.resolveModerationAppeal(moderator, appeal_id, "accepted", "exact match reviewed by a person");
    try std.testing.expectError(error.AppealNotOpen, store.resolveModerationAppeal(moderator, appeal_id, "denied", "cannot decide twice"));
    const decided = try store.staffAppealsJson(std.testing.allocator);
    defer std.testing.allocator.free(decided);
    try std.testing.expect(std.mem.indexOf(u8, decided, "\"status\":\"accepted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, decided, "exact match reviewed") != null);

    const player_json = (try store.staffUserJson(std.testing.allocator, player)).?;
    defer std.testing.allocator.free(player_json);
    try std.testing.expect(std.mem.indexOf(u8, player_json, "\"restricted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, player_json, "appeal.accept") != null);
    const audit = try store.staffAuditJson(std.testing.allocator);
    defer std.testing.allocator.free(audit);
    try std.testing.expect(std.mem.indexOf(u8, audit, "\"actor\":\"moderator\"") != null);
    const channels = try store.staffChannelsJson(std.testing.allocator);
    defer std.testing.allocator.free(channels);
    try std.testing.expect(std.mem.indexOf(u8, channels, "\"name\":\"#announce\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, channels, "\"name\":\"#lazer\"") != null);
}

test "developer role workspace changes one named bit and revokes the final staff session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/staff-roles.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const actor_id = try store.register("role developer", "role-developer@example.invalid", "00000000000000000000000000000000");
    const target_id = try store.register("role target", "role-target@example.invalid", "11111111111111111111111111111111");
    try store.exec("UPDATE users SET privileges=16387 WHERE id=4; UPDATE users SET privileges=4115 WHERE id=5;");
    const staff_token = try store.issueToken(target_id, web_auth.scope, 3600);

    const premium = try store.changeRole(actor_id, target_id, .premium, true, "grant permanent premium for mapper access");
    try std.testing.expectEqual(@as(u32, 4147), premium.privileges);
    try std.testing.expect(!premium.staff_sessions_revoked);
    try std.testing.expectError(error.RoleStateUnchanged, store.changeRole(actor_id, target_id, .premium, true, "do not duplicate the same grant"));
    try std.testing.expectError(error.InvalidRoleChange, store.changePrivileges(actor_id, target_id, 3, false));
    try std.testing.expectError(error.InvalidRoleChange, store.changePrivileges(actor_id, target_id, (1 << 4) | (1 << 5), false));

    const live_staff = (try store.authenticateToken(std.testing.allocator, &staff_token, web_auth.scope)).?;
    defer {
        std.testing.allocator.free(live_staff.name);
        std.testing.allocator.free(live_staff.safe_name);
    }
    try std.testing.expect(live_staff.privileges & account_roles.Role.premium.definition().bit != 0);

    const admin = try store.changeRole(actor_id, target_id, .administrator, true, "move this account onto admin access");
    try std.testing.expectEqual(@as(u32, 12_339), admin.privileges);
    const downgraded = try store.changeRole(actor_id, target_id, .moderator, false, "moderation role replaced by admin access");
    try std.testing.expectEqual(@as(u32, 8_243), downgraded.privileges);
    try std.testing.expect(!downgraded.staff_sessions_revoked);
    const refreshed_staff = (try store.authenticateToken(std.testing.allocator, &staff_token, web_auth.scope)).?;
    defer {
        std.testing.allocator.free(refreshed_staff.name);
        std.testing.allocator.free(refreshed_staff.safe_name);
    }
    try std.testing.expect(refreshed_staff.privileges & (1 << 13) != 0);
    try std.testing.expect(refreshed_staff.privileges & (1 << 12) == 0);
    const removed = try store.changeRole(actor_id, target_id, .administrator, false, "admin access has ended");
    try std.testing.expectEqual(@as(u32, 51), removed.privileges);
    try std.testing.expect(removed.staff_sessions_revoked);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &staff_token, web_auth.scope)) == null);
    try std.testing.expect(removed.privileges & 3 == 3);
    try std.testing.expect(removed.privileges & (1 << 4) != 0);
    try std.testing.expect(removed.privileges & (1 << 5) != 0);

    const json = (try store.staffRolesJson(std.testing.allocator, target_id)).?;
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const roles = parsed.value.object.get("roles").?.array.items;
    try std.testing.expectEqual(account_roles.definitions.len, roles.len);
    var saw_premium = false;
    for (roles) |entry| {
        if (!std.mem.eql(u8, entry.object.get("key").?.string, "premium")) continue;
        saw_premium = true;
        try std.testing.expect(entry.object.get("granted").?.bool);
        try std.testing.expect(entry.object.get("permanent").?.bool);
        try std.testing.expectEqual(@as(i64, 32), entry.object.get("bit").?.integer);
    }
    try std.testing.expect(saw_premium);
    try std.testing.expectEqual(@as(usize, 4), parsed.value.object.get("audit").?.array.items.len);
}

test "developer role workspace removes raw privilege masks from the website" {
    try std.testing.expect(std.mem.indexOf(u8, server_website_source, "/api/v1/staff/roles") != null);
    try std.testing.expect(std.mem.indexOf(u8, server_website_source, "account_roles.Role.parse") != null);
    try std.testing.expect(std.mem.indexOf(u8, server_website_source, "staff_sessions_revoked") != null);
    try std.testing.expect(std.mem.indexOf(u8, server_website_source, "add_privilege") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "add privilege bits") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "permanent until a developer explicitly revokes it") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_page, "data-role-key") != null);
}

test "Akatsuki archives only yield the exact MD5 map" {
    const map = @embedFile("testdata/synthetic-standard.osu");
    const archive = try storedZip(std.testing.allocator, "Zigcho [Tests].osu", map);
    defer std.testing.allocator.free(archive);
    const files = try beatmap_sync.extractAllOsu(std.testing.allocator, archive);
    defer beatmap_sync.freeExtractedOsu(std.testing.allocator, files);
    const hash = beatmap.md5(map);
    const extracted = beatmap_sync.findExtractedOsu(files, &hash).?;
    try std.testing.expectEqualStrings(map, extracted.contents);
    try std.testing.expect(beatmap_sync.findExtractedOsu(files, "00000000000000000000000000000000") == null);
}

test "a pulled mapset extracts every current osu difficulty" {
    const first = @embedFile("testdata/synthetic-standard.osu");
    const second =
        "osu file format v14\n" ++
        "[General]\nMode:0\n" ++
        "[Metadata]\nBeatmapID:900000002\nBeatmapSetID:900000000\nArtist:Zigcho\nTitle:Zigcho Fixture\nCreator:Ari\nVersion:Another Test\n" ++
        "[Difficulty]\nHPDrainRate:5\nCircleSize:4\nOverallDifficulty:7\nApproachRate:8\n" ++
        "[TimingPoints]\n0,500,4,2,0,100,1,0\n" ++
        "[HitObjects]\n64,192,1000,1,0,0:0:0:0:\n";
    const entries = [_]StoredZipEntry{
        .{ .filename = "Zigcho [Tests].osu", .contents = first },
        .{ .filename = "Zigcho [Another Test].osu", .contents = second },
        .{ .filename = "audio.mp3", .contents = "not really audio" },
    };
    const archive = try storedZipFiles(std.testing.allocator, &entries);
    defer std.testing.allocator.free(archive);
    const files = try beatmap_sync.extractAllOsu(std.testing.allocator, archive);
    defer beatmap_sync.freeExtractedOsu(std.testing.allocator, files);
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings(first, files[0].contents);
    try std.testing.expectEqualStrings(second, files[1].contents);
    try std.testing.expectEqualSlices(u8, &beatmap.md5(first), &files[0].md5);
    try std.testing.expectEqualSlices(u8, &beatmap.md5(second), &files[1].md5);
}

test "old beatmaps without embedded ids use trusted API ids" {
    const legacy_map =
        "osu file format v7\n" ++
        "[General]\nMode:0\n" ++
        "[Metadata]\nArtist:old artist\nTitle:old title\nCreator:old mapper\nVersion:old diff\n" ++
        "[Difficulty]\nHPDrainRate:5\nCircleSize:4\nOverallDifficulty:7\nApproachRate:8\n" ++
        "[TimingPoints]\n0,500,4,2,0,100,1,0\n" ++
        "[HitObjects]\n64,192,1000,1,0,0:0:0:0:\n";

    try std.testing.expectError(error.InvalidBeatmap, beatmap.parse(legacy_map));
    const parsed = try beatmap.parseWithIds(legacy_map, 123, 456);
    try std.testing.expectEqual(@as(i32, 123), parsed.id);
    try std.testing.expectEqual(@as(i32, 456), parsed.set_id);

    const current = try beatmap.parseWithIds(@embedFile("testdata/synthetic-standard.osu"), 1, 2);
    try std.testing.expectEqual(@as(i32, 900000001), current.id);
    try std.testing.expectEqual(@as(i32, 900000000), current.set_id);
}

test "lazer exported beatmaps accept a utf8 bom across metadata and native pp" {
    const plain = @embedFile("testdata/synthetic-standard.osu");
    const exported = "\xef\xbb\xbf" ++ plain;
    const parsed = try beatmap.parse(exported);
    try std.testing.expectEqual(@as(i32, 900000001), parsed.id);
    const calculated = try native_pp.calculate(exported, .{
        .mode = 0,
        .lazer = 0,
        .mods = 0,
        .max_combo = 1,
        .n_geki = 0,
        .n_katu = 0,
        .n300 = 1,
        .n100 = 0,
        .n50 = 0,
        .misses = 0,
        .legacy_total_score = 1_000_000,
    });
    try std.testing.expect(calculated.stars > 0);
}

test "metadata-only beatmaps stay eligible for hydration retry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/hydration-retry.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();

    const map = @embedFile("testdata/synthetic-standard.osu");
    const metadata = try beatmap.parse(map);
    const hash = beatmap.md5(map);
    try store.upsertBeatmapMeta(metadata, &hash, 3, 1.0, 1);
    try std.testing.expect(!try store.beatmapHasFile(&hash));
    try std.testing.expect(try beatmap_sync.needsHydration(&store, &hash));

    try store.upsertBeatmap(metadata, &hash, 3, 1.0, 1, map);
    try std.testing.expect(try store.beatmapHasFile(&hash));
    try std.testing.expect(!try beatmap_sync.needsHydration(&store, &hash));
}

test "public chat does not echo through the server to its sender" {
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const sender = try sessions.create(.{
        .id = 1,
        .name = try std.testing.allocator.dupe(u8, "ari"),
        .safe_name = try std.testing.allocator.dupe(u8, "ari"),
    }, 0, 0, 0);
    const other = try sessions.create(.{
        .id = 2,
        .name = try std.testing.allocator.dupe(u8, "other"),
        .safe_name = try std.testing.allocator.dupe(u8, "other"),
    }, 0, 0, 0);
    try sessions.broadcast("one message", sender);
    try std.testing.expectEqual(@as(usize, 0), sender.queue.items.len);
    try std.testing.expectEqualStrings("one message", other.queue.items);
}

test "poll by token survives session replacement and rejects the stale token" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/session-replace.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("ari", "session-replace@example.test", "00000000000000000000000000000000");

    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const first = try sessions.create(.{
        .id = user_id,
        .name = try std.testing.allocator.dupe(u8, "ari"),
        .safe_name = try std.testing.allocator.dupe(u8, "ari"),
    }, 0, 0, 0);
    const stale_token = first.token;
    const first_poll = (try bancho.pollByToken(std.testing.allocator, &store, &sessions, &stale_token, "")).?;
    defer std.testing.allocator.free(first_poll);

    sessions.mutex.lockUncancelable(sessions.io);
    const replacement = sessions.create(.{
        .id = user_id,
        .name = try std.testing.allocator.dupe(u8, "ari"),
        .safe_name = try std.testing.allocator.dupe(u8, "ari"),
    }, 0, 0, 0) catch |err| {
        sessions.mutex.unlock(sessions.io);
        return err;
    };
    const replacement_token = replacement.token;
    sessions.mutex.unlock(sessions.io);

    try std.testing.expect((try bancho.pollByToken(std.testing.allocator, &store, &sessions, &stale_token, "")) == null);
    try std.testing.expect((try bancho.pollByToken(std.testing.allocator, &store, &sessions, &stale_token, "\x00")) == null);
    const replacement_poll = (try bancho.pollByToken(std.testing.allocator, &store, &sessions, &replacement_token, "")).?;
    defer std.testing.allocator.free(replacement_poll);
    try std.testing.expectEqual(@as(usize, 0), replacement_poll.len);
}

test "stable score token authorization only nominates a bound unknown token for persisted grace" {
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const binding = try sessions_mod.StableClientBinding.init("b20260811", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1.2.3.:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccc:dddddddddddddddddddddddddddddddd:");
    const ari = try sessions.createBound(.{ .id = 1, .name = try std.testing.allocator.dupe(u8, "ari"), .safe_name = try std.testing.allocator.dupe(u8, "ari") }, 0, 0, 0, binding);
    const raya = try sessions.createBound(.{ .id = 2, .name = try std.testing.allocator.dupe(u8, "raya"), .safe_name = try std.testing.allocator.dupe(u8, "raya") }, 0, 0, 0, binding);
    const ari_token = ari.token;
    const raya_token = raya.token;

    try std.testing.expectEqual(sessions_mod.ScoreTokenAuthorization.exact, sessions.authorizeScoreToken(&ari_token, 1, binding));
    try std.testing.expectEqual(sessions_mod.ScoreTokenAuthorization.foreign_live, sessions.authorizeScoreToken(&raya_token, 1, binding));
    try std.testing.expectEqual(sessions_mod.ScoreTokenAuthorization.grace_candidate, sessions.authorizeScoreToken("stale-after-restart", 1, binding));
    try std.testing.expectEqual(sessions_mod.ScoreTokenAuthorization.offline, sessions.authorizeScoreToken("stale-after-restart", 99, binding));
    try std.testing.expectEqual(sessions_mod.ScoreTokenAuthorization.missing, sessions.authorizeScoreToken(null, 1, null));
    ari.presence_suppressed = true;
    try std.testing.expectEqual(sessions_mod.ScoreTokenAuthorization.offline, sessions.authorizeScoreToken(&ari_token, 1, binding));
    try std.testing.expectEqual(sessions_mod.ScoreTokenAuthorization.offline, sessions.authorizeScoreToken("stale-after-restart", 1, binding));
}

test "cross-client takeover emits one logout and the old Stable token only drains its kick" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/session-takeover.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(2,'raya','raya',x'00',x'00'); INSERT INTO stats(user_id,mode) VALUES(2,0)");
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const target = try sessions.create(.{ .id = 1, .name = try std.testing.allocator.dupe(u8, "ari"), .safe_name = try std.testing.allocator.dupe(u8, "ari") }, 0, 0, 0);
    const observer = try sessions.create((try store.userById(std.testing.allocator, 2)).?, 0, 0, 0);
    const hosted_spectator = try sessions.create(.{ .id = 4, .name = try std.testing.allocator.dupe(u8, "spectator"), .safe_name = try std.testing.allocator.dupe(u8, "spectator") }, 0, 0, 0);
    const target_token = target.token;
    const observer_token = observer.token;
    try target.enqueueDirectMessage(std.testing.allocator, 99, "old mail");
    target.in_lobby = true;
    target.joined_lobby_channel = true;
    target.spectating_user_id = observer.user.id;
    hosted_spectator.spectating_user_id = target.user.id;
    sessions.matches[0] = try multiplayer.Match.init(std.testing.allocator, 0, multiplayerFixtureData(target.user.id, "takeover"), target.user.id);
    const match = sessions.matchById(0).?;
    match.slots[1].user_id = observer.user.id;
    match.slots[1].status = @intFromEnum(multiplayer.SlotStatus.not_ready);
    target.match_id = 0;
    observer.match_id = 0;

    var no_memory: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&no_memory);
    try std.testing.expectError(error.OutOfMemory, bancho.suppressForTakeover(failing.allocator(), &sessions, 1, "signed in from lazer"));
    try std.testing.expect(!target.presence_suppressed);
    try std.testing.expect(target.in_lobby and target.joined_lobby_channel);
    try std.testing.expectEqual(@as(?u16, 0), target.match_id);
    try std.testing.expectEqual(@as(?i32, observer.user.id), target.spectating_user_id);
    try std.testing.expectEqual(@as(?i32, target.user.id), hosted_spectator.spectating_user_id);
    try std.testing.expectEqual(@as(usize, 1), target.pending_dm_reads.items.len);

    try std.testing.expect(try bancho.suppressForTakeover(std.testing.allocator, &sessions, 1, "signed in from lazer"));
    try std.testing.expect(target.presence_suppressed);
    try std.testing.expectEqual(@as(usize, 0), target.pending_dm_reads.items.len);
    try std.testing.expectEqual(sessions_mod.ScoreTokenAuthorization.offline, sessions.authorizeScoreToken(&target_token, 1, null));
    try std.testing.expect(!target.in_lobby and !target.joined_lobby_channel);
    try std.testing.expect(target.match_id == null);
    try std.testing.expect(target.spectating_user_id == null);
    try std.testing.expect(hosted_spectator.spectating_user_id == null);
    try std.testing.expectEqual(observer.user.id, match.host_id);
    try std.testing.expectEqual(@as(usize, 1), match.occupied());

    const immediate = (try bancho.pollByToken(std.testing.allocator, &store, &sessions, &observer_token, "")).?;
    defer std.testing.allocator.free(immediate);
    var immediate_reader: protocol.Reader = .{ .data = immediate };
    var immediate_logouts: usize = 0;
    while (try immediate_reader.next()) |packet| if (@intFromEnum(packet.id) == @intFromEnum(protocol.ServerPacket.user_logout)) {
        immediate_logouts += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), immediate_logouts);

    const ignored = try clientMessagePacket(std.testing.allocator, .send_public_message, "ari", "must not send", "#osu", 1);
    defer std.testing.allocator.free(ignored);
    const kicked = (try bancho.pollByToken(std.testing.allocator, &store, &sessions, &target_token, ignored)).?;
    defer std.testing.allocator.free(kicked);
    var kick_reader: protocol.Reader = .{ .data = kicked };
    const notification = (try kick_reader.next()).?;
    try std.testing.expectEqual(@intFromEnum(protocol.ServerPacket.notification), @intFromEnum(notification.id));
    var notification_payload: protocol.PayloadReader = .{ .data = notification.payload };
    try std.testing.expectEqualStrings("signed in from lazer", try notification_payload.string());
    const restart = (try kick_reader.next()).?;
    try std.testing.expectEqual(@intFromEnum(protocol.ServerPacket.restart), @intFromEnum(restart.id));
    try std.testing.expect((try kick_reader.next()) == null);
    try std.testing.expect(sessions.byUser(1) == null);
    try std.testing.expect((try bancho.pollByToken(std.testing.allocator, &store, &sessions, &target_token, "")) == null);

    const after_drain = (try bancho.pollByToken(std.testing.allocator, &store, &sessions, &observer_token, "")).?;
    defer std.testing.allocator.free(after_drain);
    var after_reader: protocol.Reader = .{ .data = after_drain };
    while (try after_reader.next()) |packet| try std.testing.expect(@intFromEnum(packet.id) != @intFromEnum(protocol.ServerPacket.user_logout));
}

test "interrupted lazer presence lease emits one Stable logout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/lazer-lease-expiry.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(2,'raya','raya',x'00',x'00'); INSERT INTO stats(user_id,mode) VALUES(2,0)");
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const observer = try sessions.create((try store.userById(std.testing.allocator, 2)).?, 0, 0, 0);
    const observer_token = observer.token;
    const now = std.Io.Clock.real.now(std.testing.io).toSeconds();
    try bancho.publishLazerPresence(std.testing.allocator, &store, &sessions, .{ .id = observer.user.id, .name = observer.user.name, .safe_name = observer.user.safe_name });
    try std.testing.expect(!sessions.lazer_leases.contains(observer.user.id));
    try bancho.noteLazerPresence(&sessions, 77, now - bancho.lazer_presence_lease_seconds);
    try bancho.noteLazerPresence(&sessions, 88, now);

    const first = (try bancho.pollByToken(std.testing.allocator, &store, &sessions, &observer_token, "")).?;
    defer std.testing.allocator.free(first);
    var first_reader: protocol.Reader = .{ .data = first };
    var expired_logouts: usize = 0;
    while (try first_reader.next()) |packet| if (@intFromEnum(packet.id) == @intFromEnum(protocol.ServerPacket.user_logout)) {
        var payload: protocol.PayloadReader = .{ .data = packet.payload };
        if (try payload.int(i32) == 77) expired_logouts += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), expired_logouts);
    try std.testing.expect(!sessions.lazer_leases.contains(77));
    try std.testing.expect(sessions.lazer_leases.contains(88));

    const second = (try bancho.pollByToken(std.testing.allocator, &store, &sessions, &observer_token, "")).?;
    defer std.testing.allocator.free(second);
    var second_reader: protocol.Reader = .{ .data = second };
    while (try second_reader.next()) |packet| try std.testing.expect(@intFromEnum(packet.id) != @intFromEnum(protocol.ServerPacket.user_logout));
}

test "logout removes the session and tells the remaining clients" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/session-logout.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(1,'ari','ari',x'00',x'00'),(2,'raya','raya',x'00',x'00'); INSERT INTO stats(user_id,mode) VALUES(1,0),(2,0)");
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const leaving = try sessions.create((try store.userById(std.testing.allocator, 1)).?, 0, 0, 0);
    const remaining = try sessions.create((try store.userById(std.testing.allocator, 2)).?, 0, 0, 0);
    const leaving_token = leaving.token;
    const remaining_token = remaining.token;
    const logout = try clientEmptyPacket(std.testing.allocator, .logout);
    defer std.testing.allocator.free(logout);

    const ignored_reply = (try bancho.pollByToken(std.testing.allocator, &store, &sessions, &leaving_token, logout)).?;
    defer std.testing.allocator.free(ignored_reply);
    try std.testing.expect(sessions.byUser(1) != null);

    leaving.login_time -= 2;
    const reply = (try bancho.pollByToken(std.testing.allocator, &store, &sessions, &leaving_token, logout)).?;
    defer std.testing.allocator.free(reply);
    try std.testing.expect(sessions.byUser(1) == null);

    const event = (try bancho.pollByToken(std.testing.allocator, &store, &sessions, &remaining_token, "")).?;
    defer std.testing.allocator.free(event);
    var reader: protocol.Reader = .{ .data = event };
    const packet = (try reader.next()).?;
    try std.testing.expectEqual(@as(u16, @intFromEnum(protocol.ServerPacket.user_logout)), @intFromEnum(packet.id));
    var payload: protocol.PayloadReader = .{ .data = packet.payload };
    try std.testing.expectEqual(@as(i32, 1), try payload.int(i32));
    try std.testing.expectEqual(@as(u8, 0), try payload.byte());
}

test "idle sessions expire before token polling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/session-expiry.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const expired = try sessions.create(.{ .id = 1, .name = try std.testing.allocator.dupe(u8, "ari"), .safe_name = try std.testing.allocator.dupe(u8, "ari") }, 0, 0, 0);
    const token = expired.token;
    expired.last_seen -= bancho.session_idle_seconds + 1;

    try std.testing.expect((try bancho.pollByToken(std.testing.allocator, &store, &sessions, &token, "")) == null);
    try std.testing.expect(sessions.byUser(1) == null);
}

test "a stopped client cannot grow its outgoing queue past the cap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/session-queue.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const stopped = try sessions.create(.{ .id = 1, .name = try std.testing.allocator.dupe(u8, "ari"), .safe_name = try std.testing.allocator.dupe(u8, "ari") }, 0, 0, 0);
    const token = stopped.token;
    const full = try std.testing.allocator.alloc(u8, sessions_mod.max_queue_bytes);
    defer std.testing.allocator.free(full);
    @memset(full, 1);
    try stopped.enqueue(std.testing.allocator, full);
    try stopped.enqueue(std.testing.allocator, "x");

    try std.testing.expect(stopped.queue_overflowed);
    try std.testing.expectEqual(@as(usize, 0), stopped.queue.items.len);
    try std.testing.expect((try bancho.pollByToken(std.testing.allocator, &store, &sessions, &token, "")) == null);
    try std.testing.expect(sessions.byUser(1) == null);
}

test "stable mod changes immediately return the selected stats slice to the player" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/mod-stats-update.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES" ++
            "(40,'player','player',x'00',x'00'),(41,'observer','observer',x'00',x'00');" ++
            "INSERT INTO stats(user_id,mode,pp) VALUES" ++
            "(40,0,100),(40,4,400),(40,8,800),(41,0,1);",
    );
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const player = try sessions.create((try store.userById(std.testing.allocator, 40)).?, 0, 0, 0);
    const observer = try sessions.create((try store.userById(std.testing.allocator, 41)).?, 0, 0, 0);

    const relax = try clientActionModsPacket(std.testing.allocator, 0, 1 << 7, 0);
    defer std.testing.allocator.free(relax);
    const relax_self = try bancho.poll(std.testing.allocator, &store, &sessions, player, relax);
    defer std.testing.allocator.free(relax_self);
    try expectStatsPacket(relax_self, 40, 1 << 7, 0, 400);
    const relax_observer = try bancho.poll(std.testing.allocator, &store, &sessions, observer, "");
    defer std.testing.allocator.free(relax_observer);
    try expectStatsPacket(relax_observer, 40, 1 << 7, 0, 400);

    const autopilot = try clientActionModsPacket(std.testing.allocator, 0, 1 << 13, 0);
    defer std.testing.allocator.free(autopilot);
    const autopilot_self = try bancho.poll(std.testing.allocator, &store, &sessions, player, autopilot);
    defer std.testing.allocator.free(autopilot_self);
    try expectStatsPacket(autopilot_self, 40, 1 << 13, 0, 800);
    const autopilot_observer = try bancho.poll(std.testing.allocator, &store, &sessions, observer, "");
    defer std.testing.allocator.free(autopilot_observer);
    try expectStatsPacket(autopilot_observer, 40, 1 << 13, 0, 800);

    const vanilla = try clientActionModsPacket(std.testing.allocator, 0, 0, 0);
    defer std.testing.allocator.free(vanilla);
    const vanilla_self = try bancho.poll(std.testing.allocator, &store, &sessions, player, vanilla);
    defer std.testing.allocator.free(vanilla_self);
    try expectStatsPacket(vanilla_self, 40, 0, 0, 100);
}

test "stable friends and favourites stay directional and always include kai" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/social-storage.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt,restricted) VALUES" ++
            "(40,'sender','sender',x'00',x'00',0),(41,'target','target',x'00',x'00',0),(42,'restricted','restricted',x'00',x'00',1)",
    );

    const initial = try store.friendIds(std.testing.allocator, 40);
    defer std.testing.allocator.free(initial);
    try std.testing.expectEqualSlices(i32, &.{3}, initial);
    try std.testing.expectEqual(domain.RelationshipAddResult.inserted, try store.addFriend(40, 41));
    try std.testing.expectEqual(domain.RelationshipAddResult.existing, try store.addFriend(40, 41));
    try std.testing.expectEqual(domain.RelationshipAddResult.ineligible, try store.addFriend(40, 40));
    try std.testing.expectEqual(domain.RelationshipAddResult.ineligible, try store.addFriend(40, 3));
    try std.testing.expectEqual(domain.RelationshipAddResult.ineligible, try store.addFriend(40, 42));
    try std.testing.expectEqual(domain.RelationshipAddResult.ineligible, try store.addFriend(40, 999_999));
    try std.testing.expect(!try store.friendsAreMutual(40, 41));
    try std.testing.expectEqual(domain.RelationshipAddResult.inserted, try store.addFriend(41, 40));
    try std.testing.expect(try store.friendsAreMutual(40, 41));
    try std.testing.expect(try store.removeFriend(41, 40));
    const sender_friends = try store.friendIds(std.testing.allocator, 40);
    defer std.testing.allocator.free(sender_friends);
    try std.testing.expect(std.mem.indexOfScalar(i32, sender_friends, 41) != null);
    try std.testing.expect(std.mem.indexOfScalar(i32, sender_friends, 3) != null);
    const target_friends = try store.friendIds(std.testing.allocator, 41);
    defer std.testing.allocator.free(target_friends);
    try std.testing.expectEqualSlices(i32, &.{3}, target_friends);
    try store.exec("UPDATE users SET restricted=1 WHERE id=41");
    const hidden_friends = try store.friendIds(std.testing.allocator, 40);
    defer std.testing.allocator.free(hidden_friends);
    try std.testing.expectEqualSlices(i32, &.{3}, hidden_friends);
    try std.testing.expect(!try store.friendsAreMutual(40, 41));
    try std.testing.expectEqual(domain.RelationshipAddResult.ineligible, try store.addFriend(40, 41));
    try store.exec("UPDATE users SET restricted=0 WHERE id=41; UPDATE users SET restricted=1 WHERE id=40");
    try std.testing.expectEqual(domain.RelationshipAddResult.ineligible, try store.addFriend(40, 41));
    try store.exec("UPDATE users SET restricted=0 WHERE id=40");
    try std.testing.expect(try store.removeFriend(40, 41));
    try std.testing.expect(!try store.removeFriend(40, 41));
    try std.testing.expect(!try store.removeFriend(40, 3));

    try std.testing.expect(try store.addBlock(40, 41));
    try std.testing.expect(!try store.addBlock(40, 41));
    try std.testing.expect(!try store.addBlock(40, 40));
    try std.testing.expect(!try store.addBlock(40, 3));
    const blocks = try store.blockIds(std.testing.allocator, 40);
    defer std.testing.allocator.free(blocks);
    try std.testing.expectEqualSlices(i32, &.{41}, blocks);
    try std.testing.expect(try store.removeBlock(40, 41));
    try std.testing.expect(!try store.removeBlock(40, 41));

    try std.testing.expect(try store.addFavourite(40, 900000000));
    try std.testing.expect(!try store.addFavourite(40, 900000000));
    try std.testing.expect(try store.addFavourite(40, 900000001));
    try std.testing.expectError(error.InvalidBeatmapSet, store.addFavourite(40, 0));
    const favourites = try store.favouriteSetIds(std.testing.allocator, 40);
    defer std.testing.allocator.free(favourites);
    try std.testing.expectEqualSlices(i32, &.{ 900000000, 900000001 }, favourites);
    try std.testing.expect(try store.removeFavourite(40, 900000000));
    try std.testing.expect(!try store.removeFavourite(40, 900000000));
    try std.testing.expectError(error.InvalidBeatmapSet, store.removeFavourite(40, 0));
}

test "lazer follow route reloads the target after the relationship mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/follow-route.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt,restricted) VALUES" ++
            "(40,'follower','follower',x'00',x'00',0),(41,'target','target',x'00',x'00',0),(42,'restricted','restricted',x'00',x'00',1)",
    );

    const target = switch (try player_routes.follow(std.testing.allocator, &store, 40, 41)) {
        .target => |fresh| fresh,
        else => return error.ExpectedFollowTarget,
    };
    defer {
        std.testing.allocator.free(target.name);
        std.testing.allocator.free(target.safe_name);
    }
    try std.testing.expectEqual(@as(i32, 1), target.follower_count);

    var compact: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer compact.deinit();
    try user_json.writeCompact(&compact.writer, target, target.show_country);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, compact.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("follower_count").?.integer);

    try std.testing.expectEqual(player_routes.FollowResult.ineligible, try player_routes.follow(std.testing.allocator, &store, 40, 42));
    try std.testing.expectEqual(player_routes.FollowResult.not_found, try player_routes.follow(std.testing.allocator, &store, 40, 999_999));
}

test "Stable replay HTTP session contract hides restricted owners and kai before counting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/stable-replay-route.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt,restricted) VALUES" ++
            "(40,'owner','owner',x'00',x'00',0),(41,'restricted','restricted',x'00',x'00',1),(42,'viewer','viewer',x'00',x'00',0);" ++
            "INSERT INTO scores(id,user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,rank_namespace,best) VALUES" ++
            "(700,40,'00000000000000000000000000000001',0,0,700000,100,0.98,300,300,10,1,0,0,0,0,1,x'7075626c69632d7265706c6179','vanilla',1)," ++
            "(701,41,'00000000000000000000000000000002',0,0,700001,100,0.98,300,300,10,1,0,0,0,0,1,x'726573747269637465642d7265706c6179','vanilla',1)," ++
            "(702,3,'00000000000000000000000000000003',0,0,700002,100,0.98,300,300,10,1,0,0,0,0,1,x'6b61692d7265706c6179','vanilla',1)",
    );

    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const viewer = try sessions.create((try store.userById(std.testing.allocator, 42)).?, 0, 0, 0);

    const public_replay = (try player_routes.stableReplay(std.testing.allocator, &store, viewer.user.id, 700)).?;
    defer std.testing.allocator.free(public_replay);
    try std.testing.expectEqualStrings("public-replay", public_replay);
    try std.testing.expectEqual(@as(i32, 1), try store.replayViewCount(40, .all, 0));

    try std.testing.expect((try player_routes.stableReplay(std.testing.allocator, &store, viewer.user.id, 701)) == null);
    try std.testing.expectEqual(@as(i32, 0), try store.replayViewCount(41, .all, 0));
    try std.testing.expect((try player_routes.stableReplay(std.testing.allocator, &store, viewer.user.id, 702)) == null);
    try std.testing.expectEqual(@as(i32, 0), try store.replayViewCount(3, .all, 0));
}

test "stable and lazer share followers and unique replay views" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/shared-social-replay.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES" ++
            "(40,'owner','owner',x'00',x'00'),(41,'viewer','viewer',x'00',x'00');" ++
            "INSERT INTO stats(user_id,mode,plays) VALUES(40,0,1);" ++
            "INSERT INTO beatmaps(id,set_id,md5,status,artist,title,version,creator) VALUES" ++
            "(75,75,'0123456789abcdef0123456789abcdef',3,'artist','title','diff','mapper');" ++
            "INSERT INTO scores(id,user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,rank_namespace,best) VALUES" ++
            "(700,40,'0123456789abcdef0123456789abcdef',0,0,700000,100,0.98,300,300,10,1,0,0,0,0,1,x'737461626c652d7265706c6179','vanilla',1);" ++
            "INSERT INTO lazer_scores(id,user_id,beatmap_id,ruleset_id,total_score,total_score_without_mods,legacy_total_score,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,pp,best,rank_namespace,replay) VALUES" ++
            "(700,40,75,0,800000,750000,NULL,0.99,350,1,'S','[]','{}','{}','[]',120,1,'vanilla',x'6c617a65722d7265706c6179')",
    );

    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const viewer = try sessions.create((try store.userById(std.testing.allocator, 41)).?, 0, 0, 0);

    // Stable's friend packet writes the same directional relation exposed as
    // follower_count by lazer's profile response.
    const stable_add = try clientIntPacket(std.testing.allocator, .friend_add, 40);
    defer std.testing.allocator.free(stable_add);
    const stable_add_reply = try bancho.poll(std.testing.allocator, &store, &sessions, viewer, stable_add);
    defer std.testing.allocator.free(stable_add_reply);
    const followed_summary = (try store.lazerProfileSummary(40)).?;
    try std.testing.expectEqual(@as(i32, 1), followed_summary.follower_count);
    try std.testing.expectEqual(@as(i32, 1), (try store.lazerBatchUserVisibility(40)).?.follower_count);
    const owner = (try store.userById(std.testing.allocator, 40)).?;
    defer std.testing.allocator.free(owner.name);
    defer std.testing.allocator.free(owner.safe_name);
    try std.testing.expectEqual(@as(i32, 1), owner.follower_count);
    var compact: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer compact.deinit();
    try user_json.writeCompact(&compact.writer, owner, owner.show_country);
    var parsed_compact = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, compact.written(), .{});
    defer parsed_compact.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed_compact.value.object.get("follower_count").?.integer);
    const lazer_profile = try user_json.profileOwnedWithView(std.testing.allocator, owner, null, .{}, .{}, "[]", .{ .summary = followed_summary });
    defer std.testing.allocator.free(lazer_profile);
    var parsed_profile = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lazer_profile, .{});
    defer parsed_profile.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed_profile.value.object.get("follower_count").?.integer);

    // Existing rows stop contributing as soon as either side is restricted,
    // and neither client can use the stale row to recreate a relationship.
    try store.exec("UPDATE users SET restricted=1 WHERE id=41");
    try std.testing.expectEqual(@as(i32, 0), (try store.lazerProfileSummary(40)).?.follower_count);
    try std.testing.expectEqual(@as(i32, 0), (try store.lazerBatchUserVisibility(40)).?.follower_count);
    const restricted_sender_friends = try store.friendIds(std.testing.allocator, 41);
    defer std.testing.allocator.free(restricted_sender_friends);
    try std.testing.expectEqualSlices(i32, &.{3}, restricted_sender_friends);
    try std.testing.expectEqual(domain.RelationshipAddResult.ineligible, try store.addFriend(41, 40));
    try store.exec("UPDATE users SET restricted=0 WHERE id=41; UPDATE users SET restricted=1 WHERE id=40");
    try std.testing.expectEqual(@as(i32, 0), (try store.lazerProfileSummary(40)).?.follower_count);
    const restricted_target_friends = try store.friendIds(std.testing.allocator, 41);
    defer std.testing.allocator.free(restricted_target_friends);
    try std.testing.expectEqualSlices(i32, &.{3}, restricted_target_friends);
    try std.testing.expectEqual(domain.RelationshipAddResult.ineligible, try store.addFriend(41, 40));
    try store.exec("UPDATE users SET restricted=0 WHERE id=40");

    const stable_remove = try clientIntPacket(std.testing.allocator, .friend_remove, 40);
    defer std.testing.allocator.free(stable_remove);
    const stable_remove_reply = try bancho.poll(std.testing.allocator, &store, &sessions, viewer, stable_remove);
    defer std.testing.allocator.free(stable_remove_reply);
    try std.testing.expectEqual(@as(i32, 0), (try store.lazerProfileSummary(40)).?.follower_count);

    // Lazer's POST /api/v2/friends uses this operation; Stable reads the same
    // row for its friends packet and legacy web endpoint.
    try std.testing.expectEqual(domain.RelationshipAddResult.inserted, try store.addFriend(41, 40));
    const stable_friend_ids = try store.friendIds(std.testing.allocator, 41);
    defer std.testing.allocator.free(stable_friend_ids);
    try std.testing.expect(std.mem.indexOfScalar(i32, stable_friend_ids, 40) != null);
    try std.testing.expect(std.mem.indexOfScalar(i32, stable_friend_ids, 3) != null);
    try std.testing.expect(try store.removeFriend(41, 40));
    try std.testing.expectEqual(@as(i32, 0), (try store.lazerProfileSummary(40)).?.follower_count);

    // Mirror the two authenticated download handlers. The score ids are
    // deliberately identical: source is part of the shared unique-view key.
    const stable_replay = (try store.stableReplay(std.testing.allocator, 700)).?;
    defer std.testing.allocator.free(stable_replay);
    try std.testing.expectEqualStrings("stable-replay", stable_replay);
    try std.testing.expect(try store.recordReplayView(41, .stable, 700));
    try std.testing.expectEqual(@as(i32, 1), try store.replayViewCount(40, .all, 0));
    try std.testing.expectEqual(@as(i32, 1), try store.replayViewCount(40, .stable, 0));
    try std.testing.expectEqual(@as(i32, 0), try store.replayViewCount(40, .lazer, 0));

    const lazer_replay = (try store.lazerReplay(std.testing.allocator, 700)).?;
    defer std.testing.allocator.free(lazer_replay);
    try std.testing.expectEqualStrings("lazer-replay", lazer_replay);
    try std.testing.expect(try store.recordReplayView(41, .lazer, 700));
    try std.testing.expectEqual(@as(i32, 2), try store.replayViewCount(40, .all, 0));
    try std.testing.expectEqual(@as(i32, 1), try store.replayViewCount(40, .stable, 0));
    try std.testing.expectEqual(@as(i32, 1), try store.replayViewCount(40, .lazer, 0));
    try std.testing.expectEqual(@as(i32, 0), try store.replayViewCount(40, .all, 1));
    try std.testing.expectEqual(@as(i32, 2), (try store.statsForUser(40, 0)).?.replay_views);
    try std.testing.expectEqual(@as(i32, 1), (try store.sourceStatsForUser(40, 0, .stable)).?.replay_views);
    try std.testing.expectEqual(@as(i32, 1), (try store.sourceStatsForUser(40, 0, .lazer)).?.replay_views);
    try store.exec("UPDATE score_replay_views SET viewed_at=CASE source WHEN 'stable' THEN unixepoch('2026-07-15T00:00:00Z') ELSE unixepoch('2026-08-15T00:00:00Z') END WHERE owner_id=40");
    const watched_history = try store.lazerReplaysWatchedCountsJson(std.testing.allocator, 40, 0);
    defer std.testing.allocator.free(watched_history);
    var parsed_watched_history = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, watched_history, .{});
    defer parsed_watched_history.deinit();
    const watched_months = parsed_watched_history.value.array.items;
    try std.testing.expectEqual(@as(usize, 2), watched_months.len);
    try std.testing.expectEqualStrings("2026-07-01", watched_months[0].object.get("start_date").?.string);
    try std.testing.expectEqual(@as(i64, 1), watched_months[0].object.get("count").?.integer);
    try std.testing.expectEqualStrings("2026-08-01", watched_months[1].object.get("start_date").?.string);
    try std.testing.expectEqual(@as(i64, 1), watched_months[1].object.get("count").?.integer);
    const empty_watched_history = try store.lazerReplaysWatchedCountsJson(std.testing.allocator, 40, 1);
    defer std.testing.allocator.free(empty_watched_history);
    try std.testing.expectEqualStrings("[]", empty_watched_history);
    try std.testing.expectError(error.InvalidRulesetId, store.lazerReplaysWatchedCountsJson(std.testing.allocator, 40, 4));
    const ranking = try store.lazerRankingsJson(std.testing.allocator, 0, .performance, null, 1);
    defer std.testing.allocator.free(ranking);
    var parsed_ranking = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, ranking, .{});
    defer parsed_ranking.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed_ranking.value.object.get("ranking").?.array.items[0].object.get("replays_watched_by_others").?.integer);

    // A repeat download refreshes the ledger row but cannot increase the
    // unique total, and owners never create rows for their own replays.
    try std.testing.expect(try store.recordReplayView(41, .stable, 700));
    try std.testing.expect(try store.recordReplayView(41, .lazer, 700));
    try std.testing.expect(!try store.recordReplayView(40, .stable, 700));
    try std.testing.expect(!try store.recordReplayView(40, .lazer, 700));
    try std.testing.expectEqual(@as(i32, 2), try store.replayViewCount(40, .all, 0));

    // Once the bytes are offloaded, every public Stable/lazer projection must
    // still advertise the passed replay from replay_objects.
    try store.exec(
        "INSERT INTO replay_objects(source,score_id,object_key,etag,object_bytes) VALUES" ++
            "('stable',700,'replays/stable/700','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',13)," ++
            "('lazer',700,'replays/lazer/700','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',12);" ++
            "UPDATE scores SET replay=NULL WHERE id=700;" ++
            "UPDATE lazer_scores SET replay=NULL WHERE id=700;",
    );
    inline for (.{ domain.SiteScoreSource.stable, domain.SiteScoreSource.lazer }) |source| {
        const board_json = (try store.siteBeatmapLeaderboard(std.testing.allocator, 75, source, 0)).?;
        defer std.testing.allocator.free(board_json);
        var board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, board_json, .{});
        defer board.deinit();
        try std.testing.expect(board.value.object.get("scores").?.array.items[0].object.get("has_replay").?.bool);
    }
    const object_scores_json = try store.lazerUserScoresJson(std.testing.allocator, 40, 0, .recent, .all, 0, 50);
    defer std.testing.allocator.free(object_scores_json);
    var object_scores = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, object_scores_json, .{});
    defer object_scores.deinit();
    try std.testing.expectEqual(@as(usize, 2), object_scores.value.array.items.len);
    for (object_scores.value.array.items) |score_value| try std.testing.expect(score_value.object.get("has_replay").?.bool);
    const object_profile_json = (try store.siteProfile(std.testing.allocator, 40, .all, 0)).?;
    defer std.testing.allocator.free(object_profile_json);
    var object_profile = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, object_profile_json, .{});
    defer object_profile.deinit();
    const recent_scores = object_profile.value.object.get("recent_scores").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), recent_scores.len);
    for (recent_scores) |score_value| try std.testing.expect(score_value.object.get("has_replay").?.bool);
    const lazer_detail_json = (try store.lazerScoreJson(std.testing.allocator, 700, 75)).?;
    defer std.testing.allocator.free(lazer_detail_json);
    var lazer_detail = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lazer_detail_json, .{});
    defer lazer_detail.deinit();
    try std.testing.expect(lazer_detail.value.object.get("has_replay").?.bool);
    const stable_client_board = try store.stableLeaderboard(std.testing.allocator, owner, "0123456789abcdef0123456789abcdef", 0, 0, 0);
    defer std.testing.allocator.free(stable_client_board);
    var stable_rows = std.mem.splitScalar(u8, stable_client_board, '\n');
    var stable_replay_row = false;
    while (stable_rows.next()) |row| {
        if (std.mem.indexOf(u8, row, "|owner|") == null) continue;
        const replay_field = row[(std.mem.lastIndexOfScalar(u8, row, '|') orelse continue) + 1 ..];
        if (std.mem.eql(u8, replay_field, "1")) stable_replay_row = true;
    }
    try std.testing.expect(stable_replay_row);
}

test "stable login owns friend state and restores private message privacy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/social-login.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const player_id = try store.register("social", "social@example.invalid", "00000000000000000000000000000000");
    const friend_id = try store.register("friend", "friend@example.invalid", "11111111111111111111111111111111");
    try std.testing.expectEqual(domain.RelationshipAddResult.inserted, try store.addFriend(player_id, friend_id));
    const body = "social\n00000000000000000000000000000000\n" ++
        "b20260811|0|0|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1.2.3.:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccc:dddddddddddddddddddddddddddddddd:|1";
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    var result = try bancho.login(std.testing.allocator, &store, &sessions, body, .{ 'A', 'U' }, 0, 0);
    defer result.deinit();
    try expectIntListContains(result.body, .friends_list, &.{ 3, friend_id });
    const session = sessions.byUser(player_id).?;
    try std.testing.expect(session.block_non_friend_dms);
    try std.testing.expect(session.isFriend(3));
    try std.testing.expect(session.isFriend(friend_id));
}

test "stable social packets enforce friend-only dms and away presence contracts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/social-packets.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt,privileges,restricted) VALUES" ++
            "(40,'sender','sender',x'00',x'00',3,0)," ++
            "(41,'target','target',x'00',x'00',3,0)," ++
            "(42,'restricted','restricted',x'00',x'00',2,1)",
    );
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const sender = try sessions.create((try store.userById(std.testing.allocator, 40)).?, 0, 0, 0);
    const target = try sessions.create((try store.userById(std.testing.allocator, 41)).?, 0, 0, 0);
    _ = try sessions.create((try store.userById(std.testing.allocator, 42)).?, 0, 0, 0);

    const privacy = try clientIntPacket(std.testing.allocator, .toggle_block_non_friend_dms, 1);
    defer std.testing.allocator.free(privacy);
    const privacy_reply = try bancho.poll(std.testing.allocator, &store, &sessions, target, privacy);
    defer std.testing.allocator.free(privacy_reply);
    try std.testing.expect(target.block_non_friend_dms);

    const blocked = try clientMessagePacket(std.testing.allocator, .send_private_message, "sender", "blocked", "target", 40);
    defer std.testing.allocator.free(blocked);
    const blocked_reply = try bancho.poll(std.testing.allocator, &store, &sessions, sender, blocked);
    defer std.testing.allocator.free(blocked_reply);
    try expectPacket(blocked_reply, .user_dm_blocked);
    try std.testing.expectEqual(@as(usize, 0), target.queue.items.len);

    const add = try clientIntPacket(std.testing.allocator, .friend_add, 40);
    defer std.testing.allocator.free(add);
    const add_reply = try bancho.poll(std.testing.allocator, &store, &sessions, target, add);
    defer std.testing.allocator.free(add_reply);
    try std.testing.expect(target.isFriend(40));
    const add_restricted = try clientIntPacket(std.testing.allocator, .friend_add, 42);
    defer std.testing.allocator.free(add_restricted);
    const add_restricted_reply = try bancho.poll(std.testing.allocator, &store, &sessions, target, add_restricted);
    defer std.testing.allocator.free(add_restricted_reply);
    try std.testing.expect(!target.isFriend(42));
    const delivered = try clientMessagePacket(std.testing.allocator, .send_private_message, "sender", "delivered once", "target", 40);
    defer std.testing.allocator.free(delivered);
    const delivered_reply = try bancho.poll(std.testing.allocator, &store, &sessions, sender, delivered);
    defer std.testing.allocator.free(delivered_reply);
    const target_message = try bancho.poll(std.testing.allocator, &store, &sessions, target, "");
    defer std.testing.allocator.free(target_message);
    try expectMessageText(target_message, "delivered once");
    const delivered_unread = try store.unreadDirectMessages(std.testing.allocator, target.user.id);
    defer {
        for (delivered_unread) |*message| message.deinit(std.testing.allocator);
        std.testing.allocator.free(delivered_unread);
    }
    try std.testing.expectEqual(@as(usize, 0), delivered_unread.len);
    const delivered_read = try store.unreadDirectMessages(std.testing.allocator, target.user.id);
    defer std.testing.allocator.free(delivered_read);
    try std.testing.expectEqual(@as(usize, 0), delivered_read.len);

    const afk = try clientActionPacket(std.testing.allocator, 1);
    defer std.testing.allocator.free(afk);
    const afk_reply = try bancho.poll(std.testing.allocator, &store, &sessions, target, afk);
    defer std.testing.allocator.free(afk_reply);
    const away = try clientMessagePacket(std.testing.allocator, .set_away_message, "target", "getting tea", "", 41);
    defer std.testing.allocator.free(away);
    const away_reply = try bancho.poll(std.testing.allocator, &store, &sessions, target, away);
    defer std.testing.allocator.free(away_reply);
    try std.testing.expectEqualStrings("getting tea", target.away());
    const away_dm = try clientMessagePacket(std.testing.allocator, .send_private_message, "sender", "ping", "target", 40);
    defer std.testing.allocator.free(away_dm);
    const away_dm_reply = try bancho.poll(std.testing.allocator, &store, &sessions, sender, away_dm);
    defer std.testing.allocator.free(away_dm_reply);
    try expectMessageText(away_dm_reply, "getting tea");
    const target_ping = try bancho.poll(std.testing.allocator, &store, &sessions, target, "");
    defer std.testing.allocator.free(target_ping);
    try expectMessageText(target_ping, "ping");

    const remove = try clientIntPacket(std.testing.allocator, .friend_remove, 40);
    defer std.testing.allocator.free(remove);
    const remove_reply = try bancho.poll(std.testing.allocator, &store, &sessions, target, remove);
    defer std.testing.allocator.free(remove_reply);
    try std.testing.expect(!target.isFriend(40));
    const blocked_again_reply = try bancho.poll(std.testing.allocator, &store, &sessions, sender, blocked);
    defer std.testing.allocator.free(blocked_again_reply);
    try expectPacket(blocked_again_reply, .user_dm_blocked);

    const friends_only = try clientIntPacket(std.testing.allocator, .receive_updates, 2);
    defer std.testing.allocator.free(friends_only);
    const filter_reply = try bancho.poll(std.testing.allocator, &store, &sessions, sender, friends_only);
    defer std.testing.allocator.free(filter_reply);
    try std.testing.expectEqual(@as(u8, 2), sender.presence_filter);
    const invalid_filter = try clientIntPacket(std.testing.allocator, .receive_updates, 3);
    defer std.testing.allocator.free(invalid_filter);
    const invalid_filter_reply = try bancho.poll(std.testing.allocator, &store, &sessions, sender, invalid_filter);
    defer std.testing.allocator.free(invalid_filter_reply);
    try std.testing.expectEqual(@as(u8, 2), sender.presence_filter);

    const presence_all = try clientIntPacket(std.testing.allocator, .user_presence_request_all, 0);
    defer std.testing.allocator.free(presence_all);
    const presence_reply = try bancho.poll(std.testing.allocator, &store, &sessions, sender, presence_all);
    defer std.testing.allocator.free(presence_reply);
    try expectPresenceUsers(presence_reply, &.{ 40, 41 }, &.{42});
}

test "restricted Stable dispatch cannot mutate social channel lobby match or spectator state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/restricted-dispatch.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt,privileges,restricted) VALUES" ++
            "(60,'restricted player','restricted_player',x'00',x'00',2,1)," ++
            "(61,'visible player','visible_player',x'00',x'00',3,0)",
    );

    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const restricted = try sessions.create((try store.userById(std.testing.allocator, 60)).?, 0, 0, 0);
    const visible = try sessions.create((try store.userById(std.testing.allocator, 61)).?, 0, 0, 0);
    try std.testing.expect(sessions.join(visible, "#osu"));

    var channel_payload = protocol.Writer.init(std.testing.allocator);
    defer channel_payload.deinit();
    try channel_payload.string("#osu");
    const channel_join = try clientPayloadPacket(std.testing.allocator, .channel_join, channel_payload.bytes());
    defer std.testing.allocator.free(channel_join);
    const friend_add = try clientIntPacket(std.testing.allocator, .friend_add, visible.user.id);
    defer std.testing.allocator.free(friend_add);
    const lobby_join = try clientEmptyPacket(std.testing.allocator, .join_lobby);
    defer std.testing.allocator.free(lobby_join);
    const spectate = try clientIntPacket(std.testing.allocator, .start_spectating, visible.user.id);
    defer std.testing.allocator.free(spectate);
    const create_match = try clientMatchPacket(std.testing.allocator, .create_match, restricted.user.id, "must-not-exist");
    defer std.testing.allocator.free(create_match);
    const public_message = try clientMessagePacket(std.testing.allocator, .send_public_message, restricted.user.name, "must not send", "#osu", restricted.user.id);
    defer std.testing.allocator.free(public_message);
    const privacy = try clientIntPacket(std.testing.allocator, .toggle_block_non_friend_dms, 1);
    defer std.testing.allocator.free(privacy);

    var denied_packets: std.ArrayList(u8) = .empty;
    defer denied_packets.deinit(std.testing.allocator);
    for ([_][]const u8{ channel_join, friend_add, lobby_join, spectate, create_match, public_message, privacy }) |packet| try denied_packets.appendSlice(std.testing.allocator, packet);
    const denied_reply = try bancho.poll(std.testing.allocator, &store, &sessions, restricted, denied_packets.items);
    defer std.testing.allocator.free(denied_reply);
    try std.testing.expectEqual(@as(usize, 0), denied_reply.len);
    try std.testing.expect(!restricted.joined_osu);
    try std.testing.expect(!restricted.joined_lobby_channel and !restricted.in_lobby);
    try std.testing.expect(restricted.match_id == null);
    try std.testing.expect(restricted.spectating_user_id == null);
    try std.testing.expect(!restricted.isFriend(visible.user.id));
    try std.testing.expect(!restricted.block_non_friend_dms);
    try std.testing.expect(sessions.matchById(0) == null);
    try std.testing.expectEqual(@as(usize, 0), visible.queue.items.len);

    const allowed_action = try clientActionPacket(std.testing.allocator, 2);
    defer std.testing.allocator.free(allowed_action);
    const action_reply = try bancho.poll(std.testing.allocator, &store, &sessions, restricted, allowed_action);
    defer std.testing.allocator.free(action_reply);
    try std.testing.expectEqual(@as(u8, 2), restricted.action);
    try expectPacket(action_reply, .user_stats);
    try std.testing.expectEqual(@as(usize, 0), visible.queue.items.len);
}

test "deferred Stable commands leave authority to the database and owner poll refresh" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/deferred-command-authority.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const admin_id = try store.register("authority admin", "authority-admin@example.invalid", "00000000000000000000000000000000");
    const target_id = try store.register("authority target", "authority-target@example.invalid", "11111111111111111111111111111111");
    _ = try store.changePrivileges(admin_id, admin_id, 1 << 13, true);

    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const admin = try sessions.create((try store.userById(std.testing.allocator, admin_id)).?, 0, 0, 0);
    const target = try sessions.create((try store.userById(std.testing.allocator, target_id)).?, 0, 0, 0);
    try std.testing.expect(sessions.join(admin, "#osu"));

    const restrict = try clientMessagePacket(std.testing.allocator, .send_public_message, admin.user.name, "!restrict authority_target current command", "#osu", admin_id);
    defer std.testing.allocator.free(restrict);
    const command_reply = try bancho.poll(std.testing.allocator, &store, &sessions, admin, restrict);
    defer std.testing.allocator.free(command_reply);
    const stored_restricted = (try store.userById(std.testing.allocator, target_id)).?;
    defer {
        std.testing.allocator.free(stored_restricted.name);
        std.testing.allocator.free(stored_restricted.safe_name);
    }
    try std.testing.expect(stored_restricted.restricted);
    try std.testing.expect(!target.user.restricted);

    const target_restricted = try bancho.poll(std.testing.allocator, &store, &sessions, target, "");
    defer std.testing.allocator.free(target_restricted);
    try std.testing.expect(target.user.restricted);
    try expectPacket(target_restricted, .account_restricted);

    try store.setRestricted(admin_id, target_id, false, "newer database truth");
    _ = try store.changePrivileges(admin_id, target_id, 1 << 12, true);
    const silence_end = std.Io.Clock.real.now(std.testing.io).toSeconds() + 600;
    try store.setSilence(admin_id, target_id, silence_end, "account.silence", "newer database truth");
    const refreshed = try bancho.poll(std.testing.allocator, &store, &sessions, target, "");
    defer std.testing.allocator.free(refreshed);
    try std.testing.expect(!target.user.restricted);
    try std.testing.expect(target.user.privileges & (1 << 12) != 0);
    try std.testing.expectEqual(silence_end, target.user.silence_end);
    try expectPacket(refreshed, .privileges);
    try expectPacket(refreshed, .silence_end);
    try expectPacket(refreshed, .restart);
}

test "joined public chat delivers once and kai answers private chat as user three" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/chat.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT OR IGNORE INTO users(id,name,safe_name,password_hash,password_salt) VALUES(1,'ari','ari',x'00',x'00'),(2,'raya','raya',x'00',x'00')");
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    _ = try sessions.createBot((try store.userById(std.testing.allocator, 3)).?);
    const ari = try sessions.create(.{ .id = 1, .name = try std.testing.allocator.dupe(u8, "ari"), .safe_name = try std.testing.allocator.dupe(u8, "ari") }, 0, 0, 0);
    const raya = try sessions.create(.{ .id = 2, .name = try std.testing.allocator.dupe(u8, "raya"), .safe_name = try std.testing.allocator.dupe(u8, "raya") }, 0, 0, 0);
    try std.testing.expect(sessions.join(ari, "#osu"));
    try std.testing.expect(sessions.join(raya, "#osu"));

    const public = try clientMessagePacket(std.testing.allocator, .send_public_message, "ari", "hello once", "#osu", 1);
    defer std.testing.allocator.free(public);
    const sender_reply = try bancho.poll(std.testing.allocator, &store, &sessions, ari, public);
    defer std.testing.allocator.free(sender_reply);
    try std.testing.expectEqual(@as(usize, 0), sender_reply.len);
    const received = try bancho.poll(std.testing.allocator, &store, &sessions, raya, "");
    defer std.testing.allocator.free(received);
    var public_reader: protocol.Reader = .{ .data = received };
    const public_packet = (try public_reader.next()).?;
    try std.testing.expectEqual(@as(u16, 7), @intFromEnum(public_packet.id));
    var public_payload: protocol.PayloadReader = .{ .data = public_packet.payload };
    try std.testing.expectEqualStrings("ari", try public_payload.string());
    try std.testing.expectEqualStrings("hello once", try public_payload.string());
    try std.testing.expectEqualStrings("#osu", try public_payload.string());
    try std.testing.expectEqual(@as(i32, 1), try public_payload.int(i32));
    try std.testing.expect((try public_reader.next()) == null);

    const private = try clientMessagePacket(std.testing.allocator, .send_private_message, "ari", "hello", "kai", 1);
    defer std.testing.allocator.free(private);
    const bot_reply = try bancho.poll(std.testing.allocator, &store, &sessions, ari, private);
    defer std.testing.allocator.free(bot_reply);
    var bot_reader: protocol.Reader = .{ .data = bot_reply };
    const bot_packet = (try bot_reader.next()).?;
    var bot_payload: protocol.PayloadReader = .{ .data = bot_packet.payload };
    try std.testing.expectEqualStrings("kai", try bot_payload.string());
    try std.testing.expectEqualStrings("send /np here for pp, then use !with for a custom play", try bot_payload.string());
    try std.testing.expectEqualStrings("ari", try bot_payload.string());
    try std.testing.expectEqual(@as(i32, 3), try bot_payload.int(i32));
    try std.testing.expectEqual(@as(usize, 0), sessions.byUser(3).?.queue.items.len);
}

test "online Stable direct mail becomes read only when the target drains the exact packet" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/stable-online-mail.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const sender_id = try store.register("mail sender", "sender@example.invalid", "00000000000000000000000000000000");
    const target_id = try store.register("mail target", "target@example.invalid", "11111111111111111111111111111111");
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const sender = try sessions.create((try store.userById(std.testing.allocator, sender_id)).?, 0, 0, 0);
    const target = try sessions.create((try store.userById(std.testing.allocator, target_id)).?, 0, 0, 0);

    const private = try clientMessagePacket(std.testing.allocator, .send_private_message, sender.user.name, "delivered once", target.user.name, sender_id);
    defer std.testing.allocator.free(private);
    const sender_reply = try bancho.poll(std.testing.allocator, &store, &sessions, sender, private);
    defer std.testing.allocator.free(sender_reply);
    var message_id: i64 = 0;
    {
        const unread = try store.unreadDirectMessages(std.testing.allocator, target_id);
        defer {
            for (unread) |*message| message.deinit(std.testing.allocator);
            std.testing.allocator.free(unread);
        }
        try std.testing.expectEqual(@as(usize, 1), unread.len);
        message_id = unread[0].id;
    }
    try std.testing.expectEqualSlices(i64, &.{message_id}, target.pending_dm_reads.items);

    const delivered = try bancho.poll(std.testing.allocator, &store, &sessions, target, "");
    defer std.testing.allocator.free(delivered);
    try expectMessageContains(delivered, "delivered once");
    const read = try store.unreadDirectMessages(std.testing.allocator, target_id);
    defer std.testing.allocator.free(read);
    try std.testing.expectEqual(@as(usize, 0), read.len);
    try std.testing.expect(!try store.markDirectMessageRead(target_id, message_id));
}

test "Stable polling recovers mail inserted after login without duplicating it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/stable-reconnect-mail.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const sender_id = try store.register("late sender", "late-sender@example.invalid", "00000000000000000000000000000000");
    const target_id = try store.register("late target", "late-target@example.invalid", "11111111111111111111111111111111");
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const target = try sessions.create((try store.userById(std.testing.allocator, target_id)).?, 0, 0, 0);

    const message_id = try store.storeDirectMessage(sender_id, target_id, "arrived after login snapshot");
    try std.testing.expectEqual(@as(usize, 0), target.pending_dm_reads.items.len);
    const delivered = try bancho.poll(std.testing.allocator, &store, &sessions, target, "");
    defer std.testing.allocator.free(delivered);
    try expectMessageContains(delivered, "arrived after login snapshot");
    try std.testing.expect(!try store.markDirectMessageRead(target_id, message_id));

    const duplicate = try bancho.poll(std.testing.allocator, &store, &sessions, target, "");
    defer std.testing.allocator.free(duplicate);
    try std.testing.expect(std.mem.indexOf(u8, duplicate, "arrived after login snapshot") == null);
}

test "stable slash np selects the linked map and returns pp without a fake pp command" {
    const commands = @import("commands.zig");
    const modern = commands.parseNowPlaying("\x01ACTION is listening to [https://osu.ppy.sh/beatmapsets/900000000#osu/900000001 Zigcho - Zigcho Fixture [Tests]] +HD\x01").?;
    try std.testing.expectEqual(@as(i32, 900000001), modern.beatmap_id);
    try std.testing.expectEqual(@as(?u8, 0), modern.mode);
    try std.testing.expectEqual(@as(?i32, 1 << 3), modern.mods);
    const stable_words = commands.parseNowPlaying("\x01ACTION is listening to [https://osu.ppy.sh/beatmapsets/900000000#osu/900000001 Zigcho - Zigcho Fixture [Tests]] +Hidden ~Relax~\x01").?;
    try std.testing.expectEqual(@as(?i32, (1 << 3) | (1 << 7)), stable_words.mods);
    const legacy = commands.parseNowPlaying("\x01ACTION is playing [https://osu.ppy.sh/b/900000001 Zigcho - Zigcho Fixture [Tests]]\x01").?;
    try std.testing.expectEqual(@as(i32, 900000001), legacy.beatmap_id);
    try std.testing.expect(commands.parseNowPlaying("!pp") == null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/slash-np.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("np player", "np-player@example.invalid", "00000000000000000000000000000000");
    const map = @embedFile("testdata/synthetic-standard.osu");
    const metadata = try beatmap.parse(map);
    const hash = beatmap.md5(map);
    try store.upsertBeatmap(metadata, &hash, 3, 1.8, 10, map);
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    _ = try sessions.createBot((try store.userById(std.testing.allocator, 3)).?);
    const player = try sessions.create((try store.userById(std.testing.allocator, user_id)).?, 0, 0, 0);
    const np = try clientMessagePacket(std.testing.allocator, .send_private_message, "np player", "\x01ACTION is listening to [https://osu.ppy.sh/beatmapsets/900000000#osu/900000001 Zigcho - Zigcho Fixture [Tests]] +Hidden ~Relax~\x01", "kai", user_id);
    defer std.testing.allocator.free(np);
    const response = try bancho.poll(std.testing.allocator, &store, &sessions, player, np);
    defer std.testing.allocator.free(response);
    try std.testing.expectEqual(@as(i32, 900000001), player.map_id);
    try std.testing.expectEqualSlices(u8, &hash, &player.map_md5);
    try std.testing.expectEqual(@as(i32, (1 << 3) | (1 << 7)), player.mods);
    const pp_reply = try bancho.poll(std.testing.allocator, &store, &sessions, player, "");
    defer std.testing.allocator.free(pp_reply);
    try expectMessageContains(pp_reply, "90%:");
    try expectMessageContains(pp_reply, "100%:");
    try expectMessageContains(pp_reply, "HDRX");

    const with = try clientMessagePacket(std.testing.allocator, .send_private_message, "np player", "!with HDDT", "kai", user_id);
    defer std.testing.allocator.free(with);
    const with_response = try bancho.poll(std.testing.allocator, &store, &sessions, player, with);
    defer std.testing.allocator.free(with_response);
    try std.testing.expectEqual(@as(i32, (1 << 3) | (1 << 6)), player.mods);
    const with_reply = try bancho.poll(std.testing.allocator, &store, &sessions, player, "");
    defer std.testing.allocator.free(with_reply);
    try expectMessageContains(with_reply, "HDDT");
}

test "score announcements only reach players in announcement chat" {
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const joined = try sessions.create(.{ .id = 1, .name = try std.testing.allocator.dupe(u8, "joined"), .safe_name = try std.testing.allocator.dupe(u8, "joined") }, 0, 0, 0);
    const outside = try sessions.create(.{ .id = 2, .name = try std.testing.allocator.dupe(u8, "outside"), .safe_name = try std.testing.allocator.dupe(u8, "outside") }, 0, 0, 0);
    try std.testing.expect(sessions.join(joined, "#announce"));
    try bancho.publishAnnouncement(std.testing.allocator, &sessions, "ari set #1 with 500pp");
    try expectMessageText(joined.queue.items, "ari set #1 with 500pp");
    try std.testing.expectEqual(@as(usize, 0), outside.queue.items.len);
}

test "stable chat commands enforce silence and audit staff actions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/chat-moderation.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt,privileges) VALUES" ++
            "(10,'admin','admin',x'00',x'00',12291)," ++
            "(11,'target','target',x'00',x'00',3)," ++
            "(12,'observer','observer',x'00',x'00',3);" ++
            "INSERT INTO stats(user_id,mode) VALUES(10,0),(11,0),(12,0);",
    );
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    _ = try sessions.createBot((try store.userById(std.testing.allocator, 3)).?);
    const admin = try sessions.create((try store.userById(std.testing.allocator, 10)).?, 0, 0, 0);
    const target = try sessions.create((try store.userById(std.testing.allocator, 11)).?, 0, 0, 0);
    const observer = try sessions.create((try store.userById(std.testing.allocator, 12)).?, 0, 0, 0);
    try std.testing.expect(sessions.join(admin, "#osu"));
    try std.testing.expect(sessions.join(target, "#osu"));
    try std.testing.expect(sessions.join(observer, "#osu"));

    const silence = try clientMessagePacket(std.testing.allocator, .send_private_message, "admin", "!silence target 10m testing chat", "kai", 10);
    defer std.testing.allocator.free(silence);
    const silence_reply = try bancho.poll(std.testing.allocator, &store, &sessions, admin, silence);
    defer std.testing.allocator.free(silence_reply);
    try expectMessageText(silence_reply, "target was silenced");
    const target_notice = try bancho.poll(std.testing.allocator, &store, &sessions, target, "");
    defer std.testing.allocator.free(target_notice);
    try expectPacket(target_notice, .silence_end);
    try std.testing.expect(target.user.silence_end > std.Io.Clock.real.now(std.testing.io).toSeconds());
    const observer_notice = try bancho.poll(std.testing.allocator, &store, &sessions, observer, "");
    defer std.testing.allocator.free(observer_notice);
    try expectPacket(observer_notice, .user_silenced);

    const silenced_dm = try clientMessagePacket(std.testing.allocator, .send_private_message, "observer", "can you see this", "target", 12);
    defer std.testing.allocator.free(silenced_dm);
    const silenced_dm_reply = try bancho.poll(std.testing.allocator, &store, &sessions, observer, silenced_dm);
    defer std.testing.allocator.free(silenced_dm_reply);
    try expectPacket(silenced_dm_reply, .target_is_silenced);

    const blocked = try clientMessagePacket(std.testing.allocator, .send_public_message, "target", "this must not land", "#osu", 11);
    defer std.testing.allocator.free(blocked);
    const blocked_reply = try bancho.poll(std.testing.allocator, &store, &sessions, target, blocked);
    defer std.testing.allocator.free(blocked_reply);
    try expectPacket(blocked_reply, .silence_end);
    const observer_after = try bancho.poll(std.testing.allocator, &store, &sessions, observer, "");
    defer std.testing.allocator.free(observer_after);
    try std.testing.expectEqual(@as(usize, 0), observer_after.len);

    const note = try clientMessagePacket(std.testing.allocator, .send_private_message, "admin", "!addnote target watched chat enforcement", "kai", 10);
    defer std.testing.allocator.free(note);
    const note_reply = try bancho.poll(std.testing.allocator, &store, &sessions, admin, note);
    defer std.testing.allocator.free(note_reply);
    try expectMessageText(note_reply, "note added");
    const notes = try clientMessagePacket(std.testing.allocator, .send_private_message, "admin", "!notes target", "kai", 10);
    defer std.testing.allocator.free(notes);
    const notes_reply = try bancho.poll(std.testing.allocator, &store, &sessions, admin, notes);
    defer std.testing.allocator.free(notes_reply);
    try std.testing.expect(std.mem.indexOf(u8, notes_reply, "watched chat enforcement") != null);

    const unsilence = try clientMessagePacket(std.testing.allocator, .send_private_message, "admin", "!unsilence target reviewed", "kai", 10);
    defer std.testing.allocator.free(unsilence);
    const unsilence_reply = try bancho.poll(std.testing.allocator, &store, &sessions, admin, unsilence);
    defer std.testing.allocator.free(unsilence_reply);
    try expectMessageText(unsilence_reply, "target was unsilenced");
    const target_unsilenced = try bancho.poll(std.testing.allocator, &store, &sessions, target, "");
    defer std.testing.allocator.free(target_unsilenced);
    try expectPacket(target_unsilenced, .silence_end);
    try std.testing.expect(target.user.silence_end <= std.Io.Clock.real.now(std.testing.io).toSeconds());

    const restrict = try clientMessagePacket(std.testing.allocator, .send_private_message, "admin", "!restrict target repeated abuse", "kai", 10);
    defer std.testing.allocator.free(restrict);
    const restrict_reply = try bancho.poll(std.testing.allocator, &store, &sessions, admin, restrict);
    defer std.testing.allocator.free(restrict_reply);
    try expectMessageText(restrict_reply, "target was restricted");
    const stored_target = (try store.userById(std.testing.allocator, 11)).?;
    defer std.testing.allocator.free(stored_target.name);
    defer std.testing.allocator.free(stored_target.safe_name);
    try std.testing.expect(stored_target.restricted);

    var stmt: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(storage.c.SQLITE_OK, storage.c.sqlite3_prepare_v2(store.db, "SELECT count(*) FROM audit_log WHERE target='user:11'", -1, &stmt, null));
    defer _ = storage.c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(storage.c.SQLITE_ROW, storage.c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(c_int, 4), storage.c.sqlite3_column_int(stmt, 0));
}

test "stable channel permissions and locks survive in storage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/chat-channels.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt,privileges) VALUES" ++
            "(20,'admin','admin',x'00',x'00',24579)," ++
            "(21,'player','player',x'00',x'00',3);" ++
            "INSERT INTO stats(user_id,mode) VALUES(20,0),(21,0);",
    );
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    _ = try sessions.createBot((try store.userById(std.testing.allocator, 3)).?);
    const admin = try sessions.create((try store.userById(std.testing.allocator, 20)).?, 0, 0, 0);
    const player = try sessions.create((try store.userById(std.testing.allocator, 21)).?, 0, 0, 0);
    try std.testing.expect(sessions.join(admin, "#osu"));
    try std.testing.expect(sessions.join(player, "#osu"));

    const announce = try clientMessagePacket(std.testing.allocator, .send_public_message, "player", "not allowed", "#announce", 21);
    defer std.testing.allocator.free(announce);
    const announce_reply = try bancho.poll(std.testing.allocator, &store, &sessions, player, announce);
    defer std.testing.allocator.free(announce_reply);
    try expectStringPacket(announce_reply, .notification, "that channel is read-only right now");

    const denied_restrict = try clientMessagePacket(std.testing.allocator, .send_private_message, "player", "!restrict admin no", "kai", 21);
    defer std.testing.allocator.free(denied_restrict);
    const denied_reply = try bancho.poll(std.testing.allocator, &store, &sessions, player, denied_restrict);
    defer std.testing.allocator.free(denied_reply);
    try expectMessageText(denied_reply, "you do not have permission for that");

    const lock = try clientMessagePacket(std.testing.allocator, .send_private_message, "admin", "!lock #osu maintenance", "kai", 20);
    defer std.testing.allocator.free(lock);
    const lock_reply = try bancho.poll(std.testing.allocator, &store, &sessions, admin, lock);
    defer std.testing.allocator.free(lock_reply);
    try expectMessageText(lock_reply, "channel locked");
    try std.testing.expect(!try store.channelCanWrite("#osu", 3));
    try std.testing.expect(try store.channelCanWrite("#osu", 8195));

    const blocked = try clientMessagePacket(std.testing.allocator, .send_public_message, "player", "also not allowed", "#osu", 21);
    defer std.testing.allocator.free(blocked);
    const blocked_reply = try bancho.poll(std.testing.allocator, &store, &sessions, player, blocked);
    defer std.testing.allocator.free(blocked_reply);
    try expectStringPacket(blocked_reply, .notification, "that channel is read-only right now");

    const unlock = try clientMessagePacket(std.testing.allocator, .send_private_message, "admin", "!unlock #osu finished", "kai", 20);
    defer std.testing.allocator.free(unlock);
    const unlock_reply = try bancho.poll(std.testing.allocator, &store, &sessions, admin, unlock);
    defer std.testing.allocator.free(unlock_reply);
    try expectMessageText(unlock_reply, "channel unlocked");
    try std.testing.expect(try store.channelCanWrite("#osu", 3));

    const add_priv = try clientMessagePacket(std.testing.allocator, .send_private_message, "admin", "!addpriv player supporter", "kai", 20);
    defer std.testing.allocator.free(add_priv);
    const add_priv_reply = try bancho.poll(std.testing.allocator, &store, &sessions, admin, add_priv);
    defer std.testing.allocator.free(add_priv_reply);
    try expectMessageText(add_priv_reply, "privileges updated");
    const privilege_notice = try bancho.poll(std.testing.allocator, &store, &sessions, player, "");
    defer std.testing.allocator.free(privilege_notice);
    try expectPacket(privilege_notice, .privileges);
    try std.testing.expect(player.user.privileges & (1 << 4) != 0);

    const remove_priv = try clientMessagePacket(std.testing.allocator, .send_private_message, "admin", "!rmpriv player supporter", "kai", 20);
    defer std.testing.allocator.free(remove_priv);
    const remove_priv_reply = try bancho.poll(std.testing.allocator, &store, &sessions, admin, remove_priv);
    defer std.testing.allocator.free(remove_priv_reply);
    try expectMessageText(remove_priv_reply, "privileges updated");
    const remove_notice = try bancho.poll(std.testing.allocator, &store, &sessions, player, "");
    defer std.testing.allocator.free(remove_notice);
    try expectPacket(remove_notice, .privileges);
    try std.testing.expect(player.user.privileges & (1 << 4) == 0);

    const delivered = try clientMessagePacket(std.testing.allocator, .send_public_message, "player", "back again", "#osu", 21);
    defer std.testing.allocator.free(delivered);
    const sender_reply = try bancho.poll(std.testing.allocator, &store, &sessions, player, delivered);
    defer std.testing.allocator.free(sender_reply);
    try std.testing.expectEqual(@as(usize, 0), sender_reply.len);
    const received = try bancho.poll(std.testing.allocator, &store, &sessions, admin, "");
    defer std.testing.allocator.free(received);
    try expectMessageText(received, "back again");

    var stmt: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(storage.c.SQLITE_OK, storage.c.sqlite3_prepare_v2(store.db, "SELECT count(*) FROM chat_messages WHERE sender_id=21 AND target='#osu' AND message='back again'", -1, &stmt, null));
    defer _ = storage.c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(storage.c.SQLITE_ROW, storage.c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(stmt, 0));
}

test "staff announcements persist chat and audit atomically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/staff-announcement-atomic.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const actor_id = try store.register("announce admin", "announce-admin@example.invalid", "00000000000000000000000000000000");
    try store.recordStaffAnnouncement(actor_id, "the server is back", "planned maintenance finished");

    var committed: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(storage.c.SQLITE_OK, storage.c.sqlite3_prepare_v2(store.db, "SELECT (SELECT count(*) FROM chat_messages WHERE sender_id=3 AND target='#announce' AND message='the server is back'),(SELECT count(*) FROM audit_log WHERE actor_id=?1 AND action='infra.announcement' AND target='server' AND detail='planned maintenance finished')", -1, &committed, null));
    _ = storage.c.sqlite3_bind_int(committed, 1, actor_id);
    try std.testing.expectEqual(storage.c.SQLITE_ROW, storage.c.sqlite3_step(committed));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(committed, 0));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(committed, 1));
    try std.testing.expectEqual(storage.c.SQLITE_OK, storage.c.sqlite3_finalize(committed));

    try store.exec("ALTER TABLE audit_log RENAME TO audit_log_unavailable");
    try std.testing.expectError(error.DatabaseQueryFailed, store.recordStaffAnnouncement(actor_id, "must roll back", "broken audit write"));
    var rolled_back: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(storage.c.SQLITE_OK, storage.c.sqlite3_prepare_v2(store.db, "SELECT count(*) FROM chat_messages WHERE message='must roll back'", -1, &rolled_back, null));
    try std.testing.expectEqual(storage.c.SQLITE_ROW, storage.c.sqlite3_step(rolled_back));
    try std.testing.expectEqual(@as(c_int, 0), storage.c.sqlite3_column_int(rolled_back, 0));
    try std.testing.expectEqual(storage.c.SQLITE_OK, storage.c.sqlite3_finalize(rolled_back));
    try store.exec("ALTER TABLE audit_log_unavailable RENAME TO audit_log");
}

test "stable ranking commands enforce bn and admin boundaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/ranking-commands.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt,privileges) VALUES" ++
            "(30,'player','player',x'00',x'00',3)," ++
            "(31,'first_bn','first_bn',x'00',x'00',2051)," ++
            "(32,'second_bn','second_bn',x'00',x'00',2051)," ++
            "(33,'admin','admin',x'00',x'00',8195);" ++
            "INSERT INTO stats(user_id,mode) VALUES(30,0),(31,0),(32,0),(33,0);",
    );
    const map = @embedFile("testdata/synthetic-standard.osu");
    const metadata = try beatmap.parse(map);
    const hash = beatmap.md5(map);
    try store.upsertBeatmap(metadata, &hash, 2, 1.7931, 10, map);
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    _ = try sessions.createBot((try store.userById(std.testing.allocator, 3)).?);
    const player = try sessions.create((try store.userById(std.testing.allocator, 30)).?, 0, 0, 0);
    const first_bn = try sessions.create((try store.userById(std.testing.allocator, 31)).?, 0, 0, 0);
    const second_bn = try sessions.create((try store.userById(std.testing.allocator, 32)).?, 0, 0, 0);
    const admin = try sessions.create((try store.userById(std.testing.allocator, 33)).?, 0, 0, 0);
    @memcpy(&player.map_md5, &hash);
    @memcpy(&first_bn.map_md5, &hash);
    @memcpy(&second_bn.map_md5, &hash);
    @memcpy(&admin.map_md5, &hash);

    const request = try clientMessagePacket(std.testing.allocator, .send_private_message, "player", "!request", "kai", 30);
    defer std.testing.allocator.free(request);
    const request_reply = try bancho.poll(std.testing.allocator, &store, &sessions, player, request);
    defer std.testing.allocator.free(request_reply);
    try std.testing.expect(std.mem.indexOf(u8, request_reply, "is in the queue now") != null);

    const denied_nomination = try clientMessagePacket(std.testing.allocator, .send_private_message, "player", "!nominate looks good", "kai", 30);
    defer std.testing.allocator.free(denied_nomination);
    const denied_reply = try bancho.poll(std.testing.allocator, &store, &sessions, player, denied_nomination);
    defer std.testing.allocator.free(denied_reply);
    try expectMessageText(denied_reply, "you do not have permission for that");

    const first_nomination = try clientMessagePacket(std.testing.allocator, .send_private_message, "first_bn", "!nominate first review", "kai", 31);
    defer std.testing.allocator.free(first_nomination);
    const first_reply = try bancho.poll(std.testing.allocator, &store, &sessions, first_bn, first_nomination);
    defer std.testing.allocator.free(first_reply);
    try expectMessageText(first_reply, "set 900000000 has 1/2 nominations");

    const second_nomination = try clientMessagePacket(std.testing.allocator, .send_private_message, "second_bn", "!nominate second review", "kai", 32);
    defer std.testing.allocator.free(second_nomination);
    const second_reply = try bancho.poll(std.testing.allocator, &store, &sessions, second_bn, second_nomination);
    defer std.testing.allocator.free(second_reply);
    try expectMessageText(second_reply, "set 900000000 has 2/2 nominations");

    const qualify = try clientMessagePacket(std.testing.allocator, .send_private_message, "first_bn", "!qualify both reviews passed", "kai", 31);
    defer std.testing.allocator.free(qualify);
    const qualify_reply = try bancho.poll(std.testing.allocator, &store, &sessions, first_bn, qualify);
    defer std.testing.allocator.free(qualify_reply);
    try std.testing.expect(std.mem.indexOf(u8, qualify_reply, "is qualified now") != null);

    const rank = try clientMessagePacket(std.testing.allocator, .send_private_message, "second_bn", "!rank qualification window complete", "kai", 32);
    defer std.testing.allocator.free(rank);
    const rank_reply = try bancho.poll(std.testing.allocator, &store, &sessions, second_bn, rank);
    defer std.testing.allocator.free(rank_reply);
    try std.testing.expect(std.mem.indexOf(u8, rank_reply, "is ranked now") != null);

    const love = try clientMessagePacket(std.testing.allocator, .send_private_message, "first_bn", "!love move ranked to loved", "kai", 31);
    defer std.testing.allocator.free(love);
    const love_reply = try bancho.poll(std.testing.allocator, &store, &sessions, first_bn, love);
    defer std.testing.allocator.free(love_reply);
    try std.testing.expect(std.mem.indexOf(u8, love_reply, "is loved now") != null);

    const approved = try clientMessagePacket(std.testing.allocator, .send_private_message, "second_bn", "!mapstatus approved this should be approved", "kai", 32);
    defer std.testing.allocator.free(approved);
    const approved_reply = try bancho.poll(std.testing.allocator, &store, &sessions, second_bn, approved);
    defer std.testing.allocator.free(approved_reply);
    try std.testing.expect(std.mem.indexOf(u8, approved_reply, "is approved now") != null);

    try store.exec("INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status) VALUES(900000002,900000000,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','Zigcho','Zigcho Fixture','Mixed','Ari',2)");
    const mixed_loved = try clientMessagePacket(std.testing.allocator, .send_private_message, "first_bn", "!mapstatus loved fix the mixed set", "kai", 31);
    defer std.testing.allocator.free(mixed_loved);
    const mixed_reply = try bancho.poll(std.testing.allocator, &store, &sessions, first_bn, mixed_loved);
    defer std.testing.allocator.free(mixed_reply);
    try std.testing.expect(std.mem.indexOf(u8, mixed_reply, "is loved now") != null);
    var status_stmt: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(storage.c.SQLITE_OK, storage.c.sqlite3_prepare_v2(store.db, "SELECT min(status),max(status),min(status_frozen) FROM beatmaps WHERE set_id=900000000", -1, &status_stmt, null));
    defer _ = storage.c.sqlite3_finalize(status_stmt);
    try std.testing.expectEqual(storage.c.SQLITE_ROW, storage.c.sqlite3_step(status_stmt));
    try std.testing.expectEqual(@as(c_int, 6), storage.c.sqlite3_column_int(status_stmt, 0));
    try std.testing.expectEqual(@as(c_int, 6), storage.c.sqlite3_column_int(status_stmt, 1));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(status_stmt, 2));

    const denied_rollback = try clientMessagePacket(std.testing.allocator, .send_private_message, "first_bn", "!rollback not allowed", "kai", 31);
    defer std.testing.allocator.free(denied_rollback);
    const denied_rollback_reply = try bancho.poll(std.testing.allocator, &store, &sessions, first_bn, denied_rollback);
    defer std.testing.allocator.free(denied_rollback_reply);
    try expectMessageText(denied_rollback_reply, "you do not have permission for that");

    const rollback = try clientMessagePacket(std.testing.allocator, .send_private_message, "admin", "!rollback bad metadata", "kai", 33);
    defer std.testing.allocator.free(rollback);
    const rollback_reply = try bancho.poll(std.testing.allocator, &store, &sessions, admin, rollback);
    defer std.testing.allocator.free(rollback_reply);
    try std.testing.expect(std.mem.indexOf(u8, rollback_reply, "is approved now") != null);
}

test "server roles map to stable privileges and login always grants supporter" {
    const normal: u32 = (1 << 0) | (1 << 1);
    const qat: u32 = normal | (1 << 11);
    const gmt: u32 = normal | (1 << 12);
    try std.testing.expectEqual(@as(u8, 1), bancho.clientPrivileges(normal, false));
    try std.testing.expectEqual(@as(u8, 5), bancho.clientPrivileges(normal, true));
    try std.testing.expectEqual(@as(u8, 5), bancho.clientPrivileges(qat, true));
    try std.testing.expectEqual(@as(u8, 7), bancho.clientPrivileges(gmt, true));
}

test "kai presence carries the stable owner and developer colour bits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/kai-colour.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    _ = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    _ = try sessions.createBot((try store.userById(std.testing.allocator, 3)).?);
    var result = try bancho.login(std.testing.allocator, &store, &sessions, ari_stable_login, .{ 'A', 'U' }, 0, 0);
    defer result.deinit();

    var reader: protocol.Reader = .{ .data = result.body };
    while (try reader.next()) |packet| {
        if (@intFromEnum(packet.id) != @intFromEnum(protocol.ServerPacket.user_presence)) continue;
        var payload: protocol.PayloadReader = .{ .data = packet.payload };
        if (try payload.int(i32) != 3) continue;
        try std.testing.expectEqualStrings("kai", try payload.string());
        _ = try payload.byte();
        _ = try payload.byte();
        try std.testing.expectEqual(@as(u8, 25), try payload.byte());
        return;
    }
    return error.MissingKaiPresence;
}

test "Stable login lists osu and announce channels" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/stable-channel-list.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    _ = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    const lazer_id = try store.register("lazer player", "lazer@example.invalid", "11111111111111111111111111111111");
    const lazer_tokens = try store.issueGameTokenPair(lazer_id, 60, 60, false);
    const lazer_user = (try store.authenticateToken(std.testing.allocator, &lazer_tokens.access, "identify")).?;
    std.testing.allocator.free(lazer_user.name);
    std.testing.allocator.free(lazer_user.safe_name);
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    _ = try sessions.createBot((try store.userById(std.testing.allocator, 3)).?);
    const superseded = try sessions.create(.{ .id = 99, .name = try std.testing.allocator.dupe(u8, "old stable"), .safe_name = try std.testing.allocator.dupe(u8, "old_stable") }, 0, 0, 0);
    superseded.joined_osu = true;
    superseded.presence_suppressed = true;
    var result = try bancho.login(std.testing.allocator, &store, &sessions, ari_stable_login, .{ 'A', 'U' }, 0, 0);
    defer result.deinit();
    var saw_osu = false;
    var saw_announce = false;
    var saw_superseded = false;
    var saw_lazer = false;
    var reader: protocol.Reader = .{ .data = result.body };
    while (try reader.next()) |packet| {
        if (@intFromEnum(packet.id) == @intFromEnum(protocol.ServerPacket.channel_info)) {
            var payload: protocol.PayloadReader = .{ .data = packet.payload };
            const name = try payload.string();
            if (std.mem.eql(u8, name, "#osu")) saw_osu = true;
            if (std.mem.eql(u8, name, "#announce")) saw_announce = true;
        } else if (@intFromEnum(packet.id) == @intFromEnum(protocol.ServerPacket.user_presence)) {
            var payload: protocol.PayloadReader = .{ .data = packet.payload };
            const user_id = try payload.int(i32);
            saw_superseded = saw_superseded or user_id == 99;
            saw_lazer = saw_lazer or user_id == lazer_id;
        }
    }
    try std.testing.expect(saw_osu);
    try std.testing.expect(saw_announce);
    try std.testing.expect(!saw_superseded);
    try std.testing.expect(saw_lazer);
}

test "lazer trailing slashes use the same API route" {
    try std.testing.expectEqualStrings("/api/v2/me", routing.canonicalPath("/api/v2/me/"));
    try std.testing.expectEqualStrings("/", routing.canonicalPath("/"));
}

test "lazer changelog keeps every checked in update" {
    const json = try changelog.indexJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const builds = parsed.value.object.get("builds").?.array.items;
    try std.testing.expectEqual(@as(usize, 24), builds.len);
    var entries: usize = 0;
    for (builds) |build| entries += build.object.get("changelog_entries").?.array.items.len;
    try std.testing.expectEqual(changelog.expected_update_count, entries);
    try std.testing.expectEqual(changelog.expected_update_count, changelog.historyEntryCount());
    try std.testing.expectEqual(changelog.expected_update_manifest, changelog.historyManifest());
    const oldest = (try changelog.buildJson(std.testing.allocator, "lazer", "2026.809.0")).?;
    defer std.testing.allocator.free(oldest);
}

test "lazer beatmap metadata is separate from archive downloads" {
    try std.testing.expect(routing.lazerBeatmapMetadata("/api/v2/beatmaps"));
    try std.testing.expect(routing.lazerBeatmapMetadata("/api/v2/beatmaps/lookup"));
    try std.testing.expect(routing.lazerBeatmapMetadata("/api/v2/beatmaps/123/solo-scores"));
    try std.testing.expect(routing.lazerBeatmapMetadata("/api/v2/beatmapsets/search"));
    try std.testing.expect(routing.lazerBeatmapMetadata("/api/v2/beatmapsets/456"));
    try std.testing.expect(!routing.lazerBeatmapMetadata("/api/v2/beatmapsets/456/download"));
    try std.testing.expect(!routing.lazerBeatmapMetadata("/d/456"));
    try std.testing.expectEqual(@as(u32, 6000), rate_limit.beatmap_metadata.limit);
    try std.testing.expectEqual(@as(u32, 60), rate_limit.download.limit);

    var limiter = rate_limit.Limiter.init(std.testing.allocator, std.testing.io);
    defer limiter.deinit();
    for (0..61) |_| try std.testing.expect((try limiter.checkAt("203.0.113.10", rate_limit.beatmap_metadata, 100)).allowed);
    for (0..60) |_| try std.testing.expect((try limiter.checkAt("203.0.113.10", rate_limit.download, 100)).allowed);
    try std.testing.expect(!(try limiter.checkAt("203.0.113.10", rate_limit.download, 100)).allowed);
}

test "lazer channel list and follow-up paths match the client contract" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try output.writer.writeByte('[');
    for (1..5) |channel_id| {
        if (channel_id != 1) try output.writer.writeByte(',');
        try lazer.writeChatChannel(&output.writer, @intCast(channel_id), null, null);
    }
    try output.writer.writeByte(']');
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 4), parsed.value.array.items.len);
    try std.testing.expectEqualStrings("#osu", parsed.value.array.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("#announce", parsed.value.array.items[1].object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 8), parsed.value.array.items[1].object.get("type").?.integer);
    try std.testing.expectEqualStrings("#lazer", parsed.value.array.items[3].object.get("name").?.string);

    const join = lazer.parseChannelUserPath("/api/v2/chat/channels/4/users/37").?;
    try std.testing.expectEqual(@as(i64, 4), join.channel_id);
    try std.testing.expectEqual(@as(i32, 37), join.user_id);
    try std.testing.expectEqual(@as(i64, 3), lazer.parseChannelMessagesPath("/api/v2/chat/channels/3/messages").?.channel_id);
    const read = lazer.parseChannelReadPath("/api/v2/chat/channels/3/mark-as-read/729").?;
    try std.testing.expectEqual(@as(i64, 3), read.channel_id);
    try std.testing.expectEqual(@as(i64, 729), read.message_id);
    try std.testing.expectEqual(@as(i64, 4), lazer.parseChannelPath("/api/v2/chat/channels/4").?);
    try std.testing.expectEqual(@as(i64, 1_000_037), lazer.privateChannelId(37).?);
    try std.testing.expectEqual(@as(i32, 37), lazer.privateChannelUser(1_000_037).?);
    try std.testing.expectEqual(@as(i64, 1_000_037), lazer.parseChannelPath("/api/v2/chat/channels/1000037").?);
    try std.testing.expectEqual(@as(i64, 1_000_037), lazer.parseChannelMessagesPath("/api/v2/chat/channels/1000037/messages").?.channel_id);
    try std.testing.expectEqual(@as(i64, 2_000_000_042), lazer.roomChannelId(42).?);
    try std.testing.expectEqual(@as(i64, 42), lazer.roomChannelRoom(2_000_000_042).?);
    try std.testing.expect(lazer.privateChannelUser(2_000_000_042) == null);
    try std.testing.expectEqual(@as(i64, 2_000_000_042), lazer.parseChannelPath("/api/v2/chat/channels/2000000042").?);
    try std.testing.expectEqual(@as(i64, 2_000_000_042), lazer.parseChannelMessagesPath("/api/v2/chat/channels/2000000042/messages").?.channel_id);
    var room_channel_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer room_channel_output.deinit();
    try lazer.writeRoomChatChannel(&room_channel_output.writer, 42, 700, 699);
    const parsed_room_channel = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, room_channel_output.written(), .{});
    defer parsed_room_channel.deinit();
    try std.testing.expectEqualStrings("#lazermp_42", parsed_room_channel.value.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 2), parsed_room_channel.value.object.get("type").?.integer);
    try std.testing.expectEqual(@as(i64, 700), parsed_room_channel.value.object.get("last_message_id").?.integer);
    try std.testing.expectEqual(@as(i64, 699), parsed_room_channel.value.object.get("last_read_id").?.integer);
    try std.testing.expectEqual(@as(i32, 4), lazer.directMessageOther("@dm:4:37", 37).?);
    try std.testing.expectEqual(@as(i32, 37), lazer.directMessageOther("@dm:4:37", 4).?);
    try std.testing.expect(lazer.directMessageOther("@dm:4:37", 9) == null);
    try std.testing.expectEqualStrings("#lazer", lazer.channelName(4).?);
    try std.testing.expectEqual(@as(i64, 1), lazer.channelId("#osu").?);
    try std.testing.expect(lazer.validMessageUuid("01234567-89ab-cdef-0123-456789abcdef"));
    try std.testing.expect(!lazer.validMessageUuid("0123456789abcdef0123456789abcdef"));
    try std.testing.expect(lazer.parseChannelUserPath("/api/v2/chat/channels/5/users/37") == null);
    try std.testing.expect(lazer.parseChannelUserPath("/api/v2/chat/channels/4/users/37/extra") == null);
    try std.testing.expect(lazer.parseChannelMessagesPath("/api/v2/chat/channels/0/messages") == null);
    try std.testing.expect(lazer.parseChannelReadPath("/api/v2/chat/channels/3/mark-as-read/0") == null);
    try std.testing.expect(lazer.parseChannelReadPath("/api/v2/chat/channels/9/mark-as-read/1") == null);
    try std.testing.expect(lazer.parseChannelPath("/api/v2/chat/channels/4/messages") == null);
    try std.testing.expectEqual(@as(i32, 12), lazer.parseFriendPath("/api/v2/friends/12").?);
    try std.testing.expectEqual(@as(i32, 13), lazer.parseBlockPath("/api/v2/blocks/13").?);
    try std.testing.expectEqual(@as(i32, 14), lazer.parseFavouritePath("/api/v2/beatmapsets/14/favourites").?);
    try std.testing.expect(lazer.parseFriendPath("/api/v2/friends/0") == null);
    try std.testing.expect(lazer.parseBlockPath("/api/v2/blocks/13/extra") == null);
    try std.testing.expect(lazer.parseFavouritePath("/api/v2/beatmapsets/nope/favourites") == null);

    const ids = try lazer.queryIds(std.testing.allocator, "/api/v2/users/lookup/?ids[]=3&ids%5B%5D=4&ids[]=3&ruleset_id=0", 50);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(i32, &.{ 3, 4 }, ids);
    try std.testing.expectError(error.InvalidId, lazer.queryIds(std.testing.allocator, "/api/v2/users?ids[]=nope", 50));
    try std.testing.expectError(error.MissingIds, lazer.queryIds(std.testing.allocator, "/api/v2/users?ruleset_id=0", 50));
    try std.testing.expectError(error.TooManyIds, lazer.queryIds(std.testing.allocator, "/api/v2/users?ids[]=1&ids[]=2", 1));
}

test "kai has an always-online lazer presence contract" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try lazer.writeSystemBotPresence(&output.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("online").?.bool);
    try std.testing.expectEqualStrings("bot", parsed.value.object.get("client").?.string);
    try std.testing.expectEqualStrings("kai", parsed.value.object.get("client_label").?.string);
    try std.testing.expectEqualStrings("online", parsed.value.object.get("activity").?.string);
}

test "lazer public chat persists actions and deduplicates client uuids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/lazer-chat.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("chat player", "chat@example.test", "0123456789abcdef0123456789abcdef");

    const uuid = "01234567-89ab-cdef-0123-456789abcdef";
    const first = try store.recordLazerPublicMessage(std.testing.allocator, user_id, "#osu", "hello from lazer", false, uuid);
    defer std.testing.allocator.free(first.json);
    try std.testing.expect(first.inserted);
    const parsed_first = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, first.json, .{});
    defer parsed_first.deinit();
    const first_id = parsed_first.value.object.get("message_id").?.integer;
    try std.testing.expectEqualStrings(uuid, parsed_first.value.object.get("uuid").?.string);
    try std.testing.expectEqualStrings("chat player", parsed_first.value.object.get("sender").?.object.get("username").?.string);

    const duplicate = try store.recordLazerPublicMessage(std.testing.allocator, user_id, "#osu", "hello from lazer", false, uuid);
    defer std.testing.allocator.free(duplicate.json);
    try std.testing.expect(!duplicate.inserted);
    try std.testing.expectError(error.ChatUuidConflict, store.recordLazerPublicMessage(std.testing.allocator, user_id, "#osu", "changed retry", false, uuid));

    const action_uuid = "fedcba98-7654-3210-fedc-ba9876543210";
    const action = try store.recordLazerPublicMessage(std.testing.allocator, user_id, "#lazer", "waves", true, action_uuid);
    defer std.testing.allocator.free(action.json);
    try std.testing.expect(action.inserted);
    try std.testing.expectError(error.ChannelReadOnly, store.recordLazerPublicMessage(std.testing.allocator, user_id, "#announce", "nope", false, "11111111-2222-3333-4444-555555555555"));

    const history = try store.lazerChatMessagesJson(std.testing.allocator, 1, 0, 50);
    defer std.testing.allocator.free(history);
    const parsed_history = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, history, .{});
    defer parsed_history.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_history.value.array.items.len);
    try std.testing.expectEqual(first_id, parsed_history.value.array.items[0].object.get("message_id").?.integer);

    const updates = try store.lazerChatMessagesJson(std.testing.allocator, null, first_id, 100);
    defer std.testing.allocator.free(updates);
    const parsed_updates = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, updates, .{});
    defer parsed_updates.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_updates.value.array.items.len);
    try std.testing.expect(parsed_updates.value.array.items[0].object.get("is_action").?.bool);

    const channels_before = try store.lazerChannelListJson(std.testing.allocator, user_id);
    defer std.testing.allocator.free(channels_before);
    const parsed_before = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, channels_before, .{});
    defer parsed_before.deinit();
    try std.testing.expectEqual(first_id, parsed_before.value.array.items[0].object.get("last_message_id").?.integer);
    try std.testing.expect(parsed_before.value.array.items[0].object.get("last_read_id").? == .null);
    const detail_before = try store.lazerChannelCursor(user_id, 1);
    try std.testing.expectEqual(first_id, detail_before.last_message_id.?);
    try std.testing.expectEqual(@as(?i64, null), detail_before.last_read_id);

    try store.markLazerChannelRead(user_id, 1, first_id);
    const channels_after = try store.lazerChannelListJson(std.testing.allocator, user_id);
    defer std.testing.allocator.free(channels_after);
    const parsed_after = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, channels_after, .{});
    defer parsed_after.deinit();
    try std.testing.expectEqual(first_id, parsed_after.value.array.items[0].object.get("last_read_id").?.integer);
    const detail_after = try store.lazerChannelCursor(user_id, 1);
    try std.testing.expectEqual(first_id, detail_after.last_read_id.?);
    const action_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, action.json, .{});
    defer action_parsed.deinit();
    const action_id = action_parsed.value.object.get("message_id").?.integer;
    try std.testing.expectError(error.ChatMessageNotFound, store.markLazerChannelRead(user_id, 1, action_id));
    try std.testing.expectError(error.ChatMessageNotFound, store.markLazerChannelRead(user_id, 1, 999_999));

    const second = try store.recordLazerPublicMessage(std.testing.allocator, user_id, "#osu", "new after read", false, "22222222-3333-4444-5555-666666666666");
    defer std.testing.allocator.free(second.json);
    const second_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, second.json, .{});
    defer second_parsed.deinit();
    const second_id = second_parsed.value.object.get("message_id").?.integer;
    const reconnect_unread = try store.lazerAllMessagesJson(std.testing.allocator, user_id, 0, 100);
    defer std.testing.allocator.free(reconnect_unread);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_unread, "new after read") != null);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_unread, "hello from lazer") == null);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_unread, "waves") != null);
    try store.markLazerChannelRead(user_id, 1, second_id);
    try store.markLazerChannelRead(user_id, 1, first_id);
    try store.markLazerChannelRead(user_id, 4, action_id);
    const monotonic = try store.lazerChannelCursor(user_id, 1);
    try std.testing.expectEqual(second_id, monotonic.last_read_id.?);
    const reconnect_clear = try store.lazerAllMessagesJson(std.testing.allocator, user_id, 0, 100);
    defer std.testing.allocator.free(reconnect_clear);
    try std.testing.expectEqualStrings("[]", reconnect_clear);
}

test "lazer multiplayer chat keeps room targets isolated while preserving the shared poll cursor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/lazer-room-chat.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    errdefer store.close();
    try store.migrate();
    const user_id = try store.register("room chatter", "room-chat@example.test", "0123456789abcdef0123456789abcdef");

    const room_one = try store.recordLazerRoomMessage(std.testing.allocator, user_id, 41, "room one only", false, "10000000-0000-0000-0000-000000000001");
    defer std.testing.allocator.free(room_one.json);
    const room_two = try store.recordLazerRoomMessage(std.testing.allocator, user_id, 42, "room two only", false, "10000000-0000-0000-0000-000000000002");
    defer std.testing.allocator.free(room_two.json);
    const public = try store.recordLazerPublicMessage(std.testing.allocator, user_id, "#lazer", "still public", false, "10000000-0000-0000-0000-000000000003");
    defer std.testing.allocator.free(public.json);
    const room_one_second = try store.recordLazerRoomMessage(std.testing.allocator, user_id, 41, "room one second", false, "10000000-0000-0000-0000-000000000004");
    defer std.testing.allocator.free(room_one_second.json);

    const room_one_history = try store.lazerRoomMessagesJson(std.testing.allocator, 41, 0, 50);
    defer std.testing.allocator.free(room_one_history);
    try std.testing.expect(std.mem.indexOf(u8, room_one_history, "room one only") != null);
    try std.testing.expect(std.mem.indexOf(u8, room_one_history, "room two only") == null);
    try std.testing.expect(std.mem.indexOf(u8, room_one_history, "still public") == null);

    const room_one_feed = try store.lazerAllMessagesForRoomJson(std.testing.allocator, user_id, 41, 0, 100);
    defer std.testing.allocator.free(room_one_feed);
    try std.testing.expect(std.mem.indexOf(u8, room_one_feed, "room one only") != null);
    try std.testing.expect(std.mem.indexOf(u8, room_one_feed, "room two only") == null);
    try std.testing.expect(std.mem.indexOf(u8, room_one_feed, "still public") != null);

    const public_feed = try store.lazerAllMessagesJson(std.testing.allocator, user_id, 0, 100);
    defer std.testing.allocator.free(public_feed);
    try std.testing.expect(std.mem.indexOf(u8, public_feed, "room one only") == null);
    try std.testing.expect(std.mem.indexOf(u8, public_feed, "room two only") == null);
    const cursor = try store.lazerRoomChannelCursor(user_id, 41);
    const parsed_room_one = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, room_one.json, .{});
    defer parsed_room_one.deinit();
    const room_one_id = parsed_room_one.value.object.get("message_id").?.integer;
    const parsed_room_one_second = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, room_one_second.json, .{});
    defer parsed_room_one_second.deinit();
    const room_one_second_id = parsed_room_one_second.value.object.get("message_id").?.integer;
    try std.testing.expectEqual(room_one_second_id, cursor.last_message_id.?);
    try std.testing.expectEqual(@as(?i64, null), cursor.last_read_id);

    try store.markLazerRoomChannelRead(user_id, 41, room_one_id);
    try store.markLazerRoomChannelRead(user_id, 41, room_one_id);
    try std.testing.expectEqual(room_one_id, (try store.lazerRoomChannelCursor(user_id, 41)).last_read_id.?);
    try store.markLazerRoomChannelRead(user_id, 41, room_one_second_id);
    try store.markLazerRoomChannelRead(user_id, 41, room_one_id);
    try std.testing.expectEqual(room_one_second_id, (try store.lazerRoomChannelCursor(user_id, 41)).last_read_id.?);
    const parsed_room_two = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, room_two.json, .{});
    defer parsed_room_two.deinit();
    try std.testing.expectError(error.ChatMessageNotFound, store.markLazerRoomChannelRead(user_id, 41, parsed_room_two.value.object.get("message_id").?.integer));

    const duplicate = try store.recordLazerRoomMessage(std.testing.allocator, user_id, 41, "room one only", false, "10000000-0000-0000-0000-000000000001");
    defer std.testing.allocator.free(duplicate.json);
    try std.testing.expect(!duplicate.inserted);
    try std.testing.expectError(error.ChatUuidConflict, store.recordLazerRoomMessage(std.testing.allocator, user_id, 42, "cross-room retry", false, "10000000-0000-0000-0000-000000000001"));

    store.close();
    var reopened = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();
    try reopened.migrate();
    const reconnect_feed = try reopened.lazerAllMessagesForRoomJson(std.testing.allocator, user_id, 41, 0, 100);
    defer std.testing.allocator.free(reconnect_feed);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_feed, "room one only") == null);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_feed, "room one second") == null);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_feed, "still public") != null);
    try std.testing.expectEqual(room_one_second_id, (try reopened.lazerRoomChannelCursor(user_id, 41)).last_read_id.?);

    const room_one_third = try reopened.recordLazerRoomMessage(std.testing.allocator, user_id, 41, "room one third", false, "10000000-0000-0000-0000-000000000005");
    defer std.testing.allocator.free(room_one_third.json);
    const after_reconnect = try reopened.lazerAllMessagesForRoomJson(std.testing.allocator, user_id, 41, 0, 100);
    defer std.testing.allocator.free(after_reconnect);
    try std.testing.expect(std.mem.indexOf(u8, after_reconnect, "room one only") == null);
    try std.testing.expect(std.mem.indexOf(u8, after_reconnect, "room one second") == null);
    try std.testing.expect(std.mem.indexOf(u8, after_reconnect, "room one third") != null);
}

test "lazer private messages share one cursor with stable offline mail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/lazer-private-chat.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const first_id = try store.register("first chat", "first-chat@example.test", "0123456789abcdef0123456789abcdef");
    const second_id = try store.register("second chat", "second-chat@example.test", "fedcba9876543210fedcba9876543210");
    const third_id = try store.register("third chat", "third-chat@example.test", "11111111111111111111111111111111");

    const uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    const first = try store.recordLazerDirectMessage(std.testing.allocator, first_id, second_id, "private hello", false, uuid);
    defer std.testing.allocator.free(first.json);
    try std.testing.expect(first.inserted);
    const duplicate = try store.recordLazerDirectMessage(std.testing.allocator, first_id, second_id, "private hello", false, uuid);
    defer std.testing.allocator.free(duplicate.json);
    try std.testing.expect(!duplicate.inserted);
    try std.testing.expectError(error.ChatUuidConflict, store.recordLazerDirectMessage(std.testing.allocator, first_id, second_id, "changed retry", false, uuid));

    const history = try store.lazerDirectMessagesJson(std.testing.allocator, second_id, first_id, 0, 50);
    defer std.testing.allocator.free(history);
    const parsed_history = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, history, .{});
    defer parsed_history.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_history.value.array.items.len);
    try std.testing.expectEqual(lazer.privateChannelId(first_id).?, parsed_history.value.array.items[0].object.get("channel_id").?.integer);
    try std.testing.expectEqualStrings("private hello", parsed_history.value.array.items[0].object.get("content").?.string);
    const first_message_id = parsed_history.value.array.items[0].object.get("message_id").?.integer;

    const updates = try store.lazerAllMessagesJson(std.testing.allocator, second_id, 0, 100);
    defer std.testing.allocator.free(updates);
    try std.testing.expect(std.mem.indexOf(u8, updates, "private hello") != null);
    const unrelated = try store.lazerAllMessagesJson(std.testing.allocator, third_id, 0, 100);
    defer std.testing.allocator.free(unrelated);
    try std.testing.expect(std.mem.indexOf(u8, unrelated, "private hello") == null);

    const unread = try store.unreadDirectMessages(std.testing.allocator, second_id);
    defer {
        for (unread) |*message| message.deinit(std.testing.allocator);
        std.testing.allocator.free(unread);
    }
    try std.testing.expectEqual(@as(usize, 1), unread.len);
    try std.testing.expectEqualStrings("private hello", unread[0].message);
    const cursor_before = try store.lazerDirectMessageCursor(second_id, first_id);
    try std.testing.expect(cursor_before.last_message_id != null);
    try std.testing.expectEqual(@as(?i64, null), cursor_before.last_read_id);
    try store.markLazerDirectMessageRead(second_id, first_id, first_message_id);
    const cursor_after = try store.lazerDirectMessageCursor(second_id, first_id);
    try std.testing.expectEqual(cursor_after.last_message_id, cursor_after.last_read_id);
    const reconnect_clear = try store.lazerAllMessagesJson(std.testing.allocator, second_id, 0, 100);
    defer std.testing.allocator.free(reconnect_clear);
    try std.testing.expectEqualStrings("[]", reconnect_clear);

    const second = try store.recordLazerDirectMessage(std.testing.allocator, first_id, second_id, "new private hello", false, "cccccccc-dddd-eeee-ffff-000000000000");
    defer std.testing.allocator.free(second.json);
    const second_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, second.json, .{});
    defer second_parsed.deinit();
    const second_message_id = second_parsed.value.object.get("message_id").?.integer;
    const reconnect_unread = try store.lazerAllMessagesJson(std.testing.allocator, second_id, 0, 100);
    defer std.testing.allocator.free(reconnect_unread);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_unread, "new private hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_unread, "\"content\":\"private hello\"") == null);
    try store.markLazerDirectMessageRead(second_id, first_id, second_message_id);
    try store.markLazerDirectMessageRead(second_id, first_id, first_message_id);
    const reconnect_cleared_again = try store.lazerAllMessagesJson(std.testing.allocator, second_id, 0, 100);
    defer std.testing.allocator.free(reconnect_cleared_again);
    try std.testing.expectEqualStrings("[]", reconnect_cleared_again);

    _ = try store.storeDirectMessage(second_id, first_id, "stable hello");
    const stable_update = try store.lazerAllMessagesJson(std.testing.allocator, first_id, 0, 100);
    defer std.testing.allocator.free(stable_update);
    try std.testing.expect(std.mem.indexOf(u8, stable_update, "stable hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, stable_update, "private hello") == null);

    const first_threads = try store.directMessageThreadsJson(std.testing.allocator, first_id, 50);
    defer std.testing.allocator.free(first_threads);
    const parsed_threads = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, first_threads, .{});
    defer parsed_threads.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_threads.value.array.items.len);
    const thread = parsed_threads.value.array.items[0].object;
    try std.testing.expectEqual(@as(i64, second_id), thread.get("id").?.integer);
    try std.testing.expectEqualStrings("stable hello", thread.get("last_message").?.string);
    try std.testing.expectEqual(@as(i64, 1), thread.get("unread").?.integer);

    try std.testing.expect(try store.addBlock(second_id, first_id));
    try std.testing.expect(!try store.directMessageAllowed(first_id, second_id));
    try std.testing.expectError(error.DirectMessageBlocked, store.recordLazerDirectMessage(std.testing.allocator, first_id, second_id, "blocked lazer", false, "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"));
    try std.testing.expectError(error.DirectMessageBlocked, store.storeDirectMessage(second_id, first_id, "blocked stable"));
}

test "lazer registration fields are form decoded" {
    const body = "user%5Busername%5D=zigcho+lazer&user%5Buser_email%5D=qa%2Bzigcho%40example.invalid&user%5Bpassword%5D=long%26safe%3Dpassword";
    const name = (try form_urlencoded.field(std.testing.allocator, body, &.{ "name", "user[username]" })).?;
    defer std.testing.allocator.free(name);
    const email = (try form_urlencoded.field(std.testing.allocator, body, &.{ "email", "user[user_email]" })).?;
    defer std.testing.allocator.free(email);
    const password = (try form_urlencoded.field(std.testing.allocator, body, &.{ "password_md5", "user[password]" })).?;
    defer std.testing.allocator.free(password);
    try std.testing.expectEqualStrings("zigcho lazer", name);
    try std.testing.expectEqualStrings("qa+zigcho@example.invalid", email);
    try std.testing.expectEqualStrings("long&safe=password", password);
}

test "stable registration validates before creating and returns bancho form errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/stable-registration.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();

    const checked = try registration.stableRequest(&store, "new_player", "new@example.test", "good-password", "1");
    try std.testing.expect(checked == .ok);
    try std.testing.expectEqual(@as(i64, 0), (try store.serverCounts()).users);

    const created = try registration.stableRequest(&store, "new_player", "new@example.test", "good-password", "0");
    try std.testing.expect(created == .ok);
    try std.testing.expectEqual(@as(i64, 1), (try store.serverCounts()).users);

    const duplicate = try registration.stableRequest(&store, "new player", "new@example.test", "good-password", "1");
    try std.testing.expect(duplicate == .validation_failed);
    var error_buffer: [768]u8 = undefined;
    const json = try registration.writeStableErrors(&error_buffer, duplicate.validation_failed);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"username\":[\"Username already taken") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"user_email\":[\"Email already taken") != null);
    try std.testing.expectError(error.InvalidCheck, registration.stableRequest(&store, "other_player", "other@example.test", "good-password", "no"));
}

test "official lazer multipart fields are accepted" {
    const boundary = "-----------------------------28947758029299";
    const body = "--" ++ boundary ++ "\r\n" ++
        "Content-Disposition: form-data; name=\"username\"\r\n\r\n" ++
        "zigcho_lazer_qa\r\n" ++
        "--" ++ boundary ++ "\r\n" ++
        "Content-Disposition: form-data; name=\"password\"\r\n\r\n" ++
        "raw-lazer-password\r\n" ++
        "--" ++ boundary ++ "--\r\n";
    const content_type = "multipart/form-data; boundary=" ++ boundary;
    const name = (try form_urlencoded.requestField(std.testing.allocator, body, content_type, &.{"username"})).?;
    defer std.testing.allocator.free(name);
    const password = (try form_urlencoded.requestField(std.testing.allocator, body, content_type, &.{"password"})).?;
    defer std.testing.allocator.free(password);
    try std.testing.expectEqualStrings("zigcho_lazer_qa", name);
    try std.testing.expectEqualStrings("raw-lazer-password", password);
}

test "stable md5 and raw lazer passwords normalize to the same secret" {
    const raw = try form_urlencoded.credentialMd5("password");
    const stable = try form_urlencoded.credentialMd5("5F4DCC3B5AA765D61D8327DEB882CF99");
    try std.testing.expectEqualStrings("5f4dcc3b5aa765d61d8327deb882cf99", &raw);
    try std.testing.expectEqual(raw, stable);
    const raw_32 = try form_urlencoded.credentialMd5("not-an-md5-but-exactly-32-chars!");
    try std.testing.expect(!std.mem.eql(u8, "not-an-md5-but-exactly-32-chars!", &raw_32));
    try std.testing.expectError(error.InvalidCredential, form_urlencoded.credentialMd5("short"));
}

test "packet framing round trip" {
    var w = protocol.Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.packetString(.notification, "hello");
    try std.testing.expectEqual(@as(u16, 24), std.mem.readInt(u16, w.bytes()[0..2], .little));
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, w.bytes()[3..7], .little));
    var p: protocol.PayloadReader = .{ .data = w.bytes()[7..] };
    try std.testing.expectEqualStrings("hello", try p.string());
}

test "stable multiplayer match wire format round trips and hides lobby passwords" {
    var match = try multiplayer.Match.init(std.testing.allocator, 7, multiplayerFixtureData(42, "room-secret"), 42);
    defer match.deinit();
    match.slots[3].user_id = 84;
    match.slots[3].status = @intFromEnum(multiplayer.SlotStatus.ready);
    match.slots[3].team = @intFromEnum(multiplayer.Team.blue);

    var private = protocol.Writer.init(std.testing.allocator);
    defer private.deinit();
    try multiplayer.writePacket(&private, .match_join_success, &match, true);
    var private_reader: protocol.Reader = .{ .data = private.bytes() };
    const private_packet = (try private_reader.next()).?;
    try std.testing.expectEqual(protocol.ServerPacket.match_join_success, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum(private_packet.id))));
    const private_match = try multiplayer.readMatch(private_packet.payload);
    try std.testing.expectEqualStrings("room-secret", private_match.password);
    try std.testing.expectEqual(@as(i32, 42), private_match.host_id);
    try std.testing.expectEqual(@as(usize, private_packet.payload.len), private_packet.payload.len);

    var public = protocol.Writer.init(std.testing.allocator);
    defer public.deinit();
    try multiplayer.writePacket(&public, .new_match, &match, false);
    var public_reader: protocol.Reader = .{ .data = public.bytes() };
    const public_packet = (try public_reader.next()).?;
    const public_match = try multiplayer.readMatch(public_packet.payload);
    try std.testing.expectEqualStrings("", public_match.password);
    try std.testing.expectError(error.TruncatedPayload, multiplayer.readMatch(public_packet.payload[0 .. public_packet.payload.len - 1]));
}

test "stable multiplayer score frames require the exact v1 or v2 wire size" {
    var score_frame = [_]u8{0} ** 45;
    score_frame[4] = 99;
    score_frame[25] = 1;
    try std.testing.expect(multiplayer.validScoreFrame(score_frame[0..29]));
    try std.testing.expect(!multiplayer.validScoreFrame(score_frame[0..28]));
    try std.testing.expect(!multiplayer.validScoreFrame(score_frame[0..30]));
    score_frame[28] = 1;
    try std.testing.expect(!multiplayer.validScoreFrame(score_frame[0..29]));
    try std.testing.expect(multiplayer.validScoreFrame(&score_frame));
    score_frame[25] = 2;
    try std.testing.expect(!multiplayer.validScoreFrame(&score_frame));
    score_frame[25] = 1;

    var writer = protocol.Writer.init(std.testing.allocator);
    defer writer.deinit();
    try multiplayer.writeScoreFramePacket(&writer, &score_frame, 3);
    var reader: protocol.Reader = .{ .data = writer.bytes() };
    const packet = (try reader.next()).?;
    try std.testing.expectEqual(protocol.ServerPacket.match_score_update, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum(packet.id))));
    try std.testing.expectEqual(@as(usize, 45), packet.payload.len);
    try std.testing.expectEqual(@as(u8, 3), packet.payload[4]);
    try std.testing.expectEqual(@as(u8, 99), score_frame[4]);
    try std.testing.expect((try reader.next()) == null);
}

test "stable multiplayer owned match data survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, multiplayerAllocationRun, .{{}});
}

test "stable multiplayer room lifecycle keeps lobby slot and host state coherent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/stable-multiplayer.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();

    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const host = try sessions.create(try testSessionUser(std.testing.allocator, 10, "host"), 0, 0, 0);
    const guest = try sessions.create(try testSessionUser(std.testing.allocator, 11, "guest"), 0, 0, 0);
    const observer = try sessions.create(try testSessionUser(std.testing.allocator, 12, "observer"), 0, 0, 0);

    const join_lobby = try clientEmptyPacket(std.testing.allocator, .join_lobby);
    defer std.testing.allocator.free(join_lobby);
    const host_lobby = try bancho.poll(std.testing.allocator, &store, &sessions, host, join_lobby);
    defer std.testing.allocator.free(host_lobby);
    try expectPacketIds(host_lobby, &.{ .channel_join_success, .channel_info });
    try expectStringPacket(host_lobby, .channel_join_success, "#lobby");
    const guest_lobby = try bancho.poll(std.testing.allocator, &store, &sessions, guest, join_lobby);
    defer std.testing.allocator.free(guest_lobby);
    try expectPacketIds(guest_lobby, &.{ .channel_join_success, .channel_info });
    try expectStringPacket(guest_lobby, .channel_info, "#lobby");
    const observer_lobby = try bancho.poll(std.testing.allocator, &store, &sessions, observer, join_lobby);
    defer std.testing.allocator.free(observer_lobby);
    try expectPacketIds(observer_lobby, &.{ .channel_join_success, .channel_info });
    try std.testing.expect(host.in_lobby and guest.in_lobby and observer.in_lobby);
    try std.testing.expect(host.joined_lobby_channel and guest.joined_lobby_channel and observer.joined_lobby_channel);
    try drainSession(std.testing.allocator, &store, &sessions, host);
    try drainSession(std.testing.allocator, &store, &sessions, guest);
    try drainSession(std.testing.allocator, &store, &sessions, observer);

    const create = try clientMatchPacket(std.testing.allocator, .create_match, host.user.id, "room-secret");
    defer std.testing.allocator.free(create);
    const created = try bancho.poll(std.testing.allocator, &store, &sessions, host, create);
    defer std.testing.allocator.free(created);
    try expectPacketIds(created, &.{ .channel_join_success, .channel_info, .channel_kick, .match_join_success });
    try expectStringPacket(created, .channel_join_success, "#multiplayer");
    try expectStringPacket(created, .channel_kick, "#lobby");
    const match = sessions.matchById(0).?;
    try std.testing.expectEqual(@as(?u16, 0), host.match_id);
    try std.testing.expect(!host.in_lobby);
    try std.testing.expect(!host.joined_lobby_channel);
    try std.testing.expect(host.joined("#multiplayer"));
    try std.testing.expectEqual(@as(usize, 1), match.occupied());

    const empty = try clientEmptyPacket(std.testing.allocator, .ping);
    defer std.testing.allocator.free(empty);
    const guest_discovery = try bancho.poll(std.testing.allocator, &store, &sessions, guest, empty);
    defer std.testing.allocator.free(guest_discovery);
    var discovery_reader: protocol.Reader = .{ .data = guest_discovery };
    try std.testing.expectEqual(protocol.ServerPacket.channel_info, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try discovery_reader.next()).?.id))));
    try std.testing.expectEqual(protocol.ServerPacket.new_match, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try discovery_reader.next()).?.id))));
    try std.testing.expectEqual(protocol.ServerPacket.update_match, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try discovery_reader.next()).?.id))));

    const wrong_join = try clientJoinMatchPacket(std.testing.allocator, 0, "wrong");
    defer std.testing.allocator.free(wrong_join);
    const denied = try bancho.poll(std.testing.allocator, &store, &sessions, guest, wrong_join);
    defer std.testing.allocator.free(denied);
    var denied_reader: protocol.Reader = .{ .data = denied };
    try std.testing.expectEqual(protocol.ServerPacket.match_join_fail, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try denied_reader.next()).?.id))));
    try std.testing.expectEqual(@as(?u16, null), guest.match_id);

    const right_join = try clientJoinMatchPacket(std.testing.allocator, 0, "room-secret");
    defer std.testing.allocator.free(right_join);
    const joined = try bancho.poll(std.testing.allocator, &store, &sessions, guest, right_join);
    defer std.testing.allocator.free(joined);
    try expectPacketIds(joined, &.{ .channel_join_success, .channel_info, .channel_kick, .match_join_success });
    try expectStringPacket(joined, .channel_join_success, "#multiplayer");
    try expectStringPacket(joined, .channel_kick, "#lobby");
    try std.testing.expectEqual(@as(usize, 2), match.occupied());
    try std.testing.expectEqual(@as(?u16, 0), guest.match_id);
    try std.testing.expect(!guest.in_lobby and !guest.joined_lobby_channel);
    try std.testing.expect(guest.joined("#multiplayer"));

    const clear_guest = try bancho.poll(std.testing.allocator, &store, &sessions, guest, empty);
    defer std.testing.allocator.free(clear_guest);
    const clear_observer = try bancho.poll(std.testing.allocator, &store, &sessions, observer, empty);
    defer std.testing.allocator.free(clear_observer);
    const room_message = try clientMessagePacket(std.testing.allocator, .send_public_message, host.user.name, "stable room chat", "#multiplayer", host.user.id);
    defer std.testing.allocator.free(room_message);
    const host_chat = try bancho.poll(std.testing.allocator, &store, &sessions, host, room_message);
    defer std.testing.allocator.free(host_chat);
    const guest_chat = try bancho.poll(std.testing.allocator, &store, &sessions, guest, empty);
    defer std.testing.allocator.free(guest_chat);
    var guest_chat_reader: protocol.Reader = .{ .data = guest_chat };
    const guest_chat_packet = (try guest_chat_reader.next()).?;
    try std.testing.expectEqual(protocol.ServerPacket.send_message, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum(guest_chat_packet.id))));
    var guest_chat_payload: protocol.PayloadReader = .{ .data = guest_chat_packet.payload };
    try std.testing.expectEqualStrings("host", try guest_chat_payload.string());
    try std.testing.expectEqualStrings("stable room chat", try guest_chat_payload.string());
    try std.testing.expectEqualStrings("#multiplayer", try guest_chat_payload.string());

    var slot_payload = protocol.Writer.init(std.testing.allocator);
    defer slot_payload.deinit();
    try slot_payload.int(i32, 3);
    const move_slot = try clientPayloadPacket(std.testing.allocator, .change_slot, slot_payload.bytes());
    defer std.testing.allocator.free(move_slot);
    const moved = try bancho.poll(std.testing.allocator, &store, &sessions, guest, move_slot);
    defer std.testing.allocator.free(moved);
    try std.testing.expectEqual(@as(?usize, 3), match.slotIndexByUser(guest.user.id));

    const ready_packet = try clientEmptyPacket(std.testing.allocator, .match_ready);
    defer std.testing.allocator.free(ready_packet);
    const ready = try bancho.poll(std.testing.allocator, &store, &sessions, guest, ready_packet);
    defer std.testing.allocator.free(ready);
    try std.testing.expectEqual(@as(u8, @intFromEnum(multiplayer.SlotStatus.ready)), match.slotByUser(guest.user.id).?.status);

    var host_mods_payload = protocol.Writer.init(std.testing.allocator);
    defer host_mods_payload.deinit();
    try host_mods_payload.int(i32, (1 << 6) | (1 << 3));
    const host_mods_packet = try clientPayloadPacket(std.testing.allocator, .match_change_mods, host_mods_payload.bytes());
    defer std.testing.allocator.free(host_mods_packet);
    const host_mods_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, host_mods_packet);
    defer std.testing.allocator.free(host_mods_result);
    try std.testing.expectEqual(@as(i32, (1 << 6) | (1 << 3)), match.mods);

    var free_settings = multiplayerFixtureData(host.user.id, "room-secret");
    free_settings.name = "stable teams room";
    free_settings.freemods = true;
    free_settings.team_type = 2;
    const free_settings_packet = try clientMatchDataPacket(std.testing.allocator, .match_change_settings, free_settings);
    defer std.testing.allocator.free(free_settings_packet);
    const free_settings_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, free_settings_packet);
    defer std.testing.allocator.free(free_settings_result);
    try std.testing.expect(match.freemods);
    try std.testing.expectEqualStrings("stable teams room", match.name);
    try std.testing.expectEqual(@as(i32, 1 << 6), match.mods);
    try std.testing.expectEqual(@as(i32, 1 << 3), match.slotByUser(guest.user.id).?.mods);
    try std.testing.expectEqual(@as(u8, @intFromEnum(multiplayer.Team.red)), match.slotByUser(guest.user.id).?.team);
    try std.testing.expectEqual(@as(u8, @intFromEnum(multiplayer.SlotStatus.ready)), match.slotByUser(guest.user.id).?.status);
    var changing_map = free_settings;
    changing_map.map_id = -1;
    changing_map.map_name = "";
    changing_map.map_md5 = "";
    const changing_map_packet = try clientMatchDataPacket(std.testing.allocator, .match_change_settings, changing_map);
    defer std.testing.allocator.free(changing_map_packet);
    const changing_map_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, changing_map_packet);
    defer std.testing.allocator.free(changing_map_result);
    try std.testing.expectEqual(@as(i32, -1), match.map_id);
    try std.testing.expectEqual(@as(u8, @intFromEnum(multiplayer.SlotStatus.not_ready)), match.slotByUser(guest.user.id).?.status);
    const selected_map_packet = try clientMatchDataPacket(std.testing.allocator, .match_change_settings, free_settings);
    defer std.testing.allocator.free(selected_map_packet);
    const selected_map_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, selected_map_packet);
    defer std.testing.allocator.free(selected_map_result);
    try std.testing.expectEqual(@as(i32, 900000001), match.map_id);
    var mods_payload = protocol.Writer.init(std.testing.allocator);
    defer mods_payload.deinit();
    try mods_payload.int(i32, (1 << 3) | (1 << 4));
    const guest_mods_packet = try clientPayloadPacket(std.testing.allocator, .match_change_mods, mods_payload.bytes());
    defer std.testing.allocator.free(guest_mods_packet);
    const guest_mods_result = try bancho.poll(std.testing.allocator, &store, &sessions, guest, guest_mods_packet);
    defer std.testing.allocator.free(guest_mods_result);
    try std.testing.expectEqual(@as(i32, (1 << 3) | (1 << 4)), match.slotByUser(guest.user.id).?.mods);
    const change_team_packet = try clientEmptyPacket(std.testing.allocator, .match_change_team);
    defer std.testing.allocator.free(change_team_packet);
    const changed_team = try bancho.poll(std.testing.allocator, &store, &sessions, guest, change_team_packet);
    defer std.testing.allocator.free(changed_team);
    try std.testing.expectEqual(@as(u8, @intFromEnum(multiplayer.Team.blue)), match.slotByUser(guest.user.id).?.team);

    var password_settings = free_settings;
    password_settings.password = "new-secret";
    const password_packet = try clientMatchDataPacket(std.testing.allocator, .match_change_password, password_settings);
    defer std.testing.allocator.free(password_packet);
    const password_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, password_packet);
    defer std.testing.allocator.free(password_result);
    try std.testing.expectEqualStrings("new-secret", match.password);

    const lock_slot = try clientPayloadPacket(std.testing.allocator, .match_lock, slot_payload.bytes());
    defer std.testing.allocator.free(lock_slot);
    const locked = try bancho.poll(std.testing.allocator, &store, &sessions, host, lock_slot);
    defer std.testing.allocator.free(locked);
    try std.testing.expectEqual(@as(?u16, null), guest.match_id);
    try std.testing.expect(!guest.joined("#multiplayer"));
    try std.testing.expectEqual(@as(u8, @intFromEnum(multiplayer.SlotStatus.locked)), match.slots[3].status);
    const unlocked = try bancho.poll(std.testing.allocator, &store, &sessions, host, lock_slot);
    defer std.testing.allocator.free(unlocked);
    try std.testing.expectEqual(@as(u8, @intFromEnum(multiplayer.SlotStatus.open)), match.slots[3].status);
    const guest_kicked = try bancho.poll(std.testing.allocator, &store, &sessions, guest, "");
    defer std.testing.allocator.free(guest_kicked);
    try expectStringPacket(guest_kicked, .channel_kick, "#multiplayer");

    const rejoin = try clientJoinMatchPacket(std.testing.allocator, 0, "new-secret");
    defer std.testing.allocator.free(rejoin);
    const rejoined = try bancho.poll(std.testing.allocator, &store, &sessions, guest, rejoin);
    defer std.testing.allocator.free(rejoined);
    try std.testing.expectEqual(@as(?u16, 0), guest.match_id);
    try std.testing.expectEqual(@as(usize, 2), match.occupied());
    var transfer_payload = protocol.Writer.init(std.testing.allocator);
    defer transfer_payload.deinit();
    try transfer_payload.int(i32, @intCast(match.slotIndexByUser(guest.user.id).?));
    const transfer_to_guest = try clientPayloadPacket(std.testing.allocator, .match_transfer_host, transfer_payload.bytes());
    defer std.testing.allocator.free(transfer_to_guest);
    const transferred_to_guest = try bancho.poll(std.testing.allocator, &store, &sessions, host, transfer_to_guest);
    defer std.testing.allocator.free(transferred_to_guest);
    try std.testing.expectEqual(guest.user.id, match.host_id);
    transfer_payload.list.clearRetainingCapacity();
    try transfer_payload.int(i32, @intCast(match.slotIndexByUser(host.user.id).?));
    const transfer_to_host = try clientPayloadPacket(std.testing.allocator, .match_transfer_host, transfer_payload.bytes());
    defer std.testing.allocator.free(transfer_to_host);
    const transferred_to_host = try bancho.poll(std.testing.allocator, &store, &sessions, guest, transfer_to_host);
    defer std.testing.allocator.free(transferred_to_host);
    try std.testing.expectEqual(host.user.id, match.host_id);
    const clear_guest_again = try bancho.poll(std.testing.allocator, &store, &sessions, guest, empty);
    defer std.testing.allocator.free(clear_guest_again);
    const clear_observer_before_part = try bancho.poll(std.testing.allocator, &store, &sessions, observer, empty);
    defer std.testing.allocator.free(clear_observer_before_part);
    const host_part_packet = try clientEmptyPacket(std.testing.allocator, .part_match);
    defer std.testing.allocator.free(host_part_packet);
    const host_part = try bancho.poll(std.testing.allocator, &store, &sessions, host, host_part_packet);
    defer std.testing.allocator.free(host_part);
    try std.testing.expectEqual(@as(?u16, null), host.match_id);
    try std.testing.expect(!host.joined("#multiplayer"));
    try expectStringPacket(host_part, .channel_kick, "#multiplayer");
    try std.testing.expectEqual(guest.user.id, match.host_id);

    const transferred = try bancho.poll(std.testing.allocator, &store, &sessions, guest, empty);
    defer std.testing.allocator.free(transferred);
    try expectPacket(transferred, .match_transfer_host);
    try expectPacket(transferred, .update_match);

    const clear_observer_again = try bancho.poll(std.testing.allocator, &store, &sessions, observer, empty);
    defer std.testing.allocator.free(clear_observer_again);
    const guest_part = try bancho.poll(std.testing.allocator, &store, &sessions, guest, host_part_packet);
    defer std.testing.allocator.free(guest_part);
    try std.testing.expect(sessions.matchById(0) == null);
    try std.testing.expect(!guest.joined("#multiplayer"));
    try expectStringPacket(guest_part, .channel_kick, "#multiplayer");
    const disposed = try bancho.poll(std.testing.allocator, &store, &sessions, observer, empty);
    defer std.testing.allocator.free(disposed);
    var disposed_reader: protocol.Reader = .{ .data = disposed };
    try std.testing.expectEqual(protocol.ServerPacket.dispose_match, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try disposed_reader.next()).?.id))));
}

test "stable multiplayer alias keeps chat inside its bound room" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/stable-match-channel-scope.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();

    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const first_host = try sessions.create(try testSessionUser(std.testing.allocator, 80, "first_host"), 0, 0, 0);
    const first_guest = try sessions.create(try testSessionUser(std.testing.allocator, 81, "first_guest"), 0, 0, 0);
    const second_host = try sessions.create(try testSessionUser(std.testing.allocator, 82, "second_host"), 0, 0, 0);
    const second_guest = try sessions.create(try testSessionUser(std.testing.allocator, 83, "second_guest"), 0, 0, 0);

    const first_create = try clientMatchPacket(std.testing.allocator, .create_match, first_host.user.id, "first-secret");
    defer std.testing.allocator.free(first_create);
    const first_created = try bancho.poll(std.testing.allocator, &store, &sessions, first_host, first_create);
    defer std.testing.allocator.free(first_created);
    try expectStringPacket(first_created, .channel_join_success, "#multiplayer");
    const first_join = try clientJoinMatchPacket(std.testing.allocator, 0, "first-secret");
    defer std.testing.allocator.free(first_join);
    const first_joined = try bancho.poll(std.testing.allocator, &store, &sessions, first_guest, first_join);
    defer std.testing.allocator.free(first_joined);

    const second_create = try clientMatchPacket(std.testing.allocator, .create_match, second_host.user.id, "second-secret");
    defer std.testing.allocator.free(second_create);
    const second_created = try bancho.poll(std.testing.allocator, &store, &sessions, second_host, second_create);
    defer std.testing.allocator.free(second_created);
    try std.testing.expectEqual(@as(?u16, 1), second_host.match_id);
    const second_join = try clientJoinMatchPacket(std.testing.allocator, 1, "second-secret");
    defer std.testing.allocator.free(second_join);
    const second_joined = try bancho.poll(std.testing.allocator, &store, &sessions, second_guest, second_join);
    defer std.testing.allocator.free(second_joined);

    try drainSession(std.testing.allocator, &store, &sessions, first_host);
    try drainSession(std.testing.allocator, &store, &sessions, first_guest);
    try drainSession(std.testing.allocator, &store, &sessions, second_host);
    try drainSession(std.testing.allocator, &store, &sessions, second_guest);

    const message = try clientMessagePacket(std.testing.allocator, .send_public_message, first_host.user.name, "only room zero", "#multiplayer", first_host.user.id);
    defer std.testing.allocator.free(message);
    const sent = try bancho.poll(std.testing.allocator, &store, &sessions, first_host, message);
    defer std.testing.allocator.free(sent);
    const first_delivery = try bancho.poll(std.testing.allocator, &store, &sessions, first_guest, "");
    defer std.testing.allocator.free(first_delivery);
    try expectStringPacket(first_delivery, .send_message, first_host.user.name);
    const second_host_delivery = try bancho.poll(std.testing.allocator, &store, &sessions, second_host, "");
    defer std.testing.allocator.free(second_host_delivery);
    const second_guest_delivery = try bancho.poll(std.testing.allocator, &store, &sessions, second_guest, "");
    defer std.testing.allocator.free(second_guest_delivery);
    try std.testing.expectEqual(@as(usize, 0), second_host_delivery.len);
    try std.testing.expectEqual(@as(usize, 0), second_guest_delivery.len);

    const internal_name = try clientMessagePacket(std.testing.allocator, .send_public_message, first_host.user.name, "hidden name", "#multi_0", first_host.user.id);
    defer std.testing.allocator.free(internal_name);
    const internal_result = try bancho.poll(std.testing.allocator, &store, &sessions, first_host, internal_name);
    defer std.testing.allocator.free(internal_result);
    const internal_delivery = try bancho.poll(std.testing.allocator, &store, &sessions, first_guest, "");
    defer std.testing.allocator.free(internal_delivery);
    try std.testing.expectEqual(@as(usize, 0), internal_delivery.len);
}

test "stable multiplayer match play relays load score fail skip and completion state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/stable-match-play.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();

    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const host = try sessions.create(try testSessionUser(std.testing.allocator, 20, "play_host"), 0, 0, 0);
    const guest = try sessions.create(try testSessionUser(std.testing.allocator, 21, "play_guest"), 0, 0, 0);
    const no_map = try sessions.create(try testSessionUser(std.testing.allocator, 22, "play_nomap"), 0, 0, 0);
    const observer = try sessions.create(try testSessionUser(std.testing.allocator, 23, "play_observer"), 0, 0, 0);

    const join_lobby = try clientEmptyPacket(std.testing.allocator, .join_lobby);
    defer std.testing.allocator.free(join_lobby);
    const observer_lobby = try bancho.poll(std.testing.allocator, &store, &sessions, observer, join_lobby);
    defer std.testing.allocator.free(observer_lobby);
    const create = try clientMatchPacket(std.testing.allocator, .create_match, host.user.id, "play-secret");
    defer std.testing.allocator.free(create);
    const created = try bancho.poll(std.testing.allocator, &store, &sessions, host, create);
    defer std.testing.allocator.free(created);
    const join = try clientJoinMatchPacket(std.testing.allocator, 0, "play-secret");
    defer std.testing.allocator.free(join);
    const guest_joined = try bancho.poll(std.testing.allocator, &store, &sessions, guest, join);
    defer std.testing.allocator.free(guest_joined);
    const no_map_joined = try bancho.poll(std.testing.allocator, &store, &sessions, no_map, join);
    defer std.testing.allocator.free(no_map_joined);
    const match = sessions.matchById(0).?;
    try std.testing.expectEqual(@as(usize, 3), match.occupied());
    try drainSession(std.testing.allocator, &store, &sessions, host);
    try drainSession(std.testing.allocator, &store, &sessions, guest);
    try drainSession(std.testing.allocator, &store, &sessions, no_map);
    try drainSession(std.testing.allocator, &store, &sessions, observer);

    const no_map_packet = try clientEmptyPacket(std.testing.allocator, .match_no_beatmap);
    defer std.testing.allocator.free(no_map_packet);
    const no_map_result = try bancho.poll(std.testing.allocator, &store, &sessions, no_map, no_map_packet);
    defer std.testing.allocator.free(no_map_result);
    const ready_packet = try clientEmptyPacket(std.testing.allocator, .match_ready);
    defer std.testing.allocator.free(ready_packet);
    const host_ready = try bancho.poll(std.testing.allocator, &store, &sessions, host, ready_packet);
    defer std.testing.allocator.free(host_ready);
    const guest_ready = try bancho.poll(std.testing.allocator, &store, &sessions, guest, ready_packet);
    defer std.testing.allocator.free(guest_ready);
    try drainSession(std.testing.allocator, &store, &sessions, host);
    try drainSession(std.testing.allocator, &store, &sessions, guest);
    try drainSession(std.testing.allocator, &store, &sessions, no_map);
    try drainSession(std.testing.allocator, &store, &sessions, observer);

    const start_packet = try clientEmptyPacket(std.testing.allocator, .match_start);
    defer std.testing.allocator.free(start_packet);
    const denied_start = try bancho.poll(std.testing.allocator, &store, &sessions, guest, start_packet);
    defer std.testing.allocator.free(denied_start);
    try std.testing.expect(!match.in_progress);
    const start_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, start_packet);
    defer std.testing.allocator.free(start_result);
    try std.testing.expect(match.in_progress);

    const host_start = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(host_start);
    var host_start_reader: protocol.Reader = .{ .data = host_start };
    const host_start_packet = (try host_start_reader.next()).?;
    try std.testing.expectEqual(protocol.ServerPacket.match_start, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum(host_start_packet.id))));
    const started_match = try multiplayer.readMatch(host_start_packet.payload);
    try std.testing.expect(started_match.in_progress);
    try std.testing.expectEqual(@as(u8, @intFromEnum(multiplayer.SlotStatus.playing)), started_match.slot_statuses[match.slotIndexByUser(host.user.id).?]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(multiplayer.SlotStatus.playing)), started_match.slot_statuses[match.slotIndexByUser(guest.user.id).?]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(multiplayer.SlotStatus.no_map)), started_match.slot_statuses[match.slotIndexByUser(no_map.user.id).?]);
    try std.testing.expectEqual(protocol.ServerPacket.update_match, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try host_start_reader.next()).?.id))));
    try std.testing.expect((try host_start_reader.next()) == null);
    const guest_start = try bancho.poll(std.testing.allocator, &store, &sessions, guest, "");
    defer std.testing.allocator.free(guest_start);
    var guest_start_reader: protocol.Reader = .{ .data = guest_start };
    try std.testing.expectEqual(protocol.ServerPacket.match_start, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try guest_start_reader.next()).?.id))));
    try std.testing.expectEqual(protocol.ServerPacket.update_match, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try guest_start_reader.next()).?.id))));
    const no_map_start = try bancho.poll(std.testing.allocator, &store, &sessions, no_map, "");
    defer std.testing.allocator.free(no_map_start);
    var no_map_start_reader: protocol.Reader = .{ .data = no_map_start };
    try std.testing.expectEqual(protocol.ServerPacket.update_match, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try no_map_start_reader.next()).?.id))));
    try std.testing.expect((try no_map_start_reader.next()) == null);
    const observer_start = try bancho.poll(std.testing.allocator, &store, &sessions, observer, "");
    defer std.testing.allocator.free(observer_start);
    var observer_start_reader: protocol.Reader = .{ .data = observer_start };
    try std.testing.expectEqual(protocol.ServerPacket.update_match, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try observer_start_reader.next()).?.id))));

    const loaded_packet = try clientEmptyPacket(std.testing.allocator, .match_load_complete);
    defer std.testing.allocator.free(loaded_packet);
    const host_loaded = try bancho.poll(std.testing.allocator, &store, &sessions, host, loaded_packet);
    defer std.testing.allocator.free(host_loaded);
    try std.testing.expectEqual(@as(usize, 0), host_loaded.len);
    const guest_loaded = try bancho.poll(std.testing.allocator, &store, &sessions, guest, loaded_packet);
    defer std.testing.allocator.free(guest_loaded);
    const host_all_loaded = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(host_all_loaded);
    var host_all_loaded_reader: protocol.Reader = .{ .data = host_all_loaded };
    try std.testing.expectEqual(protocol.ServerPacket.match_all_players_loaded, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try host_all_loaded_reader.next()).?.id))));
    const guest_all_loaded = try bancho.poll(std.testing.allocator, &store, &sessions, guest, "");
    defer std.testing.allocator.free(guest_all_loaded);
    var guest_all_loaded_reader: protocol.Reader = .{ .data = guest_all_loaded };
    try std.testing.expectEqual(protocol.ServerPacket.match_all_players_loaded, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try guest_all_loaded_reader.next()).?.id))));
    const no_map_all_loaded = try bancho.poll(std.testing.allocator, &store, &sessions, no_map, "");
    defer std.testing.allocator.free(no_map_all_loaded);
    var no_map_all_loaded_reader: protocol.Reader = .{ .data = no_map_all_loaded };
    try std.testing.expectEqual(protocol.ServerPacket.match_all_players_loaded, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try no_map_all_loaded_reader.next()).?.id))));
    try drainSession(std.testing.allocator, &store, &sessions, observer);

    var score_frame = [_]u8{0} ** 29;
    score_frame[4] = 99;
    score_frame[25] = 1;
    const malformed_score = try clientPayloadPacket(std.testing.allocator, .match_score_update, score_frame[0..28]);
    defer std.testing.allocator.free(malformed_score);
    const malformed_result = try bancho.poll(std.testing.allocator, &store, &sessions, guest, malformed_score);
    defer std.testing.allocator.free(malformed_result);
    const no_malformed_relay = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(no_malformed_relay);
    try std.testing.expectEqual(@as(usize, 0), no_malformed_relay.len);
    const score_packet = try clientPayloadPacket(std.testing.allocator, .match_score_update, &score_frame);
    defer std.testing.allocator.free(score_packet);
    const score_result = try bancho.poll(std.testing.allocator, &store, &sessions, guest, score_packet);
    defer std.testing.allocator.free(score_result);
    const host_score = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(host_score);
    var host_score_reader: protocol.Reader = .{ .data = host_score };
    const relayed_score = (try host_score_reader.next()).?;
    try std.testing.expectEqual(protocol.ServerPacket.match_score_update, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum(relayed_score.id))));
    try std.testing.expectEqual(@as(u8, @intCast(match.slotIndexByUser(guest.user.id).?)), relayed_score.payload[4]);
    const guest_score = try bancho.poll(std.testing.allocator, &store, &sessions, guest, "");
    defer std.testing.allocator.free(guest_score);
    var guest_score_reader: protocol.Reader = .{ .data = guest_score };
    try std.testing.expectEqual(protocol.ServerPacket.match_score_update, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try guest_score_reader.next()).?.id))));
    try drainSession(std.testing.allocator, &store, &sessions, no_map);
    try drainSession(std.testing.allocator, &store, &sessions, observer);

    const failed_packet = try clientEmptyPacket(std.testing.allocator, .match_failed);
    defer std.testing.allocator.free(failed_packet);
    const failed_result = try bancho.poll(std.testing.allocator, &store, &sessions, guest, failed_packet);
    defer std.testing.allocator.free(failed_result);
    const host_failed = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(host_failed);
    var host_failed_reader: protocol.Reader = .{ .data = host_failed };
    const failed_event = (try host_failed_reader.next()).?;
    try std.testing.expectEqual(protocol.ServerPacket.match_player_failed, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum(failed_event.id))));
    try std.testing.expectEqual(@as(i32, @intCast(match.slotIndexByUser(guest.user.id).?)), std.mem.readInt(i32, failed_event.payload[0..4], .little));
    try drainSession(std.testing.allocator, &store, &sessions, guest);
    try drainSession(std.testing.allocator, &store, &sessions, no_map);
    try drainSession(std.testing.allocator, &store, &sessions, observer);

    const skip_packet = try clientEmptyPacket(std.testing.allocator, .match_skip_request);
    defer std.testing.allocator.free(skip_packet);
    const host_skip_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, skip_packet);
    defer std.testing.allocator.free(host_skip_result);
    const host_skip_notice = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(host_skip_notice);
    var host_skip_reader: protocol.Reader = .{ .data = host_skip_notice };
    const host_skipped_event = (try host_skip_reader.next()).?;
    try std.testing.expectEqual(protocol.ServerPacket.match_player_skipped, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum(host_skipped_event.id))));
    try std.testing.expectEqual(host.user.id, std.mem.readInt(i32, host_skipped_event.payload[0..4], .little));
    try std.testing.expect((try host_skip_reader.next()) == null);
    try drainSession(std.testing.allocator, &store, &sessions, guest);
    try drainSession(std.testing.allocator, &store, &sessions, no_map);
    const observer_host_skip = try bancho.poll(std.testing.allocator, &store, &sessions, observer, "");
    defer std.testing.allocator.free(observer_host_skip);
    var observer_host_skip_reader: protocol.Reader = .{ .data = observer_host_skip };
    try std.testing.expectEqual(protocol.ServerPacket.match_player_skipped, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try observer_host_skip_reader.next()).?.id))));

    const guest_skip_result = try bancho.poll(std.testing.allocator, &store, &sessions, guest, skip_packet);
    defer std.testing.allocator.free(guest_skip_result);
    const all_skipped = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(all_skipped);
    var all_skipped_reader: protocol.Reader = .{ .data = all_skipped };
    try std.testing.expectEqual(protocol.ServerPacket.match_player_skipped, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try all_skipped_reader.next()).?.id))));
    try std.testing.expectEqual(protocol.ServerPacket.match_skip, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try all_skipped_reader.next()).?.id))));
    try std.testing.expect((try all_skipped_reader.next()) == null);
    try drainSession(std.testing.allocator, &store, &sessions, guest);
    try drainSession(std.testing.allocator, &store, &sessions, no_map);
    const observer_guest_skip = try bancho.poll(std.testing.allocator, &store, &sessions, observer, "");
    defer std.testing.allocator.free(observer_guest_skip);
    var observer_guest_skip_reader: protocol.Reader = .{ .data = observer_guest_skip };
    try std.testing.expectEqual(protocol.ServerPacket.match_player_skipped, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try observer_guest_skip_reader.next()).?.id))));
    try std.testing.expect((try observer_guest_skip_reader.next()) == null);

    const complete_packet = try clientEmptyPacket(std.testing.allocator, .match_complete);
    defer std.testing.allocator.free(complete_packet);
    const guest_complete_result = try bancho.poll(std.testing.allocator, &store, &sessions, guest, complete_packet);
    defer std.testing.allocator.free(guest_complete_result);
    try std.testing.expect(match.in_progress);
    try std.testing.expectEqual(@as(u8, @intFromEnum(multiplayer.SlotStatus.complete)), match.slotByUser(guest.user.id).?.status);
    const host_complete_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, complete_packet);
    defer std.testing.allocator.free(host_complete_result);
    try std.testing.expect(!match.in_progress);
    const host_complete = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(host_complete);
    var host_complete_reader: protocol.Reader = .{ .data = host_complete };
    try std.testing.expectEqual(protocol.ServerPacket.match_complete, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try host_complete_reader.next()).?.id))));
    const host_state_packet = (try host_complete_reader.next()).?;
    try std.testing.expectEqual(protocol.ServerPacket.update_match, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum(host_state_packet.id))));
    const completed_match = try multiplayer.readMatch(host_state_packet.payload);
    try std.testing.expect(!completed_match.in_progress);
    try std.testing.expectEqual(@as(u8, @intFromEnum(multiplayer.SlotStatus.not_ready)), completed_match.slot_statuses[match.slotIndexByUser(host.user.id).?]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(multiplayer.SlotStatus.not_ready)), completed_match.slot_statuses[match.slotIndexByUser(guest.user.id).?]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(multiplayer.SlotStatus.no_map)), completed_match.slot_statuses[match.slotIndexByUser(no_map.user.id).?]);
    const guest_complete = try bancho.poll(std.testing.allocator, &store, &sessions, guest, "");
    defer std.testing.allocator.free(guest_complete);
    var guest_complete_reader: protocol.Reader = .{ .data = guest_complete };
    try std.testing.expectEqual(protocol.ServerPacket.match_complete, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try guest_complete_reader.next()).?.id))));
    const no_map_complete = try bancho.poll(std.testing.allocator, &store, &sessions, no_map, "");
    defer std.testing.allocator.free(no_map_complete);
    var no_map_complete_reader: protocol.Reader = .{ .data = no_map_complete };
    try std.testing.expectEqual(protocol.ServerPacket.update_match, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try no_map_complete_reader.next()).?.id))));
    try std.testing.expect((try no_map_complete_reader.next()) == null);
    const observer_complete = try bancho.poll(std.testing.allocator, &store, &sessions, observer, "");
    defer std.testing.allocator.free(observer_complete);
    var observer_complete_reader: protocol.Reader = .{ .data = observer_complete };
    try std.testing.expectEqual(protocol.ServerPacket.update_match, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try observer_complete_reader.next()).?.id))));
    for (match.slots) |slot| {
        try std.testing.expect(!slot.loaded);
        try std.testing.expect(!slot.skipped);
    }
}

test "stable multiplayer invitations and supporter tournament channels follow bancho" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/stable-match-invites.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();

    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const host = try sessions.create(try testSessionUser(std.testing.allocator, 30, "invite_host"), 0, 0, 0);
    const target = try sessions.create(try testSessionUser(std.testing.allocator, 31, "invite_target"), 0, 0, 0);
    const regular = try sessions.create(try testSessionUser(std.testing.allocator, 32, "regular_viewer"), 0, 0, 0);
    var supporter_user = try testSessionUser(std.testing.allocator, 33, "supporter_viewer");
    supporter_user.privileges |= 1 << 4;
    const supporter = try sessions.create(supporter_user, 0, 0, 0);
    const bot = try sessions.createBot(try testSessionUser(std.testing.allocator, 3, "kai"));
    _ = bot;

    const create = try clientMatchPacket(std.testing.allocator, .create_match, host.user.id, "invite-secret");
    defer std.testing.allocator.free(create);
    const created = try bancho.poll(std.testing.allocator, &store, &sessions, host, create);
    defer std.testing.allocator.free(created);
    try drainSession(std.testing.allocator, &store, &sessions, host);

    const malformed_invite = try clientPayloadPacket(std.testing.allocator, .match_invite, &.{ 1, 2, 3 });
    defer std.testing.allocator.free(malformed_invite);
    const malformed_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, malformed_invite);
    defer std.testing.allocator.free(malformed_result);
    try std.testing.expectEqual(@as(usize, 0), malformed_result.len);

    const invite = try clientIntPacket(std.testing.allocator, .match_invite, target.user.id);
    defer std.testing.allocator.free(invite);
    const invite_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, invite);
    defer std.testing.allocator.free(invite_result);
    try std.testing.expectEqual(@as(usize, 0), invite_result.len);
    const delivered = try bancho.poll(std.testing.allocator, &store, &sessions, target, "");
    defer std.testing.allocator.free(delivered);
    var delivered_reader: protocol.Reader = .{ .data = delivered };
    const delivered_packet = (try delivered_reader.next()).?;
    try std.testing.expectEqual(protocol.ServerPacket.match_invite, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum(delivered_packet.id))));
    var message: protocol.PayloadReader = .{ .data = delivered_packet.payload };
    try std.testing.expectEqualStrings(host.user.name, try message.string());
    try std.testing.expectEqualStrings("Come join my game: [osump://0/invite-secret zigcho stable room].", try message.string());
    try std.testing.expectEqualStrings(target.user.name, try message.string());
    try std.testing.expectEqual(host.user.id, try message.int(i32));
    try std.testing.expectEqual(message.data.len, message.pos);

    const bot_invite = try clientIntPacket(std.testing.allocator, .match_invite, 3);
    defer std.testing.allocator.free(bot_invite);
    const bot_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, bot_invite);
    defer std.testing.allocator.free(bot_result);
    var bot_reader: protocol.Reader = .{ .data = bot_result };
    const bot_packet = (try bot_reader.next()).?;
    try std.testing.expectEqual(protocol.ServerPacket.send_message, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum(bot_packet.id))));
    var bot_message: protocol.PayloadReader = .{ .data = bot_packet.payload };
    try std.testing.expectEqualStrings("kai", try bot_message.string());
    try std.testing.expectEqualStrings("I'm too busy!", try bot_message.string());

    const info_request = try clientIntPacket(std.testing.allocator, .tournament_match_info, 0);
    defer std.testing.allocator.free(info_request);
    const regular_info = try bancho.poll(std.testing.allocator, &store, &sessions, regular, info_request);
    defer std.testing.allocator.free(regular_info);
    try std.testing.expectEqual(@as(usize, 0), regular_info.len);
    const supporter_info = try bancho.poll(std.testing.allocator, &store, &sessions, supporter, info_request);
    defer std.testing.allocator.free(supporter_info);
    var info_reader: protocol.Reader = .{ .data = supporter_info };
    const info_packet = (try info_reader.next()).?;
    try std.testing.expectEqual(protocol.ServerPacket.update_match, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum(info_packet.id))));
    const public_match = try multiplayer.readMatch(info_packet.payload);
    try std.testing.expectEqualStrings("", public_match.password);

    const join_tourney = try clientIntPacket(std.testing.allocator, .tournament_join_match_channel, 0);
    defer std.testing.allocator.free(join_tourney);
    const regular_join = try bancho.poll(std.testing.allocator, &store, &sessions, regular, join_tourney);
    defer std.testing.allocator.free(regular_join);
    try std.testing.expectEqual(@as(usize, 0), regular_join.len);
    const supporter_join = try bancho.poll(std.testing.allocator, &store, &sessions, supporter, join_tourney);
    defer std.testing.allocator.free(supporter_join);
    var join_reader: protocol.Reader = .{ .data = supporter_join };
    try std.testing.expectEqual(protocol.ServerPacket.channel_join_success, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try join_reader.next()).?.id))));
    try std.testing.expect(supporter.tournamentJoined(0));
    try drainSession(std.testing.allocator, &store, &sessions, supporter);
    try drainSession(std.testing.allocator, &store, &sessions, host);

    const ready = try clientEmptyPacket(std.testing.allocator, .match_ready);
    defer std.testing.allocator.free(ready);
    const host_ready = try bancho.poll(std.testing.allocator, &store, &sessions, host, ready);
    defer std.testing.allocator.free(host_ready);
    const supporter_state = try bancho.poll(std.testing.allocator, &store, &sessions, supporter, "");
    defer std.testing.allocator.free(supporter_state);
    var supporter_state_reader: protocol.Reader = .{ .data = supporter_state };
    try std.testing.expectEqual(protocol.ServerPacket.update_match, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try supporter_state_reader.next()).?.id))));
    try drainSession(std.testing.allocator, &store, &sessions, host);

    const room_message = try clientMessagePacket(std.testing.allocator, .send_public_message, supporter.user.name, "tourney room message", "#multiplayer", supporter.user.id);
    defer std.testing.allocator.free(room_message);
    const supporter_message_result = try bancho.poll(std.testing.allocator, &store, &sessions, supporter, room_message);
    defer std.testing.allocator.free(supporter_message_result);
    try std.testing.expectEqual(@as(usize, 0), supporter_message_result.len);
    const host_message = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(host_message);
    var host_message_reader: protocol.Reader = .{ .data = host_message };
    try std.testing.expectEqual(protocol.ServerPacket.send_message, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try host_message_reader.next()).?.id))));

    const join_match = try clientJoinMatchPacket(std.testing.allocator, 0, "invite-secret");
    defer std.testing.allocator.free(join_match);
    const occupied_viewer = try bancho.poll(std.testing.allocator, &store, &sessions, supporter, join_match);
    defer std.testing.allocator.free(occupied_viewer);
    var occupied_reader: protocol.Reader = .{ .data = occupied_viewer };
    try std.testing.expectEqual(protocol.ServerPacket.match_join_fail, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try occupied_reader.next()).?.id))));
    try std.testing.expect(supporter.tournamentJoined(0));

    const leave_tourney = try clientIntPacket(std.testing.allocator, .tournament_leave_match_channel, 0);
    defer std.testing.allocator.free(leave_tourney);
    const supporter_leave = try bancho.poll(std.testing.allocator, &store, &sessions, supporter, leave_tourney);
    defer std.testing.allocator.free(supporter_leave);
    var leave_reader: protocol.Reader = .{ .data = supporter_leave };
    try std.testing.expectEqual(protocol.ServerPacket.channel_kick, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try leave_reader.next()).?.id))));
    try std.testing.expect(!supporter.tournamentJoined(0));
    try drainSession(std.testing.allocator, &store, &sessions, host);

    const rejoin_tourney = try bancho.poll(std.testing.allocator, &store, &sessions, supporter, join_tourney);
    defer std.testing.allocator.free(rejoin_tourney);
    try std.testing.expect(supporter.tournamentJoined(0));
    const part_match = try clientEmptyPacket(std.testing.allocator, .part_match);
    defer std.testing.allocator.free(part_match);
    const host_part = try bancho.poll(std.testing.allocator, &store, &sessions, host, part_match);
    defer std.testing.allocator.free(host_part);
    try std.testing.expect(sessions.matchById(0) == null);
    try std.testing.expect(!supporter.tournamentJoined(0));
    const disposed_channel = try bancho.poll(std.testing.allocator, &store, &sessions, supporter, "");
    defer std.testing.allocator.free(disposed_channel);
    var disposed_channel_reader: protocol.Reader = .{ .data = disposed_channel };
    _ = (try disposed_channel_reader.next()).?;
    try std.testing.expectEqual(protocol.ServerPacket.channel_kick, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try disposed_channel_reader.next()).?.id))));
}

test "stable multiplayer referees can abort and reset an active round" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/stable-match-referees.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();

    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const host = try sessions.create(try testSessionUser(std.testing.allocator, 40, "ref_host"), 0, 0, 0);
    const guest = try sessions.create(try testSessionUser(std.testing.allocator, 41, "ref_guest"), 0, 0, 0);
    const outsider = try sessions.create(try testSessionUser(std.testing.allocator, 42, "ref_outsider"), 0, 0, 0);

    const create = try clientMatchPacket(std.testing.allocator, .create_match, host.user.id, "ref-secret");
    defer std.testing.allocator.free(create);
    const created = try bancho.poll(std.testing.allocator, &store, &sessions, host, create);
    defer std.testing.allocator.free(created);
    const join = try clientJoinMatchPacket(std.testing.allocator, 0, "ref-secret");
    defer std.testing.allocator.free(join);
    const joined = try bancho.poll(std.testing.allocator, &store, &sessions, guest, join);
    defer std.testing.allocator.free(joined);
    try drainSession(std.testing.allocator, &store, &sessions, host);
    try drainSession(std.testing.allocator, &store, &sessions, guest);
    const match = sessions.matchById(0).?;
    try std.testing.expect(match.isReferee(host.user.id));
    try std.testing.expect(!match.isReferee(guest.user.id));

    const malformed_abort = try clientMessagePacket(std.testing.allocator, .send_public_message, host.user.name, "!mp abort now", "#multiplayer", host.user.id);
    defer std.testing.allocator.free(malformed_abort);
    const malformed_abort_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, malformed_abort);
    defer std.testing.allocator.free(malformed_abort_result);
    try std.testing.expect(!match.in_progress);
    const malformed_abort_response = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(malformed_abort_response);
    var malformed_abort_reader: protocol.Reader = .{ .data = malformed_abort_response };
    var malformed_abort_message: protocol.PayloadReader = .{ .data = (try malformed_abort_reader.next()).?.payload };
    _ = try malformed_abort_message.string();
    try std.testing.expectEqualStrings("Invalid syntax: !mp abort", try malformed_abort_message.string());
    try drainSession(std.testing.allocator, &store, &sessions, guest);

    const outsider_ref = try clientMessagePacket(std.testing.allocator, .send_public_message, host.user.name, "!mp addref ref_outsider", "#multiplayer", host.user.id);
    defer std.testing.allocator.free(outsider_ref);
    const outsider_ref_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, outsider_ref);
    defer std.testing.allocator.free(outsider_ref_result);
    try std.testing.expect(!match.isReferee(outsider.user.id));
    const outsider_response = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(outsider_response);
    var outsider_response_reader: protocol.Reader = .{ .data = outsider_response };
    const outsider_response_packet = (try outsider_response_reader.next()).?;
    var outsider_response_message: protocol.PayloadReader = .{ .data = outsider_response_packet.payload };
    _ = try outsider_response_message.string();
    try std.testing.expectEqualStrings("User must be in the current match!", try outsider_response_message.string());

    const add_ref = try clientMessagePacket(std.testing.allocator, .send_public_message, host.user.name, "!mp addref ref_guest", "#multiplayer", host.user.id);
    defer std.testing.allocator.free(add_ref);
    const add_ref_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, add_ref);
    defer std.testing.allocator.free(add_ref_result);
    try std.testing.expect(match.isReferee(guest.user.id));
    try drainSession(std.testing.allocator, &store, &sessions, host);
    try drainSession(std.testing.allocator, &store, &sessions, guest);

    const start = try clientEmptyPacket(std.testing.allocator, .match_start);
    defer std.testing.allocator.free(start);
    const start_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, start);
    defer std.testing.allocator.free(start_result);
    try std.testing.expect(match.in_progress);
    for (&match.slots) |*slot| if (slot.user_id != null) {
        slot.loaded = true;
        slot.skipped = true;
    };
    try drainSession(std.testing.allocator, &store, &sessions, host);
    try drainSession(std.testing.allocator, &store, &sessions, guest);

    const abort = try clientMessagePacket(std.testing.allocator, .send_public_message, guest.user.name, "!mp abort", "#multiplayer", guest.user.id);
    defer std.testing.allocator.free(abort);
    const abort_result = try bancho.poll(std.testing.allocator, &store, &sessions, guest, abort);
    defer std.testing.allocator.free(abort_result);
    try std.testing.expect(!match.in_progress);
    for (match.slots) |slot| {
        try std.testing.expect(!slot.loaded);
        try std.testing.expect(!slot.skipped);
        if (slot.user_id != null) try std.testing.expectEqual(@as(u8, @intFromEnum(multiplayer.SlotStatus.not_ready)), slot.status);
    }
    const host_abort = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(host_abort);
    var host_abort_reader: protocol.Reader = .{ .data = host_abort };
    try std.testing.expectEqual(protocol.ServerPacket.match_abort, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try host_abort_reader.next()).?.id))));
    try std.testing.expectEqual(protocol.ServerPacket.update_match, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum((try host_abort_reader.next()).?.id))));
    const abort_message_packet = (try host_abort_reader.next()).?;
    try std.testing.expectEqual(protocol.ServerPacket.send_message, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum(abort_message_packet.id))));
    var abort_message: protocol.PayloadReader = .{ .data = abort_message_packet.payload };
    try std.testing.expectEqualStrings("kai", try abort_message.string());
    try std.testing.expectEqualStrings("Match aborted.", try abort_message.string());
    try drainSession(std.testing.allocator, &store, &sessions, guest);

    const remove_ref = try clientMessagePacket(std.testing.allocator, .send_public_message, host.user.name, "!mp rmref ref_guest", "#multiplayer", host.user.id);
    defer std.testing.allocator.free(remove_ref);
    const remove_ref_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, remove_ref);
    defer std.testing.allocator.free(remove_ref_result);
    try std.testing.expect(!match.isReferee(guest.user.id));
    try drainSession(std.testing.allocator, &store, &sessions, host);
    try drainSession(std.testing.allocator, &store, &sessions, guest);

    const restart_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, start);
    defer std.testing.allocator.free(restart_result);
    try std.testing.expect(match.in_progress);
    try drainSession(std.testing.allocator, &store, &sessions, host);
    try drainSession(std.testing.allocator, &store, &sessions, guest);
    const denied_abort = try bancho.poll(std.testing.allocator, &store, &sessions, guest, abort);
    defer std.testing.allocator.free(denied_abort);
    try std.testing.expect(match.in_progress);
    const host_after_denied = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(host_after_denied);
    try std.testing.expectEqual(@as(usize, 0), host_after_denied.len);

    const abort_alias = try clientMessagePacket(std.testing.allocator, .send_public_message, host.user.name, "!mp a", "#multiplayer", host.user.id);
    defer std.testing.allocator.free(abort_alias);
    const host_abort_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, abort_alias);
    defer std.testing.allocator.free(host_abort_result);
    try std.testing.expect(!match.in_progress);
    try drainSession(std.testing.allocator, &store, &sessions, host);
    try drainSession(std.testing.allocator, &store, &sessions, guest);

    const add_ref_again = try bancho.poll(std.testing.allocator, &store, &sessions, host, add_ref);
    defer std.testing.allocator.free(add_ref_again);
    try std.testing.expect(match.isReferee(guest.user.id));
    try drainSession(std.testing.allocator, &store, &sessions, host);
    try drainSession(std.testing.allocator, &store, &sessions, guest);
    const part = try clientEmptyPacket(std.testing.allocator, .part_match);
    defer std.testing.allocator.free(part);
    const guest_part = try bancho.poll(std.testing.allocator, &store, &sessions, guest, part);
    defer std.testing.allocator.free(guest_part);
    try std.testing.expect(!match.isReferee(guest.user.id));
}

test "stable spectating scopes lifecycle frames chat and failure packets to one host" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/stable-spectating.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();

    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const host = try sessions.create(try testSessionUser(std.testing.allocator, 50, "spectate_host"), 0, 0, 0);
    const first = try sessions.create(try testSessionUser(std.testing.allocator, 51, "spectate_first"), 0, 0, 0);
    const second = try sessions.create(try testSessionUser(std.testing.allocator, 52, "spectate_second"), 0, 0, 0);
    const outsider = try sessions.create(try testSessionUser(std.testing.allocator, 53, "spectate_outsider"), 0, 0, 0);

    const start_host = try clientIntPacket(std.testing.allocator, .start_spectating, host.user.id);
    defer std.testing.allocator.free(start_host);
    const first_start = try bancho.poll(std.testing.allocator, &store, &sessions, first, start_host);
    defer std.testing.allocator.free(first_start);
    try std.testing.expectEqual(host.user.id, first.spectating_user_id.?);

    const first_joined = try bancho.poll(std.testing.allocator, &store, &sessions, first, "");
    defer std.testing.allocator.free(first_joined);
    try expectPacketIds(first_joined, &.{ .channel_join_success, .channel_info });
    const host_first_join = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(host_first_join);
    try expectPacketIds(host_first_join, &.{ .channel_join_success, .channel_info, .channel_info, .spectator_joined });
    const outsider_first_join = try bancho.poll(std.testing.allocator, &store, &sessions, outsider, "");
    defer std.testing.allocator.free(outsider_first_join);
    try std.testing.expectEqual(@as(usize, 0), outsider_first_join.len);

    const same_host = try bancho.poll(std.testing.allocator, &store, &sessions, first, start_host);
    defer std.testing.allocator.free(same_host);
    const host_same_spectator = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(host_same_spectator);
    try expectPacketIds(host_same_spectator, &.{.spectator_joined});
    const first_not_duplicated = try bancho.poll(std.testing.allocator, &store, &sessions, first, "");
    defer std.testing.allocator.free(first_not_duplicated);
    try std.testing.expectEqual(@as(usize, 0), first_not_duplicated.len);

    const malformed_start = try clientPayloadPacket(std.testing.allocator, .start_spectating, &.{ 1, 2, 3 });
    defer std.testing.allocator.free(malformed_start);
    const malformed_result = try bancho.poll(std.testing.allocator, &store, &sessions, first, malformed_start);
    defer std.testing.allocator.free(malformed_result);
    try std.testing.expectEqual(host.user.id, first.spectating_user_id.?);

    const second_start = try bancho.poll(std.testing.allocator, &store, &sessions, second, start_host);
    defer std.testing.allocator.free(second_start);
    const second_joined = try bancho.poll(std.testing.allocator, &store, &sessions, second, "");
    defer std.testing.allocator.free(second_joined);
    try expectPacketIds(second_joined, &.{ .channel_join_success, .channel_info, .fellow_spectator_joined });
    const first_saw_second = try bancho.poll(std.testing.allocator, &store, &sessions, first, "");
    defer std.testing.allocator.free(first_saw_second);
    try expectPacketIds(first_saw_second, &.{ .channel_info, .fellow_spectator_joined });
    const host_saw_second = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(host_saw_second);
    try expectPacketIds(host_saw_second, &.{ .channel_info, .spectator_joined });

    const chat = try clientMessagePacket(std.testing.allocator, .send_public_message, first.user.name, "spectator room only", "#spectator", first.user.id);
    defer std.testing.allocator.free(chat);
    const chat_result = try bancho.poll(std.testing.allocator, &store, &sessions, first, chat);
    defer std.testing.allocator.free(chat_result);
    const host_chat = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(host_chat);
    try expectPacketIds(host_chat, &.{.send_message});
    const second_chat = try bancho.poll(std.testing.allocator, &store, &sessions, second, "");
    defer std.testing.allocator.free(second_chat);
    try expectPacketIds(second_chat, &.{.send_message});
    const outsider_chat = try bancho.poll(std.testing.allocator, &store, &sessions, outsider, "");
    defer std.testing.allocator.free(outsider_chat);
    try std.testing.expectEqual(@as(usize, 0), outsider_chat.len);

    const frame_bytes = [_]u8{ 1, 2, 3, 4, 5, 6 };
    const frames = try clientPayloadPacket(std.testing.allocator, .spectate_frames, &frame_bytes);
    defer std.testing.allocator.free(frames);
    const frame_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, frames);
    defer std.testing.allocator.free(frame_result);
    const first_frames = try bancho.poll(std.testing.allocator, &store, &sessions, first, "");
    defer std.testing.allocator.free(first_frames);
    var first_frame_reader: protocol.Reader = .{ .data = first_frames };
    const first_frame = (try first_frame_reader.next()).?;
    try std.testing.expectEqual(protocol.ServerPacket.spectate_frames, @as(protocol.ServerPacket, @enumFromInt(@intFromEnum(first_frame.id))));
    try std.testing.expectEqualSlices(u8, &frame_bytes, first_frame.payload);
    try std.testing.expect((try first_frame_reader.next()) == null);
    const second_frames = try bancho.poll(std.testing.allocator, &store, &sessions, second, "");
    defer std.testing.allocator.free(second_frames);
    try expectPacketIds(second_frames, &.{.spectate_frames});
    const outsider_frames = try bancho.poll(std.testing.allocator, &store, &sessions, outsider, "");
    defer std.testing.allocator.free(outsider_frames);
    try std.testing.expectEqual(@as(usize, 0), outsider_frames.len);

    const cant = try clientEmptyPacket(std.testing.allocator, .cant_spectate);
    defer std.testing.allocator.free(cant);
    const cant_result = try bancho.poll(std.testing.allocator, &store, &sessions, first, cant);
    defer std.testing.allocator.free(cant_result);
    const host_cant = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(host_cant);
    try expectPacketIds(host_cant, &.{.spectator_cant_spectate});
    const first_cant = try bancho.poll(std.testing.allocator, &store, &sessions, first, "");
    defer std.testing.allocator.free(first_cant);
    try expectPacketIds(first_cant, &.{.spectator_cant_spectate});
    const second_cant = try bancho.poll(std.testing.allocator, &store, &sessions, second, "");
    defer std.testing.allocator.free(second_cant);
    try expectPacketIds(second_cant, &.{.spectator_cant_spectate});

    const stop = try clientEmptyPacket(std.testing.allocator, .stop_spectating);
    defer std.testing.allocator.free(stop);
    const stop_result = try bancho.poll(std.testing.allocator, &store, &sessions, first, stop);
    defer std.testing.allocator.free(stop_result);
    try std.testing.expect(first.spectating_user_id == null);
    const first_stopped = try bancho.poll(std.testing.allocator, &store, &sessions, first, "");
    defer std.testing.allocator.free(first_stopped);
    try expectPacketIds(first_stopped, &.{.channel_kick});
    const host_first_left = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(host_first_left);
    try expectPacketIds(host_first_left, &.{ .channel_info, .spectator_left });
    const second_first_left = try bancho.poll(std.testing.allocator, &store, &sessions, second, "");
    defer std.testing.allocator.free(second_first_left);
    try expectPacketIds(second_first_left, &.{ .channel_info, .fellow_spectator_left });

    const start_outsider = try clientIntPacket(std.testing.allocator, .start_spectating, outsider.user.id);
    defer std.testing.allocator.free(start_outsider);
    const switched = try bancho.poll(std.testing.allocator, &store, &sessions, second, start_outsider);
    defer std.testing.allocator.free(switched);
    try std.testing.expectEqual(outsider.user.id, second.spectating_user_id.?);
    const second_switched = try bancho.poll(std.testing.allocator, &store, &sessions, second, "");
    defer std.testing.allocator.free(second_switched);
    try expectPacketIds(second_switched, &.{ .channel_kick, .channel_join_success, .channel_info });
    const old_host_empty = try bancho.poll(std.testing.allocator, &store, &sessions, host, "");
    defer std.testing.allocator.free(old_host_empty);
    try expectPacketIds(old_host_empty, &.{ .channel_kick, .spectator_left });
    const new_host_join = try bancho.poll(std.testing.allocator, &store, &sessions, outsider, "");
    defer std.testing.allocator.free(new_host_join);
    try expectPacketIds(new_host_join, &.{ .channel_join_success, .channel_info, .channel_info, .spectator_joined });

    const self_start = try clientIntPacket(std.testing.allocator, .start_spectating, host.user.id);
    defer std.testing.allocator.free(self_start);
    const self_start_result = try bancho.poll(std.testing.allocator, &store, &sessions, host, self_start);
    defer std.testing.allocator.free(self_start_result);
    try std.testing.expect(host.spectating_user_id == null);

    const outsider_id = outsider.user.id;
    outsider.login_time -= 2;
    const logout = try clientEmptyPacket(std.testing.allocator, .logout);
    defer std.testing.allocator.free(logout);
    const host_logout = try bancho.poll(std.testing.allocator, &store, &sessions, outsider, logout);
    defer std.testing.allocator.free(host_logout);
    try std.testing.expect(sessions.byUser(outsider_id) == null);
    try std.testing.expect(second.spectating_user_id == null);
    const second_host_logout = try bancho.poll(std.testing.allocator, &store, &sessions, second, "");
    defer std.testing.allocator.free(second_host_logout);
    try expectPacketIds(second_host_logout, &.{ .channel_kick, .user_logout });
}

test "stable spectator packet construction survives every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/spectator-allocation.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    var context: SpectatorAllocationContext = .{ .store = &store };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, spectatorAllocationRun, .{&context});
}

test "lazer custom mod acronyms are bounded" {
    try std.testing.expect(lazer.validAcronym("RX"));
    try std.testing.expect(lazer.validAcronym("WIGGLE"));
    try std.testing.expect(!lazer.validAcronym("bad"));
    try std.testing.expect(!lazer.validAcronym("TOO-LONG-MOD"));
}

test "lazer relax scores cannot enter vanilla namespace" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"beatmap_id\":1,\"ruleset_id\":0,\"total_score\":10,\"accuracy\":0.98,\"max_combo\":5,\"passed\":true,\"mods\":[{\"acronym\":\"RX\",\"settings\":{}}],\"statistics\":{}}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(lazer.Namespace.relax, (try lazer.parseScore(parsed.value)).namespace);
}

test "lazer autopilot has its own standard-only stats namespace" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"beatmap_id\":1,\"ruleset_id\":0,\"total_score\":10,\"accuracy\":0.98,\"max_combo\":5,\"passed\":true,\"mods\":[{\"acronym\":\"AP\"}],\"statistics\":{}}", .{});
    defer parsed.deinit();
    const input = try lazer.parseScore(parsed.value);
    try std.testing.expectEqual(lazer.Namespace.autopilot, input.namespace);
    try std.testing.expectEqual(@as(?u8, 8), lazer.statsMode(input));

    const mania_rx = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"beatmap_id\":1,\"ruleset_id\":3,\"total_score\":10,\"accuracy\":1,\"max_combo\":1,\"passed\":true,\"mods\":[{\"acronym\":\"RX\"}],\"statistics\":{}}", .{});
    defer mania_rx.deinit();
    try std.testing.expectError(error.InvalidModMode, lazer.parseScore(mania_rx.value));
    const taiko_ap = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"beatmap_id\":1,\"ruleset_id\":1,\"total_score\":10,\"accuracy\":1,\"max_combo\":1,\"passed\":true,\"mods\":[{\"acronym\":\"AP\"}],\"statistics\":{}}", .{});
    defer taiko_ap.deinit();
    try std.testing.expectError(error.InvalidModMode, lazer.parseScore(taiko_ap.value));
}

test "unknown lazer mods enter custom namespace" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"beatmap_id\":1,\"ruleset_id\":0,\"total_score\":10,\"accuracy\":0.98,\"max_combo\":5,\"passed\":true,\"mods\":[{\"acronym\":\"WIGGLE\",\"settings\":{\"strength\":1.2}}],\"statistics\":{}}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(lazer.Namespace.custom, (try lazer.parseScore(parsed.value)).namespace);
}

test "custom lazer mods win over relax regardless of order" {
    const fixtures = [_][]const u8{
        "{\"beatmap_id\":1,\"ruleset_id\":0,\"total_score\":10,\"accuracy\":1,\"max_combo\":5,\"passed\":true,\"mods\":[{\"acronym\":\"RX\"},{\"acronym\":\"WIGGLE\"}],\"statistics\":{}}",
        "{\"beatmap_id\":1,\"ruleset_id\":0,\"total_score\":10,\"accuracy\":1,\"max_combo\":5,\"passed\":true,\"mods\":[{\"acronym\":\"WIGGLE\"},{\"acronym\":\"RX\"}],\"statistics\":{}}",
    };
    for (fixtures) |fixture| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fixture, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(lazer.Namespace.custom, (try lazer.parseScore(parsed.value)).namespace);
    }
}

test "lazer replay input is bounded and tied to the submitted ruleset" {
    var replay: [32]u8 = @splat(0);
    replay[0] = 0;
    std.mem.writeInt(i32, replay[1..5], 20_260_816, .little);
    var encoded: [std.base64.standard.Encoder.calcSize(replay.len)]u8 = undefined;
    const replay_base64 = std.base64.standard.Encoder.encode(&encoded, &replay);
    var raw: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&raw, "{{\"replay\":\"{s}\"}}", .{replay_base64});
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const decoded = try lazer.decodeReplay(std.testing.allocator, parsed.value.object, 0);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, &replay, decoded);
    try std.testing.expectError(error.InvalidReplay, lazer.decodeReplay(std.testing.allocator, parsed.value.object, 1));

    const short = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"replay\":\"AA==\"}", .{});
    defer short.deinit();
    try std.testing.expectError(error.InvalidReplay, lazer.decodeReplay(std.testing.allocator, short.value.object, 0));
    const malformed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"replay\":\"not base64\"}", .{});
    defer malformed.deinit();
    try std.testing.expectError(error.InvalidReplay, lazer.decodeReplay(std.testing.allocator, malformed.value.object, 0));
}

test "lazer score input is fully typed and bounded before storage" {
    const valid = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"beatmap_id\":1,\"ruleset_id\":3,\"total_score\":1000000000000,\"legacy_total_score\":null,\"accuracy\":1,\"max_combo\":10000000,\"passed\":false,\"mods\":[],\"statistics\":{},\"client_version\":null}", .{});
    defer valid.deinit();
    const input = try lazer.parseScore(valid.value);
    try std.testing.expectEqual(@as(i64, 3), input.ruleset_id);
    try std.testing.expectEqual(@as(i64, 10_000_000), input.max_combo);
    try std.testing.expectEqual(lazer.Namespace.vanilla, input.namespace);

    const invalid = [_][]const u8{
        "{\"beatmap_id\":1,\"ruleset_id\":\"osu\",\"total_score\":10,\"accuracy\":1,\"max_combo\":1,\"passed\":true,\"mods\":[],\"statistics\":{}}",
        "{\"beatmap_id\":1,\"ruleset_id\":4,\"total_score\":10,\"accuracy\":1,\"max_combo\":1,\"passed\":true,\"mods\":[],\"statistics\":{}}",
        "{\"beatmap_id\":1,\"ruleset_id\":0,\"total_score\":-1,\"accuracy\":1,\"max_combo\":1,\"passed\":true,\"mods\":[],\"statistics\":{}}",
        "{\"beatmap_id\":1,\"ruleset_id\":0,\"total_score\":10,\"accuracy\":1.1,\"max_combo\":1,\"passed\":true,\"mods\":[],\"statistics\":{}}",
        "{\"beatmap_id\":1,\"ruleset_id\":0,\"total_score\":10,\"accuracy\":1,\"max_combo\":10000001,\"passed\":true,\"mods\":[],\"statistics\":{}}",
        "{\"beatmap_id\":1,\"ruleset_id\":0,\"total_score\":10,\"accuracy\":1,\"max_combo\":1,\"passed\":1,\"mods\":[],\"statistics\":{}}",
        "{\"beatmap_id\":1,\"ruleset_id\":0,\"total_score\":10,\"accuracy\":1,\"max_combo\":1,\"passed\":true,\"mods\":[],\"statistics\":[]}",
        "{\"beatmap_id\":1,\"ruleset_id\":0,\"total_score\":10,\"accuracy\":1,\"max_combo\":1,\"passed\":true,\"mods\":[],\"statistics\":{},\"client_version\":4}",
        "{\"beatmap_id\":1,\"ruleset_id\":0,\"total_score\":10,\"legacy_total_score\":2147483648,\"accuracy\":1,\"max_combo\":1,\"passed\":true,\"mods\":[],\"statistics\":{}}",
    };
    for (invalid) |fixture| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fixture, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidScore, lazer.parseScore(parsed.value));
    }
}

test "lazer storage only accepts the typed score input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/typed-lazer-score.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(1,'ari','ari',x'00',x'00')");

    const raw = "{\"beatmap_id\":75,\"ruleset_id\":0,\"total_score\":987654,\"legacy_total_score\":900000,\"accuracy\":0.985,\"max_combo\":321,\"passed\":true,\"mods\":[{\"acronym\":\"RX\"},{\"acronym\":\"WIGGLE\"}],\"statistics\":{},\"client_version\":\"2026.811.0\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const mods_json = try lazer.jsonField(std.testing.allocator, parsed.value.object, "mods", "[]");
    defer std.testing.allocator.free(mods_json);
    const statistics_json = try lazer.jsonField(std.testing.allocator, parsed.value.object, "statistics", "{}");
    defer std.testing.allocator.free(statistics_json);
    const id = try store.insertLazerScore(1, try lazer.parseScore(parsed.value), 0, mods_json, statistics_json, "{}", "[]", &.{});
    try std.testing.expect(id > 0);

    var stmt: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "SELECT beatmap_id,ruleset_id,total_score,legacy_total_score,accuracy,max_combo,passed,rank_namespace,client_version FROM lazer_scores WHERE id=?1", -1, &stmt, null));
    defer _ = storage.c.sqlite3_finalize(stmt);
    _ = storage.c.sqlite3_bind_int64(stmt, 1, id);
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(i64, 75), storage.c.sqlite3_column_int64(stmt, 0));
    try std.testing.expectEqual(@as(i64, 0), storage.c.sqlite3_column_int64(stmt, 1));
    try std.testing.expectEqual(@as(i64, 987654), storage.c.sqlite3_column_int64(stmt, 2));
    try std.testing.expectEqual(@as(i64, 98765), storage.c.sqlite3_column_int64(stmt, 3));
    try std.testing.expectApproxEqAbs(@as(f64, 0.985), storage.c.sqlite3_column_double(stmt, 4), 0.000001);
    try std.testing.expectEqual(@as(i64, 321), storage.c.sqlite3_column_int64(stmt, 5));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(stmt, 6));
    try std.testing.expectEqualStrings("custom", std.mem.span(storage.c.sqlite3_column_text(stmt, 7)));
    try std.testing.expectEqualStrings("2026.811.0", std.mem.span(storage.c.sqlite3_column_text(stmt, 8)));
}

test "custom lazer plays update local map counters without touching player stats" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/custom-lazer-counters.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(1,'custom counter','custom_counter',x'00',x'00');" ++
            "INSERT INTO stats(user_id,mode) VALUES(1,0)",
    );
    const map_md5 = "75757575757575757575757575757575";
    try store.upsertBeatmapMeta(.{
        .id = 75,
        .set_id = 70,
        .artist = "counter artist",
        .title = "counter title",
        .version = "counter difficulty",
        .creator = "counter mapper",
        .total_length = 120,
    }, map_md5, 3, 4.5, 500);

    const raw = "{\"beatmap_id\":75,\"ruleset_id\":0,\"total_score\":123456,\"accuracy\":0.8,\"max_combo\":40,\"passed\":false,\"rank\":\"F\",\"mods\":[{\"acronym\":\"WIGGLE\"}],\"statistics\":{\"great\":4,\"miss\":1}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const mods_json = try lazer.jsonField(std.testing.allocator, parsed.value.object, "mods", "[]");
    defer std.testing.allocator.free(mods_json);
    const statistics_json = try lazer.jsonField(std.testing.allocator, parsed.value.object, "statistics", "{}");
    defer std.testing.allocator.free(statistics_json);
    const failed_input = try lazer.parseScore(parsed.value);
    try std.testing.expectEqual(lazer.Namespace.custom, failed_input.namespace);
    try std.testing.expect(lazer.statsMode(failed_input) == null);
    const stats_before = (try store.statsForUser(1, 0)).?;

    _ = try store.insertLazerScore(1, failed_input, 0, mods_json, statistics_json, "{}", "[]", &.{});
    const after_fail = (try store.beatmapForScore(map_md5)).?;
    try std.testing.expectEqual(@as(i32, 1), after_fail.plays);
    try std.testing.expectEqual(@as(i32, 0), after_fail.passes);

    var passed_input = failed_input;
    passed_input.passed = true;
    passed_input.rank = "A";
    passed_input.total_score = 654_321;
    _ = try store.insertLazerScore(1, passed_input, 999, mods_json, statistics_json, "{}", "[]", &.{});
    const after_pass = (try store.beatmapForScore(map_md5)).?;
    try std.testing.expectEqual(@as(i32, 2), after_pass.plays);
    try std.testing.expectEqual(@as(i32, 1), after_pass.passes);
    try std.testing.expectEqualDeep(stats_before, (try store.statsForUser(1, 0)).?);

    const set_json = (try store.lazerBeatmapSet(std.testing.allocator, 70, null)).?;
    defer std.testing.allocator.free(set_json);
    var set = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, set_json, .{});
    defer set.deinit();
    try std.testing.expectEqual(@as(i64, 2), set.value.object.get("play_count").?.integer);
    const map = set.value.object.get("beatmaps").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 2), map.get("playcount").?.integer);
    try std.testing.expectEqual(@as(i64, 1), map.get("passcount").?.integer);
}

test "unbound room score tokens are discarded without touching solo tokens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/room-score-token-discard.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("room token owner", "room-token-owner@example.invalid", "00000000000000000000000000000000");
    const map_md5 = "76767676767676767676767676767676";
    try store.upsertBeatmapMeta(.{ .id = 76, .set_id = 71, .artist = "token artist", .title = "token title", .version = "token difficulty", .creator = "token mapper" }, map_md5, 3, 4, 100);
    const room_token = try store.createLazerRoomScoreToken(user_id, 76, map_md5, 0, "11111111111111111111111111111111");
    try std.testing.expect(storage.Store.isLazerRoomScoreToken(room_token));
    try std.testing.expect(try store.discardUnusedLazerRoomScoreToken(user_id, room_token));
    try std.testing.expect(!try store.discardUnusedLazerRoomScoreToken(user_id, room_token));
    const solo_token = try store.createLazerScoreToken(user_id, 76, map_md5, 0, "22222222222222222222222222222222");
    try std.testing.expect(!try store.discardUnusedLazerRoomScoreToken(user_id, solo_token));
}

test "official lazer solo score paths match the pinned client contract" {
    const create = lazer.parseSoloScorePath("/api/v2/beatmaps/75/solo/scores").?;
    try std.testing.expectEqual(@as(i32, 75), create.beatmap_id);
    try std.testing.expect(create.token_id == null);
    const submit = lazer.parseSoloScorePath("/api/v2/beatmaps/75/solo/scores/123456789").?;
    try std.testing.expectEqual(@as(i64, 123456789), submit.token_id.?);
    try std.testing.expect(lazer.parseSoloScorePath("/api/v2/beatmaps/75/solo/scores/") == null);
    try std.testing.expect(lazer.parseSoloScorePath("/api/v2/beatmaps/75/solo/scores/1/replay") == null);
    try std.testing.expect(lazer.parseSoloScorePath("/api/v2/beatmaps/nope/solo/scores") == null);
    try std.testing.expectEqual(@as(i32, 75), lazer.parseLeaderboardPath("/api/v2/beatmaps/75/scores").?.beatmap_id);
    try std.testing.expect(lazer.parseLeaderboardPath("/api/v2/beatmaps/75/solo/scores") == null);
    try std.testing.expect(lazer.parseLeaderboardPath("/api/v2/beatmaps/nope/scores") == null);
}

test "official lazer ranking paths match the pinned client contract" {
    const performance = lazer.parseRankingPath("/api/v2/rankings/osu/performance").?;
    try std.testing.expectEqual(@as(u8, 0), performance.ruleset_id);
    try std.testing.expectEqual(lazer.RankingKind.performance, performance.kind);
    const country_ranking = lazer.parseRankingPath("/api/v2/rankings/fruits/country").?;
    try std.testing.expectEqual(@as(u8, 2), country_ranking.ruleset_id);
    try std.testing.expectEqual(lazer.RankingKind.country, country_ranking.kind);
    try std.testing.expectEqual(lazer.RankingKind.score, lazer.parseRankingPath("/api/v2/rankings/mania/score").?.kind);
    try std.testing.expect(lazer.parseRankingPath("/api/v2/rankings/catch/performance") == null);
    try std.testing.expect(lazer.parseRankingPath("/api/v2/rankings/osu") == null);
    try std.testing.expect(lazer.parseRankingPath("/api/v2/rankings/osu/performance/extra") == null);
}

test "lazer ranking payloads order performance score and countries independently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/lazer-rankings.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,country,password_hash,password_salt) VALUES" ++
            "(1,'score first','score_first','AU',x'00',x'00')," ++
            "(2,'pp first','pp_first','GB',x'00',x'00')," ++
            "(5,'hidden','hidden','AU',x'00',x'00');" ++
            "UPDATE users SET restricted=1 WHERE id=5;" ++
            "INSERT INTO stats(user_id,mode,ranked_score,total_score,pp,plays,play_time,total_hits,accuracy,max_combo) VALUES" ++
            "(1,0,900,5000,300,5,60,100,0.95,50)," ++
            "(2,0,800,4000,400,4,50,90,0.90,40)," ++
            "(5,0,9999,9999,9999,99,99,99,1,99)",
    );

    const performance_json = try store.lazerRankingsJson(std.testing.allocator, 0, .performance, null, 1);
    defer std.testing.allocator.free(performance_json);
    var performance = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, performance_json, .{});
    defer performance.deinit();
    const performance_rows = performance.value.object.get("ranking").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), performance_rows.len);
    try std.testing.expectEqualStrings("pp first", performance_rows[0].object.get("user").?.object.get("username").?.string);
    try std.testing.expectEqual(@as(i64, 1), performance_rows[0].object.get("global_rank").?.integer);
    try std.testing.expectApproxEqAbs(@as(f64, 90), performance_rows[0].object.get("hit_accuracy").?.float, 0.000001);

    const score_json = try store.lazerRankingsJson(std.testing.allocator, 0, .score, null, 1);
    defer std.testing.allocator.free(score_json);
    var score = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, score_json, .{});
    defer score.deinit();
    try std.testing.expectEqualStrings("score first", score.value.object.get("ranking").?.array.items[0].object.get("user").?.object.get("username").?.string);

    const au_json = try store.lazerRankingsJson(std.testing.allocator, 0, .performance, "AU", 1);
    defer std.testing.allocator.free(au_json);
    var au = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, au_json, .{});
    defer au.deinit();
    try std.testing.expectEqual(@as(usize, 1), au.value.object.get("ranking").?.array.items.len);
    try std.testing.expectEqualStrings("AU", au.value.object.get("ranking").?.array.items[0].object.get("user").?.object.get("country_code").?.string);

    const countries_json = try store.lazerRankingsJson(std.testing.allocator, 0, .country, null, 1);
    defer std.testing.allocator.free(countries_json);
    var countries = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, countries_json, .{});
    defer countries.deinit();
    const country_rows = countries.value.object.get("ranking").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), country_rows.len);
    try std.testing.expectEqualStrings("GB", country_rows[0].object.get("code").?.string);
    try std.testing.expectEqual(@as(i64, 4), country_rows[0].object.get("play_count").?.integer);
    try std.testing.expectEqual(@as(i64, 400), country_rows[0].object.get("performance").?.integer);
}

test "lazer ruleset profile paths match the pinned client contract" {
    const osu = lazer.parseUserPath("/api/v2/users/4/osu").?;
    try std.testing.expectEqualStrings("4", osu.lookup);
    try std.testing.expectEqual(@as(u8, 0), osu.ruleset_id);
    const fruits = lazer.parseUserPath("/api/v2/users/raya/fruits").?;
    try std.testing.expectEqualStrings("raya", fruits.lookup);
    try std.testing.expectEqual(@as(u8, 2), fruits.ruleset_id);
    try std.testing.expectEqual(@as(u8, 3), lazer.parseUserPath("/api/v2/users/4/mania").?.ruleset_id);
    try std.testing.expectEqual(@as(u8, 0), lazer.parseUserPath("/api/v2/users/4/").?.ruleset_id);
    try std.testing.expectEqual(@as(u8, 0), lazer.parseUserPath("/api/v2/users/4").?.ruleset_id);
    try std.testing.expect(lazer.parseUserPath("/api/v2/users/4/catch") == null);
    try std.testing.expect(lazer.parseUserPath("/api/v2/users/4/osu/extra") == null);
    try std.testing.expect(lazer.parseUserPath("/api/v2/users//osu") == null);
    const best = lazer.parseUserScoresPath("/api/v2/users/4/scores/best").?;
    try std.testing.expectEqual(@as(i32, 4), best.user_id);
    try std.testing.expectEqual(lazer.UserScoreKind.best, best.kind);
    try std.testing.expectEqual(lazer.UserScoreKind.recent, lazer.parseUserScoresPath("/api/v2/users/4/scores/recent").?.kind);
    try std.testing.expect(lazer.parseUserScoresPath("/api/v2/users/4/scores/nope") == null);
    try std.testing.expect(lazer.parseUserScoresPath("/api/v2/users/name/scores/best") == null);
    try std.testing.expect((try lazer.lookupRulesetId(null)) == null);
    try std.testing.expectEqual(@as(u8, 0), (try lazer.lookupRulesetId("0")).?);
    try std.testing.expectEqual(@as(u8, 3), (try lazer.lookupRulesetId("3")).?);
    try std.testing.expectError(error.InvalidRulesetId, lazer.lookupRulesetId("4"));
    try std.testing.expectError(error.InvalidRulesetId, lazer.lookupRulesetId("osu"));
    try std.testing.expectEqual(@as(i32, 4), lazer.parseUserRecentActivityPath("/api/v2/users/4/recent_activity").?);
    try std.testing.expectEqual(@as(i64, 42), lazer.parseCommentPath("/api/v2/comments/42").?);
    try std.testing.expectEqual(@as(i64, 42), lazer.parseCommentVotePath("/api/v2/comments/42/vote").?);
    try std.testing.expect(lazer.parseCommentPath("/api/v2/comments/42/vote") == null);
}

test "batch user visibility and ruleset stats mirror profile privacy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/batch-user-stats.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO users(id,name,safe_name,country,password_hash,password_salt,show_country,show_profile_stats) VALUES(4,'raya','raya','AU',x'00',x'00',0,0); INSERT INTO stats(user_id,mode,ranked_score,total_score,pp,plays,play_time,total_hits,accuracy,max_combo) VALUES(4,0,1000,2000,300,4,50,60,0.95,70),(4,1,0,0,0,0,0,0,0,0),(4,2,0,0,0,0,0,0,0,0),(4,3,0,0,0,0,0,0,0,0)");
    const visibility = (try store.lazerBatchUserVisibility(4)).?;
    try std.testing.expect(!visibility.show_country);
    try std.testing.expect(!visibility.show_profile_stats);
    const rulesets = try store.statsRulesetsForUser(4);
    try std.testing.expectEqual(@as(i32, 4), rulesets[0].?.plays);
    try std.testing.expectEqual(@as(i32, 300), rulesets[0].?.pp);
    try std.testing.expectEqual(@as(i32, 0), rulesets[3].?.plays);
    try std.testing.expect((try store.statsRulesetsForUser(99))[0] == null);
    try std.testing.expect((try store.lazerBatchUserVisibility(99)) == null);
}

test "pinned batch response accepts mixed local upstream and bot users" {
    const local: domain.User = .{ .id = 4, .name = "raya", .safe_name = "raya", .country = .{ 'A', 'U' } };
    const bot: domain.User = .{ .id = 3, .name = "kai", .safe_name = "kai", .country = .{ 'X', 'X' } };
    const rulesets = [4]?domain.Stats{
        .{ .mode = .osu, .pp = 500, .plays = 10, .global_rank = 7 },
        null,
        null,
        null,
    };
    const upstream = try upstream_user.jsonOwned(std.testing.allocator, .{
        .id = 4_452_992,
        .username = "Sotarks",
        .country = .{ 'F', 'R' },
        .join_date = "2014-05-28T17:34:35Z",
        .mode = 0,
        .pp = 6440.47,
        .global_rank = 50_128,
        .country_rank = 1563,
        .ranked_score = 22_490_858_468,
        .total_score = 91_822_598_773,
        .play_count = 45_597,
        .play_time = 1_000,
        .level = 100.649,
        .accuracy = 99.301498,
        .total_hits = 10_002_288,
        .grade_ssh = 251,
        .grade_ss = 64,
        .grade_sh = 1502,
        .grade_s = 566,
        .grade_a = 780,
    });
    defer std.testing.allocator.free(upstream);
    var response: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer response.deinit();
    try response.writer.writeAll("{\"users\":[");
    try user_json.writeBatchWithRulesets(&response.writer, local, rulesets, .{}, false);
    try response.writer.writeByte(',');
    try response.writer.writeAll(upstream);
    try response.writer.writeByte(',');
    try user_json.writeBatchWithRulesets(&response.writer, bot, rulesets, .{}, false);
    try response.writer.writeAll("],\"cursor\":null}");
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response.written(), .{});
    defer parsed.deinit();
    const users = parsed.value.object.get("users").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), users.len);
    try std.testing.expectEqual(@as(i64, 4), users[0].object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 7), users[0].object.get("statistics_rulesets").?.object.get("osu").?.object.get("global_rank").?.integer);
    try std.testing.expectEqual(@as(i64, 4_452_992), users[1].object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 50_128), users[1].object.get("statistics_rulesets").?.object.get("osu").?.object.get("global_rank").?.integer);
    try std.testing.expectEqual(@as(i64, 3), users[2].object.get("id").?.integer);
    try std.testing.expect(users[2].object.get("is_bot").?.bool);
    try std.testing.expect(!users[2].object.get("statistics_rulesets").?.object.get("osu").?.object.get("is_ranked").?.bool);
    try std.testing.expect(users[2].object.get("statistics_rulesets").?.object.get("osu").?.object.get("global_rank").? == .null);
}

test "lazer beatmap listing filters map to the mirror contract" {
    try std.testing.expectEqualStrings("1,2,3,4", (try lazer.beatmapSearchCategory("leaderboard")).upstream_status.?);
    try std.testing.expectEqualStrings("1,2", (try lazer.beatmapSearchCategory("ranked")).upstream_status.?);
    try std.testing.expectEqualStrings("-1,0", (try lazer.beatmapSearchCategory("pending")).upstream_status.?);
    try std.testing.expectEqual(lazer.BeatmapSearchSource.favourites, (try lazer.beatmapSearchCategory("favourites")).source);
    try std.testing.expectEqual(lazer.BeatmapSearchSource.mine, (try lazer.beatmapSearchCategory("mine")).source);
    try std.testing.expectError(error.InvalidBeatmapSearchCategory, lazer.beatmapSearchCategory("approved"));
    try std.testing.expectEqualStrings("beatmaps.difficulty_rating:desc", (try lazer.beatmapSearchSort("difficulty_desc")).?);
    try std.testing.expectEqualStrings("last_updated:asc", (try lazer.beatmapSearchSort("updated_asc")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try lazer.beatmapSearchSort("relevance_desc"));
    try std.testing.expectError(error.InvalidBeatmapSearchSort, lazer.beatmapSearchSort("difficulty_sideways"));
}

test "lazer beatmap tags persist votes and expose the current user state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/lazer-tags.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(4,'raya','raya',x'00',x'00'); INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator) VALUES(75,75,'0123456789abcdef0123456789abcdef','artist','title','diff','mapper')");
    try std.testing.expect(try store.setLazerBeatmapTag(4, 75, 5, true));
    try std.testing.expect(!(try store.setLazerBeatmapTag(4, 75, 5, true)));
    const state = (try store.lazerBeatmapTagStateJson(std.testing.allocator, 4, 75)).?;
    defer std.testing.allocator.free(state);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, state, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 5), parsed.value.object.get("top_tag_ids").?.array.items[0].object.get("tag_id").?.integer);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("top_tag_ids").?.array.items[0].object.get("count").?.integer);
    try std.testing.expectEqual(@as(i64, 5), parsed.value.object.get("current_user_tag_ids").?.array.items[0].integer);
    try std.testing.expect(try store.setLazerBeatmapTag(4, 75, 5, false));
    try std.testing.expectError(error.InvalidBeatmapTag, store.setLazerBeatmapTag(4, 75, 99, true));
    try std.testing.expectError(error.BeatmapNotFound, store.setLazerBeatmapTag(4, 76, 5, true));
}

test "official lazer score bodies allow omitted mods and reject hostile counters" {
    const valid = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"rank\":\"A\",\"total_score\":987654,\"total_score_without_mods\":900000,\"accuracy\":0.985,\"max_combo\":321,\"ruleset_id\":0,\"passed\":true,\"statistics\":{\"great\":300,\"miss\":2},\"maximum_statistics\":{\"great\":302},\"pauses\":[-1913,2000]}", .{});
    defer valid.deinit();
    const input = try lazer.parseSoloScore(valid.value, 75);
    try std.testing.expectEqual(@as(i64, 75), input.beatmap_id);
    try std.testing.expectEqual(@as(i64, 900000), input.total_score_without_mods);
    try std.testing.expectEqual(@as(?i32, null), input.legacy_total_score);
    try std.testing.expect(input.mods == null);
    try std.testing.expectEqual(lazer.Namespace.vanilla, input.namespace);
    try std.testing.expectEqual(@as(i64, 302), input.maximum_statistics.?.get("great").?.integer);
    try std.testing.expectEqual(@as(i64, -1913), input.pauses.?.items[0].integer);
    try std.testing.expectEqual(@as(i32, 3_032_606), lazer.classicTotalScore(input));
    var taiko = input;
    taiko.ruleset_id = 1;
    try std.testing.expectEqual(@as(i32, 429_549), lazer.classicTotalScore(taiko));
    var catch_score = input;
    catch_score.ruleset_id = 2;
    try std.testing.expectEqual(@as(i32, 2_022_208), lazer.classicTotalScore(catch_score));
    var mania = input;
    mania.ruleset_id = 3;
    try std.testing.expectEqual(@as(i32, 987_654), lazer.classicTotalScore(mania));

    const invalid = [_][]const u8{
        "{\"rank\":\"SSS\",\"total_score\":1,\"total_score_without_mods\":1,\"accuracy\":1,\"max_combo\":1,\"ruleset_id\":0,\"passed\":true,\"statistics\":{},\"maximum_statistics\":{},\"pauses\":[]}",
        "{\"rank\":\"A\",\"total_score\":1,\"total_score_without_mods\":1,\"accuracy\":1,\"max_combo\":1,\"ruleset_id\":0,\"passed\":true,\"statistics\":{\"great\":100000001},\"maximum_statistics\":{},\"pauses\":[]}",
        "{\"rank\":\"A\",\"total_score\":1,\"total_score_without_mods\":1,\"accuracy\":1,\"max_combo\":1,\"ruleset_id\":0,\"passed\":true,\"statistics\":{\"made_up\":1},\"maximum_statistics\":{},\"pauses\":[]}",
        "{\"rank\":\"A\",\"total_score\":1,\"total_score_without_mods\":1,\"accuracy\":1,\"max_combo\":1,\"ruleset_id\":0,\"passed\":true,\"statistics\":{},\"maximum_statistics\":{},\"pauses\":[-2147483649]}",
    };
    for (invalid) |fixture| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fixture, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidScore, lazer.parseSoloScore(parsed.value, 75));
    }
    const invalid_mod = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"rank\":\"A\",\"total_score\":1,\"total_score_without_mods\":1,\"accuracy\":1,\"max_combo\":1,\"ruleset_id\":0,\"passed\":true,\"mods\":[{\"acronym\":\"RX\",\"settings\":1}],\"statistics\":{},\"maximum_statistics\":{},\"pauses\":[]}", .{});
    defer invalid_mod.deinit();
    try std.testing.expectError(error.InvalidMod, lazer.parseSoloScore(invalid_mod.value, 75));
}

test "lazer performance state maps official hit results and legacy mods" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"rank\":\"A\",\"total_score\":987654,\"total_score_without_mods\":900000,\"accuracy\":0.985,\"max_combo\":321,\"ruleset_id\":0,\"passed\":true,\"mods\":[{\"acronym\":\"HD\"},{\"acronym\":\"NC\"}],\"statistics\":{\"great\":300,\"ok\":10,\"meh\":2,\"miss\":1,\"large_tick_hit\":40,\"small_tick_hit\":20,\"slider_tail_hit\":15},\"maximum_statistics\":{\"great\":313},\"pauses\":[]}", .{});
    defer parsed.deinit();
    const input = try lazer.parseSoloScore(parsed.value, 75);
    const state = (try lazer.performanceState(input)).?;
    try std.testing.expectEqual((@as(u32, 1) << 3) | (@as(u32, 1) << 6) | (@as(u32, 1) << 9), state.mods);
    try std.testing.expectEqual(@as(u32, 300), state.n300);
    try std.testing.expectEqual(@as(u32, 10), state.n100);
    try std.testing.expectEqual(@as(u32, 2), state.n50);
    try std.testing.expectEqual(@as(u32, 1), state.misses);
    try std.testing.expectEqual(@as(u32, 40), state.large_tick_hits);
    try std.testing.expectEqual(@as(u32, 20), state.small_tick_hits);
    try std.testing.expectEqual(@as(u32, 15), state.slider_end_hits);

    const output = try pp.calculateLazer(@embedFile("testdata/synthetic-standard.osu"), "[{\"acronym\":\"HD\"},{\"acronym\":\"NC\"}]", .{
        .mode = 0,
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
    });
    try std.testing.expect(output.pp > 0);
    try std.testing.expect(output.stars > 0);
    try std.testing.expectError(error.PerformanceCalculationFailed, pp.calculateLazer(@embedFile("testdata/synthetic-standard.osu"), "[{\"acronym\":\"WIGGLE\"}]", .{
        .mode = 0,
        .lazer = 1,
        .mods = 0,
        .max_combo = 1,
        .n_geki = 0,
        .n_katu = 0,
        .n300 = 1,
        .n100 = 0,
        .n50 = 0,
        .misses = 0,
        .legacy_total_score = 1,
    }));
}

test "lazer mod display keeps custom DT and NC rates for announcements" {
    const dt = try lazer.modsDisplay(std.testing.allocator, "[{\"acronym\":\"DT\",\"settings\":{\"speed_change\":1.25}}]");
    defer std.testing.allocator.free(dt);
    try std.testing.expectEqualStrings("+DT 1.25×", dt);

    const nc = try lazer.modsDisplay(std.testing.allocator, "[{\"acronym\":\"HD\"},{\"acronym\":\"NC\",\"settings\":{\"speed_change\":1.75}}]");
    defer std.testing.allocator.free(nc);
    try std.testing.expectEqualStrings("+HDNC 1.75×", nc);
}

test "vanilla lazer performance matches the pinned 2026.730.0 calculator" {
    const Fixture = struct {
        mode: u8,
        map: []const u8,
        n_geki: u32,
        n300: u32,
        expected_pp: f64,
        expected_stars: f64,
        expected_combo: u32,
    };
    const fixtures = [_]Fixture{
        .{ .mode = 0, .map = @embedFile("testdata/synthetic-standard.osu"), .n_geki = 0, .n300 = 10, .expected_pp = 26.261725765606, .expected_stars = 1.668327341539, .expected_combo = 10 },
        .{ .mode = 1, .map = @embedFile("testdata/synthetic-taiko.osu"), .n_geki = 0, .n300 = 10, .expected_pp = 15.285055735482, .expected_stars = 0.641015656768, .expected_combo = 10 },
        .{ .mode = 2, .map = @embedFile("testdata/synthetic-catch.osu"), .n_geki = 0, .n300 = 10, .expected_pp = 1.931569795540, .expected_stars = 0.445536567353, .expected_combo = 10 },
        .{ .mode = 3, .map = @embedFile("testdata/synthetic-mania.osu"), .n_geki = 10, .n300 = 0, .expected_pp = 0.740323178018, .expected_stars = 0.488838504148, .expected_combo = 20 },
    };
    for (fixtures) |fixture| {
        const output = try pp.calculateLazer(fixture.map, "[]", .{
            .mode = fixture.mode,
            .lazer = 1,
            .mods = 0,
            .max_combo = 10,
            .n_geki = fixture.n_geki,
            .n_katu = 0,
            .n300 = fixture.n300,
            .n100 = 0,
            .n50 = 0,
            .misses = 0,
            .legacy_total_score = 0,
        });
        try std.testing.expectApproxEqAbs(fixture.expected_pp, output.pp, 0.0000001);
        try std.testing.expectApproxEqAbs(fixture.expected_stars, output.stars, 0.0000001);
        try std.testing.expectEqual(fixture.expected_combo, output.max_combo);
    }

    const custom_rate = try pp.calculateLazer(@embedFile("testdata/synthetic-standard.osu"), "[{\"acronym\":\"DT\",\"settings\":{\"speed_change\":1.25}}]", .{
        .mode = 0,
        .lazer = 1,
        .mods = 1 << 6,
        .max_combo = 10,
        .n_geki = 0,
        .n_katu = 0,
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .misses = 0,
        .legacy_total_score = 0,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 39.036597621743), custom_rate.pp, 0.0000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.703730093981), custom_rate.stars, 0.0000001);

    const nightcore_custom_rate = try pp.calculateLazer(@embedFile("testdata/synthetic-standard.osu"), "[{\"acronym\":\"NC\",\"settings\":{\"speed_change\":1.25}}]", .{
        .mode = 0,
        .lazer = 1,
        .mods = (1 << 6) | (1 << 9),
        .max_combo = 10,
        .n_geki = 0,
        .n_katu = 0,
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .misses = 0,
        .legacy_total_score = 0,
    });
    try std.testing.expectApproxEqAbs(custom_rate.pp, nightcore_custom_rate.pp, 0.0000001);
    try std.testing.expectApproxEqAbs(custom_rate.stars, nightcore_custom_rate.stars, 0.0000001);

    const dt_slow = try pp.calculateLazer(@embedFile("testdata/synthetic-standard.osu"), "[{\"acronym\":\"DT\",\"settings\":{\"speed_change\":1.10}}]", .{
        .mode = 0,
        .lazer = 1,
        .mods = 1 << 6,
        .max_combo = 10,
        .n_geki = 0,
        .n_katu = 0,
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .misses = 0,
        .legacy_total_score = 0,
    });
    const dt_fast = try pp.calculateLazer(@embedFile("testdata/synthetic-standard.osu"), "[{\"acronym\":\"DT\",\"settings\":{\"speed_change\":1.90}}]", .{
        .mode = 0,
        .lazer = 1,
        .mods = 1 << 6,
        .max_combo = 10,
        .n_geki = 0,
        .n_katu = 0,
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .misses = 0,
        .legacy_total_score = 0,
    });
    const nc_slow = try pp.calculateLazer(@embedFile("testdata/synthetic-standard.osu"), "[{\"acronym\":\"NC\",\"settings\":{\"speed_change\":1.10}}]", .{
        .mode = 0,
        .lazer = 1,
        .mods = (1 << 6) | (1 << 9),
        .max_combo = 10,
        .n_geki = 0,
        .n_katu = 0,
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .misses = 0,
        .legacy_total_score = 0,
    });
    const nc_fast = try pp.calculateLazer(@embedFile("testdata/synthetic-standard.osu"), "[{\"acronym\":\"NC\",\"settings\":{\"speed_change\":1.90}}]", .{
        .mode = 0,
        .lazer = 1,
        .mods = (1 << 6) | (1 << 9),
        .max_combo = 10,
        .n_geki = 0,
        .n_katu = 0,
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .misses = 0,
        .legacy_total_score = 0,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 31.801852944415), dt_slow.pp, 0.0000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.744607222530), dt_slow.stars, 0.0000001);
    try std.testing.expectApproxEqAbs(@as(f64, 71.644213191228), dt_fast.pp, 0.0000001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.098350925561), dt_fast.stars, 0.0000001);
    try std.testing.expect(dt_slow.pp < custom_rate.pp);
    try std.testing.expect(dt_fast.pp > custom_rate.pp);
    try std.testing.expectApproxEqAbs(dt_slow.pp, nc_slow.pp, 0.0000001);
    try std.testing.expectApproxEqAbs(dt_fast.pp, nc_fast.pp, 0.0000001);
    try std.testing.expectApproxEqAbs(dt_slow.stars, nc_slow.stars, 0.0000001);
    try std.testing.expectApproxEqAbs(dt_fast.stars, nc_fast.stars, 0.0000001);
}

test "lazer solo score tokens are user bound expiring and single use" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/lazer-score-token.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(1,'ari','ari',x'00',x'00'),(2,'raya','raya',x'00',x'00'); INSERT INTO teams(id,name,short_name,leader_id) VALUES(7,'uwu team','uwu',1); INSERT INTO team_members(user_id,team_id) VALUES(1,7); INSERT INTO team_assets(team_id,kind,object_key,content_type,etag,width,height,updated_at) VALUES(7,'flag','teams/7/flag.png','image/png','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',64,32,42); INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status) VALUES(75,75,'0123456789abcdef0123456789abcdef','artist','title','diff','mapper',3)");

    const raw = "{\"rank\":\"A\",\"total_score\":987654,\"total_score_without_mods\":900000,\"accuracy\":0.985,\"max_combo\":321,\"ruleset_id\":0,\"passed\":true,\"mods\":[{\"acronym\":\"RX\"},{\"acronym\":\"WIGGLE\",\"settings\":{\"strength\":1.25}}],\"statistics\":{\"great\":300,\"miss\":2},\"maximum_statistics\":{\"great\":302},\"pauses\":[]}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const score = try lazer.parseSoloScore(parsed.value, 75);
    const mods_json = try lazer.jsonField(std.testing.allocator, parsed.value.object, "mods", "[]");
    defer std.testing.allocator.free(mods_json);
    const statistics_json = try lazer.jsonField(std.testing.allocator, parsed.value.object, "statistics", "{}");
    defer std.testing.allocator.free(statistics_json);
    const maximum_statistics_json = try lazer.jsonField(std.testing.allocator, parsed.value.object, "maximum_statistics", "{}");
    defer std.testing.allocator.free(maximum_statistics_json);
    const pauses_json = try lazer.jsonField(std.testing.allocator, parsed.value.object, "pauses", "[]");
    defer std.testing.allocator.free(pauses_json);

    try std.testing.expectError(error.BeatmapHashMismatch, store.createLazerScoreToken(1, 75, "ffffffffffffffffffffffffffffffff", 0, "11111111111111111111111111111111"));
    try std.testing.expectError(error.BeatmapNotFound, store.createLazerScoreToken(1, 76, "0123456789abcdef0123456789abcdef", 0, "11111111111111111111111111111111"));
    const token = try store.createLazerScoreToken(1, 75, "0123456789ABCDEF0123456789ABCDEF", 0, "11111111111111111111111111111111");
    try std.testing.expectError(error.ForeignLazerScoreToken, store.submitLazerScoreToken(2, 75, token, score, 0, mods_json, statistics_json, maximum_statistics_json, pauses_json, &.{}));
    var wrong_ruleset = score;
    wrong_ruleset.ruleset_id = 1;
    try std.testing.expectError(error.LazerScoreTokenMismatch, store.submitLazerScoreToken(1, 75, token, wrong_ruleset, 0, mods_json, statistics_json, maximum_statistics_json, pauses_json, &.{}));
    var replay: [32]u8 = @splat(0);
    replay[0] = 0;
    std.mem.writeInt(i32, replay[1..5], 20_260_816, .little);
    const score_id = try store.submitLazerScoreToken(1, 75, token, score, 0, mods_json, statistics_json, maximum_statistics_json, pauses_json, &replay);
    try std.testing.expect(score_id > 0);
    try std.testing.expectError(error.LazerScoreTokenUsed, store.submitLazerScoreToken(1, 75, token, score, 0, mods_json, statistics_json, maximum_statistics_json, pauses_json, &.{}));
    try std.testing.expectError(error.InvalidLazerScoreToken, store.submitLazerScoreToken(1, 75, token + 2, score, 0, mods_json, statistics_json, "{}", "[]", &.{}));

    var row: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "SELECT mods_json,statistics_json,replay FROM lazer_scores WHERE id=?1", -1, &row, null));
    _ = storage.c.sqlite3_bind_int64(row, 1, score_id);
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(row));
    try std.testing.expectEqualStrings(mods_json, std.mem.span(storage.c.sqlite3_column_text(row, 0)));
    try std.testing.expectEqualStrings(statistics_json, std.mem.span(storage.c.sqlite3_column_text(row, 1)));
    const replay_len: usize = @intCast(storage.c.sqlite3_column_bytes(row, 2));
    const replay_ptr: [*]const u8 = @ptrCast(storage.c.sqlite3_column_blob(row, 2).?);
    try std.testing.expectEqualSlices(u8, &replay, replay_ptr[0..replay_len]);
    _ = storage.c.sqlite3_finalize(row);

    const leaderboard = try store.lazerLeaderboardJson(std.testing.allocator, 1, 75, 0, .custom, "[\"RX\",\"WIGGLE\"]", true, false, null, .global, 50);
    defer std.testing.allocator.free(leaderboard);
    var parsed_leaderboard = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, leaderboard, .{});
    defer parsed_leaderboard.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed_leaderboard.value.object.get("score_count").?.integer);
    const listed = parsed_leaderboard.value.object.get("scores").?.array.items[0].object;
    try std.testing.expectEqual(score_id, listed.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 987654), listed.get("total_score").?.integer);
    try std.testing.expectEqual(@as(i64, 900000), listed.get("total_score_without_mods").?.integer);
    try std.testing.expectEqual(@as(i64, 3032606), listed.get("legacy_total_score").?.integer);
    try std.testing.expectEqualStrings("A", listed.get("rank").?.string);
    try std.testing.expectEqual(@as(i64, 302), listed.get("maximum_statistics").?.object.get("great").?.integer);
    try std.testing.expect(listed.get("ranked").?.bool);
    try std.testing.expect(listed.get("has_replay").?.bool);
    const leaderboard_team = listed.get("user").?.object.get("team").?.object;
    try std.testing.expectEqual(@as(i64, 7), leaderboard_team.get("id").?.integer);
    try std.testing.expectEqualStrings("uwu", leaderboard_team.get("short_name").?.string);
    try std.testing.expectEqualStrings("https://assets.kai.ovh/teams/7/flag?v=42", leaderboard_team.get("flag_url").?.string);
    try std.testing.expectEqual(@as(i64, 1), parsed_leaderboard.value.object.get("user_score").?.object.get("position").?.integer);

    const counts = try store.lazerUserScoreCounts(1, 0, .all);
    try std.testing.expectEqual(@as(i32, 0), counts.best);
    try std.testing.expectEqual(@as(i32, 1), counts.recent);
    const recent = try store.lazerUserScoresJson(std.testing.allocator, 1, 0, .recent, .all, 0, 50);
    defer std.testing.allocator.free(recent);
    const parsed_recent = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, recent, .{});
    defer parsed_recent.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_recent.value.array.items.len);
    const recent_score = parsed_recent.value.array.items[0].object;
    try std.testing.expectEqual(score_id, recent_score.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 987654), recent_score.get("total_score").?.integer);
    try std.testing.expectEqual(@as(i64, 900000), recent_score.get("total_score_without_mods").?.integer);
    try std.testing.expectEqual(@as(i64, 3032606), recent_score.get("legacy_total_score").?.integer);
    try std.testing.expectEqual(@as(i64, 75), recent_score.get("beatmap").?.object.get("id").?.integer);
    try std.testing.expectEqualStrings("artist", recent_score.get("beatmap").?.object.get("beatmapset").?.object.get("artist").?.string);
    try std.testing.expect(recent_score.get("preserve").?.bool);
    try std.testing.expect(recent_score.get("has_replay").?.bool);
    const score_detail = (try store.lazerScoreJson(std.testing.allocator, score_id, 75)).?;
    defer std.testing.allocator.free(score_detail);
    const parsed_score_detail = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, score_detail, .{});
    defer parsed_score_detail.deinit();
    try std.testing.expectEqual(@as(i64, 987654), parsed_score_detail.value.object.get("total_score").?.integer);
    try std.testing.expectEqual(@as(i64, 900000), parsed_score_detail.value.object.get("total_score_without_mods").?.integer);
    try std.testing.expectEqual(@as(i64, 3032606), parsed_score_detail.value.object.get("legacy_total_score").?.integer);
    const stored_replay = (try store.lazerReplay(std.testing.allocator, score_id)).?;
    defer std.testing.allocator.free(stored_replay);
    try std.testing.expectEqualSlices(u8, &replay, stored_replay);
    const pinned = try store.lazerUserScoresJson(std.testing.allocator, 1, 0, .pinned, .all, 0, 50);
    defer std.testing.allocator.free(pinned);
    try std.testing.expectEqualStrings("[]", pinned);

    try store.exec("UPDATE beatmaps SET status=3 WHERE id=75; INSERT INTO scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,rank_namespace,best) VALUES(1,'0123456789abcdef0123456789abcdef',0,8,765432,123.5,0.975,300,300,10,2,1,0,0,0,1,x'7265706c6179','vanilla',1); INSERT INTO score_pins(user_id,score_id) VALUES(1,last_insert_rowid()); INSERT INTO profile_score_pins(user_id,source,score_id,mode,rank_namespace) SELECT 1,'stable',max(id),0,'vanilla' FROM scores; INSERT INTO lazer_scores(user_id,beatmap_id,ruleset_id,total_score,total_score_without_mods,legacy_total_score,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,pp,best,rank_namespace,client_version,replay,submitted_at) VALUES(1,75,0,500000,500000,NULL,0.99,350,1,'S','[]','{}','{}','[]',250.25,1,'vanilla','combined-profile-test',x'',unixepoch()-20)");
    const combined_best = try store.lazerUserScoresJson(std.testing.allocator, 1, 0, .best, .all, 0, 50);
    defer std.testing.allocator.free(combined_best);
    var parsed_combined_best = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, combined_best, .{});
    defer parsed_combined_best.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_combined_best.value.array.items.len);
    try std.testing.expectEqual(@as(f64, 250.25), parsed_combined_best.value.array.items[0].object.get("pp").?.float);
    try std.testing.expect(parsed_combined_best.value.array.items[0].object.get("id").?.integer < 4_000_000_000_000_000_000);
    try std.testing.expect(parsed_combined_best.value.array.items[0].object.get("preserve").?.bool);
    const combined_firsts = try store.lazerUserScoresJson(std.testing.allocator, 1, 0, .firsts, .all, 0, 50);
    defer std.testing.allocator.free(combined_firsts);
    var parsed_combined_firsts = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, combined_firsts, .{});
    defer parsed_combined_firsts.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_combined_firsts.value.array.items.len);
    try std.testing.expectEqual(@as(f64, 250.25), parsed_combined_firsts.value.array.items[0].object.get("pp").?.float);
    try store.exec("INSERT INTO scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,rank_namespace,best,submitted_at) VALUES(2,'0123456789abcdef0123456789abcdef',0,0,900000,100,0.98,310,300,10,2,1,0,0,0,1,x'','vanilla',1,unixepoch()-10)");
    const displaced_firsts = try store.lazerUserScoresJson(std.testing.allocator, 1, 0, .firsts, .all, 0, 50);
    defer std.testing.allocator.free(displaced_firsts);
    try std.testing.expectEqualStrings("[]", displaced_firsts);
    const combined_recent = try store.lazerUserScoresJson(std.testing.allocator, 1, 0, .recent, .all, 0, 50);
    defer std.testing.allocator.free(combined_recent);
    var parsed_combined = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, combined_recent, .{});
    defer parsed_combined.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed_combined.value.array.items.len);
    const stable_profile_score = parsed_combined.value.array.items[0].object;
    try std.testing.expect(stable_profile_score.get("id").?.integer >= 4_000_000_000_000_000_000);
    try std.testing.expectEqualStrings("A", stable_profile_score.get("rank").?.string);
    try std.testing.expectEqualStrings("CL", stable_profile_score.get("mods").?.array.items[0].object.get("acronym").?.string);
    try std.testing.expect(stable_profile_score.get("preserve").?.bool);
    try std.testing.expect(stable_profile_score.get("has_replay").?.bool);
    const stable_public_id = stable_profile_score.get("id").?.integer;
    const stable_raw_id = lazer.decodeStableScoreId(stable_public_id).?;
    const stable_replay = (try store.siteReplay(std.testing.allocator, stable_raw_id)).?;
    defer std.testing.allocator.free(stable_replay);
    try std.testing.expect(std.mem.indexOf(u8, stable_replay, "replay") != null);
    const stable_recent = try store.lazerUserScoresJson(std.testing.allocator, 1, 0, .recent, .stable, 0, 50);
    defer std.testing.allocator.free(stable_recent);
    var parsed_stable_recent = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stable_recent, .{});
    defer parsed_stable_recent.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_stable_recent.value.array.items.len);
    try std.testing.expect(parsed_stable_recent.value.array.items[0].object.get("id").?.integer >= 4_000_000_000_000_000_000);
    const lazer_recent = try store.lazerUserScoresJson(std.testing.allocator, 1, 0, .recent, .lazer, 0, 50);
    defer std.testing.allocator.free(lazer_recent);
    var parsed_lazer_recent = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lazer_recent, .{});
    defer parsed_lazer_recent.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed_lazer_recent.value.array.items.len);
    var custom_score_found = false;
    for (parsed_lazer_recent.value.array.items) |item| {
        if (item.object.get("id").?.integer == score_id) custom_score_found = true;
    }
    try std.testing.expect(custom_score_found);
    try store.setScorePinnedById(1, .lazer, score_id, true);
    try store.exec("UPDATE profile_score_pins SET pinned_at=10 WHERE source='stable'; UPDATE profile_score_pins SET pinned_at=20 WHERE source='lazer'");
    const pinned_before_repin = try store.lazerUserScoresJson(std.testing.allocator, 1, 0, .pinned, .all, 0, 1);
    defer std.testing.allocator.free(pinned_before_repin);
    var parsed_pinned_before_repin = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, pinned_before_repin, .{});
    defer parsed_pinned_before_repin.deinit();
    try std.testing.expectEqual(score_id, parsed_pinned_before_repin.value.array.items[0].object.get("id").?.integer);
    try store.setScorePinnedById(1, .stable, stable_raw_id, true);
    const pinned_first_page = try store.lazerUserScoresJson(std.testing.allocator, 1, 0, .pinned, .all, 0, 1);
    defer std.testing.allocator.free(pinned_first_page);
    var parsed_pinned_first_page = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, pinned_first_page, .{});
    defer parsed_pinned_first_page.deinit();
    try std.testing.expectEqual(stable_public_id, parsed_pinned_first_page.value.array.items[0].object.get("id").?.integer);
    const pinned_second_page = try store.lazerUserScoresJson(std.testing.allocator, 1, 0, .pinned, .all, 1, 1);
    defer std.testing.allocator.free(pinned_second_page);
    var parsed_pinned_second_page = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, pinned_second_page, .{});
    defer parsed_pinned_second_page.deinit();
    try std.testing.expectEqual(score_id, parsed_pinned_second_page.value.array.items[0].object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 900000), parsed_pinned_second_page.value.array.items[0].object.get("total_score_without_mods").?.integer);
    try std.testing.expectEqual(@as(i64, 3032606), parsed_pinned_second_page.value.array.items[0].object.get("legacy_total_score").?.integer);
    const stable_pinned = try store.lazerUserScoresJson(std.testing.allocator, 1, 0, .pinned, .stable, 0, 50);
    defer std.testing.allocator.free(stable_pinned);
    var parsed_pinned = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stable_pinned, .{});
    defer parsed_pinned.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_pinned.value.array.items.len);
    const combined_counts = try store.lazerUserScoreCounts(1, 0, .all);
    const stable_counts = try store.lazerUserScoreCounts(1, 0, .stable);
    const lazer_counts = try store.lazerUserScoreCounts(1, 0, .lazer);
    try std.testing.expectEqual(@as(i32, 1), combined_counts.best);
    try std.testing.expectEqual(@as(i32, 0), combined_counts.firsts);
    try std.testing.expectEqual(@as(i32, 3), combined_counts.recent);
    try std.testing.expectEqual(@as(i32, 2), combined_counts.pinned);
    try std.testing.expectEqual(@as(i32, 1), stable_counts.best);
    try std.testing.expectEqual(@as(i32, 0), stable_counts.firsts);
    try std.testing.expectEqual(@as(i32, 1), stable_counts.recent);
    try std.testing.expectEqual(@as(i32, 1), stable_counts.pinned);
    try std.testing.expectEqual(@as(i32, 1), lazer_counts.best);
    try std.testing.expectEqual(@as(i32, 1), lazer_counts.firsts);
    try std.testing.expectEqual(@as(i32, 2), lazer_counts.recent);
    try std.testing.expectEqual(@as(i32, 1), lazer_counts.pinned);
    const monthly = try store.lazerMonthlyPlaycountsJson(std.testing.allocator, 1);
    defer std.testing.allocator.free(monthly);
    var parsed_monthly = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, monthly, .{});
    defer parsed_monthly.deinit();
    var monthly_total: i64 = 0;
    for (parsed_monthly.value.array.items) |item| monthly_total += item.object.get("count").?.integer;
    try std.testing.expectEqual(@as(i64, 3), monthly_total);

    try std.testing.expect(try store.setLazerBeatmapTag(1, 75, 5, true));
    const owner_most_played = try store.lazerMostPlayedJson(std.testing.allocator, 1, 1, 0, 50);
    defer std.testing.allocator.free(owner_most_played);
    var parsed_owner_most_played = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, owner_most_played, .{});
    defer parsed_owner_most_played.deinit();
    try std.testing.expectEqual(@as(i64, 5), parsed_owner_most_played.value.array.items[0].object.get("beatmap").?.object.get("current_user_tag_ids").?.array.items[0].integer);
    const outsider_most_played = try store.lazerMostPlayedJson(std.testing.allocator, 1, 2, 0, 50);
    defer std.testing.allocator.free(outsider_most_played);
    var parsed_outsider_most_played = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, outsider_most_played, .{});
    defer parsed_outsider_most_played.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed_outsider_most_played.value.array.items[0].object.get("beatmap").?.object.get("current_user_tag_ids").?.array.items.len);

    const classic_board = try store.lazerLeaderboardJson(std.testing.allocator, 1, 75, 0, .vanilla, "[\"HD\"]", true, true, stable_mods.hidden, .global, 50);
    defer std.testing.allocator.free(classic_board);
    var parsed_classic = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, classic_board, .{});
    defer parsed_classic.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed_classic.value.object.get("score_count").?.integer);
    try std.testing.expectEqualStrings("CL", parsed_classic.value.object.get("scores").?.array.items[0].object.get("mods").?.array.items[0].object.get("acronym").?.string);
    try std.testing.expectEqualStrings("https://assets.kai.ovh/teams/7/flag?v=42", parsed_classic.value.object.get("scores").?.array.items[0].object.get("user").?.object.get("team").?.object.get("flag_url").?.string);

    const expired = try store.createLazerScoreToken(1, 75, "0123456789abcdef0123456789abcdef", 0, "22222222222222222222222222222222");
    var expire_buf: [160]u8 = undefined;
    const expire_sql = try std.fmt.bufPrintZ(&expire_buf, "UPDATE lazer_score_tokens SET expires_at=0 WHERE id={d}", .{expired});
    try store.exec(expire_sql);
    try std.testing.expectError(error.LazerScoreTokenExpired, store.submitLazerScoreToken(1, 75, expired, score, 0, mods_json, statistics_json, "{}", "[]", &.{}));

    var failed_score = score;
    failed_score.passed = false;
    failed_score.rank = "F";
    const failed_token = try store.createLazerScoreToken(1, 75, "0123456789abcdef0123456789abcdef", 0, "33333333333333333333333333333333");
    const failed_id = try store.submitLazerScoreToken(1, 75, failed_token, failed_score, 0, mods_json, statistics_json, maximum_statistics_json, pauses_json, &replay);
    var failed_row: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "SELECT passed,length(replay) FROM lazer_scores WHERE id=?1", -1, &failed_row, null));
    _ = storage.c.sqlite3_bind_int64(failed_row, 1, failed_id);
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(failed_row));
    try std.testing.expectEqual(@as(c_int, 0), storage.c.sqlite3_column_int(failed_row, 0));
    try std.testing.expectEqual(@as(c_int, replay.len), storage.c.sqlite3_column_int(failed_row, 1));
    _ = storage.c.sqlite3_finalize(failed_row);
    try std.testing.expect((try store.lazerReplay(std.testing.allocator, failed_id)) == null);
    const failed_recent = try store.lazerUserScoresJson(std.testing.allocator, 1, 0, .recent, .all, 0, 50);
    defer std.testing.allocator.free(failed_recent);
    var parsed_failed_recent = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, failed_recent, .{});
    defer parsed_failed_recent.deinit();
    var failed_recent_found = false;
    for (parsed_failed_recent.value.array.items) |item| {
        if (item.object.get("id").?.integer != failed_id) continue;
        failed_recent_found = true;
        try std.testing.expect(!item.object.get("preserve").?.bool);
        try std.testing.expect(!item.object.get("has_replay").?.bool);
    }
    try std.testing.expect(failed_recent_found);

    try store.exec("INSERT INTO scores(id,user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,checksum,rank_namespace,best) VALUES(999,1,'0123456789abcdef0123456789abcdef',0,0,10000,0,0.5,5,5,0,0,5,0,0,0,0,x'6661696c6564','failed-replay-checksum','vanilla',0)");
    try std.testing.expect((try store.stableReplay(std.testing.allocator, 999)) == null);
    try std.testing.expect((try store.siteReplay(std.testing.allocator, 999)) == null);
    var stored_failed: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "SELECT length(replay) FROM scores WHERE id=999", -1, &stored_failed, null));
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(stored_failed));
    try std.testing.expectEqual(@as(c_int, 6), storage.c.sqlite3_column_int(stored_failed, 0));
    _ = storage.c.sqlite3_finalize(stored_failed);

    var version_stmt: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "PRAGMA user_version", -1, &version_stmt, null));
    defer _ = storage.c.sqlite3_finalize(version_stmt);
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(version_stmt));
    try std.testing.expectEqual(@as(c_int, storage.schema_version), storage.c.sqlite3_column_int(version_stmt, 0));
}

test "ranked play ratings migrate and apply each room once per ruleset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/ranked-ratings.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();

    try store.migrate();
    try store.exec(sqlite_anticheat_exclusion_downgrade ++ "DROP TABLE lazer_ranked_matches; DROP TABLE lazer_ranked_ratings; PRAGMA user_version=38;");
    try store.migrate();
    try store.migrate();
    try store.exec("INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(10,'ranked winner','ranked_winner',x'00',x'00'),(11,'ranked loser','ranked_loser',x'00',x'00');");

    var version_stmt: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "SELECT (SELECT user_version FROM pragma_user_version),(SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN('lazer_ranked_ratings','lazer_ranked_matches'))", -1, &version_stmt, null));
    defer _ = storage.c.sqlite3_finalize(version_stmt);
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(version_stmt));
    try std.testing.expectEqual(@as(c_int, storage.schema_version), storage.c.sqlite3_column_int(version_stmt, 0));
    try std.testing.expectEqual(@as(c_int, 2), storage.c.sqlite3_column_int(version_stmt, 1));

    const initial = try store.lazerRankedRating(10, 0);
    try std.testing.expectEqual(@as(i32, 1500), initial.rating);
    try std.testing.expectEqual(@as(i32, 0), initial.games_played);
    try store.exec("INSERT INTO lazer_ranked_ratings(user_id,ruleset_id,rating) VALUES(10,0,1610)");

    const first = try store.applyLazerRankedResult(9001, 0, 10, 11);
    try std.testing.expect(first.applied);
    try std.testing.expectEqual(@as(i32, 1610), first.winner_rating_before);
    try std.testing.expectEqual(@as(i32, 1626), first.winner_rating_after);
    try std.testing.expectEqual(@as(i32, 1500), first.loser_rating_before);
    try std.testing.expectEqual(@as(i32, 1484), first.loser_rating_after);
    const repeated = try store.applyLazerRankedResult(9001, 0, 10, 11);
    try std.testing.expect(!repeated.applied);
    try std.testing.expectEqual(first.winner_rating_after, repeated.winner_rating_after);
    try std.testing.expectError(error.RankedPlayResultConflict, store.applyLazerRankedResult(9001, 0, 11, 10));

    const winner = try store.lazerRankedRating(10, 0);
    const loser = try store.lazerRankedRating(11, 0);
    try std.testing.expectEqual(@as(i32, 1626), winner.rating);
    try std.testing.expectEqual(@as(i32, 1), winner.games_played);
    try std.testing.expectEqual(@as(i32, 1), winner.wins);
    try std.testing.expectEqual(@as(i32, 0), winner.losses);
    try std.testing.expectEqual(@as(i32, 1484), loser.rating);
    try std.testing.expectEqual(@as(i32, 1), loser.losses);

    const other_ruleset = try store.applyLazerRankedResult(9002, 1, 11, 10);
    try std.testing.expect(other_ruleset.applied);
    try std.testing.expectEqual(@as(i32, 1516), other_ruleset.winner_rating_after);
    try std.testing.expectEqual(@as(i32, 1484), other_ruleset.loser_rating_after);
    try std.testing.expectEqual(@as(i32, 1626), (try store.lazerRankedRating(10, 0)).rating);
    try std.testing.expectEqual(@as(i32, 1484), (try store.lazerRankedRating(10, 1)).rating);
    try std.testing.expectEqual(@as(i64, 9003), try store.nextLazerMultiplayerRoomId());

    var integrity: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "PRAGMA integrity_check", -1, &integrity, null));
    defer _ = storage.c.sqlite3_finalize(integrity);
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(integrity));
    try std.testing.expectEqualStrings("ok", std.mem.span(storage.c.sqlite3_column_text(integrity, 0)));
}

test "schema forty widens chat read cursors and preserves public acknowledgements" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/room-read-migration.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("cursor migration", "cursor-migration@example.test", "0123456789abcdef0123456789abcdef");
    const public = try store.recordLazerPublicMessage(std.testing.allocator, user_id, "#osu", "kept public cursor", false, "40000000-0000-0000-0000-000000000001");
    defer std.testing.allocator.free(public.json);
    var parsed_public = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, public.json, .{});
    defer parsed_public.deinit();
    const public_id = parsed_public.value.object.get("message_id").?.integer;
    try store.markLazerChannelRead(user_id, 1, public_id);

    try store.exec(
        "BEGIN IMMEDIATE;" ++
            sqlite_anticheat_exclusion_downgrade ++
            "ALTER TABLE lazer_channel_reads RENAME TO lazer_channel_reads_v40;" ++
            "CREATE TABLE lazer_channel_reads(user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,channel_id INTEGER NOT NULL CHECK(channel_id BETWEEN 1 AND 4),last_read_id INTEGER NOT NULL DEFAULT 0,updated_at INTEGER NOT NULL DEFAULT (unixepoch()),PRIMARY KEY(user_id,channel_id));" ++
            "INSERT INTO lazer_channel_reads SELECT * FROM lazer_channel_reads_v40 WHERE channel_id BETWEEN 1 AND 4;" ++
            "DROP TABLE lazer_channel_reads_v40;" ++
            "PRAGMA user_version=39;" ++
            "COMMIT",
    );
    try store.migrate();
    try store.migrate();
    try std.testing.expectEqual(public_id, (try store.lazerChannelCursor(user_id, 1)).last_read_id.?);

    const room = try store.recordLazerRoomMessage(std.testing.allocator, user_id, 77, "wide room cursor", false, "40000000-0000-0000-0000-000000000002");
    defer std.testing.allocator.free(room.json);
    var parsed_room = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, room.json, .{});
    defer parsed_room.deinit();
    const room_id = parsed_room.value.object.get("message_id").?.integer;
    try store.markLazerRoomChannelRead(user_id, 77, room_id);
    try std.testing.expectEqual(room_id, (try store.lazerRoomChannelCursor(user_id, 77)).last_read_id.?);

    var schema: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "SELECT (SELECT user_version FROM pragma_user_version),(SELECT instr(sql,'2000000001') FROM sqlite_master WHERE type='table' AND name='lazer_channel_reads')", -1, &schema, null));
    defer _ = storage.c.sqlite3_finalize(schema);
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(schema));
    try std.testing.expectEqual(@as(c_int, storage.schema_version), storage.c.sqlite3_column_int(schema, 0));
    try std.testing.expect(storage.c.sqlite3_column_int(schema, 1) > 0);
}

test "schema forty two stores constrained profile history and replay views" {
    const expectConstraint = struct {
        fn run(db: *storage.c.sqlite3, sql: [:0]const u8) !void {
            var message: [*c]u8 = null;
            const result = storage.c.sqlite3_exec(db, sql.ptr, null, null, &message);
            if (message != null) storage.c.sqlite3_free(message);
            try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_CONSTRAINT), result);
        }
    }.run;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/profile-history-migration.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(sqlite_anticheat_exclusion_downgrade ++ "DROP TABLE score_replay_views; DROP TABLE user_stats_history; PRAGMA user_version=40;");
    try store.migrate();
    try store.migrate();

    const user_id = try store.register("history user", "history-user@example.test", "0123456789abcdef0123456789abcdef");
    const viewer_id = try store.register("history viewer", "history-viewer@example.test", "fedcba9876543210fedcba9876543210");
    var insert_buffer: [1024]u8 = undefined;
    const valid = try std.fmt.bufPrintZ(
        &insert_buffer,
        "INSERT INTO user_stats_history(user_id,source,mode,day,pp,global_rank) VALUES" ++
            "({d},'all',8,0,100,1)," ++
            "({d},'stable',6,0,90,2)," ++
            "({d},'lazer',8,86400,80,0)," ++
            "({d},'scorev2',3,0,70,3)",
        .{ user_id, user_id, user_id, user_id },
    );
    try store.exec(valid);

    const invalid = [_]struct {
        source: []const u8,
        mode: i32,
        day: i64,
        pp: i32,
        global_rank: i32,
    }{
        .{ .source = "unknown", .mode = 0, .day = 0, .pp = 1, .global_rank = 1 },
        .{ .source = "all", .mode = 7, .day = 0, .pp = 1, .global_rank = 1 },
        .{ .source = "scorev2", .mode = 4, .day = 0, .pp = 1, .global_rank = 1 },
        .{ .source = "stable", .mode = 0, .day = 1, .pp = 1, .global_rank = 1 },
        .{ .source = "lazer", .mode = 0, .day = 0, .pp = -1, .global_rank = 1 },
        .{ .source = "all", .mode = 0, .day = 0, .pp = 1, .global_rank = -1 },
    };
    for (invalid) |fixture| {
        var invalid_buffer: [384]u8 = undefined;
        const sql = try std.fmt.bufPrintZ(
            &invalid_buffer,
            "INSERT INTO user_stats_history(user_id,source,mode,day,pp,global_rank) VALUES({d},'{s}',{d},{d},{d},{d})",
            .{ user_id, fixture.source, fixture.mode, fixture.day, fixture.pp, fixture.global_rank },
        );
        try expectConstraint(store.db, sql);
    }
    var duplicate_buffer: [384]u8 = undefined;
    const duplicate = try std.fmt.bufPrintZ(&duplicate_buffer, "INSERT INTO user_stats_history(user_id,source,mode,day,pp,global_rank) VALUES({d},'all',8,0,1,1)", .{user_id});
    try expectConstraint(store.db, duplicate);
    var foreign_buffer: [384]u8 = undefined;
    const foreign = try std.fmt.bufPrintZ(&foreign_buffer, "INSERT INTO user_stats_history(user_id,source,mode,day,pp,global_rank) VALUES({d},'all',0,0,1,1)", .{user_id + 1000});
    try expectConstraint(store.db, foreign);

    var replay_buffer: [512]u8 = undefined;
    const valid_replay = try std.fmt.bufPrintZ(&replay_buffer, "INSERT INTO score_replay_views(source,score_id,viewer_id,owner_id,mode,rank_namespace) VALUES('stable',1,{d},{d},0,'vanilla')", .{ viewer_id, user_id });
    try store.exec(valid_replay);
    const self_replay = try std.fmt.bufPrintZ(&replay_buffer, "INSERT INTO score_replay_views(source,score_id,viewer_id,owner_id,mode,rank_namespace) VALUES('stable',2,{d},{d},0,'vanilla')", .{ user_id, user_id });
    try expectConstraint(store.db, self_replay);
    const invalid_replay_mode = try std.fmt.bufPrintZ(&replay_buffer, "INSERT INTO score_replay_views(source,score_id,viewer_id,owner_id,mode,rank_namespace) VALUES('lazer',3,{d},{d},7,'vanilla')", .{ viewer_id, user_id });
    try expectConstraint(store.db, invalid_replay_mode);
    const foreign_replay_viewer = try std.fmt.bufPrintZ(&replay_buffer, "INSERT INTO score_replay_views(source,score_id,viewer_id,owner_id,mode,rank_namespace) VALUES('lazer',4,{d},{d},0,'vanilla')", .{ user_id + 1000, user_id });
    try expectConstraint(store.db, foreign_replay_viewer);

    var schema: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "SELECT (SELECT user_version FROM pragma_user_version),(SELECT count(*) FROM sqlite_master WHERE type='table' AND name='user_stats_history'),(SELECT count(*) FROM sqlite_master WHERE type='index' AND name='user_stats_history_lookup'),(SELECT count(*) FROM user_stats_history),(SELECT count(*) FROM sqlite_master WHERE type='table' AND name='score_replay_views'),(SELECT count(*) FROM sqlite_master WHERE type='index' AND name='score_replay_views_owner'),(SELECT count(*) FROM score_replay_views),(SELECT count(*) FROM sqlite_master WHERE type='index' AND name='user_stats_history_retention'),(SELECT count(*) FROM sqlite_master WHERE type='index' AND name='friends_inbound')", -1, &schema, null));
    defer _ = storage.c.sqlite3_finalize(schema);
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(schema));
    try std.testing.expectEqual(@as(c_int, storage.schema_version), storage.c.sqlite3_column_int(schema, 0));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(schema, 1));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(schema, 2));
    try std.testing.expectEqual(@as(c_int, 4), storage.c.sqlite3_column_int(schema, 3));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(schema, 4));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(schema, 5));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(schema, 6));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(schema, 7));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(schema, 8));
}

test "schema forty four backfills Classic score without confusing score without mods" {
    const expectConstraint = struct {
        fn run(db: *storage.c.sqlite3, sql: [:0]const u8) !void {
            var message: [*c]u8 = null;
            const result = storage.c.sqlite3_exec(db, sql.ptr, null, null, &message);
            if (message != null) storage.c.sqlite3_free(message);
            try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_CONSTRAINT), result);
        }
    }.run;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/lazer-score-semantics-migration.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        sqlite_anticheat_exclusion_downgrade ++
            "DROP TRIGGER lazer_scores_legacy_total_score_insert;" ++
            "DROP TRIGGER lazer_scores_legacy_total_score_update;" ++
            "DROP TRIGGER lazer_scores_total_score_without_mods_insert;" ++
            "DROP TRIGGER lazer_scores_total_score_without_mods_update;" ++
            "ALTER TABLE lazer_scores DROP COLUMN total_score_without_mods;" ++
            "PRAGMA user_version=42;" ++
            "INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(1,'migration user','migration_user',x'00',x'00');" ++
            "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status) VALUES(75,75,'0123456789abcdef0123456789abcdef','artist','title','diff','mapper',3);" ++
            "INSERT INTO lazer_scores(id,user_id,beatmap_id,ruleset_id,total_score,legacy_total_score,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,rank_namespace) VALUES(1,1,75,0,987654,900000,0.98,321,1,'A','[]','{}','{}','[]','vanilla')",
    );
    try store.migrate();
    try store.migrate();

    var migrated: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "SELECT (SELECT user_version FROM pragma_user_version),total_score,total_score_without_mods,legacy_total_score FROM lazer_scores WHERE id=1", -1, &migrated, null));
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(migrated));
    try std.testing.expectEqual(@as(c_int, storage.schema_version), storage.c.sqlite3_column_int(migrated, 0));
    try std.testing.expectEqual(@as(i64, 987654), storage.c.sqlite3_column_int64(migrated, 1));
    try std.testing.expectEqual(@as(i64, 900000), storage.c.sqlite3_column_int64(migrated, 2));
    try std.testing.expectEqual(@as(i64, 98765), storage.c.sqlite3_column_int64(migrated, 3));
    _ = storage.c.sqlite3_finalize(migrated);
    try expectConstraint(store.db, "UPDATE lazer_scores SET legacy_total_score=2147483648 WHERE id=1");
    try expectConstraint(store.db, "UPDATE lazer_scores SET total_score_without_mods=1000000000001 WHERE id=1");

    try store.exec(
        sqlite_anticheat_exclusion_downgrade ++
            "DROP TRIGGER lazer_scores_legacy_total_score_insert;" ++
            "DROP TRIGGER lazer_scores_legacy_total_score_update;" ++
            "DROP TRIGGER lazer_scores_total_score_without_mods_insert;" ++
            "DROP TRIGGER lazer_scores_total_score_without_mods_update;" ++
            "UPDATE lazer_scores SET total_score_without_mods=0,legacy_total_score=765432 WHERE id=1;" ++
            "PRAGMA user_version=42;",
    );
    try store.migrate();
    try store.migrate();
    var repaired: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "SELECT (SELECT user_version FROM pragma_user_version),total_score_without_mods,legacy_total_score,(SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'lazer_scores_%score%') FROM lazer_scores WHERE id=1", -1, &repaired, null));
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(repaired));
    try std.testing.expectEqual(@as(c_int, storage.schema_version), storage.c.sqlite3_column_int(repaired, 0));
    try std.testing.expectEqual(@as(i64, 765432), storage.c.sqlite3_column_int64(repaired, 1));
    try std.testing.expectEqual(@as(i64, 98765), storage.c.sqlite3_column_int64(repaired, 2));
    try std.testing.expectEqual(@as(c_int, 4), storage.c.sqlite3_column_int(repaired, 3));
    _ = storage.c.sqlite3_finalize(repaired);

    try store.exec(sqlite_anticheat_exclusion_downgrade ++ "UPDATE lazer_scores SET total_score_without_mods=888000,legacy_total_score=777000 WHERE id=1; PRAGMA user_version=42;");
    try store.migrate();
    var compatible: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "SELECT (SELECT user_version FROM pragma_user_version),total_score_without_mods,legacy_total_score FROM lazer_scores WHERE id=1", -1, &compatible, null));
    defer _ = storage.c.sqlite3_finalize(compatible);
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(compatible));
    try std.testing.expectEqual(@as(c_int, storage.schema_version), storage.c.sqlite3_column_int(compatible, 0));
    try std.testing.expectEqual(@as(i64, 888000), storage.c.sqlite3_column_int64(compatible, 1));
    try std.testing.expectEqual(@as(i64, 777000), storage.c.sqlite3_column_int64(compatible, 2));
}

test "sqlite clamps high Stable scores in every lazer projection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/stable-lazer-clamp.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(1,'high score','high_score',x'00',x'00');" ++
            "INSERT INTO beatmaps(id,set_id,md5,mode,status,artist,title,version,creator) VALUES(75,75,'0123456789abcdef0123456789abcdef',0,3,'artist','title','diff','mapper');" ++
            "INSERT INTO scores(id,user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,rank_namespace,best) VALUES(700,1,'0123456789abcdef0123456789abcdef',0,0,3000000000,500,0.99,300,300,0,0,0,0,0,1,1,x'7265706c6179','vanilla',1)",
    );

    const recent_json = try store.lazerUserScoresJson(std.testing.allocator, 1, 0, .recent, .stable, 0, 50);
    defer std.testing.allocator.free(recent_json);
    var recent = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, recent_json, .{});
    defer recent.deinit();
    const recent_score = recent.value.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 3_000_000_000), recent_score.get("total_score").?.integer);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i32)), recent_score.get("legacy_total_score").?.integer);

    const board_json = try store.lazerLeaderboardJson(std.testing.allocator, 1, 75, 0, .vanilla, "[]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(board_json);
    var board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, board_json, .{});
    defer board.deinit();
    const board_score = board.value.object.get("scores").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 3_000_000_000), board_score.get("total_score").?.integer);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i32)), board_score.get("legacy_total_score").?.integer);
}

test "lazer leaderboards combine accepted mods inside each standard namespace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/lazer-exact-mods.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES" ++
            "(1,'ari','ari',x'00',x'00'),(2,'raya','raya',x'00',x'00'),(4,'mimi','mimi',x'00',x'00');" ++
            "UPDATE users SET country='AU' WHERE id IN(1,4); UPDATE users SET country='NZ' WHERE id=2;" ++
            "INSERT INTO teams(id,name,short_name,leader_id) VALUES(8,'scope team','scp',1);" ++
            "INSERT INTO team_members(user_id,team_id) VALUES(1,8),(4,8);" ++
            "INSERT INTO friends(user_id,friend_id) VALUES(1,2);" ++
            "INSERT INTO beatmaps(id,set_id,md5,status,artist,title,version,creator) VALUES" ++
            "(75,75,'0123456789abcdef0123456789abcdef',3,'artist','title','diff','mapper')," ++
            "(76,76,'1123456789abcdef0123456789abcdef',5,'artist','qualified','diff','mapper')," ++
            "(77,77,'2123456789abcdef0123456789abcdef',6,'artist','loved','diff','mapper');" ++
            "INSERT INTO lazer_scores(id,user_id,beatmap_id,ruleset_id,total_score,total_score_without_mods,legacy_total_score,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,rank_namespace,pp,best) VALUES" ++
            "(1,1,75,0,900,900,NULL,0.90,90,1,'A','[]','{}','{}','[]','vanilla',90,1)," ++
            "(2,1,75,0,500,500,NULL,0.95,50,1,'A','[{\"acronym\":\"HR\"}]','{}','{}','[]','vanilla',150,0)," ++
            "(3,2,75,0,700,700,NULL,0.97,70,1,'A','[{\"acronym\":\"HR\"}]','{}','{}','[]','vanilla',170,1)," ++
            "(4,2,75,0,100,100,NULL,0.80,10,1,'B','[]','{}','{}','[]','vanilla',20,0)," ++
            "(5,1,75,0,400,400,NULL,0.85,40,1,'B','[{\"acronym\":\"HR\"}]','{}','{}','[]','vanilla',100,0)," ++
            "(6,1,75,0,600,600,NULL,0.90,60,1,'A','[{\"acronym\":\"RX\"},{\"acronym\":\"WIGGLE\"}]','{}','{}','[]','custom',60,1)," ++
            "(7,2,75,0,800,800,NULL,0.98,80,1,'A','[{\"acronym\":\"WIGGLE\"},{\"acronym\":\"HR\"}]','{}','{}','[]','custom',80,1)," ++
            "(8,2,75,0,700,700,NULL,0.97,70,1,'A','[{\"acronym\":\"AP\"},{\"acronym\":\"WIGGLE\"}]','{}','{}','[]','custom',70,0)," ++
            "(9,1,76,0,900,900,NULL,0.99,90,1,'S','[]','{}','{}','[]','vanilla',190,1)," ++
            "(10,1,77,0,900,900,NULL,0.99,90,1,'S','[]','{}','{}','[]','vanilla',190,1);" ++
            "INSERT INTO scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,rank_namespace,best) VALUES" ++
            "(4,'0123456789abcdef0123456789abcdef',0,0,650,65,0.96,65,96,4,0,0,0,0,0,1,x'7265706c6179','vanilla',1)," ++
            "(1,'0123456789abcdef0123456789abcdef',0,0,550,55,0.95,55,95,5,0,0,0,0,0,1,x'7265706c6179','vanilla',1)," ++
            "(4,'0123456789abcdef0123456789abcdef',0,128,600,180,0.96,60,96,4,0,0,0,0,0,1,x'72656c61782d7265706c6179','relax',1)," ++
            "(1,'0123456789abcdef0123456789abcdef',0,136,580,170,0.95,58,95,5,0,0,0,0,0,1,x'68696464656e2d72656c6178','relax',1)," ++
            "(4,'0123456789abcdef0123456789abcdef',0,8192,620,190,0.97,62,97,3,0,0,0,0,0,1,x'6175746f70696c6f742d7265706c6179','autopilot',1)," ++
            "(2,'0123456789abcdef0123456789abcdef',0,8208,610,180,0.96,61,96,4,0,0,0,0,0,1,x'68617264726f636b2d6175746f70696c6f74','autopilot',1)",
    );

    const hard_rock = try store.lazerLeaderboardJson(std.testing.allocator, 1, 75, 0, .vanilla, "[\"HR\"]", true, false, stable_mods.hard_rock, .global, 50);
    defer std.testing.allocator.free(hard_rock);
    var parsed_hr = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, hard_rock, .{});
    defer parsed_hr.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed_hr.value.object.get("score_count").?.integer);
    try std.testing.expectEqual(@as(i64, 3), parsed_hr.value.object.get("scores").?.array.items[0].object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 2), parsed_hr.value.object.get("scores").?.array.items[1].object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 2), parsed_hr.value.object.get("user_score").?.object.get("position").?.integer);

    const combined = try store.lazerLeaderboardJson(std.testing.allocator, 1, 75, 0, .vanilla, "[]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(combined);
    var parsed_combined = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, combined, .{});
    defer parsed_combined.deinit();
    try std.testing.expectEqual(@as(i64, 3), parsed_combined.value.object.get("score_count").?.integer);
    try std.testing.expectEqual(@as(i64, 3), parsed_combined.value.object.get("scores").?.array.items[0].object.get("id").?.integer);
    const stable_board_score = parsed_combined.value.object.get("scores").?.array.items[1].object;
    try std.testing.expect(stable_board_score.get("id").?.integer >= lazer.stable_score_id_offset);
    try std.testing.expect(stable_board_score.get("has_replay").?.bool);
    try std.testing.expectEqualStrings("CL", stable_board_score.get("mods").?.array.items[0].object.get("acronym").?.string);
    try std.testing.expectEqual(@as(i64, 2), parsed_combined.value.object.get("scores").?.array.items[2].object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 3), parsed_combined.value.object.get("user_score").?.object.get("position").?.integer);
    try std.testing.expectEqual(@as(i64, 2), parsed_combined.value.object.get("user_score").?.object.get("score").?.object.get("id").?.integer);

    const team_scope = try store.lazerLeaderboardJson(std.testing.allocator, 1, 75, 0, .vanilla, "[]", false, false, 0, .team, 50);
    defer std.testing.allocator.free(team_scope);
    const parsed_team_scope = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, team_scope, .{});
    defer parsed_team_scope.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed_team_scope.value.object.get("score_count").?.integer);
    try std.testing.expect(parsed_team_scope.value.object.get("scores").?.array.items[0].object.get("id").?.integer >= lazer.stable_score_id_offset);
    try std.testing.expectEqual(@as(i64, 2), parsed_team_scope.value.object.get("scores").?.array.items[1].object.get("id").?.integer);

    const friend_scope = try store.lazerLeaderboardJson(std.testing.allocator, 1, 75, 0, .vanilla, "[]", false, false, 0, .friend, 50);
    defer std.testing.allocator.free(friend_scope);
    const parsed_friend_scope = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, friend_scope, .{});
    defer parsed_friend_scope.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed_friend_scope.value.object.get("score_count").?.integer);
    try std.testing.expectEqual(@as(i64, 3), parsed_friend_scope.value.object.get("scores").?.array.items[0].object.get("id").?.integer);

    const country_scope = try store.lazerLeaderboardJson(std.testing.allocator, 1, 75, 0, .vanilla, "[]", false, false, 0, .country, 50);
    defer std.testing.allocator.free(country_scope);
    const parsed_country_scope = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, country_scope, .{});
    defer parsed_country_scope.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed_country_scope.value.object.get("score_count").?.integer);

    const no_team_scope = try store.lazerLeaderboardJson(std.testing.allocator, 2, 75, 0, .vanilla, "[]", false, false, 0, .team, 50);
    defer std.testing.allocator.free(no_team_scope);
    const parsed_no_team_scope = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, no_team_scope, .{});
    defer parsed_no_team_scope.deinit();
    try std.testing.expectEqual(@as(i64, 0), parsed_no_team_scope.value.object.get("score_count").?.integer);
    try std.testing.expect(parsed_no_team_scope.value.object.get("user_score").? == .null);

    const exact_nm = try store.lazerLeaderboardJson(std.testing.allocator, 1, 75, 0, .vanilla, "[]", true, false, 0, .global, 50);
    defer std.testing.allocator.free(exact_nm);
    var parsed_exact_nm = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, exact_nm, .{});
    defer parsed_exact_nm.deinit();
    try std.testing.expectEqual(@as(i64, 3), parsed_exact_nm.value.object.get("score_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), parsed_exact_nm.value.object.get("scores").?.array.items[0].object.get("id").?.integer);
    try std.testing.expect(parsed_exact_nm.value.object.get("scores").?.array.items[1].object.get("id").?.integer >= lazer.stable_score_id_offset);
    try std.testing.expectEqual(@as(i64, 4), parsed_exact_nm.value.object.get("scores").?.array.items[2].object.get("id").?.integer);

    const relax = try store.lazerLeaderboardJson(std.testing.allocator, 4, 75, 0, .relax, "[\"RX\"]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(relax);
    var parsed_relax = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, relax, .{});
    defer parsed_relax.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed_relax.value.object.get("score_count").?.integer);
    const stable_relax = parsed_relax.value.object.get("scores").?.array.items[0].object;
    try std.testing.expect(stable_relax.get("id").?.integer >= lazer.stable_score_id_offset);
    try std.testing.expectEqual(lazer.decodeStableScoreId(stable_relax.get("id").?.integer).?, stable_relax.get("legacy_score_id").?.integer);
    try std.testing.expectEqual(@as(i64, 600), stable_relax.get("legacy_total_score").?.integer);
    try std.testing.expect(stable_relax.get("ranked").?.bool);
    try std.testing.expect(stable_relax.get("has_replay").?.bool);
    try std.testing.expectEqualStrings("CL", stable_relax.get("mods").?.array.items[0].object.get("acronym").?.string);
    try std.testing.expectEqualStrings("RX", stable_relax.get("mods").?.array.items[1].object.get("acronym").?.string);
    const relax_replay_id = lazer.decodeStableScoreId(stable_relax.get("id").?.integer).?;
    const relax_replay = (try store.siteReplay(std.testing.allocator, relax_replay_id)).?;
    defer std.testing.allocator.free(relax_replay);
    try std.testing.expect(std.mem.indexOf(u8, relax_replay, "relax-replay") != null);

    const hidden_relax = try store.lazerLeaderboardJson(std.testing.allocator, 1, 75, 0, .relax, "[\"HD\",\"RX\"]", true, false, stable_mods.hidden, .global, 50);
    defer std.testing.allocator.free(hidden_relax);
    const parsed_hidden_relax = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, hidden_relax, .{});
    defer parsed_hidden_relax.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed_hidden_relax.value.object.get("score_count").?.integer);
    const hidden_relax_score = parsed_hidden_relax.value.object.get("scores").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 1), hidden_relax_score.get("user_id").?.integer);
    try std.testing.expectEqualStrings("HD", hidden_relax_score.get("mods").?.array.items[1].object.get("acronym").?.string);
    try std.testing.expectEqualStrings("RX", hidden_relax_score.get("mods").?.array.items[2].object.get("acronym").?.string);

    const autopilot = try store.lazerLeaderboardJson(std.testing.allocator, 4, 75, 0, .autopilot, "[\"AP\"]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(autopilot);
    var parsed_autopilot = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, autopilot, .{});
    defer parsed_autopilot.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed_autopilot.value.object.get("score_count").?.integer);
    const stable_autopilot = parsed_autopilot.value.object.get("scores").?.array.items[0].object;
    try std.testing.expect(stable_autopilot.get("id").?.integer >= lazer.stable_score_id_offset);
    try std.testing.expectEqual(lazer.decodeStableScoreId(stable_autopilot.get("id").?.integer).?, stable_autopilot.get("legacy_score_id").?.integer);
    try std.testing.expectEqual(@as(i64, 620), stable_autopilot.get("legacy_total_score").?.integer);
    try std.testing.expect(stable_autopilot.get("ranked").?.bool);
    try std.testing.expect(stable_autopilot.get("has_replay").?.bool);
    try std.testing.expectEqualStrings("AP", stable_autopilot.get("mods").?.array.items[1].object.get("acronym").?.string);
    const autopilot_replay_id = lazer.decodeStableScoreId(stable_autopilot.get("id").?.integer).?;
    const autopilot_replay = (try store.siteReplay(std.testing.allocator, autopilot_replay_id)).?;
    defer std.testing.allocator.free(autopilot_replay);
    try std.testing.expect(std.mem.indexOf(u8, autopilot_replay, "autopilot-replay") != null);

    const hard_rock_autopilot = try store.lazerLeaderboardJson(std.testing.allocator, 2, 75, 0, .autopilot, "[\"HR\",\"AP\"]", true, false, stable_mods.hard_rock, .global, 50);
    defer std.testing.allocator.free(hard_rock_autopilot);
    const parsed_hard_rock_autopilot = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, hard_rock_autopilot, .{});
    defer parsed_hard_rock_autopilot.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed_hard_rock_autopilot.value.object.get("score_count").?.integer);
    try std.testing.expectEqual(@as(i64, 2), parsed_hard_rock_autopilot.value.object.get("scores").?.array.items[0].object.get("user_id").?.integer);

    const hard_rock_best = (try store.lazerScoreLeaderboardPlacement(2)).?;
    try std.testing.expect(hard_rock_best.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 1), hard_rock_best.rank);
    const hard_rock_lower = (try store.lazerScoreLeaderboardPlacement(5)).?;
    try std.testing.expect(!hard_rock_lower.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 1), hard_rock_lower.rank);

    const custom = try store.lazerLeaderboardJson(std.testing.allocator, 1, 75, 0, .custom, "[\"WIGGLE\"]", true, false, null, .global, 50);
    defer std.testing.allocator.free(custom);
    var parsed_custom = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, custom, .{});
    defer parsed_custom.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed_custom.value.object.get("score_count").?.integer);
    try std.testing.expectEqual(@as(i64, 8), parsed_custom.value.object.get("scores").?.array.items[0].object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 6), parsed_custom.value.object.get("scores").?.array.items[1].object.get("id").?.integer);
    const custom_placement = (try store.lazerScoreLeaderboardPlacement(6)).?;
    try std.testing.expect(custom_placement.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 1), custom_placement.rank);
    const qualified_placement = (try store.lazerScoreLeaderboardPlacement(9)).?;
    try std.testing.expect(qualified_placement.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 0), qualified_placement.rank);
    const loved_placement = (try store.lazerScoreLeaderboardPlacement(10)).?;
    try std.testing.expect(loved_placement.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 0), loved_placement.rank);
}

test "lazer submission updates ranked performance without overwriting another ruleset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/lazer-v2-stats.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(1,'ari','ari',x'00',x'00');" ++
            "INSERT INTO stats(user_id,mode,ranked_score,total_score,pp,plays,total_hits,accuracy,max_combo) VALUES" ++
            "(1,0,5000,10000,424,7,700,0.9353,228),(1,1,777,888,12,3,99,0.8,44);" ++
            "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,total_length,star_rating) VALUES(75,75,'0123456789abcdef0123456789abcdef','artist','title','diff','mapper',3,90,2.5)",
    );
    const raw = "{\"rank\":\"A\",\"total_score\":987654,\"total_score_without_mods\":900000,\"accuracy\":0.985,\"max_combo\":321,\"ruleset_id\":0,\"passed\":true,\"statistics\":{\"great\":300,\"miss\":2},\"maximum_statistics\":{\"great\":302},\"pauses\":[]}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    var input = try lazer.parseSoloScore(parsed.value, 75);
    input.achievement_stars = 4.25;
    const token = try store.createLazerScoreToken(1, 75, "0123456789abcdef0123456789abcdef", 0, "11111111111111111111111111111111");
    _ = try store.submitLazerScoreToken(1, 75, token, input, 500, "[]", "{\"great\":300,\"miss\":2}", "{\"great\":302}", "[]", &.{});

    const osu = (try store.statsForUser(1, 0)).?;
    try std.testing.expectEqual(@as(i64, 3_032_606), osu.ranked_score);
    try std.testing.expectEqual(@as(i64, 3_042_606), osu.total_score);
    try std.testing.expectEqual(@as(i32, 500), osu.pp);
    try std.testing.expectEqual(@as(i32, 8), osu.plays);
    try std.testing.expectEqual(@as(i32, 90), osu.play_time);
    try std.testing.expectEqual(@as(i64, 1000), osu.total_hits);
    try std.testing.expectApproxEqAbs(@as(f64, 0.985), osu.accuracy, 0.000001);
    try std.testing.expectEqual(@as(i32, 321), osu.max_combo);
    const taiko = (try store.statsForUser(1, 1)).?;
    try std.testing.expectEqual(@as(i64, 777), taiko.ranked_score);
    try std.testing.expectEqual(@as(i64, 888), taiko.total_score);
    try std.testing.expectEqual(@as(i32, 3), taiko.plays);

    var failed = input;
    failed.passed = false;
    failed.rank = "F";
    failed.total_score = 100;
    failed.max_combo = 999;
    const failed_token = try store.createLazerScoreToken(1, 75, "0123456789abcdef0123456789abcdef", 0, "22222222222222222222222222222222");
    _ = try store.submitLazerScoreToken(1, 75, failed_token, failed, 100, "[]", "{\"great\":300,\"miss\":2}", "{\"great\":302}", "[]", &.{});
    const after_fail = (try store.statsForUser(1, 0)).?;
    try std.testing.expectEqual(@as(i64, 3_032_606), after_fail.ranked_score);
    try std.testing.expectEqual(@as(i64, 3_042_913), after_fail.total_score);
    try std.testing.expectEqual(@as(i32, 9), after_fail.plays);
    try std.testing.expectEqual(@as(i32, 180), after_fail.play_time);
    try std.testing.expectEqual(@as(i32, 321), after_fail.max_combo);
    try std.testing.expectEqual(@as(i32, 500), after_fail.pp);
    try std.testing.expectApproxEqAbs(@as(f64, 0.985), after_fail.accuracy, 0.000001);
    var stored_star: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "SELECT star_rating FROM lazer_scores ORDER BY id LIMIT 1", -1, &stored_star, null));
    defer _ = storage.c.sqlite3_finalize(stored_star);
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(stored_star));
    try std.testing.expectApproxEqAbs(@as(f64, 4.25), storage.c.sqlite3_column_double(stored_star, 0), 0.000001);
    const profile = (try store.siteProfile(std.testing.allocator, 1, .lazer, 0)).?;
    defer std.testing.allocator.free(profile);
    try std.testing.expect(std.mem.indexOf(u8, profile, "\"star_rating\":4.25") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "\"play_time\":180") != null);
    const source_stats = (try store.sourceStatsForUser(1, 0, .lazer)).?;
    try std.testing.expectEqual(@as(i32, 180), source_stats.play_time);
    try store.exec("UPDATE stats SET play_time=0 WHERE user_id=1 AND mode=0");
    _ = try store.applyBeatmapRankAction(3, "0123456789abcdef0123456789abcdef", .love, "rebuild play time");
    const rebuilt = (try store.statsForUser(1, 0)).?;
    try std.testing.expectEqual(@as(i32, 180), rebuilt.play_time);
}

test "schema twenty two backfills the historical lazer best score" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/lazer-best-migration.db", .{tmp.sub_path});
    {
        var old_store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
        defer old_store.close();
        try old_store.migrate();
        try old_store.exec(
            sqlite_anticheat_exclusion_downgrade ++
                "DROP INDEX lazer_scores_user_best;" ++
                "ALTER TABLE lazer_scores DROP COLUMN pp;" ++
                "ALTER TABLE lazer_scores DROP COLUMN best;" ++
                "PRAGMA user_version=21;" ++
                "INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(1,'ari','ari',x'00',x'00');" ++
                "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status) VALUES(75,75,'11111111111111111111111111111111','a','one','one','m',3);" ++
                "INSERT INTO lazer_scores(id,user_id,beatmap_id,ruleset_id,total_score,total_score_without_mods,accuracy,max_combo,passed,mods_json,statistics_json,rank_namespace) VALUES" ++
                "(1,1,75,0,500,500,0.5,5,1,'[]','{}','vanilla'),(2,1,75,0,1000,1000,1,10,1,'[]','{}','vanilla'),(3,1,75,0,2000,2000,1,20,0,'[]','{}','vanilla')",
        );
    }
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    var stmt: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "SELECT id,best FROM lazer_scores ORDER BY id", -1, &stmt, null));
    defer _ = storage.c.sqlite3_finalize(stmt);
    for ([_]c_int{ 0, 1, 0 }, 1..) |expected, id| {
        try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(stmt));
        try std.testing.expectEqual(@as(i64, @intCast(id)), storage.c.sqlite3_column_int64(stmt, 0));
        try std.testing.expectEqual(expected, storage.c.sqlite3_column_int(stmt, 1));
    }
}

test "lazer ranked stats use legacy scores and pp overwrite while ignoring failed or unranked pp" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/lazer-weighted-stats.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(1,'ari','ari',x'00',x'00');" ++
            "INSERT INTO stats(user_id,mode) VALUES(1,0);" ++
            "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status) VALUES" ++
            "(75,75,'11111111111111111111111111111111','a','one','one','m',3)," ++
            "(76,76,'22222222222222222222222222222222','a','two','two','m',3)," ++
            "(77,77,'33333333333333333333333333333333','a','three','three','m',2)",
    );
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"rank\":\"A\",\"total_score\":1000,\"total_score_without_mods\":1000,\"accuracy\":1,\"max_combo\":100,\"ruleset_id\":0,\"passed\":true,\"statistics\":{\"great\":100},\"maximum_statistics\":{\"great\":100},\"pauses\":[]}", .{});
    defer parsed.deinit();
    var input = try lazer.parseSoloScore(parsed.value, 75);

    const first_token = try store.createLazerScoreToken(1, 75, "11111111111111111111111111111111", 0, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const first_id = try store.submitLazerScoreToken(1, 75, first_token, input, 100, "[]", "{\"great\":100}", "{\"great\":100}", "[]", &.{});
    input.beatmap_id = 76;
    input.total_score = 2000;
    input.accuracy = 0.9;
    const second_token = try store.createLazerScoreToken(1, 76, "22222222222222222222222222222222", 0, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    _ = try store.submitLazerScoreToken(1, 76, second_token, input, 200, "[]", "{\"great\":90,\"miss\":10}", "{\"great\":100}", "[]", &.{});
    const weighted = (try store.statsForUser(1, 0)).?;
    try std.testing.expectEqual(@as(i32, 295), weighted.pp);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9487179487), weighted.accuracy, 0.000001);

    input.beatmap_id = 75;
    input.total_score = 900;
    input.accuracy = 0.5;
    const lower_token = try store.createLazerScoreToken(1, 75, "11111111111111111111111111111111", 0, "cccccccccccccccccccccccccccccccc");
    const lower_id = try store.submitLazerScoreToken(1, 75, lower_token, input, 500, "[]", "{\"great\":50,\"miss\":50}", "{\"great\":100}", "[]", &.{});
    const after_lower = (try store.statsForUser(1, 0)).?;
    try std.testing.expectEqual(@as(i32, 690), after_lower.pp);
    try std.testing.expectEqual(@as(i64, 1234), after_lower.ranked_score);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6948717949), after_lower.accuracy, 0.000001);

    input.passed = false;
    input.rank = "F";
    input.total_score = 5000;
    const failed_token = try store.createLazerScoreToken(1, 75, "11111111111111111111111111111111", 0, "dddddddddddddddddddddddddddddddd");
    _ = try store.submitLazerScoreToken(1, 75, failed_token, input, 999, "[]", "{\"great\":50,\"miss\":50}", "{\"great\":100}", "[]", &.{});
    const after_fail = (try store.statsForUser(1, 0)).?;
    try std.testing.expectEqual(after_lower.pp, after_fail.pp);
    try std.testing.expectApproxEqAbs(after_lower.accuracy, after_fail.accuracy, 0.000001);

    input.passed = true;
    input.rank = "A";
    input.beatmap_id = 77;
    input.total_score = 9000;
    input.accuracy = 1;
    const unranked_token = try store.createLazerScoreToken(1, 77, "33333333333333333333333333333333", 0, "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee");
    _ = try store.submitLazerScoreToken(1, 77, unranked_token, input, 1000, "[]", "{\"great\":100}", "{\"great\":100}", "[]", &.{});
    const after_unranked = (try store.statsForUser(1, 0)).?;
    try std.testing.expectEqual(after_lower.pp, after_unranked.pp);
    try std.testing.expectApproxEqAbs(after_lower.accuracy, after_unranked.accuracy, 0.000001);

    var best_rows: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "SELECT id,pp,best FROM lazer_scores WHERE id IN(?1,?2) ORDER BY id", -1, &best_rows, null));
    defer _ = storage.c.sqlite3_finalize(best_rows);
    _ = storage.c.sqlite3_bind_int64(best_rows, 1, first_id);
    _ = storage.c.sqlite3_bind_int64(best_rows, 2, lower_id);
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(best_rows));
    try std.testing.expectEqual(first_id, storage.c.sqlite3_column_int64(best_rows, 0));
    try std.testing.expectApproxEqAbs(@as(f64, 100), storage.c.sqlite3_column_double(best_rows, 1), 0.001);
    try std.testing.expectEqual(@as(c_int, 0), storage.c.sqlite3_column_int(best_rows, 2));
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(best_rows));
    try std.testing.expectEqual(lower_id, storage.c.sqlite3_column_int64(best_rows, 0));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(best_rows, 2));

    const best_scores = try store.lazerUserScoresJson(std.testing.allocator, 1, 0, .best, .lazer, 0, 50);
    defer std.testing.allocator.free(best_scores);
    var parsed_best_scores = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, best_scores, .{});
    defer parsed_best_scores.deinit();
    try std.testing.expectEqual(lower_id, parsed_best_scores.value.array.items[0].object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 500), parsed_best_scores.value.array.items[0].object.get("pp").?.integer);

    const score_board = (try store.siteBeatmapLeaderboard(std.testing.allocator, 75, .lazer, 0)).?;
    defer std.testing.allocator.free(score_board);
    var parsed_score_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, score_board, .{});
    defer parsed_score_board.deinit();
    try std.testing.expectEqual(first_id, parsed_score_board.value.object.get("scores").?.array.items[0].object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 1000), parsed_score_board.value.object.get("scores").?.array.items[0].object.get("score").?.integer);

    const lazer_rankings = try store.siteRankings(std.testing.allocator, .lazer, 0, 0);
    defer std.testing.allocator.free(lazer_rankings);
    try std.testing.expect(std.mem.indexOf(u8, lazer_rankings, "\"source\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_rankings, "\"name\":\"ari\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_rankings, "\"pp\":690") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_rankings, "\"plays\":5") != null);

    const lazer_profile = (try store.siteProfile(std.testing.allocator, 1, .lazer, 0)).?;
    defer std.testing.allocator.free(lazer_profile);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"selected_source\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"selected_stats\":{\"ranked_score\":1234,\"total_score\":7619,\"pp\":690,\"plays\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"client\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"mods_json\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"passed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"pinned_scores\":[]") != null);

    const shared_profile = (try store.siteProfile(std.testing.allocator, 1, .all, 0)).?;
    defer std.testing.allocator.free(shared_profile);
    try std.testing.expect(std.mem.indexOf(u8, shared_profile, "\"client\":\"lazer\"") != null);
}

test "startup repairs lazer best plays by pp without changing score order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/lazer-pp-best-migration.db", .{tmp.sub_path});
    {
        var old_store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
        defer old_store.close();
        try old_store.migrate();
        try old_store.exec(
            "INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(1,'ari','ari',x'00',x'00');" ++
                "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status) VALUES(75,75,'11111111111111111111111111111111','a','one','one','m',3);" ++
                "INSERT INTO lazer_scores(id,user_id,beatmap_id,ruleset_id,total_score,total_score_without_mods,accuracy,max_combo,passed,mods_json,statistics_json,rank_namespace,pp,best) VALUES" ++
                "(1,1,75,0,1000,1000,1,10,1,'[]','{}','vanilla',100,1),(2,1,75,0,900,900,1,10,1,'[{\"acronym\":\"HR\"}]','{}','vanilla',500,0)",
        );
    }
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    var stmt: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "SELECT id,best FROM lazer_scores ORDER BY id", -1, &stmt, null));
    defer _ = storage.c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(i64, 1), storage.c.sqlite3_column_int64(stmt, 0));
    try std.testing.expectEqual(@as(c_int, 0), storage.c.sqlite3_column_int(stmt, 1));
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(i64, 2), storage.c.sqlite3_column_int64(stmt, 0));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(stmt, 1));
}

test "stable and lazer share one ranked performance result per map" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/shared-client-performance.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(1,'ari','ari',x'00',x'00');" ++
            "INSERT INTO stats(user_id,mode) VALUES(1,0);" ++
            "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status) VALUES" ++
            "(75,75,'11111111111111111111111111111111','a','one','one','m',3)",
    );
    const stable_input: stable_score.Submission = .{
        .map_md5 = "11111111111111111111111111111111",
        .username = "ari",
        .online_checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .n300 = 100,
        .n100 = 0,
        .n50 = 0,
        .ngeki = 0,
        .nkatu = 0,
        .nmiss = 0,
        .total_score = 1000,
        .max_combo = 100,
        .perfect = true,
        .grade = "X",
        .mods = 0,
        .passed = true,
        .mode = 0,
        .client_time = "260813000000",
        .client_flags = "0",
        .achievement_stars = 3.75,
    };
    _ = try store.insertStableScore(1, stable_input, 300, "stable replay", 10_000);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"rank\":\"A\",\"total_score\":1500,\"total_score_without_mods\":900,\"accuracy\":0.9,\"max_combo\":90,\"ruleset_id\":0,\"passed\":true,\"statistics\":{\"great\":90,\"miss\":10},\"maximum_statistics\":{\"great\":100},\"pauses\":[]}", .{});
    defer parsed.deinit();
    const lazer_input = try lazer.parseSoloScore(parsed.value, 75);
    const token = try store.createLazerScoreToken(1, 75, "11111111111111111111111111111111", 0, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    _ = try store.submitLazerScoreToken(1, 75, token, lazer_input, 350, "[]", "{\"great\":90,\"miss\":10}", "{\"great\":100}", "[]", &.{});
    const after_lazer = (try store.statsForUser(1, 0)).?;
    try std.testing.expectEqual(@as(i64, 639), after_lazer.ranked_score);
    try std.testing.expectEqual(@as(i64, 1639), after_lazer.total_score);
    try std.testing.expectEqual(@as(i32, 350), after_lazer.pp);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), after_lazer.accuracy, 0.000001);

    var later_stable = stable_input;
    later_stable.online_checksum = "cccccccccccccccccccccccccccccccc";
    later_stable.total_score = 1200;
    _ = try store.insertStableScore(1, later_stable, 400, "later stable replay", 10_000);
    const after_stable = (try store.statsForUser(1, 0)).?;
    try std.testing.expectEqual(@as(i64, 1200), after_stable.ranked_score);
    try std.testing.expectEqual(@as(i64, 2839), after_stable.total_score);
    try std.testing.expectEqual(@as(i32, 400), after_stable.pp);
    try std.testing.expectApproxEqAbs(@as(f64, 1), after_stable.accuracy, 0.000001);

    const stable_board = (try store.siteBeatmapLeaderboard(std.testing.allocator, 75, .stable, 0)).?;
    defer std.testing.allocator.free(stable_board);
    try std.testing.expect(std.mem.indexOf(u8, stable_board, "\"source\":\"stable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stable_board, "\"client\":\"stable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stable_board, "\"client\":\"lazer\"") == null);
    const lazer_board = (try store.siteBeatmapLeaderboard(std.testing.allocator, 75, .lazer, 0)).?;
    defer std.testing.allocator.free(lazer_board);
    try std.testing.expect(std.mem.indexOf(u8, lazer_board, "\"source\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_board, "\"client\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_board, "\"client\":\"stable\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_board, "\"score\":1500") != null);
    const stable_profile = (try store.siteProfile(std.testing.allocator, 1, .stable, 0)).?;
    defer std.testing.allocator.free(stable_profile);
    try std.testing.expect(std.mem.indexOf(u8, stable_profile, "\"selected_source\":\"stable\",\"stats_source\":\"stable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stable_profile, "\"selected_stats\":{\"ranked_score\":1200,\"total_score\":2200,\"pp\":400,\"plays\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, stable_profile, "\"client\":\"stable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stable_profile, "\"client\":\"lazer\"") == null);
    var parsed_stable_profile = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stable_profile, .{});
    defer parsed_stable_profile.deinit();
    const stable_profile_play = parsed_stable_profile.value.object.get("recent_scores").?.array.items[0].object;
    try std.testing.expectEqual(stable_profile_play.get("score").?.integer, stable_profile_play.get("legacy_score").?.integer);
    const lazer_profile = (try store.siteProfile(std.testing.allocator, 1, .lazer, 0)).?;
    defer std.testing.allocator.free(lazer_profile);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"selected_source\":\"lazer\",\"stats_source\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"selected_stats\":{\"ranked_score\":639,\"total_score\":639,\"pp\":350,\"plays\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"client\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"client\":\"stable\"") == null);
    var parsed_lazer_profile = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lazer_profile, .{});
    defer parsed_lazer_profile.deinit();
    const lazer_profile_play = parsed_lazer_profile.value.object.get("recent_scores").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 1500), lazer_profile_play.get("score").?.integer);
    try std.testing.expectEqual(@as(i64, 900), lazer_profile_play.get("score_without_mods").?.integer);
    try std.testing.expectEqual(@as(i64, 639), lazer_profile_play.get("legacy_score").?.integer);
    const lazer_first_place = parsed_lazer_profile.value.object.get("first_place_scores").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 900), lazer_first_place.get("score_without_mods").?.integer);
    try std.testing.expectEqual(@as(i64, 639), lazer_first_place.get("legacy_score").?.integer);
    const stable_source_stats = (try store.sourceStatsForUser(1, 0, .stable)).?;
    const lazer_source_stats = (try store.sourceStatsForUser(1, 0, .lazer)).?;
    try std.testing.expectEqual(@as(i64, 1200), stable_source_stats.ranked_score);
    try std.testing.expectEqual(@as(i64, 2200), stable_source_stats.total_score);
    try std.testing.expectEqual(@as(i32, 400), stable_source_stats.pp);
    try std.testing.expectEqual(@as(i32, 2), stable_source_stats.plays);
    try std.testing.expectEqual(@as(i64, 639), lazer_source_stats.ranked_score);
    try std.testing.expectEqual(@as(i64, 639), lazer_source_stats.total_score);
    try std.testing.expectEqual(@as(i32, 350), lazer_source_stats.pp);
    try std.testing.expectEqual(@as(i32, 1), lazer_source_stats.plays);
    const combined_board = (try store.siteBeatmapLeaderboard(std.testing.allocator, 75, .all, 0)).?;
    defer std.testing.allocator.free(combined_board);
    var parsed_combined_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, combined_board, .{});
    defer parsed_combined_board.deinit();
    const combined_score = parsed_combined_board.value.object.get("scores").?.array.items[0].object;
    try std.testing.expectEqualStrings("stable", combined_score.get("client").?.string);
    try std.testing.expectEqual(@as(i64, 1200), combined_score.get("score").?.integer);
    try std.testing.expectEqual(@as(i64, 400), combined_score.get("pp").?.integer);
    const stable_rankings = try store.siteRankings(std.testing.allocator, .stable, 0, 0);
    defer std.testing.allocator.free(stable_rankings);
    try std.testing.expect(std.mem.indexOf(u8, stable_rankings, "\"source\":\"stable\"") != null);

    try store.exec("UPDATE stats SET ranked_score=1,total_score=2,pp=3,plays=4,accuracy=0.5,max_combo=5 WHERE user_id=1 AND mode=0");
    _ = try store.applyBeatmapRankAction(1, stable_input.map_md5, .rank, "rebuild combined client stats");
    const rebuilt = (try store.statsForUser(1, 0)).?;
    try std.testing.expectEqual(@as(i64, 1200), rebuilt.ranked_score);
    try std.testing.expectEqual(@as(i64, 2839), rebuilt.total_score);
    try std.testing.expectEqual(@as(i32, 400), rebuilt.pp);
    try std.testing.expectEqual(@as(i32, 3), rebuilt.plays);
    try std.testing.expectApproxEqAbs(@as(f64, 1), rebuilt.accuracy, 0.000001);
    try std.testing.expectEqual(@as(i32, 100), rebuilt.max_combo);
}

test "matchmaking pools only use playable ranked maps in ruleset order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/matchmaking-pool.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,mode,star_rating,osu_file) VALUES" ++
            "(75,75,'11111111111111111111111111111111','a','one','one','m',3,0,5.5,x'01')," ++
            "(76,76,'22222222222222222222222222222222','a','two','two','m',4,0,2.5,x'02')," ++
            "(77,77,'33333333333333333333333333333333','a','three','three','m',2,0,1.5,x'03')," ++
            "(78,78,'44444444444444444444444444444444','a','four','four','m',3,0,3.5,NULL)," ++
            "(79,79,'55555555555555555555555555555555','a','five','five','m',3,1,1.5,x'05')",
    );

    const standard = try store.matchmakingBeatmaps(std.testing.allocator, 0, 16);
    defer std.testing.allocator.free(standard);
    try std.testing.expectEqual(@as(usize, 2), standard.len);
    try std.testing.expectEqual(@as(i32, 76), standard[0].id);
    try std.testing.expectEqualStrings("22222222222222222222222222222222", &standard[0].md5);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), standard[0].stars, 0.000001);
    try std.testing.expectEqual(@as(i32, 75), standard[1].id);

    const limited = try store.matchmakingBeatmaps(std.testing.allocator, 0, 1);
    defer std.testing.allocator.free(limited);
    try std.testing.expectEqual(@as(usize, 1), limited.len);
    try std.testing.expectEqual(@as(i32, 76), limited[0].id);

    try std.testing.expectError(error.InvalidMatchmakingPool, store.matchmakingBeatmaps(std.testing.allocator, 4, 1));
    try std.testing.expectError(error.InvalidMatchmakingPool, store.matchmakingBeatmaps(std.testing.allocator, 0, 0));
}

test "Rijndael-256 matches the py3rijndael block fixture" {
    var key: [32]u8 = undefined;
    try std.base64.standard.Decoder.decode(&key, "qBS8uRhEIBsr8jr8vuY9uUpGFefYRL2HSTtrKhaI1tk=");
    var expected: [32]u8 = undefined;
    try std.base64.standard.Decoder.decode(&expected, "Kc8C3vjf+EpLRmgTZ5ckWTzJ/6n7WBHW8pkByDscI/E=");
    var input: [32]u8 = [_]u8{0x1b} ** 32;
    @memcpy(input[0..5], "Mahdi");
    const cipher = rijndael.Rijndael256.init(key);
    const encrypted = cipher.encryptBlock(input);
    try std.testing.expectEqualSlices(u8, &expected, &encrypted);
    try std.testing.expectEqual(input, cipher.decryptBlock(encrypted));
}

test "Rijndael-256 CBC rejects bad PKCS7 padding" {
    const key = [_]u8{0} ** 32;
    const iv = [_]u8{0} ** 32;
    const invalid = [_]u8{0} ** 32;
    try std.testing.expectError(error.InvalidPadding, rijndael.decryptCbcPkcs7(std.testing.allocator, key, iv, &invalid));
}

test "multipart keeps both stable score fields" {
    const body = "--zigcho\r\n" ++
        "Content-Disposition: form-data; name=\"score\"\r\n\r\n" ++
        "encrypted\r\n--zigcho\r\n" ++
        "Content-Disposition: form-data; name=\"score\"; filename=\"replay.osr\"\r\n" ++
        "Content-Type: application/octet-stream\r\n\r\n" ++
        "replay-bytes\r\n--zigcho--\r\n";
    var form = try multipart.parse(std.testing.allocator, body, "zigcho");
    defer form.deinit();
    try std.testing.expectEqualStrings("encrypted", form.nth("score", 0).?.data);
    try std.testing.expectEqualStrings("replay.osr", form.nth("score", 1).?.filename.?);
    try std.testing.expectEqualStrings("replay-bytes", form.nth("score", 1).?.data);
}

test "multipart rejects a missing closing boundary" {
    const body = "--zigcho\r\nContent-Disposition: form-data; name=\"score\"\r\n\r\ndata";
    try std.testing.expectError(error.IncompleteMultipart, multipart.parse(std.testing.allocator, body, "zigcho"));
}

test "multipart ignores boundary-looking bytes inside binary parts" {
    const replay = "start\r\n--not-zigcho\x00\x01still\r\n--zigcho-but-not-a-delimiter";
    const body = "--zigcho\r\n" ++
        "Content-Disposition: form-data; name=\"score\"; filename=\"replay.osr\"\r\n" ++
        "Content-Type: application/octet-stream\r\n\r\n" ++ replay ++
        "\r\n--zigcho--\r\n";
    var form = try multipart.parse(std.testing.allocator, body, "zigcho");
    defer form.deinit();
    try std.testing.expectEqualSlices(u8, replay, form.first("score").?.data);
}

test "stable score payload decrypts from an independent client fixture" {
    var decrypted = try score_crypto.decrypt(
        std.testing.allocator,
        "ifQK7y+1eudaaKysIeS9146KPNtMuLwpB/gxFQdN1o34zAMqcheINZybLuB/09guF5NLyBLwXg7TXXfxYZAymPOYAE6a7eI96qaU9nnW5vpwaKVnWNFkUj5foS/x0xYQ5tETgLEzW404hW0j+HL7fMK3R+xu3gg26KCM6F9yK8JtJC4naSKhTZkBh2FexMMlz6OPLebgHuTp+dML18MiFA==",
        "l+IW3EOOGO3GQ0A9/d6ASDKTLMMBSvK5lxsGDDlvoQc=",
        "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
        "20260808",
    );
    defer decrypted.deinit();
    try std.testing.expectEqualStrings("client-hash-fixture", decrypted.client_hash);
    try std.testing.expect(std.mem.startsWith(u8, decrypted.score_data, "0123456789abcdef0123456789abcdef:Ari:"));
    try std.testing.expectEqual(@as(usize, 17), std.mem.count(u8, decrypted.score_data, ":"));
}

test "stable online score checksum matches the client formula" {
    const data = "0123456789abcdef0123456789abcdef:Ari:bd08534d40f7bbab046520c9b4931cdc:300:4:1:2:3:5:987654:321:False:A:0:True:0:260808235959:20260808";
    const score = try stable_score.parse(data);
    try std.testing.expect(score.verifyChecksum("20260808", "client-hash-fixture", ""));
    try std.testing.expect(!score.verifyChecksum("20260808", "wrong-client", ""));
    try std.testing.expectApproxEqAbs(@as(f64, 0.97258), score.accuracy(), 0.0001);
}

test "stable score counters are bounded and widened before arithmetic" {
    const maximum = "0123456789abcdef0123456789abcdef:Ari:00000000000000000000000000000000:10000000:10000000:10000000:10000000:10000000:10000000:1000000000000:10000000:False:A:0:True:3:260808235959:20260808";
    const score = try stable_score.parse(maximum);
    try std.testing.expect(std.math.isFinite(score.accuracy()));
    try std.testing.expect(!score.verifyChecksum("20260808", "client-hash-fixture", ""));

    const too_many_hits = "0123456789abcdef0123456789abcdef:Ari:00000000000000000000000000000000:10000001:0:0:0:0:0:1:1:False:A:0:True:0:260808235959:20260808";
    try std.testing.expectError(error.ValueTooLarge, stable_score.parse(too_many_hits));
    const too_much_combo = "0123456789abcdef0123456789abcdef:Ari:00000000000000000000000000000000:1:0:0:0:0:0:1:10000001:False:A:0:True:0:260808235959:20260808";
    try std.testing.expectError(error.ValueTooLarge, stable_score.parse(too_much_combo));
    const too_much_score = "0123456789abcdef0123456789abcdef:Ari:00000000000000000000000000000000:1:0:0:0:0:0:1000000000001:1:False:A:0:True:0:260808235959:20260808";
    try std.testing.expectError(error.ValueTooLarge, stable_score.parse(too_much_score));
}

test "stable online score checksum trims the donor marker the client appends to the username" {
    // the wire username carries a trailing space for donor accounts; the client
    // signs the checksum with the clean name, so the server must trim it too.
    const data = "0123456789abcdef0123456789abcdef:Ari :bd08534d40f7bbab046520c9b4931cdc:300:4:1:2:3:5:987654:321:False:A:0:True:0:260808235959:20260808";
    const score = try stable_score.parse(data);
    try std.testing.expect(score.verifyChecksum("20260808", "client-hash-fixture", ""));
}

test "current stable score payload accepts one trailing client field" {
    const base = "0123456789abcdef0123456789abcdef:Ari:bd08534d40f7bbab046520c9b4931cdc:300:4:1:2:3:5:987654:321:False:A:0:True:0:260808235959:20260808";
    _ = try stable_score.parse(base ++ ":0");
    _ = try stable_score.parse(base ++ ":0:future-client-field");
}

test "stable supporter marker is separate from the account name" {
    const marked = "raya ";
    const account_name = if (marked.len > 0 and marked[marked.len - 1] == ' ') marked[0 .. marked.len - 1] else marked;
    try std.testing.expectEqualStrings("raya", account_name);
}

test "failed stable scores may submit an empty replay" {
    try std.testing.expect(stable_score.replayLengthAccepted(false, 0));
    try std.testing.expect(!stable_score.replayLengthAccepted(true, 0));
    try std.testing.expect(stable_score.replayLengthAccepted(true, 1));
    try std.testing.expect(!stable_score.replayLengthAccepted(false, 16 * 1024 * 1024 + 1));
}

test "stable mod modes select isolated ranking and stats namespaces" {
    const base = "0123456789abcdef0123456789abcdef:Ari:bd08534d40f7bbab046520c9b4931cdc:300:4:1:2:3:5:987654:321:False:A:";
    const suffix = ":True:0:260808235959:20260808";
    const nomod = try stable_score.parse(base ++ "0" ++ suffix);
    const relax = try stable_score.parse(base ++ "128" ++ suffix);
    const autopilot = try stable_score.parse(base ++ "8192" ++ suffix);
    try std.testing.expectEqualStrings("vanilla", nomod.rankNamespace());
    try std.testing.expectEqualStrings("relax", relax.rankNamespace());
    try std.testing.expectEqualStrings("autopilot", autopilot.rankNamespace());
    try std.testing.expectEqual(@as(?u8, 0), stable_score.statsMode(0, 0));
    try std.testing.expectEqual(@as(?u8, 4), stable_score.statsMode(0, 128));
    try std.testing.expectEqual(@as(?u8, 5), stable_score.statsMode(1, 128));
    try std.testing.expectEqual(@as(?u8, 6), stable_score.statsMode(2, 128));
    try std.testing.expectEqual(@as(?u8, 8), stable_score.statsMode(0, 8192));
    try std.testing.expectEqual(@as(?u8, null), stable_score.statsMode(3, 128));
    try std.testing.expectEqual(@as(?u8, null), stable_score.statsMode(1, 8192));
}

test "client packet reader rejects truncation" {
    var reader: protocol.Reader = .{ .data = &.{ 1, 0, 0, 10, 0, 0, 0, 1 } };
    try std.testing.expectError(error.TruncatedPacket, reader.next());
}

test "safe names match osu convention" {
    const name = try domain.safeName(std.testing.allocator, "Ari Player");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("ari_player", name);
}

test "standard accuracy" {
    const s: domain.Score = .{ .user_id = 1, .map_md5 = "x", .mode = .osu, .mods = 0, .score = 1, .accuracy = 0, .max_combo = 1, .n300 = 9, .n100 = 1, .n50 = 0, .nmiss = 0, .ngeki = 0, .nkatu = 0, .perfect = false, .passed = true };
    try std.testing.expectApproxEqAbs(@as(f64, 93.333333), domain.accuracy(s), 0.0001);
}

test "client rate limit keys prefer Cloudflare and reject junk" {
    try std.testing.expectEqualStrings("203.0.113.7", rate_limit.clientKey("203.0.113.7", "198.51.100.1", "127.0.0.1"));
    try std.testing.expectEqualStrings("2001:db8::1", rate_limit.clientKey(null, " 2001:db8::1, 10.0.0.1 ", null));
    try std.testing.expectEqualStrings("proxy", rate_limit.clientKey("not an ip", "also/bad", null));
}

test "fixed window rate limiter returns a real retry boundary" {
    var limiter = rate_limit.Limiter.init(std.testing.allocator, std.testing.io);
    defer limiter.deinit();
    const rule: rate_limit.Rule = .{ .name = "test", .limit = 2, .window_seconds = 10 };
    const first = try limiter.checkAt("203.0.113.8", rule, 100);
    const second = try limiter.checkAt("203.0.113.8", rule, 101);
    const denied = try limiter.checkAt("203.0.113.8", rule, 102);
    try std.testing.expect(first.allowed);
    try std.testing.expectEqual(@as(u32, 1), first.remaining);
    try std.testing.expect(second.allowed);
    try std.testing.expectEqual(@as(u32, 0), second.remaining);
    try std.testing.expect(!denied.allowed);
    try std.testing.expectEqual(@as(u32, 8), denied.retry_after);
    const reset = try limiter.checkAt("203.0.113.8", rule, 110);
    try std.testing.expect(reset.allowed);
    try std.testing.expectEqual(@as(u32, 1), reset.remaining);
}

test "rate limit classes do not consume each other" {
    var limiter = rate_limit.Limiter.init(std.testing.allocator, std.testing.io);
    defer limiter.deinit();
    const strict: rate_limit.Rule = .{ .name = "strict", .limit = 1, .window_seconds = 60 };
    const other: rate_limit.Rule = .{ .name = "other", .limit = 1, .window_seconds = 60 };
    try std.testing.expect((try limiter.checkAt("203.0.113.9", strict, 50)).allowed);
    try std.testing.expect(!(try limiter.checkAt("203.0.113.9", strict, 51)).allowed);
    try std.testing.expect((try limiter.checkAt("203.0.113.9", other, 51)).allowed);
}

test "rate limiter stays bounded and only evicts expired clients" {
    var limiter = rate_limit.Limiter.init(std.testing.allocator, std.testing.io);
    defer limiter.deinit();
    limiter.max_entries = 1;
    const rule: rate_limit.Rule = .{ .name = "bounded", .limit = 2, .window_seconds = 10 };
    try std.testing.expect((try limiter.checkAt("203.0.113.20", rule, 100)).allowed);
    try std.testing.expectError(error.RateLimitCapacity, limiter.checkAt("203.0.113.21", rule, 101));
    try std.testing.expect((try limiter.checkAt("203.0.113.21", rule, 110)).allowed);
    try std.testing.expectEqual(@as(usize, 1), limiter.entries.count());
}

test "pinned performance engine calculates the synthetic stable fixture" {
    const map = @embedFile("testdata/synthetic-standard.osu");
    const result = try pp.calculate(map, .{
        .mode = 0,
        .lazer = 0,
        .mods = 0,
        .max_combo = 10,
        .n_geki = 0,
        .n_katu = 0,
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .misses = 0,
        .legacy_total_score = 1_000_000,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 26.797973284), result.pp, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.793060769), result.stars, 0.0001);
    try std.testing.expectEqual(@as(u32, 10), result.max_combo);
}

test "stable performance fixtures lock every ruleset and common mod path" {
    const Fixture = struct { mode: u8, map: []const u8, perfect_geki: u32 };
    const fixtures = [_]Fixture{
        .{ .mode = 0, .map = @embedFile("testdata/synthetic-standard.osu"), .perfect_geki = 0 },
        .{ .mode = 1, .map = @embedFile("testdata/synthetic-taiko.osu"), .perfect_geki = 0 },
        .{ .mode = 2, .map = @embedFile("testdata/synthetic-catch.osu"), .perfect_geki = 0 },
        .{ .mode = 3, .map = @embedFile("testdata/synthetic-mania.osu"), .perfect_geki = 10 },
    };
    const expected_fc = [_]f64{ 26.797973284, 15.285055735, 2.549129656, 0.740224547 };
    const expected_miss = [_]f64{ 4.974535079, 5.721262823, 1.335003302, 0.370112274 };
    const expected_hr = [_]f64{ 58.137599685, 46.303420330, 5.138172491, 0.740224547 };
    const expected_hd = [_]f64{ 29.124396934, 16.420406956, 3.058955588, 0.740224547 };
    const expected_dt = [_]f64{ 55.280056660, 49.244979734, 3.316334352, 0.616461172 };
    const expected_stars = [_]f64{ 1.793060769, 0.641015657, 0.511244829, 0.488838504 };
    const expected_max_combo = [_]u32{ 10, 10, 10, 20 };
    for (fixtures, 0..) |fixture, index| {
        const full_combo = try pp.calculate(fixture.map, .{
            .mode = fixture.mode,
            .lazer = 0,
            .mods = 0,
            .max_combo = 10,
            .n_geki = fixture.perfect_geki,
            .n_katu = 0,
            .n300 = if (fixture.mode == 3) 0 else 10,
            .n100 = 0,
            .n50 = 0,
            .misses = 0,
            .legacy_total_score = 1_000_000,
        });
        const missed = try pp.calculate(fixture.map, .{
            .mode = fixture.mode,
            .lazer = 0,
            .mods = 0,
            .max_combo = 9,
            .n_geki = if (fixture.mode == 3) 9 else 0,
            .n_katu = 0,
            .n300 = if (fixture.mode == 3) 0 else 9,
            .n100 = 0,
            .n50 = 0,
            .misses = 1,
            .legacy_total_score = 800_000,
        });
        const hard_rock = try pp.calculate(fixture.map, .{
            .mode = fixture.mode,
            .lazer = 0,
            .mods = 16,
            .max_combo = 10,
            .n_geki = fixture.perfect_geki,
            .n_katu = 0,
            .n300 = if (fixture.mode == 3) 0 else 10,
            .n100 = 0,
            .n50 = 0,
            .misses = 0,
            .legacy_total_score = 1_000_000,
        });
        const hidden = try pp.calculate(fixture.map, .{
            .mode = fixture.mode,
            .lazer = 0,
            .mods = 8,
            .max_combo = 10,
            .n_geki = fixture.perfect_geki,
            .n_katu = 0,
            .n300 = if (fixture.mode == 3) 0 else 10,
            .n100 = 0,
            .n50 = 0,
            .misses = 0,
            .legacy_total_score = 1_000_000,
        });
        const double_time = try pp.calculate(fixture.map, .{
            .mode = fixture.mode,
            .lazer = 0,
            .mods = 64,
            .max_combo = 10,
            .n_geki = fixture.perfect_geki,
            .n_katu = 0,
            .n300 = if (fixture.mode == 3) 0 else 10,
            .n100 = 0,
            .n50 = 0,
            .misses = 0,
            .legacy_total_score = 1_000_000,
        });
        try std.testing.expectApproxEqAbs(expected_fc[index], full_combo.pp, 0.0001);
        try std.testing.expectApproxEqAbs(expected_miss[index], missed.pp, 0.0001);
        try std.testing.expectApproxEqAbs(expected_hr[index], hard_rock.pp, 0.0001);
        try std.testing.expectApproxEqAbs(expected_hd[index], hidden.pp, 0.0001);
        try std.testing.expectApproxEqAbs(expected_dt[index], double_time.pp, 0.0001);
        try std.testing.expectApproxEqAbs(expected_stars[index], full_combo.stars, 0.0001);
        try std.testing.expectEqual(expected_max_combo[index], full_combo.max_combo);
        try std.testing.expect(missed.pp < full_combo.pp);
    }
    try std.testing.expectEqual(@as(?u8, 0), stable_score.statsMode(0, 0));
    try std.testing.expectEqual(@as(?u8, 1), stable_score.statsMode(1, 0));
    try std.testing.expectEqual(@as(?u8, 2), stable_score.statsMode(2, 0));
    try std.testing.expectEqual(@as(?u8, 3), stable_score.statsMode(3, 0));
    try std.testing.expectEqual(@as(?u8, 4), stable_score.statsMode(0, 128));
    try std.testing.expectEqual(@as(?u8, 5), stable_score.statsMode(1, 128));
    try std.testing.expectEqual(@as(?u8, 6), stable_score.statsMode(2, 128));
    try std.testing.expectEqual(@as(?u8, null), stable_score.statsMode(3, 128));
    try std.testing.expectEqual(@as(?u8, 8), stable_score.statsMode(0, 8192));
    try std.testing.expectEqual(@as(?u8, null), stable_score.statsMode(1, 8192));
    try std.testing.expectEqual(@as(?u8, null), stable_score.statsMode(2, 8192));
    try std.testing.expectEqual(@as(?u8, null), stable_score.statsMode(3, 8192));
}

test "native performance combo counts sliders spinners and converted objects" {
    const map = @embedFile("testdata/synthetic-slider-combo.osu");
    const expected = [_]u32{ 7, 1, 3, 33 };
    for (expected, 0..) |max_combo, mode| {
        const result = try pp.calculate(map, .{
            .mode = @intCast(mode),
            .lazer = 0,
            .mods = 0,
            .max_combo = max_combo,
            .n_geki = if (mode == 3) 3 else 0,
            .n_katu = 0,
            .n300 = if (mode == 3) 0 else 3,
            .n100 = 0,
            .n50 = 0,
            .misses = 0,
            .legacy_total_score = 1_000_000,
        });
        try std.testing.expectEqual(max_combo, result.max_combo);
        try std.testing.expect(std.math.isFinite(result.pp));
        try std.testing.expect(std.math.isFinite(result.stars));
    }
}

test "native stable performance fixtures lock relax and autopilot" {
    const Fixture = struct { mode: u8, map: []const u8, mods: u32, expected_pp: f64, expected_stars: f64 };
    const fixtures = [_]Fixture{
        .{ .mode = 0, .map = @embedFile("testdata/synthetic-standard.osu"), .mods = 128, .expected_pp = 2.839156, .expected_stars = 1.572586 },
        .{ .mode = 1, .map = @embedFile("testdata/synthetic-taiko.osu"), .mods = 128, .expected_pp = 13.168693, .expected_stars = 0.279849 },
        .{ .mode = 2, .map = @embedFile("testdata/synthetic-catch.osu"), .mods = 128, .expected_pp = 2.549130, .expected_stars = 0.511245 },
        .{ .mode = 0, .map = @embedFile("testdata/synthetic-standard.osu"), .mods = 8192, .expected_pp = 23.612298, .expected_stars = 0.718662 },
    };
    for (fixtures) |fixture| {
        const result = try pp.calculate(fixture.map, .{
            .mode = fixture.mode,
            .lazer = 0,
            .mods = fixture.mods,
            .max_combo = 10,
            .n_geki = 0,
            .n_katu = 0,
            .n300 = 10,
            .n100 = 0,
            .n50 = 0,
            .misses = 0,
            .legacy_total_score = 1_000_000,
        });
        try std.testing.expectApproxEqAbs(fixture.expected_pp, result.pp, 0.0001);
        try std.testing.expectApproxEqAbs(fixture.expected_stars, result.stars, 0.0001);
    }
    try std.testing.expectError(error.UnsupportedModMode, pp.calculate(@embedFile("testdata/synthetic-mania.osu"), .{
        .mode = 3,
        .lazer = 0,
        .mods = 128,
        .max_combo = 10,
        .n_geki = 10,
        .n_katu = 0,
        .n300 = 0,
        .n100 = 0,
        .n50 = 0,
        .misses = 0,
        .legacy_total_score = 1_000_000,
    }));
    try std.testing.expectError(error.UnsupportedModMode, pp.calculate(@embedFile("testdata/synthetic-taiko.osu"), .{
        .mode = 1,
        .lazer = 0,
        .mods = 8192,
        .max_combo = 10,
        .n_geki = 0,
        .n_katu = 0,
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .misses = 0,
        .legacy_total_score = 1_000_000,
    }));
}

test "exact stable calculator locks the live scorev2 map and partial play" {
    const map = @embedFile("testdata/disco-prince-normal.osu");
    const full_combo = try pp.calculate(map, .{
        .mode = 0,
        .lazer = 0,
        .mods = 1 << 29,
        .max_combo = 314,
        .n_geki = 0,
        .n_katu = 0,
        .n300 = 194,
        .n100 = 0,
        .n50 = 0,
        .misses = 0,
        .legacy_total_score = 1_005_340,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 36.685654210), full_combo.pp, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.626949895), full_combo.stars, 0.0001);
    try std.testing.expectEqual(@as(u32, 314), full_combo.max_combo);

    const failed_prefix = try pp.calculate(map, .{
        .mode = 0,
        .lazer = 0,
        .mods = 1 << 29,
        .max_combo = 40,
        .n_geki = 0,
        .n_katu = 0,
        .n300 = 50,
        .n100 = 4,
        .n50 = 0,
        .misses = 6,
        .legacy_total_score = 65_000,
    });
    try std.testing.expect(failed_prefix.stars < full_combo.stars);
    try std.testing.expect(failed_prefix.pp < full_combo.pp);
}

test "native performance engine survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ppAllocationRun, .{{}});
}

test "beatmap metadata parser owns the import contract" {
    const map = @embedFile("testdata/synthetic-standard.osu");
    const metadata = try beatmap.parse(map);
    try std.testing.expectEqual(@as(i32, 900000001), metadata.id);
    try std.testing.expectEqual(@as(i32, 900000000), metadata.set_id);
    try std.testing.expectEqualStrings("Zigcho", metadata.artist);
    try std.testing.expectEqualStrings("Zigcho Fixture", metadata.title);
    try std.testing.expectEqualStrings("synthetic.mp3", metadata.audio_filename);
    try std.testing.expectEqual(@as(i32, -1), metadata.preview_time);
    try std.testing.expectEqual(@as(u32, 10), metadata.object_count);
    try std.testing.expectEqual(@as(u32, 10), metadata.count_circles);
    try std.testing.expectEqual(@as(u32, 0), metadata.count_sliders);
    try std.testing.expectEqual(@as(u32, 0), metadata.count_spinners);
    try std.testing.expectApproxEqAbs(@as(f64, 120), metadata.bpm, 0.001);
    try std.testing.expectEqualStrings("f981bd174d2fc7bdbefa557e85877e5a", &beatmap.md5(map));
}

test "performance engine rejects unsupported modes" {
    const map = @embedFile("testdata/synthetic-standard.osu");
    try std.testing.expectError(error.PerformanceCalculationFailed, pp.calculate(map, .{
        .mode = 4,
        .lazer = 0,
        .mods = 0,
        .max_combo = 10,
        .n_geki = 0,
        .n_katu = 0,
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .misses = 0,
        .legacy_total_score = 1_000_000,
    }));
}

test "ranked stable PP is stored and updates normal player stats" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/pp.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(1,'ari','ari',x'00',x'00'); INSERT INTO stats(user_id,mode) VALUES(1,0),(1,4)");
    const map = @embedFile("testdata/synthetic-standard.osu");
    const metadata = try beatmap.parse(map);
    const hash = beatmap.md5(map);
    try store.upsertBeatmap(metadata, &hash, 3, 1.7931, 10, map);
    const mapper: upstream_user.Profile = .{
        .id = 4_452_992,
        .username = "Ari",
        .country = .{ 'A', 'U' },
        .join_date = "2014-05-28T17:34:35Z",
        .mode = 0,
        .pp = 6440.47,
        .global_rank = 50_128,
        .country_rank = 1563,
        .ranked_score = 22_490_858_468,
        .total_score = 91_822_598_773,
        .play_count = 45_597,
        .play_time = 1_000,
        .level = 100.649,
        .accuracy = 99.301498,
        .total_hits = 10_002_288,
        .grade_ssh = 251,
        .grade_ss = 64,
        .grade_sh = 1502,
        .grade_s = 566,
        .grade_a = 780,
    };
    const mapper_json = try upstream_user.jsonOwned(std.testing.allocator, mapper);
    defer std.testing.allocator.free(mapper_json);
    try store.upsertUpstreamUserProfile(mapper, mapper_json, 1_787_456_000);
    try store.linkBeatmapSetCreator(metadata.set_id, mapper.id);
    try store.upsertBeatmapSetMetadata(.{
        .set_id = metadata.set_id,
        .favourites = 39,
        .submitted_date = "2026-08-20T00:00:00Z",
        .last_updated = "2026-08-22T05:45:08Z",
        .ranked_date = "2026-08-22T05:45:08Z",
        .has_video = true,
        .genre_id = 4,
        .language_id = 2,
    }, 1_787_456_000);
    try store.updateBeatmapUpstreamStats(metadata.id, 123, 45, 9);
    try std.testing.expect(try store.addFavourite(1, metadata.set_id));
    const archive_bytes = "PK\x03\x04synthetic archive fixture";
    var archive_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive_bytes, &archive_digest, .{});
    const archive_sha256 = std.fmt.bytesToHex(archive_digest, .lower);
    try store.upsertBeatmapArchive(metadata.set_id, &archive_sha256, archive_bytes);
    const stored_archive = (try store.beatmapArchive(std.testing.allocator, metadata.set_id)).?;
    defer std.testing.allocator.free(stored_archive);
    try std.testing.expectEqualStrings(archive_bytes, stored_archive);
    const lazer_set = (try store.lazerBeatmapSet(std.testing.allocator, metadata.set_id, null)).?;
    defer std.testing.allocator.free(lazer_set);
    const parsed_set = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lazer_set, .{});
    defer parsed_set.deinit();
    try std.testing.expectEqual(@as(i64, 900000000), parsed_set.value.object.get("id").?.integer);
    try std.testing.expectEqualStrings("ranked", parsed_set.value.object.get("status").?.string);
    try std.testing.expectEqual(@as(i64, mapper.id), parsed_set.value.object.get("user_id").?.integer);
    // Upstream popularity is retained for metadata provenance only. Every
    // player-visible counter belongs to kai and starts from local activity.
    try std.testing.expectEqual(@as(i64, 0), parsed_set.value.object.get("play_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), parsed_set.value.object.get("favourite_count").?.integer);
    try std.testing.expect(parsed_set.value.object.get("video").?.bool);
    try std.testing.expectEqualStrings("Rock", parsed_set.value.object.get("genre").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("English", parsed_set.value.object.get("language").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("https://a.ppy.sh/4452992", parsed_set.value.object.get("user").?.object.get("avatar_url").?.string);
    try std.testing.expect(!parsed_set.value.object.get("availability").?.object.get("download_disabled").?.bool);
    try std.testing.expectEqual(@as(usize, 1), parsed_set.value.object.get("beatmaps").?.array.items.len);
    const detailed_map = parsed_set.value.object.get("beatmaps").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 0), detailed_map.get("playcount").?.integer);
    try std.testing.expectEqual(@as(i64, 0), detailed_map.get("passcount").?.integer);
    try std.testing.expectEqual(@as(i64, 9), detailed_map.get("hit_length").?.integer);
    try std.testing.expectEqual(@as(i64, mapper.id), detailed_map.get("owners").?.array.items[0].object.get("id").?.integer);
    const lazer_lookup = (try store.lazerBeatmapLookup(std.testing.allocator, null, &hash, null)).?;
    defer std.testing.allocator.free(lazer_lookup);
    const parsed_lookup = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lazer_lookup, .{});
    defer parsed_lookup.deinit();
    try std.testing.expectEqual(@as(i64, 900000001), parsed_lookup.value.object.get("id").?.integer);
    try std.testing.expectEqualStrings("ranked", parsed_lookup.value.object.get("status").?.string);
    try std.testing.expectEqual(@as(i64, 0), parsed_lookup.value.object.get("playcount").?.integer);
    try std.testing.expectEqual(@as(i64, 0), parsed_lookup.value.object.get("passcount").?.integer);
    try std.testing.expectEqualStrings("ranked", parsed_lookup.value.object.get("beatmapset").?.object.get("status").?.string);
    const lazer_search = try store.lazerBeatmapSearch(std.testing.allocator, "Fixture", 0, 0, null);
    defer std.testing.allocator.free(lazer_search);
    const parsed_search = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lazer_search, .{});
    defer parsed_search.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed_search.value.object.get("total").?.integer);
    var other_metadata = metadata;
    other_metadata.id = 900000003;
    other_metadata.set_id = 900000002;
    other_metadata.artist = "Other Artist";
    other_metadata.title = "Other Set";
    other_metadata.version = "Other Difficulty";
    const other_hash = "1234567890abcdef1234567890abcdef";
    try store.upsertBeatmapMeta(other_metadata, other_hash, 2, 2.5, 20);
    const ordered_sets = try store.lazerBeatmapSets(std.testing.allocator, &.{ other_metadata.set_id, metadata.set_id }, 0, null);
    defer std.testing.allocator.free(ordered_sets);
    const parsed_ordered_sets = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, ordered_sets, .{});
    defer parsed_ordered_sets.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed_ordered_sets.value.object.get("total").?.integer);
    try std.testing.expectEqual(@as(i64, other_metadata.set_id), parsed_ordered_sets.value.object.get("beatmapsets").?.array.items[0].object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, metadata.set_id), parsed_ordered_sets.value.object.get("beatmapsets").?.array.items[1].object.get("id").?.integer);
    try std.testing.expect(parsed_ordered_sets.value.object.get("beatmapsets").?.array.items[0].object.get("user") == null);
    try std.testing.expectEqual(@as(i64, mapper.id), parsed_ordered_sets.value.object.get("beatmapsets").?.array.items[1].object.get("user").?.object.get("id").?.integer);
    try std.testing.expect(!parsed_ordered_sets.value.object.get("beatmapsets").?.array.items[0].object.get("availability").?.object.get("download_disabled").?.bool);
    const search = try store.stableSearch(std.testing.allocator, "Fixture", -1, 4, 0);
    defer std.testing.allocator.free(search);
    try std.testing.expect(std.mem.startsWith(u8, search, "1\n900000000.osz|Zigcho|Zigcho Fixture|Ari|0|10.0|"));
    try std.testing.expect(std.mem.indexOf(u8, search, "[1.79⭐] Tests {cs: 4") != null);
    const set_lookup = try store.stableSearchSet(std.testing.allocator, null, null, &hash);
    defer std.testing.allocator.free(set_lookup);
    try std.testing.expect(std.mem.startsWith(u8, set_lookup, "900000000.osz|Zigcho|Zigcho Fixture|Ari|0|10.0|"));
    const no_pending = try store.stableSearch(std.testing.allocator, "Fixture", -1, 2, 0);
    defer std.testing.allocator.free(no_pending);
    try std.testing.expectEqualStrings("0", no_pending);
    const score: stable_score.Submission = .{
        .map_md5 = &hash,
        .username = "ari",
        .online_checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .ngeki = 0,
        .nkatu = 0,
        .nmiss = 0,
        .total_score = 1_000_000,
        .max_combo = 10,
        .perfect = true,
        .grade = "X",
        .mods = 0,
        .passed = true,
        .mode = 0,
        .client_time = "260809000000",
        .client_flags = "0",
        .achievement_stars = 3.75,
    };
    const score_id = try store.insertStableScore(1, score, 26.80, "replay", 12_000);
    const local_set = (try store.lazerBeatmapSet(std.testing.allocator, metadata.set_id, null)).?;
    defer std.testing.allocator.free(local_set);
    const parsed_local_set = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, local_set, .{});
    defer parsed_local_set.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed_local_set.value.object.get("play_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), parsed_local_set.value.object.get("favourite_count").?.integer);
    const local_map = parsed_local_set.value.object.get("beatmaps").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 1), local_map.get("playcount").?.integer);
    try std.testing.expectEqual(@as(i64, 1), local_map.get("passcount").?.integer);
    const website_board = (try store.siteBeatmapLeaderboard(std.testing.allocator, 900000001, .all, 0)).?;
    defer std.testing.allocator.free(website_board);
    var parsed_website_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, website_board, .{});
    defer parsed_website_board.deinit();
    const website_first = parsed_website_board.value.object.get("scores").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 1), website_first.get("rank").?.integer);
    try std.testing.expectEqual(score_id, website_first.get("id").?.integer);
    try std.testing.expect(website_first.get("has_replay").?.bool);
    const website_replay = (try store.siteReplay(std.testing.allocator, score_id)).?;
    defer std.testing.allocator.free(website_replay);
    try std.testing.expect(std.mem.indexOf(u8, website_replay, "replay") != null);
    try std.testing.expectEqual(score_id, std.mem.readInt(i64, website_replay[website_replay.len - 8 ..][0..8], .little));
    const snapshot = (try store.ppSnapshot(score_id)).?;
    try std.testing.expectApproxEqAbs(@as(f64, 26.80), snapshot.score, 0.001);
    try std.testing.expectEqual(@as(i64, 27), snapshot.player);
    const mode_stats = (try store.statsForUser(1, 0)).?;
    try std.testing.expectEqual(@as(i64, 1_000_000), mode_stats.ranked_score);
    try std.testing.expectEqual(@as(i64, 1_000_000), mode_stats.total_score);
    try std.testing.expectEqual(@as(i32, 27), mode_stats.pp);
    try std.testing.expectEqual(@as(i32, 1), mode_stats.plays);
    try std.testing.expectEqual(@as(i32, 12), mode_stats.play_time);
    try std.testing.expectEqual(@as(i64, 10), mode_stats.total_hits);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), mode_stats.accuracy, 0.0001);
    try std.testing.expectEqual(@as(i32, 10), mode_stats.max_combo);
    try std.testing.expectEqual(@as(i32, 1), mode_stats.global_rank);
    const stable_profile = (try store.siteProfile(std.testing.allocator, 1, .stable, 0)).?;
    defer std.testing.allocator.free(stable_profile);
    try std.testing.expect(std.mem.indexOf(u8, stable_profile, "\"star_rating\":3.75") != null);

    var failed = score;
    failed.online_checksum = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    failed.total_score = 200_000;
    failed.max_combo = 99;
    failed.n300 = 4;
    failed.n100 = 3;
    failed.nmiss = 9;
    failed.perfect = false;
    failed.grade = "F";
    failed.passed = false;
    _ = try store.insertStableScore(1, failed, 999.0, "", 45_123);
    const after_fail = (try store.statsForUser(1, 0)).?;
    try std.testing.expectEqual(@as(i64, 1_000_000), after_fail.ranked_score);
    try std.testing.expectEqual(@as(i64, 1_200_000), after_fail.total_score);
    try std.testing.expectEqual(@as(i32, 27), after_fail.pp);
    try std.testing.expectEqual(@as(i32, 2), after_fail.plays);
    try std.testing.expectEqual(@as(i32, 57), after_fail.play_time);
    try std.testing.expectEqual(@as(i64, 17), after_fail.total_hits);
    try std.testing.expectApproxEqAbs(mode_stats.accuracy, after_fail.accuracy, 0.0001);
    try std.testing.expectEqual(mode_stats.max_combo, after_fail.max_combo);
    const map_after_fail = (try store.beatmapForScore(&hash)).?;
    try std.testing.expectEqual(@as(i32, 2), map_after_fail.plays);
    try std.testing.expectEqual(@as(i32, 1), map_after_fail.passes);

    var relax = score;
    relax.online_checksum = "cccccccccccccccccccccccccccccccc";
    relax.total_score = 600_000;
    relax.mods = 128;
    _ = try store.insertStableScore(1, relax, 42.5, "relax replay", 15_000);
    const vanilla_after_relax = (try store.statsForUser(1, 0)).?;
    try std.testing.expectEqual(after_fail.ranked_score, vanilla_after_relax.ranked_score);
    try std.testing.expectEqual(after_fail.total_score, vanilla_after_relax.total_score);
    try std.testing.expectEqual(after_fail.pp, vanilla_after_relax.pp);
    try std.testing.expectEqual(after_fail.plays, vanilla_after_relax.plays);
    const relax_stats = (try store.statsForUser(1, 4)).?;
    try std.testing.expectEqual(@as(i64, 600_000), relax_stats.ranked_score);
    try std.testing.expectEqual(@as(i64, 600_000), relax_stats.total_score);
    try std.testing.expectEqual(@as(i32, 43), relax_stats.pp);
    try std.testing.expectEqual(@as(i32, 1), relax_stats.plays);
    try std.testing.expectEqual(@as(i32, 15), relax_stats.play_time);
    try std.testing.expectApproxEqAbs(@as(f64, 1), relax_stats.accuracy, 0.0001);
    try std.testing.expectEqual(@as(i32, 10), relax_stats.max_combo);

    const before_scorev2 = (try store.statsForUser(1, 0)).?;
    var scorev2 = score;
    scorev2.online_checksum = "dddddddddddddddddddddddddddddddd";
    scorev2.total_score = 2_000_000;
    scorev2.max_combo = 999;
    scorev2.mods = stable_mods.score_v2;
    const scorev2_id = try store.insertStableScore(1, scorev2, 1.0, "scorev2 replay", 30_000);
    const scorev2_placement = (try store.scoreLeaderboardPlacement(scorev2_id)).?;
    try std.testing.expect(scorev2_placement.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 0), scorev2_placement.rank);
    const after_scorev2 = (try store.statsForUser(1, 0)).?;
    try std.testing.expectEqualDeep(before_scorev2, after_scorev2);

    var lower_scorev2 = scorev2;
    lower_scorev2.online_checksum = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    lower_scorev2.total_score = 1_500_000;
    const lower_scorev2_id = try store.insertStableScore(1, lower_scorev2, 999.0, "lower scorev2 replay", 30_000);
    const lower_placement = (try store.scoreLeaderboardPlacement(lower_scorev2_id)).?;
    try std.testing.expect(!lower_placement.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 0), lower_placement.rank);
    try std.testing.expectEqualDeep(before_scorev2, (try store.statsForUser(1, 0)).?);

    const scorev2_rankings = try store.siteRankings(std.testing.allocator, .scorev2, 0, 0);
    defer std.testing.allocator.free(scorev2_rankings);
    try std.testing.expect(std.mem.indexOf(u8, scorev2_rankings, "\"source\":\"scorev2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scorev2_rankings, "\"name\":\"ari\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scorev2_rankings, "\"plays\":2") != null);

    const scorev2_profile = (try store.siteProfile(std.testing.allocator, 1, .scorev2, 0)).?;
    defer std.testing.allocator.free(scorev2_profile);
    try std.testing.expect(std.mem.indexOf(u8, scorev2_profile, "\"selected_source\":\"scorev2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scorev2_profile, "\"selected_stats\":{\"ranked_score\":1500000,\"total_score\":3500000,\"pp\":999,\"plays\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, scorev2_profile, "\"namespace\":\"scorev2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scorev2_profile, "\"client\":\"stable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scorev2_profile, "\"mods\":536870912") != null);

    try store.exec("UPDATE stats SET ranked_score=1,total_score=2,pp=3,plays=4,play_time=5,total_hits=6,accuracy=0.7,max_combo=8 WHERE user_id=1 AND mode=0");
    _ = try store.applyBeatmapRankAction(1, &hash, .rank, "rebuild scorev2 isolation");
    const rebuilt = (try store.statsForUser(1, 0)).?;
    try std.testing.expectEqualDeep(before_scorev2, rebuilt);
}

test "stable score storage keeps every supported ruleset and namespace isolated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/mode-matrix.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(1,'ari','ari',x'00',x'00'); INSERT INTO stats(user_id,mode) VALUES(1,0),(1,1),(1,2),(1,3),(1,4),(1,5),(1,6),(1,7),(1,8)");

    const fixture_maps = [_][]const u8{
        @embedFile("testdata/synthetic-standard.osu"),
        @embedFile("testdata/synthetic-taiko.osu"),
        @embedFile("testdata/synthetic-catch.osu"),
        @embedFile("testdata/synthetic-mania.osu"),
    };
    var hashes: [fixture_maps.len][32]u8 = undefined;
    for (fixture_maps, 0..) |contents, index| {
        const metadata = try beatmap.parse(contents);
        hashes[index] = beatmap.md5(contents);
        try store.upsertBeatmap(metadata, &hashes[index], 3, 1.0, 10, contents);
    }

    const cases = [_]struct { mode: u8, mods: i32, stats_mode: u8 }{
        .{ .mode = 0, .mods = 0, .stats_mode = 0 },
        .{ .mode = 1, .mods = 0, .stats_mode = 1 },
        .{ .mode = 2, .mods = 0, .stats_mode = 2 },
        .{ .mode = 3, .mods = 0, .stats_mode = 3 },
        .{ .mode = 0, .mods = 128, .stats_mode = 4 },
        .{ .mode = 1, .mods = 128, .stats_mode = 5 },
        .{ .mode = 2, .mods = 128, .stats_mode = 6 },
        .{ .mode = 0, .mods = 8192, .stats_mode = 8 },
    };
    for (cases, 0..) |case, index| {
        var checksum_buf: [32]u8 = undefined;
        @memset(&checksum_buf, @intCast('a' + index));
        const passed_score: stable_score.Submission = .{
            .map_md5 = &hashes[case.mode],
            .username = "ari",
            .online_checksum = &checksum_buf,
            .n300 = 10,
            .n100 = 0,
            .n50 = 0,
            .ngeki = 0,
            .nkatu = 0,
            .nmiss = 0,
            .total_score = 1_000_000 + @as(i64, case.stats_mode) * 1_000,
            .max_combo = 10,
            .perfect = true,
            .grade = "X",
            .mods = case.mods,
            .passed = true,
            .mode = case.mode,
            .client_time = "260809000000",
            .client_flags = "0",
        };
        _ = try store.insertStableScore(1, passed_score, 100.0 + @as(f64, @floatFromInt(case.stats_mode)), "replay", 12_000);
        const after_pass = (try store.statsForUser(1, case.stats_mode)).?;
        try std.testing.expectEqual(passed_score.total_score, after_pass.ranked_score);
        try std.testing.expectEqual(passed_score.total_score, after_pass.total_score);
        try std.testing.expectEqual(@as(i32, 1), after_pass.plays);
        try std.testing.expectEqual(@as(i32, 12), after_pass.play_time);
        try std.testing.expectEqual(@as(i64, 10), after_pass.total_hits);
        try std.testing.expectEqual(@as(i32, 10), after_pass.max_combo);

        var failed_checksum: [32]u8 = undefined;
        @memset(&failed_checksum, @intCast('k' + index));
        var failed_score = passed_score;
        failed_score.online_checksum = &failed_checksum;
        failed_score.total_score = 200_000;
        failed_score.n300 = 4;
        failed_score.n100 = 3;
        failed_score.nmiss = 9;
        failed_score.max_combo = 99;
        failed_score.perfect = false;
        failed_score.grade = "F";
        failed_score.passed = false;
        _ = try store.insertStableScore(1, failed_score, 999.0, "", 45_000);
        const after_fail = (try store.statsForUser(1, case.stats_mode)).?;
        try std.testing.expectEqual(after_pass.ranked_score, after_fail.ranked_score);
        try std.testing.expectEqual(after_pass.total_score + 200_000, after_fail.total_score);
        try std.testing.expectEqual(after_pass.pp, after_fail.pp);
        try std.testing.expectEqual(after_pass.accuracy, after_fail.accuracy);
        try std.testing.expectEqual(after_pass.max_combo, after_fail.max_combo);
        try std.testing.expectEqual(@as(i32, 2), after_fail.plays);
        try std.testing.expectEqual(@as(i32, 57), after_fail.play_time);
        try std.testing.expectEqual(@as(i64, 17), after_fail.total_hits);
    }

    var unsupported = stable_score.Submission{
        .map_md5 = &hashes[3],
        .username = "ari",
        .online_checksum = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .ngeki = 0,
        .nkatu = 0,
        .nmiss = 0,
        .total_score = 1_000_000,
        .max_combo = 10,
        .perfect = true,
        .grade = "X",
        .mods = 128,
        .passed = true,
        .mode = 3,
        .client_time = "260809000000",
        .client_flags = "0",
    };
    try std.testing.expectError(error.UnsupportedModMode, store.insertStableScore(1, unsupported, 100.0, "", 12_000));
    unsupported.map_md5 = &hashes[1];
    unsupported.mode = 1;
    unsupported.mods = 8192;
    unsupported.online_checksum = "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy";
    try std.testing.expectError(error.UnsupportedModMode, store.insertStableScore(1, unsupported, 100.0, "", 12_000));
}

test "stable ratings persist one vote per player and keep protocol states distinct" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/ratings.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(1,'ari','ari',x'00',x'00'),(2,'raya','raya',x'00',x'00')");
    const map = @embedFile("testdata/synthetic-standard.osu");
    const metadata = try beatmap.parse(map);
    const hash = beatmap.md5(map);
    try store.upsertBeatmap(metadata, &hash, 2, 1.7931, 10, map);

    try std.testing.expectEqual(storage.Store.BeatmapRating.no_exist, try store.rateBeatmap(1, "00000000000000000000000000000000", null));
    try std.testing.expectEqual(storage.Store.BeatmapRating.not_ranked, try store.rateBeatmap(1, &hash, null));
    try store.exec("UPDATE beatmaps SET status=3");
    try std.testing.expectEqual(storage.Store.BeatmapRating.can_rate, try store.rateBeatmap(1, &hash, null));
    const first = try store.rateBeatmap(1, &hash, 8);
    try std.testing.expectApproxEqAbs(@as(f64, 8), first.already_voted, 0.0001);
    const duplicate = try store.rateBeatmap(1, &hash, 10);
    try std.testing.expectApproxEqAbs(@as(f64, 8), duplicate.already_voted, 0.0001);
    const second = try store.rateBeatmap(2, &hash, 10);
    try std.testing.expectApproxEqAbs(@as(f64, 9), second.already_voted, 0.0001);
    const check = try store.rateBeatmap(1, &hash, null);
    try std.testing.expectApproxEqAbs(@as(f64, 9), check.already_voted, 0.0001);
}

test "country presence numbers and country leaderboards use the stored login country" {
    try std.testing.expectEqual(@as(u8, 16), country.numeric("AU"));
    try std.testing.expectEqual(@as(u8, 77), country.numeric("GB"));
    try std.testing.expectEqual(@as(u8, 225), country.numeric("us"));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/country.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO users(id,name,safe_name,password_hash,password_salt,country) VALUES(1,'ari','ari',x'00',x'00','AU'),(2,'other','other',x'00',x'00','US'); INSERT INTO stats(user_id,mode) VALUES(1,0),(2,0)");
    const map = @embedFile("testdata/synthetic-standard.osu");
    const metadata = try beatmap.parse(map);
    const hash = beatmap.md5(map);
    try store.upsertBeatmap(metadata, &hash, 3, 1.7931, 10, map);
    try store.exec(
        "INSERT INTO scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,checksum,rank_namespace,best,time_elapsed) VALUES" ++
            "(1,'f981bd174d2fc7bdbefa557e85877e5a',0,0,900,10,1,10,10,0,0,0,0,0,1,1,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','vanilla',1,10000)," ++
            "(2,'f981bd174d2fc7bdbefa557e85877e5a',0,0,1000,11,1,10,10,0,0,0,0,0,1,1,'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','vanilla',1,10000)",
    );
    const au = try store.stableLeaderboard(std.testing.allocator, .{ .id = 1, .name = "ari", .safe_name = "ari", .country = .{ 'A', 'U' } }, &hash, 0, 4, 0);
    defer std.testing.allocator.free(au);
    try std.testing.expect(std.mem.indexOf(u8, au, "|ari|") != null);
    try std.testing.expect(std.mem.indexOf(u8, au, "|other|") == null);
    const us = try store.stableLeaderboard(std.testing.allocator, .{ .id = 2, .name = "other", .safe_name = "other", .country = .{ 'U', 'S' } }, &hash, 0, 4, 0);
    defer std.testing.allocator.free(us);
    try std.testing.expect(std.mem.indexOf(u8, us, "|other|") != null);
    try std.testing.expect(std.mem.indexOf(u8, us, "|ari|") == null);
    try store.updateCountry(1, .{ 'G', 'B' });
    const moved = (try store.userById(std.testing.allocator, 1)).?;
    defer std.testing.allocator.free(moved.name);
    defer std.testing.allocator.free(moved.safe_name);
    try std.testing.expectEqualStrings("GB", &moved.country);
}

test "kai migration preserves an account already using id three" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/kai.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec(
        sqlite_anticheat_exclusion_downgrade ++
            "DELETE FROM stats WHERE user_id=3; DELETE FROM users WHERE id=3;" ++
            "INSERT INTO users(id,name,safe_name,password_hash,password_salt,country) VALUES(3,'zigcho_lazer_qa2','zigcho_lazer_qa2',x'00',x'00','AU');" ++
            "INSERT INTO stats(user_id,mode,total_score,plays) VALUES(3,0,1234,2);" ++
            "PRAGMA user_version=8;",
    );
    try store.migrate();
    const bot = (try store.userById(std.testing.allocator, 3)).?;
    defer std.testing.allocator.free(bot.name);
    defer std.testing.allocator.free(bot.safe_name);
    try std.testing.expectEqualStrings("kai", bot.name);
    try std.testing.expect(bot.privileges & (1 << 13) != 0);
    try std.testing.expect(bot.privileges & (1 << 14) != 0);
    try std.testing.expectEqual(@as(u8, 25), bancho.clientPrivileges(bot.privileges, false));
    const preserved = (try store.userById(std.testing.allocator, 4)).?;
    defer std.testing.allocator.free(preserved.name);
    defer std.testing.allocator.free(preserved.safe_name);
    try std.testing.expectEqualStrings("zigcho_lazer_qa2", preserved.name);
    const stats = (try store.statsForUser(4, 0)).?;
    try std.testing.expectEqual(@as(i64, 1234), stats.total_score);
    try std.testing.expectEqual(@as(i32, 2), stats.plays);
}

test "migration rebuild moves historical Relax failures out of vanilla stats" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/rebuild.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    try store.exec("INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(1,'ari','ari',x'00',x'00'); INSERT INTO stats(user_id,mode) VALUES(1,0),(1,4)");
    const map = @embedFile("testdata/synthetic-standard.osu");
    const metadata = try beatmap.parse(map);
    const hash = beatmap.md5(map);
    try store.upsertBeatmap(metadata, &hash, 3, 1.7931, 10, map);
    try store.exec(
        sqlite_anticheat_exclusion_downgrade ++
            "INSERT INTO scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,checksum,rank_namespace,best,time_elapsed) VALUES" ++
            "(1,'f981bd174d2fc7bdbefa557e85877e5a',0,0,1000,10,0.98,10,10,0,0,0,0,0,1,1,'11111111111111111111111111111111','vanilla',0,12000)," ++
            "(1,'f981bd174d2fc7bdbefa557e85877e5a',0,128,200,99,0.25,99,2,1,0,8,0,0,0,0,'22222222222222222222222222222222','relax',1,45000);" ++
            "UPDATE stats SET ranked_score=1200,total_score=1200,pp=99,plays=2,play_time=0,total_hits=0,accuracy=0.5,max_combo=99 WHERE user_id=1 AND mode=0;" ++
            "PRAGMA user_version=7;",
    );
    try store.migrate();
    const vanilla = (try store.statsForUser(1, 0)).?;
    try std.testing.expectEqual(@as(i64, 1000), vanilla.ranked_score);
    try std.testing.expectEqual(@as(i64, 1000), vanilla.total_score);
    try std.testing.expectEqual(@as(i32, 10), vanilla.pp);
    try std.testing.expectEqual(@as(i32, 1), vanilla.plays);
    try std.testing.expectEqual(@as(i32, 12), vanilla.play_time);
    try std.testing.expectEqual(@as(i64, 10), vanilla.total_hits);
    try std.testing.expectApproxEqAbs(@as(f64, 0.98), vanilla.accuracy, 0.0001);
    try std.testing.expectEqual(@as(i32, 10), vanilla.max_combo);
    const relax = (try store.statsForUser(1, 4)).?;
    try std.testing.expectEqual(@as(i64, 0), relax.ranked_score);
    try std.testing.expectEqual(@as(i64, 200), relax.total_score);
    try std.testing.expectEqual(@as(i32, 0), relax.pp);
    try std.testing.expectEqual(@as(i32, 1), relax.plays);
    try std.testing.expectEqual(@as(i32, 45), relax.play_time);
    try std.testing.expectEqual(@as(i64, 3), relax.total_hits);
    try std.testing.expectApproxEqAbs(@as(f64, 0), relax.accuracy, 0.0001);
    try std.testing.expectEqual(@as(i32, 0), relax.max_combo);
}
