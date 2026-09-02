import Foundation

/// The message boxes the export/tools paths put up, quoted from `MainForm.cs`.
public enum ExportMessages {
    public static let devicesSelectedTitle = "Device(s) selected"
    public static let devicesSelected =
        "Cannot perform this action on files until they have been downloaded.\nDownload the files or deselect the device(s)."

    public static let noFilesTitle = "No files selected"
    public static let noFiles = "No files selected."

    public static let overwriteTitle = "Overwrite existing files"
    public static let completeTitle = "Complete"

    public static let noPluginsTitle = "No Plugins Found"
    public static let noPlugins =
        "There are no plugins in this folder.\nPlease add plugin folders or change your Plugin folder in Options."
    public static let chooseFile = "Please choose a file to run a plugin on."
    public static let inputErrorTitle = "Input Error"
    public static func wrongInputCount(_ required: Int) -> String {
        "Incorrect number of CWA files provided to plugin.\nPlugin requires \(required) files"
    }

    /// `"Overwrite the following files:\r\n\r\n" + list + "\r\nAre you sure you want to overwrite?"`.
    public static func overwrite(_ lines: [String]) -> String {
        "Overwrite the following files:\n\n" + lines.map { $0 + "\n" }.joined() + "\nAre you sure you want to overwrite?"
    }

    /// `"Output " + n + "/" + m + ":\r\n\r\n" + names + "\r\n\r\n"`.
    public static func complete(outputs: [String], of total: Int) -> String {
        "Output \(outputs.count)/\(total):\n\n" + outputs.joined(separator: "\n") + "\n\n"
    }
}

/// `GetSelectedFilesForConvert` / `CheckWavConversion` — the checks every export and Tools-menu
/// action runs before it builds any command line.
@MainActor
public enum ExportFlow {

    /// `GetSelectedFilesForConvert`: refuse while devices are selected, refuse with no file
    /// selected, and confirm before overwriting any existing output.
    ///
    /// Returns `nil` when the action must not proceed, exactly as upstream does.
    public static func selectedFilesForConvert(files: [String],
                                              devicesSelected: Int,
                                              newExtension: String,
                                              prompt: any UserPrompting,
                                              fileManager: FileManager = .default) -> [String]? {
        if devicesSelected > 0 {
            prompt.warn(title: ExportMessages.devicesSelectedTitle, message: ExportMessages.devicesSelected)
            return nil
        }
        guard !files.isEmpty else {
            prompt.warn(title: ExportMessages.noFilesTitle, message: ExportMessages.noFiles)
            return nil
        }

        var lines: [String] = []
        for file in files {
            let result = DotNetPath.changeExtension(file, newExtension)
            guard fileManager.fileExists(atPath: result) else { continue }
            let source = modified(of: file, fileManager) ?? .distantPast
            let destination = modified(of: result, fileManager) ?? .distantPast
            lines.append(source <= destination
                         ? "File already exists: \(result)"
                         : "Caution, newer file exists: \(result)")
        }

        if !lines.isEmpty,
           !prompt.confirmOverwrite(title: ExportMessages.overwriteTitle,
                                    message: ExportMessages.overwrite(lines)) {
            return nil
        }
        return files
    }

    /// `CheckWavConversion`: which of these files needs a `.wav` made first, and the line the
    /// transcript gets for each.
    ///
    /// Upstream then calls `DoWavConvert(sources, ".wav", -1, true, true)` — no resampling, auto
    /// calibration on — and only prompts first when `promptBeforeConvert` is set, which no caller
    /// does.
    public static func wavConversionReport(for files: [String],
                                           regenerate: Bool,
                                           fileManager: FileManager = .default) -> [(file: String, reason: String)] {
        var report: [(file: String, reason: String)] = []
        for file in files {
            let wav = DotNetPath.changeExtension(file, ".wav")
            if regenerate {
                report.append((file, ".WAV regeneration requested: \(wav)"))
            } else if fileManager.fileExists(atPath: wav) {
                let source = modified(of: file, fileManager) ?? .distantPast
                let destination = modified(of: wav, fileManager) ?? .distantPast
                if destination < source {
                    report.append((file, ".WAV conversion older than source file: \(wav)"))
                }
            } else {
                report.append((file, ".WAV conversion required: \(wav)"))
            }
        }
        return report
    }

    /// The steps one analysis needs for one file: the `.wav` resample when it is missing or stale,
    /// then the analysis itself.
    public static func steps(for file: String,
                             analysis: ToolInvocation,
                             regenerateWav: Bool,
                             fileManager: FileManager = .default) -> [ToolInvocation] {
        let needsWav = !wavConversionReport(for: [file], regenerate: regenerateWav,
                                            fileManager: fileManager).isEmpty
        guard needsWav else { return [analysis] }
        return [OmConvertJob.wav(input: file, rate: -1, calibrate: true), analysis]
    }

    static func modified(of path: String, _ fileManager: FileManager) -> Date? {
        (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

public extension UserPrompting {
    /// `MessageBoxEx.Show(..., YesNoCancel, Question, Button3)` — the overwrite prompt the export
    /// paths use. macOS sheets get two buttons, so this maps onto `confirm`; only "Yes" proceeds,
    /// which is the only distinction upstream makes.
    func confirmOverwrite(title: String, message: String) -> Bool {
        confirm(title: title, message: message)
    }
}
