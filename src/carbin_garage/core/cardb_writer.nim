## Per-car DB row patcher for `port-to`.
##
## **STATUS 2026-05-01: Direct gamedb.slt edits ruled out for cross-
## game ports.** In-game testing surfaced an undecodable SQL chain in
## the audio engine init that crashes the global render pipeline on
## open-world spawn (~30 tables of cloning didn't resolve it). The
## DLC packaging path uses a separate per-DLC `<id>00_merge.slt`
## that's merged into the live DB at boot — see `docs/PLAN_DLC_PIVOT.md`.
## A new merge.slt builder will replace this writer's role for cross-
## game ports. Same-game `export-to` may keep using a thinned-down
## version of this writer for in-place row edits, but the FK-chain
## clone logic should move to a merge-emitter that targets the 56
## tables DLCs actually use (this writer only handles ~6 directly).
##
## Counterpart to `core/cardb.nim` (the import-time reader). Takes a
## `cardb.json` snippet (captured at import) plus a donor's MediaName,
## and writes the rows into the target game's `gamedb.slt` so the
## new ported car shows up in the roster with sensible per-car data.
##
## ## Strategy
##
## The donor's existing row is the **template** + the FK-chain anchor.
## For each per-car table:
##   - If the source snippet has rows for it → overlay source's column
##     values on top of donor's row, then INSERT with a fresh PK and
##     adjusted MediaName / CarId pointing at the new car.
##   - If the source snippet does NOT have rows but the donor does →
##     copy donor's rows verbatim with adjusted MediaName / CarId (this
##     is what fills FH1's `E3Drivers` when porting from FM4, where the
##     source has no such table).
##
## Special-case ordering: `Data_Car` must be inserted first so that the
## newly-assigned `Data_Car.Id` is available as the FK anchor for child
## tables keyed on `CarId` / `CarID`.
##
## ## What this v0 does NOT do (deferred to Slice B / Phase 2b proper)
##
## - **FK chain following.** Columns like `Data_Car.PowertrainID`,
##   `Data_Car.EngineID`, `Data_Engine.TorqueCurveID` reference rows in
##   sibling tables. v0 inherits the donor's values for these columns
##   (so the FK targets remain valid in the target game). Overlaying
##   the source's FK values would point at IDs that may not exist in
##   the target's Powertrains / Combo_Engines / List_TorqueCurve
##   tables. Slice B walks each FK chain, copies the chained rows from
##   the source DB, and remaps IDs.
## - **Schema migration for non-`Data_Car` extra columns.** Same logic
##   as Data_Car (any column the snippet doesn't carry inherits donor's
##   value), no new entries.
##
## ## Error handling
##
## - newMediaName collides with an existing Data_Car row → raise unless
##   `replace = true` (in which case existing rows for that MediaName
##   are deleted across all per-car tables before insert).
## - donor MediaName not in Data_Car → raise.
## - target gamedb missing → raise.
##
## ## Idempotency
##
## With `replace = true`, running the same port twice produces the same
## final state. Without it, a re-run errors out on the collision check.

import std/[json, os, sequtils, strutils, tables]
import db_connector/db_sqlite
import ./cardb

type
  CardbWriteError* = object of CatchableError

  CardbPatchPlan* = object
    ## Human-readable description of what `applyCardbToTarget` will do.
    ## Returned by `planCardbPatch` for the --dry-run path.
    targetGamedb*: string
    donorMediaName*: string
    donorCarId*: int
    newMediaName*: string
    willReplace*: bool
    tableActions*: seq[CardbTableAction]

  CardbTableActionKind* = enum
    ctaInsertOverlay     ## donor row + source snippet overlay
    ctaInsertDonorClone  ## donor row only (snippet has no entry for this table)
    ctaSkipNoTemplate    ## neither donor nor snippet has rows here

  CardbTableAction* = object
    table*: string
    kind*: CardbTableActionKind
    keyColumn*: string         ## "MediaName" / "CarId" / "CarID"
    rowsFromDonor*: int
    rowsFromSnippet*: int
    rowsToInsert*: int

# ---- helpers ----

proc quoteIdent(name: string): string =
  ## Wrap a SQL identifier in double quotes (SQLite delimited identifier
  ## syntax). Required because real Forza schemas contain colons,
  ## hyphens, and other punctuation in column names — e.g.
  ## `Time:0-60-sec`, `QuarterMileSpeed-mph`. Bare names with `:` get
  ## parsed as SQL parameters and prepare-fails. Embedded double quotes
  ## get doubled per SQL spec.
  result = "\"" & name.replace("\"", "\"\"") & "\""

proc tableHasColumn(db: DbConn, tbl, col: string): bool =
  for r in db.fastRows(sql("PRAGMA table_info(" & tbl & ")")):
    if r.len >= 2 and r[1] == col: return true
  return false

proc allTableNames(db: DbConn): seq[string] =
  for r in db.fastRows(sql"SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"):
    if r.len > 0: result.add(r[0])

proc perCarKeyFor(db: DbConn, tbl: string): string =
  ## Returns "MediaName" / "CarId" / "CarID" if the table is per-car
  ## keyed; otherwise "" (table is global, skip).
  if tableHasColumn(db, tbl, "MediaName"): return "MediaName"
  if tableHasColumn(db, tbl, "CarId"):     return "CarId"
  if tableHasColumn(db, tbl, "CarID"):     return "CarID"
  return ""

proc tableColumns(db: DbConn, tbl: string): seq[CardbColumn] =
  for r in db.fastRows(sql("PRAGMA table_info(" & tbl & ")")):
    if r.len < 6: continue
    var colType: CardbColType
    let lc = r[2].toLowerAscii()
    if lc.contains("int"):
      colType = cctInt
    elif lc.contains("real") or lc.contains("float") or
         lc.contains("doub") or lc.contains("num"):
      colType = cctReal
    else:
      colType = cctText
    result.add(CardbColumn(
      name: r[1], sqlType: r[2], typ: colType,
      nullable: r[3] == "0", pk: r[5] != "0"))

proc carIdFor(db: DbConn, mediaName: string): int =
  result = -1
  for r in db.fastRows(sql"SELECT Id FROM Data_Car WHERE MediaName=? LIMIT 1", mediaName):
    if r.len > 0:
      try: result = parseInt(r[0])
      except CatchableError: discard
    break

proc fetchRowsAsDicts(db: DbConn, tbl, keyCol: string,
                     keyVal: string,
                     cols: seq[CardbColumn]): seq[Table[string, string]] =
  ## Returns each row as a Table<colName, rawString> (empty string = NULL
  ## per cardb.nim convention).
  let q = "SELECT * FROM " & quoteIdent(tbl) & " WHERE " &
          quoteIdent(keyCol) & "=?"
  for r in db.fastRows(sql(q), keyVal):
    var row = initTable[string, string]()
    for i, ci in cols:
      if i < r.len: row[ci.name] = r[i]
    result.add(row)

proc snippetRowsForTable(snippet: JsonNode, tbl: string): seq[Table[string, JsonNode]] =
  ## Re-cast the snippet's `tables.<tbl>.rows` into per-row dicts.
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

proc jsonToSqlString(v: JsonNode, ci: CardbColumn): string =
  ## Project a JSON value back to the string form db_connector's exec
  ## takes. JNull → empty string (db_connector binds it as NULL when
  ## paired with the column's default; for non-null cols this can fail —
  ## v0 accepts that risk, the donor's row almost always has a value).
  if v.isNil or v.kind == JNull: return ""
  case v.kind
  of JString:
    return v.getStr
  of JInt:
    return $v.getInt
  of JFloat:
    return $v.getFloat
  of JBool:
    return (if v.getBool: "1" else: "0")
  else:
    return $v

# ---- planning ----

proc planCardbPatch*(targetGamedb: string, snippet: JsonNode,
                     donorMediaName, newMediaName: string,
                     replace: bool = false): CardbPatchPlan =
  if not fileExists(targetGamedb):
    raise newException(CardbWriteError, "target gamedb missing: " & targetGamedb)
  let db = open(targetGamedb, "", "", "")
  defer: db.close()
  let donorCarId = carIdFor(db, donorMediaName)
  if donorCarId < 0:
    raise newException(CardbWriteError,
      "donor MediaName not in Data_Car: " & donorMediaName)
  result.targetGamedb = targetGamedb
  result.donorMediaName = donorMediaName
  result.donorCarId = donorCarId
  result.newMediaName = newMediaName
  result.willReplace = replace and carIdFor(db, newMediaName) >= 0

  for tbl in allTableNames(db):
    let keyCol = perCarKeyFor(db, tbl)
    if keyCol.len == 0: continue
    let cols = tableColumns(db, tbl)
    if cols.len == 0: continue
    let keyVal =
      if keyCol == "MediaName": donorMediaName
      else: $donorCarId
    let donorRows = fetchRowsAsDicts(db, tbl, keyCol, keyVal, cols)
    let snipRows = snippetRowsForTable(snippet, tbl)
    var act = CardbTableAction(
      table: tbl, keyColumn: keyCol,
      rowsFromDonor: donorRows.len,
      rowsFromSnippet: snipRows.len)
    if snipRows.len > 0:
      act.kind = ctaInsertOverlay
      act.rowsToInsert = snipRows.len
    elif donorRows.len > 0 and tbl != "Data_Car":
      act.kind = ctaInsertDonorClone
      act.rowsToInsert = donorRows.len
    elif tbl == "Data_Car" and donorRows.len > 0:
      act.kind = ctaInsertOverlay   # always overlay-or-clone Data_Car
      act.rowsToInsert = 1
    else:
      act.kind = ctaSkipNoTemplate
      act.rowsToInsert = 0
    result.tableActions.add(act)

proc describePatchPlan*(p: CardbPatchPlan): string =
  result.add "  donor: " & p.donorMediaName & "  (Data_Car.Id=" & $p.donorCarId & ")\n"
  result.add "  newMediaName: " & p.newMediaName & "\n"
  if p.willReplace:
    result.add "  ! existing rows for newMediaName will be DELETED first\n"
  for a in p.tableActions:
    if a.kind == ctaSkipNoTemplate:
      result.add "    " & a.table & "  skip (no template)\n"
    else:
      let kindStr = (case a.kind
        of ctaInsertOverlay: "overlay"
        of ctaInsertDonorClone: "donor-clone"
        of ctaSkipNoTemplate: "skip")
      result.add "    " & a.table & "  " & kindStr &
                 "  donor=" & $a.rowsFromDonor &
                 "  snippet=" & $a.rowsFromSnippet &
                 "  insert=" & $a.rowsToInsert & "\n"

# ---- execute ----

proc deleteExistingRows(db: DbConn, mediaName: string) =
  ## Wipe every per-car row keyed on this MediaName (or its corresponding
  ## CarId in Data_Car). Used by --replace.
  let oldCarId = carIdFor(db, mediaName)
  for tbl in allTableNames(db):
    let keyCol = perCarKeyFor(db, tbl)
    if keyCol.len == 0: continue
    let keyVal =
      if keyCol == "MediaName": mediaName
      else: $oldCarId
    if keyCol == "MediaName":
      db.exec(sql("DELETE FROM " & quoteIdent(tbl) & " WHERE MediaName=?"), keyVal)
    else:
      if oldCarId < 0: continue
      db.exec(sql("DELETE FROM " & quoteIdent(tbl) & " WHERE " &
                  quoteIdent(keyCol) & "=?"), keyVal)

proc buildInsertRow(donorRow: Table[string, string],
                    snipRow: Table[string, JsonNode],
                    cols: seq[CardbColumn],
                    overrides: Table[string, string]): seq[string] =
  ## Compose the insert values column-by-column.
  ## Precedence: overrides > snippet > donor.
  ## PK columns are dropped (caller emits an INSERT that omits the PK so
  ## SQLite autoincrements it).
  result = @[]
  for ci in cols:
    if ci.pk: continue
    if ci.name in overrides:
      result.add(overrides[ci.name])
      continue
    if ci.name in snipRow:
      result.add(jsonToSqlString(snipRow[ci.name], ci))
      continue
    if ci.name in donorRow:
      result.add(donorRow[ci.name])
      continue
    result.add("")  # NULL fallback

proc colNamesNoPkQuoted(cols: seq[CardbColumn]): seq[string] =
  for ci in cols:
    if not ci.pk: result.add(quoteIdent(ci.name))

proc insertRow(db: DbConn, tbl: string, cols: seq[CardbColumn],
               values: seq[string]): int =
  ## Returns SQLite last_insert_rowid().
  let names = colNamesNoPkQuoted(cols)
  let placeholders = repeat("?", names.len).join(",")
  let q = "INSERT INTO " & quoteIdent(tbl) & " (" & names.join(",") &
          ") VALUES (" & placeholders & ")"
  db.exec(sql(q), values)
  for r in db.fastRows(sql"SELECT last_insert_rowid()"):
    if r.len > 0:
      try: return parseInt(r[0])
      except CatchableError: discard
  return -1

const DefaultDataCarOverrides*: array[2, tuple[col, val: string]] = [
  ## Applied on top of (donor + snippet) for the new car's Data_Car row.
  ## - `BaseCost = 1` makes the ported car trivially buyable in-game so
  ##   a fresh port shows up with effectively-free cost in the dealer.
  ## - `IsPurchased = 0` is required for the new car to *appear* in the
  ##   Autoshow / dealer. Donor's row carries `IsPurchased = 1` (which
  ##   in static gamedb means "owned by default in fresh profiles") and
  ##   inheriting that hides the new car from the buy list. Resetting to
  ##   0 puts it in the for-sale roster for existing saves.
  ## Columns are silently skipped if the target schema lacks them.
  ("BaseCost", "1"),
  ("IsPurchased", "0")]

proc applyCardbToTarget*(targetGamedb: string, snippet: JsonNode,
                        donorMediaName, newMediaName: string,
                        replace: bool = false,
                        extraDataCarOverrides: openArray[tuple[col, val: string]] =
                          DefaultDataCarOverrides): int =
  ## Apply the snippet to `targetGamedb`. Returns the newly-assigned
  ## `Data_Car.Id` for the ported car.
  ##
  ## Strategy summary (full doc at module top):
  ##   1. Validate target gamedb + donor MediaName.
  ##   2. If `replace`, delete any existing rows for `newMediaName`.
  ##   3. Insert Data_Car: donor's row overlaid with snippet + the
  ##      caller's overrides (default: BaseCost=1), MediaName replaced
  ##      with newMediaName, PK dropped → autoinc.
  ##   4. For every other per-car table: insert overlay (snippet over
  ##      donor) or donor-clone (no snippet rows), with the MediaName /
  ##      CarId column rewritten to point at the new car.
  if not fileExists(targetGamedb):
    raise newException(CardbWriteError, "target gamedb missing: " & targetGamedb)
  let db = open(targetGamedb, "", "", "")
  defer: db.close()

  let donorCarId = carIdFor(db, donorMediaName)
  if donorCarId < 0:
    raise newException(CardbWriteError,
      "donor MediaName not in Data_Car: " & donorMediaName)

  let collision = carIdFor(db, newMediaName) >= 0
  if collision and not replace:
    raise newException(CardbWriteError,
      "newMediaName already exists in Data_Car: " & newMediaName &
      " (re-run with replace=true to overwrite)")
  if collision and replace:
    deleteExistingRows(db, newMediaName)

  # 1. Data_Car first to get newCarId.
  let dcCols = tableColumns(db, "Data_Car")
  if dcCols.len == 0:
    raise newException(CardbWriteError, "target has no Data_Car table?")
  let dcDonorRows = fetchRowsAsDicts(db, "Data_Car", "MediaName",
                                     donorMediaName, dcCols)
  if dcDonorRows.len == 0:
    raise newException(CardbWriteError, "donor Data_Car row vanished")
  let dcSnipRows = snippetRowsForTable(snippet, "Data_Car")
  let dcSnip = if dcSnipRows.len > 0: dcSnipRows[0] else: initTable[string, JsonNode]()
  var overrides = initTable[string, string]()
  overrides["MediaName"] = newMediaName
  # Apply caller-supplied overrides last so they win over donor + snippet.
  # Non-existent columns are harmless — buildInsertRow only reads keys
  # that match real columns. Default sets BaseCost=1.
  let dcColNames = dcCols.mapIt(it.name)
  for ov in extraDataCarOverrides:
    if ov.col in dcColNames:
      overrides[ov.col] = ov.val
  let dcValues = buildInsertRow(dcDonorRows[0], dcSnip, dcCols, overrides)
  let newCarId = insertRow(db, "Data_Car", dcCols, dcValues)
  if newCarId < 0:
    raise newException(CardbWriteError, "Data_Car insert returned no rowid")

  # 2. All other per-car tables.
  for tbl in allTableNames(db):
    if tbl == "Data_Car": continue
    let keyCol = perCarKeyFor(db, tbl)
    if keyCol.len == 0: continue
    let cols = tableColumns(db, tbl)
    if cols.len == 0: continue
    let keyVal =
      if keyCol == "MediaName": donorMediaName
      else: $donorCarId
    let donorRows = fetchRowsAsDicts(db, tbl, keyCol, keyVal, cols)
    let snipRows = snippetRowsForTable(snippet, tbl)
    var ovr = initTable[string, string]()
    if keyCol == "MediaName":
      ovr["MediaName"] = newMediaName
    else:
      ovr[keyCol] = $newCarId
    if snipRows.len > 0:
      # Overlay path — pair source rows with donor's first row as
      # template (each source row may not have all columns).
      let templateRow =
        if donorRows.len > 0: donorRows[0]
        else: initTable[string, string]()
      for sr in snipRows:
        let vals = buildInsertRow(templateRow, sr, cols, ovr)
        discard insertRow(db, tbl, cols, vals)
    elif donorRows.len > 0:
      # Donor-clone: snippet is silent on this table (e.g. FH1's
      # E3Drivers when porting from FM4). Replicate donor's rows.
      for dr in donorRows:
        let vals = buildInsertRow(dr, initTable[string, JsonNode](), cols, ovr)
        discard insertRow(db, tbl, cols, vals)
    # else: nothing on either side, skip.

  result = newCarId

# ---- top-level orchestration helpers ----

proc loadCardbSnippet*(workingCar: string): JsonNode =
  ## Read working/<slug>/cardb.json. Raises if missing — port-to needs
  ## the snippet to know what to write.
  let path = workingCar / "cardb.json"
  if not fileExists(path):
    raise newException(CardbWriteError,
      "no cardb.json in " & workingCar &
      " — re-import the source car so the per-car DB rows get captured")
  result = parseJson(readFile(path))

proc snippetMediaName*(snippet: JsonNode): string =
  if snippet.hasKey("mediaName"): snippet["mediaName"].getStr
  else: ""
