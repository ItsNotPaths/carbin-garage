/* csrc/lzx_deflate.c — single-call wimlib lzx_compress wrapper for Nim FFI.
 *
 * Pairs with csrc/lzx_shim.c (libmspack lzxd, decode side). Two libs,
 * each used for what it does well; see project memory
 * "LZX library split". This shim runs wimlib's lzx_compress over a
 * caller-owned input buffer and writes the resulting bitstream into a
 * caller-owned output buffer.
 *
 * Output format = WIM-LZX raw (no E8 prefix, 1-bit "is default size"
 * block-size encoding). Reframing to CAB-LZX (the format Forza
 * Method-21 expects) and chunking are layered on top in Nim — this
 * shim is the lowest-level "make me a wimlib-shaped bitstream" call.
 *
 * compression_level: wimlib's standard 1..1000 scale. 50 = WIM default.
 * 20 = lazy parsing (fastest); 200+ = several near-optimal passes
 * (slowest, best ratio). 50 is a good baseline.
 */
#include <stddef.h>
#include <string.h>
#include <stdlib.h>

#include "wimlib/compressor_ops.h"

extern const struct compressor_ops lzx_compressor_ops;

/* Compress one buffer with wimlib's LZX encoder.
 * Returns: bytes written to out_buf (>0) on success.
 *          -1 on create_compressor failure (out of memory or invalid params).
 *          0  if the input was incompressible — wimlib's lzx_compress
 *             returns 0 when the encoded size would exceed the input
 *             size. Caller should fall back to method-0 (stored) for
 *             that entry. */
/* Forza Method-21 fixes window_bits=17 (128 KB) — verified across every
 * sample archive (docs/FORZA_LZX_FORMAT.md).  But wimlib derives the
 * Huffman symbol count from the WINDOW_ORDER it picks at create time
 * (which is in turn derived from max_bufsize), and libmspack at
 * window_bits=17 expects num_main_syms to match that pick.  So we
 * always allocate the compressor at the 128 KB tier — even for tiny
 * inputs — to force window_order = 17.  Larger inputs are split into
 * 128 KB-or-smaller pieces upstream; LZX state isn't preserved across
 * separate lzx_compress() calls, so each piece is its own self-
 * contained bitstream (the existing 4 KB roundtrip confirms libmspack
 * accepts that flavor end-to-end). */
#define FORZA_WINDOW_BUFSIZE  (1u << 17)   /* 131072 → window_order = 17 */

long forza_lzx_deflate(const unsigned char *in_buf, size_t in_len,
                       unsigned char *out_buf, size_t out_cap,
                       unsigned compression_level) {
    if (in_len > FORZA_WINDOW_BUFSIZE) return -2;  /* upstream must split */
    void *compressor = NULL;
    int rc = lzx_compressor_ops.create_compressor(FORZA_WINDOW_BUFSIZE,
                                                   compression_level,
                                                   /* destructive = */ 0,
                                                   &compressor);
    if (rc != 0 || compressor == NULL) return -1;

    size_t written = lzx_compressor_ops.compress(in_buf, in_len,
                                                  out_buf, out_cap,
                                                  compressor);
    lzx_compressor_ops.free_compressor(compressor);
    return (long)written;
}

/* Stateful API for chunked Method-21 streams.  Forza concatenates 32 KiB
 * frames sharing Huffman state across boundaries — one wimlib compressor
 * is reused for every chunk so prev_lens persists.  Patched wimlib (see
 * patches/wimlib_lzx_cab_compat.patch) is required: stock wimlib zeroes
 * prev_lens on each compress() call. */

void *forza_lzx_create(unsigned compression_level) {
    void *compressor = NULL;
    int rc = lzx_compressor_ops.create_compressor(FORZA_WINDOW_BUFSIZE,
                                                   compression_level,
                                                   /* destructive = */ 0,
                                                   &compressor);
    if (rc != 0) return NULL;
    return compressor;
}

long forza_lzx_compress_chunk(void *compressor,
                              const unsigned char *in_buf, size_t in_len,
                              unsigned char *out_buf, size_t out_cap) {
    if (compressor == NULL) return -1;
    if (in_len > FORZA_WINDOW_BUFSIZE) return -2;
    size_t written = lzx_compressor_ops.compress(in_buf, in_len,
                                                  out_buf, out_cap,
                                                  compressor);
    return (long)written;
}

void forza_lzx_destroy(void *compressor) {
    if (compressor) lzx_compressor_ops.free_compressor(compressor);
}
