const std = @import("std");
const contract = @import("media_contract.zig");
const storage = @import("runtime_storage.zig");

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

        self.fetch_slots.waitUncancelable(self.io);
        defer self.fetch_slots.post(self.io);

        // Another request may have filled the same cache entry while this one
        // waited for one of the four upstream slots.
        if (try store.beatmapMedia(self.allocator, request.set_id, request.kind)) |asset| return asset;

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
                .user_agent = .{ .override = "zigcho/0.1 (+https://github.com/raya-ac/zigcho)" },
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
