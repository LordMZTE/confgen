const std = @import("std");
const c = @import("ffi.zig").c;

/// Tries to find the confgen.lua file by walking up the directory tree.
/// Returns the directory path, NOT THE FILE PATH.
/// Returned path is malloc'd
pub fn findRootDir() !?[]const u8 {
    // TODO: walk upwards
    _ = std.fs.cwd().statFile("confgen.lua") catch |e| {
        if (e == error.FileNotFound) {
            return null;
        }

        return e;
    };

    return try std.heap.c_allocator.dupe(u8, ".");
}
