## importToWorking: one Forza method-21 zip → working/<slug>/{car.gltf, car.bin,
## geometry/, textures/, livery/, digitalgauge/, carslot.json, .archive/}.
## Spec: docs/APPLET_ARCHITECTURE.md §"Operation contracts".

import std/[json, os, strutils]
import ../core/zip21
import ../core/lzx
import ../core/profile
import ../core/workspace
import ../core/gltf
import ../core/xds
import ../core/texture_map
import ../core/cardb
import ../core/physicsdef
import ../core/carbin/parser

proc isCarbin(name: string): bool =
  name.toLowerAscii().endsWith(".carbin")

proc isStripped(name: string): bool =
  ## FH1 ships header-only stub carbins prefixed with "stripped_". Skip
  ## those in the glTF emit — they have no geometry.
  extractFilename(name).toLowerAscii().startsWith("stripped_")

proc writeAllBytes(path: string, data: openArray[byte]) =
  var f = open(path, fmWrite)
  defer: f.close()
  if data.len > 0: discard f.writeBytes(data, 0, data.len)

proc baseNameNoExt(name: string): string =
  let b = extractFilename(name)
  let dot = b.rfind('.')
  result = if dot < 0: b else: b[0 ..< dot]

proc readFileBytes(path: string): seq[byte] =
  let s = readFile(path)
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

type
  EmittedSection* = object
    name*: string
    meshIdx*: int
    offset*: array[3, float32]
    boundMin*: array[3, float32]
    boundMax*: array[3, float32]

proc readMaxDataDimensions(workingRoot: string): tuple[wheelbase, frontTrack, rearTrack: float32; ok: bool] =
  ## Pull Wheelbase, FrontTrackOuter, RearTrackOuter from maxdata.xml.
  ## Used to compute the 4 wheel-hub world positions (the carbin doesn't
  ## carry them; the game places wheels at runtime from this data).
  let candidates = [workingRoot / "maxdata.xml", workingRoot / "MAXData.xml"]
  var content = ""
  for p in candidates:
    if fileExists(p):
      content = readFile(p); break
  if content.len == 0: return (0.0'f32, 0.0'f32, 0.0'f32, false)
  proc grab(s, attr: string): float32 =
    let key = attr & "=\""
    let i = s.find(key)
    if i < 0: return 0.0'f32
    let valStart = i + key.len
    let valEnd = s.find('"', valStart)
    if valEnd < 0: return 0.0'f32
    try: return parseFloat(s[valStart ..< valEnd]).float32
    except CatchableError: return 0.0'f32
  result.wheelbase = grab(content, "Wheelbase")
  result.frontTrack = grab(content, "FrontTrackOuter")
  result.rearTrack = grab(content, "RearTrackOuter")
  result.ok = result.wheelbase > 0 and result.frontTrack > 0 and result.rearTrack > 0

proc isHiddenSection(name: string, includeVariants: bool,
                     suppressMainInterior: bool = false): bool =
  ## Sections to skip in the visual export:
  ##   - "interior": game renders this only in cockpit cam, overlaps the
  ##     exterior body in third-person and DCC tools.
  ##   - "*race" suffix: race-kit body-panel variants (wingrace,
  ##     cagerace, bumperFrace, etc.) — alternates to the stock bumper /
  ##     wing / cage rendered when the player has the upgrade. Showing
  ##     them by default produces overlapping double meshes.
  ##   - main-carbin {seatL, seatR, steering_wheel}: these are low-poly
  ##     3rd-person versions; the cockpit carbin ships high-poly
  ##     equivalents at the same world position, so emitting both
  ##     produces .001 duplicates in DCC tools. Always suppress on the
  ##     main carbin since the cockpit is now always emitted alongside.
  ## Variant bytes still ride through to round-trip via geometry/<part>.carbin.
  let n = name.toLowerAscii()
  if n == "interior": return true
  if not includeVariants and n.endsWith("race"): return true
  if suppressMainInterior and
     (n == "seatl" or n == "seatr" or n == "steering_wheel"):
    return true
  result = false

proc emitCarbinFile(b: var GltfBuilder, path, label: string,
                    emitted: var seq[EmittedSection],
                    includeVariants: bool,
                    availableTextures: seq[string] = @[],
                    suppressMainInterior: bool = false,
                    lodKind: string = "main"): int =
  ## Parse one carbin file and emit each non-empty section as a glTF mesh.
  ## Returns the number of meshes added. Soft-fails (returns 0) if the
  ## parser doesn't support this carbin's TypeId or the section bytes
  ## are mis-aligned. Captures (name, mesh-index, transform offset) per
  ## emitted section so the caller can do post-emit instancing
  ## (e.g., wheel template at 4 hub positions). `lodKind` tags every
  ## emitted mesh's extras so the UI can filter to lod0 for display.
  let data = readFileBytes(path)
  let baseName = extractFilename(path)
  try:
    let info = parseFm4Carbin(data)
    # Stamp the glTF builder with the source carbin's version on first
    # parse so finish() can emit extras.carbin.version for Stage 2's
    # round-trip emitter. All carbins in one car archive should agree on
    # the version (FM4 family vs FH1 family); successive calls overwrite,
    # but values match in practice since the archive is single-game.
    if b.cgVersion.len == 0:
      b.cgVersion = $info.version
    var added = 0
    for sec in info.sections:
      let hasLod  = sec.lodVerticesCount > 0'u32  and sec.lodVerticesSize > 0'u32
      let hasLod0 = sec.lod0VerticesCount > 0'i32 and sec.lod0VerticesSize > 0'u32
      if not (hasLod or hasLod0): continue
      if isHiddenSection(sec.name, includeVariants, suppressMainInterior): continue
      let xform = readSectionTransform(data, sec)
      let meshIdx = emitSection(b, data, sec, availableTextures, lodKind, baseName)
      # World bounds = section.target_min/max + offset (matches what
      # decodePoolToFloats produces for vertex positions).
      var bMin, bMax: array[3, float32]
      for i in 0 .. 2:
        bMin[i] = xform.targetMin[i] + xform.offset[i]
        bMax[i] = xform.targetMax[i] + xform.offset[i]
      emitted.add(EmittedSection(
        name: sec.name, meshIdx: meshIdx, offset: xform.offset,
        boundMin: bMin, boundMax: bMax))
      inc added
    if added > 0:
      echo "  + ", label, " (", added, " sections)"
    result = added
  except CatchableError as e:
    echo "  - ", label, " skipped: ", e.msg
    result = 0

proc importToWorking*(zipPath: string, profile: GameProfile,
                     workingRoot: string, slugOverride = "",
                     allVariants: bool = false): string =
  ## Pipeline:
  ##   1. Walk the zip's central directory.
  ##   2. For each carbin: LZX-inflate, write verbatim to geometry/.
  ##   3. For each xds/tga/xml/bgf/bsg/fbf: LZX-inflate, drop into the
  ##      matching working/ subdir.
  ##   4. Stash the source zip at .archive/source.zip — Phase 1 export
  ##      copies that file verbatim to guarantee byte-equal round-trip.
  ##   5. Walk geometry/*.carbin (excluding stripped_*) and emit each
  ##      into one shared glTF (main + lod0 + cockpit + 4 caliper + 4 rotor
  ##      = the full visual stack the game draws).
  ##   6. Write carslot.json with originGame from the profile.
  let zipStem = baseNameNoExt(zipPath)
  let slug = if slugOverride.len > 0: slugOverride else: zipStem
  ensureLayout(workingRoot, slug)
  let root = workingPath(workingRoot, slug)

  let entries = listEntries(zipPath)
  for e in entries:
    let bytes = extract(zipPath, e)
    let lname = e.name.toLowerAscii()
    let target =
      if isCarbin(lname): root / "geometry" / extractFilename(e.name)
      elif lname.endsWith(".tga") or lname.endsWith("masks.xml"):
        root / "livery" / extractFilename(e.name)
      elif lname.endsWith(".bgf") or lname.endsWith(".bsg") or lname.endsWith(".fbf") or
           lname.contains("dash"):
        root / "digitalgauge" / extractFilename(e.name)
      elif lname.endsWith(".xds"):
        root / "textures" / extractFilename(e.name)
      else:
        root / extractFilename(e.name)
    createDir(parentDir(target))
    writeAllBytes(target, bytes)

  # Stash the source zip for byte-exact export. Cheap, deterministic, and
  # the zip is already on disk — copying it sidesteps the "you can't
  # reproduce someone else's LZX bitstream" problem entirely. When future
  # phases edit geometry, the export code will splice replacements into
  # this archive and re-encode just the touched entries.
  let archiveDir = root / ".archive"
  createDir(archiveDir)
  copyFile(zipPath, archiveDir / "source.zip")

  # Pull the per-car DB snippet out of the source game's gamedb.slt and
  # park it next to the archive at working/<slug>/cardb.json. This makes
  # the working car self-contained: the global DB rows that pair with
  # this archive ride along with it, so the eventual export step can
  # write them straight back into a target game's gamedb.slt without
  # needing the original game's DB on disk anymore.
  # MediaName in Data_Car is the zip basename; both FM4 and FH1 store it
  # in upper-case (`ALF_8C_08`) regardless of the file system casing.
  if profile.gamedbPath.len > 0:
    let mediaName = baseNameNoExt(zipPath)
    try:
      let snippet = extractCarDbFromZip(zipPath, profile, mediaName)
      writeFile(root / "cardb.json", snippet.pretty)
      let nTables =
        if snippet.hasKey("tables"): snippet["tables"].len else: 0
      echo "  + cardb.json (", nTables, " tables for ", mediaName, ")"
    except CardbExtractError as e:
      echo "  - cardb skipped: ", e.msg
    except CatchableError as e:
      echo "  - cardb error: ", e.msg

  # Parse physicsdefinition.bin → physicsdef.json sidecar. Same pattern
  # as cardb.json: the raw bytes stay on disk for byte-identical export
  # if the user never edits anything; the JSON is the editable surface
  # the L pane reads from + writes back to. Export will eventually
  # re-emit the bin from this JSON instead of passing the donor bytes
  # through (decision noted in docs/FH1_PHYSICSDEFINITION_BIN.md).
  let physBin = root / "physicsdefinition.bin"
  if fileExists(physBin):
    try:
      let bytes = readFileBytes(physBin)
      let pd = parsePhysicsDef(bytes)
      writeFile(root / "physicsdef.json", pd.toJson.pretty)
      echo "  + physicsdef.json"
    except CatchableError as e:
      echo "  - physicsdef.json skipped: ", e.msg

  # Decode .xds → .png for every texture in working/<slug>/textures/.
  # The .xds bytes stay on disk (round-trip + re-encode reference); the
  # PNG is what the glTF references and what the user edits.
  # Stamp the PNG's mtime back to the .xds's so the
  # PNG-newer-than-XDS dirty check (used by reencode-textures /
  # export-to) only fires on real user edits, not on the import-time
  # write order.
  let texDir = root / "textures"
  if dirExists(texDir):
    for kind, p in walkDir(texDir):
      if kind != pcFile: continue
      if not p.toLowerAscii().endsWith(".xds"): continue
      try:
        let bytes = readFileBytes(p)
        let img = decodeXds(bytes)
        let pngPath = p & ".png"
        writePng(pngPath, img)
        let xdsTime = getLastModificationTime(p)
        setLastModificationTime(pngPath, xdsTime)
      except CatchableError as e:
        echo "  - texture skipped: ", extractFilename(p), " (", e.msg, ")"

  # Multi-carbin glTF emit. Walk geometry/ once, classify each file by
  # name pattern (case-insensitive — FM4 lowercases everything, FH1
  # keeps mixed case), and emit in a deterministic priority order so
  # the main carbin's meshes show up first in DCC tools.
  var b = initBuilder("car.bin")
  var totalSections = 0
  let geomDir = root / "geometry"
  let stemLc = zipStem.toLowerAscii()

  type EmitKind = enum ekMain, ekLod0, ekCockpit, ekCorner, ekOther, ekSkip

  proc classify(base: string): EmitKind =
    let lc = base.toLowerAscii()
    if not lc.endsWith(".carbin"): return ekSkip
    if isStripped(lc): return ekSkip
    if lc == stemLc & ".carbin": return ekMain
    if lc == stemLc & "_lod0.carbin": return ekLod0
    if lc == stemLc & "_cockpit.carbin": return ekCockpit
    for k in ["caliper", "rotor"]:
      for c in ["lf", "lr", "rf", "rr"]:
        if lc == stemLc & "_" & k & c & "_lod0.carbin": return ekCorner
    return ekOther

  var byKind: array[EmitKind, seq[string]]
  for kind, file in walkDir(geomDir):
    if kind != pcFile: continue
    let cls = classify(extractFilename(file))
    if cls == ekSkip: continue
    byKind[cls].add(file)

  # Emit ALL carbins into a single glTF — main + lod0 + cockpit + the 4
  # caliper + 4 rotor LOD0s + any other oddballs. Each mesh is tagged
  # with its source kind in `mesh.extras.carbin.lodKind` so the UI can
  # filter to lod0 for display while DCC tools still see the full data
  # for porting.
  # FM4 main-carbin {seatL, seatR, steering_wheel} are always suppressed
  # because the cockpit carbin ships higher-poly equivalents at the same
  # world position; emitting both produces .001 duplicates in Blender.
  let kinds = @[ekMain, ekLod0, ekCockpit, ekCorner, ekOther]
  let lodKindStr: array[EmitKind, string] =
    ["main", "lod0", "cockpit", "corner", "other", "skip"]
  let availableTextures = availableTextureBasenames(texDir)
  var emitted: seq[EmittedSection] = @[]
  let cockpitPresent = byKind[ekCockpit].len > 0
  for cls in kinds:
    let suppressMainInterior = cls == ekMain and cockpitPresent
    for path in byKind[cls]:
      totalSections += emitCarbinFile(b, path, extractFilename(path),
                                       emitted, allVariants,
                                       availableTextures,
                                       suppressMainInterior,
                                       lodKindStr[cls])

  # Wheel instancing: the main carbin's `wheel` mesh is a single
  # template. The game places it at four hub positions per-frame from
  # physics state in maxdata.xml — the carbin itself doesn't carry those
  # positions, so we compute them from Wheelbase / FrontTrackOuter /
  # RearTrackOuter (front of car is at -Z; verified by bumperFa/Ra
  # centers). Hub Y is the wheel mesh's Y-radius so the tire bottoms sit
  # on y=0 (ground reference per BottomCenterWheelbasePos).
  # Both the main carbin's `wheel` section and the lod0 carbin's `wheel`
  # section emit a mesh named "wheel". Instance *both* at the 4 hub
  # positions; otherwise whichever loses the lookup race renders at
  # world-origin (= tyres floating in the middle of the car body).
  var wheelMeshes: seq[tuple[idx: int; boundMax: array[3, float32]]] = @[]
  for e in emitted:
    if e.name.toLowerAscii() == "wheel":
      wheelMeshes.add((e.meshIdx, e.boundMax))
  if wheelMeshes.len > 0:
    let dims = readMaxDataDimensions(root)
    if dims.ok:
      let halfWb = dims.wheelbase * 0.5'f32
      let halfFt = dims.frontTrack * 0.5'f32
      let halfRt = dims.rearTrack * 0.5'f32
      # Use the largest Y-bound across wheel meshes — main and lod0
      # should agree, but pick the bigger as a safety net.
      var hubY = wheelMeshes[0].boundMax[1]
      for w in wheelMeshes: hubY = max(hubY, w.boundMax[1])
      let hubs: seq[array[3, float32]] = @[
        [-halfFt, hubY, -halfWb],   # LF
        [+halfFt, hubY, -halfWb],   # RF
        [-halfRt, hubY, +halfWb],   # LR
        [+halfRt, hubY, +halfWb],   # RR
      ]
      for w in wheelMeshes:
        setInstances(b, w.idx, hubs)
      # Brake calipers + rotors carry tiny corner-relative offsets in
      # the carbin (~±0.01 X, ~±0.16 Z) — they're meant to ride on top
      # of the per-corner wheel hub position, not stand alone near
      # origin. Without explicit placement, all 4 calipers stack at
      # (0,0,0) and read as visual nonsense. Match by name suffix.
      proc cornerHub(name: string): int =
        let lc = name.toLowerAscii()
        if lc.endsWith("lf"): 0
        elif lc.endsWith("rf"): 1
        elif lc.endsWith("lr"): 2
        elif lc.endsWith("rr"): 3
        else: -1
      for e in emitted:
        let nLc = e.name.toLowerAscii()
        if not (nLc.startsWith("caliper") or nLc.startsWith("rotor")):
          continue
        let h = cornerHub(e.name)
        if h < 0: continue
        setInstances(b, e.meshIdx, @[hubs[h]])

  if totalSections > 0:
    b.finish(root / "car.gltf", root / "car.bin")
    echo "  glTF: ", totalSections, " meshes -> car.gltf + car.bin"
  else:
    echo "  note: car.gltf NOT emitted (parser doesn't support any carbin in this archive yet)"

  writeCarSlot(workingRoot, slug, CarSlotManifest(
    schemaVersion: 2,
    name: slug,
    originGame: profile.id,
    exportTargets: @[profile.id],
    donors: @[(profile.id, slug)]))

  result = root
