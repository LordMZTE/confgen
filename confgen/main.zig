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

pub fn main() !u8 {
    run() catch |e| {
        switch (e) {
            error.InvalidArgs => {
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
            return error.InvalidArgs;
        }

        const file = try std.fs.cwd().openFile(filepath, .{});
        defer file.close();

        const content = try file.readToEndAlloc(std.heap.c_allocator, std.math.maxInt(usize));
        defer std.heap.c_allocator.free(content);

        var parser = libcg.Parser{
            .str = content,
            .pos = 0,
        };

        const tmpl = try libcg.luagen.generateLua(&parser, filepath);
        defer tmpl.deinit();

        try std.io.getStdOut().writeAll(tmpl.content);

        return;
    }

    if (arg.options.@"json-opt") |cgfile| {
        var state = libcg.luaapi.CgState{
            .outpath = null,
            .rootpath = std.fs.path.dirname(cgfile) orelse ".",
            .files = std.ArrayList(libcg.luaapi.CgFile).init(std.heap.c_allocator),
        };
        defer state.deinit();

        const l = try libcg.luaapi.initLuaState(&state);
        defer libcg.c.lua_close(l);

        try loadCGFile(l, cgfile.ptr);

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
        return error.InvalidArgs;
    }

    const cgfile = arg.positionals[0];

    var state = libcg.luaapi.CgState{
        .outpath = arg.positionals[1],
        .rootpath = std.fs.path.dirname(cgfile) orelse ".",
        .files = std.ArrayList(libcg.luaapi.CgFile).init(std.heap.c_allocator),
    };
    defer state.deinit();

    const l = try libcg.luaapi.initLuaState(&state);
    defer libcg.c.lua_close(l);

    try loadCGFile(l, cgfile.ptr);

    var content_buf = std.ArrayList(u8).init(std.heap.c_allocator);
    defer content_buf.deinit();

    var errors = false;
    for (state.files.items) |file| {
        if (file.copy) {
            std.log.info("copying     {s}", .{file.outpath});
        } else {
            std.log.info("generating  {s}", .{file.outpath});
        }
        genfile(l, file, &content_buf) catch |e| {
            errors = true;
            std.log.err("generating {s}: {}", .{ file.outpath, e });
        };
    }

    libcg.luaapi.callOnDoneCallbacks(l, errors);
}

fn genfile(
    l: *libcg.c.lua_State,
    file: libcg.luaapi.CgFile,
    content_buf: *std.ArrayList(u8),
) !void {
    const state = libcg.luaapi.getState(l);

    if (file.copy) {
        const from_path = try std.fs.path.join(
            std.heap.c_allocator,
            &.{ state.rootpath, file.content.path },
        );
        defer std.heap.c_allocator.free(from_path);

        const to_path = try std.fs.path.join(
            std.heap.c_allocator,
            &.{ state.outpath.?, file.outpath },
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
    var file_mode: std.fs.File.Mode = std.fs.File.default_mode;
    switch (file.content) {
        .string => |s| content = s,
        .path => |p| {
            fname = std.fs.path.basename(p);
            const path = try std.fs.path.join(std.heap.c_allocator, &.{ state.rootpath, p });
            defer std.heap.c_allocator.free(path);

            file_mode = (try std.fs.cwd().statFile(path)).mode;
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

    const tmpl = try libcg.luagen.generateLua(&parser, fname orelse file.outpath);
    defer tmpl.deinit();

    const out = try libcg.luaapi.generate(l, tmpl);
    defer std.heap.c_allocator.free(out);

    const path = try std.fs.path.join(
        std.heap.c_allocator,
        &.{ state.outpath.?, file.outpath },
    );
    defer std.heap.c_allocator.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    var outfile = try std.fs.cwd().createFile(path, .{ .mode = file_mode });
    defer outfile.close();

    try outfile.writeAll(out);
}

fn loadCGFile(l: *libcg.c.lua_State, cgfile: [*:0]const u8) !void {
    if (libcg.c.luaL_loadfile(l, cgfile) != 0) {
        std.log.err("loading confgen file: {s}", .{libcg.ffi.luaToString(l, -1)});
        return error.RootfileExec;
    }

    if (libcg.c.lua_pcall(l, 0, 0, 0) != 0) {
        std.log.err("running confgen file: {s}", .{libcg.ffi.luaToString(l, -1)});
        return error.RootfileExec;
    }
}
