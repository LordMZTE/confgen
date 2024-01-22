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
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });

    setupModule(&exe.root_module, zig_args);

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
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });
    setupModule(&exe_tests.root_module, zig_args);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}

fn setupModule(mod: *std.Build.Module, zig_args: *std.Build.Module) void {
    mod.linkSystemLibrary("luajit", .{});
    mod.addImport("args", zig_args);
    mod.unwind_tables = true;
}
