const std = @import("std");

pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

/// Generates a wrapper function with error handling for a lua CFunction
pub fn luaFunc(comptime func: anytype) c.lua_CFunction {
    return &struct {
        fn f(l: ?*c.lua_State) callconv(.C) c_int {
            return func(l.?) catch |e| {
                // If error.LuaError is returned, an error value must be on the stack.
                if (e != error.LuaError) {
                    var buf: [128]u8 = undefined;
                    const err_s = std.fmt.bufPrint(
                        &buf,
                        "Zig Error: {s}",
                        .{@errorName(e)},
                    ) catch unreachable;
                    luaPushString(l.?, err_s);
                }
                _ = c.lua_error(l.?);
                unreachable;
            };
        }
    }.f;
}

/// Convenience function for pushing some full userdata onto the lua stack
pub fn luaPushUdata(l: *c.lua_State, comptime T: type) *T {
    // create and set data
    const udata: *T = @ptrCast(@alignCast(c.lua_newuserdata(l, @sizeOf(T)).?));

    // set metatable
    c.luaL_getmetatable(l, T.lua_registry_key);
    _ = c.lua_setmetatable(l, -2);

    return udata;
}

pub fn luaGetUdata(comptime T: type, l: *c.lua_State, param: c_int) *T {
    return @ptrCast(@alignCast(c.luaL_checkudata(l, param, T.lua_registry_key)));
}

pub fn luaCheckString(l: *c.lua_State, idx: c_int) []const u8 {
    var len: usize = 0;
    return c.luaL_checklstring(l, idx, &len)[0..len];
}

pub fn luaToString(l: *c.lua_State, idx: c_int) ?[]const u8 {
    var len: usize = 0;
    return (@as(?[*]const u8, c.lua_tolstring(l, idx, &len)) orelse return null)[0..len];
}

pub fn luaConvertString(l: *c.lua_State, idx: c_int) []const u8 {
    c.lua_pushvalue(l, idx);
    c.lua_getglobal(l, "tostring");
    c.lua_insert(l, -2);
    c.lua_call(l, 1, 1);
    const s = luaToString(l, -1) orelse unreachable;
    c.lua_pop(l, 1);
    return s;
}

pub inline fn luaPushString(l: *c.lua_State, s: []const u8) void {
    c.lua_pushlstring(l, s.ptr, s.len);
}

pub const StackWriter = struct {
    l: *c.lua_State,
    written: u31 = 0,

    const Writer = std.io.Writer(*StackWriter, error{}, write);

    pub fn write(self: *StackWriter, bytes: []const u8) error{}!usize {
        luaPushString(self.l, bytes);
        self.written += 1;
        return bytes.len;
    }

    pub fn writer(self: *StackWriter) Writer {
        return .{ .context = self };
    }

    pub fn concat(self: *StackWriter) void {
        c.lua_concat(self.l, self.written);
        self.written = 0;
    }
};

pub fn luaFmtString(l: *c.lua_State, comptime fmt: []const u8, args: anytype) !void {
    var ctx = StackWriter{ .l = l };
    try std.fmt.format(ctx.writer(), fmt, args);
    ctx.concat();
}
