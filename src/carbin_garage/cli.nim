## CLI subcommand router. Phase-1 commands target FM4 only.

import std/[json, os, strutils, times]
import ./core/profile
import ./core/xds
import ./core/cardb
import ./core/mounts
import ./orchestrator/importwc
import ./orchestrator/scan
import ./orchestrator/mount as mountop
import ./orchestrator/exportto
import ./orchestrator/portto
import ./orchestrator/portto_dlc
import ./orchestrator/patchxex
import ./core/xex2_patches
import ./core/carbin/emitter as carbin_emitter

const
  NAME = "carbin-garage"
  VERSION = "0.0.1"

proc usage*() =
  echo NAME & " " & VERSION & """

usage:
  carbin-garage version
  carbin-garage import <car.zip> [--out <workingDir>] [--profile <id>] [--slug <name>]
                                  [--all-variants]
                                            All LODs (main + lod0 + cockpit
                                            + the 4 caliper / 4 rotor LOD0s)
                                            are emitted into one car.gltf so
                                            the file is a complete porting
                                            payload. Each mesh's
                                            `extras.carbin.lodKind` tags it
                                            as main / lod0 / cockpit / corner
                                            so DCC tools and our UI can
                                            filter at display time.
                                            --all-variants: include race-kit
                                            body-panel variants (wingrace,
                                            bumperFrace, cagerace, etc.).
                                            Variant bytes always round-trip
                                            either way; this flag only
                                            controls the visible-LOD glTF.
  carbin-garage export <working-car-dir> <out.zip>
                                            Phase-1 export = copy
                                            .archive/source.zip verbatim. Byte-exact
                                            unless geometry/ has been modified
                                            (re-encode path is Phase 2).
  carbin-garage roundtrip <car.zip> [--profile <id>]
                                            Import then export to a temp file and
                                            cmp against the original. Default
                                            profile fm4; pass --profile fh1
                                            for Horizon zips.
  carbin-garage decode-xds <in.xds> [<out>] [--ppm] [--no-detile] [--no-swap]
                                            Decode an Xbox 360 D3DBaseTexture
                                            (.xds) to PNG (default) or PPM.
                                            Top mip only for now. Output path
                                            defaults to <in>.png / <in>.ppm.
                                            --no-detile / --no-swap are
                                            bug-isolation flags.
  carbin-garage encode-xds <in.png> <orig.xds> [<out.xds>] [--highqual]
                                            Encode a PNG back into the .xds
                                            container, preserving the original
                                            header and matching its mip-chain
                                            length. Output defaults to
                                            <orig.xds>.new. --highqual runs
                                            stb_dxt's 2-pass refinement
                                            (~30% slower).
  carbin-garage reencode-textures <working-car> [--highqual]
                                            Walk working/<slug>/textures/ and
                                            re-encode every .xds whose
                                            sibling .xds.png is newer. The
                                            .xds is updated in place. Splicing
                                            the result into the export zip
                                            needs the LZX encoder (Phase 2b).
  carbin-garage dump-cardb <game-folder> <car-name> [--profile <id>] [--out <file>]
                                            Pull the per-car DB snippet out of
                                            <game-folder>/<gamedbPath> for
                                            <car-name> (= MediaName, e.g.
                                            ALF_8C_08). Default profile fm4.
                                            Writes the snippet to <file>, or
                                            stdout if --out is omitted.
  carbin-garage list <game-folder>          List car archives in a game's
                                            cars dir. Auto-detects the
                                            profile by looking for
                                            <folder>/<profile.cars>.
  carbin-garage mount <game-folder>         Register <game-folder> in
                                            ~/.config/carbin-garage/mounts.json
                                            keyed by the auto-detected
                                            game-id. Subsequent commands
                                            (export-to) take a game-id
                                            instead of a path.
  carbin-garage mounts                      List registered mounts.
  carbin-garage export-to <working-car> <game-id> [--dry-run]
                                            Copy working/<car>/.archive/source.zip
                                            into the game's cars dir as
                                            <car>.zip. Atomic write via
                                            <target>.tmp + rename. If the
                                            target exists, it's moved to
                                            <target>.bak first; refuses if
                                            <target>.bak already exists.
                                            --dry-run prints the plan
                                            without touching disk.
  carbin-garage port-to <working-car> <target-game-id> --donor <donor-slug>
                                            [--name <new-slug>] [--dry-run]
                                            [--replace-db]
                                            Cross-game port. Donor's archive
                                            scaffolds the export; source's
                                            textures + carbin slots are
                                            spliced in (v0: carbins are
                                            donor-verbatim, real transcode
                                            lands in Slice B). DB row is
                                            patched into target gamedb.slt
                                            using donor's row as template;
                                            BaseCost=1 forced. Atomic zip
                                            write via tmp + .bak rename.
                                            --replace-db deletes any
                                            existing rows for the new
                                            MediaName before insert.
  carbin-garage port-to-dlc <working-car> <target-game-id> --donor <donor-slug>
                                            --content <xenia-content-dir>
                                            [--name <new-slug>] [--profile-id <hex>]
                                            [--replace] [--skip-merge-slt]
                                            [--dry-run] [--uninstall]
                                            New-car port via DLC packaging.
                                            Emits a complete xenia DLC tree
                                            at <content>/<profile-id>/<title>/00000002/<package>/
                                            with zipmount.xml + puboffer +
                                            cars/wheels zips + merge.slt
                                            (56 per-car-data tables cloned from
                                            the donor with IDs rewritten).
                                            UNLIKE port-to: does NOT touch
                                            base gamedb.slt or zipmanifest.
                                            --replace removes any existing
                                            package at the same package-id
                                            first. --skip-merge-slt writes
                                            everything except the merge.slt —
                                            useful for inspecting the package
                                            tree shape without touching the DB.
                                            --uninstall removes the package
                                            tree for the given slug + content
                                            and exits.
  carbin-garage patch-xex <path-to-default.xex> [--dry-run] [--restore]
                                            Patch the FH1 default.xex to disable
                                            integrity checks for moddable files
                                            (gamedb.slt + 8 media zips). Required
                                            before any port-to deploy can load
                                            in-game without dirty-disc errors.
                                            10-site, 66-byte patch in .rdata.
                                            Atomic: <xex>.vanillabak holds the
                                            original. --restore swaps the bak
                                            back over the active xex.
  carbin-garage diff <a.zip> <b.zip>        (Phase 1, TODO)
"""

proc parseFlag(args: openArray[string], flag: string): string =
  for i, a in args:
    if a == flag and i + 1 < args.len: return args[i + 1]
  return ""

proc cmdImport(args: seq[string]) =
  if args.len == 0:
    echo "import: missing <car.zip>"; quit 1
  let zipPath = args[0]
  let outDir = block:
    let v = parseFlag(args, "--out")
    if v.len > 0: v else: "working"
  let profileId = block:
    let v = parseFlag(args, "--profile")
    if v.len > 0: v else: "fm4"
  let slug = parseFlag(args, "--slug")
  let allVariants = "--all-variants" in args
  let prof = loadProfileById(profileId)
  let dest = importToWorking(zipPath, prof, outDir, slug, allVariants)
  echo "imported -> ", dest

proc filesEqual(a, b: string): bool =
  let sa = readFile(a)
  let sb = readFile(b)
  result = sa == sb

proc cmdExport(args: seq[string]) =
  ## Phase-1 export: copy the stashed source.zip out. Until the LZX
  ## encoder is wired up (Phase 2), this is the only path that
  ## guarantees byte-equal output. Edits in geometry/ are silently
  ## ignored — the archive is unchanged from import time.
  if args.len < 2:
    echo "export: missing <working-car-dir> <out.zip>"; quit 1
  let workDir = args[0]
  let outPath = args[1]
  let src = workDir / ".archive" / "source.zip"
  if not fileExists(src):
    echo "export: no .archive/source.zip in ", workDir
    echo "  (re-import the car so it gets stashed)"
    quit 1
  copyFile(src, outPath)
  echo "exported -> ", outPath, " (byte-equal copy of source.zip)"

proc cmdRoundtrip(args: seq[string]) =
  ## Round-trip acceptance test: import a zip, then export and compare
  ## byte-for-byte against the source. Phase-1 path passes trivially
  ## because export is a copy of .archive/source.zip; this still proves
  ## the pipeline preserves every byte and that the stash is intact.
  if args.len == 0:
    echo "roundtrip: missing <car.zip>"; quit 1
  let zipPath = args[0]
  let profileId = block:
    let v = parseFlag(args, "--profile")
    if v.len > 0: v else: "fm4"
  let prof = loadProfileById(profileId)
  let tmpRoot = getTempDir() / "carbin-garage-roundtrip"
  removeDir(tmpRoot)
  let workCar = importToWorking(zipPath, prof, tmpRoot)
  let exportPath = tmpRoot / "exported.zip"
  copyFile(workCar / ".archive" / "source.zip", exportPath)
  if filesEqual(zipPath, exportPath):
    echo "roundtrip OK [", profileId, "]: ", zipPath, " == ", exportPath
  else:
    echo "roundtrip FAIL [", profileId, "]: bytes differ"
    quit 1

proc cmdDecodeXds(args: seq[string]) =
  ## Phase 2c.1 validation verb: decode one .xds to PNG / PPM. Prints
  ## the parsed header so we can eyeball format + dimensions before
  ## opening the image.
  if args.len == 0:
    echo "decode-xds: missing <in.xds>"; quit 1
  let inPath = args[0]
  let asPpm = "--ppm" in args
  let detile = "--no-detile" notin args
  let swap = "--no-swap" notin args
  let outPath =
    if args.len >= 2 and not args[1].startsWith("--"): args[1]
    else: inPath & (if asPpm: ".ppm" else: ".png")

  let raw = readFile(inPath)
  var bytes = newSeq[byte](raw.len)
  for i, c in raw: bytes[i] = byte(c)

  let h = parseXdsHeader(bytes)
  echo "  header: ", formatName(h.dataFormat), "  ",
       h.width, "x", h.height,
       "  payload=", h.payloadSize, " bytes",
       "  detile=", detile, " swap=", swap

  let img = decodeXds(bytes, detile = detile, endianSwap = swap)
  if asPpm: writePpm(outPath, img)
  else:     writePng(outPath, img)
  echo "decoded -> ", outPath

proc reencodeTextureDir*(texDir: string, mode: cint = StbDxtNormal): int =
  ## Re-encode every .xds in `texDir` whose sibling .xds.png is newer
  ## (the user-visible edit signal). Returns the count of rewritten .xds
  ## files. Idempotent — running twice on a clean tree does nothing.
  ## The .xds is updated in place so working-tree round-trip stays
  ## byte-equal *until* a PNG is touched. Splicing the patched .xds back
  ## into .archive/source.zip needs the LZX encoder (Phase 2b) and is
  ## not done here.
  result = 0
  if not dirExists(texDir): return
  for kind, p in walkDir(texDir):
    if kind != pcFile: continue
    if not p.toLowerAscii().endsWith(".xds"): continue
    let pngPath = p & ".png"
    if not fileExists(pngPath): continue
    if getLastModificationTime(pngPath) <= getLastModificationTime(p): continue
    try:
      let img = readPng(pngPath)
      let raw = readFile(p)
      var orig = newSeq[byte](raw.len)
      for i, c in raw: orig[i] = byte(c)
      let h = parseXdsHeader(orig)
      if img.width != h.width or img.height != h.height:
        echo "  - reencode skipped (dim mismatch): ", extractFilename(p),
             "  orig ", h.width, "x", h.height, " png ", img.width, "x", img.height
        continue
      let encoded = encodeXdsFromOriginal(img.rgba, img.width, img.height,
                                           orig, mode)
      var f = open(p, fmWrite)
      defer: f.close()
      if encoded.len > 0: discard f.writeBytes(encoded, 0, encoded.len)
      echo "  + reencoded ", extractFilename(p), " (", encoded.len, " bytes)"
      inc result
    except CatchableError as e:
      echo "  - reencode failed: ", extractFilename(p), " (", e.msg, ")"

proc cmdReencodeTextures(args: seq[string]) =
  ## Sweep working/<slug>/textures/ for any .xds whose sibling .png is
  ## newer; re-encode in place. Useful as a manual step (or from the UI)
  ## between editing a PNG and running export-to.
  if args.len == 0:
    echo "reencode-textures: missing <working-car>"; quit 1
  let workCar = args[0]
  let texDir = workCar / "textures"
  if not dirExists(texDir):
    echo "reencode-textures: no textures/ in ", workCar; quit 1
  let mode: cint =
    if "--highqual" in args: cint(StbDxtHighQual)
    else: cint(StbDxtNormal)
  let n = reencodeTextureDir(texDir, mode)
  echo (if n == 0: "no edits to apply" else: $n & " texture(s) re-encoded")

proc cmdEncodeXds(args: seq[string]) =
  ## Phase 2c.3 verb: PNG (or any stb_image-readable file) + the original
  ## .xds → a new .xds with the user's edits baked in. The original is
  ## read for its header (format-id, dimensions, mip-range) and payload
  ## length (chain count); only the BC payload bytes change.
  if args.len < 2:
    echo "encode-xds: missing <in.png> <orig.xds>"; quit 1
  let pngPath = args[0]
  let origPath = args[1]
  let outPath =
    if args.len >= 3 and not args[2].startsWith("--"): args[2]
    else: origPath & ".new"
  let mode: cint =
    if "--highqual" in args: cint(StbDxtHighQual)
    else: cint(StbDxtNormal)

  let img = readPng(pngPath)
  let raw = readFile(origPath)
  var orig = newSeq[byte](raw.len)
  for i, c in raw: orig[i] = byte(c)
  let h = parseXdsHeader(orig)
  if img.width != h.width or img.height != h.height:
    echo "encode-xds: dim mismatch — original ", h.width, "x", h.height,
         ", PNG ", img.width, "x", img.height
    quit 1
  echo "  encoding: ", formatName(h.dataFormat), "  ",
       img.width, "x", img.height,
       "  mips=", inferMipCount(img.width, img.height,
                                 h.dataFormat, h.payloadSize),
       "  mode=", (if mode == cint(StbDxtHighQual): "highqual" else: "normal")
  let encoded = encodeXdsFromOriginal(img.rgba, img.width, img.height,
                                       orig, mode)
  var f = open(outPath, fmWrite)
  defer: f.close()
  if encoded.len > 0: discard f.writeBytes(encoded, 0, encoded.len)
  echo "encoded -> ", outPath, " (", encoded.len, " bytes)"

proc cmdDumpCardb(args: seq[string]) =
  ## Read a game's gamedb.slt directly (no zip walk, no working/ tree)
  ## and print the per-car snippet. Useful for inspecting what we'd
  ## bundle alongside the working car without committing to an import.
  if args.len < 2:
    echo "dump-cardb: missing <game-folder> <car-name>"; quit 1
  let gameFolder = args[0]
  let carName = args[1]
  let profileId = block:
    let v = parseFlag(args, "--profile")
    if v.len > 0: v else: "fm4"
  let outPath = parseFlag(args, "--out")
  let prof = loadProfileById(profileId)
  if prof.gamedbPath.len == 0:
    echo "dump-cardb: profile ", profileId, " has no gamedbPath"; quit 1
  let dbPath = gameFolder / prof.gamedbPath
  let snippet = extractCarDb(dbPath, carName, profileId)
  let body = snippet.pretty
  if outPath.len > 0:
    writeFile(outPath, body)
    echo "wrote -> ", outPath, " (", snippet["tables"].len, " tables)"
  else:
    echo body

proc humanSize(bytes: BiggestInt): string =
  const units = ["B", "KiB", "MiB", "GiB"]
  var v = bytes.float
  var i = 0
  while v >= 1024.0 and i < units.high:
    v = v / 1024.0
    inc i
  if i == 0: $bytes & " B"
  else: formatFloat(v, ffDecimal, 1) & " " & units[i]

proc cmdList(args: seq[string]) =
  if args.len == 0:
    echo "list: missing <game-folder>"; quit 1
  let folder = args[0]
  let m = mountGame(folder)
  if m.profileId.len == 0:
    echo "list: could not detect a profile under ", m.folder
    echo "  (no profiles/*.json had its `cars` dir present)"
    quit 1
  let prof = loadProfileById(m.profileId)
  let slots = scanLibrary(m.folder, prof)
  echo prof.displayName, " (", prof.id, ", TitleID ", prof.titleId, ")"
  echo "  ", carsDirFor(m.folder, prof)
  echo "  ", slots.len, " archives"
  for s in slots:
    echo "    ", s.name, "  (", humanSize(s.sizeBytes), ")"

proc cmdMount(args: seq[string]) =
  if args.len == 0:
    echo "mount: missing <game-folder>"; quit 1
  let m = mountGame(args[0])
  if m.profileId.len == 0:
    echo "mount: could not detect a profile under ", m.folder
    echo "  (expected one of profiles/*.json's `cars` dir to exist)"
    quit 1
  var all = loadMounts()
  let existed = findMount(all, m.profileId) >= 0
  upsertMount(all, m.profileId, m.folder)
  saveMounts(all)
  echo (if existed: "updated " else: "mounted "), m.profileId, " -> ", m.folder
  echo "  (registry: ", mountsFile(), ")"

proc cmdMounts(args: seq[string]) =
  let all = loadMounts()
  if all.len == 0:
    echo "no mounts registered (", mountsFile(), ")"
    return
  echo mountsFile(), ":"
  for m in all:
    let exists = dirExists(m.folder)
    echo "  ", m.gameId, "  ", m.folder, (if exists: "" else: "  [missing]")

proc cmdExportCarbin(args: seq[string]) =
  ## Stage 2: glTF → carbin re-emit. Today's scope: round-trip every
  ## carbin from `working/<slug>/.archive/source.zip` to
  ## `working/<slug>/geometry/<name>.carbin.regen`. Edit-emission is
  ## the deferred follow-up; today the emitter passes donor bytes
  ## verbatim (so byte-equal round-trip is trivial).
  ##
  ##   carbin-garage export-carbin <slug-or-working-dir> [--strict]
  if args.len == 0:
    echo "export-carbin: missing <slug-or-working-dir>"; quit 1
  let arg = args[0]
  let strict = "--strict" in args
  # Accept both a bare slug (resolved relative to ./working/) and an
  # absolute / relative working-car path.
  var workDir = ""
  if dirExists(arg): workDir = arg
  elif dirExists("working" / arg): workDir = "working" / arg
  else:
    echo "export-carbin: not a working dir: ", arg
    quit 1
  try:
    let report = exportCarbinsFromWorking(workDir, strict = strict)
    echo "export-carbin -> ", workDir / "geometry"
    echo "  carbins written: ", report.carbinsWritten,
         " (", report.bytesWritten, " bytes)"
    echo "  fell through to donor: ", report.fellThroughToDonor,
         " / edited: ", report.sectionsEdited
    if report.warnings.len > 0:
      echo "  warnings:"
      for w in report.warnings: echo "    - ", w
  except IOError as e:
    echo "export-carbin: ", e.msg
    quit 1

proc cmdPatchXex(args: seq[string]) =
  if args.len == 0:
    echo "patch-xex: missing <path-to-default.xex>"; quit 1
  let xexPath = args[0]
  let restore = "--restore" in args
  let dryRun = "--dry-run" in args
  if restore:
    try:
      executeRestore(xexPath)
      echo "restored vanilla xex at ", xexPath
    except PatchXexError as e:
      echo "patch-xex: ", e.msg; quit 1
    return
  let plan =
    try: planPatch(xexPath, Fh1IntegrityBypassPatch)
    except PatchXexError as e:
      echo "patch-xex: ", e.msg; quit 1
  echo "patch-xex: ", plan.patchSet.name
  stdout.write describePlan(plan)
  if dryRun:
    echo "  (dry-run — no files touched)"
    return
  if plan.allSitesAlreadyPatched:
    echo "  no-op (already patched)"
    return
  try:
    executePatch(plan)
  except PatchXexError as e:
    echo "patch-xex: ", e.msg; quit 1
  echo "  wrote ", xexPath, "  (vanilla saved at ", plan.backupPath, ")"

proc cmdPortTo(args: seq[string]) =
  if args.len < 2:
    echo "port-to: missing <working-car> <target-game-id>"; quit 1
  let workingCar = args[0]
  let gameId = args[1]
  let donor = parseFlag(args, "--donor")
  if donor.len == 0:
    echo "port-to: --donor <donor-slug> is required"
    echo "  (the donor must be a real car already shipping in the target game)"
    quit 1
  let newName = parseFlag(args, "--name")
  let dryRun = "--dry-run" in args
  let replaceDb = "--replace-db" in args
  let fromDonorOnly = "--from-donor-only" in args
  let noEntryRename = "--no-entry-rename" in args
  let all = loadMounts()
  let i = findMount(all, gameId)
  if i < 0:
    echo "port-to: no mount registered for game-id '", gameId, "'"
    echo "  (run: carbin-garage mount <game-folder>)"
    quit 1
  let prof = loadProfileById(gameId)
  let plan =
    try: planPort(workingCar, all[i], prof, donor, newName, fromDonorOnly, noEntryRename)
    except PortError as e:
      echo "port-to: ", e.msg; quit 1
  echo "port-to [", gameId, "]: ", plan.sourceSlug, " -> ", plan.newSlug,
       "  (donor: ", plan.donorSlug, ")"
  stdout.write describePlan(plan)
  if dryRun:
    echo "  (dry-run — no files touched)"
    return
  try:
    executePort(plan, replaceDb = replaceDb)
  except PortError as e:
    echo "port-to: ", e.msg; quit 1
  if plan.targetExists:
    echo "  wrote ", plan.targetZip, " (previous saved at ", plan.backupPath, ")"
  else:
    echo "  wrote ", plan.targetZip
  if plan.targetGamedb.len > 0:
    echo "  patched ", plan.targetGamedb

proc cmdPortToDlc(args: seq[string]) =
  if args.len < 2:
    echo "port-to-dlc: missing <working-car> <target-game-id>"; quit 1
  let workingCar = args[0]
  let gameId = args[1]
  let donor = parseFlag(args, "--donor")
  let contentRoot = parseFlag(args, "--content")
  let newName = parseFlag(args, "--name")
  let profileId = block:
    let v = parseFlag(args, "--profile-id")
    if v.len > 0: v else: "0000000000000000"
  let replace = "--replace" in args
  let skipMerge = "--skip-merge-slt" in args
  let dryRun = "--dry-run" in args
  let uninstall = "--uninstall" in args
  let dlcIdOverride = block:
    let v = parseFlag(args, "--dlc-id")
    if v.len > 0:
      try: parseInt(v)
      except CatchableError:
        echo "port-to-dlc: --dlc-id must be an integer"; quit 1
    else: 0
  let forcedCarId = block:
    let v = parseFlag(args, "--car-id")
    if v.len > 0:
      try: parseInt(v)
      except CatchableError:
        echo "port-to-dlc: --car-id must be an integer"; quit 1
    else: 0
  let forcedEngineId = block:
    let v = parseFlag(args, "--engine-id")
    if v.len > 0:
      try: parseInt(v)
      except CatchableError:
        echo "port-to-dlc: --engine-id must be an integer"; quit 1
    else: 0
  if donor.len == 0:
    echo "port-to-dlc: --donor <donor-slug> is required"; quit 1
  if contentRoot.len == 0:
    echo "port-to-dlc: --content <xenia-content-dir> is required"
    echo "  (the directory that holds <profile-id>/<title-id>/...)"
    quit 1
  let all = loadMounts()
  let i = findMount(all, gameId)
  if i < 0:
    echo "port-to-dlc: no mount registered for game-id '", gameId, "'"
    echo "  (run: carbin-garage mount <game-folder>)"
    quit 1
  let prof = loadProfileById(gameId)
  let plan =
    try: planPortToDlc(workingCar, all[i], prof, contentRoot, donor,
                        newName, profileId, dlcIdOverride,
                        forcedCarId, forcedEngineId)
    except DlcPortError as e:
      echo "port-to-dlc: ", e.msg; quit 1
  echo "port-to-dlc [", gameId, "]: ", plan.sourceSlug, " -> ", plan.newSlug,
       "  (donor: ", plan.donorSlug, ")"
  stdout.write describePlan(plan)
  if uninstall:
    if plan.packageExists:
      uninstallPortToDlc(plan)
      echo "  uninstalled ", plan.packageDir
    else:
      echo "  no package at ", plan.packageDir, " — nothing to uninstall"
    return
  if dryRun:
    echo "  (dry-run — no files touched)"
    return
  try:
    executePortToDlc(plan, replace = replace, skipMergeSlt = skipMerge)
  except DlcPortError as e:
    echo "port-to-dlc: ", e.msg; quit 1
  echo "  wrote package at ", plan.packageDir
  if skipMerge:
    echo "  (merge.slt skipped — car will not load until --skip-merge-slt is dropped)"

proc cmdExportTo(args: seq[string]) =
  if args.len < 2:
    echo "export-to: missing <working-car> <game-id>"; quit 1
  let workingCar = args[0]
  let gameId = args[1]
  let dryRun = "--dry-run" in args
  let all = loadMounts()
  let i = findMount(all, gameId)
  if i < 0:
    echo "export-to: no mount registered for game-id '", gameId, "'"
    echo "  (run: carbin-garage mount <game-folder>)"
    quit 1
  let prof = loadProfileById(gameId)
  let plan =
    try: planExport(workingCar, all[i], prof)
    except ExportError as e:
      echo "export-to: ", e.msg; quit 1
  echo "export-to [", gameId, "]: ", plan.slug
  stdout.write describePlan(plan)
  if dryRun:
    echo "  (dry-run — no files touched)"
    return
  try:
    executeExport(plan)
  except ExportError as e:
    echo "export-to: ", e.msg; quit 1
  if plan.targetExists:
    echo "  wrote ", plan.targetZip, " (previous saved at ", plan.backupPath, ")"
  else:
    echo "  wrote ", plan.targetZip

proc mainWithArgs*(args: openArray[string]) =
  if args.len == 0:
    usage(); quit(0)
  let cmd = args[0].toLowerAscii()
  var rest: seq[string] = @[]
  for i in 1 ..< args.len:
    rest.add(args[i])
  case cmd
  of "version", "--version", "-v":
    echo VERSION
  of "help", "--help", "-h":
    usage()
  of "import":
    cmdImport(rest)
  of "export":
    cmdExport(rest)
  of "roundtrip":
    cmdRoundtrip(rest)
  of "decode-xds":
    cmdDecodeXds(rest)
  of "encode-xds":
    cmdEncodeXds(rest)
  of "reencode-textures":
    cmdReencodeTextures(rest)
  of "dump-cardb":
    cmdDumpCardb(rest)
  of "list":
    cmdList(rest)
  of "mount":
    cmdMount(rest)
  of "mounts":
    cmdMounts(rest)
  of "export-to":
    cmdExportTo(rest)
  of "port-to":
    cmdPortTo(rest)
  of "port-to-dlc":
    cmdPortToDlc(rest)
  of "patch-xex":
    cmdPatchXex(rest)
  of "export-carbin":
    cmdExportCarbin(rest)
  else:
    echo "TODO: command '" & cmd & "' not yet implemented"
    quit(1)

proc main*() =
  var args: seq[string] = @[]
  for i in 1 .. paramCount():
    args.add(paramStr(i))
  mainWithArgs(args)
