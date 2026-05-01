# Physics Data — Where It Lives & How To Read It

The good news: the vast majority of car physics data is **already labeled**
in FM4. The only fully-binary unknown is FH1's per-car `physicsdefinition.bin`,
and we have a known-equivalent oracle (the FM4 SQLite DB) to label it
field-by-field.

## What's labeled in each game

### FM4

| Source | Format | Coverage |
|---|---|---|
| `Media/db/gamedb.slt` | **SQLite, 200 tables, 6.5 MB** | Per-car: weight, drivetrain, gears, top speed, peak power/torque, full **torque curve** (186 RPM samples), drag, downforce, **suspension** (spring rates, dampers, ride heights, camber, caster, toe), **anti-sway**, **tire friction curve** (100 samples), engine (compression, boost, moment of inertia, gas tank), every upgrade level. Fully labeled column names. |
| `Media/db/CarPartsList.xml` | XML | Default upgrade-level template |
| `Media/physics/PI.xml` | XML | Performance Index rules |
| `Media/physics/PhysicsSettings.ini` | INI | Global tuning |
| `Media/physics/CollObjects.xml` | XML | Global collision rules |
| `Media/physics/surfaceTypes.xml` | XML | Surface friction |
| Per-car `physics/maxdata.xml` | XML | Geometry only: wheelbase, track widths, ride heights, bounding box + bevel, ~36 collision spheres |
| Per-car `carattribs.xml` | XML (Version 16) | Driver hand offsets, damage scalars, gauge config |
| Root `Database.xmplr` (13 MB) | PIRS / Xbox 360 STFS package, encrypted-ish | Likely metadata (career, profile schemas). **Not currently decoded.** |

**FM4 coverage of weight / torque / suspension: 100% labeled.** The DB
has every field as a named SQL column.

### FH1

| Source | Format | Coverage |
|---|---|---|
| Per-car `Physics/MAXData.xml` | XML | **Byte-identical to FM4's `physics/maxdata.xml` for 74/76 shared cars.** Same geometry. |
| Per-car `physicsdefinition.bin` | **Binary, 1.5–2.6 KB** | First-pass dissection in `FH1_PHYSICSDEFINITION_BIN.md`. **Not just hitboxes** — carries two symmetric 3×3 inertia tensors (mass-normalized + mass-weighted) at 0x10/0x34, a fixed scalar block 0x58..0xCC (mass/CoG/aero), a 44-byte-stride wheel/attachment record array starting near 0xCC (count varies 13–17 per car), then a variable-length convex-hull collision section at the tail. The "hitbox" intuition is right for the trailing section; the rest is rigid-body physics descriptor. |
| Per-car `carattribs.xml` | XML (Version 21) | Mostly cosmetic drift from FM4 |
| `media/db/gamedb.slt` | **SQLite, 221 tables, ~6 MB** | **Confirmed 2026-05-01.** Same per-car schema as FM4 — `Data_Car` keyed by `MediaName`, same `Id` (`ALF_8C_08` is `Id=1032` in both games). 117 of 117 FM4 `Data_Car` columns present; FH1 adds 9 (`OffRoad{EnginePowerScale,FrontWheelGripScale,RearWheelGripScale,TCSFullEffectMultiplier}`, `Is{CameraCollidable,Rentable,Selectable}`, `Specials`, `UseBoxCameraCollision`) and one extra per-car table (`E3Drivers`). Lowercase path. |
| `Media/physics.zip` | LZX-method-21 zip | FH1 zips its global physics dir (FM4 had it loose under `Media/physics/`). Unchecked. |
| Top-level `cars/CarAttribs.xml` | XML | Global override / schema (FH1-only — distinct from per-car carattribs.xml) |
| Top-level `cars/AppearancePresets.zip` | zip | FH1-only |

**Implication for the per-car write path:** FH1's `physicsdefinition.bin`
is *not* the only place per-car physics data lives — most of it
duplicates rows in `gamedb.slt`. The bin is likely a compiled cache
(offline-built from the SQL DB at game-build time). For *reading*, the
SQL row is the labelled source of truth and `cardb.json` captures it
verbatim. For *writing*, the bin is what the runtime actually loads —
so an FH1 export has to either patch the SQL row *and* synthesise the
bin, or just synthesise the bin and trust the runtime ignores the SQL.
This narrows the original RE plan: instead of brute-forcing the bin
schema cold, we now have **76 paired (FH1 SQL row, FH1 bin) tuples**
from the same game — a much tighter labeling oracle than the cross-game
FM4↔FH1 pairing the original section below proposed.

## `gamedb.slt` schema (FM4) — physics-relevant tables

Confirmed via `PRAGMA table_info` from a read-only Python sqlite3 connection.

### `Data_Car` (117 cols) — the per-car row

Highlights:

```
Id, Year, MakeID, DisplayName, ModelShort, MediaName, ClassID, CarTypeID
CarClassModifier, FamilyModelID, FamilyBodyID, EnginePlacementID, MaterialTypeID, PowertrainID

CurbWeight                     REAL
WeightDistribution             REAL
NumGears                       INT
TireBrandID                    INT
FrontTireWidthMM               INT  | FrontTireAspect / FrontWheelDiameterIN
RearTireWidthMM                INT  | RearTireAspect  / RearWheelDiameterIN

Time:0-60-sec                  REAL | Time:0-100-sec
QuarterMileTime-sec            REAL | QuarterMileSpeed-mph
TopSpeed-mph                   REAL
SpeedLimiterID                 INT
PerformanceIndex               REAL
BaseCost                       INT  | BaseRarity REAL

SteerMaxAngle, SteerMaxAngVelTurning, SteerMaxAngVelStraighten,
SteerAngVelCountersteer, SteerAngVelDynFindPeak, SteerAccelTimeToMaxRate,
SteerSpeedSensitiveMaxGees, SteerSpeedSensitiveMinMaxAngle,
SteerSpeedSensitiveSlowSpeed, SteerSpeedSensitiveFastSpeed,
SteerSpeedSensitiveFastRateScale, SteerMaxAngleFiltered      (~12 steering REAL fields)

AssistsTCSSlipDefTakeoff, AssistsTCSSlipDefMoving, AutoSteerOverrideID
FixListingRearFricScale, FixListingNormSlip0/1, FixListingSteerAngle0/1

BodyAeroLongitudinalDrag, BodyAeroVerticalDrag,
BodyAeroLateralDragFront, BodyAeroLateralDragRear,
BodyAeroForwardDownforceFront, BodyAeroForwardDownforceRear,
BodyAeroAngleZeroDownforce, BodyAeroWIForceScale            (8 aero REAL fields)

TireAeroHackShouldApply, TireAeroHackMinSpringLoad, TireAeroHackMaxSpringLoad

SimPeakPower, SimPeakAngVel, SimPeakTorque, SimPeakTorqueAngVel, SimRedlineAngVel
SimTimeTo60MPH, SimTimeTo100MPH, SimTimeQuarterMile, SimSpeedQuarterMile, SimTopSpeed
SimBrakeDistance100MPH, SimBrakeDistance60MPH
SimLatGees60MPH, SimLatGees120MPH

HandlingRating, SpeedRating, AccelerationRating, BrakingRating, LaunchRating

GameTorqueScale, GameDragScale
CaliperAngleFront, CaliperAngleRear, CaliperRGBFront, CaliperRGBRear
StockWheelID, GaugeID, ContentId, IsPurchased, IsUnicorn, IsArcade, IsInstalled, IsDrivable
HasLivery, HasRaceLivery, WingMask, Thumbnail
```

### `Data_Engine` (20 cols)

```
EngineID, EngineMass-kg, MediaName, ConfigID, CylinderID,
Compression, VariableTimingID, AspirationID_Stock, StockBoost-bar,
MomentInertia, GasTankSize,
TorqueSteerLeftSpeedScale, TorqueSteerRightSpeedScale,
EngineGraphingMaxTorque, EngineGraphingMaxPower,
EngineName, EngineRotation, Carbureted, Diesel, Rotary
```

### `Data_CarBody` (15 cols) — mirrors `maxdata.xml`

```
Id, ModelWheelbase, ModelFrontTrackOuter, ModelRearTrackOuter,
ModelFrontStockRideHeight, ModelRearStockRideHeight,
BottomCenterWheelbasePos{x,y,Z},
PristineBoundingBox{Min,Max}{X,Y,Z}
```

### `Data_Drivetrain` (3 cols)

```
DrivetrainID, DrivetypeID, EngineMountingDirection
```

### `List_TorqueCurve` (190 cols)

```
TorqueCurveID, TorqueScale, NumTorqueValues,
v0, v1, ..., v185,                  -- 186 sample slots
ZeroThrottleTorqueScale
```
Per-car curve sampled at up to 186 RPM points, scaled by `TorqueScale`.

### `List_SpringDamperPhysics` (31 cols)

```
SpringDamperPhysicsID, Ordinal, SuspensionPhysicsTypeID,
DefRideHeight, MinRideHeight, MaxRideHeight, MaxCompressHeight,
DefSpringRate, MinSpringRate, MaxSpringRate,
DefDampenBumpRate, MinDampenBumpRate, MaxDampenBumpRate, DampenBumpClamp,
DefDampenReboundRate, MinDampenReboundRate, MaxDampenReboundRate, DampenReboundClamp,
BumpstopStiffness, BumpstopDamping,
ChassisPivotX, ChassisPivotY, TirePivotX,
CamberChangeRatioCompression, CamberChangeRatioExpansion,
StaticToe, StaticCamber, Caster,
SteerRotAxisTireOffsetX, YMaxSpringVel, MaxStretchDeltaFromRideHeight
```

### `List_AntiSwayPhysics` (6 cols)

```
AntiSwayPhysicsID, Ordinal,
DefSwaybarStiffness, MinSwaybarStiffness, MaxSwaybarStiffness, SwaybarDamping
```

### `List_AeroPhysics` (20 cols)

```
AeroPhysicsID, DefaultTuneSlider,
Drag0, Downforce0, Drag1, Downforce1,
AngleZeroDownforce, LateralDrag,
DFTorqueScaleOneSliderInput0..2, DFTorqueScaleOneTorqueScaleOutput0..2,
DFTorqueScaleTwoSliderInput0..2, DFTorqueScaleTwoTorqueScaleOutput0..2
```

### `List_TireFrictionCurve` (103 cols)

```
FrictionCurveID, NumCurveValues, FrictionScale,
v0, v1, ..., v99
```

### Other relevant tables

- `Powertrains` — engine ↔ drivetrain assembly mapping
- `List_Aspiration`, `List_BrakeType`, `List_TireCompound`,
  `List_DriveType`, `List_Cylinders`, `List_EngineConfig`,
  `List_VariableTiming`, `List_TireAffectCurve`, `List_TireFrictionMultiCurve`
- `Upgrades` + ~38 `List_Upgrade*` tables — full upgrade tree (every part,
  every level, every effect)
- `CarDetails`, `CarPartPositions`, `CarPIOverrides`, `CarExceptions`,
  `CarInvalidDefaultParts`, `CarTrackOffsets`, `CarClasses`, `Powertrains`
- `Data_Motor` + `List_UpgradeMotor*` — electric/hybrid motor tables
- 162 more (career data, achievements, livery, AI, environments, races,
  events — not physics-relevant)

## How to query

```python
import sqlite3
con = sqlite3.connect('file:.../Media/db/gamedb.slt?mode=ro', uri=True)
# Pull weight, gears, peak torque, etc. for ALF_8C_08
row = con.execute("""
    SELECT DisplayName, CurbWeight, WeightDistribution, NumGears,
           SimPeakPower, SimPeakTorque, SimPeakTorqueAngVel, SimRedlineAngVel,
           BodyAeroLongitudinalDrag, BodyAeroForwardDownforceFront,
           BodyAeroForwardDownforceRear
    FROM Data_Car
    WHERE MediaName = 'ALF_8C_08'
""").fetchone()
```

The `MediaName` column is the same string as the per-car archive base
name (case-insensitive) — so it's a direct join key from the file
system to the DB.

## Strategy for FH1's `physicsdefinition.bin`

`physicsdefinition.bin` is per-car, ~2-2.5 KB → ~500-625 floats worst
case (assuming all-float). The DB plus the per-car file gives us a
**known-label, known-binary** pair for every car shared between the games
(~76 cars). The schema can be reverse-engineered without going pure
heuristic:

1. For each shared car, `SELECT *` joining `Data_Car`, `Data_Engine`,
   `Data_Drivetrain`, `Data_CarBody`, plus the curve/suspension lists
   keyed by Ids on `Data_Car`. Yields a fully-labeled vector of ~300
   floats / ints per car.
2. For each FH1 `physicsdefinition.bin`, dump as float32-BE / int32-BE
   parallel arrays (the carbin format already establishes BE convention
   on Xbox 360 PowerPC).
3. **For each labeled field in the SQL row**, scan the binary for that
   exact float value across all 76 cars. The **offset that holds the
   target value in ≥70 of 76 cars** is the field's location. Floats with
   high per-car variance (CurbWeight, EngineMass-kg, TopSpeed-mph,
   SimPeakPower, etc.) will pin uniquely; constants (SteerMaxAngle, etc.)
   need to be cross-checked against another distinguisher.
4. Curves (TorqueCurve, TireFrictionCurve, AeroPhysics) will appear as
   contiguous float runs — easy to detect because they're large and
   ordered.

If FH1 reused FM4's exact float values, this approach maps every field.
If FH1 retuned values for Horizon, the approach still works on
**structurally invariant** fields (geometry, derived ratings) and gives
us the schema — only the absolute values change.

## Open questions

1. **FH1's `gamedb.slt`** — does it exist and what tables does it have?
   The exact path needs re-confirming (case-sensitivity bit me on the
   first attempt). If FH1 keeps the SQLite DB, then `physicsdefinition.bin`
   may just be a compiled cache derived from it at build time.
2. **`Database.xmplr`** (FM4 root) — PIRS package, encrypted. Not part of
   the per-car flow but may contain career / profile / DLC data we'd need
   for a full roundtrip.
3. **`Media/physics.zip`** (FH1) — same as FM4's loose physics dir? Same
   schema? Worth a one-shot extract & diff.
4. **FH1 `CarAttribs.xml`** at the top level (not per-car) — looks like
   a global schema or override. Worth comparing against the per-car ones.

## Probe scripts

- `probe/probe_diff_configs.py` — extracts per-car XML/bin and diffs
- `probe/probe_assets.py` — full asset inventory + per-car detail
- `probe/probe_texture_eq.py` — texture byte-equivalence sweep
- `probe/probe_typeid5_layout.py` — TypeId 5 word classification
