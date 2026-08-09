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
    client: std.http.Client,
    mutex: std.Io.Mutex = .init,
    api_key: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8) Sync {
        return .{
            .allocator = allocator,
            .io = io,
            .client = .{ .allocator = allocator, .io = io },
            .api_key = api_key,
        };
    }

    pub fn deinit(self: *Sync) void {
        self.client.deinit();
    }

    pub fn ensure(self: *Sync, store: *storage.Store, wanted_md5: []const u8, expected_set_id: ?i32) !bool {
        if (!validMd5(wanted_md5)) {
            std.log.warn("{s}═══ HYDRATE ABORTED ═══{s} invalid md5: {s}", .{ c_red ++ c_bold, c_reset, wanted_md5 });
            return false;
        }
        if (try store.beatmapForScore(wanted_md5) != null) return true;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (try store.beatmapForScore(wanted_md5) != null) return true;
        const set_id = expected_set_id orelse {
            std.log.warn("{s}═══ HYDRATE ABORTED ═══{s} no set_id for {s}", .{ c_red ++ c_bold, c_reset, wanted_md5 });
            return false;
        };
        if (set_id <= 0) {
            std.log.warn("{s}═══ HYDRATE ABORTED ═══{s} bad set_id {d}", .{ c_red ++ c_bold, c_reset, set_id });
            return false;
        }

        std.log.info("{s}{s}╔══════════════════════════════════════════════════╗{s}", .{ c_magenta ++ c_bold, "", c_reset });
        std.log.info("{s}{s}║         HYDRATION SEQUENCE INITIATED            ║{s}", .{ c_magenta ++ c_bold, "", c_reset });
        std.log.info("{s}{s}╚══════════════════════════════════════════════════╝{s}", .{ c_magenta ++ c_bold, "", c_reset });
        std.log.info("{s}  ► target md5 :{s} {s}", .{ c_dim, c_reset, wanted_md5 });
        std.log.info("{s}  ► set_id     :{s} {d}", .{ c_dim, c_reset, set_id });

        const metadata_url = try std.fmt.allocPrint(self.allocator, "https://osu.ppy.sh/api/get_beatmaps?s={d}&k={s}", .{ set_id, self.api_key });
        defer self.allocator.free(metadata_url);
        std.log.info("{s}  ┌─ [1/4] METADATA FETCH ─────────────────────────{s}", .{ c_cyan, c_reset });
        std.log.info("{s}  │  → {s}{s}", .{ c_dim, c_reset, metadata_url });
        const metadata_json = self.fetch(metadata_url, metadata_limit) catch |err| {
            std.log.warn("{s}  │  ✗ FAILED: {t}{s}", .{ c_red, err, c_reset });
            std.log.warn("{s}  └──────────────────────────────────────────────{s}", .{ c_red, c_reset });
            return false;
        };
        defer self.allocator.free(metadata_json);
        std.log.info("{s}  │  ✓ received {d} bytes{s}", .{ c_green, metadata_json.len, c_reset });
        const parsed = std.json.parseFromSlice([]OsuV1Map, self.allocator, metadata_json, .{ .ignore_unknown_fields = true }) catch |err| {
            std.log.warn("{s}  │  ✗ parse failed: {t}{s}", .{ c_red, err, c_reset });
            std.log.warn("{s}  └──────────────────────────────────────────────{s}", .{ c_red, c_reset });
            return false;
        };
        defer parsed.deinit();
        if (parsed.value.len == 0) {
            std.log.warn("{s}  │  ✗ set {d} returned 0 diffs{s}", .{ c_red, set_id, c_reset });
            std.log.warn("{s}  └──────────────────────────────────────────────{s}", .{ c_red, c_reset });
            return false;
        }
        std.log.info("{s}  │  ✓ {d} diffs in set{s}", .{ c_green, parsed.value.len, c_reset });
        var remote: ?OsuV1Map = null;
        for (parsed.value) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate.file_md5, wanted_md5)) {
                remote = candidate;
                break;
            }
        }
        const map_info = remote orelse {
            std.log.warn("{s}  │  ✗ md5 not found in any diff{s}", .{ c_red, c_reset });
            std.log.warn("{s}  └──────────────────────────────────────────────{s}", .{ c_red, c_reset });
            return false;
        };
        const map_id = map_info.beatmap_id;
        if (map_id <= 0 or map_info.beatmapset_id != set_id) {
            std.log.warn("{s}  │  ✗ id sanity fail: id={d} set={d} expected={d}{s}", .{ c_red, map_id, map_info.beatmapset_id, set_id, c_reset });
            std.log.warn("{s}  └──────────────────────────────────────────────{s}", .{ c_red, c_reset });
            return false;
        }
        std.log.info("{s}  │  ✓ map_id={d} approved={d}{s}", .{ c_green, map_id, map_info.approved, c_reset });
        std.log.info("{s}  └──────────────────────────────────────────────{s}", .{ c_cyan, c_reset });

        const archive_url = try std.fmt.allocPrint(self.allocator, "https://mirror.hinamizawa.ai/d/{d}", .{set_id});
        defer self.allocator.free(archive_url);
        std.log.info("{s}  ┌─ [2/4] ARCHIVE DOWNLOAD ──────────────────────{s}", .{ c_cyan, c_reset });
        std.log.info("{s}  │  → {s}{s}", .{ c_dim, c_reset, archive_url });
        const archive = self.fetch(archive_url, archive_limit) catch |err| {
            std.log.warn("{s}  │  ✗ fetch failed: {t}{s}", .{ c_red, err, c_reset });
            std.log.warn("{s}  └──────────────────────────────────────────────{s}", .{ c_red, c_reset });
            return false;
        };
        defer self.allocator.free(archive);
        std.log.info("{s}  │  ✓ {d} bytes ({d:.1} MB){s}", .{ c_green, archive.len, @as(f64, @floatFromInt(archive.len)) / 1048576.0, c_reset });
        std.log.info("{s}  └──────────────────────────────────────────────{s}", .{ c_cyan, c_reset });

        std.log.info("{s}  ┌─ [3/4] EXTRACTION & PARSE ────────────────────{s}", .{ c_cyan, c_reset });
        std.log.info("{s}  │  searching archive for md5 match...{s}", .{ c_dim, c_reset });
        const osu_file = extractMatchingOsu(self.allocator, archive, wanted_md5) catch |err| {
            std.log.warn("{s}  │  ✗ extraction failed: {t}{s}", .{ c_red, err, c_reset });
            std.log.warn("{s}  └──────────────────────────────────────────────{s}", .{ c_red, c_reset });
            return false;
        };
        if (osu_file == null) {
            std.log.warn("{s}  │  ✗ md5 not found in archive contents{s}", .{ c_red, c_reset });
            std.log.warn("{s}  └──────────────────────────────────────────────{s}", .{ c_red, c_reset });
            return false;
        }
        defer self.allocator.free(osu_file.?);
        std.log.info("{s}  │  ✓ extracted {d} bytes .osu{s}", .{ c_green, osu_file.?.len, c_reset });

        const metadata = beatmap.parse(osu_file.?) catch |err| {
            std.log.warn("{s}  │  ✗ .osu parse failed: {t}{s}", .{ c_red, err, c_reset });
            std.log.warn("{s}  └──────────────────────────────────────────────{s}", .{ c_red, c_reset });
            return false;
        };
        if (metadata.id != map_id or metadata.set_id != set_id) {
            std.log.warn("{s}  │  ✗ mismatch: parsed id={d} set={d} vs api id={d} set={d}{s}", .{ c_red, metadata.id, metadata.set_id, map_id, set_id, c_reset });
            std.log.warn("{s}  └──────────────────────────────────────────────{s}", .{ c_red, c_reset });
            return false;
        }
        std.log.info("{s}  │  ✓ {s}{s}{s} [{s}{s}{s}]{s}", .{ c_green, c_bold, metadata.artist, c_reset, c_yellow, metadata.version, c_reset, c_reset });
        std.log.info("{s}  │    mode={d} circles={d} sliders={d} spinners={d}{s}", .{ c_dim, metadata.mode, metadata.count_circles, metadata.count_sliders, metadata.count_spinners, c_reset });
        std.log.info("{s}  └──────────────────────────────────────────────{s}", .{ c_cyan, c_reset });

        std.log.info("{s}  ┌─ [4/4] PP CALCULATION ────────────────────────{s}", .{ c_cyan, c_reset });
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
            std.log.warn("{s}  └──────────────────────────────────────────────{s}", .{ c_red, c_reset });
            return false;
        };
        std.log.info("{s}  │  ✓ stars={d:.2} max_combo={d}{s}", .{ c_green, attributes.stars, attributes.max_combo, c_reset });
        try store.upsertBeatmap(metadata, wanted_md5, localStatus(map_info.approved), attributes.stars, attributes.max_combo, osu_file.?);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
        var encoded: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&encoded, "{x}", .{digest}) catch unreachable;
        try store.upsertBeatmapArchive(set_id, &encoded, archive);
        std.log.info("{s}  └──────────────────────────────────────────────{s}", .{ c_cyan, c_reset });
        std.log.info("{s}{s}╔══════════════════════════════════════════════════╗{s}", .{ c_green ++ c_bold, "", c_reset });
        std.log.info("{s}{s}║             HYDRATION COMPLETE                  ║{s}", .{ c_green ++ c_bold, "", c_reset });
        std.log.info("{s}{s}╚══════════════════════════════════════════════════╝{s}", .{ c_green ++ c_bold, "", c_reset });
        std.log.info("{s}  ► {s}{s}{s} [{s}{s}{s}] — map {d}, set {d}{s}", .{ c_bold, c_green, metadata.artist, c_reset, c_yellow, metadata.version, c_reset, map_id, set_id, c_reset });
        return true;
    }

    fn fetch(self: *Sync, url: []const u8, limit: usize) ![]u8 {
        const buffer = try self.allocator.alloc(u8, limit);
        errdefer self.allocator.free(buffer);
        var writer = std.Io.Writer.fixed(buffer);
        const result = self.client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &writer,
            .headers = .{
                .accept_encoding = .{ .override = "identity" },
                .user_agent = .{ .override = "zigcho/0.1 (+https://github.com/raya-ac/zigcho)" },
            },
        }) catch return error.UpstreamUnavailable;
        if (result.status != .ok) return error.UpstreamUnavailable;
        return try self.allocator.realloc(buffer, writer.end);
    }
};

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
