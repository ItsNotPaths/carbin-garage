## glTF → carbin vertex-pool encoder (Stage 2, Phase 1).
##
## Inverse of `gltf.nim`'s section decode. This is the piece that lets the
## working/ glTF — not the importee's original carbin — drive exported
## geometry, so sculpt edits made in the glTF actually ship.
##
## **Phase 1 scope (matched topology):** re-encode a section's vertex
## POSITIONS from `car.gltf`, while passing every vertex's UV /
## quaternion / extra-tail bytes through from the source pool *by index*.
## The glTF is the geometry (shape) source; the hard-to-recompute tangent
## quaternion and per-subsection atlas UV ride along losslessly. New /
## replaced parts with different topology are Phase 2 (synthesize quats
## from normals, emit subsections from scratch).
##
## ## Position re-quantization (inverse of decodeVertex28 / decodePoolToFloats)
##
## Forward decode is two stages:
##   raw[i]   = shortn(spos[i]) * shortn(scale)            ∈ [-1, 1]
##   world[i] = remap(raw[i], aMin, aMax, tMin, tMax) + offset
## where aMin/aMax are the *actual* decoded raw bounds (auto-ranged by
## `decodePoolToFloats`). To invert exactly we choose our own section
## bbox = the world AABB of the glTF positions (offset = 0), and encode
## with a per-vertex scale of 1 (`spos_scale = 32767`):
##   raw[i] = 2 * (world[i] - tMin) / (tMax - tMin) - 1
## The min/max vertices quantize to exactly ∓1, so on re-decode aMin/aMax
## land back on [-1, 1] and the remap reproduces the original world pos to
## int16 precision (~extent/65534). The recomputed bbox is written into
## the donor section template via `builders`' `workingTransform9` hook so
## the collision/damage AABB stays consistent with the geometry.

import std/[json, os, math, tables]
import ../be
import ./vertex
import ./vertex_quat

type
  GltfPackError* = object of CatchableError

  GltfDoc* = object
    ## Parsed `car.gltf` + slurped `car.bin`, with a name→mesh-index map.
    j*: JsonNode
    bin*: string
    meshByName*: Table[string, int]

const
  GLTF_FLOAT = 5126
  POS_EPS = 1e-9'f32

proc loadGltfDoc*(gltfPath: string): GltfDoc =
  ## Parse car.gltf and read the sibling car.bin (uri from buffers[0]).
  if not fileExists(gltfPath):
    raise newException(GltfPackError, "no glTF at " & gltfPath)
  result.j = parseFile(gltfPath)
  let bufs = result.j{"buffers"}
  if bufs == nil or bufs.kind != JArray or bufs.len == 0:
    raise newException(GltfPackError, "glTF has no buffers[]")
  let uri = bufs[0]{"uri"}.getStr("")
  if uri.len == 0:
    raise newException(GltfPackError, "glTF buffers[0] has no uri")
  let binPath = parentDir(gltfPath) / uri
  if not fileExists(binPath):
    raise newException(GltfPackError, "no glTF buffer at " & binPath)
  result.bin = readFile(binPath)
  result.meshByName = initTable[string, int]()
  if result.j.hasKey("meshes"):
    for i, m in result.j["meshes"].getElems:
      let nm = m{"name"}.getStr("")
      if nm.len > 0 and nm notin result.meshByName:
        result.meshByName[nm] = i

proc accFloatsVec3(d: GltfDoc, accIdx: int): seq[float32] =
  ## Read a FLOAT VEC3 accessor as a flat x,y,z,… seq (glTF .bin is LE,
  ## matching the host, so a straight copy works).
  let acc = d.j["accessors"][accIdx]
  if acc{"componentType"}.getInt != GLTF_FLOAT or acc{"type"}.getStr != "VEC3":
    raise newException(GltfPackError, "accessor " & $accIdx & " is not FLOAT VEC3")
  let bv = d.j["bufferViews"][acc["bufferView"].getInt]
  let off = bv{"byteOffset"}.getInt(0) + acc{"byteOffset"}.getInt(0)
  let count = acc["count"].getInt
  result = newSeq[float32](count * 3)
  if count > 0:
    copyMem(addr result[0], unsafeAddr d.bin[off], count * 12)

proc sectionPositions*(d: GltfDoc, meshName: string,
                       wantLod0: bool): tuple[pos: seq[float32]; found: bool] =
  ## Return the POSITION accessor floats for the LOD pool (wantLod0=false,
  ## primitives at lod>=1) or the LOD0 pool (wantLod0=true, primitives at
  ## lod==0) of the named mesh. All primitives sharing a pool reference the
  ## same POSITION accessor (see gltf.nim:emitSection), so the first match
  ## is authoritative. found=false if the mesh or matching pool is absent.
  result.found = false
  if meshName notin d.meshByName: return
  let m = d.j["meshes"][d.meshByName[meshName]]
  let prims = m{"primitives"}
  if prims == nil or prims.kind != JArray: return
  for p in prims.getElems:
    let lod = p{"extras", "carbin", "lod"}.getInt(-1)
    let isLod0 = lod == 0
    if isLod0 != wantLod0: continue
    let attrs = p{"attributes"}
    if attrs == nil: continue
    let posAcc = attrs{"POSITION"}
    if posAcc == nil: continue
    result.pos = accFloatsVec3(d, posAcc.getInt)
    result.found = true
    return

proc writeI16BE(buf: var seq[byte], off: int, v: int16) =
  let p = bePackU16(cast[uint16](v))
  buf[off] = p[0]; buf[off + 1] = p[1]

proc remap1(v, srcMin, srcMax, tgtMin, tgtMax: float32): float32 =
  let r = srcMax - srcMin
  if abs(r) < 1e-12'f32: return tgtMin
  result = tgtMin + ((v - srcMin) / r) * (tgtMax - tgtMin)

proc encodePoolPositions*(positions: seq[float32], basePool: openArray[byte],
                          stride: int,
                          srcOffset: array[3, float32]):
                          tuple[pool: seq[byte]; transform9: seq[byte]] =
  ## Overwrite the 8-byte position field (spos[3] + per-vertex scale) of
  ## every vertex in `basePool` (already at the TARGET stride; UV/quat/extra
  ## bytes kept verbatim) with glTF `positions`, re-quantized to match the
  ## **game's decode model**, not a naive [-1,1] normalization.
  ##
  ## The game decodes `world = remap(spos, srcRange, targetRange) + offset`
  ## where `srcRange` is the pool's *native* decoded range (the original
  ## exporter normalized each part into its own range, typically ~0.5..1.0,
  ## NOT the full [-1,1]). Storing full-range spos inflates every part by
  ## `2/native_range` (≈2-4×) while preserving its center — exactly the
  ## "components 2-4× too big, positions correct" failure. So we mirror the
  ## reference importer (probe/reference/fm4_obj.py:_encode_vertex_pool +
  ## the import remap at ~line 1175):
  ##   1. local      = glTF world - srcOffset
  ##   2. newTMin/Max = tight per-axis bounds of local  (written to header)
  ##   3. remapped   = remap(local, newTMin/Max, origAMin/Max)   per axis
  ##                   where origAMin/Max = decoded bounds of basePool
  ##                   (the pool's native range; falls back to [-1,1] when
  ##                   the base pool is empty/degenerate, e.g. new parts)
  ##   4. encode each remapped vertex with per-vertex scale s=max(|x|,|y|,|z|)
  ## For unedited geometry this reproduces the source pool (so it round-trips
  ## byte-near-identically); for edited geometry it stays in the section's
  ## native profile. The returned transform9 = (srcOffset, newTMin, newTMax).
  let vcount = positions.len div 3
  if positions.len mod 3 != 0:
    raise newException(GltfPackError, "POSITION count not a multiple of 3")
  if stride <= 0 or basePool.len mod stride != 0:
    raise newException(GltfPackError, "basePool length not a multiple of stride")
  if basePool.len div stride != vcount:
    raise newException(GltfPackError,
      "glTF vertex count " & $vcount & " != source pool count " &
      $(basePool.len div stride) & " (topology changed; Phase 1 needs matched topology)")

  # origAMin/Max: decoded position bounds of the source pool (its native
  # normalization range). Per axis, fall back to [-1,1] when degenerate.
  let baseVerts = decodePool(@basePool, stride)
  var oAMin: array[3, float32] = [1e30'f32, 1e30'f32, 1e30'f32]
  var oAMax: array[3, float32] = [-1e30'f32, -1e30'f32, -1e30'f32]
  for v in baseVerts:
    for a in 0 .. 2:
      oAMin[a] = min(oAMin[a], v.position[a])
      oAMax[a] = max(oAMax[a], v.position[a])
  for a in 0 .. 2:
    if baseVerts.len == 0 or (oAMax[a] - oAMin[a]) < POS_EPS:
      oAMin[a] = -1.0'f32; oAMax[a] = 1.0'f32

  # local = world - offset; tight per-axis bounds become the new target.
  var tMin: array[3, float32]
  var tMax: array[3, float32]
  if vcount > 0:
    for a in 0 .. 2:
      let l0 = positions[a] - srcOffset[a]
      tMin[a] = l0; tMax[a] = l0
    for vi in 0 ..< vcount:
      for a in 0 .. 2:
        let l = positions[vi*3 + a] - srcOffset[a]
        tMin[a] = min(tMin[a], l); tMax[a] = max(tMax[a], l)
  for a in 0 .. 2:
    if (tMax[a] - tMin[a]) < 1e-6'f32:
      tMin[a] = tMin[a] - 1e-6'f32; tMax[a] = tMax[a] + 1e-6'f32

  result.pool = newSeq[byte](basePool.len)
  for i in 0 ..< basePool.len: result.pool[i] = basePool[i]

  for vi in 0 ..< vcount:
    let base = vi * stride
    var r: array[3, float32]
    for a in 0 .. 2:
      let l = positions[vi*3 + a] - srcOffset[a]
      r[a] = remap1(l, tMin[a], tMax[a], oAMin[a], oAMax[a])
    # per-vertex scale (matches fm4_obj.encode_vertex): s = max(|comp|),
    # components stored normalized by s; scale stored clamped to [.., 1.0].
    let s = max(max(abs(r[0]), abs(r[1])), max(abs(r[2]), 1e-8'f32))
    writeI16BE(result.pool, base + 0, toShortn(r[0] / s))
    writeI16BE(result.pool, base + 2, toShortn(r[1] / s))
    writeI16BE(result.pool, base + 4, toShortn(r[2] / s))
    writeI16BE(result.pool, base + 6, toShortn(min(s, 1.0'f32)))

  var xf = newSeq[byte](36)
  template putF(off: int, v: float32) =
    let p = bePackF32(v)
    for k in 0 .. 3: xf[off + k] = p[k]
  for a in 0 .. 2: putF(a*4, srcOffset[a])      # offset (kept from source)
  for a in 0 .. 2: putF(12 + a*4, tMin[a])      # targetMin (local bounds)
  for a in 0 .. 2: putF(24 + a*4, tMax[a])      # targetMax (local bounds)
  result.transform9 = xf
