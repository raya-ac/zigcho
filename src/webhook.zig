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
        total_score: i64,
        max_combo: i32,
        accuracy: f64,
        pp: f64,
        stars: f64,
        n300: i32,
        n100: i32,
        n50: i32,
        nmiss: i32,
        perfect: bool,
        artist: []const u8,
        title: []const u8,
        version: []const u8,
        set_id: i32,
    };

    pub fn postScore(self: *Webhook, data: ScoreData) void {
        if (self.url.len == 0) return;
        var buf: [4096]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{s}", .{formatPayload(data)}) catch return;
        self.doPost(json) catch {};
    }

    fn doPost(self: *Webhook, json: []const u8) !void {
        var writer = std.Io.Writer.fixed(&.{});
        _ = self.client.fetch(.{
            .location = .{ .url = self.url },
            .method = .POST,
            .payload = json,
            .response_writer = &writer,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .user_agent = .{ .override = "zigcho/0.1" },
            },
        }) catch {};
    }

    fn formatPayload(data: ScoreData) std.fmt.Formatter(formatPayloadFn) {
        return .{ .data = data };
    }

    fn formatPayloadFn(data: ScoreData, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        const display_grade = gradeDisplay(data.grade);
        const color = gradeColor(data.grade);
        const avatar = std.fmt.allocPrint(data.allocator, "https://a.kai.ovh/{d}", .{data.user_id}) catch "";
        defer data.allocator.free(avatar);
        const cover = std.fmt.allocPrint(data.allocator, "https://assets.ppy.sh/beatmaps/{d}/covers/raw.jpg", .{data.set_id}) catch "";
        defer data.allocator.free(cover);
        const mods_str = modString(data.allocator, data.mods) catch "";
        defer data.allocator.free(mods_str);

        try writer.writeAll("{\"username\":");
        try std.json.encodeJsonString(data.username, .{}, writer);
        try writer.print(",\"avatar_url\":\"{s}\",\"embeds\":[{{\"color\":{d},\"author\":{{\"name\":", .{ avatar, color });
        try std.json.encodeJsonString(data.username, .{}, writer);
        try writer.print(",\"icon_url\":\"{s}\"}},\"title\":\"{s}\",\"description\":\"", .{avatar, display_grade});
        try std.json.encodeJsonString(data.artist, .{}, writer);
        try writer.writeAll(" - ");
        try std.json.encodeJsonString(data.title, .{}, writer);
        try writer.writeAll(" [");
        try std.json.encodeJsonString(data.version, .{}, writer);
        try writer.writeAll("\",\"image\":{\"url\":\"");
        try std.json.encodeJsonString(cover, .{}, writer);
        try writer.print("\"}},\"fields\":[{{\"name\":\"★ {d:.2}\",\"value\":\"**{d}x** combo | **{d:.2}%** acc | **{d:.2}pp**\",\"inline\":false}},{{\"name\":\"Score\",\"value\":\"{d}\",\"inline\":true}},{{\"name\":\"Mods\",\"value\":\"{s}\",\"inline\":true}}", .{ data.stars, data.max_combo, data.accuracy * 100.0, data.pp, data.total_score, mods_str });
        if (data.perfect) try writer.writeAll(",{\"name\":\"FC\",\"value\":\"Yes\",\"inline\":true}");
        try writer.writeAll("]}]}");
    }

    fn gradeDisplay(grade: []const u8) []const u8 {
        if (std.mem.eql(u8, grade, "XH")) return "SS";
        if (std.mem.eql(u8, grade, "X")) return "SS";
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

    fn modString(allocator: std.mem.Allocator, mods: i32) ![]u8 {
        if (mods == 0) return try allocator.dupe(u8, "NM");
        var list = std.ArrayList(u8).init(allocator);
        errdefer list.deinit();
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
                try list.appendSlice(m.name);
            }
        }
        if (list.items.len == 0) return try allocator.dupe(u8, "NM");
        return list.toOwnedSlice();
    }
};
