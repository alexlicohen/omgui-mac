#!/usr/bin/env bash
#
# Shared notarytool credential resolution for notarize-app.sh and notarize-dmg.sh. Source this
# file, then call `resolve_notary_auth`; it fills the NOTARY_AUTH array with the arguments to
# append to every `xcrun notarytool` call, and NOTARY_AUTH_DESC with a one-line description.
#
# Credentials are looked up in this order (explicit beats implicit):
#   1. App Store Connect API key:  NOTARY_KEY=<path to AuthKey_XXXX.p8>  NOTARY_KEY_ID  NOTARY_ISSUER
#   2. Apple ID + app-specific password:  NOTARY_APPLE_ID  NOTARY_PASSWORD  [NOTARY_TEAM_ID, default AR8KJ6ST6K]
#   3. Keychain profile:  NOTARY_PROFILE (default omgui-notary), created with
#        xcrun notarytool store-credentials omgui-notary --apple-id … --team-id … --password …
# Nothing is ever written to disk by these scripts; the password in (2) is visible to `ps` on
# this machine for the duration of the upload, which is the trade-off for not touching the keychain.
#
resolve_notary_auth() {
    NOTARY_AUTH=()
    NOTARY_AUTH_DESC=""
    if [[ -n "${NOTARY_KEY:-}" || -n "${NOTARY_KEY_ID:-}" || -n "${NOTARY_ISSUER:-}" ]]; then
        [[ -n "${NOTARY_KEY:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]] \
            || { printf 'ERROR: NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER must all be set to use an API key.\n' >&2; return 1; }
        [[ -f "$NOTARY_KEY" ]] || { printf 'ERROR: NOTARY_KEY file not found: %s\n' "$NOTARY_KEY" >&2; return 1; }
        NOTARY_AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
        NOTARY_AUTH_DESC="App Store Connect API key $NOTARY_KEY_ID"
    elif [[ -n "${NOTARY_APPLE_ID:-}" || -n "${NOTARY_PASSWORD:-}" ]]; then
        [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]] \
            || { printf 'ERROR: NOTARY_APPLE_ID and NOTARY_PASSWORD must both be set.\n' >&2; return 1; }
        NOTARY_AUTH=(--apple-id "$NOTARY_APPLE_ID" --team-id "${NOTARY_TEAM_ID:-AR8KJ6ST6K}" --password "$NOTARY_PASSWORD")
        NOTARY_AUTH_DESC="Apple ID $NOTARY_APPLE_ID (team ${NOTARY_TEAM_ID:-AR8KJ6ST6K})"
    else
        local profile="${NOTARY_PROFILE:-omgui-notary}"
        if xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
            NOTARY_AUTH=(--keychain-profile "$profile")
            NOTARY_AUTH_DESC="keychain profile $profile"
        else
            printf 'ERROR: no notarytool credentials found. Provide one of:\n' >&2
            printf '  NOTARY_KEY=<AuthKey.p8> NOTARY_KEY_ID=<id> NOTARY_ISSUER=<issuer-id>        (App Store Connect API key)\n' >&2
            printf '  NOTARY_APPLE_ID=<apple-id> NOTARY_PASSWORD=<app-specific-password>          (team defaults to AR8KJ6ST6K)\n' >&2
            printf '  a keychain profile "%s" (xcrun notarytool store-credentials %s ...)\n' "$profile" "$profile" >&2
            printf 'See docs/RELEASE.md.\n' >&2
            return 1
        fi
    fi
    # Prove the credentials work before spending an upload on them.
    xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1 \
        || { printf 'ERROR: notarytool rejected the credentials (%s).\n' "$NOTARY_AUTH_DESC" >&2; return 1; }
    return 0
}
