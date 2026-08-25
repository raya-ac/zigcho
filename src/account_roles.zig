const std = @import("std");

pub const Role = enum {
    supporter,
    premium,
    alumni,
    tournament,
    nominator,
    moderator,
    administrator,
    developer,

    pub fn parse(value: []const u8) ?Role {
        return std.meta.stringToEnum(Role, value);
    }

    pub fn definition(self: Role) Definition {
        for (definitions) |entry| if (entry.role == self) return entry;
        unreachable;
    }

    pub fn fromBit(bit: u32) ?Role {
        for (definitions) |entry| if (entry.bit == bit) return entry.role;
        return null;
    }
};

pub const Definition = struct {
    role: Role,
    bit: u32,
    label: []const u8,
    short: []const u8,
    description: []const u8,
    colour: []const u8,
    permanent: bool = false,
};

pub const definitions = [_]Definition{
    .{ .role = .supporter, .bit = 1 << 4, .label = "supporter", .short = "supporter", .description = "supporter badge and Stable supporter access", .colour = "#ef9abe" },
    .{ .role = .premium, .bit = 1 << 5, .label = "premium", .short = "premium", .description = "premium access, including BSS submissions and extra username changes", .colour = "#80d7c0", .permanent = true },
    .{ .role = .alumni, .bit = 1 << 7, .label = "alumni", .short = "alumni", .description = "former staff badge without staff workspace access", .colour = "#b9a2ef" },
    .{ .role = .tournament, .bit = 1 << 10, .label = "tournament staff", .short = "tournament", .description = "tournament and multiplayer referee tools", .colour = "#e8bd69" },
    .{ .role = .nominator, .bit = 1 << 11, .label = "beatmap nominator", .short = "bn", .description = "beatmap ranking and nomination workspace", .colour = "#79c5ef" },
    .{ .role = .moderator, .bit = 1 << 12, .label = "global moderator", .short = "gmt", .description = "player, report, appeal and anticheat review tools", .colour = "#daa0ee" },
    .{ .role = .administrator, .bit = 1 << 13, .label = "administrator", .short = "admin", .description = "account, channel and team administration", .colour = "#ef8888" },
    .{ .role = .developer, .bit = 1 << 14, .label = "developer", .short = "dev", .description = "server controls, infrastructure and role management", .colour = "#ef86ba" },
};

pub const staff_mask: u32 = (1 << 11) | (1 << 12) | (1 << 13) | (1 << 14);

pub const ChangeResult = struct {
    privileges: u32,
    staff_sessions_revoked: bool,
};

pub fn isStaff(privileges: u32) bool {
    return privileges & staff_mask != 0;
}

pub fn validReason(reason: []const u8) bool {
    const trimmed = std.mem.trim(u8, reason, " \t\r\n");
    return trimmed.len >= 3 and trimmed.len <= 500 and std.unicode.utf8ValidateSlice(trimmed);
}

pub fn writeCatalogJson(writer: *std.Io.Writer, privileges: u32) !void {
    try writer.writeByte('[');
    for (definitions, 0..) |definition, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"key\":");
        try std.json.Stringify.value(@tagName(definition.role), .{}, writer);
        try writer.writeAll(",\"label\":");
        try std.json.Stringify.value(definition.label, .{}, writer);
        try writer.writeAll(",\"short\":");
        try std.json.Stringify.value(definition.short, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(definition.description, .{}, writer);
        try writer.writeAll(",\"colour\":");
        try std.json.Stringify.value(definition.colour, .{}, writer);
        try writer.print(",\"bit\":{d},\"granted\":{},\"permanent\":{}}}", .{ definition.bit, privileges & definition.bit != 0, definition.permanent });
    }
    try writer.writeByte(']');
}

test "role names map to one fixed non-base bit" {
    var mask: u32 = 0;
    for (definitions) |definition| {
        try std.testing.expectEqual(definition.role, Role.parse(@tagName(definition.role)).?);
        try std.testing.expect(definition.bit != 0 and definition.bit & (definition.bit - 1) == 0);
        try std.testing.expect(definition.bit & 3 == 0);
        try std.testing.expect(mask & definition.bit == 0);
        mask |= definition.bit;
    }
    try std.testing.expectEqual(@as(u32, 32), Role.premium.definition().bit);
    try std.testing.expect(Role.premium.definition().permanent);
    try std.testing.expect(Role.parse("32") == null);
    try std.testing.expect(Role.parse("admin developer") == null);
}
