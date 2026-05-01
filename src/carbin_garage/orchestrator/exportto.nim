## export-to: copy `working/<slug>/.archive/source.zip` into a mounted
## game's cars dir, with .bak + tmp-rename atomicity.
##
## Phase-2.5 scope: source bytes are always the stashed source.zip (byte-
## equal export). Re-encode-from-edits lives in Phase 2b.
## Spec: docs/APPLET_ARCHITECTURE.md §"Phase 2.5 — CLI safety layer".

import std/os
import ../core/profile
import ../core/mounts

type
  ExportPlan* = object
    workingCar*: string   # absolute path to working/<slug>/
    slug*: string         # working car basename
    sourceZip*: string    # working/<slug>/.archive/source.zip
    targetZip*: string    # <mountFolder>/<profile.cars>/<slug>.zip
    backupPath*: string   # <targetZip>.bak (only relevant if target exists)
    tmpPath*: string      # <targetZip>.tmp
    targetExists*: bool
    backupExists*: bool

  ExportError* = object of CatchableError

proc planExport*(workingCar: string, mount: Mount, prof: GameProfile): ExportPlan =
  let abs =
    if isAbsolute(workingCar): workingCar
    else: absolutePath(workingCar)
  if not dirExists(abs):
    raise newException(ExportError, "working car dir not found: " & abs)
  let src = abs / ".archive" / "source.zip"
  if not fileExists(src):
    raise newException(ExportError,
      "no .archive/source.zip in " & abs & " — re-import the car so it gets stashed")
  let slug = lastPathPart(abs)
  let carsDir = carsDirFor(mount.folder, prof)
  if not dirExists(carsDir):
    raise newException(ExportError, "cars dir does not exist: " & carsDir)
  let target = carsDir / (slug & ".zip")
  result = ExportPlan(
    workingCar: abs,
    slug: slug,
    sourceZip: src,
    targetZip: target,
    backupPath: target & ".bak",
    tmpPath: target & ".tmp",
    targetExists: fileExists(target),
    backupExists: fileExists(target & ".bak"))

proc describePlan*(p: ExportPlan): string =
  result.add "  source: " & p.sourceZip & "\n"
  result.add "  target: " & p.targetZip & "\n"
  if p.targetExists:
    result.add "    (target exists — would be moved to " & p.backupPath & ")\n"
  else:
    result.add "    (target does not exist — fresh write)\n"
  if p.targetExists and p.backupExists:
    result.add "  ! backup already exists at " & p.backupPath & " — refuse\n"

proc executeExport*(p: ExportPlan) =
  ## Order:
  ##   1. Refuse if target exists AND .bak exists (would clobber the user's
  ##      one stashed copy).
  ##   2. Stage tmp = source bytes (no atomicity hazard — new file).
  ##   3. If target exists, rename target -> .bak.
  ##   4. Rename tmp -> target.
  ## If step 4 fails after step 3, the user has .bak + no target; renaming
  ## .bak back is a manual one-liner. We never overwrite without going via
  ## .bak first.
  if p.targetExists and p.backupExists:
    raise newException(ExportError,
      "refusing to overwrite — backup already exists at " & p.backupPath &
      " (move or delete it before retrying)")
  copyFile(p.sourceZip, p.tmpPath)
  if p.targetExists:
    moveFile(p.targetZip, p.backupPath)
  moveFile(p.tmpPath, p.targetZip)
