const std = @import("std");
pub const c = ffi.c;

pub const ffi = @import("ffi.zig");
pub const json = @import("json.zig");
pub const luaapi = @import("luaapi.zig");
pub const luagen = @import("luagen.zig");

pub const Parser = @import("Parser.zig");

var stderr_isatty: ?bool = null;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (stderr_isatty == null) {
        stderr_isatty = std.os.isatty(std.os.STDERR_FILENO);
    }

    const scope_prefix = if (scope == .default)
        ""
    else
        "[" ++ @tagName(scope) ++ "] ";

    switch (stderr_isatty.?) {
        inline else => |isatty| {
            const lvl_prefix = comptime if (isatty) switch (level) {
                .debug => "\x1b[1;34mD:\x1b[0m ",
                .info => "\x1b[1;32mI:\x1b[0m ",
                .warn => "\x1b[1;33mW:\x1b[0m ",
                .err => "\x1b[1;31mE:\x1b[0m ",
            } else switch (level) {
                .debug => "D: ",
                .info => "I: ",
                .warn => "W: ",
                .err => "E: ",
            };

            std.io.getStdErr().writer().print(scope_prefix ++ lvl_prefix ++ fmt ++ "\n", args) catch {};
        },
    }
}
