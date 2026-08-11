const std = @import("std");
const storage = @import("runtime_storage.zig");
const form_urlencoded = @import("form_urlencoded.zig");

pub const FieldError = enum {
    none,
    invalid_username,
    username_taken,
    invalid_email,
    email_taken,
    invalid_password,
};

pub const Validation = struct {
    username: FieldError = .none,
    email: FieldError = .none,
    password: FieldError = .none,

    pub fn any(self: Validation) bool {
        return self.username != .none or self.email != .none or self.password != .none;
    }
};

pub const StableResult = union(enum) {
    ok,
    validation_failed: Validation,
};

fn validUsername(value: []const u8) bool {
    if (value.len < 2 or value.len > 15) return false;
    if (std.mem.indexOfScalar(u8, value, '_') != null and std.mem.indexOfScalar(u8, value, ' ') != null) return false;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == ' ' or byte == '[' or byte == ']' or byte == '-')) return false;
    return true;
}

fn validEmail(value: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, value, '@') orelse return false;
    if (at == 0 or at > 200 or std.mem.indexOfScalarPos(u8, value, at + 1, '@') != null) return false;
    for (value[0..at]) |byte| if (std.ascii.isWhitespace(byte)) return false;
    var labels = std.mem.splitScalar(u8, value[at + 1 ..], '.');
    const first = labels.next() orelse return false;
    if (first.len == 0 or first.len > 30) return false;
    for (first) |byte| if (byte == '@' or std.ascii.isWhitespace(byte)) return false;
    var suffixes: usize = 0;
    while (labels.next()) |label| {
        if (label.len < 2 or label.len > 24) return false;
        for (label) |byte| if (byte == '@' or std.ascii.isWhitespace(byte)) return false;
        suffixes += 1;
    }
    return suffixes != 0;
}

fn validPassword(value: []const u8) bool {
    if (value.len < 8 or value.len > 32) return false;
    var seen = [_]bool{false} ** 256;
    var unique: usize = 0;
    for (value) |byte| if (!seen[byte]) {
        seen[byte] = true;
        unique += 1;
    };
    return unique > 3;
}

pub fn validate(store: *storage.Store, name: []const u8, email: []const u8, password: []const u8) !Validation {
    var result: Validation = .{};
    if (!validUsername(name)) result.username = .invalid_username;
    if (!validEmail(email)) result.email = .invalid_email;
    if (!validPassword(password)) result.password = .invalid_password;
    const conflicts = try store.registrationConflicts(name, email);
    if (result.username == .none and conflicts.username) result.username = .username_taken;
    if (result.email == .none and conflicts.email) result.email = .email_taken;
    return result;
}

pub fn stableRequest(store: *storage.Store, name: []const u8, email: []const u8, password: []const u8, check: []const u8) !StableResult {
    const check_value = std.fmt.parseInt(i32, check, 10) catch return error.InvalidCheck;
    const validation = try validate(store, name, email, password);
    if (validation.any()) return .{ .validation_failed = validation };
    if (check_value != 0) return .ok;
    const password_md5 = try form_urlencoded.credentialMd5(password);
    _ = store.register(name, email, &password_md5) catch |err| switch (err) {
        error.UserExists => return .{ .validation_failed = .{ .username = .username_taken } },
        else => return err,
    };
    return .ok;
}

fn message(field_error: FieldError) []const u8 {
    return switch (field_error) {
        .invalid_username => "Must be 2-15 characters and use letters, numbers, spaces, underscores, brackets, or dashes.",
        .username_taken => "Username already taken by another player.",
        .invalid_email => "Invalid email syntax.",
        .email_taken => "Email already taken by another player.",
        .invalid_password => "Must be 8-32 characters with more than 3 unique characters.",
        .none => "",
    };
}

pub fn writeStableErrors(buffer: []u8, validation: Validation) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("{\"form_error\":{\"user\":{");
    var first = true;
    const fields = [_]struct { name: []const u8, value: FieldError }{
        .{ .name = "username", .value = validation.username },
        .{ .name = "user_email", .value = validation.email },
        .{ .name = "password", .value = validation.password },
    };
    for (fields) |field| {
        if (field.value == .none) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("\"{s}\":[\"{s}\"]", .{ field.name, message(field.value) });
    }
    try writer.writeAll("}}}");
    return buffer[0..writer.end];
}
