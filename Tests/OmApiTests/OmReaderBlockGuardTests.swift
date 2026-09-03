import XCTest
@testable import OmApi

/// The reader's divide-by-zero guards (`Vendor/PATCHES.md`, C37).
///
/// `omapi-reader.c` took `(512 - 32) / (numAxes * 2)` and `3200 / (1 << (15 - rateCode))` straight
/// from the packet. A zero axis count, and any rate code below 4 (whose true rate is under 1 Hz and
/// so truncates to zero), made both divisors zero. arm64's UDIV/SDIV return 0 instead of trapping,
/// so the block came back as a plausible-looking zero-duration one that the viewer's `DataLevel`
/// then dropped without a diagnostic — whole regions of a partly-corrupt file simply went missing.
/// Both cases must now reject the block.
final class OmReaderBlockGuardTests: XCTestCase {

    private let start = OmDateTime(year: 2026, month: 9, day: 1, hour: 8, minute: 0, second: 0)

    private func writer() -> CwaWriter {
        CwaWriter(deviceId: 1234, sessionId: 1, config: AccelConfig(rate: .hz100, range: .g8))
    }

    /// Overwrites one byte of one data block and repairs the packet checksum, so the block still
    /// reaches the field checks under test rather than being rejected as corrupt.
    private func patch(_ data: inout Data, block: Int, offset: Int, to value: UInt8) {
        let base = CwaWriter.headerSize + block * CwaWriter.blockSize
        data[base + offset] = value
        data[base + 510] = 0
        data[base + 511] = 0
        var sum: UInt16 = 0
        var i = base
        while i < base + CwaWriter.blockSize {
            sum = sum &+ (UInt16(data[i]) | (UInt16(data[i + 1]) << 8))
            i += 2
        }
        let checksum = 0 &- sum
        data[base + 510] = UInt8(checksum & 0xFF)
        data[base + 511] = UInt8(checksum >> 8)
    }

    private func write(_ data: Data) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omgui-guard-\(UUID().uuidString).cwa")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    private func sequenceIds(of data: Data) throws -> [UInt32] {
        let reader = try OmReader(path: try write(data))
        defer { reader.close() }
        return reader.readAllBlocks().map(\.sequenceId)
    }

    func testUnpatchedFileReadsEveryBlock() throws {
        XCTAssertEqual(try sequenceIds(of: writer().fileData(startTime: start, blockCount: 4)), [0, 1, 2, 3])
    }

    /// `@25` high nibble = axis count. Zero axes with 16-bit packing divided by zero twice.
    func testBlockWithNoAxesIsRejected() throws {
        var data = writer().fileData(startTime: start, blockCount: 4)
        patch(&data, block: 1, offset: 25, to: 0x02)        // axes = 0, packing = 2 (16-bit)
        XCTAssertEqual(try sequenceIds(of: data), [0, 2, 3])
    }

    /// `@24` low nibble = rate code. Codes 0–3 are the ones the reader's integer arithmetic
    /// flattens to 0 Hz; code 4 is the first that survives it, and must still be read.
    func testBlocksWithARateCodeBelowOneHertzAreRejected() throws {
        for code in UInt8(0)...UInt8(3) {
            var data = writer().fileData(startTime: start, blockCount: 4)
            patch(&data, block: 2, offset: 24, to: code)
            XCTAssertEqual(try sequenceIds(of: data), [0, 1, 3], "rate code \(code) must reject the block")
        }

        var data = writer().fileData(startTime: start, blockCount: 4)
        patch(&data, block: 2, offset: 24, to: 4)           // 3200 / (1 << 11) = 1 Hz
        XCTAssertEqual(try sequenceIds(of: data), [0, 1, 2, 3], "the lowest non-zero rate is still valid")
    }

    /// Every block bad: the reader must run to end-of-file, not spin or crash.
    func testAFileOfNothingButDegenerateBlocksReadsEmpty() throws {
        var data = writer().fileData(startTime: start, blockCount: 4)
        for block in 0..<4 { patch(&data, block: block, offset: 24, to: 0) }
        XCTAssertEqual(try sequenceIds(of: data), [])
    }
}
