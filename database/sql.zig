const std = @import("std");

pub const sqlite_schema = @embedFile("sqlite/schema.sql");
pub const postgres_schema = @embedFile("postgres/schema.sql");

pub fn sqliteMigration(comptime version: u16) [:0]const u8 {
    return @embedFile(std.fmt.comptimePrint("sqlite/migrations/{d:0>3}.sql", .{version}));
}

pub fn postgresMigration(comptime version: u16) [:0]const u8 {
    return @embedFile(std.fmt.comptimePrint("postgres/migrations/{d:0>3}.sql", .{version}));
}
