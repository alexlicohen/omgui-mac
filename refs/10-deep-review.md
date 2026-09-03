# Deep code review (code-review-deep, 2026-09-02, range 60d26ba..HEAD)

**VERDICT: GO-with-fixes — do not ship the current `dist/` artifact.** 10 HIGH findings (2 destructive-data-loss, 1 crash-on-quit, 1 release-blocking notarization defect, 3 untested destructive paths) must land first; 5 findings need hand-adjudication before the gate closes.

Repo root: `/Users/alex/projects/omgui-mac` (paths below are relative to it). Range `60d26ba..HEAD`.
Tally = (real/refuted/dropped) across 2 adversarial verifiers.

Editorial merges: finders reported the devicefinder use-after-free twice (once MEDIUM, once HIGH) and `OmGetDataFilename` overflow twice — merged as C6 and C13, higher severity kept. 48 raw confirmed → 46 distinct.

---

## Confirmed (ranked HIGH → LOW)

### HIGH

**C1 — `--self-test` wipes real hardware when `--mock` is absent** (2/0/0)
`Sources/OmGuiCore/LaunchOptions.swift:69-76`; `Sources/OmGui/SelfTest.swift:194-196`
`--self-test` sets `selfTestDirectory` but never `useMock`, so `makeBackend()` (LaunchOptions.swift:102-120) returns `LibOmapiBackend`. `SelfTest.run` installs `ScriptedPrompter` (answerConfirm=true, abortRetryIgnore=.ignore) and drives `model.clear(shiftHeld: false)` = full NAND wipe on every attached device, auto-confirming its own "Wipe N device(s)?" and auto-ignoring "Device Possibly Damaged". Also rewrites session id, metadata, RATE and interval on every unit.
*Fix:* `guard model.api.backend is MockBackend` at the top of `SelfTest.run`, or make `--self-test` imply `useMock = true`.

**C2 — DOWNLOAD-OK logged when the `.part` → `.cwa` rename failed** (2/0/0)
`Sources/OmApi/OmDevice.swift:184, 422-441`; `Sources/OmGui/AppModel.swift:236-253`
`updateDownloadStatus` discards `finishedDownloading()`'s return (nil on `moveItem` throw) and unconditionally fires `.complete`. `finishDownload` never checks the final file exists — logs `DOWNLOAD-OK` to the pane and to the CSV. Operator then Clears the device on the strength of that record; only a `.part` exists. Upstream cannot produce this (`downloadComplete` fires only after `File.Move` returns).
*Fix:* propagate the nil as `.error`/`.renameFailed`; verify `fileExists(atPath: plan.finalPath.path)` before logging or appending.

**C3 — Unplug-during-download orphans the download thread; `OmShutdown` then frees state it is using** (2/0/0)
`Vendor/libomapi/src/omapi-download.c:323, 349-350`; `omapi-internal.c:217,226`; `omapi-main.c:130,135,141-142`
`OM_DEVICE_REMOVED` is set *before* `OmCancelDownload`, so `OmWaitForDownload`'s first `OmQueryDownload` returns `OM_E_INVALID_DEVICE` and the `thread_join` at :358 is never reached. `OmShutdown` applies the same CONNECTED guard, skips the cancel, then `free(record->state)` + `mutex_destroy` under a thread still `fread`ing the dying volume → use-after-free / double-`fclose` on Cmd-Q. Every unplug-during-download also leaks a joinable pthread.
*Fix:* cancel before setting REMOVED; make `OmShutdown`'s cancel+join unconditional.

**C4 — Poll timer not blocked during Record/Clear/Stop → concurrent serial commands collide** (2/0/0)
`Sources/OmGui/AppModel.swift:257-291, 570-595`
`runInBackground` never stops `refreshTimer` nor sets `pollInFlight`; `tick()` checks neither `progressSheet` nor a block flag. `OmPortAcquire` returns `OM_E_ACCESS_DENIED` immediately if the fd is open (omapi-internal.c:548-576). Result: `setInterval` fails after `setDelays` succeeded — device configured but **not recording** — or `update()` fails 3× and `reset()` sends `DEBUG -1` mid-configuration. Upstream's `BlockBackgroundTasks()` (MainForm.cs:3957-3976) exists for exactly this.
*Fix:* port `BlockBackgroundTasks`: suspend the timer, drain the in-flight poll, re-enable in the completion block.

**C5 — Property grid issues a blocking `RATE` command on the MainActor on every device-changed callback** (2/0/0)
`Sources/OmGuiCore/FileMetadata.swift:186`
`PropertyGrid.rows(for:)` calls `device.accelConfig()` — a 2000 ms-timeout CDC round trip — from `selectionChanged()` ← `rebuildRows()` ← `deviceChanged`. During a download that is ~100 blocking RATE commands per selected device from the main thread; during Record it opens the port from the MainActor while `RecordFlow` holds it, producing spurious "Failed to set session ID"/"Sensor config failed" or an uncommitted device. Upstream does no device I/O here.
*Fix:* cache accel config on `OmDevice`, refreshed by `update()` on the poll thread; grid reads the cached value.

**C6 — `DeviceAdded` frees `DeviceData` while its `kIOGeneralInterest` notification is armed → UAF on unplug** (2/0/0) *(merged duplicate)*
`Vendor/libomapi/src/omapi-devicefinder-mac.c:484 register / 531-535 free`
The notification is registered with `deviceData` as refCon before four steps that can `break`: `getUSBSerialNumber` (:492), `DeviceIdFromSerialNumber` (:499), `findMount` (:508), `findSerial` (:516). Bare `free()` on that path leaves the notification live on a freed pointer; `deviceData->notification` is never `IOObjectRelease`d and `deviceName` never `CFRelease`d. `findMount` gives up after ~8 s — the exact post-FORMAT / "Allow accessory to connect" case. On later unplug `DeviceNotification` `snprintf("%s")`s garbage pointers into `OmDeviceDiscovery(OM_DEVICE_REMOVED,…)`, then releases garbage. PATCHES.md §devicefinder records the `deviceName` leak on this path but not the dangling notification.
*Fix:* move `IOServiceAddInterestNotification` to after all lookups succeed; give the do/while an explicit failure epilogue releasing notification/deviceName/interface and freeing the three heap strings.

**C7 — `notarize.sh` staples the app *after* the DMG is built, so the shipped app has no ticket** (2/0/0)
`scripts/notarize.sh:39-45`
DMG is produced by `build-dmg.sh:35` from a pre-notarization copy and never rebuilt; `stapler staple "$APP"` at :45 only fixes the developer's `dist/` copy. Verified on the artifact: `xcrun stapler validate dist/OmGui.app` → "does not have a ticket stapled". A user who drags the app out of the DMG onto an offline/firewalled Mac gets "cannot be opened because Apple cannot check it for malicious software."
*Fix:* reorder — notarize+staple the .app, then build the DMG from the stapled bundle, then notarize+staple the DMG. Split into `notarize-app` / `notarize-dmg` and document the order.

**C8 — Erase level (wipe vs quick format) is never asserted; MockBackend collapses all three** (2/0/0) — MISSING TEST
`Sources/OmApi/OmDevice.swift:383`; `Sources/OmApi/MockBackend.swift:351-358`
`.delete`/`.quickFormat`/`.wipe` all take the same `writeDataFile(blocks: 0)` branch and record nothing; `grep -rn EraseLevel Tests/` is empty. Invert the ternary in `clear` and the suite stays green — `testQuickFormatAlsoErasesData` is literally identical to the wipe test. On hardware, QUICKFORMAT only rebuilds the filesystem, so a prior participant's accelerometry stays recoverable in NAND.
*Fix:* record `eraseLevels` in MockBackend; assert the upstream call sequence for `wipe:true/false` and pin raw values against `OM_ERASE_*`.

**C9 — Download filename verification: both refusal branches are dead in CI** (2/0/0) — MISSING TEST
`Sources/OmGuiCore/DeviceFlows.swift:129`
`DeviceFlowTests` covers success, no-data, recording and the two overwrite prompts — never a device-id/session-id mismatch. Flip either comparison to `==` and the suite passes while OMGUI writes a stale device's recording under another participant's `{DeviceId}_{SessionId}` filename. `MockBackend.setSessionId` updates the id without rewriting the header, so the mismatch is one line to produce.
*Fix:* assert `.failure("Download filename (session identifier not verified).")` and the corresponding `prompt.warn` + 0-devices summary; add the `sessionId == .max` case.

**C10 — RecordFlow's seven failure paths and the unpacked/SETTINGS.INI step are never executed** (2/0/0) — MISSING TEST
`Sources/OmGuiCore/DeviceFlows.swift:378`
Both callers assert `failures.isEmpty`; MockBackend has no fault injection, so no `AX3-CONFIG-ERROR` ever traverses the flow. The `settings.unpacked && !hasSyncGyro` branch (:414) — which writes `DATAMODE=20\r\n` to the device, without which the AX3 records packed data the pipeline cannot use — has zero coverage.
*Fix:* failing decorator over MockBackend for the four error strings + ordering; assert SETTINGS.INI contents on AX3 and absence on AX6.

### MEDIUM

**C11 — `syncTime()` drops upstream's 1200 ms settle and its "clock is ticking" verification** (2/0/0)
`Sources/OmApi/OmDevice.swift:349-369` — reads back milliseconds later, so a device with a dead RTC crystal that latches the write but does not tick passes; `RecordFlow` proceeds to `alwaysRecord()` and the study gets a week stamped with a frozen clock. Upstream (`OmDevice.cs:432-507`) sleeps 1200 ms then polls until the value strictly increases, failing after 4 s.
*Fix:* port both steps.

**C12 — `omgui-cli clear` wipes every attached device by default, no confirmation, no downloading guard** (2/0/0)
`Sources/omgui-cli/Commands.swift:290-306` with `Runner.swift:91-103` — empty `--device` means *all attached*; no `--yes`, no `isDownloading`/`hasData` check. Upstream gates every destructive path with `EnsureNoSelectedDownloading()` + an OK/Cancel box defaulting to Cancel.
*Fix:* require `--all` for an empty target, require `--yes`, skip downloading devices.

**C13 — `OmGetDataFilename` appends 13 bytes to buffers its own callers size at exactly `OM_MAX_PATH`** (2/0/0) *(merged duplicate)*
`Vendor/libomapi/src/omapi-download.c:146-159`, callers at :159, :208, :234, :391 — `device->root` can hold 255 chars, then `/CWA-DATA.CWA` + NUL is `strcat`'d into a 256-byte stack buffer. `omapi.h:927` documents the parameter as `OM_MAX_PATH`, so the API contract is itself wrong. The Swift seam already passes 512 (`LibOmapiBackend.swift:116`) — the hazard was noticed on one side only. Reachability is bounded by FAT label length, i.e. by hardware accident, not by any check.
*Fix:* bounded `OmGetDataFilenameN(id, buf, size)` built with `snprintf`; bump the four internal buffers meanwhile.

**C14 — `getUSBStringDescriptor`: unsigned `wLenDone == 0` → `count = 0x7FFFFFFF`, overruns a 128-byte heap buffer** (2/0/0)
`Vendor/libomapi/src/omapi-devicefinder-mac.c:247-254` — `(request.wLenDone - 1) / 2` on a UInt32 wraps when a device ACKs the control transfer with a zero-length descriptor (a re-enumerating AX3 right after FORMAT). Loop then writes 2.1 B entries into `malloc(128)`. The malloc is also unchecked.
*Fix:* `if (wLenDone < 2) return NULL;`, clamp count to 127, check malloc.

**C15 — `om.deviceRecords` published from the discovery thread, walked unlocked from main** (2/0/0)
`Vendor/libomapi/src/omapi-internal.c:165-177`; readers `omapi-main.c:188-199`, `omapi-internal.c:69-80` — plain store of the list head with no release barrier; `OmDevice()`, `OmGetDeviceIds()` and everything downstream walk it unlocked from `AppModel`'s 100 ms tick. On arm64 the head store can be visible before the field stores → a record whose `state`/`next` is pre-memset garbage.
*Fix:* acquire/release pair on the head (records are never removed), or a dedicated mutex.

**C16 — Serial port opened blocking with no VMIN/VTIME; `OmPortReadLine`'s timeout is unenforceable** (2/0/0)
`Vendor/libomapi/src/omapi-internal.c:440-457, 485-505` — `fcntl(fd, F_SETFL, 0)` clears `O_NDELAY`, and `c_cc[VMIN]/[VTIME]` are never set (upstream's `#warning` is still there). A wedged device makes `read()` block forever, so `OmCommand`'s 2000 ms timeout is never evaluated and `OmGetBatteryLevel` from the main-thread tick beachballs the UI. A yanked device instead busy-spins a full core with no sleep.
*Fix:* `VMIN=0, VTIME=1`; add a short `usleep` on the `c <= 0` path.

**C17 — `OmDeviceDiscoveryStop` can hang the quit path forever; leaks the notify port and iterator on restart** (2/0/0)
`Vendor/libomapi/src/omapi-devicefinder-mac.c:651-662, 588-603` — `gStarted` is signalled *before* `CFRunLoopRun()`, covered only by a `usleep(200ms)` HACK; a quick quit (which `--self-test` does by construction) can drop the `CFRunLoopStop` and block the unbounded `thread_join` forever. Stop also never calls `IONotificationPortDestroy`/`IOObjectRelease(gAddedIter)`, so each shutdown/start cycle leaks a mach port and arms a second matching notification.
*Fix:* signal from a `CFRunLoopPerformBlock` once the loop is running; loop stop-then-timed-join; release the port and iterator.

**C18 — A block with a far-future RTC makes `DataLevel.grow` allocate a bucket array proportional to the clock error** (2/0/0)
`Sources/OmGuiCore/DataViewerLOD.swift:111-119, 196-199` — the non-`restrictToBounds` path calls `grow(toBucket:)` with no ceiling. A block stamped 2063 against a 1-second base bucket asks for ~1.17e9 buckets ≈ 47 GB per Float array → the app is killed. The detail path already breaks out; the pyramid does not.
*Fix:* `guard bucket < bucketCount + maximumBaseBuckets else { anomalies += 1; break }`, mirroring the existing sub-zero handling.

**C19 — No firmware blacklist check before Record or Clear** (2/0/0)
`Sources/OmGuiCore/DeviceFlows.swift:302-435, 260-283`; `Sources/OmGui/AppModel.swift:511-538` — upstream calls `CheckFirmware` in both handlers and warns on e.g. CWA17_42 ("known to have a potential problem which can limit the recording duration"). No equivalent here and no `bootload.ini` in `Resources/`. A site still on V42 gets silently configured and truncated recordings.
*Fix:* ship `bootload.ini`, port the blacklist half (version-prefix lookup + warning) into `openRecordingSettings` and `clear`. The bootloader half is not needed.

**C20 — Config-log append failure is silently swallowed** (2/0/0)
`Sources/OmGui/AppModel.swift:552` — the `@discardableResult` from `DownloadLog.append` is dropped, so an unwritable `-configlog` path loses `AX3-CONFIG-OK/ERROR` rows with no indication. The download path in the same file (:247-251) *does* check and warn; upstream loops on a Retry/Cancel dialog (MainForm.cs:247-269).
*Fix:* check the result and reuse the download path's warning.

**C21 — Data-viewer selection times formatted in local TZ while the plot's clock is device-wall-time-as-UTC** (2/0/0)
`Sources/OmGuiCore/DataSelection.swift:54-59`; `Sources/OmGuiCore/PluginDescriptor.swift:151-156` — `DataPlotView.formatter` correctly sets `.gmt`; these two do not. On UTC-4 a 10:00–11:00 selection is described as "06:00:00 - 07:00:00" in the Export dialog and handed to plugins as such, while `-blockstart/-blockcount` (which *do* use `.gmt`) export the right window. Every displayed time is wrong; the data is right — the worst combination for provenance.
*Fix:* `formatter.timeZone = .gmt` in both, plus a test pinning them against `DataPlotView.timeString`.

**C22 — Export Raw CSV over a multi-file selection re-presents the sheet inside the dismissing update** (2/0/0)
`Sources/OmGui/ToolActions.swift:81` with `Sources/OmGui/ExportDialogs.swift:97-102` — `close()` dismisses, nils `exportSheet`, then synchronously assigns a new one, so `.sheet(item:)` sees nil→new during teardown. Selecting three `.cwa`s exports the first and silently drops the rest. `SelfTest+Tools.swift:89` clears `pendingRawCsv` right after the first dialog, so the chaining is untested.
*Fix:* defer with `DispatchQueue.main.async`; add a self-test leg asserting the second `sourceFile` arrives.

**C23 — ⌘A hard-bound to "Select All Devices" with an explicit target, hijacking text fields in every sheet** (2/0/0)
`Sources/OmGui/OmGuiApp.swift:178` — explicit `target = self` with no `validateMenuItem(_:)` anywhere in `Sources/`, so it fires regardless of first responder. In Recording Settings (MOP §9.4.2 step 4.1), ⌘A in the Session ID field selects every connected device instead of the text. Port-only regression — upstream's Ctrl+A cannot fire while the modal form owns the message loop.
*Fix:* nil-target `NSResponder.selectAll(_:)` on the outline view, or implement `validateMenuItem` returning false when a sheet is attached / an `NSText` is first responder.

**C24 — A `.plugin` can point `runFilePath` outside its folder; the binary runs with no containment or quarantine check** (2/0/0)
`Sources/OmGuiCore/PluginDescriptor.swift:34` — `folder.appendingPathComponent(runFilePath)` verbatim from XML → `ToolProcess`'s `executableURL`. `../../../../../usr/bin/osascript` plus an attacker-controlled `location.hash` (which becomes argv) spawns arbitrary code as the user. Because the child is spawned by the notarized app rather than via LaunchServices, `com.apple.quarantine` is never consulted and the child inherits OmGui's TCC responsibility.
*Fix:* reject a resolved run file that escapes `plugin.folder` (standardized prefix compare); require `isExecutableFile`; warn once on a quarantined folder outside the bundle.

**C25 — Output path is re-quoted then re-split, so a workspace name containing `"` yields the wrong path** (2/0/0)
`Sources/OmGuiCore/PluginDescriptor.swift:237-241` — `"/Users/x/my "pilot" data/out.csv"` re-parsed by `splitCommandLine` collapses to `/Users/x/my pilot data/out.csv`. Helper writes to a nonexistent directory, fails with a bare non-zero exit, and `finalPath` looks for a file that was never going to exist.
*Fix:* do the substitution on the already-split argv array instead of round-tripping a command-line string.

**C26 — `VERSION` interpolated unescaped into a `sed` replacement** (2/0/0)
`scripts/build-app.sh:72` — verified: `--version 1.0/beta` (or any tag like `release/1.2`, which `git describe` will emit) kills the build with an opaque sed error; `--version 'v1.0&rc1'` silently ships `CFBundleShortVersionString = v1.0@VERSION@rc1`, which passes `plutil -lint`. Same for `$BUILD_NUMBER`.
*Fix:* render with PlistBuddy on a copy; validate VERSION as numeric dot-separated up front.

**C27 — Shipped `CFBundleShortVersionString` is `v0.1.0`, which the app itself rejects** (2/0/0)
`Resources/Info.plist.in:17-18` — `build-app.sh:31` stamps `git describe` output verbatim; `AppInfo.isNumericVersion` (`Sources/OmGuiCore/AppInfo.swift:22-25`) rejects the leading `v` and falls back to hard-coded `1.0.0`. Title bar and About say V1.0.0; Get Info and the DMG say v0.1.0 — irreconcilable in a bug report, and `v0.1.0` violates Apple's format requirement.
*Fix:* strip the tag prefix in `build-app.sh:31` and fail the build on a non-numeric result.

**C28 — No Documents/Desktop/Downloads usage descriptions; default workspace is `~/Documents` with a swallowed listing failure** (2/0/0)
`Resources/Info.plist.in:29` — only `NSRemovableVolumesUsageDescription` exists (verified by grep). Non-sandboxed hardened-runtime app defaulting to `{MyDocuments}`, so the first refresh raises an unexplained TCC prompt; on Don't Allow, `WorkspaceListing.contents` (`Sources/OmGuiCore/WorkspaceModel.swift:63-66`) does `(try? …) ?? []` and the Data Files tab renders empty — indistinguishable from an empty folder, with no path back except System Settings.
*Fix:* add the three usage descriptions; surface `NSFileReadNoPermissionError` as a named message.

**C29 — DMG volume root is mode 0700 because `mktemp -d`'s dir is the `-srcfolder`** (2/0/0)
`scripts/build-dmg.sh:32-39` — verified `drwx------` on the mounted `/Volumes/OmGui`. Masked today only because macOS mounts images `noowners`; an MDM script using `hdiutil attach -owners on`, or a root mount handed to a non-root installer, sees an empty DMG.
*Fix:* `chmod 755 "$STAGE"` after mktemp; prefer `ditto` over `cp -R` for signed bundles.

**C30 — Signing identity picked by `grep | head -1` with a brittle sed** (2/0/0)
`scripts/build-app.sh:83-86` (identical code at `build-dmg.sh:43-45`) — a machine with two Developer IDs signs with whichever sorts first, and the two scripts resolve independently so app and DMG can carry different teams; `codesign --verify` still passes. If `security`'s output format shifts, `IDENTITY` becomes the whole line, the `-n` test passes, and codesign fails opaquely instead of falling back to ad-hoc.
*Fix:* `SIGN_IDENTITY` override + `awk` extraction + `^[A-F0-9]{40}$` assertion, shared via `scripts/lib-sign.sh`; assert `TeamIdentifier` after signing.

**C31 — The whole `OmGui` target is unreachable from XCTest** (2/0/0) — MISSING TEST
`Package.swift:65` — `executableTarget`, not a dependency of either test target; `grep -rn 'AppModel|ToolActions|OmGuiApp' Tests/` is empty. That is where destructive decisions are *sequenced*: `AppModel.clear` (:466-485) computes `wipe`, calls `ensureNoSelectedDownloading`, re-filters, then prompts. Move the confirm after `ClearFlow.perform`, or drop the guard on its result, and every device is wiped on Cancel with a green suite. Same for `finishDownload` (C2's owner).
*Fix:* move non-view orchestration into `OmGuiCore` (or an `OmGuiKit` target both depend on); first test = scripted `confirm -> false`, two devices with data, assert both still `hasData`.

**C32 — Swift shadow enums never pinned to the C header; `LibOmapiBackend` has zero tests** (2/0/0) — MISSING TEST
`Sources/OmApi/DeviceModels.swift:21` — `EraseLevel`/`DownloadStatus`/`DeviceConnectionStatus`/`LedState` are hand-written mirrors, and `eraseAndCommit` reconstructs the C enum from the Swift raw value. `COmApiLayoutTests` pins struct sizes but no enum. Insert one `OM_DOWNLOAD_*` upstream and the mock suite stays green while the real path maps "progress" to "complete" and renames a half-downloaded `.part`.
*Fix:* one function of `XCTAssertEqual(Swift.rawValue, OM_*.rawValue)` across all four enums.

**C33 — Toolbar gating test never uses a downloading row** (2/0/0) — MISSING TEST
`Tests/OmGuiTests/SettingsAndRowTests.swift:195` — every fixture row has `isDownloading == false`, so `cancel == true` is never asserted and the `downloading == 0` guard on Clear is unasserted. Remove `&& downloading == 0` and the suite stays green while Clear goes live mid-download. The harness already knows how to produce a downloading device (`DeviceFlowTests.swift:218-230`).
*Fix:* assert the full upstream row for a single downloading selection, plus the mixed downloading+idle case.

**C34 — Detail-window envelope values are never checked against ground truth** (2/0/0) — MISSING TEST
`Tests/OmGuiTests/DataViewerModelTests.swift:105` — asserts existence, duration, presence, `count <= 12` and that some pair differs; pins no value. The `restrictToBounds: true` skip-forward path (`DataViewerLOD.swift:186-199`) is unique to the detail window, and an off-by-one, a wrong `accelScale` or a whole-window shift would still pass. The pyramid path *is* properly ground-truthed — the detail path is checked only against itself.
*Fix:* `SyntheticCwa` with block k carrying `x: Int16(k)`; assert `max == min == Float(k)/256` per column and exact `startTime` stepping; add a mid-block lower bound.

### LOW

**C35 — `finishedDownloading()` deletes an existing destination `.cwa` at completion with no prompt** (2/0/0) — `Sources/OmApi/OmDevice.swift:427`. The overwrite prompt happens only at download *start*, so a file restored into the workspace mid-transfer is destroyed silently. Upstream's `File.Move` throws instead. *Fix:* only remove a file this download created; otherwise let the move fail and report it (see C2).

**C36 — Every attach/detach leaks serialNumber, serialDevice and (new in this patch) mountPath** (2/0/0) — `Vendor/libomapi/src/omapi-devicefinder-mac.c:129, 391-399`. ~1.2 KB per cycle, unbounded, on the app's hot path; PATCHES.md records the first two but not `mountPath`, which the patch introduced. Same free-list omission that makes C6 dangerous. *Fix:* free all three in `DeviceNotification` and in C6's new failure epilogue.

**C37 — Reader divides by zero for `numAxes == 0` and sample-rate codes 0-3** (2/0/0) — `Vendor/libomapi/src/omapi-reader.c:351+387, 409+467`. Finder built the sources and fed hand-made CWAs: arm64 UDIV returns 0 rather than trapping, so the observable effect is zero-duration blocks and a zero rate that `DataLevel.add`'s `guard interval > 0` silently drops — whole regions of a partially-corrupt file plot as missing with no diagnostic. Still UB. *Fix:* reject the block instead of producing a degenerate one.

**C38 — `OmCommand` dereferences `expected` before its own NULL check** (2/0/0) — `Vendor/libomapi/src/omapi-status.c:498` vs the contract at :530 and in `omapi.h`. Latent: no current caller passes NULL, but `OmCommand` is public API one thin Swift wrapper away. *Fix:* one-line guard.

**C39 — Four level-0 `OmLog` DEBUG traces reach the user-facing Log pane on every attach/detach** (2/0/0) — `Vendor/libomapi/src/omapi-internal.c:180, 198, 210, 231`. `om.debug` defaults to 0 so level-0 always fires, and `LibOmapiBackend.start()` deliberately routes the callback into the visible log (and into `--log-file` transcripts and self-test evidence). PATCHES.md claims nothing else in this file changed, so leaving them is a choice — but it is the only unfiltered upstream debug output on a user surface. *Fix:* raise to level 2 as a documented patch, or filter `"DEBUG: "` in the trampoline.

**C40 — Selecting a device clears the file selection but leaves the File property grid populated** (2/0/0) — `Sources/OmGui/AppModel.swift:317-331`. `filePropertyRows` is never cleared, so the previous file's Device/Session ID stays on screen looking like it belongs to the now-highlighted device row. Upstream clears it via the list-view selection cascade. *Fix:* clear `filePropertyRows` in `selectionChanged()`.

**C41 — A file name containing `"` splices extra argv entries into a plugin's command line** (2/0/0) — `Sources/OmGuiCore/PluginDescriptor.swift:210-218, 248-268`. Download-time names are sanitised; Finder renames and hand-copied files are not. argv injection into the plugin, not shell injection (no shell is involved), and upstream has the same flaw — but the port re-implements the splitting by hand and need not. *Fix:* keep input paths as already-split argv entries (same fix as C25).

**C42 — Selection→block conversion assumes a constant block rate across the file** (2/0/0) — `Sources/OmGuiCore/DataSelection.swift:26-51`. Linear interpolation between first and last block times; a recording with a battery gap shifts `-blockstart` by the whole gap, so the exported CSV covers a different window than the highlighted one. Upstream works natively in block-index space. The doc comment acknowledges the assumption; nothing detects violation. *Fix:* resolve both edges through the LOD's existing sparse seek index (`DataViewerLOD.swift:483`), falling back to the estimate.

**C43 — `DataViewerLOD.end`/`bounds` read from the main thread without the lock** (2/0/0) — `Sources/OmGuiCore/DataViewerLOD.swift:363, 411`. Every other shared field in the class is `lock.withLock`-wrapped, so this reads as oversight. TSan-reportable; practical effect on arm64 is a stale extent for one frame. *Fix:* private `end` + locked accessor.

**C44 — `notarize.sh`'s ad-hoc guard accepts any signing authority** (2/0/0) — `scripts/notarize.sh:29-32`. An Apple Development cert produces an `Authority=` line, passes, and is submitted — rejected by notarytool after the full upload-and-wait, with the script's own error text pointing at the wrong cause. *Fix:* match `^Authority=Developer ID Application:`; also assert `flags=…runtime`.

**C45 — Shipped binary carries an `LC_RPATH` into the build machine's Xcode toolchain** (2/0/0) — `scripts/build-app.sh:43-44`; verified `…/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx` in `dist/OmGui.app/Contents/MacOS/OmGui`. Nothing resolves through it today and library validation is on, so it is not an injection vector — but it leaks the builder's layout and becomes a launch failure on every user Mac the day any `@rpath`-relative Swift dylib enters the link, a failure no build-machine test reproduces. *Fix:* `install_name_tool -delete_rpath` before codesign; assert zero `Xcode.app` hits in `otool -l`.

**C46 — `REPO_ROOT` derived with an unguarded `cd`, so an exported `CDPATH` corrupts it** (2/0/0) — `scripts/build-app.sh:13`, and identically `build-dmg.sh:11`, `build-helpers.sh:15`, `notarize.sh:19`. Invoked as documented, `dirname` yields a relative path, so `cd scripts/..` consults CDPATH and echoes the resolved dir into the command substitution. Build then fails at :45 or writes `dist/`+`build/` into an unrelated tree. *Fix:* `CDPATH= cd -- …` in all four (and in `Resources/Plugins/OmConvertPlugin/run-omconvert.sh:14,21`).

---

## UNVERIFIED — hand-adjudicate

Each below split 1 real / 1 refuted across two adversarial verifiers. **This is not a clean bill.** A tie means the two verifiers disagreed on reachability or on whether upstream behaves the same way — the orchestrator must read the cited lines and decide. Treat these as open until someone has.

**U1 — `writeUnpackedSettings` can write SETTINGS.INI into a stale or foreign `/Volumes` directory and report success** — LOW — `Sources/OmGuiCore/DeviceFlows.swift:439-455` (1/1/0)
`devicePath` is captured pre-commit (:375) and the retry loop only tests `fileExists`. After `setInterval`/`alwaysRecord()` the unit re-enumerates and macOS may remount at `/Volumes/AX317_12345 1` while an empty original lingers — the write "succeeds" into a non-device directory and the device records packed, contradicting the operator's Unpacked selection. If the old path is fully gone, the loop burns 15 s and reports a config error on a device that *is* recording. Upstream has the same shape but Windows reuses the drive letter.
*Adjudication hinge:* whether macOS actually leaves a lingering empty mountpoint in this sequence. *Fix if real:* re-resolve the path post-commit via `backend.info(deviceId).volumePath` and verify `CWA-DATA.CWA` is present.

**U2 — Workspace refresh opens every candidate file through libomapi on the main thread; every finished job triggers a full rescan** — MEDIUM — `Sources/OmGuiCore/WorkspaceModel.swift:72-83` (1/1/0)
`dataFiles(in:showAll:readableOnly:)` does `try? OmReader(path:)` per entry (header + first block + seek-to-EOF + last block), called synchronously from `@MainActor AppModel.refreshFiles()` on startup, workspace change, `finishDownload`, Refresh, and `jobs.onJobFinished`. A 25-file 400 MB `~/Documents` workspace beachballs on every completed job; a 10-file SVM batch does it ten times.
*Adjudication hinge:* actual per-open cost on the real workspace (three seeks, so possibly fast enough to be invisible). Measure before spending on the fix. *Fix if real:* background queue + probe cache keyed on path+size+mtime + coalesce `onJobFinished`.

**U3 — An unreadable device data file reports "device identifier not verified — reconnect the device", which is exactly what a denied removable-volume prompt produces** — MEDIUM — `Sources/OmGuiCore/DeviceFlows.swift:108-133` (1/1/0)
`FileMetadata(path:)` returning nil (the only "could not open at all" signal) makes `fileDeviceIdString` nil, which falls through the mismatch branch. On a fresh Mac where the TCC prompt was declined, MOP §9.4.4 step 1 tells the site to reconnect the device, which can never fix it. Faithful port of MainForm.cs:814-816, but Windows cannot fail this way — Mac-only dead end with no MOP step.
*Adjudication hinge:* whether TCC denial actually surfaces here as a nil `FileMetadata` versus being caught earlier. *Fix if real:* distinct failure naming the file and pointing at Privacy & Security ▸ Files and Folders ▸ Removable Volumes.

**U4 — `notarize.sh`'s Gatekeeper check uses the installer assessment type on an app and never assesses the DMG** — LOW — `scripts/notarize.sh:48` (1/1/0)
`spctl -a -vv -t install "$APP"` applies the pkg/dmg rule set to a bundle (`-t exec` is the documented one). Both types return the same verdict on the current unnotarized build, so the mismatch is invisible today. The distributed artifact — `dist/OmGui-<version>.dmg` — is never assessed at all, and `stapler` is not error-checked (:42). Interacts directly with C7.
*Adjudication hinge:* cosmetic-vs-real is mostly moot once C7 is fixed; fold into that change. *Fix:* `-t exec` on the app, `-t open --context context:primary-signature` on the DMG, plus `stapler validate` on both as a hard failure.

**U5 — LOD clock-anomaly and level-growth paths are asserted only as "never happens"** — MEDIUM — `Sources/OmGuiCore/DataViewerLOD.swift:187` (1/1/0)
The only assertion anywhere is `XCTAssertEqual(lod.clockAnomalies, 0)` on a well-formed file, and `grow` is never entered by any fixture because `SyntheticCwa` always writes monotonic timestamps inside the header span. `mins`/`maxs` grow by `extra * DataSeries.count` while `counts` grows by `extra` — correct, but unverified. A mis-sized grow would index out of bounds only on a clock-jump file, i.e. only in the field.
*Adjudication hinge:* this is the test-coverage twin of confirmed C18, so it is probably worth doing regardless of the tie. *Fix:* add `clockJumpAfterBlock`/`jumpSeconds` to `SyntheticCwa`; assert both the negative-jump absorption (count conservation) and the forward-jump growth.

---

## Refuted (one line each)

1. **`LibOmapiBackend.info()` all-or-nothing** — refuted 2/0: partial-failure path not reachable as described; `_info` is re-read on the paths that matter.
2. **Unretained `self` pointer with no deinit / no cleanup on failed start** — refuted 2/0: the failed-`OmStartup` unwind does not leave the callbacks armed the way the claim requires.
3. **`OmApi`'s four callback properties unsynchronised; CLI assigns one after startup** — refuted 2/0: the CLI's assignment does not race a live discovery thread in the sequence described.
4. **Plugin saved values / `wantMetadata` parsed but never used** — refuted 2/0: not a defect in this range as characterised (feature-gap framing, not a regression).
5. **Plugin fragment percent-decoded twice** (`PluginDialogs.swift:146/163`) — refuted 2/0: the fragment does not arrive pre-decoded on the path claimed.
6. **Plugin fragment percent-decoded twice** (`PluginDialogs.swift:157`, second finder) — refuted 2/0: same claim, same refutation.
7. **Second overwrite prompt names a different path than upstream** — refuted 2/0: the port fixes an upstream bug; no defect, and the "record it in refs/09" ask is documentation, not a finding.
8. **Helper binaries signed with bare identifiers** — refuted 2/0: bare identifiers here carry no practical policy consequence; notarization and validation both accept.
9. **Helper/upstream-contract tests skip silently** — refuted 2/0: `XCTSkip` on absent helpers/`upstream/` is the intended local-dev behaviour; CI gating is a process ask, not a code defect.
10. **`AccelConfig.rateCommandArgument` dead code with a self-referential test** — refuted 2/0: the value is consistent with the encoding it documents; no divergence from `omapi-settings.c` as claimed.

---

## Caveats on this report

- **Finders miss things.** The clean-coverage notes are broad and well-grounded (upstream C# traced line-by-line for recording settings, toolbar gating, metadata encoding, export argument builders, filename templates; the vendored C probed empirically for struct layout, buffer bounds and CF ownership; the shipped `dist/` artifacts inspected for entitlements, sealing and deployment target) — but they are *absence of found defects*, not proof of absence. Explicitly **not reviewed in depth** by the dimension that covered the flows: DataViewer LOD/plot internals, plugin host and `OmConvertJob` command-line construction, AppKit split-geometry.
- **UNVERIFIED ≠ clean.** Five findings split their verifiers. None was dropped for lack of a verifier, but a tie is an unresolved disagreement and needs a human read of the cited lines.
- **Not exercised end-to-end:** the release scripts were never run through a real notarization submission — C7 is established from the artifact state (`stapler validate` on `dist/OmGui.app`) plus script ordering, not from an observed user-facing launch failure. The plugin path-traversal chain (C24) was traced, not exploited.
- **Duplicate reports merged** (C6, C13); severities kept at the higher of the two.

## Recommended gate

Ship-blocking: C1, C2, C3, C7 (+ U4 folded in), C8, C9, C10. Same-release: C4, C5, C6, C11, C12, C19, C20, C21. Everything else can queue. Adjudicate U1–U5 before signing off — U5 is worth doing regardless since it is the test-side twin of confirmed C18.
