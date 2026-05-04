## glTF → carbin re-emit (Stage 2 of export refactor).
##
## Strategy: donor-splice from `.archive/source.zip`. Stage 1 already
## stashes the source zip at import time — that gives us the byte-level
## ground truth for every carbin. The emitter:
##
##   1. Opens `working/<slug>/.archive/source.zip`.
##   2. Lists every entry whose name ends with `.carbin`.
##   3. For each carbin: extracts donor bytes; (TODO: compares each
##      glTF section's vertex floats against the decoded donor pool;
##      re-encodes only changed bytes) returns the bytes.
##   4. Writes `working/<slug>/geometry/<name>.carbin.regen` next to the
##      original (kept for diffing; doesn't overwrite production
##      geometry/<name>.carbin yet).
##
## Round-trip without edits: byte-equal trivially because the emitter
## returns donor bytes verbatim until edit-emission lands.
##
## Round-trip with edits: TODO — currently flagged via a warning and
## still returns donor bytes. Edit-emission requires a vertex encode
## path that matches the original game's quantizer; `core/carbin/vertex.nim`
## has `encodeVertex` but it's untested in production. Documented in
## stage2-gltf-to-carbin.md § 2.1.
##
## Stage 1 prereq guard: refuses to run if validateRoundtripExtras
## reports any missing keys (the glTF wasn't produced by Stage-1-aware
## importwc). That gate enforces forward-compat: the day edit-emission
## lands, every Stage-1 glTF will already have what it needs.

import std/[os, strutils]
import ../zip21
import ../gltf

type
  EmitReport* = object
    carbinsWritten*: int
    bytesWritten*: int64
    warnings*: seq[string]
    sectionsCompared*: int
    sectionsEdited*: int        # reserved for future edit-emission
    fellThroughToDonor*: int    # how many sections we didn't touch

proc isCarbinName(name: string): bool =
  name.toLowerAscii().endsWith(".carbin")

proc writeAllBytes(path: string, data: openArray[byte]) =
  ## Convenience: bytes → file. Mirrors importwc.nim's helper.
  var f = open(path, fmWrite)
  defer: f.close()
  if data.len > 0: discard f.writeBytes(data, 0, data.len)

proc emitCarbinRoundtrip*(donorBytes: openArray[byte],
                          gltfMeshName: string = ""): seq[byte] =
  ## Today: pure donor passthrough. Tomorrow: per-vertex compare
  ## against the named glTF mesh and splice in edited bytes.
  ##
  ## The `gltfMeshName` argument is reserved for the edit-emission
  ## path (it lets the emitter find the matching mesh in car.gltf).
  ## Currently unused — we just return donor bytes verbatim so the
  ## scaffold is real but conservative.
  result = newSeq[byte](donorBytes.len)
  for i, b in donorBytes: result[i] = b

proc exportCarbinsFromWorking*(workingDir: string,
                               outDir: string = "",
                               strict: bool = false): EmitReport =
  ## Walk every carbin in working/<slug>/.archive/source.zip, run it
  ## through emitCarbinRoundtrip, write `<name>.carbin.regen` into
  ## `outDir` (defaults to working/<slug>/geometry/).
  ##
  ## `strict`: pre-flight `validateRoundtripExtras(car.gltf)`. If any
  ## keys are missing, raise IOError with the list — Stage 2 wants
  ## Stage-1-emitted glTFs only.
  let archive = workingDir / ".archive" / "source.zip"
  if not fileExists(archive):
    raise newException(IOError,
      "no .archive/source.zip in " & workingDir &
      "  (re-import the car so it gets stashed)")

  let gltfPath = workingDir / "car.gltf"
  if not fileExists(gltfPath):
    raise newException(IOError, "no car.gltf in " & workingDir)

  if strict:
    let missing = validateRoundtripExtras(gltfPath)
    if missing.len > 0:
      var msg = "car.gltf missing " & $missing.len & " round-trip extras keys; " &
                "re-import via Stage-1-aware importwc. First few:\n"
      for k in missing[0 ..< min(5, missing.len)]:
        msg.add("  - " & k & "\n")
      raise newException(IOError, msg)

  let dst = if outDir.len > 0: outDir else: workingDir / "geometry"
  createDir(dst)

  let entries = listEntries(archive)
  for e in entries:
    if not isCarbinName(e.name): continue
    let donor = extract(archive, e)
    if donor.len == 0:
      result.warnings.add("empty donor for " & e.name)
      continue
    let baseName = extractFilename(e.name)
    let stem = if baseName.toLowerAscii().endsWith(".carbin"):
                 baseName[0 ..< baseName.len - ".carbin".len]
               else: baseName
    let bytes = emitCarbinRoundtrip(donor, stem)
    let regen = dst / baseName & ".regen"
    writeAllBytes(regen, bytes)
    result.carbinsWritten.inc
    result.bytesWritten += bytes.len.int64
    result.fellThroughToDonor.inc
