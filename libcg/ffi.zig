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
                var buf: [128]u8 = undefined;
                const err_s = std.fmt.bufPrint(
                    &buf,
                    "Zig Error: {s}",
                    .{@errorName(e)},
                ) catch unreachable;
                c.lua_pushlstring(l, err_s.ptr, err_s.len);
                _ = c.lua_error(l);
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

pub fn luaToString(l: *c.lua_State, idx: c_int) []const u8 {
    var len: usize = 0;
    return c.lua_tolstring(l, idx, &len)[0..len];
}
