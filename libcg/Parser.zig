const std = @import("std");
const c = @import("ffi.zig").c;

str: []const u8,
pos: usize,

pub const Parser = @This();

pub const Token = struct {
    token_type: TokenType,
    str: []const u8,
};

pub const TokenType = enum {
    text,
    lua,
    lua_literal,
};

pub fn next(self: *Parser) !?Token {
    var current_type = TokenType.text;

    // TODO: this approach allows for stuff like <% <! %> %> to be considered valid.
    // that sucks, but I cannot be bothered
    var depth: usize = 0;

    var i = self.pos;
    while (i < self.str.len) : (i += 1) {
        const charpair = self.str[i..@min(i + 2, self.str.len)];

        if (std.mem.eql(u8, charpair, "<%")) {
            if (current_type == .text and self.pos != i) {
                const tok = Token{
                    .token_type = .text,
                    .str = self.str[self.pos..i],
                };

                self.pos = i;

                return tok;
            }

            defer depth += 1;

            if (depth > 0)
                continue;

            i += 1;
            self.pos = i + 1;
            current_type = .lua_literal;
        } else if (std.mem.eql(u8, charpair, "%>")) {
            depth -= 1;
            if (depth > 0)
                continue;

            // Can't check for != .lua_literal here, as that would require using
            // sort of a stack for nested blocks
            if (current_type == .text)
                return error.UnexpectedClose;

            const tok = Token{
                .token_type = .lua_literal,
                .str = std.mem.trim(u8, self.str[self.pos..i], &std.ascii.whitespace),
            };

            self.pos = i + 2;

            return tok;
        } else if (std.mem.eql(u8, charpair, "<!")) {
            if (current_type == .text and self.pos != i) {
                const tok = Token{
                    .token_type = .text,
                    .str = self.str[self.pos..i],
                };

                self.pos = i;

                return tok;
            }

            defer depth += 1;

            if (depth > 0)
                continue;

            i += 1;
            self.pos = i + 1;
            current_type = .lua;
        } else if (std.mem.eql(u8, charpair, "!>")) {
            depth -= 1;

            if (depth > 0)
                continue;

            if (current_type == .text)
                return error.UnexpectedClose;

            const tok = Token{
                .token_type = .lua,
                .str = std.mem.trim(u8, self.str[self.pos..i], &std.ascii.whitespace),
            };

            self.pos = i + 2;

            return tok;
        }
    }

    if (self.pos == i) {
        return null;
    }

    if (current_type != .text) {
        return error.UnclosedDelimeter;
    }

    const tok = Token{
        .token_type = .text,
        .str = self.str[self.pos..],
    };

    self.pos = i;

    return tok;
}

test "lua literal" {
    const input =
        \\bla
        \\<% <% test %> %>
        \\bla
    ;

    var parser = Parser{ .str = input, .pos = 0 };

    try std.testing.expectEqual(TokenType.text, (try parser.next()).?.token_type);
    try std.testing.expectEqual(TokenType.lua_literal, (try parser.next()).?.token_type);
    try std.testing.expectEqual(TokenType.text, (try parser.next()).?.token_type);

    try std.testing.expectEqual(@as(?Token, null), try parser.next());
}

test "lua" {
    const input =
        \\bla
        \\<! test !>
        \\bla
    ;

    var parser = Parser{ .str = input, .pos = 0 };

    try std.testing.expectEqual(TokenType.text, (try parser.next()).?.token_type);
    try std.testing.expectEqual(TokenType.lua, (try parser.next()).?.token_type);
    try std.testing.expectEqual(TokenType.text, (try parser.next()).?.token_type);

    try std.testing.expectEqual(@as(?Token, null), try parser.next());
}
