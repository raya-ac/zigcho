const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const postgres_prefix = b.option([]const u8, "postgres-prefix", "PostgreSQL installation prefix (macOS defaults to Homebrew postgresql@17)");
    const postgres_runtime = b.option(bool, "postgres", "Build the server with PostgreSQL runtime storage") orelse false;

    const cargo = b.addSystemCommand(&.{ "cargo", "build", "--manifest-path", "pp/Cargo.toml", "--release", "--locked" });
    const pp_library = b.path(if (target.result.os.tag == .windows) "pp/target/release/zigcho_pp.lib" else "pp/target/release/libzigcho_pp.a");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
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
    const archive_importer = b.addExecutable(.{ .name = "zigcho-import-archive", .root_module = archive_importer_mod });
    b.installArtifact(archive_importer);

    const postgres_importer_mod = b.createModule(.{
        .root_source_file = b.path("src/migrate_postgres.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    postgres_importer_mod.linkSystemLibrary("sqlite3", .{});
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
    const test_options = b.addOptions();
    test_options.addOption(bool, "postgres_runtime", false);
    test_mod.addOptions("build_options", test_options);
    const tests = b.addTest(.{ .root_module = test_mod });
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
    b.step("test", "Run all tests").dependOn(&run_tests.step);

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
