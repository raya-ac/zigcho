const std = @import("std");
const telemetry = @import("telemetry.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const empty_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
const max_object_bytes: usize = 2 * 1024 * 1024;

pub const Storage = struct {
    endpoint: []const u8,
    bucket: []const u8,
    access_key_id: []const u8,
    secret_access_key: []const u8,
    region: []const u8 = "auto",

    pub const ObjectMetadata = struct {
        bytes: usize,
        etag_buffer: [256]u8 = undefined,
        etag_len: usize = 0,
        pub fn etag(self: *const ObjectMetadata) []const u8 {
            return self.etag_buffer[0..self.etag_len];
        }
    };

    const Range = struct {
        start: usize,
        end: usize,
        total: ?usize,
        etag: []const u8,
        metadata: *ObjectMetadata,
    };

    /// Backup transfers use short, independently retryable ranges. Each response
    /// must cover exactly the requested bytes and refer to the pinned object.
    pub fn readRange(self: Storage, allocator: std.mem.Allocator, io: std.Io, object_key: []const u8, buffer: []u8, offset: usize, total: ?usize, etag: []const u8) !ObjectMetadata {
        if (!self.enabled()) return error.R2NotConfigured;
        if (buffer.len == 0 or buffer.len > 1024 * 1024 or offset > std.math.maxInt(usize) - buffer.len) return error.InvalidR2ObjectRange;
        if (total) |size| if (offset >= size or buffer.len > size - offset) return error.InvalidR2ObjectRange;
        if (etag.len > 256 or std.mem.indexOfAny(u8, etag, "\r\n") != null) return error.InvalidR2ObjectRange;
        var writer = std.Io.Writer.fixed(buffer);
        var metadata: ObjectMetadata = .{ .bytes = 0 };
        const result = try self.requestWithRange(allocator, io, .GET, object_key, "application/octet-stream", "", &writer, .{ .start = offset, .end = offset + buffer.len - 1, .total = total, .etag = etag, .metadata = &metadata });
        if (result != .partial_content) return error.R2RangeRejected;
        if (writer.end != buffer.len) return error.R2TruncatedObject;
        return metadata;
    }

    pub fn enabled(self: Storage) bool {
        return validEndpoint(self.endpoint) and validBucket(self.bucket) and validRegion(self.region) and self.access_key_id.len > 0 and self.secret_access_key.len > 0;
    }

    pub fn put(self: Storage, allocator: std.mem.Allocator, io: std.Io, object_key: []const u8, content_type: []const u8, data: []const u8) !void {
        if (!self.enabled()) return error.R2NotConfigured;
        const timer = telemetry.Timer.start(.object_upload);
        defer timer.finish();
        const result = try self.request(allocator, io, .PUT, object_key, content_type, data, null);
        if (result != .ok and result != .no_content) {
            std.log.warn("event=r2_upload_rejected status={d}", .{@intFromEnum(result)});
            return error.R2UploadFailed;
        }
    }

    pub fn get(self: Storage, allocator: std.mem.Allocator, io: std.Io, object_key: []const u8, content_type: []const u8) ![]u8 {
        return self.getWithLimit(allocator, io, object_key, content_type, max_object_bytes);
    }

    pub fn getWithLimit(self: Storage, allocator: std.mem.Allocator, io: std.Io, object_key: []const u8, content_type: []const u8, limit: usize) ![]u8 {
        if (!self.enabled()) return error.R2NotConfigured;
        const timer = telemetry.Timer.start(.object_download);
        defer timer.finish();
        if (limit == 0 or limit == std.math.maxInt(usize)) return error.InvalidR2ObjectLimit;
        const buffer = try allocator.alloc(u8, limit + 1);
        errdefer allocator.free(buffer);
        var writer = std.Io.Writer.fixed(buffer);
        const result = self.request(allocator, io, .GET, object_key, content_type, "", &writer) catch |err| switch (err) {
            error.WriteFailed => return error.R2ObjectTooLarge,
            else => return err,
        };
        if (result == .not_found) return error.R2ObjectNotFound;
        if (result != .ok) {
            std.log.warn("event=r2_download_rejected status={d}", .{@intFromEnum(result)});
            return error.R2DownloadFailed;
        }
        if (writer.end > limit) return error.R2ObjectTooLarge;
        return allocator.realloc(buffer, writer.end);
    }

    pub fn streamGet(self: Storage, allocator: std.mem.Allocator, io: std.Io, object_key: []const u8, content_type: []const u8, writer: *std.Io.Writer) !void {
        if (!self.enabled()) return error.R2NotConfigured;
        const timer = telemetry.Timer.start(.object_download);
        defer timer.finish();
        const result = try self.request(allocator, io, .GET, object_key, content_type, "", writer);
        if (result == .not_found) return error.R2ObjectNotFound;
        if (result != .ok) {
            std.log.warn("event=r2_download_rejected status={d}", .{@intFromEnum(result)});
            return error.R2DownloadFailed;
        }
    }

    /// Return a short-lived URL which lets a client read an object directly.
    /// Large beatmap archives must not be buffered by the public HTTP/2 proxy.
    pub fn presignedGetUrl(self: Storage, allocator: std.mem.Allocator, io: std.Io, object_key: []const u8, expires_seconds: u32) ![]u8 {
        const now = std.Io.Clock.real.now(io).toSeconds();
        if (now < 0) return error.InvalidClock;
        return self.presignedGetUrlAt(allocator, object_key, expires_seconds, @intCast(now));
    }

    fn presignedGetUrlAt(self: Storage, allocator: std.mem.Allocator, object_key: []const u8, expires_seconds: u32, unix_seconds: u64) ![]u8 {
        if (!self.enabled()) return error.R2NotConfigured;
        if (!validObjectKey(object_key)) return error.InvalidR2ObjectKey;
        if (expires_seconds == 0 or expires_seconds > 604_800) return error.InvalidR2PresignExpiry;
        const host = endpointHost(self.endpoint) orelse return error.InvalidR2Endpoint;
        const canonical_uri = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ self.bucket, object_key });
        defer allocator.free(canonical_uri);
        return presignedUrlAt(
            allocator,
            std.mem.trimEnd(u8, self.endpoint, "/"),
            host,
            canonical_uri,
            self.access_key_id,
            self.secret_access_key,
            self.region,
            expires_seconds,
            unix_seconds,
        );
    }

    pub fn delete(self: Storage, allocator: std.mem.Allocator, io: std.Io, object_key: []const u8) !void {
        if (!self.enabled()) return error.R2NotConfigured;
        const result = try self.request(allocator, io, .DELETE, object_key, "application/octet-stream", "", null);
        if (result != .ok and result != .no_content and result != .not_found) {
            std.log.warn("event=r2_delete_rejected status={d}", .{@intFromEnum(result)});
            return error.R2DeleteFailed;
        }
    }

    fn request(self: Storage, allocator: std.mem.Allocator, io: std.Io, method: std.http.Method, object_key: []const u8, content_type: []const u8, payload: []const u8, response_writer: ?*std.Io.Writer) !std.http.Status {
        return self.requestWithRange(allocator, io, method, object_key, content_type, payload, response_writer, null);
    }

    fn requestWithRange(self: Storage, allocator: std.mem.Allocator, io: std.Io, method: std.http.Method, object_key: []const u8, content_type: []const u8, payload: []const u8, response_writer: ?*std.Io.Writer, range: ?Range) !std.http.Status {
        if (!validObjectKey(object_key)) return error.InvalidR2ObjectKey;
        const host = endpointHost(self.endpoint) orelse return error.InvalidR2Endpoint;
        const canonical_uri = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ self.bucket, object_key });
        defer allocator.free(canonical_uri);
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ std.mem.trimEnd(u8, self.endpoint, "/"), canonical_uri });
        defer allocator.free(url);

        var payload_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(payload, &payload_digest, .{});
        const payload_hash = if (payload.len == 0) empty_sha256.* else std.fmt.bytesToHex(payload_digest, .lower);
        const now = std.Io.Clock.real.now(io).toSeconds();
        if (now < 0) return error.InvalidClock;
        const timestamp = awsTimestamp(@intCast(now));
        const signed_headers = "content-type;host;x-amz-content-sha256;x-amz-date";
        const canonical_headers = try std.fmt.allocPrint(allocator, "content-type:{s}\nhost:{s}\nx-amz-content-sha256:{s}\nx-amz-date:{s}\n", .{ content_type, host, &payload_hash, &timestamp.amz });
        defer allocator.free(canonical_headers);
        const canonical_request = try std.fmt.allocPrint(allocator, "{s}\n{s}\n\n{s}\n{s}\n{s}", .{ @tagName(method), canonical_uri, canonical_headers, signed_headers, &payload_hash });
        defer allocator.free(canonical_request);
        var request_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(canonical_request, &request_digest, .{});
        const request_hash = std.fmt.bytesToHex(request_digest, .lower);
        const credential_scope = try std.fmt.allocPrint(allocator, "{s}/{s}/s3/aws4_request", .{ &timestamp.date, self.region });
        defer allocator.free(credential_scope);
        const string_to_sign = try std.fmt.allocPrint(allocator, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ &timestamp.amz, credential_scope, &request_hash });
        defer allocator.free(string_to_sign);
        const signing_key = try deriveSigningKey(allocator, self.secret_access_key, &timestamp.date, self.region);
        defer allocator.free(signing_key);
        var signature_digest: [32]u8 = undefined;
        HmacSha256.create(&signature_digest, string_to_sign, signing_key);
        const signature = std.fmt.bytesToHex(signature_digest, .lower);
        const authorization = try std.fmt.allocPrint(allocator, "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}", .{ self.access_key_id, credential_scope, signed_headers, &signature });
        defer allocator.free(authorization);

        var range_buffer: [64]u8 = undefined;
        const range_header = if (range) |r| try std.fmt.bufPrint(&range_buffer, "bytes={d}-{d}", .{ r.start, r.end }) else "";
        const extra_headers = [_]std.http.Header{
            .{ .name = "x-amz-content-sha256", .value = &payload_hash },
            .{ .name = "x-amz-date", .value = &timestamp.amz },
            .{ .name = "range", .value = range_header },
            .{ .name = "if-match", .value = if (range) |r| r.etag else "" },
        };
        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();
        if (range) |r| {
            var req = try client.request(.GET, try std.Uri.parse(url), .{
                .redirect_behavior = .unhandled,
                .keep_alive = false,
                .headers = .{
                    .authorization = .{ .override = authorization },
                    .content_type = .{ .override = content_type },
                    .accept_encoding = .{ .override = "identity" },
                    .user_agent = .{ .override = "zigcho/0.1" },
                },
                .extra_headers = extra_headers[0..if (r.etag.len == 0) @as(usize, 3) else 4],
            });
            defer req.deinit();
            try req.sendBodiless();
            var header_buffer: [8192]u8 = undefined;
            var response = try req.receiveHead(&header_buffer);
            if (response.head.status != .partial_content) return response.head.status;
            if (response.head.content_encoding != .identity) return error.R2RangeRejected;
            if (response.head.content_length) |length| if (length != r.end - r.start + 1) return error.R2RangeRejected;
            var headers = response.head.iterateHeaders();
            var found_range = false;
            var found_etag = false;
            while (headers.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "content-range")) {
                    if (found_range) return error.R2RangeRejected;
                    r.metadata.bytes = try validateContentRange(header.value, r.start, r.end, r.total);
                    found_range = true;
                } else if (std.ascii.eqlIgnoreCase(header.name, "etag")) {
                    if (found_etag or header.value.len < 2 or header.value.len > r.metadata.etag_buffer.len or header.value[0] != '"' or header.value[header.value.len - 1] != '"') return error.R2RangeRejected;
                    if (r.etag.len != 0 and !std.mem.eql(u8, r.etag, header.value)) return error.R2ObjectChanged;
                    @memcpy(r.metadata.etag_buffer[0..header.value.len], header.value);
                    r.metadata.etag_len = header.value.len;
                    found_etag = true;
                }
            }
            if (!found_range or !found_etag) return error.R2RangeRejected;
            var transfer_buffer: [64 * 1024]u8 = undefined;
            const reader = response.reader(&transfer_buffer);
            _ = reader.streamRemaining(response_writer.?) catch |err| switch (err) {
                error.ReadFailed => return response.bodyErr() orelse error.R2TruncatedObject,
                else => return err,
            };
            return response.head.status;
        }
        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = if (method == .PUT) payload else null,
            .response_writer = response_writer,
            .headers = .{
                .authorization = .{ .override = authorization },
                .content_type = .{ .override = content_type },
                .accept_encoding = .{ .override = "identity" },
                .user_agent = .{ .override = "zigcho/0.1" },
            },
            .extra_headers = extra_headers[0..2],
        });
        return result.status;
    }
};

fn validateContentRange(value: []const u8, start: usize, end: usize, expected_total: ?usize) !usize {
    if (!std.mem.startsWith(u8, value, "bytes ")) return error.R2RangeRejected;
    const dash = std.mem.indexOfScalar(u8, value[6..], '-') orelse return error.R2RangeRejected;
    const slash = std.mem.indexOfScalar(u8, value[6..], '/') orelse return error.R2RangeRejected;
    if (dash >= slash) return error.R2RangeRejected;
    const actual_start = std.fmt.parseInt(usize, value[6 .. 6 + dash], 10) catch return error.R2RangeRejected;
    const actual_end = std.fmt.parseInt(usize, value[7 + dash .. 6 + slash], 10) catch return error.R2RangeRejected;
    const total = std.fmt.parseInt(usize, value[7 + slash ..], 10) catch return error.R2RangeRejected;
    if (actual_start != start or actual_end != end or total <= end or (expected_total != null and total != expected_total.?)) return error.R2RangeRejected;
    return total;
}

test "object ranges reject wrong offsets totals and truncated range metadata" {
    try std.testing.expectEqual(@as(usize, 100), try validateContentRange("bytes 10-19/100", 10, 19, 100));
    for ([_][]const u8{ "bytes 0-19/100", "bytes 10-18/100", "bytes 10-19/99", "bytes 10-19/*", "bytes */100", "bytes 10/100", "bytes 10-19/100/2" }) |value|
        try std.testing.expectError(error.R2RangeRejected, validateContentRange(value, 10, 19, 100));
}

const Timestamp = struct { date: [8]u8, amz: [16]u8 };

fn awsTimestamp(unix_seconds: u64) Timestamp {
    const epoch = std.time.epoch.EpochSeconds{ .secs = unix_seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    var result: Timestamp = undefined;
    _ = std.fmt.bufPrint(&result.date, "{d:0>4}{d:0>2}{d:0>2}", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1 }) catch unreachable;
    _ = std.fmt.bufPrint(&result.amz, "{s}T{d:0>2}{d:0>2}{d:0>2}Z", .{ &result.date, day_seconds.getHoursIntoDay(), day_seconds.getMinutesIntoHour(), day_seconds.getSecondsIntoMinute() }) catch unreachable;
    return result;
}

fn deriveSigningKey(allocator: std.mem.Allocator, secret: []const u8, date: []const u8, region: []const u8) ![]u8 {
    const initial = try std.fmt.allocPrint(allocator, "AWS4{s}", .{secret});
    defer allocator.free(initial);
    var date_key: [32]u8 = undefined;
    var region_key: [32]u8 = undefined;
    var service_key: [32]u8 = undefined;
    var signing_key: [32]u8 = undefined;
    HmacSha256.create(&date_key, date, initial);
    HmacSha256.create(&region_key, region, &date_key);
    HmacSha256.create(&service_key, "s3", &region_key);
    HmacSha256.create(&signing_key, "aws4_request", &service_key);
    return allocator.dupe(u8, &signing_key);
}

fn percentEncodeQueryValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try output.writer.writeByte(byte);
        } else {
            try output.writer.writeByte('%');
            try output.writer.writeByte(hex[byte >> 4]);
            try output.writer.writeByte(hex[byte & 0x0f]);
        }
    }
    return output.toOwnedSlice();
}

fn presignedUrlAt(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    host: []const u8,
    canonical_uri: []const u8,
    access_key_id: []const u8,
    secret_access_key: []const u8,
    region: []const u8,
    expires_seconds: u32,
    unix_seconds: u64,
) ![]u8 {
    if (!std.mem.startsWith(u8, endpoint, "https://") or host.len == 0 or canonical_uri.len < 2 or canonical_uri[0] != '/' or access_key_id.len == 0 or secret_access_key.len == 0 or !validRegion(region)) return error.InvalidR2Configuration;
    if (expires_seconds == 0 or expires_seconds > 604_800) return error.InvalidR2PresignExpiry;
    const timestamp = awsTimestamp(unix_seconds);
    const credential_scope = try std.fmt.allocPrint(allocator, "{s}/{s}/s3/aws4_request", .{ &timestamp.date, region });
    defer allocator.free(credential_scope);
    const credential = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ access_key_id, credential_scope });
    defer allocator.free(credential);
    const encoded_credential = try percentEncodeQueryValue(allocator, credential);
    defer allocator.free(encoded_credential);
    const canonical_query = try std.fmt.allocPrint(
        allocator,
        "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential={s}&X-Amz-Date={s}&X-Amz-Expires={d}&X-Amz-SignedHeaders=host",
        .{ encoded_credential, &timestamp.amz, expires_seconds },
    );
    defer allocator.free(canonical_query);
    const canonical_request = try std.fmt.allocPrint(
        allocator,
        "GET\n{s}\n{s}\nhost:{s}\n\nhost\nUNSIGNED-PAYLOAD",
        .{ canonical_uri, canonical_query, host },
    );
    defer allocator.free(canonical_request);
    var request_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical_request, &request_digest, .{});
    const request_hash = std.fmt.bytesToHex(request_digest, .lower);
    const string_to_sign = try std.fmt.allocPrint(allocator, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ &timestamp.amz, credential_scope, &request_hash });
    defer allocator.free(string_to_sign);
    const signing_key = try deriveSigningKey(allocator, secret_access_key, &timestamp.date, region);
    defer allocator.free(signing_key);
    var signature_digest: [32]u8 = undefined;
    HmacSha256.create(&signature_digest, string_to_sign, signing_key);
    const signature = std.fmt.bytesToHex(signature_digest, .lower);
    return std.fmt.allocPrint(allocator, "{s}{s}?{s}&X-Amz-Signature={s}", .{ endpoint, canonical_uri, canonical_query, &signature });
}

fn validEndpoint(value: []const u8) bool {
    return endpointHost(value) != null;
}

fn endpointHost(value: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, "https://")) return null;
    const rest = std.mem.trimEnd(u8, value["https://".len..], "/");
    if (rest.len == 0 or std.mem.findScalar(u8, rest, '/') != null or std.mem.findScalar(u8, rest, '?') != null or std.mem.findScalar(u8, rest, '#') != null) return null;
    return rest;
}

fn validBucket(value: []const u8) bool {
    if (value.len < 3 or value.len > 63) return false;
    for (value) |char| if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '.') return false;
    return true;
}

fn validRegion(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |char| if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_') return false;
    return true;
}

fn validObjectKey(value: []const u8) bool {
    if (value.len == 0 or value.len > 200 or value[0] == '/' or std.mem.indexOf(u8, value, "..") != null) return false;
    for (value) |char| if (!std.ascii.isAlphanumeric(char) and char != '/' and char != '-' and char != '_' and char != '.') return false;
    return true;
}

test "r2 timestamp and configuration stay deterministic" {
    const timestamp = awsTimestamp(1_628_637_300);
    try std.testing.expectEqualStrings("20210810", &timestamp.date);
    try std.testing.expectEqualStrings("20210810T231500Z", &timestamp.amz);
    const configured: Storage = .{ .endpoint = "https://example.r2.cloudflarestorage.com", .bucket = "avatar", .access_key_id = "key", .secret_access_key = "secret" };
    try std.testing.expect(configured.enabled());
    const contabo: Storage = .{ .endpoint = "https://sin1.contabostorage.com", .bucket = "data", .access_key_id = "key", .secret_access_key = "secret", .region = "default" };
    try std.testing.expect(contabo.enabled());
    try std.testing.expect(!validObjectKey("../secret"));
    try std.testing.expect(validObjectKey("avatars/4/abcdef.png"));
    try std.testing.expect(!validBucket("tenant:data"));
}

test "r2 signing key matches the official s3 signature fixture" {
    const key = try deriveSigningKey(std.testing.allocator, "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "20130524", "us-east-1");
    defer std.testing.allocator.free(key);
    const string_to_sign = "AWS4-HMAC-SHA256\n" ++
        "20130524T000000Z\n" ++
        "20130524/us-east-1/s3/aws4_request\n" ++
        "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972";
    var digest: [32]u8 = undefined;
    HmacSha256.create(&digest, string_to_sign, key);
    const signature = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings("f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41", &signature);
}

test "r2 presigned get matches the official s3 query fixture" {
    const url = try presignedUrlAt(
        std.testing.allocator,
        "https://examplebucket.s3.amazonaws.com",
        "examplebucket.s3.amazonaws.com",
        "/test.txt",
        "AKIAIOSFODNN7EXAMPLE",
        "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "us-east-1",
        86_400,
        1_369_353_600,
    );
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
        url,
    );
    try std.testing.expectError(error.InvalidR2PresignExpiry, presignedUrlAt(std.testing.allocator, "https://example.test", "example.test", "/object", "key", "secret", "default", 0, 1_369_353_600));
}
