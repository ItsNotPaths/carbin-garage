## Section transform read/patch. Port of probe/reference/fm4carbin/transform.py.
## The 0x05 marker block holds the 9-float (offset, min, max) bound transform.

import std/[math, options, algorithm]
import ../be

type
  Vec3* = array[3, float32]

  TransformCandidate* = object
    markerPos*: int    # position of 0x05 marker in section_bytes
    floatsPos*: int    # start of 9 floats (markerPos+1)
    offset*: Vec3
    left*: Vec3
    right*: Vec3
    score*: float

  SectionTransform* = object
    offset*: Vec3
    minBounds*: Vec3
    maxBounds*: Vec3
    posRel*: int       # offset to first float in section_bytes

proc sane(v: float32): bool =
  let cls = classify(v)
  result = (cls == fcNormal or cls == fcSubnormal or cls == fcZero or cls == fcNegZero) and (abs(v) < 1e6'f32)

proc read9f(buf: openArray[byte], off: int): array[9, float32] =
  var r = newBEReader(buf)
  r.seek(off)
  for i in 0 .. 8: result[i] = r.f32()

proc findTransformCandidates*(sectionBytes: openArray[byte],
                              searchLimit: int = 0x600): seq[TransformCandidate] =
  let scanLen = min(sectionBytes.len, searchLimit)
  var i = 0
  while i < scanLen:
    # find 0x05 from i within the scan window
    var p = -1
    for j in i ..< scanLen:
      if sectionBytes[j] == 0x05:
        p = j; break
    if p < 0: break
    let start = p + 1
    let endPos = start + 9 * 4
    if endPos <= sectionBytes.len:
      try:
        let vals = read9f(sectionBytes, start)
        var allSane = true
        for v in vals:
          if not sane(v): allSane = false; break
        if allSane:
          let off: Vec3 = [vals[0], vals[1], vals[2]]
          let le: Vec3  = [vals[3], vals[4], vals[5]]
          let ri: Vec3  = [vals[6], vals[7], vals[8]]
          var score = 0.0
          if le[0] <= ri[0] and le[1] <= ri[1] and le[2] <= ri[2]: score += 1.0
          if abs(le[0] + ri[0]) < 1e3 and abs(le[1] + ri[1]) < 1e3 and abs(le[2] + ri[2]) < 1e3: score += 1.0
          var anyNonzero = false
          for v in vals:
            if abs(v) > 1e-6: anyNonzero = true; break
          if anyNonzero: score += 1.0
          result.add(TransformCandidate(markerPos: p, floatsPos: start,
                     offset: off, left: le, right: ri, score: score))
      except CatchableError:
        discard
    i = p + 1
  # sort descending by score
  result.sort(proc(a, b: TransformCandidate): int =
    if a.score > b.score: -1
    elif a.score < b.score: 1
    else: 0)

proc readSectionTransform*(sectionBytes: openArray[byte],
                           prefer05: bool = true): Option[SectionTransform] =
  if prefer05:
    let cands = findTransformCandidates(sectionBytes)
    if cands.len > 0:
      let c = cands[0]
      return some(SectionTransform(offset: c.offset, minBounds: c.left,
                  maxBounds: c.right, posRel: c.floatsPos))

  # fallback heuristic
  var r = newBEReader(sectionBytes)
  try:
    let unk = r.u32()
    if unk != 2 and unk != 5:
      r.seek(-4, 1)
    let pos = r.tell()
    if pos + 9 * 4 > sectionBytes.len: return none(SectionTransform)
    let vals = read9f(sectionBytes, pos)
    for v in vals:
      if not sane(v): return none(SectionTransform)
    return some(SectionTransform(
      offset: [vals[0], vals[1], vals[2]],
      minBounds: [vals[3], vals[4], vals[5]],
      maxBounds: [vals[6], vals[7], vals[8]],
      posRel: pos))
  except CatchableError:
    return none(SectionTransform)

proc patchSectionTransform*(sectionBytes: openArray[byte],
                            offsetXyz: Option[Vec3] = none(Vec3),
                            minXyz: Option[Vec3] = none(Vec3),
                            maxXyz: Option[Vec3] = none(Vec3),
                            prefer05: bool = true): seq[byte] =
  let info = readSectionTransform(sectionBytes, prefer05)
  result = @sectionBytes
  if info.isNone: return
  let cur = info.get
  let newOff = if offsetXyz.isSome: offsetXyz.get else: cur.offset
  let newMn  = if minXyz.isSome:    minXyz.get    else: cur.minBounds
  let newMx  = if maxXyz.isSome:    maxXyz.get    else: cur.maxBounds
  var pos = cur.posRel
  for v in @[newOff[0], newOff[1], newOff[2],
             newMn[0],  newMn[1],  newMn[2],
             newMx[0],  newMx[1],  newMx[2]]:
    let packed = bePackF32(v)
    for i in 0 .. 3: result[pos + i] = packed[i]
    pos += 4

proc clampF*(x: float, lo: float = -1e6, hi: float = 1e6): float =
  let cls = classify(x)
  if cls == fcNan or cls == fcInf or cls == fcNegInf: return 0.0
  if x < lo: return lo
  if x > hi: return hi
  return x
