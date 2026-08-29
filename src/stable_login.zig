const std = @import("std");
const stable_client = @import("stable_client.zig");
const storage = @import("runtime_storage.zig");

pub const Details = struct {
    osu_version: []const u8,
    utc_offset: i8,
    display_city: bool,
    pm_private: bool,
    client_binding: stable_client.Binding,
    hardware: storage.ClientHardware,
};

pub const Envelope = struct {
    name: []const u8,
    password: []const u8,
    details: []const u8,
};

pub fn username(body: []const u8) []const u8 {
    const line_end = std.mem.findScalar(u8, body, '\n') orelse body.len;
    return std.mem.trim(u8, body[0..line_end], "\r");
}

pub fn envelope(body: []const u8) Envelope {
    var lines = std.mem.splitScalar(u8, body, '\n');
    return .{
        .name = std.mem.trim(u8, lines.next() orelse "", "\r"),
        .password = std.mem.trim(u8, lines.next() orelse "", "\r"),
        .details = std.mem.trim(u8, lines.next() orelse "", "\r"),
    };
}

fn validLoginVersion(value: []const u8) bool {
    if (value.len < 9 or value[0] != 'b') return false;
    for (value[1..9]) |char| if (!std.ascii.isDigit(char)) return false;
    var remainder = value[9..];
    if (remainder.len >= 2 and remainder[0] == '.' and std.ascii.isDigit(remainder[1])) remainder = remainder[2..];
    return remainder.len == 0 or
        std.mem.eql(u8, remainder, "beta") or
        std.mem.eql(u8, remainder, "cuttingedge") or
        std.mem.eql(u8, remainder, "dev") or
        std.mem.eql(u8, remainder, "tourney");
}

fn commonHardwareHash(value: []const u8) bool {
    return std.mem.eql(u8, value, "00000000000000000000000000000000") or
        std.ascii.eqlIgnoreCase(value, "d41d8cd98f00b204e9800998ecf8427e") or
        std.ascii.eqlIgnoreCase(value, "cfcd208495d565ef66e7dff9f98764da");
}

pub fn parse(details: []const u8) !Details {
    var fields = std.mem.splitScalar(u8, details, '|');
    const osu_version = fields.next() orelse return error.InvalidLoginDetails;
    const utc_text = fields.next() orelse return error.InvalidLoginDetails;
    const display_city = fields.next() orelse return error.InvalidLoginDetails;
    const client_hashes = fields.next() orelse return error.InvalidLoginDetails;
    const pm_private = fields.next() orelse return error.InvalidLoginDetails;
    if (fields.next() != null or !validLoginVersion(osu_version)) return error.InvalidLoginDetails;
    const utc_offset = std.fmt.parseInt(i8, utc_text, 10) catch return error.InvalidLoginDetails;
    if (utc_offset < -24 or utc_offset > 24) return error.InvalidLoginDetails;
    if ((!std.mem.eql(u8, display_city, "0") and !std.mem.eql(u8, display_city, "1")) or
        (!std.mem.eql(u8, pm_private, "0") and !std.mem.eql(u8, pm_private, "1"))) return error.InvalidLoginDetails;

    const hashes = stable_client.parseHardwareFields(client_hashes) catch return error.InvalidLoginDetails;
    const client_binding = stable_client.Binding.init(osu_version, client_hashes) catch return error.InvalidLoginDetails;
    const running_under_wine = std.mem.eql(u8, hashes.adapters, "runningunderwine");
    return .{
        .osu_version = osu_version,
        .utc_offset = utc_offset,
        .display_city = std.mem.eql(u8, display_city, "1"),
        .pm_private = std.mem.eql(u8, pm_private, "1"),
        .client_binding = client_binding,
        .hardware = .{
            .osu_path_md5 = hashes.osu_path_md5,
            .adapters_md5 = hashes.adapters_md5,
            .uninstall_md5 = hashes.uninstall_md5,
            .disk_signature_md5 = hashes.disk_signature_md5,
            .client_version = osu_version,
            .running_under_wine = running_under_wine,
            .actionable = !commonHardwareHash(hashes.adapters_md5) and !commonHardwareHash(hashes.uninstall_md5) and !commonHardwareHash(hashes.disk_signature_md5),
        },
    };
}
