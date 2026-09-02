import XCTest
import COmApi
@testable import OmApi

/// Regression guard for the vendored C layer.
///
/// `OM_DATETIME` was `unsigned long` upstream, which is 32-bit on Windows but 64-bit on macOS.
/// Because it is a member of the tightly-packed reader packets, the 64-bit width silently shifted
/// every field after `timestamp` by four bytes, so `OmReaderGetValue()` returned garbage for
/// light, temperature, events, battery and sample rate on any 64-bit build. See Vendor/PATCHES.md.
final class COmApiLayoutTests: XCTestCase {

    func testPackedStructSizes() {
        XCTAssertEqual(MemoryLayout<OM_DATETIME>.size, 4, "OM_DATETIME must be exactly 32 bits")
        XCTAssertEqual(MemoryLayout<OM_READER_DATA_PACKET>.size, 512)
        XCTAssertEqual(MemoryLayout<OM_READER_HEADER_PACKET>.size, 1024)
        XCTAssertEqual(Int(OM_METADATA_SIZE), 448)
    }

    func testDataPacketFieldsLandOnTheDocumentedOffsets() {
        let writer = CwaWriter(hardware: .ax3, deviceId: 1234, sessionId: 55,
                               config: AccelConfig(rate: .hz100, range: .g8),
                               battery: 168, light: 300, temperature: 256)
        let stamp = OmDateTime(year: 2026, month: 9, day: 1, hour: 8, minute: 0, second: 0)
        let bytes = writer.dataBlock(sequenceId: 9, timestamp: stamp, timestampOffset: 3,
                                     samples: [Int16](repeating: 1, count: 240), events: 0x01)
        XCTAssertEqual(bytes.count, MemoryLayout<OM_READER_DATA_PACKET>.size)

        let packet = bytes.withUnsafeBytes { $0.loadUnaligned(as: OM_READER_DATA_PACKET.self) }
        XCTAssertEqual(packet.packetHeader, 0x5841)     // @0  "AX"
        XCTAssertEqual(packet.packetLength, 508)        // @2
        XCTAssertEqual(packet.deviceFractional, 1234)   // @4
        XCTAssertEqual(packet.sessionId, 55)            // @6
        XCTAssertEqual(packet.sequenceId, 9)            // @10
        XCTAssertEqual(packet.timestamp, stamp.raw)     // @14
        XCTAssertEqual(packet.light & 0x03FF, 300)      // @18  <- first field past OM_DATETIME
        XCTAssertEqual(packet.temperature, 256)         // @20
        XCTAssertEqual(packet.events, 0x01)             // @22
        XCTAssertEqual(packet.battery, 168)             // @23
        XCTAssertEqual(packet.sampleRate, 74)           // @24
        XCTAssertEqual(packet.numAxesBPS, 0x32)         // @25
        XCTAssertEqual(packet.timestampOffset, 3)       // @26
        XCTAssertEqual(packet.sampleCount, 80)          // @28
    }

    func testHeaderPacketFieldsLandOnTheDocumentedOffsets() {
        let start = OmDateTime(year: 2026, month: 9, day: 1, hour: 8, minute: 0, second: 0)
        let writer = CwaWriter(hardware: .ax6, deviceId: 5678, sessionId: 77,
                               config: AccelConfig(rate: .hz100, range: .g8, gyro: .dps1000),
                               metadata: "_sc=P002", loggingStart: start,
                               loggingEnd: .infinite, firmwareRevision: 53)
        let bytes = writer.headerBlock()
        XCTAssertEqual(bytes.count, MemoryLayout<OM_READER_HEADER_PACKET>.size)

        let header = bytes.withUnsafeBytes { $0.loadUnaligned(as: OM_READER_HEADER_PACKET.self) }
        XCTAssertEqual(header.packetHeader, 0x444D)       // @0  "MD"
        XCTAssertEqual(header.packetLength, 1020)         // @2
        XCTAssertEqual(header.deviceId, 5678)             // @5
        XCTAssertEqual(header.sessionId, 77)              // @7
        XCTAssertEqual(header.loggingStartTime, start.raw)// @13
        XCTAssertEqual(header.loggingEndTime, .max)       // @17
        XCTAssertEqual(header.samplingRate, 74)           // @36 <- past two OM_DATETIME fields
        XCTAssertEqual(header.firmwareRevision, 53)       // @41

        // @64 annotation
        let annotation = withUnsafeBytes(of: header.annotation) { Array($0.prefix(8)) }
        XCTAssertEqual(annotation, Array("_sc=P002".utf8))
    }

    /// Every code the header documents must be recognised on both sides. The Swift text is a
    /// friendlier restatement of libomapi's terse `OmErrorString`, so only recognition is compared.
    func testEveryDocumentedErrorCodeIsRecognised() {
        for code: Int32 in [0, -1, -2, -3, -4, -5, -6, -7, -8, -9, -10, -11, -12] {
            let fromC = String(cString: OmErrorString(code))
            XCTAssertFalse(fromC.isEmpty, "OmErrorString(\(code))")
            XCTAssertNotEqual(fromC, "Unknown", "libomapi does not know code \(code)")
            XCTAssertFalse(OmError(code: code).message.hasPrefix("Unknown"), "OmError does not know code \(code)")
        }
        XCTAssertEqual(OmError(code: -99).message, "Unknown error -99")
    }

    func testOmCheckMapsNegativeStatusToAThrow() {
        XCTAssertEqual(try? omCheck(3, "ok"), 3)
        XCTAssertThrowsError(try omCheck(-5, "OmSetAccelConfig")) { error in
            let omError = error as? OmError
            XCTAssertEqual(omError, .invalidArg)
            XCTAssertEqual(omError?.operation, "OmSetAccelConfig")
            XCTAssertEqual(omError?.description, "OmSetAccelConfig: Invalid argument (-5)")
        }
    }
}
