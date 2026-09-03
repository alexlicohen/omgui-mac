# OmGui for Mac — agent notes

Native Apple Silicon port of Axivity's OMGUI (SwiftPM, Swift 6 strict, macOS 14+). Mirrors OMGUI's
functionality and appearance; spec inventory in `refs/03`, upstream C# under `upstream/` (gitignored clone —
`git clone --sparse` of digitalinteraction/openmovement, plus openmovementproject/libomapi and openmovement-python).

## Commands
- Build/test: `swift build -c release`, `swift test` (391 cases), `.build/release/OmGui --mock --self-test` (mock end-to-end; refuses without `--mock`).
- App bundle/release: `scripts/build-app.sh`, `scripts/build-dmg.sh` (refuses an unstapled Developer-ID app), `scripts/release.sh` (tag first: needs `git describe --exact-match --tags` or `--version`). Notary credentials: see `docs/RELEASE.md` (API key env vars preferred; the keychain profile route is unreliable on the dev Mac).
- `omgui-cli` mirrors the app's safety guards; `clear` requires `--device|--all`, confirms, refuses recording-with-data without `--force`.

## Danger zones (deep review before merge; see refs/10, refs/12 and the fixes in refs/11-*, refs/13-*)
- `Vendor/libomapi/src` — vendored C with local patches logged in `Vendor/PATCHES.md`. Threading (download thread, discovery thread, shutdown/removal) has no automated coverage; only hardware exercises it.
- `Sources/OmApi` + `Sources/OmGuiCore/DeviceFlows.swift` — anything that can erase a device or mis-name a download.
- `scripts/` — anything that could ship an unsigned/unstapled artifact.

## Rules
- Public tree is study-agnostic: no study, consortium, vendor, site or person names (check: the whole-word grep in `scripts`/review notes). Study-specific docs live outside this repo.
- Keep OMGUI's exact labels, prompts, defaults and layout; deviations are documented in `refs/05`, `refs/09`.
- Never touch `upstream/`; vendored sources change only with a `PATCHES.md` entry.
