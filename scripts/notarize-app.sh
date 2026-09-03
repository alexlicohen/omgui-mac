#!/usr/bin/env bash
#
# Notarize and staple dist/OmGui.app. Run this BEFORE scripts/build-dmg.sh — the DMG must be
# built from an already-stapled bundle, otherwise a user who drags OmGui.app out of the DMG onto
# an offline/firewalled Mac gets "cannot be opened because Apple cannot check it for malicious
# software" (the app itself never carries a ticket, only the developer's original dist/ copy).
#
# Credentials: set one of NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER (App Store Connect API key),
# NOTARY_APPLE_ID/NOTARY_PASSWORD (app-specific password), or a keychain profile — see
# scripts/lib-notary.sh and docs/RELEASE.md for all three, including the one-time keychain-profile
# setup command (run from Terminal.app, not from inside Claude Code — that interactive keychain
# item cannot be created correctly from a non-interactive session).
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

SIGNING_AUTH="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
[[ "$SIGNING_AUTH" == "Developer ID Application: "* ]] \
    || fail "$APP is not signed with a Developer ID Application identity (Authority='$SIGNING_AUTH'). notarytool rejects anything else — including an ad-hoc or Apple Development signature — only after a full upload-and-wait, with an error that doesn't point at this cause. Rebuild with scripts/build-app.sh (no --adhoc)."

# L6: the team this app is actually signed with — resolve_notary_auth refuses to submit under a
# different one.
EXPECTED_TEAM="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
resolve_notary_auth "$EXPECTED_TEAM" || exit 1

# notarytool needs a single zip/dmg/pkg to submit; a bare .app must be zipped first. Stapling
# afterwards is done directly against the .app, not the zip.
ZIP="$DIST/OmGui-notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

log "Submitting $APP (as $ZIP) to notarytool ($NOTARY_AUTH_DESC)"
notary_submit_and_wait "$ZIP" || fail "notarization of $APP failed — see the notarytool output/log above"
rm -f "$ZIP"

# Credentials are no longer needed past this point (U1) — drop them before anything else in this
# shell (a stray `env`/core dump, a sourced script) could see them.
unset NOTARY_AUTH NOTARY_AUTH_DESC

log "Stapling $APP"
xcrun stapler staple "$APP" || fail "stapler staple failed on $APP"

log "Validating staple"
xcrun stapler validate "$APP" || fail "stapler validate failed on $APP"

log "Gatekeeper check (exec):"
spctl -a -vv -t exec "$APP" || fail "spctl rejected $APP"

log "Notarized and stapled $APP — safe to build the DMG now (scripts/build-dmg.sh)"
