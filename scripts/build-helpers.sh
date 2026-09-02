#!/usr/bin/env bash
#
# Build the bundled command-line helpers (omconvert, cwa-convert) from the vendored sources.
#
# These are the analysis/conversion tools OMGUI shells out to (SVM, cut points, wear time, sleep,
# resampled WAV/CSV, raw CSV). They are portable C, so the Mac port ships arm64 builds of the same
# sources rather than reimplementing them. A later phase copies build/helpers/ into the .app bundle.
#
#   bash scripts/build-helpers.sh            # build what is out of date
#   bash scripts/build-helpers.sh --clean    # remove build/helpers first
#   CC=clang ARCH=arm64 bash scripts/build-helpers.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$REPO_ROOT/Vendor"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/build/helpers}"
CC="${CC:-clang}"
ARCH="${ARCH:-arm64}"
MACOS_MIN="${MACOS_MIN:-14.0}"

# -O2 without -ffast-math or -march=native: upstream's Makefile uses "-O3 -ffast-math
# -march=native", but reproducible numerics matter more here than the last few per cent, because
# phase 3 diffs this binary's output against the Windows build for the same .cwa file.
COMMON_FLAGS=(-O2 -Wall -arch "$ARCH" "-mmacosx-version-min=$MACOS_MIN")

if [[ "${1:-}" == "--clean" ]]; then
    echo "Removing $OUT_DIR"
    rm -rf "$OUT_DIR"
fi

mkdir -p "$OUT_DIR"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# needs_rebuild <target> <source dir>
needs_rebuild() {
    local target="$1" source_dir="$2"
    [[ -x "$target" ]] || return 0
    local newer
    newer="$(find "$source_dir" -type f \( -name '*.c' -o -name '*.h' \) -newer "$target" -print -quit)"
    [[ -n "$newer" ]]
}

# ---------------------------------------------------------------------------
# omconvert
#
# mmap-win32.c is excluded: it needs <io.h>, and omdata.c only includes mmap-win32.h under
# #ifdef _WIN32, so on macOS it contributes nothing.
# ---------------------------------------------------------------------------
build_omconvert() {
    local src="$VENDOR/omconvert"
    local target="$OUT_DIR/omconvert"
    [[ -d "$src" ]] || fail "missing $src"

    if ! needs_rebuild "$target" "$src"; then
        log "omconvert     up to date"
        return
    fi

    local sources=()
    while IFS= read -r file; do sources+=("$file"); done < <(
        find "$src" -maxdepth 1 -name '*.c' ! -name 'mmap-win32.c' | sort
    )
    [[ ${#sources[@]} -gt 0 ]] || fail "no omconvert sources in $src"

    log "omconvert     compiling ${#sources[@]} files"
    "$CC" -std=c99 "${COMMON_FLAGS[@]}" -o "$target" "${sources[@]}" -lm -lpthread
}

# ---------------------------------------------------------------------------
# cwa-convert
#
# sqlite3 is not vendored: upstream main.c keeps "//#define SQLITE" commented out, so every
# SQLite reference is inside #ifdef SQLITE and the default build links none of it.
# ---------------------------------------------------------------------------
build_cwa_convert() {
    local src="$VENDOR/cwa-convert"
    local target="$OUT_DIR/cwa-convert"
    [[ -d "$src" ]] || fail "missing $src"

    if ! needs_rebuild "$target" "$src"; then
        log "cwa-convert   up to date"
        return
    fi

    log "cwa-convert   compiling"
    "$CC" -std=gnu99 "${COMMON_FLAGS[@]}" -I "$src" -o "$target" \
        "$src/main.c" "$src/cwa.c" -lm
}

verify() {
    local target="$OUT_DIR/$1"
    [[ -x "$target" ]] || fail "$1 was not produced at $target"

    local archs
    archs="$(lipo -archs "$target" 2>/dev/null || true)"
    [[ "$archs" == *"$ARCH"* ]] || fail "$1 is '$archs', expected $ARCH"

    # Both tools exit non-zero and print usage when given no input file.
    local usage
    usage="$("$target" 2>&1 || true)"
    [[ "$usage" == *"Usage"* || "$usage" == *"usage"* ]] || fail "$1 did not print usage"

    log "  $1 ($archs): $(printf '%s' "$usage" | grep -im1 'usage' | cut -c1-72)"
}

build_omconvert
build_cwa_convert

log "Verifying:"
verify omconvert
verify cwa-convert

log "Helpers in $OUT_DIR"
