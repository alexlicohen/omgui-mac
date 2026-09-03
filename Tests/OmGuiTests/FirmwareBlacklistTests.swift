import Foundation
import OmApi
import OmGuiCore
import XCTest

/// `MainForm.CheckFirmware`'s blacklist half, which Record and Clear both run.
@MainActor
final class FirmwareBlacklistTests: XCTestCase {

    /// Upstream's own `firmware/bootload.ini`.
    private let sample = """
        ; Bootload configuration file

        [CWA17]
        _version=CWA17_45
        _executable=firmware\\CWA17_45.cmd
        CWA17_42=V42 is known to have a potential problem which can limit the recording duration.
        ;CWA17_44=V44 is temporarily marked for upgrade just for debugging.

        [AX664]
        _version=AX664_51
        AX664_50:
        """

    func testParsesSectionsVersionsCommentsAndBothSeparators() throws {
        let blacklist = FirmwareBlacklist.parse(sample)

        let v42 = try XCTUnwrap(blacklist.entries["CWA17_42"])
        XCTAssertEqual(v42.section, "CWA17")
        XCTAssertEqual(v42.latest, "CWA17_45")
        XCTAssertEqual(v42.reason,
                       "V42 is known to have a potential problem which can limit the recording duration.")

        XCTAssertNil(blacklist.entries["CWA17_44"], "a commented-out line is not a blacklist entry")
        XCTAssertNil(blacklist.entries["_version"], "_-prefixed names are not versions")
        XCTAssertNil(blacklist.entries["_executable"])

        // `:` is the second separator upstream's parser accepts, and an empty reason falls back.
        let ax = try XCTUnwrap(blacklist.entries["AX664_50"])
        XCTAssertEqual(ax.section, "AX664")
        XCTAssertEqual(ax.latest, "AX664_51")
        XCTAssertEqual(ax.reason, FirmwareBlacklist.defaultReason)
    }

    func testVersionKeyIsTheSerialPrefixPlusTheFirmwareVersion() {
        XCTAssertEqual(FirmwareBlacklist.versionKey(serialId: "CWA17_01234", firmwareVersion: 42),
                       "CWA17_42")
        XCTAssertEqual(FirmwareBlacklist.versionKey(serialId: "AX617_06036222", firmwareVersion: 53),
                       "AX617_53")
        XCTAssertEqual(FirmwareBlacklist.versionKey(serialId: "", firmwareVersion: 42), "XXX00_42")
        XCTAssertEqual(FirmwareBlacklist.versionKey(serialId: "NOUNDERSCORE", firmwareVersion: 42),
                       "XXX00_42")
    }

    func testTheBuiltInTableIsUpstreamsBlacklist() {
        let entry = FirmwareBlacklist.builtIn.entry(serialId: "CWA17_01234", firmwareVersion: 42)
        XCTAssertEqual(entry?.version, "CWA17_42")
        XCTAssertEqual(entry?.latest, "CWA17_45")
        XCTAssertNil(FirmwareBlacklist.builtIn.entry(serialId: "CWA17_01234", firmwareVersion: 48))
        XCTAssertNil(FirmwareBlacklist.builtIn.entry(serialId: "AX617_05678", firmwareVersion: 53))
    }

    func testAFileOnDiskReplacesTheBuiltInTable() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omgui-firmware-\(UUID().uuidString)/firmware", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let file = folder.appendingPathComponent("bootload.ini")
        try "[CWA17]\n_version=CWA17_99\nCWA17_48=Local policy.\n".write(to: file, atomically: true, encoding: .utf8)

        let blacklist = FirmwareBlacklist.load(paths: [file])
        XCTAssertEqual(blacklist.entry(serialId: "CWA17_01234", firmwareVersion: 48)?.reason, "Local policy.")
        XCTAssertNil(blacklist.entry(serialId: "CWA17_01234", firmwareVersion: 42),
                     "the file replaces the built-in table rather than adding to it")
    }

    func testLoadFallsBackToTheBuiltInTableWhenNoFileIsThere() {
        let missing = URL(fileURLWithPath: "/nonexistent/firmware/bootload.ini")
        XCTAssertEqual(FirmwareBlacklist.load(paths: [missing]), FirmwareBlacklist.builtIn)
    }

    // MARK: - The check itself

    private func harness(firmware: Int, serial: String) throws -> (GuiHarness, OmDevice) {
        let spec = MockBackend.Spec(deviceId: 1234, serialId: serial, volumeLabel: "AX317_01234",
                                    port: "/dev/cu.usbmodem-mock1234", battery: 90,
                                    firmware: firmware, hardware: 65)
        let harness = try GuiHarness(specs: [spec])
        let device = try harness.device(1234)
        return (harness, device)
    }

    func testABlacklistedDeviceIsWarnedAboutAndTheFlowCanBeStopped() throws {
        let (harness, device) = try harness(firmware: 42, serial: "CWA17_01234")
        defer { harness.tearDown() }
        device.update(force: true)
        XCTAssertEqual(device.firmwareVersion, 42)

        let prompter = RecordingPrompter()
        prompter.confirmAnswers = [false]        // Cancel: do not carry on with this device
        XCTAssertTrue(checkFirmware([device], blacklist: .builtIn, prompt: prompter),
                      "Cancel must stop the flow, as upstream's update path does")
        XCTAssertEqual(prompter.confirms.first?.title, FirmwareBlacklist.title)
        let message = try XCTUnwrap(prompter.confirms.first?.message)
        XCTAssertTrue(message.contains("firmware version CWA17_42"), message)
        XCTAssertTrue(message.contains("limit the recording duration"), message)
        XCTAssertTrue(message.contains("CWA17_45"), message)
    }

    func testTheOperatorCanCarryOnWithABlacklistedDevice() throws {
        let (harness, device) = try harness(firmware: 42, serial: "CWA17_01234")
        defer { harness.tearDown() }
        device.update(force: true)

        let prompter = RecordingPrompter()
        prompter.confirmAnswers = [true]
        XCTAssertFalse(checkFirmware([device], blacklist: .builtIn, prompt: prompter))
        XCTAssertEqual(prompter.confirms.count, 1)
    }

    func testAnUpToDateDeviceIsNotWarnedAbout() throws {
        let (harness, device) = try harness(firmware: 48, serial: "CWA17_01234")
        defer { harness.tearDown() }
        device.update(force: true)

        let prompter = RecordingPrompter()
        XCTAssertFalse(checkFirmware([device], blacklist: .builtIn, prompt: prompter))
        XCTAssertTrue(prompter.confirms.isEmpty)
    }

    // MARK: - M7: a version that has not been read is not a version that has been checked

    /// The device is on the blacklisted firmware but has not been polled, so the check cannot see
    /// it. Skipping it silently (what this used to do) leaves `guard !checkFirmware(…)` reading as
    /// enforced while it is not — the case being eight AX3s plugged in and Record pressed a few
    /// seconds later, before the 100 ms round robin has reached them all.
    func testAnUnreadFirmwareVersionIsAQuestionNotASilentSkip() throws {
        let (harness, device) = try harness(firmware: 42, serial: "CWA17_01234")
        defer { harness.tearDown() }
        XCTAssertNil(device.firmwareVersion)

        let prompter = RecordingPrompter()
        prompter.confirmAnswers = [false]
        var lines: [String] = []
        XCTAssertTrue(checkFirmware([device], blacklist: .builtIn, prompt: prompter,
                                    log: { lines.append($0) }),
                      "declining the unchecked-firmware question must stop the flow")
        XCTAssertEqual(prompter.confirms.count, 1)
        XCTAssertEqual(prompter.confirms.first?.title, FirmwareBlacklist.uncheckedTitle)
        let message = try XCTUnwrap(prompter.confirms.first?.message)
        XCTAssertTrue(message.contains("01234"), message)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("firmware version unknown"), lines[0])
    }

    func testTheOperatorCanContinueWithoutTheFirmwareCheck() throws {
        let (harness, device) = try harness(firmware: 42, serial: "CWA17_01234")
        defer { harness.tearDown() }

        let prompter = RecordingPrompter()
        prompter.confirmAnswers = [true]
        XCTAssertFalse(checkFirmware([device], blacklist: .builtIn, prompt: prompter))
        XCTAssertEqual(prompter.confirms.count, 1,
                       "the blacklist cannot be consulted for a version that is not there")
    }

    /// Upstream's "Examining" pass: a caller that can safely read the device (the CLI, which has no
    /// background poll) supplies one, and then there is nothing to ask about — except the
    /// blacklist's own question, because the version turns out to be a blacklisted one.
    func testASuppliedReaderIsUsedInsteadOfAskingTheOperator() throws {
        let (harness, device) = try harness(firmware: 42, serial: "CWA17_01234")
        defer { harness.tearDown() }
        XCTAssertNil(device.firmwareVersion)

        let prompter = RecordingPrompter()
        prompter.confirmAnswers = [true]
        var read: [UInt32] = []
        XCTAssertFalse(checkFirmware([device], blacklist: .builtIn, prompt: prompter,
                                     readVersion: { device in
                                         read.append(device.deviceId)
                                         device.refreshStatus()
                                         return device.firmwareVersion
                                     }))
        XCTAssertEqual(read, [1234])
        XCTAssertEqual(device.firmwareVersion, 42)
        XCTAssertEqual(prompter.confirms.count, 1)
        XCTAssertEqual(prompter.confirms.first?.title, FirmwareBlacklist.title,
                       "with the version in hand the question is the blacklist's, not the unread one")
    }

    func testEveryBlacklistedDeviceInTheSelectionIsAskedAbout() throws {
        let specs = (0..<2).map { index in
            MockBackend.Spec(deviceId: UInt32(1234 + index),
                             serialId: "CWA17_0123\(4 + index)",
                             volumeLabel: "AX317_0123\(4 + index)",
                             port: "/dev/cu.usbmodem-mock\(index)", battery: 90,
                             firmware: 42, hardware: 65)
        }
        let harness = try GuiHarness(specs: specs)
        defer { harness.tearDown() }
        let devices = harness.api.devices
        for device in devices { device.update(force: true) }

        let prompter = RecordingPrompter()
        prompter.confirmAnswers = [true, true]
        XCTAssertFalse(checkFirmware(devices, blacklist: .builtIn, prompt: prompter))
        XCTAssertEqual(prompter.confirms.count, 2)

        // The first Cancel stops the flow immediately: the second device is never asked about.
        let stopper = RecordingPrompter()
        stopper.confirmAnswers = [false]
        XCTAssertTrue(checkFirmware(devices, blacklist: .builtIn, prompt: stopper))
        XCTAssertEqual(stopper.confirms.count, 1)
    }
}
