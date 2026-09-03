import XCTest
@testable import OmApi

/// End-to-end device flows against the mock backend: the OMGUI record/download/clear sequences.
final class MockFlowTests: XCTestCase {

    private var harness: MockHarness!

    override func setUpWithError() throws {
        harness = try MockHarness()
    }

    override func tearDown() {
        harness?.tearDown()
        harness = nil
    }

    func testStartupDiscoversEveryDevice() throws {
        XCTAssertEqual(harness.api.devices.map(\.deviceId), [1234, 5678, 7654, 9999])
        XCTAssertTrue(harness.api.devices.allSatisfy(\.connected))
    }

    func testCategoriesCoverTheOMGUIGroups() throws {
        for device in harness.api.devices { device.update(force: true) }
        // 1234: stopped, holds data -> OMGUI collapses "New Data" into the plain Devices group.
        XCTAssertEqual(try harness.device(1234).category, .other)
        XCTAssertEqual(try harness.device(1234).strictCategory, .newData)
        // 5678: charged, empty, session 0.
        XCTAssertEqual(try harness.device(5678).category, .standby)
        // 9999: still charging.
        XCTAssertEqual(try harness.device(9999).category, .charging)
        // 7654: recording, and already holding data -> grouped by its data, like 1234.
        XCTAssertEqual(try harness.device(7654).strictCategory, .newData)
    }

    /// The stock mock has to contain the state Clear refuses, or no `--mock` run reaches the guard
    /// (`refs/12-deep-review-2.md` H6). This is that fixture, asserted where it is defined.
    func testTheStockMockShipsExactlyOneDeviceRecordingWithData() throws {
        for device in harness.api.devices { device.update(force: true) }
        let recordingWithData = harness.api.devices.filter { $0.isRecording != .stopped && $0.hasData }
        XCTAssertEqual(recordingWithData.map(\.deviceId), [7654])

        let device = try harness.device(7654)
        XCTAssertEqual(device.isRecording, .always)
        XCTAssertTrue(device.hasData)
        XCTAssertEqual(device.recordingDescription, "Always (with data)")
    }

    func testRemovedDeviceIsCategorisedRemoved() throws {
        let device = try harness.device(1234)
        device.setConnected(false)
        XCTAssertEqual(device.category, .removed)
        XCTAssertFalse(harness.api.devices.contains { $0.deviceId == 1234 })
        XCTAssertTrue(harness.api.allDevices.contains { $0.deviceId == 1234 })
    }

    /// The OMGUI Record commit order:
    /// SessionId -> Metadata -> MaxSamples(0) -> AccelConfig -> SyncTime -> Debug -> AlwaysRecord.
    func testRecordSetsStateAndMovesDeviceToOutbox() throws {
        let device = try harness.device(5678)
        device.update(force: true)
        XCTAssertEqual(device.category, .standby)

        var metadata = StudyMetadata()
        metadata.studyCode = "STUDY"
        metadata.subjectCode = "P 002"

        XCTAssertTrue(device.setSessionId(42, commit: false))
        try device.setMetadata(metadata.encoded)
        try device.setMaxSamples(0)
        try device.setAccelConfig(AccelConfig(rate: .hz50, range: .g4, gyro: .dps1000))
        XCTAssertTrue(device.syncTime())
        XCTAssertTrue(device.setDebug(3))
        XCTAssertTrue(device.alwaysRecord())

        device.update(force: true)
        XCTAssertEqual(device.sessionId, 42)
        XCTAssertEqual(device.isRecording, .always)
        XCTAssertEqual(device.recordingDescription, "Always")
        XCTAssertEqual(device.category, .outbox)
        XCTAssertEqual(try device.accelConfig(), AccelConfig(rate: .hz50, range: .g4, gyro: .dps1000))
        XCTAssertEqual(try device.maxSamples(), 0)
        XCTAssertEqual(StudyMetadata(decoding: try device.metadata()).subjectCode, "P 002")
        XCTAssertEqual(try device.metadata(), "_s=STUDY&_sc=P+002")
    }

    func testIntervalRecording() throws {
        let device = try harness.device(5678)
        let start = OmDateTime(year: 2026, month: 10, day: 1, hour: 8, minute: 0, second: 0)
        let stop = OmDateTime(year: 2026, month: 10, day: 8, hour: 8, minute: 0, second: 0)
        XCTAssertTrue(device.setInterval(start: start, stop: stop))
        device.update(force: true)
        XCTAssertEqual(device.startTime, start)
        XCTAssertEqual(device.stopTime, stop)
        XCTAssertEqual(device.isRecording, .interval)
        XCTAssertTrue(device.recordingDescription.hasPrefix("Interval "))
    }

    func testGyroIsIgnoredOnAnAX3() throws {
        let device = try harness.device(1234)
        XCTAssertFalse(device.hasSyncGyro)
        try device.setAccelConfig(AccelConfig(rate: .hz100, range: .g8, gyro: .dps2000))
        XCTAssertNil(try device.accelConfig().gyro)
    }

    func testAX6IsDetectedFromTheSerialPrefix() throws {
        XCTAssertTrue(try harness.device(5678).hasSyncGyro)
        XCTAssertFalse(try harness.device(1234).hasSyncGyro)
        XCTAssertTrue(DeviceInfo(deviceId: 1, serialId: "CWA64_00001", port: "", volumePath: "").hasSyncGyro)
    }

    /// Download: progress must reach 100, the `.part` file must be renamed, and the copy must be
    /// byte-identical to the device's data file.
    func testDownloadReachesCompletionAndRenames() throws {
        let device = try harness.device(1234)
        device.update(force: true)
        XCTAssertTrue(device.hasData)

        let workspace = harness.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let baseName = FilenameTemplate.expand(FilenameTemplate.defaultTemplate,
                                               deviceId: device.deviceId,
                                               sessionId: device.sessionId)
        XCTAssertEqual(baseName, "01234_0000000001")
        let paths = FilenameTemplate.downloadPaths(workspace: workspace, baseName: baseName)

        let progressValues = Locked<[Int]>([])
        let finished = XCTestExpectation(description: "download finished")
        harness.api.onDeviceChanged = { changed, status in
            switch status {
            case .progress: progressValues.mutate { $0.append(changed.downloadValue) }
            case .complete, .cancelled, .error: finished.fulfill()
            case .none: break
            }
        }

        try device.beginDownloading(to: paths.partial.path, renameTo: paths.final.path)
        wait(for: [finished], timeout: 20)

        XCTAssertEqual(device.downloadStatus, .complete)
        XCTAssertEqual(progressValues.value.last, 100, "progress must reach 100")
        XCTAssertEqual(progressValues.value, progressValues.value.sorted(), "progress must be monotonic")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.partial.path), ".part must be renamed away")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.final.path))
        XCTAssertEqual(try Data(contentsOf: paths.final),
                       try Data(contentsOf: URL(fileURLWithPath: device.dataFilePath)))

        // Once downloaded, the device drops out of "new data".
        XCTAssertFalse(device.hasNewData)
        XCTAssertEqual(device.strictCategory, .downloaded)
    }

    func testDownloadCanBeCancelled() throws {
        harness.backend.downloadStepCount = 200
        harness.backend.downloadStepDelay = 0.01
        let device = try harness.device(1234)
        let workspace = harness.root.appendingPathComponent("workspace2", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let paths = FilenameTemplate.downloadPaths(workspace: workspace, baseName: "cancelme")

        let finished = XCTestExpectation(description: "download settled")
        let sawProgress = XCTestExpectation(description: "download started")
        harness.api.onDeviceChanged = { _, status in
            if status == .progress { sawProgress.fulfill() }
            if status == .cancelled || status == .complete { finished.fulfill() }
        }
        try device.beginDownloading(to: paths.partial.path, renameTo: paths.final.path)
        wait(for: [sawProgress], timeout: 10)
        device.cancelDownload()
        wait(for: [finished], timeout: 20)

        XCTAssertEqual(device.downloadStatus, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.final.path))
    }

    /// OMGUI's Clear: session 0, metadata cleared, delays never, default accel config, data erased.
    func testClearResetsEverything() throws {
        let device = try harness.device(1234)
        XCTAssertTrue(device.setSessionId(99, commit: false))
        try device.setMetadata("_s=BEFORE")
        try device.setAccelConfig(AccelConfig(rate: .hz800, range: .g2))
        device.update(force: true)
        XCTAssertTrue(device.hasData)

        XCTAssertTrue(device.clear(wipe: true))
        device.update(force: true)

        XCTAssertEqual(device.sessionId, 0)
        XCTAssertEqual(try device.metadata(), "")
        XCTAssertEqual(device.startTime, .infinite)
        XCTAssertEqual(device.stopTime, .infinite)
        XCTAssertEqual(device.isRecording, .stopped)
        XCTAssertEqual(try device.accelConfig(), .deviceDefault)
        XCTAssertFalse(device.hasData, "the data file must be back to a bare header")
        XCTAssertEqual(try device.dataFileSize(), 1024)
        // Session 0 with no data: Charging while the battery is under 100 %, Standby at 100 %.
        XCTAssertEqual(device.category, .charging)
    }

    func testQuickFormatAlsoErasesData() throws {
        let device = try harness.device(1234)
        XCTAssertTrue(device.clear(wipe: false))
        XCTAssertFalse(device.hasData)
    }

    func testChargingDeviceClimbsToStandby() throws {
        let device = try harness.device(9999)
        device.update(force: true)
        let first = try XCTUnwrap(device.batteryLevel)
        XCTAssertEqual(device.category, .charging)
        for _ in 0..<25 { device.update(force: true) }
        let last = try XCTUnwrap(device.batteryLevel)
        XCTAssertGreaterThan(last, first)
        XCTAssertEqual(last, 100)
        XCTAssertEqual(device.category, .standby)
    }

    func testSyncTimeBringsTheDeviceClockIntoLine() throws {
        let device = try harness.device(5678)
        try harness.backend.setTime(5678, OmDateTime(year: 2007, month: 1, day: 1, hour: 0, minute: 0, second: 0))
        device.update(force: true)
        XCTAssertEqual(device.warning, .discharged, "an RTC before 2008 is OMGUI's discharged warning")

        XCTAssertTrue(device.syncTime())
        let difference = try XCTUnwrap(device.timeDifference)
        XCTAssertLessThan(abs(difference), 5)
        XCTAssertEqual(device.warning, .none)
    }

    func testSetLedTracksTheRequestedColour() throws {
        let device = try harness.device(1234)
        XCTAssertTrue(device.setLed(.magenta))
        XCTAssertEqual(device.ledColor, .magenta)
        XCTAssertEqual(device.ledColor.iconIndex, 5)
        XCTAssertEqual(LedState.unknown.iconIndex, 8)
    }

    func testUnknownDeviceIdFails() {
        XCTAssertThrowsError(try harness.backend.info(4321)) { error in
            XCTAssertEqual(error as? OmError, .invalidDevice)
        }
    }

    func testOverlongMetadataIsRejected() throws {
        XCTAssertThrowsError(try harness.backend.setMetadata(1234, String(repeating: "x", count: 449))) { error in
            XCTAssertEqual(error as? OmError, .invalidArg)
        }
    }
}

/// Tiny lock box so test callbacks can accumulate state from the backend's threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return storage }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); body(&storage); lock.unlock() }
}
