const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cargo = b.addSystemCommand(&.{ "cargo", "build", "--manifest-path", "pp/Cargo.toml", "--release", "--locked" });
    const pp_library = b.path(if (target.result.os.tag == .windows) "pp/target/release/zigcho_pp.lib" else "pp/target/release/libzigcho_pp.a");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.linkSystemLibrary("sqlite3", .{});
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

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the server").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    tests.root_module.linkSystemLibrary("sqlite3", .{});
    if (target.result.os.tag == .linux) tests.root_module.linkSystemLibrary("gcc_s", .{});
    tests.root_module.addObjectFile(pp_library);
    tests.step.dependOn(&cargo.step);
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run all tests").dependOn(&run_tests.step);
}
