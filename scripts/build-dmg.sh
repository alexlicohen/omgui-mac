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

# H7: a Developer-ID-signed app must be notarized and stapled *before* it goes into the DMG (see
# scripts/notarize-app.sh) — otherwise every later step (build-dmg, notarize-dmg, spctl) can pass
# while the enclosed app carries no ticket. --adhoc builds can never be stapled, so they're exempt.
if [[ "$ADHOC" -eq 0 ]]; then
    xcrun stapler validate "$APP" >/dev/null 2>&1 \
        || fail "$APP is not notarized+stapled — run scripts/notarize-app.sh first, or pass --adhoc for a local ad-hoc test build"
fi

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
IDENTITY_STATUS=0
if [[ "$ADHOC" -eq 0 ]]; then
    IDENTITY="$(resolve_sign_identity)" || IDENTITY_STATUS=$?
fi

if [[ -n "$IDENTITY" ]]; then
    log "Signing DMG with Developer ID Application identity $IDENTITY"
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    assert_team_identifier "$DMG"
elif [[ "$ADHOC" -eq 1 ]]; then
    log "WARNING: --adhoc given. Signing DMG ad-hoc."
    codesign --force --sign - "$DMG"
else
    fail "no Developer ID Application identity found (resolve_sign_identity exit $IDENTITY_STATUS). Likely causes: the login keychain is locked ('security unlock-keychain'), the certificate has expired, or none is installed — check with 'security find-identity -v -p codesigning'. Install one (docs/RELEASE.md) or pass --adhoc for a local ad-hoc test build."
fi

hdiutil verify "$DMG"

log "Built $DMG"
