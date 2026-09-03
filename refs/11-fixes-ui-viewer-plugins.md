# Deep-review fixes — viewer, plugin host, workspace

Findings from `refs/10-deep-review.md`: C18, C21, C23, C24, C25, C28 (part), C33, C34, C41, C42,
C43, U2, U5. Gate: `swift build -c release` clean, `swift test` 345 tests / 0 failures,
`.build/release/OmGui --mock --self-test` exit 0.

| Finding | Change | Where |
|---|---|---|
| C18 | `DataLevel.bucketLimit`; `grow` refuses past it and the block becomes a clock anomaly | `DataViewerLOD.swift` |
| C21 | Selection description and plugin `startTime`/`endTime` formatted in UTC | `DataSelection.swift`, `PluginDescriptor.swift` |
| C23 | ⌘A is nil-target `selectAll(_:)` down the responder chain | `OmGuiApp.swift` |
| C24 | `runFileIssue()` — confinement, executable bit, quarantine — refused before the spawn | `PluginDescriptor.swift`, `OmConvertJob.swift`, `ToolRunner.swift`, `PluginDialogs.swift` |
| C25/C41 | Host-contributed paths are argv entries; only the plugin page's text is ever split | `PluginDescriptor.swift` |
| C28 | `WorkspaceListing.lastFailure` + a notice above the file lists | `WorkspaceModel.swift`, `ContentView.swift` |
| C42 | Selection edges bisect the blocks' own timestamps | `DataSelection.swift` |
| C43 | `end`/`bounds` read under the lock | `DataViewerLOD.swift` |
| C33/C34/U5 | New tests (below); `SyntheticCwa` gained `clockJumpAfterBlock`/`jumpSeconds` | `Tests/OmGuiTests/` |
| U2 | Measured, no change — 0.08 ms a file | below |

## C18 — a level's growth is bounded by the bucket budget, not by the clock error

`DataLevel` now carries `bucketLimit`, fixed at construction. `grow(toBucket:)` returns false past
it, and `add` counts the block as a clock anomaly and abandons it. The base level's limit is
`max(initial, maximumBaseBuckets)` (262 144 buckets, 22 MB); each coarser level gets that divided by
its ratio to the base, so a level can never cost more than the ladder was chosen to allow. A detail
window keeps the default (`bucketLimit == bucketCount`, i.e. no growth) — it reads with
`restrictToBounds` and never grows anyway.

Refuse-and-count rather than clamp-into-the-last-bucket: a block stamped 2056 in a 2026 file is not
data at the end of the recording, and folding it into the final bucket would put a false envelope
there. The sub-zero case keeps upstream's fold-into-bucket-0 behaviour, because a backwards RTC is
usually a few seconds of overlap rather than a different decade.

A refused block no longer moves `loadedThrough` or `end` either. Without that the pyramid stayed
small but the plot's axis still stretched across thirty years and drew the whole recording into one
pixel column.

## C21 — one clock

`DataPlotView.formatter` was already `.gmt`; `DataSelection.description` and
`PluginSelection.timeString` were not. Everything the user reads about a selection is now on the
device's clock, which is the clock the `.CWA` stores (libomapi reads its wall-clock stamps with
`timegm`) and the one `-blockstart`/`-blockcount` already exported against. The old behaviour
described a UTC-5 selection five hours from the data it exported.

`ExportFlowTests.testTheSelectionDescriptionUsesOmguisDateFormatOnTheDevicesClock` used to build its
expectation with a local-zone formatter, so it passed either way; it now pins the literal string.

## C23 — ⌘A follows the first responder

The Edit menu's Select All had `target = self` and no `validateMenuItem(_:)`, so it fired whatever
had focus — including a text field in a sheet (the MOP's §9.4.2 step 4.1 types into the Session ID
box). It is now `NSResponder.selectAll(_:)` with a nil target, like Cut/Copy/Paste beside it:
`NSOutlineView` implements `selectAll(_:)`, so the device list still answers ⌘A while it has focus
and `GroupedTableView`'s binding pushes the ids into `selectedDeviceIds`; a text field selects its
own text; with nothing selectable focused AppKit greys the item out. `selectAllDevices` is gone.

The one behaviour deliberately lost: ⌘A with the *file* list focused now selects all files rather
than all devices. That is the macOS convention and the alternative is hijacking the key again.

## C24 — a plugin may only run a program inside its own folder

`PluginDescriptor.runFileIssue()` returns `.notSpecified`, `.outsideFolder`, `.missing`,
`.notExecutable` or `.quarantined`, each with a message that says what to do. `runFileURL` and
`htmlFileURL` are standardized, and confinement is a prefix compare after
`resolvingSymlinksInPath()` on both sides, so `../../../../../usr/bin/osascript` is visibly outside
the folder.

The check lands in two places: `PluginHost.invocation` stores the message in the new
`ToolInvocation.refusal`, and `ToolProcess.run` reports it instead of spawning — so a headless run
fails the queue row with the reason rather than a bare non-zero exit. `PluginsSheet` also disables
Run and shows the message, so the user sees it before the plugin's form opens.

Quarantine is only consulted for a plugin *outside* `Bundle.main.bundleURL`: a downloaded `.app`
carries `com.apple.quarantine` on everything inside it, and the bundled plugin has already been
through notarisation with the rest of the app. Code-signature validation is deliberately not
attempted — the shipped run file is `run-omconvert.sh`, and scripts are never signed, so a signature
check would refuse the app's own plugin while proving nothing about a shell script. The flag macOS
itself sets on downloaded content is the signal that carries information here.

## C25 / C41 — argv is built, never re-parsed

`PluginHost.arguments(fromFragment:…)` now returns the page's own parameter text only, and
`invocation(…)` builds the argv: the first `.cwa` as its own entry (except ClimbAx, upstream's one
exception), then the page's text split Windows-style, then the output name substituted *inside the
split entries*. No host-contributed path is ever quoted into a string and split again, so a file
name containing `"` is one argument and a working folder containing `"` keeps its directory.

The public shape is unchanged for the caller (`ToolActions.pluginFormSubmitted` still passes
`parameterString`/`outputName` through); what changed is that `parameterString` no longer has the
input path spliced into its front.

## C42 — selection edges come from the blocks' own timestamps

`DataSelection.blocks(for:path:)` bisects the data blocks on their timestamps (`BlockSeeker`), so a
recording with a gap in it maps the highlighted window to the blocks that actually cover it. Each
edge costs `log2(blocks)` header reads, with probes cached across the two edges: **0.2 ms over a
20 000-block file** (`SelectionBlockTests.testResolvingAnEdgeIsLogarithmic`), against a main-thread
budget of a dialog opening. The linear estimate survives as
`blocks(for:start:end:offsetBlocks:numBlocks:)` and is the fallback when the file will not seek.

On the fixture with an hour-long gap after block 49, the estimate puts the first block after the gap
forty blocks late; the bisection puts it at block 50.

## C43 — `end` under the lock

`end` is now `private var _end` with a locked accessor, and `bounds` takes the lock. Every other
shared field already did. `addLocked` writes `_end` directly (`NSLock` is not recursive).

## C28 — an unreadable working folder says so

`WorkspaceListing.contents(of:)` no longer swallows the error: it records
`WorkspaceListing.lastFailure` (folder + a message) and clears it on the next listing that succeeds.
`NSFileReadNoPermissionError` becomes "OmGui is not allowed to read <path>. Grant access in System
Settings > Privacy & Security > Files and Folders, or choose a different working folder";
a missing folder says so; anything else carries the Cocoa description. `ContentView` shows it above
the Data Files and Output Files lists, which is the only place the failure is visible — the default
workspace is `~/Documents`, and a TCC denial otherwise renders as an empty folder.

The `Info.plist` usage descriptions (the other half of C28) belong to another task.

## U2 — measured, and left on the main thread

`WorkspaceListingTests.testTheCostOfListingAWorkspaceOfLargeFiles` writes 25 × 16 MB `.cwa` files
and times `WorkspaceListing.dataFiles`:

```
PERF: listing 25 x 16 MB CWA files: 1.9 ms mean, 1.9 ms worst (0.08 ms a file)
```

The threshold in U2 was ~50 ms a file; the measurement is **600× under it**, so no background queue,
no probe cache keyed on path+size+mtime, and no coalescing of `onJobFinished` rescans. That is the
structure of the probe rather than luck: `OmReader.init` reads the header, the first block, seeks to
EOF and reads the last block — four reads, not a scan, whatever the file's size. Caveat: the files
are in the page cache (they were just written), so a cold workspace costs a few more random reads
per file; four seeks on the SSDs these machines have is still two orders of magnitude below the
threshold. Re-measure if the listing ever grows a per-file *scan*.

## Found while writing the C34 test — a one-bucket smear in the detail window

Ground-truthing the detail window (block `k` carries `x = k`, so a column's value names its block)
showed every 50 ms column carrying its neighbour's samples: `count` 10 or 11 instead of 5, and
`startTime` one bucket back. `DataLevel.bucket(for:)` floors `(time - start) / duration`, and at
epoch magnitudes one ulp is 2.4e-7 s, so a column boundary computed as `windowStart + n * duration`
lands a hair *below* the boundary it is, and `floor` answers the bucket before. It is invisible at
1 s buckets (integer offsets are exact) and structural below about 0.1 s.

`bucket(for:)` now snaps a time that is within a few ulps of a bucket's start onto that bucket, and
`aggregate` decides its exclusive end the same way. The pyramid's own tests are unchanged and still
pass; the detail window went from 10–11 samples a column to exactly 5.

## Tests

| File | Covers |
|---|---|
| `DataViewerClockTests` | C18, U5 — decades-ahead RTC (10 anomalies, pyramid stays 100 KB, axis unmoved), forward jump inside the budget (level grows, all 3 200 samples survive, envelopes exact), backwards jump (folded into bucket 0, nothing lost), `grow`'s own ceiling |
| `DataViewerDetailTests` | C34 — every detail column's min/max/count/startTime against the block it covers, plus the window's first and last column |
| `SelectionBlockTests` | C42 (gap file, fractional edge, clamping, bisection cost) and C21 (both formatters) |
| `ToolbarGatingTests` | C33 — a real downloading row from `DownloadFlow`: only Cancel and Identify live, and one downloading row gates a selection of otherwise-clearable rows |
| `WorkspaceListingTests` | C28 (unreadable folder, missing folder, and the failure clearing) and the U2 measurement |
| `PluginHostTests` (extended) | C24 (escape, missing, non-executable, quarantined, the shipped plugin passing, and the refusal reaching `ToolProcess`), C25/C41 (quote in a file name, quote in the working folder) |

`SyntheticCwa.write` gained `clockJumpAfterBlock`/`jumpSeconds` beside the existing
`gapAfterBlock`/`gapSeconds`: a gap moves the data, a jump moves the clock.

## Scope note

`ToolRunner.swift` is outside the files this task was given but is where a refused invocation has to
be stopped — six lines, before `Process` is created. `OmConvertJob.swift` gained
`ToolInvocation.refusal` (defaulted, so no caller changes).
