const std = @import("std");

const Article = struct {
    path: []const u8,
    title: []const u8,
    subtitle: []const u8,
    tags: []const []const u8,
    markdown: []const u8,
};

const articles = [_]Article{
    .{
        .path = "Main_page",
        .title = "zigcho wiki",
        .subtitle = "the bits of the server players actually need",
        .tags = &.{ "zigcho", "stable", "lazer" },
        .markdown =
        \\# zigcho
        \\
        \\zigcho is the server behind kai. Stable and zigcho!lazer use the same accounts, chat, maps and player stats while keeping client-specific plays visible.
        \\
        \\## start here
        \\
        \\- [using zigcho!lazer](Help_centre/Upgrading_to_lazer)
        \\- [multiplayer](Multiplayer)
        \\- [profiles and score views](Profiles)
        \\- [performance points](Performance_Points)
        \\- [beatmap submission](Beatmap_submission)
        \\- [ranking criteria](Ranking_Criteria)
        ,
    },
    .{
        .path = "Help_centre/Upgrading_to_lazer",
        .title = "using zigcho!lazer",
        .subtitle = "the pinned client and your existing account",
        .tags = &.{ "lazer", "account" },
        .markdown =
        \\# using zigcho!lazer
        \\
        \\Use the zigcho!lazer build published by kai. It is pinned to the server contract; a normal osu!lazer build still points at Bancho and will not use your kai account.
        \\
        \\Sign in with the same username and password you use on Stable. Only one game client can own an account session at a time, so signing in from another client closes the older game session.
        \\
        \\If the client falls back to offline mode, keep the network and runtime logs from that exact build. They show which request failed before the login panel gave up.
        ,
    },
    .{
        .path = "Multiplayer",
        .title = "multiplayer",
        .subtitle = "rooms, playlists and ranked play",
        .tags = &.{ "lazer", "multiplayer" },
        .markdown =
        \\# multiplayer
        \\
        \\Normal rooms support head-to-head and team-versus play, room playlists, invites, host changes, mods, ready state, round scores and a room leaderboard.
        \\
        \\Playlist rooms keep their selected duration and attempt limit. Finished rooms leave the live list but retain their final room page and scores.
        \\
        \\Quick Play and ranked play use the same multiplayer service with their own queue and round state. Leaving a queue or room should remove the player from that live state.
        ,
    },
    .{
        .path = "Profiles",
        .title = "profiles and score views",
        .subtitle = "combined stats without hiding either client",
        .tags = &.{ "profiles", "scores" },
        .markdown =
        \\# profiles and score views
        \\
        \\A profile can show combined stats or the Stable and lazer sources separately. Combined performance keeps one best play per map, chosen by pp, while each client tab keeps its own play history.
        \\
        \\Recent, top, pinned and first-place plays keep their score source, ruleset, mods and replay availability. Country, team, roles, medals, banner and live activity come from the same account.
        ,
    },
    .{
        .path = "Performance_Points",
        .title = "performance points",
        .subtitle = "how zigcho separates calculators and score namespaces",
        .tags = &.{ "scores", "pp" },
        .markdown =
        \\# performance points
        \\
        \\Stable vanilla and lazer vanilla use their own pinned calculators. Relax and Autopilot keep their Stable calculator and separate leaderboard namespaces.
        \\
        \\Custom Double Time and Nightcore rates are part of the calculation. Combined profile performance compares the resulting pp for the same map instead of letting a lower-pp play replace a better one.
        ,
    },
    .{
        .path = "Beatmap_submission",
        .title = "beatmap submission",
        .subtitle = "lazer BSS and the local ranking queue",
        .tags = &.{ "beatmaps", "bss" },
        .markdown =
        \\# beatmap submission
        \\
        \\Premium accounts can reserve a local set and map IDs from the lazer editor, then upload a complete package or a later patch. The submitted package stays owned by the local mapper.
        \\
        \\WIP and Pending sets appear on the mapper's profile and enter the local BN workflow. Pending maps do not expose a leaderboard until they move to a leaderboard-eligible status.
        ,
    },
    .{
        .path = "Ranking_Criteria",
        .title = "ranking criteria",
        .subtitle = "which maps can expose a leaderboard",
        .tags = &.{ "beatmaps", "ranking" },
        .markdown =
        \\# ranking criteria
        \\
        \\A set must be complete, playable and owned by its submitting mapper before staff can move it through the queue. Qualification, Ranked, Approved and Loved maps can expose their intended leaderboard; WIP, Pending and vetoed maps cannot.
        \\
        \\The BN decision and its reason are kept in ranking history. A status change never invents upstream ownership or silently publishes scores from an ineligible map.
        ,
    },
    .{
        .path = "Beatmap_ranking_procedure",
        .title = "beatmap ranking procedure",
        .subtitle = "from BSS upload to a public board",
        .tags = &.{ "beatmaps", "ranking", "bss" },
        .markdown =
        \\# beatmap ranking procedure
        \\
        \\Submit the set through lazer BSS, check that every difficulty and media asset appears on the set page, then request nomination. BNs can leave the set Pending, nominate it, qualify it, rank it, approve it or love it.
        \\
        \\If a set is vetoed, its scores are hidden until staff resolves the veto and applies a leaderboard-eligible status.
        ,
    },
    .{
        .path = "Rules/Content_usage_permissions",
        .title = "content usage permissions",
        .subtitle = "only upload work you are allowed to publish",
        .tags = &.{ "rules", "beatmaps", "bss" },
        .markdown =
        \\# content usage permissions
        \\
        \\Only upload audio, images and beatmap content you are allowed to publish. A successful BSS upload proves that the package is technically valid; it does not grant rights to somebody else's work.
        \\
        \\Staff can remove or veto a set when ownership or permission is disputed. Keep the source and permission record for anything that is not your own work.
        ,
    },
};

pub fn pageJson(allocator: std.mem.Allocator, locale: []const u8, path: []const u8) !?[]u8 {
    if (!std.ascii.eqlIgnoreCase(locale, "en") or path.len == 0 or path.len > 256 or std.mem.indexOfAny(u8, path, "\\\x00") != null) return null;
    const article = for (articles) |candidate| {
        if (std.mem.eql(u8, candidate.path, path)) break candidate;
    } else return null;

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"layout\":");
    try std.json.Stringify.value(if (std.mem.eql(u8, article.path, "Main_page")) "Main_page" else "wiki", .{}, &output.writer);
    try output.writer.writeAll(",\"locale\":\"en\",\"markdown\":");
    try std.json.Stringify.value(article.markdown, .{}, &output.writer);
    try output.writer.writeAll(",\"path\":");
    try std.json.Stringify.value(article.path, .{}, &output.writer);
    try output.writer.writeAll(",\"subtitle\":");
    try std.json.Stringify.value(article.subtitle, .{}, &output.writer);
    try output.writer.writeAll(",\"tags\":[");
    for (article.tags, 0..) |tag, index| {
        if (index != 0) try output.writer.writeByte(',');
        try std.json.Stringify.value(tag, .{}, &output.writer);
    }
    try output.writer.writeAll("],\"title\":");
    try std.json.Stringify.value(article.title, .{}, &output.writer);
    try output.writer.writeByte('}');
    return @as(?[]u8, try output.toOwnedSlice());
}

test "local lazer wiki returns exact pages and honest misses" {
    const page = (try pageJson(std.testing.allocator, "en", "Main_page")).?;
    defer std.testing.allocator.free(page);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, page, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Main_page", parsed.value.object.get("layout").?.string);
    try std.testing.expectEqualStrings("Main_page", parsed.value.object.get("path").?.string);
    try std.testing.expect(parsed.value.object.get("markdown").?.string.len > 100);
    try std.testing.expect((try pageJson(std.testing.allocator, "en", "Something_that_does_not_exist")) == null);
    try std.testing.expect((try pageJson(std.testing.allocator, "ja", "Main_page")) == null);
}
