## libmspack LZX decompressor wrapper. Mirrors probe/c/lzx_inflate.c
## via the csrc/lzx_shim.c bridge. window_bits=17, reset_interval=0
## — verified across all Forza method-21 archives (docs/FORZA_LZX_FORMAT.md).
##
## Encoder is wimlib's lzx_compress in csrc/lzx_deflate.c (TBD). libmspack
## ships no encoder; wimlib's decoder is WIM-LZX-restricted and isn't a
## fit for CAB-LZX bitstreams. Two libs, each used for what it does well.

{.compile: "../../../csrc/lzx_shim.c".}
{.compile: "../../../vendor/libmspack/libmspack/mspack/lzxd.c".}
{.compile: "../../../vendor/libmspack/libmspack/mspack/system.c".}

const WINDOW_BITS_FORZA* = 17

proc forzaLzxInflate(inBuf: pointer, inLen: csize_t,
                     outBuf: pointer, outLen: csize_t,
                     windowBits: cint): cint {.importc: "forza_lzx_inflate".}

proc inflate*(stripped: openArray[byte], usize: int,
              windowBits: int = WINDOW_BITS_FORZA): seq[byte] =
  ## Decompress one contiguous LZX bitstream (caller has already stripped
  ## the 2- or 5-byte chunk headers — see zip21.stripLzxChunks).
  ## `usize` is the known uncompressed size (from the zip cdir).
  result = newSeq[byte](usize)
  if usize == 0: return
  let inP = if stripped.len > 0: unsafeAddr stripped[0] else: nil
  let outP = addr result[0]
  let rc = forzaLzxInflate(inP, csize_t(stripped.len),
                           outP, csize_t(usize),
                           cint(windowBits))
  if rc != 0:
    raise newException(IOError,
      "lzxd_decompress failed: rc=" & $rc & " (in_len=" & $stripped.len &
      ", out_len=" & $usize & ")")
