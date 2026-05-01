## .xds → RGBA decoder. Phase 2c.1.
##
## .xds wraps an Xbox 360 D3DBaseTexture (52-byte header) followed by a
## tiled, 8-in-16 byte-swapped BC payload. To get a PC-renderable image:
##   1. Read header → format / width / height
##   2. For each (blockX, blockY): compute the Xenon-tiled byte offset,
##      8-in-16 byte-swap that BC block, decode via bcdec into RGBA8.
##
## Format support: BC1 (DXT1, fmt=18), BC3 (DXT4_5, fmt=20), BC5 (DXN,
## fmt=49). Others surface as "format not yet wired".
##
## Spec: docs/FM4_CARBIN_MASTER.md §18.3 (D3DBaseTexture).

import ./be
import ./bc

{.compile: "../../../csrc/stb_image_write_impl.c".}
{.compile: "../../../csrc/stb_image_impl.c".}
{.compile: "../../../csrc/stb_dxt_impl.c".}

proc stbi_write_png(filename: cstring, w, h, comp: cint,
                    data: pointer, strideBytes: cint): cint
                    {.importc, header: "stb_image_write.h".}

proc stbi_load(filename: cstring, x, y, channels_in_file: ptr cint,
               desired_channels: cint): ptr uint8
              {.importc, header: "stb_image.h".}
proc stbi_image_free(retval_from_stbi_load: pointer)
              {.importc, header: "stb_image.h".}
proc stbi_failure_reason(): cstring
              {.importc, header: "stb_image.h".}

proc stb_compress_dxt_block(dest: pointer, src_rgba: pointer,
                            alpha: cint, mode: cint)
                            {.importc, header: "stb_dxt.h".}
proc stb_compress_bc5_block(dest: pointer, src_rg: pointer)
                            {.importc, header: "stb_dxt.h".}

const
  XdsHeaderSize* = 52  # D3DResource(24) + MipFlush(4) + GPUTEXTURE_FETCH_CONSTANT(24)

  # GPUTEXTUREFORMAT subset we wire in for car textures.
  # Xenia's xenos.h enum: every BC format also has an "AS_16_16_16_16"
  # sampler-hint variant whose compressed payload is byte-identical to
  # the base format — same block size, same decoder. We treat the
  # variant codes as aliases.
  FmtDxt1*     = 18  # BC1   (8 bytes/block)
  FmtDxt2_3*   = 19  # BC2   (16 bytes/block) — rare in car textures
  FmtDxt4_5*   = 20  # BC3   (16 bytes/block)
  FmtDxn*      = 49  # BC5   (16 bytes/block)
  FmtDxt1As16*   = 51  # BC1, sampler hint
  FmtDxt2_3As16* = 52  # BC2, sampler hint
  FmtDxt4_5As16* = 53  # BC3, sampler hint  ← FM4 nodamage atlas uses this

type
  XdsHeader* = object
    dataFormat*: int        # GPUTEXTUREFORMAT
    width*, height*: int    # in texels
    mipMin*, mipMax*: int   # mip range encoded in last word; 0/0 if absent
    payloadOffset*: int     # = XdsHeaderSize (constant for now)
    payloadSize*: int

  XdsImage* = object
    width*, height*: int
    rgba*: seq[uint8]       # width * height * 4 bytes

proc bcBlockSize(fmt: int): int =
  case fmt
  of FmtDxt1, FmtDxt1As16: 8
  of FmtDxt2_3, FmtDxt2_3As16, FmtDxt4_5, FmtDxt4_5As16, FmtDxn: 16
  else: 0

proc parseXdsHeader*(data: openArray[byte]): XdsHeader =
  ## Read the 52-byte D3DBaseTexture header. Big-endian on disk.
  ## Word layout (after 28 bytes of D3DResource + MipFlush):
  ##   Word0 (0x1C): type:2 sign:8 clamp:9 pad:3 pitch:9 tiled:1
  ##   Word1 (0x20): dataFormat:6 endian:2 reqSize:2 stacked:1 clampPolicy:1 baseAddr:20
  ##   Word2 (0x24): width:13 height:13 depth:6   (each stored as N-1)
  ##   Word3 (0x28): numFormat:1 swizzle:12 expAdjust:6 magFilter:2 minFilter:2 ...
  ##   Word4 (0x2C): borderColor / lodBias / ...
  ##   Word5 (0x30): mipMaxLevel:4 mipMinLevel:4 ...
  if data.len < XdsHeaderSize:
    raise newException(ValueError, "xds too small for D3DBaseTexture header")

  var r = newBEReader(data)
  r.seek(0x20)
  let word1 = r.u32()
  r.seek(0x24)
  let word2 = r.u32()
  r.seek(0x30)
  let word5 = r.u32()

  result.dataFormat = int(word1 and 0x3F'u32)
  # Width / Height stored as (N - 1). Bit layout in the bit-packed dword
  # is: width occupies bits 0..12, height bits 13..25, depth bits 26..31.
  result.width  = int((word2 and 0x1FFF'u32) + 1)
  result.height = int(((word2 shr 13) and 0x1FFF'u32) + 1)
  # Mip range: top byte of word5 holds 4-bit min and 4-bit max. We don't
  # use these yet (Phase 2c.1 = top mip only) but record them so the
  # decoder can extend later.
  result.mipMin = int((word5 shr 24) and 0xF'u32)
  result.mipMax = int((word5 shr 28) and 0xF'u32)

  result.payloadOffset = XdsHeaderSize
  result.payloadSize = data.len - XdsHeaderSize

proc swap8in16(buf: var openArray[byte], start, count: int) =
  ## Xbox 360 textures use the GPUENDIAN_8IN16 byte-swap. Each pair of
  ## bytes is swapped before the GPU consumes it; on PC we have to undo
  ## that swap before handing the BC block to bcdec.
  var i = start
  let endPos = start + count
  while i + 1 < endPos:
    swap(buf[i], buf[i + 1])
    i += 2

proc tiledX(blockOffset, widthBlocks, texelPitch: int): int =
  ## Canonical XGAddress2DTiledX. Port of the Python source
  ## leeao/Noesis-Plugins inc_xbox360_untile.py — the published formula
  ## has been hand-verified against Xbox 360 BC3 dumps for years and is
  ## the version Noesis itself ships. blockOffset = linear block index
  ## (j*widthBlocks + i); texelPitch = bytes per BC block (8 BC1, 16 BC3/5).
  let alignedW = (widthBlocks + 31) and (not 31)
  let logBpp = (texelPitch shr 2) + ((texelPitch shr 1) shr (texelPitch shr 2))
  let offB = blockOffset shl logBpp
  let offT = ((offB and (not 4095)) shr 3) + ((offB and 1792) shr 2) + (offB and 63)
  let offM = offT shr (7 + logBpp)
  let macroX = ((offM mod (alignedW shr 5)) shl 2)
  let tile = ((((offT shr (5 + logBpp)) and 2) + (offB shr 6)) and 3)
  let macroOff = (macroX + tile) shl 3
  let micro = ((((offT shr 1) and (not 15)) + (offT and 15)) and
               ((texelPitch shl 3) - 1)) shr logBpp
  result = macroOff + micro

proc tiledY(blockOffset, widthBlocks, texelPitch: int): int =
  ## Canonical XGAddress2DTiledY — paired with tiledX above.
  let alignedW = (widthBlocks + 31) and (not 31)
  let logBpp = (texelPitch shr 2) + ((texelPitch shr 1) shr (texelPitch shr 2))
  let offB = blockOffset shl logBpp
  let offT = ((offB and (not 4095)) shr 3) + ((offB and 1792) shr 2) + (offB and 63)
  let offM = offT shr (7 + logBpp)
  let macroY = ((offM div (alignedW shr 5)) shl 2)
  let tile = ((offT shr (6 + logBpp)) and 1) + ((offB and 2048) shr 10)
  let macroOff = (macroY + tile) shl 3
  let micro = ((((offT and (((texelPitch shl 6) - 1) and (not 31))) +
                ((offT and 15) shl 1)) shr (3 + logBpp)) and (not 1))
  result = macroOff + micro + ((offT and 16) shr 4)

proc decodeBcBlockToRgba(blk: openArray[byte], fmt: int,
                         dst: var openArray[uint8], dstStride: int) =
  ## Decode one BC block into a 4×4 RGBA8 tile. dst is the start of the
  ## tile's top-left texel; dstStride is bytes-per-row of the destination.
  case fmt
  of FmtDxt1, FmtDxt1As16:
    bcdec_bc1(unsafeAddr blk[0], addr dst[0], cint(dstStride))
  of FmtDxt4_5, FmtDxt4_5As16:
    bcdec_bc3(unsafeAddr blk[0], addr dst[0], cint(dstStride))
  of FmtDxn:
    # BC5 = two-channel (R,G); bcdec writes into a 4×4 RG buffer. We
    # widen to RGBA by setting B=0, A=255 below — but bcdec_bc5 already
    # writes 4 channels into the destination if pitch is set right. The
    # bcdec convention is: pass pitch as bytes-per-row of the *RG* output
    # (8 bytes for 4 RG-pairs). For our purposes (preview), a quick wrap
    # decodes BC5 into RG and we expand.
    var tmp: array[4 * 4 * 2, uint8]
    bcdec_bc5(unsafeAddr blk[0], addr tmp[0], cint(8))
    for ty in 0 .. 3:
      for tx in 0 .. 3:
        let s = (ty * 4 + tx) * 2
        let d = ty * dstStride + tx * 4
        dst[d + 0] = tmp[s + 0]
        dst[d + 1] = tmp[s + 1]
        dst[d + 2] = 0
        dst[d + 3] = 255
  else:
    raise newException(ValueError, "unsupported BC format: " & $fmt)

proc decodeXds*(data: openArray[byte], detile: bool = true,
                 endianSwap: bool = true): XdsImage =
  ## End-to-end: header → (optional detile) → (optional 8-in-16 swap) →
  ## bcdec → RGBA8 buffer. Top mip only for now.
  ## detile=false  → decode blocks in row-major order (bug-isolation aid)
  ## endianSwap=false → skip the 8-in-16 byte pair swap
  let h = parseXdsHeader(data)
  let bpb = bcBlockSize(h.dataFormat)
  if bpb == 0:
    raise newException(ValueError,
      "xds format not yet wired: " & $h.dataFormat &
      " (supported: 18=DXT1, 20=DXT4_5, 49=DXN)")
  if (h.width and 3) != 0 or (h.height and 3) != 0:
    raise newException(ValueError,
      "xds dimensions not 4-aligned: " & $h.width & "x" & $h.height)

  let widthBlocks  = h.width  div 4
  let heightBlocks = h.height div 4
  let alignedW     = (widthBlocks + 31) and (not 31)
  let alignedH     = (heightBlocks + 31) and (not 31)

  let payloadEnd = h.payloadOffset + alignedW * alignedH * bpb
  if payloadEnd > data.len:
    raise newException(ValueError,
      "xds payload truncated: need " & $payloadEnd & " bytes, have " & $data.len)

  result.width  = h.width
  result.height = h.height
  result.rgba   = newSeq[uint8](h.width * h.height * 4)

  # Step 1: untile. Walk the on-disk (tiled) BC payload in linear order
  # — that's the order the Xenon GPU's swizzle Z-curves through. For
  # each linear-on-disk block index, the canonical XGAddress2DTiledX/Y
  # returns the *logical* (x, y) where that block belongs in row-major
  # space. Skip blocks whose (x, y) falls in the macro-tile padding
  # zone outside the actual image.
  let linearBlocks = widthBlocks * heightBlocks
  var linearBC = newSeq[byte](linearBlocks * bpb)
  let totalDiskBlocks = alignedW * alignedH
  for n in 0 ..< totalDiskBlocks:
    let lx = if detile: tiledX(n, widthBlocks, bpb) else: n mod widthBlocks
    let ly = if detile: tiledY(n, widthBlocks, bpb) else: n div widthBlocks
    if lx < 0 or lx >= widthBlocks or ly < 0 or ly >= heightBlocks: continue
    let srcOff = h.payloadOffset + n * bpb
    if srcOff + bpb > data.len: continue
    let dstIdx = (ly * widthBlocks + lx) * bpb
    for i in 0 ..< bpb:
      linearBC[dstIdx + i] = byte(data[srcOff + i])

  # Step 2: row-major BC walk → bcdec → RGBA8.
  var blkBuf: array[16, byte]
  for by in 0 ..< heightBlocks:
    for bx in 0 ..< widthBlocks:
      let off = (by * widthBlocks + bx) * bpb
      for i in 0 ..< bpb:
        blkBuf[i] = linearBC[off + i]
      if endianSwap:
        swap8in16(blkBuf, 0, bpb)
      let dstX = bx * 4
      let dstY = by * 4
      let dstOff = (dstY * h.width + dstX) * 4
      decodeBcBlockToRgba(toOpenArray(blkBuf, 0, bpb - 1), h.dataFormat,
                          toOpenArray(result.rgba, dstOff,
                                       result.rgba.high),
                          h.width * 4)

proc readPng*(path: string): XdsImage =
  ## Decode any image stb_image supports (PNG / TGA / BMP / JPEG / PSD)
  ## into the canonical RGBA8 buffer. The file at `path` must exist;
  ## raises IOError on parse failure.
  var w, h, ch: cint
  let raw = stbi_load(path.cstring, addr w, addr h, addr ch, cint(4))
  if raw == nil:
    let reason = $stbi_failure_reason()
    raise newException(IOError, "stbi_load failed: " & path & " (" & reason & ")")
  defer: stbi_image_free(raw)
  let n = int(w) * int(h) * 4
  result.width = int(w)
  result.height = int(h)
  result.rgba = newSeq[uint8](n)
  copyMem(addr result.rgba[0], raw, n)

proc writePng*(path: string, img: XdsImage) =
  ## Wraps stb_image_write. Returns silently on success; raises on failure.
  let rc = stbi_write_png(path.cstring,
                          cint(img.width), cint(img.height), cint(4),
                          unsafeAddr img.rgba[0],
                          cint(img.width * 4))
  if rc == 0:
    raise newException(IOError, "stbi_write_png failed: " & path)

proc writePpm*(path: string, img: XdsImage) =
  ## Plain PPM (P6) — RGB only, no alpha. Useful as a no-deps fallback
  ## when validating the decoder output before involving stb_image_write.
  var f = open(path, fmWrite)
  defer: f.close()
  f.write("P6\n" & $img.width & " " & $img.height & "\n255\n")
  var row = newSeq[uint8](img.width * 3)
  for y in 0 ..< img.height:
    for x in 0 ..< img.width:
      let s = (y * img.width + x) * 4
      let d = x * 3
      row[d + 0] = img.rgba[s + 0]
      row[d + 1] = img.rgba[s + 1]
      row[d + 2] = img.rgba[s + 2]
    discard f.writeBytes(row, 0, row.len)

proc formatName*(fmt: int): string =
  case fmt
  of FmtDxt1:        "DXT1 (BC1)"
  of FmtDxt2_3:      "DXT2/3 (BC2)"
  of FmtDxt4_5:      "DXT4/5 (BC3)"
  of FmtDxn:         "DXN (BC5)"
  of FmtDxt1As16:    "DXT1_AS_16 (BC1)"
  of FmtDxt2_3As16:  "DXT2/3_AS_16 (BC2)"
  of FmtDxt4_5As16:  "DXT4/5_AS_16 (BC3)"
  else:              "unknown(" & $fmt & ")"

# ---------------------------------------------------------------------------
# Encode side (Phase 2c.3). Inverse of the decode pipeline above.
# Pipeline: RGBA8 → 4×4 BC blocks (stb_dxt) → Xenon retile → 8-in-16 swap →
# concat with the original 52-byte header (or rebuild it).
#
# stb_dxt is non-deterministic across implementations; PNG → BC → PNG is
# never byte-equal vs an NVTT-encoded original. Validation is SSIM ≥ 0.95
# + in-game test, per feedback_validation_strategy memory.
# ---------------------------------------------------------------------------

const
  StbDxtNormal*   = 0
  StbDxtHighQual* = 2

proc encodeBcBlockFromRgba(src: openArray[uint8], srcStride: int,
                           fmt: int, mode: cint,
                           dst: var openArray[byte]) =
  ## Compress one 4×4 RGBA8 tile into the on-disk BC block. `srcStride` =
  ## bytes per row of the RGBA source. `dst` must be ≥ block size for fmt.
  ## stb_dxt expects a packed 4×4×4 RGBA buffer in row-major order, so we
  ## copy out of the strided source.
  var packed: array[64, uint8]
  for ty in 0 .. 3:
    for tx in 0 .. 3:
      let s = ty * srcStride + tx * 4
      let d = (ty * 4 + tx) * 4
      packed[d + 0] = src[s + 0]
      packed[d + 1] = src[s + 1]
      packed[d + 2] = src[s + 2]
      packed[d + 3] = src[s + 3]
  case fmt
  of FmtDxt1, FmtDxt1As16:
    # alpha=0 → BC1 (8 bytes). The alpha channel is ignored on encode but
    # stb_dxt warns it must contain *some* value; we filled it above.
    stb_compress_dxt_block(addr dst[0], addr packed[0], cint(0), mode)
  of FmtDxt4_5, FmtDxt4_5As16:
    # alpha=1 → BC3 (16 bytes).
    stb_compress_dxt_block(addr dst[0], addr packed[0], cint(1), mode)
  of FmtDxn:
    # BC5 = two-channel (R,G); stb_compress_bc5_block expects an RG buffer
    # (8 bytes for 4 RG-pairs per row × 4 rows = 32 bytes). Pull RG out of
    # the RGBA source.
    var rg: array[32, uint8]
    for ty in 0 .. 3:
      for tx in 0 .. 3:
        let s = (ty * 4 + tx) * 4
        let d = (ty * 4 + tx) * 2
        rg[d + 0] = packed[s + 0]
        rg[d + 1] = packed[s + 1]
    stb_compress_bc5_block(addr dst[0], addr rg[0])
  else:
    raise newException(ValueError, "unsupported BC format on encode: " & $fmt)

proc encodePayload*(rgba: openArray[uint8], width, height, fmt: int,
                    mode: cint = StbDxtNormal): seq[byte] =
  ## RGBA8 → on-disk Xenon-tiled, 8-in-16-swapped BC payload for ONE mip
  ## level. Output length = alignedW * alignedH * blockSize, matching
  ## what decodeXds reads. The full mip chain is built by
  ## encodePayloadWithMips below, which calls this once per level.
  let bpb = bcBlockSize(fmt)
  if bpb == 0:
    raise newException(ValueError, "encodePayload: unsupported format " & $fmt)
  if (width and 3) != 0 or (height and 3) != 0:
    raise newException(ValueError,
      "encodePayload: dims not 4-aligned: " & $width & "x" & $height)
  if rgba.len < width * height * 4:
    raise newException(ValueError,
      "encodePayload: rgba buffer too small (" & $rgba.len &
      " < " & $(width * height * 4) & ")")

  let widthBlocks  = width  div 4
  let heightBlocks = height div 4
  let alignedW     = (widthBlocks + 31) and (not 31)
  let alignedH     = (heightBlocks + 31) and (not 31)

  # Step 1: BC-encode every 4×4 tile in row-major order.
  var linearBC = newSeq[byte](widthBlocks * heightBlocks * bpb)
  for by in 0 ..< heightBlocks:
    for bx in 0 ..< widthBlocks:
      let srcOff = (by * 4) * (width * 4) + bx * 4 * 4
      let dstOff = (by * widthBlocks + bx) * bpb
      encodeBcBlockFromRgba(
        toOpenArray(rgba, srcOff, rgba.high),
        width * 4, fmt, mode,
        toOpenArray(linearBC, dstOff, linearBC.high))

  # Step 2: scatter row-major BC blocks into Xenon-tiled positions
  # (inverse of the decode-side detile loop). For each *disk* index n,
  # ask tiledX/Y where it lives in row-major space, then copy that block
  # to disk position n. Padding blocks (lx/ly outside the image) get
  # zeros — the GPU never reads them, so any value works as long as
  # decode's bounds check skips them, which it does.
  let totalDiskBlocks = alignedW * alignedH
  result = newSeq[byte](totalDiskBlocks * bpb)
  for n in 0 ..< totalDiskBlocks:
    let lx = tiledX(n, widthBlocks, bpb)
    let ly = tiledY(n, widthBlocks, bpb)
    if lx < 0 or lx >= widthBlocks or ly < 0 or ly >= heightBlocks: continue
    let srcIdx = (ly * widthBlocks + lx) * bpb
    let dstIdx = n * bpb
    for i in 0 ..< bpb:
      result[dstIdx + i] = linearBC[srcIdx + i]

  # Step 3: 8-in-16 endian swap, in place. Inverse is the same swap
  # (it's an involution).
  swap8in16(result, 0, result.len)

proc downsample2x2(src: openArray[uint8], srcW, srcH: int): seq[uint8] =
  ## Box-filter 2×2 → 1 RGBA8. Returns dst rgba (dstW * dstH * 4 bytes).
  ## Used to produce mip level N+1 from level N. Box filter is what
  ## stb_dxt's "generate mips" path uses internally; matches what shipped
  ## .xds files were encoded against (NVTT default = box for color, box
  ## or kaiser for normals — for visual edits at runtime, box is fine).
  let dstW = max(srcW div 2, 1)
  let dstH = max(srcH div 2, 1)
  result = newSeq[uint8](dstW * dstH * 4)
  for y in 0 ..< dstH:
    for x in 0 ..< dstW:
      var sum: array[4, int]
      for dy in 0 .. 1:
        for dx in 0 .. 1:
          let sx = min(x * 2 + dx, srcW - 1)
          let sy = min(y * 2 + dy, srcH - 1)
          let s = (sy * srcW + sx) * 4
          for c in 0 .. 3:
            sum[c] += int(src[s + c])
      let d = (y * dstW + x) * 4
      for c in 0 .. 3:
        result[d + c] = uint8((sum[c] + 2) shr 2)

proc mipPayloadSize(width, height, fmt: int): int =
  ## On-disk byte count for one Xenon-tiled mip level.
  let bpb = bcBlockSize(fmt)
  let aW = ((width  div 4) + 31) and (not 31)
  let aH = ((height div 4) + 31) and (not 31)
  result = aW * aH * bpb

proc inferMipCount*(width, height, fmt, payloadBytes: int): int =
  ## Reverse-engineer how many mip levels were in an existing .xds by
  ## summing the per-mip payload sizes until we hit (or pass) the
  ## measured payload byte count. Used to decide chain length on
  ## re-encode: UI textures ship 1 mip, world textures ship until
  ## min(w,h) reaches 16. Returning the original count exactly preserves
  ## byte-size parity with the source file.
  var w = width
  var h = height
  var consumed = 0
  result = 0
  while w >= 4 and h >= 4 and consumed < payloadBytes:
    consumed += mipPayloadSize(w, h, fmt)
    inc result
    w = w div 2
    h = h div 2
    if w < 4: w = 4
    if h < 4: h = 4
    if result > 16: break  # safety cap (Xbox 360 max levels for 2¹⁶)
  if result < 1: result = 1

proc encodePayloadChain*(rgba: openArray[uint8], width, height, fmt: int,
                        mipCount: int,
                        mode: cint = StbDxtNormal): seq[byte] =
  ## Encode `mipCount` mip levels starting from the supplied top-mip RGBA.
  ## Each level is Xenon-tiled and 8-in-16-swapped independently. Levels
  ## past the first are box-filtered down from the previous level (matches
  ## NVTT's default for color textures).
  if mipCount < 1:
    raise newException(ValueError, "encodePayloadChain: mipCount must be ≥ 1")
  result = encodePayload(rgba, width, height, fmt, mode)
  if mipCount == 1: return
  var cur = @rgba
  var w = width
  var h = height
  for _ in 1 ..< mipCount:
    if w < 4 or h < 4: break
    cur = downsample2x2(cur, w, h)
    w = max(w div 2, 4)
    h = max(h div 2, 4)
    result.add(encodePayload(cur, w, h, fmt, mode))

proc rewriteXdsHeader*(originalHeader: openArray[byte],
                       width, height, fmt: int): seq[byte] =
  ## Patch a known-good 52-byte D3DBaseTexture header with new
  ## width/height/format. We *prefer* this over building a header from
  ## scratch because the lower bits of words 0/3/4/5 carry GPU-state
  ## fields (sampler config, swizzle, mip range, border color) we don't
  ## want to disturb. Same-dim/same-fmt re-encode = no-op patch; only
  ## changes are applied when explicitly different.
  ##
  ## Format-id is preserved literally — if the original .xds claimed
  ## DXT4_5_AS_16 (53), we keep the 53 even though the BC payload is
  ## plain BC3. The "_AS_16" suffix is a GPU read-aliasing hint, not a
  ## different compression. See xds memory: gotcha #1.
  if originalHeader.len < XdsHeaderSize:
    raise newException(ValueError,
      "rewriteXdsHeader: source header too small (" & $originalHeader.len & ")")
  result = newSeq[byte](XdsHeaderSize)
  for i in 0 ..< XdsHeaderSize: result[i] = originalHeader[i]

  proc writeBE32(buf: var seq[byte], off: int, v: uint32) =
    buf[off + 0] = byte((v shr 24) and 0xFF)
    buf[off + 1] = byte((v shr 16) and 0xFF)
    buf[off + 2] = byte((v shr 8)  and 0xFF)
    buf[off + 3] = byte( v         and 0xFF)
  proc readBE32(buf: openArray[byte], off: int): uint32 =
    (uint32(buf[off + 0]) shl 24) or
    (uint32(buf[off + 1]) shl 16) or
    (uint32(buf[off + 2]) shl 8)  or
     uint32(buf[off + 3])

  # word1 @ 0x20: low 6 bits = dataFormat. Replace the format-id bits but
  # preserve the upper 26 bits (endian, reqSize, baseAddr, etc).
  let w1Old = readBE32(originalHeader, 0x20)
  let w1New = (w1Old and (not 0x3F'u32)) or (uint32(fmt) and 0x3F'u32)
  writeBE32(result, 0x20, w1New)

  # word2 @ 0x24: bits 0..12 = width-1, 13..25 = height-1, 26..31 = depth.
  let w2Old = readBE32(originalHeader, 0x24)
  let depth = (w2Old shr 26) and 0x3F'u32
  let w2New = (uint32(width  - 1) and 0x1FFF'u32) or
              ((uint32(height - 1) and 0x1FFF'u32) shl 13) or
              (depth shl 26)
  writeBE32(result, 0x24, w2New)

proc encodeXdsFromOriginal*(rgba: openArray[uint8], width, height: int,
                            originalXds: openArray[byte],
                            mode: cint = StbDxtNormal): seq[byte] =
  ## Re-encode an .xds in place: read the original's header, regenerate
  ## the full mip chain via box filter from the (likely user-edited)
  ## RGBA, splice header + chain. Mips on the original are discarded —
  ## regenerating from the edited top mip is the only way to keep lower
  ## mips visually consistent with the edit.
  let h = parseXdsHeader(originalXds)
  if width != h.width or height != h.height:
    raise newException(ValueError,
      "encodeXdsFromOriginal: dim mismatch — original " &
      $h.width & "x" & $h.height & ", new " & $width & "x" & $height &
      " (resize support is not wired)")
  let header = rewriteXdsHeader(toOpenArray(originalXds, 0, XdsHeaderSize - 1),
                                 width, height, h.dataFormat)
  let mipCount = inferMipCount(width, height, h.dataFormat, h.payloadSize)
  let payload = encodePayloadChain(rgba, width, height, h.dataFormat,
                                    mipCount, mode)
  result = newSeq[byte](header.len + payload.len)
  for i in 0 ..< header.len:  result[i] = header[i]
  for i in 0 ..< payload.len: result[header.len + i] = payload[i]
