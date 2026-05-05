## Pretty display + default-folder names for cars.
##
## Carbin slugs ship as `<MAKE>_<MODEL>_<YY>[_VARIANT]`, e.g. `ALF_8C_08`.
## This module turns those into human form like `Alfa Romeo 8C, 2008` for
## UI labels, and into the default working/ folder name when a car is
## imported from a game source — `[fh1] Alfa Romeo 8C 2008` (no comma so
## the folder name stays shell-friendly).
##
## All procs are idempotent: passing an already-pretty string back in
## returns it unchanged.

import std/[strutils, tables]

const
  MakeMap: Table[string, string] = {
    "ALF": "Alfa Romeo",
    "ASC": "Ascari",
    "AST": "Aston Martin",
    "AUD": "Audi",
    "BEN": "Bentley",
    "BMW": "BMW",
    "BUG": "Bugatti",
    "CAD": "Cadillac",
    "CHE": "Chevrolet",
    "CHR": "Chrysler",
    "CIT": "Citroen",
    "DOD": "Dodge",
    "FER": "Ferrari",
    "FIA": "Fiat",
    "FOR": "Ford",
    "GMC": "GMC",
    "HOL": "Holden",
    "HON": "Honda",
    "HSV": "HSV",
    "HUM": "Hummer",
    "HYU": "Hyundai",
    "INF": "Infiniti",
    "JAG": "Jaguar",
    "JEE": "Jeep",
    "KOE": "Koenigsegg",
    "LAM": "Lamborghini",
    "LAN": "Lancia",
    "LEX": "Lexus",
    "LOT": "Lotus",
    "LRO": "Land Rover",
    "MAS": "Maserati",
    "MAZ": "Mazda",
    "MCL": "McLaren",
    "MER": "Mercedes-Benz",
    "MIN": "Mini",
    "MIT": "Mitsubishi",
    "MOR": "Morgan",
    "NIS": "Nissan",
    "NOB": "Noble",
    "OPE": "Opel",
    "PAG": "Pagani",
    "PEU": "Peugeot",
    "PLY": "Plymouth",
    "PON": "Pontiac",
    "POR": "Porsche",
    "RAD": "Radical",
    "REN": "Renault",
    "ROL": "Rolls-Royce",
    "ROV": "Rover",
    "SAA": "Saab",
    "SAL": "Saleen",
    "SCI": "Scion",
    "SEA": "Seat",
    "SHE": "Shelby",
    "SUB": "Subaru",
    "SUZ": "Suzuki",
    "TOY": "Toyota",
    "TVR": "TVR",
    "VAU": "Vauxhall",
    "VOL": "Volvo",
    "VWW": "Volkswagen",
  }.toTable()

  ## YY ≤ this is treated as 20YY; otherwise 19YY. Forza-era cars run from
  ## the 1950s up through ~2012, so 30 cleanly splits modern from vintage.
  YearCentryCutoff = 30

proc isThreeUpper(s: string): bool =
  if s.len != 3: return false
  for c in s:
    if not c.isUpperAscii(): return false
  true

proc isTwoDigits(s: string): bool =
  if s.len != 2: return false
  for c in s:
    if not c.isDigit(): return false
  true

proc looksLikeSlug(s: string): bool =
  ## Heuristic: `<3-LETTER MAKE>_<...>_<YY>` with ≥2 underscores. The
  ## middle (model) section can be any case — Forza ships some carbins
  ## with mixed-case model names like `CorvetteStingray` or
  ## `f430Scuderia`. Already-pretty strings (containing spaces, commas,
  ## or a leading `[tag]`) skip the prettifier and pass through.
  if s.len == 0: return false
  if ' ' in s or ',' in s: return false
  if s.startsWith('['): return false
  if s.count('_') < 2: return false
  let parts = s.split('_')
  if parts.len < 3: return false
  isThreeUpper(parts[0]) and isTwoDigits(parts[parts.len - 1])

proc expandYear(yy: string): string =
  if yy.len != 2: return yy
  for c in yy:
    if not c.isDigit(): return yy
  let n = parseInt(yy)
  if n <= YearCentryCutoff: result = "20" & yy
  else:                     result = "19" & yy

proc prettyCarName*(slug: string): string =
  ## `ALF_8C_08` → `Alfa Romeo 8C, 2008`.
  ## Unknown make → falls back to the raw 3-letter code.
  ## Slug doesn't match the pattern → returned unchanged.
  if not looksLikeSlug(slug): return slug
  let parts = slug.split('_')
  if parts.len < 3: return slug
  let make = parts[0]
  let yy   = parts[parts.len - 1]
  let model = parts[1 .. parts.len - 2].join("_")
  let makerName = MakeMap.getOrDefault(make, make)
  let yearStr =
    if yy.len == 2 and yy.allCharsInSet({'0'..'9'}): expandYear(yy)
    else: yy
  result = makerName & " " & model & ", " & yearStr

proc gameTag*(gameId: string): string =
  ## "fh1" → "[fh1]". Empty → "".
  if gameId.len == 0: "" else: "[" & gameId.toLowerAscii() & "]"

proc defaultWorkingFolderName*(carbinSlug, gameId: string): string =
  ## Folder default for `Import to working/`. Comma-stripped pretty name
  ## with the source-game tag, e.g. `[fh1] Alfa Romeo 8C 2008`. Stays
  ## filesystem-safe (no commas, no leading dot, but allows spaces — the
  ## working/ scanner already tolerates spaces).
  let pretty = prettyCarName(carbinSlug).replace(",", "")
  let tag = gameTag(gameId)
  if tag.len == 0: pretty
  else:            tag & " " & pretty

proc prettyDisplayName*(name: string; gameId: string = ""): string =
  ## Universal display wrapper for any car-row label. Cases:
  ##   - already prefixed with `[xxx]` (working/ folder under the new
  ##     scheme): split off the tag, prettify the rest, recombine.
  ##   - bare slug under a per-game source column: prettify directly;
  ##     no tag prepended (the column header already names the game).
  ##   - already pretty (has spaces / commas): pass through.
  if name.startsWith('['):
    let close = name.find(']')
    if close > 0 and close + 1 < name.len:
      let tag  = name[0 .. close]
      let rest = name[close + 1 .. ^1].strip()
      return tag & " " & prettyCarName(rest)
  prettyCarName(name)
