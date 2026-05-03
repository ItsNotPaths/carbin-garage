## Slice D: cross-game damage table remap via spatial nearest-neighbor.
##
## Each cvFive section tail carries an `a*b` table of `vCount × 4` bytes —
## one 4-byte per-vertex skinning record FH1 reads on impact. When we
## splice source's vertex pool into donor's section template, the donor's
## table indexes donor's vertex order, so source vertex i inherits donor
## record i — but they live at different world-positions, so deformation
## binds source verts to wrong bones → spike artifacts on collision.
##
## Probe v2 (`probe/nim_slice_d_v2_probe.nim`) confirmed:
##   - slot[0] is a small enum (5-6 distinct values per car), almost
##     certainly a damage-zone or coarse bone index
##   - 91% of vertices share their nearest-neighbor's slot[0] (R8GT_11)
##     and 86% (alfa) — strong spatial coherence
##
## Strategy: for each src vertex i, find donor vertex j with min squared
## distance to srcPos[i] in section-local space. Output row i = donor's
## row j_best (4 bytes verbatim). Section-local space is the right frame
## because both src and donor sections share the same anatomical region
## (matched by section name) and the donor's section transform is what
## the output uses.
##
## Performance: naive O(N×M). Body has ~12k verts × ~12k = 144M dist
## computes per section, ~10 body-deformable sections per car. Each dist
## compute is 3 mul + 2 add + 1 compare ≈ 1ns → seconds per car.
## kdtree only if profiling shows this on the critical path.

import ./vertex_quat

proc readI16BEdr(buf: openArray[byte], off: int): int16 {.inline.} =
  let u = (uint16(buf[off]) shl 8) or uint16(buf[off + 1])
  result = cast[int16](u)

proc decodePos(pool: openArray[byte], off: int): array[3, float32] {.inline.} =
  ## Mirror `vertex.nim:decodeVertex` position decode. The first 8 bytes
  ## of any FM4-32 or FH1-28 vertex are int16 × 4: x, y, z, scale, with
  ## both x/y/z and scale ShortN-quantized into [-1, 1]. Section-local
  ## world position = (shortn(x) * shortn(s), shortn(y) * shortn(s),
  ## shortn(z) * shortn(s)). The same code path works for both 28- and
  ## 32-byte strides since pos lives at offset 0..8 in both layouts.
  let rx = readI16BEdr(pool, off)
  let ry = readI16BEdr(pool, off + 2)
  let rz = readI16BEdr(pool, off + 4)
  let rs = readI16BEdr(pool, off + 6)
  let s = shortn(rs)
  result = [shortn(rx) * s, shortn(ry) * s, shortn(rz) * s]

proc remapDamageTable*(srcPool: openArray[byte], srcStride, srcVCount: int,
                       donPool: openArray[byte], donStride, donVCount: int,
                       donATable: openArray[byte],
                       recordSize: int = 4): seq[byte] =
  ## Build a `srcVCount * recordSize`-byte table where row i holds the
  ## `recordSize`-byte donor record from the donor vertex spatially
  ## nearest to source vertex i.
  ##
  ## - `srcPool` / `donPool` are the raw LOD vertex pools (must be the
  ##   pre-splice source's pool — which still has FM4 32-byte stride
  ##   when crossVersionStride — and the donor's FH1 28-byte pool).
  ## - `donATable` is donor's existing a*b table bytes
  ##   (`donVCount * recordSize` long).
  ## - `recordSize` defaults to 4; passed for explicit-ness.
  if srcVCount <= 0 or donVCount <= 0:
    raise newException(ValueError, "remapDamageTable: zero vCount")
  if srcPool.len < srcVCount * srcStride:
    raise newException(ValueError, "remapDamageTable: srcPool too small")
  if donPool.len < donVCount * donStride:
    raise newException(ValueError, "remapDamageTable: donPool too small")
  if donATable.len < donVCount * recordSize:
    raise newException(ValueError, "remapDamageTable: donATable too small")

  # Decode donor positions once; src positions decoded inline (one outer
  # iteration each).
  var donPos = newSeq[array[3, float32]](donVCount)
  for j in 0 ..< donVCount:
    donPos[j] = decodePos(donPool, j * donStride)

  result = newSeq[byte](srcVCount * recordSize)
  for i in 0 ..< srcVCount:
    let sp = decodePos(srcPool, i * srcStride)
    var bestJ = 0
    var bestD = float32.high
    for j in 0 ..< donVCount:
      let dx = sp[0] - donPos[j][0]
      let dy = sp[1] - donPos[j][1]
      let dz = sp[2] - donPos[j][2]
      let d = dx*dx + dy*dy + dz*dz
      if d < bestD:
        bestD = d
        bestJ = j
    let dstOff = i * recordSize
    let srcOff = bestJ * recordSize
    for k in 0 ..< recordSize:
      result[dstOff + k] = donATable[srcOff + k]
