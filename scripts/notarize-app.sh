#!/usr/bin/env bash
#
# Notarize and staple dist/OmGui.app. Run this BEFORE scripts/build-dmg.sh — the DMG must be
# built from an already-stapled bundle, otherwise a user who drags OmGui.app out of the DMG onto
# an offline/firewalled Mac gets "cannot be opened because Apple cannot check it for malicious
# software" (the app itself never carries a ticket, only the developer's original dist/ copy).
#
# One-time setup, before the first run — from Terminal.app, not from inside Claude Code (the
# keychain item this creates must come from an interactive Terminal session):
#   xcrun notarytool store-credentials omgui-notary \
#       --apple-id <your Apple ID email> \
#       --team-id AR8KJ6ST6K \
#       --password <app-specific password>
# (Generate the app-specific password at appleid.apple.com; this stores it in the keychain, not
# on disk. Override the profile name with NOTARY_PROFILE if you used a different one.)
#
#   bash scripts/notarize-app.sh
#
set -euo pipefail

CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$(pwd)"
DIST="$REPO_ROOT/dist"
APP="$DIST/OmGui.app"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -d "$APP" ]] || fail "$APP not found — run scripts/build-app.sh first"

# shellcheck source=scripts/lib-notary.sh
source "$REPO_ROOT/scripts/lib-notary.sh"
resolve_notary_auth || exit 1

SIGNING_AUTH="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
[[ "$SIGNING_AUTH" == "Developer ID Application: "* ]] \
    || fail "$APP is not signed with a Developer ID Application identity (Authority='$SIGNING_AUTH'). notarytool rejects anything else — including an ad-hoc or Apple Development signature — only after a full upload-and-wait, with an error that doesn't point at this cause. Rebuild with scripts/build-app.sh (no --adhoc)."

# notarytool needs a single zip/dmg/pkg to submit; a bare .app must be zipped first. Stapling
# afterwards is done directly against the .app, not the zip.
ZIP="$DIST/OmGui-notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

log "Submitting $APP (as $ZIP) to notarytool ($NOTARY_AUTH_DESC)"
xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait
rm -f "$ZIP"

log "Stapling $APP"
xcrun stapler staple "$APP" || fail "stapler staple failed on $APP"

log "Validating staple"
xcrun stapler validate "$APP" || fail "stapler validate failed on $APP"

log "Gatekeeper check (exec):"
spctl -a -vv -t exec "$APP" || fail "spctl rejected $APP"

log "Notarized and stapled $APP — safe to build the DMG now (scripts/build-dmg.sh)"
