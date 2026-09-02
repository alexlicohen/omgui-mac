import Foundation
import COmApi

/// Reads a `.CWA` file (or a device's `CWA-DATA.CWA`) through libomapi's reader.
///
/// Mirrors upstream `omapinet/OmReader.cs`. Not thread-safe: the underlying handle carries a file
/// position and a current-block buffer.
public final class OmReader {

    /// One 512-byte data packet, decoded.
    public struct Block: Sendable {
        public var sequenceId: UInt32
        public var sampleCount: Int
        /// Synchronous axes: 3 = accel only, 6 = gyro + accel, 9 = gyro + accel + mag.
        public var axes: Int
        /// Units per g (`OM_VALUE_SCALE_ACCEL`): 256 on AX3, 2048…16384 on AX6.
        public var accelScale: Int
        /// Degrees/second that 32768 represents (`OM_VALUE_SCALE_GYRO`).
        public var gyroScale: Int
        /// Raw 10-bit light reading.
        public var light: Int
        public var temperatureMilliCentigrade: Int
        public var batteryMillivolts: Int
        public var batteryPercent: Int
        public var events: Int
        /// Interleaved raw values, `axes` per sample.
        public var raw: [Int16]
        /// Timestamp of each sample, `sampleCount` entries.
        public var times: [Date]

        public var temperatureCelsius: Double { Double(temperatureMilliCentigrade) / 1000.0 }
        public var batteryVolts: Double { Double(batteryMillivolts) / 1000.0 }

        /// Accelerometer sample `index`, in g.
        public func accel(_ index: Int) -> (x: Double, y: Double, z: Double) {
            let base = index * axes + (axes >= 6 ? 3 : 0)
            let s = Double(accelScale)
            return (Double(raw[base]) / s, Double(raw[base + 1]) / s, Double(raw[base + 2]) / s)
        }

        /// Gyroscope sample `index`, in degrees/second, or `nil` when there is no gyro.
        public func gyro(_ index: Int) -> (x: Double, y: Double, z: Double)? {
            guard axes >= 6 else { return nil }
            let base = index * axes
            let s = Double(gyroScale) / 32768.0
            return (Double(raw[base]) * s, Double(raw[base + 1]) * s, Double(raw[base + 2]) * s)
        }
    }

    private var handle: OmReaderHandle?
    public let path: String

    /// Device id from the file header.
    public private(set) var deviceId: UInt32 = 0
    /// Session id from the file header.
    public private(set) var sessionId: UInt32 = 0
    /// Raw annotation text from the header (still URL-encoded).
    public private(set) var metadata: String = ""
    public private(set) var dataBlockSize = 0
    public private(set) var dataOffsetBlocks = 0
    public private(set) var dataNumBlocks = 0
    public private(set) var startTime: OmDateTime = .zero
    public private(set) var endTime: OmDateTime = .zero

    /// Opens a `.CWA` file. Throws if the header is not a valid `MD` packet.
    public init(path: String) throws {
        self.path = path
        guard let handle = OmReaderOpen(path) else {
            throw OmApiError("Not a readable CWA file: \(path)")
        }
        self.handle = handle

        var blockSize: Int32 = 0, offsetBlocks: Int32 = 0, numBlocks: Int32 = 0
        var start: OM_DATETIME = 0, end: OM_DATETIME = 0
        _ = OmReaderDataRange(handle, &blockSize, &offsetBlocks, &numBlocks, &start, &end)
        dataBlockSize = Int(blockSize)
        dataOffsetBlocks = Int(offsetBlocks)
        dataNumBlocks = Int(numBlocks)
        startTime = OmDateTime(raw: start)
        endTime = OmDateTime(raw: end)

        var rawDeviceId: Int32 = 0
        var rawSessionId: UInt32 = 0
        if let text = OmReaderMetadata(handle, &rawDeviceId, &rawSessionId) {
            var bytes: [UInt8] = []
            var p = text
            while p.pointee != 0 { bytes.append(UInt8(bitPattern: p.pointee)); p += 1 }
            metadata = MetadataTools.metadata(fromAnnotation: bytes)
        }
        deviceId = UInt32(bitPattern: rawDeviceId)
        sessionId = rawSessionId

        _ = OmReaderDataBlockSeek(handle, 0)
    }

    /// Opens the data file of an attached device.
    public convenience init(device: OmDevice) throws {
        try self.init(path: device.dataFilePath)
    }

    deinit { close() }

    public func close() {
        if let handle { OmReaderClose(handle) }
        handle = nil
    }

    /// Decoded `StudyMetadata` from the header annotation.
    public var studyMetadata: StudyMetadata { StudyMetadata(decoding: metadata) }

    /// `OmReaderDataBlockPosition` — block index relative to the first data block.
    public var position: Int {
        guard let handle else { return 0 }
        return Int(OmReaderDataBlockPosition(handle))
    }

    /// `OmReaderDataBlockSeek`.
    @discardableResult
    public func seek(toBlock index: Int) -> Bool {
        guard let handle else { return false }
        return omSucceeded(OmReaderDataBlockSeek(handle, Int32(index)))
    }

    /// Reads the next data block, skipping blocks the parser rejects. `nil` at end of file.
    public func nextBlock() -> Block? {
        guard let handle else { return nil }
        while true {
            let sampleCount = OmReaderNextBlock(handle)
            if sampleCount < 0 { return nil }           // end of file (or read error)
            if sampleCount == 0 { continue }            // malformed/blank sector: skip it
            let axes = max(Int(OmReaderGetValue(handle, OM_VALUE_AXES)), 1)
            let count = Int(sampleCount)

            var raw: [Int16] = []
            if let buffer = OmReaderBuffer(handle) {
                raw = Array(UnsafeBufferPointer(start: buffer, count: count * axes))
            }

            var times: [Date] = []
            times.reserveCapacity(count)
            for i in 0..<count {
                var fractional: UInt16 = 0
                let packed = OmReaderTimestamp(handle, Int32(i), &fractional)
                times.append(Date(timeIntervalSince1970: OmReader.epochSeconds(packed, fractional)))
            }

            return Block(
                sequenceId: UInt32(bitPattern: OmReaderGetValue(handle, OM_VALUE_SEQUENCEID)),
                sampleCount: count,
                axes: axes,
                accelScale: Int(OmReaderGetValue(handle, OM_VALUE_SCALE_ACCEL)),
                gyroScale: axes >= 6 ? Int(OmReaderGetValue(handle, OM_VALUE_SCALE_GYRO)) : 0,
                light: Int(OmReaderGetValue(handle, OM_VALUE_LIGHT)),
                temperatureMilliCentigrade: Int(OmReaderGetValue(handle, OM_VALUE_TEMPERATURE_MC)),
                batteryMillivolts: Int(OmReaderGetValue(handle, OM_VALUE_BATTERY_MV)),
                batteryPercent: Int(OmReaderGetValue(handle, OM_VALUE_BATTERY_PERCENT)),
                events: Int(OmReaderGetValue(handle, OM_VALUE_EVENTS)),
                raw: raw,
                times: times)
        }
    }

    /// Every block from the current position, for small files and tests.
    public func readAllBlocks(limit: Int = Int.max) -> [Block] {
        var blocks: [Block] = []
        while blocks.count < limit, let block = nextBlock() { blocks.append(block) }
        return blocks
    }
}

// MARK: - Fast paths

/// The reader's original `nextBlock()` builds one `Date` per sample, and each of those runs a
/// `Calendar` conversion (and, inside libomapi, a `gmtime_r`). At 100 Hz a week of data is 60
/// million samples, so a preview that walked the file that way would spend minutes in calendar
/// arithmetic alone. Everything below reads a block's header values and its two end timestamps
/// only, converts them with plain integer arithmetic, and hands out libomapi's own sample buffer
/// without copying it. `OmReaderTimestamp()` itself interpolates linearly between the block's
/// start and end (`omapi-reader.c`), so interpolating in Swift from the two ends is the same
/// arithmetic, to within one 1/65536 s tick.
extension OmReader {

    /// One data block's header values and time span, with no sample decode on the Swift side.
    public struct BlockSummary: Sendable {
        /// Block index relative to the first data block (what `seek(toBlock:)` takes).
        public var index: Int
        public var sequenceId: UInt32
        public var sampleCount: Int
        /// Synchronous axes: 3 = accel only, 6 = gyro + accel, 9 = gyro + accel + mag.
        public var axes: Int
        /// Units per g (`OM_VALUE_SCALE_ACCEL`).
        public var accelScale: Int
        /// Degrees/second that 32768 represents (`OM_VALUE_SCALE_GYRO`), 0 when there is no gyro.
        public var gyroScale: Int
        /// Raw `@24 sampleRate` byte (`OM_VALUE_SAMPLERATE` returns it undecoded).
        public var sampleRateCode: Int
        public var light: Int
        public var temperatureMilliCentigrade: Int
        public var batteryMillivolts: Int
        public var batteryPercent: Int
        public var events: Int
        /// Time of sample 0, in seconds since 1970 on the device's own clock (read as UTC, which
        /// is what libomapi's `timegm`/`gmtime_r` pair does — the CWA stores wall-clock time).
        public var start: Double
        /// One sample interval past the last sample, i.e. the block's exclusive end.
        public var end: Double

        /// True nominal rate in Hz: `3200 / (1 << (15 - (code & 0x0f)))`.
        public var sampleRate: Double {
            let shift = 15 - (sampleRateCode & 0x0F)
            guard shift >= 0, shift < 32 else { return 0 }
            return 3200.0 / Double(1 << shift)
        }
        /// The rate libomapi *times the block with*, which is the same expression in integer
        /// arithmetic — so 12.5 Hz becomes 12 and 6.25 Hz becomes 6, and the block timestamps it
        /// hands back are stretched by 4 %. `omapi-reader.c` carries the TODO. OMGUI plots the
        /// same stretched timeline, so this port keeps it rather than silently disagreeing.
        public var readerSampleRate: Int {
            let shift = 15 - (sampleRateCode & 0x0F)
            guard shift >= 0, shift < 32 else { return 0 }
            return 3200 / (1 << shift)
        }
        /// Nominal range in g: `16 >> (code >> 6)`.
        public var accelRangeG: Int { 16 >> ((sampleRateCode >> 6) & 0x03) }
        public var hasGyro: Bool { axes >= 6 }
        /// Seconds between samples.
        public var interval: Double { sampleCount > 0 ? (end - start) / Double(sampleCount) : 0 }
        /// Offset of the accelerometer triple within a sample (the gyro leads when present).
        public var accelOffset: Int { axes >= 6 ? 3 : 0 }
        public var startDate: Date { Date(timeIntervalSince1970: start) }
        public var endDate: Date { Date(timeIntervalSince1970: end) }
        /// Time of sample `index`, by the same interpolation `OmReaderTimestamp()` uses.
        public func time(ofSample index: Int) -> Double { start + Double(index) * interval }
    }

    /// Reads the next block's header only, skipping blocks the parser rejects. `nil` at end of file.
    public func nextSummary() -> BlockSummary? {
        withNextBlock { summary, _ in summary }
    }

    /// Reads the next block and hands its summary and libomapi's decoded sample buffer to `body`.
    ///
    /// The buffer holds `sampleCount * axes` interleaved values and is only valid for the duration
    /// of the call — it is the reader's own scratch space, overwritten by the next read. `nil` at
    /// end of file; blocks the parser rejects are skipped, which leaves a gap in the timeline.
    public func withNextBlock<R>(_ body: (BlockSummary, UnsafeBufferPointer<Int16>) throws -> R) rethrows -> R? {
        guard let handle else { return nil }
        while true {
            let index = Int(OmReaderDataBlockPosition(handle))
            let sampleCount = OmReaderNextBlock(handle)
            if sampleCount < 0 { return nil }           // end of file (or read error)
            if sampleCount == 0 { continue }            // malformed/blank sector: skip it
            let count = Int(sampleCount)
            let axes = max(Int(OmReaderGetValue(handle, OM_VALUE_AXES)), 1)
            let rate = Int(OmReaderGetValue(handle, OM_VALUE_SAMPLERATE))

            var fractional: UInt16 = 0
            let first = OmReader.epochSeconds(OmReaderTimestamp(handle, 0, &fractional), fractional)
            var last = first
            if count > 1 {
                let packed = OmReaderTimestamp(handle, Int32(count - 1), &fractional)
                last = OmReader.epochSeconds(packed, fractional)
            }
            // `OmReaderTimestamp(i)` is blockStart + i * (blockEnd - blockStart) / sampleCount, so
            // the step between the two ends divides by count - 1, not count.
            var interval = count > 1 ? (last - first) / Double(count - 1) : 0

            var summary = BlockSummary(
                index: index,
                sequenceId: UInt32(bitPattern: OmReaderGetValue(handle, OM_VALUE_SEQUENCEID)),
                sampleCount: count,
                axes: axes,
                accelScale: Int(OmReaderGetValue(handle, OM_VALUE_SCALE_ACCEL)),
                gyroScale: axes >= 6 ? Int(OmReaderGetValue(handle, OM_VALUE_SCALE_GYRO)) : 0,
                sampleRateCode: rate,
                light: Int(OmReaderGetValue(handle, OM_VALUE_LIGHT)),
                temperatureMilliCentigrade: Int(OmReaderGetValue(handle, OM_VALUE_TEMPERATURE_MC)),
                batteryMillivolts: Int(OmReaderGetValue(handle, OM_VALUE_BATTERY_MV)),
                batteryPercent: Int(OmReaderGetValue(handle, OM_VALUE_BATTERY_PERCENT)),
                events: Int(OmReaderGetValue(handle, OM_VALUE_EVENTS)),
                start: first,
                end: first + Double(count) * interval)
            if interval <= 0 || !interval.isFinite {
                // A one-sample block has no measurable step; fall back to the header's rate.
                let hz = summary.readerSampleRate
                interval = hz > 0 ? 1.0 / Double(hz) : 0
                summary.end = summary.start + Double(count) * interval
            }

            let buffer = OmReaderBuffer(handle)
            return try body(summary, UnsafeBufferPointer(start: buffer, count: buffer == nil ? 0 : count * axes))
        }
    }

    /// Summaries for `count` blocks starting at `index`, seeking straight to them.
    public func summaries(fromBlock index: Int, count: Int) -> [BlockSummary] {
        guard seek(toBlock: index) else { return [] }
        var result: [BlockSummary] = []
        result.reserveCapacity(count)
        while result.count < count, let summary = nextSummary(), summary.index < index + count {
            result.append(summary)
        }
        return result
    }

    /// Seconds since 1970 for a packed `OM_DATETIME` plus its 1/65536 s fractional part.
    ///
    /// `Calendar.date(from:)` costs microseconds per call; this is the civil-days algorithm the C
    /// library's `timegm` implements, in integer arithmetic, and matches it exactly for every
    /// date `OM_DATETIME` can hold (2000-01-01 … 2063-12-31).
    public static func epochSeconds(_ packed: OM_DATETIME, _ fractional: UInt16 = 0) -> Double {
        let t = OmDateTime(raw: UInt32(packed))
        guard t.isValid, t.month >= 1, t.month <= 12 else { return 0 }
        let days = daysFromCivil(year: t.year, month: t.month, day: t.day)
        let seconds = days * 86_400 + t.hour * 3600 + t.minute * 60 + t.second
        return Double(seconds) + Double(fractional) / 65536.0
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's `days_from_civil`).
    public static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                             // [0, 399]
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1  // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy                     // [0, 146096]
        return era * 146_097 + doe - 719_468
    }
}
