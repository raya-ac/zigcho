const std = @import("std");

pub fn registration(buffer: []u8, id: i32, name: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.print("{{\"id\":{d},\"name\":", .{id});
    try std.json.Stringify.value(name, .{}, &writer);
    try writer.writeByte('}');
    return buffer[0..writer.end];
}

pub fn me(buffer: []u8, id: i32, name: []const u8, country: [2]u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.print("{{\"id\":{d},\"username\":", .{id});
    try std.json.Stringify.value(name, .{}, &writer);
    try writer.print(",\"avatar_url\":\"https://a.kai.ovh/{d}\",\"country_code\":", .{id});
    try std.json.Stringify.value(&country, .{}, &writer);
    try writer.writeAll(",\"is_active\":true,\"is_online\":true,\"statistics_rulesets\":{}}");
    return buffer[0..writer.end];
}

test "user JSON escapes imported names" {
    var buffer: [512]u8 = undefined;
    const registration_json = try registration(&buffer, 4, "raya\"},\"admin\":true");
    var parsed_registration = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, registration_json, .{});
    defer parsed_registration.deinit();
    try std.testing.expectEqualStrings("raya\"},\"admin\":true", parsed_registration.value.object.get("name").?.string);
    try std.testing.expect(parsed_registration.value.object.get("admin") == null);

    const me_json = try me(&buffer, 4, "line\nbreak", .{ 'A', 'U' });
    var parsed_me = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, me_json, .{});
    defer parsed_me.deinit();
    try std.testing.expectEqualStrings("line\nbreak", parsed_me.value.object.get("username").?.string);
    try std.testing.expectEqualStrings("AU", parsed_me.value.object.get("country_code").?.string);

    const imported_country_json = try me(&buffer, 4, "raya", .{ '"', '\\' });
    var parsed_country = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, imported_country_json, .{});
    defer parsed_country.deinit();
    try std.testing.expectEqualStrings("\"\\", parsed_country.value.object.get("country_code").?.string);
}
