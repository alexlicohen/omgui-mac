import Foundation
import OmApi
import XCTest
@testable import OmGuiCore

/// What the pyramid does with a device whose clock is wrong: a block stamped before the file's own
/// start, one stamped a little past its end, and one stamped decades away.
///
/// These are the only paths in `DataLevel` that were never entered by a fixture
/// (`refs/10-deep-review.md` U5/C18): `grow` and the sub-zero fold were asserted only as
/// "clockAnomalies == 0" on a well-formed file.
final class DataViewerClockTests: XCTestCase {

    private let start = OmDateTime(year: 2026, month: 9, day: 1, hour: 8, minute: 0, second: 0)
    private var startSeconds: Double { OmReader.epochSeconds(start.raw) }

    /// The sequential pass the model's loader runs, synchronously.
    @discardableResult
    private func build(_ url: URL, lod: DataViewerLOD) -> Int {
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        guard let reader = try? OmReader(path: url.path) else { return 0 }
        defer { reader.close() }
        var blocks = 0
        var done = false
        while !done {
            let batch = lod.ingestBatch { ingestor -> Int in
                var count = 0
                while count < 64 {
                    let more = reader.withNextBlock { summary, samples -> Bool in
                        ingestor.add(summary, samples: samples)
                        return true
                    }
                    if more == nil { done = true; return count }
                    count += 1
                }
                return count
            }
            lod.finishBatch()
            blocks += batch
        }
        return blocks
    }

    /// Samples the whole extent holds, one base bucket at a time.
    private func totalCount(_ lod: DataViewerLOD, from: Double, to: Double) -> Int {
        var total = 0
        var time = from
        while time < to {
            total += lod.aggregate(from: time, to: time + lod.baseDuration).count
            time += lod.baseDuration
        }
        return total
    }

    // MARK: - A clock that jumped decades (C18)

    func testABlockStampedDecadesAheadIsAnAnomalyNotAnAllocation() {
        // 40 blocks of 0.8 s = 32 s of recording, with the RTC jumping thirty years forward after
        // block 29. At a 1 s base bucket the jumped blocks ask for bucket ~9.5e8, which is 47 GB of
        // Float pairs: `grow` has to refuse rather than size the level to the clock error.
        let thirtyYears = 30.0 * 365.25 * 86_400
        let fixture = SyntheticCwa.write(blocks: 40, start: start,
                                         clockJumpAfterBlock: 29, jumpSeconds: thirtyYears) { k in
            SyntheticCwa.BlockValues(x: Int16(k), z: Int16(256))
        }
        // The span the file's header advertises, which is what `DataViewerModel` builds from.
        let lod = DataViewerLOD(start: startSeconds, end: startSeconds + 32, maximumBaseBuckets: 32_768)
        XCTAssertEqual(build(fixture.url, lod: lod), 40)

        XCTAssertEqual(lod.clockAnomalies, 10, "blocks 30...39 carry the jumped RTC")
        XCTAssertLessThan(lod.byteCount, 100 * 1024,
                          "the pyramid stays the size of the file's own span, not of the clock error")
        XCTAssertEqual(lod.bounds.upperBound, startSeconds + 32, accuracy: 1e-6,
                       "a refused block must not stretch the plot's axis either")

        // The 24 s the good blocks cover is still exact.
        XCTAssertEqual(totalCount(lod, from: startSeconds, to: startSeconds + 32), 30 * 80)
        let whole = lod.aggregate(from: startSeconds, to: startSeconds + 32)
        XCTAssertEqual(whole.minimum[.x], 0, accuracy: 1e-6)
        XCTAssertEqual(whole.maximum[.x], Float(29) / 256, accuracy: 1e-6,
                       "block 29 is the last one on the file's own timeline")
    }

    // MARK: - A clock that jumped forward inside the budget (U5)

    func testAForwardJumpInsideTheBudgetGrowsTheLevel() {
        // Ten minutes forward after block 19: past the 32 s the header advertises, but nowhere near
        // the bucket budget, so the level grows and the data is kept.
        let fixture = SyntheticCwa.write(blocks: 40, start: start,
                                         clockJumpAfterBlock: 19, jumpSeconds: 600) { k in
            SyntheticCwa.BlockValues(x: Int16(k), z: Int16(256))
        }
        let lod = DataViewerLOD(start: startSeconds, end: startSeconds + 32, maximumBaseBuckets: 32_768)
        XCTAssertEqual(build(fixture.url, lod: lod), 40)

        XCTAssertEqual(lod.clockAnomalies, 0, "a forward jump inside the budget is not an anomaly")
        XCTAssertEqual(lod.bounds.upperBound, startSeconds + 632, accuracy: 0.05,
                       "the extent follows the last block that actually landed")

        // Every sample is still accounted for: `mins`/`maxs` grow by extra * DataSeries.count while
        // `counts` grows by `extra`, and a mis-sized grow would lose or duplicate samples here.
        XCTAssertEqual(totalCount(lod, from: startSeconds, to: startSeconds + 633), 40 * 80)

        // And the envelopes on the far side of the jump are the grown buckets', not garbage.
        let after = lod.aggregate(from: startSeconds + 616, to: startSeconds + 633)
        XCTAssertTrue(after.present)
        XCTAssertEqual(after.count, 20 * 80, "blocks 20...39 landed after the jump")
        XCTAssertEqual(after.minimum[.x], Float(20) / 256, accuracy: 1e-6)
        XCTAssertEqual(after.maximum[.x], Float(39) / 256, accuracy: 1e-6)
        XCTAssertEqual(after.maximum[.z], 1.0, accuracy: 1e-6)

        // The hole between the two halves reads as missing data, not as zeroes.
        XCTAssertFalse(lod.aggregate(from: startSeconds + 300, to: startSeconds + 301).present)
    }

    // MARK: - A clock that went backwards (U5)

    func testANegativeJumpIsAbsorbedIntoTheFirstBucket() {
        // An hour backwards after block 19: every later block is stamped before the file's own
        // start, which `DataLevel.add` folds into bucket 0 and counts as an anomaly.
        let fixture = SyntheticCwa.write(blocks: 40, start: start,
                                         clockJumpAfterBlock: 19, jumpSeconds: -3600) { k in
            SyntheticCwa.BlockValues(x: Int16(k), z: Int16(256))
        }
        let lod = DataViewerLOD(start: startSeconds, end: startSeconds + 32, maximumBaseBuckets: 32_768)
        XCTAssertEqual(build(fixture.url, lod: lod), 40)

        XCTAssertEqual(lod.clockAnomalies, 20, "blocks 20...39 are stamped before the file starts")
        XCTAssertEqual(lod.bounds.upperBound, startSeconds + 32, accuracy: 1e-6)

        // Nothing is dropped: the first bucket carries its own block plus all twenty jumped ones.
        XCTAssertEqual(totalCount(lod, from: startSeconds, to: startSeconds + 32), 40 * 80)
        let first = lod.aggregate(from: startSeconds, to: startSeconds + 1)
        XCTAssertGreaterThanOrEqual(first.count, 20 * 80)
        XCTAssertEqual(first.maximum[.x], Float(39) / 256, accuracy: 1e-6,
                       "the jumped blocks' envelope is folded into the first bucket")
    }

    // MARK: - The pyramid's own ceiling

    func testGrowIsBoundedByTheBucketBudget() {
        // The level may grow, but only up to the budget the ladder was chosen against.
        let level = DataLevel(start: 0, duration: 1, bucketCount: 10, bucketLimit: 100)
        XCTAssertTrue(level.grow(toBucket: 40))
        XCTAssertGreaterThan(level.bucketCount, 40)
        XCTAssertLessThanOrEqual(level.bucketCount, 100)
        XCTAssertFalse(level.grow(toBucket: 100), "the limit itself is out of range")
        XCTAssertFalse(level.grow(toBucket: 1_000_000))
        XCTAssertTrue(level.grow(toBucket: 99))
        XCTAssertEqual(level.bucketCount, 100)
        XCTAssertEqual(level.counts.count, level.bucketCount)
        XCTAssertEqual(level.mins.count, level.bucketCount * DataSeries.count)
        XCTAssertEqual(level.maxs.count, level.bucketCount * DataSeries.count)
    }
}
