//! Tools for serialization of Lua values to JSON
//! Used by the optjson subcommand
const std = @import("std");
const ffi = @import("ffi.zig");
const c = ffi.c;

/// Writes a lua object to the stream. stream must be a json.WriteStream
pub fn luaToJSON(l: *c.lua_State, stream: anytype) !void {
    const ty = c.lua_type(l, -1);
    defer c.lua_pop(l, 1);

    switch (ty) {
        c.LUA_TNIL,
        c.LUA_TFUNCTION,
        c.LUA_TTHREAD,
        c.LUA_TUSERDATA,
        c.LUA_TLIGHTUSERDATA,
        => try stream.emitNull(),

        c.LUA_TNUMBER => {
            const n = c.lua_tonumber(l, -1);
            if (@floor(n) == n) {
                try stream.emitNumber(@floatToInt(i32, n));
            } else {
                try stream.emitNumber(n);
            }
        },
        c.LUA_TBOOLEAN => {
            try stream.emitBool(c.lua_toboolean(l, -1) != 0);
        },
        c.LUA_TSTRING => try stream.emitString(ffi.luaToString(l, -1)),
        c.LUA_TTABLE => {
            try stream.beginObject();
            c.lua_pushnil(l);
            while (c.lua_next(l, -2) != 0) {
                try stream.objectField(ffi.luaToString(l, -2));
                try luaToJSON(l, stream);
            }
            try stream.endObject();
        },
        else => unreachable,
    }
}
