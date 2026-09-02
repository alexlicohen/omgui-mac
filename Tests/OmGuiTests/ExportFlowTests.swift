import Foundation
import OmApi
import OmGuiCore
import XCTest

/// `GetSelectedFilesForConvert` and `CheckWavConversion`, plus the data-viewer selection maths.
@MainActor
final class ExportFlowTests: XCTestCase {

    var scratch: URL!
    var prompt: RecordingPrompter!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omgui-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        prompt = RecordingPrompter()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    @discardableResult
    func touch(_ name: String, modified: Date? = nil) throws -> String {
        let path = scratch.appendingPathComponent(name).path
        try "x".write(toFile: path, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
        }
        return path
    }

    // MARK: - GetSelectedFilesForConvert

    func testASelectedDeviceBlocksTheAction() throws {
        let file = try touch("a.cwa")
        XCTAssertNil(ExportFlow.selectedFilesForConvert(files: [file], devicesSelected: 1,
                                                        newExtension: ".svm.csv", prompt: prompt))
        XCTAssertEqual(prompt.warnings.first?.title, "Device(s) selected")
        XCTAssertEqual(prompt.warnings.first?.message,
                       "Cannot perform this action on files until they have been downloaded.\nDownload the files or deselect the device(s).")
    }

    func testNoFilesSelected() {
        XCTAssertNil(ExportFlow.selectedFilesForConvert(files: [], devicesSelected: 0,
                                                        newExtension: ".svm.csv", prompt: prompt))
        XCTAssertEqual(prompt.warnings.first?.message, "No files selected.")
    }

    func testNoExistingOutputMeansNoPrompt() throws {
        let file = try touch("a.cwa")
        XCTAssertEqual(ExportFlow.selectedFilesForConvert(files: [file], devicesSelected: 0,
                                                          newExtension: ".svm.csv", prompt: prompt),
                       [file])
        XCTAssertTrue(prompt.confirms.isEmpty)
    }

    /// A destination at least as new as the source is "File already exists"; an older one is
    /// "Caution, newer file exists".
    func testTheOverwritePromptDistinguishesStaleOutputs() throws {
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        let fresh = try touch("fresh.cwa", modified: old)
        try touch("fresh.svm.csv", modified: new)
        let stale = try touch("stale.cwa", modified: new)
        try touch("stale.svm.csv", modified: old)

        prompt.defaultConfirm = true
        let result = ExportFlow.selectedFilesForConvert(files: [fresh, stale], devicesSelected: 0,
                                                        newExtension: ".svm.csv", prompt: prompt)
        XCTAssertEqual(result, [fresh, stale])
        let message = try XCTUnwrap(prompt.confirms.first?.message)
        XCTAssertEqual(prompt.confirms.first?.title, "Overwrite existing files")
        XCTAssertTrue(message.hasPrefix("Overwrite the following files:\n\n"))
        XCTAssertTrue(message.contains("File already exists: \(scratch.appendingPathComponent("fresh.svm.csv").path)\n"))
        XCTAssertTrue(message.contains("Caution, newer file exists: \(scratch.appendingPathComponent("stale.svm.csv").path)\n"))
        XCTAssertTrue(message.hasSuffix("\nAre you sure you want to overwrite?"))
    }

    func testDecliningTheOverwritePromptCancelsTheAction() throws {
        let file = try touch("a.cwa")
        try touch("a.svm.csv")
        prompt.defaultConfirm = false
        XCTAssertNil(ExportFlow.selectedFilesForConvert(files: [file], devicesSelected: 0,
                                                        newExtension: ".svm.csv", prompt: prompt))
    }

    // MARK: - CheckWavConversion

    func testAMissingWavIsConverted() throws {
        let file = try touch("a.cwa")
        let report = ExportFlow.wavConversionReport(for: [file], regenerate: false)
        XCTAssertEqual(report.map(\.file), [file])
        XCTAssertEqual(report.first?.reason,
                       ".WAV conversion required: \(scratch.appendingPathComponent("a.wav").path)")
    }

    func testAnUpToDateWavIsLeftAlone() throws {
        let old = Date(timeIntervalSince1970: 1_000_000)
        let file = try touch("a.cwa", modified: old)
        try touch("a.wav", modified: old.addingTimeInterval(10))
        XCTAssertTrue(ExportFlow.wavConversionReport(for: [file], regenerate: false).isEmpty)
        XCTAssertEqual(ExportFlow.steps(for: file, analysis: OmConvertJob.sleep(input: file),
                                        regenerateWav: false).count, 1)
    }

    func testAStaleWavIsRebuilt() throws {
        let old = Date(timeIntervalSince1970: 1_000_000)
        let file = try touch("a.cwa", modified: old.addingTimeInterval(10))
        try touch("a.wav", modified: old)
        XCTAssertEqual(ExportFlow.wavConversionReport(for: [file], regenerate: false).first?.reason,
                       ".WAV conversion older than source file: \(scratch.appendingPathComponent("a.wav").path)")
    }

    /// Holding Shift regenerates the `.wav` even when it is current.
    func testRegenerationIsRequestedByShift() throws {
        let old = Date(timeIntervalSince1970: 1_000_000)
        let file = try touch("a.cwa", modified: old)
        try touch("a.wav", modified: old.addingTimeInterval(10))
        XCTAssertEqual(ExportFlow.wavConversionReport(for: [file], regenerate: true).first?.reason,
                       ".WAV regeneration requested: \(scratch.appendingPathComponent("a.wav").path)")

        let steps = ExportFlow.steps(for: file, analysis: OmConvertJob.sleep(input: file),
                                     regenerateWav: true)
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].commandLine,
                       "\"\(file)\" -calibrate 1 -out \"\(scratch.appendingPathComponent("a.wav").path).part\"",
                       "the pre-pass is DoWavConvert(files, \".wav\", -1, true, true)")
    }

    // MARK: - Messages

    func testTheCompletionMessage() {
        XCTAssertEqual(ExportMessages.complete(outputs: ["a.svm.csv", "b.svm.csv"], of: 3),
                       "Output 2/3:\n\na.svm.csv\nb.svm.csv\n\n")
    }

    // MARK: - The data viewer selection

    /// `blockStart = SelectionBeginBlock + OffsetBlocks`, `blockCount = end - begin`.
    func testSelectionBlocksAreAbsoluteInTheFile() throws {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(100)
        let blocks = try XCTUnwrap(DataSelection.blocks(for: start.addingTimeInterval(25)...start.addingTimeInterval(50),
                                                        start: start, end: end,
                                                        offsetBlocks: 2, numBlocks: 100))
        XCTAssertEqual(blocks.start, 27, accuracy: 0.0001, "25% of 100 blocks, plus the 2 header sectors")
        XCTAssertEqual(blocks.count, 25, accuracy: 0.0001)
    }

    func testASelectionOutsideTheFileIsClamped() throws {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(100)
        let blocks = try XCTUnwrap(DataSelection.blocks(for: start.addingTimeInterval(-500)...start.addingTimeInterval(500),
                                                        start: start, end: end,
                                                        offsetBlocks: 2, numBlocks: 100))
        XCTAssertEqual(blocks.start, 2)
        XCTAssertEqual(blocks.count, 100)
    }

    func testAnEmptyOrDegenerateSelectionHasNoBlocks() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertNil(DataSelection.blocks(for: start...start, start: start,
                                          end: start.addingTimeInterval(100),
                                          offsetBlocks: 2, numBlocks: 100))
        XCTAssertNil(DataSelection.blocks(for: start...start.addingTimeInterval(10),
                                          start: start, end: start, offsetBlocks: 2, numBlocks: 100))
    }

    /// The same, read from a real file written by `CwaWriter`.
    func testSelectionBlocksFromARealFile() throws {
        let writer = CwaWriter(hardware: .ax3, deviceId: 1234, sessionId: 1,
                               config: AccelConfig(rate: .hz100, range: .g8))
        let url = scratch.appendingPathComponent("sel.cwa")
        let start = OmDateTime(year: 2026, month: 2, day: 1, hour: 10, minute: 0, second: 0)
        try writer.fileData(startTime: start, blockCount: 24).write(to: url)

        let reader = try OmReader(path: url.path)
        let first = try XCTUnwrap(reader.startTime.date(in: .gmt))
        let last = try XCTUnwrap(reader.endTime.date(in: .gmt))
        XCTAssertEqual(reader.dataOffsetBlocks, 2)
        XCTAssertEqual(reader.dataNumBlocks, 24)
        reader.close()

        let middle = first.addingTimeInterval(last.timeIntervalSince(first) / 2)
        let blocks = try XCTUnwrap(DataSelection.blocks(for: middle...last, path: url.path))
        XCTAssertEqual(blocks.start, 14, accuracy: 0.5)
        XCTAssertEqual(blocks.count, 12, accuracy: 0.5)
    }

    func testTheSelectionDescriptionUsesOmguisDateFormat() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        let end = start.addingTimeInterval(3600)
        XCTAssertEqual(DataSelection.description(for: start...end),
                       formatter.string(from: start) + " - " + formatter.string(from: end))
    }
}
