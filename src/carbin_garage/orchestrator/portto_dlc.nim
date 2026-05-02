## port-to (DLC mode): emit a Forza Horizon DLC package for a new car.
##
## ## Two backend modes for cross-game / new-car export
##
## The backend now exposes two distinct write paths. The UI surface stays
## flat — a single "save as" picker chooses the slug; this module is
## reached when the user picked a slug that does NOT already exist in the
## target game (i.e. "add a new car"). The other path,
## `orchestrator/portto.nim`, is reached for an existing slug
## (i.e. "overwrite this car"). The dispatcher between them is the CLI
## verb / future orchestrator entry; this file does not own that choice.
##
## | Mode                | Module             | What it touches                                 | Status                                     |
## |---------------------|--------------------|-------------------------------------------------|--------------------------------------------|
## | overwrite-existing  | portto.nim         | media/cars/<slug>.zip + gamedb.slt row          | works same-game; cross-game pipeline-broken |
## | add-new-car (DLC)   | portto_dlc.nim     | xenia content/<profile>/<TitleID>/00000002/<id>/| **scaffold** — see "Scaffold scope" below  |
##
## ## Why DLC packaging
##
## In-game testing on 2026-05-01 ruled out cross-game `port-to` via direct
## `gamedb.slt` edits. The audio engine's init-time SQL chain returns 0
## rows for our newly-cloned car, SQL CE substitutes its error string
## into asset paths, and the open-world spawn nukes the global render
## pipeline. ~30 tables of cloning across two sessions did not isolate
## the offending join. Working car-add mods exist in the wild and they
## all package as DLC: a separate `<id>00_merge.slt` is loaded and merged
## into the live DB at boot, exercising a different code path that the
## audio subsystem honors. Authoritative roadmap: `docs/PLAN_DLC_PIVOT.md`.
##
## ## DLC package layout (decoded from the example at
##   xenia_canary_windows/content/0000000000000000/4D5309C9/00000002/4D5309C900000729)
##
## ```
## <packageDir>/                                       # named <TitleID><DlcId8hex>
## └── Media/
##     ├── <dlcId>.puboffer                            # 3-byte marker (CR LF LF)
##     └── DLCZips/
##         ├── zipmount.xml                            # declares mount points
##         ├── <packageId>_pri_99/                     # extracted "main overlay"
##         │   └── Media/
##         │       └── db/
##         │           └── patch/
##         │               └── <dlcId>00_merge.slt     # 56-table partial gamedb
##         ├── cars_pri_<dlcId>/<MediaName>.zip        # geometry (NEW)
##         └── wheels_pri_<dlcId>/<MediaName>.zip      # wheels (NEW)
## ```
##
## Mount point semantics (from sample's zipmount.xml):
##   - `cars_pri_<id>`     mounts at `game:\Media\cars\`
##   - `wheels_pri_<id>`   mounts at `game:\Media\wheels\`
##   - `_pri_<NNN>` priority encoding: higher number = higher priority
##
## ## Scaffold scope (this file, today)
##
## What this scaffold DOES:
##   - Compute every output path on disk (no writes during planning).
##   - Synthesize a deterministic DLC id + package id from the new-car
##     slug, so re-running the same port re-targets the same package.
##   - Drive the geometry zip emit via `rewriteZipMixedMethod` against
##     the donor (same engine `portto.nim` uses). v0 carbin transcode is
##     donor-verbatim; the rename mechanism re-targets entries to the new
##     MediaName. The texture splice plan is built but not yet wired into
##     edits (mirror of portto.nim's collectEdits — keep parity).
##   - Emit `<dlcId>.puboffer` (3-byte marker) and `zipmount.xml`.
##   - Provide an `uninstall` op that removes the package dir cleanly.
##
## What this scaffold STUBS (raises with a clear TODO until wired):
##   - **`buildMergeSlt`**: producing the per-DLC `<dlcId>00_merge.slt`
##     SQLite file. This is the load-blocking piece — without it the new
##     car is invisible to the game. The 56-table subset + per-car PK
##     conventions (`Data_Engine.EngineID` independent ID space,
##     `List_TorqueCurve.TorqueCurveID = <EngineID>NNN`, single-semantics
##     `List_Upgrade*.EngineID`) are documented in PLAN_DLC_PIVOT.md
##     §"DLC architecture" / §"Implementation plan §B step 4".
##   - **Audio CMT / ET XMLs**: `<MediaName>_CMT.xml` + `<MediaName>_ET.xml`.
##     PLAN found 13 base-game cars without ET files load fine, so missing
##     audio config is degrade-graceful — deferred until base path proves
##     in-game.
##   - **StringTables**: per-language `Data_Car` display name entry.
##     Open question per PLAN — may degrade gracefully via resource-id
##     lookup.
##   - **`0x1123` extra field**: known fix needed in `core/zip21_writer.nim`
##     (see project memory `project_zip21_extra_field.md`). Same fix
##     applies here — DLC zip emit will inherit it once the writer is
##     patched. No work here, just the dependency.
##
## ## Open questions deferred to follow-up
##
## All five open questions from PLAN_DLC_PIVOT.md §"Open questions" map
## directly to TODOs here. The riskiest is package-id format — the
## scaffold uses `<TitleID><24-bit-slug-hash padded to 8 hex>` which
## matches the example DLC's shape but has not been verified to mount
## under arbitrary IDs. If Xenia rejects the synthesized id, fall back
## to enumerating an unused integer DLC id under `00000002/`.

import std/[hashes, json, os, strutils, tables]
import ../core/profile
import ../core/mounts
import ../core/zip21
import ../core/texture_port
import ../core/carbin/transcode
import ../core/dlc_merge

type
  DlcPortError* = object of CatchableError

  DlcGeometryActionKind* = enum
    dgaTranscode       ## both source + donor have this carbin → transcode
    dgaDonorOnly       ## donor has it, source doesn't → keep donor's bytes
    dgaSourceExtra     ## source has it, donor doesn't → drop

  DlcGeometryAction* = object
    kind*: DlcGeometryActionKind
    zipEntryName*: string
    sourcePath*: string
    note*: string

  DlcPortPlan* = object
    # Inputs
    workingCar*:    string         # absolute path to working/<slug>/
    sourceSlug*:    string         # working car basename (= source MediaName)
    targetGameId*:  string
    targetProfile*: GameProfile
    donorSlug*:     string
    newSlug*:       string         # final MediaName for the new DLC car

    # Xenia content tree
    contentRoot*:   string         # <xenia>/content
    profileId*:     string         # "0000000000000000" = global slot (default)
    titleIdDir*:    string         # contentRoot/profileId/<TitleID>
    dlcSlot*:       string         # contentRoot/profileId/<TitleID>/00000002

    # Synthesized package identity
    dlcId*:         int            # numeric DLC id (used in dir/filename suffixes)
    forcedCarId*:   int            # 0 = auto via findUnusedCarId; >0 pins Data_Car.Id (save migration)
    forcedEngineId*:int            # 0 = auto; >0 pins Data_Engine.EngineID
    packageId*:     string         # 16-hex: <TitleID><dlcId8hex>
    packageDir*:    string         # dlcSlot/packageId

    # Per-package output paths (under packageDir/Media/...)
    pubofferPath*:  string
    dlcZipsDir*:    string         # packageDir/Media/DLCZips
    zipmountPath*:  string         # dlcZipsDir/zipmount.xml
    mergeOverlayDir*: string       # dlcZipsDir/<packageId>_pri_99
    mergeSltPath*:  string         # mergeOverlayDir/Media/db/patch/<dlcId>00_merge.slt
    carsZipPath*:   string         # dlcZipsDir/cars_pri_<dlcId>/<newSlug>.zip
    wheelsZipPath*: string         # dlcZipsDir/wheels_pri_<dlcId>/<newSlug>.zip
    headerPath*:    string         # contentRoot/<profileId>/<TitleID>/Headers/00000002/<packageId>.header

    # Source pieces from the target mount
    donorCarsZip*:    string       # <mountFolder>/<profile.cars>/<donor>.zip
    donorWheelsZip*:  string       # <mountFolder>/media/wheels/<donor>.zip
    targetGamedb*:    string       # <mountFolder>/<profile.gamedbPath>
                                    # (read-only here — used to fetch donor's
                                    # rows as the merge.slt seed)

    # Plans driven by working/<slug>/
    geometryActions*: seq[DlcGeometryAction]
    texturePlan*:     TexturePortPlan

    # Safety
    packageExists*: bool

# ---- helpers ----

const
  DefaultProfileId = "0000000000000000"
    ## Xenia's "no profile / global" slot. DLCs placed here apply for any
    ## profile; the example DLC at `4D5309C900000729` lives here.
  DlcContentTypeDir = "00000002"
    ## Xenia content type for "Marketplace Content" (DLC). Sibling to
    ## `00000001` (saved games). Always 8 hex.
  DefaultMergePriority = 99
    ## Priority for the per-package overlay. Sample DLC uses 99; higher
    ## values win on collision in zipmount mounting order.
  PubofferMarker = "\r\n\n"
    ## 3-byte marker observed in the sample DLC's `Media/729.puboffer`.
    ## Treated as opaque content for now (PLAN open question §2).

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
  extractFilename(name).toLowerAscii().startsWith("stripped_")

proc isXdsName(name: string): bool =
  name.toLowerAscii().endsWith(".xds")

proc indexZipEntries(zipPath: string): tuple[entries: seq[Entry];
                                              byBase: Table[string, Entry]] =
  let entries = listEntries(zipPath)
  var byBase = initTable[string, Entry]()
  for e in entries:
    byBase[extractFilename(e.name).toLowerAscii()] = e
  result = (entries, byBase)

proc synthDlcId*(slug: string): int =
  ## Deterministic 24-bit id from the new-car slug. Range chosen to
  ## avoid colliding with shipped DLCs (the FH1 sample DLC is id 729 —
  ## three decimal digits — so steering clear of <100_000 keeps us
  ## clear of the small-int neighborhood). Hash is `std/hashes.hash`,
  ## modulo (0xFFFFFF - 0x100000 + 1) and offset by 0x100000 so output
  ## stays in 0x100000..0xFFFFFF.
  let h = hash(slug.toLowerAscii())
  let bounded = (uint32(h) and 0xFFFFFFu32) mod (0xFFFFFFu32 - 0x100000u32 + 1)
  result = int(bounded) + 0x100000

proc packageIdFor*(targetProfile: GameProfile, dlcId: int): string =
  ## `<TitleID-hex><dlcId-as-8-decimal-digits>`. Sample DLC's id is
  ## `4D5309C900000729` for dlcId=729 — the trailing 8 chars are NOT
  ## hex-of-decimal (would be `000002D9`); they are the dlcId rendered
  ## as decimal digits zero-padded to 8 characters. Microsoft xbox
  ## content_id convention. dlcId values that take more than 8 decimal
  ## digits (>= 100_000_000) won't fit; synthDlcId stays well under.
  let dec = $dlcId
  if dec.len > 8:
    raise newException(DlcPortError,
      "dlcId " & dec & " has more than 8 decimal digits, can't fit packageId")
  result = targetProfile.titleId.toUpperAscii() &
           "0".repeat(8 - dec.len) & dec

# ---- planning ----

proc planPortToDlc*(workingCar: string, mount: Mount, targetProfile: GameProfile,
                    contentRoot: string, donorSlug: string,
                    newSlug: string = "",
                    profileId: string = DefaultProfileId,
                    overrideDlcId: int = 0,
                    forcedCarId: int = 0,
                    forcedEngineId: int = 0): DlcPortPlan =
  let abs =
    if isAbsolute(workingCar): workingCar
    else: absolutePath(workingCar)
  if not dirExists(abs):
    raise newException(DlcPortError, "working car dir not found: " & abs)
  # Don't require contentRoot to exist at plan time — dry-runs should
  # preview the path even if the user hasn't created the dir yet. The
  # writer (`executePortToDlc`) calls `createDir` so missing intermediates
  # land cleanly. We do still want a sanity hint when the path looks
  # suspicious, but raising on absence is too aggressive.
  let slug = lastPathPart(abs)
  let finalSlug = if newSlug.len > 0: newSlug else: slug

  # Donor pieces in the target mount.
  let carsDir = carsDirFor(mount.folder, targetProfile)
  if not dirExists(carsDir):
    raise newException(DlcPortError, "target cars dir does not exist: " & carsDir)
  let donorZip = carsDir / (donorSlug & ".zip")
  if not fileExists(donorZip):
    raise newException(DlcPortError,
      "donor archive not found: " & donorZip &
      " (donor must be a real car already shipping in the target game)")
  # Wheels live alongside cars at media/wheels/ on FH1; FM4 layout TBD.
  # For the scaffold, derive wheelsDir by replacing the trailing `cars`
  # with `wheels`. If a real game has wheels elsewhere, profile.json will
  # need a `wheels` field — leave a TODO.
  let wheelsDir = carsDir.parentDir / "wheels"
  let donorWheelsZip = wheelsDir / (donorSlug & ".zip")

  # Synthesize package identity. CLI may force a specific dlcId via
  # --dlc-id (overrideDlcId>0); useful when probing whether FH1 only
  # honors known FH1 DLC ids (e.g. 730, 731 ...).
  let dlcId =
    if overrideDlcId > 0: overrideDlcId
    else: synthDlcId(finalSlug)
  let packageId = packageIdFor(targetProfile, dlcId)
  let titleIdDir = contentRoot / profileId / targetProfile.titleId.toUpperAscii()
  let dlcSlot = titleIdDir / DlcContentTypeDir
  let packageDir = dlcSlot / packageId
  let dlcZipsDir = packageDir / "Media" / "DLCZips"
  # Overlay dir naming: `<dlcId>_pri_<priority>` (NOT packageId). The
  # sample DLC at 4D5309C900000729 uses `729_pri_99/`, not the full
  # 16-hex package id. FH1 auto-discovers this dir by name pattern;
  # zipmount.xml does NOT register it (verified against sample's
  # zipmount.xml).
  let mergeOverlayDir = dlcZipsDir / ($dlcId & "_pri_" & $DefaultMergePriority)

  var plan = DlcPortPlan(
    workingCar: abs, sourceSlug: slug,
    targetGameId: targetProfile.id, targetProfile: targetProfile,
    donorSlug: donorSlug, newSlug: finalSlug,
    contentRoot: contentRoot, profileId: profileId,
    titleIdDir: titleIdDir, dlcSlot: dlcSlot,
    dlcId: dlcId, forcedCarId: forcedCarId, forcedEngineId: forcedEngineId,
    packageId: packageId, packageDir: packageDir,
    pubofferPath: packageDir / "Media" / ($dlcId & ".puboffer"),
    dlcZipsDir: dlcZipsDir,
    zipmountPath: dlcZipsDir / "zipmount.xml",
    mergeOverlayDir: mergeOverlayDir,
    mergeSltPath: mergeOverlayDir / "Media" / "db" / "patch" /
                  ($dlcId & "00_merge.slt"),
    carsZipPath: dlcZipsDir / ("cars_pri_" & $dlcId) / finalSlug,
    wheelsZipPath: dlcZipsDir / ("wheels_pri_" & $dlcId) / finalSlug,
    headerPath: titleIdDir / "Headers" / DlcContentTypeDir /
                (packageId & ".header"),
    donorCarsZip: donorZip,
    donorWheelsZip: donorWheelsZip,
    packageExists: dirExists(packageDir))

  if targetProfile.gamedbPath.len > 0:
    plan.targetGamedb = mount.folder / targetProfile.gamedbPath

  # Texture plan (mirrors portto.nim).
  let workingTexDir = abs / "textures"
  var sourceTextures: seq[string] = @[]
  if dirExists(workingTexDir):
    for kind, p in walkDir(workingTexDir):
      if kind != pcFile: continue
      if isXdsName(p): sourceTextures.add(extractFilename(p))
  let donorIdx = indexZipEntries(donorZip)
  var donorTextures: seq[string] = @[]
  for e in donorIdx.entries:
    if isXdsName(e.name): donorTextures.add(extractFilename(e.name))

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
    except CatchableError: targetProfile
  plan.texturePlan = planTexturePort(sourceTextures, donorTextures,
                                     sourceProfile, targetProfile)

  # Geometry actions (donor's part list is authoritative — same as portto.nim).
  let workingGeomDir = abs / "geometry"
  for e in donorIdx.entries:
    if not isCarbinName(e.name): continue
    let baseLc = extractFilename(e.name).toLowerAscii()
    if isStrippedCarbin(baseLc):
      plan.geometryActions.add(DlcGeometryAction(
        kind: dgaDonorOnly, zipEntryName: e.name,
        note: "stripped_*.carbin — donor verbatim"))
      continue
    let donorBase = extractFilename(e.name)
    let donorBaseLc = donorBase.toLowerAscii()
    let donorPrefixLc = donorSlug.toLowerAscii()
    let sourcePrefixLc = sourceMediaName.toLowerAscii()
    let sourceBaseGuess =
      if donorBaseLc.startsWith(donorPrefixLc):
        sourcePrefixLc & donorBaseLc[donorPrefixLc.len .. ^1]
      else:
        donorBaseLc
    let candidates = [
      workingGeomDir / sourceBaseGuess,
      workingGeomDir / donorBaseLc,
      workingGeomDir / donorBase,
    ]
    var sourcePath = ""
    for c in candidates:
      if fileExists(c): sourcePath = c; break
    if sourcePath.len > 0:
      plan.geometryActions.add(DlcGeometryAction(
        kind: dgaTranscode, zipEntryName: e.name, sourcePath: sourcePath,
        note: "v0: stub transcode emits donor bytes verbatim"))
    else:
      plan.geometryActions.add(DlcGeometryAction(
        kind: dgaDonorOnly, zipEntryName: e.name,
        note: "no matching source carbin — donor verbatim"))

  result = plan

proc describePlan*(p: DlcPortPlan): string =
  result.add "  source:    " & p.workingCar & "\n"
  result.add "  donor:     " & p.donorCarsZip & "\n"
  result.add "  target:    DLC package\n"
  result.add "    titleId:    " & p.targetProfile.titleId & "\n"
  result.add "    dlcId:      " & $p.dlcId & "  (0x" & toHex(p.dlcId, 8) & ")\n"
  result.add "    packageId:  " & p.packageId & "\n"
  result.add "    packageDir: " & p.packageDir & "\n"
  if p.packageExists:
    result.add "    (! package dir already exists — will refuse unless replace=true)\n"
  result.add "  emits:\n"
  result.add "    [sidecar] " & p.headerPath & "\n"
  result.add "    " & p.pubofferPath.relativePath(p.packageDir) & "\n"
  result.add "    " & p.zipmountPath.relativePath(p.packageDir) & "\n"
  result.add "    " & p.mergeSltPath.relativePath(p.packageDir) & "\n"
  result.add "    " & p.carsZipPath.relativePath(p.packageDir) & "\n"
  result.add "    " & p.wheelsZipPath.relativePath(p.packageDir) & "\n"
  result.add "  textures: copy=" & $p.texturePlan.sourceCount &
             " splice=" & $p.texturePlan.donorCount &
             " drop=" & $p.texturePlan.droppedCount & "\n"
  var transcodeN, donorOnlyN: int
  for a in p.geometryActions:
    case a.kind
    of dgaTranscode: inc transcodeN
    of dgaDonorOnly: inc donorOnlyN
    of dgaSourceExtra: discard
  result.add "  geometry: transcode=" & $transcodeN &
             " donor-only=" & $donorOnlyN &
             "  (Slice B v2: main carbin spliced, LOD0-only sections donor-passthrough)\n"

# ---- emit ----

proc renamePrefixIn(name, fromPrefix, toPrefix: string): string =
  ## Same casing-preserving rename as portto.nim. Duplicated here to
  ## keep portto_dlc independent of portto's internals; if a third
  ## consumer shows up, extract to a shared module.
  let lc = name.toLowerAscii()
  let needle = fromPrefix.toLowerAscii()
  let idx = lc.find(needle)
  if idx < 0: return name
  let donorOcc = name[idx ..< idx + needle.len]
  let replacement =
    if donorOcc == donorOcc.toLowerAscii(): toPrefix.toLowerAscii()
    else: toPrefix
  result = name[0 ..< idx] & replacement & name[idx + needle.len .. ^1]

proc buildRenames(donorEntries: seq[Entry], donorSlug, newSlug: string):
                  Table[string, string] =
  result = initTable[string, string]()
  if donorSlug == newSlug: return
  for e in donorEntries:
    let renamed = renamePrefixIn(e.name, donorSlug, newSlug)
    if renamed != e.name:
      result[e.name] = renamed

proc collectGeometryEdits(p: DlcPortPlan): Table[string, seq[byte]] =
  ## Build the edits table for `rewriteZipMixedMethod`. Mirrors
  ## `portto.nim:collectEdits` but trimmed to geometry only — the texture
  ## splice path is intentionally not wired yet (the working tree's
  ## per-bucket re-encoded `.xds` files come in via the same mechanism;
  ## leaving it on the TODO list keeps this scaffold focused on package-
  ## tree shape).
  result = initTable[string, seq[byte]]()
  let donorIdx = indexZipEntries(p.donorCarsZip)
  var donorEntryByBase = initTable[string, Entry]()
  for e in donorIdx.entries:
    donorEntryByBase[extractFilename(e.name).toLowerAscii()] = e
  for ga in p.geometryActions:
    case ga.kind
    of dgaTranscode:
      let donorEntry = donorEntryByBase[extractFilename(ga.zipEntryName).toLowerAscii()]
      var donorBytesEntry = extract(p.donorCarsZip, donorEntry)
      let sourceBytes = readFileBytes(ga.sourcePath)
      let r =
        try: transcodeCarbin(sourceBytes, donorBytesEntry, p.targetProfile,
                             mode = tmHybridSplice)
        except CatchableError as e:
          raise newException(DlcPortError,
            "transcode failed for " & ga.zipEntryName & ": " & e.msg)
      stderr.writeLine "    [transcode] " & extractFilename(ga.zipEntryName) &
        ": spliced=" & $r.report.sectionsSpliced &
        " fallback=" & $r.report.sectionsFallback
      if r.report.mode != tmDonorVerbatim:
        result[ga.zipEntryName] = r.bytes
    of dgaDonorOnly, dgaSourceExtra:
      discard

proc zipmountEntry(name, mount: string): string =
  ## One <zip Name="..." Mount="..." AltRootPath="..." ShouldCache="0" />
  ## line. Whitespace mirrors the sample DLC for forward-compat with
  ## anything that pattern-matches on the file.
  result = "   <zip Name=\"" & name & "\" " &
           "Mount=\"" & mount & "\" " &
           "AltRootPath=\"" & mount & "\" ShouldCache=\"0\" /> \n"

proc emitZipmountXml(p: DlcPortPlan): string =
  ## Mounts cars + wheels overlays. Critically does NOT register the
  ## `<dlcId>_pri_99/` merge-overlay dir — FH1 auto-discovers that one
  ## by name pattern. Sample DLC's zipmount.xml omits it too. Audio
  ## CMT/ET/StringTables entries land here when those emitters are
  ## wired.
  result = "<?xml version=\"1.0\" ?> \n<zipmount> \n"
  result.add zipmountEntry("cars_pri_" & $p.dlcId, "game:\\Media\\cars\\")
  result.add zipmountEntry("wheels_pri_" & $p.dlcId, "game:\\Media\\wheels\\")
  result.add "</zipmount> \n"

proc emitMergeSltFile(p: DlcPortPlan): tuple[carId: int; engineId: int;
                                              perTableRows: Table[string, int]] =
  ## Build the per-DLC merge.slt at p.mergeSltPath. Overlays the working
  ## car's cardb.json snippet (captured from the source game at import
  ## time) onto donor's cloned rows, so the new car carries source
  ## values — DisplayName, top speed, engine name, weight, displacement,
  ## etc. — for any column shared between the games. Donor fills in
  ## FH1-only columns the source schema doesn't carry.
  if p.targetGamedb.len == 0 or not fileExists(p.targetGamedb):
    raise newException(DlcPortError,
      "merge.slt build needs target gamedb (target profile must specify " &
      "gamedbPath, and the file must exist): got '" & p.targetGamedb & "'")
  createDir(p.mergeSltPath.parentDir)
  if fileExists(p.mergeSltPath):
    removeFile(p.mergeSltPath)
  let snippet =
    if fileExists(p.workingCar / "cardb.json"):
      try: parseJson(readFile(p.workingCar / "cardb.json"))
      except CatchableError: newJNull()
    else: newJNull()
  # Gather every sibling DLC's merge.slt so the ID gap-fill avoids
  # collisions with already-deployed DLCs (UDLC + earlier ports). Skip
  # our own merge.slt path since that's the file we're rebuilding.
  var siblingSlts: seq[string] = @[]
  if dirExists(p.dlcSlot):
    for kind, dlcDir in walkDir(p.dlcSlot):
      if kind != pcDir: continue
      let patchDir = dlcDir / "Media" / "DLCZips"
      if not dirExists(patchDir): continue
      for kind2, sub in walkDir(patchDir):
        if kind2 != pcDir: continue
        if not sub.extractFilename.endsWith("_pri_99"): continue
        let mergeDir = sub / "Media" / "db" / "patch"
        if not dirExists(mergeDir): continue
        for f in walkFiles(mergeDir / "*.slt"):
          if f != p.mergeSltPath: siblingSlts.add(f)
  result = buildMergeSlt(
    srcGamedb = p.targetGamedb,
    dstMergeSlt = p.mergeSltPath,
    donorMediaName = p.donorSlug,
    newMediaName = p.newSlug,
    dlcId = p.dlcId,
    snippet = snippet,
    siblingDlcSlts = siblingSlts,
    forcedCarId = p.forcedCarId,
    forcedEngineId = p.forcedEngineId)

proc extractZipToDir(srcZipPath, outDir: string,
                      renames: Table[string, string],
                      edits: Table[string, seq[byte]]) =
  ## Decompress every entry from `srcZipPath` and write it loose into
  ## `outDir/<renamed-entry-name>`. Entries listed in `edits` use the
  ## edit's bytes; everything else is decompressed from the zip.
  ##
  ## FH1's DLC mount layer expects loose extracted files at
  ## `cars_pri_<id>/<MediaName>/...` rather than a `.zip` (verified
  ## empirically: ResolvePath traces show FH1 walking the loose tree).
  ## So even though our zip has correct entries, FH1 only consumes
  ## the loose form for new MediaNames. Base-game cars (in
  ## media/cars/<MediaName>.zip) work via the zip mount because FH1
  ## special-cases that path, but cars_pri_<id>/ is loose-only.
  createDir(outDir)
  let entries = listEntries(srcZipPath)
  for e in entries:
    let outName = if e.name in renames: renames[e.name] else: e.name
    # Strip directory prefixes — FH1 expects flat paths in the loose
    # car dir. Donor zips already use flat names; this is just
    # defensive against any with a "/" path. (Note: a few have
    # subdirs like LiveryMasks/back.tga; preserve those.)
    let outPath = outDir / outName
    createDir(outPath.parentDir)
    let bytes =
      if e.name in edits: edits[e.name]
      else: extract(srcZipPath, e)
    writeAllBytes(outPath, bytes)

proc emitWheelsZip(p: DlcPortPlan) =
  ## Wheels overlay: extract donor's archive into a loose file tree at
  ## `wheels_pri_<id>/<MediaName>/...`. Renames `<donorSlug>_*` →
  ## `<newSlug>_*` per the prefix-rename map. Donor-bin passthrough
  ## applies — never synthesize wheel content.
  if not fileExists(p.donorWheelsZip): return
  let donorEntries = listEntries(p.donorWheelsZip)
  let renames = buildRenames(donorEntries, p.donorSlug, p.newSlug)
  extractZipToDir(p.donorWheelsZip, p.wheelsZipPath, renames,
                   initTable[string, seq[byte]]())

proc emitCarsZip(p: DlcPortPlan) =
  ## Cars overlay: extract donor's archive (loose files), apply texture
  ## + transcoded-carbin edits over the loose tree.
  let edits = collectGeometryEdits(p)
  let donorEntries = listEntries(p.donorCarsZip)
  let renames = buildRenames(donorEntries, p.donorSlug, p.newSlug)
  extractZipToDir(p.donorCarsZip, p.carsZipPath, renames, edits)

proc emitPuboffer(p: DlcPortPlan) =
  createDir(p.pubofferPath.parentDir)
  let bytes = cast[seq[byte]](PubofferMarker)
  writeAllBytes(p.pubofferPath, bytes)

proc buildXeniaHeader(displayName, packageId, titleIdHex: string): seq[byte] =
  ## Build the 332-byte sidecar `.header` xenia uses to populate
  ## display-name metadata in `XamContentCreateEnumerator`. Without one,
  ## the package enumerates with the package id as its display name and
  ## (more importantly) FH1 doesn't recognize the DLC's license, so its
  ## merge.slt rows aren't applied to runtime queries. Format reverse-
  ## engineered from the working sample DLC's
  ## `Headers/00000002/4D5309C900000729.header`:
  ##   0x000  u32 BE  version flag (always 1)
  ##   0x004  u32 BE  content type (2 = DLC)
  ##   0x008  80B     display name in UTF-16BE, null-terminated, padded
  ##   0x058..0x100   zeros
  ##   0x100  8B      zeros
  ##   0x108  16B     ASCII package id (16 hex chars), null-padded
  ##   0x118..0x140   zeros
  ##   0x140  4B      title id (raw bytes, e.g. `4D 53 09 C9`)
  ##   0x144  8B      zeros
  ## Total 332 bytes (0x14C).
  result = newSeq[byte](332)
  # version + type
  result[0] = 0; result[1] = 0; result[2] = 0; result[3] = 1
  result[4] = 0; result[5] = 0; result[6] = 0; result[7] = 2
  # display name (UTF-16BE, max 39 ASCII chars + terminator in 80 bytes)
  var nameOff = 0x08
  for c in displayName:
    if nameOff >= 0x08 + 78: break
    result[nameOff] = 0
    result[nameOff + 1] = byte(c)
    nameOff += 2
  # null terminator (already zero-initialized)
  # ASCII package id
  for i, c in packageId:
    if i >= 16: break
    result[0x108 + i] = byte(c)
  # title id raw bytes
  if titleIdHex.len >= 8:
    result[0x140] = byte(parseHexInt(titleIdHex[0 ..< 2]))
    result[0x141] = byte(parseHexInt(titleIdHex[2 ..< 4]))
    result[0x142] = byte(parseHexInt(titleIdHex[4 ..< 6]))
    result[0x143] = byte(parseHexInt(titleIdHex[6 ..< 8]))

proc emitXeniaHeader(p: DlcPortPlan) =
  createDir(p.headerPath.parentDir)
  let displayName = "Carbin Garage: " & p.newSlug
  let bytes = buildXeniaHeader(displayName, p.packageId,
                                p.targetProfile.titleId.toUpperAscii())
  writeAllBytes(p.headerPath, bytes)

proc emitZipmount(p: DlcPortPlan) =
  createDir(p.zipmountPath.parentDir)
  writeFile(p.zipmountPath, emitZipmountXml(p))

proc emitMergeSlt(p: DlcPortPlan) =
  discard emitMergeSltFile(p)

proc executePortToDlc*(p: DlcPortPlan, replace: bool = false,
                       skipMergeSlt: bool = false) =
  ## Order:
  ##   1. Refuse if package dir exists and replace=false.
  ##   2. (replace) wipe package dir.
  ##   3. Mkdir tree, emit puboffer + zipmount.
  ##   4. Emit cars zip + wheels zip.
  ##   5. Emit merge.slt (skippable for scaffold inspection).
  ##
  ## `skipMergeSlt` exists so the rest of the layout can be inspected
  ## on disk before the merge.slt builder lands. Real ports MUST run with
  ## skipMergeSlt=false — the new car is unreachable in-game without it.
  if p.packageExists and not replace:
    raise newException(DlcPortError,
      "package already exists at " & p.packageDir &
      " (pass replace=true to overwrite, or call uninstallPortToDlc first)")
  if p.packageExists and replace:
    removeDir(p.packageDir)
  createDir(p.packageDir)
  emitXeniaHeader(p)
  emitPuboffer(p)
  emitZipmount(p)
  emitCarsZip(p)
  emitWheelsZip(p)
  if not skipMergeSlt:
    emitMergeSlt(p)

proc uninstallPortToDlc*(p: DlcPortPlan) =
  ## Remove the entire package directory and its sidecar header file.
  ## Safe to call on a partial / scaffold-state package
  ## (skipMergeSlt=true). Leaves siblings under `00000002/` untouched.
  if dirExists(p.packageDir):
    removeDir(p.packageDir)
  if fileExists(p.headerPath):
    removeFile(p.headerPath)
