const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_args = b.dependency("zig_args", .{
        .target = target,
        .optimize = optimize,
    }).module("args");

    const libcg = b.createModule(.{
        .root_source_file = .{ .path = "libcg/main.zig" },
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });

    // required for luajit errors
    libcg.unwind_tables = true;
    libcg.linkSystemLibrary("luajit", .{});

    const confgen_exe = b.addExecutable(.{
        .name = "confgen",
        .root_source_file = .{ .path = "confgen/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    confgen_exe.root_module.addImport("args", zig_args);
    confgen_exe.root_module.addImport("libcg", libcg);

    b.installArtifact(confgen_exe);

    const run_confgen_cmd = b.addRunArtifact(confgen_exe);
    run_confgen_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_confgen_cmd.addArgs(args);
    }

    const run_confgen_step = b.step("run-confgen", "Run the confgen binary");
    run_confgen_step.dependOn(&run_confgen_cmd.step);

    const exe_confgen_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });
    exe_confgen_tests.root_module.addImport("args", zig_args);
    exe_confgen_tests.root_module.addImport("libcg", libcg);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(exe_confgen_tests).step);
}

