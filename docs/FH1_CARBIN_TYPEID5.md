# FH1 carbin TypeId 5 — Layout Notes

The existing FM4 docs cover TypeId 1, 2, and 3. **TypeId 5 is the FH1
variant, undocumented before this file.** Reverse-engineered by aligning
8 main-carbin pairs across FM4 and FH1
(`probe/probe_typeid5_layout.py` for the header,
`probe/probe_fh1_section_diff.py` for the body deltas in §5–§7).
Findings cover everything the parser needs to read a TypeId 5 carbin
section-by-section. **The body parse-order matches FM4 TypeId 3** with
five precise deltas, all keyed off the section / subsection "version"
field bumping `2 → 3` in FH1.

## Top-level shape

| Zone | TypeId 2 (FM4) | TypeId 5 (FH1) | Relationship |
|---|---|---|---|
| **Prelude** | `0x000..0x0D3` (212 B) | `0x000..0x0D3` (212 B) | **Identical layout & values.** Same offsets carry the same data for the same car in both games. |
| **Middle (offset table)** | `0x0D4..0x18F` (188 B / 47 words) | `0x0D4..0x2D3` (512 B / 128 words) | TypeId 5 is **+324 B (+0x144 / +81 words)** in this zone. The format was rewritten — it's not a sub-shift. |
| **Trailing fields** | `0x190..0x397` (520 B) | `0x2D4..0x4DB` (520 B) | **Identical layout, shifted by +0x144 bytes.** Per-car float anchors at FM4 0x190..0x23C ↔ FH1 0x2D4..0x380 confirm the alignment for all 8 sample cars. |
| **Body** | starts `0x398` | starts `0x4DC` | First post-header bytes are byte-identical: `00000000 3f800000 00000000 00000000 ...` Strongly suggests body parse-order is unchanged. |

Total header: TypeId 2 = 0x398 bytes; TypeId 5 = 0x4DC bytes (= 0x398 + 0x144).

## Word 0 — TypeId

`uint32 BE` at offset 0. Distinguishes formats:

| Value | Where seen |
|---|---|
| 0 | Stripped/downlevel carbins (per existing FM4 docs §1) |
| 1 | FM2 (per existing docs) |
| 2 | **FM4** main + LOD0 + cockpit + caliper + rotor carbins |
| 3 | FM4 (alternative TypeId per docs) |
| 5 | **FH1** main + LOD0 + cockpit + caliper + rotor carbins |

## The shared prelude (`0x00..0xD3`) — what it actually holds

Word 0 is TypeId. Then a repeating 4-float record every 64 bytes:

| Offset | Field |
|---|---|
| `0x04..0x13` | record 0 — 4 floats (BE) |
| `0x14..0x43` | 48 B of trailing data (mostly zero, a few constants/offsets) |
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

The X/Y values cluster near `±half-track / wheelbase-related` magnitudes
but **don't match `maxdata.xml`'s `Wheelbase / FrontTrackOuter / RearTrackOuter`
exactly** — these are refined per-record positions, not raw track widths.
Best current hypothesis: per-wheel anchor / pivot points (FL, FR, RL, RR).
Needs cross-referencing against more cars + the corresponding rows in
`gamedb.slt`'s `Data_CarBody` to nail down the exact semantics.

The 48 trailing bytes between records carry repeating float-prefix bytes
(`0x3f`, `0xbe`, `0x3e` — i.e. more floats around 0..1 magnitude),
small-int magic values (`0x01`, `0x10`, `0x02`, `0xffffffff`), and
**byte offsets into the carbin file** (e.g. `0x18f444`, `0x18f5c4`,
`0x18f55c`, `0x18f574`, `0x18f58c`, `0x18f59c`, `0x18f5d0`, `0x18f5d8`,
`0x18f554` — clustered ~80% through the file). These are almost
certainly an offset table pointing to LOD/section payloads. The
recurring `0x18f5XX` family suggests they're offsets into a single
trailing section (LOD0 vertices? FM4 tail table?).

## The expanded middle (`0xD4..0x2D3` in FH1)

This is the **only** region where TypeId 5 genuinely differs in layout.
FM4 packs 47 words here; FH1 packs 128 words. Field-by-field correspondence
isn't a simple insertion — sliding a 324-byte hole between any two
4-byte boundaries doesn't reproduce FM4 from FH1, so the table was
re-formatted, not just extended.

For `ALF_8C_08`, FH1's middle is mostly zeros with a small cluster of
non-zero floats at FH1 `0x???..0x???` (TBD: precise sub-locations within
this expanded region need their own classification pass). Plausible
contents: extra LOD entries (FH1 may keep more LODs), additional
section pointers, Horizon-specific anchor points, or per-physics-zone
attachments.

## The trailing region (`0x190..0x397` FM4 = `0x2D4..0x4DB` FH1)

**Identical layout, shifted by +0x144.** Confirmed by these per-car
float anchors that match across all 8 sample cars at the +0x144 shift:

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

Within this region, FM4 has documented offsets in §17 of the master doc
(carbin.bt template analysis); the same fields apply to TypeId 5 at
+0x144.

## Body (`0x398+` FM4 = `0x4DC+` FH1)

First 32 bytes immediately after each header are byte-identical between
the two games for the same car:
`00000000 3f800000 00000000 00000000 00000000 3f800000 00000000 00000000`
(two rows of `[0.0, 1.0, 0.0, 0.0]` — looks like a 4×3 transform prelude,
or two 4-float vectors with a "1.0 in slot 1" pattern).

The post-header parse-order **matches FM4 TypeId 2** (not TypeId 3) once
the body-relative offsets are shifted by `+0x144` to follow the longer
FH1 header. Verified by running the FM4 TypeId 2 prelude (`unk1` at
+0x15C → fixed `unk1 * 0x8C` skip → `0x340` skip → `unkCount × 2` skip
loop → `partCount`) on real FH1 samples and recovering the correct
section count (matches the FM4 sibling for shared cars).

The expanded middle (`0xD4..0x2D3`) does NOT preserve field offsets —
some FH1 cars need the prelude to be located by a forward scan for the
`[partCount in 1..255][marker = 5][9 sane floats]` signature. The fixed
prelude works for ~half of the 8-car sample; the scan handles the rest.

## §5 — Section deltas (TypeId 5 vs FM4 TypeId 2/3)

Reverse-engineered by `probe/probe_fh1_section_diff.py` across 8 paired
main carbins (266 paired sections, 3,108 paired subsections). Each delta
is keyed off a single per-section "version" word that bumps **2 → 3**
in FH1 (100% of paired sections).

### Section header insert: +8 bytes after `lodVSize`

| Field | Bytes | Value |
|---|---|---|
| `m_NumBoneWeights` (per master docs §"version >= 3") | u32 BE | **`1`** in main / lod0 / cockpit body sections; **`0`** in caliper / rotor sections |
| Per-section ID / hash (?) | u32 BE | only present when `m_NumBoneWeights != 0`; varies; high byte often `0x80..0xFF`, low bits look pseudo-random |

The 4-byte per-section ID is **non-zero and per-section unique** within
a car. Likely a CRC, a node-tag, or a pointer into the expanded middle
table. Round-trip note: must be preserved verbatim.

**Critical: this block also precedes the LOD0 pool, not just the LOD
pool.** Body sections (with both LOD and LOD0 pools, `m_NumBoneWeights = 1`)
read it once before each pool — 8 bytes pre-LOD, 8 bytes pre-LOD0.
Caliper / rotor sections (LOD0-only, `m_NumBoneWeights = 0`) read it
once before LOD0 (just the 4-byte zero `m_NumBoneWeights`, no
`perSectionId`). Discovered 2026-05-01 when caliper meshes scrambled in
the FH1 glTF — pos was being read 8 bytes early because the parser
only handled the pre-LOD copy of this block. Fix: mirror the
`m_NumBoneWeights / perSectionId` read into the LOD0 pre-pool path in
`parseSection` (`cvFive` branch).

### Subsection prefix insert: +4 bytes before `idxCount`

| Field | Bytes | Value |
|---|---|---|
| Reserved / version-3 padding | u32 BE | **always `0`** in 3,108 paired subsections |

This is a `[u32 = 0]` inserted between the previously-`r.seek(4, 1)`
skip in the FM4 parser and the `idxCount` read. Equivalent to bumping
the skip from 4 to 8.

### Section "version" field after name

```
section header   +0 marker u32 (2 or 5)
                 +4 9 floats (offset, min, max)
                ...
                ... `r.seek(12, 1)` (FM4-docs §m_NumBoneWeights area)
nameLen (u8) + name bytes
**version u32**: FM4 = 2, FH1 = 3   (100% in sample)
lodVCount, lodVSize
[FH1 only: m_NumBoneWeights u32, perSectionId u32]
LOD pool bytes
```

### LOD pool: 28-byte vertex stride (vs FM4's 32)

**Corrected 2026-05-01.** Earlier RE inferred from stride math that FH1
"drops UV1" — wrong. Byte-level cross-game comparison
(`probe/nim_vertex_byte_diff.nim`, 8 paired cars × multiple body
sections, 3000+ matched vertices) shows `FH1 [0..24) == FM4 [0..24)`
byte-equal in every case. FH1 KEEPS UV1; the 4-byte loss is at the END
(extra8 → extra4):

| Offset | Size | Field |
|---|---|---|
| 0x00 | 8 B | Position (`int16 × 4`, ShortN x/y/z + scale) — same as FM4 |
| 0x08 | 4 B | UV0 (`uint16 × 2`, UShortN) — same as FM4 |
| 0x0C | 4 B | **UV1** (`uint16 × 2`, UShortN) — same as FM4 |
| 0x10 | 8 B | Quaternion (`int16 × 4`, ShortN) — same offset as FM4 |
| 0x18 | 4 B | extra4 — FM4 has 8 B here (extra8); FH1 truncates to 4. Byte 0 ~70% matches FM4's extra8[0]; bytes 1..3 are re-baked |

The LOD0 pool follows the same rule: stride determined by
`lod0VerticesSize`, decoded with the matching table.

The Phase-2a "caliper quat partial encoding" mystery (high pair carries
data, low pair zero) was an artifact of the wrong layout — calipers
have UV1 = 0 because they don't sample texture, and the wrong decoder
read those zero UV1 bytes as the quat low half. Real quat at 0x10 has
full data.

### Subsection "version" field after name

Mirror of the section version: FM4 `[u32 = 3]`, FH1 `[u32 = 4][u32 = 0]`
(observed at +0xA0 from subsection start, before `idxCount`).

## §6 — Section tail layout

Both games share the same skeleton; FH1 adds 12 fixed bytes (matched
~99/103 most-common case) plus a populated second table:

```
FM4: [9 init][a u32][b u32][a*b table][4 mid-skip][c u32][d u32][c*d table]
     fixed = 29 B
FH1: [13 init][a u32][b u32][4 reserved=1][a*b table][4 mid-skip][c u32][d u32][c*d table][trailing 4 B or 8 B]
     fixed = 41 B (when c=0, d=0)
```

- **a, b**: same per-section values in both games (per-vertex damage
  table dimensions; `a` = main-pool vertex count, `b` = 4 bytes per
  entry).
- **c, d** in FM4: always `(0, 0)` in our sample → FM4 leaves the second
  table empty.
- **c, d** in FH1: `(0, 0)` in 99 sections, `(3, 0)` in 157 sections
  (out of 256 paired). Often `(3, 0)` → `c*d = 0` regardless. The `c`
  value isn't always zero, but `d` is always zero → second table is
  effectively empty data-wise but the `[c u32][d u32]` header is
  retained.
- Some sections show additional padding before / after the second-table
  header (variable trailing 4 vs 8 bytes); not yet fully nailed down,
  but doesn't block the parse — the next section's marker is byte-found
  forward.

## §6.5 — `<car>_lod0.carbin` and `<car>_cockpit.carbin` (the high-detail siblings)

**RE'd 2026-05-01** — these were the last big gap in the FH1 mesh
pipeline. With the deltas below, all 8 paired `_lod0.carbin` and 7/8
paired `_cockpit.carbin` now byte-equal roundtrip.

### Prelude (header zone)

The shared 0x4DC prelude is **flattened** in lod0 and cockpit carbins:
words 1–5 (the per-car float records the main carbin carries at
`0x04..0x13`) are zero across all 8 paired samples. The prelude length
itself is **variable** — it's not at the fixed `0x4DC` body boundary the
main carbin uses. Body starts vary between `0x57C` and `0x6E0`. The
forward-scan (`[u32 in 1..255][marker = 5][9 sane floats]`) handles the
variability cleanly.

### Section layout (body)

Section *header* bytes are **identical** to the main carbin's `cvFive`
layout (same 9 floats, same name, same version=3, same +8
`m_NumBoneWeights/perSectionId`). lod0/cockpit body sections always
have `m_NumBoneWeights == 0` (lod0/cockpit are static streams without
skinning) → only the 4-byte zero `m_NumBoneWeights` is present, no
`perSectionId`. This matches the caliper/rotor convention.

### The post-pool per-vertex stream (the missing piece)

After the `c*d` table in §6's tail, lod0 and cockpit sections carry an
**additional `lod0_v_count * 4` bytes** that the main carbin doesn't.
The bytes look like packed signed int16 pairs (high bytes 0xfe / 0xff
/ 0x00 / 0x01) — most likely `D3DDECLTYPE_SHORT2N` normals or
`DEC3N`-packed tangent space. Layout:

```
... [c u32][d u32][c*d table]                              ← FH1 §6 tail
    [lod0_v_count × 4 bytes per-vertex normal/tangent stream]   ← lod0/cockpit only
    [next section marker]
```

Detection in the parser: after the §6 tail, probe for the next-section
marker at both `+0` and `+(lod0_v_count*4)` offsets, with the +/-4/+8
trailing-byte tolerance. The with-stream candidate wins when valid;
falsely matching the with-stream offset by chance is statistically
implausible because vertex-data noise inside the LOD0 pool doesn't
produce `[0 0 0 5][9 small floats]` at exactly the right alignment.

This stream is **only** in lod0 and cockpit carbins. The main carbin's
sections have neither this stream nor the `(c=4, d=1)` "1 entry of 4
bytes" header that lod0 sections often carry — main-carbin tail
parses cleanly without modification.

### Section count deltas vs FM4

| Sample (across 8 paired carbins) | FM4 lod0 → FH1 lod0 | FM4 cockpit → FH1 cockpit |
|---|---|---|
| ALF_8C_08 | 22 → 20 | 18 → 20 (+2) |
| AST_DB5Vantage | 20 → 18 | 20 → 22 (+2) |
| AST_DBR1_58 | 15 → 13 | 13 → 15 (+2) |
| AST_One77_10 | 21 → 19 | 21 → 23 (+2) |
| AUD_TTRS | 40 → 38 | 21 → 23 (+2) |
| BMW_M3E30 | 35 → 33 | 21 → 23 (+2) |
| BMW_M3E92 | 25 → 23 | 21 → 23 (+2) |
| CAD_CTSV | 24 → 22 | 24 → 26 (+2) |

**Pattern**: FH1 lod0 carbins consistently drop ~2 sections from FM4
(simplification?). FH1 cockpit carbins consistently add **exactly +2
sections** — likely the gauge-detail sections (more granular `fuel_*`,
`speed_*`, `tach_*` indicators).

### Open lod0/cockpit RE items

- **Per-vertex stream encoding**: byte values look like SHORT2N or
  DEC3N packed normals/tangents; exact layout untested. We round-trip
  the bytes verbatim for now.
- **BMW M3 cockpit section 5**: a *non-mesh* section (no 9-float
  prelude — starts with a list of u32 indices separated by
  `0x00FFFFFF` sentinels and contains "plastic" / "metal" string
  tokens). Likely a wiper / decal / strip-attachment metadata block.
  The parser's skip-and-resume handles it; semantically opaque. 1/8
  cockpit carbins have it; the rest parse 100%.
- **Variable prelude length**: lod0/cockpit prelude is variable
  (`0x57C..0x6E0` across 16 sample files). The forward partCount scan
  handles it, but the prelude itself is not field-classified yet.

## §7 — TypeId 1 caliper / rotor carbins

Per-corner brake carbins (`<car>_caliperLF_LOD0.carbin` etc.) are
**TypeId 1 in both games**. FM4 detects them via `(first == 1 and
second == 0x10)`. FH1 uses `(first == 1 and second == 0x11)`, both
routed to `cvFive` in `getVersion`. Body parser path is the FM4 TypeId
1 prelude unchanged — only the section-level `cvFive` deltas apply
(§5 above), including the LOD0 pre-pool `m_NumBoneWeights / perSectionId`
block which for these sections is just `[u32 = 0]`.

## Practical implications for porting

For an FM4→FH1 carbin port, the format change is **not catastrophic**:

1. Rewrite `TypeId` word: `0x02 → 0x05`.
2. Copy bytes `0x00..0xD3` verbatim.
3. Synthesize the new 128-word middle table at `0xD4..0x2D3` from FM4's
   47-word table at `0xD4..0x18F`. The mapping isn't trivial — needs
   per-field decoding of the FH1 middle layout. Largest remaining gap.
4. Copy bytes FM4 `0x190..0x397` to FH1 `0x2D4..0x4DB` verbatim.
5. **Body**: walk each section, apply the §5 deltas:
   - Bump section "version" 2 → 3.
   - Insert `[u32 = 1][u32 = perSectionId]` after `lodVSize`. The
     `perSectionId` needs synthesis — best current guess is to use the
     same value the donor FH1 carbin had for the matching section name,
     or generate a small monotonic counter (game-loader behaviour
     unknown).
   - Re-encode each LOD pool from 32-byte to 28-byte stride (drop UV1).
   - Bump each subsection's "version" 3 → 4 and insert `[u32 = 0]`
     before `idxCount`.
   - Tail: add 12 bytes (4 init, 4 reserved=1 between b and table, 4
     trailing); if needed, write `c=3, d=0` to match the FH1 norm.

## Open questions

1. **`perSectionId` semantics**. Pseudo-random? Hash of geometry?
   Pointer? Round-trip safe by passthrough; semantically unknown.
2. **Field semantics of the 4-float records in §"shared prelude"**.
   Wheels? Bone anchors? Convex-hull pivots? Correlate against
   `Data_CarBody.BottomCenterWheelbasePos*` and per-wheel positions in
   the SQLite DB.
3. **Per-field layout of the FH1 expanded middle (`0xD4..0x2D3`)**. Same
   word-classification technique (Z/C/V) at finer resolution will
   partition the 128 words into structural vs per-car data.
4. **Stripped carbin counterpart.** FH1 ships `stripped_*.carbin`
   companions for every part. Format unknown; existing FM4 docs flag
   them as "TypeId 0x00 / downlevel" (§1, master).
5. **Section tail trailing 4 vs 8 bytes**. Most sections trail with 4
   zero bytes; some with 8. Predicate undecided; parser uses a
   forward-marker probe to disambiguate.
6. **FH1 quat encoding for caliper sections**. The 8-byte quat field
   at vertex offset 12..19 has only the high pair populated for the
   first vertex (zeros at 12..15, real data at 16..19). Mesh shape is
   correct after the LOD0 pre-pool fix; only normals are off (lighting
   reads as flat-shaded around Z). Possibly a per-section base quat +
   per-vertex delta encoding.

## Repro

```
# Extract main carbins for the 8 sample cars (header-zone classification)
python3 probe/probe_typeid5_layout.py
# Output: probe/out/typeid5_layout.txt
# Sample carbins land in probe/out/carbin_typeid5/

# Body deltas (sections, subsections, tail) — needs the carbin pairs
# extracted by the script above:
python3 probe/probe_fh1_section_diff.py
# Aggregates: section/subsection/tail length deltas; section "version"
# field; FH1 +8-bytes-after-lodVSize values; FH1 +4-bytes-before-
# idxCount values; FH1 tail decomposition by hypothesis.
```

Both probes are self-contained Python (depend only on
`probe/reference/fm4carbin/` for the FM4-side parse).
