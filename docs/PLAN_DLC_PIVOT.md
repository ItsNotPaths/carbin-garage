---
status: authoritative-roadmap
created: 2026-05-01
context: cross-game `port-to` blocked by undecodable SQL chain in base gamedb;
         DLC packaging is the working modding path for adding new cars
---

# DLC pivot — cross-game ports become DLC packages

## TL;DR

- **Same-game car modification (`export-to`)**: keep the existing direct-write approach.
  Direct edits to `media/cars/<MediaName>.zip` and `gamedb.slt` work for editing
  cars that already exist in the target game. **No change.**

- **Cross-game ports (`port-to`)**: pivot to DLC packaging. Direct DB edits hit
  an undecodable SQL chain (engine-name lookup returns SQL CE error string
  `"Attempt to access invalid field or record"` substituted into asset paths)
  that we couldn't reverse-engineer from logs alone after extensive cloning of
  30+ tables. Working car-add mods package as DLC and the mechanism cleanly
  bypasses this chain.

- **UX is unchanged.** User runs `port-to` and the new car appears in Autoshow
  flat alongside base-game cars. The DLC mechanic is implementation detail —
  no DLC-named flags, paths, or UI strings.

## What we learned (this session, 2026-05-01)

### Things that work (keep them)

1. **xex integrity-bypass patcher** — `core/xex2/*` + `orchestrator/patchxex.nim`.
   Idempotent, byte-equal to community-patched reference. **Required for
   editing `gamedb.slt` in same-game `export-to`.** Not required for DLC path
   (DLC content isn't integrity-checked the same way).
2. **carbin parser + same-game export-to** — works.
3. **Texture port plan** — `core/texture_port.nim` validated 16/16 structural.
4. **Mixed-method zip writer** — `core/zip21_writer.nim` works for same-game.
5. **0x1123 extra field encoding** — discovered FH1's zip21 reader requires
   per-CDH-entry `<header_id=0x1123, len=4, value=cdata_offset>` extra field.
   Without it, m=21 LZX entries can't be located. Confirmed via byte-diff vs
   donor zip. **The current `rewriteZipMixedMethod` drops this field on emit
   — must be fixed for both `export-to` and `port-to`.**

### Things we tried that DIDN'T solve cross-game ports

Across multiple test cycles, these were applied and the post-purchase
open-world load STILL crashed (grey screen, 0 RPM, instant gear-up, controller
vibration spam):

- Created `cars/<NewName>.zip` and `wheels/<NewName>.zip` via mixed-method writer
- Patched `zipmanifest.xml` with new entries (alphabetical order, correct
  `dirstart`/`dirsize`/`direntries` with EOCD-inclusive size convention)
- Added `0x1123` extra field to every CDH entry
- Cloned 14 chassis tables (`Ordinal=DataCar.Id` rows): CarPartPositions,
  List_AntiSwayPhysics, List_SpringDamperPhysics, all UpgradeAntiSway/Brakes/
  CarBody/Drivetrain/RearWing/RimSize/SpringDamper/TireCompound, Combo_Colors
- Cloned 15 engine upgrade tables at `EngineID = donor.Data_Car.Id` (e.g. 1032)
- Cloned 15 engine upgrade tables at `EngineID = donor.Data_Engine.EngineID` (474)
- Inserted `Combo_Engines` row at `Ordinal=NewEngineID` matching donor's
  `(Ordinal, EngineID, Stock)` pattern (offset=246 in 311/312 base rows)
- Set `Data_Engine.MediaName` to share donor's audio identity
- Cleaned a duplicate-Ordinal row I'd accidentally created in
  `List_UpgradeEngine` (had Ordinal=1032 AND EngineID=1036)
- Inserted `CarExceptions` row (silent insert failure earlier)

**The undecodable failure**: the audio engine init code does a query that for
our new car returns 0 rows, the SQL CE error string substitutes into the path
template, and the renderer/audio pipeline tears globally. We could not
identify the offending join from Xenia logs (logs show resolved paths only,
not SQL queries). Working symptoms: Autoshow renders, purchase + color picker
work; **fail mode triggers on open-world spawn**.

### DLC architecture (decoded from sample at
`xenia_canary_windows/content/0000000000000000/4D5309C9/00000002/4D5309C900000729`)

```
<package_root>/
├── Media/
│   ├── 729.puboffer                    # marker file (~0 bytes; identifies DLC)
│   └── DLCZips/
│       ├── zipmount.xml                # <-- declares all mount points
│       ├── 729_pri_99.zip              # main overlay (also extracted to dir)
│       ├── 729_pri_99/                 # extracted version
│       │   └── Media/
│       │       └── db/
│       │           └── patch/
│       │               └── 72900_merge.slt   # <-- 56-table partial gamedb
│       │       └── audio/cars/Engines/Soundbanks/LOD1/...
│       ├── CarModelTuning_pri_729/     # loose <MediaName>_CMT.xml files
│       ├── EngineTuning_pri_729/       # loose <MediaName>_ET.xml files
│       ├── LOD1_pri_729/               # loose .fsb engine soundbanks
│       ├── StringTables_pri_99729/     # localized strings per language
│       ├── cameras_pri_729.zip         # camera defs
│       └── stringtables.xml
```

Sample `zipmount.xml`:
```xml
<zipmount>
   <zip Name="cameras_pri_729.zip"        Mount="game:\Media\cars\shared\cameras\"      AltRootPath="..." ShouldCache="0"/>
   <zip Name="StringTables_pri_99729"     Mount="game:\Media\StringTables\"             AltRootPath="..." ShouldCache="0"/>
   <zip Name="CarModelTuning_pri_729"     Mount="game:\Media\audio\cars\CarModelTuning\" ...                ShouldCache="0"/>
   <zip Name="EngineTuning_pri_729"       Mount="game:\Media\audio\cars\Engines\EngineTuning\" ...           ShouldCache="0"/>
   <zip Name="LOD1_pri_729"               Mount="game:\Media\audio\cars\Engines\Soundbanks\LOD1\" ...        ShouldCache="0"/>
</zipmount>
```

The `_pri_<NNN>` suffix in directory/zip names encodes priority. The DB merge
file uses `<DLC_id>00_merge.slt` naming (e.g. `72900_merge.slt` for DLC id 729).

**merge.slt schema parity**: identical to gamedb.slt (Data_Car: 126 cols both).
The 56 tables it covers are the per-car-data subset of gamedb's 221 tables.
Critical tables our cloning missed:
- `List_TorqueCurve` (per-car torque curves — explains the 0-RPM stall)
- `Data_CarBody`, `Data_Drivetrain`, `List_AeroPhysics`
- `List_UpgradeCarBodyChassisStiffness/FrontBumper/Hood/RearBumper/SideSkirt/TireWidthFront/TireWidthRear/Weight`
- `List_UpgradeDrivetrainClutch/Differential/Driveline/Transmission`
- `List_UpgradeEngineDSC/RestrictorPlate/TurboTwin`
- `List_CarMake`

**Sample DLC car PK convention** (from FER_575_02 in the example DLC):
- `Data_Car.Id = 257`
- `Data_Engine.EngineID = 11` — independent ID space, NOT car-id-based
- `List_UpgradeEngineCamshaft.EngineID = 11` — single semantics (matches
  Data_Engine.EngineID only). **Donor's dual-overload pattern (rows at both
  Data_Car.Id 1032 AND Data_Engine.EngineID 474) is base-game artifact only.**
  DLCs use clean single semantics — that's likely why our cross-clone broke
  some queries.
- `List_TorqueCurve.TorqueCurveID = 11000, 11002, 11003` — encodes engine ID
  with Level suffix (000, 002, 003 mirror Camshaft Level values).

The example DLC (id 729) has 113 cars but **no per-car `cars\<MediaName>.zip`
or `wheels\<MediaName>.zip`** — it's an audio/paint/data-only pack reskinning
existing base-game art. A real car-add DLC (with new geometry) would
additionally include those zips, mounted via zipmount entries.

### Why this fixes the SQL chain mystery

The SQL CE error string substitution suggests the engine-name lookup queries
the **merged DB view** (base + all merge.slt files) through a code path that's
distinct from how same-game cars work. Direct edits to gamedb.slt may bypass
merge bookkeeping (in-memory indices, FK chain caches) that the audio
subsystem expects. By placing rows in a merge.slt the way DLCs do, we use the
proven loading path that 100+ DLC cars exercise daily.

## Implementation plan

### Phase A — preserve same-game `export-to` (no work; sanity-check)

Same-game `export-to` (modifying a car already in the target) keeps the
direct-write approach that already works. No code changes here. Sanity-check
the `0x1123` extra field fix lands in `core/zip21_writer.nim` so future
emissions don't drop it.

### Phase B — refactor `port-to` to emit a DLC package

**New emission target**: `xenia_canary_windows/content/<profile_id>/<TitleID>/00000002/<package_id>/`

`<profile_id>` = `0000000000000000` (default no-profile DLC slot — the example
DLC lives here) or the user's actual profile id (`B13EBABEBABEBABE` in this
install). DLCs in `0000000000000000` apply globally.

`<package_id>` = synthesized from new car's slug, e.g. `4D5309C9CG000001` (use a
deterministic hash of the new car's name to avoid collisions across multiple
ports).

#### Steps

1. **Profile discovery**: scan `xenia_canary_windows/content/` for
   `<profile_id>/<TitleID>/00000002/` directories. If 00000002 doesn't exist
   under `0000000000000000`, create it.

2. **Package id allocation**: deterministic from new car's slug. Avoid
   collisions with existing DLCs in `00000002/`.

3. **Write package tree**:
   ```
   <package_id>/
   ├── Media/
   │   ├── <package_id>.puboffer        # empty file or minimal XML
   │   └── DLCZips/
   │       ├── zipmount.xml
   │       ├── <package_id>_pri_99/
   │       │   └── Media/db/patch/<package_id>00_merge.slt
   │       ├── cars_pri_<package_id>/<MediaName>.zip      # geometry
   │       ├── wheels_pri_<package_id>/<MediaName>.zip    # wheels
   │       ├── CarModelTuning_pri_<package_id>/<MediaName>_CMT.xml
   │       └── EngineTuning_pri_<package_id>/<MediaName>_ET.xml
   ```
   Note: zipmount.xml mount targets must match base game paths
   (`game:\Media\cars\`, `game:\Media\wheels\`, etc.). Cross-reference base
   game's existing dirs.

4. **Build merge.slt**: new SQLite file with the 56-table subset. For each
   new car, insert rows in:
   - Data_Car (with new car's MediaName, BaseCost, etc.)
   - Data_Engine (with `EngineID` allocated from a DLC ID space — NOT
     auto-incremented from gamedb)
   - Data_CarBody, Data_Drivetrain, List_AeroPhysics
   - All List_Upgrade* tables (single-semantics: `EngineID = Data_Engine.EngineID`)
   - List_TorqueCurve (per-car torque curve rows; PK convention `<EngineID>000`,
     `<EngineID>002`, `<EngineID>003`)
   - Combo_Engines (with offset=246 from Ordinal)
   - List_CarMake (only if introducing new manufacturer)
   - CameraOverrides, CarExceptions, CarPartPositions, Combo_Colors
   - List_AntiSwayPhysics, List_SpringDamperPhysics
   - The various UpgradeCarBody* / UpgradeDrivetrain* / UpgradeEngine* variants

5. **Auxiliary XMLs**: emit `<MediaName>_CMT.xml` and `<MediaName>_ET.xml`
   — start with donor's verbatim copies (or template stubs) until we have a
   reason to author new ones. Donor's CMT/ET will give donor's audio.

6. **Geometry zip**: same content as the current `port-to` emission for
   `cars/<MediaName>.zip`, but written into the DLC tree's
   `cars_pri_<package_id>/` dir and mounted via zipmount.xml. **Make sure the
   `0x1123` extra field is included** — that fix applies here.

7. **Wheels zip**: copy donor's `media/wheels/<donor>.zip` with internal
   carbin renamed to `<MediaName>.carbin` (same logic that worked
   structurally during the failed direct-edit test).

8. **Don't touch base-game gamedb.slt or zipmanifest.xml** in the `port-to`
   path. (Same-game `export-to` still touches gamedb.slt as before.)

### Phase C — UX hiding

CLI surface stays:
```
import <car.zip> --out working/
export-to <slug> <game-id>                                 # same-game
port-to  <slug> <game-id> --donor <slug> [--name <slug>] [--dry-run]
```

No `--dlc`, no `--package-id`, no DLC-named paths in user-facing output. Logs
in `port-to` should report: "writes geometry/wheels zips, transcodes 11
carbins, inserts 6 DB rows + N supporting rows, …" — describe outcomes, not
DLC plumbing.

### Phase D — cleanup utility

`port-to --uninstall <slug>` removes the DLC package directory cleanly. Useful
during iteration.

## Cleanup needed BEFORE resuming

The current FH1 install at
`/run/media/paths/SSS-Games/fh1-xex/4D5309C9/00007000/2DC7007B/` is dirty from
extensive direct DB and asset edits. Before working the new path:

1. **Delete failed-port artifacts** (in `media/cars/` and `media/wheels/`):
   - `cars/ALF_8C_08_FM4.zip` and its `.m0bak`, `.preextrafield.bak`
   - `wheels/ALF_8C_08_FM4.zip` and its `.preextrafield.bak`

2. **Restore zipmanifest.xml** from `media/zipmanifest.xml.preport.bak`.

3. **Roll back gamedb.slt rows**:
   - `DELETE FROM Data_Car WHERE Id=1569;`
   - `DELETE FROM Data_Engine WHERE EngineID=1036;`
   - `DELETE FROM List_Wheels WHERE MediaName='ALF_8C_08_FM4';`
   - `DELETE FROM CameraOverrides WHERE CarId=1569;`
   - `DELETE FROM E3Drivers WHERE CarId=1569;`
   - `DELETE FROM CarExceptions WHERE CarID=1569;`
   - `DELETE FROM Combo_Engines WHERE Ordinal=1036;`
   - For every table in the chassis-clone list (CarPartPositions,
     List_AntiSwayPhysics, List_SpringDamperPhysics, List_UpgradeAntiSwayFront/
     Rear, List_UpgradeBrakes, List_UpgradeCarBody, List_UpgradeDrivetrain,
     List_UpgradeRearWing, List_UpgradeRimSizeFront/Rear, List_UpgradeSpringDamper,
     List_UpgradeTireCompound, Combo_Colors): `DELETE WHERE Ordinal=1569;`
   - For every engine-upgrade table (List_UpgradeEngine{,CSC,Camshaft,
     Displacement,Exhaust,Flywheel,FuelSystem,Ignition,Intake,Intercooler,
     Manifold,OilCooling,PistonsCompression,TurboSingle,Valves}):
     `DELETE WHERE EngineID=1569 OR EngineID=1036;`
   - Sanity-restore donor's `Data_Car[1032].BaseCost` if changed.

4. **Restore VW Corrado base cost** if the user wants
   (we set `VW_Corrado_95` BaseCost to 200_000_000 — leave alone if intentional).

5. **xex stays patched** — `default.xex` patch remains useful for any future
   same-game `export-to`. The `.vanillabak` is preserved if rollback ever
   wanted.

## Open questions for next session

1. **DLC package id format**: must be `<TitleID-as-hex><DLC-id-as-hex>` (e.g.
   `4D5309C900000729`)? Need to verify Xenia's DLC mounting rules — specific
   filename pattern probably required.
2. **`.puboffer` content**: example file is ~empty in the sample DLC; is it
   purely a marker, or does it contain XML the game parses? Examine bytes.
3. **Headers dir**: does our DLC need a `Headers/` subdir like the game install
   has, with header metadata? Inspect the sample DLC for a parallel.
4. **merge.slt FK ID allocation**: pick a per-DLC ID range that doesn't
   collide with base game (base uses 0..~5000 for Data_Car.Id; DLC 729 uses
   257, 283, 286 — overlapping with base). Test whether merge IDs override
   base or coexist.
5. **Per-language StringTables**: do new cars need DisplayName entries? Or
   does the merge.slt's resource-id (`_&NNNNN`) lookup degrade gracefully?
6. **Audio CMT/ET templates**: try donor's verbatim first; if engine sound is
   wrong, generate stubs. The 13 base-game cars without ET files (Express2500,
   Durango, Explorer, etc.) prove the audio system tolerates missing files —
   may not be load-blocking.

## References

- Sample DLC: `/run/media/paths/SSS-Games/xenia_canary_windows/content/0000000000000000/4D5309C9/00000002/4D5309C900000729`
- Xenia content profiles: `/run/media/paths/SSS-Games/xenia_canary_windows/content/`
- Xenia log: `/run/media/paths/SSS-Games/xenia_canary_windows/xenia.log`
- Base gamedb: `/run/media/paths/SSS-Games/fh1-xex/4D5309C9/00007000/2DC7007B/media/db/gamedb.slt`
- Failed-port autopsy is in this session's transcript; key error path was
  `\Media\Audio\Cars\Engines\EngineTuning\Attempt to access invalid field or record_ET.xml`
