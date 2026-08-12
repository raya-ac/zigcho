const std = @import("std");
const bancho = @import("bancho.zig");
const protocol = @import("protocol.zig");
const domain = @import("domain.zig");
const lazer = @import("lazer.zig");
const rijndael = @import("rijndael.zig");
const multipart = @import("multipart.zig");
const score_crypto = @import("score_crypto.zig");
const stable_score = @import("stable_score.zig");
const stable_response = @import("stable_response.zig");
const rate_limit = @import("rate_limit.zig");
const pp = @import("pp.zig");
const beatmap = @import("beatmap.zig");
const storage = @import("runtime_storage.zig");
const form_urlencoded = @import("form_urlencoded.zig");
const routing = @import("routing.zig");
const beatmap_sync = @import("beatmap_sync.zig");
const sessions_mod = @import("sessions.zig");
const country = @import("country.zig");
const config_mod = @import("config.zig");
const multiplayer = @import("multiplayer.zig");
const registration = @import("registration.zig");
const postgres = @import("postgres.zig");
const migrate_postgres = @import("migrate_postgres.zig");
const postgres_store = @import("postgres_store.zig");
const webhook = @import("webhook.zig");
const web_auth = @import("web_auth.zig");
const screenshot = @import("screenshot.zig");
const media_contract = @import("media_contract.zig");
const beatmap_media = @import("beatmap_media.zig");

comptime {
    _ = postgres;
    _ = migrate_postgres;
    _ = postgres_store;
    _ = web_auth;
    _ = screenshot;
    _ = media_contract;
    _ = beatmap_media;
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

test "config values stay owned after the source buffer changes" {
    const source = try std.testing.allocator.dupe(
        u8,
        "osu_api_key=first-key\n" ++
            "score_webhook=https://discord.invalid/first\n" ++
            "beatmap_cache_max_bytes=536870912\n" ++
            "beatmap_media_cache_max_bytes=268435456\n" ++
            "osu_api_key=final-key\n",
    );
    var config = try config_mod.parse(std.testing.allocator, source);
    defer config.deinit();

    @memset(source, 'x');
    std.testing.allocator.free(source);

    try std.testing.expectEqualStrings("final-key", config.osu_api_key);
    try std.testing.expectEqualStrings("https://discord.invalid/first", config.score_webhook);
    try std.testing.expectEqual(@as(u64, 536870912), config.beatmap_cache_max_bytes);
    try std.testing.expectEqual(@as(u64, 268435456), config.beatmap_media_cache_max_bytes);
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
    _ = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    var failed: std.atomic.Value(bool) = .init(false);
    var context: AuthStressContext = .{ .store = &store, .failed = &failed };
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const online = try sessions.create(.{ .id = 99, .name = try std.testing.allocator.dupe(u8, "online"), .safe_name = try std.testing.allocator.dupe(u8, "online") }, 0, 0, 0);
    const online_token = online.token;
    const auth_thread = try std.Thread.spawn(.{}, authStress, .{&context});
    const count_thread = try std.Thread.spawn(.{}, countStress, .{&context});
    for (0..100) |_| {
        const poll = (try bancho.pollByToken(std.testing.allocator, &store, &sessions, &online_token, "")).?;
        std.testing.allocator.free(poll);
    }
    auth_thread.join();
    count_thread.join();
    try std.testing.expect(!failed.load(.acquire));
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
    _ = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    var context: LoginAllocationContext = .{ .store = &store, .body = ari_stable_login };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, loginAllocationRun, .{&context});
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

test "exact stable hardware matches restrict both accounts without partial false positives" {
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
    try std.testing.expect(!partial_result.restricted());
    var second_exact = try store.recordClientHardware(41, exact);
    defer second_exact.deinit();
    try std.testing.expectEqualSlices(i32, &.{40}, second_exact.matched_user_ids);

    const first_user = (try store.userById(std.testing.allocator, 40)).?;
    defer std.testing.allocator.free(first_user.name);
    defer std.testing.allocator.free(first_user.safe_name);
    const second_user = (try store.userById(std.testing.allocator, 41)).?;
    defer std.testing.allocator.free(second_user.name);
    defer std.testing.allocator.free(second_user.safe_name);
    try std.testing.expect(first_user.restricted);
    try std.testing.expect(second_user.restricted);

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
    try std.testing.expect(!common_two.restricted());
}

test "an exact hardware login restricts both accounts and disconnects the matched session" {
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
    try std.testing.expect(sessions.byUser(first_id) != null);

    const second_body = "second\n00000000000000000000000000000000\n" ++ stable_login_details;
    var second_login = try bancho.login(std.testing.allocator, &store, &sessions, second_body, .{ 'A', 'U' }, 0, 0);
    defer second_login.deinit();
    try std.testing.expect(sessions.byUser(first_id) == null);
    try std.testing.expect(sessions.byUser(second_id).?.user.restricted);
    try expectPacket(second_login.body, .account_restricted);

    const first_user = (try store.userById(std.testing.allocator, first_id)).?;
    defer std.testing.allocator.free(first_user.name);
    defer std.testing.allocator.free(first_user.safe_name);
    try std.testing.expect(first_user.restricted);
}

test "high confidence stable client flags restrict once while registry evidence stays audit only" {
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
    try std.testing.expect(try store.restrictForClientFlag(50, hq_flags));
    try std.testing.expect(!try store.restrictForClientFlag(50, hq_flags));
    const hq_user = (try store.userById(std.testing.allocator, 50)).?;
    defer std.testing.allocator.free(hq_user.name);
    defer std.testing.allocator.free(hq_user.safe_name);
    try std.testing.expect(hq_user.restricted);

    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    _ = try sessions.create(try testSessionUser(std.testing.allocator, 50, "hq"), 0, 0, 0);
    bancho.disconnectRestrictedUser(std.testing.allocator, &sessions, 50);
    try std.testing.expect(sessions.byUser(50) == null);
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
    const jpeg = "\xff\xd8\xffcover bytes\xff\xd9";
    const ogg = "OggSpreview bytes";
    try store.putBeatmapMedia(metadata.set_id, .cover, .jpeg, jpeg);
    try store.putBeatmapMedia(metadata.set_id, .preview, .ogg, ogg);
    try std.testing.expectError(error.InvalidBeatmapMedia, store.putBeatmapMedia(metadata.set_id, .cover, .ogg, ogg));
    try std.testing.expectError(error.UnknownBeatmapSet, store.putBeatmapMedia(metadata.set_id + 1, .cover, .jpeg, jpeg));
    var cover = (try store.beatmapMedia(std.testing.allocator, metadata.set_id, .cover)).?;
    defer cover.deinit(std.testing.allocator);
    try std.testing.expectEqual(media_contract.ContentType.jpeg, cover.content_type);
    try std.testing.expectEqualSlices(u8, jpeg, cover.data);
    var preview = (try store.beatmapMedia(std.testing.allocator, metadata.set_id, .preview)).?;
    defer preview.deinit(std.testing.allocator);
    try std.testing.expectEqual(media_contract.ContentType.ogg, preview.content_type);
    try std.testing.expectEqualSlices(u8, ogg, preview.data);
    const before = try store.beatmapMediaCacheStats();
    try std.testing.expectEqual(@as(i64, 2), before.entries);
    try std.testing.expectEqual(@as(i64, jpeg.len + ogg.len), before.bytes);
    const pruned = try store.pruneBeatmapMedia(0);
    try std.testing.expectEqual(@as(i64, 2), pruned.entries);
    try std.testing.expectEqual(@as(i64, 0), (try store.beatmapMediaCacheStats()).entries);
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
    const response = try stable_response.scoreSubmission(std.testing.allocator, 4, 99, score, .{ .id = 10, .set_id = 20, .plays = 8, .passes = 6 }, .{ .rank = 3, .submitted_is_best = true }, .{ .global_rank = 8, .pp = 100 }, .{ .global_rank = 7, .pp = 120 }, 42.25);
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
    const site_rankings = try store.siteRankings(std.testing.allocator, 0, 0);
    defer std.testing.allocator.free(site_rankings);
    try std.testing.expect(std.mem.indexOf(u8, site_rankings, "\"rank\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_rankings, "\"name\":\"requester\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_rankings, "\"pp\":27") != null);
    const site_profile = (try store.siteProfile(std.testing.allocator, requester, 0)).?;
    defer std.testing.allocator.free(site_profile);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"country\":\"XX\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"global_rank\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "Zigcho Fixture") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"selected_mode\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"namespace\":\"vanilla\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"passed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"pinned_scores\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"top_scores\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"recent_scores\":[{") != null);
    const empty_autopilot_profile = (try store.siteProfile(std.testing.allocator, requester, 8)).?;
    defer std.testing.allocator.free(empty_autopilot_profile);
    try std.testing.expect(std.mem.indexOf(u8, empty_autopilot_profile, "\"selected_mode\":8") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_autopilot_profile, "\"pinned_scores\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_autopilot_profile, "\"top_scores\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_autopilot_profile, "\"recent_scores\":[]") != null);
    try std.testing.expect((try store.siteProfile(std.testing.allocator, 999_999, 0)) == null);
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

    const profile = (try store.siteProfile(std.testing.allocator, user_id, 0)).?;
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

    const profile = (try store.siteProfile(std.testing.allocator, user_id, 0)).?;
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
    const after_unpin = (try store.siteProfile(std.testing.allocator, user_id, 0)).?;
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

    const overview = try store.staffOverviewJson(std.testing.allocator);
    defer std.testing.allocator.free(overview);
    try std.testing.expect(std.mem.indexOf(u8, overview, "\"open_appeals\":1") != null);
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
}

test "Akatsuki archives only yield the exact MD5 map" {
    const map = @embedFile("testdata/synthetic-standard.osu");
    const archive = try storedZip(std.testing.allocator, "Zigcho [Tests].osu", map);
    defer std.testing.allocator.free(archive);
    const hash = beatmap.md5(map);
    const extracted = (try beatmap_sync.extractMatchingOsu(std.testing.allocator, archive, &hash)).?;
    defer std.testing.allocator.free(extracted);
    try std.testing.expectEqualStrings(map, extracted);
    try std.testing.expect((try beatmap_sync.extractMatchingOsu(std.testing.allocator, archive, "00000000000000000000000000000000")) == null);
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

    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const first = try sessions.create(.{
        .id = 1,
        .name = try std.testing.allocator.dupe(u8, "ari"),
        .safe_name = try std.testing.allocator.dupe(u8, "ari"),
    }, 0, 0, 0);
    const stale_token = first.token;
    const first_poll = (try bancho.pollByToken(std.testing.allocator, &store, &sessions, &stale_token, "")).?;
    defer std.testing.allocator.free(first_poll);

    sessions.mutex.lockUncancelable(sessions.io);
    const replacement = sessions.create(.{
        .id = 1,
        .name = try std.testing.allocator.dupe(u8, "ari"),
        .safe_name = try std.testing.allocator.dupe(u8, "ari"),
    }, 0, 0, 0) catch |err| {
        sessions.mutex.unlock(sessions.io);
        return err;
    };
    const replacement_token = replacement.token;
    sessions.mutex.unlock(sessions.io);

    try std.testing.expect((try bancho.pollByToken(std.testing.allocator, &store, &sessions, &stale_token, "")) == null);
    const replacement_poll = (try bancho.pollByToken(std.testing.allocator, &store, &sessions, &replacement_token, "")).?;
    defer std.testing.allocator.free(replacement_poll);
    try std.testing.expectEqual(@as(usize, 0), replacement_poll.len);
}

test "stable score token authorization keeps restart compatibility without accepting a foreign live token" {
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const ari = try sessions.create(.{ .id = 1, .name = try std.testing.allocator.dupe(u8, "ari"), .safe_name = try std.testing.allocator.dupe(u8, "ari") }, 0, 0, 0);
    const raya = try sessions.create(.{ .id = 2, .name = try std.testing.allocator.dupe(u8, "raya"), .safe_name = try std.testing.allocator.dupe(u8, "raya") }, 0, 0, 0);
    const ari_token = ari.token;
    const raya_token = raya.token;

    try std.testing.expectEqual(sessions_mod.ScoreTokenAuthorization.exact, sessions.authorizeScoreToken(&ari_token, 1));
    try std.testing.expectEqual(sessions_mod.ScoreTokenAuthorization.foreign_live, sessions.authorizeScoreToken(&raya_token, 1));
    try std.testing.expectEqual(sessions_mod.ScoreTokenAuthorization.stale_online, sessions.authorizeScoreToken("stale-after-restart", 1));
    try std.testing.expectEqual(sessions_mod.ScoreTokenAuthorization.offline, sessions.authorizeScoreToken("stale-after-restart", 99));
    try std.testing.expectEqual(sessions_mod.ScoreTokenAuthorization.missing, sessions.authorizeScoreToken(null, 1));
}

test "logout removes the session and tells the remaining clients" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/session-logout.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();
    const leaving = try sessions.create(.{ .id = 1, .name = try std.testing.allocator.dupe(u8, "ari"), .safe_name = try std.testing.allocator.dupe(u8, "ari") }, 0, 0, 0);
    const remaining = try sessions.create(.{ .id = 2, .name = try std.testing.allocator.dupe(u8, "raya"), .safe_name = try std.testing.allocator.dupe(u8, "raya") }, 0, 0, 0);
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
        "INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES" ++
            "(40,'sender','sender',x'00',x'00'),(41,'target','target',x'00',x'00')",
    );

    const initial = try store.friendIds(std.testing.allocator, 40);
    defer std.testing.allocator.free(initial);
    try std.testing.expectEqualSlices(i32, &.{3}, initial);
    try std.testing.expect(try store.addFriend(40, 41));
    try std.testing.expect(!try store.addFriend(40, 41));
    try std.testing.expect(!try store.addFriend(40, 40));
    try std.testing.expect(!try store.addFriend(40, 3));
    const sender_friends = try store.friendIds(std.testing.allocator, 40);
    defer std.testing.allocator.free(sender_friends);
    try std.testing.expect(std.mem.indexOfScalar(i32, sender_friends, 41) != null);
    try std.testing.expect(std.mem.indexOfScalar(i32, sender_friends, 3) != null);
    const target_friends = try store.friendIds(std.testing.allocator, 41);
    defer std.testing.allocator.free(target_friends);
    try std.testing.expectEqualSlices(i32, &.{3}, target_friends);
    try std.testing.expect(try store.removeFriend(40, 41));
    try std.testing.expect(!try store.removeFriend(40, 41));
    try std.testing.expect(!try store.removeFriend(40, 3));

    try std.testing.expect(try store.addFavourite(40, 900000000));
    try std.testing.expect(!try store.addFavourite(40, 900000000));
    try std.testing.expect(try store.addFavourite(40, 900000001));
    try std.testing.expectError(error.InvalidBeatmapSet, store.addFavourite(40, 0));
    const favourites = try store.favouriteSetIds(std.testing.allocator, 40);
    defer std.testing.allocator.free(favourites);
    try std.testing.expectEqualSlices(i32, &.{ 900000000, 900000001 }, favourites);
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
    try std.testing.expect(try store.addFriend(player_id, friend_id));
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
    const delivered = try clientMessagePacket(std.testing.allocator, .send_private_message, "sender", "delivered once", "target", 40);
    defer std.testing.allocator.free(delivered);
    const delivered_reply = try bancho.poll(std.testing.allocator, &store, &sessions, sender, delivered);
    defer std.testing.allocator.free(delivered_reply);
    const target_message = try bancho.poll(std.testing.allocator, &store, &sessions, target, "");
    defer std.testing.allocator.free(target_message);
    try expectMessageText(target_message, "delivered once");

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
    try std.testing.expect(target.user.silence_end > std.Io.Clock.real.now(std.testing.io).toSeconds());
    const target_notice = try bancho.poll(std.testing.allocator, &store, &sessions, target, "");
    defer std.testing.allocator.free(target_notice);
    try expectPacket(target_notice, .silence_end);
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
    try std.testing.expect(player.user.privileges & (1 << 4) != 0);
    const privilege_notice = try bancho.poll(std.testing.allocator, &store, &sessions, player, "");
    defer std.testing.allocator.free(privilege_notice);
    try expectPacket(privilege_notice, .privileges);

    const remove_priv = try clientMessagePacket(std.testing.allocator, .send_private_message, "admin", "!rmpriv player supporter", "kai", 20);
    defer std.testing.allocator.free(remove_priv);
    const remove_priv_reply = try bancho.poll(std.testing.allocator, &store, &sessions, admin, remove_priv);
    defer std.testing.allocator.free(remove_priv_reply);
    try expectMessageText(remove_priv_reply, "privileges updated");
    try std.testing.expect(player.user.privileges & (1 << 4) == 0);
    const remove_notice = try bancho.poll(std.testing.allocator, &store, &sessions, player, "");
    defer std.testing.allocator.free(remove_notice);
    try expectPacket(remove_notice, .privileges);

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

test "lazer trailing slashes use the same API route" {
    try std.testing.expectEqualStrings("/api/v2/me", routing.canonicalPath("/api/v2/me/"));
    try std.testing.expectEqualStrings("/", routing.canonicalPath("/"));
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
    const id = try store.insertLazerScore(1, try lazer.parseScore(parsed.value), raw);
    try std.testing.expect(id > 0);

    var stmt: ?*storage.c.sqlite3_stmt = null;
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_OK), storage.c.sqlite3_prepare_v2(store.db, "SELECT beatmap_id,ruleset_id,total_score,legacy_total_score,accuracy,max_combo,passed,rank_namespace,client_version FROM lazer_scores WHERE id=?1", -1, &stmt, null));
    defer _ = storage.c.sqlite3_finalize(stmt);
    _ = storage.c.sqlite3_bind_int64(stmt, 1, id);
    try std.testing.expectEqual(@as(c_int, storage.c.SQLITE_ROW), storage.c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(i64, 75), storage.c.sqlite3_column_int64(stmt, 0));
    try std.testing.expectEqual(@as(i64, 0), storage.c.sqlite3_column_int64(stmt, 1));
    try std.testing.expectEqual(@as(i64, 987654), storage.c.sqlite3_column_int64(stmt, 2));
    try std.testing.expectEqual(@as(i64, 900000), storage.c.sqlite3_column_int64(stmt, 3));
    try std.testing.expectApproxEqAbs(@as(f64, 0.985), storage.c.sqlite3_column_double(stmt, 4), 0.000001);
    try std.testing.expectEqual(@as(i64, 321), storage.c.sqlite3_column_int64(stmt, 5));
    try std.testing.expectEqual(@as(c_int, 1), storage.c.sqlite3_column_int(stmt, 6));
    try std.testing.expectEqualStrings("custom", std.mem.span(storage.c.sqlite3_column_text(stmt, 7)));
    try std.testing.expectEqualStrings("2026.811.0", std.mem.span(storage.c.sqlite3_column_text(stmt, 8)));
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
    try std.testing.expectApproxEqAbs(@as(f64, 26.90), result.pp, 0.05);
    try std.testing.expectApproxEqAbs(@as(f64, 1.8065), result.stars, 0.001);
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
    const expected_fc = [_]f64{ 26.895763, 13.168693, 2.549130, 0.740225 };
    const expected_miss = [_]f64{ 4.889811, 10.017056, 1.273185, 0.370112 };
    const expected_hr = [_]f64{ 58.466484, 19.190285, 5.138172, 0.740225 };
    const expected_hd = [_]f64{ 29.196351, 14.156509, 3.058956, 0.740225 };
    const expected_dt = [_]f64{ 56.075908, 19.565074, 3.316334, 0.616461 };
    const expected_stars = [_]f64{ 1.806515, 0.279849, 0.511245, 0.488839 };
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

test "beatmap metadata parser owns the import contract" {
    const map = @embedFile("testdata/synthetic-standard.osu");
    const metadata = try beatmap.parse(map);
    try std.testing.expectEqual(@as(i32, 900000001), metadata.id);
    try std.testing.expectEqual(@as(i32, 900000000), metadata.set_id);
    try std.testing.expectEqualStrings("Zigcho", metadata.artist);
    try std.testing.expectEqualStrings("Zigcho Fixture", metadata.title);
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
    const archive_bytes = "PK\x03\x04synthetic archive fixture";
    try store.upsertBeatmapArchive(metadata.set_id, "fixture-sha256", archive_bytes);
    const stored_archive = (try store.beatmapArchive(std.testing.allocator, metadata.set_id)).?;
    defer std.testing.allocator.free(stored_archive);
    try std.testing.expectEqualStrings(archive_bytes, stored_archive);
    const lazer_set = (try store.lazerBeatmapSet(std.testing.allocator, metadata.set_id)).?;
    defer std.testing.allocator.free(lazer_set);
    const parsed_set = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lazer_set, .{});
    defer parsed_set.deinit();
    try std.testing.expectEqual(@as(i64, 900000000), parsed_set.value.object.get("id").?.integer);
    try std.testing.expectEqualStrings("ranked", parsed_set.value.object.get("status").?.string);
    try std.testing.expect(!parsed_set.value.object.get("availability").?.object.get("download_disabled").?.bool);
    try std.testing.expectEqual(@as(usize, 1), parsed_set.value.object.get("beatmaps").?.array.items.len);
    const lazer_search = try store.lazerBeatmapSearch(std.testing.allocator, "Fixture", 0, 0);
    defer std.testing.allocator.free(lazer_search);
    const parsed_search = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lazer_search, .{});
    defer parsed_search.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed_search.value.object.get("total").?.integer);
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
    };
    const score_id = try store.insertStableScore(1, score, 26.80, "replay", 12_000);
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
