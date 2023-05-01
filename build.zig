const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_args = b.dependency("zig_args", .{
        .target = target,
        .optimize = optimize,
    }).module("args");

    const exe = b.addExecutable(.{
        .name = "confgen",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.strip = optimize != .Debug and optimize != .ReleaseSafe;
    setupExe(exe, zig_args);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    setupExe(exe_tests, zig_args);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}

fn setupExe(exe: *std.Build.CompileStep, zig_args: *std.Build.Module) void {
    exe.linkLibC();
    exe.linkSystemLibrary("luajit");

    exe.addModule("args", zig_args);

    exe.unwind_tables = true;
}
