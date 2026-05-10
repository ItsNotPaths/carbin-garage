## App-wide GUI state. Populated at startup from existing core/orchestrator
## APIs (loadMounts, loadProfileById, scanLibrary, working/ walk). Verbs that
## mutate the working tree go through gui/verbs.nim — this module is a
## passive view of mounts + per-source car lists + selection.

import std/[os, sets, algorithm, strutils, tables, json]
import ../carbin_garage/core/[profile, mounts, cardb, gltf_runtime,
                              workspace, appconfig, physicsdef]
import ../carbin_garage/orchestrator/scan
import ui/text_input
import ui/scroll
import car_names

type
  ExtractState* = enum esUnextracted, esExtracted

  SourceKind* = enum srcGame, srcDlc, srcWorking

  CarRow* = object
    name*: string          ## slug (zip basename without extension, or working/<slug>)
    sourcePath*: string    ## absolute path to the source archive or working dir
    sizeBytes*: BiggestInt
    extractState*: ExtractState
    selected*: bool        ## multi-select toggle (universal selected set)

  Source* = object
    kind*: SourceKind
    label*: string         ## display name on the dropup tile (FM4, FH1, working/, ...)
    profileId*: string     ## game-id; "" for srcWorking
    folder*: string        ## mount folder, or workingRoot for srcWorking
    cars*: seq[CarRow]
    expanded*: bool
    expandFrac*: float32   ## 0..1 animated
    scrollY*: float32      ## current scroll offset within the expanded panel
    search*: TextInputState ## per-source search filter; matched against car name

  PartRow* = object
    name*: string          ## mesh name from car.gltf (e.g. "hooda", "wheel-fl")
    section*: string       ## carbin section tag ("body", "hooda", "bumperFa", ...)
    lodKind*: string       ## "main" / "lod0" / "cockpit" / "corner"
    visible*: bool
    modified*: bool

  PartsTab* = object
    slug*: string          ## working car this tab represents
    parts*: seq[PartRow]
    pinned*: bool          ## the active car's tab is pinned leftmost
    scrollY*: float32      ## per-tab scroll offset for the parts list
    search*: TextInputState ## per-tab search filter; matched against part name

  GrabSlot* = object
    active*: bool
    donorSlug*: string     ## working/ slug the part lives in
    partName*: string      ## mesh name (e.g. "hooda")
    lodKind*:  string
    section*:  string

  LPaneField* = object
    stat*:        EditableStat
    original*:    string         ## value as parsed from cardb.json (display)
    overridden*:  bool            ## true iff carslot.stats holds a value
    input*:       TextInputState

  LPaneState* = object
    slug*:    string             ## the activeSlug this state was built for
    profile*: string             ## originGame
    fields*:  seq[LPaneField]
    scroll*:  ScrollState
    dirty*:   bool               ## any unsaved edits since the last save?
    search*:  TextInputState     ## filter; matched against stat field + column

  ExportPaletteState* = object
    slug*:        string                  ## activeSlug this palette state was synced for
    newName*:     TextInputState          ## shared MediaName override across all toggled targets
    targetsOn*:   Table[string, bool]     ## profile id → toggled-on
    donors*:      Table[string, string]   ## profile id → donor carname (empty = unbound)
    statusMsg*:   string                  ## last export result (success or error msg)
    statusOk*:    bool                    ## colour cue for statusMsg
    statusS*:     float32                 ## remaining display seconds; 0 = hide

  AppState* = object
    workingRoot*: string
    cfg*: AppConfig
    sources*: seq[Source]
    activeSlug*: string
    partsTabs*: seq[PartsTab]
    activeTab*: int             ## index into partsTabs (0 = pinned slot when populated)
    grab*: GrabSlot
    lpane*: LPaneState
    palette*: ExportPaletteState
    selection*: HashSet[tuple[sourceIdx: int, name: string]]
    settingsOpen*: bool
    settingsFrac*: float32

proc defaultWorkingRoot*(): string =
  ## Prefer working/ next to the binary (release.sh stages it that way), but
  ## fall back to <cwd>/working when running an in-source build from the
  ## project root, and finally to <appDir>/working for fresh installs.
  let beside = getAppDir() / "working"
  if dirExists(beside): return beside
  let cwd = getCurrentDir() / "working"
  if dirExists(cwd): return cwd
  beside

proc computeExtractState(workingRoot, slug: string): ExtractState =
  ## Binary by design: under the DLC-only model we never edit a game-source
  ## archive in place, so a working/ slot is either present or absent.
  if dirExists(workingRoot / slug): esExtracted
  else:                              esUnextracted

proc loadGameSource(m: Mount; workingRoot: string): Source =
  result = Source(kind: srcGame, profileId: m.gameId,
                  label: m.gameId.toUpperAscii(), folder: m.folder)
  let prof =
    try: loadProfileById(m.gameId)
    except CatchableError:
      return  # mount references an unknown profile — leave cars empty

  # 1. Loose .zips in cars/ — these are the immediately-extractable rows.
  # Working/ folders are now created with a `[gameid] PrettyName` default
  # (see gui/car_names.nim:defaultWorkingFolderName), so the extract-state
  # check has to look at that derived path, not the raw carbin slug.
  var byName = initTable[string, CarRow]()
  for slot in scanLibrary(m.folder, prof):
    let workingFolder = defaultWorkingFolderName(slot.name, m.gameId)
    byName[slot.name] = CarRow(
      name: slot.name, sourcePath: slot.path, sizeBytes: slot.sizeBytes,
      extractState: computeExtractState(workingRoot, workingFolder))

  # 2. Every MediaName in gamedb.slt — adds the base-game catalog rows
  # whose carbin lives inside a packed .CAB. They show up greyed out (no
  # sourcePath) so the user sees the full catalog; extraction from the
  # .CAB is a separate pipeline (TODO).
  let dbPath = m.folder / prof.gamedbPath
  for mediaName in listMediaNames(dbPath):
    if not byName.hasKey(mediaName):
      let workingFolder = defaultWorkingFolderName(mediaName, m.gameId)
      byName[mediaName] = CarRow(
        name: mediaName, sourcePath: "", sizeBytes: 0,
        extractState: computeExtractState(workingRoot, workingFolder))

  var rows: seq[CarRow] = @[]
  for k, v in byName: rows.add(v)
  rows.sort(proc (a, b: CarRow): int = cmp(a.name, b.name))
  result.cars = rows

proc loadWorkingSource(workingRoot: string): Source =
  result = Source(kind: srcWorking, profileId: "",
                  label: "working/", folder: workingRoot)
  if not dirExists(workingRoot): return
  var rows: seq[CarRow] = @[]
  for kind, p in walkDir(workingRoot):
    if kind != pcDir: continue
    let slug = extractFilename(p)
    if slug.startsWith('.'): continue
    rows.add(CarRow(name: slug, sourcePath: p, sizeBytes: 0,
                    extractState: esExtracted))
  rows.sort(proc (a, b: CarRow): int = cmp(a.name, b.name))
  result.cars = rows

proc reloadSources*(s: var AppState) =
  ## Rebuild s.sources from disk. Called at startup and after Settings
  ## commits. Combines manual mounts.json overrides with the auto-detected
  ## standard-install layout under cfg.xeniaContent.
  s.sources.setLen(0)
  for m in effectiveMounts(s.cfg.xeniaContent):
    s.sources.add(loadGameSource(m, s.workingRoot))
  s.sources.add(loadWorkingSource(s.workingRoot))

proc initAppState*(workingRoot = ""): AppState =
  result.workingRoot = if workingRoot.len > 0: workingRoot
                       else: defaultWorkingRoot()
  result.cfg = loadAppConfig()
  result.selection = initHashSet[tuple[sourceIdx: int, name: string]]()
  reloadSources(result)

proc selectedCount*(s: AppState): int =
  s.selection.len

proc selectedRows*(s: AppState): seq[tuple[sourceIdx: int, row: CarRow]] =
  for sel in s.selection:
    if sel.sourceIdx < 0 or sel.sourceIdx >= s.sources.len: continue
    for r in s.sources[sel.sourceIdx].cars:
      if r.name == sel.name:
        result.add((sel.sourceIdx, r))
        break

proc partsTabIndex*(s: AppState; slug: string): int =
  ## -1 if no tab exists for this slug.
  for i, t in s.partsTabs:
    if t.slug == slug: return i
  result = -1

proc loadPartsForTab(s: var AppState; tabIdx: int) =
  ## Populate `partsTabs[tabIdx].parts` from the working car's car.gltf.
  ## Silent no-op if the gltf is missing.
  if tabIdx < 0 or tabIdx >= s.partsTabs.len: return
  let slug = s.partsTabs[tabIdx].slug
  let gltfPath = s.workingRoot / slug / "car.gltf"
  if not fileExists(gltfPath): return
  s.partsTabs[tabIdx].parts.setLen(0)
  for meta in listCarParts(gltfPath):
    s.partsTabs[tabIdx].parts.add(PartRow(
      name:    meta.name,
      section: meta.section,
      lodKind: meta.lodKind,
      visible: true,
      modified: false))

proc ensurePinnedTab*(s: var AppState) =
  ## When activeSlug is set, guarantee partsTabs[0] is the pinned tab for
  ## that slug. When activeSlug is empty, drop the pinned tab if any.
  if s.activeSlug.len == 0:
    if s.partsTabs.len > 0 and s.partsTabs[0].pinned:
      s.partsTabs.delete(0)
      if s.activeTab > 0: dec s.activeTab
      else: s.activeTab = max(0, s.partsTabs.len - 1)
    return
  # Pinned tab present and matches?
  if s.partsTabs.len > 0 and s.partsTabs[0].pinned and
     s.partsTabs[0].slug == s.activeSlug:
    return
  # Pinned tab present but stale slug — replace.
  if s.partsTabs.len > 0 and s.partsTabs[0].pinned:
    s.partsTabs[0].slug = s.activeSlug
    s.partsTabs[0].parts.setLen(0)
    s.partsTabs[0].scrollY = 0
    loadPartsForTab(s, 0)
    return
  # No pinned tab — insert at front. If a non-pinned tab for this slug
  # already exists, promote it instead of duplicating.
  let existing = partsTabIndex(s, s.activeSlug)
  if existing >= 0:
    var t = s.partsTabs[existing]
    s.partsTabs.delete(existing)
    t.pinned = true
    s.partsTabs.insert(t, 0)
    s.activeTab = 0
    return
  var tab = PartsTab(slug: s.activeSlug, pinned: true)
  s.partsTabs.insert(tab, 0)
  loadPartsForTab(s, 0)
  s.activeTab = 0

proc openPartsTab*(s: var AppState; slug: string) =
  ## No-op if a tab for `slug` already exists; switches to it instead.
  let existing = partsTabIndex(s, slug)
  if existing >= 0:
    s.activeTab = existing
    return
  s.partsTabs.add(PartsTab(slug: slug, pinned: false))
  loadPartsForTab(s, s.partsTabs.len - 1)
  s.activeTab = s.partsTabs.len - 1

proc dataCarRow(cardb: JsonNode): JsonNode =
  ## Return the Data_Car single-row dict from cardb.json, or nil if absent.
  ## Cardb persists a list-of-dicts under tables.<name>.rows[]; we treat
  ## row[0] as the canonical row for the slug.
  if cardb == nil or cardb.kind != JObject: return nil
  if not cardb.hasKey("tables"): return nil
  let t = cardb["tables"]
  if not t.hasKey("Data_Car"): return nil
  let dc = t["Data_Car"]
  if dc.kind != JObject or not dc.hasKey("rows"): return nil
  let rows = dc["rows"]
  if rows.kind != JArray or rows.len == 0: return nil
  rows[0]

proc fmtJsonValue(v: JsonNode): string =
  if v == nil: return ""
  case v.kind
  of JString: v.getStr
  of JInt:    $v.getInt
  of JFloat:  $v.getFloat
  of JBool:   (if v.getBool: "1" else: "0")
  of JNull:   ""
  else:       $v

proc loadLPane*(s: var AppState) =
  ## Rebuild s.lpane for the current activeSlug. Empty slug → empty state.
  ## Each `EditableStat` is dispatched on `source`:
  ##   - essCardb     → original = cardb.json's Data_Car row, overrides
  ##                    layered on top via carslot.stats{}
  ##   - essPhysicsdef→ original = current value at `path` inside
  ##                    physicsdef.json (the bin's editable mirror).
  ##                    There's no override layer; the JSON IS the data.
  s.lpane = LPaneState()
  if s.activeSlug.len == 0: return
  let slug = s.activeSlug
  let manifestPath = s.workingRoot / slug / "carslot.json"
  if not fileExists(manifestPath): return
  let manifest = readCarSlot(s.workingRoot, slug)
  let originGame = manifest.originGame
  if originGame.len == 0: return
  var prof: GameProfile
  try: prof = loadProfileById(originGame)
  except CatchableError: return
  if prof.userEditableStats.len == 0: return

  # cardb.json — may be absent if the importer skipped it; we still render
  # the form, just with empty originals.
  var dataRow: JsonNode
  let cardbPath = s.workingRoot / slug / "cardb.json"
  if fileExists(cardbPath):
    try:
      dataRow = dataCarRow(parseJson(readFile(cardbPath)))
    except CatchableError: discard

  # physicsdef.json — only loaded if the profile defines any
  # essPhysicsdef stat. Missing file is fine (stats just show empty).
  var physJson: JsonNode = nil
  block:
    var any = false
    for stat in prof.userEditableStats:
      if stat.source == essPhysicsdef: any = true; break
    if any:
      let p = s.workingRoot / slug / "physicsdef.json"
      if fileExists(p):
        try: physJson = parseJson(readFile(p))
        except CatchableError: discard

  s.lpane.slug = slug
  s.lpane.profile = originGame
  for stat in prof.userEditableStats:
    var f = LPaneField(stat: stat)
    case stat.source
    of essCardb:
      if dataRow != nil and dataRow.hasKey(stat.column):
        f.original = fmtJsonValue(dataRow[stat.column])
      var initial = f.original
      if manifest.stats != nil and manifest.stats.hasKey(stat.column):
        f.overridden = true
        initial = fmtJsonValue(manifest.stats[stat.column])
      f.input.text = initial
    of essPhysicsdef:
      if physJson != nil:
        let v = resolvePath(physJson, stat.path)
        if v != nil: f.original = fmtJsonValue(v)
      f.input.text = f.original
    of essSynthetic:
      # Synthetic fields have no direct on-disk representation; their
      # value is computed from other sources at load and dispatched to
      # a syntheticKind-specific handler at save.
      case stat.syntheticKind
      of "physMassKg":
        # Effective mass in kg = (override CurbWeight × 100) if set,
        # else (cardb default CurbWeight × 100). Stored at SQL scale
        # (x100kg); we display in kg.
        var x100kg = 0.0
        var hasOverride = false
        if manifest.stats != nil and manifest.stats.hasKey("CurbWeight"):
          x100kg = manifest.stats["CurbWeight"].getFloat
          hasOverride = true
        elif dataRow != nil and dataRow.hasKey("CurbWeight"):
          x100kg = dataRow["CurbWeight"].getFloat
        if x100kg > 0:
          f.original = formatFloat(x100kg * 100.0, ffDecimal, 1)
        else:
          f.original = ""
        f.overridden = hasOverride
      else:
        f.original = ""
      f.input.text = f.original
    f.input.cursor = f.input.text.len
    s.lpane.fields.add f

proc syncLPaneIfStale*(s: var AppState) =
  ## Cheap idempotent reload — call each frame in the L pane drawer.
  if s.lpane.slug != s.activeSlug:
    loadLPane(s)

proc resetLPaneField*(s: var AppState; idx: int) =
  if idx < 0 or idx >= s.lpane.fields.len: return
  s.lpane.fields[idx].input.text = s.lpane.fields[idx].original
  s.lpane.fields[idx].input.cursor = s.lpane.fields[idx].original.len
  s.lpane.fields[idx].overridden = false
  s.lpane.dirty = true

proc parseStatValue(kind: EditableStatKind; v: string): JsonNode =
  ## Convert a raw text input to the typed JsonNode the field expects.
  ## Returns nil on parse failure — the caller should skip the field.
  case kind
  of eskInt:
    try: result = %parseInt(v)
    except ValueError: result = nil
  of eskBool:
    let lc = v.toLowerAscii
    if lc in ["1","true","yes","on"]: result = %1
    elif lc in ["0","false","no","off"]: result = %0
    else: result = nil
  else:
    try: result = %parseFloat(v)
    except ValueError: result = nil

proc saveLPane*(s: var AppState) =
  ## Persist current fields[] to disk. Two destinations, dispatched
  ## per-field on `stat.source`:
  ##   - essCardb     → carslot.json's `stats{}` override layer.
  ##                    Reset (input == original) deletes the override.
  ##   - essPhysicsdef→ physicsdef.json's leaf at `stat.path`.
  ##                    No override layer — the JSON is the data file.
  if s.lpane.slug.len == 0: return
  var manifest = readCarSlot(s.workingRoot, s.lpane.slug)
  if manifest.stats == nil or manifest.stats.kind != JObject:
    manifest.stats = newJObject()

  let physPath = s.workingRoot / s.lpane.slug / "physicsdef.json"
  var physJson: JsonNode = nil
  var physDirty = false
  if fileExists(physPath):
    try: physJson = parseJson(readFile(physPath))
    except CatchableError: discard

  var cardbChanges: seq[string] = @[]
  var physChanges:  seq[string] = @[]

  for i in 0 ..< s.lpane.fields.len:
    var f = addr s.lpane.fields[i]
    let v = f[].input.text.strip()

    case f[].stat.source
    of essCardb:
      if v == f[].original or v.len == 0:
        if manifest.stats.hasKey(f[].stat.column):
          manifest.stats.delete(f[].stat.column)
          f[].overridden = false
          cardbChanges.add f[].stat.column & "=<reset>"
        continue
      let newNode = parseStatValue(f[].stat.kind, v)
      if newNode == nil: continue
      let existed = manifest.stats.hasKey(f[].stat.column)
      let prev = if existed: $manifest.stats[f[].stat.column] else: ""
      if not existed or prev != $newNode:
        cardbChanges.add f[].stat.column & "=" & v
      manifest.stats[f[].stat.column] = newNode
      f[].overridden = true

    of essPhysicsdef:
      if physJson == nil: continue       # nothing to write into
      let newNode = parseStatValue(f[].stat.kind, v)
      if newNode == nil: continue
      try:
        # Only mutate + record a change if the leaf actually shifts.
        # Stringified compare keeps "0.01" vs "0.01" equal even when
        # JsonNode kinds differ (JFloat vs JInt for round numbers).
        let cur = resolvePath(physJson, f[].stat.path)
        let curStr = if cur != nil: $cur else: ""
        if curStr != $newNode:
          setPath(physJson, f[].stat.path, newNode)
          physChanges.add f[].stat.path & "=" & v
          physDirty = true
        f[].overridden = (v != f[].original)
      except ValueError:
        discard  # bad path in profile; don't lose the rest of save

    of essSynthetic:
      case f[].stat.syntheticKind
      of "physMassKg":
        # Absolute-target semantics: input is the desired mass in kg.
        # Save scales forwardInertia × (new/old), inverseInertia ×
        # (old/new), and writes the cardb CurbWeight override to
        # new/100 (SQL stores x100kg). If new matches the cardb
        # default exactly, the override is deleted instead.
        if v.len == 0 or v == f[].original: continue
        var vNewKg = 0.0
        try: vNewKg = parseFloat(v)
        except ValueError: continue
        if vNewKg <= 0.0: continue
        var vOldKg = 0.0
        try: vOldKg = parseFloat(f[].original)
        except ValueError: continue
        if vOldKg <= 0.0: continue
        if abs(vNewKg - vOldKg) < 0.5: continue       # within 0.5 kg = no-op

        let scale = vNewKg / vOldKg

        # Scale tensors. FM4 cars without a bin still get the SQL
        # update (no physJson means no tensor work to do).
        if physJson != nil:
          try:
            var fwd = mat3FromJson(physJson["forwardInertia"])
            var inv = mat3FromJson(physJson["inverseInertia"])
            let sf = scale.float32
            for k in 0..8:
              fwd[k] = fwd[k] * sf
              inv[k] = inv[k] / sf
            physJson["forwardInertia"] = mat3ToJson(fwd)
            physJson["inverseInertia"] = mat3ToJson(inv)
            physChanges.add "physMassKg " &
              formatFloat(vOldKg, ffDecimal, 1) & "->" &
              formatFloat(vNewKg, ffDecimal, 1) &
              " (x" & formatFloat(scale, ffDecimal, 4) & ")"
            physDirty = true
          except CatchableError: discard

        # Write the cardb CurbWeight override (x100kg). If it matches
        # the cardb default within float tolerance, delete instead.
        let cwNew = vNewKg / 100.0
        var cwDefault = 0.0
        let cardbPath = s.workingRoot / s.lpane.slug / "cardb.json"
        if fileExists(cardbPath):
          try:
            let dr = dataCarRow(parseJson(readFile(cardbPath)))
            if dr != nil and dr.hasKey("CurbWeight"):
              cwDefault = dr["CurbWeight"].getFloat
          except CatchableError: discard
        if cwDefault > 0 and abs(cwNew - cwDefault) < 1e-4:
          if manifest.stats.hasKey("CurbWeight"):
            manifest.stats.delete("CurbWeight")
            cardbChanges.add "CurbWeight=<reset>"
          f[].overridden = false
        else:
          manifest.stats["CurbWeight"] = %cwNew
          cardbChanges.add "CurbWeight=" & formatFloat(cwNew, ffDecimal, 5)
          f[].overridden = true

        # Update f.original so subsequent saves in the same session
        # compute scale from the just-saved baseline.
        f[].original = v
      else: discard

  if cardbChanges.len > 0:
    appendEdit(manifest, kind = "stats_edit",
               note = cardbChanges.join(", "))
  writeCarSlot(s.workingRoot, s.lpane.slug, manifest)

  if physDirty:
    writeFile(physPath, physJson.pretty)
    # Re-emit the bin from the JSON so working/<slug>/physicsdefinition.bin
    # stays the canonical export-time payload. If the JSON has been
    # hand-mutated to something the emitter rejects, leave the bin
    # alone and surface the error in the edit log — better than
    # producing a corrupt bin silently.
    try:
      let pd = fromJson(physJson)
      let bytes = emitPhysicsDef(pd)
      var binOut = newString(bytes.len)
      for j in 0 ..< bytes.len:
        binOut[j] = char(bytes[j])
      writeFile(s.workingRoot / s.lpane.slug / "physicsdefinition.bin", binOut)
      appendEdit(manifest, kind = "physicsdef_edit",
                 note = physChanges.join(", "))
    except CatchableError as e:
      appendEdit(manifest, kind = "physicsdef_emit_failed",
                 note = e.msg)
    writeCarSlot(s.workingRoot, s.lpane.slug, manifest)

  s.lpane.dirty = false

proc closePartsTab*(s: var AppState; tabIdx: int) =
  ## Refuses to close a pinned tab — caller should route Unload-car to a
  ## scene-side helper instead.
  if tabIdx < 0 or tabIdx >= s.partsTabs.len: return
  if s.partsTabs[tabIdx].pinned: return
  s.partsTabs.delete(tabIdx)
  if s.activeTab >= s.partsTabs.len:
    s.activeTab = max(0, s.partsTabs.len - 1)
  elif s.activeTab > tabIdx:
    dec s.activeTab

proc toggleSelected*(s: var AppState; sourceIdx: int; name: string) =
  let key = (sourceIdx, name)
  if key in s.selection: s.selection.excl(key)
  else:                   s.selection.incl(key)
  if sourceIdx >= 0 and sourceIdx < s.sources.len:
    var src = addr s.sources[sourceIdx]
    for i in 0 ..< src[].cars.len:
      if src[].cars[i].name == name:
        src[].cars[i].selected = key in s.selection
        break

# ---- Export palette helpers ----
#
# The palette has three rows. Top: name override + Export button (shared
# across all toggled targets). Middle: per-game donor slot (label = bound
# donor carname or "select donor"). Bottom: per-game toggle button. Donor
# binding happens by right-clicking a car in a srcGame dropup popup; the
# palette itself is read-only on the donor cell beyond clicking it to
# clear. Profiles without a registered mount render their column greyed
# out and non-clickable in both rows.

proc allProfileIds*(s: AppState): seq[string] =
  ## Profile ids known to the app, in source order. The palette renders
  ## one column per id whether a mount exists or not — unmounted columns
  ## are greyed out and disabled, which makes "go register a mount"
  ## discoverable from the palette itself.
  for src in s.sources:
    if src.kind == srcGame and src.profileId.len > 0:
      result.add src.profileId
  if result.len == 0:
    result = availableProfileIds()

proc gameSourceFor*(s: AppState; profileId: string): int =
  for i, src in s.sources:
    if src.kind == srcGame and src.profileId == profileId:
      return i
  -1

proc profileMounted*(s: AppState; profileId: string): bool =
  s.gameSourceFor(profileId) >= 0

proc donorBound*(s: AppState; profileId: string): string =
  if s.palette.donors.hasKey(profileId): s.palette.donors[profileId]
  else: ""

proc setDonor*(s: var AppState; profileId, carName: string) =
  ## Bind a donor carname for a target. Auto-toggles the target ON so
  ## the user doesn't have to click twice — picking a donor is the
  ## stronger signal of intent.
  if profileId.len == 0 or carName.len == 0: return
  s.palette.donors[profileId] = carName
  s.palette.targetsOn[profileId] = true

proc clearDonor*(s: var AppState; profileId: string) =
  if s.palette.donors.hasKey(profileId):
    s.palette.donors.del(profileId)

proc toggleTarget*(s: var AppState; profileId: string) =
  let cur = s.palette.targetsOn.getOrDefault(profileId, false)
  s.palette.targetsOn[profileId] = not cur

proc targetOn*(s: AppState; profileId: string): bool =
  s.palette.targetsOn.getOrDefault(profileId, false)

proc anyTargetOn*(s: AppState): bool =
  for _, v in s.palette.targetsOn:
    if v: return true
  false

proc syncPaletteForActiveCar*(s: var AppState) =
  ## Rebuild palette state when the active car changes. We keep
  ## donor/target bindings *empty* by default — the user explicitly
  ## binds donors via right-click, and toggling targets is one click on
  ## the bottom row. Pre-filling either was clever-but-wrong: picked
  ## targets/donors that the user didn't actually want, and harder to
  ## un-bind than to bind in the first place.
  if s.palette.slug == s.activeSlug: return
  s.palette = ExportPaletteState(slug: s.activeSlug)
  s.palette.targetsOn = initTable[string, bool]()
  s.palette.donors = initTable[string, string]()

proc setPaletteStatus*(s: var AppState; msg: string; ok: bool) =
  s.palette.statusMsg = msg
  s.palette.statusOk = ok
  s.palette.statusS = 6.0'f32   ## seconds the toast hangs around

proc tickPaletteStatus*(s: var AppState; dt: float32) =
  if s.palette.statusS > 0:
    s.palette.statusS -= dt
    if s.palette.statusS < 0:
      s.palette.statusS = 0
      s.palette.statusMsg = ""
