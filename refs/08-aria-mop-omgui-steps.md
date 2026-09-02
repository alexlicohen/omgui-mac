# ARIA Wearables MOP (August 15, V1) — OMGUI steps the app must match

Source: "Wearables MOP_August15_V1.pdf" (Abby Dickinson), §2.5/2.6, §9. Screenshots in the MOP are of OMGUI V1.0.0.45 on Windows; window title reads `Open Movement [V1.0.0.45] - C:\Users\ERA EEG\Documents\` (title = "Open Movement [Vx] - <workspace path>").

## Site context
- Sites own the "study computer used for watch data download". Each site's equipment code: `[Site]-AX-[nn]` (e.g. CLA-AX-04); device ID (7 digits, e.g. 6036222) is recorded in Lasso Form 2.
- §9.4: "software is only compatible with Windows" — the Mac app replaces §9.4.1 (installer .exe + .NET 3.5) with a DMG.

## §9.4.2 Connecting Device / Recording Configuration (verbatim steps)
1. Select a watch, make sure it is fully charged, note down the device ID (Form 2).
2. Launch OMGUI, connect the watch by mini-USB, select the device in the device window. [Screenshot: toolbar `Download · Cancel · Clear | Record... · Stop | Identify` with icons (download arrow, grey circle-x Cancel, eraser Clear, red dot Record, grey square Stop, lightbulb Identify); device table columns Device | Session Id | Battery | Download | Recording; group header **"Default"**; row `6036222  0  93%  (blank)  Stopped`.]
3. Press "Record."
4. Recording Settings dialog [screenshot annotated 1–4]:
   1. Recording Session ID = the participant number.
   2. Freq 100 Hz, Range ±16 g, Gyro (disabled).
   3. "Immediately on Disconnect".
   4. Press OK; disconnect; note the date/time of disconnection → Lasso Set-up form (Form 2: "Date recording initiated in OMGUI").
   Screenshot layout: Session ID row; "Sampling" group (Freq | Range | Gyro (dps)); "Recording Time" group (radio Immediately on Disconnect / Interval; Start Date/Start Time/Delay days; Duration days/hours/minutes; End Date/End Time); "Study" group left (Study Centre, Study Code, Study Investigator, Exercise Type, Operator, Notes) and "Subject" group right (Code, Sex, Height, Weight, Handedness, Site, Notes); bottom: WARNINGS box (yellow background) on the left with "Flash during recording" checkbox to its right, OK / Cancel bottom-right. Warning text shown for an AX6 with gyro disabled: "A gyro-enabled device is being configured for accelerometer data only (no gyro data)."

Troubleshooting: if Record is greyed out, the device has existing data ("Stopped (with data)"): download + export first, then press "Clear".

## §9.4.3 Receiving the equipment back
Note the device ID returned; inspect puck/strap; then download.

## §9.4.4 Downloading and Exporting Data (verbatim steps)
1. Connect the AX6, select the device; if still recording press "Stop"; press "Download".
2. Select the downloaded file in the Data Files window. [Screenshot: Workspace bar; tabs Data Files | Plugin Queue | Output Files; toolbar `Export ▾ · SVM... · Cut Points... · Wear Time... · Sleep Analysis... · Plugins...`; file `6036222_0000000000.cwa  0.23  11/06/26 14:21:17`.]
3. Press "Export" → "Export Raw CSV…". [Menu: Export Resampled WAV… / Export Resampled CSV… / Export Raw CSV…]
4. Locate the exported file; rename it to `ParticipantID_Visit_NamingConventionsTBD` (convention not final).
5. Upload to Lasso.

Notes: download does not clear the puck; workspace defaults to the Documents folder; **do not Clear until downloaded AND uploaded to Lasso**; Clear = the "Clear" button with the eraser icon; existing data must be cleared before a new recording.

## §9.5 Prepare watch for next participant
Inspect, document damage in Lasso Form 4, clean with isopropyl wipe, fully charge (USB or wall adapter).

## Matching requirements derived for the Mac app
- Window title "Open Movement [V<version>] - <workspace>"; device group header "Default" for connected devices (verify against DeviceListView.cs — the MOP screenshot is the ground truth for V1.0.0.45); toolbar buttons with OMGUI-style icons (Clear must visibly have an eraser icon — the MOP refers to it).
- Recording Settings layout as in the screenshot (Sampling / Recording Time / Study / Subject groups; WARNINGS yellow box with "Flash during recording" to its right); the exact gyro-disabled warning string; Record disabled when the device has data.
- Default workspace = ~/Documents; 7-digit device IDs displayed in full; file names `<deviceId>_<sessionId>.cwa`.
- Initial recording profile = MOP values (100 Hz, ±16 g, gyro disabled, Immediately on Disconnect) — a deliberate deviation from OMGUI's ±8 g default, so sites only type the Session ID.
- Export ▸ Export Raw CSV… produces the file the site renames and uploads.
- Mac-specific MOP text needed: DMG install, first-launch removable-volume permission prompt.
