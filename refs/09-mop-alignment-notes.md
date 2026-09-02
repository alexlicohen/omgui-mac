# Phase 4 notes — matching the ARIA MOP's OMGUI

Spec: `refs/08-aria-mop-omgui-steps.md`. The upstream checkout in `upstream/openmovement` is
`AssemblyVersion("1.0.0.45")` (`omgui/Properties/AssemblyInfo.cs:35`) — the same build the MOP's
screenshots are of — so where the source and the MOP's description of a screenshot disagree, the
source is the better witness to what V1.0.0.45 drew, not a rival to it. Each disagreement is
recorded below.

## What changed

| refs/08 | Change | Where |
|---|---|---|
| 1 | One group header, "Default"; rows sorted by the Device column | `DeviceGroup`, `ContentView.deviceSections`, `AppModel.rebuildRows` |
| 2 | Icons on all six device-toolbar buttons and all six Data Files buttons | `ToolbarIcon`, `ToolbarButton` |
| 3 | Title `Open Movement [V<version>] - <workspace>` | `AppInfo`, `AppModel.setWorkingFolder` |
| 4 | `panelBottom` layout: yellow WARNINGS box left, check boxes + OK/Cancel right | `RecordingSettingsView.bottomBar` |
| 5 | A fresh workspace opens at 100 Hz / ±16 g / gyro off / Immediately | `RecordingSettings.applyInitialProfile`, `AppModel.openRecordingSettings`, `AboutView.profileNote` |
| 6 | (already correct) Record disabled when the selection has data | now covered by a mock device and a test |
| 7 | (already correct) workspace defaults to `{MyDocuments}` | now covered by a test |
| 8 | `Recording configured on <id>: session <n>, <yyyy-MM-dd HH:mm:ss>` in the Log and status bar | `RecordFlow.confirmationLine`, `AppModel.commitRecording` |
| 9 | Mock devices 6036222/6036223/6036224; Device column widened to fit 7 digits | `MockDeviceCatalog`, `LaunchOptions.makeBackend`, `DeviceColumns` |
| 10 | Stop → Download → select → Export ▸ Raw CSV → Output Files, driven end to end | `--self-test`, `docs/SOP-mac.md` §9.4.4 |

## The "Default" group: source vs screenshot

`DeviceListView()` *does* register nine groups — `groupOther` "Devices" … `groupFile` "Files" —
with `Groups.AddRange(...)` at the end of its constructor. But `MainForm` never puts an item in one:
both places that would do it carry the assignment commented out, with the note *"TS - Don't need this
anymore because there aren't groups in one list view but a list view each"*
(`MainForm.cs:367` in `DeviceListViewItemUpdate`, `MainForm.cs:397` in `DeviceListViewCreateItem`).
Every `ListViewItem` therefore keeps its default group, which a WinForms `ListView` labels
**"Default"** — the header in the MOP's screenshot. There is no disagreement to resolve: the
registered groups are dead code in V1.0.0.45, and one "Default" section is both what the source
produces and what the screenshot shows.

Consequences taken:

* The nine categories are still modelled (`SourceCategory`) — the device property grid, the log and
  `OmDevice.Category` all use them — they are simply never used as list headers. "Files" and
  "Removed" in particular could only ever have been reached from `OmSource`s the Mac port does not
  create (a `Removed` device is dropped from the list; `File` sources are the Data Files tab).
* Sorting moved off the category and onto the Device column, which is what
  `DeviceListView.Sorting = SortOrder.Ascending` does. Keeping the category-major order would have
  imposed an order with no header to explain it (an AX6 holding data sorted above a cleared one).

## Other source-vs-transcription differences, and how they were resolved

* **Double space in the title.** `MainForm.cs:2318` is
  `"Open Movement " + " [V" + version + "]"` — two spaces before the bracket. The MOP transcribes
  one. Single space kept: it is what the screenshot reads and what `refs/08` specifies, and the
  extra space is plainly an upstream typo.
* **The workspace in the title.** Upstream prints `Settings.Default.CurrentWorkingFolder`, which may
  still be the literal `{MyDocuments}` template. The port prints the *expanded* path, because the
  MOP screenshot shows a real path (`C:\Users\ERA EEG\Documents\`) and `{MyDocuments}` would tell a
  site nothing.
* **"Gyro (dps)" vs "Gyro (±dps)".** `refs/08` writes the label without the ±;
  `DateRangeForm.Designer.cs:1024` is `"Gyro (±dps) "`. The designer wins — it *is* V1.0.0.45, and
  the ± survives in `refs/08`'s transcription of the neighbouring "Range (±g)".
* **`labelRateRangeSetting` reads "non-standard" at the MOP's settings.** It is blank only at
  exactly 100 Hz *and* ±8 g (`DateRangeForm.cs:808`); ±16 g falls through to the final `else`.
  Reproduced rather than suppressed, and called out in the SOP so a site does not read it as an
  error.
* **Version in the title.** `scripts/build-app.sh` stamps `CFBundleShortVersionString` from
  `git describe`, which on an untagged checkout is a commit hash. `AppInfo.version` therefore uses
  the bundle's value only when it is a dotted number and otherwise falls back to
  `AppInfo.packageVersion` (`1.0.0`), so a site never sees `Open Movement [V2cf7804]`. **Tag the
  release** (`git tag v1.0.0`) and the tag is used instead.

## Port-side deviations this phase introduced

* **Device column 70 → 84 pt.** The designer's 70 fits `6036222` in Segoe UI 9 pt; in the macOS
  system font at 11 pt the same string plus the LED circle needs 72 pt and would have truncated.
  `--self-test` measures the widest cell against the column and fails if it no longer fits, so this
  cannot silently regress. The other four column widths are still the designer's.
* **Recording Settings is 640 pt wide** (`DateRangeForm.ClientSize` is 485). At 485 the Sampling
  row's labels and the Defaults button truncate under macOS control metrics.
* **The MOP's initial recording profile.** Only applied when the workspace has no `recordSetup.xml`.
  The "Defaults" button is untouched and still restores OMGUI's 100 Hz / ±8 g — the deviation is a
  seed, not a lock. Recorded in Help ▸ About (`AboutView.profileNote`).
* **`Recording configured on …` is not an upstream string.** OMGUI logs only the `AX3-CONFIG-OK`
  CSV row, which no site can read off the screen; MOP §9.4.2 step 4.4 needs a date and time.
* **The mock device set moved out of `Sources/OmApi`.** `MockBackend.Spec.defaults` is what the
  `OmApi` tests are written against, so the MOP's IDs live in `OmGuiCore.MockDeviceCatalog` and
  `LaunchOptions.makeBackend` passes them to `MockBackend(root:specs:)`. `Sources/OmApi` is
  unchanged this phase.

## Evidence

`.build/release/OmGui --mock --self-test` prints 19 `CHECK` lines and exits non-zero if any fails
(`Sources/OmGui/SelfTest+Mop.swift`); the transcript is
`refs/screenshots/self-test-transcript.txt`. The window-dependent claims — the title bar text, the
"Default" header as the outline view actually draws it, the Device column fit, the Record rule as
the toolbar renders it, and that every SF Symbol resolves on this OS — are asserted there rather
than in `swift test`, which has no window. The rest is `Tests/OmGuiTests/MopAlignmentTests.swift`
(15 cases).

`refs/screenshots/01-main-window.png` is shot once, *before* `captureSopImages` configures a
recording on 6036222 (session 1042) -- an earlier re-shot after that step overwrote the frame, so
the reference window disagreed with both the MOP's row and `docs/sop-images/sop-01-main-window.png`.
The MOP row (`6036222 | 0 | 93% | | Stopped`) is now asserted at the moment the frame is captured,
so the ordering cannot regress silently.

The SOP screenshots are the self-test's own captures, flattened onto white (the captures carry an
alpha channel) and, for `sop-04`, overlaid with the MOP's 1–4 callouts. Both steps are one Pillow
script; re-run `--self-test`, copy `sop-*.png` out of the self-test folder, then flatten and
annotate.

## Remaining MOP mismatches that software cannot fix

1. **§9.4.1 install screenshots.** The Finder window of the mounted DMG and the macOS
   "access files on a removable volume" prompt are system UI; the app cannot capture them, and
   capturing the desktop would expose whatever else is on the study computer's screen. They have to
   be taken on a site laptop from the notarised DMG that is actually distributed. §9.4.1 is written
   to work without them.
2. **The removable-volume prompt itself.** It is a macOS privacy consent; it cannot be pre-granted
   by the app or the installer. If a site refuses it, the device list stays empty and the only
   remedy is System Settings.
3. **Gatekeeper on first launch.** Until the DMG is notarised, first launch needs the
   right-click ▸ Open gesture. That is a distribution step (`scripts/notarize.sh`), not a code
   change.
4. **The file naming convention is undecided.** §9.4.4 step 4 still says
   `ParticipantID_Visit_NamingConventionsTBD`; the rename stays manual until the convention exists.
   Once it does, `Tools ▸ Options… ▸ Filename` can generate most of it at download time
   (`{DeviceId}`, `{SessionId}`, `{StudyCode}`, `{SubjectCode}`).
5. **Recording Session ID is numeric only** (0 – 2147483647, `numericUpDownSessionID`). It is the
   session id written into the CWA header, so it cannot take a non-numeric participant identifier.
   A site whose participant IDs are not numbers needs a mapping, or must use Subject ▸ Code.
6. **The MOP's Windows paths and the `.exe`/.NET install text** are Windows-only by nature;
   `docs/SOP-mac.md` replaces them rather than reconciling them.
