## Helpers shared by the two port orchestrators (portto.nim = same-game
## overwrite, portto_dlc.nim = DLC packaging). Pure name/rename logic —
## no I/O beyond what the callers pass in.

import std/[os, strutils, tables]
import ../core/zip21

proc isCarbinName*(name: string): bool =
  name.toLowerAscii().endsWith(".carbin")

proc isStrippedCarbin*(name: string): bool =
  ## TypeId 0 stub carbins. Always pass through donor's bytes — format
  ## is unknown and we can't transcode anyway.
  extractFilename(name).toLowerAscii().startsWith("stripped_")

proc isXdsName*(name: string): bool =
  name.toLowerAscii().endsWith(".xds")

proc renamePrefixIn*(name, fromPrefix, toPrefix: string): string =
  ## Substring-replace the first occurrence of `fromPrefix` (case-
  ## insensitive) inside `name`, with `toPrefix` written in the casing
  ## that *matches* the donor occurrence's casing. So:
  ##   ALF_8C_08.carbin            +(ALF_8C_08, ALF_8C_08_FM4PORT) → ALF_8C_08_FM4PORT.carbin
  ##   ALF_8C_08_caliperLF_LOD0.carbin → ALF_8C_08_FM4PORT_caliperLF_LOD0.carbin
  ##   stripped_alf_8c_08_lod0.carbin (lowercase block)
  ##                              +(ALF_8C_08, ALF_8C_08_FM4PORT) → stripped_alf_8c_08_fm4port_lod0.carbin
  ## Returns the input unchanged if there's no match.
  let lc = name.toLowerAscii()
  let needle = fromPrefix.toLowerAscii()
  let idx = lc.find(needle)
  if idx < 0: return name
  let donorOcc = name[idx ..< idx + needle.len]
  # Decide replacement casing: if the donor occurrence is all lowercase,
  # write the new prefix lowercase too; otherwise use the new prefix
  # verbatim (mixed/upper).
  let replacement =
    if donorOcc == donorOcc.toLowerAscii(): toPrefix.toLowerAscii()
    else: toPrefix
  result = name[0 ..< idx] & replacement & name[idx + needle.len .. ^1]

proc buildRenames*(donorEntries: seq[Entry], donorSlug, newSlug: string):
                   Table[string, string] =
  ## Build the rename map for every donor entry whose name carries the
  ## donor's MediaName. Entries that don't reference donor's name (rare
  ## — `physicsdefinition.bin`, `versiondata.xml`, etc.) pass through
  ## unrenamed.
  result = initTable[string, string]()
  if donorSlug == newSlug: return
  for e in donorEntries:
    let renamed = renamePrefixIn(e.name, donorSlug, newSlug)
    if renamed != e.name:
      result[e.name] = renamed
