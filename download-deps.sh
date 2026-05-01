#!/usr/bin/env bash
# Fetches third-party deps into vendor/. Run once before building.
set -euo pipefail

VENDOR="$(cd "$(dirname "$0")" && pwd)/vendor"

fetch() {
    local name="$1"
    local url="$2"
    local dest="$3"
    local strip="${4:-1}"
    local filter="${5:-}"

    if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
        echo "  already present: $(basename "$dest")"
        return
    fi

    echo "  downloading $name..."
    mkdir -p "$dest"
    if [ -n "$filter" ]; then
        curl -fsSL "$url" | tar xz --strip-components="$strip" -C "$dest" --wildcards "$filter"
    else
        curl -fsSL "$url" | tar xz --strip-components="$strip" -C "$dest"
    fi
    echo "  done."
}

echo "==> sdl3"
fetch "sdl3" \
    "https://github.com/libsdl-org/SDL/releases/download/release-3.4.4/SDL3-3.4.4.tar.gz" \
    "$VENDOR/sdl3"

echo "==> sdl3_image"
fetch "sdl3_image" \
    "https://github.com/libsdl-org/SDL_image/releases/download/release-3.4.2/SDL3_image-3.4.2.tar.gz" \
    "$VENDOR/sdl3_image"

echo "==> sdl3_ttf"
fetch "sdl3_ttf" \
    "https://github.com/libsdl-org/SDL_ttf/releases/download/release-3.2.2/SDL3_ttf-3.2.2.tar.gz" \
    "$VENDOR/sdl3_ttf"

PATCHES_DIR="$(cd "$(dirname "$0")" && pwd)/patches"

# Two LZX libraries, each used for what it does well:
#   * libmspack lzxd — Microsoft CAB-LZX decoder (Forza Method-21 native)
#   * wimlib lzx_compress — LGPL LZX encoder (wimlib's own decoder is the
#     WIM-restricted variant and isn't a fit for CAB-LZX bitstreams).
# Total vendored footprint is comparable to a wimlib-only setup with a
# growing patch series, with zero integration risk on the decoder.
echo "==> libmspack (CAB-LZX decoder)"
if [ -d "$VENDOR/libmspack" ] && [ -n "$(ls -A "$VENDOR/libmspack" 2>/dev/null)" ]; then
    echo "  already present: libmspack"
else
    echo "  cloning libmspack..."
    git clone --depth=1 "https://github.com/kyz/libmspack.git" "$VENDOR/libmspack"
    echo "  done."
fi

echo "==> wimlib (LZX encoder)"
if [ -d "$VENDOR/wimlib" ] && [ -n "$(ls -A "$VENDOR/wimlib" 2>/dev/null)" ]; then
    echo "  already present: wimlib"
else
    echo "  cloning wimlib..."
    git clone --depth=1 "https://github.com/ebiggers/wimlib.git" "$VENDOR/wimlib"
    if ls "$PATCHES_DIR"/wimlib_*.patch >/dev/null 2>&1; then
        echo "  applying patches..."
        for p in "$PATCHES_DIR"/wimlib_*.patch; do
            echo "    $(basename "$p")"
            (cd "$VENDOR/wimlib" && git apply "$p")
        done
    fi
    echo "  done."
fi

echo "==> cgltf"
if [ -d "$VENDOR/cgltf" ] && [ -n "$(ls -A "$VENDOR/cgltf" 2>/dev/null)" ]; then
    echo "  already present: cgltf"
else
    echo "  cloning cgltf..."
    git clone --depth=1 "https://github.com/jkuhlmann/cgltf.git" "$VENDOR/cgltf"
    echo "  done."
fi

echo "==> bcdec"
if [ -d "$VENDOR/bcdec" ] && [ -n "$(ls -A "$VENDOR/bcdec" 2>/dev/null)" ]; then
    echo "  already present: bcdec"
else
    echo "  cloning bcdec..."
    git clone --depth=1 "https://github.com/iOrange/bcdec.git" "$VENDOR/bcdec"
    echo "  done."
fi

echo "==> stb (image + image_write + dxt)"
mkdir -p "$VENDOR/stb"
for h in stb_image.h stb_image_write.h stb_dxt.h; do
    if [ -f "$VENDOR/stb/$h" ]; then
        echo "  already present: $h"
    else
        echo "  downloading $h..."
        curl -fsSL "https://raw.githubusercontent.com/nothings/stb/master/$h" \
            -o "$VENDOR/stb/$h"
        echo "  done."
    fi
done

FONT="$VENDOR/fonts/SpaceMono-Regular.ttf"

echo "==> SpaceMono-Regular.ttf"
mkdir -p "$VENDOR/fonts"
if [ ! -f "$FONT" ]; then
    echo "  downloading..."
    curl -fsSL \
        "https://github.com/googlefonts/spacemono/raw/main/fonts/ttf/SpaceMono-Regular.ttf" \
        -o "$FONT"
    echo "  done."
else
    echo "  already present: SpaceMono-Regular.ttf"
fi

echo ""
echo "All deps ready."
