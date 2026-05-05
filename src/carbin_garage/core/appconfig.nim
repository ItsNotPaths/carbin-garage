## Per-machine GUI config: ~/.config/carbin-garage/config.json
## Today: just the xenia content directory used by port-to-dlc. Sibling
## to mounts.json — kept separate so the mounts schema doesn't grow a
## dangling top-level key.

import std/[json, os]

type
  AppConfig* = object
    xeniaContent*: string

proc configFile*(): string =
  let xdg = getEnv("XDG_CONFIG_HOME")
  let base = if xdg.len > 0: xdg else: getEnv("HOME") / ".config"
  result = base / "carbin-garage" / "config.json"

proc loadAppConfig*(): AppConfig =
  let path = configFile()
  if not fileExists(path): return
  let j =
    try: parseJson(readFile(path))
    except CatchableError: return
  if j.kind != JObject: return
  result.xeniaContent = j{"xeniaContent"}.getStr("")

proc saveAppConfig*(c: AppConfig) =
  let path = configFile()
  createDir(parentDir(path))
  let j = %*{"xeniaContent": c.xeniaContent}
  writeFile(path, j.pretty)
