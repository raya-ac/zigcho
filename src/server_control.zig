const std = @import("std");

pub const Feature = enum {
    registrations,
    stable_login,
    lazer_login,
    stable_scores,
    lazer_scores,
    lazer_multiplayer,
    spectator,
    bss,
    beatmap_downloads,
    website_writes,

    pub fn key(self: Feature) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) ?Feature {
        inline for (std.meta.fields(Feature)) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

pub const Definition = struct {
    feature: Feature,
    label: []const u8,
    group: []const u8,
    description: []const u8,
};

pub const definitions = [_]Definition{
    .{ .feature = .registrations, .label = "account creation", .group = "accounts", .description = "new Stable and website account registration" },
    .{ .feature = .stable_login, .label = "Stable login", .group = "clients", .description = "new Stable Bancho sessions; existing polls stay alive" },
    .{ .feature = .lazer_login, .label = "lazer login", .group = "clients", .description = "new lazer OAuth game sessions and refreshes" },
    .{ .feature = .stable_scores, .label = "Stable score submit", .group = "scoring", .description = "Stable modular score submissions" },
    .{ .feature = .lazer_scores, .label = "lazer score submit", .group = "scoring", .description = "lazer solo and room score submissions" },
    .{ .feature = .lazer_multiplayer, .label = "lazer multiplayer", .group = "realtime", .description = "room, quick play and ranked play API and realtime connections" },
    .{ .feature = .spectator, .label = "lazer spectator", .group = "realtime", .description = "spectator negotiate and realtime connections" },
    .{ .feature = .bss, .label = "beatmap submission", .group = "beatmaps", .description = "lazer BSS create and upload writes" },
    .{ .feature = .beatmap_downloads, .label = "beatmap downloads", .group = "beatmaps", .description = "Stable and lazer beatmap package downloads" },
    .{ .feature = .website_writes, .label = "website writes", .group = "website", .description = "profile, settings, teams, chat and appeal changes; staff recovery stays available" },
};

pub fn definition(feature: Feature) Definition {
    for (definitions) |item| if (item.feature == feature) return item;
    unreachable;
}

test "server controls accept only the fixed production surface" {
    for (definitions) |item| {
        try std.testing.expectEqual(item.feature, Feature.parse(item.feature.key()).?);
        try std.testing.expect(item.label.len != 0);
        try std.testing.expect(item.group.len != 0);
        try std.testing.expect(item.description.len != 0);
    }
    try std.testing.expect(Feature.parse("shell") == null);
    try std.testing.expect(Feature.parse("database") == null);
}
