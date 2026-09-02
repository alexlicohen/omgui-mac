import Foundation
import OmApi

/// The three-button answer OMGUI's "possibly damaged device" alert asks for.
public enum AbortRetryIgnore: Sendable { case abort, retry, ignore }

/// The message boxes the flows put up. AppKit implements it with `NSAlert`; tests script it.
@MainActor
public protocol UserPrompting: AnyObject {
    func warn(title: String, message: String)
    /// OK / Cancel, with Cancel as the default button. Returns true for OK.
    func confirm(title: String, message: String) -> Bool
    func abortRetryIgnore(title: String, message: String) -> AbortRetryIgnore
}

/// Progress from a background flow (`BackgroundWorker.ReportProgress`). A negative percent means
/// "message only", exactly as OMGUI's `ProgressBox` treats it.
public struct ProgressReport: Sendable {
    public var percent: Int
    public var message: String
    public init(percent: Int, message: String) {
        self.percent = percent
        self.message = message
    }
}

public typealias ProgressHandler = @Sendable (ProgressReport) -> Void

/// Strings shared by the flows, quoted from `MainForm.cs`.
public enum FlowMessages {
    /// `MainForm.ADVICE`.
    public static let advice = "\n\n(If device communication problems persist, please disconnect, wait, then reconnect the device.)"

    public static let downloadFilenameTitle = "Download Filename"
    public static let deviceIdNotVerified = "The correct download file name cannot be established (device identifier not verified) -- you must reconnect the device and try again."
    public static let sessionIdNotVerified = "The correct download file name cannot be established (session identifier not verified) -- you must reconnect the device and try again."
    public static let overwriteTitle = "Overwrite File?"
    public static let downloadStatusTitle = "Download Status"
    public static let downloadInProgressTitle = "Download in progress"
    public static let errorTitle = "Error"
    public static let damagedTitle = "Warning: Device Possibly Damaged"

    public static func overwriteDownload(_ path: String) -> String {
        "Download file already exists:\n\n    \(path)\n\nOverwrite existing file?"
    }

    public static func overwriteFile(_ path: String) -> String {
        "File already exists:\n\n    \(path)\n\nOverwrite existing file?"
    }

    public static func downloadInProgress(downloading: Int, total: Int) -> String {
        "Download in progress for \(downloading) (of \(total) selected) device(s) -- cannot change configuration of these devices until download complete or cancelled."
    }

    public static func damaged(deviceId: UInt32) -> String {
        "Device \(deviceId) has a recently restarted clock yet is already appearing fully charged,\nwhich is a strong indicator that the device's clock or battery could be damaged.\n\nPlease label this device and place it aside\nuntil you have run some tests to determine its condition."
    }

    /// `"Failed operation on N device(s):\r\n" + string.Join("; ", ids) + ADVICE`.
    public static func failed(ids: [String]) -> String {
        "Failed operation on \(ids.count) device(s):\n" + ids.joined(separator: "; ") + advice
    }

    /// The record flow's per-device variant: `"id: error"` lines.
    public static func failed(details: [(id: String, error: String)]) -> String {
        var message = "Failed operation on \(details.count) device(s):\n"
        for item in details { message += "\(item.id): \(item.error)\n" }
        return message + advice
    }
}

// MARK: - Download

public struct DownloadPlan: Sendable, Equatable {
    public var deviceId: UInt32
    public var partialPath: URL
    public var finalPath: URL
}

/// The outcome of resolving one device's download file name.
public enum DownloadResolution: Sendable, Equatable {
    case plan(DownloadPlan)
    case failure(String)
}

public struct DownloadOutcome: Sendable, Equatable {
    public var started: [DownloadPlan] = []
    /// `deviceText` → error, in selection order.
    public var errors: [String: String] = [:]
    public var errorOrder: [String] = []
    /// The "Download Status" summary, or nil when everything started.
    public var summary: String?
}

/// `MainForm.toolStripButtonDownload_Click`.
@MainActor
public enum DownloadFlow {

    /// Resolve one device's download file name, or return the reason it cannot be downloaded.
    ///
    /// `now` is unused; the shape mirrors upstream so the checks stay in the same order.
    public static func resolve(device: OmDevice,
                               template: String,
                               workspace: URL) -> DownloadResolution {
        if device.isDownloading { return .failure("device is already downloading") }
        if device.isRecording != .stopped { return .failure("device is recording") }
        if !device.hasData { return .failure("device has no data") }

        let metadata = FileMetadata(path: device.dataFilePath)
        let map = metadata?.map ?? [:]

        let deviceIdString = FilenameTemplate.deviceIdString(device.deviceId)
        let fileDeviceIdString = map["DeviceId"]
        let sessionIdString = FilenameTemplate.sessionIdString(device.sessionId)
        let fileSessionIdString = map["SessionId"]

        let usedDeviceId = deviceIdString
        let usedSessionId = device.sessionId == UInt32.max
            ? (fileSessionIdString ?? "0000000000")
            : sessionIdString

        let baseName = FilenameTemplate.expand(template,
                                               deviceId: device.deviceId,
                                               sessionId: device.sessionId,
                                               fileSessionId: fileSessionIdString,
                                               metadata: map)
        let paths = FilenameTemplate.downloadPaths(workspace: workspace, baseName: baseName)

        if usedDeviceId != fileDeviceIdString {
            return .failure(DownloadFlow.deviceIdError)
        }
        if usedSessionId != sessionIdString || usedSessionId != fileSessionIdString {
            return .failure(DownloadFlow.sessionIdError)
        }
        return .plan(DownloadPlan(deviceId: device.deviceId,
                                  partialPath: paths.partial,
                                  finalPath: paths.final))
    }

    public static let deviceIdError = "Download filename (device identifier not verified)."
    public static let sessionIdError = "Download filename (session identifier not verified)."

    /// The whole button: resolve, prompt about overwrites, start each download, summarise.
    @discardableResult
    public static func run(devices: [OmDevice],
                           template: String,
                           workspace: URL,
                           prompt: any UserPrompting) -> DownloadOutcome {
        var outcome = DownloadOutcome()
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        for device in devices {
            let deviceText = FilenameTemplate.deviceIdString(device.deviceId)
            var error: String?
            var plan: DownloadPlan?

            switch resolve(device: device, template: template, workspace: workspace) {
            case .failure(let reason):
                error = reason
                if reason == deviceIdError {
                    prompt.warn(title: FlowMessages.downloadFilenameTitle, message: FlowMessages.deviceIdNotVerified)
                } else if reason == sessionIdError {
                    prompt.warn(title: FlowMessages.downloadFilenameTitle, message: FlowMessages.sessionIdNotVerified)
                }
            case .plan(let resolved):
                plan = resolved
            }

            if error == nil, let resolved = plan {
                let manager = FileManager.default
                if manager.fileExists(atPath: resolved.partialPath.path) {
                    if prompt.confirm(title: FlowMessages.overwriteTitle,
                                      message: FlowMessages.overwriteDownload(resolved.partialPath.path)) {
                        try? manager.removeItem(at: resolved.partialPath)
                    } else {
                        error = "Not overwriting existing download file."
                    }
                }
                if error == nil, manager.fileExists(atPath: resolved.finalPath.path) {
                    if prompt.confirm(title: FlowMessages.overwriteTitle,
                                      message: FlowMessages.overwriteFile(resolved.finalPath.path)) {
                        try? manager.removeItem(at: resolved.finalPath)
                    } else {
                        error = "Not overwriting existing data file."
                    }
                }
            }

            if error == nil, let resolved = plan {
                do {
                    try device.beginDownloading(to: resolved.partialPath.path,
                                                renameTo: resolved.finalPath.path)
                    outcome.started.append(resolved)
                } catch {
                    outcome.errors[deviceText] = "Unknown error"
                    outcome.errorOrder.append(deviceText)
                    continue
                }
            }

            if let error {
                outcome.errors[deviceText] = error
                outcome.errorOrder.append(deviceText)
            }
        }

        if outcome.started.count != devices.count {
            var message = "\(outcome.started.count) devices downloading:\n"
            for key in outcome.errorOrder {
                message += "\nDevice: \(key) - Status: \(outcome.errors[key] ?? "")"
            }
            outcome.summary = message
            prompt.warn(title: FlowMessages.downloadStatusTitle, message: message)
        }
        return outcome
    }
}

/// `MainForm.DownloadCompleteCallback`'s optional log file.
public enum DownloadLog {

    public static func line(at date: Date = Date(), filename: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "\(formatter.string(from: date)),DOWNLOAD-OK,\(filename)"
    }

    /// Append one line, creating the file if needed. Returns false when the write fails.
    @discardableResult
    public static func append(_ line: String, to path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                return true
            } catch {
                return false
            }
        }
        return (try? data.write(to: url)) != nil
    }
}

// MARK: - Clear / Stop / Record

/// `MainForm.EnsureNoSelectedDownloading`.
@MainActor
public func ensureNoSelectedDownloading(_ devices: [OmDevice], prompt: any UserPrompting) -> Bool {
    let downloading = devices.filter(\.isDownloading).count
    guard downloading > 0 else { return true }
    prompt.warn(title: FlowMessages.downloadInProgressTitle,
                message: FlowMessages.downloadInProgress(downloading: downloading, total: devices.count))
    return false
}

public enum ClearFlow {

    /// `wipe = (Shift NOT held)` — the default is the full NAND wipe.
    public static func wipeRequested(shiftHeld: Bool) -> Bool { !shiftHeld }

    /// `"Wipe 3 device(s)?"` / `"Clear 3 device(s)?"`.
    public static func promptMessage(wipe: Bool, count: Int) -> String {
        "\(wipe ? "Wipe" : "Clear") \(count) device(s)?"
    }

    public static func progressTitle(wipe: Bool) -> String { wipe ? "Wiping" : "Clearing" }

    /// The background body: clear each device, collecting the ids that failed.
    public static func perform(devices: [OmDevice], wipe: Bool, progress: ProgressHandler?) -> [String] {
        var fails: [String] = []
        for (index, device) in devices.enumerated() {
            progress?(ProgressReport(percent: -1,
                                     message: "\(progressTitle(wipe: wipe)) device \(index + 1) of \(devices.count)."))
            if !device.clear(wipe: wipe) { fails.append(String(device.deviceId)) }
        }
        progress?(ProgressReport(percent: 100, message: "Done"))
        return fails
    }
}

public enum StopFlow {

    /// `toolStripButtonStop_Click`'s background body.
    public static func perform(devices: [OmDevice], progress: ProgressHandler?) -> [String] {
        var fails: [String] = []
        for (index, device) in devices.enumerated() {
            guard !device.isDownloading, device.isRecording != .stopped else { continue }
            progress?(ProgressReport(percent: -1,
                                     message: "Stopping device \(index + 1) of \(devices.count)."))
            if !device.neverRecord() { fails.append(String(device.deviceId)) }
        }
        progress?(ProgressReport(percent: 100, message: "Done"))
        return fails
    }
}

/// `MainForm.toolStripButtonRecord_Click`'s background body — the five-step commit per device.
public enum RecordFlow {

    public struct Failure: Sendable, Equatable {
        public var id: String
        public var error: String
    }

    public struct Result: Sendable, Equatable {
        public var failures: [Failure] = []
        /// One `AX3-CONFIG-OK` / `AX3-CONFIG-ERROR` line per device.
        public var logLines: [String] = []
    }

    /// `DATAMODE=20` is what OMGUI writes to `SETTINGS.INI` for unpacked data on an AX3.
    public static let unpackedSettings = "DATAMODE=20\r\n"

    public static func configLogLine(at date: Date,
                                     ok: Bool,
                                     deviceId: UInt32,
                                     settings: RecordingSettings) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let type = ok ? "AX3-CONFIG-OK" : "AX3-CONFIG-ERROR"
        let start: String
        let stop: String
        if settings.immediately {
            start = "0"
            stop = "-1"
        } else {
            start = stamp.string(from: settings.startDate)
            stop = stamp.string(from: settings.endDate)
        }
        let metadata = settings.encodedMetadata
        let quoted = metadata.isEmpty ? "" : "\"" + metadata.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        return "\(stamp.string(from: date)),\(type),\(deviceId),\(settings.sessionId),\(start),\(stop),\(settings.samplingFrequency),\(settings.accelRange.rawValue),\(quoted)"
    }

    public static func perform(devices: [OmDevice],
                               settings: RecordingSettings,
                               progress: ProgressHandler?,
                               now: @Sendable () -> Date = { Date() }) -> Result {
        var result = Result()
        let total = max(devices.count, 1)

        for (index, device) in devices.enumerated() {
            var deviceError: String?
            let message = "Configuring device \(index + 1) of \(devices.count).... "
            func report(_ step: Int, _ suffix: String) {
                progress?(ProgressReport(percent: 100 * (5 * index + step) / (total * 5),
                                         message: message + "(\(suffix))"))
            }

            if device.isDownloading {
                deviceError = "Device is downloading"
            } else {
                let devicePath = device.devicePath

                report(0, "session")
                if deviceError == nil, !device.setSessionId(settings.sessionId, commit: false) {
                    deviceError = "Failed to set session ID"
                }

                report(1, "metadata")
                let metadata = settings.encodedMetadata
                if deviceError == nil, !metadata.isEmpty {
                    do { try device.setMetadata(metadata) } catch { deviceError = "Metadata set failed" }
                }

                // "Check 'max samples' is always zero" — upstream ignores the result.
                try? device.setMaxSamples(0)

                report(2, "config")
                if deviceError == nil {
                    do { try device.setAccelConfig(settings.accelConfig) } catch { deviceError = "Sensor config failed" }
                }

                report(3, "time sync")
                if deviceError == nil, device.connected, !device.syncTime() {
                    deviceError = "Time sync. failed"
                }

                if device.connected { device.setDebug(settings.flash ? 3 : 0) }

                report(4, "interval")
                if deviceError == nil {
                    if settings.immediately {
                        if !device.alwaysRecord() { deviceError = "Set interval (always) failed" }
                    } else {
                        let start = OmDateTime(date: settings.startDate)
                        let stop = OmDateTime(date: settings.endDate)
                        if !device.setInterval(start: start, stop: stop) { deviceError = "Set interval failed" }
                    }
                }

                if settings.unpacked, !device.hasSyncGyro {
                    report(4, "unpacked setting")
                    if devicePath.isEmpty {
                        deviceError = "Failed to find drive to write configuration file."
                    } else if !writeUnpackedSettings(to: devicePath) {
                        deviceError = "Failed to write unpacked configuration file."
                    }
                }
            }

            if let deviceError {
                result.failures.append(Failure(id: String(device.deviceId), error: deviceError))
            }
            result.logLines.append(configLogLine(at: now(), ok: deviceError == nil,
                                                 deviceId: device.deviceId, settings: settings))
        }

        progress?(ProgressReport(percent: 100, message: "Done"))
        return result
    }

    /// Wait for the volume to re-mount, then write `SETTINGS.INI` (upstream: 0.8 s, then 60 tries
    /// at 250 ms).
    static func writeUnpackedSettings(to devicePath: String,
                                      retries: Int = 60,
                                      initialDelay: TimeInterval = 0.8,
                                      retryDelay: TimeInterval = 0.25) -> Bool {
        Thread.sleep(forTimeInterval: initialDelay)
        let configFile = (devicePath as NSString).appendingPathComponent("SETTINGS.INI")
        for _ in 0..<retries {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: devicePath, isDirectory: &isDirectory), isDirectory.boolValue {
                if (try? unpackedSettings.write(toFile: configFile, atomically: false, encoding: .ascii)) != nil {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: retryDelay)
        }
        return false
    }
}

/// `MainForm`'s identify task: 10 ticks at 2 Hz, alternating blue/magenta, then back to auto.
public struct IdentifyController: Sendable {
    public static let initialTicks = 10
    /// The identify task latches every fifth 100 ms timer tick.
    public static let tickInterval: TimeInterval = 0.5

    public private(set) var ticks = 0

    public init() {}

    public var isRunning: Bool { ticks > 0 }

    public mutating func start() { ticks = IdentifyController.initialTicks }

    /// One tick: decrement, then return the LED state to write.
    public mutating func advance() -> LedState {
        ticks -= 1
        if ticks <= 0 {
            ticks = 0
            return .auto
        }
        return (ticks & 1) == 1 ? .blue : .magenta
    }
}
