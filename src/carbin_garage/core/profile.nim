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

  EditableStatSource* = enum
    ## Where this stat's authoritative value lives.
    ## - essCardb: gamedb.slt → cardb.json sidecar (UI-text fields like
    ##   display CurbWeight, Year, BaseCost)
    ## - essPhysicsdef: physicsdefinition.bin → physicsdef.json sidecar
    ##   (the values that actually drive simulation — inertia, AABB,
    ##   eventually mass)
    ## - essSynthetic: derived/computed value with no direct on-disk
    ##   storage. Each save invokes a `syntheticKind`-specific handler
    ##   (e.g. `physMassScale` multiplies the inertia tensors and
    ##   resets the input to its identity value).
    ## When the same conceptual stat exists in both sources, only the
    ## physicsdef entry is listed in `userEditableStats`; the cardb
    ## entry is dropped. The bin is the source of truth.
    essCardb = "cardb"
    essPhysicsdef = "physicsdef"
    essSynthetic = "synthetic"

  EditableStat* = object
    field*: string                 ## display name; matches column when synthetic absent
    table*: string                 ## gamedb table (typically "Data_Car")
    column*: string                ## gamedb column (essCardb) — also used as
                                   ## the persistence key in carslot.stats{}
    kind*: EditableStatKind
    minVal*: float                 ## lower bound for clamp; 0 if unused
    maxVal*: float                 ## upper bound for clamp; 0 if unused
    step*: float                   ## numeric step on Enter; 0 = free
    unit*: string                  ## display unit suffix ("kg", "rpm", "")
    enumValues*: seq[string]       ## populated when kind == eskEnum
    source*: EditableStatSource    ## defaults to essCardb (existing behavior)
    path*: string                  ## dotted JSON path into physicsdef.json
                                   ## (essPhysicsdef only; e.g.
                                   ## "forwardInertia.0.0", "aabbHalfExtents.0").
                                   ## Indexed array steps allowed.
    syntheticKind*: string         ## handler key (essSynthetic only).
                                   ## Recognised keys: "physMassScale".

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
        unit:   x{"unit"}.getStr(""),
        source:        parseEnum[EditableStatSource](x{"source"}.getStr("cardb")),
        path:          x{"path"}.getStr(""),
        syntheticKind: x{"syntheticKind"}.getStr(""))
      if x.hasKey("enumValues"):
        for v in x["enumValues"]:
          es.enumValues.add v.getStr
      # Sanity: physicsdef stats need a path; cardb stats need a column;
      # synthetic stats need a syntheticKind. Bad config = silent display
      # bug, so fail loudly at load time.
      case es.source
      of essPhysicsdef:
        if es.path.len == 0:
          raise newException(ValueError,
            "profile " & result.id & ": physicsdef stat \"" & es.field &
            "\" missing required `path`")
      of essCardb:
        if es.column.len == 0:
          raise newException(ValueError,
            "profile " & result.id & ": cardb stat \"" & es.field &
            "\" missing required `column`")
      of essSynthetic:
        if es.syntheticKind.len == 0:
          raise newException(ValueError,
            "profile " & result.id & ": synthetic stat \"" & es.field &
            "\" missing required `syntheticKind`")
      result.userEditableStats.add es

proc profilesDir*(): string =
  ## Conventional location: profiles/ next to the running binary.
  result = getAppDir() / "profiles"

proc loadProfileById*(id: string): GameProfile =
  loadProfile(profilesDir() / (id & ".json"))
