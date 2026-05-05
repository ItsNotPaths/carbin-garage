## working/<slug>/ layout helpers: carslot.json manifest, geometry/, textures/.
## Spec: docs/APPLET_ARCHITECTURE.md §"Working format — cracked glTF".

import std/[os, json, times, algorithm]

type
  CarSlotManifest* = object
    schemaVersion*: int
    name*: string
    originGame*: string
    exportTargets*: seq[string]
    donors*: seq[tuple[game, name: string]]
    stats*: JsonNode             ## column → edited value (JObject); empty = no overrides
    edits*: JsonNode             ## append-only audit array (JArray)

const
  UndoCap = 10
  ManifestSchemaVersion = 2

proc workingPath*(workingRoot, slug: string): string =
  workingRoot / slug

proc ensureLayout*(workingRoot, slug: string) =
  let base = workingPath(workingRoot, slug)
  for d in ["", "geometry", "textures", "livery", "digitalgauge"]:
    let p = if d.len == 0: base else: base / d
    createDir(p)

proc writeCarSlot*(workingRoot, slug: string, m: CarSlotManifest) =
  var donors = newJObject()
  for d in m.donors: donors[d.game] = %d.name
  let stats = if m.stats != nil and m.stats.kind == JObject: m.stats
              else: newJObject()
  var edits = if m.edits != nil and m.edits.kind == JArray: m.edits
              else: newJArray()
  if edits.len == 0:
    edits.add %*{"ts": $now().utc, "kind": "import",
                 "note": "imported from " & m.originGame}
  let j = %*{
    "schemaVersion": m.schemaVersion,
    "name":          m.name,
    "originGame":    m.originGame,
    "exportTargets": m.exportTargets,
    "donors":        donors,
    "stats":         stats,
    "edits":         edits}
  writeFile(workingPath(workingRoot, slug) / "carslot.json", $j)

proc readCarSlot*(workingRoot, slug: string): CarSlotManifest =
  ## Parse carslot.json; tolerant to older schema versions that may lack
  ## stats/edits or carry donors as either JObject (game→name) or JArray
  ## (legacy {game,name} tuples).
  let path = workingPath(workingRoot, slug) / "carslot.json"
  let j = parseJson(readFile(path))
  result.schemaVersion = j{"schemaVersion"}.getInt(ManifestSchemaVersion)
  result.name = j{"name"}.getStr(slug)
  result.originGame = j{"originGame"}.getStr
  if j.hasKey("exportTargets"):
    for x in j["exportTargets"]: result.exportTargets.add x.getStr
  if j.hasKey("donors"):
    let d = j["donors"]
    if d.kind == JObject:
      for game, name in d: result.donors.add((game, name.getStr))
    elif d.kind == JArray:
      for x in d:
        result.donors.add((x{"game"}.getStr, x{"name"}.getStr))
  result.stats = if j.hasKey("stats") and j["stats"].kind == JObject: j["stats"]
                 else: newJObject()
  result.edits = if j.hasKey("edits") and j["edits"].kind == JArray: j["edits"]
                 else: newJArray()

proc appendEdit*(m: var CarSlotManifest; kind, note: string) =
  if m.edits == nil or m.edits.kind != JArray: m.edits = newJArray()
  m.edits.add %*{"ts": $now().utc, "kind": kind, "note": note}

proc undoDir*(workingRoot, slug: string): string =
  workingPath(workingRoot, slug) / ".undo"

proc snapshotForUndo*(workingRoot, slug: string): string =
  ## Copy mutable artefacts (geometry/, car.gltf, car.bin) to
  ## `.undo/<ts>/`. Cap at UndoCap by mtime — oldest dirs are pruned
  ## before the new snapshot is written. Returns the new snapshot dir.
  let base = workingPath(workingRoot, slug)
  let undo = undoDir(workingRoot, slug)
  createDir(undo)

  # Prune. Walk children, sort by mtime ascending, drop the oldest until
  # we'd be under (UndoCap - 1) — leaves room for the snapshot we're about
  # to take.
  var existing: seq[tuple[mt: Time, path: string]] = @[]
  for kind, p in walkDir(undo):
    if kind == pcDir: existing.add((getLastModificationTime(p), p))
  existing.sort(proc (a, b: tuple[mt: Time, path: string]): int =
    cmp(a.mt, b.mt))
  while existing.len >= UndoCap:
    removeDir(existing[0].path)
    existing.delete(0)

  let stamp = now().utc.format("yyyyMMdd'T'HHmmss'Z'")
  let dst = undo / stamp
  createDir(dst)

  for sub in ["geometry", "car.gltf", "car.bin"]:
    let src = base / sub
    if not fileExists(src) and not dirExists(src): continue
    let target = dst / sub
    if dirExists(src):
      copyDir(src, target)
    else:
      copyFile(src, target)
  result = dst
