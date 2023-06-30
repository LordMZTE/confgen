//! Tools for serialization of Lua values to JSON
//! Used by the --json-opt flag
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
                try stream.emitNumber(@as(c_int, @intFromFloat(n)));
            } else {
                try stream.emitNumber(n);
            }
        },
        c.LUA_TBOOLEAN => {
            try stream.emitBool(c.lua_toboolean(l, -1) != 0);
        },
        c.LUA_TSTRING => try stream.emitString(ffi.luaToString(l, -1)),
        c.LUA_TTABLE => {
            // First, figure out whether this is a pure array table or if it has named keys.
            const TableType = enum { empty, array, map };
            var table_type = TableType.empty;
            c.lua_pushnil(l);
            while (c.lua_next(l, -2) != 0) {
                c.lua_pop(l, 1);
                switch (c.lua_type(l, -1)) {
                    c.LUA_TNUMBER => table_type = .array,
                    else => {
                        table_type = .map;
                        c.lua_pop(l, 1);
                        break;
                    },
                }
            }

            switch (table_type) {
                .array => try stream.beginArray(),
                .map, .empty => try stream.beginObject(),
            }

            c.lua_pushnil(l);
            while (c.lua_next(l, -2) != 0) {
                if (table_type == .array) {
                    try stream.arrayElem();
                } else {
                    // Need to duplicate the key in order to call luaToString.
                    // Direct call may break lua_next
                    c.lua_pushvalue(l, -2);
                    try stream.objectField(ffi.luaToString(l, -1));
                    c.lua_pop(l, 1);
                }
                try luaToJSON(l, stream);
            }

            switch (table_type) {
                .array => try stream.endArray(),
                .map, .empty => try stream.endObject(),
            }
        },
        else => unreachable,
    }
}
