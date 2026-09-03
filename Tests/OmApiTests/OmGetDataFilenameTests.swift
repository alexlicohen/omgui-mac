import XCTest
import COmApi

/// `OmGetDataFilename` bounds (`Vendor/PATCHES.md`, C13).
///
/// Upstream `strcat`'d `"/CWA-DATA.CWA"` onto a device path that can itself be `OM_MAX_PATH - 1`
/// characters long, into a buffer `omapi.h` documents as `OM_MAX_PATH` — a 13-byte overflow of
/// every internal caller's stack buffer, gated only by how long the FAT volume label happens to be.
/// The overflow itself needs a device mounted at a 243+ character path, so what is checkable here
/// is the other half of the contract: the buffer is validated and cleared before anything is
/// written to it, and nothing is ever written past the terminator.
final class OmGetDataFilenameTests: XCTestCase {

    func testUnknownDeviceFailsWithoutWritingPastTheTerminator() {
        let capacity = Int(OM_MAX_PATH) + 64
        var buffer = [CChar](repeating: 0x7F, count: capacity)

        let status = buffer.withUnsafeMutableBufferPointer { OmGetDataFilename(999_999, $0.baseAddress!) }

        XCTAssertLessThan(status, OM_OK, "a device that was never seen cannot have a data file")
        XCTAssertEqual(buffer[0], 0, "the result buffer is emptied before the device is looked up")
        for index in 1..<capacity {
            XCTAssertEqual(buffer[index], 0x7F, "byte \(index) was written on a failure path")
        }
    }

    func testNullBufferIsRejected() {
        XCTAssertLessThan(OmGetDataFilename(999_999, nil), OM_OK)
    }
}
