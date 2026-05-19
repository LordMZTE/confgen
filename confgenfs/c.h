// Workaround for some strange translate-c issue.
// See: https://codeberg.org/ziglang/zig/issues/35243
#define __error__(...)

#define FUSE_USE_VERSION 35

#include <fuse.h>
#include <fuse_lowlevel.h>
#include <stdio.h>
