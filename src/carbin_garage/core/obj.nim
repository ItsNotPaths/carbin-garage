## Minimal Wavefront OBJ loader for new-part synthesis.
##
## Reads `v` / `vt` / `vn` and triangulates `f` faces (fan for n-gons),
## de-indexing each `v/vt/vn` corner into a unique interleaved vertex so
## the result maps straight onto a carbin section's shared vertex pool +
## TriList index buffer. UV/normal are optional per corner (defaults: uv
## (0,0), normal (0,1,0)). Indices are returned as a flat triangle list.

import std/[strutils, tables]

type
  ObjMesh* = object
    positions*: seq[float32]   # 3 per vertex (x,y,z)
    uvs*: seq[float32]         # 2 per vertex (u,v)
    normals*: seq[float32]     # 3 per vertex (x,y,z)
    indices*: seq[uint32]      # flat triangle list (3 per tri)

  ObjError* = object of CatchableError

proc parseIdx(tok: string, count: int): int =
  ## OBJ index: 1-based, negative = relative-from-end. Returns 0-based, or
  ## -1 when absent (empty token, e.g. "v//vn" has empty vt).
  if tok.len == 0: return -1
  var v = 0
  try: v = parseInt(tok)
  except ValueError: return -1
  if v > 0: return v - 1
  if v < 0: return count + v
  return -1

proc loadObj*(path: string): ObjMesh =
  ## Parse an OBJ file into a de-indexed triangle mesh.
  let text = readFile(path)
  var vs: seq[array[3, float32]] = @[]
  var ts: seq[array[2, float32]] = @[]
  var ns: seq[array[3, float32]] = @[]
  var corner = initTable[string, uint32]()  # "vi/ti/ni" -> output index
  var outPos: seq[float32] = @[]
  var outUv: seq[float32] = @[]
  var outNorm: seq[float32] = @[]
  var outIdx: seq[uint32] = @[]

  proc addCorner(tok: string): uint32 =
    if tok in corner: return corner[tok]
    let parts = tok.split('/')
    let vi = parseIdx(parts[0], vs.len)
    let ti = if parts.len > 1: parseIdx(parts[1], ts.len) else: -1
    let ni = if parts.len > 2: parseIdx(parts[2], ns.len) else: -1
    if vi < 0 or vi >= vs.len:
      raise newException(ObjError, "OBJ face references bad vertex: " & tok)
    let oi = uint32(outPos.len div 3)
    let p = vs[vi]
    outPos.add(p[0]); outPos.add(p[1]); outPos.add(p[2])
    if ti >= 0 and ti < ts.len:
      outUv.add(ts[ti][0]); outUv.add(ts[ti][1])
    else:
      outUv.add(0'f32); outUv.add(0'f32)
    if ni >= 0 and ni < ns.len:
      outNorm.add(ns[ni][0]); outNorm.add(ns[ni][1]); outNorm.add(ns[ni][2])
    else:
      outNorm.add(0'f32); outNorm.add(1'f32); outNorm.add(0'f32)
    corner[tok] = oi
    return oi

  for rawLine in text.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line[0] == '#': continue
    let f = line.splitWhitespace()
    if f.len == 0: continue
    case f[0]
    of "v":
      if f.len >= 4:
        vs.add([parseFloat(f[1]).float32, parseFloat(f[2]).float32, parseFloat(f[3]).float32])
    of "vt":
      if f.len >= 3:
        ts.add([parseFloat(f[1]).float32, parseFloat(f[2]).float32])
    of "vn":
      if f.len >= 4:
        ns.add([parseFloat(f[1]).float32, parseFloat(f[2]).float32, parseFloat(f[3]).float32])
    of "f":
      if f.len < 4: continue
      # Fan-triangulate corners f[1..^1].
      let c0 = addCorner(f[1])
      for k in 2 ..< f.len - 1:
        let c1 = addCorner(f[k])
        let c2 = addCorner(f[k + 1])
        outIdx.add(c0); outIdx.add(c1); outIdx.add(c2)
    else: discard

  if outPos.len == 0:
    raise newException(ObjError, "OBJ has no vertices: " & path)
  result.positions = outPos
  result.uvs = outUv
  result.normals = outNorm
  result.indices = outIdx
