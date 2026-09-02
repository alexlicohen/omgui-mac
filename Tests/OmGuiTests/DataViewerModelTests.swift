import Combine
import Foundation
import OmApi
import XCTest
@testable import OmGuiCore

/// The incremental load: progress while reading, the finished pyramid, the detail window a deep
/// zoom asks for, and how long the whole pass costs on a day of AX6 data.
@MainActor
final class DataViewerModelTests: XCTestCase {

    private let start = OmDateTime(year: 2026, month: 9, day: 1, hour: 8, minute: 0, second: 0)
    private var startSeconds: Double { OmReader.epochSeconds(start.raw) }
    private var cancellables: Set<AnyCancellable> = []

    /// Runs the model's own background load to completion, collecting every state it published.
    private func load(_ url: URL, timeout: TimeInterval = 120) -> (model: DataViewerModel,
                                                                   states: [DataViewerModel.LoadState]) {
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let model = DataViewerModel()
        var states: [DataViewerModel.LoadState] = []
        let done = expectation(description: "load \(url.lastPathComponent)")
        model.$state
            .sink { state in
                states.append(state)
                if case .ready = state { done.fulfill() }
                if case .failed = state { done.fulfill() }
            }
            .store(in: &cancellables)
        model.open(path: url.path)
        wait(for: [done], timeout: timeout)
        return (model, states)
    }

    func testTheLoadReportsProgressAndEndsReady() {
        // Ten minutes of 100 Hz data: 750 blocks, enough for several publishes.
        let fixture = SyntheticCwa.write(blocks: 10 * 60 * 100 / 80, start: start) { k in
            SyntheticCwa.BlockValues(x: Int16(k % 256), z: Int16(256), light: UInt16(k % 1024))
        }
        let (model, states) = load(fixture.url)

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.sampleRate, 100)
        XCTAssertEqual(model.axes, 3)
        XCTAssertFalse(model.hasGyro)

        let progress = states.compactMap(\.progress)
        XCTAssertFalse(progress.isEmpty, "the plot has something to draw while the file loads")
        XCTAssertEqual(progress, progress.sorted(), "progress never goes backwards")
        XCTAssertEqual(progress.last ?? 0, 1, accuracy: 1e-9)

        let lod = try! XCTUnwrap(model.lod)
        XCTAssertEqual(lod.blocksRead, 750)
        XCTAssertEqual(lod.clockAnomalies, 0)
        XCTAssertEqual(lod.bounds.lowerBound, startSeconds, accuracy: 1)
        XCTAssertEqual(lod.bounds.upperBound - lod.bounds.lowerBound, 600, accuracy: 1)
    }

    func testColumnsFillTheWidthOfThePlot() {
        let fixture = SyntheticCwa.write(blocks: 3_750, start: start) { k in
            SyntheticCwa.BlockValues(x: Int16(k % 256), z: Int16(256))
        }
        let (model, _) = load(fixture.url)
        let lod = try! XCTUnwrap(model.lod)

        var columns = [ColumnAggregate](repeating: ColumnAggregate(), count: 800)
        model.columns(range: lod.bounds, into: &columns)
        XCTAssertEqual(columns.count, 800)
        XCTAssertTrue(columns.allSatisfy(\.present), "a continuous recording has no holes")
        XCTAssertTrue(columns.first!.startTime < columns.last!.startTime, "columns advance in time")
        // Every column's envelope sits inside the whole file's envelope.
        let whole = lod.aggregate(from: lod.bounds.lowerBound, to: lod.bounds.upperBound)
        for column in columns {
            XCTAssertGreaterThanOrEqual(column.minimum[.x], whole.minimum[.x])
            XCTAssertLessThanOrEqual(column.maximum[.x], whole.maximum[.x])
        }
    }

    func testADeepZoomReadsADetailWindowBackOffDisk() {
        // Half an hour, so the base bucket is 1 s; then zoom to 20 s across 400 columns, which is
        // 50 ms a column — twenty times finer than the pyramid holds.
        let fixture = SyntheticCwa.write(blocks: 30 * 60 * 100 / 80, start: start) { k in
            SyntheticCwa.BlockValues(x: Int16(k % 97), z: Int16(256))
        }
        let (model, _) = load(fixture.url)
        XCTAssertEqual(model.lod?.baseDuration, 1)
        XCTAssertNil(model.detail)

        let from = startSeconds + 600
        let window = from...(from + 20)
        let arrived = expectation(description: "detail window")
        model.$revision.dropFirst().sink { _ in
            if model.detail != nil { arrived.fulfill() }
        }
        .store(in: &cancellables)
        model.requestDetail(range: window, columns: 400)
        wait(for: [arrived], timeout: 20)

        let detail = try! XCTUnwrap(model.detail)
        XCTAssertEqual(detail.duration, 0.05, accuracy: 1e-9)
        XCTAssertEqual(detail.range.lowerBound, window.lowerBound)

        // Inside the window the plot now resolves single blocks: neighbouring 50 ms columns
        // differ, which they cannot at 1 s buckets.
        var columns = [ColumnAggregate](repeating: ColumnAggregate(), count: 400)
        model.columns(range: window, into: &columns)
        XCTAssertTrue(columns.allSatisfy(\.present))
        // Five samples a bucket, and up to two buckets when a column straddles a bucket edge —
        // an order of magnitude below the hundred samples a 1 s pyramid bucket would have given.
        XCTAssertTrue(columns.allSatisfy { $0.count <= 12 },
                      "counts were \(columns.map(\.count).max() ?? -1)")
        XCTAssertTrue(zip(columns, columns.dropFirst()).contains { $0.maximum[.x] != $1.maximum[.x] },
                      "the detail window shows structure the pyramid smoothed away")

        // Zooming back out drops it.
        model.requestDetail(range: model.lod!.bounds, columns: 400)
        XCTAssertNil(model.detail)
    }

    func testOpeningSomethingThatIsNotACwaFails() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omgui-not-cwa-\(UUID().uuidString).cwa")
        try! Data(repeating: 0, count: 4096).write(to: url)
        let (model, _) = load(url)
        guard case .failed = model.state else {
            return XCTFail("expected a failed state, got \(model.state)")
        }
        XCTAssertNil(model.lod)
    }

    func testClosingCancelsAndClears() {
        let fixture = SyntheticCwa.write(blocks: 200, start: start) { _ in
            SyntheticCwa.BlockValues(z: Int16(256))
        }
        let (model, _) = load(fixture.url)
        XCTAssertNotNil(model.lod)
        model.close()
        XCTAssertNil(model.lod)
        XCTAssertNil(model.path)
        XCTAssertEqual(model.state, .empty)

        var columns = [ColumnAggregate](repeating: ColumnAggregate(), count: 8)
        model.columns(range: 0...1, into: &columns)
        XCTAssertTrue(columns.allSatisfy { !$0.present }, "a closed viewer draws nothing")
    }

    // MARK: - Cost

    /// A day of AX6 data — 216 000 blocks, 105 MB — must build in one pass, well inside the time a
    /// person would tolerate. Release builds measure ~0.6 s; the bound here is for a debug build
    /// on a loaded machine.
    func testBuildingADayOfAX6DataIsFast() throws {
        let config = AccelConfig(rate: .hz100, range: .g8, gyro: .dps2000)
        let blocks = 216_000
        let writer = CwaWriter(hardware: .ax6, deviceId: 5678, sessionId: 77, config: config,
                               battery: 168, light: 300, temperature: 256)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omgui-lod-perf-\(UUID().uuidString).cwa")
        try writer.fileData(startTime: start, blockCount: blocks).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let reader = try OmReader(path: url.path)
        let lod = DataViewerLOD(start: OmReader.epochSeconds(reader.startTime.raw),
                                end: OmReader.epochSeconds(reader.endTime.raw))
        let began = Date()
        var read = 0
        while true {
            let batch = lod.ingestBatch { ingestor -> Int in
                var count = 0
                while count < 256 {
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
            read += abs(batch)
            if batch <= 0 { break }
        }
        let elapsed = -began.timeIntervalSinceNow
        reader.close()

        XCTAssertEqual(read, blocks)
        XCTAssertEqual(lod.baseDuration, 1, "a day buckets at one second")
        XCTAssertTrue(lod.hasGyro)
        XCTAssertLessThan(lod.byteCount, 12 * 1024 * 1024, "the pyramid for a 105 MB file")
        XCTAssertLessThan(elapsed, 60, "one pass over a day of AX6 data took \(elapsed) s")
        print("PERF: \(blocks) blocks (105 MB) folded in \(String(format: "%.2f", elapsed)) s, "
              + "\(lod.byteCount / 1024) KB of buckets")

        // And a redraw off the finished pyramid is nowhere near a frame.
        var columns = [ColumnAggregate](repeating: ColumnAggregate(), count: 2_000)
        let drawBegan = Date()
        for _ in 0..<20 { lod.columns(range: lod.bounds, into: &columns) }
        let perFrame = -drawBegan.timeIntervalSinceNow / 20
        print("PERF: 2000 columns over the whole day in \(String(format: "%.2f", perFrame * 1000)) ms")
        XCTAssertLessThan(perFrame, 0.05, "a full-extent redraw is nowhere near a second")
    }
}
