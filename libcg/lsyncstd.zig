//! This module contains a re-implementation of Lua's io-related stdlib functions that can unlock a
//! mutex while the operation is ongoing, allowing other threads to execute Lua code, enabling
//! interleaved IO.  If this is used, it is important that each thread that can access the lua_State
//! concurrently does everything in it's own Lua thread and leaves the root state's stack clean
//! and locks the mutex that we've been passed every time Lua code from this module may be executed.
const std = @import("std");
const ffi = @import("ffi.zig");
const c = @import("c");

const state_key = "cg_syncstd_state";

const State = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    env: *std.process.Environ.Map,
    mtx: *std.Io.Mutex,
};

/// Replace all io functions in the stdlib with our re-implementation.  Everything passed here will
/// be stored in the Lua state and must thus outlive it.
pub fn register(
    l: *c.lua_State,
    io: std.Io,
    alloc: std.mem.Allocator,
    env: *std.process.Environ.Map,
    mtx: *std.Io.Mutex,
) void {
    const state = ffi.luaPushUdata(l, State);
    state.* = .{
        .io = io,
        .alloc = alloc,
        .env = env,
        .mtx = mtx,
    };
    c.lua_setfield(l, c.LUA_REGISTRYINDEX, state_key);

    // Insert our new os functions into the existing `os` table, as we don't re-implement all of
    // them.
    c.lua_getglobal(l, "os");
    insertOsFuncs(l);
    c.lua_pop(l, 1);

    // Create a whole new table for `io`, as we re-implement the entire API.
    c.lua_newtable(l);
    insertIoFuncs(l);
    c.lua_setglobal(l, "io");

    lio.LFile.initMetatable(l);
}

/// Inserts our replacement functions for `io` into the table on top of the Lua stack.
fn insertIoFuncs(l: *c.lua_State) void {
    c.lua_pushcfunction(l, ffi.luaFuncErrRet(lio.lOpen));
    c.lua_setfield(l, -2, "open");

    c.lua_pushcfunction(l, ffi.luaFuncErrRet(lio.LFile.lClose));
    c.lua_setfield(l, -2, "close");

    c.lua_pushcfunction(l, ffi.luaFuncErrRet(lio.lLines));
    c.lua_setfield(l, -2, "lines");
}

/// Inserts our replacement functions for `os` into the table on top of the Lua stack.
fn insertOsFuncs(l: *c.lua_State) void {
    c.lua_pushcfunction(l, ffi.luaFunc(los.lExecute));
    c.lua_setfield(l, -2, "execute");

    c.lua_pushcfunction(l, ffi.luaFuncErrRet(los.lRemove));
    c.lua_setfield(l, -2, "remove");

    c.lua_pushcfunction(l, ffi.luaFuncErrRet(los.lRename));
    c.lua_setfield(l, -2, "rename");

    c.lua_pushcfunction(l, ffi.luaFuncErrRet(los.lTmpname));
    c.lua_setfield(l, -2, "tmpname");
}

const los = struct {
    fn lExecute(l: *c.lua_State) !c_int {
        if (c.lua_gettop(l) == 0) {
            // If we aren't passed a command, return 1 to indicate a shell is available.
            c.lua_pushinteger(l, 1);
            return 1;
        }

        const state = getState(l);
        const cmd = ffi.luaCheckString(l, 1);

        const term = run: {
            state.mtx.unlock(state.io);
            defer state.mtx.lockUncancelable(state.io);

            var proc = try std.process.spawn(state.io, .{
                .argv = &.{ "sh", "-c", cmd },
            });
            break :run try proc.wait(state.io);
        };

        switch (term) {
            inline .exited, .unknown => |code| c.lua_pushinteger(l, code),
            .signal, .stopped => |sig| c.lua_pushinteger(l, @backingInt(sig)),
        }
        return 1;
    }

    fn lRemove(l: *c.lua_State) !c_int {
        const fname = ffi.luaCheckString(l, 1);
        const state = getState(l);

        {
            state.mtx.unlock(state.io);
            defer state.mtx.lockUncancelable(state.io);

            // `deleteDir` can also remove files, at least on Io.Threaded.
            std.Io.Dir.cwd().deleteFile(state.io, fname) catch |e| switch (e) {
                error.IsDir => try std.Io.Dir.cwd().deleteDir(state.io, fname),
                else => return e,
            };
        }

        c.lua_pushboolean(l, 1);
        return 1;
    }

    fn lRename(l: *c.lua_State) !c_int {
        const old_fname = ffi.luaCheckString(l, 1);
        const new_fname = ffi.luaCheckString(l, 2);
        const state = getState(l);

        {
            state.mtx.unlock(state.io);
            defer state.mtx.lockUncancelable(state.io);

            try std.Io.Dir.cwd().rename(old_fname, std.Io.Dir.cwd(), new_fname, state.io);
        }

        c.lua_pushboolean(l, 1);
        return 1;
    }

    fn lTmpname(l: *c.lua_State) !c_int {
        const state = getState(l);

        const path = mkfile: {
            state.mtx.unlock(state.io);
            defer state.mtx.lockUncancelable(state.io);

            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const p = try mkTmpfilePath(state.io, state.env, &buf);

            var f = try std.Io.Dir.cwd().createFile(state.io, p, .{});
            f.close(state.io);

            break :mkfile p;
        };

        ffi.luaPushString(l, path);
        return 1;
    }
};

const lio = struct {
    const LFile = struct {
        pub const lua_registry_key = "confgen_file";

        file: std.Io.File,
        closed: bool,

        // These exist if the file has been opened in a respective mode.  Their
        // buffers are heap-allocated.
        reader: ?std.Io.File.Reader,
        writer: ?std.Io.File.Writer,

        pub fn initMetatable(l: *c.lua_State) void {
            _ = c.luaL_newmetatable(l, lua_registry_key);
            defer c.lua_pop(l, 1);

            c.lua_pushvalue(l, -1);
            c.lua_setfield(l, -2, "__index");

            c.lua_pushcfunction(l, ffi.luaFunc(lClose));
            c.lua_setfield(l, -2, "__gc");

            c.lua_pushcfunction(l, ffi.luaFuncErrRet(lClose));
            c.lua_setfield(l, -2, "close");

            c.lua_pushcfunction(l, ffi.luaFuncErrRet(lFlush));
            c.lua_setfield(l, -2, "flush");

            c.lua_pushcfunction(l, ffi.luaFuncErrRet(LFile.lLines));
            c.lua_setfield(l, -2, "lines");

            c.lua_pushcfunction(l, ffi.luaFuncErrRet(lRead));
            c.lua_setfield(l, -2, "read");

            c.lua_pushcfunction(l, ffi.luaFuncErrRet(lSeek));
            c.lua_setfield(l, -2, "seek");

            c.lua_pushcfunction(l, ffi.luaFuncErrRet(lWrite));
            c.lua_setfield(l, -2, "write");

            // Lua's std also has `setvbuf` for setting the buffering mode, but we always buffer.
        }

        fn lClose(l: *c.lua_State) !c_int {
            const self = ffi.luaGetUdata(LFile, l, 1);

            if (!self.closed) {
                const state = getState(l);

                state.mtx.unlock(state.io);
                defer state.mtx.lockUncancelable(state.io);

                if (self.reader) |r| {
                    state.alloc.free(r.interface.buffer);
                    self.reader = null;
                }
                if (self.writer) |*w| {
                    w.flush() catch {};
                    state.alloc.free(w.interface.buffer);
                    self.writer = null;
                }

                self.closed = true;
                self.file.close(state.io);
            }

            return 0;
        }

        fn lFlush(l: *c.lua_State) !c_int {
            const self = ffi.luaGetUdata(LFile, l, 1);
            if (self.closed) return 0;
            if (self.writer) |*w| {
                const state = getState(l);

                state.mtx.unlock(state.io);
                defer state.mtx.lockUncancelable(state.io);

                try w.flush();
            }
            return 0;
        }

        fn lLines(l: *c.lua_State) !c_int {
            const Iter = struct {
                fn lReadLine(li: *c.lua_State) !c_int {
                    const self = ffi.luaGetUdata(LFile, li, c.lua_upvalueindex(1));
                    if (self.closed) {
                        c.lua_pushnil(li);
                        return 1;
                    }

                    const state = getState(li);

                    const res = read_line: {
                        state.mtx.unlock(state.io);
                        defer state.mtx.lockUncancelable(state.io);

                        const r = &(self.reader orelse return error.NotOpenForReading);

                        break :read_line try r.interface.takeDelimiter('\n');
                    };

                    if (res) |line| {
                        ffi.luaPushString(li, line);
                    } else {
                        c.lua_pushnil(li);
                    }

                    return 1;
                }
            };

            _ = ffi.luaGetUdata(LFile, l, 1);
            c.lua_pushvalue(l, 1);
            c.lua_pushcclosure(l, ffi.luaFunc(Iter.lReadLine), 1);
            return 1;
        }

        fn lRead(l: *c.lua_State) !c_int {
            const self = ffi.luaGetUdata(LFile, l, 1);

            const Format = union(enum) {
                number, // *n
                all, // *a
                line, // *l
                count: usize,
            };

            const state = getState(l);
            const nfmt = std.math.lossyCast(usize, c.lua_gettop(l) -| 1);
            const formats = try state.alloc.alloc(Format, @max(1, nfmt));
            defer state.alloc.free(formats);

            if (nfmt == 0) {
                formats[0] = .line;
            } else {
                for (0..nfmt) |i| {
                    const idx = 2 + i;
                    if (c.lua_isnumber(l, @intCast(idx)) != 0) {
                        formats[i] = .{
                            .count = std.math.lossyCast(usize, c.lua_tointeger(l, @intCast(idx))),
                        };
                    } else if (c.lua_isstring(l, @intCast(idx)) != 0) {
                        // Since this is only called after lua_isstring returns true, this can't
                        // be null.
                        const str = ffi.luaToString(l, @intCast(idx)) orelse unreachable;
                        if (std.mem.eql(u8, str, "*n"))
                            formats[i] = .number
                        else if (std.mem.eql(u8, str, "*a"))
                            formats[i] = .all
                        else if (std.mem.eql(u8, str, "*l"))
                            formats[i] = .line
                        else {
                            try ffi.luaFmtString(
                                l,
                                "read: invalid format '{s}' at index {}",
                                .{ str, i + 1 },
                            );
                            return error.LuaError;
                        }
                    } else {
                        try ffi.luaFmtString(
                            l,
                            "read: format at index {} has invalid type",
                            .{i + 1},
                        );
                        return error.LuaError;
                    }
                }
            }

            if (self.closed) {
                c.lua_pushnil(l);
                return 1;
            }

            const reader = &(self.reader orelse return error.NotOpenForReading);

            for (formats) |fmt| {
                const ReadResult = union(enum) {
                    end,
                    num: c_int,
                    str: []const u8,
                    str_alloc: []const u8,
                };
                const res: ReadResult = read_one: {
                    state.mtx.unlock(state.io);
                    defer state.mtx.lockUncancelable(state.io);

                    switch (fmt) {
                        .number => {
                            // TODO: implement full scanf-like number parsing
                            var n: c_int = 0;
                            parse: switch (reader.interface.takeByte() catch |e| switch (e) {
                                error.EndOfStream => break :read_one .end,
                                error.ReadFailed => return reader.err.?,
                            }) {
                                '0'...'9' => |ch| {
                                    n *|= 10;
                                    n +|= ch - '0';

                                    continue :parse reader.interface.takeByte() catch |e| switch (e) {
                                        error.EndOfStream => break :read_one .{ .num = n },
                                        error.ReadFailed => return reader.err.?,
                                    };
                                },
                                else => break :read_one .{ .num = n },
                            }
                        },
                        .all => {
                            const rest = reader.interface.allocRemaining(
                                state.alloc,
                                .unlimited,
                            ) catch |e| switch (e) {
                                error.ReadFailed => return reader.err.?,
                                else => return e,
                            };
                            break :read_one .{ .str_alloc = rest };
                        },
                        .line => {
                            const maybe_line =
                                reader.interface.takeDelimiter('\n') catch |e|
                                    switch (e) {
                                        error.ReadFailed => return reader.err.?,
                                        else => return e,
                                    };

                            break :read_one if (maybe_line) |line| .{ .str = line } else .end;
                        },
                        .count => |n| {
                            const read = reader.interface.take(n) catch |e| switch (e) {
                                error.EndOfStream => break :read_one .end,
                                error.ReadFailed => return reader.err.?,
                            };
                            break :read_one .{ .str = read };
                        },
                    }
                };

                switch (res) {
                    .end => c.lua_pushnil(l),
                    .num => |num| c.lua_pushinteger(l, num),
                    .str => |str| ffi.luaPushString(l, str),
                    .str_alloc => |str| {
                        ffi.luaPushString(l, str);
                        state.alloc.free(str);
                    },
                }
            }

            return @intCast(formats.len);
        }

        fn lSeek(l: *c.lua_State) !c_int {
            const self = ffi.luaGetUdata(LFile, l, 1);
            const whence_str = ffi.luaCheckString(l, 2);
            var off = if (c.lua_gettop(l) >= 3) c.luaL_checkinteger(l, 3) else 0;

            const Whence = enum { set, cur, end };

            const whence = std.meta.stringToEnum(Whence, whence_str) orelse {
                try ffi.luaFmtString(l, "seek: invalid whence '{s}'", .{whence_str});
                return error.LuaError;
            };

            const state = getState(l);

            const new_pos = seek: {
                state.mtx.unlock(state.io);
                defer state.mtx.lockUncancelable(state.io);

                mode: switch (whence) {
                    .set => {
                        const pos = std.math.cast(u63, off) orelse 0;
                        if (self.writer) |*w| try w.flush();
                        try state.io.vtable.fileSeekTo(state.io.userdata, self.file, pos);
                        if (self.writer) |*w| w.pos = pos;
                        if (self.reader) |*r| {
                            r.pos = pos;
                            r.interface.tossBuffered();
                        }
                        break :seek pos;
                    },
                    .cur => {
                        const cur = if (self.reader) |r| r.pos else if (self.writer) |w| w.pos else
                            // If we've reached this code, the file is open, in
                            // which case we have at least a reader or writer.
                            unreachable;
                        off +|= std.math.lossyCast(c_long, cur);
                        continue :mode .set;
                    },
                    .end => {
                        const len = try self.file.length(state.io);
                        off += std.math.lossyCast(c_long, len);
                        continue :mode .set;
                    },
                }
            };

            c.lua_pushinteger(l, new_pos);
            return 1;
        }

        fn lWrite(l: *c.lua_State) !c_int {
            const self = ffi.luaGetUdata(LFile, l, 1);
            const n = std.math.lossyCast(usize, c.lua_gettop(l) -| 1);
            if (n == 0 or self.closed) return 0;

            const writer = &(self.writer orelse return error.NotOpenForWriting);

            // push string copies of everything onto the stack
            for (0..n) |i| {
                c.lua_getglobal(l, "tostring");
                c.lua_pushvalue(l, @intCast(i + 2));
                c.lua_call(l, 1, 1);
            }
            defer c.lua_pop(l, @as(c_int, @intCast(n)));

            const state = getState(l);

            const vecs = try state.alloc.alloc([]const u8, n);
            defer state.alloc.free(vecs);

            for (0..n, vecs) |i, *vec| {
                vec.* = ffi.luaToString(l, @intCast(n + i + 2)) orelse
                    // This could theoretically happen if the user overrode `tostring` to something
                    // that doesn't return a string.
                    "";
            }

            {
                state.mtx.unlock(state.io);
                defer state.mtx.lockUncancelable(state.io);

                writer.interface.writeVecAll(vecs) catch |e| switch (e) {
                    error.WriteFailed => return writer.err.?,
                };
            }

            return 0;
        }
    };

    fn lOpen(l: *c.lua_State) !c_int {
        const fname = ffi.luaCheckString(l, 1);

        const Mode = enum { read, write, append };
        var mode: Mode = .read;
        var plus = false;
        if (c.lua_gettop(l) >= 2) {
            const modestr = ffi.luaCheckString(l, 2);
            for (modestr) |m| switch (m) {
                'r' => mode = .read,
                'w' => mode = .write,
                'a' => mode = .append,
                '+' => plus = true,
                else => {},
            };
        }

        const lfile: LFile = open: {
            const state = getState(l);

            state.mtx.unlock(state.io);
            defer state.mtx.lockUncancelable(state.io);

            const std_mode: std.Io.Dir.OpenFileOptions.Mode = if (plus) .read_write else switch (mode) {
                .read => .read_only,
                .write, .append => .write_only,
            };

            const file = switch (mode) {
                .read => try std.Io.Dir.cwd().openFile(state.io, fname, .{
                    .mode = std_mode,
                }),
                .write => try std.Io.Dir.cwd().createFile(state.io, fname, .{
                    .read = plus,
                }),
                .append => try std.Io.Dir.cwd().createFile(state.io, fname, .{
                    .read = plus,
                    .truncate = false,
                }),
            };
            errdefer file.close(state.io);

            const reader = switch (std_mode) {
                .read_only, .read_write => mk: {
                    const buf = try state.alloc.alloc(u8, 1024);
                    break :mk file.reader(state.io, buf);
                },
                .write_only => null,
            };
            errdefer if (reader) |r| state.alloc.free(r.interface.buffer);

            const writer = switch (std_mode) {
                .write_only, .read_write => mk: {
                    const buf = try state.alloc.alloc(u8, 1024);
                    break :mk file.writer(state.io, buf);
                },
                .read_only => null,
            };
            errdefer if (writer) |w| state.alloc.free(w.interface.buffer);

            break :open .{
                .file = file,
                .closed = false,
                .reader = reader,
                .writer = writer,
            };
        };

        const file_ptr = ffi.luaPushUdata(l, LFile);
        file_ptr.* = lfile;
        return 1;
    }

    fn lLines(l: *c.lua_State) !c_int {
        const Iter = struct {
            fn lNext(li: *c.lua_State) !c_int {
                const file = ffi.luaGetUdata(LFile, li, c.lua_upvalueindex(1));
                const state = getState(li);

                const maybe_line = read: {
                    state.mtx.unlock(state.io);
                    defer state.mtx.lockUncancelable(state.io);

                    break :read file.reader.?.interface.takeDelimiter('\n') catch |e| switch (e) {
                        error.ReadFailed => return file.reader.?.err.?,
                        else => return e,
                    };
                };

                if (maybe_line) |line| {
                    ffi.luaPushString(li, line);
                    return 1;
                } else {
                    file.file.close(state.io);
                    file.closed = true;
                    state.alloc.free(file.reader.?.interface.buffer);
                    file.reader = null;
                    c.lua_pushnil(li);
                    return 1;
                }
            }
        };

        const fname = ffi.luaCheckString(l, 1);
        const state = getState(l);

        const handle = open: {
            state.mtx.unlock(state.io);
            defer state.mtx.lockUncancelable(state.io);

            break :open try std.Io.Dir.cwd().openFile(state.io, fname, .{});
        };
        errdefer handle.close(state.io);

        const buf = try state.alloc.alloc(u8, 1024);
        errdefer state.alloc.free(buf);

        const file = ffi.luaPushUdata(l, LFile);
        file.* = .{
            .file = handle,
            .closed = false,

            .reader = handle.reader(state.io, buf),
            .writer = null,
        };
        c.lua_pushcclosure(l, ffi.luaFunc(Iter.lNext), 1);
        return 1;
    }
};

// An alphabet to pick characters for tempfiles from.
const fname_alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

fn mkTmpfilePath(io: std.Io, env: *std.process.Environ.Map, buf: []u8) ![]u8 {
    const tmpdir_env = tmp: {
        for (&[_][]const u8{ "TMP", "TMPDIR", "TEMP", "TEMPDIR" }) |envvar| {
            if (env.get(envvar)) |tmp| break :tmp tmp;
        }

        break :tmp "/tmp";
    };

    const tmpdir = std.mem.trimEnd(u8, tmpdir_env, "/");

    const prefix = "confgen_lua_tmp_";
    const rand_len = 8;

    const total_len = tmpdir.len + 1 + prefix.len + rand_len;
    if (buf.len < total_len) return error.NameTooLong;

    @memcpy(buf[0..tmpdir.len], tmpdir);
    buf[tmpdir.len] = '/';
    @memcpy(buf[tmpdir.len + 1 ..][0..prefix.len], prefix);

    var rand: [rand_len]u8 = undefined;
    io.random(&rand);

    const rand_section = buf[tmpdir.len + 1 + prefix.len ..][0..rand_len];
    for (rand, rand_section) |r, *o| {
        o.* = fname_alphabet[r % fname_alphabet.len];
    }

    return buf[0..total_len];
}

fn getState(l: *c.lua_State) *State {
    c.lua_getfield(l, c.LUA_REGISTRYINDEX, state_key);
    const state_ptr = c.lua_touserdata(l, -1);
    c.lua_pop(l, 1);
    return @ptrCast(@alignCast(state_ptr));
}

/// Creates a new Lua thread, stores it in the registry so it isn't GC'd, then returns it.  Does not
/// modify the current Lua stack.  Caller must later invoke `unregThread` with the returned value.
pub fn regThread(l: *c.lua_State) *c.lua_State {
    const t = c.lua_newthread(l).?;
    c.lua_pushvalue(l, -1); // create copy so we have key/value on stack
    c.lua_settable(l, c.LUA_REGISTRYINDEX);
    return t;
}

pub fn unregThread(t: *c.lua_State) void {
    _ = c.lua_pushthread(t);
    c.lua_pushnil(t);
    c.lua_settable(t, c.LUA_REGISTRYINDEX);
}
