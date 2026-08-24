const std = @import("std");

pub const json = @embedFile("lazer_routes.json");
pub const route_count: usize = 86;

pub const Coverage = enum {
    implemented,
    implemented_static,
    proxied,
    placeholder,
    missing,
};

pub const Entry = struct {
    id: u8,
    request: []const u8,
    method: []const u8,
    target: []const u8,
    coverage: Coverage,
};

fn findRequest(entries: []const Entry, request: []const u8) ?Entry {
    for (entries) |entry| if (std.mem.eql(u8, entry.request, request)) return entry;
    return null;
}

test "pinned lazer route manifest covers all 86 exact request targets" {
    const parsed = try std.json.parseFromSlice([]const Entry, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(route_count, parsed.value.len);

    var placeholders: usize = 0;
    var implemented_static: usize = 0;
    var proxied: usize = 0;
    var missing: usize = 0;
    for (parsed.value, 0..) |entry, index| {
        try std.testing.expectEqual(@as(u8, @intCast(index + 1)), entry.id);
        try std.testing.expect(entry.request.len > 0);
        try std.testing.expect(entry.method.len > 0);
        try std.testing.expect(entry.target.len > 0);
        try std.testing.expect(std.mem.indexOfScalar(u8, entry.target, 0) == null);
        for (parsed.value[0..index]) |older| try std.testing.expect(!std.mem.eql(u8, older.request, entry.request));
        if (entry.coverage == .placeholder) placeholders += 1;
        if (entry.coverage == .implemented_static) implemented_static += 1;
        if (entry.coverage == .proxied) proxied += 1;
        if (entry.coverage == .missing) missing += 1;
    }

    try std.testing.expectEqual(@as(usize, 0), placeholders);
    try std.testing.expectEqual(@as(usize, 6), implemented_static);
    try std.testing.expectEqual(@as(usize, 2), proxied);
    try std.testing.expectEqual(@as(usize, 0), missing);
    try std.testing.expectEqualStrings("AddBeatmapTagRequest", parsed.value[0].request);
    try std.testing.expectEqualStrings("https://assets.ppy.sh/menu-content.json", findRequest(parsed.value, "GetMenuContentRequest").?.target);
    try std.testing.expectEqualStrings("api/v2/rankings/{ruleset}/{performance|score}", findRequest(parsed.value, "GetUserRankingsRequest").?.target);
    try std.testing.expectEqualStrings("api/v2/rankings/{ruleset}/country", findRequest(parsed.value, "GetCountryRankingsRequest").?.target);
    try std.testing.expect(findRequest(parsed.value, "GetSpotlightRankingsRequest").?.coverage == .implemented_static);
    try std.testing.expect(findRequest(parsed.value, "OAuthRevokeRequest").?.coverage == .implemented);
    try std.testing.expectEqualStrings("api/v2/chat/messages?since={message_id}", findRequest(parsed.value, "PollingChatClient.PollChatMessagesRequest").?.target);
    try std.testing.expectEqualStrings("PUT|DELETE", findRequest(parsed.value, "OnlineMetadataClient.UpdateActivityRequest").?.method);
    try std.testing.expect(findRequest(parsed.value, "BundledBeatmapDownloadRequest").?.coverage == .proxied);
    try std.testing.expectEqualStrings("https://assets.ppy.sh/client-resources/bundled/{set_id}.osz", findRequest(parsed.value, "BundledBeatmapDownloadRequest").?.target);
}
