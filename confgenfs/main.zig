const std = @import("std");
const libcg = @import("libcg");
const args = @import("args");
const c = ffi.c;

const ffi = @import("ffi.zig");

const FileSystem = @import("FileSystem.zig");

const usage =
    \\==== ConfgenFS - FUSE3 filesystem for the Confgen template engine ====
    \\LordMZTE <lord@mzte.de>
    \\
    \\Options:
    \\    --help, -h                                                 Show this help
    \\
    \\Usage:
    \\    confgenfs [CONFGENFILE] [MOUNTPOINT] <-- [FUSE_ARG]...>    Mount the configs for CONFGENFILE at MOUNTPOINT, passing optional additional arguments to FUSE
    \\
;

pub const std_options = std.Options{
    .log_level = if (@import("builtin").mode == .Debug) .debug else .info,
    .logFn = libcg.logFn,
};

pub fn main() u8 {
    run() catch |e| {
        switch (e) {
            error.InvalidArguments => std.log.err("Invalid Arguments.\n{s}", .{usage}),
            error.MountFailed => std.log.err("Failed to mount the filesystem.", .{}),
            error.RootfileExec => std.log.err("Failed to execute the confgen file.", .{}),
            error.Explained => {},
            else => std.log.err("UNEXPECTED: {s}", .{@errorName(e)}),
        }
        return 1;
    };

    return 0;
}

pub fn run() !void {
    var debug_gpa = if (@import("builtin").mode == .Debug) std.heap.GeneralPurposeAllocator(.{}){} else {};
    defer if (@TypeOf(debug_gpa) != void) {
        _ = debug_gpa.deinit();
    };
    const alloc = if (@TypeOf(debug_gpa) != void)
        debug_gpa.allocator()
    else
        std.heap.c_allocator;

    const arg = try args.parseForCurrentProcess(struct {}, alloc, .print);
    defer arg.deinit();

    if (arg.positionals.len < 2) {
        std.log.err("Expected 2 or more arguments, got {}.", .{arg.positionals.len});
        return error.InvalidArguments;
    }

    c.fuse_set_log_func(ffi.fuseLogFn);

    var init_data = FileSystem.InitData{
        .alloc = alloc,
        .confgenfile = arg.positionals[0],
        .fuse = undefined,
        .err = null,
    };

    const fuse_argv = try alloc.alloc([*:0]const u8, arg.positionals.len - 1);
    defer alloc.free(fuse_argv);

    fuse_argv[0] = "confgenfs";
    for (arg.positionals[2..], fuse_argv[1..]) |cg_arg, *fuse_arg| {
        fuse_arg.* = cg_arg.ptr;
    }

    var fuse_args = c.fuse_args{
        .argc = @intCast(arg.positionals.len - 1),
        .argv = @ptrCast(fuse_argv.ptr),
        .allocated = 0,
    };

    const fuse = c.fuse_new(
        &fuse_args,
        &FileSystem.fuse_ops,
        @sizeOf(c.fuse_operations),
        &init_data,
    ) orelse
        // According to the documentation, this only returns null if invalid arguments were provided.
        return error.InvalidArguments;
    defer c.fuse_destroy(fuse);

    init_data.fuse = fuse;

    std.log.info("mounting FS @ {s}", .{arg.positionals[1]});
    if (c.fuse_mount(fuse, arg.positionals[1]) != 0)
        return error.MountFailed;
    defer c.fuse_unmount(fuse);

    if (c.fuse_set_signal_handlers(c.fuse_get_session(fuse)) != 0)
        return error.FailedToInstallSignalHandlers;
    defer c.fuse_remove_signal_handlers(c.fuse_get_session(fuse));

    const ret = c.fuse_loop(fuse);

    if (init_data.err) |e| {
        return e;
    }

    if (ret < 0) {
        const errno = std.os.linux.getErrno(@intCast(-ret));
        std.log.err("error from FUSE main loop: {s}", .{@tagName(errno)});
        return error.Explained;
    } else if (ret > 0) {
        std.log.info("FUSE terminated by signal {}", .{ret});
    } else {
        std.log.info("unmounted", .{});
    }
}
