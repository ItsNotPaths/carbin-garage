## port-to-dlc: emit a Forza DLC package for a new car. This is THE
## shipping path for cross-game / new-car ports (in-game validated).
## Same-game overwrite of an existing slug goes through
## `orchestrator/portto.nim` instead; the CLI verb picks between them.
##
## Two package layouts, selected by the target profile:
##   - fh1 (default): the layout described below — cars/wheels overlays
##     as sibling `*_pri_<dlcId>` dirs, header sidecar, donor audio
##     CMT/ET splice.
##   - fm4 (`plan.fm4Layout`): everything rides inside the ONE merge
##     overlay dir — geometry loose at `<dlcId>_pri_99/Media/cars/<NAME>/`
##     next to the merge.slt, empty zipmount, an empty `LicenseMasks`
##     sentinel, lowercase package dir, and NO header / wheels / audio
##     pieces (validated in-game without them via
##     probe/fm4_merge_probe.py --geometry-src, 2026-05-28 + 2026-07-10).
##
## ## Why DLC packaging
##
## In-game testing on 2026-05-01 ruled out cross-game `port-to` via direct
## `gamedb.slt` edits. The audio engine's init-time SQL chain returns 0
## rows for our newly-cloned car, SQL CE substitutes its error string
## into asset paths, and the open-world spawn nukes the global render
## pipeline. Working car-add mods all package as DLC: a separate
## `<id>00_merge.slt` is merged into the live DB at boot, exercising a
## code path the audio subsystem honors.
##
## ## DLC package layout (decoded from the example at
##   xenia_canary_windows/content/0000000000000000/4D5309C9/00000002/4D5309C900000729)
##
## ```
## <packageDir>/                                       # named <TitleID><dlcId 8-digit>
## └── Media/
##     ├── <dlcId>.puboffer                            # 3-byte marker (CR LF LF)
##     └── DLCZips/
##         ├── zipmount.xml                            # declares mount points
##         ├── <dlcId>_pri_99/                         # merge overlay (auto-discovered)
##         │   └── Media/
##         │       ├── db/patch/<dlcId>00_merge.slt    # 56-table partial gamedb
##         │       └── Audio/Cars/...                  # donor CMT/ET XMLs, renamed
##         ├── cars_pri_<dlcId>/<MediaName>/           # geometry, LOOSE files
##         └── wheels_pri_<dlcId>/<MediaName>/         # wheels, LOOSE files
## ```
##
## Plus a `.header` sidecar at `<TitleID>/Headers/00000002/<packageId>.header`
## so xenia enumerates the package with a display name and FH1 honors its
## license (merge.slt rows are ignored without it).
##
## Mount point semantics (from sample's zipmount.xml):
##   - `cars_pri_<id>`     mounts at `game:\Media\cars\`
##   - `wheels_pri_<id>`   mounts at `game:\Media\wheels\`
##   - `_pri_<NNN>` priority encoding: higher number = higher priority
##   - the `<dlcId>_pri_99/` overlay dir is NOT registered in
##     zipmount.xml — FH1 auto-discovers it by name pattern.
##
## ## Pipeline (executePortToDlc)
##
##   1. header sidecar + puboffer + zipmount.xml
##   2. cars overlay: donor archive extracted LOOSE, with texture edits
##      (working/<slug>/textures/*.xds) and transcoded carbins
##      (hybrid splice; optional glTF-sourced positions via
##      `--pack-from-gltf`; part drop/replace via part_edits.json)
##      spliced over it, entry names re-prefixed donor→new slug
##   3. wheels overlay: donor wheels extracted loose + renamed
##   4. donor audio CMT/ET XMLs copied + renamed into the merge overlay
##   5. `<dlcId>00_merge.slt` built from the target gamedb (donor rows
##      cloned, IDs re-allocated, source cardb.json snippet overlaid)

import std/[hashes, json, options, os, sets, strutils, tables]
import ./port_common
import ../core/ioutil
import ../core/profile
import ../core/mounts
import ../core/zip21
import ../core/texture_port
import ../core/carbin/transcode
import ../core/carbin/gltf_pack
import ../core/carbin/section_edit
import ../core/carbin/model as carbin_model
import ../core/carbin/parser as carbin_parser
import ../core/physicsdef
export TranscodeOptions, defaultTranscodeOptions
import ../core/dlc_merge

type
  DlcPortError* = object of CatchableError

  DlcGeometryActionKind* = enum
    dgaTranscode       ## both source + donor have this carbin → transcode
    dgaDonorOnly       ## donor has it, source doesn't → keep donor's bytes

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

    # Layout flavor
    fm4Layout*:     bool           # true = FM4 package shape (see module doc)

    # Per-package output paths (under packageDir/Media/...)
    pubofferPath*:  string
    dlcZipsDir*:    string         # packageDir/Media/DLCZips
    zipmountPath*:  string         # dlcZipsDir/zipmount.xml
    licenseMasksPath*: string      # packageDir/Media/LicenseMasks (fm4 only, else "")
    mergeOverlayDir*: string       # dlcZipsDir/<dlcId>_pri_99
    mergeSltPath*:  string         # mergeOverlayDir/Media/db/patch/<dlcId>00_merge.slt
    carsOutDir*:    string         # fh1: dlcZipsDir/cars_pri_<dlcId>/<newSlug>/
                                    # fm4: mergeOverlayDir/Media/cars/<newSlug>/
    wheelsOutDir*:  string         # dlcZipsDir/wheels_pri_<dlcId>/<newSlug>/ (fh1 only, else "")
    headerPath*:    string         # contentRoot/<profileId>/<TitleID>/Headers/00000002/<packageId>.header
                                    # (fh1 only, else "")

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
  DefaultProfileId* = "0000000000000000"
    ## Xenia's "no profile / global" slot. DLCs placed here apply for any
    ## profile; the example DLC at `4D5309C900000729` lives here.
  DlcContentTypeDir* = "00000002"
    ## Xenia content type for "Marketplace Content" (DLC). Sibling to
    ## `00000001` (saved games). Always 8 hex.
  CarbinGarageHeaderPrefix* = "Carbin Garage: "
    ## Display-name prefix written into every header sidecar by
    ## `emitXeniaHeader`. Also used by `dlc_clear` to recognise our
    ## packages on disk so bulk-clear never touches third-party DLC.
  DefaultMergePriority = 99
    ## Priority for the per-package overlay. Sample DLC uses 99; higher
    ## values win on collision in zipmount mounting order.
  PubofferMarker = "\r\n\n"
    ## 3-byte marker observed in the sample DLC's `Media/729.puboffer`.
    ## Treated as opaque content for now (PLAN open question §2).
  PubofferMarkerFm4 = " \r\n"
    ## FM4's 3-byte variant (0x20 0x0D 0x0A) — observed in first-party
    ## install-disc packs and used by the validated probe pack.

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
  let fm4Layout = targetProfile.id == "fm4"
  let packageId = packageIdFor(targetProfile, dlcId)
  let titleIdDir = contentRoot / profileId / targetProfile.titleId.toUpperAscii()
  let dlcSlot = titleIdDir / DlcContentTypeDir
  # FM4 package dirs are lowercase on disk (`4d530910000000NN` — both the
  # install-disc first-party packs and the validated probe pack); FH1's
  # sample DLC dir is uppercase. Case matters on a Linux host filesystem.
  let packageDir = dlcSlot / (if fm4Layout: packageId.toLowerAscii()
                              else: packageId)
  let dlcZipsDir = packageDir / "Media" / "DLCZips"
  # Overlay dir naming: `<dlcId>_pri_<priority>` (NOT packageId). The
  # FH1 sample DLC at 4D5309C900000729 uses `729_pri_99/`, not the full
  # 16-hex package id. The runtime auto-discovers this dir by name
  # pattern; zipmount.xml does NOT register it (verified against
  # sample's zipmount.xml). FM4 zero-pads the dlcId to at least 4 digits
  # (`0099_pri_99` in the validated probe pack).
  let overlayDirName =
    if fm4Layout: align($dlcId, 4, '0') & "_pri_" & $DefaultMergePriority
    else: $dlcId & "_pri_" & $DefaultMergePriority
  let mergeOverlayDir = dlcZipsDir / overlayDirName

  var plan = DlcPortPlan(
    workingCar: abs, sourceSlug: slug,
    targetGameId: targetProfile.id, targetProfile: targetProfile,
    donorSlug: donorSlug, newSlug: finalSlug,
    contentRoot: contentRoot, profileId: profileId,
    titleIdDir: titleIdDir, dlcSlot: dlcSlot,
    dlcId: dlcId, forcedCarId: forcedCarId, forcedEngineId: forcedEngineId,
    packageId: packageId, packageDir: packageDir,
    fm4Layout: fm4Layout,
    pubofferPath: packageDir / "Media" / ($dlcId & ".puboffer"),
    dlcZipsDir: dlcZipsDir,
    zipmountPath: dlcZipsDir / "zipmount.xml",
    licenseMasksPath:
      (if fm4Layout: packageDir / "Media" / "LicenseMasks" else: ""),
    mergeOverlayDir: mergeOverlayDir,
    mergeSltPath: mergeOverlayDir / "Media" / "db" / "patch" /
                  ($dlcId & "00_merge.slt"),
    # FM4 reads the loose car overlay from INSIDE the merge overlay dir
    # (mounted whole at game:\), so geometry sits next to db/patch/.
    # FH1 uses a dedicated cars_pri_<dlcId> sibling registered in
    # zipmount.xml.
    carsOutDir:
      (if fm4Layout: mergeOverlayDir / "Media" / "cars" / finalSlug
       else: dlcZipsDir / ("cars_pri_" & $dlcId) / finalSlug),
    wheelsOutDir:
      (if fm4Layout: ""
       else: dlcZipsDir / ("wheels_pri_" & $dlcId) / finalSlug),
    headerPath:
      (if fm4Layout: ""
       else: titleIdDir / "Headers" / DlcContentTypeDir /
             (packageId & ".header")),
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
  let donorEntries = listEntries(donorZip)
  var donorTextures: seq[string] = @[]
  for e in donorEntries:
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
  # Source files are matched by LOWERCASED basename: importwc preserves
  # each game's on-disk casing (FM4 entries are lowercase, FH1 entries
  # mixed-case like `BMW_1M_11_caliperLF_LOD0.carbin`), so a literal
  # fileExists probe misses FH1-sourced cars on a case-sensitive FS.
  let workingGeomDir = abs / "geometry"
  var workingGeomByBase = initTable[string, string]()
  if dirExists(workingGeomDir):
    for kind, p in walkDir(workingGeomDir):
      if kind != pcFile: continue
      workingGeomByBase[extractFilename(p).toLowerAscii()] = p
  for e in donorEntries:
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
    var sourcePath = ""
    for key in [sourceBaseGuess, donorBaseLc]:
      if key in workingGeomByBase:
        sourcePath = workingGeomByBase[key]; break
    if sourcePath.len > 0:
      plan.geometryActions.add(DlcGeometryAction(
        kind: dgaTranscode, zipEntryName: e.name, sourcePath: sourcePath,
        note: "hybrid splice from working source onto donor scaffold"))
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
  if p.headerPath.len > 0:
    result.add "    [sidecar] " & p.headerPath & "\n"
  result.add "    " & p.pubofferPath.relativePath(p.packageDir) & "\n"
  result.add "    " & p.zipmountPath.relativePath(p.packageDir) & "\n"
  if p.licenseMasksPath.len > 0:
    result.add "    " & p.licenseMasksPath.relativePath(p.packageDir) & "\n"
  result.add "    " & p.mergeSltPath.relativePath(p.packageDir) & "\n"
  result.add "    " & p.carsOutDir.relativePath(p.packageDir) & "\n"
  if p.wheelsOutDir.len > 0:
    result.add "    " & p.wheelsOutDir.relativePath(p.packageDir) & "\n"
  result.add "  textures: copy=" & $p.texturePlan.sourceCount &
             " splice=" & $p.texturePlan.donorCount &
             " drop=" & $p.texturePlan.droppedCount & "\n"
  var transcodeN, donorOnlyN: int
  for a in p.geometryActions:
    case a.kind
    of dgaTranscode: inc transcodeN
    of dgaDonorOnly: inc donorOnlyN
  result.add "  geometry: transcode=" & $transcodeN &
             " donor-only=" & $donorOnlyN &
             "  (main carbin spliced; lod0/cockpit donor-passthrough)\n"

# ---- emit ----

proc collectGeometryEdits(p: DlcPortPlan;
                          options: TranscodeOptions): Table[string, seq[byte]] =
  ## Build the edits table for `rewriteZipMixedMethod`. Mirrors
  ## `portto.nim:collectEdits`. Both texture splice and geometry
  ## transcode produce edits keyed on the donor zip's entry names so
  ## the rewriter can match-and-replace.
  ##
  ## Texture plan handling:
  ##   - topCopySource: read source's `.xds` from working/<slug>/textures/
  ##     and replace donor's same-bucket entry. Bucket is matched by
  ##     lowercased basename (donor may carry the entry under a different
  ##     casing — e.g. FH1 `headlight_LOD0.xds` vs FM4 `headlight_lod0.xds`).
  ##   - topSpliceDonor: donor passthrough — rewriter does this for free.
  ##   - topDropExtra: same — source-only buckets aren't in donor, nothing
  ##     to drop.
  result = initTable[string, seq[byte]]()
  let donorEntries = listEntries(p.donorCarsZip)
  var donorEntryByBase = initTable[string, Entry]()
  for e in donorEntries:
    donorEntryByBase[extractFilename(e.name).toLowerAscii()] = e

  # working/<slug>/car.gltf, loaded ONCE and shared by both consumers:
  # the transcode path (only when options.packFromGltf — exported
  # geometry positions come from the editable glTF rather than the
  # importee's original carbin pool) and the part add/replace pass
  # below (always, when the file exists). One doc serves all carbins
  # (importwc emits every carbin's sections into one glTF). On any
  # load failure we fall back to the binary-splice path.
  var gltfDoc = none(GltfDoc)
  let gltfPath = p.workingCar / "car.gltf"
  if fileExists(gltfPath):
    try: gltfDoc = some(loadGltfDoc(gltfPath))
    except CatchableError as e:
      stderr.writeLine "    [transcode] glTF load failed (" & e.msg &
        "); falling back to binary splice"
  let gDoc = if options.packFromGltf: gltfDoc else: none(GltfDoc)
  if options.packFromGltf and gltfDoc.isNone:
    stderr.writeLine "    [transcode] packFromGltf set but no usable " &
      gltfPath & "; falling back to binary splice"

  # Textures (Stage 3 § 3.3): wire texture splice into emit. The plan's
  # `ops` list was built by planTexturePort during planPortToDlc; here
  # we consume it. CANONICAL bytes live at working/<slug>/textures/<bucket>.xds
  # — the .png sidecars from Stage 1 are for inspection only and are NOT
  # used here.
  let workingTexDir = p.workingCar / "textures"
  for op in p.texturePlan.ops:
    case op.kind
    of topCopySource:
      # `*_lod0` texture buckets pair with the lod0/cockpit geometry,
      # which ships donor-verbatim (splice gate below). Painting the
      # SOURCE car's lod0 textures onto the DONOR's meshes mismaps every
      # UV (messy interior — S65-on-SL65, 2026-07-10). Keep donor's
      # lod0 texture set so texture and geometry stay consistent.
      if not options.lod0SpliceCrossCar and
         op.targetName.toLowerAscii().endsWith("_lod0.xds"):
        stderr.writeLine "    [texture] " & op.targetName &
          " — donor verbatim (pairs with donor-verbatim lod0/cockpit)"
        continue
      let srcPath = workingTexDir / op.sourceName
      if not fileExists(srcPath):
        stderr.writeLine "    [texture] missing source: " & srcPath & " (skipped)"
        continue
      let bytes = readFileBytes(srcPath)
      let donorKey = op.targetName.toLowerAscii()
      let donorEntryName =
        if donorKey in donorEntryByBase: donorEntryByBase[donorKey].name
        else: op.targetName  # donor lacks it; rewriter doesn't add new
                              # entries, so this falls through silently.
                              # Tracked: same Slice B concern as portto.nim.
      result[donorEntryName] = bytes
    of topSpliceDonor, topDropExtra:
      discard

  # Physics dimensions (fm4 targets). FM4 reads per-car suspension +
  # collision geometry from `physics/maxdata.xml` (Misc Wheelbase /
  # FrontTrackOuter / RearTrackOuter / ride heights + Collision
  # BoundingBox + CollSpheres). Donor's file places wheels and hitbox at
  # DONOR dimensions — visibly wrong for cross-car ports (2012 S65 body
  # on SL65 donor: wheels inboard, hitbox 0.7m short; 2026-07-10). The
  # working car carries the source's MAXData.xml in the same schema
  # family, so ship that instead. FH1 targets keep donor's: FH1 gets
  # its physics from the compiled physicsdefinition.bin (donor
  # passthrough policy), not the XML.
  if p.fm4Layout:
    var workingMax = ""
    for kind, f in walkDir(p.workingCar):
      if kind != pcFile: continue
      if extractFilename(f).toLowerAscii() == "maxdata.xml":
        workingMax = f; break
    if workingMax.len > 0 and "maxdata.xml" in donorEntryByBase:
      result[donorEntryByBase["maxdata.xml"].name] = readFileBytes(workingMax)
      stderr.writeLine "    [physics] maxdata.xml <- working source " &
        "(wheelbase/track/collision at source dimensions)"

  # Geometry.
  for ga in p.geometryActions:
    case ga.kind
    of dgaTranscode:
      let donorEntry = donorEntryByBase[extractFilename(ga.zipEntryName).toLowerAscii()]
      var donorBytesEntry = extract(p.donorCarsZip, donorEntry)
      let sourceBytes = readFileBytes(ga.sourcePath)

      # Cockpit + lod0 carbins: if donor has any section name source
      # doesn't, splicing source vertices into a donor frame leaves
      # donor-only sections (cagerace, headlightL, headlightR, etc.)
      # embedded with donor-specific texture/material refs that don't
      # exist in our DLC overlay. xenia loops indefinitely on the
      # missing refs and crashes the heap allocator
      # (BaseHeap::Alloc page count too big). Detect this mismatch
      # and ship donor verbatim instead — visually wrong (donor's
      # cockpit interior, donor's lod0 mesh) but the load completes.
      # Main carbin always splices because the body section's LOD pool
      # is what carries the visible body geometry; this gate is
      # specifically for the supporting LOD0/cockpit slots.
      let baseLc = extractFilename(ga.zipEntryName).toLowerAscii()
      let isLod0 = baseLc.endsWith("_lod0.carbin")
      let isCockpit = baseLc.endsWith("_cockpit.carbin")
      let isCockpitOrLod0 = isLod0 or isCockpit
      # LOD0/cockpit splice has been broken since 2026-05-05 for ALL
      # cross-game cases:
      #   - cross-car: drops xenia into BaseHeap heap-loop
      #     or MSVC C++ exception (E06D7363) on autoshow load
      #   - same-car cross-game: hangs xenia indefinitely on autoshow
      #     (no exception logged, asset re-resolve loop)
      # The previously-noted "alfa autoshow shows source car" claim was a
      # false signal — the donor was alfa, so donor-verbatim ALSO showed
      # the alfa, masking the broken splice. Until the splice is rebuilt
      # to produce FH1-loadable bytes for cross-game pairs, ship donor
      # verbatim by default. Splice attempts gated behind
      # `--lod0-splice-cross-car` for development.
      let crossCarTryLod0 = options.lod0SpliceCrossCar and isLod0
      if isCockpitOrLod0 and not crossCarTryLod0:
        stderr.writeLine "    [transcode] " & extractFilename(ga.zipEntryName) &
          " — shipping donor verbatim (lod0/cockpit splice currently broken cross-game)"
        # Don't add to result map → rewriter passes donor bytes through.
        continue

      let r =
        try: transcodeCarbin(sourceBytes, donorBytesEntry, p.targetProfile,
                             mode = tmHybridSplice, options = options,
                             gltfDoc = gDoc)
        except CatchableError as e:
          raise newException(DlcPortError,
            "transcode failed for " & ga.zipEntryName & ": " & e.msg)
      stderr.writeLine "    [transcode] " & extractFilename(ga.zipEntryName) &
        ": spliced=" & $r.report.sectionsSpliced &
        " fallback=" & $r.report.sectionsFallback &
        " gaps=" & $r.report.gapsPreserved &
        " lod0Spliced=" & $r.report.lod0Spliced
      if r.report.mode != tmDonorVerbatim:
        result[ga.zipEntryName] = r.bytes
    of dgaDonorOnly:
      discard

  # ---- Part drop / replace (Phase 2) ----
  # Operates on the MAIN body carbin only. REPLACE: any glTF mesh tagged
  # lodKind=main whose name is not a donor section is synthesized into an
  # existing donor slot picked via part_edits.json's addName map
  # (APPENDING a section the donor lacks crashes in-game unconditionally —
  # docs/FH1_PART_EDITING.md §3). DROP: section names listed in
  # working/<slug>/part_edits.json {"drop":[...]}.
  block partEdits:
    var dropSet = initHashSet[string]()
    var addName = initTable[string, string]()  # gltf mesh name -> carbin section name
    var boxScale = 1.0'f32   # enlarge the donor target bbox a synthesized part fits into
    var partOffset = [0.0'f32, 0.0'f32, 0.0'f32]   # shift a synthesized part in world
    var subName = ""   # template subsection to clone (its material binding) — "" = ss0
    let sidecar = p.workingCar / "part_edits.json"
    if fileExists(sidecar):
      try:
        let pj = parseJson(readFile(sidecar))
        if pj.hasKey("drop"):
          for n in pj["drop"].getElems: dropSet.incl n.getStr
        if pj.hasKey("addName"):
          for k, v in pj["addName"].pairs: addName[k] = v.getStr
        if pj.hasKey("boxScale"): boxScale = pj["boxScale"].getFloat.float32
        if pj.hasKey("offset") and pj["offset"].len >= 3:
          for a in 0 .. 2: partOffset[a] = pj["offset"][a].getFloat.float32
        if pj.hasKey("subName"): subName = pj["subName"].getStr
      except CatchableError as e:
        stderr.writeLine "    [parts] part_edits.json parse failed: " & e.msg

    # Locate the main body carbin entry (not stripped/lod0/cockpit/caliper/rotor).
    var mainEntry = ""
    for e in donorEntries:
      if not isCarbinName(e.name): continue
      let bl = extractFilename(e.name).toLowerAscii()
      if bl.startsWith("stripped_"): continue
      if bl.endsWith("_lod0.carbin") or bl.endsWith("_cockpit.carbin"): continue
      if bl.contains("caliper") or bl.contains("rotor"): continue
      mainEntry = e.name; break
    if mainEntry.len == 0: break partEdits

    # Nothing to do?
    if dropSet.len == 0 and gltfDoc.isNone: break partEdits

    var mainBytes =
      if mainEntry in result: result[mainEntry]
      else: extract(p.donorCarsZip, donorEntryByBase[extractFilename(mainEntry).toLowerAscii()])
    var info: carbin_model.CarbinInfo
    try: info = carbin_parser.parseFm4Carbin(mainBytes)
    except CatchableError as e:
      stderr.writeLine "    [parts] main carbin parse failed; skipping: " & e.msg
      break partEdits

    var donorNames = initHashSet[string]()
    for s in info.sections: donorNames.incl s.name

    # Template: a CLEAN body section (permCount==0 && cnt2==0) with geometry
    # + subsections — glass sections carry permutation/index blocks that
    # reference their own geometry and ERANGE when cloned onto a new mesh.
    # Prefer the largest clean section for a robust scaffold.
    var tplIdx = -1
    var tplBest = -1
    for i, s in info.sections:
      if s.lodVerticesCount == 0'u32 or s.subsections.len == 0: continue
      let hc = sectionHeaderCounts(mainBytes, s)
      if hc.perm != 0'u32 or hc.cnt2 != 0'u32: continue
      if tplBest < 0 or int(s.lodVerticesCount) > tplBest:
        tplBest = int(s.lodVerticesCount); tplIdx = i
    if tplIdx < 0:   # no clean section — fall back to any (best effort)
      for i, s in info.sections:
        if s.lodVerticesCount > 0'u32 and s.subsections.len > 0: tplIdx = i; break

    var replaceTbl = initTable[string, seq[byte]]()  # in-place section swaps

    if gltfDoc.isSome and tplIdx >= 0:
      for meshName in gltfDoc.get.mainMeshNames:
        if meshName in donorNames: continue          # existing part → Phase 1
        let mg = gltfDoc.get.meshGeometry(meshName)
        if not mg.found or mg.indices.len < 3: continue
        # Section name: the game looks up each section in a fixed part-name
        # registry, so a new part must use a known name. `addName` maps the
        # glTF mesh → carbin section. `addName` maps the mesh to the donor
        # section name it should REPLACE (e.g. {"penger":"body"}). The new
        # part MUST target an existing donor slot: APPENDING a section the
        # donor lacks crashes in-game unconditionally — the per-car geometry
        # budget is allocated by the engine from the donor and can't be grown
        # via our files (see docs/FH1_PART_EDITING.md §3). So a mesh whose
        # target name isn't a donor section is skipped with a warning rather
        # than silently shipping a carbin that crashes on load.
        let secName = addName.getOrDefault(meshName, meshName)
        if secName notin donorNames:
          stderr.writeLine "    [parts] skip '" & meshName &
            "': no donor slot named '" & secName &
            "' — appending a new part crashes in-game; map it to an existing" &
            " slot with addName (e.g. \"" & meshName & "\":\"body\")"
          continue
        # Clone the target section as the structural template (its valid
        # per-section metadata + material binding). It must be a CLEAN section
        # (permCount==0 && cnt2==0); glass slots carry geometry-referencing
        # blocks that ERANGE when cloned — fall back to the largest clean one.
        var tpl = info.sections[tplIdx]
        for s in info.sections:
          if s.name == secName:
            let hc = sectionHeaderCounts(mainBytes, s)
            if hc.perm == 0'u32 and hc.cnt2 == 0'u32: tpl = s
            break
        try:
          # glTF positions are already world-space → scale 1, place 0; size and
          # position come from boxScale/partOffset (the written transform).
          var subIdx = 0
          if subName.len > 0:
            for si, ssx in tpl.subsections:
              if ssx.name == subName: subIdx = si; break
          let sec = synthSectionFromMesh(mainBytes, tpl, mg.pos, mg.uv, mg.normal,
            mg.indices, secName, boxScale, partOffset, subIdx)
          # Replace IN PLACE (keeps ordinal position; never makes the new part
          # the last section, whose tail has no next-marker to delimit it).
          replaceTbl[secName] = sec
          dropSet.excl secName
          stderr.writeLine "    [parts] ~replace '" & secName & "' with '" &
            meshName & "' (" & $(mg.pos.len div 3) & " v, " &
            $(mg.indices.len div 3) & " tris)"
        except CatchableError as e:
          stderr.writeLine "    [parts] synth '" & meshName & "' failed: " & e.msg

    if dropSet.len == 0 and replaceTbl.len == 0: break partEdits
    let pe = applyPartEdits(mainBytes, info, dropSet, @[], replaceTbl)
    if pe.ok:
      result[mainEntry] = pe.bytes
      var droppedReal = 0
      for n in dropSet:
        if n in donorNames: inc droppedReal
      stderr.writeLine "    [parts] main carbin: -" & $droppedReal &
        " dropped, ~" & $replaceTbl.len & " replaced (partCount " &
        $info.partCountDeclared & " -> " &
        $(info.sections.len - droppedReal) & ")"
    else:
      stderr.writeLine "    [parts] applyPartEdits skipped: " & pe.msg

  # No-hitboxes mode (`exportHitboxes = false`): replace donor's
  # physicsdefinition.bin `shapesAndChildren` with a single
  # `numCollisionShapes=0` u32. The runtime allocates zero collision
  # volumes → car drives through walls + off the map. Confirmed
  # 2026-05-10 on R8 cross-car port. This was originally tried as
  # theory #1b for the no-deformation experiment; it suppresses
  # damage but ALSO kills ground collision, so we keep it as its own
  # toggle.
  if not options.exportHitboxes:
    let physicsKey = "physicsdefinition.bin"
    if physicsKey in donorEntryByBase:
      let donorEntry = donorEntryByBase[physicsKey]
      let donorBytes = extract(p.donorCarsZip, donorEntry)
      try:
        var pd = parsePhysicsDef(donorBytes)
        let origShapesLen = pd.shapesAndChildren.len
        disableCollisionShapes(pd)
        let patched = emitPhysicsDef(pd)
        result[donorEntry.name] = patched
        stderr.writeLine "    [physicsdef] " & physicsKey &
          ": shapesAndChildren " & $origShapesLen & "B -> " &
          $pd.shapesAndChildren.len & "B (hitboxes OFF)"
      except CatchableError as e:
        stderr.writeLine "    [physicsdef] " & physicsKey &
          ": disable failed (" & e.msg & "), donor passthrough"


proc zipmountEntry(name, mount: string): string =
  ## One <zip Name="..." Mount="..." AltRootPath="..." ShouldCache="0" />
  ## line. Whitespace mirrors the sample DLC for forward-compat with
  ## anything that pattern-matches on the file.
  result = "   <zip Name=\"" & name & "\" " &
           "Mount=\"" & mount & "\" " &
           "AltRootPath=\"" & mount & "\" ShouldCache=\"0\" /> \n"

proc emitZipmountXml(p: DlcPortPlan): string =
  ## fh1: mounts cars + wheels overlays. Critically does NOT register
  ## the `<dlcId>_pri_99/` merge-overlay dir — FH1 auto-discovers that
  ## one by name pattern. Sample DLC's zipmount.xml omits it too.
  ## fm4: EMPTY mount set — the loose car overlay rides inside the
  ## auto-discovered merge overlay dir, so nothing needs registering
  ## (matches the validated probe pack byte-for-byte).
  if p.fm4Layout:
    return "<?xml version=\"1.0\" ?>\n<zipmount>\n</zipmount>\n"
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
  var snippet =
    if fileExists(p.workingCar / "cardb.json"):
      try: parseJson(readFile(p.workingCar / "cardb.json"))
      except CatchableError: newJNull()
    else: newJNull()
  # Overlay carslot.json's user-edited stats onto the snippet's
  # Data_Car row. The L-pane writes by gamedb column name (CurbWeight,
  # NumGears, BaseCost, ...), so each entry is a direct cell override.
  # Without this step the user's edits persist to disk but never reach
  # the merge.slt — the export quietly used the source-import values
  # instead.
  let carslotPath = p.workingCar / "carslot.json"
  if fileExists(carslotPath):
    try:
      let cs = parseJson(readFile(carslotPath))
      if cs.hasKey("stats") and cs["stats"].kind == JObject and
         cs["stats"].len > 0:
        if snippet.isNil or snippet.kind != JObject: snippet = newJObject()
        if not snippet.hasKey("tables"): snippet["tables"] = newJObject()
        let tables = snippet["tables"]
        if not tables.hasKey("Data_Car"):
          tables["Data_Car"] = %*{"rows": [newJObject()]}
        let dcEntry = tables["Data_Car"]
        if not dcEntry.hasKey("rows") or dcEntry["rows"].kind != JArray or
           dcEntry["rows"].len == 0:
          dcEntry["rows"] = %*[newJObject()]
        let row0 = dcEntry["rows"][0]
        for col, v in cs["stats"].pairs: row0[col] = v
    except CatchableError: discard
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
        # Any-priority match: hand-deployed packs (e.g. the FM4 probe at
        # `0098_pri_98`) don't necessarily use priority 99, and missing
        # a sibling merge.slt here means its car/engine IDs aren't
        # blocked during allocation.
        if not sub.extractFilename.contains("_pri_"): continue
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
    forcedEngineId = p.forcedEngineId,
    targetGameId = p.targetProfile.id,
    titleId = p.targetProfile.titleId)

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
    # Entry names are written as-is; any subdir components (e.g.
    # LiveryMasks/back.tga) are preserved via the parentDir createDir.
    let outPath = outDir / outName
    createDir(outPath.parentDir)
    let bytes =
      if e.name in edits: edits[e.name]
      else: extract(srcZipPath, e)
    writeFileBytes(outPath, bytes)

proc emitWheelsZip(p: DlcPortPlan) =
  ## Wheels overlay: extract donor's archive into a loose file tree at
  ## `wheels_pri_<id>/<MediaName>/...`. Renames `<donorSlug>_*` →
  ## `<newSlug>_*` per the prefix-rename map. Donor-bin passthrough
  ## applies — never synthesize wheel content.
  if p.wheelsOutDir.len == 0: return  # fm4 layout ships no wheels overlay
  if not fileExists(p.donorWheelsZip): return
  let donorEntries = listEntries(p.donorWheelsZip)
  let renames = buildRenames(donorEntries, p.donorSlug, p.newSlug)
  extractZipToDir(p.donorWheelsZip, p.wheelsOutDir, renames,
                   initTable[string, seq[byte]]())

proc emitCarsZip(p: DlcPortPlan; options: TranscodeOptions) =
  ## Cars overlay: extract donor's archive (loose files), apply texture
  ## + transcoded-carbin edits over the loose tree.
  let edits = collectGeometryEdits(p, options)
  let donorEntries = listEntries(p.donorCarsZip)
  let renames = buildRenames(donorEntries, p.donorSlug, p.newSlug)
  extractZipToDir(p.donorCarsZip, p.carsOutDir, renames, edits)

proc emitPuboffer(p: DlcPortPlan) =
  createDir(p.pubofferPath.parentDir)
  let marker = if p.fm4Layout: PubofferMarkerFm4 else: PubofferMarker
  writeFileBytes(p.pubofferPath, cast[seq[byte]](marker))

proc emitLicenseMasks(p: DlcPortPlan) =
  ## FM4-only zero-byte sentinel at Media/LicenseMasks. Present in every
  ## first-party install-disc pack and in the validated probe pack;
  ## purpose unknown, shipped for parity.
  if p.licenseMasksPath.len == 0: return
  createDir(p.licenseMasksPath.parentDir)
  writeFileBytes(p.licenseMasksPath, newSeq[byte]())

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
  if p.headerPath.len == 0: return  # fm4: validated in-game with no header
  createDir(p.headerPath.parentDir)
  let displayName = CarbinGarageHeaderPrefix & p.newSlug
  let bytes = buildXeniaHeader(displayName, p.packageId,
                                p.targetProfile.titleId.toUpperAscii())
  writeFileBytes(p.headerPath, bytes)

proc emitZipmount(p: DlcPortPlan) =
  createDir(p.zipmountPath.parentDir)
  writeFile(p.zipmountPath, emitZipmountXml(p))

proc findDonorAudioConfig(contentRoot, donorSlug, suffix: string;
                          allowFallback: bool = true): tuple[path: string; isFallback: bool] =
  ## Search xenia content tree for donor's CMT/ET XML config. These files
  ## live in expansion DLC overlay dirs at:
  ##   <contentRoot>/<profile>/<titleId>/00000002/<package>/Media/DLCZips/CarModelTuning_pri_<id>/<DonorSlug>_CMT.xml
  ## (and a duplicate at .../carmodeltuning/). Stock-game cars keep their
  ## CMT/ET inside the XEX so we won't find them on disk.
  ##
  ## When `allowFallback` is true and donor's exact file isn't on disk,
  ## we fall back to ANY same-manufacturer CMT/ET (matched by 3-letter
  ## prefix — e.g. donor "AST_DBR1_58" → any "AST_*"). This gives the
  ## audio engine a well-formed profile to load instead of crashing on
  ## a missing config. The audio is degraded (different car's engine
  ## tone + exhaust positions) but the load completes. Without this
  ## fallback, stock-car donors (which have CMT/ET baked into the XEX)
  ## leave the DLC without any audio config and the audio thread
  ## crashes (XAUDIO2 GetState read at near-null pointer).
  if not dirExists(contentRoot):
    return ("", false)
  let exactTargets = [donorSlug & suffix, (donorSlug & suffix).toLowerAscii()]
  let mfrPrefix =
    if donorSlug.len >= 4 and donorSlug[3] == '_':
      (donorSlug[0..3]).toLowerAscii()  # e.g. "ast_"
    else: ""
  var fallbackPath = ""
  for path in walkDirRec(contentRoot, yieldFilter = {pcFile},
                          relative = false, checkDir = false):
    if "_PARKED_DLC" in path: continue
    let parent = path.parentDir.lastPathPart.toLowerAscii()
    if not (parent.startsWith("carmodeltuning") or
            parent.startsWith("enginetuning")):
      continue
    let base = path.lastPathPart
    if base in exactTargets: return (path, false)
    if allowFallback and fallbackPath.len == 0 and mfrPrefix.len > 0:
      let baseLc = base.toLowerAscii()
      if baseLc.startsWith(mfrPrefix) and baseLc.endsWith(suffix.toLowerAscii()):
        fallbackPath = path
  return (fallbackPath, fallbackPath.len > 0)

proc emitAudioCmtEt(p: DlcPortPlan) =
  ## Splice donor's CMT/ET XMLs into our DLC overlay, renamed to the new
  ## MediaName. Without this the audio engine crashes on autoshow load
  ## for some cars (Aston DBR1 1958 in particular). With donor's XMLs in
  ## place, the audio engine finds well-formed config and uses donor's
  ## sound profile (engine tone, exhaust positions) for our ported car —
  ## degraded but stable. Real source-audio porting is a separate piece
  ## of work (would need to extract FM4 source audio, port to FH1's audio
  ## container format, etc.).
  ##
  ## Destination paths match the engine's resolve patterns observed in
  ## xenia.log — CMT and ET live in DIFFERENT subdirs even though the
  ## donor pack stores them in sibling dirs:
  ##   CMT  →  Media/Audio/Cars/CarModelTuning/<slug>_CMT.xml
  ##   ET   →  Media/Audio/Cars/Engines/EngineTuning/<slug>_ET.xml
  const Pieces = [
    ("_CMT.xml", "Media/Audio/Cars/CarModelTuning"),
    ("_ET.xml",  "Media/Audio/Cars/Engines/EngineTuning"),
  ]
  for (suffix, relDir) in Pieces:
    let (donorCfg, isFallback) =
      findDonorAudioConfig(p.contentRoot, p.donorSlug, suffix)
    if donorCfg.len == 0:
      stderr.writeLine "    [audio] no " & suffix & " donor candidate " &
        "found under content/, skipping (audio thread may crash)"
      continue
    let dstDir = p.mergeOverlayDir / relDir
    createDir(dstDir)
    let dst = dstDir / (p.newSlug & suffix)
    copyFile(donorCfg, dst)
    let tag = if isFallback: " (FALLBACK — donor exact missing)" else: ""
    stderr.writeLine "    [audio] " & donorCfg.lastPathPart &
      " → " & p.newSlug & suffix & tag

proc executePortToDlc*(p: DlcPortPlan, replace: bool = false,
                       skipMergeSlt: bool = false,
                       options: TranscodeOptions = defaultTranscodeOptions()) =
  ## Atomic install: full-delete then full-write. `synthDlcId(finalSlug)`
  ## is a deterministic hash of the lower-cased slug, so re-exporting the
  ## same car-name targets the *same* `packageDir` and the *same*
  ## `headerPath` every time — that's what makes "our DLC for car X in
  ## game Y" a stable, addressable thing. Replacing means we own that
  ## slot completely, not just whichever files happen to overlap on a
  ## per-name basis.
  ##
  ## Order:
  ##   1. Refuse if package dir exists and replace=false.
  ##   2. (replace) wipe BOTH:
  ##        - `packageDir` (everything under
  ##          `<contentRoot>/<profileId>/<TitleID>/00000002/<packageId>/`)
  ##        - `headerPath` (the sidecar at
  ##          `<contentRoot>/<profileId>/<TitleID>/Headers/00000002/<packageId>.header`)
  ##      This guarantees no orphan state from a previous build —
  ##      stale puboffer markers, partial zipmount.xml, half-written
  ##      merge.slt, all gone before the new layout lands.
  ##   3. Mkdir tree, emit puboffer + zipmount.
  ##   4. Emit cars + wheels loose overlays and donor audio CMT/ET.
  ##   5. Emit merge.slt (skippable for package-tree inspection).
  ##
  ## Real ports MUST run with skipMergeSlt=false — the new car is
  ## unreachable in-game without the merge.slt.
  if p.packageExists and not replace:
    raise newException(DlcPortError,
      "package already exists at " & p.packageDir &
      " (pass replace=true to overwrite, or call uninstallPortToDlc first)")
  if replace:
    if dirExists(p.packageDir): removeDir(p.packageDir)
    if fileExists(p.headerPath): removeFile(p.headerPath)
  createDir(p.packageDir)
  emitXeniaHeader(p)
  emitPuboffer(p)
  emitZipmount(p)
  emitLicenseMasks(p)
  emitCarsZip(p, options)
  emitWheelsZip(p)
  if not p.fm4Layout:
    # FM4 has no on-disk CMT/ET audio config system; the probe pack
    # shipped none and the car loaded with working audio.
    emitAudioCmtEt(p)
  if not skipMergeSlt:
    discard emitMergeSltFile(p)

proc uninstallPortToDlc*(p: DlcPortPlan) =
  ## Remove the entire package directory and its sidecar header file.
  ## Safe to call on a partial / scaffold-state package
  ## (skipMergeSlt=true). Leaves siblings under `00000002/` untouched.
  if dirExists(p.packageDir):
    removeDir(p.packageDir)
  if fileExists(p.headerPath):
    removeFile(p.headerPath)
