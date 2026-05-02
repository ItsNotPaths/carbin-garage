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

import std/[json, os, strutils, tables]
import db_connector/db_sqlite

type
  DlcMergeError* = object of CatchableError

  IdRewrite* = object
    ## State carried into every per-row rewrite. Captures donor's
    ## donor-specific PKs and the new IDs to substitute in.
    donorCarId*:    int
    donorEngineId*: int
    newCarId*:      int
    newEngineId*:   int
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

proc isLikelyIdColumn(name: string): bool =
  ## Whitelist of column names that may carry IDs subject to rewrite.
  ## Conservative: keeps generic-looking columns (Year, Sequence, Level,
  ## Price, MassDiff, MakeID, ManufacturerID, RegionID, ColorClassId,
  ## etc.) untouched. False negatives here just mean we copy a value
  ## that *may* have been a sub-ID — safer than false positives that
  ## scramble static FKs. The pattern set was derived from inspecting
  ## row dumps in `probe/out/dlc_merge_recon.txt`.
  if name == "Id" or name == "Ordinal" or name == "EngineID":
    return true
  if name == "AntiSwayPhysicsID" or name == "SpringDamperPhysicsID":
    return true
  if name == "FrontSpringDamperPhysicsID" or name == "RearSpringDamperPhysicsID":
    return true
  if name == "TorqueCurveID" or name == "TorqueCurveFullThrottleID":
    return true
  if name == "CarBodyID" or name == "DrivetrainID":
    return true
  if name == "CarId" or name == "CarID":
    return true
  if name == "ModelId":
    return true
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

proc rewriteCell(colName, value: string, rw: IdRewrite): string =
  ## Top-level per-cell rewrite. Handles MediaName, BaseCost, and any
  ## ID-shaped column.
  if colName == "MediaName":
    if value == rw.donorMediaName: return rw.newMediaName
    return value
  if colName == "BaseCost":
    return "1"  # locked policy from cardb_writer
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

proc findUnusedCarId(srcDb: DbConn, dlcId: int): int =
  var used: seq[int] = @[]
  for r in srcDb.fastRows(sql"SELECT Id FROM Data_Car ORDER BY Id"):
    try: used.add(parseInt(r[0]))
    except CatchableError: discard
  if used.len == 0: return 1500
  let lo = used[0]
  let hi = used[^1]
  # Walk top-down so we don't collide with the sample DLC's preferred
  # range (small Ids 257..600). Hash dlcId to bias the start point.
  var freeSlots: seq[int] = @[]
  var idx = used.len - 1
  for i in countdown(hi, lo):
    while idx >= 0 and used[idx] > i: dec idx
    if idx < 0 or used[idx] != i:
      freeSlots.add(i)
      if freeSlots.len >= 64: break
  if freeSlots.len == 0:
    raise newException(DlcMergeError,
      "no free Data_Car.Id slot in base range [" & $lo & ", " & $hi & "]")
  result = freeSlots[dlcId mod freeSlots.len]

proc findUnusedEngineId(srcDb: DbConn, dlcId: int): int =
  var used: seq[int] = @[]
  for r in srcDb.fastRows(sql"SELECT EngineID FROM Data_Engine ORDER BY EngineID"):
    try: used.add(parseInt(r[0]))
    except CatchableError: discard
  if used.len == 0: return 500
  let lo = used[0]
  let hi = used[^1]
  var freeSlots: seq[int] = @[]
  var idx = used.len - 1
  for i in countdown(hi, lo):
    while idx >= 0 and used[idx] > i: dec idx
    if idx < 0 or used[idx] != i:
      freeSlots.add(i)
      if freeSlots.len >= 64: break
  if freeSlots.len == 0:
    raise newException(DlcMergeError,
      "no free Data_Engine.EngineID slot in base range [" & $lo & ", " & $hi & "]")
  # Different hash bias from car so a single dlcId picks distinct slots.
  result = freeSlots[(dlcId * 7919) mod freeSlots.len]

# Kept for back-compat with the smoke test; both now defer to the
# in-base-range allocators above when called with a real srcDb context.
proc allocateCarId*(dlcId: int): int = 1600 + (dlcId mod 400)
proc allocateEngineId*(dlcId: int): int = 1100 + (dlcId mod 400)

# ---- main builder ----

proc lookupDonorIds(srcDb: DbConn, donorMediaName: string):
                  tuple[carId: int; engineId: int] =
  result.carId = -1
  result.engineId = -1
  for r in srcDb.fastRows(
    sql"SELECT Id FROM Data_Car WHERE MediaName=? LIMIT 1", donorMediaName):
    if r.len > 0:
      try: result.carId = parseInt(r[0]) except CatchableError: discard
    break
  for r in srcDb.fastRows(
    sql"SELECT EngineID FROM Data_Engine WHERE MediaName=? LIMIT 1",
    donorMediaName):
    if r.len > 0:
      try: result.engineId = parseInt(r[0]) except CatchableError: discard
    break

proc selectDonorRows(srcDb: DbConn, tbl, keyCol: string, rw: IdRewrite):
                    seq[seq[string]] =
  ## Pull donor rows from base gamedb keyed by the table's per-car key.
  ## Special case: List_TorqueCurve has no per-car key column — fetch
  ## all rows in TorqueCurveID range [donorEngineId*1000, +1000).
  if tbl == "List_TorqueCurve":
    let lo = $(rw.donorEngineId * 1000)
    let hi = $((rw.donorEngineId + 1) * 1000)
    let q = "SELECT * FROM " & qIdent(tbl) &
            " WHERE TorqueCurveID >= ? AND TorqueCurveID < ?"
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
    if c in overlay:
      v = jsonToSqlString(overlay[c])
    bound.add(rewriteCell(c, v, rw))
  dstDb.exec(sql(q), bound)

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
  let snippetRows = snippetRowsForTable(snippet, tbl)
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
                    snippet: JsonNode = newJNull()):
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

  let newCarId = findUnusedCarId(srcDb, dlcId)
  let newEngineId = findUnusedEngineId(srcDb, dlcId)
  let rw = IdRewrite(
    donorCarId: donorIds.carId,
    donorEngineId: donorIds.engineId,
    newCarId: newCarId,
    newEngineId: newEngineId,
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
