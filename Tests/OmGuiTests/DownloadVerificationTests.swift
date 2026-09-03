import Foundation
import OmApi
import OmGuiCore
import XCTest

/// The checks that stand between a device and a file named after somebody else's participant, and
/// the two ways a download that transferred can still fail to land.
@MainActor
final class DownloadVerificationTests: XCTestCase {

    private var harness: GuiHarness!

    override func setUpWithError() throws {
        harness = try GuiHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
    }

    // MARK: - Identity verification (both refusal branches)

    /// The file on the device was written by a different unit: `{DeviceId}_{SessionId}` would name
    /// it after the device in front of the operator, not after the recording in it.
    func testResolveRefusesWhenTheFileWasWrittenByAnotherDevice() throws {
        let device = try harness.device(1234)
        device.update(force: true)
        try writeForeignDataFile(at: device.dataFilePath, deviceId: 4321, sessionId: device.sessionId)

        guard case .failure(let reason) = DownloadFlow.resolve(device: device,
                                                              template: FilenameTemplate.defaultTemplate,
                                                              workspace: harness.workspace) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(reason, DownloadFlow.deviceIdError)

        let prompter = RecordingPrompter()
        let outcome = DownloadFlow.run(devices: [device],
                                       template: FilenameTemplate.defaultTemplate,
                                       workspace: harness.workspace,
                                       prompt: prompter)
        XCTAssertTrue(outcome.started.isEmpty)
        XCTAssertEqual(outcome.errors["01234"], DownloadFlow.deviceIdError)
        XCTAssertEqual(prompter.warnings.first?.title, FlowMessages.downloadFilenameTitle)
        XCTAssertEqual(prompter.warnings.first?.message, FlowMessages.deviceIdNotVerified)
        XCTAssertTrue(outcome.summary?.hasPrefix("0 devices downloading:") ?? false, "\(outcome.summary ?? "-")")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.workspace.path), [])
    }

    /// The device has been given a new session id since the recording was made, so the file's own
    /// session no longer matches: naming the download after either one is wrong.
    func testResolveRefusesWhenTheSessionIdDoesNotMatchTheFile() throws {
        let device = try harness.device(1234)
        device.update(force: true)
        XCTAssertEqual(device.sessionId, 1)
        // `setSessionId(commit: false)` updates the device without rewriting the file header.
        XCTAssertTrue(device.setSessionId(2, commit: false))

        guard case .failure(let reason) = DownloadFlow.resolve(device: device,
                                                              template: FilenameTemplate.defaultTemplate,
                                                              workspace: harness.workspace) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(reason, DownloadFlow.sessionIdError)

        let prompter = RecordingPrompter()
        let outcome = DownloadFlow.run(devices: [device],
                                       template: FilenameTemplate.defaultTemplate,
                                       workspace: harness.workspace,
                                       prompt: prompter)
        XCTAssertTrue(outcome.started.isEmpty)
        XCTAssertEqual(outcome.errors["01234"], DownloadFlow.sessionIdError)
        XCTAssertEqual(prompter.warnings.first?.message, FlowMessages.sessionIdNotVerified)
        XCTAssertTrue(outcome.summary?.contains("Device: 01234 - Status: \(DownloadFlow.sessionIdError)") ?? false)
    }

    /// `sessionId == .max` is "never read": the device has not answered, so nothing has been
    /// verified and the download must not be named from the file alone.
    func testResolveRefusesWhenTheSessionIdHasNotBeenReadYet() throws {
        let device = try harness.device(1234)
        XCTAssertEqual(device.sessionId, .max, "an unpolled device must not claim a session id")
        XCTAssertTrue(device.hasData)

        guard case .failure(let reason) = DownloadFlow.resolve(device: device,
                                                              template: FilenameTemplate.defaultTemplate,
                                                              workspace: harness.workspace) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(reason, DownloadFlow.sessionIdError)
    }

    /// The happy path still resolves once the device has been polled — the guard above is not just
    /// refusing everything.
    func testResolveAcceptsAMatchingDeviceAndFile() throws {
        let device = try harness.device(1234)
        device.update(force: true)
        guard case .plan(let plan) = DownloadFlow.resolve(device: device,
                                                         template: FilenameTemplate.defaultTemplate,
                                                         workspace: harness.workspace) else {
            return XCTFail("expected a plan")
        }
        XCTAssertEqual(plan.finalPath.lastPathComponent, "01234_0000000001.cwa")
    }

    // MARK: - U3: a data file that will not open at all

    func testUnreadableDataFileIsItsOwnFailureNotAnIdentityMismatch() throws {
        let device = try harness.device(1234)
        device.update(force: true)
        // Big enough to count as data, not a CWA: what a denied removable-volume prompt or a
        // damaged recording looks like from here.
        try Data(repeating: 0x5A, count: 4096).write(to: URL(fileURLWithPath: device.dataFilePath))
        XCTAssertNil(FileMetadata(path: device.dataFilePath))
        XCTAssertTrue(device.hasData)

        guard case .failure(let reason) = DownloadFlow.resolve(device: device,
                                                              template: FilenameTemplate.defaultTemplate,
                                                              workspace: harness.workspace) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(reason, DownloadFlow.unreadableFileError)
        XCTAssertNotEqual(reason, DownloadFlow.deviceIdError)

        let prompter = RecordingPrompter()
        DownloadFlow.run(devices: [device],
                         template: FilenameTemplate.defaultTemplate,
                         workspace: harness.workspace,
                         prompt: prompter)
        let message = try XCTUnwrap(prompter.warnings.first?.message)
        XCTAssertTrue(message.contains(device.dataFilePath), "the message must name the file: \(message)")
        XCTAssertTrue(message.contains("Removable Volumes"), message)
        XCTAssertFalse(message.contains("reconnect the device"),
                       "reconnecting cannot fix a file that will not open")
    }

    // MARK: - C2 / C35: the rename at the end of the download

    /// A file that appeared at the destination while the transfer was running is not overwritten,
    /// and the download is reported as failed rather than as `DOWNLOAD-OK`.
    func testRenameFailureIsReportedAsAnErrorAndKeepsTheExistingFile() throws {
        let device = try harness.device(1234)
        device.update(force: true)
        let paths = FilenameTemplate.downloadPaths(workspace: harness.workspace, baseName: "01234_0000000001")
        try Data("someone else's recording".utf8).write(to: paths.final)

        let waiter = DownloadWaiter()
        waiter.observe(harness.api)
        waiter.expect([1234])
        try device.beginDownloading(to: paths.partial.path, renameTo: paths.final.path)
        XCTAssertTrue(waiter.wait(), "the download did not settle")

        XCTAssertEqual(waiter.status(1234), .error, "a failed rename is a failed download")
        XCTAssertEqual(device.downloadStatus, .error)
        let failure = try XCTUnwrap(device.downloadFailure)
        XCTAssertTrue(failure.contains(paths.final.path), failure)
        XCTAssertEqual(try Data(contentsOf: paths.final), Data("someone else's recording".utf8),
                       "the existing file must not be destroyed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.partial.path),
                      "the transferred data must be left where it can still be recovered")
        XCTAssertTrue(device.hasNewData,
                      "a device whose download never landed still holds new data")
    }

    func testSuccessfulDownloadClearsTheFailureAndRenames() throws {
        let device = try harness.device(1234)
        device.update(force: true)
        let paths = FilenameTemplate.downloadPaths(workspace: harness.workspace, baseName: "01234_0000000001")

        let waiter = DownloadWaiter()
        waiter.observe(harness.api)
        waiter.expect([1234])
        try device.beginDownloading(to: paths.partial.path, renameTo: paths.final.path)
        XCTAssertTrue(waiter.wait())

        XCTAssertEqual(waiter.status(1234), .complete)
        XCTAssertNil(device.downloadFailure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.final.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.partial.path))
    }

    /// The completion carries the file it produced, so the record of a finished download does not
    /// depend on re-`stat`ing a path that a *later* download of the same device may already have
    /// deleted (its overwrite prompt removes the destination before it starts).
    func testTheCompletedPathIsReportedByTheDeviceAndResetOnTheNextDownload() throws {
        let device = try harness.device(1234)
        device.update(force: true)
        let paths = FilenameTemplate.downloadPaths(workspace: harness.workspace, baseName: "01234_0000000001")

        let waiter = DownloadWaiter()
        waiter.observe(harness.api)
        waiter.expect([1234])
        XCTAssertNil(device.lastDownloadedPath)
        try device.beginDownloading(to: paths.partial.path, renameTo: paths.final.path)
        XCTAssertTrue(waiter.wait())
        XCTAssertEqual(device.lastDownloadedPath, paths.final.path)

        // Starting again clears it, so a stale value can never be logged as this download's result.
        try FileManager.default.removeItem(at: paths.final)
        let second = DownloadWaiter()
        second.observe(harness.api)
        second.expect([1234])
        try device.beginDownloading(to: paths.partial.path, renameTo: paths.final.path)
        XCTAssertTrue(second.wait())
        XCTAssertEqual(device.lastDownloadedPath, paths.final.path)
    }

    // MARK: - Helpers

    /// A valid CWA header written by another device, in place of this one's data file.
    private func writeForeignDataFile(at path: String, deviceId: UInt32, sessionId: UInt32) throws {
        let writer = CwaWriter(hardware: .ax3, deviceId: deviceId, sessionId: sessionId,
                               config: AccelConfig(rate: .hz100, range: .g8),
                               metadata: "", loggingStart: .zero, loggingEnd: .infinite,
                               firmwareRevision: 48)
        let data = writer.fileData(startTime: OmDateTime(date: Date().addingTimeInterval(-60)),
                                   blockCount: 4)
        try data.write(to: URL(fileURLWithPath: path))
    }
}
