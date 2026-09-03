import Foundation
import OmApi
import OmGuiCore
import XCTest

/// Options persistence, the recording profile, the device row model and the plugin queue.
final class SettingsAndRowTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "omgui-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Options persistence

    func testOptionsDefaults() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.filenameTemplate, "{DeviceId}_{SessionId}")
        XCTAssertEqual(settings.pluginFolder, "")
        XCTAssertEqual(settings.workingFolderTemplate, "{MyDocuments}")
        XCTAssertFalse(settings.showAllFiles)
        XCTAssertTrue(settings.viewFlag(AppSettings.Key.viewToolbar))
        XCTAssertTrue(settings.viewFlag(AppSettings.Key.viewPreview))
        XCTAssertFalse(settings.viewFlag(AppSettings.Key.viewLog))
        XCTAssertNil(settings.downloadLogFile)
    }

    func testOptionsRoundTripThroughUserDefaults() {
        let settings = AppSettings(defaults: defaults)
        settings.filenameTemplate = "{DeviceId}-{SubjectCode}"
        settings.pluginFolder = "/tmp/plugins"
        settings.downloadLogFile = "/tmp/download.log"
        settings.setViewFlag(AppSettings.Key.viewLog, true)
        settings.showAllFiles = true

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.filenameTemplate, "{DeviceId}-{SubjectCode}")
        XCTAssertEqual(reloaded.pluginFolder, "/tmp/plugins")
        XCTAssertEqual(reloaded.downloadLogFile, "/tmp/download.log")
        XCTAssertTrue(reloaded.viewFlag(AppSettings.Key.viewLog))
        XCTAssertTrue(reloaded.showAllFiles)
    }

    func testRecentFoldersAreMostRecentFirstDeduplicatedAndCappedAtFive() {
        let settings = AppSettings(defaults: defaults)
        for index in 1...6 { settings.setWorkingFolder("/tmp/f\(index)") }
        XCTAssertEqual(settings.recentFolders, ["/tmp/f6", "/tmp/f5", "/tmp/f4", "/tmp/f3", "/tmp/f2"])

        settings.setWorkingFolder("/tmp/f4")
        XCTAssertEqual(settings.recentFolders, ["/tmp/f4", "/tmp/f6", "/tmp/f5", "/tmp/f3", "/tmp/f2"])
        XCTAssertEqual(settings.workingFolderTemplate, "/tmp/f4")
    }

    func testWorkingFolderTemplateIsExpandedOnRead() {
        let settings = AppSettings(defaults: defaults)
        settings.workingFolderTemplate = "{MyDocuments}"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        XCTAssertEqual(settings.workingFolder.path, documents.path)
    }

    // MARK: - Recording profile (recordSetup.xml)

    func testRecordingProfileRoundTrip() throws {
        var model = RecordingSettings(devices: [.ax3()])
        model.finishInitialisation()
        model.frequencyIndex = 4          // 200
        model.rangeIndex = 3              // 16
        model.flash = true
        model.lowPower = true
        model.unpacked = true
        model.immediately = false
        model.setDuration(days: 2, hours: 3, minutes: 4)
        model.metadata.studyCentre = "SITE1"
        model.metadata.studyCode = "STUDY"
        model.metadata.subjectCode = "P001"

        let profile = RecordingProfile(capturing: model)
        XCTAssertEqual(profile["Frequency"], "200")
        XCTAssertEqual(profile["Range"], "16")
        XCTAssertEqual(profile["Flash"], "True")
        XCTAssertEqual(profile["RecordingTime"], "Duration")
        XCTAssertEqual(profile["Duration"], String(Int(model.duration)))
        XCTAssertEqual(profile["SubjectCode"], "P001")

        let parsed = try XCTUnwrap(RecordingProfile(xml: profile.xml))
        XCTAssertEqual(parsed, profile)

        var restored = RecordingSettings(devices: [.ax3()])
        parsed.apply(to: &restored)
        restored.finishInitialisation()
        XCTAssertEqual(restored.frequencyIndex, 4)
        XCTAssertEqual(restored.rangeIndex, 3)
        XCTAssertTrue(restored.flash)
        XCTAssertTrue(restored.lowPower)
        XCTAssertTrue(restored.unpacked)
        XCTAssertFalse(restored.immediately)
        XCTAssertEqual(restored.durationDays, 2)
        XCTAssertEqual(restored.durationHours, 3)
        XCTAssertEqual(restored.durationMinutes, 4)
        XCTAssertEqual(restored.metadata.studyCentre, "SITE1")
        XCTAssertEqual(restored.metadata.studyCode, "STUDY")
        // Subject fields are saved but deliberately not restored (as in DateRangeForm.cs).
        XCTAssertEqual(restored.metadata.subjectCode, "")
    }

    func testRecordingProfileIgnoresLowPowerAndUnpackedForGyroDevices() {
        var model = RecordingSettings(devices: [.ax3()])
        model.lowPower = true
        model.unpacked = true
        let profile = RecordingProfile(capturing: model)

        var ax6 = RecordingSettings(devices: [.ax6()])
        profile.apply(to: &ax6)
        XCTAssertFalse(ax6.lowPower)
        XCTAssertFalse(ax6.unpacked)
    }

    func testRecordingProfileSavesAndLoadsFromTheWorkspace() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omgui-profile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var model = RecordingSettings(devices: [.ax3()])
        model.metadata.studyNotes = "note & <tag>"
        XCTAssertTrue(RecordingProfile(capturing: model).save(to: folder))
        XCTAssertEqual(RecordingProfile.url(in: folder).lastPathComponent, "recordSetup.xml")

        let loaded = try XCTUnwrap(RecordingProfile.load(from: folder))
        XCTAssertEqual(loaded["StudyNotes"], "note & <tag>")
    }

    // MARK: - Device rows

    func testRecordingColumnText() {
        XCTAssertEqual(DeviceRow.recordingText(start: .infinite, stop: .infinite, hasData: false), "Stopped")
        XCTAssertEqual(DeviceRow.recordingText(start: .zero, stop: .infinite, hasData: false), "Always")
        XCTAssertEqual(DeviceRow.recordingText(start: .zero, stop: .infinite, hasData: true), "Always (with data)")

        let start = OmDateTime(year: 2026, month: 9, day: 2, hour: 8, minute: 0, second: 0)
        let stop = OmDateTime(year: 2026, month: 9, day: 9, hour: 8, minute: 30, second: 15)
        XCTAssertEqual(DeviceRow.recordingText(start: start, stop: stop, hasData: false),
                       "Interval 02/09/26 08:00:00-09/09/26 08:30:15")
    }

    func testDownloadColumnText() {
        XCTAssertEqual(DeviceRow.downloadText(status: .none, value: 0), "")
        XCTAssertEqual(DeviceRow.downloadText(status: .progress, value: 42), "42%")
        XCTAssertEqual(DeviceRow.downloadText(status: .complete, value: 100), "Complete")
        XCTAssertEqual(DeviceRow.downloadText(status: .cancelled, value: 0), "Cancelled")
        XCTAssertEqual(DeviceRow.downloadText(status: .error, value: 0x2B), "Error (0x2B)")
    }

    func testDownloadColumnColours() {
        XCTAssertEqual(DeviceRow.downloadColor(status: .cancelled), .red)
        XCTAssertEqual(DeviceRow.downloadColor(status: .error), .red)
        XCTAssertEqual(DeviceRow.downloadColor(status: .progress), .orange)
        XCTAssertEqual(DeviceRow.downloadColor(status: .complete), .green)
        XCTAssertEqual(DeviceRow.downloadColor(status: .none), .normal)
    }

    func testBatteryColumnTextAndColours() {
        XCTAssertEqual(DeviceRow.batteryText(level: 87, warning: .none, timeCheck: true), "87%")
        XCTAssertEqual(DeviceRow.batteryText(level: nil, warning: .none, timeCheck: true), "-")
        XCTAssertEqual(DeviceRow.batteryText(level: 20, warning: .discharged, timeCheck: true),
                       "DISCHARGED? (20%) - allowing full discharge can damage battery.")
        XCTAssertEqual(DeviceRow.batteryText(level: 95, warning: .damaged, timeCheck: true),
                       "DAMAGED? (95%) - indications of possibly damaged device battery or clock, check carefully.")
        // -notimecheck suppresses the prefixes.
        XCTAssertEqual(DeviceRow.batteryText(level: 95, warning: .damaged, timeCheck: false), "95%")

        XCTAssertEqual(DeviceRow.batteryColor(level: 0), .red)
        XCTAssertEqual(DeviceRow.batteryColor(level: 32), .red)
        XCTAssertEqual(DeviceRow.batteryColor(level: 33), .orange)
        XCTAssertEqual(DeviceRow.batteryColor(level: 65), .orange)
        XCTAssertEqual(DeviceRow.batteryColor(level: 66), .green)
        // Upstream's final `else` also catches an unread battery.
        XCTAssertEqual(DeviceRow.batteryColor(level: nil), .green)
    }

    func testGroupOrderMatchesDeviceListView() {
        XCTAssertEqual(SourceCategory.displayOrder.map(\.groupName),
                       ["Devices", "New Data", "Downloading", "Downloaded", "Charging",
                        "Standby", "Outbox", "Removed", "Files"])
    }

    // MARK: - Toolbar enable rules

    func testToolbarStateFollowsUpstreamRules() throws {
        let harness = try GuiHarness()
        defer { harness.tearDown() }
        let withData = try harness.device(1234)
        let empty = try harness.device(5678)
        withData.update(force: true)
        empty.update(force: true)

        let dataRow = DeviceRow(device: withData, timeCheck: true)
        let emptyRow = DeviceRow(device: empty, timeCheck: true)

        XCTAssertTrue(dataRow.hasData)
        XCTAssertFalse(emptyRow.hasData)

        // Nothing selected: everything off.
        XCTAssertEqual(DeviceToolbarState(selection: []), DeviceToolbarState())

        // All have data, none recording: download and clear are live, record is not.
        var state = DeviceToolbarState(selection: [dataRow])
        XCTAssertTrue(state.download)
        XCTAssertTrue(state.clear)
        XCTAssertFalse(state.record)
        XCTAssertFalse(state.stop)
        XCTAssertTrue(state.identify)

        // A mixed selection cannot download (not all have data).
        state = DeviceToolbarState(selection: [dataRow, emptyRow])
        XCTAssertFalse(state.download)
        XCTAssertFalse(state.record)

        // An empty, unconfigured device can be recorded to but not cleared.
        state = DeviceToolbarState(selection: [emptyRow])
        XCTAssertTrue(state.record)
        XCTAssertFalse(state.clear)
        XCTAssertFalse(state.download)

        // Once it is recording, Stop lights up and Record does not.
        XCTAssertTrue(empty.alwaysRecord())
        empty.update(force: true)
        let recordingRow = DeviceRow(device: empty, timeCheck: true)
        state = DeviceToolbarState(selection: [recordingRow])
        XCTAssertTrue(state.stop)
        XCTAssertTrue(state.clear)      // no data but configured to record
        XCTAssertFalse(state.download)
    }

    // MARK: - Plugin queue

    @MainActor
    func testPluginQueue() {
        let queue = PluginQueue()
        let first = queue.enqueue(pluginName: "OmConvertPlugin", source: "/tmp/a.cwa")
        let second = queue.enqueue(pluginName: "Convert_CWA", source: "/tmp/b.cwa")
        XCTAssertEqual(queue.items.count, 2)
        XCTAssertEqual(queue.items[0].progressText, "0")

        queue.update(first, progress: 55, state: .running)
        XCTAssertEqual(queue.items[0].progressText, "55")
        queue.update(first, progress: 100, state: .complete)
        XCTAssertEqual(queue.items[0].progressText, "Complete")

        queue.cancel([second])
        XCTAssertEqual(queue.items[1].state, .cancelled)

        queue.clearCompleted()
        XCTAssertTrue(queue.items.isEmpty)
    }
}
