const std = @import("std");
const Translator = @import("translate_c").Translator;

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

    const translate_c = b.dependency("translate_c", .{});

    const libcg_translator: Translator = .init(translate_c, .{
        .c_source_file = b.path("libcg/c.h"),
        .target = target,
        .optimize = optimize,
        .link_system_libs = &.{
            .{ .name = "luajit" },
        },
    });

    const libcg = b.createModule(.{
        .root_source_file = b.path("libcg/main.zig"),
        // required for luajit errors
        .unwind_tables = .async,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = libcg_translator.mod },
        },
    });

    const libcg_test = b.addTest(.{ .root_module = libcg, .name = "libcg test" });

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
    run_confgen_cmd.addPassthruArgs();

    const run_confgen_step = b.step("run-confgen", "Run the confgen binary");
    run_confgen_step.dependOn(&run_confgen_cmd.step);

    const confgen_test = b.addTest(.{ .root_module = confgen, .name = "confgen test" });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(libcg_test).step);
    test_step.dependOn(&b.addRunArtifact(confgen_test).step);

    if (enable_confgenfs) {
        const cgfs_translator: Translator = .init(translate_c, .{
            .c_source_file = b.path("confgenfs/c.h"),
            .target = target,
            .optimize = optimize,
            .link_system_libs = &.{
                .{ .name = "fuse3" },
            },
        });

        const confgenfs = b.addModule("confgenfs", .{
            .root_source_file = b.path("confgenfs/main.zig"),
            .link_libc = true,
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "args", .module = zig_args },
                .{ .name = "libcg", .module = libcg },
                .{ .name = "c", .module = cgfs_translator.mod },
            },
        });

        // needed for fuse_shim.c
        confgenfs.linkSystemLibrary("fuse3", .{});
        confgenfs.addCSourceFile(.{
            .file = b.path("confgenfs/fuse_shim.c"),
        });

        const confgenfs_exe = b.addExecutable(.{
            .name = "confgenfs",
            .root_module = confgenfs,
        });

        b.installArtifact(confgenfs_exe);

        const run_confgenfs_cmd = b.addRunArtifact(confgenfs_exe);
        run_confgenfs_cmd.step.dependOn(b.getInstallStep());
        run_confgenfs_cmd.addPassthruArgs();

        const run_confgenfs_step = b.step("run-confgenfs", "Run the confgenfs binary");
        run_confgenfs_step.dependOn(&run_confgenfs_cmd.step);

        const confgenfs_test = b.addTest(.{ .root_module = confgenfs, .name = "confgenfs test" });
        test_step.dependOn(&b.addRunArtifact(confgenfs_test).step);
    }
}
