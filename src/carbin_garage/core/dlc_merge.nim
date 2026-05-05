## DLC merge.slt builder.
##
## Produces the per-DLC `<dlcId>00_merge.slt` SQLite file that FH1
## merges into its live gamedb at boot. The 56-table set + per-car PK
## conventions were verified empirically against the sample DLC at
## xenia_canary_windows/.../4D5309C900000729 — see
## `probe/nim_dlc_merge_recon.bin` and `probe/out/dlc_merge_recon.txt`.
##
## ## Strategy (v0)
##
## **Pure donor clone.** Every row for the new car is the donor's row
## with IDs rewritten:
##   - donor's `Data_Car.Id` → new `Data_Car.Id`
##   - donor's `Data_Engine.EngineID` → new `Data_Engine.EngineID`
##   - donor's `MediaName` → new `MediaName`
##   - any sub-ID encoded as `donorCarId * 1000 + slot` rewrites to
##     `newCarId * 1000 + slot` (preserving slot identity)
##   - same pattern for `donorEngineId * 1000 + level` (used by
##     List_TorqueCurve.TorqueCurveID and List_UpgradeEngine*.Id)
##   - Data_Car.BaseCost forced to 1
##
## Result: the new car loads as a renamed clone of the donor — same
## suspension, drivetrain, torque curve, paint options. The point of v0
## is to prove the merge.slt path is honored by FH1's runtime (i.e. the
## audio-init SQL chain that nuked direct gamedb edits does NOT nuke
## DLC-merged cars). Source-snippet overlay (re-applying the FM4 car's
## own values to columns where they're meaningful — display name,
## thumbnail, top speed, etc.) lands in v1 once load is proven.
##
## ## Key column conventions (from sample-DLC recon)
##
## | Tables                                               | Key column   |
## |------------------------------------------------------|--------------|
## | Data_Car, Data_Engine                                | MediaName    |
## | CameraOverrides, CarExceptions                       | CarId/CarID  |
## | All Ordinal-encoded chassis tables (~30 tables)      | Ordinal      |
## | List_UpgradeEngine* (~18 tables), List_TorqueCurve   | EngineID     |
##
## ## ID allocation
##
## - `newCarId`: derived from `dlcId` to be > 65536 — well above base
##   game's max Data_Car.Id (~5000 in FH1) so no collision with base
##   rows. Sub-IDs (`newCarId * 1000 + slot`) reach into the 100M+
##   range, fits in INT32.
## - `newEngineId`: derived independently from `dlcId` to land in
##   ~50000+ range (also > base max of ~1500).
## - Both are deterministic from `dlcId`, so re-running the same port
##   produces the same merge.slt content.
##
## ## What this module does NOT do (yet)
##
## - **Source-snippet overlay**: working/<slug>/cardb.json captures the
##   FM4 car's per-car rows. v1 overlays its values onto Data_Car (name,
##   image, top speed) and Data_Engine (peak power/torque). Until that
##   lands, the new car shows up in-game with the donor's name and
##   thumbnail.
## - **Cross-game schema migration**: FH1's Data_Car has 9 columns FM4
##   doesn't (OffRoadEnginePowerScale, IsRentable, IsSelectable, etc.).
##   Donor passthrough handles this trivially — no migration needed for
##   v0.
## - **List_CarMake / List_Wheels / Combo_Engines / ContentOffers**:
##   global-ish tables in the merge subset. v0 includes them but only
##   inserts donor's rows verbatim; no per-car logic. May need
##   per-table allow-list refinement after first in-game test.
## - **FK chain validation**: donor's row references Powertrains /
##   List_CarMake / List_Country — those tables stay in base gamedb,
##   not the merge.slt. Donor's FK values stay valid because they point
##   into base.

import std/[json, os, sets, strutils, tables]
import db_connector/db_sqlite

type
  DlcMergeError* = object of CatchableError

  IdRewrite* = object
    ## State carried into every per-row rewrite. Captures donor's
    ## donor-specific PKs and the new IDs to substitute in.
    donorCarId*:    int
    donorEngineId*: int
    donorWheelId*:  int    ## donor's StockWheelID (= List_Wheels.ID); 0 if absent
    newCarId*:      int
    newEngineId*:   int
    newWheelId*:    int    ## fresh List_Wheels.ID; 0 if no remap requested
    donorMediaName*: string
    newMediaName*:   string

const
  DlcTables*: array[56, string] = [
    ## Canonical 56-table list from sample DLC merge.slt. Keep ordered
    ## with parents first (Data_Car / Data_Engine before child upgrade
    ## tables), since SQLite has no FK enforcement on the merge schema
    ## but it makes debugging dumps readable.
    "Data_Car",
    "Data_Engine",
    "Data_CarBody",
    "Data_Drivetrain",
    "List_AeroPhysics",
    "List_AntiSwayPhysics",
    "List_SpringDamperPhysics",
    "List_TorqueCurve",
    "CarPartPositions",
    "Combo_Colors",
    "CameraOverrides",
    "CarExceptions",
    "List_CarMake",
    "List_Wheels",
    "ContentOffers",
    "ContentOffersMapping",
    "List_UpgradeAntiSwayFront",
    "List_UpgradeAntiSwayRear",
    "List_UpgradeBrakes",
    "List_UpgradeCarBody",
    "List_UpgradeCarBodyChassisStiffness",
    "List_UpgradeCarBodyFrontBumper",
    "List_UpgradeCarBodyHood",
    "List_UpgradeCarBodyRearBumper",
    "List_UpgradeCarBodySideSkirt",
    "List_UpgradeCarBodyTireWidthFront",
    "List_UpgradeCarBodyTireWidthRear",
    "List_UpgradeCarBodyWeight",
    "List_UpgradeDrivetrain",
    "List_UpgradeDrivetrainClutch",
    "List_UpgradeDrivetrainDifferential",
    "List_UpgradeDrivetrainDriveline",
    "List_UpgradeDrivetrainTransmission",
    "List_UpgradeEngine",
    "List_UpgradeEngineCSC",
    "List_UpgradeEngineCamshaft",
    "List_UpgradeEngineDSC",
    "List_UpgradeEngineDisplacement",
    "List_UpgradeEngineExhaust",
    "List_UpgradeEngineFlywheel",
    "List_UpgradeEngineFuelSystem",
    "List_UpgradeEngineIgnition",
    "List_UpgradeEngineIntake",
    "List_UpgradeEngineIntercooler",
    "List_UpgradeEngineManifold",
    "List_UpgradeEngineOilCooling",
    "List_UpgradeEnginePistonsCompression",
    "List_UpgradeEngineRestrictorPlate",
    "List_UpgradeEngineTurboSingle",
    "List_UpgradeEngineTurboTwin",
    "List_UpgradeEngineValves",
    "List_UpgradeRearWing",
    "List_UpgradeRimSizeFront",
    "List_UpgradeRimSizeRear",
    "List_UpgradeSpringDamper",
    "List_UpgradeTireCompound",
  ]

# ---- helpers ----

proc qIdent(name: string): string =
  ## SQLite delimited identifier. Required because real Forza schemas
  ## use `:` and `-` in column names (e.g. `Time:0-60-sec`).
  result = "\"" & name.replace("\"", "\"\"") & "\""

proc tableExists(db: DbConn, tbl: string): bool =
  for r in db.fastRows(
    sql"SELECT name FROM sqlite_master WHERE type='table' AND name=?", tbl):
    if r.len > 0: return true
  return false

proc createTableSql(srcDb: DbConn, tbl: string): string =
  ## Fetch the table's original CREATE TABLE statement from sqlite_master
  ## and return it. Schema is cloned verbatim — no PRAGMA-driven
  ## reconstruction (which would lose collations / DEFAULTs / quoting).
  for r in srcDb.fastRows(
    sql"SELECT sql FROM sqlite_master WHERE type='table' AND name=?", tbl):
    if r.len > 0: return r[0]
  raise newException(DlcMergeError,
    "table not found in source gamedb: " & tbl)

proc tableColumnNames(db: DbConn, tbl: string): seq[string] =
  for r in db.fastRows(sql("PRAGMA table_info(" & tbl & ")")):
    if r.len >= 2: result.add(r[1])

proc hasColumn(db: DbConn, tbl, col: string): bool =
  for c in tableColumnNames(db, tbl):
    if c == col: return true
  return false

proc keyColFor(db: DbConn, tbl: string): string =
  ## Per-car / per-engine key. Order matters: MediaName first (most
  ## specific), then EngineID-keyed engine-upgrade tables, then Ordinal,
  ## then CarId/CarID. List_TorqueCurve has no key match here — handled
  ## as a special case (key on TorqueCurveID range).
  if hasColumn(db, tbl, "MediaName"): return "MediaName"
  if hasColumn(db, tbl, "EngineID"):
    # EngineID + Ordinal both: for the chassis tables that key on
    # Ordinal but happen to also carry an EngineID column, prefer
    # Ordinal. Engine-upgrade tables don't carry Ordinal.
    if hasColumn(db, tbl, "Ordinal"): return "Ordinal"
    return "EngineID"
  if hasColumn(db, tbl, "Ordinal"): return "Ordinal"
  if hasColumn(db, tbl, "CarId"):   return "CarId"
  if hasColumn(db, tbl, "CarID"):   return "CarID"
  return ""

const RewritableIdColumnsLower = [
  ## Column names (lowercased for case-insensitive match) carrying IDs
  ## that may be donor PKs or sub-id-encoded FKs (donorCarId*1000+slot,
  ## donorEngineId*1000+slot). Anything else is copied verbatim — safer
  ## to leave a static FK alone than to scramble it.
  ##
  ## Casing is normalized to lowercase because FH1's schema is
  ## inconsistent across tables: same logical FK appears as `CarBodyID`
  ## in some tables and `CarBodyId` / `CarbodyId` in others. Comparing
  ## case-insensitively means future schema-casing variants don't
  ## reintroduce the same class of bug.
  ##
  ## Audit basis: scanned every INT column in every merge-table against
  ## base gamedb; any column whose values are >50% sub-id-encoded
  ## (col/1000 ∈ Data_Car.Id or Data_Engine.EngineID) is in this list.
  "id", "ordinal", "engineid",
  # Per-car physics FKs
  "antiswayphysicsid", "springdamperphysicsid",
  "frontspringdamperphysicsid", "rearspringdamperphysicsid",
  "aerophysicsid",  # 2026-05-03: missing entry caused RAD_SR8LM_10 port to
                    # carry donor's `List_UpgradeRearWing.AeroPhysicsID`
                    # value verbatim → SQL CE join failure → garbage MediaName
                    # passed downstream → grey shaders on load.
  # Engine FKs
  "torquecurveid", "torquecurvefullthrottleid",
  # Body FK (CarBodyID/CarBodyId/CarbodyId — all three casings exist in FH1's schema)
  "carbodyid", "drivetrainid",
  # Car / model FKs
  "carid", "modelid",
  # Stock wheel FK (paired with findUnusedWheelId)
  "stockwheelid",
]

proc isLikelyIdColumn(name: string): bool =
  let lower = name.toLowerAscii
  for entry in RewritableIdColumnsLower:
    if lower == entry: return true
  return false

proc rewriteId(v: string, rw: IdRewrite): string =
  ## Apply ID rewrite rules. Empty/non-int → unchanged.
  if v.len == 0: return v
  var i: int
  try: i = parseInt(v)
  except CatchableError: return v
  # Exact match: car-id
  if i == rw.donorCarId: return $rw.newCarId
  if i == rw.donorEngineId: return $rw.newEngineId
  if rw.donorWheelId > 0 and rw.newWheelId > 0 and i == rw.donorWheelId:
    return $rw.newWheelId
  # Sub-ID encoding: parentId * 1000 + slot, slot in 0..999
  if rw.donorCarId > 0 and
     i >= rw.donorCarId * 1000 and
     i < (rw.donorCarId + 1) * 1000:
    let slot = i - rw.donorCarId * 1000
    return $(rw.newCarId * 1000 + slot)
  if rw.donorEngineId > 0 and
     i >= rw.donorEngineId * 1000 and
     i < (rw.donorEngineId + 1) * 1000:
    let slot = i - rw.donorEngineId * 1000
    return $(rw.newEngineId * 1000 + slot)
  return v

proc rewriteCell(colName, value: string, rw: IdRewrite,
                 wasOverlaid: bool = false): string =
  ## Top-level per-cell rewrite. Handles MediaName, BaseCost, and any
  ## ID-shaped column.
  ##
  ## MediaName: force to newMediaName for ALL rows. We only copy rows
  ## that are for this car (keyed by donorMediaName / donorCarId), so
  ## any MediaName column in those rows refers to THIS car and must
  ## carry the new name. Earlier logic only rewrote when value matched
  ## donorMediaName — but the snippet (captured at source-game import)
  ## carries the SOURCE car's name, which doesn't match donor when
  ## donor and source are different cars (cross-game port with
  ## non-matching slugs). That left snippet's source-name in place,
  ## producing a Data_Car row that pointed at the wrong loose-files
  ## dir → car silently dropped from autoshow. (2026-05-01 fix.)
  ##
  ## `wasOverlaid` = the value came from the snippet overlay (cardb.json
  ## or carslot.json stats edit), so the user explicitly chose it and
  ## the autoshow-friendly defaults below should step aside.
  if colName == "MediaName":
    return rw.newMediaName
  if colName == "BaseCost":
    # Default policy: ports drop into autoshow at BaseCost=1 so test
    # cars are buyable. If the user explicitly set BaseCost via the
    # L-pane (overlay carries it), honor that — otherwise the slider
    # would be a no-op and writing 67 credits would silently re-export
    # as 1 credit.
    if wasOverlaid: return value
    return "1"
  if colName == "IsArcade":
    # FH1's autoshow filters cars by IsArcade=1; donors carrying 0
    # (e.g. AUD_R8GT_11, rare/non-arcade trims) silently hide the new
    # car. Empirically observed 2026-05-01: alfa donor IsArcade=1 →
    # car appears; R8 GT donor IsArcade=0 → car enumerated by
    # XamContent but never resolved by FH1 (no autoshow listing,
    # no asset loads in xenia.log). Force to 1 for ports.
    return "1"
  if colName == "BaseRarity":
    # FH1's autoshow only lists cars with BaseRarity == 0; non-zero is
    # the wheelspin / barn-find / gift gating tier. The snippet from a
    # source-game cardb may carry the source's rarity (FM4 R8_08 = 7.8)
    # even when the donor is a normal showroom car (R8 GT = 0). Force
    # to 0 so ported cars always end up purchasable in autoshow at
    # BaseCost=1. Empirically: 121/176 base cars are rarity 0 (the
    # autoshow tier); the rest are unlock rewards. L-pane override
    # wins so users can opt cars back into the gated tiers.
    if wasOverlaid: return value
    return "0"
  if isLikelyIdColumn(colName):
    return rewriteId(value, rw)
  return value

proc jsonToSqlString(v: JsonNode): string =
  ## Project a snippet JSON cell value to the string form db_connector
  ## binds. Mirrors cardb_writer.jsonToSqlString.
  if v.isNil or v.kind == JNull: return ""
  case v.kind
  of JString: return v.getStr
  of JInt: return $v.getInt
  of JFloat: return $v.getFloat
  of JBool: return (if v.getBool: "1" else: "0")
  else: return $v

proc snippetRowsForTable(snippet: JsonNode, tbl: string):
                         seq[Table[string, JsonNode]] =
  ## Pull `snippet.tables.<tbl>.rows` as a sequence of column→json maps.
  ## Returns empty if the snippet doesn't carry rows for this table.
  if snippet.isNil or snippet.kind != JObject: return
  if not snippet.hasKey("tables"): return
  let tables = snippet["tables"]
  if not tables.hasKey(tbl): return
  let entry = tables[tbl]
  if not entry.hasKey("rows"): return
  for r in entry["rows"]:
    if r.kind != JObject: continue
    var row = initTable[string, JsonNode]()
    for k, v in r.pairs: row[k] = v
    result.add(row)

# ---- ID allocation ----

## ID allocation: pick UNUSED slots WITHIN base's range. FH1 only
## iterates Data_Car rows whose Id falls in the base range it knows
## about (measured 249..1568). UDLC's 97 newly-added cars all use
## small Ids that fill GAPS in base — e.g. FER_575_02=257, where base
## has rows at 251 and 282 but nothing at 257. IDs above base.max
## (our previous 1989) are silently ignored by the runtime.
##
## Strategy: query the source gamedb for occupied Ids, walk down from
## base.max picking the first unused slot offset by `dlcId mod gap`
## so re-running the same port gets the same Id deterministically.

proc collectUsedIds(srcDb: DbConn, table, idCol: string,
                    extraSlts: openArray[string]): HashSet[int] =
  ## Used IDs across base gamedb + every sibling DLC merge.slt. UDLC
  ## and our own previously-shipped DLCs add rows via merge.slt that
  ## aren't in base — colliding on those IDs produces silent dedup at
  ## runtime. Walk all known overlays so the gap-fill is conflict-safe.
  result = initHashSet[int]()
  for r in srcDb.fastRows(sql("SELECT " & idCol & " FROM " & table)):
    try: result.incl(parseInt(r[0]))
    except CatchableError: discard
  for path in extraSlts:
    try:
      let db = open(path, "", "", "")
      defer: db.close()
      # Some DLC merge.slts may not carry every table; tolerate that.
      let hasTbl = db.getValue(sql"SELECT name FROM sqlite_master WHERE type='table' AND name=?", table)
      if hasTbl.len == 0: continue
      for r in db.fastRows(sql("SELECT " & idCol & " FROM " & table)):
        try: result.incl(parseInt(r[0]))
        except CatchableError: discard
    except CatchableError:
      # Skip unreadable .slt rather than failing the whole port.
      discard

proc collectAliasCarSlots(srcDb: DbConn,
                          extraSlts: openArray[string]): HashSet[int] =
  ## CarId slots occupied by shared-FK tables that key sub-IDs at
  ## carId*1000+slot but aren't owned by the carId on Data_Car.Id.
  ## Empirical: List_AeroPhysics has 256 rows in 112 distinct buckets,
  ## of which ~50 are orphan slots (no Data_Car at that id) — base FH1
  ## uses them as a shared aero catalog referenced by other cars'
  ## bumper/wing FKs. Picking newCarId in such a slot collides on the
  ## sub-id space and triggers cascading SQL CE FK failures during
  ## car_animations / car_skeleton / wheel asset lookups. Confirmed
  ## empirically: carId 1486 → broken; 1486000+ holds AST_V12Zagato_12's
  ## front-bumper aero rows. Bug isolated 2026-05-02.
  ##
  ## List_TorqueCurve also aliases (TorqueCurveID/1000 has buckets in
  ## 0..200 not matching any carId) but those low buckets are well
  ## below the active carId range, so they don't pollute our search.
  ## Including for defensive completeness.
  const ALIAS_TABLES = [
    ("List_AeroPhysics", "AeroPhysicsID"),
    ("List_TorqueCurve", "TorqueCurveID"),
  ]
  result = initHashSet[int]()
  for (tbl, col) in ALIAS_TABLES:
    let hasTbl = srcDb.getValue(sql"SELECT name FROM sqlite_master WHERE type='table' AND name=?", tbl)
    if hasTbl.len == 0: continue
    for r in srcDb.fastRows(sql("SELECT DISTINCT " & col & "/1000 FROM " & tbl)):
      try: result.incl(parseInt(r[0]))
      except CatchableError: discard
  for path in extraSlts:
    try:
      let db = open(path, "", "", "")
      defer: db.close()
      for (tbl, col) in ALIAS_TABLES:
        let hasTbl = db.getValue(sql"SELECT name FROM sqlite_master WHERE type='table' AND name=?", tbl)
        if hasTbl.len == 0: continue
        for r in db.fastRows(sql("SELECT DISTINCT " & col & "/1000 FROM " & tbl)):
          try: result.incl(parseInt(r[0]))
          except CatchableError: discard
    except CatchableError:
      discard

proc baseRange(srcDb: DbConn, table, idCol: string): tuple[lo, hi: int] =
  ## Min/max Id from BASE gamedb only. Sibling DLC merge.slts can carry
  ## IDs outside this range (UDLC has Data_Car ids in the 51000s) but
  ## those IDs are silently ignored by FH1's runtime — the active range
  ## is what base ships. Search must stay inside [lo..hi].
  result.lo = -1; result.hi = -1
  for r in srcDb.fastRows(sql("SELECT MIN(" & idCol & "), MAX(" & idCol & ") FROM " & table)):
    if r.len >= 2:
      try: result.lo = parseInt(r[0]) except CatchableError: discard
      try: result.hi = parseInt(r[1]) except CatchableError: discard

proc findUnusedCarId(srcDb: DbConn, dlcId: int,
                     extraSlts: openArray[string] = []): int =
  ## Picks a carId that's not in Data_Car.Id AND not aliased as a
  ## sub-id bucket in shared-FK tables (List_AeroPhysics et al). The
  ## alias check is essential — otherwise picking eg 1486 produces a
  ## merge.slt whose List_UpgradeCarBodyFrontBumper / List_UpgradeRearWing
  ## rows reference AeroPhysicsIDs that ALREADY EXIST in base gamedb and
  ## belong to a different car, breaking FK joins at car-load time.
  let usedSet = collectUsedIds(srcDb, "Data_Car", "Id", extraSlts)
  let aliasSet = collectAliasCarSlots(srcDb, extraSlts)
  let blocked = usedSet + aliasSet
  let (lo, hi) = baseRange(srcDb, "Data_Car", "Id")
  if hi < 0: return 1500
  var freeSlots: seq[int] = @[]
  for i in countdown(hi, lo):
    if i notin blocked:
      freeSlots.add(i)
      if freeSlots.len >= 64: break
  if freeSlots.len == 0:
    raise newException(DlcMergeError,
      "no free Data_Car.Id slot in base range [" & $lo & ", " & $hi & "] " &
      "(used=" & $usedSet.len & " alias=" & $aliasSet.len & ")")
  result = freeSlots[dlcId mod freeSlots.len]

proc findUnusedEngineId(srcDb: DbConn, dlcId: int,
                        extraSlts: openArray[string] = []): int =
  let usedSet = collectUsedIds(srcDb, "Data_Engine", "EngineID", extraSlts)
  let (lo, hi) = baseRange(srcDb, "Data_Engine", "EngineID")
  if hi < 0: return 500
  var freeSlots: seq[int] = @[]
  for i in countdown(hi, lo):
    if i notin usedSet:
      freeSlots.add(i)
      if freeSlots.len >= 64: break
  if freeSlots.len == 0:
    raise newException(DlcMergeError,
      "no free Data_Engine.EngineID slot in base range [" & $lo & ", " & $hi & "]")
  result = freeSlots[(dlcId * 7919) mod freeSlots.len]

proc findUnusedWheelId(srcDb: DbConn, dlcId: int,
                       extraSlts: openArray[string] = []): int =
  ## Allocates a List_Wheels.ID that's not in base AND not in any sibling
  ## DLC merge.slt's List_Wheels. Same-game ports otherwise emit a
  ## List_Wheels row at donor's ID, shadowing donor's wheel definition
  ## with the new car's MediaName — donor's car then resolves to a
  ## wheels_pri_<dlc>/<NEW_NAME>/ path that doesn't exist for it,
  ## triggering the SQL CE "attempt to access invalid field or record"
  ## that gets passed through into a HostPathDevice path lookup → infinite
  ## load on free-roam resume. Bug isolated 2026-05-02 PM (RAD_SR8LM_10
  ## TEST DLC).
  let usedSet = collectUsedIds(srcDb, "List_Wheels", "ID", extraSlts)
  let (lo, hi) = baseRange(srcDb, "List_Wheels", "ID")
  if hi < 0: return 100000
  # Search above base's max — wheel IDs aren't in carId*1000 alias space,
  # so anywhere outside the existing range is safe. Stay near base for
  # debuggability; bias by (dlcId * 9007) so sibling DLCs don't collide.
  var freeSlots: seq[int] = @[]
  for i in countdown(hi, lo):
    if i notin usedSet:
      freeSlots.add(i)
      if freeSlots.len >= 64: break
  if freeSlots.len == 0:
    raise newException(DlcMergeError,
      "no free List_Wheels.ID slot in base range [" & $lo & ", " & $hi & "]")
  result = freeSlots[(dlcId * 9007) mod freeSlots.len]

# Kept for back-compat with the smoke test; both now defer to the
# in-base-range allocators above when called with a real srcDb context.
proc allocateCarId*(dlcId: int): int = 1600 + (dlcId mod 400)
proc allocateEngineId*(dlcId: int): int = 1100 + (dlcId mod 400)

# ---- main builder ----

proc lookupDonorIds(srcDb: DbConn, donorMediaName: string):
                  tuple[carId: int; engineId: int; wheelId: int] =
  result.carId = -1
  result.engineId = -1
  result.wheelId = 0  # 0 = absent, treated as "no wheel rewrite needed"
  for r in srcDb.fastRows(
    sql"SELECT Id, StockWheelID FROM Data_Car WHERE MediaName=? LIMIT 1",
    donorMediaName):
    if r.len > 0:
      try: result.carId = parseInt(r[0]) except CatchableError: discard
    if r.len > 1:
      try: result.wheelId = parseInt(r[1]) except CatchableError: discard
    break
  for r in srcDb.fastRows(
    sql"SELECT EngineID FROM Data_Engine WHERE MediaName=? LIMIT 1",
    donorMediaName):
    if r.len > 0:
      try: result.engineId = parseInt(r[0]) except CatchableError: discard
    break

## Tables with no MediaName / Ordinal / CarId / CarID / EngineID column
## that key their rows by a sub-id-encoded PK (`donorCarId * 1000 + slot`
## or `donorEngineId * 1000 + slot`). Without explicit handling these
## fall through `keyColFor` to "" and `selectDonorRows` returns empty,
## leaving the new car's merge.slt missing rows that other tables FK
## into — empirically traced via UDLC parity diff against
## `4D5309C900000729/72900_merge.slt`. Each tuple is
## (table, PK column, "carId"|"engineId").
const SubIdKeyedTables: array[11, tuple[tbl, idCol, scope: string]] = [
  # Per-car body / chassis
  ("Data_CarBody",                          "Id",             "carId"),
  ("List_UpgradeCarBodyChassisStiffness",   "Id",             "carId"),
  ("List_UpgradeCarBodyFrontBumper",        "Id",             "carId"),
  ("List_UpgradeCarBodyHood",               "Id",             "carId"),
  ("List_UpgradeCarBodyRearBumper",         "Id",             "carId"),
  ("List_UpgradeCarBodySideSkirt",          "Id",             "carId"),
  ("List_UpgradeCarBodyTireWidthFront",     "Id",             "carId"),
  ("List_UpgradeCarBodyTireWidthRear",      "Id",             "carId"),
  ("List_UpgradeCarBodyWeight",             "Id",             "carId"),
  # Per-car aero (List_UpgradeRearWing.AeroPhysicsID FKs into here;
  # without this entry the FK dangles → SQL CE error → "Attempt to access
  # invalid field or record" propagated as a MediaName, which is the
  # 2026-05-03 RAD_SR8LM_10 grey-shader bug).
  ("List_AeroPhysics",                      "AeroPhysicsID",  "carId"),
  # Per-engine torque curve (already-known special case; folded in here
  # so all sub-id-keyed tables live in one list).
  ("List_TorqueCurve",                      "TorqueCurveID",  "engineId"),
]

proc selectDonorRows(srcDb: DbConn, tbl, keyCol: string, rw: IdRewrite):
                    seq[seq[string]] =
  ## Pull donor rows from base gamedb keyed by the table's per-car key.
  ## Sub-id-keyed tables (no Ordinal/MediaName column) are dispatched
  ## via `SubIdKeyedTables`; the rest go through the keyCol-based path.
  for entry in SubIdKeyedTables:
    if tbl == entry.tbl:
      let parentId =
        if entry.scope == "engineId": rw.donorEngineId
        else: rw.donorCarId
      let lo = $(parentId * 1000)
      let hi = $((parentId + 1) * 1000)
      let q = "SELECT * FROM " & qIdent(tbl) &
              " WHERE " & qIdent(entry.idCol) & " >= ? AND " &
              qIdent(entry.idCol) & " < ?"
      for r in srcDb.fastRows(sql(q), lo, hi):
        result.add(r)
      return
  if keyCol.len == 0: return
  var keyVal = ""
  case keyCol
  of "MediaName": keyVal = rw.donorMediaName
  of "Ordinal", "CarId", "CarID": keyVal = $rw.donorCarId
  of "EngineID": keyVal = $rw.donorEngineId
  else: return
  let q = "SELECT * FROM " & qIdent(tbl) & " WHERE " & qIdent(keyCol) & "=?"
  for r in srcDb.fastRows(sql(q), keyVal):
    result.add(r)

proc insertRow(dstDb: DbConn, tbl: string, colNames: seq[string],
               row: seq[string], rw: IdRewrite,
               overlay: Table[string, JsonNode]) =
  ## Build and execute a parameterized INSERT.
  ##
  ## For each column: start with donor's value, optionally let the
  ## snippet `overlay` (FM4 cardb.json row) replace it column-by-column,
  ## then apply ID/MediaName/BaseCost rewrites on top. Overlay only
  ## applies to columns the snippet actually carries — anything missing
  ## inherits donor's value, so FH1-only columns
  ## (OffRoadEnginePowerScale, IsRentable, etc.) stay coherent.
  ##
  ## Rewrite always runs LAST so the source's MediaName / Id values
  ## from the snippet don't leak through. BaseCost gets forced to 1
  ## regardless of what the snippet says.
  var colSqls: seq[string] = @[]
  var placeholders: seq[string] = @[]
  for c in colNames:
    colSqls.add(qIdent(c))
    placeholders.add("?")
  let q = "INSERT INTO " & qIdent(tbl) & " (" & colSqls.join(", ") &
          ") VALUES (" & placeholders.join(", ") & ")"
  var bound: seq[string] = @[]
  for i, c in colNames:
    var v = if i < row.len: row[i] else: ""
    # Snippet overlay applies to descriptive columns only. ID-shaped
    # columns must come from donor's value (which then runs through
    # rewriteId to become the new car's allocated ID); the snippet
    # carries the SOURCE game's Id, which is meaningless in target
    # space and would otherwise stomp on rw.newCarId mapping. Bug
    # symptom 2026-05-01: Data_Car.Id ended up == source FM4 Id while
    # per-car tables' Ordinal got rewriteId(donorCarId) == newCarId,
    # the two diverged, FH1 couldn't JOIN them, car silently dropped.
    let overlaid = (c in overlay) and (not isLikelyIdColumn(c))
    if overlaid:
      v = jsonToSqlString(overlay[c])
    bound.add(rewriteCell(c, v, rw, overlaid))
  dstDb.exec(sql(q), bound)

## Tables where snippet overlay is suppressed entirely (donor wins).
## Rationale: cross-game cross-engine ports inherit donor's audio config
## (CMT/ET XMLs are donor passthrough), so the DB row needs to MATCH
## donor's audio assumptions. Snippet (source-game cardb) overlaying
## these fields produced V8 vs V10 mismatches that broke audio init
## (broken RPM gauge + grey shaders observed on R8 port 2026-05-01).
const SnippetOverlaySuppressed: array[1, string] = ["Data_Engine"]

proc cloneTable(srcDb, dstDb: DbConn, tbl: string, rw: IdRewrite,
                snippet: JsonNode): int =
  ## Clone schema if needed, copy donor rows for this car with rewrites.
  ## When `snippet` carries rows for this table, donor's columns are
  ## overlaid with the snippet's values column-by-column (see
  ## insertRow). Returns row count inserted.
  if not tableExists(dstDb, tbl):
    let createSql = createTableSql(srcDb, tbl)
    dstDb.exec(sql(createSql))
  let cols = tableColumnNames(srcDb, tbl)
  let keyCol = keyColFor(srcDb, tbl)
  let donorRows = selectDonorRows(srcDb, tbl, keyCol, rw)
  let snippetRows =
    if tbl in SnippetOverlaySuppressed: @[]
    else: snippetRowsForTable(snippet, tbl)
  for i, r in donorRows:
    # Pair donor row[i] with snippet row[i] when both exist. v0:
    # positional pairing — works for the typical 1-row tables
    # (Data_Car, Data_Engine, List_Wheels). Multi-row tables
    # (CameraOverrides, CarExceptions) use snippet's row 0..N-1
    # against donor's 0..N-1; mismatch lengths fall back to donor-only
    # for the unpaired rows.
    let overlay =
      if i < snippetRows.len: snippetRows[i]
      else: initTable[string, JsonNode]()
    insertRow(dstDb, tbl, cols, r, rw, overlay)
  result = donorRows.len

proc buildMergeSlt*(srcGamedb, dstMergeSlt, donorMediaName, newMediaName: string,
                    dlcId: int,
                    snippet: JsonNode = newJNull(),
                    siblingDlcSlts: openArray[string] = [],
                    forcedCarId: int = 0,
                    forcedEngineId: int = 0):
                    tuple[carId: int; engineId: int;
                          perTableRows: Table[string, int]] =
  ## Driver. `dlcId` is used to allocate stable new car/engine IDs.
  ## Caller is responsible for ensuring `dstMergeSlt`'s parent dir exists
  ## and that any existing file at that path is the right one to extend
  ## (we OPEN, not OVERWRITE — but tables are recreated only if absent;
  ## existing rows under our newCarId would conflict on PK and raise).
  if not fileExists(srcGamedb):
    raise newException(DlcMergeError,
      "source gamedb missing: " & srcGamedb)
  if fileExists(dstMergeSlt):
    raise newException(DlcMergeError,
      "destination merge.slt already exists at " & dstMergeSlt &
      " — caller should remove it first to ensure a clean build")
  let srcDb = open(srcGamedb, "", "", "")
  defer: srcDb.close()
  let donorIds = lookupDonorIds(srcDb, donorMediaName)
  if donorIds.carId < 0:
    raise newException(DlcMergeError,
      "donor MediaName not in source Data_Car: " & donorMediaName)
  if donorIds.engineId < 0:
    raise newException(DlcMergeError,
      "donor MediaName not in source Data_Engine: " & donorMediaName)

  let newCarId =
    if forcedCarId > 0: forcedCarId
    else: findUnusedCarId(srcDb, dlcId, siblingDlcSlts)
  let newEngineId =
    if forcedEngineId > 0: forcedEngineId
    else: findUnusedEngineId(srcDb, dlcId, siblingDlcSlts)
  let newWheelId =
    if donorIds.wheelId > 0:
      findUnusedWheelId(srcDb, dlcId, siblingDlcSlts)
    else: 0
  let rw = IdRewrite(
    donorCarId: donorIds.carId,
    donorEngineId: donorIds.engineId,
    donorWheelId: donorIds.wheelId,
    newCarId: newCarId,
    newEngineId: newEngineId,
    newWheelId: newWheelId,
    donorMediaName: donorMediaName,
    newMediaName: newMediaName)

  let dstDb = open(dstMergeSlt, "", "", "")
  # CRITICAL: match the sample DLC's file format. FH1's bundled SQLite
  # parser is conservative; the working sample DLC merge.slt was created
  # with:
  #   - page_size = 1024 (modern SQLite defaults to 4096)
  #   - schema_format = 1 (modern defaults to 4)
  # Both pragmas MUST run before any table is created. VACUUM rewrites
  # the file to apply page_size; legacy_file_format=ON forces format 1
  # for any new DB created on this connection.
  dstDb.exec(sql"PRAGMA legacy_file_format = ON")
  dstDb.exec(sql"PRAGMA page_size = 1024")
  dstDb.exec(sql"VACUUM")

  result.carId = newCarId
  result.engineId = newEngineId
  result.perTableRows = initTable[string, int]()

  dstDb.exec(sql"BEGIN TRANSACTION")
  try:
    for tbl in DlcTables:
      let n = cloneTable(srcDb, dstDb, tbl, rw, snippet)
      result.perTableRows[tbl] = n
    # ContentOffers + ContentOffersMapping aren't donor-derived — they
    # describe THIS DLC's purchase offer and bind it to the new carId.
    # Without these rows the runtime won't surface the car in autoshow
    # (XamContentCreateEnumerator finds the package, but the autoshow
    # query joins ContentOffers/Mapping → no offer → no listing).
    # Was previously hand-applied via /tmp/merge_compare/post_port.sh;
    # wired in here so re-running port-to-dlc --replace doesn't drop it.
    # Format mirrors the sample DLC (4D5309C900000729) row shape.
    let offerId = 5571807927127299000 + dlcId
    let offerPk = "4D5309C90" & $dlcId & "FFFF"
    dstDb.exec(sql"""
      INSERT INTO "ContentOffers" VALUES
      (?, ?, '_&3100663008', '_&3100649066',
       ?, 2, 0, 1, '', '', 1, 1, 0, 0, 0, 0)""",
      offerPk, $offerId, $dlcId)
    dstDb.exec(sql"""
      INSERT INTO "ContentOffersMapping" VALUES (?, ?, ?, 1)""",
      $(dlcId * 1000 + newCarId), $offerId, $newCarId)
    result.perTableRows["ContentOffers"] = 1
    result.perTableRows["ContentOffersMapping"] = 1
    dstDb.exec(sql"COMMIT")
  except CatchableError as e:
    dstDb.exec(sql"ROLLBACK")
    raise newException(DlcMergeError,
      "buildMergeSlt failed mid-clone: " & e.msg)
  dstDb.close()
  # Force schema_format_number = 1 to match sample DLC's merge.slt.
  # PRAGMA legacy_file_format only governs DESC index encoding; the
  # format byte itself rises to 4 as soon as a table is created in a
  # modern SQLite. Manually patch byte 0x2C-0x2F of the closed file.
  # This is safe because the field describes which schema features the
  # file uses; we don't use any post-format-1 features (no DESC indexes,
  # no expression-DEFAULTs, no boolean literals).
  block:
    var f = open(dstMergeSlt, fmReadWriteExisting)
    defer: f.close()
    f.setFilePos(0x2C)
    let one: array[4, byte] = [0'u8, 0'u8, 0'u8, 1'u8]
    discard f.writeBytes(one, 0, 4)
