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
## FH1 ships 28-byte vertices: SAME layout for bytes [0..24) (UV1 is
## KEPT), with the trailing extra8 truncated to extra4. To splice an
## FM4 vertex pool into an FH1 section, truncate each vertex's last 4
## bytes (see `fm4PoolToFh1` for the empirical verification notes).
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
import ./gltf_pack
import ../be
import ../profile

const TranscodeTrace {.booldefine.} = false
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

  TranscodeOptions* = object
    ## Runtime knobs the GUI / CLI surface to the user. Compile-time
    ## constants stay reserved for behaviours that *can't* be safely
    ## per-export (paint fix, parser tracing).
    exportHitboxes*: bool
      ## Gate for physicsdef.bin collision shapes. Default `true`
      ## ships donor's `shapesAndChildren` verbatim. `false` replaces
      ## shapesAndChildren with a single `numShapes=0` u32 — the car
      ## becomes uncollidable (drives through walls, off the map,
      ## potentially through the ground). Confirmed 2026-05-10 on R8
      ## cross-car port. Useful as a stunt / clipping mode; also
      ## proves shapesAndChildren drives BOTH ground collision and
      ## damage (which is why we can't reuse it as the
      ## no-deformation hook on its own).
    lod0SpliceCrossCar*: bool
      ## When `true`, attempt the LOD0/cockpit splice even for cross-car
      ## ports where donor has sections source doesn't (cagerace,
      ## headlightL, etc.). Default `false` ships donor verbatim in that
      ## case to dodge the historical xenia BaseHeap::Alloc loop. The
      ## bypass was added 2026-05-10 alongside damage porting and may
      ## now be stale — main-carbin splice handles donor-only sections
      ## fine cross-car, so the LOD0 carbin probably does too. Flag
      ## exists so we can test that without regressing today's working
      ## damage-port pipeline.
    packFromGltf*: bool
      ## When `true`, geometry export sources vertex POSITIONS from the
      ## working/ glTF (`transcodeCarbinFromGltf`) instead of re-striding
      ## the importee's original carbin pool. Per-vertex UV / tangent /
      ## extra bytes still ride from the source pool by index (Phase 1,
      ## matched topology). Default `false` keeps today's binary-splice
      ## pipeline as the safety net until the glTF path is in-game-verified.
      ## The orchestrator reads this to decide whether to load the glTF and
      ## call the glTF-sourced entry point.

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
    lod0Spliced*: int    ## LOD0-only sections (lod0/cockpit carbins,
                          ## caliper/rotor) whose LOD0 pool was rebuilt
                          ## from source. Visible in autoshow / close
                          ## camera; prior behavior was donor verbatim.
    note*: string

proc defaultTranscodeOptions*(): TranscodeOptions =
  TranscodeOptions(exportHitboxes: true, lod0SpliceCrossCar: false,
                   packFromGltf: false)

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
  if info.sections.len == 0:
    raise newException(TranscodeError, "donor carbin parsed to zero sections")
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

proc fh1PoolToFm4*(fh1Pool: openArray[byte]): seq[byte] =
  ## Inverse of `fm4PoolToFh1`: extend each 28-byte FH1 vertex to FM4's 32
  ## bytes by appending 4 zero bytes. FH1 `pos[8] uv0[4] uv1[4] quat[8]
  ## extra4[4]` maps verbatim to FM4 bytes [0..28); the FH1 extra4 lands in
  ## FM4's extra8[0..4) and extra8[4..8) become zeros (FH1 doesn't carry the
  ## last 4 bytes of FM4's re-baked tangent encoding). The dominant tangent
  ## space lives in the quaternion at [16..24), so the zero tail costs only
  ## minor shading fidelity — symmetric with what fm4PoolToFh1 already drops.
  if fh1Pool.len mod Fh1VertexStride != 0:
    raise newException(TranscodeError,
      "fh1PoolToFm4: input length " & $fh1Pool.len &
      " not a multiple of 28 bytes")
  let n = fh1Pool.len div Fh1VertexStride
  result = newSeq[byte](n * Fm4VertexStride)
  for i in 0 ..< n:
    let src = i * Fh1VertexStride
    let dst = i * Fm4VertexStride
    for j in 0 ..< Fh1VertexStride:
      result[dst + j] = fh1Pool[src + j]
    # bytes [dst+28 .. dst+32) stay zero (newSeq default)

# ---- the splice driver ----

proc spliceCarbin(sourceData, donorData: openArray[byte],
                  srcInfo, donInfo: CarbinInfo,
                  srcVer, donVer: CarbinVersion,
                  gltfDoc: Option[GltfDoc] = none(GltfDoc)):
                  tuple[bytes: seq[byte]; spliced: int; fallback: int;
                        gapsPreserved: int; lod0Spliced: int] =
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

  let preBytes = donorData[0 ..< donInfo.sections[0].start]
  let postBytes = donorData[donInfo.sections[^1].endPos ..< donorData.len]

  var newSecs: seq[seq[byte]] = @[]
  var spliced = 0
  var fallback = 0
  var gapsPreserved = 0
  var lod0Spliced = 0

  let renames = initTable[string, string]()
  let allowed = none(HashSet[string])

  # Cross-version stride conversion runs in either direction:
  #   crossUp   : working FM4 (cvFour, 32B) → donor FH1 (cvFive, 28B)
  #   crossDown : working FH1 (cvFive, 28B) → donor FM4 (cvFour, 32B)
  let crossUp = (srcVer == cvFour and donVer == cvFive)
  let crossDown = (srcVer == cvFive and donVer == cvFour)

  # Build the forced vertex-pool blob + section transform for one pool,
  # in priority order:
  #   1. cross-version stride conversion (32↔28) of the source pool when
  #      donor/source formats differ → `basePool`.
  #   2. if a glTF doc is supplied AND the named mesh's matching pool has
  #      the same vertex count, overwrite basePool's POSITIONS from the
  #      glTF (UV/quat/extra ride through by index) and return the
  #      recomputed bbox as the section transform.
  #   3. otherwise: a forced blob only when a stride conversion happened;
  #      same-stride / no-glTF returns none so the builder copies the
  #      source pool verbatim (today's behaviour). The source's 36-byte
  #      transform is always returned so bounds transfer as before.
  proc forcedFor(srcPool: seq[byte], srcStride: int, meshName: string,
                 wantLod0: bool, srcXform: seq[byte]):
                 tuple[blob: Option[seq[byte]]; size: Option[uint32];
                       xform: Option[seq[byte]]] =
    let dstStride = (if crossUp: Fh1VertexStride
                     elif crossDown: Fm4VertexStride
                     else: srcStride)
    let needConv = (srcStride == 32 and dstStride == 28) or
                   (srcStride == 28 and dstStride == 32)
    let basePool =
      if needConv and srcStride == 32: fm4PoolToFh1(srcPool)
      elif needConv: fh1PoolToFm4(srcPool)
      else: srcPool
    let poolStride = if needConv: dstStride else: srcStride
    if gltfDoc.isSome and poolStride > 0 and basePool.len mod poolStride == 0:
      let sp = gltfDoc.get.sectionPositions(meshName, wantLod0)
      if sp.found and sp.pos.len div 3 == basePool.len div poolStride:
        # Section offset = first 3 BE floats of the source transform; the
        # glTF encode keeps it so the part stays at the source's placement
        # and re-quantizes into the pool's native range (correct scale).
        var rdo = newBEReader(srcXform)
        let srcOffset = [rdo.f32(), rdo.f32(), rdo.f32()]
        let enc = encodePoolPositions(sp.pos, basePool, poolStride, srcOffset)
        return (some(enc.pool), some(uint32(poolStride)), some(enc.transform9))
    if needConv:
      return (some(basePool), some(uint32(dstStride)), some(srcXform))
    return (none(seq[byte]), none(uint32), some(srcXform))

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
        newSecs.add(donorData[prev.endPos ..< donSec.start])
        inc gapsPreserved

    let donorSecBytes = donorData[donSec.start ..< donSec.endPos]

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
        # Carry the working car's 9 part-bound floats (offset.xyz +
        # targetMin.xyz + targetMax.xyz) into the rebuilt section. Without
        # this, the donor's bounds drive the spos→world decode
        # (`CalculateBoundTargetValue`) and working vertices render at
        # donor-car scale. When the glTF path is active, forcedFor
        # substitutes the bbox it recomputed from the glTF positions.
        let srcPool = sourceData[srcSec.lodVerticesStart ..< srcSec.lodVerticesEnd]
        let srcXformBytes = sourceData[srcSec.transformPos ..< srcSec.transformPos + 36]
        let ff = forcedFor(srcPool, int(srcSec.lodVerticesSize),
                           donSec.name, wantLod0 = false, srcXformBytes)
        let r = buildSectionConvertedToDonorLodOnDonorTemplate(
          donorData, donSec, sourceData, srcSec,
          workingLod = 1'i32, donorLod = 1'i32,
          renameMap = renames, allowedSubparts = allowed,
          upconvertIndices = true, padToDonorVpool = false,
          forcedWorkingVertexBlob = ff.blob,
          forcedNewVertexSize = ff.size,
          upconvertSubsectionsCvFourToCvFive = crossUp,
          downconvertSubsectionsCvFiveToCvFour = crossDown,
          workingTransform9 = ff.xform)

        # Per-section validation: reparse the rebuilt bytes against the
        # target version. Reject on raise, on byte-count mismatch (parser
        # consumed a different region than the splice produced), or on
        # vertex/subsection-count drift.
        let chk = tryParseSection(r.bytes, donVer)
        var srcLodSubcount = 0
        # Match the builder's new lod-selection rule (builders.nim, sel
        # filter): LOD pool serves all subsections at lod >= 1.
        for ss in srcSec.subsections:
          if ss.lod >= 1'i32: inc srcLodSubcount
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
        if ok and crossUp and chk.info.lodVerticesSize != 28'u32: ok = false
        if ok and crossDown and chk.info.lodVerticesSize != 32'u32: ok = false
        if ok and chk.info.subsections.len != srcLodSubcount: ok = false
        # LOD0 pool unchanged — must still match donor's counts.
        if ok and chk.info.lod0VerticesCount != donSec.lod0VerticesCount: ok = false
        if ok and chk.info.lod0VerticesSize != donSec.lod0VerticesSize: ok = false
        if ok:
          thisSecBytes = r.bytes
          thisSpliced = true
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
      except CatchableError:
        when TranscodeTrace:
          stderr.writeLine "    [splice] '" & donSec.name &
            "' raise: " & getCurrentExceptionMsg()
        thisSecBytes = donorSecBytes
    elif donSec.lod0VerticesCount > 0'i32 and srcSec.lod0VerticesCount > 0'i32:
      # LOD0-only section (lod0/cockpit body sections — visible in
      # autoshow / close camera). Today's behavior with the LOD-only
      # splice gate above was donor verbatim → autoshow showed donor's
      # body. Splice the working car's LOD0 pool onto the donor's section
      # template; re-stride 32→28 (crossUp) or 28→32 (crossDown) the same
      # way the LOD path does. The builder regenerates the post-pool 4B/v
      # stream with zero bytes of length workingLod0VCount*4 so the tail
      # length matches.
      try:
        let srcPool = sourceData[srcSec.lod0VerticesStart ..< srcSec.lod0VerticesEnd]
        let srcXformBytes = sourceData[srcSec.transformPos ..< srcSec.transformPos + 36]
        let ff = forcedFor(srcPool, int(srcSec.lod0VerticesSize),
                           donSec.name, wantLod0 = true, srcXformBytes)
        let r = buildSectionConvertedToDonorLodOnDonorTemplate(
          donorData, donSec, sourceData, srcSec,
          workingLod = 0'i32, donorLod = 0'i32,
          renameMap = renames, allowedSubparts = allowed,
          upconvertIndices = true, padToDonorVpool = false,
          forcedWorkingVertexBlob = ff.blob,
          forcedNewVertexSize = ff.size,
          upconvertSubsectionsCvFourToCvFive = crossUp,
          downconvertSubsectionsCvFiveToCvFour = crossDown,
          workingTransform9 = ff.xform)

        let chk = tryParseSection(r.bytes, donVer)
        var srcLod0Subcount = 0
        for ss in srcSec.subsections:
          if ss.lod == 0'i32: inc srcLod0Subcount
        var ok = chk.ok and chk.consumed > 0 and
                 chk.consumed >= r.bytes.len - 8 and
                 chk.consumed <= r.bytes.len
        if ok and chk.info.lod0VerticesCount != srcSec.lod0VerticesCount: ok = false
        if ok and crossUp and chk.info.lod0VerticesSize != 28'u32: ok = false
        if ok and crossDown and chk.info.lod0VerticesSize != 32'u32: ok = false
        if ok and chk.info.subsections.len != srcLod0Subcount: ok = false
        # LOD pool unchanged — must still match donor's counts (= 0 here).
        if ok and chk.info.lodVerticesCount != donSec.lodVerticesCount: ok = false
        if ok:
          thisSecBytes = r.bytes
          thisSpliced = true
          inc lod0Spliced
        else:
          when TranscodeTrace:
            stderr.writeLine "    [splice-lod0] '" & donSec.name &
              "' validation reject: parseOk=" & $chk.ok &
              " consumed=" & $chk.consumed & "/" & $r.bytes.len &
              " lod0Vc(splice)=" & $chk.info.lod0VerticesCount &
              " lod0Vc(src)=" & $srcSec.lod0VerticesCount &
              " lod0Vs(splice)=" & $chk.info.lod0VerticesSize &
              " subs(splice)=" & $chk.info.subsections.len &
              " subs(srcLod0)=" & $srcLod0Subcount
      except CatchableError:
        when TranscodeTrace:
          stderr.writeLine "    [splice-lod0] '" & donSec.name &
            "' raise: " & getCurrentExceptionMsg()
        thisSecBytes = donorSecBytes
    else:
      when TranscodeTrace:
        stderr.writeLine "    [splice] '" & donSec.name &
          "' skip: lodVc(don)=" & $donSec.lodVerticesCount &
          " lodVc(src)=" & $srcSec.lodVerticesCount &
          " lod0Vc(don)=" & $donSec.lod0VerticesCount &
          " lod0Vc(src)=" & $srcSec.lod0VerticesCount

    if thisSpliced: inc spliced
    else: inc fallback
    newSecs.add(thisSecBytes)

  var outLen = preBytes.len + postBytes.len
  for s in newSecs: outLen += s.len
  result.bytes = newSeqOfCap[byte](outLen)
  result.bytes.add(preBytes)
  for s in newSecs: result.bytes.add(s)
  result.bytes.add(postBytes)
  result.spliced = spliced
  result.fallback = fallback
  result.gapsPreserved = gapsPreserved
  result.lod0Spliced = lod0Spliced

# ---- entry point ----

proc transcodeCarbin*(sourceData, donorData: openArray[byte],
                      targetProfile: GameProfile,
                      mode: TranscodeMode = tmDonorVerbatim,
                      options: TranscodeOptions = defaultTranscodeOptions(),
                      gltfDoc: Option[GltfDoc] = none(GltfDoc)
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
    let copy = @donorData
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
                          srcVer, donVer, gltfDoc)
    let report = TranscodeReport(
      mode: tmHybridSplice,
      sourceVersion: srcVer, sourceTypeId: srcInfo.typeId,
      sourceSections: srcInfo.sections.len,
      donorVersion: donVer, donorTypeId: donInfo.typeId,
      donorSections: donInfo.sections.len,
      sectionsSpliced: r.spliced, sectionsFallback: r.fallback,
      gapsPreserved: r.gapsPreserved,
      lod0Spliced: r.lod0Spliced,
      note: (if gltfDoc.isSome:
               "v1: per-section splice, POSITIONS from glTF, donor-fallback"
             else: "v1: per-section splice with donor-fallback on failure"))
    result = (r.bytes, report)

proc transcodeCarbinFromGltf*(sourceData, donorData: openArray[byte],
                              targetProfile: GameProfile,
                              gltfPath: string,
                              options: TranscodeOptions = defaultTranscodeOptions()
                             ): tuple[bytes: seq[byte]; report: TranscodeReport] =
  ## glTF-sourced geometry export. Identical to `transcodeCarbin` with
  ## `mode = tmHybridSplice`, except each section's vertex POSITIONS come
  ## from the working/ glTF at `gltfPath` (matched by mesh name == section
  ## name). The source carbin still supplies subsection indices/headers,
  ## damage tables, and per-vertex UV/tangent/extra bytes (Phase 1, matched
  ## topology); the donor still supplies the section scaffold. Sections
  ## whose mesh/pool is absent from the glTF, or whose vertex count differs,
  ## transparently fall back to the binary-splice path.
  let doc = loadGltfDoc(gltfPath)
  transcodeCarbin(sourceData, donorData, targetProfile,
                  mode = tmHybridSplice, options = options,
                  gltfDoc = some(doc))

proc passthroughCarbin*(donorData: openArray[byte]): seq[byte] =
  ## For carbin slots the transcode never touches: stripped, caliper /
  ## rotor LOD0s, and the lod0 / cockpit special carbins (those need
  ## the post-pool stream which we don't synthesize yet).
  @donorData
