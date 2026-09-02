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
                let base = OmDateTime(raw: packed).date(in: .gmt) ?? Date(timeIntervalSince1970: 0)
                times.append(base.addingTimeInterval(Double(fractional) / 65536.0))
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
