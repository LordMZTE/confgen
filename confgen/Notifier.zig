const std = @import("std");

const sigset = sigs: {
    var set = std.posix.empty_sigset;
    std.os.linux.sigaddset(&set, std.posix.SIG.INT);
    std.os.linux.sigaddset(&set, std.posix.SIG.TERM);
    break :sigs set;
};

inotifyfd: std.os.linux.fd_t,
sigfd: std.os.linux.fd_t,
watches: WatchesMap,
inotifyrd: std.io.BufferedReader(1024 * 4, std.fs.File.Reader),

const WatchesMap = std.AutoHashMap(i32, []const u8);

const Notifier = @This();

pub const Event = union(enum) {
    quit,
    file_changed: []const u8,
};

pub fn init(alloc: std.mem.Allocator) !Notifier {
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &sigset, null);

    const inotifyfd = try std.posix.inotify_init1(0);
    errdefer std.posix.close(inotifyfd);

    const sigfd = try std.posix.signalfd(-1, &sigset, 0);
    errdefer std.posix.close(sigfd);

    return .{
        .inotifyfd = inotifyfd,
        .sigfd = sigfd,
        .watches = WatchesMap.init(alloc),
        .inotifyrd = std.io.bufferedReader((std.fs.File{ .handle = inotifyfd }).reader()),
    };
}

pub fn deinit(self: *Notifier) void {
    std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &sigset, null);

    std.posix.close(self.inotifyfd);
    std.posix.close(self.sigfd);

    var w_iter = self.watches.iterator();
    while (w_iter.next()) |wkv| {
        self.watches.allocator.free(wkv.value_ptr.*);
    }
    self.watches.deinit();
}

pub fn addDir(self: *Notifier, dirname: []const u8) !void {
    const fd = std.posix.inotify_add_watch(
        self.inotifyfd,
        dirname,
        std.os.linux.IN.MASK_CREATE | std.os.linux.IN.ONLYDIR | std.os.linux.IN.CLOSE_WRITE,
    ) catch |e| switch (e) {
        error.WatchAlreadyExists => return,
        else => return e,
    };
    errdefer std.posix.inotify_rm_watch(self.inotifyfd, fd);

    const dir_d = try self.watches.allocator.dupe(u8, dirname);
    errdefer self.watches.allocator.free(dir_d);

    // SAFETY: This cannot cause UB. We have checked if the dir is already watched.
    std.debug.assert(!self.watches.contains(fd));
    try self.watches.putNoClobber(fd, dir_d);
}

/// Caller must free returned memory.
pub fn next(self: *Notifier) !Event {
    var pollfds = [2]std.posix.pollfd{
        .{ .fd = self.inotifyfd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = self.sigfd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    const pending_data = self.inotifyrd.start != self.inotifyrd.end;

    if (!pending_data)
        _ = try std.posix.poll(&pollfds, -1);

    if (pending_data or pollfds[0].revents == std.posix.POLL.IN) {
        var ev: std.os.linux.inotify_event = undefined;
        try self.inotifyrd.reader().readNoEof(std.mem.asBytes(&ev));

        // The inotify_event struct is optionally followed by ev.len bytes for the path name of
        // the watched file. We must read them here to avoid clobbering the next event.
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        std.debug.assert(ev.len <= name_buf.len);
        if (ev.len > 0)
            try self.inotifyrd.reader().readNoEof(name_buf[0..ev.len]);

        const dirpath = self.watches.get(ev.wd) orelse
            @panic("inotifyfd returned invalid handle");

        // Required as padding bytes may be included in read value
        const name = std.mem.sliceTo(&name_buf, 0);

        return .{
            .file_changed =
            // This avoids inconsistent naming in the edge-case that we're observing the CWD
            if (std.mem.eql(u8, dirpath, "."))
                try self.watches.allocator.dupe(u8, name)
            else
                try std.fs.path.join(
                    self.watches.allocator,
                    &.{ dirpath, name },
                ),
        };
    }
    if (pollfds[1].revents == std.posix.POLL.IN) {
        var ev: std.os.linux.signalfd_siginfo = undefined;
        std.debug.assert(try std.posix.read(self.sigfd, std.mem.asBytes(&ev)) ==
            @sizeOf(std.os.linux.signalfd_siginfo));

        return .quit;
    }
    @panic("poll returned incorrectly");
}
