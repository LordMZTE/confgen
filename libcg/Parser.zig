const std = @import("std");
const c = @import("ffi.zig").c;

str: []const u8,
srcname: []const u8,
errors: *std.zig.ErrorBundle.Wip,
pos: usize = 0,

// If available, the index of the srcname in the error bundle.
srcn_erridx: ?u32 = null,

pub const Parser = @This();

pub const Token = struct {
    token_type: TokenType,
    str: []const u8,
};

pub const TokenType = enum {
    text,
    lua,
    lua_literal,

    fn nameString(self: TokenType) []const u8 {
        return switch (self) {
            .text => "text",
            .lua => "lua code",
            .lua_literal => "lua literal",
        };
    }
};

pub const Error = error{
    Reported,
} || std.mem.Allocator.Error;

pub fn next(self: *Parser) Error!?Token {
    // Optionally, the type of the token that we're currently parsing the inside of. For example,
    // this would be set to `.lua` after we've encountered a `<!`.
    var current_type = TokenType.text;

    // Position where the currently open token began.
    var open_pos: ?usize = null;

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

            if (current_type != .text) {
                return self.reportMismOpenDelimErr(
                    current_type,
                    .lua_literal,
                    open_pos,
                    i,
                );
            }

            open_pos = i;
            i += 1;
            self.pos = i + 1;
            current_type = .lua_literal;
        } else if (std.mem.eql(u8, charpair, "%>")) {
            if (current_type != .lua_literal) {
                return self.reportInvalCloseDelim(
                    current_type,
                    .lua_literal,
                    open_pos,
                    i,
                );
            }

            const tok = Token{
                .token_type = .lua_literal,
                .str = std.mem.trim(u8, self.str[self.pos..i], &std.ascii.whitespace),
            };

            open_pos = null;
            self.pos = i + 2;

            return tok;
        } else if (std.mem.eql(u8, charpair, "<!")) {
            // TODO: dedupe
            if (current_type == .text and self.pos != i) {
                const tok = Token{
                    .token_type = .text,
                    .str = self.str[self.pos..i],
                };

                self.pos = i;

                return tok;
            }

            if (current_type != .text) {
                return self.reportMismOpenDelimErr(
                    current_type,
                    .lua,
                    open_pos,
                    i,
                );
            }

            open_pos = i;
            i += 1;
            self.pos = i + 1;
            current_type = .lua;
        } else if (std.mem.eql(u8, charpair, "!>")) {
            // TODO: dedupe
            if (current_type != .lua) {
                return self.reportInvalCloseDelim(
                    current_type,
                    .lua,
                    open_pos,
                    i,
                );
            }

            const tok = Token{
                .token_type = .lua,
                .str = std.mem.trim(u8, self.str[self.pos..i], &std.ascii.whitespace),
            };

            open_pos = null;
            self.pos = i + 2;

            return tok;
        }
    }

    if (self.pos == i) {
        return null;
    }

    if (open_pos) |opos| {
        return self.reportUnclosedDelim(current_type, opos);
    }

    const tok = Token{
        .token_type = .text,
        .str = self.str[self.pos..],
    };

    self.pos = i;

    return tok;
}

fn posToSrcLoc(
    self: *Parser,
    pos: usize,
    span_len: usize,
) std.mem.Allocator.Error!std.zig.ErrorBundle.SourceLocationIndex {
    const loc = std.zig.findLineColumn(self.str, pos);

    if (self.srcn_erridx == null) {
        self.srcn_erridx = try self.errors.addString(self.srcname);
    }

    return try self.errors.addSourceLocation(.{
        .line = @intCast(loc.line),
        .column = @intCast(loc.column),
        .src_path = self.srcn_erridx.?,
        .source_line = try self.errors.addString(loc.source_line),
        .span_start = @intCast(loc.column),
        .span_main = @intCast(loc.column),
        .span_end = @intCast(loc.column + span_len),
    });
}

fn reportMismOpenDelimErr(
    self: *Parser,
    open_type: TokenType,
    unexp_type: TokenType,
    open_pos: ?usize,
    unexp_pos: usize,
) Error {
    try self.errors.addRootErrorMessage(.{
        .msg = try self.errors.printString(
            "Unexpected opening {s} delimiter inside {s} token",
            .{ open_type.nameString(), unexp_type.nameString() },
        ),
        .src_loc = try self.posToSrcLoc(unexp_pos, 2),
        .notes_len = if (open_pos) |_| 1 else 0,
    });

    if (open_pos) |opos| {
        const note_start = try self.errors.reserveNotes(1);
        const noteref = @intFromEnum(try self.errors.addErrorMessage(.{
            .msg = try self.errors.printString(
                "Opening {s} delimiter here",
                .{open_type.nameString()},
            ),
            .src_loc = try self.posToSrcLoc(opos, 2),
        }));
        self.errors.extra.items[note_start] = noteref;
    }

    return error.Reported;
}

fn reportInvalCloseDelim(
    self: *Parser,
    open_type: ?TokenType,
    unexp_type: TokenType,
    open_pos: ?usize,
    unexp_pos: usize,
) Error {
    const maybe_tip = if (open_type == .lua and unexp_type == .lua_literal)
        "Did you mean to use `!>`?"
    else if (open_type == .lua_literal and unexp_type == .lua)
        "Did you mean to use `%>`?"
    else
        null;

    const notecount = @as(u32, @intFromBool(open_pos != null)) + @intFromBool(maybe_tip != null);
    try self.errors.addRootErrorMessage(.{
        .msg = if (open_type) |otyp| try self.errors.printString(
            "Unexpected closing {s} delimiter inside {s} token",
            .{ unexp_type.nameString(), otyp.nameString() },
        ) else try self.errors.printString(
            "Unexpected closing {s} delimiter",
            .{unexp_type.nameString()},
        ),
        .src_loc = try self.posToSrcLoc(unexp_pos, 2),
        .notes_len = notecount,
    });

    var note_i = if (notecount != 0)
        try self.errors.reserveNotes(notecount)
    else
        0;

    if (open_pos) |opos| {
        const noteref = @intFromEnum(try self.errors.addErrorMessage(.{
            .msg = try self.errors.printString(
                "Mismatched open {s} delimiter here",
                .{open_type.?.nameString()},
            ),
            .src_loc = try self.posToSrcLoc(opos, 2),
        }));
        self.errors.extra.items[note_i] = noteref;
        note_i += 1;
    }

    if (maybe_tip) |tip| {
        const noteref = @intFromEnum(try self.errors.addErrorMessage(.{
            .msg = try self.errors.addString(tip),
        }));
        self.errors.extra.items[note_i] = noteref;
        note_i += 1;
    }

    return error.Reported;
}

fn reportUnclosedDelim(self: *Parser, open_type: TokenType, open_pos: usize) Error {
    try self.errors.addRootErrorMessage(.{
        .msg = try self.errors.printString(
            "Unclosed {s} delimiter",
            .{open_type.nameString()},
        ),
        .src_loc = try self.posToSrcLoc(open_pos, 2),
    });

    return error.Reported;
}

test "lua literal" {
    const input =
        \\bla
        \\<% test %>
        \\bla
    ;

    var errors: std.zig.ErrorBundle.Wip = undefined;
    try errors.init(std.testing.allocator);
    defer errors.deinit();

    var parser = Parser{
        .str = input,
        .srcname = "test",
        .errors = &errors,
        .pos = 0,
    };

    try std.testing.expectEqual(TokenType.text, (try parser.next()).?.token_type);
    try std.testing.expectEqual(TokenType.lua_literal, (try parser.next()).?.token_type);
    try std.testing.expectEqual(TokenType.text, (try parser.next()).?.token_type);

    try std.testing.expectEqual(@as(?Token, null), try parser.next());

    try std.testing.expectEqual(0, errors.tmpBundle().errorMessageCount());
}

test "lua" {
    const input =
        \\bla
        \\<! test !>
        \\bla
    ;

    var errors: std.zig.ErrorBundle.Wip = undefined;
    try errors.init(std.testing.allocator);
    defer errors.deinit();

    var parser = Parser{
        .str = input,
        .srcname = "test",
        .errors = &errors,
        .pos = 0,
    };

    try std.testing.expectEqual(TokenType.text, (try parser.next()).?.token_type);
    try std.testing.expectEqual(TokenType.lua, (try parser.next()).?.token_type);
    try std.testing.expectEqual(TokenType.text, (try parser.next()).?.token_type);

    try std.testing.expectEqual(@as(?Token, null), try parser.next());

    try std.testing.expectEqual(0, errors.tmpBundle().errorMessageCount());
}
