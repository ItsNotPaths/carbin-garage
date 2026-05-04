## carbin-garage entry point.
##
## Default mode is the SDL3 GUI. Any subcommand or `--cli` flag drops into
## the existing CLI dispatcher unchanged. Bare invocation with no controlling
## TTY (e.g. piped) falls back to printing CLI usage instead of opening a
## window.

import std/[os, terminal]
import carbin_garage/cli
import gui/app as gui

when isMainModule:
  var args: seq[string] = @[]
  for i in 1 .. paramCount():
    args.add(paramStr(i))

  # Strip a leading --cli (treat as "force CLI" hint, then route by remaining args).
  var forceCli = false
  if args.len > 0 and args[0] == "--cli":
    forceCli = true
    args.delete(0)

  # Strip a leading --gui (explicit GUI even with later args, mostly for symmetry).
  var forceGui = false
  if args.len > 0 and args[0] == "--gui":
    forceGui = true
    args.delete(0)

  if forceGui:
    gui.main()
  elif forceCli or args.len > 0:
    cli.mainWithArgs(args)
  else:
    if isatty(stdout):
      gui.main()
    else:
      cli.mainWithArgs(@[])  # prints usage and exits
