const std = @import("std");
const c = ffi.c;
const libcg = @import("libcg");

const ffi = @import("ffi.zig");

pub const lua_registry_key = "confgenfs_fsctx";

ctx: c.struct_fuse_context,

pub fn push(self: *const @This(), l: *libcg.c.lua_State) void {
    libcg.c.lua_createtable(l, 0, 4);

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

    var write_buf: [256]u8 = undefined;
    var read_buf: [256]u8 = undefined;

    var freader = file.reader(&read_buf);
    var stack_writer: libcg.ffi.StackWriter = .init(l, &write_buf);

    var i: c_int = 1;
    libcg.c.lua_newtable(l);

    while (true) {
        // Read & Push argument
        _ = try freader.interface.streamDelimiterEnding(&stack_writer.writer, 0);
        if (freader.interface.bufferedLen() == 0) break;
        freader.interface.toss(1);
        try stack_writer.writer.flush();
        stack_writer.concat();

        libcg.c.lua_rawseti(l, -2, i);
        i += 1;
    }

    return 1;
}

fn lGetCallerEnv(l: *libcg.c.lua_State) !c_int {
    const file = try luaGetProcFile(l, "environ");
    defer file.close();

    var write_buf: [256]u8 = undefined;
    var read_buf: [256]u8 = undefined;

    var freader = file.reader(&read_buf);
    var stack_writer: libcg.ffi.StackWriter = .init(l, &write_buf);

    libcg.c.lua_newtable(l);

    while (true) {
        // Read & Push key
        _ = try freader.interface.streamDelimiterEnding(&stack_writer.writer, '=');
        if (freader.interface.bufferedLen() == 0) {
            // This only happens if the file is invalid. We just discard the last kv pair and break.
            stack_writer.concat();
            libcg.c.lua_pop(l, 1);
            break;
        }
        freader.interface.toss(1);
        try stack_writer.writer.flush();
        stack_writer.concat();

        // Read & Push value
        _ = try freader.interface.streamDelimiterEnding(&stack_writer.writer, 0);
        if (freader.interface.bufferedLen() == 0) break;
        freader.interface.toss(1);
        try stack_writer.writer.flush();
        stack_writer.concat();

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
