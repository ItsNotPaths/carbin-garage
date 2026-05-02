# Roadmap

Status snapshot of where carbin-garage is and what's next. Updated 2026-05-01.

**>>> CROSS-GAME PORT-TO PIVOT (2026-05-01 EOD): see `docs/PLAN_DLC_PIVOT.md` <<<**

After ~6 hours of in-game iteration, cross-game `port-to` via direct
`gamedb.slt` edits has been **ruled out**. Autoshow + purchase + color picker
work, but post-purchase open-world spawn nukes the global render pipeline
(grey screen, 0 RPM, instant gear-up). Root cause is an undecodable SQL chain
in the audio engine init that returns 0 rows for our new car and substitutes
the SQL CE error string `"Attempt to access invalid field or record"` into
asset paths. We could not identify the offending join from logs after
extensive cloning across 30+ tables.

**Decision**: cross-game `port-to` becomes a **DLC package emitter**. Same-game
`export-to` (modifying cars that already exist in the target) keeps the
direct-write approach that works today. UX stays flat — DLC mechanic is
hidden behind the existing CLI verb.

**Authoritative plan**: `docs/PLAN_DLC_PIVOT.md`. New code goes in
`orchestrator/portto_dlc.nim` (replaces direct-edit logic in current
`portto.nim` for cross-game ports). Phase 2b real transcode (Slice B) is
deferred until the DLC port path proves in-game load.

**Critical bug discovered en route**: `core/zip21_writer.nim` drops the
FH1-required `0x1123` per-CDH extra field encoding compressed-data offset.
Donor zips have it on every entry; ours don't. Fix needed for both same-game
and DLC paths. See memory `project_zip21_extra_field.md`.

The Slice A / Slice B / xex notes below are preserved for context but are
**not the active work plan**. PLAN_DLC_PIVOT.md is.

---

**Earlier 2026-05-01 (xex integrity-bypass patcher):** Pure-Nim xex2
unpacker + repacker landed at `src/carbin_garage/core/xex2/`
(aes/format/basic/unpack/sha1) + `core/xex2_patches.nim` +
`orchestrator/patchxex.nim`. CLI: `patch-xex <default.xex> [--restore]`.
Output is **byte-equal to a community-patched reference xex** when
given the same scramble values (sha256 verified). The patch disables
FH1's integrity-check lookup table for 8 media files (gamedb.slt being
the one we care about) by scrambling filename strings in .rdata; the
loader's separate header_hash check is sidestepped by splicing a
hardcoded 16 KiB known-good header from the reference (rsa_signature
zeroed + header_hash recomputed for a restructured optional-header
layout) — `vendor/xex2_templates/fh1_header.bin`, baked in via
`staticRead`. Empirically scramble values of pure-alpha or
alpha-with-hyphens load fine; `&` and `/` cause IO errors at runtime
(unverified root cause but likely hash collision with a real lookup
entry). This patcher is the missing layer that makes gamedb writes
tolerated by the runtime — port-to deploys that INSERT new car rows
now load cleanly.

**Earlier (2026-05-01, Slice A — port-to scaffolding):** End-to-end
`port-to` pipeline wired with a **stub carbin transcode** that returns
donor bytes verbatim. New modules: `core/carbin/transcode.nim` (stub +
`tmHybridSplice` placeholder that raises until Slice B implements the
real Option-C donor splice), `core/cardb_writer.nim` (DB row patcher;
overlays source `cardb.json` on donor's row, `BaseCost=1` forced,
auto-clones FH1-only `E3Drivers` from donor when porting from FM4),
`orchestrator/portto.nim`, CLI verb `port-to <working-car>
<target-game-id> --donor <donor-slug> [--name <new-slug>] [--dry-run]
[--replace-db]`. Smoke probe `probe/nim_carbin_transcode_smoke.bin`:
**16/16 pass** across the 8 paired sample cars × 2 directions
(FM4↔FH1; output bytes equal donor + reparses cleanly). Real-mount
dry-run on FM4→FH1 port of ALF_8C_08: textures 12/3/0
(copy/splice/drop), geometry 11 transcode + 11 donor-only (the donor's
11 stripped_* slots), cardb 5 overlay + 1 donor-clone (E3Drivers) + 16
table skips. Real bytes-on-disk port + in-game test next. Slice B
replaces only `transcodeCarbin`'s body — orchestrator + DB stay put.

**Latest (2026-05-01, LZX session):** Texture edits now flow end-to-end
through `export-to`. wimlib's `lzx_compress` is wired (`csrc/lzx_deflate.c`
+ `core/lzx_encode.nim`) and patched for CAB-LZX framing
(`patches/wimlib_lzx_cab_compat.patch`, applied at deps-fetch time);
single-chunk inputs ≤64 KiB byte-equal roundtrip via libmspack.
Multi-chunk encoding desyncs at chunk boundaries because wimlib's
match-finder + recent_offsets aren't streamably persistent — Phase 2b
proper, captured in detail in project memory "LZX encoder partial".
The near-term unblock is `core/zip21_writer.nim` — a mixed-method
PKZip rewriter that copies untouched method-21 (LZX) entries verbatim
and emits edited entries as method-0 (stored). `export-to` now invokes
it automatically when the working tree has files newer than the
stashed `source.zip`. End-to-end smoke test passes: edit PNG →
`reencode-textures` → `export-to` → re-import the exported zip → the
edit is intact (red rectangle round-trips at pixel level). In-game
compatibility of method-0 entries is the next data point worth
gathering.

**Earlier (2026-05-01, encode session):** Phase 2c.3 texture **encode**
+ structural **cross-game porting** complete. PNG → BC1/3/5 via
`stb_dxt`, Xenon retile (inverse of decode), 8-in-16 endian swap, and
`.xds` header rewriter all wired in `core/xds.nim`. Mip chain length is
inferred from the original payload size so re-encoded files match
byte-counts of the source — **190/190 paired sample .xds files
round-trip with byte-equal file size and avg meanΔ = 0.134/255**
(visually imperceptible). New CLI verbs `encode-xds` and
`reencode-textures`; new module `core/texture_port.nim` planning
cross-game splices. **`probe/nim_xds_port_validate.bin` confirms 16/16
structurally-identical bucket sets** across FM4↔FH1 ports on the 8
sample cars (donor = same-named car in target game). Phase 2c.3 +
Phase 2c.4 (cross-game compat) both done structurally; the only
remaining piece — splicing edited .xds back into the export zip — is
gated on the LZX encoder (Phase 2b).

**Earlier 2026-05-01:** FH1 `<car>_lod0.carbin` and
`<car>_cockpit.carbin` parsing **complete** — the missing delta was an
extra `lod0VCount × 4`-byte per-vertex stream (likely SHORT2N or
DEC3N normals/tangents) after the §6 section tail. With it, all 8
sample cars × 3 carbin variants × 8 brake corners (= 56 carbins per
game) byte-equal roundtrip on both FM4 and FH1. The `--all-lods` flag
is removed; the importer now emits ALL carbins (main + lod0 + cockpit
+ 4 caliper + 4 rotor) into one glTF, with each mesh tagged in
`extras.carbin.lodKind` so DCC tools and our future UI can filter.
New full-format docs: `FH1_CARBIN_MASTER.md` + `FH1_CARBIN_CONDENSED.md`
(mirroring the FM4 docs); the existing `FH1_CARBIN_TYPEID5.md` got a
new §6.5 covering the lod0/cockpit deltas.

**Earlier 2026-05-01:** import now folds the per-car DB rows out of
each game's `gamedb.slt` into `working/<slug>/cardb.json`, so a working
car carries every per-car row alongside its archive. FH1 *also* ships a
`gamedb.slt` with the same `Data_Car` / `Data_Engine` schema as FM4
(plus 9 extra columns + an `E3Drivers` table), confirmed by direct
read of both DBs — the per-car SQL row is captured for both games on
import, and the FH1 archive's `physicsdefinition.bin` rides along
already via the catch-all branch in importwc.

The locked phase plan in `APPLET_ARCHITECTURE.md` §"Phase plan" is the
*architecture* destination. This file captures the *current state* and
the immediate-next-slice work. Where the two diverge it's because the
architecture phases got reordered as we discovered things.

## Where we stopped (texture decode/encode + LOD parsing)

**Texture decode — done**:
- `.xds` → RGBA8 → PNG via `core/xds.nim` (D3DBaseTexture header parse,
  Xenon detile, 8-in-16 endian swap, bcdec block walk).
- BC1 / BC3 / BC5 + their `_AS_16_16_16_16` aliases.
- Auto-decode runs at import for every `.xds` in
  `working/<slug>/textures/`.
- Per-subsection `m_UVOffsetScale` baked into the glTF; name-prefix
  shader → texture resolver in `core/texture_map.nim`.

**Texture encode — done 2026-05-01**:
- `stb_dxt.h` + `stb_image.h` + `stb_image_write.h` vendored;
  `csrc/stb_dxt_impl.c` + `csrc/stb_image_impl.c` shim.
- `core/xds.nim` carries the full encode pipeline: `encodePayload`
  (one mip), `encodePayloadChain` (top + box-filter chain),
  `inferMipCount` (back-derives chain length from original payload
  size so byte parity holds), `rewriteXdsHeader` (preserves the
  format-id literal — DXT4_5_AS_16 stays 53), and
  `encodeXdsFromOriginal` (full splice).
- New CLI verbs: `encode-xds <png> <orig.xds> [<out>] [--highqual]`
  and `reencode-textures <working-car>` (sweeps a working tree for
  PNG-newer-than-XDS).
- Validated on 190 paired sample .xds across BC1/BC3/BC5 + their
  AS_16 variants: 0 failures, 190/190 byte-size match, avg
  meanΔ = 0.134/255, worst meanΔ = 0.332/255, max single-channel
  delta = 50/255 (BC1 quantization edge case). See
  `probe/nim_xds_roundtrip.nim`.
- Splicing the re-encoded `.xds` back into the export zip is still
  gated on the LZX encoder (Phase 2b). Until that lands, edits
  update the working-tree `.xds` in place but `export-to` byte-copies
  the original `.archive/source.zip`.

**Cross-game texture porting — done structurally 2026-05-01**:
- `probe/extract_xds_pairs.py` + `probe/probe_xds_pair_diff.py`:
  empirical proof that the FM4 and FH1 `.xds` containers are
  byte-compatible (0 HEADER deltas, 0 SIZE deltas across all 22
  paired buckets and 8 sample cars).
- `core/texture_port.nim`: builds a `TexturePortPlan` (copy-source /
  splice-donor / drop-extra ops) using the target profile's
  `extraXdsBuckets` to know which FH1-only buckets need a donor
  splice (`interior_emissive_LOD0`, `zlights_LOD0`, `zlights`).
- Validated end-to-end: `probe/nim_xds_port_validate.bin` runs the
  planner across all 8 paired cars in both directions and verifies
  the resulting bucket-name set equals what the target game
  actually ships — **16/16 structurally identical**.

**Mesh LOD parsing — complete (2026-05-01)**:
- Main carbin's *internal* LOD pool + LOD0 pool: parse cleanly on both
  games (the main carbin per-section "LOD" and "LOD0" vertex pools are
  what the engine streams between at conversation distance).
- FM4 separate `<car>_lod0.carbin` (close-up high-detail) + cockpit:
  parse cleanly, byte-equal roundtrip.
- **FH1 `<car>_lod0.carbin`**: full parse, byte-equal roundtrip on all 8
  sample cars. Resolved by adding a `lod0VCount × 4`-byte per-vertex
  post-pool stream after the section tail (the second-tangent stream
  is split out from the FM4-style 28-byte vertex stride). See
  `docs/FH1_CARBIN_MASTER.md` §11.
- **FH1 `<car>_cockpit.carbin`**: full parse on 7/8 sample cars; 1
  anomalous non-mesh section in BMW M3E30 cockpit (a wiper / decal
  metadata block) handled via skip-and-resume. Byte-equal roundtrip
  passes regardless because the byte range is preserved.
- **FH1 `stripped_*.carbin`**: header-only stubs, format unknown.
  Currently filtered out of glTF emit; round-trip via passthrough.

## Locked next-step ordering

The cross-game port lands as a **two-stage workflow**: source-game car
→ `working/<slug>/` (already exists as `import`), then
`working/<slug>/` → target-game archive (new verb, e.g.
`port-to <working-car> <target-game-id> --donor <donor-slug>`).
Keeping the two stages separate lets the user inspect the working tree
between import and port, swap donors without re-importing, and reuses
the existing `export-to` plumbing for same-game writes.

1. **~~Texture encode + cross-game port plan~~ — done 2026-05-01.**
   190/190 byte-size match on encode roundtrip; 16/16 structurally-
   identical bucket sets; mixed-method zip writer ships dirty entries
   as method-0 today.
2. **Carbin transcode (TypeId 3 ↔ TypeId 5)** — the real Phase 2b
   blocker. The byte-level deltas between the two TypeIds are mapped
   in `FH1_CARBIN_TYPEID5.md` and `FM4_CARBIN_MASTER.md`; what's
   missing is the writer that takes a parsed FM4 carbin and emits an
   FH1 carbin (and vice-versa). Strategy is locked to **Option C
   hybrid donor splice**: donor's scaffolding (header / expanded-
   middle table / unknown per-section fields / cvFive +8 sub-skip /
   `m_NumBoneWeights` pre-pool block / `lod0VCount × 4` post-pool
   stream) stays; the source car's section bytes (vertex pool, index
   pool, transform, bounds) are re-quantized into the donor's slots.
   - Scope: main carbin first; `<car>_lod0.carbin` + `_cockpit.carbin`
     follow the same pattern; `stripped_*.carbin` and the 4×caliper /
     4×rotor LOD0s pass through verbatim from the donor.
   - Validation tiers per `feedback_validation_strategy.md`:
     codec roundtrip + structural invariants + donor shape-check +
     in-game load test. NOT byte-equal vs. an on-disk paired car.
3. **DB row patch** — the per-car snippet captured at import
   (`working/<slug>/cardb.json`, ~6 tables on FH1, ~5 on FM4) is the
   payload; `port-to` patches it into the target's `gamedb.slt` using
   the donor's existing row as the template. FK chains (PowertrainID
   → Powertrains, EngineID → Combo_Engines, TorqueCurveID →
   List_TorqueCurve) are followed only for tables the source's
   snippet references; everything else inherits the donor's value.
   For the 9 FH1-only `Data_Car` columns (`OffRoadEnginePowerScale`,
   `IsRentable`, `IsSelectable`, `Specials`, …) and the `E3Drivers`
   table that FM4 lacks, the donor's values pass through unchanged.
4. **Wire the verbs**:
   - `import <car.zip> --out working/` (already exists) — source-game
     car → `working/<slug>/`.
   - `port-to <working-car> <target-game-id> --donor <donor-slug>`
     (new) — `working/<slug>/` → target-game archive on disk, in one
     atomic step. Internally: load donor's archive as the scaffold,
     run carbin transcode for each carbin in `working/<slug>/geometry/`,
     splice texture bucket plan, copy donor's `physicsdefinition.bin`
     and `stripped_*.carbin` verbatim, patch the target's gamedb.slt
     row from `working/<slug>/cardb.json` keyed on the donor.
   - Same-game writes keep using `export-to` (the existing mixed-
     method zip path).
5. **LZX encoder** — still gated on the wimlib match-finder /
   recent_offsets streaming patch (project memory "LZX encoder
   partial"). Until that lands, `port-to` and `export-to` both rely on
   the mixed-method writer (method-21 verbatim for unchanged entries,
   method-0 stored for edited/transcoded entries). The in-game test
   on this method-0 path is the next data point.

## Done

### Phase 1 — FM4 read + byte-equal roundtrip
- `core/carbin/` Nim port: parser, model, vertex, transform, ops, patch, builders.
- `core/zip21.nim`, `core/lzx.nim` (libmspack `lzxd` read).
- `core/gltf.nim` hand-rolled glTF 2.0 writer + cgltf parse-validate.
- `core/profile.nim` + `profiles/fm4.json`.
- `importToWorking` + `roundtrip` CLI verbs.
- FM4 `roundtrip <zip>` byte-equal across all 8 sample cars.

### Phase 2a — FH1 import
- TypeId 5 parser handles main + lod0 + cockpit + caliper / rotor with
  cvFive deltas (header expansion, 28-byte vertex stride, +8 sub-skip,
  expanded tail).
- `profiles/fh1.json`.
- `roundtrip <zip> --profile fh1` byte-equal across paired sample cars.
- **FH1 caliper / rotor LOD0 pre-pool block fix (2026-05-01)**: TypeId 1
  carbins also carry `m_NumBoneWeights + perSectionId` *before the LOD0
  pool* (not just before the LOD pool). For sections that have only a
  LOD0 pool (calipers, rotors), missing this 8-byte skip read the first
  vertex's pos at offset +8 and produced scrambled mesh. Fix is mirrored
  into `parseSection` `cvFive` branch. See `FH1_CARBIN_TYPEID5.md` §5.

### Phase 2c.1 — Texture extract
- `core/xds.nim`: D3DBaseTexture header parse + Xenon detile + 8-in-16
  endian swap + bcdec block walk → RGBA8.
- BC1 / BC3 / BC5 + their `_AS_16_16_16_16` aliases (DXT4_5_AS_16 = 53
  is what FM4 nodamage actually claims).
- `vendor/stb/stb_image_write.h` for PNG output.
- `decode-xds` CLI verb. Auto-decode runs at import time so every .xds
  has a sibling .png in `working/<slug>/textures/`.

### Phase 2d — Per-car DB snippet on import (2026-05-01)
- `core/cardb.nim`: opens `gamedb.slt` read-only, looks up `Data_Car.Id`
  by `MediaName`, and walks every table for rows keyed on `MediaName`,
  `CarId`, or `CarID`. Captures column names + SQL types alongside the
  values so a future export pipeline can replay them as INSERT/UPDATE
  statements without touching the source DB.
- Wired into `importToWorking`: writes `working/<slug>/cardb.json` next
  to `carslot.json`. Soft-fails (notice + continue) if the gamedb is
  missing or `MediaName` isn't in `Data_Car`.
- New CLI verb `dump-cardb <game-folder> <car-name> [--profile <id>]
  [--out <file>]` for inspection without an import.
- Confirmed: ALF_8C_08 produces 5 tables on FM4 (Data_Car, Data_Engine,
  List_Wheels, CameraOverrides, CarExceptions) and 6 on FH1 (same +
  `E3Drivers`). FH1 `Data_Car` has 9 extra columns over FM4
  (`OffRoadEnginePowerScale`, `IsRentable`, `IsSelectable`, `Specials`,
  …); shared schema = 117 columns. Roundtrip on the 8 sample cars
  still byte-equal both profiles.
- Dependency: `db_connector >= 0.1.0` added to `carbin_garage.nimble`.
  On Linux it dynlinks `libsqlite3.so` at runtime; Windows builds will
  need `sqlite3.dll` shipped alongside the binary (deferred to the
  Windows release-job step).
- Out-of-scope for now (deferred to export-side):
  - Walking FK chains (Data_Car.PowertrainID → Powertrains, EngineID
    → Combo_Engines, TorqueCurveID → List_TorqueCurve, etc.). v1
    captures direct per-car rows only; FK chasing lands when we wire
    the SqlitePatch writer.
  - `physicsdefinition.bin` parse — FH1 ships it per-car and import
    already drops it into the working tree as-is.
  - FM4↔FH1 schema migration for the 9 extra FH1 columns.

### Phase 2c.2 — glTF material wiring
- Per-subsection `m_UVOffsetScale` parsing (8 floats: XOff, XScale,
  YOff, YScale × UV0 + UV1) — added to `SubSectionInfo`.
- `core/texture_map.nim`: shader-name → `MatSpec` heuristic with three
  outcomes: atlas-textured, flat-color, glass.
- `gltf.nim` emits per-subsection TEXCOORD_0 accessors with the atlas
  transform baked in; one Image+Texture+Material per unique URI.
- **No Y-flip in the bake**: the master doc claims `final.y = 1 - (raw.y * yScale + yOffset)`
  but empirically that maps the FH1 steering wheel onto the Alfa-badge
  region. The carbin-stored values are already in glTF/DirectX
  top-left convention.
- Degenerate UV detection (`scale ≈ 0`) → flat-color fallback. Catches
  procedural shaders (`bump_leather*`, `mottled`, `cloth`).
- TriStrip parity-reset on restart sentinels (was producing inverted
  triangle splotches on body panels).
- Wheel + caliper + rotor instancing at the 4 hub positions; tyres
  ride along with the wheel template; calipers/rotors placed by name
  suffix (`*LF`, `*LR`, `*RF`, `*RR`).
- Main-carbin `seatL` / `seatR` / `steering_wheel` suppressed when
  `--all-lods` is on (cockpit carbin ships higher-poly versions; emit
  both = `.001` duplicates in DCC tools).

## In progress / open

### Phase 2c.3 — Texture re-encode + porting — **done 2026-05-01**
- PNG → BC1/3/5 via `stb_dxt`, Xenon retile, header rewriter,
  mip-chain regeneration with `inferMipCount` for byte-size parity.
  190/190 paired samples roundtrip byte-size match; avg meanΔ
  0.134/255.
- Cross-game `.xds` container compat verified empirically:
  `probe/probe_xds_pair_diff.py` shows 0 header / 0 size deltas
  across 22 shared buckets × 8 sample cars.
- `core/texture_port.nim` builds a `TexturePortPlan` with copy-source
  / splice-donor / drop-extra ops, reading `extraXdsBuckets` from the
  target profile. `probe/nim_xds_port_validate.bin` confirms 16/16
  structurally-identical bucket sets across paired sample cars in
  both port directions.
- New CLI verbs: `decode-xds`, `encode-xds`, `reencode-textures`.

### Phase 2b — FM4 ↔ FH1 export — **in progress 2026-05-01**

The locked workflow is two-stage: `import` → `working/` (existing),
then `port-to <working-car> <target-game-id> --donor <donor-slug>`
(new). Inside `port-to`:

1. **Carbin transcode (TypeId 3 ↔ TypeId 5)** — *next*. Donor's
   archive is the scaffold; for each carbin in
   `working/<slug>/geometry/`, the source's section bytes
   (vertex/index pools, transform, bounds, m_UVOffsetScale) are
   re-quantized into the donor's TypeId-flavored layout. Donor keeps
   ownership of the per-Carbin scaffolding the source can't supply
   (cvFive header expansion, +8 sub-skip, expanded middle table,
   `m_NumBoneWeights` pre-pool block, FH1's `lod0VCount × 4` post-pool
   stream). `stripped_*.carbin` and caliper / rotor LOD0s pass
   through verbatim. Scope ordering: main first, then lod0 / cockpit.
2. **Texture splice** — already wired; just call
   `planTexturePort(source, donor, sourceProfile, targetProfile)` and
   apply each op against the donor archive.
3. **DB row patch** — apply `working/<slug>/cardb.json` to the target
   game's `gamedb.slt` using the donor's row as the template.
   `Data_Car` keyed on `MediaName`; child tables (`Data_Engine`,
   `List_Wheels`, `CameraOverrides`, `CarExceptions`) keyed via the
   per-car ID columns we already capture on import. The 9 FH1-only
   columns + the `E3Drivers` table inherit the donor's values when
   porting from FM4. FK chains followed only for tables the snippet
   references.
4. **`physicsdefinition.bin` + `stripped_*.carbin`** — verbatim
   passthrough from donor (locked policy in
   `FH1_PHYSICSDEFINITION_BIN.md` §"Donor-bin strategy"). FH1
   exports always need both; FM4 exports skip them.
5. **LZX encoder** — wimlib lzx_compress wired (single-chunk works,
   multi-chunk gated on match-finder/recent_offsets streaming
   patches). Until that lands, `port-to` uses the mixed-method
   writer: unchanged donor entries pass method-21 verbatim, source-
   substituted entries (transcoded carbins, ported textures) emit as
   method-0. Whether the FH1 / FM4 runtime accepts a heavily-method-0
   archive is the next data point worth gathering.

**Validation is structural, not byte-equal-vs-on-disk.** ALF_8C_08
ships in both rosters, but the two games carry independently-
authored art passes, mesh re-exports, and DB tunings — bit-
comparing our ported FH1 zip against the existing on-disk FH1
ALF_8C_08 is unreachable and not the right bar. Validation tiers:
(1) codec roundtrip stability through OUR pipeline = byte-equal;
(2) structural invariants (output re-parses, sections preserved,
headers well-formed, vertex pools valid, indices in range, DB rows
respect schema); (3) donor cross-check on structural shape only
(section counts, header field shapes, expected named sections
present); (4) in-game load test — the only ground truth.

### CLI safety layer (Phase 2.5, landed 2026-05-01)
Pre-UI primitives that get the data model and safety guarantees right
without SDL3 noise. The UI later replays these same ops under buttons.

1. **`list <game-folder>`** — walks `<folder>/<profile.cars>`, prints
   profile / TitleID + each archive's basename + size. Profile is
   auto-detected by trying each `profiles/*.json`'s `cars` relpath.
   Pure read. (`orchestrator/scan.nim`.)
2. **`mount <game-folder>` / `mounts`** — registers folder under the
   detected game-id in `~/.config/carbin-garage/mounts.json` (XDG
   aware). Re-mounting an existing id updates in place. `mounts` lists
   the registry and flags missing folders. (`core/mounts.nim`,
   `orchestrator/mount.nim`.)
3. **`export-to <working-car> <game-id> [--dry-run]`** — copies
   `working/<car>/.archive/source.zip` to
   `<mount>/<profile.cars>/<car>.zip`. Atomic: stages a `.tmp`, moves
   the existing target to `.bak` if present, then renames `.tmp` →
   target. Refuses if `.bak` already exists (prevents clobbering the
   one stashed copy). `--dry-run` prints the plan without touching
   disk. Source is always byte-equal — re-encode-from-edits is Phase
   2b. (`orchestrator/exportto.nim`.)

`--name <slug>` from the original spec was dropped for this slice; the
target zip name is always the working car's directory basename. Add it
back when porting/renaming becomes a real workflow.

### Phase 3 — UI shell (deferred until CLI safety layer is exercised)
Three-zone layout (top tabs / game library / working/ / stats drawer)
per `APPLET_ARCHITECTURE.md`. The CLI commands above are the operation
surface the UI calls.

## Open RE items (don't block applet shipping)

1. **`m_MaterialSets[]` parser** — authoritative subsection→texture
   binding. Currently we use a name-prefix heuristic. Doesn't matter
   for byte-passthrough export; matters for "the game actually links to
   my edited texture".
2. **~~FH1 `lod0.carbin` partial parse~~ — RESOLVED 2026-05-01.** Full
   parse via `lod0VCount × 4`-byte post-pool per-vertex stream fix.
   See `docs/FH1_CARBIN_MASTER.md` §11.
3. **~~FH1 `cockpit.carbin` partial parse~~ — RESOLVED 2026-05-01.**
   Same fix as lod0. One BMW M3E30 cockpit non-mesh section remains
   semantically opaque (wiper/decal metadata; round-trips fine).
4. **FH1 stripped TypeId 0** — header-only stub format. Currently
   filtered out of the glTF emit (`isStripped`). Format unknown.
5. **FH1 `perSectionId` semantics** — round-trip safe via passthrough,
   but synthesizing a value for a ported / custom car needs RE.
6. **FH1 expanded-middle header table** (`0xD4..0x2D3`, 128 words) —
   structure not classified.
7. **FM4 tail damage table / `extra8`** — passed through verbatim, not
   interpreted. Gates Phase 6 damage slider.
8. **`.xpr` cubemap container** — gates Phase 7 reflection probe.
9. **FH1 quat encoding for caliper sections** — only 2 of the 4 quat
   components are populated for caliper vertex 0 (zeros at offset
   12..15, real data at 16..19). Mesh shape is correct after the LOD0
   pre-pool fix; only normals are off (lighting reads as flat-shaded).
10. **Sidecar `car.sidecar.json` not yet emitted** — architecture doc
    specs the per-game `headerBytes` / `tailTable` blocks; current
    emitter writes `carslot.json` + `cardb.json` only. Needed for
    re-encode export after edits.
11. **Database write-back (read side done; write side open)** —
    `cardb.json` now captures the per-car rows on import (Phase 2d).
    Writing them back to a target game's `gamedb.slt` lands with the
    export pipeline. For cross-game / new-car exports, the user picks
    a donor from the target game's roster: the donor's SQL row is the
    template for the patch and the donor's `physicsdefinition.bin`
    is copied verbatim (no synthesizer — see
    `FH1_PHYSICSDEFINITION_BIN.md` §"Donor-bin strategy"). Schema
    migration for the 9 FH1-only `Data_Car` columns + the
    `E3Drivers` row is open until we tackle FM4→FH1 export, but the
    donor-row template makes that a copy-from-donor op rather than a
    synthesis op.

## Files we extract but flatten

Forza zip members carry directory structure (`physics/maxdata.xml`,
`liverymasks/back.tga`, `digitalgauge/dash_*.bgf`) and case (FH1 mixes
`Physics/MAXData.xml` and `LiveryMasks/Masks.xml`). Our import flattens
both via `extractFilename`. The original layout is preserved inside
`.archive/source.zip` so byte-equal export works fine; for re-encode
export we'll walk `source.zip`'s central directory at write time and
splice modified payloads into it rather than rebuild from scratch.

## Phase ordering rationale

Architecture-doc order was: Phase 1 (FM4 read) → Phase 2 (FH1 +
bidirectional) → Phase 3 (UI). Reality reordered to: Phase 1 → Phase
2a (FH1 import) → Phase 2c (textures) → CLI safety layer → Phase 2b
(export + transcode) → Phase 3 (UI).

The key driver: textures came earlier than planned because they unlock
visual validation in DCC tools, which in turn surfaced parser / emit
bugs (winding inversion, UV transforms, FH1 caliper LOD0 pre-pool
block) that pure structural diffing wouldn't have caught. That paid
back the schedule shift.
