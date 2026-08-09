const std = @import("std");
const storage = @import("storage.zig");

fn validZip(bytes: []const u8) bool {
    if (bytes.len < 22 or !std.mem.eql(u8, bytes[0..4], &std.zip.local_file_header_sig)) return false;
    const end_offset = std.mem.lastIndexOf(u8, bytes, &std.zip.end_record_sig) orelse return false;
    if (end_offset + 22 > bytes.len) return false;
    const record = bytes[end_offset..];
    const entry_count = std.mem.readInt(u16, record[10..12], .little);
    const central_offset: usize = std.mem.readInt(u32, record[16..20], .little);
    const comment_len: usize = std.mem.readInt(u16, record[20..22], .little);
    if (entry_count == 0 or end_offset + 22 + comment_len != bytes.len or central_offset > bytes.len - 4) return false;
    return std.mem.eql(u8, bytes[central_offset..][0..4], &std.zip.central_file_header_sig);
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len != 4) {
        std.log.err("usage: zigcho-import-archive <database> <set-id> <beatmap.osz>", .{});
        return error.InvalidArguments;
    }
    const set_id = try std.fmt.parseInt(i32, args[2], 10);
    if (set_id <= 0) return error.InvalidBeatmapSet;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[3], allocator, .limited(512 * 1024 * 1024));
    defer allocator.free(bytes);
    if (!validZip(bytes)) return error.InvalidBeatmapArchive;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var encoded: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&encoded, "{x}", .{digest}) catch unreachable;
    const db_path = try allocator.dupeZ(u8, args[1]);
    defer allocator.free(db_path);
    var store = try storage.Store.open(allocator, init.io, db_path);
    defer store.close();
    try store.migrate();
    try store.upsertBeatmapArchive(set_id, &encoded, bytes);
    std.log.info("stored beatmap set {d} archive ({s}, {d} bytes)", .{ set_id, encoded, bytes.len });
}
