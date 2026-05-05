## Bulk-remove every carbin-garage-generated DLC package for a given
## game. Identifies "ours" with a conservative AND-marker so any DLC the
## user installed by hand under the same Xenia content tree is left
## untouched:
##   1. The paired sidecar header at
##      `<contentRoot>/<profileId>/<TitleID>/Headers/00000002/<packageId>.header`
##      must contain the literal display-name prefix
##      `CarbinGarageHeaderPrefix` (UTF-16BE, starting at byte 0x08 —
##      see `buildXeniaHeader` in portto_dlc.nim).
##   2. The package must contain at least one `*_merge.slt` file under
##      `Media/DLCZips/<n>_pri_<m>/Media/db/patch/`. This file is unique
##      to the carbin-garage pipeline.

import std/[os, strutils]
import ../core/profile
import ./portto_dlc

type
  DlcPackage* = object
    packageDir*: string
    headerPath*: string

proc dlcSlotFor*(contentRoot: string; targetProfile: GameProfile;
                 profileId: string = DefaultProfileId): string =
  contentRoot / profileId / targetProfile.titleId.toUpperAscii() /
    DlcContentTypeDir

proc headersDirFor*(contentRoot: string; targetProfile: GameProfile;
                    profileId: string = DefaultProfileId): string =
  contentRoot / profileId / targetProfile.titleId.toUpperAscii() /
    "Headers" / DlcContentTypeDir

proc headerHasCarbinGaragePrefix(headerPath: string): bool =
  ## displayName is UTF-16BE starting at byte 0x08; each ASCII character
  ## occupies two bytes (00 'C', 00 'a', ...). We only need to verify the
  ## ASCII prefix, so check pairs directly without decoding.
  if not fileExists(headerPath): return false
  let data =
    try: readFile(headerPath)
    except CatchableError: return false
  let prefix = CarbinGarageHeaderPrefix
  if data.len < 0x08 + 2 * prefix.len: return false
  for i, c in prefix:
    let off = 0x08 + 2 * i
    if data[off] != '\x00': return false
    if data[off + 1] != c:  return false
  result = true

proc hasMergeSlt(packageDir: string): bool =
  let dlcZipsDir = packageDir / "Media" / "DLCZips"
  if not dirExists(dlcZipsDir): return false
  for kind, sub in walkDir(dlcZipsDir):
    if kind != pcDir: continue
    let patchDir = sub / "Media" / "db" / "patch"
    if not dirExists(patchDir): continue
    for kind2, f in walkDir(patchDir):
      if kind2 != pcFile: continue
      if extractFilename(f).endsWith("_merge.slt"): return true
  return false

proc enumerateCarbinGarageDlcs*(contentRoot: string;
                                targetProfile: GameProfile;
                                profileId: string = DefaultProfileId):
                                seq[DlcPackage] =
  if contentRoot.strip().len == 0: return @[]
  if targetProfile.titleId.len == 0: return @[]
  let slot = dlcSlotFor(contentRoot, targetProfile, profileId)
  let headersDir = headersDirFor(contentRoot, targetProfile, profileId)
  if not dirExists(slot): return @[]
  for kind, sub in walkDir(slot):
    if kind != pcDir: continue
    let pkgId = extractFilename(sub)
    let hdr = headersDir / (pkgId & ".header")
    if headerHasCarbinGaragePrefix(hdr) and hasMergeSlt(sub):
      result.add DlcPackage(packageDir: sub, headerPath: hdr)

proc clearCarbinGarageDlcs*(contentRoot: string;
                            targetProfile: GameProfile;
                            profileId: string = DefaultProfileId): int =
  ## Returns the count of packages removed. Mirrors the pair-removal in
  ## `uninstallPortToDlc`: drops `packageDir` recursively and the paired
  ## `headerPath` sidecar. Safe to re-run.
  let pkgs = enumerateCarbinGarageDlcs(contentRoot, targetProfile, profileId)
  for p in pkgs:
    if dirExists(p.packageDir): removeDir(p.packageDir)
    if fileExists(p.headerPath): removeFile(p.headerPath)
  result = pkgs.len
