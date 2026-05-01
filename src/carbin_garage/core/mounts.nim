## Mounts registry: ~/.config/carbin-garage/mounts.json
## Maps game-id -> absolute folder (the dir that contains <profile.cars>).
## Spec: docs/APPLET_ARCHITECTURE.md §"Phase 2.5 — CLI safety layer".

import std/[json, os, strutils, algorithm]
import ./profile

type
  Mount* = object
    gameId*: string
    folder*: string

proc mountsFile*(): string =
  ## XDG_CONFIG_HOME aware, falls back to ~/.config.
  let xdg = getEnv("XDG_CONFIG_HOME")
  let base = if xdg.len > 0: xdg else: getEnv("HOME") / ".config"
  result = base / "carbin-garage" / "mounts.json"

proc availableProfileIds*(): seq[string] =
  ## Enumerate profiles/<id>.json next to the binary. Sorted for stable
  ## detection order (so two profiles claiming the same folder pick the
  ## same winner across runs).
  let dir = profilesDir()
  if not dirExists(dir): return @[]
  for kind, p in walkDir(dir):
    if kind != pcFile: continue
    let n = extractFilename(p)
    if n.endsWith(".json"):
      result.add(n[0 ..< n.len - 5])
  result.sort()

proc carsDirFor*(folder: string, prof: GameProfile): string =
  folder / prof.cars

proc detectProfile*(folder: string): string =
  ## Return the id of the first profile whose <folder>/<cars> dir exists,
  ## or "" if none match. Profiles are tried in sorted-id order.
  for id in availableProfileIds():
    let prof =
      try: loadProfileById(id)
      except CatchableError: continue
    if dirExists(carsDirFor(folder, prof)):
      return id
  return ""

proc loadMounts*(): seq[Mount] =
  let path = mountsFile()
  if not fileExists(path): return @[]
  let j =
    try: parseJson(readFile(path))
    except CatchableError: return @[]
  if j.kind != JObject: return @[]
  for k, v in j.pairs:
    if v.kind == JString:
      result.add(Mount(gameId: k, folder: v.getStr))

proc saveMounts*(mounts: seq[Mount]) =
  let path = mountsFile()
  createDir(parentDir(path))
  var j = newJObject()
  for m in mounts: j[m.gameId] = %m.folder
  writeFile(path, j.pretty)

proc findMount*(mounts: seq[Mount], gameId: string): int =
  for i, m in mounts:
    if m.gameId == gameId: return i
  return -1

proc upsertMount*(mounts: var seq[Mount], gameId, folder: string) =
  let i = findMount(mounts, gameId)
  if i >= 0: mounts[i].folder = folder
  else:      mounts.add(Mount(gameId: gameId, folder: folder))
