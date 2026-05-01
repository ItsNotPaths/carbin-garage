## working/<slug>/ layout helpers: carslot.json manifest, geometry/, textures/.
## Spec: docs/APPLET_ARCHITECTURE.md §"Working format — cracked glTF".

import std/[os, json, times]

type
  CarSlotManifest* = object
    schemaVersion*: int
    name*: string
    originGame*: string
    exportTargets*: seq[string]
    donors*: seq[tuple[game, name: string]]

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
  let j = %*{
    "schemaVersion": m.schemaVersion,
    "name":          m.name,
    "originGame":    m.originGame,
    "exportTargets": m.exportTargets,
    "donors":        donors,
    "stats":         newJObject(),
    "edits": [
      {"ts": $now().utc, "kind": "import",
       "note": "imported from " & m.originGame}]}
  writeFile(workingPath(workingRoot, slug) / "carslot.json", $j)
