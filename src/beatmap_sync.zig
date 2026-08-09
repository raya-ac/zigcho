const std = @import("std");
const beatmap = @import("beatmap.zig");
const pp = @import("pp.zig");
const storage = @import("storage.zig");

const metadata_limit = 256 * 1024;
const archive_limit = 128 * 1024 * 1024;
const map_limit = 16 * 1024 * 1024;
const entry_limit = 4096;

const OsuV1Map = struct {
    beatmap_id: i32,
    beatmapset_id: i32,
    approved: i32,
    file_md5: []const u8,
    artist: []const u8 = "",
    title: []const u8 = "",
    version: []const u8 = "",
    creator: []const u8 = "",
    source: []const u8 = "",
    tags: []const u8 = "",
    difficultyrating: f64 = 0,
    diff_size: f64 = 0,
    diff_approach: f64 = 0,
    diff_overall: f64 = 0,
    diff_drain: f64 = 0,
    mode: u8 = 0,
    bpm: f64 = 0,
    total_length: i32 = 0,
    count_normal: u32 = 0,
    count_slider: u32 = 0,
    count_spinner: u32 = 0,
    max_combo: u32 = 0,
};

const c_reset = "\x1b[0m";
const c_cyan = "\x1b[36m";
const c_green = "\x1b[32m";
const c_red = "\x1b[31m";
const c_yellow = "\x1b[33m";
const c_magenta = "\x1b[35m";
const c_bold = "\x1b[1m";
const c_dim = "\x1b[2m";

pub const Sync = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    api_key: []const u8 = "",
    in_progress: std.StringHashMap(void),
    in_progress_mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8) Sync {
        return .{
            .allocator = allocator,
            .io = io,
            .api_key = api_key,
            .in_progress = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Sync) void {
        self.in_progress.deinit();
    }

    pub fn ensure(self: *Sync, store: *storage.Store, wanted_md5: []const u8, expected_set_id: ?i32) !bool {
        if (!validMd5(wanted_md5)) return false;
        if (try store.beatmapForScore(wanted_md5) != null) return true;

        self.in_progress_mutex.lockUncancelable(self.io);
        if (self.in_progress.contains(wanted_md5)) {
            self.in_progress_mutex.unlock(self.io);
            return false;
        }
        const md5_owned = self.allocator.dupe(u8, wanted_md5) catch {
            self.in_progress_mutex.unlock(self.io);
            return false;
        };
        self.in_progress.put(md5_owned, {}) catch {
            self.allocator.free(md5_owned);
            self.in_progress_mutex.unlock(self.io);
            return false;
        };
        self.in_progress_mutex.unlock(self.io);

        const set_id = expected_set_id orelse {
            self.removeFromProgress(md5_owned);
            return false;
        };
        if (set_id <= 0) {
            self.removeFromProgress(md5_owned);
            return false;
        }

        const approved = self.fetchAndStoreMetadata(store, md5_owned, set_id) catch |err| {
            std.log.warn("metadata fetch failed for {s}: {t}", .{ md5_owned, err });
            self.removeFromProgress(md5_owned);
            return false;
        };

        const thread = std.Thread.spawn(.{}, backgroundDownload, .{ self, store, md5_owned, set_id, approved }) catch {
            self.removeFromProgress(md5_owned);
            return false;
        };
        thread.detach();
        return false;
    }

    fn fetchAndStoreMetadata(self: *Sync, store: *storage.Store, wanted_md5: []const u8, set_id: i32) !i32 {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        std.debug.print("{s}{s}╔══════════════════════════════════════════════════╗{s}\n", .{ c_magenta ++ c_bold, "", c_reset });
        std.debug.print("{s}{s}║         HYDRATION SEQUENCE INITIATED            ║{s}\n", .{ c_magenta ++ c_bold, "", c_reset });
        std.debug.print("{s}{s}╚══════════════════════════════════════════════════╝{s}\n", .{ c_magenta ++ c_bold, "", c_reset });
        std.debug.print("{s}  ► target md5 :{s} {s}\n", .{ c_dim, c_reset, wanted_md5 });
        std.debug.print("{s}  ► set_id     :{s} {d}\n", .{ c_dim, c_reset, set_id });

        const metadata_url = try std.fmt.allocPrint(self.allocator, "https://osu.ppy.sh/api/get_beatmaps?s={d}&k={s}", .{ set_id, self.api_key });
        defer self.allocator.free(metadata_url);
        std.debug.print("{s}  ┌─ [1/2] METADATA FETCH ───────────────────────{s}\n", .{ c_cyan, c_reset });
        const metadata_json = fetchFn(&client, self.allocator, metadata_url, metadata_limit) catch |err| {
            std.log.warn("{s}  │  ✗ FAILED: {t}{s}", .{ c_red, err, c_reset });
            return err;
        };
        defer self.allocator.free(metadata_json);
        const parsed = std.json.parseFromSlice([]OsuV1Map, self.allocator, metadata_json, .{ .ignore_unknown_fields = true }) catch |err| {
            std.log.warn("{s}  │  ✗ parse failed: {t}{s}", .{ c_red, err, c_reset });
            return err;
        };
        defer parsed.deinit();
        if (parsed.value.len == 0) return error.EmptySet;
        var remote: ?OsuV1Map = null;
        for (parsed.value) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate.file_md5, wanted_md5)) {
                remote = candidate;
                break;
            }
        }
        const map_info = remote orelse return error.Md5NotFound;
        if (map_info.beatmap_id <= 0 or map_info.beatmapset_id != set_id) return error.IdMismatch;

        const meta = beatmap.Metadata{
            .id = map_info.beatmap_id,
            .set_id = map_info.beatmapset_id,
            .mode = map_info.mode,
            .artist = map_info.artist,
            .title = map_info.title,
            .version = map_info.version,
            .creator = map_info.creator,
            .source = map_info.source,
            .tags = map_info.tags,
            .hp = map_info.diff_drain,
            .cs = map_info.diff_size,
            .od = map_info.diff_overall,
            .ar = map_info.diff_approach,
            .bpm = map_info.bpm,
            .total_length = map_info.total_length,
            .count_circles = map_info.count_normal,
            .count_sliders = map_info.count_slider,
            .count_spinners = map_info.count_spinner,
            .object_count = map_info.count_normal + map_info.count_slider + map_info.count_spinner,
        };
        try store.upsertBeatmapMeta(meta, wanted_md5, localStatus(map_info.approved), map_info.difficultyrating, map_info.max_combo);
        std.debug.print("{s}  │  ✓ {s}{s}{s} [{s}{s}{s}] — stars={d:.2}{s}\n", .{ c_green, c_bold, meta.artist, c_reset, c_yellow, meta.version, c_reset, map_info.difficultyrating, c_reset });
        std.debug.print("{s}  │  ✓ metadata stored, spawning background download{s}\n", .{ c_green, c_reset });
        std.debug.print("{s}  └──────────────────────────────────────────────{s}\n", .{ c_cyan, c_reset });
        return map_info.approved;
    }

    fn removeFromProgress(self: *Sync, md5: []const u8) void {
        self.in_progress_mutex.lockUncancelable(self.io);
        _ = self.in_progress.remove(md5);
        self.in_progress_mutex.unlock(self.io);
        self.allocator.free(md5);
    }

    fn backgroundDownload(self: *Sync, store: *storage.Store, md5_owned: []const u8, set_id: i32, approved: i32) void {
        defer self.removeFromProgress(md5_owned);
        self.downloadArchive(store, md5_owned, set_id, approved) catch |err| {
            std.log.warn("{s}═══ ARCHIVE DOWNLOAD FAILED ═══{s} {s}: {t}", .{ c_red ++ c_bold, c_reset, md5_owned, err });
        };
    }

    fn downloadArchive(self: *Sync, store: *storage.Store, wanted_md5: []const u8, set_id: i32, approved: i32) !void {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const mirror_json_url = try std.fmt.allocPrint(self.allocator, "https://mirror.hinamizawa.ai/d/{d}", .{set_id});
        defer self.allocator.free(mirror_json_url);
        std.debug.print("{s}  ┌─ [2/2] ARCHIVE DOWNLOAD ──────────────────────{s}\n", .{ c_cyan, c_reset });
        std.debug.print("{s}  │  → {s}{s}\n", .{ c_dim, c_reset, mirror_json_url });
        const mirror_json = fetchFn(&client, self.allocator, mirror_json_url, 4096) catch |err| {
            std.log.warn("{s}  │  ✗ mirror fetch failed: {t}{s}", .{ c_red, err, c_reset });
            return err;
        };
        defer self.allocator.free(mirror_json);
        const mirror_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, mirror_json, .{}) catch return error.InvalidMirrorJson;
        defer mirror_parsed.deinit();
        const download_url = mirror_parsed.value.object.get("download_url") orelse return error.NoDownloadUrl;
        const url_str = switch (download_url) {
            .string => |s| s,
            else => return error.DownloadUrlNotString,
        };
        const fetch_url = try std.fmt.allocPrint(self.allocator, "{s}?noVideo=true", .{url_str});
        defer self.allocator.free(fetch_url);
        std.debug.print("{s}  │  ✓ redirect → {s}{s}\n", .{ c_green, c_reset, fetch_url });
        const archive = fetchFn(&client, self.allocator, fetch_url, archive_limit) catch |err| {
            std.log.warn("{s}  │  ✗ archive fetch failed: {t}{s}", .{ c_red, err, c_reset });
            return err;
        };
        defer self.allocator.free(archive);
        std.debug.print("{s}  │  ✓ {d} bytes ({d:.1} MB){s}\n", .{ c_green, archive.len, @as(f64, @floatFromInt(archive.len)) / 1048576.0, c_reset });

        std.debug.print("{s}  │  extracting .osu for {s}...{s}\n", .{ c_dim, wanted_md5, c_reset });
        const osu_file = extractMatchingOsu(self.allocator, archive, wanted_md5) catch |err| {
            std.log.warn("{s}  │  ✗ extraction failed: {t}{s}", .{ c_red, err, c_reset });
            return err;
        };
        if (osu_file == null) return error.Md5NotInArchive;
        defer self.allocator.free(osu_file.?);

        const metadata = beatmap.parse(osu_file.?) catch |err| {
            std.log.warn("{s}  │  ✗ .osu parse failed: {t}{s}", .{ c_red, err, c_reset });
            return err;
        };
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
            std.log.warn("{s}  │  ✗ PP calc failed: {t}{s}", .{ c_red, err, c_reset });
            return err;
        };
        std.debug.print("{s}  │  ✓ {s}{s}{s} [{s}{s}{s}] stars={d:.2} max_combo={d}{s}\n", .{ c_green, c_bold, metadata.artist, c_reset, c_yellow, metadata.version, c_reset, attributes.stars, attributes.max_combo, c_reset });
        try store.upsertBeatmap(metadata, wanted_md5, localStatus(approved), attributes.stars, attributes.max_combo, osu_file.?);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
        var encoded: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&encoded, "{x}", .{digest}) catch unreachable;
        try store.upsertBeatmapArchive(set_id, &encoded, archive);
        std.debug.print("{s}  └──────────────────────────────────────────────{s}\n", .{ c_cyan, c_reset });
        std.debug.print("{s}{s}╔══════════════════════════════════════════════════╗{s}\n", .{ c_green ++ c_bold, "", c_reset });
        std.debug.print("{s}{s}║             HYDRATION COMPLETE                  ║{s}\n", .{ c_green ++ c_bold, "", c_reset });
        std.debug.print("{s}{s}╚══════════════════════════════════════════════════╝{s}\n", .{ c_green ++ c_bold, "", c_reset });
    }

};

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
        -2 => 6,
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
