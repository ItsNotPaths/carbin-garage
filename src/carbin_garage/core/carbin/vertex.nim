## FM4 vertex codec. 0x20-byte stride: int16x4 position + uint16x4 UVs +
## int16x4 packed quaternion (basis matrix row 0 = normal) + 8 bytes
## verbatim ("extra8", suspected second tangent — round-trip preserved).
##
## Port of probe/reference/fm4_obj.py:159-285.
## Spec: docs/FM4_CARBIN_CONDENSED.md §3.

import std/[endians, math]
import ./vertex_quat

export vertex_quat

const VERTEX_SIZE* = 32

type
  Vertex* = object
    position*: Vec3
    texture0*: array[2, float32]
    texture1*: array[2, float32]
    normal*: Vec3
    extra8*: array[8, byte]   # bytes 0x18..0x1F preserved verbatim

# ---- BE primitive readers (slice-local; avoid pulling BEReader for hot path) ----

proc readI16BE(buf: openArray[byte], off: int): int16 =
  var be: array[2, byte] = [buf[off], buf[off + 1]]
  bigEndian16(addr result, addr be[0])

proc readU16BE(buf: openArray[byte], off: int): uint16 =
  var be: array[2, byte] = [buf[off], buf[off + 1]]
  bigEndian16(addr result, addr be[0])

proc writeI16BE(buf: var seq[byte], off: int, v: int16) =
  var src = v
  var dst: array[2, byte]
  bigEndian16(addr dst[0], addr src)
  buf[off] = dst[0]; buf[off + 1] = dst[1]

proc writeU16BE(buf: var seq[byte], off: int, v: uint16) =
  var src = v
  var dst: array[2, byte]
  bigEndian16(addr dst[0], addr src)
  buf[off] = dst[0]; buf[off + 1] = dst[1]

# ---- decode ----

proc decodeVertex*(blob: openArray[byte], off: int): Vertex =
  ## Decode one 0x20-stride vertex.
  ## Position: int16 × 4 (x, y, z, scale). World pos = (sx*s, sy*s, sz*s).
  ## UV0/UV1: uint16 × 4, raw normalized (per-subsection scale/offset
  ##   applied later by the caller from sidecar data).
  ## Quaternion: int16 × 4 ShortN; row 0 of the rotation matrix is the
  ##   surface normal (tangent + bitangent fall out of the same basis).
  ## extra8: trailing 8 bytes — undecoded, preserved verbatim.
  # Math is done in float64 to match the Python oracle bit-for-bit, then
  # downcast at the end. The source ints are int16 ShortN-quantized so
  # float64 here doesn't promise more precision than the data carries —
  # it just keeps Nim and Python rounding identical.
  let rx = readI16BE(blob, off)
  let ry = readI16BE(blob, off + 2)
  let rz = readI16BE(blob, off + 4)
  let rs = readI16BE(blob, off + 6)
  let s64 = float64(shortn(rs))
  result.position = [
    float32(float64(shortn(rx)) * s64),
    float32(float64(shortn(ry)) * s64),
    float32(float64(shortn(rz)) * s64)]
  result.texture0 = [
    float32(float64(readU16BE(blob, off + 8))  / 65535.0),
    float32(float64(readU16BE(blob, off + 10)) / 65535.0)]
  result.texture1 = [
    float32(float64(readU16BE(blob, off + 12)) / 65535.0),
    float32(float64(readU16BE(blob, off + 14)) / 65535.0)]
  let q: Quat = [shortn(readI16BE(blob, off + 16)),
                 shortn(readI16BE(blob, off + 18)),
                 shortn(readI16BE(blob, off + 20)),
                 shortn(readI16BE(blob, off + 22))]
  result.normal = quatToMatrixRow0(q)
  for i in 0 .. 7:
    result.extra8[i] = blob[off + 24 + i]

# ---- encode ----

proc encodeVertex*(pos: Vec3, uv0, uv1: array[2, float32], normal: Vec3,
                   tangent: Vec3 = [0.0'f32, 0.0'f32, 0.0'f32],
                   extra8: array[8, byte] = default(array[8, byte])): array[VERTEX_SIZE, byte] =
  ## Encode one 0x20-stride vertex. Caller picks the per-subsection inverse
  ## UV transform before calling. extra8 must be the original pool bytes
  ## from the source vertex (suspected second tangent — see docs §11.1).
  let maxAbs = max(max(abs(pos[0]), abs(pos[1])), max(abs(pos[2]), 1e-8'f32))
  let s = if maxAbs <= 1.0'f32: maxAbs else: maxAbs
  let nx = pos[0] / s
  let ny = pos[1] / s
  let nz = pos[2] / s

  let useTangent = tangent[0] != 0.0'f32 or tangent[1] != 0.0'f32 or tangent[2] != 0.0'f32
  let q: Quat16 =
    if useTangent: tangentSpaceToQuat(normal, tangent)
    else: normalToQuat(normal)

  var buf = newSeq[byte](VERTEX_SIZE)
  writeI16BE(buf, 0, toShortn(nx))
  writeI16BE(buf, 2, toShortn(ny))
  writeI16BE(buf, 4, toShortn(nz))
  writeI16BE(buf, 6, toShortn(min(1.0'f32, s)))
  writeU16BE(buf, 8,  toUshortn(uv0[0]))
  writeU16BE(buf, 10, toUshortn(uv0[1]))
  writeU16BE(buf, 12, toUshortn(uv1[0]))
  writeU16BE(buf, 14, toUshortn(uv1[1]))
  writeI16BE(buf, 16, q[0])
  writeI16BE(buf, 18, q[1])
  writeI16BE(buf, 20, q[2])
  writeI16BE(buf, 22, q[3])
  for i in 0 .. 7: buf[24 + i] = extra8[i]
  for i in 0 ..< VERTEX_SIZE: result[i] = buf[i]

proc decodeVertex28*(blob: openArray[byte], off: int): Vertex =
  ## FH1 28-byte vertex layout (corrected 2026-05-01):
  ##   pos(8) + UV0(4) + UV1(4) + quat(8) + extra4(4)
  ##
  ## Empirically verified vs paired FM4 cars: FH1 [0..24) ==
  ## FM4 [0..24) byte-equal across 3000+ matched body vertices. FH1
  ## KEEPS UV1 (prior docs claimed it was dropped — that was wrong).
  ## The 4-byte loss vs FM4's 32-byte stride lives at the END of the
  ## vertex (extra8 → extra4), NOT in the middle.
  ##
  ## extra4: byte 0 ~70% matches FM4 extra8[0] (likely AO or compact
  ## tangent component); bytes 1..3 are re-baked. extra8[4..8) of the
  ## Vertex result is zero-filled because FH1 doesn't carry those bytes.
  let rx = readI16BE(blob, off)
  let ry = readI16BE(blob, off + 2)
  let rz = readI16BE(blob, off + 4)
  let rs = readI16BE(blob, off + 6)
  let s64 = float64(shortn(rs))
  result.position = [
    float32(float64(shortn(rx)) * s64),
    float32(float64(shortn(ry)) * s64),
    float32(float64(shortn(rz)) * s64)]
  result.texture0 = [
    float32(float64(readU16BE(blob, off + 8))  / 65535.0),
    float32(float64(readU16BE(blob, off + 10)) / 65535.0)]
  result.texture1 = [
    float32(float64(readU16BE(blob, off + 12)) / 65535.0),
    float32(float64(readU16BE(blob, off + 14)) / 65535.0)]
  let q: Quat = [shortn(readI16BE(blob, off + 16)),
                 shortn(readI16BE(blob, off + 18)),
                 shortn(readI16BE(blob, off + 20)),
                 shortn(readI16BE(blob, off + 22))]
  result.normal = quatToMatrixRow0(q)
  for i in 0 .. 3:
    result.extra8[i] = blob[off + 24 + i]
  for i in 4 .. 7:
    result.extra8[i] = 0

proc decodePool*(blob: openArray[byte], stride: int = VERTEX_SIZE): seq[Vertex] =
  ## Decode an entire vertex pool. Picks the FM4 (32-byte) or FH1
  ## (28-byte) layout based on `stride`. Other strides are an error.
  if blob.len == 0: return @[]
  doAssert blob.len mod stride == 0, "vertex pool length not a multiple of stride"
  let n = blob.len div stride
  result = newSeq[Vertex](n)
  case stride
  of 32:
    for i in 0 ..< n: result[i] = decodeVertex(blob, i * stride)
  of 28:
    for i in 0 ..< n: result[i] = decodeVertex28(blob, i * stride)
  else:
    raise newException(ValueError,
      "unsupported vertex stride " & $stride & " (only 32 / 28 are known)")
