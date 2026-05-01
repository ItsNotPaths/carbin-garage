## Carbin transcode (FM4 TypeId 3 ↔ FH1 TypeId 5).
##
## **THIS FILE IS A v0 STUB.** The locked Phase 2b strategy is "Option C
## hybrid donor splice" — donor's archive is the scaffold, and the source
## car's section bytes (vertex pool, index pool, transform, bounds,
## m_UVOffsetScale) get re-quantized into the donor's TypeId-flavored
## slots. See `docs/FH1_CARBIN_TYPEID5.md` §"Practical implications for
## porting" and the project memory "Carbin transcode handoff" for the
## full design.
##
## v0 = donor passthrough. `transcodeCarbin` returns the donor bytes
## **verbatim**. The point is to wire the rest of the port-to pipeline
## (zip rewrite + DB patch + filename casing + atomic write) and prove
## the runtime accepts a method-0 mixed zip on a port-to'd path before
## sinking time into the transcode RE work. A v0-ported car renders the
## donor's mesh; the source's textures + DB rows still get applied.
##
## The call site in `port-to` doesn't change between v0 and v1 — the
## function signature stays put. Slice B replaces the body.

import ./model
import ./parser
import ../profile

type
  TranscodeError* = object of CatchableError

  TranscodeMode* = enum
    ## Which body the transcode call uses. `tmDonorVerbatim` is the v0
    ## stub. `tmHybridSplice` is Phase 2b proper and is currently
    ## unimplemented — calling with that mode raises.
    tmDonorVerbatim
    tmHybridSplice

  TranscodeReport* = object
    mode*: TranscodeMode
    sourceVersion*: CarbinVersion
    sourceTypeId*: uint32
    sourceSections*: int
    donorVersion*: CarbinVersion
    donorTypeId*: uint32
    donorSections*: int
    note*: string

proc expectedDonorVersion(targetProfile: GameProfile): CarbinVersion =
  ## We validate the donor by *family* (CarbinVersion), not by exact
  ## TypeId, because real game archives ship multiple TypeIds in the
  ## same family. Empirical:
  ##   - FM4 main carbins ship as both TypeId 2 (no damage table) and
  ##     TypeId 3 (full damage). `parseFm4Carbin` handles both.
  ##   - FM4 caliper / rotor LOD0s are TypeId 1 (also cvFour).
  ##   - FH1 main carbins are TypeId 5 (cvFive); FH1 caliper / rotor
  ##     are TypeId 1 with the cvFive layout (`second == 0x11`).
  case targetProfile.carbinTypeId
  of 5: cvFive
  of 1, 2, 3: cvFour
  else: cvUnknown

proc validateDonor(donorData: openArray[byte],
                   targetProfile: GameProfile): tuple[ver: CarbinVersion;
                                                      info: CarbinInfo] =
  ## Confirm the donor parses cleanly and its TypeId matches what the
  ## target game expects. Caller surfaces failure as a TranscodeError so
  ## the orchestrator can fall back or abort.
  let ver = getVersion(donorData)
  if ver == cvUnknown:
    raise newException(TranscodeError, "donor carbin: unknown version")
  let info =
    try: parseFm4Carbin(donorData)
    except CatchableError as e:
      raise newException(TranscodeError, "donor carbin parse failed: " & e.msg)
  let expected = expectedDonorVersion(targetProfile)
  if expected != cvUnknown and ver != expected:
    raise newException(TranscodeError,
      "donor carbin version " & $ver & " does not match target profile " &
      targetProfile.id & " (expected " & $expected & ")")
  result = (ver, info)

proc validateSource(sourceData: openArray[byte]): tuple[ver: CarbinVersion;
                                                        info: CarbinInfo] =
  ## Source must parse cleanly so v1 can pull section bytes out of it.
  ## v0 doesn't touch the source bytes, but we still parse so the report
  ## carries real numbers and the caller catches obviously-corrupt input
  ## before writing it to disk.
  let ver = getVersion(sourceData)
  if ver == cvUnknown:
    raise newException(TranscodeError, "source carbin: unknown version")
  let info =
    try: parseFm4Carbin(sourceData)
    except CatchableError as e:
      raise newException(TranscodeError, "source carbin parse failed: " & e.msg)
  result = (ver, info)

proc transcodeCarbin*(sourceData, donorData: openArray[byte],
                      targetProfile: GameProfile,
                      mode: TranscodeMode = tmDonorVerbatim
                     ): tuple[bytes: seq[byte]; report: TranscodeReport] =
  ## Transcode `sourceData` into a carbin valid for `targetProfile`,
  ## using `donorData` as the scaffold.
  ##
  ## v0 (`tmDonorVerbatim`): returns `donorData` verbatim. The source is
  ## still parsed for validation + to populate the report; the source's
  ## bytes do not affect the output.
  ##
  ## v1 (`tmHybridSplice`, Phase 2b): NOT IMPLEMENTED — raises
  ## TranscodeError. Will re-quantize source sections into donor slots.
  let (srcVer, srcInfo) = validateSource(sourceData)
  let (donVer, donInfo) = validateDonor(donorData, targetProfile)

  case mode
  of tmDonorVerbatim:
    var copy = newSeq[byte](donorData.len)
    for i in 0 ..< donorData.len: copy[i] = donorData[i]
    let report = TranscodeReport(
      mode: tmDonorVerbatim,
      sourceVersion: srcVer, sourceTypeId: srcInfo.typeId,
      sourceSections: srcInfo.sections.len,
      donorVersion: donVer, donorTypeId: donInfo.typeId,
      donorSections: donInfo.sections.len,
      note: "v0 stub: donor bytes returned verbatim; source mesh discarded")
    result = (copy, report)
  of tmHybridSplice:
    raise newException(TranscodeError,
      "tmHybridSplice not implemented yet (Phase 2b — see " &
      "docs/FH1_CARBIN_TYPEID5.md §\"Practical implications for porting\")")

proc passthroughCarbin*(donorData: openArray[byte]): seq[byte] =
  ## For carbin slots the v0 plan keeps unchanged regardless of mode:
  ## `stripped_*.carbin`, caliper / rotor LOD0s, and (initially) lod0 +
  ## cockpit. No validation — these may be format variants we don't
  ## parse (TypeId 0 stripped). Just hands back the donor's bytes.
  result = newSeq[byte](donorData.len)
  for i in 0 ..< donorData.len: result[i] = donorData[i]
