const std = @import("std");

pub const sqlite_schema = @embedFile("sqlite/schema.sql");
pub const postgres_schema = @embedFile("postgres/schema.sql");
pub const performance_fixture = @embedFile("postgres/tests/performance_fixture.sql");
pub const profile_firsts_all = @embedFile("postgres/queries/profile_firsts_all.sql");
pub const profile_firsts_all_reference = @embedFile("postgres/tests/profile_firsts_all_reference.sql");
pub const profile_firsts_stable = @embedFile("postgres/queries/profile_firsts_stable.sql");
pub const profile_firsts_stable_reference = @embedFile("postgres/tests/profile_firsts_stable_reference.sql");
pub const profile_firsts_lazer = @embedFile("postgres/queries/profile_firsts_lazer.sql");
pub const profile_firsts_lazer_reference = @embedFile("postgres/tests/profile_firsts_lazer_reference.sql");

pub fn sqliteMigration(comptime version: u16) [:0]const u8 {
    return @embedFile(std.fmt.comptimePrint("sqlite/migrations/{d:0>3}.sql", .{version}));
}

pub fn postgresMigration(comptime version: u16) [:0]const u8 {
    return @embedFile(std.fmt.comptimePrint("postgres/migrations/{d:0>3}.sql", .{version}));
}
