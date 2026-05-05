## GameProfile struct + JSON loader. Single source of truth for per-game
## quirks (carbin TypeId, header length, db strategy, etc.). Orchestrator
## branches on profile data, not hardcoded enums.
##
## Spec: docs/APPLET_ARCHITECTURE.md §"What `GameProfile` is for".
## Profiles ship under profiles/<id>.json next to the binary.

import std/[json, os]

type
  Casing* = enum
    casingLower = "Lower"
    casingMixed = "Mixed"

  DbStrategy* = enum
    dbSqlitePatch = "SqlitePatch"     # FM4: patch gamedb.slt
    dbPerCarBin   = "PerCarBin"        # FH1: physicsdefinition.bin per car
    dbDatabaseXmplr = "DatabaseXmplr"  # FM3 (TBD)
    dbUnsupported = "Unsupported"      # stub profile

  EditableStatKind* = enum
    eskFloat = "float"
    eskInt   = "int"
    eskBool  = "bool"
    eskEnum  = "enum"

  EditableStat* = object
    field*: string                 ## display name; matches column when synthetic absent
    table*: string                 ## gamedb table (typically "Data_Car")
    column*: string                ## gamedb column
    kind*: EditableStatKind
    minVal*: float                 ## lower bound for clamp; 0 if unused
    maxVal*: float                 ## upper bound for clamp; 0 if unused
    step*: float                   ## numeric step on Enter; 0 = free
    unit*: string                  ## display unit suffix ("kg", "rpm", "")
    enumValues*: seq[string]       ## populated when kind == eskEnum

  GameProfile* = object
    id*: string
    displayName*: string
    titleId*: string
    contentId*: string
    cars*: string
    casing*: Casing
    carbinTypeId*: int
    carbinHeaderLen*: int
    requiresStripped*: bool
    requiresPhysicsBin*: bool
    requiresVersionData*: bool
    extraXdsBuckets*: seq[string]
    gamedbPath*: string
    dbStrategy*: DbStrategy
    indexBufferVersion*: int
    colVersion*: int
    rmbBinVersion*: int
    canUnbundle*: bool
    canBundle*: bool
    userEditableStats*: seq[EditableStat]

proc parseEnum[T: enum](s: string): T =
  for v in T.low .. T.high:
    if $v == s: return v
  raise newException(ValueError, "unknown enum value: " & s)

proc loadProfile*(path: string): GameProfile =
  let j = parseJson(readFile(path))
  result = GameProfile(
    id:                  j["id"].getStr,
    displayName:         j["displayName"].getStr,
    titleId:             j["titleId"].getStr,
    contentId:           j["contentId"].getStr,
    cars:                j["cars"].getStr,
    casing:              parseEnum[Casing](j["casing"].getStr),
    carbinTypeId:        j["carbinTypeId"].getInt,
    carbinHeaderLen:     j["carbinHeaderLen"].getInt,
    requiresStripped:    j["requiresStripped"].getBool,
    requiresPhysicsBin:  j["requiresPhysicsBin"].getBool,
    requiresVersionData: j["requiresVersionData"].getBool,
    extraXdsBuckets:     @[],
    gamedbPath:          j["gamedbPath"].getStr,
    dbStrategy:          parseEnum[DbStrategy](j["dbStrategy"].getStr),
    indexBufferVersion:  j["indexBufferVersion"].getInt,
    colVersion:          j["colVersion"].getInt,
    rmbBinVersion:       j["rmbBinVersion"].getInt,
    canUnbundle:         j["canUnbundle"].getBool,
    canBundle:           j["canBundle"].getBool,
  )
  for x in j["extraXdsBuckets"]:
    result.extraXdsBuckets.add(x.getStr)
  if j.hasKey("userEditableStats"):
    for x in j["userEditableStats"]:
      var es = EditableStat(
        field:  x{"field"}.getStr,
        table:  x{"table"}.getStr("Data_Car"),
        column: x{"column"}.getStr,
        kind:   parseEnum[EditableStatKind](x{"kind"}.getStr("float")),
        minVal: x{"min"}.getFloat(0.0),
        maxVal: x{"max"}.getFloat(0.0),
        step:   x{"step"}.getFloat(0.0),
        unit:   x{"unit"}.getStr(""))
      if x.hasKey("enumValues"):
        for v in x["enumValues"]:
          es.enumValues.add v.getStr
      result.userEditableStats.add es

proc profilesDir*(): string =
  ## Conventional location: profiles/ next to the running binary.
  result = getAppDir() / "profiles"

proc loadProfileById*(id: string): GameProfile =
  loadProfile(profilesDir() / (id & ".json"))
