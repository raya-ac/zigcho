const std = @import("std");
const storage = @import("runtime_storage.zig");
const sessions_mod = @import("sessions.zig");
const bancho = @import("bancho.zig");
const http_boundary = @import("http_boundary.zig");
const App = @import("server/app.zig").App;
const support = @import("server/support.zig");
const startup = @import("server/startup.zig");

const HttpGate = http_boundary.Gate;
const httpRequestDeadlineSeconds = http_boundary.requestDeadlineSeconds;
const healthResponse = support.healthResponse;
const freeUser = support.freeUser;
const rollbackFailedLazerLogin = support.rollbackFailedLazerLogin;

pub fn main(init: std.process.Init) !void {
    return startup.run(init);
}

test "public beatmapset pages bypass BSS upload routing" {
    try std.testing.expect(App.bssPathForRequest(.GET, "kai.ovh", "/beatmapsets/1000000001") == null);
    try std.testing.expect(App.bssPathForRequest(.PUT, "bss.kai.ovh", "/beatmapsets/1000000001") != null);
    try std.testing.expect(App.bssPathForRequest(.PATCH, "bss.kai.ovh", "/beatmapsets/1000000001") != null);
}

test "health advertises the verified hotfix lane" {
    var buf: [256]u8 = undefined;
    const json = try healthResponse(&buf, 7);
    try std.testing.expectEqualStrings("{\"ok\":true,\"service\":\"zigcho\",\"online\":7,\"protocol\":19,\"hotfixes\":true}", json);
}

test "http gate bounds tasks and deadlines preserve realtime" {
    var gate = HttpGate.init(2);
    try std.testing.expect(gate.tryAcquire());
    try std.testing.expect(gate.tryAcquire());
    try std.testing.expect(!gate.tryAcquire());
    try std.testing.expectEqual(@as(u32, 2), gate.active.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), gate.rejected.load(.acquire));
    gate.release();
    gate.release();
    try std.testing.expectEqual(@as(u32, 0), gate.active.load(.acquire));

    try std.testing.expectEqual(@as(?u16, null), httpRequestDeadlineSeconds(.GET, "/multiplayer?access_token=redacted", 30, 300));
    try std.testing.expectEqual(@as(?u16, 30), httpRequestDeadlineSeconds(.GET, "/api/v1/status", 30, 300));
    try std.testing.expectEqual(@as(?u16, 300), httpRequestDeadlineSeconds(.GET, "/d/1", 30, 300));
    try std.testing.expectEqual(@as(?u16, 300), httpRequestDeadlineSeconds(.POST, "/api/v2/rooms/1/playlist/2/scores", 30, 300));
}

test "failed lazer password response revokes tokens and always clears presence" {
    if (storage.is_postgres) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/lazer-login-response-rollback.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();
    const user_id = try store.register("ari", "ari@example.invalid", "00000000000000000000000000000000");
    const user = (try store.userById(std.testing.allocator, user_id)).?;
    defer freeUser(std.testing.allocator, user);
    var sessions = sessions_mod.Sessions.init(std.testing.allocator, std.testing.io);
    defer sessions.deinit();

    const tokens = try store.issueGameTokenPair(user_id, 60, 60, false);
    try bancho.publishLazerPresence(std.testing.allocator, &store, &sessions, user);
    try std.testing.expect(sessions.lazer_leases.contains(user_id));
    rollbackFailedLazerLogin(std.testing.allocator, &store, &sessions, user_id, tokens);
    try std.testing.expect(!sessions.lazer_leases.contains(user_id));
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &tokens.access, "identify")) == null);

    const store_failure_tokens = try store.issueGameTokenPair(user_id, 60, 60, false);
    try bancho.publishLazerPresence(std.testing.allocator, &store, &sessions, user);
    try std.testing.expect(sessions.lazer_leases.contains(user_id));
    var oauth_table_renamed = false;
    defer if (oauth_table_renamed) store.exec("ALTER TABLE oauth_tokens_unavailable RENAME TO oauth_tokens") catch {};
    try store.exec("ALTER TABLE oauth_tokens RENAME TO oauth_tokens_unavailable");
    oauth_table_renamed = true;
    rollbackFailedLazerLogin(std.testing.allocator, &store, &sessions, user_id, store_failure_tokens);
    try std.testing.expect(!sessions.lazer_leases.contains(user_id));
    try store.exec("ALTER TABLE oauth_tokens_unavailable RENAME TO oauth_tokens");
    oauth_table_renamed = false;
    try std.testing.expect(try store.revokeToken(&store_failure_tokens.access));
}
