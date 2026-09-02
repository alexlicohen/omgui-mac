import Foundation
import OmApi
import OmGuiCore
import XCTest

/// A lock around one value, so a pipe handler on another thread can report back into a test.
final class TestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
}

/// `HelperTools`, `ToolProcess` (`ProcessingForm.Execute`) and `ToolJobController`.
final class ToolRunnerTests: XCTestCase {

    var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omgui-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Helpers

    /// A `.CWA` the real helpers can read: 24 blocks of synthetic 100 Hz motion.
    @discardableResult
    func writeCwa(named name: String = "01234_0000000001.cwa", blocks: Int = 24) throws -> String {
        let writer = CwaWriter(hardware: .ax3, deviceId: 1234, sessionId: 1,
                               config: AccelConfig(rate: .hz100, range: .g8))
        let url = scratch.appendingPathComponent(name)
        let start = OmDateTime(year: 2026, month: 2, day: 1, hour: 10, minute: 0, second: 0)
        try writer.fileData(startTime: start, blockCount: blocks).write(to: url)
        return url.path
    }

    /// A stand-in helper, so the process mechanics can be tested without omconvert.
    func writeScript(_ body: String, named name: String = "fake-helper") throws -> String {
        let url = scratch.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func invocation(script: String, arguments: [String], output: String?, final: String) -> ToolInvocation {
        ToolInvocation(executable: .path(script),
                       argumentList: arguments.map(ToolArgument.plain),
                       outputPath: output,
                       finalPath: final,
                       inputPath: "input.cwa")
    }

    static func collector(_ lines: TestBox<[String]>) -> @Sendable (String) -> Void {
        { line in lines.set(lines.get() + [line]) }
    }

    // MARK: - HelperTools

    func testTheEnvironmentOverrideComesFirst() {
        let directories = HelperTools.searchDirectories(
            environment: [HelperTools.environmentOverride: "/opt/helpers", "PATH": "/usr/bin"],
            executable: URL(fileURLWithPath: "/Applications/OmGui.app/Contents/MacOS/OmGui"),
            bundle: URL(fileURLWithPath: "/Applications/OmGui.app"),
            workingDirectory: "/tmp")
        XCTAssertEqual(directories.first?.path, "/opt/helpers")
        XCTAssertTrue(directories.map(\.path).contains("/Applications/OmGui.app/Contents/Helpers"))
        XCTAssertTrue(directories.map(\.path).contains("/usr/bin"))
    }

    func testTheDevelopmentLayoutIsSearched() {
        let directories = HelperTools.searchDirectories(
            environment: [:],
            executable: URL(fileURLWithPath: "/repo/.build/release/OmGui"),
            bundle: nil,
            workingDirectory: "/repo")
        XCTAssertTrue(directories.map(\.path).contains("/repo/build/helpers"),
                      "build/helpers must be found from the executable's ancestors")
    }

    func testAMissingHelperNamesEverywhereItLooked() {
        let directories = [URL(fileURLWithPath: "/nowhere"), URL(fileURLWithPath: "/also-nowhere")]
        XCTAssertThrowsError(try HelperTools.url(for: .omconvert, in: directories)) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("omconvert"))
            XCTAssertTrue(text.contains("/nowhere"))
            XCTAssertTrue(text.contains("/also-nowhere"))
        }
    }

    func testTheHelpersBuiltByTheBuildScriptAreFound() throws {
        for tool in HelperTool.allCases {
            let url = try? HelperTools.url(for: tool)
            try XCTSkipIf(url == nil, "run scripts/build-helpers.sh to exercise the real helpers")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url!.path))
        }
    }

    // MARK: - ToolProcess

    func testSuccessRenamesThePartFile() throws {
        let final = scratch.appendingPathComponent("out.csv").path
        let script = try writeScript("printf 'hello\\n' > \"$1\"; exit 0")
        let job = invocation(script: script, arguments: [final + ".part"],
                             output: final + ".part", final: final)

        let lines = TestBox<[String]>([])
        let result = ToolProcess().run(job, executable: URL(fileURLWithPath: script),
                                       onOutput: ToolRunnerTests.collector(lines))

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.renamed)
        XCTAssertEqual(try String(contentsOfFile: final, encoding: .utf8), "hello\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: final + ".part"))
        XCTAssertTrue(lines.get().contains("<<<SUCCESS>>>"))
        XCTAssertTrue(lines.get().contains("<<<END: 0>>>"))
    }

    func testAnExistingOutputIsReplaced() throws {
        let final = scratch.appendingPathComponent("out.csv").path
        try "old".write(toFile: final, atomically: true, encoding: .utf8)
        let script = try writeScript("printf 'new' > \"$1\"")
        let job = invocation(script: script, arguments: [final + ".part"],
                             output: final + ".part", final: final)

        let lines = TestBox<[String]>([])
        XCTAssertTrue(ToolProcess().run(job, executable: URL(fileURLWithPath: script),
                                        onOutput: ToolRunnerTests.collector(lines)).succeeded)
        XCTAssertEqual(try String(contentsOfFile: final, encoding: .utf8), "new")
        XCTAssertTrue(lines.get().contains { $0.hasPrefix("NOTE: Removing existing output file:") })
    }

    func testANonZeroExitLeavesTheFinalFileAlone() throws {
        let final = scratch.appendingPathComponent("out.csv").path
        try "old".write(toFile: final, atomically: true, encoding: .utf8)
        let script = try writeScript("printf 'partial' > \"$1\"; exit 3")
        let job = invocation(script: script, arguments: [final + ".part"],
                             output: final + ".part", final: final)

        let lines = TestBox<[String]>([])
        let result = ToolProcess().run(job, executable: URL(fileURLWithPath: script),
                                       onOutput: ToolRunnerTests.collector(lines))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(try String(contentsOfFile: final, encoding: .utf8), "old")
        XCTAssertTrue(lines.get().contains("<<<FAILED>>>"))
    }

    func testAMissingOutputIsReported() throws {
        let final = scratch.appendingPathComponent("out.csv").path
        let script = try writeScript("exit 0")
        let job = invocation(script: script, arguments: [], output: final + ".part", final: final)

        let result = ToolProcess().run(job, executable: URL(fileURLWithPath: script), onOutput: { _ in })
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.errorMessage, "ERROR: Output file not found: \(final).part")
    }

    /// The plugin protocol: `p <n>` drives the queue, `e <text>` fails the job.
    func testProgressAndErrorLinesAreParsedFromStdout() throws {
        let final = scratch.appendingPathComponent("out.csv").path
        let script = try writeScript("echo 'p 25'; echo 'p 75'; printf 'x' > \"$1\"")
        let job = invocation(script: script, arguments: [final + ".part"],
                             output: final + ".part", final: final)

        let progress = TestBox<[Int]>([])
        let result = ToolProcess().run(job, executable: URL(fileURLWithPath: script),
                                       onOutput: { _ in },
                                       onProgress: { value in progress.set(progress.get() + [value]) })
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(progress.get(), [25, 75])

        let failing = try writeScript("echo 'e disk full'; exit 0", named: "failing-helper")
        let failure = ToolProcess().run(invocation(script: failing, arguments: [], output: nil, final: final),
                                        executable: URL(fileURLWithPath: failing), onOutput: { _ in })
        XCTAssertFalse(failure.succeeded)
        XCTAssertEqual(failure.errorMessage, "disk full")
    }

    func testCancelKillsTheProcess() throws {
        let final = scratch.appendingPathComponent("out.csv").path
        let script = try writeScript("sleep 30; printf 'x' > \"$1\"")
        let job = invocation(script: script, arguments: [final + ".part"],
                             output: final + ".part", final: final)

        let process = ToolProcess()
        let finished = expectation(description: "run returned")
        let outcome = TestBox<ToolRunResult?>(nil)
        DispatchQueue.global().async {
            outcome.set(process.run(job, executable: URL(fileURLWithPath: script), onOutput: { _ in }))
            finished.fulfill()
        }
        // Give it long enough to be running, then kill it.
        Thread.sleep(forTimeInterval: 0.4)
        process.cancel()
        wait(for: [finished], timeout: 10)

        let result = try XCTUnwrap(outcome.get())
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: final))
    }

    // MARK: - The real helpers

    /// omconvert really produces a `.wav` and an SVM summary from a `CwaWriter` file, through the
    /// same argument builders the menus use.
    func testOmconvertProducesRealOutput() throws {
        let omconvert = try? HelperTools.url(for: .omconvert)
        try XCTSkipIf(omconvert == nil, "run scripts/build-helpers.sh to exercise the real helpers")
        let cwa = try writeCwa()

        let wavJob = OmConvertJob.wav(input: cwa, rate: -1, calibrate: true)
        let wavResult = ToolProcess().run(wavJob, executable: omconvert!, onOutput: { _ in })
        XCTAssertTrue(wavResult.succeeded, "omconvert failed: \(wavResult)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavJob.finalPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wavJob.outputPath!))

        let svmJob = OmConvertJob.svm(input: cwa, epoch: 1, filter: 1, mode: 0)
        let svmResult = ToolProcess().run(svmJob, executable: omconvert!, onOutput: { _ in })
        XCTAssertTrue(svmResult.succeeded, "omconvert failed: \(svmResult)")
        let svm = try String(contentsOfFile: svmJob.finalPath, encoding: .utf8)
        XCTAssertTrue(svm.contains("Time"), "the SVM file should carry omconvert's header row")
        XCTAssertGreaterThan(svm.split(separator: "\n").count, 1)
    }

    /// cwa-convert really produces the raw CSV, and honours the selection's block range.
    func testCwaConvertProducesRawCsv() throws {
        let cwaConvert = try? HelperTools.url(for: .cwaConvert)
        try XCTSkipIf(cwaConvert == nil, "run scripts/build-helpers.sh to exercise the real helpers")
        let cwa = try writeCwa()

        var options = RawCsvOptions(sourceFile: cwa, workingFolder: scratch)
        let all = OmConvertJob.rawCsv(options)
        XCTAssertTrue(ToolProcess().run(all, executable: cwaConvert!, onOutput: { _ in }).succeeded)
        let everything = try String(contentsOfFile: all.finalPath, encoding: .utf8)
            .split(separator: "\n").count
        XCTAssertEqual(everything, 24 * 80, "24 blocks of 80 accelerometer samples")

        // `-blockstart` counts sectors from the start of the file, so it includes the header.
        options.outputFile = scratch.appendingPathComponent("slice.csv").path
        options.blockStart = "2"
        options.blockCount = "3"
        let slice = OmConvertJob.rawCsv(options)
        XCTAssertTrue(ToolProcess().run(slice, executable: cwaConvert!, onOutput: { _ in }).succeeded)
        XCTAssertEqual(try String(contentsOfFile: slice.finalPath, encoding: .utf8)
            .split(separator: "\n").count, 3 * 80)
    }

    // MARK: - ToolJobController and the Plugin Queue

    @MainActor
    func testJobsRunInOrderAndReportIntoTheQueue() async throws {
        let queue = PluginQueue()
        let controller = ToolJobController(queue: queue, resolve: { tool in
            throw HelperToolMissing(tool: tool, searched: [])
        })
        let first = scratch.appendingPathComponent("a.txt").path
        let second = scratch.appendingPathComponent("b.txt").path
        let script = try writeScript("echo 'p 50'; printf 'x' > \"$1\"")

        for path in [first, second] {
            controller.enqueue(ToolJob(name: "Fake", source: DotNetPath.fileName(path),
                                       steps: [invocation(script: script, arguments: [path + ".part"],
                                                          output: path + ".part", final: path)]))
        }
        XCTAssertEqual(queue.items.map(\.pluginName), ["Fake", "Fake"])
        XCTAssertEqual(queue.items.map(\.source), ["a.txt", "b.txt"])

        try await waitUntil { !controller.isBusy }
        XCTAssertEqual(queue.items.map(\.state), [.complete, .complete])
        XCTAssertEqual(queue.items.map(\.progressText), ["Complete", "Complete"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second))

        queue.clearCompleted()
        XCTAssertTrue(queue.items.isEmpty)
    }

    @MainActor
    func testAFailedJobIsMarkedError() async throws {
        let queue = PluginQueue()
        let controller = ToolJobController(queue: queue, resolve: { tool in
            throw HelperToolMissing(tool: tool, searched: [])
        })
        let script = try writeScript("exit 9")
        let final = scratch.appendingPathComponent("never.txt").path
        controller.enqueue(ToolJob(name: "Fake", source: "x",
                                   steps: [invocation(script: script, arguments: [],
                                                      output: final + ".part", final: final)]))
        try await waitUntil { !controller.isBusy }
        XCTAssertEqual(queue.items.first?.state, .error)
        XCTAssertEqual(queue.items.first?.progressText, "Error")
    }

    /// The Plugin Queue's Cancel button kills the helper behind the row.
    @MainActor
    func testCancellingAQueuedRowStopsTheProcess() async throws {
        let queue = PluginQueue()
        let controller = ToolJobController(queue: queue, resolve: { tool in
            throw HelperToolMissing(tool: tool, searched: [])
        })
        let script = try writeScript("sleep 30")
        let final = scratch.appendingPathComponent("never.txt").path
        let id = controller.enqueue(ToolJob(name: "Fake", source: "x",
                                            steps: [invocation(script: script, arguments: [],
                                                               output: nil, final: final)]))
        try await waitUntil { queue.items.first?.state == .running }
        queue.cancel([id])
        try await waitUntil { !controller.isBusy }
        XCTAssertEqual(queue.items.first?.state, .cancelled)
        XCTAssertEqual(queue.items.first?.progressText, "Cancelled")
    }

    /// A step that cannot resolve its helper fails the job with the message the user would see.
    @MainActor
    func testAMissingHelperFailsTheJob() async throws {
        let queue = PluginQueue()
        let controller = ToolJobController(queue: queue,
                                           resolve: { tool in
            throw HelperToolMissing(tool: tool, searched: ["/nowhere"])
        })
        let transcript = TestBox<[String]>([])
        controller.log = { line in transcript.set(transcript.get() + [line]) }
        controller.enqueue(ToolJob(name: "SVM", source: "a.cwa",
                                   steps: [OmConvertJob.svm(input: "/w/a.cwa", epoch: 60, filter: 1, mode: 0)]))
        try await waitUntil { !controller.isBusy }
        XCTAssertEqual(queue.items.first?.state, .error)
        XCTAssertTrue(transcript.get().contains { $0.contains("omconvert") && $0.contains("/nowhere") })
    }

    @MainActor
    func waitUntil(timeout: TimeInterval = 20,
                   _ condition: @MainActor () -> Bool,
                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
