const std = @import("std");
const history = @import("changelog.zig");

pub const manifest_url = "https://raw.githubusercontent.com/raya-ac/zigcho/main/updates/changelog.json";
pub const update_url_prefix = "https://raw.githubusercontent.com/raya-ac/zigcho/main/updates/";
pub const refresh_seconds: i64 = 60;
pub const max_manifest_bytes: usize = 128 * 1024;
pub const max_update_bytes: usize = 128 * 1024;
pub const max_total_markdown_bytes: usize = 2 * 1024 * 1024;
pub const max_builds: usize = 64;
pub const max_updates: usize = history.max_updates;
pub const max_changed_updates_per_refresh: usize = max_updates;
pub const fetch_timeout_seconds: i64 = 4;
const max_update_name_bytes: usize = 96;

pub const Resource = union(enum) {
    manifest,
    update: []const u8,
};

pub const Fetcher = struct {
    context: ?*anyopaque = null,
    fetch_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, Resource, usize) anyerror![]u8,

    pub fn production() Fetcher {
        return .{ .fetch_fn = productionFetch };
    }

    fn fetch(self: Fetcher, allocator: std.mem.Allocator, io: std.Io, resource: Resource, limit: usize) ![]u8 {
        return self.fetch_fn(self.context, allocator, io, resource, limit);
    }
};

fn validUpdateName(name: []const u8) bool {
    if (name.len < "2000-01-01-a.md".len or name.len > max_update_name_bytes or !std.mem.endsWith(u8, name, ".md")) return false;
    for (name, 0..) |char, index| {
        const valid = if (index < 4 or (index >= 5 and index < 7) or (index >= 8 and index < 10))
            std.ascii.isDigit(char)
        else if (index == 4 or index == 7 or index == 10)
            char == '-'
        else if (index >= name.len - 3)
            (index == name.len - 3 and char == '.') or (index == name.len - 2 and char == 'm') or (index == name.len - 1 and char == 'd')
        else
            std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-';
        if (!valid) return false;
    }
    return true;
}

pub fn rawUrl(buffer: []u8, resource: Resource) ![]const u8 {
    return switch (resource) {
        .manifest => manifest_url,
        .update => |name| {
            if (!validUpdateName(name)) return error.InvalidUpdateName;
            return std.fmt.bufPrint(buffer, "{s}{s}", .{ update_url_prefix, name });
        },
    };
}

fn productionFetch(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, resource: Resource, limit: usize) ![]u8 {
    if (limit == 0 or limit > max_total_markdown_bytes) return error.InvalidFetchLimit;
    var url_buffer: [update_url_prefix.len + max_update_name_bytes]u8 = undefined;
    const url = try rawUrl(&url_buffer, resource);
    var limit_buffer: [32]u8 = undefined;
    const limit_text = try std.fmt.bufPrint(&limit_buffer, "{d}", .{limit});
    const result = try std.process.run(allocator, io, .{
        .argv = &.{
            "curl",
            "--disable",
            "--fail",
            "--silent",
            "--show-error",
            "--proto",
            "=https",
            "--connect-timeout",
            "2",
            "--max-time",
            "3",
            "--max-filesize",
            limit_text,
            url,
        },
        .stdout_limit = .limited(limit),
        .stderr_limit = .limited(2048),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(fetch_timeout_seconds) } },
    });
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ChangelogFetchFailed,
        else => return error.ChangelogFetchFailed,
    }
    if (result.stdout.len == 0 or result.stdout.len > limit) return error.InvalidFetchBody;
    return result.stdout;
}

const ManifestUpdate = struct {
    name: []const u8,
    created_at: []const u8,
    commit: []const u8,
    sha256: []const u8,
};

const ManifestBuild = struct {
    id: i64,
    version: []const u8,
    display_version: ?[]const u8 = null,
    created_at: []const u8,
    updates: []const ManifestUpdate,
};

const Manifest = struct {
    schema: u8,
    builds: []const ManifestBuild,
};

fn validVersion(value: []const u8) bool {
    if (value.len == 0 or value.len > 32) return false;
    for (value) |char| if (!std.ascii.isDigit(char) and char != '.') return false;
    return true;
}

fn allDigits(value: []const u8) bool {
    for (value) |char| if (!std.ascii.isDigit(char)) return false;
    return true;
}

fn leapYear(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn validTimestamp(value: []const u8) bool {
    if ((value.len != 20 and value.len != 25) or !std.unicode.utf8ValidateSlice(value)) return false;
    if (value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') return false;
    if (!allDigits(value[0..4]) or !allDigits(value[5..7]) or !allDigits(value[8..10]) or !allDigits(value[11..13]) or !allDigits(value[14..16]) or !allDigits(value[17..19])) return false;
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return false;
    const hour = std.fmt.parseInt(u8, value[11..13], 10) catch return false;
    const minute = std.fmt.parseInt(u8, value[14..16], 10) catch return false;
    const second = std.fmt.parseInt(u8, value[17..19], 10) catch return false;
    if (year == 0 or month == 0 or month > 12 or hour > 23 or minute > 59 or second > 59) return false;
    const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const maximum_day = month_days[month - 1] + @as(u8, if (month == 2 and leapYear(year)) 1 else 0);
    if (day == 0 or day > maximum_day) return false;
    if (value.len == 20) return value[19] == 'Z';
    if ((value[19] != '+' and value[19] != '-') or value[22] != ':' or !allDigits(value[20..22]) or !allDigits(value[23..25])) return false;
    const offset_hour = std.fmt.parseInt(u8, value[20..22], 10) catch return false;
    const offset_minute = std.fmt.parseInt(u8, value[23..25], 10) catch return false;
    return offset_hour < 14 and offset_minute <= 59 or offset_hour == 14 and offset_minute == 0;
}

fn validCommit(value: []const u8) bool {
    if (value.len == 0) return true;
    if (value.len != 40) return false;
    for (value) |char| if (!std.ascii.isHex(char) or std.ascii.isUpper(char)) return false;
    return true;
}

fn digestFor(markdown: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(markdown, &digest, .{});
    return digest;
}

fn parseDigest(value: []const u8) ![32]u8 {
    if (value.len != 64) return error.InvalidUpdateDigest;
    var result: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, value) catch return error.InvalidUpdateDigest;
    const canonical = std.fmt.bytesToHex(result, .lower);
    if (!std.mem.eql(u8, &canonical, value)) return error.InvalidUpdateDigest;
    return result;
}

fn sameDigest(markdown: []const u8, expected: [32]u8) bool {
    const actual = digestFor(markdown);
    return std.mem.eql(u8, &actual, &expected);
}

fn validMarkdown(markdown: []const u8) bool {
    if (markdown.len == 0 or markdown.len > max_update_bytes or !std.unicode.utf8ValidateSlice(markdown) or std.mem.indexOfScalar(u8, markdown, 0) != null) return false;
    const line_end = std.mem.indexOfScalar(u8, markdown, '\n') orelse markdown.len;
    return std.mem.trim(u8, markdown[0..line_end], "#* \t\r").len != 0;
}

fn freeUpdate(allocator: std.mem.Allocator, update: history.Update) void {
    allocator.free(update.name);
    allocator.free(update.created_at);
    allocator.free(update.commit);
    allocator.free(update.markdown);
}

fn freeBuild(allocator: std.mem.Allocator, build: history.Build) void {
    allocator.free(build.version);
    if (build.display_version) |display_version| allocator.free(display_version);
    allocator.free(build.created_at);
    for (build.updates) |update| freeUpdate(allocator, update);
    allocator.free(build.updates);
}

const Catalog = struct {
    allocator: std.mem.Allocator,
    builds: []history.Build,

    fn deinit(self: *Catalog) void {
        for (self.builds) |build| freeBuild(self.allocator, build);
        self.allocator.free(self.builds);
        self.* = undefined;
    }

    fn clone(self: *const Catalog, allocator: std.mem.Allocator) !Catalog {
        var list: std.ArrayList(history.Build) = .empty;
        errdefer {
            for (list.items) |build| freeBuild(allocator, build);
            list.deinit(allocator);
        }
        for (self.builds) |build| {
            const owned = try cloneBuild(allocator, build);
            var appended = false;
            errdefer if (!appended) freeBuild(allocator, owned);
            try list.append(allocator, owned);
            appended = true;
        }
        return .{ .allocator = allocator, .builds = try list.toOwnedSlice(allocator) };
    }
};

fn ownUpdate(allocator: std.mem.Allocator, update: history.Update) !history.Update {
    const name = try allocator.dupe(u8, update.name);
    errdefer allocator.free(name);
    const created_at = try allocator.dupe(u8, update.created_at);
    errdefer allocator.free(created_at);
    const commit = try allocator.dupe(u8, update.commit);
    errdefer allocator.free(commit);
    const markdown = try allocator.dupe(u8, update.markdown);
    errdefer allocator.free(markdown);
    return .{ .name = name, .created_at = created_at, .commit = commit, .markdown = markdown };
}

fn cloneBuild(allocator: std.mem.Allocator, build: history.Build) !history.Build {
    var updates: std.ArrayList(history.Update) = .empty;
    errdefer {
        for (updates.items) |update| freeUpdate(allocator, update);
        updates.deinit(allocator);
    }
    for (build.updates) |update| {
        const owned = try ownUpdate(allocator, update);
        var appended = false;
        errdefer if (!appended) freeUpdate(allocator, owned);
        try updates.append(allocator, owned);
        appended = true;
    }
    const owned_updates = try updates.toOwnedSlice(allocator);
    errdefer {
        for (owned_updates) |update| freeUpdate(allocator, update);
        allocator.free(owned_updates);
    }
    const version = try allocator.dupe(u8, build.version);
    errdefer allocator.free(version);
    const display_version = if (build.display_version) |value| try allocator.dupe(u8, value) else null;
    errdefer if (display_version) |value| allocator.free(value);
    const created_at = try allocator.dupe(u8, build.created_at);
    errdefer allocator.free(created_at);
    return .{ .id = build.id, .version = version, .display_version = display_version, .created_at = created_at, .updates = owned_updates };
}

fn findReusable(seed: ?*const Catalog, name: []const u8, digest: [32]u8) ?[]const u8 {
    if (seed) |catalog| for (catalog.builds) |build| for (build.updates) |update| {
        if (std.mem.eql(u8, update.name, name) and sameDigest(update.markdown, digest)) return update.markdown;
    };
    for (history.fallback_builds) |build| for (build.updates) |update| {
        if (std.mem.eql(u8, update.name, name) and sameDigest(update.markdown, digest)) return update.markdown;
    };
    return null;
}

fn manifestPreservesBuilds(manifest: Manifest, catalog: []const history.Build) bool {
    for (catalog) |existing_build| {
        const remote_build = for (manifest.builds) |candidate| {
            if (candidate.id == existing_build.id) break candidate;
        } else return false;
        if (!std.mem.eql(u8, remote_build.version, existing_build.version)) return false;
        for (existing_build.updates) |existing_update| {
            for (remote_build.updates) |remote_update| {
                if (std.mem.eql(u8, remote_update.name, existing_update.name)) break;
            } else return false;
        }
    }
    return true;
}

fn validateManifest(manifest: Manifest, seed: ?*const Catalog) !usize {
    if (manifest.schema != 1) return error.UnsupportedChangelogManifest;
    if (manifest.builds.len == 0 or manifest.builds.len > max_builds) return error.InvalidBuildCount;
    var update_count: usize = 0;
    for (manifest.builds, 0..) |build, build_index| {
        if (build.id <= 0 or build.id > history.max_build_id or !validVersion(build.version) or !validTimestamp(build.created_at)) return error.InvalidBuild;
        if (build.display_version) |value| if (value.len == 0 or value.len > 64 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidBuild;
        if (build.updates.len == 0) return error.InvalidBuild;
        if (build_index != 0 and manifest.builds[build_index - 1].id <= build.id) return error.InvalidBuildOrder;
        for (manifest.builds[0..build_index]) |older| if (std.mem.eql(u8, older.version, build.version)) return error.DuplicateBuild;
        for (build.updates) |update| {
            update_count += 1;
            if (update_count > max_updates or !validUpdateName(update.name) or !validTimestamp(update.created_at) or !validCommit(update.commit)) return error.InvalidUpdate;
            _ = try parseDigest(update.sha256);
            for (manifest.builds[0..build_index]) |older| for (older.updates) |previous| if (std.mem.eql(u8, previous.name, update.name)) return error.DuplicateUpdate;
        }
        for (build.updates, 0..) |update, update_index| for (build.updates[0..update_index]) |previous| {
            if (std.mem.eql(u8, previous.name, update.name)) return error.DuplicateUpdate;
        };
    }
    if (!manifestPreservesBuilds(manifest, &history.fallback_builds)) return error.HistoricalUpdateRemoved;
    if (seed) |catalog| if (!manifestPreservesBuilds(manifest, catalog.builds)) return error.HistoricalUpdateRemoved;
    return update_count;
}

fn loadUpdate(allocator: std.mem.Allocator, io: std.Io, fetcher: Fetcher, source: ManifestUpdate, seed: ?*const Catalog, changed_count: *usize, total_bytes: *usize) !history.Update {
    const expected = try parseDigest(source.sha256);
    const markdown = if (findReusable(seed, source.name, expected)) |reusable|
        try allocator.dupe(u8, reusable)
    else blk: {
        if (changed_count.* == max_changed_updates_per_refresh) return error.TooManyChangedUpdates;
        changed_count.* += 1;
        break :blk try fetcher.fetch(allocator, io, .{ .update = source.name }, max_update_bytes);
    };
    errdefer allocator.free(markdown);
    if (!validMarkdown(markdown)) return error.InvalidMarkdown;
    if (!sameDigest(markdown, expected)) return error.UpdateDigestMismatch;
    total_bytes.* = std.math.add(usize, total_bytes.*, markdown.len) catch return error.ChangelogTooLarge;
    if (total_bytes.* > max_total_markdown_bytes) return error.ChangelogTooLarge;
    const name = try allocator.dupe(u8, source.name);
    errdefer allocator.free(name);
    const created_at = try allocator.dupe(u8, source.created_at);
    errdefer allocator.free(created_at);
    const commit = try allocator.dupe(u8, source.commit);
    errdefer allocator.free(commit);
    return .{ .name = name, .created_at = created_at, .commit = commit, .markdown = markdown };
}

fn loadBuild(allocator: std.mem.Allocator, io: std.Io, fetcher: Fetcher, source: ManifestBuild, seed: ?*const Catalog, changed_count: *usize, total_bytes: *usize) !history.Build {
    var updates: std.ArrayList(history.Update) = .empty;
    errdefer {
        for (updates.items) |update| freeUpdate(allocator, update);
        updates.deinit(allocator);
    }
    for (source.updates) |update| {
        const owned = try loadUpdate(allocator, io, fetcher, update, seed, changed_count, total_bytes);
        var appended = false;
        errdefer if (!appended) freeUpdate(allocator, owned);
        try updates.append(allocator, owned);
        appended = true;
    }
    const owned_updates = try updates.toOwnedSlice(allocator);
    errdefer {
        for (owned_updates) |update| freeUpdate(allocator, update);
        allocator.free(owned_updates);
    }
    const version = try allocator.dupe(u8, source.version);
    errdefer allocator.free(version);
    const display_version = if (source.display_version) |value| try allocator.dupe(u8, value) else null;
    errdefer if (display_version) |value| allocator.free(value);
    const created_at = try allocator.dupe(u8, source.created_at);
    errdefer allocator.free(created_at);
    return .{ .id = source.id, .version = version, .display_version = display_version, .created_at = created_at, .updates = owned_updates };
}

fn loadCatalog(allocator: std.mem.Allocator, io: std.Io, fetcher: Fetcher, manifest_bytes: []const u8, seed: ?*const Catalog) !Catalog {
    if (manifest_bytes.len == 0 or manifest_bytes.len > max_manifest_bytes) return error.InvalidManifestSize;
    const parsed = try std.json.parseFromSlice(Manifest, allocator, manifest_bytes, .{ .allocate = .alloc_always, .max_value_len = max_manifest_bytes });
    defer parsed.deinit();
    _ = try validateManifest(parsed.value, seed);
    var changed_count: usize = 0;
    var total_bytes: usize = 0;
    var builds: std.ArrayList(history.Build) = .empty;
    errdefer {
        for (builds.items) |build| freeBuild(allocator, build);
        builds.deinit(allocator);
    }
    for (parsed.value.builds) |build| {
        const owned = try loadBuild(allocator, io, fetcher, build, seed, &changed_count, &total_bytes);
        var appended = false;
        errdefer if (!appended) freeBuild(allocator, owned);
        try builds.append(allocator, owned);
        appended = true;
    }
    return .{ .allocator = allocator, .builds = try builds.toOwnedSlice(allocator) };
}

pub const Feed = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    fetcher: Fetcher,
    mutex: std.Io.Mutex = .init,
    current: ?Catalog = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Feed {
        return initWithFetcher(allocator, io, Fetcher.production());
    }

    pub fn initWithFetcher(allocator: std.mem.Allocator, io: std.Io, fetcher: Fetcher) Feed {
        return .{ .allocator = allocator, .io = io, .fetcher = fetcher };
    }

    pub fn deinit(self: *Feed) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.current) |*catalog| catalog.deinit();
        self.current = null;
    }

    pub fn refresh(self: *Feed) !void {
        self.mutex.lockUncancelable(self.io);
        var seed: ?Catalog = null;
        if (self.current) |*catalog| seed = catalog.clone(self.allocator) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        defer if (seed) |*catalog| catalog.deinit();
        const manifest = try self.fetcher.fetch(self.allocator, self.io, .manifest, max_manifest_bytes);
        defer self.allocator.free(manifest);
        var next = try loadCatalog(self.allocator, self.io, self.fetcher, manifest, if (seed) |*catalog| catalog else null);
        errdefer next.deinit();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.current) |*catalog| catalog.deinit();
        self.current = next;
    }

    pub fn indexJson(self: *Feed, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return if (self.current) |catalog| history.indexJsonFor(allocator, catalog.builds) else history.indexJson(allocator);
    }

    pub fn buildJson(self: *Feed, allocator: std.mem.Allocator, stream: []const u8, version: []const u8) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return if (self.current) |catalog| history.buildJsonFor(allocator, catalog.builds, stream, version) else history.buildJson(allocator, stream, version);
    }

    pub fn newsSlugKnown(self: *Feed, value: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return if (self.current) |catalog| history.newsSlugKnownFor(catalog.builds, value) else history.newsSlugKnown(value);
    }

    pub fn newsJson(self: *Feed, allocator: std.mem.Allocator, selected_year: ?u16) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return if (self.current) |catalog| history.newsJsonFor(allocator, catalog.builds, selected_year) else history.newsJson(allocator, selected_year);
    }
};

const TestFetcher = struct {
    const Failure = enum { none, missing_curl, timeout };

    manifest: []const u8,
    update_name: []const u8 = "",
    update_markdown: []const u8 = "",
    failure: Failure = .none,
    manifest_fetches: usize = 0,
    update_fetches: usize = 0,

    fn fetch(context: ?*anyopaque, allocator: std.mem.Allocator, _: std.Io, resource: Resource, limit: usize) ![]u8 {
        const self: *TestFetcher = @ptrCast(@alignCast(context.?));
        switch (self.failure) {
            .none => {},
            .missing_curl => return error.FileNotFound,
            .timeout => return error.Timeout,
        }
        return switch (resource) {
            .manifest => blk: {
                self.manifest_fetches += 1;
                if (self.manifest.len > limit) return error.StreamTooLong;
                break :blk try allocator.dupe(u8, self.manifest);
            },
            .update => |name| blk: {
                self.update_fetches += 1;
                if ((self.update_name.len != 0 and !std.mem.eql(u8, name, self.update_name)) or self.update_markdown.len > limit) return error.UnexpectedUpdateFetch;
                break :blk try allocator.dupe(u8, self.update_markdown);
            },
        };
    }

    fn interface(self: *TestFetcher) Fetcher {
        return .{ .context = self, .fetch_fn = fetch };
    }
};

fn manifestWithPrependedBuildVersionAt(allocator: std.mem.Allocator, name: []const u8, digest_markdown: []const u8, build_id: i64, version: []const u8, timestamp: []const u8) ![]u8 {
    const base = @embedFile("../updates/changelog.json");
    const marker = "\"builds\": [";
    const marker_start = std.mem.indexOf(u8, base, marker) orelse return error.InvalidTestManifest;
    const split = marker_start + marker.len;
    const digest = std.fmt.bytesToHex(digestFor(digest_markdown), .lower);
    return std.fmt.allocPrint(
        allocator,
        "{s}\n    {{\"id\":{d},\"version\":\"{s}\",\"display_version\":\"zigcho release 1.1\",\"created_at\":\"{s}\",\"updates\":[{{\"name\":\"{s}\",\"created_at\":\"{s}\",\"commit\":\"\",\"sha256\":\"{s}\"}}]}},{s}",
        .{ base[0..split], build_id, version, timestamp, name, timestamp, digest, base[split..] },
    );
}

fn manifestWithPrependedBuildAt(allocator: std.mem.Allocator, name: []const u8, digest_markdown: []const u8, build_id: i64, timestamp: []const u8) ![]u8 {
    return manifestWithPrependedBuildVersionAt(allocator, name, digest_markdown, build_id, "2026.826.0", timestamp);
}

fn manifestWithPrependedBuild(allocator: std.mem.Allocator, name: []const u8, digest_markdown: []const u8) ![]u8 {
    return manifestWithPrependedBuildAt(allocator, name, digest_markdown, 37, "2026-08-25T00:00:00+09:30");
}

fn manifestWithPrependedUpdates(allocator: std.mem.Allocator, count: usize, digest_markdown: []const u8) ![]u8 {
    const base = @embedFile("../updates/changelog.json");
    const marker = "\"builds\": [";
    const marker_start = std.mem.indexOf(u8, base, marker) orelse return error.InvalidTestManifest;
    const split = marker_start + marker.len;
    const digest = std.fmt.bytesToHex(digestFor(digest_markdown), .lower);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{s}\n    {{\"id\":37,\"version\":\"2026.826.0\",\"display_version\":\"zigcho release 1.1\",\"created_at\":\"2026-08-25T00:00:00+09:30\",\"updates\":[", .{base[0..split]});
    for (0..count) |index| {
        if (index != 0) try output.writer.writeByte(',');
        try output.writer.print("{{\"name\":\"2026-08-25-raw-feed-{d}.md\",\"created_at\":\"2026-08-25T00:00:00+09:30\",\"commit\":\"\",\"sha256\":\"{s}\"}}", .{ index, digest });
    }
    try output.writer.print("]}},{s}", .{base[split..]});
    return output.toOwnedSlice();
}

test "raw changelog fetches cannot leave the fixed GitHub directory" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(manifest_url, try rawUrl(&buffer, .manifest));
    try std.testing.expectEqualStrings(update_url_prefix ++ "2026-08-24-release-one.md", try rawUrl(&buffer, .{ .update = "2026-08-24-release-one.md" }));
    try std.testing.expectError(error.InvalidUpdateName, rawUrl(&buffer, .{ .update = "../README.md" }));
    try std.testing.expectError(error.InvalidUpdateName, rawUrl(&buffer, .{ .update = "2026-08-24-release/one.md" }));
}

test "checked in manifest reuses every embedded update without network fanout" {
    var fixture: TestFetcher = .{ .manifest = @embedFile("../updates/changelog.json") };
    var feed = Feed.initWithFetcher(std.testing.allocator, std.testing.io, fixture.interface());
    defer feed.deinit();
    try feed.refresh();
    try std.testing.expectEqual(@as(usize, 1), fixture.manifest_fetches);
    try std.testing.expectEqual(@as(usize, 0), fixture.update_fetches);
    const json = try feed.indexJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("zigcho release 1.1", parsed.value.object.get("builds").?.array.items[0].object.get("display_version").?.string);
    try std.testing.expectEqual(history.historyEntryCount(), blk: {
        var count: usize = 0;
        for (parsed.value.object.get("builds").?.array.items) |build| count += build.object.get("changelog_entries").?.array.items.len;
        break :blk count;
    });
}

test "restart loads more than eight raw only updates without a server rebuild" {
    const markdown = "# raw only\n\nthis update was not embedded in the server.";
    const manifest = try manifestWithPrependedUpdates(std.testing.allocator, 9, markdown);
    defer std.testing.allocator.free(manifest);
    var fixture: TestFetcher = .{ .manifest = manifest, .update_markdown = markdown };
    {
        var first = Feed.initWithFetcher(std.testing.allocator, std.testing.io, fixture.interface());
        defer first.deinit();
        try first.refresh();
        try std.testing.expectEqual(@as(usize, 9), fixture.update_fetches);
    }
    fixture.manifest_fetches = 0;
    fixture.update_fetches = 0;
    {
        var restarted = Feed.initWithFetcher(std.testing.allocator, std.testing.io, fixture.interface());
        defer restarted.deinit();
        try restarted.refresh();
        try std.testing.expectEqual(@as(usize, 1), fixture.manifest_fetches);
        try std.testing.expectEqual(@as(usize, 9), fixture.update_fetches);
        const index = try restarted.indexJson(std.testing.allocator);
        defer std.testing.allocator.free(index);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, index, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(history.historyEntryCount() + 9, blk: {
            var entries: usize = 0;
            for (parsed.value.object.get("builds").?.array.items) |build| entries += build.object.get("changelog_entries").?.array.items.len;
            break :blk entries;
        });
    }
}

test "feed rejects build ids that cannot produce safe entry ids" {
    const markdown = "# overflow\n\nnever accepted";
    const manifest = try manifestWithPrependedBuildAt(std.testing.allocator, "2026-08-25-overflow.md", markdown, history.max_build_id + 1, "2026-08-25T00:00:00+09:30");
    defer std.testing.allocator.free(manifest);
    var fixture: TestFetcher = .{ .manifest = manifest, .update_name = "2026-08-25-overflow.md", .update_markdown = markdown };
    var feed = Feed.initWithFetcher(std.testing.allocator, std.testing.io, fixture.interface());
    defer feed.deinit();
    try std.testing.expectError(error.InvalidBuild, feed.refresh());
    try std.testing.expectEqual(@as(usize, 0), fixture.update_fetches);
}

test "feed timestamps are canonical and DateTimeOffset compatible" {
    try std.testing.expect(validTimestamp("2026-08-25T00:00:00Z"));
    try std.testing.expect(validTimestamp("2026-08-25T00:00:00+09:30"));
    try std.testing.expect(validTimestamp("2024-02-29T23:59:59-14:00"));
    try std.testing.expect(!validTimestamp("2026-99-99Txxxxxxxxx"));
    try std.testing.expect(!validTimestamp("2025-02-29T00:00:00Z"));
    try std.testing.expect(!validTimestamp("2026-08-25T24:00:00Z"));
    try std.testing.expect(!validTimestamp("2026-08-25T00:00:00+14:01"));
    const markdown = "# invalid time\n\nnever accepted";
    const manifest = try manifestWithPrependedBuildAt(std.testing.allocator, "2026-08-25-invalid-time.md", markdown, 37, "2026-99-99Txxxxxxxxx");
    defer std.testing.allocator.free(manifest);
    var fixture: TestFetcher = .{ .manifest = manifest, .update_name = "2026-08-25-invalid-time.md", .update_markdown = markdown };
    var feed = Feed.initWithFetcher(std.testing.allocator, std.testing.io, fixture.interface());
    defer feed.deinit();
    try std.testing.expectError(error.InvalidBuild, feed.refresh());
    try std.testing.expectEqual(@as(usize, 0), fixture.update_fetches);
}

test "dynamic changelog swaps atomically and fetch failure keeps the last good feed" {
    const markdown = "# raw feed release\n\nthis came from main without rebuilding zigcho.";
    const name = "2026-08-25-raw-feed-release.md";
    const manifest = try manifestWithPrependedBuild(std.testing.allocator, name, markdown);
    defer std.testing.allocator.free(manifest);
    var fixture: TestFetcher = .{ .manifest = manifest, .update_name = name, .update_markdown = markdown };
    var feed = Feed.initWithFetcher(std.testing.allocator, std.testing.io, fixture.interface());
    defer feed.deinit();
    try feed.refresh();
    try std.testing.expectEqual(@as(usize, 1), fixture.update_fetches);
    const latest = (try feed.buildJson(std.testing.allocator, "lazer", "latest")).?;
    defer std.testing.allocator.free(latest);
    try std.testing.expect(std.mem.indexOf(u8, latest, "\"version\":\"2026.826.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest, "\"display_version\":\"zigcho release 1.1\"") != null);
    try std.testing.expect(feed.newsSlugKnown("2026-08-25-raw-feed-release"));
    const news = try feed.newsJson(std.testing.allocator, 2026);
    defer std.testing.allocator.free(news);
    try std.testing.expect(std.mem.indexOf(u8, news, "raw feed release") != null);

    fixture.failure = .missing_curl;
    try std.testing.expectError(error.FileNotFound, feed.refresh());
    fixture.failure = .timeout;
    try std.testing.expectError(error.Timeout, feed.refresh());
    const after_failures = try feed.indexJson(std.testing.allocator);
    defer std.testing.allocator.free(after_failures);
    try std.testing.expect(std.mem.indexOf(u8, after_failures, "raw feed release") != null);
    try std.testing.expect(fetch_timeout_seconds <= 4);
}

test "dynamic next year build is visible in changelog and news contracts" {
    const markdown = "# next year release\n\nthis stayed live without a server or client rebuild.";
    const name = "2027-01-02-next-year-release.md";
    const manifest = try manifestWithPrependedBuildVersionAt(std.testing.allocator, name, markdown, 37, "2027.102.0", "2027-01-02T00:00:00+09:30");
    defer std.testing.allocator.free(manifest);
    var fixture: TestFetcher = .{ .manifest = manifest, .update_name = name, .update_markdown = markdown };
    var feed = Feed.initWithFetcher(std.testing.allocator, std.testing.io, fixture.interface());
    defer feed.deinit();
    try feed.refresh();

    const index_json = try feed.indexJson(std.testing.allocator);
    defer std.testing.allocator.free(index_json);
    var index = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, index_json, .{});
    defer index.deinit();
    const build = index.value.object.get("builds").?.array.items[0].object;
    try std.testing.expectEqualStrings("2027.102.0", build.get("version").?.string);
    try std.testing.expectEqualStrings("lazer", build.get("update_stream").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("next year release", build.get("changelog_entries").?.array.items[0].object.get("title").?.string);
    try std.testing.expectEqualStrings("this stayed live without a server or client rebuild.", build.get("changelog_entries").?.array.items[0].object.get("message").?.string);

    const news_json = try feed.newsJson(std.testing.allocator, null);
    defer std.testing.allocator.free(news_json);
    var news = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, news_json, .{});
    defer news.deinit();
    try std.testing.expectEqualStrings("2027-01-02-next-year-release", news.value.object.get("news_posts").?.array.items[0].object.get("slug").?.string);
    const sidebar = news.value.object.get("news_sidebar").?.object;
    try std.testing.expectEqual(@as(i64, 2027), sidebar.get("current_year").?.integer);
    try std.testing.expectEqual(@as(usize, 2), sidebar.get("years").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 2027), sidebar.get("years").?.array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 2026), sidebar.get("years").?.array.items[1].integer);
}

test "remote changelog rejects traversal and digest mismatches without replacing fallback" {
    const markdown = "# expected\n\nbody";
    const traversal_manifest = try manifestWithPrependedBuild(std.testing.allocator, "../release.md", markdown);
    defer std.testing.allocator.free(traversal_manifest);
    var traversal_fixture: TestFetcher = .{ .manifest = traversal_manifest };
    var feed = Feed.initWithFetcher(std.testing.allocator, std.testing.io, traversal_fixture.interface());
    defer feed.deinit();
    try std.testing.expectError(error.InvalidUpdate, feed.refresh());
    try std.testing.expectEqual(@as(usize, 0), traversal_fixture.update_fetches);

    const name = "2026-08-25-wrong-digest.md";
    const digest_manifest = try manifestWithPrependedBuild(std.testing.allocator, name, markdown);
    defer std.testing.allocator.free(digest_manifest);
    var digest_fixture: TestFetcher = .{ .manifest = digest_manifest, .update_name = name, .update_markdown = "# changed\n\nwrong bytes" };
    feed.fetcher = digest_fixture.interface();
    try std.testing.expectError(error.UpdateDigestMismatch, feed.refresh());
    const fallback = try feed.indexJson(std.testing.allocator);
    defer std.testing.allocator.free(fallback);
    try std.testing.expect(std.mem.indexOf(u8, fallback, "\"version\":\"2026.824.0\"") != null);
}
