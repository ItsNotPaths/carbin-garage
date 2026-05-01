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

# Native deps live under vendor/. Run ./download-deps.sh once to fetch them,
# then ./build-deps.sh to build SDL3 / SDL3_image / SDL3_ttf as static libs
# with their own dependencies vendored — single-binary distribution.
