import COmApi
import XCTest
@testable import OmApi

/// The seam between the Swift layer and `omapi.h`.
///
/// `EraseLevel`, `DownloadStatus`, `DeviceConnectionStatus` and `LedState` are hand-written mirrors
/// of C enums, and both directions of the bridge are unchecked at compile time: `eraseAndCommit`
/// rebuilds `OM_ERASE_LEVEL` from a Swift raw value, and the download callback rebuilds
/// `DownloadStatus` from a C one. Insert a case upstream and the mock suite stays green while the
/// real path maps "progress" to "complete" and renames a half-downloaded `.part`.
final class LibOmapiEnumBridgeTests: XCTestCase {

    func testEraseLevelMatchesTheHeader() {
        XCTAssertEqual(EraseLevel.none.rawValue, OM_ERASE_NONE.rawValue)
        XCTAssertEqual(EraseLevel.delete.rawValue, OM_ERASE_DELETE.rawValue)
        XCTAssertEqual(EraseLevel.quickFormat.rawValue, OM_ERASE_QUICKFORMAT.rawValue)
        XCTAssertEqual(EraseLevel.wipe.rawValue, OM_ERASE_WIPE.rawValue)
        for level in EraseLevel.allCases {
            XCTAssertEqual(OM_ERASE_LEVEL(rawValue: level.rawValue).rawValue, level.rawValue,
                           "\(level) does not round-trip through OM_ERASE_LEVEL")
        }
    }

    func testDownloadStatusMatchesTheHeader() {
        XCTAssertEqual(DownloadStatus.none.rawValue, OM_DOWNLOAD_NONE.rawValue)
        XCTAssertEqual(DownloadStatus.error.rawValue, OM_DOWNLOAD_ERROR.rawValue)
        XCTAssertEqual(DownloadStatus.progress.rawValue, OM_DOWNLOAD_PROGRESS.rawValue)
        XCTAssertEqual(DownloadStatus.complete.rawValue, OM_DOWNLOAD_COMPLETE.rawValue)
        XCTAssertEqual(DownloadStatus.cancelled.rawValue, OM_DOWNLOAD_CANCELLED.rawValue)
        // The download callback does exactly this conversion.
        for status in [OM_DOWNLOAD_NONE, OM_DOWNLOAD_ERROR, OM_DOWNLOAD_PROGRESS,
                       OM_DOWNLOAD_COMPLETE, OM_DOWNLOAD_CANCELLED] {
            XCTAssertNotNil(DownloadStatus(rawValue: status.rawValue),
                            "no Swift case for OM_DOWNLOAD_STATUS \(status.rawValue)")
        }
    }

    func testDeviceStatusMatchesTheHeader() {
        XCTAssertEqual(DeviceConnectionStatus.removed.rawValue, OM_DEVICE_REMOVED.rawValue)
        XCTAssertEqual(DeviceConnectionStatus.connected.rawValue, OM_DEVICE_CONNECTED.rawValue)
    }

    func testLedStateMatchesTheHeader() {
        XCTAssertEqual(LedState.auto.rawValue, OM_LED_AUTO.rawValue)
        XCTAssertEqual(LedState.off.rawValue, OM_LED_OFF.rawValue)
        XCTAssertEqual(LedState.blue.rawValue, OM_LED_BLUE.rawValue)
        XCTAssertEqual(LedState.green.rawValue, OM_LED_GREEN.rawValue)
        XCTAssertEqual(LedState.cyan.rawValue, OM_LED_CYAN.rawValue)
        XCTAssertEqual(LedState.red.rawValue, OM_LED_RED.rawValue)
        XCTAssertEqual(LedState.magenta.rawValue, OM_LED_MAGENTA.rawValue)
        XCTAssertEqual(LedState.yellow.rawValue, OM_LED_YELLOW.rawValue)
        XCTAssertEqual(LedState.white.rawValue, OM_LED_WHITE.rawValue)
        // `unknown` is omapinet's own "not read yet"; the header has no such state.
        XCTAssertEqual(LedState.unknown.rawValue, -2)
        for state in LedState.allCases where state != .unknown {
            XCTAssertEqual(OM_LED_STATE(rawValue: state.rawValue).rawValue, state.rawValue)
        }
    }
}

/// `LibOmapiBackend` without hardware.
///
/// Every call is exercised against a library that was never started: libomapi answers
/// `OM_E_NOT_VALID_STATE`/`OM_E_INVALID_DEVICE`, which is enough to prove the Swift wrapper passes
/// the right arguments, checks the status, and turns a failure into an `OmError` rather than
/// returning junk out of an uninitialised buffer.
final class LibOmapiBackendTests: XCTestCase {

    private var backend: LibOmapiBackend!

    override func setUp() {
        super.setUp()
        backend = LibOmapiBackend()
    }

    override func tearDown() {
        backend = nil
        super.tearDown()
    }

    func testNameIsTheOneTheLogAndTheMockFlagReport() {
        XCTAssertEqual(backend.name, "libomapi")
        XCTAssertFalse(backend is MockBackend)
    }

    func testEnumerationOnAStoppedLibraryIsEmptyRatherThanGarbage() {
        XCTAssertEqual(backend.deviceIds(), [])
    }

    /// Each accessor must surface the library's status as a thrown `OmError`.
    func testEveryAccessorThrowsRatherThanReturningUninitialisedData() {
        let id: UInt32 = 1234
        func expectThrow(_ what: String, _ body: () throws -> Void) {
            XCTAssertThrowsError(try body(), what) { error in
                guard let omError = error as? OmError else {
                    return XCTFail("\(what) threw \(error), not an OmError")
                }
                XCTAssertLessThan(omError.code, 0, "\(what) reported success")
                XCTAssertEqual(omError.operation?.isEmpty, false, "\(what) lost the operation name")
            }
        }

        expectThrow("info") { _ = try self.backend.info(id) }
        expectThrow("version") { _ = try self.backend.version(id) }
        expectThrow("batteryLevel") { _ = try self.backend.batteryLevel(id) }
        expectThrow("time") { _ = try self.backend.time(id) }
        expectThrow("setTime") { try self.backend.setTime(id, OmDateTime(date: Date())) }
        expectThrow("setLed") { try self.backend.setLed(id, .blue) }
        expectThrow("setDebug") { try self.backend.setDebug(id, 0) }
        expectThrow("delays") { _ = try self.backend.delays(id) }
        expectThrow("setDelays") { try self.backend.setDelays(id, start: .zero, stop: .infinite) }
        expectThrow("sessionId") { _ = try self.backend.sessionId(id) }
        expectThrow("setSessionId") { try self.backend.setSessionId(id, 1) }
        expectThrow("metadata") { _ = try self.backend.metadata(id) }
        expectThrow("setMetadata") { try self.backend.setMetadata(id, "_sc=P001") }
        expectThrow("accelConfig") { _ = try self.backend.accelConfig(id) }
        expectThrow("setAccelConfig") { try self.backend.setAccelConfig(id, rate: 100, range: 8) }
        expectThrow("maxSamples") { _ = try self.backend.maxSamples(id) }
        expectThrow("setMaxSamples") { try self.backend.setMaxSamples(id, 0) }
        expectThrow("eraseAndCommit") { try self.backend.eraseAndCommit(id, level: .wipe) }
        expectThrow("commit") { try self.backend.commit(id) }
        expectThrow("dataFileSize") { _ = try self.backend.dataFileSize(id) }
        expectThrow("beginDownload") { try self.backend.beginDownload(id, to: "/dev/null") }
        expectThrow("cancelDownload") { try self.backend.cancelDownload(id) }
    }

    /// `OmGetDeviceSerial` and friends answer `OM_E_NOT_VALID_STATE` before `OmStartup`; the
    /// wrapper must report that code rather than a generic failure.
    func testStoppedLibraryReportsNotValidState() {
        XCTAssertThrowsError(try backend.info(1234)) { error in
            XCTAssertEqual(error as? OmError, .notValidState)
        }
    }

    /// `shutdown()` on a backend that was never started must not call into the library.
    func testShutdownWithoutStartIsSafe() {
        backend.shutdown()
        backend.shutdown()
        XCTAssertEqual(backend.deviceIds(), [])
    }
}
