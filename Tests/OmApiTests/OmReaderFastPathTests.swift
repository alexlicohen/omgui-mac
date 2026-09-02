import XCTest
@testable import OmApi

/// The header-only / zero-copy reads the data viewer builds its level-of-detail pyramid from.
/// Each one has to agree, value for value, with the `nextBlock()` path it short-cuts.
final class OmReaderFastPathTests: XCTestCase {

    private func write(_ writer: CwaWriter, blocks: Int, start: OmDateTime) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omgui-fast-\(UUID().uuidString).cwa")
        try writer.fileData(startTime: start, blockCount: blocks).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    private let start = OmDateTime(year: 2026, month: 9, day: 1, hour: 8, minute: 0, second: 0)

    func testSummariesAgreeWithFullBlocks() throws {
        let writer = CwaWriter(hardware: .ax6, deviceId: 5678, sessionId: 77,
                               config: AccelConfig(rate: .hz100, range: .g8, gyro: .dps1000),
                               battery: 168, light: 300, temperature: 256)
        let path = try write(writer, blocks: 12, start: start)

        let full = try OmReader(path: path)
        let blocks = full.readAllBlocks()
        full.close()

        let fast = try OmReader(path: path)
        defer { fast.close() }
        var summaries: [OmReader.BlockSummary] = []
        while let summary = fast.nextSummary() { summaries.append(summary) }

        XCTAssertEqual(summaries.count, blocks.count)
        for (index, (summary, block)) in zip(summaries, blocks).enumerated() {
            XCTAssertEqual(summary.index, index, "block index")
            XCTAssertEqual(summary.sequenceId, block.sequenceId)
            XCTAssertEqual(summary.sampleCount, block.sampleCount)
            XCTAssertEqual(summary.axes, block.axes)
            XCTAssertEqual(summary.accelScale, block.accelScale)
            XCTAssertEqual(summary.gyroScale, block.gyroScale)
            XCTAssertEqual(summary.light, block.light)
            XCTAssertEqual(summary.temperatureMilliCentigrade, block.temperatureMilliCentigrade)
            XCTAssertEqual(summary.batteryMillivolts, block.batteryMillivolts)
            XCTAssertEqual(summary.batteryPercent, block.batteryPercent)
            XCTAssertEqual(summary.events, block.events)

            // The two timestamps the summary keeps, against the per-sample times `nextBlock` builds.
            XCTAssertEqual(summary.start, block.times[0].timeIntervalSince1970, accuracy: 1e-9)
            XCTAssertEqual(summary.time(ofSample: block.sampleCount - 1),
                           block.times[block.sampleCount - 1].timeIntervalSince1970,
                           accuracy: 1.0 / 65536,
                           "interpolating the ends reproduces OmReaderTimestamp()")
            XCTAssertEqual(summary.interval, 0.01, accuracy: 1e-4, "100 Hz")
        }
    }

    func testEverySampleTimeMatchesTheCReaderWithinOneTick() throws {
        let writer = CwaWriter(deviceId: 1234, sessionId: 1, config: AccelConfig(rate: .hz50, range: .g8))
        let path = try write(writer, blocks: 6, start: start)
        let full = try OmReader(path: path)
        let blocks = full.readAllBlocks()
        full.close()

        let fast = try OmReader(path: path)
        defer { fast.close() }
        for block in blocks {
            let summary = try XCTUnwrap(fast.nextSummary())
            for i in 0..<block.sampleCount {
                XCTAssertEqual(summary.time(ofSample: i),
                               block.times[i].timeIntervalSince1970,
                               accuracy: 1.0 / 65536,
                               "sample \(i)")
            }
        }
    }

    func testWithNextBlockHandsOutTheDecodedBufferWithoutCopying() throws {
        let writer = CwaWriter(hardware: .ax6, deviceId: 5678, sessionId: 77,
                               config: AccelConfig(rate: .hz100, range: .g8, gyro: .dps2000))
        let path = try write(writer, blocks: 4, start: start)

        let full = try OmReader(path: path)
        let blocks = full.readAllBlocks()
        full.close()

        let fast = try OmReader(path: path)
        defer { fast.close() }
        for block in blocks {
            let copied = fast.withNextBlock { summary, buffer -> [Int16] in
                XCTAssertEqual(buffer.count, summary.sampleCount * summary.axes)
                XCTAssertEqual(summary.accelOffset, 3, "the gyro triple leads on an AX6")
                return Array(buffer)
            }
            XCTAssertEqual(copied, block.raw)
        }
        XCTAssertNil(fast.withNextBlock { _, _ in true }, "nil at end of file")
    }

    func testSeekingToABlockRange() throws {
        let writer = CwaWriter(deviceId: 1234, sessionId: 1, config: AccelConfig(rate: .hz100, range: .g8))
        let path = try write(writer, blocks: 50, start: start)
        let reader = try OmReader(path: path)
        defer { reader.close() }

        let summaries = reader.summaries(fromBlock: 20, count: 5)
        XCTAssertEqual(summaries.map(\.index), [20, 21, 22, 23, 24])
        XCTAssertEqual(summaries.map(\.sequenceId), [20, 21, 22, 23, 24])

        // Seeking back gives the same block again, byte for byte.
        let again = reader.summaries(fromBlock: 20, count: 1)
        XCTAssertEqual(again.first?.start, summaries.first?.start)
        XCTAssertTrue(reader.summaries(fromBlock: 999, count: 4).isEmpty, "past the end of the file")
    }

    func testTheSampleRateByteIsDecoded() throws {
        for rate in [SampleRate.hz100, .hz50, .hz800, .hz12_5] {
            let writer = CwaWriter(deviceId: 1, sessionId: 1, config: AccelConfig(rate: rate, range: .g8))
            let reader = try OmReader(path: try write(writer, blocks: 2, start: start))
            defer { reader.close() }
            let summary = try XCTUnwrap(reader.nextSummary())
            XCTAssertEqual(summary.sampleRate, rate.hz, "\(rate)")
            XCTAssertEqual(summary.accelRangeG, 8)
            // libomapi times blocks with the *integer* rate, so 12.5 Hz data is timed at 12 Hz —
            // its own TODO, and what OMGUI plots.
            XCTAssertEqual(summary.interval, 1 / Double(summary.readerSampleRate), accuracy: 1e-4,
                           "\(rate)")
        }
        XCTAssertEqual(SampleRate.hz12_5.hz, 12.5)
    }

    func testTheReaderRateIsTheIntegerOneLibomapiTimesWith() throws {
        for (rate, reader) in [(SampleRate.hz100, 100), (.hz25, 25), (.hz12_5, 12), (.hz6_25, 6)] {
            let writer = CwaWriter(deviceId: 1, sessionId: 1, config: AccelConfig(rate: rate, range: .g8))
            let handle = try OmReader(path: try write(writer, blocks: 2, start: start))
            defer { handle.close() }
            let summary = try XCTUnwrap(handle.nextSummary())
            XCTAssertEqual(summary.readerSampleRate, reader, "\(rate)")
        }
    }

    // MARK: - The date conversion the fast paths depend on

    func testCivilDaysMatchesCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        XCTAssertEqual(OmReader.daysFromCivil(year: 1970, month: 1, day: 1), 0)
        XCTAssertEqual(OmReader.daysFromCivil(year: 2000, month: 1, day: 1), 10_957)
        XCTAssertEqual(OmReader.daysFromCivil(year: 2000, month: 2, day: 29), 11_016, "a leap day")

        // Every date `OM_DATETIME` can hold, sampled across the range, must match `Foundation`.
        for year in stride(from: 2000, through: 2063, by: 1) {
            for month in [1, 2, 3, 6, 9, 12] {
                for day in [1, 15, 28] {
                    for (hour, minute, second) in [(0, 0, 0), (13, 45, 59), (23, 59, 59)] {
                        let packed = OmDateTime(year: year, month: month, day: day,
                                                hour: hour, minute: minute, second: second)
                        let expected = packed.date(in: .gmt)?.timeIntervalSince1970
                        XCTAssertEqual(OmReader.epochSeconds(packed.raw), expected ?? -1,
                                       "\(year)-\(month)-\(day) \(hour):\(minute):\(second)")
                    }
                }
            }
        }
    }

    func testFractionalSecondsAndSentinels() {
        let packed = OmDateTime(year: 2026, month: 9, day: 1, hour: 8, minute: 0, second: 0)
        let base = OmReader.epochSeconds(packed.raw, 0)
        XCTAssertEqual(OmReader.epochSeconds(packed.raw, 32_768) - base, 0.5, accuracy: 1e-9)
        XCTAssertEqual(OmReader.epochSeconds(packed.raw, 65_535) - base, 65_535.0 / 65_536, accuracy: 1e-9)
        XCTAssertEqual(OmReader.epochSeconds(OmDateTime.zero.raw), 0, "the 'never' sentinel")
        XCTAssertEqual(OmReader.epochSeconds(OmDateTime.infinite.raw), 0, "the 'always' sentinel")
    }
}
