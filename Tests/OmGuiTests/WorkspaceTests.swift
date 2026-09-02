import Foundation
import OmApi
import OmGuiCore
import XCTest

/// Workspace listing and formatting (`fileListViewRefreshList` / `UpdateFile`).
final class WorkspaceTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omgui-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, bytes: Int) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// Copies a real CWA out of a mock device volume so the reader accepts it.
    private func copyRealCwa(named name: String) throws -> URL {
        let harness = try GuiHarness(specs: [MockBackend.Spec.defaults[0]])
        defer { harness.tearDown() }
        let device = try harness.device(1234)
        let destination = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(atPath: device.dataFilePath, toPath: destination.path)
        return destination
    }

    // MARK: - Formatting

    func testSizeIsMegabytesToTwoDecimals() {
        XCTAssertEqual(WorkspaceListing.sizeText(bytes: 0), "0.00")
        XCTAssertEqual(WorkspaceListing.sizeText(bytes: 1024 * 1024), "1.00")
        XCTAssertEqual(WorkspaceListing.sizeText(bytes: 1024 * 1024 * 3 / 2), "1.50")
        XCTAssertEqual(WorkspaceListing.sizeText(bytes: 507_904_000), "484.38")
    }

    func testDateUsesOmguiFormat() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 2
        components.hour = 14; components.minute = 5; components.second = 6
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let date = calendar.date(from: components)!
        XCTAssertEqual(WorkspaceListing.dateText(date), "02/09/26 14:05:06")
    }

    // MARK: - Listing

    func testDataFilesListsOnlyReadableCwaByDefault() throws {
        _ = try write("notes.txt", bytes: 10)
        _ = try write("bogus.cwa", bytes: 4096)          // right extension, unreadable header
        let real = try copyRealCwa(named: "00001_0000000001.cwa")

        let files = WorkspaceListing.dataFiles(in: folder, showAll: false)
        XCTAssertEqual(files.map(\.name), [real.lastPathComponent])
        XCTAssertEqual(URL(fileURLWithPath: files[0].location).resolvingSymlinksInPath(),
                       real.resolvingSymlinksInPath())
        XCTAssertFalse(files[0].sizeText.isEmpty)
        XCTAssertEqual(files[0].dateText.count, "dd/MM/yy HH:mm:ss".count)
    }

    func testShowAllFilesStillOnlyListsWhatTheReaderAccepts() throws {
        _ = try write("notes.txt", bytes: 10)
        let real = try copyRealCwa(named: "00001_0000000001.cwa")
        let files = WorkspaceListing.dataFiles(in: folder, showAll: true)
        XCTAssertEqual(files.map(\.name), [real.lastPathComponent])
    }

    func testShowAllFilesWithoutTheReaderFilterListsEverything() throws {
        _ = try write("notes.txt", bytes: 10)
        _ = try write("a.cwa", bytes: 32)
        let files = WorkspaceListing.dataFiles(in: folder, showAll: true, readableOnly: false)
        XCTAssertEqual(Set(files.map(\.name)), ["notes.txt", "a.cwa"])
    }

    func testOutputFilesExcludeCwaPartAndHiddenFiles() throws {
        _ = try write("result.csv", bytes: 20)
        _ = try write("result.wav", bytes: 20)
        _ = try write("keep.cwa", bytes: 20)
        _ = try write("keep.cwa.part", bytes: 20)
        _ = try write(".DS_Store", bytes: 20)

        let files = WorkspaceListing.outputFiles(in: folder)
        XCTAssertEqual(Set(files.map(\.name)), ["result.csv", "result.wav"])
    }

    func testOutputFilesUppercaseExtensionIsStillExcluded() throws {
        _ = try write("KEEP.CWA", bytes: 20)
        _ = try write("out.txt", bytes: 20)
        XCTAssertEqual(WorkspaceListing.outputFiles(in: folder).map(\.name), ["out.txt"])
    }

    // MARK: - Working-folder templates

    func testWorkspaceTemplatesExpand() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.path
        XCTAssertEqual(WorkspacePath.expand("{MyDocuments}"), documents)
        XCTAssertEqual(WorkspacePath.expand("{MyDocuments}/Studies"), documents + "/Studies")
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.path
        XCTAssertEqual(WorkspacePath.expand("{Desktop}"), desktop)
        XCTAssertEqual(WorkspacePath.expand("/tmp/plain"), "/tmp/plain")
        // A trailing separator is dropped; the URL carries the directory-ness instead.
        XCTAssertEqual(WorkspacePath.expand("/tmp/plain/"), "/tmp/plain")
        XCTAssertTrue(WorkspacePath.url("{MyDocuments}").hasDirectoryPath)
    }

    // MARK: - File metadata / property grid

    func testFileMetadataReadsHeaderIdentityAndConfiguration() throws {
        let file = try copyRealCwa(named: "00001_0000000001.cwa")
        let metadata = try XCTUnwrap(FileMetadata(path: file.path))
        XCTAssertEqual(metadata.deviceId, 1234)
        XCTAssertEqual(metadata.deviceIdText, "01234")
        XCTAssertEqual(metadata.sessionIdText, "0000000001")
        XCTAssertEqual(metadata.samplingRate, 100)
        XCTAssertEqual(metadata.samplingRange, 8)
        XCTAssertEqual(metadata.named["StudyCode"], "ARIA-IMPACT")
        XCTAssertEqual(metadata.named["SubjectSite"], "left wrist")
    }

    func testFilePropertyGridMatchesMetadataObject() throws {
        let file = try copyRealCwa(named: "00001_0000000001.cwa")
        let rows = PropertyGrid.rows(for: FileMetadata(path: file.path))
        XCTAssertEqual(rows.map(\.category).prefix(6),
                       ["Recording", "Recording", "Recording", "Recording", "Recording", "Recording"])
        XCTAssertEqual(rows.map(\.name), ["Device ID", "Session ID", "Sampling Rate", "Sampling Range",
                                          "Time Start", "Time End",
                                          "Centre", "Code", "Investigator", "Exercise Type", "Operator", "Notes",
                                          "Site", "Code", "Sex", "Height", "Weight", "Handedness", "Notes"])
        XCTAssertEqual(rows.first?.value, "01234")
        XCTAssertEqual(rows.first(where: { $0.category == "Subject" && $0.name == "Site" })?.value, "left wrist")
    }

    func testFileMetadataRejectsANonCwaFile() throws {
        let junk = try write("junk.cwa", bytes: 2048)
        XCTAssertNil(FileMetadata(path: junk.path))
        XCTAssertTrue(PropertyGrid.rows(for: nil).isEmpty)
    }
}
