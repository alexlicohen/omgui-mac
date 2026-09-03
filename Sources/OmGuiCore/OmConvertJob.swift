import Foundation

// MARK: - .NET path helpers

/// The two `System.IO.Path` members OMGUI's export code depends on.
public enum DotNetPath {

    /// `Path.ChangeExtension` — replace everything from the last `.` in the final path component.
    /// `"a/b.c.cwa"` + `".svm.csv"` is `"a/b.c.svm.csv"`, and a name with no dot simply gains one.
    public static func changeExtension(_ path: String, _ newExtension: String) -> String {
        var index = path.endIndex
        while index > path.startIndex {
            let previous = path.index(before: index)
            let character = path[previous]
            if character == "." { return String(path[path.startIndex..<previous]) + newExtension }
            if character == "/" { break }
            index = previous
        }
        return path + newExtension
    }

    /// `Path.GetFileName`.
    public static func fileName(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}

// MARK: - Arguments

/// What a job runs: one of the bundled helpers, or a plugin's own run file.
public enum ToolExecutable: Sendable, Equatable {
    case helper(HelperTool)
    case path(String)
}

/// One command-line argument. `Process` is handed the raw value; `literal` reproduces the string
/// upstream builds for `ProcessStartInfo.Arguments`, which is what the unit tests compare against.
public enum ToolArgument: Sendable, Equatable {
    case plain(String)
    case quoted(String)

    public var value: String {
        switch self {
        case .plain(let text), .quoted(let text): return text
        }
    }

    public var literal: String {
        switch self {
        case .plain(let text): return text
        case .quoted(let text): return "\"" + text + "\""
        }
    }
}

/// A single helper run: what to execute, with what, and where the result lands.
public struct ToolInvocation: Sendable, Equatable {
    public var executable: ToolExecutable
    public var argumentList: [ToolArgument]
    /// The file the helper is told to write. `nil` when it writes straight to `finalPath`
    /// (`ExportForm` does; every `ProcessingForm` caller writes `<final>.part` first).
    public var outputPath: String?
    /// Where the output ends up once the job succeeds.
    public var finalPath: String
    /// The file the helper reads (a `.cwa`, or the intermediate `.wav` for the analyses).
    public var inputPath: String
    /// The directory the process runs in, when the job needs one (plugins).
    public var workingDirectory: String?
    /// Set when the executable must not be launched at all — a plugin whose run file escapes its
    /// folder, is not executable, or is still quarantined. `ToolProcess` reports it instead of
    /// spawning, so the queue row fails with a message rather than a bare non-zero exit
    /// (`refs/10-deep-review.md` C24).
    public var refusal: String?

    public init(executable: ToolExecutable,
                argumentList: [ToolArgument],
                outputPath: String?,
                finalPath: String,
                inputPath: String,
                workingDirectory: String? = nil,
                refusal: String? = nil) {
        self.executable = executable
        self.argumentList = argumentList
        self.outputPath = outputPath
        self.finalPath = finalPath
        self.inputPath = inputPath
        self.workingDirectory = workingDirectory
        self.refusal = refusal
    }

    /// argv, unquoted — `Process` does not go through a shell.
    public var arguments: [String] { argumentList.map(\.value) }

    /// `string.Join(" ", args)`: byte-for-byte what OMGUI passes to `ProcessStartInfo.Arguments`.
    public var commandLine: String { argumentList.map(\.literal).joined(separator: " ") }
}

// MARK: - The tools

/// Every omconvert/cwa-convert command OMGUI builds, in the order `MainForm` builds them.
///
/// Each `input` is the `.cwa` the user selected; the analyses actually read the `.wav` that
/// `CheckWavConversion` makes first, and every output extension is derived from the `.cwa` with
/// `Path.ChangeExtension` exactly as upstream does.
public enum OmConvertJob {

    public static let partSuffix = ".part"

    /// `DoWavConvert` — also the resample that `CheckWavConversion` runs before every analysis
    /// (with `rate = -1`, `calibrate = true`).
    ///
    /// `"<in>" [-resample <rate>] -calibrate <0|1> -out "<out>"`
    ///
    /// Upstream's `ext` parameter is ignored inside `DoWavConvert`, so "Export Resampled WAV..."
    /// writes `<name>.wav` even though the overwrite check looked at `<name>.resampled.wav`. The
    /// port keeps that behaviour; see `refs/07-phase3b-notes.md`.
    public static func wav(input: String, rate: Int, calibrate: Bool) -> ToolInvocation {
        let final = DotNetPath.changeExtension(input, ".wav")
        let output = final + partSuffix
        var args: [ToolArgument] = [.quoted(input)]
        if rate > 0 {
            args.append(.plain("-resample"))
            args.append(.plain("\(rate)"))
        }
        args.append(.plain("-calibrate"))
        args.append(.plain(calibrate ? "1" : "0"))
        args.append(.plain("-out"))
        args.append(.quoted(output))
        return ToolInvocation(executable: .helper(.omconvert), argumentList: args,
                              outputPath: output, finalPath: final, inputPath: input)
    }

    /// `svmToolStripMenuItem_Click` —
    /// `"<wav>" -svm-epoch <e> -svm-filter <f> -svm-mode <m> -svm-file "<out>"`.
    public static func svm(input cwa: String, epoch: Int, filter: Int, mode: Int) -> ToolInvocation {
        let wav = DotNetPath.changeExtension(cwa, ".wav")
        let final = DotNetPath.changeExtension(cwa, ".svm.csv")
        let output = final + partSuffix
        let args: [ToolArgument] = [
            .quoted(wav),
            .plain("-svm-epoch"), .plain("\(epoch)"),
            .plain("-svm-filter"), .plain("\(filter)"),
            .plain("-svm-mode"), .plain("\(mode)"),
            .plain("-svm-file"), .quoted(output),
        ]
        return ToolInvocation(executable: .helper(.omconvert), argumentList: args,
                              outputPath: output, finalPath: final, inputPath: wav)
    }

    /// `cutPointsToolStripMenuItem_Click` —
    /// `"<wav>" -paee-epoch <e> -paee-model "<model>" -paee-filter <f> -paee-file "<out>"`.
    public static func cutPoints(input cwa: String, epoch: Int, model: String, filter: Int) -> ToolInvocation {
        let wav = DotNetPath.changeExtension(cwa, ".wav")
        let final = DotNetPath.changeExtension(cwa, ".cut.csv")
        let output = final + partSuffix
        let args: [ToolArgument] = [
            .quoted(wav),
            .plain("-paee-epoch"), .plain("\(epoch)"),
            .plain("-paee-model"), .quoted(model),
            .plain("-paee-filter"), .plain("\(filter)"),
            .plain("-paee-file"), .quoted(output),
        ]
        return ToolInvocation(executable: .helper(.omconvert), argumentList: args,
                              outputPath: output, finalPath: final, inputPath: wav)
    }

    /// `wearTimeToolStripMenuItem_Click` — `"<wav>" -wtv-epoch <e> -wtv-file "<out>"`.
    public static func wearTime(input cwa: String, epoch: Int) -> ToolInvocation {
        let wav = DotNetPath.changeExtension(cwa, ".wav")
        let final = DotNetPath.changeExtension(cwa, ".wtv.csv")
        let output = final + partSuffix
        let args: [ToolArgument] = [
            .quoted(wav),
            .plain("-wtv-epoch"), .plain("\(epoch)"),
            .plain("-wtv-file"), .quoted(output),
        ]
        return ToolInvocation(executable: .helper(.omconvert), argumentList: args,
                              outputPath: output, finalPath: final, inputPath: wav)
    }

    /// `toolStripButtonSleep_Click` — `"<wav>" -sleep-file "<out>"`.
    public static func sleep(input cwa: String) -> ToolInvocation {
        let wav = DotNetPath.changeExtension(cwa, ".wav")
        let final = DotNetPath.changeExtension(cwa, ".sleep.csv")
        let output = final + partSuffix
        let args: [ToolArgument] = [
            .quoted(wav),
            .plain("-sleep-file"), .quoted(output),
        ]
        return ToolInvocation(executable: .helper(.omconvert), argumentList: args,
                              outputPath: output, finalPath: final, inputPath: wav)
    }

    /// `toolStripButtonCSV_Click_1` — `"<wav>" -csv-file "<out>"`.
    public static func resampledCsv(input cwa: String) -> ToolInvocation {
        let wav = DotNetPath.changeExtension(cwa, ".wav")
        let final = DotNetPath.changeExtension(cwa, ".resampled.csv")
        let output = final + partSuffix
        let args: [ToolArgument] = [
            .quoted(wav),
            .plain("-csv-file"), .quoted(output),
        ]
        return ToolInvocation(executable: .helper(.omconvert), argumentList: args,
                              outputPath: output, finalPath: final, inputPath: wav)
    }

    /// `ExportForm.buttonConvert_Click` — the raw CSV export, which runs `cwa-convert`, not
    /// `omconvert`, and writes its output file directly (there is no `.part` step upstream).
    public static func rawCsv(_ options: RawCsvOptions) -> ToolInvocation {
        var args: [ToolArgument] = [
            .quoted(options.sourceFile),
            .plain("-f:csv"),
            .plain("-out"), .quoted(options.outputFile),
        ]
        args.append(.plain(options.stream.flag))
        args.append(.plain(options.values.flag))
        args.append(.plain(options.timestamp.flag))
        if !options.sampleStart.isEmpty { args.append(.plain("-start")); args.append(.plain(options.sampleStart)) }
        if !options.sampleLength.isEmpty { args.append(.plain("-length")); args.append(.plain(options.sampleLength)) }
        if !options.sampleStep.isEmpty { args.append(.plain("-step")); args.append(.plain(options.sampleStep)) }
        if !options.blockStart.isEmpty { args.append(.plain("-blockstart")); args.append(.plain(options.blockStart)) }
        if !options.blockCount.isEmpty { args.append(.plain("-blockcount")); args.append(.plain(options.blockCount)) }
        return ToolInvocation(executable: .helper(.cwaConvert), argumentList: args,
                              outputPath: nil, finalPath: options.outputFile,
                              inputPath: options.sourceFile)
    }
}

// MARK: - Dialog models

/// `ExportWavForm` — "Resample to .WAV".
public struct WavExportOptions: Sendable, Equatable {
    /// `comboBoxRate.Items`, with `"auto"` selected (`comboBoxRate.Text = "auto"`).
    public static let rates = ["auto", "25", "40", "50", "80", "100"]

    public var rateText: String = "auto"
    /// `checkBoxAutoCalibrate.Checked = true`.
    public var autoCalibrate = true

    public init() {}

    /// `ExportWavForm.Rate` — `int.TryParse` leaves the seeded `-1` for "auto".
    public var rate: Int { Int(rateText) ?? -1 }
}

/// `ExportSvmForm` — "SVM".
public struct SvmExportOptions: Sendable, Equatable {
    public static let epochs = ["1", "2", "3", "4", "5", "6", "10", "12", "15", "20", "30",
                                "60", "120", "300", "600", "1800", "3600"]
    public static let filters = ["none", "BP 0.5-20Hz"]
    public static let modes = ["abs(sqrt(x^2+y^2+z^2)-1)", "max(0,sqrt(x^2+y^2+z^2)-1)"]

    /// `comboBoxRate.Text = "60"`.
    public var epochText = "60"
    /// `comboBoxFilter.SelectedIndex = 1`.
    public var filter = 1
    /// `comboBoxMode.SelectedIndex = 0`.
    public var mode = 0

    public init() {}

    /// `ExportSvmForm.Epoch` — the seed is 60, so an unparsable text keeps 60.
    public var epoch: Int { Int(epochText) ?? 60 }
}

/// `ExportPaeeForm` — "Cut-point Analysis".
public struct CutPointsOptions: Sendable, Equatable {
    /// `comboBoxRate.Items` (epochs are `* 60 s`).
    public static let epochs = ["1", "2", "3", "4", "5", "6", "10", "12", "15", "20", "30",
                                "60", "120", "240", "300", "360", "720", "1440"]
    public static let filters = ["none", "BP 0.5-20Hz (compatible with V42 and earlier)"]
    /// `comboBox1.Items` — passed to omconvert verbatim; it parses the values after the `:`.
    public static let models = [
        "'wrist':                386/80/60 542/80/60 1811/80/60",
        "Esliger(40-63)-wristR:  386/80/60 440/80/60 2099/80/60",
        "Esliger(40-63)-wristL:  217/80/60 645/80/60 1811/80/60",
        "Esliger(40-63)-waist:    77/80/60 220/80/60 2057/80/60",
        "Schaefer(6-11)-wristND: 0.190 0.314 0.998",
        "Phillips(8-14)-wristR:   6/80 22/80 56/80",
        "Phillips(8-14)-wristL:   7/80 20/80 60/80",
        "Phillips(8-14)-hip:      3/80 17/80 51/80",
    ]

    /// `comboBoxRate.Text = "1"`.
    public var epochText = "1"
    /// `comboBox1.SelectedIndex = 0`.
    public var model = CutPointsOptions.models[0]
    /// `comboBoxFilter.SelectedIndex = 1`.
    public var filter = 1

    public init() {}

    /// `ExportPaeeForm.Epoch` — the seed is 1.
    public var epoch: Int { Int(epochText) ?? 1 }

    /// `ExportPaeeForm.Settings` — the `Properties.Settings.Default.CutPointSettings` round-trip.
    /// Note that upstream *saves* `comboBoxRate.SelectedIndex` but *restores* into
    /// `comboBoxRate.Text`; the port stores the epoch text, which is what the setting is used as.
    public var settingsString: String {
        let escaped = { (text: String) in
            text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
        }
        return "epoch=\(escaped(epochText))&model=\(escaped(model))&filter=\(escaped("\(filter)"))"
    }

    public init(settingsString: String) {
        self.init()
        var values: [String: String] = [:]
        for pair in settingsString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
        }
        if let epoch = values["epoch"] { epochText = epoch }
        if let model = values["model"] { self.model = model }
        if let filter = values["filter"], let index = Int(filter) { self.filter = index }
    }
}

/// `ExportWtvForm` — "Wear Time Validation".
public struct WearTimeOptions: Sendable, Equatable {
    /// `comboBoxRate.Items` (epochs are `* 1800 s`).
    public static let epochs = ["1", "2", "4", "6", "8", "12", "16", "24", "48"]

    /// `comboBoxRate.Text = "1"`.
    public var epochText = "1"

    public init() {}

    /// `ExportWtvForm.Epoch` — the seed is 1.
    public var epoch: Int { Int(epochText) ?? 1 }
}

/// `ExportForm` — "Export raw data" (the only export that runs `cwa-convert`).
public struct RawCsvOptions: Sendable, Equatable {

    public enum Stream: String, Sendable, CaseIterable, Identifiable {
        case accelerometer = "Accelerometer"
        case gyroscope = "Gyroscope"
        public var id: String { rawValue }
        public var flag: String { self == .accelerometer ? "-s:accel" : "-s:gyro" }
    }

    public enum Values: String, Sendable, CaseIterable, Identifiable {
        case gravity = "Gravity (g)"
        case raw = "Raw sensor units (1/256 g)"
        public var id: String { rawValue }
        public var flag: String { self == .gravity ? "-v:float" : "-v:int" }
    }

    /// `groupBoxTimestamps`, in the designer's own order.
    public enum Timestamp: String, Sendable, CaseIterable, Identifiable {
        case formatted = "Formatted (Y-M-D h:m:s.f)"
        case matlab = "Fractional Days (Matlab)"
        case excel = "Fractional Days (Excel)"
        case days = "Fractional Days (relative to start)"
        case unix = "Seconds (Unix epoch)"
        case seconds = "Seconds (relative to start)"
        case sequence = "Sample Number"
        case none = "None"

        public var id: String { rawValue }

        public var flag: String {
            switch self {
            case .formatted: return "-t:timestamp"
            case .matlab: return "-t:matlab"
            case .excel: return "-t:excel"
            case .days: return "-t:days"
            case .unix: return "-t:serial"
            case .seconds: return "-t:secs"
            case .sequence: return "-t:sequence"
            case .none: return "-t:none"
            }
        }
    }

    public var sourceFile: String = ""
    public var outputFile: String = ""
    /// `radioButtonStreamAccel.Checked = true`.
    public var stream: Stream = .accelerometer
    /// `radioButtonValuesFloat.Checked = true`.
    public var values: Values = .gravity
    /// `radioButtonTimeTimestamp.Checked = true`.
    public var timestamp: Timestamp = .formatted
    public var sampleStart = ""
    public var sampleLength = ""
    public var sampleStep = ""
    /// `textBoxBlockStart` — seeded from the data viewer selection when there is one.
    public var blockStart = ""
    public var blockCount = ""
    /// `labelBlocks` — the selection description, empty when there is no selection.
    public var blockDescription = ""

    public init() {}

    /// `ExportForm`'s constructor: the output file starts as the source name with the dialog's
    /// `DefaultExt` ("csv"), in the working folder, and the block boxes are floor/ceil of the
    /// selection.
    public init(sourceFile: String,
                workingFolder: URL,
                blockStart: Double = -1,
                blockCount: Double = -1,
                blockDescription: String? = nil) {
        self.init()
        self.sourceFile = sourceFile
        let name = DotNetPath.changeExtension(DotNetPath.fileName(sourceFile), ".csv")
        self.outputFile = workingFolder.appendingPathComponent(name).path
        if blockStart >= 0 { self.blockStart = "\(Int(blockStart.rounded(.down)))" }
        if blockCount >= 0 { self.blockCount = "\(Int(blockCount.rounded(.up)))" }
        // `labelBlocks.Text = blockDescription.Replace(" - ", "\r\n- ")`.
        if let blockDescription, !blockDescription.isEmpty {
            self.blockDescription = blockDescription.replacingOccurrences(of: " - ", with: "\n- ")
        }
    }
}
