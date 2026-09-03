import Combine
import Foundation
import OmApi
import XCTest
@testable import OmGuiCore

/// The detail window a deep zoom reads back off disk, checked against ground truth.
///
/// The pyramid's own envelopes are ground-truthed in `DataViewerLODTests`, but the
/// `restrictToBounds: true` path is unique to the detail window and was only ever checked against
/// itself — an off-by-one, a wrong `accelScale` or a whole-window shift would have passed
/// (`refs/10-deep-review.md` C34). Here block `k` carries `x = k`, so every 50 ms column has a
/// value that says exactly which block it came from.
@MainActor
final class DataViewerDetailTests: XCTestCase {

    private let start = OmDateTime(year: 2026, month: 9, day: 1, hour: 8, minute: 0, second: 0)
    private var startSeconds: Double { OmReader.epochSeconds(start.raw) }
    private var cancellables: Set<AnyCancellable> = []

    private func load(_ url: URL, timeout: TimeInterval = 120) -> DataViewerModel {
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let model = DataViewerModel()
        let done = expectation(description: "load \(url.lastPathComponent)")
        model.$state
            .sink { state in
                if case .ready = state { done.fulfill() }
                if case .failed = state { done.fulfill() }
            }
            .store(in: &cancellables)
        model.open(path: url.path)
        wait(for: [done], timeout: timeout)
        return model
    }

    func testTheDetailWindowsEnvelopesAreTheBlocksTheyCover() throws {
        // Half an hour of 100 Hz data: 2 250 blocks of 0.8 s, block k holding x = k counts (exact
        // in a Float at 256 counts/g) and z = 1 g.
        let blockDuration = 0.8
        let fixture = SyntheticCwa.write(blocks: 30 * 60 * 100 / 80, start: start) { k in
            SyntheticCwa.BlockValues(x: Int16(k), z: Int16(256))
        }
        let model = load(fixture.url)
        XCTAssertEqual(model.lod?.baseDuration, 1)

        // 20 s across 400 columns is 50 ms a column — twenty times finer than the pyramid holds,
        // so every column is served by the detail window.
        let from = startSeconds + 600
        let window = from...(from + 20)
        let arrived = expectation(description: "detail window")
        model.$revision.dropFirst().sink { _ in
            if model.detail != nil { arrived.fulfill() }
        }
        .store(in: &cancellables)
        model.requestDetail(range: window, columns: 400)
        wait(for: [arrived], timeout: 20)

        let detail = try XCTUnwrap(model.detail)
        XCTAssertEqual(detail.duration, 0.05, accuracy: 1e-9)

        var columns = [ColumnAggregate](repeating: ColumnAggregate(), count: 400)
        model.columns(range: window, into: &columns)
        XCTAssertTrue(columns.allSatisfy(\.present))

        // The block whose samples a time belongs to, from the fixture's own arithmetic.
        func block(at time: Double) -> Int { Int(((time - startSeconds) / blockDuration).rounded(.down)) }

        var interior = 0
        for (index, column) in columns.enumerated() {
            let columnStart = window.lowerBound + Double(index) * detail.duration
            let columnEnd = columnStart + detail.duration
            let label = "column \(index)"

            // The window's grid is the level's grid: no drift, no half-bucket offset.
            XCTAssertEqual(column.startTime, columnStart, accuracy: 1e-6, label)
            XCTAssertEqual(column.endTime, columnEnd, accuracy: 1e-6, label)

            let first = block(at: columnStart)
            let last = block(at: columnEnd - 1e-9)
            // Five samples at 100 Hz, ± the one that straddles a block boundary; a whole-window
            // shift or a mis-read sample count would break this bound long before the envelope.
            XCTAssertGreaterThanOrEqual(column.count, 4, label)
            XCTAssertLessThanOrEqual(column.count, 6, label)

            // Away from a block edge (the file's timestamps land within a tick of the nominal
            // 0.8 s, so a column within one tick of an edge may take either side).
            let edge = min(columnStart - Double(first) * blockDuration - startSeconds,
                           Double(last + 1) * blockDuration + startSeconds - columnEnd)
            guard first == last, edge > 0.005 else { continue }
            interior += 1
            XCTAssertEqual(column.minimum[.x], Float(first) / 256, accuracy: 1e-6, label)
            XCTAssertEqual(column.maximum[.x], Float(first) / 256, accuracy: 1e-6,
                           "\(label): one block's constant value, min == max")
            XCTAssertEqual(column.maximum[.z], 1.0, accuracy: 1e-6, label)
            XCTAssertEqual(column.count, 5, label)
        }
        XCTAssertGreaterThan(interior, 300, "most of the 400 columns sit inside a single block")

        // The window covers exactly the blocks under it: 20 s at block 750 of the file.
        let firstBlock = block(at: window.lowerBound)
        XCTAssertEqual(firstBlock, 750)
        XCTAssertEqual(columns.first?.maximum[.x] ?? 0, Float(firstBlock) / 256, accuracy: 1e-6)
        XCTAssertEqual(columns.last?.maximum[.x] ?? 0,
                       Float(block(at: window.upperBound - detail.duration)) / 256, accuracy: 1e-6)

        // And a mid-window read straight off the detail level agrees with the columns.
        let mid = model.aggregate(from: from + 10, to: from + 10.05)
        XCTAssertEqual(mid.maximum[.x], Float(block(at: from + 10)) / 256, accuracy: 1e-6)
    }
}
