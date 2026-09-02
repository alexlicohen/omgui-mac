import AppKit
import Foundation
import OmApi
import OmGuiCore

/// The phase 3b half of `--self-test`: one export and one Tools-menu analysis run end to end on
/// the mock file with the real helpers, and the plugin host runs the bundled OmConvertPlugin.
///
/// As in the rest of the self test, nothing is simulated: these are the same `AppModel` methods
/// the menu items call, and the outputs are read back out of the Output Files tab afterwards.
extension SelfTest {

    @MainActor
    static func runTools(model: AppModel,
                         say: @MainActor (String) -> Void,
                         shot: @MainActor (String) async -> Void,
                         pause: @MainActor (Double) async -> Void) async {

        // Where the helpers and the bundled plugins were found.
        for tool in HelperTool.allCases {
            if let url = try? HelperTools.url(for: tool) {
                say("helper \(tool.executableName): \(url.path)")
            } else {
                say("WARNING: helper \(tool.executableName) not found - run scripts/build-helpers.sh")
                return
            }
        }

        guard let file = model.dataFiles.first else {
            say("WARNING: no data file in the workspace to export")
            return
        }
        model.filesTab = 0
        model.selectedFilePaths = [file.location]
        model.fileSelectionChanged()
        // The earlier steps leave a hand-made row in the queue to photograph the tab; drop it so
        // the rows below are only the jobs these steps really ran.
        model.pluginQueue.removeAll()
        say("selected \(file.name) -> Data Files toolbar enabled = \(model.fileToolbarEnabled)")

        // MOP §9.4.4 step 2: the downloaded file, selected in Data Files. Captured here rather
        // than in the download leg so steps 2, 3 and 4 of the SOP are all the same device's file.
        let hadFileProperties = model.showFileProperties
        let hadPreviewPane = model.showPreview
        model.showFileProperties = false
        model.showPreview = false
        await pause(0.3)
        await shot("sop-06-data-files.png")
        model.showFileProperties = hadFileProperties
        model.showPreview = hadPreviewPane

        @MainActor func settle(_ what: String) async {
            for _ in 0..<600 where model.jobs.isBusy { await pause(0.1) }
            model.refreshFiles()
            say("\(what): queue = " + model.pluginQueue.items
                .map { "\($0.pluginName)/\($0.source)=\($0.progressText)" }.joined(separator: ", "))
            say("\(what): output files = " + model.outputFiles.map(\.name).joined(separator: ", "))
        }

        @MainActor func hasOutput(_ suffix: String) -> Bool {
            model.outputFiles.contains { $0.name.hasSuffix(suffix) }
        }

        // The steps below are assertions, not a demonstration: anything that does not appear in
        // Output Files fails the run.
        var failures: [String] = []
        @MainActor func expect(_ condition: Bool, _ what: String) {
            say("\(what): \(condition)")
            if !condition { failures.append(what) }
        }

        // --- An export: Raw CSV, which runs cwa-convert exactly as ExportForm does -------------
        model.exportRawCsv()
        await pause(0.4)
        guard let rawCsv = model.exportSheet else {
            say("WARNING: the Export raw data dialog did not open")
            return
        }
        say("Export raw data: source=\(DotNetPath.fileName(rawCsv.rawCsv.sourceFile))"
            + " output=\(DotNetPath.fileName(rawCsv.rawCsv.outputFile))"
            + " stream=\(rawCsv.rawCsv.stream.flag) values=\(rawCsv.rawCsv.values.flag)"
            + " time=\(rawCsv.rawCsv.timestamp.flag)")
        say("command: " + OmConvertJob.rawCsv(rawCsv.rawCsv).commandLine)
        await shot("15-export-raw-csv.png")
        // MOP §9.4.4 step 3.
        await shot("sop-07-export-raw-csv.png")
        rawCsv.onRun?(rawCsv)
        model.exportSheet = nil
        model.pendingRawCsv.removeAll()
        await settle("after Export Raw CSV")
        expect(hasOutput(".csv"), "Raw CSV appeared in Output Files")
        await shot("15-export-output.png")
        // MOP §9.4.4 step 4: the exported file, ready to be renamed and uploaded. Nothing is
        // selected and the preview is folded away (View ▸ Preview), so the shot is of the Output
        // Files list rather than of the plot the viewer leg left behind.
        model.selectedDeviceIds = []
        model.selectedFilePaths = []
        model.fileSelectionChanged()
        let hadPreview = model.showPreview
        model.showPreview = false
        model.filesTab = 2
        await shot("sop-08-output-files.png")
        model.filesTab = 0
        model.showPreview = hadPreview

        // --- A tool: SVM, which resamples to .wav first and then runs the analysis -------------
        model.filesTab = 0
        model.selectedFilePaths = [file.location]
        model.fileSelectionChanged()
        model.calculateSvm()
        await pause(0.4)
        guard let svm = model.exportSheet else {
            say("WARNING: the SVM dialog did not open")
            return
        }
        // The mock file is 19.5 s long, so use the shortest epoch the dialog offers.
        svm.svm.epochText = "1"
        say("SVM dialog: epoch=\(svm.svm.epoch) filter=\(svm.svm.filter) mode=\(svm.svm.mode)")
        say("command: " + OmConvertJob.svm(input: file.location, epoch: svm.svm.epoch,
                                           filter: svm.svm.filter, mode: svm.svm.mode).commandLine)
        await shot("15-export-svm.png")
        svm.onRun?(svm)
        model.exportSheet = nil
        await settle("after Calculate SVM")
        expect(hasOutput(".svm.csv"), "SVM appeared in Output Files")

        // --- The plugin host --------------------------------------------------------------------
        model.filesTab = 0
        model.selectedFilePaths = [file.location]
        model.fileSelectionChanged()
        model.showPlugins()
        await pause(0.5)
        guard let plugins = model.pluginsSheet else {
            say("WARNING: the Plugins dialog did not open")
            return
        }
        say("plugins: " + plugins.plugins.map { "\($0.readableName) [\($0.runFilePath)]" }
            .joined(separator: ", "))
        await shot("16-plugins-list.png")

        model.runPlugin(plugins)
        await pause(1.2)
        guard let run = model.runPluginSheet else {
            say("WARNING: the plugin's form did not open")
            return
        }
        say("plugin form: \(run.formURL.absoluteString)")
        await shot("16-plugins-form.png")

        // The page's own `func()` builds this fragment; check the shipped HTML still says so
        // before standing in for the click, so the transcript is not claiming more than it did.
        let html = (try? String(contentsOf: run.plugin.htmlFileURL, encoding: .utf8)) ?? ""
        let contract = #"hash = quote + name + quote + "?" + quote + name + quote;"#
        expect(html.contains(contract), "the plugin page builds the documented hash")
        model.pluginFormSubmitted(run, fragment: "\"\"?\"\"")
        await settle("after OMConvert plugin")
        expect(hasOutput(".wav") && hasOutput(".wtv.csv") && hasOutput(".paee.csv"),
               "the OMConvert plugin wrote its .wav, .wtv.csv and .paee.csv")
        expect(model.pluginQueue.items.allSatisfy { $0.state == .complete },
               "every queued job completed")
        model.filesTab = 2
        await shot("16-plugins-output.png")

        // --- The Plugin Queue's own buttons ------------------------------------------------------
        model.filesTab = 1
        await shot("16-plugins-queue.png")
        model.pluginQueue.clearCompleted()
        say("plugin queue after Clear Completed: \(model.pluginQueue.items.count) row(s)")
        model.filesTab = 0
        model.selectedFilePaths = []
        model.fileSelectionChanged()

        guard failures.isEmpty else {
            say("FAILED: " + failures.joined(separator: "; "))
            model.shutdown()
            exit(1)
        }
    }
}
