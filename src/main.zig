const std = @import("std");

const c = @import("ffi.zig").c;

const luagen = @import("luagen.zig");
const lapi = @import("lua_api.zig");
const rootfile = @import("rootfile.zig");

const Parser = @import("Parser.zig");

comptime {
    if (@import("builtin").is_test) {
        std.testing.refAllDeclsRecursive(@This());
    }
}

pub fn main() !void {
    // TODO: add flag to emit generated lua files
    if (std.os.argv.len != 2) {
        // TODO: print usage
        std.log.err("Expected one argument.", .{});
        return error.InvalidArgs;
    }

    const conf_dir = (try rootfile.findRootDir()) orelse {
        std.log.err("Couldn't find confgen.lua file!", .{});
        return error.RootfileNotFound;
    };
    defer std.heap.c_allocator.free(conf_dir);

    var state = lapi.CgState{
        .outpath = std.mem.span(std.os.argv[1]),
        .rootpath = conf_dir,
        .files = std.ArrayList(lapi.CgFile).init(std.heap.c_allocator),
    };
    defer state.deinit();

    const l = try lapi.initLuaState(&state);
    defer c.lua_close(l);

    const conf_file_path = try std.fs.path.joinZ(
        std.heap.c_allocator,
        &.{ conf_dir, "confgen.lua" },
    );
    defer std.heap.c_allocator.free(conf_file_path);

    if (c.luaL_loadfile(l, conf_file_path.ptr) != 0) {
        std.log.err("loading confgen.lua: {s}", .{c.lua_tolstring(l, -1, null)});
        return error.RootfileExec;
    }

    if (c.lua_pcall(l, 0, 0, 0) != 0) {
        std.log.err("running confgen.lua: {s}", .{c.lua_tolstring(l, -1, null)});
        return error.RootfileExec;
    }

    var content_buf = std.ArrayList(u8).init(std.heap.c_allocator);
    defer content_buf.deinit();

    for (state.files.items) |file| {
        if (file.copy) {
            std.log.info("copying {s}", .{file.outpath});
        } else {
            std.log.info("generating {s}", .{file.outpath});
        }
        genfile(l, file, &content_buf) catch |e| {
            std.log.err("generating {s}: {}", .{ file.outpath, e });
        };
    }
}

fn genfile(
    l: *c.lua_State,
    file: lapi.CgFile,
    content_buf: *std.ArrayList(u8),
) !void {
    const state = lapi.getState(l);

    if (file.copy) {
        const from_path = try std.fs.path.join(
            std.heap.c_allocator,
            &.{ state.rootpath, file.content.path },
        );
        defer std.heap.c_allocator.free(from_path);

        const to_path = try std.fs.path.join(
            std.heap.c_allocator,
            &.{ state.outpath, file.outpath },
        );
        defer std.heap.c_allocator.free(to_path);

        if (std.fs.path.dirname(to_path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        try std.fs.cwd().copyFile(from_path, std.fs.cwd(), to_path, .{});

        return;
    }
    content_buf.clearRetainingCapacity();

    var content: []const u8 = undefined;
    var fname: ?[]const u8 = null;
    switch (file.content) {
        .string => |s| content = s,
        .path => |p| {
            fname = std.fs.path.basename(p);
            const path = try std.fs.path.join(std.heap.c_allocator, &.{ state.rootpath, p });
            defer std.heap.c_allocator.free(path);

            const f = try std.fs.cwd().openFile(path, .{});
            defer f.close();

            try f.reader().readAllArrayList(content_buf, std.math.maxInt(usize));

            content = content_buf.items;
        },
    }

    var parser = Parser{
        .str = content,
        .pos = 0,
    };

    const tmpl = try luagen.generateLua(&parser, fname orelse file.outpath);
    defer tmpl.deinit();

    const out = try lapi.generate(l, tmpl);
    defer std.heap.c_allocator.free(out);

    const path = try std.fs.path.join(
        std.heap.c_allocator,
        &.{ state.outpath, file.outpath },
    );
    defer std.heap.c_allocator.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    var outfile = try std.fs.cwd().createFile(path, .{});
    defer outfile.close();

    try outfile.writeAll(out);
}
