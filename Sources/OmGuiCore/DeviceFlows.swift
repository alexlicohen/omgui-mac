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

    /// Not an upstream string. Windows cannot fail this way, so OMGUI folds "the file will not
    /// open at all" into the identity-mismatch message above — which on macOS sends a site round a
    /// loop of reconnecting a device whose data file was never the problem.
    public static func dataFileUnreadable(_ path: String) -> String {
        "The device's data file could not be read:\n\n    \(path)\n\n"
            + "Reconnecting the device will not help. If macOS has not been given access to "
            + "removable volumes, allow it in System Settings ▸ Privacy & Security ▸ Files and "
            + "Folders ▸ Removable Volumes (or grant Full Disk Access), then try again. "
            + "Otherwise the recording on this device may be damaged."
    }

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

        // A file that will not open at all is a different failure from one whose identity does not
        // match: the mismatch message tells the operator to reconnect the device, which can never
        // fix a denied removable-volume prompt or a damaged file.
        guard let metadata = FileMetadata(path: device.dataFilePath) else {
            return .failure(DownloadFlow.unreadableFileError)
        }
        let map = metadata.map

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
    public static let unreadableFileError = "Device data file could not be read."

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
                } else if reason == unreadableFileError {
                    prompt.warn(title: FlowMessages.downloadFilenameTitle,
                                message: FlowMessages.dataFileUnreadable(device.dataFilePath))
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
        /// The devices the configuration reached without error, in the order they were written.
        public var configured: [UInt32] = []
    }

    /// The confirmation a site copies into their study's data platform ("Date recording initiated
    /// in OMGUI", per the study MOP).
    ///
    /// Not an upstream string: OMGUI logs only the `AX3-CONFIG-OK` CSV row, which is not something
    /// a site can read off the screen. This line goes to the Log pane and the status bar.
    public static let confirmationDateFormat = "yyyy-MM-dd HH:mm:ss"

    public static func confirmationLine(deviceId: UInt32, sessionId: UInt32, at date: Date) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = confirmationDateFormat
        return "Recording configured on \(FilenameTemplate.deviceIdString(deviceId)): "
            + "session \(sessionId), \(stamp.string(from: date))"
    }

    /// `DATAMODE=20` is what OMGUI writes to `SETTINGS.INI` for unpacked data on an AX3.
    public static let unpackedSettings = "DATAMODE=20\r\n"

    /// The waits around the `SETTINGS.INI` write (upstream: 0.8 s, then 60 tries at 250 ms).
    public struct Timing: Sendable, Equatable {
        public var unpackedInitialDelay: TimeInterval
        public var unpackedRetries: Int
        public var unpackedRetryDelay: TimeInterval

        public init(unpackedInitialDelay: TimeInterval, unpackedRetries: Int, unpackedRetryDelay: TimeInterval) {
            self.unpackedInitialDelay = unpackedInitialDelay
            self.unpackedRetries = unpackedRetries
            self.unpackedRetryDelay = unpackedRetryDelay
        }

        public static let upstream = Timing(unpackedInitialDelay: 0.8, unpackedRetries: 60,
                                            unpackedRetryDelay: 0.25)
        /// For tests, where the mock volume never goes away.
        public static let fast = Timing(unpackedInitialDelay: 0, unpackedRetries: 4,
                                        unpackedRetryDelay: 0.01)
    }

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
                               timing: Timing = .upstream,
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
                    // The commit re-enumerates the unit, and macOS can bring it back at a
                    // different mount point (`/Volumes/AX317_01234 1`) while an empty directory
                    // lingers at the old one — so resolve the path again, every try, rather than
                    // reusing the one captured before the device was configured.
                    if !writeUnpackedSettings(resolvingPathWith: { device.refreshInfo()?.volumePath ?? device.devicePath },
                                              retries: timing.unpackedRetries,
                                              initialDelay: timing.unpackedInitialDelay,
                                              retryDelay: timing.unpackedRetryDelay) {
                        deviceError = device.devicePath.isEmpty
                            ? "Failed to find drive to write configuration file."
                            : "Failed to write unpacked configuration file."
                    }
                }
            }

            if let deviceError {
                result.failures.append(Failure(id: String(device.deviceId), error: deviceError))
            } else {
                result.configured.append(device.deviceId)
            }
            result.logLines.append(configLogLine(at: now(), ok: deviceError == nil,
                                                 deviceId: device.deviceId, settings: settings))
        }

        progress?(ProgressReport(percent: 100, message: "Done"))
        return result
    }

    /// The device's data file, which is what proves a `/Volumes` directory really is the device
    /// and not a stale mount point left behind by the re-enumeration.
    public static let deviceDataFileName = "CWA-DATA.CWA"

    /// Wait for the volume to re-mount, then write `SETTINGS.INI` (upstream: 0.8 s, then 60 tries
    /// at 250 ms).
    ///
    /// `resolvePath` is re-asked on every try, and the directory only counts once `CWA-DATA.CWA`
    /// is in it: writing `DATAMODE=20` into an empty leftover mount point "succeeds" while the
    /// device goes on recording packed data the pipeline cannot read.
    @discardableResult
    static func writeUnpackedSettings(resolvingPathWith resolvePath: () -> String,
                                      retries: Int = 60,
                                      initialDelay: TimeInterval = 0.8,
                                      retryDelay: TimeInterval = 0.25) -> Bool {
        if initialDelay > 0 { Thread.sleep(forTimeInterval: initialDelay) }
        for attempt in 0..<max(1, retries) {
            let devicePath = resolvePath()
            if !devicePath.isEmpty {
                var isDirectory: ObjCBool = false
                let dataFile = (devicePath as NSString).appendingPathComponent(deviceDataFileName)
                if FileManager.default.fileExists(atPath: devicePath, isDirectory: &isDirectory),
                   isDirectory.boolValue,
                   FileManager.default.fileExists(atPath: dataFile) {
                    let configFile = (devicePath as NSString).appendingPathComponent("SETTINGS.INI")
                    if (try? unpackedSettings.write(toFile: configFile, atomically: false, encoding: .ascii)) != nil {
                        return true
                    }
                }
            }
            if attempt + 1 < max(1, retries) { Thread.sleep(forTimeInterval: retryDelay) }
        }
        return false
    }

    /// Fixed-path form, for a caller that already knows where the volume is.
    @discardableResult
    static func writeUnpackedSettings(to devicePath: String,
                                      retries: Int = 60,
                                      initialDelay: TimeInterval = 0.8,
                                      retryDelay: TimeInterval = 0.25) -> Bool {
        writeUnpackedSettings(resolvingPathWith: { devicePath }, retries: retries,
                              initialDelay: initialDelay, retryDelay: retryDelay)
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

// MARK: - Firmware

/// `MainForm.CheckFirmware`'s blacklist half: the `firmware/bootload.ini` lookup that warns before
/// Record and before Clear when a device is running a firmware version marked for update.
///
/// The bootloader half is not ported — the updater is a Windows `.cmd` driving a Windows-only
/// bootloader — so where upstream offers to update, this offers the operator the choice to carry
/// on or stop.
public struct FirmwareBlacklist: Sendable, Equatable {

    /// One blacklisted `<prefix>_<version>`, e.g. `CWA17_42`.
    public struct Entry: Sendable, Equatable {
        /// The blacklisted version key, e.g. `"CWA17_42"`.
        public var version: String
        /// `[section]` the key was found under, e.g. `"CWA17"`.
        public var section: String
        /// The section's `_version`, e.g. `"CWA17_45"`; nil when the file does not name one.
        public var latest: String?
        /// The value after `=`, or upstream's fallback wording when it is empty.
        public var reason: String

        public init(version: String, section: String, latest: String?, reason: String) {
            self.version = version
            self.section = section
            self.latest = latest
            self.reason = reason.trimmingCharacters(in: .whitespaces).isEmpty
                ? FirmwareBlacklist.defaultReason : reason
        }
    }

    /// `"The current version of the firmware is marked as needing an update."`
    public static let defaultReason = "The current version of the firmware is marked as needing an update."

    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) { self.entries = entries }

    /// `firmware/bootload.ini` as upstream ships it, so the check works before the file does.
    ///
    /// Kept in code because the app bundle's `Resources/` is not this port's to add to yet; a real
    /// `firmware/bootload.ini` found on disk replaces it wholesale.
    public static let builtIn = FirmwareBlacklist.parse("""
        [CWA17]
        _version=CWA17_45
        CWA17_42=V42 is known to have a potential problem which can limit the recording duration.

        [AX664]
        _version=AX664_51
        """)

    /// Where upstream looks: `firmware/bootload.ini` under the current directory, then under the
    /// executable's folder. The bundle's `Resources/firmware/bootload.ini` is the Mac equivalent.
    public static func searchPaths(bundleResources: URL? = Bundle.main.resourceURL,
                                   executable: URL? = Bundle.main.executableURL) -> [URL] {
        var paths: [URL] = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("firmware/bootload.ini")]
        if let executable {
            paths.append(executable.deletingLastPathComponent().appendingPathComponent("firmware/bootload.ini"))
        }
        if let bundleResources {
            paths.append(bundleResources.appendingPathComponent("firmware/bootload.ini"))
        }
        return paths
    }

    /// The first readable `bootload.ini` in `paths`, or the built-in table.
    public static func load(paths: [URL] = FirmwareBlacklist.searchPaths()) -> FirmwareBlacklist {
        for path in paths {
            if let text = try? String(contentsOf: path, encoding: .utf8) { return parse(text) }
        }
        return builtIn
    }

    /// Upstream's "rough .INI parser", including its `=`-or-`:` split and its `_name` convention.
    public static func parse(_ text: String) -> FirmwareBlacklist {
        var latestVersion: [String: String] = [:]
        var found: [(name: String, section: String, value: String)] = []
        var section = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }
            guard let separator = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
            let name = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("_") {
                if name == "_version" { latestVersion[section] = value }
            } else {
                found.append((name, section, value))
            }
        }
        var entries: [String: Entry] = [:]
        for item in found {
            entries[item.name] = Entry(version: item.name, section: item.section,
                                       latest: latestVersion[item.section], reason: item.value)
        }
        return FirmwareBlacklist(entries: entries)
    }

    /// `prefix + firmwareVersion`, where the prefix is the serial up to and including its `_`.
    public static func versionKey(serialId: String, firmwareVersion: Int) -> String {
        var prefix = "XXX00_"
        if let underscore = serialId.firstIndex(of: "_") {
            prefix = String(serialId[serialId.startIndex...underscore])
        }
        return prefix + String(firmwareVersion)
    }

    public func entry(serialId: String, firmwareVersion: Int?) -> Entry? {
        guard let firmwareVersion else { return nil }
        return entries[FirmwareBlacklist.versionKey(serialId: serialId, firmwareVersion: firmwareVersion)]
    }

    public static let title = "Firmware Update Recommended"

    /// The message body, following `MainForm.cs`'s wording as far as the port can honour it.
    public static func message(deviceId: UInt32, entry: Entry) -> String {
        var text = "Device \(deviceId) is running firmware version \(entry.version).\n\n\(entry.reason)\n\n"
        if let latest = entry.latest {
            text += "The recommended version is \(latest), but the firmware updater is Windows-only "
                + "and is not part of this port, so the device cannot be updated here.\n\n"
        } else {
            text += "The firmware updater is Windows-only and is not part of this port, so the "
                + "device cannot be updated here.\n\n"
        }
        return text + "Continue with this device anyway?"
    }
}

/// `CheckFirmware(devices)` — returns true when the caller should stop, exactly as upstream's
/// "Don't do anything else now (user can press button again)".
///
/// Devices whose firmware version has not been read yet are skipped rather than re-polled: the
/// poll thread owns device I/O (a blocking `ID` command from the main thread is what makes the
/// property grid collide with a running flow), so an unknown version cannot be checked here.
@MainActor
@discardableResult
public func checkFirmware(_ devices: [OmDevice],
                          blacklist: FirmwareBlacklist,
                          prompt: any UserPrompting,
                          log: ((String) -> Void)? = nil) -> Bool {
    for device in devices {
        guard let entry = blacklist.entry(serialId: device.serialId,
                                          firmwareVersion: device.firmwareVersion) else {
            if device.firmwareVersion == nil {
                log?("FIRMWARE: device \(device.deviceId) firmware version unknown (not checked).")
            }
            continue
        }
        log?("FIRMWARE: device \(device.deviceId) is running \(entry.version)"
             + (entry.latest.map { " - recommended \($0)" } ?? "") + " (\(entry.reason))")
        if !prompt.confirm(title: FirmwareBlacklist.title,
                           message: FirmwareBlacklist.message(deviceId: device.deviceId, entry: entry)) {
            return true
        }
    }
    return false
}
