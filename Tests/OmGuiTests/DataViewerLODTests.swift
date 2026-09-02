import Foundation
import OmApi
import XCTest
@testable import OmGuiCore

/// The level-of-detail pyramid the preview renders from: envelope correctness against a fixture
/// whose per-block values are known, level selection, gaps, and the cost of building one.
final class DataViewerLODTests: XCTestCase {

    private let start = OmDateTime(year: 2026, month: 9, day: 1, hour: 8, minute: 0, second: 0)
    private var startSeconds: Double { OmReader.epochSeconds(start.raw) }

    /// Drives the same sequential pass the model's loader runs, synchronously.
    @discardableResult
    private func build(_ path: String, lod: DataViewerLOD) -> Int {
        guard let reader = try? OmReader(path: path) else { return 0 }
        defer { reader.close() }
        var blocks = 0
        while true {
            let batch = lod.ingestBatch { ingestor -> Int in
                var count = 0
                while count < 64 {
                    let more = reader.withNextBlock { summary, samples -> Bool in
                        ingestor.add(summary, samples: samples)
                        return true
                    }
                    if more == nil { return -count }
                    count += 1
                }
                return count
            }
            lod.finishBatch()
            blocks += abs(batch)
            if batch <= 0 { break }
        }
        return blocks
    }

    private func open(_ url: URL) -> (lod: DataViewerLOD, blocks: Int) {
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let reader = try! OmReader(path: url.path)
        let lodStart = OmReader.epochSeconds(reader.startTime.raw)
        let lodEnd = OmReader.epochSeconds(reader.endTime.raw)
        reader.close()
        let lod = DataViewerLOD(start: lodStart, end: lodEnd)
        return (lod, build(url.path, lod: lod))
    }

    // MARK: - Envelopes

    func testBucketEnvelopesMatchTheBlocksThatOverlapThem() {
        // Block k holds x = k, y = -k, z = 100 + k in raw counts (an AX3 is 256 counts per g, so
        // every value is exact in a Float), for 40 blocks of 0.8 s = 32 s of "recording".
        let blocks = 40
        let fixture = SyntheticCwa.write(blocks: blocks, start: start) { k in
            SyntheticCwa.BlockValues(x: Int16(k), y: Int16(-k), z: Int16(100 + k),
                                     light: UInt16(100 + k), temperature: UInt16(200 + k),
                                     battery: UInt8(150 + k))
        }
        let (lod, read) = open(fixture.url)
        XCTAssertEqual(read, blocks)
        XCTAssertEqual(lod.baseDuration, 1, "32 s of data buckets at 1 s")

        // No sample is lost or counted twice when a block is split across buckets.
        var total = 0
        for bucket in 0..<40 {
            total += lod.aggregate(from: startSeconds + Double(bucket),
                                   to: startSeconds + Double(bucket) + 1).count
        }
        XCTAssertEqual(total, blocks * 80, "every sample lands in exactly one bucket")

        for bucket in 0..<32 {
            let from = startSeconds + Double(bucket)
            let to = from + 1
            // Every block whose span genuinely overlaps this bucket.
            let overlapping = (0..<blocks).filter { k in
                let blockFrom = fixture.blockStart(k)
                let blockTo = blockFrom + fixture.blockDuration
                return min(blockTo, Double(bucket + 1)) - max(blockFrom, Double(bucket)) > 1e-6
            }
            XCTAssertFalse(overlapping.isEmpty)

            let column = lod.aggregate(from: from, to: to)
            XCTAssertTrue(column.present, "bucket \(bucket)")
            XCTAssertEqual(column.minimum[.x], Float(overlapping.min()!) / 256, accuracy: 1e-6,
                           "bucket \(bucket) min X")
            XCTAssertEqual(column.maximum[.x], Float(overlapping.max()!) / 256, accuracy: 1e-6,
                           "bucket \(bucket) max X")
            XCTAssertEqual(column.minimum[.y], -Float(overlapping.max()!) / 256, accuracy: 1e-6)
            XCTAssertEqual(column.maximum[.z], Float(100 + overlapping.max()!) / 256, accuracy: 1e-6)
            XCTAssertEqual(column.minimum[.light], Float(100 + overlapping.min()!))
            XCTAssertEqual(column.maximum[.light], Float(100 + overlapping.max()!))
            XCTAssertEqual(column.minimum[.temperature],
                           Float(SyntheticCwa.milliCentigrade(UInt16(200 + overlapping.min()!))) / 1000,
                           accuracy: 1e-3)
            XCTAssertEqual(column.maximum[.batteryMillivolts],
                           Float(SyntheticCwa.millivolts(UInt8(150 + overlapping.max()!))))
            // 100 Hz over a 1 s bucket, ± the one sample that straddles the boundary: libomapi
            // keeps block times in 1/65536 s ticks, so 0.8 s lands at 0.79998, and the sample at
            // the boundary falls to whichever side the file's own timestamps put it.
            XCTAssertTrue((99...101).contains(column.count), "bucket \(bucket) count \(column.count)")
        }
    }

    func testCoarseLevelsAgreeWithTheBaseLevel() {
        // 90 minutes, so the pyramid has 1 s / 10 s / 1 min levels.
        let blocks = 90 * 60 * 100 / 80
        let fixture = SyntheticCwa.write(blocks: blocks, start: start) { k in
            SyntheticCwa.BlockValues(x: Int16(k % 512), z: Int16(256))
        }
        let (lod, _) = open(fixture.url)
        XCTAssertEqual(lod.levelDurations, [1, 10, 60, 600])

        // A coarse read and a fine read of the same window must give the same envelope.
        for window in [60.0, 600.0, 1800.0] {
            let from = startSeconds + 1200
            let coarse = lod.aggregate(from: from, to: from + window)
            var fine = ColumnAggregate()
            for second in stride(from: 0.0, to: window, by: 1.0) {
                fine.merge(lod.aggregate(from: from + second, to: from + second + 1))
            }
            XCTAssertEqual(coarse.minimum[.x], fine.minimum[.x], accuracy: 1e-6, "\(window) s window")
            XCTAssertEqual(coarse.maximum[.x], fine.maximum[.x], accuracy: 1e-6, "\(window) s window")
            XCTAssertEqual(coarse.count, fine.count, "\(window) s window")
        }
    }

    func testMissingDataLeavesEmptyBuckets() {
        // 20 blocks, a 10 s hole, then 20 more: the hole must read as absent, not as zeroes.
        let fixture = SyntheticCwa.write(blocks: 40, start: start,
                                         gapAfterBlock: 19, gapSeconds: 10) { k in
            SyntheticCwa.BlockValues(x: Int16(k), z: Int16(256))
        }
        let (lod, read) = open(fixture.url)
        XCTAssertEqual(read, 40)

        let hole = startSeconds + 17          // inside 16 s … 26 s
        XCTAssertFalse(lod.aggregate(from: hole, to: hole + 1).present, "the gap is missing data")
        XCTAssertTrue(lod.aggregate(from: startSeconds + 5, to: startSeconds + 6).present)
        XCTAssertTrue(lod.aggregate(from: startSeconds + 30, to: startSeconds + 31).present)

        var columns = [ColumnAggregate](repeating: ColumnAggregate(), count: 42)
        lod.columns(range: startSeconds...(startSeconds + 42), into: &columns)
        let absent = columns.filter { !$0.present }.count
        XCTAssertGreaterThanOrEqual(absent, 8, "roughly the 10 s hole, one column a second")
        XCTAssertLessThanOrEqual(absent, 12)
    }

    func testGyroChannelsAreScaledToDegreesPerSecond() {
        let config = AccelConfig(rate: .hz100, range: .g8, gyro: .dps2000)
        let fixture = SyntheticCwa.write(blocks: 20, hardware: .ax6, config: config, start: start) { _ in
            SyntheticCwa.BlockValues(x: 0, y: 0, z: 4096, gyroX: 16384, gyroY: -16384, gyroZ: 0)
        }
        let (lod, _) = open(fixture.url)
        XCTAssertTrue(lod.hasGyro)
        let column = lod.aggregate(from: startSeconds, to: startSeconds + 4)
        XCTAssertEqual(column.maximum[.gyroX], 1000, accuracy: 0.5, "16384/32768 of 2000 dps")
        XCTAssertEqual(column.minimum[.gyroY], -1000, accuracy: 0.5)
        XCTAssertEqual(column.maximum[.z], 1.0, accuracy: 1e-6, "±8 g on an AX6 is 4096 counts/g")
    }

    // MARK: - Level selection

    func testResolutionFollowsTheZoom() {
        let blocks = 6 * 3600 * 100 / 80          // six hours
        let fixture = SyntheticCwa.write(blocks: blocks, start: start) { k in
            SyntheticCwa.BlockValues(x: Int16(k % 256), z: Int16(256))
        }
        let (lod, _) = open(fixture.url)
        XCTAssertEqual(lod.levelDurations, [1, 10, 60, 600, 3600])

        XCTAssertEqual(lod.resolution(forSpan: 6 * 3600, columns: 600), 10, "6 h across 600 px")
        XCTAssertEqual(lod.resolution(forSpan: 3600, columns: 600), 1, "1 h across 600 px")
        XCTAssertEqual(lod.resolution(forSpan: 60, columns: 600), 1, "below the base bucket, clamped")
        XCTAssertEqual(lod.resolution(forSpan: 6 * 3600, columns: 6), 3600)
    }

    func testTheBaseBucketGrowsWithTheRecordingSoMemoryStaysBounded() {
        let day = 86_400.0
        XCTAssertEqual(DataViewerLOD(start: 0, end: day).baseDuration, 1)
        XCTAssertEqual(DataViewerLOD(start: 0, end: 7 * day).baseDuration, 5)
        XCTAssertEqual(DataViewerLOD(start: 0, end: 30 * day).baseDuration, 10)
        XCTAssertEqual(DataViewerLOD(start: 0, end: 365 * day).baseDuration, 300)

        // A week never costs more than a day: same bucket budget, coarser buckets.
        let week = DataViewerLOD(start: 0, end: 7 * day)
        XCTAssertLessThan(week.byteCount, 16 * 1024 * 1024)
        XCTAssertLessThan(DataViewerLOD(start: 0, end: 365 * day).byteCount, 32 * 1024 * 1024)
    }
}
