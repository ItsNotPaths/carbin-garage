#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="carbin-garage"
RELEASE_DIR="$(cd "$PROJECT_DIR/.." && pwd)/${PROJECT_NAME}-release"

usage() {
    cat <<EOF
usage: $(basename "$0") --local [--target linux|windows] [--skip-deps] [--clear-working]
       $(basename "$0") --public --version X.Y[.Z] [--notes "text"] [--prerelease]

  --local                       build locally into <project>-release/<target>/.
                                Overwrites the binary, LICENSE, README, and
                                profiles/. Preserves working/ and any other
                                user-side files in the release dir between runs.
  --target linux|windows        build target (default: linux). windows = mingw-w64 cross.
  --skip-deps                   skip download-deps.sh + build-deps.sh (Phase-1
                                builds don't link SDL3 yet, so the .a files
                                aren't required).
  --clear-working               wipe <project>-release/<target>/working/ before
                                staging. Use when a code change makes existing
                                working/ trees stale and you want a clean slate.
  --public                      trigger release.yml workflow via gh CLI
  --version <tag>               required when --public is used. Accepts 1.2,
                                1.2.3, v1.2 etc.; normalized to vX.Y[.Z].
  --notes <text>                optional release notes
  --prerelease                  mark the GitHub release as a pre-release
EOF
}

DO_LOCAL=0
DO_PUBLIC=0
TARGET="linux"
VERSION=""
NOTES=""
SKIP_DEPS=0
CLEAR_WORKING=0
PRERELEASE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --local)          DO_LOCAL=1; shift ;;
        --public)         DO_PUBLIC=1; shift ;;
        --target)         TARGET="${2:-}"; shift 2 ;;
        --version)        VERSION="${2:-}"; shift 2 ;;
        --notes)          NOTES="${2:-}"; shift 2 ;;
        --skip-deps)      SKIP_DEPS=1; shift ;;
        --clear-working)  CLEAR_WORKING=1; shift ;;
        --prerelease)     PRERELEASE=1; shift ;;
        -h|--help)        usage; exit 0 ;;
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

    # Fetch + build vendored deps if missing. --skip-deps bypasses
    # build-deps.sh entirely (Phase 1 doesn't link SDL3, so the .a's
    # aren't needed yet).
    if [ $SKIP_DEPS -eq 0 ]; then
        if [ ! -d "$PROJECT_DIR/vendor/sdl3" ]; then
            echo "  vendor missing; running download-deps.sh"
            "$PROJECT_DIR/download-deps.sh"
        fi
        "$PROJECT_DIR/build-deps.sh" --target "$TARGET"
    else
        echo "  --skip-deps: not running build-deps.sh"
    fi

    # Enumerate every .a in vendor/build/<target>/lib/ and pass to the linker
    # inside --start-group/--end-group so circular references resolve.
    # Empty if --skip-deps and the .a's haven't been built — that's fine for
    # Phase-1 builds with no SDL3 imports.
    cd "$PROJECT_DIR"
    PASSL_ARGS=("--passL:-Wl,--start-group")
    if [ -d "vendor/build/$TARGET/lib" ]; then
        for lib in "vendor/build/$TARGET/lib"/*.a; do
            [ -f "$lib" ] && PASSL_ARGS+=("--passL:$lib")
        done
    fi
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

    # Stage release: overwrite only the files we own (binary, LICENSE,
    # README, profiles/, shaders/). Preserve working/ and any other
    # user-side state — `rm -rf "$DEST"` would blow up imports between
    # rebuilds. Use --clear-working to drop working/ explicitly.
    mkdir -p "$DEST"
    if [ $CLEAR_WORKING -eq 1 ] && [ -d "$DEST/working" ]; then
        echo "  --clear-working: removing $DEST/working"
        rm -rf "$DEST/working"
    fi
    cp -f "$PROJECT_DIR/build/${BIN_NAME}" "$DEST/"
    [ -f "$PROJECT_DIR/README.md" ] && cp -f "$PROJECT_DIR/README.md" "$DEST/" || true
    [ -f "$PROJECT_DIR/LICENSE" ]   && cp -f "$PROJECT_DIR/LICENSE"   "$DEST/" || true
    # profiles/ and shaders/: refresh contents (overwrite same-named files,
    # add new ones) without nuking unrelated files a user may have dropped in.
    if [ -d "$PROJECT_DIR/profiles" ]; then
        mkdir -p "$DEST/profiles"
        cp -f "$PROJECT_DIR/profiles/"* "$DEST/profiles/" 2>/dev/null || true
    fi
    if [ -d "$PROJECT_DIR/shaders" ]; then
        mkdir -p "$DEST/shaders"
        cp -rf "$PROJECT_DIR/shaders/"* "$DEST/shaders/" 2>/dev/null || true
    fi

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

    # Normalize tag: "1.2" / "1.2.3" / "v1.2" → "v1.2" / "v1.2.3".
    case "$VERSION" in
        v*) ;;
        *)  VERSION="v$VERSION" ;;
    esac
    if ! echo "$VERSION" | grep -Eq '^v[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
        echo "error: --version must look like X.Y or X.Y.Z (got '$VERSION')" >&2
        exit 1
    fi

    cd "$PROJECT_DIR"

    # Working tree must be clean — anything uncommitted won't make it to GHA.
    if [ -n "$(git status --porcelain)" ]; then
        echo "error: working tree dirty; commit or stash before --public" >&2
        git status --short >&2
        exit 1
    fi

    # workflow_dispatch runs against the remote default branch. Make sure the
    # tip of that branch matches local HEAD, otherwise GHA builds stale code.
    REMOTE_DEFAULT=$(git ls-remote --symref origin HEAD 2>/dev/null \
        | awk '/^ref:/ {sub("refs/heads/","",$2); print $2; exit}')
    if [ -z "$REMOTE_DEFAULT" ]; then
        echo "error: could not detect origin's default branch" >&2; exit 1
    fi
    git fetch --quiet origin "$REMOTE_DEFAULT"
    LOCAL_SHA=$(git rev-parse HEAD)
    REMOTE_SHA=$(git rev-parse "origin/$REMOTE_DEFAULT")
    if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
        cat >&2 <<EOF
error: HEAD ($LOCAL_SHA) does not match origin/$REMOTE_DEFAULT ($REMOTE_SHA).
       GitHub Actions builds the tip of the default branch, so push first:
           git push origin HEAD:$REMOTE_DEFAULT
EOF
        exit 1
    fi

    # Refuse to clobber an existing tag — gh release create would fail later
    # with a less-obvious error.
    if gh release view "$VERSION" --repo "$REPO" >/dev/null 2>&1; then
        echo "error: release $VERSION already exists on $REPO" >&2; exit 1
    fi

    WORKFLOW="release.yml"
    PRERELEASE_ARG="false"; [ $PRERELEASE -eq 1 ] && PRERELEASE_ARG="true"
    echo "==> Triggering $WORKFLOW on $REPO ($VERSION, ref=$REMOTE_DEFAULT, prerelease=$PRERELEASE_ARG)"
    OLD_ID=$(gh run list --workflow="$WORKFLOW" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
    gh workflow run "$WORKFLOW" \
        --ref "$REMOTE_DEFAULT" \
        --field version="$VERSION" \
        --field notes="$NOTES" \
        --field prerelease="$PRERELEASE_ARG"
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
    echo "==> Release: https://github.com/$REPO/releases/tag/$VERSION"
fi
