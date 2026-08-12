const std = @import("std");

pub const max_image_bytes: usize = 2 * 1024 * 1024;
pub const max_preview_bytes: usize = 4 * 1024 * 1024;

pub const ContentType = enum {
    jpeg,
    ogg,
    mp3,

    pub fn value(self: ContentType) []const u8 {
        return switch (self) {
            .jpeg => "image/jpeg",
            .ogg => "audio/ogg",
            .mp3 => "audio/mpeg",
        };
    }

    pub fn parse(raw: []const u8) ?ContentType {
        if (std.mem.eql(u8, raw, "image/jpeg")) return .jpeg;
        if (std.mem.eql(u8, raw, "audio/ogg")) return .ogg;
        if (std.mem.eql(u8, raw, "audio/mpeg")) return .mp3;
        return null;
    }
};

pub const Kind = enum {
    cover,
    cover_2x,
    card,
    card_2x,
    list,
    list_2x,
    slimcover,
    slimcover_2x,
    thumb,
    thumb_large,
    preview,

    pub fn dbName(self: Kind) []const u8 {
        return switch (self) {
            .cover => "cover",
            .cover_2x => "cover_2x",
            .card => "card",
            .card_2x => "card_2x",
            .list => "list",
            .list_2x => "list_2x",
            .slimcover => "slimcover",
            .slimcover_2x => "slimcover_2x",
            .thumb => "thumb",
            .thumb_large => "thumb_large",
            .preview => "preview",
        };
    }

    pub fn parseDb(value: []const u8) ?Kind {
        inline for (std.meta.tags(Kind)) |kind| {
            if (std.mem.eql(u8, value, kind.dbName())) return kind;
        }
        return null;
    }

    pub fn maxBytes(self: Kind) usize {
        return if (self == .preview) max_preview_bytes else max_image_bytes;
    }

    fn coverFilename(self: Kind) ?[]const u8 {
        return switch (self) {
            .cover => "cover.jpg",
            .cover_2x => "cover@2x.jpg",
            .card => "card.jpg",
            .card_2x => "card@2x.jpg",
            .list => "list.jpg",
            .list_2x => "list@2x.jpg",
            .slimcover => "slimcover.jpg",
            .slimcover_2x => "slimcover@2x.jpg",
            else => null,
        };
    }

    pub fn upstreamUrl(self: Kind, allocator: std.mem.Allocator, set_id: i32) ![]u8 {
        if (self.coverFilename()) |filename|
            return std.fmt.allocPrint(allocator, "https://assets.ppy.sh/beatmaps/{d}/covers/{s}", .{ set_id, filename });
        return switch (self) {
            .thumb => std.fmt.allocPrint(allocator, "https://b.ppy.sh/thumb/{d}.jpg", .{set_id}),
            .thumb_large => std.fmt.allocPrint(allocator, "https://b.ppy.sh/thumb/{d}l.jpg", .{set_id}),
            .preview => std.fmt.allocPrint(allocator, "https://b.ppy.sh/preview/{d}.mp3", .{set_id}),
            else => unreachable,
        };
    }
};

pub const Request = struct {
    set_id: i32,
    kind: Kind,
};

pub const Asset = struct {
    data: []u8,
    content_type: ContentType,

    pub fn deinit(self: *Asset, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

fn positiveSetId(value: []const u8) ?i32 {
    if (value.len == 0 or value.len > 10) return null;
    const set_id = std.fmt.parseInt(i32, value, 10) catch return null;
    return if (set_id > 0) set_id else null;
}

pub fn parsePath(path: []const u8) ?Request {
    const cover_prefix = "/beatmaps/";
    if (std.mem.startsWith(u8, path, cover_prefix)) {
        const rest = path[cover_prefix.len..];
        const marker = "/covers/";
        const marker_at = std.mem.find(u8, rest, marker) orelse return null;
        const set_id = positiveSetId(rest[0..marker_at]) orelse return null;
        const filename = rest[marker_at + marker.len ..];
        inline for (std.meta.tags(Kind)) |kind| {
            if (kind.coverFilename()) |expected| {
                if (std.mem.eql(u8, filename, expected)) return .{ .set_id = set_id, .kind = kind };
            }
        }
        return null;
    }

    const preview_prefix = "/preview/";
    if (std.mem.startsWith(u8, path, preview_prefix) and std.mem.endsWith(u8, path, ".mp3")) {
        const id_text = path[preview_prefix.len .. path.len - ".mp3".len];
        return .{ .set_id = positiveSetId(id_text) orelse return null, .kind = .preview };
    }

    const thumb_prefix = "/thumb/";
    if (std.mem.startsWith(u8, path, thumb_prefix) and std.mem.endsWith(u8, path, ".jpg")) {
        const stem = path[thumb_prefix.len .. path.len - ".jpg".len];
        if (std.mem.endsWith(u8, stem, "l")) {
            return .{ .set_id = positiveSetId(stem[0 .. stem.len - 1]) orelse return null, .kind = .thumb_large };
        }
        return .{ .set_id = positiveSetId(stem) orelse return null, .kind = .thumb };
    }
    return null;
}

fn validJpeg(bytes: []const u8) bool {
    return bytes.len >= 4 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff and bytes[bytes.len - 2] == 0xff and bytes[bytes.len - 1] == 0xd9;
}

fn validMp3(bytes: []const u8) bool {
    if (bytes.len < 3) return false;
    if (std.mem.eql(u8, bytes[0..3], "ID3")) return true;
    return bytes[0] == 0xff and (bytes[1] & 0xe0) == 0xe0;
}

pub fn detect(kind: Kind, bytes: []const u8) ?ContentType {
    if (bytes.len == 0 or bytes.len > kind.maxBytes()) return null;
    if (kind != .preview) return if (validJpeg(bytes)) .jpeg else null;
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "OggS")) return .ogg;
    if (validMp3(bytes)) return .mp3;
    return null;
}

pub fn compatible(kind: Kind, content_type: ContentType) bool {
    return if (kind == .preview)
        content_type == .ogg or content_type == .mp3
    else
        content_type == .jpeg;
}

test "stable and modern beatmap media paths stay exact" {
    try std.testing.expectEqual(Request{ .set_id = 2340453, .kind = .cover_2x }, parsePath("/beatmaps/2340453/covers/cover@2x.jpg").?);
    try std.testing.expectEqual(Request{ .set_id = 2340453, .kind = .slimcover }, parsePath("/beatmaps/2340453/covers/slimcover.jpg").?);
    try std.testing.expectEqual(Request{ .set_id = 2340453, .kind = .preview }, parsePath("/preview/2340453.mp3").?);
    try std.testing.expectEqual(Request{ .set_id = 2340453, .kind = .thumb }, parsePath("/thumb/2340453.jpg").?);
    try std.testing.expectEqual(Request{ .set_id = 2340453, .kind = .thumb_large }, parsePath("/thumb/2340453l.jpg").?);
    try std.testing.expect(parsePath("/beatmaps/-1/covers/cover.jpg") == null);
    try std.testing.expect(parsePath("/beatmaps/1/covers/unknown.jpg") == null);
    try std.testing.expect(parsePath("/preview/1.ogg") == null);
    try std.testing.expect(parsePath("/thumb/1ll.jpg") == null);
}

test "beatmap media validates bytes instead of extensions" {
    const jpeg = "\xff\xd8\xffbody\xff\xd9";
    const ogg = "OggSpreview";
    const mp3 = "ID3preview";
    try std.testing.expectEqual(ContentType.jpeg, detect(.cover, jpeg).?);
    try std.testing.expectEqual(ContentType.ogg, detect(.preview, ogg).?);
    try std.testing.expectEqual(ContentType.mp3, detect(.preview, mp3).?);
    try std.testing.expect(detect(.preview, jpeg) == null);
    try std.testing.expect(detect(.cover, ogg) == null);
    try std.testing.expect(ContentType.parse("audio/ogg").? == .ogg);
    try std.testing.expect(ContentType.parse("text/html") == null);
}
