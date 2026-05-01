# Applet Architecture (Locked)

This is the canonical reference for what we're building. Supersedes the
sketch in earlier docs and chat iterations. Format and stack decisions
below are committed; everything beyond is implementation detail.

## Mental model

`working/` is **the main screen and the canonical workspace.** Each car
in `working/` is a self-contained, neutral, edit-friendly tree (cracked
glTF + sidecar + supporting files). Players port a car *into* `working/`,
edit it, then export it *out* to one or more games.

The per-game tabs are essentially **file managers** layered on top of
each game's `cars/` folder. Their job is to let you browse a game's car
archives and pull one into `working/`. Reverse direction (working →
game) is done via the export button on the working car, not by dragging
back to a game tab.

```
        ┌───────────────────────────┐
        │  working/  (main screen)  │
        │    cracked glTF cars      │
        └─┬───────────────────────┬─┘
   import │                       │ export (1+ targets)
          │                       │
   ┌──────┴──────┐         ┌──────┴──────┐
   │  game tab   │         │  game tab   │
   │  (FM4)      │         │  (FH1)      │
   │  file mgr   │         │  file mgr   │
   └─────────────┘         └─────────────┘
```

A car in working is **neutral** — it's not "FM4 form" or "FH1 form" until
the moment it's exported to a game. There's exactly one tile per car in
the working grid regardless of how many games it can target.

## Stack (locked)

| Layer | Choice |
|---|---|
| Language | **Nim** |
| Window / input / GPU | **SDL3 + sdl_gpu** (we have working bindings + shaders ready to adapt) |
| UI widgets | **SDL3-native** — hand-rolled on top of SDL3 input + sdl_gpu draw. No third-party UI library. (Pattern carries over from prior SDL3 UI work.) |
| LZX (read + write) | **libmspack** (`lzxd.c` + `lzxc.c`), already vendored |
| glTF (read + write) | **cgltf** (single-header C) |
| BC texture decode | **bcdec** (single-header C) |
| BC1/5 encode | **stb_dxt.h** (single-header C) |
| SQLite (gamedb.slt) | **`db_sqlite`** (Nim stdlib) |
| Math | **vmath** or hand-rolled |

All native deps vendored under `vendor/`. Existing `download-deps.sh`
gets extended to fetch each. No git submodules.

## Working format — cracked glTF

```
working/<slug>/
├── carslot.json                # manifest (origin game, exportTargets, donors, db edits)
├── car.gltf                    # editable scene (open in Blender / any DCC)
├── car.bin                     # glTF buffers
├── car.sidecar.json            # bytes glTF can't represent (per-game)
├── geometry/                   # original .carbin files, untouched
│   ├── main.carbin
│   ├── lod0.carbin
│   ├── cockpit.carbin
│   ├── caliper_LF.carbin / _LR / _RF / _RR
│   └── rotor_LF.carbin / _LR / _RF / _RR
├── textures/
│   ├── damage_LOD0.png         # decoded for editing
│   ├── damage_LOD0.xds         # original kept for re-encode reference
│   └── ...
├── livery/                     # tga + masks.xml — drop-in
├── digitalgauge/               # bgf/bsg/fbf + xds — drop-in
├── physics.xml                 # = maxdata.xml; ~identical FM4↔FH1
├── carattribs.xml
└── shadersettings.xml
```

**Slug convention:** `<CarName>` (no per-game suffix). The car is neutral.
The `originGame` lives in the manifest, not the directory name.

### `carslot.json`

```jsonc
{
  "schemaVersion": 2,
  "name": "ALF_8C_08",
  "originGame": "fh1",
  "exportTargets": ["fm4", "fh1"],   // games this car can target
  "donors": {                        // per target, which donor's bytes to inherit
    "fm4": "ALF_8C_08",              //   (for fields we don't represent in glTF)
    "fh1": "ALF_8C_08"
  },
  "stats": {
    "CurbWeight": 1410.0,
    "WeightDistribution": 0.51,
    "NumGears": 6,
    "...": "..."                      // one set of values; applied to every export target
  },
  "edits": [
    {"ts": "2026-04-30T18:30Z", "kind": "geometry", "note": "scion->gt86 badge swap"}
  ]
}
```

One `stats` block — the same values are folded into every export target's
DB. If a player wants different tunings per game, they make a copy of
the working car (e.g. `ALF_8C_08-track`, `ALF_8C_08-street`) and edit
each.

### `car.sidecar.json`

Per-game blocks for the format-specific bytes glTF doesn't carry:

```jsonc
{
  "schemaVersion": 2,
  "carbins": {
    "main": {
      "perGame": {
        "fm4": { "typeId": 2, "headerBytes": "<base64>", "tailTable": "<base64>" },
        "fh1": { "typeId": 5, "headerBytes": "<base64>", "middleExpansion": "<base64>", "tailTable": "<base64>" }
      }
    },
    "lod0": { "perGame": { ... } },
    "cockpit": { "perGame": { ... } },
    "caliperLF": { ... }, "caliperLR": { ... }, "caliperRF": { ... }, "caliperRR": { ... },
    "rotorLF": { ... },   "rotorLR": { ... },   "rotorRF": { ... },   "rotorRR": { ... }
  },
  "vertices": {
    "main:bumperRA:LOD0": { "extra8": "<base64 = vertexCount * 8>" }
  },
  "subsections": {
    "main:bumperRA:LOD0:body_paint": {
      "uvScale": [1.0, 1.0], "uvOffset": [0.0, 0.0],
      "uv2Scale": [1.0, 1.0], "uv2Offset": [0.0, 0.0]
    }
  },
  "indexEncoding": {
    "main:bumperRA:LOD0:body_paint": { "type": "TriStrip", "size": 2 }
  }
}
```

Bundling for FM4 reads `perGame.fm4`; bundling for FH1 reads `perGame.fh1`.
If the user imported from FH1 and is now exporting to FM4, `perGame.fm4`
is missing — we synthesize it from the FM4 donor's bytes during port.

## What `GameProfile` is for

The applet supports an extensible set of games. **`GameProfile` is the
single struct that captures every per-game quirk** so the orchestrator
and codecs branch on data, not hardcoded enums. Adding a new game = add
one `GameProfile` (JSON, hot-loadable), implement whatever transcoder
its TypeId/version differences need. No new UI code, no recompile of
the core.

```nim
type
  GameId = string  # "fm2" | "fm3" | "fm4" | "fh1" | "fh2" | future

  GameProfile = object
    id: GameId
    displayName: string         # "Forza Motorsport 4"
    titleId: string             # "4D530910"
    contentId: string           # "33E7B39F"
    cars: RelativePath          # "Media/cars" or "media/cars"
    casing: enum Lower, Mixed   # how member names are cased

    # Carbin format
    carbinTypeId: int           # 2 / 3 / 5 / ...
    carbinHeaderLen: int        # 0x398 / 0x4DC / ...

    # Asset expectations on this game's archives
    requiresStripped: bool      # FH1+ true, FM* false
    requiresPhysicsBin: bool    # FH-line true
    requiresVersionData: bool   # FM4 true (so far)
    extraXdsBuckets: seq[string]  # ["interior_emissive_LOD0", "zlights"] for FH1

    # Database
    gamedbPath: RelativePath    # "Media/db/gamedb.slt"
    dbStrategy: enum            # SqlitePatch (FM4) | PerCarBin (FH1) | DatabaseXmplr (FM3?)

    # Subformats
    indexBufferVersion: int     # 3 / 4 / 5
    colVersion: int             # 2 / 4
    rmbBinVersion: int          # 4 / 6

    # Capabilities
    canUnbundle: bool           # if false, profile is import-only stub
    canBundle: bool             # if false, profile is read-only
```

**Why this matters for the user-visible experience:**

- A new tab can be added without recompiling the binary — drop a profile
  JSON next to the binary, restart, browse to the game folder.
- Profiles can be **partial**: ship FM4 + FH1 with full bundle/unbundle
  in v1; ship FM2/FM3/FH2 as `canUnbundle=true, canBundle=false` stubs
  that let the user *import* cars but not (yet) export to them. The UI
  greys out the unsupported export buttons.
- Auto-detect: when the user mounts a game folder via `[+]`, we match
  its TitleID against profile JSONs to pick the right one. Manual
  override available.

Profiles ship under `profiles/<game>.json` next to the binary.

## UI layout

`working/` dominates. Game tabs are auxiliary panes for loading.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ ┌─[FM2]─┬─[FM3]─┬─[FM4]─┬─[FH1]─┬─[FH2]─┬─[+]─┐  Settings  ?                │   ← top tab strip
│ └───────┴───────┴───────┴───────┴───────┴─────┘                             │     (scrollable, per game)
├─────────────────────────────────────────────────────────────────────────────┤
│  GAME LIBRARY (active tab) — file manager view of the game's cars/          │
│                                                                             │
│  ALF_8C_08             [right-click → Import to Working / Diff / Show in OS]│
│  AST_DBR1_58           [...]                                                │
│  ...                                                                        │
│                                                                             │
│  (~25% of vertical space; scrollable)                                       │
├═════════════════════════════════════════════════════════════════════════════┤
│ T │  WORKING/  (main screen, dominant)              │   PARTS              │
│ O │                                                 │ ┌──────────────────┐ │
│ O │ ┌─[ALF_8C_08]─┐ ┌─[BMW_M3E30_91]─┐ ┌─[+ New]─┐  │ │ body         👁  │ │
│ L │ │   selected  │ │                │ │  ...   │  │ │ hooda        👁  │ │
│ B │ └─────────────┘ └────────────────┘ └────────┘  │ │ bumperFa  ▾  👁  │ │
│ A │                                                 │ │  └ bumperFrace   │ │
│ R │ ┌────────────────────────────────────────────┐  │ │ bumperRa     👁  │ │
│ S │ │  3D PREVIEW (sdl_gpu)                      │  │ │ wing      ▾  👁  │ │
│   │ │     <render of selected working car>       │  │ │  └ wingrace      │ │
│   │ │  [Wireframe] [Damage] [Cubemap ▾]          │  │ │ taillightL   👁  │ │
│   │ └────────────────────────────────────────────┘  │ │ taillightR   👁  │ │
│   │   ↑ drop OBJ/glTF here = replace ALL parts      │ │ wheel        👁  │ │
│   │                                                 │ │ ... (scrollable) │ │
│   │ Origin: FH1                                     │ └──────────────────┘ │
│   │ Export targets: ☑FM4 ☑FH1 ☐FH2                  │  ↑ drop onto a row   │
│   │ [Export...] [Replace donor...] [Open glTF ext]  │   = replace 1 part   │
├─────────────────────────────────────────────────────────────────────────────┤
│  STATS DRAWER (collapsed/expanded by chevron, expands UPWARD)               │
│  ┌──[Engine]──[Drivetrain]──[Suspension]──[Aero]──[Tires]──[Body]──┐        │
│  │  CurbWeight        [1410.0      ] kg    (FM4 stock: 1395.0)     │        │
│  │  WeightDistribution[0.51         ]      (FM4 stock: 0.50)       │        │
│  │  NumGears          [6            ]                              │        │
│  │  ...                                                            │        │
│  │  [Reset to FM4 stock]  [Reset to FH1 stock]  [Reset all]        │        │
│  └─────────────────────────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Top tab strip
- Toggleable, scrollable horizontally if many games are mounted.
- Each tab corresponds to a mounted GameProfile. Toggling off
  unmounts/hides; doesn't delete profile.
- `[+]` button opens **auto-detect + manual** mount flow:
  - Folder picker → walk known structure (look for `<TitleID>/00007000/<ContentID>/Media/cars`)
  - Match TitleID against `profiles/*.json`
  - If matched: mount automatically.
  - If unmatched: open profile-picker dropdown showing all known profiles,
    user confirms.
- `Settings`, `?` are pinned (don't scroll out).

### Game library pane (active tab)
- Scrollable list of car archives in that game.
- Right-click any car (or focused row + Enter):
  - **Import to Working** (canonical action — copies into working/, sets `originGame` and per-game sidecar block)
  - Open (read-only inspect)
  - Diff against working/<same-name> (if exists)
  - Show in OS file manager
- Drag-drop a car onto the working area below = same as Import to Working.
  Drag-drop is **one-way only**: game → working. Reverse is via Export button.

### Working/ pane (main)
- Tile grid of working cars.
- Selecting a tile populates: 3D preview + export controls + stats drawer.
- "+ New Car" tile opens a submenu:
  - Pick base car from any mounted game (searchable dropdown across all mounts).
  - Choose initial export targets (toggle buttons).
  - Optional: import OBJ / glTF here to seed (we transcode OBJ → glTF if needed).
  - Creates working dir.

### 3D preview (center, when a working car is selected)
- sdl_gpu render: textured car, simple lights, cubemap reflection (per-track XPR).
- Damage slider (placeholder until damage RE — visual lerp to a placeholder mesh).
- Wireframe toggle.
- Cubemap selector (browses per-track XPRs from any mounted game's `tracks/`).
- **Drop target for whole-car replacement.** Drag an `.obj` or `.gltf`
  onto the 3D viewport itself = "replace every part with the dropped
  geometry". Used for porting an external car or starting a new car
  from a single mesh:
  - **OBJ** drop: one mesh → goes into the donor's `body` section.
    Every other section (wheel, calipers, rotors, glass, lights,
    bumpers, etc.) keeps its donor bytes intact so the game still has
    a working physics+visual stack. Result is the dropped body welded
    onto the donor's running gear.
  - **glTF** drop: one or more meshes. We *do not* auto-name. The user
    is responsible for naming each mesh in their glTF to match a
    donor section name (`body`, `hooda`, `bumperFa`, `taillightL`,
    etc.) — anything that doesn't match a section name is dropped on
    the floor with a warning. Section names users care about are
    listed in the Parts panel (right side, below).
- Single-mesh drag-drop onto the **viewport** is destructive (replaces
  all matching parts). Drop onto a **part-row in the Parts panel**
  (next section) for surgical per-part replacement.

### Parts panel (right side, below tool hotbar)
- One row per **section** in the donor's main carbin (`body`, `hooda`,
  `bumperFa`, `taillightL`, `wheel`, ...). Names match what the game
  runtime expects for physics / paint / damage routing — renaming
  breaks game integration.
- Each row shows: section name, vertex count, modified badge
  (`original` / `modified`), eye toggle (show/hide in viewport).
- Each row has a **variants dropdown** when the donor has alternates
  for that part (e.g., `bumperFa` row has `bumperFrace` listed under
  it as an alternate; `wing` row may list `wingrace`). Picking a
  variant from the dropdown swaps which alternate is the "active"
  one — both bytes still ride through to export, only the active one
  shows in the viewport.
- **Drag an OBJ/glTF onto a row** = replace just that part's
  geometry. The applet re-encodes the affected section in the
  donor's main / lod0 / cockpit carbins (decimating LODs as
  needed) and refreshes the viewport.
- **Right-click a row** for: *Replace…*, *Export part as .glb*,
  *Revert to donor*, *Show only this part*.
- Glasses, bumpers, lights, mirrors etc. that come in left/right
  pairs are listed as separate rows (they're separate sections in
  the carbin). The applet does not auto-mirror an edit between L/R —
  the user replaces each side explicitly.

### Export button (under preview)
- Press → opens Export sub-dialog:
  - Confirm name (defaults to `<slug>`, can rename per target if user wants
    to write a tagged variant).
  - Show overwrite-confirm if a car of that name already exists in target's `cars/`.
  - Display the toggled targets ☑/☐ for confirmation.
- Press [Confirm] → writes archives to chosen targets, applies stats to
  each target's DB per its `dbStrategy`, atomic (with `.bak` of the
  game's gamedb.slt).
- Multi-target export = same dialog, multiple writes, single transaction
  semantics where possible.

### Stats drawer (bottom, expands upward)
- One set of values per car. Stat names mirror gamedb.slt schema buckets
  (Engine / Drivetrain / Suspension / Aero / Tires / Body).
- Per-field "stock" badge for each export target showing what that game's
  DB currently has → user sees the diff at a glance.
- **No per-game value editing here.** A copy of the working car gives the
  user a fresh tile to retune.
- Reset buttons restore stock values from a chosen target.
- Folding into multiple games' DBs uses the export-targets toggle (in the
  pane above, not in the drawer) — same toggle drives both archive
  writes and DB writes.

## Operation contracts

The orchestrator exposes six core ops. Each is a flat function on data;
no global state.

| Op | Signature | Notes |
|---|---|---|
| `mountGame(folder)` | → GameProfile, [errors] | Auto-detect + manual fallback. Adds a tab. |
| `scanLibrary(profile)` | → seq[CarSlot] | Walks profile's cars dir; cheap (cdir only). |
| `importToWorking(slot, profile)` | → WorkingCar (on disk under `working/`) | LZX-decompress → carbin parse → glTF emit + sidecar write + textures decoded. |
| `exportFromWorking(workingCar, target: GameProfile, donor: CarSlot, opts)` | → archive bytes + db patch ops | Reads glTF + sidecar + donor bytes; emits archive + planned DB ops. |
| `writeArchive(bytes, profile, name, overwrite: bool)` | → side effect | Atomic. |
| `applyDbPatch(ops, profile)` | → side effect | Strategy per profile. Always with `.bak`. |

`exportFromWorking` and the two writers are kept separate so the dialog
can preview the planned changes before committing.

## Database editing per game

Per `GameProfile.dbStrategy`:

| Strategy | Used by | Mechanism |
|---|---|---|
| `SqlitePatch` | FM4 | Open `Media/db/gamedb.slt`, patch `Data_Car`, `Data_Engine`, list tables in transaction, backup `.bak`. |
| `PerCarBin` | FH1 | Synthesize/overwrite `physicsdefinition.bin` in the per-car archive. The DB file may also exist; if it does, treat as authoritative for read-only fields. |
| `DatabaseXmplr` | FM3 (TBD) | Decode the PIRS/STFS package, patch, repack. Highest-effort strategy. |
| `Unsupported` | stub profiles | Stat edits ignored on export to that target. UI marks the target's DB toggle disabled. |

Backup policy: **every** export that writes to a DB makes a timestamped
`.bak` next to the original. Restore via Settings → Backups.

## Phase plan (revised, locked)

See `ROADMAP.md` for the live status snapshot and what's currently
done / in progress. The phases below are the architectural target; the
roadmap captures the actual sequencing (which has reordered Phase 2
texture work ahead of Phase 2 export work).

**Phase 1 — Core libraries + FM4 read-only:**
- Port Soulbrix's `fm4carbin/` to Nim → `core/carbin/`.
- Wire libmspack (read), cgltf (read+write), bcdec (read), stb_dxt (write later).
- Define `GameProfile` schema, ship `profiles/fm4.json`.
- Implement `mountGame`, `scanLibrary`, `importToWorking` for FM4.
- CLI: `forza-tool list <game>`, `import <car>`.

**Phase 2 — FH1 profile + bidirectional export + textures:**
- 2a — FH1 import (TypeId 5 parser + cvFive section deltas).
- 2b — FM4 ↔ FH1 transcode + LZX `lzxc` write + `exportFromWorking`
  for both games. `physicsdefinition.bin` synthesizer (gated on SQL→
  bin RE in `FH1_PHYSICS_DB.md`). `stripped_*.carbin` synthesizer. CLI
  `forza-tool export <car> --target fm4|fh1`.
- 2c — Textures: .xds → PNG (decode), per-subsection UV bake into
  glTF, name-prefix material resolver. PNG → BC + Xenon retile is the
  re-encode-on-edit path.

**Phase 2.5 — CLI safety layer (added 2026-05-01):**
Pre-UI primitives that get the data model and safety guarantees right
without the SDL3 surface. The UI later replays these same ops under
buttons.
- `list <game-folder>` — scan a game's `cars/`, print archives + size +
  detected profile / TitleID. Pure read.
- `mount <game-folder>` / `mounts` — register folder + auto-detected
  profile in `~/.config/carbin-garage/mounts.json`. Subsequent commands
  take game-id instead of paths.
- `export-to <working-car> <game-id> [--name <slug>] [--dry-run]` —
  atomic write with `.bak`, refuses to overwrite if `.bak` already
  exists, `--dry-run` surfaces planned writes.

**Phase 3 — UI shell (SDL3-native + sdl_gpu, no 3D yet):**
- Three-zone layout (top tabs, game library, working/, stats drawer).
- Mount/unmount flow with auto-detect.
- Tile grid, drag-drop import, right-click menus.
- Export sub-dialog.
- Stats drawer (read-only view first).

**Phase 4 — UI 3D preview + stats edit:**
- sdl_gpu render of selected working car.
- Texture preview.
- Damage slider (placeholder geometry until RE).
- Stats drawer becomes editable; export pushes both archive and DB ops.

**Phase 5 — extra game profiles:**
- FM2, FM3, FH2 stubs first (read-only). Then bundle support per game as
  format work completes.

**Phase 6 — damage models RE:**
- Crack the FM4 tail table / `extra8` to reveal panel-deformation data.
- Drive the damage slider with real geometry.

**Phase 7 — cubemap rendering:**
- `.xpr` decoder (Xbox Packed Resource).
- Reflection probe in the 3D viewer.

## Out of scope (deliberately)

- USD / FBX / Collada — glTF is enough.
- Custom shader authoring — passthrough only via `shadersettings.xml` and
  `.fxobj` references.
- Multiplayer / live-game integration.
- Cars-folder versioning beyond `.bak` of DBs and atomic archive writes.

## Open RE items, not blocking the architecture

These are tracked but won't block applet shipping. Each is a focused
follow-up the architecture absorbs cleanly:

1. FH1 `physicsdefinition.bin` schema (gates Phase 2 export to FH1 with stat changes).
2. FM3 / FM2 / FH2 profile specifics (gate Phase 5).
3. FM4 tail table / `extra8` damage encoding (gates Phase 6).
4. `.xpr` cubemap container (gates Phase 7).
5. `Database.xmplr` (FM4 root file) decode — likely needed if any
   per-car field lives there rather than in `gamedb.slt`. Verify.

## Glossary

- **Cracked glTF**: working format = glTF main file + JSON sidecar +
  supporting files in a directory. Editable in DCCs and shell tools.
- **Donor**: a real car archive in a target game whose untouched bytes
  fill in the slots our working car doesn't represent (e.g. FH1
  `physicsdefinition.bin` if the working car came from FM4). User
  picks the donor explicitly at export time when the target game has
  no existing copy of the car — "close enough" chassis (e.g.
  Murciélago donor for a ported Gallardo, Raptor donor for a new
  pickup). The donor's per-car bin is copied verbatim into the new
  archive and the donor's SQL row is the patch template; we
  deliberately do **not** synthesize a fresh `physicsdefinition.bin`.
  See `FH1_PHYSICSDEFINITION_BIN.md` §"Donor-bin strategy".
- **GameProfile**: the data struct + JSON describing one game's quirks;
  drives every codec/orchestrator branch.
- **Mount**: the user telling the applet where a game's folder lives.
  Adds a tab.
- **Slug**: the working car's directory name. Equals the car's neutral
  name; no per-game suffix.
