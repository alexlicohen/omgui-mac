import Foundation
import OmApi
import XCTest

/// A `.CWA` whose every block carries *constant* sample values plus its own light, temperature and
/// battery reading, so a bucket's expected extremes are known without re-deriving them through the
/// same reader the code under test uses.
struct SyntheticCwa {

    struct BlockValues {
        var x: Int16 = 0
        var y: Int16 = 0
        var z: Int16 = 0
        var gyroX: Int16 = 0
        var gyroY: Int16 = 0
        var gyroZ: Int16 = 0
        var light: UInt16 = 0
        var temperature: UInt16 = 256
        var battery: UInt8 = 168
    }

    /// Block `k` starts at `base + k * samplesPerBlock / rate`, plus `gapSeconds` once `k` passes
    /// `gapAfterBlock` — which is how a recording with a hole in it is built.
    static func write(blocks: Int,
                      hardware: CwaWriter.HardwareType = .ax3,
                      config: AccelConfig = AccelConfig(rate: .hz100, range: .g8),
                      start: OmDateTime,
                      gapAfterBlock: Int = .max,
                      gapSeconds: Double = 0,
                      values: (Int) -> BlockValues) -> (url: URL, blockDuration: Double, blockStart: (Int) -> Double) {
        var writer = CwaWriter(hardware: hardware, deviceId: 4242, sessionId: 7, config: config)
        let axes = config.axisCount
        let perBlock = writer.samplesPerBlock
        let rate = config.rate.hz
        let blockDuration = Double(perBlock) / rate
        let blockStart: (Int) -> Double = { k in
            Double(k) * blockDuration + (k > gapAfterBlock ? gapSeconds : 0)
        }

        var data = Data(writer.headerBlock())
        for k in 0..<blocks {
            let v = values(k)
            writer.light = v.light
            writer.temperature = v.temperature
            writer.battery = v.battery

            var samples: [Int16] = []
            samples.reserveCapacity(perBlock * axes)
            for _ in 0..<perBlock {
                if axes == 6 {
                    samples.append(v.gyroX); samples.append(v.gyroY); samples.append(v.gyroZ)
                }
                samples.append(v.x); samples.append(v.y); samples.append(v.z)
            }

            // The RTC field is a whole second; `timestampOffset` says which sample it lands on,
            // which is how the format expresses a block that starts mid-second.
            let offsetSeconds = blockStart(k)
            let wholeSecond = offsetSeconds.rounded(.up)
            let offset = Int16(clamping: Int(((wholeSecond - offsetSeconds) * rate).rounded()))
            let stamp = OmDateTime(date: (start.date(in: .gmt) ?? Date()).addingTimeInterval(wholeSecond),
                                   in: .gmt)
            data.append(contentsOf: writer.dataBlock(sequenceId: UInt32(k),
                                                     timestamp: stamp,
                                                     timestampOffset: offset,
                                                     samples: samples))
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omgui-lod-\(UUID().uuidString).cwa")
        try? data.write(to: url)
        return (url, blockDuration, blockStart)
    }

    /// Milli-centigrade for a raw temperature word, as `omapi-reader.c` converts it.
    static func milliCentigrade(_ raw: UInt16) -> Int { Int(raw & 0x3FF) * 75_000 / 256 - 50_000 }
    /// Millivolts for a raw battery byte.
    static func millivolts(_ raw: UInt8) -> Int { (Int(raw) + 512) * 6000 / 1024 }
}
