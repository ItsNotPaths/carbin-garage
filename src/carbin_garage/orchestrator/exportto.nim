## export-to: copy `working/<slug>/.archive/source.zip` into a mounted
## game's cars dir, with .bak + tmp-rename atomicity.
##
## Phase-2.5 scope: source bytes are always the stashed source.zip (byte-
## equal export). Phase 2c.3 added an opt-in *mixed-method* path that
## walks the working tree for files newer than their stashed counter-
## part and emits a method-0 (stored) entry for each, leaving the rest
## as method-21 LZX bytes copied verbatim from source.zip. This is the
## near-term unblock for in-game testing while the full LZX encoder is
## still in progress (see project memory "LZX encoder partial").
## Spec: docs/APPLET_ARCHITECTURE.md §"Phase 2.5 — CLI safety layer".

import std/[os, tables, times]
import ../core/profile
import ../core/mounts
import ../core/zip21
import ../core/zip21_writer

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

proc describePlan*(p: ExportPlan): string

proc readBytes(path: string): seq[byte] =
  let s = readFile(path)
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc collectEdits(workingCar: string): Table[string, seq[byte]] =
  ## Walk the working tree (textures/, geometry/, livery/, digitalgauge/,
  ## and the root) and pick out files whose mtime is newer than the
  ## same-named entry inside .archive/source.zip's mtime. We use the
  ## stashed zip's own mtime as the import-time stamp; anything edited
  ## after that point counts as a delta. Match is case-sensitive against
  ## the zip's central-directory entry names.
  result = initTable[string, seq[byte]]()
  let archiveZip = workingCar / ".archive" / "source.zip"
  if not fileExists(archiveZip): return
  let importTime = getLastModificationTime(archiveZip)
  let entries = listEntries(archiveZip)
  for e in entries:
    let base = lastPathPart(e.name)
    # The importer flattens entries — try a handful of candidate
    # locations the importer drops them into.
    let candidates = [
      workingCar / base,
      workingCar / "textures" / base,
      workingCar / "geometry" / base,
      workingCar / "livery"   / base,
      workingCar / "digitalgauge" / base,
    ]
    for c in candidates:
      if not fileExists(c): continue
      if getLastModificationTime(c) <= importTime: continue
      result[e.name] = readBytes(c)
      break

proc planEdits*(p: ExportPlan): seq[string] =
  ## List of zip-entry names that would be re-emitted as method-0 by
  ## executeExport. Used for the dry-run summary.
  let edits = collectEdits(p.workingCar)
  result = @[]
  for k in edits.keys: result.add(k)

proc describePlan*(p: ExportPlan): string =
  result.add "  source: " & p.sourceZip & "\n"
  result.add "  target: " & p.targetZip & "\n"
  if p.targetExists:
    result.add "    (target exists — would be moved to " & p.backupPath & ")\n"
  else:
    result.add "    (target does not exist — fresh write)\n"
  if p.targetExists and p.backupExists:
    result.add "  ! backup already exists at " & p.backupPath & " — refuse\n"
  let edits = planEdits(p)
  if edits.len == 0:
    result.add "  edits: none — byte-equal copy of source.zip\n"
  else:
    result.add "  edits: " & $edits.len & " entry(ies) re-emitted as method-0 (stored)\n"
    for n in edits:
      result.add "    " & n & "\n"

proc executeExport*(p: ExportPlan) =
  ## Order:
  ##   1. Refuse if target exists AND .bak exists (would clobber the user's
  ##      one stashed copy).
  ##   2. Decide source bytes for the staged tmp:
  ##        - If the working tree has any file newer than source.zip,
  ##          rewrite source.zip into a mixed-method (method-0 for edits,
  ##          method-21 verbatim for everything else) zip in memory.
  ##        - Otherwise, byte-copy source.zip — the established
  ##          byte-equal-export path.
  ##   3. Write tmp.
  ##   4. If target exists, rename target -> .bak.
  ##   5. Rename tmp -> target.
  ## If step 5 fails after step 4, the user has .bak + no target; renaming
  ## .bak back is a manual one-liner. We never overwrite without going via
  ## .bak first.
  if p.targetExists and p.backupExists:
    raise newException(ExportError,
      "refusing to overwrite — backup already exists at " & p.backupPath &
      " (move or delete it before retrying)")
  let edits = collectEdits(p.workingCar)
  if edits.len == 0:
    copyFile(p.sourceZip, p.tmpPath)
  else:
    let bytes = rewriteZipMixedMethod(p.sourceZip, edits)
    var f = open(p.tmpPath, fmWrite)
    defer: f.close()
    if bytes.len > 0: discard f.writeBytes(bytes, 0, bytes.len)
  if p.targetExists:
    moveFile(p.targetZip, p.backupPath)
  moveFile(p.tmpPath, p.targetZip)
