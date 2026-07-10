---
status: IN PROGRESS — container + geometry-transcode proven; emitter remains
created: 2026-05-10
updated: 2026-05-28
direction: FH1 (source) → FM4 (target) — reverse of the shipped FM4→FH1 pipeline
---

# FH1 → FM4 porting — investigation & leads

## PROGRESS LOG

**2026-07-10 — pipeline productionized end-to-end in Nim.**

1. **Reverse-transcoded geometry validated IN-GAME** (user, same day):
   swapped fh1→fm4 transcoded carbins into the loose-geometry probe pack —
   "majorly correct and drives fine with only minor visual issues"
   (issues untriaged; candidates: extra8 zero-pad paint analog, donor-
   verbatim lod0/cockpit, texture format drift).
2. **`port-to-dlc <working-car> fm4 --donor <fm4-slug>` now works.**
   `portto_dlc.nim` grew an fm4 layout flavor (`plan.fm4Layout`):
   lowercase package dir, `" \r\n"` puboffer, empty zipmount, empty
   `Media/LicenseMasks`, loose geometry INSIDE the merge overlay at
   `<dlcId>_pri_99/Media/cars/<NAME>/`, and no header/wheels/audio
   pieces. `dlc_merge.buildMergeSlt` gained the fm4 ContentOffers
   flavor (offer-id namespace 5571807128311562241+dlcId, string keys
   `_&3100679600`/`_&3100698426`, PK `<TITLEID><dlcId:08d>`). FH1
   output is unchanged (same SQL text, same paths).
   Fixes riding along: geometry source matching is now case-insensitive
   (FH1-imported working cars have mixed-case filenames and matched
   nothing on a case-sensitive FS); the sibling merge.slt id scan
   matches any `_pri_<N>` priority, not just 99; `dlc_clear`
   identifies fm4 packs by their loose merge.slt (they ship no header).
3. **Validated offline against the in-game-proven probe pack**: emitted
   BMW_1M_11 (fh1) → ALF_8C_08 donor pack at `4d53091015174729`;
   sentinels byte-match the probe, merge.slt structurally identical
   (56 tables, same per-table row counts, correct offer row, snippet
   BaseCost honored), main carbin spliced 27 sections and reparses as
   cvFour with all-32B strides. NOT yet booted in FM4 — that's the
   next xenia run.

**2026-07-10 PM — first cross-car FM4 port debugged (S65AMG on SL65
donor); two systemic fixes landed.**

User exported FH1 MER_S65AMG_12 believing the donor was a "2008 S65" —
FM4 has NO S65; the picked donor fingerprinted (via the pack's cloned
CarPartPositions rows vs base gamedb) to **MER_SL65AMG_09**, a 2.50m-
wheelbase roadster under a 3.17m-wheelbase sedan body. Symptoms
("body too large, wheels wrong place, hitbox off") decomposed as:

1. **Wheels + hitbox come from `Data_CarBody`** (empirically corrected
   same day: the first fix shipped source `MAXData.xml` into
   `physics/maxdata.xml` and changed NOTHING in-game — the XML is only
   the offline source; the runtime reads the db row). `Data_CarBody`
   (sub-id keyed, cloned from donor) carries ModelWheelbase /
   ModelFront-/RearTrackOuter / ride heights + the
   **PristineBoundingBox** (the hitbox). Values are rebaked vs the XML
   (sign flips, adjusted track) so deriving from MAXData is wrong.
   The geometry itself was fine: the 9 part-bound floats are
   byte-identical between FM4/FH1 builds of the same car (verified over
   the 8 sample pairs — bounds semantics equal, transfer correct), so
   the body renders at true source scale and the donor-dimensioned
   frame sat wrong underneath. **Fix**: `cardb.nim:extractCarDb` now
   captures `Data_CarBody` (sub-id range) and `CarPartPositions`
   (Ordinal-keyed anchor points) into the cardb.json snippet; the
   existing export-side overlay then carries source dimensions onto the
   donor clone with ids rewritten. Direction-agnostic — FM4 imports get
   the same capture, so FH1-target ports benefit identically.
   **Existing working cars must be re-imported** (or cardb.json
   regenerated via `extractCarDb`) to pick up the new tables.
   The maxdata.xml splice stays (harmless, keeps the shipped pack
   internally consistent) but is NOT the operative fix.
2. **Interior UV mess = texture/geometry mismatch**, not a transcode
   bug: source's `interior_lod0.xds` was painted onto the
   donor-verbatim cockpit mesh. **Fix**: `*_lod0.xds` buckets now
   follow the lod0/cockpit geometry decision — donor-verbatim unless
   `--lod0-splice-cross-car`. Applies to both port directions (same
   mismatch existed FM4→FH1).

Donor-selection assist: FM4 donors ranked by wheelbase proximity to the
S65's 3.170 — best fits CHR_300C_08 (3.048), AST_Rapide_10 (2.990),
**MER_CL65AMG_10 (2.955, same M275 V12, brand-matched cockpit)**.
Scanner probe: extract `Wheelbase=` from each donor zip's maxdata.xml.

Still donor-verbatim after these fixes (candidate future work):
lod0/cockpit models (splice gate), CarPartPositions rows (part/light
anchor points — importwc doesn't capture the source's; overlay would
need an importwc snippet extension), caranimationevents/skeleton gr2s.

Remaining: (a) boot-test the re-exported S65 pack (`4d53091009448691`,
BaseCost 215000) + the BMW pack; (b) confirm FM4 accepts FH1's sparser
CollSpheres set.

**2026-05-28 — the two hard unknowns are both resolved empirically.**

1. **Container / db (§5): SOLVED.** FM4 honors a DLC
   `Media/db/patch/<dlcId>00_merge.slt` overlay. A hand-built merge.slt
   adding a new `Data_Car` row + `ContentOffers` surfaced a new car in
   autoshow at a chosen `BaseCost`. **No xex integrity patch needed** (§7
   mooted for the DLC path). Option B confirmed the winner. Tool:
   `probe/fm4_merge_probe.py`.

2. **Geometry packaging (§6): SOLVED — LZX/zip blocker is DEAD.** FM4 mounts
   the loose `_pri_NN/` overlay at `game:\` and reads **uncompressed loose
   carbins** from `_pri_NN/Media/cars/<NAME>/*`. A full DLC car shipped as
   loose files (decoded working/ carbins, stem-renamed to the new MediaName)
   **rendered, purchased, and painted correctly in-game.** We never build a
   cars zip → the LZX-encoder blocker is off the critical path entirely.

3. **Geometry transcode reverse (§3): LANDED (offline).** `fh1PoolToFm4`
   (28→32), `downconvertSubsectionCvFiveToCvFour`, and the `crossDown` gate
   are implemented; 8 sample cars splice both directions; forward output is
   byte-identical to baseline. Builder renamed to working/donor vocabulary.
   NOT yet validated in-game (the loose-geometry probe above used base-FM4
   geometry to isolate packaging from transcode correctness).

**Remaining:** (a) in-game validation of the reverse-transcoded geometry
(swap transcoded carbins into the loose-geometry probe); (b) productionize
the FM4 DLC emitter (orchestrator + parametrized buildMergeSlt + working→
on-disk layout map + stem-rename) — see `project_fm4_loose_geometry_confirmed`
and `project_fm4_merge_slt_confirmed` memories for the exact working layout
and the merge.slt id-allocation caveats; (c) stats whitelist (§4); (d) GUI/CLI
wiring. The original §5.3 Option A/B/C decision and the §6 "does FM4 accept
method-0 big entries" question are now moot.

---

The FM4→FH1 direction is shipped and verified (BMW Z8→Z4, 2026-05-10).
This document catalogues every fact, code path, and open question for the
**reverse direction** so implementation can proceed with a complete map.

References in this doc use `path:line` (clickable in Claude Code) or
`docs/<file.md>§<section>` for cross-file pointers.

## 1. Summary of asymmetry

| Concern | FM4→FH1 (shipped) | FH1→FM4 (new) | Trivial / Hard |
|---|---|---|---|
| Carbin parser cvFour ↔ cvFive | both wired (`src/carbin_garage/core/carbin/parser.nim:27,35`) | already bidirectional | trivial |
| Vertex stride | 32→28 truncate (`transcode.nim:161 fm4PoolToFh1`) | 28→32 zero-pad tail | trivial — write `fh1PoolToFm4` |
| Section pre-pool m_NumBoneWeights block | inserted via builder slice | **drop** the 4/8 bytes | trivial — symmetric inversion |
| Subsection +4 bytes before idxCount | `patch.nim:upconvertSubsectionCvFourToCvFive` | new `downconvertSubsectionCvFiveToCvFour` | trivial — symmetric |
| Section tail (12 B longer in FH1) | preserved verbatim via donor template | preserved verbatim via FM4 donor template | trivial — donor scaffolds |
| LOD0 / cockpit post-pool 4B/v stream | passthrough (donor's bytes) | **drop** (FM4 doesn't carry it) | trivial — exclude from tail copy |
| Damage a*b table (per-vertex skinning) | NN spatial remap + table resize (`builders.nim` 2026-05-10 fix) | symmetric — same code path with FM4 donor's table | trivial — fix is direction-agnostic |
| Bounds transfer (9 floats) | source's bounds patched into donor prefix (`builders.nim` 2026-05-10) | symmetric | trivial |
| Header layout (0x4DC vs 0x398) | donor scaffolds — only body bytes change | donor scaffolds — same | trivial |
| TypeId word | 3→5 (donor's typeId, no rewrite needed since donor scaffold supplies it) | 5→3 (same — donor's typeId wins) | trivial |
| `stripped_*.carbin` (FH1-only) | synthesised from main | **drop entirely** | trivial — exclude from output |
| `physicsdefinition.bin` (FH1-only) | donor passthrough | **drop entirely** | trivial — exclude from output |
| `interior_emissive_LOD0.xds`, `zlights*.xds` | donor passthrough | **drop entirely** | trivial — exclude from output |
| `versiondata.xml` (FM4-only) | drop | **synthesise/passthrough from FM4 donor** | trivial — copy donor's |
| `carattribs.xml` Version 16 ↔ 21 | donor's V21 passthrough | use donor's V16 passthrough | trivial — donor wins |
| Stats / db row | donor row + cardb.json overlay merged into FH1 `merge.slt` DLC | **TBD** — see §5 (the real unknown) | **HARD** |
| Output container | DLC overlay tree at FH1 `00000002/<pkg>/` | **TBD** — see §6 | **HARD** |
| LZX encode for new carbin bytes | mixed-method: method-0 for edited + LZX verbatim copy elsewhere | same mixed-method writer reusable | trivial — `zip21_writer.nim` already does it |
| Integrity-bypass xex patch | FH1 patch set (`xex2_patches.nim:Fh1IntegrityBypassPatch`) | **FM4 patch set unknown** — see §7 | medium |

Bottom line: the **carbin geometry transcode is straight inversion** of
shipped code — a few small files. The **container / db / xex story is
the real investigation**, all in §5–§7.

## 2. What's already done that we don't have to redo

These are facts established across many sessions; reverse direction
inherits them all unchanged.

- **Parser** (`src/carbin_garage/core/carbin/parser.nim`): reads both cvFour
  (FM4 TypeId 1/2/3) and cvFive (FH1 TypeId 5 + TypeId 1 with second=0x11).
  `getVersion` at `parser.nim:15` handles both; `parseSection`, `parseSubsection`
  branch on `ver` for every delta. **Reverse direction reads its source
  with `ver=cvFive` already.** No parser work needed.
- **Carbin model** (`core/carbin/model.nim`): `CarbinVersion = enum cvFour | cvFive`
  already symmetric. `SectionInfo` carries `aTableStart/End`, `cTableStart/End`,
  `postPoolStart/End` so emission can splice/strip these regions per direction.
- **Builder** (`core/carbin/builders.nim:buildSectionConvertedToTargetLodOnTargetTemplate`):
  splice path uses donor as scaffold, source vertex/index data drops in.
  Symmetric on `m_NumBoneWeights` pre-pool block — for cvFour donor template,
  `between(lodVertexSizePos+4, lodVerticesStart)` is empty, so the slice
  is a no-op going to cvFour. Same for LOD0 pre-pool.
- **Bounds transfer** (`builders.nim` + `transcode.nim` 2026-05-10):
  source's 9 part-bound floats overwrite donor's at every splice — direction-agnostic.
- **a*b table resize** (`builders.nim` 2026-05-10): patches the
  `a` field + resizes damage table when source/donor vCount differ —
  direction-agnostic. Damage table contents come from donor scaffold; NN
  remap (if needed) is also direction-agnostic.
- **Multi-LOD splice** (2026-05-10): subsection filter accepts `ss.lod>=1`
  for the shared LOD pool — direction-agnostic.
- **Gap preservation** (`transcode.nim:spliceCarbin`): preserves donor
  bytes between parsed sections regardless of which version is donor.
  Reverse direction may emit fewer gaps (FM4 has fewer LOD0-only-in-main
  sections than FH1) but the loop is still a no-op when there are zero gaps.
- **Mixed-method zip writer** (`core/zip21_writer.nim`): emits edited
  entries as method-0 stored, copies untouched entries' LZX bytes verbatim
  with proper `0x1123` extra field. Reusable for any direction.
- **LZX decoder** (`core/lzx.nim`): reads FH1 source carbins fine.
  Method-21 framing in `core/zip21.nim` is direction-agnostic.

## 3. Carbin transcode reverse — exact code shape

`docs/CARBIN_TRANSCODE.md§"Reverse direction (FH1 → FM4): playbook"` has
the spec. Distilled to file:line changes:

### 3.1 New vertex transcode procs
`core/carbin/transcode.nim` — add alongside `fm4PoolToFh1` (line 161):

```nim
const Fh1VertexStride* = 28
const Fm4VertexStride* = 32  # already declared

proc fh1PoolToFm4*(fh1Pool: openArray[byte]): seq[byte] =
  ## Extend each 28-byte FH1 vertex to 32 bytes by appending 4 zero bytes.
  ## FH1 [0..24) maps verbatim to FM4 [0..24). FH1 byte 24 (extra4[0])
  ## stays at FM4 byte 24 (extra8[0]); FM4 extra8[1..7] become zeros
  ## (FH1 doesn't carry the data). See CARBIN_TRANSCODE.md§"Reverse direction".
  if fh1Pool.len mod Fh1VertexStride != 0:
    raise newException(ValueError, ...)
  let n = fh1Pool.len div Fh1VertexStride
  result = newSeq[byte](n * Fm4VertexStride)
  for i in 0 ..< n:
    let src = i * Fh1VertexStride
    let dst = i * Fm4VertexStride
    for j in 0 ..< Fh1VertexStride: result[dst + j] = fh1Pool[src + j]
    # bytes [dst+28..dst+32) stay zero (newSeq default)

proc fh1Lod0PoolToFm4*(fh1Pool: openArray[byte]): seq[byte] = fh1PoolToFm4(fh1Pool)
```

### 3.2 Reverse subsection downconvert
`core/carbin/patch.nim` — add alongside `upconvertSubsectionCvFourToCvFive` (line 71):

```nim
proc downconvertSubsectionCvFiveToCvFour*(...) =
  ## At offset (idxCountPos - 8) cvFive has [u32=4][u32=0]; cvFour has [u32=3].
  ## Patch [u32=4]→[u32=3], drop the 4 trailing zero bytes, shift
  ## SubSectionInfo offsets by -4.
```

### 3.3 Cross-version gate in transcode
`core/carbin/transcode.nim:247` currently:
```nim
let crossVersionStride = (srcVer == cvFour and donVer == cvFive)
```
Replace with two flags:
```nim
let crossUp   = (srcVer == cvFour and donVer == cvFive)
let crossDown = (srcVer == cvFive and donVer == cvFour)
let crossVersion = crossUp or crossDown
```

Then at `transcode.nim:289` and `transcode.nim:370`:
```nim
if crossUp   and srcSec.lodVerticesSize == 32'u32:
  forcedBlob = some(fm4PoolToFh1(srcPool))
  forcedSize = some(uint32(Fh1VertexStride))
elif crossDown and srcSec.lodVerticesSize == 28'u32:
  forcedBlob = some(fh1PoolToFm4(srcPool))
  forcedSize = some(uint32(Fm4VertexStride))
```

Validation gates at `transcode.nim:334` and `transcode.nim:399`:
```nim
if ok and crossUp   and chk.info.lodVerticesSize != 28'u32: ok = false
if ok and crossDown and chk.info.lodVerticesSize != 32'u32: ok = false
```

### 3.4 Builder subsection param
`core/carbin/builders.nim` — the `upconvertSubsectionsCvFourToCvFive: bool`
parameter becomes a direction enum:
```nim
type SubsectionXform = enum sxNone, sxUpToCvFive, sxDownToCvFour
```
or just add a sibling `downconvertSubsectionsCvFiveToCvFour: bool` param.

### 3.5 Post-pool 4B/v stream
The FH1 lod0/cockpit `lod0_v_count * 4` per-vertex stream (per
`docs/FH1_CARBIN_TYPEID5.md§6.5`) lives between the c*d table and the
next section. For FH1→FM4: source has the stream, donor (FM4) doesn't.
The builder's tail-copy uses **donor's** tail verbatim so the stream is
naturally absent — no code change needed. Just confirm by parser
validation that rebuilt section ends at the right boundary.

### 3.6 Test recipe (parallel to CARBIN_TRANSCODE.md§"Test recipe")
```
build/carbin-garage import "<fh1-mount>/media/cars/ALF_8C_08.zip" --profile fh1
build/carbin-garage port-to-... working/ALF_8C_08 fm4 \
  --donor ALF_8C_08 --replace
```
(orchestrator command TBD per §6.)

Expected log:
- `[transcode] alf_8c_08.carbin: spliced=N fallback=0 gaps=0`
- All `stripped_*.carbin`: dropped (no log line)
- `physicsdefinition.bin`: dropped (no log line)

Probe should show rebuilt main carbin reparses as cvFour with
`lodVerticesSize == 32` and `lod0VerticesSize == 32`.

## 4. Stats / database — the unknown of the day

For FH1→FM4 stats migration we have a major asymmetry on which the
solved direction does not help.

### 4.1 What ships in each game
- **FH1 source**: `media/db/gamedb.slt` (Data_Car 117 shared cols + 9
  FH1-only cols) AND per-car `physicsdefinition.bin` (a compiled cache
  built offline from the SQL row at game build time —
  `docs/FH1_PHYSICS_DB.md§"Implication for the per-car write path"`).
  For ports we read the SQL row; the bin is donor-passthrough policy
  (`feedback_donor_passthrough` memory, `docs/FH1_PHYSICSDEFINITION_BIN.md§"Donor-bin strategy"`).
- **FM4 target**: `Media/db/gamedb.slt` (Data_Car 117 cols). No physicsdef.bin.

### 4.2 The 9 FH1-only Data_Car columns to drop on emit
Per `docs/FH1_PHYSICS_DB.md`:
- `OffRoadEnginePowerScale`
- `OffRoadFrontWheelGripScale`
- `OffRoadRearWheelGripScale`
- `OffRoadTCSFullEffectMultiplier`
- `IsCameraCollidable`
- `IsRentable`
- `IsSelectable`
- `Specials`
- `UseBoxCameraCollision`

Plus one FH1-only sibling table: `E3Drivers`.

Going FH1→FM4: read source row, drop these 9 columns + `E3Drivers` row,
overlay onto FM4 donor row.

### 4.3 Going through `cardb.json`
`importwc.nim` already dumps the source's `Data_Car` row into
`working/<slug>/cardb.json` regardless of source game. The FH1 import
will include the 9 extra cols there. The export-side overlay needs to
**filter out** unknown columns when target is FM4 (or whitelist only
target's known cols).

`profiles/fm4.json:userEditableStats` enumerates the columns the GUI
exposes — useful but not authoritative. The full FM4 `Data_Car` schema
has 117 cols. Authoritative whitelist source: `PRAGMA table_info(Data_Car)`
on the target gamedb at port time. We already do this lookup elsewhere;
plumb it into the cardb overlay merger.

### 4.4 Sub-id tables
`project_radical_aerophysics_bug.md` documented: `AeroPhysicsID` +
`Data_CarBody`, `List_AeroPhysics`, `List_UpgradeCarBody*` are sub-id-keyed
tables that must be cloned with the new carId. The fix landed in
`core/dlc_merge.nim`'s clone-and-rewrite path. **For FH1→FM4 we'd
need the same machinery in whichever container path is chosen** (§6).

### 4.5 No physicsdef synthesis required
Going FH1→FM4, the source bin gets dropped (FM4 doesn't load it). No
RE of the bin's 0x58..0xCC scalar block is needed for this direction.
(That's still a future-work item for displaying tunable physics in the
GUI's stats drawer per `FH1_PHYSICSDEFINITION_BIN.md§"What we still might
want to RE later"`.)

## 5. **HARD QUESTION**: What's the FM4 mod-deployment container?

This is the central unknown that gates the entire FH1→FM4 effort. The
FH1→FM4 carbin transcode is easy — but where do we put the resulting
files so FM4 actually loads them?

### 5.1 Why direct gamedb.slt patch is a known dead end
`docs/PLAN_DLC_PIVOT.md` — the original `portto.nim` direct-edit path
worked in autoshow but **crashed on open-world spawn** when an audio
engine SQL chain hit our patched gamedb. We could not RE the chain from
xenia logs alone after cloning 30+ tables. **Important**: that crash
was specifically on FH1 with FM4-source cars; whether the same chain
exists in FM4's audio init is unknown — could be that FM4 was happier
with direct edits because its audio init queries differently. Probing
this requires either:
- testing direct edit again (cheap — already have `portto.nim`)
- or just skipping straight to the DLC path (slower to build, but
  proven robust on FH1 side)

### 5.2 Does FM4 have a DLC-merge mechanism?
**Strong signal yes**: FM4 historically shipped monthly Car Pack DLCs
(March 2011 through 2012, 75+ cars across the run). Each was a
downloadable batch of cars added to autoshow/career flat — same UX as
FH1's marketplace DLC.

**EMPIRICALLY CONFIRMED 2026-05-13 with a proper xenia DLC install.**
After installing the FM4 second ("Install/Content") disc through
xenia's content-installer (correctly this time — earlier half-install
left them at `…/00007000/6225E9B1/content/.../00000002/` as PIRS
packages), the four DLC packs landed at exactly the FH1-parallel
location as **loose-files trees**:

```
content/0000000000000000/4D530910/00000002/
├── 4d53091000000001/
│   └── Media/
│       ├── 1.puboffer                    (3 bytes: " \r\n")
│       ├── LicenseMasks                  (0 bytes)
│       └── DLCZips/
│           ├── 0001_pri_65.zip           (~730 MB; 63 cars + 63 wheel sets)
│           ├── 0001_pri_65/              (extracted dir for streaming audio)
│           │   └── Media/audio/cars/Engines/…
│           ├── StringTables_pri_151.zip  (~ small; 18-lang × 2-file = 36 .str files)
│           └── zipmount.xml              (mount config; only mounts StringTables)
├── 4d53091000000002/   "2001-2005 Model Year Car Pack" (~841 MB)
├── 4d53091000000003/   "2006-Current Model Year Car Pack" (~580 MB)
└── 4d53091000000004/   "Autovista Car Pack" (~854 MB)
```

**This is bit-for-bit the FH1 DLC layout family** — same path
(`<titleId>/00000002/<pkg>/Media/DLCZips/`), same naming convention
(`<numId>_pri_<NN>.zip`), same `puboffer` + `zipmount.xml` + extracted
audio dir + StringTables sidecar. Compare directly to FH1
`4D5309C9/00000002/4D5309C900000729/Media/DLCZips/…`.

#### Structural diff vs. FH1 first-party DLC (verified 2026-05-13)

| Element                                  | FH1 first-party DLC      | FM4 install-disc DLC      | Notes |
|------------------------------------------|--------------------------|---------------------------|-------|
| `<pkg>/Media/<N>.puboffer`               | yes (3-byte marker)      | yes (3-byte marker, ` \r\n`) | identical |
| `<pkg>/Media/LicenseMasks`               | (not present)            | yes (0-byte sentinel)     | FM4-only |
| `<pkg>/Media/DLCZips/<id>_pri_<NN>.zip`  | yes (`729_pri_99.zip`)   | yes (`0001_pri_65.zip`)   | identical convention |
| `<pkg>/Media/DLCZips/<id>_pri_<NN>/`     | yes (extracted)          | yes (extracted)           | both have it for streaming audio |
| `<pkg>/Media/DLCZips/StringTables_pri_…` | extracted dir            | `.zip` file               | format differs (FH1 loose-dir / FM4 zip) |
| `<pkg>/Media/DLCZips/zipmount.xml`       | 5 mounts                 | 1 mount (StringTables only) | FM4 ships less |
| `<pkg>/Media/DLCZips/cameras_pri_<id>.zip` | yes                    | (not present)             | FH1-only |
| `<pkg>/Media/DLCZips/CarModelTuning_pri_<id>/` | yes (extracted)  | (not present)             | FH1-only |
| `<pkg>/Media/DLCZips/EngineTuning_pri_<id>/`   | yes (extracted)  | (not present)             | FH1-only |
| `<pkg>/Media/DLCZips/LOD1_pri_<id>/`           | yes (extracted)  | (not present)             | FH1-only |
| `<pkg>/Media/DLCZips/carmodeltuning/`           | yes (extracted) | (not present)             | FH1-only |
| `<pkg>/Media/DLCZips/soundbanks/`               | yes (extracted) | (not present)             | FH1-only |
| `<pkg>/Media/DLCZips/stringtables.xml`         | yes (manifest)  | (not present)             | FH1-only |

#### Main zip contents (`<id>_pri_<NN>.zip`) — comparison

| Aspect                     | FH1 `729_pri_99.zip`           | FM4 `0001_pri_65.zip`         |
|----------------------------|--------------------------------|-------------------------------|
| Top-level dirs             | `media/cars`, `media/wheels`, `media/audio`, `media/ui` | `media/cars`, `media/wheels`  |
| Cars                       | per-car folders under media/cars/ | per-car folders under media/cars/ |
| Wheels                     | per-set folders under media/wheels/ | per-set folders under media/wheels/ |
| Per-car carbin set         | 11 (main+lod0+cockpit+4 calipers+4 rotors) | identical |
| `.carbin` count            | 2220                            | 756  (FM4 has fewer cars per pack) |
| `.xds` count               | 1882 + 166 `.XDS`               | 1103 |
| `.xml` count               | 1008                            | 445  (carattribs/shadersettings/versiondata/maxdata) |
| `.tga` (livery)            | 590                             | 348 |
| `.bin` (physicsdefinition) | **97** (1 per car)              | **0** (FM4 has no physicsdef.bin) |
| `.gr2` (granny mesh)       | 30                              | 10 |
| `.fbf` / `.bsg` / `.bgf`   | 43 each (digital gauges)        | 7 each |
| `.html` (build report)     | 199                             | 0 |
| **`merge.slt` or any `.slt`/`.db`** | **NOT PRESENT**         | **NOT PRESENT**               |
| `media/ui/textures/Thumbnails/Thumbnail_<carId>.tga` | yes  | (not seen in this pack)       |

#### StringTables format diff

- **FH1**: extracted directory tree — `StringTables_pri_99729/<lang>/<files>` (per-language subdirs at the filesystem level).
- **FM4**: zipped — `StringTables_pri_<NN>.zip` containing `<LANG>/Data_Car.str` + `<LANG>/Subtitles.str` per language (18 langs × 2 files = 36 `.str` total). The runtime un-zips this transparently via the `zipmount.xml` mount to `game:\Media\StringTables\`.

#### zipmount.xml — actual contents

FM4 (1 mount only):
```xml
<zipmount>
   <zip Name="StringTables_pri_151.zip" Mount="game:\Media\StringTables\" />
</zipmount>
```

FH1 (5 mounts):
```xml
<zipmount>
   <zip Name="cameras_pri_729.zip"      Mount="game:\Media\cars\shared\cameras\"        AltRootPath="…" ShouldCache="0" />
   <zip Name="StringTables_pri_99729"   Mount="game:\Media\StringTables\"               AltRootPath="…" ShouldCache="0" />
   <zip Name="CarModelTuning_pri_729"   Mount="game:\Media\audio\cars\CarModelTuning\"  AltRootPath="…" ShouldCache="0" />
   <zip Name="EngineTuning_pri_729"     Mount="game:\Media\audio\cars\Engines\EngineTuning\" AltRootPath="…" ShouldCache="0" />
   <zip Name="LOD1_pri_729"             Mount="game:\Media\audio\cars\Engines\Soundbanks\LOD1\" AltRootPath="…" ShouldCache="0" />
</zipmount>
```

The shared rule: **only sidecar zips that need a non-default mount
point are listed.** The main `<id>_pri_<NN>.zip` is *not* listed in
either game's zipmount.xml — the runtime auto-mounts it via the
`_pri_NN` filename convention against the default root (which is
effectively `game:\` for the cars+wheels at root paths
`media/cars/…`, `media/wheels/…`).

#### The gamedb-augment question

Neither FH1's `729_pri_99.zip` nor FM4's `0001_pri_65.zip` contains a
`merge.slt`, `.db`, `.sqlite`, or any obvious gamedb-augment file.
Because these are first-party packs whose Data_Car rows are *already
baked into the base gamedb*, no augment is needed at runtime.

For our use case (adding *new* cars from FH1 → FM4), we still need a
gamedb-augment mechanism — but the shape FH1 uses (per
`project_dlc_pipeline_state` and `core/dlc_merge.nim`) **does work**
when shipped as a sidecar file outside the DLC zip. Where to drop the
equivalent for FM4 is the next open question — likely either:
- inside the main `_pri_NN.zip` at a path FM4's loader scans (TBD),
- as a sibling sidecar in `Media/DLCZips/` (mirror of how cars zip
  itself sits there), or
- as an actual loose-`gamedb.slt` overlay (FH1's mechanism).

**Cheap probe candidate**: stage a hand-built test pack at
`4D530910/00000002/4d53091000000099/Media/DLCZips/0099_pri_99.zip`
containing one transcoded FH1→FM4 car under `media/cars/<NAME>/` plus
a `merge.slt`-like file, mirror the FH1 emitter exactly, and observe
xenia logs to see what FM4 attempts to load.

### 5.3 Three options to chase (B is the clear path — see §5.2 update)
**Option A — Direct edit (resurrect `portto.nim`)**.
- Pros: existing code path, only needs FH1 source plumbing.
- Cons: gamedb edit on FM4 requires `Fm4IntegrityBypassPatch` (TBD,
  see §7) for runtime to accept modified gamedb.slt; risk of repeating
  the FH1 audio-init crash mode.

**Option B — FM4 DLC overlay** (parallel to portto_dlc.nim). **WINNER.**
- Pros: proven robust path on FH1 side. **2026-05-13: empirically
  confirmed FM4 uses the loose-files `…/00000002/<pkg>/Media/DLCZips/`
  layout — bit-for-bit identical to FH1 at the directory level**, with
  `<id>_pri_<NN>.zip` cars zip, sibling StringTables zip, `puboffer`
  marker, and `zipmount.xml`. The `core/dlc_merge.nim` +
  `zip21_writer.nim` machinery should port across with surgical
  edits (drop FH1-only `.bin` physicsdefinition emission, drop
  FH1-only sidecar zips `cameras_pri_X.zip` / `CarModelTuning_*` /
  `EngineTuning_*` / `LOD1_*`, switch StringTables from extracted-dir
  to zipped form, switch zipmount.xml from 5-mount to 1-mount).
- Open question: where does FM4 expect a `merge.slt`-equivalent for
  *new* car rows (not present in any first-party FM4 DLC sample
  inspected). Test via the cheap probe in §5.5.

**Option C — Punt: target FM4 as a "read-only file manager" tab**.
- Just don't support FH1→FM4 mod deployment. Render FH1 cars in the
  GUI, let user export to glTF, but no FM4-side write path.
- Pros: zero new code.
- Cons: doesn't match user's stated goal of FH1→FM4 porting.

### 5.4 Investigation tasks to choose between A and B
1. ~~**Find or fetch a real FM4 Car Pack DLC**.~~ **DONE 2026-05-13**:
   xenia content-installed the 4 FM4 Install-Disc Car Packs as
   loose-files trees at `…/4D530910/00000002/4d530910000000{01..04}/`.
   See §5.2 for the full layout + diff vs FH1.
2. **Probe FM4's xex2** for an integrity-check string table (the FH1
   pattern from `xex2_patches.nim:Fh1IntegrityBypassPatch`). Look for
   `"gamedb"`, `"camera"`, `"physics"`, `"ui"`, `"zipmanifest"` ASCII
   string literals in .rdata. If found, the xex patch translates
   directly (different offsets, same scrambling pattern). FM4 `default.xex`
   path: `/run/media/paths/SSS-Games/fm4-god/4D530910/00007000/33E7B39F.data/Data00XX` —
   it's GoD-packaged, need to extract first via the existing
   `core/xex2/` machinery or xenia mount. **Likely moot if Option B
   wins** — DLC mount bypasses the per-file integrity check on FH1
   and presumably on FM4 too.
3. **Try direct edit on a throwaway gamedb.slt** with the existing
   `portto.nim` retargeted at FM4. Set source=fh1, target=fm4.
   Run a no-mesh-change test: add a single fresh `Data_Car` row
   for a fully-cloned donor (no FH1 source) and see if FM4 autoshows
   it and drives. Iterate from there.

### 5.5 New investigation tasks unlocked by the install-disc samples

The 2026-05-13 install made all the loose-file samples directly
inspectable — no STFS reader needed. Tasks remaining:

1. **Stage a minimal hand-built FM4 DLC pack** mirroring the verified
   §5.2 layout exactly:
   ```
   content/0000000000000000/4D530910/00000002/4d53091000000099/Media/
   ├── 99.puboffer           (3 bytes " \r\n", copy from any first-party pack)
   ├── LicenseMasks          (empty file)
   └── DLCZips/
       ├── 0099_pri_99.zip   (contains media/cars/<TEST>/* — one transcoded car)
       ├── StringTables_pri_199.zip (only if we need a localized car name)
       └── zipmount.xml      (1 mount, copied verbatim from FM4 first-party)
   ```
   Boot FM4 in xenia. Look for the test car in autoshow.
   - **Outcome A** — appears + drivable: shape is correct, no gamedb
     augment needed for IDs in the base-game range. We can ship.
   - **Outcome B** — doesn't appear: need the gamedb augment (§5.5#3).
   - **Outcome C** — crashes: log the crash, narrow on which file the
     loader fails to parse.
2. **`StringTables_pri_151.zip` schema** — confirmed 2026-05-13: contains
   18 language subdirs (`br/`, `CHT/`, `cz/`, `DE/`, `DEV/`, `EN/`,
   `ES/`, `FR/`, `GB/`, `HU/`, `IT/`, `JP/`, `KO/`, `LOC/`, `MX/`,
   `NL/`, `PL/`, `RU/`) each with two files — `Data_Car.str` (~66 KB
   typical) and `Subtitles.str`. Format is the same `.str` we already
   handle in FH1 path. Total 36 files per pack.
3. **Gamedb-augment shape** — neither FH1 first-party DLC nor FM4
   first-party DLC ships a `merge.slt` inside the main zip (confirmed
   via `unzip -l | grep -iE '\.(slt|db|sqlite)$|merge|gamedb'` — empty
   on both). The FH1 *user-DLC* path our `core/dlc_merge.nim` writes
   to is a sidecar `merge.slt` *outside* the cars zip. For FM4 we need
   to test the same idea — drop a `merge.slt` either:
   - alongside `0099_pri_99.zip` in `Media/DLCZips/`,
   - at `00000002/<pkg>/merge.slt`,
   - inside the cars zip at `media/db/merge.slt`,
   - or some other path the loader scans.

   Cheap probe: stage all four locations as separate test packs and
   observe which one xenia logs FM4 attempting to open.
4. **Marketplace DLC vs install-disc DLC** — the install-disc packs we
   sampled are first-party and may behave subtly differently from
   user-installable marketplace Car Packs (March 2011–2012 cadence).
   No marketplace sample currently on disk. If/when one shows up, audit
   for differences (especially in zipmount.xml and any `merge.slt`-like
   file).

### 5.6 ~~STFS/PIRS reader — minimum bytes to read~~ — OBSOLETED
xenia's content installer extracted the packs to loose-files at install
time (§5.2), so no PIRS parser is needed for the carbin-garage pipeline.
Keeping a stub here in case STFS is needed later for marketplace-DLC
ingestion: free60 spec offsets (`0x000` magic, `0x360` titleId BE u32,
`0x36C` contentType BE u32, `0x411` display name UTF-16BE multilang).

## 6. **HARD QUESTION**: Output zip — mixed-method writer constraint

### 6.1 What's required to hand FM4 a cars zip
Layout per §FM4 cars zip listing (from probed `ALF_8C_08.zip`):
- 11 carbins (main + lod0 + cockpit + 4 calipers + 4 rotors), each LZX-method-21
- ~20 XDS textures (damage / nodamage / lights / interior / livery), method-21
- 6 livery TGAs, method-21
- 5 digital gauge files (dash bgf/bsg/fbf + 2 XDS), method-21
- `physics/maxdata.xml`, method-21
- `carattribs.xml`, `shadersettings.xml`, `versiondata.xml`, method-21
- `buildnumber.txt` — **method-0 stored**, 95 bytes
- `cars_<NAME>_build_report.html`, method-21

**Mixed-method precedent confirmed** by `buildnumber.txt`. At least one
method-0 entry is already accepted by FM4's runtime.

### 6.2 The LZX-encode-only-≤64KiB limit
`project_lzx_encoder_blocker.md`: wimlib `lzx_compress` partial — works
≤64 KiB only. Body carbins are MB-scale, untreatable at present.

### 6.3 Strategy: lean on `zip21_writer.nim`'s existing mixed-method
`src/carbin_garage/core/zip21_writer.nim` already writes "edited entries
as method-0 stored, copies untouched entries' method-21 LZX bytes
verbatim". The shipped FH1 DLC path uses this for edited carbins.
**Same writer applies to FM4-target without changes** — just feed it an
FM4 donor zip and the transcoded carbin bytes as the edit set.

Open question: whether FM4's loader accepts a zip where the BIG entries
(main carbin, lod0 carbin) are method-0. `zip21_writer.nim`'s header
comment is honest about this:
> Whether a Forza game runtime accepts a heavily-method-0 archive is
> **unverified** — that's the point of building this writer

The shipped FH1 DLC path has answered this for FH1 (yes, accepts
heavily-method-0). FM4 is untested. **Easy to test**: write one
mixed-method FM4 zip with a single edited carbin and see if it boots.

### 6.4 If FM4 rejects method-0 for big entries
Fallback: do the work to crack full-stream CAB-LZX encode. `lzx_encode.nim`
has the wimlib hookup; what's missing is the multi-frame CAB-LZX framing
that `docs/FORZA_LZX_FORMAT.md` documents. The decoder side reads it;
the encoder side needs to produce matching chunk-headered output.
`docs/FORZA_LZX_FORMAT.md§"Encoding"` flags this as future work and
already names the libmspack reference (`lzxc.c`) we could port.

## 7. **MEDIUM QUESTION**: FM4 xex2 integrity check

Going same-game `export-to` for FM4 needs runtime to accept the edited
gamedb.slt and cars zip. FH1's pattern (`Fh1IntegrityBypassPatch` in
`src/carbin_garage/core/xex2_patches.nim:64`):
- 10 ASCII string scrambling patches in `.rdata` integrity-check
  lookup table.
- Strings scrambled: "camera", "gamedb", "gamemodes", "gametunablesettings",
  "physics", "renderscenarios" (3 parts), "ui", "zipma" → ASCII junk
  that fails the per-file lookup.
- Effect: per-file SHA1 (or whatever check) misses → check skipped.

**For FM4**: TBD whether the same integrity-check pattern exists in
FM4's xex. Probe steps:
1. Decrypt FM4 default.xex via `core/xex2/` machinery.
2. Search `.rdata` for ASCII strings: `gamedb`, `camera`, `physics`,
   `zipmanifest`.
3. If found, replicate `Fh1IntegrityBypassPatch` with FM4 offsets +
   appropriate scrambled patches.

If FM4 *doesn't* have a per-file integrity check (older title, less
DRM hardening?), the xex patch may be unnecessary — drop straight to
gamedb edits.

**Note**: DLC path on FH1 bypasses this requirement entirely (DLC
content isn't integrity-checked). If FM4 supports DLC mounting (§5.3),
the xex patch is similarly bypassed.

## 8. Code change inventory — every site to touch

### 8.1 Files that need new code (additive)
- `src/carbin_garage/core/carbin/transcode.nim` — `fh1PoolToFm4`,
  `fh1Lod0PoolToFm4`. Update `crossVersionStride` → bidirectional flags.
- `src/carbin_garage/core/carbin/patch.nim` — `downconvertSubsectionCvFiveToCvFour`.
- `src/carbin_garage/core/carbin/builders.nim` — accept reverse-direction
  subsection downconvert flag. Existing `srcTransform9` and a*b resize
  paths already direction-agnostic.

### 8.2 Files with hardcoded `sourceProfileId = "fm4"` (need either
parametrization or symmetric per-direction fallback)
- `src/carbin_garage/orchestrator/portto.nim:189`
- `src/carbin_garage/orchestrator/portto_dlc.nim:332`
- `src/carbin_garage/cli.nim:174,213` (default `--profile fm4` in
  `import` + `roundtrip` is fine; user passes `--profile fh1` for
  FH1-source imports anyway)

These should read `originGame` from `carslot.json` (already the override
path); the literal default `"fm4"` is just for the case where carslot
is missing. Change literal to direction-agnostic — or skip if every
real call sets `originGame`. Tracing: `importwc.nim` populates
`carslot.originGame` on import; for FH1 imports it should already be
`"fh1"`. The fm4-literal-fallback is dead weight as long as imports run.

### 8.3 Files conditional on `target.id == "fh1"`
- `src/carbin_garage/core/texture_port.nim:71-72` — `case target.id of "fh1"`
  applies FH1-specific extra buckets. Need a matching `case` for `"fm4"`
  (or just default behavior with target.extraXdsBuckets driving exclusions).
- `src/carbin_garage/core/xex2_patches.nim:46-114` — FH1-only patch set.
  Either add `Fm4IntegrityBypassPatch` per §7 or skip if FM4 doesn't
  need it.
- `src/carbin_garage/core/dlc_merge.nim` — fundamentally an FH1 DLC
  emitter. If FM4 DLC mechanism is similar (§5.3 option B), refactor
  to direction-agnostic or write `core/dlc_merge_fm4.nim`. If FM4
  uses direct gamedb edits (option A), `cardb_writer.nim` already
  exists and is direction-agnostic.

### 8.4 New orchestrator
Either:
- **Option A (direct edit)**: extend `portto.nim` to support
  `targetProfile.id == "fm4"` end-to-end. Already mostly there —
  the audio-init crash mode was an FH1 problem, not necessarily an
  FM4 problem.
- **Option B (FM4 DLC)**: new `orchestrator/portto_dlc_fm4.nim` mirroring
  `portto_dlc.nim`'s structure with FM4-specific package layout.

### 8.5 CLI surface
`src/carbin_garage/cli.nim` currently has:
- `import` / `roundtrip` / `dump-cardb` — already direction-agnostic
  via `--profile`.
- `port-to-dlc` — FH1-DLC-specific.

For FH1→FM4 we need either to make `port-to-dlc` accept `fm4` as
target (and dispatch to the FM4 emitter) or add `port-to-fm4-dlc`.
Latter is cleaner if FM4 mechanism is meaningfully different.

## 9. Profile updates needed

`profiles/fm4.json` is the target profile; nothing changes structurally
for it. But the GUI's stats path may need:
- The 9 FH1-only stats in `profiles/fh1.json:userEditableStats` should
  emit `null` or "(unsupported)" in FM4 export targets.
- The synthetic `physMassKg` stat in fh1.json (line: `"source":
  "synthetic", "syntheticKind": "physMassKg"`) reads FH1's
  physicsdefinition.bin's mass field. For FH1→FM4 we'd drop it (FM4
  uses `CurbWeight` directly, already present).

## 10. Concrete recommended next steps

In dependency order — each step is ~1 small session.

1. **Land carbin transcode reverse** (§3) — pure code change, fully
   testable offline against pairs of FH1+FM4 carbins from the same
   car (`probe/out/carbin_samples` already has them). Yields:
   ```
   nim c -r probe/nim_fh1_to_fm4_smoke.nim
   ```
   that reparses a transcoded ALF_8C_08 main carbin as cvFour with
   correct stride/section counts. No game runtime needed.

2. **Decide direct-edit vs DLC for FM4** by *cheap probe*:
   - Try the existing `portto.nim` with hand-tweaked source=fh1,
     target=fm4. Emit a single mixed-method cars zip + a patched
     gamedb.slt row. Boot FM4 in xenia. Three outcomes:
       (a) Loads + drives → option A is live, no FM4 DLC needed.
       (b) Loads + crashes on open-world → DLC pivot needed (same as FH1).
       (c) Doesn't load at all → xex integrity patch needed first.
   - This is one xenia run; tells us which of §5.3 options applies.

3. **If option A wins**: extend `portto.nim` to support fh1 source +
   fm4 target. Most of the orchestrator is generic; the dispatch table
   needs entries for the new direction.

4. **If option B wins**: pull a real FM4 Car Pack DLC sample, RE its
   package layout (parallel to `dlc_merge_recon.txt`), write
   `core/dlc_merge_fm4.nim` and `orchestrator/portto_dlc_fm4.nim`.

5. **GUI plumbing**: dropup palette already supports per-target
   export. Wire fm4 as a target option when the working car's source
   is fh1 (mirroring the existing fh1-target option). Existing
   `gui/app.nim` palette code is direction-agnostic.

6. **Stats overlay filter** (§4.3): plumb target's `Data_Car` schema
   into `cardb.json` merger so 9 FH1-only cols drop when target is fm4.

7. **No-cross-game test cases**: same-game FH1→FH1 and FM4→FM4 don't
   trigger any of the reverse-transcode code paths (`crossDown` false).
   Make sure step 1's changes don't regress them.

## 11. Open empirical questions (single-line each)

- [ ] Does FM4 ship per-file integrity checks in default.xex like FH1 does?
- [ ] Does FM4 accept a cars zip with method-0 stored entries for >64KB carbins?
- [x] **2026-05-13**: FM4 mounts `00000002/<package_id>/` — confirmed
  twice: first by Install Disc 2 dropping PIRS packs at
  `…/6225E9B1/content/.../00000002/`, then again after proper xenia
  content-install which **extracted them to loose-files** at
  `…/4D530910/00000002/4d530910000000{01..04}/Media/DLCZips/…`. The
  loose-files layout is bit-for-bit family-identical to FH1's at the
  directory level.
- [x] **2026-05-13**: Loose-file `00000002/<pkg>/` mount IS the
  primary form FM4 reads from — first-party DLC ships as loose-files
  (`<id>_pri_<NN>.zip` + StringTables sidecar + zipmount.xml +
  puboffer + LicenseMasks under `Media/DLCZips/`). No PIRS packer
  needed for the carbin-garage pipeline.
- [ ] What does FM4 use as its `merge.slt` analog for *new* car IDs
  (out of base gamedb range)? Neither FH1 first-party nor FM4
  first-party packs contain any `.slt`/`.db`/`.sqlite` inside the cars
  zip (confirmed 2026-05-13 by grep). FH1 user-DLC ships a sidecar
  `merge.slt` outside the cars zip — FM4's equivalent path is the
  open empirical question. See §5.5#3 for probe plan.
- [ ] Does FM4's audio engine init choke on direct gamedb edits the way FH1 did?
- [ ] What's FM4's analog of FH1's `Combo_Engines.Ordinal = EngineID + 246` quirk?
- [ ] Does FM4's `Data_Engine` have the same `EngineID` independent ID space, or piggyback on `Data_Car.Id`?
- [ ] Do FM4 base-game carbins have any LOD0-only-inside-main-carbin sections (the R8GT_11 pattern that needed Slice C)? If not, gap preservation is a guaranteed no-op going to FM4.
- [ ] Is FM4's `versiondata.xml` checked for any car-name binding, or is it generic and donor-passthrough-safe?
- [ ] Does FM4's `carattribs.xml` Version 16 need any field rewrites from Version 21 (FH1 source)? FH1_VS_FM4_OVERVIEW says "1/77 byte-identical" — drift is mostly cosmetic but may include car-name strings.
- [ ] What casing rules apply inside an FM4 cars zip? Probe shows lowercase member names but `Media/cars/` dir capitalized; profile says `"casing": "Mixed"` — semantics need an audit pass parallel to FH1's "Lower".

## 12. Memory + project status updates this doc supersedes

This doc adds new context but doesn't invalidate existing memories.
Notable cross-refs:
- `feedback_donor_passthrough.md` applies in reverse: FH1→FM4 donor
  passthrough drops physicsdef.bin (no synthesis needed either way).
- `feedback_validation_strategy.md` applies symmetrically: validate
  rebuilt FM4 carbin via codec roundtrip + invariants (`lodVerticesSize
  == 32`, parsed section count matches donor) + xenia smoke test.
- `feedback_vendor_pristine.md` unchanged — wimlib + libmspack patches
  stay vendor-pristine, no encoder work in vendor/.

## References

- This doc is the synthesis of:
  - `docs/CARBIN_TRANSCODE.md` (especially §"Reverse direction (FH1 → FM4): playbook")
  - `docs/FH1_VS_FM4_OVERVIEW.md`
  - `docs/FH1_CARBIN_TYPEID5.md`
  - `docs/FH1_PHYSICS_DB.md`
  - `docs/FH1_PHYSICSDEFINITION_BIN.md`
  - `docs/FM4_CARBIN_CONDENSED.md`
  - `docs/FORZA_LZX_FORMAT.md`
  - `docs/APPLET_ARCHITECTURE.md`
  - `docs/PLAN_DLC_PIVOT.md`
- Code:
  - `src/carbin_garage/core/carbin/{parser,transcode,builders,patch,model}.nim`
  - `src/carbin_garage/core/{zip21,zip21_writer,lzx,lzx_encode,xex2_patches,dlc_merge,texture_port,cardb_writer,profile}.nim`
  - `src/carbin_garage/orchestrator/{portto,portto_dlc}.nim`
- Sample data:
  - FM4 install: `/run/media/paths/SSS-Games/xenia_canary_windows/content/0000000000000000/4D530910/00007000/33E7B39F/Media/cars/`
  - FH1 install: `/run/media/paths/SSS-Games/xenia_canary_windows/content/0000000000000000/4D5309C9/00007000/2DC7007B/media/cars/`
  - FH1 sample DLC: `/run/media/paths/SSS-Games/xenia_canary_windows/content/0000000000000000/4D5309C9/00000002/4D5309C900000729/`
  - No FM4 DLC sample currently on disk
