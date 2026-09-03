import Foundation
import OmApi
import OmGuiCore
import XCTest

/// Every way `RecordFlow.perform` can fail, and the `SETTINGS.INI` step.
///
/// Both existing callers assert `failures.isEmpty`, so before these the only thing the suite knew
/// about the flow was its happy path: an `AX3-CONFIG-ERROR` had never traversed it, and the
/// `DATAMODE=20` write — without which an AX3 records packed data the pipeline cannot use — had no
/// coverage at all.
@MainActor
final class RecordFlowFailureTests: XCTestCase {

    private var harness: FaultHarness!

    override func setUpWithError() throws {
        harness = try FaultHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
    }

    /// 9999 is an AX3 with no data; 5678 is an AX6.
    private func settings(for device: OmDevice, sessionId: UInt32 = 4321) -> RecordingSettings {
        var model = RecordingSettings(devices: [RecordingDeviceInfo(device: device)])
        model.finishInitialisation()
        model.sessionId = sessionId
        model.metadata.studyCode = "STUDY"
        return model
    }

    private func perform(_ devices: [OmDevice], _ model: RecordingSettings) -> RecordFlow.Result {
        RecordFlow.perform(devices: devices, settings: model, progress: nil, timing: .fast)
    }

    private func assertFailed(_ result: RecordFlow.Result, _ error: String, deviceId: UInt32) {
        XCTAssertEqual(result.failures.map(\.id), [String(deviceId)])
        XCTAssertEqual(result.failures.map(\.error), [error])
        XCTAssertTrue(result.configured.isEmpty, "a failed device must not be reported as configured")
        XCTAssertEqual(result.logLines.count, 1)
        XCTAssertTrue(result.logLines[0].contains(",AX3-CONFIG-ERROR,\(deviceId),"),
                      "expected an AX3-CONFIG-ERROR row, got \(result.logLines[0])")
    }

    // MARK: - The seven per-device failures

    func testDownloadingDeviceIsRefusedBeforeAnythingIsWritten() throws {
        harness.mock.downloadStepCount = 400
        harness.mock.downloadStepDelay = 0.02
        let device = try harness.device(1234)
        device.update(force: true)
        let paths = FilenameTemplate.downloadPaths(workspace: harness.workspace, baseName: "busy")
        try device.beginDownloading(to: paths.partial.path, renameTo: paths.final.path)
        let deadline = Date().addingTimeInterval(5)
        while !device.isDownloading && Date() < deadline { usleep(5_000) }
        XCTAssertTrue(device.isDownloading)

        harness.mock.clearCalls()
        let result = perform([device], settings(for: device))
        assertFailed(result, "Device is downloading", deviceId: 1234)
        XCTAssertTrue(harness.mock.calls.filter { $0.name != "cancelDownload" }.isEmpty,
                      "nothing may be written to a downloading device: \(harness.mock.callDescriptions)")
        device.cancelDownload()
    }

    func testSessionIdFailureStopsBeforeTheConfiguration() throws {
        let device = try harness.device(9999)
        harness.backend.fail(.setSessionId)
        harness.mock.clearCalls()

        let result = perform([device], settings(for: device))
        assertFailed(result, "Failed to set session ID", deviceId: 9999)
        let names = harness.mock.calls.map(\.name)
        XCTAssertFalse(names.contains("setAccelConfig"), "\(names)")
        XCTAssertFalse(names.contains("setDelays"), "\(names)")
        XCTAssertFalse(names.contains("eraseAndCommit"), "\(names)")
    }

    func testMetadataFailure() throws {
        let device = try harness.device(9999)
        harness.backend.fail(.setMetadata)
        harness.mock.clearCalls()

        let result = perform([device], settings(for: device))
        assertFailed(result, "Metadata set failed", deviceId: 9999)
        XCTAssertFalse(harness.mock.calls.map(\.name).contains("setAccelConfig"))
    }

    func testSensorConfigFailure() throws {
        let device = try harness.device(9999)
        harness.backend.fail(.setAccelConfig)
        harness.mock.clearCalls()

        let result = perform([device], settings(for: device))
        assertFailed(result, "Sensor config failed", deviceId: 9999)
        XCTAssertFalse(harness.mock.calls.map(\.name).contains("setDelays"))
    }

    /// A device whose clock latches the write but never ticks: upstream's second check, and the
    /// whole reason `syncTime` waits at all.
    func testTimeSyncFailsWhenTheDeviceClockIsNotTicking() throws {
        let device = try harness.device(9999)
        harness.backend.frozenClock = true
        harness.mock.clearCalls()

        XCTAssertFalse(device.syncTime(), "a frozen clock must not pass the tick check")

        let result = perform([device], settings(for: device))
        assertFailed(result, "Time sync. failed", deviceId: 9999)
        XCTAssertFalse(harness.mock.calls.map(\.name).contains("setDelays"),
                       "the recording must not be started on a device with a dead clock")
    }

    func testTimeSyncFailsWhenTheTimeCannotBeWritten() throws {
        let device = try harness.device(9999)
        harness.backend.fail(.setTime)

        let result = perform([device], settings(for: device))
        assertFailed(result, "Time sync. failed", deviceId: 9999)
    }

    func testAlwaysIntervalFailure() throws {
        let device = try harness.device(9999)
        harness.backend.fail(.commit)

        var model = settings(for: device)
        model.immediately = true
        let result = perform([device], model)
        assertFailed(result, "Set interval (always) failed", deviceId: 9999)
        XCTAssertEqual(device.isRecording, .stopped)
    }

    func testFixedIntervalFailure() throws {
        let device = try harness.device(9999)
        harness.backend.fail(.setDelays)

        var model = settings(for: device)
        model.immediately = false
        model.setStart(Date().addingTimeInterval(3600))
        model.setDuration(days: 1, hours: 0, minutes: 0)
        let result = perform([device], model)
        assertFailed(result, "Set interval failed", deviceId: 9999)
    }

    // MARK: - The unpacked / SETTINGS.INI step

    func testUnpackedWritesDataModeToTheDeviceVolume() throws {
        let device = try harness.device(9999)
        var model = settings(for: device)
        model.unpacked = true

        let result = perform([device], model)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(result.configured, [9999])

        let settingsPath = (device.devicePath as NSString).appendingPathComponent("SETTINGS.INI")
        let written = try String(contentsOfFile: settingsPath, encoding: .ascii)
        XCTAssertEqual(written, "DATAMODE=20\r\n")
        XCTAssertEqual(written, RecordFlow.unpackedSettings)
    }

    func testUnpackedIsNotWrittenOnADeviceWithASyncGyro() throws {
        let device = try harness.device(5678)
        XCTAssertTrue(device.hasSyncGyro)
        var model = settings(for: device)
        model.unpacked = true

        let result = perform([device], model)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        let settingsPath = (device.devicePath as NSString).appendingPathComponent("SETTINGS.INI")
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsPath),
                       "an AX6 records unpacked already; upstream writes no SETTINGS.INI for it")
    }

    func testUnpackedIsNotWrittenWhenItWasNotAskedFor() throws {
        let device = try harness.device(9999)
        var model = settings(for: device)
        model.unpacked = false

        XCTAssertTrue(perform([device], model).failures.isEmpty)
        let settingsPath = (device.devicePath as NSString).appendingPathComponent("SETTINGS.INI")
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsPath))
    }

    func testUnpackedFailsWhenThereIsNoDrive() throws {
        let device = try harness.device(9999)
        harness.backend.volumePath = .some(nil)
        device.refreshInfo()
        var model = settings(for: device)
        model.unpacked = true

        let result = perform([device], model)
        assertFailed(result, "Failed to find drive to write configuration file.", deviceId: 9999)
    }

    /// U1: a `/Volumes` directory with no `CWA-DATA.CWA` in it is not this device — writing
    /// `DATAMODE=20` there "succeeds" while the device goes on recording packed data.
    func testUnpackedFailsWhenTheVolumeIsNotTheDevice() throws {
        let device = try harness.device(9999)
        let stale = harness.workspace.appendingPathComponent("AX317_09999 1", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        harness.backend.volumePath = .some(stale.path)
        device.refreshInfo()
        var model = settings(for: device)
        model.unpacked = true

        let result = perform([device], model)
        assertFailed(result, "Failed to write unpacked configuration file.", deviceId: 9999)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.appendingPathComponent("SETTINGS.INI").path),
                       "nothing may be written into a directory that is not the device")
    }

    /// The same re-resolution, the other way round: the volume comes back under a new path after
    /// the commit, and the write follows it.
    func testUnpackedFollowsAVolumeThatMovedDuringTheCommit() throws {
        let device = try harness.device(9999)
        let moved = harness.workspace.appendingPathComponent("AX317_09999 1", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1024).write(to: moved.appendingPathComponent("CWA-DATA.CWA"))
        harness.backend.volumePath = .some(moved.path)
        var model = settings(for: device)
        model.unpacked = true

        // The path is only announced by `info()`, which the flow re-reads after committing.
        let result = perform([device], model)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(try String(contentsOfFile: moved.appendingPathComponent("SETTINGS.INI").path,
                                  encoding: .ascii),
                       RecordFlow.unpackedSettings)
    }

    // MARK: - Several devices

    func testEveryDeviceGetsItsOwnFailureAndLogLine() throws {
        let first = try harness.device(9999)
        let second = try harness.device(5678)
        harness.backend.fail(.setSessionId)

        let result = perform([first, second], settings(for: first))
        XCTAssertEqual(result.failures.map(\.id), ["9999", "5678"])
        XCTAssertEqual(result.logLines.count, 2)
        XCTAssertTrue(result.logLines[0].contains(",AX3-CONFIG-ERROR,9999,"))
        XCTAssertTrue(result.logLines[1].contains(",AX3-CONFIG-ERROR,5678,"))
        XCTAssertTrue(result.configured.isEmpty)
    }

    func testSuccessesAreReportedInSelectionOrder() throws {
        let first = try harness.device(9999)
        let second = try harness.device(5678)

        let result = perform([first, second], settings(for: first))
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(result.configured, [9999, 5678])
        XCTAssertEqual(result.logLines.count, 2)
        XCTAssertTrue(result.logLines[0].contains(",AX3-CONFIG-OK,9999,"))
        XCTAssertTrue(result.logLines[1].contains(",AX3-CONFIG-OK,5678,"))
    }
}
