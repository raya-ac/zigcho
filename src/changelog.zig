const std = @import("std");

pub const latest_version = "2026.822.0";

const Entry = struct {
    kind: []const u8,
    category: []const u8,
    title: []const u8,
    message: []const u8,
    major: bool = false,
};

const Build = struct {
    id: i64,
    version: []const u8,
    created_at: []const u8,
    entries: []const Entry,
};

const builds = [_]Build{
    .{ .id = 33, .version = latest_version, .created_at = "2026-08-22T13:30:00Z", .entries = &.{
        .{ .kind = "add", .category = "accounts", .title = "the website account is actually yours now", .message = "change your email or password, use the free username change, upload a profile banner, and manage the same team shown in lazer.", .major = true },
        .{ .kind = "add", .category = "scores", .title = "replays live in the object store", .message = "new and existing Stable and lazer replays are mirrored by content hash. failed replay data stays private and cannot be downloaded." },
        .{ .kind = "add", .category = "profiles", .title = "first places have somewhere to live", .message = "player pages now show the total number of #1 scores and the actual plays behind it." },
        .{ .kind = "fix", .category = "staff", .title = "player search searches players", .message = "the dashboard accepts partial names, safe names, spaces, and ids instead of only pretending an exact lookup is search." },
        .{ .kind = "add", .category = "lazer", .title = "you are reading the Zigcho changelog", .message = "the in-game changelog now comes from Zigcho releases instead of an empty upstream page." },
    } },
    .{ .id = 32, .version = "2026.821.0", .created_at = "2026-08-21T22:00:00Z", .entries = &.{
        .{ .kind = "add", .category = "profiles", .title = "profiles stopped being placeholders", .message = "recent activity, comments, medals, ranks, and proper profile data now reach the website and lazer." },
        .{ .kind = "fix", .category = "beatmaps", .title = "the mirror starts sending before it finishes thinking", .message = "cached mapsets stream straight from object storage and missing sets fill through the background mirror worker." },
    } },
    .{ .id = 31, .version = "2026.820.0", .created_at = "2026-08-20T22:00:00Z", .entries = &.{
        .{ .kind = "fix", .category = "scores", .title = "Stable and lazer agree on the useful score", .message = "combined boards keep one play per player by higher pp while preserving the ordering the lazer client expects." },
        .{ .kind = "fix", .category = "performance", .title = "each ruleset keeps its own pp maths", .message = "lazer uses the pinned lazer calculator, Stable stays on its Stable calculator, and Relax or Autopilot are left alone." },
    } },
};

fn writeStream(writer: *std.Io.Writer, latest: bool) anyerror!void {
    try writer.writeAll("{\"id\":5,\"name\":\"lazer\",\"is_featured\":true,\"display_name\":\"zigcho!lazer\",\"user_count\":0,\"latest_build\":");
    if (latest) try writeBuild(writer, builds[0], false) else try writer.writeAll("null");
    try writer.writeByte('}');
}

fn writeEntry(writer: *std.Io.Writer, build: Build, entry: Entry, index: usize) anyerror!void {
    try writer.print("{{\"id\":{d},\"repository\":\"raya-ac/zigcho\",\"github_pull_request_id\":null,\"github_url\":null,\"url\":\"https://kai.ovh/changelog\",\"type\":", .{build.id * 100 + @as(i64, @intCast(index))});
    try std.json.Stringify.value(entry.kind, .{}, writer);
    try writer.writeAll(",\"category\":");
    try std.json.Stringify.value(entry.category, .{}, writer);
    try writer.writeAll(",\"title\":");
    try std.json.Stringify.value(entry.title, .{}, writer);
    try writer.writeAll(",\"message\":");
    try std.json.Stringify.value(entry.message, .{}, writer);
    try writer.writeAll(",\"message_html\":");
    try std.json.Stringify.value(entry.message, .{}, writer);
    try writer.print(",\"major\":{},\"created_at\":", .{entry.major});
    try std.json.Stringify.value(build.created_at, .{}, writer);
    try writer.writeAll(",\"github_user\":null}");
}

fn writeBuild(writer: *std.Io.Writer, build: Build, detailed: bool) anyerror!void {
    try writer.print("{{\"id\":{d},\"version\":", .{build.id});
    try std.json.Stringify.value(build.version, .{}, writer);
    try writer.print(",\"display_version\":\"zigcho!lazer {s}\",\"users\":0,\"created_at\":", .{build.version});
    try std.json.Stringify.value(build.created_at, .{}, writer);
    try writer.writeAll(",\"update_stream\":");
    try writeStream(writer, false);
    try writer.writeAll(",\"changelog_entries\":[");
    if (detailed) for (build.entries, 0..) |entry, index| {
        if (index != 0) try writer.writeByte(',');
        try writeEntry(writer, build, entry, index);
    };
    try writer.writeAll("],\"versions\":{\"next\":null,\"previous\":null}}");
}

pub fn indexJson(allocator: std.mem.Allocator) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"streams\":[");
    try writeStream(&output.writer, true);
    try output.writer.writeAll("],\"builds\":[");
    for (builds, 0..) |build, index| {
        if (index != 0) try output.writer.writeByte(',');
        try writeBuild(&output.writer, build, true);
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

pub fn buildJson(allocator: std.mem.Allocator, stream: []const u8, version: []const u8) !?[]u8 {
    if (!std.mem.eql(u8, stream, "lazer") and !std.mem.eql(u8, stream, "zigcho")) return null;
    for (builds) |build| if (std.mem.eql(u8, build.version, version) or (std.mem.eql(u8, build.version, latest_version) and std.mem.eql(u8, version, "latest"))) {
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try writeBuild(&output.writer, build, true);
        return @as(?[]u8, try output.toOwnedSlice());
    };
    return null;
}

test "changelog matches the lazer response contract" {
    const json = try indexJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("zigcho!lazer", object.get("streams").?.array.items[0].object.get("display_name").?.string);
    try std.testing.expectEqualStrings(latest_version, object.get("builds").?.array.items[0].object.get("version").?.string);
    try std.testing.expect(object.get("builds").?.array.items[0].object.get("changelog_entries").?.array.items.len >= 5);
    const detail = (try buildJson(std.testing.allocator, "lazer", latest_version)).?;
    defer std.testing.allocator.free(detail);
    try std.testing.expect((try buildJson(std.testing.allocator, "stable", latest_version)) == null);
}
