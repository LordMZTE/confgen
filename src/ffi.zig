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
pub fn luaPushUdata(l: *c.lua_State, udata: anytype, tname: [*:0]const u8) void {
    const T = @TypeOf(udata);

    // create and set data
    @ptrCast(*T, @alignCast(@alignOf(*T), c.lua_newuserdata(l, @sizeOf(T)).?)).* = udata;

    // set metatable
    c.luaL_getmetatable(l, tname);
    _ = c.lua_setmetatable(l, -2);
}

pub fn luaGetUdata(comptime T: type, l: *c.lua_State, param: c_int, tname: [*:0]const u8) *T {
    return @ptrCast(*T, @alignCast(@alignOf(*T), c.luaL_checkudata(l, param, tname)));
}
