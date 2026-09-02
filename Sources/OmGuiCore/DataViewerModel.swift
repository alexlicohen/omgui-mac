import Combine
import Foundation
import OmApi

/// The preview's data source: opens a `.CWA` through `OmReader` on a background queue, folds it
/// into a `DataViewerLOD` as it reads, and hands the plot pixel columns.
///
/// `DataViewer.cs` runs a `BackgroundWorker` that fetches only the blocks landing under pixels, in
/// passes of stride 64, 32, … 1, and refreshes the bitmap every 250 ms. This does the same job the
/// other way round: one sequential pass that folds *every* block into a pyramid, publishing every
/// 100 ms, so the picture fills in left to right and is exact once the pass ends (upstream's
/// picture stays an interpolation of whichever blocks happened to be cached). One pass over a day
/// of AX6 data is ~0.6 s; a 500 MB week is ~3 s, and the plot is live throughout.
@MainActor
public final class DataViewerModel: ObservableObject {

    public enum LoadState: Equatable, Sendable {
        case empty
        case loading(Double)
        case ready
        case failed(String)

        public var progress: Double? {
            if case .loading(let value) = self { return value }
            return nil
        }
    }

    @Published public private(set) var state: LoadState = .empty
    /// Bumped whenever new data lands, so the plot can invalidate itself.
    @Published public private(set) var revision = 0

    public private(set) var lod: DataViewerLOD?
    public private(set) var detail: DataDetailWindow?
    public private(set) var path: String?
    /// Sample rate (Hz) and axis count from the first block, for the read-out.
    public private(set) var sampleRate = 0.0
    public private(set) var axes = 0
    public private(set) var hasGyro = false

    private let loadQueue = DispatchQueue(label: "omgui.dataviewer.load", qos: .userInitiated)
    private let detailQueue = DispatchQueue(label: "omgui.dataviewer.detail", qos: .userInitiated)
    private var generation = 0
    private var currentLoad: CancelFlag?
    private var loadedSize: Int64 = 0
    private var loadedModified: Date?
    private var detailToken = 0

    public init() {}

    /// `DataViewer.Open(filename)` / `Open(deviceId)` — the device case opens the device's
    /// `CWA-DATA.CWA` (upstream calls `OmReaderOpenDeviceData`, which this build of libomapi does
    /// not export; the mounted volume's file is the same bytes).
    public func open(path: String) {
        guard path != self.path else { return }
        close()
        self.path = path
        startLoad()
    }

    /// `DataViewer.Close()`.
    public func close() {
        generation += 1
        currentLoad?.cancel()
        currentLoad = nil
        path = nil
        lod = nil
        detail = nil
        sampleRate = 0
        axes = 0
        hasGyro = false
        loadedSize = 0
        loadedModified = nil
        state = .empty
        revision &+= 1
    }

    /// Re-reads the file if it has grown — a device writes to `CWA-DATA.CWA` while it records, so
    /// a live preview has to notice. Cheap when nothing changed (one `stat`).
    public func refreshIfChanged() {
        guard let path, case .ready = state else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes?[.modificationDate] as? Date
        guard size != loadedSize || modified != loadedModified else { return }
        startLoad()
    }

    private func startLoad() {
        guard let path else { return }
        generation += 1
        let generation = self.generation
        currentLoad?.cancel()
        let flag = CancelFlag()
        currentLoad = flag
        detail = nil
        state = .loading(0)

        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        loadedSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        loadedModified = attributes?[.modificationDate] as? Date

        let publish: @Sendable (LoadEvent) -> Void = { [weak self] event in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.apply(event)
            }
        }
        loadQueue.async { DataViewerModel.load(path: path, flag: flag, publish: publish) }
    }

    private func apply(_ event: LoadEvent) {
        switch event {
        case .opened(let lod, let rate, let axes):
            self.lod = lod
            self.sampleRate = rate
            self.axes = axes
            state = .loading(0)
        case .progress(let value):
            hasGyro = lod?.hasGyro ?? false
            state = .loading(value)
        case .finished:
            hasGyro = lod?.hasGyro ?? false
            state = .ready
        case .failed(let message):
            lod = nil
            state = .failed(message)
        }
        revision &+= 1
    }

    // MARK: - Columns

    /// Fills `output` with one aggregate per pixel column, preferring the detail window.
    public func columns(range: ClosedRange<Double>, into output: inout [ColumnAggregate]) {
        guard let lod else {
            for index in output.indices { output[index] = ColumnAggregate() }
            return
        }
        lod.columns(range: range, into: &output, detail: detail)
    }

    /// One aggregate for the cursor read-out.
    public func aggregate(from: Double, to: Double) -> ColumnAggregate {
        if let detail, from >= detail.range.lowerBound, to <= detail.range.upperBound {
            return detail.level.aggregate(from: from, to: to)
        }
        return lod?.aggregate(from: from, to: to) ?? ColumnAggregate()
    }

    /// Asks for a finer read of `range` when the zoom has gone below the pyramid's base bucket.
    ///
    /// The window is at most `columns` buckets wide and only ever covers what is on screen, so the
    /// read is bounded: at the point this triggers, the visible window is `columns * baseBucket`
    /// seconds — a few thousand blocks, tens of milliseconds.
    public func requestDetail(range: ClosedRange<Double>, columns: Int) {
        guard let lod, let path, columns > 0 else { return }
        let span = range.upperBound - range.lowerBound
        let wanted = span / Double(columns)
        guard wanted < lod.baseDuration else {
            if detail != nil { detail = nil; revision &+= 1 }
            return
        }
        if let detail, detail.range.lowerBound <= range.lowerBound,
           detail.range.upperBound >= range.upperBound,
           detail.duration <= wanted * 1.5, detail.duration >= wanted / 4 {
            return                                    // the window we have is good enough
        }
        detailToken += 1
        let token = detailToken
        let firstBlock = lod.block(before: range.lowerBound)
        let generation = self.generation

        detailQueue.async { [weak self] in
            let window = DataViewerModel.readDetail(path: path,
                                                    firstBlock: firstBlock,
                                                    range: range,
                                                    duration: wanted)
            Task { @MainActor in
                guard let self, self.generation == generation, self.detailToken == token else { return }
                self.detail = window
                self.revision &+= 1
            }
        }
    }

    // MARK: - Background load

    private enum LoadEvent: @unchecked Sendable {
        case opened(DataViewerLOD, rate: Double, axes: Int)
        case progress(Double)
        case finished
        case failed(String)
    }

    /// One sequential pass over the file, folding blocks into the pyramid.
    private nonisolated static func load(path: String,
                                         flag: CancelFlag,
                                         publish: @escaping @Sendable (LoadEvent) -> Void) {
        let reader: OmReader
        do {
            reader = try OmReader(path: path)
        } catch {
            publish(.failed("\(error)"))
            return
        }
        defer { reader.close() }

        // The header's first/last block times, which libomapi derives by reading those blocks.
        var start = reader.startTime.isValid ? OmReader.epochSeconds(reader.startTime.raw, 0) : 0
        var end = reader.endTime.isValid ? OmReader.epochSeconds(reader.endTime.raw, 0) : 0
        guard let first = reader.nextSummary() else {
            publish(.failed("No readable data blocks"))
            return
        }
        if start <= 0 { start = first.start }
        if end <= start {
            end = start + Double(max(reader.dataNumBlocks, 1)) * max(first.end - first.start, 1)
        }
        _ = reader.seek(toBlock: 0)

        let lod = DataViewerLOD(start: start, end: end)
        publish(.opened(lod, rate: first.sampleRate, axes: first.axes))

        let total = max(reader.dataNumBlocks, 1)
        var read = 0
        var lastPublish = Date.distantPast
        var done = false

        while !done, !flag.isCancelled {
            let batch = lod.ingestBatch { ingestor -> (blocks: Int, eof: Bool) in
                var count = 0
                while count < dataViewerBatchBlocks {
                    let more = reader.withNextBlock { summary, samples -> Bool in
                        ingestor.add(summary, samples: samples)
                        return true
                    }
                    if more == nil { return (count, true) }
                    count += 1
                }
                return (count, false)
            }
            lod.finishBatch()
            read += batch.blocks
            done = batch.eof

            let now = Date()
            if done || now.timeIntervalSince(lastPublish) > 0.1 {
                lastPublish = now
                publish(.progress(min(1, Double(read) / Double(total))))
            }
        }
        publish(flag.isCancelled ? .progress(min(1, Double(read) / Double(total))) : .finished)
    }


    private nonisolated static func readDetail(path: String,
                                               firstBlock: Int,
                                               range: ClosedRange<Double>,
                                               duration: Double) -> DataDetailWindow? {
        guard let reader = try? OmReader(path: path) else { return nil }
        defer { reader.close() }
        let bucketCount = Int(((range.upperBound - range.lowerBound) / duration).rounded(.up)) + 2
        let level = DataLevel(start: range.lowerBound, duration: duration, bucketCount: bucketCount)
        guard reader.seek(toBlock: max(0, firstBlock)) else { return nil }

        var scanned = 0
        while scanned < dataViewerDetailBlockLimit {
            // The closure returns false once the blocks have run past the window; `nil` is EOF.
            let more = reader.withNextBlock { summary, samples -> Bool in
                scanned += 1
                guard summary.start <= range.upperBound else { return false }
                if summary.end >= range.lowerBound {
                    _ = level.add(summary, samples: samples, restrictToBounds: true)
                }
                return true
            }
            if more != true { break }
        }
        return DataDetailWindow(level: level, range: range)
    }

}


/// Blocks folded per lock acquisition. Small enough that a redraw never waits long for the lock.
private let dataViewerBatchBlocks = 256
/// A hard stop on how far a detail read will scan, so a corrupt seek index cannot walk a whole file.
private let dataViewerDetailBlockLimit = 200_000

/// A cancellation flag shared with the background load.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
