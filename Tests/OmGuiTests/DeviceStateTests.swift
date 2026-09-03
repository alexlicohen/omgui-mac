import Foundation
import OmApi
import OmGuiCore
import XCTest

/// What `OmDevice` caches and when it re-reads it.
///
/// Every case here is one where the cache and the device disagreed and nothing ever noticed: the
/// property grid renders the cache and only the poll may talk to the device, so a value that is
/// wrong once stays wrong for the life of the session unless something marks it for re-reading.
@MainActor
final class DeviceStateTests: XCTestCase {

    private var harness: FaultHarness!

    override func setUpWithError() throws {
        harness = try FaultHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
    }

    // MARK: - M4: a failed syncTime must not erase the device warning

    /// `syncTime` clears the DAMAGED?/DISCHARGED? warning at entry because a *successful* sync
    /// invalidates it (upstream: "reset warning, as it was time-based anyway"). A failed one leaves
    /// the clock exactly as it was, so the finding still stands — and `update()` re-derives the
    /// warning only in its one-shot `!validData` branch, so nothing would ever restore it: the row
    /// silently loses its prefix and Record's abort/retry/ignore prompt stops firing. The tick
    /// verification added in this range makes `false` returns routine.
    func testAFailedTimeSyncKeepsTheDeviceWarning() throws {
        let device = try harness.device(5678)
        try harness.mock.setTime(5678, OmDateTime(year: 2000, month: 1, day: 1,
                                                  hour: 0, minute: 0, second: 0))
        device.update(force: true)
        XCTAssertEqual(device.warning, .damaged,
                       "a just-restarted clock on a full battery is OMGUI's damaged warning")

        harness.backend.fail(.setTime)
        XCTAssertFalse(device.syncTime(), "the write fails on every retry")
        XCTAssertEqual(device.warning, .damaged, "the warning is still true, so it must still be shown")

        // And the ticking check failing counts the same way.
        harness.backend.succeed(.setTime)
        harness.backend.frozenClock = true
        device.syncTimeTiming = SyncTimeTiming(settle: 0.01, tickTimeout: 0.05,
                                               tickPollInterval: 0.01, retries: 2,
                                               alignToSecondBoundary: false)
        XCTAssertFalse(device.syncTime(), "a clock that latches the write but never ticks")
        XCTAssertEqual(device.warning, .damaged)
    }

    func testASuccessfulTimeSyncStillClearsTheWarning() throws {
        let device = try harness.device(5678)
        try harness.mock.setTime(5678, OmDateTime(year: 2000, month: 1, day: 1,
                                                  hour: 0, minute: 0, second: 0))
        device.update(force: true)
        XCTAssertEqual(device.warning, .damaged)

        XCTAssertTrue(device.syncTime())
        XCTAssertEqual(device.warning, .none, "the clock was set and verified: the finding is gone")
    }

    // MARK: - M5: one RATE timeout must not blank the Sampling rows for the session

    func testAFailedFirstRateReadIsRetriedOnTheNextPollInsteadOfBlankingTheRowsForever() throws {
        let device = try harness.device(5678)
        harness.backend.fail(.accelConfig)

        device.update(force: true)
        XCTAssertTrue(device.validData, "the five status reads all succeeded: RATE is not one of them")
        XCTAssertNil(device.cachedAccelConfig)
        XCTAssertTrue(device.accelConfigIsStale)
        XCTAssertTrue(PropertyGrid.rows(forDevices: [device]).filter { $0.name.hasPrefix("Sampling") }.isEmpty)

        // The next poll asks again. Before this fix the read sat inside the one-shot `!validData`
        // branch, so it never ran again and the rows stayed empty until the device was replugged.
        harness.backend.succeed(.accelConfig)
        device.update(force: true)
        XCTAssertEqual(device.cachedAccelConfig, AccelConfig(rate: .hz100, range: .g8, gyro: .dps2000))
        XCTAssertFalse(device.accelConfigIsStale)
        let rows = PropertyGrid.rows(forDevices: [device])
        XCTAssertEqual(rows.first { $0.name == "Sampling Rate" }?.value, "100")
        XCTAssertEqual(rows.first { $0.name == "Sampling Range" }?.value, "8")
    }

    func testARateFailureKeepsTheLastGoodValueRatherThanBlankingIt() throws {
        let device = try harness.device(5678)
        device.update(force: true)
        let good = try XCTUnwrap(device.cachedAccelConfig)
        XCTAssertFalse(device.accelConfigIsStale)

        // A settled cache is not re-read at all — a RATE per poll would cost a round trip per
        // device for a value that only changes when something here changes it.
        harness.backend.fail(.accelConfig)
        device.update(force: true)
        XCTAssertEqual(device.cachedAccelConfig, good)
        XCTAssertFalse(device.accelConfigIsStale)

        // A failed clear says "what this device holds is now unknown", which owes a re-read. The
        // read fails, and the last-good value is kept and stays marked for another try.
        harness.backend.fail(.erase)
        XCTAssertFalse(device.clear(wipe: true))
        XCTAssertTrue(device.accelConfigIsStale)
        let lastGood = try XCTUnwrap(device.cachedAccelConfig)

        device.update(force: true)
        XCTAssertEqual(device.cachedAccelConfig, lastGood, "a failed read must not blank the rows")
        XCTAssertTrue(device.accelConfigIsStale)

        harness.backend.succeed(.accelConfig)
        device.update(force: true)
        XCTAssertFalse(device.accelConfigIsStale)
        XCTAssertNotNil(device.cachedAccelConfig)
    }

    // MARK: - M6: clear() writes the config through the same path as record

    func testClearRefreshesTheAccelCacheThroughTheSharedPath() throws {
        let device = try harness.device(5678)
        try device.setAccelConfig(AccelConfig(rate: .hz800, range: .g2, gyro: .dps2000))
        device.update(force: true)
        XCTAssertEqual(device.cachedAccelConfig?.rate, .hz800)

        XCTAssertTrue(device.clear(wipe: false))
        XCTAssertEqual(device.cachedAccelConfig?.rate, AccelConfig.deviceDefault.rate)
        XCTAssertEqual(device.cachedAccelConfig?.range, AccelConfig.deviceDefault.range)
        XCTAssertFalse(device.accelConfigIsStale)
        XCTAssertEqual(try device.accelConfig().rate, AccelConfig.deviceDefault.rate,
                       "and that is what the device actually holds")
    }

    /// An AX6 at 50 Hz/±16 g where every config write lands and the 15 s `FORMAT WC` times out.
    /// The cache used to keep the stale, high configuration — and nothing ever re-read it, so the
    /// property grid lied about the one device the operator was diagnosing.
    func testAFailedClearLeavesTheAccelCacheMarkedForReReading() throws {
        let device = try harness.device(5678)
        try device.setAccelConfig(AccelConfig(rate: .hz50, range: .g16, gyro: .dps1000))
        device.update(force: true)
        XCTAssertEqual(device.cachedAccelConfig?.range, .g16)

        harness.backend.fail(.erase)
        XCTAssertFalse(device.clear(wipe: true), "FORMAT WC timed out")
        XCTAssertNotEqual(device.cachedAccelConfig?.range, .g16,
                          "the config writes did land, so the grid must not still show ±16 g")
        XCTAssertTrue(device.accelConfigIsStale,
                      "and what the device holds after a part-done clear is unknown: re-read it")

        harness.backend.succeed(.erase)
        device.update(force: true)
        XCTAssertFalse(device.accelConfigIsStale)
        XCTAssertEqual(device.cachedAccelConfig?.rate, AccelConfig.deviceDefault.rate)
        XCTAssertEqual(device.cachedAccelConfig?.range, AccelConfig.deviceDefault.range)
    }

    // MARK: - L3: reading a device back after changing it

    func testRefreshStatusRereadsWhatForceAloneDoesNot() throws {
        let device = try harness.device(1234)
        device.update(force: true)
        XCTAssertEqual(device.sessionId, 1)
        XCTAssertTrue(device.validData)

        // Something changed the device behind the cache's back — a clear that ACKed without
        // resetting the session id is the case this exists for.
        try harness.mock.setSessionId(1234, 77)

        device.update(force: true)
        XCTAssertEqual(device.sessionId, 1,
                       "`force` bypasses the poll interval, not the one-shot `validData` gate")

        XCTAssertTrue(device.refreshStatus())
        XCTAssertEqual(device.sessionId, 77)
    }
}
