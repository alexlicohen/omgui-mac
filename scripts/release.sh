#!/usr/bin/env bash
#
# Full release pipeline, in the order that ships a correctly-ticketed app and DMG:
#
#   build-app -> notarize-app -> build-dmg -> notarize-dmg
#
# Notarizing+stapling the .app before packaging it means the DMG is built from an already-ticketed
# bundle, so a user who drags OmGui.app out of the DMG onto an offline Mac still launches cleanly.
#
# Credentials: set one of NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER (App Store Connect API key),
# NOTARY_APPLE_ID/NOTARY_PASSWORD (app-specific password), or a keychain profile — see
# scripts/lib-notary.sh and docs/RELEASE.md for all three, including the one-time keychain-profile
# setup (run from Terminal.app, not from inside Claude Code).
#
# A release must be Developer-ID signed and notarized — --adhoc is refused here (use
# build-app.sh/build-dmg.sh directly with --adhoc for a local test build; they don't notarize).
# HEAD must be exactly on a git tag, or pass --version X.Y.Z explicitly: tag first, then release.
#
#   bash scripts/release.sh                  # sign with Developer ID, notarize, staple both
#   bash scripts/release.sh --version 1.2.3  # forwarded to build-app.sh
#
set -euo pipefail

CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$(pwd)"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# U2: release.sh is the notarized-release pipeline; refuse --adhoc up front rather than let
# notarize-app.sh fail three steps later on an ad-hoc-signed artifact.
for arg in "$@"; do
    [[ "$arg" == "--adhoc" ]] \
        && fail "release.sh does not support --adhoc — a release must be Developer-ID signed and notarized. For a local ad-hoc test build, run scripts/build-app.sh and scripts/build-dmg.sh directly with --adhoc."
done

# U4: without an explicit --version, build-app.sh derives the version from
# git describe --exact-match --tags, which fails on anything but an exact tag. Check it here too,
# so a bare `release.sh` off-tag fails immediately with a message naming both remedies rather than
# one line into step 1/4.
HAS_VERSION_ARG=0
for arg in "$@"; do
    [[ "$arg" == "--version" ]] && HAS_VERSION_ARG=1
done
if [[ "$HAS_VERSION_ARG" -eq 0 ]]; then
    (cd "$REPO_ROOT" && git describe --exact-match --tags >/dev/null 2>&1) \
        || fail "HEAD is not exactly on a git tag (git describe --exact-match --tags failed) — either tag this commit first (git tag vX.Y.Z) and re-run, or pass --version X.Y.Z explicitly."
fi

log "== 1/4 build-app =="
bash "$REPO_ROOT/scripts/build-app.sh" "$@"

log "== 2/4 notarize-app =="
bash "$REPO_ROOT/scripts/notarize-app.sh"

log "== 3/4 build-dmg =="
bash "$REPO_ROOT/scripts/build-dmg.sh"

log "== 4/4 notarize-dmg =="
bash "$REPO_ROOT/scripts/notarize-dmg.sh"

log "Release complete: $REPO_ROOT/dist"
