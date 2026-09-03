#!/usr/bin/env bash
#
# Package dist/OmGui.app into a signed, distributable dist/OmGui-<version>.dmg.
# Run scripts/build-app.sh first.
#
#   bash scripts/build-dmg.sh              # sign with Developer ID if available, else ad-hoc
#   bash scripts/build-dmg.sh --adhoc      # force ad-hoc signing
#
set -euo pipefail

CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$(pwd)"
DIST="$REPO_ROOT/dist"
APP="$DIST/OmGui.app"
VOLNAME="OmGui"

source "$REPO_ROOT/scripts/lib-sign.sh"

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
# mktemp -d creates the dir mode 0700; that becomes the DMG's -srcfolder, so the mounted volume
# root inherits it unless we open it up. Masked on a normal desktop because hdiutil attach mounts
# noowners — an MDM `-owners on` attach, or a root-owned mount handed to a non-root installer,
# sees an unreadable/empty volume otherwise.
chmod 755 "$STAGE"

# ditto, not cp -R: preserves a signed bundle's extended attributes/resource fork faithfully.
ditto "$APP" "$STAGE/OmGui.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

IDENTITY=""
if [[ "$ADHOC" -eq 0 ]]; then
    IDENTITY="$(resolve_sign_identity)"
fi

if [[ -n "$IDENTITY" ]]; then
    log "Signing DMG with Developer ID Application identity $IDENTITY"
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    assert_team_identifier "$DMG"
else
    log "WARNING: no Developer ID Application identity found (or --adhoc given). Signing DMG ad-hoc."
    codesign --force --sign - "$DMG"
fi

hdiutil verify "$DMG"

log "Built $DMG"
