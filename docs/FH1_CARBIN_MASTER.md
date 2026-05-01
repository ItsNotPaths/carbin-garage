# FH1 .carbin Modding — Master Reference

**Project:** Forza Horizon 1 (FH1) car-archive modding pipeline (carbin-garage)
**Tool:** carbin-garage (Nim) — production parser at `src/carbin_garage/core/carbin/parser.nim`
**Authority:** Reverse-engineered against 8 paired FM4↔FH1 sample cars; cross-validated by byte-equal roundtrip on 8 cars × 3 carbin variants × 8 brake corners (= 56 carbins, 100% pass).
**Cross-references:**
- `FM4_CARBIN_MASTER.md` — TypeId 2 baseline, the structural ancestor
- `FH1_CARBIN_CONDENSED.md` — quick-reference distillation of this doc
- `FH1_CARBIN_TYPEID5.md` — RE narrative (probe outputs, hypotheses)
**Last updated:** 2026-05-01 (lod0/cockpit RE complete — see §7)

---

## Table of Contents

1. [Scope & Authority](#1-scope--authority)
2. [Carbin Variants in an FH1 zip](#2-carbin-variants-in-an-fh1-zip)
3. [Version Detection (TypeId 1, 5)](#3-version-detection-typeid-1-5)
4. [Top-level Header Shape](#4-top-level-header-shape)
5. [The Shared Prelude (0x000..0x0D3)](#5-the-shared-prelude-0x0000x0d3)
6. [The Expanded Middle (0x0D4..0x2D3)](#6-the-expanded-middle-0x0d40x2d3)
7. [Body — Section Layout (cvFive)](#7-body--section-layout-cvfive)
8. [Subsection Layout (cvFive)](#8-subsection-layout-cvfive)
9. [Vertex Format (28-byte stride)](#9-vertex-format-28-byte-stride)
10. [Section Tail (cvFive, +12 B vs FM4)](#10-section-tail-cvfive-12-b-vs-fm4)
11. [lod0 / cockpit per-vertex post-pool stream (FH1-only)](#11-lod0--cockpit-per-vertex-post-pool-stream-fh1-only)
12. [TypeId 1 — Caliper / Rotor Carbins](#12-typeid-1--caliper--rotor-carbins)
13. [Stripped Carbins (TypeId 0)](#13-stripped-carbins-typeid-0)
14. [Section-count Catalog (8 sample cars)](#14-section-count-catalog-8-sample-cars)
15. [UV System & Material Resolution](#15-uv-system--material-resolution)
16. [Index Buffers (TriList / TriStrip)](#16-index-buffers-trilist--tristrip)
17. [Wheel & Brake Instancing (post-emit)](#17-wheel--brake-instancing-post-emit)
18. [Practical FM4 → FH1 Port Recipe](#18-practical-fm4--fh1-port-recipe)
19. [Validation Strategy (Cross-game / New-car)](#19-validation-strategy-cross-game--new-car)
20. [Open RE Items](#20-open-re-items)
21. [Probes & Repro](#21-probes--repro)

---

## 1. Scope & Authority

This doc covers the *Xbox 360 Forza Horizon 1* car-archive carbin format, as RE'd inside the carbin-garage project. The structural ancestor is FM4's TypeId 2 (covered in `FM4_CARBIN_MASTER.md`); FH1 retains FM4's body parse order with five precise deltas keyed off a per-section "version" word that bumps `2 → 3`. The five deltas:

1. Section header `+8` bytes after `lodVSize` (`m_NumBoneWeights u32` + optional `perSectionId u32`); applies before *both* LOD and LOD0 pools.
2. Subsection prefix `+4` bytes before `idxCount` (a `u32 = 0` reserved padding).
3. Vertex stride `0x20 → 0x1C` (UV1 dropped).
4. Section tail `+12` bytes (4 init, 4 reserved=1 between b and a*b, 4 trailing) + populated 2nd table.
5. **lod0 / cockpit only**: per-vertex `lod0VCount × 4` byte stream after the tail.

> **Authority precedence (when sources conflict):**
> 1. The byte-equal roundtrip status across our 8-car sample (the empirical ground truth).
> 2. `core/carbin/parser.nim` (the production read path; tracks RE).
> 3. This document and `FH1_CARBIN_TYPEID5.md` (hypotheses, often partial).
> 4. `probe/reference/fm4carbin/` (the FM4 oracle; FM4-only).
>
> When in doubt, run `./build/carbin-garage roundtrip <zip> --profile fh1` — if it says OK, the reader and writer agree.

---

## 2. Carbin Variants in an FH1 zip

A typical FH1 car zip (`<CAR>.zip` in the game's `media/cars/` directory) contains:

| File pattern | TypeId | Role | Parsed? |
|---|---|---|---|
| `<car>.carbin` | 5 | **Main** body — LOD pool (mid-distance) + LOD0 pool (close) per section. Most-detailed art. | ✓ full |
| `<car>_lod0.carbin` | 5 | High-detail close-up sibling. Sections have only a LOD0 pool; carries an extra per-vertex normal/tangent stream (§11). | ✓ full (this RE) |
| `<car>_cockpit.carbin` | 5 | First-person cockpit cam mesh. Same shape as `_lod0.carbin`. | ✓ full (1 anomalous section across 8 sample cars; see §20) |
| `<car>_caliper{LF,LR,RF,RR}_LOD0.carbin` | 1 | Per-corner brake caliper (4 carbins). | ✓ full |
| `<car>_rotor{LF,LR,RF,RR}_LOD0.carbin` | 1 | Per-corner brake rotor (4 carbins). | ✓ full |
| `stripped_<car>.carbin` | 0 | Header-only stub. Format unknown; round-trip via passthrough. | ✗ opaque |
| `stripped_<car>_*.carbin` | 0 | Same. | ✗ opaque |
| `physicsdefinition.bin` | — | FH1-only physics blob (FM4 stores physics in `gamedb.slt`). Donor passthrough on cross-game ports. | ✗ opaque |
| `Physics/MAXData.xml` | — | Wheelbase / track widths / mass data. Used by importer for wheel hub instancing. | ✓ XML parse |
| `<bucket>.xds` | — | Xbox 360 D3DBaseTexture: BC1/3/5 + Xenon tile. Decoded in `core/xds.nim`. | ✓ decode (encode pending) |
| `LiveryMasks/*.tga`, `LiveryMasks/Masks.xml` | — | Per-car livery decal layout. Round-trip verbatim. | ✗ opaque |
| `digitalgauge/*.bgf/.bsg/.fbf/.xds` | — | Per-car digital dashboard (font + frame buffer). Round-trip verbatim. | ✗ opaque |
| `cars_<car>_build_report.html`, `BuildNumber.txt`, `*.xml` | — | Build metadata. Round-trip verbatim. | n/a |

A typical Audi TT RS (`AUD_TTRS_10.zip`):
- main = 51 sections, lod0 = 38 sections, cockpit = 23 sections, 4 calipers (1 sec each), 4 rotors (1 sec each) = 121 sections / 60 carbins.

Cross-game: an FM4 zip has the same structure with these substitutions: TypeId 2 instead of 5; vertex stride 32 instead of 28; no `physicsdefinition.bin` (physics in `gamedb.slt` → `Data_Car`).

---

## 3. Version Detection (TypeId 1, 5)

`getVersion(data)` in `core/carbin/parser.nim` sniffs the first two u32 BE words plus three "magic" anchor offsets at `0x70`, `0x104`, `0x154`:

| Sniff | Decision | `cvVersion` |
|---|---|---|
| word[0] = 5 | FH1 main / lod0 / cockpit | `cvFive` |
| word[0] = 1 ∧ word[1] = `0x11` | FH1 caliper / rotor LOD0 | `cvFive` (TypeId 1 path) |
| word[0] = 1 ∧ word[1] = `0x10` | FM4 caliper / rotor | `cvFour` |
| word[0] = 2 | FM4 main / lod0 / cockpit | `cvFour` |
| word[0] = 1 ∧ f3test = 0 | FM3 (legacy) | `cvThree` |
| word[0] = 0 | Stripped | unparseable |

The single distinguishing byte for "is this FH1 or FM4 brakes?" is **word[1] high byte**: `0x10` (FM4) vs `0x11` (FH1). Beyond that one delta, the body parse is identical to FM4's TypeId 1 prelude — only the `cvFive` section-level deltas (§7) apply.

---

## 4. Top-level Header Shape

| Zone | TypeId 2 (FM4) | TypeId 5 (FH1) | Relationship |
|---|---|---|---|
| **Prelude** | `0x000..0x0D3` (212 B) | `0x000..0x0D3` (212 B) | **Identical layout & values.** |
| **Middle (offset table)** | `0x0D4..0x18F` (188 B / 47 words) | `0x0D4..0x2D3` (512 B / 128 words) | **+324 B (+0x144 / +81 words)**. Reformatted, not just extended. |
| **Trailing fields** | `0x190..0x397` (520 B) | `0x2D4..0x4DB` (520 B) | **Identical layout, shifted by +0x144 bytes.** |
| **Body** | starts `0x398` | starts `0x4DC` (main) / variable for lod0/cockpit | First post-header bytes byte-identical. |

Total header: TypeId 2 = `0x398`; TypeId 5 main carbin = `0x4DC` (= `0x398 + 0x144`).

For `<car>_lod0.carbin` and `<car>_cockpit.carbin`, the prelude is **flattened and variable-length** — words 1..5 are zero, body starts vary `0x57C..0x6E0` across the 8-car sample. The forward-scan partCount detection handles this cleanly.

### Locating partCount (forward-scan)

The robust way to find `partCount` in any TypeId 5 carbin is to scan `i` from offset `0x4DC` (main) or `0x100` (lod0/cockpit) forward, looking for `[u32 in 1..255][u32 in {2, 5}][9 sane floats]`:

```nim
# parser.nim, the cvFive partCount scan
var i = 0x4DC
while i < scanLimit:
  let pc = u32_be(data, i)
  let marker = u32_be(data, i + 4)
  if pc in 1'u32..255'u32 and (marker == 2'u32 or marker == 5'u32):
    # try to parse pc sections starting at i+4; if section[0] parses
    # cleanly, this is the real partCount. Otherwise advance i and retry.
```

The "real" `partCount` is whichever candidate yields the most successful section parses; tie-break by larger `pc` (biases toward main-carbin's tens-of-sections over single-section stubs).

---

## 5. The Shared Prelude (`0x000..0x0D3`)

The 212-byte prelude is byte-identical between TypeId 2 and TypeId 5 *for the same car*. Layout (verified across 8 paired carbins):

| Offset | Field |
|---|---|
| `0x00..0x03` | `TypeId` u32 BE |
| `0x04..0x13` | record 0 — 4 floats (BE) |
| `0x14..0x43` | 48 B trailing data (mostly zero, a few constants/offsets) |
| `0x44..0x53` | record 1 — 4 floats |
| `0x54..0x83` | 48 B trailing |
| `0x84..0x93` | record 2 — 4 floats |
| `0x94..0xC3` | 48 B trailing |
| `0xC4..0xD3` | record 3 — 4 floats |

For `ALF_8C_08` (Alfa 8C, identical values FM4 and FH1):

```
record 0: ( 0.9754,  1.1354,  0.1082, -0.3920)
record 1: ( 0.9859,  1.1421,  0.0852,  0.4020)
record 2: ( 0.9544,  1.1208, -0.1360,  0.3745)
record 3: ( 0.9544,  1.1218, -0.1011, -0.3787)
```

The X/Y values cluster near `±half-track / wheelbase-related` magnitudes but **don't match `MAXData.xml`'s `Wheelbase / FrontTrackOuter / RearTrackOuter` exactly**. Best current hypothesis: **per-wheel anchor / pivot points (FL, FR, RL, RR)**. Cross-correlate with `Data_CarBody.BottomCenterWheelbasePos*` in `gamedb.slt` for confirmation.

The 48-byte trailing blocks contain floats around 0..1, small-int magic values, and **byte offsets into the carbin file** clustered ~80% through the file (likely an offset table pointing to LOD/section payloads).

> **For lod0/cockpit carbins**: words 1..5 (the per-car float records) are zero, and the entire prelude is a flattened, variable-length zone. We forward-scan for partCount; field-classification of the lod0/cockpit prelude is open (§20).

---

## 6. The Expanded Middle (`0x0D4..0x2D3`)

This is the **only** region where TypeId 5 genuinely differs in layout from TypeId 2. FM4 packs 47 words here; FH1 packs 128 words. Field-by-field correspondence isn't a simple insertion — sliding a 324-byte hole between any two 4-byte boundaries doesn't reproduce FM4 from FH1.

For `ALF_8C_08`, FH1's middle is mostly zeros with a small cluster of non-zero floats. **Plausible contents** (untested):
- Extra LOD entries (FH1 may keep more LODs).
- Additional section pointers.
- Horizon-specific anchor points (per-physics-zone attachments, dynamic-camera mounts).

This is the **largest remaining RE gap** for FH1. For now, donor-template passthrough (use a similar FH1 car's middle table verbatim) is the workaround for synthesizing new FH1 carbins.

### Trailing region (`0x190..0x397` FM4 ⇔ `0x2D4..0x4DB` FH1)

**Identical layout, shifted by +0x144.** Per-car float anchors that match across all 8 sample cars at the +0x144 shift:

| FM4 word | FM4 off | FH1 word | FH1 off | Sample value (`ALF_8C_08`) |
|---:|---:|---:|---:|---|
| 100 | 0x190 | 181 | 0x2D4 | `0x34800000` (2.38e-07) |
| 104 | 0x1A0 | 185 | 0x2E4 | `0xbf15f4f3` (-0.586) |
| 105 | 0x1A4 | 186 | 0x2E8 | `0x3e75834a` (0.240) |
| 106 | 0x1A8 | 187 | 0x2EC | `0x4001cf89` (2.028) |
| 121 | 0x1E4 | 202 | 0x328 | `0x3d2537e7` (0.0403) |
| 122 | 0x1E8 | 203 | 0x32C | `0x3f6a4bff` (0.915) |
| 124 | 0x1F0 | 205 | 0x334 | `0x00000002` |
| 129..143 | 0x204..0x23C | 210..224 | 0x348..0x380 | varying floats |

Within this region, FM4 has documented offsets in `FM4_CARBIN_MASTER.md` §17 (`carbin.bt` template analysis); the same fields apply to TypeId 5 at +0x144.

---

## 7. Body — Section Layout (`cvFive`)

```
section_start
    +0  marker u32  (2 in cvFour, 5 in cvFive)
    +4  9 floats: offset.xyz, targetMin.xyz, targetMax.xyz   (BE)
    +0x28  28 bytes (m_Mass / m_CenterOfMass / m_DetachDamage / m_GlassParticles area)
    +0x44  permCount u32                       ← typically 0 (≤ 1 in our sample)
    +     permCount * 16 bytes
    +     4-byte skip
    +     cnt2 u32                             ← typically 0
    +     cnt2 * 2 bytes
    +     12-byte skip
    +     nameLen u8 + name bytes
    +     version u32                          ← FM4 = 2, FH1 = 3 (the cvFive marker)
    +     lodVCount u32
    +     lodVSize u32
    +     ─── cvFive +8 insert (version >= 3) ────────────────
    +       m_NumBoneWeights u32                ← 1 in body sections, 0 in caliper / rotor / lod0 / cockpit
    +       perSectionId u32  (only when m_NumBoneWeights != 0)
    +     ─────────────────────────────────────────────────────
    +     LOD pool: lodVCount × lodVSize bytes  (28-byte stride in FH1)
    +     4-byte skip
    +     subpartCount u32
    +     subpartCount × subsection bytes  (see §8)
    +     4-byte skip
    +     lod0VCount i32
    +     lod0VSize u32
    +     ─── cvFive +8 insert (only if lod0V > 0) ────────────
    +       m_NumBoneWeights u32                ← second copy, before LOD0 pool
    +       perSectionId u32  (only when m_NumBoneWeights != 0)
    +     ─────────────────────────────────────────────────────
    +     LOD0 pool: lod0VCount × lod0VSize bytes
    +     [section tail — see §10]
    +     [post-tail per-vertex stream — see §11, lod0/cockpit only]
section_end
```

### The pre-pool `m_NumBoneWeights / perSectionId` block — applies to BOTH pools

This is the single trickiest detail in the FH1 RE. The 4..8 byte block (`m_NumBoneWeights u32` + optional `perSectionId u32`) precedes **both** the LOD pool and the LOD0 pool. Two pools, two copies of this block.

- `m_NumBoneWeights == 1` for body sections that have skinning data → `perSectionId u32` follows (8 bytes total).
- `m_NumBoneWeights == 0` for caliper / rotor sections AND for lod0 / cockpit body sections (these are static streams without skinning) → no `perSectionId` (4 bytes total).

**Discovered 2026-05-01 fix**: caliper / rotor sections are LOD0-only (no LOD pool). Until the pre-LOD0 copy of this block was wired in, the parser read the first vertex's position 8 bytes early — calipers rendered scrambled. The fix was mirrored from `parseSection`'s pre-LOD path into the cvFive pre-LOD0 path.

`perSectionId` is **non-zero, per-section unique, and round-trip safe by passthrough**. Likely a CRC, node-tag, or pointer into the expanded middle table; semantically unknown.

---

## 8. Subsection Layout (`cvFive`)

```
subsection_start
    +0   5 bytes skip
    +5   8 floats: m_UVOffsetScale  (XOff, XScale, YOff, YScale × UV0 + UV1)
    +0x25  36 bytes skip
    +0x49  nameLen i32 (32-bit length prefix)
    +     name bytes
    +     lod i32        (0 = LOD0, 1..4 = LOD1..4)
    +     indexType u32  (4 = TriList, 6 = TriStrip)
    +     6 floats (24 B)
    +     8 floats (32 B)
    +     ─── cvFive +4 insert ─────────────────
    +       reserved u32 = 0   ← ALWAYS 0 in 3,108 paired subsections
    +     ───────────────────────────────────────
    +     idxCount i32
    +     idxSize i32  (2 or 4)
    +     idxCount × idxSize bytes (index buffer)
    +     4-byte tail skip
subsection_end
```

The subsection "version" field after the name is FM4 `[u32 = 3]`; FH1 reads as `[u32 = 4][u32 = 0]` (observed at `+0xA0` from subsection start, before `idxCount`). This is the +4 padding above.

`m_UVOffsetScale` carries 8 floats: `(xOff, xScale, yOff, yScale)` for UV0 and the same for UV1. UV1 isn't used by FH1 (vertex stride dropped UV1 entirely) but the floats are still in the subsection header.

---

## 9. Vertex Format (28-byte stride)

| Offset | Size | Field | Decode | Delta from FM4 |
|--------|------|-------|--------|----|
| 0x00 | 8 B | Position | 4× int16 (x, y, z, scale). `ShortN(v) = v / 32767.0`. Final: `(x*s, y*s, z*s)` | unchanged |
| 0x08 | 4 B | UV0 | 2× uint16. `UShortN(v) = v / 65535.0` | unchanged |
| 0x0C | 8 B | Quaternion (normal/tangent) | 4× int16 ShortN → matrix → row 0 = normal | shifted from 0x10 in FM4 |
| 0x14 | 8 B | extra8 | opaque, round-trip verbatim | shifted from 0x18 in FM4 |

UV1 (4 B at FM4's 0x0C) is **dropped** in FH1's 28-byte stride. The "second tangent / paint data" the FM4 master speculates lives in `extra8` may be encoded differently (or in the lod0/cockpit per-vertex stream — see §11).

`decodeVertex28` lives in `core/carbin/vertex.nim`.

### Helper functions

```nim
proc uShortN(v: uint16): float32 = float32(v) / 0xFFFF.float32
proc shortN (v: int16):  float32 = float32(v) / 0x7FFF.float32
```

### Quaternion → Normal

Same path as FM4: take the int16 quaternion, normalize via `ShortN`, build a rotation matrix, take **row 0** as the normal vector. Hemisphere convention: negate all components if `qw < 0`.

### Caliper / rotor partial quat encoding (open)

For caliper sections, the 8-byte quat field at offset `+0x0C..+0x13` has only the **high pair** populated for the first vertex (zeros at `+0x0C..+0x0F`, real data at `+0x10..+0x13`). Mesh shape decodes correctly after the LOD0 pre-pool fix; only normals read flat-shaded around Z. Possibly a per-section base quat + per-vertex delta encoding (untested).

---

## 10. Section Tail (`cvFive`, +12 B vs FM4)

```
FM4: [9 init][a u32][b u32][a*b table][4 mid-skip][c u32][d u32][c*d table]
     fixed = 29 B
FH1: [13 init][a u32][b u32][4 reserved=1][a*b table][4 mid-skip][c u32][d u32][c*d table][trailing 4..8 B]
     fixed = 41 B (when c*d = 0)
```

| Field | Meaning |
|---|---|
| 13 init (FH1) / 9 init (FM4) | mostly zero; first non-zero usually `0x00000001` early on, possibly `m_HasTransparentMeshes` byte + padding. RE gap. |
| `a u32` | Equal to `lodVCount` (main pool vertex count). |
| `b u32` | `4` — bytes per entry in the `a*b` table. |
| `a*b table` | Per-vertex damage / LOD remap data. Always present in FM4; in FH1 same role (round-trips verbatim). |
| 4 reserved=1 (FH1 only) | Inserted between `b` and the `a*b` table; value typically `0x00000001`. |
| 4 mid-skip | usually zeros. |
| `c u32, d u32` | FM4 always `(0, 0)` → `c*d = 0`. FH1 most often `(0, 0)`, sometimes `(3, 0)`, `(4, 1)`, etc. The `[c][d]` header is always retained even when `c*d = 0`. |
| `c*d table` | Empty when `c*d = 0`. Otherwise a small per-section header / hash. |
| trailing | 4 vs 8 bytes; predicate undecided. Parser disambiguates by probing for the next-section marker at `+0/+4/+8` from the end of `c*d`. |

Across 256 paired sections in the 8-car sample: `(c, d) = (0, 0)` ×99, `(3, 0)` ×157. So in FH1, `d` is always 0 → second table is data-empty. The `c` value itself isn't always zero; it's a flag/version of some sort.

---

## 11. lod0 / cockpit per-vertex post-pool stream (FH1-only)

**RE'd 2026-05-01.** `<car>_lod0.carbin` and `<car>_cockpit.carbin` body sections carry an additional `lod0VCount × 4` bytes after the §10 tail:

```
... [c*d table] [trailing 4..8]
    [lod0VCount × 4 bytes per-vertex stream]   ← packed signed int16 pairs
    [next section marker (or EOF / 24-byte file footer)]
```

### Byte signature

High bytes are 0xFE / 0xFF / 0x00 / 0x01 — small signed values around 0. Reading as 2× int16 BE per entry gives values in `[-512, 8]` typical range. Most likely:
- **D3DDECLTYPE_SHORT2N**: 2× int16 normalized to `[-1, 1]` — fits "tangent space packed" (compressed normal+tangent).
- **D3DDECLTYPE_DEC3N**: 3× 10-bit signed normalized + 2-bit padding = 4 bytes — common Xbox 360 normal format.

We round-trip the bytes verbatim; semantic decode is deferred (Phase 2c.4 or similar).

### Why the main carbin doesn't have it

Main-carbin sections have BOTH a LOD pool (mid-distance, lower-detail) AND a LOD0 pool (close, high-detail). The vertex stride is 28 bytes — the same in both pools — and the second tangent / paint data is encoded inline (in `extra8` at +0x14 of the vertex). For lod0 / cockpit carbins, sections have ONLY a LOD0 pool, and the stride is still 28 bytes — but the second-tangent stream is split out into a separate per-vertex array that follows the pool. Likely a memory-layout optimization (the lod0 pool is what the GPU streams at close camera; keeping the second-tangent data in a separate stream lets the GPU fetch them via separate vertex declarations).

### Detection in the parser

```nim
# parser.nim cvFive tail probe
let extraStream = int(lod0VCount) * 4
for extra in [extraStream, 0]:                    # WITH-stream wins when valid
  for tryOff in [0, 4, 8]:                        # trailing-byte tolerance
    let k = probeStart + extra + tryOff
    if k+40 > data.len: break
    if data[k..<k+4] == [0,0,0,5] and 9 sane floats follow:
      r.seek(k); snapped = true; break
  if snapped: break
if not snapped and lod0VCount > 0:
  r.seek(extraStream, 1)                          # last-section EOF case
```

Falsely matching the with-stream offset by chance is statistically implausible because vertex-data noise inside the LOD0 pool doesn't produce `[0 0 0 5][9 small floats]` at exactly the right alignment. Verified across 16 sample carbins (8 lod0 + 8 cockpit) — no false matches.

---

## 12. TypeId 1 — Caliper / Rotor Carbins

Per-corner brake carbins (`<car>_caliperLF_LOD0.carbin`, `<car>_rotorRR_LOD0.carbin`, etc.) are **TypeId 1 in both games**:

| Detector | Game |
|---|---|
| `first == 1 and second == 0x10` | FM4 |
| `first == 1 and second == 0x11` | FH1 |

Both routed to `cvFive` in `getVersion` for FH1. **Body parser path is the FM4 TypeId 1 prelude unchanged** — only the section-level `cvFive` deltas (§7) apply, including the LOD0 pre-pool `m_NumBoneWeights / perSectionId` block which for these sections is just `[u32 = 0]` (no `perSectionId`).

Caliper sections sit at small per-corner offsets in the carbin (`±0.005..0.009 X, ±0.133..0.158 Z`) — these are corner-relative pivot offsets meant to ride on top of the wheel hub at each of the 4 corners. Without explicit instancing, all 4 calipers stack at `(0, 0, 0)` and read as visual nonsense. Match by name suffix (`*lf`, `*rf`, `*lr`, `*rr`) for placement; see §17.

---

## 13. Stripped Carbins (TypeId 0)

Every part has a companion `stripped_*.carbin` (and `stripped_<car>.carbin` for the main). These are header-only stubs with `TypeId 0x00` at offset 0. Format unknown.

Round-trip via passthrough: the import unpacks them into `geometry/`, the byte-equal `.archive/source.zip` carries them through export. `isStripped` filters them out of glTF emit so they don't trip the parser.

`stripped_*` likely never worth re-implementing — they're presumably degenerate placeholders the engine streams as fallback during heavy memory pressure.

---

## 14. Section-count Catalog (8 sample cars)

| Car | FM4 main | FM4 lod0 | FM4 cockpit | FH1 main | FH1 lod0 | FH1 cockpit |
|---|--:|--:|--:|--:|--:|--:|
| ALF_8C_08 | 33 | 22 | 18 | 33 | 20 | 20 |
| AST_DB5Vantage_64 | 30 | 20 | 20 | 30 | 18 | 22 |
| AST_DBR1_58 | 24 | 15 | 13 | 24 | 13 | 15 |
| AST_One77_10 | 32 | 21 | 21 | 32 | 19 | 23 |
| AUD_TTRS_10 | 51 | 40 | 21 | 51 | 38 | 23 |
| BMW_M3E30_91 | 46 | 35 | 21 | 46 | 33 | 23 |
| BMW_M3E92_08 | 36 | 25 | 21 | 36 | 23 | 23 |
| CAD_CTSVcoupe_11 | 35 | 24 | 24 | 35 | 22 | 26 |

**Patterns**:
- **Main** carbins: section count is *stable* across both games. Same artist parts list.
- **lod0** carbins: FH1 drops *exactly 2* sections vs FM4. Likely simplified visual detail.
- **Cockpit** carbins: FH1 adds *exactly +2* sections. Consistent with FH1 packing more granular gauge-detail sections (`fuel_*`, `speed_*`, `tach_*` indicators in BMW M3 cockpit, etc.).

---

## 15. UV System & Material Resolution

### UV transform (no Y-flip in our bake)

The FM4 master spec'd `final.y = 1 - (raw.y * yScale + yOffset)`. Empirically that maps the FH1 steering wheel onto the Alfa-badge atlas region. **The carbin-stored UV values are already in glTF/DirectX top-left convention** — no Y-flip needed:

```
final.x = raw.x * xScale + xOffset
final.y = raw.y * yScale + yOffset      # NO Y-flip
```

Verified across both games on all 8 sample cars. The FM4-master Y-flip is wrong (an artifact of FM4-era OBJ exporter conventions, not the carbin-stored values).

### Procedural shaders (scale ≈ 0)

When `(xScale, yScale) ≈ (0, 0)` for a subsection, the shader is **procedural** (runtime tint, e.g. `bump_leather*`, `mottled`, `cloth`). Atlas-sampling produces one random pixel as a tint hint that's then ignored — emit a flat-color material instead:

```nim
# core/texture_map.nim
let degenerate = abs(ss.uvXScale) < 1e-5'f32 or abs(ss.uvYScale) < 1e-5'f32
if degenerate:
  # flat-color fallback
```

### Texture name resolution

Subsection names like `chrome`, `body`, `glass_red`, `bump_leather*` map to texture file basenames via `core/texture_map.nim`. The resolver tries longest-prefix-first matching against the available `<bucket>_LOD0.xds` files in the working dir (`damage_LOD0`, `nodamage_LOD0`, `interior_LOD0`, `lights_LOD0`, `zlights_LOD0` for FH1; FM4 omits the `_LOD0` suffix and lacks `zlights`). Authoritative `m_MaterialSets[]` parser is open RE.

---

## 16. Index Buffers (TriList / TriStrip)

| `indexType` | Value | Notes |
|---|---|---|
| TriList | 4 | Every 3 indices = one triangle |
| TriStrip | 6 | Triangle strip with restart sentinel: `0xFFFF` (i16) / `0xFFFFFFFF` (i32) |

TriStrip parity must reset on each restart sentinel. Without parity reset, body panels render with inverted-triangle splotches.

---

## 17. Wheel & Brake Instancing (post-emit)

The main-carbin and lod0-carbin both have a section named `wheel`. The game places it at four hub positions per-frame from physics state in `MAXData.xml`:

```nim
# importwc.nim
let halfWb = wheelbase * 0.5
let halfFt = frontTrack * 0.5
let halfRt = rearTrack * 0.5
let hubY = max(boundMaxY across all wheel meshes)
hubs = [
  [-halfFt, hubY, -halfWb],   # LF
  [+halfFt, hubY, -halfWb],   # RF
  [-halfRt, hubY, +halfWb],   # LR
  [+halfRt, hubY, +halfWb],   # RR
]
```

The hub Y is the wheel mesh's Y-radius so tire bottoms sit on `y=0` (ground reference per `Data_CarBody.BottomCenterWheelbasePos`). Front of car is at `-Z` (verified by `bumperFa` / `bumperRa` centers).

Calipers + rotors carry tiny corner-relative offsets (`±0.005..0.009 X, ±0.133..0.158 Z`) — they're meant to ride on the per-corner wheel hub position. Without explicit placement, all 4 calipers stack at origin. Match by name suffix:

```nim
# importwc.nim, post-emit instancing
proc cornerHub(name: string): int =
  let lc = name.toLowerAscii()
  if lc.endsWith("lf"): 0
  elif lc.endsWith("rf"): 1
  elif lc.endsWith("lr"): 2
  elif lc.endsWith("rr"): 3
  else: -1
# Apply hub translation to caliper/rotor mesh by suffix.
```

---

## 18. Practical FM4 → FH1 Port Recipe

Cross-game porting (e.g., taking ALF_8C_08 from FM4 and dropping it into FH1):

1. **TypeId**: rewrite `0x02 → 0x05` for main / lod0 / cockpit; `0x10 → 0x11` for caliper / rotor (in word[1]).
2. **Shared prelude (`0x000..0x0D3`)**: copy verbatim. The 4-record float anchors and 48-byte trailing zones are byte-identical between games for the same car.
3. **Expanded middle (`0x0D4..0x2D3` in FH1)**: synthesize from FM4's 47-word table at `0x0D4..0x18F`. **Mapping is non-trivial — the largest remaining RE gap.** Pragmatic substitute: use a donor FH1 carbin's middle table (Option C "hybrid donor splice" — see ROADMAP.md).
4. **Trailing fields (`0x190..0x397` FM4 → `0x2D4..0x4DB` FH1)**: copy verbatim; per-car float anchors hold across the +0x144 shift.
5. **Body sections** (per §7):
   - Bump section "version" `2 → 3`.
   - Insert `[u32 = m_NumBoneWeights][u32 = perSectionId?]` after `lodVSize` and (when applicable) before LOD0 pool. `m_NumBoneWeights = 1` for body; `0` for caliper/rotor/lod0/cockpit. `perSectionId` synthesis open — donor passthrough or monotonic counter.
   - Re-encode each LOD pool from 32-byte to 28-byte stride (drop UV1).
   - Bump each subsection's "version" `3 → 4` and insert `[u32 = 0]` before `idxCount`.
   - Tail: add 12 bytes (4 init, 4 reserved=1 between b and a*b table, 4 trailing); write `c=3, d=0` to match FH1 norm (or copy from donor).
6. **lod0 / cockpit only**: append `lod0VCount × 4` bytes of per-vertex normal/tangent stream after the tail. Synthesizing this from FM4's inline `extra8` field needs encoding RE.
7. **`physicsdefinition.bin`**: copy verbatim from a donor FH1 car of similar class. We do NOT synthesize physics bins — see `FH1_PHYSICSDEFINITION_BIN.md` §"Donor-bin strategy" and project memory `feedback_donor_passthrough.md`.
8. **Database (`gamedb.slt`)**: copy the donor's per-car row as the template; patch `MediaName` / `CarId` / similar identifying fields. FH1 has 9 extra columns vs FM4 in `Data_Car` (`OffRoadEnginePowerScale`, `IsRentable`, `IsSelectable`, `Specials`, etc.) plus an extra `E3Drivers` table. Schema migration handled in Phase 2b.
9. **Textures**: Phase 2c.3 (PNG → BC + Xenon retile + `.xds` rewrite) is open; cross-game `.xds` container compat (FM4 ↔ FH1) needs verification (probably interchangeable since both are Xbox 360 BC1/3/5).

---

## 19. Validation Strategy (Cross-game / New-car)

Per project memory `feedback_validation_strategy.md` — cross-game / new-car ports validate **structurally**, not byte-equal-vs-on-disk:

1. **Codec roundtrip stability** through OUR pipeline: byte-equal. ✓ Status: 100% on 8 sample cars × 3 carbin variants × 8 brake corners = 56 carbins per game. Both FM4 and FH1.
2. **Structural invariants**: output re-parses cleanly; section counts preserved; headers well-formed; vertex pools valid; indices in range; DB rows respect schema.
3. **Donor cross-check** on structural shape only: section counts match a donor of similar class; expected named sections present; `partCount` within healthy range; `m_NumBoneWeights` matches kind (1 for body, 0 for brakes/lod0/cockpit).
4. **In-game load test**: the only ground truth.

Bit-comparing a ported FM4 car's FH1 output against the existing on-disk FH1 version of the same car (e.g., ALF_8C_08 in both rosters) is **unreachable** — both games carry independently-authored art passes, mesh re-exports, and DB tunings. Don't aim for that bar.

---

## 20. Open RE Items

| Item | Severity | Notes |
|---|---|---|
| Expanded middle table (`0x0D4..0x2D3`) field semantics | **high** | 128 words, mostly zero. Z/C/V word classification at finer resolution would partition structural vs per-car data. Largest blocker for synthetic-from-scratch FH1 carbins. Donor passthrough is the workaround. |
| `perSectionId` semantics | medium | Non-zero, per-section unique. CRC? Pointer? Round-trip safe by passthrough; synthesis blocked on game-loader behavior. |
| Per-vertex stream encoding (lod0/cockpit) | medium | High bytes 0xFE/0xFF/0x00/0x01. SHORT2N? DEC3N? Verbatim round-trip OK; semantic decode pending. |
| `m_MaterialSets[]` parser | medium | Authoritative subsection→texture binding. Currently using a name-prefix heuristic; doesn't matter for byte-passthrough export but matters for "the game actually links to my edited texture". |
| Caliper/rotor quat encoding | low | First vertex's quat field has only the high pair populated (zeros at +12..15, real data at +16..19). Mesh shape correct; only normals read flat-shaded around Z. Possibly per-section base + per-vertex delta. |
| BMW M3E30 cockpit section 5 | low | A non-mesh section: list of u32 indices with `0x00FFFFFF` sentinels + "plastic"/"metal" string tokens. Likely wiper/decal metadata. 1/8 sample cockpits have it; parser skip-and-resume handles it. |
| FH1 stripped carbin format (`TypeId 0x00`) | low | Round-trip via passthrough. Format unknown; FM4 docs flag it as "downlevel". |
| Variable lod0/cockpit prelude length | low | Body start varies `0x57C..0x6E0`. Forward-scan handles it; field-classifying the prelude itself is a future cleanup. |
| Section tail trailing 4 vs 8 bytes | low | Predicate undecided. Parser uses forward-marker probe to disambiguate. |
| FH1 13-byte tail "init" classification | low | First 13 bytes of cvFive tail (vs FM4's 9). Mostly zero; first non-zero is usually `0x00000001`. Likely `m_HasTransparentMeshes` byte + padding, but not field-classified. |

---

## 21. Probes & Repro

```bash
# 1. Extract paired sample carbins for the 8 cars (main + lod0 + cockpit)
python3 probe/extract_carbin_lod_pairs.py
#   → probe/out/carbin_typeid5/{fm4,fh1}_<car>.carbin
#   → probe/out/carbin_lod0/{fm4,fh1}_<car>.carbin
#   → probe/out/carbin_cockpit/{fm4,fh1}_<car>.carbin

# 2. Header-zone Z/C/V word classification (main carbin only)
python3 probe/probe_typeid5_layout.py

# 3. Body deltas (sections, subsections, tail) — by variant
python3 probe/probe_fh1_section_diff.py --variant=main      # main
python3 probe/probe_fh1_section_diff.py --variant=lod0      # lod0
python3 probe/probe_fh1_section_diff.py --variant=cockpit   # cockpit

# 4. Section-by-section walk on a single FH1 lod0/cockpit (the RE workhorse)
python3 probe/probe_fh1_lod_walk.py lod0 alf_8c_08
python3 probe/probe_fh1_lod_walk.py cockpit bmw_m3e30_91

# 5. Nim parser dump (matches the production read path)
./probe/nim_parse_dump.bin probe/out/carbin_lod0/fh1_alf_8c_08.carbin

# 6. Roundtrip verification (the empirical ground truth)
./build/carbin-garage roundtrip <FH1_zip> --profile fh1
./build/carbin-garage roundtrip <FM4_zip>
# OK = byte-equal across our import → export pipeline.
```

All 8 paired sample cars × both games × all 3 carbin variants currently report `roundtrip OK`.

### Sample carbin pairs

`probe/out/carbin_typeid5/`, `probe/out/carbin_lod0/`, `probe/out/carbin_cockpit/` — each holding paired `fm4_<car>.carbin` and `fh1_<car>.carbin` for:
- alf_8c_08, ast_db5vantage_64, ast_dbr1_58, ast_one77_10
- aud_ttrs_10, bmw_m3e30_91, bmw_m3e92_08, cad_ctsvcoupe_11

### Game folders (mounted)

- FM4: `/run/media/paths/SSS-Games/fm4-xex/4D530910/00007000/33E7B39F/Media/cars/<CAR>.zip`
- FH1: `/run/media/paths/SSS-Games/fh1-xex/4D5309C9/00007000/2DC7007B/media/cars/<CAR>.zip`

Mount via `./build/carbin-garage mount <game-folder>` to register in `~/.config/carbin-garage/mounts.json` for use with `export-to <working-car> <game-id>`.
