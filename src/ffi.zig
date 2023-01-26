const std = @import("std");

pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

/// Generates a wrapper function with error handling for a lua CFunction
pub fn luaFunc(comptime func: fn (*c.lua_State) anyerror!c_int) c.lua_CFunction {
    return &struct {
        fn f(l: ?*c.lua_State) callconv(.C) c_int {
            return func(l.?) catch |e| {
                var buf: [128]u8 = undefined;
                const err_s = std.fmt.bufPrintZ(
                    &buf,
                    "Zig Error: {s}",
                    .{@errorName(e)},
                ) catch unreachable;
                c.lua_pushstring(l, err_s.ptr);
                _ = c.lua_error(l);
                unreachable;
            };
        }
    }.f;
}

/// Convenience function for pushing some full userdata onto the lua stack
pub fn luaPushUdata(l: *c.lua_State, comptime T: type, tname: [*:0]const u8) *T {
    // create and set data
    const udata = @ptrCast(*T, @alignCast(@alignOf(*T), c.lua_newuserdata(l, @sizeOf(T)).?));

    // set metatable
    c.luaL_getmetatable(l, tname);
    _ = c.lua_setmetatable(l, -2);

    return udata;
}

pub fn luaGetUdata(comptime T: type, l: *c.lua_State, param: c_int, tname: [*:0]const u8) *T {
    return @ptrCast(*T, @alignCast(@alignOf(*T), c.luaL_checkudata(l, param, tname)));
}

pub fn luaCheckString(l: *c.lua_State, idx: c_int) []const u8 {
    var len: usize = 0;
    return c.luaL_checklstring(l, idx, &len)[0..len];
}

pub fn luaToString(l: *c.lua_State, idx: c_int) []const u8 {
    var len: usize = 0;
    return c.lua_tolstring(l, idx, &len)[0..len];
}
