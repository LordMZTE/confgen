//! A data structure used to cache file content for a given time, after which it is freed.

const std = @import("std");

pub const Entry = struct {
    freetime: i64,
    data: []const u8,
    mode: u24,
};

inner: std.StringArrayHashMapUnmanaged(Entry),
next_time: i64,

pub const empty = @This(){ .inner = .empty, .next_time = std.math.maxInt(i64) };

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    var iter = self.inner.iterator();
    while (iter.next()) |kv| {
        alloc.free(kv.key_ptr.*);
        alloc.free(kv.value_ptr.data);
    }

    self.inner.deinit(alloc);
}

pub fn tick(self: *@This(), alloc: std.mem.Allocator) void {
    const now_time = now();
    var next_time: i64 = std.math.maxInt(i64);

    var i: usize = 0;
    while (i < self.inner.count()) {
        const elem = self.inner.entries.get(i);
        if (elem.value.freetime <= now_time) {
            std.log.debug("deleted from data cache: {s}", .{elem.key});
            alloc.free(elem.key);
            alloc.free(elem.value.data);

            self.inner.swapRemoveAt(i);
        } else {
            next_time = @min(next_time, elem.value.freetime);
            i += 1;
        }
    }
    self.next_time = next_time;
}

pub fn put(self: *@This(), alloc: std.mem.Allocator, path: []const u8, ent: Entry) !void {
    {
        const path_d = try alloc.dupe(u8, path);
        errdefer alloc.free(path_d);

        try self.inner.put(alloc, path_d, ent);
    }

    self.next_time = @min(self.next_time, ent.freetime);
}

pub fn armTimerFD(self: *const @This(), tfd: std.posix.fd_t) !void {
    try std.posix.timerfd_settime(tfd, .{ .ABSTIME = true }, &.{
        .it_value = .{
            .sec = @divTrunc(self.next_time, std.time.ms_per_s),
            .nsec = @mod(self.next_time, 1000) * std.time.ns_per_ms,
        },
        .it_interval = .{ .sec = 0, .nsec = 0 },
    }, null);
}

pub fn now() i64 {
    const now_ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
    return now_ts.sec * std.time.ms_per_s + @divTrunc(now_ts.nsec, std.time.ns_per_ms);
}
