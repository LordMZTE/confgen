const std = @import("std");
const libcg = @import("libcg");
const args = @import("args");
const c = @import("c");

const ffi = @import("ffi.zig");

const DataCache = @import("DataCache.zig");
const FileSystem = @import("FileSystem.zig");
const FuseBufpool = @import("FuseBufpool.zig");

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

pub fn main(init: std.process.Init) u8 {
    run(init) catch |e| {
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

pub fn run(init: std.process.Init) !void {
    const arg = try args.parseForCurrentProcess(Args, init, .print);
    defer arg.deinit();

    if (arg.options.help) {
        try std.Io.File.stdout().writeStreamingAll(init.io, usage);
        return;
    }

    if (arg.positionals.len < 2) {
        std.log.err("Expected 2 or more arguments, got {}.", .{arg.positionals.len});
        return error.InvalidArguments;
    }

    c.fuse_set_log_func(ffi.fuseLogFn);

    const l = libcg.c.luaL_newstate() orelse return error.OutOfMemory;
    defer libcg.c.lua_close(l);

    var data_cache: DataCache = .empty;
    defer data_cache.deinit(init.gpa);

    var init_data: FileSystem.InitData = .{
        .alloc = init.gpa,
        .io = init.io,
        .confgenfile = arg.positionals[0],
        .eval = arg.options.eval,
        .post_eval = arg.options.@"post-eval",
        .mountpoint = arg.positionals[1],
        .fuse = undefined,
        .data_cache = &data_cache,
        .l = l,
        .err = null,
    };

    const fuse_argv = try init.gpa.alloc([*:0]const u8, arg.positionals.len - 1);
    defer init.gpa.free(fuse_argv);

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
        const sigset = sigs: {
            var sigs = std.posix.sigemptyset();
            std.posix.sigaddset(&sigs, std.os.linux.SIG.INT);
            std.posix.sigaddset(&sigs, std.os.linux.SIG.TERM);
            break :sigs sigs;
        };

        // use a sigfd to handle signals
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &sigset, null);
        const sigfd = try std.posix.signalfd(-1, &sigset, 0);
        defer _ = std.posix.system.close(sigfd);

        const datacache_tfd: libcg.posix.TimerFd = try .init(.MONOTONIC, 0);
        defer datacache_tfd.deinit();

        var bufs: FuseBufpool = .init;
        defer bufs.deinit(init.gpa);

        var tasks: std.Io.Group = .init;
        defer tasks.cancel(init.io);

        const session = c.fuse_get_session(fuse).?;

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
            .fd = datacache_tfd.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        } };

        while (c.fuse_session_exited(session) == 0) {
            _ = try std.posix.poll(
                &pollfds,
                -1,
            );

            // event on FUSE socket
            if (pollfds[0].revents != 0) {
                var fuse_buf = try bufs.acquire(init.io);

                const ret = c.fuse_session_receive_buf(session, &fuse_buf);
                if (ret < 0) {
                    const err: std.posix.E = @fromBackingInt(@intCast(-ret));
                    try bufs.release(init.io, init.gpa, fuse_buf);
                    std.log.err("reading FUSE events: {s}", .{@tagName(err)});
                    return error.Explained;
                } else if (ret == 0) {
                    std.log.info("unmounted", .{});
                    break;
                }

                try tasks.concurrent(
                    init.io,
                    processFuseEvents,
                    .{ init.io, init.gpa, &bufs, session, fuse_buf },
                );
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
                std.debug.assert(try std.posix.read(datacache_tfd.handle, std.mem.asBytes(&nexpirations)) == 8);

                cache_timer_next = null;
                data_cache.tick(init.gpa);
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

fn processFuseEvents(
    io: std.Io,
    alloc: std.mem.Allocator,
    bufs: *FuseBufpool,
    session: *c.fuse_session,
    buf: c.fuse_buf,
) void {
    c.fuse_session_process_buf(session, &buf);
    bufs.release(io, alloc, buf) catch {
        if (buf.mem) |mem| std.c.free(mem);
    };
}
