import AppKit
import Foundation
import OmApi
import OmGuiCore

/// The MOP-alignment half of `--self-test`.
///
/// Two jobs: assert the things `refs/08-aria-mop-omgui-steps.md` pins down that only the running
/// window can show (the title, the "Default" group header, an un-truncated 7-digit device ID, the
/// Record-disabled-with-data rule, the toolbar icons), and capture the screenshots
/// `docs/SOP-mac.md` embeds.
extension SelfTest {

    /// The text of the device table as the window actually renders it: `[Group]` rows and the
    /// Device column of each device row, read back out of the `NSOutlineView`.
    @MainActor
    static func deviceTableOutline() -> String {
        guard let root = mainWindow?.contentView else { return "(no window)" }
        var found: NSOutlineView?
        func walk(_ view: NSView) {
            if found == nil, let outline = view as? NSOutlineView,
               outline.tableColumns.first?.title == "Device" {
                found = outline
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        guard let outline = found else { return "(no device table)" }
        var parts: [String] = []
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? GroupedTableView.Node else { continue }
            if node.isGroup { parts.append("[\(node.title)]") }
            else { parts.append(node.row?.cells.first?.text ?? node.id) }
        }
        return parts.joined(separator: " ")
    }

    /// The width the Device column would need for its widest cell, so a 7-digit ID that is being
    /// clipped shows up as a failure rather than as a screenshot nobody looks at twice.
    @MainActor
    static func deviceColumnFits() -> (fits: Bool, needed: CGFloat, width: CGFloat) {
        guard let root = mainWindow?.contentView else { return (false, 0, 0) }
        var found: NSOutlineView?
        func walk(_ view: NSView) {
            if found == nil, let outline = view as? NSOutlineView,
               outline.tableColumns.first?.title == "Device" {
                found = outline
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        guard let outline = found, let column = outline.tableColumns.first else { return (false, 0, 0) }
        var needed: CGFloat = 0
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? GroupedTableView.Node,
                  let text = node.row?.cells.first?.text, !text.isEmpty else { continue }
            let size = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
            // The device rows also carry the LED icon plus the cell's own insets.
            needed = max(needed, size.width + 24)
        }
        return (needed <= column.width, needed, column.width)
    }

    /// Everything in `refs/08` items 1-3, 6 and 9 that needs the running window.
    @MainActor
    static func checkMopAlignment(model: AppModel,
                                  say: @MainActor (String) -> Void,
                                  expect: @MainActor (Bool, String) -> Void) {
        // 3. Window title.
        let title = mainWindow?.title ?? ""
        say("title: \(title)")
        expect(title == AppInfo.windowTitle(workspace: model.workspace),
               "the window title is \"Open Movement [V<version>] - <workspace>\"")
        expect(title.hasPrefix("Open Movement [V") && title.contains("] - /"),
               "the title carries a version and an absolute workspace path")

        // 1. One group header, reading "Default".
        let outline = deviceTableOutline()
        say("device table: \(outline)")
        expect(outline.hasPrefix("[\(DeviceGroup.defaultTitle)]"),
               "the device list has one group header and it reads \"Default\"")
        expect(outline.components(separatedBy: "[").count == 2,
               "no other group header is drawn")

        // 9. Seven-digit IDs, in full.
        let ids = model.rows.map(\.deviceText)
        say("device IDs: \(ids.joined(separator: ", "))")
        expect(ids.contains(String(MockDeviceCatalog.mopDeviceId)),
               "the MOP's device \(MockDeviceCatalog.mopDeviceId) is listed with all seven digits")
        let fit = deviceColumnFits()
        say(String(format: "Device column: %.0f pt wide, widest cell needs %.0f pt", fit.width, fit.needed))
        expect(fit.fits, "the Device column is wide enough for a 7-digit ID")

        // 2. Every toolbar button has an icon that this OS can draw.
        var missing: [String] = []
        for (title, icon) in ToolbarIcon.all where icon.nsImage() == nil {
            missing.append("\(title)=\(icon.symbol)")
        }
        say("toolbar icons: " + ToolbarIcon.all.map { "\($0.0)=\($0.1.symbol)" }.joined(separator: " "))
        expect(missing.isEmpty, "every toolbar icon resolves (missing: \(missing.joined(separator: ", ")))")
        expect(ToolbarIcon.clear.symbol == "eraser.fill", "Clear has the eraser icon the MOP names")
    }

    /// The screenshots `docs/SOP-mac.md` embeds, captured from the real window before anything
    /// else in the run has touched the devices.
    ///
    /// It configures a recording on the MOP's device and stops it again, so the rest of the
    /// self test still finds the device cleared and stopped.
    @MainActor
    static func captureSopImages(model: AppModel,
                                 say: @MainActor (String) -> Void,
                                 shot: @MainActor (String) async -> Void,
                                 pause: @MainActor (Double) async -> Void,
                                 expect: @MainActor (Bool, String) -> Void) async {
        model.selectedDeviceIds = []
        model.selectionChanged()
        await shot("sop-01-main-window.png")

        // 9.4.2 step 2: select the device.
        model.selectedDeviceIds = [MockDeviceCatalog.mopDeviceId]
        model.selectionChanged()
        guard let mopRow = model.rows.first(where: { $0.deviceId == MockDeviceCatalog.mopDeviceId }) else {
            say("WARNING: the MOP device is not in the list")
            return
        }
        say("MOP device row: \(mopRow.deviceText) | \(mopRow.sessionText) | \(mopRow.batteryText)"
            + " | \(mopRow.downloadText) | \(mopRow.recordingText)")
        expect(mopRow.recordingText == "Stopped", "the MOP device reads \"Stopped\"")
        expect(model.toolbar.record, "Record is live for a cleared device")
        await shot("sop-02-device-selected.png")

        // 6. The troubleshooting case: a device that still holds data.
        model.selectedDeviceIds = [MockDeviceCatalog.mopDeviceWithDataId]
        model.selectionChanged()
        if let withData = model.rows.first(where: { $0.deviceId == MockDeviceCatalog.mopDeviceWithDataId }) {
            say("device with data: \(withData.deviceText) recording=\(withData.recordingText)"
                + " record=\(model.toolbar.record) download=\(model.toolbar.download) clear=\(model.toolbar.clear)")
            expect(withData.recordingText == "Stopped (with data)",
                   "a device holding a recording reads \"Stopped (with data)\"")
            expect(!model.toolbar.record, "Record is greyed out for a device that has data")
            expect(model.toolbar.download && model.toolbar.clear,
                   "Download and Clear are live for a device that has data")
        }
        await shot("sop-03-record-greyed.png")

        // 9.4.2 steps 3-4: the Recording Settings dialog.
        model.selectedDeviceIds = [MockDeviceCatalog.mopDeviceId]
        model.selectionChanged()
        model.openRecordingSettings()
        await pause(0.5)
        guard let sheet = model.recordingSheet else {
            say("WARNING: the Recording Settings sheet did not open")
            return
        }
        // 5. The MOP's starting values, because this workspace has no recordSetup.xml yet.
        let seeded = sheet.settings
        say("initial profile: freq=\(RecordingSettings.frequencyLabels[seeded.frequencyIndex])"
            + " range=\(RecordingSettings.rangeLabels[seeded.rangeIndex])"
            + " gyro=\(RecordingSettings.gyroLabels[seeded.gyroIndex])"
            + " immediately=\(seeded.immediately)")
        expect(seeded.sampleRate == .hz100 && seeded.accelRange == .g16
                && seeded.gyroIndex == 0 && seeded.immediately,
               "a fresh workspace opens at 100 Hz, +-16 g, gyro disabled, Immediately on Disconnect")
        expect(seeded.hasSyncGyro, "the MOP device is an AX6, so the Gyro combo is shown")
        let warnings = seeded.validate().warningText ?? ""
        say("warnings: " + warnings.replacingOccurrences(of: "\n", with: " / "))
        expect(warnings.contains(RecordingSettings.warningMessages[10]),
               "the gyro-disabled warning is shown verbatim")

        sheet.settings.sessionId = 1042
        await pause(0.4)
        await shot("sop-04-recording-settings.png")

        // The screenshot below is of the Log pane, so drop the transcript this run has been
        // writing into it: what should be readable is the app's own output.
        model.clearLog()
        model.commitRecording(sheet.settings, devices: sheet.devices)
        model.recordingSheet = nil
        for _ in 0..<200 where model.progressSheet != nil { await pause(0.1) }
        await pause(0.6)
        model.rebuildRows()

        // 8. The Form 2 line, in the Log pane and the status bar.
        model.showLog = true
        await pause(0.4)
        let expected = "Recording configured on \(MockDeviceCatalog.mopDeviceId): session 1042, "
        let logText = model.logText
        let statusText = model.statusText
        await shot("sop-05-record-confirmed.png")
        model.showLog = false
        await pause(0.3)
        say("status bar: \(statusText)")
        expect(logText.contains(expected),
               "the Log pane carries \"Recording configured on <id>: session <n>, <date time>\"")
        expect(statusText.hasPrefix(expected), "the status bar carries the same line")

        // Put the device back the way the rest of the run expects to find it.
        model.selectedDeviceIds = [MockDeviceCatalog.mopDeviceId]
        model.selectionChanged()
        model.stopRecording()
        for _ in 0..<300 where model.progressSheet != nil { await pause(0.1) }
        await pause(0.4)
        model.rebuildRows()
        model.selectedDeviceIds = []
        model.selectionChanged()
    }
}
