# Releasing omgui-mac

## One-time setup

1. **Developer ID Application certificate.** Xcode → Settings → Accounts → select your Apple ID
   → Manage Certificates → **+** → Developer ID Application. This installs the cert + private key
   in your login keychain; `scripts/build-app.sh`/`build-dmg.sh` pick it up automatically via
   `security find-identity -v -p codesigning`. If more than one Developer ID Application identity
   is installed, the scripts refuse to guess — set `SIGN_IDENTITY=<hash-or-name>` to pick one.
2. **Notary credentials.** Pick one of the three options in [§Notarization
   credentials](#notarization-credentials-three-options-checked-in-this-order) below — the
   keychain profile is only one of them, and it's the option most likely to misbehave in a
   non-interactive shell.

## Cutting a release

Tag first, then release — `release.sh` requires HEAD to sit exactly on a git tag unless you pass
`--version` explicitly:

```sh
git tag vX.Y.Z
scripts/release.sh
```

or, without tagging:

```sh
scripts/release.sh --version X.Y.Z
```

which runs, in this exact order:

```sh
scripts/build-app.sh          # dist/OmGui.app, Developer ID signed
scripts/notarize-app.sh       # submit the .app, staple + validate it
scripts/build-dmg.sh          # dist/OmGui-<version>.dmg, built from the STAPLED .app, signed
scripts/notarize-dmg.sh       # submit the DMG, staple + validate it
```

**The order matters.** The app is notarized and stapled *before* the DMG is built, so the ticket
travels with `OmGui.app` itself — a user who drags the app out of the DMG onto an offline or
firewalled Mac still launches cleanly. Building the DMG first and only stapling the DMG (the old
order) leaves the app with no ticket of its own. `build-dmg.sh` itself refuses to package an
un-stapled Developer-ID-signed app (run `notarize-app.sh` first), and `notarize-dmg.sh` mounts the
built DMG and validates the staple on the copy actually sealed inside it, not `dist/OmGui.app` —
so a DMG built out of order cannot ship green. Each script fails hard (not a warning) if
`stapler staple`/`stapler validate` fails, if no notarytool credentials resolve, or if the
object being submitted isn't signed with a Developer ID Application identity — an Apple
Development or ad-hoc signature is caught here instead of surfacing as an opaque notarytool
rejection after a full upload-and-wait.

`build-app.sh` derives the version from `git describe --exact-match --tags`, stripping a leading
`v` (a `vX.Y.Z` tag) — this fails loudly on a commit that isn't exactly on a tag rather than
silently accepting an abbreviated hash. The build also fails if the result isn't a plain numeric
dot-separated version — pass `--version X.Y.Z` explicitly for an untagged commit, since
`AppInfo.isNumericVersion` rejects anything else in the shipped app and would silently fall back
to `1.0.0`.

Then:

```sh
git push origin vX.Y.Z
gh release create vX.Y.Z dist/OmGui-X.Y.Z.dmg --title "OmGui vX.Y.Z" --notes "..."
```

Add `--adhoc` to `build-app.sh`/`build-dmg.sh` for a local test build with no Developer ID cert
installed — `notarize-app.sh`/`notarize-dmg.sh` refuse to run against an ad-hoc-signed object.

## What a site user does

1. Download and double-click the `.dmg`.
2. Drag `OmGui.app` to `Applications`.
3. Launch it. On first read of an attached AX3/AX6 volume, macOS shows the removable-volumes
   permission prompt (`NSRemovableVolumesUsageDescription`) — allow it. The first refresh of a
   Documents/Desktop/Downloads workspace shows the corresponding folder-access prompt — allow that
   too, or the Data Files tab renders empty with no error.

## Notarization credentials (three options, checked in this order)

The scripts never store anything. Set one of these in the shell that runs `scripts/release.sh`:

1. **App Store Connect API key** (most reliable on a Mac whose keychain misbehaves): App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → generate (Developer role), download the `.p8` once, keep it outside the repo.
   `NOTARY_KEY=~/.private/notary/AuthKey_XXXXXXXXXX.p8 NOTARY_KEY_ID=XXXXXXXXXX NOTARY_ISSUER=<issuer-uuid>`
2. **Apple ID + app-specific password** (nothing stored; the password is visible to `ps` during the upload):
   `NOTARY_APPLE_ID=<apple-id> NOTARY_PASSWORD=<app-specific-password>` (team defaults to the artifact's own signing team, i.e. the `TeamIdentifier` from `codesign -dvv`; set `NOTARY_TEAM_ID` to override, but a mismatch against the signed artifact is refused)
3. **Keychain profile** `omgui-notary` (or `NOTARY_PROFILE`), created with `xcrun notarytool store-credentials …` in Terminal.app.

Example, from Terminal.app:

```
cd ~/projects/omgui-mac
NOTARY_APPLE_ID=<apple-id> NOTARY_PASSWORD='<app-specific-password>' bash scripts/release.sh
```
