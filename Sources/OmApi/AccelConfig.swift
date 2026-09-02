import Foundation

/// The accelerometer sample rates OMGUI offers (`DateRangeForm` "Freq. (Hz)" combo box).
///
/// `apiValue` is what OMGUI passes to `OmSetAccelConfig` — it is the *integer truncation* of the
/// displayed frequency (`(int)float.Parse("12.5") == 12`), which is exactly what the C switch in
/// `omapi-settings.c` matches on.
public enum SampleRate: Int, CaseIterable, Sendable {
    case hz3200 = 3200
    case hz1600 = 1600
    case hz800 = 800
    case hz400 = 400
    case hz200 = 200
    case hz100 = 100
    case hz50 = 50
    case hz25 = 25
    case hz12_5 = 12
    case hz6_25 = 6

    /// The value OMGUI/`OmSetAccelConfig` uses.
    public var apiValue: Int { rawValue }

    /// The true frequency in Hz.
    public var hz: Double {
        switch self {
        case .hz12_5: return 12.5
        case .hz6_25: return 6.25
        default: return Double(rawValue)
        }
    }

    /// The 4-bit rate code: `3200 / (1 << (15 - code))`.
    public var code: UInt8 {
        switch self {
        case .hz3200: return 0x0F
        case .hz1600: return 0x0E
        case .hz800: return 0x0D
        case .hz400: return 0x0C
        case .hz200: return 0x0B
        case .hz100: return 0x0A
        case .hz50: return 0x09
        case .hz25: return 0x08
        case .hz12_5: return 0x07
        case .hz6_25: return 0x06
        }
    }

    public var displayString: String { hz == hz.rounded() ? String(Int(hz)) : String(hz) }

    public init?(apiValue: Int) { self.init(rawValue: apiValue) }

    public init?(code: UInt8) {
        guard let match = SampleRate.allCases.first(where: { $0.code == (code & 0x0F) }) else { return nil }
        self = match
    }

    /// Accepts "12.5", "12", "6.25", "100"...
    public init?(display: String) {
        guard let d = Double(display) else { return nil }
        self.init(rawValue: Int(d))
    }
}

/// Accelerometer sensitivity, `±g` (`DateRangeForm` "Range (±g)").
public enum AccelRange: Int, CaseIterable, Sendable {
    case g16 = 16, g8 = 8, g4 = 4, g2 = 2

    /// Top two bits of the rate code.
    public var code: UInt8 {
        switch self {
        case .g16: return 0x00
        case .g8: return 0x40
        case .g4: return 0x80
        case .g2: return 0xC0
        }
    }

    public init?(code: UInt8) {
        switch code >> 6 {
        case 0: self = .g16
        case 1: self = .g8
        case 2: self = .g4
        default: self = .g2
        }
    }
}

/// Synchronous gyroscope range in degrees/second (AX6 only). `.off` is `0`.
public enum GyroRange: Int, CaseIterable, Sendable {
    case off = 0, dps125 = 125, dps250 = 250, dps500 = 500, dps1000 = 1000, dps2000 = 2000
}

/// One `RATE` configuration, in the exact form the API and the device protocol use.
///
/// Encoding is `omapi-settings.c` / `Docs/ax3/ax3-technical.md`:
/// * rate code byte = range bits (`0/64/128/192`) | low-power bit (`16`) | frequency code (`6…15`)
/// * `OmSetAccelConfig(rate, range)` overloads its two `int` arguments: a **negative rate** means
///   low power, and the **high word of range** carries the gyro range (`range |= gyroRange << 16`),
///   exactly as `MainForm.cs` builds it.
public struct AccelConfig: Hashable, Sendable {
    public var rate: SampleRate
    public var range: AccelRange
    public var lowPower: Bool
    /// `nil` = leave the gyro unspecified (the device disables it); `.off` = explicitly disabled.
    public var gyro: GyroRange?

    public init(rate: SampleRate = .hz100, range: AccelRange = .g8,
                lowPower: Bool = false, gyro: GyroRange? = nil) {
        self.rate = rate
        self.range = range
        self.lowPower = lowPower
        self.gyro = gyro
    }

    /// `OM_ACCEL_DEFAULT_RATE` / `OM_ACCEL_DEFAULT_RANGE` — 100 Hz, ±8 g.
    public static let deviceDefault = AccelConfig(rate: .hz100, range: .g8)

    /// The single rate-code byte sent as `RATE <code>`.
    public var rateCode: UInt8 {
        var v = rate.code | range.code
        if lowPower { v |= 0x10 }
        return v
    }

    /// `OM_ACCEL_IS_VALID_RATE` — low power is only defined for 12.5–400 Hz.
    public var isValidRateCode: Bool {
        let v = Int(rateCode) & 0x3F
        return (v >= 0x06 && v <= 0x0F) || (v >= 0x17 && v <= 0x1C)
    }

    /// The `rate` argument for `OmSetAccelConfig` (negated for low power).
    public var apiRate: Int32 { Int32(lowPower ? -rate.apiValue : rate.apiValue) }

    /// The `range` argument for `OmSetAccelConfig` (gyro range in the high word).
    ///
    /// `1 << 16` is the library's special "gyro explicitly disabled" encoding, because a plain
    /// `0 << 16` is indistinguishable from "gyro unspecified".
    public var apiRange: Int32 {
        guard let gyro else { return Int32(range.rawValue) }
        let high = gyro == .off ? 1 : gyro.rawValue
        return Int32(range.rawValue) | Int32(high << 16)
    }

    /// Inverse of `apiRate`/`apiRange` — what `OmGetAccelConfig` hands back.
    public init?(apiRate: Int32, apiRange: Int32) {
        let lowPower = apiRate < 0
        guard let rate = SampleRate(apiValue: Int(abs(apiRate))) else { return nil }
        guard let range = AccelRange(rawValue: Int(apiRange & 0xFFFF)) else { return nil }
        var gyro: GyroRange?
        if apiRange & ~0xFFFF != 0 {
            let high = Int(apiRange >> 16)
            gyro = high == 1 ? .off : GyroRange(rawValue: high)
            if gyro == nil { return nil }
        }
        self.init(rate: rate, range: range, lowPower: lowPower, gyro: gyro)
    }

    /// Decode a rate-code byte as the device reports it (`RATE=<code>,<hz>[,<gyro>]`).
    public init?(rateCode: UInt8, gyroDps: Int? = nil) {
        guard let rate = SampleRate(code: rateCode), let range = AccelRange(code: rateCode) else { return nil }
        var gyro: GyroRange?
        if let gyroDps { gyro = GyroRange(rawValue: gyroDps); if gyro == nil { return nil } }
        self.init(rate: rate, range: range, lowPower: (rateCode & 0x10) != 0, gyro: gyro)
    }

    /// The literal `RATE` command payload, e.g. `"74"` or `"74,1000"`.
    public var rateCommandArgument: String {
        guard let gyro, gyro != .off else { return "\(rateCode)" }
        return "\(rateCode),\(gyro.rawValue)"
    }

    /// Bytes per sample on the wire (16-bit signed per axis; 6 axes when the gyro is on).
    public var axisCount: Int { (gyro != nil && gyro != .off) ? 6 : 3 }
}
