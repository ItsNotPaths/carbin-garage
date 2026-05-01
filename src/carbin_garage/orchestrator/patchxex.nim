## patch-xex orchestrator: apply a patch set to a default.xex.
##
## Pipeline:
##   1. Read the .xex bytes.
##   2. Run xex2 unpack → decrypted PE image.
##   3. Verify each patch site has the expected vanilla bytes
##      (early-out with a clear error if a different version is on disk).
##   4. Apply each site's `patched` bytes in-place on the image.
##   5. Run xex2 repack → re-encrypted xex bytes.
##   6. Atomic write: stage to .tmp, move existing .xex to .vanillabak
##      (only if not already present), rename .tmp → target.
##
## Restore: a separate verb `patch-xex --restore` swaps .vanillabak
## back over the active .xex.

import std/[os, strutils]
import ../core/xex2/unpack
import ../core/xex2_patches

type
  PatchXexError* = object of CatchableError

  PatchPlanSite* = object
    site*: XexPatchSite
    matchesVanilla*: bool
    matchesPatched*: bool      ## Already patched — site reports as no-op
    actualBytes*: seq[uint8]   ## What's currently at the offset

  PatchPlan* = object
    xexPath*: string
    backupPath*: string
    tmpPath*: string
    targetExists*: bool
    backupExists*: bool
    keyUsed*: string           ## "retail" / "devkit" / ""
    patchSet*: XexPatchSet
    sites*: seq[PatchPlanSite]
    allSitesMatch*: bool       ## true if every site matches vanilla
    allSitesAlreadyPatched*: bool  ## true if every site already has patched bytes (idempotent re-run)
    image*: UnpackResult       ## kept around so executePatch doesn't re-unpack

proc readBytes(path: string): seq[uint8] =
  let s = readFile(path)
  result = newSeq[uint8](s.len)
  for i, c in s: result[i] = uint8(ord(c))

proc writeAllBytes(path: string, data: openArray[uint8]) =
  var f = open(path, fmWrite)
  defer: f.close()
  if data.len > 0: discard f.writeBytes(data, 0, data.len)

proc bytesEq(a, b: openArray[uint8]): bool =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if a[i] != b[i]: return false
  return true

proc planPatchFromTemplate*(targetPath, templatePath: string,
                            patchSet: XexPatchSet): PatchPlan =
  ## Template mode: decrypt `templatePath` (a known-good patched xex from
  ## another tool), apply OUR patch bytes on top of theirs at the same
  ## offsets, re-encrypt, and write the result over `targetPath`. Skips
  ## all the header-integrity guesswork by reusing theirs' headers
  ## verbatim — they're already structured to satisfy the loader.
  if not fileExists(templatePath):
    raise newException(PatchXexError, "template xex not found: " & templatePath)
  if not fileExists(targetPath):
    raise newException(PatchXexError, "target xex not found: " & targetPath)
  let templateRaw = readBytes(templatePath)
  let img = unpackXex(templateRaw)
  result.xexPath = targetPath
  result.backupPath = targetPath & ".vanillabak"
  result.tmpPath = targetPath & ".tmp"
  result.targetExists = true
  result.backupExists = fileExists(result.backupPath)
  result.keyUsed = img.keyUsed
  result.patchSet = patchSet
  result.image = img
  result.allSitesMatch = true
  result.allSitesAlreadyPatched = false  # in template mode the sites
                                          # already carry theirs' scramble,
                                          # not vanilla — but we apply
                                          # OUR patches regardless.
  for s in patchSet.sites:
    if s.imageOffset + s.vanilla.len > img.imageBytes.len:
      raise newException(PatchXexError,
        "patch site " & toHex(s.imageOffset) & " (" & s.note &
        ") past end of image")
    var actual = newSeq[uint8](s.vanilla.len)
    for i in 0 ..< s.vanilla.len:
      actual[i] = img.imageBytes[s.imageOffset + i]
    result.sites.add(PatchPlanSite(
      site: s, matchesVanilla: bytesEq(actual, s.vanilla),
      matchesPatched: bytesEq(actual, s.patched), actualBytes: actual))

proc planPatch*(xexPath: string, patchSet: XexPatchSet): PatchPlan =
  if not fileExists(xexPath):
    raise newException(PatchXexError, "xex file not found: " & xexPath)
  let raw = readBytes(xexPath)
  let img = unpackXex(raw)
  result.xexPath = xexPath
  result.backupPath = xexPath & ".vanillabak"
  result.tmpPath = xexPath & ".tmp"
  result.targetExists = true
  result.backupExists = fileExists(result.backupPath)
  result.keyUsed = img.keyUsed
  result.patchSet = patchSet
  result.image = img
  result.allSitesMatch = true
  result.allSitesAlreadyPatched = true
  for s in patchSet.sites:
    var actual = newSeq[uint8](s.vanilla.len)
    if s.imageOffset + s.vanilla.len > img.imageBytes.len:
      raise newException(PatchXexError,
        "patch site " & toHex(s.imageOffset) & " (" & s.note &
        ") past end of image (image size " & $img.imageBytes.len & ")")
    for i in 0 ..< s.vanilla.len:
      actual[i] = img.imageBytes[s.imageOffset + i]
    let mv = bytesEq(actual, s.vanilla)
    let mp = bytesEq(actual, s.patched)
    result.sites.add(PatchPlanSite(
      site: s, matchesVanilla: mv, matchesPatched: mp, actualBytes: actual))
    if not mv: result.allSitesMatch = false
    if not mp: result.allSitesAlreadyPatched = false

proc describePlan*(p: PatchPlan): string =
  result.add "  xex:    " & p.xexPath & "\n"
  result.add "  backup: " & p.backupPath
  if p.backupExists: result.add "  (exists)"
  result.add "\n"
  result.add "  encryption key used: " &
             (if p.keyUsed.len > 0: p.keyUsed else: "(none — unencrypted)") & "\n"
  result.add "  patch set: " & p.patchSet.name & "  (" & $p.patchSet.sites.len & " sites)\n"
  if p.allSitesAlreadyPatched:
    result.add "  ! all sites ALREADY match the patched bytes — no-op\n"
    return
  if not p.allSitesMatch:
    result.add "  ! some sites don't match expected vanilla bytes — refusing to patch\n"
  for ps in p.sites:
    let mark =
      if ps.matchesVanilla: "vanilla -> patched ✓"
      elif ps.matchesPatched: "ALREADY PATCHED (skip)"
      else: "MISMATCH — won't apply"
    result.add "    " & toHex(ps.site.imageOffset, 7) & "  " &
               $ps.site.vanilla.len & "B  " & ps.site.note & "  [" & mark & "]\n"

proc executePatch*(p: PatchPlan; templateBytes: seq[uint8] = @[]) =
  ## Apply the patch and write the new xex bytes to disk atomically.
  ##
  ## When `templateBytes` is non-empty, repack against the template's
  ## bytes (template-mode) instead of the target's. The target gets
  ## overwritten with the template's headers + our re-encrypted payload.
  if p.allSitesAlreadyPatched:
    raise newException(PatchXexError,
      "all sites already patched — nothing to do (re-running would be a no-op)")
  if not p.allSitesMatch and templateBytes.len == 0:
    raise newException(PatchXexError,
      "refusing to patch: some sites don't match expected vanilla bytes " &
      "(this xex is a different version than our patch set knows about)")
  if p.backupExists:
    raise newException(PatchXexError,
      "refusing to patch: backup already exists at " & p.backupPath &
      " (move or delete it before re-running)")
  # Apply patches in-place on the decrypted image.
  var image = p.image.imageBytes
  for ps in p.sites:
    for i in 0 ..< ps.site.patched.len:
      image[ps.site.imageOffset + i] = ps.site.patched[i]
  # Repack against the TEMPLATE — its FileFormatInfo (basic_block_pairs)
  # and encrypted_image_key are what the loader will use, so we must
  # recompress + re-encrypt with theirs' parameters even though our
  # plaintext image came from the user's vanilla xex.
  let templateHeader = fh1HeaderTemplateBytes()
  let templateProbe = probeXex(templateHeader)
  let baseBytes = if templateBytes.len > 0: templateBytes
                  else: readBytes(p.xexPath)
  let repacked = repackXex(baseBytes, image, templateProbe, p.image.keyUsed,
                           templateHeader)
  # Write tmp, then atomic rename via .vanillabak.
  writeAllBytes(p.tmpPath, repacked)
  moveFile(p.xexPath, p.backupPath)
  moveFile(p.tmpPath, p.xexPath)

proc executeRestore*(xexPath: string) =
  ## Restore the .vanillabak over the active xex. Used by --restore.
  let backup = xexPath & ".vanillabak"
  if not fileExists(backup):
    raise newException(PatchXexError,
      "no backup found at " & backup & " — nothing to restore")
  if fileExists(xexPath):
    removeFile(xexPath)
  moveFile(backup, xexPath)
