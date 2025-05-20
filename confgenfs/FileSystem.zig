const std = @import("std");
const libcg = @import("libcg");
const c = ffi.c;

const ffi = @import("ffi.zig");

const FileSystem = @This();

pub const fuse_ops = ops: {
    var ops = std.mem.zeroes(c.fuse_operations);
    for (@typeInfo(fuse_op_impl).@"struct".decls) |decl| {
        @field(ops, decl.name) = @field(fuse_op_impl, decl.name);
    }
    break :ops ops;
};

/// Data passed to the FUSE init function.
pub const InitData = struct {
    alloc: std.mem.Allocator,
    confgenfile: [:0]const u8,
    eval: ?[]const u8,
    post_eval: ?[]const u8,
    mountpoint: [:0]const u8,
    fuse: *c.fuse,
    err: ?anyerror,
};

const fuse_op_impl = struct {
    pub fn init(ci: ?*c.fuse_conn_info, cfg: ?*c.fuse_config) callconv(.C) ?*anyopaque {
        std.log.info(
            "initializing FUSE with protocol version {}.{}",
            .{ ci.?.proto_major, ci.?.proto_minor },
        );

        // New files are only added on reloads, so long cache time is fine.
        cfg.?.negative_timeout = 10;

        // Attributes never change
        cfg.?.attr_timeout = 30;

        // Without this, no attempts to read files with a reported size of 0 will be made.
        cfg.?.direct_io = 1;

        const init_data: *InitData = @alignCast(@ptrCast(c.fuse_get_context().*.private_data));

        const fs = init_data.alloc.create(FileSystem) catch |e| {
            init_data.err = e;
            c.fuse_exit(init_data.fuse);
            return null;
        };

        fs.* = FileSystem.init(init_data.*) catch |e| {
            init_data.alloc.destroy(fs);
            init_data.err = e;
            c.fuse_exit(init_data.fuse);
            return null;
        };

        return fs;
    }

    pub fn destroy(udata: ?*anyopaque) callconv(.C) void {
        const fs: *FileSystem = @alignCast(@ptrCast(udata));
        fs.deinit();
    }

    pub fn open(path_p: ?[*:0]const u8, fi_r: ?*c.fuse_file_info) callconv(.C) c_int {
        const fuse_ctx = c.fuse_get_context().*;
        const fi: *ffi.fuse_file_info = @alignCast(@ptrCast(fi_r.?));
        const fs: *FileSystem = @alignCast(@ptrCast(fuse_ctx.private_data));
        const path = trimPath(path_p.?);

        const handle_idx = for (fs.handles, 0..) |h, i| {
            if (h == null) {
                break i;
            }
        } else {
            return errnoRet(.NFILE);
        };

        fs.handles[handle_idx] = if (std.mem.eql(u8, path, "_cgfs/eval")) blk: {
            if (fi.flags.ACCMODE != .WRONLY) return errnoRet(.ACCES);
            break :blk .{ .special_eval = .{} };
        } else if (std.mem.eql(u8, path, "_cgfs/opts.json")) blk: {
            if (fi.flags.ACCMODE != .RDONLY) return errnoRet(.ACCES);

            break :blk .{ .cgfile = .{
                .content = fs.generateOptsJSON() catch |e| {
                    std.log.err("generating opts.json: {}", .{e});
                    return errnoRet(.PERM);
                },
                .mode = 0o444,
                .assume_deterministic = false,
            } };
        } else blk: {
            if (fi.flags.ACCMODE != .RDONLY) return errnoRet(.ACCES);

            const cgfile = fs.cg_state.files.get(path) orelse return errnoRet(.NOENT);

            const content = fs.generateCGFile(cgfile, path, fuse_ctx) catch |e| {
                std.log.err("generating '{s}': {}", .{ path, e });
                return errnoRet(.PERM);
            };

            break :blk .{ .cgfile = content };
        };

        std.log.debug("new handle idx: {}", .{handle_idx});

        fi.fh = handle_idx;

        return 0;
    }

    pub fn read(
        path_p: ?[*:0]const u8,
        buf_r: ?[*]u8,
        bufsiz: usize,
        offset: c_long,
        fi_r: ?*c.fuse_file_info,
    ) callconv(.C) c_int {
        _ = path_p;
        const fi: *ffi.fuse_file_info = @alignCast(@ptrCast(fi_r.?));
        const fs: *FileSystem = @alignCast(@ptrCast(c.fuse_get_context().*.private_data));

        const buf = buf_r.?[0..bufsiz];

        const handle = fs.handles[fi.fh] orelse return errnoRet(.BADF);

        switch (handle) {
            .cgfile => |content| {
                if (offset >= content.content.len)
                    return 0;

                const cont_off = content.content[@intCast(offset)..];
                const len = @min(buf.len, cont_off.len);
                @memcpy(buf[0..len], cont_off[0..len]);
                return @intCast(len);
            },
            .special_eval => return 0,
        }
    }

    pub fn write(
        path_p: ?[*:0]const u8,
        buf_p: ?[*]const u8,
        bufsiz: usize,
        offset: c_long,
        fi_r: ?*c.fuse_file_info,
    ) callconv(.C) c_int {
        _ = path_p;
        const fi: *ffi.fuse_file_info = @alignCast(@ptrCast(fi_r));
        const fs: *FileSystem = @alignCast(@ptrCast(c.fuse_get_context().*.private_data));

        const buf = buf_p.?[0..bufsiz];

        std.log.debug("{}", .{offset});

        switch (fs.handles[fi.fh] orelse return errnoRet(.BADF)) {
            .cgfile => return errnoRet(.BADF),
            .special_eval => |*content| {
                content.appendSlice(
                    fs.alloc,
                    buf,
                ) catch return errnoRet(.NOMEM);
                return @intCast(buf.len);
            },
        }

        return 0;
    }

    pub fn release(path_p: ?[*:0]const u8, fi_r: ?*c.fuse_file_info) callconv(.C) c_int {
        _ = path_p;
        const fi: *ffi.fuse_file_info = @alignCast(@ptrCast(fi_r));
        const fs: *FileSystem = @alignCast(@ptrCast(c.fuse_get_context().*.private_data));

        if (fs.handles[fi.fh]) |h| {
            defer {
                std.log.debug("freed handle idx {}", .{fi.fh});
                h.deinit(fs.alloc);
                fs.handles[fi.fh] = null;
            }

            switch (h) {
                .special_eval => |code| {
                    fs.eval(code.items) catch return errnoRet(.IO);
                },
                else => {},
            }
        } else {
            return errnoRet(.BADF);
        }

        return 0;
    }

    pub fn getattr(
        path_p: ?[*:0]const u8,
        stat_r: ?*c.struct_stat,
        fi: ?*c.fuse_file_info,
    ) callconv(.C) c_int {
        _ = fi;
        const dir_mode = std.posix.S.IFDIR | 0o555;

        const stat: *std.posix.Stat = @ptrCast(stat_r.?);
        stat.* = std.mem.zeroInit(std.posix.Stat, .{
            .uid = std.os.linux.getuid(),
            .gid = std.os.linux.getgid(),
        });

        const fs: *FileSystem = @alignCast(@ptrCast(c.fuse_get_context().*.private_data));

        const path = trimPath(path_p.?);

        if (path.len == 0) {
            stat.mode = dir_mode;
            stat.nlink = 2;
            return 0;
        }

        if (std.mem.eql(u8, path, "_cgfs/eval")) {
            stat.mode = std.posix.S.IFREG | 0o644;
            stat.nlink = 1;
            return 0;
        } else if (std.mem.eql(u8, path, "_cgfs/opts.json")) {
            stat.mode = std.posix.S.IFREG | 0o444;
            stat.nlink = 1;
            return 0;
        }

        if (fs.cg_state.files.get(path)) |cgf| {
            const meta = fs.getFileMeta(cgf, path) catch |e| {
                std.log.err("getting file meta: {}", .{e});
                return errnoRet(.IO);
            };
            stat.mode = std.posix.S.IFREG | meta.mode;
            stat.size = @intCast(meta.size);
            stat.nlink = 1;
        } else if (fs.directory_cache.contains(path)) {
            stat.mode = dir_mode;
            stat.nlink = 2;
        } else {
            return errnoRet(.NOENT);
        }

        return 0;
    }

    pub fn readdir(
        path_p: ?[*:0]const u8,
        buf: ?*anyopaque,
        filler: c.fuse_fill_dir_t,
        offset: c_long,
        fi: ?*c.fuse_file_info,
        flags: c.fuse_readdir_flags,
    ) callconv(.C) c_int {
        _ = offset;
        _ = fi;
        _ = flags;

        const path = trimPath(path_p.?);

        _ = filler.?(buf, ".", null, 0, 0);
        _ = filler.?(buf, "..", null, 0, 0);

        const fs: *FileSystem = @alignCast(@ptrCast(c.fuse_get_context().*.private_data));

        if (std.mem.eql(u8, path, "_cgfs")) {
            _ = filler.?(buf, "eval", null, 0, 0);
            _ = filler.?(buf, "opts.json", null, 0, 0);
            return 0;
        }

        inline for (.{ fs.directory_cache, fs.cg_state.files }) |map| {
            var iter = map.keyIterator();
            while (iter.next()) |k| {
                var k_z_buf: [std.fs.max_path_bytes]u8 = undefined;
                const k_z = std.fmt.bufPrintZ(&k_z_buf, "{s}", .{k.*}) catch
                    return errnoRet(.NOMEM);

                if (path.len == 0) {
                    if (std.fs.path.dirname(k.*) == null) {
                        _ = filler.?(buf, k_z.ptr, null, 0, 0);
                    }
                } else {
                    if (std.mem.eql(u8, std.fs.path.dirname(k.*) orelse continue, path)) {
                        _ = filler.?(buf, k_z[path.len + 1 ..].ptr, null, 0, 0);
                    }
                }
            }
        }

        return 0;
    }
};

fn trimPath(p: [*:0]const u8) [:0]const u8 {
    const path = std.mem.span(p);
    return if (path.len != 0 and path[0] == '/') path[1..] else path;
}

inline fn errnoRet(e: std.posix.E) c_int {
    return -@as(c_int, @intCast(@intFromEnum(e)));
}

fn Cache(comptime V: type) type {
    return std.HashMap([:0]const u8, V, struct {
        pub fn hash(_: @This(), s: [:0]const u8) u64 {
            return std.hash.Wyhash.hash(0, s);
        }

        pub fn eql(_: @This(), a: [:0]const u8, b: [:0]const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }, std.hash_map.default_max_load_percentage);
}

const FileMeta = struct {
    mode: u24,
    size: u64,
};

const FileHandle = union(enum) {
    cgfile: libcg.luaapi.GeneratedFile,
    special_eval: std.ArrayListUnmanaged(u8),

    pub fn deinit(self_const: FileHandle, alloc: std.mem.Allocator) void {
        var self = self_const;
        switch (self) {
            .cgfile => |data| alloc.free(data.content),
            .special_eval => |*data| data.deinit(alloc),
        }
    }
};

alloc: std.mem.Allocator,
cg_state: *libcg.luaapi.CgState,
l: *libcg.c.lua_State,
ttyconf: std.io.tty.Config,

/// A buffer used for temporary storage during file generation. It is re-used.
genbuf: std.ArrayList(u8),

/// A set containing all directories.
directory_cache: Cache(void),

/// A cache containing metadata for a file at a given path.
/// Since the mode of templates required them to be generated, and that of copy files requiring a
/// stat call, not caching this would be stupid.
/// A downside of supporting modes at all is that we'll have to evaluate every template on a getattr
/// once and then cache it, but I don't think this is avoidable.
meta_cache: Cache(FileMeta),

/// An array storing all possible open file handles. When a new file is opened,
/// the first unused is used.
handles: [512]?FileHandle,

fn init(init_data: InitData) !FileSystem {
    const cg_state = try init_data.alloc.create(libcg.luaapi.CgState);
    errdefer init_data.alloc.destroy(cg_state);
    cg_state.* = libcg.luaapi.CgState{
        .rootpath = std.fs.path.dirname(init_data.confgenfile) orelse ".",
        .files = std.StringHashMap(libcg.luaapi.CgFile).init(init_data.alloc),
    };
    errdefer cg_state.deinit();

    try std.posix.chdir(cg_state.rootpath);

    const l = try libcg.luaapi.initLuaState(cg_state);

    // Initialize cg.fs table
    {
        var realpath_buf: [std.fs.max_path_bytes]u8 = undefined;
        // If the given mountpoint is absolute, just use that. Otherwise, try to get the absolute
        // path and fallback to the unmodified path if that fails.
        const mountpoint = if (std.fs.path.isAbsolute(init_data.mountpoint))
            init_data.mountpoint
        else if (std.fs.cwd().realpathZ(
            init_data.mountpoint,
            &realpath_buf,
        )) |rp| rp else |e| fallb: {
            std.log.warn("failed to get real mountpoint: {}", .{e});
            break :fallb init_data.mountpoint;
        };

        libcg.c.lua_getglobal(l, "cg");
        defer libcg.c.lua_pop(l, 1);

        libcg.c.lua_createtable(l, 0, 1);
        defer libcg.c.lua_setfield(l, -2, "fs");

        libcg.ffi.luaPushString(l, mountpoint);
        libcg.c.lua_setfield(l, -2, "mountpoint");
    }

    if (init_data.eval) |code| {
        try libcg.luaapi.evalUserCode(l, code);
    }

    std.log.info("loading confgenfile @ {s}", .{init_data.confgenfile});
    try libcg.luaapi.loadCGFile(l, init_data.confgenfile);

    if (init_data.post_eval) |code| {
        try libcg.luaapi.evalUserCode(l, code);
    }

    var self = FileSystem{
        .alloc = init_data.alloc,
        .cg_state = cg_state,
        .l = l,
        .ttyconf = std.io.tty.detectConfig(std.io.getStdErr()),
        .genbuf = std.ArrayList(u8).init(init_data.alloc),
        .directory_cache = Cache(void).init(init_data.alloc),
        .meta_cache = Cache(FileMeta).init(init_data.alloc),
        .handles = [1]?FileHandle{null} ** 512,
    };
    errdefer self.deinit();

    try self.computeDirectoryCache();

    return self;
}

fn computeDirectoryCache(self: *FileSystem) !void {
    {
        var iter = self.directory_cache.keyIterator();
        while (iter.next()) |key| {
            self.alloc.free(key.*);
        }
        self.directory_cache.clearRetainingCapacity();
    }

    {
        const cgfs_p = try self.alloc.dupeZ(u8, "_cgfs");
        errdefer self.alloc.free(cgfs_p);

        try self.directory_cache.put(cgfs_p, {});
    }

    var iter = self.cg_state.files.keyIterator();
    while (iter.next()) |file| {
        var dir = file.*;
        while (std.fs.path.dirname(dir)) |dirname| {
            dir = dirname;
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            @memcpy(buf[0..dirname.len], dirname);
            // I don't like this line.
            // Deal with it once it's a problem.
            buf[dirname.len] = 0;

            const dirname_z: [:0]const u8 = @ptrCast(buf[0..dirname.len]);

            const res = try self.directory_cache.getOrPutAdapted(
                dirname_z,
                self.directory_cache.ctx,
            );
            if (!res.found_existing) {
                // TODO remove the entry again in case this allocation fails to not leave the map in
                // an invalid state
                res.key_ptr.* = try self.alloc.dupeZ(u8, dirname);
                res.value_ptr.* = {};
            }
        }
    }
}

fn deinit(self: *FileSystem) void {
    libcg.c.lua_close(self.l);
    self.cg_state.deinit();
    self.alloc.destroy(self.cg_state);
    self.genbuf.deinit();

    var dircache_iter = self.directory_cache.keyIterator();
    while (dircache_iter.next()) |key| {
        self.alloc.free(key.*);
    }
    self.directory_cache.deinit();

    var metacache_iter = self.meta_cache.keyIterator();
    while (metacache_iter.next()) |key| {
        self.alloc.free(key.*);
    }
    self.meta_cache.deinit();

    for (self.handles) |maybe_handle| {
        if (maybe_handle) |handle| {
            handle.deinit(self.alloc);
        }
    }

    self.alloc.destroy(self);
}

fn getFileMeta(self: *FileSystem, cgf: libcg.luaapi.CgFile, path: [:0]const u8) !FileMeta {
    if (self.meta_cache.get(path)) |meta| {
        return meta;
    } else {
        std.log.debug("new in meta cache: {s}", .{path});

        if (cgf.copy) {
            var meta = FileMeta{
                .mode = 0o444,
                .size = 0,
            };
            switch (cgf.content) {
                .string => |s| meta.size = s.len,
                .path => |content_path| {
                    const stat = try std.fs.cwd().statFile(content_path);
                    meta.mode = @truncate(stat.mode);
                    meta.mode &= 0o555; // read-only
                    meta.size = stat.size;
                },
            }

            try self.updateMetaCache(path, meta);
            return meta;
        } else {
            // generateCGFile populates the meta cache for generated files
            const gen = try self.generateCGFile(cgf, path, null);
            defer self.alloc.free(gen.content);

            return self.meta_cache.get(path) orelse blk: {
                std.log.err(
                    "Meta cache not populated for generated file '{s}'! This is a bug!",
                    .{path},
                );
                break :blk .{ .mode = 0o444, .size = 0 };
            };
        }
    }
}

fn updateMetaCache(self: *FileSystem, name: [:0]const u8, meta: FileMeta) !void {
    if (self.meta_cache.getPtr(name)) |m| {
        m.* = meta;
    } else {
        const name_d = try self.alloc.dupeZ(u8, name);
        errdefer self.alloc.free(name_d);
        try self.meta_cache.putNoClobber(name_d, meta);
    }
}

fn generateCGFile(
    self: *FileSystem,
    cgf: libcg.luaapi.CgFile,
    name: [:0]const u8,
    maybe_fsctx: ?c.fuse_context,
) !libcg.luaapi.GeneratedFile {
    var content: []const u8 = undefined;
    var copy_mode: u24 = 0o644;
    switch (cgf.content) {
        // CGFile contains content, no work needed.
        .string => |con| content = con,

        // CgFile points to a file on disk, read it.
        .path => |rel_path| {
            self.genbuf.clearRetainingCapacity();
            var file = try std.fs.cwd().openFile(rel_path, .{});
            defer file.close();

            copy_mode = @truncate((try file.stat()).mode);

            try file.reader().readAllArrayList(&self.genbuf, std.math.maxInt(usize));
            content = self.genbuf.items;
        },
    }

    if (cgf.copy) {
        std.log.info("copying {s}", .{name});
        return .{
            .content = try self.alloc.dupe(u8, content),
            .mode = copy_mode & 0o555, // read-only
            .assume_deterministic = true,
        };
    }

    std.log.info("generating {s}", .{name});
    const src_alloc = try self.alloc.dupe(u8, content);
    var errors: std.zig.ErrorBundle.Wip = undefined;
    try errors.init(self.alloc);
    const tmpl = libcg.luagen.generateLua(
        self.alloc,
        &errors,
        src_alloc,
        name,
    ) catch |e| switch (e) {
        error.Reported => {
            var owned = try errors.toOwnedBundle("");
            defer owned.deinit(self.alloc);

            std.log.err("parsing template:", .{});
            owned.renderToStdErr(.{ .ttyconf = self.ttyconf });
            return error.Reported;
        },
        else => return e,
    };
    errors.deinit();

    libcg.c.lua_newtable(self.l);
    libcg.luaapi.LTemplate.createTmplEnv(self.l);
    if (maybe_fsctx) |fsctx| {
        libcg.c.lua_createtable(self.l, 0, 3);

        libcg.c.lua_pushinteger(self.l, fsctx.pid);
        libcg.c.lua_setfield(self.l, -2, "pid");

        libcg.c.lua_pushinteger(self.l, fsctx.uid);
        libcg.c.lua_setfield(self.l, -2, "uid");

        libcg.c.lua_pushinteger(self.l, fsctx.gid);
        libcg.c.lua_setfield(self.l, -2, "gid");

        libcg.c.lua_pushinteger(self.l, fsctx.umask);
        libcg.c.lua_setfield(self.l, -2, "umask");

        libcg.c.lua_setfield(self.l, -2, "fsctx");
    }
    const genfile = try libcg.luaapi.generateWithEnv(self.l, tmpl);

    const meta = FileMeta{
        .mode = genfile.mode,
        // we technically know the size here, but given it's non-deterministic nature, we'll
        // report 0 in order to prevent applications from naively reading too little data when
        // the file is larger the next time it's generated, unless the file has
        // assume_deterministic set in which case the user wishes for this behavior by asserting
        // that the file size is constant.
        .size = if (genfile.assume_deterministic) genfile.content.len else 0,
    };

    try self.updateMetaCache(name, meta);

    return genfile;
}

fn generateOptsJSON(self: *FileSystem) ![]const u8 {
    var buf = std.ArrayList(u8).init(self.alloc);
    errdefer buf.deinit();

    var wstream = std.json.WriteStream(@TypeOf(buf.writer()), .assumed_correct)
        .init(self.alloc, buf.writer(), .{ .whitespace = .indent_2 });
    defer wstream.deinit();

    const lua_top = libcg.c.lua_gettop(self.l);
    defer libcg.c.lua_settop(self.l, lua_top);

    libcg.c.lua_getglobal(self.l, "cg");
    libcg.c.lua_getfield(self.l, -1, "opt");

    try libcg.format.formats.json.luaToJSON(self.l, &wstream);

    return try buf.toOwnedSlice();
}

fn eval(self: *FileSystem, code: []const u8) !void {
    if (libcg.c.luaL_loadbuffer(self.l, code.ptr, code.len, "<cgfs-eval>") != 0) {
        std.log.err("unable to load eval code: {?s}", .{libcg.ffi.luaToString(self.l, -1)});
        libcg.c.lua_pop(self.l, 1);
        return error.InvalidEvalCode;
    }

    if (libcg.c.lua_pcall(self.l, 0, 0, 0) != 0) {
        std.log.err("unable to run eval code: {?s}", .{libcg.ffi.luaToString(self.l, -1)});
        libcg.c.lua_pop(self.l, 1);
        return error.InvalidEvalCode;
    }
}
