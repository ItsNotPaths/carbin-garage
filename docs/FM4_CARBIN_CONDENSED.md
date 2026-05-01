# FM4 .carbin Modding — Condensed Master Reference

**Project:** Scion FRS → GT86 badge swap via .carbin import/export starting with a round trip first 
**Tool:** Soulbrix (Python) — production `fm4_obj.py` (2,517 lines)  
**Fallback Spec:** Forza Studio C# source (`ForzaVertex.cs`, `ForzaCarSection.cs`, `ForzaCarSubSection.cs`) — authoritative where conflicts exist  
**Scope:** Xbox 360 era — FM2, FM3, FM4, FH1, FH2  
**Constraints:** Single modder, LOD0 primary, LOD1–4 must not break

---

## 1. Version Detection & Header

Version is sniffed via magic values at offsets `0x70`, `0x104`, `0x154`:

| Game | Detection Rule |
|------|---------------|
| FM2 | TypeId 1 + 0x2CA magic, or TypeId 2 + f2test == 0x2CA |
| FM3 | TypeId 2 + (secondDword == 0 or 1), or f3test == 0 |
| FM4 | TypeId 1 + 0x10 magic, or TypeId 2 + f4test == 0x10, or TypeId == 3 |

**Stripped files:** Some carbin files (e.g., `vanillatrunk.carbin`) have `TypeId 0x00` at offset 0x00. These are downlevel/stripped files, not full TypeId==3 FM4 files. Version detection and parsing behave differently.

### FM4 Full Header (TypeId == 3)

```
- TypeId (uint32)
- 0x398 bytes skip
- unkCount × 2 iterations of (uint32 × 4) skips
- 4 bytes skip
- partCount (uint32)
- For each part: CCarSubModel (see below)
```

---

## 2. Authoritative Parse Order

Sources: `ForzaCarSection.cs` + `ForzaCarSubSection.cs` + `carbin.bt` (Doliman100). All multi-byte values are **Big Endian**.

### CCarSubModel Stream Order

```
CCarPartData (section-level header)
├── m_SubModelCount (uint32)
├── SubModelInfo[m_SubModelCount] { uint16 m_SubModel; uint16 m_Material; }
├── version (int32)
├── m_OffsetFromCarOrigin (3× float32)     ← Section position offset
├── m_MinBounds (3× float32)               ← Bounding box min
├── m_MaxBounds (3× float32)               ← Bounding box max
├── m_Mass (float32)
├── m_CenterOfMass (3× float32)
├── m_DetachDamage (float32)
├── m_GlassParticles (variable)            ← Vertices + Indices headers
├── m_HasTransparentMeshes (uint8)
└── m_NumBoneWeights (int32, if version >= 3)

TSubModel (mesh data)
├── Name (String, 8-bit length prefix)
├── [4 bytes skip]

├── LOD1–4 Shared Vertex Pool               ← CRITICAL: stored BEFORE subsections
│   ├── lodVertexCount (uint32)
│   ├── lodVertexSize (uint32)
│   └── lodVertices[lodVertexCount] (ForzaVertex, lodVertexSize bytes each)
│   └── [4 bytes skip]

├── SubSections (meshes)
│   ├── subpartCount (uint32)
│   └── SubSections[subpartCount] (ForzaCarSubSection, see below)

├── LOD0 Vertex Buffer (if version >= 2)    ← stored AFTER subsections
│   ├── [4 bytes skip]
│   ├── vertexCount (int32)
│   ├── vertexSize (uint32)
│   └── lod0Vertices[vertexCount] (ForzaVertex, vertexSize bytes each)

└── FM4 Tail
    ├── [9 bytes skip]
    ├── ReadUInt32() × ReadUInt32() seek
    ├── [4 bytes skip]
    ├── ReadUInt32() × ReadUInt32() seek
    └── 24-byte footer (identical in all observed files)
```

**Key point:** LOD1–4 vertices live in a **shared pool** before subsections. LOD0 has its own separate buffer after subsections. This matches both the C# parser and the `carbin.bt` template (`TSubModel.m_VertexBuffer` vs `CCarSubModel.m_VertexBuffer_LOD0`).

### ForzaCarSubSection Stream Order

```
[5 bytes skip]
XUVOffset  (float32)
XUVScale   (float32)
YUVOffset  (float32)
YUVScale   (float32)
XUV2Offset (float32)
XUV2Scale  (float32)
YUV2Offset (float32)
YUV2Scale  (float32)
[36 bytes skip]
Name       (String, 32-bit length prefix)
Lod        (int32)              ← 0=LOD0, 1–4=LOD1–4
IndexType  (uint32)             ← 4=TriList, 6=TriStrip
[series of skip/assert fields]
IndexCount (int32)
IndexSize  (int32)              ← 2 or 4 bytes per index
Indices[IndexCount]             ← index buffer data
[4 bytes skip]
```

**Subsection header total:** 5 + 32 + 36 = **73 bytes** before the name string.

---

## 3. FM4 Vertex Format (0x20 bytes)

| Offset | Size | Field | Decode |
|--------|------|-------|--------|
| 0x00 | 8 B | Position | 4× int16 (x, y, z, s). `ShortN(v) = v / 32767.0`. Final: `(x*s, y*s, z*s)` |
| 0x08 | 4 B | UV1 | 2× uint16. `UShortN(v) = v / 65535.0` |
| 0x0C | 4 B | UV2 | 2× uint16. `UShortN(v) = v / 65535.0` |
| 0x10 | 8 B | Normal | 4× int16 quaternion → rotation matrix → Row 0 = normal |
| 0x18 | 8 B | extra8 | **Not decoded. Suspected second tangent vector. Must round-trip verbatim.** |

### Helper Functions (Forza Studio)

```csharp
float UShortN(ushort v) => (float)v / 0xFFFF;
float ShortN(short v)   => (float)v / 0x7FFF;
```

### Quaternion → Normal

```csharp
Matrix m = Matrix.CreateFromQuaternion(new Quaternion(
    ShortN(qx), ShortN(qy), ShortN(qz), ShortN(qw)));
normal = new Vector3(m.M11, m.M12, m.M13);   // Row 0
```

**Hemisphere consistency:** `q` and `-q` represent the same rotation, but the game may assume a specific sign. Ensure consistent hemisphere (negate all components if `qw < 0`).

### Other 360-Era Vertex Formats (Reference)

| Game | Size | Layout |
|------|------|--------|
| FM3 Car | 0x10 | Position 4× float16, UV1 2× float16, Normal uint32 packed |
| FM3 Car | 0x28 | Above + UV2 + 16-byte tangent/bitangent + tangent packed |

---

## 4. UV System

### Encoding
UVs are **normalized uint16** (`value / 65535.0`), **not** IEEE 754 half-floats.  
*Historical note: an early stub incorrectly used `>eeee` half-float reads. The production file uses correct `>HHHH` uint16 encoding.*

### Per-Subsection Transform

Each subsection carries its own UV scale/offset, parsed from the 73-byte subsection header:

```
// Default = identity
XUVOffset = 0;   XUVScale = 1;
YUVOffset = 0;   YUVScale = 1;
XUV2Offset = 0;  XUV2Scale = 1;
YUV2Offset = 0;  YUV2Scale = 1;
```

### Transform Applied After Decode

```csharp
// DirectX top-left UV origin requires Y-flip
texture0.X =        texture0.X * XUVScale  + XUVOffset;
texture0.Y = 1.0f - (texture0.Y * YUVScale  + YUVOffset);
texture1.X =        texture1.X * XUV2Scale + XUV2Offset;
texture1.Y = 1.0f - (texture1.Y * YUV2Scale + YUV2Offset);
```

### Import Inverse (OBJ → .carbin)

```python
raw_uv_x = (uv_x - XUVOffset) / XUVScale
raw_uv_y = (1.0 - uv_y - YUVOffset) / YUVScale
```

### `carbin.bt` Note on Packing
`CUnpackingData.m_UVOffsetScale` is a single **XMVECTOR** (4 floats = 16 bytes), suggesting the file packs transforms as:
```c
UV.x = UV.x * scale_x + offset_x   // m_UVOffsetScale.y = XUVOffset?
UV.y = UV.y * scale_y + offset_y   // packed into one vector
```
However, the C# parser reads 8 separate floats. Treat the 8-float parse as authoritative for FM4; the XMVECTOR packing may be a template-level abstraction.

---

## 5. Position Transform

### Section Offset
```csharp
Vector3 Offset = new Vector3(ReadSingle(), ReadSingle(), ReadSingle());
// Applied to all vertices in section after decode:
vertex.position += Offset;
```

### Bounding Box Remapping
```csharp
vertex.position = CalculateBoundTargetValue(
    vertex.position,
    lod0Bounds.Min, lod0Bounds.Max,
    targetMin, targetMax);
```

### Import Inverse
1. Subtract section `Offset` from vertex positions.
2. Reverse the bound remapping (linear remap — exact formula pending from `Utilities.cs`).

---

## 6. Index Buffers

| IndexType | Value | Notes |
|-----------|-------|-------|
| TriList | 4 | Every 3 indices = one triangle |
| TriStrip | 6 | Triangle strip with restart sentinels (`0xFFFF` for 16-bit, `0xFFFFFFFF` for 32-bit) |

---

## 7. Soulbrix Implementation Status

### Working
- **Vertex codec:** `decode_vertex` / `encode_vertex` — correct `>HHHH` UV encoding, correct quaternion handling.
- **Vectorized pools:** `_decode_pool` / `_encode_vertex_pool` (numpy).
- **Export:** `export_section_to_obj` — applies UV Y-flip and per-subsection transforms.
- **Import:** `import_topology`, `import_positions_only`, `import_foreign_mesh`, `add_new_section`, `batch_import`.
- **Tools:** Material mapping, OBJ parsing, LOD decimation via open3d (optional) or numpy fallback.

### Broken / Known Issues

| Issue | Symptom | Root Cause |
|-------|---------|------------|
| **LOD Decimation** | LOD2–5 index buffers are identical clones of LOD1 | `import_topology` writes the same buffer to all LOD subsection slots instead of generating decimated subsets. |
| **FM4 Tail Table** | Filled with `0x03FF` (index 1023) degenerate sentinels | Not reconstructed on import. Original table likely encodes per-vertex LOD remapping or secondary index data. |
| **Normal/Tangent Round-Trip** | Flat/matte paint, missing reflections | Quaternion encode path (`_tangent_space_to_quat`, `_matrix_to_packed_quat`). Possible handedness flip or sign inconsistency for FM4's left-handed space. |
| **Shadows (FS export → Soulbrix import)** | Broken shadow pass under car | Winding order flip or tangent sign error on import. |

**`extra8` (offset 0x18):** Do not zero out. Preserve verbatim. Suspected to be a second tangent vector used by the specular/reflection pass.

---

## 8. Binary Analysis: vanillatrunk vs moddedtrunk

**Files:** `vanillatrunk.carbin` (79,905 B) vs `moddedtrunk.carbin` (95,491 B)  
**TypeId:** `0x00` — stripped/downlevel carbin, not full FM4 TypeId==3.

### Structure
- **Header:** Identical for first ~0x1492 bytes.
- **Section "trunk":** Pure LOD1–5 geometry. **LOD0 vertexCount = 0 in both files.**
- **LOD1–4 vertex pool:** 1,791 → 1,573 vertices (stride 0x20 unchanged).
- **Bounding boxes:** Effectively identical.
- **Normals:** Clean in both (length ~1.0).

### Key Changes
| Feature | Vanilla | Modded | Notes |
|---------|---------|--------|-------|
| LOD1–4 vertex count field | 0xFF (255) | 0x25 (37) | Lower LODs aggressively simplified |
| body indices LOD1 | 388 | 1,008 | ~2.6× increase (widebody geometry) |
| body indices LOD2–5 | 167→55 (decimated) | **1,008 (cloned)** | **BUG:** All LODs identical to LOD1 |
| FM4 tail table | Real per-vertex data | `00 00 03 FF` repeated | Degenerate tri padding as placeholder |

### Conclusions
- The mod adds significant LOD0/detail geometry (+15KB net).
- **Vertex and normal data are clean** — shading issues are not caused by vertex corruption.
- The LOD cloning bug and tail table zeroing are Soulbrix import pipeline defects, not intentional design.
- `0x03FF` = uint16 index 1023, used as D3D9-era strip terminator / degenerate triangle padding.

---

## 9. Supporting 360-Era Formats

### 9.1 Track Models — `.rmb.bin` (`rmb_bin.bt`)
- **Version 6** = FM4 / FH1 (FM3 = version 4).
- **21 command buffers** (FM4/FH1) vs 15 (FM3).
- **Mesh format is byte-for-byte identical to cars:** same `CUnpackingData` (48 bytes), same `CMaterial` v3, same `TSubModel` structure, same index buffer logic.
- **Differences from cars:** No physics (mass/CoM/damage), no skinning/bones, has a world transform `XMMATRIX` (64 bytes), command buffer system with `D3D_FixupRecord` relocations.
- **Relevance:** Validates that the car vertex codec should work for tracks. Command buffers can be treated as opaque blobs for modding.

### 9.2 Shader Objects — `.fxobj` (`fxobj.bt`)
- **Magic:** `00 00 01 01` at offset 0 (`e_fxlite`).
- Contains compiled Xbox 360 shader bytecode + `D3D_CVertexDeclaration` structs.
- **GPU Vertex Format Enum (Xbox 360):**
  - `25` = `GPUVERTEXFORMAT_16_16` (4 bytes) — likely UV1/UV2
  - `26` = `GPUVERTEXFORMAT_16_16_16_16` (8 bytes) — likely position/normal
  - `31` = `GPUVERTEXFORMAT_16_16_FLOAT` — **not** what FM4 uses for UVs
- **D3DDECLUSAGE:** Position(0), TexCoord(5), Normal(3), Tangent(6), Binormal(7).
- **Relevance:** `CMaterial.FxFileNameIndex` references these. `extra8` may map to TANGENT/BINORMAL semantics.

### 9.3 Collision — `.col` / `.colfull` / `.fiz` (`col.bt`, `col_importer.py`)
- **Version 2** = FM3/4 (Motorsport). **Version 4** = FH1/2 (Horizon).
- **Vertex stride:** 32 bytes (FM3/4) = 16-byte XMVECTOR position + 4-byte packed normal (`R11G11B10_SNORM`) + 12-byte padding. Horizon v4+ optimized to 16 bytes.
- **Normal packing:** X=11 bits, Y=11 bits, Z=10 bits, signed. Same format used by later engines.
- **`.fiz` files:** Streaming containers (`magic = "fiz "`) holding collision mesh data per stream square. 32-byte header + data.
- **Relevance:** Separate from visual meshes. Shared packed normal format may inform car normal debugging.

### 9.4 Textures — `.xds` (`D3DBaseTexture.bt`)
- Xbox 360 `D3DBaseTexture` header (~52 bytes) describing GPU texture fetch constants.
- **Formats:** DXT1(18), DXT2_3(19), DXT4_5(20), DXN(49), 16/32_FLOAT, 8_8_8_8 variants.
- **Relevance:** Car textures (damage, paint) are stored separately or referenced via material `TextureSamplerIndices`.

### 9.5 Lookup Tables
- **`PVSZLookup_00.dat`:** 8-byte entries (volume_entry + zone_id). Track visibility/occlusion.
- **`FilenameMap_00.dat`:** Maps volume entry indices to null-terminated filenames. String table for asset lookup.

---

## 10. UV Round-Trip Bug — Analysis & Fix

### Observed Symptom
Exporting `trunk` section to OBJ then re-importing via `import_topology` produces a UV map that is:
- **U axis:** ~98.3% of original (≈1.7% shrinkage)
- **V axis:** ~94.0% of original (≈6.0% shrinkage)
- **Area coverage:** ~92.4% of original (~7.6% smaller)
- Additionally, UV coordinates are **offset** (translated) from their original positions — not merely scaled.

The shrinkage is **non-uniform**, which rules out a simple float precision issue and points to a missing or incorrect transform inversion.

### Root Cause

The export path (`export_section_to_obj`, line ~519) correctly applies the per-subsection UV transform when writing `vt` lines:

```python
# Export (correct)
uvs.append((uv0[0]*xuv_scale + xuv_off, 1.0 - (uv0[1]*yuv_scale + yuv_off)))
```

This matches the authoritative C# formula:
```csharp
texture0.X =        texture0.X * XUVScale  + XUVOffset;
texture0.Y = 1.0f - (texture0.Y * YUVScale + YUVOffset);
```

However, the **import path** (`import_topology` → `_encode_vertex_pool`) does **not invert this transform** before encoding UVs back into the binary. It passes `compiled.texcoords` (the already-transformed OBJ UV values) directly into `_encode_vertex_pool`, which only applies a plain V-flip (`1.0 - v`):

```python
# _encode_vertex_pool (line ~212) — only flips V, no scale/offset inversion
uv0[:, 1] = 1.0 - uv0[:, 1]
```

This means the stored UVs in the reimported binary are:
```
stored = (XUVOffset + raw * XUVScale, YUVOffset + (1 - raw * YUVScale))
```
instead of the correct `raw` value. When the game reads them back and re-applies the subsection transform, the result is double-transformed, causing both the scale compression and the positional offset.

### The Missing Inverse

Per section 4 of this document, the correct import inverse is:
```python
raw_uv_x = (uv_x - XUVOffset) / XUVScale
raw_uv_y = (1.0 - uv_y - YUVOffset) / YUVScale
```

This inverse must be applied to each vertex's UV0 **before** encoding, using the `xuv_off`, `xuv_scale`, `yuv_off`, `yuv_scale` values from the subsection that vertex belongs to.

### Complication: Multi-Subsection Vertex Pool

The shared LOD1–4 vertex pool is written as a **single flat buffer** — all subsections share it. But each subsection has its own UV scale/offset. This means:

- On export, each subsection's vertices get that subsection's transform applied before being written as `vt` lines.
- On import, when rebuilding the pool, each vertex must have its subsection's inverse transform applied **before** encoding.
- The current `_encode_vertex_pool` call at line ~1185 receives the full `compiled.texcoords` list with no per-vertex subsection context, so no per-subsection inversion is possible at that stage.

### Fix Strategy

**Option A — Invert at parse time (preferred):**
When `parse_obj_compiled` / `import_topology` builds the compiled mesh, tag each vertex with its source subsection (already determined during triangle routing). After routing, apply the appropriate inverse transform to each vertex's UV0 before passing to `_encode_vertex_pool`. This keeps the encode function clean.

**Option B — Invert inside `_encode_vertex_pool`:**
Pass a per-vertex array of `(xuv_off, xuv_scale, yuv_off, yuv_scale)` tuples into `_encode_vertex_pool` and apply the inverse there. More self-contained but increases the function's interface complexity.

**Option C — Strip subsection transforms to identity on import:**
For a round-trip-only use case, write back `XUVScale=1, XUVOffset=0, YUVScale=1, YUVOffset=0` in the subsection headers after import, and store the already-transformed UV values verbatim. Avoids the inversion entirely but changes the binary format for those subsection header fields — may cause issues if the game uses those values for anything beyond vertex decode.

### Verification

After applying the fix, compare OBJ `vt` ranges between original export and post-import re-export:
- U range should match within float quantization tolerance (~1/65535 ≈ 0.0015%)
- V range should match within the same tolerance
- Individual UV coordinates should match (not merely the overall extents)

The UV coord data from the two test files for reference:
| | U min | U max | U range | V min | V max | V range |
|---|---|---|---|---|---|---|
| Original export | 0.037315 | 0.940833 | 0.903518 | 0.079003 | 0.987926 | 0.908923 |
| After reimport | 0.037321 | 0.925205 | 0.887884 | 0.133585 | 0.987925 | 0.854340 |
| Expected after fix | ~0.037315 | ~0.940833 | ~0.903518 | ~0.079003 | ~0.987926 | ~0.908923 |

---

## 11. Open Questions (Pre-existing)

1. **`extra8` content:** Second tangent, paint data, or something else? Needs hex diff between vanilla and round-trip.
2. **Quaternion sign convention:** Does `_matrix_to_packed_quat` choose the same hemisphere as original data?
3. **Tangent handedness:** Is a winding/sign flip needed for FM4's left-handed coordinate system?
4. **Bound remapping:** Exact formula for `CalculateBoundTargetValue` (pending `Utilities.cs`).
5. **TriStrip handling:** Does Soulbrix correctly convert TriStrip ↔ TriList on import/export?
6. **Stripped carbin (TypeId 0x00):** Does the parser handle downlevel files correctly, or does it assume TypeId==3?
7. **FM4 tail table:** What do the per-vertex values encode? Per-vertex LOD remapping? Secondary index structure?
8. **LOD decimation:** Why does `import_topology` clone LOD1 into LOD2–5 instead of decimating?
9. **`.fxobj` location:** Are shaders embedded in `.carbin` or separate files? What vertex declaration does FM4 expect?
10. **Per-subsection UV inversion in shared pool:** When multiple subsections with different UV scale/offset share a single vertex pool, a vertex referenced by two subsections with different transforms can only be stored once. Does the game expect raw (pre-transform) UVs in the pool and rely solely on the per-subsection header for display, or does it expect the dominant subsection's transform to be pre-baked? Needs verification against a multi-material section with non-identity UV transforms.

---

## 12. Next Steps (Prioritized)

### P0 — Fix UV Round-Trip (per-subsection inverse transform)
- In `import_topology`, after triangle routing assigns each vertex to a subsection, apply the inverse UV transform before encoding:
  ```python
  raw_uv_x = (uv_x - xuv_off) / xuv_scale
  raw_uv_y = (1.0 - uv_y - yuv_off) / yuv_scale
  ```
- The fix must be per-vertex using the subsection that owns each triangle (already determined during the routing step).
- See Section 10 for full analysis, root cause, and fix strategy options.
- **Verification:** Re-export after import and compare `vt` ranges — U and V extents must match originals within ~0.002.

### P1 — Fix LOD Decimation
- Locate the LOD index write loop in `import_topology`.
- **Quick fix:** Carry over vanilla LOD2–5 index buffers unchanged until decimation is implemented.
- **Proper fix:** Implement LOD decimation (open3d or numpy) to generate LOD-appropriate subsets.
- **Reconstruct FM4 tail table:** Determine encoding and regenerate or preserve from original.

### P2 — Fix Normal/Tangent Round-Trip
- Hex diff `extra8` between vanilla and Soulbrix round-trip — confirm preservation.
- Hex diff quaternion bytes (0x10–0x17) — compare vanilla vs round-trip for quantization accuracy.
- Investigate `_tangent_space_to_quat` for handedness flip.
- Investigate `_matrix_to_packed_quat` for sign consistency (`qw < 0` negation).
- Test Forza Studio export → Soulbrix import path to isolate the shadow/tangent difference.

### P3 — Reconcile Parser with Template
- Map `ForzaCarSection.cs` skips to `carbin.bt` fields for exact byte-accurate parsing.
- Verify `m_UVOffsetScale` packing in actual file offsets (4-float XMVECTOR vs 8-float array).
- Confirm TypeId sniffing behavior on stripped (TypeId 0x00) files.

### Verification Checklist
| Test | Pass Criteria |
|------|---------------|
| `extra8` hex diff | Identical between vanilla and round-trip |
| Quaternion hex diff | Within int16 quantization tolerance (~1/32767) |
| Normal round-trip | Export `(0,1,0)` → re-import matches within tolerance |
| LOD2–5 indices | Unique and decimated (not cloned from LOD1) |
| FM4 tail table | Valid per-vertex data, not `0x03FF` |
| In-game reflections | Match vanilla |
| In-game shadows | No artifacts under car |

### Post-Fix Workflow
Once normal/tangent + LOD bugs are resolved → proceed to badge swap workflow.
