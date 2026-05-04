## App-wide GUI state. Populated at startup from existing core/orchestrator
## APIs (loadMounts, loadProfileById, scanLibrary, working/ walk). Verbs that
## mutate the working tree go through gui/verbs.nim — this module is a
## passive view of mounts + per-source car lists + selection.

import std/[os, sets, algorithm, strutils, tables]
import ../carbin_garage/core/[profile, mounts, cardb]
import ../carbin_garage/orchestrator/scan

type
  ExtractState* = enum esUnextracted, esExtracted, esDirty

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

  AppState* = object
    workingRoot*: string
    sources*: seq[Source]
    activeSlug*: string
    partsTabs*: seq[PartsTab]
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
  ## Phase 3a: dirty bit isn't tracked yet — we only distinguish
  ## extracted vs unextracted. Phase 3d adds dirty-tracking via a manifest
  ## field + in-memory write-bit.
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
  var byName = initTable[string, CarRow]()
  for slot in scanLibrary(m.folder, prof):
    byName[slot.name] = CarRow(
      name: slot.name, sourcePath: slot.path, sizeBytes: slot.sizeBytes,
      extractState: computeExtractState(workingRoot, slot.name))

  # 2. Every MediaName in gamedb.slt — adds the base-game catalog rows
  # whose carbin lives inside a packed .CAB. They show up greyed out (no
  # sourcePath) so the user sees the full catalog; extraction from the
  # .CAB is a separate pipeline (TODO).
  let dbPath = m.folder / prof.gamedbPath
  for mediaName in listMediaNames(dbPath):
    if not byName.hasKey(mediaName):
      byName[mediaName] = CarRow(
        name: mediaName, sourcePath: "", sizeBytes: 0,
        extractState: computeExtractState(workingRoot, mediaName))

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
  ## Rebuild s.sources from disk. Called at startup and after mounts edits.
  s.sources.setLen(0)
  for m in loadMounts():
    s.sources.add(loadGameSource(m, s.workingRoot))
  s.sources.add(loadWorkingSource(s.workingRoot))

proc initAppState*(workingRoot = ""): AppState =
  result.workingRoot = if workingRoot.len > 0: workingRoot
                       else: defaultWorkingRoot()
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
