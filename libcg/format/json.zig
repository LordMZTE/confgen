//! Tools for serialization of Lua values to JSON
//! Used by the --json-opt flag
const std = @import("std");
const ffi = @import("../ffi.zig");
const c = ffi.c;

const luaapi = @import("../luaapi.zig");

pub fn luaPush(l: *c.lua_State) void {
    c.lua_createtable(l, 0, 1);
    c.lua_pushcfunction(l, ffi.luaFunc(lSerialize));
    c.lua_setfield(l, -2, "serialize");
}

/// Writes a lua object to the stream. stream must be a json.WriteStream
pub fn luaToJSON(l: *c.lua_State, stream: *std.json.Stringify) !void {
    const ty = c.lua_type(l, -1);
    defer c.lua_pop(l, 1);

    switch (ty) {
        c.LUA_TNIL,
        c.LUA_TFUNCTION,
        c.LUA_TTHREAD,
        c.LUA_TUSERDATA,
        c.LUA_TLIGHTUSERDATA,
        => try stream.write(null),

        c.LUA_TNUMBER => {
            const n = c.lua_tonumber(l, -1);
            if (@floor(n) == n) {
                try stream.write(@as(c_int, @intFromFloat(n)));
            } else {
                try stream.write(n);
            }
        },
        c.LUA_TBOOLEAN => {
            try stream.write(c.lua_toboolean(l, -1) != 0);
        },
        c.LUA_TSTRING => try stream.write(ffi.luaToString(l, -1)),
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
                if (table_type != .array) {
                    // Need to duplicate the key in order to call luaToString.
                    // Direct call may break lua_next
                    c.lua_pushvalue(l, -2);
                    try stream.objectField(ffi.luaConvertString(l, -1));
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

fn lSerialize(l: *c.lua_State) !c_int {
    c.luaL_checkany(l, 1);
    const pretty = if (c.lua_gettop(l) >= 2) c.lua_toboolean(l, 2) != 0 else false;

    const state = luaapi.getState(l);

    var writer: std.Io.Writer.Allocating = .init(state.alloc);
    defer writer.deinit();

    var wstream: std.json.Stringify = .{
        .writer = &writer.writer,
        .options = .{ .whitespace = if (pretty) .indent_2 else .minified },
    };

    c.lua_pushvalue(l, 1);
    try @import("json.zig").luaToJSON(l, &wstream);

    ffi.luaPushString(l, writer.written());
    return 1;
}
