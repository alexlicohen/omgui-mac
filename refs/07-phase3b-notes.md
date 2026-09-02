# Phase 3b notes — exports, tools and the plugin host

What landed: `HelperTools` (finds the bundled `omconvert`/`cwa-convert`), `OmConvertJob` (the
argument builders), `ToolProcess`/`ToolJobController` (the runner and the Plugin Queue producer),
`ExportFlow` (`GetSelectedFilesForConvert` + `CheckWavConversion`), `PluginDescriptor`/
`PluginManager`/`PluginHost` (the `.plugin` schema and the `RunPluginForm` contract), seven dialogs,
the File/Tools/toolbar wiring, and `Resources/Plugins/OmConvertPlugin/`. 66 new tests; the
`--self-test` run in `refs/screenshots/self-test-transcript.txt` exports, analyses and runs the
plugin end to end on the mock file with the real helpers.

## Which binary each action runs

| Action | Helper | Input | Output |
|---|---|---|---|
| Export Resampled WAV… | omconvert | `.cwa` | `.wav` (see the `ext` bug below) |
| Export Resampled CSV… | omconvert | `.wav` | `.resampled.csv` |
| Export Raw CSV… | **cwa-convert** | `.cwa` | the chosen `.csv` |
| Calculate SVM… | omconvert | `.wav` | `.svm.csv` |
| Calculate Cut Points… | omconvert | `.wav` | `.cut.csv` |
| Calculate Wear Time… | omconvert | `.wav` | `.wtv.csv` |
| Calculate Sleep Time… | omconvert | `.wav` | `.sleep.csv` |
| Tools ▸ Plugins… ▸ OMConvert | `run-omconvert.sh` → omconvert | `.cwa` | `.wav .svm.csv .wtv.csv .paee.csv` |

Every analysis is preceded by `CheckWavConversion`, which runs
`omconvert "<cwa>" -calibrate 1 -out "<wav>.part"` when the `.wav` is missing, older than the
`.cwa`, or Shift was held. Both steps are one queue row.

## Deviations from OMGUI, and why

* **Raw CSV runs `cwa-convert`, not an in-process reader.** `refs/03 §5` says this export uses the
  libomapi reader; it does not. `ExportForm.cs:16` is
  `EXECUTABLE_NAME = @"Plugins\Convert_CWA\cwa-convert.exe"`, and `buttonConvert_Click` builds
  `-f:csv -out … -s:… -v:… -t:… [-start/-length/-step] [-blockstart/-blockcount]`. Running the same
  vendored C gives byte-identical output to the Windows build, which reimplementing the CSV writer
  in Swift would not; it also keeps this phase out of `Sources/OmApi/OmReader.swift`, which another
  task owns. `refs/03 §5` is wrong on this row.
* **Tool jobs go through the Plugin Queue, not a modal dialog.** Upstream opens a `ProcessingForm`
  per file and blocks the window; a batch of eight files is eight modal dialogs. The port queues
  them (serially, one process at a time) and reports into the Plugin Queue tab, so Cancel and Clear
  Completed work on exports too and the window stays usable. `ProcessingForm`'s transcript
  (`<<<START/WAIT/END/SUCCESS/FAILED/CANCELLED>>>` plus the helper's stderr) goes to the Log pane,
  and the `"Output n/m"` box still appears once the batch finishes.
* **Progress is per step, not per cent.** Neither omconvert nor cwa-convert prints a percentage —
  `ProcessingForm` shows an indeterminate marquee for exactly that reason. The queue's
  "Progress (%)" column therefore moves on completed steps (50 → 100 for an analysis that had to
  make a `.wav` first) unless the process speaks the plugin protocol (`p <n>` / `P:<n>` on stdout,
  `e <text>` / `E:<text>` for an error — `MainForm.parseMessage`, implemented in full). The shipped
  `run-omconvert.sh` does speak it.
* **"Export Resampled WAV…" writes `<name>.wav`.** `DoWavConvert` ignores its `ext` parameter, so
  upstream checks `<name>.resampled.wav` for overwrites and then writes `<name>.wav` — which
  silently replaces the cached `.wav` the Tools menu reuses. Reproduced, because it is what OMGUI
  does and the phase's goal is parity; `ExportArgumentTests.testWavOutputIsPlainWavNotResampledWav`
  pins it. Worth fixing upstream-side, not port-side.
* **The overwrite prompt has two buttons.** `MessageBoxEx` offers Yes/No/Cancel with Cancel
  default, but upstream only branches on `!= Yes`, so `UserPrompting.confirmOverwrite` maps onto
  the existing OK/Cancel sheet. No behaviour is lost.
* **`RunProcess2`'s output substitution is skipped for an empty name.** Upstream does
  `parameterString.Replace(outputName, "\"" + workingFolder + "\\" + outputName + "\"")`
  unconditionally; for OMConvert, whose page returns `""`, that produces `"<wf>\"""` — four quote
  characters and a broken argv. The port substitutes only a non-empty name.
  `PluginHostTests.testInvocationWithNoOutputName` covers it.
* **`numberOfInputFiles` falls back to 1.** `Int32.Parse` throws for a malformed value and
  `CreatePlugin` then returns `null`, losing the whole plugin; the port keeps the documented
  default.
* **The bundled OmConvertPlugin page is re-authored.** The descriptor is upstream's with
  `runFilePath` changed. The HTML keeps `fillValues()` and `func()` verbatim — so the
  `window.location.hash = "\"\"?\"\""` contract is unchanged — but the 2.6 MB of bootstrap, jQuery,
  p5 and PNGs behind a logo, a rule and one button are replaced with inline CSS. Every form field
  in the upstream page is commented out, so nothing functional was dropped. `run-omconvert.cmd`
  becomes `run-omconvert.sh`, which finds omconvert in `Contents/Helpers` (bundle) or
  `build/helpers` (checkout) and emits `p <n>` progress.
* **Helpers live in `Contents/Helpers`, not `Contents/Resources/Plugins/…`.** Upstream keeps
  `omconvert.exe` inside the plugin folder. A hardened-runtime `.app` will not execute a binary
  from `Resources`, and phase 4 already signs `Contents/Helpers/*` separately, so `HelperTools`
  resolves there (then `$OMGUI_HELPER_DIR`, `build/helpers` in any ancestor, then `PATH`).
* **`ClimbAx` is still special-cased** in `PluginHost.arguments`, because `NewArgumentCreator`
  hard-codes it. There is no ClimbAx plugin to ship; the branch is kept so a user's own copy works.

## Gaps

* **The data-viewer selection is reconstructed, not read.** `MainForm` takes
  `dataViewer.SelectionBeginBlock + OffsetBlocks`; the Mac data viewer publishes
  `AppModel.dataSelection` as a `ClosedRange<Date>`. `DataSelection.blocks(for:path:)` maps the
  range back to block numbers linearly across `OmReaderDataRange`'s start/end — exact for a `.CWA`
  written at a constant rate, approximate for a file with gaps or a rate change mid-recording. If
  the data viewer later exposes block numbers directly, use them and delete this. Verified against
  `cwa-convert`: `-blockstart` counts sectors from the start of the file, so the two header sectors
  are included, which is what `+ OffsetBlocks` produces.
* **`OmReader` was not extended.** Nothing in this phase needed a new field;
  `dataOffsetBlocks`/`dataNumBlocks`/`startTime`/`endTime` were enough. `Sources/OmApi/` and
  `Sources/OmGui/DataViewer/` are untouched.
* **`wantMetadata` is parsed but never populated.** `RunPluginForm.Go` passes
  `MetaDataTools.MetadataFromReader(file)` into the query for a plugin that asks for it.
  `PluginHost.formQuery` takes the pairs and is tested, but `AppModel.showPlugins` passes none —
  no shipped plugin sets the flag. Wire `FileMetadata`/`MetadataTools` in when one does.
* **`savedValuesFilePath` is parsed but not read or written.** `RunPluginForm.saveXmlProfile` is
  commented out upstream, and `loadXmlProfile` reads a file nothing ever writes; the port parses
  the field and stops there. Same for `PluginManager.LoadProfilePlugins`
  (`settings/pluginsProfile.profile`) — unused upstream.
* **Plugin icons.** `iconName` is parsed; `PluginsForm` upstream never shows the image either
  (`descriptionLabel` only), so nothing renders it.
* **One dialog per file for Raw CSV.** Upstream loops `ExportForm` over the selection; the port
  presents them one after another via `pendingRawCsv`. With a data-viewer selection active,
  upstream exports only `files[0]`; reproduced.
* **The "Complete" box names the source file for a plugin with no output file.** OMConvert declares
  none, so `ToolJob.finalPath` falls back to the input. Cosmetic.

## What a Windows-omconvert parity check would need

The Mac helpers are built from `Vendor/omconvert` and `Vendor/cwa-convert` with `-O2` and without
`-ffast-math`/`-march=native` (see `scripts/build-helpers.sh`); upstream ships `-O3 -ffast-math
-march=native` MSVC builds. To confirm the numbers agree:

1. A real `.cwa`, not the mock file — several days, an AX3 and an AX6, ideally one with a gap and
   one with a non-stationary calibration. The 19.5 s mock file exercises the plumbing, not the
   maths.
2. On Windows, run OMGUI v45's Tools menu over it and keep `.wav .resampled.csv .svm.csv .cut.csv
   .wtv.csv .sleep.csv`, plus a raw CSV per timestamp mode.
3. On macOS, run the same actions here. The command lines are in the Log pane and are asserted
   against the C# in `ExportArgumentTests`, so any difference is in the binary, not the arguments.
4. Compare: the `.wav` byte-for-byte (it is integer PCM plus a text header — only the header's
   `Time`/`Scale-n` lines should differ if anything does), and the CSVs column-wise with a
   tolerance. `-ffast-math` reorders the Butterworth filter and the auto-calibration regression, so
   small last-digit differences are expected in `.svm.csv` and `.cut.csv`; a difference in the
   *number of rows*, in wear-time/sleep classifications, or in the calibration coefficients printed
   on stderr is a real divergence.
5. `-calibrate 1` is the sensitive one: `omcalibrate.c` iterates a least-squares fit, so build flags
   show up there first. Run one comparison with `-calibrate 0` to separate a calibration difference
   from a resampling difference.

Nothing here is a blocker for the port; it is the check that would let the numbers be published as
equivalent.
