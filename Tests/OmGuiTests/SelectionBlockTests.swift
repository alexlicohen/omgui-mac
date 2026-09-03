import Foundation
import OmApi
import XCTest
@testable import OmGuiCore

/// Turning the data viewer's highlighted time range into `-blockstart`/`-blockcount`.
///
/// The interesting case is a recording that is *not* laid down at a constant rate: a battery gap
/// shifts every block after it, and interpolating between the file's first and last block exports a
/// different window than the one the user dragged over (`refs/10-deep-review.md` C42).
final class SelectionBlockTests: XCTestCase {

    private let start = OmDateTime(year: 2026, month: 9, day: 1, hour: 8, minute: 0, second: 0)
    private var startSeconds: Double { OmReader.epochSeconds(start.raw) }

    private func date(_ offset: Double) -> Date {
        Date(timeIntervalSince1970: startSeconds + offset)
    }

    func testTheBlockRangeFollowsTheBlocksOwnTimestampsAcrossAGap() throws {
        // 100 blocks of 0.8 s, with an hour of nothing after block 49: the second half of the
        // recording sits at 3 640 s … 3 680 s, not at 40 s … 80 s.
        let fixture = SyntheticCwa.write(blocks: 100, start: start,
                                         gapAfterBlock: 49, gapSeconds: 3_600) { k in
            SyntheticCwa.BlockValues(x: Int16(k), z: Int16(256))
        }
        let url = fixture.url
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let reader = try OmReader(path: url.path)
        let offset = reader.dataOffsetBlocks
        XCTAssertEqual(reader.dataNumBlocks, 100)
        reader.close()

        // The three blocks that start at 3 640 s, 3 640.8 s and 3 641.6 s are 50, 51 and 52.
        let selection = try XCTUnwrap(DataSelection.blocks(for: date(3_640)...date(3_642.4),
                                                           path: url.path))
        XCTAssertEqual(selection.start, Double(50 + offset), accuracy: 0.01,
                       "the first block after the gap, not the linear estimate")
        XCTAssertEqual(selection.count, 3, accuracy: 0.02)

        // What the constant-rate estimate would have said, for the record: the same instant is
        // 99 % of the way through the file's advertised span, so it lands near the last block.
        let estimate = try XCTUnwrap(DataSelection.blocks(for: date(3_640)...date(3_642.4),
                                                          start: date(0),
                                                          end: date(3_680),
                                                          offsetBlocks: offset,
                                                          numBlocks: 100))
        XCTAssertGreaterThan(estimate.start - selection.start, 40,
                             "the estimate is forty blocks out on this file")
    }

    func testAnEdgeInsideABlockIsAFractionOfThatBlock() throws {
        let fixture = SyntheticCwa.write(blocks: 40, start: start) { k in
            SyntheticCwa.BlockValues(x: Int16(k), z: Int16(256))
        }
        let url = fixture.url
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let reader = try OmReader(path: url.path)
        let offset = reader.dataOffsetBlocks
        reader.close()

        // Block 10 spans 8.0 s … 8.8 s; a selection starting a quarter of the way into it.
        let blocks = try XCTUnwrap(DataSelection.blocks(for: date(8.2)...date(12.0),
                                                        path: url.path))
        XCTAssertEqual(blocks.start, Double(10 + offset) + 0.25, accuracy: 0.02)
        XCTAssertEqual(blocks.count, 4.75, accuracy: 0.02, "up to the start of block 15")
    }

    func testASelectionOutsideTheFileClampsToTheWholeFile() throws {
        let fixture = SyntheticCwa.write(blocks: 40, start: start) { _ in
            SyntheticCwa.BlockValues(z: Int16(256))
        }
        let url = fixture.url
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let reader = try OmReader(path: url.path)
        let offset = reader.dataOffsetBlocks
        reader.close()

        let blocks = try XCTUnwrap(DataSelection.blocks(for: date(-500)...date(500),
                                                        path: url.path))
        XCTAssertEqual(blocks.start, Double(offset), accuracy: 1e-9)
        XCTAssertEqual(blocks.count, 40, accuracy: 1e-9)

        // A range entirely before the data has no blocks in it.
        XCTAssertNil(DataSelection.blocks(for: date(-500)...date(-400), path: url.path))
    }

    /// Every edge is resolved by bisection, so a long file costs a handful of block reads, not a
    /// scan — the export dialog opens on the main thread.
    func testResolvingAnEdgeIsLogarithmic() throws {
        let fixture = SyntheticCwa.write(blocks: 20_000, start: start) { k in
            SyntheticCwa.BlockValues(x: Int16(k % 128), z: Int16(256))
        }
        let url = fixture.url
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let began = Date()
        let blocks = try XCTUnwrap(DataSelection.blocks(for: date(8_000)...date(8_800),
                                                        path: url.path))
        let elapsed = -began.timeIntervalSinceNow
        XCTAssertEqual(blocks.start, Double(10_000 + 2), accuracy: 1, "8 000 s in at 0.8 s a block")
        XCTAssertEqual(blocks.count, 1_000, accuracy: 1)
        print("PERF: selection edges over a 20 000-block file in "
              + String(format: "%.1f ms", elapsed * 1000))
        XCTAssertLessThan(elapsed, 1.0)
    }

    /// The label above the block boxes reads on the same clock the plot draws (C21).
    func testTheSelectionDescriptionIsOnTheDevicesClock() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        let from = date(0)
        let to = date(3_600)

        XCTAssertEqual(DataSelection.description(for: from...to),
                       "01/09/2026 08:00:00 - 01/09/2026 09:00:00",
                       "the times the device stamped, not the reader's own zone")
        XCTAssertEqual(DataSelection.description(for: from...to),
                       formatter.string(from: from) + " - " + formatter.string(from: to))
    }

    /// The same instant, in the format plugins are handed (C21).
    func testThePluginSelectionTimesAreOnTheDevicesClock() {
        XCTAssertEqual(PluginSelection.timeString(date(0)), "01/09/2026/_08:00:00")
        XCTAssertEqual(PluginSelection.timeString(date(3_600)), "01/09/2026/_09:00:00")
    }
}
