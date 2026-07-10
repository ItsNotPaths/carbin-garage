## Shared SQLite row-plumbing helpers.
##
## Collects the byte-identical helpers that had been copy-pasted across
## `cardb.nim` (import-time snippet extractor), `cardb_writer.nim`
## (same-game row patcher) and `dlc_merge.nim` (DLC merge.slt builder)
## during the bolt-on-fix era. Pure plumbing only — no game policy
## (ID allocation, rewrite rules, overlay precedence) lives here.

import std/[json, strutils, tables]
import db_connector/db_sqlite

type
  CardbColType* = enum cctInt, cctReal, cctText
  CardbColumn* = object
    name*: string
    sqlType*: string
    typ*: CardbColType
    nullable*: bool
    pk*: bool

proc classifyType*(t: string): CardbColType =
  let lc = t.toLowerAscii()
  if lc.contains("int"): cctInt
  elif lc.contains("real") or lc.contains("float") or lc.contains("doub") or lc.contains("num"):
    cctReal
  else: cctText

proc quoteIdent*(name: string): string =
  ## Wrap a SQL identifier in double quotes (SQLite delimited identifier
  ## syntax). Required because real Forza schemas contain colons,
  ## hyphens, and other punctuation in column names — e.g.
  ## `Time:0-60-sec`, `QuarterMileSpeed-mph`. Bare names with `:` get
  ## parsed as SQL parameters and prepare-fails. Embedded double quotes
  ## get doubled per SQL spec.
  result = "\"" & name.replace("\"", "\"\"") & "\""

proc allTableNames*(db: DbConn): seq[string] =
  for r in db.fastRows(sql"SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"):
    if r.len > 0: result.add(r[0])

proc tableColumns*(db: DbConn, tbl: string): seq[CardbColumn] =
  ## PRAGMA table_info returns rows of [cid, name, type, notnull, dflt_value, pk].
  for r in db.fastRows(sql("PRAGMA table_info(" & tbl & ")")):
    if r.len < 6: continue
    result.add(CardbColumn(
      name: r[1],
      sqlType: r[2],
      typ: classifyType(r[2]),
      nullable: r[3] == "0",
      pk: r[5] != "0"))

proc tableColumnNames*(db: DbConn, tbl: string): seq[string] =
  for r in db.fastRows(sql("PRAGMA table_info(" & tbl & ")")):
    if r.len >= 2: result.add(r[1])

proc tableHasColumn*(db: DbConn, tbl, col: string): bool =
  for r in db.fastRows(sql("PRAGMA table_info(" & tbl & ")")):
    if r.len >= 2 and r[1] == col: return true
  return false

proc carIdByMediaName*(db: DbConn, mediaName: string): int =
  ## -1 if the car is not in Data_Car. The MediaName comparison is
  ## case-sensitive on the SQL side; both FM4 and FH1 store the upper-
  ## cased zip basename verbatim so this matches the file system.
  result = -1
  for r in db.fastRows(sql"SELECT Id FROM Data_Car WHERE MediaName=? LIMIT 1", mediaName):
    if r.len > 0:
      try: result = parseInt(r[0])
      except CatchableError: discard
    break

proc jsonToSqlString*(v: JsonNode): string =
  ## Project a JSON value back to the string form db_connector's exec
  ## takes. JNull → empty string (db_connector binds it as NULL when
  ## paired with the column's default; for non-null cols this can fail —
  ## v0 accepts that risk, the donor's row almost always has a value).
  if v.isNil or v.kind == JNull: return ""
  case v.kind
  of JString: return v.getStr
  of JInt: return $v.getInt
  of JFloat: return $v.getFloat
  of JBool: return (if v.getBool: "1" else: "0")
  else: return $v

proc snippetRowsForTable*(snippet: JsonNode, tbl: string):
                          seq[Table[string, JsonNode]] =
  ## Pull `snippet.tables.<tbl>.rows` as a sequence of column→json maps.
  ## Returns empty if the snippet doesn't carry rows for this table (or
  ## isn't an object at all — dlc_merge passes `newJNull()` for
  ## no-snippet builds).
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
