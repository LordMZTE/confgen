const std = @import("std");
const c = ffi.c;
const libcg = @import("libcg");

const ffi = @import("ffi.zig");

pub const lua_registry_key = "confgenfs_fsctx";

ctx: c.struct_fuse_context,

pub fn push(self: *const @This(), l: *libcg.c.lua_State) void {
    libcg.c.lua_createtable(l, 0, 3);

    libcg.c.luaL_getmetatable(l, lua_registry_key);
    _ = libcg.c.lua_setmetatable(l, -2);

    libcg.c.lua_pushinteger(l, self.ctx.pid);
    libcg.c.lua_setfield(l, -2, "pid");

    libcg.c.lua_pushinteger(l, self.ctx.uid);
    libcg.c.lua_setfield(l, -2, "uid");

    libcg.c.lua_pushinteger(l, self.ctx.gid);
    libcg.c.lua_setfield(l, -2, "gid");

    libcg.c.lua_pushinteger(l, self.ctx.umask);
    libcg.c.lua_setfield(l, -2, "umask");
}

pub fn initMetatable(l: *libcg.c.lua_State) void {
    _ = libcg.c.luaL_newmetatable(l, lua_registry_key);
    defer libcg.c.lua_pop(l, 1);

    libcg.c.lua_pushcfunction(l, libcg.ffi.luaFunc(lGetCallerCmd));
    libcg.c.lua_setfield(l, -2, "getCallerCmd");

    libcg.c.lua_pushcfunction(l, libcg.ffi.luaFunc(lGetCallerEnv));
    libcg.c.lua_setfield(l, -2, "getCallerEnv");

    libcg.c.lua_pushvalue(l, -1);
    libcg.c.lua_setfield(l, -2, "__index");
}

fn lGetCallerCmd(l: *libcg.c.lua_State) !c_int {
    const file = try luaGetProcFile(l, "cmdline");
    defer file.close();

    var readbuf = std.ArrayList(u8).init(std.heap.c_allocator);
    defer readbuf.deinit();

    var buf_reader = std.io.bufferedReader(file.reader());

    var i: c_int = 1;
    libcg.c.lua_newtable(l);

    while (true) {
        // Read & Push argument
        buf_reader.reader().streamUntilDelimiter(readbuf.writer(), 0, null) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        libcg.ffi.luaPushString(l, readbuf.items);
        readbuf.clearRetainingCapacity();

        libcg.c.lua_rawseti(l, -2, i);
        i += 1;
    }

    return 1;
}

fn lGetCallerEnv(l: *libcg.c.lua_State) !c_int {
    const file = try luaGetProcFile(l, "environ");
    defer file.close();

    var readbuf = std.ArrayList(u8).init(std.heap.c_allocator);
    defer readbuf.deinit();

    var buf_reader = std.io.bufferedReader(file.reader());

    libcg.c.lua_newtable(l);

    while (true) {
        // Read & Push key
        buf_reader.reader().streamUntilDelimiter(readbuf.writer(), '=', null) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        libcg.ffi.luaPushString(l, readbuf.items);
        readbuf.clearRetainingCapacity();

        // Read & Push value
        buf_reader.reader().streamUntilDelimiter(readbuf.writer(), 0, null) catch |e| {
            libcg.c.lua_pop(l, 1);
            switch (e) {
                error.EndOfStream => break,
                else => return e,
            }
        };
        libcg.ffi.luaPushString(l, readbuf.items);
        readbuf.clearRetainingCapacity();

        libcg.c.lua_settable(l, -3);
    }

    return 1;
}

fn luaGetProcFile(l: *libcg.c.lua_State, name: []const u8) !std.fs.File {
    libcg.c.lua_getfield(l, 1, "pid");
    const pid = libcg.c.lua_tointeger(l, -1);
    libcg.c.lua_pop(l, 1);

    var fname_buf: [std.fs.max_path_bytes]u8 = undefined;
    const fname = try std.fmt.bufPrintZ(&fname_buf, "/proc/{}/{s}", .{ pid, name });

    return try std.fs.openFileAbsoluteZ(fname.ptr, .{});
}
