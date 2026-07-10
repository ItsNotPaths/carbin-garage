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
# Use git clone --recurse-submodules so VENDORED=ON gets freetype source.
# Release tarballs don't include external/* submodule contents.
if [ -d "$VENDOR/sdl3_ttf" ] && [ -n "$(ls -A "$VENDOR/sdl3_ttf" 2>/dev/null)" ]; then
    echo "  already present: sdl3_ttf"
else
    echo "  cloning sdl3_ttf (with submodules)..."
    git clone --depth=1 --branch release-3.2.2 --recurse-submodules \
        "https://github.com/libsdl-org/SDL_ttf.git" "$VENDOR/sdl3_ttf"
    echo "  done."
fi

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

echo "==> sqlite (amalgamation, for static link)"
# Vendored so the binary statically links SQLite (see build-deps.sh +
# nim.cfg --dynlibOverride) instead of dlopen'ing a system libsqlite3.so /
# sqlite3.dll at runtime. Pin the version + sha3-256 from sqlite.org's
# download page. The autoconf .tar.gz (not the .zip) is used so plain `tar`
# extracts it — no `unzip` dependency in CI.
SQLITE_YEAR="2026"
SQLITE_VER="3530200"   # 3.53.2
SQLITE_SHA3="025328da165109f48abccc6e7478508060804412bed2bd81d47e98ba1b72983b"
if [ -f "$VENDOR/sqlite/sqlite3.c" ] && [ -f "$VENDOR/sqlite/sqlite3.h" ]; then
    echo "  already present: sqlite"
else
    echo "  downloading sqlite-autoconf-$SQLITE_VER..."
    mkdir -p "$VENDOR/sqlite"
    tmp="$VENDOR/sqlite/.autoconf.tar.gz"
    curl -fsSL "https://www.sqlite.org/$SQLITE_YEAR/sqlite-autoconf-$SQLITE_VER.tar.gz" -o "$tmp"
    # Best-effort integrity check (openssl >=1.1.1 ships sha3-256). Fail on a
    # real mismatch; skip silently only if the digest isn't available at all.
    if printf '' | openssl dgst -sha3-256 >/dev/null 2>&1; then
        got=$(openssl dgst -sha3-256 "$tmp" | awk '{print $NF}')
        if [ "$got" != "$SQLITE_SHA3" ]; then
            echo "  error: sqlite checksum mismatch (got $got, want $SQLITE_SHA3)" >&2
            rm -f "$tmp"; exit 1
        fi
        echo "  sha3-256 ok"
    else
        echo "  (openssl sha3-256 unavailable; skipping checksum)"
    fi
    tar xz --strip-components=1 -C "$VENDOR/sqlite" -f "$tmp" --wildcards \
        '*/sqlite3.c' '*/sqlite3.h' '*/sqlite3ext.h'
    rm -f "$tmp"
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
