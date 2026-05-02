## Carbin transcode (FM4 TypeId 3 ↔ FH1 TypeId 5).
##
## Implements the locked "Option C hybrid donor splice" strategy: the
## donor's archive is the byte-level scaffold (header expansion, expanded
## middle table, +8 sub-skip, m_NumBoneWeights pre-pool blocks,
## lod0VCount post-pool stream) — and the source car's section bytes
## (vertex pool, index pool, subsection geometry, transform) get
## re-quantized into the donor's TypeId-flavored slots.
##
## ## Vertex-pool stride conversion
##
## FM4 ships 32-byte vertices: `pos[8] uv0[4] uv1[4] quat[8] extra8[8]`.
## FH1 ships 28-byte vertices: same layout with **UV1 dropped** at
## offset 0x0C. To splice an FM4 vertex pool into an FH1 section, we
## strip bytes [0x0C..0x10) from each vertex.
##
## ## Section-by-section policy
##
## Donor's part list is authoritative (same convention as
## `orchestrator/portto.nim:planPort` — donor decides which parts a
## valid car has). For each donor section:
##   - look up a source section by name match;
##   - if found AND we can splice without raising → use the
##     spliced bytes (source's vertex/index data wrapped in donor's
##     section template);
##   - otherwise → fall back to donor's section bytes verbatim.
##
## So the worst case is byte-identical to the v0 stub. The best case is
## donor's scaffolding with FM4's geometry inside it. Subsections that
## don't map cleanly (e.g. cockpit interior subassembly missing on the
## source side) just keep donor's mesh.
##
## ## Caveats / scope
##
## - **Stripped, caliper, rotor LOD0**: passthrough via
##   `passthroughCarbin`. These are TypeId 0 / TypeId 1 cvFive carbins
##   where the FM4 source either doesn't ship the same parts or ships
##   them as a different TypeId. Bone-weight blocks and damage tables
##   would need a separate transcode pass; deferred.
## - **lod0 / cockpit per-vertex post-pool stream**: 4 bytes per vertex
##   that FH1's lod0/cockpit carbins carry after the c*d table. We
##   don't synthesize it — donor's stream stays via the section tail
##   passthrough (the splice replaces only the prefix..vertexPool span,
##   the tail bytes including the post-pool stream are donor's).
## - **m_UVOffsetScale**: the source's per-subsection 8-float UV
##   transform travels with the source's subsection bytes verbatim.
##   FH1 ignores UV1's 4 floats but the slots still exist in the
##   subsection header on both formats, so the splice doesn't have to
##   omit them.
## - **Indices**: existing builder handles 2↔4 byte index conversion +
##   restart-marker fixing.

import std/[options, sets, tables]
import ./model
import ./parser
import ./builders
import ../profile

type
  TranscodeError* = object of CatchableError

  TranscodeMode* = enum
    tmDonorVerbatim   ## Legacy v0: return donor bytes verbatim.
    tmHybridSplice    ## Splice source vertex/index data onto donor scaffold.

  TranscodeReport* = object
    mode*: TranscodeMode
    sourceVersion*: CarbinVersion
    sourceTypeId*: uint32
    sourceSections*: int
    donorVersion*: CarbinVersion
    donorTypeId*: uint32
    donorSections*: int
    sectionsSpliced*: int
    sectionsFallback*: int
    note*: string

proc expectedDonorVersion(targetProfile: GameProfile): CarbinVersion =
  ## Validate by family, not exact TypeId — FM4 ships TypeIds 1/2/3 in
  ## cvFour; FH1 ships TypeId 5 main + TypeId 1 cvFive caliper/rotor.
  case targetProfile.carbinTypeId
  of 5: cvFive
  of 1, 2, 3: cvFour
  else: cvUnknown

proc validateDonor(donorData: openArray[byte],
                   targetProfile: GameProfile): tuple[ver: CarbinVersion;
                                                      info: CarbinInfo] =
  let ver = getVersion(donorData)
  if ver == cvUnknown:
    raise newException(TranscodeError, "donor carbin: unknown version")
  let info =
    try: parseFm4Carbin(donorData)
    except CatchableError as e:
      raise newException(TranscodeError, "donor carbin parse failed: " & e.msg)
  let expected = expectedDonorVersion(targetProfile)
  if expected != cvUnknown and ver != expected:
    raise newException(TranscodeError,
      "donor carbin version " & $ver & " does not match target profile " &
      targetProfile.id & " (expected " & $expected & ")")
  result = (ver, info)

proc validateSource(sourceData: openArray[byte]): tuple[ver: CarbinVersion;
                                                        info: CarbinInfo] =
  let ver = getVersion(sourceData)
  if ver == cvUnknown:
    raise newException(TranscodeError, "source carbin: unknown version")
  let info =
    try: parseFm4Carbin(sourceData)
    except CatchableError as e:
      raise newException(TranscodeError, "source carbin parse failed: " & e.msg)
  result = (ver, info)

# ---- vertex stride conversion ----

const Fm4VertexStride = 32
const Fh1VertexStride = 28

proc fm4PoolToFh1*(fm4Pool: openArray[byte]): seq[byte] =
  ## Strip UV1 (bytes [0x0C..0x10) of each 32-byte FM4 vertex). Output
  ## stride is 28 bytes/vertex matching FH1.
  ##
  ## In-game effect: FH1 reads each vertex as the same pos+UV0+quat+extra
  ## fields, just at the new offsets. UV1 had no consumer on FH1
  ## (vertex shader never sampled it on the FH1 28-byte path).
  if fm4Pool.len mod Fm4VertexStride != 0:
    raise newException(TranscodeError,
      "fm4PoolToFh1: input length " & $fm4Pool.len &
      " not a multiple of 32 bytes")
  let n = fm4Pool.len div Fm4VertexStride
  result = newSeq[byte](n * Fh1VertexStride)
  for i in 0 ..< n:
    let src = i * Fm4VertexStride
    let dst = i * Fh1VertexStride
    for j in 0 ..< 0x0C:
      result[dst + j] = fm4Pool[src + j]
    for j in 0 ..< 0x14:
      result[dst + 0x0C + j] = fm4Pool[src + 0x10 + j]

# ---- section-pool helpers (shim source bytes to look like FH1 stride) ----

proc convertedSourceData(sourceData: openArray[byte], srcInfo: CarbinInfo,
                         section: SectionInfo,
                         srcVer, dstVer: CarbinVersion): seq[byte] =
  ## Return a copy of `sourceData` where this section's LOD pool and
  ## LOD0 pool have been re-strided cvFour→cvFive (32→28). The returned
  ## buffer's offsets DIFFER from sourceData's because the section bytes
  ## shrink — but the builder reads the section bytes via `section.start
  ## .. section.endPos`, and we adjust by passing a section copy with
  ## updated offsets. Callers should NOT reuse `srcInfo.sections`
  ## offsets after calling this.
  ##
  ## For srcVer == dstVer, returns a verbatim copy (no work).
  if srcVer == dstVer:
    result = newSeq[byte](sourceData.len)
    for i in 0 ..< sourceData.len: result[i] = sourceData[i]
    return
  if srcVer == cvFour and dstVer == cvFive:
    # The simplest reliable path: leave the section bytes alone and let
    # the builder use the section's reported lodVSize=32 verbatim. FH1
    # then sees a 32-byte stride which doesn't match its expected 28.
    # That's known to render scrambled in-game — but the splice still
    # exercises the codepath end-to-end and gives us a probe.
    #
    # The cleaner fix is to rewrite the section's lodVSize bytes to 28
    # AND replace the pool with a re-strided pool. Doing that requires
    # also knowing the section's vSize positions, which the SectionInfo
    # already records (`lodVertexSizePos` / `vertexSizePos`). Implement
    # in a follow-up; for v1 we ship the verbatim-stride approach to
    # validate the surrounding pipeline.
    result = newSeq[byte](sourceData.len)
    for i in 0 ..< sourceData.len: result[i] = sourceData[i]
    return
  raise newException(TranscodeError,
    "unsupported transcode direction " & $srcVer & "→" & $dstVer)

# ---- the splice driver ----

proc spliceCarbin(sourceData, donorData: openArray[byte],
                  srcInfo, donInfo: CarbinInfo,
                  srcVer, donVer: CarbinVersion):
                  tuple[bytes: seq[byte]; spliced: int; fallback: int] =
  ## Donor's part list is authoritative. For each donor section, look up
  ## a source section by name; splice if possible, otherwise donor verbatim.
  ## Assemble the final file by concatenating donor's pre-section bytes,
  ## the rebuilt section blobs, and donor's post-section bytes.
  var srcByName = initTable[string, int]()
  for i, s in srcInfo.sections: srcByName[s.name] = i

  let preBytes = block:
    var b = newSeq[byte](donInfo.sections[0].start)
    for i in 0 ..< b.len: b[i] = donorData[i]
    b
  let postBytes = block:
    let lastEnd = donInfo.sections[^1].endPos
    var b = newSeq[byte](donorData.len - lastEnd)
    for i in 0 ..< b.len: b[i] = donorData[lastEnd + i]
    b

  var newSecs: seq[seq[byte]] = @[]
  var spliced = 0
  var fallback = 0

  let renames = initTable[string, string]()
  let allowed = none(HashSet[string])

  for donSec in donInfo.sections:
    let donorSecBytes = block:
      var b = newSeq[byte](donSec.endPos - donSec.start)
      for i in 0 ..< b.len: b[i] = donorData[donSec.start + i]
      b

    if donSec.name notin srcByName:
      newSecs.add(donorSecBytes)
      inc fallback
      continue

    let srcSec = srcInfo.sections[srcByName[donSec.name]]

    # Pick a source LOD that has subsections to splice. v1 strategy:
    # use donor's targetLod for the LOD pool; for LOD0 use 0 directly.
    # We splice both LOD pool and the high-detail LOD0 pool.
    var thisSecBytes = donorSecBytes
    var thisSpliced = false

    if donSec.lodVerticesCount > 0'u32 and srcSec.lodVerticesCount > 0'u32:
      try:
        # Use the donor's LOD as the target slot, source's LOD-with-
        # subsections (1) as the donor of bytes. padToTargetVpool=false
        # because cvFour and cvFive vSize differ (32 vs 28).
        let r = buildSectionConvertedToTargetLodOnTargetTemplate(
          donorData, donSec, sourceData, srcSec,
          donorLod = 1'i32, targetLod = 1'i32,
          renameMap = renames, allowedSubparts = allowed,
          upconvertIndices = true, padToTargetVpool = false)
        thisSecBytes = r.bytes
        thisSpliced = true
      except CatchableError:
        thisSecBytes = donorSecBytes  # already set; defensive

    if thisSpliced: inc spliced
    else: inc fallback
    newSecs.add(thisSecBytes)

  # Assemble: pre + sections + post.
  var outLen = preBytes.len + postBytes.len
  for s in newSecs: outLen += s.len
  result.bytes = newSeq[byte](outLen)
  var off = 0
  for i in 0 ..< preBytes.len: result.bytes[off + i] = preBytes[i]
  off += preBytes.len
  for s in newSecs:
    for i in 0 ..< s.len: result.bytes[off + i] = s[i]
    off += s.len
  for i in 0 ..< postBytes.len: result.bytes[off + i] = postBytes[i]
  result.spliced = spliced
  result.fallback = fallback
  # convertedSourceData is a no-op stub for v1; reference it so the
  # symbol stays warm for the v2 pass.
  discard convertedSourceData(sourceData, srcInfo, donInfo.sections[0],
                              srcVer, donVer)

# ---- entry point ----

proc transcodeCarbin*(sourceData, donorData: openArray[byte],
                      targetProfile: GameProfile,
                      mode: TranscodeMode = tmDonorVerbatim
                     ): tuple[bytes: seq[byte]; report: TranscodeReport] =
  ## Default mode is `tmDonorVerbatim` until the v1 splice handles
  ## cvFour→cvFive vertex-stride conversion + per-section parse
  ## validation. tmHybridSplice currently produces bytes that reparse
  ## for lod0/cockpit but BREAK the main carbin's partCount scan —
  ## verified empirically. Opt into tmHybridSplice for experimentation.
  let (srcVer, srcInfo) = validateSource(sourceData)
  let (donVer, donInfo) = validateDonor(donorData, targetProfile)

  case mode
  of tmDonorVerbatim:
    var copy = newSeq[byte](donorData.len)
    for i in 0 ..< donorData.len: copy[i] = donorData[i]
    let report = TranscodeReport(
      mode: tmDonorVerbatim,
      sourceVersion: srcVer, sourceTypeId: srcInfo.typeId,
      sourceSections: srcInfo.sections.len,
      donorVersion: donVer, donorTypeId: donInfo.typeId,
      donorSections: donInfo.sections.len,
      sectionsSpliced: 0, sectionsFallback: donInfo.sections.len,
      note: "donor bytes returned verbatim; source mesh discarded")
    result = (copy, report)
  of tmHybridSplice:
    let r = spliceCarbin(sourceData, donorData, srcInfo, donInfo,
                          srcVer, donVer)
    let report = TranscodeReport(
      mode: tmHybridSplice,
      sourceVersion: srcVer, sourceTypeId: srcInfo.typeId,
      sourceSections: srcInfo.sections.len,
      donorVersion: donVer, donorTypeId: donInfo.typeId,
      donorSections: donInfo.sections.len,
      sectionsSpliced: r.spliced, sectionsFallback: r.fallback,
      note: "v1: per-section splice with donor-fallback on failure")
    result = (r.bytes, report)

proc passthroughCarbin*(donorData: openArray[byte]): seq[byte] =
  ## For carbin slots the transcode never touches: stripped, caliper /
  ## rotor LOD0s, and the lod0 / cockpit special carbins (those need
  ## the post-pool stream which we don't synthesize yet).
  result = newSeq[byte](donorData.len)
  for i in 0 ..< donorData.len: result[i] = donorData[i]
