const std = @import("std");
const ffi = @import("ffi.zig");
const c = ffi.c;

const TemplateCode = @import("luagen.zig").TemplateCode;

pub const state_key = "cg_state";

pub const CgState = struct {
    outpath: []const u8,
    rootpath: []const u8,
    files: std.ArrayList(CgFile),

    pub fn deinit(self: *CgState) void {
        for (self.files.items) |*file| {
            file.deinit();
        }
        self.files.deinit();
    }
};

pub const CgFile = struct {
    outpath: []const u8,
    content: CgFileContent,

    /// If set, this is a normal file that should just be copied.
    copy: bool = false,

    pub fn deinit(self: *CgFile) void {
        std.heap.c_allocator.free(self.outpath);
        switch (self.content) {
            .path => |x| std.heap.c_allocator.free(x),
            .string => |x| std.heap.c_allocator.free(x),
        }
    }
};

pub const CgFileContent = union(enum) {
    path: []const u8,
    string: []const u8,
};

pub fn initLuaState(cgstate: *CgState) !*c.lua_State {
    const l = c.luaL_newstate().?;

    // open all lua libs
    c.luaL_openlibs(l);

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

    // add cg table to globals
    c.lua_setglobal(l, "cg");

    // add state to registry
    c.lua_pushlightuserdata(l, cgstate);
    c.lua_setfield(l, c.LUA_REGISTRYINDEX, state_key);

    LTemplate.initMetatable(l);

    return l;
}

pub fn getState(l: *c.lua_State) *CgState {
    c.lua_getfield(l, c.LUA_REGISTRYINDEX, state_key);
    const state_ptr = c.lua_touserdata(l, -1);
    c.lua_pop(l, 1);
    return @ptrCast(*CgState, @alignCast(@alignOf(*CgState), state_ptr));
}

pub fn generate(l: *c.lua_State, code: TemplateCode) ![]const u8 {
    const prevtop = c.lua_gettop(l);
    defer c.lua_settop(l, prevtop);

    if (c.luaL_loadbuffer(l, code.content.ptr, code.content.len, code.name) != 0) {
        std.log.err("failed to load template: {s}", .{c.lua_tolstring(l, -1, null)});

        return error.LoadTemplate;
    }

    // create template environment
    c.lua_newtable(l);

    // initialize environment
    c.lua_getglobal(l, "_G");
    c.lua_setfield(l, -2, "_G");

    // add cg.opt to context
    c.lua_getglobal(l, "cg");
    c.lua_getfield(l, -1, "opt");
    c.lua_setfield(l, -3, "opt");
    c.lua_pop(l, 1);

    // initialize template
    const tmpl = (try LTemplate.init(code)).push(l);

    c.lua_setfield(l, -2, "tmpl");
    _ = c.lua_setfenv(l, -2);

    if (c.lua_pcall(l, 0, 0, 0) != 0) {
        std.log.err("failed to run template: {s}", .{c.lua_tolstring(l, -1, null)});

        return error.RunTemplate;
    }

    return try tmpl.getOutput(l);
}

fn lAddString(l: *c.lua_State) !c_int {
    var outpath_len: usize = 0;
    const outpath = c.luaL_checklstring(l, 1, &outpath_len);
    var data_len: usize = 0;
    const data = c.luaL_checklstring(l, 2, &data_len);

    const state = getState(l);

    try state.files.append(CgFile{
        .outpath = try std.heap.c_allocator.dupe(u8, outpath[0..outpath_len]),
        .content = .{ .string = try std.heap.c_allocator.dupe(u8, data[0..data_len]) },
    });

    return 0;
}

fn lAddPath(l: *c.lua_State) !c_int {
    var path_len: usize = 0;
    const path = c.luaL_checklstring(l, 1, &path_len)[0..path_len];

    const state = getState(l);

    var dir = try std.fs.cwd().openIterableDir(path, .{});
    defer dir.close();

    var iter = try dir.walk(std.heap.c_allocator);
    defer iter.deinit();

    while (try iter.next()) |entry| {
        if (entry.kind == .Directory)
            continue;

        const outbase = if (std.mem.endsWith(u8, entry.path, ".cgt"))
            entry.path[0 .. entry.path.len - 4]
        else
            entry.path;

        const outpath = try std.fs.path.join(std.heap.c_allocator, &.{ path, outbase });
        errdefer std.heap.c_allocator.free(outpath);

        const inpath = try std.fs.path.join(std.heap.c_allocator, &.{ path, entry.path });
        errdefer std.heap.c_allocator.free(inpath);

        try state.files.append(.{
            .outpath = outpath,
            .content = .{ .path = inpath },
            .copy = !std.mem.endsWith(u8, entry.path, ".cgt"),
        });
    }

    return 0;
}

fn lAddFile(l: *c.lua_State) !c_int {
    const argc = c.lua_gettop(l);

    var inpath_len: usize = 0;
    const inpath = c.luaL_checklstring(l, 1, &inpath_len)[0..inpath_len];

    const outpath = if (argc >= 2) blk: {
        var outpath_len: usize = 0;
        break :blk c.luaL_checklstring(l, 2, &outpath_len)[0..outpath_len];
    } else blk: {
        if (std.mem.endsWith(u8, inpath, ".cgt")) {
            break :blk inpath[0 .. inpath.len - 4];
        }
        break :blk inpath;
    };

    const state = getState(l);

    try state.files.append(.{
        .outpath = try std.heap.c_allocator.dupe(u8, outpath),
        .content = .{ .path = try std.heap.c_allocator.dupe(u8, inpath) },
        .copy = !std.mem.endsWith(u8, inpath, ".cgt"),
    });

    return 0;
}

pub const LTemplate = struct {
    pub const registry_key = "confgen_template";

    code: TemplateCode,
    output: std.ArrayList(u8),

    pub fn init(code: TemplateCode) !LTemplate {
        return .{
            .output = std.ArrayList(u8).init(std.heap.c_allocator),
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
            std.log.err("running post processor: {s}", .{c.lua_tolstring(l, -1, null)});
            return error.PostProcessor;
        }

        var out_len: usize = 0;
        const out = c.lua_tolstring(l, -1, &out_len)[0..out_len];

        return try std.heap.c_allocator.dupe(u8, out);
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
        const val = c.luaL_checklstring(l, 2, null);

        try self.output.appendSlice(std.mem.span(val));

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

        c.lua_pushvalue(l, -1);
        c.lua_setfield(l, -2, "__index");
    }
};
