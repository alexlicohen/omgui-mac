#!/usr/bin/env bash
#
# Shared Developer ID Application identity resolution for build-app.sh and build-dmg.sh. Source
# this file, then:
#
#   IDENTITY="$(resolve_sign_identity)" || IDENTITY_STATUS=$?
#
# Override the lookup entirely with SIGN_IDENTITY=<hash-or-name> in the environment. Without an
# override, exactly one "Developer ID Application" identity must be present in the codesigning
# keychain; two or more is a hard error (pick one via SIGN_IDENTITY) rather than a silent
# first-match, since app and DMG resolving to different identities independently is exactly how
# a mixed-team signature slips through. resolve_sign_identity returns 1 (not 0) when nothing is
# found — the caller decides whether that's fatal (Developer ID build) or expected (--adhoc).
# The notarize scripts determine the identity independently by parsing `codesign -dvv` on the
# already-signed artifact; they don't source this file.
#
resolve_sign_identity() {
    if [[ -n "${SIGN_IDENTITY:-}" ]]; then
        printf '%s\n' "$SIGN_IDENTITY"
        return 0
    fi

    local matches count hash
    matches="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' || true)"
    if [[ -z "$matches" ]]; then
        return 1
    fi

    count="$(printf '%s\n' "$matches" | grep -c .)"
    if [[ "$count" -gt 1 ]]; then
        printf 'ERROR: multiple Developer ID Application identities found; set SIGN_IDENTITY to pick one:\n%s\n' "$matches" >&2
        exit 1
    fi

    # "  1) HASH \"Developer ID Application: Name (TEAMID)\"" — the hash is always field 2.
    hash="$(printf '%s\n' "$matches" | awk '{print $2}')"
    [[ "$hash" =~ ^[A-F0-9]{40}$ ]] || {
        printf 'ERROR: could not parse a 40-hex identity hash from: %s\n' "$matches" >&2
        exit 1
    }
    printf '%s\n' "$hash"
}

# assert_team_identifier <path-to-signed-app-or-dmg>
# Confirms the object actually carries a team identifier after signing, so a codesign call that
# silently no-oped (or signed ad-hoc when Developer ID was expected) is caught here rather than
# surfacing later as a notarization rejection.
assert_team_identifier() {
    local target="$1"
    codesign -dvv "$target" 2>&1 | grep -q '^TeamIdentifier=' \
        || { printf 'ERROR: %s has no TeamIdentifier after signing\n' "$target" >&2; exit 1; }
}
