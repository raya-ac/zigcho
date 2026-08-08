const std = @import("std");
const protocol = @import("protocol.zig");
const domain = @import("domain.zig");
const lazer = @import("lazer.zig");
const rijndael = @import("rijndael.zig");
const multipart = @import("multipart.zig");
const score_crypto = @import("score_crypto.zig");
const stable_score = @import("stable_score.zig");
const rate_limit = @import("rate_limit.zig");

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
