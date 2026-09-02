import AppKit
import OmApi
import OmGuiCore
import SwiftUI

/// `--self-test <dir>`: drive the real toolbar actions against the mock backend, capture the
/// window at each step and print a transcript, then quit.
///
/// This is not a stub or a simulation — every step calls the same `AppModel` method the button
/// calls; only the message boxes are auto-answered (they would otherwise block a headless run).
enum SelfTest {

    nonisolated(unsafe) static var window: NSWindow?

    @MainActor
    static func run(model: AppModel, directory: String, completion: @escaping @MainActor () -> Void) {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prompter = ScriptedPrompter()
        model.prompter = prompter

        Task { @MainActor in
            @MainActor func say(_ text: String) {
                print("SELF-TEST: \(text)")
                model.log("SELF-TEST: " + text)
            }

            @MainActor func pause(_ seconds: Double = 0.6) async {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }

            @MainActor func shot(_ name: String) async {
                await pause(0.35)
                let path = folder.appendingPathComponent(name)
                if capture(to: path) { say("captured \(path.lastPathComponent)") }
                else { say("WARNING: could not capture \(name)") }
            }

            say("backend = \(model.api.backend.name)")

            // Wait for the mock to enumerate.
            for _ in 0..<40 where model.rows.isEmpty { await pause(0.25) }
            say("devices: " + model.rows.map { "\($0.deviceText) [\($0.category.groupName)] battery=\($0.batteryText) recording=\($0.recordingText)" }
                .joined(separator: " | "))

            // Give the poller a moment so battery/session/interval are populated.
            for _ in 0..<40 where model.rows.contains(where: { $0.sessionText == "-" }) { await pause(0.25) }
            model.rebuildRows()
            await shot("01-main-window.png")

            // --- Selection drives the toolbar -----------------------------------------------
            model.selectedDeviceIds = Set(model.rows.map(\.deviceId))
            model.selectionChanged()
            say("select all -> toolbar download=\(model.toolbar.download) clear=\(model.toolbar.clear) record=\(model.toolbar.record) stop=\(model.toolbar.stop) identify=\(model.toolbar.identify)")
            await shot("02-all-selected.png")

            // --- Identify ---------------------------------------------------------------------
            model.identifySelected()
            await pause(1.4)
            say("identify: LED indices now \(model.rows.map(\.ledIconIndex))")
            await shot("03-identify.png")

            // --- Download the device that holds data -----------------------------------------
            let withData = model.rows.filter(\.hasData).map(\.deviceId)
            if let target = withData.first {
                model.selectedDeviceIds = [target]
                model.selectionChanged()
                say("download \(FilenameTemplate.deviceIdString(target)) into \(model.workspace.path)")
                model.download()
                var done = false
                for _ in 0..<200 {
                    await pause(0.1)
                    model.rebuildRows()
                    if let row = model.rows.first(where: { $0.deviceId == target }),
                       row.downloadText == "Complete" { done = true; break }
                }
                say("download \(done ? "completed" : "DID NOT COMPLETE")")
                model.refreshFiles()
                say("workspace data files: " + model.dataFiles.map { "\($0.name) \($0.sizeText) MB \($0.dateText)" }.joined(separator: ", "))
                await shot("04-downloaded.png")

                if let file = model.dataFiles.first {
                    model.selectedFilePaths = [file.location]
                    model.fileSelectionChanged()
                    say("file properties: " + model.filePropertyRows.prefix(6).map { "\($0.name)=\($0.value)" }.joined(separator: " "))
                    await shot("05-file-properties.png")
                    model.selectedFilePaths = []
                    model.fileSelectionChanged()
                }
            } else {
                say("WARNING: no device with data to download")
            }

            // --- Record on a cleared device ---------------------------------------------------
            if let target = model.rows.first(where: { !$0.hasData })?.deviceId {
                model.selectedDeviceIds = [target]
                model.selectionChanged()
                model.openRecordingSettings()
                await pause(0.5)
                guard let context = model.recordingSheet else {
                    say("WARNING: recording sheet did not open")
                    completion()
                    return
                }
                let validation = context.settings.validate()
                say("record dialog for \(FilenameTemplate.deviceIdString(target)): gyro=\(context.settings.hasSyncGyro) rateRange='\(validation.rateRangeText)' ok=\(validation.okEnabled)")
                say("warnings: " + (validation.warningText?.replacingOccurrences(of: "\n", with: " / ") ?? "(none)"))
                await shot("06-recording-settings.png")

                context.settings.sessionId = 4321
                context.settings.metadata.studyCode = "ARIA-IMPACT"
                context.settings.metadata.subjectCode = "P042"
                context.settings.metadata.subjectSite = "left wrist"
                model.commitRecording(context.settings, devices: context.devices)
                model.recordingSheet = nil
                for _ in 0..<200 where model.progressSheet != nil { await pause(0.1) }
                await pause(0.6)
                model.rebuildRows()
                if let row = model.rows.first(where: { $0.deviceId == target }) {
                    say("after record: session=\(row.sessionText) recording=\(row.recordingText)")
                }
                say("recordSetup.xml written: \(FileManager.default.fileExists(atPath: RecordingProfile.url(in: model.workspace).path))")
                await shot("07-after-record.png")
            }

            // --- Clear -------------------------------------------------------------------------
            model.selectedDeviceIds = Set(model.rows.map(\.deviceId))
            model.selectionChanged()
            prompter.answerConfirm = true
            say("clear (full wipe) \(model.selectedDeviceIds.count) device(s)")
            model.clear(shiftHeld: false)
            for _ in 0..<300 where model.progressSheet != nil { await pause(0.1) }
            await pause(0.8)
            model.rebuildRows()
            say("after clear: " + model.rows.map { "\($0.deviceText) session=\($0.sessionText) recording=\($0.recordingText) group=\($0.category.groupName)" }
                .joined(separator: " | "))
            await shot("08-after-clear.png")

            // --- Chrome toggles ------------------------------------------------------------------
            model.showLog = true
            model.persistViewFlags()
            await shot("09-log-pane.png")

            say("prompts answered: \(prompter.transcript.joined(separator: " | "))")
            say("done")
            completion()
        }
    }

    /// The main window, however we can find it.
    @MainActor
    static var mainWindow: NSWindow? {
        if let window, window.contentView != nil { return window }
        return NSApp.windows.first { $0.contentView != nil && $0.frame.width > 200 && $0.sheetParent == nil }
    }

    /// Snapshot the key window (or its attached sheet) to a PNG.
    @MainActor
    static func capture(to url: URL) -> Bool {
        guard let base = mainWindow else {
            print("SELF-TEST: capture failed - no window (windows: \(NSApp.windows.count))")
            return false
        }
        let target = base.attachedSheet ?? base
        guard let view = target.contentView else {
            print("SELF-TEST: capture failed - no content view")
            return false
        }
        target.displayIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            print("SELF-TEST: capture failed - empty bounds \(bounds)")
            return false
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            print("SELF-TEST: capture failed - no bitmap rep")
            return false
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("SELF-TEST: capture failed - no PNG data")
            return false
        }
        do {
            try data.write(to: url)
            return true
        } catch {
            print("SELF-TEST: capture failed - \(error)")
            return false
        }
    }
}

/// Auto-answers the flows' message boxes and records what it was asked.
@MainActor
final class ScriptedPrompter: UserPrompting {
    var answerConfirm = true
    var answerAbortRetryIgnore: AbortRetryIgnore = .ignore
    private(set) var transcript: [String] = []

    func warn(title: String, message: String) {
        transcript.append("warn[\(title)] \(message.replacingOccurrences(of: "\n", with: " "))")
        print("SELF-TEST: prompt warn [\(title)] \(message.replacingOccurrences(of: "\n", with: " "))")
    }

    func confirm(title: String, message: String) -> Bool {
        transcript.append("confirm[\(title)] \(message.replacingOccurrences(of: "\n", with: " ")) -> \(answerConfirm ? "OK" : "Cancel")")
        print("SELF-TEST: prompt confirm [\(title)] \(message.replacingOccurrences(of: "\n", with: " ")) -> \(answerConfirm ? "OK" : "Cancel")")
        return answerConfirm
    }

    func abortRetryIgnore(title: String, message: String) -> AbortRetryIgnore {
        transcript.append("abortRetryIgnore[\(title)] -> \(answerAbortRetryIgnore)")
        return answerAbortRetryIgnore
    }
}
