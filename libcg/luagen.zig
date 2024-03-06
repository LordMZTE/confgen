const std = @import("std");
const Parser = @import("Parser.zig");

/// A compiled lua file for a template.
/// Contains references to template input string!
pub const TemplateCode = struct {
    name: [:0]const u8,
    content: []const u8,
    literals: []const []const u8,

    pub fn deinit(self: TemplateCode) void {
        std.heap.c_allocator.free(self.name);
        std.heap.c_allocator.free(self.literals);
        std.heap.c_allocator.free(self.content);
    }
};

/// Generates a lua script that allows getting the output from a given parser.
pub fn generateLua(parser: *Parser, name: []const u8) !TemplateCode {
    var outbuf = std.ArrayList(u8).init(std.heap.c_allocator);
    var literals = std.ArrayList([]const u8).init(std.heap.c_allocator);

    while (try parser.next()) |token| {
        switch (token.token_type) {
            .text => {
                try literals.append(token.str);
                try outbuf.writer().print(
                    "tmpl:pushLitIdx({d})\n",
                    .{literals.items.len - 1},
                );
            },
            .lua => {
                try outbuf.appendSlice(token.str);
                try outbuf.append('\n');
            },
            .lua_literal => {
                try outbuf.writer().print(
                    "tmpl:pushValue({s})\n",
                    .{token.str},
                );
            },
        }
    }

    return .{
        .name = try std.heap.c_allocator.dupeZ(u8, name),
        .content = try outbuf.toOwnedSlice(),
        .literals = try literals.toOwnedSlice(),
    };
}
