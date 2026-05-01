# Roadmap

Status snapshot of where carbin-garage is and what's next. Updated 2026-05-01.

**Latest (2026-05-01, encode session):** Phase 2c.3 texture **encode**
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

1. **~~Finish FH1 LOD / full-model parsing~~ — done 2026-05-01.** All 8
   sample `<car>_lod0.carbin` byte-equal roundtrip; 7/8
   `<car>_cockpit.carbin` byte-equal (the 8th has a non-mesh anomaly
   that round-trips fine via skip-and-resume but doesn't surface in
   glTF). Cross-car ports now have full mesh data on both sides.
   `stripped_*.carbin` stays on donor passthrough indefinitely —
   likely never worth re-implementing.
2. **Texture porting** — three sub-pieces:
   - **Re-encode on edit (Phase 2c.3)**: PNG → BC + Xenon retile +
     `.xds` header rewrite. Triggered by
     `working/<slug>/textures/<name>.xds.png` newer than `<name>.xds`.
     Unblocks visual edits flowing through to export.
   - **Cross-game container compat**: verify FM4↔FH1 `.xds` is
     interchangeable byte-for-byte (both Xbox 360, BC1/3/5, Xenon
     tile). If yes, source textures port verbatim; if no, identify
     the delta (header version? format-id remap?).
   - **Texture-name resolution for cross-car ports**: donor's archive
     has its own texture set; source's textures need to splice in
     under names the donor's shaders expect. FH1 also ships
     `extraXdsBuckets` (`interior_emissive_LOD0`, `zlights`) that FM4
     doesn't — handle missing/extra buckets explicitly.
3. **LZX encoder + carbin transcode + DB patcher** (already-tracked
   Phase 2b work) — the bytes-on-the-wire side. Independent of the LOD
   and texture work above; can run in parallel.

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

### Phase 2c.3 — Texture re-encode + porting (see "Where we stopped" above for full scope)
Three sub-pieces queued; not started:
- PNG → BC1/BC3 via `stb_dxt.h` + Xenon retile + `.xds` header rewrite.
- Cross-game `.xds` container compat verification (FM4 ↔ FH1).
- Cross-car texture-name resolution against donor's shader name-set,
  including FH1's `extraXdsBuckets`.

### Phase 2b — FM4 ↔ FH1 export
- LZX encoder via wimlib's `lzx_compress` (libmspack ships no encoder;
  `vendor/libmspack/.../lzxc.c` is `/* todo */`). Decoder stays on
  libmspack `lzxd` — wimlib's decoder is WIM-LZX-restricted and isn't
  a fit for CAB-LZX bitstreams. Two libs, each used for what it does
  well; see project memory "LZX library split".
- Carbin transcode (TypeId 2 ↔ TypeId 5) using deltas in
  `FH1_CARBIN_TYPEID5.md` §"Practical implications for porting".
  Strategy = **Option C hybrid donor splice**: donor scaffolding
  (header / expanded-middle table / unknown per-section fields), source
  sections re-quantized in. Same approach extends to `<car>_lod0.carbin`
  and `<car>_cockpit.carbin` once the FH1 RE for those files lands;
  donor passthrough is the fallback until then.
- **Validation is structural, not byte-equal-vs-on-disk.** ALF_8C_08
  ships in both rosters, but the two games carry independently-authored
  art passes, mesh re-exports, and DB tunings — bit-comparing our
  ported FH1 zip against the existing on-disk FH1 ALF_8C_08 is
  unreachable and not the right bar. Validation tiers: (1) codec
  roundtrip stability through OUR pipeline = byte-equal; (2) structural
  invariants (output re-parses, sections preserved, headers well-formed,
  vertex pools valid, indices in range, DB rows respect schema);
  (3) donor cross-check on structural shape only (section counts,
  header field shapes, expected named sections present); (4) in-game
  load test — the only ground truth.
- `physicsdefinition.bin` **passthrough from a donor** — locked
  decision 2026-05-01. We do NOT synthesize a fresh bin. The export
  dialog asks the user to pick a "close-enough" donor car from FH1's
  roster (e.g. Murciélago for a ported Gallardo, Raptor for a new
  pickup truck) and the donor's bin is copied verbatim into the new
  archive. Same passthrough applies to `stripped_*.carbin`. Details:
  `FH1_PHYSICSDEFINITION_BIN.md` §"Donor-bin strategy".

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
