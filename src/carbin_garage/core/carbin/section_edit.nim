## Carbin section-list editing: synthesize a NEW section from an arbitrary
## mesh, drop named sections, and re-pack the carbin with `partCount` fixed.
##
## This is Phase 2 of the glTF geometry pipeline. Phase 1 (gltf_pack) only
## repositions the vertices of an *existing* part (matched topology). A
## brand-new mesh (e.g. an imported OBJ injected into car.gltf) has its own
## topology, so the exporter must build a whole new carbin section: a vertex
## pool, ONE TriList subsection with a fresh index buffer, and a damage tail
## sized to the new vertex count. We do this by cloning an existing body
## section as the structural scaffold (header, bone-weight block, subsection
## boilerplate, tail layout) and swapping in the new geometry — the same
## "clone a donor template" philosophy the splice path already uses.
##
## Sections are referenced only by NAME anywhere it matters (physicsdef,
## gamedb, transcode all key off the name; SectionInfo.index is unused), so
## adding/removing a section needs nothing beyond rebuilding the byte stream
## and patching the u32 `partCount`.

import std/[sets, tables, math]
import ../be
import ./model
import ./parser
import ./patch
import ./vertex
import ./vertex_quat

type
  SectionEditError* = object of CatchableError

proc sliceB(buf: openArray[byte], a, b: int): seq[byte] =
  result = newSeq[byte](b - a)
  for i in 0 ..< (b - a): result[i] = buf[a + i]

proc wU16(buf: var seq[byte], off: int, v: uint16) =
  let p = bePackU16(v); buf[off] = p[0]; buf[off + 1] = p[1]

proc wI16(buf: var seq[byte], off: int, v: int16) =
  let p = bePackU16(cast[uint16](v)); buf[off] = p[0]; buf[off + 1] = p[1]

proc remap1(v, sa, sb, ta, tb: float32): float32 =
  let r = sb - sa
  if abs(r) < 1e-12'f32: return ta
  result = ta + ((v - sa) / r) * (tb - ta)

proc poolRange(carbin: openArray[byte], sec: SectionInfo):
              tuple[mn, mx: array[3, float32]] =
  ## Decoded per-axis min/max of a section's LOD pool — the section's native
  ## normalization range (== its lod0Bounds, which the runtime uses as the
  ## source range in CalculateBoundTargetValue). A synthesized part's pool
  ## must span this same range or it decodes at the wrong scale.
  var b = newSeq[byte](sec.lodVerticesEnd - sec.lodVerticesStart)
  for i in 0 ..< b.len: b[i] = carbin[sec.lodVerticesStart + i]
  let verts = decodePool(b, int(sec.lodVerticesSize))
  result.mn = [1e30'f32, 1e30'f32, 1e30'f32]
  result.mx = [-1e30'f32, -1e30'f32, -1e30'f32]
  for v in verts:
    for a in 0 .. 2:
      result.mn[a] = min(result.mn[a], v.position[a])
      result.mx[a] = max(result.mx[a], v.position[a])
  for a in 0 .. 2:
    if result.mx[a] - result.mn[a] < 1e-6'f32:
      result.mn[a] = -1.0'f32; result.mx[a] = 1.0'f32

# ---- vertex pool from a raw mesh, FIT into the donor slot's bbox ----

proc buildMeshPoolFit(positions, uvs, normals: seq[float32],
                      dTMin, dTMax, dRMin, dRMax: array[3, float32],
                      fill: float32 = 0.9'f32): seq[byte] =
  ## The runtime renders a replaced section against the DONOR slot's bounds
  ## (verified in-game: a written section transform is ignored). So we KEEP
  ## the donor's transform and fit the new mesh INTO the donor slot's target
  ## bbox, preserving aspect (uniform scale):
  ##   placedLocal = (vert - meshCenter) * s + donorTargetCenter
  ##   pool        = remap(placedLocal, donorTarget, donorPoolRange)
  ## On decode `CalcBound(pool, donorPoolRange≈donorTarget, donorTarget)+offset`
  ## ≈ placedLocal + offset, so the mesh appears undistorted, filling ~`fill`
  ## of the donor slot's box at the slot's location. (Robust to whether the
  ## runtime's source range is the pool's auto-range or the target, since for
  ## a real part those are ~equal.)
  let vcount = positions.len div 3
  var pmin = [1e30'f32, 1e30'f32, 1e30'f32]
  var pmax = [-1e30'f32, -1e30'f32, -1e30'f32]
  for i in 0 ..< vcount:
    for a in 0 .. 2:
      pmin[a] = min(pmin[a], positions[i*3+a]); pmax[a] = max(pmax[a], positions[i*3+a])
  var pcenter, dcenter: array[3, float32]
  var s = 1e30'f32
  for a in 0 .. 2:
    pcenter[a] = (pmin[a] + pmax[a]) * 0.5'f32
    dcenter[a] = (dTMin[a] + dTMax[a]) * 0.5'f32
    let pe = pmax[a] - pmin[a]
    let de = dTMax[a] - dTMin[a]
    if pe > 1e-6'f32: s = min(s, de / pe)
  if s > 1e29'f32 or s <= 0'f32: s = 1.0'f32
  s = s * fill

  var pool = newSeq[byte](vcount * 28)
  for i in 0 ..< vcount:
    let b = i * 28
    var r: array[3, float32]
    for a in 0 .. 2:
      let placed = (positions[i*3+a] - pcenter[a]) * s + dcenter[a]
      r[a] = remap1(placed, dTMin[a], dTMax[a], dRMin[a], dRMax[a])
    let sc = max(max(abs(r[0]), abs(r[1])), max(abs(r[2]), 1e-8'f32))
    wI16(pool, b + 0, toShortn(r[0] / sc)); wI16(pool, b + 2, toShortn(r[1] / sc))
    wI16(pool, b + 4, toShortn(r[2] / sc)); wI16(pool, b + 6, toShortn(min(sc, 1.0'f32)))
    let u = max(0.0'f32, min(1.0'f32, (if uvs.len > i*2: uvs[i*2] else: 0.0'f32)))
    let v = max(0.0'f32, min(1.0'f32, (if uvs.len > i*2+1: uvs[i*2+1] else: 0.0'f32)))
    wU16(pool, b + 8,  toUshortn(u)); wU16(pool, b + 10, toUshortn(v))
    wU16(pool, b + 12, toUshortn(u)); wU16(pool, b + 14, toUshortn(v))
    let nrm: Vec3 =
      if normals.len >= i*3 + 3: [normals[i*3], normals[i*3+1], normals[i*3+2]]
      else: [0.0'f32, 1.0'f32, 0.0'f32]
    let q = normalToQuat(nrm)
    wI16(pool, b + 16, q[0]); wI16(pool, b + 18, q[1])
    wI16(pool, b + 20, q[2]); wI16(pool, b + 22, q[3])
  result = pool

# ---- damage tail resize (mirror of builders.nim:373-421) ----

proc resizeTail(carbin: openArray[byte], tpl: SectionInfo,
                newLodCount: uint32): seq[byte] =
  let aFieldOk = tpl.aFieldPos > 0 and tpl.aTableEnd > tpl.aTableStart
  let donorATableLen = tpl.aTableEnd - tpl.aTableStart
  let donorAField =
    if aFieldOk:
      uint32(carbin[tpl.aFieldPos]) shl 24 or
      uint32(carbin[tpl.aFieldPos + 1]) shl 16 or
      uint32(carbin[tpl.aFieldPos + 2]) shl 8 or
      uint32(carbin[tpl.aFieldPos + 3])
    else: 0'u32
  let recordB =
    if aFieldOk and donorAField > 0'u32: donorATableLen div int(donorAField)
    else: 0
  let needsResize = aFieldOk and recordB > 0 and newLodCount != donorAField
  if not needsResize:
    return sliceB(carbin, tpl.vertexCountPos, tpl.endPos)
  let beforeAField = sliceB(carbin, tpl.vertexCountPos, tpl.aFieldPos)
  let bAndReserved = sliceB(carbin, tpl.aFieldPos + 4, tpl.aTableStart)
  let afterATable = sliceB(carbin, tpl.aTableEnd, tpl.endPos)
  let donorTable = sliceB(carbin, tpl.aTableStart, tpl.aTableEnd)
  let newTableLen = int(newLodCount) * recordB
  # The a*b table is REAL per-vertex 4-byte data (not all-neutral). All-zero
  # records make the runtime compute garbage (insane floats) at load — the
  # working cross-car path copies the donor's records. We have one record
  # per template vertex; cycle them so every new vertex gets a valid-shaped
  # record (mismatched but well-formed, vs zeros which crash).
  var newTable = newSeq[byte](newTableLen)
  let srcRecs = int(donorAField)
  if srcRecs > 0:
    for i in 0 ..< int(newLodCount):
      let src = (i mod srcRecs) * recordB
      for k in 0 ..< recordB: newTable[i*recordB + k] = donorTable[src + k]
  result = beforeAField & @(bePackU32(newLodCount)) & bAndReserved &
           newTable & afterATable

# ---- synthesize a section from a mesh, cloning a template section ----

proc synthSectionFromMesh*(carbin: openArray[byte], tpl: SectionInfo,
                           positions, uvs, normals: seq[float32],
                           indices: seq[uint32], newName: string,
                           boxScale: float32 = 1.0'f32,
                           posOffset: array[3, float32] = [0.0'f32, 0.0'f32, 0.0'f32],
                           subIdx: int = 0): seq[byte] =
  ## Build a complete cvFive section carrying `positions/uvs/normals/indices`
  ## (world-space), using `tpl` (an existing CLEAN body section in `carbin`)
  ## as the byte scaffold. One TriList subsection cloned from `tpl`'s
  ## `subIdx`-th subsection (its material binding rides along); damage tail
  ## resized to the new vertex count. The mesh is fit (uniform, aspect-
  ## preserved) into `tpl`'s target bbox scaled by `boxScale` (the runtime
  ## honors the written transform), shifted by `posOffset`. Intended for
  ## REPLACING an existing slot (see docs/FH1_PART_EDITING.md §4).
  if tpl.subsections.len == 0:
    raise newException(SectionEditError, "template section has no subsections")
  if indices.len mod 3 != 0:
    raise newException(SectionEditError, "indices not a multiple of 3")
  # Donor slot's target bbox (9 floats: offset + tMin + tMax) and pool range.
  var dTMin, dTMax: array[3, float32]
  for a in 0 .. 2:
    let oMin = tpl.transformPos + 12 + a*4
    let oMax = tpl.transformPos + 24 + a*4
    dTMin[a] = cast[float32](uint32(carbin[oMin]) shl 24 or uint32(carbin[oMin+1]) shl 16 or
                             uint32(carbin[oMin+2]) shl 8 or uint32(carbin[oMin+3]))
    dTMax[a] = cast[float32](uint32(carbin[oMax]) shl 24 or uint32(carbin[oMax+1]) shl 16 or
                             uint32(carbin[oMax+2]) shl 8 or uint32(carbin[oMax+3]))
  # Scale the target bbox by boxScale (about its center).
  var sTMin, sTMax: array[3, float32]
  for a in 0 .. 2:
    let c = (dTMin[a] + dTMax[a]) * 0.5'f32
    let h = (dTMax[a] - dTMin[a]) * 0.5'f32 * boxScale
    sTMin[a] = c - h; sTMax[a] = c + h
  let nr = poolRange(carbin, tpl)
  let pool = buildMeshPoolFit(positions, uvs, normals, sTMin, sTMax, nr.mn, nr.mx)
  let vcount = pool.len div 28

  # --- subsection: clone the chosen template subsection (its m_MaterialSets
  # binding — i.e. which texture/shader the game uses — rides along) ---
  let ss = tpl.subsections[(if subIdx >= 0 and subIdx < tpl.subsections.len: subIdx else: 0)]
  var ssPrefix = sliceB(carbin, ss.start, ss.idxCountPos)
  let ident = [0.0'f32, 1.0'f32, 0.0'f32, 1.0'f32, 0.0'f32, 1.0'f32, 0.0'f32, 1.0'f32]
  for k in 0 .. 7:
    let p = bePackF32(ident[k])
    for j in 0 .. 3: ssPrefix[5 + k*4 + j] = p[j]
  block:   # lod = 1
    let lp = ss.lodPos - ss.start
    let p = bePackI32(1'i32)
    for j in 0 .. 3: ssPrefix[lp + j] = p[j]
  block:   # indexType = 4 (TriList)
    let ip = ss.lodPos + 4 - ss.start
    let p = bePackU32(4'u32)
    for j in 0 .. 3: ssPrefix[ip + j] = p[j]
  var idxData = newSeq[byte](indices.len * 2)
  for i, ix in indices:
    let p = bePackU16(uint16(ix)); idxData[i*2] = p[0]; idxData[i*2 + 1] = p[1]
  let ssTrail = sliceB(carbin, ss.afterIdxPos, ss.endPos)
  let ssBlob = ssPrefix & @(bePackI32(int32(indices.len))) & @(bePackI32(2'i32)) &
               idxData & ssTrail

  # --- section assembly (mirror builders.buildSection... layout) ---
  # Keep the donor's offset; write the (scaled) target bbox we fit into.
  var prefix = sliceB(carbin, tpl.start, tpl.lodVertexCountPos)
  block:
    let tRel = tpl.transformPos - tpl.start
    for a in 0 .. 2:
      # offset = donor offset + posOffset (shift the part in world)
      let oOff = tpl.transformPos + a*4
      let donorOff = cast[float32](uint32(carbin[oOff]) shl 24 or uint32(carbin[oOff+1]) shl 16 or
                                   uint32(carbin[oOff+2]) shl 8 or uint32(carbin[oOff+3]))
      let pOff = bePackF32(donorOff + posOffset[a])
      let pMin = bePackF32(sTMin[a]); let pMax = bePackF32(sTMax[a])
      for j in 0 .. 3:
        prefix[tRel + a*4 + j] = pOff[j]
        prefix[tRel + 12 + a*4 + j] = pMin[j]
        prefix[tRel + 24 + a*4 + j] = pMax[j]
  let betweenSizeAndPool   = sliceB(carbin, tpl.lodVertexSizePos + 4, tpl.lodVerticesStart)
  let betweenLodAndSubcount = sliceB(carbin, tpl.lodVerticesEnd, tpl.subpartCountPos)
  let betweenSubsAndVc     = sliceB(carbin, tpl.subsectionsEnd, tpl.vertexCountPos)
  let suffix = resizeTail(carbin, tpl, uint32(vcount))

  var sec = prefix & @(bePackU32(uint32(vcount))) & @(bePackU32(28'u32)) &
            betweenSizeAndPool & pool & betweenLodAndSubcount &
            @(bePackU32(1'u32)) & ssBlob & betweenSubsAndVc & suffix
  sec = patchSectionNameRescan(sec, newName)
  result = sec

proc rdU32(carbin: openArray[byte], o: int): uint32 =
  uint32(carbin[o]) shl 24 or uint32(carbin[o+1]) shl 16 or
  uint32(carbin[o+2]) shl 8 or uint32(carbin[o+3])

proc sectionHeaderCounts*(carbin: openArray[byte], sec: SectionInfo):
                         tuple[perm, cnt2: uint32] =
  ## permCount and cnt2 from a section header. Glass sections carry
  ## non-zero values (per-vertex/triangle permutation + index blocks that
  ## reference THEIR OWN geometry). A clone template MUST have both == 0,
  ## else the cloned blocks reference indices absent from the new mesh →
  ## the runtime reads out of range (ERANGE) at load. body/hooda/bumper*
  ## are clean; glass* are not.
  let permPos = sec.transformPos + 36 + 28
  if permPos + 4 > carbin.len: return (uint32.high, uint32.high)
  let perm = rdU32(carbin, permPos)
  let cnt2Pos = permPos + 4 + int(perm) * 16 + 4
  if perm > 1_000_000'u32 or cnt2Pos + 4 > carbin.len:
    return (perm, uint32.high)
  result = (perm, rdU32(carbin, cnt2Pos))

proc perSectionIdRel(sec: SectionInfo): int =
  ## Byte offset of perSectionId within the section, or -1 if the section
  ## has none (m_NumBoneWeights==0). cvFive: pool starts at
  ## lodVertexSizePos+12 when perSectionId present (size+4 mbw, +4 id),
  ## +8 when absent.
  let gap = sec.lodVerticesStart - sec.lodVertexSizePos
  if gap >= 12: return (sec.lodVertexSizePos + 8) - sec.start
  return -1

proc readPerSectionIds*(carbin: openArray[byte], info: CarbinInfo): HashSet[uint32] =
  result = initHashSet[uint32]()
  for s in info.sections:
    let rel = perSectionIdRel(s)
    if rel < 0: continue
    let o = s.start + rel
    result.incl(uint32(carbin[o]) shl 24 or uint32(carbin[o+1]) shl 16 or
                uint32(carbin[o+2]) shl 8 or uint32(carbin[o+3]))

proc rdI16BE(b: openArray[byte], o: int): int16 =
  cast[int16]((uint16(b[o]) shl 8) or uint16(b[o+1]))

proc rdU16BE(b: openArray[byte], o: int): uint16 =
  (uint16(b[o]) shl 8) or uint16(b[o+1])

proc mutateRegenQuats*(carbin: openArray[byte], sec: SectionInfo): seq[byte] =
  ## REAL section, but every LOD vertex's tangent quaternion replaced by
  ## normalToQuat(decoded normal). Bisect probe: isolates "generated quats"
  ## (the one field synthesis fabricates; working paths copy it verbatim).
  result = sliceB(carbin, sec.start, sec.endPos)
  let n = int(sec.lodVerticesCount)
  let stride = int(sec.lodVerticesSize)
  let baseRel = sec.lodVerticesStart - sec.start
  for i in 0 ..< n:
    let q0 = baseRel + i*stride + 16
    let q: Quat = [shortn(rdI16BE(result, q0)), shortn(rdI16BE(result, q0+2)),
                   shortn(rdI16BE(result, q0+4)), shortn(rdI16BE(result, q0+6))]
    let nq = normalToQuat(quatToMatrixRow0(q))
    for k in 0 .. 3: wI16(result, q0 + k*2, nq[k])

proc isRestart(v: uint32, idxSize: int): bool =
  if idxSize == 2: return v == 0xFFFF'u32
  v == 0xFFFFFFFF'u32 or v == 0x00FFFFFF'u32 or v == 0x0000FFFF'u32

proc stripToList(idx: seq[uint32], idxSize: int): seq[uint32] =
  ## Expand a triangle strip (with restart sentinels) to a flat triangle
  ## list, alternating winding within each sub-strip (parity resets on
  ## restart). Mirrors gltf.nim:tristripToTris.
  result = @[]
  var i = 0
  var stripBase = 0
  while i + 2 < idx.len:
    if isRestart(idx[i], idxSize) or isRestart(idx[i+1], idxSize) or isRestart(idx[i+2], idxSize):
      while i < idx.len and not isRestart(idx[i], idxSize): inc i
      while i < idx.len and isRestart(idx[i], idxSize): inc i
      stripBase = i; continue
    if idx[i] == idx[i+1] or idx[i+1] == idx[i+2] or idx[i] == idx[i+2]:
      inc i; continue
    if ((i - stripBase) and 1) == 0:
      result.add idx[i]; result.add idx[i+1]; result.add idx[i+2]
    else:
      result.add idx[i]; result.add idx[i+2]; result.add idx[i+1]
    inc i

proc mutateTriList*(carbin: openArray[byte], sec: SectionInfo): seq[byte] =
  ## REAL section, every TriStrip subsection converted to TriList (indexType
  ## 6→4, strips expanded to flat triangle lists). Bisect probe: isolates
  ## the index-encoding choice (synthesis emits TriList; real uses TriStrip).
  var prefix = sliceB(carbin, sec.start, sec.subsections[0].start)
  var ssBlob: seq[byte] = @[]
  for ss in sec.subsections:
    let isz = int(ss.idxSize)
    var idx = newSeq[uint32](int(ss.idxCount))
    for k in 0 ..< int(ss.idxCount):
      if isz == 2: idx[k] = uint32(rdU16BE(carbin, ss.idxDataStart + k*2))
      else: idx[k] = (uint32(carbin[ss.idxDataStart+k*4]) shl 24) or
                     (uint32(carbin[ss.idxDataStart+k*4+1]) shl 16) or
                     (uint32(carbin[ss.idxDataStart+k*4+2]) shl 8) or
                      uint32(carbin[ss.idxDataStart+k*4+3])
    let tris = (if ss.indexType == 6'u32: stripToList(idx, isz) else: idx)
    var ssp = sliceB(carbin, ss.start, ss.idxCountPos)
    # indexType=4 at lodPos+4
    block:
      let ip = ss.lodPos + 4 - ss.start
      let p = bePackU32(4'u32)
      for j in 0..3: ssp[ip+j] = p[j]
    var idxData = newSeq[byte](tris.len * isz)
    for k, v in tris:
      if isz == 2:
        let p = bePackU16(uint16(v)); idxData[k*2]=p[0]; idxData[k*2+1]=p[1]
      else:
        let p = bePackU32(v); for j in 0..3: idxData[k*4+j]=p[j]
    let ssTrail = sliceB(carbin, ss.afterIdxPos, ss.endPos)
    ssBlob.add(ssp & @(bePackI32(int32(tris.len))) & @(bePackI32(int32(isz))) & idxData & ssTrail)
  let suffix = sliceB(carbin, sec.subsections[^1].endPos, sec.endPos)
  result = prefix & ssBlob & suffix

proc mutateMergeSubs*(carbin: openArray[byte], sec: SectionInfo): seq[byte] =
  ## REAL section, but all subsections merged into ONE TriList subsection
  ## (verts/quats/a*b untouched). Bisect probe: isolates the subsection-count
  ## change (synthesis emits 1; real hooda has 9).
  var allTris: seq[uint32] = @[]
  for ss in sec.subsections:
    let isz = int(ss.idxSize)
    var idx = newSeq[uint32](int(ss.idxCount))
    for k in 0 ..< int(ss.idxCount):
      if isz == 2: idx[k] = uint32(rdU16BE(carbin, ss.idxDataStart + k*2))
      else: idx[k] = (uint32(carbin[ss.idxDataStart+k*4]) shl 24) or
                     (uint32(carbin[ss.idxDataStart+k*4+1]) shl 16) or
                     (uint32(carbin[ss.idxDataStart+k*4+2]) shl 8) or
                      uint32(carbin[ss.idxDataStart+k*4+3])
    let tris = (if ss.indexType == 6'u32: stripToList(idx, isz) else: idx)
    for v in tris: allTris.add v
  let ss0 = sec.subsections[0]
  var ssp = sliceB(carbin, ss0.start, ss0.idxCountPos)
  block:   # indexType = 4
    let ip = ss0.lodPos + 4 - ss0.start
    let p = bePackU32(4'u32)
    for j in 0..3: ssp[ip+j] = p[j]
  var idxData = newSeq[byte](allTris.len * 2)   # all hooda verts < 65536 → u16
  for k, v in allTris:
    let p = bePackU16(uint16(v)); idxData[k*2]=p[0]; idxData[k*2+1]=p[1]
  let ssTrail = sliceB(carbin, ss0.afterIdxPos, ss0.endPos)
  let merged = ssp & @(bePackI32(int32(allTris.len))) & @(bePackI32(2'i32)) & idxData & ssTrail
  result = sliceB(carbin, sec.start, sec.subpartCountPos) & @(bePackU32(1'u32)) &
           merged & sliceB(carbin, sec.subsections[^1].endPos, sec.endPos)

proc mutateZeroAtable*(carbin: openArray[byte], sec: SectionInfo): seq[byte] =
  ## REAL section, but the a*b per-vertex table zeroed. Bisect probe: does
  ## the a*b table's CONTENT matter for load? (penger gets cycled/wrong a*b.)
  result = sliceB(carbin, sec.start, sec.endPos)
  for o in (sec.aTableStart - sec.start) ..< (sec.aTableEnd - sec.start):
    result[o] = 0

proc cloneSectionRenamed*(carbin: openArray[byte], sec: SectionInfo,
                          newName: string, newPerSecId: int = -1): seq[byte] =
  ## Verbatim byte-copy of an existing section, renamed. Used to isolate
  ## "is appending a 34th part the problem" from "is my synthesized
  ## geometry the problem" — the bytes are guaranteed game-valid.
  ## `newPerSecId >= 0` overwrites the section's perSectionId (so an
  ## appended copy gets a unique id instead of colliding with its source).
  var raw = sliceB(carbin, sec.start, sec.endPos)
  if newPerSecId >= 0:
    let rel = perSectionIdRel(sec)
    if rel >= 0:
      let p = bePackU32(uint32(newPerSecId))
      for j in 0 .. 3: raw[rel + j] = p[j]
  result = patchSectionNameRescan(raw, newName)

# ---- drop + append, rebuilding the carbin with partCount fixed ----

proc applyPartEdits*(carbin: openArray[byte], info: CarbinInfo,
                     dropNames: HashSet[string],
                     appended: seq[seq[byte]],
                     replace: Table[string, seq[byte]] = initTable[string, seq[byte]]()):
                     tuple[bytes: seq[byte]; ok: bool; msg: string] =
  ## Rebuild `carbin`: substitute sections named in `replace` IN PLACE (keeps
  ## their original ordinal position — important so a swapped part never
  ## becomes the last section, whose tail has no next-marker to delimit it),
  ## drop sections named in `dropNames`, and append `appended` blobs after the
  ## last section; patch the u32 partCount. Refuses if the carbin has unparsed
  ## gap sections (partCount != parsed).
  if info.sections.len != int(info.partCountDeclared):
    return (@carbin, false,
      "carbin has unparsed gap sections (declared " &
      $info.partCountDeclared & " parsed " & $info.sections.len &
      "); part edits skipped")
  let pre = sliceB(carbin, 0, info.sections[0].start)
  var body: seq[byte] = @[]
  var kept = 0
  for s in info.sections:
    if s.name in replace:
      body.add replace[s.name]; inc kept
    elif s.name in dropNames:
      continue
    else:
      body.add sliceB(carbin, s.start, s.endPos); inc kept
  for a in appended: body.add a
  let post = sliceB(carbin, info.sections[^1].endPos, carbin.len)
  var outb = pre & body & post
  let newCount = uint32(kept + appended.len)
  writeU32(outb, info.partCountPos, newCount)
  # Validate: must reparse with the new partCount and section count.
  try:
    let chk = parseFm4Carbin(outb)
    if int(chk.partCountDeclared) != int(newCount):
      return (@carbin, false, "rebuilt partCount mismatch after reparse")
  except CatchableError as e:
    return (@carbin, false, "rebuilt carbin failed reparse: " & e.msg)
  result = (outb, true, "")
