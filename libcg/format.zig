const std = @import("std");
const ffi = @import("ffi.zig");
const c = ffi.c;

pub const formats = struct {
    pub const json = @import("format/json.zig");
};

pub fn pushFmtTable(l: *c.lua_State) void {
    c.lua_createtable(l, 0, @typeInfo(formats).@"struct".decls.len);

    inline for (@typeInfo(formats).@"struct".decls) |decl| {
        @field(formats, decl.name).luaPush(l);
        c.lua_setfield(l, -2, decl.name);
    }
}
