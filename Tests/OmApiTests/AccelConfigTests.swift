import XCTest
@testable import OmApi

/// Expected rate codes come from `Docs/ax3/ax3-technical.md` ("A code can be created by the sum of
/// the parts"), cross-checked against `OM_ACCEL_*` in `omapi-settings.c`.
final class AccelConfigTests: XCTestCase {

    /// Range component of the rate code, per the protocol doc.
    private let rangeCodes: [AccelRange: UInt8] = [.g16: 0, .g8: 64, .g4: 128, .g2: 192]
    /// Frequency component of the rate code, per the protocol doc.
    private let rateCodes: [SampleRate: UInt8] = [
        .hz6_25: 6, .hz12_5: 7, .hz25: 8, .hz50: 9, .hz100: 10,
        .hz200: 11, .hz400: 12, .hz800: 13, .hz1600: 14, .hz3200: 15,
    ]

    func testDocumentedComponentCodes() {
        for (range, code) in rangeCodes { XCTAssertEqual(range.code, code, "range ±\(range.rawValue) g") }
        for (rate, code) in rateCodes { XCTAssertEqual(rate.code, code, "rate \(rate.displayString) Hz") }
    }

    /// The single documented example: 100 Hz at ±8 g is code 74 ("RATE=74,100").
    func testKnownRateCode() {
        XCTAssertEqual(AccelConfig(rate: .hz100, range: .g8).rateCode, 74)
    }

    func testEveryFrequencyAndRangeCombination() {
        for rate in SampleRate.allCases {
            for range in AccelRange.allCases {
                let config = AccelConfig(rate: rate, range: range)
                let code = config.rateCode
                XCTAssertEqual(code, rangeCodes[range]! + rateCodes[rate]!,
                               "\(rate.displayString) Hz ±\(range.rawValue) g")

                // The device-side formulas from ax3-technical.md must invert the code.
                XCTAssertEqual(3200 / (1 << (15 - Int(code & 0x0F))), rate.apiValue,
                               "frequency formula for code \(code)")
                XCTAssertEqual(16 >> (Int(code) >> 6), range.rawValue,
                               "range formula for code \(code)")

                XCTAssertTrue(config.isValidRateCode)
                XCTAssertEqual(AccelConfig(rateCode: code), config)
            }
        }
    }

    func testDisplayFrequenciesCoverOMGUIsList() {
        // DateRangeForm's combo box, in order.
        XCTAssertEqual(SampleRate.allCases.map(\.displayString),
                       ["3200", "1600", "800", "400", "200", "100", "50", "25", "12.5", "6.25"])
        // OMGUI passes (int)float.Parse(...) to the API, so 12.5 and 6.25 arrive as 12 and 6.
        XCTAssertEqual(SampleRate.hz12_5.apiValue, 12)
        XCTAssertEqual(SampleRate.hz6_25.apiValue, 6)
        XCTAssertEqual(SampleRate.hz12_5.hz, 12.5)
        XCTAssertEqual(SampleRate.hz6_25.hz, 6.25)
        XCTAssertEqual(SampleRate(display: "12.5"), .hz12_5)
        XCTAssertEqual(SampleRate(display: "100"), .hz100)
        XCTAssertNil(SampleRate(display: "1000"))
    }

    func testLowPowerBitAndValidRange() {
        // OM_ACCEL_RATE_LOW_POWER is 0x10, and is only defined for 12.5-400 Hz.
        for rate in SampleRate.allCases {
            let config = AccelConfig(rate: rate, range: .g8, lowPower: true)
            XCTAssertEqual(config.rateCode, 64 + 16 + rateCodes[rate]!)
            let expectValid = rate.apiValue >= 12 && rate.apiValue <= 400
            XCTAssertEqual(config.isValidRateCode, expectValid,
                           "low power at \(rate.displayString) Hz")
        }
        XCTAssertEqual(AccelConfig(rate: .hz400, range: .g8, lowPower: true).rateCode, 92)
    }

    func testApiRateAndRangeOverloading() {
        // Negative rate means low power (MainForm.cs: `if (rangeForm.LowPower) freq = -freq;`).
        XCTAssertEqual(AccelConfig(rate: .hz100, range: .g8).apiRate, 100)
        XCTAssertEqual(AccelConfig(rate: .hz100, range: .g8, lowPower: true).apiRate, -100)

        // Gyro range lives in the high word (`range |= gyroRange << 16`).
        XCTAssertEqual(AccelConfig(rate: .hz100, range: .g8).apiRange, 8)
        XCTAssertEqual(AccelConfig(rate: .hz100, range: .g8, gyro: .dps2000).apiRange, 8 | (2000 << 16))
        XCTAssertEqual(AccelConfig(rate: .hz100, range: .g4, gyro: .dps125).apiRange, 4 | (125 << 16))
        // 1 << 16 is libomapi's "gyro explicitly disabled" encoding.
        XCTAssertEqual(AccelConfig(rate: .hz100, range: .g8, gyro: .off).apiRange, 8 | (1 << 16))
    }

    func testEveryGyroRangeRoundTrips() {
        for rate in SampleRate.allCases {
            for range in AccelRange.allCases {
                for gyro in [nil] + GyroRange.allCases.map(Optional.init) {
                    let config = AccelConfig(rate: rate, range: range, gyro: gyro)
                    let decoded = AccelConfig(apiRate: config.apiRate, apiRange: config.apiRange)
                    XCTAssertEqual(decoded, config,
                                   "\(rate.displayString) Hz ±\(range.rawValue) g gyro \(String(describing: gyro))")
                    XCTAssertEqual(config.axisCount, (gyro != nil && gyro != .off) ? 6 : 3)
                }
            }
        }
    }

    func testGyroRangesMatchOMGUIsList() {
        // DateRangeForm's `GyroRanges = { 0, 2000, 1000, 500, 250, 125 }`.
        XCTAssertEqual(Set(GyroRange.allCases.map(\.rawValue)), Set([0, 2000, 1000, 500, 250, 125]))
        XCTAssertNil(GyroRange(rawValue: 4000))
    }

    func testRateCommandArgument() {
        XCTAssertEqual(AccelConfig(rate: .hz100, range: .g8).rateCommandArgument, "74")
        XCTAssertEqual(AccelConfig(rate: .hz100, range: .g8, gyro: .dps2000).rateCommandArgument, "74,2000")
        XCTAssertEqual(AccelConfig(rate: .hz100, range: .g8, gyro: .off).rateCommandArgument, "74")
    }

    func testDeviceDefaultsMatchLibomapi() {
        // OM_ACCEL_DEFAULT_RATE 100, OM_ACCEL_DEFAULT_RANGE 8.
        XCTAssertEqual(AccelConfig.deviceDefault.rate, .hz100)
        XCTAssertEqual(AccelConfig.deviceDefault.range, .g8)
        XCTAssertEqual(AccelConfig.deviceDefault.apiRate, 100)
        XCTAssertEqual(AccelConfig.deviceDefault.apiRange, 8)
    }

    func testRejectsUnknownValues() {
        XCTAssertNil(AccelConfig(apiRate: 300, apiRange: 8))
        XCTAssertNil(AccelConfig(apiRate: 100, apiRange: 3))
        XCTAssertNil(AccelConfig(apiRate: 100, apiRange: 8 | (777 << 16)))
    }
}
