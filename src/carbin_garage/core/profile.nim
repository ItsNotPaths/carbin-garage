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

proc profilesDir*(): string =
  ## Conventional location: profiles/ next to the running binary.
  result = getAppDir() / "profiles"

proc loadProfileById*(id: string): GameProfile =
  loadProfile(profilesDir() / (id & ".json"))
