import Foundation
import OmApi
import OmGuiCore
import XCTest

/// The guards that used to live only in `AppModel`.
///
/// `swift test` never loads the `OmGui` executable target and nothing runs `--self-test`, so
/// deleting the self-test backend check, the poll gate, the `checkFirmware` calls or the config-log
/// warning left the whole suite green (`refs/12-deep-review-2.md` L2). They are in `OmGuiCore` now,
/// and these are the tests that hold them there.
@MainActor
final class FlowGuardTests: XCTestCase {

    // MARK: - C1: `--self-test` may only ever run against the mock

    func testSelfTestIsRefusedForAnythingButTheMockBackend() throws {
        let harness = try FaultHarness()
        defer { harness.tearDown() }

        XCTAssertFalse(SelfTestGuard.mustRefuse(selfTestRequested: true, backend: harness.mock),
                       "the mock is the one backend the self-test may drive")
        XCTAssertTrue(SelfTestGuard.mustRefuse(selfTestRequested: true, backend: harness.backend),
                      "anything that is not a MockBackend may be real hardware")
        XCTAssertFalse(SelfTestGuard.mustRefuse(selfTestRequested: false, backend: harness.backend),
                       "an ordinary run is not refused")
    }

    // MARK: - C4: the poll never runs beside a foreground flow

    func testTheGateRefusesAPollWhileAFlowOwnsTheDevices() {
        let gate = BackgroundTaskGate()
        XCTAssertTrue(gate.beginPoll())
        gate.endPoll()

        gate.block()
        XCTAssertFalse(gate.beginPoll(), "BlockBackgroundTasks stops the poll starting at all")
        XCTAssertFalse(gate.pollInFlight)

        gate.enable()
        XCTAssertTrue(gate.beginPoll())
    }

    func testTheGateRefusesASecondConcurrentPoll() {
        let gate = BackgroundTaskGate()
        XCTAssertTrue(gate.beginPoll())
        XCTAssertFalse(gate.beginPoll(), "two polls at once would open one device's port twice")
        gate.endPoll()
        XCTAssertTrue(gate.beginPoll())
    }

    // MARK: - H5: draining the poll before a flow starts

    /// The wait has to cover a *whole* first poll: SAMPLE, ID, TIME, HIBERNATE, STOP, SESSION and
    /// RATE, each with libomapi's 2 s command timeout (`OmGetDelays` is two commands). The 5 s cap
    /// this replaces expired during perfectly ordinary polls.
    func testTheDefaultDrainTimeoutOutlastsAFullPoll() {
        XCTAssertGreaterThanOrEqual(BackgroundTaskGate.defaultDrainTimeout, 15)
    }

    func testDrainingReturnsFalseWhenThePollNeverFinishes() async {
        let gate = BackgroundTaskGate(drainTimeout: 0.15, drainPollInterval: 0.01)
        XCTAssertTrue(gate.beginPoll())          // a poll that is wedged on a device's port

        let started = Date()
        let drained = await gate.drainPoll()

        XCTAssertFalse(drained, "a poll that never finishes must be reported, not waited out")
        XCTAssertTrue(gate.pollInFlight, "and it is still running: the flow must not start")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.15,
                                    "the drain gave up before its own timeout")
    }

    func testDrainingReturnsTrueOnceTheSlowPollFinishes() async {
        let gate = BackgroundTaskGate(drainTimeout: 5, drainPollInterval: 0.01)
        XCTAssertTrue(gate.beginPoll())
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            gate.endPoll()
        }

        let drained = await gate.drainPoll()
        XCTAssertTrue(drained)
        XCTAssertFalse(gate.pollInFlight)
    }

    // MARK: - H6: Clear's recording-with-data exclusion

    /// The CLI cannot read `DeviceToolbarState`, so it asks `ClearGuard` the same question the
    /// toolbar predicate answers. These are the two halves that have to agree.
    func testClearGuardIsExactlyWhatTheToolbarPredicateExcludes() throws {
        let harness = try GuiHarness()
        defer { harness.tearDown() }
        let device = try harness.device(1234)      // an AX3 holding 24 blocks of data
        device.update(force: true)
        XCTAssertTrue(device.hasData)

        // Stopped with data: the Clear button is live and the guard says nothing.
        XCTAssertEqual(device.isRecording, .stopped)
        XCTAssertFalse(ClearGuard.isRecordingWithData(device))
        var row = DeviceRow(device: device, timeCheck: true)
        XCTAssertTrue(DeviceToolbarState(selection: [row]).clear)
        XCTAssertFalse(ClearGuard.isRecordingWithData(row))

        // The participant plugs the watch in mid-wear to charge: recording, and holding data.
        XCTAssertTrue(device.alwaysRecord())
        device.update(force: true)
        XCTAssertEqual(device.isRecording, .always)
        XCTAssertTrue(device.hasData)
        XCTAssertTrue(ClearGuard.isRecordingWithData(device))
        row = DeviceRow(device: device, timeCheck: true)
        XCTAssertFalse(DeviceToolbarState(selection: [row]).clear,
                       "the GUI greys Clear out here — the CLI has to refuse for the same reason")
        XCTAssertTrue(ClearGuard.isRecordingWithData(row))
        XCTAssertEqual(ClearGuard.recordingWithData([device]).map(\.deviceId), [1234])

        // A device recording with nothing on it yet is *not* excluded: Clear is how a mis-set
        // interval is undone.
        let empty = try harness.device(9999)
        empty.update(force: true)
        XCTAssertTrue(empty.alwaysRecord())
        empty.update(force: true)
        XCTAssertFalse(empty.hasData)
        XCTAssertFalse(ClearGuard.isRecordingWithData(empty))
        XCTAssertTrue(DeviceToolbarState(selection: [DeviceRow(device: empty, timeCheck: true)]).clear)
    }

    /// `omgui-cli clear --mock --all` — the whole stock selection, nothing configured first.
    ///
    /// The guard is only worth anything if a plain `--mock` run can reach it, so the mock ships a
    /// device recording with data (`MockBackend.Spec.defaults`, id 7654). Select-all has to be
    /// refused, naming that device and no other, and the toolbar has to grey Clear out for the same
    /// selection.
    func testTheStockMockSelectionIsRefusedByTheClearGuard() throws {
        let harness = try GuiHarness()
        defer { harness.tearDown() }
        let devices = harness.api.devices
        for device in devices { device.update(force: true) }

        let unsafe = ClearGuard.recordingWithData(devices)
        XCTAssertEqual(unsafe.map(\.deviceId), [7654],
                       "a plain --mock run has to reach the guard, or nothing exercises it")
        XCTAssertTrue(ClearGuard.refusalMessage(ids: unsafe.map { FilenameTemplate.deviceIdString($0.deviceId) })
            .contains("07654"), "the refusal has to name the device the operator must look at")

        let rows = devices.map { DeviceRow(device: $0, timeCheck: true) }
        XCTAssertFalse(DeviceToolbarState(selection: rows).clear,
                       "the GUI greys Clear out for this selection; the CLI refuses it")

        // ...and it is that one device the refusal is about: drop it and the guard says nothing,
        // and the stopped-with-data unit next to it is still clearable on its own.
        let rest = devices.filter { $0.deviceId != 7654 }
        XCTAssertTrue(ClearGuard.recordingWithData(rest).isEmpty)
        let stoppedWithData = try XCTUnwrap(rest.first { $0.deviceId == 1234 })
        XCTAssertTrue(DeviceToolbarState(selection: [DeviceRow(device: stoppedWithData, timeCheck: true)]).clear)
    }

    // MARK: - The preflight both front ends run

    func testThePreflightRefusesADeviceOnBlacklistedFirmware() throws {
        let spec = MockBackend.Spec(deviceId: 1234, serialId: "CWA17_01234",
                                    volumeLabel: "AX317_01234", port: "/dev/mock",
                                    battery: 90, firmware: 42, hardware: 65)
        let harness = try GuiHarness(specs: [spec])
        defer { harness.tearDown() }
        let device = try harness.device(1234)
        device.update(force: true)

        let prompter = RecordingPrompter()
        prompter.confirmAnswers = [false]
        XCTAssertEqual(DeviceFlowPreflight.run(devices: [device], blacklist: .builtIn,
                                               prompt: prompter),
                       .firmware)

        let carryOn = RecordingPrompter()
        carryOn.confirmAnswers = [true]
        XCTAssertNil(DeviceFlowPreflight.run(devices: [device], blacklist: .builtIn, prompt: carryOn))
    }

    func testThePreflightRefusesARecordingDeviceWithDataOnlyWhenAsked() throws {
        let harness = try GuiHarness()
        defer { harness.tearDown() }
        let device = try harness.device(1234)
        device.update(force: true)
        XCTAssertTrue(device.alwaysRecord())

        let prompter = RecordingPrompter()
        XCTAssertEqual(DeviceFlowPreflight.run(devices: [device], blacklist: .builtIn,
                                               prompt: prompter, refuseRecordingWithData: true),
                       .recordingWithData(ids: ["01234"]))
        // The GUI leaves it off, because the toolbar has already made the same exclusion.
        XCTAssertNil(DeviceFlowPreflight.run(devices: [device], blacklist: .builtIn,
                                             prompt: prompter, refuseRecordingWithData: false))
    }

    func testThePreflightRefusesADownloadingDeviceAndSaysSo() throws {
        let harness = try GuiHarness(downloadSteps: 400, downloadDelay: 0.02)
        defer { harness.tearDown() }
        let device = try harness.device(1234)
        device.update(force: true)
        let paths = FilenameTemplate.downloadPaths(workspace: harness.workspace, baseName: "busy")
        try device.beginDownloading(to: paths.partial.path, renameTo: paths.final.path)
        defer { device.cancelDownload() }
        let deadline = Date().addingTimeInterval(5)
        while !device.isDownloading && Date() < deadline { usleep(5_000) }
        XCTAssertTrue(device.isDownloading)

        let prompter = RecordingPrompter()
        XCTAssertEqual(DeviceFlowPreflight.run(devices: [device], blacklist: .builtIn, prompt: prompter),
                       .downloading(ids: ["01234"], total: 1))
        XCTAssertEqual(prompter.warnings.first?.title, FlowMessages.downloadInProgressTitle)
    }

    // MARK: - C20: the configuration log

    func testConfigLogReportsThePathItCouldNotWrite() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omgui-configlog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let good = folder.appendingPathComponent("config.csv").path
        XCTAssertNil(ConfigLog.append(["one", "two"], to: good))
        XCTAssertEqual(try String(contentsOfFile: good, encoding: .utf8), "one\ntwo\n")

        XCTAssertNil(ConfigLog.append([], to: good), "nothing to write is not a failure")
        XCTAssertNil(ConfigLog.append(["one"], to: nil), "no -configlog is not a failure")

        let unwritable = folder.appendingPathComponent("missing/config.csv").path
        XCTAssertEqual(ConfigLog.append(["one"], to: unwritable), unwritable,
                       "an unwritable -configlog path must be reported, not swallowed")
    }
}
