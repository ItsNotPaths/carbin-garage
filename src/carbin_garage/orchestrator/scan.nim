## scanLibrary: walk profile.cars, return cheap CarSlot records.
## Spec: docs/APPLET_ARCHITECTURE.md §"Operation contracts" / §"Phase 2.5".

import std/[os, strutils, algorithm]
import ../core/profile
import ../core/mounts

type
  CarSlot* = object
    name*: string       # zip basename without extension (e.g. ALF_8C_08)
    path*: string       # absolute path to the .zip
    sizeBytes*: BiggestInt

proc scanLibrary*(folder: string, prof: GameProfile): seq[CarSlot] =
  let cars = carsDirFor(folder, prof)
  if not dirExists(cars): return @[]
  for kind, p in walkDir(cars):
    if kind != pcFile: continue
    if not p.toLowerAscii().endsWith(".zip"): continue
    let base = extractFilename(p)
    let stem = base[0 ..< base.len - 4]
    var size: BiggestInt = 0
    try: size = getFileSize(p)
    except CatchableError: discard
    result.add(CarSlot(name: stem, path: p, sizeBytes: size))
  result.sort(proc (a, b: CarSlot): int = cmp(a.name, b.name))
