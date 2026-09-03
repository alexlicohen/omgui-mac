import AppKit
import Foundation
import OmApi
import OmGuiCore
import SwiftUI

/// The Export/Tools flows of `MainForm.cs`: the checks, the option dialog, and the omconvert or
/// cwa-convert jobs each one queues.
///
/// Every handler follows the same upstream shape — `GetSelectedFilesForConvert(newExtension)`, then
/// the `Export*Form`, then `CheckWavConversion` (except Raw CSV and Resample to WAV, which read the
/// `.cwa` directly), then one helper run per file.
extension AppModel {

    // MARK: - Selection

    /// `filesListView.SelectedItems`, in list order.
    var selectedDataFiles: [String] {
        dataFiles.filter { selectedFilePaths.contains($0.location) }.map(\.location)
    }

    /// `Control.ModifierKeys & Keys.Shift` — regenerate the `.wav` even when it looks current.
    var shiftHeld: Bool { NSEvent.modifierFlags.contains(.shift) }

    /// The data viewer's selected slice, as the blocks upstream passes around.
    var selectionBlocks: DataSelection.Blocks? {
        guard let range = dataSelection, let path = selectedDataFiles.first else { return nil }
        return DataSelection.blocks(for: range, path: path)
    }

    func filesForConvert(_ newExtension: String) -> [String]? {
        ExportFlow.selectedFilesForConvert(files: selectedDataFiles,
                                           devicesSelected: selectedDeviceIds.count,
                                           newExtension: newExtension,
                                           prompt: prompter)
    }

    // MARK: - File menu / Export button

    /// `wavToolStripMenuItem_Click`.
    func exportResampledWav() {
        guard let files = filesForConvert(".resampled.wav") else { return }
        present(.wav, files: files)
    }

    /// `toolStripButtonCSV_Click_1`.
    func exportResampledCsv() {
        guard let files = filesForConvert(".resampled.csv") else { return }
        present(.resampledCsv, files: files)
    }

    /// `exportToolStripMenuItem_Click` → `ExportDataConstruct` → one `ExportForm` per file.
    func exportRawCsv() {
        if selectedDeviceIds.count > 0 {
            prompter.warn(title: ExportMessages.devicesSelectedTitle, message: ExportMessages.devicesSelected)
            return
        }
        let files = selectedDataFiles
        guard !files.isEmpty else {
            prompter.warn(title: ExportMessages.noFilesTitle, message: ExportMessages.noFiles)
            return
        }
        // With a selection the export applies to the first file only, exactly as upstream does.
        pendingRawCsv = selectionBlocks == nil ? files : [files[0]]
        presentNextRawCsv()
    }

    /// Dismiss the Export/Tools sheet and run whatever it chains to.
    ///
    /// The chained presentation has to land in a *later* main-loop turn: assigning a new
    /// `exportSheet` inside the same update that clears it leaves `.sheet(item:)` looking at a
    /// nil→new transition during its own teardown, and the second dialog never appears — so
    /// "Export Raw CSV" over three files silently exported only the first.
    func closeExportSheet() {
        let onClose = exportSheet?.onClose
        exportSheet = nil
        guard let onClose else { return }
        DispatchQueue.main.async { onClose() }
    }

    func presentNextRawCsv() {
        guard !pendingRawCsv.isEmpty else { return }
        let file = pendingRawCsv.removeFirst()
        let blocks = selectionBlocks
        var options = RawCsvOptions(sourceFile: file,
                                    workingFolder: workspace,
                                    blockStart: blocks?.start ?? -1,
                                    blockCount: blocks?.count ?? -1,
                                    blockDescription: dataSelection.map(DataSelection.description(for:)))
        if blocks == nil { options.blockDescription = "" }
        let context = ExportSheetContext(kind: .rawCsv, files: [file])
        context.rawCsv = options
        context.onRun = { [weak self] context in self?.runRawCsv(context) }
        context.onClose = { [weak self] in self?.presentNextRawCsv() }
        exportSheet = context
    }

    // MARK: - Tools menu

    /// `svmToolStripMenuItem_Click`.
    func calculateSvm() {
        guard let files = filesForConvert(".svm.csv") else { return }
        present(.svm, files: files)
    }

    /// `cutPointsToolStripMenuItem_Click`.
    func calculateCutPoints() {
        guard let files = filesForConvert(".cut.csv") else { return }
        let context = ExportSheetContext(kind: .cutPoints, files: files)
        // `optionsForm.Settings = Properties.Settings.Default.CutPointSettings`.
        context.cutPoints = CutPointsOptions(settingsString: settings.cutPointSettings)
        finishPresenting(context)
    }

    /// `wearTimeToolStripMenuItem_Click`.
    func calculateWearTime() {
        guard let files = filesForConvert(".wtv.csv") else { return }
        present(.wearTime, files: files)
    }

    /// `toolStripButtonSleep_Click`.
    func calculateSleepTime() {
        guard let files = filesForConvert(".sleep.csv") else { return }
        present(.sleep, files: files)
    }

    private func present(_ kind: ExportSheetContext.Kind, files: [String]) {
        finishPresenting(ExportSheetContext(kind: kind, files: files))
    }

    private func finishPresenting(_ context: ExportSheetContext) {
        context.regenerateWav = shiftHeld
        context.onRun = { [weak self] context in self?.run(context) }
        exportSheet = context
    }

    // MARK: - Running

    /// The dialog's Run/Resample button: build the jobs and queue them.
    func run(_ context: ExportSheetContext) {
        if context.kind == .cutPoints { settings.cutPointSettings = context.cutPoints.settingsString }
        var jobsToQueue: [ToolJob] = []
        for file in context.files {
            let name = DotNetPath.fileName(file)
            switch context.kind {
            case .wav:
                // `DoWavConvert(files, ".resampled.wav", rate, autoCalibrate, false)`.
                let step = OmConvertJob.wav(input: file,
                                            rate: context.wav.rate,
                                            calibrate: context.wav.autoCalibrate)
                jobsToQueue.append(ToolJob(name: "Resample to .WAV", source: name, steps: [step]))
            case .resampledCsv:
                jobsToQueue.append(analysis("Export Resampled to CSV", file, name, context,
                                            OmConvertJob.resampledCsv(input: file)))
            case .svm:
                jobsToQueue.append(analysis("SVM", file, name, context,
                                            OmConvertJob.svm(input: file,
                                                             epoch: context.svm.epoch,
                                                             filter: context.svm.filter,
                                                             mode: context.svm.mode)))
            case .cutPoints:
                jobsToQueue.append(analysis("Cut-point Analysis", file, name, context,
                                            OmConvertJob.cutPoints(input: file,
                                                                   epoch: context.cutPoints.epoch,
                                                                   model: context.cutPoints.model,
                                                                   filter: context.cutPoints.filter)))
            case .wearTime:
                jobsToQueue.append(analysis("Wear Time Validation", file, name, context,
                                            OmConvertJob.wearTime(input: file, epoch: context.wearTime.epoch)))
            case .sleep:
                jobsToQueue.append(analysis("Sleep Analysis", file, name, context,
                                            OmConvertJob.sleep(input: file)))
            case .rawCsv:
                break
            }
        }
        queue(jobsToQueue)
    }

    private func analysis(_ title: String, _ file: String, _ name: String,
                          _ context: ExportSheetContext, _ invocation: ToolInvocation) -> ToolJob {
        ToolJob(name: title, source: name,
                steps: ExportFlow.steps(for: file, analysis: invocation,
                                        regenerateWav: context.regenerateWav))
    }

    /// `ExportForm.buttonConvert_Click` — one `cwa-convert` run, no `.part` step.
    func runRawCsv(_ context: ExportSheetContext) {
        let step = OmConvertJob.rawCsv(context.rawCsv)
        queue([ToolJob(name: "Export raw data",
                       source: DotNetPath.fileName(context.rawCsv.sourceFile),
                       steps: [step])])
    }

    /// Queue the batch and put up the `"Output n/m"` box once the last one lands, as the loops in
    /// `MainForm` do after their `ProcessingForm`s.
    func queue(_ batch: [ToolJob]) {
        guard !batch.isEmpty else { return }
        filesTab = 1
        let total = batch.count
        let outcome = BatchOutcome(total: total)
        for job in batch {
            jobs.enqueue(job) { [weak self] result in
                guard let self else { return }
                if result.succeeded, let path = job.finalPath {
                    outcome.outputs.append(DotNetPath.fileName(path))
                }
                outcome.finished += 1
                guard outcome.finished == total else { return }
                self.refreshFiles()
                self.prompter.warn(title: ExportMessages.completeTitle,
                                   message: ExportMessages.complete(outputs: outcome.outputs, of: total))
            }
        }
    }

    // MARK: - Plugins

    /// `RunPluginsProcess(filesListView.SelectedItems)`.
    func showPlugins() {
        let files = selectedDataFiles
        guard !files.isEmpty else {
            prompter.warn(title: AppModel.defaultTitle, message: ExportMessages.chooseFile)
            return
        }
        guard let folder = PluginManager.effectiveFolder(setting: settings.pluginFolder) else {
            prompter.warn(title: ExportMessages.noPluginsTitle, message: ExportMessages.noPlugins)
            return
        }
        let plugins = PluginManager.load(from: folder)
        guard !plugins.isEmpty else {
            prompter.warn(title: ExportMessages.noPluginsTitle, message: ExportMessages.noPlugins)
            return
        }
        log("Plugins: \(plugins.count) in \(folder.path)")
        let selection = dataSelection.flatMap { range -> PluginSelection? in
            guard let blocks = selectionBlocks else { return nil }
            return PluginSelection(blockStart: blocks.start, blockCount: blocks.count,
                                   startTime: PluginSelection.timeString(range.lowerBound),
                                   endTime: PluginSelection.timeString(range.upperBound))
        }
        pluginsSheet = PluginsSheetContext(plugins: plugins, files: files, selection: selection)
    }

    /// `PluginsForm.btnRun_Click` — check the input count, then open the plugin's own form.
    func runPlugin(_ context: PluginsSheetContext) {
        let plugin = context.selected
        guard context.files.count == plugin.numberOfInputFiles else {
            prompter.warn(title: ExportMessages.inputErrorTitle,
                          message: ExportMessages.wrongInputCount(plugin.numberOfInputFiles))
            return
        }
        pluginsSheet = nil
        runPluginSheet = RunPluginSheetContext(plugin: plugin,
                                               files: context.files,
                                               selection: context.selection)
    }

    /// `RunPluginForm`'s `window.location.hash` handler, then `RunProcess2`.
    func pluginFormSubmitted(_ context: RunPluginSheetContext, fragment: String) {
        runPluginSheet = nil
        guard let arguments = PluginHost.arguments(fromFragment: fragment,
                                                   plugin: context.plugin,
                                                   inputs: context.files) else {
            prompter.warn(title: "Plugin Fatal Error", message: "The plugin has peformed an illegal operation.\n")
            return
        }
        let invocation = PluginHost.invocation(plugin: context.plugin,
                                               parameterString: arguments.parameterString,
                                               outputName: arguments.outputName,
                                               workingFolder: workspace,
                                               inputs: context.files)
        // `PluginQueueItem`'s Source column joins several inputs with "  |  ".
        let job = ToolJob(name: context.plugin.readableName,
                          source: context.files.joined(separator: "  |  "),
                          steps: [invocation])
        queue([job])
    }
}

/// Collects a batch's results for the single "Complete" message box at the end.
@MainActor
final class BatchOutcome {
    let total: Int
    var outputs: [String] = []
    var finished = 0
    init(total: Int) { self.total = total }
}

/// What an Export/Tools option dialog is editing.
@MainActor
final class ExportSheetContext: ObservableObject, Identifiable {

    enum Kind: String {
        case wav, resampledCsv, rawCsv, svm, cutPoints, wearTime, sleep

        /// The dialog's `Form.Text`.
        var title: String {
            switch self {
            case .wav: return "Resample to .WAV"
            case .resampledCsv: return "Export Resampled to CSV"
            case .rawCsv: return "Export raw data"
            case .svm: return "SVM"
            case .cutPoints: return "Cut-point Analysis"
            case .wearTime: return "Wear Time Validation"
            case .sleep: return "Sleep Analysis"
            }
        }

        /// The accept button's text (`&Resample` / `&Run` / `C&onvert`).
        var acceptTitle: String {
            switch self {
            case .wav: return "Resample"
            case .rawCsv: return "Convert"
            default: return "Run"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let files: [String]
    /// Shift was held when the action started (`regenerateWav`).
    var regenerateWav = false

    @Published var wav = WavExportOptions()
    @Published var svm = SvmExportOptions()
    @Published var cutPoints = CutPointsOptions()
    @Published var wearTime = WearTimeOptions()
    @Published var rawCsv = RawCsvOptions()

    var onRun: ((ExportSheetContext) -> Void)?
    /// Raw CSV shows one dialog per file, so the next one opens when this one closes.
    var onClose: (() -> Void)?

    init(kind: Kind, files: [String]) {
        self.kind = kind
        self.files = files
    }
}

/// `PluginsForm` — pick a plugin to run on the selected files.
@MainActor
final class PluginsSheetContext: ObservableObject, Identifiable {
    let id = UUID()
    let plugins: [PluginDescriptor]
    let files: [String]
    let selection: PluginSelection?
    @Published var index = 0

    var selected: PluginDescriptor { plugins[min(index, plugins.count - 1)] }

    init(plugins: [PluginDescriptor], files: [String], selection: PluginSelection?) {
        self.plugins = plugins
        self.files = files
        self.selection = selection
    }
}

/// `RunPluginForm` — the plugin's own HTML form.
@MainActor
final class RunPluginSheetContext: ObservableObject, Identifiable {
    let id = UUID()
    let plugin: PluginDescriptor
    let files: [String]
    let selection: PluginSelection?

    init(plugin: PluginDescriptor, files: [String], selection: PluginSelection?) {
        self.plugin = plugin
        self.files = files
        self.selection = selection
    }

    /// The `file:///…?…` URL `RunPluginForm.Go` builds.
    var formURL: URL {
        let query = PluginHost.formQuery(plugin: plugin, inputs: files, selection: selection)
        let base = plugin.htmlFileURL
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        // Upstream does no encoding at all and the page calls `unescape()`; percent-encoding just
        // the characters a URL cannot hold keeps a path with spaces in it working either way.
        components?.percentEncodedQuery = String(query.dropFirst())
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        return components?.url ?? base
    }
}
