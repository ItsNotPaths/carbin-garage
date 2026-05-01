## mountGame: thin wrapper that detects which profile a game folder belongs
## to (= first profile whose `<folder>/<cars>` dir exists). Pure read.
## Spec: docs/APPLET_ARCHITECTURE.md §"Operation contracts" / §"Phase 2.5".

import std/os
import ../core/mounts

type
  MountResult* = object
    folder*: string
    profileId*: string   # "" if no profile matched

proc mountGame*(folder: string): MountResult =
  let abs =
    if isAbsolute(folder): folder
    else: absolutePath(folder)
  result = MountResult(folder: abs, profileId: detectProfile(abs))
