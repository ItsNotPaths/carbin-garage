# DiRT 3 — file-format and container survey

Findings from a single pass over both installs:

- Steam: `/run/media/paths/SSS-Games/SteamLibrary/steamapps/common/DiRT 3 Complete Edition`
- X360 (Xenia): `/run/media/paths/SSS-Games/xenia_canary_windows/content/0000000000000000/434D083D` — installed via Xenia's "Install Content" workflow from the ISO/GoD form. The `default.xex` is loose XEX2; `x360_000.nfs` + `x360_001.nfs` are **plaintext FATX volume slices** (one logical volume split across two files). Verified by raw magic sweep of the first 512 MiB: 57× `PSSG`, 18× `\x00BXML`, 1× `SBDN`, 26× `cars/models` path strings — all sitting in the clear. Nothing is encrypted; the high-entropy sectors my first entropy probe hit just happened to be inside compressed PSSG / BIK payloads.

Probes that exercise everything below live under `probe/d3_*.py`. Run `python3 probe/d3_overview.py` first.

## Steam install — per-car layout

Cars use a 3-letter slug (e.g. `c4r`, `6r4`, `gym`):

```
cars/models/<id>/                     one folder per car
  <id>_highLOD.pssg                   visual mesh (Codemasters PSSG)
  <id>_lowLOD.pssg                    LOD1 mesh
  <id>_AO.pssg                        baked AO atlas
  <id>_anim_dummies.pssg              named locators (suspension, doors, windows)
  <id>.ctf                            physics tuning, chained sections
  <id>_A.ctf, <id>_B.ctf              alternate setups (some cars only — gym, 6r4, ...)
  <id>.nd2                            damage parameters — Codemasters BXML
  <id>.ppts                           per-panel parts table (deformation atlas)
  cameras.xml                         camera presets — CMBXML (yes, .xml extension is misleading)
  ai_vehicle_statistics.xml           grip/brake/accelerate curves — CMBXML
  ai_vehicle_cornering_statistics.xml CMBXML
  livery_NN/textures_high/<id>_tex_*.pssg   DXT body textures wrapped in PSSG
  livery_NN/textures_low/...

cars/interiors/models/<id>/int_<id>.pssg     cockpit (huge: 12+ MB on c4r)
cars/interiors/models/<id>/int_<id>.xml      cockpit shaders / dial bindings (plain text XML)
cars/interiors/models/<id>/int_<id>_anims.pssg, _driver_anims.pssg, _environmentmap.pssg
cars/interiors/models/<id>/int_<id>_gripTimings.xml, _driver_rag_doll.xml

cars/settings/tuning.tng         master schema — names every CTF slot
cars/settings/fallback.ctf       defaults applied when a per-car CTF slot is absent
cars/settings/{carlodsettings,class_mappings,materials*,render_materials,*}.xml

cars/generics/{rally,rallyx,gymkhana,raid,truck,trailblazer,buggy,historic,splitscreen}/
                                  shared meshes per discipline

database/database.bin            SBDN catalog (cars, manufacturers, sponsors, AI cfg, ...)
database/database_{1..8}.bin     localised / per-region row payloads
database/schema.bin              CMBXML — names every column of every SBDN table
database/database_restrictions*.xml   plain XML

system/{flow,links,states}.bin   game state machine (CMBXML)
system/{flow,links,states}_steam.bin   Steam-build variants
system/*.xml                     boot + render config
```

Census from `d3_overview.py` (Steam):

```
cars/      total files: 3680
  PSSG          2989       CMBXML        188      raw.ppts       62
  raw.xml        261       CTF/TNG?      114      raw.pssg        3
  BXML(nd2)       63
database/  SBDN 9 + CMBXML 10 + raw.bin 1 (= 20 files)
system/    raw.xml 32 + CMBXML 6
```

## File-format reference

### PSSG  (`50 53 53 47`)

Codemasters/Phyre scene-and-asset graph. Multi-byte ints are big-endian on disc on **both** PC and Xbox 360 builds — no endian flip needed for the schema. (Texture *payload* bytes inside DATABLOCKDATA do flip on X360, see X360 section.)

Header layout (verified on `c4r_highLOD.pssg`):

```
off  type     meaning
0    char[4]  magic "PSSG"
4    u32 BE   payload size = file size − 8
8    u32 BE   attribute-info total (sum of attr counts across all node types)
12   u32 BE   node-info count (number of unique node types in the schema)
16+         NODE-INFO TABLE: node_info_count entries, each:
              u32 BE   node_id
              u32 BE   name_len
              char[]   name (ASCII)
              u32 BE   attr_count
              attr_count * { u32 BE attr_id, u32 BE name_len, char[] name }
...         NODE TREE: recursive,
              u32 BE   node_id
              u32 BE   size_to_end_of_node
              u32 BE   attr_block_size
              attr_block:  per-attr { u32 BE attr_id, u32 BE size, byte[size] }
              children    until size_to_end_of_node is consumed
```

Sizes seen on `c4r`: highLOD 2.91 MB / 145 node types / 384 attr defs / tree starts at byte 12001. Texture and AO PSSGs ship the full 248–249-node-type Codemasters schema regardless of which nodes they actually use.

Mesh-relevant node types:
`RENDERDATASOURCE`, `RENDERSTREAM`, `RENDERINTERFACEBOUND`, `DATABLOCK`, `DATABLOCKBUFFERED`, `DATABLOCKDATA`, `DATABLOCKSTREAM`, `INDEXSOURCEDATA`, `INVERSEBINDMATRIX`, `JOINTNODE`, `LODNODE`, `MATRIXPALETTE*`, `BBOX`, `TEXTURE`, `TEXTUREIMAGEBLOCK`, `SHADERPROGRAM*`.

Documented format. Open-source readers: RavioliWorks PSSGEditor, Noesis `fmt_codemasters_pssg.py`.

### CTF  (`64 00 00 00 …`)  — per-car physics tuning

`<id>.ctf`. Chain of versioned sections, all little-endian:

```
section := u32 LE version  (always 0x64 = 100)
           u32 LE count
           count * u32       payload word (typically f32)
```

`c4r.ctf` (1388 B): one section count=35, one terminator section count=0, then trailing free-form ASCII metadata strings (e.g. `Citroen C4 WRC - Rebalanced`, `c4r_v2.9 [DiRT3]` — present in modded copies).

A handful of "float" slots are actually packed 4-byte ASCII (engine layout `Inline`, drive `Four`, chassis tag `c4r`); a robust decoder treats slot N as f32 unless it's NaN-range or contains only printable bytes.

Slot semantics live in `cars/settings/tuning.tng`; nothing in `.ctf` itself names the columns.

`fallback.ctf` (925 B): single section count=1 plus trailing ASCII (`fallback_imp_100`).

### TNG  (`64 00 00 00 …`)  — master tuning schema

`cars/settings/tuning.tng`. One file, global.

```
off  type     meaning
0    u32 LE   version (0x64 = 100)
4    u32 LE   entry_count            (61 in DiRT 3 retail)
8    u32 LE   string_table_size      (2743 bytes)
12   bytes    string_table           (NUL-separated ASCII)
...  bytes    per-entry payload      (5026 bytes; ~1256 u32s — exact record
                                       layout left for follow-up)
```

The string table holds field names (`weather_power_multiple`, `rear_drive_proportion`, `tyre_patch_shape_front`, `front_pressure`, …) and slash-paths used by the in-game tuning UI (`Tyres/Tyre Pressure (Front)`, `Drivetrain/Power distribution`, …). 119 unique names total.

### ND2 / "\x00BXML"  — damage definitions

`cars/models/<id>/<id>.nd2`. Codemasters BXML tag tree.

```
0x00  u8       0x00
0x01  char[4]  "BXML"
0x05  u8       0x00 (?)
0x06  u8       0x15 = version 21
0x07..        opcode + NUL-terminated ASCII string stream
```

Strings alternate name/value (`m_damage_multiple` = `1`, `m_wheel_burst_dist_f` = `10`, `m_verts_min_x` = `-1.033473`, …). Opcode bytes (0x01, 0x02, 0x19, …) act as begin-tag / count markers; for a coarse extraction, scan for printable runs and pair them.

### CMBXML  (`1A 22 52 72 …`)  — compact-string BXML

Used by:
- `cars/models/<id>/cameras.xml`, `ai_vehicle_*.xml`
- `system/{flow,links,states}.bin` and `_steam.bin` variants
- `database/schema.bin`
- `database/database_restrictions*.xml`

Three section headers identified by varying first bytes:

```
1A 22 52 72  + u32 LE size   string-table descriptor / root
17 22 52 72  + u32 LE size   string-offset table (strings index by id)
1D 22 52 72  + u32 LE size   element/attribute tree (refs strings by id)
```

Strings are NUL-separated ASCII. Document content (e.g. cameras.xml on `c4r`) carries names like `VehicleViewDefinition`, `Loose`, `lcLateralRestoringForce2`, `chase_close`, `replay_wheel1`. AI vehicle XMLs carry curves like `bump_coef_m`, `accelerate_grip_performances`, `cruise_grip_performances` followed by triplets of (speed, distance, ...).

### PPTS  — panel / parts table

`cars/models/<id>/<id>.ppts`. Little-endian.

```
off  type        meaning
0    u32 LE      record_count
4..  record_count * 40-byte struct {
       char[20]  name             NUL-padded ASCII
       u8[12]    reserved         all zero in retail c4r
       u32 LE    count            # of u32 payload words
       u32 LE    offset           file-relative byte offset of payload
     }
...                               payload region (u32 LE words),
                                   referenced by the offset above
```

Record names follow `<lod>_<region>_<index>` — `x0_window_b_0`, `x0_window_fl_4`, `x0_window_br_0` (b/f back/front, l/r left/right). 15 records on `c4r` (windows only); 30 on `6r4`; ~62 .ppts files total (some cars have none — `dmy` is the no-parts dummy chassis).

The per-record payload (counts ranging 4..44) is presumably an index list pointing at panel-vertex IDs in the matching LOD0 mesh — used by the deformation pass. Exact payload semantics left for follow-up.

### SBDN  (`53 42 44 4e …`)  — global database

`database/database.bin` (+ `_1..8.bin`).

```
off  type        meaning
0    char[4]     magic "SBDN"
4    u32 LE      schema hash (matches schema.bin signature; 0xea8a59e9 in retail)
8    repeating tables, each:
       u8       table_id
       char[3]  "LBT"
       u32 LE   row_count
       row_count * record:
         char[3]  "ITM"
         u8       table_id (matches the enclosing LBT)
         byte[]   row body — variable size, NO leading length field; row
                  ends at the next "ITM" or "LBT" magic
```

`d3_sbdn_probe.py` walks `database.bin` cleanly: 212 tables, schema-hash 0xea8a59e9. Sample of row sizes and contents the probe surfaced:

```
table_id=  0  rows=   22  avg_row=12.0B    fixed-width int fields
table_id=  5  rows=   50  avg_row=104.0B   leading 32-char string id (e.g. "reputation_boost")
table_id=  7  rows=   38  avg_row=88.0B    AI driver records ("PLAYER_AI_DR…")
table_id= 12  rows=  250  avg_row=40.0B    voice samples ("male_001", "male_name_bm_001")
table_id= 14  rows= 1997  avg_row=12.0B    pure FK-id tuples
table_id= 27  rows=   22  avg_row=220.0B   championship metadata ("event_bg_01", "champ_gfx_01…")
```

Column meaning (so you can map a row to "vehicle_model: 2KGT, manufacturer: Ford, …") requires parsing `database/schema.bin` (CMBXML) and joining by table_id; the schema hash is stamped into both files.

`database_1.bin` is essentially empty (132 zero-row LBT headers — likely a placeholder for one localisation that isn't shipped). `database_2..8.bin` carry the actual localised payload per region.

## Steam vs Xbox 360

The Xbox 360 retail disc carries an **identical car-folder tree**; the EGO engine pipeline is the same. The only differences are layered on top.

| aspect | Steam (PC) | Xbox 360 |
|---|---|---|
| container | loose files on disk | Xenia-managed FATX volume in `x360_000.nfs` (~2.95 GB) + `x360_001.nfs` (~3.60 GB) |
| executable | `dirt3_game.exe` (PE) | `default.xex` (XEX2 PowerPC, magic `XEX2`) |
| PSSG schema/header | u32 BE | u32 BE (no flip — already BE on PC) |
| PSSG texture payload | DXT linear | DXT + Xenos GPU swizzle, must be untiled before BC decode |
| CTF / TNG | f32 LE, u32 LE | f32 BE, u32 BE |
| CMBXML | u32 LE size fields | u32 BE size fields |
| BXML (.nd2) | NUL-string tree | identical (text values, endian-independent) |
| SBDN | u32 LE row counts | u32 BE row counts |

So a PC-grade reader for each format works on X360 with one endian flag, except the PSSG texture untile step.

### X360 install layout (Xenia GoD)

`d3_x360_container.py` confirms the on-disk shape under `0000000000000000/434D083D/`:

```
Headers/00007000/32E5D1A4.header               GoD/STFS metadata
00007000/32E5D1A4/
  default.xex                                  XEX2 executable (boots in Xenia)
  nxeart                                       NXE artwork blob (STFS-PIRS)
  x360_000.nfs    2,948,726,784 bytes          FATX volume slice 0 — pseudo-random
  x360_001.nfs    3,603,038,208 bytes          FATX volume slice 1 — pseudo-random
  AvatarAssetPack, AvatarAwards                STFS-PIRS containers
  $SystemUpdate/                               shipped dashboard XEXs
  video/*.bik                                  intro videos (already plaintext)
```

The `.nfs` files are plaintext FATX volume slices that Xenia mounts as the title's installed-game drive. Magic sweep over the first 512 MiB of `x360_000.nfs` finds:

```
PSSG hits         57    -- mesh / texture asset headers in the clear
\x00BXML hits     18    -- damage definition headers
SBDN hits          1    -- catalog header (the rest live in x360_001.nfs)
"cars/models" hits 26    -- directory entries naming the per-car folders
"highLOD" hits     1
```

`x360_001.nfs` is the second half of the same logical FATX volume.

There is no encryption layer. The high entropy I measured on the first pass with `d3_x360_container.py` was an artefact of sampling sectors that happened to fall inside compressed PSSG payloads.

**To extract cars from the X360 install you only need a FATX walker — no key, no Xenia round-trip.** Options:

1. Boot DiRT 3 in Xenia and use **File → Export Content** — easiest, gives you a directory tree.
2. A small standalone FATX reader (~150 LOC of Python: parse the volume header, walk the cluster chain across the two `.nfs` slices, dump entries).
3. `py360` / `xfatx` / `xenia-vfs`.

Per-file formats post-extraction are identical to Steam, with the endian flips listed above.

## Export feasibility — glTF + SQLite per car

`d3_export_feasibility.py c4r` summarises:

| source | kind | status | what's needed |
|---|---|---|---|
| `<id>_highLOD.pssg` | mesh | UNBLOCKED | vendor a Python PSSG reader → emit glTF buffers |
| `<id>_lowLOD.pssg` | mesh | UNBLOCKED | second glTF mesh or skip for v1 |
| `<id>_AO.pssg` | tex | UNBLOCKED | bake into glTF if UV2 exposed |
| `<id>_anim_dummies.pssg` | locators | UNBLOCKED | emit as glTF nodes (suspension, doors) |
| `livery_00/textures_high/*.pssg` | tex | UNBLOCKED | DXT1/3/5 inside PSSG → glTF textures |
| `int_<id>.pssg` | mesh | OPTIONAL | cockpit; skip for v1 (~12 MB on c4r) |
| `<id>.ctf` | floats | PARTIAL | resolve column names from `tuning.tng` schema |
| `<id>.nd2` | damage | UNBLOCKED | BXML name→value pairs |
| `cameras.xml` | camera | UNBLOCKED | CMBXML decode |
| `ai_vehicle_*.xml` | AI curves | UNBLOCKED | CMBXML decode |
| `tuning.tng` | schema | UNBLOCKED | one-time parse, labels CTF slots |
| `database.bin` | catalog | PARTIAL | walk SBDN; column labels need `schema.bin` |
| `database/schema.bin` | schema | UNBLOCKED | CMBXML decode, join by SBDN hash |

Result: ~30–50 LOC of glue once a PSSG reader is vendored. Same code works on X360 once the `.nfs` is exported through Xenia.

## Probes

All under `probe/d3_*.py` — each is standalone and prints a structured report:

- `d3_overview.py` — file census of both installs by magic
- `d3_pssg_probe.py` — PSSG schema-dictionary walker
- `d3_ctf_probe.py` — `.ctf` sections + `.tng` schema dump
- `d3_nd2_probe.py` — both BXML dialects
- `d3_ppts_probe.py` — 40-byte panel record walk
- `d3_sbdn_probe.py` — SBDN table/row walk for `database.bin` family
- `d3_x360_container.py` — verifies XEX2/STFS-PIRS/BIK content + reports `.nfs` entropy
- `d3_export_feasibility.py` — synthesises per-source status for any car id (`python3 probe/d3_export_feasibility.py 6r4`)
