const std = @import("std");
const startup_catalog = @import("changelog_catalog");

pub const latest_version = startup_catalog.builds[0].version;
pub const max_updates: usize = 256;
pub const max_build_id: i64 = @divFloor(std.math.maxInt(i64) - @as(i64, max_updates - 1), 100);
pub const Update = startup_catalog.Update;
pub const Build = startup_catalog.Build;
pub const fallback_builds = startup_catalog.builds;

pub fn historyEntryCount() usize {
    var count: usize = 0;
    for (fallback_builds) |build| count += build.updates.len;
    return count;
}

pub fn historyManifest() u64 {
    var manifest: u64 = 0;
    for (fallback_builds) |build| for (build.updates) |update| {
        manifest ^= std.hash.Wyhash.hash(0, update.name);
    };
    return manifest;
}

fn contains(value: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, value, needle) != null;
}

fn title(markdown: []const u8) []const u8 {
    const line_end = std.mem.indexOfScalar(u8, markdown, '\n') orelse markdown.len;
    return std.mem.trim(u8, markdown[0..line_end], "#* \t\r");
}

fn message(markdown: []const u8) []const u8 {
    const line_end = std.mem.indexOfScalar(u8, markdown, '\n') orelse return "";
    return std.mem.trim(u8, markdown[line_end + 1 ..], " \t\r\n");
}

fn preview(markdown: []const u8) []const u8 {
    const body = message(markdown);
    const paragraph_end = std.mem.indexOf(u8, body, "\n\n") orelse body.len;
    return std.mem.trim(u8, body[0..paragraph_end], " \t\r\n");
}

fn slug(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, ".md")) name[0 .. name.len - 3] else name;
}

fn updateYear(update: Update) u16 {
    if (update.created_at.len < 4) return 0;
    return std.fmt.parseInt(u16, update.created_at[0..4], 10) catch 0;
}

fn buildYear(build: Build) u16 {
    if (build.created_at.len < 4) return 0;
    return std.fmt.parseInt(u16, build.created_at[0..4], 10) catch 0;
}

fn category(name: []const u8) []const u8 {
    if (contains(name, "lazer")) return "lazer";
    if (contains(name, "stable")) return "stable";
    if (contains(name, "beatmap") or contains(name, "map-") or contains(name, "mirror")) return "beatmaps";
    if (contains(name, "score") or contains(name, "pp") or contains(name, "replay")) return "scores";
    if (contains(name, "chat") or contains(name, "bot")) return "chat";
    if (contains(name, "account") or contains(name, "avatar") or contains(name, "profile") or contains(name, "player-page")) return "profiles";
    if (contains(name, "auth") or contains(name, "session") or contains(name, "postgres")) return "server";
    return "zigcho";
}

fn kind(name: []const u8) []const u8 {
    if (contains(name, "fix") or contains(name, "rejection") or contains(name, "empty") or contains(name, "cleanup") or contains(name, "bounded") or contains(name, "remove")) return "fix";
    return "add";
}

fn major(name: []const u8) bool {
    return contains(name, "is-live") or contains(name, "is-finished") or contains(name, "cutover") or contains(name, "windows-alpha") or contains(name, "postgres-runtime");
}

fn entryId(build_id: i64, index: usize) !i64 {
    if (build_id <= 0 or build_id > max_build_id or index >= max_updates) return error.InvalidChangelogEntryId;
    const scaled = std.math.mul(i64, build_id, 100) catch return error.InvalidChangelogEntryId;
    return std.math.add(i64, scaled, @intCast(index)) catch return error.InvalidChangelogEntryId;
}

fn writeStream(writer: *std.Io.Writer, catalog: []const Build, include_latest: bool) anyerror!void {
    try writer.writeAll("{\"id\":5,\"name\":\"lazer\",\"is_featured\":true,\"display_name\":\"zigcho!lazer\",\"user_count\":0,\"latest_build\":");
    if (include_latest) try writeBuild(writer, catalog, 0, false, false) else try writer.writeAll("null");
    try writer.writeByte('}');
}

fn writeEntry(writer: *std.Io.Writer, build: Build, update: Update, index: usize) anyerror!void {
    var commit_url_buf: [128]u8 = undefined;
    const commit_url = if (update.commit.len == 0) "https://github.com/zigcho/zigcho" else try std.fmt.bufPrint(&commit_url_buf, "https://github.com/zigcho/zigcho/commit/{s}", .{update.commit});
    try writer.print("{{\"id\":{d},\"repository\":\"zigcho/zigcho\",\"github_pull_request_id\":null,\"github_url\":null,\"url\":", .{try entryId(build.id, index)});
    try std.json.Stringify.value(commit_url, .{}, writer);
    try writer.writeAll(",\"type\":");
    try std.json.Stringify.value(kind(update.name), .{}, writer);
    try writer.writeAll(",\"category\":");
    try std.json.Stringify.value(category(update.name), .{}, writer);
    try writer.writeAll(",\"title\":");
    try std.json.Stringify.value(title(update.markdown), .{}, writer);
    try writer.writeAll(",\"message\":");
    try std.json.Stringify.value(message(update.markdown), .{}, writer);
    try writer.writeAll(",\"message_html\":");
    try std.json.Stringify.value(message(update.markdown), .{}, writer);
    try writer.print(",\"major\":{},\"created_at\":", .{major(update.name)});
    try std.json.Stringify.value(update.created_at, .{}, writer);
    try writer.writeAll(",\"github_user\":null}");
}

fn writeBuild(writer: *std.Io.Writer, catalog: []const Build, index: usize, detailed: bool, navigation: bool) anyerror!void {
    const build = catalog[index];
    try writer.print("{{\"id\":{d},\"version\":", .{build.id});
    try std.json.Stringify.value(build.version, .{}, writer);
    try writer.writeAll(",\"display_version\":");
    if (build.display_version) |display_version|
        try std.json.Stringify.value(display_version, .{}, writer)
    else
        try writer.print("\"zigcho!lazer {s}\"", .{build.version});
    try writer.writeAll(",\"users\":0,\"created_at\":");
    try std.json.Stringify.value(build.created_at, .{}, writer);
    try writer.writeAll(",\"update_stream\":");
    try writeStream(writer, catalog, false);
    try writer.writeAll(",\"changelog_entries\":[");
    if (detailed) for (build.updates, 0..) |update, update_index| {
        if (update_index != 0) try writer.writeByte(',');
        try writeEntry(writer, build, update, update_index);
    };
    try writer.writeAll("],\"versions\":");
    if (!navigation) {
        try writer.writeAll("null}");
        return;
    }
    try writer.writeAll("{\"next\":");
    if (index > 0) try writeBuild(writer, catalog, index - 1, false, false) else try writer.writeAll("null");
    try writer.writeAll(",\"previous\":");
    if (index + 1 < catalog.len) try writeBuild(writer, catalog, index + 1, false, false) else try writer.writeAll("null");
    try writer.writeAll("}}");
}

pub fn indexJsonFor(allocator: std.mem.Allocator, catalog: []const Build) ![]u8 {
    if (catalog.len == 0) return error.EmptyChangelog;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"streams\":[");
    try writeStream(&output.writer, catalog, true);
    try output.writer.writeAll("],\"builds\":[");
    for (catalog, 0..) |_, index| {
        if (index != 0) try output.writer.writeByte(',');
        try writeBuild(&output.writer, catalog, index, true, false);
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

pub fn indexJson(allocator: std.mem.Allocator) ![]u8 {
    return indexJsonFor(allocator, &fallback_builds);
}

pub fn buildJsonFor(allocator: std.mem.Allocator, catalog: []const Build, stream: []const u8, version: []const u8) !?[]u8 {
    if (!std.mem.eql(u8, stream, "lazer") and !std.mem.eql(u8, stream, "zigcho")) return null;
    for (catalog, 0..) |build, index| if (std.mem.eql(u8, build.version, version) or (index == 0 and std.mem.eql(u8, version, "latest"))) {
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try writeBuild(&output.writer, catalog, index, true, true);
        return @as(?[]u8, try output.toOwnedSlice());
    };
    return null;
}

pub fn buildJson(allocator: std.mem.Allocator, stream: []const u8, version: []const u8) !?[]u8 {
    return buildJsonFor(allocator, &fallback_builds, stream, version);
}

fn writeNewsPost(writer: *std.Io.Writer, build: Build, update: Update, index: usize) !void {
    var edit_url_buf: [128]u8 = undefined;
    const edit_url = if (update.commit.len == 0) "https://github.com/zigcho/zigcho" else try std.fmt.bufPrint(&edit_url_buf, "https://github.com/zigcho/zigcho/commit/{s}", .{update.commit});
    try writer.print("{{\"id\":{d},\"author\":\"ari\",\"edit_url\":", .{try entryId(build.id, index)});
    try std.json.Stringify.value(edit_url, .{}, writer);
    try writer.writeAll(",\"first_image\":\"\",\"published_at\":");
    try std.json.Stringify.value(update.created_at, .{}, writer);
    try writer.writeAll(",\"updated_at\":");
    try std.json.Stringify.value(update.created_at, .{}, writer);
    try writer.writeAll(",\"slug\":");
    try std.json.Stringify.value(slug(update.name), .{}, writer);
    try writer.writeAll(",\"title\":");
    try std.json.Stringify.value(title(update.markdown), .{}, writer);
    try writer.writeAll(",\"preview\":");
    try std.json.Stringify.value(preview(update.markdown), .{}, writer);
    try writer.writeByte('}');
}

pub fn newsSlugKnownFor(catalog: []const Build, value: []const u8) bool {
    for (catalog) |build| for (build.updates) |update| {
        if (std.mem.eql(u8, slug(update.name), value)) return true;
    };
    return false;
}

pub fn newsSlugKnown(value: []const u8) bool {
    return newsSlugKnownFor(&fallback_builds, value);
}

pub fn newsJsonFor(allocator: std.mem.Allocator, catalog: []const Build, selected_year: ?u16) ![]u8 {
    if (catalog.len == 0) return error.EmptyChangelog;
    var years: std.ArrayList(u16) = .empty;
    defer years.deinit(allocator);
    for (catalog) |build| {
        const candidate = buildYear(build);
        if (candidate == 0) continue;
        var known = false;
        for (years.items) |existing| if (existing == candidate) {
            known = true;
            break;
        };
        if (!known) try years.append(allocator, candidate);
    }
    std.mem.sort(u16, years.items, {}, struct {
        fn before(_: void, left: u16, right: u16) bool {
            return left > right;
        }
    }.before);
    if (years.items.len == 0) return error.InvalidChangelogTimestamp;
    const year = selected_year orelse buildYear(catalog[0]);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"news_posts\":[");
    var written: usize = 0;
    outer: for (catalog) |build| for (build.updates, 0..) |update, index| {
        if (updateYear(update) != year) continue;
        if (written == 12) break :outer;
        if (written != 0) try output.writer.writeByte(',');
        try writeNewsPost(&output.writer, build, update, index);
        written += 1;
    };
    try output.writer.print("],\"news_sidebar\":{{\"current_year\":{d},\"news_posts\":[", .{year});
    written = 0;
    sidebar: for (catalog) |build| for (build.updates, 0..) |update, index| {
        if (written == 5) break :sidebar;
        if (written != 0) try output.writer.writeByte(',');
        try writeNewsPost(&output.writer, build, update, index);
        written += 1;
    };
    try output.writer.writeAll("],\"years\":[");
    for (years.items, 0..) |available, index| {
        if (index != 0) try output.writer.writeByte(',');
        try output.writer.print("{d}", .{available});
    }
    try output.writer.writeAll("]},\"cursor\":null}");
    return output.toOwnedSlice();
}

pub fn newsJson(allocator: std.mem.Allocator, selected_year: ?u16) ![]u8 {
    return newsJsonFor(allocator, &fallback_builds, selected_year);
}

test "changelog exposes the complete checked in release history" {
    const manifest = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, @embedFile("../updates/changelog.json"), .{});
    defer manifest.deinit();
    const expected_builds = manifest.value.object.get("builds").?.array.items;
    const json = try indexJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("zigcho!lazer", object.get("streams").?.array.items[0].object.get("display_name").?.string);
    try std.testing.expectEqualStrings(latest_version, object.get("builds").?.array.items[0].object.get("version").?.string);
    const actual_builds = object.get("builds").?.array.items;
    try std.testing.expectEqual(expected_builds.len, actual_builds.len);
    for (expected_builds, actual_builds) |expected, actual| {
        try std.testing.expectEqual(expected.object.get("id").?.integer, actual.object.get("id").?.integer);
        try std.testing.expectEqualStrings(expected.object.get("version").?.string, actual.object.get("version").?.string);
        try std.testing.expectEqualStrings(expected.object.get("created_at").?.string, actual.object.get("created_at").?.string);
        try std.testing.expectEqual(expected.object.get("updates").?.array.items.len, actual.object.get("changelog_entries").?.array.items.len);
        if (expected.object.get("display_version")) |display| try std.testing.expectEqualStrings(display.string, actual.object.get("display_version").?.string);
    }
    var entries: usize = 0;
    for (object.get("builds").?.array.items) |build| entries += build.object.get("changelog_entries").?.array.items.len;
    try std.testing.expectEqual(historyEntryCount(), entries);
    try std.testing.expect(object.get("builds").?.array.items[0].object.get("changelog_entries").?.array.items[0].object.get("title").?.string.len > 0);

    const latest = (try buildJson(std.testing.allocator, "lazer", "latest")).?;
    defer std.testing.allocator.free(latest);
    const parsed_latest = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, latest, .{});
    defer parsed_latest.deinit();
    try std.testing.expectEqualStrings(expected_builds[1].object.get("version").?.string, parsed_latest.value.object.get("versions").?.object.get("previous").?.object.get("version").?.string);

    const oldest = (try buildJson(std.testing.allocator, "zigcho", "2026.809.0")).?;
    defer std.testing.allocator.free(oldest);
    const parsed_oldest = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, oldest, .{});
    defer parsed_oldest.deinit();
    try std.testing.expectEqual(@as(usize, 18), parsed_oldest.value.object.get("changelog_entries").?.array.items.len);
    try std.testing.expectEqualStrings("2026.810.0", parsed_oldest.value.object.get("versions").?.object.get("next").?.object.get("version").?.string);
    try std.testing.expect(parsed_oldest.value.object.get("versions").?.object.get("previous").? == .null);
    try std.testing.expect((try buildJson(std.testing.allocator, "stable", latest_version)) == null);
}

test "news is backed by the checked in zigcho updates" {
    const json = try newsJson(std.testing.allocator, null);
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const posts = parsed.value.object.get("news_posts").?.array.items;
    try std.testing.expectEqual(@as(usize, 12), posts.len);
    try std.testing.expectEqualStrings("ari", posts[0].object.get("author").?.string);
    try std.testing.expect(posts[0].object.get("title").?.string.len > 0);
    try std.testing.expect(posts[0].object.get("preview").?.string.len > 0);
    try std.testing.expect(newsSlugKnown(posts[0].object.get("slug").?.string));
    try std.testing.expectEqual(@as(i64, 2026), parsed.value.object.get("news_sidebar").?.object.get("current_year").?.integer);
    try std.testing.expectEqual(@as(i64, 2026), parsed.value.object.get("news_sidebar").?.object.get("years").?.array.items[0].integer);

    const old = try newsJson(std.testing.allocator, 2025);
    defer std.testing.allocator.free(old);
    const parsed_old = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, old, .{});
    defer parsed_old.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed_old.value.object.get("news_posts").?.array.items.len);
}
