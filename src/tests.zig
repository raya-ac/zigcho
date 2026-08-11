const std = @import("std");
const bancho = @import("bancho.zig");
const protocol = @import("protocol.zig");
const domain = @import("domain.zig");
const lazer = @import("lazer.zig");
const rijndael = @import("rijndael.zig");
const multipart = @import("multipart.zig");
const score_crypto = @import("score_crypto.zig");
const stable_score = @import("stable_score.zig");
const rate_limit = @import("rate_limit.zig");
const pp = @import("pp.zig");
const beatmap = @import("beatmap.zig");
const storage = @import("storage.zig");
const form_urlencoded = @import("form_urlencoded.zig");
const routing = @import("routing.zig");
const beatmap_sync = @import("beatmap_sync.zig");
const sessions_mod = @import("sessions.zig");
const country = @import("country.zig");
const config_mod = @import("config.zig");
const multiplayer = @import("multiplayer.zig");
const registration = @import("registration.zig");

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
            "osu_api_key=final-key\n",
    );
    var config = try config_mod.parse(std.testing.allocator, source);
    defer config.deinit();

    @memset(source, 'x');
    std.testing.allocator.free(source);

    try std.testing.expectEqualStrings("final-key", config.osu_api_key);
    try std.testing.expectEqualStrings("https://discord.invalid/first", config.score_webhook);
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
    var result = try bancho.login(std.testing.allocator, &store, &sessions, "ari\n00000000000000000000000000000000\n20260811|0", .{ 'A', 'U' }, 138.6, -34.9);
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
    var context: LoginAllocationContext = .{ .store = &store, .body = "ari\n00000000000000000000000000000000\n20260811|0" };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, loginAllocationRun, .{&context});
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

    try store.upsertBeatmap(metadata, &hash, 3, 1.0, 1, map);
    try std.testing.expect(try store.beatmapHasFile(&hash));
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

test "joined public chat delivers once and kai answers private chat as user three" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/chat.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
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
    try std.testing.expectEqualStrings("commands: !np (pp for current map) | !with mods acc% misses (custom pp)", try bot_payload.string());
    try std.testing.expectEqualStrings("ari", try bot_payload.string());
    try std.testing.expectEqual(@as(i32, 3), try bot_payload.int(i32));
    try std.testing.expectEqual(@as(usize, 0), sessions.byUser(3).?.queue.items.len);
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
