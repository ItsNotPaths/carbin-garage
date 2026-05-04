## Hand-rolled glTF 2.0 writer for cracked carbin → working/<slug>/car.{gltf,bin}.
##
## We write JSON directly (no cgltf_write FFI dance) and pack a single
## interleaved-per-attribute .bin buffer. cgltf is compiled into the
## project so we can use *its* parser to validate our own output
## (validateGltf below).
##
## For Phase 1 the goal is a Blender-loadable view of the geometry —
## TriStrips are expanded to TriLists, and the original carbin bytes are
## preserved on disk in working/<slug>/geometry/ for byte-accurate
## round-trip. UV and normal data are emitted; the per-subsection UV
## scale/offset transform is baked into TEXCOORD_0/1 here so the Blender
## view matches the in-game UV layout.

import std/[json, math, streams, sets, tables]
import ./be
import ./carbin/model
import ./carbin/vertex
import ./texture_map

{.compile: "../../../csrc/cgltf_impl.c".}
{.compile: "../../../csrc/cgltf_write_impl.c".}

# ----- cgltf parse-only bindings (used to validate our own output) -----

type
  CgltfOptions* {.importc: "cgltf_options", header: "cgltf.h",
                  bycopy, incompleteStruct.} = object
  CgltfData* {.importc: "cgltf_data", header: "cgltf.h",
               incompleteStruct.} = object

proc cgltf_parse_file(opts: ptr CgltfOptions, path: cstring,
                      outData: ptr ptr CgltfData): cint
                      {.importc, header: "cgltf.h".}
proc cgltf_load_buffers(opts: ptr CgltfOptions, data: ptr CgltfData,
                        gltfPath: cstring): cint
                        {.importc, header: "cgltf.h".}
proc cgltf_validate(data: ptr CgltfData): cint
                    {.importc, header: "cgltf.h".}
proc cgltf_free(data: ptr CgltfData) {.importc, header: "cgltf.h".}

type
  GltfValidateStep* = enum
    vsParse, vsLoadBuffers, vsValidate

proc validateGltf*(path: string): tuple[ok: bool; step: GltfValidateStep; rc: int] =
  ## Parse + buffer-load + validate. Returns the failing step + cgltf rc.
  ## cgltf rejects NULL options (rc=5), so we hand it a 256-byte zero-
  ## initialized buffer — way bigger than the real cgltf_options struct
  ## (~64 bytes) so layout drift across cgltf versions can't bite us.
  ## All-zero == "use defaults" for every field.
  var optsBuf: array[256, byte]
  var data: ptr CgltfData
  let optsP = cast[ptr CgltfOptions](addr optsBuf[0])
  let parseRc = cgltf_parse_file(optsP, path.cstring, addr data)
  if parseRc != 0: return (false, vsParse, parseRc.int)
  let loadRc = cgltf_load_buffers(optsP, data, path.cstring)
  if loadRc != 0:
    cgltf_free(data); return (false, vsLoadBuffers, loadRc.int)
  let valRc = cgltf_validate(data)
  cgltf_free(data)
  result = (valRc == 0, vsValidate, valRc.int)

proc validateRoundtripExtras*(gltfPath: string): seq[string] =
  ## Stage 2 pre-flight gate. Returns a list of missing extras keys that
  ## the round-trip emitter requires. Empty list means the glTF is ready
  ## for `export-carbin`. The emitter's CLI verb checks this and refuses
  ## to run if the list is non-empty (with a pointer to the Stage 1
  ## refactor plan).
  ##
  ## Required keys (per stage1-importwc-refactor.md § 1.6):
  ##   - top-level extras.carbin.version
  ##   - per-mesh extras.carbin.bbox.{offset,targetMin,targetMax}
  ##   - per-mesh extras.carbin.rawQuatLod or rawQuatLod0 (at least one)
  ##   - per-primitive extras.carbin.{uvXScale,uvYScale,uvXOffset,uvYOffset,
  ##                                  uv1XScale,uv1YScale,uv1XOffset,uv1YOffset}
  result = @[]
  let j = parseFile(gltfPath)

  let topVer = j{"extras", "carbin", "version"}
  if topVer == nil or topVer.kind != JString or topVer.getStr.len == 0:
    result.add("top-level extras.carbin.version")

  if not j.hasKey("meshes"):
    result.add("meshes[]"); return
  for mi, m in j["meshes"].getElems:
    let mc = m{"extras", "carbin"}
    if mc == nil or mc.kind != JObject:
      result.add("meshes[" & $mi & "].extras.carbin"); continue
    let bb = mc{"bbox"}
    if bb == nil or bb.kind != JObject:
      result.add("meshes[" & $mi & "].extras.carbin.bbox")
    else:
      for f in ["offset", "targetMin", "targetMax"]:
        let v = bb{f}
        if v == nil or v.kind != JArray or v.len < 3:
          result.add("meshes[" & $mi & "].extras.carbin.bbox." & f)
    if mc{"rawQuatLod"} == nil and mc{"rawQuatLod0"} == nil:
      result.add("meshes[" & $mi & "].extras.carbin.rawQuat{Lod,Lod0}")

    if not m.hasKey("primitives"): continue
    for pi, p in m["primitives"].getElems:
      let pc = p{"extras", "carbin"}
      if pc == nil or pc.kind != JObject:
        result.add("meshes[" & $mi & "].primitives[" & $pi & "].extras.carbin"); continue
      for f in ["uvXScale", "uvYScale", "uvXOffset", "uvYOffset",
                "uv1XScale", "uv1YScale", "uv1XOffset", "uv1YOffset"]:
        let v = pc{f}
        if v == nil or v.kind notin {JFloat, JInt}:
          result.add("meshes[" & $mi & "].primitives[" & $pi & "].extras.carbin." & f)

# ----- glTF constants -----

const
  GLTF_FLOAT*          = 5126
  GLTF_UNSIGNED_INT*   = 5125
  GLTF_UNSIGNED_SHORT* = 5123
  GLTF_ARRAY_BUFFER*       = 34962
  GLTF_ELEMENT_ARRAY_BUFFER* = 34963
  PRIMITIVE_TRIANGLES* = 4

# ----- builder -----

type
  GltfBuilder* = object
    binBuf*: seq[byte]
    bufferViews*: seq[JsonNode]
    accessors*: seq[JsonNode]
    meshes*: seq[JsonNode]
    nodes*: seq[JsonNode]
    images*: seq[JsonNode]
    textures*: seq[JsonNode]
    samplers*: seq[JsonNode]
    materials*: seq[JsonNode]
    materialByKey*: Table[string, int]   # spec-cache key → material index
    imageByUri*: Table[string, int]      # uri → image index (dedupe)
    bufferUri*: string
    cgVersion*: string                   # carbin-version tag for top-level
                                          # extras.carbin.version (Stage 2
                                          # round-trip prereq). "" means
                                          # don't emit the field.
    # Per-mesh placement overrides for finish().
    # If a mesh index appears in `instances`, finish() emits one node per
    # listed translation instead of the default single node at origin.
    # `skipDefault` suppresses the default node entirely (use with the
    # instances mechanism for runtime-instanced meshes like the wheel).
    instances*: Table[int, seq[array[3, float32]]]
    skipDefault*: HashSet[int]

proc initBuilder*(bufferUri: string): GltfBuilder =
  result.bufferUri = bufferUri
  result.instances = initTable[int, seq[array[3, float32]]]()
  result.skipDefault = initHashSet[int]()
  result.materialByKey = initTable[string, int]()
  result.imageByUri    = initTable[string, int]()

proc ensureSharedSampler(b: var GltfBuilder) =
  if b.samplers.len == 0:
    b.samplers.add(%*{
      "magFilter": 9729,   # LINEAR
      "minFilter": 9987,   # LINEAR_MIPMAP_LINEAR
      "wrapS":     10497,  # REPEAT
      "wrapT":     10497})

proc addImageOnce(b: var GltfBuilder, uri, name: string): int =
  ## Idempotent: one glTF Image per uri, regardless of how many materials
  ## reference it.
  if uri in b.imageByUri: return b.imageByUri[uri]
  b.images.add(%*{"uri": uri, "name": name})
  result = b.images.high
  b.imageByUri[uri] = result

proc getOrCreateMaterial*(b: var GltfBuilder, key, name, imageUri: string,
                          baseColor: array[4, float32],
                          metallic, roughness: float32,
                          alphaMode: string = ""): int =
  ## Idempotent material creator. `key` is the cache identifier — typically
  ## the shader name — so primitives sharing a shader share a material.
  ## `imageUri` is "" for flat-color materials.
  if key in b.materialByKey: return b.materialByKey[key]

  var pbr = %*{
    "baseColorFactor": [baseColor[0], baseColor[1], baseColor[2], baseColor[3]],
    "metallicFactor":  metallic,
    "roughnessFactor": roughness}

  if imageUri.len > 0:
    ensureSharedSampler(b)
    let imageIdx = addImageOnce(b, imageUri, name)
    # One Texture per Image is fine — texture is a (sampler, source)
    # pair. Reusing across materials isn't worth the bookkeeping.
    b.textures.add(%*{"sampler": 0, "source": imageIdx})
    let texIdx = b.textures.high
    pbr["baseColorTexture"] = %*{"index": texIdx, "texCoord": 0}

  var mat = %*{
    "name": name,
    "pbrMetallicRoughness": pbr,
    "doubleSided": true}
  if alphaMode.len > 0:
    mat["alphaMode"] = %alphaMode
  b.materials.add(mat)
  result = b.materials.high
  b.materialByKey[key] = result

proc setInstances*(b: var GltfBuilder, meshIdx: int,
                   translations: openArray[array[3, float32]]) =
  ## Replace the default single-instance node for a mesh with N nodes,
  ## each with the given translation. The wheel template uses this to
  ## render at the four hub positions.
  b.instances[meshIdx] = @translations
  b.skipDefault.incl(meshIdx)

proc alignTo4(buf: var seq[byte]) =
  while buf.len mod 4 != 0: buf.add(0'u8)

proc addBufferView(b: var GltfBuilder, byteLen: int, target: int): int =
  alignTo4(b.binBuf)
  let off = b.binBuf.len
  b.binBuf.setLen(off + byteLen)
  let view = %*{
    "buffer": 0,
    "byteOffset": off,
    "byteLength": byteLen,
    "target": target}
  b.bufferViews.add(view)
  result = b.bufferViews.high

proc addRawBufferView(b: var GltfBuilder, bytes: openArray[byte]): int =
  ## Untyped (no-target) bufferView for arbitrary binary blobs. Used by
  ## Stage 2 round-trip prereq emit to park raw int16[4] quaternion
  ## streams in car.bin without exposing them as glTF accessors (they
  ## have no standard component layout in the spec). Caller stores the
  ## bufferView index in extras and decodes it itself.
  alignTo4(b.binBuf)
  let off = b.binBuf.len
  b.binBuf.setLen(off + bytes.len)
  if bytes.len > 0:
    copyMem(addr b.binBuf[off], unsafeAddr bytes[0], bytes.len)
  let view = %*{
    "buffer": 0,
    "byteOffset": off,
    "byteLength": bytes.len}
  b.bufferViews.add(view)
  result = b.bufferViews.high

proc extractRawQuat(pool: openArray[byte], stride: int): seq[byte] =
  ## Pull the per-vertex int16[4] quaternion bytes ([16..24) within each
  ## stride) from a vertex pool. Both FM4 (stride 32) and FH1 (stride 28)
  ## carry the quat at the same byte offset; only the trailing extra
  ## bytes differ. Returns an 8 * vertexCount byte stream, big-endian as
  ## stored on disk.
  if pool.len == 0 or stride <= 0: return @[]
  if pool.len mod stride != 0: return @[]
  let n = pool.len div stride
  result = newSeq[byte](n * 8)
  for i in 0 ..< n:
    for j in 0 ..< 8:
      result[i*8 + j] = pool[i*stride + 16 + j]

proc writeFloatsAt(b: var GltfBuilder, off: int, vals: openArray[float32]) =
  for i, v in vals:
    let bits = cast[uint32](v)
    let p = bePackU32(bits)   # we want LE; flip
    b.binBuf[off + i*4 + 0] = p[3]
    b.binBuf[off + i*4 + 1] = p[2]
    b.binBuf[off + i*4 + 2] = p[1]
    b.binBuf[off + i*4 + 3] = p[0]

proc addVec3FloatAccessor(b: var GltfBuilder, data: openArray[float32],
                          minB, maxB: array[3, float32]): int =
  doAssert data.len mod 3 == 0
  let count = data.len div 3
  let bv = addBufferView(b, count * 12, GLTF_ARRAY_BUFFER)
  writeFloatsAt(b, b.bufferViews[bv]["byteOffset"].getInt, data)
  let acc = %*{
    "bufferView": bv,
    "componentType": GLTF_FLOAT,
    "count": count,
    "type": "VEC3",
    "min": [minB[0], minB[1], minB[2]],
    "max": [maxB[0], maxB[1], maxB[2]]}
  b.accessors.add(acc)
  result = b.accessors.high

proc addVec2FloatAccessor(b: var GltfBuilder, data: openArray[float32]): int =
  doAssert data.len mod 2 == 0
  let count = data.len div 2
  let bv = addBufferView(b, count * 8, GLTF_ARRAY_BUFFER)
  writeFloatsAt(b, b.bufferViews[bv]["byteOffset"].getInt, data)
  let acc = %*{
    "bufferView": bv,
    "componentType": GLTF_FLOAT,
    "count": count,
    "type": "VEC2"}
  b.accessors.add(acc)
  result = b.accessors.high

proc addIndexAccessor(b: var GltfBuilder, indices: openArray[uint32]): int =
  let bv = addBufferView(b, indices.len * 4, GLTF_ELEMENT_ARRAY_BUFFER)
  let off = b.bufferViews[bv]["byteOffset"].getInt
  for i, v in indices:
    var le = v
    b.binBuf[off + i*4 + 0] = byte(le and 0xff'u32)
    b.binBuf[off + i*4 + 1] = byte((le shr 8) and 0xff'u32)
    b.binBuf[off + i*4 + 2] = byte((le shr 16) and 0xff'u32)
    b.binBuf[off + i*4 + 3] = byte((le shr 24) and 0xff'u32)
  let acc = %*{
    "bufferView": bv,
    "componentType": GLTF_UNSIGNED_INT,
    "count": indices.len,
    "type": "SCALAR"}
  b.accessors.add(acc)
  result = b.accessors.high

# ----- index decode + strip expansion -----

proc readIndices(data: openArray[byte], sec: SectionInfo,
                 ss: SubSectionInfo): seq[uint32] =
  ## Decode subsection indices into uint32, regardless of source idx_size.
  let n = int(ss.idxCount)
  let isz = int(ss.idxSize)
  result = newSeq[uint32](n)
  for i in 0 ..< n:
    if isz == 2:
      let a = uint32(data[ss.idxDataStart + i*2])
      let b = uint32(data[ss.idxDataStart + i*2 + 1])
      result[i] = (a shl 8) or b
    else:
      let a = uint32(data[ss.idxDataStart + i*4])
      let b = uint32(data[ss.idxDataStart + i*4 + 1])
      let c = uint32(data[ss.idxDataStart + i*4 + 2])
      let d = uint32(data[ss.idxDataStart + i*4 + 3])
      result[i] = (a shl 24) or (b shl 16) or (c shl 8) or d

proc isRestart(v: uint32, idxSize: int): bool =
  ## FM4 uses multiple restart sentinels for the same purpose because the
  ## 4-byte index size sometimes carries a 24-bit pattern stuffed into 32
  ## bits. patch.nim treats {0xFFFFFFFF, 0x00FFFFFF, 0x0000FFFF} as
  ## equivalent restart markers — match that here so strip expansion
  ## doesn't emit triangles indexing 0x00FFFFFF (= 16777215) and blow
  ## past the vertex count.
  if idxSize == 2: return v == 0xFFFF'u32
  result = v == 0xFFFFFFFF'u32 or v == 0x00FFFFFF'u32 or v == 0x0000FFFF'u32

proc tristripToTris(idx: openArray[uint32], idxSize: int): seq[uint32] =
  ## Expand a triangle-strip index buffer (with restart sentinels) to a
  ## flat triangle list. Winding alternates within each sub-strip (every
  ## odd triangle is CCW-flipped); sub-strips are delimited by restart
  ## sentinels. Crucially, the alternation parity must reset after each
  ## restart — otherwise an odd-offset restart leaves every triangle in
  ## the next sub-strip back-facing in Blender.
  result = newSeqOfCap[uint32](idx.len * 3)
  var i = 0
  var stripBase = 0
  while i + 2 < idx.len:
    if isRestart(idx[i], idxSize) or isRestart(idx[i+1], idxSize) or isRestart(idx[i+2], idxSize):
      while i < idx.len and not isRestart(idx[i], idxSize): inc i
      while i < idx.len and isRestart(idx[i], idxSize): inc i
      stripBase = i
      continue
    if idx[i] == idx[i+1] or idx[i+1] == idx[i+2] or idx[i] == idx[i+2]:
      inc i; continue
    if ((i - stripBase) and 1) == 0:
      result.add(idx[i]); result.add(idx[i+1]); result.add(idx[i+2])
    else:
      result.add(idx[i]); result.add(idx[i+2]); result.add(idx[i+1])
    inc i

proc trilistToTris(idx: openArray[uint32], idxSize: int): seq[uint32] =
  ## Drop any restart-sentinel triple from a TriList — defensive: some
  ## FM4 LOD0 buffers include strip-style sentinels even when index_type
  ## is 4 (TriList). Filtering keeps the glTF valid.
  result = newSeqOfCap[uint32](idx.len)
  var i = 0
  while i + 2 < idx.len:
    if isRestart(idx[i], idxSize) or isRestart(idx[i+1], idxSize) or isRestart(idx[i+2], idxSize):
      i += 3; continue
    result.add(idx[i]); result.add(idx[i+1]); result.add(idx[i+2])
    i += 3

# ----- per-section emit -----

type
  PoolAccessors = object
    pos*, normal*: int               # accessor indices (-1 if missing)
    rawUv0*, rawUv1*: seq[float32]   # untransformed UVs, kept for per-
                                      # subsection bake (each subsection
                                      # has its own atlas region via
                                      # m_UVOffsetScale).
    valid*: bool

type
  SectionTransform* = object
    offset*: array[3, float32]
    targetMin*: array[3, float32]
    targetMax*: array[3, float32]

proc readSectionTransform*(data: openArray[byte], sec: SectionInfo): SectionTransform =
  ## Per-section header carries 3 offset + 3 target_min + 3 target_max
  ## big-endian floats, used to remap normalized vertex positions back to
  ## world space. See docs/FM4_CARBIN_CONDENSED.md §5 and the Python
  ## oracle's read_transform() in probe/reference/fm4_obj.py.
  var r = newBEReader(data)
  r.seek(sec.transformPos)
  for i in 0 .. 2: result.offset[i]    = r.f32()
  for i in 0 .. 2: result.targetMin[i] = r.f32()
  for i in 0 .. 2: result.targetMax[i] = r.f32()

proc remap1(v, srcMin, srcMax, tgtMin, tgtMax: float32): float32 =
  let r = srcMax - srcMin
  if abs(r) < 1e-12'f32: return tgtMin
  result = tgtMin + ((v - srcMin) / r) * (tgtMax - tgtMin)

proc decodePoolToFloats(blob: openArray[byte], stride: int, xform: SectionTransform):
                       tuple[pos, uv0, uv1, normal: seq[float32];
                             posMin, posMax: array[3, float32]] =
  ## Decode raw pool, remap each position from [actual_min..actual_max]
  ## to [target_min..target_max] then add section offset.
  ## UVs are returned RAW (no Y-flip, no atlas transform) — the caller
  ## bakes the per-subsection m_UVOffsetScale into a fresh UV accessor.
  ## `stride` is the section's lodVSize / lod0VSize — 32 (FM4) or 28 (FH1).
  let verts = decodePool(blob, stride)
  result.pos    = newSeqOfCap[float32](verts.len * 3)
  result.uv0    = newSeqOfCap[float32](verts.len * 2)
  result.uv1    = newSeqOfCap[float32](verts.len * 2)
  result.normal = newSeqOfCap[float32](verts.len * 3)
  if verts.len == 0:
    return

  # actual bounds of decoded raw positions (the source range for the remap)
  var aMin = verts[0].position
  var aMax = verts[0].position
  for v in verts:
    for i in 0 .. 2:
      aMin[i] = min(aMin[i], v.position[i])
      aMax[i] = max(aMax[i], v.position[i])

  # Apply remap + offset, accumulate world bounds for the accessor.
  for vi, v in verts:
    var world: array[3, float32]
    for i in 0 .. 2:
      world[i] = remap1(v.position[i], aMin[i], aMax[i],
                        xform.targetMin[i], xform.targetMax[i]) + xform.offset[i]
    if vi == 0:
      result.posMin = world; result.posMax = world
    else:
      for i in 0 .. 2:
        result.posMin[i] = min(result.posMin[i], world[i])
        result.posMax[i] = max(result.posMax[i], world[i])
    result.pos.add(world[0]); result.pos.add(world[1]); result.pos.add(world[2])
    result.uv0.add(v.texture0[0]); result.uv0.add(v.texture0[1])
    result.uv1.add(v.texture1[0]); result.uv1.add(v.texture1[1])
    result.normal.add(v.normal[0]); result.normal.add(v.normal[1]); result.normal.add(v.normal[2])

proc emitPoolAccessors(b: var GltfBuilder, blob: openArray[byte],
                       stride: int, xform: SectionTransform): PoolAccessors =
  if blob.len == 0 or stride <= 0:
    return PoolAccessors(valid: false, pos: -1, normal: -1)
  let dec = decodePoolToFloats(blob, stride, xform)
  result.pos    = addVec3FloatAccessor(b, dec.pos, dec.posMin, dec.posMax)
  result.normal = addVec3FloatAccessor(b, dec.normal,
                  [-1.0'f32, -1.0'f32, -1.0'f32], [1.0'f32, 1.0'f32, 1.0'f32])
  result.rawUv0 = dec.uv0
  result.rawUv1 = dec.uv1
  result.valid  = true

proc bakeSsUv(raw: seq[float32], xs, ys, xo, yo: float32): seq[float32] =
  ## Apply the per-subsection UV transform from m_UVOffsetScale.
  ## NOTE: master doc says final.y = 1 - (raw.y*ys + yo) but empirically
  ## that maps the FH1 steering wheel onto the Alfa-badge atlas region
  ## instead of the steering-wheel image. The carbin-stored values are
  ## already in glTF/DirectX top-left convention — no extra flip needed.
  ## (Soulbrix oracle uses identity transform, so it never had to pick
  ## between these.)
  result = newSeq[float32](raw.len)
  var i = 0
  while i + 1 < raw.len:
    result[i]     = raw[i]     * xs + xo
    result[i + 1] = raw[i + 1] * ys + yo
    i += 2

proc emitSection*(b: var GltfBuilder, data: openArray[byte], sec: SectionInfo,
                  availableTextures: seq[string] = @[],
                  lodKind: string = "main",
                  sourceCarbin: string = ""): int =
  ## Emit one mesh for the given section. Returns mesh index.
  ## Each (subsection, lod) becomes one primitive. If `availableTextures`
  ## is non-empty, each primitive gets a glTF material whose baseColorTexture
  ## points at the predicted PNG (decoded from .xds at import time).
  ## `lodKind` tags the mesh as one of main / lod0 / cockpit / corner / other
  ## so the UI can filter to lod0 for display while DCC tools still see everything.
  let xform = readSectionTransform(data, sec)
  let lodPool  = data[sec.lodVerticesStart  ..< sec.lodVerticesEnd]
  let lod0Pool = data[sec.lod0VerticesStart ..< sec.lod0VerticesEnd]
  let lodAcc  = emitPoolAccessors(b, lodPool,  int(sec.lodVerticesSize),  xform)
  let lod0Acc = emitPoolAccessors(b, lod0Pool, int(sec.lod0VerticesSize), xform)

  var primitives = newJArray()
  for ss in sec.subsections:
    let useLod0 = (ss.lod == 0)
    let acc = if useLod0: lod0Acc else: lodAcc
    if not acc.valid: continue
    let raw = readIndices(data, sec, ss)
    let isz = int(ss.idxSize)
    let tris =
      if ss.indexType == 6'u32:  # TriStrip
        tristripToTris(raw, isz)
      else:
        trilistToTris(raw, isz)
    if tris.len < 3: continue
    let idxAcc = addIndexAccessor(b, tris)
    # Per-subsection UV accessors: bake atlas transform from
    # m_UVOffsetScale so each primitive samples its texture region.
    let uv0Acc = addVec2FloatAccessor(b,
      bakeSsUv(acc.rawUv0, ss.uvXScale, ss.uvYScale,
                            ss.uvXOffset, ss.uvYOffset))
    let uv1Acc = addVec2FloatAccessor(b,
      bakeSsUv(acc.rawUv1, ss.uv1XScale, ss.uv1YScale,
                            ss.uv1XOffset, ss.uv1YOffset))
    var prim = %*{
      "attributes": {
        "POSITION":   acc.pos,
        "NORMAL":     acc.normal,
        "TEXCOORD_0": uv0Acc,
        "TEXCOORD_1": uv1Acc
      },
      "indices": idxAcc,
      "mode": PRIMITIVE_TRIANGLES,
      "extras": {
        "carbin": {
          "lod":       int(ss.lod),
          "indexType": int(ss.indexType),
          "idxSize":   int(ss.idxSize),
          "subName":   ss.name,
          # Raw per-subsection UV transform from m_UVOffsetScale. The
          # writer bakes these into TEXCOORD_0/1 above, so consumers get
          # baked UVs by default; Stage 2 inverse-emit reads these to
          # un-bake before re-quantizing back into the carbin pool.
          "uvXScale":   ss.uvXScale,
          "uvYScale":   ss.uvYScale,
          "uvXOffset":  ss.uvXOffset,
          "uvYOffset":  ss.uvYOffset,
          "uv1XScale":  ss.uv1XScale,
          "uv1YScale":  ss.uv1YScale,
          "uv1XOffset": ss.uv1XOffset,
          "uv1YOffset": ss.uv1YOffset
        }}}
    let spec = resolveMaterial(ss.name, availableTextures)
    # If the subsection's UV scale is effectively zero, the shader is
    # procedural (bump map / runtime tint) and *not* meant to sample the
    # atlas — the GPU collapse-samples one pixel as a tint hint. Treat
    # those as flat-color. Common case: steering-wheel `bump_leather*`,
    # which would otherwise paint the wheel one random atlas pixel.
    let degenerate = abs(ss.uvXScale) < 1e-5'f32 or abs(ss.uvYScale) < 1e-5'f32
    let textureBase = if degenerate: "" else: spec.textureBase
    let imageUri = if textureBase.len > 0:
                     "textures/" & textureBase & ".xds.png"
                   else: ""
    let key = spec.name & "|" & textureBase
    let matIdx = getOrCreateMaterial(b, key, spec.name, imageUri,
                                     spec.baseColor, spec.metallic,
                                     spec.roughness, spec.alphaMode)
    if matIdx >= 0:
      prim["material"] = %matIdx
    primitives.add(prim)

  # Mesh-level extras tag the source carbin so consumers (our future UI,
  # Blender add-ons, etc.) can filter "show only lod0" without re-parsing
  # the carbin metadata. All LODs ride into one glTF for porting; the UI
  # displays lod0-tagged meshes and edits flow back into geometry/<part>.carbin.
  #
  # Stage 2 round-trip extras (added 2026-05-04):
  #   - bbox: per-section offset/targetMin/targetMax floats. Stage 2's
  #     ShortN re-quantize uses this to map float positions back into
  #     int16 pool entries.
  #   - rawQuatLod / rawQuatLod0: bufferView indices into car.bin holding
  #     the original int16[4] quaternion bytes verbatim. Lossless tangent-
  #     space preservation for un-edited geometry. Either field may be
  #     absent if the corresponding pool was empty.
  var carbinExtras = %*{
    "lodKind":      lodKind,
    "sourceCarbin": sourceCarbin,
    "bbox": {
      "offset":    [xform.offset[0],    xform.offset[1],    xform.offset[2]],
      "targetMin": [xform.targetMin[0], xform.targetMin[1], xform.targetMin[2]],
      "targetMax": [xform.targetMax[0], xform.targetMax[1], xform.targetMax[2]]
    }}
  if lodPool.len > 0 and sec.lodVerticesSize > 0'u32:
    let raw = extractRawQuat(lodPool, int(sec.lodVerticesSize))
    if raw.len > 0:
      let bv = addRawBufferView(b, raw)
      carbinExtras["rawQuatLod"] = %*{
        "bufferView": bv,
        "count":      raw.len div 8}
  if lod0Pool.len > 0 and sec.lod0VerticesSize > 0'u32:
    let raw = extractRawQuat(lod0Pool, int(sec.lod0VerticesSize))
    if raw.len > 0:
      let bv = addRawBufferView(b, raw)
      carbinExtras["rawQuatLod0"] = %*{
        "bufferView": bv,
        "count":      raw.len div 8}
  let mesh = %*{
    "name": sec.name,
    "primitives": primitives,
    "extras": {
      "carbin": carbinExtras}}
  b.meshes.add(mesh)
  result = b.meshes.high

proc finish*(b: GltfBuilder, gltfPath, binPath: string) =
  ## Write car.gltf and car.bin alongside each other.
  block:
    var f = newFileStream(binPath, fmWrite)
    if f == nil: raise newException(IOError, "cannot open " & binPath)
    if b.binBuf.len > 0: f.writeData(unsafeAddr b.binBuf[0], b.binBuf.len)
    f.close()

  var nodes = newJArray()
  var sceneNodes = newJArray()
  for i in 0 ..< b.meshes.len:
    let name = b.meshes[i]["name"].getStr
    if i notin b.skipDefault:
      let nodeIdx = nodes.len
      nodes.add(%*{"mesh": i, "name": name})
      sceneNodes.add(%nodeIdx)
    if i in b.instances:
      for k, t in b.instances[i]:
        let nodeIdx = nodes.len
        nodes.add(%*{
          "mesh": i,
          "name": name & "_inst" & $k,
          "translation": [t[0], t[1], t[2]]})
        sceneNodes.add(%nodeIdx)

  var root = %*{
    "asset": {"version": "2.0", "generator": "carbin-garage 0.0.1"},
    "scene": 0,
    "scenes": [{"nodes": sceneNodes}],
    "nodes": nodes,
    "meshes": b.meshes,
    "accessors": b.accessors,
    "bufferViews": b.bufferViews,
    "buffers": [{"uri": b.bufferUri, "byteLength": b.binBuf.len}]}
  if b.images.len > 0:    root["images"]    = %b.images
  if b.textures.len > 0:  root["textures"]  = %b.textures
  if b.samplers.len > 0:  root["samplers"]  = %b.samplers
  if b.materials.len > 0: root["materials"] = %b.materials
  # Top-level carbin extras: version tag tells Stage 2 which target's
  # vertex/section layout to emit (cvFour = FM4, cvFive = FH1, cvTwo /
  # cvThree = FM2/FM3 read-only).
  if b.cgVersion.len > 0:
    root["extras"] = %*{"carbin": {"version": b.cgVersion}}
  writeFile(gltfPath, $root)
