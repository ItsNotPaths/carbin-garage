## port-to: cross-game car export.
##
## Stage 2 of the locked two-stage workflow. Takes an already-imported
## working car (`working/<slug>/`) and produces a new archive in the
## target game's cars dir, using a donor car from the target game as
## the structural scaffold.
##
## ## v0 (Slice A) scope
##
## - **Carbins**: every carbin in `working/<slug>/geometry/` is replaced
##   by the donor's same-named carbin (verbatim passthrough). The
##   `transcode.nim` stub validates source + donor parse, but the
##   output bytes are the donor's. v0-ported cars therefore render the
##   donor's mesh — the value of v0 is proving the runtime accepts the
##   port-to'd archive shape, not shipping the source's mesh.
## - **Textures**: `texture_port.planTexturePort` decides which buckets
##   copy from source, splice from donor, or drop. Source's textures
##   get re-cased for the target's casing convention.
## - **DB**: source's `cardb.json` is overlaid on the donor's
##   `Data_Car` row + child rows in the target's `gamedb.slt`.
##   `BaseCost=1` is forced so the new car is cheap to buy in-game.
## - **physicsdefinition.bin** + **stripped_*.carbin**: donor passthrough
##   per locked policy (donor-bin strategy, never synthesized).
## - **Output zip**: `rewriteZipMixedMethod(donorZip, edits)`. Edits
##   are the texture renames + carbin (donor-verbatim) replacements;
##   everything not in `edits` rides the donor's method-21 LZX bytes
##   verbatim. Atomic write via `.tmp` + `.bak` rename.
##
## Slice B replaces only `transcodeCarbin`'s body — the orchestrator's
## edit-table assembly stays the same.

import std/[json, os, strutils, tables]
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
    fromDonorOnly*: bool           # if true: skip texture splicing AND
                                   # snippet overlay; clone donor's DB row
                                   # with just MediaName + the default
                                   # overrides. Used for stepwise
                                   # debugging of the port pipeline.
    noEntryRename*: bool           # if true: skip the inner-zip entry
                                   # rename. Outer zip is still named with
                                   # newSlug, and the DB row is patched,
                                   # but entries inside keep donor's
                                   # filenames. Tests whether entry-name
                                   # rewrites are what breaks IO.

  GeometryActionKind* = enum
    gaTranscode       ## both source + donor have this carbin → transcode (v0 = donor verbatim)
    gaDonorOnly       ## donor has it, source doesn't → keep donor's bytes (no edit)
    gaSourceExtra     ## source has it, donor doesn't → drop (donor scaffolds the part list)

  GeometryAction* = object
    kind*:        GeometryActionKind
    zipEntryName*: string         # name as it appears in the donor zip
    sourcePath*:  string          # working/<slug>/geometry/<file> (if any)
    note*:        string

# ---- helpers ----

proc readFileBytes(path: string): seq[byte] =
  let s = readFile(path)
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc writeAllBytes(path: string, data: openArray[byte]) =
  var f = open(path, fmWrite)
  defer: f.close()
  if data.len > 0: discard f.writeBytes(data, 0, data.len)

proc isCarbinName(name: string): bool =
  name.toLowerAscii().endsWith(".carbin")

proc isStrippedCarbin(name: string): bool =
  ## TypeId 0 stub carbins. Always pass through donor's bytes — format
  ## is unknown and we can't transcode anyway.
  extractFilename(name).toLowerAscii().startsWith("stripped_")

proc isPhysicsBin(name: string): bool =
  extractFilename(name).toLowerAscii() == "physicsdefinition.bin"

proc isXdsName(name: string): bool =
  name.toLowerAscii().endsWith(".xds")

proc baseNameNoExt(name: string): string =
  let b = extractFilename(name)
  let dot = b.rfind('.')
  if dot < 0: b else: b[0 ..< dot]

proc indexZipEntries(zipPath: string): tuple[entries: seq[Entry];
                                              byBase: Table[string, Entry]] =
  let entries = listEntries(zipPath)
  var byBase = initTable[string, Entry]()
  for e in entries:
    byBase[extractFilename(e.name).toLowerAscii()] = e
  result = (entries, byBase)

# ---- planning ----

proc planPort*(workingCar: string, mount: Mount, targetProfile: GameProfile,
               donorSlug: string, newSlug: string = "",
               fromDonorOnly: bool = false,
               noEntryRename: bool = false): PortPlan =
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
    backupExists: fileExists(targetZip & ".bak"),
    fromDonorOnly: fromDonorOnly,
    noEntryRename: noEntryRename)

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
  let donorIdx = indexZipEntries(donorZip)
  var donorTextures: seq[string] = @[]
  for e in donorIdx.entries:
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
  if fromDonorOnly:
    # Empty texture plan — donor's textures pass through verbatim via
    # the rename mechanism.
    plan.texturePlan = TexturePortPlan(target: targetProfile.id, ops: @[])
  else:
    plan.texturePlan = planTexturePort(sourceTextures, donorTextures,
                                       sourceProfile, targetProfile)

  # Geometry actions: walk donor's carbin entries, decide what to do
  # for each. Donor's part list is authoritative.
  let workingGeomDir = abs / "geometry"
  for e in donorIdx.entries:
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
        note: "v0: stub transcode emits donor bytes verbatim"))
    else:
      plan.geometryActions.add(GeometryAction(
        kind: gaDonorOnly, zipEntryName: e.name,
        note: "no matching source carbin — donor verbatim"))

  # Cardb plan.
  if plan.targetGamedb.len > 0 and fileExists(plan.targetGamedb):
    let snippet =
      if fromDonorOnly:
        # Empty snippet → planCardbPatch only finds donor rows, so every
        # table action becomes ctaInsertDonorClone (or ctaInsertOverlay
        # for Data_Car which is always inserted from donor's row when
        # snippet is silent on it).
        %*{"tables": newJObject()}
      elif fileExists(abs / "cardb.json"):
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
    of gaSourceExtra: discard
  result.add "  geometry: transcode=" & $transcodeN &
             " donor-only=" & $donorOnlyN & "  (v0: all output is donor bytes)\n"
  if p.targetGamedb.len == 0:
    result.add "  cardb: skipped (no gamedbPath in target profile)\n"
  elif p.cardbPlan.targetGamedb.len == 0:
    result.add "  cardb: skipped (no cardb.json in working car)\n"
  else:
    result.add "  cardb:\n"
    result.add describePatchPlan(p.cardbPlan)

# ---- execute ----

proc rewriteXdsName(srcZipName, donorBase, donorSlug, newSlug: string): string =
  ## Cross-game ports re-base zip-entry paths so the file lands in the
  ## same conceptual slot. For now we only need the basename swap (zips
  ## don't always carry a directory structure on FM4; FH1 does, but the
  ## donor's path is reused verbatim — only the *basename* gets retargeted
  ## for buckets that come from the texture plan). This helper isn't
  ## currently called; texture rebase happens via direct entry-name
  ## lookup in `executePort`.
  result = srcZipName

proc renamePrefixIn(name, fromPrefix, toPrefix: string): string =
  ## Substring-replace the first occurrence of `fromPrefix` (case-
  ## insensitive) inside `name`, with `toPrefix` written in the casing
  ## that *matches* the donor occurrence's casing. So:
  ##   ALF_8C_08.carbin            +(ALF_8C_08, ALF_8C_08_FM4PORT) → ALF_8C_08_FM4PORT.carbin
  ##   ALF_8C_08_caliperLF_LOD0.carbin → ALF_8C_08_FM4PORT_caliperLF_LOD0.carbin
  ##   stripped_alf_8c_08_lod0.carbin (lowercase block)
  ##                              +(ALF_8C_08, ALF_8C_08_FM4PORT) → stripped_alf_8c_08_fm4port_lod0.carbin
  ## Returns the input unchanged if there's no match.
  let lc = name.toLowerAscii()
  let needle = fromPrefix.toLowerAscii()
  let idx = lc.find(needle)
  if idx < 0: return name
  let donorOcc = name[idx ..< idx + needle.len]
  # Decide replacement casing: if the donor occurrence is all lowercase,
  # write the new prefix lowercase too; otherwise use the new prefix
  # verbatim (mixed/upper).
  let replacement =
    if donorOcc == donorOcc.toLowerAscii(): toPrefix.toLowerAscii()
    else: toPrefix
  result = name[0 ..< idx] & replacement & name[idx + needle.len .. ^1]

proc buildRenames(donorEntries: seq[Entry], donorSlug, newSlug: string):
                  Table[string, string] =
  ## Build the rename map for every donor entry whose name carries the
  ## donor's MediaName. Entries that don't reference donor's name (rare
  ## — `physicsdefinition.bin`, `versiondata.xml`, etc.) pass through
  ## unrenamed.
  result = initTable[string, string]()
  if donorSlug == newSlug: return
  for e in donorEntries:
    let renamed = renamePrefixIn(e.name, donorSlug, newSlug)
    if renamed != e.name:
      result[e.name] = renamed

proc collectEdits(p: PortPlan): Table[string, seq[byte]] =
  ## Build the `Table[zipEntryName -> newBytes]` for
  ## rewriteZipMixedMethod. Donor's archive is the byte source; only
  ## entries that change (textures, carbins) appear here. Keys are the
  ## donor's *original* entry name (rename happens separately).
  result = initTable[string, seq[byte]]()
  let donorIdx = indexZipEntries(p.donorZip)
  let donorBytes = readFileBytes(p.donorZip)
  let donorEntries = donorIdx.entries

  # Index donor entries by lowercased basename for fast lookup.
  var donorEntryByBase = initTable[string, Entry]()
  for e in donorEntries: donorEntryByBase[extractFilename(e.name).toLowerAscii()] = e

  let workingTexDir = p.workingCar / "textures"
  let workingGeomDir = p.workingCar / "geometry"

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
    of gaDonorOnly, gaSourceExtra:
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
  let renames =
    if p.noEntryRename: initTable[string, string]()
    else: buildRenames(donorEntries, p.donorSlug, p.newSlug)
  let bytes = rewriteZipMixedMethod(p.donorZip, edits, renames)
  writeAllBytes(p.tmpPath, bytes)
  if p.targetExists:
    moveFile(p.targetZip, p.backupPath)
  moveFile(p.tmpPath, p.targetZip)

  # DB patch.
  if p.targetGamedb.len > 0 and fileExists(p.targetGamedb):
    let snippet =
      if p.fromDonorOnly: %*{"tables": newJObject()}
      elif fileExists(p.workingCar / "cardb.json"):
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
