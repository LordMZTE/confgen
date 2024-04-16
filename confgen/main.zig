const std = @import("std");
const args = @import("args");
const libcg = @import("libcg");

comptime {
    if (@import("builtin").is_test) {
        std.testing.refAllDeclsRecursive(@This());
    }
}

pub const std_options = std.Options{
    .log_level = if (@import("builtin").mode == .Debug) .debug else .info,

    .logFn = libcg.logFn,
};

const Args = struct {
    /// Compile template to Lua for debugging.
    compile: ?[]const u8 = null,
    /// Dump options identified by positional arguments.
    @"json-opt": ?[:0]const u8 = null,
    help: bool = false,

    pub const shorthands = .{
        .c = "compile",
        .j = "json-opt",
        .h = "help",
    };
};

const usage =
    \\==== Confgen - Config File Template Engine ====
    \\LordMZTE <lord@mzte.de>
    \\
    \\Options:
    \\    --compile, -c [TEMPLATE_FILE]      Compile a template to Lua instead of running. Useful for debugging.
    \\    --json-opt, -j [CONFGENFILE]       Write the given or all fields from cg.opt to stdout as JSON after running the given confgenfile instead of running.
    \\    --help, -h                         Show this help
    \\
    \\Usage:
    \\    confgen [CONFGENFILE] [OUTPATH]    Generate configs according the the supplied configuration file.
    \\
;

pub fn main() u8 {
    run() catch |e| {
        switch (e) {
            error.InvalidArguments => {
                std.log.err(
                    \\Invalid Arguments.
                    \\{s}
                , .{usage});
            },
            //error.Explained => {},
            else => {
                std.log.err("UNEXPECTED: {s}", .{@errorName(e)});
            },
        }
        return 1;
    };

    return 0;
}

pub fn run() !void {
    const arg = try args.parseForCurrentProcess(Args, std.heap.c_allocator, .print);
    defer arg.deinit();

    if (arg.options.help) {
        try std.io.getStdOut().writeAll(usage);
        return;
    }

    if (arg.options.compile) |filepath| {
        if (arg.positionals.len != 0) {
            std.log.err("Expected 0 positional arguments, got {}.", .{arg.positionals.len});
            return error.InvalidArguments;
        }

        const file = try std.fs.cwd().openFile(filepath, .{});
        defer file.close();

        const content = try file.readToEndAlloc(std.heap.c_allocator, std.math.maxInt(usize));
        defer std.heap.c_allocator.free(content);

        var parser = libcg.Parser{
            .str = content,
            .pos = 0,
        };

        const tmpl = try libcg.luagen.generateLua(std.heap.c_allocator, &parser, filepath);
        defer tmpl.deinit(std.heap.c_allocator);

        try std.io.getStdOut().writeAll(tmpl.content);

        return;
    }

    if (arg.options.@"json-opt") |cgfile| {
        var state = libcg.luaapi.CgState{
            .rootpath = std.fs.path.dirname(cgfile) orelse ".",
            .files = std.StringHashMap(libcg.luaapi.CgFile).init(std.heap.c_allocator),
        };
        defer state.deinit();

        const l = try libcg.luaapi.initLuaState(&state);
        defer libcg.c.lua_close(l);

        try libcg.luaapi.loadCGFile(l, cgfile.ptr);

        var bufwriter = std.io.bufferedWriter(std.io.getStdOut().writer());
        var wstream = std.json.WriteStream(@TypeOf(bufwriter.writer()), .assumed_correct)
            .init(std.heap.c_allocator, bufwriter.writer(), .{ .whitespace = .indent_2 });
        defer wstream.deinit();

        libcg.c.lua_getglobal(l, "cg");
        libcg.c.lua_getfield(l, -1, "opt");

        if (arg.positionals.len == 0) {
            try libcg.json.luaToJSON(l, &wstream);
            libcg.c.lua_pop(l, 1);
        } else {
            try wstream.beginObject();
            for (arg.positionals) |opt| {
                try wstream.objectField(opt);
                libcg.c.lua_getfield(l, -1, opt);
                try libcg.json.luaToJSON(l, &wstream);
            }
            libcg.c.lua_pop(l, 2);
            try wstream.endObject();
        }

        try bufwriter.writer().writeAll("\n");

        try bufwriter.flush();

        return;
    }

    if (arg.positionals.len != 2) {
        std.log.err("Expected 2 positional arguments, got {}.", .{arg.positionals.len});
        return error.InvalidArguments;
    }

    const cgfile = arg.positionals[0];

    var state = libcg.luaapi.CgState{
        .rootpath = std.fs.path.dirname(cgfile) orelse ".",
        .files = std.StringHashMap(libcg.luaapi.CgFile).init(std.heap.c_allocator),
    };
    defer state.deinit();

    const l = try libcg.luaapi.initLuaState(&state);
    defer libcg.c.lua_close(l);

    try libcg.luaapi.loadCGFile(l, cgfile.ptr);

    var content_buf = std.ArrayList(u8).init(std.heap.c_allocator);
    defer content_buf.deinit();

    var errors = false;
    var iter = state.files.iterator();
    while (iter.next()) |kv| {
        const outpath = kv.key_ptr.*;
        const file = kv.value_ptr.*;

        if (file.copy) {
            std.log.info("copying     {s}", .{outpath});
        } else {
            std.log.info("generating  {s}", .{outpath});
        }
        genfile(
            l,
            file,
            &content_buf,
            arg.positionals[1],
            outpath,
        ) catch |e| {
            errors = true;
            std.log.err("generating {s}: {}", .{ outpath, e });
        };
    }

    libcg.luaapi.callOnDoneCallbacks(l, errors);
}

fn genfile(
    l: *libcg.c.lua_State,
    file: libcg.luaapi.CgFile,
    content_buf: *std.ArrayList(u8),
    outpath_root: []const u8,
    file_outpath: []const u8,
) !void {
    const state = libcg.luaapi.getState(l);

    if (file.copy) {
        const to_path = try std.fs.path.join(
            std.heap.c_allocator,
            &.{ outpath_root, file_outpath },
        );
        defer std.heap.c_allocator.free(to_path);

        if (std.fs.path.dirname(to_path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        switch (file.content) {
            .path => |p| {
                const from_path = try std.fs.path.resolve(
                    std.heap.c_allocator,
                    &.{ state.rootpath, p },
                );
                defer std.heap.c_allocator.free(from_path);

                try std.fs.cwd().copyFile(from_path, std.fs.cwd(), to_path, .{});
            },

            .string => |s| {
                var outfile = try std.fs.cwd().createFile(to_path, .{});
                defer outfile.close();

                try outfile.writeAll(s);
            },
        }

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

    var parser = libcg.Parser{
        .str = content,
        .pos = 0,
    };

    const out = gen: {
        const tmpl = try libcg.luagen.generateLua(std.heap.c_allocator, &parser, fname orelse file_outpath);
        errdefer tmpl.deinit(std.heap.c_allocator);

        break :gen try libcg.luaapi.generate(l, tmpl);
    };
    defer std.heap.c_allocator.free(out.content);

    const path = try std.fs.path.join(
        std.heap.c_allocator,
        &.{ outpath_root, file_outpath },
    );
    defer std.heap.c_allocator.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    var outfile = try std.fs.cwd().createFile(path, .{ .mode = out.mode });
    defer outfile.close();

    try outfile.writeAll(out.content);
}
