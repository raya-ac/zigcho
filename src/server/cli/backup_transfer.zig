const std = @import("std");
const r2 = @import("../../r2.zig");

const chunk_bytes = 256 * 1024;
const worker_limit = 8;
const attempt_limit = 3;
const range_timeout_ms = 45_000;
const transfer_timeout_ms = 900_000;

fn deadline(comptime T: type, io: std.Io, milliseconds: u32, comptime function: anytype, args: anytype) !T {
    const Completion = union(enum) { value: anyerror!T, timeout: std.Io.Cancelable!void };
    const Work = struct {
        fn run(arguments: @TypeOf(args)) anyerror!T {
            return @call(.auto, function, arguments);
        }
    };
    var events: [2]Completion = undefined;
    var selected: std.Io.Select(Completion) = .init(io, &events);
    defer selected.cancelDiscard();
    try selected.concurrent(.timeout, std.Io.sleep, .{ io, .fromMilliseconds(milliseconds), .awake });
    try selected.concurrent(.value, Work.run, .{args});
    return switch (try selected.await()) {
        .value => |result| try result,
        .timeout => error.ObjectTransferTimedOut,
    };
}

fn probe(allocator: std.mem.Allocator, io: std.Io, target: r2.Storage, key: []const u8, byte: *[1]u8, total: ?usize) !r2.Storage.ObjectMetadata {
    for (0..attempt_limit) |attempt| {
        return deadline(r2.Storage.ObjectMetadata, io, range_timeout_ms, r2.Storage.readRange, .{ target, allocator, io, key, byte[0..], @as(usize, 0), total, @as([]const u8, "") }) catch |err| {
            if (err == error.Canceled or attempt + 1 == attempt_limit) return err;
            try std.Io.sleep(io, .fromSeconds(1), .awake);
            continue;
        };
    }
    unreachable;
}

fn Context(comptime Storage: type) type {
    return struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        target: Storage,
        key: []const u8,
        metadata: r2.Storage.ObjectMetadata,
        expected: ?[]const u8,
        output: ?[]u8,
        next: std.atomic.Value(usize) = .init(0),
        completed: std.atomic.Value(usize) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),

        fn count(self: *const @This()) usize {
            return (self.metadata.bytes - 1 + chunk_bytes - 1) / chunk_bytes;
        }

        fn worker(self: *@This()) void {
            const scratch = if (self.expected != null) self.allocator.alloc(u8, chunk_bytes) catch {
                self.failed.store(true, .release);
                return;
            } else null;
            defer if (scratch) |buffer| self.allocator.free(buffer);
            while (!self.failed.load(.acquire)) {
                std.Io.checkCancel(self.io) catch return;
                const part = self.next.fetchAdd(1, .acq_rel);
                if (part >= self.count()) return;
                const offset = 1 + part * chunk_bytes;
                const length = @min(chunk_bytes, self.metadata.bytes - offset);
                const buffer = if (scratch) |bytes| bytes[0..length] else self.output.?[offset .. offset + length];
                var success = false;
                for (0..attempt_limit) |attempt| {
                    const metadata = deadline(r2.Storage.ObjectMetadata, self.io, range_timeout_ms, Storage.readRange, .{ self.target, self.allocator, self.io, self.key, buffer, offset, @as(?usize, self.metadata.bytes), self.metadata.etag() }) catch |err| {
                        if (err == error.Canceled) return;
                        std.log.warn("event=backup_range_retry part={d} attempt={d} error={t}", .{ part, attempt + 1, err });
                        if (attempt + 1 < attempt_limit) std.Io.sleep(self.io, .fromSeconds(1), .awake) catch return;
                        continue;
                    };
                    if (metadata.bytes != self.metadata.bytes or !std.mem.eql(u8, metadata.etag(), self.metadata.etag())) break;
                    if (self.expected) |source| if (!std.mem.eql(u8, source[offset .. offset + length], buffer)) break;
                    success = true;
                    break;
                }
                if (!success) {
                    self.failed.store(true, .release);
                    return;
                }
                const done = self.completed.fetchAdd(1, .acq_rel) + 1;
                if (done % 16 == 0 or done == self.count()) std.log.info("event=backup_read_progress parts={d}/{d}", .{ done, self.count() });
            }
        }

        fn run(self: *@This()) !void {
            var group: std.Io.Group = .init;
            defer group.cancel(self.io);
            for (0..@min(worker_limit, self.count())) |_| try group.concurrent(self.io, worker, .{self});
            try group.await(self.io);
            if (self.failed.load(.acquire) or self.completed.load(.acquire) != self.count()) return error.ObjectVerificationFailed;
        }
    };
}

pub fn putVerified(allocator: std.mem.Allocator, io: std.Io, target: r2.Storage, key: []const u8, bytes: []const u8) !void {
    if (bytes.len == 0) return error.InvalidObjectTransferArguments;
    try deadline(void, io, 180_000, r2.Storage.put, .{ target, allocator, io, key, @as([]const u8, "application/octet-stream"), bytes });
    var byte: [1]u8 = undefined;
    const metadata = try probe(allocator, io, target, key, &byte, bytes.len);
    if (byte[0] != bytes[0]) return error.ObjectVerificationFailed;
    var context: Context(r2.Storage) = .{ .allocator = allocator, .io = io, .target = target, .key = key, .metadata = metadata, .expected = bytes, .output = null };
    // All bytes are compared, not just an ETag or the ends of the object. Memory
    // used for verification is bounded by eight 256 KiB buffers, not another dump.
    try deadline(void, io, transfer_timeout_ms, Context(r2.Storage).run, .{&context});
}

pub fn get(allocator: std.mem.Allocator, io: std.Io, target: r2.Storage, key: []const u8, limit: usize) ![]u8 {
    var byte: [1]u8 = undefined;
    const metadata = try probe(allocator, io, target, key, &byte, null);
    if (metadata.bytes == 0 or metadata.bytes > limit) return error.R2ObjectTooLarge;
    const bytes = try allocator.alloc(u8, metadata.bytes);
    errdefer allocator.free(bytes);
    bytes[0] = byte[0];
    var context: Context(r2.Storage) = .{ .allocator = allocator, .io = io, .target = target, .key = key, .metadata = metadata, .expected = null, .output = bytes };
    try deadline(void, io, transfer_timeout_ms, Context(r2.Storage).run, .{&context});
    return bytes;
}

test "backup ranges cover every byte and reject changed content" {
    const Fake = struct {
        corrupt: bool = false,
        fn readRange(self: @This(), _: std.mem.Allocator, _: std.Io, _: []const u8, buffer: []u8, offset: usize, total: ?usize, _: []const u8) !r2.Storage.ObjectMetadata {
            for (buffer, 0..) |*byte, i| byte.* = @truncate((offset + i) % 251);
            if (self.corrupt) buffer[buffer.len - 1] ^= 1;
            var metadata: r2.Storage.ObjectMetadata = .{ .bytes = total.?, .etag_len = 3 };
            @memcpy(metadata.etag_buffer[0..3], "\"x\"");
            return metadata;
        }
    };
    const bytes = try std.testing.allocator.alloc(u8, chunk_bytes * 2 + 17);
    defer std.testing.allocator.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i % 251);
    var metadata: r2.Storage.ObjectMetadata = .{ .bytes = bytes.len, .etag_len = 3 };
    @memcpy(metadata.etag_buffer[0..3], "\"x\"");
    var valid: Context(Fake) = .{ .allocator = std.testing.allocator, .io = std.testing.io, .target = .{}, .key = "fixture", .metadata = metadata, .expected = bytes, .output = null };
    try valid.run();
    try std.testing.expectEqual(@as(usize, 3), valid.completed.load(.acquire));
    var corrupt: Context(Fake) = .{ .allocator = std.testing.allocator, .io = std.testing.io, .target = .{ .corrupt = true }, .key = "fixture", .metadata = metadata, .expected = bytes, .output = null };
    try std.testing.expectError(error.ObjectVerificationFailed, corrupt.run());
}

test "backup transfer rejects unconfigured storage before sending data" {
    const target: r2.Storage = .{ .endpoint = "", .bucket = "", .access_key_id = "", .secret_access_key = "" };
    try std.testing.expectError(error.R2NotConfigured, putVerified(std.testing.allocator, std.testing.io, target, "fixture", "x"));
}
