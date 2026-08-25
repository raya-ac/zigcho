const std = @import("std");
const bss = @import("bss.zig");
const lazer = @import("lazer.zig");
const lazer_multiplayer = @import("lazer_multiplayer.zig");
const server_control = @import("server_control.zig");

pub const Requirements = struct {
    values: [server_control.definitions.len]server_control.Feature = undefined,
    len: usize = 0,

    fn add(self: *Requirements, feature: server_control.Feature) void {
        for (self.values[0..self.len]) |current| if (current == feature) return;
        std.debug.assert(self.len < self.values.len);
        self.values[self.len] = feature;
        self.len += 1;
    }

    pub fn slice(self: *const Requirements) []const server_control.Feature {
        return self.values[0..self.len];
    }
};

pub fn required(method: std.http.Method, path: []const u8, has_stable_token: bool) Requirements {
    var result: Requirements = .{};
    if (method == .POST and std.mem.eql(u8, path, "/users")) result.add(.registrations);
    if (method == .POST and std.mem.eql(u8, path, "/") and !has_stable_token) result.add(.stable_login);
    if (method == .POST and std.mem.eql(u8, path, "/oauth/token")) result.add(.lazer_login);
    if (method == .POST and std.mem.eql(u8, path, "/web/osu-submit-modular-selector.php")) result.add(.stable_scores);

    const room_score = lazer_multiplayer.parseRoomScorePath(path) != null;
    if ((method == .POST or method == .PUT) and
        (std.mem.eql(u8, path, "/api/v2/scores") or lazer.parseSoloScorePath(path) != null or room_score))
    {
        result.add(.lazer_scores);
    }
    // Room scores mutate both the scoring store and an active multiplayer
    // room. Keeping both requirements in one policy prevents route ordering
    // from silently bypassing either operational control.
    if ((method == .POST or method == .PUT) and room_score) result.add(.lazer_multiplayer);

    if ((method == .PUT or method == .PATCH) and bss.parsePath(path) != null) result.add(.bss);
    if (method == .GET and (std.mem.startsWith(u8, path, "/d/") or
        (std.mem.startsWith(u8, path, "/api/v2/beatmapsets/") and std.mem.endsWith(u8, path, "/download"))))
    {
        result.add(.beatmap_downloads);
    }
    if (std.mem.eql(u8, path, "/multiplayer") or
        std.mem.eql(u8, path, "/multiplayer/negotiate") or
        std.mem.startsWith(u8, path, "/api/v2/rooms"))
    {
        result.add(.lazer_multiplayer);
    }
    if (std.mem.eql(u8, path, "/spectator") or std.mem.eql(u8, path, "/spectator/negotiate")) result.add(.spectator);
    if (method != .GET and method != .HEAD and
        (std.mem.eql(u8, path, "/api/v1/account") or
            std.mem.startsWith(u8, path, "/api/v1/account/") or
            std.mem.eql(u8, path, "/api/v1/teams") or
            std.mem.startsWith(u8, path, "/api/v1/teams/") or
            std.mem.startsWith(u8, path, "/api/v1/chat/") or
            std.mem.eql(u8, path, "/api/v1/appeals")))
    {
        result.add(.website_writes);
    }
    return result;
}

test "room score writes require both scoring and multiplayer controls" {
    const create = required(.POST, "/api/v2/rooms/5/playlist/8/scores", false);
    try std.testing.expectEqualSlices(server_control.Feature, &.{ .lazer_scores, .lazer_multiplayer }, create.slice());
    const submit = required(.PUT, "/api/v2/rooms/5/playlist/8/scores/13", false);
    try std.testing.expectEqualSlices(server_control.Feature, &.{ .lazer_scores, .lazer_multiplayer }, submit.slice());

    const read = required(.GET, "/api/v2/rooms/5/playlist/8/scores", false);
    try std.testing.expectEqualSlices(server_control.Feature, &.{.lazer_multiplayer}, read.slice());
    const solo = required(.PUT, "/api/v2/beatmaps/75/solo/scores/13", false);
    try std.testing.expectEqualSlices(server_control.Feature, &.{.lazer_scores}, solo.slice());
}
