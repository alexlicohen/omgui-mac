# Phase 2 notes — the `OmGui` macOS app shell

Everything below was verified on this machine (macOS 26.6, Xcode 26.6, Swift 6.3, arm64) with
`MockBackend`. No hardware was available, so every device-side claim inherits the UNVERIFIED status
recorded in `refs/04-phase1-notes.md`.

Evidence for the acceptance criteria: `swift build -c release` clean; `swift test` = 166 tests, 0
failures (75 from phase 1, 91 new); `refs/screenshots/*.png` are captures of the live window taken
during a `--self-test` run of the release binary, and `/tmp` transcripts of that run show Download,
Record, Clear and Identify completing against the mock.

## Shape

```
Sources/OmGuiCore   headless view models (no AppKit/SwiftUI) — testable without a window
Sources/OmGui       the SwiftUI/AppKit shell
Tests/OmGuiTests    91 cases over OmGuiCore
```

`OmGuiCore` is a separate target only so `OmGuiTests` can link it; the executable target is still
`OmGui` at `Sources/OmGui`, product name `OmGui`, as `scripts/build-app.sh` expects.

## Decisions

**The main window is an `NSWindow` hosting the SwiftUI tree, not a SwiftUI `Window` scene.**
This is the one structural surprise of the phase. With `@main struct OmGuiApp: App` + a
`Window("OmGui", id: "main")` scene, the window never materialised: `NSApp.windows` stayed empty and
`NSApp.isActive` stayed false for the life of the process. Bisected to the point where the App
scene's *content* was irrelevant (a bare `Text` failed too) but instantiating `AppModel` before the
scene was built did not fail — i.e. the failure is in SwiftUI's scene machinery for this
non-bundled executable, not in our view code. A minimal reproduction with the same `.commands`,
`.defaultSize` and delegate shape works, so the trigger is something this app does that the
reduction does not; chasing it further was not worth the budget. `AppDelegate` now creates the
`NSWindow` itself, sets `NSHostingView(rootView: ContentView())`, and the `App` body is
`Settings { EmptyView() }` (an `App` must declare at least one scene; that one opens nothing).
Side benefits: the 1056x590 content size and the `MainForm` title are set exactly, with no
`.defaultSize` guesswork. Worth re-testing once the app is a signed bundle (phase 4) — it may just
work then, but there is no reason to go back.

**AppKit for the lists.** `devicesListView`, the two property grids and the three file lists are all
one `NSOutlineView`-backed `GroupedTableView`: column headers, grid lines, full-row multi-select and
WinForms-style group rows have no SwiftUI equivalent. Group rows arrive with a `nil` table column,
which is what made the first cut render blank headers. A column whose designer width is 0
(`File Location`) is created and then `isHidden`, which is the AppKit equivalent of upstream's
width-0 trick.

**Message boxes are `NSAlert` behind a `UserPrompting` protocol.** The flows take the protocol, so
the download/clear/record orchestration is exercised headlessly in tests with a scripted prompter,
and `--self-test` drives the real UI actions with an auto-answering one. Nothing about the flows is
duplicated for testing.

**`--self-test <dir>`** drives the real `AppModel` methods the toolbar buttons call, captures the
window (and any attached sheet) to PNG at each step and prints a transcript. It exists because
`screencapture` is unusable here: the terminal has no Screen Recording permission on this machine
(`screencapture -x` fails with `could not create image from display`), so the screenshots in
`refs/screenshots/` are `NSView.cacheDisplay` renders of the live window instead. Same pixels, no
TCC prompt.

## Deviations from OMGUI, and why

* **View ▸ Preview hides the preview, not the device list.** `MainForm.View_CheckChanged` sets
  `splitContainerPreview.Panel1Collapsed = !previewToolStripMenuItem.Checked`, and Panel1 holds
  `splitContainerDevices` — so in OMGUI, unchecking "Preview" hides the *device table*. That is
  plainly a mislabelled panel rather than an intent; the port hides the `dataViewer` pane.
* **Split proportions are initial, not exact.** The designer distances (218 / 747 / 89 / 738 / 562)
  are supplied as `idealHeight`/`idealWidth` to `VSplitView`/`HSplitView`, which weighs them against
  content size, so the preview strip opens taller than 89 px. Every splitter is draggable, and the
  device pane, the device/property split and the file/property split land within a few pixels.
* **Channel check-box order follows the designer, not `refs/03`.** `tableLayoutPanel1` adds them as
  X, Y, Z, ±1g, Light, Temp., Batt.%, Batt.V, Time, Gyro-X, Gyro-Y, Gyro-Z. `refs/03 §1` lists the
  three gyro boxes after Z; the designer is authoritative, so `refs/03` is wrong on this point.
  All twelve are present, X/Y/Z checked, as specified.
* **The "file already exists" prompt names the file.** Upstream's second overwrite prompt
  interpolates `downloadFilename` (the `.part` path) into the "File already exists:" message — a
  copy/paste bug. The port prints the path it is actually about to delete.
* **"Show All Files" stays enabled with no file selected.** `FilesResetToolStripButtons` disables
  every item in `toolStripFiles`, including the filter toggle, which would make the tab inert in
  this phase (every other button there is a phase-3 stub).
* **The status bar label is used.** `toolStripStatusLabelMain` is set to `""` in `MainForm` and
  never written again. Ours shows device/file counts and the running background operation; the
  spring label + progress slot layout is unchanged.
* **`recordSetup.xml` restores `Unpacked` to the unpacked check box.** Upstream's restore branch
  writes `checkBoxFlash.Checked = false` for a stored `Unpacked=False` — a typo that corrupts an
  unrelated field. Subject fields are saved but *not* restored, which is upstream's deliberate
  behaviour (the block is commented out in `DateRangeForm.cs`) and is reproduced.
* **Delay-day arithmetic is calendar-based.** `.NET`'s `DateTime` is zone-less, so
  `now.Date + TimeSpan.FromDays(n)` keeps the wall-clock time across a DST boundary. Adding
  `n * 86400` seconds to a `Date` does not; `setDelayDays` uses `Calendar.date(byAdding: .day…)`.
  Covered by `DateRangeTests`.
* **Working-folder templates.** `{MyDocuments}` → `~/Documents`, `{Desktop}` → `~/Desktop`,
  `{LocalApplicationData}` and `{ApplicationData}` → `~/Library/Application Support`,
  `{CommonApplicationData}` → `/Library/Application Support`. The .NET `SpecialFolder` values have
  no exact macOS equivalents; these are the closest native ones.
* **A macOS application menu exists** (About / Options… / Services / Hide / Quit) because AppKit
  requires one. File ▸ Exit and Help ▸ About… are kept as OMGUI has them.
* **Message strings use `\n`** rather than `\r\n`; the text is otherwise quoted verbatim from
  `MainForm.cs` (`FlowMessages` holds them all in one place, with the upstream member named in a
  comment).
* **LED circles are drawn, not shipped.** `Circle0.png`…`Circle7.png`/`Circle.png` are reproduced by
  `LedCircle.image(index:)` from the `OM_LED_STATE` colour list, so there is nothing to license or
  vendor. `Data.png` (index 9, file rows) is unused: this port never puts file rows in the device
  list.
* **Recent Folders is capped at five**, matching `MainForm.SetWorkingFolder`, and is rebuilt from
  `UserDefaults` each time the submenu opens.

## Not ported (Windows-only)

* **UAC elevation.** `Program.cs`'s `-uac:*` handling and the "Attempt to elevate user level?"
  prompt exist to avoid Windows drive-letter exhaustion. There are no drive letters here.
* **Firmware bootloading.** `MainForm.CheckFirmware` reads `firmware\bootload.ini` and runs a
  Windows bootloader executable; Clear and Record call it before doing anything. The port skips the
  check (Record and Clear proceed straight to the prompt). The *firmware warnings* named in
  `refs/04` risk 7 are implemented — they live in the Recording Settings dialog, not in
  `CheckFirmware`, and are covered by tests.
* `ShellContextMenu` (Explorer right-click), file drag-and-drop, and `Splash`.

## Stubbed for phase 3

* **The plot.** `Sources/OmGui/DataViewer/DataViewerView.swift` has the agreed signature
  (`init(source:channels:mode:selection:)`, `DataViewerSource.file(URL)/.device(OmDevice)`) and
  renders OMGUI's light-grey background plus the open source's name. Selecting one connected,
  non-downloading device or exactly one data file opens it, exactly as `dataViewer.Open` does;
  Zoom/Selection and all twelve channel check boxes already drive its inputs, and
  `DataChannel.penColor` carries the pen colours from `refs/03 §6`.
* **Exports** (Resampled WAV / Resampled CSV / Raw CSV) and **Tools** (SVM, Cut Points, Wear Time,
  Sleep Time, Plugins) are present in the menus and the Data Files toolbar, disabled, with the
  tooltip "available in phase 3". None of them has fake behaviour attached.
* **The plugin host.** `PluginQueue` is a real in-app model (enqueue / progress / cancel /
  clear-completed) wired to the Plugin Queue tab and its two toolbar buttons; phase 3 supplies the
  producer. Output Files lists whatever non-`.cwa` files appear in the workspace, so plugin output
  will show up without further work.

## OmApi gaps hit

No `OmApi` changes were needed; two things are worth knowing.

1. **`OmReader` does not expose the header rate/range byte.** `MetaDataTools.MetadataFromFile`
   reports `SamplingRate`/`SamplingRange` from header offset 36, and the file property grid and the
   filename template both want them. `FileMetadata` reads that single byte directly rather than
   widening `OmReader`. If phase 3 needs more header fields, add them to `OmReader` instead.
2. **`OmDevice.recordingDescription` is not the "Recording" column.** It maps an interval whose stop
   time has passed to `"Stopped"` (it is built on `isRecording`, which is what the *colour* uses),
   whereas `MainForm.DeviceListViewCreateItem` compares the packed times directly and still prints
   the dates. `DeviceRow.recordingText` implements the column; `recordingDescription` is left alone
   because the CLI uses it as a one-word status.

Also carried forward, unchanged from phase 1: `OmDevice.category` reproduces upstream's TODO that
collapses `New Data` into `Devices`, so the "New Data" group never appears (`strictCategory` is
still there if a later phase wants it). `MockBackend` cannot model the eject/re-insert a real
`FORMAT` causes, so the Clear flow's behaviour on hardware remains risk 4 in `refs/04`.

## Test coverage (91 new cases)

* `RecordingSettingsTests` — every `updateWarningMessages` flag and every `labelRateRangeSetting`
  branch as a separate vector (including the three AX6 firmware rules from `refs/04` risk 7), the
  battery-life and capacity estimators against the upstream formulas, the warning-box text format,
  and the accel/gyro encoding.
* `DateRangeTests` — start/delay/duration/end coupling, the roll-over and roll-under arithmetic of
  the three duration pickers, the +30 s rounding in the `Duration` setter, seconds clamping, and
  the DST case above.
* `WorkspaceTests` — data/output listing and filtering, `Size (MB)` to 2 dp, `dd/MM/yy HH:mm:ss`,
  the `{MyDocuments}`-style templates, and `FileMetadata` against a real mock-written CWA.
* `DeviceFlowTests` — download name resolution (template, metadata placeholders, refusal reasons),
  a full download to completion with the `.part` rename, both overwrite-prompt answers, cancel,
  the download log line, clear/stop/record commit sequences against `MockBackend`, the config log
  line, the failure-message wording, and the identify blink sequence.
* `SettingsAndRowTests` — Options persistence and the recent-folder rules, `recordSetup.xml`
  round-trip, every device-row cell text and colour, the group order, the six toolbar enable rules,
  and the plugin queue.
