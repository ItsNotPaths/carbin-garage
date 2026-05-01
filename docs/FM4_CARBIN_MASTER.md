# FM4 .carbin Modding — Master Reference

**Project:** Scion FRS → GT86 badge swap via .carbin import/export  
**Tool:** Soulbrix (Python) — chosen over Forza Studio (C#/XNA, no import logic)  
**Fallback:** Forza Studio as reference spec only  
**Constraints:** Single modder, LOD0 is primary target, LOD1–4 must not break  
**Last updated:** 2026-04-28 (session 7 — added fxobj.bt, rmb_bin.bt; consolidated duplicates)

---

## Table of Contents

1. [Project Context](#1-project-context)
2. [.carbin Binary Structure](#2-carbin-binary-structure)
3. [FM4 Vertex Format (0x20 bytes)](#3-fm4-vertex-format-0x20-bytes)
4. [UV Coordinates](#4-uv-coordinates)
5. [UV Transform System](#5-uv-transform-system)
6. [Normals (Quaternion Format)](#6-normals-quaternion-format)
7. [Position Transform](#7-position-transform)
8. [Section & Subsection Parse Order (Authoritative)](#8-section--subsection-parse-order-authoritative)
9. [fm4_obj.py — Implementation Status](#9-fm4_objpy--implementation-status)
10. [UV1 Bug — Root Cause & Status](#10-uv1-bug--root-cause--status)
11. [In-Game Round-Trip Test Results](#11-in-game-round-trip-test-results)
12. [vanillatrunk vs moddedtrunk — Full Binary Analysis](#12-vanillatrunk-vs-moddedtrunk--full-binary-analysis)
13. [ForzaTech Reference (Speculative — Not FM4)](#13-forzatech-reference-speculative--not-fm4)
14. [Open Questions](#14-open-questions)
15. [Next Steps](#15-next-steps)
16. [BlackBird's Notes](#16-blackbirds-notes)
17. [carbin.bt — 010 Editor Binary Template Analysis](#17-carbinbt--010-editor-binary-template-analysis)
18. [Supporting Format Reference](#18-supporting-format-reference)
    - [18.1 pvsz_lookup.bt](#181-pvsz_lookupbt--pvsz-lookup-table)
    - [18.2 col.bt + col_importer.py](#182-colbt--col_importerpy--collision-mesh-format)
    - [18.3 D3DBaseTexture.bt](#183-d3dbasetexturebt--xbox-360-texture-format)
    - [18.4 filename_map.bt](#184-filenamemapbt--volume-entry-name-lookup)
    - [18.5 fiz.bt](#185-fizbt--streaming-file-container)
19. [rmb_bin.bt — Track Model Binary Template Analysis](#19-rmb_binbt--track-model-binary-template-analysis)
20. [fxobj.bt — Xbox 360 Shader Object Format](#20-fxobjbt--xbox-360-shader-object-format)

---

## 1. Project Context

**Goal:** Modify .carbin files for Forza Motorsport 4 to swap badges (Scion FRS → GT86).

### Tool Decision

| Tool | Verdict | Reason |
|------|---------|--------|
| Forza Studio | ❌ Dead end | Exports correctly, but zero import logic. C# + XNA = dead toolchain. |
| Soulbrix | ✅ Chosen | Python = fixable. Already attempts import/export. UV bug traceable and now resolved. |

### Authoritative Sources (priority order)

1. **Forza Studio C# source** — `ForzaVertex.cs`, `ForzaCarSection.cs`, `ForzaCarSubSection.cs` — always wins
2. **Soulbrix `fm4_obj.py`** (2,517-line production file) — working Python implementation
3. **carbin_importer.py / carbin.hexpat** — ForzaTech (FH2–FM2023) reference only; treat as hypothesis for FM4

---

## 2. .carbin Binary Structure

### Version Detection

Version is sniffed by reading magic values at offsets `0x70`, `0x104`, `0x154`:

```csharp
FM2: TypeId 1 + 0x2CA magic, or TypeId 2 + f2test == 0x2CA
FM3: TypeId 2 + (secondDword == 0 or 1), or f3test == 0
FM4: TypeId 1 + 0x10 magic, or TypeId 2 + f4test == 0x10, or TypeId == 3
```

> **Note:** `vanillatrunk.carbin` has TypeId `0x00` at offset 0x00 — this is a stripped/downlevel carbin, not a full FM4 TypeId==3 file. Version detection behaves differently on these.

### FM4 Header (TypeId == 3)

```
- TypeId (uint32)
- 0x398 bytes skip
- unkCount × 2 iterations of (uint32 × 4) skips
- 4 bytes skip
- partCount (uint32)
- For each part: ForzaCarSection
```

### Section Parsing Flow

1. Skip header (0x398 for TypeId == 3)
2. Read section count
3. For each section:
   - Skip unk_type, transform, perms
   - Read name (8-bit length prefix)
   - Read LOD1–4 vertex count/size → read LOD1–4 vertices
   - Read subsections
   - Read LOD0 vertex count/size → read LOD0 vertices

### LOD Order — Critical

**LOD1–4 are stored BEFORE LOD0 in the stream.**

```csharp
// ForzaCarSection.cs
lodVertexCount = Stream.ReadUInt32();
lodVertexSize  = Stream.ReadUInt32();
for i in lodVertexCount:
    lodVertices[i] = ForzaVertex(version, Car, stream, lodVertexSize)

// ... SubSections read here ...

vertexCount = Stream.ReadInt32();
vertexSize  = Stream.ReadUInt32();
for i in vertexCount:
    lod0Vertices[i] = ForzaVertex(version, Car, stream, vertexSize)
```

### Soulbrix parser.py — Known Gap

`_parse_section()` skips vertex data entirely, only tracking offsets. Vertex interpretation is delegated to `fm4_obj.py`:

```python
lod_v_count = r.u32()
lod_v_size  = r.u32()
lod_vertices_start = r.tell()
r.seek(lod_v_count * lod_v_size, 1)   # SKIPS — vertex logic is in fm4_obj.py
```

---

## 3. FM4 Vertex Format (0x20 bytes)

**All multi-byte values are Big Endian.**

| Offset | Size | Field | Format | Decode |
|--------|------|-------|--------|--------|
| 0x00 | 8 B | Position | 4× int16 (x, y, z, s) | `ShortN(v) = v / 32767.0` → `pos = (x*s, y*s, z*s)` |
| 0x08 | 4 B | UV1 (texture0) | 2× uint16 | `UShortN(v) = v / 0xFFFF` |
| 0x0C | 4 B | UV2 (texture1) | 2× uint16 | `UShortN(v) = v / 0xFFFF` |
| 0x10 | 8 B | Normal | 4× int16 quaternion | Quat → rotation matrix → Row 0 |
| 0x18 | 8 B | extra8 | — | **Not decoded; suspected second tangent vector. Must be round-tripped verbatim.** |

### Key Helper Functions (Forza Studio)

```csharp
float UShortN(ushort value) => (float)value / 0xFFFF;   // 0–65535 → 0.0–1.0
float ShortN(short value)   => (float)value / 0x7FFF;   // -32768–32767 → -1.0–1.0
```

### Forza Studio Reference (ForzaVertex.cs — case 0x20)

```csharp
x = ShortN(stream.ReadInt16());
y = ShortN(stream.ReadInt16());
z = ShortN(stream.ReadInt16());
s = ShortN(stream.ReadInt16());
position = new Vector3(x * s, y * s, z * s);

texture0 = new Vector2(UShortN(stream.ReadUInt16()), UShortN(stream.ReadUInt16()));
texture1 = new Vector2(UShortN(stream.ReadUInt16()), UShortN(stream.ReadUInt16()));

Matrix m = Matrix.CreateFromQuaternion(new Quaternion(
    ShortN(stream.ReadInt16()), ShortN(stream.ReadInt16()),
    ShortN(stream.ReadInt16()), ShortN(stream.ReadInt16())));
normal = new Vector3(m.M11, m.M12, m.M13);   // Row 0

stream.Position += 8;   // skip extra8
```

### Other Vertex Formats (Reference Only)

**FM3 Car — 0x10 bytes:** Position 4× float16, UV1 2× float16, Normal uint32 packed
**FM3 Car — 0x28 bytes:** As above + UV2 + 16-byte tangent/bitangent + tangent packed

---

## 4. UV Coordinates

UVs are **normalized uint16** (`v / 0xFFFF`), not half-floats. Production `fm4_obj.py` uses correct `>HHHH` encoding. See [Section 10](#10-uv1-bug--root-cause--status) for bug history.

---

## 5. UV Transform System

Each subsection carries its own UV scale/offset, parsed from `ForzaCarSubSection`:

```csharp
// Defaults = identity transform:
public float XUVOffset = 0;   public float XUVScale = 1;
public float YUVOffset = 0;   public float YUVScale = 1;
public float XUV2Offset = 0;  public float XUV2Scale = 1;
public float YUV2Offset = 0;  public float YUV2Scale = 1;
```

### Parse Order (ForzaCarSubSection.cs — FM4 case)

```
5 bytes skip
XUVOffset  (float32)
XUVScale   (float32)
YUVOffset  (float32)
YUVScale   (float32)
XUV2Offset (float32)
XUV2Scale  (float32)
YUV2Offset (float32)
YUV2Scale  (float32)
36 bytes skip
Total: 5 + 32 + 36 = 73 bytes per subsection header
```

### Transform Applied After Decode

```csharp
// As documented in the C# RE source:
texture0.X =        texture0.X * XUVScale  + XUVOffset;
texture0.Y = 1.0f - (texture0.Y * YUVScale  + YUVOffset);
texture1.X =        texture1.X * XUV2Scale + XUV2Offset;
texture1.Y = 1.0f - (texture1.Y * YUV2Scale + YUV2Offset);
```

**Empirical correction (2026-05-01)**: the `1.0f -` on Y is *wrong*
relative to the carbin-stored values — applying it lands the FH1
steering wheel onto the Alfa-badge atlas region instead of the
steering-wheel image at right-middle of `nodamage.xds`. Either the C#
RE source captured an exporter pipeline (Forza Studio → atlas) rather
than the GPU sample path, or the convention flipped between Forza
versions. Our Nim port bakes the unflipped form:

```
final.x = raw.x * XUVScale  + XUVOffset
final.y = raw.y * YUVScale  + YUVOffset
```

and leaves glTF UV-Y in the carbin's native top-left convention.
Verified across FM4 and FH1 cockpit + body subsections in the 8-car
sample.

### Import Inverse (OBJ → .carbin)

```python
# Carbin → OBJ (export):
uv_x = raw_uv_x * scale + offset
uv_y = 1.0 - (raw_uv_y * scale + offset)

# OBJ → carbin (import, inverse):
raw_uv_x = (uv_x - offset) / scale
raw_uv_y = (1.0 - uv_y - offset) / scale
```

---

## 6. Normals (Quaternion Format)

Quaternion → rotation matrix → Row 0 = normal. Soulbrix implementation correct. Watch for:
- **Quaternion sign:** `q` and `-q` same rotation — ensure consistent hemisphere (negate if `qw < 0`)
- **Tangent computation:** Compute from geometry + UVs if OBJ lacks tangents
- **Rounding:** float → int16 → float quantization (~1/32767) expected

---

## 7. Position Transform

### Section Offset (ForzaCarSection.cs)

```csharp
Vector3 Offset = new Vector3(Stream.ReadSingle(), Stream.ReadSingle(), Stream.ReadSingle());
// Applied after vertex decode:
subSection.Vertices[i].position += Offset;
```

### Bounding Box Remapping

```csharp
// LOD0 and LOD1–4 use separate bounding boxes
subSection.Vertices[i].position = Utilities.CalculateBoundTargetValue(
    subSection.Vertices[i].position,
    lod0Bounds.Min, lod0Bounds.Max,
    targetMin, targetMax);
```

### Import Inverse

1. Subtract section `Offset` from vertex positions
2. Reverse the bound remapping (linear remap — full details pending from `Utilities.cs`)

---

## 8. Section & Subsection Parse Order (Authoritative)

Source: `ForzaCarSection.cs` + `ForzaCarSubSection.cs`, cross-checked against Soulbrix `parser.py`.

### ForzaCarSection — Binary Stream Order

```
1.  unkType (uint32)              — skip if not 2 or 5
2.  Offset  (3× float32)          — position offset applied to all verts
3.  targetMin (3× float32)        — bounding box min
4.  targetMax (3× float32)        — bounding box max
5.  [28 bytes skip]               — damage permutations?
6.  ReadUInt32() × 16 seek        — unknown table
7.  [4 bytes skip]
8.  ReadUInt32() × 2 seek         — unknown table
9.  FM4: +12 bytes skip
10. Name = ReadASCII(ReadByte())   — 8-bit length prefix
11. [4 bytes skip]

--- LOD1–4 vertex block (stored BEFORE LOD0 and BEFORE subsections) ---
12. lodVertexCount (uint32)
13. lodVertexSize  (uint32)
14. lodVertices[]  — lodVertexCount × ForzaVertex(lodVertexSize)
15. [4 bytes skip]

--- SubSections ---
16. subpartCount (uint32)
17. SubSections[] — subpartCount × ForzaCarSubSection

--- LOD0 vertex block ---
18. [4 bytes skip]
19. vertexCount (int32)
20. vertexSize  (uint32)
21. lod0Vertices[] — vertexCount × ForzaVertex(vertexSize)

--- FM4 tail ---
22. [9 bytes skip]
23. ReadUInt32() × ReadUInt32() seek
24. [4 bytes skip]
25. ReadUInt32() × ReadUInt32() seek
```

### ForzaCarSubSection — Binary Stream Order (FM4)

```
1.  [5 bytes skip]
2.  XUVOffset  (float32)
3.  XUVScale   (float32)
4.  YUVOffset  (float32)
5.  YUVScale   (float32)
6.  XUV2Offset (float32)
7.  XUV2Scale  (float32)
8.  YUV2Offset (float32)
9.  YUV2Scale  (float32)
10. [36 bytes skip]
11. Name      = ReadASCII(ReadInt32())   — 32-bit length prefix
12. Lod       = ReadInt32()              — 0=LOD0, 1–4=LOD1–4
13. IndexType = ReadUInt32()             — 4=TriList, 6=TriStrip
14. [series of skip/assert fields — 6×uint32, 4×float, 2×float, 2×float, 1×uint32]
15. IndexCount = ReadInt32()
16. IndexSize  = ReadInt32()             — 2 or 4 bytes per index
17. Indices[]  — IndexCount × IndexSize
18. [4 bytes skip]
```

### Index Types

- **TriList (4):** every 3 indices = one triangle, read directly
- **TriStrip (6):** triangle strip with restart sentinels (`0xFFFF` / `0xFFFFFFFF`)

### extra8 — The 8 Bytes at Offset 0x18

Forza Studio does `stream.Position += 8` after reading the quaternion. These 8 bytes are **not decoded** but are preserved verbatim by Soulbrix's `encode_vertex` via the `extra8` parameter. Originally suspected to be paint/colour data — now believed to be a **second tangent vector** used by the game's specular/reflection pass (see Section 11). **Do not zero them out — round-trip as-is.**

---

## 9. fm4_obj.py — Implementation Status

The production `fm4_obj.py` (2,517 lines, confirmed 2026-04-27) is a complete implementation.

### Vertex codec — ✅ Correct
- `decode_vertex` / `encode_vertex` — correct `>HHHH` UV encoding, correct quaternion handling
- `_decode_pool` / `_encode_vertex_pool` — vectorised (numpy) full vertex buffer codec
- `_shortn` / `_to_shortn` / `_ushortn` — correct normalization helpers
- `_quat_to_matrix_row0` — correct quaternion → normal (Row 0)
- `_tangent_space_to_quat` / `_normal_to_quat` / `_matrix_to_packed_quat` — correct normal → quaternion

### Export pipeline — ✅ Implemented
- `export_section_to_obj` — decodes pool, applies UV Y-flip and per-subsection scale/offset, writes `.obj` + `.mtl` + `.fm4obj.json` manifest
- `_decode_pool` — handles LOD0 vs LOD1–4 selection, validates stride

### Import pipeline — ✅ Implemented
- `import_topology` — rebuilds vertex pool and all subsection index buffers from OBJ
- `import_positions_only` — positional patch only, preserves normals/UVs
- `import_foreign_mesh` — imports external OBJ geometry into a target section
- `add_new_section` — adds a wholly new section from an OBJ + template section
- `batch_import` — imports multiple OBJs in one pass

### Supporting tools — ✅ Implemented
- `get_material_mapping` / `apply_material_mapping` — subsection ↔ OBJ material matching
- `validate_obj_for_import` — pre-import checks
- `parse_obj_compiled` — OBJ text → `CompiledObjMesh` (positions, UVs, normals, face groups)
- LOD decimation via open3d (optional) or numpy fallback

> **Note on the stub file:** A separate ~100-line `fm4_obj.py` stub exists with placeholder functions and `>eeee` half-float UV reads. It is **not** the production file. Discard it.

---

## 10. UV1 Bug — Root Cause & Status

### The Mismatch (Historical)

| Component | Forza Studio (correct) | Soulbrix stub (wrong) |
|-----------|----------------------|-----------------|
| UV1 / UV2 | `ushort / 0xFFFF` (linear, 0–1) | `>e` IEEE 754 half-float (exponential) |

**These are completely incompatible.** A UV of 0.5 stored as half-float (`0x3800`) reads back as `0x3800 / 65535 ≈ 0.0000229` when treated as ushort — severe corruption.

### ✅ RESOLVED — Correct in Production File

The real `fm4_obj.py` already uses correct normalized ushort encoding:

```python
# decode_vertex (line 164):
ru0, rv0, ru1, rv1 = struct.unpack_from(">HHHH", blob, off+8)
tex0 = (_ushortn(ru0), _ushortn(rv0))   # _ushortn = v / 65535.0
tex1 = (_ushortn(ru1), _ushortn(rv1))

# encode_vertex (line 281):
header = struct.pack(">hhhhHHHHhhhh", ...)  # HH = uint16 ✓
```

The stub file circulating with `>eeee` and an incorrect "UV FIX Applied" comment was never the production file.

### What the UV corruption symptoms would look like (if encountered)
- Scrambled textures on LOD1–4
- Badge swap pointing to wrong texture areas
- LOD0 appearing "less broken" at close range on certain meshes

---

## 11. In-Game Round-Trip Test Results

Three screenshots captured at the same track position with the same car (Scion FRS):

| Test | Result | Symptom |
|------|--------|---------|
| **Fig2 — Vanilla** | ✅ Reference | Clean reflections, correct lighting, proper shadows |
| **SoulbrixRoundTrip** | ❌ Broken | Flat/matte paint — reflections missing. Normal/tangent corruption. |
| **ForzaStudioRoundTrip** | ⚠️ Partial | Reflections correct, shadow pass broken underneath car. Winding or tangent issue on import. |

### Conclusions

**UVs are not the active problem.** Both round-trips render textures well enough to identify the car — corruption is in shading/lighting.

**Root cause is in the quaternion encode path:**
- `_tangent_space_to_quat` — how normals+tangents are packed back into the quaternion on import
- `_matrix_to_packed_quat` — the 3×3 matrix → quaternion conversion
- `extra8` (offset 0x18) — suspected second tangent vector used by the specular/reflection pass; **do not zero**

**Forza Studio export → Soulbrix import** is closer to correct (reflections survive) but shadows break — consistent with a winding order flip or sign error in the tangent component being written back.

**Soulbrix export → Soulbrix import** loses reflections entirely — normals pointing wrong directions after full round-trip.

---

## 12. vanillatrunk vs moddedtrunk — Full Binary Analysis

**Date:** 2026-04-28  
**Method:** Full binary parse — header, LOD vertex pool, 18 subsections, LOD0 block, FM4 tail

**Files:**
- `vanillatrunk.carbin` — 79,905 bytes (0x13821), SHA256: `9879204F...EF9AC`
- `moddedtrunk.carbin` — 95,491 bytes (0x17503), SHA256: `755DABA0...0922`
- **Size delta:** +15,586 bytes (+0x3CE2)

### Structure Confirmed

Both files parse cleanly end-to-end:

```
Header (identical, first 0x1492 bytes)
  └─ First diff at 0x1493 (minor float)

Section: "trunk" (TypeId 0x00 — stripped/downlevel carbin)
  ├─ LOD1–4 vertex pool     ← all geometry lives here
  ├─ 18 subsections         ← index buffers only
  ├─ LOD0 block             ← vertexCount = 0 in BOTH files
  └─ FM4 tail               ← LOD_count × 4 byte table + 24-byte footer
```

**This section has zero LOD0 geometry.** Both files are pure LOD1–5, driven entirely by the LOD1–4 vertex pool. The 18 subsections each carry only index buffers — no per-subsection geometry.

### Header Comparison

Both files share identical headers for the first 0x1492 bytes (minor float differences only). TypeId at 0x00 = `0x00` — this is a stripped/downlevel carbin, not a full FM4 TypeId==3 file.

First difference at offset **0x1493**.

### Section "trunk" (at offset 0x14D8)

```
14D0: 00 00 00 00 01 00 00 00 05 74 72 75 6E 6B 00 00  .........trunk..
```

| Offset | Field | Vanilla | Modded | Notes |
|--------|-------|---------|--------|-------|
| 0x14D8 | Name length | 5 | 5 | "trunk" |
| 0x14E4 | LOD count | 6 | 6 | Consistent |
| 0x14E5 | **LOD1–4 vertex count** | **0xFF (255)** | **0x25 (37)** | **Critical change** |

The byte at **0x14E5** changed `FF` → `25`: LOD1–4 reduced from 255 → 37 vertices (85% reduction). Combined with the +15KB net size increase, this indicates LOD0 gained significant geometry while lower LODs were aggressively simplified.

### LOD Vertex Pool

| | Vanilla | Modded |
|---|---|---|
| Vertex count | 1,791 | 1,573 |
| Stride | 32 bytes (0x20) | 32 bytes (0x20) |
| Pool start | 0x14EA | 0x14EA |
| Pool end | 0xF4CA | 0xD98A |

#### Bounding Box (decoded positions)

| Axis | Vanilla | Modded |
|------|---------|--------|
| X | [-0.8790, +0.8790] | [-0.8791, +0.8790] |
| Y | [-0.2736, +0.2736] | [-0.2736, +0.2736] |
| Z | [-0.3906, +0.3906] | [-0.3906, +0.3905] |

Bounding boxes are **effectively identical**. The mesh occupies the same space in both files.

#### Normal Vector Health

| | Min length | Max length | Avg length |
|---|---|---|---|
| Vanilla | 0.9999 | 1.0001 | 1.0000 |
| Modded | 0.9999 | 1.0001 | 1.0000 |

Normals are **clean in both files.** Vertex corruption is not the issue.

### Subsection Index Buffer Comparison

All 18 subsections use `IndexType=6` (TriStrip), `IndexSize=2` (uint16).

| Subsection | LOD | Vanilla indices | Modded indices | Ratio |
|-----------|-----|----------------|----------------|-------|
| body | 1 | 388 | 1,008 | ×2.60 |
| body_2 | 1 | 594 | 1,560 | ×2.63 |
| black | 1 | 78 | 168 | ×2.15 |
| emblem | 1 | 1,116 | 3,020 | ×2.71 |
| badge | 1 | 37 | 72 | ×1.95 |
| body | 2 | 167 | **1,008** | ×6.04 |
| body_2 | 2 | 350 | **1,560** | ×4.46 |
| black | 2 | 98 | 168 | ×1.71 |
| badge | 2 | 24 | 72 | ×3.00 |
| body | 3 | 300 | **1,008** | ×3.36 |
| body_2 | 3 | 21 | **1,560** | ×74.29 |
| black | 3 | 64 | 168 | ×2.62 |
| badge | 3 | 24 | 72 | ×3.00 |
| body | 4 | 142 | **1,008** | ×7.10 |
| black | 4 | 63 | 168 | ×2.67 |
| body_2 | 4 | 13 | **1,560** | ×120.00 |
| badge | 4 | 9 | 72 | ×8.00 |
| body | 5 | 55 | **1,008** | ×18.33 |

### The Actual Problem: LOD Decimation Is a No-Op

The vanilla file has **properly decimated LOD levels** — index counts shrink with each LOD as expected. The modded file has **the exact same index count at every LOD level**:

```
Vanilla body:   LOD1=388  LOD2=167  LOD3=300  LOD4=142  LOD5=55
Modded  body:   LOD1=1008 LOD2=1008 LOD3=1008 LOD4=1008 LOD5=1008
                          ^^^^ cloned ^^^^ cloned ^^^^ cloned ^^^^
```

```
Vanilla body_2: LOD1=594  LOD2=350  LOD3=21   LOD4=13
Modded  body_2: LOD1=1560 LOD2=1560 LOD3=1560 LOD4=1560
                          ^^^^ cloned ^^^^ cloned ^^^^ cloned ^^^^
```

**LOD2 through LOD5 in the modded file are copies of the LOD1 index buffer.** No decimation happened. The game will render full-detail geometry at all distances.

The lower vertex pool count (1,573 vs 1,791) combined with larger index buffers is consistent with this: fewer unique vertices, but the same geometry referenced at every LOD level.

### FM4 Tail Table

The FM4 tail (step 23 in section parse order) is `LOD_count × 4 bytes`:

| | Vanilla | Modded |
|---|---|---|
| Entry count | 1,791 | 1,573 |
| Content | Real data (mixed values) | `00 00 03 FF` repeated throughout |

The modded file's tail table is **entirely zeroed out** (index 1023 = `0x03FF` as a sentinel/null). Whatever this table encodes (likely per-vertex LOD remapping or a secondary index structure), it has been replaced with a degenerate placeholder.

The 24-byte footer at the very end of both files is **identical**:
```
00 00 00 01 00 00 00 00 00 00 00 01 00 00 00 00
00 00 00 01 00 00 00 00
```

### Difference Pattern

- 3,603 difference regions throughout the file
- Differences cluster in ~28-byte chunks — matches FM4's 32-byte vertex stride
- Confirms **vertex-by-vertex modifications**, not just appended data
- ~500+ vertices touched across both LOD levels

### Index Buffer Tail

The modded file has a large block of repeated `00 00 03 FF` at the end:

```
17400+: 00 00 03 FF 00 00 03 FF 00 00 03 FF ...  (repeating)
```

`0x03FF` = uint16 index 1023. This is **degenerate triangle padding** (1023, 1023, 1023 = degenerate tri) — a standard D3D9-era technique for mesh strip termination and vertex cache optimization.

### Root Cause Summary

Based on the binary evidence, the `import_topology` function in Soulbrix rebuilds the vertex pool and subsection index buffers on import:

1. **LOD1 import is correct** — new geometry is present, index counts are ~2–3× vanilla (reflecting the widebody mod geometry).
2. **LOD2–5 import is broken** — the tool clones the LOD1 index buffer into all lower LOD subsection slots instead of generating LOD-appropriate subsets.
3. **FM4 tail table is not reconstructed** — filled with `0x03FF` degenerate sentinels rather than the original per-vertex mapping data.
4. **Vertex data and normals are fine** — not the source of any rendering artifacts.

The round-trip shading issues (flat/matte paint, broken reflections) reported in the in-game tests are likely **unrelated to this file specifically**, since the vertex/normal data is clean. Those symptoms point to the quaternion encode path, which is a separate issue from the LOD cloning bug found here.

### What Changed — Summary

1. LOD1–4 vertex pool simplified: 1,791 → 1,573 vertices
2. LOD1–4 simplified: 255 → 37 vertices (performance tradeoff)
3. LOD0 expanded: net +15KB = significant new detail geometry
4. Index buffer restructured with degenerate tri strip restarts
5. ~500+ vertices modified throughout
6. LOD2–5 index buffers cloned from LOD1 (decimation bug)
7. FM4 tail table zeroed out

This matches a **body kit / widebody mod** pattern: simplified lower LODs for performance, detailed LOD0 for visual quality. The LOD decimation bug is a Soulbrix import issue, not an intentional design choice.

---

## 13. ForzaTech Reference (Speculative — Not FM4)

> ⚠️ **Warning:** This section covers community RE of ForzaTech (FH4/FH5, FM2023) — a **different engine** to FM4's Xbox 360 ForzaEngine. Where anything conflicts with Forza Studio C# source, **the C# source wins**. Treat everything here as hypotheses to verify against real FM4 hex dumps.

### What ForzaTech Confirms About UV Encoding

A working Blender importer for FH2–FM2023 reads UVs as DXGI `R16G16_UNORM` (code 35):

```python
t[0] = stream.read_un16()   # read_u16() / 65535
t[1] = stream.read_un16()
t[0] = t[0] * uv_transform[0][1] + uv_transform[0][0]
t[1] = t[1] * uv_transform[1][1] + uv_transform[1][0]
uv = (t[0], 1 - t[1])   # Y-flip for Blender
```

This independently confirms **normalized uint16 (value/65535) is correct** for UV encoding — consistent with FM4's Forza Studio source.

### ForzaTech Vertex Formats (Not FM4 — Reference Only)

| DXGI Code | Format | Size | Used for |
|-----------|--------|------|----------|
| 6 | R32G32B32_FLOAT | 12 B | Position (FH2 style) |
| 13 | R16G16B16A16_SNORM | 8 B | Position (modern) |
| 35 | R16G16_UNORM | 4 B | **UV coords** |
| 37 | R16G16_SNORM | 4 B | Normal (modern, W-packed) |

### W-Packed Normal Format (ForzaTech modern — NOT FM4)

In newer ForzaTech, Normal X is packed into the Position W component:
```python
n[0] = v_w                        # Normal X packed into Position W
n[1] = normal_stream.read_sn16()  # Normal Y
n[2] = normal_stream.read_sn16()  # Normal Z
```

**FM4 uses quaternion packing** (confirmed by Forza Studio). This format is reference only.

### Coordinate System (ForzaTech → Blender)

```python
# Left-handed (FM/FH) → Right-handed (Blender Z-up):
vert_blender = (-v[0], -v[2], v[1])
norm_blender = (-n[0], -n[2], n[1])
# Face winding flip (LH → RH): swap B and C
face = (a, c, b)
```

Must be reversed on import back to carbin.

### .carbin as Scene File (ForzaTech)

In ForzaTech, `.carbin` is a scene/hierarchy file referencing `.modelbin` files via tagged blob bundles (`Modl`, `Skel`, `Mesh`, `VLay`, `IndB`, `VerB` tags). Whether FM4 uses this same bundle structure is **unconfirmed** — FM4 predates FH2 and likely uses an older format.

### LOD Flags (ForzaTech vs FM4)

ForzaTech uses a bitmask per mesh (LOD0=bit0, LOD1=bit1, etc.). FM4 uses an **integer field per subsection** — confirmed by Soulbrix parser.

### Series Detection (ForzaTech carbin_importer.py)

```python
if self.version == 18:          series = 2  # Horizon
elif self.version in [15, 16]:  series = 2  # Horizon
elif self.version == 21:        # FM (latest)
elif self.version in [14, 17]:  # FM older
```

FM4's version is likely **14 or lower** — needs verification against real FM4 carbin hex dump.

---

## 14. Open Questions

### Vertex/Normal Pipeline

1. **extra8 content:** Are the 8 bytes at offset 0x18 a second tangent (bitangent row), paint data, or something else? Needs hex diff between vanilla and round-tripped carbin.
2. **Quaternion sign convention:** Does `_matrix_to_packed_quat` consistently choose the same hemisphere as the original data? `q` and `-q` encode the same rotation but different shading if the game assumes a specific sign.
3. **Tangent handedness:** Is a handedness/winding flip needed in `_tangent_space_to_quat` for FM4's left-handed coordinate system?
4. **UV2 purpose:** What is `texture1` used for in FM4? Lightmap? Paint mask? Livery layer?

### Parser/Importer

5. **Bound remapping:** Does `CalculateBoundTargetValue` do a simple linear remap or something more complex? Pending `Utilities.cs`.
6. **TriStrip handling:** Does Soulbrix correctly convert TriStrip ↔ TriList on import/export?
7. **fm4carbin library:** Does `parse_fm4_carbin` / `CarbinInfo` / `SectionInfo` handle the stripped/downlevel TypeId==0 carbin format correctly?
8. **LOD decimation:** Why does `import_topology` clone LOD1 index buffers into LOD2–5 instead of generating decimated subsets?

### carbin.bt Mysteries

9. **TypeId at 0x00:** `carbin.bt` doesn't show a top-level TypeId field — the template starts directly with `CCarModelData`. The TypeId sniffing logic may be probing `m_WheelSH` or `m_RearViewMirrorOBB` magic values.
10. **LOD1–4 vertex pool location:** The template shows `m_VertexBuffer` inside `TSubModel`, but the actual file has a shared pool before subsections. This may be a flattening/optimization the template doesn't capture.
11. **FM4 tail table:** The `0x03FF` degenerate index pattern in the modded file isn't explained by this template. What does this table encode? Per-vertex LOD remapping? Secondary index structure?
12. **m_UVOffsetScale packing:** Is it 4 floats (XMVECTOR) in `CUnpackingData` or 8 floats in `CCarMaterialData`? Need to verify against actual file offsets.

### Supporting Format Questions

13. **Do cars use .fiz files?** The collision format references `.fiz` streaming containers — do cars have separate collision files like tracks?
14. **Where are `.xds` textures stored?** The `D3DBaseTexture` format is defined, but where do car textures live — embedded in `.carbin` or separate files?
15. **What does the PVSZ lookup do for cars?** Is there a car-equivalent visibility/occlusion system?
16. **Does `.carbin` have a filename map?** The `FilenameMap_00.dat` maps indices to names — is there an equivalent structure inside `.carbin`?

---

## 15. Next Steps

### Priority 1 — Fix LOD Decimation Bug

The trunk binary analysis revealed that `import_topology` clones LOD1 index buffers into LOD2–5 instead of decimating:

1. **Locate the LOD index write loop** in `import_topology` — confirm it iterates subsections and writes the same buffer for all LOD levels.
2. **Quick fix:** Carry over vanilla LOD2–5 index buffers unchanged until proper decimation is implemented.
3. **Proper fix:** Implement LOD decimation via open3d or numpy fallback to generate LOD-appropriate subsets.
4. **Reconstruct FM4 tail table** — determine what the per-vertex values encode and regenerate or preserve from original.

### Priority 2 — Fix Normal/Tangent Round-Trip

1. **Hex diff `extra8`** between vanilla carbin and Soulbrix round-trip — confirm whether bytes are preserved or zeroed
2. **Hex diff quaternion bytes** (offset 0x10–0x17) — compare vanilla vs round-trip to check reconstruction accuracy
3. **Investigate `_tangent_space_to_quat`** — check if a handedness flip is needed for FM4's left-handed space
4. **Investigate `_matrix_to_packed_quat`** — check quaternion sign consistency (negate all if `qw < 0`)
5. **Test Forza Studio export → Soulbrix import shadow fix** — reflections survive this path; isolate what differs in import-side tangent handling

### Priority 3 — Reconcile carbin.bt with ForzaCarSection.cs

1. **Map C# skips to C++ template fields** — produce an exact byte-accurate parse table.
2. **Verify `m_UVOffsetScale` packing** — confirm whether it's 4 floats (XMVECTOR) or 8 floats in the actual file.
3. **Locate TypeId** — determine if TypeId is a separate header field or if `CCarModelData::version` is what we're detecting.

### Verification Checklist

| Test | Expected Result |
|------|----------------|
| extra8 hex diff | Identical bytes between vanilla and round-trip |
| Quaternion hex diff | Values within int16 quantization tolerance (~1/32767) |
| Normal round-trip: export (0,1,0) | Re-import matches within tolerance |
| LOD2–5 index buffers | Unique, decimated (not cloned from LOD1) |
| FM4 tail table | Reconstructed with valid per-vertex data |
| In-game reflections | Match vanilla (Fig2) |
| In-game shadows | No artefacts under car |

### If normal/tangent + LOD bugs are fixed
→ Proceed to badge swap workflow

---

## 16. BlackBird's Notes

1. **Safe mode:** Using the vanilla OBJ for a full round trip works as expected — good baseline.
2. **Topology is the active blocker:** All current issues stem from failed topology. Original carbins have been replaced with trunk-only files for isolated testing; full round-trip in progress.
3. **UV maps still broken in current Soulbrix version:** Despite the production file using correct `>HHHH` encoding, UV maps do not align with textures the way Forza Studio's UVs do. The encoding format is correct but something upstream (transform application, Y-flip, or scale/offset inversion) is producing misaligned results in practice.
4. **vanillatrunk analysis:** The `FF` → `25` swap at 0x14E5 is the key change in the modded trunk. The `00 00 03 FF` repeats at the tail are index 1023 used as D3D9-era strip terminators — confirms this mod predates the FH2 carbin format.

---

## 17. carbin.bt — 010 Editor Binary Template Analysis

**Source:** `E:\ForzaModdingWorkshop\Rook Workspace\Stage 2\carbin.bt`  
**Author:** Doliman100  
**Tool:** 010 Editor v16.0.3  
**Category:** Authoritative C++ struct layout (game-side)

### Key Discoveries

#### 1. Byte Order Confirmed

```c
BigEndian();
BitfieldRightToLeft();
```

Confirms all multi-byte values are **big-endian**. Bitfields are right-to-left (standard for Xbox/PowerPC).

#### 2. Root Structure — CCarBodyModel

```c
typedef struct {
    CCarModelData m_CarModelData;
    CBaseCarModel base;
} CCarBodyModel;

CCarBodyModel a;  // entry point
```

The `.carbin` file is a `CCarBodyModel` containing:
- `CCarModelData` — lights, wheels, mirrors (car-specific)
- `CBaseCarModelBase<CCarSubModel>` — hierarchy, materials, meshes

#### 3. Version System

| Struct | FM4 Version | Notes |
|--------|-------------|-------|
| `CCarModelData` | 3-4 | `version >= 4` adds `m_DamagePosXYZ` (int8 × 3) |
| `CBaseCarModelData` | 14-17 | `version >= 14` adds `m_NumBones`; `>= 15` adds bone mapping table |
| `CCarPartData` | 3 | `version >= 3` adds `m_NumBoneWeights` |
| `CMesh` | 2 | FH2 baseline |
| `CIndexBuffer` | 4 | `version >= 4` adds serialize flags + key |
| `CVertexBuffer` | 3 | `version >= 3` adds key for shared buffer lookup |
| `CMaterial` | 3 | FM3/4 baseline |

**FM4 is likely version 3-4** for `CCarModelData` (has damage positions) and **version 14-17** for `CBaseCarModelData` (has bones).

#### 4. CCarModelData Layout (TypeId Sniffer Context)

```c
typedef struct {
    int32 version;
    struct { float a[16]; } m_WheelSH[4];  // 0x04–0x43
    
    // version >= 2:
    struct OBB {
        DirectX_XMVECTOR centerPos;      // 4 floats
        DirectX_XMVECTOR orientation[3]; // 3 × 4 floats
        DirectX_XMVECTOR halfDim;        // 4 floats
    } m_RearViewMirrorOBB;
    
    // version >= 3:
    uint32 m_LightFlareCount;
    struct CCarLightData {
        float m_PositionXYZ;      // 12 bytes
        int16 m_DirectionXYZ[3];  // 6 bytes (hfloat?)
        uint8 m_Index;            // 1 byte
        uint8 m_BulbType;         // 1 byte
        uint8 m_Location;         // 1 byte
        uint8 m_Function;         // 1 byte
        uint8 m_ColourRGB[3];     // 3 bytes
        uint8 m_Size;             // 1 byte
        uint8 m_Texture;          // 1 byte
        // version >= 4:
        int8 m_DamagePosX, m_DamagePosY, m_DamagePosZ;  // 3 bytes
        // version >= 5:
        uint8 m_StartFadeAngle, m_EndFadeAngle;  // 2 bytes
    } m_LightFlares[m_LightFlareCount];
} CCarModelData;
```

**Total size (v3, 0 lights):** 0x04 (version) + 0x40 (WheelSH) + 0x40 (OBB) + 0x04 (count) = **0x8C bytes minimum header**

This explains the magic value detection at offsets `0x70`, `0x104`, `0x154` — those are probing into `m_LightFlares` array or subsequent structs.

#### 5. CBaseCarModelData — Hierarchical Structure

```c
typedef struct {
    int32 version;
    
    // version >= 9:
    uint32 m_ShaderVersion;
    
    // Emitters (particle systems):
    struct {
        int32 version;
        uint32 length;
        CCarEmitterData data[length];
    } m_Emitters;
    
    // Driver controls (animation anchors):
    CDriverControls m_DriverControlsData;
    
    // LOD range:
    int32 m_StartLOD, m_EndLOD;
    
    // Analog gauges (dashboard):
    CAnalogGaugeData m_AnalogGauges;  // 3-15 entries depending on version
    
    // Shadow volume:
    float sh_offset, sh_scale;  // m_SHOffsetScale
    
    // Skinning:
    int32 m_NumBones;  // version >= 14
    struct {
        int32 version;
        uint32 length;
        String data[length];  // bone names
    } m_BoneMappingTable;  // version >= 15
} CBaseCarModelData;
```

#### 6. CCarPartData — Section-Level Header

```c
typedef struct {
    int32 m_SubModelCount;
    struct SubModelInfo {
        uint16 m_SubModel;     // index into m_SubModels
        uint16 m_Material;     // index into material set
    } m_SubModels[m_SubModelCount];
    
    int32 version;
    float m_OffsetFromCarOrigin[3];    // XMVECTOR (position offset)
    float m_MinBounds[3];              // bounding box min
    float m_MaxBounds[3];              // bounding box max
    float m_Mass;
    float m_CenterOfMass[3];
    float m_DetachDamage;
    
    struct CCarGlassParticlesData {
        struct { uint32 length; XMVECTOR data[length]; } Vertices;
        struct { uint32 length; uint16 data[length]; } Indices;
    } m_GlassParticles;
    
    uint8 m_HasTransparentMeshes;
    
    // version >= 3:
    int32 m_NumBoneWeights;
} CCarPartData;
```

**This is the authoritative source for section parsing order.** The "unkType", "transform", "perms" skips in `ForzaCarSection.cs` map to:
- `m_OffsetFromCarOrigin[3]` + padding = **12 bytes** (or 16 as XMVECTOR)
- `m_MinBounds[3]`, `m_MaxBounds[3]` = **24 bytes** (bounding box)
- `m_Mass`, `m_CenterOfMass[3]`, `m_DetachDamage` = **16 bytes**
- `m_GlassParticles` = variable (Vertices + Indices headers)
- `m_HasTransparentMeshes` = **1 byte**

#### 7. CMesh — The Actual Mesh Struct

```c
typedef struct {
    int32 version;
    String m_Name;           // length-prefixed
    int32 m_LOD;
    enum D3DPRIMITIVETYPE {
        D3DPT_TRIANGLELIST = 4,
        D3DPT_TRIANGLESTRIP = 6,
    } m_PrimitiveType;
    int32 m_MaterialIndex;
    
    struct CUnpackingData {
        int32 version;
        DirectX_XMVECTOR m_PositionOffset;   // 16 bytes
        DirectX_XMVECTOR m_PositionScale;    // 16 bytes
        DirectX_XMVECTOR m_UVOffsetScale;    // 16 bytes (4 floats!)
    } m_UnpackingData;
    
    struct CIndexBuffer {
        int32 version;
        // version >= 4:
        Buffer_SerializeFlags flags;  // bitfield: keyIsValid, dataIsStripped
        uint32 key;                   // hash for shared buffer lookup
        int32 length;
        int32 stride;
        uint8 data[stride * length];
    } m_IndexBuffer;
    
    // version >= 2:
    struct MeshFlags {
        uint32 PureOpaque : 1;
        uint32 PureTransparent : 1;
        uint32 ShadowDepth : 1;
        uint32 OpaqueBlend : 1;
        uint32 __padding__ : 28;
    } m_MeshFlags;
} CMesh;
```

**Critical finding:** `m_UVOffsetScale` is **4 floats (16 bytes)**, not 8 floats as the subsection header parse suggests. The template shows:
```c
DirectX_XMVECTOR m_UVOffsetScale[4];  // 4 × XMVECTOR = 64 bytes total in CCarMaterialData
```

But in `CUnpackingData`, it's a **single XMVECTOR** (4 floats). This suggests the UV transform is:
```
UV.x = UV.x * m_UVOffsetScale.x + m_UVOffsetScale.y
UV.y = UV.y * m_UVOffsetScale.z + m_UVOffsetScale.w
```

Which matches the Forza Studio `XUVScale, XUVOffset, YUVScale, YUVOffset` pattern — packed as a single `XMVECTOR`.

#### 8. CVertexBuffer — Shared Vertex Pool

```c
typedef struct {
    int32 version;
    if (version >= 3) {
        Buffer_SerializeFlags flags;
        uint32 key;  // hash to find shared buffer
    }
    int32 length;
    int32 stride;
    uint8 data[stride * length];  // CUberPackedVertex
} CVertexBuffer;
```

The vertex pool is a **separate struct** from the mesh — meshes reference it via key. This explains why LOD1–4 vertices are stored before subsections: the vertex buffer comes first, then index buffers reference it.

#### 9. CCarSubModel — Full Hierarchy

```c
typedef struct {
    CCarPartData m_CarPartData;
    TSubModel base;
    
    // version >= 2:
    CVertexBuffer m_VertexBuffer_LOD0;
    
    // version >= 5:
    struct { uint8 m_HasMorphs; } MorphTargets;
    CVertexBuffer m_MorphVertexBuffer;
    CVertexBuffer m_MorphVertexBuffer_LOD0;
} CCarSubModel;
```

**LOD0 has its own vertex buffer** (`m_VertexBuffer_LOD0`) separate from the LOD1–4 pool. This confirms the parse order:
1. LOD1–4 vertex pool (shared)
2. Subsections (index buffers referencing LOD1–4 pool)
3. LOD0 vertex buffer (separate, per-submodel)

#### 10. CMaterialSet — Shader Pipeline

```c
struct CMaterial {
    int32 Version;
    int32 FxFileNameIndex;       // .fx shader file
    int32 TechniqueIndex;        // technique in .fx
    struct {
        uint32 length;
        DirectX_XMVECTOR ShaderConstants[length];  // vertex shader
    } VertexShaderConstants_Container;
    struct {
        uint32 length;
        DirectX_XMVECTOR ShaderConstants[length];  // pixel shader
    } PixelShaderConstants_Container;
    struct {
        uint32 length;
        int32 TextureSamplerIndices[length];  // -1 = inherited
    } TextureSamplerIndices_Container;
};
```

Materials carry **shader constants** (XMVECTOR arrays) and **texture sampler indices**. The `-1 = inherited` is interesting — allows material inheritance across parts.

### Revised Parse Order (Authoritative)

Based on `carbin.bt`, the authoritative parse order is:

```
CCarBodyModel
├── CCarModelData (version 3-4)
│   ├── version (uint32)
│   ├── m_WheelSH[4] (4 × 16 floats = 64 bytes)
│   ├── m_RearViewMirrorOBB (if version >= 2)
│   │   ├── centerPos (16 bytes)
│   │   ├── orientation[3] (48 bytes)
│   │   └── halfDim (16 bytes)
│   └── m_LightFlares (if version >= 3)
│       ├── count (uint32)
│       └── CCarLightData[count] (26-31 bytes each)
│
└── CBaseCarModelBase<CCarSubModel>
    ├── CBaseCarModelData (version 14-17)
    │   ├── version, m_ShaderVersion
    │   ├── m_Emitters (variable)
    │   ├── m_DriverControlsData (variable)
    │   ├── m_StartLOD, m_EndLOD
    │   ├── m_AnalogGauges (12-60 entries)
    │   ├── m_SHOffsetScale (8 bytes)
    │   ├── m_NumBones (if version >= 14)
    │   └── m_BoneMappingTable (if version >= 15)
    │
    ├── m_OrderedSubModels (version 4)
    │   ├── m_NumLODs
    │   ├── m_AlphaList[m_NumLODs]
    │   └── m_OpaqueList[m_NumLODs]
    │
    ├── m_SubModels (CCarSubModel[])
    │   ├── CCarPartData
    │   │   ├── m_SubModelCount
    │   │   ├── SubModelInfo[m_SubModelCount]
    │   │   ├── version, Offset, Bounds, Mass, CoM, Damage
    │   │   ├── m_GlassParticles
    │   │   └── m_HasTransparentMeshes
    │   ├── TSubModel
    │   │   ├── m_Name
    │   │   ├── m_Meshes[]
    │   │   │   ├── CMesh
    │   │   │   │   ├── name, LOD, primitiveType, materialIndex
    │   │   │   │   ├── m_UnpackingData (48 bytes)
    │   │   │   │   ├── m_IndexBuffer (variable)
    │   │   │   │   └── m_MeshFlags
    │   │   │   └── CCarMaterialData
    │   │   │       └── m_UVOffsetScale[4] (64 bytes)
    │   │   └── m_VertexBuffer (shared LOD1-4)
    │   ├── m_VertexBuffer_LOD0 (if version >= 2)
    │   └── m_MorphVertexBuffer (if version >= 5)
    │
    └── m_MaterialSets[]
        └── CMaterial[] (shader constants, textures)
```

### Open Questions — Updated

1. **TypeId at 0x00:** `carbin.bt` doesn't show a top-level TypeId field — the template starts directly with `CCarModelData`. The TypeId sniffing logic may be probing `m_WheelSH` or `m_RearViewMirrorOBB` magic values.

2. **LOD1–4 vertex pool location:** The template shows `m_VertexBuffer` inside `TSubModel`, but the actual file has a shared pool before subsections. This may be a flattening/optimization the template doesn't capture.

3. **FM4 tail table:** The `0x03FF` degenerate index pattern in the modded file isn't explained by this template. May be a post-processing step or cache optimization table.

### Next Steps — Updated

1. **Map `ForzaCarSection.cs` skips to `carbin.bt` fields** — reconcile the C# parser with the C++ template to produce an exact byte-accurate parse.

2. **Verify `m_UVOffsetScale` packing** — confirm whether it's 4 floats (XMVECTOR) or 8 floats (XUVScale/Offset × 2) in the actual file.

3. **Locate TypeId** — determine if TypeId is a separate header field or if the template's `CCarModelData::version` is what we're detecting.

---

## 18. Supporting Format Reference

This section covers auxiliary formats used alongside `.carbin` and `.rmb.bin` — collision data, textures, streaming files, and lookup tables.

---

### 18.1. pvsz_lookup.bt — PVSZ Lookup Table

**Source:** `E:\ForzaModdingWorkshop\Rook Workspace\Stage 2\pvsz_lookup.bt`  
**File Mask:** `PVSZLookup_00.dat`  
**Category:** Zone/visibility lookup

**Structure:**
```c
struct PVSZLookup {
    int32 volume_entry;    // m_VolumeEntry
    int32 unique_id;       // m_UniqueID; zone id
} zones[zones_length];     // FileSize() / 8 entries
```

**Purpose:** Maps volume entries to zone IDs. Used by `CTrackPresentation::InitialisePVSZLookupFile()` and `CTrackPresentation::GetPVSZLookup()`.

**Relevance to cars:** Unknown — this appears to be track-specific for visibility/occlusion systems.

---

### 18.2. col.bt + col_importer.py — Collision Mesh Format

**Source:** `E:\ForzaModdingWorkshop\Rook Workspace\Stage 2\col.bt`, `col_importer.py`  
**Author:** Doliman100  
**File Mask:** `*.col`, `*.colfull`  
**Category:** Collision geometry

**Key Discoveries:**

#### Series Detection

```c
typedef enum {
    MOTORSPORT = 0,
    HORIZON = 1
} Series;
```

The template uses heuristics: if `version == 4` at offset 48, assume Horizon (FH1/FH2).

#### Version System

```
Version 2: FM1/2/3/4 (Motorsport)
Version 3: FM7 (Motorsport, supports (?-2)-3)
Version 4: FH1/2 (Horizon fork)
```

#### File Structure

```
World {
    GridBase (40 bytes) — spatial grid metadata
    file_size, version, magic (0xABCD1234)
    stream_square_dimension/cushion (32 bytes) — streaming bounds
    grid_size (8 bytes)
    stream_squares_length, stream_squares_address
    
    Square[stream_squares_length] {  // 24 bytes each
        grid_coll_mesh_address
        array_id, grid_id
        data_offset, data_size
        game_specific_address
        
        → StreamedGridCollMesh at data_offset {
            GridCollMesh {
                CollMesh {
                    vertexes_length, polygons_length
                    bitmaps_length, bitmaps_offset (FM3+, Motorsport only)
                    vertexes_offset, polygons_offset
                    
                    → CollVert[vertexes_length] {
                        position (XMVECTOR = 16 bytes)
                        normal (packed uint32, R11G11B10_SNORM)
                        gap4[12] (12 bytes padding)
                        // Total: 32 bytes per vertex (FM3/4)
                        // Total: 16 bytes per vertex (FH4+)
                    }
                    
                    → CollPoly[polygons_length] {
                        flags (1 byte)
                        surface_id (1 byte)
                        packed_routes_mask (2 bytes, Horizon v4+)
                        vertex_offsets[3] (12 bytes)
                        normal (XMVECTOR = 16 bytes)
                        // Total: 32 bytes per poly
                    }
                }
                CollGrid — spatial lookup grid
            }
        }
    }
}
```

#### Normal Packing — R11G11B10_SNORM

The collision format uses **packed normals** (same as ForzaTech modern):

```python
# Decode (col_importer.py)
packed_normals = vertex[:, 12:16].view(">u4")  # or [:, 16:20] depending on version
normals = (packed_normals >> np.array([0, 11, 22], np.uint32)) & np.array([0x7FF, 0x7FF, 0x3FF], np.uint32)
normals = ((normals.view(np.int32) << [21, 21, 22]) >> [21, 21, 22]).astype(np.float32) / np.array([1023, 1023, 511], np.float32)

# FM4/Motorsport: swizzle x, z, y → x, y, z
if game_series != 2 or version < 4:
    normals = normals[:, [0, 2, 1]]
```

**Bit layout:**
- X: 11 bits (bits 0-10), range -1023 to 1023
- Y: 11 bits (bits 11-21), range -1023 to 1023  
- Z: 10 bits (bits 22-31), range -511 to 511

This is **DXGI_FORMAT_R11G11B10_SNORM** — the same format ForzaTech uses for packed normals.

#### Collision Vertex Format

| Version | Series | Stride | Position | Normal | Padding |
|---------|--------|--------|----------|--------|---------|
| v2 (FM3/4) | Motorsport | 32 bytes | 16 bytes (XMVECTOR) | 4 bytes (packed) | 12 bytes |
| v4+ | Horizon | 16 bytes | 12 bytes (float3) | 4 bytes (packed) | 0 bytes |

**Horizon optimized the format** — removed the XMVECTOR wrapper and padding, saving 16 bytes per collision vertex.

#### .fiz Files — Streaming Collision Data

The `.fiz` files contain the actual collision mesh data for each stream square:

```
StreamedFileHeader {
    magic = "fiz " (0x20 0x7A 0x69 0x66)
    version (1: FH1 E3, FH2)
    stream_square_data_size
    ai_block_data_size
    ai_block_index
    gap4[12]
}

stream_square_data[stream_square_data_size]
ai_block_data[ai_block_data_size] (if > 0)
```

The `col_importer.py` loads `.fiz` files by index:
```python
with open(F"{bin_path}\\{index}.fiz", "rb", 0) as f:
    f.seek(32)  # skip header
    fiz_stream = BinaryStream.from_buffer(memoryview(f.read(data_size)), ">")
mesh = CollMesh.from_stream(fiz_stream, version, 0)
```

#### Relevance to Cars

Collision meshes are **separate from visual meshes** (`.carbin`). The format shares:
- XMVECTOR position packing
- Packed normal format (R11G11B10_SNORM)
- Big-endian byte order

If we ever need to parse/modify collision data, the `col_importer.py` is a working reference.

---

### 18.3. D3DBaseTexture.bt — Xbox 360 Texture Format

**Source:** `E:\ForzaModdingWorkshop\Rook Workspace\Stage 2\D3DBaseTexture.bt`  
**Author:** Doliman100  
**File Mask:** `*.xds`  
**Category:** D3D9 Xbox texture header

**Key Discoveries:**

#### GPUTEXTUREFORMAT Enum (94 values)

The template defines all Xbox 360 GPU texture formats:

| Value | Format | Notes |
|-------|--------|-------|
| 18 | DXT1 | BC1, 8 bytes/block |
| 19 | DXT2_3 | BC2, 16 bytes/block |
| 20 | DXT4_5 | BC3, 16 bytes/block |
| 49 | DXN | BC4/BC5, 16 bytes/block |
| 60 | CTX1 | Context texture |
| 30-32 | 16/32_FLOAT | Half/full float |
| 6-9, 14 | 8_8_8_8 variants | RGBA8, sRGB, etc. |

#### GPUTEXTURE_FETCH_CONSTANT (24 bytes)

The texture fetch constant is a **packed GPU descriptor**:

```c
typedef struct {
    // Word 0 (4 bytes)
    GPUCONSTANTTYPE Type : 2;       // 0=invalid, 2=texture, 3=vertex
    GPUSIGN SignXYZW : 8;           // 2 bits each
    GPUCLAMP ClampXYZ : 9;          // 3 bits each
    uint32 __padding__ : 3;
    uint32 Pitch : 9;               // DWORD pitch
    uint32 Tiled : 1;               // BOOL
    
    // Word 1 (4 bytes)
    GPUTEXTUREFORMAT DataFormat : 6;
    GPUENDIAN Endian : 2;
    GPUREQUESTSIZE RequestSize : 2;
    uint32 Stacked : 1;
    GPUCLAMPPOLICY ClampPolicy : 1;
    uint32 BaseAddress : 20;        // DWORD
    
    // Word 2 (4 bytes) — size depends on dimension
    union {
        GPUTEXTURESIZE_1D { Width : 24 };
        GPUTEXTURESIZE_2D { Width : 13, Height : 13 };
        GPUTEXTURESIZE_3D { Width : 11, Height : 11, Depth : 10 };
        GPUTEXTURESIZE_STACK { Width : 13, Height : 13, Depth : 6 };
    } Size;
    
    // Word 3-5 (12 bytes) — filter/swizzle config
    GPUNUMFORMAT NumFormat : 1;
    GPUSWIZZLE SwizzleXYZW : 12;    // 3 bits each
    int32 ExpAdjust : 6;
    GPUMINMAGFILTER MagFilter : 2;
    GPUMINMAGFILTER MinFilter : 2;
    GPUMIPFILTER MipFilter : 2;
    GPUANISOFILTER AnisoFilter : 3;
    // ... more filter fields
} GPUTEXTURE_FETCH_CONSTANT;
```

This is the **Xbox 360 GPU command format** — textures are referenced by a 24-byte descriptor that encodes format, dimensions, swizzle, filters, and base address.

#### D3DBaseTexture Structure

```c
typedef struct {
    D3DResource base;  // 24 bytes
    uint32 MipFlush;
    GPUTEXTURE_FETCH_CONSTANT Format;  // 24 bytes
} D3DBaseTexture;  // Total: ~52 bytes
```

**D3DResource:**
```c
typedef struct {
    D3DCOMMON Common;  // 4 bytes (type, lock count, flags)
    uint32 ReferenceCount;
    uint32 Fence;
    uint32 ReadFence;
    uint32 Identifier;
    uint32 BaseFlush;
} D3DResource;
```

#### Relevance to Cars

The `.xds` format is used for **damage textures** (per the comment: `damage.xds`). The carbin material system references textures via `TextureSamplerIndices` — the actual texture data lives in separate `.xds` or embedded in the carbin's material sets.

If we need to extract/modify textures, this template defines the Xbox 360 GPU descriptor format.

---

### 18.4. filename_map.bt — Volume Entry Name Lookup

**Source:** `E:\ForzaModdingWorkshop\Rook Workspace\Stage 2\filename_map.bt`  
**File Mask:** `FilenameMap_00.dat`  
**Category:** Asset name lookup

**Structure:**
```c
local int32 entries_length = ReadUInt() / 4;

// volume_entry offsets
uint32 offsets[entries_length];

// volume_entry names (variable length, null-terminated)
struct {
    char data[];
} names[entries_length];
```

**Purpose:** Maps volume entry indices to filenames. Used by `CTrackPresentation::EnsureFilenameMapLoaded`.

**Relevance:** This is a **string table** for asset lookup — lets the engine resolve "trunk" → section name without storing full strings in the binary.

---

### 18.5. fiz.bt — Streaming File Container

**Source:** `E:\ForzaModdingWorkshop\Rook Workspace\Stage 2\fiz.bt`  
**Author:** Doliman100  
**File Mask:** `*.fiz`  
**ID Bytes:** `66 69 7A 20` ("fiz ")  
**Category:** Streaming data container

**Structure:**
```c
struct StreamedFileHeader {
    char magic[4];       // "fiz "
    uint32 version;      // 1: FH1 E3, FH2
    uint32 stream_square_data_size;
    uint32 ai_block_data_size;
    uint32 ai_block_index;
    uint8 gap4[12];      // padding
} header;  // 32 bytes

uint8 stream_square_data[header.stream_square_data_size];
uint8 ai_block_data[header.ai_block_data_size];  // if > 0
```

**Purpose:** Container for streaming collision data (see `col.bt` Section 18.2). Each `.col` stream square references a `.fiz` file by index.

**Relevance to cars:** Unknown — may be used for streaming track collision, not car data.

---

## 19. rmb_bin.bt — Track Model Binary Template Analysis

### Key Discoveries

#### 1. Version System — FM3 vs FM4 vs FH1

```c
CTrackModel Version:
  - 4: FM3 baseline
  - 5: FM3+ (unreleased?)
  - 6: FM4, FH1
  - >6: Unsupported warning
```

**Critical finding:** FM4's track format is **Version 6**, while the car format (`carbin.bt`) uses versions 3-4 for `CCarModelData` and 14-17 for `CBaseCarModelData`. This confirms **cars and tracks evolved on different version tracks** — they share the same underlying engine structures but diverged.

#### 2. Command Buffer Count Scales with Version

```c
if (Version >= 6)      command_buffer_length = 21;  // FM4, FH1
else if (Version >= 5) command_buffer_length = 18;  // FH1_E3 code
else if (Version >= 4) command_buffer_length = 15;  // FM3
else if (Version >= 3) command_buffer_length = 12;  // FM3 older
```

The command buffer count is **hardcoded per version** — this is a compile-time constant, not a runtime value. FM4/FH1 use **21 command buffers** vs FM3's 15. This suggests FM4 added:
- More render passes (shadow cascades? deferred lighting?)
- More material complexity
- More LOD transition buffers

#### 3. CTrackMesh vs CCarMesh — Nearly Identical

| Field | CTrackMesh | CCarMesh | Notes |
|-------|------------|----------|-------|
| Version | 2 (FM3/4) | 2 (FH2) | Same baseline |
| Name | String (length-prefixed) | String (length-prefixed) | Identical |
| LOD | int32 | int32 | Identical |
| PrimitiveType | D3DPT_TRIANGLELIST/STRIP | D3DPT_TRIANGLELIST/STRIP | Identical |
| MaterialIndex | int32 | int32 | Identical |
| UnpackingData | PositionOffset, PositionScale, UVOffsetScale (3× XMVECTOR = 48 bytes) | Same | **Identical** |
| IndexBuffer | Version 3 (FM3/4) or 4 (FH1) | Version 4 (FH2) | Tracks lag one version behind |
| MeshFlags | PureOpaque, PureTransparent, ShadowDepth, OpaqueBlend | Identical | **Identical** |

**Conclusion:** Track meshes and car meshes use the **same vertex unpacking format**. The `UVOffsetScale` XMVECTOR packing we saw in `carbin.bt` is confirmed here — it's 4 floats (16 bytes), not 8.

#### 4. IndexBuffer Version Differences

```c
// Track (rmb_bin.bt):
IndexBuffer.Version >= 3: FM3/4
IndexBuffer.Version >= 4: FH1 (adds flags + key)

// Car (carbin.bt):
IndexBuffer.Version >= 4: FH2 (adds flags + key)
```

**Tracks got the flags/key feature one version earlier than cars.** This suggests tracks were the "proving ground" for the shared vertex buffer optimization — tracks have more repeated geometry (barriers, buildings, grandstands) so the payoff is bigger.

#### 5. TSubModel Structure — Identical to Cars

```c
TSubModel {
    Version (1: FM3)
    Name (String)
    VertexBuffer {
        Version (2: FM3/4; 3: FH1)
        length, stride
        flags + key (if Version >= 3)
        data[stride * length]
    }
    Mesh_Container {
        Version (1: FM3)
        meshes_length
        CTrackMesh meshes[meshes_length]
    }
}
```

This is **structurally identical** to `TSubModel` in `carbin.bt`. The vertex buffer layout (version, flags, key, stride×length data) is the same.

#### 6. CTrackSubModel — Bounding Box + Offset

```c
CTrackSubModel {
    Version (1: FM3/4)
    OffsetFromModelOrigin (XMVECTOR = 16 bytes)
    MinBounds (XMVECTOR = 16 bytes)
    MaxBounds (XMVECTOR = 16 bytes)
    TSubModel base
}
```

Compare to `CCarPartData`:
```c
CCarPartData {
    m_SubModelCount
    SubModelInfo[m_SubModelCount]
    version
    m_OffsetFromCarOrigin[3] (XMVECTOR = 16 bytes)
    m_MinBounds[3] (XMVECTOR = 16 bytes)
    m_MaxBounds[3] (XMVECTOR = 16 bytes)
    m_Mass, m_CenterOfMass[3], m_DetachDamage (16 bytes)
    m_GlassParticles (variable)
    m_HasTransparentMeshes (1 byte)
    m_NumBoneWeights (if version >= 3)
}
```

**Cars have extra physics data** (mass, center of mass, detach damage, glass particles, bone weights). Tracks are purely visual — no physics, no damage, no skinning.

#### 7. TBaseModel — Command Buffer System

The `TBaseModel` struct contains the **command buffer group** — a D3D9-era render command list system:

```c
CommandBufferGroup {
    SharedHeaderSize, SharedPhysicalSize, SharedInitializationSize
    SharedStaticFixupSize, SharedDynamicFixupSize
    
    CommandBuffer[command_buffer_length] {
        Version (2: FM3/4)
        StaticFixups, DynamicFixups
        HeaderSize, PhysicalSize, InitializationSize
    }
    
    SharedHeaderPart (D3D_CCommandBuffer)
    SharedPhysicalPart (D3D_CPatchListChunk)
    SharedInitializationPart (static fixups)
}
```

This is a **custom D3D command allocator** — the game pre-bakes render commands into a binary blob instead of recording them at runtime. The `D3D_FixupRecord` system patches pointers into the command buffers at load time.

#### 8. D3D_FixupRecord — Binary Relocation System

```c
struct D3D_FixupRecord {
    uint32 Type : 6;       // not D3D_FixupType enum
    uint32 Offset : 20;    // relative to m_dwBufferResources->m_Resource
    uint32 Dwords : 4;     // how many dwords follow
    uint32 More : 1;       // chained records
    uint32 Dynamic : 1;    // static vs dynamic fixup
    uint32 Data[Dwords - 1];
}
```

This is a **binary relocation table** — like ELF relocations but for D3D resources. When the `.rmb.bin` loads, the engine walks the fixup records and patches pointers/indices into the vertex/index buffers.

**Fixup types** (from `D3D_FixupType` enum in `CBaseCarModelData`):
1. SetSurfaces
2. SetClipRect
3. SetViewport
4. SetShaderConstant
5. SetVertexShader
6. SetPixelShader
7. SetTexture
8. SetIndexBuffer
9. SetVertexBuffer
10. SetConstantBuffer
11. SetCommandBuffer

#### 9. CMaterial — Identical to Cars

```c
CMaterial {
    Version (3: FM3/4)
    FxFileNameIndex (int)
    TechniqueIndex (int)
    VertexShaderConstants_Container (XMVECTOR array)
    PixelShaderConstants_Container (XMVECTOR array)
    TextureSamplerIndices_Container (int array, -1 = inherited)
}
```

This is **byte-for-byte identical** to the car material format. The shader pipeline is shared between cars and tracks.

#### 10. World Transform — Track-Specific

```c
CTrackModel {
    Version (4: FM3, 6: FM4/FH1)
    MinBounds, MaxBounds (bounding sphere?)
    WorldTransform (XMMATRIX = 64 bytes)
    TBaseModel base
}
```

Tracks have a **world transform matrix** — this is the track's position/orientation in the world. Cars don't have this at the top level because the car's transform is handled by the physics engine, not the model file.

### Comparison: .rmb.bin vs .carbin

| Feature | .rmb.bin (Track) | .carbin (Car) | Notes |
|---------|-----------------|---------------|-------|
| Root version | 6 (FM4) | 3-4 / 14-17 | Different version tracks |
| Command buffers | 21 (FM4) | Unknown | FM4 tracks use 21 |
| Vertex unpacking | 3× XMVECTOR (48 bytes) | 3× XMVECTOR (48 bytes) | **Identical** |
| Index buffer version | 3 (FM3/4), 4 (FH1) | 4 (FH2) | Tracks got it earlier |
| Material format | CMaterial v3 | CMaterial v3 | **Identical** |
| SubModel structure | TSubModel | TSubModel + CCarPartData | Cars have extra physics |
| Physics data | None | Mass, CoM, damage, glass | Cars only |
| Skinning | None | Bones, weights (v14+) | Cars only |
| World transform | XMMATRIX (64 bytes) | Per-section offset (12 bytes) | Tracks have global transform |
| Fixup system | D3D_FixupRecord | Unknown (likely same) | Shared engine feature |

### What This Tells Us

1. **FM4 cars and tracks share the same mesh format** — vertex unpacking, materials, index buffers are identical. This means Soulbrix's vertex codec should work for both.

2. **Tracks don't have skinning or physics** — simpler format, no bones, no mass/CoM, no damage model. If we can parse `.rmb.bin`, we can parse the visual parts of `.carbin`.

3. **The command buffer system is the same** — the `D3D_FixupRecord` relocation system is a shared engine feature. If `.carbin` uses the same structure (likely), we can skip it entirely for modding purposes (just preserve bytes verbatim).

4. **Version divergence is real** — cars are on version 3-4/14-17, tracks are on version 6. This suggests the engine evolved cars and tracks separately — maybe different teams, maybe different priorities.

### Open Questions — Updated

13. **Does `.carbin` have the same command buffer system?** If so, we can skip it verbatim like we do with the FM4 tail table.

14. **What are the 21 command buffers in FM4?** Compare to FM3's 15 — what extra render passes were added?

15. **Can we parse `.rmb.bin` as a test case?** If Soulbrix can successfully round-trip a track model, that validates the vertex codec for cars.

### Next Steps — Updated

1. **Hex dump a vanilla `.rmb.bin` file** — see if the structure matches `rmb_bin.bt` and identify the magic values.

2. **Compare `.rmb.bin` vertex format to `.carbin`** — confirm the 0x20 byte FM4 vertex format is identical.

3. **Skip command buffers for now** — treat them as opaque blobs to preserve verbatim. Focus on mesh + material data.

---

## 20. fxobj.bt — Xbox 360 Shader Object Format

**Source:** `C:\Users\BlackBird\.claude\memory\technical\forza\fxobj.bt`
**Author:** Doliman100
**File Mask:** `*.fxobj`
**ID Bytes:** `00 00 01 01` (magic at offset 0)
**Category:** Compiled shader + vertex declaration format

---

### Key Discoveries

#### 1. File Structure Overview

```
Offset  Size   Field
0x00    4      m_type (uint32) — 0x101 = e_fxlite
0x04    4      Hash (uint32)
0x08    4      m_size (uint32) — shader bytecode size
0x0C    4      m_techniqueCount (uint32)
0x10    4      m_vdeclCount (uint32) — vertex declaration count
0x14    4      m_strideCount (uint32)
0x18    4      size_bytes (uint32) — total size
0x1C    var    m_data1 — technique/vdecl/stride tables
var     m_size m_data2 — shader bytecode (uint8 array)
var     var    m_data3 — D3D_CVertexDeclaration structs + element names
```

#### 2. GPU Vertex Format Enum (Authoritative Xbox 360 Values)

The template defines the **actual GPU vertex format enum** used by Xbox 360 D3D:

| Value | Format | Size | Notes |
|-------|--------|------|-------|
| 6 | `GPUVERTEXFORMAT_8_8_8_8` | 4 B | RGBA8 / UBVEC4 |
| 7 | `GPUVERTEXFORMAT_2_10_10_10` | 4 B | Packed normal/color |
| 16 | `GPUVERTEXFORMAT_10_11_11` | 4 B | Unsigned float pack |
| 17 | `GPUVERTEXFORMAT_11_11_10` | 4 B | Unsigned float pack (swizzled) |
| 25 | `GPUVERTEXFORMAT_16_16` | 4 B | Half-float or short |
| 26 | `GPUVERTEXFORMAT_16_16_16_16` | 8 B | Half-float × 4 |
| 31 | `GPUVERTEXFORMAT_16_16_FLOAT` | 4 B | **2× float16** |
| 32 | `GPUVERTEXFORMAT_16_16_16_16_FLOAT` | 8 B | **4× float16** |
| 33 | `GPUVERTEXFORMAT_32` | 4 B | Single float32 |
| 34 | `GPUVERTEXFORMAT_32_32` | 8 B | 2× float32 |
| 35 | `GPUVERTEXFORMAT_32_32_32_32` | 16 B | 4× float32 |
| 36 | `GPUVERTEXFORMAT_32_FLOAT` | 4 B | Single float32 |
| 37 | `GPUVERTEXFORMAT_32_32_FLOAT` | 8 B | 2× float32 |
| 38 | `GPUVERTEXFORMAT_32_32_32_32_FLOAT` | 16 B | 4× float32 (XMVECTOR) |
| 57 | `GPUVERTEXFORMAT_32_32_32_FLOAT` | 12 B | 3× float32 |

**Relevance to FM4:** The FM4 vertex format (Section 3) uses:
- **Position:** 4× int16 (`ShortN`) → likely `GPUVERTEXFORMAT_16_16_16_16` (type 26) with sign extension
- **UV1/UV2:** 2× uint16 (`UShortN`) → likely `GPUVERTEXFORMAT_16_16` (type 25)
- **Normal:** 4× int16 quaternion → likely `GPUVERTEXFORMAT_16_16_16_16` (type 26)
- **extra8:** Unknown — possibly `GPUVERTEXFORMAT_16_16_16_16` or `GPUVERTEXFORMAT_2_10_10_10` (type 7)

#### 3. D3DDECLUSAGE — Semantic Enum

```c
typedef enum <uint8> {
    D3DDECLUSAGE_POSITION = 0,
    D3DDECLUSAGE_BLENDWEIGHT = 1,
    D3DDECLUSAGE_BLENDINDICES = 2,
    D3DDECLUSAGE_NORMAL = 3,
    D3DDECLUSAGE_PSIZE = 4,
    D3DDECLUSAGE_TEXCOORD = 5,      // UV coordinates
    D3DDECLUSAGE_TANGENT = 6,
    D3DDECLUSAGE_BINORMAL = 7,
    D3DDECLUSAGE_TESSFACTOR = 8,
    D3DDECLUSAGE_COLOR = 10,
    D3DDECLUSAGE_FOG = 11,
    D3DDECLUSAGE_DEPTH = 12,
    D3DDECLUSAGE_SAMPLE = 13
} D3DDECLUSAGE;
```

**Relevance:** Each vertex element in a D3D vertex declaration has a **usage semantic** that tells the shader what the data represents. The FM4 vertex format maps to:
- Position → `D3DDECLUSAGE_POSITION`
- UV1/UV2 → `D3DDECLUSAGE_TEXCOORD` (UsageIndex 0 and 1)
- Normal → `D3DDECLUSAGE_NORMAL`
- extra8 → Possibly `D3DDECLUSAGE_TANGENT` + `D3DDECLUSAGE_BINORMAL`

#### 4. D3DVERTEXELEMENT9 — Vertex Element Struct

```c
struct D3DVERTEXELEMENT9 {
    uint16 Stream;          // Vertex stream index (usually 0)
    uint16 Offset;          // Byte offset within vertex
    D3DDECLTYPE Type;       // Format (see GPUVERTEXFORMAT above)
    uint8 Method;           // D3DDECLMETHOD (0=default, 1=lookup, 2=lookup_presampled)
    D3DDECLUSAGE Usage;     // Semantic (see D3DDECLUSAGE above)
    uint8 UsageIndex;       // Semantic index (e.g., TEXCOORD 0 vs TEXCOORD 1)
    uint8 gapB;             // Padding
}
```

**This is the standard D3D9 vertex element format** — Xbox 360 uses the same structure as PC D3D9, but with Xbox-specific `GPUVERTEXFORMAT` types.

#### 5. D3D_CVertexDeclaration — Full Vertex Declaration

```c
struct D3D_CVertexDeclaration {
    D3DResource base;           // 24 bytes (common D3D resource header)
    uint32 m_Count;             // Number of vertex elements
    uint32 m_MaxStream;         // Max stream index used
    uint8 m_StreamMask[16];     // Which streams are active
    uint32 m_Uniqueness;        // Hash for deduplication
    D3DVERTEXELEMENT9 m_Element[m_Count];  // Element array
    uint8 padding[4];           // Alignment
}
```

**Total size:** `24 + 4 + 4 + 16 + 4 + (m_Count × 16) + 4` bytes

Each element is **16 bytes**, so a typical FM4 vertex declaration with 5 elements (Position, UV1, UV2, Normal, extra8) would be:
- Base: 52 bytes
- Elements: 5 × 16 = 80 bytes
- **Total: ~132 bytes** per vertex declaration

#### 6. D3DResource — Common Resource Header (24 bytes)

```c
struct D3DResource {
    D3DCOMMON Common;       // 4 bytes (bitfield with type, lock count, flags)
    uint32 ReferenceCount;  // 4 bytes
    uint32 Fence;           // 4 bytes
    uint32 ReadFence;       // 4 bytes
    uint32 Identifier;      // 4 bytes
    uint32 BaseFlush;       // 4 bytes
}
```

**D3DCOMMON bitfield (4 bytes):**
```c
struct D3DCOMMON {
    enum D3DRESOURCETYPE TYPE : 4;         // Resource type (see below)
    uint32 LOCKID : 4;
    uint32 LOCKCOUNT : 4;
    uint32 INTREFCOUNT : 5;
    uint32 COMMMANDBUFFER_USED : 1;
    uint32 ASYNCLOCK : 1;
    uint32 ASYNCLOCK_LOCKED : 1;
    uint32 D3DCREATED : 1;
    uint32 CPU_CACHED_MEMORY : 1;
    uint32 RUNCOMMANDBUFFER_TIMESTAMP : 1;
    uint32 ASYNCLOCK_PENDING : 6;
    uint32 UNUSED : 3;
}
```

#### 7. D3DRESOURCETYPE — Resource Type Enum

```c
typedef enum {
    D3DRTYPE_NONE = 0,
    D3DRTYPE_VERTEXBUFFER = 1,
    D3DRTYPE_INDEXBUFFER = 2,
    D3DRTYPE_TEXTURE = 3,
    D3DRTYPE_SURFACE = 4,
    D3DRTYPE_VERTEXDECLARATION = 5,       // ← fxobj contains these
    D3DRTYPE_VERTEXSHADER = 6,            // ← fxobj contains these
    D3DRTYPE_PIXELSHADER = 7,
    D3DRTYPE_CONSTANTBUFFER = 8,
    D3DRTYPE_COMMANDBUFFER = 9,
    D3DRTYPE_ASYNCCOMMANDBUFFERCALL = 10,
    D3DRTYPE_PERFCOUNTERBATCH = 11,
    D3DRTYPE_OCCLUSIONQUERYBATCH = 12
} D3DRESOURCETYPE;
```

**Relevance:** `.fxobj` files contain **compiled shader bytecode** (vertex/pixel shaders) and **vertex declarations**. The carbin format references these via `FxFileNameIndex` in the `CMaterial` struct.

#### 8. Shader Bytecode Section (m_data2)

```c
uint8 m_data2[m_size];  // Shader bytecode, size = m_size
```

This is **raw compiled Xbox 360 shader bytecode** — typically D3D9-style bytecode with Xbox extensions. The bytecode is what the GPU actually executes.

#### 9. Element Names Section (m_data3)

After the vertex declarations, there's a section with **human-readable element names**:

```c
struct {
    struct {
        char data[];  // Null-terminated strings
    } elements_names[vdecls[i].m_Count];
} vdecls_elements_names[m_vdeclCount];
```

**Example names:** `"POSITION"`, `"TEXCOORD0"`, `"TEXCOORD1"`, `"NORMAL"`, `"TANGENT"`, `"BINORMAL"`, `"COLOR0"`

This is debug/metadata — not used at runtime but useful for tools.

---

### Comparison: fxobj vs carbin Vertex Handling

| Feature | fxobj (Shader Object) | carbin (Mesh) | Notes |
|---------|----------------------|---------------|-------|
| Vertex declaration | D3D_CVertexDeclaration (formal) | Implicit (0x20 byte stride) | fxobj defines the layout; carbin just stores packed vertices |
| Vertex format | GPUVERTEXFORMAT enum | Packed int16/uint16 | carbin uses custom packing; fxobj declares what GPU expects |
| Shader bytecode | Yes (m_data2) | No | carbin references shaders via material's `FxFileNameIndex` |
| Element names | Yes (debug metadata) | No | carbin relies on implicit ordering |
| Resource header | D3DResource (24 bytes) | None | carbin is a scene file, not a D3D resource |

**Key insight:** The `.fxobj` format defines **what the GPU expects** (vertex declaration + shader bytecode). The `.carbin` format stores **the actual vertex data** in a compact, engine-specific packing. The material system bridges them via `FxFileNameIndex` → shader + `TextureSamplerIndices` → textures.

---

### Open Questions — Updated

17. **What vertex declaration does FM4 use?** The carbin doesn't store explicit vertex declarations — they're implicit in the vertex stride (0x20 = 32 bytes). What `D3D_CVertexDeclaration` does the shader expect?

18. **Where are the .fxobj files?** Are they embedded in `.carbin`, stored in separate files, or compiled into the game binary?

19. **What shader techniques does FM4 use?** The `m_techniqueCount` field suggests multiple techniques per shader — what techniques are used for car rendering (opaque, transparent, glass, damage)?

20. **Does the `extra8` field map to TANGENT/BINORMAL?** If the vertex declaration includes tangent semantics, the `extra8` bytes at offset 0x18 likely encode a second tangent vector.

---

### Next Steps — Updated

4. **Extract vertex declaration from a vanilla .fxobj** — if we can find the shader file, we can see exactly what vertex format the GPU expects.

5. **Cross-reference CMaterial::FxFileNameIndex** — map material indices to shader filenames to find the actual vertex declaration used.

6. **Test `extra8` as tangent/bitangent** — decode the 8 bytes as 4× int16 and see if they form a valid tangent vector orthogonal to the normal.
