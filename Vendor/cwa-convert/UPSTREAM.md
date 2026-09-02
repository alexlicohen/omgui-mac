# Vendored: cwa-convert

- Repo: https://github.com/digitalinteraction/openmovement.git
- Commit: `38c11714aa63684f14721c6f5e59dbaf156c62f6`
- Upstream path: `Software/AX3/cwa-convert/c/`
- Vendored: 2026-09-02
- Licence: BSD 2-clause (`LICENSE.TXT`, copied from `Software/LICENSE.TXT`), Newcastle University.

`main.c`, `cwa.c`, `cwa.h`, `README.md` taken verbatim.

Left out: `sqlite3.c` / `sqlite3.h` (4.7 MB amalgamation). Upstream `main.c` line 14 is
`//#define SQLITE` — every SQLite reference is inside `#ifdef SQLITE`, so the default upstream
build contains no SQLite code and links none. To re-enable, drop the amalgamation back in,
`#define SQLITE`, and add `-ldl` to the link line.

Also left out: `Makefile`, `cwa-convert.sln`, `cwa-convert.vcxproj*` — see `scripts/build-helpers.sh`.

No source modifications.
