# FH1 vs FM4 — Asset & Format Overview

Snapshot of what lives where in each game and how they differ. Refer to
`FORZA_LZX_FORMAT.md` for the per-archive compression layer and to
`FH1_CARBIN_TYPEID5.md` / `FH1_PHYSICS_DB.md` for the per-format deep dives.

## Game roots

| | FM4 | FH1 |
|---|---|---|
| Title ID | `4D530910` | `4D5309C9` |
| Content ID | `33E7B39F` | `2DC7007B` |
| Media folder | `Media/` (capitalized) | `media/` (lowercased) |
| Cars folder | `Media/cars/` — 322 zips | `media/cars/` — 180 zips |
| Cars in both games | — | **80** by name (case-insensitive) |
| Build dates seen | 2011-07 | 2012-08 |

FH1 has an extra top-level dir `00000001/marketplace/` (DLC).
FH1's cars folder also has two non-car siblings: `CarAttribs.xml` (top
level, distinct from the per-car one) and `AppearancePresets.zip`.

## Per-car archive contents (reference: `ALF_8C_08.zip`)

| Group | FM4 | FH1 | Notes |
|---|---|---|---|
| Main carbin | `<car>.carbin` (TypeId 2) | `<CAR>.carbin` (**TypeId 5**) | Casing differs; format differs (see FH1_CARBIN_TYPEID5.md) |
| LOD0 carbin | `<car>_lod0.carbin` (TypeId 2) | `<CAR>_lod0.carbin` (TypeId 5) | |
| Cockpit | `<car>_cockpit.carbin` | `<CAR>_cockpit.carbin` | |
| Calipers / rotors | 4 of each, LOD0 | 4 of each, LOD0 | |
| **Stripped variants** | (none) | `stripped_*.carbin` for every part above | **FH1-only** — downlevel/header-only carbins, ~10 per car (839 total in 77 cars) |
| Damage textures | `damage*.xds`, `nodamage*.xds`, `lights*.xds` | same + `interior_emissive_LOD0.xds`, `zlights*.xds` | FH1 adds emissive + zlights variants |
| Livery masks | 5× TGA + `masks.xml` | 5× TGA + `Masks.xml` | identical layout, ~drop-in |
| Digital gauge | `Dash_*.{bgf,bsg,fbf}` + 2× XDS | same | identical layout, drop-in for 9/9 sample |
| **Physics XML** | `physics/maxdata.xml` | `Physics/MAXData.xml` | **byte-identical for 74/76 shared cars** — see FH1_PHYSICS_DB.md |
| **Compiled physics** | (none) | `physicsdefinition.bin` (~2.3 KB) | **FH1-only**, binary, unlabeled |
| `carattribs.xml` | yes (Version 16) | yes (Version 21) | Mostly cosmetic drift; 1/77 byte-identical |
| `shadersettings.xml` | sometimes (66/79) | sometimes (80/79) | |
| `versiondata.xml` | yes (77/77) | (none) | **FM4-only** |
| `BuildNumber.txt`, `*_build_report.html` | yes | yes | metadata only |

## Aggregate asset counts (over the 79 shared cars)

| Bucket | FM4 # | FH1 # | FM4 MB | FH1 MB | Δ MB |
|---|---:|---:|---:|---:|---:|
| `carbin_main` | 77 | 77 | 161.81 | 144.56 | -17.26 |
| `carbin_lod0` | 77 | 77 | 341.21 | 273.13 | -68.09 |
| `carbin_cockpit` | 77 | 77 | 169.74 | 169.93 | +0.19 |
| `carbin_caliper` | 308 | 304 | 12.07 | 10.16 | -1.91 |
| `carbin_rotor` | 308 | 304 | 11.16 | 9.82 | -1.34 |
| `carbin_stripped` | 0 | 839 | 0.00 | 20.87 | +20.87 |
| `xds_damage` | 308 | 308 | 682.77 | 678.64 | -4.13 |
| `xds_nodamage` | 154 | 154 | 541.47 | 538.32 | -3.15 |
| `xds_lights` | 155 | 157 | 141.30 | 140.58 | -0.72 |
| `xds_interior` | 77 | 151 | 29.89 | 44.44 | +14.55 |
| `xds_normalmap` | 89 | 91 | 4.40 | 4.84 | +0.44 |
| `xds_gauge` | 197 | 190 | 5.47 | 5.36 | -0.12 |
| `tga_livery` | 406 | 406 | 38.75 | 38.80 | +0.05 |
| `physics_xml` | 77 | 76 | 0.29 | 0.28 | — |
| `physics_bin` | 0 | 77 | 0.00 | 0.18 | +0.18 |
| `xml_versiondata` | 77 | 0 | 0.11 | 0.00 | — |

Source: `probe/probe_assets.py` → `probe/out/asset_summary.tsv`.

## Cross-game equivalence (shared-name pairs)

**Configs (79 shared cars):**

| File | Both have | Byte-identical |
|---|---:|---:|
| `physics/maxdata.xml` | 76 | **74** |
| `carattribs.xml` | 77 | 1 |

**Textures (sample of 10 shared cars, 110 .xds pairs):**

| Bucket | Identical | Same-size, content differs |
|---|---:|---:|
| damage / nodamage | 37 | 23 |
| lights | 2 | 18 |
| interior | 8 | 2 |
| normalmaps (`*_NRM.xds`) | 7 | 0 |
| digital gauge | 9 | 0 |
| other | 4 | 0 |

**Cubemaps:** **not per-car**. Both games keep them as global per-track
files: `Media/tracks/<track>/staticCarCubemap.xpr` (Xbox Packed Resource
container). Both games have these.

## Global, non-per-car assets

| File | FM4 | FH1 | Format |
|---|---|---|---|
| `Database.xmplr` (root) | 13 MB | (none) | PIRS / Xbox 360 STFS package, encrypted-ish |
| `HeadPosition.xmplr` (root) | small | (none) | same family |
| `Media/db/gamedb.slt` | 6.5 MB | TBD | **SQLite database, fully labeled, 200 tables** |
| `Media/db/CarPartsList.xml` | 1.2 KB | small | template upgrade levels, labeled XML |
| `Media/physics/PI.xml` | 2.7 KB | (in `physics.zip`) | Performance Index rules, labeled XML |
| `Media/physics/CollObjects.xml` | yes | (in `physics.zip`) | global collision rules, labeled XML |
| `Media/physics/surfaceTypes.xml` | yes | (in `physics.zip`) | surface friction, labeled XML |
| `Media/physics/PhysicsSettings.ini` | yes | (in `physics.zip`) | global tuning, labeled INI |
| `Media/physics.zip` | (none) | yes | FH1 zips its global physics dir |

## Compression layer

Per-car zips are PKZip method 21 = chunked Microsoft LZX. See
`FORZA_LZX_FORMAT.md` for the framing and decode details.

The `Media/db/gamedb.slt` and root `.xmplr` files are NOT compressed by
the zip layer — they're plain on-disk files. The SQLite DB opens
directly with any sqlite3 client (Python `sqlite3` works against the FM4
file in read-only mode).

## What ports and what doesn't (FM4 → FH1)

Drop-in or near-drop-in:
- Livery masks (TGA + xml)
- Digital gauge files (bgf/bsg/fbf + xds): 9/9 identical sample
- Normalmaps (`*_NRM.xds`): 7/7 identical sample
- `physics/maxdata.xml`: ~97% byte-identical
- Build metadata files

Format-mapping required:
- `carbin` main: cvFour → cvFive transcode wired (Slice B v2,
  FM4 main TypeId 3 → FH1 TypeId 5 main). See `CARBIN_TRANSCODE.md`
  for the four byte-level deltas (stride 32→28, m_NumBoneWeights
  pre-pool block, +4 byte subsection upconvert, section-tail
  passthrough) and `FH1_CARBIN_TYPEID5.md` for the on-disk format.
- `carbin` lod0 / cockpit / caliper / rotor LOD0: Slice C — splice
  for LOD0-only sections not yet wired; donor passthrough today.
- `carattribs.xml`: Version 16 → 21, mostly cosmetic textual drift
- Lights / damage XDS: many differ — likely re-baked

Synthesis required (no FM4 source):
- `physicsdefinition.bin`: derive from FM4 `gamedb.slt` (see FH1_PHYSICS_DB.md)
- `stripped_*.carbin`: derive from full carbin (one per part)
- `interior_emissive_LOD0.xds`, `zlights*.xds`: TBD

Probe outputs that backed every number above:
`probe/out/asset_summary.tsv`, `probe/out/asset_diff/<car>.txt`,
`probe/out/texture_eq.tsv`, `probe/out/diff/<car>/`.
