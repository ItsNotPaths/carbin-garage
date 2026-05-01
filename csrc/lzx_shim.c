/* lzx_shim.c — single-call libmspack lzxd wrapper for Nim FFI.
 *
 * Forza Method-21 zip entries are LZX with chunked framing; the caller
 * (zip21.nim) strips the framing and passes a contiguous LZX bitstream.
 * This shim runs lzxd_decompress on that bitstream into a caller-owned
 * output buffer. Window_bits=17, reset_interval=0 — verified against
 * every Forza FM4/FH1 archive. See docs/FORZA_LZX_FORMAT.md.
 */
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <sys/types.h>

#include "mspack.h"
#include "system.h"
#include "lzx.h"

struct mem_in {
    const unsigned char *buf;
    size_t len;
    size_t pos;
};

struct mem_out {
    unsigned char *buf;
    size_t cap;
    size_t pos;
};

static struct mspack_file *mem_open(struct mspack_system *self, const char *fn, int mode) {
    (void)self; (void)fn; (void)mode;
    return NULL;
}
static void mem_close(struct mspack_file *f) { (void)f; }

static int mem_read(struct mspack_file *f, void *buf, int bytes) {
    struct mem_in *m = (struct mem_in *)f;
    size_t avail = m->len - m->pos;
    size_t take = (size_t)bytes < avail ? (size_t)bytes : avail;
    memcpy(buf, m->buf + m->pos, take);
    m->pos += take;
    return (int)take;
}
static int mem_write(struct mspack_file *f, void *buf, int bytes) {
    struct mem_out *o = (struct mem_out *)f;
    size_t avail = o->cap - o->pos;
    size_t take = (size_t)bytes < avail ? (size_t)bytes : avail;
    memcpy(o->buf + o->pos, buf, take);
    o->pos += take;
    return (int)take;
}
static int mem_seek(struct mspack_file *f, off_t off, int mode) {
    struct mem_in *m = (struct mem_in *)f;
    size_t np;
    if (mode == MSPACK_SYS_SEEK_START) np = (size_t)off;
    else if (mode == MSPACK_SYS_SEEK_CUR) np = m->pos + (size_t)off;
    else if (mode == MSPACK_SYS_SEEK_END) np = m->len + (size_t)off;
    else return -1;
    if (np > m->len) return -1;
    m->pos = np;
    return 0;
}
static off_t mem_tell(struct mspack_file *f) {
    return (off_t)((struct mem_in *)f)->pos;
}
static void *m_alloc(struct mspack_system *self, size_t n) { (void)self; return malloc(n); }
static void m_free(void *p) { free(p); }
static void m_copy(void *src, void *dst, size_t n) { memcpy(dst, src, n); }
static void m_msg(struct mspack_file *f, const char *fmt, ...) { (void)f; (void)fmt; }

static struct mspack_system FORZA_SYS = {
    mem_open, mem_close, mem_read, mem_write, mem_seek, mem_tell, m_msg,
    m_alloc, m_free, m_copy, NULL,
};

/* Inflate one contiguous LZX bitstream (chunk framing already stripped).
 * Returns 0 on success, libmspack MSPACK_ERR_* (non-zero) on failure. */
int forza_lzx_inflate(const unsigned char *in_buf, size_t in_len,
                      unsigned char *out_buf, size_t out_len,
                      int window_bits) {
    struct mem_in mi = { in_buf, in_len, 0 };
    struct mem_out mo = { out_buf, out_len, 0 };
    struct lzxd_stream *lzx = lzxd_init(&FORZA_SYS,
                                        (struct mspack_file *)&mi,
                                        (struct mspack_file *)&mo,
                                        window_bits,
                                        0,        /* reset_interval = 0 */
                                        4096,
                                        (off_t)out_len,
                                        0);
    if (!lzx) return -1;
    int err = lzxd_decompress(lzx, (off_t)out_len);
    lzxd_free(lzx);
    if (err != MSPACK_ERR_OK) return err;
    if (mo.pos != out_len) return -2;
    return 0;
}
