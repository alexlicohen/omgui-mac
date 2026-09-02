#!/usr/bin/env bash
#
# Notarize and staple dist/OmGui-<version>.dmg (and the app inside dist/OmGui.app). Run
# scripts/build-app.sh and scripts/build-dmg.sh first, with a Developer ID Application signature
# (not ad-hoc — Apple will reject an ad-hoc-signed submission).
#
# One-time setup, before the first run:
#   xcrun notarytool store-credentials omgui-notary \
#       --apple-id <your Apple ID email> \
#       --team-id V9R6KQRWSD \
#       --password <app-specific password>
# (Generate the app-specific password at appleid.apple.com; this stores it in the keychain, not
# on disk. Override the profile name with NOTARY_PROFILE if you used a different one.)
#
#   bash scripts/notarize.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO_ROOT/dist"
APP="$DIST/OmGui.app"
PROFILE="${NOTARY_PROFILE:-omgui-notary}"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -d "$APP" ]] || fail "$APP not found — run scripts/build-app.sh first"

SIGNING_AUTH="$(codesign -dv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [[ -z "$SIGNING_AUTH" || "$SIGNING_AUTH" == "-" ]]; then
    fail "$APP is ad-hoc signed. Notarization needs a Developer ID Application signature — rebuild with scripts/build-app.sh (no --adhoc)."
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$DIST/OmGui-$VERSION.dmg"
[[ -f "$DMG" ]] || fail "$DMG not found — run scripts/build-dmg.sh first"

log "Submitting $DMG to notarytool (profile: $PROFILE)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

log "Stapling $DMG"
xcrun stapler staple "$DMG"

log "Stapling $APP"
xcrun stapler staple "$APP"

log "Gatekeeper check:"
spctl -a -vv -t install "$APP"
