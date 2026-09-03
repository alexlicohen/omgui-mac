# OmGui for Mac — native Apple Silicon port of Axivity OMGUI

## Context

ARIA IMPACT sites must configure Axivity AX6 watches, download `CWA-DATA.CWA`, and clear devices. OMGUI is Windows-only. The 2026-07-15 DCC action (OMGUI not centralized in Lasso; Alex to evaluate a container) is still open as of 2026-08-28 and blocks the CCC's wearable click-by-click MOP.

Research (verified against openmovement sources, 2026-09-02):
- **Containers can't do it**: no USB passthrough on macOS for Docker/Podman/Apptainer. **Wine/CrossOver**: OMGUI's WMI/SetupAPI device pairing isn't emulated; Rosetta 2 ends after macOS 27. **VM** (VMware Fusion free + Win11 ARM64): works but needs a Windows license, ~40 GB, admin. Documented fallback only.
- **OMGUI = thin .NET 3.5 WinForms over `libomapi`** (BSD-2 C library) which already ships a **macOS backend** (`omapi-devicefinder-mac.c`: IOKit + DiskArbitration; devices appear as `/dev/cu.usbmodem*` + `/Volumes/AX*/CWA-DATA.CWA`, VID:PID `04d8:0057`). All analysis tools (SVM, cut points, wear time, sleep, WAV/CSV export) are `omconvert`, portable C in the same repo.
- Full UI/feature inventory of OMGUI v45 was extracted from `MainForm.Designer.cs`, `DateRangeForm`, `MetaDataTools.cs`, `OptionsDialog`, `DataViewer`, plugin system, and the InnoSetup manifest. Summary below; the agent report is the spec and gets checked into `refs/`.

Constraints from Alex: Apple Silicon only; everything local; a real Mac app (no Terminal); repo under `alexlicohen`; **functionality and appearance mirror OMGUI as closely as possible**; prototype first, then the CCC tests with a real AX6. Paid Apple Developer account exists (team V9R6KQRWSD); Xcode 26.6 / Swift 6.3 installed.

## Architecture

```
alexlicohen/omgui-mac  (public, BSD-2)
  Vendor/libomapi/        # vendored from openmovementproject/libomapi (C), built as SwiftPM C target, arm64
  Vendor/omconvert/       # vendored omconvert + cwa-convert C sources → helper binaries in app bundle
  OmApi/                  # Swift wrapper mirroring omapinet: OmDevice, OmReader, OmSource, categories, callbacks
                          #   protocol DeviceAPI { LibOmapiDevice, MockDevice }  (mock = demo without hardware)
  OmGui/                  # SwiftUI/AppKit app "OmGui" (macOS 14+): MainWindow, DateRangeForm, OptionsDialog,
                          #   DataViewer, Export*Form, PluginsForm/RunPluginForm/ProcessingForm, About
  omgui-cli/              # thin CLI on OmApi for CCC batch (record|download|clear|status) — no UI
  refs/                   # spec: OMGUI source files listed below + inventory report
  scripts/                # build-libomapi.sh, build-omconvert.sh, build-dmg.sh, notarize.sh
  docs/                   # SOP.md (MOP click-by-click), FALLBACK-VM.md, README
  Tests/                  # OmApi tests on MockDevice; metadata encoding; filename template; omconvert arg builders
```

Decision: **link libomapi rather than reimplement the serial protocol.** It gives OMGUI's exact semantics (session/metadata/accel config/delays/erase/download/reader) and its macOS finder. If the mac finder proves broken on macOS 26, fix it in the vendored copy (phase 1 escalation) before falling back to a Swift protocol reimplementation.

## What "mirror OMGUI" means (from the inventory)

**Main window** — same regions, labels, and column names:
- Menus: File (Choose Working Folder…, Open Working Folder, Recent Folders, Export Resampled WAV/CSV…, Export Raw CSV…, Exit) · Edit · View (Toolbar, Status Bar, Preview, Device Properties, File Properties, Log) · Tools (Calculate SVM/Cut Points/Wear Time/Sleep Time…, Plugins…, Options…) · Help (About…).
- Device toolbar: Download · Cancel · Clear · | · Record… · Stop · | · Identify. All batch over multi-selection.
- Devices table: Device | Session Id | Battery | Download | Recording; groups Devices/New Data/Downloading/Downloaded/Charging/Standby/Outbox/Removed/Files; LED circle icon 0–7; battery text red <33 / orange 33–65 / green ≥66; Download column Cancelled/Error red, NN% orange, Complete green; Recording column Stopped (red) / Always / Interval … (with data). Device property grid to the right.
- Preview (DataViewer): Zoom/Selection modes; checkboxes X/Y/Z, Gyro-X/Y/Z, ±1g, Light, Temp., Batt.%, Batt.V, Time; OMGUI pen colours (X red, Y green, Z blue, gyro cyan/magenta/yellow, SVM black, light brown, temp dark magenta, batt dark cyan / light cyan; light-grey background with hourly bands). Opens on file select or live on device select. Implemented on Canvas with level-of-detail downsampling (files are hundreds of MB).
- Workspace toolbar: "Workspace:" path, …, open, refresh. Tabs: Data Files (Export ▾ WAV/Resampled CSV/Raw CSV, SVM…, Cut Points…, Wear Time…, Sleep Analysis…, Plugins…, Show All Files; columns Name | Size (MB) | Date Modified; file property grid) · Plugin Queue (Cancel, Clear Completed; Plugin | Source | Progress) · Output Files.
- Log pane (View ▸ Log), status bar with progress.

**Recording Settings dialog** (`DateRangeForm`) — identical fields, defaults, validation and warnings: Session ID; Freq 3200…6.25 (default 100); Range ±2/4/8/16 g (default 8); Gyro ±dps 2000…125 (AX6 only); Immediately on Disconnect vs Interval with Start/End date-time, Delay days, Duration d/h/m; Flash during recording; Low Power + Unpacked hidden for AX6; Study (Code, Centre, Investigator, Exercise Type, Operator, Notes) and Subject (Code, Sex, Height, Weight, Handedness, Site list, Notes); Defaults button; warning panel (battery <90, has data, duration > capacity/battery, start >14 d ahead, end in past → OK disabled, etc.). Metadata encoded as `key=value&…` URL-encoded into the 448-byte annotation block via `OmSetMetadata`; commit order SessionId → Metadata → MaxSamples(0) → AccelConfig → SyncTime → Debug(flash) → AlwaysRecord/SetDelays.

**Download** — filename template `{DeviceId}_{SessionId}` (`%05u`, `%010u`) plus metadata placeholders, whitelist-sanitised; `.cwa.part` → rename; device/session ID verification message on mismatch; overwrite prompt; optional download log `DOWNLOAD-OK` line.

**Clear** — prompt "Wipe/Clear N device(s)?"; default = full wipe, Shift-click = quick format (OMGUI semantics preserved and stated in the SOP); resets session/metadata/delays/accel config then `OmEraseDataAndCommit`.

**Options** — Filename template (+Default), Plugin Folder (+Browse), placeholder hint.

**Plugins / Tools** — bundle arm64 `omconvert` and `cwa-convert` in the app; implement the built-in Tools (SVM, Cut Points, Wear Time, Sleep, Resampled WAV/CSV) with OMGUI's `ProcessingForm` flow and omconvert argument sets; Raw CSV export via OmReader. Plugin folder support with the XML `*.plugin` descriptor schema and HTML-form host (WKWebView); ship the `OmConvertPlugin` descriptor. `.cmd` wrappers replaced by direct exec. OMPA Convertor (.NET) not ported.

Out of scope: firmware update, Windows driver setup, ARIA-specific presets (metadata defaults live in the workspace profile exactly as OMGUI does; ARIA values go in the SOP).

## Phases and tiers

| # | Work | Tier | Acceptance |
|---|---|---|---|
| 0 | Repo scaffold; vendor libomapi + omconvert/cwa-convert; `refs/` (spec files + inventory); SwiftPM + Xcode project skeleton | quick-task | `xcodebuild -scheme OmGui build` succeeds with C targets compiled arm64 |
| 1 | Build libomapi on macOS 26 arm64; audit/fix `omapi-devicefinder-mac.c` (deprecated IOKit/DA APIs); Swift `OmApi` wrapper mirroring `omapinet` (OmDevice/OmReader/categories/download callbacks); `MockDevice` replaying documented responses | deep-reasoner (danger zone: C interop) | OmApi tests pass on MockDevice; libomapi finder compiles without deprecated-API errors; CLI `status` lists mock devices |
| 2 | Main window: devices table with groups/LED/colours, property grids, toolbar/menus, workspace + file tabs, log, status bar; Record dialog with full validation + metadata encoding; Download/Clear/Cancel/Identify batch flows; Options; filename template | builder (spec = Designer files) | mock-mode walkthrough matches the inventory item-for-item; metadata-encoding and filename-template unit tests |
| 3 | DataViewer (file + live device preview, zoom/selection, channels, colours); Export Raw CSV; Tools via omconvert (`ProcessingForm`, Plugin Queue, Output Files); plugin descriptor loader + HTML host | deep-reasoner (DataViewer, CWA reader perf) + builder (export/tools) | 500 MB CWA scrolls smoothly; omconvert outputs byte-identical to Windows omconvert for a fixture file |
| 4 | Signing/notarization scripts (Developer ID Application cert — Alex issues it once in Xcode → Accounts; notarytool keychain profile, never committed), hardened runtime, signed helper binaries, DMG; About; `docs/`; first release | builder | DMG installs by double-click on a second Mac with no Gatekeeper prompt; reviewer PASS on docs |
| 5 | Hands-on with the CCC's AX6: detect, Record (interval + immediate), 1-h recording, Download, header diff vs an OMGUI-produced `.cwa` (`cwa_metadata.py` both), Clear, Tools run | Alex + CCC | header/annotation bytes match OMGUI's for the same settings; device re-recordable after Clear |

## Distribution

- **GitHub** `alexlicohen/omgui-mac`: tagged releases with notarized DMG; README + SOP. Windows sites keep OMGUI.
- **Lasso**: not hosted there (2026-07-15 decision); SOP goes into the wearable MOP in Lasso's document system; the actigraphy CRF's Launch Pad upload references the `{DeviceId}_{SessionId}.cwa` naming.
- **CCC**: `omgui-cli` for pre-provisioning the 10-kit shipments; sites use the app. Announce at the first DM meeting / office hours; the CCC is first tester and MOP author.

## Verification

- `xcodebuild test` (OmApi on MockDevice, metadata encoding, filename template, omconvert arg builders).
- Mock-mode UI walkthrough against the inventory checklist (phase 2/3).
- omconvert output parity vs Windows binary on a fixture `.cwa` (phase 3).
- Notarized DMG cold install on a second Mac (phase 4).
- Real-device header diff vs OMGUI (phase 5) is the objective equivalence check.

## Open items for the CCC (needed before phase 5, not before build)

- ARIA recording settings (Hz, ±g, gyro, immediate vs interval, duration) and which Study/Subject metadata fields sites fill in; a sample OMGUI-configured `.cwa` for the header diff and DataViewer fixture.
- Whether Clear is site-side or CCC-only on kit return.
