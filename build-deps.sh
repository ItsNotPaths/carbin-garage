#!/usr/bin/env bash
# Builds the vendored C libs (SDL3, SDL3_image, SDL3_ttf) into
# vendor/build/<target>/. Always uses the SDL3_image / SDL3_ttf VENDORED=ON
# option so libpng / libjpeg / libwebp / libtiff / libfreetype / etc. are
# pulled in as static libs — no system-side runtime dependencies on those.
#
# Usage:
#   ./build-deps.sh                       # native target (linux)
#   ./build-deps.sh --target windows      # cross-compile via mingw-w64
#   ./build-deps.sh --clean               # wipe vendor/build/<target>/ and rebuild
#
# Idempotent: skips if libSDL3.a / libSDL3_image.a / libSDL3_ttf.a already
# exist for the target. release.sh / release.yml enumerate the resulting
# vendor/build/<target>/lib/*.a at link time and pass them via --passL.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VENDOR="$ROOT/vendor"

TARGET="linux"
CLEAN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="${2:-}"; shift 2 ;;
        --clean)  CLEAN=1; shift ;;
        -h|--help)
            sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

if [ "$TARGET" != "linux" ] && [ "$TARGET" != "windows" ]; then
    echo "error: --target must be linux or windows (got '$TARGET')" >&2
    exit 1
fi

OUT="$VENDOR/build/$TARGET"
PREFIX="$OUT"
NCPU=$(nproc 2>/dev/null || echo 4)

if [ $CLEAN -eq 1 ]; then
    echo "==> clean: removing $OUT"
    rm -rf "$OUT"
fi

mkdir -p "$OUT/lib" "$OUT/include"

# Skip-if-built sentinels. Mirror the actual build_one calls below — keep
# in sync if SDL3_image (currently skipped) gets re-enabled.
# SQLite amalgamation → static libsqlite3.a, built BEFORE the SDL sentinel so a
# tree that already has the (slow) SDL libs but not libsqlite3.a gets it without
# re-running the SDL cmake build. Linked into the binary via nim.cfg's
# --dynlibOverride:sqlite3 — no runtime dependency on a system libsqlite3.so /
# sqlite3.dll. Minimal feature set on purpose: we only read plain tables from
# each game's gamedb.slt, so FTS5/RTREE (which drag in libm and complicate
# static link order) stay off; OMIT_LOAD_EXTENSION keeps it free of any dlopen.
# Drops into vendor/build/<target>/lib/, which release.sh / release.yml already
# enumerate into the link --start-group.
if [ ! -f "$PREFIX/lib/libsqlite3.a" ]; then
    if [ ! -f "$VENDOR/sqlite/sqlite3.c" ]; then
        echo "error: vendor/sqlite/sqlite3.c missing — run ./download-deps.sh" >&2
        exit 1
    fi
    SQLITE_CC="gcc"; SQLITE_AR="ar"
    if [ "$TARGET" = "windows" ]; then
        if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
            echo "error: x86_64-w64-mingw32-gcc not found. Install mingw-w64." >&2
            exit 1
        fi
        SQLITE_CC="x86_64-w64-mingw32-gcc"; SQLITE_AR="x86_64-w64-mingw32-ar"
    fi
    echo "==> building sqlite3 ($TARGET)"
    "$SQLITE_CC" -O2 \
        -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DQS=0 \
        -c "$VENDOR/sqlite/sqlite3.c" -o "$OUT/sqlite3.o"
    "$SQLITE_AR" rcs "$PREFIX/lib/libsqlite3.a" "$OUT/sqlite3.o"
    rm -f "$OUT/sqlite3.o"
fi

if [ -f "$PREFIX/lib/libSDL3.a" ] && \
   [ -f "$PREFIX/lib/libSDL3_ttf.a" ]; then
    echo "==> $TARGET deps already built at $OUT (use --clean to rebuild)"
    exit 0
fi

# CMake toolchain selection.
CMAKE_BASE_FLAGS=(
    "-DCMAKE_BUILD_TYPE=Release"
    "-DCMAKE_INSTALL_PREFIX=$PREFIX"
    "-DBUILD_SHARED_LIBS=OFF"
    "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
    # SDL3 test binaries pull in CRC32 intrinsics that mingw-w64's libgcc
    # doesn't expose; nothing in this project consumes them anyway.
    "-DSDL_TESTS=OFF"
)

if [ "$TARGET" = "windows" ]; then
    if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
        echo "error: x86_64-w64-mingw32-gcc not found. Install mingw-w64." >&2
        exit 1
    fi
    CMAKE_BASE_FLAGS+=(
        "-DCMAKE_SYSTEM_NAME=Windows"
        "-DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc"
        "-DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++"
        "-DCMAKE_RC_COMPILER=x86_64-w64-mingw32-windres"
        "-DCMAKE_FIND_ROOT_PATH=/usr/x86_64-w64-mingw32"
        "-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER"
        "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY"
        "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY"
    )
fi

# VENDORED=ON for both targets — single-binary distribution. SDL3_image and
# SDL3_ttf bundle libpng/libjpeg/libwebp/libtiff/dav1d/avif/freetype/etc. as
# static .a files alongside their own.
SDL3_IMAGE_FLAGS=("-DSDL3IMAGE_VENDORED=ON" "-DSDL3IMAGE_BACKEND_STB=ON")
SDL3_TTF_FLAGS=("-DSDLTTF_VENDORED=ON" "-DSDLTTF_HARFBUZZ=OFF" "-DSDLTTF_PLUTOSVG=OFF")

build_one() {
    local name="$1"
    local src="$2"
    shift 2
    local extra=("$@")

    local bdir="$OUT/build-$name"
    # Stale-cache guard: a CMakeCache.txt pointing at a different source
    # path (e.g. docker's /src/... vs a host rebuild) blows up cmake with
    # "source does not match the source used to generate cache." Wipe the
    # build dir in that case — install artifacts under $PREFIX/lib are
    # untouched, so this only re-does the configure/build, not the install.
    if [ -f "$bdir/CMakeCache.txt" ]; then
        local cached_src
        cached_src=$(awk -F= '/^CMAKE_HOME_DIRECTORY:INTERNAL=/{print $2; exit}' "$bdir/CMakeCache.txt")
        if [ -n "$cached_src" ] && [ "$cached_src" != "$src" ]; then
            echo "==> stale cache in $bdir (was $cached_src, now $src) — wiping"
            rm -rf "$bdir"
        fi
    fi
    echo "==> building $name ($TARGET)"
    cmake -S "$src" -B "$bdir" -G "Unix Makefiles" "${CMAKE_BASE_FLAGS[@]}" "${extra[@]}"
    cmake --build "$bdir" --parallel "$NCPU"
    cmake --install "$bdir"
}

# Linux SDL3 backend opt-outs: libdecor + pipewire dev headers aren't available
# on Ubuntu 20.04 (jammy+ only). Wayland still works without libdecor (no
# client-side decorations on GNOME); audio falls back to ALSA/Pulse without
# PipeWire. Windows cross-build runs on jammy (release.yml) so its mingw-w64
# v10 has all the Windows SDK headers SDL3's d3d11/d3d12/WASAPI need.
SDL3_OPTOUT_FLAGS=()
if [ "$TARGET" = "linux" ]; then
    SDL3_OPTOUT_FLAGS+=("-DSDL_WAYLAND_LIBDECOR=OFF" "-DSDL_PIPEWIRE=OFF")
fi

build_one sdl3       "$VENDOR/sdl3"       -DSDL_STATIC=ON -DSDL_SHARED=OFF "${SDL3_OPTOUT_FLAGS[@]}"
# SDL3_image skipped: nothing in Nim code calls IMG_Load yet (we use stb_image
# from csrc/ for our own decoders). Re-enable once a real consumer needs it —
# its 3.4.2 CMake hits an upstream bug querying SDL_FULL_VERSION on the
# imported INTERFACE target. The Nim FFI bindings still compile because the
# headers live independently in vendor/sdl3_image/include/.
# build_one sdl3_image "$VENDOR/sdl3_image" "${SDL3_IMAGE_FLAGS[@]}" "-DSDL3_DIR=$PREFIX/lib/cmake/SDL3"
build_one sdl3_ttf   "$VENDOR/sdl3_ttf"   "${SDL3_TTF_FLAGS[@]}"   "-DSDL3_DIR=$PREFIX/lib/cmake/SDL3"

echo "==> $TARGET deps installed at $PREFIX"
echo "    static libs:"
ls "$PREFIX/lib"/*.a 2>/dev/null | sed 's|^|      |'
