#!/usr/bin/env bash
#
# Shared notarytool credential resolution and submission for notarize-app.sh and notarize-dmg.sh.
# Source this file, then:
#
#   resolve_notary_auth "$EXPECTED_TEAM" || exit 1     # fills NOTARY_AUTH / NOTARY_AUTH_DESC
#   notary_submit_and_wait "$TARGET" || exit 1         # submit, wait, verify Accepted
#   unset NOTARY_AUTH NOTARY_AUTH_DESC                 # after the last submit
#
# Credentials are looked up in this order (explicit beats implicit):
#   1. App Store Connect API key:  NOTARY_KEY=<path to AuthKey_XXXX.p8>  NOTARY_KEY_ID  NOTARY_ISSUER
#   2. Apple ID + app-specific password:  NOTARY_APPLE_ID  NOTARY_PASSWORD  [NOTARY_TEAM_ID]
#   3. Keychain profile:  NOTARY_PROFILE (default omgui-notary), created with
#        xcrun notarytool store-credentials omgui-notary --apple-id … --team-id … --password …
# See docs/RELEASE.md for the full setup instructions for all three.
#
# Nothing is ever written to disk by these scripts; the password in (2) is visible to `ps` on
# this machine for the duration of the upload, which is the trade-off for not touching the
# keychain. `set -x` tracing is suppressed around credential handling and each submit below (U1)
# so `bash -x notarize-app.sh` — the normal way to debug a failing run — never echoes a password
# or API key to stderr/scrollback/a CI log; it is restored immediately after. Callers should
# `unset NOTARY_AUTH` once the last submit is done so a stray `env`/core dump later in the shell
# doesn't carry it.
#
resolve_notary_auth() {
    local expected_team="${1:-}"
    local xtrace_was_on=0
    case "$-" in *x*) xtrace_was_on=1; set +x ;; esac

    _resolve_notary_auth_impl "$expected_team"
    local rc=$?

    [[ "$xtrace_was_on" -eq 1 ]] && set -x
    return $rc
}

_resolve_notary_auth_impl() {
    local expected_team="${1:-}"
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
        # L6: no hard-coded team default. Fall back to the artifact's own signing team (passed in
        # by the caller) rather than a fixed constant, and refuse outright if an explicit
        # NOTARY_TEAM_ID disagrees with it — that mismatch is exactly how a submission ends up
        # under the wrong team, surfacing later as an opaque stapler failure.
        local team="${NOTARY_TEAM_ID:-$expected_team}"
        [[ -n "$team" ]] \
            || { printf 'ERROR: NOTARY_TEAM_ID is not set and no signing team could be derived from the artifact; set NOTARY_TEAM_ID explicitly.\n' >&2; return 1; }
        if [[ -n "$expected_team" && "$team" != "$expected_team" ]]; then
            printf 'ERROR: NOTARY_TEAM_ID (%s) does not match the signed artifact'"'"'s TeamIdentifier (%s) — refusing to submit under a mismatched team.\n' "$team" "$expected_team" >&2
            return 1
        fi
        NOTARY_AUTH=(--apple-id "$NOTARY_APPLE_ID" --team-id "$team" --password "$NOTARY_PASSWORD")
        NOTARY_AUTH_DESC="Apple ID $NOTARY_APPLE_ID (team $team)"
    else
        local profile="${NOTARY_PROFILE:-omgui-notary}"
        NOTARY_AUTH=(--keychain-profile "$profile")
        NOTARY_AUTH_DESC="keychain profile $profile"
    fi

    # Prove the credentials work before spending an upload on them — the single pre-flight for
    # all three branches (L5). Captures stderr instead of discarding it: a transient network
    # error or an Apple 503 must not read the same as a rejected password.
    local preflight_err preflight_rc=0
    preflight_err="$(xcrun notarytool history "${NOTARY_AUTH[@]}" 2>&1 >/dev/null)" || preflight_rc=$?
    if [[ $preflight_rc -ne 0 ]]; then
        printf 'ERROR: notarytool rejected the credentials (%s):\n%s\n' "$NOTARY_AUTH_DESC" "$preflight_err" >&2
        printf 'Provide one of NOTARY_KEY/KEY_ID/ISSUER, NOTARY_APPLE_ID/PASSWORD, or a keychain profile — see docs/RELEASE.md.\n' >&2
        return 1
    fi
    return 0
}

# notary_submit_and_wait <path> — submit, wait (bounded), and verify the result was actually
# Accepted (M10). `--wait`'s own exit status is 0 for a submission that completes Invalid, so it
# is not sufficient on its own; this parses the JSON status line, and on anything but Accepted
# fetches and prints `notarytool log` before failing, instead of leaving the operator to guess
# from a stapler error two lines later. `--timeout` bounds an otherwise-indefinite hang on a stuck
# submission.
notary_submit_and_wait() {
    local target="$1"
    local xtrace_was_on=0
    case "$-" in *x*) xtrace_was_on=1; set +x ;; esac

    local out status id
    local rc=0
    out="$(xcrun notarytool submit "$target" "${NOTARY_AUTH[@]}" --wait --timeout 30m -f json 2>&1)" || rc=$?
    [[ "$xtrace_was_on" -eq 1 ]] && set -x

    if [[ $rc -ne 0 ]]; then
        printf 'ERROR: notarytool submit failed (exit %s):\n%s\n' "$rc" "$out" >&2
        return 1
    fi

    status="$(printf '%s' "$out" | jq -r '.status // empty' 2>/dev/null)"
    id="$(printf '%s' "$out" | jq -r '.id // empty' 2>/dev/null)"

    if [[ "$status" != "Accepted" ]]; then
        printf 'ERROR: notarytool submission %s status: %s\n' "${id:-unknown}" "${status:-unknown}" >&2
        printf '%s\n' "$out" >&2
        if [[ -n "$id" ]]; then
            printf 'Fetching notarytool log for %s:\n' "$id" >&2
            xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >&2 || true
        fi
        return 1
    fi
    return 0
}
