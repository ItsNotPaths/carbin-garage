# Package
version       = "0.0.1"
author        = "paths"
description   = "Cross-game car-archive editor for Forza FM4 / FH1 (and other Xbox-360 era Forza titles)"
license       = "GPL-3.0-or-later"
srcDir        = "src"
bin           = @["carbin-garage"]
binDir        = "build"
namedBin["carbin_garage"] = "carbin-garage"

# Dependencies
requires "nim >= 2.2.0"
requires "db_connector >= 0.1.0"
# db_connector binds SQLite; used by core/cardb.nim to slurp per-car rows from
# each game's gamedb.slt at import time. SQLite is STATICALLY linked, not
# dlopen'd: download-deps.sh vendors the amalgamation, build-deps.sh compiles
# vendor/build/<target>/lib/libsqlite3.a, and nim.cfg's --dynlibOverride:sqlite3
# resolves the symbols at link time. No system libsqlite3.so / sqlite3.dll
# required at runtime on either platform.

# Native deps live under vendor/. Run ./download-deps.sh once to fetch them,
# then ./build-deps.sh to build SDL3 / SDL3_image / SDL3_ttf as static libs
# with their own dependencies vendored — single-binary distribution.
