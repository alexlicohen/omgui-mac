import Foundation
import OmApi
import XCTest
@testable import OmGuiCore

/// `devicesListViewUpdateEnabled` for a selection that contains a device *while it is downloading*.
///
/// Every fixture row in `SettingsAndRowTests` has `isDownloading == false`, so `cancel == true` was
/// never asserted and the `downloading == 0` guard on Clear/Record/Stop/Download was unasserted:
/// deleting it left the suite green while Clear went live mid-download
/// (`refs/10-deep-review.md` C33).
@MainActor
final class ToolbarGatingTests: XCTestCase {

    private var harness: GuiHarness!

    override func setUpWithError() throws {
        // A long, slow download, so the row is still downloading while the assertions run.
        harness = try GuiHarness(downloadSteps: 400, downloadDelay: 0.02)
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
    }

    /// Starts a real download against the mock backend and returns the row while it is in flight.
    private func downloadingRow() throws -> (device: OmDevice, row: DeviceRow) {
        let device = try harness.device(1234)
        device.update(force: true)
        XCTAssertTrue(device.hasData)
        DownloadFlow.run(devices: [device],
                         template: FilenameTemplate.defaultTemplate,
                         workspace: harness.workspace,
                         prompt: RecordingPrompter())
        // The first progress callback arrives on the backend's own queue.
        let deadline = Date().addingTimeInterval(5)
        while !device.isDownloading && Date() < deadline { usleep(5_000) }
        XCTAssertTrue(device.isDownloading, "the mock download never started")
        return (device, DeviceRow(device: device, timeCheck: true))
    }

    func testADownloadingRowLeavesOnlyCancelAndIdentifyLive() throws {
        let (device, row) = try downloadingRow()
        defer { device.cancelDownload() }

        XCTAssertTrue(row.isDownloading)
        XCTAssertTrue(row.hasData, "a downloading device counts as having data")
        XCTAssertEqual(row.downloadColor, .orange)
        XCTAssertTrue(row.downloadText.hasSuffix("%"), row.downloadText)

        let state = DeviceToolbarState(selection: [row])
        XCTAssertTrue(state.cancel, "Cancel is the one button a download turns on")
        XCTAssertTrue(state.identify)
        XCTAssertFalse(state.download)
        XCTAssertFalse(state.clear, "Clear must not go live mid-download")
        XCTAssertFalse(state.record)
        XCTAssertFalse(state.stop)
    }

    /// The mixed case the `downloading == 0` guards exist for: every row is otherwise clearable,
    /// and one of them is downloading.
    func testOneDownloadingRowGatesTheWholeSelection() throws {
        let (device, downloading) = try downloadingRow()
        defer { device.cancelDownload() }

        // The same device's row as it will read once the download finishes: clearable, idle.
        var idle = downloading
        idle.deviceId = 4321
        idle.isDownloading = false
        XCTAssertTrue(idle.isStoppedWithDataOrConfiguredWithout)
        XCTAssertTrue(downloading.isStoppedWithDataOrConfiguredWithout)

        // On its own it is fully live...
        let alone = DeviceToolbarState(selection: [idle])
        XCTAssertTrue(alone.clear)
        XCTAssertTrue(alone.download)
        XCTAssertFalse(alone.cancel)

        // ...and one downloading row in the selection takes all of that away but Cancel.
        let mixed = DeviceToolbarState(selection: [downloading, idle])
        XCTAssertTrue(mixed.cancel)
        XCTAssertTrue(mixed.identify)
        XCTAssertFalse(mixed.clear)
        XCTAssertFalse(mixed.download)
        XCTAssertFalse(mixed.record)
        XCTAssertFalse(mixed.stop)
    }

    /// A recording device that is also downloading: Stop is gated too.
    func testDownloadingGatesStopOnARecordingRow() throws {
        let (device, downloading) = try downloadingRow()
        defer { device.cancelDownload() }

        var recording = downloading
        recording.isDownloading = false
        recording.isRecordingNow = true
        XCTAssertTrue(DeviceToolbarState(selection: [recording]).stop)

        recording.isDownloading = true
        let state = DeviceToolbarState(selection: [recording])
        XCTAssertFalse(state.stop)
        XCTAssertTrue(state.cancel)
    }
}
