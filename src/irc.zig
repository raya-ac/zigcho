const std = @import("std");

pub const server_name = "irc.kai.ovh";
pub const max_line_bytes: usize = 510;
pub const max_parameters: usize = 15;

pub const Command = struct {
    verb: []const u8,
    parameters: [max_parameters][]const u8 = [_][]const u8{""} ** max_parameters,
    parameter_count: usize = 0,

    pub fn parameter(self: Command, index: usize) ?[]const u8 {
        return if (index < self.parameter_count) self.parameters[index] else null;
    }

    pub fn is(self: Command, verb: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.verb, verb);
    }
};

pub fn parseCommand(raw: []const u8) !?Command {
    if (raw.len > max_line_bytes) return error.LineTooLong;
    if (std.mem.indexOfScalar(u8, raw, 0) != null or !std.unicode.utf8ValidateSlice(raw)) return error.InvalidLine;
    const line = std.mem.trim(u8, raw, " \t\r\n");
    if (line.len == 0) return null;
    if (line[0] == ':') return error.ClientPrefixForbidden;

    var command: Command = undefined;
    command.parameters = [_][]const u8{""} ** max_parameters;
    command.parameter_count = 0;
    const verb_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    command.verb = line[0..verb_end];
    if (!validVerb(command.verb)) return error.InvalidCommand;

    var cursor = verb_end;
    while (cursor < line.len) {
        while (cursor < line.len and (line[cursor] == ' ' or line[cursor] == '\t')) cursor += 1;
        if (cursor == line.len) break;
        if (command.parameter_count == max_parameters) return error.TooManyParameters;
        if (line[cursor] == ':') {
            command.parameters[command.parameter_count] = line[cursor + 1 ..];
            command.parameter_count += 1;
            break;
        }
        const end = std.mem.indexOfAnyPos(u8, line, cursor, " \t") orelse line.len;
        command.parameters[command.parameter_count] = line[cursor..end];
        command.parameter_count += 1;
        cursor = end;
    }
    return command;
}

fn validVerb(value: []const u8) bool {
    if (value.len == 0 or value.len > 16) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte)) return false;
    return true;
}

pub fn validNick(value: []const u8) bool {
    if (value.len == 0 or value.len > 32 or !std.ascii.isAlphabetic(value[0])) return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '-', '_', '[', ']', '\\', '`', '^', '{', '}', '|' => {},
            else => return false,
        }
    }
    return true;
}

pub fn channelMask(name: []const u8) ?u8 {
    if (std.ascii.eqlIgnoreCase(name, "#osu")) return 1 << 0;
    if (std.ascii.eqlIgnoreCase(name, "#announce")) return 1 << 1;
    if (std.ascii.eqlIgnoreCase(name, "#lobby")) return 1 << 2;
    if (std.ascii.eqlIgnoreCase(name, "#lazer")) return 1 << 3;
    return null;
}

pub fn canonicalChannel(name: []const u8) ?[]const u8 {
    const mask = channelMask(name) orelse return null;
    return switch (mask) {
        1 << 0 => "#osu",
        1 << 1 => "#announce",
        1 << 2 => "#lobby",
        1 << 3 => "#lazer",
        else => unreachable,
    };
}

pub fn channelForId(id: i64) ?[]const u8 {
    return switch (id) {
        1 => "#osu",
        2 => "#announce",
        3 => "#lobby",
        4 => "#lazer",
        else => null,
    };
}

pub fn writeCleanText(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '\r', '\n', 0 => try writer.writeByte(' '),
        else => try writer.writeByte(byte),
    };
}

pub fn writeMessage(writer: *std.Io.Writer, sender: []const u8, target: []const u8, content: []const u8, action: bool) !void {
    try writer.writeByte(':');
    try writeCleanText(writer, sender);
    try writer.writeAll("!zigcho@kai.ovh PRIVMSG ");
    try writeCleanText(writer, target);
    try writer.writeAll(" :");
    if (action) try writer.writeByte(0x01);
    if (action) try writer.writeAll("ACTION ");
    try writeCleanText(writer, content);
    if (action) try writer.writeByte(0x01);
    try writer.writeAll("\r\n");
}

test "irc command parser keeps trailing parameters intact" {
    const command = (try parseCommand("PRIVMSG #osu :hello from the website\r")).?;
    try std.testing.expect(command.is("privmsg"));
    try std.testing.expectEqual(@as(usize, 2), command.parameter_count);
    try std.testing.expectEqualStrings("#osu", command.parameter(0).?);
    try std.testing.expectEqualStrings("hello from the website", command.parameter(1).?);
    try std.testing.expectError(error.ClientPrefixForbidden, parseCommand(":forged PRIVMSG #osu :no"));
    try std.testing.expectError(error.LineTooLong, parseCommand(&([_]u8{'x'} ** (max_line_bytes + 1))));
}

test "irc names and channels stay bounded" {
    try std.testing.expect(validNick("raya"));
    try std.testing.expect(validNick("ari_raya"));
    try std.testing.expect(!validNick("3raya"));
    try std.testing.expect(!validNick("raya name"));
    try std.testing.expectEqualStrings("#announce", canonicalChannel("#ANNOUNCE").?);
    try std.testing.expect(channelMask("#unknown") == null);
}

test "irc output cannot inject a second protocol line" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeMessage(&output.writer, "raya", "#osu", "hello\r\nQUIT :oops", false);
    try std.testing.expectEqualStrings(":raya!zigcho@kai.ovh PRIVMSG #osu :hello  QUIT :oops\r\n", output.written());
}
