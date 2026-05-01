## wimlib LZX encoder wrapper. Pairs with core/lzx.nim's libmspack
## decoder. See project memory "LZX library split" for why we use
## wimlib for encode and libmspack for decode.
##
## Phase 2b: this module emits a *raw wimlib-shaped* LZX bitstream.
## The CAB-LZX framing (E8 preamble, 24-bit flat block-size) and the
## Method-21 chunk wrapping (`[csize-BE-2]` / `[0xff][usize][csize]`)
## are layered on top in this same file.

{.compile: "../../../csrc/lzx_deflate.c".}
{.compile: "../../../csrc/lzx_deflate_stubs.c".}
{.compile: "../../../vendor/wimlib/src/lzx_compress.c".}
{.compile: "../../../vendor/wimlib/src/lzx_common.c".}
{.compile: "../../../vendor/wimlib/src/compress_common.c".}

const
  DefaultLevel*  = 50         # wimlib's WIM-default compression level.
  Method21Frame* = 32_768     # libmspack realigns bits at every 32 KiB
                               # output boundary; we feed the encoder one
                               # frame-sized chunk at a time so blocks
                               # never straddle a frame boundary.

proc forzaLzxDeflate(inBuf: pointer, inLen: csize_t,
                     outBuf: pointer, outCap: csize_t,
                     level: cuint): clong {.importc: "forza_lzx_deflate".}

proc forzaLzxCreate(level: cuint): pointer {.importc: "forza_lzx_create".}
proc forzaLzxCompressChunk(comp: pointer, inBuf: pointer, inLen: csize_t,
                           outBuf: pointer, outCap: csize_t): clong
                          {.importc: "forza_lzx_compress_chunk".}
proc forzaLzxDestroy(comp: pointer) {.importc: "forza_lzx_destroy".}

proc deflateRaw*(input: openArray[byte],
                level: int = DefaultLevel): seq[byte] =
  ## Encode `input` as a raw wimlib-shaped LZX bitstream. The output is
  ## NOT yet CAB-LZX (no E8 preamble, WIM-style block-size encoding) and
  ## NOT yet method-21 framed (no chunk headers). Layer the framing on
  ## top before writing to a Forza zip.
  ##
  ## Returns an empty seq if the input was incompressible (wimlib
  ## yielded 0). Raises IOError on encoder construction failure.
  if input.len == 0: return @[]
  # wimlib over-allocates internally; an output cap of 1.5× input is a
  # comfortable upper bound (LZX blocks won't exceed input by more than
  # a small Huffman + block-header overhead).
  let cap = max(input.len * 3 div 2, input.len + 1024)
  var buf = newSeq[byte](cap)
  let inP = unsafeAddr input[0]
  let outP = addr buf[0]
  let written = forzaLzxDeflate(inP, csize_t(input.len),
                                outP, csize_t(cap),
                                cuint(level))
  if written < 0:
    raise newException(IOError, "lzx_create_compressor failed")
  if written == 0: return @[]
  buf.setLen(int(written))
  result = buf

proc deflateChunked*(input: openArray[byte],
                     level: int = DefaultLevel): seq[seq[byte]] =
  ## Encode `input` as a sequence of self-contained LZX bitstreams, one
  ## per 32 KiB output frame. State (prev_lens) carries across chunks
  ## via a single reused wimlib compressor — required for libmspack's
  ## decoder, which expects continuous Huffman state across frame
  ## boundaries (it only realigns bits at each boundary).
  ##
  ## The last chunk's input is `≤ 32768` bytes; all others are exactly
  ## 32768. Output is padded to a 16-bit boundary per chunk so the
  ## decoder's frame-boundary realignment lands cleanly. Used by
  ## Method-21 framing to wrap each chunk in a header.
  result = @[]
  if input.len == 0: return
  let comp = forzaLzxCreate(cuint(level))
  if comp.isNil:
    raise newException(IOError, "forza_lzx_create failed")
  defer: forzaLzxDestroy(comp)

  let cap = Method21Frame + 1024
  var buf = newSeq[byte](cap)
  var p = 0
  while p < input.len:
    let take = min(Method21Frame, input.len - p)
    let inP = unsafeAddr input[p]
    let outP = addr buf[0]
    let written = forzaLzxCompressChunk(comp, inP, csize_t(take),
                                         outP, csize_t(cap))
    if written < 0:
      raise newException(IOError,
        "forza_lzx_compress_chunk failed: rc=" & $written)
    if written == 0:
      # Incompressible chunk — caller must fall back to method-0.
      return @[]
    var chunk = newSeq[byte](int(written))
    for i in 0 ..< chunk.len: chunk[i] = buf[i]
    if (chunk.len and 1) != 0: chunk.add(0'u8)
    result.add(chunk)
    inc p, take
