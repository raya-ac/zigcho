const std = @import("std");
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

test "stable md5 and raw lazer passwords normalize to the same secret" {
    const raw = try form_urlencoded.credentialMd5("password");
    const stable = try form_urlencoded.credentialMd5("5F4DCC3B5AA765D61D8327DEB882CF99");
    try std.testing.expectEqualStrings("5f4dcc3b5aa765d61d8327deb882cf99", &raw);
    try std.testing.expectEqual(raw, stable);
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

test "lazer custom mod acronyms are bounded" {
    try std.testing.expect(lazer.validAcronym("RX"));
    try std.testing.expect(lazer.validAcronym("WIGGLE"));
    try std.testing.expect(!lazer.validAcronym("bad"));
    try std.testing.expect(!lazer.validAcronym("TOO-LONG-MOD"));
}

test "lazer relax scores cannot enter vanilla namespace" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"beatmap_id\":1,\"total_score\":10,\"mods\":[{\"acronym\":\"RX\",\"settings\":{}}]}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(lazer.Namespace.relax, try lazer.validateScore(parsed.value));
}

test "unknown lazer mods enter custom namespace" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"beatmap_id\":1,\"total_score\":10,\"mods\":[{\"acronym\":\"WIGGLE\",\"settings\":{\"strength\":1.2}}]}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(lazer.Namespace.custom, try lazer.validateScore(parsed.value));
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

test "stable relax and autopilot scores cannot enter vanilla rankings" {
    const base = "0123456789abcdef0123456789abcdef:Ari:bd08534d40f7bbab046520c9b4931cdc:300:4:1:2:3:5:987654:321:False:A:";
    const suffix = ":True:0:260808235959:20260808";
    const nomod = try stable_score.parse(base ++ "0" ++ suffix);
    const relax = try stable_score.parse(base ++ "128" ++ suffix);
    const autopilot = try stable_score.parse(base ++ "8192" ++ suffix);
    try std.testing.expectEqualStrings("vanilla", nomod.rankNamespace());
    try std.testing.expectEqualStrings("relax", relax.rankNamespace());
    try std.testing.expectEqualStrings("relax", autopilot.rankNamespace());
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
    try std.testing.expectApproxEqAbs(@as(f64, 26.80), result.pp, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 1.7931), result.stars, 0.0001);
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
    try store.exec("INSERT INTO users(id,name,safe_name,password_hash,password_salt) VALUES(1,'ari','ari',x'00',x'00'); INSERT INTO stats(user_id,mode) VALUES(1,0)");
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
    try std.testing.expect(std.mem.startsWith(u8, search, "1\n900000000.osz|Zigcho|Zigcho Fixture|Ari|2|10.0|"));
    try std.testing.expect(std.mem.indexOf(u8, search, "[1.79⭐] Tests {cs: 4") != null);
    const set_lookup = try store.stableSearchSet(std.testing.allocator, null, null, &hash);
    defer std.testing.allocator.free(set_lookup);
    try std.testing.expect(std.mem.startsWith(u8, set_lookup, "900000000.osz|Zigcho|Zigcho Fixture|Ari|2|10.0|"));
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
    const score_id = try store.insertStableScore(1, score, 26.80, "replay");
    const snapshot = (try store.ppSnapshot(score_id)).?;
    try std.testing.expectApproxEqAbs(@as(f64, 26.80), snapshot.score, 0.001);
    try std.testing.expectEqual(@as(i64, 27), snapshot.player);
}
