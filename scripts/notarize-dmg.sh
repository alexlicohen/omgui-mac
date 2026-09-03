#!/usr/bin/env bash
#
# Notarize and staple dist/OmGui-<version>.dmg. Run this AFTER scripts/notarize-app.sh and
# scripts/build-dmg.sh, in that order — the DMG must be built from an already-stapled
# dist/OmGui.app (see scripts/notarize-app.sh for why).
#
# One-time setup: see scripts/notarize-app.sh (same profile, same Terminal.app requirement).
#
#   bash scripts/notarize-dmg.sh
#
set -euo pipefail

CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$(pwd)"
DIST="$REPO_ROOT/dist"
APP="$DIST/OmGui.app"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -d "$APP" ]] || fail "$APP not found — run scripts/build-app.sh first"
xcrun stapler validate "$APP" >/dev/null 2>&1 \
    || fail "$APP is not stapled — run scripts/notarize-app.sh before building/notarizing the DMG"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$DIST/OmGui-$VERSION.dmg"
[[ -f "$DMG" ]] || fail "$DMG not found — run scripts/build-dmg.sh first"

# shellcheck source=scripts/lib-notary.sh
source "$REPO_ROOT/scripts/lib-notary.sh"
resolve_notary_auth || exit 1

SIGNING_AUTH="$(codesign -dvv "$DMG" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
[[ "$SIGNING_AUTH" == "Developer ID Application: "* ]] \
    || fail "$DMG is not signed with a Developer ID Application identity (Authority='$SIGNING_AUTH'). Rebuild with scripts/build-dmg.sh (no --adhoc)."

log "Submitting $DMG to notarytool ($NOTARY_AUTH_DESC)"
xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait

log "Stapling $DMG"
xcrun stapler staple "$DMG" || fail "stapler staple failed on $DMG"

log "Validating staple"
xcrun stapler validate "$DMG" || fail "stapler validate failed on $DMG"

log "Gatekeeper check (open, primary signature):"
spctl -a -vv -t open --context context:primary-signature "$DMG" || fail "spctl rejected $DMG"

log "Notarized and stapled $DMG"
