# Second review fixes: flows, device state and the CLI

`refs/12-deep-review-2.md` findings H5, H6, M2–M7, L2–L4. The scripts/docs findings (H7, M8–M14,
L5) and the libomapi ones (H1–H4) belong to other tasks and are untouched here.

Owned: `Sources/OmApi`, `Sources/OmGuiCore`, `Sources/OmGui/AppModel.swift`, `Sources/omgui-cli`,
`Tests/`. Plus one line of `Package.swift` — `omgui-cli` now depends on `OmGuiCore`, which is what
"share the code" in M2/M3 requires.

## The shape of the fix

Three of these findings (H6, M2, M3) are the same defect: the CLI re-implemented a guard the GUI
already had, and the copy drifted. Two more (M7, L2) are guards that existed but nothing could
reach. So the fixes are one move, not eleven patches: **every guard now lives in `OmGuiCore` and
both front ends call it.**

`Sources/OmGuiCore/FlowGuards.swift` (new) holds

| type | replaces | finding |
|---|---|---|
| `SelfTestGuard` | the `api.backend is MockBackend` check inline in `AppModel.start` | L2 (C1) |
| `BackgroundTaskGate` | `AppModel.pollInFlight` + `backgroundTasksBlocked` + `drainBackgroundPoll` | H5, L2 (C4) |
| `ClearGuard` | nothing — the exclusion only existed inside `DeviceToolbarState` | H6 |
| `ConfigLog` | the `configLogFailed` loop inline in `commitRecording` | L2 (C20) |
| `DeviceFlowPreflight` | the `ensureNoSelectedDownloading` + `checkFirmware` pair at four call sites | L2 (C19), M3 |

`AppModel` keeps `backgroundTasksBlocked` as a computed property, because `SelfTest.swift` asserts
on it and that file belongs to another task.

## Per finding

**H5 — `drainBackgroundPoll` (`AppModel.runInBackground`).** The cap is now
`BackgroundTaskGate.defaultDrainTimeout` = 20 s, and a timeout is **fatal**: the sheet comes down,
`enableBackgroundTasks()` runs, the Log gets an `ERROR:` line and the operator gets
`FlowMessages.pollStillRunning`. `completion` is never called, so the flow does not run. 5 s was
shorter than the poll it had to drain — a first `update()` is up to seven serial commands at
libomapi's 2 s timeout, so it expired during ordinary polls and then started the flow anyway, which
is verbatim the C4 failure `blockBackgroundTasks` exists to prevent.

**H6 — `omgui-cli clear`.** `ClearGuard.isRecordingWithData` states the exclusion
`DeviceToolbarState.clear` makes (`clearable` counts `(data && stopped) || (!data && configured)`,
which leaves out a device recording *with* data), for a device and for a rendered row, so the CLI
and the toolbar cannot drift. `clear` refuses those devices by id before the confirmation, and
`--force` is the only way past. The narrower predicate is deliberate: mirroring `clearable == total`
literally would also refuse a blank never-configured device, which is a normal thing to clear from
a script and harmless.

**M2 — `omgui-cli download`.** Now calls `DownloadFlow.resolve`, so it gets the state guards, the
unreadable-file case and both identity comparisons from one place. Both holes are closed: the
`device.sessionId != .max` exemption (a failed SESSION read filed data under the *file's* session
id and printed `DOWNLOAD-OK`) and the unreadable-file case (neither comparison ran, so the file
landed as `NNNNN_0000000000.cwa`). `--force` still writes an unverifiable name — it goes through the
new `DownloadFlow.plan`, and only for `DownloadFlow.identityFailures`, never for "device is
recording" or "no data".

**M3 — the CLI never ran `checkFirmware`.** `record` and `clear` both call `Runner.preflight`,
which is `DeviceFlowPreflight` with a `CLIPrompter`. Without `--yes`/`--force` and without a
terminal, a blacklisted firmware refuses (exit 3) and says so on stderr; with `--yes` it warns and
carries on. Verified against a `firmware/bootload.ini` blacklisting the mock's own CWA17_48.

**M4 — a failed `syncTime` erased the device warning. The 1-of-2 claim is real; fixed.** Verified,
not just read: reverting the hunk in an isolated tree makes
`DeviceStateTests.testAFailedTimeSyncKeepsTheDeviceWarning` fail with `("none") is not equal to
("damaged")` on both failure paths (the write failing on every retry, and the tick check timing out
on a latched-but-frozen clock). The fix keeps `_warning` at entry and restores it on every failing
return; a *successful* sync still clears it.

This is a deliberate divergence from upstream, which sets `deviceWarning = 0` at entry
(`OmDevice.cs:437`, "reset warning as it was time-based anyway") and never restores it. Upstream can
afford that because its `SyncTime` almost always succeeds first try; the tick verification added in
the previous range makes `false` returns routine here, and `update()` re-derives the warning only in
its one-shot `!validData` branch, so nothing else would ever put it back. A failed sync leaves the
clock exactly as it was, so the DAMAGED?/DISCHARGED? finding still stands.

**M5 — one RATE timeout blanked the Sampling rows for the session.** The accel read is out of the
one-shot `!validData` block and now runs whenever `_accelConfig == nil || _accelConfigStale`. A
failed read keeps the last-good value and sets `accelConfigIsStale` (new, public), so the next poll
tries again; a settled cache still costs no round trips. `setAccelConfig` clears the flag — a write
the device accepted is as good as a read.

**M6 — `clear()` bypassed the cache-refreshing path.** It now writes through
`OmDevice.setAccelConfig`, the same call Record makes and the only writer that refreshes
`_accelConfig`. If any step of the clear fails, the cache is marked stale rather than left asserting
the operator's last request, so the next poll re-reads what the device actually holds. (The M6
scenario — every config write lands, `FORMAT WC` times out — used to leave the grid showing the old
50 Hz/±16 g while the hardware sat at the defaults.)

**M7 — `checkFirmware` silently skipped unknown versions.** It now takes an optional `readVersion`
(upstream's "Examining" pass, `MainForm.cs:1490-1520`), and whatever is still unknown afterwards is
collected and put to the operator as one question naming the ids; declining stops the flow. The CLI
passes a real reader (`refreshStatus()`), because it has no background poll to collide with; the GUI
passes none, because the poll thread owns device I/O and a blocking `ID` from the main actor is
C5 all over again — so in the GUI an unread version is a question rather than silence.

Divergence: upstream's modal is OK-only ("Problem examining N device(s) - firmware version not
checked.") and it carries on afterwards, because it has just re-polled and knows the read genuinely
failed. Here the version may simply not have been read yet, and the port cannot force the read, so
the operator gets the choice. Silently skipping — which made `guard !checkFirmware(…)` read as
enforced while it was not — is the one option that is not defensible.

**L2 — the guards were unreachable by any check.** Lifted into `OmGuiCore` as above and held by
`Tests/OmGuiTests/FlowGuardTests.swift`: the self-test backend refusal, both poll-gate conditions,
the drain timeout (including that the default outlasts a full poll), the Clear predicate against
`DeviceToolbarState`, the preflight's three refusals, and the config-log failure path. The report's
other suggestion — a `scripts/check.sh` — belongs to whoever owns `scripts/`; it is still worth
adding, because `--self-test` remains outside `swift test`.

**L3 — the post-clear line was assumed state.** New `OmDevice.refreshStatus()` drops `validData`
before a forced update, so the version/time/delays/session block is re-read rather than skipped
(`force` only bypasses the poll interval). `omgui-cli clear` uses it and now prints a genuine
read-back: session, recording state, whether the metadata is really empty, the accel config, and a
loud `STILL HOLDS DATA` if the erase did not take.

**L4 — the download `.error` alert.** The path line is only claimed when the plan is still in hand;
the reason is printed once. Before, an `.error` arriving after `downloadPaths` was cleared printed
the reason twice and named no file, on the one alert whose job is naming the file.

## Verification

Run in an isolated `git archive HEAD` tree with only this task's files copied in — the shared
checkout has another task's in-flight `Vendor/libomapi` work (and its own failing
`LibOmapiDownloadProtocolTests`, which is theirs, not a regression here).

- `swift build -c release` — clean.
- `swift test` — 383 tests, 0 failures (363 before; +20). The 4 skips are environment-only
  (`upstream/` is not in `git archive`, helper binaries not built in a scratch tree).
- `.build/release/OmGui --mock --self-test` — exit 0, every CHECK ok, including
  "the device poll is blocked while a foreground flow runs" / "enabled again afterwards".
- `swift run omgui-cli record --mock --device 1234 --session 5 --immediate` then
  `swift run omgui-cli clear --mock --all --yes` → exit 3,
  `ERROR 1 selected device(s) are recording and already hold data: 01234 …  Pass --force to erase
  them anyway.`; the same command with `--force` clears all three and prints the read-back line.
- `omgui-cli download` against a corrupted `CWA-DATA.CWA` → `ERROR 01234: Device data file could not
  be read.` (it used to download and mis-name it); with `--force`, a warning and the download.

## Not done, and why

- The GUI's `clear()` does **not** pass `refuseRecordingWithData`. `DeviceToolbarState.clear`
  already greys the button out for those devices, and adding a second refusal inside the flow would
  fire in `--self-test`'s select-all Clear, which another task owns. `FlowGuardTests` asserts the
  two predicates agree, which is what keeps that true.
- `refs/screenshots/self-test-transcript.txt` is not re-recorded here (M14, another task). This
  change adds Log lines — `Clear not started:` / `Record not started:` on a refusal — and, when a
  firmware version has not been read, one extra confirm to the prompt transcript.
