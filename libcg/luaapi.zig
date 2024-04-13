const std = @import("std");
const ffi = @import("ffi.zig");
const c = ffi.c;
const luagen = @import("luagen.zig");

const Parser = @import("Parser.zig");
const TemplateCode = luagen.TemplateCode;

pub const state_key = "cg_state";
pub const on_done_callbacks_key = "on_done_callbacks";

pub const CgState = struct {
    rootpath: []const u8,
    files: std.StringHashMap(CgFile),

    pub fn deinit(self: *CgState) void {
        var iter = self.files.iterator();
        while (iter.next()) |kv| {
            self.files.allocator.free(kv.key_ptr.*);
            kv.value_ptr.*.deinit(self.files.allocator);
        }
        self.files.deinit();
    }
};

pub const CgFile = struct {
    content: CgFileContent,

    /// If set, this is a normal file that should just be copied.
    copy: bool = false,

    pub fn deinit(self: CgFile, alloc: std.mem.Allocator) void {
        switch (self.content) {
            .path => |x| alloc.free(x),
            .string => |x| alloc.free(x),
        }
    }
};

pub const CgFileContent = union(enum) {
    path: []const u8,
    string: []const u8,
};

pub const GeneratedFile = struct {
    /// Typically allocated.
    content: []const u8,
    mode: u24,
};

pub fn initLuaState(cgstate: *CgState) !*c.lua_State {
    const l = c.luaL_newstate().?;

    // open all lua libs
    c.luaL_openlibs(l);

    c.lua_getglobal(l, "_G");

    // Override `print`
    c.lua_pushcfunction(l, ffi.luaFunc(lPrint));
    c.lua_setfield(l, -2, "print");

    // Add root path to package.path
    c.lua_getfield(l, -1, "package");

    const root_luapath_prefix = try std.fmt.allocPrintZ(
        cgstate.files.allocator,
        "{s}/?.lua;",
        .{cgstate.rootpath},
    );
    defer cgstate.files.allocator.free(root_luapath_prefix);

    c.lua_pushlstring(l, root_luapath_prefix.ptr, root_luapath_prefix.len);
    c.lua_getfield(l, -2, "path");
    c.lua_concat(l, 2);
    c.lua_setfield(l, -2, "path");
    c.lua_pop(l, 2);

    // create opt table
    c.lua_newtable(l);

    // init cg table
    c.lua_newtable(l);
    c.lua_setfield(l, -2, "opt");

    c.lua_pushcfunction(l, ffi.luaFunc(lAddString));
    c.lua_setfield(l, -2, "addString");

    c.lua_pushcfunction(l, ffi.luaFunc(lAddPath));
    c.lua_setfield(l, -2, "addPath");

    c.lua_pushcfunction(l, ffi.luaFunc(lAddFile));
    c.lua_setfield(l, -2, "addFile");

    c.lua_pushcfunction(l, ffi.luaFunc(lDoTemplate));
    c.lua_setfield(l, -2, "doTemplate");

    c.lua_pushcfunction(l, ffi.luaFunc(lOnDone));
    c.lua_setfield(l, -2, "onDone");

    c.lua_pushcfunction(l, ffi.luaFunc(lToJSON));
    c.lua_setfield(l, -2, "toJSON");

    // add cg table to globals
    c.lua_setglobal(l, "cg");

    // add state to registry
    c.lua_pushlightuserdata(l, cgstate);
    c.lua_setfield(l, c.LUA_REGISTRYINDEX, state_key);

    // add empty table for onDone callbacks to registry
    c.lua_newtable(l);
    c.lua_setfield(l, c.LUA_REGISTRYINDEX, on_done_callbacks_key);

    LTemplate.initMetatable(l);

    return l;
}

pub fn loadCGFile(l: *c.lua_State, cgfile: [*:0]const u8) !void {
    if (c.luaL_loadfile(l, cgfile) != 0) {
        std.log.err("loading confgen file: {s}", .{ffi.luaToString(l, -1)});
        return error.RootfileExec;
    }

    if (c.lua_pcall(l, 0, 0, 0) != 0) {
        std.log.err("running confgen file: {s}", .{ffi.luaToString(l, -1)});
        return error.RootfileExec;
    }
}

pub fn getState(l: *c.lua_State) *CgState {
    c.lua_getfield(l, c.LUA_REGISTRYINDEX, state_key);
    const state_ptr = c.lua_touserdata(l, -1);
    c.lua_pop(l, 1);
    return @ptrCast(@alignCast(state_ptr));
}

pub fn generate(l: *c.lua_State, code: TemplateCode) !GeneratedFile {
    const state = getState(l);

    const prevtop = c.lua_gettop(l);
    defer c.lua_settop(l, prevtop);

    if (c.luaL_loadbuffer(l, code.content.ptr, code.content.len, code.name) != 0) {
        std.log.err("failed to load template: {s}", .{ffi.luaToString(l, -1)});

        return error.LoadTemplate;
    }

    // create template environment
    c.lua_newtable(l);

    // initialize environment metatable
    c.lua_createtable(l, 0, 1);
    c.lua_getglobal(l, "_G");
    c.lua_setfield(l, -2, "__index");
    _ = c.lua_setmetatable(l, -2);

    // add cg.opt to context
    c.lua_getglobal(l, "cg");
    c.lua_getfield(l, -1, "opt");
    c.lua_setfield(l, -3, "opt");
    c.lua_pop(l, 1);

    // initialize template
    const tmpl = (try LTemplate.init(code, state.files.allocator)).push(l);

    c.lua_setfield(l, -2, "tmpl");
    _ = c.lua_setfenv(l, -2);

    if (c.lua_pcall(l, 0, 0, 0) != 0) {
        std.log.err("failed to run template: {s}", .{ffi.luaToString(l, -1)});

        return error.RunTemplate;
    }

    return .{
        .content = try tmpl.getOutput(l),
        .mode = tmpl.mode,
    };
}

pub fn callOnDoneCallbacks(l: *c.lua_State, errors: bool) void {
    c.lua_getfield(l, c.LUA_REGISTRYINDEX, on_done_callbacks_key);

    const len = c.lua_objlen(l, -1);
    var idx: usize = 1;
    while (idx <= len) : (idx += 1) {
        c.lua_rawgeti(l, -1, @intCast(idx));
        c.lua_pushboolean(l, @intFromBool(errors));
        if (c.lua_pcall(l, 1, 0, 0) != 0) {
            const err_s = ffi.luaToString(l, -1);
            std.log.err("running onDone callback: {s}", .{err_s});
            c.lua_pop(l, 1);
        }
    }

    c.lua_pop(l, 1);
}

fn lPrint(l: *c.lua_State) !c_int {
    const nargs = c.lua_gettop(l);

    var buf_writer = std.io.bufferedWriter(std.io.getStdErr().writer());
    var writer = buf_writer.writer();
    try writer.writeAll("\x1b[1;34mL:\x1b[0m ");

    for (0..@intCast(nargs)) |i| {
        const s = ffi.luaToString(l, @intCast(i + 1));
        try writer.writeAll(s);
        if (i + 1 != nargs)
            try writer.writeByte('\t');
    }

    try writer.writeByte('\n');
    try buf_writer.flush();
    return 0;
}

fn lAddString(l: *c.lua_State) !c_int {
    const outpath = ffi.luaCheckString(l, 1);
    const data = ffi.luaCheckString(l, 2);

    const state = getState(l);

    const outpath_d = try state.files.allocator.dupe(u8, outpath);
    errdefer state.files.allocator.free(outpath_d);

    const data_d = try state.files.allocator.dupe(u8, data);
    errdefer state.files.allocator.free(data_d);

    if (try state.files.fetchPut(outpath_d, CgFile{
        .content = .{ .string = data_d },
    })) |old| {
        state.files.allocator.free(old.key);
        old.value.deinit(state.files.allocator);
    }
    return 0;
}

fn lAddPath(l: *c.lua_State) !c_int {
    const path = ffi.luaCheckString(l, 1);
    const targpath = if (c.lua_gettop(l) >= 2) ffi.luaCheckString(l, 2) else path;

    const state = getState(l);

    const resolved_path = try std.fs.path.resolve(state.files.allocator, &.{ state.rootpath, path });
    defer state.files.allocator.free(resolved_path);

    var dir = try std.fs.cwd().openDir(resolved_path, .{ .iterate = true });
    defer dir.close();

    var iter = try dir.walk(state.files.allocator);
    defer iter.deinit();

    while (try iter.next()) |entry| {
        if (entry.kind == .directory)
            continue;

        const outbase = if (std.mem.endsWith(u8, entry.path, ".cgt"))
            entry.path[0 .. entry.path.len - 4]
        else
            entry.path;

        const outpath = try std.fs.path.join(state.files.allocator, &.{ targpath, outbase });
        errdefer state.files.allocator.free(outpath);

        const inpath = try std.fs.path.resolve(state.files.allocator, &.{ path, entry.path });
        errdefer state.files.allocator.free(inpath);

        if (try state.files.fetchPut(outpath, .{
            .content = .{ .path = inpath },
            .copy = !std.mem.endsWith(u8, entry.path, ".cgt"),
        })) |old| {
            state.files.allocator.free(old.key);
            old.value.deinit(state.files.allocator);
        }
    }

    return 0;
}

fn lAddFile(l: *c.lua_State) !c_int {
    const state = getState(l);

    const argc = c.lua_gettop(l);

    const inpath = ffi.luaCheckString(l, 1);

    const outpath = if (argc >= 2)
        ffi.luaCheckString(l, 2)
    else blk: {
        if (std.mem.endsWith(u8, inpath, ".cgt")) {
            break :blk inpath[0 .. inpath.len - 4];
        }
        break :blk inpath;
    };

    const outpath_d = try state.files.allocator.dupe(u8, outpath);
    errdefer state.files.allocator.free(outpath_d);

    const inpath_d = try state.files.allocator.dupe(u8, inpath);
    errdefer state.files.allocator.free(inpath_d);

    if (try state.files.fetchPut(outpath_d, .{
        .content = .{ .path = inpath_d },
        .copy = !std.mem.endsWith(u8, inpath, ".cgt"),
    })) |old| {
        state.files.allocator.free(old.key);
        old.value.deinit(state.files.allocator);
    }

    return 0;
}

fn lDoTemplate(l: *c.lua_State) !c_int {
    const source = ffi.luaCheckString(l, 1);

    const state = getState(l);

    var source_name: []const u8 = "<dotemplate>";

    // check if there is an option table argument, otherwise create empty table
    if (c.lua_gettop(l) < 2) {
        c.lua_newtable(l);
    } else {
        c.luaL_checktype(l, 2, c.LUA_TTABLE);
    }

    // opt field of option table is alternative opt to pass to template
    c.lua_getfield(l, 2, "opt");
    if (c.lua_isnil(l, -1)) {
        c.lua_remove(l, -1);

        // push default opt table
        c.lua_getfield(l, c.LUA_GLOBALSINDEX, "cg");
        c.lua_getfield(l, -1, "opt");
        c.lua_remove(l, -2);
    }

    c.lua_getfield(l, 2, "name");
    if (!c.lua_isnil(l, -1)) {
        source_name = ffi.luaToString(l, -1);
    }

    var parser = Parser{ .str = source, .pos = 0 };
    const tmpl_code = try luagen.generateLua(state.files.allocator, &parser, source_name);
    defer tmpl_code.deinit(state.files.allocator);

    if (c.luaL_loadbuffer(
        l,
        tmpl_code.content.ptr,
        tmpl_code.content.len,
        tmpl_code.name.ptr,
    ) != 0) {
        // TODO: turn this into a lua error
        std.log.err("loading template: {s}", .{ffi.luaToString(l, -1)});
        return error.LoadTemplate;
    }

    // create env table
    c.lua_newtable(l);

    // add globals
    c.lua_getfield(l, c.LUA_GLOBALSINDEX, "_G");
    c.lua_setfield(l, -2, "_G");

    // add opt
    c.lua_pushvalue(l, -4);
    c.lua_setfield(l, -2, "opt");

    // add tmpl
    const tmpl = (try LTemplate.init(tmpl_code, state.files.allocator)).push(l);
    c.lua_setfield(l, -2, "tmpl");

    _ = c.lua_setfenv(l, -2);

    if (c.lua_pcall(l, 0, 0, 0) != 0) {
        // TODO: turn this into a lua error
        std.log.err("failed to run template: {s}", .{ffi.luaToString(l, -1)});
        return error.RunTemplate;
    }

    const output = try tmpl.getOutput(l);
    defer state.files.allocator.free(output);

    c.lua_pushlstring(l, output.ptr, output.len);
    return 1;
}

pub fn lOnDone(l: *c.lua_State) !c_int {
    c.luaL_checktype(l, 1, c.LUA_TFUNCTION);

    c.lua_getfield(l, c.LUA_REGISTRYINDEX, on_done_callbacks_key);
    const new_idx = c.lua_objlen(l, 1) + 1;

    c.lua_pushvalue(l, 1);
    c.lua_rawseti(l, -2, @intCast(new_idx));
    c.lua_pop(l, 1);

    return 0;
}

pub fn lToJSON(l: *c.lua_State) !c_int {
    c.luaL_checkany(l, 1);
    const pretty = if (c.lua_gettop(l) >= 2) c.lua_toboolean(l, 2) != 0 else false;

    const state = getState(l);

    // If you're doing more than 16KiB of JSON, open an issue
    // and bring a VERY good explanation with you :D
    var buf: [1024 * 16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var wstream = std.json.WriteStream(@TypeOf(fbs.writer()), .assumed_correct).init(
        state.files.allocator,
        fbs.writer(),
        .{ .whitespace = if (pretty) .indent_2 else .minified },
    );
    defer wstream.deinit();

    c.lua_pushvalue(l, 1);
    try @import("json.zig").luaToJSON(l, &wstream);

    const written = fbs.getWritten();
    c.lua_pushlstring(l, written.ptr, written.len);
    return 1;
}

pub const LTemplate = struct {
    pub const registry_key = "confgen_template";

    code: TemplateCode,
    mode: u24 = 0o644,
    output: std.ArrayList(u8),

    pub fn init(code: TemplateCode, alloc: std.mem.Allocator) !LTemplate {
        return .{
            .output = std.ArrayList(u8).init(alloc),
            .code = code,
        };
    }

    pub fn deinit(self: *LTemplate) void {
        self.output.deinit();
    }

    pub fn push(self: LTemplate, l: *c.lua_State) *LTemplate {
        const self_ptr = ffi.luaPushUdata(l, LTemplate, registry_key);
        self_ptr.* = self;

        // Create the companion table. It is used for storing user-provided stuff.
        c.lua_pushlightuserdata(l, self_ptr);
        c.lua_newtable(l);
        c.lua_settable(l, c.LUA_REGISTRYINDEX);

        return self_ptr;
    }

    fn getOutput(self: *LTemplate, l: *c.lua_State) ![]const u8 {
        const top = c.lua_gettop(l);
        defer c.lua_settop(l, top);

        c.lua_pushlightuserdata(l, self);
        c.lua_gettable(l, c.LUA_REGISTRYINDEX);

        c.lua_getfield(l, -1, "post_processor");

        // check if there's no post processor
        if (c.lua_isnil(l, -1)) {
            return try self.output.toOwnedSlice();
        }

        c.lua_pushlstring(l, self.output.items.ptr, self.output.items.len);

        // call post processor
        if (c.lua_pcall(l, 1, 1, 0) != 0) {
            std.log.err("running post processor: {s}", .{ffi.luaToString(l, -1)});
            return error.PostProcessor;
        }

        const out = ffi.luaToString(l, -1);

        return try self.output.allocator.dupe(u8, out);
    }

    fn lGC(l: *c.lua_State) !c_int {
        const self = ffi.luaGetUdata(LTemplate, l, 1, registry_key);

        // set this template's companion table in the registry to nil
        c.lua_pushlightuserdata(l, self);
        c.lua_pushnil(l);
        c.lua_settable(l, c.LUA_REGISTRYINDEX);

        self.deinit();

        return 0;
    }

    fn lPushLitIdx(l: *c.lua_State) !c_int {
        const self = ffi.luaGetUdata(LTemplate, l, 1, registry_key);
        const idx = std.math.cast(usize, c.luaL_checkint(l, 2)) orelse return error.InvalidIndex;

        if (idx >= self.code.literals.len)
            return error.InvalidIndex;

        try self.output.appendSlice(self.code.literals[idx]);

        return 0;
    }

    fn lPushValue(l: *c.lua_State) !c_int {
        const self = ffi.luaGetUdata(LTemplate, l, 1, registry_key);
        try self.output.appendSlice(ffi.luaCheckString(l, 2));

        return 0;
    }

    fn lSetPostProcessor(l: *c.lua_State) !c_int {
        c.luaL_checktype(l, 2, c.LUA_TFUNCTION);

        const self = ffi.luaGetUdata(LTemplate, l, 1, registry_key);

        // get companion table
        c.lua_pushlightuserdata(l, self);
        c.lua_gettable(l, c.LUA_REGISTRYINDEX);

        // set field on companion table
        c.lua_pushvalue(l, 2);
        c.lua_setfield(l, -2, "post_processor");

        return 0;
    }

    fn lSetMode(l: *c.lua_State) !c_int {
        const self = ffi.luaGetUdata(LTemplate, l, 1, registry_key);
        c.luaL_checkany(l, 2);

        const mode = mode: {
            if (c.lua_isstring(l, 2) != 0) {
                const s = ffi.luaToString(l, 2);
                if (s.len != 3) break :mode null;
                break :mode std.fmt.parseInt(u24, s, 8) catch null;
            } else if (c.lua_isnumber(l, 2) != 0) {
                const n = c.lua_tonumber(l, 2);
                if (@floor(n) == n) {
                    break :mode @as(u24, @intFromFloat(n));
                }
            }
            break :mode null;
        } orelse {
            return c.luaL_argerror(l, 2, "must be either number or string interpretable as 3 octal digits!");
        };

        self.mode = mode;

        return 0;
    }

    fn initMetatable(l: *c.lua_State) void {
        _ = c.luaL_newmetatable(l, registry_key);

        c.lua_pushcfunction(l, ffi.luaFunc(lGC));
        c.lua_setfield(l, -2, "__gc");

        c.lua_pushcfunction(l, ffi.luaFunc(lPushLitIdx));
        c.lua_setfield(l, -2, "pushLitIdx");

        c.lua_pushcfunction(l, ffi.luaFunc(lPushValue));
        c.lua_setfield(l, -2, "pushValue");

        c.lua_pushcfunction(l, ffi.luaFunc(lSetPostProcessor));
        c.lua_setfield(l, -2, "setPostProcessor");

        c.lua_pushcfunction(l, ffi.luaFunc(lSetMode));
        c.lua_setfield(l, -2, "setMode");

        c.lua_pushvalue(l, -1);
        c.lua_setfield(l, -2, "__index");
    }
};
