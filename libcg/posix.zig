//! Error handling wrappers around POSIX functions.  These were in std, but Andrew had yet another
//! brainfart and removed them.
const std = @import("std");

pub const EPoll = struct {
    handle: std.posix.fd_t,

    pub fn init() !EPoll {
        const epfd = std.posix.system.epoll_create1(0);
        switch (std.posix.system.errno(epfd)) {
            .SUCCESS => {},
            .MFILE => return error.ProcessFdQuoteExceeded,
            .NFILE => return error.SystemFdQuoteExceeded,
            .NOMEM => return error.OutOfMemory,
            else => |errno| return std.posix.unexpectedErrno(errno),
        }

        return .{ .handle = epfd };
    }

    pub fn deinit(self: EPoll) void {
        _ = std.posix.system.close(self.handle);
    }

    pub fn addFd(self: EPoll, fd: std.posix.fd_t, events: u32) !void {
        var ev: std.os.linux.epoll_event = .{
            .events = events,
            .data = .{ .fd = fd },
        };

        const rc = std.os.linux.epoll_ctl(self.handle, std.os.linux.EPOLL.CTL_ADD, fd, &ev);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {},
            .EXIST => return error.FileDescriptorAlreadyRegistered,
            .LOOP => return error.Loop,
            .NOSPC => return error.ProcessFdQuoteExceeded,
            .PERM => return error.PermissionDenied,
            else => |errno| return std.posix.unexpectedErrno(errno),
        }
    }

    pub fn wait(
        self: EPoll,
        buf: []std.os.linux.epoll_event,
        timeout: i32,
    ) ![]std.os.linux.epoll_event {
        while (true) {
            const rc = std.os.linux.epoll_wait(self.handle, buf.ptr, @intCast(buf.len), timeout);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => |errno| return std.posix.unexpectedErrno(errno),
            }

            return buf[0..rc];
        }
    }
};

pub const TimerFd = struct {
    handle: std.posix.fd_t,

    pub fn init(clock: std.posix.system.timerfd_clockid_t, flags: c_int) !TimerFd {
        const rc = std.posix.system.timerfd_create(clock, flags);
        switch (std.posix.system.errno(rc)) {
            .SUCCESS => {},
            .MFILE => return error.ProcessFdQuoteExceeded,
            .NFILE => return error.SystemFdQuoteExceeded,
            .NOMEM => return error.OutOfMemory,
            .PERM => return error.PermissionDenied,
            else => |errno| return std.posix.unexpectedErrno(errno),
        }
        return .{ .handle = rc };
    }

    pub fn deinit(self: TimerFd) void {
        _ = std.posix.system.close(self.handle);
    }

    pub fn setTime(
        self: TimerFd,
        value: std.os.linux.timespec,
        interval: std.os.linux.timespec,
        flags: std.os.linux.TFD.TIMER,
    ) !void {
        const rc = std.os.linux.timerfd_settime(
            self.handle,
            @bitCast(flags),
            &.{
                .it_value = value,
                .it_interval = interval,
            },
            null,
        );

        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {},
            else => |errno| return std.posix.unexpectedErrno(errno),
        }
    }
};
