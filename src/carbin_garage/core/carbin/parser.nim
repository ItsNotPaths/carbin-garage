## Forza carbin structural parser. Port of probe/reference/fm4carbin/parser.py
## with a Phase-2a extension for TypeId 5 (FH1).
##
## Format families:
##   - cvFour (FM4):  TypeIds 1 / 2 / 3, header skip 0x398 bytes after typeId.
##   - cvFive (FH1):  TypeId 5, header skip 0x4DC bytes (= 0x398 + 0x144).
##                    Body parse-order is identical to FM4 — verified by
##                    matching the first 32 post-header bytes in real cars
##                    (docs/FH1_CARBIN_TYPEID5.md §"Body").
## TypeId 0 (stripped/downlevel) and FH2/FM2/FM3 stubs are still future work.

import ../be
import ./model

proc getVersion*(data: openArray[byte]): CarbinVersion =
  if data.len <= 512:
    return cvUnknown
  var r = newBEReader(data)
  r.seek(0)
  let first = r.u32()
  let second = r.u32()
  # FH1 family detection. TypeId 5 main-family carbins are obviously FH1.
  # FH1 TypeId 1 (caliper/rotor) carbins distinguish themselves from
  # FM4's TypeId 1 by `second == 0x11` (FM4 uses 0x10). Sections in
  # those carbins still use the cvFive layout (version=3, +8 after
  # lodVSize, +4 in subsections, expanded tail).
  if first == 5: return cvFive
  if first == 1 and second == 0x11: return cvFive
  r.seek(0x70); let f3 = r.u32()
  r.seek(0x104); let f2 = r.u32()
  r.seek(0x154); let f4 = r.u32()
  if (first == 1 and second == 0x2CA) or (first == 2 and f2 == 0x2CA):
    return cvTwo
  if (first == 1 and second == 0x10) or (first == 2 and f4 == 0x10) or (first == 3):
    return cvFour
  if (first == 2 and (second == 0 or second == 1)) or (first == 1 and f3 == 0):
    return cvThree
  return cvUnknown

proc parseSubsection(r: var BEReader, ver: CarbinVersion = cvFour): SubSectionInfo =
  let ssStart = r.tell()
  r.seek(5, 1)
  # 8 floats: per-subsection UV transform (m_UVOffsetScale). Order per
  # FM4_CARBIN_MASTER §5: XUVOffset, XUVScale, YUVOffset, YUVScale (UV0)
  # then XUV2Offset, XUV2Scale, YUV2Offset, YUV2Scale (UV1). Default
  # identity = (0, 1, 0, 1).
  let xo0 = r.f32(); let xs0 = r.f32()
  let yo0 = r.f32(); let ys0 = r.f32()
  let xo1 = r.f32(); let xs1 = r.f32()
  let yo1 = r.f32(); let ys1 = r.f32()
  r.seek(36, 1)
  let (name, nameLenPos, nameBytesEnd) = r.asciiLen32()
  let lodPos = r.tell()
  let lod = r.i32()
  let indexType = r.u32()
  r.seek(6 * 4, 1)
  r.seek(8 * 4, 1)
  if ver == cvFive:
    # FH1 subsection bumped its leading "version" or padding word: at
    # offset +0xA0 from subsection start FM4 has [u32=3] then idxCount,
    # FH1 has [u32=4][u32=0] then idxCount. Skip 8 instead of 4.
    r.seek(8, 1)
  else:
    r.seek(4, 1)
  let idxCountPos = r.tell()
  let idxCount = r.i32()
  let idxSizePos = r.tell()
  let idxSize = r.i32()
  let idxDataStart = r.tell()
  # Bounds-check before the mul: corrupt parses can yield huge values
  # that overflow int (Defects aren't caught by try/except CatchableError).
  if idxCount < 0 or idxCount > 1_000_000 or
     (idxSize != 2 and idxSize != 4):
    raise newException(ValueError, "subsection idxCount/idxSize insane")
  r.seek(int(idxCount) * int(idxSize), 1)
  let idxDataEnd = r.tell()
  let afterIdxPos = idxDataEnd
  r.seek(4, 1)
  let ssEnd = r.tell()
  result = SubSectionInfo(
    name: name, lod: lod, start: ssStart, endPos: ssEnd,
    idxCount: idxCount, idxSize: idxSize, indexType: indexType,
    idxCountPos: idxCountPos, idxSizePos: idxSizePos,
    idxDataStart: idxDataStart, idxDataEnd: idxDataEnd, afterIdxPos: afterIdxPos,
    nameLenPos: nameLenPos, nameBytesEnd: nameBytesEnd, lodPos: lodPos,
    uvXScale:  xs0, uvYScale:  ys0, uvXOffset:  xo0, uvYOffset:  yo0,
    uv1XScale: xs1, uv1YScale: ys1, uv1XOffset: xo1, uv1YOffset: yo1
  )

proc parseSection(r: var BEReader, index: int, ver: CarbinVersion = cvFour): SectionInfo =
  let secStart = r.tell()
  var unk = r.u32()
  var hasUnk = true
  if unk != 2 and unk != 5:
    r.seek(-4, 1)
    unk = uint32.high  # sentinel; matches Python's -1 unset
    hasUnk = false

  let transformPos = r.tell()
  r.seek(9 * 4, 1)

  r.seek(28, 1)
  let permCount = r.u32()
  if permCount > 100_000'u32:
    raise newException(ValueError, "section permCount insane")
  r.seek(int(permCount) * 16, 1)
  r.seek(4, 1)
  let cnt2 = r.u32()
  if cnt2 > 1_000_000'u32:
    raise newException(ValueError, "section cnt2 insane")
  r.seek(int(cnt2) * 2, 1)
  r.seek(12, 1)

  let (name, nameLenPos, nameBytesEnd) = r.asciiLen8()
  r.seek(4, 1)

  let lodVertexCountPos = r.tell()
  let lodVCount = r.u32()
  let lodVertexSizePos = r.tell()
  let lodVSize = r.u32()
  if lodVCount > 1_000_000'u32 or lodVSize > 256'u32:
    raise newException(ValueError, "section lodVCount/lodVSize insane")
  if ver == cvFive:
    # FH1 sections have m_NumBoneWeights (u32) between lodVSize and the
    # LOD pool. If m_NumBoneWeights > 0, an additional perSectionId u32
    # follows (random per section). Caliper / rotor sections have
    # m_NumBoneWeights = 0 → no perSectionId. Main / lod0 / cockpit
    # sections have m_NumBoneWeights = 1 → perSectionId present.
    # Master docs §"version >= 3"; cross-verified by the section diff
    # probe (256 paired sections).
    let mNumBoneWeights = r.u32()
    if mNumBoneWeights != 0'u32:
      r.seek(4, 1)
  let lodVerticesStart = r.tell()
  r.seek(int(lodVCount) * int(lodVSize), 1)
  let lodVerticesEnd = r.tell()

  r.seek(4, 1)
  let subpartCountPos = r.tell()
  let subpartCount = r.u32()
  let subsectionsStart = r.tell()

  var subsections: seq[SubSectionInfo] = @[]
  for _ in 0 ..< int(subpartCount):
    subsections.add(parseSubsection(r, ver))
  let subsectionsEnd = r.tell()

  r.seek(4, 1)
  let vertexCountPos = r.tell()
  let lod0VCount = r.i32()
  let vertexSizePos = r.tell()
  let lod0VSize = r.u32()
  if lod0VCount < 0 or lod0VCount > 1_000_000 or lod0VSize > 256'u32:
    raise newException(ValueError, "section lod0V* insane")
  if ver == cvFive and lod0VCount > 0 and lod0VSize > 0:
    # FH1 has a per-pool m_NumBoneWeights (u32) + optional perSectionId
    # (u32 if m_NumBoneWeights != 0) block BEFORE the LOD0 pool, just
    # like before the LOD pool. Body sections quietly get this right
    # because their LOD pool absorbs the offset; caliper / rotor
    # sections (no LOD pool, only LOD0) need explicit handling here or
    # the LOD0 vertex decode reads 8 bytes of bone-weight data as the
    # first vertex's pos.
    let mNumBoneWeights0 = r.u32()
    if mNumBoneWeights0 != 0'u32:
      r.seek(4, 1)
  let lod0VerticesStart = r.tell()
  if lod0VCount > 0 and lod0VSize > 0:
    r.seek(int(lod0VCount) * int(lod0VSize), 1)
  let lod0VerticesEnd = r.tell()
  let tailStart = r.tell()

  if ver == cvFive:
    # FH1 tail layout, RE'd in docs/FH1_CARBIN_TYPEID5.md §6:
    #   [13 init][a u32][b u32][4 reserved=1][a*b table][4 mid-skip]
    #   [c u32][d u32][c*d table][optional per-vertex 4-byte stream
    #   for lod0/cockpit carbins][trailing 4..8 bytes]
    #
    # In FH1 lod0 / cockpit carbins, after the c*d table comes an
    # additional `lod0VCount * 4` bytes of per-vertex data — packed
    # signed int16 pairs (high bytes 0xfe/0xff/0x00/0x01) that look
    # like D3DDECLTYPE_SHORT2N normals or DEC3N tangent space. Main
    # carbin sections don't carry it. Detect by trying both with and
    # without the extra stream and picking whichever lands on a valid
    # next-section marker.
    r.seek(13, 1)
    let a = r.u32(); let b = r.u32()
    if a > 1_000_000'u32 or b > 256'u32:
      raise newException(ValueError, "section tail a/b insane")
    r.seek(4, 1)
    r.seek(int(a) * int(b), 1)
    r.seek(4, 1)
    let c = r.u32(); let d = r.u32()
    if c > 1_000_000'u32 or d > 256'u32:
      raise newException(ValueError, "section tail c/d insane")
    r.seek(int(c) * int(d), 1)
    let probeStart = r.tell()
    let extraStream = int(lod0VCount) * 4
    var snapped = false
    # Prefer WITH-stream candidates over without-stream ones — vertex
    # noise inside the LOD0 pool can fluke a `[0 0 0 5][9 small floats]`
    # at the no-stream offset, but matching at the with-stream offset
    # can't happen without the stream actually being present.
    for extra in [extraStream, 0]:
      for tryOff in [0, 4, 8]:
        let k = probeStart + extra + tryOff
        if k + 40 > r.data.len: break
        if r.data[k] == 0 and r.data[k+1] == 0 and r.data[k+2] == 0 and r.data[k+3] == 5:
          var rr = newBEReader(r.data)
          rr.seek(k + 4)
          var floats: array[9, float32]
          for j in 0 .. 8: floats[j] = rr.f32()
          var sane = 0
          for f in floats:
            if abs(f) < 100.0'f32: inc sane
          if sane == 9 and floats[3] <= floats[6] + 1e-3'f32:
            r.seek(k); snapped = true; break
      if snapped: break
    if not snapped:
      # No marker found ahead. If lod0VCount > 0, this is likely the
      # last section in a lod0/cockpit carbin — skip the extra stream
      # so the parser's nominal sec.end lands at the file footer, not
      # at the start of the per-vertex stream.
      if lod0VCount > 0'i32:
        r.seek(extraStream, 1)
      else:
        r.seek(4, 1)
  else:
    r.seek(9, 1)
    let a = r.u32(); let b = r.u32()
    r.seek(int(a) * int(b), 1)
    r.seek(4, 1)
    let c = r.u32(); let d = r.u32()
    r.seek(int(c) * int(d), 1)

  let secEnd = r.tell()

  result = SectionInfo(
    name: name, index: index, start: secStart, endPos: secEnd,
    unkType: cast[int32](unk), hasUnkType: hasUnk,
    transformPos: transformPos,
    lodVerticesCount: lodVCount, lodVerticesSize: lodVSize,
    lodVerticesStart: lodVerticesStart, lodVerticesEnd: lodVerticesEnd,
    lod0VerticesCount: lod0VCount, lod0VerticesSize: lod0VSize,
    lod0VerticesStart: lod0VerticesStart, lod0VerticesEnd: lod0VerticesEnd,
    subsections: subsections,
    nameLenPos: nameLenPos, nameBytesEnd: nameBytesEnd,
    lodVertexCountPos: lodVertexCountPos, lodVertexSizePos: lodVertexSizePos,
    subpartCountPos: subpartCountPos,
    subsectionsStart: subsectionsStart, subsectionsEnd: subsectionsEnd,
    vertexCountPos: vertexCountPos, vertexSizePos: vertexSizePos,
    tailStart: tailStart
  )

proc tryParseSection*(data: openArray[byte], ver: CarbinVersion):
                      tuple[ok: bool; info: SectionInfo; consumed: int] =
  ## Trial-parse a single section starting at `data[0]`. Returns ok=false
  ## on any parse failure (ValueError / IndexDefect / overflow). Used by
  ## the transcode splice path: per-section reparse the rebuilt bytes;
  ## fall back to donor verbatim when the splice produced something the
  ## live parser can't read.
  ##
  ## `consumed` is the byte length of the parsed section (= parser's
  ## `secEnd - secStart`); compare to the section's expected `endPos -
  ## start` to detect tail-marker mismatch even when the parse runs to
  ## completion.
  var r = newBEReader(data)
  try:
    let info = parseSection(r, 0, ver)
    result = (true, info, r.tell())
  except CatchableError:
    result = (false, SectionInfo(), 0)

proc parseFm4Carbin*(data: openArray[byte]): CarbinInfo =
  let ver = getVersion(data)
  # Accept cvThree as well — some FH1 per-corner carbins (TypeId 1) trip
  # the cvThree detection heuristic (first==1, f3==0). The body parser
  # branches on typeId not on cvVersion, so this is safe.
  if ver != cvFour and ver != cvFive and ver != cvThree:
    raise newException(ValueError,
      "Unsupported carbin version: " & $ver & " (only FM3/FM4/FH1 are wired in)")

  var r = newBEReader(data)
  let typeId = r.u32()

  if typeId == 1:
    r.seek(r.tell() + 0x35C)
    let unk = r.u32()
    r.seek(int(unk) * 4, 1)
    r.seek(8, 1)
  elif typeId == 2:
    r.seek(r.tell() + 0x15C)
    let unk1 = r.u32()
    r.seek(4, 1)
    r.seek(int(unk1) * 0x8C, 1)
    r.seek(0x340, 1)
    let unkCount = r.u32() * 2
    for _ in 0 ..< int(unkCount):
      let skip = r.u32()
      r.seek(int(skip) * 4, 1)
    r.seek(4, 1)
  elif typeId == 3:
    r.seek(r.tell() + 0x398)
    let unkCount = r.u32() * 2
    for _ in 0 ..< int(unkCount):
      let skip = r.u32()
      r.seek(int(skip) * 4, 1)
    r.seek(4, 1)
  elif typeId == 5:
    # FH1 TypeId 5: prelude was reformatted, not just shifted — see
    # docs/FH1_CARBIN_TYPEID5.md §"The expanded middle". The FM4
    # TypeId 2 prelude shape works on some FH1 cars with a +0x144 shift
    # but not all. We instead scan the body for a partCount candidate:
    # `[u32 in 1..255][u32 in {2,5}]` brackets the partCount and the
    # first section's marker. Multiple candidates exist; the real one
    # is the one whose section parse runs to completion. The
    # candidate-search happens below in the calling code.
    discard  # leave cursor at typeId+4; the FH1 fallback runs next

  var partCount: uint32
  var partCountPos: int
  var sections: seq[SectionInfo] = @[]
  if typeId == 5:
    # Walk the file looking for [small partCount][section marker] pairs;
    # for each candidate, run the full section parse and remember the
    # candidate that yielded the most sections. This is robust because
    # parseSection raises on misalignment, so wrong candidates fail fast.
    sections = @[]
    var bestSections: seq[SectionInfo] = @[]
    var bestPC: uint32 = 0
    var bestPos = -1
    let scanLimit = min(data.len - 8, 0x10000)
    var i = 0x4DC  # body start; partCount can't precede this
    while i < scanLimit:
      let pc = uint32((int(data[i]) shl 24) or (int(data[i+1]) shl 16) or
                      (int(data[i+2]) shl 8) or int(data[i+3]))
      let marker = uint32((int(data[i+4]) shl 24) or (int(data[i+5]) shl 16) or
                          (int(data[i+6]) shl 8) or int(data[i+7]))
      if pc >= 1'u32 and pc <= 255'u32 and (marker == 2'u32 or marker == 5'u32):
        var rr = newBEReader(data)
        rr.seek(i + 4)
        var cand: seq[SectionInfo] = @[]
        var ok = true
        for k in 0 ..< int(pc):
          let beforeAttempt = rr.tell()
          try:
            cand.add(parseSection(rr, k, cvFive))
          except CatchableError:
            # A section's bytes hit a layout quirk we haven't RE'd. Skip
            # forward to the next plausible section marker (`[u32=5][9
            # sane floats]`) and resume. Bound the scan so we don't burn
            # the rest of the file on a misalignment that produces no
            # more matches.
            rr.seek(beforeAttempt)
            let scanEnd = min(data.len - 40, beforeAttempt + 0x40000)
            var found = -1
            var s = beforeAttempt + 4   # skip past the byte that just failed
            while s <= scanEnd:
              if data[s] == 0 and data[s+1] == 0 and data[s+2] == 0 and data[s+3] == 5:
                var rr2 = newBEReader(data)
                rr2.seek(s + 4)
                var floats: array[9, float32]
                for j in 0 .. 8: floats[j] = rr2.f32()
                var sane = 0
                for f in floats:
                  if abs(f) < 100.0'f32: inc sane
                if sane == 9 and floats[3] <= floats[6] + 1e-3'f32:
                  found = s; break
              inc s
            if found < 0:
              ok = false; break
            rr.seek(found)
            # don't add a placeholder; just try the next section index here
            continue
        # Pick the candidate that parses the most sections. The real
        # partCount is the one whose first section parses cleanly; fake
        # matches almost always fail on section[0] because the bytes
        # right after a stray `[small_int][2|5]` aren't a valid 9-float
        # transform. Tiebreak by larger declared pc to bias toward real
        # main carbins (pc in the 20s..40s) over single-section stubs.
        if cand.len > bestSections.len or
           (cand.len == bestSections.len and pc > bestPC):
          bestSections = cand
          bestPC = pc
          bestPos = i
        discard ok
      i += 4
    if bestPos < 0:
      raise newException(ValueError,
        "TypeId 5 partCount candidate not found in scan")
    partCount = bestPC
    partCountPos = bestPos
    sections = bestSections
  else:
    partCountPos = r.tell()
    partCount = r.u32()
    for i in 0 ..< int(partCount):
      try:
        sections.add(parseSection(r, i, ver))
      except CatchableError:
        break

  let sectionsEnd = if sections.len > 0: sections[^1].endPos else: partCountPos + 4
  result = CarbinInfo(
    version: ver,
    typeId: typeId,
    partCountDeclared: partCount,
    partCountPos: partCountPos,
    sections: sections,
    sectionsEnd: sectionsEnd
  )
