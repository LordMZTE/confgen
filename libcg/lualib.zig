//! The implementation of the `cg.lib` library API

const std = @import("std");
const c = ffi.c;

const ffi = @import("ffi.zig");

pub fn pushLibMod(l: *c.lua_State) void {
    c.lua_createtable(l, 0, 1);

    c.lua_pushcfunction(l, lMergeLuaFunc);
    c.lua_setfield(l, -2, "merge");

    c.lua_pushcfunction(l, ffi.luaFunc(lMap));
    c.lua_setfield(l, -2, "map");
}


const lMergeLuaFunc = ffi.luaFunc(lMerge);
fn lMerge(l: *c.lua_State) !c_int {
    c.luaL_checktype(l, 1, c.LUA_TTABLE); // A
    c.luaL_checktype(l, 2, c.LUA_TTABLE); // B

    // Iterate over B
    c.lua_pushnil(l);
    while (c.lua_next(l, 2) != 0) {
        if (c.lua_istable(l, -1)) {
            // We have a table. Check if A has a table at this key.
            c.lua_pushvalue(l, -2); // push key
            c.lua_gettable(l, 1);

            if (c.lua_istable(l, -1)) {
                // Both A and B have a table, recurse.
                // On our stack right now: key, new b, new a => swap top two
                c.lua_insert(l, -2);
                c.lua_pushcfunction(l, lMergeLuaFunc);
                c.lua_insert(l, -3); // shove function under arguments
                c.lua_call(l, 2, 0); // we can discard the result, as we've merged in-place
                continue;
            } else {
                // Not a table, remove element and continue with plain replace logic.
                c.lua_pop(l, 1);
            }
        }

        // No need to merge, add the kv pair to A.
        c.lua_pushvalue(l, -2); // Duplicate the key, as it will be popped off.
        c.lua_insert(l, -2); // Swap the top two elements. Value is on top.

        // Value is removed from stack, we're left with the key for the next iteration.
        c.lua_settable(l, 1);
    }

    // return A
    c.lua_pushvalue(l, 1);
    return 1;
}

fn lMap(l: *c.lua_State) !c_int {
    c.luaL_checktype(l, 1, c.LUA_TTABLE);
    // TODO: refactor other stuff to be like this
    c.luaL_checkany(l, 2); // Don't make assumptions on what's callable and what isn't.

    //const len = c.lua_objlen(l, 1);
    //c.lua_createtable(l, @intCast(len), 0);
    //for (1..(len + 1)) |i| {
    //    c.lua_pushvalue(l, 2);
    //    c.lua_rawgeti(l, 1, @intCast(i));
    //    c.lua_call(l, 1, 1);
    //    c.lua_rawseti(l, -2, @intCast(i));
    //}

    c.lua_createtable(l, @intCast(c.lua_objlen(l, 1)), 0); // output
    c.lua_pushnil(l);
    while (c.lua_next(l, 1) != 0) {
        c.lua_pushvalue(l, 2);
        c.lua_insert(l, -2);
        c.lua_call(l, 1, 1);
        c.lua_pushvalue(l, -2);
        c.lua_insert(l, -2);
        c.lua_settable(l, -4);
    }

    return 1;
}
