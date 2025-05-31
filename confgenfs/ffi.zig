const std = @import("std");
pub const c = @cImport({
    @cDefine("FUSE_USE_VERSION", "35");

    @cInclude("fuse.h");
    @cInclude("fuse_lowlevel.h");
    @cInclude("stdio.h");
});

// translate-c fails to translate this properly as it contains a bitfield.
pub const fuse_file_info = extern struct {
    flags: std.posix.O,
    bitfield: packed struct {
        writepage: u1,
        direct_io: u1,
        keep_cache: u1,
        parallel_direct_writes: u1,
        flush: u1,
        nonseekable: u1,
        flock_release: u1,
        cache_readdir: u1,
        noflush: u1,
        padding: u23 = 0,
        padding2: u32 = 0,
    },
    fh: u64,
    lock_owner: u64,
    poll_events: u64,
};

comptime {
    std.debug.assert(@sizeOf(fuse_file_info) == 40);
}

pub fn fuseLogFn(
    lvl: c.fuse_log_level,
    fmt: ?[*:0]const u8,
    args: ?*c.struct___va_list_tag_1,
) callconv(.C) void {
    var buf: [1024]u8 = undefined;
    const ret = c.vsnprintf(&buf, buf.len, fmt.?, args.?);

    if (ret < 0 or ret > buf.len) {
        std.log.err("failed to format FUSE log message, output might be missing!", .{});
        return;
    }

    const msg = buf[0..@intCast(ret)];

    const log = std.log.scoped(.FUSE);
    switch (lvl) {
        c.FUSE_LOG_EMERG,
        c.FUSE_LOG_ALERT,
        c.FUSE_LOG_CRIT,
        c.FUSE_LOG_ERR,
        => log.err("{s}", .{msg}),

        c.FUSE_LOG_WARNING,
        => log.warn("{s}", .{msg}),

        c.FUSE_LOG_NOTICE,
        c.FUSE_LOG_INFO,
        => log.info("{s}", .{msg}),

        c.FUSE_LOG_DEBUG,
        => log.debug("{s}", .{msg}),

        else => unreachable,
    }
}
