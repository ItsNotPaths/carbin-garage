## Entry point. CLI for now (Phase 1); SDL3 UI added in Phase 3 per APPLET_ARCHITECTURE.md.

import std/[os, strutils]

const
  NAME = "carbin-garage"
  VERSION = "0.0.1"

proc usage() =
  echo NAME & " " & VERSION & """

usage:
  carbin-garage version
  carbin-garage list <game-folder>          (Phase 1, TODO)
  carbin-garage import <car.zip> [--out W]  (Phase 1, TODO)
  carbin-garage diff <a.zip> <b.zip>        (Phase 1, TODO)
  carbin-garage export <working-car> --target fm4|fh1   (Phase 2, TODO)
"""

proc main() =
  if paramCount() == 0:
    usage(); quit(0)
  case paramStr(1).toLowerAscii()
  of "version", "--version", "-v":
    echo VERSION
  of "help", "--help", "-h":
    usage()
  else:
    echo "TODO: command '" & paramStr(1) & "' not yet implemented"
    quit(1)

when isMainModule:
  main()
