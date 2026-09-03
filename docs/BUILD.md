# Building omgui-mac

## Requirements

| | |
|---|---|
| Hardware | Apple Silicon (arm64). Intel is not a target. |
| macOS | 14 or later (deployment target); developed on 26.6 |
| Toolchain | Swift 6 (developed on 6.3, Xcode 26.6) |
| Dependencies | none — no SwiftPM packages beyond the standard library, no Homebrew |

There is deliberately **no `.xcodeproj`**. The package is SwiftPM only; a later phase assembles
the `.app` bundle with a script.

## Commands

```sh
swift build                     # debug
swift build -c release          # release
swift test                      # XCTest suite
swift run omgui-cli status --mock
bash scripts/build-helpers.sh   # arm64 omconvert + cwa-convert into build/helpers/
bash scripts/build-helpers.sh --clean
```

## Targets

| Target | Kind | Notes |
|---|---|---|
| `COmApi` | C library | Vendored libomapi at `Vendor/libomapi`, `src/` compiled, `include/` public. Links CoreFoundation, IOKit, DiskArbitration. |
| `OmApi` | Swift library | The API surface, mirroring upstream `omapinet`. Swift 6 language mode. |
| `omgui-cli` | executable | Command-line front end. |
| `OmApiTests` | test | XCTest. |

`COmApi` deliberately vendors only the macOS device finder; the Windows and Linux finders and the
Windows DLL export shim are not present. See `Vendor/libomapi/UPSTREAM.md`.

## Language mode

Everything is built in **Swift 6 language mode with full strict concurrency** — including the code
that talks to C. No target falls back to Swift 5.

The C interop layer needs no relaxation because it never lets the compiler reason about C state:
libomapi's callbacks are `@convention(c)` function pointers that carry an
`Unmanaged<LibOmapiBackend>` pointer as their user reference, and the Swift objects they reach
(`LibOmapiBackend`, `OmApi`, `OmDevice`, `MockBackend`) are `final class … @unchecked Sendable`
with an explicit `NSLock`/`NSRecursiveLock` around their mutable state. The one global —
`LibOmapiBackend.current`, which enforces that only one backend owns libomapi's process-wide
callback slots — is `nonisolated(unsafe)` behind its own lock.

## Helper binaries

`scripts/build-helpers.sh` compiles the vendored `omconvert` and `cwa-convert` with `clang` for
`arm64` into `build/helpers/`, then verifies each binary's architecture with `lipo` and checks it
prints usage. It rebuilds only when a vendored source is newer than the binary.

Two deliberate deviations from upstream's Makefiles:

* **`-O2`, no `-ffast-math`, no `-march=native`.** Upstream uses `-O3 -ffast-math -march=native`.
  Phase 3 diffs this binary's output against the Windows `omconvert` for the same `.cwa` fixture,
  and reproducible arithmetic is worth more there than the last few per cent of speed.
* **`mmap-win32.c` is not compiled** (it needs `<io.h>`; `omdata.c` only includes its header under
  `#ifdef _WIN32`), and **sqlite3 is not vendored at all** (upstream `cwa-convert/main.c` keeps
  `//#define SQLITE` commented out, so the default build links none of it).

The vendored sources emit a handful of `-Wunused-*` warnings under `-Wall`. They are upstream's
and are left alone; patching them would add churn to a tree we want to keep diffable.

## Where the build output goes

```
.build/                  SwiftPM (gitignored)
build/helpers/omconvert
build/helpers/cwa-convert
```

`build/` is gitignored. A later phase copies `build/helpers/` into `OmGui.app/Contents/Helpers`.

## App bundle

```sh
scripts/build-app.sh [--adhoc] [--version X.Y.Z]   # dist/OmGui.app
scripts/notarize-app.sh                            # notarize + staple the .app (Developer ID build only)
scripts/build-dmg.sh [--adhoc]                     # dist/OmGui-<version>.dmg, built from the stapled .app
scripts/notarize-dmg.sh                            # notarize + staple the .dmg
scripts/release.sh [--version X.Y.Z]               # runs all four in that order
```

`build-app.sh` builds the `OmGui` executable, runs `build-helpers.sh`, and assembles the bundle
from `Resources/` (icon, `Info.plist.in` template, entitlements), signing with a Developer ID
Application identity when one is installed and ad-hoc otherwise. `dist/` is gitignored. The app
must be notarized and stapled *before* the DMG is built — see [`docs/RELEASE.md`](RELEASE.md) for
why the order matters and for the full release process.
