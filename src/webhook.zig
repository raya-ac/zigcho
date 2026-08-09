const std = @import("std");

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
        var mod_buf: [32]u8 = undefined;
        const json = buildJson(&buf, &mod_buf, data) catch return;
        self.doPost(json) catch |err| std.log.warn("webhook post failed: {t}", .{err});
    }

    fn doPost(self: *Webhook, json: []const u8) !void {
        var response_buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&response_buf);
        const result = self.client.fetch(.{
            .location = .{ .url = self.url },
            .method = .POST,
            .payload = json,
            .response_writer = &writer,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .user_agent = .{ .override = "zigcho/0.1" },
            },
        }) catch |err| return err;
        if (@intFromEnum(result.status) >= 400) {
            std.log.warn("webhook returned status {d}", .{@intFromEnum(result.status)});
        }
    }

    fn buildJson(buf: *[4096]u8, mod_buf: *[32]u8, data: ScoreData) ![]const u8 {
        const display_grade = gradeDisplay(data.grade);
        const color = gradeColor(data.grade);
        const mods_str = modString(mod_buf, data.mods);
        const mode_str = modeName(data.mode);
        var w = std.Io.Writer.fixed(buf);
        try w.writeAll("{\"username\":");
        try std.json.Stringify.value(data.username, .{}, &w);
        try w.print(",\"avatar_url\":\"https://a.kai.ovh/{d}\",\"embeds\":[{{\"color\":{d},\"author\":{{\"name\":", .{ data.user_id, color });
        try std.json.Stringify.value(data.username, .{}, &w);
        try w.print(",\"icon_url\":\"https://a.kai.ovh/{d}\"}},\"title\":\"{s}\",\"description\":\"", .{ data.user_id, display_grade });
        try std.json.Stringify.value(data.artist, .{}, &w);
        try w.writeAll(" - ");
        try std.json.Stringify.value(data.title, .{}, &w);
        try w.writeAll(" [");
        try std.json.Stringify.value(data.version, .{}, &w);
        try w.print("\",\"image\":{{\"url\":\"https://assets.ppy.sh/beatmaps/{d}/covers/raw.jpg\"}},\"fields\":[", .{data.set_id});
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
        try w.print("{{\"name\":\"Mods\",\"value\":\"{s}\",\"inline\":true}},", .{mods_str});
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

    fn modString(buf: *[32]u8, mods: i32) []const u8 {
        if (mods == 0) return "NM";
        var pos: usize = 0;
        const mod_names = [_]struct { bit: i32, name: []const u8 }{
            .{ .bit = 1 << 0, .name = "NF" },
            .{ .bit = 1 << 1, .name = "EZ" },
            .{ .bit = 1 << 3, .name = "HD" },
            .{ .bit = 1 << 4, .name = "HR" },
            .{ .bit = 1 << 5, .name = "SD" },
            .{ .bit = 1 << 6, .name = "DT" },
            .{ .bit = 1 << 7, .name = "RX" },
            .{ .bit = 1 << 8, .name = "HT" },
            .{ .bit = 1 << 10, .name = "NC" },
            .{ .bit = 1 << 12, .name = "FL" },
            .{ .bit = 1 << 13, .name = "AP" },
            .{ .bit = 1 << 14, .name = "SO" },
            .{ .bit = 1 << 15, .name = "AT" },
            .{ .bit = 1 << 16, .name = "CN" },
            .{ .bit = 1 << 17, .name = "TP" },
            .{ .bit = 1 << 20, .name = "FI" },
            .{ .bit = 1 << 22, .name = "RN" },
            .{ .bit = 1 << 23, .name = "CL" },
            .{ .bit = 1 << 27, .name = "V2" },
            .{ .bit = 1 << 29, .name = "MR" },
        };
        for (mod_names) |m| {
            if (mods & m.bit != 0) {
                @memcpy(buf[pos..][0..2], m.name);
                pos += 2;
            }
        }
        if (pos == 0) return "NM";
        return buf[0..pos];
    }
};
