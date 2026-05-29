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

import std/[json, os, strutils]
import ../zip21
import ../gltf
import ../profile
import ./transcode

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

proc verbatim(donorBytes: openArray[byte]): seq[byte] =
  result = newSeq[byte](donorBytes.len)
  for i, b in donorBytes: result[i] = b

proc emitCarbinRoundtrip*(donorBytes: openArray[byte],
                          profile: GameProfile,
                          gltfPath: string): tuple[bytes: seq[byte]; edited: bool] =
  ## Re-encode a carbin from the working/ glTF: donor == source == this
  ## carbin (same car, same game), with vertex POSITIONS sourced from
  ## `car.gltf` (`transcodeCarbinFromGltf`). A round-trip without edits is
  ## byte-near-identical — positions are re-quantized through int16, so
  ## sub-µm drift only. On any failure (non-body carbin, parse/validate
  ## error, missing mesh) returns donor bytes verbatim with edited=false.
  try:
    let r = transcodeCarbinFromGltf(donorBytes, donorBytes, profile, gltfPath)
    result.bytes = r.bytes
    result.edited = r.report.sectionsSpliced > 0
  except CatchableError:
    result.bytes = verbatim(donorBytes)
    result.edited = false

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

  # Resolve the origin game's profile from carslot.json so the re-encode
  # validates against the right carbin family. Without it, fall back to
  # pure passthrough (today's conservative behaviour).
  var profile: GameProfile
  var haveProfile = false
  let carslot = workingDir / "carslot.json"
  if fileExists(carslot):
    try:
      let origin = parseJson(readFile(carslot)){"originGame"}.getStr("")
      if origin.len > 0:
        profile = loadProfileById(origin)
        haveProfile = true
    except CatchableError as e:
      result.warnings.add("profile resolve failed: " & e.msg)
  if not haveProfile:
    result.warnings.add(
      "no resolvable originGame profile; carbins pass through verbatim")

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
    let bytes =
      if haveProfile:
        let er = emitCarbinRoundtrip(donor, profile, gltfPath)
        result.sectionsCompared.inc
        if er.edited: result.sectionsEdited.inc
        else: result.fellThroughToDonor.inc
        er.bytes
      else:
        result.fellThroughToDonor.inc
        verbatim(donor)
    let regen = dst / baseName & ".regen"
    writeAllBytes(regen, bytes)
    result.carbinsWritten.inc
    result.bytesWritten += bytes.len.int64
