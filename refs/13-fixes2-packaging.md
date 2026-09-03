# Packaging/release fix pass 2 — H7, H8, M8–M14, L5–L10, U1, U2, U4

Answers `refs/12-deep-review-2.md`. Owned: `scripts/`, `docs/`, `README.md`,
`refs/09-mop-alignment-notes.md`. The libomapi and flows/CLI findings (H1–H6, M1–M7, L1–L4, U3)
belong to other tasks and are untouched here.

## H7 — an un-notarized app could ship green

The gap: `build-dmg.sh` had no staple precondition, and `notarize-dmg.sh` validated
`dist/OmGui.app` — not the copy actually sealed inside the DMG. Run in the old order
(build-app → build-dmg → notarize-app → notarize-dmg), every script printed success while the
enclosed app carried no ticket.

- `build-dmg.sh`: refuses (`xcrun stapler validate "$APP"`) unless `--adhoc`, before the `ditto`.
- `notarize-dmg.sh`: mounts the built DMG read-only to a `mktemp -d` mountpoint, runs
  `stapler validate` against `$MOUNT/OmGui.app`, detaches in a trap regardless of outcome, then
  fails if that validation didn't return 0.

Proof: `build-app.sh` (Developer ID) → `build-dmg.sh` now refuses non-zero, citing
"not notarized+stapled — run scripts/notarize-app.sh first". `build-dmg.sh --adhoc` still works.

## M8 — rpath parsing split on whitespace

`awk '{print $2}'` truncated any Xcode path containing a space (`/Applications/Xcode 26.app/...`
→ `/Applications/Xcode`), then hard-failed `install_name_tool -delete_rpath` after the bundle was
already assembled. `toolchain_rpaths()` in `build-app.sh` now parses the `path` field with
`sed -n 's/^ *path \(.*\) (offset [0-9]*)$/\1/p'`, robust to embedded spaces, used for both the
strip loop and the re-check.

## M9 — an all-decimal hash could pass as a version

`git describe --tags --always` falls back to an abbreviated hash, and the old regex
(`^[0-9]+(\.[0-9]+){0,3}$`) accepted a dotless all-digit one (~3.7% of 7-hex abbreviations).
`build-app.sh` now requires a dot (`^[0-9]+\.[0-9]+(\.[0-9]+){0,2}$`) and derives the version from
`git describe --exact-match --tags` (no `--always`) — an off-tag build fails loudly instead of
shipping a version like `0123456` that sorts above every real 1.x.y.

## M10 — notarytool `--wait` exit status doesn't mean Accepted

`--wait` returns 0 for a submission that completes `Invalid`. `notary_submit_and_wait()`
(`lib-notary.sh`) now submits with `--timeout 30m -f json`, parses `.status`/`.id`, and on anything
but `Accepted` fetches and prints `xcrun notarytool log "$id"` before failing — the real rejection
reason surfaces immediately instead of the operator being pointed at a `stapler staple` failure
two lines later.

## M11, L8 — script headers didn't describe the credential split

`notarize-app.sh`, `notarize-dmg.sh`, `release.sh` headers now name all three credential options
(API key / Apple ID+password / keychain profile) and point at `lib-notary.sh` + `RELEASE.md`.
`lib-sign.sh`'s header no longer claims the notarize scripts source it — they determine the
identity independently from the already-signed artifact's `codesign -dvv` output.

## M12, M14, L9 — refs/09 stale pointers and wrap

- `scripts/notarize.sh` (deleted in `f825311`) → `scripts/release.sh`.
- The self-test evidence paragraph no longer hard-codes "19 CHECK lines" (five `expect()` sites
  were added since that count was written, and the committed transcript wasn't regenerated) — it
  now describes the pass/fail contract instead of a count that drifts.
- Capitalized "the study's MOP-alignment steps write..." and re-wrapped the 124-column line 3.

## M13 — README described a pre-GUI repo

Status line, opening paragraph and Layout block were still phase-0/1 ("No GUI yet"). Updated to
name `Sources/OmGui`/`OmGuiCore`/`Tests/OmGuiTests` and the packaging scripts/docs, and dropped the
reference to the deleted `refs/00-plan.md`.

## L10 — BUILD.md contradicted itself

":12-13 and :77 still said "a later phase" for work the range had already shipped (the `.app`
bundle script, copying `build/helpers/` into it). Targets table was missing `OmGuiCore`, `OmGui`,
`OmGuiTests`. Also corrected the App bundle section's claim that `build-app.sh` falls back to
ad-hoc signing automatically — it now fails hard without `--adhoc` (U2).

## L5 — credential pre-flight discarded stderr

`_resolve_notary_auth_impl()`'s pre-flight (`xcrun notarytool history`) now captures stderr and
prints it on failure, so a transient network error or an Apple 503 doesn't read identically to a
rejected password. Also de-duplicated: the keychain branch no longer probes credentials twice
(once as a branch condition, once as the pre-flight) — one pre-flight covers all three branches.

## L6 — no team-identity cross-check

`NOTARY_TEAM_ID` defaulted to a hard-coded team constant with nothing comparing it to the signing
identity. `resolve_notary_auth` now takes the artifact's own `TeamIdentifier` (from
`codesign -dvv`, read by the caller) as an expected-team argument, defaults to it when
`NOTARY_TEAM_ID` isn't set, and refuses outright on a mismatch. The hard-coded team id is gone from
`lib-notary.sh`, `notarize-app.sh`, and `docs/RELEASE.md`.

## L7 — wrong rpath comment

The comment justifying the toolchain-rpath strip claimed "every Swift dylib the app uses ships
inside the bundle" — false; nothing is bundled, the app uses the OS Swift runtime, no
`Contents/Frameworks` is ever created. Comment corrected, and `no_rpath_deps()` now asserts (via
`otool -L | grep '@rpath/'`) that no `@rpath/`-relative dependency exists, for the main binary and
both helpers — the day that assumption stops holding, the build fails instead of shipping a
silent launch-time failure.

## U1 — password visible under `bash -x`

`NOTARY_AUTH` (containing `--password "$NOTARY_PASSWORD"`) was traced to stderr by
`bash -x`, the normal way to debug a failing notarization. `resolve_notary_auth` and
`notary_submit_and_wait` now suspend and restore `set -x` around credential handling and each
submit (bash-3.2-safe `case "$-" in *x*) ...`, no `[[ =~ ]]` on `$-`), and both `notarize-app.sh`
and `notarize-dmg.sh` `unset NOTARY_AUTH NOTARY_AUTH_DESC` immediately after their last submit.

## U2 — silent ad-hoc fallback

`resolve_sign_identity` returned `0` (empty string) whenever no Developer ID identity was found —
indistinguishable from a locked keychain or an expired cert, and `build-app.sh` signed with `-`
and reported success regardless. It now `return 1`s when nothing is found; `build-app.sh` and
`build-dmg.sh` accept an empty identity only under `--adhoc`, otherwise fail naming the likely
causes (locked login keychain, expired cert, none installed) and how to check
(`security find-identity -v -p codesigning`). `release.sh` rejects `--adhoc` up front — it forwards
version flags to `build-app.sh` only, so `--adhoc` reaching only that script (never
`build-dmg.sh`) would have produced an ad-hoc app plus a Developer-ID DMG attempt.

## U4 — release.sh required an exact tag with no clear remedy

Documented order was `release.sh` then `git tag`; one commit past a tag,
`git describe --tags --always` yields a suffixed description the version regex rejects, so a bare
`release.sh` died three lines into step 1/4 with no obvious fix. `release.sh` now checks
`git describe --exact-match --tags` itself before step 1 and fails immediately, naming both
remedies (tag first, or pass `--version`). `RELEASE.md`'s "Cutting a release" section now leads
with `git tag vX.Y.Z` before `scripts/release.sh`.

## Verified

- `bash -n` clean on all eight scripts.
- `bash scripts/build-app.sh --adhoc` — builds and signs ad-hoc.
- `bash scripts/release.sh --adhoc` — exits non-zero immediately: "release.sh does not support
  --adhoc".
- `bash scripts/build-app.sh` (Developer ID present) → `bash scripts/build-dmg.sh` — refuses:
  "not notarized+stapled — run scripts/notarize-app.sh first" (H7 proof; no notarization run).
- `bash scripts/build-dmg.sh --adhoc` on the ad-hoc app from the first bullet — succeeds.
