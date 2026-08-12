const std = @import("std");
const beatmap = @import("beatmap.zig");
const pp = @import("pp.zig");
const storage = @import("runtime_storage.zig");

const metadata_limit = 256 * 1024;
const archive_limit = 128 * 1024 * 1024;
const map_limit = 16 * 1024 * 1024;
const entry_limit = 4096;
pub const max_concurrent_hydrations = 4;

const NerinyanMap = struct {
    id: i32,
    beatmapset_id: i32,
    version: []const u8,
    checksum: ?[]const u8 = null,
    mode_int: u8 = 0,
    bpm: ?f64 = null,
    ar: ?f64 = null,
    accuracy: ?f64 = null,
    cs: ?f64 = null,
    drain: ?f64 = null,
    total_length: ?i32 = null,
    max_combo: ?u32 = null,
    difficulty_rating: ?f64 = null,
};

const NerinyanSet = struct {
    id: i32,
    beatmaps: []NerinyanMap,
    ranked: i32,
    artist: []const u8 = "",
    title: []const u8 = "",
    creator: []const u8 = "",
    source: []const u8 = "",
    tags: []const u8 = "",
};

const RemoteMap = struct {
    approved: i32,
    beatmap_id: i32,
};

pub const Sync = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_max_bytes: u64,
    in_progress: std.StringHashMap(void),
    in_progress_mutex: std.Io.Mutex = .init,
    attempts: std.atomic.Value(u64) = .init(0),
    successes: std.atomic.Value(u64) = .init(0),
    failures: std.atomic.Value(u64) = .init(0),
    backoff_skips: std.atomic.Value(u64) = .init(0),
    capacity_skips: std.atomic.Value(u64) = .init(0),
    pruned_entries: std.atomic.Value(u64) = .init(0),
    pruned_bytes: std.atomic.Value(u64) = .init(0),

    pub const Metrics = struct {
        attempts: u64,
        successes: u64,
        failures: u64,
        backoff_skips: u64,
        capacity_skips: u64,
        pruned_entries: u64,
        pruned_bytes: u64,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cache_max_bytes: u64) Sync {
        return .{
            .allocator = allocator,
            .io = io,
            .cache_max_bytes = cache_max_bytes,
            .in_progress = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Sync) void {
        self.in_progress.deinit();
    }

    pub fn metrics(self: *const Sync) Metrics {
        return .{
            .attempts = self.attempts.load(.monotonic),
            .successes = self.successes.load(.monotonic),
            .failures = self.failures.load(.monotonic),
            .backoff_skips = self.backoff_skips.load(.monotonic),
            .capacity_skips = self.capacity_skips.load(.monotonic),
            .pruned_entries = self.pruned_entries.load(.monotonic),
            .pruned_bytes = self.pruned_bytes.load(.monotonic),
        };
    }

    pub fn ensure(self: *Sync, store: *storage.Store, wanted_md5: []const u8, expected_set_id: ?i32) !bool {
        if (!validMd5(wanted_md5)) return false;
        if (!try needsHydration(store, wanted_md5)) return true;
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        if (!try store.hydrationRetryAllowed(wanted_md5, now)) {
            _ = self.backoff_skips.fetchAdd(1, .monotonic);
            return false;
        }

        const md5_owned = switch (self.claim(wanted_md5) catch return false) {
            .claimed => |value| value,
            .duplicate => return false,
            .at_capacity => return false,
        };

        const set_id = expected_set_id orelse {
            self.removeFromProgress(md5_owned);
            return false;
        };
        if (set_id <= 0) {
            self.removeFromProgress(md5_owned);
            return false;
        }

        _ = self.attempts.fetchAdd(1, .monotonic);
        const remote = self.fetchAndStoreMetadata(store, md5_owned, set_id) catch |err| {
            std.log.warn("metadata fetch failed for {s}: {t}", .{ md5_owned, err });
            self.recordFailure(store, md5_owned, set_id, err);
            self.removeFromProgress(md5_owned);
            return false;
        };

        const thread = std.Thread.spawn(.{}, backgroundDownload, .{ self, store, md5_owned, set_id, remote }) catch {
            self.recordFailure(store, md5_owned, set_id, error.ThreadSpawnFailed);
            self.removeFromProgress(md5_owned);
            return false;
        };
        thread.detach();
        return false;
    }

    const Claim = union(enum) {
        claimed: []const u8,
        duplicate,
        at_capacity,
    };

    fn claim(self: *Sync, wanted_md5: []const u8) !Claim {
        self.in_progress_mutex.lockUncancelable(self.io);
        defer self.in_progress_mutex.unlock(self.io);
        if (self.in_progress.contains(wanted_md5)) return .duplicate;
        if (self.in_progress.count() >= max_concurrent_hydrations) {
            _ = self.capacity_skips.fetchAdd(1, .monotonic);
            return .at_capacity;
        }

        const md5_owned = try self.allocator.dupe(u8, wanted_md5);
        errdefer self.allocator.free(md5_owned);
        try self.in_progress.put(md5_owned, {});
        return .{ .claimed = md5_owned };
    }

    fn fetchAndStoreMetadata(self: *Sync, store: *storage.Store, wanted_md5: []const u8, set_id: i32) !RemoteMap {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        std.log.info("[hydrate] start md5={s} set={d}", .{ wanted_md5, set_id });

        const metadata_url = try std.fmt.allocPrint(self.allocator, "https://api.nerinyan.moe/v2/beatmapsets/{d}", .{set_id});
        defer self.allocator.free(metadata_url);
        const metadata_json = fetchFn(&client, self.allocator, metadata_url, metadata_limit) catch |err| {
            std.log.warn("[hydrate] metadata fetch failed: {t}", .{err});
            return err;
        };
        defer self.allocator.free(metadata_json);
        const parsed = std.json.parseFromSlice(NerinyanSet, self.allocator, metadata_json, .{ .ignore_unknown_fields = true }) catch |err| {
            std.log.warn("[hydrate] metadata parse failed: {t}", .{err});
            return err;
        };
        defer parsed.deinit();
        if (parsed.value.id != set_id or parsed.value.beatmaps.len == 0) return error.IdMismatch;
        var remote: ?NerinyanMap = null;
        for (parsed.value.beatmaps) |candidate| {
            if (candidate.checksum) |checksum| if (std.ascii.eqlIgnoreCase(checksum, wanted_md5)) {
                remote = candidate;
                break;
            };
        }
        const map_info = remote orelse return error.Md5NotFound;
        if (map_info.id <= 0 or map_info.beatmapset_id != set_id) return error.IdMismatch;

        const meta = beatmap.Metadata{
            .id = map_info.id,
            .set_id = map_info.beatmapset_id,
            .mode = map_info.mode_int,
            .artist = parsed.value.artist,
            .title = parsed.value.title,
            .version = map_info.version,
            .creator = parsed.value.creator,
            .source = parsed.value.source,
            .tags = parsed.value.tags,
            .hp = map_info.drain orelse 0,
            .cs = map_info.cs orelse 0,
            .od = map_info.accuracy orelse 0,
            .ar = map_info.ar orelse 0,
            .bpm = map_info.bpm orelse 0,
            .total_length = map_info.total_length orelse 0,
            .count_circles = 0,
            .count_sliders = 0,
            .count_spinners = 0,
            .object_count = 0,
        };
        try store.upsertBeatmapMeta(meta, wanted_md5, localStatus(parsed.value.ranked), map_info.difficulty_rating orelse 0, map_info.max_combo orelse 0);
        std.log.info("[hydrate] metadata ok — {s} - {s} [{s}] stars={d:.2}", .{ parsed.value.artist, parsed.value.title, map_info.version, map_info.difficulty_rating orelse 0 });
        return .{ .approved = parsed.value.ranked, .beatmap_id = map_info.id };
    }

    fn fetchArchive(self: *Sync, client: *std.http.Client, set_id: i32) ![]u8 {
        const primary_url = try std.fmt.allocPrint(self.allocator, "https://beatmaps.akatsuki.gg/api/d/{d}", .{set_id});
        defer self.allocator.free(primary_url);
        if (fetchFn(client, self.allocator, primary_url, archive_limit)) |bytes| return bytes else |err| if (err == error.OutOfMemory) return err;

        const next_url = try std.fmt.allocPrint(self.allocator, "https://api.nerinyan.moe/d/{d}", .{set_id});
        defer self.allocator.free(next_url);
        return fetchFn(client, self.allocator, next_url, archive_limit);
    }

    fn removeFromProgress(self: *Sync, md5: []const u8) void {
        self.in_progress_mutex.lockUncancelable(self.io);
        _ = self.in_progress.remove(md5);
        self.in_progress_mutex.unlock(self.io);
        self.allocator.free(md5);
    }

    fn backgroundDownload(self: *Sync, store: *storage.Store, md5_owned: []const u8, set_id: i32, remote: RemoteMap) void {
        defer self.removeFromProgress(md5_owned);
        self.downloadArchive(store, md5_owned, set_id, remote) catch |err| {
            std.log.warn("[hydrate] download failed md5={s}: {t}", .{ md5_owned, err });
            self.recordFailure(store, md5_owned, set_id, err);
            return;
        };
        store.clearHydrationFailure(md5_owned) catch |err| std.log.warn("[hydrate] could not clear failure state md5={s}: {t}", .{ md5_owned, err });
        _ = self.successes.fetchAdd(1, .monotonic);
    }

    fn recordFailure(self: *Sync, store: *storage.Store, md5: []const u8, set_id: i32, err: anyerror) void {
        _ = self.failures.fetchAdd(1, .monotonic);
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        store.recordHydrationFailure(md5, set_id, @errorName(err), now) catch |store_err|
            std.log.err("[hydrate] could not save failure state md5={s}: {t}", .{ md5, store_err });
    }

    fn downloadArchive(self: *Sync, store: *storage.Store, wanted_md5: []const u8, set_id: i32, remote: RemoteMap) !void {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        std.log.info("[hydrate] downloading archive set={d}", .{set_id});
        const archive = self.fetchArchive(&client, set_id) catch |err| {
            std.log.warn("[hydrate] archive fetch failed: {t}", .{err});
            return err;
        };
        defer self.allocator.free(archive);
        std.log.info("[hydrate] downloaded {d:.1} MB", .{@as(f64, @floatFromInt(archive.len)) / 1048576.0});

        const osu_file = extractMatchingOsu(self.allocator, archive, wanted_md5) catch |err| {
            std.log.warn("[hydrate] extraction failed: {t}", .{err});
            return err;
        };
        if (osu_file == null) return error.Md5NotInArchive;
        defer self.allocator.free(osu_file.?);

        const metadata = beatmap.parseWithIds(osu_file.?, remote.beatmap_id, set_id) catch |err| {
            std.log.warn("[hydrate] .osu parse failed: {t}", .{err});
            return err;
        };
        if (metadata.id != remote.beatmap_id or metadata.set_id != set_id) return error.IdMismatch;
        const attributes = pp.calculate(osu_file.?, .{
            .mode = metadata.mode,
            .lazer = 0,
            .mods = 0,
            .max_combo = metadata.object_count,
            .n_geki = if (metadata.mode == 3) metadata.object_count else 0,
            .n_katu = 0,
            .n300 = metadata.object_count,
            .n100 = 0,
            .n50 = 0,
            .misses = 0,
            .legacy_total_score = 1_000_000,
        }) catch |err| {
            std.log.warn("[hydrate] PP calc failed: {t}", .{err});
            return err;
        };
        std.log.info("[hydrate] complete — {s} [{s}] stars={d:.2} max_combo={d}", .{ metadata.artist, metadata.version, attributes.stars, attributes.max_combo });
        try store.upsertBeatmap(metadata, wanted_md5, localStatus(remote.approved), attributes.stars, attributes.max_combo, osu_file.?);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
        var encoded: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&encoded, "{x}", .{digest}) catch unreachable;
        try store.upsertBeatmapArchive(set_id, &encoded, archive);
        const pruned = try store.pruneBeatmapArchives(self.cache_max_bytes);
        if (pruned.entries > 0) {
            _ = self.pruned_entries.fetchAdd(@intCast(pruned.entries), .monotonic);
            _ = self.pruned_bytes.fetchAdd(@intCast(pruned.bytes), .monotonic);
            std.log.info("event=beatmap_cache_pruned entries={d} bytes={d}", .{ pruned.entries, pruned.bytes });
        }
    }
};

fn hydrationClaimAllocationRun(allocator: std.mem.Allocator) !void {
    var sync = Sync.init(allocator, std.testing.io, 1);
    defer sync.deinit();
    const result = try sync.claim("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    switch (result) {
        .claimed => |md5| sync.removeFromProgress(md5),
        else => return error.UnexpectedClaimResult,
    }
}

test "beatmap hydration bounds distinct work and deduplicates maps" {
    const hashes = [_][]const u8{
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "cccccccccccccccccccccccccccccccc",
        "dddddddddddddddddddddddddddddddd",
        "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    };
    var sync = Sync.init(std.testing.allocator, std.testing.io, 1);
    defer sync.deinit();
    var held: [max_concurrent_hydrations][]const u8 = undefined;
    for (hashes[0..max_concurrent_hydrations], 0..) |hash, index| {
        held[index] = switch (try sync.claim(hash)) {
            .claimed => |md5| md5,
            else => return error.UnexpectedClaimResult,
        };
    }

    try std.testing.expect(switch (try sync.claim(hashes[0])) {
        .duplicate => true,
        else => false,
    });
    try std.testing.expect(switch (try sync.claim(hashes[4])) {
        .at_capacity => true,
        else => false,
    });
    try std.testing.expectEqual(@as(u64, 1), sync.metrics().capacity_skips);

    sync.removeFromProgress(held[0]);
    held[0] = switch (try sync.claim(hashes[4])) {
        .claimed => |md5| md5,
        else => return error.UnexpectedClaimResult,
    };
    for (held) |md5| sync.removeFromProgress(md5);
}

test "beatmap hydration claims clean every induced allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, hydrationClaimAllocationRun, .{});
}

pub fn needsHydration(store: *storage.Store, wanted_md5: []const u8) !bool {
    return !try store.beatmapHasFile(wanted_md5);
}

fn fetchFn(client: *std.http.Client, allocator: std.mem.Allocator, url: []const u8, limit: usize) ![]u8 {
    const buffer = try allocator.alloc(u8, limit);
    errdefer allocator.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer,
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
            .user_agent = .{ .override = "zigcho/0.1 (+https://github.com/raya-ac/zigcho)" },
        },
    }) catch return error.UpstreamUnavailable;
    if (result.status != .ok) return error.UpstreamUnavailable;
    return try allocator.realloc(buffer, writer.end);
}

pub fn localStatus(upstream: i32) i8 {
    return switch (upstream) {
        1 => 3,
        2 => 4,
        3 => 5,
        4 => 6,
        -2 => 2,
        else => 2,
    };
}

fn validMd5(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |char| if (!std.ascii.isHex(char)) return false;
    return true;
}

fn range(bytes: []const u8, start: usize, len: usize) ![]const u8 {
    const end = std.math.add(usize, start, len) catch return error.InvalidBeatmapArchive;
    if (end > bytes.len) return error.InvalidBeatmapArchive;
    return bytes[start..end];
}

fn unzipEntry(allocator: std.mem.Allocator, archive: []const u8, central: []const u8) ![]u8 {
    const method = std.mem.readInt(u16, central[10..12], .little);
    const crc = std.mem.readInt(u32, central[16..20], .little);
    const compressed_len: usize = std.mem.readInt(u32, central[20..24], .little);
    const output_len: usize = std.mem.readInt(u32, central[24..28], .little);
    const local_offset: usize = std.mem.readInt(u32, central[42..46], .little);
    if (output_len == 0 or output_len > map_limit or compressed_len > archive_limit) return error.InvalidBeatmapArchive;
    const local = try range(archive, local_offset, 30);
    if (!std.mem.eql(u8, local[0..4], &std.zip.local_file_header_sig)) return error.InvalidBeatmapArchive;
    if (std.mem.readInt(u16, local[8..10], .little) != method) return error.InvalidBeatmapArchive;
    const name_len: usize = std.mem.readInt(u16, local[26..28], .little);
    const extra_len: usize = std.mem.readInt(u16, local[28..30], .little);
    const local_header_end = std.math.add(usize, local_offset, 30) catch return error.InvalidBeatmapArchive;
    const local_variable_len = std.math.add(usize, name_len, extra_len) catch return error.InvalidBeatmapArchive;
    const data_offset = std.math.add(usize, local_header_end, local_variable_len) catch return error.InvalidBeatmapArchive;
    const compressed = try range(archive, data_offset, compressed_len);
    const output = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output);
    switch (method) {
        0 => {
            if (compressed.len != output.len) return error.InvalidBeatmapArchive;
            @memcpy(output, compressed);
        },
        8 => {
            var input = std.Io.Reader.fixed(compressed);
            var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var decompress: std.compress.flate.Decompress = .init(&input, .raw, &flate_buffer);
            decompress.reader.readSliceAll(output) catch return error.InvalidBeatmapArchive;
        },
        else => return error.UnsupportedCompressionMethod,
    }
    if (std.hash.Crc32.hash(output) != crc) return error.InvalidBeatmapArchive;
    return output;
}

pub fn extractMatchingOsu(allocator: std.mem.Allocator, archive: []const u8, wanted_md5: []const u8) !?[]u8 {
    if (!validMd5(wanted_md5)) return null;
    const end_offset = std.mem.lastIndexOf(u8, archive, &std.zip.end_record_sig) orelse return error.InvalidBeatmapArchive;
    const end = try range(archive, end_offset, 22);
    const entry_count: usize = std.mem.readInt(u16, end[10..12], .little);
    const central_size: usize = std.mem.readInt(u32, end[12..16], .little);
    const central_offset: usize = std.mem.readInt(u32, end[16..20], .little);
    const comment_len: usize = std.mem.readInt(u16, end[20..22], .little);
    if (entry_count == 0 or entry_count > entry_limit or end_offset + 22 + comment_len != archive.len) return error.InvalidBeatmapArchive;
    _ = try range(archive, central_offset, central_size);
    const central_end = std.math.add(usize, central_offset, central_size) catch return error.InvalidBeatmapArchive;

    var offset = central_offset;
    for (0..entry_count) |_| {
        const central = try range(archive, offset, 46);
        if (!std.mem.eql(u8, central[0..4], &std.zip.central_file_header_sig)) return error.InvalidBeatmapArchive;
        const name_len: usize = std.mem.readInt(u16, central[28..30], .little);
        const extra_len: usize = std.mem.readInt(u16, central[30..32], .little);
        const comment_entry_len: usize = std.mem.readInt(u16, central[32..34], .little);
        const filename = try range(archive, offset + 46, name_len);
        const record_len = std.math.add(usize, 46 + name_len, extra_len + comment_entry_len) catch return error.InvalidBeatmapArchive;
        offset = std.math.add(usize, offset, record_len) catch return error.InvalidBeatmapArchive;
        if (std.ascii.endsWithIgnoreCase(filename, ".osu")) {
            const contents = try unzipEntry(allocator, archive, central);
            const digest = beatmap.md5(contents);
            if (std.ascii.eqlIgnoreCase(&digest, wanted_md5)) return contents;
            allocator.free(contents);
        }
    }
    if (offset != central_end) return error.InvalidBeatmapArchive;
    return null;
}
