const std = @import("std");

pub const Part = struct {
    name: []const u8,
    filename: ?[]const u8,
    content_type: ?[]const u8,
    data: []const u8,
};

pub const Form = struct {
    allocator: std.mem.Allocator,
    parts: std.ArrayList(Part) = .empty,

    pub fn deinit(self: *Form) void {
        self.parts.deinit(self.allocator);
    }
    pub fn first(self: *const Form, name: []const u8) ?Part {
        for (self.parts.items) |part| if (std.mem.eql(u8, part.name, name)) return part;
        return null;
    }
    pub fn nth(self: *const Form, name: []const u8, wanted: usize) ?Part {
        var found: usize = 0;
        for (self.parts.items) |part| if (std.mem.eql(u8, part.name, name)) {
            if (found == wanted) return part;
            found += 1;
        };
        return null;
    }
};

pub fn boundaryFromContentType(content_type: []const u8) ![]const u8 {
    var fields = std.mem.splitScalar(u8, content_type, ';');
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, fields.next() orelse "", " \t"), "multipart/form-data")) return error.NotMultipart;
    while (fields.next()) |field| {
        const trimmed = std.mem.trim(u8, field, " \t");
        if (std.mem.startsWith(u8, trimmed, "boundary=")) {
            var value = trimmed[9..];
            if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
            if (value.len == 0 or value.len > 200 or std.mem.findAny(u8, value, "\r\n") != null) return error.InvalidBoundary;
            return value;
        }
    }
    return error.MissingBoundary;
}

pub fn parse(allocator: std.mem.Allocator, body: []const u8, boundary: []const u8) !Form {
    var form: Form = .{ .allocator = allocator };
    errdefer form.deinit();
    var marker_buf: [204]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buf, "--{s}", .{boundary});
    var delimiter_buf: [204]u8 = undefined;
    const delimiter = try std.fmt.bufPrint(&delimiter_buf, "\r\n--{s}", .{boundary});
    if (!std.mem.startsWith(u8, body, marker)) return error.InvalidMultipart;
    var cursor: usize = marker.len;
    while (true) {
        if (cursor + 2 > body.len) return error.IncompleteMultipart;
        if (std.mem.eql(u8, body[cursor..][0..2], "--")) {
            cursor += 2;
            if (cursor == body.len or std.mem.eql(u8, body[cursor..], "\r\n")) return form;
            return error.InvalidMultipart;
        }
        if (!std.mem.eql(u8, body[cursor..][0..2], "\r\n")) return error.InvalidMultipart;
        cursor += 2;
        const headers_end = std.mem.findPosLinear(u8, body, cursor, "\r\n\r\n") orelse return error.IncompleteMultipart;
        const headers = body[cursor..headers_end];
        cursor = headers_end + 4;
        const next_delimiter_pos = findDelimiter(body, cursor, delimiter) orelse return error.IncompleteMultipart;
        const data = body[cursor..next_delimiter_pos];
        cursor = next_delimiter_pos + delimiter.len;

        var name: ?[]const u8 = null;
        var filename: ?[]const u8 = null;
        var part_type: ?[]const u8 = null;
        var lines = std.mem.splitSequence(u8, headers, "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.findScalar(u8, line, ':') orelse return error.InvalidPartHeader;
            const header_name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(header_name, "content-disposition")) {
                name = dispositionValue(value, "name");
                filename = dispositionValue(value, "filename");
            } else if (std.ascii.eqlIgnoreCase(header_name, "content-type")) {
                part_type = value;
            }
        }
        try form.parts.append(allocator, .{ .name = name orelse return error.MissingPartName, .filename = filename, .content_type = part_type, .data = data });
        if (form.parts.items.len > 64) return error.TooManyParts;
    }
}

fn findDelimiter(body: []const u8, start: usize, delimiter: []const u8) ?usize {
    var cursor = start;
    while (std.mem.findPosLinear(u8, body, cursor, delimiter)) |position| {
        const suffix = position + delimiter.len;
        if (suffix + 2 <= body.len and
            (std.mem.eql(u8, body[suffix..][0..2], "--") or std.mem.eql(u8, body[suffix..][0..2], "\r\n"))) return position;
        cursor = suffix;
    }
    return null;
}

fn dispositionValue(value: []const u8, key: []const u8) ?[]const u8 {
    var fields = std.mem.splitScalar(u8, value, ';');
    _ = fields.next();
    while (fields.next()) |field| {
        const trimmed = std.mem.trim(u8, field, " \t");
        const eq = std.mem.findScalar(u8, trimmed, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(trimmed[0..eq], key)) continue;
        const raw = trimmed[eq + 1 ..];
        if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') return raw[1 .. raw.len - 1];
        return raw;
    }
    return null;
}
