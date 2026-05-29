# FH1 carbin part editing — add / remove / replace + texture (RE findings)

Empirical findings from in-game (xenia) testing on the Alfa 8C (ALF_8C_08),
2026-05-28. Covers removing parts, the hard wall on *adding* parts, the
working **replace-a-slot** method for arbitrary new geometry, bounding-box
control, and texturing. "Confirmed" = verified loading/rendering in-game.

All edits operate on the DLC export path (`portto_dlc`), driven by a
`working/<slug>/part_edits.json` sidecar (schema at the end). The geometry
itself comes from the working/ glTF (Phase 1/2, see
`project_gltf_pack_phase*`); parts are synthesized by `core/carbin/section_edit.nim`.

---

## 1. Sections are name-keyed, not index-keyed

Nothing references a carbin section by ordinal index — physicsdef.bin, the
gamedb tables, and the transcoder all key off the section **name**
(`model.SectionInfo.index` is parsed but unused). The game looks up each
section name in a **fixed part-name registry** (the vocabulary across all
cars: `body`, `hooda`, `bumperF{a-d}`, `bumperR{a-d}`, `wing{a-d,z,race}`,
`skirt{L,R}{a-d}`, `glass*`, `headlight{L,R}`, `mirror{L,R}`, `seat{L,R}`,
`interior`, `wheel`, `exhaust*`, `trunk`, `undercarriagea`, `cagerace`,
`steering_wheel`, …). A section whose name is **not** in the registry is a
bad-slot lookup → **write to a bad address (AV at `0x20000000`) → crash.**
Cars differ in part count because they use different *subsets* of this
registry.

## 2. Removing parts — WORKS (flawless)

Drop the section's bytes and decrement the u32 `partCount`
(`CarbinInfo.partCountPos`). Nothing else to fix (name-keyed). Confirmed
removing `bumperRa`, `body`, etc. The runtime tolerates fewer parts than the
donor (a removed name simply isn't rendered).
- Sidecar: `{"drop": ["bumperRa", "body"]}`

## 3. Adding parts (> donor's count) — HARD DEAD-END

Appending a section beyond the donor's part count **always crashes** —
verified with a 100%-valid *verbatim copy* of a real section, given a valid
**registry name**, at count 34. The crash is a write one-past-the-end of a
buffer at the top of 512 MB RAM (`0x20000000`) = a fixed-size allocation
overflow.

The budget is **not in any file we can edit**: searched the carbin header
(only one `partCount` field, which we *do* set), all aggregate counts, and
all 56 cloned `merge.slt` tables — no per-car geometry budget found. The
allocation is decided by the engine (Xbox 360 static allocation, sized from
the donor's data the DLC inherits). Going *under* leaves slack; going *over*
overflows.

→ To truly add geometry **above** the donor's budget you'd need to RE the
donor manifest/DB blob for the size field and bump it, port onto a
higher-poly donor, or xex-patch the allocator. Not done.

## 4. Replacing a slot — WORKS (the way to add arbitrary geometry)

Since you can't exceed the donor's budget, put new geometry **into an
existing slot** (count stays the donor's). Confirmed: penger (716 v) rendered
in the `body` slot.

Rules / synthesis (`section_edit.synthSectionFromMesh`, clones a donor
section as scaffold):
- **Vertex count must be ≤ the donor slot's** vertex count (716 ≤ `body`'s
  12,612 ✓). Use a high-vert slot for headroom (`body` 12,612, `wheel`
  6,506, `bumperFa` 3,459). (A `716 > hooda(444)` crash was seen but on older
  code — the per-section cap is plausible but not cleanly re-confirmed.)
- **Clone a CLEAN template** (`permCount==0 && cnt2==0`). Glass sections carry
  permutation/index blocks that reference *their own* geometry → cloning onto
  a new mesh reads out of range (ERANGE). `body`/`hooda`/`bumper*` are clean;
  `glass*` are not.
- **Replace IN PLACE** (keep the section's ordinal position). The last
  section's tail has no next-marker to delimit it; appending the replacement
  at the end risks a footer desync. `applyPartEdits` substitutes in place.
- **a×b damage table content is irrelevant to loading** (zeroing it loads
  fine; we cycle the template's records anyway).

### Synthesis pipeline is sound (bisect results)

Starting from a real hooda and flipping ONE thing at a time, all of these
**load fine** in-game: regenerated quaternions, TriStrip→TriList, merging 9
subsections→1, zeroed a×b table, and a full from-its-own-geometry resynth.
So position re-quantize, quat generation, index encoding, single-subsection,
and section assembly are all correct.

## 5. Bounding box = size + position control — the runtime HONORS the written transform

The section's 9-float transform (offset.xyz + targetMin.xyz + targetMax.xyz)
**is honored** for a replaced section. The mesh is fit (uniform, aspect-
preserved) into the target bbox; writing a larger bbox makes the part bigger
(`boxScale 3×` → ~3× penger, confirmed). The pool must span the donor
section's *native pool range* and be remapped relative to the written
target, consistently (`buildMeshPoolFit`) — getting this inconsistent was
what caused the early "squished to slot aspect / wrong size" results.

- `boxScale`: multiplies the target bbox (size).
- `offset` [x,y,z]: added to the section offset (position). NOTE: the engine
  appears to **recenter** a model by its bbox (observed on the hood-spike:
  raising verts moved the bbox center up, the placement shifted down to
  compensate). So a plain `offset` may be partially canceled — bias the mesh
  within an enlarged bbox if precise placement is needed. (Not fully nailed.)

## 6. Texturing — WORKS in-game via emissive material + texture overwrite

Body paint is a runtime shader (no .xds). The .xds atlases with real sampled
content: `lights` (head/tail lights, reflectors), `nodamage` (interior +
badges), `interior_lod0`, `leather*_nrm`.

**The in-game material binding = the cloned subsection's `m_MaterialSets`
entry** (rides along when we clone a subsection — pick which via `subName`).
That block is **not parsed** (the one open RE item), so material choice is
currently by cloning a subsection known to use a given material, then
overwriting that material's .xds with our texture (encode PNG → .xds via
`reencode-textures` from the `.xds.png` sidecar).

### Material behavior in-game (empirical)

| Donor subsection | Samples | In-game result |
|---|---|---|
| `black` (body ss0) | — | renders, **no texture** (vantablack) |
| `interior` | `nodamage` | textured in **LOD0/autoshow/photo**, but **unlit → black in-game** |
| `emblem` | (decal) | **alpha-masked → discarded** (part vanishes) |
| `reflector` | `lights` | **emissive → textured AND visible in-game** ✓ (but glossy/shiny) |

So: **clone an emissive material (`reflector`/lights), overwrite `lights.xds`
with the texture.** Penger rendered with its penger.png skin in-game this way.

### Texture caveats / TODO
- **UV mapping is off** in-game (penger's UVs stored with identity
  `m_UVOffsetScale`, but the mapping doesn't line up — likely a V-flip or the
  material's expected atlas sub-region). Needs the real UV convention.
- **Shininess** — `reflector` is glossy; want a matte-but-lit material.
- **LOD0 vs in-game** differ: LOD0/autoshow textures readily (lighting-
  tolerant); in-game needs a lit/emissive material.

## 7. Control surface — `working/<slug>/part_edits.json`

```jsonc
{
  "drop":    ["bumperRa"],                  // remove sections (§2)
  "addName": {"penger": "body"},            // synth glTF mesh -> slot (replace if existing) (§4)
  "subName": "reflector",                   // which template subsection to clone (material) (§6)
  "boxScale": 1.6,                          // size: target-bbox multiplier (§5)
  "offset":  [0, 1.0, 0]                    // position shift (§5; recenter caveat)
  // debug: "dupAppend":[{src,name}], "mutate":[{section,op}]  (op: regenquats|trilist|mergesubs|zeroatable|resynth)
}
```
CLI: `add-part <work> <obj> --name --place x,y,z --scale s` (inject OBJ into
car.gltf); `drop-part <work> name,name`. Textures: overwrite
`working/<slug>/textures/<name>.xds.png`, run `reencode-textures <work>`.

Working recipe for "put an arbitrary textured mesh in-game":
1. `add-part` the OBJ into car.gltf (or it's already a glTF mesh).
2. Overwrite an emissive texture (`lights.xds`) with the mesh's PNG; `reencode-textures`.
3. `part_edits.json`: `addName` mesh→a clean high-vert slot (`body`),
   `subName: "reflector"`, `boxScale`/`offset` to taste.
4. `port-to-dlc … --pack-from-gltf`.

## 8. Open RE items
- **Parse `m_MaterialSets`** — turns material binding from guesswork into a
  deliberate choice (pick a lit/opaque material, point it at our texture) and
  fixes UVs. The proper texture fix.
- Correct UV convention for synthesized subsections (V-flip / atlas region).
- Confirm/locate the per-car geometry **budget** (to ever exceed the donor).
- Confirm `offset` vs the engine's model recentering.
