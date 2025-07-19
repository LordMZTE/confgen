const std = @import("std");
const libcg = @import("libcg");
const args = @import("args");
const c = ffi.c;

const ffi = @import("ffi.zig");

const FileSystem = @import("FileSystem.zig");
const DataCache = @import("DataCache.zig");

const Args = struct {
    help: bool = false,
    eval: ?[]const u8 = null,
    @"post-eval": ?[]const u8 = null,

    pub const shorthands = .{
        .h = "help",
        .e = "eval",
        .p = "post-eval",
    };
};

const usage =
    \\==== ConfgenFS - FUSE3 filesystem for the Confgen template engine ====
    \\LordMZTE <lord@mzte.de>
    \\
    \\Options:
    \\    --help, -h                           Show this help
    \\    --eval, -e [CODE]                    Evaluate code before the confgenfile 
    \\    --post-eval, -p [CODE]               Evaluate code after the confgenfile
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
            //error.RootfileExec => std.log.err("Failed to execute the confgen file.", .{}),
            error.Explained => {},
            else => std.log.err("UNEXPECTED: {s}", .{@errorName(e)}),
        }
        return 1;
    };

    return 0;
}

pub fn run() !void {
    var debug_gpa = if (@import("builtin").mode == .Debug) std.heap.DebugAllocator(.{}).init else {};
    defer if (@TypeOf(debug_gpa) != void) {
        _ = debug_gpa.deinit();
    };
    const alloc = if (@TypeOf(debug_gpa) != void)
        debug_gpa.allocator()
    else
        std.heap.c_allocator;

    const arg = try args.parseForCurrentProcess(Args, alloc, .print);
    defer arg.deinit();

    if (arg.options.help) {
        try std.io.getStdOut().writeAll(usage);
        return;
    }

    if (arg.positionals.len < 2) {
        std.log.err("Expected 2 or more arguments, got {}.", .{arg.positionals.len});
        return error.InvalidArguments;
    }

    c.fuse_set_log_func(ffi.fuseLogFn);

    const l = libcg.c.luaL_newstate() orelse return error.OutOfMemory;
    defer libcg.c.lua_close(l);

    var data_cache = DataCache.empty;
    defer data_cache.deinit(alloc);

    var init_data = FileSystem.InitData{
        .alloc = alloc,
        .confgenfile = arg.positionals[0],
        .eval = arg.options.eval,
        .post_eval = arg.options.@"post-eval",
        .mountpoint = arg.positionals[1],
        .fuse = undefined,
        .data_cache = &data_cache,
        .l = l,
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

    // main loop
    {
        const sigset = comptime sigs: {
            var sigs = std.posix.empty_sigset;
            std.os.linux.sigaddset(&sigs, std.os.linux.SIG.INT);
            std.os.linux.sigaddset(&sigs, std.os.linux.SIG.TERM);
            break :sigs sigs;
        };

        // use a sigfd to handle signals
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &sigset, null);
        const sigfd = try std.posix.signalfd(-1, &sigset, 0);
        defer std.posix.close(sigfd);

        const datacache_tfd = try std.posix.timerfd_create(.MONOTONIC, .{});
        defer std.posix.close(datacache_tfd);

        var fuse_buf = c.fuse_buf{};
        // There is a fuse_buf_free function, but that's internal for some reason.
        defer std.c.free(fuse_buf.mem);

        const session = c.fuse_get_session(fuse);

        // This is set to true once we've done some FUSE work in order to then pass a timeout to
        // poll to invoke the lua GC when we've no work.
        var did_work_since_last_gc = false;

        var cache_timer_next: ?i64 = null;

        var pollfds = [_]std.posix.pollfd{ .{
            .fd = c.fuse_session_fd(session),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }, .{
            .fd = sigfd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }, .{
            .fd = datacache_tfd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        } };

        while (c.fuse_session_exited(session) == 0) {
            const nret = try std.posix.poll(
                &pollfds,
                if (did_work_since_last_gc) 2 * std.time.ms_per_s else -1,
            );

            // Hit timeout, we want to do a GC pass.
            if (nret == 0) {
                std.log.debug("running GC pass on idle", .{});
                // return value isn't documented for LUA_GCCOLLECT, probably means nothing.
                _ = libcg.c.lua_gc(l, libcg.c.LUA_GCCOLLECT, 0);
                did_work_since_last_gc = false;
                continue;
            }

            // event on FUSE socket
            if (pollfds[0].revents != 0) {
                const ret = c.fuse_session_receive_buf(session, &fuse_buf);
                if (ret < 0) {
                    const err: std.posix.E = @enumFromInt(-ret);
                    std.log.err("reading FUSE events: {s}", .{@tagName(err)});
                    return error.Explained;
                } else if (ret == 0) {
                    std.log.info("unmounted", .{});
                    break;
                }

                c.fuse_session_process_buf(session, &fuse_buf);
                did_work_since_last_gc = true;
            }

            // got signal
            if (pollfds[1].revents != 0) {
                var siginf: std.os.linux.signalfd_siginfo = undefined;
                std.debug.assert(try std.posix.read(sigfd, std.mem.asBytes(&siginf)) == @sizeOf(std.os.linux.signalfd_siginfo));
                std.log.info("caught signal {}, exiting", .{siginf.signo});
                break;
            }

            // need to tick the data cache
            if (pollfds[2].revents != 0) {
                var nexpirations: u64 = undefined;
                std.debug.assert(try std.posix.read(datacache_tfd, std.mem.asBytes(&nexpirations)) == 8);

                cache_timer_next = null;
                data_cache.tick(alloc);
            }

            if (data_cache.next_time != std.math.maxInt(i64)) {
                if ((cache_timer_next orelse std.math.maxInt(i64)) > data_cache.next_time) {
                    try data_cache.armTimerFD(datacache_tfd);
                    cache_timer_next = data_cache.next_time;
                }
            } else cache_timer_next = null;
        }
    }

    if (init_data.err) |e| {
        return e;
    }
}
