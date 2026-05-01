## carbin-garage entry point. Dispatches to the CLI subcommand router.
## SDL3 UI is added in Phase 3 per docs/APPLET_ARCHITECTURE.md.

import carbin_garage/cli

when isMainModule:
  cli.main()
