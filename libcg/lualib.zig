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

    c.lua_pushcfunction(l, ffi.luaFunc(lFilter));
    c.lua_setfield(l, -2, "filter");

    c.lua_pushcfunction(l, ffi.luaFunc(lContains));
    c.lua_setfield(l, -2, "contains");

    c.lua_pushcfunction(l, ffi.luaFunc(lContainsEq));
    c.lua_setfield(l, -2, "containsEq");

    c.lua_pushcfunction(l, ffi.luaFunc(lLazy));
    c.lua_setfield(l, -2, "lazy");
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

fn lFilter(l: *c.lua_State) !c_int {
    c.luaL_checktype(l, 1, c.LUA_TTABLE);
    c.luaL_checkany(l, 2);

    c.lua_newtable(l);

    c.lua_pushnil(l);
    while (c.lua_next(l, 1) != 0) {
        // Duplicate value
        c.lua_pushvalue(l, -1);

        // Invoke predicate
        c.lua_pushvalue(l, 2);
        c.lua_insert(l, -2);
        c.lua_call(l, 1, 1);

        const keep = c.lua_toboolean(l, -1) != 0;
        c.lua_pop(l, 1);

        if (keep) {
            // Set value with same key in output
            c.lua_pushvalue(l, -2);
            c.lua_insert(l, -2);
            c.lua_settable(l, -4);
        } else {
            // Pop value
            c.lua_pop(l, 1);
        }
    }

    return 1;
}

fn lContains(l: *c.lua_State) !c_int {
    c.luaL_checktype(l, 1, c.LUA_TTABLE);
    c.luaL_checkany(l, 2);

    c.lua_pushnil(l);
    while (c.lua_next(l, 1) != 0) {
        c.lua_pushvalue(l, 2);
        c.lua_insert(l, -2);
        c.lua_call(l, 1, 1);

        if (c.lua_toboolean(l, -1) != 0) {
            c.lua_pushboolean(l, 1);
            return 1;
        }

        c.lua_pop(l, 1);
    }

    c.lua_pushboolean(l, 0);
    return 1;
}

fn lContainsEq(l: *c.lua_State) !c_int {
    c.luaL_checktype(l, 1, c.LUA_TTABLE);
    c.luaL_checkany(l, 2);

    c.lua_pushnil(l);
    while (c.lua_next(l, 1) != 0) {
        if (c.lua_equal(l, -1, 2) != 0) {
            c.lua_pushboolean(l, 1);
            return 1;
        }

        c.lua_pop(l, 1);
    }

    c.lua_pushboolean(l, 0);
    return 1;
}

pub const LLazy = struct {
    pub const lua_registry_key = "confgen_lazy";

    // If false, the companion object is the function to be called, if true, it's the value.
    initialized: bool = false,

    pub fn initMetatable(l: *c.lua_State) void {
        _ = c.luaL_newmetatable(l, lua_registry_key);
        defer c.lua_pop(l, 1);

        c.lua_pushvalue(l, -1);
        c.lua_setfield(l, -2, "__index");

        c.lua_pushcfunction(l, ffi.luaFunc(lGC));
        c.lua_setfield(l, -2, "__gc");

        c.lua_pushcfunction(l, ffi.luaFunc(lCall));
        c.lua_setfield(l, -2, "__call");
    }

    /// Needs the function on top of the stack
    fn push(self: LLazy, l: *c.lua_State) *LLazy {
        const self_ptr = ffi.luaPushUdata(l, LLazy);
        self_ptr.* = self;
        c.lua_insert(l, -2);

        // Set companion in registry.
        c.lua_pushlightuserdata(l, self_ptr);
        c.lua_insert(l, -2);
        c.lua_settable(l, c.LUA_REGISTRYINDEX);

        return self_ptr;
    }

    fn lCall(l: *c.lua_State) !c_int {
        const self = ffi.luaGetUdata(LLazy, l, 1);

        // get companion
        c.lua_pushlightuserdata(l, self);
        c.lua_gettable(l, c.LUA_REGISTRYINDEX);
        if (self.initialized) {
            // return companion
            return 1;
        } else {
            // invoke function, update companion and return it.
            c.lua_call(l, 0, 1);
            c.lua_pushlightuserdata(l, self);
            c.lua_pushvalue(l, -2);
            c.lua_settable(l, c.LUA_REGISTRYINDEX);
            self.initialized = true;
            return 1;
        }
    }

    fn lGC(l: *c.lua_State) !c_int {
        const self = ffi.luaGetUdata(LLazy, l, 1);

        // delete companion data
        c.lua_pushlightuserdata(l, self);
        c.lua_pushnil(l);
        c.lua_settable(l, c.LUA_REGISTRYINDEX);

        return 0;
    }
};

fn lLazy(l: *c.lua_State) !c_int {
    c.luaL_checkany(l, 1);
    c.lua_settop(l, 1);
    _ = (LLazy{}).push(l);
    return 1;
}
