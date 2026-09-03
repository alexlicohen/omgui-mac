import Foundation
import OmApi
import OmGuiCore
import XCTest

/// The study's MOP-alignment requirements that can be asserted without a window.
///
/// The four that need the running app -- the title bar text, the "Default" header the outline view
/// draws, the Device column width and the Record-disabled-with-data rule as the toolbar renders it
/// -- are asserted by `--self-test` (`SelfTest+Mop.swift`).
final class MopAlignmentTests: XCTestCase {

    private let noon = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - MOP-alignment item 3: the window title

    func testDefaultTitleTextMatchesMainForm() {
        XCTAssertEqual(AppInfo.defaultTitleText(version: "1.0.0.45"), "Open Movement [V1.0.0.45]")
    }

    func testWindowTitleIsTheTitleTextThenTheWorkspace() {
        let workspace = URL(fileURLWithPath: "/Users/era/Documents", isDirectory: true)
        XCTAssertEqual(AppInfo.windowTitle(workspace: workspace, version: "1.0.0"),
                       "Open Movement [V1.0.0] - /Users/era/Documents")
    }

    func testTheVersionFallsBackWhenTheBundleCarriesACommitHash() {
        XCTAssertTrue(AppInfo.isNumericVersion("1"))
        XCTAssertTrue(AppInfo.isNumericVersion("1.0.0.45"))
        XCTAssertFalse(AppInfo.isNumericVersion("2cf7804"))
        XCTAssertFalse(AppInfo.isNumericVersion("v1.0.0"))
        XCTAssertFalse(AppInfo.isNumericVersion("1..0"))
        XCTAssertFalse(AppInfo.isNumericVersion(""))
        // The test bundle has no marketing version, so the package version is what is used.
        XCTAssertEqual(AppInfo.version(bundle: Bundle(for: MopAlignmentTests.self)),
                       AppInfo.packageVersion)
    }

    // MARK: - MOP-alignment item 1: the group header

    func testTheDeviceListHasOneGroupCalledDefault() {
        XCTAssertEqual(DeviceGroup.defaultTitle, "Default")
        // The nine groups `DeviceListView` registers are still modelled, because the device
        // properties and the log name them -- they are simply never used as headers.
        XCTAssertEqual(SourceCategory.displayOrder.map(\.groupName),
                       ["Devices", "New Data", "Downloading", "Downloaded", "Charging",
                        "Standby", "Outbox", "Removed", "Files"])
    }

    // MARK: - MOP-alignment item 5: the initial recording profile

    func testAFreshWorkspaceStartsAtTheMopValues() {
        var model = RecordingSettings(devices: [.ax6()], now: noon)
        model.applyInitialProfile()
        model.finishInitialisation(now: noon)
        XCTAssertEqual(model.sampleRate, .hz100)
        XCTAssertEqual(model.accelRange, .g16)
        XCTAssertEqual(model.gyroIndex, 0)
        XCTAssertEqual(model.gyroRange, .off)
        XCTAssertTrue(model.immediately)
        XCTAssertEqual(RecordingSettings.rangeLabels[model.rangeIndex], "16")
        XCTAssertEqual(RecordingSettings.gyroLabels[model.gyroIndex], "(disabled)")
    }

    func testTheDefaultsButtonStillRestoresOmguisOwnValues() {
        var model = RecordingSettings(devices: [.ax6()], now: noon)
        model.applyInitialProfile()
        model.applyDefaults()
        XCTAssertEqual(model.sampleRate, .hz100)
        XCTAssertEqual(model.accelRange, .g8, "the Defaults button is OMGUI's, not the MOP's")
    }

    func testAStoredProfileWinsOverTheInitialValues() throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mop-profile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        var stored = RecordingSettings(devices: [.ax6()], now: noon)
        stored.frequencyIndex = 4          // 200 Hz
        stored.rangeIndex = 1              // +-4 g
        XCTAssertTrue(RecordingProfile(capturing: stored).save(to: workspace))

        var reopened = RecordingSettings(devices: [.ax6()], now: noon)
        let profile = try XCTUnwrap(RecordingProfile.load(from: workspace))
        profile.apply(to: &reopened)
        XCTAssertEqual(reopened.sampleRate, .hz200)
        XCTAssertEqual(reopened.accelRange, .g4)
    }

    // MARK: - MOP-alignment item 4: the warnings

    func testEveryWarningStringIsTheOneDateRangeFormUses() {
        XCTAssertEqual(RecordingSettings.warningMessages.count, 11)
        XCTAssertEqual(RecordingSettings.warningMessages, [
            "Selected device(s) not fully charged",
            "Selected device(s) not fully cleared",
            "Selected device(s) capacity could limit duration",
            "Selected device(s) current battery charge could limit duration",
            "Delayed start time is more than 14 days in the future",
            "End time is in the past",
            "Start time is in the past",
            "Chosen sampling frequency is not officially supported (use at own risk)",
            "Chosen start and end times do not make an interval (end <= start)",
            "Low power accelerometer produces noisier data (and does not significantly extend duration)",
            "A gyro-enabled device is being configured for accelerometer data only (no gyro data).",
        ])
        XCTAssertEqual(RecordingSettings.invalidMessage, "Invalid configuration")
    }

    func testAnAx6WithTheGyroDisabledShowsExactlyTheMopsWarning() {
        var model = RecordingSettings(devices: [.ax6()], now: noon)
        model.applyInitialProfile()
        model.finishInitialisation(now: noon)
        let validation = model.validate(now: noon)
        XCTAssertEqual(validation.flags, [10], "no other warning fires for the MOP's settings")
        XCTAssertEqual(validation.warningText,
                       "WARNINGS\n\u{2022} A gyro-enabled device is being configured for "
                       + "accelerometer data only (no gyro data).\n")
        XCTAssertTrue(validation.okEnabled)
        // `labelRateRangeSetting` is blank only at 100 Hz / +-8 g, so the MOP's +-16 g reads
        // "non-standard" -- upstream behaviour, reproduced.
        XCTAssertEqual(validation.rateRangeText, "non-standard")
    }

    func testTheGyroWarningGoesAwayOnceTheGyroIsEnabled() {
        var model = RecordingSettings(devices: [.ax6()], now: noon)
        model.applyInitialProfile()
        model.gyroIndex = 1                // 2000 dps
        model.finishInitialisation(now: noon)
        XCTAssertEqual(model.validate(now: noon).flags, [])
    }

    // MARK: - MOP-alignment items 6 and 9: the device row and the toolbar

    func testADeviceHoldingARecordingReadsStoppedWithData() {
        XCTAssertEqual(DeviceRow.recordingText(start: .infinite, stop: .infinite, hasData: false),
                       "Stopped")
        XCTAssertEqual(DeviceRow.recordingText(start: .infinite, stop: .infinite, hasData: true),
                       "Stopped (with data)")
    }

    func testRecordIsDisabledWhenTheSelectionHasData() throws {
        let harness = try GuiHarness(specs: MockDeviceCatalog.specs)
        defer { harness.tearDown() }
        let rows = harness.api.devices.map { DeviceRow(device: $0, timeCheck: true) }

        let cleared = try XCTUnwrap(rows.first { $0.deviceId == MockDeviceCatalog.mopDeviceId })
        XCTAssertFalse(cleared.hasData)
        XCTAssertEqual(cleared.recordingText, "Stopped")
        XCTAssertTrue(DeviceToolbarState(selection: [cleared]).record)

        let withData = try XCTUnwrap(rows.first { $0.deviceId == MockDeviceCatalog.mopDeviceWithDataId })
        XCTAssertTrue(withData.hasData)
        XCTAssertEqual(withData.recordingText, "Stopped (with data)")
        let toolbar = DeviceToolbarState(selection: [withData])
        XCTAssertFalse(toolbar.record, "Record is greyed out for a device that has data")
        XCTAssertTrue(toolbar.download)
        XCTAssertTrue(toolbar.clear)

        // A mixed selection is disabled too: `numData == 0` is the rule, not "none of them".
        XCTAssertFalse(DeviceToolbarState(selection: [cleared, withData]).record)
    }

    func testTheMockDevicesUseTheMopsSevenDigitIds() {
        let ids = MockDeviceCatalog.specs.map(\.deviceId)
        XCTAssertEqual(ids, [6_036_222, 6_036_223, 6_036_224])
        for id in ids {
            XCTAssertEqual(FilenameTemplate.deviceIdString(id), String(id),
                           "{0:00000} pads short IDs, it must never truncate a long one")
        }
        XCTAssertEqual(FilenameTemplate.expand(FilenameTemplate.defaultTemplate,
                                               deviceId: MockDeviceCatalog.mopDeviceId,
                                               sessionId: 0),
                       "6036222_0000000000")
    }

    // MARK: - MOP-alignment item 8: the configuration confirmation line

    func testTheRecordingConfirmationLine() {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = RecordFlow.confirmationDateFormat
        XCTAssertEqual(RecordFlow.confirmationLine(deviceId: 6_036_222, sessionId: 42, at: when),
                       "Recording configured on 6036222: session 42, " + formatter.string(from: when))
    }

    // MARK: - MOP-alignment item 7: the default workspace

    func testTheDefaultWorkspaceIsMyDocuments() {
        let defaults = UserDefaults(suiteName: "mop-workspace-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.workingFolderTemplate, "{MyDocuments}")
        XCTAssertEqual(settings.workingFolder.path,
                       FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.path)
    }
}

private extension RecordingDeviceInfo {
    /// A cleared, charged AX6 -- the state the MOP's watch is in when it is configured.
    static func ax6(battery: Int = 93) -> RecordingDeviceInfo {
        RecordingDeviceInfo(deviceId: MockDeviceCatalog.mopDeviceId,
                            batteryLevel: battery,
                            hasData: false,
                            deviceCapacity: 494_384_795_648,
                            hasSyncGyro: true,
                            firmwareVersion: 53)
    }
}
