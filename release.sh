#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="carbin-garage"
RELEASE_DIR="$(cd "$PROJECT_DIR/.." && pwd)/${PROJECT_NAME}-release"

usage() {
    cat <<EOF
usage: $(basename "$0") --local [--target linux|windows]
       $(basename "$0") --public --version vX.Y.Z [--notes "text"]

  --local                       build locally into <project>-release/<target>/
  --target linux|windows        build target (default: linux). windows = mingw-w64 cross.
  --public                      trigger release.yml workflow via gh CLI
  --version <tag>               required when --public is used
  --notes <text>                optional release notes
EOF
}

DO_LOCAL=0
DO_PUBLIC=0
TARGET="linux"
VERSION=""
NOTES=""

while [ $# -gt 0 ]; do
    case "$1" in
        --local)   DO_LOCAL=1; shift ;;
        --public)  DO_PUBLIC=1; shift ;;
        --target)  TARGET="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --notes)   NOTES="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown flag: $1" >&2; usage; exit 1 ;;
    esac
done

if [ $DO_LOCAL -eq 0 ] && [ $DO_PUBLIC -eq 0 ]; then
    usage; exit 1
fi

# ── Local build ──────────────────────────────────────────────────────────────
if [ $DO_LOCAL -eq 1 ]; then
    if [ "$TARGET" != "linux" ] && [ "$TARGET" != "windows" ]; then
        echo "error: --target must be linux or windows" >&2; exit 1
    fi
    DEST="$RELEASE_DIR/$TARGET"
    echo "==> Local build ($TARGET): $PROJECT_NAME -> $DEST"

    # Fetch + build vendored deps if missing.
    if [ ! -d "$PROJECT_DIR/vendor/sdl3" ]; then
        echo "  vendor missing; running download-deps.sh"
        "$PROJECT_DIR/download-deps.sh"
    fi
    "$PROJECT_DIR/build-deps.sh" --target "$TARGET"

    # Enumerate every .a in vendor/build/<target>/lib/ and pass to the linker
    # inside --start-group/--end-group so circular references resolve.
    cd "$PROJECT_DIR"
    PASSL_ARGS=("--passL:-Wl,--start-group")
    for lib in "vendor/build/$TARGET/lib"/*.a; do
        PASSL_ARGS+=("--passL:$lib")
    done
    PASSL_ARGS+=("--passL:-Wl,--end-group")

    if [ "$TARGET" = "windows" ]; then
        BIN_NAME="${PROJECT_NAME}.exe"
        nimble -y build -d:release --os:windows --cpu:amd64 -d:mingw \
            --gcc.exe:x86_64-w64-mingw32-gcc \
            --gcc.linkerexe:x86_64-w64-mingw32-gcc \
            "${PASSL_ARGS[@]}"
    else
        BIN_NAME="${PROJECT_NAME}"
        nimble -y build -d:release "${PASSL_ARGS[@]}"
    fi

    # Stage release: binary + LICENSE + README + profiles + shaders.
    # working/ and settings.json are NOT staged — the binary creates them on
    # first run next to itself.
    rm -rf "$DEST"
    mkdir -p "$DEST"
    cp "$PROJECT_DIR/build/${BIN_NAME}" "$DEST/"
    [ -f "$PROJECT_DIR/README.md" ] && cp "$PROJECT_DIR/README.md" "$DEST/" || true
    [ -f "$PROJECT_DIR/LICENSE" ]   && cp "$PROJECT_DIR/LICENSE"   "$DEST/" || true
    [ -d "$PROJECT_DIR/profiles" ]  && cp -r "$PROJECT_DIR/profiles" "$DEST/" || true
    [ -d "$PROJECT_DIR/shaders" ]   && cp -r "$PROJECT_DIR/shaders"  "$DEST/" || true

    echo "==> Local done: $DEST"
fi

# ── Public release via GitHub Actions ────────────────────────────────────────
if [ $DO_PUBLIC -eq 1 ]; then
    if [ -z "$VERSION" ]; then
        echo "error: --public requires --version <tag>" >&2; exit 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo "error: gh CLI not found; install it and run 'gh auth login'" >&2; exit 1
    fi
    REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || true)
    if [ -z "$REPO" ]; then
        echo "error: not in a github repo (or gh not authenticated)" >&2; exit 1
    fi
    WORKFLOW="release.yml"
    echo "==> Triggering $WORKFLOW on $REPO ($VERSION)"
    OLD_ID=$(gh run list --workflow="$WORKFLOW" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
    gh workflow run "$WORKFLOW" \
        --field version="$VERSION" \
        --field notes="$NOTES"
    echo "==> Waiting for run to register..."
    NEW_ID=""
    for i in $(seq 1 30); do
        sleep 2
        CUR_ID=$(gh run list --workflow="$WORKFLOW" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
        if [ -n "$CUR_ID" ] && [ "$CUR_ID" != "$OLD_ID" ]; then
            NEW_ID="$CUR_ID"; break
        fi
    done
    if [ -z "$NEW_ID" ]; then
        echo "error: failed to detect new workflow run" >&2; exit 1
    fi
    echo "==> Watching run $NEW_ID"
    gh run watch "$NEW_ID" --exit-status
fi
