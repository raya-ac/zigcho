const std = @import("std");

fn isUpdateMarkdownName(name: []const u8) bool {
    if (name.len < "2000-01-01-a.md".len or !std.mem.endsWith(u8, name, ".md")) return false;
    for (name, 0..) |char, index| {
        const valid = if (index < 4 or (index >= 5 and index < 7) or (index >= 8 and index < 10))
            std.ascii.isDigit(char)
        else if (index == 4 or index == 7 or index == 10)
            char == '-'
        else if (index >= name.len - 3)
            (index == name.len - 3 and char == '.') or (index == name.len - 2 and char == 'm') or (index == name.len - 1 and char == 'd')
        else
            std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-';
        if (!valid) return false;
    }
    return true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const postgres_prefix = b.option([]const u8, "postgres-prefix", "PostgreSQL installation prefix (macOS defaults to Homebrew postgresql@17)");
    const postgres_runtime = b.option(bool, "postgres", "Build the server with PostgreSQL runtime storage") orelse false;
    const test_filter = b.option([]const u8, "test-filter", "Run only Zig tests containing this name");
    var test_filters: []const []const u8 = &.{};
    if (test_filter) |filter| {
        const selected = b.allocator.alloc([]const u8, 1) catch @panic("out of memory");
        selected[0] = filter;
        test_filters = selected;
    }

    const database_sql_mod = b.createModule(.{
        .root_source_file = b.path("database/sql.zig"),
    });

    const cargo = b.addSystemCommand(&.{ "cargo", "build", "--manifest-path", "pp/Cargo.toml", "--release", "--locked" });
    const pp_library = b.path(if (target.result.os.tag == .windows) "pp/target/release/zigcho_pp.lib" else "pp/target/release/libzigcho_pp.a");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const changelog_mod = b.createModule(.{
        .root_source_file = b.path("changelog_module.zig"),
        .target = target,
        .optimize = optimize,
    });
    const build_io = b.graph.io;
    const updates_dir = std.Io.Dir.cwd().openDir(build_io, "updates", .{ .iterate = true }) catch |err| std.debug.panic("cannot open updates/: {t}", .{err});
    defer updates_dir.close(build_io);
    var update_count: usize = 0;
    var update_manifest: u64 = 0;
    var update_iterator = updates_dir.iterate();
    while (update_iterator.next(build_io) catch |err| std.debug.panic("cannot read updates/: {t}", .{err})) |entry| {
        if (entry.kind != .file or !isUpdateMarkdownName(entry.name)) continue;
        update_count += 1;
        update_manifest ^= std.hash.Wyhash.hash(0, entry.name);
    }
    const changelog_options = b.addOptions();
    changelog_options.addOption(usize, "update_count", update_count);
    changelog_options.addOption(u64, "update_manifest", update_manifest);
    changelog_mod.addOptions("changelog_options", changelog_options);
    mod.addImport("changelog", changelog_mod);
    mod.addImport("database_sql", database_sql_mod);
    const server_options = b.addOptions();
    server_options.addOption(bool, "postgres_runtime", postgres_runtime);
    mod.addOptions("build_options", server_options);
    mod.linkSystemLibrary("sqlite3", .{});
    if (postgres_runtime) mod.linkSystemLibrary("pq", .{ .use_pkg_config = .no });
    if (postgres_runtime and target.result.os.tag == .macos) {
        const prefix = postgres_prefix orelse "/opt/homebrew/opt/postgresql@17";
        mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include/postgresql", .{prefix}) });
        mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib/postgresql", .{prefix}) });
    } else if (postgres_runtime and target.result.os.tag == .linux) {
        mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include/postgresql" });
    }
    if (target.result.os.tag == .linux) mod.linkSystemLibrary("gcc_s", .{});
    mod.addObjectFile(pp_library);

    const exe = b.addExecutable(.{ .name = "zigcho", .root_module = mod });
    exe.step.dependOn(&cargo.step);
    b.installArtifact(exe);

    const importer_mod = b.createModule(.{
        .root_source_file = b.path("src/import.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    importer_mod.linkSystemLibrary("sqlite3", .{});
    importer_mod.addImport("database_sql", database_sql_mod);
    if (target.result.os.tag == .linux) importer_mod.linkSystemLibrary("gcc_s", .{});
    importer_mod.addObjectFile(pp_library);
    const importer = b.addExecutable(.{ .name = "zigcho-import", .root_module = importer_mod });
    importer.step.dependOn(&cargo.step);
    b.installArtifact(importer);

    const archive_importer_mod = b.createModule(.{
        .root_source_file = b.path("src/import_archive.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    archive_importer_mod.linkSystemLibrary("sqlite3", .{});
    archive_importer_mod.addImport("database_sql", database_sql_mod);
    const archive_importer = b.addExecutable(.{ .name = "zigcho-import-archive", .root_module = archive_importer_mod });
    b.installArtifact(archive_importer);

    const postgres_importer_mod = b.createModule(.{
        .root_source_file = b.path("src/migrate_postgres.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    postgres_importer_mod.linkSystemLibrary("sqlite3", .{});
    postgres_importer_mod.addImport("database_sql", database_sql_mod);
    postgres_importer_mod.linkSystemLibrary("pq", .{ .use_pkg_config = .no });
    if (target.result.os.tag == .macos) {
        const prefix = postgres_prefix orelse "/opt/homebrew/opt/postgresql@17";
        postgres_importer_mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include/postgresql", .{prefix}) });
        postgres_importer_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib/postgresql", .{prefix}) });
    } else if (target.result.os.tag == .linux) {
        postgres_importer_mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include/postgresql" });
    }
    const postgres_importer = b.addExecutable(.{ .name = "zigcho-migrate-postgres", .root_module = postgres_importer_mod });
    b.installArtifact(postgres_importer);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the server").dependOn(&run.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("changelog", changelog_mod);
    test_mod.addImport("database_sql", database_sql_mod);
    const test_options = b.addOptions();
    test_options.addOption(bool, "postgres_runtime", false);
    test_mod.addOptions("build_options", test_options);
    const tests = b.addTest(.{ .root_module = test_mod, .filters = test_filters });
    tests.root_module.linkSystemLibrary("sqlite3", .{});
    tests.root_module.linkSystemLibrary("pq", .{ .use_pkg_config = .no });
    if (target.result.os.tag == .macos) {
        const prefix = postgres_prefix orelse "/opt/homebrew/opt/postgresql@17";
        tests.root_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include/postgresql", .{prefix}) });
        tests.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib/postgresql", .{prefix}) });
    } else if (target.result.os.tag == .linux) {
        tests.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/postgresql" });
    }
    if (target.result.os.tag == .linux) tests.root_module.linkSystemLibrary("gcc_s", .{});
    tests.root_module.addObjectFile(pp_library);
    tests.step.dependOn(&cargo.step);
    const run_tests = b.addRunArtifact(tests);
    const changelog_tests = b.addTest(.{ .root_module = changelog_mod, .filters = test_filters });
    const run_changelog_tests = b.addRunArtifact(changelog_tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_changelog_tests.step);

    const anticheat_smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/anticheat_host_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const anticheat_smoke = b.addExecutable(.{ .name = "zigcho-anticheat-host-smoke", .root_module = anticheat_smoke_mod });
    const run_anticheat_smoke = b.addRunArtifact(anticheat_smoke);
    if (b.args) |args| run_anticheat_smoke.addArgs(args);
    b.step("anticheat-smoke", "Load and exercise a private anticheat module").dependOn(&run_anticheat_smoke.step);
}
