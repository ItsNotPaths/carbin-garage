## Per-machine GUI config: ~/.config/carbin-garage/config.json
## Sibling to mounts.json — kept separate so the mounts schema doesn't
## grow a dangling top-level key.
##
## Fields:
##   xeniaContent    — xenia content/ root used by export + auto-mount
##   exportHitboxes  — gate physicsdef collision shapes. Default ON
##                     keeps donor's collision verbatim. OFF replaces
##                     shapesAndChildren with `numShapes=0` so the car
##                     has no collision against walls/ground — useful
##                     for "drive off the map" / clipping exploration.

import std/[json, os]

type
  AppConfig* = object
    xeniaContent*: string
    exportHitboxes*: bool

proc defaultAppConfig(): AppConfig =
  AppConfig(exportHitboxes: true)

proc configFile*(): string =
  let xdg = getEnv("XDG_CONFIG_HOME")
  let base = if xdg.len > 0: xdg else: getEnv("HOME") / ".config"
  result = base / "carbin-garage" / "config.json"

proc loadAppConfig*(): AppConfig =
  result = defaultAppConfig()
  let path = configFile()
  if not fileExists(path): return
  let j =
    try: parseJson(readFile(path))
    except CatchableError: return
  if j.kind != JObject: return
  result.xeniaContent = j{"xeniaContent"}.getStr("")
  result.exportHitboxes = j{"exportHitboxes"}.getBool(true)

proc saveAppConfig*(c: AppConfig) =
  let path = configFile()
  createDir(parentDir(path))
  let j = %*{
    "xeniaContent":   c.xeniaContent,
    "exportHitboxes": c.exportHitboxes}
  writeFile(path, j.pretty)
