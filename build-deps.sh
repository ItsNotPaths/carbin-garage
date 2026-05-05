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

# Skip-if-built sentinels.
if [ -f "$PREFIX/lib/libSDL3.a" ] && \
   [ -f "$PREFIX/lib/libSDL3_image.a" ] && \
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
    echo "==> building $name ($TARGET)"
    cmake -S "$src" -B "$bdir" -G "Unix Makefiles" "${CMAKE_BASE_FLAGS[@]}" "${extra[@]}"
    cmake --build "$bdir" --parallel "$NCPU"
    cmake --install "$bdir"
}

# SDL3 backend opt-outs:
#   - libdecor + pipewire dev headers aren't available on Ubuntu 20.04 (jammy+
#     only). Wayland still works without libdecor (no client-side decorations
#     on GNOME); audio falls back to ALSA/Pulse without PipeWire.
#   - mingw-w64 7.x on focal lacks dxgidebug.h, which SDL3's d3d11/d3d12
#     renderers include. d3d9 (HAVE_D3D9_H) still builds; OpenGL/Vulkan paths
#     cover Windows fine.
SDL3_OPTOUT_FLAGS=()
if [ "$TARGET" = "linux" ]; then
    SDL3_OPTOUT_FLAGS+=("-DSDL_WAYLAND_LIBDECOR=OFF" "-DSDL_PIPEWIRE=OFF")
elif [ "$TARGET" = "windows" ]; then
    # mingw-w64 7.x on focal also lacks newer audioclient.h fields
    # (AudioClientProperties.Options, AUDCLNT_STREAMOPTIONS_RAW) used by
    # SDL3's WASAPI backend. DirectSound covers Windows audio output.
    SDL3_OPTOUT_FLAGS+=("-DSDL_RENDER_D3D11=OFF" "-DSDL_RENDER_D3D12=OFF" "-DSDL_WASAPI=OFF")
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
