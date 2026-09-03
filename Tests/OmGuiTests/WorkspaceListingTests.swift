import Foundation
import OmApi
import XCTest
@testable import OmGuiCore

/// Listing the working folder: what happens when it cannot be read, and what it costs when it can.
final class WorkspaceListingTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omgui-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - A folder that cannot be read (C28)

    func testAnUnreadableFolderIsReportedRatherThanLookingEmpty() throws {
        // A `~/Documents` the user answered "Don't Allow" for raises the same error a folder with
        // no search permission does.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: root.path),
                      "running as a user that can read a 0o000 directory")

        XCTAssertTrue(WorkspaceListing.dataFiles(in: root, showAll: true).isEmpty)
        let failure = try XCTUnwrap(WorkspaceListing.lastFailure,
                                    "an empty list with no explanation is C28 all over again")
        XCTAssertEqual(failure.folder, root.path)
        XCTAssertTrue(failure.message.contains("not allowed to read"), failure.message)
        XCTAssertTrue(failure.message.contains("Privacy & Security"), failure.message)

        // A listing that works clears it, so the notice does not outlive the problem.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertTrue(WorkspaceListing.dataFiles(in: root, showAll: true).isEmpty)
        XCTAssertNil(WorkspaceListing.lastFailure)
    }

    func testAMissingFolderSaysSo() throws {
        let missing = root.appendingPathComponent("gone", isDirectory: true)
        XCTAssertTrue(WorkspaceListing.outputFiles(in: missing).isEmpty)
        let failure = try XCTUnwrap(WorkspaceListing.lastFailure)
        XCTAssertEqual(failure.folder, missing.path)
        XCTAssertTrue(failure.message.contains("no longer exists"), failure.message)
        _ = WorkspaceListing.outputFiles(in: root)
        XCTAssertNil(WorkspaceListing.lastFailure)
    }

    // MARK: - What a refresh costs (U2)

    /// `refreshFiles()` opens every candidate through `OmReader` on the main thread, and every
    /// finished job triggers a full rescan. `refs/10-deep-review.md` U2 asks whether that is
    /// actually expensive: an open is a header read, one block, a seek to EOF and the last block —
    /// three seeks, not a scan. This is the measurement the decision rests on; the numbers land in
    /// `refs/11-fixes-ui-viewer-plugins.md`.
    func testTheCostOfListingAWorkspaceOfLargeFiles() throws {
        let fileCount = 25
        let megabytes = 16
        // 16 MB of AX3 data: one file's bytes, written 25 times (the probe cost is per file, and
        // the reader only ever touches the ends of one).
        let writer = CwaWriter(hardware: .ax3, deviceId: 4242, sessionId: 7,
                               config: AccelConfig(rate: .hz100, range: .g8))
        let blocks = megabytes * 1024 * 1024 / CwaWriter.blockSize
        let data = writer.fileData(startTime: OmDateTime(year: 2026, month: 9, day: 1,
                                                         hour: 8, minute: 0, second: 0),
                                   blockCount: blocks)
        for index in 0..<fileCount {
            try data.write(to: root.appendingPathComponent(String(format: "file-%02d.cwa", index)))
        }
        // One warm pass first: the measurement is of the probing, not of the page cache.
        _ = WorkspaceListing.dataFiles(in: root, showAll: false)

        var worst = 0.0
        var total = 0.0
        let passes = 5
        for _ in 0..<passes {
            let began = Date()
            let files = WorkspaceListing.dataFiles(in: root, showAll: false)
            let elapsed = -began.timeIntervalSinceNow
            XCTAssertEqual(files.count, fileCount)
            worst = max(worst, elapsed)
            total += elapsed
        }
        let mean = total / Double(passes)
        print(String(format: "PERF: listing %d x %d MB CWA files: %.1f ms mean, %.1f ms worst "
                     + "(%.2f ms a file)", fileCount, megabytes, mean * 1000, worst * 1000,
                     mean * 1000 / Double(fileCount)))

        // U2's threshold for moving the probe off the main thread is ~50 ms a file.
        XCTAssertLessThan(mean / Double(fileCount), 0.050,
                          "a workspace refresh is cheap enough to stay on the main thread")
    }
}
