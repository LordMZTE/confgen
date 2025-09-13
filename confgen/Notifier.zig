const std = @import("std");

inotifyfd: std.os.linux.fd_t,
sigfd: std.os.linux.fd_t,
watches: WatchesMap,

rdbuf: [@sizeOf(std.os.linux.inotify_event) + std.fs.max_path_bytes + 1]u8 = undefined,
evstart: usize = 0,
readend: usize = 0,

const WatchesMap = std.AutoHashMap(i32, []const u8);

const Notifier = @This();

pub const Event = union(enum) {
    quit,
    file_changed: []const u8,
};

fn mkBlockedSigset() std.posix.sigset_t {
    var set = std.posix.sigemptyset();
    std.posix.sigaddset(&set, std.posix.SIG.INT);
    std.posix.sigaddset(&set, std.posix.SIG.TERM);
    return set;
}

const inotify_event = std.os.linux.inotify_event;

/// Initialize a new Notifier. Caller asserts that `self`
pub fn init(self: *Notifier, alloc: std.mem.Allocator) !void {
    const sigset = mkBlockedSigset();
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &sigset, null);

    const inotifyfd = try std.posix.inotify_init1(0);
    errdefer std.posix.close(inotifyfd);

    const sigfd = try std.posix.signalfd(-1, &sigset, 0);
    errdefer std.posix.close(sigfd);

    self.* = .{
        .inotifyfd = inotifyfd,
        .sigfd = sigfd,
        .watches = WatchesMap.init(alloc),
    };
}

pub fn deinit(self: *Notifier) void {
    const sigset = mkBlockedSigset();
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
    if (self.readend - self.evstart > 0) {
        // We have a buffered event
        return self.takeEventFromBuffer();
    }

    var pollfds = [2]std.posix.pollfd{
        .{ .fd = self.inotifyfd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = self.sigfd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    _ = try std.posix.poll(&pollfds, -1);

    if (pollfds[0].revents == std.posix.POLL.IN) {
        self.readend = try std.posix.read(self.inotifyfd, &self.rdbuf);
        self.evstart = 0;

        return try self.takeEventFromBuffer();
    }
    if (pollfds[1].revents == std.posix.POLL.IN) {
        var ev: std.os.linux.signalfd_siginfo = undefined;
        std.debug.assert(try std.posix.read(self.sigfd, std.mem.asBytes(&ev)) ==
            @sizeOf(std.os.linux.signalfd_siginfo));

        return .quit;
    }
    @panic("poll returned incorrectly");
}

fn takeEventFromBuffer(self: *Notifier) !Event {
    const slice = self.rdbuf[self.evstart..self.readend];
    std.debug.assert(slice.len >= @sizeOf(inotify_event));

    const ev = std.mem.bytesAsValue(
        inotify_event,
        slice[0..@sizeOf(inotify_event)],
    );

    self.evstart += @sizeOf(inotify_event) + ev.len;

    // The inotify_event struct is optionally followed by ev.len bytes for the path name of
    // the watched file. We must read them here to avoid clobbering the next event.
    const name_padded = slice[@sizeOf(inotify_event)..][0..ev.len];

    // Required as padding bytes may be included in read value
    const name = std.mem.sliceTo(name_padded, 0);

    const dirpath = self.watches.get(ev.wd) orelse
        unreachable; // inotifyfd returned invalid handle

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
