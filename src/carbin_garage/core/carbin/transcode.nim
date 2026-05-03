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
import ./damage_remap
import ../profile

const TranscodeTrace {.booldefine.} = false
const SliceDDamageRemap {.booldefine.} = false
  ## Experimental: NN-remap donor's per-vertex damage table (a*b) onto
  ## source's vertex order. Empirically does NOT fix cross-game spike
  ## artifacts on collision in FH1 — its deformation engine doesn't
  ## read this table. Off by default. The eventual UI toggle for
  ## "experimental damage export" will flip this; until then users
  ## should rely on FH1's in-game "no visual damage" setting.
const SliceDExtra4Zero {.booldefine.} = true
  ## Zero `extra4` bytes 1..3 in each cross-version vertex. Empirically
  ## fixes cross-game paint splotchiness — those bytes carry FM4 tangent
  ## encoding that FH1 reads as something else, producing per-vertex
  ## shading garbage. Byte 0 (~70% match with FM4 extra8[0]) is preserved.

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
    gapsPreserved*: int  ## Slice C: donor byte ranges between parsed
                          ## sections (LOD0-only sections in main carbin)
                          ## emitted verbatim so partCount stays consistent.
    damageRemapped*: int ## Slice D: spliced sections whose a*b damage
                          ## table was remapped by spatial-NN over donor's
                          ## vertex order (cvFour→cvFive only).
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
  ## Truncate each 32-byte FM4 vertex to FH1's 28 bytes. Empirically
  ## verified 2026-05-01 against 8 paired sample cars × multiple body
  ## sections (3000+ vertices total): FH1 vertex bytes [0..24) are
  ## byte-IDENTICAL to FM4 vertex bytes [0..24) in every case.
  ##
  ## Real FH1 vertex layout (correcting prior misdoc):
  ##   pos[8]  uv0[4]  uv1[4]  quat[8]  extra4[4]   = 28 bytes
  ## FH1 KEEPS uv1 (it was thought to be dropped). What FH1 drops is the
  ## last 4 bytes of FM4's 8-byte extra8 trailing field.
  ##
  ## The trailing 4 bytes of FH1's extra4 vs FM4's extra8 first 4 bytes:
  ## byte 0 matches ~70% of the time (likely a quantized AO or compact
  ## tangent component); bytes 1..3 differ (re-baked tangent encoding).
  ## We copy FM4's first 4 extra8 bytes — close enough for byte 0; bytes
  ## 1..3 will be slightly off but aren't dominant for surface normals
  ## (the quat at [16..24) carries the primary tangent space).
  ##
  ## **Why the prior "drop UV1 at [12..16)" was wrong**: it placed FM4's
  ## quat (offset 16) at FH1's UV1 slot (offset 12) and FM4's extra8 at
  ## FH1's quat slot (offset 16). Shader read garbage as the quaternion
  ## → wrong normals on every vertex → in-game splotchy black body.
  if fm4Pool.len mod Fm4VertexStride != 0:
    raise newException(TranscodeError,
      "fm4PoolToFh1: input length " & $fm4Pool.len &
      " not a multiple of 32 bytes")
  let n = fm4Pool.len div Fm4VertexStride
  result = newSeq[byte](n * Fh1VertexStride)
  for i in 0 ..< n:
    let src = i * Fm4VertexStride
    let dst = i * Fh1VertexStride
    for j in 0 ..< Fh1VertexStride:
      result[dst + j] = fm4Pool[src + j]
    if SliceDExtra4Zero:
      result[dst + 25] = 0
      result[dst + 26] = 0
      result[dst + 27] = 0

# ---- the splice driver ----

proc spliceCarbin(sourceData, donorData: openArray[byte],
                  srcInfo, donInfo: CarbinInfo,
                  srcVer, donVer: CarbinVersion):
                  tuple[bytes: seq[byte]; spliced: int; fallback: int;
                        gapsPreserved: int; damageRemapped: int] =
  ## Donor's part list is authoritative. For each donor section, look up
  ## a source section by name; splice if possible, otherwise donor verbatim.
  ## Assemble the final file by concatenating donor's pre-section bytes,
  ## the rebuilt section blobs, and donor's post-section bytes.
  ##
  ## v2 splice (cvFour→cvFive): re-stride the source LOD pool (32→28)
  ## via `fm4PoolToFh1`, force the rebuilt section's lodVSize field to 28,
  ## and validate each rebuilt section by reparsing it. On any validation
  ## failure (parse raise, vertex count mismatch, length mismatch,
  ## subsection count mismatch) we fall back to donor's section bytes
  ## verbatim — so partial transcode is automatic.
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
  var gapsPreserved = 0
  var damageRemapped = 0

  let renames = initTable[string, string]()
  let allowed = none(HashSet[string])

  let crossVersionStride = (srcVer == cvFour and donVer == cvFive)

  for kIdx, donSec in donInfo.sections:
    # Slice C: preserve donor bytes between consecutive parsed sections.
    # Cars like R8 carry LOD0-only sections inside the main carbin (no
    # LOD pool, only LOD0). Their layout differs from regular sections
    # — e.g. no `m_NumBoneWeights` block before a non-existent LOD pool
    # — and the body parser raises on them, then scans forward for the
    # next `[u32=5][9 sane floats]` marker. The skipped byte range IS
    # the LOD0-only section. Emitting that gap verbatim preserves the
    # section so FH1's main-thread walk hits real bytes at every slot
    # the partCount field promises (R8 declares 49; this lets us emit
    # all 49 even though the parser only resolved 37).
    if kIdx > 0:
      let prev = donInfo.sections[kIdx - 1]
      if prev.endPos < donSec.start:
        var gap = newSeq[byte](donSec.start - prev.endPos)
        for i in 0 ..< gap.len: gap[i] = donorData[prev.endPos + i]
        newSecs.add(gap)
        inc gapsPreserved

    let donorSecBytes = block:
      var b = newSeq[byte](donSec.endPos - donSec.start)
      for i in 0 ..< b.len: b[i] = donorData[donSec.start + i]
      b

    if donSec.name notin srcByName:
      when TranscodeTrace:
        stderr.writeLine "    [splice] '" & donSec.name & "' fallback: no name match"
      newSecs.add(donorSecBytes)
      inc fallback
      continue

    let srcSec = srcInfo.sections[srcByName[donSec.name]]

    var thisSecBytes = donorSecBytes
    var thisSpliced = false

    if donSec.lodVerticesCount > 0'u32 and srcSec.lodVerticesCount > 0'u32:
      try:
        var forcedBlob = none(seq[byte])
        var forcedSize = none(uint32)
        if crossVersionStride and srcSec.lodVerticesSize == 32'u32:
          let srcPool = block:
            var b = newSeq[byte](srcSec.lodVerticesEnd - srcSec.lodVerticesStart)
            for i in 0 ..< b.len: b[i] = sourceData[srcSec.lodVerticesStart + i]
            b
          forcedBlob = some(fm4PoolToFh1(srcPool))
          forcedSize = some(uint32(Fh1VertexStride))
        # Slice D: when crossVersion and donor section has a non-empty
        # a*b damage table, remap it by spatial nearest-neighbor so source
        # vertex i inherits donor vertex j_best's per-vertex skinning
        # record (where j_best minimizes ||srcPos[i] - donPos[j]||²). For
        # same-game splices or empty-table sections, leave donor's table
        # verbatim — the bytes are correct as-is.
        var remap = none(seq[byte])
        if SliceDDamageRemap and crossVersionStride and
           donSec.aTableEnd > donSec.aTableStart:
          let srcPool = block:
            var b = newSeq[byte](srcSec.lodVerticesEnd - srcSec.lodVerticesStart)
            for i in 0 ..< b.len: b[i] = sourceData[srcSec.lodVerticesStart + i]
            b
          let donPool = block:
            var b = newSeq[byte](donSec.lodVerticesEnd - donSec.lodVerticesStart)
            for i in 0 ..< b.len: b[i] = donorData[donSec.lodVerticesStart + i]
            b
          let donATable = block:
            var b = newSeq[byte](donSec.aTableEnd - donSec.aTableStart)
            for i in 0 ..< b.len: b[i] = donorData[donSec.aTableStart + i]
            b
          remap = some(remapDamageTable(
            srcPool, int(srcSec.lodVerticesSize), int(srcSec.lodVerticesCount),
            donPool, int(donSec.lodVerticesSize), int(donSec.lodVerticesCount),
            donATable, recordSize = 4))
        let r = buildSectionConvertedToTargetLodOnTargetTemplate(
          donorData, donSec, sourceData, srcSec,
          donorLod = 1'i32, targetLod = 1'i32,
          renameMap = renames, allowedSubparts = allowed,
          upconvertIndices = true, padToTargetVpool = false,
          forcedDonorVertexBlob = forcedBlob,
          forcedNewVertexSize = forcedSize,
          upconvertSubsectionsCvFourToCvFive = crossVersionStride,
          remappedDamageTable = remap)

        # Per-section validation: reparse the rebuilt bytes against the
        # target version. Reject on raise, on byte-count mismatch (parser
        # consumed a different region than the splice produced), or on
        # vertex/subsection-count drift.
        let chk = tryParseSection(r.bytes, donVer)
        var srcLodSubcount = 0
        for ss in srcSec.subsections:
          if ss.lod == 1'i32: inc srcLodSubcount
        # cvFive sections end with 4..8 bytes of variable trailing pad
        # that the parser only resolves via next-section marker probe.
        # In single-section validation there is no next marker, so the
        # parser's no-marker fallback consumes 4 bytes regardless of
        # actual pad. Accept consumed within the rebuilt size minus the
        # max known pad delta (8 bytes).
        var ok = chk.ok and chk.consumed > 0 and
                 chk.consumed >= r.bytes.len - 8 and
                 chk.consumed <= r.bytes.len
        if ok and chk.info.lodVerticesCount != srcSec.lodVerticesCount: ok = false
        if ok and crossVersionStride and chk.info.lodVerticesSize != 28'u32: ok = false
        if ok and chk.info.subsections.len != srcLodSubcount: ok = false
        # LOD0 pool unchanged — must still match donor's counts.
        if ok and chk.info.lod0VerticesCount != donSec.lod0VerticesCount: ok = false
        if ok and chk.info.lod0VerticesSize != donSec.lod0VerticesSize: ok = false
        if ok:
          thisSecBytes = r.bytes
          thisSpliced = true
          if remap.isSome: inc damageRemapped
        else:
          when TranscodeTrace:
            stderr.writeLine "    [splice] '" & donSec.name &
              "' validation reject: parseOk=" & $chk.ok &
              " consumed=" & $chk.consumed & "/" & $r.bytes.len &
              " lodVc(splice)=" & $chk.info.lodVerticesCount &
              " lodVc(src)=" & $srcSec.lodVerticesCount &
              " lodVs(splice)=" & $chk.info.lodVerticesSize &
              " subs(splice)=" & $chk.info.subsections.len &
              " subs(srcLod1)=" & $srcLodSubcount &
              " lod0Vc(splice)=" & $chk.info.lod0VerticesCount &
              " lod0Vc(donor)=" & $donSec.lod0VerticesCount
      except CatchableError as e:
        when TranscodeTrace:
          stderr.writeLine "    [splice] '" & donSec.name &
            "' raise: " & e.msg
        thisSecBytes = donorSecBytes
    else:
      when TranscodeTrace:
        stderr.writeLine "    [splice] '" & donSec.name &
          "' skip: lodVc(don)=" & $donSec.lodVerticesCount &
          " lodVc(src)=" & $srcSec.lodVerticesCount

    if thisSpliced: inc spliced
    else: inc fallback
    newSecs.add(thisSecBytes)

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
  result.gapsPreserved = gapsPreserved
  result.damageRemapped = damageRemapped

# ---- entry point ----

proc transcodeCarbin*(sourceData, donorData: openArray[byte],
                      targetProfile: GameProfile,
                      mode: TranscodeMode = tmDonorVerbatim
                     ): tuple[bytes: seq[byte]; report: TranscodeReport] =
  ## v2 splice (mode=tmHybridSplice): cvFour→cvFive stride conversion
  ## (32→28) is plumbed via `fm4PoolToFh1`, the cvFive m_NumBoneWeights
  ## pre-pool block is preserved, and each rebuilt section is reparsed
  ## as a single-section validation gate — failures fall back to donor
  ## bytes verbatim, so partial transcode (e.g. cockpit splices, main
  ## falls back) is automatic. Default still `tmDonorVerbatim` for
  ## stability; orchestrator opts in.
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
      gapsPreserved: r.gapsPreserved,
      damageRemapped: r.damageRemapped,
      note: "v1: per-section splice with donor-fallback on failure")
    result = (r.bytes, report)

proc passthroughCarbin*(donorData: openArray[byte]): seq[byte] =
  ## For carbin slots the transcode never touches: stripped, caliper /
  ## rotor LOD0s, and the lod0 / cockpit special carbins (those need
  ## the post-pool stream which we don't synthesize yet).
  result = newSeq[byte](donorData.len)
  for i in 0 ..< donorData.len: result[i] = donorData[i]
