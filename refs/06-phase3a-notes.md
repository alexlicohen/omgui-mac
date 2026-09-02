# Phase 3a notes — the DataViewer plot

Verified on this machine (macOS 26.6, Xcode 26.6, Swift 6.3, arm64) against `MockBackend` and
synthetic `.CWA` fixtures. No hardware, so the device-side claims inherit the UNVERIFIED status in
`refs/04-phase1-notes.md`.

Spec: `upstream/openmovement/Software/OM/omgui/DataViewer.cs` + `.Designer.cs`, and
`omapinet/OmReader.cs`. Every deviation is listed in §2 — none of them is accidental.

```
Sources/OmGuiCore/DataViewerLOD.swift     the pyramid: series, buckets, levels, aggregation
Sources/OmGuiCore/DataViewerModel.swift   the incremental load, progress, detail windows
Sources/OmGuiCore/DataViewerAxis.swift    time↔pixel, zoom and selection arithmetic
Sources/OmGui/DataViewer/DataPlotView.swift       the NSView: CoreGraphics, mouse, cursors
Sources/OmGui/DataViewer/DataViewerView.swift     the phase-2 signature, colours, SwiftUI host
Sources/OmGui/DataViewer/DataViewerSelfTest.swift the --self-test leg and its fixture generator
```

## 1. How the level of detail works

`DataViewer.cs` keeps up to 100 000 *decoded blocks* in an LRU cache (`DataBlockCache`, ~1.4 KB of
`Sample` structs each) and a `BackgroundWorker` fetches only the blocks that land under a pixel, in
passes of stride 64, 32, … 1. Whatever is cached when a repaint happens is what gets drawn, and
`GetAggregate` substitutes the nearest cached block (returning a `tolerance`) for the ones that are
not. The picture is therefore an interpolation that converges as the worker runs.

This port inverts that. One sequential pass folds **every** block into fixed-width time buckets and
nothing keeps samples:

* **Series** (`DataSeries`): X, Y, Z in g; gyro X/Y/Z in dps; light in raw 10-bit counts;
  temperature in °C; battery in % and in mV. `±1g` and `Time` are not series — see §2.3.
* **Buckets** hold a min/max envelope per series plus a sample count, stored as flat `[Float]` of
  `buckets × 10`: 84 bytes a bucket, contiguous.
* **Levels** are 1 s → 10 s → 1 min → 10 min → 1 h, each folded from the one below
  (`DataLevel.rebuild`) over just the bucket range the last batch touched. Coarser levels add ~12 %.
* **The base bucket is chosen from a ladder** (`1, 2, 5, 10, 30, 60, 120, 300, 600, 1800, 3600 s`)
  so the base level never exceeds 262 144 buckets. Memory is bounded by that budget, not by the
  file: 1 s for a day (86 400 buckets, 7.7 MB), 5 s for a week (10 MB), 10 s for a month, 300 s for
  a year. This is the one design choice that makes a 500 MB file behave the same as a 5 MB one.
* **A block is split at bucket boundaries.** Sample times inside a block are evenly spaced, so the
  split index is arithmetic; a test asserts that every sample lands in exactly one bucket.
  Per-block scalars (light, temperature, battery) widen every bucket the block touches.
* **Below the base bucket** — a zoom past ~800 × baseBucket seconds — `DataViewerModel.requestDetail`
  reads that window back off disk on its own queue into a `DataDetailWindow`, which is just a finer
  `DataLevel`, so the drawing code is identical at every zoom. The read is bounded by construction:
  at the zoom where it triggers, the visible window is minutes long (a few thousand blocks, tens of
  milliseconds). A sparse seek index (`(time, block)` every 64 blocks, built during the load) turns
  the window's start time into a block number for `OmReaderDataBlockSeek`.
* **Empty buckets are "no data".** That covers both a real hole in the recording and a region the
  load has not reached, and both draw as OMGUI's LightGray/Gray hatch — so the plot is honest while
  it fills in, left to right, and exact once the pass ends.
* **Threading.** The loader folds 256 blocks per lock acquisition (~1 ms) and publishes progress
  every 100 ms; the plot reads under the same lock. Aggregation for a redraw touches at most
  `ratio` (≤ 10) buckets per pixel column whatever the file length.

### Measured

Release build, this machine:

| | |
|---|---|
| 24 h AX6, 105 MB, 216 000 blocks | LOD in **0.63 s**, 7.7 MB of buckets |
| 7 days at 100 Hz, **369 MB, 756 000 blocks** | **LOD in 2.30 s**, base bucket 5 s, **10 MB** of buckets |
| 1000-column full-extent aggregate over that week | **0.02 ms** (2000 columns over the day: 0.06 ms) |
| Full plot recompose, 959 pt wide | 3.0–4.5 ms mean at 40 pt high, 3.7 ms worst at 460 pt |
| Cursor move (cached bitmap + overlays) | 0.3 ms |

Debug builds are ~3× slower on the load and ~200× on the aggregation (no inlining, live bounds checks); the perf test's bound is set for those. "Without
dropping frames" above means: the whole-file redraw path is 3–4 ms against a 16.7 ms frame, measured
by `DataPlotView.measureRedraw()` inside the real running app, 20 recompositions per zoom level, at
full extent / 1 h / 1 min on a two-day file — printed by `--self-test`.

## 2. Deviations from `DataViewer.cs`

1. **The x axis is wall-clock time, not block index.** Upstream works in `firstBlock`/`numBlocks`
   and converts with `BlockAtPoint`/`PointForBlock`. Two reasons to change it: the phase-2 preview
   signature already publishes the selection as a `ClosedRange<Date>`, and a time axis draws a
   recording's gaps at their true width where block space hides them (a device that stopped for a
   day is one pixel wide in block space). Consequence: `DataSelection` (phase 3b) converts the date
   range back to block numbers for `cwa-convert -blockstart`, which is exactly what upstream's
   `SelectionBeginBlock + OffsetBlocks` produced.
2. **The load is exhaustive, not opportunistic.** No `tolerance`, no nearest-cached-block
   substitution: a column either has data or is drawn as missing.
3. **`±1g` draws only the two dotted guide lines.** `OnPaint` has `bool displayAccel = false;`
   hard-wired, so `penDataAccel` (Black) is never used and no SVM trace is drawn anywhere in OMGUI.
   `refs/03 §6` calls the channel "±1g/SVM"; the SVM half of that name does not exist in the code.
   The `Black` colour is kept on the channel so nothing downstream changes.
4. **The temperature band's sign is corrected.** Upstream computes
   `height = -0.02f * (Max.Temp - Min.Temp) / 1000` and then reuses the light/battery formula, which
   draws the band mirrored about its minimum (light and battery, with positive heights, are right).
   Identical for a single-valued column, visibly wrong for a column spanning a temperature change.
   The scale itself is unchanged: 0–50 °C over the plot height.
5. **Zoom gestures.** Upstream: left click zooms in ×2 at the point, right click zooms out ×2,
   double-click *inside a selection* zooms to it, and there is no reset. All of that is here. Two
   additions the brief asked for: a **left-drag rubber band** zooms to the band (upstream ignores a
   drag in Zoom mode entirely), and a **double-click away from a selection** goes to the full
   extent.
6. **No zoom animation.** `StartAnimation`/`timerAnimate` interpolate `firstBlock`/`numBlocks` over
   ~1/3 s; here a zoom snaps. The animation existed to cover a cache that was still refilling; the
   pyramid is already loaded. It would be a small addition to `DataTimeAxis` if it is wanted for
   fidelity.
7. **Cursors.** `Cursors.IBeam` → `NSCursor.iBeam`; `SizeWE` → `.resizeLeftRight`; `SizeAll` →
   `.openHand` (macOS has no move cursor); the embedded `Resources.zoom` bitmap → `.crosshair`
   (macOS has no public zoom cursor).
8. **Modifier keys.** Upstream shows per-channel values on **Ctrl** and block/sequence detail on
   **Shift**. Ctrl-click is a right click on macOS, so values are on **Option**; Shift stays, but
   reports the column's sample count and span rather than sequence/block/file-offset, which are not
   meaningful on a time axis.
9. **The dead `hScrollBar` is not reproduced.** The designer docks a 16 px scroll bar inside
   `graphPanel` with `Maximum = 0`, `LargeChange = 0` and an empty `Scroll` handler. The plot is
   16 px taller here.
10. **Label text.** `SelectionDescription` concatenates a `DateTime` with the current culture's
    default format; both the cursor and the selection labels here use `TimeString`'s
    `yyyy-MM-dd HH:mm:ss.000`, formatted in UTC — the CWA stores wall-clock time, so this shows the
    device's own clock, which is what OMGUI's zone-less `DateTime` also shows.
11. **The download-progress wash is implemented but not reachable by clicking.** The code is
    commented out upstream; this port draws it from that code and `refs/03 §6` (green 0x66 →
    white 0xCC at 0.3 → green 0x66 over the downloaded fraction, DarkGray 0x33 → WhiteSmoke 0x66 →
    DarkGray 0x33 over the rest, both vertical). **`AppModel.download()` sets
    `dataViewerSource = nil`**, so in this port a download closes the preview and the wash never
    shows. Deleting that one line (AppModel is owned by another task this phase) restores it;
    `--self-test` captures the overlay against a genuinely downloading device via a hook, and
    `refs/screenshots/14-viewer-download.png` is that capture.
12. **Gyro channels are simply not drawn when a file has no gyro.** Upstream *hides* the three
    check boxes (`Refresh()` toggles their `Visible` from `DataBlockCache.HasGyro`). The check boxes
    live in `ContentView`'s options box in this port, which phase 3a does not own;
    `DataViewerModel.hasGyro` is published for whoever wires that up.
13. **A device is previewed from its mounted `CWA-DATA.CWA`.** `omapinet`'s `OmReader.Open(deviceId)`
    calls `OmReaderOpenDeviceData`, which the vendored libomapi does not export. Same bytes.

## 3. `OmReader` changes

`nextBlock()` built one `Date` per sample, and each of those ran a `Calendar` conversion (193 ns
measured) on top of the `gmtime_r` `OmReaderTimestamp` already does. A week of 100 Hz data is 60
million samples.

* **`BlockSummary` + `nextSummary()`** — a block's header values and its two end timestamps, no
  sample decode on the Swift side.
* **`withNextBlock(_:)`** — the same plus libomapi's own decoded buffer, handed over without a copy.
  This is what the LOD builder uses.
* **`summaries(fromBlock:count:)`** — seek straight into a block range.
* **`epochSeconds` / `daysFromCivil`** — `timegm`'s civil-days algorithm in integer arithmetic:
  3.7 ns per conversion against 193 ns, and equal to `Calendar` for every date `OM_DATETIME` can
  hold (asserted across 2000–2063). `nextBlock()` uses it too, so the old path got faster without
  changing.
* **`sampleRateCode` / `sampleRate` / `readerSampleRate`** — `OM_VALUE_SAMPLERATE` returns the raw
  `@24` byte; `sampleRate` decodes the true Hz, `readerSampleRate` the *integer* form
  `omapi-reader.c` times blocks with (see §4.2).

`OmReaderTimestamp(i)` is `blockStart + i * (blockEnd - blockStart) / sampleCount`, so interpolating
in Swift from the two ends is the same arithmetic to within one 1/65536 s tick — asserted per sample
in `Tests/OmApiTests/OmReaderFastPathTests.swift`.

Measured, release, 24 h AX6 (216 000 blocks, 105 MB): `nextBlock()` 0.80 s, `nextSummary()` 0.51 s,
`withNextBlock` plus a full accelerometer envelope 0.56 s.

## 4. Real-hardware risks

1. **A device clock that goes backwards mid-file.** The pyramid's span comes from the header's
   first/last block times (which libomapi derives by reading those blocks). Samples that land before
   the start are folded into the first bucket and counted in `DataViewerLOD.clockAnomalies`; blocks
   past the end grow the level. Upstream is immune to this because block space has no clock. A real
   file with a large backwards jump will therefore show a smeared first bucket where OMGUI would
   show a discontinuity. `clockAnomalies` is the signal to watch when hardware files arrive; if it
   is ever non-zero in practice, the fix is a second pyramid segment rather than clamping.
2. **12.5 Hz and 6.25 Hz timelines are 4 % long.** `omapi-reader.c` computes
   `sampleRate = 3200 / (1 << (15 - (code & 0x0f)))` in integer arithmetic, so 12.5 → 12 and
   6.25 → 6 (its own TODO). Every block timestamp it returns is stretched to match, and OMGUI plots
   the same stretched timeline. This port deliberately keeps libomapi's numbers rather than
   silently disagreeing with the rest of the toolchain; `readerSampleRate` documents it and a test
   pins it. Anything that converts a *selection* to a wall-clock time on a 12.5 Hz recording
   inherits the 4 %.
3. **Packed 10-bit AX3 data** (`numAxesBPS & 0x0f == 0`, 120 samples of 4 bytes) is unpacked by
   libomapi into the same `short*` buffer, so the LOD path never sees the difference. Untested
   against a real packed file — `CwaWriter` only writes the 16-bit form.
4. **A device file being written while it is previewed.** `refreshIfChanged()` re-opens on a size or
   mtime change (a 0.25 s tick while a device is the source). A torn final block fails libomapi's
   checksum and is skipped, so it shows as missing data until the next refresh. Reloading is a full
   re-read; for a device's own file (capacity-bounded) that is cheap, but it is a re-read, not an
   append.
5. **Header times that are absent or wrong.** `startTime`/`endTime` of `0`/`-1` fall back to the
   first block's time plus `dataNumBlocks × blockDuration`. A file whose header claims a far larger
   range than it holds gets a coarser base bucket than it needs — harmless.
6. **Mixed-axis files.** `hasGyro` is a property of the whole file, as it is upstream
   (`DataBlockCache.HasGyro` is OR-ed across blocks). A file with both 3-axis and 6-axis blocks
   would report gyro and draw zeros for the accel-only stretches.
7. **Very large files still hold their pyramid in memory** — bounded (10 MB for a week, ~24 MB for a
   year) but resident for as long as the preview is open. `close()` drops it.

## 5. What `--self-test` covers

`OmGui --mock --self-test` (no arguments needed any more; with none it runs entirely in
`$TMPDIR/omgui-self-test`, with its own workspace and a mock root that is reset each run — the state
a previous run persisted would otherwise leave every device cleared and the Download leg with
nothing to download).

The viewer leg writes a two-day 25 Hz recording (day/night light, drifting temperature, draining
battery, quiet nights, and a twenty-minute hole), opens it by selecting the file, and then sends
real `NSEvent`s into `DataPlotView`: rubber-band zoom, click zoom-in, right-click zoom-out, eight
more zoom-ins until the detail window takes over, double-click reset, a Selection-mode drag, a
marker drag, and a right click to clear. It asserts the `selection` binding against the dragged
pixels (matched to 0.000 s), previews a mock device from its own `CWA-DATA.CWA`, and captures the
download wash over a live download. Screenshots: `refs/screenshots/14-viewer-*.png`.

## 6. Left for later

* The zoom animation (§2.6) and the gyro check-box visibility (§2.12).
* `AppModel.download()` clearing the preview (§2.11) — one line, in another task's file.
* A `DataViewerLOD` that survives `close()`/re-open of the same path, so re-selecting a file does
  not re-read it. The load is fast enough that this has not been worth the invalidation logic.
