import XCTest
@testable import OmApi

/// Vectors traced from `MainForm.toolStripButtonDownload_Click`.
final class FilenameTemplateTests: XCTestCase {

    func testDefaultTemplateFormatting() {
        // {DeviceId} is "{0:00000}", {SessionId} is "{0:0000000000}".
        XCTAssertEqual(FilenameTemplate.expand(FilenameTemplate.defaultTemplate,
                                               deviceId: 1234, sessionId: 7),
                       "01234_0000000007")
        XCTAssertEqual(FilenameTemplate.expand("", deviceId: 42, sessionId: 0),
                       "00042_0000000000")
        XCTAssertEqual(FilenameTemplate.expand(FilenameTemplate.defaultTemplate,
                                               deviceId: 123456, sessionId: 4294967294),
                       "123456_4294967294")
    }

    func testUnknownDeviceSessionFallsBackToTheFile() {
        // device.SessionId == uint.MaxValue -> use the file's session id, else "0000000000".
        XCTAssertEqual(FilenameTemplate.expand(FilenameTemplate.defaultTemplate,
                                               deviceId: 1234, sessionId: .max,
                                               fileSessionId: "0000000099"),
                       "01234_0000000099")
        XCTAssertEqual(FilenameTemplate.expand(FilenameTemplate.defaultTemplate,
                                               deviceId: 1234, sessionId: .max),
                       "01234_0000000000")
    }

    func testSanitiseWhitelist() {
        // Anything outside [0-9A-Za-z_-] becomes '_'.
        XCTAssertEqual(FilenameTemplate.sanitise("abcXYZ019-_"), "abcXYZ019-_")
        XCTAssertEqual(FilenameTemplate.sanitise("P 01"), "P_01")
        XCTAssertEqual(FilenameTemplate.sanitise("R&D"), "R_D")
        XCTAssertEqual(FilenameTemplate.sanitise("a/b\\c:d*e?f\"g<h>i|j"), "a_b_c_d_e_f_g_h_i_j")
        XCTAssertEqual(FilenameTemplate.sanitise("Müller"), "M_ller")
        XCTAssertEqual(FilenameTemplate.sanitise("../etc/passwd"), "___etc_passwd")
        // Empty becomes "-".
        XCTAssertEqual(FilenameTemplate.sanitise(""), "-")
    }

    func testMetadataPlaceholders() {
        let metadata = ["SubjectCode": "P 01", "StudyCode": "R&D", "StudyCentre": "SITE1"]
        XCTAssertEqual(FilenameTemplate.expand("{SubjectCode}-{StudyCode}",
                                               deviceId: 1, sessionId: 1, metadata: metadata),
                       "P_01-R_D")
        XCTAssertEqual(FilenameTemplate.expand("{StudyCentre}_{DeviceId}",
                                               deviceId: 7, sessionId: 1, metadata: metadata),
                       "SITE1_00007")
    }

    func testMissingBuiltInKeyBecomesEmpty() {
        // OMGUI substitutes "" for a built-in key that the file does not carry.
        XCTAssertEqual(FilenameTemplate.expand("{SubjectCode}", deviceId: 1, sessionId: 1), "-")
        XCTAssertEqual(FilenameTemplate.expand("x{SubjectNotes}y", deviceId: 1, sessionId: 1), "xy")
    }

    func testUnknownPlaceholderIsLeftInPlaceThenSanitised() {
        // Not a built-in key and not present in the metadata, so the braces survive to sanitising.
        XCTAssertEqual(FilenameTemplate.expand("{Nope}", deviceId: 1, sessionId: 1), "_Nope_")
    }

    func testCustomMetadataKeyIsSubstituted() {
        XCTAssertEqual(FilenameTemplate.expand("{Site}", deviceId: 1, sessionId: 1,
                                               metadata: ["Site": "ward 3"]),
                       "ward_3")
    }

    func testDownloadPathsUsePartThenRename() {
        let workspace = URL(fileURLWithPath: "/tmp/ws")
        let paths = FilenameTemplate.downloadPaths(workspace: workspace, baseName: "01234_0000000001")
        XCTAssertEqual(paths.partial.lastPathComponent, "01234_0000000001.cwa.part")
        XCTAssertEqual(paths.final.lastPathComponent, "01234_0000000001.cwa")
    }
}
