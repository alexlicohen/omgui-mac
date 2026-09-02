#!/usr/bin/env bash
#
# Assemble dist/OmGui.app from the release build of the OmGui SwiftUI executable, the
# omconvert/cwa-convert helpers, and Resources/. Signs with a Developer ID Application identity
# when one is installed, otherwise ad-hoc.
#
#   bash scripts/build-app.sh              # sign with Developer ID if available, else ad-hoc
#   bash scripts/build-app.sh --adhoc      # force ad-hoc signing
#   bash scripts/build-app.sh --version 1.2.3
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES="$REPO_ROOT/Resources"
DIST="$REPO_ROOT/dist"
APP="$DIST/OmGui.app"
PRODUCT="OmGui"

ADHOC=0
VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --adhoc) ADHOC=1; shift ;;
        --version) VERSION="$2"; shift 2 ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    VERSION="$(cd "$REPO_ROOT" && git describe --tags --always 2>/dev/null || echo "0.0.0")"
fi
BUILD_NUMBER="$(cd "$REPO_ROOT" && git rev-list --count HEAD 2>/dev/null || echo 1)"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

log "Building $PRODUCT $VERSION (build $BUILD_NUMBER)"

# ---------------------------------------------------------------------------
# 1. Swift build
# ---------------------------------------------------------------------------
BIN_PATH="$(cd "$REPO_ROOT" && swift build -c release --arch arm64 --show-bin-path)"
(cd "$REPO_ROOT" && swift build -c release --product "$PRODUCT" --arch arm64)
[[ -x "$BIN_PATH/$PRODUCT" ]] || fail "built product not found at $BIN_PATH/$PRODUCT"

# ---------------------------------------------------------------------------
# 2. Helper binaries
# ---------------------------------------------------------------------------
bash "$REPO_ROOT/scripts/build-helpers.sh"
HELPERS_DIR="$REPO_ROOT/build/helpers"
[[ -x "$HELPERS_DIR/omconvert" ]] || fail "omconvert not built"
[[ -x "$HELPERS_DIR/cwa-convert" ]] || fail "cwa-convert not built"

# ---------------------------------------------------------------------------
# 3. Assemble the bundle
# ---------------------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

cp "$BIN_PATH/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
cp "$HELPERS_DIR/omconvert" "$APP/Contents/Helpers/omconvert"
cp "$HELPERS_DIR/cwa-convert" "$APP/Contents/Helpers/cwa-convert"
cp "$RESOURCES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD_NUMBER/" \
    "$RESOURCES/Info.plist.in" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "rendered Info.plist failed lint"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# ---------------------------------------------------------------------------
# 4. Sign
# ---------------------------------------------------------------------------
IDENTITY=""
if [[ "$ADHOC" -eq 0 ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' | head -1 \
        | sed -E 's/^[[:space:]]*[0-9]+\) ([A-F0-9]+) .*/\1/' || true)"
fi

if [[ -n "$IDENTITY" ]]; then
    log "Signing with Developer ID Application identity $IDENTITY"
    codesign --force --sign "$IDENTITY" --options runtime --timestamp \
        "$APP/Contents/Helpers/omconvert"
    codesign --force --sign "$IDENTITY" --options runtime --timestamp \
        "$APP/Contents/Helpers/cwa-convert"
    codesign --force --sign "$IDENTITY" --options runtime --timestamp \
        --entitlements "$RESOURCES/OmGui.entitlements" "$APP"
else
    log "WARNING: no Developer ID Application identity found (or --adhoc given)."
    log "WARNING: signing ad-hoc. This build cannot be notarized and Gatekeeper will warn on other Macs."
    codesign --force --sign - "$APP/Contents/Helpers/omconvert"
    codesign --force --sign - "$APP/Contents/Helpers/cwa-convert"
    codesign --force --sign - --entitlements "$RESOURCES/OmGui.entitlements" "$APP"
fi

# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------
codesign --verify --deep --strict --verbose=2 "$APP"

log "Built $APP"
