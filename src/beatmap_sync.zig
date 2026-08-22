const std = @import("std");
const beatmap = @import("beatmap.zig");
const pp = @import("exact_pp.zig");
const storage = @import("runtime_storage.zig");

const metadata_limit = 256 * 1024;
const search_limit = 8 * 1024 * 1024;
const archive_limit = 128 * 1024 * 1024;
const map_limit = 16 * 1024 * 1024;
const entry_limit = 4096;
const mapset_map_limit = 256;
pub const max_concurrent_hydrations = 4;

const CheesegullMap = struct {
    ParentSetID: i32,
    BeatmapID: i32,
    TotalLength: i32 = 0,
    DiffName: []const u8,
    FileMD5: []const u8,
    CS: ?f64 = null,
    AR: ?f64 = null,
    HP: ?f64 = null,
    OD: ?f64 = null,
    Mode: u8 = 0,
    BPM: ?f64 = null,
    MaxCombo: ?u32 = null,
    DifficultyRating: ?f64 = null,
};

const CheesegullSet = struct {
    SetID: i32,
    ChildrenBeatmaps: []CheesegullMap,
    RankedStatus: i32,
    Artist: []const u8 = "",
    Title: []const u8 = "",
    Creator: []const u8 = "",
    Source: ?[]const u8 = null,
    Tags: ?[]const u8 = null,
};

const BeatmapIdentity = struct {
    set_id: i32,
    md5: [32]u8,
};

const RemoteMap = struct {
    md5: [32]u8,
    beatmap_id: i32,
};

const RemoteSet = struct {
    allocator: std.mem.Allocator,
    approved: i32,
    requested_beatmap_id: i32,
    maps: []RemoteMap,

    fn deinit(self: RemoteSet) void {
        self.allocator.free(self.maps);
    }
};

pub const ExtractedOsu = struct {
    md5: [32]u8,
    contents: []u8,
};

pub fn freeExtractedOsu(allocator: std.mem.Allocator, files: []ExtractedOsu) void {
    for (files) |file| allocator.free(file.contents);
    allocator.free(files);
}

pub fn findExtractedOsu(files: []const ExtractedOsu, wanted_md5: []const u8) ?ExtractedOsu {
    if (!validMd5(wanted_md5)) return null;
    for (files) |file| if (std.ascii.eqlIgnoreCase(&file.md5, wanted_md5)) return file;
    return null;
}

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
    mirror_hits: std.atomic.Value(u64) = .init(0),
    mirror_misses: std.atomic.Value(u64) = .init(0),
    mirror_fills: std.atomic.Value(u64) = .init(0),
    mirror_failures: std.atomic.Value(u64) = .init(0),
    mirror_bytes_served: std.atomic.Value(u64) = .init(0),

    pub const Metrics = struct {
        attempts: u64,
        successes: u64,
        failures: u64,
        backoff_skips: u64,
        capacity_skips: u64,
        pruned_entries: u64,
        pruned_bytes: u64,
        mirror_hits: u64,
        mirror_misses: u64,
        mirror_fills: u64,
        mirror_failures: u64,
        mirror_bytes_served: u64,
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
            .mirror_hits = self.mirror_hits.load(.monotonic),
            .mirror_misses = self.mirror_misses.load(.monotonic),
            .mirror_fills = self.mirror_fills.load(.monotonic),
            .mirror_failures = self.mirror_failures.load(.monotonic),
            .mirror_bytes_served = self.mirror_bytes_served.load(.monotonic),
        };
    }

    pub const MirrorArchive = struct {
        data: []u8,
        cache_hit: bool,
    };

    /// Serve an already verified archive or fill it through the same full-set
    /// metadata, archive, hash, and object-storage path used by gameplay.
    pub fn mirrorArchive(self: *Sync, store: *storage.Store, set_id: i32) !MirrorArchive {
        return self.resolveMirrorArchive(store, set_id, true);
    }

    pub fn prefetchMirrorArchive(self: *Sync, store: *storage.Store, set_id: i32) !MirrorArchive {
        return self.resolveMirrorArchive(store, set_id, false);
    }

    fn resolveMirrorArchive(self: *Sync, store: *storage.Store, set_id: i32, count_served: bool) !MirrorArchive {
        if (set_id <= 0) return error.InvalidBeatmapSet;
        if (try store.beatmapArchive(self.allocator, set_id)) |archive| {
            if (count_served) {
                _ = self.mirror_hits.fetchAdd(1, .monotonic);
                _ = self.mirror_bytes_served.fetchAdd(@intCast(archive.len), .monotonic);
            }
            return .{ .data = archive, .cache_hit = true };
        }
        if (count_served) _ = self.mirror_misses.fetchAdd(1, .monotonic);

        var key_buffer: [48]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "mirror:{d}", .{set_id});
        const claim_owned = switch (try self.claim(key)) {
            .claimed => |value| value,
            .duplicate => return error.MirrorFillInProgress,
            .at_capacity => return error.MirrorAtCapacity,
        };
        defer self.removeFromProgress(claim_owned);
        errdefer _ = self.mirror_failures.fetchAdd(1, .monotonic);

        const remote = try self.fetchAndStoreMetadata(store, null, set_id);
        defer remote.deinit();
        if (remote.maps.len == 0) return error.MapsetIncomplete;
        try self.downloadArchive(store, &remote.maps[0].md5, set_id, remote);
        const archive = (try store.beatmapArchive(self.allocator, set_id)) orelse return error.MirrorArchiveMissing;
        _ = self.mirror_fills.fetchAdd(1, .monotonic);
        if (count_served) _ = self.mirror_bytes_served.fetchAdd(@intCast(archive.len), .monotonic);
        return .{ .data = archive, .cache_hit = false };
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
            remote.deinit();
            self.recordFailure(store, md5_owned, set_id, error.ThreadSpawnFailed);
            self.removeFromProgress(md5_owned);
            return false;
        };
        thread.detach();
        return false;
    }

    pub fn ensureByBeatmapId(self: *Sync, store: *storage.Store, beatmap_id: i32, requested_md5: ?[]const u8) !bool {
        if (beatmap_id <= 0) return false;
        if (requested_md5) |value| if (!validMd5(value)) return false;

        var key_buffer: [48]u8 = undefined;
        const lookup_key = try std.fmt.bufPrint(&key_buffer, "id:{d}", .{beatmap_id});
        const claim_owned = switch (self.claim(lookup_key) catch return false) {
            .claimed => |value| value,
            .duplicate => return false,
            .at_capacity => return false,
        };

        _ = self.attempts.fetchAdd(1, .monotonic);
        const identity = self.fetchBeatmapIdentity(beatmap_id) catch |err| {
            _ = self.failures.fetchAdd(1, .monotonic);
            self.removeFromProgress(claim_owned);
            return err;
        };
        const remote = self.fetchAndStoreMetadata(store, &identity.md5, identity.set_id) catch |err| {
            self.recordFailure(store, &identity.md5, identity.set_id, err);
            self.removeFromProgress(claim_owned);
            return err;
        };

        const md5_owned = self.allocator.dupe(u8, &identity.md5) catch |err| {
            remote.deinit();
            self.recordFailure(store, &identity.md5, identity.set_id, err);
            self.removeFromProgress(claim_owned);
            return err;
        };
        const thread = std.Thread.spawn(.{}, backgroundLookupDownload, .{ self, store, claim_owned, md5_owned, identity.set_id, remote }) catch |err| {
            remote.deinit();
            self.allocator.free(md5_owned);
            self.recordFailure(store, &identity.md5, identity.set_id, err);
            self.removeFromProgress(claim_owned);
            return err;
        };
        thread.detach();
        return true;
    }

    /// Score submission needs the actual .osu payload, not just the public
    /// metadata row. Store the whole set's metadata, but fetch the selected
    /// difficulty directly so a large archive cannot outlive lazer's ten-second
    /// score-token timeout. The archive remains the verified fallback.
    pub fn ensureFileByBeatmapId(self: *Sync, store: *storage.Store, beatmap_id: i32, requested_md5: ?[]const u8) !bool {
        if (beatmap_id <= 0) return false;
        if (requested_md5) |value| if (!validMd5(value)) return false;

        if (try scoreFileReady(store, beatmap_id, requested_md5)) return true;

        // Lazer normally asks for metadata before creating a score token. Use
        // that owned local identity when it exists: re-querying the catalogue
        // here made score submission depend on osu.direct being up twice.
        const known = try store.beatmapSelectionById(beatmap_id);
        if (known) |selection| {
            if (selection.set_id <= 0) return false;
            if (requested_md5) |value| if (!std.ascii.eqlIgnoreCase(value, &selection.md5)) return error.BeatmapHashMismatch;
        }

        var key_buffer: [48]u8 = undefined;
        const lookup_key = try std.fmt.bufPrint(&key_buffer, "id:{d}", .{beatmap_id});
        const claim_owned = switch (self.claim(lookup_key) catch return false) {
            .claimed => |value| value,
            .duplicate => {
                // Browsing may already be downloading a large archive. Do not
                // make a score-token request wait behind it: the selected .osu
                // payload is small, independently hash-checked, and safe to
                // upsert while the full-set cache finishes.
                if (known) |selection| {
                    self.downloadSingleMap(store, beatmap_id, selection.set_id, &selection.md5, selection.status) catch {};
                    if (try scoreFileReady(store, beatmap_id, requested_md5)) return true;
                }
                for (0..160) |_| {
                    std.Io.sleep(self.io, .fromMilliseconds(50), .awake) catch return false;
                    if (try scoreFileReady(store, beatmap_id, requested_md5)) return true;
                }
                return false;
            },
            .at_capacity => return false,
        };
        var release_claim = true;
        defer if (release_claim) self.removeFromProgress(claim_owned);

        _ = self.attempts.fetchAdd(1, .monotonic);
        const identity: BeatmapIdentity = if (known) |selection|
            .{ .set_id = selection.set_id, .md5 = selection.md5 }
        else
            self.fetchBeatmapIdentity(beatmap_id) catch |err| {
                _ = self.failures.fetchAdd(1, .monotonic);
                return err;
            };
        if (requested_md5) |value| if (!std.ascii.eqlIgnoreCase(value, &identity.md5)) return error.BeatmapHashMismatch;

        const now = std.Io.Clock.real.now(self.io).toSeconds();
        if (!try store.hydrationRetryAllowed(&identity.md5, now)) {
            _ = self.backoff_skips.fetchAdd(1, .monotonic);
            return false;
        }
        var remote: ?RemoteSet = null;
        var metadata_error: ?anyerror = null;
        if (self.fetchAndStoreMetadata(store, &identity.md5, identity.set_id)) |value| {
            remote = value;
        } else |err| {
            metadata_error = err;
        }
        defer if (remote) |value| value.deinit();

        const status = if (remote) |value| localStatus(value.approved) else if (known) |selection| selection.status else @as(i8, 2);
        var selected_map_ready = true;
        self.downloadSingleMap(store, beatmap_id, identity.set_id, &identity.md5, status) catch |map_err| {
            selected_map_ready = false;
            const set = remote orelse {
                const err = metadata_error orelse map_err;
                std.log.warn("[hydrate] selected map unavailable map={d}: {t}", .{ beatmap_id, err });
                self.recordFailure(store, &identity.md5, identity.set_id, err);
                return err;
            };
            std.log.warn("[hydrate] selected map unavailable map={d}: {t}; trying full set", .{ beatmap_id, map_err });
            self.downloadArchive(store, &identity.md5, identity.set_id, set) catch |archive_err| {
                std.log.warn("[hydrate] full set fallback failed set={d} map={d}: {t}", .{ identity.set_id, beatmap_id, archive_err });
                self.recordFailure(store, &identity.md5, identity.set_id, archive_err);
                return archive_err;
            };
        };
        if (selected_map_ready) if (remote) |set| {
            const md5_owned = self.allocator.dupe(u8, &identity.md5) catch null;
            if (md5_owned) |md5| {
                const thread = std.Thread.spawn(.{}, backgroundLookupDownload, .{ self, store, claim_owned, md5, identity.set_id, set }) catch null;
                if (thread) |handle| {
                    remote = null;
                    release_claim = false;
                    handle.detach();
                } else {
                    self.allocator.free(md5);
                }
            }
        };
        store.clearHydrationFailure(&identity.md5) catch |err|
            std.log.warn("[hydrate] could not clear failure state md5={s}: {t}", .{ &identity.md5, err });
        if (release_claim) _ = self.successes.fetchAdd(1, .monotonic);
        return try scoreFileReady(store, beatmap_id, requested_md5);
    }

    /// Hydrate the metadata for a whole set without downloading its archive.
    /// Set overlays need this before they know which individual difficulty will
    /// be opened, while the later beatmap lookup remains responsible for the
    /// bounded archive download.
    pub fn ensureBySetId(self: *Sync, store: *storage.Store, set_id: i32) !bool {
        if (set_id <= 0) return false;

        var key_buffer: [48]u8 = undefined;
        const lookup_key = try std.fmt.bufPrint(&key_buffer, "set:{d}", .{set_id});
        const claim_owned = switch (self.claim(lookup_key) catch return false) {
            .claimed => |value| value,
            .duplicate => return false,
            .at_capacity => return false,
        };
        defer self.removeFromProgress(claim_owned);

        _ = self.attempts.fetchAdd(1, .monotonic);
        const remote = self.fetchAndStoreMetadata(store, null, set_id) catch |err| {
            _ = self.failures.fetchAdd(1, .monotonic);
            return err;
        };
        remote.deinit();
        _ = self.successes.fetchAdd(1, .monotonic);
        return true;
    }

    /// Pull the public CheeseGull catalogue page and persist every difficulty
    /// from each returned set. The returned ids preserve upstream relevance
    /// order so Lazer does not depend on the order of the local cache.
    pub fn searchSets(self: *Sync, store: *storage.Store, query: []const u8, mode: i8, offset: u16) ![]i32 {
        if (query.len > 256 or mode < -1 or mode > 3) return error.InvalidSearch;

        var url: std.Io.Writer.Allocating = .init(self.allocator);
        defer url.deinit();
        try url.writer.print("https://osu.direct/api/search?amount=50&offset={d}", .{offset});
        if (mode >= 0) try url.writer.print("&mode={d}", .{mode});
        try url.writer.print("&query={f}", .{std.fmt.alt(
            @as(std.Uri.Component, .{ .raw = query }),
            .formatEscaped,
        )});

        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        const json = try fetchFn(&client, self.allocator, url.written(), search_limit);
        defer self.allocator.free(json);
        const parsed = try std.json.parseFromSlice([]CheesegullSet, self.allocator, json, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (parsed.value.len > 50) return error.InvalidSearchResponse;

        const ids = try self.allocator.alloc(i32, parsed.value.len);
        errdefer self.allocator.free(ids);
        for (parsed.value, 0..) |set, index| {
            try self.storeSetMetadata(store, set);
            ids[index] = set.SetID;
        }
        return ids;
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

    fn fetchBeatmapIdentity(self: *Sync, beatmap_id: i32) !BeatmapIdentity {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        const metadata_url = try std.fmt.allocPrint(self.allocator, "https://osu.direct/api/b/{d}", .{beatmap_id});
        defer self.allocator.free(metadata_url);
        const metadata_json = try fetchFn(&client, self.allocator, metadata_url, metadata_limit);
        defer self.allocator.free(metadata_json);
        const parsed = try std.json.parseFromSlice(CheesegullMap, self.allocator, metadata_json, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (parsed.value.BeatmapID != beatmap_id or parsed.value.ParentSetID <= 0 or !validMd5(parsed.value.FileMD5)) return error.IdMismatch;
        var identity: BeatmapIdentity = .{ .set_id = parsed.value.ParentSetID, .md5 = undefined };
        @memcpy(&identity.md5, parsed.value.FileMD5);
        return identity;
    }

    fn storeSetMetadata(self: *Sync, store: *storage.Store, set: CheesegullSet) !void {
        _ = self;
        if (set.SetID <= 0 or set.ChildrenBeatmaps.len == 0 or set.ChildrenBeatmaps.len > mapset_map_limit) return error.IdMismatch;
        for (set.ChildrenBeatmaps, 0..) |candidate, index| {
            if (candidate.BeatmapID <= 0 or candidate.ParentSetID != set.SetID or !validMd5(candidate.FileMD5) or candidate.Mode > 3) return error.IdMismatch;
            for (set.ChildrenBeatmaps[0..index]) |previous| {
                if (previous.BeatmapID == candidate.BeatmapID or std.ascii.eqlIgnoreCase(previous.FileMD5, candidate.FileMD5)) return error.IdMismatch;
            }
            const meta = beatmap.Metadata{
                .id = candidate.BeatmapID,
                .set_id = candidate.ParentSetID,
                .mode = candidate.Mode,
                .artist = set.Artist,
                .title = set.Title,
                .version = candidate.DiffName,
                .creator = set.Creator,
                .source = set.Source orelse "",
                .tags = set.Tags orelse "",
                .hp = candidate.HP orelse 0,
                .cs = candidate.CS orelse 0,
                .od = candidate.OD orelse 0,
                .ar = candidate.AR orelse 0,
                .bpm = candidate.BPM orelse 0,
                .total_length = candidate.TotalLength,
                .count_circles = 0,
                .count_sliders = 0,
                .count_spinners = 0,
                .object_count = 0,
            };
            try store.upsertBeatmapMeta(meta, candidate.FileMD5, localStatus(set.RankedStatus), candidate.DifficultyRating orelse 0, candidate.MaxCombo orelse 0);
        }
    }

    fn fetchAndStoreMetadata(self: *Sync, store: *storage.Store, wanted_md5: ?[]const u8, set_id: i32) !RemoteSet {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        if (wanted_md5) |md5|
            std.log.info("[hydrate] start md5={s} set={d}", .{ md5, set_id })
        else
            std.log.info("[hydrate] start set={d}", .{set_id});

        const metadata_url = try std.fmt.allocPrint(self.allocator, "https://osu.direct/api/s/{d}", .{set_id});
        defer self.allocator.free(metadata_url);
        const metadata_json = fetchFn(&client, self.allocator, metadata_url, metadata_limit) catch |err| {
            std.log.warn("[hydrate] metadata fetch failed: {t}", .{err});
            return err;
        };
        defer self.allocator.free(metadata_json);
        const parsed = std.json.parseFromSlice(CheesegullSet, self.allocator, metadata_json, .{ .ignore_unknown_fields = true }) catch |err| {
            std.log.warn("[hydrate] metadata parse failed: {t}", .{err});
            return err;
        };
        defer parsed.deinit();
        if (parsed.value.SetID != set_id or parsed.value.ChildrenBeatmaps.len == 0 or parsed.value.ChildrenBeatmaps.len > mapset_map_limit) return error.IdMismatch;
        var remote: ?CheesegullMap = if (wanted_md5 == null) parsed.value.ChildrenBeatmaps[0] else null;
        for (parsed.value.ChildrenBeatmaps) |candidate| {
            if (candidate.BeatmapID <= 0 or candidate.ParentSetID != set_id or !validMd5(candidate.FileMD5) or candidate.Mode > 3) return error.IdMismatch;
            if (wanted_md5) |md5| if (std.ascii.eqlIgnoreCase(candidate.FileMD5, md5)) {
                remote = candidate;
                break;
            };
        }
        const map_info = remote orelse return error.Md5NotFound;
        try self.storeSetMetadata(store, parsed.value);

        const maps = try self.allocator.alloc(RemoteMap, parsed.value.ChildrenBeatmaps.len);
        errdefer self.allocator.free(maps);
        for (parsed.value.ChildrenBeatmaps, 0..) |candidate, index| {
            maps[index] = .{ .md5 = undefined, .beatmap_id = candidate.BeatmapID };
            @memcpy(&maps[index].md5, candidate.FileMD5);
        }
        std.log.info("[hydrate] metadata ok — {s} - {s} [{s}] stars={d:.2}", .{ parsed.value.Artist, parsed.value.Title, map_info.DiffName, map_info.DifficultyRating orelse 0 });
        return .{
            .allocator = self.allocator,
            .approved = parsed.value.RankedStatus,
            .requested_beatmap_id = map_info.BeatmapID,
            .maps = maps,
        };
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

    fn backgroundDownload(self: *Sync, store: *storage.Store, md5_owned: []const u8, set_id: i32, remote: RemoteSet) void {
        defer self.removeFromProgress(md5_owned);
        defer remote.deinit();
        self.downloadArchive(store, md5_owned, set_id, remote) catch |err| {
            std.log.warn("[hydrate] download failed md5={s}: {t}", .{ md5_owned, err });
            self.recordFailure(store, md5_owned, set_id, err);
            return;
        };
        store.clearHydrationFailure(md5_owned) catch |err| std.log.warn("[hydrate] could not clear failure state md5={s}: {t}", .{ md5_owned, err });
        _ = self.successes.fetchAdd(1, .monotonic);
    }

    fn backgroundLookupDownload(self: *Sync, store: *storage.Store, claim_owned: []const u8, md5_owned: []const u8, set_id: i32, remote: RemoteSet) void {
        defer self.removeFromProgress(claim_owned);
        defer self.allocator.free(md5_owned);
        defer remote.deinit();
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

    fn downloadArchive(self: *Sync, store: *storage.Store, wanted_md5: []const u8, set_id: i32, remote: RemoteSet) !void {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        std.log.info("[hydrate] downloading archive set={d}", .{set_id});
        const archive = self.fetchArchive(&client, set_id) catch |err| {
            std.log.warn("[hydrate] archive fetch failed: {t}", .{err});
            return err;
        };
        defer self.allocator.free(archive);
        std.log.info("[hydrate] downloaded {d:.1} MB", .{@as(f64, @floatFromInt(archive.len)) / 1048576.0});

        const osu_files = extractAllOsu(self.allocator, archive) catch |err| {
            std.log.warn("[hydrate] extraction failed: {t}", .{err});
            return err;
        };
        defer freeExtractedOsu(self.allocator, osu_files);

        const PreparedMap = struct {
            metadata: beatmap.Metadata,
            md5: [32]u8,
            stars: f64,
            max_combo: u32,
            contents: []const u8,
        };
        const prepared = try self.allocator.alloc(PreparedMap, remote.maps.len);
        defer self.allocator.free(prepared);

        var requested_found = false;
        for (remote.maps, 0..) |remote_map, index| {
            const extracted = findExtractedOsu(osu_files, &remote_map.md5) orelse return error.MapsetIncomplete;

            const metadata = beatmap.parseWithIds(extracted.contents, remote_map.beatmap_id, set_id) catch |err| {
                std.log.warn("[hydrate] .osu parse failed map={d}: {t}", .{ remote_map.beatmap_id, err });
                return err;
            };
            if (metadata.id != remote_map.beatmap_id or metadata.set_id != set_id) return error.IdMismatch;
            const attributes = pp.calculate(extracted.contents, .{
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
                std.log.warn("[hydrate] PP calc failed map={d}: {t}", .{ remote_map.beatmap_id, err });
                return err;
            };
            prepared[index] = .{
                .metadata = metadata,
                .md5 = remote_map.md5,
                .stars = attributes.stars,
                .max_combo = attributes.max_combo,
                .contents = extracted.contents,
            };
            if (remote_map.beatmap_id == remote.requested_beatmap_id) {
                if (!std.ascii.eqlIgnoreCase(&remote_map.md5, wanted_md5)) return error.BeatmapHashMismatch;
                requested_found = true;
            }
        }
        if (!requested_found) return error.Md5NotInArchive;

        for (prepared) |map| {
            try store.upsertBeatmap(map.metadata, &map.md5, localStatus(remote.approved), map.stars, map.max_combo, map.contents);
            std.log.info("[hydrate] stored map={d} — {s} [{s}] stars={d:.2} max_combo={d}", .{ map.metadata.id, map.metadata.artist, map.metadata.version, map.stars, map.max_combo });
        }
        std.log.info("[hydrate] complete set={d} maps={d}", .{ set_id, prepared.len });

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

    fn downloadSingleMap(self: *Sync, store: *storage.Store, beatmap_id: i32, set_id: i32, wanted_md5: []const u8, status: i8) !void {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const url = try std.fmt.allocPrint(self.allocator, "https://osu.ppy.sh/osu/{d}", .{beatmap_id});
        defer self.allocator.free(url);
        const contents = try fetchFn(&client, self.allocator, url, map_limit);
        defer self.allocator.free(contents);

        const digest = beatmap.md5(contents);
        if (!std.ascii.eqlIgnoreCase(&digest, wanted_md5)) return error.BeatmapHashMismatch;
        const metadata = try beatmap.parseWithIds(contents, beatmap_id, set_id);
        if (metadata.id != beatmap_id or metadata.set_id != set_id) return error.IdMismatch;
        const attributes = try pp.calculate(contents, .{
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
        });
        try store.upsertBeatmap(metadata, &digest, status, attributes.stars, attributes.max_combo, contents);
        std.log.info("[hydrate] stored verified map fallback map={d} set={d} md5={s}", .{ beatmap_id, set_id, &digest });
    }
};

fn scoreFileReady(store: *storage.Store, beatmap_id: i32, requested_md5: ?[]const u8) !bool {
    const selection = (try store.beatmapSelectionById(beatmap_id)) orelse return false;
    if (requested_md5) |value| if (!std.ascii.eqlIgnoreCase(value, &selection.md5)) return error.BeatmapHashMismatch;
    return store.beatmapHasFile(&selection.md5);
}

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

test "osu direct metadata keeps cheese gull map and set fields" {
    const map_json =
        \\{"ParentSetID":1593278,"BeatmapID":3314160,"TotalLength":245,"DiffName":"normal","FileMD5":"e74aaf07ca2a2f48b9fcb75892d2387c","CS":3.2,"AR":6,"HP":4,"OD":4,"Mode":0,"BPM":168,"MaxCombo":827,"DifficultyRating":2.20658}
    ;
    const parsed_map = try std.json.parseFromSlice(CheesegullMap, std.testing.allocator, map_json, .{ .ignore_unknown_fields = true });
    defer parsed_map.deinit();
    try std.testing.expectEqual(@as(i32, 3314160), parsed_map.value.BeatmapID);
    try std.testing.expectEqual(@as(i32, 1593278), parsed_map.value.ParentSetID);
    try std.testing.expectEqualStrings("e74aaf07ca2a2f48b9fcb75892d2387c", parsed_map.value.FileMD5);

    const set_json =
        \\{"SetID":1593278,"Title":"test title","Artist":"test artist","Creator":"mapper","Source":"","Tags":"tag one","RankedStatus":1,"ChildrenBeatmaps":[{"ParentSetID":1593278,"BeatmapID":3314160,"TotalLength":245,"DiffName":"normal","FileMD5":"e74aaf07ca2a2f48b9fcb75892d2387c","CS":3.2,"AR":6,"HP":4,"OD":4,"Mode":0,"BPM":168,"MaxCombo":827,"DifficultyRating":2.20658}]}
    ;
    const parsed_set = try std.json.parseFromSlice(CheesegullSet, std.testing.allocator, set_json, .{ .ignore_unknown_fields = true });
    defer parsed_set.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_set.value.ChildrenBeatmaps.len);
    try std.testing.expectEqual(@as(i8, 3), localStatus(parsed_set.value.RankedStatus));
    try std.testing.expectEqualStrings("normal", parsed_set.value.ChildrenBeatmaps[0].DiffName);
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
    }) catch |err| {
        std.log.warn("[hydrate] upstream request failed url={s}: {t}", .{ url, err });
        return error.UpstreamUnavailable;
    };
    if (result.status != .ok) {
        std.log.warn("[hydrate] upstream status url={s} status={d}", .{ url, @intFromEnum(result.status) });
        return error.UpstreamUnavailable;
    }
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

pub fn extractAllOsu(allocator: std.mem.Allocator, archive: []const u8) ![]ExtractedOsu {
    const end_offset = std.mem.lastIndexOf(u8, archive, &std.zip.end_record_sig) orelse return error.InvalidBeatmapArchive;
    const end = try range(archive, end_offset, 22);
    const entry_count: usize = std.mem.readInt(u16, end[10..12], .little);
    const central_size: usize = std.mem.readInt(u32, end[12..16], .little);
    const central_offset: usize = std.mem.readInt(u32, end[16..20], .little);
    const comment_len: usize = std.mem.readInt(u16, end[20..22], .little);
    if (entry_count == 0 or entry_count > entry_limit or end_offset + 22 + comment_len != archive.len) return error.InvalidBeatmapArchive;
    _ = try range(archive, central_offset, central_size);
    const central_end = std.math.add(usize, central_offset, central_size) catch return error.InvalidBeatmapArchive;

    var files: std.ArrayList(ExtractedOsu) = .empty;
    errdefer {
        for (files.items) |file| allocator.free(file.contents);
        files.deinit(allocator);
    }
    var total_size: usize = 0;
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
        if (!std.ascii.endsWithIgnoreCase(filename, ".osu")) continue;

        const contents = try unzipEntry(allocator, archive, central);
        const next_size = std.math.add(usize, total_size, contents.len) catch {
            allocator.free(contents);
            return error.InvalidBeatmapArchive;
        };
        if (next_size > archive_limit) {
            allocator.free(contents);
            return error.InvalidBeatmapArchive;
        }
        const digest = beatmap.md5(contents);
        for (files.items) |existing| if (std.ascii.eqlIgnoreCase(&existing.md5, &digest)) {
            allocator.free(contents);
            return error.InvalidBeatmapArchive;
        };
        files.append(allocator, .{ .md5 = digest, .contents = contents }) catch |err| {
            allocator.free(contents);
            return err;
        };
        total_size = next_size;
    }
    if (offset != central_end or files.items.len == 0) return error.InvalidBeatmapArchive;
    return files.toOwnedSlice(allocator);
}
