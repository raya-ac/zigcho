const std = @import("std");
const beatmap = @import("beatmap.zig");
const pp = @import("exact_pp.zig");
const multipart = @import("multipart.zig");

pub const premium_privilege: u32 = 1 << 5;
pub const max_upload_bytes: usize = 128 * 1024 * 1024;
pub const max_unpacked_bytes: usize = 256 * 1024 * 1024;
pub const max_file_bytes: usize = 64 * 1024 * 1024;
pub const max_osu_bytes: usize = 16 * 1024 * 1024;
pub const max_entries: usize = 4096;
pub const max_beatmaps: usize = 256;
pub const legacy_private_id_floor: i32 = 100_000_000;
pub const private_id_floor: i32 = 1_000_000_000;

pub const Path = union(enum) {
    collection,
    set: i32,
};

pub fn parsePath(path: []const u8) ?Path {
    if (std.mem.eql(u8, path, "/beatmapsets")) return .collection;
    const prefix = "/beatmapsets/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const value = path[prefix.len..];
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, '/') != null) return null;
    const set_id = std.fmt.parseInt(i32, value, 10) catch return null;
    return if (set_id >= legacy_private_id_floor) .{ .set = set_id } else null;
}

pub const Target = enum {
    wip,
    pending,

    pub fn parse(value: []const u8) ?Target {
        if (std.ascii.eqlIgnoreCase(value, "WIP")) return .wip;
        if (std.ascii.eqlIgnoreCase(value, "Pending")) return .pending;
        return null;
    }

    pub fn database(self: Target) []const u8 {
        return switch (self) {
            .wip => "WIP",
            .pending => "Pending",
        };
    }

    pub fn status(self: Target) i8 {
        return switch (self) {
            .wip => 1,
            .pending => 2,
        };
    }
};

pub const ReserveInput = struct {
    allocator: std.mem.Allocator,
    set_id: ?i32,
    create_count: u16,
    keep_ids: []i32,
    target: Target,
    notify_replies: bool,

    pub fn deinit(self: *ReserveInput) void {
        self.allocator.free(self.keep_ids);
        self.* = undefined;
    }
};

pub fn parseReserveInput(allocator: std.mem.Allocator, body: []const u8) !ReserveInput {
    if (body.len == 0 or body.len > 64 * 1024) return error.InvalidBssReservation;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidBssReservation;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidBssReservation;
    const object = parsed.value.object;

    const raw_create = object.get("beatmaps_to_create") orelse return error.InvalidBssReservation;
    if (raw_create != .integer or raw_create.integer < 0 or raw_create.integer > max_beatmaps) return error.InvalidBssReservation;
    const create_count: u16 = @intCast(raw_create.integer);

    const raw_target = object.get("target") orelse return error.InvalidBssReservation;
    if (raw_target != .string) return error.InvalidBssReservation;
    const target = Target.parse(raw_target.string) orelse return error.InvalidBssReservation;

    const set_id: ?i32 = if (object.get("beatmapset_id")) |value| switch (value) {
        .null => null,
        .integer => if (value.integer >= legacy_private_id_floor and value.integer <= std.math.maxInt(i32)) @intCast(value.integer) else return error.InvalidBssReservation,
        else => return error.InvalidBssReservation,
    } else null;

    const raw_keep = object.get("beatmaps_to_keep") orelse return error.InvalidBssReservation;
    if (raw_keep != .array or raw_keep.array.items.len > max_beatmaps) return error.InvalidBssReservation;
    const keep_ids = try allocator.alloc(i32, raw_keep.array.items.len);
    errdefer allocator.free(keep_ids);
    for (raw_keep.array.items, 0..) |value, index| {
        if (value != .integer or value.integer < legacy_private_id_floor or value.integer > std.math.maxInt(i32)) return error.InvalidBssReservation;
        const id: i32 = @intCast(value.integer);
        if (std.mem.indexOfScalar(i32, keep_ids[0..index], id) != null) return error.InvalidBssReservation;
        keep_ids[index] = id;
    }
    if (set_id == null and (keep_ids.len != 0 or create_count == 0)) return error.InvalidBssReservation;
    if (set_id != null and keep_ids.len + create_count == 0) return error.InvalidBssReservation;
    if (keep_ids.len + create_count > max_beatmaps) return error.InvalidBssReservation;

    const notify_replies = if (object.get("notify_on_discussion_replies")) |value| switch (value) {
        .bool => value.bool,
        else => return error.InvalidBssReservation,
    } else false;
    return .{
        .allocator = allocator,
        .set_id = set_id,
        .create_count = create_count,
        .keep_ids = keep_ids,
        .target = target,
        .notify_replies = notify_replies,
    };
}

pub const Reservation = struct {
    allocator: std.mem.Allocator,
    set_id: i32,
    beatmap_ids: []i32,
    revision: u32,

    pub fn deinit(self: *Reservation) void {
        self.allocator.free(self.beatmap_ids);
        self.* = undefined;
    }
};

pub const Entry = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    data: []u8,

    pub fn deinit(self: *Entry) void {
        self.allocator.free(self.name);
        self.allocator.free(self.data);
        self.* = undefined;
    }
};

pub const Archive = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Archive) void {
        for (self.entries.items) |*entry| entry.deinit();
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn indexOf(self: *const Archive, name: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| if (std.ascii.eqlIgnoreCase(entry.name, name)) return index;
        return null;
    }
};

fn boundedRange(bytes: []const u8, start: usize, length: usize) ![]const u8 {
    const end = std.math.add(usize, start, length) catch return error.InvalidBssArchive;
    if (end > bytes.len) return error.InvalidBssArchive;
    return bytes[start..end];
}

fn validFilename(name: []const u8, directory: bool) bool {
    if (name.len == 0 or name.len > 1024 or name[0] == '/' or std.mem.indexOfScalar(u8, name, '\\') != null or !std.unicode.utf8ValidateSlice(name)) return false;
    for (name) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    var pieces = std.mem.splitScalar(u8, if (directory) std.mem.trimEnd(u8, name, "/") else name, '/');
    while (pieces.next()) |piece| if (piece.len == 0 or std.mem.eql(u8, piece, ".") or std.mem.eql(u8, piece, "..")) return false;
    return directory == std.mem.endsWith(u8, name, "/");
}

fn extractEntry(allocator: std.mem.Allocator, archive: []const u8, central: []const u8, central_name: []const u8) ![]u8 {
    const flags = std.mem.readInt(u16, central[8..10], .little);
    if (flags & 1 != 0) return error.EncryptedBssArchive;
    const method = std.mem.readInt(u16, central[10..12], .little);
    const crc = std.mem.readInt(u32, central[16..20], .little);
    const compressed_length: usize = std.mem.readInt(u32, central[20..24], .little);
    const output_length: usize = std.mem.readInt(u32, central[24..28], .little);
    const local_offset: usize = std.mem.readInt(u32, central[42..46], .little);
    if (output_length == 0 or output_length > max_file_bytes or compressed_length > max_upload_bytes) return error.InvalidBssArchive;
    const local = try boundedRange(archive, local_offset, 30);
    if (!std.mem.eql(u8, local[0..4], &std.zip.local_file_header_sig)) return error.InvalidBssArchive;
    if (std.mem.readInt(u16, local[6..8], .little) & 1 != 0 or std.mem.readInt(u16, local[8..10], .little) != method) return error.InvalidBssArchive;
    const name_length: usize = std.mem.readInt(u16, local[26..28], .little);
    const extra_length: usize = std.mem.readInt(u16, local[28..30], .little);
    const local_name = try boundedRange(archive, local_offset + 30, name_length);
    if (!std.mem.eql(u8, local_name, central_name)) return error.InvalidBssArchive;
    const data_offset = std.math.add(usize, local_offset + 30 + name_length, extra_length) catch return error.InvalidBssArchive;
    const compressed = try boundedRange(archive, data_offset, compressed_length);
    const output = try allocator.alloc(u8, output_length);
    errdefer allocator.free(output);
    switch (method) {
        0 => {
            if (compressed.len != output.len) return error.InvalidBssArchive;
            @memcpy(output, compressed);
        },
        8 => {
            var input = std.Io.Reader.fixed(compressed);
            var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var decompress: std.compress.flate.Decompress = .init(&input, .raw, &flate_buffer);
            decompress.reader.readSliceAll(output) catch return error.InvalidBssArchive;
        },
        else => return error.UnsupportedBssCompression,
    }
    if (std.hash.Crc32.hash(output) != crc) return error.InvalidBssArchive;
    return output;
}

pub fn parseArchive(allocator: std.mem.Allocator, bytes: []const u8) !Archive {
    if (bytes.len < 22 or bytes.len > max_upload_bytes) return error.InvalidBssArchive;
    const end_offset = std.mem.lastIndexOf(u8, bytes, &std.zip.end_record_sig) orelse return error.InvalidBssArchive;
    const end = try boundedRange(bytes, end_offset, 22);
    if (std.mem.readInt(u16, end[4..6], .little) != 0 or std.mem.readInt(u16, end[6..8], .little) != 0) return error.InvalidBssArchive;
    const disk_entries: usize = std.mem.readInt(u16, end[8..10], .little);
    const entry_count: usize = std.mem.readInt(u16, end[10..12], .little);
    const central_size: usize = std.mem.readInt(u32, end[12..16], .little);
    const central_offset: usize = std.mem.readInt(u32, end[16..20], .little);
    const comment_length: usize = std.mem.readInt(u16, end[20..22], .little);
    if (entry_count == 0 or entry_count != disk_entries or entry_count > max_entries or end_offset + 22 + comment_length != bytes.len) return error.InvalidBssArchive;
    const central_end = std.math.add(usize, central_offset, central_size) catch return error.InvalidBssArchive;
    if (central_end != end_offset) return error.InvalidBssArchive;

    var result: Archive = .{ .allocator = allocator };
    errdefer result.deinit();
    var unpacked: usize = 0;
    var offset = central_offset;
    for (0..entry_count) |_| {
        const central = try boundedRange(bytes, offset, 46);
        if (!std.mem.eql(u8, central[0..4], &std.zip.central_file_header_sig)) return error.InvalidBssArchive;
        const name_length: usize = std.mem.readInt(u16, central[28..30], .little);
        const extra_length: usize = std.mem.readInt(u16, central[30..32], .little);
        const entry_comment_length: usize = std.mem.readInt(u16, central[32..34], .little);
        if (std.mem.readInt(u16, central[34..36], .little) != 0) return error.InvalidBssArchive;
        const name = try boundedRange(bytes, offset + 46, name_length);
        const record_length = std.math.add(usize, 46 + name_length, extra_length + entry_comment_length) catch return error.InvalidBssArchive;
        offset = std.math.add(usize, offset, record_length) catch return error.InvalidBssArchive;
        const directory = std.mem.endsWith(u8, name, "/");
        if (!validFilename(name, directory)) return error.InvalidBssFilename;
        if (directory) continue;
        if (result.indexOf(name) != null) return error.DuplicateBssFilename;
        const data = try extractEntry(allocator, bytes, central, name);
        errdefer allocator.free(data);
        unpacked = std.math.add(usize, unpacked, data.len) catch return error.BssArchiveTooLarge;
        if (unpacked > max_unpacked_bytes) return error.BssArchiveTooLarge;
        const owned_name = try allocator.dupe(u8, name);
        result.entries.append(allocator, .{ .allocator = allocator, .name = owned_name, .data = data }) catch |err| {
            allocator.free(owned_name);
            return err;
        };
    }
    if (offset != central_end or result.entries.items.len == 0) return error.InvalidBssArchive;
    return result;
}

pub fn buildArchive(allocator: std.mem.Allocator, archive: *const Archive) ![]u8 {
    if (archive.entries.items.len == 0 or archive.entries.items.len > max_entries or archive.entries.items.len > std.math.maxInt(u16)) return error.InvalidBssArchive;
    const local_offsets = try allocator.alloc(u32, archive.entries.items.len);
    defer allocator.free(local_offsets);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    for (archive.entries.items, 0..) |entry, index| {
        if (!validFilename(entry.name, false) or entry.data.len == 0 or entry.data.len > max_file_bytes) return error.InvalidBssArchive;
        if (output.written().len > std.math.maxInt(u32)) return error.BssArchiveTooLarge;
        local_offsets[index] = @intCast(output.written().len);
        const crc = std.hash.Crc32.hash(entry.data);
        try writer.writeAll(&std.zip.local_file_header_sig);
        try writer.writeInt(u16, 20, .little);
        try writer.writeInt(u16, 0x800, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u32, crc, .little);
        try writer.writeInt(u32, @intCast(entry.data.len), .little);
        try writer.writeInt(u32, @intCast(entry.data.len), .little);
        try writer.writeInt(u16, @intCast(entry.name.len), .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeAll(entry.name);
        try writer.writeAll(entry.data);
        if (output.written().len > max_upload_bytes) return error.BssArchiveTooLarge;
    }
    const central_offset: u32 = @intCast(output.written().len);
    for (archive.entries.items, local_offsets) |entry, local_offset| {
        const crc = std.hash.Crc32.hash(entry.data);
        try writer.writeAll(&std.zip.central_file_header_sig);
        try writer.writeInt(u16, 20, .little);
        try writer.writeInt(u16, 20, .little);
        try writer.writeInt(u16, 0x800, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u32, crc, .little);
        try writer.writeInt(u32, @intCast(entry.data.len), .little);
        try writer.writeInt(u32, @intCast(entry.data.len), .little);
        try writer.writeInt(u16, @intCast(entry.name.len), .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u32, 0, .little);
        try writer.writeInt(u32, local_offset, .little);
        try writer.writeAll(entry.name);
    }
    const central_size: u32 = @intCast(output.written().len - central_offset);
    try writer.writeAll(&std.zip.end_record_sig);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, @intCast(archive.entries.items.len), .little);
    try writer.writeInt(u16, @intCast(archive.entries.items.len), .little);
    try writer.writeInt(u32, central_size, .little);
    try writer.writeInt(u32, central_offset, .little);
    try writer.writeInt(u16, 0, .little);
    if (output.written().len > max_upload_bytes) return error.BssArchiveTooLarge;
    return output.toOwnedSlice();
}

fn removeEntry(archive: *Archive, index: usize) void {
    var removed = archive.entries.swapRemove(index);
    removed.deinit();
}

pub fn applyPatch(allocator: std.mem.Allocator, current: []const u8, form: *const multipart.Form) ![]u8 {
    var archive = try parseArchive(allocator, current);
    defer archive.deinit();
    var touched: std.ArrayList([]const u8) = .empty;
    defer touched.deinit(allocator);
    var changes: usize = 0;
    for (form.parts.items) |part| {
        if (std.mem.eql(u8, part.name, "filesChanged")) {
            const filename = part.filename orelse return error.InvalidBssPatch;
            if (!validFilename(filename, false) or part.data.len == 0 or part.data.len > max_file_bytes) return error.InvalidBssPatch;
            for (touched.items) |name| if (std.ascii.eqlIgnoreCase(name, filename)) return error.DuplicateBssPatch;
            try touched.append(allocator, filename);
            const data = try allocator.dupe(u8, part.data);
            errdefer allocator.free(data);
            const name = try allocator.dupe(u8, filename);
            errdefer allocator.free(name);
            if (archive.indexOf(filename)) |index| {
                archive.entries.items[index].deinit();
                archive.entries.items[index] = .{ .allocator = allocator, .name = name, .data = data };
            } else {
                if (archive.entries.items.len >= max_entries) return error.BssArchiveTooLarge;
                try archive.entries.append(allocator, .{ .allocator = allocator, .name = name, .data = data });
            }
            changes += 1;
        } else if (std.mem.eql(u8, part.name, "filesDeleted")) {
            if (part.filename != null or !validFilename(part.data, false)) return error.InvalidBssPatch;
            for (touched.items) |name| if (std.ascii.eqlIgnoreCase(name, part.data)) return error.DuplicateBssPatch;
            try touched.append(allocator, part.data);
            const index = archive.indexOf(part.data) orelse return error.InvalidBssPatch;
            removeEntry(&archive, index);
            changes += 1;
        } else return error.InvalidBssPatch;
    }
    if (changes == 0) return error.InvalidBssPatch;
    return buildArchive(allocator, &archive);
}

pub const PreparedMap = struct {
    metadata: beatmap.Metadata,
    md5: [32]u8,
    stars: f64,
    max_combo: u32,
    contents: []const u8,
};

pub const Package = struct {
    allocator: std.mem.Allocator,
    archive: Archive,
    maps: []PreparedMap,

    pub fn deinit(self: *Package) void {
        self.allocator.free(self.maps);
        self.archive.deinit();
        self.* = undefined;
    }
};

fn metadataBounded(metadata: beatmap.Metadata) bool {
    return metadata.artist.len <= 256 and metadata.title.len <= 256 and metadata.version.len <= 256 and metadata.creator.len <= 256 and metadata.source.len <= 1000 and metadata.tags.len <= 4000;
}

pub fn preparePackage(allocator: std.mem.Allocator, bytes: []const u8, set_id: i32, expected_ids: []const i32) !Package {
    if (expected_ids.len == 0 or expected_ids.len > max_beatmaps) return error.InvalidBssReservation;
    var archive = try parseArchive(allocator, bytes);
    errdefer archive.deinit();
    const maps = try allocator.alloc(PreparedMap, expected_ids.len);
    errdefer allocator.free(maps);
    var count: usize = 0;
    for (archive.entries.items) |entry| {
        if (!std.ascii.endsWithIgnoreCase(entry.name, ".osu")) continue;
        if (entry.data.len > max_osu_bytes) return error.BssBeatmapTooLarge;
        if (count >= maps.len) return error.BssBeatmapCountMismatch;
        const metadata = beatmap.parse(entry.data) catch return error.BssBeatmapParseFailed;
        if (!metadataBounded(metadata)) return error.BssBeatmapMetadataTooLarge;
        if (metadata.set_id != set_id) return error.BssBeatmapSetIdMismatch;
        if (std.mem.indexOfScalar(i32, expected_ids, metadata.id) == null) return error.BssBeatmapIdMismatch;
        for (maps[0..count]) |existing| if (existing.metadata.id == metadata.id or std.ascii.eqlIgnoreCase(&existing.md5, &beatmap.md5(entry.data))) return error.DuplicateBssBeatmap;
        const digest = beatmap.md5(entry.data);
        const attributes = pp.calculate(entry.data, .{
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
        }) catch pp.Output{ .stars = 0, .max_combo = metadata.object_count };
        maps[count] = .{ .metadata = metadata, .md5 = digest, .stars = attributes.stars, .max_combo = attributes.max_combo, .contents = entry.data };
        count += 1;
    }
    if (count != expected_ids.len) return error.BssBeatmapCountMismatch;
    for (expected_ids) |id| {
        var found = false;
        for (maps) |map| if (map.metadata.id == id) {
            found = true;
            break;
        };
        if (!found) return error.BssBeatmapIdMismatch;
    }
    return .{ .allocator = allocator, .archive = archive, .maps = maps };
}

pub fn packageErrorJson(err: anyerror) []const u8 {
    return switch (err) {
        error.BssBeatmapTooLarge => "{\"error\":\"a beatmap file is too large\"}",
        error.BssBeatmapCountMismatch => "{\"error\":\"beatmap count does not match the reservation\"}",
        error.BssBeatmapParseFailed => "{\"error\":\"one of the .osu files could not be read\"}",
        error.BssBeatmapMetadataTooLarge => "{\"error\":\"beatmap metadata is too large\"}",
        error.BssBeatmapSetIdMismatch => "{\"error\":\"beatmap set ids do not match the reservation\"}",
        error.BssBeatmapIdMismatch => "{\"error\":\"beatmap ids do not match the reservation\"}",
        error.DuplicateBssBeatmap => "{\"error\":\"the package contains a duplicate beatmap\"}",
        else => "{\"error\":\"invalid beatmap package\"}",
    };
}

pub fn archiveSha256(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn reservationJson(allocator: std.mem.Allocator, reservation: Reservation, archive: ?*const Archive) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"beatmapset_id\":{d},\"beatmap_ids\":[", .{reservation.set_id});
    for (reservation.beatmap_ids, 0..) |id, index| {
        if (index != 0) try output.writer.writeByte(',');
        try output.writer.print("{d}", .{id});
    }
    try output.writer.writeAll("],\"files\":[");
    if (archive) |current| for (current.entries.items, 0..) |entry, index| {
        if (index != 0) try output.writer.writeByte(',');
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(entry.data, &digest, .{});
        const encoded = std.fmt.bytesToHex(digest, .lower);
        try output.writer.writeAll("{\"filename\":");
        try std.json.Stringify.value(entry.name, .{}, &output.writer);
        try output.writer.print(",\"sha2_hash\":\"{s}\"}}", .{&encoded});
    };
    try output.writer.print("],\"zigcho\":{{\"revision\":{d},\"premium_required\":true}}}}", .{reservation.revision});
    return output.toOwnedSlice();
}

test "BSS paths and reservation payload stay lazer-specific and bounded" {
    try std.testing.expect(private_id_floor > legacy_private_id_floor);
    try std.testing.expect(parsePath("/beatmapsets") != null);
    try std.testing.expectEqual(@as(i32, 100_000_004), parsePath("/beatmapsets/100000004").?.set);
    try std.testing.expectEqual(@as(i32, 1_000_000_004), parsePath("/beatmapsets/1000000004").?.set);
    try std.testing.expect(parsePath("/beatmapsets/4") == null);
    var input = try parseReserveInput(std.testing.allocator, "{\"beatmapset_id\":null,\"beatmaps_to_create\":2,\"beatmaps_to_keep\":[],\"target\":\"Pending\",\"notify_on_discussion_replies\":true}");
    defer input.deinit();
    try std.testing.expectEqual(@as(u16, 2), input.create_count);
    try std.testing.expectEqual(Target.pending, input.target);
    try std.testing.expect(input.notify_replies);
}
