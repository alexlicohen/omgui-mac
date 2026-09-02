import Foundation

/// Writes syntactically valid `.CWA` files.
///
/// Layout follows `Docs/ax3/ax3-technical.md` and `Docs/ax3/cwa.h`, cross-checked against the
/// parser in `omapi-reader.c` (which is what actually reads these files back). Used to give the
/// mock backend a real `CWA-DATA.CWA` so `OmReader` exercises the same C code path as hardware.
public struct CwaWriter: Sendable {

    public static let blockSize = 512
    public static let headerSize = 1024

    /// `cwa_header_t.hardwareType`.
    public enum HardwareType: UInt8, Sendable {
        case ax3 = 0x17
        case ax6 = 0x64
    }

    public var hardware: HardwareType
    public var deviceId: UInt32
    public var sessionId: UInt32
    public var config: AccelConfig
    public var metadata: String
    public var loggingStart: OmDateTime
    public var loggingEnd: OmDateTime
    public var lastChange: OmDateTime
    public var firmwareRevision: UInt8
    public var flashLed: Bool
    /// Raw battery byte; volts = `(battery + 512) * 6000 / 1024 / 1000`.
    public var battery: UInt8
    /// Raw 10-bit light reading.
    public var light: UInt16
    /// Raw temperature; centigrade = `raw * 75 / 256 - 50`.
    public var temperature: UInt16

    public init(hardware: HardwareType = .ax3,
                deviceId: UInt32,
                sessionId: UInt32,
                config: AccelConfig = .deviceDefault,
                metadata: String = "",
                loggingStart: OmDateTime = .zero,
                loggingEnd: OmDateTime = .infinite,
                lastChange: OmDateTime = .zero,
                firmwareRevision: UInt8 = 48,
                flashLed: Bool = false,
                battery: UInt8 = 168,
                light: UInt16 = 300,
                temperature: UInt16 = 256) {
        self.hardware = hardware
        self.deviceId = deviceId
        self.sessionId = sessionId
        self.config = config
        self.metadata = metadata
        self.loggingStart = loggingStart
        self.loggingEnd = loggingEnd
        self.lastChange = lastChange
        self.firmwareRevision = firmwareRevision
        self.flashLed = flashLed
        self.battery = battery
        self.light = light
        self.temperature = temperature
    }

    // MARK: - Scale codes

    /// Accel scale exponent `n` in the data block's packed light field: units per g is `1 << (8 + n)`.
    /// An AX3 always reports 0 (256 counts/g); an AX6 reports the true 16-bit scale.
    var accelScaleCode: UInt16 {
        guard hardware == .ax6 else { return 0 }
        switch config.range {
        case .g16: return 3
        case .g8: return 4
        case .g4: return 5
        case .g2: return 6
        }
    }

    /// Gyro scale exponent `n`: dps is `8000 >> n` (matches `omapi-reader.c`).
    var gyroScaleCode: UInt16 {
        switch config.gyro ?? .off {
        case .off: return 0
        case .dps2000: return 2
        case .dps1000: return 3
        case .dps500: return 4
        case .dps250: return 5
        case .dps125: return 6
        }
    }

    /// `cwa_header_t.sensorConfig` — 0x00 for accel-only, else the gyro range in the low nibble.
    var sensorConfig: UInt8 {
        guard config.axisCount == 6 else { return 0x00 }
        return UInt8(gyroScaleCode & 0x0F)
    }

    // MARK: - Header

    public func headerBlock() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: CwaWriter.headerSize)
        write16(&b, 0, 0x444D)                                  // "MD"
        write16(&b, 2, UInt16(CwaWriter.headerSize - 4))        // 1020
        b[4] = hardware.rawValue
        write16(&b, 5, UInt16(deviceId & 0xFFFF))
        write32(&b, 7, sessionId)
        write16(&b, 11, UInt16((deviceId >> 16) & 0xFFFF))      // upperDeviceId (0 = none)
        write32(&b, 13, loggingStart.raw)
        write32(&b, 17, loggingEnd.raw)
        write32(&b, 21, 0)                                      // loggingCapacity (deprecated)
        b[26] = flashLed ? 1 : 0
        b[35] = sensorConfig
        b[36] = config.rateCode
        write32(&b, 37, lastChange.raw)
        b[41] = firmwareRevision
        write16(&b, 42, 0xFFFF)                                 // timeZone: unknown
        let annotation = MetadataTools.annotationBlock(from: metadata)
        b.replaceSubrange(64..<(64 + annotation.count), with: annotation)
        // @512 +512 device-specific scratch: leave as spaces, like a formatted device.
        for i in 512..<1024 { b[i] = 0x20 }
        return b
    }

    // MARK: - Data blocks

    /// Samples that fit in one block with 16-bit packing: `(512 - 32) / (axes * 2)`.
    public var samplesPerBlock: Int { 480 / (config.axisCount * 2) }

    /// Build one data block.
    ///
    /// - Parameters:
    ///   - sequenceId: 0-indexed packet counter.
    ///   - timestamp: whole-second RTC value valid at sample `timestampOffset`.
    ///   - samples: interleaved 16-bit values, `axes` per sample; `[Gx Gy Gz Ax Ay Az]` when the
    ///     gyro is on, `[Ax Ay Az]` otherwise (the order `omapi-reader.c` documents).
    public func dataBlock(sequenceId: UInt32,
                          timestamp: OmDateTime,
                          timestampOffset: Int16 = 0,
                          samples: [Int16],
                          events: UInt8 = 0) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: CwaWriter.blockSize)
        let axes = config.axisCount
        let count = min(samples.count / axes, samplesPerBlock)

        write16(&b, 0, 0x5841)                                  // "AX"
        write16(&b, 2, UInt16(CwaWriter.blockSize - 4))         // 508
        write16(&b, 4, UInt16(deviceId & 0x7FFF))               // top bit clear = device id
        write32(&b, 6, sessionId)
        write32(&b, 10, sequenceId)
        write32(&b, 14, timestamp.raw)
        // AAAGGGLLLLLLLLLL
        write16(&b, 18, (accelScaleCode << 13) | (gyroScaleCode << 10) | (light & 0x03FF))
        write16(&b, 20, temperature & 0x03FF)
        b[22] = events
        b[23] = battery
        b[24] = config.rateCode
        b[25] = UInt8((axes << 4) | 0x02)                       // 0x02 = 3x 16-bit signed
        write16(&b, 26, UInt16(bitPattern: timestampOffset))
        write16(&b, 28, UInt16(count))
        for i in 0..<(count * axes) {
            write16(&b, 30 + i * 2, UInt16(bitPattern: samples[i]))
        }
        write16(&b, 510, checksum(b))
        return b
    }

    /// 16-bit word-wise sum of the whole packet must be zero (`omapi-reader.c`).
    private func checksum(_ block: [UInt8]) -> UInt16 {
        var sum: UInt16 = 0
        var i = 0
        while i < block.count {
            sum = sum &+ (UInt16(block[i]) | (UInt16(block[i + 1]) << 8))
            i += 2
        }
        return 0 &- sum
    }

    // MARK: - Whole files

    /// A header-only file: this is what a device looks like after a Clear (OMGUI treats a data
    /// file of 1024 bytes or less as "no data").
    public func emptyFileData() -> Data { Data(headerBlock()) }

    /// A file with `blockCount` blocks of synthetic motion starting at `startTime`.
    ///
    /// The waveform is deterministic (a 0.5 Hz sine on X, cosine on Y, ~1 g static on Z) so tests
    /// can assert exact sample values.
    public func fileData(startTime: OmDateTime, blockCount: Int) -> Data {
        var data = Data(headerBlock())
        guard let base = startTime.date(in: .gmt) else { return data }
        let axes = config.axisCount
        let perBlock = samplesPerBlock
        let unitsPerG = 1 << (8 + Int(accelScaleCode))
        let gyroDps = Double(8000 >> Int(gyroScaleCode))
        let rateHz = config.rate.hz

        for block in 0..<blockCount {
            let firstSample = block * perBlock
            var samples: [Int16] = []
            samples.reserveCapacity(perBlock * axes)
            for i in 0..<perBlock {
                let t = Double(firstSample + i) / rateHz
                let x = sin(2 * Double.pi * 0.5 * t)
                let y = cos(2 * Double.pi * 0.5 * t)
                if axes == 6 {
                    let scale = 32768.0 / gyroDps
                    samples.append(clampInt16(x * 90.0 * scale))
                    samples.append(clampInt16(y * 90.0 * scale))
                    samples.append(clampInt16(0))
                }
                samples.append(clampInt16(x * 0.25 * Double(unitsPerG)))
                samples.append(clampInt16(y * 0.25 * Double(unitsPerG)))
                samples.append(clampInt16(1.0 * Double(unitsPerG)))
            }

            // The block's RTC field must be a whole second; `timestampOffset` says which sample
            // that second falls on, which is how the format expresses a sub-second block start.
            let blockStartSeconds = Double(firstSample) / rateHz
            let wholeSecond = blockStartSeconds.rounded(.up)
            let offset = Int16(clamping: Int(((wholeSecond - blockStartSeconds) * rateHz).rounded()))
            let stamp = OmDateTime(date: base.addingTimeInterval(wholeSecond), in: .gmt)

            data.append(contentsOf: dataBlock(sequenceId: UInt32(block),
                                              timestamp: stamp,
                                              timestampOffset: offset,
                                              samples: samples,
                                              events: block == 0 ? 0x01 : 0x00))
        }
        return data
    }

    private func clampInt16(_ value: Double) -> Int16 {
        Int16(max(-32768, min(32767, value.rounded())))
    }

    private func write16(_ b: inout [UInt8], _ offset: Int, _ value: UInt16) {
        b[offset] = UInt8(value & 0xFF)
        b[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private func write32(_ b: inout [UInt8], _ offset: Int, _ value: UInt32) {
        b[offset] = UInt8(value & 0xFF)
        b[offset + 1] = UInt8((value >> 8) & 0xFF)
        b[offset + 2] = UInt8((value >> 16) & 0xFF)
        b[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
