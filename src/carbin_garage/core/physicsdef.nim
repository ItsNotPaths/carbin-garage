## FH1 `physicsdefinition.bin` parser + emitter — round-trip safe.
##
## Per-car file (~1.5–2.6 KB), big-endian. We name the fields we
## understand (header + both inertia tensors + AABB triple) and
## preserve everything else as opaque byte blobs so a parse → emit
## cycle is byte-identical even when we haven't labelled every field.
##
## Layout (offsets BE), cross-checked against the FH1 recomp's
## `CPhysicsDefinition::Serialize` (rexglue/run-fh1/out-v4 fh1_recomp.86.cpp:34271)
## and `CPhysicsDefinitionList::Serialize` (same file, 39076):
##
##   +0x00  u32  fileVersion              (always 1 in samples)
##   +0x04  u32  defVersion               (always 13 → enum Version14)
##   +0x08  u32  defType                  (always 1 = Vehicle)
##   +0x0C  f32  epsilon                  (always 0.01)
##   +0x10  9×f32  inverseInertia          (Forza struct name:
##                                          m_InertiaTensorLocalSpace —
##                                          stores J⁻¹, the unit-mass
##                                          inverse, which is the runtime
##                                          primary tensor for ω̇=J⁻¹·τ)
##   +0x34  9×f32  forwardInertia          (Forza struct name:
##                                          m_InverseInertiaTensorLocalSpace —
##                                          stores J, the mass-weighted
##                                          inertia tensor in kg·m²)
##                                          NB: our names match physics
##                                          convention. Forza's struct
##                                          names are inverted relative
##                                          to physics — the small-magnitude
##                                          tensor (~0.005-0.17) is what
##                                          they call "InertiaTensor" and
##                                          the large one (~5-240) is
##                                          their "InverseInertiaTensor".
##   +0x58  3×f32  aabbHalfExtents         (m_AabbHalfExtents)
##   +0x64  f32   boundingRadius           (m_BoundingRadius — collision
##                                          bounding-sphere radius in m)
##   +0x68  3×f32  physToGraphicsOffset    (m_PhysicsToGraphicsOffsetLocalSpace —
##                                          translation from physics CoM
##                                          to graphics model origin, m)
##   +0x74  u32   numChildDefinitions      (m_NumChildDefinitions — always 0
##                                          for cars; nonzero would mean
##                                          attached child colliders)
##   +0x78  3×f32  aabbCentreOffset        (m_AabbCentreOffset — AABB centre
##                                          relative to physics origin, m;
##                                          only present when defVersion >= 12)
##   +0x84  var   shapesAndChildren       (opaque — m_NumCollisionShapes
##                                          followed by per-shape data,
##                                          handled by SerializeShapes /
##                                          SerializeChildDefinitions in
##                                          the engine; we round-trip
##                                          verbatim)
##   last10 raw   footer                   (always
##                                          00 00 00 01 00 00 ff ff ff ff)
##
## Mass: `CPhysicsDefinition` has a `m_MassGameUnits` field at struct
## offset 0x8C, and Serialize emits a vtable[180] call for it. But mass
## is empirically NOT present at any byte position in defVersion=13 bins
## across our paired samples — most plausible explanation is that the
## stream's vtable[180] is internally version-gated and skips for v13,
## with mass recomputed from the inertia tensor or hull volume at load.
## Bottom line: there is no on-disk mass scalar to parse.
##
## Decision (docs/FH1_PHYSICSDEFINITION_BIN.md §"Donor-bin strategy",
## locked 2026-05-01): we never SYNTHESISE a bin from glTF/SQL — that
## stays as donor passthrough. This module enables the round-trip
## parse → mutate-named-fields → re-emit workflow, which is a different
## thing: starts from a real bin (the donor), tweaks fields we
## understand (mass / inertia / bounds), keeps unknown regions
## verbatim. Useful for stats display, donor-vs-source comparison, and
## targeted edits without re-baking from scratch.

import std/[json, strutils]
import ./be

type
  PhysicsDefinitionType* = enum
    ## Mirrors `PhysicsDefinitionType::Enum` (enums.h:27877).
    pdtCollidableObject = 0
    pdtVehicle = 1

  Mat3x3* = array[9, float32]   # row-major
  Vec3*   = array[3, float32]

  PhysicsDefinition* = object
    ## Round-trip-safe record. Named fields cover everything labelled in
    ## CPhysicsDefinition::Serialize; the variable-length collision
    ## shape + child-definition list past the fixed header is preserved
    ## as `shapesAndChildren` opaque bytes.
    fileVersion*: uint32
    defVersion*: uint32
    defType*: uint32
    epsilon*: float32
    inverseInertia*: Mat3x3          # 0x10 — Forza's m_InertiaTensorLocalSpace
    forwardInertia*: Mat3x3          # 0x34 — Forza's m_InverseInertiaTensorLocalSpace
    aabbHalfExtents*: Vec3           # 0x58 — m_AabbHalfExtents
    boundingRadius*: float32         # 0x64 — m_BoundingRadius
    physToGraphicsOffset*: Vec3      # 0x68 — m_PhysicsToGraphicsOffsetLocalSpace
    numChildDefinitions*: uint32     # 0x74 — m_NumChildDefinitions
    aabbCentreOffset*: Vec3          # 0x78 — m_AabbCentreOffset (defVersion >= 12)
    shapesAndChildren*: seq[byte]    # 0x84..(end-FooterLen) — variable
    footer*: array[10, byte]         # last 10 — constant across samples

const
  ExpectedFileVersion* = 1'u32
  ExpectedDefVersion*  = 13'u32        # PhysicsDefinitionVersion::Version14
  ExpectedEpsilon*     = 0.01'f32
  ExpectedFooter*: array[10, byte] = [
    0x00'u8, 0x00, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF
  ]
  AabbCentreOffsetMinVersion* = 12'u32 ## defVersion gate for AabbCentreOffset
  HeaderEnd*           = 0x84          ## end of fixed header when defVersion >= 12
  HeaderEndPreV12*     = 0x78          ## end of fixed header when defVersion < 12
  FooterLen*           = 10
  MinFileLen*          = HeaderEndPreV12 + FooterLen ## 0x82 = 130 B floor

proc isSym3*(m: Mat3x3): bool =
  ## Symmetric 3×3 check. Both inertia tensors are dense-symmetric in
  ## every sample we've seen.
  template close(a, b: float32): bool =
    abs(a - b) <= 1.0e-3'f32 * max(1.0'f32, abs(a))
  close(m[1], m[3]) and close(m[2], m[6]) and close(m[5], m[7])

proc readMat3(r: var BEReader): Mat3x3 =
  for i in 0 .. 8: result[i] = r.f32()

proc readVec3(r: var BEReader): Vec3 =
  for i in 0 .. 2: result[i] = r.f32()

# ---------- parse ----------

proc parsePhysicsDef*(data: openArray[byte]): PhysicsDefinition =
  ## Round-trip-safe parse. Raises `ValueError` only on truncation /
  ## obvious header corruption; anything we don't recognise inside the
  ## fixed header is preserved verbatim and surfaced via the round-trip
  ## (caller can compare against `Expected*` constants).
  if data.len < MinFileLen:
    raise newException(ValueError,
      "physicsdef: file too small (" & $data.len &
      " B, need at least " & $MinFileLen & ")")

  var r = newBEReader(data)
  result.fileVersion = r.u32()
  result.defVersion  = r.u32()
  result.defType     = r.u32()
  result.epsilon     = r.f32()

  result.inverseInertia       = readMat3(r)
  result.forwardInertia       = readMat3(r)
  result.aabbHalfExtents      = readVec3(r)
  result.boundingRadius       = r.f32()
  result.physToGraphicsOffset = readVec3(r)
  result.numChildDefinitions  = r.u32()
  let hdrEnd =
    if result.defVersion >= AabbCentreOffsetMinVersion:
      result.aabbCentreOffset = readVec3(r)
      HeaderEnd
    else:
      HeaderEndPreV12
  doAssert r.tell() == hdrEnd

  let tailEnd = data.len - FooterLen
  if tailEnd < hdrEnd:
    raise newException(ValueError,
      "physicsdef: tail end (" & $tailEnd &
      ") precedes header end (" & $hdrEnd & ")")
  result.shapesAndChildren = newSeq[byte](tailEnd - hdrEnd)
  for i in 0 ..< result.shapesAndChildren.len:
    result.shapesAndChildren[i] = data[hdrEnd + i]

  for i in 0 ..< FooterLen:
    result.footer[i] = data[tailEnd + i]

# ---------- emit ----------

proc writeF32BE(buf: var seq[byte], v: float32) =
  let p = bePackF32(v)
  for b in p: buf.add b

proc writeU32BE(buf: var seq[byte], v: uint32) =
  let p = bePackU32(v)
  for b in p: buf.add b

proc writeMat3(buf: var seq[byte], m: Mat3x3) =
  for i in 0 .. 8: writeF32BE(buf, m[i])

proc writeVec3(buf: var seq[byte], v: Vec3) =
  for i in 0 .. 2: writeF32BE(buf, v[i])

proc emitPhysicsDef*(pd: PhysicsDefinition): seq[byte] =
  ## Pack `pd` into a byte buffer suitable for writing to disk.
  ## `parsePhysicsDef(emitPhysicsDef(parsePhysicsDef(b))) == b` MUST
  ## hold byte-for-byte for any well-formed bin in our sample set.
  let hdrEnd =
    if pd.defVersion >= AabbCentreOffsetMinVersion: HeaderEnd
    else: HeaderEndPreV12
  result = newSeqOfCap[byte](hdrEnd + pd.shapesAndChildren.len + FooterLen)
  writeU32BE(result, pd.fileVersion)
  writeU32BE(result, pd.defVersion)
  writeU32BE(result, pd.defType)
  writeF32BE(result, pd.epsilon)
  writeMat3(result, pd.inverseInertia)
  writeMat3(result, pd.forwardInertia)
  writeVec3(result, pd.aabbHalfExtents)
  writeF32BE(result, pd.boundingRadius)
  writeVec3(result, pd.physToGraphicsOffset)
  writeU32BE(result, pd.numChildDefinitions)
  if pd.defVersion >= AabbCentreOffsetMinVersion:
    writeVec3(result, pd.aabbCentreOffset)
  doAssert result.len == hdrEnd
  for b in pd.shapesAndChildren: result.add b
  for b in pd.footer: result.add b

# ---------- experimental: disable collision shapes ----------

proc disableCollisionShapes*(pd: var PhysicsDefinition) =
  ## Replace the entire shapesAndChildren region with `[0,0,0,0]` —
  ## a logically valid `m_NumCollisionShapes = 0` followed by no per-
  ## shape data. The runtime allocates zero CCollisionShape pointers
  ## and the SerializeShapes loop runs zero iterations.
  ##
  ## Confirmed 2026-05-10: car loads + drives + clips through walls,
  ## but ground collision survives via the wheel raycast system.
  ## This is the `exportHitboxes = false` consumer.
  pd.shapesAndChildren = @[0'u8, 0'u8, 0'u8, 0'u8]

# ---------- intermediate JSON format ----------

proc bytesToHex(bs: openArray[byte]): string =
  result = newStringOfCap(bs.len * 2)
  for b in bs:
    result.add toHex(int(b), 2).toLowerAscii

proc hexToBytes(s: string): seq[byte] =
  ## Accepts compact hex (`"deadbeef"`); whitespace allowed.
  var clean = newStringOfCap(s.len)
  for c in s:
    if c in {'0'..'9', 'a'..'f', 'A'..'F'}: clean.add c
  if clean.len mod 2 != 0:
    raise newException(ValueError, "physicsdef: hex string has odd length")
  result = newSeq[byte](clean.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(clean[2*i .. 2*i+1]))

proc mat3ToJson*(m: Mat3x3): JsonNode =
  result = newJArray()
  for row in 0 .. 2:
    let r = newJArray()
    for col in 0 .. 2: r.add %m[row*3 + col]
    result.add r

proc mat3FromJson*(n: JsonNode): Mat3x3 =
  if n.kind != JArray or n.len != 3:
    raise newException(ValueError, "physicsdef: mat3 must be 3 rows")
  for row in 0 .. 2:
    let r = n[row]
    if r.kind != JArray or r.len != 3:
      raise newException(ValueError, "physicsdef: mat3 row must be 3 values")
    for col in 0 .. 2:
      result[row*3 + col] = r[col].getFloat.float32

proc vec3ToJson(v: Vec3): JsonNode =
  result = newJArray()
  for i in 0 .. 2: result.add %v[i]

proc vec3FromJson(n: JsonNode): Vec3 =
  if n.kind != JArray or n.len != 3:
    raise newException(ValueError, "physicsdef: vec3 must be 3 values")
  for i in 0 .. 2:
    result[i] = n[i].getFloat.float32

proc toJson*(pd: PhysicsDefinition): JsonNode =
  ## Serialise to the editable intermediate format.
  result = %* {
    "version": {
      "file":       %pd.fileVersion,
      "definition": %pd.defVersion,
      "type":       %pd.defType
    },
    "epsilon":              %pd.epsilon,
    "inverseInertia":       mat3ToJson(pd.inverseInertia),
    "forwardInertia":       mat3ToJson(pd.forwardInertia),
    "aabbHalfExtents":      vec3ToJson(pd.aabbHalfExtents),
    "boundingRadius":       %pd.boundingRadius,
    "physToGraphicsOffset": vec3ToJson(pd.physToGraphicsOffset),
    "numChildDefinitions":  %pd.numChildDefinitions,
    "aabbCentreOffset":     vec3ToJson(pd.aabbCentreOffset),
    "shapesAndChildren":    %bytesToHex(pd.shapesAndChildren),
    "footer":               %bytesToHex(pd.footer)
  }

proc fromJson*(n: JsonNode): PhysicsDefinition =
  ## Inverse of `toJson`. Strict on `shapesAndChildren` / `footer`
  ## byte lengths because those are what guarantees byte-identical
  ## round-trip; tolerant of missing labelled fields (uses zero).
  let v = n["version"]
  result.fileVersion = uint32(v["file"].getInt)
  result.defVersion  = uint32(v["definition"].getInt)
  result.defType     = uint32(v["type"].getInt)
  result.epsilon     = n["epsilon"].getFloat.float32
  result.inverseInertia       = mat3FromJson(n["inverseInertia"])
  result.forwardInertia       = mat3FromJson(n["forwardInertia"])
  result.aabbHalfExtents      = vec3FromJson(n["aabbHalfExtents"])
  result.boundingRadius       = n["boundingRadius"].getFloat.float32
  result.physToGraphicsOffset = vec3FromJson(n["physToGraphicsOffset"])
  result.numChildDefinitions  = uint32(n["numChildDefinitions"].getInt)
  if n.hasKey("aabbCentreOffset"):
    result.aabbCentreOffset   = vec3FromJson(n["aabbCentreOffset"])

  result.shapesAndChildren = hexToBytes(n["shapesAndChildren"].getStr)

  let foot = hexToBytes(n["footer"].getStr)
  if foot.len != FooterLen:
    raise newException(ValueError,
      "physicsdef: footer must be exactly " & $FooterLen &
      " B (got " & $foot.len & ")")
  for i in 0 ..< FooterLen: result.footer[i] = foot[i]

# ---------- JSON pointer-ish lookup (used by L pane stat path mapping) ----------

proc jsonPathStep(node: JsonNode; key: string): JsonNode =
  ## Resolve `key` as either an object field name or an integer array
  ## index. Returns nil if the step doesn't exist; caller decides
  ## whether that's a hard error or just "no value yet."
  if node == nil: return nil
  case node.kind
  of JObject:
    if node.hasKey(key): return node[key]
    return nil
  of JArray:
    var idx = -1
    try: idx = parseInt(key)
    except ValueError: return nil
    if idx < 0 or idx >= node.len: return nil
    return node[idx]
  else: return nil

proc resolvePath*(root: JsonNode; path: string): JsonNode =
  ## Look up `root` at the dotted `path` (e.g. "forwardInertia.0.0").
  ## Returns nil if any step is missing. Read-only — does not allocate
  ## intermediate nodes.
  if path.len == 0: return root
  var cur = root
  for step in path.split('.'):
    cur = jsonPathStep(cur, step)
    if cur == nil: return nil
  return cur

proc setPath*(root: JsonNode; path: string; value: JsonNode) =
  ## Replace the leaf at `path` with `value`. Raises `ValueError` if
  ## any intermediate step is missing — this module doesn't grow the
  ## physicsdef.json shape implicitly because a missing key almost
  ## always means a profile/path typo, not a legitimate addition.
  if path.len == 0:
    raise newException(ValueError, "physicsdef.setPath: empty path")
  let parts = path.split('.')
  var cur = root
  for i in 0 ..< parts.len - 1:
    let nxt = jsonPathStep(cur, parts[i])
    if nxt == nil:
      raise newException(ValueError,
        "physicsdef.setPath: path " & path & " missing at step " & parts[i])
    cur = nxt
  let leafKey = parts[^1]
  case cur.kind
  of JObject: cur[leafKey] = value
  of JArray:
    var idx = -1
    try: idx = parseInt(leafKey)
    except ValueError:
      raise newException(ValueError,
        "physicsdef.setPath: array step needs int, got " & leafKey)
    if idx < 0 or idx >= cur.len:
      raise newException(ValueError,
        "physicsdef.setPath: array index " & $idx & " out of range")
    cur.elems[idx] = value
  else:
    raise newException(ValueError,
      "physicsdef.setPath: cannot index into " & $cur.kind & " at " & path)

# ---------- pretty-print ----------

proc fmtMat3*(m: Mat3x3, indent = "    "): string =
  result = ""
  for row in 0 .. 2:
    result.add indent
    for col in 0 .. 2:
      let val = m[row * 3 + col]
      result.add formatFloat(val, ffDecimal, 6).align(13)
      if col < 2: result.add "  "
    if row < 2: result.add "\n"

proc fmtVec3*(v: Vec3): string =
  "(" & formatFloat(v[0], ffDecimal, 6) & ", " &
        formatFloat(v[1], ffDecimal, 6) & ", " &
        formatFloat(v[2], ffDecimal, 6) & ")"

proc summarize*(pd: PhysicsDefinition): string =
  ## One-screen dump for the `dump-physicsdef` CLI.
  let hdrEnd =
    if pd.defVersion >= AabbCentreOffsetMinVersion: HeaderEnd
    else: HeaderEndPreV12
  let total = hdrEnd + pd.shapesAndChildren.len + FooterLen
  var s = ""
  s.add "  size:           " & $total & " B (header " & $hdrEnd &
        " + shapes " & $pd.shapesAndChildren.len &
        " + footer " & $FooterLen & ")\n"
  s.add "  fileVersion:    " & $pd.fileVersion
  if pd.fileVersion != ExpectedFileVersion:
    s.add "   ⚠ expected " & $ExpectedFileVersion
  s.add "\n  defVersion:     " & $pd.defVersion &
        " (PhysicsDefinitionVersion::Version" & $(pd.defVersion + 1) & ")"
  if pd.defVersion != ExpectedDefVersion:
    s.add "   ⚠ expected " & $ExpectedDefVersion
  let typeStr =
    if pd.defType == 0: "CollidableObject"
    elif pd.defType == 1: "Vehicle"
    else: "?"
  s.add "\n  defType:        " & $pd.defType & " (" & typeStr & ")\n"
  s.add "  epsilon:        " & formatFloat(pd.epsilon, ffDecimal, 6)
  if pd.epsilon != ExpectedEpsilon:
    s.add "   ⚠ expected " & formatFloat(ExpectedEpsilon, ffDecimal, 6)
  s.add "\n  inverseInertia (sym=" & $isSym3(pd.inverseInertia) & "):\n"
  s.add fmtMat3(pd.inverseInertia) & "\n"
  s.add "  forwardInertia (sym=" & $isSym3(pd.forwardInertia) & "):\n"
  s.add fmtMat3(pd.forwardInertia) & "\n"
  s.add "  aabbHalfExtents:        " & fmtVec3(pd.aabbHalfExtents) & "\n"
  s.add "  boundingRadius:         " & formatFloat(pd.boundingRadius, ffDecimal, 6) & " m\n"
  s.add "  physToGraphicsOffset:   " & fmtVec3(pd.physToGraphicsOffset) & "\n"
  s.add "  numChildDefinitions:    " & $pd.numChildDefinitions & "\n"
  if pd.defVersion >= AabbCentreOffsetMinVersion:
    s.add "  aabbCentreOffset:       " & fmtVec3(pd.aabbCentreOffset) & "\n"
  s.add "  shapesAndChildren (opaque, " & $pd.shapesAndChildren.len & " B)\n"
  s.add "  footer:         " & bytesToHex(pd.footer)
  if pd.footer == ExpectedFooter:
    s.add "  ✓"
  else:
    s.add "  ⚠ expected " & bytesToHex(ExpectedFooter)
  result = s
