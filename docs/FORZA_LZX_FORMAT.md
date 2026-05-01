# Forza FM4 / FH1 ZIP Method-21 (LZX) Container Format

Per-car archives in both games (`Media/cars/<CAR>.zip`) use PKZip with
**compression method 21**, which is **Microsoft LZX** with chunk framing.
Standard tools (`unzip`, `7z`, `unar`) all fail. Decompression works
through a small driver around libmspack's `lzxd`.

## Outer container

Standard PKZip with central directory. Method per entry can be:

- **0** (stored) — rare, used for a couple of leftover files in some archives
- **21** — Microsoft LZX with the framing below

Walk the central directory yourself; Python's `zipfile` rejects method 21.
See `probe/lzxzip.py:list_entries` for a working parser.

## Inner framing (method 21)

Each method-21 entry's payload is a sequence of LZX **chunks** that share
Huffman-table state across chunk boundaries (CAB-style continuous stream,
not independent frames). The chunks are wrapped in one of two headers:

| Header | Bytes | Meaning |
|---|---|---|
| Full chunk | `[csize-BE-2]` | Decompresses to exactly **32768** output bytes |
| Final / single chunk | `[0xff][usize-BE-2][csize-BE-2]` | Decompresses to exactly `usize` bytes (≤ 32768) |

A small file (uncompressed size ≤ 32768) is just the single-chunk variant.
A large file is N full chunks followed by one final chunk of the partial
form. The `0xff` byte is the discriminator — it's never the high byte of
a real `csize` because LZX chunks never compress to `≥ 0xff00` bytes
(they cap at 32768 = 0x8000 input, so output csize is always < 0x8000
plus a small header overhead).

## Decoder parameters

- **window_bits = 17** (128 KB window). Verified across small XML, mid
  binaries, and multi-MB carbins/textures. Same value used for every file
  in every archive seen so far.
- **reset_interval = 0** (no reset; Huffman state persists across chunks).
- **is_delta = 0** (regular LZX, not LZX-DELTA).

## Decoder algorithm

```
1. Walk the chunk headers; concatenate just the LZX bitstreams (skip the
   2-byte or 5-byte headers).
2. Feed the concatenated bitstream to lzxd_init(window_bits=17,
   reset_interval=0, output_length=usize), then lzxd_decompress(usize).
3. Done — output matches expected uncompressed size on every file tested.
```

The "concatenate stripped chunks → single lzxd call" approach is
necessary because the chunks share Huffman state. Decompressing each
chunk with its own `lzxd_init` produces err=11 (decrunch error) on
every chunk after the first.

## Reference implementation

- C driver: `probe/c/lzx_inflate.c` (links libmspack `lzxd.c` + `system.c`,
  no autotools dependency — just `make`).
- Python wrapper: `probe/lzxzip.py` (`list_entries`, `extract`,
  `_strip_lzx_chunks`).
- Verified on: every file in every archive across 79 shared cars (carbins,
  XDS textures, all XML, livery TGAs, dash bgf/bsg/fbf, physicsdefinition.bin).

## Encoding

**Decode-only for now.** libmspack's `lzxc.c` is the encoder side and
ships in the same tree, so a future round-trip is feasible — but unverified
against the game runtime. For early-port experiments, a fallback is to
re-pack changed entries with method 0 (stored) and test whether the FH1
loader accepts mixed-method archives. Not yet attempted.

## What `0xff` is, mechanically

The `0xff` byte is the high byte of a 16-bit field that, in normal
chunks, encodes `csize` (always < 32768 = 0x8000). When `0xff` shows up
the runtime knows the chunk is the last/only one and reads the 4 bytes
that follow as `[usize-BE-2][csize-BE-2]`. It's not a "magic" — it's a
disambiguator that exploits a value out of csize's natural range.
