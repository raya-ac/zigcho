const std = @import("std");
const beatmap = @import("beatmap.zig");
const pp = @import("exact_pp.zig");
const storage = @import("storage.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len < 3 or args.len > 4) {
        std.log.err("usage: zigcho-import <database> <beatmap.osu> [status]", .{});
        return error.InvalidArguments;
    }
    const status: i8 = if (args.len == 4) try std.fmt.parseInt(i8, args[3], 10) else 2;
    if (status < 0 or status > 4) return error.InvalidBeatmapStatus;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    const metadata = try beatmap.parse(bytes);
    const hash = beatmap.md5(bytes);
    const attributes = try pp.calculate(bytes, .{
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
    const db_path = try allocator.dupeZ(u8, args[1]);
    defer allocator.free(db_path);
    var store = try storage.Store.open(allocator, init.io, db_path);
    defer store.close();
    try store.migrate();
    try store.upsertBeatmap(metadata, hash[0..], status, attributes.stars, attributes.max_combo, bytes);
    std.log.info("imported {s} - {s} [{s}] ({s}, {d:.2} stars, {d:.2}pp SS)", .{ metadata.artist, metadata.title, metadata.version, hash, attributes.stars, attributes.pp });
}
