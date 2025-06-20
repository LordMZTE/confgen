#define FUSE_USE_VERSION 35

#include <fuse.h>

/// A small function which extracts major and minor protocol versions from fuse_conn_info. This is
/// implemented in C because fuse_conn_info contains a bitfield, so Zig can't translate it. We could
/// have declared it ourselves in Zig, but this would be prone to being broken by API changes
/// without us noticing.
void confgenfsGetFuseVersionFromConnInfo(struct fuse_conn_info *cinf, uint32_t *maj_out, uint32_t *min_out) {
    *maj_out = cinf->proto_major;
    *min_out = cinf->proto_minor;
}
