## Cross-game texture porting plan. Phase 2c.3.
##
## When a source car X is being ported into a target game's archive, its
## textures need to land under names the *target's* shader name-set
## expects. The Forza .xds container is byte-compatible across FM4 and
## FH1 (verified empirically — `probe/probe_xds_pair_diff.py` shows zero
## header / size deltas across all 22 paired buckets and 8 sample cars),
## so the move is a name-and-case rewrite + a donor splice for buckets
## that exist on the target side but not the source side.
##
## Rules:
##   - Shared buckets (the 22 names that exist in both FM4 and FH1)
##     copy verbatim, with the basename re-cased to the target's
##     casing convention (FH1 capitalizes `_LOD0`; FM4 lowercases).
##   - Buckets on `target.extraXdsBuckets` that the source car does
##     not have are spliced from the donor's archive.
##   - Buckets on `source.extraXdsBuckets` that the target does not
##     declare are dropped (e.g., FH1→FM4 drops the 3 zlights /
##     interior_emissive textures).
##
## This planner is structural — it produces a plan (list of ops) and
## doesn't touch disk by itself. Validation works by running it across
## paired sample cars and checking the resulting name set matches what
## the target game actually ships for that car.

import std/[os, sets, strutils, tables]
import ./profile

type
  TextureOpKind* = enum
    topCopySource    ## Copy source-car .xds verbatim (re-cased)
    topSpliceDonor   ## Copy donor's .xds verbatim (re-cased)
    topDropExtra     ## Source has bucket the target doesn't declare; skip

  TextureOp* = object
    kind*:        TextureOpKind
    bucket*:      string         ## canonical lowercased basename
    sourceName*:  string         ## as it appears in source/donor on disk
    targetName*:  string         ## as it should appear in target archive

  TexturePortPlan* = object
    target*:        string                ## target profile id
    sourceCount*:   int
    donorCount*:    int
    droppedCount*:  int
    ops*:           seq[TextureOp]

proc bucketKey*(filename: string): string =
  ## Lowercase basename without `.xds` extension. The "canonical" key
  ## for matching across games (FH1's `interior_emissive_LOD0.xds` and
  ## a hypothetical lowercased import both map to
  ## `interior_emissive_lod0`).
  let b = extractFilename(filename)
  let lc = b.toLowerAscii()
  result = if lc.endsWith(".xds"): lc[0 ..< lc.len - 4] else: lc

proc applyTargetCasing*(bucket: string, target: GameProfile): string =
  ## Project a lowercase canonical bucket name into the target game's
  ## on-disk casing. Both games store extensions lowercase; only the
  ## body convention varies.
  ##   - FM4 (`Mixed`): keep lowercase (matches what FM4 ships).
  ##   - FH1 (`Lower`): apply the capitalization that FH1 uses for
  ##     LOD-suffixed buckets — `_lod0` → `_LOD0`. Profile-declared
  ##     extras like `interior_emissive_LOD0` are passed through with
  ##     the casing they were declared in (so FH1 only needs to enumerate
  ##     its quirks once, in profiles/fh1.json).
  let extras = target.extraXdsBuckets
  for ex in extras:
    if ex.toLowerAscii() == bucket:
      return ex & ".xds"
  case target.id
  of "fh1":
    if bucket.endsWith("_lod0"):
      result = bucket[0 ..< bucket.len - 5] & "_LOD0.xds"
    else:
      result = bucket & ".xds"
  else:
    result = bucket & ".xds"

proc planTexturePort*(sourceTextures: seq[string],
                      donorTextures: seq[string],
                      sourceProfile, targetProfile: GameProfile): TexturePortPlan =
  ## Build the op list for a port. `sourceTextures` / `donorTextures` are
  ## .xds basenames (no path). `sourceProfile` is the originating game,
  ## `targetProfile` is where the car is being ported.
  result.target = targetProfile.id
  result.ops = @[]

  # Index by canonical bucket key.
  var sourceByBucket = initTable[string, string]()
  for n in sourceTextures: sourceByBucket[bucketKey(n)] = n
  var donorByBucket = initTable[string, string]()
  for n in donorTextures: donorByBucket[bucketKey(n)] = n

  # Targets-extras: lowercase bucket key set the target *requires*.
  var targetExtras = initHashSet[string]()
  for x in targetProfile.extraXdsBuckets:
    targetExtras.incl(x.toLowerAscii())

  # Sources-extras: lowercase bucket key set the source declares.
  var sourceExtras = initHashSet[string]()
  for x in sourceProfile.extraXdsBuckets:
    sourceExtras.incl(x.toLowerAscii())

  # 1. Walk source's own textures: shared → copy with retargeted name;
  #    source-extra-but-target-doesnt-declare → drop.
  for bucket in sourceByBucket.keys:
    let sourceName = sourceByBucket[bucket]
    if bucket in sourceExtras and bucket notin targetExtras:
      result.ops.add(TextureOp(kind: topDropExtra,
                               bucket: bucket,
                               sourceName: sourceName,
                               targetName: ""))
      inc result.droppedCount
    else:
      result.ops.add(TextureOp(kind: topCopySource,
                               bucket: bucket,
                               sourceName: sourceName,
                               targetName: applyTargetCasing(bucket, targetProfile)))
      inc result.sourceCount

  # 2. Target-required extras the source doesn't have → splice donor.
  for bucket in targetExtras:
    if bucket in sourceByBucket: continue       # already covered above
    if bucket notin donorByBucket: continue     # donor lacks it too — fail late
    result.ops.add(TextureOp(kind: topSpliceDonor,
                             bucket: bucket,
                             sourceName: donorByBucket[bucket],
                             targetName: applyTargetCasing(bucket, targetProfile)))
    inc result.donorCount

proc resultingNames*(plan: TexturePortPlan): seq[string] =
  ## The final list of .xds basenames in the ported archive.
  result = @[]
  for op in plan.ops:
    if op.kind != topDropExtra:
      result.add(op.targetName)
