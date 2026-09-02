# Vendored: libomapi

- Repo: https://github.com/openmovementproject/libomapi.git
- Commit: `606c32f18a5542d785bf5ff603df0acb7acabab2`
- Vendored: 2026-09-02
- Licence: BSD 2-clause (`LICENSE.TXT`), Newcastle University.

## What was taken

| Upstream path | Here |
|---|---|
| `include/omapi.h` | `include/omapi.h` |
| `src/omapi-main.c` `omapi-internal.c` `omapi-download.c` `omapi-status.c` `omapi-reader.c` `omapi-settings.c` `omapi-internal.h` | `src/` |
| `src/omapi-devicefinder-mac.c` | `src/` |

## What was deliberately left out

- `src/omapi-devicefinder-win.cpp`, `src/omapi-devicefinder-linux.c` — non-macOS backends.
- `src/omapi-export.c` — Windows DLL export shim (`#error` on non-Windows).
- `src/Makefile`, `src/build.cmd`, `src/_build-watcher/`, `libomapi.vcxproj`, `libomapi.xcodeproj`,
  `bindings/`, `examples/`, `docs/` — replaced by this repo's SwiftPM `COmApi` target.

Local modifications are listed in `../PATCHES.md`.
