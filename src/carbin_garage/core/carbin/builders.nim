## Section builders that combine donor + target byte ranges into rebuilt sections.
## Port of probe/reference/fm4carbin/builders.py.
## Powers FH1 transcoding in Phase 2; Phase 1 uses buildSectionAsIs for round-trip.

import std/[tables, sets, options, algorithm, sequtils]
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

proc buildSectionConvertedToTargetLodOnTargetTemplate*(
    targetData: openArray[byte], targetSec: SectionInfo,
    donorData: openArray[byte], donorSec: SectionInfo,
    donorLod: int32, targetLod: int32,
    renameMap: Table[string, string],
    allowedSubparts: Option[HashSet[string]] = none(HashSet[string]),
    upconvertIndices: bool = true,
    padToTargetVpool: bool = true,
    forcedDonorVertexBlob: Option[seq[byte]] = none(seq[byte]),
    forcedNewVertexSize: Option[uint32] = none(uint32),
    upconvertSubsectionsCvFourToCvFive: bool = false,
    srcTransform9: Option[seq[byte]] = none(seq[byte])
   ): tuple[bytes: seq[byte]; idxConverted, rstFixed: int] =
  ## `forcedDonorVertexBlob` / `forcedNewVertexSize` override the donor's
  ## raw vertex pool + vSize (cross-version splice path uses these to feed
  ## a re-strided 28-byte FH1 pool when the donor is FM4 32-byte source).
  ## Both must be Some together; their length must equal donorVCount *
  ## forced size. Wired for both the LOD pool (targetLod>0) and the LOD0
  ## pool (targetLod==0) paths. When forced into the LOD0 path with the
  ## section carrying a per-vertex post-pool 4B stream (FH1 lod0/cockpit
  ## body sections — `postPoolEnd > postPoolStart`), the donor's stream
  ## is replaced by `donorVCount * 4` zero bytes so the rebuilt section's
  ## tail length matches the new lod0VCount. Stream zero-fill loses the
  ## supplemental tangent encoding (likely SHORT2N/DEC3N); the dominant
  ## tangent space is in the 28-byte vertex's quaternion, so this only
  ## costs minor shading fidelity in close-camera views.
  ##
  ## `upconvertSubsectionsCvFourToCvFive=true` runs each donor subsection
  ## through `upconvertSubsectionCvFourToCvFive` first (insert 4 zero
  ## bytes before idxCount, patch [u32=3]→[u32=4]) so that source FM4
  ## subsection bytes spliced into an FH1 section template parse cleanly
  ## as cvFive. All subsequent index conversion / restart-marker fixing
  ## runs against the upconverted bytes + shifted SubSectionInfo.
  ##
  ## `srcTransform9` (when Some, must be 36 bytes): replaces the 9 floats
  ## at `targetSec.transformPos` (offset.xyz + targetMin.xyz + targetMax.xyz,
  ## BE float32). The carbin per-vertex `spos` is `_XMSHORTN4` decoded as
  ## `pos = CalculateBoundTargetValue(spos, lod0Min, lod0Max, targetMin,
  ## targetMax)`. Splicing source's vertex pool onto donor's section
  ## template without overwriting these bounds renders the source mesh
  ## stretched/shrunk to the donor car's bbox (e.g. FM4 beetle body
  ## ports onto FH1 raptor scaffold and renders raptor-sized). On-disk
  ## layout for the 9 floats is identical in FM4 and FH1 — copy bytes
  ## verbatim. Same offset+min+max also feeds the part's collision /
  ## damage AABB so the runtime bbox stays consistent with the geometry.

  var donorVCount: int
  var donorVSize: int
  var donorVerticesBlob: seq[byte]
  if donorLod == 0:
    donorVCount = int(donorSec.lod0VerticesCount)
    donorVSize = int(donorSec.lod0VerticesSize)
    donorVerticesBlob = sliceBytes(donorData, donorSec.lod0VerticesStart, donorSec.lod0VerticesEnd)
  else:
    donorVCount = int(donorSec.lodVerticesCount)
    donorVSize = int(donorSec.lodVerticesSize)
    donorVerticesBlob = sliceBytes(donorData, donorSec.lodVerticesStart, donorSec.lodVerticesEnd)

  if donorVCount <= 0 or donorVSize <= 0:
    raise newException(ValueError,
      "Donor has no non-zero LOD" & $donorLod & " vertex buffer to convert.")

  let tgtBytes = sliceBytes(targetData, targetSec.start, targetSec.endPos)

  # Subsection LOD selection. A single carbin section's vertex POOL is
  # shared across multiple LODs of subsections (each subsection group
  # has its own index list referencing the same pool). Body sections
  # carry 5 LOD groups (LOD1-5) sharing the LOD pool; LOD0 sits in the
  # separate lod0VerticesStart..End pool.
  #
  # Selection rule:
  #   donorLod == 0  →  include only ss.lod == 0   (LOD0 pool consumers)
  #   donorLod >= 1  →  include all ss.lod >= 1    (LOD pool consumers,
  #                     i.e. all LODs 1..N for the multi-LOD body case)
  #
  # Fix 2026-05-10: previously we filtered `ss.lod == donorLod` strictly,
  # which dropped LODs 2..N when splicing body sections. The rebuilt
  # section then carried only LOD1 subsections; xenia fell back to donor
  # bytes whenever a missing LOD was needed — making the body appear as
  # the donor car at any non-close camera distance. Diagnosed against
  # Camaro FM4→FH1 cross-car port (probe/nim_camaro_splice_diag.nim).
  var sel: seq[SubSectionInfo] = @[]
  for ss in donorSec.subsections:
    let lodMatches =
      if donorLod == 0: ss.lod == 0
      else: ss.lod >= 1
    if lodMatches:
      if allowedSubparts.isNone or ss.name in allowedSubparts.get:
        sel.add(ss)
  if sel.len == 0:
    raise newException(ValueError,
      "Donor section has no subsections for LOD" & $donorLod & " (after filtering).")

  let desiredIdxSize = desiredIdxSizeForTarget(targetSec, targetLod)
  var ssBlob: seq[byte] = @[]
  var idxConverted = 0
  var rstFixed = 0

  for ssOrig in sel:
    var b = sliceBytes(donorData, ssOrig.start, ssOrig.endPos)
    var ss = ssOrig
    if upconvertSubsectionsCvFourToCvFive:
      let up = upconvertSubsectionCvFourToCvFive(b, ss)
      b = up.bytes
      ss = up.ss
    b = patchSubsectionLod(b, ss, targetLod)

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
      if ss.idxSize == 2 and desiredIdxSize == 4:
        let origLen = ss.endPos - ss.start
        let delta = b.len - origLen
        ssTmp = SubSectionInfo(
          name: ss.name, lod: targetLod, start: ss.start,
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

  if targetLod == 0:
    let tgtVCount = int(targetSec.lod0VerticesCount)
    let tgtVSize = int(targetSec.lod0VerticesSize)
    var newVertexCount: int32
    var newVertexSize: uint32
    var poolBlob: seq[byte]
    if forcedDonorVertexBlob.isSome or forcedNewVertexSize.isSome:
      if forcedDonorVertexBlob.isNone or forcedNewVertexSize.isNone:
        raise newException(ValueError,
          "forcedDonorVertexBlob and forcedNewVertexSize must be set together")
      if padToTargetVpool:
        raise newException(ValueError,
          "forced-stride splice is incompatible with padToTargetVpool=true")
      newVertexCount = int32(donorVCount)
      newVertexSize = forcedNewVertexSize.get
      poolBlob = forcedDonorVertexBlob.get
      if poolBlob.len != int(newVertexCount) * int(newVertexSize):
        raise newException(ValueError,
          "forcedDonorVertexBlob length " & $poolBlob.len &
          " does not match newVertexCount*newVertexSize " &
          $(int(newVertexCount) * int(newVertexSize)))
    elif padToTargetVpool:
      if donorVSize != tgtVSize:
        raise newException(ValueError,
          "VertexSize mismatch: donor LOD" & $donorLod & " stride=" & $donorVSize &
          " vs target LOD0 stride=" & $tgtVSize)
      if donorVCount > tgtVCount:
        raise newException(ValueError,
          "Donor vertexCount " & $donorVCount & " exceeds target LOD0 vertexCount " &
          $tgtVCount & " (cannot pad)")
      let tgtVertexBlob = sliceBytes(targetData,
        targetSec.lod0VerticesStart, targetSec.lod0VerticesEnd)
      let need = tgtVCount * tgtVSize
      let donorNeed = donorVCount * donorVSize
      if tgtVertexBlob.len != need or donorVerticesBlob.len != donorNeed:
        raise newException(ValueError, "Vertex blob size mismatch during pad-to-target for LOD0")
      newVertexCount = int32(tgtVCount)
      newVertexSize = uint32(tgtVSize)
      poolBlob = donorVerticesBlob & tgtVertexBlob[donorNeed ..< tgtVertexBlob.len]
    else:
      newVertexCount = int32(donorVCount)
      newVertexSize = uint32(donorVSize)
      poolBlob = donorVerticesBlob

    var prefix = sliceBytes(tgtBytes, 0, targetSec.subpartCountPos - targetSec.start)
    if srcTransform9.isSome:
      let blob = srcTransform9.get
      if blob.len != 36:
        raise newException(ValueError,
          "srcTransform9 must be 36 bytes (got " & $blob.len & ")")
      let dst = targetSec.transformPos - targetSec.start
      if dst < 0 or dst + 36 > prefix.len:
        raise newException(ValueError,
          "transform region falls outside section prefix")
      for i in 0 ..< 36: prefix[dst + i] = blob[i]
    let betweenSubsAndVc = sliceBytes(tgtBytes,
      targetSec.subsectionsEnd - targetSec.start,
      targetSec.vertexCountPos - targetSec.start)
    # cvFive sections carry m_NumBoneWeights [+ perSectionId] between the
    # vSize field and the actual LOD0 pool start. Splat those donor bytes
    # back in unchanged. Empty for cvFour (vertexSizePos+4 == lod0VerticesStart).
    let betweenLod0SizeAndPool = sliceBytes(tgtBytes,
      targetSec.vertexSizePos + 4 - targetSec.start,
      targetSec.lod0VerticesStart - targetSec.start)
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
    let hasPostPool = targetSec.postPoolEnd > targetSec.postPoolStart
    let tail =
      if hasPostPool and forcedDonorVertexBlob.isSome:
        let preStream = sliceBytes(tgtBytes,
          targetSec.tailStart - targetSec.start,
          targetSec.postPoolStart - targetSec.start)
        let neededStreamLen = int(newVertexCount) * 4
        let srcCTableLen = donorSec.cTableEnd - donorSec.cTableStart
        let stream =
          if srcCTableLen == neededStreamLen:
            sliceBytes(donorData, donorSec.cTableStart, donorSec.cTableEnd)
          else:
            newSeq[byte](neededStreamLen)
        let trailingPad = sliceBytes(tgtBytes,
          targetSec.postPoolEnd - targetSec.start, tgtBytes.len)
        concatBytes(preStream, stream, trailingPad)
      else:
        sliceBytes(tgtBytes,
          targetSec.tailStart - targetSec.start, tgtBytes.len)
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
  let tgtLodVCount = int(targetSec.lodVerticesCount)
  let tgtLodVSize = int(targetSec.lodVerticesSize)
  var newLodCount: uint32
  var newLodSize: uint32
  var lodBlob: seq[byte]
  if forcedDonorVertexBlob.isSome or forcedNewVertexSize.isSome:
    if forcedDonorVertexBlob.isNone or forcedNewVertexSize.isNone:
      raise newException(ValueError,
        "forcedDonorVertexBlob and forcedNewVertexSize must be set together")
    if padToTargetVpool:
      raise newException(ValueError,
        "forced-stride splice is incompatible with padToTargetVpool=true")
    newLodCount = uint32(donorVCount)
    newLodSize = forcedNewVertexSize.get
    lodBlob = forcedDonorVertexBlob.get
    if lodBlob.len != int(newLodCount) * int(newLodSize):
      raise newException(ValueError,
        "forcedDonorVertexBlob length " & $lodBlob.len &
        " does not match newLodCount*newLodSize " &
        $(int(newLodCount) * int(newLodSize)))
  elif padToTargetVpool and tgtLodVCount > 0 and tgtLodVSize > 0:
    if donorVSize != tgtLodVSize:
      raise newException(ValueError,
        "VertexSize mismatch: donor LOD" & $donorLod & " stride=" & $donorVSize &
        " vs target LOD" & $targetLod & " stride=" & $tgtLodVSize)
    if donorVCount > tgtLodVCount:
      raise newException(ValueError,
        "Donor vertexCount " & $donorVCount & " exceeds target LOD" & $targetLod &
        " vertexCount " & $tgtLodVCount & " (cannot pad)")
    let tgtVertexBlob = sliceBytes(targetData,
      targetSec.lodVerticesStart, targetSec.lodVerticesEnd)
    let need = tgtLodVCount * tgtLodVSize
    let donorNeed = donorVCount * donorVSize
    if tgtVertexBlob.len != need or donorVerticesBlob.len != donorNeed:
      raise newException(ValueError,
        "Vertex blob size mismatch during pad-to-target for LOD" & $targetLod)
    newLodCount = uint32(tgtLodVCount)
    newLodSize = uint32(tgtLodVSize)
    lodBlob = donorVerticesBlob & tgtVertexBlob[donorNeed ..< tgtVertexBlob.len]
  else:
    newLodCount = uint32(donorVCount)
    newLodSize = uint32(donorVSize)
    lodBlob = donorVerticesBlob

  var prefixBeforeLod = sliceBytes(tgtBytes, 0, targetSec.lodVertexCountPos - targetSec.start)
  if srcTransform9.isSome:
    let blob = srcTransform9.get
    if blob.len != 36:
      raise newException(ValueError,
        "srcTransform9 must be 36 bytes (got " & $blob.len & ")")
    let dst = targetSec.transformPos - targetSec.start
    if dst < 0 or dst + 36 > prefixBeforeLod.len:
      raise newException(ValueError,
        "transform region falls outside section prefixBeforeLod")
    for i in 0 ..< 36: prefixBeforeLod[dst + i] = blob[i]
  # cvFive sections carry m_NumBoneWeights [+ perSectionId] between the
  # vSize field and the actual LOD pool start. Splat those donor bytes
  # back in unchanged. Empty for cvFour (lodVertexSizePos+4 == lodVerticesStart).
  let betweenSizeAndPool = sliceBytes(tgtBytes,
    targetSec.lodVertexSizePos + 4 - targetSec.start,
    targetSec.lodVerticesStart - targetSec.start)
  let betweenLodAndSubcount = sliceBytes(tgtBytes,
    targetSec.lodVerticesEnd - targetSec.start,
    targetSec.subpartCountPos - targetSec.start)
  let betweenSubsAndVc = sliceBytes(tgtBytes,
    targetSec.subsectionsEnd - targetSec.start,
    targetSec.vertexCountPos - targetSec.start)
  # Tail rewrite: keep donor's per-vertex 4B/v "a*b" damage table CONTENT
  # but resize it to match the new (source) LOD vertex count. The runtime
  # uses `a` as the count of damage records; if it stays at donor's count
  # while the LOD pool is source-sized, source's trailing vertices read
  # garbage past the table → consistent spike at the tail of the pool
  # (showed up as the rear-bumper triangle on cross-car ports).
  let aFieldOk = targetSec.aFieldPos > 0 and
                 targetSec.aTableEnd > targetSec.aTableStart
  let donorATableLen = targetSec.aTableEnd - targetSec.aTableStart
  let donorAField =
    if aFieldOk:
      uint32(targetData[targetSec.aFieldPos]) shl 24 or
      uint32(targetData[targetSec.aFieldPos + 1]) shl 16 or
      uint32(targetData[targetSec.aFieldPos + 2]) shl 8 or
      uint32(targetData[targetSec.aFieldPos + 3])
    else: 0'u32
  let recordB =
    if aFieldOk and donorAField > 0'u32:
      donorATableLen div int(donorAField)
    else: 0
  let needsResize = aFieldOk and recordB > 0 and
                    uint32(newLodCount) != donorAField
  let suffix =
    if needsResize:
      let beforeAField = sliceBytes(tgtBytes,
        targetSec.vertexCountPos - targetSec.start,
        targetSec.aFieldPos - targetSec.start)
      let bAndReserved = sliceBytes(tgtBytes,
        targetSec.aFieldPos + 4 - targetSec.start,
        targetSec.aTableStart - targetSec.start)
      let afterATable = sliceBytes(tgtBytes,
        targetSec.aTableEnd - targetSec.start, tgtBytes.len)
      let donorTableBytes = sliceBytes(tgtBytes,
        targetSec.aTableStart - targetSec.start,
        targetSec.aTableEnd - targetSec.start)
      let newTableLen = int(newLodCount) * recordB
      var newTable = newSeq[byte](newTableLen)
      let copyLen = min(donorTableBytes.len, newTableLen)
      for i in 0 ..< copyLen: newTable[i] = donorTableBytes[i]
      # Trailing entries (if newTable is larger) stay zero-initialized —
      # those vertices get a "neutral" damage record instead of garbage.
      concatBytes(
        beforeAField,
        @(bePackU32(uint32(newLodCount))),
        bAndReserved,
        newTable,
        afterATable)
    else:
      sliceBytes(tgtBytes,
        targetSec.vertexCountPos - targetSec.start, tgtBytes.len)

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

proc buildSectionConvertedToLod0OnTargetTemplate*(
    targetData: openArray[byte], targetSec: SectionInfo,
    donorData: openArray[byte], donorSec: SectionInfo,
    lodPick: int32,
    renameMap: Table[string, string],
    allowedSubparts: Option[HashSet[string]] = none(HashSet[string]),
    upconvertIndices: bool = true,
    padToTargetVpool: bool = true): tuple[bytes: seq[byte]; idxConverted, rstFixed: int] =
  buildSectionConvertedToTargetLodOnTargetTemplate(
    targetData, targetSec, donorData, donorSec,
    lodPick, 0'i32, renameMap, allowedSubparts,
    upconvertIndices, padToTargetVpool)

proc buildSectionAsIs*(donorData: openArray[byte], donorSec: SectionInfo,
                       renameMap: Table[string, string],
                       allowedSubparts: Option[HashSet[string]] = none(HashSet[string])): seq[byte] =
  let secBytes = sliceBytes(donorData, donorSec.start, donorSec.endPos)

  let lodBlob = sliceBytes(donorData, donorSec.lodVerticesStart, donorSec.lodVerticesEnd)
  let lod0Blob = sliceBytes(donorData, donorSec.lod0VerticesStart, donorSec.lod0VerticesEnd)

  let partA = sliceBytes(secBytes,
                donorSec.lodVertexCountPos - donorSec.start,
                donorSec.lodVerticesStart - donorSec.start) & lodBlob
  let midToSubcount = sliceBytes(secBytes,
                donorSec.lodVerticesEnd - donorSec.start,
                donorSec.subpartCountPos - donorSec.start)

  var subsForBuild: seq[SubSectionInfo] = donorSec.subsections
  if allowedSubparts.isSome:
    subsForBuild = subsForBuild.filterIt(it.name in allowedSubparts.get)
  let subcount = subsForBuild.len.uint32

  var ssBlob: seq[byte] = @[]
  for ss in subsForBuild:
    var b = sliceBytes(donorData, ss.start, ss.endPos)
    if ss.name in renameMap:
      b = patchSubsectionName(b, ss, renameMap[ss.name])
    ssBlob.add(b)

  let betweenSubsAndVc = sliceBytes(secBytes,
                donorSec.subsectionsEnd - donorSec.start,
                donorSec.vertexCountPos - donorSec.start)
  let lod0Header = sliceBytes(secBytes,
                donorSec.vertexCountPos - donorSec.start,
                donorSec.lod0VerticesStart - donorSec.start)
  let tail = sliceBytes(secBytes,
                donorSec.tailStart - donorSec.start, secBytes.len)

  result = concatBytes(
    sliceBytes(secBytes, 0, donorSec.lodVertexCountPos - donorSec.start),
    partA,
    midToSubcount,
    @(bePackU32(subcount)),
    ssBlob,
    betweenSubsAndVc,
    lod0Header, lod0Blob,
    tail)
