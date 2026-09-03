import Foundation
import OmApi
import OmGuiCore

@MainActor
enum Commands {

    // MARK: - status

    /// OMGUI's device list, as a text table: Device | Session Id | Battery | Download | Recording.
    static func status(_ runner: Runner) throws {
        let devices = try runner.selectedDevices()
        for device in devices { device.update(force: true) }

        var rows: [[String]] = [["Device", "Session Id", "Battery", "Download", "Recording", "Group"]]
        for device in devices.sorted(by: { $0.deviceId < $1.deviceId }) {
            rows.append([
                FilenameTemplate.deviceIdString(device.deviceId),
                device.sessionId == .max ? "-" : FilenameTemplate.sessionIdString(device.sessionId),
                batteryText(device),
                downloadText(device),
                device.recordingDescription,
                device.category.groupName,
            ])
        }
        print(table(rows))

        if runner.options.has("--long") {
            print("")
            for device in devices.sorted(by: { $0.deviceId < $1.deviceId }) {
                print("\(FilenameTemplate.deviceIdString(device.deviceId))  \(device.serialId)")
                print("  port          \(device.port)")
                print("  volume        \(device.devicePath)")
                print("  data file     \(device.dataFilePath) (\((try? device.dataFileSize()) ?? 0) bytes)")
                if let firmware = device.firmwareVersion, let hardware = device.hardwareVersion {
                    print("  firmware      \(firmware) (hardware \(hardware))")
                }
                if let config = try? device.accelConfig() {
                    var text = "\(config.rate.displayString) Hz, ±\(config.range.rawValue) g"
                    if config.lowPower { text += ", low power" }
                    if let gyro = config.gyro, gyro != .off { text += ", gyro ±\(gyro.rawValue) dps" }
                    print("  config        \(text)")
                }
                if let difference = device.timeDifference {
                    print("  clock offset  \(String(format: "%+.1f", difference)) s")
                }
                if let metadata = try? device.metadata(), !metadata.isEmpty {
                    let named = MetadataTools.namedMap(metadata)
                    for key in named.keys.sorted() where !(named[key] ?? "").isEmpty {
                        print("  \(key.padding(toLength: 13, withPad: " ", startingAt: 0)) \(named[key] ?? "")")
                    }
                }
                if device.warning != .none { print("  warning       \(device.warning)") }
            }
        }
    }

    // MARK: - identify

    /// Flashes the LED so an operator can tell which device on the desk is which.
    static func identify(_ runner: Runner) throws {
        let devices = try runner.selectedDevices()
        let explicit = try runner.options.int("--led").map { Int32($0) }
        var failures = 0
        for device in devices {
            if let explicit {
                guard let state = LedState(rawValue: explicit) else {
                    throw CLIError.usage("--led must be -1…7")
                }
                print("\(FilenameTemplate.deviceIdString(device.deviceId)): LED \(state)")
                if !device.setLed(state) { failures += 1 }
            } else {
                print("\(FilenameTemplate.deviceIdString(device.deviceId)): flashing \(device.serialId) at \(device.port)")
                for state in [LedState.magenta, .off, .magenta, .off, .magenta] {
                    if !device.setLed(state) { failures += 1; break }
                    Thread.sleep(forTimeInterval: 0.25)
                }
                _ = device.setLed(.auto)
            }
        }
        if failures > 0 { throw CLIError.failed("\(failures) LED command(s) failed") }
    }

    // MARK: - record

    /// The OMGUI Record flow, in OMGUI's commit order:
    /// SessionId → Metadata → MaxSamples(0) → AccelConfig → SyncTime → Debug(flash) →
    /// AlwaysRecord()/SetDelays() (the last call commits).
    static func record(_ runner: Runner) throws {
        let options = runner.options
        guard let session = try options.uint32("--session") else {
            throw CLIError.usage("record needs --session <id>")
        }

        var config = AccelConfig.deviceDefault
        if let rateText = options.values["--rate"] {
            guard let rate = SampleRate(display: rateText) else {
                throw CLIError.usage("--rate must be one of \(SampleRate.allCases.map(\.displayString).joined(separator: ", "))")
            }
            config.rate = rate
        }
        if let rangeValue = try options.int("--range") {
            guard let range = AccelRange(rawValue: rangeValue) else {
                throw CLIError.usage("--range must be 2, 4, 8 or 16")
            }
            config.range = range
        }
        if let gyroValue = try options.int("--gyro") {
            guard let gyro = GyroRange(rawValue: gyroValue) else {
                throw CLIError.usage("--gyro must be 0, 125, 250, 500, 1000 or 2000")
            }
            config.gyro = gyro
        }
        config.lowPower = options.has("--low-power")
        guard config.isValidRateCode else {
            throw CLIError.usage("Low power is only defined for 12.5–400 Hz")
        }

        // Immediate (start on disconnect, never stop) versus a fixed interval.
        let immediate = options.has("--immediate") || (options.values["--start"] == nil && options.values["--stop"] == nil)
        var start = OmDateTime.zero
        var stop = OmDateTime.infinite
        if !immediate {
            guard let startText = options.values["--start"], let parsedStart = OmDateTime.parse(startText) else {
                throw CLIError.usage("--start needs \"YYYY-MM-DD HH:MM:SS\"")
            }
            guard let stopText = options.values["--stop"], let parsedStop = OmDateTime.parse(stopText) else {
                throw CLIError.usage("--stop needs \"YYYY-MM-DD HH:MM:SS\"")
            }
            guard parsedStart.raw < parsedStop.raw else {
                throw CLIError.usage("--start must be before --stop")
            }
            start = parsedStart
            stop = parsedStop
        }

        var metadata = StudyMetadata()
        for pair in options.pairs {
            guard metadata.set(pair.key, pair.value) else {
                throw CLIError.usage("Empty metadata key in \"\(pair.key)=\(pair.value)\"")
            }
        }
        let encoded = metadata.encoded
        guard encoded.utf8.count <= MetadataTools.annotationTotalLength else {
            throw CLIError.failed("Metadata is \(encoded.utf8.count) bytes; the annotation block holds \(MetadataTools.annotationTotalLength)")
        }

        let flash = options.has("--flash")
        let devices = try runner.selectedDevices()
        for device in devices { device.update(force: true) }

        // `CheckFirmware(devices)` — the blacklist the GUI has run before Record since C19 and the
        // CLI did not run at all: `omgui-cli record --session N --all` over units on CWA17_42 (the
        // one active entry) configured them silently and their recordings were truncated.
        try runner.preflight(devices)

        var failures: [String] = []

        for device in devices {
            let label = FilenameTemplate.deviceIdString(device.deviceId)

            var deviceConfig = config
            if !device.hasSyncGyro { deviceConfig.gyro = nil }   // OMGUI ignores gyro on an AX3

            do {
                guard device.setSessionId(session, commit: false) else { throw CLIError.failed("session id") }
                if !encoded.isEmpty { try device.setMetadata(encoded) }
                try device.setMaxSamples(0)
                try device.setAccelConfig(deviceConfig)
                if !device.syncTime() { throw CLIError.failed("time sync") }
                _ = device.setDebug(flash ? 3 : 0)
                let committed = immediate ? device.alwaysRecord() : device.setInterval(start: start, stop: stop)
                guard committed else { throw CLIError.failed("commit") }

                var summary = "\(label): session \(session), \(deviceConfig.rate.displayString) Hz, ±\(deviceConfig.range.rawValue) g"
                if let gyro = deviceConfig.gyro, gyro != .off { summary += ", gyro ±\(gyro.rawValue) dps" }
                summary += immediate ? ", start on disconnect" : ", \(start) → \(stop)"
                if flash { summary += ", flashing" }
                print(summary)
            } catch {
                failures.append("\(label): \(error)")
            }
        }

        if !failures.isEmpty {
            for failure in failures { FileHandle.standardError.write(Data("ERROR \(failure)\n".utf8)) }
            throw CLIError.failed("\(failures.count) of \(devices.count) device(s) failed to configure")
        }
    }

    // MARK: - download

    static func download(_ runner: Runner) throws {
        let options = runner.options
        guard let workspacePath = options.values["--workspace"] else {
            throw CLIError.usage("download needs --workspace <dir>")
        }
        let workspace = URL(fileURLWithPath: (workspacePath as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let template = options.values["--template"] ?? FilenameTemplate.defaultTemplate

        let devices = try runner.selectedDevices()
        let watcher = DownloadWatcher(verbose: !options.has("--quiet"))
        runner.api.onDeviceChanged = { device, status in
            watcher.handle(device, status: status, finalPath: nil)
        }

        var started: [OmDevice] = []
        var failures: [String] = []

        for device in devices {
            device.update(force: true)
            let label = FilenameTemplate.deviceIdString(device.deviceId)

            // `DownloadFlow.resolve` — the same resolution the GUI's Download button runs: the
            // three state guards, the unreadable-file case and *both* identity comparisons.
            // Re-implementing them here kept two holes the shared version has closed: a device
            // whose SESSION read had failed (`sessionId == .max`) was exempted from the session
            // comparison and filed its data under the file's own session id, and a file that would
            // not open at all skipped both comparisons because neither value could be read.
            let paths: DownloadPlan
            switch DownloadFlow.resolve(device: device, template: template, workspace: workspace) {
            case .plan(let resolved):
                paths = resolved
            case .failure(let reason):
                guard options.has("--force"), DownloadFlow.isIdentityFailure(reason) else {
                    failures.append("\(label): \(reason)")
                    continue
                }
                FileHandle.standardError.write(Data("WARNING \(label): \(reason) (--force)\n".utf8))
                paths = DownloadFlow.plan(device: device, template: template, workspace: workspace)
            }

            if FileManager.default.fileExists(atPath: paths.finalPath.path) && !options.has("--overwrite") {
                failures.append("\(label): \(paths.finalPath.lastPathComponent) already exists (pass --overwrite)")
                continue
            }
            try? FileManager.default.removeItem(at: paths.partialPath)
            try? FileManager.default.removeItem(at: paths.finalPath)

            print("\(label): downloading \((try? device.dataFileSize()) ?? 0) bytes to \(paths.finalPath.path)")
            watcher.expect(device.deviceId)
            do {
                try device.beginDownloading(to: paths.partialPath.path, renameTo: paths.finalPath.path)
                started.append(device)
            } catch {
                failures.append("\(label): \(error)")
            }
        }

        if !started.isEmpty {
            if !watcher.waitForAll() { failures.append("timed out waiting for downloads") }
            for device in started {
                let label = FilenameTemplate.deviceIdString(device.deviceId)
                switch watcher.result(for: device.deviceId)?.status {
                case .complete:
                    print("\(label): DOWNLOAD-OK")
                case .cancelled:
                    failures.append("\(label): cancelled")
                case .error:
                    failures.append("\(label): download error \(watcher.result(for: device.deviceId)?.value ?? 0)")
                default:
                    failures.append("\(label): download did not finish")
                }
            }
        }

        if !failures.isEmpty {
            for failure in failures { FileHandle.standardError.write(Data("ERROR \(failure)\n".utf8)) }
            throw CLIError.failed("\(failures.count) device(s) not downloaded")
        }
        if started.isEmpty { throw CLIError.failed("Nothing to download") }
    }

    // MARK: - clear

    /// OMGUI's Clear. Default is a full NAND wipe; `--quick` is OMGUI's Shift-click quick format.
    ///
    /// Every guard OMGUI's Clear button has, in its order: no implicit "all devices", nothing
    /// downloading (`EnsureNoSelectedDownloading`), the toolbar's recording-with-data exclusion
    /// (`ClearGuard`), `CheckFirmware`, and an explicit confirmation that defaults to no. This
    /// erases participant data that is not recoverable, so the default has to be refusal.
    static func clear(_ runner: Runner) throws {
        let options = runner.options
        let quick = options.has("--quick")

        guard !options.deviceIds.isEmpty || options.has("--all") else {
            throw CLIError.usage("clear erases the data on a device -- name the devices with --device ID (repeatable), or pass --all for every attached device")
        }

        let devices = try runner.selectedDevices()
        for device in devices { device.update(force: true) }

        // `EnsureNoSelectedDownloading`, then the exclusion `DeviceToolbarState.clear` makes —
        // a device that is recording *and* already holds data is one the GUI's Clear button greys
        // out, because `FORMAT WC` on it destroys a recording in progress. Then `CheckFirmware`.
        try runner.preflight(devices, refuseRecordingWithData: !options.has("--force"))

        if !options.has("--yes") {
            let labels = devices.map { FilenameTemplate.deviceIdString($0.deviceId) }.joined(separator: ", ")
            let withData = devices.filter(\.hasData).count
            var question = "\(quick ? "Clear" : "Wipe") \(devices.count) device(s): \(labels)"
            if withData > 0 { question += " -- \(withData) still hold(s) data, which will be erased" }
            FileHandle.standardError.write(Data((question + ".\nContinue? [y/N] ").utf8))
            let answer = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "yes" else {
                throw CLIError.failed("Cancelled -- nothing was cleared (pass --yes to skip this question)")
            }
        }

        var failures: [String] = []
        for device in devices {
            let label = FilenameTemplate.deviceIdString(device.deviceId)
            print("\(label): \(quick ? "quick format" : "wipe")…")
            if device.clear(wipe: !quick) {
                // Read the device back rather than printing the state we asked it for.
                // `update(force:)` alone bypasses only the poll interval — the session/time/delays
                // block is gated on `validData`, already true from the pre-clear update — so a
                // device that ACKed `FORMAT WC` without resetting its session id still printed
                // "session 0". `refreshStatus()` drops `validData` first.
                device.refreshStatus()
                let metadata = (try? device.metadata()) ?? ""
                var line = "\(label): session \(device.sessionId), \(device.recordingDescription)"
                line += metadata.isEmpty ? ", metadata cleared"
                                         : ", metadata NOT cleared (\(metadata.utf8.count) bytes)"
                if let config = device.cachedAccelConfig {
                    line += ", \(config.rate.displayString) Hz ±\(config.range.rawValue) g"
                }
                if device.hasData { line += ", STILL HOLDS DATA" }
                print(line)
            } else {
                failures.append(label)
            }
        }
        if !failures.isEmpty {
            throw CLIError.failed("Failed to clear device(s): \(failures.joined(separator: ", "))")
        }
    }

    // MARK: - Formatting helpers

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// OMGUI's battery column: `NN%` or `-`, with the DAMAGED?/DISCHARGED? prefixes.
    private static func batteryText(_ device: OmDevice) -> String {
        guard let level = device.batteryLevel, level >= 0 else { return device.warning.batteryPrefix + "-" }
        return device.warning.batteryPrefix + "\(level)%"
    }

    /// OMGUI's Download column.
    private static func downloadText(_ device: OmDevice) -> String {
        switch device.downloadStatus {
        case .none: return ""
        case .error: return String(format: "Error (0x%02X)", device.downloadValue)
        case .progress: return "\(device.downloadValue)%"
        case .complete: return "Complete"
        case .cancelled: return "Cancelled"
        }
    }

    private static func table(_ rows: [[String]]) -> String {
        guard let first = rows.first else { return "" }
        var widths = first.map(\.count)
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }
        return rows.map { row in
            row.enumerated().map { index, cell in
                index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
