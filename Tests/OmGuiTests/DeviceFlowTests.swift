import Foundation
import OmApi
import OmGuiCore
import XCTest

/// Download / Clear / Stop / Record orchestration, driven against `MockBackend`.
@MainActor
final class DeviceFlowTests: XCTestCase {

    private var harness: GuiHarness!

    override func setUpWithError() throws {
        harness = try GuiHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
    }

    private func poll(_ device: OmDevice) {
        device.update(force: true)
    }

    // MARK: - Download

    func testResolveProducesTheTemplateFilename() throws {
        let device = try harness.device(1234)
        poll(device)
        switch DownloadFlow.resolve(device: device,
                                    template: FilenameTemplate.defaultTemplate,
                                    workspace: harness.workspace) {
        case .plan(let plan):
            XCTAssertEqual(plan.finalPath.lastPathComponent, "01234_0000000001.cwa")
            XCTAssertEqual(plan.partialPath.lastPathComponent, "01234_0000000001.cwa.part")
        case .failure(let reason):
            XCTFail("expected a plan, got \(reason)")
        }
    }

    func testResolveExpandsMetadataPlaceholders() throws {
        let device = try harness.device(1234)
        poll(device)
        switch DownloadFlow.resolve(device: device,
                                    template: "{DeviceId}_{SubjectCode}_{SubjectSite}",
                                    workspace: harness.workspace) {
        case .plan(let plan):
            // The whitelist sanitiser turns the space in "left wrist" into an underscore.
            XCTAssertEqual(plan.finalPath.lastPathComponent, "01234_P001_left_wrist.cwa")
        case .failure(let reason):
            XCTFail("expected a plan, got \(reason)")
        }
    }

    func testResolveRefusesADeviceWithNoData() throws {
        let device = try harness.device(5678)
        poll(device)
        guard case .failure(let reason) = DownloadFlow.resolve(device: device,
                                                               template: FilenameTemplate.defaultTemplate,
                                                               workspace: harness.workspace) else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(reason, "device has no data")
    }

    func testResolveRefusesARecordingDevice() throws {
        let device = try harness.device(5678)
        XCTAssertTrue(device.alwaysRecord())
        poll(device)
        guard case .failure(let reason) = DownloadFlow.resolve(device: device,
                                                               template: FilenameTemplate.defaultTemplate,
                                                               workspace: harness.workspace) else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(reason, "device is recording")
    }

    func testDownloadRunsEndToEnd() throws {
        let device = try harness.device(1234)
        poll(device)
        let waiter = DownloadWaiter()
        waiter.observe(harness.api)
        waiter.expect([1234])

        let prompter = RecordingPrompter()
        let outcome = DownloadFlow.run(devices: [device],
                                       template: FilenameTemplate.defaultTemplate,
                                       workspace: harness.workspace,
                                       prompt: prompter)
        XCTAssertEqual(outcome.started.count, 1)
        XCTAssertNil(outcome.summary)
        XCTAssertTrue(prompter.warnings.isEmpty)

        XCTAssertTrue(waiter.wait(), "download did not finish")
        XCTAssertEqual(waiter.status(1234), .complete)

        let final = harness.workspace.appendingPathComponent("01234_0000000001.cwa")
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path + ".part"))

        // The downloaded file is a real CWA carrying the device's metadata.
        let metadata = try XCTUnwrap(FileMetadata(path: final.path))
        XCTAssertEqual(metadata.deviceId, 1234)
        XCTAssertEqual(metadata.named["StudyCode"], "ARIA-IMPACT")
    }

    func testDownloadPromptsBeforeOverwritingAndRespectsCancel() throws {
        let device = try harness.device(1234)
        poll(device)
        let final = harness.workspace.appendingPathComponent("01234_0000000001.cwa")
        try Data("existing".utf8).write(to: final)

        let prompter = RecordingPrompter()
        prompter.confirmAnswers = [false]
        let outcome = DownloadFlow.run(devices: [device],
                                       template: FilenameTemplate.defaultTemplate,
                                       workspace: harness.workspace,
                                       prompt: prompter)
        XCTAssertTrue(outcome.started.isEmpty)
        XCTAssertEqual(outcome.errors["01234"], "Not overwriting existing data file.")
        XCTAssertEqual(prompter.confirms.first?.title, FlowMessages.overwriteTitle)
        XCTAssertTrue(prompter.confirms.first?.message.hasPrefix("File already exists:") ?? false)
        // The existing file is left alone.
        XCTAssertEqual(try Data(contentsOf: final), Data("existing".utf8))
        // ...and the "Download Status" summary is shown.
        XCTAssertEqual(prompter.warnings.last?.title, FlowMessages.downloadStatusTitle)
        XCTAssertTrue(outcome.summary?.contains("Device: 01234 - Status: Not overwriting existing data file.") ?? false)
    }

    func testDownloadOverwritesWhenConfirmed() throws {
        let device = try harness.device(1234)
        poll(device)
        let final = harness.workspace.appendingPathComponent("01234_0000000001.cwa")
        try Data("existing".utf8).write(to: final)

        let waiter = DownloadWaiter()
        waiter.observe(harness.api)
        waiter.expect([1234])

        let prompter = RecordingPrompter()
        prompter.confirmAnswers = [true]
        let outcome = DownloadFlow.run(devices: [device],
                                       template: FilenameTemplate.defaultTemplate,
                                       workspace: harness.workspace,
                                       prompt: prompter)
        XCTAssertEqual(outcome.started.count, 1)
        XCTAssertTrue(waiter.wait())
        XCTAssertNotEqual(try Data(contentsOf: final), Data("existing".utf8))
    }

    func testCancelStopsADownload() throws {
        harness.backend.downloadStepCount = 200
        harness.backend.downloadStepDelay = 0.02
        let device = try harness.device(1234)
        poll(device)
        let waiter = DownloadWaiter()
        waiter.observe(harness.api)
        waiter.expect([1234])

        DownloadFlow.run(devices: [device],
                         template: FilenameTemplate.defaultTemplate,
                         workspace: harness.workspace,
                         prompt: RecordingPrompter())
        device.cancelDownload()
        XCTAssertTrue(waiter.wait())
        XCTAssertEqual(waiter.status(1234), .cancelled)
        XCTAssertEqual(DeviceRow.downloadText(status: .cancelled, value: 0), "Cancelled")
    }

    func testDownloadLogLineFormatAndAppend() throws {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 2
        components.hour = 7; components.minute = 8; components.second = 9
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let date = calendar.date(from: components)!
        let line = DownloadLog.line(at: date, filename: "01234_0000000001.cwa")
        XCTAssertEqual(line, "2026-09-02 07:08:09,DOWNLOAD-OK,01234_0000000001.cwa")

        let path = harness.workspace.appendingPathComponent("download.log").path
        XCTAssertTrue(DownloadLog.append(line, to: path))
        XCTAssertTrue(DownloadLog.append(line, to: path))
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }

    // MARK: - Clear

    func testClearPromptWording() {
        XCTAssertTrue(ClearFlow.wipeRequested(shiftHeld: false))
        XCTAssertFalse(ClearFlow.wipeRequested(shiftHeld: true))
        XCTAssertEqual(ClearFlow.promptMessage(wipe: true, count: 3), "Wipe 3 device(s)?")
        XCTAssertEqual(ClearFlow.promptMessage(wipe: false, count: 1), "Clear 1 device(s)?")
        XCTAssertEqual(ClearFlow.progressTitle(wipe: true), "Wiping")
        XCTAssertEqual(ClearFlow.progressTitle(wipe: false), "Clearing")
    }

    func testClearResetsTheDevice() throws {
        let device = try harness.device(1234)
        poll(device)
        XCTAssertEqual(device.sessionId, 1)
        XCTAssertTrue(device.hasData)

        let collector = ProgressCollector()
        let fails = ClearFlow.perform(devices: [device], wipe: true, progress: { collector.add($0) })
        let reports = collector.reports
        XCTAssertTrue(fails.isEmpty)
        XCTAssertEqual(device.sessionId, 0)
        XCTAssertEqual(device.startTime, .infinite)
        XCTAssertEqual(device.stopTime, .infinite)
        XCTAssertEqual(try device.metadata(), "")
        XCTAssertEqual(try device.accelConfig(), AccelConfig.deviceDefault)
        XCTAssertFalse(device.hasData)
        XCTAssertEqual(reports.first?.message, "Wiping device 1 of 1.")
        XCTAssertEqual(reports.last?.percent, 100)
    }

    func testEnsureNoSelectedDownloadingWarnsAndBlocks() throws {
        harness.backend.downloadStepCount = 200
        harness.backend.downloadStepDelay = 0.02
        let device = try harness.device(1234)
        poll(device)
        DownloadFlow.run(devices: [device],
                         template: FilenameTemplate.defaultTemplate,
                         workspace: harness.workspace,
                         prompt: RecordingPrompter())
        // The first progress callback arrives on the backend's own queue.
        let deadline = Date().addingTimeInterval(5)
        while !device.isDownloading && Date() < deadline { usleep(5_000) }
        XCTAssertTrue(device.isDownloading)

        let prompter = RecordingPrompter()
        XCTAssertFalse(ensureNoSelectedDownloading([device], prompt: prompter))
        XCTAssertEqual(prompter.warnings.first?.title, FlowMessages.downloadInProgressTitle)
        XCTAssertEqual(prompter.warnings.first?.message,
                       "Download in progress for 1 (of 1 selected) device(s) -- cannot change configuration of these devices until download complete or cancelled.")
        device.cancelDownload()
    }

    // MARK: - Stop

    func testStopEndsRecording() throws {
        let device = try harness.device(5678)
        XCTAssertTrue(device.alwaysRecord())
        poll(device)
        XCTAssertEqual(device.isRecording, .always)

        let fails = StopFlow.perform(devices: [device], progress: nil)
        XCTAssertTrue(fails.isEmpty)
        XCTAssertEqual(device.isRecording, .stopped)
        XCTAssertEqual(device.startTime, .infinite)
        XCTAssertEqual(device.stopTime, .infinite)
    }

    func testStopSkipsDevicesThatAreNotRecording() throws {
        let device = try harness.device(5678)
        poll(device)
        let collector = ProgressCollector()
        _ = StopFlow.perform(devices: [device], progress: { collector.add($0) })
        XCTAssertEqual(collector.reports.map(\.message), ["Done"])
    }

    // MARK: - Record

    func testRecordCommitsTheWholeSequence() throws {
        let device = try harness.device(9999)
        poll(device)

        var model = RecordingSettings(devices: [RecordingDeviceInfo(device: device)])
        model.finishInitialisation()
        model.sessionId = 4321
        model.frequencyIndex = 4          // 200 Hz
        model.rangeIndex = 3              // 16 g
        model.flash = true
        model.metadata.studyCode = "ARIA"
        model.metadata.subjectCode = "P042"

        let collector = ProgressCollector()
        let result = RecordFlow.perform(devices: [device], settings: model, progress: { collector.add($0) })
        let reports = collector.reports

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(device.sessionId, 4321)
        XCTAssertEqual(try device.metadata(), "_s=ARIA&_sc=P042")
        XCTAssertEqual(try device.accelConfig(), AccelConfig(rate: .hz200, range: .g16))
        XCTAssertEqual(try device.maxSamples(), 0)
        XCTAssertEqual(device.startTime, .zero)
        XCTAssertEqual(device.stopTime, .infinite)
        XCTAssertEqual(device.isRecording, .always)

        // Five progress steps per device, in OMGUI's order, then "Done".
        let messages = reports.map(\.message)
        XCTAssertTrue(messages.contains { $0.hasSuffix("(session)") })
        XCTAssertTrue(messages.contains { $0.hasSuffix("(metadata)") })
        XCTAssertTrue(messages.contains { $0.hasSuffix("(config)") })
        XCTAssertTrue(messages.contains { $0.hasSuffix("(time sync)") })
        XCTAssertTrue(messages.contains { $0.hasSuffix("(interval)") })
        XCTAssertEqual(messages.last, "Done")
        XCTAssertEqual(result.logLines.count, 1)
        XCTAssertTrue(result.logLines[0].contains(",AX3-CONFIG-OK,9999,4321,0,-1,200,16,"))
    }

    func testRecordWritesAnIntervalWhenNotImmediate() throws {
        let device = try harness.device(9999)
        poll(device)

        var model = RecordingSettings(devices: [RecordingDeviceInfo(device: device)])
        model.finishInitialisation()
        model.immediately = false
        let start = Date().addingTimeInterval(3600)
        model.setStart(start)
        model.setDuration(days: 1, hours: 0, minutes: 0)

        let result = RecordFlow.perform(devices: [device], settings: model, progress: nil)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(device.startTime, OmDateTime(date: model.startDate))
        XCTAssertEqual(device.stopTime, OmDateTime(date: model.endDate))
        XCTAssertEqual(device.isRecording, .interval)
    }

    func testConfigLogLineFormat() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 2
        components.hour = 11; components.minute = 22; components.second = 33
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let date = calendar.date(from: components)!

        var model = RecordingSettings(devices: [.ax3()])
        model.finishInitialisation()
        model.sessionId = 7
        model.metadata.studyNotes = "a \"quoted\" note"

        let line = RecordFlow.configLogLine(at: date, ok: true, deviceId: 1234, settings: model)
        XCTAssertEqual(line,
                       "2026-09-02 11:22:33,AX3-CONFIG-OK,1234,7,0,-1,100,8,\"_n=a+%22quoted%22+note\"")

        let failed = RecordFlow.configLogLine(at: date, ok: false, deviceId: 1234, settings: model)
        XCTAssertTrue(failed.contains(",AX3-CONFIG-ERROR,"))
    }

    // MARK: - Failure reporting

    func testFailureMessagesMatchUpstream() {
        XCTAssertEqual(FlowMessages.failed(ids: ["1234", "5678"]),
                       "Failed operation on 2 device(s):\n1234; 5678" + FlowMessages.advice)
        XCTAssertEqual(FlowMessages.failed(details: [(id: "1234", error: "Time sync. failed")]),
                       "Failed operation on 1 device(s):\n1234: Time sync. failed\n" + FlowMessages.advice)
    }

    // MARK: - Identify

    func testIdentifyBlinksBlueAndMagentaThenReturnsToAuto() {
        var controller = IdentifyController()
        XCTAssertFalse(controller.isRunning)
        controller.start()
        XCTAssertTrue(controller.isRunning)

        var states: [LedState] = []
        while controller.isRunning { states.append(controller.advance()) }
        XCTAssertEqual(states, [.blue, .magenta, .blue, .magenta, .blue, .magenta, .blue, .magenta, .blue, .auto])
        XCTAssertFalse(controller.isRunning)
    }

    func testIdentifySetsTheLedOnTheDevice() throws {
        let device = try harness.device(1234)
        XCTAssertTrue(device.setLed(.blue))
        XCTAssertEqual(device.ledColor, .blue)
        XCTAssertEqual(DeviceRow(device: device, timeCheck: true).ledIconIndex, 1)
        XCTAssertTrue(device.setLed(.auto))
        XCTAssertEqual(DeviceRow(device: device, timeCheck: true).ledIconIndex, 8)
    }
}
