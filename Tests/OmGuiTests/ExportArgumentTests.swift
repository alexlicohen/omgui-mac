import Foundation
import OmGuiCore
import XCTest

/// Every command line OMGUI builds, compared with the string hand-traced from `MainForm.cs` /
/// `Export*Form.cs`. The expectations below are what `ProcessStartInfo.Arguments` receives on
/// Windows, so they carry upstream's quoting exactly.
final class ExportArgumentTests: XCTestCase {

    let cwa = "/Users/x/Study Data/01234_0000000001.cwa"
    let wav = "/Users/x/Study Data/01234_0000000001.wav"

    // MARK: - Path.ChangeExtension

    func testChangeExtensionMatchesDotNet() {
        XCTAssertEqual(DotNetPath.changeExtension("a/b.cwa", ".wav"), "a/b.wav")
        XCTAssertEqual(DotNetPath.changeExtension("a/b.cwa", ".svm.csv"), "a/b.svm.csv")
        // The last dot in the *file name* wins, not the last dot in the path.
        XCTAssertEqual(DotNetPath.changeExtension("a.b/c.cwa", ".wav"), "a.b/c.wav")
        // A directory with a dot and a file without one: the extension is appended.
        XCTAssertEqual(DotNetPath.changeExtension("a.b/c", ".wav"), "a.b/c.wav")
        XCTAssertEqual(DotNetPath.changeExtension("plain", ".csv"), "plain.csv")
        // Already-multipart names keep everything up to the final dot.
        XCTAssertEqual(DotNetPath.changeExtension("a/b.svm.csv", ".wav"), "a/b.svm.wav")
        XCTAssertEqual(DotNetPath.fileName("/a/b/c.cwa"), "c.cwa")
        XCTAssertEqual(DotNetPath.fileName("c.cwa"), "c.cwa")
    }

    // MARK: - DoWavConvert

    /// `args: "<in>", -calibrate, 1, -out, "<out>"` — `CheckWavConversion`'s call, `rate = -1`.
    func testWavWithoutResample() {
        let job = OmConvertJob.wav(input: cwa, rate: -1, calibrate: true)
        XCTAssertEqual(job.commandLine,
                       "\"\(cwa)\" -calibrate 1 -out \"\(wav).part\"")
        XCTAssertEqual(job.arguments, [cwa, "-calibrate", "1", "-out", wav + ".part"])
        XCTAssertEqual(job.outputPath, wav + ".part")
        XCTAssertEqual(job.finalPath, wav)
        XCTAssertEqual(job.executable, .helper(.omconvert))
    }

    /// `if (rate > 0) { args.Add("-resample"); args.Add("" + rate); }`.
    func testWavWithResampleAndNoCalibration() {
        let job = OmConvertJob.wav(input: cwa, rate: 50, calibrate: false)
        XCTAssertEqual(job.commandLine,
                       "\"\(cwa)\" -resample 50 -calibrate 0 -out \"\(wav).part\"")
    }

    /// `DoWavConvert` ignores its `ext` argument, so "Export Resampled WAV..." lands on `.wav`
    /// even though `GetSelectedFilesForConvert(".resampled.wav")` checked a different name.
    func testWavOutputIsPlainWavNotResampledWav() {
        XCTAssertEqual(OmConvertJob.wav(input: cwa, rate: 100, calibrate: true).finalPath, wav)
    }

    // MARK: - The analyses

    func testSvm() {
        let job = OmConvertJob.svm(input: cwa, epoch: 60, filter: 1, mode: 0)
        XCTAssertEqual(job.commandLine,
                       "\"\(wav)\" -svm-epoch 60 -svm-filter 1 -svm-mode 0"
                       + " -svm-file \"/Users/x/Study Data/01234_0000000001.svm.csv.part\"")
        XCTAssertEqual(job.inputPath, wav, "the analyses read the .wav, not the .cwa")
        XCTAssertEqual(job.finalPath, "/Users/x/Study Data/01234_0000000001.svm.csv")
    }

    /// The PAEE order is epoch, model, filter, file — not the alphabetical order the others use.
    func testCutPoints() {
        let model = CutPointsOptions.models[4]
        let job = OmConvertJob.cutPoints(input: cwa, epoch: 1, model: model, filter: 1)
        XCTAssertEqual(job.commandLine,
                       "\"\(wav)\" -paee-epoch 1 -paee-model \"\(model)\" -paee-filter 1"
                       + " -paee-file \"/Users/x/Study Data/01234_0000000001.cut.csv.part\"")
        XCTAssertEqual(job.arguments[4], model, "the model string is one argv element, spaces and all")
    }

    func testWearTime() {
        let job = OmConvertJob.wearTime(input: cwa, epoch: 2)
        XCTAssertEqual(job.commandLine,
                       "\"\(wav)\" -wtv-epoch 2"
                       + " -wtv-file \"/Users/x/Study Data/01234_0000000001.wtv.csv.part\"")
    }

    func testSleep() {
        let job = OmConvertJob.sleep(input: cwa)
        XCTAssertEqual(job.commandLine,
                       "\"\(wav)\" -sleep-file \"/Users/x/Study Data/01234_0000000001.sleep.csv.part\"")
    }

    func testResampledCsv() {
        let job = OmConvertJob.resampledCsv(input: cwa)
        XCTAssertEqual(job.commandLine,
                       "\"\(wav)\" -csv-file \"/Users/x/Study Data/01234_0000000001.resampled.csv.part\"")
    }

    // MARK: - ExportForm (raw CSV, cwa-convert)

    func testRawCsvDefaults() {
        var options = RawCsvOptions()
        options.sourceFile = cwa
        options.outputFile = "/Users/x/out.csv"
        let job = OmConvertJob.rawCsv(options)
        XCTAssertEqual(job.commandLine,
                       "\"\(cwa)\" -f:csv -out \"/Users/x/out.csv\" -s:accel -v:float -t:timestamp")
        XCTAssertEqual(job.executable, .helper(.cwaConvert))
        XCTAssertNil(job.outputPath, "ExportForm writes straight to the chosen file")
    }

    func testRawCsvEveryOptionalArgument() {
        var options = RawCsvOptions()
        options.sourceFile = cwa
        options.outputFile = "/Users/x/out.csv"
        options.stream = .gyroscope
        options.values = .raw
        options.timestamp = .excel
        options.sampleStart = "10"
        options.sampleLength = "200"
        options.sampleStep = "2"
        options.blockStart = "12"
        options.blockCount = "34"
        XCTAssertEqual(OmConvertJob.rawCsv(options).commandLine,
                       "\"\(cwa)\" -f:csv -out \"/Users/x/out.csv\" -s:gyro -v:int -t:excel"
                       + " -start 10 -length 200 -step 2 -blockstart 12 -blockcount 34")
    }

    /// Every `-t:` flag maps to the radio button `ExportForm.Designer.cs` labels it with.
    func testTimestampFlags() {
        XCTAssertEqual(RawCsvOptions.Timestamp.allCases.map(\.flag),
                       ["-t:timestamp", "-t:matlab", "-t:excel", "-t:days",
                        "-t:serial", "-t:secs", "-t:sequence", "-t:none"])
    }

    /// `ExportForm`'s constructor: floor the start, ceil the count, name the output after the
    /// source with the save dialog's `DefaultExt`.
    func testRawCsvSeedsFromTheSelection() {
        let options = RawCsvOptions(sourceFile: cwa,
                                    workingFolder: URL(fileURLWithPath: "/Work"),
                                    blockStart: 12.7,
                                    blockCount: 30.2,
                                    blockDescription: "01/02/26 10:00:00 - 01/02/26 11:00:00")
        XCTAssertEqual(options.outputFile, "/Work/01234_0000000001.csv")
        XCTAssertEqual(options.blockStart, "12")
        XCTAssertEqual(options.blockCount, "31")
        XCTAssertEqual(options.blockDescription, "01/02/26 10:00:00\n- 01/02/26 11:00:00")
    }

    func testRawCsvWithoutASelectionLeavesTheBlockBoxesEmpty() {
        let options = RawCsvOptions(sourceFile: cwa, workingFolder: URL(fileURLWithPath: "/Work"))
        XCTAssertEqual(options.blockStart, "")
        XCTAssertEqual(options.blockCount, "")
        XCTAssertEqual(options.blockDescription, "")
    }

    // MARK: - Dialog defaults

    func testDialogDefaultsMatchTheDesigners() {
        XCTAssertEqual(WavExportOptions().rateText, "auto")
        XCTAssertEqual(WavExportOptions().rate, -1, "\"auto\" leaves int.TryParse's seed of -1")
        XCTAssertTrue(WavExportOptions().autoCalibrate)

        XCTAssertEqual(SvmExportOptions().epoch, 60)
        XCTAssertEqual(SvmExportOptions().filter, 1)
        XCTAssertEqual(SvmExportOptions().mode, 0)
        XCTAssertEqual(SvmExportOptions.filters, ["none", "BP 0.5-20Hz"])
        XCTAssertEqual(SvmExportOptions.modes.count, 2)

        XCTAssertEqual(CutPointsOptions().epoch, 1)
        XCTAssertEqual(CutPointsOptions().filter, 1)
        XCTAssertTrue(CutPointsOptions().model.hasPrefix("'wrist':"))
        XCTAssertEqual(CutPointsOptions.models.count, 8)

        XCTAssertEqual(WearTimeOptions().epoch, 1)
        XCTAssertEqual(WearTimeOptions.epochs, ["1", "2", "4", "6", "8", "12", "16", "24", "48"])
    }

    /// `ExportPaeeForm.Settings` — `Properties.Settings.Default.CutPointSettings` round-trips.
    func testCutPointSettingsRoundTrip() {
        var options = CutPointsOptions()
        options.epochText = "15"
        options.model = CutPointsOptions.models[3]
        options.filter = 0
        let restored = CutPointsOptions(settingsString: options.settingsString)
        XCTAssertEqual(restored.epochText, "15")
        XCTAssertEqual(restored.model, CutPointsOptions.models[3])
        XCTAssertEqual(restored.filter, 0)
    }

    func testCutPointSettingsIgnoresRubbish() {
        let restored = CutPointsOptions(settingsString: "not a settings string")
        XCTAssertEqual(restored.epochText, CutPointsOptions().epochText)
        XCTAssertEqual(restored.model, CutPointsOptions().model)
    }

    // MARK: - The plugin stdout protocol

    /// `MainForm.parseMessage`.
    func testPluginOutputProtocol() {
        XCTAssertEqual(PluginOutput.parse("p 42").progress, 42)
        XCTAssertEqual(PluginOutput.parse("P:42").progress, 42)
        XCTAssertEqual(PluginOutput.parse("e something broke").error, "something broke")
        XCTAssertEqual(PluginOutput.parse("E:something broke").error, "something broke")
        XCTAssertNil(PluginOutput.parse("progress 42").progress, "a third character must be ' ' or ':'")
        XCTAssertNil(PluginOutput.parse("p").progress, "too short to be a message")
        XCTAssertNil(PluginOutput.parse("Finished.").progress)
        XCTAssertNil(PluginOutput.parse("Finished.").error)
    }
}
