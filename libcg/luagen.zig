const std = @import("std");
const c = ffi.c;

const Parser = @import("Parser.zig");

const ffi = @import("ffi.zig");

/// A compiled lua file for a template.
pub const TemplateCode = struct {
    alloc: std.mem.Allocator,
    name: [:0]const u8,
    source: []const u8,
    content: []const u8,
    literals: []const []const u8,

    pub const lua_registry_key = "confgen_template_code";

    pub fn deinit(self: TemplateCode) void {
        self.alloc.free(self.name);
        self.alloc.free(self.source);
        self.alloc.free(self.literals);
        self.alloc.free(self.content);
    }

    pub fn push(self: TemplateCode, l: *c.lua_State) *TemplateCode {
        const self_ptr = ffi.luaPushUdata(l, TemplateCode);
        self_ptr.* = self;

        return self_ptr;
    }

    fn lGC(l: *c.lua_State) !c_int {
        const self = ffi.luaGetUdata(TemplateCode, l, 1);
        self.deinit();
        return 0;
    }

    pub fn initMetatable(l: *c.lua_State) void {
        _ = c.luaL_newmetatable(l, lua_registry_key);
        defer c.lua_pop(l, 1);

        c.lua_pushcfunction(l, ffi.luaFunc(lGC));
        c.lua_setfield(l, -2, "__gc");
    }
};

/// Generates a lua script that allows getting the output from a given parser.
/// `src` must be allocated with `alloc`, ownership is transferred.
pub fn generateLua(
    alloc: std.mem.Allocator,
    errors: *std.zig.ErrorBundle.Wip,
    src: []const u8,
    name: []const u8,
) Parser.Error!TemplateCode {
    errdefer alloc.free(src);

    var outbuf = std.Io.Writer.Allocating.init(alloc);
    errdefer outbuf.deinit();
    var literals = std.ArrayList([]const u8).empty;
    errdefer literals.deinit(alloc);

    generateLuaInto(alloc, errors, src, name, &outbuf.writer, &literals) catch |e| switch (e) {
        error.WriteFailed => return error.OutOfMemory,
        else => |er| return er,
    };

    return .{
        .alloc = alloc,
        .name = try alloc.dupeZ(u8, name),
        .source = src,
        .content = try outbuf.toOwnedSlice(),
        .literals = try literals.toOwnedSlice(alloc),
    };
}

pub fn generateLuaInto(
    alloc: std.mem.Allocator,
    errors: *std.zig.ErrorBundle.Wip,
    src: []const u8,
    name: []const u8,
    tmplcode_writer: *std.Io.Writer,
    literals: *std.ArrayList([]const u8),
) (Parser.Error || std.Io.Writer.Error)!void {
    var parser = Parser{
        .str = src,
        .srcname = name,
        .errors = errors,
    };

    while (try parser.next()) |token| {
        switch (token.token_type) {
            .text => {
                try literals.append(alloc, token.str);
                try tmplcode_writer.print(
                    "tmpl:pushLitIdx(tmplcode, {d})\n",
                    .{literals.items.len - 1},
                );
            },
            .lua => {
                try tmplcode_writer.writeAll(token.str);
                try tmplcode_writer.writeByte('\n');
            },
            .lua_literal => {
                try tmplcode_writer.print(
                    "tmpl:pushValue({s})\n",
                    .{token.str},
                );
            },
        }
    }
}
