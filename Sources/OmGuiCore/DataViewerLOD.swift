import Foundation
import OmApi

/// The numeric series the preview keeps envelopes for.
///
/// `±1g` and `Time` are not series: OMGUI draws them from the geometry alone (a pair of dotted
/// guide lines and the per-hour background banding), which is why `DataViewer.cs` has no
/// `displayAccel` data — the flag exists but is hard-wired to `false`.
///
/// Units are the ones `DataViewer.cs` plots with: g, degrees/second, raw 10-bit light counts,
/// degrees Celsius, percent, and millivolts.
public enum DataSeries: Int, CaseIterable, Sendable {
    case x, y, z
    case gyroX, gyroY, gyroZ
    case light, temperature, batteryPercent, batteryMillivolts

    public static let count = 10
}

/// One value per `DataSeries`, held in a SIMD lane so a whole column merges in one operation.
public struct SeriesValues: Sendable, Equatable {
    public var storage: SIMD16<Float>

    public init(repeating value: Float) { storage = SIMD16(repeating: value) }
    public init(_ storage: SIMD16<Float>) { self.storage = storage }

    public static let lowest = SeriesValues(repeating: -.greatestFiniteMagnitude)
    public static let highest = SeriesValues(repeating: .greatestFiniteMagnitude)

    public subscript(series: DataSeries) -> Float {
        get { storage[series.rawValue] }
        set { storage[series.rawValue] = newValue }
    }

    public var x: Float { storage[DataSeries.x.rawValue] }
    public var y: Float { storage[DataSeries.y.rawValue] }
    public var z: Float { storage[DataSeries.z.rawValue] }
}

/// What one pixel column of the plot needs: whether any data covers it, the extremes of every
/// series over it, and the wall-clock span it covers (which is what picks the hour band).
public struct ColumnAggregate: Sendable {
    public var present = false
    /// Number of samples (accelerometer samples, not blocks) behind this column.
    public var count = 0
    /// Wall-clock seconds since 1970, read as UTC — the device's own clock, as libomapi returns it.
    public var startTime = 0.0
    public var endTime = 0.0
    public var minimum = SeriesValues.highest
    public var maximum = SeriesValues.lowest

    public init() {}

    /// The hour of day the column starts in, for the per-hour background banding.
    public var hourOfDay: Int {
        let seconds = startTime.truncatingRemainder(dividingBy: 86_400)
        let positive = seconds < 0 ? seconds + 86_400 : seconds
        return min(23, max(0, Int(positive / 3600)))
    }

    /// Midpoint of the covered span — `DataViewer.TimeForBlock` uses the mean of min and max.
    public var midTime: Double { (startTime + endTime) / 2 }

    public mutating func merge(_ other: ColumnAggregate) {
        guard other.present else { return }
        if !present {
            self = other
            return
        }
        count += other.count
        startTime = Swift.min(startTime, other.startTime)
        endTime = Swift.max(endTime, other.endTime)
        minimum.storage = pointwiseMin(minimum.storage, other.minimum.storage)
        maximum.storage = pointwiseMax(maximum.storage, other.maximum.storage)
    }
}

/// One decimation level: fixed-width time buckets holding a min/max envelope per series.
///
/// Storage is a flat `[Float]` of `bucketCount * DataSeries.count` so a level costs 84 bytes a
/// bucket and stays contiguous; `counts[bucket] == 0` means "nothing here", which is both "no
/// data in the file" and "not loaded yet" — the plot draws both as OMGUI's missing-data hatch.
final class DataLevel {
    let duration: Double
    let start: Double
    private(set) var bucketCount: Int
    var mins: [Float]
    var maxs: [Float]
    var counts: [UInt32]

    init(start: Double, duration: Double, bucketCount: Int) {
        self.start = start
        self.duration = duration
        self.bucketCount = Swift.max(1, bucketCount)
        let width = self.bucketCount * DataSeries.count
        mins = [Float](repeating: .greatestFiniteMagnitude, count: width)
        maxs = [Float](repeating: -.greatestFiniteMagnitude, count: width)
        counts = [UInt32](repeating: 0, count: self.bucketCount)
    }

    @inline(__always) func bucket(for time: Double) -> Int {
        Int(((time - start) / duration).rounded(.down))
    }

    @inline(__always) func startTime(ofBucket bucket: Int) -> Double {
        start + Double(bucket) * duration
    }

    /// Extends the level upwards in time. Only reached when a file's blocks run past the end time
    /// its header advertises (a device whose clock jumped forward mid-recording).
    func grow(toBucket bucket: Int) {
        guard bucket >= bucketCount else { return }
        let target = Swift.max(bucket + 1, bucketCount + bucketCount / 2)
        let extra = target - bucketCount
        mins.append(contentsOf: repeatElement(.greatestFiniteMagnitude, count: extra * DataSeries.count))
        maxs.append(contentsOf: repeatElement(-.greatestFiniteMagnitude, count: extra * DataSeries.count))
        counts.append(contentsOf: repeatElement(0, count: extra))
        bucketCount = target
    }

    /// Folds `[from, through]` of `source` into this level's buckets, recomputing each affected
    /// bucket from scratch so a partially-loaded bucket becomes correct once its children arrive.
    func rebuild(from source: DataLevel, sourceBuckets range: Range<Int>) {
        guard !range.isEmpty else { return }
        let ratio = Int((duration / source.duration).rounded())
        guard ratio >= 1 else { return }
        let first = range.lowerBound / ratio
        let last = (range.upperBound - 1) / ratio
        guard first <= last else { return }
        grow(toBucket: last)
        let n = DataSeries.count

        for bucket in first...last {
            var count: UInt32 = 0
            var lo = SIMD16<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD16<Float>(repeating: -.greatestFiniteMagnitude)
            let childFirst = bucket * ratio
            let childLast = Swift.min(childFirst + ratio, source.bucketCount)
            guard childFirst < childLast else { continue }
            for child in childFirst..<childLast where source.counts[child] > 0 {
                count &+= source.counts[child]
                let base = child * n
                for s in 0..<n {
                    lo[s] = Swift.min(lo[s], source.mins[base + s])
                    hi[s] = Swift.max(hi[s], source.maxs[base + s])
                }
            }
            counts[bucket] = count
            let base = bucket * n
            for s in 0..<n {
                mins[base + s] = lo[s]
                maxs[base + s] = hi[s]
            }
        }
    }

    /// Folds one block into this level, splitting it where it crosses a bucket boundary.
    ///
    /// Returns the buckets touched and how many samples fell before the level's start (a device
    /// whose clock went backwards mid-recording); those are folded into the first bucket.
    /// `restrictToBounds` drops samples outside the level's own span instead of folding them into
    /// the edge buckets — what a detail window wants, since it is only a viewport.
    func add(_ summary: OmReader.BlockSummary,
             samples: UnsafeBufferPointer<Int16>,
             restrictToBounds: Bool = false) -> (touched: Range<Int>, anomalies: Int) {
        guard summary.sampleCount > 0, summary.interval > 0 else { return (0..<0, 0) }

        let axes = summary.axes
        let accelOffset = summary.accelOffset
        let accelScale = Float(summary.accelScale == 0 ? 256 : summary.accelScale)
        let gyroScale = summary.gyroScale > 0 ? Float(summary.gyroScale) / 32768.0 : 0
        let hasGyro = summary.hasGyro && samples.count >= summary.sampleCount * axes

        // Per-block scalars: one reading for the whole block, so they widen every bucket it spans.
        let light = Float(summary.light)
        let temperature = Float(summary.temperatureMilliCentigrade) / 1000.0
        let batteryPercent = Float(summary.batteryPercent)
        let batteryMillivolts = Float(summary.batteryMillivolts)

        var anomalies = 0
        var lowest = Int.max
        var highest = Int.min
        var sample = 0

        while sample < summary.sampleCount {
            var bucket = self.bucket(for: summary.time(ofSample: sample))
            if bucket < 0 {
                if restrictToBounds {
                    let firstInside = (start - summary.start) / summary.interval
                    sample = Swift.max(sample + 1, Int(firstInside.rounded(.up)))
                    continue
                }
                anomalies += 1
                bucket = 0
            }
            if bucket >= bucketCount {
                if restrictToBounds { break }
                grow(toBucket: bucket)
            }

            // Samples up to the end of this bucket, or the end of the block.
            var last = summary.sampleCount - 1
            let bucketEnd = startTime(ofBucket: bucket + 1)
            if bucketEnd < summary.end {
                let edge = (bucketEnd - summary.start) / summary.interval
                last = Swift.min(last, Int(edge.rounded(.up)) - 1)
            }
            if last < sample { last = sample }

            var lo = SIMD16<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD16<Float>(repeating: -.greatestFiniteMagnitude)
            var i = sample * axes + accelOffset
            let limit = last * axes + accelOffset
            while i <= limit {
                let x = Float(samples[i]) / accelScale
                let y = Float(samples[i + 1]) / accelScale
                let z = Float(samples[i + 2]) / accelScale
                if x < lo[0] { lo[0] = x }; if x > hi[0] { hi[0] = x }
                if y < lo[1] { lo[1] = y }; if y > hi[1] { hi[1] = y }
                if z < lo[2] { lo[2] = z }; if z > hi[2] { hi[2] = z }
                if hasGyro {
                    let gx = Float(samples[i - 3]) * gyroScale
                    let gy = Float(samples[i - 2]) * gyroScale
                    let gz = Float(samples[i - 1]) * gyroScale
                    if gx < lo[3] { lo[3] = gx }; if gx > hi[3] { hi[3] = gx }
                    if gy < lo[4] { lo[4] = gy }; if gy > hi[4] { hi[4] = gy }
                    if gz < lo[5] { lo[5] = gz }; if gz > hi[5] { hi[5] = gz }
                }
                i += axes
            }
            if !hasGyro {
                lo[3] = 0; hi[3] = 0; lo[4] = 0; hi[4] = 0; lo[5] = 0; hi[5] = 0
            }
            lo[6] = light; hi[6] = light
            lo[7] = temperature; hi[7] = temperature
            lo[8] = batteryPercent; hi[8] = batteryPercent
            lo[9] = batteryMillivolts; hi[9] = batteryMillivolts

            let base = bucket * DataSeries.count
            let existing = counts[bucket]
            for s in 0..<DataSeries.count {
                if existing == 0 {
                    mins[base + s] = lo[s]
                    maxs[base + s] = hi[s]
                } else {
                    mins[base + s] = Swift.min(mins[base + s], lo[s])
                    maxs[base + s] = Swift.max(maxs[base + s], hi[s])
                }
            }
            counts[bucket] = existing &+ UInt32(last - sample + 1)
            lowest = Swift.min(lowest, bucket)
            highest = Swift.max(highest, bucket)
            sample = last + 1
        }
        guard lowest <= highest else { return (0..<0, anomalies) }
        return (lowest..<(highest + 1), anomalies)
    }

    /// Whether `[from, to)` lies inside this level's buckets.
    func covers(from: Double, to: Double) -> Bool {
        bucket(for: from) >= 0 && bucket(for: to) < bucketCount
    }

    /// Aggregates the buckets overlapping `[from, to)`.
    func aggregate(from: Double, to: Double) -> ColumnAggregate {
        var result = ColumnAggregate()
        let firstBucket = Swift.max(0, bucket(for: from))
        var lastBucket = bucket(for: to)
        if Double(lastBucket) * duration + start >= to { lastBucket -= 1 }   // `to` is exclusive
        lastBucket = Swift.min(lastBucket, bucketCount - 1)
        guard firstBucket <= lastBucket else { return result }

        let n = DataSeries.count
        var lo = SIMD16<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD16<Float>(repeating: -.greatestFiniteMagnitude)
        var count = 0
        var firstPresent = -1
        var lastPresent = -1

        mins.withUnsafeBufferPointer { minBuffer in
            maxs.withUnsafeBufferPointer { maxBuffer in
                for bucket in firstBucket...lastBucket where counts[bucket] > 0 {
                    count += Int(counts[bucket])
                    if firstPresent < 0 { firstPresent = bucket }
                    lastPresent = bucket
                    let base = bucket * n
                    for s in 0..<n {
                        lo[s] = Swift.min(lo[s], minBuffer[base + s])
                        hi[s] = Swift.max(hi[s], maxBuffer[base + s])
                    }
                }
            }
        }
        guard firstPresent >= 0 else { return result }
        result.present = true
        result.count = count
        result.startTime = startTime(ofBucket: firstPresent)
        result.endTime = startTime(ofBucket: lastPresent) + duration
        result.minimum = SeriesValues(lo)
        result.maximum = SeriesValues(hi)
        return result
    }
}

/// The level-of-detail pyramid a `DataViewer` renders from.
///
/// A week of 100 Hz data is 60 million samples; nothing here holds samples. Blocks are folded into
/// fixed-width time buckets as they are read, and each level above is folded from the one below,
/// so a redraw touches at most `ratio` buckets per pixel column no matter how long the file is.
///
/// The base bucket is chosen from a fixed ladder so that the base level never exceeds
/// `maximumBaseBuckets` — memory is bounded by the *bucket budget*, not by the file: 1 s buckets
/// for a day (86 400 buckets, 7 MB), 5 s for a week (121 000 buckets, 10 MB), 10 s for a month.
/// Below the base resolution the model reads the visible window back off disk (see
/// `DataViewerModel.detail`), which is cheap because the window is by then only minutes long.
///
/// Thread-safe: the loader ingests under the lock in batches, the plot reads under the same lock.
public final class DataViewerLOD: @unchecked Sendable {

    /// Bucket durations the base level may take, in seconds.
    static let ladder: [Double] = [1, 2, 5, 10, 30, 60, 120, 300, 600, 1800, 3600]
    /// Each level above the base multiplies by the next factor: 1 s → 10 s → 1 min → 10 min → 1 h.
    static let factors: [Int] = [10, 6, 10, 6]

    private let lock = NSLock()
    private var levels: [DataLevel]
    private var pendingFold: Range<Int>?
    private var _hasGyro = false
    private var _loadedThrough: Double
    private var _blocksRead = 0
    private var _clockAnomalies = 0
    /// `(time, block index)` every `seekStride` blocks, for seeking back into the file by time.
    private var seek: [(time: Double, block: Int)] = []
    private var seekStride = 64

    public let start: Double
    public private(set) var end: Double

    public init(start: Double, end: Double, maximumBaseBuckets: Int = 262_144) {
        self.start = start
        self.end = Swift.max(end, start + 1)
        _loadedThrough = start

        let span = self.end - start
        let base = DataViewerLOD.ladder.first { span / $0 <= Double(maximumBaseBuckets) }
            ?? DataViewerLOD.ladder[DataViewerLOD.ladder.count - 1]
        var durations = [base]
        for factor in DataViewerLOD.factors {
            let next = durations[durations.count - 1] * Double(factor)
            if span / next < 2 { break }
            durations.append(next)
        }
        levels = durations.map { duration in
            DataLevel(start: start,
                      duration: duration,
                      bucketCount: Int((span / duration).rounded(.up)) + 1)
        }
    }

    /// Bucket duration of every level, coarsest last.
    public var levelDurations: [Double] { levels.map(\.duration) }
    public var baseDuration: Double { levels[0].duration }
    public var bounds: ClosedRange<Double> { start...end }

    public var hasGyro: Bool { lock.withLock { _hasGyro } }
    /// Wall-clock time the sequential load has reached.
    public var loadedThrough: Double { lock.withLock { _loadedThrough } }
    public var blocksRead: Int { lock.withLock { _blocksRead } }
    /// Blocks whose timestamp fell before the file's advertised start (a device clock that went
    /// backwards mid-recording); they are folded into the first bucket.
    public var clockAnomalies: Int { lock.withLock { _clockAnomalies } }

    /// Bytes the pyramid currently occupies, for the notes and the tests.
    public var byteCount: Int {
        lock.withLock {
            levels.reduce(0) { $0 + $1.bucketCount * (DataSeries.count * 8 + 4) }
        }
    }

    // MARK: - Loading

    /// Runs `body` with the lock held, so a batch of blocks costs one acquisition.
    func ingestBatch<R>(_ body: (Ingestor) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(Ingestor(lod: self))
    }

    /// The write side of the pyramid, valid only inside `ingestBatch`.
    struct Ingestor {
        let lod: DataViewerLOD
        func add(_ summary: OmReader.BlockSummary, samples: UnsafeBufferPointer<Int16>) {
            lod.addLocked(summary, samples: samples)
        }
    }

    /// Folds one block into the base level and records the bookkeeping the plot reads.
    private func addLocked(_ summary: OmReader.BlockSummary, samples: UnsafeBufferPointer<Int16>) {
        _blocksRead += 1
        if summary.hasGyro { _hasGyro = true }
        let (touched, anomalies) = levels[0].add(summary, samples: samples)
        _clockAnomalies += anomalies
        if !touched.isEmpty {
            if let range = pendingFold {
                pendingFold = Swift.min(range.lowerBound, touched.lowerBound)..<Swift.max(range.upperBound, touched.upperBound)
            } else {
                pendingFold = touched
            }
        }
        _loadedThrough = Swift.max(_loadedThrough, summary.end)
        if summary.end > end { end = summary.end }
        if _blocksRead % seekStride == 1 || seek.isEmpty {
            seek.append((summary.start, summary.index))
        }
    }

    /// Folds everything ingested since the last call up through the coarser levels.
    func finishBatch() {
        lock.lock()
        defer { lock.unlock() }
        guard var range = pendingFold else { return }
        pendingFold = nil
        for index in 1..<levels.count {
            levels[index].rebuild(from: levels[index - 1], sourceBuckets: range)
            let ratio = Int((levels[index].duration / levels[index - 1].duration).rounded())
            range = (range.lowerBound / ratio)..<((range.upperBound - 1) / ratio + 1)
        }
    }

    // MARK: - Reading

    /// The level whose buckets are no wider than `secondsPerColumn`, coarsest first.
    func level(forSecondsPerColumn seconds: Double) -> DataLevel {
        var chosen = levels[0]
        for level in levels where level.duration <= seconds { chosen = level }
        return chosen
    }

    /// Bucket duration the plot would draw a range of `span` seconds across `columns` pixels with.
    public func resolution(forSpan span: Double, columns: Int) -> Double {
        guard columns > 0 else { return baseDuration }
        return level(forSecondsPerColumn: span / Double(columns)).duration
    }

    /// Fills `output` with one aggregate per pixel column across `range`.
    ///
    /// `detail` is an optional finer level covering part of the range (read back off disk for a
    /// zoomed-in window); where it covers a column it wins over the pyramid.
    public func columns(range: ClosedRange<Double>,
                        into output: inout [ColumnAggregate],
                        detail: DataDetailWindow? = nil) {
        let count = output.count
        guard count > 0 else { return }
        let span = Swift.max(range.upperBound - range.lowerBound, .leastNormalMagnitude)
        let step = span / Double(count)

        lock.lock()
        defer { lock.unlock() }
        let level = self.level(forSecondsPerColumn: step)
        for column in 0..<count {
            let from = range.lowerBound + Double(column) * step
            let to = from + step
            // Bucket indices, not float comparisons: the last column's `to` can land an ulp past
            // the window's end and would otherwise fall back to the coarse level for one pixel.
            if let window = detail, window.duration < level.duration,
               window.level.covers(from: from, to: to) {
                output[column] = window.level.aggregate(from: from, to: to)
            } else {
                output[column] = level.aggregate(from: from, to: to)
            }
        }
    }

    /// One aggregate over an arbitrary span — the cursor read-out and the tests use this.
    public func aggregate(from: Double, to: Double) -> ColumnAggregate {
        lock.lock()
        defer { lock.unlock() }
        let level = self.level(forSecondsPerColumn: Swift.max(to - from, baseDuration))
        return level.aggregate(from: from, to: to)
    }

    /// First block at or before `time`, from the sparse seek index built during the load.
    public func block(before time: Double) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard !seek.isEmpty else { return 0 }
        var low = 0, high = seek.count - 1, answer = 0
        while low <= high {
            let mid = (low + high) / 2
            if seek[mid].time <= time { answer = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return seek[answer].block
    }
}

/// A finer level built for one visible window by reading those blocks back off disk, for zoom
/// levels below the pyramid's base bucket. `DataViewer.cs` does the equivalent by re-reading the
/// blocks under the visible pixels; here the window is a proper level, so the drawing code is
/// the same at every zoom.
public final class DataDetailWindow: @unchecked Sendable {
    let level: DataLevel
    public let range: ClosedRange<Double>
    public var duration: Double { level.duration }

    init(level: DataLevel, range: ClosedRange<Double>) {
        self.level = level
        self.range = range
    }
}
