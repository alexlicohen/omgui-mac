#!/usr/bin/env bash
#
# Package dist/OmGui.app into a signed, distributable dist/OmGui-<version>.dmg.
# Run scripts/build-app.sh first.
#
#   bash scripts/build-dmg.sh              # sign with Developer ID if available, else ad-hoc
#   bash scripts/build-dmg.sh --adhoc      # force ad-hoc signing
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO_ROOT/dist"
APP="$DIST/OmGui.app"
VOLNAME="OmGui"

ADHOC=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --adhoc) ADHOC=1; shift ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
    esac
done

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -d "$APP" ]] || fail "$APP not found — run scripts/build-app.sh first"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$DIST/OmGui-$VERSION.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/OmGui.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

IDENTITY=""
if [[ "$ADHOC" -eq 0 ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' | head -1 \
        | sed -E 's/^[[:space:]]*[0-9]+\) ([A-F0-9]+) .*/\1/' || true)"
fi

if [[ -n "$IDENTITY" ]]; then
    log "Signing DMG with Developer ID Application identity $IDENTITY"
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
else
    log "WARNING: no Developer ID Application identity found (or --adhoc given). Signing DMG ad-hoc."
    codesign --force --sign - "$DMG"
fi

hdiutil verify "$DMG"

log "Built $DMG"
