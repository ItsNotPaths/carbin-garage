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
    padToTargetVpool: bool = true): tuple[bytes: seq[byte]; idxConverted, rstFixed: int] =

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

  var sel: seq[SubSectionInfo] = @[]
  for ss in donorSec.subsections:
    if ss.lod == donorLod:
      if allowedSubparts.isNone or ss.name in allowedSubparts.get:
        sel.add(ss)
  if sel.len == 0:
    raise newException(ValueError,
      "Donor section has no subsections for LOD" & $donorLod & " (after filtering).")

  let desiredIdxSize = desiredIdxSizeForTarget(targetSec, targetLod)
  var ssBlob: seq[byte] = @[]
  var idxConverted = 0
  var rstFixed = 0

  for ss in sel:
    var b = sliceBytes(donorData, ss.start, ss.endPos)
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
    if padToTargetVpool:
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

    let prefix = sliceBytes(tgtBytes, 0, targetSec.subpartCountPos - targetSec.start)
    let betweenSubsAndVc = sliceBytes(tgtBytes,
      targetSec.subsectionsEnd - targetSec.start,
      targetSec.vertexCountPos - targetSec.start)
    let tail = sliceBytes(tgtBytes,
      targetSec.tailStart - targetSec.start, tgtBytes.len)
    let rebuilt = concatBytes(
      prefix,
      @(bePackU32(newSubcount)),
      ssBlob,
      betweenSubsAndVc,
      @(bePackI32(newVertexCount)),
      @(bePackU32(newVertexSize)),
      poolBlob,
      tail)
    return (rebuilt, idxConverted, rstFixed)

  # target_lod > 0
  let tgtLodVCount = int(targetSec.lodVerticesCount)
  let tgtLodVSize = int(targetSec.lodVerticesSize)
  var newLodCount: uint32
  var newLodSize: uint32
  var lodBlob: seq[byte]
  if padToTargetVpool and tgtLodVCount > 0 and tgtLodVSize > 0:
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

  let prefixBeforeLod = sliceBytes(tgtBytes, 0, targetSec.lodVertexCountPos - targetSec.start)
  let betweenLodAndSubcount = sliceBytes(tgtBytes,
    targetSec.lodVerticesEnd - targetSec.start,
    targetSec.subpartCountPos - targetSec.start)
  let betweenSubsAndVc = sliceBytes(tgtBytes,
    targetSec.subsectionsEnd - targetSec.start,
    targetSec.vertexCountPos - targetSec.start)
  let suffixFromVc = sliceBytes(tgtBytes,
    targetSec.vertexCountPos - targetSec.start, tgtBytes.len)

  let rebuilt = concatBytes(
    prefixBeforeLod,
    @(bePackU32(newLodCount)),
    @(bePackU32(newLodSize)),
    lodBlob,
    betweenLodAndSubcount,
    @(bePackU32(newSubcount)),
    ssBlob,
    betweenSubsAndVc,
    suffixFromVc)
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
