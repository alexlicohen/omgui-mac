#!/usr/bin/env bash
#
# Notarize and staple dist/OmGui-<version>.dmg. Run this AFTER scripts/notarize-app.sh and
# scripts/build-dmg.sh, in that order — the DMG must be built from an already-stapled
# dist/OmGui.app (see scripts/notarize-app.sh for why).
#
# Credentials: set one of NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER (App Store Connect API key),
# NOTARY_APPLE_ID/NOTARY_PASSWORD (app-specific password), or a keychain profile — see
# scripts/lib-notary.sh and docs/RELEASE.md for all three, including the one-time keychain-profile
# setup (same requirements as scripts/notarize-app.sh).
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

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$DIST/OmGui-$VERSION.dmg"
[[ -f "$DMG" ]] || fail "$DMG not found — run scripts/build-dmg.sh first"

# H7: verify the app *sealed inside the DMG* is stapled — not dist/OmGui.app. Those are two
# independent copies (build-dmg.sh `ditto`s dist/OmGui.app into the image); dist/OmGui.app can
# hold a ticket from a stale notarize-app.sh run, or from a different build entirely, while the
# copy actually inside this DMG carries none. Only mounting the DMG and checking its own copy
# proves the ticket travels with what ships.
MOUNT="$(mktemp -d)"
cleanup_mount() {
    hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
    rm -rf "$MOUNT"
}
trap cleanup_mount EXIT

hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -quiet -readonly \
    || fail "could not mount $DMG to verify the enclosed app is stapled"

STAPLE_RC=0
xcrun stapler validate "$MOUNT/OmGui.app" >/dev/null 2>&1 || STAPLE_RC=$?

hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true

[[ $STAPLE_RC -eq 0 ]] \
    || fail "the app inside $DMG is not stapled — rebuild in order: scripts/notarize-app.sh then scripts/build-dmg.sh, then retry this script"

# shellcheck source=scripts/lib-notary.sh
source "$REPO_ROOT/scripts/lib-notary.sh"

SIGNING_AUTH="$(codesign -dvv "$DMG" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
[[ "$SIGNING_AUTH" == "Developer ID Application: "* ]] \
    || fail "$DMG is not signed with a Developer ID Application identity (Authority='$SIGNING_AUTH'). Rebuild with scripts/build-dmg.sh (no --adhoc)."

# L6: the team this DMG is actually signed with — resolve_notary_auth refuses to submit under a
# different one.
EXPECTED_TEAM="$(codesign -dvv "$DMG" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
resolve_notary_auth "$EXPECTED_TEAM" || exit 1

log "Submitting $DMG to notarytool ($NOTARY_AUTH_DESC)"
notary_submit_and_wait "$DMG" || fail "notarization of $DMG failed — see the notarytool output/log above"

# Credentials are no longer needed past this point (U1).
unset NOTARY_AUTH NOTARY_AUTH_DESC

log "Stapling $DMG"
xcrun stapler staple "$DMG" || fail "stapler staple failed on $DMG"

log "Validating staple"
xcrun stapler validate "$DMG" || fail "stapler validate failed on $DMG"

log "Gatekeeper check (open, primary signature):"
spctl -a -vv -t open --context context:primary-signature "$DMG" || fail "spctl rejected $DMG"

log "Notarized and stapled $DMG"
