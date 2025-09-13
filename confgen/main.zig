const std = @import("std");
const args = @import("args");
const libcg = @import("libcg");

const Notifier = @import("Notifier.zig");

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
    file: bool = false,
    help: bool = false,
    eval: ?[]const u8 = null,
    @"post-eval": ?[]const u8 = null,
    watch: bool = false,

    pub const shorthands = .{
        .c = "compile",
        .j = "json-opt",
        .f = "file",
        .h = "help",
        .e = "eval",
        .p = "post-eval",
        .w = "watch",
    };
};

const usage =
    \\==== Confgen - Config File Template Engine ====
    \\LordMZTE <lord@mzte.de>
    \\
    \\Options:
    \\    --compile, -c [TEMPLATE_FILE]        Compile a template to Lua instead of running. Useful for debugging.
    \\    --json-opt, -j [CONFGENFILE]         Write the given or all fields from cg.opt to stdout as JSON after running the given confgenfile instead of running.
    \\    --file, -f [TEMPLATE_FILE] [OUTFILE] Evaluate a single template and write the output instead of running.
    \\    --eval, -e [CODE]                    Evaluate code before the confgenfile .
    \\    --post-eval, -p [CODE]               Evaluate code after the confgenfile.
    \\    --watch, -w                          Watch for changes of input files and re-generate them if changed.
    \\    --help, -h                           Show this help.
    \\
    \\Usage:
    \\    confgen [CONFGENFILE] [OUTPATH]      Generate configs according the the supplied configuration file.
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
            error.Explained => {},
            error.LuaError => {
                // Once Zig is smart enough to remove LuaError from the error set here, we'll
                // replace this branch with this compile-time check:
                //comptime {
                //    const ret_errors = @typeInfo(@typeInfo(@typeInfo(@TypeOf(run)).Fn.return_type.?).ErrorUnion.error_set).ErrorSet.?;
                //    for (ret_errors) |err| {
                //        if (std.mem.eql(u8, err.name, "LuaError"))
                //            @compileError("Run function must never return a LuaError!");
                //    }
                //}

                // We can't get the error message here as the Lua state will alread have been destroyed.
                std.log.err("UNKNOWN LUA ERROR! THIS IS A BUG!", .{});
            },
            error.RootfileExec => {
                std.log.err("Couldn't run Confgenfile.", .{});
            },
            else => {
                std.log.err("UNEXPECTED: {s}", .{@errorName(e)});
                if (@errorReturnTrace()) |ert| std.debug.dumpStackTrace(ert.*);
            },
        }
        return 1;
    };

    return 0;
}

pub fn run() !void {
    var debug_gpa = if (@import("builtin").mode == .Debug) std.heap.DebugAllocator(.{}){} else {};
    defer if (@TypeOf(debug_gpa) != void) {
        _ = debug_gpa.deinit();
    };
    const alloc = if (@TypeOf(debug_gpa) != void)
        debug_gpa.allocator()
    else
        std.heap.c_allocator;

    const arg = try args.parseForCurrentProcess(Args, alloc, .print);
    defer arg.deinit();

    if (arg.options.help) {
        try std.fs.File.stdout().writeAll(usage);
        return;
    }

    const ttyconf = std.io.tty.detectConfig(std.fs.File.stderr());

    if (arg.options.compile) |filepath| {
        if (arg.positionals.len != 0) {
            std.log.err("Expected 0 positional arguments, got {}.", .{arg.positionals.len});
            return error.InvalidArguments;
        }

        const file = try std.fs.cwd().openFile(filepath, .{});
        defer file.close();

        const content = try file.readToEndAlloc(alloc, std.math.maxInt(usize));
        defer alloc.free(content);

        var errors: std.zig.ErrorBundle.Wip = undefined;
        try errors.init(alloc);

        var stdout_buf: [1024]u8 = undefined;
        var stdout = std.fs.File.stdout().writer(&stdout_buf);

        var literals: std.ArrayList([]const u8) = .empty;
        defer literals.deinit(alloc);

        libcg.luagen.generateLuaInto(
            alloc,
            &errors,
            content,
            filepath,
            &stdout.interface,
            &literals,
        ) catch |e| switch (e) {
            error.Reported => {
                var owned = try errors.toOwnedBundle("");
                defer owned.deinit(alloc);

                std.log.err("parsing template:", .{});
                owned.renderToStdErr(.{ .ttyconf = ttyconf });
                return error.Explained;
            },
            else => return e,
        };
        errors.deinit();

        try stdout.interface.flush();

        return;
    }

    if (arg.options.@"json-opt") |cgfile| {
        var state = libcg.luaapi.CgState{
            .alloc = alloc,
            .rootpath = std.fs.path.dirname(cgfile) orelse ".",
            .files = .empty,
        };
        defer state.deinit();

        try std.posix.chdir(state.rootpath);

        const l = libcg.c.luaL_newstate() orelse return error.OutOfMemory;
        defer libcg.c.lua_close(l);
        try libcg.luaapi.initLuaState(&state, l);

        if (arg.options.eval) |code| {
            try libcg.luaapi.evalUserCode(l, code);
        }

        try libcg.luaapi.loadCGFile(l, cgfile.ptr);

        if (arg.options.@"post-eval") |code| {
            try libcg.luaapi.evalUserCode(l, code);
        }

        var write_buf: [512]u8 = undefined;
        var writer = std.fs.File.stdout().writer(&write_buf);
        var wstream: std.json.Stringify = .{
            .writer = &writer.interface,
            .options = .{ .whitespace = .indent_2 },
        };

        libcg.c.lua_getglobal(l, "cg");
        libcg.c.lua_getfield(l, -1, "opt");

        if (arg.positionals.len == 0) {
            try libcg.format.formats.json.luaToJSON(l, &wstream);
            libcg.c.lua_pop(l, 1);
        } else {
            try wstream.beginObject();
            for (arg.positionals) |opt| {
                try wstream.objectField(opt);
                libcg.c.lua_getfield(l, -1, opt);
                try libcg.format.formats.json.luaToJSON(l, &wstream);
            }
            libcg.c.lua_pop(l, 2);
            try wstream.endObject();
        }

        try writer.interface.writeByte('\n');
        try writer.interface.flush();

        return;
    }

    if (arg.options.file) {
        if (arg.positionals.len != 2) {
            std.log.err(
                "Expected 2 positional arguments for single-file mode, got {}.",
                .{arg.positionals.len},
            );
            return error.InvalidArguments;
        }

        var state = libcg.luaapi.CgState{
            .alloc = alloc,
            .rootpath = ".",
            .files = .empty,
        };
        defer state.deinit();

        const l = libcg.c.luaL_newstate() orelse return error.OutOfMemory;
        defer libcg.c.lua_close(l);
        try libcg.luaapi.initLuaState(&state, l);

        var content_buf: std.Io.Writer.Allocating = .init(alloc);
        defer content_buf.deinit();

        const cgfile = libcg.luaapi.CgFile{
            .content = .{ .path = arg.positionals[0] },
            .copy = false,
        };

        var errors: std.zig.ErrorBundle.Wip = undefined;
        try errors.init(alloc);
        genfile(
            alloc,
            l,
            &errors,
            cgfile,
            &content_buf,
            ".",
            arg.positionals[1],
        ) catch |e| switch (e) {
            error.Reported => {
                var bundle = try errors.toOwnedBundle("");
                defer bundle.deinit(alloc);

                std.log.err("reported errors:", .{});
                bundle.renderToStdErr(.{ .ttyconf = ttyconf });
            },
            else => {
                errors.deinit();
                return e;
            },
        };
        errors.deinit();

        libcg.luaapi.callOnDoneCallbacks(l, false);
        if (arg.options.watch) {
            var notif: Notifier = undefined;
            try Notifier.init(&notif, alloc);
            defer notif.deinit();

            try notif.addDir(std.fs.path.dirname(arg.positionals[0]) orelse ".");

            while (true) switch (try notif.next()) {
                .quit => break,
                .file_changed => |p| {
                    defer alloc.free(p);
                    if (!std.mem.eql(u8, p, arg.positionals[0])) continue;

                    var errorb: std.zig.ErrorBundle.Wip = undefined;
                    try errorb.init(alloc);
                    genfile(
                        alloc,
                        l,
                        &errorb,
                        cgfile,
                        &content_buf,
                        ".",
                        arg.positionals[1],
                    ) catch |e| {
                        if (e == error.Reported) {
                            var owned = try errorb.toOwnedBundle("");
                            defer owned.deinit(alloc);

                            owned.renderToStdErr(.{ .ttyconf = ttyconf });
                        }
                        std.log.err("generating {s}: {}", .{ arg.positionals[1], e });
                    };
                    errorb.deinit();
                },
            };
        }

        return;
    }

    if (arg.positionals.len != 2) {
        std.log.err("Expected 2 positional arguments, got {}.", .{arg.positionals.len});
        return error.InvalidArguments;
    }

    var cgfile_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const cgfile_nosentinel = try std.fs.realpath(
        arg.positionals[0],
        cgfile_buf[0 .. cgfile_buf.len - 1],
    );
    cgfile_buf[cgfile_nosentinel.len] = 0; // Is guaranteed to be in bounds
    const cgfile: [:0]u8 = @ptrCast(cgfile_nosentinel);

    std.fs.cwd().makeDir(arg.positionals[1]) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    var output_abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const output_abs = try std.fs.realpath(arg.positionals[1], &output_abs_buf);

    var state = libcg.luaapi.CgState{
        .alloc = alloc,
        .rootpath = std.fs.path.dirname(cgfile) orelse ".",
        .files = .empty,
    };
    defer state.deinit();

    try std.posix.chdir(state.rootpath);

    var l = libcg.c.luaL_newstate() orelse return error.OutOfMemory;
    defer libcg.c.lua_close(l);
    try libcg.luaapi.initLuaState(&state, l);

    if (arg.options.eval) |code| {
        try libcg.luaapi.evalUserCode(l, code);
    }

    try libcg.luaapi.loadCGFile(l, cgfile.ptr);

    if (arg.options.@"post-eval") |code| {
        try libcg.luaapi.evalUserCode(l, code);
    }

    var content_buf: std.Io.Writer.Allocating = .init(alloc);
    defer content_buf.deinit();

    {
        var errors = false;
        var errorb: std.zig.ErrorBundle.Wip = undefined;
        try errorb.init(alloc);
        var iter = state.files.iterator();
        while (iter.next()) |kv| {
            const outpath = kv.key_ptr.*;
            const file = kv.value_ptr.*;

            genfile(
                alloc,
                l,
                &errorb,
                file,
                &content_buf,
                output_abs,
                outpath,
            ) catch |e| {
                errors = true;
                std.log.err("generating {s}: {}", .{ outpath, e });
            };
        }

        var errorbo = try errorb.toOwnedBundle("");
        defer errorbo.deinit(alloc);

        if (errorbo.extra.len != 0) {
            std.log.err("reported errors:", .{});
            errorbo.renderToStdErr(.{ .ttyconf = ttyconf });
        }

        libcg.luaapi.callOnDoneCallbacks(l, errors);
    }

    if (arg.options.watch) {
        var notif: Notifier = undefined;
        try Notifier.init(&notif, alloc);
        defer notif.deinit();

        {
            try notif.addDir(std.fs.path.dirname(cgfile) orelse ".");

            var iter = state.files.iterator();
            while (iter.next()) |kv| {
                switch (kv.value_ptr.content) {
                    .path => |p| try notif.addDir(std.fs.path.dirname(p) orelse "."),
                    else => {},
                }
            }
        }

        while (true) switch (try notif.next()) {
            .quit => break,
            .file_changed => |p| {
                defer alloc.free(p);

                if (std.mem.eql(u8, p, cgfile)) {
                    std.log.info("Confgenfile changed; re-evaluating", .{});

                    // Destroy Lua state
                    libcg.c.lua_close(l);
                    l = libcg.c.luaL_newstate() orelse return error.OutOfMemory;
                    try libcg.luaapi.initLuaState(&state, l);

                    // Reset CgState
                    state.nfile_iters = 0; // old Lua state is dead, so no iterators.
                    {
                        var iter = state.files.iterator();
                        while (iter.next()) |kv| {
                            alloc.free(kv.key_ptr.*);
                            kv.value_ptr.deinit(alloc);
                        }
                        state.files.clearRetainingCapacity();
                    }

                    // Evaluate cgfile and eval args
                    if (arg.options.eval) |code| {
                        try libcg.luaapi.evalUserCode(l, code);
                    }

                    try libcg.luaapi.loadCGFile(l, cgfile.ptr);

                    if (arg.options.@"post-eval") |code| {
                        try libcg.luaapi.evalUserCode(l, code);
                    }

                    // Watch new files
                    {
                        try notif.addDir(std.fs.path.dirname(cgfile) orelse ".");

                        var iter = state.files.iterator();
                        while (iter.next()) |kv| {
                            switch (kv.value_ptr.content) {
                                .path => |path| try notif.addDir(std.fs.path.dirname(path) orelse "."),
                                else => {},
                            }
                        }
                    }

                    continue;
                }

                // We need to iterate here because the key of the map corresponds to the file's
                // output path. The input path may be entirely different.
                var iter = state.files.iterator();
                while (iter.next()) |kv| {
                    if (kv.value_ptr.content != .path) continue;

                    if (std.mem.eql(u8, kv.value_ptr.content.path, p)) {
                        var errors: std.zig.ErrorBundle.Wip = undefined;
                        try errors.init(alloc);
                        genfile(
                            alloc,
                            l,
                            &errors,
                            kv.value_ptr.*,
                            &content_buf,
                            output_abs,
                            kv.key_ptr.*,
                        ) catch |e| {
                            if (e == error.Reported) {
                                var owned = try errors.toOwnedBundle("");
                                defer owned.deinit(alloc);

                                std.log.err("reported errors:", .{});
                                owned.renderToStdErr(.{ .ttyconf = ttyconf });
                            }
                            std.log.err("generating {s}: {}", .{ p, e });
                        };
                        errors.deinit();
                    }
                }
            },
        };
    }
}

fn genfile(
    alloc: std.mem.Allocator,
    l: *libcg.c.lua_State,
    errors: *std.zig.ErrorBundle.Wip,
    file: libcg.luaapi.CgFile,
    content_buf: *std.Io.Writer.Allocating,
    outpath_root: []const u8,
    file_outpath: []const u8,
) !void {
    const state = libcg.luaapi.getState(l);

    if (file.copy) {
        std.log.info("copying     {s}", .{file_outpath});
    } else {
        std.log.info("generating  {s}", .{file_outpath});
    }

    if (file.copy) {
        const to_path = try std.fs.path.join(
            alloc,
            &.{ outpath_root, file_outpath },
        );
        defer alloc.free(to_path);

        if (std.fs.path.dirname(to_path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        switch (file.content) {
            .path => |p| {
                const from_path = try std.fs.path.resolve(
                    alloc,
                    &.{ state.rootpath, p },
                );
                defer alloc.free(from_path);

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
            const path = try std.fs.path.resolve(alloc, &.{ state.rootpath, p });
            defer alloc.free(path);

            const f = try std.fs.cwd().openFile(path, .{});
            defer f.close();

            var read_buf: [512]u8 = undefined;
            var reader = f.reader(&read_buf);
            _ = try reader.interface.streamRemaining(&content_buf.writer);

            content = content_buf.written();
        },
    }

    const out = gen: {
        const content_alloc = try alloc.dupe(u8, content);
        const tmpl = try libcg.luagen.generateLua(
            alloc,
            errors,
            content_alloc,
            fname orelse file_outpath,
        );
        break :gen try libcg.luaapi.generate(l, tmpl);
    };
    defer alloc.free(out.content);

    const path = try std.fs.path.join(
        alloc,
        &.{ outpath_root, file_outpath },
    );
    defer alloc.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    var outfile = try std.fs.cwd().createFile(path, .{ .mode = out.mode });
    defer outfile.close();

    try outfile.writeAll(out.content);
}
