# Vendored: omconvert

- Repo: https://github.com/digitalinteraction/openmovement.git
- Commit: `38c11714aa63684f14721c6f5e59dbaf156c62f6`
- Upstream path: `Software/AX3/omconvert/`
- Vendored: 2026-09-02
- Licence: BSD 2-clause (`LICENSE.TXT`, copied from `Software/LICENSE.TXT`), Newcastle University.

All `*.c` / `*.h` plus `README.md` were taken verbatim. Left out: `OmConvert-Output.docx`,
`Makefile`, `Makefile.lambda`, `omconvert.sln`, `omconvert.vcxproj*` — this repo builds it with
`scripts/build-helpers.sh`.

`mmap-win32.c` is vendored (for fidelity) but is not compiled on macOS: it needs `<io.h>`, and
`omdata.c` only includes `mmap-win32.h` under `#ifdef _WIN32`.

No source modifications.
