## Section builders that combine donor + working byte ranges into rebuilt
## sections. Port of probe/reference/fm4carbin/builders.py. Powers the
## hybrid-splice transcode path (transcode.nim).

import std/[tables, sets, options]
import ../be
import ./model
import ./patch

proc desiredIdxSizeForTarget(targetSec: SectionInfo, targetLod: int32): int32 =
  ## Most common idx_size in target's existing subsections at this LOD,
  ## or a sensible default.
  var matches: seq[int32] = @[]
  for ss in targetSec.subsections:
    if ss.lod == targetLod: matches.add(ss.idxSize)
  if matches.len > 0:
    var counts = initCountTable[int32]()
    for s in matches: counts.inc(s)
    counts.sort()
    return counts.largest.key
  return (if targetLod == 0: 4'i32 else: 2'i32)

proc sliceBytes(buf: openArray[byte], a, b: int): seq[byte] =
  result = newSeq[byte](b - a)
  for i in 0 ..< (b - a): result[i] = buf[a + i]

proc concatBytes(parts: varargs[seq[byte]]): seq[byte] =
  var total = 0
  for p in parts: total += p.len
  result = newSeqOfCap[byte](total)
  for p in parts:
    for b in p: result.add(b)

proc buildSectionConvertedToDonorLodOnDonorTemplate*(
    donorData: openArray[byte], donorSec: SectionInfo,
    workingData: openArray[byte], workingSec: SectionInfo,
    workingLod: int32, donorLod: int32,
    renameMap: Table[string, string],
    allowedSubparts: Option[HashSet[string]] = none(HashSet[string]),
    upconvertIndices: bool = true,
    padToDonorVpool: bool = true,
    forcedWorkingVertexBlob: Option[seq[byte]] = none(seq[byte]),
    forcedNewVertexSize: Option[uint32] = none(uint32),
    upconvertSubsectionsCvFourToCvFive: bool = false,
    downconvertSubsectionsCvFiveToCvFour: bool = false,
    workingTransform9: Option[seq[byte]] = none(seq[byte])
   ): tuple[bytes: seq[byte]; idxConverted, rstFixed: int] =
  ## Build one carbin section in the DONOR's byte form, carrying the
  ## WORKING car's geometry. Vocabulary used throughout this proc:
  ##   - **donor**  = the target-format scaffold/template car. Its section
  ##     bytes (header layout, m_NumBoneWeights blocks, damage table,
  ##     post-pool stream) frame the output. `donorLod` is the LOD slot the
  ##     output is written as. (transcode.nim passes its `donorData` here.)
  ##   - **working** = the car whose geometry is ported in (from working/).
  ##     `workingLod` is the LOD pool read from it. (transcode passes its
  ##     `sourceData` here.)
  ##
  ## `forcedWorkingVertexBlob` / `forcedNewVertexSize` override the working
  ## car's raw vertex pool + vSize (cross-version splice path uses these to
  ## feed a re-strided pool: 32→28 for fm4→fh1, 28→32 for fh1→fm4).
  ## Both must be Some together; their length must equal workingVCount *
  ## forced size. Wired for both the LOD pool (donorLod>0) and the LOD0
  ## pool (donorLod==0) paths. When forced into the LOD0 path with the
  ## section carrying a per-vertex post-pool 4B stream (FH1 lod0/cockpit
  ## body sections — `postPoolEnd > postPoolStart`), the donor's stream
  ## is replaced by `workingVCount * 4` zero bytes so the rebuilt section's
  ## tail length matches the new lod0VCount. Stream zero-fill loses the
  ## supplemental tangent encoding (likely SHORT2N/DEC3N); the dominant
  ## tangent space is in the 28-byte vertex's quaternion, so this only
  ## costs minor shading fidelity in close-camera views.
  ##
  ## `upconvertSubsectionsCvFourToCvFive=true` runs each working subsection
  ## through `upconvertSubsectionCvFourToCvFive` first (insert 4 zero
  ## bytes before idxCount, patch [u32=3]→[u32=4]) so that working FM4
  ## subsection bytes spliced into an FH1 (cvFive) donor template parse
  ## cleanly. `downconvertSubsectionsCvFiveToCvFour=true` is the inverse
  ## (drop the 4 zero bytes, patch [u32=4]→[u32=3]) for fh1→fm4: working
  ## FH1 subsections spliced into an FM4 (cvFour) donor template. At most
  ## one of the two may be true. Subsequent index conversion /
  ## restart-marker fixing runs against the converted bytes + shifted
  ## SubSectionInfo.
  ##
  ## `workingTransform9` (when Some, must be 36 bytes): replaces the 9 floats
  ## at `donorSec.transformPos` (offset.xyz + targetMin.xyz + targetMax.xyz,
  ## BE float32). The carbin per-vertex `spos` is `_XMSHORTN4` decoded as
  ## `pos = CalculateBoundTargetValue(spos, lod0Min, lod0Max, targetMin,
  ## targetMax)`. Splicing the working car's vertex pool onto the donor's
  ## section template without overwriting these bounds renders the mesh
  ## stretched/shrunk to the donor car's bbox (e.g. FM4 beetle body
  ## ports onto FH1 raptor scaffold and renders raptor-sized). On-disk
  ## layout for the 9 floats is identical in FM4 and FH1 — copy bytes
  ## verbatim. Same offset+min+max also feeds the part's collision /
  ## damage AABB so the runtime bbox stays consistent with the geometry.

  var workingVCount: int
  var workingVSize: int
  var workingVerticesBlob: seq[byte]
  if workingLod == 0:
    workingVCount = int(workingSec.lod0VerticesCount)
    workingVSize = int(workingSec.lod0VerticesSize)
    workingVerticesBlob = sliceBytes(workingData, workingSec.lod0VerticesStart, workingSec.lod0VerticesEnd)
  else:
    workingVCount = int(workingSec.lodVerticesCount)
    workingVSize = int(workingSec.lodVerticesSize)
    workingVerticesBlob = sliceBytes(workingData, workingSec.lodVerticesStart, workingSec.lodVerticesEnd)

  if workingVCount <= 0 or workingVSize <= 0:
    raise newException(ValueError,
      "Working car has no non-zero LOD" & $workingLod & " vertex buffer to convert.")

  let donorBytes = sliceBytes(donorData, donorSec.start, donorSec.endPos)

  # Subsection LOD selection. A single carbin section's vertex POOL is
  # shared across multiple LODs of subsections (each subsection group
  # has its own index list referencing the same pool). Body sections
  # carry 5 LOD groups (LOD1-5) sharing the LOD pool; LOD0 sits in the
  # separate lod0VerticesStart..End pool.
  #
  # Selection rule:
  #   workingLod == 0  →  include only ss.lod == 0   (LOD0 pool consumers)
  #   workingLod >= 1  →  include all ss.lod >= 1    (LOD pool consumers,
  #                     i.e. all LODs 1..N for the multi-LOD body case)
  #
  # Fix 2026-05-10: previously we filtered `ss.lod == workingLod` strictly,
  # which dropped LODs 2..N when splicing body sections. The rebuilt
  # section then carried only LOD1 subsections; xenia fell back to donor
  # bytes whenever a missing LOD was needed — making the body appear as
  # the donor car at any non-close camera distance. Diagnosed against
  # Camaro FM4→FH1 cross-car port (probe/nim_camaro_splice_diag.nim).
  var sel: seq[SubSectionInfo] = @[]
  for ss in workingSec.subsections:
    let lodMatches =
      if workingLod == 0: ss.lod == 0
      else: ss.lod >= 1
    if lodMatches:
      if allowedSubparts.isNone or ss.name in allowedSubparts.get:
        sel.add(ss)
  if sel.len == 0:
    raise newException(ValueError,
      "Working section has no subsections for LOD" & $workingLod & " (after filtering).")

  let desiredIdxSize = desiredIdxSizeForTarget(donorSec, donorLod)
  var ssBlob: seq[byte] = @[]
  var idxConverted = 0
  var rstFixed = 0

  for ssOrig in sel:
    var b = sliceBytes(workingData, ssOrig.start, ssOrig.endPos)
    var ss = ssOrig
    if upconvertSubsectionsCvFourToCvFive:
      let up = upconvertSubsectionCvFourToCvFive(b, ss)
      b = up.bytes
      ss = up.ss
    elif downconvertSubsectionsCvFiveToCvFour:
      let dn = downconvertSubsectionCvFiveToCvFour(b, ss)
      b = dn.bytes
      ss = dn.ss
    b = patchSubsectionLod(b, ss, donorLod)

    if desiredIdxSize == 4 and ss.idxSize == 2 and upconvertIndices:
      let (b2, changed) = upconvertSubsectionIndices_2_to_4(b, ss)
      if changed:
        b = b2
        inc idxConverted
    elif desiredIdxSize == 2 and ss.idxSize == 4:
      let (b2, changed) = downconvertSubsectionIndices_4_to_2(b, ss)
      if changed:
        b = b2
        inc idxConverted

    if desiredIdxSize == 4:
      var ssTmp = ss
      if ss.idxSize == 2:
        let origLen = ss.endPos - ss.start
        let delta = b.len - origLen
        ssTmp = SubSectionInfo(
          name: ss.name, lod: donorLod, start: ss.start,
          endPos: ss.endPos + delta,
          idxCount: ss.idxCount, idxSize: 4'i32, indexType: ss.indexType,
          idxCountPos: ss.idxCountPos, idxSizePos: ss.idxSizePos,
          idxDataStart: ss.idxDataStart,
          idxDataEnd: ss.idxDataStart + int(ss.idxCount) * 4,
          afterIdxPos: ss.afterIdxPos + delta,
          nameLenPos: ss.nameLenPos, nameBytesEnd: ss.nameBytesEnd,
          lodPos: ss.lodPos)
      let (b3, changedCnt) = sanitize32bitRestartMarkers(b, ssTmp)
      if changedCnt > 0:
        b = b3
        rstFixed += changedCnt

    if ss.name in renameMap:
      b = patchSubsectionName(b, ss, renameMap[ss.name])
    ssBlob.add(b)

  let newSubcount = sel.len.uint32

  if donorLod == 0:
    let donorVCount = int(donorSec.lod0VerticesCount)
    let donorVSize = int(donorSec.lod0VerticesSize)
    var newVertexCount: int32
    var newVertexSize: uint32
    var poolBlob: seq[byte]
    if forcedWorkingVertexBlob.isSome or forcedNewVertexSize.isSome:
      if forcedWorkingVertexBlob.isNone or forcedNewVertexSize.isNone:
        raise newException(ValueError,
          "forcedWorkingVertexBlob and forcedNewVertexSize must be set together")
      if padToDonorVpool:
        raise newException(ValueError,
          "forced-stride splice is incompatible with padToDonorVpool=true")
      newVertexCount = int32(workingVCount)
      newVertexSize = forcedNewVertexSize.get
      poolBlob = forcedWorkingVertexBlob.get
      if poolBlob.len != int(newVertexCount) * int(newVertexSize):
        raise newException(ValueError,
          "forcedWorkingVertexBlob length " & $poolBlob.len &
          " does not match newVertexCount*newVertexSize " &
          $(int(newVertexCount) * int(newVertexSize)))
    elif padToDonorVpool:
      if workingVSize != donorVSize:
        raise newException(ValueError,
          "VertexSize mismatch: working LOD" & $workingLod & " stride=" & $workingVSize &
          " vs donor LOD0 stride=" & $donorVSize)
      if workingVCount > donorVCount:
        raise newException(ValueError,
          "Working vertexCount " & $workingVCount & " exceeds donor LOD0 vertexCount " &
          $donorVCount & " (cannot pad)")
      let donorVertexBlob = sliceBytes(donorData,
        donorSec.lod0VerticesStart, donorSec.lod0VerticesEnd)
      let need = donorVCount * donorVSize
      let workingNeed = workingVCount * workingVSize
      if donorVertexBlob.len != need or workingVerticesBlob.len != workingNeed:
        raise newException(ValueError, "Vertex blob size mismatch during pad-to-donor for LOD0")
      newVertexCount = int32(donorVCount)
      newVertexSize = uint32(donorVSize)
      poolBlob = workingVerticesBlob & donorVertexBlob[workingNeed ..< donorVertexBlob.len]
    else:
      newVertexCount = int32(workingVCount)
      newVertexSize = uint32(workingVSize)
      poolBlob = workingVerticesBlob

    var prefix = sliceBytes(donorBytes, 0, donorSec.subpartCountPos - donorSec.start)
    if workingTransform9.isSome:
      let blob = workingTransform9.get
      if blob.len != 36:
        raise newException(ValueError,
          "workingTransform9 must be 36 bytes (got " & $blob.len & ")")
      let dst = donorSec.transformPos - donorSec.start
      if dst < 0 or dst + 36 > prefix.len:
        raise newException(ValueError,
          "transform region falls outside section prefix")
      for i in 0 ..< 36: prefix[dst + i] = blob[i]
    let betweenSubsAndVc = sliceBytes(donorBytes,
      donorSec.subsectionsEnd - donorSec.start,
      donorSec.vertexCountPos - donorSec.start)
    # cvFive sections carry m_NumBoneWeights [+ perSectionId] between the
    # vSize field and the actual LOD0 pool start. Splat those donor bytes
    # back in unchanged. Empty for cvFour (vertexSizePos+4 == lod0VerticesStart).
    let betweenLod0SizeAndPool = sliceBytes(donorBytes,
      donorSec.vertexSizePos + 4 - donorSec.start,
      donorSec.lod0VerticesStart - donorSec.start)
    # Tail rewrite: when the section carries a per-vertex post-pool 4B
    # stream (cvFive lod0/cockpit body sections — postPoolEnd >
    # postPoolStart) AND we changed lod0VCount (forced path), produce a
    # `newVertexCount * 4` byte stream. Source carries the same data in
    # its `cTable` (FM4 stores c=lod0Vc d=4 → lod0Vc*4 byte table; FH1
    # stores c=1 d=4 + separate post-pool stream of lod0Vc*4 bytes —
    # same per-vertex 4B data, different layout). When source's cTable
    # byte count matches newVertexCount*4, copy it verbatim. Empirically
    # confirmed 2026-05-10 PM via probe/nim_alfa_lod0_field_diff.nim:
    # alfa 8C FM4 cTable byte counts equal alfa 8C FH1 post-pool byte
    # counts for every body-bearing LOD0 section. Falls back to zero-fill
    # when the byte count doesn't match (rare; would lose shading).
    let hasPostPool = donorSec.postPoolEnd > donorSec.postPoolStart
    let tail =
      if hasPostPool and forcedWorkingVertexBlob.isSome:
        let preStream = sliceBytes(donorBytes,
          donorSec.tailStart - donorSec.start,
          donorSec.postPoolStart - donorSec.start)
        let neededStreamLen = int(newVertexCount) * 4
        let srcCTableLen = workingSec.cTableEnd - workingSec.cTableStart
        let stream =
          if srcCTableLen == neededStreamLen:
            sliceBytes(workingData, workingSec.cTableStart, workingSec.cTableEnd)
          else:
            newSeq[byte](neededStreamLen)
        let trailingPad = sliceBytes(donorBytes,
          donorSec.postPoolEnd - donorSec.start, donorBytes.len)
        concatBytes(preStream, stream, trailingPad)
      else:
        sliceBytes(donorBytes,
          donorSec.tailStart - donorSec.start, donorBytes.len)
    let rebuilt = concatBytes(
      prefix,
      @(bePackU32(newSubcount)),
      ssBlob,
      betweenSubsAndVc,
      @(bePackI32(newVertexCount)),
      @(bePackU32(newVertexSize)),
      betweenLod0SizeAndPool,
      poolBlob,
      tail)
    return (rebuilt, idxConverted, rstFixed)

  # target_lod > 0
  let donorLodVCount = int(donorSec.lodVerticesCount)
  let donorLodVSize = int(donorSec.lodVerticesSize)
  var newLodCount: uint32
  var newLodSize: uint32
  var lodBlob: seq[byte]
  if forcedWorkingVertexBlob.isSome or forcedNewVertexSize.isSome:
    if forcedWorkingVertexBlob.isNone or forcedNewVertexSize.isNone:
      raise newException(ValueError,
        "forcedWorkingVertexBlob and forcedNewVertexSize must be set together")
    if padToDonorVpool:
      raise newException(ValueError,
        "forced-stride splice is incompatible with padToDonorVpool=true")
    newLodCount = uint32(workingVCount)
    newLodSize = forcedNewVertexSize.get
    lodBlob = forcedWorkingVertexBlob.get
    if lodBlob.len != int(newLodCount) * int(newLodSize):
      raise newException(ValueError,
        "forcedWorkingVertexBlob length " & $lodBlob.len &
        " does not match newLodCount*newLodSize " &
        $(int(newLodCount) * int(newLodSize)))
  elif padToDonorVpool and donorLodVCount > 0 and donorLodVSize > 0:
    if workingVSize != donorLodVSize:
      raise newException(ValueError,
        "VertexSize mismatch: working LOD" & $workingLod & " stride=" & $workingVSize &
        " vs donor LOD" & $donorLod & " stride=" & $donorLodVSize)
    if workingVCount > donorLodVCount:
      raise newException(ValueError,
        "Working vertexCount " & $workingVCount & " exceeds donor LOD" & $donorLod &
        " vertexCount " & $donorLodVCount & " (cannot pad)")
    let donorVertexBlob = sliceBytes(donorData,
      donorSec.lodVerticesStart, donorSec.lodVerticesEnd)
    let need = donorLodVCount * donorLodVSize
    let workingNeed = workingVCount * workingVSize
    if donorVertexBlob.len != need or workingVerticesBlob.len != workingNeed:
      raise newException(ValueError,
        "Vertex blob size mismatch during pad-to-donor for LOD" & $donorLod)
    newLodCount = uint32(donorLodVCount)
    newLodSize = uint32(donorLodVSize)
    lodBlob = workingVerticesBlob & donorVertexBlob[workingNeed ..< donorVertexBlob.len]
  else:
    newLodCount = uint32(workingVCount)
    newLodSize = uint32(workingVSize)
    lodBlob = workingVerticesBlob

  var prefixBeforeLod = sliceBytes(donorBytes, 0, donorSec.lodVertexCountPos - donorSec.start)
  if workingTransform9.isSome:
    let blob = workingTransform9.get
    if blob.len != 36:
      raise newException(ValueError,
        "workingTransform9 must be 36 bytes (got " & $blob.len & ")")
    let dst = donorSec.transformPos - donorSec.start
    if dst < 0 or dst + 36 > prefixBeforeLod.len:
      raise newException(ValueError,
        "transform region falls outside section prefixBeforeLod")
    for i in 0 ..< 36: prefixBeforeLod[dst + i] = blob[i]
  # cvFive sections carry m_NumBoneWeights [+ perSectionId] between the
  # vSize field and the actual LOD pool start. Splat those donor bytes
  # back in unchanged. Empty for cvFour (lodVertexSizePos+4 == lodVerticesStart).
  let betweenSizeAndPool = sliceBytes(donorBytes,
    donorSec.lodVertexSizePos + 4 - donorSec.start,
    donorSec.lodVerticesStart - donorSec.start)
  let betweenLodAndSubcount = sliceBytes(donorBytes,
    donorSec.lodVerticesEnd - donorSec.start,
    donorSec.subpartCountPos - donorSec.start)
  let betweenSubsAndVc = sliceBytes(donorBytes,
    donorSec.subsectionsEnd - donorSec.start,
    donorSec.vertexCountPos - donorSec.start)
  # Tail rewrite: keep donor's per-vertex 4B/v "a*b" damage table CONTENT
  # but resize it to match the new (source) LOD vertex count. The runtime
  # uses `a` as the count of damage records; if it stays at donor's count
  # while the LOD pool is source-sized, source's trailing vertices read
  # garbage past the table → consistent spike at the tail of the pool
  # (showed up as the rear-bumper triangle on cross-car ports).
  let aFieldOk = donorSec.aFieldPos > 0 and
                 donorSec.aTableEnd > donorSec.aTableStart
  let donorATableLen = donorSec.aTableEnd - donorSec.aTableStart
  let donorAField =
    if aFieldOk: beU32At(donorData, donorSec.aFieldPos)
    else: 0'u32
  let recordB =
    if aFieldOk and donorAField > 0'u32:
      donorATableLen div int(donorAField)
    else: 0
  let needsResize = aFieldOk and recordB > 0 and
                    newLodCount != donorAField
  let suffix =
    if needsResize:
      let beforeAField = sliceBytes(donorBytes,
        donorSec.vertexCountPos - donorSec.start,
        donorSec.aFieldPos - donorSec.start)
      let bAndReserved = sliceBytes(donorBytes,
        donorSec.aFieldPos + 4 - donorSec.start,
        donorSec.aTableStart - donorSec.start)
      let afterATable = sliceBytes(donorBytes,
        donorSec.aTableEnd - donorSec.start, donorBytes.len)
      let donorTableBytes = sliceBytes(donorBytes,
        donorSec.aTableStart - donorSec.start,
        donorSec.aTableEnd - donorSec.start)
      let newTableLen = int(newLodCount) * recordB
      var newTable = newSeq[byte](newTableLen)
      let copyLen = min(donorTableBytes.len, newTableLen)
      for i in 0 ..< copyLen: newTable[i] = donorTableBytes[i]
      # Trailing entries (if newTable is larger) stay zero-initialized —
      # those vertices get a "neutral" damage record instead of garbage.
      concatBytes(
        beforeAField,
        @(bePackU32(newLodCount)),
        bAndReserved,
        newTable,
        afterATable)
    else:
      sliceBytes(donorBytes,
        donorSec.vertexCountPos - donorSec.start, donorBytes.len)

  let rebuilt = concatBytes(
    prefixBeforeLod,
    @(bePackU32(newLodCount)),
    @(bePackU32(newLodSize)),
    betweenSizeAndPool,
    lodBlob,
    betweenLodAndSubcount,
    @(bePackU32(newSubcount)),
    ssBlob,
    betweenSubsAndVc,
    suffix)
  return (rebuilt, idxConverted, rstFixed)
