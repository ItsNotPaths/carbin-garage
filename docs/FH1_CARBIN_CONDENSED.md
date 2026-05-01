# FH1 .carbin Modding — Condensed Master Reference

**Project:** Forza Horizon 1 (FH1) car-archive modding pipeline (carbin-garage)
**Tool:** carbin-garage (Nim port of Soulbrix's FM4 parser, extended for FH1)
**Authority:** Reverse-engineered from 8 paired FM4↔FH1 sample cars; cross-referenced against `FM4_CARBIN_MASTER.md` for the FM4-side structure.
**Scope:** Xbox 360 Forza Horizon 1 (TypeId 5) — main + lod0 + cockpit + caliper + rotor carbins
**Status:** Read pipeline complete (byte-equal roundtrip on all 8 sample cars × 3 carbin variants × 8 brake corners). Write pipeline is donor-passthrough until Phase 2b.

> **Companion docs:**
> - `FM4_CARBIN_CONDENSED.md` / `FM4_CARBIN_MASTER.md` — FM4 (TypeId 2) baseline
> - `FH1_CARBIN_TYPEID5.md` — RE narrative + open questions
> - `FH1_CARBIN_MASTER.md` — full byte-level layout reference (this doc's expanded sibling)

---

## 1. Version Detection & TypeIds

FH1 sniff order, applied in `getVersion`:

| First u32 | Second u32 | Decision |
|---|---|---|
| 5 | * | **TypeId 5** = FH1 main / lod0 / cockpit body carbin (`cvFive`) |
| 1 | 0x11 | **TypeId 1** = FH1 caliper / rotor LOD0 carbin (`cvFive`, body parser branches on TypeId) |
| 1 | 0x10 | TypeId 1 = **FM4** caliper / rotor (`cvFour`) |
| 2 | * | TypeId 2 = **FM4** main / lod0 / cockpit (`cvFour`) |
| 0 | * | Stripped / downlevel (`stripped_*.carbin` companions) — opaque |

The `0x10 → 0x11` second-word delta on TypeId 1 is the only way to distinguish FH1 brakes from FM4 brakes — the body parse path is otherwise FM4's TypeId 1 prelude unchanged, with `cvFive` section-level deltas.

---

## 2. Top-level Header Shape

| Zone | TypeId 2 (FM4) | TypeId 5 (FH1) | Relationship |
|---|---|---|---|
| **Prelude** | `0x000..0x0D3` (212 B) | `0x000..0x0D3` (212 B) | **Identical layout & values.** Same offsets carry the same data for the same car in both games. |
| **Middle (offset table)** | `0x0D4..0x18F` (188 B / 47 words) | `0x0D4..0x2D3` (512 B / 128 words) | TypeId 5 is **+324 B (+0x144 / +81 words)** in this zone. The format was rewritten — it's not a sub-shift. |
| **Trailing fields** | `0x190..0x397` (520 B) | `0x2D4..0x4DB` (520 B) | **Identical layout, shifted by +0x144 bytes.** |
| **Body** | starts `0x398` | starts `0x4DC` (main only) | First post-header bytes are byte-identical: `00000000 3f800000 00000000 00000000 ...` |

Total header: TypeId 2 = `0x398`; TypeId 5 main = `0x4DC` (= `0x398 + 0x144`).
**`<car>_lod0.carbin` and `<car>_cockpit.carbin` have a *flattened, variable-length* prelude** — body starts vary `0x57C..0x6E0` across the 8-car sample. Words 1–5 of the prelude are zero. Forward-scan `[u32 in 1..255][marker = 5][9 sane floats]` is the robust way to find `partCount` for all three variants.

**Stripped carbins**: every part has a companion `stripped_*.carbin` with `TypeId 0x00`. Format unknown; round-trip via passthrough.

---

## 3. Section "version" delta (cvFive)

The single most-load-bearing delta: a 4-byte u32 after each section's name (`r.seek(4, 1)` in the FM4 oracle) bumps **2 → 3** in FH1, gating four downstream changes:

1. **+8 bytes after `lodVSize`**: `m_NumBoneWeights u32` + (conditional) `perSectionId u32`.
2. **+4 bytes before each subsection's `idxCount`**: a `u32 = 0` reserved/padding word.
3. **Vertex stride 0x20 → 0x1C** (UV1 dropped) — see §5.
4. **Tail layout +12 bytes** + populated 2nd table — see §6.

For lod0 / cockpit only: a **per-vertex 4-byte stream after the tail** — see §7.

---

## 4. Section header layout (cvFive)

```
section_start
    +0  marker u32  (always 2 or 5; 5 in cvFive)
    +4  9 floats: offset.xyz, targetMin.xyz, targetMax.xyz   (BE)
    +0x28  28 bytes (m_Mass / m_CenterOfMass / m_DetachDamage / m_GlassParticles area)
    +0x44  permCount u32
    +     permCount * 16 bytes  (per-permutation block)
    +     4-byte skip
    +     cnt2 u32                (typically 0 in our sample)
    +     cnt2 * 2 bytes
    +     12-byte skip
    +     nameLen u8 + name bytes
    +     version u32   ← FM4 = 2, FH1 = 3 (the cvFive marker)
    +     lodVCount u32
    +     lodVSize u32
    +     ─── cvFive +8 insert ──────────────────────────────
    +       m_NumBoneWeights u32        ← 1 in body sections, 0 in caliper / rotor / lod0 / cockpit
    +       perSectionId u32  (only present when m_NumBoneWeights != 0)
    +     ───────────────────────────────────────────────────
    +     LOD pool: lodVCount × lodVSize bytes
    +     4-byte skip
    +     subpartCount u32
    +     subpartCount × subsection bytes  (see §8)
    +     4-byte skip
    +     lod0VCount i32
    +     lod0VSize u32
    +     ─── cvFive +8 insert (only if lod0V > 0) ──────────
    +       m_NumBoneWeights u32        ← second copy, before LOD0 pool
    +       perSectionId u32  (only present when m_NumBoneWeights != 0)
    +     ───────────────────────────────────────────────────
    +     LOD0 pool: lod0VCount × lod0VSize bytes
    +     [tail — see §6]
    +     [post-tail per-vertex stream — see §7, lod0/cockpit only]
section_end
```

**Critical**: the `m_NumBoneWeights / perSectionId` block precedes **both** the LOD pool *and* the LOD0 pool. Caliper / rotor sections and lod0/cockpit body sections only have a LOD0 pool — missing the pre-LOD0 copy of this block reads the first vertex's position from the bone-weight bytes (mesh scrambles).

---

## 5. Vertex Format (28 bytes — TypeId 5, cvFive)

| Offset | Size | Field | Decode | Delta from FM4 |
|--------|------|-------|--------|----|
| 0x00 | 8 B | Position | 4× int16 (x, y, z, scale). `ShortN(v) = v / 32767.0`. Final: `(x*s, y*s, z*s)` | same as FM4 |
| 0x08 | 4 B | UV0 | 2× uint16. `UShortN(v) = v / 65535.0` | same as FM4 |
| 0x0C | 8 B | Quaternion (normal/tangent) | 4× int16 ShortN | shifted from 0x10 in FM4 |
| 0x14 | 8 B | extra8 | opaque, round-trip verbatim | shifted from 0x18 in FM4 |
| ~~0x08~~ | ~~4 B~~ | ~~UV1~~ | **dropped in FH1** | UV2 is gone |

`decodeVertex28` lives in `core/carbin/vertex.nim`. For the LOD0 pool of lod0 / cockpit carbins, see also §7's per-vertex stream — likely the second tangent / normal carrier that's bundled inline in FM4's 0x20 stride.

### UV transform (no Y-flip in our bake)

The FM4 master doc spec'd `final.y = 1 - (raw.y * yScale + yOffset)`. Empirically that lands the FH1 steering wheel on the Alfa-badge atlas region. **Don't Y-flip on FH1 bake**:

```
final.x = raw.x * xScale + xOffset
final.y = raw.y * yScale + yOffset      # NO Y-flip
```

`scale ≈ 0` ⇒ procedural shader (runtime tint, e.g. `bump_leather*`, `mottled`, `cloth`) — fall back to flat-color material; do not sample atlas.

---

## 6. Section Tail (cvFive, +12 B vs FM4)

```
FM4: [9 init][a u32][b u32][a*b table][4 mid-skip][c u32][d u32][c*d table]
     fixed = 29 B
FH1: [13 init][a u32][b u32][4 reserved=1][a*b table][4 mid-skip][c u32][d u32][c*d table][trailing 4 B or 8 B]
     fixed = 41 B (when c*d = 0)
```

- `a` = main-pool vertex count (= `lodVCount`); `b` = 4 bytes per entry → `a * b` = the per-vertex damage/LOD-remap table.
- `c, d`: in FM4 always `(0, 0)`; in FH1 most often `(0, 0)` (no body damage) or `(3, 0)` / `(4, 1)` / `(0, 4, 1)`. Effective `c * d` is small (≤ 4 bytes) but the `[c][d]` header is always retained.
- Trailing 4 vs 8 bytes is undecided; the parser disambiguates by probing for the next-section marker at `+0/+4/+8` from the end of `c*d`.

---

## 7. lod0 / cockpit per-vertex post-pool stream (FH1-only, +`lod0VCount × 4` B)

**Newly RE'd (2026-05-01).** `<car>_lod0.carbin` and `<car>_cockpit.carbin` body sections carry an additional `lod0VCount × 4` bytes after the §6 tail:

```
... [c*d table] [trailing 4..8]
    [lod0VCount × 4 bytes per-vertex stream]   ← packed signed int16 pairs
    [next section marker (or EOF / 24-byte file footer)]
```

Byte signature: high bytes 0xFE / 0xFF / 0x00 / 0x01 (small signed values around 0). Most likely **D3DDECLTYPE_SHORT2N normals** or **DEC3N** packed tangent space. We round-trip the bytes verbatim; semantic decode is deferred.

The main carbin's body sections do NOT have this stream — their LOD pool absorbs equivalent data inline in the 28-byte stride. lod0/cockpit appear to split it out into a separate stream for memory-layout reasons (the LOD0 pool is the high-detail mesh streamed at close camera).

Detection in the parser: probe for the next-section marker at both `+0` and `+(lod0VCount * 4)` offsets, with `±0/+4/+8` trailing tolerance. With-stream wins when valid (no FH1 main carbin produces a false match because `[0 0 0 5][9 sane floats]` doesn't appear at exactly `+(lod0VCount * 4)` from a tail end by chance).

---

## 8. Subsection Layout (cvFive, +4 B vs FM4)

```
subsection_start
    +0  5 bytes skip
    +5  8 floats: m_UVOffsetScale (UV0 + UV1 scale & offset)
    +0x25  36 bytes skip
    +0x49  nameLen i32 (length-32 prefix; FM4 oracle reads as u32 BE)
    +     name bytes
    +     lod i32        (0 = LOD0, 1..4 = LOD1..4)
    +     indexType u32  (4 = TriList, 6 = TriStrip)
    +     6 floats (24 B)
    +     8 floats (32 B)
    +     ─── cvFive +8 (FM4 was +4) ─────────────────────
    +       reserved u32 = 0   ← the cvFive padding
    +       (FM4's 4 bytes here)
    +     ────────────────────────────────────────────────
    +     idxCount i32
    +     idxSize i32  (2 or 4)
    +     idxCount × idxSize bytes (index buffer)
    +     4-byte tail skip
subsection_end
```

The subsection "version" field after name is FM4 `[u32 = 3]`, FH1 `[u32 = 4][u32 = 0]` (observed at `+0xA0` from subsection start, before `idxCount`).

---

## 9. Index Buffers

| IndexType | Value | Notes |
|---|---|---|
| TriList | 4 | Every 3 indices = one triangle |
| TriStrip | 6 | Triangle strip with `0xFFFF` (i16) / `0xFFFFFFFF` (i32) restart sentinel |

TriStrip parity must reset on each restart. Without parity reset, body panels render with inverted-triangle splotches.

---

## 10. Section-count deltas vs FM4 (8 sample cars)

| Car | FM4 main → FH1 main | FM4 lod0 → FH1 lod0 | FM4 cockpit → FH1 cockpit |
|---|---|---|---|
| ALF_8C_08 | 33 → 33 | 22 → 20 | 18 → 20 |
| AST_DB5Vantage_64 | 30 → 30 | 20 → 18 | 20 → 22 |
| AST_DBR1_58 | 24 → 24 | 15 → 13 | 13 → 15 |
| AST_One77_10 | 32 → 32 | 21 → 19 | 21 → 23 |
| AUD_TTRS_10 | 51 → 51 | 40 → 38 | 21 → 23 |
| BMW_M3E30_91 | 46 → 46 | 35 → 33 | 21 → 23 |
| BMW_M3E92_08 | 36 → 36 | 25 → 23 | 21 → 23 |
| CAD_CTSVcoupe_11 | 35 → 35 | 24 → 22 | 24 → 26 |

**Patterns**:
- Main carbins: section count is **stable** across both games. Same artist parts list.
- lod0 carbins: FH1 drops ~2 sections vs FM4 (visual-detail simplification).
- Cockpit carbins: FH1 adds **+2 sections** consistently (likely additional gauge-detail granularity — `fuel_*`, `speed_*`, `tach_*`).

---

## 11. Practical implications for FM4 → FH1 porting

1. Rewrite TypeId word: `0x02 → 0x05`.
2. Copy bytes `0x00..0xD3` verbatim (shared prelude is byte-identical).
3. Synthesize the new 128-word middle table at `0xD4..0x2D3` from FM4's 47-word table at `0xD4..0x18F`. **Mapping is non-trivial — largest remaining gap.** Donor template (= an existing FH1 carbin of a similar car) is the pragmatic substitute (Option C "hybrid donor splice" — see ROADMAP.md).
4. Copy bytes FM4 `0x190..0x397` to FH1 `0x2D4..0x4DB` verbatim (per-car float anchors hold).
5. **Body**: walk each section, apply the §3 deltas:
   - Bump section "version" 2 → 3.
   - Insert `[u32 = m_NumBoneWeights][u32 = perSectionId?]` after `lodVSize` and before LOD pool. Insert again before LOD0 pool when applicable. `m_NumBoneWeights = 1` for body, `0` for caliper/rotor/lod0/cockpit. `perSectionId` synthesis is open — donor passthrough or monotonic counter.
   - Re-encode each LOD pool from 32-byte to 28-byte stride (drop UV1).
   - Bump each subsection's "version" 3 → 4 and insert `[u32 = 0]` before `idxCount`.
   - Tail: add 12 bytes (4 init, 4 reserved=1 between b and a*b table, 4 trailing); write `c=3, d=0` to match FH1 norm (or copy from donor).
6. **lod0 / cockpit only**: append `lod0VCount × 4` bytes of per-vertex normal/tangent stream after the tail. Synthesizing this from FM4's inline 0x20 vertex stride needs encoding RE.
7. **`physicsdefinition.bin`**: copy verbatim from a donor FH1 car of similar class. We do NOT synthesize physics bins — see `FH1_PHYSICSDEFINITION_BIN.md` §"Donor-bin strategy".
8. **Database (`gamedb.slt`)**: copy the donor's per-car row as the template; patch `MediaName` / `CarId`. Schema migration handled in Phase 2b.

---

## 12. Open RE Items

| Item | Severity | Notes |
|---|---|---|
| `perSectionId` semantics | medium | Pseudo-random per section. Round-trip safe by passthrough; synthesis blocked on game-loader behavior. |
| Per-vertex stream encoding | medium | High bytes 0xFE/0xFF/0x00/0x01. SHORT2N? DEC3N? Verbatim round-trip OK; semantic decode pending. |
| Expanded middle table (`0xD4..0x2D3`) | medium | 128 words, mostly zero. Z/C/V word classification at finer resolution would partition structural vs per-car. |
| Caliper/rotor quat encoding | low | First vertex's quat field has only the high pair populated (zeros at +12..15, real data at +16..19). Mesh shape correct; only normals read flat-shaded around Z. Possibly per-section base + per-vertex delta. |
| BMW M3 cockpit section 5 | low | A non-mesh section: list of u32 indices with `0x00FFFFFF` sentinels + "plastic"/"metal" string tokens. Likely wiper/decal metadata. 1/8 sample cockpits have it; parser skip-and-resume handles it. |
| FH1 stripped carbin format | low | `TypeId 0x00`. Round-trip via passthrough. Format unknown; FM4 docs flag it as "downlevel". |
| Variable lod0/cockpit prelude | low | Body start varies `0x57C..0x6E0`. Forward-scan handles it; field-classifying the prelude is a future cleanup. |
| `m_MaterialSets[]` parser | medium | Authoritative subsection→texture binding. Currently using a name-prefix heuristic; doesn't matter for byte-passthrough export but matters for "the game actually links to my edited texture". |

---

## 13. Validation strategy

Per project memory `feedback_validation_strategy.md` — cross-game / new-car ports validate **structurally**, not byte-equal-vs-on-disk:

1. **Codec roundtrip stability** through OUR pipeline = byte-equal (current status: ✓ on all 8 sample cars × 3 variants × 8 brake corners on FH1; ✓ on FM4 baseline).
2. **Structural invariants**: output re-parses cleanly; section counts preserved; headers well-formed; vertex pools valid; indices in range; DB rows respect schema.
3. **Donor cross-check** on structural shape only: section counts match a donor of similar class; expected named sections present.
4. **In-game load test**: the only ground truth.

Bit-comparing a ported FM4 car's FH1 output against the existing on-disk FH1 version of the same car (e.g., ALF_8C_08 in both rosters) is **unreachable** — both games carry independently-authored art passes, mesh re-exports, and DB tunings. Don't aim for that bar.

---

## 14. Repro & probes

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
python3 probe/probe_fh1_section_diff.py --variant=lod0      # lod0 (uses fixed parser walk)
python3 probe/probe_fh1_section_diff.py --variant=cockpit   # cockpit

# 4. Section-by-section walk on a single FH1 lod0/cockpit (the RE workhorse)
python3 probe/probe_fh1_lod_walk.py lod0 alf_8c_08
python3 probe/probe_fh1_lod_walk.py cockpit bmw_m3e30_91

# 5. Nim parser dump (matches the production read path)
./probe/nim_parse_dump.bin probe/out/carbin_lod0/fh1_alf_8c_08.carbin
```

Roundtrip verification:

```bash
./build/carbin-garage roundtrip <FH1_zip> --profile fh1
# OK = byte-equal across our import → export pipeline.
```

All 8 paired sample cars × both games × all 3 carbin variants currently report `roundtrip OK`.
