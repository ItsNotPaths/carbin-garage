## port-to: SAME-GAME in-place port. Takes an already-imported working
## car (`working/<slug>/`) and rewrites a donor archive in the target
## game's cars dir, patching the target's live `gamedb.slt` directly.
##
## Cross-game / new-car ports do NOT go through here — they use the DLC
## packaging path in `orchestrator/portto_dlc.nim` (direct gamedb edits
## crash FH1's audio-init SQL chain for cross-game rows; the DLC
## merge.slt overlay avoids that entirely).
##
## Pipeline:
## - **Carbins**: each carbin in `working/<slug>/geometry/` is
##   transcoded against the donor's same-named carbin
##   (`transcode.transcodeCarbin`); donor-verbatim results ride the
##   donor's method-21 LZX bytes untouched.
## - **Textures**: `texture_port.planTexturePort` decides which buckets
##   copy from source, splice from donor, or drop.
## - **DB**: source's `cardb.json` is overlaid on the donor's
##   `Data_Car` row + child rows in the target's `gamedb.slt`.
## - **physicsdefinition.bin** + **stripped_*.carbin**: donor passthrough
##   per locked policy (donor-bin strategy, never synthesized).
## - **Output zip**: `rewriteZipMixedMethod(donorZip, edits)` with
##   atomic write via `.tmp` + `.bak` rename.

import std/[json, os, strutils, tables]
import ./port_common
import ../core/ioutil
import ../core/profile
import ../core/mounts
import ../core/zip21
import ../core/zip21_writer
import ../core/texture_port
import ../core/cardb_writer
import ../core/carbin/transcode

type
  PortError* = object of CatchableError

  PortPlan* = object
    workingCar*:    string         # absolute path to working/<slug>/
    sourceSlug*:    string         # working car basename (= source MediaName)
    targetGameId*:  string
    targetProfile*: GameProfile
    donorSlug*:     string
    newSlug*:       string         # final basename for the ported zip
    donorZip*:      string         # <mountFolder>/<profile.cars>/<donorSlug>.zip
    targetZip*:     string         # <mountFolder>/<profile.cars>/<newSlug>.zip
    backupPath*:    string         # <targetZip>.bak (only relevant if it exists)
    tmpPath*:       string         # <targetZip>.tmp
    targetGamedb*:  string         # <mountFolder>/<gamedbPath>
    targetExists*:  bool
    backupExists*:  bool
    cardbPlan*:     CardbPatchPlan
    texturePlan*:   TexturePortPlan
    geometryActions*: seq[GeometryAction]

  GeometryActionKind* = enum
    gaTranscode       ## both source + donor have this carbin → transcode
    gaDonorOnly       ## donor has it, source doesn't → keep donor's bytes (no edit)

  GeometryAction* = object
    kind*:        GeometryActionKind
    zipEntryName*: string         # name as it appears in the donor zip
    sourcePath*:  string          # working/<slug>/geometry/<file> (if any)
    note*:        string

# ---- planning ----

proc planPort*(workingCar: string, mount: Mount, targetProfile: GameProfile,
               donorSlug: string, newSlug: string = ""): PortPlan =
  let abs =
    if isAbsolute(workingCar): workingCar
    else: absolutePath(workingCar)
  if not dirExists(abs):
    raise newException(PortError, "working car dir not found: " & abs)
  let slug = lastPathPart(abs)
  let finalSlug = if newSlug.len > 0: newSlug else: slug
  let carsDir = carsDirFor(mount.folder, targetProfile)
  if not dirExists(carsDir):
    raise newException(PortError, "target cars dir does not exist: " & carsDir)
  let donorZip = carsDir / (donorSlug & ".zip")
  if not fileExists(donorZip):
    raise newException(PortError,
      "donor archive not found: " & donorZip &
      " (donor must be a real car already shipping in the target game)")
  let targetZip = carsDir / (finalSlug & ".zip")

  var plan = PortPlan(
    workingCar: abs, sourceSlug: slug,
    targetGameId: targetProfile.id, targetProfile: targetProfile,
    donorSlug: donorSlug, newSlug: finalSlug,
    donorZip: donorZip, targetZip: targetZip,
    backupPath: targetZip & ".bak", tmpPath: targetZip & ".tmp",
    targetExists: fileExists(targetZip),
    backupExists: fileExists(targetZip & ".bak"))

  # Resolve target gamedb path.
  if targetProfile.gamedbPath.len > 0:
    plan.targetGamedb = mount.folder / targetProfile.gamedbPath

  # Texture plan.
  let workingTexDir = abs / "textures"
  var sourceTextures: seq[string] = @[]
  if dirExists(workingTexDir):
    for kind, p in walkDir(workingTexDir):
      if kind != pcFile: continue
      if isXdsName(p):
        sourceTextures.add(extractFilename(p))
  let donorEntries = listEntries(donorZip)
  var donorTextures: seq[string] = @[]
  for e in donorEntries:
    if isXdsName(e.name):
      donorTextures.add(extractFilename(e.name))

  # Source profile + source MediaName: needed for texture_port (extras
  # check) and for naming-prefix swap when matching donor carbin slots
  # to source files. carslot.json gives us originGame; cardb.json gives
  # us mediaName. Both fall back to slug-derived guesses if absent.
  var sourceProfileId = "fm4"
  var sourceMediaName = slug
  let carslot = abs / "carslot.json"
  if fileExists(carslot):
    try:
      let j = parseJson(readFile(carslot))
      if j.hasKey("originGame"): sourceProfileId = j["originGame"].getStr
    except CatchableError: discard
  let cardbJson = abs / "cardb.json"
  if fileExists(cardbJson):
    try:
      let j = parseJson(readFile(cardbJson))
      if j.hasKey("mediaName"): sourceMediaName = j["mediaName"].getStr
    except CatchableError: discard
  let sourceProfile =
    try: loadProfileById(sourceProfileId)
    except CatchableError: targetProfile  # degraded fallback
  plan.texturePlan = planTexturePort(sourceTextures, donorTextures,
                                     sourceProfile, targetProfile)

  # Geometry actions: walk donor's carbin entries, decide what to do
  # for each. Donor's part list is authoritative.
  let workingGeomDir = abs / "geometry"
  for e in donorEntries:
    if not isCarbinName(e.name): continue
    let baseLc = extractFilename(e.name).toLowerAscii()
    if isStrippedCarbin(baseLc):
      plan.geometryActions.add(GeometryAction(
        kind: gaDonorOnly, zipEntryName: e.name,
        note: "stripped_*.carbin — donor verbatim (format unknown)"))
      continue
    # Look for a matching source carbin. Carbin filenames are prefixed
    # with the *source game's* MediaName (FM4 lowercases the prefix on
    # disk; FH1 mixed). Swap donor's MediaName prefix → source's
    # MediaName prefix to find the corresponding file in the working
    # tree. `donorSlug` here is the donor zip basename which equals the
    # donor's MediaName.
    let donorBase = extractFilename(e.name)
    let donorBaseLc = donorBase.toLowerAscii()
    let donorPrefixLc = donorSlug.toLowerAscii()
    let sourcePrefixLc = sourceMediaName.toLowerAscii()
    let sourceBaseGuess =
      if donorBaseLc.startsWith(donorPrefixLc):
        sourcePrefixLc & donorBaseLc[donorPrefixLc.len .. ^1]
      else:
        donorBaseLc
    let sourceCandidates = [
      workingGeomDir / sourceBaseGuess,
      workingGeomDir / donorBaseLc,
      workingGeomDir / donorBase,
    ]
    var sourcePath = ""
    for c in sourceCandidates:
      if fileExists(c): sourcePath = c; break
    if sourcePath.len > 0:
      plan.geometryActions.add(GeometryAction(
        kind: gaTranscode, zipEntryName: e.name,
        sourcePath: sourcePath,
        note: "transcode from working source against donor scaffold"))
    else:
      plan.geometryActions.add(GeometryAction(
        kind: gaDonorOnly, zipEntryName: e.name,
        note: "no matching source carbin — donor verbatim"))

  # Cardb plan.
  if plan.targetGamedb.len > 0 and fileExists(plan.targetGamedb):
    let snippet =
      if fileExists(abs / "cardb.json"):
        parseJson(readFile(abs / "cardb.json"))
      else:
        newJNull()
    if snippet.kind != JNull:
      try:
        plan.cardbPlan = planCardbPatch(plan.targetGamedb, snippet,
                                        donorSlug.toUpperAscii(),
                                        finalSlug.toUpperAscii())
      except CatchableError as e:
        raise newException(PortError, "cardb plan failed: " & e.msg)
  result = plan

proc describePlan*(p: PortPlan): string =
  result.add "  source: " & p.workingCar & "\n"
  result.add "  target: " & p.targetZip & "\n"
  result.add "  donor:  " & p.donorZip & "\n"
  if p.targetExists:
    result.add "    (target exists — will move to " & p.backupPath & ")\n"
  else:
    result.add "    (fresh write)\n"
  if p.targetExists and p.backupExists:
    result.add "  ! backup already exists at " & p.backupPath & " — refuse\n"
  result.add "  textures: copy=" & $p.texturePlan.sourceCount &
             " splice=" & $p.texturePlan.donorCount &
             " drop=" & $p.texturePlan.droppedCount & "\n"
  var transcodeN, donorOnlyN: int
  for a in p.geometryActions:
    case a.kind
    of gaTranscode: inc transcodeN
    of gaDonorOnly: inc donorOnlyN
  result.add "  geometry: transcode=" & $transcodeN &
             " donor-only=" & $donorOnlyN & "\n"
  if p.targetGamedb.len == 0:
    result.add "  cardb: skipped (no gamedbPath in target profile)\n"
  elif p.cardbPlan.targetGamedb.len == 0:
    result.add "  cardb: skipped (no cardb.json in working car)\n"
  else:
    result.add "  cardb:\n"
    result.add describePatchPlan(p.cardbPlan)

# ---- execute ----

proc collectEdits(p: PortPlan): Table[string, seq[byte]] =
  ## Build the `Table[zipEntryName -> newBytes]` for
  ## rewriteZipMixedMethod. Donor's archive is the byte source; only
  ## entries that change (textures, carbins) appear here. Keys are the
  ## donor's *original* entry name (rename happens separately).
  result = initTable[string, seq[byte]]()

  # Index donor entries by lowercased basename for fast lookup.
  var donorEntryByBase = initTable[string, Entry]()
  for e in listEntries(p.donorZip):
    donorEntryByBase[extractFilename(e.name).toLowerAscii()] = e

  let workingTexDir = p.workingCar / "textures"

  # Textures.
  for op in p.texturePlan.ops:
    case op.kind
    of topCopySource:
      # Source's bytes go in under the target's casing convention.
      # Donor's archive may carry the entry under a different casing —
      # find the existing entry by lowercased basename so the cdir
      # rewrite slots into the right LFH location.
      let srcPath = workingTexDir / op.sourceName
      if not fileExists(srcPath): continue
      let bytes = readFileBytes(srcPath)
      let donorEntryName =
        if op.targetName.toLowerAscii() in donorEntryByBase:
          donorEntryByBase[op.targetName.toLowerAscii()].name
        else:
          op.targetName  # donor lacks it; will be a fresh entry — but
                          # rewriteZipMixedMethod doesn't add new entries,
                          # only replaces existing ones, so this case is
                          # silently skipped today. (Slice B concern.)
      result[donorEntryName] = bytes
    of topSpliceDonor:
      # Donor's own bytes — no edit needed; rewriteZipMixedMethod
      # already passes donor entries through verbatim.
      discard
    of topDropExtra:
      # Source has it, target doesn't declare it — same: drop = no edit.
      discard

  # Geometry.
  for ga in p.geometryActions:
    case ga.kind
    of gaTranscode:
      let donorEntry = donorEntryByBase[extractFilename(ga.zipEntryName).toLowerAscii()]
      # Pull donor's decompressed bytes (need them as input to transcode).
      var donorBytesEntry = extract(p.donorZip, donorEntry)
      let sourceBytes = readFileBytes(ga.sourcePath)
      let r =
        try: transcodeCarbin(sourceBytes, donorBytesEntry, p.targetProfile)
        except CatchableError as e:
          raise newException(PortError,
            "transcode failed for " & ga.zipEntryName & ": " & e.msg)
      # When transcode is the v0 donor-verbatim stub, the output bytes
      # equal donor's decompressed bytes — there is nothing to splice.
      # Skipping the edit here lets the rename mechanism retarget the
      # donor's *original method-21 LZX-compressed* entry under the new
      # name (zero decompress/recompress; the LZX bitstream is preserved
      # byte-verbatim, which is what the FH1 IO layer expects for
      # carbin slots).
      if r.report.mode != tmDonorVerbatim:
        result[ga.zipEntryName] = r.bytes
    of gaDonorOnly:
      discard

proc executePort*(p: PortPlan, replaceDb: bool = false) =
  ## Order:
  ##   1. Refuse if target exists AND .bak exists.
  ##   2. Build edits Table from texture plan + geometry actions.
  ##   3. rewriteZipMixedMethod(donorZip, edits) → tmp.
  ##   4. If target exists, move target → .bak.
  ##   5. Move tmp → target.
  ##   6. Patch target gamedb.slt with cardb snippet (replace=replaceDb).
  ## DB patch happens AFTER the zip lands so a zip failure doesn't leave
  ## a half-applied DB.
  if p.targetExists and p.backupExists:
    raise newException(PortError,
      "refusing to overwrite — backup already exists at " & p.backupPath)
  let edits = collectEdits(p)
  let donorEntries = listEntries(p.donorZip)
  let renames = buildRenames(donorEntries, p.donorSlug, p.newSlug)
  let bytes = rewriteZipMixedMethod(p.donorZip, edits, renames)
  writeFileBytes(p.tmpPath, bytes)
  if p.targetExists:
    moveFile(p.targetZip, p.backupPath)
  moveFile(p.tmpPath, p.targetZip)

  # DB patch.
  if p.targetGamedb.len > 0 and fileExists(p.targetGamedb):
    let snippet =
      if fileExists(p.workingCar / "cardb.json"):
        parseJson(readFile(p.workingCar / "cardb.json"))
      else: newJNull()
    if snippet.kind != JNull:
      try:
        discard applyCardbToTarget(p.targetGamedb, snippet,
                                   p.donorSlug.toUpperAscii(),
                                   p.newSlug.toUpperAscii(),
                                   replace = replaceDb)
      except CardbWriteError as e:
        raise newException(PortError, "cardb patch failed: " & e.msg)
