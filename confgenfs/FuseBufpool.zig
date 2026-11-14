const std = @import("std");
const c = @import("c");

bufs: std.ArrayList(c.fuse_buf),
mtx: std.Io.Mutex,

const FuseBufpool = @This();

pub const init: FuseBufpool = .{
    .bufs = .empty,
    .mtx = .init,
};

pub fn deinit(self: *FuseBufpool, alloc: std.mem.Allocator) void {
    for (self.bufs.items) |buf| {
        if (buf.mem) |mem| std.c.free(mem);
    }
    self.bufs.deinit(alloc);
}

pub fn acquire(self: *FuseBufpool, io: std.Io) !c.fuse_buf {
    try self.mtx.lock(io);
    defer self.mtx.unlock(io);

    if (self.bufs.pop()) |buf| return buf;
    return .{
        .size = 0,
        .flags = 0,
        .mem = null,
        .fd = -1,
        .pos = 0,
        .mem_size = 0,
    };
}

pub fn release(self: *FuseBufpool, io: std.Io, alloc: std.mem.Allocator, buf: c.fuse_buf) !void {
    try self.mtx.lock(io);
    defer self.mtx.unlock(io);

    try self.bufs.append(alloc, buf);
}
