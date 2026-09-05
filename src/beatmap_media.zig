const std = @import("std");
const telemetry = @import("telemetry.zig");
const contract = @import("media_contract.zig");
const storage = @import("runtime_storage.zig");
const bss = @import("bss.zig");

pub const Sync = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_max_bytes: u64,
    fetch_slots: std.Io.Semaphore = .{ .permits = 4 },
    attempts: std.atomic.Value(u64) = .init(0),
    successes: std.atomic.Value(u64) = .init(0),
    failures: std.atomic.Value(u64) = .init(0),
    pruned_entries: std.atomic.Value(u64) = .init(0),
    pruned_bytes: std.atomic.Value(u64) = .init(0),

    pub const Metrics = struct {
        attempts: u64,
        successes: u64,
        failures: u64,
        pruned_entries: u64,
        pruned_bytes: u64,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cache_max_bytes: u64) Sync {
        return .{ .allocator = allocator, .io = io, .cache_max_bytes = cache_max_bytes };
    }

    pub fn metrics(self: *const Sync) Metrics {
        return .{
            .attempts = self.attempts.load(.monotonic),
            .successes = self.successes.load(.monotonic),
            .failures = self.failures.load(.monotonic),
            .pruned_entries = self.pruned_entries.load(.monotonic),
            .pruned_bytes = self.pruned_bytes.load(.monotonic),
        };
    }

    pub fn get(self: *Sync, store: *storage.Store, request: contract.Request) !?contract.Asset {
        if (!try store.beatmapSetExists(request.set_id)) return null;
        if (try store.beatmapMedia(self.allocator, request.set_id, request.kind)) |asset| return asset;
        if (request.set_id >= bss.legacy_private_id_floor and request.kind != .cover and request.kind != .preview) {
            if (try store.beatmapMedia(self.allocator, request.set_id, .cover)) |asset| return asset;
        }

        const pending = telemetry.work.enter(.media_slots);
        self.fetch_slots.waitUncancelable(self.io);
        pending.leave();
        defer self.fetch_slots.post(self.io);

        // Another request may have filled the same cache entry while this one
        // waited for one of the four upstream slots.
        if (try store.beatmapMedia(self.allocator, request.set_id, request.kind)) |asset| return asset;
        if (request.set_id >= bss.legacy_private_id_floor and request.kind != .cover and request.kind != .preview) {
            if (try store.beatmapMedia(self.allocator, request.set_id, .cover)) |asset| return asset;
        }
        if (request.set_id >= bss.legacy_private_id_floor) {
            try self.hydrateLocalArchive(store, request.set_id);
            if (try store.beatmapMedia(self.allocator, request.set_id, request.kind)) |asset| return asset;
            if (request.kind != .cover and request.kind != .preview) {
                if (try store.beatmapMedia(self.allocator, request.set_id, .cover)) |asset| return asset;
            }
            return null;
        }

        _ = self.attempts.fetchAdd(1, .monotonic);
        const fetched = self.fetch(request) catch |err| {
            _ = self.failures.fetchAdd(1, .monotonic);
            return err;
        };
        var asset = fetched orelse {
            _ = self.failures.fetchAdd(1, .monotonic);
            return null;
        };
        errdefer asset.deinit(self.allocator);

        try store.putBeatmapMedia(request.set_id, request.kind, asset.content_type, asset.data);
        const pruned = try store.pruneBeatmapMedia(self.cache_max_bytes);
        if (pruned.entries > 0) {
            _ = self.pruned_entries.fetchAdd(@intCast(pruned.entries), .monotonic);
            _ = self.pruned_bytes.fetchAdd(@intCast(pruned.bytes), .monotonic);
            std.log.info("event=beatmap_media_cache_pruned entries={d} bytes={d}", .{ pruned.entries, pruned.bytes });
        }
        _ = self.successes.fetchAdd(1, .monotonic);
        std.log.info("event=beatmap_media_cached set_id={d} kind={s} bytes={d}", .{ request.set_id, request.kind.dbName(), asset.data.len });
        return asset;
    }

    fn hydrateLocalArchive(self: *Sync, store: *storage.Store, set_id: i32) !void {
        const bytes = (try store.beatmapArchive(self.allocator, set_id)) orelse return;
        defer self.allocator.free(bytes);
        var archive = try bss.parseArchive(self.allocator, bytes);
        defer archive.deinit();
        const media = bss.mediaFromArchive(&archive);
        try storeLocalMedia(store, set_id, media);
        std.log.info("event=bss_media_hydrated set_id={d} cover={s} preview={s}", .{ set_id, if (media.cover != null) "uploaded" else "default", if (media.preview != null) "true" else "false" });
    }

    fn fetch(self: *Sync, request: contract.Request) !?contract.Asset {
        const url = try request.kind.upstreamUrl(self.allocator, request.set_id);
        defer self.allocator.free(url);

        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        const buffer = try self.allocator.alloc(u8, request.kind.maxBytes());
        errdefer self.allocator.free(buffer);
        var writer = std.Io.Writer.fixed(buffer);
        const result = client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &writer,
            .headers = .{
                .accept_encoding = .{ .override = "identity" },
                .user_agent = .{ .override = "zigcho/0.1 (+https://github.com/zigcho/zigcho)" },
            },
        }) catch |err| switch (err) {
            error.WriteFailed => return error.UpstreamMediaTooLarge,
            else => return error.UpstreamUnavailable,
        };
        if (result.status == .not_found) {
            self.allocator.free(buffer);
            return null;
        }
        if (result.status != .ok) return error.UpstreamUnavailable;
        const content_type = contract.detect(request.kind, buffer[0..writer.end]) orelse return error.InvalidUpstreamMedia;
        return .{
            .data = try self.allocator.realloc(buffer, writer.end),
            .content_type = content_type,
        };
    }
};

pub fn storeLocalMedia(store: *storage.Store, set_id: i32, media: bss.PreparedMedia) !void {
    const cover = media.cover orelse bss.PreparedMediaAsset{ .data = contract.local_cover_fallback, .content_type = .png };
    try store.putBeatmapMedia(set_id, .cover, cover.content_type, cover.data);
    if (media.preview) |asset| try store.putBeatmapMedia(set_id, .preview, asset.content_type, asset.data);
}

test "private BSS media hydrates from its stored archive without upstream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/bss-media.db", .{tmp.sub_path});
    var store = try storage.Store.open(std.testing.allocator, std.testing.io, path);
    defer store.close();
    try store.migrate();

    const source_map = @embedFile("testdata/synthetic-standard.osu");
    const set_text = try std.fmt.allocPrint(std.testing.allocator, "BeatmapSetID:{d}", .{bss.private_id_floor});
    defer std.testing.allocator.free(set_text);
    const map = try std.mem.replaceOwned(u8, std.testing.allocator, source_map, "BeatmapSetID:900000000", set_text);
    defer std.testing.allocator.free(map);
    const metadata = try @import("beatmap.zig").parse(map);
    const md5 = @import("beatmap.zig").md5(map);
    try store.upsertBeatmap(metadata, &md5, 2, 0, metadata.object_count, map);

    const preview = "ID3local preview";
    var source: bss.Archive = .{ .allocator = std.testing.allocator };
    defer source.deinit();
    for ([_][]const u8{ "map.osu", "synthetic.mp3" }, [_][]const u8{ map, preview }) |name, data| {
        try source.entries.append(std.testing.allocator, .{
            .allocator = std.testing.allocator,
            .name = try std.testing.allocator.dupe(u8, name),
            .data = try std.testing.allocator.dupe(u8, data),
        });
    }
    const archive = try bss.buildArchive(std.testing.allocator, &source);
    defer std.testing.allocator.free(archive);
    const digest = bss.archiveSha256(archive);
    try store.upsertBeatmapArchive(metadata.set_id, &digest, archive);

    var sync = Sync.init(std.testing.allocator, std.testing.io, 64 * 1024 * 1024);
    var cover = (try sync.get(&store, .{ .set_id = metadata.set_id, .kind = .list })).?;
    defer cover.deinit(std.testing.allocator);
    try std.testing.expectEqual(contract.ContentType.png, cover.content_type);
    try std.testing.expectEqualSlices(u8, contract.local_cover_fallback, cover.data);
    var audio = (try sync.get(&store, .{ .set_id = metadata.set_id, .kind = .preview })).?;
    defer audio.deinit(std.testing.allocator);
    try std.testing.expectEqual(contract.ContentType.mp3, audio.content_type);
    try std.testing.expectEqualSlices(u8, preview, audio.data);
    try std.testing.expectEqual(@as(u64, 0), sync.metrics().attempts);
}
