#!/usr/bin/env bash
#
# Port of "Plugins for release/Plugins/OmConvertPlugin/run-omconvert.cmd".
#
# Same contract: one argument, the source .CWA. Writes <source>.wav, <source>.svm.csv,
# <source>.wtv.csv and <source>.paee.csv beside it, via a temporary directory so a failed run
# leaves nothing behind. omconvert.exe sits next to the .cmd upstream; here it is the signed
# helper in OmGui.app/Contents/Helpers (or build/helpers in a checkout).
#
# Progress goes to stdout in the plugin protocol OmGui already parses ("p <percent>",
# "e <message>"), so the Plugin Queue tab shows real progress for this plugin.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { printf 'e %s\n' "$*"; printf 'ERROR: %s\n' "$*" >&2; exit 1; }

INPUT="${1:-}"
[ -n "$INPUT" ] || fail "No input file specified."
[ -f "$INPUT" ] || fail "Input file not found: $INPUT"
INPUT="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"
OUTPUT="${INPUT%.*}"

# omconvert: the override first, then the app bundle and the checkout. This script lives in
#   <OmGui.app>/Contents/Resources/Plugins/OmConvertPlugin/  ->  ../../../Helpers/omconvert
#   <repo>/Resources/Plugins/OmConvertPlugin/                ->  ../../../build/helpers/omconvert
# and PATH is the last resort.
OMCONVERT=""
for candidate in \
    "${OMGUI_HELPER_DIR:-/nonexistent}/omconvert" \
    "$HERE/../../../Helpers/omconvert" \
    "$HERE/../../../build/helpers/omconvert" \
    "$(command -v omconvert 2>/dev/null || true)"
do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then OMCONVERT="$candidate"; break; fi
done
[ -n "$OMCONVERT" ] || fail "Executable not found: omconvert"

TEMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/CBR-XXXXXX")" || fail "Could not create a temporary directory."
trap 'rm -rf "$TEMPDIR"' EXIT

echo "OMCONVERT: INPUT: $INPUT"
echo "OMCONVERT: OUTPUT: $OUTPUT"
echo "OMCONVERT: TEMPORARY: $TEMPDIR"
echo "OMCONVERT: Running: $OMCONVERT \"$INPUT\" \"$TEMPDIR\""
echo "p 10"

"$OMCONVERT" "$INPUT" \
    -out "$TEMPDIR/file.wav" \
    -svm-file "$TEMPDIR/file.svm.csv" \
    -wtv-file "$TEMPDIR/file.wtv.csv" \
    -paee-file "$TEMPDIR/file.paee.csv" || fail "omconvert failed ($?)."

echo "p 80"

moved=0
for suffix in wav svm.csv wtv.csv paee.csv; do
    if [ -f "$TEMPDIR/file.$suffix" ]; then
        mv -f "$TEMPDIR/file.$suffix" "$OUTPUT.$suffix" || fail "Could not write $OUTPUT.$suffix"
        moved=$((moved + 1))
    fi
done
[ "$moved" -gt 0 ] || fail "omconvert produced no output."

echo "p 100"
echo "OMCONVERT: Wrote $moved file(s) for $OUTPUT"
