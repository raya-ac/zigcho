const std = @import("std");

pub const max_client_hash_bytes = 4096;

pub const BindingMismatch = enum {
    version,
    hardware,
};

/// Owned evidence shared by a Stable login and its later score submissions.
/// Raw hardware identifiers never leave request parsing.
pub const Binding = struct {
    version_date: [8]u8,
    hardware_digest: [32]u8,

    pub fn init(osu_version: []const u8, client_hash: []const u8) !Binding {
        const version_date = try normalizedVersion(osu_version);
        const fields = try parseHardwareFields(client_hash);
        var digest: [32]u8 = undefined;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("zigcho-stable-client-binding-v1\x00");
        hashField(&hash, fields.osu_path_md5);
        hashField(&hash, fields.adapters);
        hashField(&hash, fields.adapters_md5);
        hashField(&hash, fields.uninstall_md5);
        hashField(&hash, fields.disk_signature_md5);
        hash.final(&digest);
        return .{ .version_date = version_date, .hardware_digest = digest };
    }

    pub fn mismatch(self: Binding, submitted: Binding) ?BindingMismatch {
        if (!std.crypto.timing_safe.eql([8]u8, self.version_date, submitted.version_date)) return .version;
        if (!std.crypto.timing_safe.eql([32]u8, self.hardware_digest, submitted.hardware_digest)) return .hardware;
        return null;
    }
};

pub const HardwareFields = struct {
    osu_path_md5: []const u8,
    adapters: []const u8,
    adapters_md5: []const u8,
    uninstall_md5: []const u8,
    disk_signature_md5: []const u8,
};

fn normalizedVersion(value: []const u8) ![8]u8 {
    const date = if (value.len == 8) value else if (value.len >= 9 and value[0] == 'b') value[1..9] else return error.InvalidStableClientVersion;
    for (date) |char| if (!std.ascii.isDigit(char)) return error.InvalidStableClientVersion;
    if (value.len != 8) {
        var remainder = value[9..];
        if (remainder.len >= 2 and remainder[0] == '.' and std.ascii.isDigit(remainder[1])) remainder = remainder[2..];
        if (remainder.len != 0 and
            !std.mem.eql(u8, remainder, "beta") and
            !std.mem.eql(u8, remainder, "cuttingedge") and
            !std.mem.eql(u8, remainder, "dev") and
            !std.mem.eql(u8, remainder, "tourney")) return error.InvalidStableClientVersion;
    }
    return date[0..8].*;
}

pub fn parseHardwareFields(value: []const u8) !HardwareFields {
    if (value.len < 2 or value.len > max_client_hash_bytes or value[value.len - 1] != ':') return error.InvalidStableClientHash;
    var fields = std.mem.splitScalar(u8, value[0 .. value.len - 1], ':');
    const osu_path_md5 = fields.next() orelse return error.InvalidStableClientHash;
    const adapters = fields.next() orelse return error.InvalidStableClientHash;
    const adapters_md5 = fields.next() orelse return error.InvalidStableClientHash;
    const uninstall_md5 = fields.next() orelse return error.InvalidStableClientHash;
    const disk_signature_md5 = fields.next() orelse return error.InvalidStableClientHash;
    if (fields.next() != null or !validMd5(osu_path_md5) or !validMd5(adapters_md5) or !validMd5(uninstall_md5) or !validMd5(disk_signature_md5)) return error.InvalidStableClientHash;
    if (!std.mem.eql(u8, adapters, "runningunderwine")) {
        if (adapters.len < 2 or adapters[adapters.len - 1] != '.') return error.InvalidStableClientHash;
        var parts = std.mem.splitScalar(u8, adapters[0 .. adapters.len - 1], '.');
        var any_adapter = false;
        while (parts.next()) |adapter| if (adapter.len != 0) {
            any_adapter = true;
            for (adapter) |char| if (char == 0 or char == ':') return error.InvalidStableClientHash;
        };
        if (!any_adapter) return error.InvalidStableClientHash;
    }
    return .{
        .osu_path_md5 = osu_path_md5,
        .adapters = adapters,
        .adapters_md5 = adapters_md5,
        .uninstall_md5 = uninstall_md5,
        .disk_signature_md5 = disk_signature_md5,
    };
}

fn validMd5(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |char| if (!std.ascii.isHex(char)) return false;
    return true;
}

fn hashField(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(value.len), .little);
    hash.update(&length);
    for (value) |char| {
        const normalized = [1]u8{std.ascii.toLower(char)};
        hash.update(&normalized);
    }
}

test "Stable client bindings own normalized version and hardware evidence" {
    const hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1.2.3.:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:cccccccccccccccccccccccccccccccc:dddddddddddddddddddddddddddddddd:";
    const same = try Binding.init("b20260811cuttingedge", hash);
    const score = try Binding.init("20260811", hash);
    try std.testing.expectEqual(@as(?BindingMismatch, null), same.mismatch(score));
    const other_version = try Binding.init("20260812", hash);
    try std.testing.expectEqual(BindingMismatch.version, same.mismatch(other_version).?);
}
