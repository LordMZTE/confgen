const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_confgenfs = b.option(
        bool,
        "confgenfs",
        "Build and install confgenfs",
    ) orelse true;

    const zig_args = b.dependency("zig_args", .{
        .target = target,
        .optimize = optimize,
    }).module("args");

    const libcg = b.createModule(.{
        .root_source_file = b.path("libcg/main.zig"),
        .link_libc = true,
        // required for luajit errors
        .unwind_tables = .@"async",
        .target = target,
        .optimize = optimize,
    });

    libcg.linkSystemLibrary("luajit", .{});

    const libcg_test = b.addTest(.{ .root_module = libcg });

    const confgen = b.addModule("confgen", .{
        .root_source_file = b.path("confgen/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "args", .module = zig_args },
            .{ .name = "libcg", .module = libcg },
        },
    });

    const confgen_exe = b.addExecutable(.{
        .name = "confgen",
        .root_module = confgen,
    });

    b.installArtifact(confgen_exe);

    b.installDirectory(.{
        .source_dir = b.path("share"),
        .install_dir = .{ .custom = "share" },
        .install_subdir = ".",
    });

    const run_confgen_cmd = b.addRunArtifact(confgen_exe);
    run_confgen_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_confgen_cmd.addArgs(args);
    }

    const run_confgen_step = b.step("run-confgen", "Run the confgen binary");
    run_confgen_step.dependOn(&run_confgen_cmd.step);

    const confgen_test = b.addTest(.{ .root_module = confgen });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(libcg_test).step);
    test_step.dependOn(&b.addRunArtifact(confgen_test).step);

    if (enable_confgenfs) {
        const confgenfs = b.addModule("confgenfs", .{
            .root_source_file = b.path("confgenfs/main.zig"),
            .link_libc = true,
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "args", .module = zig_args },
                .{ .name = "libcg", .module = libcg },
            },
        });
        confgenfs.linkSystemLibrary("fuse3", .{});

        const confgenfs_exe = b.addExecutable(.{
            .name = "confgenfs",
            .root_module = confgenfs,
        });

        b.installArtifact(confgenfs_exe);

        const run_confgenfs_cmd = b.addRunArtifact(confgenfs_exe);
        run_confgenfs_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_confgenfs_cmd.addArgs(args);
        }

        const run_confgenfs_step = b.step("run-confgenfs", "Run the confgenfs binary");
        run_confgenfs_step.dependOn(&run_confgenfs_cmd.step);

        const confgenfs_test = b.addTest(.{ .root_module = confgenfs });
        test_step.dependOn(&b.addRunArtifact(confgenfs_test).step);
    }
}
