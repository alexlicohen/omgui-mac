# Releasing omgui-mac

## One-time setup

1. **Developer ID Application certificate.** Xcode → Settings → Accounts → select your Apple ID
   → Manage Certificates → **+** → Developer ID Application. This installs the cert + private key
   in your login keychain; `scripts/build-app.sh`/`build-dmg.sh` pick it up automatically via
   `security find-identity -v -p codesigning`.
2. **Notary credentials**, stored once in the keychain (never on disk):
   ```sh
   xcrun notarytool store-credentials omgui-notary \
       --apple-id <your Apple ID email> \
       --team-id V9R6KQRWSD \
       --password <app-specific password>
   ```
   Generate the app-specific password at appleid.apple.com. `NOTARY_PROFILE` overrides the
   profile name if you use something other than `omgui-notary`.

## Cutting a release

```sh
scripts/build-app.sh              # dist/OmGui.app, Developer ID signed
scripts/build-dmg.sh              # dist/OmGui-<version>.dmg, signed
scripts/notarize.sh               # submit, staple DMG + app, print Gatekeeper check
```

`build-app.sh` derives the version from `git describe --tags --always`; pass `--version X.Y.Z` to
override. Then:

```sh
git tag vX.Y.Z
git push origin vX.Y.Z
gh release create vX.Y.Z dist/OmGui-X.Y.Z.dmg --title "OmGui vX.Y.Z" --notes "..."
```

Add `--adhoc` to `build-app.sh`/`build-dmg.sh` for a local test build with no Developer ID cert
installed — `notarize.sh` refuses to run against an ad-hoc-signed app.

## What a site user does

1. Download and double-click the `.dmg`.
2. Drag `OmGui.app` to `Applications`.
3. Launch it. On first read of an attached AX3/AX6 volume, macOS shows the removable-volumes
   permission prompt (`NSRemovableVolumesUsageDescription`) — allow it.
