# Device-flow review fixes (refs/10 items C1, C2, C4, C5, C8-C12, C19, C20, C22, C32, C35, C40, U1, U3)

Range: this commit. Scope: `Sources/OmApi`, `Sources/OmGuiCore/{DeviceFlows,FileMetadata}.swift`,
`Sources/OmGui/{AppModel,ToolActions,ExportDialogs,SelfTest*}.swift`, `Sources/omgui-cli`, new tests.
The libomapi C findings, the notarization findings and the viewer/plugin findings are other commits.

Verified: `swift build -c release` clean (no warnings), `swift test` 363 tests / 0 failures,
`.build/release/OmGui --mock --self-test` exits 0 (21 CHECKs ok), `.build/release/OmGui --self-test`
exits 2 in 0.13 s, `omgui-cli clear --mock` with no target exits 1 and clears nothing.

## Fixed

**C1 — `--self-test` against real hardware.** `AppModel.start()` refuses before `api.startup()`
when `options.selfTestDirectory != nil` and the backend is not `MockBackend`
(`SelfTest.refuseNonMockBackend`, stderr + `exit(2)`); `SelfTest.run` keeps the same guard for any
other caller. Refusing rather than implying `--mock` because an operator who typed `--self-test` on
a machine with devices attached needs to be told, not silently given a different run.

**C2 — `DOWNLOAD-OK` after a failed rename.** `OmDevice.updateDownloadStatus` now performs the
`.part` → `.cwa` rename *before* publishing the status, and publishes `.error` (with
`downloadFailure` naming the rename) when `finishedDownloading()` returns nil. `finishedDownloading()`
verifies the moved file exists and records it in `lastDownloadedPath`. `AppModel.finishDownload`
logs `DOWNLOAD-OK` (and appends to `-downloadlog`) from that value; the `.error` branch logs
`DOWNLOAD-FAILED` and puts up "the device has NOT been downloaded -- do not clear it".

Note on the shape: an earlier attempt re-`stat`ed `plan.finalPath` in `finishDownload` instead, as
the report suggested. That is racy — the self-test reproduced it: a second download of the same
device answers its overwrite prompt and deletes the destination *before* the previous completion is
drained on the main actor, so the check fired on a download that had in fact landed. The
verification belongs on the thread that did the rename, which is where it now is.

**C4 — poll timer during Record/Clear/Stop.** `MainForm.BlockBackgroundTasks`/`EnableBackgroundTasks`
ported as `AppModel.blockBackgroundTasks()`/`enableBackgroundTasks()` + `backgroundTasksBlocked`,
checked at the top of `tick()`. `runInBackground` (the port's `ShowProgressWithBackground`, and the
only caller of Clear/Stop/Record) blocks the timer, `await`s `drainBackgroundPoll()` — upstream's
`while (backgroundWorkerUpdate.IsBusy) DoEvents()`, without blocking the actor the poll has to
finish on, 5 s cap — then runs the work and re-enables in the completion. Identify is driven by the
timer, so it is blocked by the same flag. Self-test asserts both edges around Clear.

**C5 — blocking `RATE` from the property grid.** `OmDevice` caches the accel config
(`cachedAccelConfig`), refreshed by `update()` on the poll thread and written through by
`setAccelConfig`/`clear`/`accelConfig()`, cleared on reconnect. `PropertyGrid.rows(for device:)`
reads the cache. Consequence: the two Sampling rows are absent until the device's first successful
poll, where before they were present and blocked the main thread for up to 2 s per selection change.
The read is deliberately outside upstream's `error` mask, so `validData` still means what it means
upstream.

**C11 — `syncTime`.** Ported both missing steps: the 1200 ms settle before the read-back, and the
"clock is ticking" verification (packed value must strictly increase and land within 5 s of now,
4 s budget). A dead RTC that latches the write now fails instead of passing. Waits live in
`SyncTimeTiming` (`.upstream` in the app, `.fast` in the harnesses) because upstream's timing is
~2.2 s per device per Record and the mock's clock is the host clock.

**C12 — `omgui-cli clear`.** Requires `--device ID` (repeatable) or `--all`; refuses when any target
is downloading (upstream's `EnsureNoSelectedDownloading`); asks `Wipe N device(s): ids -- n still
hold(s) data. Continue? [y/N]` unless `--yes`, defaulting to no on EOF. Usage text updated.

**C19 — firmware blacklist.** `FirmwareBlacklist` in `DeviceFlows.swift` ports `CheckFirmware`'s
INI parser (sections, `_version`, `=`/`:`, `;`/`#` comments), the `<serial prefix><firmware>` lookup
and the warning; `checkFirmware(_:blacklist:prompt:log:)` returns "stop, the user can press the
button again", called from `openRecordingSettings` (before the damaged-device loop) and from
`clear` (before the Wipe/Clear confirmation), as `MainForm.cs:1718` and `:2137` do.

Two deliberate deviations: the bootloader half is not ported (Windows `.cmd`), so the prompt says
the updater is not part of this port and asks whether to continue with the device (Cancel is the
default button, and Cancel stops the flow); and a device whose firmware version has not been read
yet is logged, not re-polled, because re-polling here is exactly the main-thread device I/O C5 is
about. Upstream's table ships as `FirmwareBlacklist.builtIn` (`CWA17_42`, latest `CWA17_45`) and is
replaced wholesale by a real `firmware/bootload.ini` found in the working directory, next to the
executable, or in the bundle's `Resources` — see Deferred.

**C20 — config-log append failure.** `commitRecording` checks every `DownloadLog.append` and warns
once, through the same `warnLogAppendFailed` the download log now uses.

**C22 — Export Raw CSV over several files.** The chained presentation moved out of the SwiftUI view
into `AppModel.closeExportSheet()`, which clears `exportSheet` and presents the next one from a
later main-loop turn (`DispatchQueue.main.async`), so `.sheet(item:)` never sees nil→new inside its
own teardown. Self-test leg copies a second `.cwa` into the workspace, selects both, and asserts the
sheet is nil immediately after the close and that the second file's dialog then arrives.

**C35 — existing destination at completion.** `finishedDownloading()` no longer deletes the
destination: as upstream's `File.Move`, the move fails and (via C2) the download is reported as
failed, leaving both the existing file and the `.part` intact. The overwrite question is still asked
once, at the start, by `DownloadFlow`.

**C40 — stale file property grid.** `selectionChanged()` clears `filePropertyRows` when a device
selection drops the file selection.

**U1 (adjudicated real) — `SETTINGS.INI` into a stale mount point.** `RecordFlow` re-resolves the
volume through `device.refreshInfo()` (`backend.info(deviceId).volumePath`) on *every* retry after
the commit, and `writeUnpackedSettings` only writes into a directory that contains `CWA-DATA.CWA`.
An empty leftover mount point now fails with "Failed to write unpacked configuration file." instead
of reporting success while the device records packed data.

**U3 (adjudicated real) — unreadable device data file.** `DownloadFlow.resolve` distinguishes
"`FileMetadata` will not open the file" from an identity mismatch (`unreadableFileError`), and
`DownloadFlow.run` warns with the file's path plus System Settings ▸ Privacy & Security ▸ Files and
Folders ▸ Removable Volumes, instead of MOP §9.4.4's "reconnect the device", which cannot fix it.

## Tests added

**C8 — erase levels.** `MockBackend` records every mutating call (`calls`, `callDescriptions`,
`eraseLevels(for:)`). `EraseLevelTests` pins the whole upstream `Clear` sequence
(`setSessionId(0)`, `setMetadata("")`, `setDelays(∞,∞)`, `setAccelConfig(100, 8)`, `eraseAndCommit`),
asserts `.wipe` for `wipe: true` and `.quickFormat` for `wipe: false` (inverting the ternary now
fails), that a commit is `.none` and keeps the data, and pins all four raw values to `OM_ERASE_*`.

**C9 — download identity refusals.** `DownloadVerificationTests` covers a file written by another
device, a session id changed on the device but not in the file, and `sessionId == .max`, each with
the `prompt.warn` text and the "0 devices downloading" summary, plus the matching device as a
control. Also C2/C35: a rename failure reports `.error`, keeps the existing file and the `.part`,
and leaves the device holding new data; and `lastDownloadedPath` is set on success and reset by the
next download.

**C10 — RecordFlow failures.** `FaultBackend` (a `DeviceBackend` decorator over `MockBackend` with
per-operation failure, a frozen clock and a volume-path override) drives every failure path:
downloading device (and that nothing is written to it), session id, metadata, sensor config, time
sync (both the unwritable clock and the dead RTC), always-interval, fixed interval, no drive, a
volume that is not the device, and a volume that moved during the commit; plus `SETTINGS.INI`
contents on an AX3, its absence on an AX6 and when Unpacked is off, the `AX3-CONFIG-ERROR` rows and
selection ordering.

**C32 — enum bridge and `LibOmapiBackend`.** `LibOmapiBridgeTests` pins `EraseLevel`,
`DownloadStatus`, `DeviceConnectionStatus` and `LedState` to the C constants in both directions, and
exercises all 22 `LibOmapiBackend` entry points against a library that was never started: each must
throw an `OmError` carrying the operation name rather than return uninitialised buffer contents.

Test-suite cost: 18 s → 36 s, almost all of it the ported `syncTime` waits (`.fast` still spends up
to a second per device waiting for a packed clock that only ticks once a second).

## Deferred

* **`Resources/firmware/bootload.ini` is not shipped.** `Resources/` belongs to another task in this
  round; `FirmwareBlacklist.builtIn` carries upstream's table meanwhile and
  `FirmwareBlacklist.searchPaths()` already looks in `Bundle.main.resourceURL/firmware/bootload.ini`,
  so dropping the file in (and copying it in `scripts/build-app.sh`) is all that remains.
* **C31 stands.** `AppModel` is still unreachable from XCTest, so C1's guard, C4's block/unblock,
  C2's logging branches, C19's call sites, C20 and C40 are covered by `--self-test` assertions and
  by unit tests of the pieces they call, not by XCTest of the orchestration itself.
* **C22's SwiftUI half is asserted at the model layer.** The self-test drives `closeExportSheet()`
  and asserts the deferral; it cannot click the sheet's Cancel button, so the `.sheet(item:)`
  re-presentation itself is still only checked by hand.
* **CLI "refuse while downloading"** cannot be exercised from a one-shot CLI process (nothing is
  downloading in a fresh invocation); the guard mirrors the GUI's, which is tested.
