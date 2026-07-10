## Per-car DB snippet extractor.
##
## Each Forza title we touch ships a SQLite file (`gamedb.slt`) that
## carries per-car rows: `Data_Car`, `Data_Engine`, suspension /
## torque-curve / aero / friction lists, plus career hooks
## (`CarExceptions`, `CameraOverrides`, etc.). The schema is shared
## between FM4 and FH1 — same primary keys, same column names, mostly
## the same row counts. Writing the per-car rows out of one DB and into
## another's is what lets the working car behave as a single self-
## contained file even though the game's actual data lives in two
## places (the .zip archive + a row inside a global SQLite blob).
##
## What this module does at import time:
##   1. Open `gamedb.slt` read-only.
##   2. Look up the car's `Id` from `Data_Car` keyed on `MediaName`
##      (= the zip basename, case-insensitive in the games but stored
##      verbatim in the DB).
##   3. Walk every table in the file. For each:
##        - If it has a `MediaName` column, capture rows where MediaName
##          matches the car (catches tables like Data_Car, Data_Engine,
##          List_Wheels — anything keyed by media-name string).
##        - Else if it has a `CarId` or `CarID` column, capture rows
##          where that column equals Data_Car.Id (catches Career /
##          camera / exception lookups).
##   4. Emit a JSON snippet per-table that records column names, SQL
##      types, and rows — enough for an export pipeline to reconstruct
##      INSERT/UPDATE statements without reopening the source DB.
##
## NULL handling: db_connector's SQLite reader collapses NULLs to empty
## strings. We treat empty TEXT as NULL when round-tripping into the
## target DB; for INTEGER/REAL columns an empty string parses as JNull.
## This is lossy at the column level but matches what the game DBs
## actually carry — we haven't seen a per-car row with a meaningful
## "" string yet.
##
## What this module deliberately does NOT do:
##   - Walk foreign-key chains (Data_Car.PowertrainID → Powertrains,
##     Data_Engine.TorqueCurveID → List_TorqueCurve, etc.). The plan is
##     to add a profile-driven FK map later; for v1 we capture the
##     direct per-car rows and rely on the export-side patcher to map
##     IDs through.
##   - Schema migration between games. FM4 ↔ FH1 row shape is
##     near-identical (verified for ALF_8C_08), but FH1 added some
##     columns. Resolution is deferred until export-to-FH1 lands.

import std/[json, os, sequtils, strutils]
import db_connector/db_sqlite
import ./profile
import ./sqlite_util

# Re-export the shared column types (CardbColType / CardbColumn used to
# live here; downstream modules still reach them via `import ./cardb`).
export sqlite_util

const SchemaTag* = "carbin-garage.cardb/1"

type
  CardbExtractError* = object of CatchableError

proc valueAsJson(v: string, ci: CardbColumn): JsonNode =
  if v.len == 0:
    return newJNull()
  case ci.typ
  of cctInt:
    try: return %parseBiggestInt(v)
    except CatchableError: return %v
  of cctReal:
    try: return %parseFloat(v)
    except CatchableError: return %v
  of cctText:
    return %v

proc encodeRows(db: DbConn, schema: seq[CardbColumn], query: string,
                args: varargs[string]): JsonNode =
  result = newJArray()
  for r in db.fastRows(sql(query), args):
    var rowObj = newJObject()
    for i, ci in schema:
      if i < r.len:
        rowObj[ci.name] = valueAsJson(r[i], ci)
    result.add(rowObj)

proc listMediaNames*(gamedbPath: string): seq[string] =
  ## Enumerate every `Data_Car.MediaName` in the game DB. Used by the GUI
  ## bottom-dropup row to show every car the game knows about (including
  ## ones whose carbin is bundled in a base-game .CAB rather than a loose
  ## .zip in `cars/`). Returns [] if the DB is missing or the table doesn't
  ## have a MediaName column.
  if not fileExists(gamedbPath): return @[]
  let db =
    try: open(gamedbPath, "", "", "")
    except CatchableError: return @[]
  defer: db.close()
  for r in db.fastRows(sql"SELECT MediaName FROM Data_Car ORDER BY MediaName"):
    if r.len > 0 and r[0].len > 0:
      result.add(r[0])

proc extractCarDb*(gamedbPath: string, mediaName: string,
                   originGame: string = ""): JsonNode =
  ## Read every per-car row across the game DB into a JSON snippet.
  ## Raises `CardbExtractError` if the file is missing or the car isn't
  ## in `Data_Car`.
  if not fileExists(gamedbPath):
    raise newException(CardbExtractError, "gamedb not found: " & gamedbPath)
  let db = open(gamedbPath, "", "", "")
  defer: db.close()

  let carId = carIdByMediaName(db, mediaName)
  if carId < 0:
    raise newException(CardbExtractError,
      "MediaName not in Data_Car: " & mediaName)

  var tablesNode = newJObject()
  for tbl in allTableNames(db):
    let cols = tableColumns(db, tbl)
    if cols.len == 0: continue
    let colNames = cols.mapIt(it.name)
    var keyMode = ""
    var rows: JsonNode = nil
    if "MediaName" in colNames:
      rows = encodeRows(db, cols,
        "SELECT * FROM " & tbl & " WHERE MediaName=?", mediaName)
      keyMode = "MediaName"
    elif "CarId" in colNames:
      rows = encodeRows(db, cols,
        "SELECT * FROM " & tbl & " WHERE CarId=?", $carId)
      keyMode = "CarId"
    elif "CarID" in colNames:
      rows = encodeRows(db, cols,
        "SELECT * FROM " & tbl & " WHERE CarID=?", $carId)
      keyMode = "CarID"
    elif tbl == "Data_CarBody" and "Id" in colNames:
      # Sub-id keyed (Id = carId*1000 + slot). Carries the car's MODEL
      # dimensions — ModelWheelbase / track / ride heights + the
      # PristineBoundingBox. The runtime places wheels and the hitbox
      # from THIS row (physics/maxdata.xml is only its offline source) —
      # leaving donor-cloned values puts a donor-sized frame under the
      # ported body (S65-on-SL65, 2026-07-10). Captured here so the
      # export-side snippet overlay carries source dimensions.
      rows = encodeRows(db, cols,
        "SELECT * FROM " & tbl & " WHERE Id >= ? AND Id < ?",
        $(carId * 1000), $((carId + 1) * 1000))
      keyMode = "SubId"
    elif tbl == "CarPartPositions" and "Ordinal" in colNames:
      # Ordinal-keyed anchor points (PartId + world pos — lights,
      # exhausts, effects). Same rationale as Data_CarBody: donor's
      # anchors sit at donor dimensions.
      rows = encodeRows(db, cols,
        "SELECT * FROM " & tbl & " WHERE Ordinal=?", $carId)
      keyMode = "Ordinal"
    if rows != nil and rows.len > 0:
      tablesNode[tbl] = %*{
        "key":     keyMode,
        "schema":  colNames,
        "types":   cols.mapIt(it.sqlType),
        "rows":    rows}

  result = %*{
    "schema":     SchemaTag,
    "originGame": originGame,
    "mediaName":  mediaName,
    "carId":      carId,
    "tables":     tablesNode}

proc resolveGameRoot*(zipPath, carsRel: string): string =
  ## Game root = strip `<carsRel>/<zipname>` off the zip path. Walks up
  ## one parentDir for the filename plus one for each component in
  ## `carsRel` (typically "Media/cars" → 2 components).
  result = parentDir(zipPath)   # → carsRel folder
  for p in carsRel.split({'/', '\\'}):
    if p.len > 0:
      result = parentDir(result)

proc gamedbPathFromZip*(zipPath: string, profile: GameProfile): string =
  ## "" if the profile doesn't declare a gamedb path. Otherwise the
  ## absolute path to the gamedb.slt that pairs with this zip.
  if profile.gamedbPath.len == 0: return ""
  let root = resolveGameRoot(zipPath, profile.cars)
  result = root / profile.gamedbPath

proc extractCarDbFromZip*(zipPath: string, profile: GameProfile,
                          mediaName: string): JsonNode =
  ## Convenience wrapper used by the importer: derives the gamedb path
  ## from a zip's location plus its profile and pulls the snippet.
  let dbPath = gamedbPathFromZip(zipPath, profile)
  if dbPath.len == 0:
    raise newException(CardbExtractError,
      "profile " & profile.id & " has no gamedbPath")
  extractCarDb(dbPath, mediaName, profile.id)
