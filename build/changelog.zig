const std = @import("std");

const Manifest = struct {
    schema: u8,
    builds: []const struct {
        id: i64,
        version: []const u8,
        display_version: ?[]const u8 = null,
        created_at: []const u8,
        updates: []const struct {
            name: []const u8,
            created_at: []const u8,
            commit: []const u8,
            sha256: []const u8,
        },
    },
};

// Generate only in Zig's build cache. The JSON manifest owns release metadata;
// each Markdown file remains a compiler-tracked input to the startup fallback.
pub fn create(b: *std.Build) !*std.Build.Module {
    const io = b.graph.io;
    const bytes = try b.build_root.handle.readFileAlloc(io, "updates/changelog.json", b.allocator, .limited(128 * 1024));
    const parsed = try std.json.parseFromSlice(Manifest, b.allocator, bytes, .{});
    const manifest = parsed.value;
    if (manifest.schema != 1 or manifest.builds.len == 0 or manifest.builds.len > 64) return error.InvalidChangelogManifest;

    const files = b.addWriteFiles();
    var source: std.Io.Writer.Allocating = .init(b.allocator);
    const writer = &source.writer;
    try writer.writeAll(@embedFile("../src/changelog_types.zig"));
    try writer.writeAll("\npub const builds = [_]Build{\n");
    var previous_id: i64 = std.math.maxInt(i64);
    var names: std.StringHashMapUnmanaged(void) = .empty;
    var total_bytes: usize = 0;
    for (manifest.builds) |build| {
        if (build.id <= 0 or build.id >= previous_id or build.updates.len == 0) return error.InvalidChangelogBuild;
        previous_id = build.id;
        try writer.print(".{{ .id = {d}, .version = \"{f}\", .created_at = \"{f}\", .display_version = ", .{ build.id, std.zig.fmtString(build.version), std.zig.fmtString(build.created_at) });
        if (build.display_version) |display| {
            try writer.print("\"{f}\"", .{std.zig.fmtString(display)});
        } else try writer.writeAll("null");
        try writer.writeAll(", .updates = &.{\n");
        for (build.updates) |update| {
            if (!validName(update.name)) return error.InvalidChangelogFilename;
            const entry = try names.getOrPut(b.allocator, update.name);
            if (entry.found_existing or names.count() > 256) return error.InvalidChangelogUpdates;
            const path = b.fmt("updates/{s}", .{update.name});
            const markdown = try b.build_root.handle.readFileAlloc(io, path, b.allocator, .limited(128 * 1024));
            total_bytes += markdown.len;
            if (markdown.len == 0 or total_bytes > 2 * 1024 * 1024) return error.InvalidChangelogSize;
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(markdown, &digest, .{});
            const expected = std.fmt.bytesToHex(digest, .lower);
            if (!std.mem.eql(u8, update.sha256, &expected)) return error.ChangelogDigestMismatch;
            _ = files.addCopyFile(b.path(path), path);
            try writer.print(".{{ .name = \"{f}\", .created_at = \"{f}\", .commit = \"{f}\", .markdown = @embedFile(\"{f}\") }},\n", .{ std.zig.fmtString(update.name), std.zig.fmtString(update.created_at), std.zig.fmtString(update.commit), std.zig.fmtString(path) });
        }
        try writer.writeAll("} },\n");
    }
    try writer.writeAll("};\n");
    return b.createModule(.{ .root_source_file = files.add("catalog.zig", source.written()) });
}

fn validName(name: []const u8) bool {
    if (name.len < "2000-01-01-a.md".len or name.len > 96 or !std.mem.endsWith(u8, name, ".md")) return false;
    for (name[0 .. name.len - 3]) |char| {
        if (!std.ascii.isLower(char) and !std.ascii.isDigit(char) and char != '-') return false;
    }
    return true;
}
