const std = @import("std");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const empty_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
const max_object_bytes: usize = 2 * 1024 * 1024;

pub const Storage = struct {
    endpoint: []const u8,
    bucket: []const u8,
    access_key_id: []const u8,
    secret_access_key: []const u8,
    region: []const u8 = "auto",

    pub fn enabled(self: Storage) bool {
        return validEndpoint(self.endpoint) and validBucket(self.bucket) and validRegion(self.region) and self.access_key_id.len > 0 and self.secret_access_key.len > 0;
    }

    pub fn put(self: Storage, allocator: std.mem.Allocator, io: std.Io, object_key: []const u8, content_type: []const u8, data: []const u8) !void {
        if (!self.enabled()) return error.R2NotConfigured;
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

        const extra_headers = [_]std.http.Header{
            .{ .name = "x-amz-content-sha256", .value = &payload_hash },
            .{ .name = "x-amz-date", .value = &timestamp.amz },
        };
        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();
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
            .extra_headers = &extra_headers,
        });
        return result.status;
    }
};

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
