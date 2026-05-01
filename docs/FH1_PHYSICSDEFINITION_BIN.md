# FH1 `physicsdefinition.bin` — first-pass dissection

Per-car file, 1.5–2.6 KB, big-endian (Xbox 360 PowerPC). Partially
structured rigid-body physics descriptor — **not just hitboxes**, though
it does carry a collision-hull section at the tail. Findings below are
empirical (12-sample sweep) and not yet implemented in code.

## Sample size distribution

```
BUS_TOUR_12              1514   (showcase non-driveable, simplest)
CHE_Express2500Cargo_05  2064   (cargo van, boxy)
AUS_MiniCooperS_65       2268
BMW_Z4sDrive28i_12       2286
BUG_EB110SS_92 / FOR_GT_05  2294
AUD_R8GT_11              2320
ALF_8C_08                2330
AST_DBR1_58              2400
ASC_KZ1R_12              2434
AST_One77_10             2464
BEN_CONTINENTALGT_11     2502
BMW_M1_81                2560
```

Variance is concentrated at the **tail** (collision-hull section); the
fixed-shape header zone is ~0xCC bytes across every sample.

## Layout (offsets BE)

| Offset | Size | Type | Meaning |
|---|---|---|---|
| `+0x00` | 4 | u32 | `1` — version? |
| `+0x04` | 4 | u32 | `13` — top-level record count? Constant across all samples. |
| `+0x08` | 4 | u32 | `1` |
| `+0x0C` | 4 | f32 | `0.01` — looks like a tolerance / convergence epsilon |
| `+0x10` | 36 | f32×9 | **Symmetric 3×3 inertia tensor (unit-mass, kg⁻¹)**. Diagonal ≈ 0.005..0.17 across samples; off-diagonals match exactly (M[0,1]=M[1,0] etc., verified by `is_sym3`). |
| `+0x34` | 36 | f32×9 | **Symmetric 3×3 inertia tensor (mass-weighted, kg·m²)**. Diagonal ≈ 5..240 across samples; same symmetry. Ratio between this and the prior tensor is ~2000:1 (consistent with curb-weight scaling). |
| `+0x58` | ~104 | f32×~26 | Mixed scalars + vec3s. Center of mass / various pivot points / aero coefs / drag scalars. Several confirmed-zero slots (suggests the tail of a fixed scalar block). Detailed labelling deferred — needs cross-correlation with `gamedb.slt` rows. |
| `+0xCC` | 44×N | record array | Fixed 44-byte records. N varies (ALF=17, FOR_GT=13, BMW_M1=16, BUS_TOUR=17 trivial, MiniCooper=1). First u32 of each record is mostly `1` or `2` — likely a mirror-pair flag (1 = single, 2 = symmetric pair) for wheel / suspension / pivot attachments. |
| variable | variable | indexed mesh | Convex-hull collision data. Contains float32 vertex coords interleaved with byte-index lists (ints `0..0x1F`, grouped 3–8) — classic convex-hull or AABB-tree topology. **This is the "hitbox" section** — its size is what makes the file vary by ~1 KB between cars. |
| last 10 | 10 | tail | `00 00 00 01 00 00 ff ff ff ff` — identical footer across every sample. |

## Why "physicsdefinition" and not "hitboxes"

The file packs three different things:

1. **Mass / inertia rigid-body parameters** (the two 3×3 tensors at
   0x10 and 0x34, plus the scalar block from 0x58). The runtime needs
   these to integrate the chassis as a rigid body — they don't fit the
   "hitbox" framing.
2. **Suspension / wheel / chassis attachment table** (44-byte records
   from 0xCC). The mirror-pair flag and per-record stride strongly
   suggest left/right wheel attachments and chassis-relative pivots.
3. **Collision hulls** (the variable-length tail). This *is* what a
   user would call hitboxes — convex hulls used for collision detection
   and probably damage routing. Size scales with body-shape complexity
   (bus-shape Express van: small; M1 with sculpted wings: large).

## Cross-check vs `gamedb.slt`

For ALF_8C_08, `gamedb.slt`'s `Data_CarBody.PristineBoundingBoxMax-Min`
gives a single AABB. The bin instead carries **per-section convex
hulls** in its tail — a finer-grain representation than the SQL row.
Damage panels and per-corner crush behavior almost certainly read from
the bin, not the SQL row.

For values in the inertia tensors and the 0x58 scalar block, we have
**76 paired (FH1 SQL row, FH1 bin) tuples** to use as a labeling oracle.
The original cross-game FM4↔FH1 plan in `FH1_PHYSICS_DB.md` is moot —
in-game pairing is tighter.

## Donor-bin strategy (locked decision, 2026-05-01)

We are **not** building a `physicsdefinition.bin` synthesizer. For any
export to FH1 where the working car doesn't already have a usable bin
(cross-game port from FM4, brand-new car not in FH1's roster), the user
picks a **donor car** from FH1's existing roster — "close enough"
chassis/category — and the donor's `physicsdefinition.bin` is copied
into the export archive verbatim, renamed for the new car.

Examples:
- Port FM4 Lamborghini Gallardo → FH1 (no Gallardo in FH1's roster):
  user picks Murciélago as donor; Murciélago's bin rides along.
- Brand-new pickup truck added to FH1: user picks Raptor as donor.

Same logic applies to anything else this file's bake step would
otherwise need to synthesize (collision hulls, mass/inertia tensors,
attachment records). Donor passthrough sidesteps the whole problem.

This is fine because:
- The bin is per-car, ~2 KB, with no cross-references to anything
  outside it (no FK into gamedb.slt, no mention of the car's name).
- Vehicles in the same chassis class behave plausibly under a borrowed
  inertia tensor + collision-hull set; users can iterate on the donor
  choice if the result feels off.
- This is what the architecture doc already calls a "donor" — see
  `APPLET_ARCHITECTURE.md` Glossary; the SQL-row picker (`donors`
  block in `carslot.json`) was already going to do the same thing
  for fields we don't represent in glTF. Bin passthrough joins the
  same machinery rather than getting its own.

What this changes in the import pipeline:
- Nothing today — we already copy the source archive's bin verbatim
  via the catch-all branch in `importwc.nim`, and `cardb.json` gives
  us the SQL row.
- At export time, the export dialog needs a "donor" picker for FH1
  targets when the working car has no FH1 bin yet (i.e., the working
  car was imported from FM4 and is being cross-exported). The donor's
  bin goes into the new archive; the donor's SQL row becomes the
  template for the SQL patch (with the user's stat overrides applied
  on top).

What we still might want to RE later (but don't need for export):
- The 0x58 scalar block labels — useful for **showing** the user the
  donor's physics in the stats drawer, even though we don't re-bake.
- The hull-section format — only needed if a user really wants to
  retune collision shape, which is an out-of-scope advanced workflow.

## Open questions (deferred)

1. **Exact field labels in the 0x58..0xCC scalar block** — needs
   per-field correlation against the SQL row's mass / CoG / aero
   columns across cars.
2. **Record interpretation in the 0xCC..tail array** — the 44-byte
   stride strongly suggests `(u32 mirror, vec3 pos, vec3 axis, vec3
   limit, ?)` but unverified.
3. **Hull-section format** — vertex layout (3×f32 BE? compressed?),
   index width (u8 confirmed for face lists, but no clear count
   prefix), and how multiple hulls are concatenated in one file.
4. **Whether SQL row patches alone are sufficient for an export to
   FH1, or whether the bin must be re-synthesized.** If the bin is a
   build-time cache, a runtime-time SQL patch may be ignored — the
   game might only reload the bin. Test by patching `Data_Engine.
   StockBoost-bar` for one car and observing whether the in-game
   power changes.

## Probe

`probe/probe_physicsdef_bin.py` (run on one or more imported
`physicsdefinition.bin`) emits the same dissection table this doc was
written from.
