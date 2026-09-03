#!/usr/bin/env bash
#
# Full release pipeline, in the order that ships a correctly-ticketed app and DMG:
#
#   build-app -> notarize-app -> build-dmg -> notarize-dmg
#
# Notarizing+stapling the .app before packaging it means the DMG is built from an already-ticketed
# bundle, so a user who drags OmGui.app out of the DMG onto an offline Mac still launches cleanly.
# See scripts/notarize-app.sh for the one-time keychain-profile setup.
#
#   bash scripts/release.sh                  # sign with Developer ID, notarize, staple both
#   bash scripts/release.sh --version 1.2.3  # forwarded to build-app.sh
#
set -euo pipefail

CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$(pwd)"

log() { printf '%s\n' "$*"; }

log "== 1/4 build-app =="
bash "$REPO_ROOT/scripts/build-app.sh" "$@"

log "== 2/4 notarize-app =="
bash "$REPO_ROOT/scripts/notarize-app.sh"

log "== 3/4 build-dmg =="
bash "$REPO_ROOT/scripts/build-dmg.sh"

log "== 4/4 notarize-dmg =="
bash "$REPO_ROOT/scripts/notarize-dmg.sh"

log "Release complete: $REPO_ROOT/dist"
