import COmApi
import XCTest
@testable import OmApi

/// What `OmDevice.clear(wipe:)` actually sends.
///
/// The mock cannot make a quick format look different from a wipe afterwards — both leave a bare
/// header — so the only thing that can distinguish OMGUI's default (a full NAND wipe) from its
/// Shift-click (a filesystem rebuild that leaves the previous participant's accelerometry
/// recoverable in NAND) is the erase level on the wire.
final class EraseLevelTests: XCTestCase {

    private var harness: MockHarness!

    override func setUpWithError() throws {
        harness = try MockHarness()
        harness.backend.clearCalls()
    }

    override func tearDown() {
        harness?.tearDown()
        harness = nil
    }

    /// `OmDevice.Clear(true)` — session, metadata, delays, config, then `OM_ERASE_WIPE`.
    func testWipeSendsTheUpstreamSequenceEndingInEraseWipe() throws {
        let device = try harness.device(1234)
        XCTAssertTrue(device.clear(wipe: true))

        XCTAssertEqual(harness.backend.callDescriptions, [
            "setSessionId(1234, 0)",
            "setMetadata(1234, \"\")",
            "setDelays(1234, 4294967295, 4294967295)",
            "setAccelConfig(1234, rate: 100, range: 8)",
            "eraseAndCommit(1234, wipe)",
        ])
        XCTAssertEqual(harness.backend.eraseLevels(), [.wipe])
    }

    /// The Shift-click path is a *quick format*, not a wipe.
    func testQuickFormatSendsEraseQuickFormat() throws {
        let device = try harness.device(1234)
        XCTAssertTrue(device.clear(wipe: false))

        XCTAssertEqual(harness.backend.callDescriptions.last, "eraseAndCommit(1234, quickFormat)")
        XCTAssertEqual(harness.backend.eraseLevels(), [.quickFormat])
        XCTAssertNotEqual(harness.backend.eraseLevels(), [.wipe])
    }

    /// Every commit that is not a clear is `OM_ERASE_NONE`, and it keeps the data.
    func testCommitUsesEraseNoneAndKeepsTheData() throws {
        let device = try harness.device(1234)
        device.update(force: true)
        XCTAssertTrue(device.hasData)

        XCTAssertTrue(device.setSessionId(77, commit: true))
        XCTAssertEqual(harness.backend.eraseLevels(for: 1234), [EraseLevel.none])
        XCTAssertTrue(device.hasData, "a commit must not erase the recording")
    }

    /// One clear per selected device, in selection order.
    func testClearingSeveralDevicesRecordsOneEraseEach() throws {
        let first = try harness.device(1234)
        let second = try harness.device(9999)
        XCTAssertTrue(first.clear(wipe: true))
        XCTAssertTrue(second.clear(wipe: false))

        XCTAssertEqual(harness.backend.eraseLevels(for: 1234), [.wipe])
        XCTAssertEqual(harness.backend.eraseLevels(for: 9999), [.quickFormat])
        XCTAssertEqual(harness.backend.eraseLevels(), [.wipe, .quickFormat])
    }

    /// The Swift raw values are what `OmEraseDataAndCommit` is handed, so they have to be the
    /// header's.
    func testEraseLevelRawValuesMatchTheCHeader() {
        XCTAssertEqual(EraseLevel.none.rawValue, OM_ERASE_NONE.rawValue)
        XCTAssertEqual(EraseLevel.delete.rawValue, OM_ERASE_DELETE.rawValue)
        XCTAssertEqual(EraseLevel.quickFormat.rawValue, OM_ERASE_QUICKFORMAT.rawValue)
        XCTAssertEqual(EraseLevel.wipe.rawValue, OM_ERASE_WIPE.rawValue)
        XCTAssertEqual(EraseLevel.allCases.count, 4)
        // `OmClearDataAndCommit` is quick format; `OmCommit` is none (omapi.h:749, :762).
        XCTAssertEqual(EraseLevel(rawValue: OM_ERASE_QUICKFORMAT.rawValue), .quickFormat)
        XCTAssertEqual(EraseLevel(rawValue: OM_ERASE_NONE.rawValue), EraseLevel.none)
    }
}
