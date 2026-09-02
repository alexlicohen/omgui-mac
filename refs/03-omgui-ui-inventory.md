# OMGUI v45 UI + feature inventory (spec for the Mac port)

Source of truth: `upstream/openmovement/Software/OM/omgui/*.cs` (Designer files are authoritative for layout/labels), `Software/OM/omapinet/*.cs` for device semantics. Everything below verified against those files unless marked UNVERIFIED.

## 1. Main window (`MainForm.Designer.cs`, ClientSize 1056x590)

```
menuStripMain:  &File  &Edit  &View  &Tools  &Help
toolStripDevices: [Download][Cancel][Clear] | [Record...][Stop] | [Identify]
splitContainerPreview.Panel1 (Horizontal, FixedPanel=Panel1, dist 218)
  splitContainerDevices (Vertical, IsSplitterFixed, dist 747)
    devicesListView (Details, GridLines, FullRowSelect, grouped, sort asc, AllowColumnReorder)
      columns: Device | Session Id | Battery | Download | Recording
      groups: Devices / New Data / Downloading / Downloaded / Charging / Standby / Outbox / Removed / Files
    propertyGrid "Device" (ToolbarVisible=false)
splitContainerPreview.Panel2 -> splitContainer1 (Horizontal, FixedPanel=Panel2, dist 89)
  dataViewer (Mode=Zoom)
  toolStripData: [Zoom][Selection]  groupBoxOptions "Options":
    [x]X-Axis [x]Y-Axis [x]Z-Axis [ ]Gyro-X [ ]Gyro-Y [ ]Gyro-Z [ ]±1g [ ]Light [ ]Temp. [ ]Batt.% [ ]Batt.V [ ]Time
toolStripWorkingFolder: "Workspace:" [directory chooser, ReadOnly] [...] [open icon] [refresh icon]
tabControlFiles: ( Data Files | Plugin Queue | Output Files )
  Data Files: toolStripFiles [&Export ▾ (Export Resampled WAV… / Export Resampled CSV… / Export Raw CSV…)]
              [SVM...][Cut Points...][Wear Time...][Sleep Analysis...][&Plugins...][Show All Files]
              splitContainerFileProperties (Vertical, dist 738, FixedPanel=P2)
                filesListView: Name | File Location (w=0) | Size (MB) | Date Modified   |  propertyGridFile
  Plugin Queue: [Cancel][Clear Completed]; cols Plugin | Source | Progress (%)
  Output Files: File Name | File Location | File Size (MB) | Date Modified
textBoxLog (splitContainerLog.Panel2, toggled View ▸ &Log, dist 562)
statusStripMain: toolStripStatusLabelMain (Spring) | progress (16px)
```
Menus: File = Choose Working Folder… / Open &Working Folder / Recent Folders / Export Resampled &WAV… / Export &Resampled CSV… / Export Ra&w CSV… / E&xit. Edit = Cu&t / &Copy / &Paste / Select &All. View = &Toolbar / &Status Bar / Pre&view / Device &Properties / File P&roperties / &Log. Tools = Calculate S&VM… / Calculate &Cut Points… / Calculate Wear &Time… / Calculate &Sleep Time… / &Plugins… / &Options…. Help = &About….

## 2. Record dialog — `DateRangeForm` (title "Recording Settings")

| Label | Control | Default | Values | Encoding |
|---|---|---|---|---|
| Recording Session ID | NumericUpDown | last profile | 0…2147483647 | OmSetSessionId |
| Freq. (Hz) | ComboBox DropDownList | 100 (index 5) | 3200,1600,800,400,200,100,50,25,12.5,6.25 | OmSetAccelConfig(freq,…); negated if Low Power |
| Range (±g) | ComboBox | 8 (index 2) | 2,4,8,16 | OmSetAccelConfig(…,range) |
| Gyro (±dps) | ComboBox, visible only if device.HasSyncGyro (AX6) | (disabled) | (disabled),2000,1000,500,250,125 | range |= gyroRange << 16 |
| labelRateRangeSetting | Label | "-" | "not supported by firmware/device", "not supported with gyro", "not supported by firmware in packed mode", "not guaranteed", "non-standard" | — |
| Defaults | Button | — | resets freq=100, range=8 | — |
| Immediately on Disconnect / Interval | RadioButtons | Immediately | — | AlwaysRecord() vs SetDelays |
| Start Date / Start Time / End Date / End Time | DateTimePickers (ShowUpDown) | now / now+duration | enabled only for Interval | — |
| Delay: days | NumericUpDown | 0 | 0–1000 | — |
| Duration: days / hours / minutes | NumericUpDown ×3 | 0 | 0–1000 / 1–24 / 1–60 | — |
| Flash during recording | CheckBox | profile | — | SetDebug(3 : 0) |
| Lower Power (Noisier) | CheckBox, hidden for AX6 | false | — | negative frequency |
| Unpacked data | CheckBox, hidden for AX6 (always unpacked) | false | — | — |
| Study: Study Code / Study Centre / Study Investigator / Exercise Type / Operator / Notes | TextBoxes | profile | free text | _s, _c, _i, _x, _so, _n |
| Subject: Code / Sex / Height / Weight / Handedness / Site / Notes | TextBox, ComboBox("",male,female), TextBox, TextBox, ComboBox("",left,right), ComboBox(site list), TextBox | profile | Site list: "", left wrist, right wrist, waist, left ankle, right ankle, left thigh, right thigh, left hip, right hip, left upper-arm, right upper-arm, chest, sacrum, neck, head | _sc, _se, _h, _w, _ha, _p, _sn |
| richTextBoxWarning | RichTextBox, hidden when empty | — | "WARNINGS\n…": battery<90, device has data, duration > capacity, duration > battery life, start >14 days ahead, end in past (invalid → OK disabled), start >1 day past, freq>200 or <50, start≥end (invalid), low-power in use | — |
| OK / Cancel | Buttons | OK disabled while invalid | — | — |

Metadata encoding (`MetaDataTools.cs`): `key=value` pairs joined by `&`, key and value URL-encoded (space→`+`, unreserved `A-Za-z0-9~_.-`, else `%XX` of UTF-8). Empty `_`-prefixed keys omitted. Written via OmSetMetadata into the annotation block: offset 64, 14 segments × 32 bytes = 448 bytes, space-padded.

Commit order per device (batch, 5 progress steps): SetSessionId → OmSetMetadata → OmSetMaxSamples(0) → OmSetAccelConfig → SyncTime → SetDebug(flash) → AlwaysRecord() / SetDelays (this last call commits).

## 3. Download / Clear / Cancel (`MainForm.cs`)

Filename: template `Settings.FilenameTemplate`, default `{DeviceId}_{SessionId}`. `{DeviceId}` → `%05u`; `{SessionId}` → `%010u` (file's SessionId if device SessionId == uint.MaxValue, else "0000000000"). Also `{StudyCentre} {StudyCode} {StudyInvestigator} {StudyExerciseType} {StudyOperator} {StudyNotes} {SubjectSite} {SubjectCode} {SubjectSex} {SubjectHeight} {SubjectWeight} {SubjectHandedness} {SubjectNotes}` + custom metadata keys. Whitelist sanitise: anything outside `[0-9A-Za-z_-]` → `_`; empty → `-`. Final `<workingFolder><name>.cwa`; downloaded to `<name>.cwa.part` then renamed.

Verification: if DeviceId used ≠ label ≠ device ≠ file-header ID → MessageBox "The correct download file name cannot be established (device identifier not verified) -- you must reconnect the device and try again." Same for session ID. Existing `.part`/`.cwa` → "Overwrite existing file?" (OKCancel, default Cancel), OK deletes. On completion append `yyyy-MM-dd HH:mm:ss,DOWNLOAD-OK,<filename>` to the optional download log.

Clear: `wipe = (Shift NOT held)`. Firmware check first. Prompt "Wipe/Clear N device(s)?" (OKCancel, default Cancel). Preview closed, then per device on a background worker: OmSetSessionId(0), OmSetMetadata(""), OmSetDelays(INFINITE, INFINITE), OmSetAccelConfig(default rate, default range), OmEraseDataAndCommit(OM_ERASE_WIPE | OM_ERASE_QUICKFORMAT). Default = full WIPE; Shift-click = quick format.

Cancel: selected downloading devices → CancelDownload(); column shows "Cancelled". Download/Cancel/Clear/Record are batch over devicesListView.SelectedItems.

## 4. Options dialog (`OptionsDialog`, title "Options")
Filename: TextBox + [Default] (`{DeviceId}_{SessionId}`); Plugin Folder: TextBox + [Browse...]; static hint "Placeholders: {DeviceId}, {SessionId}, {StudyCode}, {SubjectCode}"; OK / Cancel. Working-folder templates support {MyDocuments} {Desktop} {LocalApplicationData} {ApplicationData} {CommonApplicationData}.

## 5. Plugins
Plugin = subdirectory of the plugin folder with an XML `*.plugin` descriptor: height, width, runFilePath, htmlFilePath, savedValuesFilePath, iconName, description, fileName, readableName, outputFile, inputFile, outputExtensions/extension, defaultValues, numberOfInputFiles, wantMetadata, requiresCWANames, createsOutput. A WebBrowser control hosts the HTML form; values become command-line args to runFilePath. Per-workspace `settings/pluginsProfile.profile`.

| Bundled plugin | Backend | Cross-platform |
|---|---|---|
| OmConvertPlugin (AX_OMConvert) | run-omconvert.cmd → omconvert.exe (`-out .wav -svm-file -wtv-file -paee-file`) | yes (omconvert portable C; only the .cmd is Windows) |
| Convert_CWA / cwa-convert | cwa-convert.exe | yes |
| Convert_CWA / OMPA Convertor | .NET exe | no — not ported |
| Built-in Tools menu (SVM, Cut Points, Wear Time, Sleep, Resampled WAV/CSV) | Plugins\OmConvertPlugin\omconvert.exe via ProcessingForm | yes |
| Raw CSV export (ExportForm) | in-process libomapi reader | reimplement on OmReader |
| setup-ax3-driver.exe, firmware\* | Windows-only | N/A |

omconvert args: WAV `-resample N -calibrate 0|1 -out X`; SVM `-svm-epoch -svm-filter -svm-mode -svm-file`; WTV `-wtv-epoch/-wtv-file`; PAEE `-paee-epoch/-paee-filter/-paee-model/-paee-file`; sleep `-sleep-file`; resampled CSV `-csv-file`. All write `<out>.part` then rename.

## 6. Preview (`DataViewer`)
File select → `dataViewer.Open(filename)`; device select → `dataViewer.Open(deviceId)` (live on-device preview). Modes: Zoom (left-drag zoom in, right-click zoom out), Selection (selected time slice feeds Export Raw CSV and plugins). Pen colours (alpha 0x60): X Red, Y Green, Z Blue, Gyro-X Cyan, Gyro-Y Magenta, Gyro-Z Yellow, ±1g/SVM Black, Light Brown, Temp. DarkMagenta, Batt.% DarkCyan, Batt.V LightCyan. Background LightGray; alternating per-hour grey bands; missing-data pens LightGray/Gray; download-progress overlay green↔white↔green gradient over DarkGray↔WhiteSmoke.

## 7. Icons / colours
Device LED: Circle0.png…Circle7.png (index = device.LedColor 0–7), Circle.png (8, unknown), Data.png (9, file rows). Battery `NN%` or `-`; red <33, orange 33–65, green ≥66; prefixes `DAMAGED? (…)` / `DISCHARGED? (…)`. Download column: Cancelled / Error (0xNN) red; NN% orange; Complete green. Recording column: Stopped (red), Always, `Interval dd/MM/yy HH:mm:ss-dd/MM/yy HH:mm:ss`, suffix " (with data)". File dates `dd/MM/yy HH:mm:ss`; sizes MB 2 dp.

## 8. Spec files (all under upstream/openmovement/Software/OM/)
omgui/MainForm.Designer.cs, MainForm.cs, DateRangeForm.Designer.cs + .cs, MetaDataTools.cs, MetaDataEntry.cs, MetadataObject.cs, DeviceListView.cs, DataViewer.Designer.cs + .cs, OptionsDialog.Designer.cs + .cs, ExportForm*.cs, Export{Csv,Wav,Svm,Wtv,Paee,Sleep}Form*, Plugin.cs, PluginManager.cs, PluginsForm*, RunPluginForm.cs, ProcessingForm.cs, OmGui-InnoSetup.iss; omapinet/OmDevice.cs, OmSource.cs, OmReader.cs, OmApi.cs; "Plugins for release/Plugins/**/*.plugin", run-omconvert.cmd.

UNVERIFIED: byte-level OM_ERASE_WIPE vs OM_ERASE_QUICKFORMAT (libomapi C); no OMGUI screenshots retrieved.
