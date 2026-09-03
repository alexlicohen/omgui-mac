import XCTest
@testable import OmApi

/// `CwaWriter` byte layout against `Docs/ax3/cwa.h`, and a round trip back through libomapi's
/// reader (`OmReader`), which is the same C code a real download is parsed with.
final class CwaFileTests: XCTestCase {

    private func read16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | (UInt16(b[o + 1]) << 8) }
    private func read32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    func testHeaderBlockLayout() {
        let start = OmDateTime(year: 2026, month: 9, day: 1, hour: 8, minute: 0, second: 0)
        let stop = OmDateTime(year: 2026, month: 9, day: 8, hour: 8, minute: 0, second: 0)
        let writer = CwaWriter(hardware: .ax6, deviceId: 5678, sessionId: 77,
                               config: AccelConfig(rate: .hz100, range: .g8, gyro: .dps1000),
                               metadata: "_sc=P002",
                               loggingStart: start, loggingEnd: stop,
                               firmwareRevision: 53, flashLed: true)
        let header = writer.headerBlock()

        XCTAssertEqual(header.count, 1024)
        XCTAssertEqual(read16(header, 0), 0x444D, "@0 packetHeader 'MD'")
        XCTAssertEqual(read16(header, 2), 1020, "@2 packetLength")
        XCTAssertEqual(header[4], 0x64, "@4 hardwareType AX6")
        XCTAssertEqual(read16(header, 5), 5678, "@5 deviceId")
        XCTAssertEqual(read32(header, 7), 77, "@7 sessionId")
        XCTAssertEqual(read16(header, 11), 0, "@11 upperDeviceId")
        XCTAssertEqual(read32(header, 13), start.raw, "@13 loggingStartTime")
        XCTAssertEqual(read32(header, 17), stop.raw, "@17 loggingEndTime")
        XCTAssertEqual(read32(header, 21), 0, "@21 loggingCapacity")
        XCTAssertEqual(header[26], 1, "@26 flashLed")
        XCTAssertEqual(header[35], 3, "@35 sensorConfig: 1000 dps is 8000>>3")
        XCTAssertEqual(header[36], 74, "@36 samplingRate: 100 Hz at ±8 g")
        XCTAssertEqual(header[41], 53, "@41 firmwareRevision")
        XCTAssertEqual(read16(header, 42), 0xFFFF, "@42 timeZone unknown")
        XCTAssertEqual(Array(header[64..<72]), Array("_sc=P002".utf8), "@64 annotation")
        XCTAssertTrue(header[72..<512].allSatisfy { $0 == 0x20 }, "annotation is space padded")
    }

    func testAccelOnlyHeaderHasNoSensorConfig() {
        let writer = CwaWriter(hardware: .ax3, deviceId: 1, sessionId: 1)
        XCTAssertEqual(writer.headerBlock()[35], 0x00)
    }

    func testDataBlockLayoutAndChecksum() {
        let writer = CwaWriter(hardware: .ax3, deviceId: 1234, sessionId: 1,
                               config: AccelConfig(rate: .hz100, range: .g8),
                               battery: 168, light: 300, temperature: 256)
        let stamp = OmDateTime(year: 2026, month: 9, day: 1, hour: 8, minute: 0, second: 0)
        let samples = [Int16](repeating: 7, count: 80 * 3)
        let block = writer.dataBlock(sequenceId: 5, timestamp: stamp, timestampOffset: 3, samples: samples)

        XCTAssertEqual(block.count, 512)
        XCTAssertEqual(read16(block, 0), 0x5841, "@0 packetHeader 'AX'")
        XCTAssertEqual(read16(block, 2), 508, "@2 packetLength")
        XCTAssertEqual(read16(block, 4), 1234, "@4 deviceFractional (top bit clear = device id)")
        XCTAssertEqual(read32(block, 6), 1, "@6 sessionId")
        XCTAssertEqual(read32(block, 10), 5, "@10 sequenceId")
        XCTAssertEqual(read32(block, 14), stamp.raw, "@14 timestamp")
        XCTAssertEqual(read16(block, 18) & 0x03FF, 300, "@18 light in the bottom 10 bits")
        XCTAssertEqual(read16(block, 20), 256, "@20 temperature")
        XCTAssertEqual(block[23], 168, "@23 battery")
        XCTAssertEqual(block[24], 74, "@24 sampleRate code")
        XCTAssertEqual(block[25], 0x32, "@25 numAxesBPS: 3 axes, 16-bit packing")
        XCTAssertEqual(Int16(bitPattern: read16(block, 26)), 3, "@26 timestampOffset")
        XCTAssertEqual(read16(block, 28), 80, "@28 sampleCount")

        // The 16-bit word-wise sum of the whole packet must be zero.
        var sum: UInt16 = 0
        for i in stride(from: 0, to: 512, by: 2) { sum = sum &+ read16(block, i) }
        XCTAssertEqual(sum, 0)
    }

    func testSamplesPerBlock() {
        XCTAssertEqual(CwaWriter(deviceId: 1, sessionId: 1).samplesPerBlock, 80)
        XCTAssertEqual(CwaWriter(hardware: .ax6, deviceId: 1, sessionId: 1,
                                 config: AccelConfig(rate: .hz100, range: .g8, gyro: .dps2000))
                        .samplesPerBlock, 40)
    }

    // MARK: - Round trip through libomapi's reader

    private func write(_ writer: CwaWriter, blocks: Int, start: OmDateTime) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omgui-cwa-\(UUID().uuidString).cwa")
        try writer.fileData(startTime: start, blockCount: blocks).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    func testReaderParsesAnAX3File() throws {
        let metadata = MetadataTools.create([.init("_s", "STUDY"), .init("_sc", "P 001")])
        let writer = CwaWriter(hardware: .ax3, deviceId: 1234, sessionId: 9,
                               config: AccelConfig(rate: .hz100, range: .g8),
                               metadata: metadata, battery: 168, light: 300, temperature: 256)
        let start = OmDateTime(year: 2026, month: 9, day: 1, hour: 8, minute: 0, second: 0)
        let reader = try OmReader(path: try write(writer, blocks: 10, start: start))
        defer { reader.close() }

        XCTAssertEqual(reader.deviceId, 1234)
        XCTAssertEqual(reader.sessionId, 9)
        XCTAssertEqual(reader.dataBlockSize, 512)
        XCTAssertEqual(reader.dataOffsetBlocks, 2, "the 1024-byte header is two blocks")
        XCTAssertEqual(reader.dataNumBlocks, 10)
        XCTAssertEqual(reader.metadata, metadata)
        XCTAssertEqual(reader.studyMetadata.studyCode, "STUDY")
        XCTAssertEqual(reader.studyMetadata.subjectCode, "P 001")
        XCTAssertEqual(reader.startTime, start)

        let blocks = reader.readAllBlocks()
        XCTAssertEqual(blocks.count, 10)
        let first = try XCTUnwrap(blocks.first)
        XCTAssertEqual(first.sequenceId, 0)
        XCTAssertEqual(first.sampleCount, 80)
        XCTAssertEqual(first.axes, 3)
        XCTAssertEqual(first.accelScale, 256, "an AX3 is always 256 counts per g")
        XCTAssertEqual(first.light, 300)
        XCTAssertEqual(first.temperatureCelsius, 25.0, accuracy: 0.01)
        // AdcBattToPercentReader(168 + 512 = 680) = (150 * (680 - 538)) >> 8 = 83
        XCTAssertEqual(first.batteryPercent, 83)
        XCTAssertEqual(first.batteryMillivolts, (168 + 512) * 6000 / 1024)
        XCTAssertEqual(first.events, 1, "b0 = resume logging on the first block")
        XCTAssertNil(first.gyro(0))

        // The synthetic waveform: X = sin, Y = cos, Z = 1 g, at 0.25 g amplitude.
        let sample = first.accel(0)
        XCTAssertEqual(sample.x, 0.0, accuracy: 0.01)
        XCTAssertEqual(sample.y, 0.25, accuracy: 0.01)
        XCTAssertEqual(sample.z, 1.0, accuracy: 0.01)

        // Sequence ids are contiguous and timestamps advance.
        XCTAssertEqual(blocks.map(\.sequenceId), Array(0..<10).map(UInt32.init))
        XCTAssertLessThan(first.times[0], try XCTUnwrap(blocks.last).times[0])
    }

    func testReaderParsesAnAX6FileWithGyro() throws {
        let writer = CwaWriter(hardware: .ax6, deviceId: 5678, sessionId: 77,
                               config: AccelConfig(rate: .hz100, range: .g8, gyro: .dps2000))
        let start = OmDateTime(year: 2026, month: 9, day: 1, hour: 8, minute: 0, second: 0)
        let reader = try OmReader(path: try write(writer, blocks: 4, start: start))
        defer { reader.close() }

        let blocks = reader.readAllBlocks()
        XCTAssertEqual(blocks.count, 4)
        let first = try XCTUnwrap(blocks.first)
        XCTAssertEqual(first.axes, 6, "gyro + accel")
        XCTAssertEqual(first.sampleCount, 40, "480 bytes / (6 axes * 2 bytes)")
        XCTAssertEqual(first.accelScale, 4096, "±8 g on an AX6 is 4096 counts per g")
        XCTAssertEqual(first.gyroScale, 2000)
        let gyro = try XCTUnwrap(first.gyro(0))
        XCTAssertEqual(gyro.y, 90.0, accuracy: 1.0)
        let accel = first.accel(0)
        XCTAssertEqual(accel.z, 1.0, accuracy: 0.01)
    }

    func testAccelScaleFollowsTheRangeOnAnAX6() throws {
        let expected: [AccelRange: Int] = [.g16: 2048, .g8: 4096, .g4: 8192, .g2: 16384]
        for (range, scale) in expected {
            let writer = CwaWriter(hardware: .ax6, deviceId: 1, sessionId: 1,
                                   config: AccelConfig(rate: .hz100, range: range, gyro: .dps250))
            let reader = try OmReader(path: try write(writer, blocks: 1,
                                                      start: OmDateTime(year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 0)))
            defer { reader.close() }
            let block = try XCTUnwrap(reader.nextBlock())
            XCTAssertEqual(block.accelScale, scale, "±\(range.rawValue) g")
            XCTAssertEqual(block.gyroScale, 250)
        }
    }

    func testEmptyFileHasNoDataBlocks() throws {
        let writer = CwaWriter(deviceId: 1, sessionId: 1)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omgui-empty-\(UUID().uuidString).cwa")
        try writer.emptyFileData().write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let reader = try OmReader(path: url.path)
        defer { reader.close() }
        XCTAssertEqual(reader.dataNumBlocks, 0)
        XCTAssertNil(reader.nextBlock())
    }

    func testOpeningANonCwaFileThrows() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omgui-bogus-\(UUID().uuidString).cwa")
        try Data(repeating: 0, count: 4096).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try OmReader(path: url.path))
        XCTAssertThrowsError(try OmReader(path: "/no/such/file.cwa"))
    }

    /// The mock device's own `CWA-DATA.CWA` must be readable, since that is what a UI or the
    /// helper tools will open in mock mode.
    func testReaderOnTheMockDeviceDataFile() throws {
        let harness = try MockHarness()
        defer { harness.tearDown() }
        let device = try harness.device(1234)
        device.update(force: true)
        let reader = try OmReader(device: device)
        defer { reader.close() }

        XCTAssertEqual(reader.deviceId, device.deviceId)
        XCTAssertEqual(reader.sessionId, device.sessionId)
        XCTAssertEqual(reader.dataNumBlocks, 24)
        XCTAssertEqual(reader.studyMetadata.studyCode, "STUDY-DEMO")
        XCTAssertEqual(reader.studyMetadata.subjectSite, "left wrist")
        let blocks = reader.readAllBlocks()
        XCTAssertEqual(blocks.count, 24)
        XCTAssertEqual(blocks.first?.batteryPercent, 87, "matches the battery the device reports")
    }

    func testReaderOnAMockAX6WithGyro() throws {
        let harness = try MockHarness(specs: [.ax6WithData(blocks: 6, gyro: .dps500)])
        defer { harness.tearDown() }
        let reader = try OmReader(device: try harness.device(5678))
        defer { reader.close() }
        let block = try XCTUnwrap(reader.nextBlock())
        XCTAssertEqual(block.axes, 6)
        XCTAssertEqual(block.gyroScale, 500)
        XCTAssertEqual(reader.studyMetadata.subjectCode, "P002")
    }
}
