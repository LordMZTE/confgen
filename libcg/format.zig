const std = @import("std");
const c = @import("c");

pub const formats = struct {
    pub const json = @import("format/json.zig");
};

pub fn pushFmtTable(l: *c.lua_State) void {
    const decl_names = @typeInfo(formats).@"struct".decl_names;
    c.lua_createtable(l, 0, decl_names.len);

    inline for (decl_names) |decl| {
        @field(formats, decl).luaPush(l);
        c.lua_setfield(l, -2, decl);
    }
}
