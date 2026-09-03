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

CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$(pwd)"
RESOURCES="$REPO_ROOT/Resources"
DIST="$REPO_ROOT/dist"
APP="$DIST/OmGui.app"
PRODUCT="OmGui"

source "$REPO_ROOT/scripts/lib-sign.sh"

ADHOC=0
VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --adhoc) ADHOC=1; shift ;;
        --version) VERSION="$2"; shift 2 ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
    esac
done

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [[ -z "$VERSION" ]]; then
    VERSION="$(cd "$REPO_ROOT" && git describe --tags --always 2>/dev/null || echo "0.0.0")"
fi
# Strip a leading 'v' (git describe on a "vX.Y.Z" tag) — CFBundleShortVersionString must be a
# plain numeric dot-separated version; AppInfo.isNumericVersion rejects anything else and falls
# back to a hard-coded "1.0.0", which is worse than failing the build here.
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]] \
    || fail "VERSION '$VERSION' is not a plain numeric dot-separated version (e.g. 1.2.3) — pass --version X.Y.Z, or tag the release numerically"
BUILD_NUMBER="$(cd "$REPO_ROOT" && git rev-list --count HEAD 2>/dev/null || echo 1)"

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

# Bundled plugins (phase 3b): the plugin folder OmGui defaults to.
if [[ -d "$RESOURCES/Plugins" ]]; then
    cp -R "$RESOURCES/Plugins" "$APP/Contents/Resources/Plugins"
    find "$APP/Contents/Resources/Plugins" -name '*.sh' -exec chmod +x {} +
fi

# PlistBuddy, not sed: VERSION/BUILD_NUMBER can otherwise contain sed metacharacters (a tag like
# "release/1.2" breaks the substitution outright; "&" duplicates the match) and land unescaped in
# the rendered plist.
cp "$RESOURCES/Info.plist.in" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "rendered Info.plist failed lint"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# ---------------------------------------------------------------------------
# 3b. Strip build-machine toolchain rpaths (C45)
#
# A release build's LC_RPATH can carry the build machine's Xcode/toolchain path (e.g.
# .../XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx). Nothing resolves through it while every
# Swift dylib the app uses ships inside the bundle, but it leaks the builder's local layout and
# would become a launch failure on a user Mac the day an @rpath-relative dylib enters the link.
# Must run before codesign — install_name_tool after signing invalidates the signature.
# ---------------------------------------------------------------------------
BIN="$APP/Contents/MacOS/$PRODUCT"
TOOLCHAIN_RPATHS="$(otool -l "$BIN" | awk '/ path / && /(Xcode\.app|\.xctoolchain|CommandLineTools)/ {print $2}')"
if [[ -n "$TOOLCHAIN_RPATHS" ]]; then
    while IFS= read -r rp; do
        [[ -z "$rp" ]] && continue
        log "Stripping toolchain LC_RPATH: $rp"
        install_name_tool -delete_rpath "$rp" "$BIN"
    done <<< "$TOOLCHAIN_RPATHS"
fi
REMAINING_RPATHS="$(otool -l "$BIN" | awk '/ path / && /(Xcode\.app|\.xctoolchain|CommandLineTools)/ {print $2}')"
[[ -z "$REMAINING_RPATHS" ]] || fail "toolchain rpath still present after stripping: $REMAINING_RPATHS"

# ---------------------------------------------------------------------------
# 4. Sign
# ---------------------------------------------------------------------------
IDENTITY=""
if [[ "$ADHOC" -eq 0 ]]; then
    IDENTITY="$(resolve_sign_identity)"
fi

if [[ -n "$IDENTITY" ]]; then
    log "Signing with Developer ID Application identity $IDENTITY"
    codesign --force --sign "$IDENTITY" --options runtime --timestamp \
        "$APP/Contents/Helpers/omconvert"
    codesign --force --sign "$IDENTITY" --options runtime --timestamp \
        "$APP/Contents/Helpers/cwa-convert"
    codesign --force --sign "$IDENTITY" --options runtime --timestamp \
        --entitlements "$RESOURCES/OmGui.entitlements" "$APP"
    assert_team_identifier "$APP"
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
