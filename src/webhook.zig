const std = @import("std");
const domain = @import("domain.zig");
const stable_mods = @import("stable_mods.zig");

pub fn shouldAnnounceScore(placement: ?domain.ScorePlacement, pp_value: f64) bool {
    const current = placement orelse return false;
    return current.submitted_is_best and current.rank >= 0 and current.rank < 50 and (current.rank < 10 or pp_value >= 500.0);
}

pub const Webhook = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: std.http.Client,
    url: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, url: []const u8) Webhook {
        return .{
            .allocator = allocator,
            .io = io,
            .client = .{ .allocator = allocator, .io = io },
            .url = url,
        };
    }

    pub fn deinit(self: *Webhook) void {
        self.client.deinit();
    }

    pub const ScoreData = struct {
        username: []const u8,
        user_id: i32,
        grade: []const u8,
        mods: i32,
        mods_text: ?[]const u8 = null,
        mode: u8,
        rank: i32,
        total_score: i64,
        max_combo: i32,
        beatmap_max_combo: i32,
        accuracy: f64,
        pp: f64,
        stars: f64,
        perfect: bool,
        artist: []const u8,
        title: []const u8,
        version: []const u8,
        set_id: i32,
    };

    pub fn postScore(self: *Webhook, data: ScoreData) void {
        if (self.url.len == 0) return;
        var buf: [4096]u8 = undefined;
        var mod_buf: [64]u8 = undefined;
        const json = buildJson(&buf, &mod_buf, data) catch return;
        const json_owned = self.allocator.dupe(u8, json) catch return;
        const url_owned = self.allocator.dupe(u8, self.url) catch {
            self.allocator.free(json_owned);
            return;
        };
        const io = self.io;
        const thread = std.Thread.spawn(.{}, webhookThread, .{ self.allocator, io, url_owned, json_owned }) catch return;
        thread.detach();
    }

    fn webhookThread(allocator: std.mem.Allocator, io: std.Io, url: []const u8, json: []const u8) void {
        defer allocator.free(json);
        defer allocator.free(url);
        var client = std.http.Client{ .allocator = allocator, .io = io };
        defer client.deinit();
        var response_buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&response_buf);
        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = json,
            .response_writer = &writer,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .user_agent = .{ .override = "zigcho/0.1" },
            },
        }) catch |err| {
            std.log.warn("webhook post failed: {t}", .{err});
            return;
        };
        if (@intFromEnum(result.status) >= 400) {
            std.log.warn("webhook returned status {d}", .{@intFromEnum(result.status)});
        }
    }

    fn buildJson(buf: *[4096]u8, mod_buf: *[64]u8, data: ScoreData) ![]const u8 {
        const display_grade = gradeDisplay(data.grade);
        const color = gradeColor(data.grade);
        const mods_str = data.mods_text orelse stable_mods.shortString(mod_buf, data.mods);
        const mode_str = modeName(data.mode);
        var w = std.Io.Writer.fixed(buf);
        try w.writeAll("{\"username\":");
        try std.json.Stringify.value(data.username, .{}, &w);
        try w.print(",\"avatar_url\":\"https://a.kai.ovh/{d}\",\"embeds\":[{{\"color\":{d},\"author\":{{\"name\":", .{ data.user_id, color });
        try std.json.Stringify.value(data.username, .{}, &w);
        try w.print(",\"icon_url\":\"https://a.kai.ovh/{d}\"}},\"title\":\"{s}\",\"description\":", .{ data.user_id, display_grade });
        var desc_buf: [512]u8 = undefined;
        var desc_w = std.Io.Writer.fixed(&desc_buf);
        try desc_w.writeAll(data.artist);
        try desc_w.writeAll(" - ");
        try desc_w.writeAll(data.title);
        try desc_w.writeAll(" [");
        try desc_w.writeAll(data.version);
        try desc_w.writeAll("]");
        try std.json.Stringify.value(desc_buf[0..desc_w.end], .{}, &w);
        try w.print(",\"image\":{{\"url\":\"https://assets.ppy.sh/beatmaps/{d}/covers/raw.jpg\"}},\"fields\":[", .{data.set_id});
        try w.print("{{\"name\":\"★ {d:.2}\",\"value\":\"#{d} on the map\",\"inline\":false}},", .{ data.stars, data.rank });
        if (data.beatmap_max_combo > 0) {
            const pct: f64 = @as(f64, @floatFromInt(data.max_combo)) / @as(f64, @floatFromInt(data.beatmap_max_combo)) * 100.0;
            try w.print("{{\"name\":\"Combo\",\"value\":\"{d}/{d} ({d:.0}%)\",\"inline\":true}},", .{ data.max_combo, data.beatmap_max_combo, pct });
        } else {
            try w.print("{{\"name\":\"Combo\",\"value\":\"{d}x\",\"inline\":true}},", .{data.max_combo});
        }
        try w.print("{{\"name\":\"Accuracy\",\"value\":\"{d:.2}%\",\"inline\":true}},", .{data.accuracy * 100.0});
        try w.print("{{\"name\":\"PP\",\"value\":\"{d:.2}\",\"inline\":true}},", .{data.pp});
        try w.print("{{\"name\":\"Score\",\"value\":\"{d}\",\"inline\":true}},", .{data.total_score});
        try w.writeAll("{\"name\":\"Mods\",\"value\":");
        try std.json.Stringify.value(mods_str, .{}, &w);
        try w.writeAll(",\"inline\":true},");
        try w.print("{{\"name\":\"Mode\",\"value\":\"{s}\",\"inline\":true}}", .{mode_str});
        if (data.perfect) try w.writeAll(",{\"name\":\"FC\",\"value\":\"Yes\",\"inline\":true}");
        try w.writeAll("]}]}");
        return buf[0..w.end];
    }

    fn gradeDisplay(grade: []const u8) []const u8 {
        if (std.mem.eql(u8, grade, "XH") or std.mem.eql(u8, grade, "X")) return "SS";
        if (std.mem.eql(u8, grade, "SH")) return "S";
        return grade;
    }

    fn gradeColor(grade: []const u8) u24 {
        if (std.mem.eql(u8, grade, "XH") or std.mem.eql(u8, grade, "X")) return 0xFFD700;
        if (std.mem.eql(u8, grade, "SH") or std.mem.eql(u8, grade, "S")) return 0xC0C0C0;
        if (std.mem.eql(u8, grade, "A")) return 0x00FF00;
        if (std.mem.eql(u8, grade, "B")) return 0x00BFFF;
        if (std.mem.eql(u8, grade, "C")) return 0xFFA500;
        if (std.mem.eql(u8, grade, "D")) return 0xFF4500;
        return 0xFF0000;
    }

    fn modeName(mode: u8) []const u8 {
        return switch (mode) {
            0 => "osu!",
            1 => "osu!taiko",
            2 => "osu!catch",
            3 => "osu!mania",
            else => "osu!",
        };
    }
};

test "score webhook renders the score specific modded star rating" {
    var buffer: [4096]u8 = undefined;
    var mod_buffer: [64]u8 = undefined;
    const json = try Webhook.buildJson(&buffer, &mod_buffer, .{
        .username = "ari",
        .user_id = 1,
        .grade = "S",
        .mods = 16,
        .mode = 0,
        .rank = 2,
        .total_score = 1_000_000,
        .max_combo = 500,
        .beatmap_max_combo = 600,
        .accuracy = 0.9876,
        .pp = 424.5,
        .stars = 6.42,
        .perfect = false,
        .artist = "artist",
        .title = "title",
        .version = "difficulty",
        .set_id = 75,
    });
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"★ 6.42\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"value\":\"HR\"") != null);
}

test "score webhook safely renders lazer mod adjustments" {
    var buffer: [4096]u8 = undefined;
    var mod_buffer: [64]u8 = undefined;
    const json = try Webhook.buildJson(&buffer, &mod_buffer, .{
        .username = "ari",
        .user_id = 1,
        .grade = "A",
        .mods = 0,
        .mods_text = "+DT 1.25×DA (AR 9.50, hidden on)",
        .mode = 0,
        .rank = 1,
        .total_score = 900_000,
        .max_combo = 400,
        .beatmap_max_combo = 500,
        .accuracy = 0.98,
        .pp = 300,
        .stars = 5,
        .perfect = false,
        .artist = "artist",
        .title = "title",
        .version = "difficulty",
        .set_id = 75,
    });
    try std.testing.expect(std.mem.indexOf(u8, json, "DT 1.25×DA (AR 9.50, hidden on)") != null);
}
